import AppKit
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class AXObserverService {
    private static let pollInterval: TimeInterval = 0.15
    private static let frameTolerance: CGFloat = 1

    private let focusedWindowSnapshot: @MainActor () -> Result<FocusedWindowSnapshot, AXClientError>
    private let windowSnapshot: @MainActor () -> AXWindowSnapshot
    private let echoSuppressor: AXEchoSuppressor
    private let reporter: StartupReporter
    private let activeSpaceByDisplay: @MainActor ([WindowMetadata]) -> [DisplayID: SpaceID]
    private let emit: @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    private let spaceChanged: @MainActor () -> Void
    private var timer: Timer?
    private var settleTimers: [Timer] = []
    private var workspaceObserver: NSObjectProtocol?
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
    }

    init(
        focusedWindowSnapshot: @escaping @MainActor () -> Result<FocusedWindowSnapshot, AXClientError>,
        windowSnapshot: @escaping @MainActor () -> AXWindowSnapshot,
        echoSuppressor: AXEchoSuppressor,
        reporter: StartupReporter,
        activeSpaceByDisplay: @escaping @MainActor ([WindowMetadata]) -> [DisplayID: SpaceID],
        spaceChanged: @escaping @MainActor () -> Void,
        emit: @escaping @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    ) {
        self.focusedWindowSnapshot = focusedWindowSnapshot
        self.windowSnapshot = windowSnapshot
        self.echoSuppressor = echoSuppressor
        self.reporter = reporter
        self.activeSpaceByDisplay = activeSpaceByDisplay
        self.spaceChanged = spaceChanged
        self.emit = emit
    }

    func start() {
        guard timer == nil else { return }
        pollFocusedWindow()
        syncWindowInventory()
        timer = makeTimer(interval: Self.pollInterval, repeats: true) { [weak self] _ in
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
        reporter.info("AX focus observer ready")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settleTimers.forEach { $0.invalidate() }
        settleTimers.removeAll()
        focusedAvailabilityLogState = .empty
        windowInventoryObservationState = .empty
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
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
}
