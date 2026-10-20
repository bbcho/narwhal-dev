import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
    @Test("Apply focus records focused window without changing layout state")
    func applyFocusRecordsFocusedWindowOnly() throws {
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
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [second])],
                    focused: first
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

        let next = try requireWorld(apply(.focus(second), to: world), "Expected focus to succeed")

        #expect(next.spaces[space]?.focused == second)
        #expect(next.spaces[space]?.displays == world.spaces[space]?.displays)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Apply focus can create the active Space focus record")
    func applyFocusCreatesActiveSpaceFocusRecord() throws {
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

        let next = try requireWorld(apply(.focus(window), to: world), "Expected focus to create active Space state")

        #expect(next.spaces[space] == SpaceState(id: space, displays: [:], focused: window))
    }

    @Test("Apply focus rejects missing windows and missing active Space")
    func applyFocusRejectsInvalidState() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let missing = WindowID(raw: 99)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [space: SpaceState(id: space, displays: [:], focused: nil)],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let noActiveSpace = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: nil,
            spaces: [:],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.focus(missing), to: world) == .failure(.windowNotFound(missing)))
        #expect(apply(.focus(window), to: noActiveSpace) == .failure(.activeSpaceUnavailable))
    }

    @Test("Apply focusDirection selects the adjacent tiled window without changing layout state")
    func applyFocusDirectionSelectsAdjacentTiledWindow() throws {
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
                    focused: first
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

        let next = try requireWorld(apply(.focusDirection(.right), to: world), "Expected focusDirection to succeed")

        #expect(next.spaces[space]?.focused == second)
        #expect(next.spaces[space]?.displays == world.spaces[space]?.displays)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Apply focusDirection rejects missing focus and missing neighbors")
    func applyFocusDirectionRejectsInvalidState() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let focusedWorld = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .leaf(window), floating: [])],
                    focused: window
                )
            ],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let noFocusWorld = World(
            displays: focusedWorld.displays,
            activeSpace: focusedWorld.activeSpace,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: focusedWorld.spaces[space]?.displays ?? [:],
                    focused: nil
                )
            ],
            windows: focusedWorld.windows,
            windowDisplay: focusedWorld.windowDisplay,
            windowConstraints: focusedWorld.windowConstraints,
            pendingRules: focusedWorld.pendingRules,
            config: focusedWorld.config
        )

        #expect(apply(.focusDirection(.right), to: noFocusWorld) == .failure(.activeSpaceUnavailable))
        #expect(apply(.focusDirection(.right), to: focusedWorld) == .failure(.noNeighbor(.right)))
    }

    @Test("Apply focusDirection can target visible floating windows by frame")
    func applyFocusDirectionCanTargetFloatingWindowsByFrame() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let left = WindowID(raw: 1)
        let right = WindowID(raw: 2)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [left, right])],
                    focused: left
                )
            ],
            windows: [
                left: metadata(for: left, frame: CGRect(x: 0, y: 0, width: 500, height: 800)),
                right: metadata(for: right, frame: CGRect(x: 600, y: 0, width: 500, height: 800))
            ],
            windowDisplay: [
                left: display,
                right: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(
            apply(.focusDirection(.right), to: world),
            "Expected focusDirection to use visible floating window frames"
        )

        #expect(next.spaces[space]?.focused == right)
        #expect(next.spaces[space]?.displays == world.spaces[space]?.displays)
    }

    @Test("Apply focusCycle follows observed window frame order without changing layout state")
    func applyFocusCycleFollowsWindowFrameOrder() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let topLeft = WindowID(raw: 1)
        let topRight = WindowID(raw: 2)
        let bottomLeft = WindowID(raw: 3)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [topLeft, topRight, bottomLeft])],
                    focused: topLeft
                )
            ],
            windows: [
                topLeft: metadata(for: topLeft, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                topRight: metadata(for: topRight, frame: CGRect(x: 300, y: 0, width: 100, height: 100)),
                bottomLeft: metadata(for: bottomLeft, frame: CGRect(x: 0, y: 300, width: 100, height: 100))
            ],
            windowDisplay: [
                topLeft: display,
                topRight: display,
                bottomLeft: display
            ],
            windowConstraints: [topRight: WindowConstraints(minWidth: 500)],
            pendingRules: [bottomLeft: .forceFloat],
            config: .default
        )

        let next = try requireWorld(apply(.focusCycle(.next), to: world), "Expected next focus cycle to succeed")
        let previous = try requireWorld(apply(.focusCycle(.previous), to: world), "Expected previous focus cycle to succeed")

        #expect(next.spaces[space]?.focused == topRight)
        #expect(previous.spaces[space]?.focused == bottomLeft)
        #expect(next.spaces[space]?.displays == world.spaces[space]?.displays)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Focus cycle uses one representative window per app bundle")
    func focusCycleUsesOneRepresentativeWindowPerAppBundle() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let firefoxA = WindowID(raw: 1)
        let firefoxB = WindowID(raw: 2)
        let chromeA = WindowID(raw: 3)
        let chromeB = WindowID(raw: 4)
        let terminal = WindowID(raw: 5)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1400)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: .void,
                            floating: [firefoxA, firefoxB, chromeA, chromeB, terminal]
                        )
                    ],
                    focused: firefoxB
                )
            ],
            windows: [
                firefoxA: metadata(for: firefoxA, bundleID: "org.mozilla.firefox", frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                firefoxB: metadata(for: firefoxB, bundleID: "org.mozilla.firefox", frame: CGRect(x: 20, y: 20, width: 100, height: 100)),
                chromeA: metadata(for: chromeA, bundleID: "com.google.Chrome", frame: CGRect(x: 300, y: 0, width: 100, height: 100)),
                chromeB: metadata(for: chromeB, bundleID: "com.google.Chrome", frame: CGRect(x: 320, y: 20, width: 100, height: 100)),
                terminal: metadata(for: terminal, bundleID: "com.apple.Terminal", frame: CGRect(x: 600, y: 0, width: 100, height: 100))
            ],
            windowDisplay: [
                firefoxA: display,
                firefoxB: display,
                chromeA: display,
                chromeB: display,
                terminal: display
            ],
            windowSpace: [
                firefoxA: space,
                firefoxB: space,
                chromeA: space,
                chromeB: space,
                terminal: space
            ],
            observedVisibleWindows: [
                WorkspaceKey(displayID: display, spaceID: space): [firefoxA, firefoxB, chromeA, chromeB, terminal]
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let candidates = focusCycleWindows(in: world, focusedWindowID: firefoxB).map(\.id)
        let cycle = focusCycleCandidates(windows: focusCycleWindows(in: world, focusedWindowID: firefoxB), from: firefoxB, direction: .next)

        #expect(candidates == [firefoxB, chromeA, terminal])
        #expect(cycle == [chromeA, terminal, firefoxB])
    }
}
