import CoreGraphics

public func pruneWorld(_ world: World, keepingLiveWindows liveWindowIDs: Set<WindowID>) -> World {
    let windows = world.windows.filter { liveWindowIDs.contains($0.key) }
    let windowDisplay = world.windowDisplay.filter { liveWindowIDs.contains($0.key) }
    let windowSpace = world.windowSpace.filter { liveWindowIDs.contains($0.key) }
    let observedVisibleWindows = world.observedVisibleWindows.mapValues { $0.intersection(liveWindowIDs) }
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
        observedVisibleWindows: observedVisibleWindows,
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

    let spaces = activeWorkspaceKeys(in: world).reduce(world.spaces) { spaces, key in
        guard let space = spaces[key.spaceID] else { return spaces }
        return spaces.setting(key.spaceID, to: removingWindows(windowIDs, from: space))
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
        observedVisibleWindows: world.observedVisibleWindows.mapValues { $0.subtracting(removedUntrackedWindowIDs) },
        windowConstraints: world.windowConstraints.filter { !removedUntrackedWindowIDs.contains($0.key) },
        pendingRules: world.pendingRules.filter { !removedUntrackedWindowIDs.contains($0.key) },
        config: world.config
    )
}

public func reconcileEnvironment(_ snapshot: EnvironmentSnapshot, in world: World) -> World {
    switch snapshot.axSnapshot.quality {
    case .complete:
        return reconcileCompleteEnvironment(snapshot, in: world)
    case .partial, .permissionDenied, .unavailable:
        return World(
            displays: snapshot.displays,
            activeSpace: snapshot.activeSpace,
            activeSpaceByDisplay: snapshot.activeSpaceByDisplay,
            spaces: world.spaces,
            windows: world.windows,
            windowDisplay: world.windowDisplay,
            windowSpace: world.windowSpace.merging(snapshot.windowSpace) { _, live in live },
            observedVisibleWindows: world.observedVisibleWindows,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
    }
}

func worldByOpeningWindow(_ metadata: WindowMetadata, in world: World) -> World {
    let resolution = resolveWindowOpen(
        metadata,
        managedRules: world.config.managedRules,
        luaRules: world.config.rules
    )
    switch resolution.decision {
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
    switch snapshot.reconciliationMode {
    case .observeOnly, .preserveLayouts:
        return true
    case .activeWorkspaceCleanup:
        break
    case .displayTopologySettled:
        guard case .complete = snapshot.axSnapshot.quality else { return true }
        return false
    }

    guard case .complete = snapshot.axSnapshot.quality else {
        return snapshot.preserveSpaceLayouts
    }

    let liveWindowIDs = Set(snapshot.axSnapshot.windows.map(\.id))
    let hasTrackedMemory = !trackedWindowIDs(in: world.spaces).isEmpty
    let activeSpaceChanged = !world.activeSpaceByDisplay.isEmpty
        ? snapshot.activeSpaceByDisplay != world.activeSpaceByDisplay
        : world.activeSpace != nil && snapshot.activeSpace != world.activeSpace
    return snapshot.preserveSpaceLayouts
        || (snapshot.hasLowTopologyCoverage && hasTrackedMemory)
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
    let liveWindows = Dictionary(
        snapshot.axSnapshot.windows.map { ($0.id, $0) },
        uniquingKeysWith: { _, live in live }
    )
    let liveWindowIDs = Set(liveWindows.keys)
    let previouslyTrackedWindowIDs = trackedWindowIDs(in: world.spaces)
    let liveWindowDisplay = displayOwnership(for: liveWindows.values, displays: snapshot.displays)
    let activeSpaceByDisplay = normalizedActiveSpaceByDisplay(in: snapshot)
    let activeSpaceIDs = Set(activeSpaceByDisplay.values)
    let observedVisibleWindows = observedVisibleWindowsByWorkspace(
        liveWindowIDs: liveWindowIDs,
        liveWindowDisplay: liveWindowDisplay,
        activeSpaceByDisplay: activeSpaceByDisplay
    )
    let mergedWindowSpace = reconciledWindowSpace(
        existing: world.windowSpace,
        snapshot: snapshot.windowSpace,
        liveWindowIDs: liveWindowIDs,
        clearMissingLiveMappings: snapshot.topologyQuality == .managedDisplaySpaces
    )
    if environmentSnapshotPreservesSpaceLayouts(snapshot, in: world) {
        return World(
            displays: snapshot.displays,
            activeSpace: snapshot.activeSpace,
            activeSpaceByDisplay: activeSpaceByDisplay,
            spaces: sanitizedSpaces(world.spaces),
            windows: world.windows.merging(liveWindows) { _, live in live },
            windowDisplay: world.windowDisplay.merging(liveWindowDisplay) { _, live in live },
            windowSpace: mergedWindowSpace,
            observedVisibleWindows: observedVisibleWindows,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
    }

    guard !activeSpaceByDisplay.isEmpty else {
        let reconciled = World(
            displays: snapshot.displays,
            activeSpace: nil,
            activeSpaceByDisplay: [:],
            spaces: sanitizedSpaces(world.spaces),
            windows: world.windows.merging(liveWindows) { _, live in live },
            windowDisplay: world.windowDisplay.merging(liveWindowDisplay) { _, live in live },
            windowSpace: mergedWindowSpace,
            observedVisibleWindows: observedVisibleWindows,
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

    let windows = world.windows
        .filter { !removedActiveSpaceWindowIDs.contains($0.key) }
        .merging(liveWindows) { _, live in live }
    let windowDisplay = world.windowDisplay
        .filter { !removedActiveSpaceWindowIDs.contains($0.key) }
        .merging(liveWindowDisplay) { _, live in live }
    let windowSpace = liveWindowDisplay.keys.reduce(
        mergedWindowSpace.filter { !removedActiveSpaceWindowIDs.contains($0.key) }
    ) { windowSpace, windowID in
        guard let spaceID = snapshot.windowSpace[windowID] else { return windowSpace }
        return windowSpace.setting(windowID, to: spaceID)
    }

    let liveIDsForActiveSpaces = liveWindowIDs.filter { windowID in
        guard let displayID = liveWindowDisplay[windowID] else { return true }
        let liveSpace = mergedWindowSpace[windowID] ?? activeSpaceByDisplay[displayID]
        return liveSpace.map { activeSpaceIDs.contains($0) } ?? true
    }
    let spacesWithoutActiveLiveWindows = world.spaces.reduce(world.spaces) { spaces, pair in
        let (spaceID, space) = pair
        guard !activeSpaceIDs.contains(spaceID) else { return spaces }
        return spaces.setting(spaceID, to: removingWindows(liveIDsForActiveSpaces, from: space))
    }

    let liveIDsByActiveSpace = activeSpaceByDisplay.reduce([SpaceID: Set<WindowID>]()) { result, pair in
        let key = WorkspaceKey(displayID: pair.key, spaceID: pair.value)
        let liveIDs = liveWindowIDsForWorkspace(
            key,
            liveWindowIDs: liveWindowIDs,
            liveWindowDisplay: liveWindowDisplay,
            windowSpace: mergedWindowSpace
        )
        return result.setting(pair.value, to: (result[pair.value] ?? []).union(liveIDs))
    }

    let spaces = activeSpaceByDisplay.reduce(spacesWithoutActiveLiveWindows) { spaces, pair in
        let (displayID, activeSpace) = pair
        let previousSpace = spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
        let previous = previousSpace.displays[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
        let liveIDs = liveWindowIDsForWorkspace(
            WorkspaceKey(displayID: displayID, spaceID: activeSpace),
            liveWindowIDs: liveWindowIDs,
            liveWindowDisplay: liveWindowDisplay,
            windowSpace: mergedWindowSpace
        )
        let tree = snapshot.reconciliationMode == .displayTopologySettled
            ? reconciledTreeAfterDisplayTopologyChange(
                for: WorkspaceKey(displayID: displayID, spaceID: activeSpace),
                liveWindowIDs: liveIDs,
                liveWindows: liveWindows,
                previousSpaces: world.spaces
            )
            : pruneTree(previous.tree, keeping: liveIDs)
        let tiled = Set(occupiedWindows(in: tree))
        let floating = liveWindowDisplay
            .filter { windowID, ownedDisplayID in
                ownedDisplayID == displayID
                    && liveIDs.contains(windowID)
                    && !tiled.contains(windowID)
            }
            .map(\.key)
            .sorted { $0.raw < $1.raw }
        let displayStates = previousSpace.displays
            .filter { snapshot.displays[$0.key] != nil }
            .setting(
                displayID,
                to: DisplaySpaceState(displayID: displayID, tree: tree, floating: floating)
            )

        let focused = previousSpace.focused.flatMap {
            liveIDsByActiveSpace[activeSpace, default: []].contains($0) ? $0 : nil
        }
        return spaces.setting(activeSpace, to: SpaceState(id: activeSpace, displays: displayStates, focused: focused))
    }

    let reconciled = World(
        displays: snapshot.displays,
        activeSpace: snapshot.activeSpace,
        activeSpaceByDisplay: activeSpaceByDisplay,
        spaces: sanitizedSpaces(spaces),
        windows: windows,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace,
        observedVisibleWindows: observedVisibleWindows,
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

private struct DisplayTreeFragment {
    let source: WorkspaceKey
    let tree: Node
    let windowIDs: Set<WindowID>
}

private func reconciledTreeAfterDisplayTopologyChange(
    for target: WorkspaceKey,
    liveWindowIDs: Set<WindowID>,
    liveWindows: [WindowID: WindowMetadata],
    previousSpaces: [SpaceID: SpaceState]
) -> Node {
    let sources = previousSpaces.flatMap { spaceID, space in
        space.displays.map { displayID, state in
            (key: WorkspaceKey(displayID: displayID, spaceID: spaceID), tree: state.tree)
        }
    }.sorted { lhs, rhs in
        let lhsPriority = displayTreeSourcePriority(lhs.key, target: target)
        let rhsPriority = displayTreeSourcePriority(rhs.key, target: target)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.key.spaceID.raw != rhs.key.spaceID.raw { return lhs.key.spaceID.raw < rhs.key.spaceID.raw }
        return lhs.key.displayID.raw < rhs.key.displayID.raw
    }

    let result = sources.reduce((remaining: liveWindowIDs, fragments: [DisplayTreeFragment]())) { result, source in
        let sourceWindowIDs = Set(occupiedWindows(in: source.tree)).intersection(result.remaining)
        guard !sourceWindowIDs.isEmpty else { return result }
        return (
            remaining: result.remaining.subtracting(sourceWindowIDs),
            fragments: result.fragments + [DisplayTreeFragment(
                source: source.key,
                tree: pruneTree(source.tree, keeping: sourceWindowIDs),
                windowIDs: sourceWindowIDs
            )]
        )
    }
    return mergedDisplayTreeFragments(result.fragments, liveWindows: liveWindows)
}

private func displayTreeSourcePriority(_ source: WorkspaceKey, target: WorkspaceKey) -> Int {
    if source == target { return 0 }
    if source.spaceID == target.spaceID { return 1 }
    return 2
}

private func mergedDisplayTreeFragments(
    _ fragments: [DisplayTreeFragment],
    liveWindows: [WindowID: WindowMetadata]
) -> Node {
    guard let first = fragments.first else { return .void }
    guard fragments.count > 1 else { return first.tree }

    let axis = displayTreeMergeAxis(fragments, liveWindows: liveWindows)
    let ordered = fragments.sorted { lhs, rhs in
        let lhsFrame = displayTreeFragmentFrame(lhs, liveWindows: liveWindows)
        let rhsFrame = displayTreeFragmentFrame(rhs, liveWindows: liveWindows)
        let lhsCoordinate = axis == .horizontal ? lhsFrame.midX : lhsFrame.midY
        let rhsCoordinate = axis == .horizontal ? rhsFrame.midX : rhsFrame.midY
        if lhsCoordinate != rhsCoordinate { return lhsCoordinate < rhsCoordinate }
        if lhs.source.spaceID.raw != rhs.source.spaceID.raw {
            return lhs.source.spaceID.raw < rhs.source.spaceID.raw
        }
        return lhs.source.displayID.raw < rhs.source.displayID.raw
    }
    let cells = ordered.compactMap { fragment -> Cell? in
        try? Cell.create(weight: Double(fragment.windowIDs.count), node: fragment.tree).get()
    }
    guard case .success(let split) = Split.create(axis: axis, cells: cells) else {
        return first.tree
    }
    return .split(split)
}

private func displayTreeMergeAxis(
    _ fragments: [DisplayTreeFragment],
    liveWindows: [WindowID: WindowMetadata]
) -> Axis {
    let frames = fragments.map { displayTreeFragmentFrame($0, liveWindows: liveWindows) }
    guard let first = frames.first else { return .horizontal }
    let minX = frames.dropFirst().reduce(first.midX) { min($0, $1.midX) }
    let maxX = frames.dropFirst().reduce(first.midX) { max($0, $1.midX) }
    let minY = frames.dropFirst().reduce(first.midY) { min($0, $1.midY) }
    let maxY = frames.dropFirst().reduce(first.midY) { max($0, $1.midY) }
    return maxX - minX >= maxY - minY ? .horizontal : .vertical
}

private func displayTreeFragmentFrame(
    _ fragment: DisplayTreeFragment,
    liveWindows: [WindowID: WindowMetadata]
) -> CGRect {
    fragment.windowIDs.compactMap { liveWindows[$0]?.frame }.reduce(CGRect.null) { $0.union($1) }
}

private func containsTrackedInactiveSpaceWindows(
    _ liveWindowIDs: Set<WindowID>,
    activeSpaces: Set<SpaceID>,
    fallbackActiveSpace: SpaceID?,
    spaces: [SpaceID: SpaceState]
) -> Bool {
    let activeSpaces = activeSpaces.isEmpty ? Set(fallbackActiveSpace.map { [$0] } ?? []) : activeSpaces
    guard !activeSpaces.isEmpty else { return false }
    let inactiveWindowIDs = spaces
        .filter { !activeSpaces.contains($0.key) }
        .reduce(Set<WindowID>()) { result, pair in result.union(windowIDs(in: pair.value)) }
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
    let activeWindowIDs = activeSpaces.reduce(Set<WindowID>()) { result, spaceID in
        guard let space = spaces[spaceID] else { return result }
        return result.union(windowIDs(in: space))
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

private func reconciledWindowSpace(
    existing: [WindowID: SpaceID],
    snapshot: [WindowID: SpaceID],
    liveWindowIDs: Set<WindowID>,
    clearMissingLiveMappings: Bool
) -> [WindowID: SpaceID] {
    liveWindowIDs.reduce(existing) { result, windowID in
        if let spaceID = snapshot[windowID] {
            return result.setting(windowID, to: spaceID)
        } else if clearMissingLiveMappings {
            return result.removing(windowID)
        }
        return result
    }
}

private func removedWindowIDsFromActiveWorkspaces(
    activeSpaceByDisplay: [DisplayID: SpaceID],
    liveWindowIDs: Set<WindowID>,
    liveWindowDisplay: [WindowID: DisplayID],
    windowSpace: [WindowID: SpaceID],
    spaces: [SpaceID: SpaceState]
) -> Set<WindowID> {
    activeSpaceByDisplay.reduce(Set<WindowID>()) { removed, pair in
        let key = WorkspaceKey(displayID: pair.key, spaceID: pair.value)
        guard let displayState = spaces[key.spaceID]?.displays[key.displayID] else { return removed }
        let liveIDs = liveWindowIDsForWorkspace(
            key,
            liveWindowIDs: liveWindowIDs,
            liveWindowDisplay: liveWindowDisplay,
            windowSpace: windowSpace
        )
        return removed.union(windowIDs(in: displayState).subtracting(liveIDs))
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

private func observedVisibleWindowsByWorkspace(
    liveWindowIDs: Set<WindowID>,
    liveWindowDisplay: [WindowID: DisplayID],
    activeSpaceByDisplay: [DisplayID: SpaceID]
) -> [WorkspaceKey: Set<WindowID>] {
    liveWindowIDs.reduce([WorkspaceKey: Set<WindowID>]()) { result, windowID in
        guard let displayID = liveWindowDisplay[windowID],
              let spaceID = activeSpaceByDisplay[displayID]
        else { return result }
        let key = WorkspaceKey(displayID: displayID, spaceID: spaceID)
        return result.setting(key, to: (result[key] ?? []).union([windowID]))
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
    let targetActiveSpace = displayID.flatMap { activeSpaceID(for: $0, in: world) } ?? world.activeSpace
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
        windows: world.windows.setting(metadata.id, to: metadata),
        windowDisplay: world.windowDisplay.settingOrRemoving(metadata.id, to: displayID),
        windowSpace: world.windowSpace.settingOrRemoving(metadata.id, to: targetActiveSpace),
        observedVisibleWindows: observedVisibleWindowsByAdding(
            metadata.id,
            displayID: displayID,
            spaceID: targetActiveSpace,
            to: world.observedVisibleWindows
        ),
        windowConstraints: constraintsByApplyingManagedRule(to: metadata, in: world),
        pendingRules: world.pendingRules.settingOrRemoving(metadata.id, to: pendingRule),
        config: world.config
    )
}

private func constraintsByApplyingManagedRule(
    to metadata: WindowMetadata,
    in world: World
) -> [WindowID: WindowConstraints] {
    guard let constraints = managedConstraints(for: metadata, rules: world.config.managedRules) else {
        return world.windowConstraints
    }
    return world.windowConstraints.setting(
        metadata.id,
        to: (world.windowConstraints[metadata.id] ?? WindowConstraints()).merged(with: constraints)
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

    let ejectedDisplayStates = space.displays.mapValues { displayState in
        DisplaySpaceState(
            displayID: displayState.displayID,
            tree: displayState.tree,
            floating: displayState.floating.filter { $0 != windowID }
        )
    }
    let displayStates: [DisplayID: DisplaySpaceState]
    if isTiled {
        displayStates = ejectedDisplayStates
    } else {
        let target = ejectedDisplayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
        displayStates = ejectedDisplayStates.setting(displayID, to: DisplaySpaceState(
            displayID: displayID,
            tree: target.tree,
            floating: target.floating + [windowID]
        ))
    }

    return spaces.setting(activeSpace, to: SpaceState(id: activeSpace, displays: displayStates, focused: space.focused))
}

private func observedVisibleWindowsByAdding(
    _ windowID: WindowID,
    displayID: DisplayID?,
    spaceID: SpaceID?,
    to observed: [WorkspaceKey: Set<WindowID>]
) -> [WorkspaceKey: Set<WindowID>] {
    guard let displayID, let spaceID else { return observed }
    let key = WorkspaceKey(displayID: displayID, spaceID: spaceID)
    return observed.setting(key, to: (observed[key] ?? []).union([windowID]))
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
    Dictionary(
        windows.compactMap { metadata in
            displayContainingFrame(metadata.frame, displays: displays).map { (metadata.id, $0) }
        },
        uniquingKeysWith: { _, replacement in replacement }
    )
}
