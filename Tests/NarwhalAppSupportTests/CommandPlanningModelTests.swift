import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Command planning model")
struct CommandPlanningModelTests {
    @Test("Command plan builds desired layout from immutable worlds")
    func commandPlanBuildsDesiredLayoutFromImmutableWorlds() throws {
        let left = windowFixture(1, frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let right = windowFixture(2, frame: CGRect(x: 600, y: 0, width: 400, height: 800))
        let oldWorld = worldFixture(
            windows: [left, right],
            tree: .leaf(left.id),
            floating: [right.id],
            focused: left.id
        )
        let newWorld = try apply(.push(right.id, .right), to: oldWorld).get()

        let plan = try commandPlan(
            from: oldWorld,
            to: newWorld,
            focusedWindowID: right.id,
            undoWorld: oldWorld,
            generation: LayoutGeneration(raw: 42)
        ).get()

        #expect(plan.focusedWindowID == right.id)
        #expect(plan.desiredLayout.generation.raw == 42)
        #expect(plan.plannedWorld == newWorld)
        #expect(plan.undoWorld == oldWorld)
        #expect(plan.windows == newWorld.windows)
        #expect(plan.desiredLayout.layout.tiled[right.id] != nil)
        #expect(oldWorld.spaces[spaceID]?.displays[displayID]?.floating == [right.id])
    }

    @Test("Focused command plans are scoped to the focused display workspace")
    func focusedCommandPlansAreScopedToFocusedDisplayWorkspace() throws {
        let leftTiled = windowFixture(1, frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let leftFloating = windowFixture(2, frame: CGRect(x: 200, y: 0, width: 400, height: 800))
        let rightTiled = windowFixture(3, frame: CGRect(x: 1200, y: 0, width: 400, height: 800))
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let oldWorld = multiDisplayWorldFixture(
            windows: [leftTiled, leftFloating, rightTiled],
            displays: [
                leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: .leaf(leftTiled.id), floating: [leftFloating.id]),
                rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .leaf(rightTiled.id), floating: [])
            ],
            windowDisplay: [
                leftTiled.id: leftDisplay,
                leftFloating.id: leftDisplay,
                rightTiled.id: rightDisplay
            ],
            focused: leftFloating.id
        )
        let newWorld = try apply(.push(leftFloating.id, .right), to: oldWorld).get()
        let scope = commandPlanScope(
            focusedWindowID: leftFloating.id,
            oldWorld: oldWorld,
            newWorld: newWorld
        )

        let plan = try commandPlan(
            from: oldWorld,
            to: newWorld,
            focusedWindowID: leftFloating.id,
            undoWorld: oldWorld,
            generation: LayoutGeneration(raw: 43),
            scope: scope
        ).get()

        #expect(scope == .workspace(WorkspaceKey(displayID: leftDisplay, spaceID: spaceID)))
        #expect(Set(plan.desiredLayout.layout.tiled.keys) == [leftTiled.id, leftFloating.id])
        #expect(plan.desiredLayout.layout.tiled[rightTiled.id] == nil)
    }

    @Test("Move-display plans use the new display workspace despite stale observed visibility")
    func moveDisplayPlansUseNewDisplayWorkspaceDespiteStaleObservedVisibility() throws {
        let moving = windowFixture(1, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let oldWorld = multiDisplayWorldFixture(
            windows: [moving],
            displays: [
                leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: .void, floating: [moving.id]),
                rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .void, floating: [])
            ],
            windowDisplay: [moving.id: leftDisplay],
            focused: moving.id
        )
        let newWorld = try apply(.moveToNextDisplay(moving.id), to: oldWorld).get()

        let scope = commandPlanScope(
            focusedWindowID: moving.id,
            oldWorld: oldWorld,
            newWorld: newWorld
        )
        let plan = try commandPlan(
            from: oldWorld,
            to: newWorld,
            focusedWindowID: moving.id,
            undoWorld: oldWorld,
            generation: LayoutGeneration(raw: 44),
            scope: scope
        ).get()

        #expect(scope == .workspace(WorkspaceKey(displayID: rightDisplay, spaceID: spaceID)))
        #expect(plan.desiredLayout.layout.tiled[moving.id]?.minX ?? 0 >= 1000)
        #expect(plan.desiredLayout.delta.moves[moving.id]?.minX ?? 0 >= 1000)
    }

    @Test("Current layout plan returns nil when there are no tiled windows")
    func currentLayoutPlanReturnsNilWithoutTiledWindows() throws {
        let window = windowFixture(1)
        let world = worldFixture(windows: [window], tree: .void, floating: [window.id])

        let plan = try currentLayoutCommandPlan(
            in: world,
            generation: LayoutGeneration(raw: 9)
        ).get()

        #expect(plan == nil)
    }

    @Test("Focus direction plan uses active floating geometry as fallback")
    func focusDirectionPlanUsesActiveFloatingGeometryAsFallback() throws {
        let left = windowFixture(1, frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let right = windowFixture(2, frame: CGRect(x: 600, y: 0, width: 400, height: 600))
        let world = worldFixture(
            windows: [left, right],
            tree: .void,
            floating: [left.id, right.id],
            focused: left.id
        )

        let plan = try focusDirectionPlan(in: world, from: left.id, direction: .right).get()

        #expect(plan.window.id == right.id)
        #expect(plan.frame == right.frame)
    }

    @Test("Focus direction plan does not cross display workspaces")
    func focusDirectionPlanDoesNotCrossDisplayWorkspaces() throws {
        let left = windowFixture(1, frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let right = windowFixture(2, frame: CGRect(x: 1200, y: 0, width: 400, height: 800))
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let world = multiDisplayWorldFixture(
            windows: [left, right],
            displays: [
                leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: .leaf(left.id), floating: []),
                rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .leaf(right.id), floating: [])
            ],
            windowDisplay: [
                left.id: leftDisplay,
                right.id: rightDisplay
            ],
            focused: left.id
        )

        #expect(focusDirectionPlan(in: world, from: left.id, direction: .right) == .failure(.noNeighbor(.right)))
    }

    @Test("Focus previous stays inside the current display workspace")
    func focusPreviousStaysInsideCurrentDisplayWorkspace() throws {
        let leftCurrent = windowFixture(1, frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let leftPrevious = windowFixture(2, frame: CGRect(x: 500, y: 0, width: 400, height: 800))
        let rightRecent = windowFixture(3, frame: CGRect(x: 1200, y: 0, width: 400, height: 800))
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let world = multiDisplayWorldFixture(
            windows: [leftCurrent, leftPrevious, rightRecent],
            displays: [
                leftDisplay: DisplaySpaceState(
                    displayID: leftDisplay,
                    tree: .void,
                    floating: [leftCurrent.id, leftPrevious.id]
                ),
                rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .void, floating: [rightRecent.id])
            ],
            windowDisplay: [
                leftCurrent.id: leftDisplay,
                leftPrevious.id: leftDisplay,
                rightRecent.id: rightDisplay
            ],
            focused: leftCurrent.id
        )
        let runtime = WorldRuntimeState(
            undoWorld: nil,
            focusHistory: [leftPrevious.id, rightRecent.id, leftCurrent.id]
        )

        let plan = try focusPreviousPlan(in: world, runtime: runtime, from: leftCurrent.id).get()

        #expect(plan.window.id == leftPrevious.id)
    }

    @Test("Setting focus updates the owning Space only")
    func settingFocusUpdatesTheOwningSpaceOnly() {
        let window = windowFixture(1)
        let world = worldFixture(windows: [window], tree: .void, floating: [window.id])

        let updated = worldBySettingFocus(window.id, in: world)

        #expect(updated.spaces[spaceID]?.focused == window.id)
        #expect(updated.windows == world.windows)
        #expect(updated.windowDisplay == world.windowDisplay)
    }

    @Test("Recording observed constraints merges all observations in one pure update")
    func recordingObservedConstraintsMergesAllObservationsInOnePureUpdate() {
        let first = windowFixture(1)
        let second = windowFixture(2)
        let world = worldFixture(
            windows: [first, second],
            tree: .void,
            floating: [first.id, second.id],
            constraints: [first.id: WindowConstraints(minWidth: 500)]
        )

        let updated = worldByRecordingObservedConstraints([
            first.id: WindowConstraints(minWidth: 450, minHeight: 300),
            second.id: WindowConstraints(minWidth: 250)
        ], in: world)

        #expect(updated.windowConstraints[first.id] == WindowConstraints(minWidth: 500, minHeight: 300))
        #expect(updated.windowConstraints[second.id] == WindowConstraints(minWidth: 250))
    }

    private var displayID: DisplayID { DisplayID(raw: 1) }
    private var spaceID: SpaceID { SpaceID(raw: 1) }

    private func worldFixture(
        windows: [WindowMetadata],
        tree: Node,
        floating: [WindowID],
        focused: WindowID? = nil,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> World {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let windowDisplay = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, displayID) })
        let windowSpace = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) })
        let observed = Set(windows.map(\.id))
        let workspaceKey = WorkspaceKey(displayID: displayID, spaceID: spaceID)

        return World(
            displays: [
                displayID: DisplayInfo(
                    id: displayID,
                    slot: 0,
                    fingerprint: "main",
                    frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
                )
            ],
            activeSpace: spaceID,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: floating)],
                    focused: focused
                )
            ],
            windows: windowsByID,
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: [workspaceKey: observed],
            windowConstraints: constraints,
            pendingRules: [:],
            config: .default
        )
    }

    private func multiDisplayWorldFixture(
        windows: [WindowMetadata],
        displays: [DisplayID: DisplaySpaceState],
        windowDisplay: [WindowID: DisplayID],
        focused: WindowID? = nil
    ) -> World {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let windowSpace = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) })
        let displayInfos = Dictionary(uniqueKeysWithValues: displays.keys.map { displayID in
            let index = displayID.raw == 1 ? 0 : 1
            let x = CGFloat(index) * 1000
            return (
                displayID,
                DisplayInfo(
                    id: displayID,
                    slot: index,
                    fingerprint: "display-\(displayID.raw)",
                    frame: CGRect(x: x, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: x, y: 0, width: 1000, height: 800)
                )
            )
        })
        let observed = Dictionary(uniqueKeysWithValues: displays.keys.map { displayID in
            (
                WorkspaceKey(displayID: displayID, spaceID: spaceID),
                Set(windowDisplay.compactMap { $0.value == displayID ? $0.key : nil })
            )
        })

        return World(
            displays: displayInfos,
            activeSpace: spaceID,
            activeSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.keys.map { ($0, spaceID) }),
            spaces: [
                spaceID: SpaceState(id: spaceID, displays: displays, focused: focused)
            ],
            windows: windowsByID,
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: observed,
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func windowFixture(
        _ raw: UInt32,
        frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300)
    ) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.\(raw)"),
            title: "Window \(raw)",
            role: "AXWindow",
            pid: ProcessID(raw),
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }
}
