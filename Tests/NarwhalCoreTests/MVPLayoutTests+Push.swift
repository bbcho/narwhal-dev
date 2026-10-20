import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
    @Test("Void leaves are first-class slots")
    func voidLeavesAreFirstClassSlots() throws {
        let window = WindowID(raw: 1)
        let tree = pushIntoTree(window, .left, .void)

        #expect(slots(in: tree) == [
            TreeSlot(path: [0], occupancy: .occupied(window)),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(occupiedWindows(in: tree) == [window])
    }

    @Test("First left push allocates the left half and leaves the other half void")
    func firstPushCreatesHalfScreenLayout() throws {
        let window = WindowID(raw: 1)
        let tree = pushIntoTree(window, .left, .void)
        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: window
        )

        let result = layout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        )

        #expect(result.tiled[window] == CGRect(x: 0, y: 0, width: 500, height: 800))
    }

    @Test("Second left push splits the occupied left half vertically")
    func repeatedLeftPushSplitsOccupiedHalfVertically() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .left, pushIntoTree(first, .left, .void))

        #expect(occupiedWindows(in: tree) == [first, second])

        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: second
        )
        let result = layout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        )

        #expect(result.tiled[first] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result.tiled[second] == CGRect(x: 0, y: 400, width: 600, height: 400))
    }

    @Test("Changing direction for the same window resets it to that edge half")
    func changingDirectionForSameWindowDoesNotCreateQuarterTile() throws {
        let window = WindowID(raw: 1)
        let tree = pushIntoTree(window, .left, pushIntoTree(window, .right, .void))

        #expect(occupiedWindows(in: tree) == [window])

        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: window
        )
        let result = layout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        )

        #expect(result.tiled[window] == CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    @Test("Changing same window from vertical to horizontal resets to the horizontal edge half")
    func changingSameWindowFromVerticalToHorizontalResetsToHalf() throws {
        let window = WindowID(raw: 1)
        let tree = pushIntoTree(window, .left, pushIntoTree(window, .up, .void))

        #expect(occupiedWindows(in: tree) == [window])
        #expect(frames(for: tree)[window] == CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    @Test("Left then right push with two windows fills left and right halves")
    func leftThenRightWithTwoWindowsCreatesHalves() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))

        #expect(occupiedWindows(in: tree) == [first, second])

        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: second
        )
        let result = layout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        )

        #expect(result.tiled[first] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(result.tiled[second] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Center creates a three-column root with a half-width center anchor")
    func centerCreatesThreeColumnRoot() throws {
        let window = WindowID(raw: 1)
        let tree = centerIntoTree(window, .void)

        #expect(slots(in: tree) == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .occupied(window)),
            TreeSlot(path: [2], occupancy: .empty)
        ])
        #expect(frames(for: tree)[window] == CGRect(x: 300, y: 0, width: 600, height: 800))
    }

    @Test("Repeated center pushes stack top to bottom inside the center anchor")
    func repeatedCenterPushesStackTopToBottom() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = centerIntoTree(second, centerIntoTree(first, .void))
        let result = frames(for: tree)

        #expect(occupiedWindows(in: tree) == [first, second])
        #expect(result[first] == CGRect(x: 300, y: 0, width: 600, height: 400))
        #expect(result[second] == CGRect(x: 300, y: 400, width: 600, height: 400))
    }

    @Test("Quarter insertion creates exact corner cells from an empty tree")
    func quarterInsertionCreatesExactCornerCells() throws {
        let topLeft = WindowID(raw: 1)
        let topRight = WindowID(raw: 2)
        let bottomLeft = WindowID(raw: 3)
        let bottomRight = WindowID(raw: 4)

        let topLeftFrames = frames(for: quarterIntoTree(topLeft, .topLeft, .void))
        let topRightFrames = frames(for: quarterIntoTree(topRight, .topRight, .void))
        let bottomLeftFrames = frames(for: quarterIntoTree(bottomLeft, .bottomLeft, .void))
        let bottomRightFrames = frames(for: quarterIntoTree(bottomRight, .bottomRight, .void))

        #expect(topLeftFrames[topLeft] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(topRightFrames[topRight] == CGRect(x: 600, y: 0, width: 600, height: 400))
        #expect(bottomLeftFrames[bottomLeft] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(bottomRightFrames[bottomRight] == CGRect(x: 600, y: 400, width: 600, height: 400))
    }

    @Test("Quarter insertion preserves opposite side lane as void")
    func quarterInsertionPreservesOppositeSideLaneAsVoid() throws {
        let window = WindowID(raw: 1)
        let tree = quarterIntoTree(window, .topLeft, .void)

        #expect(slots(in: tree) == [
            TreeSlot(path: [0, 0], occupancy: .occupied(window)),
            TreeSlot(path: [0, 1], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .empty)
        ])
    }

    @Test("Repeated quarter insertion splits the corner toward center")
    func repeatedQuarterInsertionSplitsCornerTowardCenter() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = quarterIntoTree(second, .topLeft, quarterIntoTree(first, .topLeft, .void))
        let result = frames(for: tree)

        #expect(occupiedWindows(in: tree) == [first, second])
        #expect(result[first] == CGRect(x: 0, y: 0, width: 300, height: 400))
        #expect(result[second] == CGRect(x: 300, y: 0, width: 300, height: 400))
        #expect(slots(in: tree) == [
            TreeSlot(path: [0, 0, 0], occupancy: .occupied(first)),
            TreeSlot(path: [0, 0, 1], occupancy: .occupied(second)),
            TreeSlot(path: [0, 1], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .empty)
        ])
    }

    @Test("Center preserves existing left and right edge lanes")
    func centerPreservesExistingLeftAndRightEdgeLanes() throws {
        let left = WindowID(raw: 1)
        let right = WindowID(raw: 2)
        let center = WindowID(raw: 3)
        let tree = centerIntoTree(center, pushIntoTree(right, .right, pushIntoTree(left, .left, .void)))
        let result = frames(for: tree)

        #expect(occupiedWindows(in: tree) == [left, center, right])
        #expect(result[left] == CGRect(x: 0, y: 0, width: 300, height: 800))
        #expect(result[center] == CGRect(x: 300, y: 0, width: 600, height: 800))
        #expect(result[right] == CGRect(x: 900, y: 0, width: 300, height: 800))
    }

    @Test("Center anchor keeps side pushes as side stacks")
    func centerAnchorKeepsSidePushesAsSideStacks() throws {
        let center = WindowID(raw: 1)
        let topLeft = WindowID(raw: 2)
        let bottomLeft = WindowID(raw: 3)
        let right = WindowID(raw: 4)
        let tree = pushIntoTree(
            right,
            .right,
            pushIntoTree(bottomLeft, .left, pushIntoTree(topLeft, .left, centerIntoTree(center, .void)))
        )
        let result = frames(for: tree)

        #expect(result[topLeft] == CGRect(x: 0, y: 0, width: 300, height: 400))
        #expect(result[bottomLeft] == CGRect(x: 0, y: 400, width: 300, height: 400))
        #expect(result[center] == CGRect(x: 300, y: 0, width: 600, height: 800))
        #expect(result[right] == CGRect(x: 900, y: 0, width: 300, height: 800))
    }

    @Test("Center normalization preserves every occupied cell in a wider root")
    func centerNormalizationPreservesEveryOccupiedCellInWiderRoot() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let fourth = WindowID(raw: 4)
        let center = WindowID(raw: 5)
        let root = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second)),
            try cell(weight: 1, node: .leaf(third)),
            try cell(weight: 1, node: .leaf(fourth))
        ]))

        let tree = centerIntoTree(center, root)

        #expect(Set(occupiedWindows(in: tree)) == [first, second, third, fourth, center])
    }

    @Test("Left right left with three windows splits the left half vertically")
    func threeWindowBSPKeepsRightHalfAndSplitsLeftHalfVertically() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let tree = pushIntoTree(third, .left, pushIntoTree(second, .right, pushIntoTree(first, .left, .void)))

        #expect(occupiedWindows(in: tree) == [first, third, second])

        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: third
        )
        let result = layout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        )

        #expect(result.tiled[first] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result.tiled[third] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(result.tiled[second] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Pushing an already-tiled opposite-lane window leaves its old lane void")
    func pushingExistingWindowLeavesVacatedLaneVoid() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .left, pushIntoTree(second, .right, pushIntoTree(first, .left, .void)))

        #expect(occupiedWindows(in: tree) == [first, second])

        let result = frames(for: tree)
        #expect(result[first] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[second] == CGRect(x: 0, y: 400, width: 600, height: 400))
    }

    @Test("pushIntoTree compacts a nested branch before reinserting its window")
    func pushPrimitiveCompactsVacatedNestedBranch() {
        let leftWindow = WindowID(raw: 1)
        let terminal = WindowID(raw: 2)
        let movedWindow = WindowID(raw: 3)
        var tree = pushIntoTree(terminal, .right, pushIntoTree(leftWindow, .left, .void))

        tree = pushIntoTree(movedWindow, .left, tree)
        var result = frames(for: tree)
        #expect(result[leftWindow] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[movedWindow] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(result[terminal] == CGRect(x: 600, y: 0, width: 600, height: 800))

        tree = pushIntoTree(movedWindow, .right, tree)
        result = frames(for: tree)
        #expect(result[leftWindow] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(result[terminal] == CGRect(x: 600, y: 0, width: 600, height: 400))
        #expect(result[movedWindow] == CGRect(x: 600, y: 400, width: 600, height: 400))

        tree = pushIntoTree(movedWindow, .left, tree)
        result = frames(for: tree)
        #expect(result[leftWindow] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[movedWindow] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(result[terminal] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Apply push compacts the branch vacated before runtime insertion")
    func applyPushCompactsVacatedBranch() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let leftWindow = WindowID(raw: 1)
        let terminal = WindowID(raw: 2)
        let movedWindow = WindowID(raw: 3)
        let initialTree = pushIntoTree(terminal, .right, pushIntoTree(leftWindow, .left, .void))
        let initialFrames = frames(for: initialTree)
        #expect(initialFrames[leftWindow] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(initialFrames[terminal] == CGRect(x: 600, y: 0, width: 600, height: 800))
        #expect(initialFrames[movedWindow] == nil)
        var world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: initialTree, floating: [movedWindow])
                    ],
                    focused: leftWindow
                )
            ],
            windows: [
                leftWindow: metadata(for: leftWindow),
                terminal: metadata(for: terminal),
                movedWindow: metadata(for: movedWindow)
            ],
            windowDisplay: [leftWindow: display, terminal: display, movedWindow: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        for direction in [Direction.left, .right, .left] {
            world = try requireWorld(
                apply(.push(movedWindow, direction), to: world),
                "Expected runtime push \(direction.rawValue) to succeed"
            )
            let displayState = try #require(world.spaces[space]?.displays[display])
            #expect(displayState.floating.isEmpty)
            let tree = displayState.tree
            let result = frames(for: tree)
            if direction == .right {
                #expect(result[leftWindow] == CGRect(x: 0, y: 0, width: 600, height: 800))
                #expect(result[terminal] == CGRect(x: 600, y: 0, width: 600, height: 400))
                #expect(result[movedWindow] == CGRect(x: 600, y: 400, width: 600, height: 400))
            } else {
                #expect(result[leftWindow] == CGRect(x: 0, y: 0, width: 600, height: 400))
                #expect(result[movedWindow] == CGRect(x: 0, y: 400, width: 600, height: 400))
                #expect(result[terminal] == CGRect(x: 600, y: 0, width: 600, height: 800))
            }
        }
    }

    @Test("Reconciliation preserves a vacated right lane for the next right push")
    func reconciliationPreservesVacatedRightLaneForNextRightPush() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let movedLeft = pushIntoTree(second, .left, pushIntoTree(second, .right, pushIntoTree(first, .left, .void)))
        let reconciled = pruneTree(movedLeft, keeping: [first, second])
        let tree = pushIntoTree(third, .right, reconciled)
        let result = frames(for: tree)

        #expect(occupiedWindows(in: tree) == [first, second, third])
        #expect(result[first] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[second] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(result[third] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Horizontal push treats empty split edge lanes as open halves")
    func horizontalPushTreatsEmptySplitEdgeLanesAsOpenHalves() throws {
        let leftOccupant = WindowID(raw: 1)
        let rightOccupant = WindowID(raw: 2)
        let pushedRight = WindowID(raw: 3)
        let pushedLeft = WindowID(raw: 4)
        let emptyVerticalSplit = Node.split(try split(axis: .vertical, cells: [
            try cell(weight: 1, node: .void),
            try cell(weight: 1, node: .void)
        ]))

        let staleRightEdge = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(leftOccupant)),
            try cell(weight: 1, node: emptyVerticalSplit)
        ]))
        let pushedIntoRight = pushIntoTree(pushedRight, .right, staleRightEdge)

        let staleLeftEdge = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: emptyVerticalSplit),
            try cell(weight: 1, node: .leaf(rightOccupant))
        ]))
        let pushedIntoLeft = pushIntoTree(pushedLeft, .left, staleLeftEdge)

        #expect(frames(for: pushedIntoRight)[pushedRight] == CGRect(x: 600, y: 0, width: 600, height: 800))
        #expect(frames(for: pushedIntoLeft)[pushedLeft] == CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    @Test("Third left push splits the bottom-left leaf toward center")
    func thirdLeftPushSplitsCenterFacingLeaf() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let tree = pushIntoTree(third, .left, pushIntoTree(second, .left, pushIntoTree(first, .left, .void)))
        let result = frames(for: tree)

        #expect(result[first] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[second] == CGRect(x: 0, y: 400, width: 300, height: 400))
        #expect(result[third] == CGRect(x: 300, y: 400, width: 300, height: 400))
    }

    @Test("HLHHL creates independent left and right edge lanes")
    func hlhhlCreatesIndependentEdgeLanes() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let e = WindowID(raw: 5)
        let tree = pushIntoTree(
            e,
            .right,
            pushIntoTree(
                d,
                .left,
                pushIntoTree(c, .left, pushIntoTree(b, .right, pushIntoTree(a, .left, .void)))
            )
        )
        let result = frames(for: tree)

        #expect(result[a] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[c] == CGRect(x: 0, y: 400, width: 300, height: 400))
        #expect(result[d] == CGRect(x: 300, y: 400, width: 300, height: 400))
        #expect(result[b] == CGRect(x: 600, y: 0, width: 600, height: 400))
        #expect(result[e] == CGRect(x: 600, y: 400, width: 600, height: 400))
    }

    @Test("Switching a full vertical layout to a horizontal edge preserves it as one group")
    func fullVerticalLayoutMovesOppositeNewHorizontalEdge() {
        let rightTree = tree(for: "JKKKL")
        let rightFrames = frames(for: rightTree)

        #expect(rightFrames[WindowID(raw: 5)] == CGRect(x: 600, y: 0, width: 600, height: 800))
        #expect((1...4).allSatisfy { id in
            guard let frame = rightFrames[WindowID(raw: CGWindowID(id))] else { return false }
            return CGRect(x: 0, y: 0, width: 600, height: 800).contains(frame)
        })

        let leftTree = tree(for: "JKKKH")
        let leftFrames = frames(for: leftTree)

        #expect(leftFrames[WindowID(raw: 5)] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect((1...4).allSatisfy { id in
            guard let frame = leftFrames[WindowID(raw: CGWindowID(id))] else { return false }
            return CGRect(x: 600, y: 0, width: 600, height: 800).contains(frame)
        })
    }

    @Test("Switching a full horizontal layout to a vertical edge preserves it as one group")
    func fullHorizontalLayoutMovesOppositeNewVerticalEdge() {
        for keys in ["HLLLJ", "HLLLLJ"] {
            let bottomFrames = frames(for: tree(for: keys))
            let newWindow = WindowID(raw: CGWindowID(keys.count))

            #expect(bottomFrames[newWindow] == CGRect(x: 0, y: 400, width: 1200, height: 400))
            #expect((1..<keys.count).allSatisfy { id in
                guard let frame = bottomFrames[WindowID(raw: CGWindowID(id))] else { return false }
                return CGRect(x: 0, y: 0, width: 1200, height: 400).contains(frame)
            })
        }

        let topTree = tree(for: "HLLLK")
        let topFrames = frames(for: topTree)

        #expect(topFrames[WindowID(raw: 5)] == CGRect(x: 0, y: 0, width: 1200, height: 400))
        #expect((1...4).allSatisfy { id in
            guard let frame = topFrames[WindowID(raw: CGWindowID(id))] else { return false }
            return CGRect(x: 0, y: 400, width: 1200, height: 400).contains(frame)
        })
    }

    @Test("Third right push splits the bottom-right leaf toward center")
    func thirdRightPushSplitsCenterFacingLeaf() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let tree = pushIntoTree(c, .right, pushIntoTree(b, .right, pushIntoTree(a, .right, .void)))
        let result = frames(for: tree)

        #expect(result[a] == CGRect(x: 600, y: 0, width: 600, height: 400))
        #expect(result[c] == CGRect(x: 600, y: 400, width: 300, height: 400))
        #expect(result[b] == CGRect(x: 900, y: 400, width: 300, height: 400))
    }

    @Test("Third up push inserts into the top row before the inner anchor")
    func thirdUpPushInsertsIntoTopRowBeforeInnerAnchor() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let tree = pushIntoTree(c, .up, pushIntoTree(b, .up, pushIntoTree(a, .up, .void)))
        let result = frames(for: tree)

        #expect(result[a] == CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(result[c] == CGRect(x: 400, y: 0, width: 400, height: 400))
        #expect(result[b] == CGRect(x: 800, y: 0, width: 400, height: 400))
    }

    @Test("Third down push inserts into the bottom row before the inner anchor")
    func thirdDownPushInsertsIntoBottomRowBeforeInnerAnchor() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let tree = pushIntoTree(c, .down, pushIntoTree(b, .down, pushIntoTree(a, .down, .void)))
        let result = frames(for: tree)

        #expect(result[a] == CGRect(x: 0, y: 400, width: 400, height: 400))
        #expect(result[c] == CGRect(x: 400, y: 400, width: 400, height: 400))
        #expect(result[b] == CGRect(x: 800, y: 400, width: 400, height: 400))
    }

    @Test("HLJK keeps the completed horizontal layout together when switching axes")
    func hljkKeepsCompletedHorizontalLayoutTogether() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let tree = pushIntoTree(d, .up, pushIntoTree(c, .down, pushIntoTree(b, .right, pushIntoTree(a, .left, .void))))
        let result = frames(for: tree)

        #expect(result[a] == CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(result[d] == CGRect(x: 400, y: 0, width: 400, height: 400))
        #expect(result[b] == CGRect(x: 800, y: 0, width: 400, height: 400))
        #expect(result[c] == CGRect(x: 0, y: 400, width: 1200, height: 400))
    }

    @Test("KJHL keeps the completed vertical layout together when switching axes")
    func kjhlKeepsCompletedVerticalLayoutTogether() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let tree = pushIntoTree(d, .right, pushIntoTree(c, .left, pushIntoTree(b, .down, pushIntoTree(a, .up, .void))))
        let result = frames(for: tree, frame: CGRect(x: 0, y: 0, width: 1200, height: 900))

        #expect(result[c] == CGRect(x: 0, y: 0, width: 600, height: 900))
        #expect(result[a] == CGRect(x: 600, y: 0, width: 600, height: 450))
        #expect(result[d] == CGRect(x: 600, y: 450, width: 300, height: 450))
        #expect(result[b] == CGRect(x: 900, y: 450, width: 300, height: 450))
    }

    @Test("Generated push sequences preserve core BSP invariants")
    func generatedPushSequencesPreserveCoreInvariants() throws {
        for directions in generatedDirectionSequences(maxLength: 5) {
            var tree = Node.void
            var inserted: [WindowID] = []

            for (index, direction) in directions.enumerated() {
                let window = WindowID(raw: CGWindowID(index + 1))
                inserted.append(window)
                tree = pushIntoTree(window, direction, tree)

                let occupied = occupiedWindows(in: tree)
                #expect(Set(occupied).count == occupied.count)
                #expect(Set(occupied) == Set(inserted))

                let rects = Array(frames(for: tree).values)
                #expect(rects.allSatisfy(isFiniteNonNegativeRect))
                #expect(rectsArePairwiseDisjoint(rects))
            }

            let kept = Set(inserted.enumerated().compactMap { index, window in
                index.isMultiple(of: 2) ? window : nil
            })
            let pruned = pruneTree(tree, keeping: kept)

            #expect(Set(occupiedWindows(in: pruned)).isSubset(of: kept))
            #expect(pruneTree(pruned, keeping: kept) == pruned)
        }
    }

    @Test("Default MVP gaps keep three Finder-width columns above 500 px on MacBook display")
    func defaultGapsKeepThreeColumnsAboveFinderMinimum() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let e = WindowID(raw: 5)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(a)),
                try cell(weight: 1, node: .leaf(c))
            ]))),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(e)),
                try cell(weight: 1, node: .void)
            ]))),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(b)),
                try cell(weight: 1, node: .leaf(d))
            ])))
        ]))
        let display = DisplayID(raw: 1)
        let space = SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: nil
        )

        let result = layout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 33, width: 1512, height: 873),
            gaps: Config.default.gaps
        ).tiled

        #expect(result[a] == CGRect(x: 0, y: 33, width: 504, height: 437))
        #expect(result[e] == CGRect(x: 504, y: 33, width: 504, height: 437))
        #expect(result[b] == CGRect(x: 1008, y: 33, width: 504, height: 437))
        #expect(result.values.allSatisfy { $0.width >= 500 })
    }

    @Test("Apply push fails when active Space is unavailable")
    func applyPushFailsWithoutActiveSpace() throws {
        let display = DisplayID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [
                display: DisplayInfo(
                    id: display,
                    slot: 0,
                    fingerprint: nil,
                    frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
                )
            ],
            activeSpace: nil,
            spaces: [:],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .failure(let error) = apply(.push(window, .left), to: world) else {
            #expect(Bool(false), "Expected push without active Space to fail")
            throw TestAbort()
        }

        #expect(error == .activeSpaceUnavailable)
        #expect(error.code == "active_space_unavailable")
        #expect(error.message == "active Space unavailable")
    }

    @Test("Apply push updates the active display tree")
    func applyPushUpdatesWorld() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let metadata = WindowMetadata(
            id: window,
            bundleID: BundleID(raw: "com.example"),
            title: "Window",
            role: "AXWindow",
            pid: 42,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isResizable: true,
            isMinimized: false
        )
        let world = World(
            displays: [
                display: DisplayInfo(
                    id: display,
                    slot: 0,
                    fingerprint: nil,
                    frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
                )
            ],
            activeSpace: space,
            spaces: [space: SpaceState(id: space, displays: [:], focused: nil)],
            windows: [window: metadata],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(apply(.push(window, .left), to: world), "Expected push to succeed")

        let tree = next.spaces[space]?.displays[display]?.tree
        #expect(tree.map(occupiedWindows(in:)) == [window])
        #expect(next.spaces[space]?.focused == window)
    }

    @Test("Apply push clears stale leaves from other displays")
    func applyPushClearsStaleLeavesFromOtherDisplays() throws {
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [
                leftDisplay: display(leftDisplay, x: 0, width: 1000),
                rightDisplay: display(rightDisplay, x: 1000, width: 1000)
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        leftDisplay: DisplaySpaceState(
                            displayID: leftDisplay,
                            tree: pushIntoTree(window, .left, .void),
                            floating: []
                        ),
                        rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .void, floating: [])
                    ],
                    focused: nil
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: rightDisplay],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(apply(.push(window, .right), to: world), "Expected push to succeed")

        #expect(slots(in: try #require(next.spaces[space]?.displays[leftDisplay]?.tree)) == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(frames(for: try #require(next.spaces[space]?.displays[rightDisplay]?.tree), frame: try #require(next.displays[rightDisplay]?.visibleFrame))[window] == CGRect(x: 1500, y: 0, width: 500, height: 800))
        #expect(next.windowDisplay[window] == rightDisplay)
    }
}
