import CoreGraphics

public func focusTarget(in layout: Layout, from focused: WindowID, direction: Direction) -> WindowID? {
    focusTarget(in: layout.tiled, from: focused, direction: direction)
}

public func focusTarget(windows: [WindowMetadata], from focused: WindowID, direction: Direction) -> WindowID? {
    let frames = Dictionary(
        windows
            .filter { !$0.isMinimized }
            .map { ($0.id, $0.frame) },
        uniquingKeysWith: { _, replacement in replacement }
    )
    return focusTarget(in: frames, from: focused, direction: direction)
}

private func focusTarget(in frames: [WindowID: CGRect], from focused: WindowID, direction: Direction) -> WindowID? {
    guard let sourceFrame = frames[focused],
          sourceFrame.narwhalIsFinitePositive
    else { return nil }

    return frames
        .compactMap { windowID, frame -> FocusCandidate? in
            guard windowID != focused,
                  frame.narwhalIsFinitePositive,
                  isCandidate(frame, from: sourceFrame, direction: direction)
            else {
                return nil
            }
            return FocusCandidate(
                windowID: windowID,
                score: focusScore(frame, from: sourceFrame, direction: direction)
            )
        }
        .min()?
        .windowID
}

public func focusCycleTarget(
    windows: [WindowMetadata],
    from focused: WindowID?,
    direction: FocusCycleDirection
) -> WindowID? {
    focusCycleCandidates(windows: windows, from: focused, direction: direction).first
}

public func focusCycleCandidates(
    windows: [WindowMetadata],
    from focused: WindowID?,
    direction: FocusCycleDirection
) -> [WindowID] {
    let ordered = windows
        .filter { !$0.isMinimized }
        .sorted(by: focusCycleSort)
        .map(\.id)
    guard !ordered.isEmpty else { return [] }

    let traversal = direction == .next ? ordered : Array(ordered.reversed())
    guard let focused, let currentIndex = traversal.firstIndex(of: focused) else {
        return Array(traversal)
    }

    return Array(traversal.dropFirst(currentIndex + 1)) + Array(traversal.prefix(currentIndex + 1))
}

private struct FocusCandidate: Equatable, Comparable {
    let windowID: WindowID
    let score: FocusScore

    static func < (lhs: FocusCandidate, rhs: FocusCandidate) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        return lhs.windowID.raw < rhs.windowID.raw
    }
}

private struct FocusScore: Equatable, Comparable {
    let noPerpendicularOverlap: Bool
    let primaryDistance: CGFloat
    let perpendicularGap: CGFloat
    let perpendicularCenterDistance: CGFloat

    static func < (lhs: FocusScore, rhs: FocusScore) -> Bool {
        if lhs.noPerpendicularOverlap != rhs.noPerpendicularOverlap {
            return !lhs.noPerpendicularOverlap
        }
        if lhs.primaryDistance != rhs.primaryDistance {
            return lhs.primaryDistance < rhs.primaryDistance
        }
        if lhs.perpendicularGap != rhs.perpendicularGap {
            return lhs.perpendicularGap < rhs.perpendicularGap
        }
        return lhs.perpendicularCenterDistance < rhs.perpendicularCenterDistance
    }
}

private func isCandidate(_ frame: CGRect, from source: CGRect, direction: Direction) -> Bool {
    switch direction {
    case .left:
        return frame.midX < source.midX
    case .right:
        return frame.midX > source.midX
    case .up:
        return frame.midY < source.midY
    case .down:
        return frame.midY > source.midY
    }
}

private func focusScore(_ frame: CGRect, from source: CGRect, direction: Direction) -> FocusScore {
    switch direction {
    case .left:
        return FocusScore(
            noPerpendicularOverlap: !intervalsOverlap(frame.minY...frame.maxY, source.minY...source.maxY),
            primaryDistance: max(0, source.minX - frame.maxX),
            perpendicularGap: intervalGap(frame.minY...frame.maxY, source.minY...source.maxY),
            perpendicularCenterDistance: abs(frame.midY - source.midY)
        )
    case .right:
        return FocusScore(
            noPerpendicularOverlap: !intervalsOverlap(frame.minY...frame.maxY, source.minY...source.maxY),
            primaryDistance: max(0, frame.minX - source.maxX),
            perpendicularGap: intervalGap(frame.minY...frame.maxY, source.minY...source.maxY),
            perpendicularCenterDistance: abs(frame.midY - source.midY)
        )
    case .up:
        return FocusScore(
            noPerpendicularOverlap: !intervalsOverlap(frame.minX...frame.maxX, source.minX...source.maxX),
            primaryDistance: max(0, source.minY - frame.maxY),
            perpendicularGap: intervalGap(frame.minX...frame.maxX, source.minX...source.maxX),
            perpendicularCenterDistance: abs(frame.midX - source.midX)
        )
    case .down:
        return FocusScore(
            noPerpendicularOverlap: !intervalsOverlap(frame.minX...frame.maxX, source.minX...source.maxX),
            primaryDistance: max(0, frame.minY - source.maxY),
            perpendicularGap: intervalGap(frame.minX...frame.maxX, source.minX...source.maxX),
            perpendicularCenterDistance: abs(frame.midX - source.midX)
        )
    }
}

private func intervalsOverlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> Bool {
    lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
}

private func intervalGap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> CGFloat {
    if intervalsOverlap(lhs, rhs) { return 0 }
    if lhs.upperBound <= rhs.lowerBound { return rhs.lowerBound - lhs.upperBound }
    return lhs.lowerBound - rhs.upperBound
}

private func focusCycleSort(_ lhs: WindowMetadata, _ rhs: WindowMetadata) -> Bool {
    if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
    if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
    if lhs.bundleID.raw != rhs.bundleID.raw { return lhs.bundleID.raw < rhs.bundleID.raw }
    if lhs.title != rhs.title { return lhs.title < rhs.title }
    return lhs.id.raw < rhs.id.raw
}
