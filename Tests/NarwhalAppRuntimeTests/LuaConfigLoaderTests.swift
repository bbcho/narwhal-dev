import Foundation
import Testing
@testable import NarwhalAppRuntime

@Suite("Lua config loader")
struct LuaConfigLoaderTests {
    @Test("Lua source stops at its byte budget")
    func luaSourceStopsAtByteBudget() throws {
        let url = try writeTemporaryConfig("return { value = '\(String(repeating: "x", count: 128))' }")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let limits = LuaConfigLimits(sourceBytes: 64, memoryBytes: 1_048_576, instructions: 10_000, decodedValues: 100)

        let result = StartupConfigLoader(
            configURL: url,
            missingFilePolicy: .fail,
            limits: limits
        ).load()

        guard case .failure(.luaResourceLimitExceeded(_, let limit)) = result else {
            Issue.record("Expected source size limit failure, got \(String(describing: result))")
            return
        }
        #expect(limit == .sourceBytes(64))
    }

    @Test("Lua execution stops at its instruction budget")
    func luaExecutionStopsAtInstructionBudget() throws {
        let url = try writeTemporaryConfig("while true do end")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaResourceLimitExceeded(let path, let limit)) = result else {
            Issue.record("Expected instruction limit failure, got \(String(describing: result))")
            return
        }
        #expect(path == url.path)
        #expect(limit == .instructions(LuaConfigLimits.default.instructions))
    }

    @Test("Lua allocation stops at its memory budget")
    func luaAllocationStopsAtMemoryBudget() throws {
        let url = try writeTemporaryConfig("return { value = string.rep('x', 32 * 1024 * 1024) }")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaResourceLimitExceeded(let path, let limit)) = result else {
            Issue.record("Expected memory limit failure, got \(String(describing: result))")
            return
        }
        #expect(path == url.path)
        #expect(limit == .memoryBytes(LuaConfigLimits.default.memoryBytes))
    }

    @Test("Lua config cannot invoke operating-system libraries")
    func luaConfigCannotInvokeOperatingSystemLibraries() throws {
        let url = try writeTemporaryConfig("return { value = os.execute('true') }")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaRuntimeFailed(let path, let message)) = result else {
            Issue.record("Expected unavailable library failure, got \(String(describing: result))")
            return
        }
        #expect(path == url.path)
        #expect(message.contains("global 'os'"))
    }

    @Test("Lua decode stops at its value budget")
    func luaDecodeStopsAtValueBudget() throws {
        let url = try writeTemporaryConfig("return { values = { 1, 2, 3, 4 } }")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let limits = LuaConfigLimits(sourceBytes: 1_024, memoryBytes: 1_048_576, instructions: 10_000, decodedValues: 3)

        let result = StartupConfigLoader(
            configURL: url,
            missingFilePolicy: .fail,
            limits: limits
        ).load()

        guard case .failure(.luaResourceLimitExceeded(_, let limit)) = result else {
            Issue.record("Expected decoded value limit failure, got \(String(describing: result))")
            return
        }
        #expect(limit == .decodedValues(3))
    }

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
