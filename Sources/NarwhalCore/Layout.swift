import CoreGraphics

public struct Layout: Equatable, Sendable {
    public let tiled: [WindowID: CGRect]
    public let floatingZOrder: [WindowID]
    public let hidden: Set<WindowID>

    public init(tiled: [WindowID: CGRect], floatingZOrder: [WindowID], hidden: Set<WindowID>) {
        self.tiled = tiled
        self.floatingZOrder = floatingZOrder
        self.hidden = hidden
    }
}

public struct LayoutDelta: Equatable, Sendable {
    public let moves: [WindowID: CGRect]
    public let raises: [WindowID]
    public let hides: Set<WindowID>
    public let shows: Set<WindowID>

    public init(moves: [WindowID: CGRect], raises: [WindowID], hides: Set<WindowID>, shows: Set<WindowID>) {
        self.moves = moves
        self.raises = raises
        self.hides = hides
        self.shows = shows
    }
}

public struct LayoutGeneration: Hashable, Codable, Sendable {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }
}

public struct DesiredLayout: Equatable, Sendable {
    public let generation: LayoutGeneration
    public let layout: Layout
    public let delta: LayoutDelta

    public init(generation: LayoutGeneration, layout: Layout, delta: LayoutDelta) {
        self.generation = generation
        self.layout = layout
        self.delta = delta
    }
}

public struct CommandEffects: Equatable, Sendable {
    public let desiredLayout: DesiredLayout?
    public let focus: WindowID?
    public let raises: [WindowID]
    public let focusBorder: FocusBorderEffect?
    public let persistRestore: Bool
    public let configChanged: Config?

    public init(
        desiredLayout: DesiredLayout?,
        focus: WindowID?,
        raises: [WindowID],
        focusBorder: FocusBorderEffect?,
        persistRestore: Bool,
        configChanged: Config?
    ) {
        self.desiredLayout = desiredLayout
        self.focus = focus
        self.raises = raises
        self.focusBorder = focusBorder
        self.persistRestore = persistRestore
        self.configChanged = configChanged
    }

    public static let none = CommandEffects(
        desiredLayout: nil,
        focus: nil,
        raises: [],
        focusBorder: nil,
        persistRestore: false,
        configChanged: nil
    )
}

public enum FocusBorderEffect: Equatable, Sendable {
    case show(WindowID, CGRect)
    case hide
}

public enum ConfigStatus: Equatable, Sendable {
    case loaded
    case failed(String)
}
