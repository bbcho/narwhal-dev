import Darwin
import Foundation
import Testing
import NarwhalCore
@testable import NarwhalIPC

@Suite("IPC transport")
struct IPCTransportTests {
    @Test("Production IPC path uses the private Darwin user temporary directory")
    func productionPathUsesPrivateUserDirectory() throws {
        let expectedDirectory = try darwinUserTemporaryDirectoryForTest()

        #expect(try IPCDefaults.socketPath() == expectedDirectory + "/narwhal.sock")
        #expect(IPCDefaults.lockPath(forSocketPath: expectedDirectory + "/narwhal.sock") == expectedDirectory + "/narwhal.lock")
    }

    @Test("Explicit IPC endpoints receive independent lock paths")
    func explicitEndpointsReceiveIndependentLocks() {
        #expect(IPCDefaults.lockPath(forSocketPath: "/private/tmp/first.sock") == "/private/tmp/first.lock")
        #expect(IPCDefaults.lockPath(forSocketPath: "/private/tmp/second") == "/private/tmp/second.lock")
    }

    @Test("Private runtime directory validation rejects unsafe metadata")
    func privateRuntimeDirectoryRejectsUnsafeMetadata() throws {
        let path = "/private/var/folders/example/T"
        let safe = IPCPathMetadata(
            kind: .directory,
            ownerUID: Darwin.getuid(),
            permissions: 0o700,
            device: 1,
            inode: 2
        )
        try validatePrivateRuntimeDirectory(path: path, metadata: safe, expectedUID: Darwin.getuid()).get()

        let worldAccessible = IPCPathMetadata(
            kind: .directory,
            ownerUID: Darwin.getuid(),
            permissions: 0o755,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try validatePrivateRuntimeDirectory(
                path: path,
                metadata: worldAccessible,
                expectedUID: Darwin.getuid()
            ).get()
        }

        let wrongOwner = IPCPathMetadata(
            kind: .directory,
            ownerUID: Darwin.getuid() + 1,
            permissions: 0o700,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try validatePrivateRuntimeDirectory(
                path: path,
                metadata: wrongOwner,
                expectedUID: Darwin.getuid()
            ).get()
        }

        let regularFile = IPCPathMetadata(
            kind: .regularFile,
            ownerUID: Darwin.getuid(),
            permissions: 0o700,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try validatePrivateRuntimeDirectory(
                path: path,
                metadata: regularFile,
                expectedUID: Darwin.getuid()
            ).get()
        }
    }

    @Test("Server handles multiple newline-delimited commands on one connection")
    func serverReusesConnectionForMultipleCommands() async throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path) { command in
            switch command {
            case .resetLayout:
                return .ok(commandID: CommandID(raw: "reset-ok"))
            case .pushFocused(.left):
                return .ok(commandID: CommandID(raw: "push-left-ok"))
            default:
                return .error(commandID: CommandID(raw: "unexpected"), code: "unexpected_command", message: "\(command)")
            }
        }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        let client = IPCClient(socketPath: path)
        defer { client.close() }

        let resetReply = try client.send(.resetLayout)
        let pushReply = try client.send(.pushFocused(.left))

        #expect(resetReply == .ok(commandID: CommandID(raw: "reset-ok")))
        #expect(pushReply == .ok(commandID: CommandID(raw: "push-left-ok")))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Server returns exact structured error for invalid command JSON")
    func invalidJSONReturnsStructuredError() async throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path) { _ in
            .ok(commandID: CommandID(raw: "should-not-run"))
        }
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path)
        defer { client.close() }

        let reply = try client.sendRawLine(Data(#"{"command":"push","direction":"sideways"}"#.utf8) + Data([0x0A]))

        #expect(reply == .error(
            commandID: CommandID(raw: "decode-error"),
            code: "invalid_json",
            message: "Invalid IPC command JSON"
        ))
    }

    @Test("Server stop closes idle active client sockets")
    func stopClosesIdleActiveClientSockets() async throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path) { _ in
            .ok(commandID: CommandID(raw: "should-not-run"))
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectRawSocket(path: path)
        defer { Darwin.close(fd) }
        try await Task.sleep(nanoseconds: 20_000_000)

        server.stop()

        var byte: UInt8 = 0
        let closed = try await waitUntil {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return true }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return false }
            if count < 0, errno == EINTR { return false }
            return true
        }
        #expect(closed)
    }

    @Test("Server survives client closing before reply write")
    func serverSurvivesClientClosingBeforeReplyWrite() async throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path) { _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .ok(commandID: CommandID(raw: "still-running"))
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectRawSocket(path: path, nonBlocking: false)
        try writeAllRaw(Data(#"{"command":"resetLayout"}"#.utf8) + Data([0x0A]), to: fd)
        Darwin.close(fd)
        try await Task.sleep(nanoseconds: 50_000_000)

        let client = IPCClient(socketPath: path)
        defer { client.close() }

        #expect(try client.send(.resetLayout) == .ok(commandID: CommandID(raw: "still-running")))
    }

    @Test("Idle clients time out and release bounded server slots")
    func idleClientsReleaseServerSlotsAfterTimeout() async throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path, maxConnections: 2, ioTimeout: 0.08) { _ in
            .ok(commandID: CommandID(raw: "recovered"))
        }
        try server.start()
        defer { server.stop() }

        let first = try connectRawSocket(path: path)
        defer { Darwin.close(first) }
        let second = try connectRawSocket(path: path)
        defer { Darwin.close(second) }
        try await Task.sleep(nanoseconds: 180_000_000)

        let client = IPCClient(socketPath: path, ioTimeout: 0.5)
        defer { client.close() }
        #expect(try client.send(.resetLayout) == .ok(commandID: CommandID(raw: "recovered")))
    }

    @Test("Client abandons a connection when its reply deadline expires")
    func clientAbandonsConnectionAfterReplyTimeout() async throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path, ioTimeout: 1.0) { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .ok(commandID: CommandID(raw: "late"))
        }
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path, ioTimeout: 0.05)
        do {
            _ = try client.send(.resetLayout)
            Issue.record("Expected client read timeout")
        } catch IPCTransportError.timedOut(let operation) {
            #expect(operation == "read")
        } catch {
            Issue.record("Expected IPC read timeout, got \(String(describing: error))")
        }
    }

    private func tempSocketPath() -> String {
        "/private/tmp/narwhal-ipc-\(UUID().uuidString).sock"
    }

    private func darwinUserTemporaryDirectoryForTest() throws -> String {
        let required = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard required > 1 else { throw POSIXError(.EIO) }
        var buffer = [CChar](repeating: 0, count: required)
        guard Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, required) == required else {
            throw POSIXError(.EIO)
        }
        return String(cString: buffer).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty
            ? "/"
            : "/" + String(cString: buffer)
                .split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/")
    }

    private func connectRawSocket(path: String, nonBlocking: Bool = true) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try configureNoSIGPIPE(fd)
            try withSocketAddress(path: path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            if nonBlocking {
                let flags = Darwin.fcntl(fd, F_GETFL, 0)
                guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func configureNoSIGPIPE(_ fd: Int32) throws {
        var noSIGPIPE: Int32 = 1
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSIGPIPE,
            socklen_t(MemoryLayout.size(ofValue: noSIGPIPE))
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeAllRaw(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 {
                    throw POSIXError(.EPIPE)
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
            throw POSIXError(.ENAMETOOLONG)
        }
        guard let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) else {
            throw POSIXError(.EINVAL)
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

    private func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0..<50 {
            if try condition() {
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try condition()
    }
}
