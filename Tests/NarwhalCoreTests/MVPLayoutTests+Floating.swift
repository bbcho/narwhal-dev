import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
    @Test("Eject leaves the zone shape intact")
    func ejectLeavesZoneShapeIntact() throws {
        let window = WindowID(raw: 1)
        let ejected = ejectFromTree(window, pushIntoTree(window, .left, .void))

        guard case .split(let split) = ejected else {
            #expect(Bool(false), "Expected eject to preserve the split shape")
            throw TestAbort()
        }

        #expect(split.axis == .horizontal)
        #expect(split.cells.map(\.node) == [.void, .void])
    }

    @Test("Apply eject moves a tiled window to floating while preserving zone shape")
    func applyEjectMovesTiledWindowToFloating() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: second
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second)
            ],
            windowDisplay: [
                first: display,
                second: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [second: .forceFloat],
            config: .default
        )

        let next = try requireWorld(apply(.eject(second), to: world), "Expected eject to succeed")

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)
        let flattened = try requireLayout(flattenedLayout(of: next), "Expected eject layout to remain satisfiable")

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [second])
        #expect(next.spaces[space]?.focused == second)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(flattened.tiled == [first: CGRect(x: 0, y: 0, width: 600, height: 800)])
        #expect(flattened.floatingZOrder == [second])
    }

    @Test("Apply eject is idempotent for windows that are already floating")
    func applyEjectIsIdempotentForFloatingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(apply(.eject(window), to: world), "Expected ejecting an already-floating window to succeed")

        #expect(next.spaces[space]?.displays[display]?.tree == .void)
        #expect(next.spaces[space]?.displays[display]?.floating == [window])
        #expect(next.spaces[space]?.focused == window)
        #expect(next.windowDisplay[window] == display)
    }

    @Test("Apply eject rejects missing windows")
    func applyEjectRejectsMissingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let missing = WindowID(raw: 99)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [])],
                    focused: nil
                )
            ],
            windows: [:],
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.eject(missing), to: world) == .failure(.windowNotFound(missing)))
    }

    @Test("Apply toggleFloat moves tiled windows to floating")
    func applyToggleFloatMovesTiledWindowToFloating() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: second
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second, isResizable: false)
            ],
            windowDisplay: [
                first: display,
                second: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [second: .forceFloat],
            config: .default
        )

        let next = try requireWorld(apply(.toggleFloat(second), to: world), "Expected toggleFloat to float the tiled window")

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [second])
        #expect(next.spaces[space]?.focused == second)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
    }

    @Test("Apply toggleFloat tiles floating windows into the center anchor")
    func applyToggleFloatTilesFloatingWindowIntoCenterAnchor() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [window: .forceFloat],
            config: .default
        )

        let next = try requireWorld(apply(.toggleFloat(window), to: world), "Expected toggleFloat to tile the floating window")

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)
        let flattened = try requireLayout(flattenedLayout(of: next), "Expected toggleFloat layout to remain satisfiable")

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .occupied(window)),
            TreeSlot(path: [2], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [])
        #expect(next.spaces[space]?.focused == window)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(flattened.tiled == [window: CGRect(x: 300, y: 0, width: 600, height: 800)])
        #expect(flattened.floatingZOrder == [])
    }

    @Test("Apply toggleFloat can create the active Space for floating windows")
    func applyToggleFloatCreatesActiveSpaceForFloatingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [:],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(apply(.toggleFloat(window), to: world), "Expected toggleFloat to create the active Space")

        let nextTree = try #require(next.spaces[space]?.displays[display]?.tree)

        #expect(slots(in: nextTree) == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .occupied(window)),
            TreeSlot(path: [2], occupancy: .empty)
        ])
        #expect(next.spaces[space]?.displays[display]?.floating == [])
        #expect(next.spaces[space]?.focused == window)
    }

    @Test("Apply toggleFloat rejects non-resizable floating windows")
    func applyToggleFloatRejectsNonResizableFloatingWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window, isResizable: false)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.toggleFloat(window), to: world) == .failure(.windowNotResizable(window)))
    }
}
