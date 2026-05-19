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

    public init(state: WindowInventoryState, events: [AXEvent]) {
        self.state = state
        self.events = events
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
