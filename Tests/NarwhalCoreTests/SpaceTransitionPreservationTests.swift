import Testing
@testable import NarwhalCore

@Suite("Space transition preservation")
struct SpaceTransitionPreservationTests {
    @Test("Beginning preservation records active generation and timer plan")
    func beginPreservationRecordsGenerationAndPlan() {
        let start = beginSpaceTransitionPreservation(
            in: .empty,
            settledRefreshDelays: [0.35, 0.80],
            preserveEndDelay: 1.25
        )

        #expect(start.generation == 1)
        #expect(start.state == SpaceTransitionPreservationState(
            activeGeneration: 1,
            nextGeneration: 2
        ))
        #expect(start.settledRefreshDelays == [0.35, 0.80])
        #expect(start.preserveEndDelay == 1.25)
        #expect(start.state.isPreservingSpaceLayouts)
    }

    @Test("Cancel clears active preservation without rewinding generation")
    func cancelClearsActivePreservationWithoutRewindingGeneration() {
        let start = beginSpaceTransitionPreservation(
            in: .empty,
            settledRefreshDelays: [],
            preserveEndDelay: 1.25
        )

        let cancelled = cancelSpaceTransitionPreservation(in: start.state)
        let next = beginSpaceTransitionPreservation(
            in: cancelled,
            settledRefreshDelays: [],
            preserveEndDelay: 1.25
        )

        #expect(cancelled == SpaceTransitionPreservationState(
            activeGeneration: nil,
            nextGeneration: 2
        ))
        #expect(!cancelled.isPreservingSpaceLayouts)
        #expect(next.generation == 2)
    }

    @Test("Matching preservation completion clears state and schedules final refresh")
    func matchingCompletionClearsStateAndSchedulesFinalRefresh() {
        let start = beginSpaceTransitionPreservation(
            in: .empty,
            settledRefreshDelays: [],
            preserveEndDelay: 1.25
        )

        let completion = completeSpaceTransitionPreservation(
            generation: start.generation,
            in: start.state
        )

        #expect(completion.state == SpaceTransitionPreservationState(
            activeGeneration: nil,
            nextGeneration: 2
        ))
        #expect(completion.decision == .scheduleRefresh)
    }

    @Test("Stale preservation completion cannot end a newer transition")
    func staleCompletionCannotEndNewerTransition() {
        let first = beginSpaceTransitionPreservation(
            in: .empty,
            settledRefreshDelays: [],
            preserveEndDelay: 1.25
        )
        let cancelled = cancelSpaceTransitionPreservation(in: first.state)
        let second = beginSpaceTransitionPreservation(
            in: cancelled,
            settledRefreshDelays: [],
            preserveEndDelay: 1.25
        )

        let stale = completeSpaceTransitionPreservation(
            generation: first.generation,
            in: second.state
        )

        #expect(stale.state == second.state)
        #expect(stale.decision == .stale(activeGeneration: second.generation))
    }
}
