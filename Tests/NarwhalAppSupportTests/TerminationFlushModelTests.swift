import Testing
@testable import NarwhalAppSupport

@Suite("Termination flush model")
struct TerminationFlushModelTests {
    @Test("First termination request starts one flush and later requests share it")
    func repeatedRequestsShareFlush() {
        let first = requestTermination(in: .idle)
        #expect(first == (.waiting, .startFlushAndDefer))

        let repeated = requestTermination(in: first.state)
        #expect(repeated == (.waiting, .deferExistingFlush))
    }

    @Test("The first flush completion, persisted or timed out, approves exactly one AppKit reply")
    func firstCompletionRepliesOnce() {
        let completed = completeTerminationFlush(in: .waiting)
        #expect(completed == (.approved, .replyToTerminate))
        #expect(completeTerminationFlush(in: completed.state) == (.approved, .ignore))
        #expect(requestTermination(in: completed.state) == (.approved, .terminateNow))
    }
}
