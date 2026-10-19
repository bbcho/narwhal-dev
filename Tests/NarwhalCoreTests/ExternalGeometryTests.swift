import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("External geometry")
struct ExternalGeometryTests {
    private let spaceID = SpaceID(raw: 1)
    private let leftDisplay = DisplayID(raw: 1)
    private let rightDisplay = DisplayID(raw: 2)
    private let source = WindowID(raw: 1)
    private let sibling = WindowID(raw: 2)

    @Test("An outer-edge resize keeps the window tiled so it can snap back")
    func outerEdgeResizeKeepsWindowTiled() throws {
        let world = try twoColumnWorld()
        let draggedOuterEdge = CGRect(x: 20, y: 0, width: 580, height: 800)

        let next = try apply(.windowMovedExternally(source, draggedOuterEdge), to: world).get()

        #expect(next.spaces == world.spaces)
        #expect(next.windows[source]?.frame == draggedOuterEdge)
    }

    @Test("A resize below a neighbor's minimum size keeps the window tiled so it can snap back")
    func resizeBelowNeighborMinimumKeepsWindowTiled() throws {
        let world = try twoColumnWorld(constraints: [sibling: WindowConstraints(minWidth: 500)])
        let squeezesSibling = CGRect(x: 0, y: 0, width: 800, height: 800)

        let next = try apply(.windowMovedExternally(source, squeezesSibling), to: world).get()

        #expect(next.spaces == world.spaces)
        #expect(next.windows[source]?.frame == squeezesSibling)
    }

    @Test("Moving a tiled window onto another display floats it on that display")
    func moveOntoAnotherDisplayFloatsWindowThere() throws {
        let world = try twoColumnWorld()
        let onRightDisplay = CGRect(x: 1_300, y: 0, width: 600, height: 800)

        let next = try apply(.windowMovedExternally(source, onRightDisplay), to: world).get()
        let displays = try #require(next.spaces[spaceID]?.displays)

        #expect(displays[leftDisplay] == DisplaySpaceState(
            displayID: leftDisplay,
            tree: .split(try Split.create(axis: .horizontal, cells: [
                try Cell.create(weight: 1, node: .void).get(),
                try Cell.create(weight: 1, node: .leaf(sibling)).get()
            ]).get()),
            floating: []
        ))
        #expect(displays[rightDisplay] == DisplaySpaceState(
            displayID: rightDisplay,
            tree: .void,
            floating: [source]
        ))
        #expect(next.windowDisplay[source] == rightDisplay)
    }

    private func twoColumnWorld(constraints: [WindowID: WindowConstraints] = [:]) throws -> World {
        let tree = Node.split(try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1, node: .leaf(source)).get(),
            try Cell.create(weight: 1, node: .leaf(sibling)).get()
        ]).get())
        return World(
            displays: [
                leftDisplay: display(leftDisplay, x: 0),
                rightDisplay: display(rightDisplay, x: 1_200)
            ],
            activeSpace: spaceID,
            activeSpaceByDisplay: [leftDisplay: spaceID, rightDisplay: spaceID],
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [
                        leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: tree, floating: []),
                        rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .void, floating: [])
                    ],
                    focused: source
                )
            ],
            windows: [
                source: window(source, frame: CGRect(x: 0, y: 0, width: 600, height: 800)),
                sibling: window(sibling, frame: CGRect(x: 600, y: 0, width: 600, height: 800))
            ],
            windowDisplay: [source: leftDisplay, sibling: leftDisplay],
            windowSpace: [source: spaceID, sibling: spaceID],
            observedVisibleWindows: [
                WorkspaceKey(displayID: leftDisplay, spaceID: spaceID): [source, sibling]
            ],
            windowConstraints: constraints,
            pendingRules: [:],
            config: .default
        )
    }

    private func display(_ id: DisplayID, x: CGFloat) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: Int(id.raw) - 1,
            fingerprint: "display-\(id.raw)",
            frame: CGRect(x: x, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: 1_200, height: 800)
        )
    }

    private func window(_ id: WindowID, frame: CGRect) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.\(id.raw)"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }
}
