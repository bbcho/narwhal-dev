import CoreGraphics
import NarwhalCore

public struct ExternalGeometryEventSelection: Equatable, Sendable {
    public let event: AXEvent
    public let usedLiveFrame: Bool

    public init(event: AXEvent, usedLiveFrame: Bool) {
        self.event = event
        self.usedLiveFrame = usedLiveFrame
    }
}

public func externalGeometryEventSelection(
    for event: AXEvent,
    liveSnapshot: AXWindowSnapshot,
    tolerance: CGFloat
) -> ExternalGeometryEventSelection {
    let windowID: WindowID
    switch event {
    case .windowMoved(let id, _), .windowResized(let id, _):
        windowID = id
    case .windowOpened, .windowClosed, .windowFocused:
        return ExternalGeometryEventSelection(event: event, usedLiveFrame: false)
    }

    guard case .complete = liveSnapshot.quality,
          let live = liveSnapshot.windows.first(where: { $0.id == windowID })
    else {
        return ExternalGeometryEventSelection(event: event, usedLiveFrame: false)
    }

    let matchesLiveFrame: Bool
    switch event {
    case .windowMoved(_, let frame):
        matchesLiveFrame = framesApproximatelyEqual(live.frame, frame, tolerance: tolerance)
    case .windowResized(_, let size):
        matchesLiveFrame = sizesApproximatelyEqual(live.frame.size, size, tolerance: tolerance)
    case .windowOpened, .windowClosed, .windowFocused:
        matchesLiveFrame = true
    }

    guard !matchesLiveFrame else {
        return ExternalGeometryEventSelection(event: event, usedLiveFrame: false)
    }
    return ExternalGeometryEventSelection(
        event: .windowMoved(windowID, live.frame),
        usedLiveFrame: true
    )
}

private func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance
        && abs(lhs.origin.y - rhs.origin.y) <= tolerance
        && sizesApproximatelyEqual(lhs.size, rhs.size, tolerance: tolerance)
}

private func sizesApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}
