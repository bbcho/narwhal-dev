import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Environment refresh model")
struct EnvironmentRefreshModelTests {
    @Test("Environment refresh transition applies snapshot and returns summary")
    func environmentRefreshTransitionAppliesSnapshotAndReturnsSummary() {
        let window = windowFixture(1)
        let snapshot = environmentSnapshot(windows: [window])

        let transition = environmentRefreshTransition(for: snapshot, in: .empty)

        #expect(transition.world.activeSpace == spaceID)
        #expect(transition.world.displays.count == 1)
        #expect(transition.world.windows[window.id] == window)
        #expect(transition.result.activeSpace == spaceID)
        #expect(transition.result.displayCount == 1)
        #expect(transition.result.windowCount == 1)
        #expect(transition.result.quality == .complete)
        #expect(transition.result.observedWindowCount == 1)
        #expect(transition.result.mappedWindowCount == 1)
        #expect(!transition.result.preservedSpaceLayouts)
    }

    @Test("Environment refresh transition preserves layout mode as data")
    func environmentRefreshTransitionPreservesLayoutModeAsData() {
        let window = windowFixture(1)
        let world = worldFixture(window: window, tree: .leaf(window.id))
        let snapshot = environmentSnapshot(
            windows: [window],
            reconciliationMode: .preserveLayouts
        )

        let transition = environmentRefreshTransition(for: snapshot, in: world)

        #expect(transition.result.preservedSpaceLayouts)
        #expect(transition.world.spaces[spaceID]?.displays[displayID]?.tree == .leaf(window.id))
    }

    private var displayID: DisplayID { DisplayID(raw: 1) }
    private var spaceID: SpaceID { SpaceID(raw: 1) }

    private func environmentSnapshot(
        windows: [WindowMetadata],
        reconciliationMode: EnvironmentReconciliationMode = .activeWorkspaceCleanup
    ) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            activeSpace: spaceID,
            displays: [displayID: displayInfo()],
            axSnapshot: AXWindowSnapshot(windows: windows, quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [displayID: spaceID],
                windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) }),
                quality: .managedDisplaySpaces
            ),
            reconciliationMode: reconciliationMode
        )
    }

    private func worldFixture(window: WindowMetadata, tree: Node) -> World {
        let workspaceKey = WorkspaceKey(displayID: displayID, spaceID: spaceID)
        return World(
            displays: [displayID: displayInfo()],
            activeSpace: spaceID,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [])],
                    focused: window.id
                )
            ],
            windows: [window.id: window],
            windowDisplay: [window.id: displayID],
            windowSpace: [window.id: spaceID],
            observedVisibleWindows: [workspaceKey: [window.id]],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func displayInfo() -> DisplayInfo {
        DisplayInfo(
            id: displayID,
            slot: 0,
            fingerprint: "main",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
    }

    private func windowFixture(_ raw: UInt32) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.\(raw)"),
            title: "Window \(raw)",
            role: "AXWindow",
            pid: ProcessID(raw),
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            isResizable: true,
            isMinimized: false
        )
    }
}
