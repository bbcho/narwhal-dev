import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Window minimization")
struct WindowMinimizationTests {
    private let spaceID = SpaceID(raw: 1)
    private let displayID = DisplayID(raw: 1)
    private let left = WindowID(raw: 1)
    private let right = WindowID(raw: 2)

    @Test("A minimized tiled window keeps its slot but is not laid out")
    func minimizedTiledWindowKeepsSlotWithoutFrame() throws {
        let world = try twoColumnWorld(rightMinimized: true)

        let layout = try flattenedLayout(of: world).get()

        #expect(layout.tiled == [left: CGRect(x: 0, y: 0, width: 600, height: 800)])
        #expect(layout.hidden == [right])
    }

    @Test("Marking a window minimized changes only its metadata, never the tree")
    func markingMinimizedChangesOnlyMetadata() throws {
        let world = try twoColumnWorld(rightMinimized: false)

        let minimized = worldBySettingMinimized([right], to: true, in: world)

        #expect(minimized.windows[right]?.isMinimized == true)
        #expect(minimized.windows[left]?.isMinimized == false)
        #expect(minimized.spaces == world.spaces)
        #expect(worldBySettingMinimized([right], to: false, in: minimized) == world)
    }

    @Test("Reconciliation keeps a minimized window that the snapshot still reports")
    func reconciliationKeepsMinimizedWindowInTree() throws {
        let world = try twoColumnWorld(rightMinimized: true)
        let snapshot = EnvironmentSnapshot(
            activeSpace: spaceID,
            displays: world.displays,
            axSnapshot: AXWindowSnapshot(
                windows: [try #require(world.windows[left]), try #require(world.windows[right])],
                quality: .complete
            )
        )

        let reconciled = reconcileEnvironment(snapshot, in: world)

        #expect(reconciled.spaces[spaceID]?.displays[displayID]?.tree == world.spaces[spaceID]?.displays[displayID]?.tree)
        #expect(reconciled.windows[right]?.isMinimized == true)
    }

    private func twoColumnWorld(rightMinimized: Bool) throws -> World {
        let tree = Node.split(try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1, node: .leaf(left)).get(),
            try Cell.create(weight: 1, node: .leaf(right)).get()
        ]).get())
        return World(
            displays: [
                displayID: DisplayInfo(
                    id: displayID,
                    slot: 0,
                    fingerprint: "main",
                    frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
                )
            ],
            activeSpace: spaceID,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [])],
                    focused: left
                )
            ],
            windows: [
                left: window(left, frame: CGRect(x: 0, y: 0, width: 600, height: 800), minimized: false),
                right: window(right, frame: CGRect(x: 600, y: 0, width: 600, height: 800), minimized: rightMinimized)
            ],
            windowDisplay: [left: displayID, right: displayID],
            windowSpace: [left: spaceID, right: spaceID],
            observedVisibleWindows: [WorkspaceKey(displayID: displayID, spaceID: spaceID): [left, right]],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func window(_ id: WindowID, frame: CGRect, minimized: Bool) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.\(id.raw)"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: frame,
            isResizable: true,
            isMinimized: minimized
        )
    }
}
