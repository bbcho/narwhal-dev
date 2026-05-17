import CoreGraphics
import Testing
@testable import WinMgrCore

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

    private func metadata(for window: WindowID) -> WindowMetadata {
        WindowMetadata(
            id: window,
            bundleID: BundleID(raw: "com.example"),
            title: "Window \(window.raw)",
            role: "AXWindow",
            pid: 42,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isResizable: true,
            isMinimized: false
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
}
