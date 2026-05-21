public enum EnvironmentRefreshReason: Equatable, CustomStringConvertible, Sendable {
    case windowOpened(WindowID)
    case windowClosed(WindowID)
    case displayChanged
    case spaceSettled
    case spaceTransitionEnded

    public var description: String {
        switch self {
        case .windowOpened(let id):
            return "window opened \(id.description)"
        case .windowClosed(let id):
            return "window closed \(id.description)"
        case .displayChanged:
            return "display changed"
        case .spaceSettled:
            return "space settled"
        case .spaceTransitionEnded:
            return "space transition ended"
        }
    }
}

public struct CoalescedEnvironmentRefresh: Equatable, CustomStringConvertible, Sendable {
    public let generation: UInt64
    public let reasons: [EnvironmentRefreshReason]

    public init(generation: UInt64, reasons: [EnvironmentRefreshReason]) {
        self.generation = generation
        self.reasons = reasons
    }

    public var description: String {
        guard reasons.count != 1 else {
            return reasons[0].description
        }
        return "\(reasons.count) coalesced events: \(reasons.map(\.description).joined(separator: ", "))"
    }
}

public struct EnvironmentRefreshCoalescerState: Equatable, Sendable {
    public let nextGeneration: UInt64
    public let pending: CoalescedEnvironmentRefresh?

    public init(nextGeneration: UInt64, pending: CoalescedEnvironmentRefresh?) {
        self.nextGeneration = nextGeneration
        self.pending = pending
    }

    public static let empty = EnvironmentRefreshCoalescerState(nextGeneration: 1, pending: nil)
}

public struct EnvironmentRefreshSchedule: Equatable, Sendable {
    public let state: EnvironmentRefreshCoalescerState
    public let request: CoalescedEnvironmentRefresh

    public init(state: EnvironmentRefreshCoalescerState, request: CoalescedEnvironmentRefresh) {
        self.state = state
        self.request = request
    }
}

public enum EnvironmentRefreshTimerDecision: Equatable, Sendable {
    case run(CoalescedEnvironmentRefresh)
    case stale(pending: CoalescedEnvironmentRefresh?)
    case idle
}

public struct EnvironmentRefreshTimerResult: Equatable, Sendable {
    public let state: EnvironmentRefreshCoalescerState
    public let decision: EnvironmentRefreshTimerDecision

    public init(state: EnvironmentRefreshCoalescerState, decision: EnvironmentRefreshTimerDecision) {
        self.state = state
        self.decision = decision
    }
}

public enum EnvironmentRefreshCompletionDecision: Equatable, Sendable {
    case cleared(CoalescedEnvironmentRefresh)
    case retained(CoalescedEnvironmentRefresh)
    case stale(pending: CoalescedEnvironmentRefresh?)
    case idle
}

public struct EnvironmentRefreshCompletionResult: Equatable, Sendable {
    public let state: EnvironmentRefreshCoalescerState
    public let decision: EnvironmentRefreshCompletionDecision

    public init(state: EnvironmentRefreshCoalescerState, decision: EnvironmentRefreshCompletionDecision) {
        self.state = state
        self.decision = decision
    }
}

public func scheduleEnvironmentRefresh(
    _ reason: EnvironmentRefreshReason,
    in state: EnvironmentRefreshCoalescerState
) -> EnvironmentRefreshSchedule {
    let request = CoalescedEnvironmentRefresh(
        generation: state.nextGeneration,
        reasons: (state.pending?.reasons ?? []) + [reason]
    )
    return EnvironmentRefreshSchedule(
        state: EnvironmentRefreshCoalescerState(
            nextGeneration: state.nextGeneration + 1,
            pending: request
        ),
        request: request
    )
}

public func fireEnvironmentRefreshTimer(
    generation: UInt64,
    in state: EnvironmentRefreshCoalescerState
) -> EnvironmentRefreshTimerResult {
    guard let pending = state.pending else {
        return EnvironmentRefreshTimerResult(state: state, decision: .idle)
    }
    guard pending.generation == generation else {
        return EnvironmentRefreshTimerResult(state: state, decision: .stale(pending: pending))
    }
    return EnvironmentRefreshTimerResult(state: state, decision: .run(pending))
}

public func completeEnvironmentRefresh(
    generation: UInt64,
    snapshotComplete: Bool,
    in state: EnvironmentRefreshCoalescerState
) -> EnvironmentRefreshCompletionResult {
    guard let pending = state.pending else {
        return EnvironmentRefreshCompletionResult(state: state, decision: .idle)
    }
    guard pending.generation == generation else {
        return EnvironmentRefreshCompletionResult(state: state, decision: .stale(pending: pending))
    }
    guard snapshotComplete else {
        return EnvironmentRefreshCompletionResult(state: state, decision: .retained(pending))
    }

    return EnvironmentRefreshCompletionResult(
        state: EnvironmentRefreshCoalescerState(nextGeneration: state.nextGeneration, pending: nil),
        decision: .cleared(pending)
    )
}

public func shouldPreserveSpaceLayouts(
    for reasons: [EnvironmentRefreshReason],
    duringSpaceTransition: Bool
) -> Bool {
    duringSpaceTransition
        || reasons.contains(.displayChanged)
        || reasons.contains(.spaceSettled)
        || reasons.contains(.spaceTransitionEnded)
}

public func shouldPersistRestoreAfterEnvironmentRefresh(
    reasons: [EnvironmentRefreshReason],
    preservedSpaceLayouts: Bool = false
) -> Bool {
    guard !preservedSpaceLayouts else { return false }
    return !reasons.contains(.spaceSettled)
        && !reasons.contains(.spaceTransitionEnded)
}

public func shouldApplyPendingTileRulesAfterEnvironmentRefresh(
    preservedSpaceLayouts: Bool
) -> Bool {
    !preservedSpaceLayouts
}
