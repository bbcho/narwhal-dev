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
            activeSpace: snapshot.activeSpace,
            spaces: world.spaces,
            windows: world.windows,
            windowDisplay: world.windowDisplay,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
    }
}

func worldByOpeningWindow(_ metadata: WindowMetadata, in world: World) -> World {
    switch windowOpenDecision(metadata, rules: world.config.rules) {
    case .tileOrFloatByDefault(let metadata):
        return worldByTrackingOpenedWindow(metadata, pendingRule: nil, preferredDisplaySlot: nil, in: world)
    case .forceFloat(let metadata):
        return worldByTrackingOpenedWindow(metadata, pendingRule: .forceFloat, preferredDisplaySlot: nil, in: world)
    case .ignore(let id):
        return worldByClosingWindow(id, in: world)
    case .pinToDisplay(let metadata, let slot):
        return worldByTrackingOpenedWindow(metadata, pendingRule: .pinToDisplay(slot: slot), preferredDisplaySlot: slot, in: world)
    case .tileToZone(let metadata, let zoneID):
        return worldByTrackingOpenedWindow(metadata, pendingRule: .tileToZone(zoneID), preferredDisplaySlot: nil, in: world)
    }
}

func worldByClosingWindow(_ windowID: WindowID, in world: World) -> World {
    pruneWorld(world, keepingLiveWindows: Set(world.windows.keys).subtracting([windowID]))
}

private func reconcileCompleteEnvironment(_ snapshot: EnvironmentSnapshot, in world: World) -> World {
    let liveWindows = snapshot.axSnapshot.windows.reduce(into: [:]) { result, metadata in
        result[metadata.id] = metadata
    }
    let liveWindowIDs = Set(liveWindows.keys)
    let previouslyKnownWindowIDs = Set(world.windows.keys)
    let windowDisplay = displayOwnership(for: liveWindows.values, displays: snapshot.displays)
    let pruned = pruneWorld(world, keepingLiveWindows: liveWindowIDs)
    guard let activeSpace = snapshot.activeSpace else {
        let reconciled = World(
            displays: snapshot.displays,
            activeSpace: nil,
            spaces: pruned.spaces,
            windows: liveWindows,
            windowDisplay: windowDisplay,
            windowConstraints: pruned.windowConstraints,
            pendingRules: pruned.pendingRules,
            config: world.config
        )
        return applyOpenRulesForNewWindows(
            liveWindows,
            previouslyKnownWindowIDs: previouslyKnownWindowIDs,
            in: reconciled
        )
    }

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

    let reconciled = World(
        displays: snapshot.displays,
        activeSpace: activeSpace,
        spaces: spaces,
        windows: liveWindows,
        windowDisplay: windowDisplay,
        windowConstraints: pruned.windowConstraints,
        pendingRules: pruned.pendingRules,
        config: world.config
    )
    return applyOpenRulesForNewWindows(
        liveWindows,
        previouslyKnownWindowIDs: previouslyKnownWindowIDs,
        in: reconciled
    )
}

private func applyOpenRulesForNewWindows(
    _ liveWindows: [WindowID: WindowMetadata],
    previouslyKnownWindowIDs: Set<WindowID>,
    in world: World
) -> World {
    liveWindows.keys
        .filter { !previouslyKnownWindowIDs.contains($0) }
        .sorted { $0.raw < $1.raw }
        .reduce(world) { current, windowID in
            guard let metadata = liveWindows[windowID] else { return current }
            return worldByOpeningWindow(metadata, in: current)
        }
}

private func worldByTrackingOpenedWindow(
    _ metadata: WindowMetadata,
    pendingRule: RuleAction?,
    preferredDisplaySlot: Int?,
    in world: World
) -> World {
    let displayID = resolvedDisplayID(
        for: metadata,
        preferredSlot: preferredDisplaySlot,
        displays: world.displays
    )
    var windows = world.windows
    windows[metadata.id] = metadata

    var windowDisplay = world.windowDisplay
    if let displayID {
        windowDisplay[metadata.id] = displayID
    } else {
        windowDisplay.removeValue(forKey: metadata.id)
    }

    var pendingRules = world.pendingRules
    if let pendingRule {
        pendingRules[metadata.id] = pendingRule
    } else {
        pendingRules.removeValue(forKey: metadata.id)
    }

    let spaces = spacesByMovingFloatingWindowIfNeeded(
        metadata.id,
        displayID: displayID,
        spaces: world.spaces,
        activeSpace: world.activeSpace
    )

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        spaces: spaces,
        windows: windows,
        windowDisplay: windowDisplay,
        windowConstraints: world.windowConstraints,
        pendingRules: pendingRules,
        config: world.config
    )
}

private func spacesByMovingFloatingWindowIfNeeded(
    _ windowID: WindowID,
    displayID: DisplayID?,
    spaces: [SpaceID: SpaceState],
    activeSpace: SpaceID?
) -> [SpaceID: SpaceState] {
    guard let activeSpace, let displayID else { return spaces }

    let space = spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    let isTiled = space.displays.values.contains { displayState in
        occupiedWindows(in: displayState.tree).contains(windowID)
    }

    var displayStates = space.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: displayState.tree,
            floating: displayState.floating.filter { $0 != windowID }
        )
    }
    if !isTiled {
        let target = displayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
        displayStates[displayID] = DisplaySpaceState(
            displayID: displayID,
            tree: target.tree,
            floating: target.floating + [windowID]
        )
    }

    var nextSpaces = spaces
    nextSpaces[activeSpace] = SpaceState(id: activeSpace, displays: displayStates, focused: space.focused)
    return nextSpaces
}

private func resolvedDisplayID(
    for metadata: WindowMetadata,
    preferredSlot: Int?,
    displays: [DisplayID: DisplayInfo]
) -> DisplayID? {
    if let preferredSlot,
       let preferredDisplay = displays.values
        .filter({ $0.slot == preferredSlot })
        .sorted(by: { $0.id.raw < $1.id.raw })
        .first {
        return preferredDisplay.id
    }
    return displayContainingFrame(metadata.frame, displays: displays)
}

private func displayOwnership(
    for windows: Dictionary<WindowID, WindowMetadata>.Values,
    displays: [DisplayID: DisplayInfo]
) -> [WindowID: DisplayID] {
    windows.reduce(into: [:]) { result, metadata in
        guard let displayID = displayContainingFrame(metadata.frame, displays: displays) else { return }
        result[metadata.id] = displayID
    }
}

func displayContainingFrame(_ frame: CGRect, displays: [DisplayID: DisplayInfo]) -> DisplayID? {
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
