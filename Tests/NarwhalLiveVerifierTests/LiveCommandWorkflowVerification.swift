#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Darwin
import NarwhalAppSupport
import NarwhalCore

@MainActor
enum LiveCommandWorkflowVerification {
    static func verifyCommandWorkflows() -> (passed: Bool, message: String) {
        verify("full command workflows") {
            let context = try liveWorkflowContext()
            var coverage = LiveCommandWorkflowCoverage.empty
            try verifyZeroWindowFailures(display: context.primaryDisplay, coverage: &coverage)
            try verifyFocusCycleRaisesTargetWithAX(display: context.primaryDisplay, coverage: &coverage)
            for count in 1...6 {
                try verifyWindowCountWorkflow(
                    count: count,
                    display: context.primaryDisplay,
                    includeManualResize: true,
                    coverage: &coverage
                )
            }
            try verifyResetLayoutCommands(display: context.primaryDisplay, coverage: &coverage)
            try verifyDropZone(display: context.primaryDisplay, coverage: &coverage)
            try verifyMoveDisplayIfAvailable(context: context, coverage: &coverage)

            let missingCommands = coverage.missingRequiredCommands()
            guard missingCommands.isEmpty else {
                throw LiveCommandWorkflowFailure("live command workflow verification missed command coverage: \(missingCommands.joined(separator: ", "))")
            }
            let missingManualResizeCounts = coverage.missingRequiredManualResizeCounts()
            guard missingManualResizeCounts.isEmpty else {
                throw LiveCommandWorkflowFailure(
                    "live command workflow verification missed manual tile resize counts: \(missingManualResizeCounts.map(String.init).joined(separator: ", "))"
                )
            }

            return coverage.summary(prefix: "live command workflows verified:")
        }
    }

    private static func verify(
        _ name: String,
        run: () throws -> String
    ) -> (passed: Bool, message: String) {
        if isSystemLocked() {
            return (false, "live command workflow verification requires an unlocked user session")
        }
        do {
            _ = NSApplication.shared
            VerifierAppDelegate.installIfNeeded()
            return (true, try run())
        } catch let error as LiveCommandWorkflowFailure {
            return (false, error.message)
        } catch {
            return (false, "\(name) failed: \(String(describing: error))")
        }
    }

    private static func liveWorkflowContext() throws -> LiveCommandWorkflowContext {
        let displays = DisplayClient().currentDisplays()
        let orderedDisplays = displays.values.sorted {
            if $0.slot == $1.slot { return $0.id.raw < $1.id.raw }
            return $0.slot < $1.slot
        }
        guard let primaryDisplay = orderedDisplays.first else {
            throw LiveCommandWorkflowFailure("live command workflow verification requires at least one display")
        }
        guard primaryDisplay.visibleFrame.width >= 640,
              primaryDisplay.visibleFrame.height >= 420
        else {
            throw LiveCommandWorkflowFailure(
                "live command workflow verification requires a usable primary display; primary=\(primaryDisplay.visibleFrame.debugDescription)"
            )
        }
        return LiveCommandWorkflowContext(primaryDisplay: primaryDisplay, orderedDisplays: orderedDisplays)
    }

    private static func verifyZeroWindowFailures(
        display: DisplayInfo,
        coverage: inout LiveCommandWorkflowCoverage
    ) throws {
        coverage = coverage.recordingCount(0)
        let world = workflowWorld(windows: [], displays: [display], activeDisplay: display)
        let missing = WindowID(raw: 1)
        let rejectedCommands: [(String, Command)] = [
            ("push", .push(missing, .left)),
            ("center", .center(missing)),
            ("eject", .eject(missing)),
            ("toggleFloat", .toggleFloat(missing)),
            ("swap", .swapInTree(missing, .right)),
            ("resizeSplit", .resizeSplit(missing, .right, delta: 0.25)),
            ("move display rejection", .moveToNextDisplay(missing)),
            ("focus", .focus(missing)),
            ("drop zone", .dropAtZone(missing, display.id, ZoneID(raw: "left-half")))
        ]
        for (name, command) in rejectedCommands {
            if case .success(let next) = apply(command, to: world), next != world {
                throw LiveCommandWorkflowFailure("zero-window \(name) unexpectedly mutated world")
            }
            coverage = coverage.recordingCommand(name)
        }
        guard case .failure(.noFocusedWindow) = apply(.focusCycle(.next), to: world) else {
            throw LiveCommandWorkflowFailure("zero-window focus cycle did not reject with noFocusedWindow")
        }
        coverage = coverage.recordingCommand("focusCycle")
    }

    private static func verifyWindowCountWorkflow(
        count: Int,
        display: DisplayInfo,
        includeManualResize: Bool,
        coverage: inout LiveCommandWorkflowCoverage
    ) throws {
        let liveWindows = makeWindows(
            count: count,
            prefix: "Narwhal live command count \(count)",
            display: display,
            colors: verificationColors
        )
        defer {
            liveWindows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        try requireVisible(liveWindows, context: "count \(count) setup")
        coverage = coverage.recordingCount(count)

        var state = LiveCommandWorkflowState(
            world: workflowWorld(windows: liveWindows, displays: [display], activeDisplay: display),
            generation: 1
        )

        try verifyFocusCycleCandidates(
            state.world,
            expected: Set(liveWindows.map(\.id)),
            from: nil,
            direction: .next,
            liveWindows: liveWindows,
            context: "count \(count) all floating cycle next"
        )
        try verifyFocusCycleCandidates(
            state.world,
            expected: Set(liveWindows.map(\.id)),
            from: nil,
            direction: .previous,
            liveWindows: liveWindows,
            context: "count \(count) all floating cycle previous"
        )
        coverage = coverage.recordingCommand("focusCycle")

        state = LiveCommandWorkflowState(
            world: try verifyFocusCommand(
                windowID: liveWindows[0].id,
                world: state.world,
                liveWindows: liveWindows,
                context: "count \(count) direct focus"
            ),
            generation: state.generation
        )
        coverage = coverage.recordingCommand("focus")

        for (index, liveWindow) in liveWindows.enumerated() {
            let direction = pushDirections[index % pushDirections.count]
            state = try verifyLayoutCommand(
                name: "push",
                command: .push(liveWindow.id, direction),
                focusedWindowID: liveWindow.id,
                state: state,
                liveWindows: liveWindows,
                displays: [display.id: display]
            )
            coverage = coverage.recordingCommand("push")
        }

        try verifyOverlayTracksAndClearsTiledBorders(
            world: state.world,
            liveWindows: liveWindows,
            displays: [display.id: display],
            context: "count \(count) tiled borders"
        )
        coverage = coverage.recordingCommand("tiled borders")
        coverage = coverage.recordingCommand("focus border")

        if count > 1 {
            try verifyFocusDirection(
                world: state.world,
                source: liveWindows[count - 1].id,
                liveWindows: liveWindows,
                context: "count \(count)"
            )
            coverage = coverage.recordingCommand("focusDirection")

            state = try verifyFirstSuccessfulTreeCommand(
                name: "swap",
                commands: pushDirections.map { .swapInTree(liveWindows[count - 1].id, $0) },
                focusedWindowID: liveWindows[count - 1].id,
                state: state,
                liveWindows: liveWindows,
                displays: [display.id: display]
            )
            coverage = coverage.recordingCommand("swap")

            state = try verifyFirstSuccessfulTreeCommand(
                name: "resizeSplit",
                commands: pushDirections.map { .resizeSplit(liveWindows[count - 1].id, $0, delta: 0.10) },
                focusedWindowID: liveWindows[count - 1].id,
                state: state,
                liveWindows: liveWindows,
                displays: [display.id: display]
            )
            coverage = coverage.recordingCommand("resizeSplit")
        }

        if includeManualResize, count >= 2 {
            state = try verifyManualTileResize(
                count: count,
                state: state,
                liveWindows: liveWindows,
                displays: [display.id: display]
            )
            coverage = coverage.recordingManualResize(count)
            coverage = coverage.recordingCommand("manual tile resize")
        }

        state = try verifyBalance(state: state, liveWindows: liveWindows, displays: [display.id: display])
        coverage = coverage.recordingCommand("balance")

        let first = liveWindows[0]
        state = try verifyLayoutCommand(
            name: "eject",
            command: .eject(first.id),
            focusedWindowID: first.id,
            state: state,
            liveWindows: liveWindows,
            displays: [display.id: display]
        )
        coverage = coverage.recordingCommand("eject")

        state = try verifyLayoutCommand(
            name: "toggleFloat",
            command: .toggleFloat(first.id),
            focusedWindowID: first.id,
            state: state,
            liveWindows: liveWindows,
            displays: [display.id: display]
        )
        coverage = coverage.recordingCommand("toggleFloat")

        let beforeCenter = state.world
        state = try verifyLayoutCommand(
            name: "center",
            command: .center(first.id),
            focusedWindowID: first.id,
            state: state,
            liveWindows: liveWindows,
            displays: [display.id: display]
        )
        coverage = coverage.recordingCommand("center")

        state = try verifyUndoLayout(
            currentState: state,
            undoWorld: beforeCenter,
            focusedWindowID: first.id,
            liveWindows: liveWindows,
            displays: [display.id: display]
        )
        coverage = coverage.recordingCommand("undoLayout")
    }

    private static func verifyResetLayoutCommands(
        display: DisplayInfo,
        coverage: inout LiveCommandWorkflowCoverage
    ) throws {
        let liveWindows = makeWindows(
            count: 4,
            prefix: "Narwhal live reset commands",
            display: display,
            colors: verificationColors
        )
        defer {
            liveWindows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        var state = LiveCommandWorkflowState(
            world: workflowWorld(windows: liveWindows, displays: [display], activeDisplay: display),
            generation: 1
        )
        for (index, liveWindow) in liveWindows.enumerated() {
            state = try verifyLayoutCommand(
                name: "push",
                command: .push(liveWindow.id, pushDirections[index % pushDirections.count]),
                focusedWindowID: liveWindow.id,
                state: state,
                liveWindows: liveWindows,
                displays: [display.id: display]
            )
        }

        state = try verifyMaximizeReset(state: state, focused: liveWindows[0], liveWindows: liveWindows, displays: [display.id: display])
        coverage = coverage.recordingCommand("maximizeReset")

        state = try verifyCascade(state: state, liveWindows: liveWindows, displays: [display.id: display])
        coverage = coverage.recordingCommand("cascade")

        state = try verifyShuffle(state: state, liveWindows: liveWindows, displays: [display.id: display])
        coverage = coverage.recordingCommand("shuffle")

        state = try verifyResetLayout(state: state, liveWindows: liveWindows, displays: [display.id: display])
        coverage = coverage.recordingCommand("resetLayout")
    }

    private static func verifyDropZone(
        display: DisplayInfo,
        coverage: inout LiveCommandWorkflowCoverage
    ) throws {
        let liveWindows = makeWindows(
            count: 2,
            prefix: "Narwhal live drop zone",
            display: display,
            colors: verificationColors
        )
        defer {
            liveWindows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        guard let zoneID = Config.default.zones.first?.id else {
            throw LiveCommandWorkflowFailure("drop zone verification has no default zones")
        }
        var state = LiveCommandWorkflowState(
            world: workflowWorld(windows: liveWindows, displays: [display], activeDisplay: display),
            generation: 1
        )
        state = try verifyLayoutCommand(
            name: "drop zone",
            command: .dropAtZone(liveWindows[0].id, display.id, zoneID),
            focusedWindowID: liveWindows[0].id,
            state: state,
            liveWindows: liveWindows,
            displays: [display.id: display]
        )
        let tiled = tiledWindowIDs(in: state.world)
        guard tiled.contains(liveWindows[0].id) else {
            throw LiveCommandWorkflowFailure("drop zone did not tile target window")
        }
        coverage = coverage.recordingCommand("drop zone")
    }

    private static func verifyMoveDisplay(
        source: DisplayInfo,
        target: DisplayInfo,
        coverage: inout LiveCommandWorkflowCoverage
    ) throws {
        guard source.visibleFrame.width >= 480,
              source.visibleFrame.height >= 320,
              target.visibleFrame.width >= 480,
              target.visibleFrame.height >= 320
        else {
            coverage = coverage.recordingSkip("move display: displays too small")
            return
        }

        let liveWindows = makeWindows(
            count: 2,
            prefix: "Narwhal live move display",
            display: source,
            colors: verificationColors
        )
        defer {
            liveWindows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        let displays = [source.id: source, target.id: target]
        var state = LiveCommandWorkflowState(
            world: workflowWorld(windows: liveWindows, displays: [source, target], activeDisplay: source),
            generation: 1
        )
        state = try verifyLayoutCommand(
            name: "move display",
            command: .moveToNextDisplay(liveWindows[0].id),
            focusedWindowID: liveWindows[0].id,
            state: state,
            liveWindows: liveWindows,
            displays: displays
        )
        guard state.world.windowDisplay[liveWindows[0].id] == target.id,
              let targetFrame = state.world.windows[liveWindows[0].id]?.frame,
              target.visibleFrame.intersection(targetFrame).area > 0
        else {
            throw LiveCommandWorkflowFailure("move display did not move target into next display workspace")
        }
        coverage = coverage.recordingCommand("move display")
    }

    private static func verifyMoveDisplayIfAvailable(
        context: LiveCommandWorkflowContext,
        coverage: inout LiveCommandWorkflowCoverage
    ) throws {
        if context.orderedDisplays.count >= 2 {
            try verifyMoveDisplay(source: context.orderedDisplays[0], target: context.orderedDisplays[1], coverage: &coverage)
        } else {
            coverage = coverage.recordingSkip("move display: requires two displays")
        }
    }

    private static func verifyManualTileResize(
        count: Int,
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let tiledIDs = tiledWindowIDs(in: state.world)
        let candidate = liveWindows
            .filter { tiledIDs.contains($0.id) }
            .compactMap { live -> ManualResizeCandidate? in
                guard let originalFrame = state.world.windows[live.id]?.frame,
                      let display = displayContaining(originalFrame, displays: displays)
                else {
                    return nil
                }
                let resizedFrame = manuallyResizedFrame(originalFrame, in: display.visibleFrame)
                guard !resizedFrame.matches(originalFrame, tolerance: 2) else {
                    return nil
                }
                let nextWorld: World
                switch apply(.windowResizedExternally(live.id, resizedFrame.size), to: state.world) {
                case .success(let value):
                    nextWorld = value
                case .failure:
                    return nil
                }
                guard nextWorld.spaces != state.world.spaces else { return nil }
                let plan = try? manualResizePlan(
                    targetID: live.id,
                    oldWorld: state.world,
                    nextWorld: nextWorld,
                    generation: state.generation
                )
                guard let plan,
                      plan.desiredLayout.delta.moves.keys.contains(where: { $0 != live.id })
                else {
                    return nil
                }
                return ManualResizeCandidate(
                    target: live,
                    display: display,
                    resizedFrame: resizedFrame,
                    nextWorld: nextWorld,
                    plan: plan
                )
            }
            .first
        guard let candidate else {
            throw LiveCommandWorkflowFailure("manual tile resize count \(count) found no tiled target with a resizable neighbor")
        }

        let targetID = candidate.target.id
        candidate.target.window.setFrame(
            appKitFrame(forAXFrame: candidate.resizedFrame, display: candidate.display),
            display: true
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        try requireMovedWindowsMatchPlan(
            [targetID],
            moves: [targetID: candidate.resizedFrame],
            windows: liveWindows,
            displays: displays,
            context: "manual tile resize count \(count) direct target"
        )

        guard candidate.nextWorld.windows[targetID]?.frame.matches(candidate.resizedFrame, tolerance: 0.5) == true else {
            throw LiveCommandWorkflowFailure(
                "manual tile resize count \(count) did not record resized frame: expected=\(candidate.resizedFrame.debugDescription) actual=\(String(describing: candidate.nextWorld.windows[targetID]?.frame))"
            )
        }
        guard tiledWindowIDs(in: candidate.nextWorld).contains(targetID) else {
            throw LiveCommandWorkflowFailure("manual tile resize count \(count) removed resized target from tiling state")
        }

        let nextState = try applyAndCommit(
            candidate.plan,
            name: "manual tile resize count \(count)",
            state: state,
            liveWindows: liveWindows,
            displays: displays
        )

        try verifyOverlayTracksAndClearsTiledBorders(
            world: nextState.world,
            liveWindows: liveWindows,
            displays: displays,
            context: "manual tile resize count \(count)"
        )

        return nextState
    }

    private static func manualResizePlan(
        targetID: WindowID,
        oldWorld: World,
        nextWorld: World,
        generation: UInt64
    ) throws -> CommandPlanResult {
        let scope = commandPlanScope(
            focusedWindowID: targetID,
            oldWorld: oldWorld,
            newWorld: nextWorld
        )
        switch commandPlan(
            from: oldWorld,
            to: nextWorld,
            focusedWindowID: nil,
            undoWorld: oldWorld,
            generation: LayoutGeneration(raw: generation),
            scope: scope
        ) {
        case .success(let value):
            return value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("manual tile resize plan rejected: \(error.message)")
        }
    }

    private static func verifyLayoutCommand(
        name: String,
        command: Command,
        focusedWindowID: WindowID?,
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let nextWorld: World
        switch apply(command, to: state.world) {
        case .success(let value):
            nextWorld = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("\(name) rejected by core: \(error.message)")
        }
        let scope = commandPlanScope(
            focusedWindowID: focusedWindowID,
            oldWorld: state.world,
            newWorld: nextWorld
        )
        let plan: CommandPlanResult
        switch commandPlan(
            from: state.world,
            to: nextWorld,
            focusedWindowID: focusedWindowID,
            undoWorld: state.world,
            generation: LayoutGeneration(raw: state.generation),
            scope: scope
        ) {
        case .success(let value):
            plan = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("\(name) plan rejected: \(error.message)")
        }
        return try applyAndCommit(plan, name: name, state: state, liveWindows: liveWindows, displays: displays)
    }

    private static func verifyFirstSuccessfulTreeCommand(
        name: String,
        commands: [Command],
        focusedWindowID: WindowID,
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let first = commands.lazy.compactMap { command -> Command? in
            if case .success = apply(command, to: state.world) {
                return command
            }
            return nil
        }.first
        guard let command = first else {
            throw LiveCommandWorkflowFailure("\(name) found no valid direction in current tree")
        }
        return try verifyLayoutCommand(
            name: name,
            command: command,
            focusedWindowID: focusedWindowID,
            state: state,
            liveWindows: liveWindows,
            displays: displays
        )
    }

    private static func verifyBalance(
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        guard let activeSpace = state.world.activeSpace else {
            throw LiveCommandWorkflowFailure("balance has no active space")
        }
        return try verifyLayoutCommand(
            name: "balance",
            command: .balance(activeSpace),
            focusedWindowID: activeFocusedWindow(in: state.world)?.id,
            state: state,
            liveWindows: liveWindows,
            displays: displays
        )
    }

    private static func verifyUndoLayout(
        currentState: LiveCommandWorkflowState,
        undoWorld: World,
        focusedWindowID: WindowID?,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let scope = commandPlanScope(
            focusedWindowID: focusedWindowID,
            oldWorld: currentState.world,
            newWorld: undoWorld
        )
        let plan: CommandPlanResult
        switch commandPlan(
            from: currentState.world,
            to: undoWorld,
            focusedWindowID: focusedWindowID,
            undoWorld: currentState.world,
            generation: LayoutGeneration(raw: currentState.generation),
            scope: scope
        ) {
        case .success(let value):
            plan = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("undoLayout plan rejected: \(error.message)")
        }
        return try applyAndCommit(plan, name: "undoLayout", state: currentState, liveWindows: liveWindows, displays: displays)
    }

    private static func verifyMaximizeReset(
        state: LiveCommandWorkflowState,
        focused: LiveCommandWorkflowWindow,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let layout: Layout
        switch maximizeResetLayout(windowID: focused.id, in: state.world) {
        case .success(let value):
            layout = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("maximizeReset layout rejected: \(error.message)")
        }
        let nextWorld = worldBySettingFocus(focused.id, in: resetActiveSpaceTilingState(in: state.world))
        return try verifyCustomLayout(
            name: "maximizeReset",
            layout: layout,
            nextWorld: nextWorld,
            focusedWindowID: focused.id,
            state: state,
            liveWindows: liveWindows,
            displays: displays
        )
    }

    private static func verifyCascade(
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let layout: Layout
        switch cascadeResetLayout(in: state.world) {
        case .success(let value):
            layout = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("cascade layout rejected: \(error.message)")
        }
        return try verifyCustomLayout(
            name: "cascade",
            layout: layout,
            nextWorld: resetActiveSpaceTilingState(in: state.world),
            focusedWindowID: nil,
            state: state,
            liveWindows: liveWindows,
            displays: displays
        )
    }

    private static func verifyShuffle(
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        var generator = SeededGenerator(seed: 0x5eed_2026)
        let layout: Layout
        switch shuffledResetLayout(in: state.world, using: &generator) {
        case .success(let value):
            layout = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("shuffle layout rejected: \(error.message)")
        }
        return try verifyCustomLayout(
            name: "shuffle",
            layout: layout,
            nextWorld: resetActiveSpaceTilingState(in: state.world),
            focusedWindowID: nil,
            state: state,
            liveWindows: liveWindows,
            displays: displays
        )
    }

    private static func verifyResetLayout(
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let resetWorld: World
        switch apply(.resetLayout, to: state.world) {
        case .success(let value):
            resetWorld = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("resetLayout rejected: \(error.message)")
        }
        let plan: CommandPlanResult
        switch commandPlan(
            from: state.world,
            to: resetWorld,
            focusedWindowID: nil,
            undoWorld: state.world,
            generation: LayoutGeneration(raw: state.generation),
            scope: .activeWorkspaces
        ) {
        case .success(let value):
            plan = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("resetLayout plan rejected: \(error.message)")
        }
        let next = try applyAndCommit(plan, name: "resetLayout", state: state, liveWindows: liveWindows, displays: displays)
        switch tiledBorderTargets(of: next.world) {
        case .success(let targets):
            guard targets.isEmpty else {
                throw LiveCommandWorkflowFailure("resetLayout left tiled border targets: \(ids(Set(targets.map(\.windowID))))")
            }
        case .failure(let unsatisfiable):
            throw LiveCommandWorkflowFailure("resetLayout border target solve failed: \(unsatisfiable)")
        }
        return next
    }

    private static func verifyCustomLayout(
        name: String,
        layout: Layout,
        nextWorld: World,
        focusedWindowID: WindowID?,
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        let plan: CommandPlanResult
        switch customLayoutCommandPlan(
            from: state.world,
            to: nextWorld,
            layout: layout,
            focusedWindowID: focusedWindowID,
            undoWorld: nil,
            generation: LayoutGeneration(raw: state.generation)
        ) {
        case .success(let value):
            plan = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("\(name) plan rejected: \(error.message)")
        }
        guard !plan.desiredLayout.delta.moves.isEmpty else {
            throw LiveCommandWorkflowFailure("\(name) produced no visible frame moves")
        }
        return try applyAndCommit(plan, name: name, state: state, liveWindows: liveWindows, displays: displays)
    }

    private static func applyAndCommit(
        _ plan: CommandPlanResult,
        name: String,
        state: LiveCommandWorkflowState,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo]
    ) throws -> LiveCommandWorkflowState {
        try applyLiveMoves(plan.desiredLayout.delta.moves, to: liveWindows, displays: displays, context: name)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        try requireMovedWindowsMatchPlan(
            Set(plan.desiredLayout.delta.moves.keys),
            moves: plan.desiredLayout.delta.moves,
            windows: liveWindows,
            displays: displays,
            context: name
        )
        return LiveCommandWorkflowState(
            world: worldByRecordingWindowFrames(plan.desiredLayout.delta.moves, in: plan.plannedWorld),
            generation: state.generation + 1
        )
    }

    private static func verifyFocusDirection(
        world: World,
        source: WindowID,
        liveWindows: [LiveCommandWorkflowWindow],
        context: String
    ) throws {
        let plans = pushDirections.compactMap { direction -> FocusPlanResult? in
            if case .success(let plan) = focusDirectionPlan(in: world, from: source, direction: direction) {
                return plan
            }
            return nil
        }
        guard let plan = plans.first else {
            throw LiveCommandWorkflowFailure("\(context) focusDirection found no visible neighbor")
        }
        try raiseAndVerify(plan.window.id, liveWindows: liveWindows, context: "\(context) focusDirection")
    }

    private static func verifyFocusCommand(
        windowID: WindowID,
        world: World,
        liveWindows: [LiveCommandWorkflowWindow],
        context: String
    ) throws -> World {
        let nextWorld: World
        switch apply(.focus(windowID), to: world) {
        case .success(let value):
            nextWorld = value
        case .failure(let error):
            throw LiveCommandWorkflowFailure("\(context) rejected by core: \(error.message)")
        }
        switch focusPlan(in: nextWorld, windowID: windowID) {
        case .success(let plan):
            try raiseAndVerify(plan.window.id, liveWindows: liveWindows, context: context)
        case .failure(let error):
            throw LiveCommandWorkflowFailure("\(context) plan rejected: \(error.message)")
        }
        return nextWorld
    }

    private static func verifyFocusCycleCandidates(
        _ world: World,
        expected: Set<WindowID>,
        from focusedWindowID: WindowID?,
        direction: FocusCycleDirection,
        liveWindows: [LiveCommandWorkflowWindow],
        context: String
    ) throws {
        let candidates: [FocusPlanResult]
        switch focusCycleCandidatePlans(in: world, from: focusedWindowID, direction: direction) {
        case .success(let value):
            candidates = value
        case .failure(let error):
            if expected.isEmpty { return }
            throw LiveCommandWorkflowFailure("\(context) focusCycle rejected: \(error.message)")
        }
        let candidateIDs = Set(candidates.map(\.window.id))
        guard candidateIDs == expected else {
            throw LiveCommandWorkflowFailure("\(context) focusCycle candidates expected \(ids(expected)) got \(ids(candidateIDs))")
        }
        guard let first = candidates.first else {
            if expected.isEmpty { return }
            throw LiveCommandWorkflowFailure("\(context) focusCycle had no live candidates")
        }
        try raiseAndVerify(first.window.id, liveWindows: liveWindows, context: context)
    }

    private static func verifyFocusCycleRaisesTargetWithAX(
        display: DisplayInfo,
        coverage: inout LiveCommandWorkflowCoverage
    ) throws {
        // See LiveFocusWorkflowVerification.activateVerifierApplication for why
        // we use .accessory: prevents AppKit auto-terminate on the deferred
        // window cleanup at end of test.
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        NSApp.unhide(nil)

        let windows = makeFocusableWindows(display: display)
        defer {
            windows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try requireVisible(windows, context: "focusCycle AX raise setup")

        let world = workflowWorld(windows: windows, displays: [display], activeDisplay: display)
        let focused = windows[0].id
        let target: FocusPlanResult
        switch focusCycleCandidatePlans(in: world, from: focused, direction: .next) {
        case .success(let candidates):
            guard let first = candidates.first else {
                throw LiveCommandWorkflowFailure("focusCycle AX raise had no candidates")
            }
            target = first
        case .failure(let error):
            throw LiveCommandWorkflowFailure("focusCycle AX raise rejected: \(error.message)")
        }

        windows[0].window.orderFrontRegardless()
        windows[1].window.orderFrontRegardless()
        windows[2].window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try requireLiveWindowNotFront(
            target.window.id,
            liveWindows: windows,
            context: "focusCycle AX raise precondition"
        )

        switch awaitLiveVerifierOperation({ await AXClient(processID: -1).focusWindow(target.window) }) {
        case .success:
            break
        case .failure(let error):
            throw LiveCommandWorkflowFailure("focusCycle AX raise failed focusing \(target.window.id.description): \(error.description)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        try requireFrontLiveWindow(
            target.window.id,
            liveWindows: windows,
            context: "focusCycle AX raise"
        )
        coverage = coverage.recordingCommand("focusCycle")
    }

    private static func verifyOverlayTracksAndClearsTiledBorders(
        world: World,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo],
        context: String
    ) throws {
        let targets: [FocusBorderTarget]
        switch tiledBorderTargets(of: world) {
        case .success(let value):
            targets = value
        case .failure(let unsatisfiable):
            throw LiveCommandWorkflowFailure("\(context) tiled border solve failed: \(unsatisfiable)")
        }
        let expectedIDs = tiledWindowIDs(in: world)
        guard Set(targets.map(\.windowID)) == expectedIDs else {
            throw LiveCommandWorkflowFailure("\(context) tiled border targets expected \(ids(expectedIDs)) got \(ids(Set(targets.map(\.windowID))))")
        }
        let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
        defer {
            overlay.stop()
        }
        overlay.render(OverlayModel.empty.settingTiledBorders(targets))
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard Set(overlay.debugTiledBorderWindowIDs()) == expectedIDs,
              overlay.debugVisibleTiledBorderCount() == expectedIDs.count
        else {
            throw LiveCommandWorkflowFailure("\(context) overlay showed wrong tiled borders: expected \(ids(expectedIDs)) got \(ids(Set(overlay.debugTiledBorderWindowIDs())))")
        }
        for target in targets {
            try requireTiledBorderVisible(
                overlay: overlay,
                target: target,
                liveWindows: liveWindows,
                displays: displays,
                context: context
            )
        }

        if let focusedID = activeFocusedWindow(in: world)?.id ?? targets.first?.windowID {
            let plannedFocus: FocusPlanResult
            switch focusPlan(in: world, windowID: focusedID) {
            case .success(let value):
                plannedFocus = value
            case .failure(let error):
                throw LiveCommandWorkflowFailure("\(context) focus border plan rejected: \(error.message)")
            }
            let focusTarget = FocusBorderTarget(window: plannedFocus.window, frame: plannedFocus.frame)
            overlay.render(OverlayModel.empty.settingTiledBorders(targets).showingFocusBorder(focusTarget))
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            try requireFocusBorderVisible(
                overlay: overlay,
                target: focusTarget,
                liveWindows: liveWindows,
                displays: displays,
                context: "\(context) focus border"
            )
            if let liveTarget = liveWindow(focusedID, in: liveWindows) {
                liveTarget.window.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(0.45))
                try requireFocusBorderVisible(
                    overlay: overlay,
                    target: focusTarget,
                    liveWindows: liveWindows,
                    displays: displays,
                    context: "\(context) focus border after target raise"
                )
            }
        }

        let resetModel = OverlayModel.empty.settingTiledBorders([])
        overlay.render(resetModel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard overlay.debugTiledBorderWindowIDs().isEmpty,
              overlay.debugVisibleTiledBorderCount() == 0
        else {
            throw LiveCommandWorkflowFailure("\(context) overlay did not clear tiled borders")
        }
    }

    private static func requireTiledBorderVisible(
        overlay: Overlay,
        target: FocusBorderTarget,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo],
        context: String
    ) throws {
        guard let borderNumber = overlay.debugTiledBorderWindowNumber(for: target.windowID),
              let actualFrame = overlay.debugTiledBorderFrame(for: target.windowID),
              let liveTarget = liveWindow(target.windowID, in: liveWindows),
              let display = displayContaining(target.frame, displays: displays)
        else {
            throw LiveCommandWorkflowFailure("\(context) tiled border for \(target.windowID.description) is not inspectable")
        }
        let expectedFrame = borderFrame(for: target.frame, display: display, width: 2)
        guard actualFrame.matches(expectedFrame, tolerance: 2) else {
            throw LiveCommandWorkflowFailure(
                "\(context) tiled border frame mismatch for \(target.windowID.description): expected=\(expectedFrame.debugDescription) actual=\(actualFrame.debugDescription)"
            )
        }
        try requireWindowServerOrder(
            above: borderNumber,
            below: liveTarget.window.windowNumber,
            context: "\(context) tiled border \(target.windowID.description)"
        )
    }

    private static func requireFocusBorderVisible(
        overlay: Overlay,
        target: FocusBorderTarget,
        liveWindows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo],
        context: String
    ) throws {
        guard overlay.debugFocusBorderWindowID() == target.windowID,
              overlay.debugFocusBorderIsVisible(),
              let focusNumber = overlay.debugFocusBorderWindowNumber(),
              let liveTarget = liveWindow(target.windowID, in: liveWindows),
              let display = displayContaining(target.frame, displays: displays)
        else {
            throw LiveCommandWorkflowFailure("\(context) is not visible for \(target.windowID.description)")
        }
        let expectedFrame = borderFrame(for: target.frame, display: display, width: Config.default.border.width)
        guard let actualFrame = overlay.debugFocusBorderFrame(),
              actualFrame.matches(expectedFrame, tolerance: 2)
        else {
            throw LiveCommandWorkflowFailure(
                "\(context) frame mismatch for \(target.windowID.description): expected=\(expectedFrame.debugDescription) actual=\(String(describing: overlay.debugFocusBorderFrame()))"
            )
        }
        if let tiledNumber = overlay.debugTiledBorderWindowNumber(for: target.windowID) {
            try requireWindowServerOrder(
                above: focusNumber,
                below: tiledNumber,
                context: "\(context) focus above tiled border"
            )
            try requireWindowServerOrder(
                above: tiledNumber,
                below: liveTarget.window.windowNumber,
                context: "\(context) tiled border above target"
            )
        } else {
            try requireWindowServerOrder(
                above: focusNumber,
                below: liveTarget.window.windowNumber,
                context: "\(context) focus above target"
            )
        }
    }

    private static func requireWindowServerOrder(
        above: Int,
        below: Int,
        context: String
    ) throws {
        let ordered = frontToBackWindowNumbers()
        guard let aboveIndex = ordered.firstIndex(of: above),
              let belowIndex = ordered.firstIndex(of: below)
        else {
            throw LiveCommandWorkflowFailure("\(context) windows are not visible in window-server order: above=\(above) below=\(below)")
        }
        guard aboveIndex < belowIndex else {
            throw LiveCommandWorkflowFailure("\(context) is hidden behind target: aboveIndex=\(aboveIndex) belowIndex=\(belowIndex)")
        }
    }

    private static func borderFrame(for axFrame: CGRect, display: DisplayInfo, width: Double) -> CGRect {
        appKitFrame(forAXFrame: axFrame, display: display)
            .insetBy(dx: -CGFloat(width) / 2, dy: -CGFloat(width) / 2)
    }

    private static func workflowWorld(
        windows: [LiveCommandWorkflowWindow],
        displays: [DisplayInfo],
        activeDisplay: DisplayInfo
    ) -> World {
        let activeSpaces = activeSpacesByDisplay(for: displays)
        let activeSpace = activeSpaces[activeDisplay.id] ?? SpaceID(raw: 920_001)
        let displayIDs = Set(displays.map(\.id))
        let worldDisplays = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let windowsByDisplay = Dictionary(grouping: windows) { window in
            displayIDs.contains(window.displayID) ? window.displayID : activeDisplay.id
        }
        let spaces = displays.reduce([SpaceID: SpaceState]()) { partial, display in
            let spaceID = activeSpaces[display.id] ?? activeSpace
            let workspaceWindows = windowsByDisplay[display.id] ?? []
            let displayState = DisplaySpaceState(
                displayID: display.id,
                tree: .void,
                floating: workspaceWindows.map(\.id)
            )
            let existing = partial[spaceID] ?? SpaceState(id: spaceID, displays: [:], focused: nil)
            let focused = existing.focused ?? (display.id == activeDisplay.id ? workspaceWindows.first?.id : nil)
            let next = SpaceState(
                id: spaceID,
                displays: existing.displays.merging([display.id: displayState]) { _, replacement in replacement },
                focused: focused
            )
            return partial.merging([spaceID: next]) { _, replacement in replacement }
        }
        let windowDisplay = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.displayID) })
        let windowSpace = Dictionary(uniqueKeysWithValues: windows.map { window in
            (window.id, activeSpaces[window.displayID] ?? activeSpace)
        })
        let observed = displays.reduce([WorkspaceKey: Set<WindowID>]()) { partial, display in
            let spaceID = activeSpaces[display.id] ?? activeSpace
            let ids = Set((windowsByDisplay[display.id] ?? []).map(\.id))
            guard !ids.isEmpty else { return partial }
            return partial.merging([WorkspaceKey(displayID: display.id, spaceID: spaceID): ids]) { _, replacement in replacement }
        }

        return World(
            displays: worldDisplays,
            activeSpace: activeSpace,
            activeSpaceByDisplay: activeSpaces,
            spaces: spaces,
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.metadata) }),
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: observed,
            windowConstraints: [:],
            pendingRules: [:],
            config: Config.default
        )
    }

    private static func activeSpacesByDisplay(for displays: [DisplayInfo]) -> [DisplayID: SpaceID] {
        let displayMap = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let topology = SpaceClient().spaceTopology(displays: displayMap, windows: [])
        let fallbackSpace = SpaceID(raw: 920_001)
        return Dictionary(uniqueKeysWithValues: displays.enumerated().map { index, display in
            (display.id, topology.activeSpaceByDisplay[display.id] ?? SpaceID(raw: fallbackSpace.raw + UInt64(index)))
        })
    }

    private static func makeWindows(
        count: Int,
        prefix: String,
        display: DisplayInfo,
        colors: [NSColor]
    ) -> [LiveCommandWorkflowWindow] {
        (0..<count).map { index in
            let frame = sampleFrame(in: display.visibleFrame, index: index, count: count)
            let appKitFrame = appKitFrame(forAXFrame: frame, display: display)
            let window = NSWindow(
                contentRect: appKitFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.title = "\(prefix) \(index + 1)"
            window.backgroundColor = colors[index % colors.count]
            window.isOpaque = true
            window.hasShadow = false
            window.level = .normal
            window.collectionBehavior = [.ignoresCycle]
            window.setFrame(appKitFrame, display: false)
            window.orderFrontRegardless()

            let id = WindowID(raw: CGWindowID(window.windowNumber))
            return LiveCommandWorkflowWindow(
                id: id,
                displayID: display.id,
                window: window,
                metadata: WindowMetadata(
                    id: id,
                    bundleID: BundleID(raw: "dev.narwhal.live-command-workflow-verifier.\(index + 1)"),
                    title: window.title,
                    role: "AXWindow",
                    pid: getpid(),
                    frame: frame,
                    isResizable: true,
                    isMinimized: false
                )
            )
        }
    }

    private static func makeFocusableWindows(display: DisplayInfo) -> [LiveCommandWorkflowWindow] {
        let baseFrame = centeredFrame(in: display.visibleFrame, width: 520, height: 360)
        return (0..<3).map { index in
            let frame = baseFrame.offsetBy(dx: CGFloat(index * 28), dy: CGFloat(index * 18))
            let appKitFrame = appKitFrame(forAXFrame: frame, display: display)
            let window = NSWindow(
                contentRect: appKitFrame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = "Narwhal live focus-cycle AX raise \(index + 1)"
            window.backgroundColor = verificationColors[index % verificationColors.count]
            window.isOpaque = true
            window.hasShadow = false
            window.level = .normal
            window.collectionBehavior = [.ignoresCycle]
            window.setFrame(appKitFrame, display: false)
            window.makeKeyAndOrderFront(nil)

            let id = WindowID(raw: CGWindowID(window.windowNumber))
            return LiveCommandWorkflowWindow(
                id: id,
                displayID: display.id,
                window: window,
                metadata: WindowMetadata(
                    id: id,
                    bundleID: BundleID(raw: "dev.narwhal.live-command-workflow-verifier.focus.\(index + 1)"),
                    title: window.title,
                    role: "AXWindow",
                    pid: getpid(),
                    frame: frame,
                    isResizable: true,
                    isMinimized: false
                )
            )
        }
    }

    private static func sampleFrame(in visibleFrame: CGRect, index: Int, count: Int) -> CGRect {
        let columns = min(3, max(1, count))
        let rows = Int(ceil(Double(max(1, count)) / Double(columns)))
        let width = max(180, min(visibleFrame.width / CGFloat(columns) - 36, 520))
        let height = max(140, min(visibleFrame.height / CGFloat(rows) - 36, 360))
        let column = index % columns
        let row = index / columns
        let cellWidth = visibleFrame.width / CGFloat(columns)
        let cellHeight = visibleFrame.height / CGFloat(max(1, rows))
        return CGRect(
            x: visibleFrame.minX + CGFloat(column) * cellWidth + 18,
            y: visibleFrame.minY + CGFloat(row) * cellHeight + 18,
            width: min(width, max(120, visibleFrame.width - 36)),
            height: min(height, max(100, visibleFrame.height - 36))
        )
    }

    private static func manuallyResizedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let widthDelta = min(max(18, frame.width * 0.12), max(0, frame.width - 120))
        let heightDelta = min(max(14, frame.height * 0.10), max(0, frame.height - 96))
        let candidate = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: max(96, frame.width - widthDelta),
            height: max(80, frame.height - heightDelta)
        )
        return candidate.intersection(visibleFrame).standardized
    }

    private static func centeredFrame(in visibleFrame: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: visibleFrame.midX - min(width, visibleFrame.width - 80) / 2,
            y: visibleFrame.midY - min(height, visibleFrame.height - 80) / 2,
            width: min(width, visibleFrame.width - 80),
            height: min(height, visibleFrame.height - 80)
        )
    }

    private static func applyLiveMoves(
        _ moves: [WindowID: CGRect],
        to windows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo],
        context: String
    ) throws {
        for (windowID, axFrame) in moves {
            guard let live = liveWindow(windowID, in: windows) else {
                throw LiveCommandWorkflowFailure("\(context) planned move for unknown live window \(windowID.description)")
            }
            guard let display = displayContaining(axFrame, displays: displays) else {
                throw LiveCommandWorkflowFailure("\(context) planned move outside known displays for \(windowID.description): \(axFrame.debugDescription)")
            }
            live.window.setFrame(appKitFrame(forAXFrame: axFrame, display: display), display: true)
        }
    }

    private static func requireMovedWindowsMatchPlan(
        _ windowIDs: Set<WindowID>,
        moves: [WindowID: CGRect],
        windows: [LiveCommandWorkflowWindow],
        displays: [DisplayID: DisplayInfo],
        context: String
    ) throws {
        for windowID in windowIDs {
            guard let axFrame = moves[windowID],
                  let live = liveWindow(windowID, in: windows),
                  let display = displayContaining(axFrame, displays: displays)
            else {
                throw LiveCommandWorkflowFailure("\(context) cannot verify moved frame for \(windowID.description)")
            }
            let expected = appKitFrame(forAXFrame: axFrame, display: display)
            let serverFrame = LiveWindowServerVerification.waitForFrame(windowNumber: live.window.windowNumber, matching: axFrame)
            guard live.window.frame.matches(expected, tolerance: 2),
                  serverFrame?.matches(axFrame, tolerance: 2) == true
            else {
                throw LiveCommandWorkflowFailure(
                    "\(context) frame mismatch for \(windowID.description): expectedAppKit=\(expected.debugDescription) actualAppKit=\(live.window.frame.debugDescription) expectedWindowServer=\(axFrame.debugDescription) actualWindowServer=\(serverFrame?.debugDescription ?? "nil")"
                )
            }
        }
    }

    private static func raiseAndVerify(
        _ windowID: WindowID,
        liveWindows: [LiveCommandWorkflowWindow],
        context: String
    ) throws {
        guard let target = liveWindow(windowID, in: liveWindows) else {
            throw LiveCommandWorkflowFailure("\(context) focus target \(windowID.description) has no live window")
        }
        target.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        let ordered = frontToBackWindowNumbers()
        let liveNumbers = Set(liveWindows.map { $0.window.windowNumber })
        guard let frontLive = ordered.first(where: { liveNumbers.contains($0) }) else {
            throw LiveCommandWorkflowFailure("\(context) could not find verifier windows in window-server order")
        }
        guard frontLive == target.window.windowNumber else {
            throw LiveCommandWorkflowFailure("\(context) did not raise \(windowID.description) to front; front verifier window=\(frontLive)")
        }
    }

    private static func requireLiveWindowNotFront(
        _ windowID: WindowID,
        liveWindows: [LiveCommandWorkflowWindow],
        context: String
    ) throws {
        let frontLive = try frontLiveWindowNumber(liveWindows: liveWindows, context: context)
        guard let target = liveWindow(windowID, in: liveWindows) else {
            throw LiveCommandWorkflowFailure("\(context) target \(windowID.description) has no live window")
        }
        guard frontLive != target.window.windowNumber else {
            throw LiveCommandWorkflowFailure("\(context) target \(windowID.description) unexpectedly started as front window")
        }
    }

    private static func requireFrontLiveWindow(
        _ windowID: WindowID,
        liveWindows: [LiveCommandWorkflowWindow],
        context: String
    ) throws {
        let frontLive = try frontLiveWindowNumber(liveWindows: liveWindows, context: context)
        guard let target = liveWindow(windowID, in: liveWindows) else {
            throw LiveCommandWorkflowFailure("\(context) target \(windowID.description) has no live window")
        }
        guard frontLive == target.window.windowNumber else {
            throw LiveCommandWorkflowFailure("\(context) did not raise \(windowID.description) to front; front verifier window=\(frontLive)")
        }
    }

    private static func frontLiveWindowNumber(
        liveWindows: [LiveCommandWorkflowWindow],
        context: String
    ) throws -> Int {
        let ordered = frontToBackWindowNumbers()
        let liveNumbers = Set(liveWindows.map { $0.window.windowNumber })
        guard let frontLive = ordered.first(where: { liveNumbers.contains($0) }) else {
            throw LiveCommandWorkflowFailure("\(context) could not find verifier windows in window-server order")
        }
        return frontLive
    }

    private static func requireVisible(
        _ windows: [LiveCommandWorkflowWindow],
        context: String
    ) throws {
        let visibleNumbers = Set(frontToBackWindowNumbers())
        let missing = windows
            .map(\.window.windowNumber)
            .filter { !visibleNumbers.contains($0) }
        guard missing.isEmpty else {
            throw LiveCommandWorkflowFailure("\(context) windows missing from window server: \(missing)")
        }
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
        guard let displayID = displayContainingFrame(frame, displays: displays),
              let display = displays[displayID],
              display.visibleFrame.intersection(frame).narwhalArea > 0
        else { return nil }
        return display
    }

    private static func liveWindow(_ id: WindowID, in windows: [LiveCommandWorkflowWindow]) -> LiveCommandWorkflowWindow? {
        windows.first { $0.id == id }
    }

    private static func tiledWindowIDs(in world: World) -> Set<WindowID> {
        world.spaces.values.reduce(Set<WindowID>()) { result, space in
            result.union(space.displays.values.reduce(Set<WindowID>()) { partial, state in
                partial.union(occupiedWindows(in: state.tree))
            })
        }
    }

    private static func ids(_ ids: Set<WindowID>) -> String {
        ids.sorted { $0.raw < $1.raw }.map(\.description).joined(separator: ",")
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

    private static let pushDirections: [Direction] = [.left, .right, .up, .down]
    private static let verificationColors: [NSColor] = [
        .systemBlue,
        .systemGreen,
        .systemPurple,
        .systemOrange,
        .systemRed,
        .systemTeal
    ]
}

@MainActor
private struct LiveCommandWorkflowWindow {
    let id: WindowID
    let displayID: DisplayID
    let window: NSWindow
    let metadata: WindowMetadata
}

private struct LiveCommandWorkflowState {
    let world: World
    let generation: UInt64
}

@MainActor
private struct ManualResizeCandidate {
    let target: LiveCommandWorkflowWindow
    let display: DisplayInfo
    let resizedFrame: CGRect
    let nextWorld: World
    let plan: CommandPlanResult
}

private struct LiveCommandWorkflowContext {
    let primaryDisplay: DisplayInfo
    let orderedDisplays: [DisplayInfo]
}

private struct LiveCommandWorkflowCoverage {
    let windowCounts: Set<Int>
    let manualResizeCounts: Set<Int>
    let commands: Set<String>
    let skips: [String]

    static let empty = LiveCommandWorkflowCoverage(windowCounts: [], manualResizeCounts: [], commands: [], skips: [])

    func recordingCount(_ count: Int) -> LiveCommandWorkflowCoverage {
        LiveCommandWorkflowCoverage(
            windowCounts: windowCounts.union([count]),
            manualResizeCounts: manualResizeCounts,
            commands: commands,
            skips: skips
        )
    }

    func recordingManualResize(_ count: Int) -> LiveCommandWorkflowCoverage {
        LiveCommandWorkflowCoverage(
            windowCounts: windowCounts,
            manualResizeCounts: manualResizeCounts.union([count]),
            commands: commands,
            skips: skips
        )
    }

    func recordingCommand(_ command: String) -> LiveCommandWorkflowCoverage {
        LiveCommandWorkflowCoverage(
            windowCounts: windowCounts,
            manualResizeCounts: manualResizeCounts,
            commands: commands.union([command]),
            skips: skips
        )
    }

    func recordingSkip(_ skip: String) -> LiveCommandWorkflowCoverage {
        LiveCommandWorkflowCoverage(
            windowCounts: windowCounts,
            manualResizeCounts: manualResizeCounts,
            commands: commands,
            skips: skips + [skip]
        )
    }

    func missingRequiredCommands() -> [String] {
        let required = Set([
            "push",
            "center",
            "eject",
            "focusDirection",
            "focusCycle",
            "focus",
            "swap",
            "resizeSplit",
            "balance",
            "toggleFloat",
            "drop zone",
            "resetLayout",
            "cascade",
            "shuffle",
            "maximizeReset",
            "undoLayout",
            "manual tile resize",
            "move display",
            "tiled borders",
            "focus border"
        ])
        return required.subtracting(commands).sorted()
    }

    func missingRequiredManualResizeCounts() -> [Int] {
        Set(2...6).subtracting(manualResizeCounts).sorted()
    }

    func summary(prefix: String) -> String {
        [
            prefix,
            "windowCounts=\(windowCounts.sorted().map(String.init).joined(separator: ","))",
            "manualResizeCounts=\(manualResizeCounts.sorted().map(String.init).joined(separator: ","))",
            "commands=\(commands.sorted().joined(separator: ","))",
            "skips=\(skips.isEmpty ? "none" : skips.joined(separator: ";"))"
        ].joined(separator: " ")
    }
}

private struct LiveCommandWorkflowFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = "live command workflow verification failed: \(message)"
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

private extension CGRect {
    var area: CGFloat {
        narwhalArea
    }

    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        narwhalApproximatelyEquals(other, tolerance: tolerance)
    }
}
#endif
