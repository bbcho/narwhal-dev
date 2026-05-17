import CoreGraphics

public struct StoredWindowRef: Hashable, Codable, Sendable {
    public let bundleID: BundleID
    public let title: String
    public let role: String
    public let occurrence: Int
    public let lastKnownFrame: CGRect?

    public init(
        bundleID: BundleID,
        title: String,
        role: String,
        occurrence: Int,
        lastKnownFrame: CGRect?
    ) {
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.occurrence = occurrence
        self.lastKnownFrame = lastKnownFrame
    }
}

public indirect enum StoredNode: Equatable, Codable, Sendable {
    case void
    case leaf(StoredWindowRef)
    case split(StoredSplit)
}

public struct StoredSplit: Equatable, Codable, Sendable {
    public let axis: Axis
    public let cells: [StoredCell]

    private init(axis: Axis, cells: [StoredCell]) {
        self.axis = axis
        self.cells = cells
    }

    public static func create(axis: Axis, cells: [StoredCell]) -> Result<StoredSplit, InvariantError> {
        guard cells.count >= 2 else { return .failure(.splitNeedsAtLeastTwoCells) }
        guard cells.allSatisfy({ $0.weight.isFinite }) else {
            return .failure(.nonFiniteNumber("storedCell.weight"))
        }
        return .success(StoredSplit(axis: axis, cells: cells))
    }

    private enum CodingKeys: String, CodingKey {
        case axis
        case cells
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let axis = try container.decode(Axis.self, forKey: .axis)
        let cells = try container.decode([StoredCell].self, forKey: .cells)
        switch StoredSplit.create(axis: axis, cells: cells) {
        case .success(let split):
            self = split
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .cells,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }
}

public struct StoredCell: Equatable, Codable, Sendable {
    public let weight: Double
    public let node: StoredNode

    private init(weight: Double, node: StoredNode) {
        self.weight = weight
        self.node = node
    }

    public static func create(weight: Double, node: StoredNode) -> Result<StoredCell, InvariantError> {
        guard weight.isFinite else { return .failure(.nonFiniteNumber("storedCell.weight")) }
        guard weight > 0 else { return .failure(.cellWeightMustBePositive) }
        return .success(StoredCell(weight: weight, node: node))
    }

    private enum CodingKeys: String, CodingKey {
        case weight
        case node
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let weight = try container.decode(Double.self, forKey: .weight)
        let node = try container.decode(StoredNode.self, forKey: .node)
        switch StoredCell.create(weight: weight, node: node) {
        case .success(let cell):
            self = cell
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .weight,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }
}

public struct StoredDisplayLayout: Equatable, Codable, Sendable {
    public let displaySlot: Int
    public let displayFingerprint: String?
    public let tree: StoredNode
    public let floating: [StoredWindowRef]

    public init(displaySlot: Int, displayFingerprint: String?, tree: StoredNode, floating: [StoredWindowRef]) {
        self.displaySlot = displaySlot
        self.displayFingerprint = displayFingerprint
        self.tree = tree
        self.floating = floating
    }
}

public struct StoredSpace: Equatable, Codable, Sendable {
    public let layouts: [StoredDisplayLayout]
    public let focused: StoredWindowRef?

    public init(layouts: [StoredDisplayLayout], focused: StoredWindowRef?) {
        self.layouts = layouts
        self.focused = focused
    }
}

public struct StoredPendingRule: Equatable, Codable, Sendable {
    public let window: StoredWindowRef
    public let action: StoredRuleAction

    public init(window: StoredWindowRef, action: StoredRuleAction) {
        self.window = window
        self.action = action
    }
}

public enum StoredRuleAction: Equatable, Codable, Sendable {
    case forceFloat
    case ignore
    case pinToDisplay(displaySlot: Int)
}

public struct StoredWorld: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = StoredWorld(schemaVersion: currentSchemaVersion, activeSpace: nil, pendingRules: [])

    public let schemaVersion: Int
    public let activeSpace: StoredSpace?
    public let pendingRules: [StoredPendingRule]

    public init(schemaVersion: Int, activeSpace: StoredSpace?, pendingRules: [StoredPendingRule]) {
        self.schemaVersion = schemaVersion
        self.activeSpace = activeSpace
        self.pendingRules = pendingRules
    }
}

public func validateStoredWorld(_ stored: StoredWorld) -> Result<StoredWorld, RestoreError> {
    guard stored.schemaVersion == StoredWorld.currentSchemaVersion else {
        return .failure(.invalidStoredWorld("unsupported schemaVersion \(stored.schemaVersion)"))
    }

    for ref in stored.allWindowRefs {
        guard ref.occurrence >= 0 else {
            return .failure(.invalidStoredWorld("StoredWindowRef.occurrence must be non-negative"))
        }
        if let frame = ref.lastKnownFrame, frame.hasNonFiniteCoordinate {
            return .failure(.invalidStoredWorld("StoredWindowRef.lastKnownFrame must be finite"))
        }
    }

    return .success(stored)
}

private extension StoredWorld {
    var allWindowRefs: [StoredWindowRef] {
        var refs: [StoredWindowRef] = []
        if let activeSpace {
            for layout in activeSpace.layouts {
                refs.append(contentsOf: layout.tree.windowRefs)
                refs.append(contentsOf: layout.floating)
            }
            if let focused = activeSpace.focused {
                refs.append(focused)
            }
        }
        refs.append(contentsOf: pendingRules.map(\.window))
        return refs
    }
}

private extension StoredNode {
    var windowRefs: [StoredWindowRef] {
        switch self {
        case .void:
            return []
        case .leaf(let ref):
            return [ref]
        case .split(let split):
            return split.cells.flatMap { $0.node.windowRefs }
        }
    }
}

private extension CGRect {
    var hasNonFiniteCoordinate: Bool {
        [origin.x, origin.y, size.width, size.height].contains { !$0.isFinite }
    }
}
