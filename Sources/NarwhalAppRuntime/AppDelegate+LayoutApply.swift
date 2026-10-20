import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    @MainActor
    func focusedLayoutContext(operation: String) async -> FocusedLayoutContext? {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("\(operation) skipped because Accessibility is not trusted")
            showOperatorFeedback("\(operation) failed: Accessibility not trusted", tone: .error)
            return nil
        }

        let focused: FocusedLayoutContext
        if let snapshot = await focusedWindowSnapshotForLayoutOperation(operation) {
            focused = FocusedLayoutContext(metadata: snapshot.metadata, displays: displayClient.currentDisplays())
        } else {
            let error = focusedWindowReadError()
            let displays = displayClient.currentDisplays()
            _ = await refreshEnvironmentLocked(
                reason: "\(operation.lowercased()) focus fallback",
                displays: displays,
                reconciliationMode: .observeOnly
            )
            if let fallback = await worldActor.focusedWindowFallback() {
                reporter.info("\(operation) using stored focused-window fallback \(fallback.id.description) after AX focus read failed: \(error.description)")
                focused = FocusedLayoutContext(metadata: fallback, displays: displays)
            } else if let recovered = await waitForFocusedLayoutContextAfterSpaceChange(
                operation: operation,
                initialError: error
            ) {
                focused = recovered
            } else {
                reporter.error("\(operation) failed reading focused window: \(error.description)")
                showOperatorFeedback("\(operation) failed: no focused window", tone: .error)
                return nil
            }
        }

        guard focused.metadata.role == "AXWindow" else {
            reporter.error("\(operation) failed: focused element is not a window")
            showOperatorFeedback("\(operation) failed: no focused window", tone: .error)
            return nil
        }

        reporter.info("\(operation) focused \(focused.logDescription)")
        logDisplays(focused.displays)
        return focused
    }

    @MainActor
    private func focusedWindowSnapshotForLayoutOperation(_ operation: String) async -> FocusedWindowSnapshot? {
        for attempt in 0..<4 {
            if case .success(let snapshot) = axClient.focusedWindowSnapshot() {
                activeSpaceFocusRecoveryDeadline = nil
                return snapshot
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        return nil
    }

    @MainActor
    private func waitForFocusedLayoutContextAfterSpaceChange(
        operation: String,
        initialError: AXClientError
    ) async -> FocusedLayoutContext? {
        guard let deadline = activeSpaceFocusRecoveryDeadline,
              Date() < deadline
        else { return nil }

        reporter.info("\(operation) waiting for focused window after Space transition: \(initialError.description)")
        var nextRefresh = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            if case .success(let snapshot) = axClient.focusedWindowSnapshot() {
                activeSpaceFocusRecoveryDeadline = nil
                return FocusedLayoutContext(metadata: snapshot.metadata, displays: displayClient.currentDisplays())
            }

            let displays = displayClient.currentDisplays()
            if let fallback = await worldActor.focusedWindowFallback() {
                reporter.info("\(operation) recovered stored focused-window fallback \(fallback.id.description) after Space transition")
                return FocusedLayoutContext(metadata: fallback, displays: displays)
            }
            if Date() >= nextRefresh {
                _ = await refreshEnvironmentLocked(
                    reason: "\(operation.lowercased()) focus recovery",
                    displays: displays,
                    reconciliationMode: .observeOnly
                )
                nextRefresh = Date().addingTimeInterval(0.45)
            }

            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch is CancellationError {
                activeSpaceFocusRecoveryDeadline = nil
                return nil
            } catch {
                activeSpaceFocusRecoveryDeadline = nil
                return nil
            }
        }

        activeSpaceFocusRecoveryDeadline = nil
        return nil
    }

    @MainActor
    private func focusedWindowReadError() -> AXClientError {
        switch axClient.focusedWindowSnapshot() {
        case .success:
            return .missingFocusedWindow
        case .failure(let value):
            return value
        }
    }

    @MainActor
    func displayForFocusedWindow(_ context: FocusedLayoutContext, operation: String) -> DisplayID? {
        guard let displayID = displayClient.displayContaining(frame: context.frame, displays: context.displays) else {
            reporter.error("\(operation) failed: no display for focused window")
            showOperatorFeedback("\(operation) failed: no display for focus", tone: .error)
            return nil
        }
        reporter.info("\(operation) selected display \(displayID.raw)")
        return displayID
    }

    @MainActor
    func prepareLayoutWorld(
        _ context: FocusedLayoutContext,
        displayID: DisplayID,
        operation: String,
        refreshReason: String
    ) async -> Bool {
        let environment = await refreshEnvironmentLocked(
            reason: refreshReason,
            displays: context.displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("\(operation) rejected before planning: active Space unavailable")
            showOperatorFeedback("\(operation) failed: active Space unavailable", tone: .error)
            return false
        }

        switch await worldActor.upsertWindow(context.metadata, displayID: displayID, displays: context.displays) {
        case .success:
            return true
        case .failure(let error):
            reporter.error("\(operation) failed updating focused window state: \(error.message)")
            showOperatorFeedback("\(operation) failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    func applyPlannedPush(_ result: CommandPlanResult, direction: Direction, retryOnClamp: Bool) async -> Bool {
        guard let focusedWindowID = result.focusedWindowID else {
            reporter.error("Push \(direction.rawValue) cannot retry or commit without a focused window")
            return false
        }
        return await applyPlannedLayout(
            result,
            operation: "Push \(direction.rawValue)",
            persistReason: "push \(direction.rawValue)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planPush(focusedWindowID, direction: direction)
        }
    }

    @MainActor
    func applyPlannedDrop(
        _ result: CommandPlanResult,
        windowID: WindowID,
        displayID: DisplayID,
        zoneID: ZoneID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Drag drop \(zoneID.raw)",
            persistReason: "drag \(zoneID.raw)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planDrop(windowID: windowID, displayID: displayID, zoneID: zoneID)
        }
    }

    @MainActor
    func applyPlannedCenter(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Center",
            persistReason: "center",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planCenter(windowID)
        }
    }

    @MainActor
    func applyPlannedEject(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Eject",
            persistReason: "eject",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planEject(windowID)
        }
    }

    @MainActor
    func applyPlannedToggleFloat(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Toggle float",
            persistReason: "toggle float",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planToggleFloat(windowID)
        }
    }

    @MainActor
    func applyPlannedSwap(
        _ result: CommandPlanResult,
        windowID: WindowID,
        direction: Direction,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Swap \(direction.rawValue)",
            persistReason: "swap \(direction.rawValue)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planSwap(windowID, direction: direction)
        }
    }

    @MainActor
    func applyPlannedResize(
        _ result: CommandPlanResult,
        windowID: WindowID,
        direction: Direction,
        deltas: [Double],
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Resize \(direction.rawValue) \(deltas)",
            persistReason: "resize \(direction.rawValue) \(deltas)",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planResizeSequence(windowID, direction: direction, deltas: deltas)
        }
    }

    @MainActor
    func applyPlannedMoveToNextDisplay(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Move display",
            persistReason: "move display",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planMoveToNextDisplay(windowID)
        }
    }

    @MainActor
    func applyPlannedShuffle(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Shuffle",
            persistReason: "shuffle",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planShuffleActiveSpace()
        }
    }

    @MainActor
    func applyPlannedCascade(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Cascade",
            persistReason: "cascade",
            retryOnClamp: retryOnClamp
        ) {
            await self.worldActor.planCascadeActiveSpace()
        }
    }

    @MainActor
    func applyPlannedMaximizeReset(
        _ result: CommandPlanResult,
        windowID: WindowID,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Max reset",
            persistReason: "max reset",
            retryOnClamp: retryOnClamp,
            showFocusBorder: false
        ) {
            await self.worldActor.planMaximizeReset(windowID)
        }
    }

    @MainActor
    func applyPlannedUndo(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Undo",
            persistReason: "undo",
            retryOnClamp: retryOnClamp
        ) {
            await self.requireUndoLayoutPlan()
        }
    }

    @MainActor
    func applyPlannedRedo(_ result: CommandPlanResult, retryOnClamp: Bool) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Redo",
            persistReason: "redo",
            retryOnClamp: retryOnClamp
        ) {
            await self.requireRedoLayoutPlan()
        }
    }

    @MainActor
    func applyPlannedPendingTileRules(
        _ result: CommandPlanResult,
        reason: String,
        retryOnClamp: Bool
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: "Open rules",
            persistReason: "open rules \(reason)",
            retryOnClamp: retryOnClamp
        ) {
            await self.requirePendingTileRulePlan()
        }
    }

    private func requireUndoLayoutPlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planUndoLastLayout() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.configInvalid("nothing to undo"))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func requireRedoLayoutPlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planRedoLastLayout() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.configInvalid("nothing to redo"))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func requirePendingTileRulePlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planPendingTileRules() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.configInvalid("no pending tile rule"))
        case .failure(let error):
            return .failure(error)
        }
    }

    func replanExternalGeometryAfterClamp(
        _ result: CommandPlanResult
    ) async -> Result<CommandPlanResult, CommandError> {
        await worldActor.replanExternalGeometryAfterClamp(result)
    }

    @MainActor
    func applyPlannedBalance(
        _ result: CommandPlanResult,
        operation: String,
        persistReason: String,
        retryOnClamp: Bool,
        replanAfterClamp: @escaping () async -> Result<CommandPlanResult, CommandError>
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: operation,
            persistReason: persistReason,
            retryOnClamp: retryOnClamp
        ) { await replanAfterClamp() }
    }

    @MainActor
    func applyPlannedLayout(
        _ result: CommandPlanResult,
        operation: String,
        persistReason: String,
        retryOnClamp: Bool,
        showFocusBorder: Bool = true,
        preserving preservedFrames: [WindowID: CGRect] = [:],
        replanAfterClamp: @escaping @MainActor () async -> Result<CommandPlanResult, CommandError>
    ) async -> Bool {
        let affectedWindowIDs = layoutTransactionAffectedWindowIDs(result)
        let sourceFocus = await liveSourceFocusTarget(
            for: result,
            showFocusBorder: showFocusBorder
        )
        layoutPresentationCoordinator.begin(
            affectedWindowIDs: affectedWindowIDs,
            source: sourceFocus
        )

        let spaceChangesAtStart = activeSpaceChangeCount
        let outcome = await layoutTransactionCoordinator.execute(
            initialPlan: result,
            operation: operation,
            retryOnConstraint: retryOnClamp,
            preserving: preservedFrames,
            environmentUnchanged: { [weak self] in
                self?.activeSpaceChangeCount == spaceChangesAtStart
            },
            replan: replanAfterClamp,
            reconcileLiveWorld: {
                await self.refreshEnvironmentLocked(
                    reason: "reconcile \(operation.lowercased())",
                    reconciliationMode: .observeOnly
                )
            }
        )
        switch outcome {
        case .committed(let commit):
            let presentationCommit = LayoutTransactionCommit(
                appliedFrames: commit.appliedFrames,
                focusUpdate: showFocusBorder ? commit.focusUpdate : nil,
                affectedWorkspaces: commit.affectedWorkspaces
            )
            layoutPresentationCoordinator.committed(
                presentationCommit,
                windows: result.windows
            )
            if !showFocusBorder,
               case .target(let focusedWindowID, let frame) = commit.focusUpdate {
                suppressFocusBorder(for: focusedWindowID, frame: frame)
            }
            reporter.info("\(operation) completed")
            await refreshWorkspacePresentationSurfaces()
            showOperatorFeedback("\(operation) completed", tone: .success, showsHUD: false)
            await persistRestore(reason: persistReason)
            return true

        case .failed(_, let reason, let restoredFrames):
            layoutPresentationCoordinator.rolledBack(
                frames: restoredFrames,
                windows: result.windows
            )
            await refreshWorkspacePresentationSurfaces()
            reporter.error("\(operation) failed; live frames were restored: \(reason)")
            showOperatorFeedback("\(operation) failed; layout restored", tone: .error)
            return false

        case .reconciliationRequired(_, let reason):
            layoutPresentationCoordinator.reconciliationRequired(
                affectedWindowIDs: affectedWindowIDs
            )
            await refreshWorkspacePresentationSurfaces()
            reporter.error("\(operation) requires workspace reconciliation: \(reason)")
            showOperatorFeedback("\(operation) needs layout refresh", tone: .error)
            return false
        }
    }

    @MainActor
    private func liveSourceFocusTarget(
        for result: CommandPlanResult,
        showFocusBorder: Bool
    ) async -> FocusBorderTarget? {
        guard showFocusBorder,
              let windowID = result.focusedWindowID,
              let window = result.windows[windowID]
        else { return nil }

        switch await WindowFrameWriter(axClient: axClient).readFrame(window) {
        case .success(let readback)
            where readback.accessibility.narwhalApproximatelyEquals(
                readback.windowServer,
                tolerance: configuredGapTolerance
            ):
            return FocusBorderTarget(window: window, frame: readback.accessibility)
        case .success, .failure:
            return FocusBorderTarget(window: window, frame: window.frame)
        }
    }
}
