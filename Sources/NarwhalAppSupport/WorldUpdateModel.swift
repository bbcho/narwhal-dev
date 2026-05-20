import CoreGraphics
import NarwhalCore

public func worldByUpsertingActiveWindow(
    _ metadata: WindowMetadata,
    displayID: DisplayID,
    displays: [DisplayID: DisplayInfo],
    in world: World
) -> Result<World, CommandError> {
    guard let activeSpace = activeSpaceID(for: displayID, in: world) else {
        return .failure(.activeSpaceUnavailable)
    }

    var windows = world.windows
    windows[metadata.id] = metadata

    var windowDisplay = world.windowDisplay
    windowDisplay[metadata.id] = displayID

    var windowSpace = world.windowSpace
    windowSpace[metadata.id] = activeSpace

    let workspaceKey = WorkspaceKey(displayID: displayID, spaceID: activeSpace)
    var observedVisibleWindows = world.observedVisibleWindows
    observedVisibleWindows[workspaceKey, default: []].insert(metadata.id)

    var spaces = world.spaces
    let space = spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    var displayStates = space.displays
    let existing = displayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
    if !occupiedWindows(in: existing.tree).contains(metadata.id),
       !existing.floating.contains(metadata.id) {
        displayStates[displayID] = DisplaySpaceState(
            displayID: displayID,
            tree: existing.tree,
            floating: existing.floating + [metadata.id]
        )
    } else {
        displayStates[displayID] = sanitizedDisplayState(existing)
    }
    spaces[activeSpace] = SpaceState(id: activeSpace, displays: displayStates, focused: space.focused)

    return .success(World(
        displays: displays,
        activeSpace: world.activeSpace ?? activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: sanitizedSpaces(spaces),
        windows: windows,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace,
        observedVisibleWindows: observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    ))
}

public func worldByRecordingWindowFrames(
    _ frames: [WindowID: CGRect],
    in world: World
) -> World {
    guard !frames.isEmpty else { return world }

    var windows = world.windows
    for (id, frame) in frames {
        guard let old = windows[id] else { continue }
        windows[id] = WindowMetadata(
            id: old.id,
            bundleID: old.bundleID,
            title: old.title,
            role: old.role,
            pid: old.pid,
            frame: frame,
            isResizable: old.isResizable,
            isMinimized: old.isMinimized
        )
    }

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces,
        windows: windows,
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    )
}
