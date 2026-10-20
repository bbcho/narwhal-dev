import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    @MainActor
    func enqueueHotkey(_ action: HotkeyAction) {
        let maxPendingHotkeys = 32
        if pendingHotkeys.count >= maxPendingHotkeys {
            pendingHotkeys.removeFirst(pendingHotkeys.count - maxPendingHotkeys + 1)
            reporter.info("Hotkey queue trimmed to \(maxPendingHotkeys) pending action(s)")
        }
        pendingHotkeys.append(action)
        guard !isDrainingHotkeys else { return }
        isDrainingHotkeys = true
        Task { @MainActor in
            await self.drainHotkeyQueue()
        }
    }

    @MainActor
    private func drainHotkeyQueue() async {
        while !pendingHotkeys.isEmpty {
            guard let batch = nextHotkeyExecutionBatch(in: pendingHotkeys) else { break }
            pendingHotkeys.removeFirst(batch.consumedCount)
            // A modal confirmation inside the gate would block every other
            // workflow (AX events, drops, IPC) until the user answers.
            if batch.action == .command(.resetLayout), !confirmResetLayout() {
                showOperatorFeedback("Reset canceled", tone: .info)
                continue
            }
            await workspaceMutationGate.perform {
                await self.performHotkey(batch.action, resizeDeltas: batch.resizeDeltas)
            }
        }
        isDrainingHotkeys = false
    }

    @MainActor
    private func performHotkey(_ action: HotkeyAction, resizeDeltas: [Double] = []) async {
        if routeCommandOverlayHotkey(action) {
            return
        }

        reporter.info("Hotkey received: \(AppDelegateText.describe(action))")

        if isPaused, pausesTilingBlocks(action) {
            reporter.info("Hotkey ignored while Narwhal is paused: \(AppDelegateText.describe(action))")
            showOperatorFeedback("Narwhal paused", tone: .warning, showsHUD: false)
            return
        }

        guard await waitForStableWorkspaceIfNeeded(for: action) else {
            return
        }

        switch action {
        case .command(.push(let direction)):
            await performPush(direction)
        case .command(.center):
            await performCenter()
        case .command(.eject):
            await performEject()
        case .command(.toggleFloat):
            await performToggleFloat()
        case .command(.balance):
            await performBalance()
        case .command(.shuffle):
            await performShuffle()
        case .command(.cascade):
            await performCascade()
        case .command(.maximizeReset):
            await performMaximizeReset()
        case .command(.swap(let direction)):
            await performSwap(direction)
        case .command(.resizeSplit(let direction, let delta)):
            await performResize(direction, deltas: resizeDeltas.isEmpty ? [delta] : resizeDeltas)
        case .command(.focusDirection(let direction)):
            await performFocusDirection(direction)
        case .command(.focusCycle(let direction)):
            await performFocusCycle(direction)
        case .command(.focusPrevious):
            await performFocusPrevious()
        case .command(.undoLayout):
            await performUndoLayout()
        case .command(.redoLayout):
            await performRedoLayout()
        case .command(.moveToNextDisplay):
            await performMoveToNextDisplay()
        case .command(.moveToDesktop(let direction)):
            await performMoveToDesktop(direction)
        case .command(.togglePause):
            await togglePause()
        case .command(.resetLayout):
            // Confirmed in drainHotkeyQueue before entering the mutation gate.
            await performResetLayout(logPrefix: "Reset", persistReason: "reset")
        case .openFinderWindow:
            performOpenFinderWindow()
        case .command(let template):
            reporter.error("Hotkey action not implemented in this build: \(AppDelegateText.describe(template))")
            showOperatorFeedback("Command unavailable: \(AppDelegateText.describe(template))", tone: .error)
        case .reloadConfig:
            await reloadConfigLocked(reason: "hotkey")
        case .showCommands:
            overlay.toggleCommandOverlay(
                bindings: config.keymap,
                dragModifier: config.dragModifier,
                zones: config.zones
            )
        }
    }

    @MainActor
    private func waitForStableWorkspaceIfNeeded(for action: HotkeyAction) async -> Bool {
        guard workspaceStabilityPolicy(for: action) == .waitForStableWorkspace,
              spaceTransitionPreservation.isPreservingSpaceLayouts
        else { return true }

        let description = AppDelegateText.describe(action)
        reporter.info("Hotkey waiting for Space transition to settle: \(description)")
        let deadline = Date().addingTimeInterval(Self.activeSpaceTransitionPreserveDuration + 0.5)
        while spaceTransitionPreservation.isPreservingSpaceLayouts && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
        }
        guard !spaceTransitionPreservation.isPreservingSpaceLayouts else {
            reporter.error("Hotkey skipped because Space transition did not settle: \(description)")
            showOperatorFeedback("Space still settling", tone: .warning, showsHUD: false)
            return false
        }
        return true
    }

    private func pausesTilingBlocks(_ action: HotkeyAction) -> Bool {
        switch action {
        case .command(let template):
            switch template {
            case .push, .center, .eject, .swap, .resizeSplit, .toggleFloat, .balance, .shuffle, .cascade, .maximizeReset, .undoLayout, .redoLayout, .moveToNextDisplay, .moveToDesktop:
                return true
            case .focusDirection, .focusCycle, .focusPrevious, .togglePause, .resetLayout:
                return false
            }
        case .openFinderWindow, .reloadConfig, .showCommands:
            return false
        }
    }

    @MainActor
    private func routeCommandOverlayHotkey(_ action: HotkeyAction) -> Bool {
        guard overlay.isCommandOverlayVisible else { return false }
        switch action {
        case .showCommands:
            overlay.hideCommandOverlay()
            return true
        case .command(.focusDirection(.up)):
            overlay.scrollCommandOverlay(.up)
            return true
        case .command(.focusDirection(.down)):
            overlay.scrollCommandOverlay(.down)
            return true
        default:
            return false
        }
    }

    @MainActor
    private func performOpenFinderWindow() {
        do {
            try FinderWindowOpener.openHomeWindow()
            reporter.info("Opened Finder window")
            showOperatorFeedback("Finder window opened", tone: .success, showsHUD: false)
        } catch {
            reporter.error("Open Finder window failed: \(String(describing: error))")
            showOperatorFeedback("Open Finder failed", tone: .error)
        }
    }

    @MainActor
    @discardableResult
    func performResetLayout(logPrefix: String, persistReason: String) async -> Bool {
        switch await worldActor.planResetLayoutMemory() {
        case .success(let result):
            let completed = await applyPlannedLayout(
                result,
                operation: logPrefix,
                persistReason: persistReason,
                retryOnClamp: false,
                showFocusBorder: false
            ) {
                await self.worldActor.planResetLayoutMemory()
            }
            if completed {
                reporter.info("\(logPrefix) layout memory cleared for the active Space; undo remains available")
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
            return completed
        case .failure(let error):
            reporter.error("\(logPrefix) rejected: \(error.message)")
            showOperatorFeedback("Reset failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    private func confirmResetLayout() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset Narwhal layout memory?"
        alert.informativeText = "This clears tracked tiling state, floating order, focus memory, pending rules, and observed window minimums for the active Space. You can undo it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    @discardableResult
    private func performUndoLayout() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Undo skipped because Accessibility is not trusted")
            showOperatorFeedback("Undo failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironmentLocked(
            reason: "pre-undo",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Undo rejected before planning: active Space unavailable")
            showOperatorFeedback("Undo failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Undo rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Undo failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planUndoLastLayout() {
        case .success(nil):
            reporter.info("Undo skipped: no previous layout")
            showOperatorFeedback("Nothing to undo", tone: .warning, showsHUD: false)
            return false
        case .success(let result?):
            return await applyPlannedUndo(result, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Undo rejected by core: \(error.message)")
            showOperatorFeedback("Undo failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performRedoLayout() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Redo skipped because Accessibility is not trusted")
            showOperatorFeedback("Redo failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironmentLocked(reason: "pre-redo", reconciliationMode: .observeOnly)
        guard environment.activeSpace != nil else {
            reporter.error("Redo rejected before planning: active Space unavailable")
            showOperatorFeedback("Redo failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Redo rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Redo failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planRedoLastLayout() {
        case .success(nil):
            reporter.info("Redo skipped: no later layout")
            showOperatorFeedback("Nothing to redo", tone: .warning, showsHUD: false)
            return false
        case .success(let result?):
            return await applyPlannedRedo(result, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Redo rejected by core: \(error.message)")
            showOperatorFeedback("Redo failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func performPush(_ direction: Direction) async -> Bool {
        let operation = "Push \(direction.rawValue)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-push \(direction.rawValue)")
        else { return false }

        switch await worldActor.planPush(context.id, direction: direction) {
        case .success(let result):
            return await applyPlannedPush(result, direction: direction, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Push \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Push failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performCenter() async -> Bool {
        let operation = "Center"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-center")
        else { return false }

        switch await worldActor.planCenter(context.id) {
        case .success(let result):
            return await applyPlannedCenter(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Center rejected by core: \(error.message)")
            showOperatorFeedback("Center failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performEject() async -> Bool {
        let operation = "Eject"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-eject")
        else { return false }

        switch await worldActor.planEject(context.id) {
        case .success(let result):
            return await applyPlannedEject(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Eject rejected by core: \(error.message)")
            showOperatorFeedback("Eject failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performToggleFloat() async -> Bool {
        let operation = "Toggle float"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-toggle-float")
        else { return false }

        switch await worldActor.planToggleFloat(context.id) {
        case .success(let result):
            return await applyPlannedToggleFloat(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Toggle float rejected by core: \(error.message)")
            showOperatorFeedback("Toggle float failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func performSwap(_ direction: Direction) async -> Bool {
        let operation = "Swap \(direction.rawValue)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-swap \(direction.rawValue)")
        else { return false }

        switch await worldActor.planSwap(context.id, direction: direction) {
        case .success(let result):
            return await applyPlannedSwap(result, windowID: context.id, direction: direction, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Swap \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Swap failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func performResize(_ direction: Direction, delta: Double) async -> Bool {
        await performResize(direction, deltas: [delta])
    }

    @MainActor
    @discardableResult
    func performResize(_ direction: Direction, deltas: [Double]) async -> Bool {
        let operation = "Resize \(direction.rawValue) \(deltas)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-resize \(direction.rawValue)")
        else { return false }

        switch await worldActor.planResizeSequence(context.id, direction: direction, deltas: deltas) {
        case .success(let result):
            return await applyPlannedResize(
                result,
                windowID: context.id,
                direction: direction,
                deltas: deltas,
                retryOnClamp: true
            )
        case .failure(let error):
            reporter.error("Resize \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Resize failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performMoveToNextDisplay() async -> Bool {
        let operation = "Move display"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-move-display")
        else { return false }

        switch await worldActor.planMoveToNextDisplay(context.id) {
        case .success(let result):
            return await applyPlannedMoveToNextDisplay(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Move display rejected by core: \(error.message)")
            showOperatorFeedback("Move display failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performMoveToDesktop(_ direction: DesktopMoveDirection) async -> Bool {
        let operation = "Move desktop \(direction.rawValue)"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              let display = context.displays[displayID]
        else { return false }

        let plan: DesktopWindowMovePlan
        switch await desktopWindowMover.plan(
            window: context.metadata,
            direction: direction,
            display: display,
            displays: context.displays
        ) {
        case .success(let value):
            plan = value
        case .failure(let error):
            reporter.error("\(operation) preflight failed: \(error.description)")
            showOperatorFeedback("Move desktop failed: \(error.description)", tone: .error)
            return false
        }

        guard await prepareLayoutWorld(
            context,
            displayID: displayID,
            operation: operation,
            refreshReason: "pre-move-desktop-\(direction.rawValue)"
        ) else { return false }

        switch await worldActor.planEject(context.id) {
        case .success(let result):
            guard await applyPlannedEject(result, windowID: context.id, retryOnClamp: true) else {
                return false
            }
        case .failure(let error):
            reporter.error("\(operation) could not float the focused window: \(error.message)")
            showOperatorFeedback("Move desktop failed: \(error.message)", tone: .error)
            return false
        }

        switch await desktopWindowMover.execute(plan) {
        case .success:
            reporter.info(
                "Moved \(context.id.description) from desktop \(plan.sourceSpace.raw) "
                    + "to \(plan.destinationSpace.raw) as floating"
            )
            showOperatorFeedback("Moved to desktop \(direction.rawValue)", tone: .success)
            return true
        case .failure(let error):
            _ = spaceClient.switchActiveSpace(display: display, to: plan.sourceSpace)
            reporter.error("\(operation) failed: \(error.description)")
            showOperatorFeedback("Move desktop failed: \(error.description)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performBalance() async -> Bool {
        let operation = "Balance"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation)
        else { return false }
        guard await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-balance") else {
            return false
        }

        switch await worldActor.planBalanceWorkspace(containing: context.id) {
        case .success(let result):
            return await applyPlannedBalance(
                result,
                operation: operation,
                persistReason: "balance",
                retryOnClamp: true
            ) {
                await self.worldActor.planBalanceWorkspace(containing: context.id)
            }
        case .failure(let error):
            reporter.error("Balance rejected by core: \(error.message)")
            showOperatorFeedback("Balance failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performShuffle() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Shuffle skipped because Accessibility is not trusted")
            showOperatorFeedback("Shuffle failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironmentLocked(
            reason: "pre-shuffle",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Shuffle rejected before planning: active Space unavailable")
            showOperatorFeedback("Shuffle failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Shuffle rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Shuffle failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planShuffleActiveSpace() {
        case .success(let result):
            let completed = await applyPlannedShuffle(result, retryOnClamp: true)
            if completed {
                setFocusBorder(nil)
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
            return completed
        case .failure(let error):
            reporter.error("Shuffle rejected by core: \(error.message)")
            showOperatorFeedback("Shuffle failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performCascade() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Cascade skipped because Accessibility is not trusted")
            showOperatorFeedback("Cascade failed: Accessibility not trusted", tone: .error)
            return false
        }

        let environment = await refreshEnvironmentLocked(
            reason: "pre-cascade",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Cascade rejected before planning: active Space unavailable")
            showOperatorFeedback("Cascade failed: active Space unavailable", tone: .error)
            return false
        }
        guard case .complete = environment.quality else {
            reporter.error("Cascade rejected before planning: environment snapshot is \(AppDelegateText.describe(environment.quality))")
            showOperatorFeedback("Cascade failed: incomplete snapshot", tone: .error)
            return false
        }

        switch await worldActor.planCascadeActiveSpace() {
        case .success(let result):
            let completed = await applyPlannedCascade(result, retryOnClamp: true)
            if completed {
                setFocusBorder(nil)
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
            return completed
        case .failure(let error):
            reporter.error("Cascade rejected by core: \(error.message)")
            showOperatorFeedback("Cascade failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    private func performMaximizeReset() async -> Bool {
        let operation = "Max reset"
        guard let context = await focusedLayoutContext(operation: operation),
              let displayID = displayForFocusedWindow(context, operation: operation),
              await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-max-reset")
        else { return false }

        switch await worldActor.planMaximizeReset(context.id) {
        case .success(let result):
            return await applyPlannedMaximizeReset(result, windowID: context.id, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Max reset rejected by core: \(error.message)")
            showOperatorFeedback("Max reset failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    private func togglePause() async {
        isPaused.toggle()
        updateOperatingStatus { $0.paused = isPaused }
        reporter.info(isPaused ? "Narwhal paused" : "Narwhal resumed")
        showOperatorFeedback(isPaused ? "Narwhal paused" : "Narwhal resumed", tone: isPaused ? .warning : .success)
        if isPaused {
            overlay.hideDragPreview()
        } else {
            await applyPendingTileRulesLocked(reason: "resume")
        }
    }
}
