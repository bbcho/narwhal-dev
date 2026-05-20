import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("World update model")
struct WorldUpdateModelTests {
    @Test("Display-state upsert appends only absent floating windows")
    func displayStateUpsertAppendsOnlyAbsentFloatingWindows() {
        let displayID = DisplayID(raw: 1)
        let existing = WindowID(raw: 10)
        let inserted = WindowID(raw: 11)
        let state = DisplaySpaceState(displayID: displayID, tree: .void, floating: [existing])

        let updated = displayStateByUpsertingFloatingWindow(inserted, in: state)

        #expect(updated == DisplaySpaceState(
            displayID: displayID,
            tree: .void,
            floating: [existing, inserted]
        ))
    }

    @Test("Display-state upsert sanitizes duplicates when window is already tracked")
    func displayStateUpsertSanitizesDuplicatesWhenAlreadyTracked() {
        let displayID = DisplayID(raw: 1)
        let existing = WindowID(raw: 10)
        let state = DisplaySpaceState(displayID: displayID, tree: .void, floating: [existing, existing])

        let updated = displayStateByUpsertingFloatingWindow(existing, in: state)

        #expect(updated == DisplaySpaceState(
            displayID: displayID,
            tree: .void,
            floating: [existing]
        ))
    }

    @Test("Display-state upsert does not float already tiled windows")
    func displayStateUpsertDoesNotFloatAlreadyTiledWindows() {
        let displayID = DisplayID(raw: 1)
        let tiled = WindowID(raw: 10)
        let state = DisplaySpaceState(displayID: displayID, tree: .leaf(tiled), floating: [tiled])

        let updated = displayStateByUpsertingFloatingWindow(tiled, in: state)

        #expect(updated == DisplaySpaceState(displayID: displayID, tree: .leaf(tiled), floating: []))
    }

    @Test("Window frame recording updates only matching metadata")
    func windowFrameRecordingUpdatesOnlyMatchingMetadata() {
        let known = windowFixture(1)
        let other = windowFixture(2)
        let frame = CGRect(x: 100, y: 200, width: 500, height: 300)

        let windows = windowsByRecordingWindowFrames([
            known.id: frame,
            WindowID(raw: 999): CGRect(x: 1, y: 1, width: 1, height: 1)
        ], in: [
            known.id: known,
            other.id: other
        ])

        #expect(windows[known.id]?.frame == frame)
        #expect(windows[known.id]?.bundleID == known.bundleID)
        #expect(windows[other.id] == other)
        #expect(windows[WindowID(raw: 999)] == nil)
    }

    @Test("Upserting active window records ownership, visibility, and floating order")
    func upsertingActiveWindowRecordsOwnershipVisibilityAndFloatingOrder() throws {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 2)
        let metadata = windowFixture(42)
        let displays = displaysFixture(displayID)
        let world = worldFixture(
            displayID: displayID,
            spaceID: spaceID,
            displays: displays,
            windows: [],
            floating: []
        )

        let updated = try #require(worldByUpsertingActiveWindow(
            metadata,
            displayID: displayID,
            displays: displays,
            in: world
        ).successValue)

        let workspaceKey = WorkspaceKey(displayID: displayID, spaceID: spaceID)
        #expect(updated.windows[metadata.id] == metadata)
        #expect(updated.windowDisplay[metadata.id] == displayID)
        #expect(updated.windowSpace[metadata.id] == spaceID)
        #expect(updated.observedVisibleWindows[workspaceKey] == [metadata.id])
        #expect(updated.spaces[spaceID]?.displays[displayID]?.floating == [metadata.id])
    }

    @Test("Upserting existing floating window sanitizes duplicates without appending")
    func upsertingExistingFloatingWindowSanitizesDuplicatesWithoutAppending() throws {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 2)
        let metadata = windowFixture(42)
        let displays = displaysFixture(displayID)
        let world = worldFixture(
            displayID: displayID,
            spaceID: spaceID,
            displays: displays,
            windows: [metadata],
            floating: [metadata.id, metadata.id]
        )

        let updated = try #require(worldByUpsertingActiveWindow(
            metadata,
            displayID: displayID,
            displays: displays,
            in: world
        ).successValue)

        #expect(updated.spaces[spaceID]?.displays[displayID]?.floating == [metadata.id])
    }

    @Test("Upserting active window fails without an active Space")
    func upsertingActiveWindowFailsWithoutAnActiveSpace() {
        let displayID = DisplayID(raw: 1)
        let metadata = windowFixture(42)
        let displays = displaysFixture(displayID)
        let world = World(
            displays: displays,
            activeSpace: nil,
            activeSpaceByDisplay: [:],
            spaces: [:],
            windows: [:],
            windowDisplay: [:],
            windowSpace: [:],
            observedVisibleWindows: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let result = worldByUpsertingActiveWindow(metadata, displayID: displayID, displays: displays, in: world)

        #expect(result == .failure(.activeSpaceUnavailable))
    }

    @Test("Recording window frames updates only known window frame fields")
    func recordingWindowFramesUpdatesOnlyKnownWindowFrameFields() throws {
        let known = windowFixture(1)
        let world = worldFixture(
            displayID: DisplayID(raw: 1),
            spaceID: SpaceID(raw: 2),
            displays: displaysFixture(DisplayID(raw: 1)),
            windows: [known],
            floating: [known.id]
        )
        let frame = CGRect(x: 100, y: 200, width: 500, height: 300)

        let updated = worldByRecordingWindowFrames([
            known.id: frame,
            WindowID(raw: 999): CGRect(x: 1, y: 1, width: 1, height: 1)
        ], in: world)

        let updatedWindow = try #require(updated.windows[known.id])
        #expect(updatedWindow.frame == frame)
        #expect(updatedWindow.bundleID == known.bundleID)
        #expect(updated.windows[WindowID(raw: 999)] == nil)
        #expect(updated.spaces == world.spaces)
    }

    private func worldFixture(
        displayID: DisplayID,
        spaceID: SpaceID,
        displays: [DisplayID: DisplayInfo],
        windows: [WindowMetadata],
        floating: [WindowID]
    ) -> World {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let windowDisplay = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, displayID) })
        let windowSpace = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) })
        return World(
            displays: displays,
            activeSpace: spaceID,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: .void, floating: floating)],
                    focused: nil
                )
            ],
            windows: windowsByID,
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func displaysFixture(_ displayID: DisplayID) -> [DisplayID: DisplayInfo] {
        [
            displayID: DisplayInfo(
                id: displayID,
                slot: 0,
                fingerprint: "main",
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760)
            )
        ]
    }

    private func windowFixture(_ raw: UInt32) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.\(raw)"),
            title: "Window \(raw)",
            role: "AXWindow",
            pid: ProcessID(raw),
            frame: CGRect(x: 10, y: 20, width: 300, height: 200),
            isResizable: true,
            isMinimized: false
        )
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
