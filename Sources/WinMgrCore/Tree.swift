import CoreGraphics

public indirect enum Node: Equatable, Codable, Sendable {
    case void
    case leaf(WindowID)
    case split(Split)
}

public struct Split: Equatable, Codable, Sendable {
    public let axis: Axis
    public let cells: [Cell]

    private init(axis: Axis, cells: [Cell]) {
        self.axis = axis
        self.cells = cells
    }

    public static func create(axis: Axis, cells: [Cell]) -> Result<Split, InvariantError> {
        guard cells.count >= 2 else { return .failure(.splitNeedsAtLeastTwoCells) }
        guard cells.allSatisfy({ $0.weight.isFinite }) else {
            return .failure(.nonFiniteNumber("cell.weight"))
        }
        return .success(Split(axis: axis, cells: cells))
    }

    private enum CodingKeys: String, CodingKey {
        case axis
        case cells
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let axis = try container.decode(Axis.self, forKey: .axis)
        let cells = try container.decode([Cell].self, forKey: .cells)
        switch Split.create(axis: axis, cells: cells) {
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

public struct Cell: Equatable, Codable, Sendable {
    public let weight: Double
    public let node: Node

    private init(weight: Double, node: Node) {
        self.weight = weight
        self.node = node
    }

    public static func create(weight: Double, node: Node) -> Result<Cell, InvariantError> {
        guard weight.isFinite else { return .failure(.nonFiniteNumber("cell.weight")) }
        guard weight > 0 else { return .failure(.cellWeightMustBePositive) }
        return .success(Cell(weight: weight, node: node))
    }

    private enum CodingKeys: String, CodingKey {
        case weight
        case node
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let weight = try container.decode(Double.self, forKey: .weight)
        let node = try container.decode(Node.self, forKey: .node)
        switch Cell.create(weight: weight, node: node) {
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

public enum Axis: String, Codable, CaseIterable, Sendable {
    case horizontal
    case vertical
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case up
    case down

    public var layoutAxisForPush: Axis {
        switch self {
        case .left, .right:
            return .horizontal
        case .up, .down:
            return .vertical
        }
    }

    public var splitLineAxis: Axis {
        switch self {
        case .left, .right:
            return .vertical
        case .up, .down:
            return .horizontal
        }
    }
}

public typealias NodePath = [Int]

public enum SlotOccupancy: Equatable, Sendable {
    case empty
    case occupied(WindowID)
}

public struct TreeSlot: Equatable, Sendable {
    public let path: NodePath
    public let occupancy: SlotOccupancy

    public init(path: NodePath, occupancy: SlotOccupancy) {
        self.path = path
        self.occupancy = occupancy
    }
}
