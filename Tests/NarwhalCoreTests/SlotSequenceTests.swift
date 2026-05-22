import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("0-6 window slot sequences")
struct SlotSequenceTests {
    @Test("Fresh-window key sequences produce exact slots and AX frames")
    func freshWindowSequencesProduceExactSlotsAndFrames() {
        for expectation in expectations() {
            let tree = treeFor(expectation.keys)
            let actualSlots = slots(in: tree)
            let actualFrames = framesFor(tree)

            #expect(
                actualSlots == expectation.slots,
                "\(displayName(expectation.keys)) slots expected \(render(expectation.slots)) got \(render(actualSlots))"
            )
            #expect(
                actualFrames == expectation.frames,
                "\(displayName(expectation.keys)) frames expected \(render(expectation.frames)) got \(render(actualFrames))"
            )
        }
    }

    @Test("All fresh-window sequences through six windows preserve slot invariants")
    func freshWindowSequencesThroughSixWindowsPreserveInvariants() {
        let sequences = keySequences(maxLength: 6)
        #expect(sequences.count == 5_461)

        for keys in sequences {
            let tree = treeFor(keys)
            let treeSlots = slots(in: tree)
            let occupied = occupiedWindows(in: tree)
            let expectedWindows = expectedWindowIDs(count: keys.count)
            let frames = framesFor(tree)
            let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
            let slotFrames = framesBySlot(for: tree, frame: display)

            #expect(Set(occupied) == Set(expectedWindows))
            #expect(Set(occupied).count == expectedWindows.count)
            #expect(frames.keys.sorted { $0.raw < $1.raw } == expectedWindows)
            #expect(treeSlots.count >= max(1, expectedWindows.count))
            #expect(slotFrames.map(\.slot) == treeSlots)
            #expect(frames.values.allSatisfy { display.contains($0) })
            #expect(slotFrames.map(\.frame).allSatisfy { display.contains($0) })
            #expect(rectsArePairwiseDisjoint(Array(frames.values)))
            #expect(rectsArePairwiseDisjoint(slotFrames.map(\.frame)))
            let coveredArea = slotFrames.map { $0.frame.width * $0.frame.height }.reduce(0, +)
            let displayArea = display.width * display.height
            #expect(abs(coveredArea - displayArea) < 0.0001)
        }
    }

    @Test("Vertical row realms match FancyZones row ordering")
    func verticalRowRealmsMatchFancyZonesOrdering() {
        expectSketch("KKK", [
            "A C B",
            ". . ."
        ])
        expectSketch("JJJ", [
            ". . .",
            "A C B"
        ])
        expectSketch("KKJJ", [
            "A B",
            "C D"
        ])
        expectSketch("KKKJJJ", [
            "A C B",
            "D F E"
        ])
        expectSketch("KJKJKJ", [
            "A E C",
            "B F D"
        ])
    }

    @Test("Horizontal lane realms keep accepted ordering")
    func horizontalLaneRealmsKeepAcceptedOrdering() {
        expectSketch("HLHLHL", [
            "A A B B",
            "C E F D"
        ])
        expectSketch("HHHLLL", [
            "A A D D",
            "B C F E"
        ])
    }

    private func expectations() -> [SequenceExpectation] {
        [
            SequenceExpectation(keys: "", slots: [.slot([], .empty)], frames: [:]),
            SequenceExpectation(keys: "H", slots: [.slot([0], .occupied(.a)), .slot([1], .empty)], frames: [
                .a: rect(0, 0, 600, 800)
            ]),
            SequenceExpectation(keys: "L", slots: [.slot([0], .empty), .slot([1], .occupied(.a))], frames: [
                .a: rect(600, 0, 600, 800)
            ]),
            SequenceExpectation(keys: "J", slots: [.slot([0], .empty), .slot([1], .occupied(.a))], frames: [
                .a: rect(0, 400, 1200, 400)
            ]),
            SequenceExpectation(keys: "K", slots: [.slot([0], .occupied(.a)), .slot([1], .empty)], frames: [
                .a: rect(0, 0, 1200, 400)
            ]),
            SequenceExpectation(keys: "HH", slots: [
                .slot([0, 0], .occupied(.a)), .slot([0, 1], .occupied(.b)), .slot([1], .empty)
            ], frames: [.a: rect(0, 0, 600, 400), .b: rect(0, 400, 600, 400)]),
            SequenceExpectation(keys: "HL", slots: [.slot([0], .occupied(.a)), .slot([1], .occupied(.b))], frames: [
                .a: rect(0, 0, 600, 800), .b: rect(600, 0, 600, 800)
            ]),
            SequenceExpectation(keys: "HJ", slots: [
                .slot([0], .occupied(.a)), .slot([1, 0], .empty), .slot([1, 1], .occupied(.b)), .slot([2], .empty)
            ], frames: [.a: rect(0, 0, 400, 800), .b: rect(400, 400, 400, 400)]),
            SequenceExpectation(keys: "HK", slots: [
                .slot([0], .occupied(.a)), .slot([1, 0], .occupied(.b)), .slot([1, 1], .empty), .slot([2], .empty)
            ], frames: [.a: rect(0, 0, 400, 800), .b: rect(400, 0, 400, 400)]),
            SequenceExpectation(keys: "LH", slots: [.slot([0], .occupied(.b)), .slot([1], .occupied(.a))], frames: [
                .a: rect(600, 0, 600, 800), .b: rect(0, 0, 600, 800)
            ]),
            SequenceExpectation(keys: "LL", slots: [
                .slot([0], .empty), .slot([1, 0], .occupied(.a)), .slot([1, 1], .occupied(.b))
            ], frames: [.a: rect(600, 0, 600, 400), .b: rect(600, 400, 600, 400)]),
            SequenceExpectation(keys: "LJ", slots: [
                .slot([0], .empty), .slot([1, 0], .empty), .slot([1, 1], .occupied(.b)), .slot([2], .occupied(.a))
            ], frames: [.a: rect(800, 0, 400, 800), .b: rect(400, 400, 400, 400)]),
            SequenceExpectation(keys: "LK", slots: [
                .slot([0], .empty), .slot([1, 0], .occupied(.b)), .slot([1, 1], .empty), .slot([2], .occupied(.a))
            ], frames: [.a: rect(800, 0, 400, 800), .b: rect(400, 0, 400, 400)]),
            SequenceExpectation(keys: "JH", slots: [
                .slot([0], .empty), .slot([1, 0], .occupied(.b)), .slot([1, 1], .empty), .slot([2], .occupied(.a))
            ], frames: [.a: rect(0, lastThirdY, 1200, lastThirdHeight), .b: rect(0, firstThirdHeight, 600, firstThirdHeight)]),
            SequenceExpectation(keys: "JL", slots: [
                .slot([0], .empty), .slot([1, 0], .empty), .slot([1, 1], .occupied(.b)), .slot([2], .occupied(.a))
            ], frames: [.a: rect(0, lastThirdY, 1200, lastThirdHeight), .b: rect(600, firstThirdHeight, 600, firstThirdHeight)]),
            SequenceExpectation(keys: "JJ", slots: [
                .slot([0], .empty), .slot([1, 0], .occupied(.a)), .slot([1, 1], .occupied(.b))
            ], frames: [.a: rect(0, 400, 600, 400), .b: rect(600, 400, 600, 400)]),
            SequenceExpectation(keys: "JK", slots: [.slot([0], .occupied(.b)), .slot([1], .occupied(.a))], frames: [
                .a: rect(0, 400, 1200, 400), .b: rect(0, 0, 1200, 400)
            ]),
            SequenceExpectation(keys: "KH", slots: [
                .slot([0], .occupied(.a)), .slot([1, 0], .occupied(.b)), .slot([1, 1], .empty), .slot([2], .empty)
            ], frames: [.a: rect(0, 0, 1200, firstThirdHeight), .b: rect(0, firstThirdHeight, 600, firstThirdHeight)]),
            SequenceExpectation(keys: "KL", slots: [
                .slot([0], .occupied(.a)), .slot([1, 0], .empty), .slot([1, 1], .occupied(.b)), .slot([2], .empty)
            ], frames: [.a: rect(0, 0, 1200, firstThirdHeight), .b: rect(600, firstThirdHeight, 600, firstThirdHeight)]),
            SequenceExpectation(keys: "KJ", slots: [.slot([0], .occupied(.a)), .slot([1], .occupied(.b))], frames: [
                .a: rect(0, 0, 1200, 400), .b: rect(0, 400, 1200, 400)
            ]),
            SequenceExpectation(keys: "KK", slots: [
                .slot([0, 0], .occupied(.a)), .slot([0, 1], .occupied(.b)), .slot([1], .empty)
            ], frames: [.a: rect(0, 0, 600, 400), .b: rect(600, 0, 600, 400)])
        ]
    }

    private func treeFor(_ keys: String) -> Node {
        Array(keys).enumerated().reduce(Node.void) { tree, entry in
            pushIntoTree(WindowID(raw: CGWindowID(entry.offset + 1)), direction(for: entry.element), tree)
        }
    }

    private func keySequences(maxLength: Int) -> [String] {
        var result = [""]
        var current = [""]
        for _ in 0..<maxLength {
            current = current.flatMap { prefix in
                ["H", "L", "J", "K"].map { prefix + $0 }
            }
            result.append(contentsOf: current)
        }
        return result
    }

    private func expectedWindowIDs(count: Int) -> [WindowID] {
        guard count > 0 else { return [] }
        return (1...count).map { WindowID(raw: CGWindowID($0)) }
    }

    private func framesFor(_ tree: Node) -> [WindowID: CGRect] {
        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: nil
        )
        return layout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        ).tiled
    }

    private func direction(for key: Character) -> Direction {
        switch key {
        case "H":
            return .left
        case "L":
            return .right
        case "J":
            return .down
        case "K":
            return .up
        default:
            preconditionFailure("Unsupported test key \(key)")
        }
    }

    private func framesBySlot(for node: Node, frame: CGRect) -> [SlotFrame] {
        framesBySlot(for: node, frame: frame, path: [])
    }

    private func expectSketch(_ keys: String, _ expectedRows: [String]) {
        let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let actual = sketch(framesBySlot(for: treeFor(keys), frame: display))
        let expected = expectedRows.joined(separator: " / ")
        #expect(actual == expected, "\(keys) sketch expected \(expected) got \(actual)")
    }

    private func sketch(_ slotFrames: [SlotFrame]) -> String {
        let xs = sortedUnique(slotFrames.flatMap { [$0.frame.minX, $0.frame.maxX] })
        let ys = sortedUnique(slotFrames.flatMap { [$0.frame.minY, $0.frame.maxY] })
        guard xs.count > 1, ys.count > 1 else {
            return label(slotFrames.first?.slot.occupancy ?? .empty)
        }

        return (0..<(ys.count - 1)).map { row in
            (0..<(xs.count - 1)).map { column in
                let point = CGPoint(
                    x: (xs[column] + xs[column + 1]) / 2.0,
                    y: (ys[row] + ys[row + 1]) / 2.0
                )
                return label(slotFrames.first { $0.frame.contains(point) }?.slot.occupancy ?? .empty)
            }.joined(separator: " ")
        }.joined(separator: " / ")
    }

    private func sortedUnique(_ values: [CGFloat]) -> [CGFloat] {
        values.sorted().reduce(into: []) { result, value in
            guard result.last.map({ abs($0 - value) < 0.0001 }) != true else { return }
            result.append(value)
        }
    }

    private func label(_ occupancy: SlotOccupancy) -> String {
        switch occupancy {
        case .empty:
            return "."
        case .occupied(let windowID):
            return render(windowID)
        }
    }

    private func framesBySlot(for node: Node, frame: CGRect, path: NodePath) -> [SlotFrame] {
        switch node {
        case .void:
            return [SlotFrame(slot: TreeSlot(path: path, occupancy: .empty), frame: frame)]
        case .leaf(let windowID):
            return [SlotFrame(slot: TreeSlot(path: path, occupancy: .occupied(windowID)), frame: frame)]
        case .split(let split):
            return zip(split.cells, splitFrames(frame, axis: split.axis, weights: split.cells.map(\.weight)))
                .enumerated()
                .flatMap { index, pair in
                    framesBySlot(for: pair.0.node, frame: pair.1, path: path + [index])
                }
        }
    }

    private func splitFrames(_ frame: CGRect, axis: Axis, weights: [Double]) -> [CGRect] {
        let total = weights.reduce(0, +)
        var offset: CGFloat = 0
        return weights.enumerated().map { index, weight in
            let isLast = index == weights.count - 1
            switch axis {
            case .horizontal:
                let width = isLast ? frame.width - offset : frame.width * CGFloat(weight / total)
                defer { offset += width }
                return CGRect(x: frame.minX + offset, y: frame.minY, width: width, height: frame.height)
            case .vertical:
                let height = isLast ? frame.height - offset : frame.height * CGFloat(weight / total)
                defer { offset += height }
                return CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: height)
            }
        }
    }

    private func rectsArePairwiseDisjoint(_ rects: [CGRect]) -> Bool {
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

    private var firstThirdHeight: Double {
        800.0 * (1.0 / 3.0)
    }

    private var lastThirdY: Double {
        firstThirdHeight + firstThirdHeight
    }

    private var lastThirdHeight: Double {
        800.0 - lastThirdY
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    private func displayName(_ keys: String) -> String {
        keys.isEmpty ? "<empty>" : keys
    }

    private func render(_ slots: [TreeSlot]) -> String {
        slots.map { slot in
            "\(slot.path.map(String.init).joined(separator: ".")):\(render(slot.occupancy))"
        }.joined(separator: " ")
    }

    private func render(_ occupancy: SlotOccupancy) -> String {
        switch occupancy {
        case .empty:
            return "void"
        case .occupied(let windowID):
            return render(windowID)
        }
    }

    private func render(_ frames: [WindowID: CGRect]) -> String {
        frames.keys.sorted { $0.raw < $1.raw }.map { windowID in
            "\(render(windowID))=\(render(frames[windowID]!))"
        }.joined(separator: " ")
    }

    private func render(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)))"
    }

    private func render(_ windowID: WindowID) -> String {
        switch windowID.raw {
        case 1:
            return "A"
        case 2:
            return "B"
        case 3:
            return "C"
        case 4:
            return "D"
        case 5:
            return "E"
        case 6:
            return "F"
        default:
            return "W\(windowID.raw)"
        }
    }
}

private struct SequenceExpectation {
    let keys: String
    let slots: [TreeSlot]
    let frames: [WindowID: CGRect]
}

private struct SlotFrame: Equatable {
    let slot: TreeSlot
    let frame: CGRect
}

private extension TreeSlot {
    static func slot(_ path: NodePath, _ occupancy: SlotOccupancy) -> TreeSlot {
        TreeSlot(path: path, occupancy: occupancy)
    }
}

private extension WindowID {
    static let a = WindowID(raw: 1)
    static let b = WindowID(raw: 2)
}
