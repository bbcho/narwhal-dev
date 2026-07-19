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

    @Test("Persistence completion approves exactly one AppKit reply")
    func persistenceRepliesOnce() {
        let completed = completeTerminationFlush(.persisted, in: .waiting)
        #expect(completed == (.approved, .replyToTerminate))
        #expect(completeTerminationFlush(.persisted, in: completed.state) ==
            (.approved, .ignore))
        #expect(requestTermination(in: completed.state) ==
            (.approved, .terminateNow))
    }

    @Test("Timeout and late persistence cannot reply twice")
    func timeoutWinsOnce() {
        let timeout = completeTerminationFlush(.timedOut, in: .waiting)
        #expect(timeout == (.approved, .replyToTerminate))
        #expect(completeTerminationFlush(.persisted, in: timeout.state) ==
            (.approved, .ignore))
    }
}
