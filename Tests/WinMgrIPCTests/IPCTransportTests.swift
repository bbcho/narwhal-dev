import Foundation
import Testing
import WinMgrCore
@testable import WinMgrIPC

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

    private func tempSocketPath() -> String {
        "/private/tmp/winmgr-ipc-\(UUID().uuidString).sock"
    }
}
