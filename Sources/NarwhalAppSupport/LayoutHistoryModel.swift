import NarwhalCore

public struct LayoutHistoryEntry: Equatable, Sendable {
    public let label: String
    public let spaceID: SpaceID
    public let beforeWorld: World
    public let afterWorld: World
    public let beforeLayout: Layout
    public let afterLayout: Layout

    public init(
        label: String,
        spaceID: SpaceID,
        beforeWorld: World,
        afterWorld: World,
        beforeLayout: Layout,
        afterLayout: Layout
    ) {
        self.label = label
        self.spaceID = spaceID
        self.beforeWorld = beforeWorld
        self.afterWorld = afterWorld
        self.beforeLayout = beforeLayout
        self.afterLayout = afterLayout
    }
}

public enum LayoutHistoryAction: Equatable, Sendable {
    case none
    case record(LayoutHistoryEntry)
    case undo(SpaceID)
    case redo(SpaceID)
}

public struct SpaceLayoutHistory: Equatable, Sendable {
    public let undo: [LayoutHistoryEntry]
    public let redo: [LayoutHistoryEntry]

    public init(undo: [LayoutHistoryEntry] = [], redo: [LayoutHistoryEntry] = []) {
        self.undo = undo
        self.redo = redo
    }
}

public struct LayoutHistoryState: Equatable, Sendable {
    public static let defaultLimit = 32
    public static let empty = LayoutHistoryState(limit: defaultLimit, spaces: [:])

    public let limit: Int
    public let spaces: [SpaceID: SpaceLayoutHistory]

    public init(limit: Int = defaultLimit, spaces: [SpaceID: SpaceLayoutHistory] = [:]) {
        self.limit = max(0, limit)
        self.spaces = spaces
    }
}

public func layoutHistoryByRecording(
    _ entry: LayoutHistoryEntry,
    in state: LayoutHistoryState
) -> LayoutHistoryState {
    let timeline = state.spaces[entry.spaceID] ?? SpaceLayoutHistory()
    let undo = state.limit == 0
        ? []
        : Array((timeline.undo + [entry]).suffix(state.limit))
    return state.replacing(
        SpaceLayoutHistory(undo: undo, redo: []),
        for: entry.spaceID
    )
}

public func layoutHistoryUndoEntry(
    for spaceID: SpaceID,
    in state: LayoutHistoryState
) -> LayoutHistoryEntry? {
    state.spaces[spaceID]?.undo.last
}

public func layoutHistoryRedoEntry(
    for spaceID: SpaceID,
    in state: LayoutHistoryState
) -> LayoutHistoryEntry? {
    state.spaces[spaceID]?.redo.last
}

public func layoutHistoryByCommittingUndo(
    for spaceID: SpaceID,
    in state: LayoutHistoryState
) -> LayoutHistoryState {
    guard let timeline = state.spaces[spaceID], let entry = timeline.undo.last else { return state }
    let redo = state.limit == 0
        ? []
        : Array((timeline.redo + [entry]).suffix(state.limit))
    return state.replacing(
        SpaceLayoutHistory(undo: Array(timeline.undo.dropLast()), redo: redo),
        for: spaceID
    )
}

public func layoutHistoryByCommittingRedo(
    for spaceID: SpaceID,
    in state: LayoutHistoryState
) -> LayoutHistoryState {
    guard let timeline = state.spaces[spaceID], let entry = timeline.redo.last else { return state }
    let undo = state.limit == 0
        ? []
        : Array((timeline.undo + [entry]).suffix(state.limit))
    return state.replacing(
        SpaceLayoutHistory(undo: undo, redo: Array(timeline.redo.dropLast())),
        for: spaceID
    )
}

public func prunedLayoutHistoryState(
    liveWindowIDs: Set<WindowID>,
    in state: LayoutHistoryState
) -> LayoutHistoryState {
    let timelines = state.spaces.compactMapValues { timeline -> SpaceLayoutHistory? in
        let undo = timeline.undo.filter { historyEntryIsLive($0, liveWindowIDs: liveWindowIDs) }
        let redo = timeline.redo.filter { historyEntryIsLive($0, liveWindowIDs: liveWindowIDs) }
        guard !undo.isEmpty || !redo.isEmpty else { return nil }
        return SpaceLayoutHistory(undo: undo, redo: redo)
    }
    return LayoutHistoryState(limit: state.limit, spaces: timelines)
}

public func worldByRestoringHistorySpace(
    from snapshot: World,
    spaceID: SpaceID,
    onto current: World
) -> World {
    guard let restoredSpace = snapshot.spaces[spaceID] else { return current }
    let currentIDs = current.spaces[spaceID].map(windowIDs(in:)) ?? []
    let restoredIDs = windowIDs(in: restoredSpace)
    let affectedIDs = currentIDs.union(restoredIDs)
    let spaces = current.spaces.merging([spaceID: restoredSpace]) { _, restored in restored }
    let windowDisplay = affectedIDs.reduce(into: current.windowDisplay) { result, windowID in
        if let displayID = snapshot.windowDisplay[windowID] {
            result[windowID] = displayID
        } else {
            result.removeValue(forKey: windowID)
        }
    }
    let windowSpace = affectedIDs.reduce(into: current.windowSpace) { result, windowID in
        result[windowID] = restoredIDs.contains(windowID) ? spaceID : current.windowSpace[windowID]
    }
    return World(
        displays: current.displays,
        activeSpace: current.activeSpace,
        activeSpaceByDisplay: current.activeSpaceByDisplay,
        spaces: spaces,
        windows: current.windows,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace,
        observedVisibleWindows: current.observedVisibleWindows,
        windowConstraints: current.windowConstraints,
        pendingRules: current.pendingRules,
        config: current.config
    )
}

public func layoutByRestoringHistorySpace(
    _ historical: Layout,
    historicalWorld: World,
    spaceID: SpaceID,
    currentLayout: Layout,
    currentWorld: World
) -> Layout {
    let currentIDs = currentWorld.spaces[spaceID].map(windowIDs(in:)) ?? []
    let historicalIDs = historicalWorld.spaces[spaceID].map(windowIDs(in:)) ?? []
    let affectedIDs = currentIDs.union(historicalIDs)
    let historicalTiled = historical.tiled.filter { affectedIDs.contains($0.key) }
    let historicalFloating = historical.floatingZOrder.filter { affectedIDs.contains($0) }
    let historicalHidden = historical.hidden.intersection(affectedIDs)
    return Layout(
        tiled: currentLayout.tiled
            .filter { !affectedIDs.contains($0.key) }
            .merging(historicalTiled) { _, historical in historical },
        floatingZOrder: currentLayout.floatingZOrder.filter { !affectedIDs.contains($0) }
            + historicalFloating,
        hidden: currentLayout.hidden.subtracting(affectedIDs).union(historicalHidden)
    )
}

private extension LayoutHistoryState {
    func replacing(_ timeline: SpaceLayoutHistory, for spaceID: SpaceID) -> LayoutHistoryState {
        LayoutHistoryState(
            limit: limit,
            spaces: spaces.merging([spaceID: timeline]) { _, replacement in replacement }
        )
    }
}

private func historyEntryIsLive(_ entry: LayoutHistoryEntry, liveWindowIDs: Set<WindowID>) -> Bool {
    let before = entry.beforeWorld.spaces[entry.spaceID].map(windowIDs(in:)) ?? []
    let after = entry.afterWorld.spaces[entry.spaceID].map(windowIDs(in:)) ?? []
    return before.union(after).isSubset(of: liveWindowIDs)
}
