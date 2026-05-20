import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Window rule integration")
struct WindowRuleIntegrationTests {
    @Test("Window opened applies force-float rule to world state")
    func windowOpenedAppliesForceFloatRule() {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 10)
        let metadata = metadata(window, bundleID: "com.example.float")
        let world = emptyWorld(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            config: config(rules: [
                WindowRule(predicate: .bundleID("com.example.float"), action: .forceFloat)
            ])
        )

        guard case .success(let next) = apply(.windowOpened(metadata), to: world) else {
            Issue.record("Expected windowOpened to succeed")
            return
        }

        #expect(next.windows == [window: metadata])
        #expect(next.windowDisplay == [window: display])
        #expect(next.pendingRules == [window: .forceFloat])
        #expect(next.spaces[space]?.displays[display]?.tree == .void)
        #expect(next.spaces[space]?.displays[display]?.floating == [window])
    }

    @Test("Window opened applies ignore rule by leaving the window untracked")
    func windowOpenedAppliesIgnoreRule() {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let metadata = metadata(WindowID(raw: 20), bundleID: "com.example.ignore")
        let world = emptyWorld(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            config: config(rules: [
                WindowRule(predicate: .bundleID("com.example.ignore"), action: .ignore)
            ])
        )

        guard case .success(let next) = apply(.windowOpened(metadata), to: world) else {
            Issue.record("Expected windowOpened to succeed")
            return
        }

        #expect(next.windows.isEmpty)
        #expect(next.windowDisplay.isEmpty)
        #expect(next.pendingRules.isEmpty)
        #expect(next.spaces[space]?.displays[display]?.tree == .void)
        #expect(next.spaces[space]?.displays[display]?.floating == [])
    }

    @Test("Window opened applies pin-to-display rule using display slot before frame ownership")
    func windowOpenedAppliesPinToDisplayRule() {
        let left = DisplayID(raw: 1)
        let right = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 30)
        let metadata = metadata(
            window,
            bundleID: "com.example.pin",
            frame: CGRect(x: 100, y: 0, width: 300, height: 300)
        )
        let world = emptyWorld(
            displays: [
                left: displayInfo(left, slot: 0, x: 0),
                right: displayInfo(right, slot: 1, x: 1000)
            ],
            activeSpace: space,
            config: config(rules: [
                WindowRule(predicate: .bundleID("com.example.pin"), action: .pinToDisplay(slot: 1))
            ])
        )

        guard case .success(let next) = apply(.windowOpened(metadata), to: world) else {
            Issue.record("Expected windowOpened to succeed")
            return
        }

        #expect(next.windows == [window: metadata])
        #expect(next.windowDisplay == [window: right])
        #expect(next.pendingRules == [window: .pinToDisplay(slot: 1)])
        #expect(next.spaces[space]?.displays[left]?.floating == [])
        #expect(next.spaces[space]?.displays[right]?.tree == .void)
        #expect(next.spaces[space]?.displays[right]?.floating == [window])
    }

    @Test("Window opened records tile-to-zone rule for later placement")
    func windowOpenedRecordsTileToZoneRule() {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 40)
        let metadata = metadata(window, bundleID: "com.example.tile")
        let world = emptyWorld(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            config: config(rules: [
                WindowRule(predicate: .bundleID("com.example.tile"), action: .tileToZone(ZoneID(raw: "center")))
            ])
        )

        guard case .success(let next) = apply(.windowOpened(metadata), to: world) else {
            Issue.record("Expected windowOpened to succeed")
            return
        }

        #expect(next.windows == [window: metadata])
        #expect(next.windowDisplay == [window: display])
        #expect(next.pendingRules == [window: .tileToZone(ZoneID(raw: "center"))])
        #expect(next.spaces[space]?.displays[display]?.tree == .void)
        #expect(next.spaces[space]?.displays[display]?.floating == [window])
    }

    @Test("Pending tile rule application tiles active floating windows and clears applied rules")
    func pendingTileRuleApplicationTilesActiveFloatingWindows() {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 50)
        let metadata = metadata(window, bundleID: "com.example.pending")
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: nil
                )
            ],
            windows: [window: metadata],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [window: .tileToZone(ZoneID(raw: "center"))],
            config: .default
        )

        guard case .success(.some(let plan)) = applyingPendingTileRules(in: world) else {
            Issue.record("Expected pending tile rule application to succeed")
            return
        }

        #expect(plan.focusedWindowID == window)
        #expect(plan.world.pendingRules.isEmpty)
        #expect(plan.world.spaces[space]?.displays[display]?.floating == [])
        let tree: Node? = plan.world.spaces[space]?.displays[display]?.tree
        #expect(tree.map { occupiedWindows(in: $0) } == [window])
    }

    @Test("Pending tile rule application ignores inactive pending windows")
    func pendingTileRuleApplicationIgnoresInactiveWindows() {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 60)
        let metadata = metadata(window, bundleID: "com.example.inactive")
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [])],
                    focused: nil
                )
            ],
            windows: [window: metadata],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [window: .tileToZone(ZoneID(raw: "center"))],
            config: .default
        )

        guard case .success(nil) = applyingPendingTileRules(in: world) else {
            Issue.record("Expected inactive pending rule to produce no plan")
            return
        }
    }

    @Test("Pending tile rule application returns command failures explicitly")
    func pendingTileRuleApplicationReturnsCommandFailures() {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 70)
        let metadata = metadata(window, bundleID: "com.example.bad-zone")
        let missingZone = ZoneID(raw: "missing")
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [window])],
                    focused: nil
                )
            ],
            windows: [window: metadata],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [window: .tileToZone(missingZone)],
            config: .default
        )

        #expect(applyingPendingTileRules(in: world) == .failure(.zoneNotFound(missingZone)))
    }

    @Test("Window closed command prunes metadata, ownership, pending rules, constraints, focus, and tree leaves")
    func windowClosedPrunesWorldState() {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let closed = WindowID(raw: 2)
        let tree = pushIntoTree(closed, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [closed])],
                    focused: closed
                )
            ],
            windows: [
                first: metadata(first, bundleID: "com.example.keep"),
                closed: metadata(closed, bundleID: "com.example.close")
            ],
            windowDisplay: [first: display, closed: display],
            windowConstraints: [closed: WindowConstraints(minWidth: 500)],
            pendingRules: [closed: .forceFloat],
            config: .default
        )

        guard case .success(let next) = apply(.windowClosed(closed), to: world) else {
            Issue.record("Expected windowClosed to succeed")
            return
        }

        #expect(next.windows == [first: metadata(first, bundleID: "com.example.keep")])
        #expect(next.windowDisplay == [first: display])
        #expect(next.windowConstraints.isEmpty)
        #expect(next.pendingRules.isEmpty)
        #expect(next.spaces[space]?.focused == nil)
        #expect(next.spaces[space]?.displays[display]?.floating == [])
        let nextTree = next.spaces[space]?.displays[display]?.tree
        #expect(nextTree.map { slots(in: $0) } == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .empty)
        ])
    }

    @Test("Complete environment refresh applies rules only to newly discovered windows")
    func environmentRefreshAppliesRulesToNewWindowsOnly() {
        let left = DisplayID(raw: 1)
        let right = DisplayID(raw: 2)
        let space = SpaceID(raw: 1)
        let existing = WindowID(raw: 1)
        let ignored = WindowID(raw: 2)
        let floating = WindowID(raw: 3)
        let pinned = WindowID(raw: 4)
        let existingMetadata = metadata(existing, bundleID: "com.example.ignore")
        let ignoredMetadata = metadata(ignored, bundleID: "com.example.ignore")
        let floatingMetadata = metadata(floating, bundleID: "com.example.float")
        let pinnedMetadata = metadata(pinned, bundleID: "com.example.pin")
        let displays = [
            left: displayInfo(left, slot: 0, x: 0),
            right: displayInfo(right, slot: 1, x: 1000)
        ]
        let world = World(
            displays: displays,
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        left: DisplaySpaceState(displayID: left, tree: .void, floating: [existing]),
                        right: DisplaySpaceState(displayID: right, tree: .void, floating: [])
                    ],
                    focused: existing
                )
            ],
            windows: [existing: existingMetadata],
            windowDisplay: [existing: left],
            windowConstraints: [:],
            pendingRules: [:],
            config: config(rules: [
                WindowRule(predicate: .bundleID("com.example.ignore"), action: .ignore),
                WindowRule(predicate: .bundleID("com.example.float"), action: .forceFloat),
                WindowRule(predicate: .bundleID("com.example.pin"), action: .pinToDisplay(slot: 1))
            ])
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: space,
            displays: displays,
            axSnapshot: AXWindowSnapshot(
                windows: [existingMetadata, ignoredMetadata, floatingMetadata, pinnedMetadata],
                quality: .complete
            )
        )

        guard case .success(let next) = apply(.environmentChanged(snapshot), to: world) else {
            Issue.record("Expected environmentChanged to succeed")
            return
        }

        #expect(next.windows == [
            existing: existingMetadata,
            floating: floatingMetadata,
            pinned: pinnedMetadata
        ])
        #expect(next.windowDisplay == [existing: left, floating: left, pinned: right])
        #expect(next.pendingRules == [
            floating: .forceFloat,
            pinned: .pinToDisplay(slot: 1)
        ])
        #expect(next.spaces[space]?.focused == existing)
        #expect(next.spaces[space]?.displays[left]?.floating == [existing, floating])
        #expect(next.spaces[space]?.displays[right]?.floating == [pinned])
    }

    private func emptyWorld(
        displays: [DisplayID: DisplayInfo],
        activeSpace: SpaceID,
        config: Config
    ) -> World {
        World(
            displays: displays,
            activeSpace: activeSpace,
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: displays.mapValues { DisplaySpaceState(displayID: $0.id, tree: .void, floating: []) },
                    focused: nil
                )
            ],
            windows: [:],
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }

    private func config(rules: [WindowRule]) -> Config {
        Config(
            keymap: Config.default.keymap,
            rules: rules,
            zones: Config.default.zones,
            gaps: Config.default.gaps,
            border: .default,
            hud: .default,
            dragModifier: Config.default.dragModifier
        )
    }

    private func metadata(
        _ id: WindowID,
        bundleID: String,
        frame: CGRect = CGRect(x: 100, y: 100, width: 300, height: 300),
        isResizable: Bool = true
    ) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: bundleID),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: frame,
            isResizable: isResizable,
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
