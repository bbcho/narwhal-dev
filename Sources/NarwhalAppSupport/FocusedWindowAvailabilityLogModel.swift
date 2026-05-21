public struct FocusedWindowAvailabilityLogState: Equatable, Sendable {
    public let missedPolls: Int
    public let lastReason: String?

    public init(missedPolls: Int, lastReason: String?) {
        self.missedPolls = missedPolls
        self.lastReason = lastReason
    }

    public static let empty = FocusedWindowAvailabilityLogState(missedPolls: 0, lastReason: nil)
}

public enum FocusedWindowAvailabilityInput: Equatable, Sendable {
    case observed
    case unavailable(reason: String, hasLastFocusedWindow: Bool)
}

public enum FocusedWindowAvailabilityEffect: Equatable, Sendable {
    case logUnavailable(reason: String, preservingLastFocus: Bool)
    case logRecovered(missedPolls: Int)
}

public struct FocusedWindowAvailabilityTransition: Equatable, Sendable {
    public let state: FocusedWindowAvailabilityLogState
    public let effects: [FocusedWindowAvailabilityEffect]

    public init(
        state: FocusedWindowAvailabilityLogState,
        effects: [FocusedWindowAvailabilityEffect]
    ) {
        self.state = state
        self.effects = effects
    }
}

public func reduceFocusedWindowAvailabilityLog(
    state: FocusedWindowAvailabilityLogState,
    input: FocusedWindowAvailabilityInput
) -> FocusedWindowAvailabilityTransition {
    switch input {
    case .observed:
        guard state.missedPolls > 0 else {
            return FocusedWindowAvailabilityTransition(state: .empty, effects: [])
        }
        return FocusedWindowAvailabilityTransition(
            state: .empty,
            effects: [.logRecovered(missedPolls: state.missedPolls)]
        )

    case .unavailable(let reason, let hasLastFocusedWindow):
        let next = FocusedWindowAvailabilityLogState(
            missedPolls: state.missedPolls + 1,
            lastReason: reason
        )
        guard state.missedPolls == 0 || state.lastReason != reason else {
            return FocusedWindowAvailabilityTransition(state: next, effects: [])
        }
        return FocusedWindowAvailabilityTransition(
            state: next,
            effects: [.logUnavailable(reason: reason, preservingLastFocus: hasLastFocusedWindow)]
        )
    }
}
