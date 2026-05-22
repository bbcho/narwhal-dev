import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Observation boundary")
struct ObservationBoundaryTests {
    @Test("Observe-only refresh records visible windows without pruning or assigning unknown Space ownership")
    func observeOnlyRefreshRecordsVisibleWindowsWithoutPruningOrAssigningUnknownSpaceOwnership() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 3)
        let inactiveSpace = SpaceID(raw: 4)
        let inactiveTile = WindowID(raw: 10)
        let activeMapped = WindowID(raw: 20)
        let activeUnmapped = WindowID(raw: 21)
        let inactiveTree = pushIntoTree(inactiveTile, .right, .void)
        let world = World(
            displays: [display: displayInfo(display)],
            activeSpace: inactiveSpace,
            activeSpaceByDisplay: [display: inactiveSpace],
            spaces: [
                inactiveSpace: SpaceState(
                    id: inactiveSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: inactiveTree, floating: [])],
                    focused: inactiveTile
                )
            ],
            windows: [inactiveTile: metadata(inactiveTile, x: 0)],
            windowDisplay: [inactiveTile: display],
            windowSpace: [inactiveTile: inactiveSpace],
            windowConstraints: [inactiveTile: WindowConstraints(minWidth: 500)],
            pendingRules: [inactiveTile: .forceFloat],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [display: displayInfo(display)],
            axSnapshot: AXWindowSnapshot(
                windows: [
                    metadata(activeMapped, x: 300),
                    metadata(activeUnmapped, x: 600)
                ],
                quality: .complete
            ),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [display: activeSpace],
                windowSpace: [activeMapped: activeSpace],
                quality: .managedDisplaySpaces
            ),
            reconciliationMode: .observeOnly
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world))
        let observedKey = WorkspaceKey(displayID: display, spaceID: activeSpace)

        #expect(next.spaces[inactiveSpace]?.displays[display]?.tree == inactiveTree)
        #expect(next.spaces[inactiveSpace]?.focused == inactiveTile)
        #expect(next.windowConstraints == [inactiveTile: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [inactiveTile: .forceFloat])
        #expect(next.windows[activeMapped] == metadata(activeMapped, x: 300))
        #expect(next.windows[activeUnmapped] == metadata(activeUnmapped, x: 600))
        #expect(next.windowSpace[activeMapped] == activeSpace)
        #expect(next.windowSpace[activeUnmapped] == nil)
        #expect(next.observedVisibleWindows[observedKey] == [activeMapped, activeUnmapped])
    }

    @Test("Observe-only refresh clears stale Space ownership for visible unmapped windows")
    func observeOnlyRefreshClearsStaleSpaceOwnershipForVisibleUnmappedWindows() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 3)
        let staleSpace = SpaceID(raw: 4)
        let window = WindowID(raw: 42)
        let world = World(
            displays: [display: displayInfo(display)],
            activeSpace: staleSpace,
            activeSpaceByDisplay: [display: staleSpace],
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [])],
                    focused: nil
                )
            ],
            windows: [window: metadata(window, x: 100)],
            windowDisplay: [window: display],
            windowSpace: [window: staleSpace],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [display: displayInfo(display)],
            axSnapshot: AXWindowSnapshot(windows: [metadata(window, x: 100)], quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [display: activeSpace],
                windowSpace: [:],
                quality: .managedDisplaySpaces
            ),
            reconciliationMode: .observeOnly
        )

        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world))

        #expect(next.windowSpace[window] == nil)
        #expect(focusCycleWindows(in: next, focusedWindowID: window).map(\.id) == [window])
    }

    @Test("Focus cycle uses visible unmapped windows and excludes tiled or explicitly other-Space windows")
    func focusCycleUsesVisibleUnmappedWindowsAndExcludesTiledOrExplicitlyOtherSpaceWindows() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 3)
        let otherSpace = SpaceID(raw: 4)
        let tiled = WindowID(raw: 1)
        let rememberedFloating = WindowID(raw: 2)
        let visibleUnmappedA = WindowID(raw: 3)
        let visibleUnmappedB = WindowID(raw: 4)
        let mappedOther = WindowID(raw: 5)
        let key = WorkspaceKey(displayID: display, spaceID: activeSpace)
        let world = World(
            displays: [display: displayInfo(display)],
            activeSpace: activeSpace,
            activeSpaceByDisplay: [display: activeSpace],
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: pushIntoTree(tiled, .left, .void),
                            floating: [rememberedFloating]
                        )
                    ],
                    focused: tiled
                ),
                otherSpace: SpaceState(
                    id: otherSpace,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: .void, floating: [mappedOther])
                    ],
                    focused: nil
                )
            ],
            windows: [
                tiled: metadata(tiled, x: 0),
                rememberedFloating: metadata(rememberedFloating, x: 200),
                visibleUnmappedA: metadata(visibleUnmappedA, x: 400),
                visibleUnmappedB: metadata(visibleUnmappedB, x: 600),
                mappedOther: metadata(mappedOther, x: 800)
            ],
            windowDisplay: [
                tiled: display,
                rememberedFloating: display,
                visibleUnmappedA: display,
                visibleUnmappedB: display,
                mappedOther: display
            ],
            windowSpace: [
                tiled: activeSpace,
                rememberedFloating: activeSpace,
                mappedOther: otherSpace
            ],
            observedVisibleWindows: [
                key: [tiled, rememberedFloating, visibleUnmappedA, visibleUnmappedB, mappedOther]
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let candidates = Set(focusCycleWindows(in: world, focusedWindowID: tiled).map(\.id))
        #expect(candidates == [rememberedFloating, visibleUnmappedA, visibleUnmappedB])

        let next = try requireWorld(apply(.focusCycle(.previous), to: world))
        #expect(next.spaces[activeSpace]?.focused == visibleUnmappedB)
        #expect(next.spaces[otherSpace]?.focused == nil)
    }

    @Test("External focus prefers observed active workspace over stale stored Space ownership")
    func externalFocusPrefersObservedActiveWorkspaceOverStaleStoredSpaceOwnership() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 3)
        let staleSpace = SpaceID(raw: 4)
        let window = WindowID(raw: 42)
        let key = WorkspaceKey(displayID: display, spaceID: activeSpace)
        let world = World(
            displays: [display: displayInfo(display)],
            activeSpace: activeSpace,
            activeSpaceByDisplay: [display: activeSpace],
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: nil
                ),
                staleSpace: SpaceState(
                    id: staleSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: nil
                )
            ],
            windows: [window: metadata(window, x: 100)],
            windowDisplay: [window: display],
            windowSpace: [window: staleSpace],
            observedVisibleWindows: [key: [window]],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(apply(.windowFocusedExternally(window), to: world))

        #expect(next.spaces[activeSpace]?.focused == window)
        #expect(next.spaces[staleSpace]?.focused == nil)
        #expect(next.windowSpace[window] == activeSpace)
    }

    @Test("Low-coverage managed topology preserves existing Space memory")
    func lowCoverageManagedTopologyPreservesExistingSpaceMemory() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let inactiveSpace = SpaceID(raw: 2)
        let activeTiled = WindowID(raw: 10)
        let inactiveTiled = WindowID(raw: 20)
        let extraWindows = (0..<6).map { WindowID(raw: CGWindowID(100 + $0)) }
        let inactiveTree = pushIntoTree(inactiveTiled, .right, .void)
        let world = World(
            displays: [display: displayInfo(display)],
            activeSpace: activeSpace,
            activeSpaceByDisplay: [display: activeSpace],
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: pushIntoTree(activeTiled, .left, .void), floating: [])],
                    focused: activeTiled
                ),
                inactiveSpace: SpaceState(
                    id: inactiveSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: inactiveTree, floating: [])],
                    focused: inactiveTiled
                )
            ],
            windows: [
                activeTiled: metadata(activeTiled, x: 0),
                inactiveTiled: metadata(inactiveTiled, x: 200)
            ],
            windowDisplay: [
                activeTiled: display,
                inactiveTiled: display
            ],
            windowSpace: [
                activeTiled: activeSpace,
                inactiveTiled: inactiveSpace
            ],
            windowConstraints: [inactiveTiled: WindowConstraints(minWidth: 500)],
            pendingRules: [inactiveTiled: .forceFloat],
            config: .default
        )
        let liveWindows = [metadata(activeTiled, x: 0)] + extraWindows.map { metadata($0, x: CGFloat($0.raw)) }
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: [display: displayInfo(display)],
            axSnapshot: AXWindowSnapshot(windows: liveWindows, quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [display: activeSpace],
                windowSpace: [activeTiled: activeSpace],
                quality: .managedDisplaySpaces
            )
        )

        #expect(snapshot.hasLowTopologyCoverage)
        #expect(environmentSnapshotPreservesSpaceLayouts(snapshot, in: world))
        let next = try requireWorld(apply(.environmentChanged(snapshot), to: world))
        #expect(next.spaces[inactiveSpace]?.displays[display]?.tree == inactiveTree)
        #expect(next.spaces[inactiveSpace]?.focused == inactiveTiled)
        #expect(next.windowConstraints == [inactiveTiled: WindowConstraints(minWidth: 500)])
        #expect(next.pendingRules == [inactiveTiled: .forceFloat])
    }

    private func displayInfo(_ id: DisplayID) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: 0,
            fingerprint: "display-\(id.raw)",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
    }

    private func metadata(_ id: WindowID, x: CGFloat) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: CGRect(x: x, y: 0, width: 100, height: 100),
            isResizable: true,
            isMinimized: false
        )
    }

    private func requireWorld(_ result: Result<World, CommandError>) throws -> World {
        try result.get()
    }
}
