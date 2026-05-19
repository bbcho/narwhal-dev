import CoreGraphics

public func apply(_ command: Command, to world: World) -> Result<World, CommandError> {
    switch command {
    case .push(let windowID, let direction):
        return applyPush(windowID, direction: direction, to: world)
    case .center(let windowID):
        return applyCenter(windowID, to: world)
    case .eject(let windowID):
        return applyEject(windowID, to: world)
    case .focusDirection(let direction):
        return applyFocusDirection(direction, to: world)
    case .focusCycle(let direction):
        return applyFocusCycle(direction, to: world)
    case .focus(let windowID):
        return applyFocus(windowID, to: world)
    case .swapInTree(let windowID, let direction):
        return applySwap(windowID, direction: direction, to: world)
    case .resizeSplit(let windowID, let direction, let delta):
        return applyResizeSplit(windowID, direction: direction, delta: delta, to: world)
    case .balance(let spaceID):
        return applyBalance(spaceID, to: world)
    case .toggleFloat(let windowID):
        return applyToggleFloat(windowID, to: world)
    case .moveToNextDisplay(let windowID):
        return applyMoveToNextDisplay(windowID, to: world)
    case .dropAtZone(let windowID, let displayID, let zoneID):
        return applyDropAtZone(windowID, displayID: displayID, zoneID: zoneID, to: world)
    case .resetLayout:
        return .success(resetTilingState(in: world))
    case .windowFocusedExternally(let windowID):
        return applyExternalFocus(windowID, to: world)
    case .windowConstraintObserved(let windowID, let constraints):
        return .success(recordObservedConstraints(constraints, for: windowID, in: world))
    case .windowOpened(let metadata):
        return .success(worldByOpeningWindow(metadata, in: world))
    case .windowClosed(let windowID):
        return .success(worldByClosingWindow(windowID, in: world))
    case .windowMovedExternally(let windowID, let frame):
        return applyExternalMove(windowID, frame: frame, to: world)
    case .windowResizedExternally(let windowID, let size):
        return applyExternalResize(windowID, size: size, to: world)
    case .environmentChanged(let snapshot):
        return .success(reconcileEnvironment(snapshot, in: world))
    case .startupConverge:
        return .success(world)
    case .reloadConfig(let config):
        return .success(worldBySettingConfig(config, in: world))
    }
}

private func applyPush(_ windowID: WindowID, direction: Direction, to world: World) -> Result<World, CommandError> {
    switch retileTarget(windowID, displayID: nil, in: world) {
    case .success(let target):
        return worldByRetiling(target, insertion: .edge(direction), in: world)
    case .failure(let error):
        return .failure(error)
    }
}

private func applyDropAtZone(
    _ windowID: WindowID,
    displayID: DisplayID,
    zoneID: ZoneID,
    to world: World
) -> Result<World, CommandError> {
    let target: RetileTarget
    switch retileTarget(windowID, displayID: displayID, in: world) {
    case .success(let value):
        target = value
    case .failure(let error):
        return .failure(error)
    }
    guard let zone = world.config.zones.first(where: { $0.id == zoneID }) else {
        return .failure(.zoneNotFound(zoneID))
    }
    switch zone.action {
    case .insertAsHalf(let direction):
        return worldByRetiling(target, insertion: .edge(direction), in: world)
    case .insertAsQuarter(let corner):
        return worldByRetiling(target, insertion: .quarter(corner), in: world)
    case .insertAsCenter:
        return worldByRetiling(target, insertion: .center, in: world)
    case .insertAtSubtree(let path):
        return worldByRetiling(target, insertion: .subtree(path), in: world)
    }
}

private func applyCenter(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    switch retileTarget(windowID, displayID: nil, in: world) {
    case .success(let target):
        return worldByRetiling(target, insertion: .center, in: world)
    case .failure(let error):
        return .failure(error)
    }
}

private func applyEject(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    guard let activeSpace = world.activeSpace, let space = world.spaces[activeSpace] else {
        return .failure(.activeSpaceUnavailable)
    }
    guard let displayID = tiledDisplay(containing: windowID, in: space) else {
        return .failure(.windowIsFloating(windowID))
    }

    var displayStates = space.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: ejectFromTree(windowID, displayState.tree),
            floating: displayState.floating.filter { $0 != windowID }
        )
    }
    let target = displayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
    displayStates[displayID] = DisplaySpaceState(
        displayID: displayID,
        tree: target.tree,
        floating: target.floating + [windowID]
    )

    var spaces = world.spaces
    spaces[activeSpace] = SpaceState(id: activeSpace, displays: displayStates, focused: windowID)

    var windowDisplay = world.windowDisplay
    windowDisplay[windowID] = displayID

    return .success(World(
        displays: world.displays,
        activeSpace: activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func applyToggleFloat(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    if let activeSpace = world.activeSpace,
       let space = world.spaces[activeSpace],
       tiledDisplay(containing: windowID, in: space) != nil {
        return applyEject(windowID, to: world)
    }

    switch retileTarget(windowID, displayID: nil, in: world) {
    case .success(let target):
        return worldByRetiling(target, insertion: .center, in: world)
    case .failure(let error):
        return .failure(error)
    }
}

private func applyMoveToNextDisplay(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    let currentDisplayID: DisplayID?
    if let activeSpace = world.activeSpace,
       let space = world.spaces[activeSpace],
       let tiledDisplayID = tiledDisplay(containing: windowID, in: space) {
        currentDisplayID = tiledDisplayID
    } else {
        currentDisplayID = world.windowDisplay[windowID]
    }
    guard let currentDisplayID else {
        return .failure(.displayNotFound(DisplayID(raw: 0)))
    }
    guard let targetDisplayID = nextDisplayID(after: currentDisplayID, in: world.displays) else {
        return .failure(.displayNotFound(currentDisplayID))
    }
    switch retileTarget(windowID, displayID: targetDisplayID, in: world) {
    case .success(let target):
        return worldByRetiling(target, insertion: .center, in: world)
    case .failure(let error):
        return .failure(error)
    }
}

private func applyFocus(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    guard let activeSpace = world.activeSpace else {
        return .failure(.activeSpaceUnavailable)
    }

    var spaces = world.spaces
    let space = spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    spaces[activeSpace] = SpaceState(id: activeSpace, displays: space.displays, focused: windowID)

    return .success(World(
        displays: world.displays,
        activeSpace: activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func applyFocusDirection(_ direction: Direction, to world: World) -> Result<World, CommandError> {
    guard let activeSpace = world.activeSpace,
          let focusedWindowID = world.spaces[activeSpace]?.focused
    else {
        return .failure(.activeSpaceUnavailable)
    }
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
    guard let targetWindowID = focusTarget(in: currentLayout, from: focusedWindowID, direction: direction) else {
        return .failure(.noNeighbor(direction))
    }
    return applyFocus(targetWindowID, to: world)
}

private func applyFocusCycle(_ direction: FocusCycleDirection, to world: World) -> Result<World, CommandError> {
    guard let activeSpace = world.activeSpace else {
        return .failure(.activeSpaceUnavailable)
    }
    let focusedWindowID = world.spaces[activeSpace]?.focused
    let tiledWindowIDs: Set<WindowID>
    switch flattenedLayout(of: world) {
    case .success(let layout):
        tiledWindowIDs = Set(layout.tiled.keys)
    case .failure:
        tiledWindowIDs = []
    }
    guard let targetWindowID = focusCycleTarget(
        windows: Array(world.windows.values).filter { !tiledWindowIDs.contains($0.id) },
        from: focusedWindowID,
        direction: direction
    ) else {
        return .failure(.windowNotFound(focusedWindowID ?? WindowID(raw: 0)))
    }
    return applyFocus(targetWindowID, to: world)
}

private func nextDisplayID(after currentDisplayID: DisplayID, in displays: [DisplayID: DisplayInfo]) -> DisplayID? {
    let ordered = displays.values.sorted { lhs, rhs in
        if lhs.slot != rhs.slot {
            return lhs.slot < rhs.slot
        }
        return lhs.id.raw < rhs.id.raw
    }
    guard ordered.count > 1,
          let index = ordered.firstIndex(where: { $0.id == currentDisplayID })
    else {
        return nil
    }
    return ordered[(index + 1) % ordered.count].id
}

private func applySwap(_ windowID: WindowID, direction: Direction, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    guard let activeSpace = world.activeSpace, let space = world.spaces[activeSpace] else {
        return .failure(.activeSpaceUnavailable)
    }

    let currentLayout: Layout
    switch flattenedLayout(of: world) {
    case .success(let layout):
        currentLayout = layout
    case .failure(let unsatisfiable):
        return .failure(.layoutUnsatisfiable(unsatisfiable))
    }
    guard currentLayout.tiled[windowID] != nil else {
        return .failure(.windowIsFloating(windowID))
    }
    guard let targetWindowID = focusTarget(in: currentLayout, from: windowID, direction: direction) else {
        return .failure(.noNeighbor(direction))
    }
    guard world.windows[targetWindowID] != nil else {
        return .failure(.windowNotFound(targetWindowID))
    }
    guard let sourceDisplay = tiledDisplay(containing: windowID, in: space),
          let targetDisplay = tiledDisplay(containing: targetWindowID, in: space)
    else {
        return .failure(.windowIsFloating(windowID))
    }

    let displayStates = space.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: swapWindowsInTree(windowID, targetWindowID, displayState.tree),
            floating: displayState.floating
        )
    }
    var spaces = world.spaces
    spaces[activeSpace] = SpaceState(id: activeSpace, displays: displayStates, focused: windowID)

    var windowDisplay = world.windowDisplay
    windowDisplay[windowID] = targetDisplay
    windowDisplay[targetWindowID] = sourceDisplay

    return .success(World(
        displays: world.displays,
        activeSpace: activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func applyResizeSplit(
    _ windowID: WindowID,
    direction: Direction,
    delta: Double,
    to world: World
) -> Result<World, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    guard metadata.isResizable else {
        return .failure(.windowNotResizable(windowID))
    }
    guard let activeSpace = world.activeSpace, let space = world.spaces[activeSpace] else {
        return .failure(.activeSpaceUnavailable)
    }
    guard let displayID = tiledDisplay(containing: windowID, in: space) else {
        return .failure(.windowIsFloating(windowID))
    }
    guard let displayState = space.displays[displayID] else {
        return .failure(.displayNotFound(displayID))
    }

    let resizedTree: Node
    switch resizeSplitInTree(windowID, direction, delta: delta, displayState.tree) {
    case .success(let tree):
        resizedTree = tree
    case .failure(let error):
        return .failure(commandError(from: error, windowID: windowID, direction: direction))
    }

    var displayStates = space.displays
    displayStates[displayID] = DisplaySpaceState(
        displayID: displayID,
        tree: resizedTree,
        floating: displayState.floating
    )

    var spaces = world.spaces
    spaces[activeSpace] = SpaceState(id: activeSpace, displays: displayStates, focused: windowID)

    return .success(World(
        displays: world.displays,
        activeSpace: activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func commandError(from error: TreeResizeError, windowID: WindowID, direction: Direction) -> CommandError {
    switch error {
    case .windowNotFound:
        return .windowIsFloating(windowID)
    case .noNeighbor(let direction):
        return .noNeighbor(direction)
    case .nonFiniteDelta:
        return .invalidResizeDelta
    case .nonPositiveWeight:
        return .resizeWouldCollapseSplit(windowID, direction)
    }
}

private func applyBalance(_ spaceID: SpaceID, to world: World) -> Result<World, CommandError> {
    guard let space = world.spaces[spaceID] else {
        return .failure(.spaceNotFound(spaceID))
    }

    let displayStates = space.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: balanceTree(displayState.tree),
            floating: displayState.floating
        )
    }
    var spaces = world.spaces
    spaces[spaceID] = SpaceState(id: space.id, displays: displayStates, focused: space.focused)

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func tiledDisplay(containing windowID: WindowID, in space: SpaceState) -> DisplayID? {
    for displayID in space.displays.keys.sorted(by: { $0.raw < $1.raw }) {
        guard let displayState = space.displays[displayID],
              occupiedWindows(in: displayState.tree).contains(windowID)
        else { continue }
        return displayID
    }
    return nil
}

private struct RetileTarget {
    let windowID: WindowID
    let displayID: DisplayID
    let activeSpace: SpaceID
}

private enum RetileInsertion {
    case edge(Direction)
    case quarter(Corner)
    case center
    case subtree(NodePath)

    func insert(_ windowID: WindowID, into tree: Node) -> Result<Node, CommandError> {
        switch self {
        case .edge(let direction):
            return .success(pushIntoTree(windowID, direction, tree))
        case .quarter(let corner):
            return .success(quarterIntoTree(windowID, corner, tree))
        case .center:
            return .success(centerIntoTree(windowID, tree))
        case .subtree(let path):
            return insertIntoSubtree(windowID, path: path, tree)
                .mapError(commandError(from:))
        }
    }
}

private func retileTarget(
    _ windowID: WindowID,
    displayID requestedDisplayID: DisplayID?,
    in world: World
) -> Result<RetileTarget, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    guard metadata.isResizable else {
        return .failure(.windowNotResizable(windowID))
    }
    guard let displayID = requestedDisplayID ?? world.windowDisplay[windowID] else {
        return .failure(.displayNotFound(DisplayID(raw: 0)))
    }
    guard world.displays[displayID] != nil else {
        return .failure(.displayNotFound(displayID))
    }
    guard let activeSpace = world.activeSpace else {
        return .failure(.activeSpaceUnavailable)
    }

    return .success(RetileTarget(windowID: windowID, displayID: displayID, activeSpace: activeSpace))
}

private func worldByRetiling(_ target: RetileTarget, insertion: RetileInsertion, in world: World) -> Result<World, CommandError> {
    let currentSpace = world.spaces[target.activeSpace] ?? SpaceState(id: target.activeSpace, displays: [:], focused: nil)
    var displayStates = currentSpace.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: ejectFromTree(target.windowID, displayState.tree),
            floating: displayState.floating.filter { $0 != target.windowID }
        )
    }
    let targetDisplayState = displayStates[target.displayID] ?? DisplaySpaceState(
        displayID: target.displayID,
        tree: .void,
        floating: []
    )
    let targetTree: Node
    switch insertion.insert(target.windowID, into: targetDisplayState.tree) {
    case .success(let tree):
        targetTree = tree
    case .failure(let error):
        return .failure(error)
    }
    displayStates[target.displayID] = DisplaySpaceState(
        displayID: target.displayID,
        tree: targetTree,
        floating: targetDisplayState.floating.filter { $0 != target.windowID }
    )

    var spaces = world.spaces
    spaces[target.activeSpace] = SpaceState(id: target.activeSpace, displays: displayStates, focused: target.windowID)

    var windowDisplay = world.windowDisplay
    windowDisplay[target.windowID] = target.displayID

    return .success(World(
        displays: world.displays,
        activeSpace: target.activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func commandError(from error: TreeSubtreeInsertError) -> CommandError {
    switch error {
    case .pathNotFound(let path):
        return .configInvalid("zone subtree path not found: \(path)")
    }
}

public func resetTilingState(in world: World) -> World {
    let spaces = world.spaces.mapValues { space in
        let displays = space.displays.mapValues { displayState in
            DisplaySpaceState(displayID: displayState.displayID, tree: .void, floating: [])
        }
        return SpaceState(id: space.id, displays: displays, focused: nil)
    }

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: [:],
        pendingRules: [:],
        config: world.config
    )
}

public func recordObservedConstraints(_ observed: WindowConstraints, for windowID: WindowID, in world: World) -> World {
    guard world.windows[windowID] != nil, !observed.isEmpty else { return world }

    var windowConstraints = world.windowConstraints
    windowConstraints[windowID] = (windowConstraints[windowID] ?? WindowConstraints()).merged(with: observed)

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: world.spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    )
}

private func applyExternalFocus(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    guard let activeSpace = world.activeSpace, var space = world.spaces[activeSpace] else {
        return .success(world)
    }

    space = SpaceState(id: space.id, displays: space.displays, focused: windowID)
    var spaces = world.spaces
    spaces[activeSpace] = space

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func applyExternalMove(_ windowID: WindowID, frame: CGRect, to world: World) -> Result<World, CommandError> {
    applyExternalFrameUpdate(windowID, frame: frame, to: world)
}

private func applyExternalResize(_ windowID: WindowID, size: CGSize, to world: World) -> Result<World, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    let frame = CGRect(origin: metadata.frame.origin, size: size)
    return applyExternalFrameUpdate(windowID, frame: frame, to: world)
}

private func applyExternalFrameUpdate(_ windowID: WindowID, frame: CGRect, to world: World) -> Result<World, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }

    var windows = world.windows
    windows[windowID] = WindowMetadata(
        id: metadata.id,
        bundleID: metadata.bundleID,
        title: metadata.title,
        role: metadata.role,
        pid: metadata.pid,
        frame: frame,
        isResizable: metadata.isResizable,
        isMinimized: metadata.isMinimized
    )

    var windowDisplay = world.windowDisplay
    if let displayID = displayContainingFrame(frame, displays: world.displays) {
        windowDisplay[windowID] = displayID
    } else {
        windowDisplay.removeValue(forKey: windowID)
    }

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: world.spaces,
        windows: windows,
        windowDisplay: windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func worldBySettingConfig(_ config: Config, in world: World) -> World {
    World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: world.spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: config
    )
}
