import Foundation
import WinMgrCore

@MainActor
final class AXObserverService {
    private let axClient: AXClient
    private let echoSuppressor: AXEchoSuppressor
    private let reporter: StartupReporter
    private let emit: @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    private var timer: Timer?
    private var lastFocusedWindowID: WindowID?

    init(
        axClient: AXClient,
        echoSuppressor: AXEchoSuppressor,
        reporter: StartupReporter,
        emit: @escaping @MainActor (AXEvent, FocusedWindowSnapshot?) -> Void
    ) {
        self.axClient = axClient
        self.echoSuppressor = echoSuppressor
        self.reporter = reporter
        self.emit = emit
    }

    func start() {
        guard timer == nil else { return }
        pollFocusedWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollFocusedWindow()
            }
        }
        reporter.info("AX focus observer ready")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
