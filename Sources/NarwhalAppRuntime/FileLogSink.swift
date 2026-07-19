import Darwin
import Foundation
import NarwhalAppSupport

final class FileLogSink: @unchecked Sendable {
    private static let defaultMaximumFileBytes: UInt64 = 5 * 1_024 * 1_024
    private static let defaultRetainedGenerations = 3
    private static let defaultMaximumPendingBytes = 1 * 1_024 * 1_024

    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "ca.quantim.narwhal.file-log")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let path: String
    private let maximumFileBytes: UInt64
    private let retainedGenerations: Int
    private let maximumPendingBytes: Int
    private var handle: FileHandle?
    private var available = false
    private var pendingByteCount = 0
    private var droppedLines: UInt64 = 0
    private var reportedFailure = false

    var isAvailable: Bool {
        withStateLock { available }
    }

    var droppedLineCount: UInt64 {
        withStateLock { droppedLines }
    }

    init(
        path: String,
        maximumFileBytes: UInt64 = FileLogSink.defaultMaximumFileBytes,
        retainedGenerations: Int = FileLogSink.defaultRetainedGenerations,
        maximumPendingBytes: Int = FileLogSink.defaultMaximumPendingBytes
    ) {
        precondition(maximumFileBytes > 0, "Log rotation size must be positive")
        precondition(retainedGenerations >= 0, "Log generations cannot be negative")
        precondition(maximumPendingBytes > 0, "Log pending-byte limit must be positive")
        self.path = path
        self.maximumFileBytes = maximumFileBytes
        self.retainedGenerations = retainedGenerations
        self.maximumPendingBytes = maximumPendingBytes
        queue.setSpecific(key: queueKey, value: 1)
        queue.async { [self] in
            handle = prepareLogFile()
            withStateLock { available = handle != nil }
            if handle == nil {
                writeStderr("Log file unavailable\n")
            }
        }
    }

    func write(_ data: Data, synchronizing: Bool = false) {
        if synchronizing {
            onWriterQueue {
                self.writeOnQueue(data, synchronizing: true)
            }
            return
        }

        let admitted = withStateLock { () -> Bool in
            guard data.count <= maximumPendingBytes - pendingByteCount else {
                if droppedLines < UInt64.max {
                    droppedLines += 1
                }
                return false
            }
            pendingByteCount += data.count
            return true
        }
        guard admitted else { return }

        queue.async { [self] in
            writeOnQueue(data, synchronizing: false)
            withStateLock { pendingByteCount -= data.count }
        }
    }

    func flush() {
        onWriterQueue {
            guard let handle = self.handle else { return }
            do {
                try handle.synchronize()
            } catch {
                self.reportFailureOnce(error)
            }
        }
    }

    private func writeOnQueue(_ data: Data, synchronizing: Bool) {
        FileHandle.standardError.write(data)
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            if synchronizing {
                try handle.synchronize()
            }
        } catch {
            reportFailureOnce(error)
        }
    }

    private func onWriterQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func reportFailureOnce(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        writeStderr("Log file write failed\n")
    }

    private func prepareLogFile() -> FileHandle? {
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

        rotateIfNeeded()
        return Self.openAppendOnlyLog(path: path)
    }

    private func rotateIfNeeded() {
        var fileStatus = stat()
        guard Darwin.lstat(path, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { return }

        let currentByteCount = UInt64(max(0, fileStatus.st_size))
        let operations = logRotationPlan(
            currentByteCount: currentByteCount,
            maximumByteCount: maximumFileBytes,
            retainedGenerationCount: retainedGenerations
        )
        for operation in operations {
            switch operation {
            case .remove(let generation):
                removeArchiveIfSafe(generation: generation)
            case .move(let source, let destination):
                moveArchiveIfSafe(from: source, to: destination)
            }
        }
    }

    private func removeArchiveIfSafe(generation: Int) {
        let archivePath = pathForGeneration(generation)
        var fileStatus = stat()
        guard Darwin.lstat(archivePath, &fileStatus) == 0 else { return }
        let kind = fileStatus.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else {
            writeStderr("Log rotation refused non-file archive\n")
            return
        }
        if Darwin.unlink(archivePath) != 0 {
            writeStderr("Log rotation could not remove archive: errno=\(errno)\n")
        }
    }

    private func moveArchiveIfSafe(from sourceGeneration: Int, to destinationGeneration: Int) {
        let source = pathForGeneration(sourceGeneration)
        let destination = pathForGeneration(destinationGeneration)
        var fileStatus = stat()
        guard Darwin.lstat(source, &fileStatus) == 0 else { return }
        let kind = fileStatus.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK) {
            _ = Darwin.unlink(source)
            return
        }
        guard kind == mode_t(S_IFREG) else {
            writeStderr("Log rotation refused non-file archive\n")
            return
        }
        guard Darwin.rename(source, destination) == 0 else {
            writeStderr("Log rotation could not move archive: errno=\(errno)\n")
            return
        }
        _ = Darwin.chmod(destination, mode_t(S_IRUSR | S_IWUSR))
    }

    private func pathForGeneration(_ generation: Int) -> String {
        generation == 0 ? path : "\(path).\(generation)"
    }

    private static func openAppendOnlyLog(path: String) -> FileHandle? {
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

    private func withStateLock<Result>(_ operation: () -> Result) -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}

private func writeStderr(_ message: String) {
    guard let data = message.data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}
