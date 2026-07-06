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
    applyRetile(windowID, displayID: nil, insertion: .edge(direction), to: world)
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
    applyRetile(windowID, displayID: nil, insertion: .center, to: world)
}

private func applyEject(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    guard let key = workspaceKey(forWindow: windowID, in: world),
          let space = world.spaces[key.spaceID]
    else {
        return .failure(.activeSpaceUnavailable)
    }
    let displayID = tiledDisplay(containing: windowID, in: space)
        ?? floatingDisplay(containing: windowID, in: space)
        ?? world.windowDisplay[windowID]
    guard let displayID else {
        return .failure(.displayUnknownForWindow(windowID))
    }
    guard world.displays[displayID] != nil else {
        return .failure(.displayNotFound(displayID))
    }

    let ejectedDisplayStates = space.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: ejectFromTree(windowID, displayState.tree),
            floating: displayState.floating.filter { $0 != windowID }
        )
    }
    let target = ejectedDisplayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
    let displayStates = ejectedDisplayStates.setting(displayID, to: DisplaySpaceState(
        displayID: displayID,
        tree: target.tree,
        floating: target.floating + [windowID]
    ))

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces.setting(
            key.spaceID,
            to: SpaceState(id: key.spaceID, displays: displayStates, focused: windowID)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay.setting(windowID, to: displayID),
        windowSpace: world.windowSpace.setting(windowID, to: key.spaceID),
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func applyToggleFloat(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    if let key = workspaceKey(forWindow: windowID, in: world),
       let space = world.spaces[key.spaceID],
       tiledDisplay(containing: windowID, in: space) != nil {
        return applyEject(windowID, to: world)
    }

    return applyRetile(windowID, displayID: nil, insertion: .center, to: world)
}

private func applyMoveToNextDisplay(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    let currentDisplayID: DisplayID?
    if let key = workspaceKey(forWindow: windowID, in: world),
       let space = world.spaces[key.spaceID],
       let tiledDisplayID = tiledDisplay(containing: windowID, in: space) {
        currentDisplayID = tiledDisplayID
    } else {
        currentDisplayID = world.windowDisplay[windowID]
    }
    guard let currentDisplayID else {
        return .failure(.displayUnknownForWindow(windowID))
    }
    guard let targetDisplayID = nextDisplayID(after: currentDisplayID, in: world.displays) else {
        return .failure(.displayNotFound(currentDisplayID))
    }
    return applyRetile(windowID, displayID: targetDisplayID, insertion: .center, to: world)
}

private func applyFocus(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    guard let key = observedWorkspaceKey(forVisibleWindow: windowID, in: world)
        ?? workspaceKey(forWindow: windowID, in: world)
    else {
        return .failure(.activeSpaceUnavailable)
    }

    let space = world.spaces[key.spaceID] ?? SpaceState(id: key.spaceID, displays: [:], focused: nil)

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces.setting(
            key.spaceID,
            to: SpaceState(id: key.spaceID, displays: space.displays, focused: windowID)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace.setting(windowID, to: key.spaceID),
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func applyFocusDirection(_ direction: Direction, to world: World) -> Result<World, CommandError> {
    guard let focusedWindowID = world.activeSpace
        .flatMap({ world.spaces[$0]?.focused })
        ?? activeWorkspaceKeys(in: world)
            .compactMap({ world.spaces[$0.spaceID]?.focused })
            .first
    else {
        return .failure(.activeSpaceUnavailable)
    }
    guard world.windows[focusedWindowID] != nil else {
        return .failure(.windowNotFound(focusedWindowID))
    }
    guard let key = observedWorkspaceKey(forVisibleWindow: focusedWindowID, in: world)
        ?? workspaceKey(forWindow: focusedWindowID, in: world)
    else {
        return .failure(.activeSpaceUnavailable)
    }

    let currentLayout: Layout
    switch workspaceLayout(for: key, in: world) {
    case .success(let layout):
        currentLayout = layout
    case .failure(let unsatisfiable):
        return .failure(.layoutUnsatisfiable(unsatisfiable))
    }
    let targetWindowID = focusTarget(in: currentLayout, from: focusedWindowID, direction: direction)
        ?? focusTarget(
            windows: activeLayoutWindows(in: currentLayout, world: world),
            from: focusedWindowID,
            direction: direction
        )
    guard let targetWindowID else {
        return .failure(.noNeighbor(direction))
    }
    return applyFocus(targetWindowID, to: world)
}

private func applyFocusCycle(_ direction: FocusCycleDirection, to world: World) -> Result<World, CommandError> {
    let focusedWindowID = world.activeSpace
        .flatMap { world.spaces[$0]?.focused }
        ?? activeWorkspaceKeys(in: world).compactMap { world.spaces[$0.spaceID]?.focused }.first
    let floatingWindows = focusCycleWindows(in: world, focusedWindowID: focusedWindowID)
    guard let targetWindowID = focusCycleTarget(
        windows: floatingWindows,
        from: focusedWindowID,
        direction: direction
    ) else {
        guard let focusedWindowID else {
            return .failure(.noFocusedWindow)
        }
        return .failure(.windowNotFound(focusedWindowID))
    }
    return applyFocus(targetWindowID, to: world)
}

private func activeLayoutWindows(in layout: Layout, world: World) -> [WindowMetadata] {
    let activeWindowIDs = Set(layout.tiled.keys).union(layout.floatingZOrder)
    return activeWindowIDs.compactMap { world.windows[$0] }
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
    guard let key = workspaceKey(forWindow: windowID, in: world),
          let space = world.spaces[key.spaceID]
    else {
        return .failure(.activeSpaceUnavailable)
    }
    guard let sourceDisplay = tiledDisplay(containing: windowID, in: space) else {
        return .failure(.windowIsFloating(windowID))
    }

    let currentLayout: Layout
    switch workspaceLayout(for: WorkspaceKey(displayID: sourceDisplay, spaceID: key.spaceID), in: world) {
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
    guard let targetDisplay = tiledDisplay(containing: targetWindowID, in: space)
    else {
        return .failure(.windowIsFloating(windowID))
    }

    let displayStates = space.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: swapWindowsInTree(windowID, targetWindowID, displayState.tree),
            floating: sanitizedFloatingIDs(in: displayState)
        )
    }
    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces.setting(
            key.spaceID,
            to: SpaceState(id: key.spaceID, displays: displayStates, focused: windowID)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay
            .setting(windowID, to: targetDisplay)
            .setting(targetWindowID, to: sourceDisplay),
        windowSpace: world.windowSpace
            .setting(windowID, to: key.spaceID)
            .setting(targetWindowID, to: key.spaceID),
        observedVisibleWindows: world.observedVisibleWindows,
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
    guard let key = workspaceKey(forWindow: windowID, in: world),
          let space = world.spaces[key.spaceID]
    else {
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

    let displayStates = space.displays.setting(displayID, to: DisplaySpaceState(
        displayID: displayID,
        tree: resizedTree,
        floating: displayState.floating
    ))

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces.setting(
            key.spaceID,
            to: SpaceState(id: key.spaceID, displays: displayStates, focused: windowID)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
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
            floating: sanitizedFloatingIDs(in: displayState)
        )
    }
    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces.setting(
            spaceID,
            to: SpaceState(id: space.id, displays: displayStates, focused: space.focused)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

public func worldByBalancingWorkspace(
    _ key: WorkspaceKey,
    in world: World
) -> Result<World, CommandError> {
    guard let space = world.spaces[key.spaceID] else {
        return .failure(.spaceNotFound(key.spaceID))
    }
    guard let displayState = space.displays[key.displayID] else {
        return .failure(.displayNotFound(key.displayID))
    }
    let displayStates = space.displays.setting(
        key.displayID,
        to: DisplaySpaceState(
            displayID: displayState.displayID,
            tree: balanceTree(displayState.tree),
            floating: sanitizedFloatingIDs(in: displayState)
        )
    )

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces.setting(
            key.spaceID,
            to: SpaceState(id: space.id, displays: displayStates, focused: space.focused)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
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

private func floatingDisplay(containing windowID: WindowID, in space: SpaceState) -> DisplayID? {
    for displayID in space.displays.keys.sorted(by: { $0.raw < $1.raw }) {
        guard let displayState = space.displays[displayID],
              displayState.floating.contains(windowID)
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
        return .failure(.displayUnknownForWindow(windowID))
    }
    guard world.displays[displayID] != nil else {
        return .failure(.displayNotFound(displayID))
    }
    guard let activeSpace = activeSpaceID(for: displayID, in: world) else {
        return .failure(.activeSpaceUnavailable)
    }

    return .success(RetileTarget(windowID: windowID, displayID: displayID, activeSpace: activeSpace))
}

private func applyRetile(
    _ windowID: WindowID,
    displayID: DisplayID?,
    insertion: RetileInsertion,
    to world: World
) -> Result<World, CommandError> {
    switch retileTarget(windowID, displayID: displayID, in: world) {
    case .success(let target):
        return worldByRetiling(target, insertion: insertion, in: world)
    case .failure(let error):
        return .failure(error)
    }
}

private func worldByRetiling(_ target: RetileTarget, insertion: RetileInsertion, in world: World) -> Result<World, CommandError> {
    let ejectedSpaces = world.spaces.mapValues { space in
        let displays = space.displays.mapValues { displayState in
            DisplaySpaceState(
                displayID: displayState.displayID,
                tree: ejectFromTree(target.windowID, displayState.tree),
                floating: displayState.floating.filter { $0 != target.windowID }
            )
        }
        let focused = space.focused == target.windowID ? nil : space.focused
        return SpaceState(id: space.id, displays: displays, focused: focused)
    }
    let currentSpace = ejectedSpaces[target.activeSpace] ?? SpaceState(id: target.activeSpace, displays: [:], focused: nil)
    let targetDisplayState = currentSpace.displays[target.displayID] ?? DisplaySpaceState(
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
    let displayStates = currentSpace.displays.setting(target.displayID, to: DisplaySpaceState(
        displayID: target.displayID,
        tree: targetTree,
        floating: targetDisplayState.floating.filter { $0 != target.windowID }
    ))

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace ?? target.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: ejectedSpaces.setting(
            target.activeSpace,
            to: SpaceState(id: target.activeSpace, displays: displayStates, focused: target.windowID)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay.setting(target.windowID, to: target.displayID),
        windowSpace: world.windowSpace.setting(target.windowID, to: target.activeSpace),
        observedVisibleWindows: world.observedVisibleWindows,
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
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: [:],
        pendingRules: [:],
        config: world.config
    )
}

public func resetActiveSpaceTilingState(in world: World) -> World {
    let activeKeys = activeWorkspaceKeys(in: world)
    guard !activeKeys.isEmpty else { return world }

    let activeWindowIDs = activeSpaceWindowIDs(in: world)
    let spaces = activeKeys.reduce(world.spaces) { spaces, key in
        guard let space = spaces[key.spaceID] else { return spaces }
        let displayStates = resetDisplay(key.displayID, in: space.displays)
        return spaces.setting(key.spaceID, to: SpaceState(id: space.id, displays: displayStates, focused: nil))
    }
    let activeOnlyWindowIDs = activeWindowIDs.subtracting(trackedWindowIDs(in: spaces))

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace.filter { !activeOnlyWindowIDs.contains($0.key) },
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints.filter { !activeOnlyWindowIDs.contains($0.key) },
        pendingRules: world.pendingRules.filter { !activeOnlyWindowIDs.contains($0.key) },
        config: world.config
    )
}

public func recordObservedConstraints(_ observed: WindowConstraints, for windowID: WindowID, in world: World) -> World {
    guard world.windows[windowID] != nil, !observed.isEmpty else { return world }

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints.setting(
            windowID,
            to: (world.windowConstraints[windowID] ?? WindowConstraints()).merged(with: observed)
        ),
        pendingRules: world.pendingRules,
        config: world.config
    )
}

private func applyExternalFocus(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard world.windows[windowID] != nil else {
        return .failure(.windowNotFound(windowID))
    }
    guard let key = observedWorkspaceKey(forVisibleWindow: windowID, in: world)
        ?? workspaceKey(forWindow: windowID, in: world),
          let space = world.spaces[key.spaceID]
    else {
        return .success(world)
    }

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces.setting(
            key.spaceID,
            to: SpaceState(id: space.id, displays: space.displays, focused: windowID)
        ),
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace.setting(windowID, to: key.spaceID),
        observedVisibleWindows: world.observedVisibleWindows,
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

    let ownership = externalFrameOwnership(windowID: windowID, frame: frame, in: world)
    let spaces = spacesByApplyingExternalResize(
        windowID,
        from: metadata.frame,
        to: frame,
        in: world
    ) ?? world.spaces

    return .success(World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: spaces,
        windows: world.windows.setting(windowID, to: metadata.withFrame(frame)),
        windowDisplay: ownership.windowDisplay,
        windowSpace: ownership.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func spacesByApplyingExternalResize(
    _ windowID: WindowID,
    from oldFrame: CGRect,
    to newFrame: CGRect,
    in world: World
) -> [SpaceID: SpaceState]? {
    let directions = externalResizeDirections(from: oldFrame, to: newFrame)
    guard !directions.isEmpty,
          let key = workspaceKey(forWindow: windowID, in: world),
          let space = world.spaces[key.spaceID],
          let displayID = tiledDisplay(containing: windowID, in: space),
          let displayState = space.displays[displayID],
          let display = world.displays[displayID]
    else {
        return nil
    }
    guard display.visibleFrame.intersection(newFrame).narwhalArea > 0,
          displayContainingFrame(newFrame, displays: world.displays) == displayID
    else {
        return nil
    }

    let rootFrame = applyOuterGaps(world.config.gaps.outer, to: display.visibleFrame)
    var tree = displayState.tree
    var changedTree = false
    for direction in directions {
        switch resizeSplitInTreeToMatchWindowFrame(
            windowID,
            direction,
            desiredFrame: newFrame,
            rootFrame: rootFrame,
            innerGap: world.config.gaps.inner,
            tree
        ) {
        case .success(let resized):
            changedTree = changedTree || resized != tree
            tree = resized
        case .failure:
            continue
        }
    }
    guard changedTree else { return nil }

    let displayStates = space.displays.setting(displayID, to: DisplaySpaceState(
        displayID: displayID,
        tree: tree,
        floating: displayState.floating
    ))
    return world.spaces.setting(
        key.spaceID,
        to: SpaceState(id: space.id, displays: displayStates, focused: space.focused)
    )
}

private func externalResizeDirections(from oldFrame: CGRect, to newFrame: CGRect) -> [Direction] {
    let tolerance = GeometryTolerances.externalResizeDirection
    var directions: [Direction] = []
    if abs(newFrame.width - oldFrame.width) > tolerance {
        let minChange = abs(newFrame.minX - oldFrame.minX)
        let maxChange = abs(newFrame.maxX - oldFrame.maxX)
        directions.append(minChange > maxChange ? .left : .right)
    }
    if abs(newFrame.height - oldFrame.height) > tolerance {
        let minChange = abs(newFrame.minY - oldFrame.minY)
        let maxChange = abs(newFrame.maxY - oldFrame.maxY)
        directions.append(minChange > maxChange ? .up : .down)
    }
    return directions
}

private func worldBySettingConfig(_ config: Config, in world: World) -> World {
    World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: config
    )
}

private func resetDisplay(
    _ displayID: DisplayID,
    in displays: [DisplayID: DisplaySpaceState]
) -> [DisplayID: DisplaySpaceState] {
    guard let displayState = displays[displayID] else { return displays }
    return displays.setting(
        displayID,
        to: DisplaySpaceState(displayID: displayState.displayID, tree: .void, floating: [])
    )
}

private struct ExternalFrameOwnership {
    let windowDisplay: [WindowID: DisplayID]
    let windowSpace: [WindowID: SpaceID]
}

private func externalFrameOwnership(
    windowID: WindowID,
    frame: CGRect,
    in world: World
) -> ExternalFrameOwnership {
    guard let displayID = displayContainingFrame(frame, displays: world.displays) else {
        return ExternalFrameOwnership(
            windowDisplay: world.windowDisplay.removing(windowID),
            windowSpace: world.windowSpace.removing(windowID)
        )
    }

    return ExternalFrameOwnership(
        windowDisplay: world.windowDisplay.setting(windowID, to: displayID),
        windowSpace: windowSpaceAfterExternalFrameUpdate(windowID: windowID, displayID: displayID, in: world)
    )
}

private func windowSpaceAfterExternalFrameUpdate(
    windowID: WindowID,
    displayID: DisplayID,
    in world: World
) -> [WindowID: SpaceID] {
    if let currentSpace = world.windowSpace[windowID] {
        let activeSpaces = Set(world.activeSpaceByDisplay.values)
        guard activeSpaces.contains(currentSpace),
              let spaceID = activeSpaceID(for: displayID, in: world)
        else {
            return world.windowSpace
        }
        return world.windowSpace.setting(windowID, to: spaceID)
    }
    guard let spaceID = activeSpaceID(for: displayID, in: world) else {
        return world.windowSpace
    }
    return world.windowSpace.setting(windowID, to: spaceID)
}

private extension WindowMetadata {
    func withFrame(_ frame: CGRect) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: bundleID,
            title: title,
            role: role,
            pid: pid,
            frame: frame,
            isResizable: isResizable,
            isMinimized: isMinimized
        )
    }
}
