import Darwin
import Foundation
import NarwhalCore
import NarwhalIPC

@main
struct NarwhalCtl {
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
        } catch let error as NarwhalCtlError {
            fputs("\(error.description)\n", stderr)
            Darwin.exit(2)
        } catch let error as IPCTransportError {
            fputs("IPC failed: \(error.description)\n", stderr)
            Darwin.exit(1)
        } catch {
            fputs("narwhalctl failed: \(String(describing: error))\n", stderr)
            Darwin.exit(1)
        }
    }
}

private struct Invocation {
    let socketPath: String
    let command: IPCCommandDTO
}

private enum NarwhalCtlError: Error, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case missingDirection
    case invalidDirection(String)
    case missingWindowID
    case invalidWindowID(String)
    case missingDelta
    case invalidDelta(String)
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
        case .missingDelta:
            return usage("missing resize delta after --delta")
        case .invalidDelta(let value):
            return usage("invalid resize delta: \(value)")
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
          narwhalctl reset [--socket PATH]
          narwhalctl balance [--socket PATH]
          narwhalctl quit [--socket PATH]
          narwhalctl push <left|right|up|down> [--window WINDOW_ID] [--socket PATH]
          narwhalctl swap <left|right|up|down> [--window WINDOW_ID] [--socket PATH]
          narwhalctl resize <left|right|up|down> --delta WEIGHT_DELTA [--window WINDOW_ID] [--socket PATH]
          narwhalctl center --window WINDOW_ID [--socket PATH]
          narwhalctl eject --window WINDOW_ID [--socket PATH]
          narwhalctl toggle-float --window WINDOW_ID [--socket PATH]
          narwhalctl focus --window WINDOW_ID [--socket PATH]
          narwhalctl focus-direction <left|right|up|down> [--socket PATH]
          narwhalctl focus-cycle <previous|next> [--socket PATH]
        """
    }
}

private func parseInvocation(_ arguments: [String]) throws -> Invocation {
    var socketPath = IPCDefaults.socketPath
    var positional: [String] = []
    var explicitWindowID: WindowID?
    var resizeDelta: Double?
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--socket":
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else { throw NarwhalCtlError.missingSocketPath }
            socketPath = arguments[valueIndex]
            index += 2
        case "--window":
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else { throw NarwhalCtlError.missingWindowID }
            explicitWindowID = try parseWindowID(arguments[valueIndex])
            index += 2
        case "--delta":
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else { throw NarwhalCtlError.missingDelta }
            resizeDelta = try parseResizeDelta(arguments[valueIndex])
            index += 2
        default:
            if argument.hasPrefix("--") {
                throw NarwhalCtlError.unexpectedArgument(argument)
            }
            positional.append(argument)
            index += 1
        }
    }

    guard let command = positional.first else { throw NarwhalCtlError.missingCommand }
    switch command {
    case "reset", "reset-layout", "resetLayout":
        guard positional.count == 1 else { throw NarwhalCtlError.unexpectedArgument(positional[1]) }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .resetLayout)
    case "balance":
        guard positional.count == 1 else { throw NarwhalCtlError.unexpectedArgument(positional[1]) }
        guard explicitWindowID == nil else { throw NarwhalCtlError.unexpectedArgument("--window") }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .balance)
    case "quit":
        guard positional.count == 1 else { throw NarwhalCtlError.unexpectedArgument(positional[1]) }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .quit)
    case "push":
        guard positional.indices.contains(1) else { throw NarwhalCtlError.missingDirection }
        guard positional.count == 2 else { throw NarwhalCtlError.unexpectedArgument(positional[2]) }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        let direction = try parseDirection(positional[1])
        let dto: IPCCommandDTO
        if let explicitWindowID {
            dto = .push(windowID: explicitWindowID, direction: direction)
        } else {
            dto = .pushFocused(direction)
        }
        return Invocation(socketPath: socketPath, command: dto)
    case "swap":
        guard positional.indices.contains(1) else { throw NarwhalCtlError.missingDirection }
        guard positional.count == 2 else { throw NarwhalCtlError.unexpectedArgument(positional[2]) }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        let direction = try parseDirection(positional[1])
        let dto: IPCCommandDTO
        if let explicitWindowID {
            dto = .swap(windowID: explicitWindowID, direction: direction)
        } else {
            dto = .swapFocused(direction)
        }
        return Invocation(socketPath: socketPath, command: dto)
    case "resize", "resize-split", "resizeSplit":
        guard positional.indices.contains(1) else { throw NarwhalCtlError.missingDirection }
        guard positional.count == 2 else { throw NarwhalCtlError.unexpectedArgument(positional[2]) }
        guard let resizeDelta else { throw NarwhalCtlError.missingDelta }
        let direction = try parseDirection(positional[1])
        let dto: IPCCommandDTO
        if let explicitWindowID {
            dto = .resize(windowID: explicitWindowID, direction: direction, delta: resizeDelta)
        } else {
            dto = .resizeFocused(direction, delta: resizeDelta)
        }
        return Invocation(socketPath: socketPath, command: dto)
    case "center":
        guard positional.count == 1 else { throw NarwhalCtlError.unexpectedArgument(positional[1]) }
        guard let explicitWindowID else { throw NarwhalCtlError.missingWindowID }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .center(windowID: explicitWindowID))
    case "eject":
        guard positional.count == 1 else { throw NarwhalCtlError.unexpectedArgument(positional[1]) }
        guard let explicitWindowID else { throw NarwhalCtlError.missingWindowID }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .eject(windowID: explicitWindowID))
    case "toggle-float", "toggleFloat", "float":
        guard positional.count == 1 else { throw NarwhalCtlError.unexpectedArgument(positional[1]) }
        guard let explicitWindowID else { throw NarwhalCtlError.missingWindowID }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .toggleFloat(windowID: explicitWindowID))
    case "focus":
        guard positional.count == 1 else { throw NarwhalCtlError.unexpectedArgument(positional[1]) }
        guard let explicitWindowID else { throw NarwhalCtlError.missingWindowID }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .focus(windowID: explicitWindowID))
    case "focus-direction", "focusDirection":
        guard positional.indices.contains(1) else { throw NarwhalCtlError.missingDirection }
        guard positional.count == 2 else { throw NarwhalCtlError.unexpectedArgument(positional[2]) }
        guard explicitWindowID == nil else { throw NarwhalCtlError.unexpectedArgument("--window") }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .focusDirection(try parseDirection(positional[1])))
    case "focus-cycle", "focusCycle":
        guard positional.indices.contains(1) else { throw NarwhalCtlError.missingDirection }
        guard positional.count == 2 else { throw NarwhalCtlError.unexpectedArgument(positional[2]) }
        guard explicitWindowID == nil else { throw NarwhalCtlError.unexpectedArgument("--window") }
        guard resizeDelta == nil else { throw NarwhalCtlError.unexpectedArgument("--delta") }
        return Invocation(socketPath: socketPath, command: .focusCycle(try parseFocusCycleDirection(positional[1])))
    default:
        throw NarwhalCtlError.unknownCommand(command)
    }
}

private func parseDirection(_ raw: String) throws -> Direction {
    guard let direction = Direction(rawValue: raw) else {
        throw NarwhalCtlError.invalidDirection(raw)
    }
    return direction
}

private func parseWindowID(_ raw: String) throws -> WindowID {
    let trimmed = raw.hasPrefix("w") ? String(raw.dropFirst()) : raw
    guard let value = UInt32(trimmed) else {
        throw NarwhalCtlError.invalidWindowID(raw)
    }
    return WindowID(raw: value)
}

private func parseFocusCycleDirection(_ raw: String) throws -> FocusCycleDirection {
    guard let direction = FocusCycleDirection(rawValue: raw) else {
        throw NarwhalCtlError.invalidDirection(raw)
    }
    return direction
}

private func parseResizeDelta(_ raw: String) throws -> Double {
    guard let value = Double(raw), value.isFinite else {
        throw NarwhalCtlError.invalidDelta(raw)
    }
    return value
}
