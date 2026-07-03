import Foundation
import Testing
@testable import NarwhalAppRuntime

@Suite("Lua config loader")
struct LuaConfigLoaderTests {
    @Test("Lua decoder rejects sparse integer-keyed tables without trapping")
    func luaDecoderRejectsSparseIntegerKeyedTablesWithoutTrapping() throws {
        let url = try writeTemporaryConfig("""
        return {
          keymap = {
            { key = "a", modifiers = { "control" }, action = { type = "show_commands" } },
            { key = "b", modifiers = { "control" }, action = { type = "show_commands" } },
            { key = "c", modifiers = { "control" }, action = { type = "show_commands" } },
            [5] = { key = "e", modifiers = { "control" }, action = { type = "show_commands" } },
            [7] = { key = "g", modifiers = { "control" }, action = { type = "show_commands" } },
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        switch result {
        case .failure(.luaDecodeFailed(let path, let message)):
            #expect(path == url.path)
            #expect(message == "return[keymap] must be a dense array")
        default:
            #expect(Bool(false), "Expected sparse Lua table decode failure, got \(String(describing: result))")
        }
    }

    private func writeTemporaryConfig(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-lua-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("init.lua")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
