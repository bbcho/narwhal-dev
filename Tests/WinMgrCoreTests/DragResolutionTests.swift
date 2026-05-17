import CoreGraphics
import Testing
@testable import WinMgrCore

@Suite("Drag zone resolution")
struct DragResolutionTests {
    @Test("Drop inside one zone resolves to dropAtZone command")
    func dropInsideOneZoneResolvesToCommand() {
        let window = WindowID(raw: 10)
        let display = DisplayID(raw: 1)
        let event = DragEvent(windowID: window, location: CGPoint(x: 100, y: 400), displayID: nil)

        let command = resolveDrop(
            event,
            zones: [zone("left", x: 0, y: 0, w: 0.25, h: 1, action: .insertAsHalf(.left))],
            displays: [display: displayInfo(display, x: 0, y: 0, width: 1000, height: 800)]
        )

        #expect(command == .dropAtZone(window, display, ZoneID(raw: "left")))
    }

    @Test("Drop on max zone edge resolves to no command")
    func dropOnMaxZoneEdgeResolvesToNoCommand() {
        let event = DragEvent(windowID: WindowID(raw: 11), location: CGPoint(x: 250, y: 400), displayID: nil)

        let command = resolveDrop(
            event,
            zones: [zone("left", x: 0, y: 0, w: 0.25, h: 1, action: .insertAsHalf(.left))],
            displays: [DisplayID(raw: 1): displayInfo(DisplayID(raw: 1), x: 0, y: 0, width: 1000, height: 800)]
        )

        #expect(command == nil)
    }

    @Test("Overlapping zones resolve to no command")
    func overlappingZonesResolveToNoCommand() {
        let event = DragEvent(windowID: WindowID(raw: 12), location: CGPoint(x: 200, y: 200), displayID: nil)

        let command = resolveDrop(
            event,
            zones: [
                zone("first", x: 0, y: 0, w: 0.4, h: 0.4, action: .insertAsHalf(.left)),
                zone("second", x: 0.1, y: 0.1, w: 0.4, h: 0.4, action: .insertAsHalf(.right))
            ],
            displays: [DisplayID(raw: 1): displayInfo(DisplayID(raw: 1), x: 0, y: 0, width: 1000, height: 800)]
        )

        #expect(command == nil)
    }

    @Test("Display-specific bounds choose the display containing the drop point")
    func displaySpecificBoundsChooseContainingDisplay() {
        let window = WindowID(raw: 13)
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let event = DragEvent(windowID: window, location: CGPoint(x: 1250, y: 400), displayID: nil)

        let command = resolveDrop(
            event,
            zones: [zone("left", x: 0, y: 0, w: 0.5, h: 1, action: .insertAsHalf(.left))],
            displays: [
                leftDisplay: displayInfo(leftDisplay, x: 0, y: 0, width: 1000, height: 800),
                rightDisplay: displayInfo(rightDisplay, x: 1000, y: 0, width: 1000, height: 800)
            ]
        )

        #expect(command == .dropAtZone(window, rightDisplay, ZoneID(raw: "left")))
    }

    @Test("Drop at half zone pushes window onto the target display")
    func dropAtHalfZonePushesWindowOntoTargetDisplay() throws {
        let window = WindowID(raw: 20)
        let sourceDisplay = DisplayID(raw: 1)
        let targetDisplay = DisplayID(raw: 2)
        let spaceID = SpaceID(raw: 1)
        let sourceTree = pushIntoTree(window, .left, .void)
        let world = worldWith(
            window: window,
            activeSpace: spaceID,
            displays: [
                sourceDisplay: displayInfo(sourceDisplay, x: 0, y: 0, width: 1000, height: 800),
                targetDisplay: displayInfo(targetDisplay, x: 1000, y: 0, width: 1000, height: 800)
            ],
            displayStates: [
                sourceDisplay: DisplaySpaceState(displayID: sourceDisplay, tree: sourceTree, floating: []),
                targetDisplay: DisplaySpaceState(displayID: targetDisplay, tree: .void, floating: [])
            ],
            windowDisplay: sourceDisplay,
            config: .default
        )

        guard case .success(let next) = apply(.dropAtZone(window, targetDisplay, ZoneID(raw: "right-half")), to: world) else {
            Issue.record("Expected half-zone drop to succeed")
            return
        }

        let sourceSlots = slots(in: try #require(next.spaces[spaceID]?.displays[sourceDisplay]?.tree))
        let targetFrames = layout(
            spaceState: try #require(next.spaces[spaceID]),
            displayID: targetDisplay,
            frame: try #require(next.displays[targetDisplay]?.visibleFrame),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        ).tiled

        #expect(sourceSlots == [
            TreeSlot(path: [0], occupancy: .empty),
            TreeSlot(path: [1], occupancy: .empty)
        ])
        #expect(next.windowDisplay[window] == targetDisplay)
        #expect(targetFrames[window] == CGRect(x: 1500, y: 0, width: 500, height: 800))
    }

    @Test("Drop at center zone creates the center anchor")
    func dropAtCenterZoneCreatesCenterAnchor() throws {
        let window = WindowID(raw: 21)
        let display = DisplayID(raw: 1)
        let world = worldWith(
            window: window,
            activeSpace: SpaceID(raw: 1),
            displays: [display: displayInfo(display, x: 0, y: 0, width: 1000, height: 800)],
            displayStates: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [])],
            windowDisplay: display,
            config: .default
        )

        guard case .success(let next) = apply(.dropAtZone(window, display, ZoneID(raw: "center")), to: world) else {
            Issue.record("Expected center-zone drop to succeed")
            return
        }

        let frames = layout(
            spaceState: try #require(next.spaces[SpaceID(raw: 1)]),
            displayID: display,
            frame: try #require(next.displays[display]?.visibleFrame),
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
        ).tiled

        #expect(frames[window] == CGRect(x: 250, y: 0, width: 500, height: 800))
    }

    @Test("Drop at unsupported zone action fails explicitly")
    func dropAtUnsupportedZoneActionFailsExplicitly() {
        let window = WindowID(raw: 22)
        let display = DisplayID(raw: 1)
        let config = Config(
            keymap: [],
            rules: [],
            zones: [zone("top-left", x: 0, y: 0, w: 0.5, h: 0.5, action: .insertAsQuarter(corner: .topLeft))],
            gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0)),
            border: .default,
            hud: .default,
            dragModifier: [.shift]
        )
        let world = worldWith(
            window: window,
            activeSpace: SpaceID(raw: 1),
            displays: [display: displayInfo(display, x: 0, y: 0, width: 1000, height: 800)],
            displayStates: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [])],
            windowDisplay: display,
            config: config
        )

        let result = apply(.dropAtZone(window, display, ZoneID(raw: "top-left")), to: world)

        #expect(result == .failure(.configInvalid("zone action is not implemented in the current MVP rung: insertAsQuarter(corner: WinMgrCore.Corner.topLeft)")))
    }

    private func zone(
        _ id: String,
        x: Double,
        y: Double,
        w: Double,
        h: Double,
        action: ZoneAction
    ) -> Zone {
        Zone(id: ZoneID(raw: id), bounds: ProportionalRect(x: x, y: y, w: w, h: h), action: action)
    }

    private func displayInfo(
        _ id: DisplayID,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: Int(id.raw),
            fingerprint: nil,
            frame: CGRect(x: x, y: y, width: width, height: height),
            visibleFrame: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func worldWith(
        window: WindowID,
        activeSpace: SpaceID,
        displays: [DisplayID: DisplayInfo],
        displayStates: [DisplayID: DisplaySpaceState],
        windowDisplay: DisplayID,
        config: Config
    ) -> World {
        World(
            displays: displays,
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(id: activeSpace, displays: displayStates, focused: nil)
            ],
            windows: [
                window: WindowMetadata(
                    id: window,
                    bundleID: BundleID(raw: "com.example"),
                    title: "Window \(window.raw)",
                    role: "AXWindow",
                    pid: 42,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    isResizable: true,
                    isMinimized: false
                )
            ],
            windowDisplay: [window: windowDisplay],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }
}
