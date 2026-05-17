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
    .failure(.configInvalid("command not implemented in MVP core: \(String(describing: command))"))
}

private func applyPush(_ windowID: WindowID, direction: Direction, to world: World) -> Result<World, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    guard metadata.isResizable else {
        return .failure(.windowNotResizable(windowID))
    }
    guard let displayID = world.windowDisplay[windowID] else {
        return .failure(.displayNotFound(DisplayID(raw: 0)))
    }
    guard world.displays[displayID] != nil else {
        return .failure(.displayNotFound(displayID))
    }
    guard let activeSpace = world.activeSpace else {
        return .failure(.activeSpaceUnavailable)
    }

    let currentSpace = world.spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    let currentDisplayState = currentSpace.displays[displayID] ?? DisplaySpaceState(
        displayID: displayID,
        tree: .void,
        floating: []
    )

    let nextDisplayState = DisplaySpaceState(
        displayID: displayID,
        tree: pushIntoTree(windowID, direction, currentDisplayState.tree),
        floating: currentDisplayState.floating.filter { $0 != windowID }
    )

    var nextDisplayStates = currentSpace.displays
    nextDisplayStates[displayID] = nextDisplayState

    var nextSpaces = world.spaces
    nextSpaces[activeSpace] = SpaceState(id: activeSpace, displays: nextDisplayStates, focused: windowID)

    return .success(World(
        displays: world.displays,
        activeSpace: activeSpace,
        spaces: nextSpaces,
        windows: world.windows,
        windowDisplay: world.windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

private func applyDropAtZone(
    _ windowID: WindowID,
    displayID: DisplayID,
    zoneID: ZoneID,
    to world: World
) -> Result<World, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    guard metadata.isResizable else {
        return .failure(.windowNotResizable(windowID))
    }
    guard world.displays[displayID] != nil else {
        return .failure(.displayNotFound(displayID))
    }
    guard let activeSpace = world.activeSpace else {
        return .failure(.activeSpaceUnavailable)
    }
    guard let zone = world.config.zones.first(where: { $0.id == zoneID }) else {
        return .failure(.zoneNotFound(zoneID))
    }
    switch zone.action {
    case .insertAsHalf(let direction):
        return applyDropAsHalf(windowID, direction: direction, displayID: displayID, activeSpace: activeSpace, to: world)
    case .insertAsCenter:
        return applyDropAsCenter(windowID, displayID: displayID, activeSpace: activeSpace, to: world)
    case .insertAsQuarter, .insertAtSubtree:
        return .failure(.configInvalid("zone action is not implemented in the current MVP rung: \(String(describing: zone.action))"))
    }
}

private func applyCenter(_ windowID: WindowID, to world: World) -> Result<World, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    guard metadata.isResizable else {
        return .failure(.windowNotResizable(windowID))
    }
    guard let displayID = world.windowDisplay[windowID] else {
        return .failure(.displayNotFound(DisplayID(raw: 0)))
    }
    guard world.displays[displayID] != nil else {
        return .failure(.displayNotFound(displayID))
    }
    guard let activeSpace = world.activeSpace else {
        return .failure(.activeSpaceUnavailable)
    }

    return applyDropAsCenter(windowID, displayID: displayID, activeSpace: activeSpace, to: world)
}

private func applyDropAsHalf(
    _ windowID: WindowID,
    direction: Direction,
    displayID: DisplayID,
    activeSpace: SpaceID,
    to world: World
) -> Result<World, CommandError> {
    let currentSpace = world.spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    var displayStates = currentSpace.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: ejectFromTree(windowID, displayState.tree),
            floating: displayState.floating.filter { $0 != windowID }
        )
    }
    let targetDisplayState = displayStates[displayID] ?? DisplaySpaceState(
        displayID: displayID,
        tree: .void,
        floating: []
    )
    displayStates[displayID] = DisplaySpaceState(
        displayID: displayID,
        tree: pushIntoTree(windowID, direction, targetDisplayState.tree),
        floating: targetDisplayState.floating.filter { $0 != windowID }
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

private func applyDropAsCenter(
    _ windowID: WindowID,
    displayID: DisplayID,
    activeSpace: SpaceID,
    to world: World
) -> Result<World, CommandError> {
    let currentSpace = world.spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    var displayStates = currentSpace.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: ejectFromTree(windowID, displayState.tree),
            floating: displayState.floating.filter { $0 != windowID }
        )
    }
    let targetDisplayState = displayStates[displayID] ?? DisplaySpaceState(
        displayID: displayID,
        tree: .void,
        floating: []
    )
    displayStates[displayID] = DisplaySpaceState(
        displayID: displayID,
        tree: centerIntoTree(windowID, targetDisplayState.tree),
        floating: targetDisplayState.floating.filter { $0 != windowID }
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
