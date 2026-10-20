import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
    @Test("External move onto another display updates ownership and floats the window there")
    func externalMoveOntoAnotherDisplayFloatsWindowThere() throws {
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let other = WindowID(raw: 2)
        let tree = pushIntoTree(window, .left, .void)
        let world = World(
            displays: [
                leftDisplay: self.display(leftDisplay, x: 0, width: 1200),
                rightDisplay: self.display(rightDisplay, x: 1200, width: 1200)
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: tree, floating: [other])],
                    focused: other
                )
            ],
            windows: [
                window: metadata(for: window, frame: CGRect(x: 100, y: 100, width: 300, height: 250)),
                other: metadata(for: other, frame: CGRect(x: 600, y: 200, width: 300, height: 250))
            ],
            windowDisplay: [
                window: leftDisplay,
                other: leftDisplay
            ],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [other: .forceFloat],
            config: .default
        )
        let movedFrame = CGRect(x: 1400, y: 80, width: 320, height: 280)

        let next = try requireWorld(apply(.windowMovedExternally(window, movedFrame), to: world), "Expected external move to succeed")

        #expect(next.windows[window]?.frame == movedFrame)
        #expect(next.windows[other] == world.windows[other])
        #expect(next.windowDisplay[window] == rightDisplay)
        #expect(next.spaces[space]?.displays == [
            leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: ejectFromTree(window, tree), floating: [other]),
            rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .void, floating: [window])
        ])
        #expect(next.displays == world.displays)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
        #expect(apply(.windowMovedExternally(window, movedFrame), to: next) == .success(next))
    }

    @Test("External resize updates size while preserving origin and layout state")
    func externalResizeUpdatesSizeOnly() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let originalFrame = CGRect(x: 100, y: 120, width: 300, height: 250)
        let resizedFrame = CGRect(x: 100, y: 120, width: 640, height: 360)
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
            windows: [window: metadata(for: window, frame: originalFrame)],
            windowDisplay: [window: display],
            windowConstraints: [window: WindowConstraints(minWidth: 500)],
            pendingRules: [window: .forceFloat],
            config: .default
        )

        let next = try requireWorld(apply(.windowResizedExternally(window, resizedFrame.size), to: world), "Expected external resize to succeed")

        #expect(next.windows[window]?.frame == resizedFrame)
        #expect(next.windowDisplay[window] == display)
        #expect(next.spaces == world.spaces)
        #expect(next.displays == world.displays)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("External resize of tiled window adjusts split weights and sibling frames")
    func externalResizeOfTiledWindowAdjustsSiblings() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let chrome = WindowID(raw: 1)
        let firefox = WindowID(raw: 2)
        let companion = WindowID(raw: 3)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(chrome)),
                try cell(weight: 1, node: .leaf(firefox))
            ]))),
            try cell(weight: 1, node: .leaf(companion))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: firefox
                )
            ],
            windows: [
                chrome: metadata(for: chrome, bundleID: "com.google.Chrome", frame: CGRect(x: 0, y: 0, width: 600, height: 400)),
                firefox: metadata(for: firefox, bundleID: "org.mozilla.firefox", frame: CGRect(x: 0, y: 400, width: 600, height: 400)),
                companion: metadata(for: companion, bundleID: "net.kovidgoyal.kitty", frame: CGRect(x: 600, y: 0, width: 600, height: 800))
            ],
            windowDisplay: [
                chrome: display,
                firefox: display,
                companion: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(
            apply(.windowResizedExternally(chrome, CGSize(width: 600, height: 500)), to: world),
            "Expected external resize to adjust tiled layout"
        )
        let flattened = try requireLayout(flattenedLayout(of: next), "Expected externally resized layout")

        #expect(next.windows[chrome]?.frame == CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(next.spaces[space]?.displays[display]?.tree == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1.25, node: .leaf(chrome)),
                try cell(weight: 0.75, node: .leaf(firefox))
            ]))),
            try cell(weight: 1, node: .leaf(companion))
        ])))
        #expect(flattened.tiled[chrome] == CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(flattened.tiled[firefox] == CGRect(x: 0, y: 500, width: 600, height: 300))
        #expect(flattened.tiled[companion] == CGRect(x: 600, y: 0, width: 600, height: 800))
        #expect(next.spaces[space]?.focused == firefox)
    }

    @Test("External bottom-row resize preserves the top row through command application")
    func externalBottomRowResizeUsesVisiblePartition() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let topLeft = WindowID(raw: 1)
        let topRight = WindowID(raw: 2)
        let bottomLeft = WindowID(raw: 3)
        let bottomRight = WindowID(raw: 4)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(topLeft)),
                try cell(weight: 1, node: .leaf(bottomLeft))
            ]))),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(topRight)),
                try cell(weight: 1, node: .leaf(bottomRight))
            ])))
        ]))
        let topLeftFrame = CGRect(x: 4, y: 4, width: 592, height: 392)
        let topRightFrame = CGRect(x: 604, y: 4, width: 592, height: 392)
        let bottomLeftFrame = CGRect(x: 4, y: 404, width: 592, height: 392)
        let bottomRightFrame = CGRect(x: 604, y: 404, width: 592, height: 392)
        let frames = [
            topLeft: topLeftFrame,
            topRight: topRightFrame,
            bottomLeft: bottomLeftFrame,
            bottomRight: bottomRightFrame
        ]
        let config = Config(
            keymap: Config.default.keymap,
            rules: Config.default.rules,
            zones: Config.default.zones,
            gaps: Gaps(inner: 8, outer: Insets(top: 0, left: 0, bottom: 0, right: 0)),
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier
        )
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1_200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: bottomLeft
                )
            ],
            windows: [
                topLeft: metadata(for: topLeft, frame: topLeftFrame),
                topRight: metadata(for: topRight, frame: topRightFrame),
                bottomLeft: metadata(for: bottomLeft, frame: bottomLeftFrame),
                bottomRight: metadata(for: bottomRight, frame: bottomRightFrame)
            ],
            windowDisplay: Dictionary(uniqueKeysWithValues: frames.keys.map { ($0, display) }),
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
        let requested = CGRect(x: 4, y: 404, width: 712, height: 392)

        let next = try requireWorld(
            apply(.windowMovedExternally(bottomLeft, requested), to: world),
            "Expected external resize to update the visible partition"
        )
        let flattened = try requireLayout(flattenedLayout(of: next), "Expected resized layout")

        #expect(flattened.tiled[topLeft] == frames[topLeft])
        #expect(flattened.tiled[topRight] == frames[topRight])
        #expect(flattened.tiled[bottomLeft] == requested)
        #expect(flattened.tiled[bottomRight] == CGRect(x: 724, y: 404, width: 472, height: 392))
    }

    @Test("Ambiguous external geometry detaches only the source window")
    func ambiguousExternalGeometryDetachesSource() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let source = WindowID(raw: 1)
        let sibling = WindowID(raw: 2)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(source)),
            try cell(weight: 1, node: .leaf(sibling))
        ]))
        let sourceFrame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let siblingFrame = CGRect(x: 600, y: 0, width: 600, height: 800)
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1_200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: source
                )
            ],
            windows: [
                source: metadata(for: source, frame: sourceFrame),
                sibling: metadata(for: sibling, frame: siblingFrame)
            ],
            windowDisplay: [source: display, sibling: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let movedAndResized = CGRect(x: 20, y: 0, width: 700, height: 800)

        let next = try requireWorld(
            apply(.windowMovedExternally(source, movedAndResized), to: world),
            "Expected ambiguous manual geometry to detach safely"
        )
        let displayState = try #require(next.spaces[space]?.displays[display])

        #expect(displayState.tree == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .void),
            try cell(weight: 1, node: .leaf(sibling))
        ])))
        #expect(displayState.floating == [source])
        #expect(next.windows[source]?.frame == movedAndResized)
    }

    @Test("External resize of tiled window preserves nil focus")
    func externalResizeOfTiledWindowPreservesNilFocus() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let chrome = WindowID(raw: 1)
        let firefox = WindowID(raw: 2)
        let tree = Node.split(try split(axis: .vertical, cells: [
            try cell(weight: 1, node: .leaf(chrome)),
            try cell(weight: 1, node: .leaf(firefox))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: nil
                )
            ],
            windows: [
                chrome: metadata(for: chrome, frame: CGRect(x: 0, y: 0, width: 1200, height: 400)),
                firefox: metadata(for: firefox, frame: CGRect(x: 0, y: 400, width: 1200, height: 400))
            ],
            windowDisplay: [
                chrome: display,
                firefox: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(
            apply(.windowResizedExternally(chrome, CGSize(width: 1200, height: 500)), to: world),
            "Expected external resize to adjust tiled layout"
        )

        #expect(next.windows[chrome]?.frame == CGRect(x: 0, y: 0, width: 1200, height: 500))
        #expect(next.spaces[space]?.displays[display]?.tree == Node.split(try split(axis: .vertical, cells: [
            try cell(weight: 1.25, node: .leaf(chrome)),
            try cell(weight: 0.75, node: .leaf(firefox))
        ])))
        #expect(next.spaces[space]?.focused == nil)
    }

    @Test("Tiled border targets follow externally resized tiled window frames")
    func tiledBorderTargetsFollowExternallyResizedTiledFrames() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let sibling = WindowID(raw: 2)
        let originalFrame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let siblingFrame = CGRect(x: 600, y: 0, width: 600, height: 800)
        let resizedFrame = CGRect(x: 0, y: 0, width: 700, height: 800)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(window)),
            try cell(weight: 1, node: .leaf(sibling))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: tree,
                            floating: []
                        )
                    ],
                    focused: window
                )
            ],
            windows: [
                window: metadata(for: window, frame: originalFrame),
                sibling: metadata(for: sibling, frame: siblingFrame)
            ],
            windowDisplay: [window: display, sibling: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let resized = try requireWorld(
            apply(.windowResizedExternally(window, resizedFrame.size), to: world),
            "Expected external resize to succeed"
        )
        let targets = try requireSuccess(
            tiledBorderTargets(of: resized),
            "Expected tiled border target calculation to succeed"
        )

        #expect(targets.map(\.windowID) == [window, sibling])
        #expect(targets.first(where: { $0.windowID == window })?.frame == resizedFrame)
    }
}
