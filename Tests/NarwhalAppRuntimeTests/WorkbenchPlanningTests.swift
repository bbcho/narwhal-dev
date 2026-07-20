import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Workbench planning")
struct WorkbenchPlanningTests {
    @Test("Named layout partial failures have explicit evidence and recovery")
    func partialExplanation() {
        let result = NamedLayoutMatchResult(
            matches: [MatchedLayoutSlot(
                slotID: LayoutSlotID(rawValue: "editor"),
                windowID: WindowID(raw: 1),
                targetDisplaySlot: 0
            )],
            unmatchedSlots: [UnmatchedLayoutSlot(
                slotID: LayoutSlotID(rawValue: "browser"),
                targetDisplaySlot: 0,
                matcher: LayoutWindowMatcher(bundleID: "com.example.browser")
            )],
            unmatchedWindows: [],
            missingDisplaySlots: [1]
        )

        let explanation = workbenchExplanation(for: .namedLayout(.partialMatch(result)))

        #expect(explanation.title == "Named layout has unmatched targets")
        #expect(explanation.reason.contains("1 window slot"))
        #expect(explanation.reason.contains("1 display"))
        #expect(explanation.canRetryAsPartial)
    }

    @Test("Reset is the only workbench intent requiring a second confirmation")
    func destructiveConfirmation() {
        #expect(WorkbenchIntent.reset.requiresDestructiveConfirmation)
        #expect(!WorkbenchIntent.shuffle.requiresDestructiveConfirmation)
        #expect(!WorkbenchIntent.eject(windowID: WindowID(raw: 1)).requiresDestructiveConfirmation)
    }
}
