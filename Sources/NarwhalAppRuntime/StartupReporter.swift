import Foundation
import NarwhalAppSupport
import os

struct StartupReporter {
    static var defaultLogPath: String {
        let override = ProcessInfo.processInfo.environment["NARWHAL_LOG_PATH"]
        return override.flatMap { $0.isEmpty ? nil : $0 } ?? standardLogPath
    }

    static var standardLogPath: String {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Narwhal", isDirectory: true)
            .appendingPathComponent("narwhal.log", isDirectory: false)
            .path
    }

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

    func flush() {
        sink.flush()
    }

    var droppedLogLineCount: UInt64 {
        sink.droppedLineCount
    }

    private func write(level: LogLineLevel, message: String) {
        let line = formattedLogLine(timestamp: timestamp(), level: level, message: message)
        guard let data = line.data(using: .utf8) else { return }
        sink.write(data, synchronizing: level == .error)
    }

    private static func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
