import Testing
@testable import NarwhalAppSupport

@Suite("Focused window availability log model")
struct FocusedWindowAvailabilityLogModelTests {
    @Test("Repeated unavailable focus logs once until recovery")
    func repeatedUnavailableFocusLogsOnceUntilRecovery() {
        let reason = "AXFocusedApplication failed with AXError(rawValue: -25212)"
        let first = reduceFocusedWindowAvailabilityLog(
            state: .empty,
            input: .unavailable(reason: reason, hasLastFocusedWindow: true)
        )
        let second = reduceFocusedWindowAvailabilityLog(
            state: first.state,
            input: .unavailable(reason: reason, hasLastFocusedWindow: true)
        )
        let third = reduceFocusedWindowAvailabilityLog(
            state: second.state,
            input: .unavailable(reason: reason, hasLastFocusedWindow: true)
        )

        #expect(first.effects == [.logUnavailable(reason: reason, preservingLastFocus: true)])
        #expect(second.effects == [])
        #expect(third.effects == [])
        #expect(third.state.missedPolls == 3)

        let recovered = reduceFocusedWindowAvailabilityLog(state: third.state, input: .observed)
        #expect(recovered.effects == [.logRecovered(missedPolls: 3)])
        #expect(recovered.state == .empty)

        let unavailableAfterRecovery = reduceFocusedWindowAvailabilityLog(
            state: recovered.state,
            input: .unavailable(reason: reason, hasLastFocusedWindow: false)
        )
        #expect(unavailableAfterRecovery.effects == [.logUnavailable(reason: reason, preservingLastFocus: false)])
    }

    @Test("Changed unavailable reason logs a fresh line")
    func changedUnavailableReasonLogsFreshLine() {
        let first = reduceFocusedWindowAvailabilityLog(
            state: .empty,
            input: .unavailable(reason: "first", hasLastFocusedWindow: true)
        )
        let changed = reduceFocusedWindowAvailabilityLog(
            state: first.state,
            input: .unavailable(reason: "second", hasLastFocusedWindow: true)
        )

        #expect(changed.effects == [.logUnavailable(reason: "second", preservingLastFocus: true)])
        #expect(changed.state.missedPolls == 2)
    }
}
