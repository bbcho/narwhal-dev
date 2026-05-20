import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("World runtime model")
struct WorldRuntimeModelTests {
    @Test("Recording focus ignores duplicate tail and keeps newest IDs")
    func recordingFocusIgnoresDuplicateTailAndKeepsNewestIDs() {
        let initial = WorldRuntimeState.empty
        let recorded = [
            WindowID(raw: 1),
            WindowID(raw: 2),
            WindowID(raw: 2),
            WindowID(raw: 3),
            WindowID(raw: 4)
        ].reduce(initial) { state, windowID in
            worldRuntimeByRecordingFocus(windowID, limit: 3, in: state)
        }

        #expect(recorded.focusHistory == [
            WindowID(raw: 2),
            WindowID(raw: 3),
            WindowID(raw: 4)
        ])
    }

    @Test("Pruning runtime state drops closed focus history and invalid undo worlds")
    func pruningRuntimeStateDropsClosedFocusHistoryAndInvalidUndoWorlds() {
        let undo = worldFixture(windowIDs: [1, 2])
        let state = WorldRuntimeState(
            undoWorld: undo,
            focusHistory: [WindowID(raw: 1), WindowID(raw: 2), WindowID(raw: 3)]
        )

        let pruned = prunedWorldRuntimeState(liveWindowIDs: [WindowID(raw: 1), WindowID(raw: 3)], in: state)

        #expect(pruned.undoWorld == nil)
        #expect(pruned.focusHistory == [WindowID(raw: 1), WindowID(raw: 3)])
    }

    @Test("Focused window fallback prefers active focus before history")
    func focusedWindowFallbackPrefersActiveFocusBeforeHistory() throws {
        let world = worldFixture(windowIDs: [1, 2], focused: WindowID(raw: 1))
        let runtime = WorldRuntimeState(
            undoWorld: nil,
            focusHistory: [WindowID(raw: 2)]
        )

        let fallback = try #require(runtimeFocusedWindowFallback(in: world, runtime: runtime))

        #expect(fallback.id == WindowID(raw: 1))
    }

    @Test("Focused window fallback uses visible history and skips minimized windows")
    func focusedWindowFallbackUsesVisibleHistoryAndSkipsMinimizedWindows() throws {
        let visible = WindowID(raw: 2)
        let minimized = WindowID(raw: 3)
        let world = worldFixture(
            windows: [
                windowFixture(1),
                windowFixture(2),
                windowFixture(3, isMinimized: true)
            ],
            observed: [visible, minimized]
        )
        let runtime = WorldRuntimeState(
            undoWorld: nil,
            focusHistory: [WindowID(raw: 1), visible, minimized]
        )

        let fallback = try #require(runtimeFocusedWindowFallback(in: world, runtime: runtime))

        #expect(fallback.id == visible)
    }

    @Test("Previous focus target stays in active windows and skips current focus")
    func previousFocusTargetStaysInActiveWindowsAndSkipsCurrentFocus() {
        let current = WindowID(raw: 3)
        let previous = WindowID(raw: 2)
        let inactive = WindowID(raw: 1)
        let world = worldFixture(windowIDs: [1, 2, 3], focused: current)
        let runtime = WorldRuntimeState(
            undoWorld: nil,
            focusHistory: [inactive, previous, current]
        )

        let target = previousFocusTarget(
            in: world,
            runtime: runtime,
            activeWindowIDs: [previous, current]
        )

        #expect(target == previous)
    }

    private func worldFixture(
        windowIDs: [UInt32],
        focused: WindowID? = nil,
        observed: Set<WindowID> = []
    ) -> World {
        worldFixture(
            windows: windowIDs.map { windowFixture($0) },
            focused: focused,
            observed: observed
        )
    }

    private func worldFixture(
        windows: [WindowMetadata],
        focused: WindowID? = nil,
        observed: Set<WindowID> = []
    ) -> World {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 1)
        let workspaceKey = WorkspaceKey(displayID: displayID, spaceID: spaceID)
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let windowDisplay = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, displayID) })
        let windowSpace = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) })

        return World(
            displays: [
                displayID: DisplayInfo(
                    id: displayID,
                    slot: 0,
                    fingerprint: "main",
                    frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760)
                )
            ],
            activeSpace: spaceID,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: .void, floating: [])],
                    focused: focused
                )
            ],
            windows: windowsByID,
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: observed.isEmpty ? [:] : [workspaceKey: observed],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func windowFixture(_ raw: UInt32, isMinimized: Bool = false) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.\(raw)"),
            title: "Window \(raw)",
            role: "AXWindow",
            pid: ProcessID(raw),
            frame: CGRect(x: CGFloat(raw) * 10, y: 20, width: 300, height: 200),
            isResizable: true,
            isMinimized: isMinimized
        )
    }
}
