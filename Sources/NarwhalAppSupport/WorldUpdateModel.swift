import CoreGraphics
import NarwhalCore

public func displayStateByUpsertingFloatingWindow(
    _ windowID: WindowID,
    in displayState: DisplaySpaceState
) -> DisplaySpaceState {
    guard !occupiedWindows(in: displayState.tree).contains(windowID),
          !displayState.floating.contains(windowID)
    else {
        return sanitizedDisplayState(displayState)
    }
    return DisplaySpaceState(
        displayID: displayState.displayID,
        tree: displayState.tree,
        floating: displayState.floating + [windowID]
    )
}

public func windowMetadataByRecordingFrame(
    _ frame: CGRect,
    in metadata: WindowMetadata
) -> WindowMetadata {
    WindowMetadata(
        id: metadata.id,
        bundleID: metadata.bundleID,
        title: metadata.title,
        role: metadata.role,
        pid: metadata.pid,
        frame: frame,
        isResizable: metadata.isResizable,
        isMinimized: metadata.isMinimized
    )
}

public func windowsByRecordingWindowFrames(
    _ frames: [WindowID: CGRect],
    in windows: [WindowID: WindowMetadata]
) -> [WindowID: WindowMetadata] {
    windows.mapValues { metadata in
        frames[metadata.id].map { windowMetadataByRecordingFrame($0, in: metadata) } ?? metadata
    }
}

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
    displayStates[displayID] = displayStateByUpsertingFloatingWindow(metadata.id, in: existing)
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

    return World(
        displays: world.displays,
        activeSpace: world.activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: world.spaces,
        windows: windowsByRecordingWindowFrames(frames, in: world.windows),
        windowDisplay: world.windowDisplay,
        windowSpace: world.windowSpace,
        observedVisibleWindows: world.observedVisibleWindows,
        windowConstraints: world.windowConstraints,
        pendingRules: world.pendingRules,
        config: world.config
    )
}
