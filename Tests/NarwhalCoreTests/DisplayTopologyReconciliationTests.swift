import CoreGraphics
import NarwhalCore
import Testing

@Suite("Display topology reconciliation")
struct DisplayTopologyReconciliationTests {
    private let laptopID = DisplayID(raw: 1)
    private let externalID = DisplayID(raw: 2)
    private let replacementID = DisplayID(raw: 9)
    private let spaceID = SpaceID(raw: 1)

    @Test("A visible-frame change reflows the existing tree into the new bounds")
    func visibleFrameChangeReflowsExistingTree() throws {
        let first = window(1, frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        let second = window(2, frame: CGRect(x: 500, y: 0, width: 500, height: 800))
        let tree = try split(.horizontal, [.leaf(first.id), .leaf(second.id)])
        let initialDisplay = display(laptopID, slot: 0, width: 1_000, height: 800)
        let resizedDisplay = display(laptopID, slot: 0, width: 1_600, height: 1_000)
        let original = world(
            displays: [laptopID: initialDisplay],
            displayStates: [laptopID: DisplaySpaceState(displayID: laptopID, tree: tree, floating: [])],
            windows: [first, second]
        )

        let reconciled = reconcileEnvironment(
            snapshot(displays: [laptopID: resizedDisplay], windows: [first, second]),
            in: original
        )
        let layout = try flattenedLayout(of: reconciled).get()

        #expect(reconciled.spaces[spaceID]?.displays[laptopID]?.tree == tree)
        #expect(layout.tiled[first.id] == CGRect(x: 0, y: 0, width: 800, height: 1_000))
        #expect(layout.tiled[second.id] == CGRect(x: 800, y: 0, width: 800, height: 1_000))
    }

    @Test("Adding an empty display leaves the laptop layout where it is")
    func addedDisplayDoesNotStealTiles() throws {
        let first = window(1, frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        let second = window(2, frame: CGRect(x: 500, y: 0, width: 500, height: 800))
        let tree = try split(.horizontal, [.leaf(first.id), .leaf(second.id)])
        let laptop = display(laptopID, slot: 0, width: 1_000, height: 800)
        let external = display(externalID, slot: 1, x: 1_000, width: 1_800, height: 1_000)
        let original = world(
            displays: [laptopID: laptop],
            displayStates: [laptopID: DisplaySpaceState(displayID: laptopID, tree: tree, floating: [])],
            windows: [first, second]
        )

        let reconciled = reconcileEnvironment(
            snapshot(displays: [laptopID: laptop, externalID: external], windows: [first, second]),
            in: original
        )

        #expect(reconciled.spaces[spaceID]?.displays[laptopID]?.tree == tree)
        #expect(reconciled.spaces[spaceID]?.displays[externalID]?.tree == .void)
        #expect(reconciled.windowDisplay[first.id] == laptopID)
        #expect(reconciled.windowDisplay[second.id] == laptopID)
    }

    @Test("Unplugging a display migrates and merges both live tile groups")
    func removedDisplayMergesLiveTileGroups() throws {
        let laptopWindow = window(1, frame: CGRect(x: 0, y: 0, width: 600, height: 1_000))
        let externalTop = window(2, frame: CGRect(x: 600, y: 0, width: 1_200, height: 500))
        let externalBottom = window(3, frame: CGRect(x: 600, y: 500, width: 1_200, height: 500))
        let externalTree = try split(.vertical, [.leaf(externalTop.id), .leaf(externalBottom.id)])
        let laptop = display(laptopID, slot: 0, width: 1_000, height: 800)
        let external = display(externalID, slot: 1, x: 1_000, width: 1_800, height: 1_000)
        let original = world(
            displays: [laptopID: laptop, externalID: external],
            displayStates: [
                laptopID: DisplaySpaceState(displayID: laptopID, tree: .leaf(laptopWindow.id), floating: []),
                externalID: DisplaySpaceState(displayID: externalID, tree: externalTree, floating: [])
            ],
            windows: [laptopWindow, externalTop, externalBottom]
        )
        let survivingDisplay = display(laptopID, slot: 0, width: 1_800, height: 1_000)

        let reconciled = reconcileEnvironment(
            snapshot(
                displays: [laptopID: survivingDisplay],
                windows: [laptopWindow, externalTop, externalBottom]
            ),
            in: original
        )
        let layout = try flattenedLayout(of: reconciled).get()

        #expect(reconciled.spaces[spaceID]?.displays[externalID] == nil)
        #expect(Set(occupiedWindows(in: reconciled.spaces[spaceID]?.displays[laptopID]?.tree ?? .void)) == [
            laptopWindow.id, externalTop.id, externalBottom.id
        ])
        #expect(layout.tiled[laptopWindow.id] == CGRect(x: 0, y: 0, width: 600, height: 1_000))
        #expect(layout.tiled[externalTop.id] == CGRect(x: 600, y: 0, width: 1_200, height: 500))
        #expect(layout.tiled[externalBottom.id] == CGRect(x: 600, y: 500, width: 1_200, height: 500))
    }

    @Test("Replacing the only display preserves the tile tree on the larger screen")
    func replacementDisplayPreservesTree() throws {
        let first = window(1, frame: CGRect(x: 0, y: 0, width: 1_200, height: 1_400))
        let second = window(2, frame: CGRect(x: 1_200, y: 0, width: 1_200, height: 1_400))
        let tree = try split(.horizontal, [.leaf(first.id), .leaf(second.id)])
        let laptop = display(laptopID, slot: 0, width: 1_000, height: 800)
        let replacement = display(replacementID, slot: 0, width: 2_400, height: 1_400)
        let original = world(
            displays: [laptopID: laptop],
            displayStates: [laptopID: DisplaySpaceState(displayID: laptopID, tree: tree, floating: [])],
            windows: [first, second]
        )

        let reconciled = reconcileEnvironment(
            snapshot(displays: [replacementID: replacement], windows: [first, second]),
            in: original
        )
        let layout = try flattenedLayout(of: reconciled).get()

        #expect(reconciled.spaces[spaceID]?.displays[laptopID] == nil)
        #expect(reconciled.spaces[spaceID]?.displays[replacementID]?.tree == tree)
        #expect(layout.tiled[first.id] == CGRect(x: 0, y: 0, width: 1_200, height: 1_400))
        #expect(layout.tiled[second.id] == CGRect(x: 1_200, y: 0, width: 1_200, height: 1_400))
    }

    @Test("Reconnecting a remembered display does not reclaim tiles that remain on the laptop")
    func returningDisplayDoesNotReclaimTiles() throws {
        let first = window(1, frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        let second = window(2, frame: CGRect(x: 500, y: 0, width: 500, height: 800))
        let laptopTree = try split(.horizontal, [.leaf(first.id), .leaf(second.id)])
        let laptop = display(laptopID, slot: 0, width: 1_000, height: 800)
        let external = display(externalID, slot: 1, x: 1_000, width: 1_800, height: 1_000)
        let original = world(
            displays: [laptopID: laptop],
            displayStates: [
                laptopID: DisplaySpaceState(displayID: laptopID, tree: laptopTree, floating: []),
                externalID: DisplaySpaceState(displayID: externalID, tree: .leaf(second.id), floating: [])
            ],
            windows: [first, second]
        )

        let reconciled = reconcileEnvironment(
            snapshot(displays: [laptopID: laptop, externalID: external], windows: [first, second]),
            in: original
        )

        #expect(reconciled.spaces[spaceID]?.displays[laptopID]?.tree == laptopTree)
        #expect(reconciled.spaces[spaceID]?.displays[externalID]?.tree == .void)
    }

    private func snapshot(
        displays: [DisplayID: DisplayInfo],
        windows: [WindowMetadata]
    ) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            activeSpace: spaceID,
            displays: displays,
            axSnapshot: AXWindowSnapshot(windows: windows, quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.keys.map { ($0, spaceID) }),
                windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) }),
                quality: .managedDisplaySpaces
            ),
            reconciliationMode: .displayTopologySettled
        )
    }

    private func world(
        displays: [DisplayID: DisplayInfo],
        displayStates: [DisplayID: DisplaySpaceState],
        windows: [WindowMetadata]
    ) -> World {
        World(
            displays: displays,
            activeSpace: spaceID,
            activeSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.keys.map { ($0, spaceID) }),
            spaces: [
                spaceID: SpaceState(id: spaceID, displays: displayStates, focused: windows.first?.id)
            ],
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }),
            windowDisplay: Dictionary(uniqueKeysWithValues: windows.compactMap { metadata in
                displayContainingFrame(metadata.frame, displays: displays).map { (metadata.id, $0) }
            }),
            windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) }),
            observedVisibleWindows: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func display(
        _ id: DisplayID,
        slot: Int,
        x: CGFloat = 0,
        width: CGFloat,
        height: CGFloat
    ) -> DisplayInfo {
        let frame = CGRect(x: x, y: 0, width: width, height: height)
        return DisplayInfo(id: id, slot: slot, fingerprint: "display-\(id.raw)", frame: frame, visibleFrame: frame)
    }

    private func window(_ raw: UInt32, frame: CGRect) -> WindowMetadata {
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

    private func split(_ axis: Axis, _ nodes: [Node]) throws -> Node {
        let cells = try nodes.map { try Cell.create(weight: 1, node: $0).get() }
        return .split(try Split.create(axis: axis, cells: cells).get())
    }
}
