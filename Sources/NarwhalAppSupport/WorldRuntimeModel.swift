import NarwhalCore

public struct WorldRuntimeState: Equatable, Sendable {
    public static let empty = WorldRuntimeState(undoWorld: nil, focusHistory: [])

    public let undoWorld: World?
    public let focusHistory: [WindowID]

    public init(undoWorld: World?, focusHistory: [WindowID]) {
        self.undoWorld = undoWorld
        self.focusHistory = focusHistory
    }
}

public func worldRuntimeBySettingUndo(
    _ undoWorld: World?,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    WorldRuntimeState(undoWorld: undoWorld, focusHistory: state.focusHistory)
}

public func worldRuntimeByRecordingFocus(
    _ windowID: WindowID,
    limit: Int = 16,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    guard state.focusHistory.last != windowID else { return state }
    let boundedLimit = max(0, limit)
    let nextHistory = Array((state.focusHistory + [windowID]).suffix(boundedLimit))
    return WorldRuntimeState(undoWorld: state.undoWorld, focusHistory: nextHistory)
}

public func prunedWorldRuntimeState(
    liveWindowIDs: Set<WindowID>,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    let focusHistory = state.focusHistory.filter { liveWindowIDs.contains($0) }
    let undoWorld: World?
    if let undo = state.undoWorld,
       Set(undo.windows.keys).isSubset(of: liveWindowIDs) {
        undoWorld = undo
    } else {
        undoWorld = nil
    }
    return WorldRuntimeState(undoWorld: undoWorld, focusHistory: focusHistory)
}

public func runtimeFocusedWindowFallback(
    in world: World,
    runtime: WorldRuntimeState
) -> WindowMetadata? {
    if let active = activeFocusedWindow(in: world) {
        return active
    }
    let visible = activeObservedVisibleWindowIDs(in: world)
    for windowID in runtime.focusHistory.reversed() {
        guard visible.isEmpty || visible.contains(windowID),
              let metadata = world.windows[windowID],
              !metadata.isMinimized
        else { continue }
        return metadata
    }
    return nil
}

public func previousFocusTarget(
    in world: World,
    runtime: WorldRuntimeState,
    activeWindowIDs: Set<WindowID>
) -> WindowID? {
    let current = world.activeSpace.flatMap { world.spaces[$0]?.focused }
    return runtime.focusHistory.reversed().first { windowID in
        windowID != current && activeWindowIDs.contains(windowID) && world.windows[windowID] != nil
    }
}
