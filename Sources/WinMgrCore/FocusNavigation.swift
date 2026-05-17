import CoreGraphics

public func focusTarget(in layout: Layout, from focused: WindowID, direction: Direction) -> WindowID? {
    guard let sourceFrame = layout.tiled[focused] else { return nil }

    var best: FocusCandidate?
    for (windowID, frame) in layout.tiled {
        guard windowID != focused,
              frame.isFinitePositive,
              isCandidate(frame, from: sourceFrame, direction: direction)
        else {
            continue
        }

        let candidate = FocusCandidate(
            windowID: windowID,
            score: focusScore(frame, from: sourceFrame, direction: direction)
        )
        if let currentBest = best {
            if candidate.score < currentBest.score
                || (candidate.score == currentBest.score && candidate.windowID.raw < currentBest.windowID.raw) {
                best = candidate
            }
        } else {
            best = candidate
        }
    }

    return best?.windowID
}

public func focusCycleTarget(
    windows: [WindowMetadata],
    from focused: WindowID?,
    direction: FocusCycleDirection
) -> WindowID? {
    let ordered = windows
        .filter { !$0.isMinimized }
        .sorted(by: focusCycleSort)
        .map(\.id)
    guard !ordered.isEmpty else { return nil }
    guard let focused, let currentIndex = ordered.firstIndex(of: focused) else {
        return direction == .next ? ordered.first : ordered.last
    }

    switch direction {
    case .previous:
        return ordered[(currentIndex - 1 + ordered.count) % ordered.count]
    case .next:
        return ordered[(currentIndex + 1) % ordered.count]
    }
}

private struct FocusCandidate {
    let windowID: WindowID
    let score: FocusScore
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

private extension CGRect {
    var isFinitePositive: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
