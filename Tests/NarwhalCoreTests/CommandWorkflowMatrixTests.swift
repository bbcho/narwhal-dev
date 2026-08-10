import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Command workflow matrix")
struct CommandWorkflowMatrixTests {
    @Test("Canonical one-through-eight layouts have exact swap and resize contracts")
    func canonicalDirectionalCommandContracts() throws {
        for testCase in directionalCases {
            let world = try canonicalTiledWorld(windowCount: testCase.windowCount)
            let focused = WindowID(raw: CGWindowID(testCase.windowCount))
            let before = try tiledFrames(in: world)

            for direction in pushDirections {
                if let expectedTarget = testCase.swapTargets.first(where: { $0.direction == direction })?.windowID {
                    let swapped = try apply(.swapInTree(focused, direction), to: world).get()
                    let after = try tiledFrames(in: swapped)
                    let target = WindowID(raw: expectedTarget)
                    #expect(changedWindowIDs(from: before, to: after) == Set([focused, target]))
                    #expect(after[focused] == before[target])
                    #expect(after[target] == before[focused])
                    assertCommandPreservesWorldMetadata(swapped, from: world, focused: focused)
                } else {
                    #expect(apply(.swapInTree(focused, direction), to: world) == .failure(.noNeighbor(direction)))
                }

                if let expected = testCase.resizeChanges.first(where: { $0.direction == direction }) {
                    let resized = try apply(.resizeSplit(focused, direction, delta: 0.10), to: world).get()
                    let after = try tiledFrames(in: resized)
                    let expectedChanged = Set(expected.windowIDs.map { WindowID(raw: $0) })
                    #expect(changedWindowIDs(from: before, to: after) == expectedChanged)
                    assertResizeGrowth(
                        direction: direction,
                        before: try #require(before[focused]),
                        after: try #require(after[focused])
                    )
                    assertCommandPreservesWorldMetadata(resized, from: world, focused: focused)
                } else {
                    #expect(apply(.resizeSplit(focused, direction, delta: 0.10), to: world) == .failure(.noNeighbor(direction)))
                }
            }
        }
    }

    @Test("Zero windows reject focus-dependent commands without mutating")
    func zeroWindowsRejectFocusDependentCommandsWithoutMutating() {
        let world = workflowWorld(windowCount: 0, displayCount: 1)
        let missing = WindowID(raw: 1)
        let commands: [Command] = [
            .push(missing, .left),
            .center(missing),
            .eject(missing),
            .toggleFloat(missing),
            .swapInTree(missing, .right),
            .resizeSplit(missing, .right, delta: 0.25),
            .moveToNextDisplay(missing),
            .focus(missing),
            .windowFocusedExternally(missing)
        ]

        for command in commands {
            switch apply(command, to: world) {
            case .failure:
                break
            case .success(let next):
                #expect(Bool(false), "Expected \(command) to fail, but it produced \(next)")
            }
        }

        #expect(apply(.focusCycle(.next), to: world) == .failure(.noFocusedWindow))
        #expect(apply(.focusDirection(.right), to: world) == .failure(.activeSpaceUnavailable))
    }

    @Test("Push, focus, balance, float, and reset workflows hold from one through eight windows")
    func coreLayoutWorkflowsHoldFromOneThroughEightWindows() throws {
        for count in 1...8 {
            let ids = (1...count).map { WindowID(raw: CGWindowID($0)) }
            var world = workflowWorld(windowCount: count, displayCount: 1)
            try assertWorldInvariants(world, note: "initial count \(count)")

            for (index, windowID) in ids.enumerated() {
                world = try applyRequired(.windowFocusedExternally(windowID), to: world, note: "focus \(windowID)")
                world = try applyRequired(.push(windowID, pushDirections[index % pushDirections.count]), to: world, note: "push \(windowID)")
                try assertWorldInvariants(world, note: "after push \(windowID)")
                #expect(tiledIDs(in: world).contains(windowID))
            }

            world = try applyRequired(.balance(SpaceID(raw: 1)), to: world, note: "balance count \(count)")
            try assertWorldInvariants(world, note: "after balance count \(count)")

            let first = ids[0]
            world = try applyRequired(.eject(first), to: world, note: "eject count \(count)")
            #expect(!tiledIDs(in: world).contains(first))
            world = try applyRequired(.toggleFloat(first), to: world, note: "retile toggleFloat count \(count)")
            #expect(tiledIDs(in: world).contains(first))
            world = try applyRequired(.center(first), to: world, note: "center count \(count)")
            try assertWorldInvariants(world, note: "after center count \(count)")

            world = try applyRequired(.resetLayout, to: world, note: "reset count \(count)")
            #expect(tiledIDs(in: world).isEmpty)
            try assertWorldInvariants(world, note: "after reset count \(count)")
        }
    }

    @Test("Focus cycle sees only untiled windows from the active workspace for zero through six windows")
    func focusCycleSeesOnlyUntiledActiveWorkspaceWindows() throws {
        for count in 0...6 {
            let world = mixedTiledFloatingWorld(windowCount: count)
            let cycleWindowIDs = focusCycleWindows(in: world, focusedWindowID: nil).map(\.id)
            let expectedSet = Set(cycleWindowIDs)
            let tiled = tiledIDs(in: world)

            #expect(expectedSet.isDisjoint(with: tiled), "Cycle included tiled windows at count \(count)")
            #expect(cycleWindowIDs.allSatisfy { world.windowSpace[$0] == SpaceID(raw: 1) }, "Cycle crossed spaces at count \(count)")

            let candidateIDs = focusCycleCandidates(
                windows: focusCycleWindows(in: world, focusedWindowID: nil),
                from: nil,
                direction: .next
            )
            #expect(Set(candidateIDs) == expectedSet)

            switch apply(.focusCycle(.next), to: world) {
            case .success(let next):
                if let focused = next.spaces[SpaceID(raw: 1)]?.focused {
                    #expect(expectedSet.contains(focused), "Focus cycle selected non-candidate \(focused) at count \(count)")
                } else {
                    #expect(Bool(false), "Focus cycle succeeded without focused window at count \(count)")
                }
            case .failure(.windowNotFound), .failure(.noFocusedWindow):
                #expect(expectedSet.isEmpty)
            case .failure(let error):
                #expect(Bool(false), "Unexpected focus cycle error at count \(count): \(error.message)")
            }
        }
    }

    @Test("Move-display workflow scopes the target window across two displays for one through six windows")
    func moveDisplayWorkflowScopesTargetAcrossTwoDisplays() throws {
        for count in 1...6 {
            let first = WindowID(raw: 1)
            let world = workflowWorld(windowCount: count, displayCount: 2)

            let moved = try applyRequired(.moveToNextDisplay(first), to: world, note: "move display count \(count)")

            #expect(moved.windowDisplay[first] == DisplayID(raw: 2))
            #expect(moved.windowSpace[first] == SpaceID(raw: 1))
            try assertWorldInvariants(moved, note: "after move display count \(count)")
        }
    }

    private let pushDirections: [Direction] = [.left, .right, .up, .down]

    private let directionalCases: [DirectionalCommandCase] = [
        DirectionalCommandCase(windowCount: 1, swapTargets: [], resizeChanges: [(.right, [1])]),
        DirectionalCommandCase(windowCount: 2, swapTargets: [(.left, 1)], resizeChanges: [(.left, [1, 2])]),
        DirectionalCommandCase(
            windowCount: 3,
            swapTargets: [(.left, 1), (.right, 2), (.down, 1)],
            resizeChanges: [(.down, [1, 2, 3])]
        ),
        DirectionalCommandCase(
            windowCount: 4,
            swapTargets: [(.left, 1), (.right, 2), (.up, 3)],
            resizeChanges: [(.left, [1, 4]), (.right, [2, 4]), (.up, [1, 2, 3, 4])]
        ),
        DirectionalCommandCase(
            windowCount: 5,
            swapTargets: [(.right, 1), (.up, 3), (.down, 1)],
            resizeChanges: [(.right, [1, 2, 3, 4, 5])]
        ),
        DirectionalCommandCase(
            windowCount: 6,
            swapTargets: [(.left, 5), (.right, 4), (.up, 1)],
            resizeChanges: [
                (.left, [1, 2, 3, 4, 5, 6]),
                (.right, [1, 4, 6]),
                (.up, [1, 6])
            ]
        ),
        DirectionalCommandCase(
            windowCount: 7,
            swapTargets: [(.left, 5), (.right, 3), (.down, 3)],
            resizeChanges: [(.down, [1, 2, 3, 4, 5, 6, 7])]
        ),
        DirectionalCommandCase(
            windowCount: 8,
            swapTargets: [(.left, 5), (.right, 1), (.up, 7), (.down, 1)],
            resizeChanges: [
                (.left, [5, 8]),
                (.right, [1, 2, 3, 4, 6, 8]),
                (.up, [1, 2, 3, 4, 5, 6, 7, 8])
            ]
        )
    ]

    private func canonicalTiledWorld(windowCount: Int) throws -> World {
        let ids = (1...windowCount).map { WindowID(raw: CGWindowID($0)) }
        var world = workflowWorld(windowCount: windowCount, displayCount: 1)
        for (index, windowID) in ids.enumerated() {
            world = try applyRequired(
                .windowFocusedExternally(windowID),
                to: world,
                note: "canonical focus count \(windowCount)"
            )
            world = try applyRequired(
                .push(windowID, pushDirections[index % pushDirections.count]),
                to: world,
                note: "canonical push count \(windowCount)"
            )
        }
        return world
    }

    private func tiledFrames(in world: World) throws -> [WindowID: CGRect] {
        try workspaceLayout(
            for: WorkspaceKey(displayID: DisplayID(raw: 1), spaceID: SpaceID(raw: 1)),
            in: world
        ).get().tiled
    }

    private func changedWindowIDs(
        from before: [WindowID: CGRect],
        to after: [WindowID: CGRect]
    ) -> Set<WindowID> {
        Set(before.keys.filter { before[$0] != after[$0] })
    }

    private func assertResizeGrowth(direction: Direction, before: CGRect, after: CGRect) {
        switch direction {
        case .left:
            #expect(after.minX < before.minX)
            #expect(after.width > before.width)
            #expect(after.minY == before.minY)
            #expect(after.height == before.height)
        case .right:
            #expect(after.maxX > before.maxX)
            #expect(after.width > before.width)
            #expect(after.minY == before.minY)
            #expect(after.height == before.height)
        case .up:
            #expect(after.minY < before.minY)
            #expect(after.height > before.height)
            #expect(after.minX == before.minX)
            #expect(after.width == before.width)
        case .down:
            #expect(after.maxY > before.maxY)
            #expect(after.height > before.height)
            #expect(after.minX == before.minX)
            #expect(after.width == before.width)
        }
    }

    private func assertCommandPreservesWorldMetadata(
        _ next: World,
        from world: World,
        focused: WindowID
    ) {
        #expect(next.spaces[SpaceID(raw: 1)]?.focused == focused)
        #expect(next.displays == world.displays)
        #expect(next.activeSpace == world.activeSpace)
        #expect(next.activeSpaceByDisplay == world.activeSpaceByDisplay)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowSpace == world.windowSpace)
        #expect(next.observedVisibleWindows == world.observedVisibleWindows)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    private func applyRequired(_ command: Command, to world: World, note: String) throws -> World {
        switch apply(command, to: world) {
        case .success(let next):
            try assertWorldInvariants(next, note: note)
            return next
        case .failure(let error):
            #expect(Bool(false), "Command \(command) failed in \(note): \(error.message)")
            throw WorkflowFailure()
        }
    }

    private func assertWorldInvariants(_ world: World, note: String) throws {
        let knownWindows = Set(world.windows.keys)
        var tracked: Set<WindowID> = []

        for (spaceID, space) in world.spaces {
            if let focused = space.focused {
                #expect(knownWindows.contains(focused), "Focused missing in \(note)")
                #expect(world.windowSpace[focused] == spaceID, "Focused window has wrong Space in \(note)")
            }
            for (displayID, displayState) in space.displays {
                #expect(displayState.displayID == displayID, "Display state key mismatch in \(note)")
                let tiled = Set(occupiedWindows(in: displayState.tree))
                let floating = Set(displayState.floating)
                #expect(tiled.isDisjoint(with: floating), "Window is both tiled and floating in \(note)")
                for windowID in tiled.union(floating) {
                    #expect(knownWindows.contains(windowID), "Tracked unknown window \(windowID) in \(note)")
                    #expect(world.windowDisplay[windowID] == displayID, "Tracked window has wrong display in \(note)")
                    #expect(world.windowSpace[windowID] == spaceID, "Tracked window has wrong Space in \(note)")
                    #expect(!tracked.contains(windowID), "Window tracked twice in \(note)")
                    tracked.insert(windowID)
                }
            }
        }

        for (key, visible) in world.observedVisibleWindows {
            #expect(world.activeSpaceByDisplay[key.displayID] == key.spaceID, "Observed inactive workspace in \(note)")
            #expect(visible.isSubset(of: knownWindows), "Observed unknown windows in \(note)")
        }
    }

    private func workflowWorld(windowCount: Int, displayCount: Int) -> World {
        let displayIDs = displayCount == 0 ? [] : (1...displayCount).map { DisplayID(raw: CGDirectDisplayID($0)) }
        let spaceID = SpaceID(raw: 1)
        let windowIDs = windowCount == 0 ? [] : (1...windowCount).map { WindowID(raw: CGWindowID($0)) }
        let displays = Dictionary(uniqueKeysWithValues: displayIDs.enumerated().map { index, displayID in
            (
                displayID,
                DisplayInfo(
                    id: displayID,
                    slot: index,
                    fingerprint: "display-\(displayID.raw)",
                    frame: CGRect(x: CGFloat(index) * 1000, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: CGFloat(index) * 1000, y: 0, width: 1000, height: 760)
                )
            )
        })
        let windows = Dictionary(uniqueKeysWithValues: windowIDs.map { ($0, window($0)) })
        let firstDisplay = displayIDs[0]
        let key = WorkspaceKey(displayID: firstDisplay, spaceID: spaceID)

        return World(
            displays: displays,
            activeSpace: spaceID,
            activeSpaceByDisplay: Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, spaceID) }),
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [
                        firstDisplay: DisplaySpaceState(displayID: firstDisplay, tree: .void, floating: windowIDs)
                    ],
                    focused: windowIDs.first
                )
            ],
            windows: windows,
            windowDisplay: Dictionary(uniqueKeysWithValues: windowIDs.map { ($0, firstDisplay) }),
            windowSpace: Dictionary(uniqueKeysWithValues: windowIDs.map { ($0, spaceID) }),
            observedVisibleWindows: windowIDs.isEmpty ? [:] : [key: Set(windowIDs)],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func mixedTiledFloatingWorld(windowCount: Int) -> World {
        var world = workflowWorld(windowCount: windowCount, displayCount: 1)
        let ids = windowCount == 0 ? [] : (1...windowCount).map { WindowID(raw: CGWindowID($0)) }
        let tiled = ids.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let floating = ids.filter { !tiled.contains($0) }
        let tree = tiled.reduce(Node.void) { tree, windowID in
            pushIntoTree(windowID, .right, tree)
        }
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 1)
        world = World(
            displays: world.displays,
            activeSpace: world.activeSpace,
            activeSpaceByDisplay: world.activeSpaceByDisplay,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [
                        displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: floating)
                    ],
                    focused: floating.first
                )
            ],
            windows: world.windows,
            windowDisplay: world.windowDisplay,
            windowSpace: world.windowSpace,
            observedVisibleWindows: world.observedVisibleWindows,
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        return world
    }

    private func tiledIDs(in world: World) -> Set<WindowID> {
        world.spaces.values.reduce(Set<WindowID>()) { result, space in
            result.union(space.displays.values.reduce(Set<WindowID>()) { partial, state in
                partial.union(occupiedWindows(in: state.tree))
            })
        }
    }

    private func window(_ id: WindowID) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.workflow"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: CGRect(x: CGFloat(id.raw) * 30, y: CGFloat(id.raw) * 20, width: 360, height: 240),
            isResizable: true,
            isMinimized: false
        )
    }

    private struct WorkflowFailure: Error {}

    private struct DirectionalCommandCase {
        let windowCount: Int
        let swapTargets: [(direction: Direction, windowID: CGWindowID)]
        let resizeChanges: [(direction: Direction, windowIDs: [CGWindowID])]
    }
}
