import AppKit
import CoreGraphics
import Darwin
import WinMgrCore
import WinMgrIPC

private enum StartupArgumentError: Error, CustomStringConvertible {
    case missingRestoreStatePath

    var description: String {
        switch self {
        case .missingRestoreStatePath:
            return "--restore-state requires a file path"
        }
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()
    private static let environmentRefreshCoalescingDelay: TimeInterval = 0.10

    private let axClient = AXClient()
    private let displayClient = DisplayClient()
    private let spaceClient = SpaceClient()
    private var restoreManager = RestoreManager()
    private let echoSuppressor = AXEchoSuppressor()
    private let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
    private let menubar = Menubar()
    private var worldActor = WorldActor()
    private let reporter = StartupReporter()
    private var config = Config.default
    private var accessibilityPollTimer: Timer?
    private var hotkeyManager: HotkeyManager?
    private var axObserverService: AXObserverService?
    private var displayObserverService: DisplayObserverService?
    private var configFileWatcherService: ConfigFileWatcherService?
    private var ipcServer: IPCServer?
    private var eventTapClient: EventTapClient?
    private var environmentRefreshCoalescer = EnvironmentRefreshCoalescerState.empty
    private var environmentRefreshCoalescingTimer: Timer?
    private var environmentRefreshCoalescingTimerGeneration: UInt64?
    private var servicesStarted = false

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = instance
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reporter.info("WinMgrApp started")
        reporter.info("Log file: \(StartupReporter.defaultLogPath)")
        guard configureRestoreManagerOrTerminate() else { return }

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
        environmentRefreshCoalescingTimer?.invalidate()
        environmentRefreshCoalescingTimer = nil
        environmentRefreshCoalescingTimerGeneration = nil
        axObserverService?.stop()
        axObserverService = nil
        displayObserverService?.stop()
        displayObserverService = nil
        configFileWatcherService?.stop()
        configFileWatcherService = nil
        ipcServer?.stop()
        ipcServer = nil
        eventTapClient?.stop()
        eventTapClient = nil
        hotkeyManager?.stop()
        hotkeyManager = nil
        menubar.stop()
        overlay.stop()
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
        guard !servicesStarted else { return }
        reporter.info("Rung 1 complete: AppKit run loop is active and Accessibility is trusted")
        let focused = reportFocusedWindowSnapshot()
        let environment = await refreshEnvironment(reason: "startup")
        guard environment.activeSpace != nil else {
            reporter.error("Window manager services not started: active Space unavailable")
            return
        }
        guard await loadRestoreState(using: environment.snapshot) else { return }
        if let focused {
            await worldActor.recordExternalFocus(focused.id)
            overlay.updateFocusBorder(.show(focused.id, focused.frame))
        }
        await applyStartupConverge()
        startServices()
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
    private func configureRestoreManagerOrTerminate() -> Bool {
        switch restoreStateURLFromArguments() {
        case .success(let url):
            restoreManager = RestoreManager(url: url)
            if url != RestoreManager.defaultURL {
                reporter.info("Using restore state path \(url.path)")
            }
            return true
        case .failure(let error):
            reporter.error(error.description)
            reporter.info("WinMgrApp stopped")
            Darwin.exit(1)
        }
    }

    private func restoreStateURLFromArguments() -> Result<URL, StartupArgumentError> {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--restore-state") else {
            return .success(RestoreManager.defaultURL)
        }
        let pathIndex = arguments.index(after: index)
        guard arguments.indices.contains(pathIndex) else {
            return .failure(.missingRestoreStatePath)
        }
        return .success(URL(fileURLWithPath: arguments[pathIndex]).standardizedFileURL)
    }

    @discardableResult
    private func loadStartupConfig() -> Bool {
        switch startupConfigLoad() {
        case .success(let loaded):
            config = loaded.config
            worldActor = WorldActor(config: loaded.config)
            overlay.updateConfig(border: loaded.config.border, hud: loaded.config.hud)
            logStartupConfig(loaded)
            return true
        case .failure(let error):
            reporter.error("Startup config failed: \(error.description)")
            return false
        }
    }

    private func startupConfigLoad() -> Result<StartupConfigLoad, StartupConfigError> {
        switch startupConfigRequestFromArguments() {
        case .success(let request):
            return StartupConfigLoader(configURL: request.url, missingFilePolicy: request.missingFilePolicy).load()
        case .failure(let error):
            return .failure(error)
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

    private func startServices() {
        guard !servicesStarted else { return }
        startMenubar()

        let manager = HotkeyManager(bindings: config.keymap, reporter: reporter) { [weak self] action in
            Task { @MainActor in
                await self?.performHotkey(action)
            }
        }

        do {
            try manager.start()
            hotkeyManager = manager
            startAXObserver()
            startDisplayObserver()
            startConfigFileWatcher()
            startIPCServer()
            startEventTap()
            servicesStarted = true
            reporter.info("Layout command loop ready")
        } catch {
            reporter.error("Hotkey startup failed: \(String(describing: error))")
        }
    }

    @MainActor
    private func startMenubar() {
        menubar.start(
            reload: { [weak self] in
                Task { @MainActor in
                    await self?.reloadConfig(reason: "menubar")
                }
            },
            reset: { [weak self] in
                Task { @MainActor in
                    await self?.performHotkey(.command(.resetLayout))
                }
            },
            quit: {
                NSApplication.shared.terminate(nil)
            }
        )
        menubar.updateConfigStatus(.loaded)
    }

    @MainActor
    private func startAXObserver() {
        guard axObserverService == nil else { return }
        let service = AXObserverService(
            axClient: axClient,
            echoSuppressor: echoSuppressor,
            reporter: reporter,
            spaceChanged: { [weak self] in
                self?.overlay.updateFocusBorder(.hide)
                self?.scheduleCoalescedEnvironmentRefresh(.spaceSettled)
            }
        ) { [weak self] event, snapshot in
            Task { @MainActor in
                await self?.handleAXEvent(event, snapshot: snapshot)
            }
        }
        service.start()
        axObserverService = service
    }

    @MainActor
    private func startDisplayObserver() {
        guard displayObserverService == nil else { return }
        let service = DisplayObserverService(reporter: reporter) { [weak self] in
            self?.overlay.updateFocusBorder(.hide)
            self?.scheduleCoalescedEnvironmentRefresh(.displayChanged)
        }
        service.start()
        displayObserverService = service
    }

    @MainActor
    private func startConfigFileWatcher() {
        guard configFileWatcherService == nil else { return }
        switch startupConfigRequestFromArguments() {
        case .success(let request):
            let service = ConfigFileWatcherService(configURL: request.url, reporter: reporter) { [weak self] in
                Task { @MainActor in
                    await self?.reloadConfig(reason: "file watcher")
                }
            }
            service.start()
            configFileWatcherService = service
        case .failure(let error):
            reporter.error("Config watcher skipped: \(error.description)")
        }
    }

    @MainActor
    private func startIPCServer() {
        guard ipcServer == nil else { return }
        let server = IPCServer(
            socketPath: IPCDefaults.socketPath,
            handle: { [weak self] command in
                await self?.handleIPCCommand(command) ?? .error(
                    commandID: CommandID(raw: "app-unavailable"),
                    code: "app_unavailable",
                    message: "WinMgrApp is not available"
                )
            },
            log: { [weak self] message in
                Task { @MainActor in
                    self?.reporter.error(message)
                }
            }
        )
        do {
            try server.start()
            ipcServer = server
            reporter.info("IPC server ready at \(IPCDefaults.socketPath)")
        } catch {
            reporter.error("IPC server startup failed: \(String(describing: error))")
        }
    }

    @MainActor
    private func startEventTap() {
        guard eventTapClient == nil else { return }
        let client = EventTapClient(modifier: config.dragModifier, reporter: reporter) { [weak self] location in
            Task { @MainActor in
                await self?.performDragDrop(at: location)
            }
        }
        do {
            try client.start()
            eventTapClient = client
        } catch {
            reporter.error("Drag-zone event tap startup failed: \(String(describing: error))")
        }
    }

    @MainActor
    private func performHotkey(_ action: HotkeyAction) async {
        switch action {
        case .command(.push(let direction)):
            await performPush(direction)
        case .command(.center):
            await performCenter()
        case .command(.swap(let direction)):
            await performSwap(direction)
        case .command(.focusDirection(let direction)):
            await performFocusDirection(direction)
        case .command(.focusCycle(let direction)):
            await performFocusCycle(direction)
        case .command(.resetLayout):
            await worldActor.resetLayoutMemory()
            reporter.info("Reset layout memory: cleared BSP trees, floating lists, focus, pending rules, and observed window minimums")
            overlay.updateFocusBorder(.hide)
            await persistRestore(reason: "reset")
        case .command(let template):
            reporter.error("Hotkey action not implemented in this build: \(describe(template))")
        case .reloadConfig:
            await reloadConfig(reason: "hotkey")
        }
    }

    @MainActor
    @discardableResult
    private func performFocusDirection(_ direction: Direction) async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus \(direction.rawValue) skipped because Accessibility is not trusted")
            return false
        }

        let snapshot: FocusedWindowSnapshot
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            reporter.error("Focus \(direction.rawValue) failed reading focused window: \(error.description)")
            return false
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(reason: "pre-focus \(direction.rawValue)", displays: displays)
        guard environment.activeSpace != nil else {
            reporter.error("Focus \(direction.rawValue) rejected before planning: active Space unavailable")
            return false
        }
        await worldActor.recordExternalFocus(snapshot.id)

        switch await worldActor.planFocusDirection(from: snapshot.id, direction: direction) {
        case .success(let result):
            return await focusWindow(result, reason: "focus \(direction.rawValue)")
        case .failure(let error):
            reporter.error("Focus \(direction.rawValue) rejected by core: \(error.message)")
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performFocusCycle(_ direction: FocusCycleDirection) async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus cycle \(direction.rawValue) skipped because Accessibility is not trusted")
            return false
        }

        let focusedWindowID: WindowID?
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            focusedWindowID = value.id
        case .failure:
            focusedWindowID = nil
        }

        let environment = await refreshEnvironment(reason: "pre-focus-cycle \(direction.rawValue)")
        guard environment.activeSpace != nil else {
            reporter.error("Focus cycle \(direction.rawValue) rejected before planning: active Space unavailable")
            return false
        }
        if let focusedWindowID {
            await worldActor.recordExternalFocus(focusedWindowID)
        }

        switch await worldActor.planFocusCycle(from: focusedWindowID, direction: direction) {
        case .success(let result):
            return await focusWindow(result, reason: "focus cycle \(direction.rawValue)")
        case .failure(let error):
            reporter.error("Focus cycle \(direction.rawValue) rejected by core: \(error.message)")
            return false
        }
    }

    @MainActor
    private func focusWindow(_ result: FocusPlanResult, reason: String) async -> Bool {
        switch axClient.focusWindow(result.window) {
        case .success:
            echoSuppressor.expectFocus(windowID: result.window.id)
            await worldActor.recordExternalFocus(result.window.id)
            overlay.updateFocusBorder(.show(result.window.id, result.frame))
            reporter.info("\(reason) completed target=\(result.window.id.description)")
            return true
        case .failure(let error):
            reporter.error("\(reason) failed focusing \(result.window.id.description): \(error.description)")
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performPush(_ direction: Direction) async -> Bool {
        let operation = "Push \(direction.rawValue)"
        guard let context = focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-push \(direction.rawValue)")
        else { return false }

        switch await worldActor.planPush(context.snapshot.id, direction: direction) {
        case .success(let result):
            return await applyPlannedPush(result, direction: direction, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) rejected by core: \(error.message)")
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performCenter() async -> Bool {
        let operation = "Center"
        guard let context = focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-center")
        else { return false }

        switch await worldActor.planCenter(context.snapshot.id) {
        case .success(let result):
            return await applyPlannedCenter(result, windowID: context.snapshot.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Center rejected by core: \(error.message)")
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performSwap(_ direction: Direction) async -> Bool {
        let operation = "Swap \(direction.rawValue)"
        guard let context = focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-swap \(direction.rawValue)")
        else { return false }

        switch await worldActor.planSwap(context.snapshot.id, direction: direction) {
        case .success(let result):
            return await applyPlannedSwap(result, windowID: context.snapshot.id, direction: direction, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Swap \(direction.rawValue) rejected by core: \(error.message)")
            return false
        }
    }

    @MainActor
    private func performDragDrop(at location: CGPoint) async {
        let operation = "Drag drop"
        guard let context = focusedLayoutContext(operation: operation) else { return }
        let drag = DragEvent(windowID: context.snapshot.id, location: location, displayID: nil)
        guard let command = resolveDrop(drag, zones: config.zones, displays: context.displays) else {
            reporter.info("Drag drop ignored: no matching exclusive zone at \(location.debugDescription)")
            return
        }
        guard case .dropAtZone(let windowID, let displayID, let zoneID) = command else {
            reporter.error("Drag drop resolved to unsupported command: \(command)")
            return
        }

        reporter.info(
            "Drag drop resolved focused=\(context.snapshot.id.description) display=\(displayID.raw) zone=\(zoneID.raw) location=\(location.debugDescription)"
        )
        guard await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-drag drop") else { return }

        switch await worldActor.planDrop(windowID: windowID, displayID: displayID, zoneID: zoneID) {
        case .success(let result):
            _ = await applyPlannedDrop(result, windowID: windowID, displayID: displayID, zoneID: zoneID, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Drag drop rejected by core: \(error.message)")
        }
    }

    @MainActor
    private func focusedLayoutContext(operation: String) -> FocusedLayoutContext? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("\(operation) skipped because Accessibility is not trusted")
            return nil
        }

        let snapshot: FocusedWindowSnapshot
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            reporter.error("\(operation) failed reading focused window: \(error.description)")
            return nil
        }

        let displays = displayClient.currentDisplays()
        reporter.info("\(operation) focused \(snapshot.logDescription)")
        logDisplays(displays)
        return FocusedLayoutContext(snapshot: snapshot, displays: displays)
    }

    @MainActor
    private func displayForFocusedWindow(_ context: FocusedLayoutContext, operation: String) -> DisplayID? {
        guard let displayID = displayClient.displayContaining(frame: context.snapshot.frame, displays: context.displays) else {
            reporter.error("\(operation) failed: no display for focused window")
            return nil
        }
        reporter.info("\(operation) selected display \(displayID.raw)")
        return displayID
    }

    @MainActor
    private func prepareLayoutWorld(
        _ context: FocusedLayoutContext,
        displayID: DisplayID,
        operation: String,
        refreshReason: String
    ) async -> Bool {
        let environment = await refreshEnvironment(reason: refreshReason, displays: context.displays)
        guard environment.activeSpace != nil else {
            reporter.error("\(operation) rejected before planning: active Space unavailable")
            return false
        }

        switch axClient.visibleWindowIDs() {
        case .success(let liveWindowIDs):
            await worldActor.reconcileLiveWindows(liveWindowIDs.union([context.snapshot.id]))
        case .failure(let error):
            reporter.error("\(operation) skipped live-window reconciliation: \(error.description)")
        }
        switch await worldActor.upsertWindow(context.snapshot.metadata, displayID: displayID, displays: context.displays) {
        case .success:
            return true
        case .failure(let error):
            reporter.error("\(operation) failed updating focused window state: \(error.message)")
            return false
        }
    }

    @MainActor
    private func applyPlannedPush(_ result: CommandPlanResult, direction: Direction, retryOnClamp: Bool) async -> Bool {
        guard let focusedWindowID = result.focusedWindowID else {
            reporter.error("Push \(direction.rawValue) cannot retry or commit without a focused window")
            return false
        }
        return await applyPlannedLayout(
            result,
            operation: "Push \(direction.rawValue)",
            persistReason: "push \(direction.rawValue)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planPush(focusedWindowID, direction: direction)
        }
    }

    @MainActor
    private func applyPlannedDrop(
        _ result: CommandPlanResult,
        windowID: WindowID,
        displayID: DisplayID,
        zoneID: ZoneID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Drag drop \(zoneID.raw)",
            persistReason: "drag \(zoneID.raw)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planDrop(windowID: windowID, displayID: displayID, zoneID: zoneID)
        }
    }

    @MainActor
    private func applyPlannedCenter(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Center",
            persistReason: "center",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planCenter(windowID)
        }
    }

    @MainActor
    private func applyPlannedSwap(
        _ result: CommandPlanResult,
        windowID: WindowID,
        direction: Direction,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Swap \(direction.rawValue)",
            persistReason: "swap \(direction.rawValue)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planSwap(windowID, direction: direction)
        }
    }

    @MainActor
    private func applyPlannedLayout(
        _ result: CommandPlanResult,
        operation: String,
        persistReason: String,
        retryOnClamp: Bool,
        replanAfterClamp: () async -> Result<CommandPlanResult, CommandError>
    ) async -> Bool {
        let applyResult = LayoutApplier(axClient: axClient, reporter: reporter, echoSuppressor: echoSuppressor).apply(result)
        if applyResult.succeeded {
            await worldActor.commit(result, appliedFrames: applyResult.applied)
            reporter.info("\(operation) completed")
            if let focusedWindowID = result.focusedWindowID,
               let frame = applyResult.applied[focusedWindowID] ?? result.desiredLayout.layout.tiled[focusedWindowID] {
                overlay.updateFocusBorder(.show(focusedWindowID, frame))
            }
            await persistRestore(reason: persistReason)
            return true
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
                "\(operation) failed applying \(applyResult.failures.count) window(s); planned layout was not committed: \(failureSummary)"
            )
            return false
        }

        let clampSummary = applyResult.clamps
            .map {
                "\($0.windowID.description) target=\($0.targetFrame.debugDescription) actual=\($0.actualFrame.debugDescription) observed=\($0.observed.debugDescription)"
            }
            .joined(separator: "; ")

        guard retryOnClamp else {
            reporter.error(
                "\(operation) still clamped after min-size re-solve; planned layout was not committed: \(clampSummary)"
            )
            return false
        }

        reporter.info("\(operation) observed app min-size clamp; re-solving once: \(clampSummary)")
        switch await replanAfterClamp() {
        case .success(let retry):
            return await applyPlannedLayout(
                retry,
                operation: operation,
                persistReason: persistReason,
                retryOnClamp: false,
                replanAfterClamp: replanAfterClamp
            )
        case .failure(let error):
            reporter.error("\(operation) rejected after min-size observation: \(error.message)")
            return false
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
            let applyResult = LayoutApplier(axClient: axClient, reporter: reporter, echoSuppressor: echoSuppressor).apply(result)
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
    private func reloadConfig(reason: String) async {
        let loaded: StartupConfigLoad
        switch startupConfigLoad() {
        case .success(let value):
            loaded = value
        case .failure(let error):
            reporter.error("Config reload failed (\(reason)): \(error.description)")
            menubar.updateConfigStatus(.failed(error.description))
            return
        }

        do {
            try hotkeyManager?.rebind(loaded.config.keymap)
        } catch {
            let message = String(describing: error)
            reporter.error("Config reload failed rebinding hotkeys (\(reason)): \(message)")
            menubar.updateConfigStatus(.failed(message))
            return
        }

        config = loaded.config
        await worldActor.reloadConfig(loaded.config)
        overlay.updateConfig(border: loaded.config.border, hud: loaded.config.hud)
        eventTapClient?.updateModifier(loaded.config.dragModifier)
        logStartupConfig(loaded)
        menubar.updateConfigStatus(.loaded)
        reporter.info("Config reload completed (\(reason))")
    }

    @MainActor
    private func handleAXEvent(_ event: AXEvent, snapshot: FocusedWindowSnapshot?) async {
        switch event {
        case .windowFocused(let windowID):
            await worldActor.recordExternalFocus(windowID)
            if let snapshot {
                overlay.updateFocusBorder(.show(windowID, snapshot.frame))
            }
        case .windowMoved(let windowID, _), .windowResized(let windowID, _):
            if let snapshot {
                overlay.updateFocusBorder(.show(windowID, snapshot.frame))
            }
        case .windowOpened(let metadata):
            scheduleCoalescedEnvironmentRefresh(.windowOpened(metadata.id))
        case .windowClosed(let windowID):
            scheduleCoalescedEnvironmentRefresh(.windowClosed(windowID))
        }
    }

    @MainActor
    private func scheduleCoalescedEnvironmentRefresh(_ reason: EnvironmentRefreshReason) {
        let scheduled = scheduleEnvironmentRefresh(reason, in: environmentRefreshCoalescer)
        environmentRefreshCoalescer = scheduled.state

        environmentRefreshCoalescingTimer?.invalidate()
        let generation = scheduled.request.generation
        let timer = Timer(timeInterval: Self.environmentRefreshCoalescingDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.runCoalescedEnvironmentRefresh(generation: generation)
            }
        }
        environmentRefreshCoalescingTimer = timer
        environmentRefreshCoalescingTimerGeneration = generation
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func runCoalescedEnvironmentRefresh(generation: UInt64) async {
        if environmentRefreshCoalescingTimerGeneration == generation {
            environmentRefreshCoalescingTimer?.invalidate()
            environmentRefreshCoalescingTimer = nil
            environmentRefreshCoalescingTimerGeneration = nil
        }

        let fired = fireEnvironmentRefreshTimer(generation: generation, in: environmentRefreshCoalescer)
        environmentRefreshCoalescer = fired.state
        guard case .run(let request) = fired.decision else { return }

        let environment = await refreshEnvironment(reason: "coalesced \(request.description)")
        let completed: Bool
        if case .complete = environment.quality {
            completed = true
        } else {
            completed = false
        }

        let completion = completeEnvironmentRefresh(
            generation: request.generation,
            snapshotComplete: completed,
            in: environmentRefreshCoalescer
        )
        environmentRefreshCoalescer = completion.state
        switch completion.decision {
        case .cleared(let completedRequest):
            await persistRestore(reason: "coalesced \(completedRequest.description)")
        case .retained(let pending):
            reporter.info("Coalesced environment refresh retained pending generation \(pending.generation) after incomplete AX snapshot")
        case .stale, .idle:
            break
        }
    }

    @MainActor
    private func handleIPCCommand(_ command: IPCCommandDTO) async -> IPCReplyDTO {
        let commandID = CommandID(raw: "ipc-\(UUID().uuidString)")
        switch command {
        case .resetLayout:
            await worldActor.resetLayoutMemory()
            reporter.info("IPC reset layout memory: cleared BSP trees, floating lists, focus, pending rules, and observed window minimums")
            overlay.updateFocusBorder(.hide)
            await persistRestore(reason: "ipc reset")
            return .ok(commandID: commandID)
        case .quit:
            reporter.info("IPC quit requested")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                NSApplication.shared.terminate(nil)
            }
            return .ok(commandID: commandID)
        case .pushFocused(let direction):
            if await performPush(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "push_failed",
                message: "Focused push \(direction.rawValue) failed; see WinMgrApp log"
            )
        case .push(let windowID, let direction):
            if let failure = await performExplicitPush(windowID: windowID, direction: direction) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .swapFocused(let direction):
            if await performSwap(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "swap_failed",
                message: "Focused swap \(direction.rawValue) failed; see WinMgrApp log"
            )
        case .swap(let windowID, let direction):
            if let failure = await performExplicitSwap(windowID: windowID, direction: direction) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .center(let windowID):
            if let failure = await performExplicitCenter(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .focusDirection(let direction):
            if await performFocusDirection(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "focus_failed",
                message: "Focus \(direction.rawValue) failed; see WinMgrApp log"
            )
        case .focusCycle(let direction):
            if await performFocusCycle(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "focus_failed",
                message: "Focus cycle \(direction.rawValue) failed; see WinMgrApp log"
            )
        case .eject, .focus, .toggleFloat:
            return .error(
                commandID: commandID,
                code: "not_implemented",
                message: "IPC command is not implemented in the current build: \(command)"
            )
        }
    }

    @MainActor
    private func performExplicitPush(windowID: WindowID, direction: Direction) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(reason: "ipc push \(direction.rawValue)", displays: displays)
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC push requires a complete AX snapshot; got \(describe(environment.quality))"
            )
        }

        switch await worldActor.planPush(windowID, direction: direction) {
        case .success(let result):
            if await applyPlannedPush(result, direction: direction, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Push \(direction.rawValue) layout write failed; see WinMgrApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitCenter(windowID: WindowID) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(reason: "ipc center", displays: displays)
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC center requires a complete AX snapshot; got \(describe(environment.quality))"
            )
        }

        switch await worldActor.planCenter(windowID) {
        case .success(let result):
            if await applyPlannedCenter(result, windowID: windowID, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Center layout write failed; see WinMgrApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitSwap(windowID: WindowID, direction: Direction) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(reason: "ipc swap \(direction.rawValue)", displays: displays)
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC swap requires a complete AX snapshot; got \(describe(environment.quality))"
            )
        }

        switch await worldActor.planSwap(windowID, direction: direction) {
        case .success(let result):
            if await applyPlannedSwap(result, windowID: windowID, direction: direction, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Swap \(direction.rawValue) layout write failed; see WinMgrApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
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

private struct CommandExecutionFailure {
    let code: String
    let message: String
}

private struct FocusedLayoutContext {
    let snapshot: FocusedWindowSnapshot
    let displays: [DisplayID: DisplayInfo]
}

private func describe(_ template: CommandTemplate) -> String {
    switch template {
    case .push(let direction):
        return "push \(direction.rawValue)"
    case .center:
        return "center"
    case .eject:
        return "eject"
    case .swap(let direction):
        return "swap \(direction.rawValue)"
    case .focusDirection(let direction):
        return "focus \(direction.rawValue)"
    case .focusCycle(let direction):
        return "focus cycle \(direction.rawValue)"
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
