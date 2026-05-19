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
    case show(FocusBorderTarget)
    case hide
}

public struct FocusBorderTarget: Equatable, Sendable {
    public let windowID: WindowID
    public let frame: CGRect
    public let cornerRadius: Double

    public init(windowID: WindowID, frame: CGRect, cornerRadius: Double) {
        self.windowID = windowID
        self.frame = frame
        self.cornerRadius = max(0, cornerRadius)
    }

    public init(windowID: WindowID, frame: CGRect, traits: FocusBorderWindowTraits) {
        self.init(
            windowID: windowID,
            frame: frame,
            cornerRadius: focusBorderCornerRadius(frame: frame, traits: traits)
        )
    }

    public init(window: WindowMetadata, frame: CGRect, subrole: String = "", isFullscreen: Bool = false) {
        self.init(
            windowID: window.id,
            frame: frame,
            traits: FocusBorderWindowTraits(
                role: window.role,
                subrole: subrole,
                isResizable: window.isResizable,
                isFullscreen: isFullscreen
            )
        )
    }
}

public struct FocusBorderWindowTraits: Equatable, Sendable {
    public let role: String
    public let subrole: String
    public let isResizable: Bool
    public let isFullscreen: Bool

    public init(role: String, subrole: String, isResizable: Bool, isFullscreen: Bool) {
        self.role = role
        self.subrole = subrole
        self.isResizable = isResizable
        self.isFullscreen = isFullscreen
    }

    public static let standard = FocusBorderWindowTraits(
        role: "AXWindow",
        subrole: "AXStandardWindow",
        isResizable: true,
        isFullscreen: false
    )
}

public func focusBorderCornerRadius(frame: CGRect, traits: FocusBorderWindowTraits) -> Double {
    let minDimension = max(0, min(Double(frame.width), Double(frame.height)))
    guard minDimension > 0, !traits.isFullscreen else {
        return 0
    }

    return min(preferredFocusBorderCornerRadius(traits: traits, minDimension: minDimension), minDimension / 2)
}

private func preferredFocusBorderCornerRadius(traits: FocusBorderWindowTraits, minDimension: Double) -> Double {
    let role = traits.role.lowercased()
    let subrole = traits.subrole.lowercased()
    let descriptor = "\(role) \(subrole)"

    let baseRadius: Double
    if descriptor.contains("sheet") || descriptor.contains("dialog") || descriptor.contains("alert") {
        baseRadius = 13
    } else if descriptor.contains("floating")
        || descriptor.contains("popover")
        || descriptor.contains("drawer")
        || descriptor.contains("utility") {
        baseRadius = 10
    } else if !traits.isResizable {
        baseRadius = 11
    } else {
        baseRadius = 15
    }

    if minDimension < 160 {
        return min(baseRadius, 8)
    }
    if minDimension < 320, baseRadius >= 15 {
        return min(baseRadius, 10)
    }
    return baseRadius
}

public enum ConfigStatus: Equatable, Sendable {
    case loaded
    case failed(String)
}
