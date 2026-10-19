import Darwin
import Foundation
import NarwhalCore

public enum IPCTransportError: Error, CustomStringConvertible, Sendable {
    case runtimeDirectoryUnavailable(errno: Int32)
    case pathMetadataFailed(path: String, errno: Int32)
    case unsafeRuntimeDirectory(path: String)
    case lockOpenFailed(path: String, errno: Int32)
    case unsafeLockFile(path: String)
    case unsafeSocketPath(path: String)
    case socketProbeFailed(path: String, errno: Int32)
    case peerCredentialsFailed(errno: Int32)
    case peerUIDMismatch(expected: uid_t, actual: uid_t)
    case socketPathTooLong(String)
    case socketCreateFailed(errno: Int32)
    case bindFailed(path: String, errno: Int32)
    case chmodFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case socketOptionFailed(option: String, errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case connectionClosed
    case lineTooLong(maxBytes: Int)
    case invalidUTF8
    case alreadyRunning(path: String)
    case timedOut(operation: String)

    public var description: String {
        switch self {
        case .runtimeDirectoryUnavailable(let errno):
            return "Could not resolve the private user runtime directory: \(Self.errnoDescription(errno))"
        case .pathMetadataFailed(let path, let errno):
            return "lstat(\(path)) failed: \(Self.errnoDescription(errno))"
        case .unsafeRuntimeDirectory(let path):
            return "Private user runtime directory is unsafe: \(path)"
        case .lockOpenFailed(let path, let errno):
            return "open(\(path)) failed: \(Self.errnoDescription(errno))"
        case .unsafeLockFile(let path):
            return "IPC lock file is unsafe: \(path)"
        case .unsafeSocketPath(let path):
            return "IPC socket path is unsafe: \(path)"
        case .socketProbeFailed(let path, let errno):
            return "IPC socket probe failed for \(path): \(Self.errnoDescription(errno))"
        case .peerCredentialsFailed(let errno):
            return "getpeereid() failed: \(Self.errnoDescription(errno))"
        case .peerUIDMismatch(let expected, let actual):
            return "IPC peer UID mismatch: expected \(expected), got \(actual)"
        case .socketPathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        case .socketCreateFailed(let errno):
            return "socket() failed: \(Self.errnoDescription(errno))"
        case .bindFailed(let path, let errno):
            return "bind(\(path)) failed: \(Self.errnoDescription(errno))"
        case .chmodFailed(let path, let errno):
            return "chmod(\(path)) failed: \(Self.errnoDescription(errno))"
        case .listenFailed(let errno):
            return "listen() failed: \(Self.errnoDescription(errno))"
        case .acceptFailed(let errno):
            return "accept() failed: \(Self.errnoDescription(errno))"
        case .socketOptionFailed(let option, let errno):
            return "setsockopt(\(option)) failed: \(Self.errnoDescription(errno))"
        case .connectFailed(let path, let errno):
            return "connect(\(path)) failed: \(Self.errnoDescription(errno))"
        case .readFailed(let errno):
            return "read() failed: \(Self.errnoDescription(errno))"
        case .writeFailed(let errno):
            return "write() failed: \(Self.errnoDescription(errno))"
        case .connectionClosed:
            return "IPC connection closed before a reply was received"
        case .lineTooLong(let maxBytes):
            return "IPC line exceeded \(maxBytes) bytes"
        case .invalidUTF8:
            return "IPC payload was not valid UTF-8"
        case .alreadyRunning(let path):
            return "Another narwhal daemon is already serving \(path)"
        case .timedOut(let operation):
            return "IPC \(operation) timed out"
        }
    }

    private static func errnoDescription(_ errno: Int32) -> String {
        String(cString: strerror(errno))
    }
}

typealias IPCPeerUIDReader = @Sendable (Int32) -> Result<uid_t, IPCTransportError>

/// Not thread-safe. Sequential use across threads requires external synchronization.
/// CLI usage is single-threaded.
public final class IPCClient {
    private let configuredSocketPath: String?
    private let maxLineBytes: Int
    private let ioTimeout: TimeInterval
    private let peerUIDReader: IPCPeerUIDReader
    private var fd: Int32?

    public convenience init(
        socketPath: String? = nil,
        maxLineBytes: Int = 64 * 1024,
        ioTimeout: TimeInterval = 5.0
    ) {
        self.init(
            socketPath: socketPath,
            maxLineBytes: maxLineBytes,
            ioTimeout: ioTimeout,
            peerUIDReader: livePeerUID
        )
    }

    init(
        socketPath: String?,
        maxLineBytes: Int = 64 * 1024,
        ioTimeout: TimeInterval = 5.0,
        peerUIDReader: @escaping IPCPeerUIDReader
    ) {
        self.configuredSocketPath = socketPath
        self.maxLineBytes = maxLineBytes
        self.ioTimeout = boundedSocketTimeout(ioTimeout)
        self.peerUIDReader = peerUIDReader
    }

    deinit {
        close()
    }

    public func connect() throws {
        guard fd == nil else { return }
        let socketPath = try configuredSocketPath ?? IPCDefaults.socketPath()
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCTransportError.socketCreateFailed(errno: errno)
        }
        do {
            try configureSocket(socketFD, ioTimeout: ioTimeout)
            try withSocketAddress(path: socketPath) { address, length in
                guard Darwin.connect(socketFD, address, length) == 0 else {
                    throw IPCTransportError.connectFailed(path: socketPath, errno: errno)
                }
            }
            try requireCurrentPeerUID(socketFD, using: peerUIDReader)
            fd = socketFD
        } catch {
            Darwin.close(socketFD)
            throw error
        }
    }

    public func send(_ command: IPCCommandDTO) throws -> IPCReplyDTO {
        try connect()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var request = try encoder.encode(command)
        request.append(0x0A)
        return try sendRawLine(request)
    }

    func sendRawLine(_ request: Data) throws -> IPCReplyDTO {
        try connect()
        guard let fd else { throw IPCTransportError.connectionClosed }
        do {
            try writeAll(request, to: fd)
            guard let replyData = try readLine(from: fd, maxBytes: maxLineBytes) else {
                throw IPCTransportError.connectionClosed
            }
            return try JSONDecoder().decode(IPCReplyDTO.self, from: replyData)
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        guard let oldFD = fd else { return }
        fd = nil
        Darwin.shutdown(oldFD, SHUT_RDWR)
        Darwin.close(oldFD)
    }
}

public final class IPCServer: @unchecked Sendable {
    private let configuredSocketPath: String?
    private let maxLineBytes: Int
    private let maxConnections: Int
    private let ioTimeout: TimeInterval
    private let handle: @Sendable (IPCCommandDTO) async -> IPCReplyDTO
    private let log: @Sendable (String) -> Void
    private let peerUIDReader: IPCPeerUIDReader
    private let beforePublishStartedResources: @Sendable () -> Void
    private let lifecycleLock = NSLock()
    private let state = IPCServerState()

    public convenience init(
        socketPath: String? = nil,
        maxLineBytes: Int = 64 * 1024,
        maxConnections: Int = 8,
        ioTimeout: TimeInterval = 5.0,
        handle: @escaping @Sendable (IPCCommandDTO) async -> IPCReplyDTO,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            socketPath: socketPath,
            maxLineBytes: maxLineBytes,
            maxConnections: maxConnections,
            ioTimeout: ioTimeout,
            peerUIDReader: livePeerUID,
            beforePublishStartedResources: {},
            handle: handle,
            log: log
        )
    }

    init(
        socketPath: String?,
        maxLineBytes: Int = 64 * 1024,
        maxConnections: Int = 8,
        ioTimeout: TimeInterval = 5.0,
        peerUIDReader: @escaping IPCPeerUIDReader = livePeerUID,
        beforePublishStartedResources: @escaping @Sendable () -> Void = {},
        handle: @escaping @Sendable (IPCCommandDTO) async -> IPCReplyDTO,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuredSocketPath = socketPath
        self.maxLineBytes = maxLineBytes
        self.maxConnections = maxConnections
        self.ioTimeout = boundedSocketTimeout(ioTimeout)
        self.peerUIDReader = peerUIDReader
        self.handle = handle
        self.log = log
        self.beforePublishStartedResources = beforePublishStartedResources
    }

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !state.isRunning else { return }
        let socketPath = try configuredSocketPath ?? IPCDefaults.socketPath()
        let lockPath = IPCDefaults.lockPath(forSocketPath: socketPath)
        let lockFD = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard lockFD >= 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw IPCTransportError.alreadyRunning(path: socketPath)
            }
            throw IPCTransportError.lockOpenFailed(path: lockPath, errno: errno)
        }

        var socketFD: Int32?
        var socketIdentity: IPCSocketIdentity?
        var transferred = false
        defer {
            if !transferred {
                if let socketIdentity {
                    unlinkSocketIfOwned(path: socketPath, identity: socketIdentity)
                }
                if let socketFD {
                    closeSocket(socketFD)
                }
                Darwin.close(lockFD)
            }
        }

        let lockMetadata = try ipcPathMetadata(forFileDescriptor: lockFD, path: lockPath)
        try validateLockMetadata(
            path: lockPath,
            metadata: lockMetadata,
            expectedUID: Darwin.getuid()
        ).get()
        guard Darwin.fchmod(lockFD, S_IRUSR | S_IWUSR) == 0 else {
            throw IPCTransportError.lockOpenFailed(path: lockPath, errno: errno)
        }
        if try probeExistingDaemon(path: socketPath) {
            throw IPCTransportError.alreadyRunning(path: socketPath)
        }
        if let existing = try ipcPathMetadataIfPresent(at: socketPath) {
            _ = try reclaimableSocketIdentity(
                path: socketPath,
                metadata: existing,
                expectedUID: Darwin.getuid()
            ).get()
            guard Darwin.unlink(socketPath) == 0 else {
                throw IPCTransportError.bindFailed(path: socketPath, errno: errno)
            }
        }

        let createdSocketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard createdSocketFD >= 0 else {
            throw IPCTransportError.socketCreateFailed(errno: errno)
        }
        socketFD = createdSocketFD
        do {
            try configureSocket(createdSocketFD)
            try withSocketAddress(path: socketPath) { address, length in
                guard Darwin.bind(createdSocketFD, address, length) == 0 else {
                    throw IPCTransportError.bindFailed(path: socketPath, errno: errno)
                }
            }
            let boundMetadata = try ipcPathMetadata(at: socketPath)
            socketIdentity = try reclaimableSocketIdentity(
                path: socketPath,
                metadata: boundMetadata,
                expectedUID: Darwin.getuid()
            ).get()
            guard Darwin.chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw IPCTransportError.chmodFailed(path: socketPath, errno: errno)
            }
            guard Darwin.listen(createdSocketFD, Int32(maxConnections)) == 0 else {
                throw IPCTransportError.listenFailed(errno: errno)
            }
            beforePublishStartedResources()
            guard let socketIdentity else {
                throw IPCTransportError.unsafeSocketPath(path: socketPath)
            }
            state.start(resources: IPCServerResources(
                socketPath: socketPath,
                socketIdentity: socketIdentity,
                socketFD: createdSocketFD,
                lockFD: lockFD
            ))
            transferred = true
            // Blocking socket calls run on dedicated threads, never on Swift's
            // cooperative pool: blocking pool threads starves every other task
            // in the process, including this server's own handler.
            Thread.detachNewThread { [self] in
                acceptLoop(createdSocketFD)
            }
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let stopped = state.stop() else { return }
        for fd in stopped.socketFDs {
            closeSocket(fd)
        }
        unlinkSocketIfOwned(
            path: stopped.resources.socketPath,
            identity: stopped.resources.socketIdentity
        )
        Darwin.close(stopped.resources.lockFD)
    }

    private func acceptLoop(_ socketFD: Int32) {
        while state.isRunning {
            let clientFD = Darwin.accept(socketFD, nil, nil)
            if clientFD < 0 {
                let currentErrno = errno
                if currentErrno == EBADF || currentErrno == EINVAL {
                    return
                }
                if [EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED, EMFILE, ENFILE].contains(currentErrno) {
                    if state.isRunning {
                        log("IPC accept transient errno=\(currentErrno) (\(String(cString: strerror(currentErrno)))); continuing")
                    }
                    // Back off while file descriptors are exhausted.
                    if currentErrno == EMFILE || currentErrno == ENFILE {
                        usleep(50_000)
                    }
                    continue
                }
                if state.isRunning {
                    log(IPCTransportError.acceptFailed(errno: currentErrno).description)
                }
                return
            }

            do {
                try requireCurrentPeerUID(clientFD, using: peerUIDReader)
                try configureSocket(clientFD, ioTimeout: ioTimeout)
            } catch {
                log(String(describing: error))
                closeSocket(clientFD)
                continue
            }

            guard state.openConnection(clientFD, limit: maxConnections) else {
                closeSocket(clientFD)
                continue
            }

            Thread.detachNewThread { [self] in
                processConnection(clientFD)
            }
        }
    }

    private func probeExistingDaemon(path: String) throws -> Bool {
        let probeFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else {
            throw IPCTransportError.socketCreateFailed(errno: errno)
        }
        defer { Darwin.close(probeFD) }
        try configureSocket(probeFD, ioTimeout: min(ioTimeout, 0.25))
        let result = try withSocketAddress(path: path) { address, length in
            Darwin.connect(probeFD, address, length)
        }
        if result == 0 {
            try requireCurrentPeerUID(probeFD, using: peerUIDReader)
            return true
        }
        let currentErrno = errno
        switch currentErrno {
        case ENOENT, ECONNREFUSED:
            return false
        default:
            throw IPCTransportError.socketProbeFailed(path: path, errno: currentErrno)
        }
    }

    private func processConnection(_ clientFD: Int32) {
        defer {
            if state.closeConnection(clientFD) {
                closeSocket(clientFD)
            }
        }

        while state.isRunning {
            do {
                guard let requestData = try readLine(
                    from: clientFD,
                    maxBytes: maxLineBytes,
                    deadline: Date().addingTimeInterval(ioTimeout)
                ) else { return }
                let reply = reply(for: requestData)
                let encoded = try encodeReplyLine(reply)
                try writeAll(encoded, to: clientFD)
            } catch IPCTransportError.lineTooLong {
                let reply = IPCReplyDTO.error(
                    commandID: CommandID(raw: "line-too-long"),
                    code: "line_too_long",
                    message: "IPC command exceeded \(maxLineBytes) bytes"
                )
                if let encoded = try? encodeReplyLine(reply) {
                    try? writeAll(encoded, to: clientFD)
                }
                return
            } catch let error as IPCTransportError {
                log(error.description)
                return
            } catch {
                log("IPC connection failed: \(String(describing: error))")
                return
            }
        }
    }

    private func reply(for requestData: Data) -> IPCReplyDTO {
        guard let command = try? JSONDecoder().decode(IPCCommandDTO.self, from: requestData) else {
            return .error(
                commandID: CommandID(raw: "decode-error"),
                code: "invalid_json",
                message: "Invalid IPC command JSON"
            )
        }
        // Waiting here is safe: this is a dedicated connection thread.
        let reply = IPCReplySlot()
        let replied = DispatchSemaphore(value: 0)
        Task { [handle] in
            reply.value = await handle(command)
            replied.signal()
        }
        replied.wait()
        return reply.value ?? .error(
            commandID: CommandID(raw: "handler-error"),
            code: "handler_failed",
            message: "IPC handler produced no reply"
        )
    }
}

private let livePeerUID: IPCPeerUIDReader = { fd in
    var effectiveUID: uid_t = 0
    var effectiveGID: gid_t = 0
    guard Darwin.getpeereid(fd, &effectiveUID, &effectiveGID) == 0 else {
        return .failure(.peerCredentialsFailed(errno: errno))
    }
    return .success(effectiveUID)
}

private func requireCurrentPeerUID(
    _ fd: Int32,
    using reader: IPCPeerUIDReader
) throws {
    let actual = try reader(fd).get()
    let expected = Darwin.getuid()
    guard actual == expected else {
        throw IPCTransportError.peerUIDMismatch(expected: expected, actual: actual)
    }
}

/// Hands one reply from the handler task to the waiting connection thread;
/// the semaphore in `reply(for:)` orders the write before the read.
private final class IPCReplySlot: @unchecked Sendable {
    var value: IPCReplyDTO?
}

private struct IPCServerResources {
    let socketPath: String
    let socketIdentity: IPCSocketIdentity
    let socketFD: Int32
    let lockFD: Int32
}

private struct IPCStoppedServerResources {
    let resources: IPCServerResources
    let socketFDs: [Int32]
}

private final class IPCServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var resources: IPCServerResources?
    private var clientFDs = Set<Int32>()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resources != nil
    }

    func start(resources: IPCServerResources) {
        lock.lock()
        self.resources = resources
        lock.unlock()
    }

    func stop() -> IPCStoppedServerResources? {
        lock.lock()
        guard let resources else {
            lock.unlock()
            return nil
        }
        self.resources = nil
        let sockets = [resources.socketFD] + clientFDs.sorted()
        clientFDs.removeAll()
        lock.unlock()
        return IPCStoppedServerResources(resources: resources, socketFDs: sockets)
    }

    func openConnection(_ clientFD: Int32, limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard resources != nil && clientFDs.count < limit else { return false }
        clientFDs.insert(clientFD)
        return true
    }

    func closeConnection(_ clientFD: Int32) -> Bool {
        lock.lock()
        let wasActive = clientFDs.remove(clientFD) != nil
        lock.unlock()
        return wasActive
    }
}

private func unlinkSocketIfOwned(path: String, identity: IPCSocketIdentity) {
    guard let current = try? ipcPathMetadata(at: path),
          socketIdentityMatches(identity, metadata: current)
    else { return }
    Darwin.unlink(path)
}

private func closeSocket(_ fd: Int32) {
    Darwin.shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
}

private func configureSocket(_ fd: Int32, ioTimeout: TimeInterval? = nil) throws {
    var noSIGPIPE: Int32 = 1
    let result = Darwin.setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSIGPIPE,
        socklen_t(MemoryLayout.size(ofValue: noSIGPIPE))
    )
    guard result == 0 else {
        throw IPCTransportError.socketOptionFailed(option: "SO_NOSIGPIPE", errno: errno)
    }

    guard let ioTimeout else { return }
    var timeout = socketTimeval(ioTimeout)
    for (option, name) in [(SO_RCVTIMEO, "SO_RCVTIMEO"), (SO_SNDTIMEO, "SO_SNDTIMEO")] {
        let timeoutResult = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            option,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
        guard timeoutResult == 0 else {
            throw IPCTransportError.socketOptionFailed(option: name, errno: errno)
        }
    }
}

private func boundedSocketTimeout(_ timeout: TimeInterval) -> TimeInterval {
    guard timeout.isFinite else { return 5.0 }
    return min(300, max(0.01, timeout))
}

private func socketTimeval(_ timeout: TimeInterval) -> timeval {
    let bounded = boundedSocketTimeout(timeout)
    let seconds = floor(bounded)
    let microseconds = (bounded - seconds) * 1_000_000
    return timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
}

private func encodeReplyLine(_ reply: IPCReplyDTO) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(reply)
    data.append(0x0A)
    return data
}

/// Reads one newline-terminated line. `deadline` bounds the whole line, so a
/// peer trickling bytes cannot outlast the per-read socket timeout forever.
private func readLine(from fd: Int32, maxBytes: Int, deadline: Date? = nil) throws -> Data? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(min(1024, maxBytes))

    while true {
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        if count == 0 {
            return bytes.isEmpty ? nil : Data(bytes)
        }
        if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw IPCTransportError.timedOut(operation: "read")
            }
            throw IPCTransportError.readFailed(errno: errno)
        }
        if byte == 0x0A {
            return Data(bytes)
        }
        if let deadline, Date() >= deadline {
            throw IPCTransportError.timedOut(operation: "read")
        }
        guard bytes.count < maxBytes else {
            throw IPCTransportError.lineTooLong(maxBytes: maxBytes)
        }
        bytes.append(byte)
    }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var written = 0
        while written < buffer.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: written), buffer.count - written)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw IPCTransportError.timedOut(operation: "write")
                }
                throw IPCTransportError.writeFailed(errno: errno)
            }
            if count == 0 {
                throw IPCTransportError.connectionClosed
            }
            written += count
        }
    }
}

private func withSocketAddress<Result>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) throws -> Result {
    let pathBytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= pathCapacity else {
        throw IPCTransportError.socketPathTooLong(path)
    }

    guard let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) else {
        throw IPCTransportError.socketPathTooLong(path)
    }

    withUnsafeMutableBytes(of: &address) { rawAddress in
        for (index, byte) in pathBytes.enumerated() {
            rawAddress[pathOffset + index] = byte
        }
    }

    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    address.sun_len = UInt8(length)
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try body(socketAddress, length)
        }
    }
}
