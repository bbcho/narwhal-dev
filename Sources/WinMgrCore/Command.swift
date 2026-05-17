import CoreGraphics

public enum Command: Equatable, Sendable {
    case push(WindowID, Direction)
    case center(WindowID)
    case eject(WindowID)
    case focusDirection(Direction)
    case focus(WindowID)
    case swapInTree(Direction)
    case resizeSplit(WindowID, Direction, delta: Double)
    case balance(SpaceID)
    case toggleFloat(WindowID)
    case dropAtZone(WindowID, DisplayID, ZoneID)
    case resetLayout
    case startupConverge

    case windowOpened(WindowMetadata)
    case windowClosed(WindowID)
    case windowMovedExternally(WindowID, CGRect)
    case windowResizedExternally(WindowID, CGSize)
    case windowFocusedExternally(WindowID)
    case windowConstraintObserved(WindowID, WindowConstraints)
    case environmentChanged(EnvironmentSnapshot)

    case reloadConfig(Config)
}

public enum CommandError: Error, Equatable, Sendable {
    case windowNotFound(WindowID)
    case windowIsFloating(WindowID)
    case windowIsTiled(WindowID)
    case windowNotResizable(WindowID)
    case activeSpaceUnavailable
    case spaceNotFound(SpaceID)
    case displayNotFound(DisplayID)
    case noNeighbor(Direction)
    case layoutUnsatisfiable(UnsatisfiableLayout)
    case zoneNotFound(ZoneID)
    case ruleInvalid(String)
    case configInvalid(String)

    public var code: String {
        switch self {
        case .windowNotFound:
            return "window_not_found"
        case .windowIsFloating:
            return "window_is_floating"
        case .windowIsTiled:
            return "window_is_tiled"
        case .windowNotResizable:
            return "window_not_resizable"
        case .activeSpaceUnavailable:
            return "active_space_unavailable"
        case .spaceNotFound:
            return "space_not_found"
        case .displayNotFound:
            return "display_not_found"
        case .noNeighbor:
            return "no_neighbor"
        case .layoutUnsatisfiable:
            return "layout_unsatisfiable"
        case .zoneNotFound:
            return "zone_not_found"
        case .ruleInvalid:
            return "rule_invalid"
        case .configInvalid:
            return "config_invalid"
        }
    }

    public var message: String {
        switch self {
        case .activeSpaceUnavailable:
            return "active Space unavailable"
        case .layoutUnsatisfiable(let layout):
            return "layout unsatisfiable on display \(layout.displayID.raw) axis=\(layout.axis.rawValue) required=\(layout.required) available=\(layout.available) windows=\(layout.windows.map(\.description).joined(separator: ","))"
        default:
            return String(describing: self)
        }
    }
}

public enum CommandSource: String, Codable, Sendable {
    case hotkey
    case drag
    case ipc
    case ax
    case space
    case display
    case config
    case restore
}

public struct CommandEnvelope: Equatable, Sendable {
    public let id: CommandID
    public let source: CommandSource
    public let command: Command

    public init(id: CommandID, source: CommandSource, command: Command) {
        self.id = id
        self.source = source
        self.command = command
    }
}

public enum CommandOutcome: Equatable, Sendable {
    case success(envelope: CommandEnvelope, newWorld: World, effects: CommandEffects)
    case failure(envelope: CommandEnvelope, error: CommandError)
}

public enum IPCReplyDTO: Codable, Equatable, Sendable {
    case ok(commandID: CommandID)
    case error(commandID: CommandID, code: String, message: String)

    public static func from(_ outcome: CommandOutcome) -> IPCReplyDTO {
        switch outcome {
        case .success(let envelope, _, _):
            return .ok(commandID: envelope.id)
        case .failure(let envelope, let error):
            return .error(commandID: envelope.id, code: error.code, message: error.message)
        }
    }
}

public enum IPCCommandDTO: Codable, Sendable {
    case push(windowID: WindowID, direction: Direction)
    case center(windowID: WindowID)
    case eject(windowID: WindowID)
    case focusDirection(Direction)
    case focus(windowID: WindowID)
    case toggleFloat(windowID: WindowID)
    case resetLayout

    public func toCommand() -> Command {
        switch self {
        case .push(let windowID, let direction):
            return .push(windowID, direction)
        case .center(let windowID):
            return .center(windowID)
        case .eject(let windowID):
            return .eject(windowID)
        case .focusDirection(let direction):
            return .focusDirection(direction)
        case .focus(let windowID):
            return .focus(windowID)
        case .toggleFloat(let windowID):
            return .toggleFloat(windowID)
        case .resetLayout:
            return .resetLayout
        }
    }
}

public struct DragEvent: Equatable, Sendable {
    public let windowID: WindowID
    public let location: CGPoint
    public let displayID: DisplayID?

    public init(windowID: WindowID, location: CGPoint, displayID: DisplayID?) {
        self.windowID = windowID
        self.location = location
        self.displayID = displayID
    }
}

public enum AXEvent: Equatable, Sendable {
    case windowOpened(WindowMetadata)
    case windowClosed(WindowID)
    case windowMoved(WindowID, CGRect)
    case windowResized(WindowID, CGSize)
    case windowFocused(WindowID)

    public func toCommand() -> Command {
        switch self {
        case .windowOpened(let metadata):
            return .windowOpened(metadata)
        case .windowClosed(let id):
            return .windowClosed(id)
        case .windowMoved(let id, let frame):
            return .windowMovedExternally(id, frame)
        case .windowResized(let id, let size):
            return .windowResizedExternally(id, size)
        case .windowFocused(let id):
            return .windowFocusedExternally(id)
        }
    }
}
