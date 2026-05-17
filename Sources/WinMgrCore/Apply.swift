import CoreGraphics

public func apply(_ command: Command, to world: World) -> Result<World, CommandError> {
    switch command {
    case .push(let windowID, let direction):
        return applyPush(windowID, direction: direction, to: world)
    case .center(let windowID):
        return applyCenter(windowID, to: world)
    case .eject:
        return commandNotImplemented(command)
    case .focusDirection:
        return commandNotImplemented(command)
    case .focusCycle:
        return commandNotImplemented(command)
    case .focus:
        return commandNotImplemented(command)
    case .swapInTree:
        return commandNotImplemented(command)
    case .resizeSplit:
        return commandNotImplemented(command)
    case .balance:
        return commandNotImplemented(command)
    case .toggleFloat:
        return commandNotImplemented(command)
    case .dropAtZone(let windowID, let displayID, let zoneID):
        return applyDropAtZone(windowID, displayID: displayID, zoneID: zoneID, to: world)
    case .resetLayout:
        return .success(resetTilingState(in: world))
    case .windowFocusedExternally(let windowID):
        return applyExternalFocus(windowID, to: world)
    case .windowConstraintObserved(let windowID, let constraints):
        return .success(recordObservedConstraints(constraints, for: windowID, in: world))
    case .windowOpened:
        return commandNotImplemented(command)
    case .windowClosed:
        return commandNotImplemented(command)
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
    case .insertAsCenter:
        return .success(worldByRetiling(target, insertion: .center, in: world))
    case .insertAsQuarter, .insertAtSubtree:
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

private struct RetileTarget {
    let windowID: WindowID
    let displayID: DisplayID
    let activeSpace: SpaceID
}

private enum RetileInsertion {
    case edge(Direction)
    case center

    func insert(_ windowID: WindowID, into tree: Node) -> Node {
        switch self {
        case .edge(let direction):
            return pushIntoTree(windowID, direction, tree)
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
