import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

enum NamedLayoutPlanError: Error, Equatable, Sendable {
    case application(NamedLayoutApplicationError)
    case command(CommandError)
}

actor WorldActor {
    private var world: World
    private var nextGeneration: UInt64 = 1
    private var runtimeState = WorldRuntimeState.empty
    private var layoutHistory = LayoutHistoryState.empty
    private let runtimeMetrics: RuntimeMetrics?

    init(config: Config = .default, runtimeMetrics: RuntimeMetrics? = nil) {
        self.runtimeMetrics = runtimeMetrics
        self.world = World(
            displays: [:],
            activeSpace: nil,
            spaces: [:],
            windows: [:],
            windowDisplay: [:],
            observedVisibleWindows: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }

    func refreshEnvironment(_ snapshot: EnvironmentSnapshot) -> EnvironmentRefreshResult {
        let transition = environmentRefreshTransition(for: snapshot, in: world)
        world = transition.world
        pruneRuntimeState()
        return transition.result
    }

    func restore(_ stored: StoredWorld, from snapshot: EnvironmentSnapshot) -> Int {
        world = restoreWorld(
            from: stored,
            liveWindows: snapshot.axSnapshot.windows,
            displays: snapshot.displays,
            activeSpace: snapshot.activeSpace,
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: snapshot.activeSpaceByDisplay,
                windowSpace: snapshot.windowSpace,
                quality: snapshot.topologyQuality
            ),
            config: world.config
        )
        layoutHistory = .empty
        return world.spaces.values.reduce(0) { total, space in
            total + space.displays.values.reduce(0) { displayTotal, state in
                displayTotal + occupiedWindows(in: state.tree).count
            }
        }
    }

    func recordExternalFocus(_ windowID: WindowID) {
        guard case .success(let next) = apply(.windowFocusedExternally(windowID), to: world) else { return }
        recordFocus(windowID)
        world = next
    }

    func recordExternalGeometry(_ event: AXEvent) {
        switch event {
        case .windowMoved, .windowResized:
            guard case .success(let next) = apply(event.toCommand(), to: world) else { return }
            world = next
        case .windowOpened, .windowClosed, .windowFocused:
            return
        }
    }

    func setWindowInteraction(_ interaction: WindowInteractionState?, for windowID: WindowID) {
        runtimeState = worldRuntimeBySettingInteraction(interaction, for: windowID, in: runtimeState)
    }

    func planExternalGeometry(_ event: AXEvent) -> Result<CommandPlanResult?, CommandError> {
        switch event {
        case .windowMoved, .windowResized:
            break
        case .windowOpened, .windowClosed, .windowFocused:
            return .success(nil)
        }

        let oldWorld = world
        switch apply(event.toCommand(), to: oldWorld) {
        case .success(let newWorld):
            guard newWorld.spaces != oldWorld.spaces else {
                world = newWorld
                pruneRuntimeState()
                return .success(nil)
            }
            return recordingHistory(
                makePlan(
                from: oldWorld,
                to: newWorld,
                focusedWindowID: nil,
                undoWorld: oldWorld
                ),
                label: externalGeometryHistoryLabel(event),
                beforeWorld: oldWorld
            ).map(Optional.some)
        case .failure(let error):
            return .failure(error)
        }
    }

    func replanExternalGeometryAfterClamp(_ previous: CommandPlanResult) -> Result<CommandPlanResult, CommandError> {
        let constrainedWorld = worldByRecordingObservedConstraints(
            world.windowConstraints,
            in: previous.plannedWorld
        )
        return makePlan(
            from: world,
            to: constrainedWorld,
            focusedWindowID: nil,
            undoWorld: previous.undoWorld
        ).map { replanned in
            replanned.withHistoryAction(replannedHistoryAction(previous.historyAction, result: replanned))
        }
    }

    func reloadConfig(_ config: Config) {
        guard case .success(let next) = apply(.reloadConfig(config), to: world) else { return }
        world = next
    }

    func reconcileLiveWindows(_ liveWindowIDs: Set<WindowID>) {
        world = pruneActiveSpace(world, keepingLiveWindows: liveWindowIDs)
        pruneRuntimeState()
    }

    func focusedWindowFallback() -> WindowMetadata? {
        runtimeFocusedWindowFallback(in: world, runtime: runtimeState)
    }

    func removeWindowFromActiveSpace(_ windowID: WindowID) {
        world = removeWindowsFromActiveSpace([windowID], in: world)
        pruneRuntimeState()
    }

    func upsertWindow(
        _ metadata: WindowMetadata,
        displayID: DisplayID,
        displays: [DisplayID: DisplayInfo]
    ) -> Result<Void, CommandError> {
        switch worldByUpsertingActiveWindow(metadata, displayID: displayID, displays: displays, in: world) {
        case .success(let updated):
            world = updated
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func planPush(_ windowID: WindowID, direction: Direction) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.push(windowID, direction), focusedWindowID: windowID, historyLabel: "Push \(direction.rawValue)")
    }

    func planCenter(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.center(windowID), focusedWindowID: windowID, historyLabel: "Center")
    }

    func planEject(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.eject(windowID), focusedWindowID: windowID, historyLabel: "Eject")
    }

    func planToggleFloat(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.toggleFloat(windowID), focusedWindowID: windowID, historyLabel: "Toggle Float")
    }

    func planMoveToNextDisplay(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.moveToNextDisplay(windowID), focusedWindowID: windowID, historyLabel: "Move Display")
    }

    func planSwap(_ windowID: WindowID, direction: Direction) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.swapInTree(windowID, direction), focusedWindowID: windowID, historyLabel: "Swap \(direction.rawValue)")
    }

    func planResize(
        _ windowID: WindowID,
        direction: Direction,
        delta: Double
    ) -> Result<CommandPlanResult, CommandError> {
        planResizeSequence(windowID, direction: direction, deltas: [delta])
    }

    func planResizeSequence(
        _ windowID: WindowID,
        direction: Direction,
        deltas: [Double]
    ) -> Result<CommandPlanResult, CommandError> {
        let beforeWorld = world
        let result = measureLayoutPlan {
            advanceLayoutGeneration(onSuccess: resizeSequenceCommandPlan(
                in: world,
                windowID: windowID,
                direction: direction,
                deltas: deltas,
                generation: LayoutGeneration(raw: nextGeneration)
            ))
        }
        return recordingHistory(result, label: "Resize \(direction.rawValue)", beforeWorld: beforeWorld)
    }

    func planBalanceActiveSpace() -> Result<CommandPlanResult, CommandError> {
        guard let activeSpace = world.activeSpace else {
            return .failure(.activeSpaceUnavailable)
        }
        switch apply(.balance(activeSpace), to: world) {
        case .success(let newWorld):
            return recordingHistory(makePlan(
                from: world,
                to: newWorld,
                focusedWindowID: world.spaces[activeSpace]?.focused,
                undoWorld: world,
                scope: .activeWorkspaces
            ), label: "Balance", beforeWorld: world, spaceID: activeSpace)
        case .failure(let error):
            return .failure(error)
        }
    }

    func planBalanceWorkspace(containing windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        guard let key = workspaceKey(forWindow: windowID, in: world) else {
            return .failure(.activeSpaceUnavailable)
        }
        switch worldByBalancingWorkspace(key, in: world) {
        case .success(let newWorld):
            return recordingHistory(makePlan(
                from: world,
                to: newWorld,
                focusedWindowID: windowID,
                undoWorld: world,
                scope: .workspace(key)
            ), label: "Balance", beforeWorld: world, spaceID: key.spaceID)
        case .failure(let error):
            return .failure(error)
        }
    }

    func planShuffleActiveSpace() -> Result<CommandPlanResult, CommandError> {
        let beforeWorld = world
        var generator = SystemRandomNumberGenerator()
        switch shuffledResetLayout(in: world, using: &generator) {
        case .success(let layout):
            return recordingHistory(makeCustomLayoutPlan(
                from: world,
                to: resetActiveSpaceTilingState(in: world),
                layout: layout,
                focusedWindowID: nil,
                undoWorld: world
            ), label: "Shuffle", beforeWorld: beforeWorld)
        case .failure(let error):
            return .failure(error)
        }
    }

    func planCascadeActiveSpace() -> Result<CommandPlanResult, CommandError> {
        let beforeWorld = world
        switch cascadeResetLayout(in: world) {
        case .success(let layout):
            return recordingHistory(makeCustomLayoutPlan(
                from: world,
                to: resetActiveSpaceTilingState(in: world),
                layout: layout,
                focusedWindowID: nil,
                undoWorld: world
            ), label: "Cascade", beforeWorld: beforeWorld)
        case .failure(let error):
            return .failure(error)
        }
    }

    func planMaximizeReset(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        let beforeWorld = world
        switch maximizeResetLayout(windowID: windowID, in: world) {
        case .success(let layout):
            return recordingHistory(makeCustomLayoutPlan(
                from: world,
                to: worldBySettingFocus(windowID, in: resetActiveSpaceTilingState(in: world)),
                layout: layout,
                focusedWindowID: windowID,
                undoWorld: world
            ), label: "Maximize", beforeWorld: beforeWorld)
        case .failure(let error):
            return .failure(error)
        }
    }

    func planDrop(windowID: WindowID, displayID: DisplayID, zoneID: ZoneID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(
            .dropAtZone(windowID, displayID, zoneID),
            focusedWindowID: windowID,
            historyLabel: "Drop in \(zoneID.raw)"
        )
    }

    func planUndoLastLayout() -> Result<CommandPlanResult?, CommandError> {
        guard let spaceID = world.activeSpace,
              let entry = layoutHistoryUndoEntry(for: spaceID, in: layoutHistory)
        else { return .success(nil) }
        return historyPlan(entry, useBefore: true, action: .undo(spaceID)).map(Optional.some)
    }

    func planRedoLastLayout() -> Result<CommandPlanResult?, CommandError> {
        guard let spaceID = world.activeSpace,
              let entry = layoutHistoryRedoEntry(for: spaceID, in: layoutHistory)
        else { return .success(nil) }
        return historyPlan(entry, useBefore: false, action: .redo(spaceID)).map(Optional.some)
    }

    func planPendingTileRules() -> Result<CommandPlanResult?, CommandError> {
        switch applyingPendingTileRules(in: world) {
        case .success(.some(let plan)):
            return recordingHistory(
                makePlan(from: world, to: plan.world, focusedWindowID: plan.focusedWindowID, undoWorld: world),
                label: "Apply Window Rule",
                beforeWorld: world
            ).map(Optional.some)
        case .success(nil):
            return .success(nil)
        case .failure(let error):
            return .failure(error)
        }
    }

    func planNamedLayout(
        _ namedLayout: NamedLayout,
        spaceID: SpaceID,
        allowPartial: Bool
    ) -> Result<CommandPlanResult, NamedLayoutPlanError> {
        let application: NamedLayoutApplication
        switch applyNamedLayout(
            namedLayout,
            to: spaceID,
            in: world,
            allowPartial: allowPartial
        ) {
        case .success(let planned):
            application = planned
        case .failure(let error):
            return .failure(.application(error))
        }

        let result = recordingHistory(
            makeCustomLayoutPlan(
                from: world,
                to: application.world,
                layout: application.layout,
                focusedWindowID: world.spaces[spaceID]?.focused,
                undoWorld: world
            ),
            label: "Apply \(namedLayout.name)",
            beforeWorld: world,
            spaceID: spaceID
        )
        return result.mapError(NamedLayoutPlanError.command)
    }

    func captureNamedLayout(
        id: NamedLayoutID,
        name: String,
        revision: Int,
        spaceID: SpaceID,
        includeTitleHints: Set<WindowID>
    ) -> Result<NamedLayout, NamedLayoutValidationError> {
        NarwhalCore.namedLayout(
            id: id,
            name: name,
            revision: revision,
            from: spaceID,
            in: world,
            includeTitleHints: includeTitleHints
        )
    }

    func workbenchPresentation(snapshotQuality: AXSnapshotQuality?) -> WorkbenchPresentation {
        NarwhalAppSupport.workbenchPresentation(
            in: world,
            runtime: runtimeState,
            snapshotQuality: snapshotQuality
        )
    }

    func layoutHistoryAvailability(spaceID: SpaceID) -> LayoutHistoryAvailability {
        let undo = layoutHistoryUndoEntry(for: spaceID, in: layoutHistory)
        let redo = layoutHistoryRedoEntry(for: spaceID, in: layoutHistory)
        return LayoutHistoryAvailability(
            canUndo: undo != nil,
            canRedo: redo != nil,
            undoLabel: undo?.label,
            redoLabel: redo?.label
        )
    }

    private func planLayoutCommand(
        _ command: Command,
        focusedWindowID: WindowID?,
        historyLabel: String
    ) -> Result<CommandPlanResult, CommandError> {
        let beforeWorld = world
        switch apply(command, to: world) {
        case .success(let newWorld):
            return recordingHistory(
                makePlan(from: world, to: newWorld, focusedWindowID: focusedWindowID, undoWorld: world),
                label: historyLabel,
                beforeWorld: beforeWorld
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    private func makePlan(
        from oldWorld: World,
        to newWorld: World,
        focusedWindowID: WindowID?,
        undoWorld: World?,
        scope explicitScope: CommandPlanScope? = nil
    ) -> Result<CommandPlanResult, CommandError> {
        measureLayoutPlan {
            let scope = explicitScope ?? commandPlanScope(
                focusedWindowID: focusedWindowID,
                oldWorld: oldWorld,
                newWorld: newWorld
            )
            return advanceLayoutGeneration(onSuccess: commandPlan(
                from: oldWorld,
                to: newWorld,
                focusedWindowID: focusedWindowID,
                undoWorld: undoWorld,
                generation: LayoutGeneration(raw: nextGeneration),
                scope: scope
            ))
        }
    }

    private func makeCustomLayoutPlan(
        from oldWorld: World,
        to newWorld: World,
        layout newLayout: Layout,
        focusedWindowID: WindowID?,
        undoWorld: World?
    ) -> Result<CommandPlanResult, CommandError> {
        measureLayoutPlan {
            advanceLayoutGeneration(onSuccess: customLayoutCommandPlan(
                from: oldWorld,
                to: newWorld,
                layout: newLayout,
                focusedWindowID: focusedWindowID,
                undoWorld: undoWorld,
                generation: LayoutGeneration(raw: nextGeneration)
            ))
        }
    }

    func planCurrentLayout() -> Result<CommandPlanResult?, CommandError> {
        measureLayoutPlan {
            let result = currentLayoutCommandPlan(in: world, generation: LayoutGeneration(raw: nextGeneration))
            if case .success(.some) = result {
                nextGeneration += 1
            }
            return result
        }
    }

    private func measureLayoutPlan<Result>(_ operation: () -> Result) -> Result {
        let metricInterval = runtimeMetrics?.begin(.layoutPlan)
        defer { runtimeMetrics?.end(metricInterval) }
        return operation()
    }

    func planFocusDirection(from focusedWindowID: WindowID, direction: Direction) -> Result<FocusPlanResult, CommandError> {
        focusDirectionPlan(in: world, from: focusedWindowID, direction: direction)
    }

    func planFocusCycle(from focusedWindowID: WindowID?, direction: FocusCycleDirection) -> Result<FocusPlanResult, CommandError> {
        focusCyclePlan(in: world, from: focusedWindowID, direction: direction)
    }

    func planFocusCycleCandidates(
        from focusedWindowID: WindowID?,
        direction: FocusCycleDirection
    ) -> Result<[FocusPlanResult], CommandError> {
        focusCycleCandidatePlans(in: world, from: focusedWindowID, direction: direction)
    }

    func planFocusPrevious(from focusedWindowID: WindowID?) -> Result<FocusPlanResult, CommandError> {
        focusPreviousPlan(in: world, runtime: runtimeState, from: focusedWindowID)
    }

    func planFocus(_ windowID: WindowID) -> Result<FocusPlanResult, CommandError> {
        focusPlan(in: world, windowID: windowID)
    }

    func tiledBorderTargets() -> Result<[FocusBorderTarget], CommandError> {
        switch NarwhalCore.tiledBorderTargets(of: world) {
        case .success(let targets):
            return .success(targets)
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
    }

    func tiledWindowCount() -> Int {
        guard let activeSpace = world.activeSpace,
              let space = world.spaces[activeSpace]
        else { return 0 }
        return space.displays.values.reduce(0) { count, display in
            count + occupiedWindows(in: display.tree).count
        }
    }

    func recordObservedConstraints(_ observations: [WindowID: WindowConstraints]) {
        world = worldByRecordingObservedConstraints(observations, in: world)
    }

    func planResetLayoutMemory() -> Result<CommandPlanResult, CommandError> {
        guard let activeSpace = world.activeSpace else {
            return .failure(.activeSpaceUnavailable)
        }
        switch flattenedLayout(of: world) {
        case .success(let currentLayout):
            return recordingHistory(
                makeCustomLayoutPlan(
                    from: world,
                    to: resetActiveSpaceTilingState(in: world),
                    layout: currentLayout,
                    focusedWindowID: nil,
                    undoWorld: world
                ),
                label: "Reset",
                beforeWorld: world,
                spaceID: activeSpace
            )
        case .failure(let error):
            return .failure(.layoutUnsatisfiable(error))
        }
    }

    func restoreSnapshot() -> StoredWorld {
        storedWorld(from: world)
    }

    func commit(_ result: CommandPlanResult, appliedFrames: [WindowID: CGRect]) {
        runtimeState = worldRuntimeBySettingUndo(result.undoWorld, in: runtimeState)
        switch result.historyAction {
        case .none:
            break
        case .record(let entry):
            layoutHistory = layoutHistoryByRecording(entry, in: layoutHistory)
        case .undo(let spaceID):
            layoutHistory = layoutHistoryByCommittingUndo(for: spaceID, in: layoutHistory)
        case .redo(let spaceID):
            layoutHistory = layoutHistoryByCommittingRedo(for: spaceID, in: layoutHistory)
        }
        if let focusedWindowID = result.focusedWindowID {
            recordFocus(focusedWindowID)
        }
        world = worldByRecordingWindowFrames(appliedFrames, in: result.plannedWorld)
        pruneRuntimeState()
    }

    func recordAppliedFrames(_ frames: [WindowID: CGRect]) {
        guard !frames.isEmpty else { return }

        world = worldByRecordingWindowFrames(frames, in: world)
    }

    private func recordFocus(_ windowID: WindowID) {
        runtimeState = worldRuntimeByRecordingFocus(
            windowID,
            workspaceKey: workspaceKey(forWindow: windowID, in: world),
            in: runtimeState
        )
    }

    private func pruneRuntimeState() {
        let liveWindowIDs = Set(world.windows.keys)
        runtimeState = prunedWorldRuntimeState(liveWindowIDs: liveWindowIDs, in: runtimeState)
        layoutHistory = prunedLayoutHistoryState(liveWindowIDs: liveWindowIDs, in: layoutHistory)
    }

    private func recordingHistory(
        _ result: Result<CommandPlanResult, CommandError>,
        label: String,
        beforeWorld: World,
        spaceID explicitSpaceID: SpaceID? = nil
    ) -> Result<CommandPlanResult, CommandError> {
        result.flatMap { plan in
            let spaceID = explicitSpaceID
                ?? plan.focusedWindowID.flatMap { workspaceKey(forWindow: $0, in: plan.plannedWorld)?.spaceID }
                ?? plan.plannedWorld.activeSpace
                ?? beforeWorld.activeSpace
            guard let spaceID else { return .failure(.activeSpaceUnavailable) }
            switch flattenedLayout(of: beforeWorld) {
            case .success(let beforeLayout):
                let entry = LayoutHistoryEntry(
                    label: label,
                    spaceID: spaceID,
                    beforeWorld: beforeWorld,
                    afterWorld: plan.plannedWorld,
                    beforeLayout: beforeLayout,
                    afterLayout: plan.desiredLayout.layout
                )
                return .success(plan.withHistoryAction(.record(entry)))
            case .failure(let error):
                return .failure(.layoutUnsatisfiable(error))
            }
        }
    }

    private func historyPlan(
        _ entry: LayoutHistoryEntry,
        useBefore: Bool,
        action: LayoutHistoryAction
    ) -> Result<CommandPlanResult, CommandError> {
        let historicalWorld = useBefore ? entry.beforeWorld : entry.afterWorld
        let historicalLayout = useBefore ? entry.beforeLayout : entry.afterLayout
        let targetWorld = worldByRestoringHistorySpace(
            from: historicalWorld,
            spaceID: entry.spaceID,
            onto: world
        )
        switch flattenedLayout(of: world) {
        case .success(let currentLayout):
            let targetLayout = layoutByRestoringHistorySpace(
                historicalLayout,
                historicalWorld: historicalWorld,
                spaceID: entry.spaceID,
                currentLayout: currentLayout,
                currentWorld: world
            )
            return makeCustomLayoutPlan(
                from: world,
                to: targetWorld,
                layout: targetLayout,
                focusedWindowID: targetWorld.spaces[entry.spaceID]?.focused,
                undoWorld: nil
            ).map { $0.withHistoryAction(action) }
        case .failure(let error):
            return .failure(.layoutUnsatisfiable(error))
        }
    }

    private func replannedHistoryAction(
        _ action: LayoutHistoryAction,
        result: CommandPlanResult
    ) -> LayoutHistoryAction {
        guard case .record(let entry) = action else { return action }
        return .record(LayoutHistoryEntry(
            label: entry.label,
            spaceID: entry.spaceID,
            beforeWorld: entry.beforeWorld,
            afterWorld: result.plannedWorld,
            beforeLayout: entry.beforeLayout,
            afterLayout: result.desiredLayout.layout
        ))
    }

    private func externalGeometryHistoryLabel(_ event: AXEvent) -> String {
        switch event {
        case .windowMoved: return "Manual Move"
        case .windowResized: return "Manual Resize"
        case .windowOpened, .windowClosed, .windowFocused: return "Window Change"
        }
    }

    private func advanceLayoutGeneration<T>(
        onSuccess result: Result<T, CommandError>
    ) -> Result<T, CommandError> {
        if case .success = result {
            nextGeneration += 1
        }
        return result
    }
}
