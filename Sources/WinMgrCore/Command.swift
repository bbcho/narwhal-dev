import CoreGraphics

public enum Command: Equatable, Sendable {
    case push(WindowID, Direction)
    case center(WindowID)
    case eject(WindowID)
    case focusDirection(Direction)
    case focusCycle(FocusCycleDirection)
    case focus(WindowID)
    case swapInTree(WindowID, Direction)
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
    case invalidResizeDelta
    case resizeWouldCollapseSplit(WindowID, Direction)
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
        case .invalidResizeDelta:
            return "invalid_resize_delta"
        case .resizeWouldCollapseSplit:
            return "resize_would_collapse_split"
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
        case .invalidResizeDelta:
            return "resize delta must be finite"
        case .resizeWouldCollapseSplit(let windowID, let direction):
            return "resize would make a split weight non-positive for \(windowID.description) toward \(direction.rawValue)"
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

    private enum CodingKeys: String, CodingKey {
        case status
        case commandID
        case code
        case message
    }

    private enum Status: String, Codable {
        case ok
        case error
    }

    public static func from(_ outcome: CommandOutcome) -> IPCReplyDTO {
        switch outcome {
        case .success(let envelope, _, _):
            return .ok(commandID: envelope.id)
        case .failure(let envelope, let error):
            return .error(commandID: envelope.id, code: error.code, message: error.message)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(Status.self, forKey: .status)
        let commandID = CommandID(raw: try container.decode(String.self, forKey: .commandID))
        switch status {
        case .ok:
            self = .ok(commandID: commandID)
        case .error:
            self = .error(
                commandID: commandID,
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let commandID):
            try container.encode(Status.ok, forKey: .status)
            try container.encode(commandID.raw, forKey: .commandID)
        case .error(let commandID, let code, let message):
            try container.encode(Status.error, forKey: .status)
            try container.encode(commandID.raw, forKey: .commandID)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}

public enum IPCCommandResolutionError: Error, Equatable, Sendable {
    case focusedWindowRequired
    case shellCommandOnly
}

public enum IPCCommandDTO: Codable, Equatable, Sendable {
    case pushFocused(Direction)
    case push(windowID: WindowID, direction: Direction)
    case center(windowID: WindowID)
    case eject(windowID: WindowID)
    case swapFocused(Direction)
    case swap(windowID: WindowID, direction: Direction)
    case resizeFocused(Direction, delta: Double)
    case resize(windowID: WindowID, direction: Direction, delta: Double)
    case focusDirection(Direction)
    case focusCycle(FocusCycleDirection)
    case focus(windowID: WindowID)
    case toggleFloat(windowID: WindowID)
    case balance
    case resetLayout
    case quit

    private enum CodingKeys: String, CodingKey {
        case command
        case windowID
        case direction
        case delta
    }

    private enum CommandName: String, Codable {
        case push
        case center
        case eject
        case swap
        case resizeSplit
        case focusDirection
        case focusCycle
        case focus
        case toggleFloat
        case balance
        case resetLayout
        case quit
    }

    public func toCommand(focusedWindowID: WindowID? = nil) -> Result<Command, IPCCommandResolutionError> {
        switch self {
        case .pushFocused(let direction):
            guard let focusedWindowID else { return .failure(.focusedWindowRequired) }
            return .success(.push(focusedWindowID, direction))
        case .push(let windowID, let direction):
            return .success(.push(windowID, direction))
        case .center(let windowID):
            return .success(.center(windowID))
        case .eject(let windowID):
            return .success(.eject(windowID))
        case .swapFocused(let direction):
            guard let focusedWindowID else { return .failure(.focusedWindowRequired) }
            return .success(.swapInTree(focusedWindowID, direction))
        case .swap(let windowID, let direction):
            return .success(.swapInTree(windowID, direction))
        case .resizeFocused(let direction, let delta):
            guard let focusedWindowID else { return .failure(.focusedWindowRequired) }
            return .success(.resizeSplit(focusedWindowID, direction, delta: delta))
        case .resize(let windowID, let direction, let delta):
            return .success(.resizeSplit(windowID, direction, delta: delta))
        case .focusDirection(let direction):
            return .success(.focusDirection(direction))
        case .focusCycle(let direction):
            return .success(.focusCycle(direction))
        case .focus(let windowID):
            return .success(.focus(windowID))
        case .toggleFloat(let windowID):
            return .success(.toggleFloat(windowID))
        case .balance:
            return .failure(.shellCommandOnly)
        case .resetLayout:
            return .success(.resetLayout)
        case .quit:
            return .failure(.shellCommandOnly)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(CommandName.self, forKey: .command) {
        case .push:
            let direction = try container.decode(Direction.self, forKey: .direction)
            if let rawWindowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID) {
                self = .push(windowID: WindowID(raw: rawWindowID), direction: direction)
            } else {
                self = .pushFocused(direction)
            }
        case .center:
            self = .center(windowID: try Self.decodeWindowID(from: container))
        case .eject:
            self = .eject(windowID: try Self.decodeWindowID(from: container))
        case .swap:
            let direction = try container.decode(Direction.self, forKey: .direction)
            if let rawWindowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID) {
                self = .swap(windowID: WindowID(raw: rawWindowID), direction: direction)
            } else {
                self = .swapFocused(direction)
            }
        case .resizeSplit:
            let direction = try container.decode(Direction.self, forKey: .direction)
            let delta = try container.decode(Double.self, forKey: .delta)
            if let rawWindowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID) {
                self = .resize(windowID: WindowID(raw: rawWindowID), direction: direction, delta: delta)
            } else {
                self = .resizeFocused(direction, delta: delta)
            }
        case .focusDirection:
            self = .focusDirection(try container.decode(Direction.self, forKey: .direction))
        case .focusCycle:
            self = .focusCycle(try container.decode(FocusCycleDirection.self, forKey: .direction))
        case .focus:
            self = .focus(windowID: try Self.decodeWindowID(from: container))
        case .toggleFloat:
            self = .toggleFloat(windowID: try Self.decodeWindowID(from: container))
        case .balance:
            self = .balance
        case .resetLayout:
            self = .resetLayout
        case .quit:
            self = .quit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pushFocused(let direction):
            try container.encode(CommandName.push, forKey: .command)
            try container.encode(direction, forKey: .direction)
        case .push(let windowID, let direction):
            try container.encode(CommandName.push, forKey: .command)
            try container.encode(windowID.raw, forKey: .windowID)
            try container.encode(direction, forKey: .direction)
        case .center(let windowID):
            try container.encode(CommandName.center, forKey: .command)
            try container.encode(windowID.raw, forKey: .windowID)
        case .eject(let windowID):
            try container.encode(CommandName.eject, forKey: .command)
            try container.encode(windowID.raw, forKey: .windowID)
        case .swapFocused(let direction):
            try container.encode(CommandName.swap, forKey: .command)
            try container.encode(direction, forKey: .direction)
        case .swap(let windowID, let direction):
            try container.encode(CommandName.swap, forKey: .command)
            try container.encode(windowID.raw, forKey: .windowID)
            try container.encode(direction, forKey: .direction)
        case .resizeFocused(let direction, let delta):
            try container.encode(CommandName.resizeSplit, forKey: .command)
            try container.encode(direction, forKey: .direction)
            try container.encode(delta, forKey: .delta)
        case .resize(let windowID, let direction, let delta):
            try container.encode(CommandName.resizeSplit, forKey: .command)
            try container.encode(windowID.raw, forKey: .windowID)
            try container.encode(direction, forKey: .direction)
            try container.encode(delta, forKey: .delta)
        case .focusDirection(let direction):
            try container.encode(CommandName.focusDirection, forKey: .command)
            try container.encode(direction, forKey: .direction)
        case .focusCycle(let direction):
            try container.encode(CommandName.focusCycle, forKey: .command)
            try container.encode(direction, forKey: .direction)
        case .focus(let windowID):
            try container.encode(CommandName.focus, forKey: .command)
            try container.encode(windowID.raw, forKey: .windowID)
        case .toggleFloat(let windowID):
            try container.encode(CommandName.toggleFloat, forKey: .command)
            try container.encode(windowID.raw, forKey: .windowID)
        case .balance:
            try container.encode(CommandName.balance, forKey: .command)
        case .resetLayout:
            try container.encode(CommandName.resetLayout, forKey: .command)
        case .quit:
            try container.encode(CommandName.quit, forKey: .command)
        }
    }

    private static func decodeWindowID(from container: KeyedDecodingContainer<CodingKeys>) throws -> WindowID {
        WindowID(raw: try container.decode(UInt32.self, forKey: .windowID))
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
