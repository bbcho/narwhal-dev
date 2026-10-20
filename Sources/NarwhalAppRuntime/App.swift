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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()
    static let environmentRefreshCoalescingDelay: TimeInterval = 0.10
    static let externalGeometryEventTolerance: CGFloat = frameWriteSettleTolerance
    static let activeSpaceTransitionPreserveDuration: TimeInterval = 1.25
    static let activeSpaceFocusRecoveryDuration: TimeInterval = 5.0
    static let activeSpaceSettledRefreshDelays: [TimeInterval] = [0.35, 0.80]
    static let displaySettledRefreshDelay: TimeInterval = 6.0
    static let restoreSaveDebounceInterval: TimeInterval = 0.25
    private static let terminationFlushTimeoutNanoseconds: UInt64 = 2_000_000_000

    let runtimeMetrics = RuntimeMetrics()
    lazy var axClient = AXClient(runtimeMetrics: runtimeMetrics)
    let displayClient = DisplayClient()
    let spaceClient = SpaceClient()
    lazy var desktopWindowMover = DesktopWindowMover(axClient: axClient, spaceClient: spaceClient)
    var restorePersistence = RestorePersistence(manager: RestoreManager())
    let managedRulesStore = ManagedRulesStore()
    let echoSuppressor = AXEchoSuppressor()
    let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
    var overlayModel = OverlayModel.empty
    let menubar = Menubar()
    let loginItemController = LoginItemController()
    let updateChecker = UpdateChecker()
    let startupArguments = StartupArguments.current
    lazy var worldActor = WorldActor(runtimeMetrics: runtimeMetrics)
    let reporter = StartupReporter()
    lazy var layoutTransactionCoordinator = LayoutTransactionCoordinator(
        worldActor: worldActor,
        frameTransaction: LayoutFrameTransaction(
            axClient: axClient,
            reporter: reporter,
            echoSuppressor: echoSuppressor,
            runtimeMetrics: runtimeMetrics
        ),
        runtimeMetrics: runtimeMetrics
    )
    lazy var layoutPresentationCoordinator = LayoutPresentationCoordinator(
        currentModel: { [weak self] in self?.overlayModel ?? .empty },
        publish: { [weak self] model in
            self?.publishOverlayModel(model)
        }
    )
    lazy var externalGeometryCoordinator = ExternalGeometryCoordinator {
        [weak self] event, snapshot in
        await self?.handleSettledExternalGeometryEvent(event, snapshot: snapshot)
    }
    lazy var workbenchController = LayoutWorkbenchController(
        worldActor: worldActor,
        snapshotQuality: { [weak self] in self?.operatingStatus.snapshotQuality },
        applyPlan: { [weak self] result, intent in
            guard let self else { return false }
            return await self.workspaceMutationGate.perform {
                await self.applyWorkbenchPlan(result, intent: intent)
            }
        },
        activateManagedRules: { [weak self] rules in
            guard let self else { return }
            let activation: Result<Void, Error> = await self.workspaceMutationGate.perform {
                do {
                    try await self.activateManagedRules(rules)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            try activation.get()
        },
        managedRulesSnapshot: { [weak self] in
            self?.managedRules ?? []
        },
        openAccessibilitySettings: { [weak self] in
            self?.openAccessibilitySettingsFromMenu()
        }
    )
    var config = Config.default
    var managedRules: [ManagedWindowRule] = []
    var managedRulesWarning: String?
    var operatingStatus = MenubarOperatingStatus.empty
    var accessibilityPollTimer: Timer?
    var hotkeyManager: HotkeyManager?
    var axObserverService: AXObserverService?
    var displayObserverService: DisplayObserverService?
    var configFileWatcherService: ConfigFileWatcherService?
    var ipcServer: IPCServer?
    var eventTapClient: EventTapClient?
    var environmentRefreshCoalescer = EnvironmentRefreshCoalescerState.empty
    var environmentRefreshCoalescingTimer: Timer?
    var environmentRefreshCoalescingTimerGeneration: UInt64?
    var displaySettledRefreshTimer: Timer?
    var spaceSettledRefreshTimers: [Timer] = []
    var spaceTransitionPreserveTimer: Timer?
    var spaceTransitionPreservation = SpaceTransitionPreservationState.empty
    var activeSpaceFocusRecoveryDeadline: Date?
    var pendingHotkeys: [HotkeyAction] = []
    var isDrainingHotkeys = false
    let workspaceMutationGate = WorkspaceMutationGate()
    var runningServices: RunningServices?
    var servicesStarted = false
    var isPaused = false
    var configHealthy = true
    var startupConfigFailure: StartupConfigError?
    var configWarning: RuntimeReadinessIssue?
    var restoreWarning: RuntimeReadinessIssue?
    /// Set when the restore file is from a newer Narwhal or unreadable, so this
    /// session never overwrites it.
    var restoreSavingSuspended = false
    var dragStartWindow: DragStartWindow?
    /// Lets an in-flight layout transaction notice a Space switch, which
    /// arrives outside the mutation gate while the transaction awaits AX.
    var activeSpaceChangeCount = 0
    var runtimeReadiness: RuntimeReadiness = .starting
    private var terminationFlushState: TerminationFlushState = .idle
    private var terminationFlushTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    var updateCheckTask: Task<Void, Never>?
    var updateStatus: UpdateMenuStatus = .idle
    // AX raise failures survive environment refreshes, so exclusions are session-scoped.
    var axRaiseBlocklist: Set<WindowID> = []

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
                await workspaceMutationGate.perform {
                    let focused = reportFocusedWindowSnapshot()
                    let environment = await refreshEnvironmentLocked(reason: "check")
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
        externalGeometryCoordinator.cancelAll()
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
        let transition = completeTerminationFlush(in: terminationFlushState)
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

    func updateOperatingStatus(_ update: (inout MenubarOperatingStatus) -> Void) {
        update(&operatingStatus)
        menubar.updateOperatingStatus(operatingStatus)
    }

    func updateRuntimeReadiness(_ readiness: RuntimeReadiness) {
        runtimeReadiness = readiness
        menubar.updateRuntimeReadiness(readiness)
    }

    func showOperatorFeedback(_ message: String, tone: OverlayTone, showsHUD: Bool = true) {
        updateOperatingStatus { status in
            status.lastCommand = message
        }
        if showsHUD {
            overlay.showHUD(message, tone: tone)
        }
    }

    @discardableResult
    func reportAccessibilityStatus(prompt: Bool) -> AccessibilityStatus {
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
    func startAfterAccessibilityTrusted() async {
        await workspaceMutationGate.perform {
            await self.startAfterAccessibilityTrustedLocked()
        }
    }

    @MainActor
    private func startAfterAccessibilityTrustedLocked() async {
        guard !servicesStarted else { return }
        updateRuntimeReadiness(.starting)
        reporter.info("Rung 1 complete: AppKit run loop is active and Accessibility is trusted")
        let focused = reportFocusedWindowSnapshot()
        let environment = await refreshEnvironmentLocked(reason: "startup")
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
        await applyStartupConvergeLocked()
        await applyPendingTileRulesLocked(reason: "startup")
        startServices()
    }

    @MainActor
    func persistRestore(reason: String) async {
        guard !restoreSavingSuspended else { return }
        let stored = await worldActor.restoreSnapshot()
        restorePersistence.scheduleSave(stored, reason: reason)
    }

    @MainActor
    func requestTermination() async {
        reporter.info("Termination requested; flushing restore state")
        await restorePersistence.flushPending()
        reporter.info("Termination restore flush completed")
        terminationFlushState = .approved
        NSApplication.shared.terminate(nil)
    }

    func exitAfterFlushing(_ status: Int32) -> Never {
        reporter.flush()
        Darwin.exit(status)
    }
}

func logRestoreSaveEvent(_ event: RestoreSaveEvent, reporter: StartupReporter) {
    switch event {
    case .saved(let result):
        reporter.info("Restore state saved (\(result.reason)) to \(result.urlPath)")
    case .failed(let failure):
        reporter.error("Restore state save failed (\(failure.reason)): \(failure.message)")
    }
}

func runtimeSnapshotQuality(_ quality: AXSnapshotQuality?) -> RuntimeSnapshotQuality {
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
