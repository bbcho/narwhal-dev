import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
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

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: World.empty), "Expected environmentChanged to succeed")

        #expect(next.activeSpace == space)
        #expect(next.displays == displays)
        #expect(next.windows.keys.sorted { $0.raw < $1.raw } == [first, second])
        #expect(next.windowDisplay == [first: leftDisplay, second: rightDisplay])
        #expect(next.spaces[space]?.displays[leftDisplay]?.tree == .void)
        #expect(next.spaces[space]?.displays[leftDisplay]?.floating == [first])
        #expect(next.spaces[space]?.displays[rightDisplay]?.tree == .void)
        #expect(next.spaces[space]?.displays[rightDisplay]?.floating == [second])
    }

    @Test("Complete active Space snapshot preserves inactive Space tiling")
    func completeActiveSpaceSnapshotPreservesInactiveSpaceTiling() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceLeft = WindowID(raw: 11)
        let firstSpaceRight = WindowID(raw: 12)
        let secondSpaceLeft = WindowID(raw: 21)
        let secondSpaceRight = WindowID(raw: 22)
        let firstTree = pushIntoTree(firstSpaceRight, .right, pushIntoTree(firstSpaceLeft, .left, .void))
        let secondTree = pushIntoTree(secondSpaceRight, .right, pushIntoTree(secondSpaceLeft, .left, .void))
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: firstSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceLeft
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: secondTree, floating: [])],
                    focused: secondSpaceRight
                )
            ],
            windows: [
                firstSpaceLeft: metadata(for: firstSpaceLeft),
                firstSpaceRight: metadata(for: firstSpaceRight),
                secondSpaceLeft: metadata(for: secondSpaceLeft),
                secondSpaceRight: metadata(for: secondSpaceRight)
            ],
            windowDisplay: [
                firstSpaceLeft: displayID,
                firstSpaceRight: displayID,
                secondSpaceLeft: displayID,
                secondSpaceRight: displayID
            ],
            windowConstraints: [firstSpaceLeft: WindowConstraints(minWidth: 500)],
            pendingRules: [firstSpaceRight: .forceFloat],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: [
                    metadata(for: secondSpaceLeft, frame: CGRect(x: 0, y: 0, width: 600, height: 800)),
                    metadata(for: secondSpaceRight, frame: CGRect(x: 600, y: 0, width: 600, height: 800))
                ],
                quality: .complete
            )
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

        #expect(next.activeSpace == secondSpace)
        #expect(next.windows.keys.sorted { $0.raw < $1.raw } == [
            firstSpaceLeft,
            firstSpaceRight,
            secondSpaceLeft,
            secondSpaceRight
        ])
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[firstSpace]?.focused == firstSpaceLeft)
        #expect(next.windowConstraints[firstSpaceLeft] == WindowConstraints(minWidth: 500))
        #expect(next.pendingRules[firstSpaceRight] == .forceFloat)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.tree == secondTree)
        #expect(next.spaces[secondSpace]?.focused == secondSpaceRight)
    }

    @Test("Space-settle snapshots preserve every Space tree even with a wrong live set")
    func spaceSettleSnapshotPreservesEverySpaceTreeEvenWithWrongLiveSet() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceLeft = WindowID(raw: 11)
        let firstSpaceRight = WindowID(raw: 12)
        let secondSpaceLeft = WindowID(raw: 21)
        let secondSpaceRight = WindowID(raw: 22)
        let firstTree = pushIntoTree(firstSpaceRight, .right, pushIntoTree(firstSpaceLeft, .left, .void))
        let secondTree = pushIntoTree(secondSpaceRight, .right, pushIntoTree(secondSpaceLeft, .left, .void))
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: firstSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceLeft
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: secondTree, floating: [])],
                    focused: secondSpaceRight
                )
            ],
            windows: [
                firstSpaceLeft: metadata(for: firstSpaceLeft),
                firstSpaceRight: metadata(for: firstSpaceRight),
                secondSpaceLeft: metadata(for: secondSpaceLeft),
                secondSpaceRight: metadata(for: secondSpaceRight)
            ],
            windowDisplay: [
                firstSpaceLeft: displayID,
                firstSpaceRight: displayID,
                secondSpaceLeft: displayID,
                secondSpaceRight: displayID
            ],
            windowConstraints: [secondSpaceLeft: WindowConstraints(minWidth: 500)],
            pendingRules: [secondSpaceRight: .forceFloat],
            config: .default
        )
        let staleFirstSpaceFrame = CGRect(x: 100, y: 100, width: 500, height: 600)
        let snapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: [metadata(for: firstSpaceLeft, frame: staleFirstSpaceFrame)],
                quality: .complete
            ),
            preserveSpaceLayouts: true
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

        #expect(next.activeSpace == secondSpace)
        #expect(next.windows[firstSpaceLeft]?.frame == staleFirstSpaceFrame)
        #expect(next.windows[secondSpaceLeft] == metadata(for: secondSpaceLeft))
        #expect(next.windows[secondSpaceRight] == metadata(for: secondSpaceRight))
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[firstSpace]?.focused == firstSpaceLeft)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.tree == secondTree)
        #expect(next.spaces[secondSpace]?.focused == secondSpaceRight)
        #expect(next.windowConstraints == [secondSpaceLeft: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [secondSpaceRight: .forceFloat])
    }

    @Test("Active Space changes preserve every Space tree even without the app preservation flag")
    func activeSpaceChangePreservesEverySpaceTreeWithoutPreservationFlag() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceWindow = WindowID(raw: 11)
        let secondSpaceWindow = WindowID(raw: 21)
        let firstTree = pushIntoTree(firstSpaceWindow, .left, .void)
        let secondTree = pushIntoTree(secondSpaceWindow, .right, .void)
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: firstSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceWindow
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: secondTree, floating: [])],
                    focused: secondSpaceWindow
                )
            ],
            windows: [
                firstSpaceWindow: metadata(for: firstSpaceWindow),
                secondSpaceWindow: metadata(for: secondSpaceWindow)
            ],
            windowDisplay: [
                firstSpaceWindow: displayID,
                secondSpaceWindow: displayID
            ],
            windowConstraints: [secondSpaceWindow: WindowConstraints(minWidth: 500)],
            pendingRules: [secondSpaceWindow: .forceFloat],
            config: .default
        )
        let staleFirstSpaceFrame = CGRect(x: 100, y: 100, width: 500, height: 600)
        let snapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: [metadata(for: firstSpaceWindow, frame: staleFirstSpaceFrame)],
                quality: .complete
            )
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

        #expect(next.activeSpace == secondSpace)
        #expect(next.windows[firstSpaceWindow]?.frame == staleFirstSpaceFrame)
        #expect(next.windows[secondSpaceWindow] == metadata(for: secondSpaceWindow))
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.tree == secondTree)
        #expect(next.windowConstraints == [secondSpaceWindow: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [secondSpaceWindow: .forceFloat])
    }

    @Test("Post-transition cleanup preserves inactive Space tiling while reconciling active Space")
    func postTransitionCleanupPreservesInactiveSpaceTilingWhileReconcilingActiveSpace() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceWindow = WindowID(raw: 11)
        let secondSpaceLive = WindowID(raw: 21)
        let secondSpaceClosed = WindowID(raw: 22)
        let firstTree = pushIntoTree(firstSpaceWindow, .left, .void)
        let secondTree = pushIntoTree(secondSpaceClosed, .right, pushIntoTree(secondSpaceLive, .left, .void))
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: secondSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceWindow
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: secondTree, floating: [])],
                    focused: secondSpaceClosed
                )
            ],
            windows: [
                firstSpaceWindow: metadata(for: firstSpaceWindow),
                secondSpaceLive: metadata(for: secondSpaceLive),
                secondSpaceClosed: metadata(for: secondSpaceClosed)
            ],
            windowDisplay: [
                firstSpaceWindow: displayID,
                secondSpaceLive: displayID,
                secondSpaceClosed: displayID
            ],
            windowConstraints: [
                firstSpaceWindow: WindowConstraints(minWidth: 500),
                secondSpaceClosed: WindowConstraints(minWidth: 600)
            ],
            pendingRules: [
                firstSpaceWindow: .forceFloat,
                secondSpaceClosed: .forceFloat
            ],
            config: .default
        )
        let liveFrame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let snapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: [metadata(for: secondSpaceLive, frame: liveFrame)],
                quality: .complete
            )
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

        #expect(next.activeSpace == secondSpace)
        #expect(next.windows[firstSpaceWindow] == metadata(for: firstSpaceWindow))
        #expect(next.windows[secondSpaceLive]?.frame == liveFrame)
        #expect(next.windows[secondSpaceClosed] == nil)
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[firstSpace]?.focused == firstSpaceWindow)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.tree == pruneTree(secondTree, keeping: [secondSpaceLive]))
        #expect(next.spaces[secondSpace]?.displays[displayID]?.floating == [])
        #expect(next.spaces[secondSpace]?.focused == nil)
        #expect(next.windowConstraints == [firstSpaceWindow: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [firstSpaceWindow: .forceFloat])
    }

    @Test("Post-transition cleanup rebuilds active floating list from live active windows only")
    func postTransitionCleanupRebuildsActiveFloatingFromLiveActiveWindowsOnly() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceWindow = WindowID(raw: 11)
        let activeLiveFloating = WindowID(raw: 21)
        let activeClosedFloating = WindowID(raw: 22)
        let firstTree = pushIntoTree(firstSpaceWindow, .left, .void)
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: secondSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceWindow
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: .void,
                            floating: [activeLiveFloating, activeClosedFloating]
                        )
                    ],
                    focused: activeClosedFloating
                )
            ],
            windows: [
                firstSpaceWindow: metadata(for: firstSpaceWindow),
                activeLiveFloating: metadata(for: activeLiveFloating),
                activeClosedFloating: metadata(for: activeClosedFloating)
            ],
            windowDisplay: [
                firstSpaceWindow: displayID,
                activeLiveFloating: displayID,
                activeClosedFloating: displayID
            ],
            windowConstraints: [
                firstSpaceWindow: WindowConstraints(minWidth: 500),
                activeClosedFloating: WindowConstraints(minWidth: 600)
            ],
            pendingRules: [
                firstSpaceWindow: .forceFloat,
                activeClosedFloating: .forceFloat
            ],
            config: .default
        )
        let liveFrame = CGRect(x: 240, y: 90, width: 700, height: 500)
        let snapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: [metadata(for: activeLiveFloating, frame: liveFrame)],
                quality: .complete
            )
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

        #expect(next.windows[firstSpaceWindow] == metadata(for: firstSpaceWindow))
        #expect(next.windows[activeLiveFloating]?.frame == liveFrame)
        #expect(next.windows[activeClosedFloating] == nil)
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.tree == .void)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.floating == [activeLiveFloating])
        #expect(next.spaces[secondSpace]?.focused == nil)
        #expect(next.windowConstraints == [firstSpaceWindow: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [firstSpaceWindow: .forceFloat])
    }

    @Test("Contaminated active Space snapshots preserve inactive Space memory")
    func contaminatedActiveSpaceSnapshotsPreserveInactiveSpaceMemory() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceWindow = WindowID(raw: 11)
        let secondSpaceFloating = WindowID(raw: 21)
        let firstTree = pushIntoTree(firstSpaceWindow, .left, .void)
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: secondSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceWindow
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [
                        displayID: DisplaySpaceState(displayID: displayID, tree: .void, floating: [secondSpaceFloating])
                    ],
                    focused: secondSpaceFloating
                )
            ],
            windows: [
                firstSpaceWindow: metadata(for: firstSpaceWindow),
                secondSpaceFloating: metadata(for: secondSpaceFloating)
            ],
            windowDisplay: [
                firstSpaceWindow: displayID,
                secondSpaceFloating: displayID
            ],
            windowConstraints: [firstSpaceWindow: WindowConstraints(minWidth: 500)],
            pendingRules: [firstSpaceWindow: .forceFloat],
            config: .default
        )
        let inactiveFrame = CGRect(x: 100, y: 100, width: 500, height: 600)
        let activeFrame = CGRect(x: 650, y: 100, width: 500, height: 600)
        let snapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: [
                    metadata(for: firstSpaceWindow, frame: inactiveFrame),
                    metadata(for: secondSpaceFloating, frame: activeFrame)
                ],
                quality: .complete
            )
        )

        #expect(environmentSnapshotPreservesSpaceLayouts(snapshot, in: world))
        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

        #expect(next.windows[firstSpaceWindow]?.frame == inactiveFrame)
        #expect(next.windows[secondSpaceFloating]?.frame == activeFrame)
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[firstSpace]?.focused == firstSpaceWindow)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.floating == [secondSpaceFloating])
        #expect(next.windowConstraints == [firstSpaceWindow: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [firstSpaceWindow: .forceFloat])
    }

    @Test("Removing a closed window from the active Space preserves inactive Space memory")
    func activeSpaceLivePruningPreservesInactiveSpaceMemory() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceWindow = WindowID(raw: 11)
        let activeLive = WindowID(raw: 21)
        let activeClosed = WindowID(raw: 22)
        let firstTree = pushIntoTree(firstSpaceWindow, .left, .void)
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: secondSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceWindow
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: .void,
                            floating: [activeLive, activeClosed]
                        )
                    ],
                    focused: activeClosed
                )
            ],
            windows: [
                firstSpaceWindow: metadata(for: firstSpaceWindow),
                activeLive: metadata(for: activeLive),
                activeClosed: metadata(for: activeClosed)
            ],
            windowDisplay: [
                firstSpaceWindow: displayID,
                activeLive: displayID,
                activeClosed: displayID
            ],
            windowConstraints: [
                firstSpaceWindow: WindowConstraints(minWidth: 500),
                activeClosed: WindowConstraints(minWidth: 600)
            ],
            pendingRules: [
                firstSpaceWindow: .forceFloat,
                activeClosed: .forceFloat
            ],
            config: .default
        )

        let next = removeWindowsFromActiveSpace([activeClosed], in: world)

        #expect(next.windows[firstSpaceWindow] == metadata(for: firstSpaceWindow))
        #expect(next.windows[activeLive] == metadata(for: activeLive))
        #expect(next.windows[activeClosed] == nil)
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[firstSpace]?.focused == firstSpaceWindow)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.floating == [activeLive])
        #expect(next.spaces[secondSpace]?.focused == nil)
        #expect(next.windowConstraints == [firstSpaceWindow: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [firstSpaceWindow: .forceFloat])
    }

    @Test("Display-change preservation defers active close pruning until display settled cleanup")
    func displayChangePreservationDefersActiveClosePruningUntilDisplaySettledCleanup() throws {
        let displayID = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let live = WindowID(raw: 11)
        let closed = WindowID(raw: 12)
        let tree = pushIntoTree(closed, .right, pushIntoTree(live, .left, .void))
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [])],
                    focused: closed
                )
            ],
            windows: [
                live: metadata(for: live),
                closed: metadata(for: closed)
            ],
            windowDisplay: [
                live: displayID,
                closed: displayID
            ],
            windowConstraints: [closed: WindowConstraints(minWidth: 600)],
            pendingRules: [closed: .forceFloat],
            config: .default
        )
        let liveSnapshotWindows = [metadata(for: live)]

        let displayChangedPolicy = environmentRefreshPolicy(
            for: [.windowClosed(closed), .displayChanged],
            duringSpaceTransition: false
        )
        #expect(displayChangedPolicy.scheduleDeferredCleanup)
        #expect(!displayChangedPolicy.persistRestore)
        #expect(displayChangedPolicy.reconciliationMode == .preserveLayouts)

        let preservedSnapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: liveSnapshotWindows, quality: .complete),
            preserveSpaceLayouts: displayChangedPolicy.preserveSpaceLayouts,
            reconciliationMode: displayChangedPolicy.reconciliationMode
        )
        let preserved = try requireWorld(
            apply(.environmentChanged(preservedSnapshot), to: world),
            "Expected display-change refresh to preserve layout memory"
        )

        #expect(Set(occupiedWindows(in: preserved.spaces[activeSpace]?.displays[displayID]?.tree ?? .void)) == [live, closed])
        #expect(preserved.windows[closed] == metadata(for: closed))
        #expect(preserved.windowConstraints == [closed: WindowConstraints(minWidth: 600)])
        #expect(preserved.pendingRules == [closed: .forceFloat])

        let displaySettledPolicy = environmentRefreshPolicy(
            for: [.displaySettled],
            duringSpaceTransition: false
        )
        #expect(!displaySettledPolicy.persistRestore)
        #expect(displaySettledPolicy.applyPendingTileRules)
        #expect(displaySettledPolicy.reconciliationMode == .displayTopologySettled)
        #expect(displaySettledPolicy.reflowTiledLayout)

        let settledSnapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: liveSnapshotWindows, quality: .complete),
            preserveSpaceLayouts: displaySettledPolicy.preserveSpaceLayouts,
            reconciliationMode: displaySettledPolicy.reconciliationMode
        )
        let cleaned = try requireWorld(
            apply(.environmentChanged(settledSnapshot), to: preserved),
            "Expected display-settled cleanup to prune active closed windows"
        )

        #expect(Set(occupiedWindows(in: cleaned.spaces[activeSpace]?.displays[displayID]?.tree ?? .void)) == [live])
        #expect(cleaned.windows[closed] == nil)
        #expect(cleaned.windowDisplay[closed] == nil)
        #expect(cleaned.windowConstraints.isEmpty)
        #expect(cleaned.pendingRules.isEmpty)
        #expect(cleaned.spaces[activeSpace]?.focused == nil)
    }

    @Test("Explicit window close prunes active tiling before preserving replacement refresh")
    func explicitWindowClosePrunesActiveTilingBeforePreservingReplacementRefresh() throws {
        let displayID = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let live = WindowID(raw: 11)
        let closed = WindowID(raw: 12)
        let replacement = WindowID(raw: 13)
        let tree = pushIntoTree(closed, .left, pushIntoTree(live, .right, .void))
        let display = self.display(displayID, x: 0, width: 1200)
        let world = World(
            displays: [displayID: display],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [])],
                    focused: closed
                )
            ],
            windows: [
                live: metadata(for: live),
                closed: metadata(for: closed)
            ],
            windowDisplay: [
                live: displayID,
                closed: displayID
            ],
            windowConstraints: [closed: WindowConstraints(minWidth: 600)],
            pendingRules: [closed: .forceFloat],
            config: .default
        )

        let afterClose = try requireWorld(
            apply(.windowClosed(closed), to: world),
            "Expected explicit close to prune closed active tile"
        )
        let replacementMetadata = WindowMetadata(
            id: replacement,
            bundleID: BundleID(raw: "com.example.app"),
            title: "Replacement",
            role: "AXWindow",
            pid: 13,
            frame: CGRect(x: 50, y: 50, width: 800, height: 600),
            isResizable: true,
            isMinimized: false
        )
        let preservingSnapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: [metadata(for: live), replacementMetadata],
                quality: .complete
            ),
            preserveSpaceLayouts: true,
            reconciliationMode: .preserveLayouts
        )
        let refreshed = try requireWorld(
            apply(.environmentChanged(preservingSnapshot), to: afterClose),
            "Expected preserving refresh to keep explicit close pruned"
        )

        let activeTree = refreshed.spaces[activeSpace]?.displays[displayID]?.tree ?? .void
        #expect(Set(occupiedWindows(in: activeTree)) == [live])
        #expect(refreshed.windows[closed] == nil)
        #expect(refreshed.windowDisplay[closed] == nil)
        #expect(refreshed.windowConstraints[closed] == nil)
        #expect(refreshed.pendingRules[closed] == nil)
        #expect(refreshed.spaces[activeSpace]?.focused == nil)
        #expect(refreshed.windows[replacement] == replacementMetadata)

        let borderTargets = try tiledBorderTargets(of: refreshed).get()
        #expect(Set(borderTargets.map { $0.windowID }) == [live])
    }

    @Test("Removing windows from the active Space keeps metadata for windows still tracked in inactive Spaces")
    func activeSpacePruningKeepsMetadataForWindowsStillTrackedInInactiveSpaces() throws {
        let displayID = DisplayID(raw: 1)
        let inactiveSpace = SpaceID(raw: 1)
        let activeSpace = SpaceID(raw: 2)
        let sharedWindow = WindowID(raw: 11)
        let activeClosed = WindowID(raw: 21)
        let inactiveTree = pushIntoTree(sharedWindow, .left, .void)
        let world = World(
            displays: [displayID: self.display(displayID, x: 0, width: 1200)],
            activeSpace: activeSpace,
            spaces: [
                inactiveSpace: SpaceState(
                    id: inactiveSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: inactiveTree, floating: [])],
                    focused: sharedWindow
                ),
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: .void,
                            floating: [sharedWindow, activeClosed]
                        )
                    ],
                    focused: activeClosed
                )
            ],
            windows: [
                sharedWindow: metadata(for: sharedWindow),
                activeClosed: metadata(for: activeClosed)
            ],
            windowDisplay: [
                sharedWindow: displayID,
                activeClosed: displayID
            ],
            windowConstraints: [
                sharedWindow: WindowConstraints(minWidth: 500),
                activeClosed: WindowConstraints(minWidth: 600)
            ],
            pendingRules: [
                sharedWindow: .forceFloat,
                activeClosed: .forceFloat
            ],
            config: .default
        )

        let next = removeWindowsFromActiveSpace([sharedWindow, activeClosed], in: world)

        #expect(next.windows[sharedWindow] == metadata(for: sharedWindow))
        #expect(next.windows[activeClosed] == nil)
        #expect(next.windowDisplay == [sharedWindow: displayID])
        #expect(next.windowConstraints == [sharedWindow: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [sharedWindow: .forceFloat])
        #expect(next.spaces[inactiveSpace]?.displays[displayID]?.tree == inactiveTree)
        #expect(next.spaces[activeSpace]?.displays[displayID]?.floating == [])
    }

    @Test("Post-transition cleanup applies open rules to windows first seen during preservation")
    func postTransitionCleanupAppliesOpenRulesToWindowsFirstSeenDuringPreservation() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstSpaceWindow = WindowID(raw: 11)
        let newWindow = WindowID(raw: 21)
        let firstTree = pushIntoTree(firstSpaceWindow, .left, .void)
        let display = self.display(displayID, x: 0, width: 1200)
        let config = Config(
            keymap: Config.default.keymap,
            rules: [
                WindowRule(
                    predicate: .bundleID("com.example"),
                    action: .tileToZone(ZoneID(raw: "center"))
                )
            ],
            zones: Config.default.zones,
            gaps: Config.default.gaps,
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier
        )
        let world = World(
            displays: [displayID: display],
            activeSpace: firstSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstSpaceWindow
                )
            ],
            windows: [firstSpaceWindow: metadata(for: firstSpaceWindow)],
            windowDisplay: [firstSpaceWindow: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
        let liveMetadata = metadata(
            for: newWindow,
            bundleID: "com.example",
            frame: CGRect(x: 600, y: 0, width: 600, height: 800)
        )
        let preservingSnapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: [liveMetadata], quality: .complete),
            preserveSpaceLayouts: true
        )

        let preservingWorld = try requireWorld(
            apply(.environmentChanged(preservingSnapshot), to: world),
            "Expected preserving environmentChanged to succeed"
        )

        #expect(preservingWorld.windows[newWindow] == liveMetadata)
        #expect(preservingWorld.spaces[secondSpace] == nil)
        #expect(preservingWorld.pendingRules.isEmpty)

        let cleanupSnapshot = EnvironmentSnapshot(
            activeSpace: secondSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: [liveMetadata], quality: .complete)
        )

        let next = try requireWorld(
            apply(.environmentChanged(cleanupSnapshot), to: preservingWorld),
            "Expected cleanup environmentChanged to succeed"
        )

        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.floating == [newWindow])
        #expect(next.pendingRules == [newWindow: .tileToZone(ZoneID(raw: "center"))])
    }

    @Test("Bulk untracked complete snapshots preserve Space layout memory")
    func bulkUntrackedCompleteSnapshotsPreserveSpaceLayoutMemory() throws {
        let displayID = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let inactiveSpace = SpaceID(raw: 2)
        let activeTiled = WindowID(raw: 11)
        let activeFloating = WindowID(raw: 12)
        let inactiveTiled = WindowID(raw: 21)
        let activeTree = pushIntoTree(activeTiled, .left, .void)
        let inactiveTree = pushIntoTree(inactiveTiled, .right, .void)
        let display = self.display(displayID, x: 0, width: 1200)
        let untrackedWindows = (0..<6).map { WindowID(raw: CGWindowID(100 + $0)) }
        let world = World(
            displays: [displayID: display],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: activeTree,
                            floating: [activeFloating]
                        )
                    ],
                    focused: activeTiled
                ),
                inactiveSpace: SpaceState(
                    id: inactiveSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: inactiveTree, floating: [])],
                    focused: inactiveTiled
                )
            ],
            windows: [
                activeTiled: metadata(for: activeTiled),
                activeFloating: metadata(for: activeFloating),
                inactiveTiled: metadata(for: inactiveTiled)
            ],
            windowDisplay: [
                activeTiled: displayID,
                activeFloating: displayID,
                inactiveTiled: displayID
            ],
            windowConstraints: [inactiveTiled: WindowConstraints(minWidth: 500)],
            pendingRules: [inactiveTiled: .forceFloat],
            config: .default
        )
        let liveWindows = [
            metadata(for: activeTiled),
            metadata(for: activeFloating)
        ] + untrackedWindows.map { metadata(for: $0) }
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: liveWindows, quality: .complete)
        )

        #expect(environmentSnapshotPreservesSpaceLayouts(snapshot, in: world))
        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

        #expect(next.spaces[activeSpace]?.displays[displayID]?.tree == activeTree)
        #expect(next.spaces[activeSpace]?.displays[displayID]?.floating == [activeFloating])
        #expect(next.spaces[inactiveSpace]?.displays[displayID]?.tree == inactiveTree)
        for windowID in untrackedWindows {
            #expect(next.windows[windowID] == metadata(for: windowID))
        }
        #expect(next.windowConstraints == [inactiveTiled: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [inactiveTiled: .forceFloat])
    }

    @Test("Bulk untracked snapshots with missing active windows still reconcile active closures")
    func bulkUntrackedSnapshotsWithMissingActiveWindowsStillReconcileActiveClosures() throws {
        let displayID = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let activeLive = WindowID(raw: 11)
        let activeClosed = WindowID(raw: 12)
        let activeTree = pushIntoTree(activeClosed, .right, pushIntoTree(activeLive, .left, .void))
        let display = self.display(displayID, x: 0, width: 1200)
        let untrackedWindows = (0..<8).map { WindowID(raw: CGWindowID(200 + $0)) }
        let world = World(
            displays: [displayID: display],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: activeTree, floating: [])],
                    focused: activeClosed
                )
            ],
            windows: [
                activeLive: metadata(for: activeLive),
                activeClosed: metadata(for: activeClosed)
            ],
            windowDisplay: [
                activeLive: displayID,
                activeClosed: displayID
            ],
            windowConstraints: [activeClosed: WindowConstraints(minWidth: 500)],
            pendingRules: [activeClosed: .forceFloat],
            config: .default
        )
        let liveWindows = [metadata(for: activeLive)] + untrackedWindows.map { metadata(for: $0) }
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: liveWindows, quality: .complete)
        )

        #expect(!environmentSnapshotPreservesSpaceLayouts(snapshot, in: world))
        let next = try requireWorld(
            apply(.environmentChanged(snapshot), to: world),
            "Expected active closure reconciliation to succeed"
        )

        #expect(next.windows[activeClosed] == nil)
        #expect(next.windowConstraints.isEmpty)
        #expect(next.pendingRules.isEmpty)
        #expect(next.spaces[activeSpace]?.focused == nil)
        #expect(next.spaces[activeSpace]?.displays[displayID].map { occupiedWindows(in: $0.tree) } == [activeLive])
        for windowID in untrackedWindows {
            #expect(next.spaces[activeSpace]?.displays[displayID]?.floating.contains(windowID) == true)
        }
    }

    @Test("Bulk untracked snapshots without existing active memory are normal startup discovery")
    func bulkUntrackedSnapshotsWithoutExistingActiveMemoryAreNormalStartupDiscovery() throws {
        let displayID = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let display = self.display(displayID, x: 0, width: 1200)
        let startupWindows = (0..<7).map { WindowID(raw: CGWindowID(300 + $0)) }
        let world = World(
            displays: [displayID: display],
            activeSpace: activeSpace,
            spaces: [activeSpace: SpaceState(id: activeSpace, displays: [:], focused: nil)],
            windows: [:],
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(
                windows: startupWindows.map { metadata(for: $0) },
                quality: .complete
            )
        )

        #expect(!environmentSnapshotPreservesSpaceLayouts(snapshot, in: world))
        let next = try requireWorld(
            apply(.environmentChanged(snapshot), to: world),
            "Expected startup discovery to track visible windows"
        )

        #expect(Set(next.windows.keys) == Set(startupWindows))
        #expect(next.spaces[activeSpace]?.displays[displayID]?.floating == startupWindows)
    }

    @Test("Small active Space window bursts are not treated as Space contamination")
    func smallActiveSpaceWindowBurstsAreNotTreatedAsSpaceContamination() throws {
        let displayID = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let existing = WindowID(raw: 11)
        let display = self.display(displayID, x: 0, width: 1200)
        let openedWindows = (0..<4).map { WindowID(raw: CGWindowID(400 + $0)) }
        let world = World(
            displays: [displayID: display],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: .void, floating: [existing])],
                    focused: existing
                )
            ],
            windows: [existing: metadata(for: existing)],
            windowDisplay: [existing: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let liveWindows = [metadata(for: existing)] + openedWindows.map { metadata(for: $0) }
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: liveWindows, quality: .complete)
        )

        #expect(!environmentSnapshotPreservesSpaceLayouts(snapshot, in: world))
        let next = try requireWorld(
            apply(.environmentChanged(snapshot), to: world),
            "Expected small active window burst to reconcile"
        )

        #expect(next.spaces[activeSpace]?.displays[displayID]?.floating == [existing] + openedWindows)
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

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: oldWorld), "Expected environmentChanged to succeed")

        #expect(next.activeSpace == nil)
        #expect(next.windows == [window: metadata(for: window, frame: CGRect(x: 100, y: 50, width: 400, height: 300))])
        #expect(next.windowDisplay == [window: displayID])
        #expect(next.spaces[SpaceID(raw: 1)] == nil)
        #expect(next.spaces[oldSpace]?.displays[displayID]?.tree == oldTree)
        #expect(next.spaces[oldSpace]?.focused == window)
        #expect(next.windowConstraints == [window: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [window: .forceFloat])
    }

    @Test("Complete snapshot without active Space preserves known Space tiling when live set changes")
    func completeSnapshotWithoutActiveSpacePreservesKnownSpaceTilingWhenLiveSetChanges() throws {
        let displayID = DisplayID(raw: 7)
        let firstSpace = SpaceID(raw: 99)
        let secondSpace = SpaceID(raw: 100)
        let firstWindow = WindowID(raw: 41)
        let secondWindow = WindowID(raw: 42)
        let liveUnknownSpaceWindow = WindowID(raw: 43)
        let firstTree = pushIntoTree(firstWindow, .left, .void)
        let secondTree = pushIntoTree(secondWindow, .right, .void)
        let display = self.display(displayID, x: 0, width: 1000)
        let oldWorld = World(
            displays: [displayID: display],
            activeSpace: firstSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: firstTree, floating: [])],
                    focused: firstWindow
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: secondTree, floating: [])],
                    focused: secondWindow
                )
            ],
            windows: [
                firstWindow: metadata(for: firstWindow),
                secondWindow: metadata(for: secondWindow)
            ],
            windowDisplay: [
                firstWindow: displayID,
                secondWindow: displayID
            ],
            windowConstraints: [firstWindow: WindowConstraints(minWidth: 500)],
            pendingRules: [secondWindow: .forceFloat],
            config: .default
        )
        let liveMetadata = metadata(
            for: liveUnknownSpaceWindow,
            frame: CGRect(x: 100, y: 50, width: 400, height: 300)
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: nil,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: [liveMetadata], quality: .complete)
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: oldWorld), "Expected environmentChanged to succeed")

        #expect(next.activeSpace == nil)
        #expect(next.windows[firstWindow] == metadata(for: firstWindow))
        #expect(next.windows[secondWindow] == metadata(for: secondWindow))
        #expect(next.windows[liveUnknownSpaceWindow] == liveMetadata)
        #expect(next.windowDisplay == [
            firstWindow: displayID,
            secondWindow: displayID,
            liveUnknownSpaceWindow: displayID
        ])
        #expect(next.spaces[firstSpace]?.displays[displayID]?.tree == firstTree)
        #expect(next.spaces[secondSpace]?.displays[displayID]?.tree == secondTree)
        #expect(next.windowConstraints == [firstWindow: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [secondWindow: .forceFloat])
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

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

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

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

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

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world), "Expected environmentChanged to succeed")

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

        let next = try requireWorld(apply(.reloadConfig(config), to: World.empty), "Expected reloadConfig to succeed")

        #expect(next.config == config)
    }
}
