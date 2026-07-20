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
                .displaySettled,
                .spaceSettled,
                .tiledBorderTargetMismatch(WindowID(raw: 3))
            ]
        )

        #expect(CoalescedEnvironmentRefresh(generation: 1, reasons: [.displayChanged]).description == "display changed")
        #expect(CoalescedEnvironmentRefresh(generation: 1, reasons: [.displaySettled]).description == "display settled")
        #expect(request.description == "6 coalesced events: window opened w1, window closed w2, display changed, display settled, space settled, tiled border target mismatch w3")
        #expect(CoalescedEnvironmentRefresh(
            generation: 2,
            reasons: [.spaceTransitionEnded]
        ).description == "space transition ended")
    }

    @Test("Environment refresh policy separates reconciliation, persistence, and deferred cleanup")
    func environmentRefreshPolicySeparatesEffects() {
        expectPolicy(environmentRefreshPolicy(
            for: [.windowClosed(WindowID(raw: 44)), .windowOpened(WindowID(raw: 45))],
            duringSpaceTransition: true
        ),
            preserveSpaceLayouts: true,
            reconciliationMode: .preserveLayouts,
            persistRestore: false,
            applyPendingTileRules: false,
            scheduleDeferredCleanup: false,
            reflowTiledLayout: false
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.windowClosed(WindowID(raw: 44)), .spaceSettled],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: true,
            reconciliationMode: .preserveLayouts,
            persistRestore: false,
            applyPendingTileRules: false,
            scheduleDeferredCleanup: false,
            reflowTiledLayout: false
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.windowClosed(WindowID(raw: 44)), .windowOpened(WindowID(raw: 45))],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: false,
            reconciliationMode: .activeWorkspaceCleanup,
            persistRestore: true,
            applyPendingTileRules: true,
            scheduleDeferredCleanup: false,
            reflowTiledLayout: false
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.spaceSettled, .spaceTransitionEnded],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: true,
            reconciliationMode: .preserveLayouts,
            persistRestore: false,
            applyPendingTileRules: false,
            scheduleDeferredCleanup: false,
            reflowTiledLayout: false
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.displayChanged],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: true,
            reconciliationMode: .preserveLayouts,
            persistRestore: false,
            applyPendingTileRules: false,
            scheduleDeferredCleanup: true,
            reflowTiledLayout: false
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.windowOpened(WindowID(raw: 46)), .displayChanged],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: true,
            reconciliationMode: .preserveLayouts,
            persistRestore: false,
            applyPendingTileRules: false,
            scheduleDeferredCleanup: true,
            reflowTiledLayout: false
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.displaySettled],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: false,
            reconciliationMode: .displayTopologySettled,
            persistRestore: false,
            applyPendingTileRules: true,
            scheduleDeferredCleanup: false,
            reflowTiledLayout: true
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.tiledBorderTargetMismatch(WindowID(raw: 47))],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: false,
            reconciliationMode: .activeWorkspaceCleanup,
            persistRestore: true,
            applyPendingTileRules: true,
            scheduleDeferredCleanup: false,
            reflowTiledLayout: false
        )
        expectPolicy(environmentRefreshPolicy(
            for: [.displaySettled, .displayChanged],
            duringSpaceTransition: false
        ),
            preserveSpaceLayouts: true,
            reconciliationMode: .preserveLayouts,
            persistRestore: false,
            applyPendingTileRules: false,
            scheduleDeferredCleanup: true,
            reflowTiledLayout: false
        )
    }

    private func expectPolicy(
        _ policy: EnvironmentRefreshPolicy,
        preserveSpaceLayouts: Bool,
        reconciliationMode: EnvironmentReconciliationMode,
        persistRestore: Bool,
        applyPendingTileRules: Bool,
        scheduleDeferredCleanup: Bool,
        reflowTiledLayout: Bool
    ) {
        #expect(policy.preserveSpaceLayouts == preserveSpaceLayouts)
        #expect(policy.reconciliationMode == reconciliationMode)
        #expect(policy.persistRestore == persistRestore)
        #expect(policy.applyPendingTileRules == applyPendingTileRules)
        #expect(policy.scheduleDeferredCleanup == scheduleDeferredCleanup)
        #expect(policy.reflowTiledLayout == reflowTiledLayout)
    }
}
