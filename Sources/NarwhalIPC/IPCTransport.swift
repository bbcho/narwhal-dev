import Darwin
import Foundation
import NarwhalCore

public enum IPCDefaults {
    public static var socketPath: String {
        "/tmp/narwhal-\(Darwin.getuid()).sock"
    }
}

public enum IPCTransportError: Error, CustomStringConvertible, Sendable {
    case socketPathTooLong(String)
    case socketCreateFailed(errno: Int32)
    case bindFailed(path: String, errno: Int32)
    case chmodFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case connectionClosed
    case lineTooLong(maxBytes: Int)
    case invalidUTF8
    case alreadyRunning(path: String)

    public var description: String {
        switch self {
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
        }
    }

    private static func errnoDescription(_ errno: Int32) -> String {
        String(cString: strerror(errno))
    }
}

/// Not thread-safe. Sequential use across threads requires external synchronization.
/// CLI usage is single-threaded.
public final class IPCClient {
    private let socketPath: String
    private let maxLineBytes: Int
    private var fd: Int32?

    public init(socketPath: String = IPCDefaults.socketPath, maxLineBytes: Int = 64 * 1024) {
        self.socketPath = socketPath
        self.maxLineBytes = maxLineBytes
    }

    deinit {
        close()
    }

    public func connect() throws {
        guard fd == nil else { return }
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCTransportError.socketCreateFailed(errno: errno)
        }
        do {
            try withSocketAddress(path: socketPath) { address, length in
                guard Darwin.connect(socketFD, address, length) == 0 else {
                    throw IPCTransportError.connectFailed(path: socketPath, errno: errno)
                }
            }
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
        try writeAll(request, to: fd)
        guard let replyData = try readLine(from: fd, maxBytes: maxLineBytes) else {
            throw IPCTransportError.connectionClosed
        }
        return try JSONDecoder().decode(IPCReplyDTO.self, from: replyData)
    }

    public func close() {
        guard let oldFD = fd else { return }
        fd = nil
        Darwin.shutdown(oldFD, SHUT_RDWR)
        Darwin.close(oldFD)
    }
}

public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    private let maxLineBytes: Int
    private let maxConnections: Int
    private let handle: @Sendable (IPCCommandDTO) async -> IPCReplyDTO
    private let log: @Sendable (String) -> Void
    private let state = IPCServerState()

    public init(
        socketPath: String = IPCDefaults.socketPath,
        maxLineBytes: Int = 64 * 1024,
        maxConnections: Int = 8,
        handle: @escaping @Sendable (IPCCommandDTO) async -> IPCReplyDTO,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.socketPath = socketPath
        self.maxLineBytes = maxLineBytes
        self.maxConnections = maxConnections
        self.handle = handle
        self.log = log
    }

    public func start() throws {
        guard !state.isRunning else { return }
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCTransportError.socketCreateFailed(errno: errno)
        }

        do {
            if probeExistingDaemon(path: socketPath) {
                Darwin.close(socketFD)
                throw IPCTransportError.alreadyRunning(path: socketPath)
            }
            Darwin.unlink(socketPath)
            try withSocketAddress(path: socketPath) { address, length in
                guard Darwin.bind(socketFD, address, length) == 0 else {
                    throw IPCTransportError.bindFailed(path: socketPath, errno: errno)
                }
            }
            guard Darwin.chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw IPCTransportError.chmodFailed(path: socketPath, errno: errno)
            }
            guard Darwin.listen(socketFD, Int32(maxConnections)) == 0 else {
                throw IPCTransportError.listenFailed(errno: errno)
            }
            state.start(fd: socketFD)
            Task.detached { [self] in
                await acceptLoop(socketFD)
            }
        } catch {
            Darwin.close(socketFD)
            Darwin.unlink(socketPath)
            throw error
        }
    }

    public func stop() {
        let sockets = state.stop()
        for fd in sockets {
            closeSocket(fd)
        }
        Darwin.unlink(socketPath)
    }

    private func acceptLoop(_ socketFD: Int32) async {
        while !Task.isCancelled && state.isRunning {
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
                    // EMFILE/ENFILE: back off to let descriptors free. Cancellation here just
                    // skips the sleep; the next loop iteration checks Task.isCancelled.
                    if currentErrno == EMFILE || currentErrno == ENFILE {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    continue
                }
                if state.isRunning {
                    log(IPCTransportError.acceptFailed(errno: currentErrno).description)
                }
                return
            }

            guard state.openConnection(clientFD, limit: maxConnections) else {
                closeSocket(clientFD)
                continue
            }

            Task.detached { [self] in
                await processConnection(clientFD)
            }
        }
    }

    private func probeExistingDaemon(path: String) -> Bool {
        let probeFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else { return false }
        defer { Darwin.close(probeFD) }
        var alive = false
        do {
            try withSocketAddress(path: path) { address, length in
                // Blocking connect on a UNIX socket: stale socket file returns ECONNREFUSED
                // immediately; live daemon returns 0. Non-blocking errnos cannot occur here.
                if Darwin.connect(probeFD, address, length) == 0 {
                    alive = true
                }
            }
        } catch {
            // address construction failed; treat as no daemon present.
        }
        return alive
    }

    private func processConnection(_ clientFD: Int32) async {
        defer {
            if state.closeConnection(clientFD) {
                closeSocket(clientFD)
            }
        }

        while state.isRunning {
            do {
                guard let requestData = try readLine(from: clientFD, maxBytes: maxLineBytes) else { return }
                let reply = await reply(for: requestData)
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

    private func reply(for requestData: Data) async -> IPCReplyDTO {
        do {
            let command = try JSONDecoder().decode(IPCCommandDTO.self, from: requestData)
            return await handle(command)
        } catch {
            return .error(
                commandID: CommandID(raw: "decode-error"),
                code: "invalid_json",
                message: "Invalid IPC command JSON"
            )
        }
    }
}

private final class IPCServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    private var running = false
    private var clientFDs = Set<Int32>()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start(fd: Int32) {
        lock.lock()
        self.fd = fd
        running = true
        lock.unlock()
    }

    func stop() -> [Int32] {
        lock.lock()
        running = false
        let sockets = [fd].compactMap { $0 } + clientFDs.sorted()
        fd = nil
        clientFDs.removeAll()
        lock.unlock()
        return sockets
    }

    func openConnection(_ clientFD: Int32, limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running && clientFDs.count < limit else { return false }
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

private func closeSocket(_ fd: Int32) {
    Darwin.shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
}

private func encodeReplyLine(_ reply: IPCReplyDTO) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(reply)
    data.append(0x0A)
    return data
}

private func readLine(from fd: Int32, maxBytes: Int) throws -> Data? {
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
            throw IPCTransportError.readFailed(errno: errno)
        }
        if byte == 0x0A {
            return Data(bytes)
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
