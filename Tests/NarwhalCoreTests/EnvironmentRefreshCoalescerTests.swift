import Testing
@testable import NarwhalCore

@Suite("Environment refresh coalescing")
struct EnvironmentRefreshCoalescerTests {
    @Test("Burst scheduling accumulates reasons and supersedes stale generations")
    func burstSchedulingAccumulatesReasonsAndSupersedesStaleGenerations() {
        let first = scheduleEnvironmentRefresh(.windowOpened(WindowID(raw: 10)), in: .empty)
        let second = scheduleEnvironmentRefresh(.windowClosed(WindowID(raw: 11)), in: first.state)
        let third = scheduleEnvironmentRefresh(.displayChanged, in: second.state)

        #expect(first.request == CoalescedEnvironmentRefresh(
            generation: 1,
            reasons: [.windowOpened(WindowID(raw: 10))]
        ))
        #expect(second.request == CoalescedEnvironmentRefresh(
            generation: 2,
            reasons: [
                .windowOpened(WindowID(raw: 10)),
                .windowClosed(WindowID(raw: 11))
            ]
        ))
        #expect(third.request == CoalescedEnvironmentRefresh(
            generation: 3,
            reasons: [
                .windowOpened(WindowID(raw: 10)),
                .windowClosed(WindowID(raw: 11)),
                .displayChanged
            ]
        ))
        #expect(third.state == EnvironmentRefreshCoalescerState(
            nextGeneration: 4,
            pending: third.request
        ))
        #expect(fireEnvironmentRefreshTimer(generation: 1, in: third.state).decision == .stale(pending: third.request))
        #expect(fireEnvironmentRefreshTimer(generation: 2, in: third.state).decision == .stale(pending: third.request))
        #expect(fireEnvironmentRefreshTimer(generation: 3, in: third.state).decision == .run(third.request))
    }

    @Test("Complete matching refresh clears the pending request only after it runs")
    func completeMatchingRefreshClearsPendingRequest() {
        let scheduled = scheduleEnvironmentRefresh(.displayChanged, in: .empty)
        let fired = fireEnvironmentRefreshTimer(generation: scheduled.request.generation, in: scheduled.state)
        let completed = completeEnvironmentRefresh(
            generation: scheduled.request.generation,
            snapshotComplete: true,
            in: fired.state
        )

        #expect(fired.decision == .run(scheduled.request))
        #expect(completed.decision == .cleared(scheduled.request))
        #expect(completed.state == EnvironmentRefreshCoalescerState(nextGeneration: 2, pending: nil))
        #expect(fireEnvironmentRefreshTimer(generation: scheduled.request.generation, in: completed.state).decision == .idle)
    }

    @Test("Incomplete refresh keeps the pending request for the next complete snapshot")
    func incompleteRefreshKeepsPendingRequest() {
        let first = scheduleEnvironmentRefresh(.windowOpened(WindowID(raw: 21)), in: .empty)
        let incomplete = completeEnvironmentRefresh(
            generation: first.request.generation,
            snapshotComplete: false,
            in: first.state
        )
        let second = scheduleEnvironmentRefresh(.spaceSettled, in: incomplete.state)

        #expect(incomplete.decision == .retained(first.request))
        #expect(incomplete.state == first.state)
        #expect(second.request == CoalescedEnvironmentRefresh(
            generation: 2,
            reasons: [
                .windowOpened(WindowID(raw: 21)),
                .spaceSettled
            ]
        ))
    }

    @Test("Stale completion cannot clear a newer pending request")
    func staleCompletionCannotClearNewerPendingRequest() {
        let first = scheduleEnvironmentRefresh(.windowOpened(WindowID(raw: 30)), in: .empty)
        let second = scheduleEnvironmentRefresh(.windowClosed(WindowID(raw: 31)), in: first.state)
        let staleCompletion = completeEnvironmentRefresh(
            generation: first.request.generation,
            snapshotComplete: true,
            in: second.state
        )

        #expect(staleCompletion.decision == .stale(pending: second.request))
        #expect(staleCompletion.state == second.state)
    }

    @Test("Reason descriptions are deterministic")
    func reasonDescriptionsAreDeterministic() {
        let request = CoalescedEnvironmentRefresh(
            generation: 7,
            reasons: [
                .windowOpened(WindowID(raw: 1)),
                .windowClosed(WindowID(raw: 2)),
                .displayChanged,
                .spaceSettled
            ]
        )

        #expect(CoalescedEnvironmentRefresh(generation: 1, reasons: [.displayChanged]).description == "display changed")
        #expect(request.description == "4 coalesced events: window opened w1, window closed w2, display changed, space settled")
        #expect(CoalescedEnvironmentRefresh(
            generation: 2,
            reasons: [.spaceTransitionEnded]
        ).description == "space transition ended")
    }

    @Test("Space transition preservation covers inventory-only refreshes")
    func spaceTransitionPreservationCoversInventoryOnlyRefreshes() {
        #expect(shouldPreserveSpaceLayouts(
            for: [.windowClosed(WindowID(raw: 44)), .windowOpened(WindowID(raw: 45))],
            duringSpaceTransition: true
        ))
        #expect(shouldPreserveSpaceLayouts(
            for: [.windowClosed(WindowID(raw: 44)), .spaceSettled],
            duringSpaceTransition: false
        ))
        #expect(!shouldPreserveSpaceLayouts(
            for: [.windowClosed(WindowID(raw: 44)), .windowOpened(WindowID(raw: 45))],
            duringSpaceTransition: false
        ))
        #expect(!shouldPreserveSpaceLayouts(
            for: [.spaceSettled, .spaceTransitionEnded],
            duringSpaceTransition: false
        ))
    }

    @Test("Space-settle refreshes do not persist restore state")
    func spaceSettleRefreshesDoNotPersistRestoreState() {
        #expect(shouldPersistRestoreAfterEnvironmentRefresh(reasons: [.windowClosed(WindowID(raw: 44))]))
        #expect(!shouldPersistRestoreAfterEnvironmentRefresh(reasons: [.spaceSettled]))
        #expect(!shouldPersistRestoreAfterEnvironmentRefresh(reasons: [
            .windowClosed(WindowID(raw: 44)),
            .spaceSettled
        ]))
        #expect(shouldPersistRestoreAfterEnvironmentRefresh(reasons: [.spaceTransitionEnded]))
        #expect(shouldPersistRestoreAfterEnvironmentRefresh(reasons: [
            .spaceSettled,
            .spaceTransitionEnded
        ]))
        #expect(!shouldPersistRestoreAfterEnvironmentRefresh(
            reasons: [.spaceSettled, .spaceTransitionEnded],
            preservedSpaceLayouts: true
        ))
        #expect(!shouldPersistRestoreAfterEnvironmentRefresh(
            reasons: [.windowClosed(WindowID(raw: 44))],
            preservedSpaceLayouts: true
        ))
    }

    @Test("Preserved refreshes defer pending tile rule application")
    func preservedRefreshesDeferPendingTileRuleApplication() {
        #expect(shouldApplyPendingTileRulesAfterEnvironmentRefresh(preservedSpaceLayouts: false))
        #expect(!shouldApplyPendingTileRulesAfterEnvironmentRefresh(preservedSpaceLayouts: true))
    }
}
