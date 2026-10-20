import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
    @Test("Reset layouts only operate on active Space windows")
    func resetLayoutsOnlyOperateOnActiveSpaceWindows() throws {
        let displayID = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let inactiveSpace = SpaceID(raw: 2)
        let activeTiled = WindowID(raw: 11)
        let activeFloating = WindowID(raw: 12)
        let inactiveTiled = WindowID(raw: 21)
        let activeTree = pushIntoTree(activeTiled, .left, .void)
        let inactiveTree = pushIntoTree(inactiveTiled, .right, .void)
        let world = World(
            displays: [displayID: self.display(displayID, x: 0, width: 1200)],
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
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        var generator = SeededGenerator(seed: 1)
        let shuffled = try requireSuccess(
            shuffledResetLayout(in: world, using: &generator),
            "Expected shuffled reset layout to succeed"
        )
        let cascaded = try requireSuccess(cascadeResetLayout(in: world), "Expected cascade reset layout to succeed")

        #expect(Set(shuffled.tiled.keys) == [activeTiled, activeFloating])
        #expect(Set(cascaded.tiled.keys) == [activeTiled, activeFloating])
    }

    @Test("Active Space reset preserves inactive Space layout memory")
    func activeSpaceResetPreservesInactiveSpaceLayoutMemory() throws {
        let displayID = DisplayID(raw: 1)
        let inactiveSpace = SpaceID(raw: 1)
        let activeSpace = SpaceID(raw: 2)
        let inactiveWindow = WindowID(raw: 11)
        let sharedWindow = WindowID(raw: 12)
        let activeWindow = WindowID(raw: 21)
        let inactiveTree = pushIntoTree(sharedWindow, .right, pushIntoTree(inactiveWindow, .left, .void))
        let activeTree = pushIntoTree(activeWindow, .left, .void)
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
                            tree: activeTree,
                            floating: [sharedWindow]
                        )
                    ],
                    focused: activeWindow
                )
            ],
            windows: [
                inactiveWindow: metadata(for: inactiveWindow),
                sharedWindow: metadata(for: sharedWindow),
                activeWindow: metadata(for: activeWindow)
            ],
            windowDisplay: [
                inactiveWindow: displayID,
                sharedWindow: displayID,
                activeWindow: displayID
            ],
            windowConstraints: [
                inactiveWindow: WindowConstraints(minWidth: 500),
                sharedWindow: WindowConstraints(minWidth: 550),
                activeWindow: WindowConstraints(minWidth: 600)
            ],
            pendingRules: [
                inactiveWindow: .forceFloat,
                sharedWindow: .forceFloat,
                activeWindow: .forceFloat
            ],
            config: .default
        )

        let next = resetActiveSpaceTilingState(in: world)

        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.spaces[inactiveSpace]?.displays[displayID]?.tree == inactiveTree)
        #expect(next.spaces[inactiveSpace]?.focused == sharedWindow)
        #expect(next.spaces[activeSpace]?.displays[displayID]?.tree == .void)
        #expect(next.spaces[activeSpace]?.displays[displayID]?.floating == [])
        #expect(next.spaces[activeSpace]?.focused == nil)
        #expect(next.windowConstraints == [
            inactiveWindow: WindowConstraints(minWidth: 500),
            sharedWindow: WindowConstraints(minWidth: 550)
        ])
        #expect(next.pendingRules == [
            inactiveWindow: .forceFloat,
            sharedWindow: .forceFloat
        ])
    }

    @Test("User Space switching keeps tile memory and commands local")
    func userSpaceSwitchingKeepsTileMemoryAndCommandsLocal() throws {
        let displayID = DisplayID(raw: 1)
        let spaceFour = SpaceID(raw: 4)
        let spaceThree = SpaceID(raw: 3)
        let rightTile = WindowID(raw: 31639)
        let topLeftTile = WindowID(raw: 73384)
        let bottomLeftTile = WindowID(raw: 41662)
        let lowerRightTile = WindowID(raw: 72825)
        let spaceFourFloating = WindowID(raw: 70013)
        let spaceThreeLeft = WindowID(raw: 77623)
        let spaceThreeRight = WindowID(raw: 75807)
        let spaceThreeFloating = WindowID(raw: 75962)
        let display = self.display(displayID, x: 0, width: 3840)
        let spaceFourWindows = [rightTile, topLeftTile, bottomLeftTile, lowerRightTile, spaceFourFloating]
        let spaceThreeWindows = [spaceThreeLeft, spaceThreeRight, spaceThreeFloating]
        let allWindows = spaceFourWindows + spaceThreeWindows

        var world = try requireWorld(
            apply(
                .environmentChanged(EnvironmentSnapshot(
                    activeSpace: spaceFour,
                    displays: [displayID: display],
                    axSnapshot: AXWindowSnapshot(windows: spaceFourWindows.map { metadata(for: $0) }, quality: .complete)
                )),
                to: World.empty
            ),
            "Expected initial Space 4 refresh to succeed"
        )
        world = try requireWorld(apply(.push(rightTile, .right), to: world), "Expected first Space 4 push to succeed")
        world = try requireWorld(apply(.push(topLeftTile, .left), to: world), "Expected second Space 4 push to succeed")
        world = try requireWorld(apply(.push(bottomLeftTile, .left), to: world), "Expected third Space 4 push to succeed")
        world = try requireWorld(apply(.push(lowerRightTile, .left), to: world), "Expected fourth Space 4 push to succeed")

        let expectedSpaceFour = try requireSpace(world, spaceFour, "Expected Space 4 to exist after tiling")
        let expectedSpaceFourTree = expectedSpaceFour.displays[displayID]?.tree
        #expect(expectedSpaceFourTree.map { Set(occupiedWindows(in: $0)) } == [
            rightTile,
            topLeftTile,
            bottomLeftTile,
            lowerRightTile
        ])
        #expect(expectedSpaceFour.displays[displayID]?.floating == [spaceFourFloating])

        let noisySpaceThreeSnapshot = EnvironmentSnapshot(
            activeSpace: spaceThree,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: allWindows.map { metadata(for: $0) }, quality: .complete)
        )
        #expect(environmentSnapshotPreservesSpaceLayouts(noisySpaceThreeSnapshot, in: world))
        world = try requireWorld(
            apply(.environmentChanged(noisySpaceThreeSnapshot), to: world),
            "Expected noisy switch to Space 3 to preserve existing Space memory"
        )
        #expect(world.spaces[spaceFour] == expectedSpaceFour)

        world = try requireWorld(apply(.push(spaceThreeRight, .right), to: world), "Expected Space 3 right push to succeed")
        world = try requireWorld(apply(.push(spaceThreeLeft, .left), to: world), "Expected Space 3 left push to succeed")
        world = try requireWorld(
            apply(.windowOpened(metadata(for: spaceThreeFloating)), to: world),
            "Expected active Space 3 floating window to be tracked"
        )
        let focusedSpaceThree = try requireWorld(
            apply(.focusCycle(.next), to: world),
            "Expected Space 3 focus cycle to succeed"
        )
        #expect(focusedSpaceThree.spaces[spaceThree]?.focused == spaceThreeFloating)
        world = focusedSpaceThree

        let expectedSpaceThree = try requireSpace(world, spaceThree, "Expected Space 3 to exist after user actions")
        #expect(Set(occupiedWindows(in: expectedSpaceThree.displays[displayID]?.tree ?? .void)) == [
            spaceThreeLeft,
            spaceThreeRight
        ])
        #expect(expectedSpaceThree.displays[displayID]?.floating == [spaceThreeFloating])
        #expect(world.spaces[spaceFour] == expectedSpaceFour)

        let noisySpaceFourSnapshot = EnvironmentSnapshot(
            activeSpace: spaceFour,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: allWindows.map { metadata(for: $0) }, quality: .complete)
        )
        #expect(environmentSnapshotPreservesSpaceLayouts(noisySpaceFourSnapshot, in: world))
        world = try requireWorld(
            apply(.environmentChanged(noisySpaceFourSnapshot), to: world),
            "Expected noisy switch back to Space 4 to preserve per-Space memory"
        )

        #expect(world.spaces[spaceFour] == expectedSpaceFour)
        #expect(world.spaces[spaceThree] == expectedSpaceThree)

        let spaceFourLayout = try requireLayout(flattenedLayout(of: world), "Expected Space 4 layout to flatten")
        #expect(Set(spaceFourLayout.tiled.keys) == [
            rightTile,
            topLeftTile,
            bottomLeftTile,
            lowerRightTile
        ])
        #expect(spaceFourLayout.floatingZOrder == [spaceFourFloating])

        let focusedSpaceFour = try requireWorld(
            apply(.focusCycle(.next), to: world),
            "Expected Space 4 focus cycle to stay local"
        )
        #expect(focusedSpaceFour.spaces[spaceFour]?.focused == spaceFourFloating)

        var shuffleGenerator = SeededGenerator(seed: 2)
        let spaceFourShuffle = try requireSuccess(
            shuffledResetLayout(in: focusedSpaceFour, using: &shuffleGenerator),
            "Expected Space 4 shuffle plan to succeed"
        )
        #expect(Set(spaceFourShuffle.tiled.keys) == Set(spaceFourWindows))
        #expect(spaceFourShuffle.tiled[spaceThreeLeft] == nil)
        #expect(spaceFourShuffle.tiled[spaceThreeRight] == nil)
        #expect(spaceFourShuffle.tiled[spaceThreeFloating] == nil)

        var worldOnSpaceThree = try requireWorld(
            apply(.environmentChanged(noisySpaceThreeSnapshot), to: focusedSpaceFour),
            "Expected noisy switch back to Space 3 to preserve per-Space memory"
        )
        let spaceThreeLayout = try requireLayout(flattenedLayout(of: worldOnSpaceThree), "Expected Space 3 layout to flatten")
        #expect(Set(spaceThreeLayout.tiled.keys) == [spaceThreeLeft, spaceThreeRight])
        #expect(spaceThreeLayout.floatingZOrder == [spaceThreeFloating])

        worldOnSpaceThree = resetActiveSpaceTilingState(in: worldOnSpaceThree)
        #expect(worldOnSpaceThree.spaces[spaceFour]?.displays == expectedSpaceFour.displays)
        #expect(worldOnSpaceThree.spaces[spaceFour]?.focused == spaceFourFloating)
        #expect(worldOnSpaceThree.spaces[spaceThree]?.displays[displayID]?.tree == .void)
        #expect(worldOnSpaceThree.spaces[spaceThree]?.displays[displayID]?.floating == [])
    }

    @Test("Pending tile rule applications are limited to active Space windows")
    func pendingTileRuleApplicationsAreLimitedToActiveSpaceWindows() throws {
        let displayID = DisplayID(raw: 1)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let inactivePending = WindowID(raw: 11)
        let activePending = WindowID(raw: 21)
        let activeForcedFloat = WindowID(raw: 22)
        let world = World(
            displays: [displayID: self.display(displayID, x: 0, width: 1200)],
            activeSpace: secondSpace,
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: .void,
                            floating: [inactivePending]
                        )
                    ],
                    focused: inactivePending
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: .void,
                            floating: [activePending, activeForcedFloat]
                        )
                    ],
                    focused: activePending
                )
            ],
            windows: [
                inactivePending: metadata(for: inactivePending),
                activePending: metadata(for: activePending),
                activeForcedFloat: metadata(for: activeForcedFloat)
            ],
            windowDisplay: [
                inactivePending: displayID,
                activePending: displayID,
                activeForcedFloat: displayID
            ],
            windowConstraints: [:],
            pendingRules: [
                inactivePending: .tileToZone(ZoneID(raw: "center")),
                activePending: .tileToZone(ZoneID(raw: "center")),
                activeForcedFloat: .forceFloat
            ],
            config: .default
        )

        let pending = try requireSuccess(
            pendingTileRuleApplications(in: world),
            "Expected pending tile rule applications to resolve"
        )

        #expect(pending.map(\.0) == [activePending])
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

        let reset = try requireWorld(apply(.resetLayout, to: world), "Expected resetLayout to succeed")

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
}
