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

public func reconcileEnvironment(_ snapshot: EnvironmentSnapshot, in world: World) -> World {
    switch snapshot.axSnapshot.quality {
    case .complete:
        return reconcileCompleteEnvironment(snapshot, in: world)
    case .partial, .permissionDenied:
        return World(
            displays: snapshot.displays,
            activeSpace: snapshot.activeSpace ?? world.activeSpace,
            spaces: world.spaces,
            windows: world.windows,
            windowDisplay: world.windowDisplay,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
    }
}

private func reconcileCompleteEnvironment(_ snapshot: EnvironmentSnapshot, in world: World) -> World {
    let activeSpace = snapshot.activeSpace ?? world.activeSpace ?? SpaceID(raw: 1)
    let liveWindows = snapshot.axSnapshot.windows.reduce(into: [:]) { result, metadata in
        result[metadata.id] = metadata
    }
    let liveWindowIDs = Set(liveWindows.keys)
    let windowDisplay = displayOwnership(for: liveWindows.values, displays: snapshot.displays)
    let pruned = pruneWorld(world, keepingLiveWindows: liveWindowIDs)

    var spaces = pruned.spaces
    let previousSpace = spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    var displayStates = previousSpace.displays
    for displayID in snapshot.displays.keys {
        let previous = displayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
        let tiled = Set(occupiedWindows(in: previous.tree))
        let floating = windowDisplay
            .filter { $0.value == displayID && !tiled.contains($0.key) }
            .map(\.key)
            .sorted { $0.raw < $1.raw }
        displayStates[displayID] = DisplaySpaceState(displayID: displayID, tree: previous.tree, floating: floating)
    }

    let focused = previousSpace.focused.flatMap { liveWindowIDs.contains($0) ? $0 : nil }
    spaces[activeSpace] = SpaceState(id: activeSpace, displays: displayStates, focused: focused)

    return World(
        displays: snapshot.displays,
        activeSpace: activeSpace,
        spaces: spaces,
        windows: liveWindows,
        windowDisplay: windowDisplay,
        windowConstraints: pruned.windowConstraints,
        pendingRules: pruned.pendingRules,
        config: world.config
    )
}

private func displayOwnership(
    for windows: Dictionary<WindowID, WindowMetadata>.Values,
    displays: [DisplayID: DisplayInfo]
) -> [WindowID: DisplayID] {
    windows.reduce(into: [:]) { result, metadata in
        guard let displayID = displayContaining(frame: metadata.frame, displays: displays) else { return }
        result[metadata.id] = displayID
    }
}

private func displayContaining(frame: CGRect, displays: [DisplayID: DisplayInfo]) -> DisplayID? {
    if let byIntersection = displays.max(by: { lhs, rhs in
        lhs.value.visibleFrame.intersection(frame).area < rhs.value.visibleFrame.intersection(frame).area
    }), byIntersection.value.visibleFrame.intersection(frame).area > 0 {
        return byIntersection.key
    }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    return displays.min(by: { lhs, rhs in
        lhs.value.visibleFrame.center.distanceSquared(to: center) < rhs.value.visibleFrame.center.distanceSquared(to: center)
    })?.key
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
