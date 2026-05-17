import AppKit
import WinMgrCore

@MainActor
final class AXObserverService {
    private static let pollInterval: TimeInterval = 0.15

    private let axClient: AXClient
    private let echoSuppressor: AXEchoSuppressor
    private let reporter: StartupReporter
    private let emit: @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    private let spaceChanged: @MainActor () -> Void
    private var timer: Timer?
    private var settleTimers: [Timer] = []
    private var workspaceObserver: NSObjectProtocol?
    private var lastFocusedWindowID: WindowID?

    init(
        axClient: AXClient,
        echoSuppressor: AXEchoSuppressor,
        reporter: StartupReporter,
        spaceChanged: @escaping @MainActor () -> Void,
        emit: @escaping @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    ) {
        self.axClient = axClient
        self.echoSuppressor = echoSuppressor
        self.reporter = reporter
        self.spaceChanged = spaceChanged
        self.emit = emit
    }

    func start() {
        guard timer == nil else { return }
        pollFocusedWindow()
        timer = makeTimer(interval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollFocusedWindow()
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
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    private func activeSpaceChanged() {
        settleTimers.forEach { $0.invalidate() }
        settleTimers.removeAll()
        lastFocusedWindowID = nil
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
        guard case .success(let snapshot) = axClient.focusedWindowSnapshot() else { return }
        guard snapshot.id != lastFocusedWindowID else { return }
        lastFocusedWindowID = snapshot.id

        let event = AXEvent.windowFocused(snapshot.id)
        guard !echoSuppressor.isExpectedEcho(event) else {
            reporter.info("Suppressed expected AX focus echo for \(snapshot.id.description)")
            return
        }
        emit(event, snapshot)
    }
}
