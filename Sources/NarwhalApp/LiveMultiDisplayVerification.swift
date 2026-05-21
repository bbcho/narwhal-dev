#if NARWHAL_ENABLE_VERIFIERS
import AppKit
import CoreGraphics
import Darwin
import NarwhalAppSupport
import NarwhalCore

@MainActor
enum LiveMultiDisplayVerification {
    static func verifyDisplayScopedPushAndCycle() -> (passed: Bool, message: String) {
        let displayClient = DisplayClient()
        let displays = displayClient.currentDisplays()
        let orderedDisplays = displays.values.sorted {
            if $0.slot == $1.slot { return $0.id.raw < $1.id.raw }
            return $0.slot < $1.slot
        }
        guard orderedDisplays.count >= 2 else {
            return (false, "live multi-display verification requires at least two displays; found \(orderedDisplays.count)")
        }

        let sourceDisplay = orderedDisplays[0]
        let otherDisplay = orderedDisplays[1]
        guard sourceDisplay.visibleFrame.width >= 480,
              sourceDisplay.visibleFrame.height >= 320,
              otherDisplay.visibleFrame.width >= 480,
              otherDisplay.visibleFrame.height >= 320
        else {
            return (
                false,
                "live multi-display verification requires two usable displays; source=\(sourceDisplay.visibleFrame.debugDescription) other=\(otherDisplay.visibleFrame.debugDescription)"
            )
        }

        let topology = SpaceClient().spaceTopology(displays: displays, windows: [])
        let sourceSpace = topology.activeSpaceByDisplay[sourceDisplay.id] ?? SpaceID(raw: 900_001)
        let otherSpace = topology.activeSpaceByDisplay[otherDisplay.id] ?? SpaceID(raw: 900_002)
        let sourceKey = WorkspaceKey(displayID: sourceDisplay.id, spaceID: sourceSpace)
        let otherKey = WorkspaceKey(displayID: otherDisplay.id, spaceID: otherSpace)
        let config = verificationConfig()

        let sourceTile = makeWindow(
            title: "Narwhal live verify source tile",
            axFrame: sampleFrame(in: sourceDisplay.visibleFrame, column: 0, row: 0),
            display: sourceDisplay,
            color: .systemBlue
        )
        let sourceFloating = makeWindow(
            title: "Narwhal live verify source floating",
            axFrame: sampleFrame(in: sourceDisplay.visibleFrame, column: 1, row: 0),
            display: sourceDisplay,
            color: .systemGreen
        )
        let sourceCycle = makeWindow(
            title: "Narwhal live verify source cycle",
            axFrame: sampleFrame(in: sourceDisplay.visibleFrame, column: 0, row: 1),
            display: sourceDisplay,
            color: .systemPurple
        )
        let otherTile = makeWindow(
            title: "Narwhal live verify other tile",
            axFrame: sampleFrame(in: otherDisplay.visibleFrame, column: 0, row: 0),
            display: otherDisplay,
            color: .systemOrange
        )
        let otherFloating = makeWindow(
            title: "Narwhal live verify other floating",
            axFrame: sampleFrame(in: otherDisplay.visibleFrame, column: 1, row: 0),
            display: otherDisplay,
            color: .systemRed
        )
        let liveWindows = [sourceTile, sourceFloating, sourceCycle, otherTile, otherFloating]
        defer {
            liveWindows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        let missingWindowNumbers = liveWindows
            .map(\.window.windowNumber)
            .filter { !frontToBackWindowNumbers().contains($0) }
        guard missingWindowNumbers.isEmpty else {
            return (false, "live multi-display verification windows were not visible in the window server: \(missingWindowNumbers)")
        }

        var world = verificationWorld(
            sourceKey: sourceKey,
            otherKey: otherKey,
            sourceDisplay: sourceDisplay,
            otherDisplay: otherDisplay,
            sourceTile: sourceTile,
            sourceFloating: sourceFloating,
            sourceCycle: sourceCycle,
            otherTile: otherTile,
            otherFloating: otherFloating,
            activeSpaceByDisplay: topology.activeSpaceByDisplay,
            config: config
        )

        guard case .success(let oldSourceLayout) = workspaceLayout(for: sourceKey, in: world),
              let sourceTileStart = oldSourceLayout.tiled[sourceTile.id],
              case .success(let oldOtherLayout) = workspaceLayout(for: otherKey, in: world),
              let otherTileStart = oldOtherLayout.tiled[otherTile.id]
        else {
            return (false, "live multi-display verification could not solve initial workspace layouts")
        }

        setAXFrame(sourceTile.window, to: sourceTileStart, display: sourceDisplay)
        setAXFrame(otherTile.window, to: otherTileStart, display: otherDisplay)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        world = worldByUpdatingFrames(
            [
                sourceTile.id: sourceTileStart,
                otherTile.id: otherTileStart
            ],
            in: world
        )
        let beforeFrames = liveFrames(liveWindows)

        switch focusCycleCandidatePlans(in: world, from: sourceFloating.id, direction: .next) {
        case .success(let candidates):
            let candidateIDs = Set(candidates.map(\.window.id))
            let expected = Set([sourceFloating.id, sourceCycle.id])
            guard candidateIDs == expected else {
                return (
                    false,
                    "live multi-display cycle scope failed: expected \(ids(expected)) got \(ids(candidateIDs))"
                )
            }
        case .failure(let error):
            return (false, "live multi-display cycle planning failed: \(error.message)")
        }

        guard case .success(let pushedWorld) = apply(.push(sourceFloating.id, .right), to: world) else {
            return (false, "live multi-display push was rejected by the core")
        }
        let scope = commandPlanScope(
            focusedWindowID: sourceFloating.id,
            oldWorld: world,
            newWorld: pushedWorld
        )
        guard scope == .workspace(sourceKey) else {
            return (false, "live multi-display push planned wrong scope: \(scope)")
        }
        guard case .success(let plan) = commandPlan(
            from: world,
            to: pushedWorld,
            focusedWindowID: sourceFloating.id,
            undoWorld: world,
            generation: LayoutGeneration(raw: 1),
            scope: scope
        ) else {
            return (false, "live multi-display push command plan was rejected")
        }

        let plannedMoveIDs = Set(plan.desiredLayout.delta.moves.keys)
        let expectedMoveIDs = Set([sourceTile.id, sourceFloating.id])
        guard plannedMoveIDs == expectedMoveIDs else {
            return (
                false,
                "live multi-display push touched wrong windows: expected \(ids(expectedMoveIDs)) got \(ids(plannedMoveIDs))"
            )
        }

        guard applyLiveMoves(plan.desiredLayout.delta.moves, to: liveWindows, displays: displays) else {
            return (false, "live multi-display push failed to apply planned AppKit frames")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        guard movedWindowsMatchPlan(expectedMoveIDs, moves: plan.desiredLayout.delta.moves, windows: liveWindows, displays: displays) else {
            return (
                false,
                "live multi-display pushed windows did not match planned frames: \(plannedFramesDescription(expectedMoveIDs, moves: plan.desiredLayout.delta.moves, windows: liveWindows, displays: displays))"
            )
        }
        let unchangedOtherIDs = Set([otherTile.id, otherFloating.id])
        guard unchangedOtherIDs.allSatisfy({ id in beforeFrames[id].map { liveWindow(id, in: liveWindows)?.window.frame.matches($0, tolerance: 2) == true } ?? false }) else {
            return (
                false,
                "live multi-display push changed the other display: before=\(framesDescription(beforeFrames, ids: unchangedOtherIDs)) after=\(framesDescription(liveFrames(liveWindows), ids: unchangedOtherIDs))"
            )
        }

        let overlay = Overlay(border: config.border, hud: config.hud)
        defer {
            overlay.stop()
        }
        let sourceTargets = plan.desiredLayout.layout.tiled.compactMap { windowID, frame -> FocusBorderTarget? in
            guard expectedMoveIDs.contains(windowID), let window = plan.windows[windowID] else { return nil }
            return FocusBorderTarget(window: window, frame: frame)
        }
        overlay.render(OverlayModel.empty.settingTiledBorders(sourceTargets))
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard Set(overlay.debugTiledBorderWindowIDs()) == expectedMoveIDs,
              overlay.debugVisibleTiledBorderCount() == expectedMoveIDs.count
        else {
            return (
                false,
                "live multi-display overlay showed wrong tiled borders: expected \(ids(expectedMoveIDs)) got \(ids(Set(overlay.debugTiledBorderWindowIDs())))"
            )
        }

        return (
            true,
            [
                "live multi-display verified:",
                "displays=\(sourceDisplay.id.raw),\(otherDisplay.id.raw)",
                "spaces=\(sourceSpace.raw),\(otherSpace.raw)",
                "pushMoved=\(ids(expectedMoveIDs))",
                "cycleCandidates=\(ids(Set([sourceFloating.id, sourceCycle.id])))",
                "otherDisplayUnchanged=\(ids(unchangedOtherIDs))"
            ].joined(separator: " ")
        )
    }

    private static func verificationConfig() -> Config {
        Config(
            keymap: Config.default.keymap,
            rules: [],
            zones: Config.default.zones,
            gaps: Gaps(
                inner: 8,
                outer: Insets(top: 44, left: 44, bottom: 44, right: 44)
            ),
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier
        )
    }

    private static func verificationWorld(
        sourceKey: WorkspaceKey,
        otherKey: WorkspaceKey,
        sourceDisplay: DisplayInfo,
        otherDisplay: DisplayInfo,
        sourceTile: LiveVerificationWindow,
        sourceFloating: LiveVerificationWindow,
        sourceCycle: LiveVerificationWindow,
        otherTile: LiveVerificationWindow,
        otherFloating: LiveVerificationWindow,
        activeSpaceByDisplay liveActiveSpaces: [DisplayID: SpaceID],
        config: Config
    ) -> World {
        let displays = [
            sourceDisplay.id: sourceDisplay,
            otherDisplay.id: otherDisplay
        ]
        let windows = [
            sourceTile,
            sourceFloating,
            sourceCycle,
            otherTile,
            otherFloating
        ]
        let sourceState = DisplaySpaceState(
            displayID: sourceDisplay.id,
            tree: .leaf(sourceTile.id),
            floating: [sourceFloating.id, sourceCycle.id]
        )
        let otherState = DisplaySpaceState(
            displayID: otherDisplay.id,
            tree: .leaf(otherTile.id),
            floating: [otherFloating.id]
        )
        let spaces = mergedSpaces(
            sourceKey: sourceKey,
            sourceState: sourceState,
            otherKey: otherKey,
            otherState: otherState,
            focused: sourceFloating.id
        )
        let activeSpaceByDisplay = [
            sourceDisplay.id: liveActiveSpaces[sourceDisplay.id] ?? sourceKey.spaceID,
            otherDisplay.id: liveActiveSpaces[otherDisplay.id] ?? otherKey.spaceID
        ]
        let sourceVisible = Set([sourceTile.id, sourceFloating.id, sourceCycle.id])
        let otherVisible = Set([otherTile.id, otherFloating.id])

        return World(
            displays: displays,
            activeSpace: sourceKey.spaceID,
            activeSpaceByDisplay: activeSpaceByDisplay,
            spaces: spaces,
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.metadata) }),
            windowDisplay: [
                sourceTile.id: sourceDisplay.id,
                sourceFloating.id: sourceDisplay.id,
                sourceCycle.id: sourceDisplay.id,
                otherTile.id: otherDisplay.id,
                otherFloating.id: otherDisplay.id
            ],
            windowSpace: [
                sourceTile.id: sourceKey.spaceID,
                sourceFloating.id: sourceKey.spaceID,
                sourceCycle.id: sourceKey.spaceID,
                otherTile.id: otherKey.spaceID,
                otherFloating.id: otherKey.spaceID
            ],
            observedVisibleWindows: [
                sourceKey: sourceVisible,
                otherKey: otherVisible
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }

    private static func mergedSpaces(
        sourceKey: WorkspaceKey,
        sourceState: DisplaySpaceState,
        otherKey: WorkspaceKey,
        otherState: DisplaySpaceState,
        focused: WindowID
    ) -> [SpaceID: SpaceState] {
        let sourceDisplays = [sourceKey.displayID: sourceState]
        let otherDisplays = [otherKey.displayID: otherState]
        if sourceKey.spaceID == otherKey.spaceID {
            return [
                sourceKey.spaceID: SpaceState(
                    id: sourceKey.spaceID,
                    displays: sourceDisplays.merging(otherDisplays) { _, other in other },
                    focused: focused
                )
            ]
        }
        return [
            sourceKey.spaceID: SpaceState(id: sourceKey.spaceID, displays: sourceDisplays, focused: focused),
            otherKey.spaceID: SpaceState(id: otherKey.spaceID, displays: otherDisplays, focused: nil)
        ]
    }

    private static func worldByUpdatingFrames(_ frames: [WindowID: CGRect], in world: World) -> World {
        World(
            displays: world.displays,
            activeSpace: world.activeSpace,
            activeSpaceByDisplay: world.activeSpaceByDisplay,
            spaces: world.spaces,
            windows: world.windows.mapValues { metadata in
                guard let frame = frames[metadata.id] else { return metadata }
                return WindowMetadata(
                    id: metadata.id,
                    bundleID: metadata.bundleID,
                    title: metadata.title,
                    role: metadata.role,
                    pid: metadata.pid,
                    frame: frame,
                    isResizable: metadata.isResizable,
                    isMinimized: metadata.isMinimized
                )
            },
            windowDisplay: world.windowDisplay,
            windowSpace: world.windowSpace,
            observedVisibleWindows: world.observedVisibleWindows,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
    }

    private static func makeWindow(
        title: String,
        axFrame: CGRect,
        display: DisplayInfo,
        color: NSColor
    ) -> LiveVerificationWindow {
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
        return LiveVerificationWindow(
            id: id,
            window: window,
            metadata: WindowMetadata(
                id: id,
                bundleID: BundleID(raw: "dev.narwhal.live-multi-display-verifier"),
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
        let width = min(max(visibleFrame.width * 0.26, 220), max(220, visibleFrame.width - 120))
        let height = min(max(visibleFrame.height * 0.24, 160), max(160, visibleFrame.height - 120))
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
        to windows: [LiveVerificationWindow],
        displays: [DisplayID: DisplayInfo]
    ) -> Bool {
        moves.allSatisfy { windowID, axFrame in
            guard let live = liveWindow(windowID, in: windows),
                  let display = displayContaining(axFrame, displays: displays)
            else { return false }
            setAXFrame(live.window, to: axFrame, display: display)
            return true
        }
    }

    private static func movedWindowsMatchPlan(
        _ windowIDs: Set<WindowID>,
        moves: [WindowID: CGRect],
        windows: [LiveVerificationWindow],
        displays: [DisplayID: DisplayInfo]
    ) -> Bool {
        windowIDs.allSatisfy { windowID in
            guard let axFrame = moves[windowID],
                  let live = liveWindow(windowID, in: windows),
                  let display = displayContaining(axFrame, displays: displays)
            else { return false }
            return live.window.frame.matches(appKitFrame(forAXFrame: axFrame, display: display), tolerance: 2)
        }
    }

    private static func plannedFramesDescription(
        _ windowIDs: Set<WindowID>,
        moves: [WindowID: CGRect],
        windows: [LiveVerificationWindow],
        displays: [DisplayID: DisplayInfo]
    ) -> String {
        windowIDs.sorted { $0.raw < $1.raw }
            .map { windowID in
                guard let axFrame = moves[windowID],
                      let live = liveWindow(windowID, in: windows),
                      let display = displayContaining(axFrame, displays: displays)
                else { return "\(windowID.description)=missing" }
                let expected = appKitFrame(forAXFrame: axFrame, display: display)
                return "\(windowID.description) expected=\(expected.debugDescription) actual=\(live.window.frame.debugDescription)"
            }
            .joined(separator: "; ")
    }

    private static func setAXFrame(_ window: NSWindow, to axFrame: CGRect, display: DisplayInfo) {
        window.setFrame(appKitFrame(forAXFrame: axFrame, display: display), display: true)
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

    private static func displayContaining(_ frame: CGRect, displays: [DisplayID: DisplayInfo]) -> DisplayInfo? {
        if let byIntersection = displays.values.max(by: {
            $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area
        }), byIntersection.visibleFrame.intersection(frame).area > 0 {
            return byIntersection
        }
        return nil
    }

    private static func liveWindow(_ id: WindowID, in windows: [LiveVerificationWindow]) -> LiveVerificationWindow? {
        windows.first { $0.id == id }
    }

    private static func liveFrames(_ windows: [LiveVerificationWindow]) -> [WindowID: CGRect] {
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

    private static func frontToBackWindowNumbers() -> Set<Int> {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return [] }

        return Set(windows.compactMap { window in
            if let number = window[kCGWindowNumber as String] as? CGWindowID {
                return Int(number)
            }
            if let number = window[kCGWindowNumber as String] as? Int {
                return number
            }
            return nil
        })
    }
}

@MainActor
private struct LiveVerificationWindow {
    let id: WindowID
    let window: NSWindow
    let metadata: WindowMetadata
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
#endif
