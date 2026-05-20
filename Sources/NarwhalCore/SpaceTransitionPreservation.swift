public struct SpaceTransitionPreservationState: Equatable, Sendable {
    public let activeGeneration: UInt64?
    public let nextGeneration: UInt64

    public var isPreservingSpaceLayouts: Bool {
        activeGeneration != nil
    }

    public init(activeGeneration: UInt64?, nextGeneration: UInt64) {
        self.activeGeneration = activeGeneration
        self.nextGeneration = nextGeneration
    }

    public static let empty = SpaceTransitionPreservationState(
        activeGeneration: nil,
        nextGeneration: 1
    )
}

public struct SpaceTransitionPreservationStart: Equatable, Sendable {
    public let state: SpaceTransitionPreservationState
    public let generation: UInt64
    public let settledRefreshDelays: [Double]
    public let preserveEndDelay: Double

    public init(
        state: SpaceTransitionPreservationState,
        generation: UInt64,
        settledRefreshDelays: [Double],
        preserveEndDelay: Double
    ) {
        self.state = state
        self.generation = generation
        self.settledRefreshDelays = settledRefreshDelays
        self.preserveEndDelay = preserveEndDelay
    }
}

public enum SpaceTransitionPreservationEndDecision: Equatable, Sendable {
    case scheduleRefresh
    case stale(activeGeneration: UInt64?)
}

public struct SpaceTransitionPreservationEnd: Equatable, Sendable {
    public let state: SpaceTransitionPreservationState
    public let decision: SpaceTransitionPreservationEndDecision

    public init(
        state: SpaceTransitionPreservationState,
        decision: SpaceTransitionPreservationEndDecision
    ) {
        self.state = state
        self.decision = decision
    }
}

public func beginSpaceTransitionPreservation(
    in state: SpaceTransitionPreservationState,
    settledRefreshDelays: [Double],
    preserveEndDelay: Double
) -> SpaceTransitionPreservationStart {
    let generation = state.nextGeneration
    return SpaceTransitionPreservationStart(
        state: SpaceTransitionPreservationState(
            activeGeneration: generation,
            nextGeneration: generation + 1
        ),
        generation: generation,
        settledRefreshDelays: settledRefreshDelays,
        preserveEndDelay: preserveEndDelay
    )
}

public func cancelSpaceTransitionPreservation(
    in state: SpaceTransitionPreservationState
) -> SpaceTransitionPreservationState {
    SpaceTransitionPreservationState(
        activeGeneration: nil,
        nextGeneration: state.nextGeneration
    )
}

public func completeSpaceTransitionPreservation(
    generation: UInt64,
    in state: SpaceTransitionPreservationState
) -> SpaceTransitionPreservationEnd {
    guard state.activeGeneration == generation else {
        return SpaceTransitionPreservationEnd(
            state: state,
            decision: .stale(activeGeneration: state.activeGeneration)
        )
    }

    return SpaceTransitionPreservationEnd(
        state: SpaceTransitionPreservationState(
            activeGeneration: nil,
            nextGeneration: state.nextGeneration
        ),
        decision: .scheduleRefresh
    )
}
