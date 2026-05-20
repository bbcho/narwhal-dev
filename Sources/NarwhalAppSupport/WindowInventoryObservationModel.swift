import CoreGraphics
import NarwhalCore

public struct WindowInventoryObservationState: Equatable, Sendable {
    public let inventory: WindowInventoryState?
    public let frameInventory: WindowFrameInventoryState?
    public let activeSpaceByDisplay: [DisplayID: SpaceID]

    public init(
        inventory: WindowInventoryState?,
        frameInventory: WindowFrameInventoryState?,
        activeSpaceByDisplay: [DisplayID: SpaceID]
    ) {
        self.inventory = inventory
        self.frameInventory = frameInventory
        self.activeSpaceByDisplay = activeSpaceByDisplay
    }

    public static let empty = WindowInventoryObservationState(
        inventory: nil,
        frameInventory: nil,
        activeSpaceByDisplay: [:]
    )
}

public enum WindowInventoryObservationEffect: Equatable, Sendable {
    case activeSpaceChanged
    case likelySpaceReplacement
}

public struct WindowInventoryObservationTransition: Equatable, Sendable {
    public let state: WindowInventoryObservationState
    public let events: [AXEvent]
    public let frameEvents: [AXEvent]
    public let effect: WindowInventoryObservationEffect?

    public init(
        state: WindowInventoryObservationState,
        events: [AXEvent],
        frameEvents: [AXEvent],
        effect: WindowInventoryObservationEffect?
    ) {
        self.state = state
        self.events = events
        self.frameEvents = frameEvents
        self.effect = effect
    }
}

public func windowInventoryObservationBaseline(
    windows: [WindowMetadata],
    activeSpaceByDisplay: [DisplayID: SpaceID]
) -> WindowInventoryObservationState {
    WindowInventoryObservationState(
        inventory: WindowInventoryState(visibleWindowIDs: Set(windows.map(\.id))),
        frameInventory: WindowFrameInventoryState(
            framesByWindowID: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        ),
        activeSpaceByDisplay: activeSpaceByDisplay
    )
}

public func observeWindowInventory(
    windows: [WindowMetadata],
    activeSpaceByDisplay: [DisplayID: SpaceID],
    tolerance: CGFloat,
    in state: WindowInventoryObservationState
) -> WindowInventoryObservationTransition {
    guard let previous = state.inventory else {
        return WindowInventoryObservationTransition(
            state: windowInventoryObservationBaseline(
                windows: windows,
                activeSpaceByDisplay: activeSpaceByDisplay
            ),
            events: [],
            frameEvents: [],
            effect: nil
        )
    }

    guard !activeDisplaySpacesChanged(from: state.activeSpaceByDisplay, to: activeSpaceByDisplay) else {
        return WindowInventoryObservationTransition(
            state: .empty,
            events: [],
            frameEvents: [],
            effect: .activeSpaceChanged
        )
    }

    let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
        previous: previous,
        current: windows
    )
    guard !poll.suppressedSpaceReplacement else {
        return WindowInventoryObservationTransition(
            state: .empty,
            events: [],
            frameEvents: [],
            effect: .likelySpaceReplacement
        )
    }

    let framePoll = pollWindowFrameInventory(
        previous: state.frameInventory ?? .empty,
        current: windows,
        tolerance: tolerance
    )
    return WindowInventoryObservationTransition(
        state: WindowInventoryObservationState(
            inventory: poll.state,
            frameInventory: framePoll.state,
            activeSpaceByDisplay: activeSpaceByDisplay
        ),
        events: poll.events,
        frameEvents: framePoll.events,
        effect: nil
    )
}

private func activeDisplaySpacesChanged(
    from previous: [DisplayID: SpaceID],
    to current: [DisplayID: SpaceID]
) -> Bool {
    guard !previous.isEmpty, !current.isEmpty else { return false }
    return previous != current
}
