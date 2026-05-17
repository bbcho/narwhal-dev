import AppKit

@MainActor
final class DisplayObserverService {
    private let reporter: StartupReporter
    private let displayChanged: @MainActor () -> Void
    private var observer: NSObjectProtocol?

    init(
        reporter: StartupReporter,
        displayChanged: @escaping @MainActor () -> Void
    ) {
        self.reporter = reporter
        self.displayChanged = displayChanged
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reporter.info("Display parameters changed; scheduling environment refresh")
                self?.displayChanged()
            }
        }
        reporter.info("Display observer ready")
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
