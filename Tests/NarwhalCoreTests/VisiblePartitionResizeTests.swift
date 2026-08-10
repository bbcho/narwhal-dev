import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Visible partition resize")
struct VisiblePartitionResizeTests {
    private let rootFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    private let innerGap = 8.0
    private let topLeft = WindowID(raw: 1)
    private let topRight = WindowID(raw: 2)
    private let bottomLeft = WindowID(raw: 3)
    private let bottomRight = WindowID(raw: 4)

    @Test("Bottom-row seam resize rotates a column-root tree without moving the top row")
    func bottomSeamIsLocalAcrossColumnRootTopology() throws {
        let tree = try columnRootTree()
        let before = renderedFrames(tree)
        let oldSource = try #require(before[bottomLeft])
        let requestedSource = CGRect(
            x: oldSource.minX,
            y: oldSource.minY,
            width: oldSource.width + 120,
            height: oldSource.height
        )

        let resized = try resizeVisibleSeamInTree(
            bottomLeft,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[topLeft] == before[topLeft])
        #expect(after[topRight] == before[topRight])
        #expect(after[bottomLeft] == requestedSource)
        #expect(after[bottomRight] == CGRect(x: 724, y: 404, width: 472, height: 392))
        guard case .split(let root) = resized else {
            Issue.record("Expected a row-root split after localizing the bottom seam")
            return
        }
        #expect(root.axis == .vertical)
    }

    @Test("Top-row seam resize preserves the bottom row across column-root history")
    func topSeamIsLocalAcrossColumnRootTopology() throws {
        let tree = try columnRootTree()
        let before = renderedFrames(tree)
        let oldSource = try #require(before[topRight])
        let requestedSource = CGRect(
            x: oldSource.minX - 100,
            y: oldSource.minY,
            width: oldSource.width + 100,
            height: oldSource.height
        )

        let resized = try resizeVisibleSeamInTree(
            topRight,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[bottomLeft] == before[bottomLeft])
        #expect(after[bottomRight] == before[bottomRight])
        #expect(after[topLeft] == CGRect(x: 4, y: 4, width: 492, height: 392))
        #expect(after[topRight] == requestedSource)
    }

    @Test("Bottom-row seam resize preserves a compatible row-root topology")
    func bottomSeamStaysLocalInRowRootTopology() throws {
        let tree = try rowRootTree()
        let before = renderedFrames(tree)
        let oldSource = try #require(before[bottomLeft])
        let requestedSource = CGRect(
            x: oldSource.minX,
            y: oldSource.minY,
            width: oldSource.width + 120,
            height: oldSource.height
        )

        let resized = try resizeVisibleSeamInTree(
            bottomLeft,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[topLeft] == before[topLeft])
        #expect(after[topRight] == before[topRight])
        #expect(after[bottomLeft] == requestedSource)
        #expect(after[bottomRight] == CGRect(x: 724, y: 404, width: 472, height: 392))
        guard case .split(let root) = resized else {
            Issue.record("Expected the row-root split to remain representable")
            return
        }
        #expect(root.axis == .vertical)
    }

    @Test("Moving a right window's left edge adjusts only its visible row")
    func leftEdgeResizeUsesOnlyCoincidentNeighbors() throws {
        let tree = try columnRootTree()
        let before = renderedFrames(tree)
        let oldSource = try #require(before[bottomRight])
        let requestedSource = CGRect(
            x: oldSource.minX - 80,
            y: oldSource.minY,
            width: oldSource.width + 80,
            height: oldSource.height
        )

        let resized = try resizeVisibleSeamInTree(
            bottomRight,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[topLeft] == before[topLeft])
        #expect(after[topRight] == before[topRight])
        #expect(after[bottomLeft] == CGRect(x: 4, y: 404, width: 512, height: 392))
        #expect(after[bottomRight] == requestedSource)
    }

    @Test("Left-column horizontal seam resize preserves the right column")
    func horizontalSeamIsLocalAcrossRowRootTopology() throws {
        let tree = try rowRootTree()
        let before = renderedFrames(tree)
        let oldSource = try #require(before[topLeft])
        let requestedSource = CGRect(
            x: oldSource.minX,
            y: oldSource.minY,
            width: oldSource.width,
            height: oldSource.height + 80
        )

        let resized = try resizeVisibleSeamInTree(
            topLeft,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[topRight] == before[topRight])
        #expect(after[bottomRight] == before[bottomRight])
        #expect(after[topLeft] == requestedSource)
        #expect(after[bottomLeft] == CGRect(x: 4, y: 484, width: 592, height: 312))
        guard case .split(let root) = resized else {
            Issue.record("Expected a column-root split after localizing the left seam")
            return
        }
        #expect(root.axis == .horizontal)
    }

    @Test("A spanning source adjusts every directly adjacent neighbor")
    func spanningSourceMovesAllCoincidentNeighbors() throws {
        let source = WindowID(raw: 10)
        let upperNeighbor = WindowID(raw: 11)
        let lowerNeighbor = WindowID(raw: 12)
        let tree = Node.split(try split(.horizontal, [
            try cell(.leaf(source)),
            try cell(.split(try split(.vertical, [
                try cell(.leaf(upperNeighbor)),
                try cell(.leaf(lowerNeighbor))
            ])))
        ]))
        let before = renderedFrames(tree)
        let oldSource = try #require(before[source])
        let requestedSource = CGRect(
            x: oldSource.minX,
            y: oldSource.minY,
            width: oldSource.width + 100,
            height: oldSource.height
        )

        let resized = try resizeVisibleSeamInTree(
            source,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[source] == requestedSource)
        #expect(after[upperNeighbor] == CGRect(x: 704, y: 4, width: 492, height: 392))
        #expect(after[lowerNeighbor] == CGRect(x: 704, y: 404, width: 492, height: 392))
    }

    @Test("Moving an outer edge reports that no visible neighbor exists")
    func outerEdgeHasNoVisibleNeighbor() throws {
        let tree = try columnRootTree()
        let before = renderedFrames(tree)
        let oldSource = try #require(before[topLeft])
        let requestedSource = CGRect(
            x: oldSource.minX + 20,
            y: oldSource.minY,
            width: oldSource.width - 20,
            height: oldSource.height
        )

        #expect(resizeVisibleSeamInTree(
            topLeft,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ) == .failure(.noVisibleNeighbor(.left)))
    }

    @Test("Empty slots survive partition reconstruction")
    func emptySlotsRemainFirstClass() throws {
        let tree = try rowRootTree(bottomRightNode: .void)
        let before = renderedFrames(tree)
        let oldSource = try #require(before[bottomLeft])
        let requestedSource = CGRect(
            x: oldSource.minX,
            y: oldSource.minY,
            width: oldSource.width + 120,
            height: oldSource.height
        )

        let resized = try resizeVisibleSeamInTree(
            bottomLeft,
            from: oldSource,
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()

        #expect(slots(in: resized).count == 4)
        #expect(slots(in: resized).filter { $0.occupancy == .empty }.count == 1)
        #expect(renderedFrames(resized)[bottomLeft] == requestedSource)
    }

    @Test("Multi-edge changes are rejected instead of guessing a tree seam")
    func multiEdgeChangeIsAmbiguous() throws {
        let tree = try columnRootTree()
        let before = renderedFrames(tree)
        let oldSource = try #require(before[bottomLeft])
        let movedAndResized = CGRect(
            x: oldSource.minX + 20,
            y: oldSource.minY,
            width: oldSource.width + 100,
            height: oldSource.height
        )

        #expect(resizeVisibleSeamInTree(
            bottomLeft,
            from: oldSource,
            to: movedAndResized,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ) == .failure(.ambiguousChangedEdges))
    }

    private func renderedFrames(_ tree: Node) -> [WindowID: CGRect] {
        let displayID = DisplayID(raw: 1)
        return layout(
            spaceState: SpaceState(
                id: SpaceID(raw: 1),
                displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [])],
                focused: nil
            ),
            displayID: displayID,
            frame: rootFrame,
            gaps: Gaps(
                inner: innerGap,
                outer: Insets(top: 0, left: 0, bottom: 0, right: 0)
            )
        ).tiled
    }

    private func columnRootTree() throws -> Node {
        .split(try split(.horizontal, [
            try cell(.split(try split(.vertical, [
                try cell(.leaf(topLeft)),
                try cell(.leaf(bottomLeft))
            ]))),
            try cell(.split(try split(.vertical, [
                try cell(.leaf(topRight)),
                try cell(.leaf(bottomRight))
            ])))
        ]))
    }

    private func rowRootTree(bottomRightNode: Node? = nil) throws -> Node {
        .split(try split(.vertical, [
            try cell(.split(try split(.horizontal, [
                try cell(.leaf(topLeft)),
                try cell(.leaf(topRight))
            ]))),
            try cell(.split(try split(.horizontal, [
                try cell(.leaf(bottomLeft)),
                try cell(bottomRightNode ?? .leaf(bottomRight))
            ])))
        ]))
    }

    private func split(_ axis: Axis, _ cells: [Cell]) throws -> Split {
        try Split.create(axis: axis, cells: cells).get()
    }

    private func cell(_ node: Node, weight: Double = 1) throws -> Cell {
        try Cell.create(weight: weight, node: node).get()
    }
}
