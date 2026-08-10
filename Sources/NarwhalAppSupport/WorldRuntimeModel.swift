import NarwhalCore

public struct WorkspaceReconciliationIssue: Equatable, Sendable {
    public let operation: String
    public let windowIDs: [WindowID]
    public let reason: String

    public init(operation: String, windowIDs: [WindowID], reason: String) {
        self.operation = operation
        self.windowIDs = Array(Set(windowIDs)).sorted { $0.raw < $1.raw }
        self.reason = reason
    }
}

public struct WorldRuntimeState: Equatable, Sendable {
    public static let empty = WorldRuntimeState(
        undoWorld: nil,
        focusHistory: [],
        workspaceFocus: [:],
        windowInteractions: [:],
        workspaceReconciliationIssues: [:]
    )

    public let undoWorld: World?
    public let focusHistory: [WindowID]
    public let workspaceFocus: [WorkspaceKey: WindowID]
    public let windowInteractions: [WindowID: WindowInteractionState]
    public let workspaceReconciliationIssues: [WorkspaceKey: WorkspaceReconciliationIssue]

    public init(
        undoWorld: World?,
        focusHistory: [WindowID],
        workspaceFocus: [WorkspaceKey: WindowID] = [:],
        windowInteractions: [WindowID: WindowInteractionState] = [:],
        workspaceReconciliationIssues: [WorkspaceKey: WorkspaceReconciliationIssue] = [:]
    ) {
        self.undoWorld = undoWorld
        self.focusHistory = focusHistory
        self.workspaceFocus = workspaceFocus
        self.windowInteractions = windowInteractions
        self.workspaceReconciliationIssues = workspaceReconciliationIssues
    }
}

public enum TemporaryDetachmentReason: String, Equatable, Codable, Sendable {
    case applicationConstraint
    case reconciliationPending
    case userMoved
}

public enum WindowInteractionState: Equatable, Codable, Sendable {
    case manualAdjustment
    case temporarilyDetached(TemporaryDetachmentReason)
}

public func worldRuntimeBySettingUndo(
    _ undoWorld: World?,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    WorldRuntimeState(
        undoWorld: undoWorld,
        focusHistory: state.focusHistory,
        workspaceFocus: state.workspaceFocus,
        windowInteractions: state.windowInteractions,
        workspaceReconciliationIssues: state.workspaceReconciliationIssues
    )
}

public func worldRuntimeByRecordingFocus(
    _ windowID: WindowID,
    workspaceKey: WorkspaceKey? = nil,
    limit: Int = 16,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    let boundedLimit = max(0, limit)
    let nextHistory = state.focusHistory.last == windowID
        ? state.focusHistory
        : Array((state.focusHistory + [windowID]).suffix(boundedLimit))
    let nextWorkspaceFocus = workspaceKey.map { key in
        state.workspaceFocus.merging([key: windowID]) { _, replacement in replacement }
    } ?? state.workspaceFocus
    return WorldRuntimeState(
        undoWorld: state.undoWorld,
        focusHistory: nextHistory,
        workspaceFocus: nextWorkspaceFocus,
        windowInteractions: state.windowInteractions,
        workspaceReconciliationIssues: state.workspaceReconciliationIssues
    )
}

public func worldRuntimeBySettingInteraction(
    _ interaction: WindowInteractionState?,
    for windowID: WindowID,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    var interactions = state.windowInteractions
    interactions[windowID] = interaction
    return WorldRuntimeState(
        undoWorld: state.undoWorld,
        focusHistory: state.focusHistory,
        workspaceFocus: state.workspaceFocus,
        windowInteractions: interactions,
        workspaceReconciliationIssues: state.workspaceReconciliationIssues
    )
}

public func worldRuntimeByRecordingReconciliationIssue(
    _ issue: WorkspaceReconciliationIssue,
    for key: WorkspaceKey,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    WorldRuntimeState(
        undoWorld: state.undoWorld,
        focusHistory: state.focusHistory,
        workspaceFocus: state.workspaceFocus,
        windowInteractions: state.windowInteractions,
        workspaceReconciliationIssues: state.workspaceReconciliationIssues.merging([key: issue]) {
            _, replacement in replacement
        }
    )
}

public func worldRuntimeByClearingReconciliationIssue(
    for key: WorkspaceKey,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    var issues = state.workspaceReconciliationIssues
    issues[key] = nil
    return WorldRuntimeState(
        undoWorld: state.undoWorld,
        focusHistory: state.focusHistory,
        workspaceFocus: state.workspaceFocus,
        windowInteractions: state.windowInteractions,
        workspaceReconciliationIssues: issues
    )
}

public func prunedWorldRuntimeState(
    liveWindowIDs: Set<WindowID>,
    liveWorkspaceKeys: Set<WorkspaceKey>? = nil,
    in state: WorldRuntimeState
) -> WorldRuntimeState {
    let focusHistory = state.focusHistory.filter { liveWindowIDs.contains($0) }
    let workspaceFocus = state.workspaceFocus.filter { liveWindowIDs.contains($0.value) }
    let windowInteractions = state.windowInteractions.filter { liveWindowIDs.contains($0.key) }
    let undoWorld: World?
    if let undo = state.undoWorld,
       Set(undo.windows.keys).isSubset(of: liveWindowIDs) {
        undoWorld = undo
    } else {
        undoWorld = nil
    }
    let workspaceReconciliationIssues = liveWorkspaceKeys.map { liveKeys in
        state.workspaceReconciliationIssues.filter { liveKeys.contains($0.key) }
    } ?? state.workspaceReconciliationIssues
    return WorldRuntimeState(
        undoWorld: undoWorld,
        focusHistory: focusHistory,
        workspaceFocus: workspaceFocus,
        windowInteractions: windowInteractions,
        workspaceReconciliationIssues: workspaceReconciliationIssues
    )
}

public func runtimeFocusedWindowFallback(
    in world: World,
    runtime: WorldRuntimeState
) -> WindowMetadata? {
    if let active = activeFocusedWindow(in: world) {
        return active
    }
    for key in activeWorkspaceKeys(in: world) {
        guard let windowID = runtime.workspaceFocus[key],
              let metadata = fallbackMetadata(windowID, in: key, world: world)
        else { continue }
        return metadata
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

private func fallbackMetadata(_ windowID: WindowID, in key: WorkspaceKey, world: World) -> WindowMetadata? {
    guard let metadata = world.windows[windowID],
          !metadata.isMinimized,
          world.windowDisplay[windowID] == key.displayID
    else { return nil }

    if let spaceID = world.windowSpace[windowID], spaceID != key.spaceID {
        return nil
    }
    let observed = observedVisibleWindowIDs(key, in: world)
    if !observed.isEmpty, !observed.contains(windowID) {
        return nil
    }
    return metadata
}

public func previousFocusTarget(
    in world: World,
    runtime: WorldRuntimeState,
    currentWindowID: WindowID? = nil,
    activeWindowIDs: Set<WindowID>
) -> WindowID? {
    let current = currentWindowID ?? world.activeSpace.flatMap { world.spaces[$0]?.focused }
    return runtime.focusHistory.reversed().first { windowID in
        windowID != current && activeWindowIDs.contains(windowID) && world.windows[windowID] != nil
    }
}
