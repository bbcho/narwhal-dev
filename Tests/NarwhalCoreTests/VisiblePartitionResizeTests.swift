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

    @Test("Half-point external seams are normalized to rendered split boundaries")
    func halfPointExternalSeamUsesRenderedBoundary() throws {
        let source = WindowID(raw: 20)
        let lowerLeft = WindowID(raw: 21)
        let lowerRight = WindowID(raw: 22)
        let root = CGRect(x: -1_440, y: 30, width: 1_440, height: 2_530)
        let tree = Node.split(try split(.vertical, [
            try cell(.leaf(source)),
            try cell(.split(try split(.horizontal, [
                try cell(.leaf(lowerLeft), weight: 1.1),
                try cell(.leaf(lowerRight), weight: 0.9)
            ])))
        ]))
        let requested = CGRect(x: -1_440, y: 30, width: 1_440, height: 1_391.5)

        let resized = try resizeVisibleSeamInTree(
            source,
            from: CGRect(x: -1_440, y: 30, width: 1_440, height: 1_265),
            to: requested,
            rootFrame: root,
            innerGap: 0,
            tree
        ).get()
        let after = layout(
            spaceState: SpaceState(
                id: SpaceID(raw: 1),
                displays: [
                    DisplayID(raw: 1): DisplaySpaceState(
                        displayID: DisplayID(raw: 1),
                        tree: resized,
                        floating: []
                    )
                ],
                focused: source
            ),
            displayID: DisplayID(raw: 1),
            frame: root,
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        ).tiled

        #expect(after[source] == CGRect(x: -1_440, y: 30, width: 1_440, height: 1_392))
        #expect(after[lowerLeft]?.minY == 1_422)
        #expect(after[lowerRight]?.minY == 1_422)
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

    @Test("A short source moves the whole seam it shares with a taller neighbor")
    func shortSourceMovesWholeSharedSeam() throws {
        let tall = WindowID(raw: 30)
        let upper = WindowID(raw: 31)
        let lower = WindowID(raw: 32)
        let tree = Node.split(try split(.horizontal, [
            try cell(.leaf(tall)),
            try cell(.split(try split(.vertical, [
                try cell(.leaf(upper)),
                try cell(.leaf(lower))
            ])))
        ]))
        let before = renderedFrames(tree)
        let requestedUpper = CGRect(x: 504, y: 4, width: 692, height: 392)

        let resized = try resizeVisibleSeamInTree(
            upper,
            from: try #require(before[upper]),
            to: requestedUpper,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[upper] == requestedUpper)
        #expect(after[lower] == CGRect(x: 504, y: 404, width: 692, height: 392))
        #expect(after[tall] == CGRect(x: 4, y: 4, width: 492, height: 792))
    }

    @Test("A corner drag moves both seams that meet at the corner")
    func cornerDragMovesBothSeams() throws {
        let tree = try columnRootTree()
        let before = renderedFrames(tree)
        let requestedSource = CGRect(x: 4, y: 4, width: 692, height: 442)

        let resized = try resizeVisibleSeamInTree(
            topLeft,
            from: try #require(before[topLeft]),
            to: requestedSource,
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)

        #expect(after[topLeft] == requestedSource)
        #expect(after[topRight] == CGRect(x: 704, y: 4, width: 492, height: 442))
        #expect(after[bottomLeft] == CGRect(x: 4, y: 454, width: 592, height: 342))
        #expect(after[bottomRight] == CGRect(x: 604, y: 454, width: 592, height: 342))
    }

    @Test("Dragging an edge past the neighbor's far edge is rejected")
    func edgeDraggedPastNeighborIsRejected() throws {
        let left = WindowID(raw: 40)
        let right = WindowID(raw: 41)
        let tree = Node.split(try split(.horizontal, [
            try cell(.leaf(left)),
            try cell(.leaf(right))
        ]))
        let before = renderedFrames(tree)

        let result = resizeVisibleSeamInTree(
            left,
            from: try #require(before[left]),
            to: CGRect(x: 4, y: 4, width: 1_240, height: 792),
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        )

        #expect(result == .failure(.invalidPartition))
    }

    @Test("A seam drag starts from the constraint-solved frames, not the raw weights")
    func seamDragUsesConstraintSolvedFrames() throws {
        let first = WindowID(raw: 50)
        let middle = WindowID(raw: 51)
        let last = WindowID(raw: 52)
        let tree = Node.split(try split(.horizontal, [
            try cell(.leaf(first)),
            try cell(.leaf(middle)),
            try cell(.leaf(last))
        ]))
        let constraints = [middle: WindowConstraints(minWidth: 600)]
        let before = try solvedFrames(tree, innerGap: 0, constraints: constraints)
        #expect(before[first] == CGRect(x: 0, y: 0, width: 300, height: 800))
        let requestedFirst = CGRect(x: 0, y: 0, width: 260, height: 800)

        let resized = try resizeVisibleSeamInTree(
            first,
            from: try #require(before[first]),
            to: requestedFirst,
            rootFrame: rootFrame,
            innerGap: 0,
            constraints: constraints,
            tree
        ).get()
        let after = try solvedFrames(resized, innerGap: 0, constraints: constraints)

        #expect(after[first] == requestedFirst)
        #expect(after[middle] == CGRect(x: 260, y: 0, width: 640, height: 800))
        #expect(after[last] == CGRect(x: 900, y: 0, width: 300, height: 800))
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

    @Test("A left-edge resize tolerates application rounding at the fixed right edge")
    func leftEdgeResizeWithRoundedWidth() throws {
        let tree = try columnRootTree()
        let before = renderedFrames(tree)
        let source = try #require(before[bottomRight])
        let resized = try resizeVisibleSeamInTree(
            bottomRight,
            from: source,
            to: CGRect(x: source.minX - 96, y: source.minY,
                       width: source.width + 98, height: source.height),
            rootFrame: rootFrame,
            innerGap: innerGap,
            tree
        ).get()
        let after = renderedFrames(resized)
        #expect(after[topLeft] == before[topLeft])
        #expect(after[topRight] == before[topRight])
        #expect(after[bottomLeft] == CGRect(x: 4, y: 404, width: 496, height: 392))
        #expect(after[bottomRight] == CGRect(x: 508, y: 404, width: 688, height: 392))
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

    private func solvedFrames(
        _ tree: Node,
        innerGap: Double,
        constraints: [WindowID: WindowConstraints]
    ) throws -> [WindowID: CGRect] {
        let displayID = DisplayID(raw: 1)
        let result = solveLayout(
            spaceState: SpaceState(
                id: SpaceID(raw: 1),
                displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [])],
                focused: nil
            ),
            displayID: displayID,
            frame: rootFrame,
            gaps: Gaps(inner: innerGap, outer: Insets(top: 0, left: 0, bottom: 0, right: 0)),
            constraints: constraints
        )
        guard case .solved(let layout, _) = result else {
            throw UnsolvedLayout(result: result)
        }
        return layout.tiled
    }

    private struct UnsolvedLayout: Error {
        let result: LayoutSolveResult
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
