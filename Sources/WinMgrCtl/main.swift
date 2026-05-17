import Darwin
import Foundation
import WinMgrCore
import WinMgrIPC

@main
struct WinMgrCtl {
    static func main() {
        do {
            let invocation = try parseInvocation(Array(CommandLine.arguments.dropFirst()))
            let reply = try IPCClient(socketPath: invocation.socketPath).send(invocation.command)
            switch reply {
            case .ok(let commandID):
                print("ok \(commandID.raw)")
                Darwin.exit(0)
            case .error(_, let code, let message):
                fputs("error \(code): \(message)\n", stderr)
                Darwin.exit(1)
            }
        } catch let error as WinMgrCtlError {
            fputs("\(error.description)\n", stderr)
            Darwin.exit(2)
        } catch let error as IPCTransportError {
            fputs("IPC failed: \(error.description)\n", stderr)
            Darwin.exit(1)
        } catch {
            fputs("winmgrctl failed: \(String(describing: error))\n", stderr)
            Darwin.exit(1)
        }
    }
}

private struct Invocation {
    let socketPath: String
    let command: IPCCommandDTO
}

private enum WinMgrCtlError: Error, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case missingDirection
    case invalidDirection(String)
    case missingWindowID
    case invalidWindowID(String)
    case missingSocketPath
    case unexpectedArgument(String)

    var description: String {
        switch self {
        case .missingCommand:
            return usage("missing command")
        case .unknownCommand(let command):
            return usage("unknown command: \(command)")
        case .missingDirection:
            return usage("missing direction")
        case .invalidDirection(let value):
            return usage("invalid direction: \(value)")
        case .missingWindowID:
            return usage("missing window ID after --window")
        case .invalidWindowID(let value):
            return usage("invalid window ID: \(value)")
        case .missingSocketPath:
            return usage("missing socket path after --socket")
        case .unexpectedArgument(let value):
            return usage("unexpected argument: \(value)")
        }
    }

    private func usage(_ message: String) -> String {
        """
        \(message)
        usage:
          winmgrctl reset [--socket PATH]
          winmgrctl push <left|right|up|down> [--window WINDOW_ID] [--socket PATH]
        """
    }
}

private func parseInvocation(_ arguments: [String]) throws -> Invocation {
    var socketPath = IPCDefaults.socketPath
    var positional: [String] = []
    var explicitWindowID: WindowID?
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--socket":
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else { throw WinMgrCtlError.missingSocketPath }
            socketPath = arguments[valueIndex]
            index += 2
        case "--window":
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else { throw WinMgrCtlError.missingWindowID }
            explicitWindowID = try parseWindowID(arguments[valueIndex])
            index += 2
        default:
            if argument.hasPrefix("--") {
                throw WinMgrCtlError.unexpectedArgument(argument)
            }
            positional.append(argument)
            index += 1
        }
    }

    guard let command = positional.first else { throw WinMgrCtlError.missingCommand }
    switch command {
    case "reset", "reset-layout", "resetLayout":
        guard positional.count == 1 else { throw WinMgrCtlError.unexpectedArgument(positional[1]) }
        return Invocation(socketPath: socketPath, command: .resetLayout)
    case "push":
        guard positional.indices.contains(1) else { throw WinMgrCtlError.missingDirection }
        guard positional.count == 2 else { throw WinMgrCtlError.unexpectedArgument(positional[2]) }
        let direction = try parseDirection(positional[1])
        let dto: IPCCommandDTO
        if let explicitWindowID {
            dto = .push(windowID: explicitWindowID, direction: direction)
        } else {
            dto = .pushFocused(direction)
        }
        return Invocation(socketPath: socketPath, command: dto)
    default:
        throw WinMgrCtlError.unknownCommand(command)
    }
}

private func parseDirection(_ raw: String) throws -> Direction {
    guard let direction = Direction(rawValue: raw) else {
        throw WinMgrCtlError.invalidDirection(raw)
    }
    return direction
}

private func parseWindowID(_ raw: String) throws -> WindowID {
    let trimmed = raw.hasPrefix("w") ? String(raw.dropFirst()) : raw
    guard let value = UInt32(trimmed) else {
        throw WinMgrCtlError.invalidWindowID(raw)
    }
    return WindowID(raw: value)
}
