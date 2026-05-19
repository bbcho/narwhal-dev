public struct WindowInventoryState: Equatable, Sendable {
    public let visibleWindowIDs: Set<WindowID>

    public init(visibleWindowIDs: Set<WindowID>) {
        self.visibleWindowIDs = visibleWindowIDs
    }

    public static let empty = WindowInventoryState(visibleWindowIDs: [])
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
