import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Lua config loader")
struct LuaConfigLoaderTests {
    @Test("Empty Lua table loads the complete default config")
    func emptyLuaTableLoadsDefaultConfig() throws {
        let loaded = try loadUserConfig("return {}")

        #expect(loaded.config == Config.default)
    }

    @Test("Empty nested object inherits its default members")
    func emptyNestedObjectInheritsDefaultMembers() throws {
        let loaded = try loadUserConfig("return { border = {} }")

        #expect(loaded.config == Config.default)
    }

    @Test("Real Lua partial config overrides fields and clears explicit collections")
    func realLuaPartialConfigOverridesAndClears() throws {
        let loaded = try loadUserConfig("""
        return {
          keymap = {},
          border = { width = 4 },
        }
        """)

        #expect(loaded.config.keymap.isEmpty)
        #expect(loaded.config.border == BorderConfig(
            width: 4,
            colorHex: Config.default.border.colorHex
        ))
        #expect(loaded.config.zones == Config.default.zones)
    }

    @Test("The bundled default init.lua loads through real Lua to exactly the default config")
    func bundledDefaultConfigLoadsToDefault() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("DefaultConfig/init.lua")

        let loaded = try StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load().get()

        #expect(loaded.config == Config.default)
    }

    @Test("Non-empty root array retains the root table decode error")
    func nonEmptyRootArrayRetainsRootTableDecodeError() throws {
        let url = try writeTemporaryConfig("return {1}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaDecodeFailed(let path, let message)) = result else {
            Issue.record("Expected root Lua table decode failure, got \(String(describing: result))")
            return
        }
        #expect(path == url.path)
        #expect(message == "config must return a table")
    }

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

    @Test("A config that catches the instruction-limit error with pcall still stops at the limit")
    func pcallCannotEscapeInstructionLimit() throws {
        let result = try loadInBackground("while true do pcall(function() while true do end end) end")

        guard case .failure(.luaResourceLimitExceeded(_, let limit)) = result else {
            Issue.record("Expected instruction limit failure, got \(String(describing: result))")
            return
        }
        #expect(limit == .instructions(LuaConfigLimits.default.instructions))
    }

    @Test("A config that catches the instruction-limit error with xpcall still stops at the limit")
    func xpcallCannotEscapeInstructionLimit() throws {
        let result = try loadInBackground(
            "while true do xpcall(function() while true do end end, function() return 1 end) end"
        )

        guard case .failure(.luaResourceLimitExceeded(_, let limit)) = result else {
            Issue.record("Expected instruction limit failure, got \(String(describing: result))")
            return
        }
        #expect(limit == .instructions(LuaConfigLimits.default.instructions))
    }

    @Test("Lua pattern matching is unavailable because it runs outside the instruction budget")
    func patternMatchingIsUnavailable() throws {
        let result = try loadInBackground(
            "return { value = string.find(string.rep('a', 3000), ('.-'):rep(4) .. 'x') }"
        )

        guard case .failure(.luaRuntimeFailed(_, let message)) = result else {
            Issue.record("Expected pattern rejection, got \(String(describing: result))")
            return
        }
        #expect(message.contains("pattern matching is not available in Narwhal config"))
    }

    @Test("Method-style pattern matching on strings is unavailable")
    func methodStylePatternMatchingIsUnavailable() throws {
        let url = try writeTemporaryConfig("return { value = ('abc'):gsub('b', 'x') }")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaRuntimeFailed(_, let message)) = result else {
            Issue.record("Expected gsub to be unavailable, got \(String(describing: result))")
            return
        }
        #expect(message.contains("gsub"))
    }

    @Test("Plain string.find still works in config")
    func plainStringFindStillWorks() throws {
        let loaded = try loadUserConfig("""
        local width = string.find("left", "f", 1, true)
        return { border = { width = width } }
        """)

        #expect(loaded.config.border.width == 3)
    }

    @Test("A config file containing Lua bytecode is rejected")
    func bytecodeConfigFileIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-lua-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("init.lua")
        try Data([0x1B, 0x4C, 0x75, 0x61, 0x55, 0x00, 0x01, 0x02]).write(to: url)

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaLoadFailed(let path, let message)) = result else {
            Issue.record("Expected bytecode load rejection, got \(String(describing: result))")
            return
        }
        #expect(path == url.path)
        #expect(message.contains("attempt to load a binary chunk"))
    }

    @Test("A config cannot load bytecode through load()")
    func configCannotLoadBytecodeThroughLoad() throws {
        let url = try writeTemporaryConfig("""
        local chunk = assert(load(string.dump(function() return {} end), "=dumped", "b"))
        return chunk()
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaRuntimeFailed(_, let message)) = result else {
            Issue.record("Expected binary chunk rejection, got \(String(describing: result))")
            return
        }
        #expect(message.contains("attempt to load a binary chunk"))
    }

    @Test("A caught memory error does not mislabel a later unrelated failure")
    func caughtMemoryErrorDoesNotMislabelLaterFailure() throws {
        let url = try writeTemporaryConfig("""
        pcall(string.rep, "x", 32 * 1024 * 1024)
        error("unrelated config failure")
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()

        guard case .failure(.luaRuntimeFailed(_, let message)) = result else {
            Issue.record("Expected the unrelated runtime failure, got \(String(describing: result))")
            return
        }
        #expect(message.contains("unrelated config failure"))
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

    private func loadUserConfig(_ contents: String) throws -> StartupConfigLoad {
        let url = try writeTemporaryConfig(contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = try StartupConfigLoader(
            configURL: url,
            missingFilePolicy: .fail
        ).load().get()
        #expect(loaded.source == .userFile(url))
        return loaded
    }

    /// Loads on a separate thread so a regression that never terminates fails
    /// the test after 20 seconds instead of hanging the run.
    private func loadInBackground(_ contents: String) throws -> Result<StartupConfigLoad, StartupConfigError>? {
        let url = try writeTemporaryConfig(contents)
        let finished = DispatchSemaphore(value: 0)
        let outcome = LoadOutcome()
        Thread.detachNewThread {
            outcome.result = StartupConfigLoader(configURL: url, missingFilePolicy: .fail).load()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 20) == .success else {
            Issue.record("Lua config was still running after 20 seconds")
            return nil
        }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return outcome.result
    }

    private final class LoadOutcome: @unchecked Sendable {
        var result: Result<StartupConfigLoad, StartupConfigError>?
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
