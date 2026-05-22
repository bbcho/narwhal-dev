import Foundation
import NarwhalAppSupport
import os

struct StartupReporter {
    static let defaultLogPath = "/tmp/narwhal.log"

    private let logger = Logger(subsystem: "ca.quantim.narwhal", category: "app")
    private let sink: FileLogSink
    private let timestamp: () -> String

    init(
        logPath: String = StartupReporter.defaultLogPath,
        timestamp: @escaping () -> String = StartupReporter.currentTimestamp
    ) {
        sink = FileLogSink(path: logPath)
        self.timestamp = timestamp
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write(level: .info, message: message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write(level: .error, message: message)
    }

    private func write(level: LogLineLevel, message: String) {
        let line = formattedLogLine(timestamp: timestamp(), level: level, message: message)
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        sink.write(data)
    }

    private static func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

final class FileLogSink {
    private let lock = NSLock()
    private let handle: FileHandle?
    private var reportedFailure = false

    init(path: String) {
        let created = FileManager.default.createFile(atPath: path, contents: Data())
        handle = FileHandle(forWritingAtPath: path)
        if !created || handle == nil {
            writeStderr("Log file unavailable at \(path)\n")
        }
    }

    deinit {
        try? handle?.close()
    }

    func write(_ data: Data) {
        guard let handle else { return }

        lock.lock()
        defer { lock.unlock() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            reportFailureOnce(error)
        }
    }

    private func reportFailureOnce(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        writeStderr("Log file write failed: \(String(describing: error))\n")
    }
}

private func writeStderr(_ message: String) {
    guard let data = message.data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}
