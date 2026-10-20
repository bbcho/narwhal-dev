import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
    @Test("Swap primitive exchanges occupied leaves without changing zone paths")
    func swapPrimitiveExchangesLeavesOnly() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let tree = pushIntoTree(c, .left, pushIntoTree(b, .right, pushIntoTree(a, .left, .void)))
        let swapped = swapWindowsInTree(a, b, tree)

        #expect(slots(in: swapped) == [
            TreeSlot(path: [0, 0], occupancy: .occupied(b)),
            TreeSlot(path: [0, 1], occupancy: .occupied(c)),
            TreeSlot(path: [1], occupancy: .occupied(a))
        ])

        let result = frames(for: swapped)
        #expect(result[b] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(result[c] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(result[a] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Apply swap exchanges the focused source with its directional neighbor")
    func applySwapExchangesDirectionalNeighbor() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: pushIntoTree(b, .right, pushIntoTree(a, .left, .void)),
                            floating: []
                        )
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a), b: metadata(for: b)],
            windowDisplay: [a: displayID, b: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(apply(.swapInTree(a, .right), to: world), "Expected swap right to succeed")
        let nextFrames = try requireLayout(flattenedLayout(of: next), "Expected swapped layout to solve").tiled
        #expect(nextFrames[b] == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(nextFrames[a] == CGRect(x: 500, y: 0, width: 500, height: 800))
        #expect(next.spaces[space]?.focused == a)
        #expect(next.windowDisplay == [a: displayID, b: displayID])
    }

    @Test("Apply swap stays inside one display workspace")
    func applySwapRejectsNeighborOnAnotherDisplay() throws {
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let world = World(
            displays: [
                leftDisplay: display(leftDisplay, x: 0, width: 1000),
                rightDisplay: display(rightDisplay, x: 1000, width: 1000)
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: pushIntoTree(a, .left, .void), floating: []),
                        rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: pushIntoTree(b, .right, .void), floating: [])
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a), b: metadata(for: b)],
            windowDisplay: [a: leftDisplay, b: rightDisplay],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.swapInTree(a, .right), to: world) == .failure(.noNeighbor(.right)))
    }

    @Test("Apply swap rejects untiled source windows")
    func applySwapRejectsUntiledSource() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(displayID: displayID, tree: pushIntoTree(b, .right, .void), floating: [a])
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a), b: metadata(for: b)],
            windowDisplay: [a: displayID, b: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.swapInTree(a, .right), to: world) == .failure(.windowIsFloating(a)))
    }

    @Test("Apply swap rejects missing directional neighbors")
    func applySwapRejectsMissingNeighbor() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(displayID: displayID, tree: pushIntoTree(a, .left, .void), floating: [])
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a)],
            windowDisplay: [a: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.swapInTree(a, .right), to: world) == .failure(.noNeighbor(.right)))
    }

    @Test("Apply swap rejects stale target leaves without metadata")
    func applySwapRejectsStaleTargetLeaf() throws {
        let displayID = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let a = WindowID(raw: 1)
        let stale = WindowID(raw: 2)
        let world = World(
            displays: [displayID: display(displayID, x: 0, width: 1000)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: pushIntoTree(stale, .right, pushIntoTree(a, .left, .void)),
                            floating: []
                        )
                    ],
                    focused: a
                )
            ],
            windows: [a: metadata(for: a)],
            windowDisplay: [a: displayID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.swapInTree(a, .right), to: world) == .failure(.windowNotFound(stale)))
    }
}
