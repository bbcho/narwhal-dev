import CoreGraphics

public func pruneWorld(_ world: World, keepingLiveWindows liveWindowIDs: Set<WindowID>) -> World {
    let windows = world.windows.filter { liveWindowIDs.contains($0.key) }
    let windowDisplay = world.windowDisplay.filter { liveWindowIDs.contains($0.key) }
    let windowConstraints = world.windowConstraints.filter { liveWindowIDs.contains($0.key) }
    let pendingRules = world.pendingRules.filter { liveWindowIDs.contains($0.key) }
    let spaces = world.spaces.mapValues { space in
        let displays = space.displays.mapValues { displayState in
            DisplaySpaceState(
                displayID: displayState.displayID,
                tree: pruneTree(displayState.tree, keeping: liveWindowIDs),
                floating: displayState.floating.filter { liveWindowIDs.contains($0) }
            )
        }
        let focused = space.focused.flatMap { liveWindowIDs.contains($0) ? $0 : nil }
        return SpaceState(id: space.id, displays: displays, focused: focused)
    }

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: spaces,
        windows: windows,
        windowDisplay: windowDisplay,
        windowConstraints: windowConstraints,
        pendingRules: pendingRules,
        config: world.config
    )
}
