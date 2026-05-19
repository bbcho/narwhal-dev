import CLua
import Foundation
import WinMgrCore

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

enum MissingConfigFilePolicy {
    case useBuiltInDefault
    case fail
}

enum StartupConfigError: Error, CustomStringConvertible {
    case missingConfigPathArgument
    case configFileNotFound(String)
    case luaStateUnavailable
    case luaLoadFailed(path: String, message: String)
    case luaRuntimeFailed(path: String, message: String)
    case luaDecodeFailed(path: String, message: String)
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
        case .configInvalid(let path, let error):
            return "Config validation failed for \(path): \(error.description)"
        }
    }
}

struct StartupConfigLoader {
    static var defaultUserConfigURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/winmgr/init.lua")
    }

    let configURL: URL
    let missingFilePolicy: MissingConfigFilePolicy
    let fileManager: FileManager

    init(
        configURL: URL = StartupConfigLoader.defaultUserConfigURL,
        missingFilePolicy: MissingConfigFilePolicy = .useBuiltInDefault,
        fileManager: FileManager = .default
    ) {
        self.configURL = configURL
        self.missingFilePolicy = missingFilePolicy
        self.fileManager = fileManager
    }

    func load() -> Result<StartupConfigLoad, StartupConfigError> {
        guard fileManager.fileExists(atPath: configURL.path) else {
            guard missingFilePolicy == .useBuiltInDefault else {
                return .failure(.configFileNotFound(configURL.path))
            }
            return .success(StartupConfigLoad(config: .default, source: .builtInDefault(missingUserConfig: configURL)))
        }

        do {
            let data = try LuaConfigDecoder(url: configURL).decode()
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

    init(url: URL) {
        self.url = url
    }

    func decode() throws -> LuaConfigData {
        guard let state = winmgr_lua_newstate() else {
            throw StartupConfigError.luaStateUnavailable
        }
        defer { winmgr_lua_close(state) }

        winmgr_lua_openlibs(state)

        let loadStatus = url.path.withCString { path in
            winmgr_lua_loadfile(state, path)
        }
        guard loadStatus == 0 else {
            throw StartupConfigError.luaLoadFailed(path: url.path, message: stackString(state, index: -1) ?? "unknown load error")
        }

        let runtimeStatus = winmgr_lua_pcall(state, 0, 1, 0)
        guard runtimeStatus == 0 else {
            throw StartupConfigError.luaRuntimeFailed(path: url.path, message: stackString(state, index: -1) ?? "unknown runtime error")
        }

        var activeTables = Set<UInt>()
        let value = try decodeValue(state, index: -1, path: "return", depth: 0, activeTables: &activeTables)
        guard case .table(let root) = value else {
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "config must return a table")
        }
        return LuaConfigData(root: root)
    }

    private func decodeValue(
        _ state: OpaquePointer,
        index: CInt,
        path: String,
        depth: Int,
        activeTables: inout Set<UInt>
    ) throws -> LuaValue {
        let absolute = winmgr_lua_absindex(state, index)
        let type = winmgr_lua_type(state, absolute)

        switch type {
        case winmgr_lua_type_nil():
            return .nilValue
        case winmgr_lua_type_boolean():
            return .bool(winmgr_lua_toboolean(state, absolute) != 0)
        case winmgr_lua_type_number():
            var isNumber: CInt = 0
            let number = winmgr_lua_tonumber(state, absolute, &isNumber)
            guard isNumber != 0 else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) is not a valid number")
            }
            return .number(Double(number))
        case winmgr_lua_type_string():
            guard let string = stackString(state, index: absolute) else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) is not valid UTF-8")
            }
            return .string(string)
        case winmgr_lua_type_table():
            return try decodeTable(state, index: absolute, path: path, depth: depth, activeTables: &activeTables)
        default:
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has unsupported Lua type \(type)")
        }
    }

    private func decodeTable(
        _ state: OpaquePointer,
        index: CInt,
        path: String,
        depth: Int,
        activeTables: inout Set<UInt>
    ) throws -> LuaValue {
        guard depth < Self.maxDecodeDepth else {
            throw StartupConfigError.luaDecodeFailed(
                path: url.path,
                message: "\(path) exceeds maximum table nesting depth \(Self.maxDecodeDepth)"
            )
        }
        guard let tablePointer = winmgr_lua_topointer(state, index) else {
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

        winmgr_lua_pushnil(state)
        while winmgr_lua_next(state, index) != 0 {
            let key = try decodeTableKey(state, index: -2, path: path)
            let entryPath = "\(path)[\(key.description)]"
            let value = try decodeValue(
                state,
                index: -1,
                path: entryPath,
                depth: depth + 1,
                activeTables: &activeTables
            )
            switch key {
            case .string(let name):
                stringEntries[name] = value
            case .integer(let position):
                integerEntries[position] = value
            }
            winmgr_lua_pop(state, 1)
        }

        if !stringEntries.isEmpty {
            guard integerEntries.isEmpty else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) mixes string and integer keys")
            }
            return .table(stringEntries)
        }

        let count = Int(winmgr_lua_rawlen(state, index))
        guard integerEntries.count == count else {
            throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) must be a dense array")
        }
        guard count > 0 else {
            return .array([])
        }
        return .array((1...count).map { position in
            integerEntries[position]!
        })
    }

    private func decodeTableKey(_ state: OpaquePointer, index: CInt, path: String) throws -> LuaTableKey {
        let type = winmgr_lua_type(state, index)
        switch type {
        case winmgr_lua_type_string():
            guard let string = stackString(state, index: index) else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has a non-UTF-8 key")
            }
            return .string(string)
        case winmgr_lua_type_number():
            guard winmgr_lua_isinteger(state, index) != 0 else {
                throw StartupConfigError.luaDecodeFailed(path: url.path, message: "\(path) has a non-integer numeric key")
            }
            var isNumber: CInt = 0
            let integer = winmgr_lua_tointeger(state, index, &isNumber)
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
    guard let pointer = winmgr_lua_tolstring(state, index, &length) else { return nil }
    let buffer = UnsafeRawBufferPointer(start: pointer, count: length)
    return String(decoding: buffer, as: UTF8.self)
}
