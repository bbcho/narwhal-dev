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

    let workspaceKey = WorkspaceKey(displayID: displayID, spaceID: activeSpace)
    let space = world.spaces[activeSpace] ?? SpaceState(id: activeSpace, displays: [:], focused: nil)
    let existingDisplayState = space.displays[displayID]
        ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
    let displayState = displayStateByUpsertingFloatingWindow(metadata.id, in: existingDisplayState)
    let displayStates = space.displays.merging([displayID: displayState]) { _, replacement in replacement }
    let spaces = world.spaces.merging([
        activeSpace: SpaceState(id: activeSpace, displays: displayStates, focused: space.focused)
    ]) { _, replacement in replacement }
    let visibleWindows = (world.observedVisibleWindows[workspaceKey] ?? []).union([metadata.id])

    return .success(World(
        displays: displays,
        activeSpace: world.activeSpace ?? activeSpace,
        activeSpaceByDisplay: world.activeSpaceByDisplay,
        spaces: sanitizedSpaces(spaces),
        windows: world.windows.merging([metadata.id: metadata]) { _, replacement in replacement },
        windowDisplay: world.windowDisplay.merging([metadata.id: displayID]) { _, replacement in replacement },
        windowSpace: world.windowSpace.merging([metadata.id: activeSpace]) { _, replacement in replacement },
        observedVisibleWindows: world.observedVisibleWindows.merging(
            [workspaceKey: visibleWindows]
        ) { _, replacement in replacement },
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
