import Darwin
import Foundation
import Testing
import NarwhalCore
@testable import NarwhalIPC

@Suite("IPC transport")
struct IPCTransportTests {
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

    private func tempSocketPath() -> String {
        "/private/tmp/narwhal-ipc-\(UUID().uuidString).sock"
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
