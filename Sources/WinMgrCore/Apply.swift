import CoreGraphics

public func apply(_ command: Command, to world: World) -> Result<World, CommandError> {
    switch command {
    case .push(let windowID, let direction):
        return applyPush(windowID, direction: direction, to: world)
    case .center(let windowID):
        return applyCenter(windowID, to: world)
    case .eject(let windowID):
        return applyEject(windowID, to: world)
    case .focusDirection:
        return commandNotImplemented(command)
    case .focusCycle:
        return commandNotImplemented(command)
    case .focus:
        return commandNotImplemented(command)
    case .swapInTree(let windowID, let direction):
        return applySwap(windowID, direction: direction, to: world)
    case .resizeSplit:
        return commandNotImplemented(command)
    case .balance:
        return commandNotImplemented(command)
    case .toggleFloat(let windowID):
        return applyToggleFloat(windowID, to: world)
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
    case .windowMovedExternally:
        return commandNotImplemented(command)
    case .windowResizedExternally:
        return commandNotImplemented(command)
    case .environmentChanged(let snapshot):
        return .success(reconcileEnvironment(snapshot, in: world))
    case .startupConverge:
        return .success(world)
    case .reloadConfig(let config):
        return .success(worldBySettingConfig(config, in: world))
    }
}

private func commandNotImplemented(_ command: Command) -> Result<World, CommandError> {
    .failure(.configInvalid("command not implemented in current core: \(String(describing: command))"))
}

private func applyPush(_ windowID: WindowID, direction: Direction, to world: World) -> Result<World, CommandError> {
    switch retileTarget(windowID, displayID: nil, in: world) {
    case .success(let target):
        return .success(worldByRetiling(target, insertion: .edge(direction), in: world))
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
        return .success(worldByRetiling(target, insertion: .edge(direction), in: world))
    case .insertAsQuarter(let corner):
        return .success(worldByRetiling(target, insertion: .quarter(corner), in: world))
    case .insertAsCenter:
        return .success(worldByRetiling(target, insertion: .center, in: world))
    case .insertAtSubtree:
        return .failure(.configInvalid("zone action is not implemented in the current build: \(String(describing: zone.action))"))
    }
}

private func applyCenter(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    switch retileTarget(windowID, displayID: nil, in: world) {
    case .success(let target):
        return .success(worldByRetiling(target, insertion: .center, in: world))
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
        return .success(worldByRetiling(target, insertion: .center, in: world))
    case .failure(let error):
        return .failure(error)
    }
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

    func insert(_ windowID: WindowID, into tree: Node) -> Node {
        switch self {
        case .edge(let direction):
            return pushIntoTree(windowID, direction, tree)
        case .quarter(let corner):
            return quarterIntoTree(windowID, corner, tree)
        case .center:
            return centerIntoTree(windowID, tree)
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

private func worldByRetiling(_ target: RetileTarget, insertion: RetileInsertion, in world: World) -> World {
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
    displayStates[target.displayID] = DisplaySpaceState(
        displayID: target.displayID,
        tree: insertion.insert(target.windowID, into: targetDisplayState.tree),
        floating: targetDisplayState.floating.filter { $0 != target.windowID }
    )

    var spaces = world.spaces
    spaces[target.activeSpace] = SpaceState(id: target.activeSpace, displays: displayStates, focused: target.windowID)

    var windowDisplay = world.windowDisplay
    windowDisplay[target.windowID] = target.displayID

    return World(
        displays: world.displays,
        activeSpace: target.activeSpace,
        spaces: spaces,
        windows: world.windows,
        windowDisplay: windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    )
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
