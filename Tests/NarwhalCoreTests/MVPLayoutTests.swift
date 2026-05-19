import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("MVP tiling core")
struct MVPLayoutTests {
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

    @Test("Eject leaves the zone shape intact")
    func ejectLeavesZoneShapeIntact() throws {
        let window = WindowID(raw: 1)
        let ejected = ejectFromTree(window, pushIntoTree(window, .left, .void))

        guard case .split(let split) = ejected else {
            Issue.record("Expected eject to preserve the split shape")
            return
        }

        #expect(split.axis == .horizontal)
        #expect(split.cells.map(\.node) == [.void, .void])
    }

    @Test("Apply eject moves a tiled window to floating while preserving zone shape")
    func applyEjectMovesTiledWindowToFloating() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: second
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second)
            ],
            windowDisplay: [
                first: display,
                second: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [second: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.eject(second), to: world) else {
            Issue.record("Expected eject to succeed")
            return
        }

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)
        let flattened: Layout
        switch flattenedLayout(of: next) {
        case .success(let layout):
            flattened = layout
        case .failure(let error):
            Issue.record("Expected eject layout to remain satisfiable, got \(error)")
            return
        }

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [second])
        #expect(next.spaces[space]?.focused == second)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(flattened.tiled == [first: CGRect(x: 0, y: 0, width: 600, height: 800)])
        #expect(flattened.floatingZOrder == [second])
    }

    @Test("Apply eject rejects windows that are already floating")
    func applyEjectRejectsFloatingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.eject(window), to: world) == .failure(.windowIsFloating(window)))
    }

    @Test("Apply eject rejects missing windows")
    func applyEjectRejectsMissingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let missing = WindowID(raw: 99)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [])],
                    focused: nil
                )
            ],
            windows: [:],
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.eject(missing), to: world) == .failure(.windowNotFound(missing)))
    }

    @Test("Apply toggleFloat moves tiled windows to floating")
    func applyToggleFloatMovesTiledWindowToFloating() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: second
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second, isResizable: false)
            ],
            windowDisplay: [
                first: display,
                second: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [second: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.toggleFloat(second), to: world) else {
            Issue.record("Expected toggleFloat to float the tiled window")
            return
        }

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [second])
        #expect(next.spaces[space]?.focused == second)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
    }

    @Test("Apply toggleFloat tiles floating windows into the center anchor")
    func applyToggleFloatTilesFloatingWindowIntoCenterAnchor() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [window: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.toggleFloat(window), to: world) else {
            Issue.record("Expected toggleFloat to tile the floating window")
            return
        }

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)
        let flattened: Layout
        switch flattenedLayout(of: next) {
        case .success(let layout):
            flattened = layout
        case .failure(let error):
            Issue.record("Expected toggleFloat layout to remain satisfiable, got \(error)")
            return
        }

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .occupied(window)),
            TreeSlot(path: [2], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [])
        #expect(next.spaces[space]?.focused == window)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(flattened.tiled == [window: CGRect(x: 300, y: 0, width: 600, height: 800)])
        #expect(flattened.floatingZOrder == [])
    }

    @Test("Apply toggleFloat can create the active Space for floating windows")
    func applyToggleFloatCreatesActiveSpaceForFloatingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [:],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.toggleFloat(window), to: world) else {
            Issue.record("Expected toggleFloat to create the active Space")
            return
        }

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .occupied(window)),
            TreeSlot(path: [2], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [])
        #expect(next.spaces[space]?.focused == window)
    }

    @Test("Apply toggleFloat rejects non-resizable floating windows")
    func applyToggleFloatRejectsNonResizableFloatingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window, isResizable: false)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.toggleFloat(window), to: world) == .failure(.windowNotResizable(window)))
    }

    @Test("Apply focus records focused window without changing layout state")
    func applyFocusRecordsFocusedWindowOnly() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [second])],
                    focused: first
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second)
            ],
            windowDisplay: [
                first: display,
                second: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [second: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.focus(second), to: world) else {
            Issue.record("Expected focus to succeed")
            return
        }

        #expect(next.spaces[space]?.focused == second)
        #expect(next.spaces[space]?.displays == world.spaces[space]?.displays)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Apply focus can create the active Space focus record")
    func applyFocusCreatesActiveSpaceFocusRecord() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [:],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.focus(window), to: world) else {
            Issue.record("Expected focus to create active Space state")
            return
        }

        #expect(next.spaces[space] == SpaceState(id: space, displays: [:], focused: window))
    }

    @Test("Apply focus rejects missing windows and missing active Space")
    func applyFocusRejectsInvalidState() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let missing = WindowID(raw: 99)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [space: SpaceState(id: space, displays: [:], focused: nil)],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let noActiveSpace = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: nil,
            spaces: [:],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.focus(missing), to: world) == .failure(.windowNotFound(missing)))
        #expect(apply(.focus(window), to: noActiveSpace) == .failure(.activeSpaceUnavailable))
    }

    @Test("Apply focusDirection selects the adjacent tiled window without changing layout state")
    func applyFocusDirectionSelectsAdjacentTiledWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: first
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second)
            ],
            windowDisplay: [
                first: display,
                second: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [second: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.focusDirection(.right), to: world) else {
            Issue.record("Expected focusDirection to succeed")
            return
        }

        #expect(next.spaces[space]?.focused == second)
        #expect(next.spaces[space]?.displays == world.spaces[space]?.displays)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Apply focusDirection rejects missing focus and missing neighbors")
    func applyFocusDirectionRejectsInvalidState() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let focusedWorld = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .leaf(window), floating: [])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let noFocusWorld = World(
            displays: focusedWorld.displays,
            activeSpace: focusedWorld.activeSpace,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: focusedWorld.spaces[space]?.displays ?? [:],
                    focused: nil
                )
            ],
            windows: focusedWorld.windows,
            windowDisplay: focusedWorld.windowDisplay,
            windowConstraints: focusedWorld.windowConstraints,
            pendingRules: focusedWorld.pendingRules,
            config: focusedWorld.config
        )

        #expect(apply(.focusDirection(.right), to: noFocusWorld) == .failure(.activeSpaceUnavailable))
        #expect(apply(.focusDirection(.right), to: focusedWorld) == .failure(.noNeighbor(.right)))
    }

    @Test("Apply focusCycle follows observed window frame order without changing layout state")
    func applyFocusCycleFollowsWindowFrameOrder() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let topLeft = WindowID(raw: 1)
        let topRight = WindowID(raw: 2)
        let bottomLeft = WindowID(raw: 3)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [topLeft, topRight, bottomLeft])],
                    focused: topLeft
                )
            ],
            windows: [
                topLeft: metadata(for: topLeft, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                topRight: metadata(for: topRight, frame: CGRect(x: 300, y: 0, width: 100, height: 100)),
                bottomLeft: metadata(for: bottomLeft, frame: CGRect(x: 0, y: 300, width: 100, height: 100))
            ],
            windowDisplay: [
                topLeft: display,
                topRight: display,
                bottomLeft: display
            ],
            windowConstraints: [topRight: WindowConstraints(minWidth: 500)],
            pendingRules: [bottomLeft: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.focusCycle(.next), to: world) else {
            Issue.record("Expected next focus cycle to succeed")
            return
        }
        guard case .success(let previous) = apply(.focusCycle(.previous), to: world) else {
            Issue.record("Expected previous focus cycle to succeed")
            return
        }

        #expect(next.spaces[space]?.focused == topRight)
        #expect(previous.spaces[space]?.focused == bottomLeft)
        #expect(next.spaces[space]?.displays == world.spaces[space]?.displays)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("External move updates frame and display ownership without changing layout state")
    func externalMoveUpdatesFrameAndDisplayOwnershipOnly() throws {
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let other = WindowID(raw: 2)
        let tree = pushIntoTree(window, .left, .void)
        let world = World(
            displays: [
                leftDisplay: self.display(leftDisplay, x: 0, width: 1200),
                rightDisplay: self.display(rightDisplay, x: 1200, width: 1200)
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: tree, floating: [other])],
                    focused: other
                )
            ],
            windows: [
                window: metadata(for: window, frame: CGRect(x: 100, y: 100, width: 300, height: 250)),
                other: metadata(for: other, frame: CGRect(x: 600, y: 200, width: 300, height: 250))
            ],
            windowDisplay: [
                window: leftDisplay,
                other: leftDisplay
            ],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [other: .forceFloat],
            config: .default
        )
        let movedFrame = CGRect(x: 1400, y: 80, width: 320, height: 280)

        guard case .success(let next) = apply(.windowMovedExternally(window, movedFrame), to: world) else {
            Issue.record("Expected external move to succeed")
            return
        }

        #expect(next.windows[window]?.frame == movedFrame)
        #expect(next.windows[other] == world.windows[other])
        #expect(next.windowDisplay[window] == rightDisplay)
        #expect(next.spaces == world.spaces)
        #expect(next.displays == world.displays)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
        #expect(apply(.windowMovedExternally(window, movedFrame), to: next) == .success(next))
    }

    @Test("External resize updates size while preserving origin and layout state")
    func externalResizeUpdatesSizeOnly() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let originalFrame = CGRect(x: 100, y: 120, width: 300, height: 250)
        let resizedFrame = CGRect(x: 100, y: 120, width: 640, height: 360)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window, frame: originalFrame)],
            windowDisplay: [window: display],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [window: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.windowResizedExternally(window, resizedFrame.size), to: world) else {
            Issue.record("Expected external resize to succeed")
            return
        }

        #expect(next.windows[window]?.frame == resizedFrame)
        #expect(next.windowDisplay[window] == display)
        #expect(next.spaces == world.spaces)
        #expect(next.displays == world.displays)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Balance tree normalizes every split weight without changing slots")
    func balanceTreeNormalizesEverySplitWeight() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 3, node: .leaf(first)),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 4, node: .leaf(second)),
                try cell(weight: 2, node: .void)
            ])))
        ]))

        let balanced = balanceTree(tree)

        #expect(balanced == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(second)),
                try cell(weight: 1, node: .void)
            ])))
        ])))
        #expect(slots(in: balanced) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1, 0], occupancy: .occupied(second)),
            TreeSlot(path: [1, 1], occupancy: .empty)
        ])

        let result = frames(for: balanced)
        #expect(result[first] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(result[second] == CGRect(x: 600, y: 0, width: 600, height: 400))
    }

    @Test("Apply balance normalizes one Space while preserving world metadata")
    func applyBalanceNormalizesSelectedSpaceOnly() throws {
        let display = DisplayID(raw: 1)
        let selectedSpace = SpaceID(raw: 1)
        let otherSpace = SpaceID(raw: 2)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let floating = WindowID(raw: 3)
        let selectedTree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 5, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let otherTree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 7, node: .leaf(first)),
            try cell(weight: 1, node: .void)
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: selectedSpace,
            spaces: [
                selectedSpace: SpaceState(
                    id: selectedSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: selectedTree, floating: [floating])],
                    focused: second
                ),
                otherSpace: SpaceState(
                    id: otherSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: otherTree, floating: [])],
                    focused: first
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second),
                floating: metadata(for: floating)
            ],
            windowDisplay: [
                first: display,
                second: display,
                floating: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [floating: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.balance(selectedSpace), to: world) else {
            Issue.record("Expected balance to succeed")
            return
        }

        #expect(next.spaces[selectedSpace]?.displays[display]?.tree == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ])))
        #expect(next.spaces[selectedSpace]?.displays[display]?.floating == [floating])
        #expect(next.spaces[selectedSpace]?.focused == second)
        #expect(next.spaces[otherSpace] == world.spaces[otherSpace])
        #expect(next.displays == world.displays)
        #expect(next.activeSpace == world.activeSpace)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Apply balance rejects missing Spaces")
    func applyBalanceRejectsMissingSpace() throws {
        let missing = SpaceID(raw: 99)

        #expect(apply(.balance(missing), to: World.empty) == .failure(.spaceNotFound(missing)))
    }

    @Test("Resize split grows the focused cell toward the requested neighbor")
    func resizeSplitGrowsFocusedCellTowardNeighbor() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))

        guard case .success(let resized) = resizeSplitInTree(first, .right, delta: 0.5, tree) else {
            Issue.record("Expected resize to succeed")
            return
        }

        #expect(resized == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1.5, node: .leaf(first)),
            try cell(weight: 0.5, node: .leaf(second))
        ])))
        #expect(slots(in: resized) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .occupied(second))
        ])

        let result = frames(for: resized)
        #expect(result[first] == CGRect(x: 0, y: 0, width: 900, height: 800))
        #expect(result[second] == CGRect(x: 900, y: 0, width: 300, height: 800))
    }

    @Test("Resize split chooses the innermost matching ancestor split")
    func resizeSplitChoosesInnermostMatchingAncestor() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(first)),
                try cell(weight: 1, node: .leaf(third))
            ]))),
            try cell(weight: 1, node: .leaf(second))
        ]))

        guard case .success(let resizedDown) = resizeSplitInTree(first, .down, delta: 0.25, tree) else {
            Issue.record("Expected vertical resize to succeed")
            return
        }
        guard case .success(let resizedRight) = resizeSplitInTree(first, .right, delta: 0.5, tree) else {
            Issue.record("Expected ancestor horizontal resize to succeed")
            return
        }

        #expect(resizedDown == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1.25, node: .leaf(first)),
                try cell(weight: 0.75, node: .leaf(third))
            ]))),
            try cell(weight: 1, node: .leaf(second))
        ])))
        #expect(resizedRight == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1.5, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(first)),
                try cell(weight: 1, node: .leaf(third))
            ]))),
            try cell(weight: 0.5, node: .leaf(second))
        ])))

        let downFrames = frames(for: resizedDown)
        #expect(downFrames[first] == CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(downFrames[third] == CGRect(x: 0, y: 500, width: 600, height: 300))
        #expect(downFrames[second] == CGRect(x: 600, y: 0, width: 600, height: 800))

        let rightFrames = frames(for: resizedRight)
        #expect(rightFrames[first] == CGRect(x: 0, y: 0, width: 900, height: 400))
        #expect(rightFrames[third] == CGRect(x: 0, y: 400, width: 900, height: 400))
        #expect(rightFrames[second] == CGRect(x: 900, y: 0, width: 300, height: 800))
    }

    @Test("Resize split rejects missing neighbor, invalid delta, and collapsing weights")
    func resizeSplitRejectsInvalidPureInputs() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let missing = WindowID(raw: 99)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))

        #expect(resizeSplitInTree(first, .left, delta: 0.5, tree) == .failure(.noNeighbor(.left)))
        #expect(resizeSplitInTree(first, .right, delta: .infinity, tree) == .failure(.nonFiniteDelta))
        #expect(resizeSplitInTree(first, .right, delta: 1, tree) == .failure(.nonPositiveWeight))
        #expect(resizeSplitInTree(missing, .right, delta: 0.5, tree) == .failure(.windowNotFound(missing)))
    }

    @Test("Apply resizeSplit updates active tree weights and preserves world metadata")
    func applyResizeSplitUpdatesWeightsOnly() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let floating = WindowID(raw: 3)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [floating])],
                    focused: second
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second),
                floating: metadata(for: floating)
            ],
            windowDisplay: [
                first: display,
                second: display,
                floating: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [floating: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.resizeSplit(first, .right, delta: 0.5), to: world) else {
            Issue.record("Expected resizeSplit to succeed")
            return
        }
        let flattened: Layout
        switch flattenedLayout(of: next) {
        case .success(let layout):
            flattened = layout
        case .failure(let error):
            Issue.record("Expected resized layout to remain satisfiable, got \(error)")
            return
        }

        #expect(next.spaces[space]?.displays[display]?.tree == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1.5, node: .leaf(first)),
            try cell(weight: 0.5, node: .leaf(second))
        ])))
        #expect(next.spaces[space]?.displays[display]?.floating == [floating])
        #expect(next.spaces[space]?.focused == first)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
        #expect(flattened.tiled[first] == CGRect(x: 0, y: 0, width: 700, height: 800))
        #expect(flattened.tiled[second] == CGRect(x: 700, y: 0, width: 500, height: 800))
    }

    @Test("Apply resizeSplit rejects invalid command state")
    func applyResizeSplitRejectsInvalidState() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let floating = WindowID(raw: 3)
        let fixed = WindowID(raw: 4)
        let missing = WindowID(raw: 99)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let fixedTree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(fixed)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [floating])],
                    focused: first
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second),
                floating: metadata(for: floating),
                fixed: metadata(for: fixed, isResizable: false)
            ],
            windowDisplay: [
                first: display,
                second: display,
                floating: display,
                fixed: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let nonResizableWorld = World(
            displays: world.displays,
            activeSpace: world.activeSpace,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: fixedTree, floating: [])],
                    focused: fixed
                )
            ],
            windows: world.windows,
            windowDisplay: world.windowDisplay,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )

        #expect(apply(.resizeSplit(missing, .right, delta: 0.5), to: world) == .failure(.windowNotFound(missing)))
        #expect(apply(.resizeSplit(fixed, .right, delta: 0.5), to: nonResizableWorld) == .failure(.windowNotResizable(fixed)))
        #expect(apply(.resizeSplit(floating, .right, delta: 0.5), to: world) == .failure(.windowIsFloating(floating)))
        #expect(apply(.resizeSplit(first, .left, delta: 0.5), to: world) == .failure(.noNeighbor(.left)))
        #expect(apply(.resizeSplit(first, .right, delta: .nan), to: world) == .failure(.invalidResizeDelta))
        #expect(
            apply(.resizeSplit(first, .right, delta: 1), to: world)
                == .failure(.resizeWouldCollapseSplit(first, .right))
        )
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

    @Test("HLJK creates one lane per edge")
    func hljkCreatesOneLanePerEdge() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let tree = pushIntoTree(d, .up, pushIntoTree(c, .down, pushIntoTree(b, .right, pushIntoTree(a, .left, .void))))
        let result = frames(for: tree)

        #expect(result[a] == CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(result[d] == CGRect(x: 400, y: 0, width: 400, height: 400))
        #expect(result[c] == CGRect(x: 400, y: 400, width: 400, height: 400))
        #expect(result[b] == CGRect(x: 800, y: 0, width: 400, height: 800))
    }

    @Test("KJHL creates the vertical mirror of HLJK")
    func kjhlCreatesVerticalMirrorOfHLJK() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let tree = pushIntoTree(d, .right, pushIntoTree(c, .left, pushIntoTree(b, .down, pushIntoTree(a, .up, .void))))
        let result = frames(for: tree, frame: CGRect(x: 0, y: 0, width: 1200, height: 900))

        #expect(result[a] == CGRect(x: 0, y: 0, width: 1200, height: 300))
        #expect(result[c] == CGRect(x: 0, y: 300, width: 600, height: 300))
        #expect(result[d] == CGRect(x: 600, y: 300, width: 600, height: 300))
        #expect(result[b] == CGRect(x: 0, y: 600, width: 1200, height: 300))
    }

    @Test("Pruning a closed window removes it from metadata, display ownership, and BSP layout")
    func pruningClosedWindowRemovesItFromWorldAndTree() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let tree = pushIntoTree(c, .left, pushIntoTree(b, .right, pushIntoTree(a, .left, .void)))
        let world = World(
            displays: [
                display: DisplayInfo(
                    id: display,
                    slot: 0,
                    fingerprint: nil,
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
                )
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: tree, floating: [b])
                    ],
                    focused: b
                )
            ],
            windows: [
                a: metadata(for: a),
                b: metadata(for: b),
                c: metadata(for: c)
            ],
            windowDisplay: [
                a: display,
                b: display,
                c: display
            ],
            windowConstraints: [
                b: WindowConstraints(minWidth: 500),
                c: WindowConstraints(minWidth: 600)
            ],
            pendingRules: [b: .forceFloat],
            config: .default
        )

        let pruned = pruneWorld(world, keepingLiveWindows: [a, c])
        let prunedTree = pruned.spaces[space]?.displays[display]?.tree
        let prunedFrames = prunedTree.map { frames(for: $0) } ?? [:]

        #expect(pruned.windows.keys.sorted(by: { $0.raw < $1.raw }) == [a, c])
        #expect(pruned.windowDisplay.keys.sorted(by: { $0.raw < $1.raw }) == [a, c])
        #expect(pruned.windowConstraints == [c: WindowConstraints(minWidth: 600)])
        #expect(pruned.pendingRules.isEmpty)
        #expect(pruned.spaces[space]?.focused == nil)
        #expect(pruned.spaces[space]?.displays[display]?.floating == [])
        #expect(prunedTree.map(occupiedWindows(in:)) == [a, c])
        #expect(prunedFrames[a] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(prunedFrames[c] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(prunedFrames[b] == nil)
    }

    @Test("Complete environment snapshot replaces live windows and assigns display ownership")
    func completeEnvironmentSnapshotReplacesLiveWindowsAndAssignsDisplays() throws {
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let space = SpaceID(raw: 99)
        let first = WindowID(raw: 11)
        let second = WindowID(raw: 12)
        let displays = [
            leftDisplay: display(leftDisplay, x: 0, width: 1000),
            rightDisplay: display(rightDisplay, x: 1000, width: 1000)
        ]
        let snapshot = EnvironmentSnapshot(
            activeSpace: space,
            displays: displays,
            axSnapshot: AXWindowSnapshot(
                windows: [
                    metadata(for: first, frame: CGRect(x: 100, y: 50, width: 400, height: 300)),
                    metadata(for: second, frame: CGRect(x: 1200, y: 50, width: 400, height: 300))
                ],
                quality: .complete
            )
        )

        guard case .success(let next) = apply(.environmentChanged(snapshot), to: World.empty) else {
            Issue.record("Expected environmentChanged to succeed")
            return
        }

        #expect(next.activeSpace == space)
        #expect(next.displays == displays)
        #expect(next.windows.keys.sorted { $0.raw < $1.raw } == [first, second])
        #expect(next.windowDisplay == [first: leftDisplay, second: rightDisplay])
        #expect(next.spaces[space]?.displays[leftDisplay]?.tree == .void)
        #expect(next.spaces[space]?.displays[leftDisplay]?.floating == [first])
        #expect(next.spaces[space]?.displays[rightDisplay]?.tree == .void)
        #expect(next.spaces[space]?.displays[rightDisplay]?.floating == [second])
    }

    @Test("Complete environment snapshot without active Space does not fabricate Space 1")
    func completeEnvironmentSnapshotWithoutActiveSpaceDoesNotFabricateSpaceOne() throws {
        let displayID = DisplayID(raw: 7)
        let oldSpace = SpaceID(raw: 99)
        let window = WindowID(raw: 42)
        let oldTree = pushIntoTree(window, .left, .void)
        let oldWorld = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: oldSpace,
            spaces: [
                oldSpace: SpaceState(
                    id: oldSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: oldTree, floating: [])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: displayID],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [window: .forceFloat],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: nil,
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            axSnapshot: AXWindowSnapshot(
                windows: [metadata(for: window, frame: CGRect(x: 100, y: 50, width: 400, height: 300))],
                quality: .complete
            )
        )

        guard case .success(let next) = apply(.environmentChanged(snapshot), to: oldWorld) else {
            Issue.record("Expected environmentChanged to succeed")
            return
        }

        #expect(next.activeSpace == nil)
        #expect(next.windows == [window: metadata(for: window, frame: CGRect(x: 100, y: 50, width: 400, height: 300))])
        #expect(next.windowDisplay == [window: displayID])
        #expect(next.spaces[SpaceID(raw: 1)] == nil)
        #expect(next.spaces[oldSpace]?.displays[displayID]?.tree == oldTree)
        #expect(next.spaces[oldSpace]?.focused == window)
        #expect(next.windowConstraints == [window: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [window: .forceFloat])
    }

    @Test("Complete environment snapshot prunes closed windows but preserves zone shape")
    func completeEnvironmentSnapshotPrunesClosedWindowsPreservingTreeShape() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let closed = WindowID(raw: 2)
        let tree = pushIntoTree(closed, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [closed])],
                    focused: closed
                )
            ],
            windows: [first: metadata(for: first), closed: metadata(for: closed)],
            windowDisplay: [first: displayID, closed: displayID],
            windowConstraints: [closed: WindowConstraints(minWidth: 500)],
            pendingRules: [closed: .forceFloat],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: space,
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            axSnapshot: AXWindowSnapshot(windows: [metadata(for: first)], quality: .complete)
        )

        guard case .success(let next) = apply(.environmentChanged(snapshot), to: world) else {
            Issue.record("Expected environmentChanged to succeed")
            return
        }

        let nextTree = next.spaces[space]?.displays[displayID]?.tree
        #expect(next.windows == [first: metadata(for: first)])
        #expect(next.windowDisplay == [first: displayID])
        #expect(next.windowConstraints.isEmpty)
        #expect(next.pendingRules.isEmpty)
        #expect(next.spaces[space]?.focused == nil)
        #expect(next.spaces[space]?.displays[displayID]?.floating == [])
        #expect(nextTree.map(occupiedWindows(in:)) == [first])
        #expect(nextTree.map(slots(in:)) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .empty)
        ])
    }

    @Test("Incomplete environment snapshot preserves window state and updates display identity only")
    func incompleteEnvironmentSnapshotPreservesWindowState() throws {
        let oldDisplay = DisplayID(raw: 1)
        let newDisplay = DisplayID(raw: 2)
        let oldSpace = SpaceID(raw: 1)
        let newSpace = SpaceID(raw: 2)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [oldDisplay: display(oldDisplay, x: 0, width: 1000)],
            activeSpace: oldSpace,
            spaces: [oldSpace: SpaceState(id: oldSpace, displays: [:], focused: window)],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: oldDisplay],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [window: .forceFloat],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: newSpace,
            displays: [newDisplay: display(newDisplay, x: 1000, width: 1200)],
            axSnapshot: AXWindowSnapshot(
                windows: [],
                quality: .partial([AXWindowReadError(windowID: nil, pid: nil, message: "AX read failed")])
            )
        )

        guard case .success(let next) = apply(.environmentChanged(snapshot), to: world) else {
            Issue.record("Expected environmentChanged to succeed")
            return
        }

        #expect(next.activeSpace == newSpace)
        #expect(next.displays == [newDisplay: display(newDisplay, x: 1000, width: 1200)])
        #expect(next.spaces == world.spaces)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
    }

    @Test("Incomplete environment snapshot without active Space clears active Space without deleting windows")
    func incompleteEnvironmentSnapshotWithoutActiveSpaceClearsActiveSpaceOnly() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 10)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [space: SpaceState(id: space, displays: [:], focused: window)],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: displayID],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [window: .forceFloat],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: nil,
            displays: [displayID: display(displayID, x: 0, width: 1200)],
            axSnapshot: AXWindowSnapshot(
                windows: [],
                quality: .partial([AXWindowReadError(windowID: nil, pid: nil, message: "AX read failed")])
            )
        )

        guard case .success(let next) = apply(.environmentChanged(snapshot), to: world) else {
            Issue.record("Expected environmentChanged to succeed")
            return
        }

        #expect(next.activeSpace == nil)
        #expect(next.displays == [displayID: display(displayID, x: 0, width: 1200)])
        #expect(next.spaces == world.spaces)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
    }

    @Test("Reload config updates world config used by layout")
    func reloadConfigUpdatesWorldConfig() throws {
        let config = Config(
            keymap: Config.default.keymap,
            rules: [],
            zones: Config.default.zones,
            gaps: Gaps(inner: 8, outer: Insets(top: 1, left: 2, bottom: 3, right: 4)),
            border: .default,
            hud: .default,
            dragModifier: [.shift]
        )

        guard case .success(let next) = apply(.reloadConfig(config), to: World.empty) else {
            Issue.record("Expected reloadConfig to succeed")
            return
        }

        #expect(next.config == config)
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
        let tree = pushIntoTree(
            e,
            .up,
            pushIntoTree(d, .right, pushIntoTree(c, .left, pushIntoTree(b, .right, pushIntoTree(a, .left, .void))))
        )
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

        #expect(result[a] == CGRect(x: 0, y: 33, width: 504, height: 436.5))
        #expect(result[e] == CGRect(x: 504, y: 33, width: 504, height: 436.5))
        #expect(result[b] == CGRect(x: 1008, y: 33, width: 504, height: 436.5))
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
            Issue.record("Expected push without active Space to fail")
            return
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

        guard case .success(let next) = apply(.push(window, .left), to: world) else {
            Issue.record("Expected push to succeed")
            return
        }

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

        guard case .success(let next) = apply(.push(window, .right), to: world) else {
            Issue.record("Expected push to succeed")
            return
        }

        #expect(slots(in: try #require(next.spaces[space]?.displays[leftDisplay]?.tree)) == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(frames(for: try #require(next.spaces[space]?.displays[rightDisplay]?.tree), frame: try #require(next.displays[rightDisplay]?.visibleFrame))[window] == CGRect(x: 1500, y: 0, width: 500, height: 800))
        #expect(next.windowDisplay[window] == rightDisplay)
    }

    @Test("Swap primitive exchanges occupied leaves without changing zone paths")
    func swapPrimitiveExchangesLeavesOnly() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let tree = pushIntoTree(c, .left, pushIntoTree(b, .right, pushIntoTree(a, .left, .void)))
        let swapped = swapWindowsInTree(a, b, tree)

        #expect(slots(in: swapped) == [
            TreeSlot(path: [0, 0], occupancy: .occupied(b)),
            TreeSlot(path: [0, 1], occupancy: .occupied(c)),
            TreeSlot(path: [1], occupancy: .occupied(a))
        ])

        let result = frames(for: swapped)
        #expect(result[b] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[c] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(result[a] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Apply swap exchanges the focused source with its directional neighbor")
    func applySwapExchangesDirectionalNeighbor() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: pushIntoTree(b, .right, pushIntoTree(a, .left, .void)),
                            floating: []
                        )
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a), b: metadata(for: b)],
            windowDisplay: [a: displayID, b: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.swapInTree(a, .right), to: world) else {
            Issue.record("Expected swap right to succeed")
            return
        }

        let nextFrames: [WindowID: CGRect]
        switch flattenedLayout(of: next) {
        case .success(let layout):
            nextFrames = layout.tiled
        case .failure(let unsatisfiable):
            Issue.record("Expected swapped layout to solve, got \(unsatisfiable)")
            return
        }
        #expect(nextFrames[b] == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(nextFrames[a] == CGRect(x: 500, y: 0, width: 500, height: 800))
        #expect(next.spaces[space]?.focused == a)
        #expect(next.windowDisplay == [a: displayID, b: displayID])
    }

    @Test("Apply swap can exchange windows across adjacent displays")
    func applySwapAcrossDisplaysUpdatesDisplayOwnership() throws {
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
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
                        leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: pushIntoTree(a, .left, .void), floating: []),
                        rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: pushIntoTree(b, .right, .void), floating: [])
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a), b: metadata(for: b)],
            windowDisplay: [a: leftDisplay, b: rightDisplay],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.swapInTree(a, .right), to: world) else {
            Issue.record("Expected cross-display swap right to succeed")
            return
        }

        let nextFrames: [WindowID: CGRect]
        switch flattenedLayout(of: next) {
        case .success(let layout):
            nextFrames = layout.tiled
        case .failure(let unsatisfiable):
            Issue.record("Expected swapped layout to solve, got \(unsatisfiable)")
            return
        }
        #expect(nextFrames[b] == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(nextFrames[a] == CGRect(x: 1500, y: 0, width: 500, height: 800))
        #expect(next.windowDisplay == [a: rightDisplay, b: leftDisplay])
        #expect(next.spaces[space]?.focused == a)
    }

    @Test("Apply swap rejects untiled source windows")
    func applySwapRejectsUntiledSource() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(displayID: displayID, tree: pushIntoTree(b, .right, .void), floating: [a])
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a), b: metadata(for: b)],
            windowDisplay: [a: displayID, b: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.swapInTree(a, .right), to: world) == .failure(.windowIsFloating(a)))
    }

    @Test("Apply swap rejects missing directional neighbors")
    func applySwapRejectsMissingNeighbor() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(displayID: displayID, tree: pushIntoTree(a, .left, .void), floating: [])
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a)],
            windowDisplay: [a: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.swapInTree(a, .right), to: world) == .failure(.noNeighbor(.right)))
    }

    @Test("Apply swap rejects stale target leaves without metadata")
    func applySwapRejectsStaleTargetLeaf() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let stale = WindowID(raw: 2)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: pushIntoTree(stale, .right, pushIntoTree(a, .left, .void)),
                            floating: []
                        )
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a)],
            windowDisplay: [a: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.swapInTree(a, .right), to: world) == .failure(.windowNotFound(stale)))
    }

    @Test("Frame writes apply focused window last to avoid AX rematching during swaps")
    func frameWriteOrderMovesFocusedWindowLast() {
        let focused = WindowID(raw: 1)
        let other = WindowID(raw: 2)
        let layout = Layout(
            tiled: [
                focused: CGRect(x: 0, y: 0, width: 500, height: 800),
                other: CGRect(x: 500, y: 0, width: 500, height: 800)
            ],
            floatingZOrder: [],
            hidden: []
        )

        #expect(frameWriteOrder(for: layout, focused: focused) == [other, focused])
        #expect(frameWriteOrder(for: layout, focused: nil) == [focused, other])
    }

    @Test("Reset layout clears tree memory without dropping live windows")
    func resetLayoutClearsTreeMemoryOnly() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let displayInfo = DisplayInfo(
            id: display,
            slot: 0,
            fingerprint: nil,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let world = World(
            displays: [display: displayInfo],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: tree, floating: [second])
                    ],
                    focused: second
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second)
            ],
            windowDisplay: [
                first: display,
                second: display
            ],
            windowConstraints: [
                first: WindowConstraints(minWidth: 500)
            ],
            pendingRules: [second: .forceFloat],
            config: .default
        )

        guard case .success(let reset) = apply(.resetLayout, to: world) else {
            Issue.record("Expected resetLayout to succeed")
            return
        }

        #expect(reset.displays == [display: displayInfo])
        #expect(reset.windows == world.windows)
        #expect(reset.windowDisplay == world.windowDisplay)
        #expect(reset.spaces[space]?.displays[display]?.tree == .void)
        #expect(reset.spaces[space]?.displays[display]?.floating == [])
        #expect(reset.spaces[space]?.focused == nil)
        #expect(reset.windowConstraints.isEmpty)
        #expect(reset.pendingRules.isEmpty)
        #expect(reset.config == .default)
    }

    private func frames(
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

    private func metadata(
        for window: WindowID,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        isResizable: Bool = true
    ) -> WindowMetadata {
        WindowMetadata(
            id: window,
            bundleID: BundleID(raw: "com.example"),
            title: "Window \(window.raw)",
            role: "AXWindow",
            pid: 42,
            frame: frame,
            isResizable: isResizable,
            isMinimized: false
        )
    }

    private func display(_ id: DisplayID, x: Double, width: Double) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: Int(id.raw),
            fingerprint: nil,
            frame: CGRect(x: x, y: 0, width: width, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: width, height: 800)
        )
    }

    private func generatedDirectionSequences(maxLength: Int) -> [[Direction]] {
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

    private func isFiniteNonNegativeRect(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 0
            && rect.height >= 0
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

    private func cell(weight: Double, node: Node) throws -> Cell {
        switch Cell.create(weight: weight, node: node) {
        case .success(let cell):
            return cell
        case .failure(let error):
            throw error
        }
    }

    private func split(axis: Axis, cells: [Cell]) throws -> Split {
        switch Split.create(axis: axis, cells: cells) {
        case .success(let split):
            return split
        case .failure(let error):
            throw error
        }
    }
}
