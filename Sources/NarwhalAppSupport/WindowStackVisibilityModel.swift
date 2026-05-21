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

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
