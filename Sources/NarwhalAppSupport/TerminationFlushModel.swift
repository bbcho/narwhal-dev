public enum TerminationFlushState: Equatable, Sendable {
    case idle
    case waiting
    case approved
}

public enum TerminationRequestDecision: Equatable, Sendable {
    case startFlushAndDefer
    case deferExistingFlush
    case terminateNow
}

public enum TerminationCompletionDecision: Equatable, Sendable {
    case replyToTerminate
    case ignore
}

public enum TerminationFlushCompletion: Equatable, Sendable {
    case persisted
    case timedOut
}

public func requestTermination(
    in state: TerminationFlushState
) -> (state: TerminationFlushState, decision: TerminationRequestDecision) {
    switch state {
    case .idle:
        return (.waiting, .startFlushAndDefer)
    case .waiting:
        return (.waiting, .deferExistingFlush)
    case .approved:
        return (.approved, .terminateNow)
    }
}

public func completeTerminationFlush(
    _ completion: TerminationFlushCompletion,
    in state: TerminationFlushState
) -> (state: TerminationFlushState, decision: TerminationCompletionDecision) {
    switch state {
    case .waiting:
        return (.approved, .replyToTerminate)
    case .idle, .approved:
        return (state, .ignore)
    }
}
