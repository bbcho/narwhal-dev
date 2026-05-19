import CoreGraphics

public func pruneWorld(_ world: World, keepingLiveWindows liveWindowIDs: Set<WindowID>) -> World {
    let windows = world.windows.filter { liveWindowIDs.contains($0.key) }
    let windowDisplay = world.windowDisplay.filter { liveWindowIDs.contains($0.key) }
    let windowSpace = world.windowSpace.filter { liveWindowIDs.contains($0.key) }
    let windowConstraints = world.windowConstraints.filter { liveWindowIDs.contains($0.key) }
    let pendingRules = world.pendingRules.filter { liveWindowIDs.contains($0.key) }
    let spaces = sanitizedSpaces(world.spaces.mapValues { space in
        let displays = space.displays.mapValues { displayState in
            DisplaySpaceState(
                displayID: displayState.displayID,
                tree: pruneTree(displayState.tree, keeping: liveWindowIDs),
                floating: displayState.floating.filter { liveWindowIDs.contains($0) }
            )
        }
        let focused = space.focused.flatMap { liveWindowIDs.contains($0) ? $0 : nil }
        return SpaceState(id: space.id, displays: displays, focused: focused)
    })

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: spaces,
        windows: windows,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace,
        windowConstraints: windowConstraints,
        pendingRules: pendingRules,
        config: world.config
    )
}

public func pruneActiveSpace(_ world: World, keepingLiveWindows liveWindowIDs: Set<WindowID>) -> World {
    let removedActiveSpaceWindowIDs = activeSpaceWindowIDs(in: world).subtracting(liveWindowIDs)
    return removeWindowsFromActiveSpace(removedActiveSpaceWindowIDs, in: world)
}

public func removeWindowsFromActiveSpace(_ windowIDs: Set<WindowID>, in world: World) -> World {
    guard !windowIDs.isEmpty else { return world }

    var spaces = world.spaces
    for key in activeWorkspaceKeys(in: world) {
        guard let space = spaces[key.spaceID] else { continue }
        spaces[key.spaceID] = removingWindows(windowIDs, from: space)
    }
    let removedUntrackedWindowIDs = windowIDs.subtracting(trackedWindowIDs(in: spaces))

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: sanitizedSpaces(spaces),
        windows: world.windows.filter { !removedUntrackedWindowIDs.contains($0.key) },
        windowDisplay: world.windowDisplay.filter { !removedUntrackedWindowIDs.contains($0.key) },
        windowSpace: world.windowSpace.filter { !removedUntrackedWindowIDs.contains($0.key) },
        windowConstraints: world.windowConstraints.filter { !removedUntrackedWindowIDs.contains($0.key) },
        pendingRules: world.pendingRules.filter { !removedUntrackedWindowIDs.contains($0.key) },
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
            activeSpaceByDisplay: snapshot.activeSpaceByDisplay,
            spaces: world.spaces,
            windows: world.windows,
            windowDisplay: world.windowDisplay,
            windowSpace: world.windowSpace.merging(snapshot.windowSpace) { _, live in live },
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

public func environmentSnapshotPreservesSpaceLayouts(_ snapshot: EnvironmentSnapshot, in world: World) -> Bool {
    guard case .complete = snapshot.axSnapshot.quality else {
        return snapshot.preserveSpaceLayouts
    }

    let liveWindowIDs = Set(snapshot.axSnapshot.windows.map(\.id))
    let activeSpaceChanged = !world.activeSpaceByDisplay.isEmpty
        ? snapshot.activeSpaceByDisplay != world.activeSpaceByDisplay
        : world.activeSpace != nil && snapshot.activeSpace != world.activeSpace
    return snapshot.preserveSpaceLayouts
        || activeSpaceChanged
        || containsTrackedInactiveSpaceWindows(
            liveWindowIDs,
            activeSpaces: Set(snapshot.activeSpaceByDisplay.values),
            fallbackActiveSpace: snapshot.activeSpace,
            spaces: world.spaces
        )
        || containsBulkUntrackedWindowExpansion(
            liveWindowIDs,
            activeSpaces: Set(snapshot.activeSpaceByDisplay.values),
            fallbackActiveSpace: snapshot.activeSpace,
            spaces: world.spaces
        )
}

private func reconcileCompleteEnvironment(_ snapshot: EnvironmentSnapshot, in world: World) -> World {
    let liveWindows = snapshot.axSnapshot.windows.reduce(into: [:]) { result, metadata in
        result[metadata.id] = metadata
    }
    let liveWindowIDs = Set(liveWindows.keys)
    let previouslyTrackedWindowIDs = trackedWindowIDs(in: world.spaces)
    let liveWindowDisplay = displayOwnership(for: liveWindows.values, displays: snapshot.displays)
    let activeSpaceByDisplay = normalizedActiveSpaceByDisplay(in: snapshot)
    let activeSpaceIDs = Set(activeSpaceByDisplay.values)
    let mergedWindowSpace = world.windowSpace.merging(snapshot.windowSpace) { _, live in live }
    if environmentSnapshotPreservesSpaceLayouts(snapshot, in: world) {
        var windows = world.windows
        windows.merge(liveWindows) { _, live in live }

        var windowDisplay = world.windowDisplay
        windowDisplay.merge(liveWindowDisplay) { _, live in live }

        return World(
            displays: snapshot.displays,
            activeSpace: snapshot.activeSpace,
            activeSpaceByDisplay: activeSpaceByDisplay,
            spaces: sanitizedSpaces(world.spaces),
            windows: windows,
            windowDisplay: windowDisplay,
            windowSpace: mergedWindowSpace,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
    }

    guard !activeSpaceByDisplay.isEmpty else {
        var windows = world.windows
        windows.merge(liveWindows) { _, live in live }

        var windowDisplay = world.windowDisplay
        windowDisplay.merge(liveWindowDisplay) { _, live in live }

        let reconciled = World(
            displays: snapshot.displays,
            activeSpace: nil,
            activeSpaceByDisplay: [:],
            spaces: sanitizedSpaces(world.spaces),
            windows: windows,
            windowDisplay: windowDisplay,
            windowSpace: mergedWindowSpace,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
        return applyOpenRulesForNewWindows(
            liveWindows,
            previouslyTrackedWindowIDs: previouslyTrackedWindowIDs,
            in: reconciled
        )
    }

    let removedActiveSpaceWindowIDs = removedWindowIDsFromActiveWorkspaces(
        activeSpaceByDisplay: activeSpaceByDisplay,
        liveWindowIDs: liveWindowIDs,
        liveWindowDisplay: liveWindowDisplay,
        windowSpace: mergedWindowSpace,
        spaces: world.spaces
    )

    var windows = world.windows.filter { !removedActiveSpaceWindowIDs.contains($0.key) }
    windows.merge(liveWindows) { _, live in live }

    var windowDisplay = world.windowDisplay.filter { !removedActiveSpaceWindowIDs.contains($0.key) }
    windowDisplay.merge(liveWindowDisplay) { _, live in live }

    var windowSpace = mergedWindowSpace.filter { !removedActiveSpaceWindowIDs.contains($0.key) }
    for (windowID, displayID) in liveWindowDisplay {
        if let spaceID = snapshot.windowSpace[windowID] {
            windowSpace[windowID] = spaceID
        } else if windowSpace[windowID] == nil,
                  let spaceID = activeSpaceByDisplay[displayID] {
            windowSpace[windowID] = spaceID
        }
    }

    var spaces = world.spaces
    let liveIDsForActiveSpaces = liveWindowIDs.filter { windowID in
        guard let displayID = liveWindowDisplay[windowID] else { return true }
        let liveSpace = mergedWindowSpace[windowID] ?? activeSpaceByDisplay[displayID]
        return liveSpace.map { activeSpaceIDs.contains($0) } ?? true
    }
    for (spaceID, space) in spaces where !activeSpaceIDs.contains(spaceID) {
        spaces[spaceID] = removingWindows(liveIDsForActiveSpaces, from: space)
    }

    let liveIDsByActiveSpace = activeSpaceByDisplay.reduce(into: [SpaceID: Set<WindowID>]()) { result, pair in
        let key = WorkspaceKey(displayID: pair.key, spaceID: pair.value)
        result[pair.value, default: []].formUnion(liveWindowIDsForWorkspace(
            key,
            liveWindowIDs: liveWindowIDs,
            liveWindowDisplay: liveWindowDisplay,
            windowSpace: mergedWindowSpace
        ))
    }

    for (displayID, activeSpace) in activeSpaceByDisplay {
        let previousSpace = spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
        var displayStates = previousSpace.displays
        let previous = displayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
        let liveIDs = liveWindowIDsForWorkspace(
            WorkspaceKey(displayID: displayID, spaceID: activeSpace),
            liveWindowIDs: liveWindowIDs,
            liveWindowDisplay: liveWindowDisplay,
            windowSpace: mergedWindowSpace
        )
        let tree = pruneTree(previous.tree, keeping: liveIDs)
        let tiled = Set(occupiedWindows(in: tree))
        let floating = liveWindowDisplay
            .filter { windowID, ownedDisplayID in
                ownedDisplayID == displayID
                    && liveIDs.contains(windowID)
                    && !tiled.contains(windowID)
            }
            .map(\.key)
            .sorted { $0.raw < $1.raw }
        displayStates[displayID] = DisplaySpaceState(displayID: displayID, tree: tree, floating: floating)

        let focused = previousSpace.focused.flatMap {
            liveIDsByActiveSpace[activeSpace, default: []].contains($0) ? $0 : nil
        }
        spaces[activeSpace] = SpaceState(id: activeSpace, displays: displayStates, focused: focused)
    }

    let reconciled = World(
        displays: snapshot.displays,
        activeSpace: snapshot.activeSpace,
        activeSpaceByDisplay: activeSpaceByDisplay,
        spaces: sanitizedSpaces(spaces),
        windows: windows,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace,
        windowConstraints: world.windowConstraints.filter { !removedActiveSpaceWindowIDs.contains($0.key) },
        pendingRules: world.pendingRules.filter { !removedActiveSpaceWindowIDs.contains($0.key) },
        config: world.config
    )
    return applyOpenRulesForNewWindows(
        liveWindows,
        previouslyTrackedWindowIDs: previouslyTrackedWindowIDs,
        in: reconciled
    )
}

private func containsTrackedInactiveSpaceWindows(
    _ liveWindowIDs: Set<WindowID>,
    activeSpaces: Set<SpaceID>,
    fallbackActiveSpace: SpaceID?,
    spaces: [SpaceID: SpaceState]
) -> Bool {
    let activeSpaces = activeSpaces.isEmpty ? Set(fallbackActiveSpace.map { [$0] } ?? []) : activeSpaces
    guard !activeSpaces.isEmpty else { return false }
    let inactiveWindowIDs = spaces.reduce(into: Set<WindowID>()) { result, pair in
        guard !activeSpaces.contains(pair.key) else { return }
        result.formUnion(windowIDs(in: pair.value))
    }
    return !liveWindowIDs.isDisjoint(with: inactiveWindowIDs)
}

private func containsBulkUntrackedWindowExpansion(
    _ liveWindowIDs: Set<WindowID>,
    activeSpaces: Set<SpaceID>,
    fallbackActiveSpace: SpaceID?,
    spaces: [SpaceID: SpaceState]
) -> Bool {
    let activeSpaces = activeSpaces.isEmpty ? Set(fallbackActiveSpace.map { [$0] } ?? []) : activeSpaces
    guard !activeSpaces.isEmpty else { return false }
    let activeWindowIDs = activeSpaces.reduce(into: Set<WindowID>()) { result, spaceID in
        guard let space = spaces[spaceID] else { return }
        result.formUnion(windowIDs(in: space))
    }
    guard !activeWindowIDs.isEmpty else { return false }

    let trackedWindowIDs = trackedWindowIDs(in: spaces)
    let untrackedLiveWindowCount = liveWindowIDs.subtracting(trackedWindowIDs).count
    guard untrackedLiveWindowCount >= 5 else { return false }

    return activeWindowIDs.isSubset(of: liveWindowIDs)
        && liveWindowIDs.count >= activeWindowIDs.count * 2
}

private func normalizedActiveSpaceByDisplay(in snapshot: EnvironmentSnapshot) -> [DisplayID: SpaceID] {
    if !snapshot.activeSpaceByDisplay.isEmpty {
        return snapshot.activeSpaceByDisplay
    }
    guard let activeSpace = snapshot.activeSpace else { return [:] }
    return Dictionary(uniqueKeysWithValues: snapshot.displays.keys.map { ($0, activeSpace) })
}

private func removedWindowIDsFromActiveWorkspaces(
    activeSpaceByDisplay: [DisplayID: SpaceID],
    liveWindowIDs: Set<WindowID>,
    liveWindowDisplay: [WindowID: DisplayID],
    windowSpace: [WindowID: SpaceID],
    spaces: [SpaceID: SpaceState]
) -> Set<WindowID> {
    activeSpaceByDisplay.reduce(into: Set<WindowID>()) { removed, pair in
        let key = WorkspaceKey(displayID: pair.key, spaceID: pair.value)
        guard let displayState = spaces[key.spaceID]?.displays[key.displayID] else { return }
        let liveIDs = liveWindowIDsForWorkspace(
            key,
            liveWindowIDs: liveWindowIDs,
            liveWindowDisplay: liveWindowDisplay,
            windowSpace: windowSpace
        )
        removed.formUnion(windowIDs(in: displayState).subtracting(liveIDs))
    }
}

private func liveWindowIDsForWorkspace(
    _ key: WorkspaceKey,
    liveWindowIDs: Set<WindowID>,
    liveWindowDisplay: [WindowID: DisplayID],
    windowSpace: [WindowID: SpaceID]
) -> Set<WindowID> {
    return liveWindowIDs.filter { windowID in
        guard liveWindowDisplay[windowID] == key.displayID else { return false }
        guard let spaceID = windowSpace[windowID] else { return true }
        return spaceID == key.spaceID
    }
}

private func applyOpenRulesForNewWindows(
    _ liveWindows: [WindowID: WindowMetadata],
    previouslyTrackedWindowIDs: Set<WindowID>,
    in world: World
) -> World {
    liveWindows.keys
        .filter { !previouslyTrackedWindowIDs.contains($0) }
        .sorted { $0.raw < $1.raw }
        .reduce(world) { current, windowID in
            guard let metadata = liveWindows[windowID] else { return current }
            return worldByOpeningWindow(metadata, in: current)
        }
}

private func removingWindows(_ windowIDs: Set<WindowID>, from space: SpaceState) -> SpaceState {
    guard !windowIDs.isEmpty else { return space }
    let displays = space.displays.mapValues { displayState in
        let keptTiled = Set(occupiedWindows(in: displayState.tree)).subtracting(windowIDs)
        return DisplaySpaceState(
            displayID: displayState.displayID,
            tree: pruneTree(displayState.tree, keeping: keptTiled),
            floating: displayState.floating.filter { !windowIDs.contains($0) }
        )
    }
    let focused = space.focused.flatMap { windowIDs.contains($0) ? nil : $0 }
    return SpaceState(id: space.id, displays: displays, focused: focused)
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

    let targetActiveSpace = displayID.flatMap { activeSpaceID(for: $0, in: world) } ?? world.activeSpace
    var windowSpace = world.windowSpace
    if let targetActiveSpace {
        windowSpace[metadata.id] = targetActiveSpace
    } else {
        windowSpace.removeValue(forKey: metadata.id)
    }

    let spaces = spacesByMovingFloatingWindowIfNeeded(
        metadata.id,
        displayID: displayID,
        spaces: world.spaces,
        activeSpace: targetActiveSpace
    )

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: sanitizedSpaces(spaces),
        windows: windows,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace,
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
