import CoreGraphics
import NarwhalCore

public struct WindowInventoryObservationState: Equatable, Sendable {
    public let inventory: WindowInventoryState?
    public let frameInventory: WindowFrameInventoryState?
    public let spaceID: SpaceID?

    public init(
        inventory: WindowInventoryState?,
        frameInventory: WindowFrameInventoryState?,
        spaceID: SpaceID?
    ) {
        self.inventory = inventory
        self.frameInventory = frameInventory
        self.spaceID = spaceID
    }

    public static let empty = WindowInventoryObservationState(
        inventory: nil,
        frameInventory: nil,
        spaceID: nil
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
    spaceID: SpaceID?
) -> WindowInventoryObservationState {
    WindowInventoryObservationState(
        inventory: WindowInventoryState(visibleWindowIDs: Set(windows.map(\.id))),
        frameInventory: WindowFrameInventoryState(
            framesByWindowID: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
        ),
        spaceID: spaceID
    )
}

public func observeWindowInventory(
    windows: [WindowMetadata],
    spaceID: SpaceID?,
    tolerance: CGFloat,
    in state: WindowInventoryObservationState
) -> WindowInventoryObservationTransition {
    guard let previous = state.inventory else {
        return WindowInventoryObservationTransition(
            state: windowInventoryObservationBaseline(windows: windows, spaceID: spaceID),
            events: [],
            frameEvents: [],
            effect: nil
        )
    }

    guard spaceID == state.spaceID else {
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
            spaceID: spaceID
        ),
        events: poll.events,
        frameEvents: framePoll.events,
        effect: nil
    )
}
