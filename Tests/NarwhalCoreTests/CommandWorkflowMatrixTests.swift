import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Command workflow matrix")
struct CommandWorkflowMatrixTests {
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
            if case .success(let next) = apply(command, to: world) {
                #expect(next == world, "Unexpected mutation for \(command)")
            }
        }

        #expect(apply(.focusCycle(.next), to: world) == .failure(.windowNotFound(WindowID(raw: 0))))
        #expect(apply(.focusDirection(.right), to: world) == .failure(.activeSpaceUnavailable))
    }

    @Test("Push, focus, swap, resize, balance, float, and reset workflows hold from one through six windows")
    func coreLayoutWorkflowsHoldFromOneThroughSixWindows() throws {
        for count in 1...6 {
            let ids = (1...count).map { WindowID(raw: CGWindowID($0)) }
            var world = workflowWorld(windowCount: count, displayCount: 1)
            try assertWorldInvariants(world, note: "initial count \(count)")

            for (index, windowID) in ids.enumerated() {
                world = try applyRequired(.windowFocusedExternally(windowID), to: world, note: "focus \(windowID)")
                world = try applyRequired(.push(windowID, pushDirections[index % pushDirections.count]), to: world, note: "push \(windowID)")
                try assertWorldInvariants(world, note: "after push \(windowID)")
                #expect(tiledIDs(in: world).contains(windowID))
            }

            if count > 1 {
                let focused = ids.last!
                #expect(pushDirections.contains { apply(.swapInTree(focused, $0), to: world).isSuccess })
                #expect(pushDirections.contains { apply(.resizeSplit(focused, $0, delta: 0.10), to: world).isSuccess })
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
                    Issue.record("Focus cycle succeeded without focused window at count \(count)")
                }
            case .failure(.windowNotFound):
                #expect(expectedSet.isEmpty)
            case .failure(let error):
                Issue.record("Unexpected focus cycle error at count \(count): \(error.message)")
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

    private func applyRequired(_ command: Command, to world: World, note: String) throws -> World {
        switch apply(command, to: world) {
        case .success(let next):
            try assertWorldInvariants(next, note: note)
            return next
        case .failure(let error):
            Issue.record("Command \(command) failed in \(note): \(error.message)")
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
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
