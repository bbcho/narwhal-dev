import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("MVP tiling core")
struct MVPLayoutTests {
    func frames(
        for tree: Node,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800)
    ) -> [WindowID: CGRect] {
        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: nil
        )
        return layout(
            spaceState: space,
            displayID: display,
            frame: frame,
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        ).tiled
    }

    func tree(for keys: String) -> Node {
        keys.enumerated().reduce(Node.void) { tree, entry in
            let direction: Direction = switch entry.element {
            case "H": .left
            case "L": .right
            case "J": .down
            case "K": .up
            default: preconditionFailure("Unsupported layout key \(entry.element)")
            }
            return pushIntoTree(WindowID(raw: CGWindowID(entry.offset + 1)), direction, tree)
        }
    }

    func generatedDirectionSequences(length: Int) -> [[Direction]] {
        guard length > 0 else { return [[]] }
        let directions: [Direction] = [.left, .right, .up, .down]
        return (0..<length).reduce([[]]) { sequences, _ in
            sequences.flatMap { sequence in
                directions.map { sequence + [$0] }
            }
        }
    }

    func requireValidPartition(_ rects: [CGRect], in frame: CGRect, context: String) throws {
        let tolerance: CGFloat = 0.5
        guard !rects.isEmpty else {
            throw TestFailure("Expected non-empty partition for \(context)")
        }
        for rect in rects {
            guard rect.width > 0,
                  rect.height > 0,
                  rect.minX >= frame.minX - tolerance,
                  rect.minY >= frame.minY - tolerance,
                  rect.maxX <= frame.maxX + tolerance,
                  rect.maxY <= frame.maxY + tolerance
            else {
                throw TestFailure("Invalid rect \(rect.debugDescription) in frame \(frame.debugDescription) for \(context)")
            }
        }
        for lhsIndex in rects.indices {
            for rhsIndex in rects.indices where rhsIndex > lhsIndex {
                let overlap = rects[lhsIndex].intersection(rects[rhsIndex])
                guard overlap.isNull || overlap.width <= tolerance || overlap.height <= tolerance else {
                    throw TestFailure(
                        "Overlapping rects \(rects[lhsIndex].debugDescription) and \(rects[rhsIndex].debugDescription) for \(context)"
                    )
                }
            }
        }
    }

    func metadata(
        for window: WindowID,
        bundleID: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        isResizable: Bool = true
    ) -> WindowMetadata {
        WindowMetadata(
            id: window,
            bundleID: BundleID(raw: bundleID ?? "com.example.\(window.raw)"),
            title: "Window \(window.raw)",
            role: "AXWindow",
            pid: 42,
            frame: frame,
            isResizable: isResizable,
            isMinimized: false
        )
    }

    func display(_ id: DisplayID, x: Double, width: Double) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: Int(id.raw),
            fingerprint: nil,
            frame: CGRect(x: x, y: 0, width: width, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: width, height: 800)
        )
    }

    func generatedDirectionSequences(maxLength: Int) -> [[Direction]] {
        var result: [[Direction]] = [[]]
        var current: [[Direction]] = [[]]

        for _ in 0..<maxLength {
            current = current.flatMap { sequence in
                Direction.allCases.map { sequence + [$0] }
            }
            result.append(contentsOf: current)
        }

        return result
    }

    func isFiniteNonNegativeRect(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 0
            && rect.height >= 0
    }

    func rectsArePairwiseDisjoint(_ rects: [CGRect]) -> Bool {
        for firstIndex in rects.indices {
            for secondIndex in rects.indices where secondIndex > firstIndex {
                if overlapArea(rects[firstIndex], rects[secondIndex]) > 0.0001 {
                    return false
                }
            }
        }

        return true
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        guard !overlap.isNull && !overlap.isInfinite else { return 0 }
        return max(0, overlap.width) * max(0, overlap.height)
    }

    func cell(weight: Double, node: Node) throws -> Cell {
        switch Cell.create(weight: weight, node: node) {
        case .success(let cell):
            return cell
        case .failure(let error):
            throw error
        }
    }

    func split(axis: Axis, cells: [Cell]) throws -> Split {
        switch Split.create(axis: axis, cells: cells) {
        case .success(let split):
            return split
        case .failure(let error):
            throw error
        }
    }

    func requireWorld(_ result: Result<World, CommandError>, _ message: String) throws -> World {
        try requireSuccess(result, message, describeError: \.message)
    }

    func requireSpace(_ world: World, _ spaceID: SpaceID, _ message: String) throws -> SpaceState {
        guard let space = world.spaces[spaceID] else {
            #expect(Bool(false), "\(message)")
            throw TestAbort()
        }
        return space
    }

    func requireLayout(_ result: Result<Layout, UnsatisfiableLayout>, _ message: String) throws -> Layout {
        try requireSuccess(result, message)
    }

    func requireSuccess<Success, Failure: Error>(
        _ result: Result<Success, Failure>,
        _ message: String,
        describeError: (Failure) -> String = { String(describing: $0) }
    ) throws -> Success {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            #expect(Bool(false), "\(message): \(describeError(error))")
            throw error
        }
    }

    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    struct TestAbort: Error {}
    private struct TestFailure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }
}
