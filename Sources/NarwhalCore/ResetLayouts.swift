import CoreGraphics
import Foundation

public func shuffledResetLayout<Generator: RandomNumberGenerator>(
    in world: World,
    using generator: inout Generator
) -> Result<Layout, CommandError> {
    guard world.activeSpace != nil else {
        return .failure(.activeSpaceUnavailable)
    }

    let windowsByDisplay = resizableVisibleWindowsByDisplay(in: world)
    let tiled = resetLayoutTiledFrames(in: world, windowsByDisplay: windowsByDisplay) { windows, frame, innerGap in
        let shuffled = randomScreenOrder(windows, using: &generator)
        let frames = randomQuarterFrames(
            count: shuffled.count,
            in: frame,
            innerGap: innerGap,
            using: &generator
        )
        return resetFrameAssignments(windows: shuffled, frames: frames)
    }

    return .success(Layout(tiled: tiled, floatingZOrder: [], hidden: []))
}

public func shuffledResetLayout<Generator: RandomNumberGenerator>(
    for spaceID: SpaceID,
    in world: World,
    using generator: inout Generator
) -> Result<Layout, CommandError> {
    guard world.spaces[spaceID] != nil else { return .failure(.spaceNotFound(spaceID)) }
    return .success(shuffledResetLayout(
        windowsByDisplay: resizableVisibleWindowsByDisplay(in: world, spaceID: spaceID),
        world: world,
        using: &generator
    ))
}

public func cascadeResetLayout(in world: World) -> Result<Layout, CommandError> {
    guard world.activeSpace != nil else {
        return .failure(.activeSpaceUnavailable)
    }

    let windowsByDisplay = resizableVisibleWindowsByDisplay(in: world)
    let tiled = resetLayoutTiledFrames(in: world, windowsByDisplay: windowsByDisplay) { windows, frame, innerGap in
        let ordered = screenOrdered(windows)
        let frames = cascadedQuarterFrames(count: ordered.count, in: frame, innerGap: innerGap)
        return resetFrameAssignments(windows: ordered, frames: frames)
    }

    return .success(Layout(tiled: tiled, floatingZOrder: [], hidden: []))
}

public func cascadeResetLayout(for spaceID: SpaceID, in world: World) -> Result<Layout, CommandError> {
    guard world.spaces[spaceID] != nil else { return .failure(.spaceNotFound(spaceID)) }
    return .success(cascadeResetLayout(
        windowsByDisplay: resizableVisibleWindowsByDisplay(in: world, spaceID: spaceID),
        world: world
    ))
}

public func maximizeResetLayout(windowID: WindowID, in world: World) -> Result<Layout, CommandError> {
    guard let metadata = world.windows[windowID] else {
        return .failure(.windowNotFound(windowID))
    }
    guard metadata.isResizable else {
        return .failure(.windowNotResizable(windowID))
    }
    guard world.activeSpace != nil else {
        return .failure(.activeSpaceUnavailable)
    }
    guard let displayID = world.windowDisplay[windowID] else {
        return .failure(.displayUnknownForWindow(windowID))
    }
    guard let display = world.displays[displayID] else {
        return .failure(.displayNotFound(displayID))
    }

    let frame = applyingOuterGaps(world.config.gaps.outer, to: display.visibleFrame)
    return .success(Layout(tiled: [windowID: frame], floatingZOrder: [], hidden: []))
}

private func resizableVisibleWindowsByDisplay(in world: World) -> [DisplayID: [WindowMetadata]] {
    let observedActiveWindowIDs = activeObservedVisibleWindowIDs(in: world)
    let activeWindowIDs = observedActiveWindowIDs.isEmpty ? activeSpaceWindowIDs(in: world) : observedActiveWindowIDs
    let activeSpaceIDs = Set(activeWorkspaceKeys(in: world).map(\.spaceID))
    let displayWindows = world.windows.values.compactMap { window -> (DisplayID, WindowMetadata)? in
        guard activeWindowIDs.contains(window.id),
              window.isResizable,
              !window.isMinimized,
              let displayID = world.windowDisplay[window.id],
              world.displays[displayID] != nil
        else { return nil }
        if let mappedSpaceID = world.windowSpace[window.id],
           !activeSpaceIDs.contains(mappedSpaceID) {
            return nil
        }
        return (displayID, window)
    }
    return Dictionary(grouping: displayWindows, by: \.0).mapValues { entries in
        entries.map(\.1)
    }
}

private func resizableVisibleWindowsByDisplay(
    in world: World,
    spaceID: SpaceID
) -> [DisplayID: [WindowMetadata]] {
    guard let space = world.spaces[spaceID] else { return [:] }
    let tracked = windowIDs(in: space)
    let entries = world.windows.values.compactMap { window -> (DisplayID, WindowMetadata)? in
        guard tracked.contains(window.id),
              window.isResizable,
              !window.isMinimized,
              let displayID = world.windowDisplay[window.id],
              space.displays[displayID] != nil
        else { return nil }
        return (displayID, window)
    }
    return Dictionary(grouping: entries, by: \.0).mapValues { $0.map(\.1) }
}

private func shuffledResetLayout<Generator: RandomNumberGenerator>(
    windowsByDisplay: [DisplayID: [WindowMetadata]],
    world: World,
    using generator: inout Generator
) -> Layout {
    let tiled = resetLayoutTiledFrames(in: world, windowsByDisplay: windowsByDisplay) { windows, frame, innerGap in
        let shuffled = randomScreenOrder(windows, using: &generator)
        let frames = randomQuarterFrames(count: shuffled.count, in: frame, innerGap: innerGap, using: &generator)
        return resetFrameAssignments(windows: shuffled, frames: frames)
    }
    return Layout(tiled: tiled, floatingZOrder: [], hidden: [])
}

private func cascadeResetLayout(
    windowsByDisplay: [DisplayID: [WindowMetadata]],
    world: World
) -> Layout {
    let tiled = resetLayoutTiledFrames(in: world, windowsByDisplay: windowsByDisplay) { windows, frame, innerGap in
        let ordered = screenOrdered(windows)
        let frames = cascadedQuarterFrames(count: ordered.count, in: frame, innerGap: innerGap)
        return resetFrameAssignments(windows: ordered, frames: frames)
    }
    return Layout(tiled: tiled, floatingZOrder: [], hidden: [])
}

private func resetLayoutTiledFrames(
    in world: World,
    windowsByDisplay: [DisplayID: [WindowMetadata]],
    assignmentsForDisplay: ([WindowMetadata], CGRect, Double) -> [(WindowID, CGRect)]
) -> [WindowID: CGRect] {
    windowsByDisplay.keys.sorted(by: { $0.raw < $1.raw }).reduce([WindowID: CGRect]()) { tiled, displayID in
        guard let display = world.displays[displayID],
              let windows = windowsByDisplay[displayID],
              !windows.isEmpty
        else { return tiled }

        let frame = applyingOuterGaps(world.config.gaps.outer, to: display.visibleFrame)
        let assignments = assignmentsForDisplay(windows, frame, world.config.gaps.inner)
        return tiled.merging(
            Dictionary(assignments, uniquingKeysWith: { _, replacement in replacement }),
            uniquingKeysWith: { _, replacement in replacement }
        )
    }
}

private func resetFrameAssignments(windows: [WindowMetadata], frames: [CGRect]) -> [(WindowID, CGRect)] {
    zip(windows, frames).map { window, frame in
        (window.id, frame)
    }
}

private func randomScreenOrder<Generator: RandomNumberGenerator>(
    _ windows: [WindowMetadata],
    using generator: inout Generator
) -> [WindowMetadata] {
    screenOrdered(windows).shuffled(using: &generator)
}

private func screenOrdered(_ windows: [WindowMetadata]) -> [WindowMetadata] {
    windows.sorted { lhs, rhs in
        let lhsFrame = lhs.frame.standardized
        let rhsFrame = rhs.frame.standardized
        if lhsFrame.minY != rhsFrame.minY {
            return lhsFrame.minY < rhsFrame.minY
        }
        if lhsFrame.minX != rhsFrame.minX {
            return lhsFrame.minX < rhsFrame.minX
        }
        return lhs.id.raw < rhs.id.raw
    }
}

private func randomQuarterFrames<Generator: RandomNumberGenerator>(
    count: Int,
    in frame: CGRect,
    innerGap: Double,
    using generator: inout Generator
) -> [CGRect] {
    guard count > 0, frame.width > 0, frame.height > 0 else { return [] }

    let width = frame.width / 2
    let height = frame.height / 2
    let maxXOffset = max(0, frame.width - width)
    let maxYOffset = max(0, frame.height - height)

    return (0..<count).map { _ in
        let xOffset = maxXOffset * CGFloat.random(in: 0...1, using: &generator)
        let yOffset = maxYOffset * CGFloat.random(in: 0...1, using: &generator)
        return CGRect(
            x: frame.minX + xOffset,
            y: frame.minY + yOffset,
            width: width,
            height: height
        )
        .insetBy(dx: innerGap / 2, dy: innerGap / 2)
        .standardized
    }
}

private func cascadedQuarterFrames(count: Int, in frame: CGRect, innerGap: Double) -> [CGRect] {
    guard count > 0, frame.width > 0, frame.height > 0 else { return [] }

    let width = frame.width / 2
    let height = frame.height / 2
    let maxXOffset = max(0, frame.width - width)
    let maxYOffset = max(0, frame.height - height)
    let step = min(width, height) * 0.08

    return (0..<count).map { index in
        let xOffset = maxXOffset == 0 ? 0 : (CGFloat(index) * step).truncatingRemainder(dividingBy: maxXOffset + step)
        let yOffset = maxYOffset == 0 ? 0 : (CGFloat(index) * step).truncatingRemainder(dividingBy: maxYOffset + step)
        return CGRect(
            x: frame.minX + min(xOffset, maxXOffset),
            y: frame.minY + min(yOffset, maxYOffset),
            width: width,
            height: height
        )
        .insetBy(dx: innerGap / 2, dy: innerGap / 2)
        .standardized
    }
}

private func applyingOuterGaps(_ gaps: Insets, to frame: CGRect) -> CGRect {
    CGRect(
        x: frame.minX + gaps.left,
        y: frame.minY + gaps.top,
        width: max(0, frame.width - gaps.left - gaps.right),
        height: max(0, frame.height - gaps.top - gaps.bottom)
    )
}
