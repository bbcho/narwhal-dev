import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    @discardableResult
    @MainActor
    func refreshEnvironmentLocked(
        reason: String,
        displays providedDisplays: [DisplayID: DisplayInfo]? = nil,
        preserveSpaceLayouts: Bool = false,
        reconciliationMode: EnvironmentReconciliationMode = .activeWorkspaceCleanup
    ) async -> EnvironmentRefreshResult {
        let displays = providedDisplays ?? displayClient.currentDisplays()
        let axSnapshot = await includingParkedWindows(axClient.windowSnapshot())
        let topology = spaceClient.spaceTopology(displays: displays, windows: axSnapshot.windows)
        let activeSpace: SpaceID?
        switch spaceClient.activeSpaceID() {
        case .success(let spaceID):
            activeSpace = spaceID
        case .failure(let error):
            activeSpace = topology.primaryActiveSpace
            if activeSpace == nil {
                reporter.error("Active Space refresh failed (\(reason)): \(error.description)")
            }
        }
        let snapshot = EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: displays,
            axSnapshot: axSnapshot,
            spaceTopology: topology,
            preserveSpaceLayouts: preserveSpaceLayouts,
            reconciliationMode: preserveSpaceLayouts ? .preserveLayouts : reconciliationMode
        )
        let result = await worldActor.refreshEnvironment(snapshot)
        let preserved = result.preservedSpaceLayouts ? " preservedSpaceLayouts=true" : ""
        reporter.info(
            "Environment refreshed (\(reason)): activeSpace=\(result.activeSpace?.raw.description ?? "nil") displays=\(result.displayCount) windows=\(result.windowCount) quality=\(AppDelegateText.describe(result.quality)) topology=\(topology.quality.rawValue) mode=\(snapshot.reconciliationMode.rawValue) mapped=\(result.mappedWindowCount)/\(result.observedWindowCount) spaceWindows=\(topology.windowSpace.count)\(preserved)"
        )
        updateOperatingStatus { status in
            status.activeSpace = result.activeSpace
            status.displayCount = result.displayCount
            status.windowCount = result.windowCount
            status.snapshotQuality = result.quality
        }
        await updateTiledBordersFromWorld()
        await refreshWorkspacePresentationSurfaces()
        return result
    }

    /// The on-screen snapshot omits minimized and hidden windows; adding the
    /// parked ones that still exist keeps reconciliation from pruning their slots.
    @MainActor
    private func includingParkedWindows(_ snapshot: AXWindowSnapshot) async -> AXWindowSnapshot {
        let parked = await worldActor.minimizedWindows()
        guard !parked.isEmpty, let existing = axClient.existingWindowIDs() else { return snapshot }
        let onScreen = Set(snapshot.windows.map(\.id))
        let stillParked = parked.filter { existing.contains($0.id) && !onScreen.contains($0.id) }
        return AXWindowSnapshot(
            windows: (snapshot.windows + stillParked).sorted { $0.id.raw < $1.id.raw },
            quality: snapshot.quality
        )
    }

    @MainActor
    func handleAXEvent(_ event: AXEvent, snapshot: FocusedWindowSnapshot?) async {
        if externalGeometryWindowID(for: event) != nil {
            externalGeometryCoordinator.observe(event, snapshot: snapshot)
            return
        }
        await workspaceMutationGate.perform {
            await self.handleAXEventLocked(event, snapshot: snapshot)
        }
    }

    @MainActor
    private func handleAXEventLocked(_ event: AXEvent, snapshot: FocusedWindowSnapshot?) async {
        switch event {
        case .windowFocused(let windowID):
            activeSpaceFocusRecoveryDeadline = nil
            await worldActor.recordExternalFocus(windowID)
            updateOperatingStatus { $0.focusedWindowID = windowID }
            if let snapshot {
                updateFocusBorder(for: snapshot)
            }
            await updateTiledBordersFromWorld()
        case .windowMoved, .windowResized:
            break
        case .windowOpened(let metadata):
            if await worldActor.windows([metadata.id]).first?.isMinimized == true {
                await worldActor.setMinimized([metadata.id], false)
                scheduleCoalescedEnvironmentRefresh(.windowRestored(metadata.id))
            } else {
                scheduleCoalescedEnvironmentRefresh(.windowOpened(metadata.id))
            }
        case .windowClosed(let windowID):
            if await vanishedWindowFates([windowID])[windowID] == .parked {
                await parkWindows([windowID])
                return
            }
            await removeClosedWindow(windowID)
            scheduleCoalescedEnvironmentRefresh(.windowClosed(windowID))
        }
    }

    @MainActor
    func handleVanishedWindows(_ windowIDs: Set<WindowID>) async {
        await workspaceMutationGate.perform {
            let fates = await self.vanishedWindowFates(windowIDs)
            let parked = Set(fates.filter { $0.value == .parked }.keys)
            let closed = fates.filter { $0.value == .closed }.keys.sorted { $0.raw < $1.raw }
            if !parked.isEmpty {
                self.reporter.info("Parked \(parked.count) minimized or hidden window(s) from a bulk disappearance")
                await self.parkWindows(parked)
            }
            for windowID in closed {
                await self.removeClosedWindow(windowID)
            }
            if !closed.isEmpty {
                self.reporter.info("Removed \(closed.count) closed window(s) from a bulk disappearance")
                // The Space-change refresh that follows preserves layouts and does not save.
                await self.persistRestore(reason: "closed windows")
            }
        }
    }

    /// Classifies windows that left the screen: closed, minimized or hidden
    /// (kept in their slot), or simply elsewhere such as another Space.
    @MainActor
    private func vanishedWindowFates(_ windowIDs: Set<WindowID>) async -> [WindowID: VanishedWindowFate] {
        let existing = axClient.existingWindowIDs()
        let candidates = await worldActor.windows(windowIDs).filter { existing?.contains($0.id) == true }
        let minimizedOrHidden = axClient.minimizedOrHiddenWindowIDs(among: candidates)
        return Dictionary(uniqueKeysWithValues: windowIDs.map { windowID in
            (windowID, vanishedWindowFate(
                windowID,
                existingWindowIDs: existing,
                isMinimizedOrHidden: minimizedOrHidden.contains(windowID)
            ))
        })
    }

    /// A minimized window or a hidden app's window keeps its tile slot as a gap
    /// and returns to it when it reappears.
    @MainActor
    private func parkWindows(_ windowIDs: Set<WindowID>) async {
        await worldActor.setMinimized(windowIDs, true)
        for windowID in windowIDs {
            externalGeometryCoordinator.cancel(windowID: windowID)
            removeWindowFromOverlays(windowID)
            if operatingStatus.focusedWindowID == windowID {
                updateOperatingStatus { $0.focusedWindowID = nil }
            }
        }
        await updateTiledBordersFromWorld()
    }

    @MainActor
    private func removeClosedWindow(_ windowID: WindowID) async {
        externalGeometryCoordinator.cancel(windowID: windowID)
        await worldActor.removeWindowFromActiveSpace(windowID)
        removeWindowFromOverlays(windowID)
        if operatingStatus.focusedWindowID == windowID {
            updateOperatingStatus { $0.focusedWindowID = nil }
        }
        await updateTiledBordersFromWorld()
    }

    @MainActor
    func handleSettledExternalGeometryEvent(
        _ event: AXEvent,
        snapshot: FocusedWindowSnapshot?
    ) async {
        await workspaceMutationGate.perform {
            let windowID = externalGeometryWindowID(for: event)
            if let windowID {
                await worldActor.setWindowInteraction(.manualAdjustment, for: windowID)
                await refreshWorkspacePresentationSurfaces()
            }
            let resolvedInteraction = await processExternalGeometryEvent(
                event,
                snapshot: snapshot
            )
            if let windowID {
                await worldActor.setWindowInteraction(resolvedInteraction, for: windowID)
                await refreshWorkspacePresentationSurfaces()
            }
        }
    }

    @MainActor
    private func processExternalGeometryEvent(
        _ event: AXEvent,
        snapshot: FocusedWindowSnapshot?
    ) async -> WindowInteractionState? {
        let metricInterval = runtimeMetrics.begin(.manualResizeHandoff)
        defer { runtimeMetrics.end(metricInterval) }
        let selectedEvent = externalGeometryEventSelection(
            for: event,
            liveSnapshot: axClient.windowSnapshot(),
            tolerance: Self.externalGeometryEventTolerance
        )
        if selectedEvent.usedLiveFrame {
            reporter.info("External geometry event converged to settled live frame")
        }

        switch await worldActor.planExternalGeometry(selectedEvent.event) {
        case .success(let result?):
            let preservedFrames = preservedExternalGeometryFrames(
                selection: selectedEvent,
                plan: result
            )
            let completed = await applyPlannedLayout(
                result,
                operation: "Manual resize",
                persistReason: "manual resize",
                retryOnClamp: true,
                showFocusBorder: snapshot != nil,
                preserving: preservedFrames
            ) {
                await self.replanExternalGeometryAfterClamp(result)
            }
            if let snapshot {
                await updateFocusBorderFromWorld(windowID: snapshot.id)
            }
            if !completed {
                let snappedBack = await snapBackAfterRejectedManualGeometry(selectedEvent)
                await updateTiledBordersFromWorld()
                return snappedBack ? nil : .temporarilyDetached(.applicationConstraint)
            }
            return nil
        case .success(nil):
            if let snapshot {
                await updateFocusBorderFromWorld(windowID: snapshot.id)
            }
            await updateTiledBordersFromWorld()
            return nil
        case .failure(let error):
            reporter.error("External geometry rejected by core: \(error.message)")
            await worldActor.recordExternalGeometry(selectedEvent.event)
            if let snapshot {
                await updateFocusBorderFromWorld(windowID: snapshot.id)
            }
            await updateTiledBordersFromWorld()
            return .temporarilyDetached(.userMoved)
        }
    }

    /// A rejected manual resize leaves the tree as it was; write the dragged
    /// window back to its tile instead of recording a seam its neighbors never took.
    @MainActor
    private func snapBackAfterRejectedManualGeometry(_ selection: ExternalGeometryEventSelection) async -> Bool {
        guard let windowID = externalGeometryWindowID(for: selection.event) else { return false }
        switch await worldActor.planSnapBack(windowID, observedFrame: selection.liveFrame) {
        case .success(let plan?):
            return await applyPlannedLayout(
                plan,
                operation: "Snap back",
                persistReason: "snap back",
                retryOnClamp: false
            ) {
                .success(plan)
            }
        case .success(nil):
            return true
        case .failure(let error):
            reporter.error("Snap back rejected by core: \(error.message)")
            return false
        }
    }

    @MainActor
    func scheduleCoalescedEnvironmentRefresh(_ reason: EnvironmentRefreshReason) {
        let scheduled = scheduleEnvironmentRefresh(reason, in: environmentRefreshCoalescer)
        environmentRefreshCoalescer = scheduled.state

        environmentRefreshCoalescingTimer?.invalidate()
        let generation = scheduled.request.generation
        let timer = Timer(timeInterval: Self.environmentRefreshCoalescingDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.runCoalescedEnvironmentRefresh(generation: generation)
            }
        }
        environmentRefreshCoalescingTimer = timer
        environmentRefreshCoalescingTimerGeneration = generation
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    func activeSpaceChanged() {
        activeSpaceChangeCount += 1
        externalGeometryCoordinator.cancelAll()
        cancelSpaceTransitionTimers()
        let preservation = beginSpaceTransitionPreservation(
            in: spaceTransitionPreservation,
            settledRefreshDelays: Self.activeSpaceSettledRefreshDelays,
            preserveEndDelay: Self.activeSpaceTransitionPreserveDuration
        )
        spaceTransitionPreservation = preservation.state
        activeSpaceFocusRecoveryDeadline = Date().addingTimeInterval(Self.activeSpaceFocusRecoveryDuration)
        clearBorderOverlays()
        scheduleCoalescedEnvironmentRefresh(.spaceSettled)
        preservation.settledRefreshDelays.forEach { delay in
            scheduleDelayedSpaceSettledRefresh(after: delay)
        }
        scheduleSpaceTransitionPreserveEnd(
            after: preservation.preserveEndDelay,
            generation: preservation.generation
        )
    }

    @MainActor
    private func scheduleDelayedSpaceSettledRefresh(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                self?.spaceSettledRefreshTimers.removeAll { $0 === timer }
                self?.scheduleCoalescedEnvironmentRefresh(.spaceSettled)
            }
        }
        spaceSettledRefreshTimers.append(timer)
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func scheduleDelayedDisplaySettledRefresh(after delay: TimeInterval) {
        cancelDisplaySettledRefreshTimer()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                guard self?.displaySettledRefreshTimer === timer else { return }
                self?.displaySettledRefreshTimer = nil
                self?.scheduleCoalescedEnvironmentRefresh(.displaySettled)
            }
        }
        displaySettledRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func scheduleSpaceTransitionPreserveEnd(after delay: TimeInterval, generation: UInt64) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                guard self?.spaceTransitionPreserveTimer === timer else { return }
                self?.spaceTransitionPreserveTimer = nil
                guard let self else { return }
                let completion = completeSpaceTransitionPreservation(
                    generation: generation,
                    in: self.spaceTransitionPreservation
                )
                self.spaceTransitionPreservation = completion.state
                guard completion.decision == .scheduleRefresh else { return }
                self.scheduleCoalescedEnvironmentRefresh(.spaceTransitionEnded)
            }
        }
        spaceTransitionPreserveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    func cancelSpaceTransitionTimers() {
        spaceSettledRefreshTimers.forEach { $0.invalidate() }
        spaceSettledRefreshTimers.removeAll()
        spaceTransitionPreserveTimer?.invalidate()
        spaceTransitionPreserveTimer = nil
        spaceTransitionPreservation = cancelSpaceTransitionPreservation(in: spaceTransitionPreservation)
    }

    @MainActor
    func cancelDisplaySettledRefreshTimer() {
        displaySettledRefreshTimer?.invalidate()
        displaySettledRefreshTimer = nil
    }

    @MainActor
    private func runCoalescedEnvironmentRefresh(generation: UInt64) async {
        await workspaceMutationGate.perform {
            await self.runCoalescedEnvironmentRefreshLocked(generation: generation)
        }
    }

    @MainActor
    private func runCoalescedEnvironmentRefreshLocked(generation: UInt64) async {
        if environmentRefreshCoalescingTimerGeneration == generation {
            environmentRefreshCoalescingTimer?.invalidate()
            environmentRefreshCoalescingTimer = nil
            environmentRefreshCoalescingTimerGeneration = nil
        }

        let fired = fireEnvironmentRefreshTimer(generation: generation, in: environmentRefreshCoalescer)
        environmentRefreshCoalescer = fired.state
        guard case .run(let request) = fired.decision else { return }

        let policy = environmentRefreshPolicy(
            for: request.reasons,
            duringSpaceTransition: spaceTransitionPreservation.isPreservingSpaceLayouts
        )
        let environment = await refreshEnvironmentLocked(
            reason: "coalesced \(request.description)",
            preserveSpaceLayouts: policy.preserveSpaceLayouts,
            reconciliationMode: policy.reconciliationMode
        )
        let completed: Bool
        if case .complete = environment.quality {
            completed = true
        } else {
            completed = false
        }

        let completion = completeEnvironmentRefresh(
            generation: request.generation,
            snapshotComplete: completed,
            in: environmentRefreshCoalescer
        )
        environmentRefreshCoalescer = completion.state
        switch completion.decision {
        case .cleared(let completedRequest):
            if completed,
               !spaceTransitionPreservation.isPreservingSpaceLayouts,
               await worldActor.restoreVisibleDeferredSpaces() {
                reporter.info("Restored a saved Space layout now that its Space is visible")
                await applySettledDisplayLayoutLocked(reason: "deferred Space restore")
            }
            if completed && policy.scheduleDeferredCleanup {
                scheduleDelayedDisplaySettledRefresh(after: Self.displaySettledRefreshDelay)
            }
            var appliedPendingTileRules = false
            if completed && policy.applyPendingTileRules && !environment.preservedSpaceLayouts {
                appliedPendingTileRules = await applyPendingTileRulesLocked(
                    reason: "coalesced \(completedRequest.description)"
                )
            }
            if completed
                && policy.reflowTiledLayout
                && !environment.preservedSpaceLayouts
                && !appliedPendingTileRules
            {
                await applySettledDisplayLayoutLocked(reason: completedRequest.description)
            }
            if policy.persistRestore && !environment.preservedSpaceLayouts {
                await persistRestore(reason: "coalesced \(completedRequest.description)")
            }
        case .retained(let pending):
            reporter.info("Coalesced environment refresh retained pending generation \(pending.generation) after incomplete AX snapshot")
        case .stale, .idle:
            break
        }
    }

    @MainActor
    private func applySettledDisplayLayoutLocked(reason: String) async {
        guard !isPaused else {
            reporter.info("Display reflow deferred while paused (\(reason))")
            return
        }
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Display reflow requires Accessibility permission (\(reason))")
            return
        }

        switch await worldActor.planCurrentLayout() {
        case .success(nil):
            reporter.info("Display reflow completed with no tiled windows (\(reason))")
            await persistRestore(reason: "display topology")
        case .success(let result?):
            _ = await applyPlannedLayout(
                result,
                operation: "Display reflow",
                persistReason: "display topology",
                retryOnClamp: true,
                showFocusBorder: false
            ) {
                await self.currentLayoutRetryPlan()
            }
        case .failure(let error):
            reporter.error("Display reflow rejected by core (\(reason)): \(error.message)")
        }
    }

    func currentLayoutRetryPlan() async -> Result<CommandPlanResult, CommandError> {
        switch await worldActor.planCurrentLayout() {
        case .success(let result?):
            return .success(result)
        case .success(nil):
            return .failure(.activeSpaceUnavailable)
        case .failure(let error):
            return .failure(error)
        }
    }

    @MainActor
    @discardableResult
    func applyPendingTileRulesLocked(reason: String) async -> Bool {
        guard !isPaused else { return false }
        guard AccessibilityTrust.current(prompt: false).isTrusted else { return false }

        switch await worldActor.planPendingTileRules() {
        case .success(nil):
            return false
        case .success(let result?):
            return await applyPlannedPendingTileRules(result, reason: reason, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Open rules rejected by core (\(reason)): \(error.message)")
            showOperatorFeedback("Open rules failed: \(error.message)", tone: .error)
            return false
        }
    }

    func logDisplays(_ displays: [DisplayID: DisplayInfo]) {
        for (id, display) in displays.sorted(by: { $0.key.raw < $1.key.raw }) {
            reporter.info("Display \(id.raw) frame=\(display.frame.debugDescription) visible=\(display.visibleFrame.debugDescription)")
        }
    }
}
