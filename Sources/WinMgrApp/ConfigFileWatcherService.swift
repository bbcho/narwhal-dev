import CoreServices
import Foundation

@MainActor
final class ConfigFileWatcherService {
    private static let reloadDelay: TimeInterval = 0.20

    private let configURL: URL
    private let reporter: StartupReporter
    private let fileManager: FileManager
    private let configChanged: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private var reloadTimer: Timer?

    init(
        configURL: URL,
        reporter: StartupReporter,
        fileManager: FileManager = .default,
        configChanged: @escaping @MainActor () -> Void
    ) {
        self.configURL = configURL.standardizedFileURL
        self.reporter = reporter
        self.fileManager = fileManager
        self.configChanged = configChanged
    }

    func start() {
        guard stream == nil else { return }
        guard let root = existingWatchRoot(for: configURL) else {
            reporter.info("Config watcher skipped: no existing config directory for \(configURL.path)")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.reloadDelay,
            flags
        ) else {
            reporter.error("Config watcher startup failed for \(configURL.path)")
            return
        }

        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            reporter.error("Config watcher could not start for \(configURL.path)")
            return
        }

        stream = created
        reporter.info("Config watcher ready for \(configURL.path) under \(root.path)")
    }

    func stop() {
        reloadTimer?.invalidate()
        reloadTimer = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func existingWatchRoot(for url: URL) -> URL? {
        let targetDirectory = url.deletingLastPathComponent().standardizedFileURL
        let configParent = targetDirectory.deletingLastPathComponent().standardizedFileURL
        for candidate in [targetDirectory, configParent] {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private func handleEvent(path: String) {
        let eventURL = URL(fileURLWithPath: path).standardizedFileURL
        let targetDirectory = configURL.deletingLastPathComponent().standardizedFileURL
        guard eventURL == configURL || eventURL == targetDirectory else { return }
        scheduleReload()
    }

    private func scheduleReload() {
        reloadTimer?.invalidate()
        let timer = Timer(timeInterval: Self.reloadDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reporter.info("Config file changed; reloading \(self.configURL.path)")
                self.configChanged()
            }
        }
        reloadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static let handleEvents: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<ConfigFileWatcherService>.fromOpaque(info).takeUnretainedValue()
        let paths = eventPaths.bindMemory(to: UnsafePointer<CChar>.self, capacity: eventCount)
        for index in 0..<eventCount {
            let path = String(cString: paths[index])
            Task { @MainActor in
                watcher.handleEvent(path: path)
            }
        }
    }
}
