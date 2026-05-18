import Foundation
import Testing
@testable import WinMgrCore

@Suite("IPC DTO JSON")
struct IPCDTOTests {
    @Test("Command JSON uses stable command-key shape")
    func commandJSONShapeIsStable() throws {
        #expect(try encode(.pushFocused(.left)) == #"{"command":"push","direction":"left"}"#)
        #expect(try encode(.push(windowID: WindowID(raw: 123), direction: .right)) == #"{"command":"push","direction":"right","windowID":123}"#)
        #expect(try encode(.center(windowID: WindowID(raw: 234))) == #"{"command":"center","windowID":234}"#)
        #expect(try encode(.eject(windowID: WindowID(raw: 235))) == #"{"command":"eject","windowID":235}"#)
        #expect(try encode(.toggleFloat(windowID: WindowID(raw: 236))) == #"{"command":"toggleFloat","windowID":236}"#)
        #expect(try encode(.swapFocused(.left)) == #"{"command":"swap","direction":"left"}"#)
        #expect(try encode(.swap(windowID: WindowID(raw: 345), direction: .right)) == #"{"command":"swap","direction":"right","windowID":345}"#)
        #expect(try encode(.resizeFocused(.right, delta: 0.25)) == #"{"command":"resizeSplit","delta":0.25,"direction":"right"}"#)
        #expect(
            try encode(.resize(windowID: WindowID(raw: 346), direction: .left, delta: -0.5))
                == #"{"command":"resizeSplit","delta":-0.5,"direction":"left","windowID":346}"#
        )
        #expect(try encode(.focusDirection(.up)) == #"{"command":"focusDirection","direction":"up"}"#)
        #expect(try encode(.focusCycle(.next)) == #"{"command":"focusCycle","direction":"next"}"#)
        #expect(try encode(.focus(windowID: WindowID(raw: 237))) == #"{"command":"focus","windowID":237}"#)
        #expect(try encode(.balance) == #"{"command":"balance"}"#)
        #expect(try encode(.resetLayout) == #"{"command":"resetLayout"}"#)
        #expect(try encode(.quit) == #"{"command":"quit"}"#)
    }

    @Test("Command JSON decodes focused and explicit push commands")
    func commandJSONDecodesPushForms() throws {
        let focused = try decodeCommand(#"{"command":"push","direction":"up"}"#)
        let explicit = try decodeCommand(#"{"command":"push","direction":"down","windowID":456}"#)

        #expect(focused == .pushFocused(.up))
        #expect(explicit == .push(windowID: WindowID(raw: 456), direction: .down))
        #expect(focused.toCommand() == .failure(.focusedWindowRequired))
        #expect(focused.toCommand(focusedWindowID: WindowID(raw: 789)) == .success(.push(WindowID(raw: 789), .up)))
        #expect(explicit.toCommand() == .success(.push(WindowID(raw: 456), .down)))
        #expect(try decodeCommand(#"{"command":"center","windowID":234}"#).toCommand() == .success(.center(WindowID(raw: 234))))
        #expect(try decodeCommand(#"{"command":"eject","windowID":235}"#).toCommand() == .success(.eject(WindowID(raw: 235))))
        #expect(try decodeCommand(#"{"command":"toggleFloat","windowID":236}"#).toCommand() == .success(.toggleFloat(WindowID(raw: 236))))
        #expect(try decodeCommand(#"{"command":"focus","windowID":237}"#).toCommand() == .success(.focus(WindowID(raw: 237))))
        #expect(try decodeCommand(#"{"command":"balance"}"#).toCommand() == .failure(.shellCommandOnly))
        #expect(try decodeCommand(#"{"command":"swap","direction":"left"}"#).toCommand() == .failure(.focusedWindowRequired))
        #expect(try decodeCommand(#"{"command":"swap","direction":"left"}"#).toCommand(focusedWindowID: WindowID(raw: 567)) == .success(.swapInTree(WindowID(raw: 567), .left)))
        #expect(try decodeCommand(#"{"command":"swap","direction":"right","windowID":678}"#).toCommand() == .success(.swapInTree(WindowID(raw: 678), .right)))
        #expect(try decodeCommand(#"{"command":"resizeSplit","direction":"right","delta":0.25}"#).toCommand() == .failure(.focusedWindowRequired))
        #expect(
            try decodeCommand(#"{"command":"resizeSplit","direction":"right","delta":0.25}"#)
                .toCommand(focusedWindowID: WindowID(raw: 679))
                == .success(.resizeSplit(WindowID(raw: 679), .right, delta: 0.25))
        )
        #expect(
            try decodeCommand(#"{"command":"resizeSplit","direction":"left","delta":-0.5,"windowID":680}"#).toCommand()
                == .success(.resizeSplit(WindowID(raw: 680), .left, delta: -0.5))
        )
        #expect(try decodeCommand(#"{"command":"focusCycle","direction":"previous"}"#).toCommand() == .success(.focusCycle(.previous)))
        #expect(try decodeCommand(#"{"command":"quit"}"#).toCommand() == .failure(.shellCommandOnly))
    }

    @Test("Reply JSON uses stable status shape")
    func replyJSONShapeIsStable() throws {
        #expect(try encodeReply(.ok(commandID: CommandID(raw: "ipc-1"))) == #"{"commandID":"ipc-1","status":"ok"}"#)
        #expect(
            try encodeReply(.error(commandID: CommandID(raw: "ipc-2"), code: "invalid_json", message: "bad payload"))
                == #"{"code":"invalid_json","commandID":"ipc-2","message":"bad payload","status":"error"}"#
        )
    }

    @Test("Reply JSON round-trips exact values")
    func replyJSONRoundTripsExactValues() throws {
        let ok = try decodeReply(#"{"commandID":"ipc-1","status":"ok"}"#)
        let error = try decodeReply(#"{"code":"window_not_found","commandID":"ipc-2","message":"Window missing","status":"error"}"#)

        #expect(ok == .ok(commandID: CommandID(raw: "ipc-1")))
        #expect(error == .error(commandID: CommandID(raw: "ipc-2"), code: "window_not_found", message: "Window missing"))
    }

    private func encode(_ dto: IPCCommandDTO) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(dto), as: UTF8.self)
    }

    private func encodeReply(_ dto: IPCReplyDTO) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(dto), as: UTF8.self)
    }

    private func decodeCommand(_ json: String) throws -> IPCCommandDTO {
        try JSONDecoder().decode(IPCCommandDTO.self, from: Data(json.utf8))
    }

    private func decodeReply(_ json: String) throws -> IPCReplyDTO {
        try JSONDecoder().decode(IPCReplyDTO.self, from: Data(json.utf8))
    }
}
