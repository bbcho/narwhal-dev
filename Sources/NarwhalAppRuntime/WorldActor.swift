import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

actor WorldActor {
    private var world: World
    private var nextGeneration: UInt64 = 1
    private var runtimeState = WorldRuntimeState.empty
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
            return makePlan(
                from: oldWorld,
                to: newWorld,
                focusedWindowID: nil,
                undoWorld: oldWorld
            )
            .map(Optional.some)
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
        )
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
        planLayoutCommand(.push(windowID, direction), focusedWindowID: windowID)
    }

    func planCenter(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.center(windowID), focusedWindowID: windowID)
    }

    func planEject(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.eject(windowID), focusedWindowID: windowID)
    }

    func planToggleFloat(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.toggleFloat(windowID), focusedWindowID: windowID)
    }

    func planMoveToNextDisplay(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.moveToNextDisplay(windowID), focusedWindowID: windowID)
    }

    func planSwap(_ windowID: WindowID, direction: Direction) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.swapInTree(windowID, direction), focusedWindowID: windowID)
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
        measureLayoutPlan {
            advanceLayoutGeneration(onSuccess: resizeSequenceCommandPlan(
                in: world,
                windowID: windowID,
                direction: direction,
                deltas: deltas,
                generation: LayoutGeneration(raw: nextGeneration)
            ))
        }
    }

    func planBalanceActiveSpace() -> Result<CommandPlanResult, CommandError> {
        guard let activeSpace = world.activeSpace else {
            return .failure(.activeSpaceUnavailable)
        }
        switch apply(.balance(activeSpace), to: world) {
        case .success(let newWorld):
            return makePlan(
                from: world,
                to: newWorld,
                focusedWindowID: world.spaces[activeSpace]?.focused,
                undoWorld: world,
                scope: .activeWorkspaces
            )
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
            return makePlan(
                from: world,
                to: newWorld,
                focusedWindowID: windowID,
                undoWorld: world,
                scope: .workspace(key)
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    func planShuffleActiveSpace() -> Result<CommandPlanResult, CommandError> {
        var generator = SystemRandomNumberGenerator()
        switch shuffledResetLayout(in: world, using: &generator) {
        case .success(let layout):
            return makeCustomLayoutPlan(
                from: world,
                to: resetActiveSpaceTilingState(in: world),
                layout: layout,
                focusedWindowID: nil,
                undoWorld: nil
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    func planCascadeActiveSpace() -> Result<CommandPlanResult, CommandError> {
        switch cascadeResetLayout(in: world) {
        case .success(let layout):
            return makeCustomLayoutPlan(
                from: world,
                to: resetActiveSpaceTilingState(in: world),
                layout: layout,
                focusedWindowID: nil,
                undoWorld: nil
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    func planMaximizeReset(_ windowID: WindowID) -> Result<CommandPlanResult, CommandError> {
        switch maximizeResetLayout(windowID: windowID, in: world) {
        case .success(let layout):
            return makeCustomLayoutPlan(
                from: world,
                to: worldBySettingFocus(windowID, in: resetActiveSpaceTilingState(in: world)),
                layout: layout,
                focusedWindowID: windowID,
                undoWorld: nil
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    func planDrop(windowID: WindowID, displayID: DisplayID, zoneID: ZoneID) -> Result<CommandPlanResult, CommandError> {
        planLayoutCommand(.dropAtZone(windowID, displayID, zoneID), focusedWindowID: windowID)
    }

    func planUndoLastLayout() -> Result<CommandPlanResult?, CommandError> {
        guard let undoWorld = runtimeState.undoWorld else { return .success(nil) }
        return makePlan(from: world, to: undoWorld, focusedWindowID: undoWorld.spaces[undoWorld.activeSpace ?? SpaceID(raw: 0)]?.focused, undoWorld: world)
            .map(Optional.some)
    }

    func planPendingTileRules() -> Result<CommandPlanResult?, CommandError> {
        switch applyingPendingTileRules(in: world) {
        case .success(.some(let plan)):
            return makePlan(from: world, to: plan.world, focusedWindowID: plan.focusedWindowID, undoWorld: world)
                .map(Optional.some)
        case .success(nil):
            return .success(nil)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func planLayoutCommand(
        _ command: Command,
        focusedWindowID: WindowID?
    ) -> Result<CommandPlanResult, CommandError> {
        switch apply(command, to: world) {
        case .success(let newWorld):
            return makePlan(from: world, to: newWorld, focusedWindowID: focusedWindowID, undoWorld: world)
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

    func resetLayoutMemory() {
        switch apply(.resetLayout, to: world) {
        case .success(let resetWorld):
            world = resetWorld
        case .failure:
            world = resetTilingState(in: world)
        }
        runtimeState = .empty
    }

    func restoreSnapshot() -> StoredWorld {
        storedWorld(from: world)
    }

    func commit(_ result: CommandPlanResult, appliedFrames: [WindowID: CGRect]) {
        runtimeState = worldRuntimeBySettingUndo(result.undoWorld, in: runtimeState)
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
