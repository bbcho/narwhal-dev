import AppKit
import CoreGraphics
import Darwin
import NarwhalAppSupport
import NarwhalCore
import NarwhalIPC

private enum StartupArgumentError: Error, CustomStringConvertible {
    case missingRestoreStatePath
    case missingDebugFailServiceStartName

    var description: String {
        switch self {
        case .missingRestoreStatePath:
            return "--restore-state requires a file path"
        case .missingDebugFailServiceStartName:
            return "--debug-fail-service-start requires a service name"
        }
    }
}

private enum ServiceStartupRequestError: Error, CustomStringConvertible {
    case startupArgument(StartupArgumentError)
    case failureInjection(ServiceStartFailureInjectionError)

    var description: String {
        switch self {
        case .startupArgument(let error):
            return error.description
        case .failureInjection(let error):
            return error.description
        }
    }
}

@MainActor
public enum NarwhalApplication {
    public static func main() {
        AppDelegate.main()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()
    private static let environmentRefreshCoalescingDelay: TimeInterval = 0.10
    private static let activeSpaceTransitionPreserveDuration: TimeInterval = 1.25
    private static let activeSpaceFocusRecoveryDuration: TimeInterval = 5.0
    private static let activeSpaceSettledRefreshDelays: [TimeInterval] = [0.35, 0.80]
    private static let displaySettledRefreshDelay: TimeInterval = 6.0
    private static let restoreSaveDebounceInterval: TimeInterval = 0.25

    private let axClient = AXClient()
    private let displayClient = DisplayClient()
    private let spaceClient = SpaceClient()
    private var restorePersistence = RestorePersistence(manager: RestoreManager())
    private let echoSuppressor = AXEchoSuppressor()
    private let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
    private var overlayModel = OverlayModel.empty
    private let menubar = Menubar()
    private var worldActor = WorldActor()
    private let reporter = StartupReporter()
    private var config = Config.default
    private var operatingStatus = MenubarOperatingStatus.empty
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
    private var displaySettledRefreshTimer: Timer?
    private var spaceSettledRefreshTimers: [Timer] = []
    private var spaceTransitionPreserveTimer: Timer?
    private var spaceTransitionPreservation = SpaceTransitionPreservationState.empty
    private var activeSpaceFocusRecoveryDeadline: Date?
    private var pendingHotkeys: [HotkeyAction] = []
    private var isDrainingHotkeys = false
    private var runningServices: RunningServices?
    private var servicesStarted = false
    private var isPaused = false

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let verifierFlag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--verify-") }) {
            print("NarwhalApp was built without verifier support; rerun \(verifierFlag) through scripts/live_verify_all.sh")
            Darwin.exit(2)
        }
        app.delegate = instance
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reporter.info("NarwhalApp started")
        reporter.info("Log file: \(StartupReporter.defaultLogPath)")

        guard configureRestoreManagerOrTerminate() else { return }

        if ProcessInfo.processInfo.arguments.contains("--check-config") {
            let ok = loadStartupConfig()
            reporter.info("NarwhalApp stopped")
            Darwin.exit(ok ? 0 : 1)
        }

        if ProcessInfo.processInfo.arguments.contains("--check-environment") {
            guard loadStartupConfig() else {
                reporter.info("NarwhalApp stopped")
                Darwin.exit(1)
            }
            let status = reportAccessibilityStatus(prompt: false)
            guard status.isTrusted else {
                reporter.error("Environment check skipped because Accessibility is not trusted")
                reporter.info("NarwhalApp stopped")
                Darwin.exit(1)
            }
            Task { @MainActor in
                let focused = reportFocusedWindowSnapshot()
                let environment = await refreshEnvironment(reason: "check")
                guard environment.activeSpace != nil else {
                    reporter.error("Environment check failed: active Space unavailable")
                    reporter.info("NarwhalApp stopped")
                    Darwin.exit(1)
                }
                if let focused {
                    await worldActor.recordExternalFocus(focused.id)
                }
                reporter.info("NarwhalApp stopped")
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
        restorePersistence.flushPending()
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        environmentRefreshCoalescingTimer?.invalidate()
        environmentRefreshCoalescingTimer = nil
        environmentRefreshCoalescingTimerGeneration = nil
        cancelDisplaySettledRefreshTimer()
        cancelSpaceTransitionTimers()
        runningServices?.stopAll()
        runningServices = nil
        servicesStarted = false
        overlay.stop()
        reporter.info("NarwhalApp stopped")
    }

    private func updateOperatingStatus(_ update: (inout MenubarOperatingStatus) -> Void) {
        update(&operatingStatus)
        menubar.updateOperatingStatus(operatingStatus)
    }

    private func showOperatorFeedback(_ message: String, tone: OverlayTone, showsHUD: Bool = true) {
        updateOperatingStatus { status in
            status.lastCommand = message
        }
        if showsHUD {
            overlay.showHUD(message, tone: tone)
        }
    }

    @discardableResult
    private func reportAccessibilityStatus(prompt: Bool) -> AccessibilityStatus {
        let status = AccessibilityTrust.current(prompt: prompt)
        switch status {
        case .trusted:
            reporter.info("Accessibility trusted")
            updateOperatingStatus { $0.accessibilityTrusted = true }
        case .notTrusted(let prompted):
            let promptState = prompted ? "prompted" : "not prompted"
            reporter.error("Accessibility not trusted (\(promptState))")
            updateOperatingStatus { $0.accessibilityTrusted = false }
            showOperatorFeedback("Accessibility permission is not trusted", tone: .error)
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
            updateFocusBorder(for: focused)
        }
        await applyStartupConverge()
        await applyPendingTileRules(reason: "startup")
        startServices()
    }

    private func reportFocusedWindowSnapshot() -> FocusedWindowSnapshot? {
        switch axClient.focusedWindowSnapshot() {
        case .success(let snapshot):
            reporter.info("Focused window: \(snapshot.logDescription)")
            updateOperatingStatus { $0.focusedWindowID = snapshot.id }
            return snapshot
        case .failure(let error):
            reporter.error("Focused-window snapshot failed: \(error.description)")
            showOperatorFeedback("Focused window unavailable", tone: .warning, showsHUD: false)
            return nil
        }
    }

    @MainActor
    private func updateFocusBorder(for snapshot: FocusedWindowSnapshot) {
        if snapshot.isFullscreen {
            setFocusBorder(nil)
        } else {
            setFocusBorder(snapshot.focusBorderTarget)
        }
    }

    @MainActor
    private func setFocusBorder(_ target: FocusBorderTarget?) {
        if let target {
            overlayModel = overlayModel.showingFocusBorder(target)
        } else {
            overlayModel = overlayModel.hidingFocusBorder()
        }
        overlay.render(overlayModel)
    }

    @MainActor
    private func suppressFocusBorder(for windowID: WindowID, frame: CGRect) {
        overlayModel = overlayModel.hidingFocusBorder()
        overlay.suppressFocusBorder(for: windowID, frame: frame)
        overlay.render(overlayModel)
    }

    @MainActor
    private func setTiledBorders(_ targets: [FocusBorderTarget]) {
        overlayModel = overlayModel.settingTiledBorders(targets)
        overlay.render(overlayModel)
    }

    @MainActor
    private func clearBorderOverlays() {
        overlayModel = .empty
        overlay.render(overlayModel)
    }

    @MainActor
    private func removeWindowFromOverlays(_ windowID: WindowID) {
        overlayModel = overlayModel.removingWindow(windowID)
        overlay.render(overlayModel)
    }

    private func focusBorderTarget(
        windowID: WindowID,
        frame: CGRect,
        windows: [WindowID: WindowMetadata]
    ) -> FocusBorderTarget {
        guard let window = windows[windowID] else {
            return FocusBorderTarget(windowID: windowID, frame: frame, traits: .standard)
        }
        return FocusBorderTarget(window: window, frame: frame)
    }

    @discardableResult
    @MainActor
    private func refreshEnvironment(
        reason: String,
        displays providedDisplays: [DisplayID: DisplayInfo]? = nil,
        preserveSpaceLayouts: Bool = false,
        reconciliationMode: EnvironmentReconciliationMode = .activeWorkspaceCleanup
    ) async -> EnvironmentRefreshResult {
        let displays = providedDisplays ?? displayClient.currentDisplays()
        let axSnapshot = axClient.windowSnapshot()
        let topology = spaceClient.spaceTopology(displays: displays, windows: axSnapshot.windows)
        let activeSpace: SpaceID?
        switch spaceClient.activeSpaceID() {
        case .success(let spaceID):
            activeSpace = spaceID
        case .failure(let error):
            activeSpace = topology.primaryActiveSpace
            if activeSpace == nil {
                reporter.error("Active Space refresh failed (\(reason)): \(error.description)")
            }
        }
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: displays,
            axSnapshot: axSnapshot,
            spaceTopology: topology,
            preserveSpaceLayouts: preserveSpaceLayouts,
            reconciliationMode: preserveSpaceLayouts ? .preserveLayouts : reconciliationMode
        )
        let result = await worldActor.refreshEnvironment(snapshot)
        let preserved = result.preservedSpaceLayouts ? " preservedSpaceLayouts=true" : ""
        reporter.info(
            "Environment refreshed (\(reason)): activeSpace=\(result.activeSpace?.raw.description ?? "nil") displays=\(result.displayCount) windows=\(result.windowCount) quality=\(AppDelegateText.describe(result.quality)) topology=\(topology.quality.rawValue) mode=\(snapshot.reconciliationMode.rawValue) mapped=\(result.mappedWindowCount)/\(result.observedWindowCount) spaceWindows=\(topology.windowSpace.count)\(preserved)"
        )
        updateOperatingStatus { status in
            status.activeSpace = result.activeSpace
            status.displayCount = result.displayCount
            status.windowCount = result.windowCount
            status.snapshotQuality = result.quality
        }
        await updateTiledBordersFromWorld()
        return result
    }

    @MainActor
    private func updateTiledBordersFromWorld() async {
        switch await worldActor.tiledBorderTargets() {
        case .success(let targets):
            setTiledBorders(targets)
        case .failure(let error):
            reporter.error("Tiled border refresh failed: \(error.message)")
            setTiledBorders([])
        }
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
            let manager = RestoreManager(url: url)
            restorePersistence = restorePersistence(for: manager)
            if url != RestoreManager.defaultURL {
                reporter.info("Using restore state path \(url.path)")
            }
            return true
        case .failure(let error):
            reporter.error(error.description)
            reporter.info("NarwhalApp stopped")
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

    private func restorePersistence(for manager: RestoreManager) -> RestorePersistence {
        RestorePersistence(
            manager: manager,
            debounceInterval: Self.restoreSaveDebounceInterval
        ) { [reporter] event in
            logRestoreSaveEvent(event, reporter: reporter)
        }
    }

    private func debugServiceStartFailureFromArguments() -> Result<String?, StartupArgumentError> {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--debug-fail-service-start") else {
            return .success(nil)
        }
        let nameIndex = arguments.index(after: index)
        guard arguments.indices.contains(nameIndex) else {
            return .failure(.missingDebugFailServiceStartName)
        }
        return .success(arguments[nameIndex])
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
            terminateAfterFlushingRestore()
        }
    }

    private func startServices() {
        guard !servicesStarted else { return }

        let steps: [ServiceStartStep]
        switch serviceStartStepsFromArguments() {
        case .success(let value):
            steps = value
        case .failure(let error):
            reporter.error(error.description)
            reporter.info("Runtime service startup failed; terminating")
            NSApplication.shared.terminate(nil)
            return
        }

        switch startServiceSequence(steps) {
        case .success(let services):
            runningServices = services
            servicesStarted = true
            reporter.info("Layout command loop ready")
        case .failure(let error):
            runningServices = nil
            servicesStarted = false
            reporter.error(error.description)
            reporter.info("Runtime service startup failed; terminating")
            NSApplication.shared.terminate(nil)
        }
    }

    private func serviceStartStepsFromArguments() -> Result<[ServiceStartStep], ServiceStartupRequestError> {
        let failureTarget: String?
        switch debugServiceStartFailureFromArguments() {
        case .success(let value):
            failureTarget = value
        case .failure(let error):
            return .failure(.startupArgument(error))
        }

        switch NarwhalAppSupport.serviceStartSteps(serviceStartSteps(), injectingFailureAt: failureTarget) {
        case .success(let steps):
            return .success(steps)
        case .failure(let error):
            return .failure(.failureInjection(error))
        }
    }

    private func serviceStartSteps() -> [ServiceStartStep] {
        [
            ServiceStartStep(name: "menubar") {
                self.startMenubar()
                return { [weak self] in
                    self?.menubar.stop()
                }
            },
            ServiceStartStep(name: "hotkeys") {
                try self.installHotkeys()
            },
            ServiceStartStep(name: "axObserver") {
                self.installAXObserver()
            },
            ServiceStartStep(name: "displayObserver") {
                self.installDisplayObserver()
            },
            ServiceStartStep(name: "configWatcher") {
                try self.installConfigFileWatcher()
            },
            ServiceStartStep(name: "ipcServer") {
                try self.installIPCServer()
            },
            ServiceStartStep(name: "dragZones") {
                try self.installEventTap()
            }
        ]
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
            quit: { [weak self] in
                Task { @MainActor in
                    self?.terminateAfterFlushingRestore()
                }
            }
        )
        menubar.updateConfigStatus(.loaded)
        menubar.updateOperatingStatus(operatingStatus)
    }

    @MainActor
    private func installHotkeys() throws -> ServiceStop {
        let manager = HotkeyManager(bindings: config.keymap, reporter: reporter) { [weak self] action in
            Task { @MainActor in
                self?.enqueueHotkey(action)
            }
        }
        try manager.start()
        hotkeyManager = manager
        return { [weak self, manager] in
            manager.stop()
            if self?.hotkeyManager === manager {
                self?.hotkeyManager = nil
            }
        }
    }

    @MainActor
    private func installAXObserver() -> ServiceStop {
        guard axObserverService == nil else {
            return {}
        }
        let service = AXObserverService(
            axClient: axClient,
            echoSuppressor: echoSuppressor,
            reporter: reporter,
            activeSpaceByDisplay: { [weak self] windows in
                guard let self else { return [:] }
                let displays = self.displayClient.currentDisplays()
                return self.spaceClient
                    .spaceTopology(displays: displays, windows: windows)
                    .activeSpaceByDisplay
            },
            spaceChanged: { [weak self] in
                self?.activeSpaceChanged()
            }
        ) { [weak self] event, snapshot in
            Task { @MainActor in
                await self?.handleAXEvent(event, snapshot: snapshot)
            }
        }
        service.start()
        axObserverService = service
        return { [weak self, service] in
            self?.cancelSpaceTransitionTimers()
            service.stop()
            if self?.axObserverService === service {
                self?.axObserverService = nil
            }
        }
    }

    @MainActor
    private func installDisplayObserver() -> ServiceStop {
        guard displayObserverService == nil else {
            return {}
        }
        let service = DisplayObserverService(reporter: reporter) { [weak self] in
            self?.setTiledBorders([])
            self?.cancelDisplaySettledRefreshTimer()
            self?.scheduleCoalescedEnvironmentRefresh(.displayChanged)
        }
        service.start()
        displayObserverService = service
        return { [weak self, service] in
            service.stop()
            if self?.displayObserverService === service {
                self?.displayObserverService = nil
            }
        }
    }

    @MainActor
    private func installConfigFileWatcher() throws -> ServiceStop {
        guard configFileWatcherService == nil else {
            return {}
        }
        switch startupConfigRequestFromArguments() {
        case .success(let request):
            let service = ConfigFileWatcherService(configURL: request.url, reporter: reporter) { [weak self] in
                Task { @MainActor in
                    await self?.reloadConfig(reason: "file watcher")
                }
            }
            service.start()
            configFileWatcherService = service
            return { [weak self, service] in
                service.stop()
                if self?.configFileWatcherService === service {
                    self?.configFileWatcherService = nil
                }
            }
        case .failure(let error):
            throw error
        }
    }

    @MainActor
    private func installIPCServer() throws -> ServiceStop {
        guard ipcServer == nil else {
            return {}
        }
        let server = IPCServer(
            socketPath: IPCDefaults.socketPath,
            handle: { [weak self] command in
                await self?.handleIPCCommand(command) ?? .error(
                    commandID: CommandID(raw: "app-unavailable"),
                    code: "app_unavailable",
                    message: "NarwhalApp is not available"
                )
            },
            log: { [weak self] message in
                Task { @MainActor in
                    self?.reporter.error(message)
                }
            }
        )
        try server.start()
        ipcServer = server
        reporter.info("IPC server ready at \(IPCDefaults.socketPath)")
        return { [weak self, server] in
            server.stop()
            if self?.ipcServer === server {
                self?.ipcServer = nil
            }
        }
    }

    @MainActor
    private func installEventTap() throws -> ServiceStop {
        guard eventTapClient == nil else {
            return {}
        }
        let client = EventTapClient(
            modifier: config.dragModifier,
            reporter: reporter,
            dragChanged: { [weak self] location in
                Task { @MainActor in
                    self?.previewDragDrop(at: location)
                }
            },
            dragEnded: { [weak self] in
                Task { @MainActor in
                    self?.overlay.hideDragPreview()
                }
            },
            drop: { [weak self] location in
                Task { @MainActor in
                    await self?.performDragDrop(at: location)
                }
            }
        )
        try client.start()
        eventTapClient = client
        return { [weak self, client] in
            client.stop()
            if self?.eventTapClient === client {
                self?.eventTapClient = nil
            }
        }
    }

    @MainActor
    private func enqueueHotkey(_ action: HotkeyAction) {
        let maxPendingHotkeys = 32
        if pendingHotkeys.count >= maxPendingHotkeys {
            pendingHotkeys.removeFirst(pendingHotkeys.count - maxPendingHotkeys + 1)
            reporter.info("Hotkey queue trimmed to \(maxPendingHotkeys) pending action(s)")
        }
        pendingHotkeys.append(action)
        guard !isDrainingHotkeys else { return }
        isDrainingHotkeys = true
        Task { @MainActor in
            await self.drainHotkeyQueue()
        }
    }

    @MainActor
    private func drainHotkeyQueue() async {
        while !pendingHotkeys.isEmpty {
            let action = pendingHotkeys.removeFirst()
            await performHotkey(action)
        }
        isDrainingHotkeys = false
    }

    @MainActor
    private func performHotkey(_ action: HotkeyAction) async {
        if routeCommandOverlayHotkey(action) {
            return
        }

        if isPaused, pausesTilingBlocks(action) {
            reporter.info("Hotkey ignored while Narwhal is paused: \(AppDelegateText.describe(action))")
            showOperatorFeedback("Narwhal paused", tone: .warning, showsHUD: false)
            return
        }

        guard await waitForStableWorkspaceIfNeeded(for: action) else {
            return
        }

        switch action {
        case .command(.push(let direction)):
            await performPush(direction)
        case .command(.center):
            await performCenter()
        case .command(.eject):
            await performEject()
        case .command(.toggleFloat):
            await performToggleFloat()
        case .command(.balance):
            await performBalance()
        case .command(.shuffle):
            await performShuffle()
        case .command(.cascade):
            await performCascade()
        case .command(.maximizeReset):
            await performMaximizeReset()
        case .command(.swap(let direction)):
            await performSwap(direction)
        case .command(.resizeSplit(let direction, let delta)):
            await performResize(direction, delta: delta)
        case .command(.focusDirection(let direction)):
            await performFocusDirection(direction)
        case .command(.focusCycle(let direction)):
            await performFocusCycle(direction)
        case .command(.focusPrevious):
            await performFocusPrevious()
        case .command(.undoLayout):
            await performUndoLayout()
        case .command(.moveToNextDisplay):
            await performMoveToNextDisplay()
        case .command(.togglePause):
            await togglePause()
        case .command(.resetLayout):
            await performResetLayout(requiresConfirmation: true, logPrefix: "Reset", persistReason: "reset")
        case .openFinderWindow:
            performOpenFinderWindow()
        case .command(let template):
            reporter.error("Hotkey action not implemented in this build: \(AppDelegateText.describe(template))")
            showOperatorFeedback("Command unavailable: \(AppDelegateText.describe(template))", tone: .error)
        case .reloadConfig:
            await reloadConfig(reason: "hotkey")
        case .showCommands:
            overlay.toggleCommandOverlay(
                bindings: config.keymap,
                dragModifier: config.dragModifier,
                zones: config.zones
            )
        }
    }

    @MainActor
    private func waitForStableWorkspaceIfNeeded(for action: HotkeyAction) async -> Bool {
        guard workspaceStabilityPolicy(for: action) == .waitForStableWorkspace,
              spaceTransitionPreservation.isPreservingSpaceLayouts
        else { return true }

        let description = AppDelegateText.describe(action)
        reporter.info("Hotkey waiting for Space transition to settle: \(description)")
        let deadline = Date().addingTimeInterval(Self.activeSpaceTransitionPreserveDuration + 0.5)
        while spaceTransitionPreservation.isPreservingSpaceLayouts && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !spaceTransitionPreservation.isPreservingSpaceLayouts else {
            reporter.error("Hotkey skipped because Space transition did not settle: \(description)")
            showOperatorFeedback("Space still settling", tone: .warning, showsHUD: false)
            return false
        }
        return true
    }

    private func pausesTilingBlocks(_ action: HotkeyAction) -> Bool {
        switch action {
        case .command(let template):
            switch template {
            case .push, .center, .eject, .swap, .resizeSplit, .toggleFloat, .balance, .shuffle, .cascade, .maximizeReset, .undoLayout, .moveToNextDisplay:
                return true
            case .focusDirection, .focusCycle, .focusPrevious, .togglePause, .resetLayout:
                return false
            }
        case .openFinderWindow, .reloadConfig, .showCommands:
            return false
        }
    }

    @MainActor
    private func routeCommandOverlayHotkey(_ action: HotkeyAction) -> Bool {
        guard overlay.isCommandOverlayVisible else { return false }
        switch action {
        case .showCommands:
            overlay.hideCommandOverlay()
            return true
        case .command(.focusDirection(.up)):
            overlay.scrollCommandOverlay(.up)
            return true
        case .command(.focusDirection(.down)):
            overlay.scrollCommandOverlay(.down)
            return true
        default:
            return false
        }
    }

    @MainActor
    private func performOpenFinderWindow() {
        do {
            try FinderWindowOpener.openHomeWindow()
            reporter.info("Opened Finder window")
            showOperatorFeedback("Finder window opened", tone: .success, showsHUD: false)
        } catch {
            reporter.error("Open Finder window failed: \(String(describing: error))")
            showOperatorFeedback("Open Finder failed", tone: .error)
        }
    }

    @MainActor
    @discardableResult
    private func performResetLayout(
        requiresConfirmation: Bool,
        logPrefix: String,
        persistReason: String
    ) async -> Bool {
        if requiresConfirmation, !confirmResetLayout() {
            showOperatorFeedback("Reset canceled", tone: .info)
            return false
        }

        await worldActor.resetLayoutMemory()
        reporter.info("\(logPrefix) layout memory: cleared BSP trees, floating lists, focus, pending rules, and observed window minimums")
        clearBorderOverlays()
        updateOperatingStatus { $0.focusedWindowID = nil }
        showOperatorFeedback("Layout memory reset", tone: .warning)
        await persistRestore(reason: persistReason)
        return true
    }

    @MainActor
    private func confirmResetLayout() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset Narwhal layout memory?"
        alert.informativeText = "This clears tracked tiling state, floating order, focus memory, pending rules, and observed window minimums for the current stored world."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    @discardableResult
    private func performFocusDirection(_ direction: Direction) async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus \(direction.rawValue) skipped because Accessibility is not trusted")
            showOperatorFeedback("Focus failed: Accessibility not trusted", tone: .error)
            return false
        }

        let axFocusedWindowID: WindowID?
        let axFocusError: AXClientError?
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            axFocusedWindowID = value.id
            axFocusError = nil
        case .failure(let error):
            axFocusedWindowID = nil
            axFocusError = error
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(
            reason: "pre-focus \(direction.rawValue)",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Focus \(direction.rawValue) rejected before planning: active Space unavailable")
            showOperatorFeedback("Focus failed: active Space unavailable", tone: .error)
            return false
        }
        let focusedWindowID: WindowID
        if let axFocusedWindowID {
            focusedWindowID = axFocusedWindowID
            await worldActor.recordExternalFocus(axFocusedWindowID)
        } else if let fallback = await worldActor.focusedWindowFallback() {
            focusedWindowID = fallback.id
            reporter.info("Focus \(direction.rawValue) using stored focus fallback \(fallback.id.description) after AX focus read failed: \(axFocusError?.description ?? "unknown")")
        } else {
            reporter.error("Focus \(direction.rawValue) failed reading focused window: \(axFocusError?.description ?? "unknown")")
            showOperatorFeedback("Focus failed: no focused window", tone: .error)
            return false
        }

        switch await worldActor.planFocusDirection(from: focusedWindowID, direction: direction) {
        case .success(let result):
            return await focusWindow(result, reason: "focus \(direction.rawValue)")
        case .failure(let error):
            if case .noNeighbor = error {
                reporter.info("Focus \(direction.rawValue) has no neighboring window")
                showOperatorFeedback("No window \(direction.rawValue)", tone: .info, showsHUD: false)
                return false
            }
            reporter.error("Focus \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Focus failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performFocusCycle(_ direction: FocusCycleDirection) async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus cycle \(direction.rawValue) skipped because Accessibility is not trusted")
            showOperatorFeedback("Focus cycle failed: Accessibility not trusted", tone: .error)
            return false
        }

        var focusedWindowID: WindowID?
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            focusedWindowID = value.id
        case .failure:
            focusedWindowID = nil
        }

        let environment = await refreshEnvironment(
            reason: "pre-focus-cycle \(direction.rawValue)",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Focus cycle \(direction.rawValue) rejected before planning: active Space unavailable")
            showOperatorFeedback("Focus cycle failed: active Space unavailable", tone: .error)
            return false
        }
        if let focusedWindowID {
            await worldActor.recordExternalFocus(focusedWindowID)
        } else if let fallback = await worldActor.focusedWindowFallback() {
            focusedWindowID = fallback.id
            await worldActor.recordExternalFocus(fallback.id)
        }

        switch await worldActor.planFocusCycleCandidates(from: focusedWindowID, direction: direction) {
        case .success(let results):
            reporter.info("Focus cycle \(direction.rawValue) planned \(results.count) candidate(s)")
            for (index, result) in results.enumerated() {
                if await focusWindow(
                    result,
                    reason: "focus cycle \(direction.rawValue)",
                    suppressFailureFeedback: index < results.count - 1
                ) {
                    return true
                }
            }
            reporter.error("Focus cycle \(direction.rawValue) exhausted \(results.count) candidate(s)")
            showOperatorFeedback("Focus cycle failed", tone: .error)
            return false
        case .failure(let error):
            reporter.error("Focus cycle \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Focus cycle failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performFocusPrevious() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus previous skipped because Accessibility is not trusted")
            showOperatorFeedback("Focus previous failed: Accessibility not trusted", tone: .error)
            return false
        }

        var focusedWindowID: WindowID?
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            focusedWindowID = value.id
        case .failure:
            focusedWindowID = nil
        }

        let environment = await refreshEnvironment(
            reason: "pre-focus-previous",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Focus previous rejected before planning: active Space unavailable")
            showOperatorFeedback("Focus previous failed: active Space unavailable", tone: .error)
            return false
        }
        if let focusedWindowID {
            await worldActor.recordExternalFocus(focusedWindowID)
        } else if let fallback = await worldActor.focusedWindowFallback() {
            focusedWindowID = fallback.id
            await worldActor.recordExternalFocus(fallback.id)
        }

        switch await worldActor.planFocusPrevious(from: focusedWindowID) {
        case .success(let result):
            return await focusWindow(result, reason: "focus previous")
        case .failure(let error):
            reporter.error("Focus previous rejected by core: \(error.message)")
            showOperatorFeedback("Focus previous failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    private func focusWindow(
        _ result: FocusPlanResult,
        reason: String,
        suppressFailureFeedback: Bool = false
    ) async -> Bool {
        switch axClient.focusWindow(result.window) {
        case .success:
            echoSuppressor.expectFocus(windowID: result.window.id)
            await worldActor.recordExternalFocus(result.window.id)
            updateOperatingStatus { $0.focusedWindowID = result.window.id }
            setFocusBorder(FocusBorderTarget(window: result.window, frame: result.frame))
            reporter.info("\(reason) completed target=\(result.window.id.description)")
            showOperatorFeedback("\(reason) -> \(result.window.id.description)", tone: .success, showsHUD: false)
            return true
        case .failure(let error):
            reporter.error("\(reason) failed focusing \(result.window.id.description): \(error.description)")
            if shouldRemoveFailedFocusTarget(error, reason: reason) {
                await worldActor.removeWindowFromActiveSpace(result.window.id)
                await updateTiledBordersFromWorld()
                reporter.info("Removed stale focus target \(result.window.id.description) from active Space after focus failure")
            }
            if !suppressFailureFeedback {
                showOperatorFeedback("\(reason) failed", tone: .error)
            }
            return false
        }
    }

    private func shouldRemoveFailedFocusTarget(_ error: AXClientError, reason: String) -> Bool {
        let isCycling = reason.hasPrefix("focus cycle") || reason == "focus previous"
        switch error {
        case .windowElementNotFound:
            return true
        case .performActionFailed(let action, let axError):
            return isCycling && action == kAXRaiseAction && axError == .cannotComplete
        case .applicationActivateFailed:
            return isCycling
        case .copyAttributeFailed,
             .missingFocusedWindow,
             .focusedWindowWrongType,
             .pidUnavailable,
             .pointAttributeInvalid,
             .sizeAttributeInvalid,
             .boolAttributeInvalid,
             .focusedWindowUnmatchedToCGWindow,
             .windowsAttributeInvalid,
             .setAttributeFailed,
             .frameDidNotConverge,
             .visibleWindowListUnavailable,
             .windowNotRaised:
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performUndoLayout() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Undo skipped because Accessibility is not trusted")
            showOperatorFeedback("Undo failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironment(
            reason: "pre-undo",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Undo rejected before planning: active Space unavailable")
            showOperatorFeedback("Undo failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Undo rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Undo failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planUndoLastLayout() {
        case .success(nil):
            reporter.info("Undo skipped: no previous layout")
            showOperatorFeedback("Nothing to undo", tone: .warning, showsHUD: false)
            return false
        case .success(let result?):
            return await applyPlannedUndo(result, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Undo rejected by core: \(error.message)")
            showOperatorFeedback("Undo failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performPush(_ direction: Direction) async -> Bool {
        let operation = "Push \(direction.rawValue)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-push \(direction.rawValue)")
        else { return false }

        switch await worldActor.planPush(context.id, direction: direction) {
        case .success(let result):
            return await applyPlannedPush(result, direction: direction, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Push failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performCenter() async -> Bool {
        let operation = "Center"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-center")
        else { return false }

        switch await worldActor.planCenter(context.id) {
        case .success(let result):
            return await applyPlannedCenter(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Center rejected by core: \(error.message)")
            showOperatorFeedback("Center failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performEject() async -> Bool {
        let operation = "Eject"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-eject")
        else { return false }

        switch await worldActor.planEject(context.id) {
        case .success(let result):
            return await applyPlannedEject(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Eject rejected by core: \(error.message)")
            showOperatorFeedback("Eject failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performToggleFloat() async -> Bool {
        let operation = "Toggle float"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-toggle-float")
        else { return false }

        switch await worldActor.planToggleFloat(context.id) {
        case .success(let result):
            return await applyPlannedToggleFloat(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Toggle float rejected by core: \(error.message)")
            showOperatorFeedback("Toggle float failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performSwap(_ direction: Direction) async -> Bool {
        let operation = "Swap \(direction.rawValue)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-swap \(direction.rawValue)")
        else { return false }

        switch await worldActor.planSwap(context.id, direction: direction) {
        case .success(let result):
            return await applyPlannedSwap(result, windowID: context.id, direction: direction, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Swap \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Swap failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performResize(_ direction: Direction, delta: Double) async -> Bool {
        let operation = "Resize \(direction.rawValue) \(delta)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-resize \(direction.rawValue)")
        else { return false }

        switch await worldActor.planResize(context.id, direction: direction, delta: delta) {
        case .success(let result):
            return await applyPlannedResize(
                result,
                windowID: context.id,
                direction: direction,
                delta: delta,
                retryOnClamp: true
            )
        case .failure(let error):
            reporter.error("Resize \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Resize failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performMoveToNextDisplay() async -> Bool {
        let operation = "Move display"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-move-display")
        else { return false }

        switch await worldActor.planMoveToNextDisplay(context.id) {
        case .success(let result):
            return await applyPlannedMoveToNextDisplay(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Move display rejected by core: \(error.message)")
            showOperatorFeedback("Move display failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performBalance() async -> Bool {
        let operation = "Balance"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation)
        else { return false }
        guard await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-balance") else {
            return false
        }

        switch await worldActor.planBalanceWorkspace(containing: context.id) {
        case .success(let result):
            return await applyPlannedBalance(
                result,
                operation: operation,
                persistReason: "balance",
                retryOnClamp: true
            ) {
                await self.worldActor.planBalanceWorkspace(containing: context.id)
            }
        case .failure(let error):
            reporter.error("Balance rejected by core: \(error.message)")
            showOperatorFeedback("Balance failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performShuffle() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Shuffle skipped because Accessibility is not trusted")
            showOperatorFeedback("Shuffle failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironment(
            reason: "pre-shuffle",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Shuffle rejected before planning: active Space unavailable")
            showOperatorFeedback("Shuffle failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Shuffle rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Shuffle failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planShuffleActiveSpace() {
        case .success(let result):
            let completed = await applyPlannedShuffle(result, retryOnClamp: true)
            if completed {
                setFocusBorder(nil)
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
            return completed
        case .failure(let error):
            reporter.error("Shuffle rejected by core: \(error.message)")
            showOperatorFeedback("Shuffle failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performCascade() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Cascade skipped because Accessibility is not trusted")
            showOperatorFeedback("Cascade failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironment(
            reason: "pre-cascade",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Cascade rejected before planning: active Space unavailable")
            showOperatorFeedback("Cascade failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Cascade rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Cascade failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planCascadeActiveSpace() {
        case .success(let result):
            let completed = await applyPlannedCascade(result, retryOnClamp: true)
            if completed {
                setFocusBorder(nil)
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
            return completed
        case .failure(let error):
            reporter.error("Cascade rejected by core: \(error.message)")
            showOperatorFeedback("Cascade failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performMaximizeReset() async -> Bool {
        let operation = "Max reset"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-max-reset")
        else { return false }

        switch await worldActor.planMaximizeReset(context.id) {
        case .success(let result):
            return await applyPlannedMaximizeReset(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Max reset rejected by core: \(error.message)")
            showOperatorFeedback("Max reset failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    private func previewDragDrop(at location: CGPoint) {
        guard !isPaused else {
            overlay.hideDragPreview()
            return
        }
        guard let preview = dragPreview(at: location, displays: displayClient.currentDisplays()) else {
            overlay.hideDragPreview()
            return
        }
        overlay.showDragPreview(frame: preview.frame, title: preview.title, valid: preview.valid)
    }

    private func dragPreview(at location: CGPoint, displays: [DisplayID: DisplayInfo]) -> DragZonePreview? {
        guard let display = displays.values
            .filter({ AppDelegateGeometry.contains(location, in: $0.visibleFrame) })
            .sorted(by: { $0.id.raw < $1.id.raw })
            .first
        else {
            return nil
        }
        guard display.visibleFrame.width > 0, display.visibleFrame.height > 0 else { return nil }

        let proportional = CGPoint(
            x: (location.x - display.visibleFrame.minX) / display.visibleFrame.width,
            y: (location.y - display.visibleFrame.minY) / display.visibleFrame.height
        )
        let matches = config.zones.filter { AppDelegateGeometry.contains(proportional, in: $0.bounds) }
        guard matches.count == 1, let zone = matches.first else {
            if matches.count > 1 {
                return DragZonePreview(
                    frame: AppDelegateGeometry.badgeFrame(around: location),
                    title: "Overlapping zones",
                    valid: false
                )
            }
            return nil
        }

        return DragZonePreview(
            frame: AppDelegateGeometry.absoluteFrame(for: zone.bounds, in: display.visibleFrame),
            title: "Drop: \(AppDelegateText.dropActionDescription(zone.action))",
            valid: true
        )
    }

    @MainActor
    private func performDragDrop(at location: CGPoint) async {
        overlay.hideDragPreview()
        guard !isPaused else {
            reporter.info("Drag drop ignored while Narwhal is paused")
            showOperatorFeedback("Narwhal paused", tone: .warning, showsHUD: false)
            return
        }
        let operation = "Drag drop"
        guard let context = await focusedLayoutContext(operation: operation) else { return }
        let drag = DragEvent(windowID: context.id, location: location, displayID: nil)
        guard let command = resolveDrop(drag, zones: config.zones, displays: context.displays) else {
            reporter.info("Drag drop ignored: no matching exclusive zone at \(location.debugDescription)")
            showOperatorFeedback("No drop zone", tone: .warning)
            return
        }
        guard case .dropAtZone(let windowID, let displayID, let zoneID) = command else {
            reporter.error("Drag drop resolved to unsupported command: \(command)")
            return
        }

        reporter.info(
            "Drag drop resolved focused=\(context.id.description) display=\(displayID.raw) zone=\(zoneID.raw) location=\(location.debugDescription)"
        )
        guard await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-drag drop") else { return }

        switch await worldActor.planDrop(windowID: windowID, displayID: displayID, zoneID: zoneID) {
        case .success(let result):
            _ = await applyPlannedDrop(result, windowID: windowID, displayID: displayID, zoneID: zoneID, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Drag drop rejected by core: \(error.message)")
            showOperatorFeedback("Drag drop failed: \(error.message)", tone: .error)
        }
    }

    @MainActor
    private func focusedLayoutContext(operation: String) async -> FocusedLayoutContext? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("\(operation) skipped because Accessibility is not trusted")
            showOperatorFeedback("\(operation) failed: Accessibility not trusted", tone: .error)
            return nil
        }

        let focused: FocusedLayoutContext
        if let snapshot = focusedWindowSnapshotForLayoutOperation(operation) {
            focused = FocusedLayoutContext(metadata: snapshot.metadata, displays: displayClient.currentDisplays())
        } else {
            let error = focusedWindowReadError()
            let displays = displayClient.currentDisplays()
            _ = await refreshEnvironment(
                reason: "\(operation.lowercased()) focus fallback",
                displays: displays,
                reconciliationMode: .observeOnly
            )
            if let fallback = await worldActor.focusedWindowFallback() {
                reporter.info("\(operation) using stored focused-window fallback \(fallback.id.description) after AX focus read failed: \(error.description)")
                focused = FocusedLayoutContext(metadata: fallback, displays: displays)
            } else if let recovered = await waitForFocusedLayoutContextAfterSpaceChange(
                operation: operation,
                initialError: error
            ) {
                focused = recovered
            } else {
                reporter.error("\(operation) failed reading focused window: \(error.description)")
                showOperatorFeedback("\(operation) failed: no focused window", tone: .error)
                return nil
            }
        }

        guard focused.metadata.role == "AXWindow" else {
            reporter.error("\(operation) failed: focused element is not a window")
            showOperatorFeedback("\(operation) failed: no focused window", tone: .error)
            return nil
        }

        reporter.info("\(operation) focused \(focused.logDescription)")
        logDisplays(focused.displays)
        return focused
    }

    @MainActor
    private func focusedWindowSnapshotForLayoutOperation(_ operation: String) -> FocusedWindowSnapshot? {
        for attempt in 0..<4 {
            if case .success(let snapshot) = axClient.focusedWindowSnapshot() {
                activeSpaceFocusRecoveryDeadline = nil
                return snapshot
            }
            if attempt < 3 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            }
        }
        return nil
    }

    @MainActor
    private func waitForFocusedLayoutContextAfterSpaceChange(
        operation: String,
        initialError: AXClientError
    ) async -> FocusedLayoutContext? {
        guard let deadline = activeSpaceFocusRecoveryDeadline,
              Date() < deadline
        else { return nil }

        reporter.info("\(operation) waiting for focused window after Space transition: \(initialError.description)")
        var nextRefresh = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            if case .success(let snapshot) = axClient.focusedWindowSnapshot() {
                activeSpaceFocusRecoveryDeadline = nil
                return FocusedLayoutContext(metadata: snapshot.metadata, displays: displayClient.currentDisplays())
            }

            let displays = displayClient.currentDisplays()
            if let fallback = await worldActor.focusedWindowFallback() {
                reporter.info("\(operation) recovered stored focused-window fallback \(fallback.id.description) after Space transition")
                return FocusedLayoutContext(metadata: fallback, displays: displays)
            }
            if Date() >= nextRefresh {
                _ = await refreshEnvironment(
                    reason: "\(operation.lowercased()) focus recovery",
                    displays: displays,
                    reconciliationMode: .observeOnly
                )
                nextRefresh = Date().addingTimeInterval(0.45)
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        activeSpaceFocusRecoveryDeadline = nil
        return nil
    }

    @MainActor
    private func focusedWindowReadError() -> AXClientError {
        switch axClient.focusedWindowSnapshot() {
        case .success:
            return .missingFocusedWindow
        case .failure(let value):
            return value
        }
    }

    @MainActor
    private func displayForFocusedWindow(_ context: FocusedLayoutContext, operation: String) -> DisplayID? {
        guard let displayID = displayClient.displayContaining(frame: context.frame, displays: context.displays) else {
            reporter.error("\(operation) failed: no display for focused window")
            showOperatorFeedback("\(operation) failed: no display for focus", tone: .error)
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
        let environment = await refreshEnvironment(
            reason: refreshReason,
            displays: context.displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("\(operation) rejected before planning: active Space unavailable")
            showOperatorFeedback("\(operation) failed: active Space unavailable", tone: .error)
            return false
        }

        switch await worldActor.upsertWindow(context.metadata, displayID: displayID, displays: context.displays) {
        case .success:
            return true
        case .failure(let error):
            reporter.error("\(operation) failed updating focused window state: \(error.message)")
            showOperatorFeedback("\(operation) failed: \(error.message)", tone: .error)
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
    private func applyPlannedEject(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Eject",
            persistReason: "eject",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planEject(windowID)
        }
    }

    @MainActor
    private func applyPlannedToggleFloat(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Toggle float",
            persistReason: "toggle float",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planToggleFloat(windowID)
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
    private func applyPlannedResize(
        _ result: CommandPlanResult,
        windowID: WindowID,
        direction: Direction,
        delta: Double,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Resize \(direction.rawValue) \(delta)",
            persistReason: "resize \(direction.rawValue) \(delta)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planResize(windowID, direction: direction, delta: delta)
        }
    }

    @MainActor
    private func applyPlannedMoveToNextDisplay(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Move display",
            persistReason: "move display",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planMoveToNextDisplay(windowID)
        }
    }

    @MainActor
    private func applyPlannedShuffle(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Shuffle",
            persistReason: "shuffle",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planShuffleActiveSpace()
        }
    }

    @MainActor
    private func applyPlannedCascade(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Cascade",
            persistReason: "cascade",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planCascadeActiveSpace()
        }
    }

    @MainActor
    private func applyPlannedMaximizeReset(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Max reset",
            persistReason: "max reset",
            retryOnClamp: retryOnClamp,
            showFocusBorder: false
        ) {
            await self.worldActor.planMaximizeReset(windowID)
        }
    }

    @MainActor
    private func applyPlannedUndo(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Undo",
            persistReason: "undo",
            retryOnClamp: retryOnClamp
        ) {
            await self.requireUndoLayoutPlan()
        }
    }

    @MainActor
    private func applyPlannedPendingTileRules(
        _ result: CommandPlanResult,
        reason: String,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Open rules",
            persistReason: "open rules \(reason)",
            retryOnClamp: retryOnClamp
        ) {
            await self.requirePendingTileRulePlan()
        }
    }

    private func requireUndoLayoutPlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planUndoLastLayout() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.configInvalid("nothing to undo"))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func requirePendingTileRulePlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planPendingTileRules() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.configInvalid("no pending tile rule"))
        case .failure(let error):
            return .failure(error)
        }
    }

    @MainActor
    private func applyPlannedBalance(
        _ result: CommandPlanResult,
        operation: String,
        persistReason: String,
        retryOnClamp: Bool,
        replanAfterClamp: @escaping () async -> Result<CommandPlanResult, CommandError>
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: operation,
            persistReason: persistReason,
            retryOnClamp: retryOnClamp
        ) { await replanAfterClamp() }
    }

    @MainActor
    private func applyPlannedLayout(
        _ result: CommandPlanResult,
        operation: String,
        persistReason: String,
        retryOnClamp: Bool,
        showFocusBorder: Bool = true,
        replanAfterClamp: () async -> Result<CommandPlanResult, CommandError>
    ) async -> Bool {
        let applyResult = LayoutApplier(axClient: axClient, reporter: reporter, echoSuppressor: echoSuppressor).apply(result)
        switch plannedLayoutApplyDecision(plan: result, applyResult: applyResult, retryOnClamp: retryOnClamp) {
        case .commit(let appliedFrames, let focusUpdate):
            await worldActor.commit(result, appliedFrames: appliedFrames)
            reporter.info("\(operation) completed")
            await updateTiledBordersFromWorld()
            switch focusUpdate {
            case .target(let focusedWindowID, let frame):
                if showFocusBorder {
                    let target = focusBorderTarget(windowID: focusedWindowID, frame: frame, windows: result.windows)
                    setFocusBorder(target)
                } else {
                    suppressFocusBorder(for: focusedWindowID, frame: frame)
                }
            case .clear:
                setFocusBorder(nil)
            case nil:
                break
            }
            showOperatorFeedback("\(operation) completed", tone: .success, showsHUD: false)
            await persistRestore(reason: persistReason)
            return true

        case .fail(let appliedFrames, let failureCount, let summary):
            await worldActor.recordAppliedFrames(appliedFrames)
            reporter.error(
                "\(operation) failed applying \(failureCount) window(s); planned layout was not committed: \(summary)"
            )
            showOperatorFeedback("\(operation) failed applying windows", tone: .error)
            return false

        case .clamp(let appliedFrames, let observedConstraints, let shouldRetry, let summary):
            await worldActor.recordAppliedFrames(appliedFrames)
            if !observedConstraints.isEmpty {
                await worldActor.recordObservedConstraints(observedConstraints)
            }

            guard shouldRetry else {
                reporter.error(
                    "\(operation) still clamped after min-size re-solve; planned layout was not committed: \(summary)"
                )
                showOperatorFeedback("\(operation) clamped by app minimum size", tone: .warning)
                return false
            }

            reporter.info("\(operation) observed app min-size clamp; re-solving once: \(summary)")
            showOperatorFeedback("\(operation) re-solving after size clamp", tone: .warning)
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
                showOperatorFeedback("\(operation) failed after clamp: \(error.message)", tone: .error)
                return false
            }
        }
    }

    @MainActor
    private func loadRestoreState(using snapshot: EnvironmentSnapshot) async -> Bool {
        guard snapshot.axSnapshot.quality == .complete else {
            reporter.error("Restore skipped because environment snapshot is \(AppDelegateText.describe(snapshot.axSnapshot.quality))")
            return true
        }

        do {
            guard let stored = try restorePersistence.load() else {
                reporter.info("Restore state not found at \(restorePersistence.url.path)")
                return true
            }
            let restoredCount = await worldActor.restore(stored, from: snapshot)
            reporter.info("Restore state loaded from \(restorePersistence.url.path); restored tiled windows=\(restoredCount)")
            await updateTiledBordersFromWorld()
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
                await updateTiledBordersFromWorld()
                await persistRestore(reason: "startup")
                return
            }

            await worldActor.recordAppliedFrames(applyResult.applied)
            if !applyResult.clamps.isEmpty {
                await worldActor.recordObservedConstraints(applyResult.observedConstraints)
            }
            let clampSummary = applyResult.clamps
                .map {
                    "\($0.windowID.description) target=\($0.targetFrame.debugDescription) actual=\($0.actualFrame.debugDescription) observed=\($0.observed.appDebugDescription)"
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
            showOperatorFeedback("Config reload failed", tone: .error)
            return
        }

        do {
            try hotkeyManager?.rebind(loaded.config.keymap)
        } catch {
            let message = String(describing: error)
            reporter.error("Config reload failed rebinding hotkeys (\(reason)): \(message)")
            menubar.updateConfigStatus(.failed(message))
            showOperatorFeedback("Hotkey rebind failed", tone: .error)
            return
        }

        config = loaded.config
        await worldActor.reloadConfig(loaded.config)
        overlay.updateConfig(border: loaded.config.border, hud: loaded.config.hud)
        eventTapClient?.updateModifier(loaded.config.dragModifier)
        logStartupConfig(loaded)
        menubar.updateConfigStatus(.loaded)
        reporter.info("Config reload completed (\(reason))")
        showOperatorFeedback("Config reloaded", tone: .success)
    }

    @MainActor
    private func handleAXEvent(_ event: AXEvent, snapshot: FocusedWindowSnapshot?) async {
        switch event {
        case .windowFocused(let windowID):
            activeSpaceFocusRecoveryDeadline = nil
            await worldActor.recordExternalFocus(windowID)
            updateOperatingStatus { $0.focusedWindowID = windowID }
            if let snapshot {
                updateFocusBorder(for: snapshot)
            }
            await updateTiledBordersFromWorld()
        case .windowMoved, .windowResized:
            await worldActor.recordExternalGeometry(event)
            if let snapshot {
                updateFocusBorder(for: snapshot)
            }
            await updateTiledBordersFromWorld()
        case .windowOpened(let metadata):
            scheduleCoalescedEnvironmentRefresh(.windowOpened(metadata.id))
        case .windowClosed(let windowID):
            removeWindowFromOverlays(windowID)
            if operatingStatus.focusedWindowID == windowID {
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
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
    private func activeSpaceChanged() {
        cancelSpaceTransitionTimers()
        let preservation = beginSpaceTransitionPreservation(
            in: spaceTransitionPreservation,
            settledRefreshDelays: Self.activeSpaceSettledRefreshDelays,
            preserveEndDelay: Self.activeSpaceTransitionPreserveDuration
        )
        spaceTransitionPreservation = preservation.state
        activeSpaceFocusRecoveryDeadline = Date().addingTimeInterval(Self.activeSpaceFocusRecoveryDuration)
        clearBorderOverlays()
        scheduleCoalescedEnvironmentRefresh(.spaceSettled)
        preservation.settledRefreshDelays.forEach { delay in
            scheduleDelayedSpaceSettledRefresh(after: delay)
        }
        scheduleSpaceTransitionPreserveEnd(
            after: preservation.preserveEndDelay,
            generation: preservation.generation
        )
    }

    @MainActor
    private func scheduleDelayedSpaceSettledRefresh(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                self?.spaceSettledRefreshTimers.removeAll { $0 === timer }
                self?.scheduleCoalescedEnvironmentRefresh(.spaceSettled)
            }
        }
        spaceSettledRefreshTimers.append(timer)
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func scheduleDelayedDisplaySettledRefresh(after delay: TimeInterval) {
        cancelDisplaySettledRefreshTimer()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                guard self?.displaySettledRefreshTimer === timer else { return }
                self?.displaySettledRefreshTimer = nil
                self?.scheduleCoalescedEnvironmentRefresh(.displaySettled)
            }
        }
        displaySettledRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func scheduleSpaceTransitionPreserveEnd(after delay: TimeInterval, generation: UInt64) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                guard self?.spaceTransitionPreserveTimer === timer else { return }
                self?.spaceTransitionPreserveTimer = nil
                guard let self else { return }
                let completion = completeSpaceTransitionPreservation(
                    generation: generation,
                    in: self.spaceTransitionPreservation
                )
                self.spaceTransitionPreservation = completion.state
                guard completion.decision == .scheduleRefresh else { return }
                self.scheduleCoalescedEnvironmentRefresh(.spaceTransitionEnded)
            }
        }
        spaceTransitionPreserveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func cancelSpaceTransitionTimers() {
        spaceSettledRefreshTimers.forEach { $0.invalidate() }
        spaceSettledRefreshTimers.removeAll()
        spaceTransitionPreserveTimer?.invalidate()
        spaceTransitionPreserveTimer = nil
        spaceTransitionPreservation = cancelSpaceTransitionPreservation(in: spaceTransitionPreservation)
    }

    @MainActor
    private func cancelDisplaySettledRefreshTimer() {
        displaySettledRefreshTimer?.invalidate()
        displaySettledRefreshTimer = nil
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

        let policy = environmentRefreshPolicy(
            for: request.reasons,
            duringSpaceTransition: spaceTransitionPreservation.isPreservingSpaceLayouts
        )
        let environment = await refreshEnvironment(
            reason: "coalesced \(request.description)",
            preserveSpaceLayouts: policy.preserveSpaceLayouts,
            reconciliationMode: policy.reconciliationMode
        )
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
            if completed && policy.scheduleDeferredCleanup {
                scheduleDelayedDisplaySettledRefresh(after: Self.displaySettledRefreshDelay)
            }
            if completed && policy.applyPendingTileRules && !environment.preservedSpaceLayouts {
                await applyPendingTileRules(reason: "coalesced \(completedRequest.description)")
            }
            if policy.persistRestore && !environment.preservedSpaceLayouts {
                await persistRestore(reason: "coalesced \(completedRequest.description)")
            }
        case .retained(let pending):
            reporter.info("Coalesced environment refresh retained pending generation \(pending.generation) after incomplete AX snapshot")
        case .stale, .idle:
            break
        }
    }

    @MainActor
    @discardableResult
    private func applyPendingTileRules(reason: String) async -> Bool {
        guard !isPaused else { return false }
        guard AccessibilityTrust.current(prompt: false).isTrusted else { return false }

        switch await worldActor.planPendingTileRules() {
        case .success(nil):
            return false
        case .success(let result?):
            return await applyPlannedPendingTileRules(result, reason: reason, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Open rules rejected by core (\(reason)): \(error.message)")
            showOperatorFeedback("Open rules failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    private func togglePause() async {
        isPaused.toggle()
        updateOperatingStatus { $0.paused = isPaused }
        reporter.info(isPaused ? "Narwhal paused" : "Narwhal resumed")
        showOperatorFeedback(isPaused ? "Narwhal paused" : "Narwhal resumed", tone: isPaused ? .warning : .success)
        if isPaused {
            overlay.hideDragPreview()
        } else {
            await applyPendingTileRules(reason: "resume")
        }
    }

    @MainActor
    private func handleIPCCommand(_ command: IPCCommandDTO) async -> IPCReplyDTO {
        let commandID = CommandID(raw: "ipc-\(UUID().uuidString)")
        switch command {
        case .resetLayout:
            await performResetLayout(requiresConfirmation: false, logPrefix: "IPC reset", persistReason: "ipc reset")
            return .ok(commandID: commandID)
        case .quit:
            reporter.info("IPC quit requested")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.terminateAfterFlushingRestore()
            }
            return .ok(commandID: commandID)
        case .pushFocused(let direction):
            if await performPush(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "push_failed",
                message: "Focused push \(direction.rawValue) failed; see NarwhalApp log"
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
                message: "Focused swap \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .swap(let windowID, let direction):
            if let failure = await performExplicitSwap(windowID: windowID, direction: direction) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .resizeFocused(let direction, let delta):
            if await performResize(direction, delta: delta) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "resize_failed",
                message: "Focused resize \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .resize(let windowID, let direction, let delta):
            if let failure = await performExplicitResize(windowID: windowID, direction: direction, delta: delta) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .center(let windowID):
            if let failure = await performExplicitCenter(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .eject(let windowID):
            if let failure = await performExplicitEject(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .toggleFloat(let windowID):
            if let failure = await performExplicitToggleFloat(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .balance:
            if let failure = await performActiveSpaceBalance(
                operation: "IPC balance",
                refreshReason: "ipc balance",
                persistReason: "ipc balance"
            ) {
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
                message: "Focus \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .focusCycle(let direction):
            if await performFocusCycle(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "focus_failed",
                message: "Focus cycle \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .focus(let windowID):
            if let failure = await performExplicitFocus(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        }
    }

    @MainActor
    private func performActiveSpaceBalance(
        operation: String,
        refreshReason: String,
        persistReason: String
    ) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(
            reason: refreshReason,
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard let activeSpace = environment.activeSpace else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "\(operation) requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        reporter.info("\(operation) selected active Space \(activeSpace.raw)")
        switch await worldActor.planBalanceActiveSpace() {
        case .success(let result):
            if await applyPlannedBalance(
                result,
                operation: operation,
                persistReason: persistReason,
                retryOnClamp: true,
                replanAfterClamp: {
                    await self.worldActor.planBalanceActiveSpace()
                }
            ) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "\(operation) layout write failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
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
        let environment = await refreshEnvironment(
            reason: "ipc push \(direction.rawValue)",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC push requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        switch await worldActor.planPush(windowID, direction: direction) {
        case .success(let result):
            if await applyPlannedPush(result, direction: direction, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Push \(direction.rawValue) layout write failed; see NarwhalApp log"
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
        let environment = await refreshEnvironment(
            reason: "ipc center",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC center requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        switch await worldActor.planCenter(windowID) {
        case .success(let result):
            if await applyPlannedCenter(result, windowID: windowID, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Center layout write failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitEject(windowID: WindowID) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(
            reason: "ipc eject",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC eject requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        switch await worldActor.planEject(windowID) {
        case .success(let result):
            if await applyPlannedEject(result, windowID: windowID, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Eject layout write failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitToggleFloat(windowID: WindowID) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(
            reason: "ipc toggle float",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC toggleFloat requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        switch await worldActor.planToggleFloat(windowID) {
        case .success(let result):
            if await applyPlannedToggleFloat(result, windowID: windowID, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Toggle float layout write failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitFocus(windowID: WindowID) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(
            reason: "ipc focus",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC focus requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        switch await worldActor.planFocus(windowID) {
        case .success(let result):
            if await focusWindow(result, reason: "ipc focus") {
                return nil
            }
            return CommandExecutionFailure(
                code: "focus_failed",
                message: "Focus \(windowID.description) failed; see NarwhalApp log"
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
        let environment = await refreshEnvironment(
            reason: "ipc swap \(direction.rawValue)",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC swap requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        switch await worldActor.planSwap(windowID, direction: direction) {
        case .success(let result):
            if await applyPlannedSwap(result, windowID: windowID, direction: direction, retryOnClamp: true) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Swap \(direction.rawValue) layout write failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitResize(
        windowID: WindowID,
        direction: Direction,
        delta: Double
    ) async -> CommandExecutionFailure? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            )
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(
            reason: "ipc resize \(direction.rawValue)",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            return CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable")
        }
        guard case .complete = environment.quality else {
            return CommandExecutionFailure(
                code: "environment_incomplete",
                message: "IPC resize requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            )
        }

        switch await worldActor.planResize(windowID, direction: direction, delta: delta) {
        case .success(let result):
            if await applyPlannedResize(
                result,
                windowID: windowID,
                direction: direction,
                delta: delta,
                retryOnClamp: true
            ) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "Resize \(direction.rawValue) layout write failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func persistRestore(reason: String) async {
        let stored = await worldActor.restoreSnapshot()
        restorePersistence.scheduleSave(stored, reason: reason)
    }

    @MainActor
    private func terminateAfterFlushingRestore() {
        restorePersistence.flushPending()
        NSApplication.shared.terminate(nil)
    }

    private func logDisplays(_ displays: [DisplayID: DisplayInfo]) {
        for (id, display) in displays.sorted(by: { $0.key.raw < $1.key.raw }) {
            reporter.info("Display \(id.raw) frame=\(display.frame.debugDescription) visible=\(display.visibleFrame.debugDescription)")
        }
    }
}

private func logRestoreSaveEvent(_ event: RestoreSaveEvent, reporter: StartupReporter) {
    switch event {
    case .saved(let result):
        reporter.info("Restore state saved (\(result.reason)) to \(result.urlPath)")
    case .failed(let failure):
        reporter.error("Restore state save failed (\(failure.reason)): \(failure.message)")
    }
}
