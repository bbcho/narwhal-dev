import AppKit
import CoreGraphics
import Darwin
import NarwhalAppSupport
import NarwhalCore
import NarwhalIPC
import UniformTypeIdentifiers

@MainActor
public enum NarwhalApplication {
    public static func main() {
        let startupArguments = StartupArguments.current
        if startupArguments.command == .checkConfig {
            Darwin.exit(runHeadlessCheckConfig(startupArguments) ? 0 : 1)
        }
        AppDelegate.main()
    }

    private static func runHeadlessCheckConfig(_ startupArguments: StartupArguments) -> Bool {
        let reporter = StartupReporter()
        defer { reporter.flush() }
        reporter.info("NarwhalApp started")
        reporter.info("Log file: \(StartupReporter.defaultLogPath)")

        let result: Result<StartupConfigLoad, StartupConfigError>
        switch startupArguments.startupConfigRequest {
        case .success(let request):
            result = StartupConfigLoader(
                configURL: request.url,
                missingFilePolicy: request.missingFilePolicy
            ).load()
        case .failure(let error):
            result = .failure(error)
        }

        switch result {
        case .success(let loaded):
            switch loaded.source {
            case .builtInDefault(let missingUserConfig):
                reporter.info("Startup config not found at \(missingUserConfig.path); using built-in defaults")
            case .userFile(let url):
                reporter.info("Loaded startup config from \(url.path)")
            }
            reporter.info("Startup config active: \(loaded.config.keymap.count) hotkeys, \(loaded.config.zones.count) zones")
            reporter.info("NarwhalApp stopped")
            return true
        case .failure(let error):
            reporter.error("Startup config failed: \(error.description)")
            reporter.info("NarwhalApp stopped")
            return false
        }
    }
}

private struct PendingExternalGeometryEvent {
    let event: AXEvent
    let snapshot: FocusedWindowSnapshot?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()
    private static let environmentRefreshCoalescingDelay: TimeInterval = 0.10
    private static let externalGeometryEventTolerance: CGFloat = frameWriteSettleTolerance
    private static let activeSpaceTransitionPreserveDuration: TimeInterval = 1.25
    private static let activeSpaceFocusRecoveryDuration: TimeInterval = 5.0
    private static let activeSpaceSettledRefreshDelays: [TimeInterval] = [0.35, 0.80]
    private static let displaySettledRefreshDelay: TimeInterval = 6.0
    private static let restoreSaveDebounceInterval: TimeInterval = 0.25
    private static let terminationFlushTimeoutNanoseconds: UInt64 = 2_000_000_000

    private let runtimeMetrics = RuntimeMetrics()
    private lazy var axClient = AXClient(runtimeMetrics: runtimeMetrics)
    private let displayClient = DisplayClient()
    private let spaceClient = SpaceClient()
    private var restorePersistence = RestorePersistence(manager: RestoreManager())
    private let managedRulesStore = ManagedRulesStore()
    private let echoSuppressor = AXEchoSuppressor()
    private let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
    private var overlayModel = OverlayModel.empty
    private let menubar = Menubar()
    private let loginItemController = LoginItemController()
    private let updateChecker = UpdateChecker()
    private let startupArguments = StartupArguments.current
    private lazy var worldActor = WorldActor(runtimeMetrics: runtimeMetrics)
    private let reporter = StartupReporter()
    private lazy var workbenchController = LayoutWorkbenchController(
        worldActor: worldActor,
        snapshotQuality: { [weak self] in self?.operatingStatus.snapshotQuality },
        applyPlan: { [weak self] result, intent in
            guard let self else { return false }
            return await self.applyWorkbenchPlan(result, intent: intent)
        },
        activateManagedRules: { [weak self] rules in
            guard let self else { return }
            await self.activateManagedRules(rules)
        },
        managedRulesSnapshot: { [weak self] in
            self?.managedRules ?? []
        },
        openAccessibilitySettings: { [weak self] in
            self?.openAccessibilitySettingsFromMenu()
        }
    )
    private var config = Config.default
    private var managedRules: [ManagedWindowRule] = []
    private var managedRulesWarning: String?
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
    private let commandExecutionGate = MainActorCommandExecutionGate()
    private var isHandlingExternalGeometry = false
    private var pendingExternalGeometryEvents =
        ExternalGeometryEventQueue<PendingExternalGeometryEvent>()
    private var runningServices: RunningServices?
    private var servicesStarted = false
    private var isPaused = false
    private var configHealthy = true
    private var startupConfigFailure: StartupConfigError?
    private var configWarning: RuntimeReadinessIssue?
    private var restoreWarning: RuntimeReadinessIssue?
    private var runtimeReadiness: RuntimeReadiness = .starting
    private var terminationFlushState: TerminationFlushState = .idle
    private var terminationFlushTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var updateStatus: UpdateMenuStatus = .idle
    // AX raise failures survive environment refreshes, so exclusions are session-scoped.
    private var axRaiseBlocklist: Set<WindowID> = []

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let verifierFlag = instance.startupArguments.verifierFlag {
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

        switch startupArguments.command {
        case .checkConfig:
            let ok = loadStartupConfig()
            reporter.info("NarwhalApp stopped")
            exitAfterFlushing(ok ? 0 : 1)
        case .checkEnvironment:
            guard loadStartupConfig() else {
                reporter.info("NarwhalApp stopped")
                exitAfterFlushing(1)
            }
            let status = reportAccessibilityStatus(prompt: false)
            guard status.isTrusted else {
                reporter.error("Environment check skipped because Accessibility is not trusted")
                reporter.info("NarwhalApp stopped")
                exitAfterFlushing(1)
            }
            Task { @MainActor in
                let focused = reportFocusedWindowSnapshot()
                let environment = await refreshEnvironment(reason: "check")
                guard environment.activeSpace != nil else {
                    reporter.error("Environment check failed: active Space unavailable")
                    reporter.info("NarwhalApp stopped")
                    exitAfterFlushing(1)
                }
                if let focused {
                    await worldActor.recordExternalFocus(focused.id)
                }
                reporter.info("NarwhalApp stopped")
                exitAfterFlushing(0)
            }
            return
        case .pushLeft:
            runPushOnceAndTerminate(.left)
            return
        case .focusedWindow:
            let status = reportAccessibilityStatus(prompt: false)
            if status.isTrusted {
                _ = reportFocusedWindowSnapshot()
            } else {
                reporter.error("Focused-window check skipped because Accessibility is not trusted")
            }
            NSApplication.shared.terminate(nil)
            return
        case .checkAccessibility:
            reportAccessibilityStatus(prompt: false)
            NSApplication.shared.terminate(nil)
            return
        case .unregisterLoginItem:
            do {
                try loginItemController.unregister()
                reporter.info("Launch at Login unregistered")
                reporter.info("NarwhalApp stopped")
                exitAfterFlushing(0)
            } catch {
                reporter.error("Launch at Login unregister failed: \(String(describing: error))")
                reporter.info("NarwhalApp stopped")
                exitAfterFlushing(1)
            }
        case .normal:
            break
        }

        loadNormalStartupConfig()

        // Start the menubar BEFORE the Accessibility check so the user always has a
        // visible indicator that Narwhal is alive, even while waiting for permission.
        startMenubar()

        let status = reportAccessibilityStatus(prompt: true)
        guard status.isTrusted else {
            reporter.info("Waiting for Accessibility permission before starting AX work")
            updateRuntimeReadiness(.waitingForAccessibility)
            showOperatorFeedback("Narwhal needs Accessibility permission", tone: .warning, showsHUD: false)
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
        terminationFlushTask?.cancel()
        terminationFlushTask = nil
        terminationTimeoutTask?.cancel()
        terminationTimeoutTask = nil
        updateCheckTask?.cancel()
        updateCheckTask = nil
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
        workbenchController.close()
        overlay.stop()
        reporter.info("NarwhalApp stopped")
        reporter.flush()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let transition = NarwhalAppSupport.requestTermination(in: terminationFlushState)
        terminationFlushState = transition.state

        switch transition.decision {
        case .startFlushAndDefer:
            reporter.info("Termination requested; flushing restore state")
            terminationFlushTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await restorePersistence.flushPending()
                resolveTermination(.persisted)
            }
            terminationTimeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.terminationFlushTimeoutNanoseconds)
                } catch {
                    return
                }
                self?.resolveTermination(.timedOut)
            }
            return .terminateLater
        case .deferExistingFlush:
            return .terminateLater
        case .terminateNow:
            return .terminateNow
        }
    }

    private func resolveTermination(_ completion: TerminationFlushCompletion) {
        let transition = completeTerminationFlush(completion, in: terminationFlushState)
        terminationFlushState = transition.state
        guard transition.decision == .replyToTerminate else { return }

        switch completion {
        case .persisted:
            reporter.info("Termination restore flush completed")
            terminationTimeoutTask?.cancel()
        case .timedOut:
            terminationFlushTask?.cancel()
            reporter.error("Termination restore flush timed out; allowing shutdown")
        }
        terminationFlushTask = nil
        terminationTimeoutTask = nil
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    private func updateOperatingStatus(_ update: (inout MenubarOperatingStatus) -> Void) {
        update(&operatingStatus)
        menubar.updateOperatingStatus(operatingStatus)
    }

    private func updateRuntimeReadiness(_ readiness: RuntimeReadiness) {
        runtimeReadiness = readiness
        menubar.updateRuntimeReadiness(readiness)
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
        updateOperatingStatus { $0.accessibilityTrusted = true }
        updateRuntimeReadiness(.starting)
        Task { @MainActor in
            await startAfterAccessibilityTrusted()
        }
    }

    @MainActor
    private func startAfterAccessibilityTrusted() async {
        guard !servicesStarted else { return }
        updateRuntimeReadiness(.starting)
        reporter.info("Rung 1 complete: AppKit run loop is active and Accessibility is trusted")
        let focused = reportFocusedWindowSnapshot()
        let environment = await refreshEnvironment(reason: "startup")
        guard environment.activeSpace != nil else {
            reporter.error("Window manager services not started: active Space unavailable")
            updateRuntimeReadiness(.degraded(.activeSpaceUnavailable))
            return
        }
        restoreWarning = nil
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
    private func updateFocusBorderFromWorld(windowID: WindowID) async {
        switch await worldActor.planFocus(windowID) {
        case .success(let result):
            setFocusBorder(FocusBorderTarget(window: result.window, frame: result.frame))
        case .failure(let error):
            reporter.error("Focus border refresh failed: \(error.message)")
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
        let renderResult = overlay.render(overlayModel)
        for windowID in renderResult.staleTiledBorderTargets {
            reporter.info("Tiled border target \(windowID.description) did not match live WindowServer bounds; scheduling environment refresh")
            scheduleCoalescedEnvironmentRefresh(.tiledBorderTargetMismatch(windowID))
        }
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
        await refreshWorkspacePresentationSurfaces()
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

    private func refreshWorkspacePresentationSurfaces() async {
        let presentation = await worldActor.workbenchPresentation(
            snapshotQuality: operatingStatus.snapshotQuality
        )
        menubar.updateWorkspacePresentation(presentation)
        workbenchController.updatePresentationIfVisible(presentation)
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
        switch startupArguments.restoreStateURL {
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
            exitAfterFlushing(1)
        }
    }

    private func restorePersistence(for manager: RestoreManager) -> RestorePersistence {
        RestorePersistence(
            manager: manager,
            debounceInterval: Self.restoreSaveDebounceInterval,
            measureSave: { [runtimeMetrics] durationMilliseconds in
                runtimeMetrics.record(.restoreWrite, durationMilliseconds: durationMilliseconds)
            }
        ) { [reporter] event in
            logRestoreSaveEvent(event, reporter: reporter)
        }
    }

    @discardableResult
    private func loadStartupConfig() -> Bool {
        switch startupConfigLoad() {
        case .success(let loaded):
            activateStartupConfig(configByRefreshingManagedRules(loaded.config))
            logStartupConfig(loaded)
            return true
        case .failure(let error):
            reporter.error("Startup config failed: \(error.description)")
            return false
        }
    }

    private func loadNormalStartupConfig() {
        switch startupConfigLoad() {
        case .success(let loaded):
            activateStartupConfig(configByRefreshingManagedRules(loaded.config))
            configHealthy = true
            startupConfigFailure = nil
            configWarning = nil
            logStartupConfig(loaded)
        case .failure(let error):
            activateStartupConfig(configByRefreshingManagedRules(.default))
            configHealthy = false
            startupConfigFailure = error
            configWarning = .configFallback
            reporter.error("Startup config failed; using built-in defaults: \(error.description)")
        }
    }

    private func activateStartupConfig(_ activeConfig: Config) {
        config = activeConfig
        worldActor = WorldActor(config: activeConfig, runtimeMetrics: runtimeMetrics)
        overlay.updateConfig(border: activeConfig.border, hud: activeConfig.hud)
    }

    private func configByRefreshingManagedRules(_ baseConfig: Config) -> Config {
        do {
            switch try managedRulesStore.loadRecovering() {
            case .missing:
                managedRules = []
                managedRulesWarning = nil
            case .loaded(let loadedRules):
                managedRules = loadedRules
                managedRulesWarning = nil
                reporter.info("Loaded \(loadedRules.count) managed window rules")
            case .recoveredEmpty(let recovery):
                managedRulesWarning = recovery.error.description
                reporter.error(
                    "Managed rules were invalid; preserving \(managedRules.count) active rules and quarantined \(recovery.quarantinedFilename): \(recovery.error.description)"
                )
            case .incompatible(let error):
                managedRulesWarning = error.description
                reporter.error(
                    "Managed rules were written by an incompatible version; preserving \(managedRules.count) active rules: \(error.description)"
                )
            }
        } catch {
            managedRulesWarning = String(describing: error)
            reporter.error(
                "Managed rules could not be read; preserving \(managedRules.count) active rules: \(error)"
            )
        }
        return baseConfig.withManagedRules(managedRules)
    }

    private func startupConfigLoad() -> Result<StartupConfigLoad, StartupConfigError> {
        switch startupArguments.startupConfigRequest {
        case .success(let request):
            return StartupConfigLoader(configURL: request.url, missingFilePolicy: request.missingFilePolicy).load()
        case .failure(let error):
            return .failure(error)
        }
    }

    private func logStartupConfig(_ loaded: StartupConfigLoad) {
        switch loaded.source {
        case .builtInDefault(let missingUserConfig):
            reporter.info("Startup config not found at \(missingUserConfig.path); using built-in defaults")
        case .userFile(let url):
            reporter.info("Loaded startup config from \(url.path)")
        }
        reporter.info(
            "Startup config active: \(config.keymap.count) hotkeys, \(config.zones.count) zones, \(config.managedRules.count) managed rules"
        )
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
            await requestTermination()
        }
    }

    private func startServices() {
        guard !servicesStarted else { return }

        let steps: [ServiceStartStep]
        switch startupArguments.serviceStartSteps(serviceStartSteps()) {
        case .success(let value):
            steps = value
        case .failure(let error):
            reporter.error(error.description)
            reporter.info("Runtime service startup failed; recovery menu remains available")
            updateRuntimeReadiness(.degraded(.serviceStartupFailed(service: "startup request")))
            return
        }

        switch startServiceSequence(steps) {
        case .success(let services):
            runningServices = services
            servicesStarted = true
            reporter.info("Layout command loop ready")
            updateRuntimeReadiness(operationalReadiness)
        case .failure(let error):
            runningServices = nil
            servicesStarted = false
            reporter.error(error.description)
            reporter.info("Runtime service startup failed; recovery menu remains available")
            updateRuntimeReadiness(.degraded(.serviceStartupFailed(service: error.service)))
        }
    }

    private func serviceStartSteps() -> [ServiceStartStep] {
        [
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
        menubar.start(actions: MenubarActions(
            openWorkbench: { [weak self] in
                self?.workbenchController.show()
            },
            reloadConfig: { [weak self] in
                Task { @MainActor in
                    await self?.reloadConfig(reason: "menubar")
                }
            },
            retryStartup: { [weak self] in
                self?.retryStartupFromMenu()
            },
            openConfig: { [weak self] in
                self?.openConfigFromMenu()
            },
            openAccessibilitySettings: { [weak self] in
                self?.openAccessibilitySettingsFromMenu()
            },
            revealLogs: { [weak self] in
                self?.revealLogsFromMenu()
            },
            toggleLaunchAtLogin: { [weak self] in
                self?.toggleLaunchAtLoginFromMenu()
            },
            checkForUpdates: { [weak self] in
                self?.handleUpdateMenuAction()
            },
            exportSupportBundle: { [weak self] in
                self?.exportSupportBundleFromMenu()
            },
            copyDiagnostics: { [weak self] in
                Task { @MainActor in
                    await self?.copyDiagnosticsToPasteboard()
                }
            },
            resetLayout: { [weak self] in
                Task { @MainActor in
                    await self?.performHotkey(.command(.resetLayout))
                }
            },
            quit: { [weak self] in
                Task { @MainActor in
                    await self?.requestTermination()
                }
            }
        ))
        if let startupConfigFailure {
            menubar.updateConfigStatus(.failed(startupConfigFailure.description))
        } else {
            menubar.updateConfigStatus(.loaded)
        }
        menubar.updateRuntimeReadiness(runtimeReadiness)
        menubar.updateLoginItemStatus(loginItemController.status)
        menubar.updateUpdateStatus(updateStatus)
        menubar.updateOperatingStatus(operatingStatus)
    }

    private var operationalReadiness: RuntimeReadiness {
        if let restoreWarning {
            return .operationalWithWarning(restoreWarning)
        }
        if let configWarning {
            return .operationalWithWarning(configWarning)
        }
        return .operational
    }

    private func retryStartupFromMenu() {
        guard !servicesStarted, runtimeReadiness.canRetryStartup else { return }

        let status = reportAccessibilityStatus(prompt: true)
        guard status.isTrusted else {
            updateRuntimeReadiness(.waitingForAccessibility)
            return
        }

        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        updateRuntimeReadiness(.starting)
        Task { @MainActor in
            await startAfterAccessibilityTrusted()
        }
    }

    private func openConfigFromMenu() {
        let url: URL
        switch startupArguments.startupConfigRequest {
        case .success(let request):
            url = request.url
        case .failure:
            url = StartupConfigLoader.defaultUserConfigURL
        }

        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try DefaultConfigLua.render().write(to: url, atomically: true, encoding: .utf8)
                reporter.info("Created default user config")
            }
            guard NSWorkspace.shared.open(url) else {
                reporter.error("Open Config failed: workspace rejected the file")
                showOperatorFeedback("Could not open config", tone: .error)
                return
            }
        } catch {
            reporter.error("Open Config failed: \(String(describing: error))")
            showOperatorFeedback("Could not open config", tone: .error)
        }
    }

    private func openAccessibilitySettingsFromMenu() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url)
        else {
            reporter.error("Accessibility Settings could not be opened")
            showOperatorFeedback("Could not open Accessibility Settings", tone: .error)
            return
        }
        reporter.info("Opened Accessibility Settings")
    }

    private func revealLogsFromMenu() {
        let logURL = URL(fileURLWithPath: StartupReporter.defaultLogPath)
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
        reporter.info("Revealed runtime log")
    }

    private func toggleLaunchAtLoginFromMenu() {
        do {
            let status = try loginItemController.performAction()
            menubar.updateLoginItemStatus(status)
            switch status {
            case .enabled:
                reporter.info("Launch at Login enabled")
            case .disabled:
                reporter.info("Launch at Login disabled")
            case .requiresApproval:
                reporter.info("Launch at Login requires approval in System Settings")
            case .unavailable:
                reporter.error("Launch at Login is unavailable for this app bundle")
            case .failed:
                break
            }
        } catch {
            let message = String(describing: error)
            menubar.updateLoginItemStatus(.failed(message))
            reporter.error("Launch at Login update failed: \(message)")
            showOperatorFeedback("Launch at Login update failed", tone: .error)
        }
    }

    private func handleUpdateMenuAction() {
        if case .available(_, let pageURL) = updateStatus {
            guard NSWorkspace.shared.open(pageURL) else {
                reporter.error("Available update page could not be opened")
                showOperatorFeedback("Could not open update page", tone: .error)
                return
            }
            reporter.info("Opened available update page")
            return
        }
        checkForUpdates()
    }

    private func checkForUpdates() {
        guard updateCheckTask == nil else { return }

        let currentVersion: SemanticVersion
        do {
            let value = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? ""
            currentVersion = try SemanticVersion(value)
        } catch {
            updateStatus = .failed
            menubar.updateUpdateStatus(updateStatus)
            reporter.error("Update check failed: current app version is invalid")
            showOperatorFeedback("Update check failed", tone: .error)
            return
        }

        updateStatus = .checking
        menubar.updateUpdateStatus(updateStatus)
        reporter.info("Checking for updates")
        updateCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let release = try await updateChecker.latestRelease()
                guard !Task.isCancelled else { return }
                switch updateAvailability(
                    current: currentVersion,
                    latest: release.version,
                    pageURL: release.pageURL
                ) {
                case .current:
                    updateStatus = .current
                    reporter.info("Narwhal is up to date")
                    showOperatorFeedback("Narwhal is up to date", tone: .success)
                case .newer(let version, let pageURL):
                    updateStatus = .available(version: version, pageURL: pageURL)
                    reporter.info("Narwhal update \(version.description) is available")
                    showOperatorFeedback("Narwhal \(version.description) is available", tone: .success)
                }
            } catch {
                guard !Task.isCancelled else { return }
                updateStatus = .failed
                reporter.error("Update check failed: \(String(describing: error))")
                showOperatorFeedback("Update check failed", tone: .error)
            }
            menubar.updateUpdateStatus(updateStatus)
            updateCheckTask = nil
        }
    }

    private func exportSupportBundleFromMenu() {
        let panel = supportBundleSavePanel()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK,
                  let destination = panel.url,
                  let self
            else { return }
            Task { @MainActor in
                let diagnostics = await self.runtimeDiagnostics()
                self.reporter.flush()
                let builder = SupportBundleBuilder(
                    logURL: URL(fileURLWithPath: StartupReporter.defaultLogPath)
                )
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try builder.write(diagnostics: diagnostics, to: destination)
                    }
                }.value
                switch result {
                case .success:
                    self.reporter.info("Support bundle exported")
                    self.showOperatorFeedback("Support bundle exported", tone: .success)
                case .failure(let error):
                    self.reporter.error("Support bundle export failed: \(String(describing: error))")
                    self.showOperatorFeedback("Support bundle export failed", tone: .error)
                }
            }
        }
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
        switch startupArguments.startupConfigRequest {
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
                    guard let self else { return }
                    await self.commandExecutionGate.perform {
                        await self.performDragDrop(at: location)
                    }
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
            guard let batch = nextHotkeyExecutionBatch(in: pendingHotkeys) else { break }
            pendingHotkeys.removeFirst(batch.consumedCount)
            await commandExecutionGate.perform {
                await self.performHotkey(batch.action, resizeDeltas: batch.resizeDeltas)
            }
        }
        isDrainingHotkeys = false
    }

    @MainActor
    private func performHotkey(_ action: HotkeyAction, resizeDeltas: [Double] = []) async {
        if routeCommandOverlayHotkey(action) {
            return
        }

        reporter.info("Hotkey received: \(AppDelegateText.describe(action))")

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
            await performResize(direction, deltas: resizeDeltas.isEmpty ? [delta] : resizeDeltas)
        case .command(.focusDirection(let direction)):
            await performFocusDirection(direction)
        case .command(.focusCycle(let direction)):
            await performFocusCycle(direction)
        case .command(.focusPrevious):
            await performFocusPrevious()
        case .command(.undoLayout):
            await performUndoLayout()
        case .command(.redoLayout):
            await performRedoLayout()
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
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
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
            case .push, .center, .eject, .swap, .resizeSplit, .toggleFloat, .balance, .shuffle, .cascade, .maximizeReset, .undoLayout, .redoLayout, .moveToNextDisplay:
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

        switch await worldActor.planResetLayoutMemory() {
        case .success(let result):
            let completed = await applyPlannedLayout(
                result,
                operation: logPrefix,
                persistReason: persistReason,
                retryOnClamp: false,
                showFocusBorder: false
            ) {
                await self.worldActor.planResetLayoutMemory()
            }
            if completed {
                reporter.info("\(logPrefix) layout memory cleared for the active Space; undo remains available")
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
            return completed
        case .failure(let error):
            reporter.error("\(logPrefix) rejected: \(error.message)")
            showOperatorFeedback("Reset failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    private func confirmResetLayout() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset Narwhal layout memory?"
        alert.informativeText = "This clears tracked tiling state, floating order, focus memory, pending rules, and observed window minimums for the active Space. You can undo it."
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
        case .success(let allResults):
            let results = allResults.filter { !axRaiseBlocklist.contains($0.window.id) }
            let droppedCount = allResults.count - results.count
            if droppedCount > 0 {
                reporter.info("Focus cycle \(direction.rawValue) skipped \(droppedCount) AX-raise-hostile candidate(s)")
            }
            reporter.info("Focus cycle \(direction.rawValue) planned \(results.count) candidate(s)")
            if results.isEmpty {
                showOperatorFeedback("No cyclable window", tone: .info, showsHUD: false)
                return false
            }
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
        switch await axClient.focusWindow(result.window) {
        case .success:
            echoSuppressor.expectFocus(windowID: result.window.id)
            await worldActor.recordExternalFocus(result.window.id)
            updateOperatingStatus { $0.focusedWindowID = result.window.id }
            setFocusBorder(FocusBorderTarget(window: result.window, frame: result.frame))
            reporter.info("\(reason) completed target=\(result.window.id.description)")
            showOperatorFeedback("\(reason) -> \(result.window.id.description)", tone: .success, showsHUD: false)
            return true
        case .failure(let error):
            reporter.error(
                "\(reason) failed focusing \(result.window.id.description) "
                + "(bundle=\(result.window.bundleID.raw) title=\"\(result.window.title)\"): "
                + error.description
            )
            if shouldRemoveFailedFocusTarget(error, reason: reason) {
                await worldActor.removeWindowFromActiveSpace(result.window.id)
                await updateTiledBordersFromWorld()
                reporter.info("Removed stale focus target \(result.window.id.description) from active Space after focus failure")
            }
            if shouldBlocklistFromCycle(error) {
                if axRaiseBlocklist.insert(result.window.id).inserted {
                    reporter.info(
                        "Added \(result.window.id.description) (bundle=\(result.window.bundleID.raw)) "
                        + "to AX-raise blocklist; future focus cycles will skip it"
                    )
                }
            }
            if !suppressFailureFeedback {
                showOperatorFeedback("\(reason) failed", tone: .error)
            }
            return false
        }
    }

    private func shouldBlocklistFromCycle(_ error: AXClientError) -> Bool {
        // Permanent (for the session) AX-raise refusals — the target app does not
        // expose kAXRaiseAction at all (e.g., System Settings). Env refresh will
        // keep re-discovering the window, so we must remember it ourselves.
        if case let .performActionFailed(action, axError) = error,
           action == kAXRaiseAction,
           axError == .attributeUnsupported || axError == .actionUnsupported {
            return true
        }
        return false
    }

    private func shouldRemoveFailedFocusTarget(_ error: AXClientError, reason: String) -> Bool {
        let isCycling = reason.hasPrefix("focus cycle") || reason == "focus previous"
        switch error {
        case .windowElementNotFound:
            return true
        case .performActionFailed(let action, let axError):
            // .cannotComplete: app unresponsive / window gone. .attributeUnsupported /
            // .actionUnsupported: the target app doesn't expose kAXRaiseAction at all
            // (some Electron/web apps, some control panels, some menu-only apps). In
            // all three cases the window is not focus-cyclable; drop it from the active
            // Space so the cycle stops getting stuck on it.
            return isCycling
                && action == kAXRaiseAction
                && (axError == .cannotComplete
                    || axError == .attributeUnsupported
                    || axError == .actionUnsupported)
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
             .automationFailed,
             .frameDidNotConverge,
             .frameReadbackDisagreed,
             .invalidFrame,
             .visibleWindowListUnavailable,
             .windowServerFrameUnavailable,
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
    private func performRedoLayout() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Redo skipped because Accessibility is not trusted")
            showOperatorFeedback("Redo failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironment(reason: "pre-redo", reconciliationMode: .observeOnly)
        guard environment.activeSpace != nil else {
            reporter.error("Redo rejected before planning: active Space unavailable")
            showOperatorFeedback("Redo failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Redo rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Redo failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planRedoLastLayout() {
        case .success(nil):
            reporter.info("Redo skipped: no later layout")
            showOperatorFeedback("Nothing to redo", tone: .warning, showsHUD: false)
            return false
        case .success(let result?):
            return await applyPlannedRedo(result, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Redo rejected by core: \(error.message)")
            showOperatorFeedback("Redo failed: \(error.message)", tone: .error)
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
        await performResize(direction, deltas: [delta])
    }

    @MainActor
    @discardableResult
    private func performResize(_ direction: Direction, deltas: [Double]) async -> Bool {
        let operation = "Resize \(direction.rawValue) \(deltas)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-resize \(direction.rawValue)")
        else { return false }

        switch await worldActor.planResizeSequence(context.id, direction: direction, deltas: deltas) {
        case .success(let result):
            return await applyPlannedResize(
                result,
                windowID: context.id,
                direction: direction,
                deltas: deltas,
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
        if let snapshot = await focusedWindowSnapshotForLayoutOperation(operation) {
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
    private func focusedWindowSnapshotForLayoutOperation(_ operation: String) async -> FocusedWindowSnapshot? {
        for attempt in 0..<4 {
            if case .success(let snapshot) = axClient.focusedWindowSnapshot() {
                activeSpaceFocusRecoveryDeadline = nil
                return snapshot
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 30_000_000)
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

            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch is CancellationError {
                activeSpaceFocusRecoveryDeadline = nil
                return nil
            } catch {
                activeSpaceFocusRecoveryDeadline = nil
                return nil
            }
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
        deltas: [Double],
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Resize \(direction.rawValue) \(deltas)",
            persistReason: "resize \(direction.rawValue) \(deltas)",
            retryOnClamp: retryOnClamp,
            writeStrategy: .coordinated
        ) {
            await self.worldActor.planResizeSequence(windowID, direction: direction, deltas: deltas)
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
    private func applyPlannedRedo(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Redo",
            persistReason: "redo",
            retryOnClamp: retryOnClamp
        ) {
            await self.requireRedoLayoutPlan()
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

    private func requireRedoLayoutPlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planRedoLastLayout() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.configInvalid("nothing to redo"))
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

    private func requireExternalGeometryPlan(_ event: AXEvent) async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planExternalGeometry(event) {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.configInvalid("external geometry produced no layout change"))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func replanExternalGeometryAfterClamp(
        _ result: CommandPlanResult
    ) async -> Result<CommandPlanResult, CommandError> {
        await worldActor.replanExternalGeometryAfterClamp(result)
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
        preserving preservedFrames: [WindowID: CGRect] = [:],
        writeStrategy: LayoutFrameWriteStrategy = .sequential,
        clampRetryState: LayoutClampRetryState? = nil,
        replanAfterClamp: () async -> Result<CommandPlanResult, CommandError>
    ) async -> Bool {
        if !result.desiredLayout.delta.moves.isEmpty {
            setTiledBorders([])
        }
        let applyResult = await LayoutApplier(
            axClient: axClient,
            reporter: reporter,
            echoSuppressor: echoSuppressor
        ).apply(result, preserving: preservedFrames, strategy: writeStrategy)
        switch plannedLayoutApplyDecision(plan: result, applyResult: applyResult, retryOnClamp: retryOnClamp) {
        case .commit(let appliedFrames, let focusUpdate):
            guard await worldActor.commit(result, appliedFrames: appliedFrames) else {
                reporter.error(
                    "\(operation) moved windows but its source workspace changed before commit; reconciling live frames without history"
                )
                _ = await refreshEnvironment(reason: "stale \(operation.lowercased()) commit")
                showOperatorFeedback("\(operation) was not committed because the workspace changed", tone: .warning)
                return false
            }
            reporter.info("\(operation) completed")
            await updateTiledBordersFromWorld()
            await refreshWorkspacePresentationSurfaces()
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
            await updateTiledBordersFromWorld()
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

            let retryState = clampRetryState
                ?? LayoutClampRetryState(maxAttempts: result.desiredLayout.delta.moves.count)
            guard shouldRetry,
                  let nextRetryState = retryState.recording(observedConstraints)
            else {
                await updateTiledBordersFromWorld()
                reporter.error(
                    "\(operation) still clamped without a new bounded constraint observation; "
                        + "planned layout was not committed: \(summary)"
                )
                showOperatorFeedback("\(operation) clamped by app minimum size", tone: .warning)
                return false
            }

            reporter.info(
                "\(operation) observed a new app size constraint; re-solving "
                    + "with \(nextRetryState.remainingAttempts) bounded attempt(s) remaining: \(summary)"
            )
            showOperatorFeedback("\(operation) re-solving after size clamp", tone: .warning)
            switch await replanAfterClamp() {
            case .success(let retry):
                return await applyPlannedLayout(
                    retry,
                    operation: operation,
                    persistReason: persistReason,
                    retryOnClamp: retryOnClamp,
                    preserving: preservedFrames,
                    writeStrategy: writeStrategy,
                    clampRetryState: nextRetryState,
                    replanAfterClamp: replanAfterClamp
                )
            case .failure(let error):
                await updateTiledBordersFromWorld()
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
            switch try await restorePersistence.loadRecovering() {
            case .missing:
                reporter.info("Restore state not found at \(restorePersistence.url.path)")
                return true
            case .loaded(let stored):
                let restoredCount = await worldActor.restore(stored, from: snapshot)
                reporter.info("Restore state loaded; restored tiled windows=\(restoredCount)")
                await updateTiledBordersFromWorld()
                return true
            case .recoveredFromBackup(let stored, let recovery):
                restoreWarning = .restoreRecovered(
                    quarantinedFilenames: recovery.quarantinedFilenames
                )
                let restoredCount = await worldActor.restore(stored, from: snapshot)
                reporter.error(
                    "Invalid restore state quarantined as \(recovery.quarantinedFilenames.joined(separator: ", ")); recovered from backup"
                )
                reporter.info("Restore backup loaded; restored tiled windows=\(restoredCount)")
                await updateTiledBordersFromWorld()
                return true
            case .recoveredEmpty(let recovery):
                restoreWarning = .restoreReset(
                    quarantinedFilenames: recovery.quarantinedFilenames
                )
                reporter.error(
                    "Invalid restore state quarantined as \(recovery.quarantinedFilenames.joined(separator: ", ")); starting with empty layout"
                )
                return true
            case .incompatible(let recovery):
                let schemaError = recovery.backupError ?? recovery.primaryError
                reporter.error("Restore state is from an unsupported future schema: \(schemaError.description)")
                updateRuntimeReadiness(.degraded(.restoreIncompatible))
                return false
            }
        } catch {
            reporter.error("Restore state failed: \(String(describing: error))")
            updateRuntimeReadiness(.degraded(.restoreUnavailable))
            return false
        }
    }

    @MainActor
    private func applyStartupConverge() async {
        switch await worldActor.planCurrentLayout() {
        case .success(nil):
            reporter.info("Startup restore convergence skipped: no restored tiled windows")
        case .success(let result?):
            let applyResult = await LayoutApplier(axClient: axClient, reporter: reporter, echoSuppressor: echoSuppressor).apply(result)
            if applyResult.succeeded {
                guard await worldActor.commit(result, appliedFrames: applyResult.applied) else {
                    reporter.error("Startup restore convergence became stale before commit; reconciling live frames")
                    _ = await refreshEnvironment(reason: "stale startup convergence")
                    return
                }
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
        switch await backgroundStartupConfigLoad() {
        case .success(let value):
            loaded = value
        case .failure(let error):
            reporter.error("Config reload failed (\(reason)): \(error.description)")
            configHealthy = false
            configWarning = .configReloadFailed
            menubar.updateConfigStatus(.failed(error.description))
            if servicesStarted {
                updateRuntimeReadiness(operationalReadiness)
            }
            showOperatorFeedback("Config reload failed", tone: .error)
            return
        }

        do {
            try hotkeyManager?.rebind(loaded.config.keymap)
        } catch {
            let message = String(describing: error)
            reporter.error("Config reload failed rebinding hotkeys (\(reason)): \(message)")
            configHealthy = false
            configWarning = .configReloadFailed
            menubar.updateConfigStatus(.failed(message))
            if servicesStarted {
                updateRuntimeReadiness(operationalReadiness)
            }
            showOperatorFeedback("Hotkey rebind failed", tone: .error)
            return
        }

        let activeConfig = configByRefreshingManagedRules(loaded.config)
        config = activeConfig
        configHealthy = true
        startupConfigFailure = nil
        configWarning = nil
        await worldActor.reloadConfig(activeConfig)
        overlay.updateConfig(border: activeConfig.border, hud: activeConfig.hud)
        eventTapClient?.updateModifier(activeConfig.dragModifier)
        logStartupConfig(loaded)
        menubar.updateConfigStatus(.loaded)
        if servicesStarted {
            updateRuntimeReadiness(operationalReadiness)
        }
        reporter.info("Config reload completed (\(reason))")
        showOperatorFeedback("Config reloaded", tone: .success)
        workbenchController.refreshIfVisible()
    }

    private func activateManagedRules(_ rules: [ManagedWindowRule]) async {
        managedRules = rules
        managedRulesWarning = nil
        let activeConfig = config.withManagedRules(rules)
        config = activeConfig
        await worldActor.reloadConfig(activeConfig)
        reporter.info("Activated \(rules.count) managed window rules from Layout Workbench")
    }

    private func applyWorkbenchPlan(
        _ result: CommandPlanResult,
        intent: WorkbenchIntent
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: intent.label,
            persistReason: "workbench \(intent.label.lowercased())",
            retryOnClamp: intent != .shuffle,
            replanAfterClamp: { [worldActor] in
                switch await planWorkbenchIntent(intent, with: worldActor) {
                case .success(let plan):
                    return .success(plan)
                case .failure(.command(let error)):
                    return .failure(error)
                case .failure(let failure):
                    return .failure(.configInvalid(workbenchExplanation(for: failure).reason))
                }
            }
        )
    }

    private func backgroundStartupConfigLoad() async -> Result<StartupConfigLoad, StartupConfigError> {
        let request = startupArguments.startupConfigRequest
        return await Task.detached(priority: .userInitiated) {
            switch request {
            case .success(let request):
                return StartupConfigLoader(
                    configURL: request.url,
                    missingFilePolicy: request.missingFilePolicy
                ).load()
            case .failure(let error):
                return .failure(error)
            }
        }.value
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
            await handleExternalGeometryEvent(event, snapshot: snapshot)
        case .windowOpened(let metadata):
            scheduleCoalescedEnvironmentRefresh(.windowOpened(metadata.id))
        case .windowClosed(let windowID):
            await worldActor.removeWindowFromActiveSpace(windowID)
            removeWindowFromOverlays(windowID)
            if operatingStatus.focusedWindowID == windowID {
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
            await updateTiledBordersFromWorld()
            scheduleCoalescedEnvironmentRefresh(.windowClosed(windowID))
        }
    }

    @MainActor
    private func handleExternalGeometryEvent(
        _ event: AXEvent,
        snapshot: FocusedWindowSnapshot?
    ) async {
        let incoming = PendingExternalGeometryEvent(event: event, snapshot: snapshot)
        guard !isHandlingExternalGeometry else {
            if let windowID = externalGeometryWindowID(for: event) {
                pendingExternalGeometryEvents.enqueue(incoming, for: windowID)
            }
            return
        }

        isHandlingExternalGeometry = true
        var current: PendingExternalGeometryEvent? = incoming
        while let currentEvent = current {
            let windowID = externalGeometryWindowID(for: currentEvent.event)
            if let windowID {
                await worldActor.setWindowInteraction(.manualAdjustment, for: windowID)
                await refreshWorkspacePresentationSurfaces()
            }
            let resolvedInteraction = await commandExecutionGate.perform {
                await self.processExternalGeometryEvent(currentEvent.event, snapshot: currentEvent.snapshot)
            }
            if let windowID {
                await worldActor.setWindowInteraction(resolvedInteraction, for: windowID)
                await refreshWorkspacePresentationSurfaces()
            }
            current = pendingExternalGeometryEvents.dequeue()
        }
        isHandlingExternalGeometry = false
    }

    @MainActor
    private func processExternalGeometryEvent(
        _ event: AXEvent,
        snapshot: FocusedWindowSnapshot?
    ) async -> WindowInteractionState? {
        let metricInterval = runtimeMetrics.begin(.manualResizeHandoff)
        defer { runtimeMetrics.end(metricInterval) }
        let selectedEvent = externalGeometryEventSelection(
            for: event,
            liveSnapshot: axClient.windowSnapshot(),
            tolerance: Self.externalGeometryEventTolerance
        )
        if selectedEvent.usedLiveFrame {
            reporter.info("External geometry event converged to settled live frame")
        }

        switch await worldActor.planExternalGeometry(selectedEvent.event) {
        case .success(let result?):
            let preservedFrames = preservedExternalGeometryFrames(
                selection: selectedEvent,
                plan: result
            )
            let completed = await applyPlannedLayout(
                result,
                operation: "Manual resize",
                persistReason: "manual resize",
                retryOnClamp: true,
                showFocusBorder: snapshot != nil,
                preserving: preservedFrames,
                writeStrategy: .coordinated
            ) {
                await self.replanExternalGeometryAfterClamp(result)
            }
            if let snapshot {
                await updateFocusBorderFromWorld(windowID: snapshot.id)
            }
            if !completed {
                await worldActor.recordExternalGeometry(selectedEvent.event)
                await updateTiledBordersFromWorld()
                return .temporarilyDetached(.applicationConstraint)
            }
            return nil
        case .success(nil):
            if let snapshot {
                await updateFocusBorderFromWorld(windowID: snapshot.id)
            }
            await updateTiledBordersFromWorld()
            return nil
        case .failure(let error):
            reporter.error("External geometry rejected by core: \(error.message)")
            await worldActor.recordExternalGeometry(selectedEvent.event)
            if let snapshot {
                await updateFocusBorderFromWorld(windowID: snapshot.id)
            }
            await updateTiledBordersFromWorld()
            return .temporarilyDetached(.userMoved)
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
            var appliedPendingTileRules = false
            if completed && policy.applyPendingTileRules && !environment.preservedSpaceLayouts {
                appliedPendingTileRules = await applyPendingTileRules(
                    reason: "coalesced \(completedRequest.description)"
                )
            }
            if completed
                && policy.reflowTiledLayout
                && !environment.preservedSpaceLayouts
                && !appliedPendingTileRules
            {
                await applySettledDisplayLayout(reason: completedRequest.description)
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
    private func applySettledDisplayLayout(reason: String) async {
        guard !isPaused else {
            reporter.info("Display reflow deferred while paused (\(reason))")
            return
        }
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Display reflow requires Accessibility permission (\(reason))")
            return
        }

        switch await worldActor.planCurrentLayout() {
        case .success(nil):
            reporter.info("Display reflow completed with no tiled windows (\(reason))")
            await persistRestore(reason: "display topology")
        case .success(let result?):
            _ = await applyPlannedLayout(
                result,
                operation: "Display reflow",
                persistReason: "display topology",
                retryOnClamp: true,
                showFocusBorder: false,
                writeStrategy: .coordinated
            ) {
                await self.currentLayoutRetryPlan()
            }
        case .failure(let error):
            reporter.error("Display reflow rejected by core (\(reason)): \(error.message)")
        }
    }

    private func currentLayoutRetryPlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planCurrentLayout() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.activeSpaceUnavailable)
        case .failure(let error):
            return .failure(error)
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
        await commandExecutionGate.perform {
            await self.handleSerializedIPCCommand(command)
        }
    }

    @MainActor
    private func handleSerializedIPCCommand(_ command: IPCCommandDTO) async -> IPCReplyDTO {
        let commandID = CommandID(raw: "ipc-\(UUID().uuidString)")
        switch command {
        case .status:
            return .diagnostics(commandID: commandID, value: await runtimeDiagnostics())
        case .resetLayout:
            await performResetLayout(requiresConfirmation: false, logPrefix: "IPC reset", persistReason: "ipc reset")
            return .ok(commandID: commandID)
        case .quit:
            reporter.info("IPC quit requested")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                await self?.requestTermination()
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
        switch await requireIPCPlanningEnvironment(operation: operation, refreshReason: refreshReason) {
        case .success(let activeSpace):
            reporter.info("\(operation) selected active Space \(activeSpace.raw)")
        case .failure(let failure):
            return failure
        }

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
    private func requireIPCPlanningEnvironment(
        operation: String,
        refreshReason: String
    ) async -> Result<SpaceID, CommandExecutionFailure> {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return .failure(CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            ))
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironment(
            reason: refreshReason,
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard let activeSpace = environment.activeSpace else {
            return .failure(CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable"))
        }
        guard case .complete = environment.quality else {
            return .failure(CommandExecutionFailure(
                code: "environment_incomplete",
                message: "\(operation) requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            ))
        }
        return .success(activeSpace)
    }

    @MainActor
    private func performExplicitLayoutPlan(
        operation: String,
        refreshReason: String,
        applyFailureMessage: String,
        plan: () async -> Result<CommandPlanResult, CommandError>,
        apply: (CommandPlanResult) async -> Bool
    ) async -> CommandExecutionFailure? {
        if case .failure(let failure) = await requireIPCPlanningEnvironment(
            operation: operation,
            refreshReason: refreshReason
        ) {
            return failure
        }

        switch await plan() {
        case .success(let result):
            if await apply(result) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: applyFailureMessage
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitPush(windowID: WindowID, direction: Direction) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC push",
            refreshReason: "ipc push \(direction.rawValue)",
            applyFailureMessage: "Push \(direction.rawValue) layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planPush(windowID, direction: direction) },
            apply: { result in
                await self.applyPlannedPush(result, direction: direction, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitCenter(windowID: WindowID) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC center",
            refreshReason: "ipc center",
            applyFailureMessage: "Center layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planCenter(windowID) },
            apply: { result in
                await self.applyPlannedCenter(result, windowID: windowID, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitEject(windowID: WindowID) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC eject",
            refreshReason: "ipc eject",
            applyFailureMessage: "Eject layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planEject(windowID) },
            apply: { result in
                await self.applyPlannedEject(result, windowID: windowID, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitToggleFloat(windowID: WindowID) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC toggleFloat",
            refreshReason: "ipc toggle float",
            applyFailureMessage: "Toggle float layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planToggleFloat(windowID) },
            apply: { result in
                await self.applyPlannedToggleFloat(result, windowID: windowID, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitFocus(windowID: WindowID) async -> CommandExecutionFailure? {
        if case .failure(let failure) = await requireIPCPlanningEnvironment(
            operation: "IPC focus",
            refreshReason: "ipc focus"
        ) {
            return failure
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
        await performExplicitLayoutPlan(
            operation: "IPC swap",
            refreshReason: "ipc swap \(direction.rawValue)",
            applyFailureMessage: "Swap \(direction.rawValue) layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planSwap(windowID, direction: direction) },
            apply: { result in
                await self.applyPlannedSwap(result, windowID: windowID, direction: direction, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitResize(
        windowID: WindowID,
        direction: Direction,
        delta: Double
    ) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC resize",
            refreshReason: "ipc resize \(direction.rawValue)",
            applyFailureMessage: "Resize \(direction.rawValue) layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planResize(windowID, direction: direction, delta: delta) },
            apply: { result in
                await self.applyPlannedResize(
                    result,
                    windowID: windowID,
                    direction: direction,
                    deltas: [delta],
                    retryOnClamp: true
                )
            }
        )
    }

    @MainActor
    private func persistRestore(reason: String) async {
        let stored = await worldActor.restoreSnapshot()
        restorePersistence.scheduleSave(stored, reason: reason)
    }

    @MainActor
    private func requestTermination() async {
        reporter.info("Termination requested; flushing restore state")
        await restorePersistence.flushPending()
        reporter.info("Termination restore flush completed")
        terminationFlushState = .approved
        NSApplication.shared.terminate(nil)
    }

    private func runtimeDiagnostics() async -> RuntimeDiagnostics {
        let bundle = Bundle.main
        return RuntimeDiagnostics(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            accessibilityTrusted: operatingStatus.accessibilityTrusted == true,
            notificationFastPathActive: axObserverService?.notificationFastPathActive == true,
            configHealthy: configHealthy,
            paused: isPaused,
            activeSpaceID: operatingStatus.activeSpace?.raw,
            displayCount: operatingStatus.displayCount ?? 0,
            windowCount: operatingStatus.windowCount ?? 0,
            tiledWindowCount: await worldActor.tiledWindowCount(),
            snapshotQuality: runtimeSnapshotQuality(operatingStatus.snapshotQuality),
            focusedWindowID: operatingStatus.focusedWindowID?.raw,
            lastCommand: operatingStatus.lastCommand,
            pendingHotkeyCount: pendingHotkeys.count,
            pendingGeometryEventCount: pendingExternalGeometryEvents.count,
            droppedLogLineCount: reporter.droppedLogLineCount,
            latency: runtimeMetrics.summaries()
        )
    }

    @MainActor
    private func copyDiagnosticsToPasteboard() async {
        do {
            try copyRuntimeDiagnostics(await runtimeDiagnostics())
            reporter.info("Runtime diagnostics copied to pasteboard")
            showOperatorFeedback("Diagnostics copied", tone: .success)
        } catch {
            reporter.error("Runtime diagnostics copy failed: \(String(describing: error))")
            showOperatorFeedback("Diagnostics copy failed", tone: .error)
        }
    }

    private func exitAfterFlushing(_ status: Int32) -> Never {
        reporter.flush()
        Darwin.exit(status)
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

private func runtimeSnapshotQuality(_ quality: AXSnapshotQuality?) -> RuntimeSnapshotQuality {
    switch quality {
    case .complete:
        return .complete
    case .partial:
        return .partial
    case .permissionDenied:
        return .permissionDenied
    case .unavailable:
        return .unavailable
    case nil:
        return .unknown
    }
}
