import CoreGraphics

public struct WindowInventoryState: Equatable, Sendable {
    public let visibleWindowIDs: Set<WindowID>

    public init(visibleWindowIDs: Set<WindowID>) {
        self.visibleWindowIDs = visibleWindowIDs
    }

    public static let empty = WindowInventoryState(visibleWindowIDs: [])
}

public struct WindowFrameInventoryState: Equatable, Sendable {
    public let framesByWindowID: [WindowID: CGRect]

    public init(framesByWindowID: [WindowID: CGRect]) {
        self.framesByWindowID = framesByWindowID
    }

    public static let empty = WindowFrameInventoryState(framesByWindowID: [:])
}

public struct WindowFrameInventoryPoll: Equatable, Sendable {
    public let state: WindowFrameInventoryState
    public let events: [AXEvent]

    public init(state: WindowFrameInventoryState, events: [AXEvent]) {
        self.state = state
        self.events = events
    }
}

public struct WindowInventoryPoll: Equatable, Sendable {
    public let state: WindowInventoryState
    public let events: [AXEvent]
    public let suppressedSpaceReplacement: Bool

    public init(
        state: WindowInventoryState,
        events: [AXEvent],
        suppressedSpaceReplacement: Bool = false
    ) {
        self.state = state
        self.events = events
        self.suppressedSpaceReplacement = suppressedSpaceReplacement
    }
}

public func pollWindowInventory(
    previous: WindowInventoryState,
    current: [WindowMetadata]
) -> WindowInventoryPoll {
    let windowsByID = current.reduce(into: [:]) { result, metadata in
        result[metadata.id] = metadata
    }
    let currentIDs = Set(windowsByID.keys)
    let opened = currentIDs.subtracting(previous.visibleWindowIDs)
        .sorted { $0.raw < $1.raw }
        .compactMap { windowsByID[$0].map(AXEvent.windowOpened) }
    let closed = previous.visibleWindowIDs.subtracting(currentIDs)
        .sorted { $0.raw < $1.raw }
        .map(AXEvent.windowClosed)

    return WindowInventoryPoll(
        state: WindowInventoryState(visibleWindowIDs: currentIDs),
        events: opened + closed
    )
}

public func pollWindowInventorySuppressingLikelySpaceReplacement(
    previous: WindowInventoryState,
    current: [WindowMetadata]
) -> WindowInventoryPoll {
    let poll = pollWindowInventory(previous: previous, current: current)
    let currentIDs = poll.state.visibleWindowIDs
    let openedCount = currentIDs.subtracting(previous.visibleWindowIDs).count
    let closedCount = previous.visibleWindowIDs.subtracting(currentIDs).count
    let previousCount = previous.visibleWindowIDs.count
    let currentCount = currentIDs.count
    let isLikelySpaceReplacement = openedCount > 0
        && closedCount > 0
    let isLikelyTransientFullDisappearance = closedCount == previous.visibleWindowIDs.count
        && !previous.visibleWindowIDs.isEmpty
        && currentIDs.isEmpty
    let isLikelyBulkDisappearance = openedCount == 0
        && closedCount > 0
        && previousCount >= 3
        && currentCount * 2 <= previousCount
    let isLikelyBulkAppearance = closedCount == 0
        && openedCount >= 5
        && previousCount > 0
        && currentCount >= previousCount * 2

    guard isLikelySpaceReplacement
        || isLikelyTransientFullDisappearance
        || isLikelyBulkDisappearance
        || isLikelyBulkAppearance
    else {
        return poll
    }
    return WindowInventoryPoll(
        state: poll.state,
        events: [],
        suppressedSpaceReplacement: true
    )
}

public func pollWindowFrameInventory(
    previous: WindowFrameInventoryState,
    current: [WindowMetadata],
    tolerance: CGFloat = 1
) -> WindowFrameInventoryPoll {
    let currentFrames = current.reduce(into: [WindowID: CGRect]()) { result, metadata in
        result[metadata.id] = metadata.frame
    }
    let currentIDs = Set(currentFrames.keys)
    let previousIDs = Set(previous.framesByWindowID.keys)
    let sharedIDs = currentIDs.intersection(previousIDs).sorted { $0.raw < $1.raw }
    let events = sharedIDs.compactMap { windowID -> AXEvent? in
        guard let oldFrame = previous.framesByWindowID[windowID],
              let newFrame = currentFrames[windowID],
              !framesEqual(oldFrame, newFrame, tolerance: tolerance)
        else { return nil }

        if sizesEqual(oldFrame.size, newFrame.size, tolerance: tolerance) {
            return .windowMoved(windowID, newFrame)
        }
        return .windowResized(windowID, newFrame.size)
    }
    return WindowFrameInventoryPoll(
        state: WindowFrameInventoryState(framesByWindowID: currentFrames),
        events: events
    )
}

private func framesEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance
        && abs(lhs.origin.y - rhs.origin.y) <= tolerance
        && sizesEqual(lhs.size, rhs.size, tolerance: tolerance)
}

private func sizesEqual(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}
