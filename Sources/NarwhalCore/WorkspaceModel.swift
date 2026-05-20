import CoreGraphics

public func activeSpaceID(for displayID: DisplayID, in world: World) -> SpaceID? {
    world.activeSpaceByDisplay[displayID] ?? world.activeSpace
}

public func activeWorkspaceKeys(in world: World) -> [WorkspaceKey] {
    let keyed = world.displays.keys.compactMap { displayID -> WorkspaceKey? in
        guard let spaceID = activeSpaceID(for: displayID, in: world) else { return nil }
        return WorkspaceKey(displayID: displayID, spaceID: spaceID)
    }
    return keyed.sorted {
        if $0.displayID.raw != $1.displayID.raw { return $0.displayID.raw < $1.displayID.raw }
        return $0.spaceID.raw < $1.spaceID.raw
    }
}

public func workspaceKey(forWindow windowID: WindowID, in world: World) -> WorkspaceKey? {
    guard let displayID = world.windowDisplay[windowID] ?? displayContainingWindow(windowID, in: world.spaces) else {
        return nil
    }
    let spaceID = world.windowSpace[windowID]
        ?? spaceContainingWindow(windowID, in: world.spaces)
        ?? activeSpaceID(for: displayID, in: world)
    guard let spaceID else { return nil }
    return WorkspaceKey(displayID: displayID, spaceID: spaceID)
}

public func workspaceWindowIDs(_ key: WorkspaceKey, in world: World) -> Set<WindowID> {
    guard let displayState = world.spaces[key.spaceID]?.displays[key.displayID] else { return [] }
    return windowIDs(in: displayState)
}

public func observedVisibleWindowIDs(_ key: WorkspaceKey, in world: World) -> Set<WindowID> {
    world.observedVisibleWindows[key, default: []]
}

public func activeObservedVisibleWindowIDs(in world: World) -> Set<WindowID> {
    activeWorkspaceKeys(in: world).reduce(Set<WindowID>()) { result, key in
        result.union(observedVisibleWindowIDs(key, in: world))
    }
}

public func activeSpaceWindowIDs(in world: World) -> Set<WindowID> {
    activeWorkspaceKeys(in: world).reduce(Set<WindowID>()) { result, key in
        result.union(workspaceWindowIDs(key, in: world))
    }
}

public func sanitizedFloatingIDs(in displayState: DisplaySpaceState) -> [WindowID] {
    let tiled = Set(occupiedWindows(in: displayState.tree))
    return displayState.floating
        .reduce(FloatingIDsAccumulator(tiled: tiled, seen: [], ordered: [])) { accumulator, windowID in
            accumulator.adding(windowID)
        }
        .ordered
}

public func sanitizedDisplayState(_ displayState: DisplaySpaceState) -> DisplaySpaceState {
    DisplaySpaceState(
        displayID: displayState.displayID,
        tree: displayState.tree,
        floating: sanitizedFloatingIDs(in: displayState)
    )
}

public func sanitizedSpaceState(_ space: SpaceState) -> SpaceState {
    SpaceState(
        id: space.id,
        displays: space.displays.mapValues(sanitizedDisplayState),
        focused: space.focused
    )
}

public func sanitizedSpaces(_ spaces: [SpaceID: SpaceState]) -> [SpaceID: SpaceState] {
    spaces.mapValues(sanitizedSpaceState)
}

public func focusCycleWindows(
    in world: World,
    focusedWindowID: WindowID?
) -> [WindowMetadata] {
    guard let key = focusedWindowID.flatMap({ observedWorkspaceKey(forVisibleWindow: $0, in: world) })
        ?? focusedWindowID.flatMap({ workspaceKey(forWindow: $0, in: world) })
        ?? activeWorkspaceKeys(in: world).first
    else { return [] }

    let displayState = world.spaces[key.spaceID]?.displays[key.displayID]
    let tiled = displayState.map { Set(occupiedWindows(in: $0.tree)) } ?? []
    let rememberedFloating = displayState.map { Set(sanitizedFloatingIDs(in: $0)) } ?? []
    let observedVisible = observedVisibleWindowIDs(key, in: world)
    let hasObservedVisibleWindows = !observedVisible.isEmpty

    return world.windows.values.filter { metadata in
        guard !metadata.isMinimized,
              !tiled.contains(metadata.id),
              world.windowDisplay[metadata.id] == key.displayID
        else { return false }

        if hasObservedVisibleWindows, !observedVisible.contains(metadata.id) {
            return false
        }
        if let spaceID = world.windowSpace[metadata.id] {
            return spaceID == key.spaceID
        }
        if hasObservedVisibleWindows {
            return true
        }
        return rememberedFloating.contains(metadata.id)
    }
}

public func activeFocusedWindow(in world: World) -> WindowMetadata? {
    let activeKeys = activeWorkspaceKeys(in: world)
    for key in activeKeys {
        guard let focused = world.spaces[key.spaceID]?.focused,
              let metadata = world.windows[focused],
              world.windowDisplay[focused] == key.displayID
        else { continue }
        let observed = observedVisibleWindowIDs(key, in: world)
        if observed.isEmpty || observed.contains(focused) {
            return metadata
        }
    }
    return nil
}

public func isWindowTiled(_ windowID: WindowID, in world: World) -> Bool {
    world.spaces.values.contains { space in
        space.displays.values.contains { displayState in
            occupiedWindows(in: displayState.tree).contains(windowID)
        }
    }
}

public func windowIDs(in displayState: DisplaySpaceState) -> Set<WindowID> {
    Set(occupiedWindows(in: displayState.tree)).union(displayState.floating)
}

public func windowIDs(in space: SpaceState) -> Set<WindowID> {
    space.displays.values.reduce(Set<WindowID>()) { result, displayState in
        result.union(windowIDs(in: displayState))
    }
}

public func trackedWindowIDs(in spaces: [SpaceID: SpaceState]) -> Set<WindowID> {
    spaces.values.reduce(Set<WindowID>()) { result, space in
        result.union(windowIDs(in: space))
    }
}

private struct FloatingIDsAccumulator {
    let tiled: Set<WindowID>
    let seen: Set<WindowID>
    let ordered: [WindowID]

    func adding(_ windowID: WindowID) -> FloatingIDsAccumulator {
        guard !tiled.contains(windowID), !seen.contains(windowID) else { return self }
        return FloatingIDsAccumulator(
            tiled: tiled,
            seen: seen.union([windowID]),
            ordered: ordered + [windowID]
        )
    }
}

private func displayContainingWindow(_ windowID: WindowID, in spaces: [SpaceID: SpaceState]) -> DisplayID? {
    for spaceID in spaces.keys.sorted(by: { $0.raw < $1.raw }) {
        guard let space = spaces[spaceID] else { continue }
        for displayID in space.displays.keys.sorted(by: { $0.raw < $1.raw }) {
            guard let displayState = space.displays[displayID],
                  windowIDs(in: displayState).contains(windowID)
            else { continue }
            return displayID
        }
    }
    return nil
}

public func observedWorkspaceKey(forVisibleWindow windowID: WindowID, in world: World) -> WorkspaceKey? {
    activeWorkspaceKeys(in: world).first { key in
        observedVisibleWindowIDs(key, in: world).contains(windowID)
    }
}

private func spaceContainingWindow(_ windowID: WindowID, in spaces: [SpaceID: SpaceState]) -> SpaceID? {
    for spaceID in spaces.keys.sorted(by: { $0.raw < $1.raw }) {
        guard let space = spaces[spaceID], windowIDs(in: space).contains(windowID) else { continue }
        return spaceID
    }
    return nil
}
