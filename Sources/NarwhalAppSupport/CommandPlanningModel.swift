import CoreGraphics
import NarwhalCore

public struct CommandPlanResult: Equatable, Sendable {
    public let focusedWindowID: WindowID?
    public let desiredLayout: DesiredLayout
    public let windows: [WindowID: WindowMetadata]
    public let plannedWorld: World
    public let undoWorld: World?

    public init(
        focusedWindowID: WindowID?,
        desiredLayout: DesiredLayout,
        windows: [WindowID: WindowMetadata],
        plannedWorld: World,
        undoWorld: World?
    ) {
        self.focusedWindowID = focusedWindowID
        self.desiredLayout = desiredLayout
        self.windows = windows
        self.plannedWorld = plannedWorld
        self.undoWorld = undoWorld
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

public struct EnvironmentRefreshResult: Equatable, Sendable {
    public let snapshot: EnvironmentSnapshot
    public let activeSpace: SpaceID?
    public let displayCount: Int
    public let windowCount: Int
    public let quality: AXSnapshotQuality
    public let preservedSpaceLayouts: Bool
    public let observedWindowCount: Int
    public let mappedWindowCount: Int

    public init(
        snapshot: EnvironmentSnapshot,
        activeSpace: SpaceID?,
        displayCount: Int,
        windowCount: Int,
        quality: AXSnapshotQuality,
        preservedSpaceLayouts: Bool,
        observedWindowCount: Int,
        mappedWindowCount: Int
    ) {
        self.snapshot = snapshot
        self.activeSpace = activeSpace
        self.displayCount = displayCount
        self.windowCount = windowCount
        self.quality = quality
        self.preservedSpaceLayouts = preservedSpaceLayouts
        self.observedWindowCount = observedWindowCount
        self.mappedWindowCount = mappedWindowCount
    }
}

public func commandPlan(
    from oldWorld: World,
    to newWorld: World,
    focusedWindowID: WindowID?,
    undoWorld: World?,
    generation: LayoutGeneration
) -> Result<CommandPlanResult, CommandError> {
    switch flattenedLayout(of: oldWorld) {
    case .success(let oldLayout):
        switch flattenedLayout(of: newWorld) {
        case .success(let newLayout):
            return .success(commandPlanResult(
                newWorld: newWorld,
                focusedWindowID: focusedWindowID,
                undoWorld: undoWorld,
                desiredLayout: DesiredLayout(
                    generation: generation,
                    layout: newLayout,
                    delta: diff(old: oldLayout, new: newLayout)
                )
            ))
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
    case .failure(let unsatisfiable):
        return .failure(.layoutUnsatisfiable(unsatisfiable))
    }
}

public func customLayoutCommandPlan(
    from oldWorld: World,
    to newWorld: World,
    layout newLayout: Layout,
    focusedWindowID: WindowID?,
    undoWorld: World?,
    generation: LayoutGeneration
) -> Result<CommandPlanResult, CommandError> {
    switch flattenedLayout(of: oldWorld) {
    case .success(let oldLayout):
        return .success(commandPlanResult(
            newWorld: newWorld,
            focusedWindowID: focusedWindowID,
            undoWorld: undoWorld,
            desiredLayout: DesiredLayout(
                generation: generation,
                layout: newLayout,
                delta: diff(old: oldLayout, new: newLayout)
            )
        ))
    case .failure(let unsatisfiable):
        return .failure(.layoutUnsatisfiable(unsatisfiable))
    }
}

public func currentLayoutCommandPlan(
    in world: World,
    generation: LayoutGeneration
) -> Result<CommandPlanResult?, CommandError> {
    switch flattenedLayout(of: world) {
    case .success(let layout):
        guard !layout.tiled.isEmpty else { return .success(nil) }
        return .success(commandPlanResult(
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
        ))
    case .failure(let unsatisfiable):
        return .failure(.layoutUnsatisfiable(unsatisfiable))
    }
}

public func focusDirectionPlan(
    in world: World,
    from focusedWindowID: WindowID,
    direction: Direction
) -> Result<FocusPlanResult, CommandError> {
    guard world.windows[focusedWindowID] != nil else {
        return .failure(.windowNotFound(focusedWindowID))
    }
    switch flattenedLayout(of: world) {
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
        return .failure(.windowNotFound(focusedWindowID ?? WindowID(raw: 0)))
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

public func focusPreviousPlan(
    in world: World,
    runtime: WorldRuntimeState
) -> Result<FocusPlanResult, CommandError> {
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
        runtime: runtime,
        activeWindowIDs: activeWindowIDs
    ) else {
        return .failure(.windowNotFound(current ?? WindowID(raw: 0)))
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
    newWorld: World,
    focusedWindowID: WindowID?,
    undoWorld: World?,
    desiredLayout: DesiredLayout
) -> CommandPlanResult {
    CommandPlanResult(
        focusedWindowID: focusedWindowID,
        desiredLayout: desiredLayout,
        windows: newWorld.windows,
        plannedWorld: newWorld,
        undoWorld: undoWorld
    )
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
