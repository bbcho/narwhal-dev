import CLua
import Foundation
import NarwhalCore

struct StartupConfigLoad {
    let config: Config
    let source: StartupConfigSource
}

struct StartupConfigRequest {
    let url: URL
    let missingFilePolicy: MissingConfigFilePolicy
}

enum StartupConfigSource: Equatable {
    case builtInDefault(missingUserConfig: URL)
    case userFile(URL)
}

enum MissingConfigFilePolicy: Equatable {
    case useBuiltInDefault
    case fail
}

enum LuaConfigResourceLimit: Equatable {
    case sourceBytes(Int)
    case memoryBytes(Int)
    case instructions(Int)
    case decodedValues(Int)

    var description: String {
        switch self {
        case .sourceBytes(let bytes):
            return "source size limit of \(bytes) bytes"
        case .memoryBytes(let bytes):
            return "memory limit of \(bytes) bytes"
        case .instructions(let instructions):
            return "instruction limit of \(instructions)"
        case .decodedValues(let values):
            return "decoded value limit of \(values)"
        }
    }
}

struct LuaConfigLimits: Equatable {
    static let `default` = LuaConfigLimits(
        sourceBytes: 1_048_576,
        memoryBytes: 16_777_216,
        instructions: 1_000_000,
        decodedValues: 10_000
    )

    let sourceBytes: Int
    let memoryBytes: Int
    let instructions: Int
    let decodedValues: Int

    init(sourceBytes: Int, memoryBytes: Int, instructions: Int, decodedValues: Int) {
        self.sourceBytes = max(1, sourceBytes)
        self.memoryBytes = max(1, memoryBytes)
        self.instructions = max(1, instructions)
        self.decodedValues = max(1, decodedValues)
    }
}

enum StartupConfigError: Error, CustomStringConvertible {
    case missingConfigPathArgument
    case configFileNotFound(String)
    case luaStateUnavailable
    case luaLoadFailed(path: String, message: String)
    case luaRuntimeFailed(path: String, message: String)
    case luaDecodeFailed(path: String, message: String)
    case luaResourceLimitExceeded(path: String, limit: LuaConfigResourceLimit)
    case configInvalid(path: String, error: ConfigError)

    var description: String {
        switch self {
        case .missingConfigPathArgument:
            return "--config requires a file path"
        case .configFileNotFound(let path):
            return "Config file not found at \(path)"
        case .luaStateUnavailable:
            return "Lua state could not be created"
        case .luaLoadFailed(let path, let message):
            return "Lua load failed for \(path): \(message)"
        case .luaRuntimeFailed(let path, let message):
            return "Lua runtime failed for \(path): \(message)"
        case .luaDecodeFailed(let path, let message):
            return "Lua decode failed for \(path): \(message)"
        case .luaResourceLimitExceeded(let path, let limit):
            return "Lua config at \(path) exceeded its \(limit.description)"
        case .configInvalid(let path, let error):
            return "Config validation failed for \(path): \(error.description)"
        }
    }
}

struct StartupConfigLoader {
    static var defaultUserConfigURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/narwhal/init.lua")
    }

    let configURL: URL
    let missingFilePolicy: MissingConfigFilePolicy
    let fileManager: FileManager
    let limits: LuaConfigLimits

    init(
        configURL: URL = StartupConfigLoader.defaultUserConfigURL,
        missingFilePolicy: MissingConfigFilePolicy = .useBuiltInDefault,
        fileManager: FileManager = .default,
        limits: LuaConfigLimits = .default
    ) {
        self.configURL = configURL
        self.missingFilePolicy = missingFilePolicy
        self.fileManager = fileManager
        self.limits = limits
    }

    func load() -> Result<StartupConfigLoad, StartupConfigError> {
        guard fileManager.fileExists(atPath: configURL.path) else {
            guard missingFilePolicy == .useBuiltInDefault else {
                return .failure(.configFileNotFound(configURL.path))
            }
            return .success(StartupConfigLoad(config: .default, source: .builtInDefault(missingUserConfig: configURL)))
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: configURL.path)
            if let sourceBytes = attributes[.size] as? NSNumber,
               sourceBytes.int64Value > Int64(limits.sourceBytes) {
                return .failure(.luaResourceLimitExceeded(
                    path: configURL.path,
                    limit: .sourceBytes(limits.sourceBytes)
                ))
            }
            let data = try LuaConfigDecoder(url: configURL, limits: limits).decode()
            switch parseConfig(data) {
            case .success(let config):
                return .success(StartupConfigLoad(config: config, source: .userFile(configURL)))
            case .failure(let error):
                return .failure(.configInvalid(path: configURL.path, error: error))
            }
        } catch let error as StartupConfigError {
            return .failure(error)
        } catch {
            return .failure(.luaDecodeFailed(path: configURL.path, message: String(describing: error)))
        }
    }
}

private final class LuaConfigDecoder {
    private static let maxDecodeDepth = 64

    let url: URL
    let limits: LuaConfigLimits

    init(url: URL, limits: LuaConfigLimits) {
        self.url = url
        self.limits = limits
    }

    func decode() throws -> LuaConfigData {
        guard let state = narwhal_lua_newstate(limits.memoryBytes) else {
            throw StartupConfigError.luaStateUnavailable
        }
        defer { narwhal_lua_close(state) }

        let libraryStatus = narwhal_lua_open_config_libraries(state)
        guard libraryStatus == 0 else {
            try throwLuaFailure(state, path: url.path, phase: "library initialization")
        }
        narwhal_lua_set_instruction_limit(state, UInt64(limits.instructions))

        let loadStatus = url.path.withCString { path in
            narwhal_lua_loadfile(state, path)
        }
        guard loadStatus == 0 else {
            if narwhal_lua_memory_limit_exceeded(state) != 0 {
                throw StartupConfigError.luaResourceLimitExceeded(
                    path: url.path,
                    limit: .memoryBytes(limits.memoryBytes)
                )
            }
            throw StartupConfigError.luaLoadFailed(path: url.path, message: stackString(state, index: -1) ?? "unknown load error")
        }

        let runtimeStatus = narwhal_lua_pcall(state, 0, 1, 0)
        guard runtimeStatus == 0 else {
            try throwLuaFailure(state, path: url.path, phase: "runtime")
        }

        var activeTables = Set<UInt>()
        var remainingValues = limits.decodedValues
        let value = try decodeValue(
            state,
            index: -1,
            path: "return",
            depth: 0,
            remainingValues: &remainingValues,
            activeTables: &activeTables
        )
        guard case .table(let root) = value else {
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "config must return a table")
        }
        return LuaConfigData(root: root)
    }

    private func throwLuaFailure(_ state: OpaquePointer, path: String, phase: String) throws -> Never {
        if narwhal_lua_memory_limit_exceeded(state) != 0 {
            throw StartupConfigError.luaResourceLimitExceeded(
                path: path,
                limit: .memoryBytes(limits.memoryBytes)
            )
        }
        if narwhal_lua_instruction_limit_exceeded(state) != 0 {
            throw StartupConfigError.luaResourceLimitExceeded(
                path: path,
                limit: .instructions(limits.instructions)
            )
        }
        throw StartupConfigError.luaRuntimeFailed(
            path: path,
            message: stackString(state, index: -1) ?? "unknown \(phase) error"
        )
    }

    private func decodeValue(
        _ state: OpaquePointer,
        index: CInt,
        path: String,
        depth: Int,
        remainingValues: inout Int,
        activeTables: inout Set<UInt>
    ) throws -> LuaValue {
        guard remainingValues > 0 else {
            throw StartupConfigError.luaResourceLimitExceeded(
                path: url.path,
                limit: .decodedValues(limits.decodedValues)
            )
        }
        remainingValues -= 1
        let absolute = narwhal_lua_absindex(state, index)
        let type = narwhal_lua_type(state, absolute)

        switch type {
        case narwhal_lua_type_nil():
            return .nilValue
        case narwhal_lua_type_boolean():
            return .bool(narwhal_lua_toboolean(state, absolute) != 0)
        case narwhal_lua_type_number():
            var isNumber: CInt = 0
            let number = narwhal_lua_tonumber(state, absolute, &isNumber)
            guard isNumber != 0 else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) is not a valid number")
            }
            return .number(Double(number))
        case narwhal_lua_type_string():
            guard let string = stackString(state, index: absolute) else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) is not valid UTF-8")
            }
            return .string(string)
        case narwhal_lua_type_table():
            return try decodeTable(
                state,
                index: absolute,
                path: path,
                depth: depth,
                remainingValues: &remainingValues,
                activeTables: &activeTables
            )
        default:
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has unsupported Lua type \(type)")
        }
    }

    private func decodeTable(
        _ state: OpaquePointer,
        index: CInt,
        path: String,
        depth: Int,
        remainingValues: inout Int,
        activeTables: inout Set<UInt>
    ) throws -> LuaValue {
        guard depth < Self.maxDecodeDepth else {
            throw StartupConfigError.luaDecodeFailed(
                path: url.path,
                message: "\(path) exceeds maximum table nesting depth \(Self.maxDecodeDepth)"
            )
        }
        guard let tablePointer = narwhal_lua_topointer(state, index) else {
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) table identity unavailable")
        }
        let tableID = UInt(bitPattern: tablePointer)
        guard activeTables.insert(tableID).inserted else {
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) contains a cyclic table reference")
        }
        defer {
            activeTables.remove(tableID)
        }

        var stringEntries: [String: LuaValue] = [:]
        var integerEntries: [Int: LuaValue] = [:]

        narwhal_lua_pushnil(state)
        while narwhal_lua_next(state, index) != 0 {
            let key = try decodeTableKey(state, index: -2, path: path)
            let entryPath = "\(path)[\(key.description)]"
            let value = try decodeValue(
                state,
                index: -1,
                path: entryPath,
                depth: depth + 1,
                remainingValues: &remainingValues,
                activeTables: &activeTables
            )
            switch key {
            case .string(let name):
                stringEntries[name] = value
            case .integer(let position):
                integerEntries[position] = value
            }
            narwhal_lua_pop(state, 1)
        }

        if !stringEntries.isEmpty {
            guard integerEntries.isEmpty else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) mixes string and integer keys")
            }
            return .table(stringEntries)
        }

        let rawCount = narwhal_lua_rawlen(state, index)
        guard rawCount <= lua_Unsigned(Int.max) else {
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) must be a dense array")
        }
        let count = Int(rawCount)
        guard integerEntries.count == count else {
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) must be a dense array")
        }
        guard count > 0 else {
            return .array([])
        }
        var values: [LuaValue] = []
        values.reserveCapacity(count)
        for position in 1...count {
            guard let value = integerEntries[position] else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) must be a dense array")
            }
            values.append(value)
        }
        return .array(values)
    }

    private func decodeTableKey(_ state: OpaquePointer, index: CInt, path: String) throws -> LuaTableKey {
        let type = narwhal_lua_type(state, index)
        switch type {
        case narwhal_lua_type_string():
            guard let string = stackString(state, index: index) else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has a non-UTF-8 key")
            }
            return .string(string)
        case narwhal_lua_type_number():
            guard narwhal_lua_isinteger(state, index) != 0 else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has a non-integer numeric key")
            }
            var isNumber: CInt = 0
            let integer = narwhal_lua_tointeger(state, index, &isNumber)
            guard isNumber != 0, integer > 0, integer <= lua_Integer(Int.max) else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has an invalid array index")
            }
            return .integer(Int(integer))
        default:
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has unsupported key type \(type)")
        }
    }
}

private enum LuaTableKey: CustomStringConvertible {
    case string(String)
    case integer(Int)

    var description: String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        }
    }
}

private func stackString(_ state: OpaquePointer, index: CInt) -> String? {
    var length = 0
    guard let pointer = narwhal_lua_tolstring(state, index, &length) else { return nil }
    let buffer = UnsafeRawBufferPointer(start: pointer, count: length)
    return String(decoding: buffer, as: UTF8.self)
}
