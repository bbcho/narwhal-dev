import CoreGraphics

public func apply(_ command: Command, to world: World) -> Result<World, CommandError> {
    switch command {
    case .push(let windowID, let direction):
        return applyPush(windowID, direction: direction, to: world)
    case .center:
        return commandNotImplemented(command)
    case .eject:
        return commandNotImplemented(command)
    case .focusDirection:
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
    case .dropAtZone:
        return commandNotImplemented(command)
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
    case .environmentChanged:
        return commandNotImplemented(command)
    case .startupConverge:
        return .success(world)
    case .reloadConfig:
        return commandNotImplemented(command)
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

    let activeSpace = world.activeSpace ?? SpaceID(raw: 1)
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
