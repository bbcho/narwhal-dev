import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Managed minimum sizes")
struct ManagedConstraintTests {
    private let spaceID = SpaceID(raw: 1)
    private let displayID = DisplayID(raw: 1)
    private let left = WindowID(raw: 1)
    private let right = WindowID(raw: 2)

    @Test("A managed minimum width shapes the layout")
    func managedMinimumShapesLayout() throws {
        let world = try twoColumnWorld(leftMinimumWidth: 800)

        let layout = try flattenedLayout(of: world).get()

        #expect(layout.tiled[left] == CGRect(x: 0, y: 0, width: 800, height: 800))
    }

    @Test("Lowering a managed minimum width on reload shrinks open windows to the new minimum")
    func loweringManagedMinimumOnReloadTakesEffect() throws {
        let world = try twoColumnWorld(leftMinimumWidth: 800)

        let reloaded = try apply(.reloadConfig(config(leftMinimumWidth: 700)), to: world).get()
        let layout = try flattenedLayout(of: reloaded).get()

        #expect(layout.tiled[left] == CGRect(x: 0, y: 0, width: 700, height: 800))
    }

    @Test("Deleting a managed rule on reload removes its minimum from open windows")
    func deletingManagedRuleOnReloadRemovesMinimum() throws {
        let world = try twoColumnWorld(leftMinimumWidth: 800)

        let reloaded = try apply(.reloadConfig(.default), to: world).get()

        #expect(effectiveWindowConstraints(in: reloaded) == [:])
        #expect(try flattenedLayout(of: reloaded).get().tiled[left] == CGRect(x: 0, y: 0, width: 600, height: 800))
    }

    @Test("A window opened under a managed rule follows a lowered minimum after reload")
    func openedWindowFollowsLoweredMinimumAfterReload() throws {
        let world = try twoColumnWorld(leftMinimumWidth: 800)
        let opened = WindowID(raw: 7)
        let openedWindow = WindowMetadata(
            id: opened,
            bundleID: BundleID(raw: "com.example.left"),
            title: "Opened",
            role: "AXWindow",
            pid: 7,
            frame: CGRect(x: 100, y: 100, width: 400, height: 400),
            isResizable: true,
            isMinimized: false
        )

        let afterOpen = try apply(.windowOpened(openedWindow), to: world).get()
        let reloaded = try apply(.reloadConfig(config(leftMinimumWidth: 700)), to: afterOpen).get()

        #expect(afterOpen.windowConstraints[opened] == nil)
        #expect(effectiveWindowConstraints(in: reloaded)[opened] == WindowConstraints(minWidth: 700))
    }

    @Test("Effective constraints combine observed application minimums with managed rules")
    func effectiveConstraintsCombineObservedAndManaged() throws {
        let world = try twoColumnWorld(
            leftMinimumWidth: 400,
            observed: [left: WindowConstraints(minWidth: 500, minHeight: 300)]
        )

        #expect(effectiveWindowConstraints(in: world) == [left: WindowConstraints(minWidth: 500, minHeight: 300)])
    }

    private func config(leftMinimumWidth: Double) -> Config {
        Config(
            keymap: Config.default.keymap,
            rules: [],
            zones: Config.default.zones,
            gaps: Config.default.gaps,
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier,
            managedRules: [ManagedWindowRule(
                id: ManagedRuleID(rawValue: "wide-left"),
                name: "Wide left",
                matcher: ManagedRuleMatcher(bundleID: "com.example.left"),
                policy: ManagedRulePolicy(minimumWidth: leftMinimumWidth)
            )]
        )
    }

    private func twoColumnWorld(
        leftMinimumWidth: Double,
        observed: [WindowID: WindowConstraints] = [:]
    ) throws -> World {
        let tree = Node.split(try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1, node: .leaf(left)).get(),
            try Cell.create(weight: 1, node: .leaf(right)).get()
        ]).get())
        return World(
            displays: [
                displayID: DisplayInfo(
                    id: displayID,
                    slot: 0,
                    fingerprint: "main",
                    frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
                )
            ],
            activeSpace: spaceID,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: [])],
                    focused: left
                )
            ],
            windows: [
                left: window(left, bundleID: "com.example.left", x: 0),
                right: window(right, bundleID: "com.example.right", x: 600)
            ],
            windowDisplay: [left: displayID, right: displayID],
            windowSpace: [left: spaceID, right: spaceID],
            observedVisibleWindows: [WorkspaceKey(displayID: displayID, spaceID: spaceID): [left, right]],
            windowConstraints: observed,
            pendingRules: [:],
            config: config(leftMinimumWidth: leftMinimumWidth)
        )
    }

    private func window(_ id: WindowID, bundleID: String, x: CGFloat) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: bundleID),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: CGRect(x: x, y: 0, width: 600, height: 800),
            isResizable: true,
            isMinimized: false
        )
    }
}
