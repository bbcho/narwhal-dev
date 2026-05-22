import CoreServices
import Foundation
import NarwhalAppSupport

@MainActor
final class ConfigFileWatcherService {
    private static let reloadDelay: TimeInterval = 0.20

    private let configURL: URL
    private let reporter: StartupReporter
    private let fileManager: FileManager
    private let configChanged: @MainActor () -> Void
    private let watchTarget: ConfigWatchTarget
    private var stream: FSEventStreamRef?
    private var reloadTimer: Timer?
    private var reloadState = ConfigReloadDebounceState.empty
    private var reloadTimerGeneration: UInt64?

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
        self.watchTarget = ConfigWatchTarget(
            configPath: self.configURL.path,
            directoryPath: self.configURL.deletingLastPathComponent().standardizedFileURL.path
        )
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
        reloadTimerGeneration = nil
        reloadState = cancelConfigReload(in: reloadState)

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func existingWatchRoot(for url: URL) -> URL? {
        let targetDirectory = url.deletingLastPathComponent().standardizedFileURL
        let configParent = targetDirectory.deletingLastPathComponent().standardizedFileURL
        let candidates = [targetDirectory, configParent].map { candidate in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            return ConfigWatchRootCandidate(
                path: candidate.path,
                isDirectory: exists && isDirectory.boolValue
            )
        }
        return selectedConfigWatchRoot(from: candidates).map { path in
            URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    private func handleEvent(path: String) {
        let eventURL = URL(fileURLWithPath: path).standardizedFileURL
        guard configChangeEventTouchesTarget(path: eventURL.path, target: watchTarget) else { return }
        scheduleReload()
    }

    private func scheduleReload() {
        let scheduled = scheduleConfigReload(in: reloadState)
        reloadState = scheduled.state
        scheduleTimer(generation: scheduled.generation)
    }

    private func scheduleTimer(generation: UInt64) {
        reloadTimer?.invalidate()
        let timer = Timer(timeInterval: Self.reloadDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireTimer(generation: generation)
            }
        }
        reloadTimer = timer
        reloadTimerGeneration = generation
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fireTimer(generation: UInt64) {
        if reloadTimerGeneration == generation {
            reloadTimer?.invalidate()
            reloadTimer = nil
            reloadTimerGeneration = nil
        }
        let fired = fireConfigReloadTimer(generation: generation, in: reloadState)
        reloadState = fired.state
        guard fired.decision == .reload else { return }
        reporter.info("Config file changed; reloading \(configURL.path)")
        configChanged()
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
