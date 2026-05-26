import CoreGraphics
import NarwhalCore

public struct WindowStackEntry: Equatable, Sendable {
    public let id: WindowID
    public let frame: CGRect

    public init(id: WindowID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public enum WindowStackVisibilityDecision: Equatable, Sendable {
    case visible
    case blockedBy(WindowID)
    case targetMissing
}

public enum TiledBorderTargetVisibilityDecision: Equatable, Sendable {
    case show
    case hideTargetMissing
    case hideFrameMismatch(actual: CGRect)
}

public func windowStackVisibility(
    target: WindowID,
    frontToBackWindows: [WindowStackEntry],
    minimumIntersectionArea: CGFloat = 1
) -> WindowStackVisibilityDecision {
    guard let targetIndex = frontToBackWindows.firstIndex(where: { $0.id == target }) else {
        return .targetMissing
    }
    let targetFrame = frontToBackWindows[targetIndex].frame
    for entry in frontToBackWindows.prefix(targetIndex) where entry.id != target {
        if entry.frame.intersection(targetFrame).area > minimumIntersectionArea {
            return .blockedBy(entry.id)
        }
    }
    return .visible
}

public func tiledBorderTargetVisibility(
    target: FocusBorderTarget,
    liveWindows: [WindowStackEntry],
    frameTolerance: CGFloat = 8
) -> TiledBorderTargetVisibilityDecision {
    guard let live = liveWindows.first(where: { $0.id == target.windowID }) else {
        return .hideTargetMissing
    }
    guard framesApproximatelyMatch(live.frame, target.frame, minimumTolerance: frameTolerance) else {
        return .hideFrameMismatch(actual: live.frame)
    }
    return .show
}

private func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect, minimumTolerance: CGFloat) -> Bool {
    let tolerance = max(
        minimumTolerance,
        min(lhs.width, lhs.height, rhs.width, rhs.height) * 0.04
    )
    return abs(lhs.origin.x - rhs.origin.x) <= tolerance
        && abs(lhs.origin.y - rhs.origin.y) <= tolerance
        && abs(lhs.size.width - rhs.size.width) <= tolerance
        && abs(lhs.size.height - rhs.size.height) <= tolerance
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
