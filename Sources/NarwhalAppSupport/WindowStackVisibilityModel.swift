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

public enum FocusBorderStackingDecision: Equatable, Sendable {
    case keepVisible
    case restack
    case hideBlockedBy(WindowID)
    case hideTargetMissing
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
        if entry.frame.intersection(targetFrame).narwhalArea > minimumIntersectionArea {
            return .blockedBy(entry.id)
        }
    }
    return .visible
}

public func focusBorderStackingDecision(
    target: WindowID,
    border: WindowID?,
    frontToBackWindows: [WindowStackEntry],
    ignoredWindowIDs: Set<WindowID>,
    minimumIntersectionArea: CGFloat = 1
) -> FocusBorderStackingDecision {
    var visibilityIgnoredWindowIDs = ignoredWindowIDs
    if let border {
        visibilityIgnoredWindowIDs.insert(border)
    }
    let targetVisibility = windowStackVisibility(
        target: target,
        frontToBackWindows: frontToBackWindows.filter {
            !visibilityIgnoredWindowIDs.contains($0.id)
        },
        minimumIntersectionArea: minimumIntersectionArea
    )

    switch targetVisibility {
    case .visible:
        guard let border,
              let borderIndex = frontToBackWindows.firstIndex(where: { $0.id == border }),
              let targetIndex = frontToBackWindows.firstIndex(where: { $0.id == target })
        else {
            return .restack
        }
        return borderIndex < targetIndex ? .keepVisible : .restack
    case .blockedBy(let blocker):
        return .hideBlockedBy(blocker)
    case .targetMissing:
        return .hideTargetMissing
    }
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
    return lhs.narwhalApproximatelyEquals(rhs, tolerance: tolerance)
}
