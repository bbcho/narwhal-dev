#if NARWHAL_ENABLE_VERIFIERS
import AppKit
import CoreGraphics
import Darwin
import NarwhalAppSupport
import NarwhalCore

@MainActor
enum SpaceFocusRecoveryVerification {
    static func verifyWorkspaceFocusFallbackMovesOnlyActiveSpace() -> (passed: Bool, message: String) {
        let displays = DisplayClient().currentDisplays()
        guard let display = displays.values.sorted(by: { $0.slot < $1.slot }).first else {
            return (false, "space focus recovery verification requires at least one display")
        }
        guard display.visibleFrame.width >= 720,
              display.visibleFrame.height >= 520
        else {
            return (false, "space focus recovery verification requires a usable display; visible=\(display.visibleFrame.debugDescription)")
        }

        let activeSpace = SpaceID(raw: 910_001)
        let inactiveSpace = SpaceID(raw: 910_003)
        let activeKey = WorkspaceKey(displayID: display.id, spaceID: activeSpace)
        let inactiveKey = WorkspaceKey(displayID: display.id, spaceID: inactiveSpace)
        let config = verificationConfig()

        let activeTile = makeWindow(
            title: "Narwhal verify active tile",
            axFrame: sampleFrame(in: display.visibleFrame, column: 0, row: 0),
            display: display,
            color: .systemBlue
        )
        let activeFloating = makeWindow(
            title: "Narwhal verify active focus fallback",
            axFrame: sampleFrame(in: display.visibleFrame, column: 1, row: 0),
            display: display,
            color: .systemGreen
        )
        let inactiveTile = makeWindow(
            title: "Narwhal verify inactive tile",
            axFrame: sampleFrame(in: display.visibleFrame, column: 0, row: 1),
            display: display,
            color: .systemOrange
        )
        let inactiveFloating = makeWindow(
            title: "Narwhal verify inactive focus history",
            axFrame: sampleFrame(in: display.visibleFrame, column: 1, row: 1),
            display: display,
            color: .systemRed
        )
        let liveWindows = [activeTile, activeFloating, inactiveTile, inactiveFloating]
        defer {
            liveWindows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        let world = verificationWorld(
            display: display,
            activeSpace: activeSpace,
            inactiveSpace: inactiveSpace,
            activeTile: activeTile,
            activeFloating: activeFloating,
            inactiveTile: inactiveTile,
            inactiveFloating: inactiveFloating,
            config: config
        )
        let runtime = WorldRuntimeState(
            undoWorld: nil,
            focusHistory: [inactiveFloating.id],
            workspaceFocus: [
                activeKey: activeFloating.id,
                inactiveKey: inactiveFloating.id
            ]
        )

        guard let fallback = runtimeFocusedWindowFallback(in: world, runtime: runtime),
              fallback.id == activeFloating.id
        else {
            return (
                false,
                "space focus recovery fallback selected \(runtimeFocusedWindowFallback(in: world, runtime: runtime)?.id.description ?? "nil"); expected \(activeFloating.id.description)"
            )
        }

        let beforeFrames = liveFrames(liveWindows)
        guard case .success(let pushedWorld) = apply(.push(fallback.id, .right), to: world) else {
            return (false, "space focus recovery push was rejected by the core")
        }
        let scope = commandPlanScope(
            focusedWindowID: fallback.id,
            oldWorld: world,
            newWorld: pushedWorld
        )
        guard scope == .workspace(activeKey) else {
            return (false, "space focus recovery planned wrong scope: \(scope)")
        }
        guard case .success(let plan) = commandPlan(
            from: world,
            to: pushedWorld,
            focusedWindowID: fallback.id,
            undoWorld: world,
            generation: LayoutGeneration(raw: 1),
            scope: scope
        ) else {
            return (false, "space focus recovery command plan was rejected")
        }

        let expectedMoved = Set([activeTile.id, activeFloating.id])
        let moved = Set(plan.desiredLayout.delta.moves.keys)
        guard moved == expectedMoved else {
            return (false, "space focus recovery moved wrong windows: expected \(ids(expectedMoved)) got \(ids(moved))")
        }

        guard applyLiveMoves(plan.desiredLayout.delta.moves, to: liveWindows, display: display) else {
            return (false, "space focus recovery failed to apply AppKit frames")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        guard movedWindowsMatchPlan(expectedMoved, moves: plan.desiredLayout.delta.moves, windows: liveWindows, display: display) else {
            return (
                false,
                "space focus recovery moved windows did not match planned frames: \(plannedFramesDescription(expectedMoved, moves: plan.desiredLayout.delta.moves, windows: liveWindows, display: display))"
            )
        }
        let inactiveIDs = Set([inactiveTile.id, inactiveFloating.id])
        guard inactiveIDs.allSatisfy({ id in beforeFrames[id].map { liveWindow(id, in: liveWindows)?.window.frame.matches($0, tolerance: 2) == true } ?? false }) else {
            return (
                false,
                "space focus recovery changed inactive-space windows: before=\(framesDescription(beforeFrames, ids: inactiveIDs)) after=\(framesDescription(liveFrames(liveWindows), ids: inactiveIDs))"
            )
        }

        return (
            true,
            "space focus recovery verified: workspace fallback=\(activeFloating.id.description) moved=\(ids(expectedMoved)) inactiveUnchanged=\(ids(inactiveIDs))"
        )
    }

    private static func verificationConfig() -> Config {
        Config(
            keymap: Config.default.keymap,
            rules: [],
            zones: Config.default.zones,
            gaps: Gaps(inner: 8, outer: Insets(top: 44, left: 44, bottom: 44, right: 44)),
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier
        )
    }

    private static func verificationWorld(
        display: DisplayInfo,
        activeSpace: SpaceID,
        inactiveSpace: SpaceID,
        activeTile: SpaceFocusVerificationWindow,
        activeFloating: SpaceFocusVerificationWindow,
        inactiveTile: SpaceFocusVerificationWindow,
        inactiveFloating: SpaceFocusVerificationWindow,
        config: Config
    ) -> World {
        let activeKey = WorkspaceKey(displayID: display.id, spaceID: activeSpace)
        let activeState = DisplaySpaceState(
            displayID: display.id,
            tree: .leaf(activeTile.id),
            floating: [activeFloating.id]
        )
        let inactiveState = DisplaySpaceState(
            displayID: display.id,
            tree: .leaf(inactiveTile.id),
            floating: [inactiveFloating.id]
        )
        let windows = [activeTile, activeFloating, inactiveTile, inactiveFloating]
        return World(
            displays: [display.id: display],
            activeSpace: activeSpace,
            activeSpaceByDisplay: [display.id: activeSpace],
            spaces: [
                activeSpace: SpaceState(id: activeSpace, displays: [display.id: activeState], focused: nil),
                inactiveSpace: SpaceState(id: inactiveSpace, displays: [display.id: inactiveState], focused: inactiveFloating.id)
            ],
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.metadata) }),
            windowDisplay: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, display.id) }),
            windowSpace: [
                activeTile.id: activeSpace,
                activeFloating.id: activeSpace,
                inactiveTile.id: inactiveSpace,
                inactiveFloating.id: inactiveSpace
            ],
            observedVisibleWindows: [
                activeKey: [activeTile.id, activeFloating.id]
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }

    private static func makeWindow(
        title: String,
        axFrame: CGRect,
        display: DisplayInfo,
        color: NSColor
    ) -> SpaceFocusVerificationWindow {
        let appKitFrame = appKitFrame(forAXFrame: axFrame, display: display)
        let window = NSWindow(
            contentRect: appKitFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.ignoresCycle]
        window.setFrame(appKitFrame, display: false)
        window.orderFrontRegardless()

        let id = WindowID(raw: CGWindowID(window.windowNumber))
        return SpaceFocusVerificationWindow(
            id: id,
            window: window,
            metadata: WindowMetadata(
                id: id,
                bundleID: BundleID(raw: "dev.narwhal.space-focus-verifier"),
                title: title,
                role: "AXWindow",
                pid: getpid(),
                frame: axFrame,
                isResizable: true,
                isMinimized: false
            )
        )
    }

    private static func sampleFrame(in visibleFrame: CGRect, column: Int, row: Int) -> CGRect {
        let width = min(max(visibleFrame.width * 0.22, 220), max(220, visibleFrame.width - 120))
        let height = min(max(visibleFrame.height * 0.20, 160), max(160, visibleFrame.height - 120))
        let horizontalStep = min(width + 36, max(0, visibleFrame.width - width - 72))
        let verticalStep = min(height + 36, max(0, visibleFrame.height - height - 72))
        return CGRect(
            x: visibleFrame.minX + 36 + CGFloat(column) * horizontalStep,
            y: visibleFrame.minY + 36 + CGFloat(row) * verticalStep,
            width: width,
            height: height
        )
    }

    private static func applyLiveMoves(
        _ moves: [WindowID: CGRect],
        to windows: [SpaceFocusVerificationWindow],
        display: DisplayInfo
    ) -> Bool {
        moves.allSatisfy { windowID, axFrame in
            guard let live = liveWindow(windowID, in: windows) else { return false }
            live.window.setFrame(appKitFrame(forAXFrame: axFrame, display: display), display: true)
            return true
        }
    }

    private static func movedWindowsMatchPlan(
        _ windowIDs: Set<WindowID>,
        moves: [WindowID: CGRect],
        windows: [SpaceFocusVerificationWindow],
        display: DisplayInfo
    ) -> Bool {
        windowIDs.allSatisfy { windowID in
            guard let axFrame = moves[windowID],
                  let live = liveWindow(windowID, in: windows)
            else { return false }
            return live.window.frame.matches(appKitFrame(forAXFrame: axFrame, display: display), tolerance: 2)
        }
    }

    private static func plannedFramesDescription(
        _ windowIDs: Set<WindowID>,
        moves: [WindowID: CGRect],
        windows: [SpaceFocusVerificationWindow],
        display: DisplayInfo
    ) -> String {
        windowIDs.sorted { $0.raw < $1.raw }
            .map { windowID in
                guard let axFrame = moves[windowID],
                      let live = liveWindow(windowID, in: windows)
                else { return "\(windowID.description)=missing" }
                let expected = appKitFrame(forAXFrame: axFrame, display: display)
                return "\(windowID.description) expected=\(expected.debugDescription) actual=\(live.window.frame.debugDescription)"
            }
            .joined(separator: "; ")
    }

    private static func appKitFrame(forAXFrame frame: CGRect, display: DisplayInfo) -> CGRect {
        let screenFrame = screenFrame(for: display.id) ?? display.frame
        return CGRect(
            x: screenFrame.minX + (frame.minX - display.frame.minX),
            y: screenFrame.minY + (display.frame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    private static func screenFrame(for displayID: DisplayID) -> CGRect? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID.raw
        }?.frame
    }

    private static func liveWindow(_ id: WindowID, in windows: [SpaceFocusVerificationWindow]) -> SpaceFocusVerificationWindow? {
        windows.first { $0.id == id }
    }

    private static func liveFrames(_ windows: [SpaceFocusVerificationWindow]) -> [WindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.window.frame) })
    }

    private static func framesDescription(_ frames: [WindowID: CGRect], ids: Set<WindowID>) -> String {
        ids.sorted { $0.raw < $1.raw }
            .map { "\($0.description)=\(frames[$0]?.debugDescription ?? "nil")" }
            .joined(separator: ",")
    }

    private static func ids(_ ids: Set<WindowID>) -> String {
        ids.sorted { $0.raw < $1.raw }.map(\.description).joined(separator: ",")
    }
}

@MainActor
private struct SpaceFocusVerificationWindow {
    let id: WindowID
    let window: NSWindow
    let metadata: WindowMetadata
}

private extension CGRect {
    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
#endif
