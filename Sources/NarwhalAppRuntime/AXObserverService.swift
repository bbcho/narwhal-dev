import AppKit
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class AXObserverService {
    private static let reconciliationInterval: TimeInterval = 1.0
    private static let geometryThrottleInterval: TimeInterval = 1.0 / 30.0
    private static let frameTolerance: CGFloat = 1

    private let focusedWindowSnapshot: @MainActor () -> Result<FocusedWindowSnapshot, AXClientError>
    private let windowSnapshot: @MainActor () -> AXWindowSnapshot
    private let echoSuppressor: AXEchoSuppressor
    private let reporter: StartupReporter
    private let activeSpaceByDisplay: @MainActor ([WindowMetadata]) -> [DisplayID: SpaceID]
    private let emit: @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    private let spaceChanged: @MainActor () -> Void
    private let notificationFastPathEnabled: Bool
    private var reconciliationTimer: Timer?
    private var geometryThrottleTimer: Timer?
    private var settleTimers: [Timer] = []
    private var workspaceObserver: NSObjectProtocol?
    private var notificationClient: AXNotificationClient?
    private var geometryThrottleState = AXGeometryNotificationThrottleState.idle
    private var focusedObservationState = FocusedWindowObservationState.empty
    private var focusedAvailabilityLogState = FocusedWindowAvailabilityLogState.empty
    private var windowInventoryObservationState = WindowInventoryObservationState.empty

    init(
        axClient: AXClient,
        echoSuppressor: AXEchoSuppressor,
        reporter: StartupReporter,
        activeSpaceByDisplay: @escaping @MainActor ([WindowMetadata]) -> [DisplayID: SpaceID],
        spaceChanged: @escaping @MainActor () -> Void,
        emit: @escaping @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    ) {
        self.focusedWindowSnapshot = axClient.focusedWindowSnapshot
        self.windowSnapshot = axClient.windowSnapshot
        self.echoSuppressor = echoSuppressor
        self.reporter = reporter
        self.activeSpaceByDisplay = activeSpaceByDisplay
        self.spaceChanged = spaceChanged
        self.emit = emit
        self.notificationFastPathEnabled = true
    }

    init(
        focusedWindowSnapshot: @escaping @MainActor () -> Result<FocusedWindowSnapshot, AXClientError>,
        windowSnapshot: @escaping @MainActor () -> AXWindowSnapshot,
        echoSuppressor: AXEchoSuppressor,
        reporter: StartupReporter,
        activeSpaceByDisplay: @escaping @MainActor ([WindowMetadata]) -> [DisplayID: SpaceID],
        spaceChanged: @escaping @MainActor () -> Void,
        notificationFastPathEnabled: Bool = false,
        emit: @escaping @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    ) {
        self.focusedWindowSnapshot = focusedWindowSnapshot
        self.windowSnapshot = windowSnapshot
        self.echoSuppressor = echoSuppressor
        self.reporter = reporter
        self.activeSpaceByDisplay = activeSpaceByDisplay
        self.spaceChanged = spaceChanged
        self.emit = emit
        self.notificationFastPathEnabled = notificationFastPathEnabled
    }

    func start() {
        guard reconciliationTimer == nil else { return }
        pollFocusedWindow()
        syncWindowInventory()
        reconciliationTimer = makeTimer(interval: Self.reconciliationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollFocusedWindow()
                self?.pollVisibleWindowInventory()
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.activeSpaceChanged()
            }
        }
        if notificationFastPathEnabled {
            let notificationClient = AXNotificationClient(reporter: reporter) { [weak self] event in
                self?.handleNotificationEvent(event)
            }
            notificationClient.start()
            self.notificationClient = notificationClient
        }
        let fastPath = notificationFastPathActive ? "active" : "unavailable; using reconciliation fallback"
        reporter.info("AX observer ready; notification fast path \(fastPath)")
    }

    func stop() {
        notificationClient?.stop()
        notificationClient = nil
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        geometryThrottleTimer?.invalidate()
        geometryThrottleTimer = nil
        geometryThrottleState = reduceAXGeometryNotificationThrottle(
            state: geometryThrottleState,
            input: .cancelled
        ).state
        settleTimers.forEach { $0.invalidate() }
        settleTimers.removeAll()
        focusedAvailabilityLogState = .empty
        windowInventoryObservationState = .empty
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    func pollFocusedWindowNow() {
        pollFocusedWindow()
    }

    var notificationFastPathActive: Bool {
        notificationClient?.isActive == true
    }

    private func handleNotificationEvent(_ event: AXNotificationEvent) {
        switch event {
        case .applicationActivated:
            cancelGeometryThrottle()
            pollFocusedWindow()
            pollVisibleWindowInventory()
        case .focusedWindowChanged:
            cancelGeometryThrottle()
            pollFocusedWindow()
        case .focusedWindowGeometryChanged:
            applyGeometryThrottleInput(.notificationReceived)
        case .windowInventoryChanged:
            pollVisibleWindowInventory()
        }
    }

    private func cancelGeometryThrottle() {
        geometryThrottleTimer?.invalidate()
        geometryThrottleTimer = nil
        geometryThrottleState = reduceAXGeometryNotificationThrottle(
            state: geometryThrottleState,
            input: .cancelled
        ).state
    }

    private func applyGeometryThrottleInput(_ input: AXGeometryNotificationThrottleInput) {
        let transition = reduceAXGeometryNotificationThrottle(
            state: geometryThrottleState,
            input: input
        )
        geometryThrottleState = transition.state
        for effect in transition.effects {
            switch effect {
            case .pollFocusedWindow:
                pollFocusedWindow()
            case .scheduleTimer:
                scheduleGeometryThrottleTimer()
            }
        }
    }

    private func scheduleGeometryThrottleTimer() {
        geometryThrottleTimer?.invalidate()
        geometryThrottleTimer = makeTimer(
            interval: Self.geometryThrottleInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.geometryThrottleTimer = nil
                self?.applyGeometryThrottleInput(.timerFired)
            }
        }
    }

    private func activeSpaceChanged() {
        if activeSpaceNotificationOnlyChangedFocusedDisplay() {
            reporter.info("Active Space notification kept display Space topology unchanged; preserving borders")
            pollFocusedWindowAfterDelay(0.05)
            pollFocusedWindowAfterDelay(0.15)
            return
        }

        settleTimers.forEach { $0.invalidate() }
        settleTimers.removeAll()
        focusedObservationState = .empty
        windowInventoryObservationState = .empty
        spaceChanged()
        reporter.info("Active Space changed; focus border hidden pending focused-window refresh")
        pollFocusedWindowAfterDelay(0.05)
        pollFocusedWindowAfterDelay(0.15)
        pollFocusedWindowAfterDelay(0.35)
    }

    private func activeSpaceNotificationOnlyChangedFocusedDisplay() -> Bool {
        let snapshot = windowSnapshot()
        guard case .complete = snapshot.quality else { return false }
        let nextActiveSpaceByDisplay = activeSpaceByDisplay(snapshot.windows)
        guard !windowInventoryObservationState.activeSpaceByDisplay.isEmpty,
              !nextActiveSpaceByDisplay.isEmpty,
              windowInventoryObservationState.activeSpaceByDisplay == nextActiveSpaceByDisplay
        else { return false }

        return true
    }

    private func pollFocusedWindowAfterDelay(_ delay: TimeInterval) {
        let timer = makeTimer(interval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                self?.settleTimers.removeAll { $0 === timer }
                self?.pollFocusedWindow()
            }
        }
        settleTimers.append(timer)
    }

    private func makeTimer(
        interval: TimeInterval,
        repeats: Bool,
        block: @Sendable @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func pollFocusedWindow() {
        let transition: FocusedWindowObservationTransition
        switch focusedWindowSnapshot() {
        case .success(let value):
            transition = reduceFocusedWindowObservation(
                state: focusedObservationState,
                input: .observed(windowID: value.id, frame: value.frame),
                tolerance: Self.frameTolerance
            )
            focusedObservationState = transition.state
            handleFocusedObservationEffects(transition.effects, snapshot: value)
            handleFocusedAvailabilityEffects(reduceFocusedWindowAvailabilityLog(
                state: focusedAvailabilityLogState,
                input: .observed
            ))
        case .failure(let error):
            transition = reduceFocusedWindowObservation(
                state: focusedObservationState,
                input: .unavailable,
                tolerance: Self.frameTolerance
            )
            focusedObservationState = transition.state
            handleFocusedObservationEffects(transition.effects, snapshot: nil)
            handleFocusedAvailabilityEffects(reduceFocusedWindowAvailabilityLog(
                state: focusedAvailabilityLogState,
                input: .unavailable(
                    reason: error.description,
                    hasLastFocusedWindow: focusedObservationState.geometry.windowID != nil
                )
            ))
        }
    }

    private func handleFocusedObservationEffects(
        _ effects: [FocusedWindowObservationEffect],
        snapshot: FocusedWindowSnapshot?
    ) {
        for effect in effects {
            switch effect {
            case .emit(let event):
                guard !echoSuppressor.isExpectedEcho(event) else {
                    if let snapshot {
                        reporter.info("Suppressed expected AX echo for \(snapshot.id.description)")
                    }
                    continue
                }
                emit(event, snapshot)
            }
        }
    }

    private func handleFocusedAvailabilityEffects(_ transition: FocusedWindowAvailabilityTransition) {
        focusedAvailabilityLogState = transition.state
        for effect in transition.effects {
            switch effect {
            case .logUnavailable(let reason, let preservingLastFocus):
                let action = preservingLastFocus ? "preserving last focus border" : "no previous focus border to preserve"
                reporter.info("Focused-window snapshot unavailable; \(action): \(reason)")
            case .logRecovered(let missedPolls):
                reporter.info("Focused-window snapshot recovered after \(missedPolls) unavailable poll(s)")
            }
        }
    }

    private func syncWindowInventory() {
        let snapshot = windowSnapshot()
        guard case .complete = snapshot.quality else { return }
        windowInventoryObservationState = windowInventoryObservationBaseline(
            windows: snapshot.windows,
            activeSpaceByDisplay: activeSpaceByDisplay(snapshot.windows)
        )
    }

    private func pollVisibleWindowInventory() {
        let snapshot = windowSnapshot()
        guard case .complete = snapshot.quality else { return }
        let transition = observeWindowInventory(
            windows: snapshot.windows,
            activeSpaceByDisplay: activeSpaceByDisplay(snapshot.windows),
            tolerance: Self.frameTolerance,
            excludedFrameEventWindowIDs: focusedFrameInventoryEventExclusions(),
            in: windowInventoryObservationState
        )
        windowInventoryObservationState = transition.state

        switch transition.effect {
        case .activeSpaceChanged:
            reporter.info("Active Space changed during inventory poll; inventory baseline reset")
            activeSpaceChanged()
            return
        case .likelySpaceReplacement:
            reporter.info("Suppressed likely Space replacement inventory diff")
            activeSpaceChanged()
            return
        case nil:
            break
        }

        for event in transition.events {
            emit(event, nil)
        }

        for event in transition.frameEvents {
            guard !echoSuppressor.isExpectedEcho(event) else {
                reporter.info("Suppressed expected AX echo for frame inventory event")
                continue
            }
            emit(event, nil)
        }
    }

    private func focusedFrameInventoryEventExclusions() -> Set<WindowID> {
        guard let windowID = focusedObservationState.geometry.windowID else { return [] }
        return [windowID]
    }
}
