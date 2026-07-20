import CoreGraphics
import NarwhalCore

public struct CommandPlanResult: Equatable, Sendable {
    public let focusedWindowID: WindowID?
    public let desiredLayout: DesiredLayout
    public let windows: [WindowID: WindowMetadata]
    public let sourceWorld: World
    public let plannedWorld: World
    public let undoWorld: World?
    public let historyAction: LayoutHistoryAction

    public init(
        focusedWindowID: WindowID?,
        desiredLayout: DesiredLayout,
        windows: [WindowID: WindowMetadata],
        sourceWorld: World,
        plannedWorld: World,
        undoWorld: World?,
        historyAction: LayoutHistoryAction = .none
    ) {
        self.focusedWindowID = focusedWindowID
        self.desiredLayout = desiredLayout
        self.windows = windows
        self.sourceWorld = sourceWorld
        self.plannedWorld = plannedWorld
        self.undoWorld = undoWorld
        self.historyAction = historyAction
    }

    public func withHistoryAction(_ action: LayoutHistoryAction) -> CommandPlanResult {
        CommandPlanResult(
            focusedWindowID: focusedWindowID,
            desiredLayout: desiredLayout,
            windows: windows,
            sourceWorld: sourceWorld,
            plannedWorld: plannedWorld,
            undoWorld: undoWorld,
            historyAction: action
        )
    }
}

public struct FocusPlanResult: Equatable, Sendable {
    public let window: WindowMetadata
    public let frame: CGRect

    public init(window: WindowMetadata, frame: CGRect) {
        self.window = window
        self.frame = frame
    }
}

public enum CommandPlanScope: Equatable, Sendable {
    case activeWorkspaces
    case workspace(WorkspaceKey)
}

public func commandPlan(
    from oldWorld: World,
    to newWorld: World,
    focusedWindowID: WindowID?,
    undoWorld: World?,
    generation: LayoutGeneration,
    scope: CommandPlanScope = .activeWorkspaces
) -> Result<CommandPlanResult, CommandError> {
    commandLayout(of: oldWorld, scope: scope)
        .flatMap { oldLayout in
            commandLayout(of: newWorld, scope: scope).map { newLayout in
                commandPlanResult(
                    sourceWorld: oldWorld,
                    newWorld: newWorld,
                    focusedWindowID: focusedWindowID,
                    undoWorld: undoWorld,
                    desiredLayout: DesiredLayout(
                        generation: generation,
                        layout: newLayout,
                        delta: diff(old: oldLayout, new: newLayout)
                    )
                )
            }
        }
        .mapError(CommandError.layoutUnsatisfiable)
}

public func resizeSequenceCommandPlan(
    in world: World,
    windowID: WindowID,
    direction: Direction,
    deltas: [Double],
    generation: LayoutGeneration
) -> Result<CommandPlanResult, CommandError> {
    guard !deltas.isEmpty else { return .failure(.invalidResizeDelta) }

    func plan(to candidate: World) -> Result<CommandPlanResult, CommandError> {
        commandPlan(
            from: world,
            to: candidate,
            focusedWindowID: windowID,
            undoWorld: world,
            generation: generation,
            scope: commandPlanScope(focusedWindowID: windowID, oldWorld: world, newWorld: candidate)
        )
    }

    var latestValidWorld = world
    var appliedCount = 0
    for delta in deltas {
        let candidate: World
        switch apply(.resizeSplit(windowID, direction, delta: delta), to: latestValidWorld) {
        case .success(let next):
            candidate = next
        case .failure(let error):
            return appliedCount == 0 ? .failure(error) : plan(to: latestValidWorld)
        }

        switch plan(to: candidate) {
        case .success:
            latestValidWorld = candidate
            appliedCount += 1
        case .failure(let error):
            return appliedCount == 0 ? .failure(error) : plan(to: latestValidWorld)
        }
    }
    return plan(to: latestValidWorld)
}

public func customLayoutCommandPlan(
    from oldWorld: World,
    to newWorld: World,
    layout newLayout: Layout,
    focusedWindowID: WindowID?,
    undoWorld: World?,
    generation: LayoutGeneration
) -> Result<CommandPlanResult, CommandError> {
    flattenedLayout(of: oldWorld)
        .map { oldLayout in
            commandPlanResult(
                sourceWorld: oldWorld,
                newWorld: newWorld,
                focusedWindowID: focusedWindowID,
                undoWorld: undoWorld,
                desiredLayout: DesiredLayout(
                    generation: generation,
                    layout: newLayout,
                    delta: diff(old: oldLayout, new: newLayout)
                )
            )
        }
        .mapError(CommandError.layoutUnsatisfiable)
}

public func currentLayoutCommandPlan(
    in world: World,
    generation: LayoutGeneration
) -> Result<CommandPlanResult?, CommandError> {
    flattenedLayout(of: world)
        .map { layout -> CommandPlanResult? in
            guard !layout.tiled.isEmpty else { return nil }
            return commandPlanResult(
                sourceWorld: world,
                newWorld: world,
                focusedWindowID: nil,
                undoWorld: nil,
                desiredLayout: DesiredLayout(
                    generation: generation,
                    layout: layout,
                    delta: LayoutDelta(
                        moves: layout.tiled,
                        raises: [],
                        hides: [],
                        shows: Set(layout.tiled.keys)
                    )
                )
            )
        }
        .mapError(CommandError.layoutUnsatisfiable)
}

public func focusDirectionPlan(
    in world: World,
    from focusedWindowID: WindowID,
    direction: Direction
) -> Result<FocusPlanResult, CommandError> {
    guard world.windows[focusedWindowID] != nil else {
        return .failure(.windowNotFound(focusedWindowID))
    }
    guard let key = observedWorkspaceKey(forVisibleWindow: focusedWindowID, in: world)
        ?? workspaceKey(forWindow: focusedWindowID, in: world)
    else {
        return .failure(.activeSpaceUnavailable)
    }
    switch workspaceLayout(for: key, in: world) {
    case .success(let layout):
        let targetWindowID = focusTarget(in: layout, from: focusedWindowID, direction: direction)
            ?? focusTarget(
                windows: activeLayoutWindows(in: layout, world: world),
                from: focusedWindowID,
                direction: direction
            )
        guard let targetWindowID else {
            return .failure(.noNeighbor(direction))
        }
        return focusPlan(in: world, layout: layout, windowID: targetWindowID)
    case .failure(let unsatisfiable):
        return .failure(.layoutUnsatisfiable(unsatisfiable))
    }
}

public func focusCyclePlan(
    in world: World,
    from focusedWindowID: WindowID?,
    direction: FocusCycleDirection
) -> Result<FocusPlanResult, CommandError> {
    guard let targetWindowID = focusCycleTarget(
        windows: focusCycleWindows(in: world, focusedWindowID: focusedWindowID),
        from: focusedWindowID,
        direction: direction
    ) else {
        guard let focusedWindowID else {
            return .failure(.noFocusedWindow)
        }
        return .failure(.windowNotFound(focusedWindowID))
    }
    return focusPlan(in: world, windowID: targetWindowID)
}

public func focusCycleCandidatePlans(
    in world: World,
    from focusedWindowID: WindowID?,
    direction: FocusCycleDirection
) -> Result<[FocusPlanResult], CommandError> {
    let candidateIDs = focusCycleCandidates(
        windows: focusCycleWindows(in: world, focusedWindowID: focusedWindowID),
        from: focusedWindowID,
        direction: direction
    )
    guard !candidateIDs.isEmpty else {
        guard let focusedWindowID else {
            return .failure(.noFocusedWindow)
        }
        return .failure(.windowNotFound(focusedWindowID))
    }

    let layout: Layout?
    if let key = focusedWindowID.flatMap({ observedWorkspaceKey(forVisibleWindow: $0, in: world) })
        ?? focusedWindowID.flatMap({ workspaceKey(forWindow: $0, in: world) }) {
        switch workspaceLayout(for: key, in: world) {
        case .success(let value):
            layout = value
        case .failure:
            layout = nil
        }
    } else {
        layout = nil
    }
    let candidates = candidateIDs.compactMap { windowID -> FocusPlanResult? in
        guard let target = world.windows[windowID] else { return nil }
        return FocusPlanResult(window: target, frame: layout?.tiled[windowID] ?? target.frame)
    }
    guard !candidates.isEmpty else {
        guard let focusedWindowID else {
            return .failure(.noFocusedWindow)
        }
        return .failure(.windowNotFound(focusedWindowID))
    }
    return .success(candidates)
}

public func commandPlanScope(
    focusedWindowID: WindowID?,
    oldWorld: World,
    newWorld: World
) -> CommandPlanScope {
    guard let focusedWindowID else { return .activeWorkspaces }
    if oldWorld.windowDisplay[focusedWindowID] != newWorld.windowDisplay[focusedWindowID],
       let key = workspaceKey(forWindow: focusedWindowID, in: newWorld) {
        return .workspace(key)
    }
    if let key = observedWorkspaceKey(forVisibleWindow: focusedWindowID, in: newWorld)
        ?? workspaceKey(forWindow: focusedWindowID, in: newWorld)
        ?? observedWorkspaceKey(forVisibleWindow: focusedWindowID, in: oldWorld)
        ?? workspaceKey(forWindow: focusedWindowID, in: oldWorld) {
        return .workspace(key)
    }
    return .activeWorkspaces
}

public func focusPreviousPlan(
    in world: World,
    runtime: WorldRuntimeState,
    from focusedWindowID: WindowID?
) -> Result<FocusPlanResult, CommandError> {
    let current = focusedWindowID ?? world.activeSpace.flatMap { world.spaces[$0]?.focused }
    let key = current.flatMap { observedWorkspaceKey(forVisibleWindow: $0, in: world) }
        ?? current.flatMap { workspaceKey(forWindow: $0, in: world) }
        ?? activeWorkspaceKeys(in: world).first
    let activeWindowIDs: Set<WindowID>
    if let key {
        switch workspaceLayout(for: key, in: world) {
        case .success(let layout):
            activeWindowIDs = Set(layout.tiled.keys).union(layout.floatingZOrder)
        case .failure:
            activeWindowIDs = []
        }
    } else {
        activeWindowIDs = []
    }
    guard let targetWindowID = previousFocusTarget(
        in: world,
        runtime: runtime,
        currentWindowID: current,
        activeWindowIDs: activeWindowIDs
    ) else {
        guard let current else {
            return .failure(.noFocusedWindow)
        }
        return .failure(.windowNotFound(current))
    }
    return focusPlan(in: world, windowID: targetWindowID)
}

public func focusPlan(
    in world: World,
    windowID: WindowID
) -> Result<FocusPlanResult, CommandError> {
    guard let target = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    switch flattenedLayout(of: world) {
    case .success(let layout):
        return .success(FocusPlanResult(window: target, frame: layout.tiled[windowID] ?? target.frame))
    case .failure:
        return .success(FocusPlanResult(window: target, frame: target.frame))
    }
}

public func worldBySettingFocus(_ windowID: WindowID, in world: World) -> World {
    guard let key = workspaceKey(forWindow: windowID, in: world) else { return world }
    let space = world.spaces[key.spaceID] ?? SpaceState(id: key.spaceID, displays: [:], focused: nil)
    let focusedSpace = SpaceState(id: space.id, displays: space.displays, focused: windowID)
    let spaces = world.spaces.merging([key.spaceID: focusedSpace]) { _, replacement in replacement }
    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    )
}

public func worldByRecordingObservedConstraints(
    _ observations: [WindowID: WindowConstraints],
    in world: World
) -> World {
    observations.reduce(world) { partial, entry in
        NarwhalCore.recordObservedConstraints(entry.value, for: entry.key, in: partial)
    }
}

private func commandPlanResult(
    sourceWorld: World,
    newWorld: World,
    focusedWindowID: WindowID?,
    undoWorld: World?,
    desiredLayout: DesiredLayout
) -> CommandPlanResult {
    CommandPlanResult(
        focusedWindowID: focusedWindowID,
        desiredLayout: desiredLayout,
        windows: newWorld.windows,
        sourceWorld: sourceWorld,
        plannedWorld: newWorld,
        undoWorld: undoWorld
    )
}

private func commandLayout(
    of world: World,
    scope: CommandPlanScope
) -> Result<Layout, UnsatisfiableLayout> {
    switch scope {
    case .activeWorkspaces:
        return flattenedLayout(of: world)
    case .workspace(let key):
        return workspaceLayout(for: key, in: world)
    }
}

private func focusPlan(
    in world: World,
    layout: Layout,
    windowID: WindowID
) -> Result<FocusPlanResult, CommandError> {
    guard let target = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    return .success(FocusPlanResult(window: target, frame: layout.tiled[windowID] ?? target.frame))
}

private func activeLayoutWindows(in layout: Layout, world: World) -> [WindowMetadata] {
    Set(layout.tiled.keys).union(layout.floatingZOrder).compactMap { world.windows[$0] }
}
