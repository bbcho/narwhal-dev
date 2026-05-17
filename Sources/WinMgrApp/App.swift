import AppKit
import CoreGraphics
import WinMgrCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()

    private let axClient = AXClient()
    private let displayClient = DisplayClient()
    private let worldActor = MVPWorldActor()
    private let reporter = StartupReporter()
    private var accessibilityPollTimer: Timer?
    private var hotkeyManager: HotkeyManager?
    private var mvpServicesStarted = false

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = instance
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reporter.info("WinMgrApp started")
        reporter.info("Build marker: mvp-frame-debug-2026-05-16.1")
        reporter.info("Log file: \(StartupReporter.defaultLogPath)")

        if ProcessInfo.processInfo.arguments.contains("--left-half") {
            runLeftHalfOnceAndTerminate()
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--push-left") {
            runPushOnceAndTerminate(.left)
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--focused-window") {
            let status = reportAccessibilityStatus(prompt: false)
            if status.isTrusted {
                reportFocusedWindowSnapshot()
            } else {
                reporter.error("Focused-window check skipped because Accessibility is not trusted")
            }
            NSApplication.shared.terminate(nil)
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--check-accessibility") {
            reportAccessibilityStatus(prompt: false)
            NSApplication.shared.terminate(nil)
            return
        }

        let status = reportAccessibilityStatus(prompt: true)
        guard status.isTrusted else {
            reporter.info("Waiting for Accessibility permission before starting AX work")
            accessibilityPollTimer = Timer.scheduledTimer(
                timeInterval: 2.0,
                target: self,
                selector: #selector(checkAccessibilityPermissionAgain(_:)),
                userInfo: nil,
                repeats: true
            )
            return
        }

        reporter.info("Rung 1 complete: AppKit run loop is active and Accessibility is trusted")
        reportFocusedWindowSnapshot()
        startMVPServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        hotkeyManager?.stop()
        hotkeyManager = nil
        reporter.info("WinMgrApp stopped")
    }

    @discardableResult
    private func reportAccessibilityStatus(prompt: Bool) -> AccessibilityStatus {
        let status = AccessibilityTrust.current(prompt: prompt)
        switch status {
        case .trusted:
            reporter.info("Accessibility trusted")
        case .notTrusted(let prompted):
            let promptState = prompted ? "prompted" : "not prompted"
            reporter.error("Accessibility not trusted (\(promptState))")
        }
        return status
    }

    @objc
    private func checkAccessibilityPermissionAgain(_ timer: Timer) {
        guard AccessibilityTrust.current(prompt: false).isTrusted else { return }

        timer.invalidate()
        accessibilityPollTimer = nil
        reporter.info("Accessibility trusted")
        reporter.info("Rung 1 complete: AppKit run loop is active and Accessibility is trusted")
        reportFocusedWindowSnapshot()
        startMVPServices()
    }

    private func reportFocusedWindowSnapshot() {
        switch axClient.focusedWindowSnapshot() {
        case .success(let snapshot):
            reporter.info("Focused window: \(snapshot.logDescription)")
        case .failure(let error):
            reporter.error("Focused-window snapshot failed: \(error.description)")
        }
    }

    private func runLeftHalfOnceAndTerminate() {
        let status = reportAccessibilityStatus(prompt: false)
        guard status.isTrusted else {
            reporter.error("Left-half command skipped because Accessibility is not trusted")
            NSApplication.shared.terminate(nil)
            return
        }

        if let error = moveFocusedWindowToLeftHalf() {
            reporter.error("Left-half command failed: \(error)")
        } else {
            reporter.info("Left-half command completed")
        }
        NSApplication.shared.terminate(nil)
    }

    private func runPushOnceAndTerminate(_ direction: Direction) {
        let status = reportAccessibilityStatus(prompt: false)
        guard status.isTrusted else {
            reporter.error("Push command skipped because Accessibility is not trusted")
            NSApplication.shared.terminate(nil)
            return
        }

        Task { @MainActor in
            await performPush(direction)
            NSApplication.shared.terminate(nil)
        }
    }

    private func startMVPServices() {
        guard !mvpServicesStarted else { return }

        let manager = HotkeyManager(bindings: Config.default.keymap, reporter: reporter) { [weak self] action in
            Task { @MainActor in
                await self?.performHotkey(action)
            }
        }

        do {
            try manager.start()
            hotkeyManager = manager
            mvpServicesStarted = true
            reporter.info("MVP push loop ready")
        } catch {
            reporter.error("Hotkey startup failed: \(String(describing: error))")
        }
    }

    private func moveFocusedWindowToLeftHalf() -> String? {
        let snapshot: FocusedWindowSnapshot
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            return error.description
        }

        let displays = displayClient.currentDisplays()
        logDisplays(displays)
        guard let displayID = displayClient.displayContaining(frame: snapshot.frame, displays: displays),
              let display = displays[displayID]
        else {
            return "No display found for focused window"
        }

        let targetFrame = displayClient.leftHalf(of: display)
        reporter.info("Left-half target display=\(displayID.raw) focused=\(snapshot.frame.debugDescription) target=\(targetFrame.debugDescription)")
        switch axClient.setFocusedWindowFrame(targetFrame) {
        case .converged(let actual):
            reporter.info("Moved focused window to left half of display \(displayID.raw) actual=\(actual.debugDescription)")
            return nil
        case .clamped(let actual, let observed):
            return "left-half command clamped actual=\(actual.debugDescription) observed=\(observed.debugDescription)"
        case .failed(let error):
            return error.description
        }
    }

    @MainActor
    private func performHotkey(_ action: HotkeyAction) async {
        switch action {
        case .command(.push(let direction)):
            await performPush(direction)
        case .command(.resetLayout):
            await worldActor.resetLayoutMemory()
            reporter.info("Reset layout memory: cleared BSP trees, floating lists, focus, pending rules, and observed window minimums")
        case .command(let template):
            reporter.error("Hotkey action not implemented in MVP: \(describe(template))")
        case .reloadConfig:
            reporter.error("Reload config hotkey ignored: Lua config loader lands in Rung 7")
        }
    }

    @MainActor
    private func performPush(_ direction: Direction) async {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Push \(direction.rawValue) skipped because Accessibility is not trusted")
            return
        }

        let snapshot: FocusedWindowSnapshot
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) failed reading focused window: \(error.description)")
            return
        }

        let displays = displayClient.currentDisplays()
        reporter.info("Push \(direction.rawValue) focused \(snapshot.logDescription)")
        logDisplays(displays)
        guard let displayID = displayClient.displayContaining(frame: snapshot.frame, displays: displays) else {
            reporter.error("Push \(direction.rawValue) failed: no display for focused window")
            return
        }
        reporter.info("Push \(direction.rawValue) selected display \(displayID.raw)")

        switch axClient.visibleWindowIDs() {
        case .success(let liveWindowIDs):
            await worldActor.reconcileLiveWindows(liveWindowIDs.union([snapshot.id]))
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) skipped live-window reconciliation: \(error.description)")
        }
        await worldActor.upsertWindow(snapshot.metadata, displayID: displayID, displays: displays)

        switch await worldActor.planPush(snapshot.id, direction: direction) {
        case .success(let result):
            await applyPlannedPush(result, direction: direction, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) rejected by core: \(error.message)")
        }
    }

    @MainActor
    private func applyPlannedPush(_ result: MVPCommandResult, direction: Direction, retryOnClamp: Bool) async {
        let applyResult = LayoutApplier(axClient: axClient, reporter: reporter).apply(result)
        if applyResult.succeeded {
            await worldActor.commit(result, appliedFrames: applyResult.applied)
            reporter.info("Push \(direction.rawValue) completed")
            return
        }

        await worldActor.recordAppliedFrames(applyResult.applied)
        if !applyResult.clamps.isEmpty {
            await worldActor.recordObservedConstraints(applyResult.observedConstraints)
        }

        if !applyResult.failures.isEmpty {
            let failureSummary = applyResult.failures
                .map { "\($0.windowID.description) target=\($0.targetFrame.debugDescription) error=\($0.message)" }
                .joined(separator: "; ")
            reporter.error(
                "Push \(direction.rawValue) failed applying \(applyResult.failures.count) window(s); planned layout was not committed: \(failureSummary)"
            )
            return
        }

        let clampSummary = applyResult.clamps
            .map {
                "\($0.windowID.description) target=\($0.targetFrame.debugDescription) actual=\($0.actualFrame.debugDescription) observed=\($0.observed.debugDescription)"
            }
            .joined(separator: "; ")

        guard retryOnClamp else {
            reporter.error(
                "Push \(direction.rawValue) still clamped after min-size re-solve; planned layout was not committed: \(clampSummary)"
            )
            return
        }

        reporter.info("Push \(direction.rawValue) observed app min-size clamp; re-solving once: \(clampSummary)")
        switch await worldActor.planPush(result.focusedWindowID, direction: direction) {
        case .success(let retry):
            await applyPlannedPush(retry, direction: direction, retryOnClamp: false)
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) rejected after min-size observation: \(error.message)")
        }
    }

    private func logDisplays(_ displays: [DisplayID: DisplayInfo]) {
        for (id, display) in displays.sorted(by: { $0.key.raw < $1.key.raw }) {
            reporter.info("Display \(id.raw) frame=\(display.frame.debugDescription) visible=\(display.visibleFrame.debugDescription)")
        }
    }
}

private extension WindowConstraints {
    var debugDescription: String {
        "minWidth=\(minWidth.map { String($0) } ?? "nil") minHeight=\(minHeight.map { String($0) } ?? "nil")"
    }
}

private func describe(_ template: CommandTemplate) -> String {
    switch template {
    case .push(let direction):
        return "push \(direction.rawValue)"
    case .center:
        return "center"
    case .eject:
        return "eject"
    case .focusDirection(let direction):
        return "focus \(direction.rawValue)"
    case .toggleFloat:
        return "toggleFloat"
    case .resetLayout:
        return "resetLayout"
    }
}
