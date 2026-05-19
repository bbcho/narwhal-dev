import CoreGraphics

public struct FocusedWindowGeometryState: Equatable, Sendable {
    public let windowID: WindowID?
    public let frame: CGRect?

    public init(windowID: WindowID?, frame: CGRect?) {
        self.windowID = windowID
        self.frame = frame
    }

    public static let empty = FocusedWindowGeometryState(windowID: nil, frame: nil)
}

public struct FocusedWindowGeometryPoll: Equatable, Sendable {
    public let state: FocusedWindowGeometryState
    public let event: AXEvent?

    public init(state: FocusedWindowGeometryState, event: AXEvent?) {
        self.state = state
        self.event = event
    }
}

public func pollFocusedWindowGeometry(
    previous: FocusedWindowGeometryState,
    currentWindowID: WindowID,
    currentFrame: CGRect,
    tolerance: CGFloat
) -> FocusedWindowGeometryPoll {
    let nextState = FocusedWindowGeometryState(windowID: currentWindowID, frame: currentFrame)
    guard previous.windowID == currentWindowID else {
        return FocusedWindowGeometryPoll(state: nextState, event: .windowFocused(currentWindowID))
    }
    guard let previousFrame = previous.frame else {
        return FocusedWindowGeometryPoll(state: nextState, event: nil)
    }
    guard !framesApproximatelyMatch(previousFrame, currentFrame, tolerance: tolerance) else {
        return FocusedWindowGeometryPoll(state: previous, event: nil)
    }

    let event: AXEvent = originsApproximatelyMatch(previousFrame.origin, currentFrame.origin, tolerance: tolerance)
        ? .windowResized(currentWindowID, currentFrame.size)
        : .windowMoved(currentWindowID, currentFrame)
    return FocusedWindowGeometryPoll(state: nextState, event: event)
}

private func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
    originsApproximatelyMatch(lhs.origin, rhs.origin, tolerance: tolerance)
        && abs(lhs.size.width - rhs.size.width) <= tolerance
        && abs(lhs.size.height - rhs.size.height) <= tolerance
}

private func originsApproximatelyMatch(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat) -> Bool {
    abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
}
