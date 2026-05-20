import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

struct CommandPlanResult: Sendable {
    let focusedWindowID: WindowID?
    let desiredLayout: DesiredLayout
    let windows: [WindowID: WindowMetadata]
    let plannedWorld: World
    let undoWorld: World?
}

struct FocusPlanResult: Sendable {
    let window: WindowMetadata
    let frame: CGRect
}

struct EnvironmentRefreshResult: Sendable {
    let snapshot: EnvironmentSnapshot
    let activeSpace: SpaceID?
    let displayCount: Int
    let windowCount: Int
    let quality: AXSnapshotQuality
    let preservedSpaceLayouts: Bool
    let observedWindowCount: Int
    let mappedWindowCount: Int
}

actor WorldActor {
    private var world: World
    private var nextGeneration: UInt64 = 1
    private var runtimeState = WorldRuntimeState.empty

    init(config: Config = .default) {
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
        let preservedSpaceLayouts = environmentSnapshotPreservesSpaceLayouts(snapshot, in: world)
        switch apply(.environmentChanged(snapshot), to: world) {
        case .success(let next):
            world = next
        case .failure:
            break
        }
        pruneRuntimeState()
        return EnvironmentRefreshResult(
            snapshot: snapshot,
            activeSpace: world.activeSpace,
            displayCount: world.displays.count,
            windowCount: world.windows.count,
            quality: snapshot.axSnapshot.quality,
            preservedSpaceLayouts: preservedSpaceLayouts,
            observedWindowCount: snapshot.observedWindowCount,
            mappedWindowCount: snapshot.mappedWindowCount
        )
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
        planLayoutCommand(.resizeSplit(windowID, direction, delta: delta), focusedWindowID: windowID)
    }

    func planBalanceActiveSpace() -> Result<CommandPlanResult, CommandError> {
        guard let activeSpace = world.activeSpace else {
            return .failure(.activeSpaceUnavailable)
        }
        return planLayoutCommand(.balance(activeSpace), focusedWindowID: world.spaces[activeSpace]?.focused)
    }

    func planShuffleActiveSpace() -> Result<CommandPlanResult, CommandError> {
        switch shuffledResetLayout(in: world) {
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
                to: resetActiveSpaceTilingState(in: world).settingFocus(windowID),
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
        undoWorld: World?
    ) -> Result<CommandPlanResult, CommandError> {
        let oldLayout: Layout
        switch flattenedLayout(of: oldWorld) {
        case .success(let layout):
            oldLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }

        let newLayout: Layout
        switch flattenedLayout(of: newWorld) {
        case .success(let layout):
            newLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
        let desired = DesiredLayout(
            generation: LayoutGeneration(raw: nextGeneration),
            layout: newLayout,
            delta: diff(old: oldLayout, new: newLayout)
        )
        nextGeneration += 1
        return .success(CommandPlanResult(
            focusedWindowID: focusedWindowID,
            desiredLayout: desired,
            windows: newWorld.windows,
            plannedWorld: newWorld,
            undoWorld: undoWorld
        ))
    }

    private func makeCustomLayoutPlan(
        from oldWorld: World,
        to newWorld: World,
        layout newLayout: Layout,
        focusedWindowID: WindowID?,
        undoWorld: World?
    ) -> Result<CommandPlanResult, CommandError> {
        let oldLayout: Layout
        switch flattenedLayout(of: oldWorld) {
        case .success(let layout):
            oldLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }

        let desired = DesiredLayout(
            generation: LayoutGeneration(raw: nextGeneration),
            layout: newLayout,
            delta: diff(old: oldLayout, new: newLayout)
        )
        nextGeneration += 1
        return .success(CommandPlanResult(
            focusedWindowID: focusedWindowID,
            desiredLayout: desired,
            windows: newWorld.windows,
            plannedWorld: newWorld,
            undoWorld: undoWorld
        ))
    }

    func planCurrentLayout() -> Result<CommandPlanResult?, CommandError> {
        let newLayout: Layout
        switch flattenedLayout(of: world) {
        case .success(let layout):
            newLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
        guard !newLayout.tiled.isEmpty else {
            return .success(nil)
        }

        let desired = DesiredLayout(
            generation: LayoutGeneration(raw: nextGeneration),
            layout: newLayout,
            delta: LayoutDelta(
                moves: newLayout.tiled,
                raises: [],
                hides: [],
                shows: Set(newLayout.tiled.keys)
            )
        )
        nextGeneration += 1
        return .success(CommandPlanResult(
            focusedWindowID: nil,
            desiredLayout: desired,
            windows: world.windows,
            plannedWorld: world,
            undoWorld: nil
        ))
    }

    func planFocusDirection(from focusedWindowID: WindowID, direction: Direction) -> Result<FocusPlanResult, CommandError> {
        guard world.windows[focusedWindowID] != nil else {
            return .failure(.windowNotFound(focusedWindowID))
        }
        let currentLayout: Layout
        switch flattenedLayout(of: world) {
        case .success(let layout):
            currentLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
        let targetWindowID = focusTarget(in: currentLayout, from: focusedWindowID, direction: direction)
            ?? focusTarget(
                windows: activeLayoutWindows(in: currentLayout),
                from: focusedWindowID,
                direction: direction
            )
        guard let targetWindowID else {
            return .failure(.noNeighbor(direction))
        }
        guard let target = world.windows[targetWindowID] else {
            return .failure(.windowNotFound(targetWindowID))
        }
        return .success(FocusPlanResult(window: target, frame: currentLayout.tiled[targetWindowID] ?? target.frame))
    }

    func planFocusCycle(from focusedWindowID: WindowID?, direction: FocusCycleDirection) -> Result<FocusPlanResult, CommandError> {
        guard let targetWindowID = focusCycleTarget(
            windows: focusCycleWindows(in: world, focusedWindowID: focusedWindowID),
            from: focusedWindowID,
            direction: direction
        ) else {
            return .failure(.windowNotFound(focusedWindowID ?? WindowID(raw: 0)))
        }
        guard let target = world.windows[targetWindowID] else {
            return .failure(.windowNotFound(targetWindowID))
        }
        let targetFrame: CGRect
        switch flattenedLayout(of: world) {
        case .success(let layout):
            targetFrame = layout.tiled[targetWindowID] ?? target.frame
        case .failure:
            targetFrame = target.frame
        }
        return .success(FocusPlanResult(window: target, frame: targetFrame))
    }

    func planFocusCycleCandidates(
        from focusedWindowID: WindowID?,
        direction: FocusCycleDirection
    ) -> Result<[FocusPlanResult], CommandError> {
        let candidateIDs = focusCycleCandidates(
            windows: focusCycleWindows(in: world, focusedWindowID: focusedWindowID),
            from: focusedWindowID,
            direction: direction
        )
        guard !candidateIDs.isEmpty else {
            return .failure(.windowNotFound(focusedWindowID ?? WindowID(raw: 0)))
        }
        let layout: Layout?
        switch flattenedLayout(of: world) {
        case .success(let value):
            layout = value
        case .failure:
            layout = nil
        }
        let candidates = candidateIDs.compactMap { windowID -> FocusPlanResult? in
            guard let target = world.windows[windowID] else { return nil }
            return FocusPlanResult(window: target, frame: layout?.tiled[windowID] ?? target.frame)
        }
        guard !candidates.isEmpty else {
            return .failure(.windowNotFound(focusedWindowID ?? WindowID(raw: 0)))
        }
        return .success(candidates)
    }

    private func activeLayoutWindows(in layout: Layout) -> [WindowMetadata] {
        let activeWindowIDs = Set(layout.tiled.keys).union(layout.floatingZOrder)
        return activeWindowIDs.compactMap { world.windows[$0] }
    }

    func planFocusPrevious() -> Result<FocusPlanResult, CommandError> {
        let current = world.activeSpace.flatMap { world.spaces[$0]?.focused }
        let activeWindowIDs: Set<WindowID>
        switch flattenedLayout(of: world) {
        case .success(let layout):
            activeWindowIDs = Set(layout.tiled.keys).union(layout.floatingZOrder)
        case .failure:
            activeWindowIDs = []
        }
        guard let targetWindowID = previousFocusTarget(
            in: world,
            runtime: runtimeState,
            activeWindowIDs: activeWindowIDs
        ) else {
            return .failure(.windowNotFound(current ?? WindowID(raw: 0)))
        }
        return planFocus(targetWindowID)
    }

    func planFocus(_ windowID: WindowID) -> Result<FocusPlanResult, CommandError> {
        guard let target = world.windows[windowID] else {
            return .failure(.windowNotFound(windowID))
        }
        let targetFrame: CGRect
        switch flattenedLayout(of: world) {
        case .success(let layout):
            targetFrame = layout.tiled[windowID] ?? target.frame
        case .failure:
            targetFrame = target.frame
        }
        return .success(FocusPlanResult(window: target, frame: targetFrame))
    }

    func tiledBorderTargets() -> Result<[FocusBorderTarget], CommandError> {
        switch NarwhalCore.tiledBorderTargets(of: world) {
        case .success(let targets):
            return .success(targets)
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
    }

    func recordObservedConstraints(_ observations: [WindowID: WindowConstraints]) {
        for (windowID, constraints) in observations {
            world = NarwhalCore.recordObservedConstraints(constraints, for: windowID, in: world)
        }
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
        runtimeState = worldRuntimeByRecordingFocus(windowID, in: runtimeState)
    }

    private func pruneRuntimeState() {
        let liveWindowIDs = Set(world.windows.keys)
        runtimeState = prunedWorldRuntimeState(liveWindowIDs: liveWindowIDs, in: runtimeState)
    }
}

private extension World {
    func settingFocus(_ windowID: WindowID) -> World {
        guard let key = workspaceKey(forWindow: windowID, in: self) else { return self }
        var spaces = spaces
        let space = spaces[key.spaceID] ?? SpaceState(id: key.spaceID, displays: [:], focused: nil)
        spaces[key.spaceID] = SpaceState(id: space.id, displays: space.displays, focused: windowID)
        return World(
            displays: displays,
            activeSpace: activeSpace,
            activeSpaceByDisplay: activeSpaceByDisplay,
            spaces: spaces,
            windows: windows,
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: observedVisibleWindows,
            windowConstraints: windowConstraints,
            pendingRules: pendingRules,
            config: config
        )
    }
}
