import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Command application")
struct ApplyCommandTests {
    @Test("Move to next display retitles the window onto the next display")
    func moveToNextDisplayRetilesOntoNextDisplay() throws {
        let left = DisplayID(raw: 1)
        let right = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 10)
        let world = World(
            displays: [
                left: displayInfo(left, slot: 0, x: 0),
                right: displayInfo(right, slot: 1, x: 1000)
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        left: DisplaySpaceState(displayID: left, tree: pushIntoTree(window, .left, .void), floating: []),
                        right: DisplaySpaceState(displayID: right, tree: .void, floating: [])
                    ],
                    focused: window
                )
            ],
            windows: [window: metadata(window, x: 100, y: 100)],
            windowDisplay: [window: left],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.moveToNextDisplay(window), to: world) else {
            Issue.record("Expected moveToNextDisplay to succeed")
            return
        }

        #expect(next.windowDisplay[window] == right)
        #expect(next.spaces[space]?.focused == window)
        let leftTree = next.spaces[space]?.displays[left]?.tree
        let rightTree = next.spaces[space]?.displays[right]?.tree
        #expect(leftTree.map { occupiedWindows(in: $0) } == [])
        #expect(rightTree.map { occupiedWindows(in: $0) } == [window])
    }

    @Test("Focus cycle skips tiled windows")
    func focusCycleSkipsTiledWindows() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let tiled = WindowID(raw: 1)
        let firstFloating = WindowID(raw: 2)
        let secondFloating = WindowID(raw: 3)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: pushIntoTree(tiled, .left, .void),
                            floating: [firstFloating, secondFloating]
                        )
                    ],
                    focused: tiled
                )
            ],
            windows: [
                tiled: metadata(tiled, x: 0, y: 0),
                firstFloating: metadata(firstFloating, x: 200, y: 0),
                secondFloating: metadata(secondFloating, x: 400, y: 0)
            ],
            windowDisplay: [
                tiled: display,
                firstFloating: display,
                secondFloating: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.focusCycle(.next), to: world) else {
            Issue.record("Expected focusCycle to succeed")
            return
        }
        #expect(next.spaces[space]?.focused == firstFloating)

        guard case .success(let wrapped) = apply(.focusCycle(.previous), to: next) else {
            Issue.record("Expected focusCycle to wrap")
            return
        }
        #expect(wrapped.spaces[space]?.focused == secondFloating)
    }

    @Test("Focus cycle stays inside active Space floating windows")
    func focusCycleStaysInsideActiveSpaceFloatingWindows() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let inactiveSpace = SpaceID(raw: 2)
        let activeFloating = WindowID(raw: 10)
        let inactiveFloating = WindowID(raw: 20)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: .void, floating: [activeFloating])
                    ],
                    focused: nil
                ),
                inactiveSpace: SpaceState(
                    id: inactiveSpace,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: .void, floating: [inactiveFloating])
                    ],
                    focused: inactiveFloating
                )
            ],
            windows: [
                activeFloating: metadata(activeFloating, x: 400, y: 0),
                inactiveFloating: metadata(inactiveFloating, x: 0, y: 0)
            ],
            windowDisplay: [
                activeFloating: display,
                inactiveFloating: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.focusCycle(.next), to: world) else {
            Issue.record("Expected focusCycle to succeed")
            return
        }

        #expect(next.spaces[activeSpace]?.focused == activeFloating)
        #expect(next.spaces[inactiveSpace]?.focused == inactiveFloating)
    }

    @Test("Focus cycle fails instead of crossing Spaces when active Space has no floating windows")
    func focusCycleFailsInsteadOfCrossingSpacesWhenActiveSpaceHasNoFloatingWindows() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let inactiveSpace = SpaceID(raw: 2)
        let activeTiled = WindowID(raw: 10)
        let inactiveFloating = WindowID(raw: 20)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: pushIntoTree(activeTiled, .left, .void),
                            floating: []
                        )
                    ],
                    focused: activeTiled
                ),
                inactiveSpace: SpaceState(
                    id: inactiveSpace,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: .void, floating: [inactiveFloating])
                    ],
                    focused: inactiveFloating
                )
            ],
            windows: [
                activeTiled: metadata(activeTiled, x: 0, y: 0),
                inactiveFloating: metadata(inactiveFloating, x: 400, y: 0)
            ],
            windowDisplay: [
                activeTiled: display,
                inactiveFloating: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(apply(.focusCycle(.next), to: world) == .failure(.windowNotFound(activeTiled)))
    }

    @Test("Directional focus fallback stays inside active Space windows")
    func directionalFocusFallbackStaysInsideActiveSpaceWindows() throws {
        let display = DisplayID(raw: 1)
        let activeSpace = SpaceID(raw: 1)
        let inactiveSpace = SpaceID(raw: 2)
        let source = WindowID(raw: 10)
        let activeRight = WindowID(raw: 11)
        let inactiveRight = WindowID(raw: 20)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: .void, floating: [source, activeRight])
                    ],
                    focused: source
                ),
                inactiveSpace: SpaceState(
                    id: inactiveSpace,
                    displays: [
                        display: DisplaySpaceState(displayID: display, tree: .void, floating: [inactiveRight])
                    ],
                    focused: inactiveRight
                )
            ],
            windows: [
                source: metadata(source, x: 100, y: 0),
                activeRight: metadata(activeRight, x: 500, y: 0),
                inactiveRight: metadata(inactiveRight, x: 200, y: 0)
            ],
            windowDisplay: [
                source: display,
                activeRight: display,
                inactiveRight: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let next) = apply(.focusDirection(.right), to: world) else {
            Issue.record("Expected focusDirection to succeed")
            return
        }

        #expect(next.spaces[activeSpace]?.focused == activeRight)
        #expect(next.spaces[inactiveSpace]?.focused == inactiveRight)
    }

    @Test("Shuffle reset layouts all resizable windows as quarter-screen frames")
    func shuffleResetLayoutsResizableWindowsAsQuarterScreenFrames() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let fourth = WindowID(raw: 4)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: pushIntoTree(first, .left, .void),
                            floating: [second, third, fourth]
                        )
                    ],
                    focused: first
                )
            ],
            windows: [
                first: metadata(first, x: 0, y: 0),
                second: metadata(second, x: 500, y: 0),
                third: metadata(third, x: 0, y: 400),
                fourth: metadata(fourth, x: 500, y: 400)
            ],
            windowDisplay: [
                first: display,
                second: display,
                third: display,
                fourth: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        var generator = SeededGenerator(seed: 1)
        guard case .success(let layout) = shuffledResetLayout(in: world, using: &generator) else {
            Issue.record("Expected shuffle reset layout to succeed")
            return
        }

        #expect(Set(layout.tiled.keys) == [first, second, third, fourth])
        for frame in layout.tiled.values {
            #expect(frame.size == CGSize(width: 500, height: 400))
            #expect(frame.minX >= 0)
            #expect(frame.minY >= 0)
            #expect(frame.maxX <= 1000)
            #expect(frame.maxY <= 800)
        }
    }

    @Test("Cascade reset stacks resizable windows as offset quarter-screen frames")
    func cascadeResetStacksResizableWindowsAsOffsetQuarterScreenFrames() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: pushIntoTree(first, .left, .void),
                            floating: [second, third]
                        )
                    ],
                    focused: first
                )
            ],
            windows: [
                first: metadata(first, x: 0, y: 0),
                second: metadata(second, x: 500, y: 0),
                third: metadata(third, x: 0, y: 400)
            ],
            windowDisplay: [
                first: display,
                second: display,
                third: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let layout) = cascadeResetLayout(in: world) else {
            Issue.record("Expected cascade reset layout to succeed")
            return
        }

        #expect(layout.tiled[first] == CGRect(x: 0, y: 0, width: 500, height: 400))
        #expect(layout.tiled[second] == CGRect(x: 32, y: 32, width: 500, height: 400))
        #expect(layout.tiled[third] == CGRect(x: 64, y: 64, width: 500, height: 400))
    }

    @Test("Maximize reset targets the focused window visible frame")
    func maximizeResetTargetsFocusedWindowVisibleFrame() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 10)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: pushIntoTree(window, .left, .void), floating: [])],
                    focused: window
                )
            ],
            windows: [window: metadata(window, x: 100, y: 100)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        guard case .success(let layout) = maximizeResetLayout(windowID: window, in: world) else {
            Issue.record("Expected maximize reset layout to succeed")
            return
        }

        #expect(layout.tiled == [window: CGRect(x: 0, y: 0, width: 1000, height: 800)])
    }

    private func metadata(_ id: WindowID, x: Double, y: Double) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: CGRect(x: x, y: y, width: 100, height: 100),
            isResizable: true,
            isMinimized: false
        )
    }

    private func displayInfo(_ id: DisplayID, slot: Int, x: Double) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: slot,
            fingerprint: "display-\(id.raw)",
            frame: CGRect(x: x, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: 1000, height: 800)
        )
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
