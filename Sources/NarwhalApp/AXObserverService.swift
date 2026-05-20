import AppKit
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class AXObserverService {
    private static let pollInterval: TimeInterval = 0.15
    private static let frameTolerance: CGFloat = 1

    private let axClient: AXClient
    private let echoSuppressor: AXEchoSuppressor
    private let reporter: StartupReporter
    private let activeSpaceID: @MainActor () -> SpaceID?
    private let focusedWindowUnavailable: @MainActor () -> Void
    private let emit: @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    private let spaceChanged: @MainActor () -> Void
    private var timer: Timer?
    private var settleTimers: [Timer] = []
    private var workspaceObserver: NSObjectProtocol?
    private var focusedObservationState = FocusedWindowObservationState.empty
    private var windowInventoryState: WindowInventoryState?
    private var windowFrameInventoryState: WindowFrameInventoryState?
    private var windowInventorySpaceID: SpaceID?

    init(
        axClient: AXClient,
        echoSuppressor: AXEchoSuppressor,
        reporter: StartupReporter,
        activeSpaceID: @escaping @MainActor () -> SpaceID?,
        focusedWindowUnavailable: @escaping @MainActor () -> Void,
        spaceChanged: @escaping @MainActor () -> Void,
        emit: @escaping @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    ) {
        self.axClient = axClient
        self.echoSuppressor = echoSuppressor
        self.reporter = reporter
        self.activeSpaceID = activeSpaceID
        self.focusedWindowUnavailable = focusedWindowUnavailable
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
        windowInventoryState = nil
        windowFrameInventoryState = nil
        windowInventorySpaceID = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    private func activeSpaceChanged() {
        settleTimers.forEach { $0.invalidate() }
        settleTimers.removeAll()
        focusedObservationState = .empty
        windowInventoryState = nil
        windowFrameInventoryState = nil
        windowInventorySpaceID = nil
        spaceChanged()
        reporter.info("Active Space changed; focus border hidden pending focused-window refresh")
        pollFocusedWindowAfterDelay(0.05)
        pollFocusedWindowAfterDelay(0.15)
        pollFocusedWindowAfterDelay(0.35)
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
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            transition = reduceFocusedWindowObservation(
                state: focusedObservationState,
                input: .observed(windowID: value.id, frame: value.frame),
                tolerance: Self.frameTolerance
            )
            focusedObservationState = transition.state
            handleFocusedObservationEffects(transition.effects, snapshot: value)
        case .failure(let error):
            transition = reduceFocusedWindowObservation(
                state: focusedObservationState,
                input: .unavailable,
                tolerance: Self.frameTolerance
            )
            focusedObservationState = transition.state
            handleFocusedObservationEffects(transition.effects, snapshot: nil)
            if transition.effects.contains(.focusedWindowUnavailable) {
                reporter.info("Focused-window snapshot unavailable; focus border hidden: \(error.description)")
            }
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
            case .focusedWindowUnavailable:
                focusedWindowUnavailable()
            }
        }
    }

    private func syncWindowInventory() {
        let snapshot = axClient.windowSnapshot()
        guard case .complete = snapshot.quality else { return }
        windowInventoryState = WindowInventoryState(
            visibleWindowIDs: Set(snapshot.windows.map(\.id))
        )
        windowFrameInventoryState = WindowFrameInventoryState(
            framesByWindowID: Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0.frame) })
        )
        windowInventorySpaceID = activeSpaceID()
    }

    private func pollVisibleWindowInventory() {
        let snapshot = axClient.windowSnapshot()
        guard case .complete = snapshot.quality else { return }
        let currentSpaceID = activeSpaceID()

        guard let previous = windowInventoryState else {
            windowInventoryState = WindowInventoryState(
                visibleWindowIDs: Set(snapshot.windows.map(\.id))
            )
            windowFrameInventoryState = WindowFrameInventoryState(
                framesByWindowID: Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0.frame) })
            )
            windowInventorySpaceID = currentSpaceID
            return
        }

        if currentSpaceID != windowInventorySpaceID {
            reporter.info("Active Space changed during inventory poll; inventory baseline reset")
            activeSpaceChanged()
            return
        }

        let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: previous,
            current: snapshot.windows
        )
        windowInventoryState = poll.state
        if poll.suppressedSpaceReplacement {
            windowFrameInventoryState = WindowFrameInventoryState(
                framesByWindowID: Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0.frame) })
            )
            reporter.info("Suppressed likely Space replacement inventory diff")
            activeSpaceChanged()
            return
        }
        for event in poll.events {
            emit(event, nil)
        }

        let framePoll = pollWindowFrameInventory(
            previous: windowFrameInventoryState ?? .empty,
            current: snapshot.windows,
            tolerance: Self.frameTolerance
        )
        windowFrameInventoryState = framePoll.state
        for event in framePoll.events {
            guard !echoSuppressor.isExpectedEcho(event) else {
                reporter.info("Suppressed expected AX echo for frame inventory event")
                continue
            }
            emit(event, nil)
        }
    }
}
