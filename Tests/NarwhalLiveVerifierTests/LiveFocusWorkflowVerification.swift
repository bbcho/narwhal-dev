#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Darwin
import NarwhalAppSupport
import NarwhalCore

/// A do-nothing NSApplicationDelegate whose sole purpose is to return false from
/// `applicationShouldTerminateAfterLastWindowClosed`. The live verifier creates
/// and tears down its own NSWindows; without this guard, AppKit terminates the
/// test process when our `defer { orderOut }` closes the last window, which
/// silently aborts the rest of the test suite.
@MainActor
final class VerifierAppDelegate: NSObject, NSApplicationDelegate {
    private static var installed: VerifierAppDelegate?

    static func installIfNeeded() {
        if installed == nil {
            // macOS may auto-terminate the testing helper when it goes idle
            // between tests; disable both vectors.
            ProcessInfo.processInfo.disableAutomaticTermination("NarwhalLiveVerifier")
            ProcessInfo.processInfo.disableSuddenTermination()
            let delegate = VerifierAppDelegate()
            NSApp.delegate = delegate
            installed = delegate
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateCancel
    }
}

@MainActor
enum LiveFocusWorkflowVerification {
    static func verifyCycleMouseAndBorderWorkflow() -> (passed: Bool, message: String) {
        if isSystemLocked() {
            return (false, "live focus workflow verification requires an unlocked user session")
        }
        do {
            let displays = DisplayClient().currentDisplays()
            let orderedDisplays = displays.values.sorted {
                if $0.slot == $1.slot { return $0.id.raw < $1.id.raw }
                return $0.slot < $1.slot
            }
            guard let display = orderedDisplays.first else {
                return (false, "live focus workflow verification requires at least one display")
            }
            guard display.visibleFrame.width >= 720,
                  display.visibleFrame.height >= 500
            else {
                return (
                    false,
                    "live focus workflow verification requires a usable display; primary=\(display.visibleFrame.debugDescription)"
                )
            }

            activateVerifierApplication()

            let axClient = AXClient(processID: -1)
            let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
            let windows = makeWindows(display: display)
            var observer: AXObserverService?
            var overlayModel = OverlayModel.empty
            var observedFocuses: [WindowID] = []

            defer {
                observer?.stop()
                overlay.stop()
                // Alpha-hide rather than orderOut: orderOut'ing the last visible
                // NSWindow at the end of a test has triggered process exit in
                // this harness despite .accessory policy and a custom delegate
                // returning .terminateCancel.
                windows.all.forEach { $0.window.alphaValue = 0 }
            }

            let activeSpace = activeSpace(for: display)
            var world = workflowWorld(
                windows: windows.all,
                display: display,
                activeSpace: activeSpace
            )
            world = try tileWindow(
                windows.tiled,
                in: world,
                display: display,
                liveWindows: windows.all
            )
            let tiledBorderID = windows.tiled.id

            let tiledTargets = try currentTiledTargets(in: world, context: "initial tiled border")
            overlayModel = overlayModel.settingTiledBorders(tiledTargets)
            overlay.render(overlayModel)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            try requireTiledBorderVisible(
                overlay: overlay,
                targetID: tiledBorderID,
                liveWindow: windows.tiled,
                display: display,
                context: "initial tiled border"
            )

            try focusVerifierWindow(windows.floatA, using: axClient, context: "focus-cycle source")
            world = worldBySettingFocus(windows.floatA.id, in: world)
            let cycleTarget = try focusCycleTarget(in: world, from: windows.floatA.id)
            guard cycleTarget.window.id == windows.floatB.id else {
                throw LiveFocusWorkflowFailure(
                    "focus-cycle target expected \(windows.floatB.id.description) got \(cycleTarget.window.id.description)"
                )
            }

            windows.floatA.window.orderFrontRegardless()
            windows.floatB.window.orderBack(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            try requireLiveWindowNotFront(windows.floatB, liveWindows: windows.all, context: "focus-cycle precondition")
            try focusViaAX(windows.floatB, using: axClient, context: "focus-cycle target")
            try requireFrontLiveWindow(windows.floatB, liveWindows: windows.all, context: "focus-cycle target")

            let floatBFocus = FocusBorderTarget(window: cycleTarget.window, frame: cycleTarget.frame)
            overlayModel = overlayModel.showingFocusBorder(floatBFocus)
            overlay.render(overlayModel)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            try requireFocusBorderVisible(
                overlay: overlay,
                target: floatBFocus,
                liveWindow: windows.floatB,
                display: display,
                context: "focus-cycle target border"
            )

            windows.tiled.window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            try focusVerifierWindow(windows.tiled, using: axClient, context: "mouse workflow tiled source")
            let tiledFocusTarget = try focusTarget(for: tiledBorderID, in: world)
            overlayModel = overlayModel.showingFocusBorder(tiledFocusTarget)
            overlay.render(overlayModel)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            try requireFocusBorderVisible(
                overlay: overlay,
                target: tiledFocusTarget,
                liveWindow: windows.tiled,
                display: display,
                context: "mouse workflow tiled source border"
            )

            observer = AXObserverService(
                axClient: axClient,
                echoSuppressor: AXEchoSuppressor(),
                reporter: StartupReporter(logPath: "/tmp/narwhal-live-focus-workflow.log"),
                activeSpaceByDisplay: { _ in [display.id: activeSpace] },
                spaceChanged: {},
                emit: { event, snapshot in
                    guard case .windowFocused(let windowID) = event else { return }
                    if let snapshot,
                       let liveWindow = windows.all.first(where: { $0.metadata.title == snapshot.title }) {
                        liveWindow.updateIdentity(from: snapshot)
                    }
                    observedFocuses.append(windowID)
                    if let snapshot {
                        overlayModel = overlayModel.showingFocusBorder(snapshot.focusBorderTarget)
                        overlay.render(overlayModel)
                    }
                }
            )
            observer?.start()

            try raiseClickTarget(
                windows.floatA,
                overFocused: windows.tiled,
                focusedBorderID: tiledBorderID,
                overlay: overlay,
                using: axClient,
                context: "mouse workflow floating target precondition"
            )
            try clickWindowUntilFocused(windows.floatA, using: axClient)
            try waitFor(
                timeout: 2.0,
                description: "mouse focus observer did not move focus border to \(windows.floatA.id.description)"
            ) {
                observer?.pollFocusedWindowNow()
                return observedFocuses.last == windows.floatA.id
                    && overlay.debugFocusBorderWindowID() == windows.floatA.id
                    && overlay.debugFocusBorderIsVisible()
            }
            let mouseSnapshot = try focusedSnapshot(
                using: axClient,
                expected: windows.floatA,
                context: "after mouse click"
            )
            try requireFocusBorderVisible(
                overlay: overlay,
                target: mouseSnapshot.focusBorderTarget,
                liveWindow: windows.floatA,
                display: display,
                context: "mouse-focused floating border"
            )
            try requireFloatingWindowCoversTiledBorder(
                overlay: overlay,
                floating: windows.floatA,
                tiledID: tiledBorderID,
                display: display,
                context: "mouse-focused floating over tiled border"
            )

            // Regression: with focus on a *different* floating window (not the one over
            // the tile), the unfocused floating window must still cover the tile border.
            // See Overlay.orderTiledBorderWindow.
            windows.floatA.window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            windows.floatB.window.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try focusVerifierWindow(
                windows.floatB,
                using: axClient,
                context: "regression: focus floatB so floatA is unfocused over tile"
            )
            try waitFor(
                timeout: 2.0,
                description: "regression focus observer did not move focus border to \(windows.floatB.id.description)"
            ) {
                observer?.pollFocusedWindowNow()
                return observedFocuses.last == windows.floatB.id
                    && overlay.debugFocusBorderWindowID() == windows.floatB.id
            }
            try requireFloatingWindowCoversTiledBorder(
                overlay: overlay,
                floating: windows.floatA,
                tiledID: tiledBorderID,
                display: display,
                context: "regression: unfocused floating must stay above tile border"
            )

            return (
                true,
                [
                    "live focus workflow verified:",
                    "tiled=\(tiledBorderID.description)",
                    "cycle=\(windows.floatA.id.description)->\(windows.floatB.id.description)",
                    "mouseFocus=\(windows.floatA.id.description)",
                    "focusBorderVisible=true",
                    "tiledBorderBelowFloating=true",
                    "unfocusedFloatStaysAboveBorder=true"
                ].joined(separator: " ")
            )
        } catch let error as LiveFocusWorkflowFailure {
            return (false, error.message)
        } catch {
            return (false, "live focus workflow verification failed: \(String(describing: error))")
        }
    }

    private static func tileWindow(
        _ window: LiveFocusWindow,
        in world: World,
        display: DisplayInfo,
        liveWindows: [LiveFocusWindow]
    ) throws -> World {
        let nextWorld: World
        switch apply(.push(window.id, .left), to: world) {
        case .success(let value):
            nextWorld = value
        case .failure(let error):
            throw LiveFocusWorkflowFailure("tile source push rejected by core: \(error.message)")
        }

        let scope = commandPlanScope(
            focusedWindowID: window.id,
            oldWorld: world,
            newWorld: nextWorld
        )
        let plan: CommandPlanResult
        switch commandPlan(
            from: world,
            to: nextWorld,
            focusedWindowID: window.id,
            undoWorld: world,
            generation: LayoutGeneration(raw: 1),
            scope: scope
        ) {
        case .success(let value):
            plan = value
        case .failure(let error):
            throw LiveFocusWorkflowFailure("tile source plan rejected: \(error.message)")
        }

        try applyLiveMoves(plan.desiredLayout.delta.moves, to: liveWindows, display: display, context: "tile source")
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try requireMovedWindowsMatchPlan(
            plan.desiredLayout.delta.moves,
            windows: liveWindows,
            display: display,
            context: "tile source"
        )
        return worldByRecordingWindowFrames(plan.desiredLayout.delta.moves, in: plan.plannedWorld)
    }

    private static func currentTiledTargets(in world: World, context: String) throws -> [FocusBorderTarget] {
        switch tiledBorderTargets(of: world) {
        case .success(let targets):
            guard !targets.isEmpty else {
                throw LiveFocusWorkflowFailure("\(context) produced no tiled border targets")
            }
            return targets
        case .failure(let error):
            throw LiveFocusWorkflowFailure("\(context) failed solving tiled border targets: \(error)")
        }
    }

    private static func focusCycleTarget(in world: World, from focused: WindowID) throws -> FocusPlanResult {
        switch focusCycleCandidatePlans(in: world, from: focused, direction: .next) {
        case .success(let candidates):
            guard let first = candidates.first else {
                throw LiveFocusWorkflowFailure("focus-cycle produced no candidates")
            }
            return first
        case .failure(let error):
            throw LiveFocusWorkflowFailure("focus-cycle rejected by core: \(error.message)")
        }
    }

    private static func focusTarget(for windowID: WindowID, in world: World) throws -> FocusBorderTarget {
        switch focusPlan(in: world, windowID: windowID) {
        case .success(let plan):
            return FocusBorderTarget(window: plan.window, frame: plan.frame)
        case .failure(let error):
            throw LiveFocusWorkflowFailure("focus plan rejected for \(windowID.description): \(error.message)")
        }
    }

    private static func focusViaAX(
        _ window: LiveFocusWindow,
        using axClient: AXClient,
        context: String
    ) throws {
        switch awaitLiveVerifierOperation({ await axClient.focusWindow(window.metadata) }) {
        case .success:
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        case .failure(let error):
            throw LiveFocusWorkflowFailure("\(context) failed focusing \(window.id.description): \(error.description)")
        }
    }

    private static func activateVerifierApplication() {
        NSApp.setActivationPolicy(.accessory)
        // Install (once) a delegate that explicitly forbids auto-terminating on
        // last-window-closed. Without this, the test process exits cleanly
        // (exit 0, no crash) after our defer orderOuts the last window, which
        // swallows the test result line AND aborts the remaining tests in the
        // suite. .accessory alone is not sufficient on macOS 15+.
        VerifierAppDelegate.installIfNeeded()
        NSApp.finishLaunching()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    }

    private static func raiseClickTarget(
        _ target: LiveFocusWindow,
        overFocused focused: LiveFocusWindow,
        focusedBorderID: WindowID,
        overlay: Overlay,
        using axClient: AXClient,
        context: String
    ) throws {
        activateVerifierApplication()
        try focusVerifierWindow(focused, using: axClient, context: "\(context) focused source")

        target.window.order(.above, relativeTo: focused.windowNumber)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))

        let ignoredOverlayWindows = Set([
            overlay.debugFocusBorderWindowNumber(),
            overlay.debugTiledBorderWindowNumber(for: focusedBorderID)
        ].compactMap { $0 })
        let candidates = clickPoints(for: target)
        guard candidates.contains(where: {
            topmostWindowNumber(at: $0, ignoring: ignoredOverlayWindows) == target.windowNumber
        }) else {
            let observed = candidates
                .map { point in
                    "\(point.debugDescription)->\(String(describing: topmostWindowNumber(at: point, ignoring: ignoredOverlayWindows)))"
                }
                .joined(separator: ", ")
            throw LiveFocusWorkflowFailure(
                "\(context) could not make \(target.id.description) the top click target: \(observed)"
            )
        }
        _ = try focusedSnapshot(using: axClient, expected: focused, context: "\(context) focused source")
    }

    private static func focusVerifierWindow(
        _ window: LiveFocusWindow,
        using axClient: AXClient,
        context: String
    ) throws {
        activateVerifierApplication()
        window.window.makeKeyAndOrderFront(nil)
        window.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.18))
        if (try? focusedSnapshot(using: axClient, expected: window, context: context)) != nil {
            return
        }

        switch awaitLiveVerifierOperation({ await axClient.focusWindow(window.metadata) }) {
        case .success:
            break
        case .failure(let error):
            throw LiveFocusWorkflowFailure(
                "\(context) could not focus verifier window \(window.id.description): \(error.description)"
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.18))
        _ = try focusedSnapshot(using: axClient, expected: window, context: context)
    }

    private static func focusedSnapshot(
        using axClient: AXClient,
        expected window: LiveFocusWindow,
        context: String
    ) throws -> FocusedWindowSnapshot {
        var lastFailure = "no focused snapshot"
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            switch axClient.focusedWindowSnapshot() {
            case .success(let snapshot) where snapshot.id == window.id || snapshot.title == window.metadata.title:
                window.updateIdentity(from: snapshot)
                return snapshot
            case .success(let snapshot):
                lastFailure = "focused \(snapshot.id.description) title=\"\(snapshot.title)\""
            case .failure(let error):
                lastFailure = error.description
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        throw LiveFocusWorkflowFailure(
            "\(context) expected focused \(window.id.description) but saw \(lastFailure)"
        )
    }

    private static func clickWindowUntilFocused(
        _ window: LiveFocusWindow,
        using axClient: AXClient
    ) throws {
        var lastFailure = "click did not update focus"
        for point in clickPoints(for: window) {
            try postClick(at: point)
            if waitForFocus(window, using: axClient, timeout: 0.5, lastFailure: &lastFailure, context: "click at \(point.debugDescription)") {
                return
            }
        }
        postAppKitClick(to: window)
        if waitForFocus(window, using: axClient, timeout: 0.5, lastFailure: &lastFailure, context: "AppKit click") {
            return
        }
        throw LiveFocusWorkflowFailure(
            "mouse click did not focus \(window.id.description): \(lastFailure)"
        )
    }

    private static func clickPoints(for window: LiveFocusWindow) -> [CGPoint] {
        [
            windowServerFrame(for: window.windowNumber),
            windowServerFrame(for: Int(window.metadata.id.raw)),
            windowServerFrame(for: window.window.windowNumber),
            Optional(window.metadata.frame)
        ]
        .compactMap { $0 }
        .map { CGPoint(x: $0.midX, y: $0.midY) }
        .removingDuplicates()
    }

    private static func waitForFocus(
        _ window: LiveFocusWindow,
        using axClient: AXClient,
        timeout: TimeInterval,
        lastFailure: inout String,
        context: String
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch axClient.focusedWindowSnapshot() {
            case .success(let snapshot) where snapshot.id == window.id || snapshot.title == window.metadata.title:
                window.updateIdentity(from: snapshot)
                return true
            case .success(let snapshot):
                lastFailure = "focused \(snapshot.id.description) title=\"\(snapshot.title)\" after \(context)"
            case .failure(let error):
                lastFailure = "\(error.description) after \(context)"
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        return false
    }

    private static func postClick(at point: CGPoint) throws {
        CGWarpMouseCursorPosition(point)
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw LiveFocusWorkflowFailure("could not create mouse click events at \(point.debugDescription)")
        }
        down.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        up.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.20))
    }

    private static func postAppKitClick(to window: LiveFocusWindow) {
        let location = CGPoint(x: window.window.frame.width / 2, y: window.window.frame.height / 2)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: timestamp + 0.05,
            windowNumber: window.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0.0
        )
        if let down {
            NSApp.sendEvent(down)
        }
        if let up {
            NSApp.sendEvent(up)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.20))
    }

    private static func waitFor(
        timeout: TimeInterval,
        description: String,
        predicate: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        throw LiveFocusWorkflowFailure(description)
    }

    private static func requireTiledBorderVisible(
        overlay: Overlay,
        targetID: WindowID,
        liveWindow: LiveFocusWindow,
        display: DisplayInfo,
        context: String
    ) throws {
        guard let borderNumber = overlay.debugTiledBorderWindowNumber(for: targetID),
              let actualFrame = overlay.debugTiledBorderFrame(for: targetID)
        else {
            throw LiveFocusWorkflowFailure("\(context) tiled border for \(targetID.description) is not inspectable")
        }
        let expectedFrame = borderFrame(for: liveWindow.metadata.frame, display: display, width: 2)
        guard actualFrame.matches(expectedFrame, tolerance: 2) else {
            throw LiveFocusWorkflowFailure(
                "\(context) tiled border frame mismatch: expected=\(expectedFrame.debugDescription) actual=\(actualFrame.debugDescription)"
            )
        }
        let actualWindowServerFrame = axFrame(forAppKitFrame: actualFrame, display: display)
        guard let resolvedBorderNumber = windowServerNumber(
            appKitWindowNumber: borderNumber,
            frame: actualWindowServerFrame,
            excluding: [liveWindow.windowNumber]
        ) else {
            throw LiveFocusWorkflowFailure("\(context) tiled border was not found in WindowServer order")
        }
        try requireWindowServerOrder(
            above: resolvedBorderNumber,
            below: liveWindow.windowNumber,
            context: "\(context) tiled border above target"
        )
    }

    private static func requireFocusBorderVisible(
        overlay: Overlay,
        target: FocusBorderTarget,
        liveWindow: LiveFocusWindow,
        display: DisplayInfo,
        context: String
    ) throws {
        guard overlay.debugFocusBorderWindowID() == target.windowID,
              overlay.debugFocusBorderIsVisible(),
              let borderNumber = overlay.debugFocusBorderWindowNumber(),
              let actualFrame = overlay.debugFocusBorderFrame()
        else {
            throw LiveFocusWorkflowFailure("\(context) focus border for \(target.windowID.description) is not visible")
        }
        let actualWindowServerFrame = axFrame(forAppKitFrame: actualFrame, display: display)
        let expectedFrame = borderFrame(for: target.frame, display: display, width: Config.default.border.width)
        guard actualFrame.matches(expectedFrame, tolerance: 2) else {
            throw LiveFocusWorkflowFailure(
                "\(context) focus border frame mismatch: expected=\(expectedFrame.debugDescription) actual=\(actualFrame.debugDescription)"
            )
        }
        guard let resolvedBorderNumber = windowServerNumber(
            appKitWindowNumber: borderNumber,
            frame: actualWindowServerFrame,
            excluding: [liveWindow.windowNumber]
        ) else {
            return
        }
        try requireWindowServerOrder(
            above: resolvedBorderNumber,
            below: liveWindow.windowNumber,
            context: "\(context) focus border above target"
        )
    }

    private static func requireFloatingWindowCoversTiledBorder(
        overlay: Overlay,
        floating: LiveFocusWindow,
        tiledID: WindowID,
        display: DisplayInfo,
        context: String
    ) throws {
        guard let tiledBorder = overlay.debugTiledBorderWindowNumber(for: tiledID) else {
            throw LiveFocusWorkflowFailure("\(context) tiled border is not visible")
        }
        if !overlay.debugTiledBorderIsVisuallyVisible(for: tiledID) {
            guard let tiledBorderFrame = overlay.debugTiledBorderFrame(for: tiledID) else {
                throw LiveFocusWorkflowFailure("\(context) tiled border is hidden but has no debug frame")
            }
            let axTiledBorderFrame = axFrame(forAppKitFrame: tiledBorderFrame, display: display)
            let floatingFrame = windowServerFrame(for: floating.windowNumber) ?? floating.metadata.frame
            guard floatingFrame.intersects(axTiledBorderFrame) else {
                throw LiveFocusWorkflowFailure(
                    "\(context) tiled border was hidden without an overlapping floating window: floating=\(floatingFrame.debugDescription) border=\(axTiledBorderFrame.debugDescription)"
                )
            }
            return
        }
        guard let resolvedTiledBorder = windowServerNumber(
            appKitWindowNumber: tiledBorder,
            frame: overlay.debugTiledBorderFrame(for: tiledID).map { axFrame(forAppKitFrame: $0, display: display) },
            excluding: [Int(tiledID.raw), floating.windowNumber]
        ) else {
            throw LiveFocusWorkflowFailure("\(context) tiled border was not found in WindowServer order")
        }
        try requireWindowServerOrder(
            above: floating.windowNumber,
            below: resolvedTiledBorder,
            context: "\(context) floating window above unrelated tiled border"
        )
    }

    private static func requireWindowServerOrder(
        above: Int,
        below: Int,
        context: String,
        timeout: TimeInterval = 0.6
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFailure = "\(context) windows are not visible in window-server order: above=\(above) below=\(below)"
        while Date() < deadline {
            let ordered = frontToBackWindowNumbers()
            guard let aboveIndex = ordered.firstIndex(of: above),
                  let belowIndex = ordered.firstIndex(of: below)
            else {
                lastFailure = "\(context) windows are not visible in window-server order: above=\(above) below=\(below)"
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                continue
            }
            guard aboveIndex < belowIndex else {
                lastFailure = "\(context) failed stack order: aboveIndex=\(aboveIndex) belowIndex=\(belowIndex)"
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                continue
            }
            return
        }
        throw LiveFocusWorkflowFailure(lastFailure)
    }

    private static func requireLiveWindowNotFront(
        _ window: LiveFocusWindow,
        liveWindows: [LiveFocusWindow],
        context: String
    ) throws {
        let front = try frontLiveWindowNumber(liveWindows: liveWindows, context: context)
        guard front != window.windowNumber else {
            throw LiveFocusWorkflowFailure("\(context) target \(window.id.description) unexpectedly started frontmost")
        }
    }

    private static func requireFrontLiveWindow(
        _ window: LiveFocusWindow,
        liveWindows: [LiveFocusWindow],
        context: String
    ) throws {
        let front = try frontLiveWindowNumber(liveWindows: liveWindows, context: context)
        guard front == window.windowNumber else {
            throw LiveFocusWorkflowFailure(
                "\(context) did not raise \(window.id.description) to front; front verifier window=\(front)"
            )
        }
    }

    private static func frontLiveWindowNumber(
        liveWindows: [LiveFocusWindow],
        context: String
    ) throws -> Int {
        let ordered = frontToBackWindowNumbers()
        let liveNumbers = Set(liveWindows.map(\.windowNumber))
        guard let front = ordered.first(where: { liveNumbers.contains($0) }) else {
            throw LiveFocusWorkflowFailure("\(context) could not find verifier windows in window-server order")
        }
        return front
    }

    private static func requireVisible(_ windows: [LiveFocusWindow], context: String) throws {
        let visibleNumbers = Set(frontToBackWindowNumbers())
        let missing = windows.map(\.windowNumber).filter { !visibleNumbers.contains($0) }
        guard missing.isEmpty else {
            throw LiveFocusWorkflowFailure("\(context) windows missing from window server: \(missing)")
        }
    }

    private static func applyLiveMoves(
        _ moves: [WindowID: CGRect],
        to windows: [LiveFocusWindow],
        display: DisplayInfo,
        context: String
    ) throws {
        for (windowID, frame) in moves {
            guard let live = windows.first(where: { $0.id == windowID }) else {
                throw LiveFocusWorkflowFailure("\(context) planned move for unknown window \(windowID.description)")
            }
            live.updateFrame(frame, display: display)
        }
    }

    private static func requireMovedWindowsMatchPlan(
        _ moves: [WindowID: CGRect],
        windows: [LiveFocusWindow],
        display: DisplayInfo,
        context: String
    ) throws {
        for (windowID, frame) in moves {
            guard let live = windows.first(where: { $0.id == windowID }) else {
                throw LiveFocusWorkflowFailure("\(context) planned move for unknown window \(windowID.description)")
            }
            let expected = appKitFrame(forAXFrame: frame, display: display)
            guard live.window.frame.matches(expected, tolerance: 2),
                  live.metadata.frame.matches(frame, tolerance: 2)
            else {
                throw LiveFocusWorkflowFailure(
                    "\(context) frame mismatch for \(windowID.description): expected=\(expected.debugDescription) actual=\(live.window.frame.debugDescription)"
                )
            }
        }
    }

    private static func workflowWorld(
        windows: [LiveFocusWindow],
        display: DisplayInfo,
        activeSpace: SpaceID
    ) -> World {
        let displayState = DisplaySpaceState(
            displayID: display.id,
            tree: .void,
            floating: windows.map(\.id)
        )
        return World(
            displays: [display.id: display],
            activeSpace: activeSpace,
            activeSpaceByDisplay: [display.id: activeSpace],
            spaces: [
                activeSpace: SpaceState(
                    id: activeSpace,
                    displays: [display.id: displayState],
                    focused: windows.first?.id
                )
            ],
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.metadata) }),
            windowDisplay: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, display.id) }),
            windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, activeSpace) }),
            observedVisibleWindows: [WorkspaceKey(displayID: display.id, spaceID: activeSpace): Set(windows.map(\.id))],
            windowConstraints: [:],
            pendingRules: [:],
            config: Config.default
        )
    }

    private static func activeSpace(for display: DisplayInfo) -> SpaceID {
        let displays = [display.id: display]
        return SpaceClient().spaceTopology(displays: displays, windows: []).activeSpaceByDisplay[display.id]
            ?? SpaceID(raw: 930_001)
    }

    private static func makeWindows(display: DisplayInfo) -> LiveFocusWindows {
        let visible = display.visibleFrame
        let tileSeed = CGRect(
            x: visible.minX + 40,
            y: visible.minY + 60,
            width: min(520, visible.width - 100),
            height: min(360, visible.height - 120)
        )
        let coverWidth = min(max(visible.width * 0.36, 360), visible.width - 120)
        let coverHeight = min(max(visible.height * 0.34, 260), visible.height - 140)
        let floatAFrame = CGRect(
            x: visible.minX + 72,
            y: visible.minY + 96,
            width: coverWidth,
            height: coverHeight
        )
        let floatBFrame = CGRect(
            x: visible.minX + 116,
            y: visible.minY + 138,
            width: coverWidth,
            height: coverHeight
        )
        let tiled = makeWindow(
            title: "Narwhal live focus workflow tiled",
            frame: tileSeed,
            display: display,
            color: .systemBlue
        )
        let floatA = makeWindow(
            title: "Narwhal live focus workflow floating A",
            frame: floatAFrame,
            display: display,
            color: .systemOrange
        )
        let floatB = makeWindow(
            title: "Narwhal live focus workflow floating B",
            frame: floatBFrame,
            display: display,
            color: .systemPurple
        )
        tiled.window.orderFrontRegardless()
        floatB.window.orderFrontRegardless()
        floatA.window.orderFrontRegardless()
        return LiveFocusWindows(tiled: tiled, floatA: floatA, floatB: floatB)
    }

    private static func makeWindow(
        title: String,
        frame: CGRect,
        display: DisplayInfo,
        color: NSColor
    ) -> LiveFocusWindow {
        let appKitFrame = appKitFrame(forAXFrame: frame, display: display)
        let window = NSWindow(
            contentRect: appKitFrame,
            styleMask: [.titled],
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
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let snapshot = initialFocusedSnapshot(titled: title)
        let id = snapshot?.id ?? windowID(titled: title) ?? WindowID(raw: CGWindowID(window.windowNumber))
        let metadataFrame = snapshot?.frame ?? frame
        return LiveFocusWindow(
            id: id,
            window: window,
            metadata: WindowMetadata(
                id: id,
                bundleID: BundleID(raw: "dev.narwhal.live-focus-workflow-verifier.\(id.raw)"),
                title: title,
                role: "AXWindow",
                pid: getpid(),
                frame: metadataFrame,
                isResizable: true,
                isMinimized: false
            )
        )
    }

    private static func initialFocusedSnapshot(titled title: String) -> FocusedWindowSnapshot? {
        let axClient = AXClient(processID: -1)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if case .success(let snapshot) = axClient.focusedWindowSnapshot(),
               snapshot.title == title {
                return snapshot
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        return nil
    }

    private static func borderFrame(for axFrame: CGRect, display: DisplayInfo, width: Double) -> CGRect {
        appKitFrame(forAXFrame: axFrame, display: display)
            .insetBy(dx: -CGFloat(width) / 2, dy: -CGFloat(width) / 2)
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

    private static func axFrame(forAppKitFrame frame: CGRect, display: DisplayInfo) -> CGRect {
        let screenFrame = screenFrame(for: display.id) ?? display.frame
        return CGRect(
            x: display.frame.minX + (frame.minX - screenFrame.minX),
            y: display.frame.maxY - (frame.maxY - screenFrame.minY),
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

    private static func frontToBackWindowNumbers() -> [Int] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return [] }

        return windows.compactMap { window in
            if let number = window[kCGWindowNumber as String] as? CGWindowID {
                return Int(number)
            }
            if let number = window[kCGWindowNumber as String] as? Int {
                return number
            }
            return nil
        }
    }

    private static func topmostWindowNumber(at point: CGPoint, ignoring ignored: Set<Int>) -> Int? {
        for window in windowServerWindows() {
            guard
                let number = windowNumber(from: window),
                !ignored.contains(number),
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDictionary),
                frame.contains(point)
            else {
                continue
            }
            return number
        }
        return nil
    }

    private static func windowServerFrame(for windowNumber: Int) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return nil }

        for window in windows {
            let number: Int?
            if let value = window[kCGWindowNumber as String] as? CGWindowID {
                number = Int(value)
            } else {
                number = window[kCGWindowNumber as String] as? Int
            }
            guard number == windowNumber,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }
            return frame
        }
        return nil
    }

    private static func windowServerNumber(
        appKitWindowNumber: Int,
        frame: CGRect?,
        excluding excluded: Set<Int> = []
    ) -> Int? {
        let windows = windowServerWindows()
        if let frame,
           let matched = windows.first(where: { window in
               guard
                   let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                   ownerPID == getpid(),
                   let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                   let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
               else {
                   return false
               }
               return bounds.matches(frame, tolerance: 0.75)
           }),
           let number = windowNumber(from: matched),
           !excluded.contains(number) {
            return number
        }
        let ordered = frontToBackWindowNumbers()
        return ordered.contains(appKitWindowNumber) && !excluded.contains(appKitWindowNumber)
            ? appKitWindowNumber
            : nil
    }

    private static func windowID(titled title: String) -> WindowID? {
        for window in windowServerWindows() {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == getpid(),
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let name = window[kCGWindowName as String] as? String,
                name == title
            else {
                continue
            }
            if let number = windowNumber(from: window) {
                return WindowID(raw: CGWindowID(number))
            }
        }
        return nil
    }

    private static func windowServerWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
    }

    private static func windowNumber(from window: [String: Any]) -> Int? {
        if let number = window[kCGWindowNumber as String] as? CGWindowID {
            return Int(number)
        }
        if let number = window[kCGWindowNumber as String] as? Int {
            return number
        }
        return nil
    }
}

@MainActor
private final class LiveFocusWindow {
    private(set) var id: WindowID
    let window: NSWindow
    private(set) var metadata: WindowMetadata

    var windowNumber: Int {
        window.windowNumber
    }

    init(id: WindowID, window: NSWindow, metadata: WindowMetadata) {
        self.id = id
        self.window = window
        self.metadata = metadata
    }

    func updateIdentity(from snapshot: FocusedWindowSnapshot) {
        id = snapshot.id
        metadata = snapshot.metadata
    }

    func updateFrame(_ frame: CGRect, display: DisplayInfo) {
        metadata = WindowMetadata(
            id: metadata.id,
            bundleID: metadata.bundleID,
            title: metadata.title,
            role: metadata.role,
            pid: metadata.pid,
            frame: frame,
            isResizable: metadata.isResizable,
            isMinimized: metadata.isMinimized
        )
        window.setFrame(LiveFocusWorkflowVerification.appKitFrameForWindowUpdate(frame, display: display), display: true)
    }
}

@MainActor
private struct LiveFocusWindows {
    let tiled: LiveFocusWindow
    let floatA: LiveFocusWindow
    let floatB: LiveFocusWindow

    var all: [LiveFocusWindow] {
        [tiled, floatA, floatB]
    }
}

private struct LiveFocusWorkflowFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = "live focus workflow verification failed: \(message)"
    }
}

private extension LiveFocusWorkflowVerification {
    static func appKitFrameForWindowUpdate(_ frame: CGRect, display: DisplayInfo) -> CGRect {
        appKitFrame(forAXFrame: frame, display: display)
    }
}

private extension CGRect {
    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        narwhalApproximatelyEquals(other, tolerance: tolerance)
    }
}

private extension Array where Element == CGPoint {
    func removingDuplicates() -> [CGPoint] {
        reduce(into: []) { points, point in
            guard !points.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 0.5 }) else {
                return
            }
            points.append(point)
        }
    }
}
#endif
