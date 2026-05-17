import AppKit
import CoreGraphics
import Darwin
import WinMgrCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()

    private let axClient = AXClient()
    private let displayClient = DisplayClient()
    private let spaceClient = SpaceClient()
    private let restoreManager = RestoreManager()
    private var worldActor = MVPWorldActor()
    private let reporter = StartupReporter()
    private var config = Config.default
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

        if ProcessInfo.processInfo.arguments.contains("--check-config") {
            let ok = loadStartupConfig()
            reporter.info("WinMgrApp stopped")
            Darwin.exit(ok ? 0 : 1)
        }

        if ProcessInfo.processInfo.arguments.contains("--check-environment") {
            guard loadStartupConfig() else {
                reporter.info("WinMgrApp stopped")
                Darwin.exit(1)
            }
            let status = reportAccessibilityStatus(prompt: false)
            guard status.isTrusted else {
                reporter.error("Environment check skipped because Accessibility is not trusted")
                reporter.info("WinMgrApp stopped")
                Darwin.exit(1)
            }
            Task { @MainActor in
                let focused = reportFocusedWindowSnapshot()
                let environment = await refreshEnvironment(reason: "check")
                guard environment.activeSpace != nil else {
                    reporter.error("Environment check failed: active Space unavailable")
                    reporter.info("WinMgrApp stopped")
                    Darwin.exit(1)
                }
                if let focused {
                    await worldActor.recordExternalFocus(focused.id)
                }
                reporter.info("WinMgrApp stopped")
                Darwin.exit(0)
            }
            return
        }

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
                _ = reportFocusedWindowSnapshot()
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

        guard loadStartupConfigOrTerminate() else { return }

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

        Task { @MainActor in
            await startAfterAccessibilityTrusted()
        }
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
        Task { @MainActor in
            await startAfterAccessibilityTrusted()
        }
    }

    @MainActor
    private func startAfterAccessibilityTrusted() async {
        guard !mvpServicesStarted else { return }
        reporter.info("Rung 1 complete: AppKit run loop is active and Accessibility is trusted")
        let focused = reportFocusedWindowSnapshot()
        let environment = await refreshEnvironment(reason: "startup")
        guard environment.activeSpace != nil else {
            reporter.error("MVP services not started: active Space unavailable")
            return
        }
        guard await loadRestoreState(using: environment.snapshot) else { return }
        if let focused {
            await worldActor.recordExternalFocus(focused.id)
        }
        await applyStartupConverge()
        startMVPServices()
    }

    private func reportFocusedWindowSnapshot() -> FocusedWindowSnapshot? {
        switch axClient.focusedWindowSnapshot() {
        case .success(let snapshot):
            reporter.info("Focused window: \(snapshot.logDescription)")
            return snapshot
        case .failure(let error):
            reporter.error("Focused-window snapshot failed: \(error.description)")
            return nil
        }
    }

    @discardableResult
    @MainActor
    private func refreshEnvironment(
        reason: String,
        displays providedDisplays: [DisplayID: DisplayInfo]? = nil
    ) async -> EnvironmentRefreshResult {
        let displays = providedDisplays ?? displayClient.currentDisplays()
        let activeSpace: SpaceID?
        switch spaceClient.activeSpaceID() {
        case .success(let spaceID):
            activeSpace = spaceID
        case .failure(let error):
            activeSpace = nil
            reporter.error("Active Space refresh failed (\(reason)): \(error.description)")
        }
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: displays,
            axSnapshot: axClient.windowSnapshot()
        )
        let result = await worldActor.refreshEnvironment(snapshot)
        reporter.info(
            "Environment refreshed (\(reason)): activeSpace=\(result.activeSpace?.raw.description ?? "nil") displays=\(result.displayCount) windows=\(result.windowCount) quality=\(describe(result.quality))"
        )
        return result
    }

    @discardableResult
    private func loadStartupConfigOrTerminate() -> Bool {
        let ok = loadStartupConfig()
        if !ok {
            NSApplication.shared.terminate(nil)
        }
        return ok
    }

    @discardableResult
    private func loadStartupConfig() -> Bool {
        switch startupConfigRequestFromArguments() {
        case .success(let request):
            switch StartupConfigLoader(configURL: request.url, missingFilePolicy: request.missingFilePolicy).load() {
            case .success(let loaded):
                config = loaded.config
                worldActor = MVPWorldActor(config: loaded.config)
                logStartupConfig(loaded)
                return true
            case .failure(let error):
                reporter.error("Startup config failed: \(error.description)")
                return false
            }
        case .failure(let error):
            reporter.error("Startup config failed: \(error.description)")
            return false
        }
    }

    private func startupConfigRequestFromArguments() -> Result<StartupConfigRequest, StartupConfigError> {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--config") else {
            return .success(StartupConfigRequest(
                url: StartupConfigLoader.defaultUserConfigURL,
                missingFilePolicy: .useBuiltInDefault
            ))
        }
        let pathIndex = arguments.index(after: index)
        guard arguments.indices.contains(pathIndex) else {
            return .failure(.missingConfigPathArgument)
        }
        return .success(StartupConfigRequest(
            url: URL(fileURLWithPath: arguments[pathIndex]).standardizedFileURL,
            missingFilePolicy: .fail
        ))
    }

    private func logStartupConfig(_ loaded: StartupConfigLoad) {
        switch loaded.source {
        case .builtInDefault(let missingUserConfig):
            reporter.info("Startup config not found at \(missingUserConfig.path); using built-in defaults")
        case .userFile(let url):
            reporter.info("Loaded startup config from \(url.path)")
        }
        reporter.info("Startup config active: \(loaded.config.keymap.count) hotkeys, \(loaded.config.zones.count) zones")
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
        guard loadStartupConfigOrTerminate() else { return }

        let status = reportAccessibilityStatus(prompt: false)
        guard status.isTrusted else {
            reporter.error("Push command skipped because Accessibility is not trusted")
            NSApplication.shared.terminate(nil)
            return
        }

        Task { @MainActor in
            let environment = await refreshEnvironment(reason: "one-shot push")
            guard environment.activeSpace != nil else {
                reporter.error("Push \(direction.rawValue) skipped because active Space is unavailable")
                NSApplication.shared.terminate(nil)
                return
            }
            guard await loadRestoreState(using: environment.snapshot) else {
                NSApplication.shared.terminate(nil)
                return
            }
            await performPush(direction)
            NSApplication.shared.terminate(nil)
        }
    }

    private func startMVPServices() {
        guard !mvpServicesStarted else { return }

        let manager = HotkeyManager(bindings: config.keymap, reporter: reporter) { [weak self] action in
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
            await persistRestore(reason: "reset")
        case .command(let template):
            reporter.error("Hotkey action not implemented in MVP: \(describe(template))")
        case .reloadConfig:
            reporter.error("Reload config hotkey ignored: hot reload is not implemented; restart the app to apply startup config")
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
        let environment = await refreshEnvironment(reason: "pre-push \(direction.rawValue)", displays: displays)
        guard environment.activeSpace != nil else {
            reporter.error("Push \(direction.rawValue) rejected before planning: active Space unavailable")
            return
        }

        switch axClient.visibleWindowIDs() {
        case .success(let liveWindowIDs):
            await worldActor.reconcileLiveWindows(liveWindowIDs.union([snapshot.id]))
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) skipped live-window reconciliation: \(error.description)")
        }
        switch await worldActor.upsertWindow(snapshot.metadata, displayID: displayID, displays: displays) {
        case .success:
            break
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) failed updating focused window state: \(error.message)")
            return
        }

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
            await persistRestore(reason: "push \(direction.rawValue)")
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
        guard let focusedWindowID = result.focusedWindowID else {
            reporter.error("Push \(direction.rawValue) cannot retry min-size re-solve without a focused window")
            return
        }
        switch await worldActor.planPush(focusedWindowID, direction: direction) {
        case .success(let retry):
            await applyPlannedPush(retry, direction: direction, retryOnClamp: false)
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) rejected after min-size observation: \(error.message)")
        }
    }

    @MainActor
    private func loadRestoreState(using snapshot: EnvironmentSnapshot) async -> Bool {
        guard snapshot.axSnapshot.quality == .complete else {
            reporter.error("Restore skipped because environment snapshot is \(describe(snapshot.axSnapshot.quality))")
            return true
        }

        do {
            guard let stored = try restoreManager.load() else {
                reporter.info("Restore state not found at \(restoreManager.url.path)")
                return true
            }
            let restoredCount = await worldActor.restore(stored, from: snapshot)
            reporter.info("Restore state loaded from \(restoreManager.url.path); restored tiled windows=\(restoredCount)")
            return true
        } catch {
            reporter.error("Restore state failed: \(String(describing: error))")
            NSApplication.shared.terminate(nil)
            return false
        }
    }

    @MainActor
    private func applyStartupConverge() async {
        switch await worldActor.planCurrentLayout() {
        case .success(nil):
            reporter.info("Startup restore convergence skipped: no restored tiled windows")
        case .success(let result?):
            let applyResult = LayoutApplier(axClient: axClient, reporter: reporter).apply(result)
            if applyResult.succeeded {
                await worldActor.commit(result, appliedFrames: applyResult.applied)
                reporter.info("Startup restore convergence completed")
                await persistRestore(reason: "startup")
                return
            }

            await worldActor.recordAppliedFrames(applyResult.applied)
            if !applyResult.clamps.isEmpty {
                await worldActor.recordObservedConstraints(applyResult.observedConstraints)
            }
            let clampSummary = applyResult.clamps
                .map {
                    "\($0.windowID.description) target=\($0.targetFrame.debugDescription) actual=\($0.actualFrame.debugDescription) observed=\($0.observed.debugDescription)"
                }
                .joined(separator: "; ")
            let failureSummary = applyResult.failures
                .map { "\($0.windowID.description) target=\($0.targetFrame.debugDescription) error=\($0.message)" }
                .joined(separator: "; ")
            reporter.error(
                "Startup restore convergence failed; restored layout was not committed: clamps=\(clampSummary) failures=\(failureSummary)"
            )
        case .failure(let error):
            reporter.error("Startup restore convergence rejected by core: \(error.message)")
        }
    }

    @MainActor
    private func persistRestore(reason: String) async {
        let stored = await worldActor.restoreSnapshot()
        do {
            try restoreManager.save(stored)
            reporter.info("Restore state saved (\(reason)) to \(restoreManager.url.path)")
        } catch {
            reporter.error("Restore state save failed (\(reason)): \(String(describing: error))")
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

private func describe(_ quality: AXSnapshotQuality) -> String {
    switch quality {
    case .complete:
        return "complete"
    case .partial(let errors):
        return "partial(\(errors.count) errors)"
    case .permissionDenied(let message):
        return "permissionDenied(\(message))"
    }
}
