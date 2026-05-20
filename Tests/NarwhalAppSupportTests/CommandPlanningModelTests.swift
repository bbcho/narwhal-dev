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
