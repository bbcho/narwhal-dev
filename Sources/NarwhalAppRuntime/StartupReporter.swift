import Darwin
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

    var isAvailable: Bool {
        handle != nil
    }

    init(path: String) {
        handle = Self.openAppendOnlyLog(path: path)
        if handle == nil {
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

    private static func openAppendOnlyLog(path: String) -> FileHandle? {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        do {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { return nil }
            } else {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            return nil
        }

        let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        let descriptor = Darwin.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return nil }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0
        else {
            Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private func writeStderr(_ message: String) {
    guard let data = message.data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}
