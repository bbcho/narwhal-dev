import CoreGraphics

public struct WindowMetadata: Equatable, Codable, Sendable {
    public let id: WindowID
    public let bundleID: BundleID
    public let title: String
    public let role: String
    public let pid: ProcessID
    public let frame: CGRect
    public let isResizable: Bool
    public let isMinimized: Bool

    public init(
        id: WindowID,
        bundleID: BundleID,
        title: String,
        role: String,
        pid: ProcessID,
        frame: CGRect,
        isResizable: Bool,
        isMinimized: Bool
    ) {
        self.id = id
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.pid = pid
        self.frame = frame
        self.isResizable = isResizable
        self.isMinimized = isMinimized
    }
}

public struct DisplaySpaceState: Equatable, Codable, Sendable {
    public let displayID: DisplayID
    public let tree: Node
    public let floating: [WindowID]

    public init(displayID: DisplayID, tree: Node, floating: [WindowID]) {
        self.displayID = displayID
        self.tree = tree
        self.floating = floating
    }
}

public struct SpaceState: Equatable, Codable, Sendable {
    public let id: SpaceID
    public let displays: [DisplayID: DisplaySpaceState]
    public let focused: WindowID?

    public init(id: SpaceID, displays: [DisplayID: DisplaySpaceState], focused: WindowID?) {
        self.id = id
        self.displays = displays
        self.focused = focused
    }
}

public struct DisplayInfo: Equatable, Codable, Sendable {
    public let id: DisplayID
    public let slot: Int
    public let fingerprint: String?
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(
        id: DisplayID,
        slot: Int,
        fingerprint: String?,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.id = id
        self.slot = slot
        self.fingerprint = fingerprint
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum SpaceTopologyQuality: String, Equatable, Codable, Sendable {
    case managedDisplaySpaces
    case replicatedActiveSpace
    case unavailable
}

public struct SpaceTopology: Equatable, Codable, Sendable {
    public let activeSpaceByDisplay: [DisplayID: SpaceID]
    public let windowSpace: [WindowID: SpaceID]
    public let quality: SpaceTopologyQuality

    public init(
        activeSpaceByDisplay: [DisplayID: SpaceID],
        windowSpace: [WindowID: SpaceID],
        quality: SpaceTopologyQuality
    ) {
        self.activeSpaceByDisplay = activeSpaceByDisplay
        self.windowSpace = windowSpace
        self.quality = quality
    }

    public static func replicated(activeSpace: SpaceID?, displays: [DisplayID: DisplayInfo]) -> SpaceTopology {
        guard let activeSpace else {
            return SpaceTopology(activeSpaceByDisplay: [:], windowSpace: [:], quality: .unavailable)
        }
        return SpaceTopology(
            activeSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.keys.map { ($0, activeSpace) }),
            windowSpace: [:],
            quality: .replicatedActiveSpace
        )
    }

    public var primaryActiveSpace: SpaceID? {
        activeSpaceByDisplay.values.sorted { $0.raw < $1.raw }.first
    }
}

public struct World: Equatable, Sendable {
    public let displays: [DisplayID: DisplayInfo]
    public let activeSpace: SpaceID?
    public let activeSpaceByDisplay: [DisplayID: SpaceID]
    public let spaces: [SpaceID: SpaceState]
    public let windows: [WindowID: WindowMetadata]
    public let windowDisplay: [WindowID: DisplayID]
    public let windowSpace: [WindowID: SpaceID]
    public let windowConstraints: [WindowID: WindowConstraints]
    public let pendingRules: [WindowID: RuleAction]
    public let config: Config

    public init(
        displays: [DisplayID: DisplayInfo],
        activeSpace: SpaceID?,
        activeSpaceByDisplay: [DisplayID: SpaceID]? = nil,
        spaces: [SpaceID: SpaceState],
        windows: [WindowID: WindowMetadata],
        windowDisplay: [WindowID: DisplayID],
        windowSpace: [WindowID: SpaceID] = [:],
        windowConstraints: [WindowID: WindowConstraints],
        pendingRules: [WindowID: RuleAction],
        config: Config
    ) {
        self.displays = displays
        self.activeSpace = activeSpace
        if let activeSpaceByDisplay {
            self.activeSpaceByDisplay = activeSpaceByDisplay
        } else if let activeSpace {
            self.activeSpaceByDisplay = Dictionary(uniqueKeysWithValues: displays.keys.map { ($0, activeSpace) })
        } else {
            self.activeSpaceByDisplay = [:]
        }
        self.spaces = spaces
        self.windows = windows
        self.windowDisplay = windowDisplay
        self.windowSpace = windowSpace
        self.windowConstraints = windowConstraints
        self.pendingRules = pendingRules
        self.config = config
    }

    public static let empty = World(
        displays: [:],
        activeSpace: nil,
        activeSpaceByDisplay: [:],
        spaces: [:],
        windows: [:],
        windowDisplay: [:],
        windowSpace: [:],
        windowConstraints: [:],
        pendingRules: [:],
        config: .default
    )
}

public enum AXSnapshotQuality: Equatable, Sendable {
    case complete
    case partial([AXWindowReadError])
    case permissionDenied(String)
}

public struct AXWindowReadError: Equatable, Sendable {
    public let windowID: WindowID?
    public let pid: ProcessID?
    public let message: String

    public init(windowID: WindowID?, pid: ProcessID?, message: String) {
        self.windowID = windowID
        self.pid = pid
        self.message = message
    }
}

public struct AXWindowSnapshot: Equatable, Sendable {
    public let windows: [WindowMetadata]
    public let quality: AXSnapshotQuality

    public init(windows: [WindowMetadata], quality: AXSnapshotQuality) {
        self.windows = windows
        self.quality = quality
    }
}

public struct EnvironmentSnapshot: Equatable, Sendable {
    public let activeSpace: SpaceID?
    public let activeSpaceByDisplay: [DisplayID: SpaceID]
    public let displays: [DisplayID: DisplayInfo]
    public let axSnapshot: AXWindowSnapshot
    public let windowSpace: [WindowID: SpaceID]
    public let topologyQuality: SpaceTopologyQuality
    public let preserveSpaceLayouts: Bool

    public init(
        activeSpace: SpaceID?,
        displays: [DisplayID: DisplayInfo],
        axSnapshot: AXWindowSnapshot,
        spaceTopology: SpaceTopology? = nil,
        preserveSpaceLayouts: Bool = false
    ) {
        let topology = spaceTopology ?? SpaceTopology.replicated(activeSpace: activeSpace, displays: displays)
        self.activeSpace = activeSpace
        self.activeSpaceByDisplay = topology.activeSpaceByDisplay
        self.displays = displays
        self.axSnapshot = axSnapshot
        self.windowSpace = topology.windowSpace
        self.topologyQuality = topology.quality
        self.preserveSpaceLayouts = preserveSpaceLayouts
    }
}

public enum StartupError: Error, Equatable, Sendable {
    case axSnapshotUnavailable(AXSnapshotQuality)
}
