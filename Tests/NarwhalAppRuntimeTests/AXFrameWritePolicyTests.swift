import ApplicationServices
import CoreGraphics
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("AX frame write policy")
struct AXFrameWritePolicyTests {
    @Test("A shrinking window is sized before it is moved")
    func shrinkingWindowUsesSizeFirstOrdering() {
        let current = CGRect(x: 684, y: 241, width: 2_195, height: 1_346)
        let target = CGRect(x: 0, y: 811, width: 1_504, height: 781)

        #expect(axFrameWriteOrder(current: current, target: target) == .sizeThenPosition)
    }

    @Test("A window expanding toward the display origin is positioned first")
    func expandingWindowUsesPositionFirstOrdering() {
        let current = CGRect(x: 1_504, y: 30, width: 1_504, height: 1_562)
        let target = CGRect(x: 0, y: 30, width: 3_008, height: 1_562)

        #expect(axFrameWriteOrder(current: current, target: target) == .positionThenSize)
    }

    @Test("One or changing read-back cannot become a persistent constraint")
    func constraintInferenceRequiresStableReadBacks() {
        let target = CGRect(x: 0, y: 811, width: 1_504, height: 781)
        let first = CGRect(x: 0, y: 811, width: 1_504, height: 881)
        let changing = CGRect(x: 0, y: 811, width: 1_504, height: 831)

        #expect(confirmedObservedConstraints(target: target, actualFrames: [first]) == nil)
        #expect(confirmedObservedConstraints(target: target, actualFrames: [first, changing]) == nil)
        #expect(
            confirmedObservedConstraints(target: target, actualFrames: [first, first])
                == WindowConstraints(minHeight: 881)
        )
    }

    @Test("An uncorrected browser-chrome offset that spills outside its cell is rejected")
    func uncorrectedBrowserFrameSpillIsRejected() {
        let target = CGRect(x: 16, y: 499.36, width: 1_410, height: 1_076.64)
        let actual = CGRect(x: 16, y: 515, width: 1_410, height: 1_076)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .failed:
            break
        case .converged, .constrained, .clamped:
            #expect(Bool(false), "Expected the uncorrected Firefox frame spill to fail")
        }
    }

    @Test("A stable browser-chrome offset with no anchored edge is rejected")
    func browserFrameWithoutAnchoredEdgeIsRejected() {
        let target = CGRect(x: 16, y: 499.36, width: 1_410, height: 1_076.64)
        let actual = CGRect(x: 16, y: 515, width: 1_410, height: 1_060)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .failed:
            break
        case .converged, .constrained, .clamped:
            #expect(Bool(false), "Expected the unanchored Firefox mismatch to fail")
        }
    }

    @Test("Stable Terminal grid expansion reports a minimum constraint")
    func stableTerminalGridExpansionIsClamped() {
        let target = CGRect(x: 1504, y: 550.666_666_666_7, width: 1504, height: 520.666_666_666_7)
        let actual = CGRect(x: 1504, y: 551, width: 1507, height: 525)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .clamped(let settled, let observed):
            #expect(settled == actual)
            #expect(observed == WindowConstraints(minWidth: 1_507, minHeight: 525))
        case .converged, .constrained, .failed:
            #expect(Bool(false), "Expected the Terminal expansion to become a minimum constraint")
        }
    }

    @Test("Stable Firefox grid expansion reports a minimum constraint")
    func stableFirefoxTrailingEdgeExpansionIsClamped() {
        let target = CGRect(x: 0, y: 551, width: 3_008, height: 521)
        let actual = CGRect(x: 0, y: 546, width: 3_000, height: 526)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .clamped(let settled, let observed):
            #expect(settled == actual)
            #expect(observed == WindowConstraints(minHeight: 526))
        case .converged, .constrained, .failed:
            #expect(Bool(false), "Expected the Firefox expansion to become a minimum constraint")
        }
    }

    @Test("A stable contained Terminal mismatch is reported as constrained")
    func correctedTerminalFrameIsConstrained() {
        let target = CGRect(x: 1504, y: 550.666_666_666_7, width: 1504, height: 520.666_666_666_7)
        let actual = CGRect(x: 1504, y: 551, width: 1500, height: 511)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .constrained(let settled):
            #expect(settled == actual)
        case .converged, .clamped, .failed:
            #expect(Bool(false), "Expected the Terminal mismatch to remain explicit")
        }
    }

    @Test("Contained browser and Terminal grid undershoot is not exact")
    func containedAppGridUndershootIsNotExact() {
        #expect(!axFrameWriteSettledInsideTarget(
            target: CGRect(x: 0, y: 551, width: 3008, height: 521),
            actual: CGRect(x: 0, y: 551, width: 2966, height: 521)
        ))
        #expect(!axFrameWriteSettledInsideTarget(
            target: CGRect(x: 0, y: 1280, width: 3008, height: 312),
            actual: CGRect(x: 0, y: 1280, width: 3005, height: 287)
        ))
    }

    @Test("Only an invalid AX element retries against a refreshed window")
    func staleElementRefreshPolicy() {
        #expect(axFrameWriteRequiresElementRefresh(
            .setAttributeFailed("AXPosition", .invalidUIElement)
        ))
        #expect(!axFrameWriteRequiresElementRefresh(
            .setAttributeFailed("AXPosition", .illegalArgument)
        ))
    }

    @Test("A stale contained frame with excessive dimension drift is not converged")
    func staleContainedFrameIsNotConverged() {
        let target = CGRect(x: 1_880, y: 1_354, width: 376, height: 238)
        let actual = CGRect(x: 1_880, y: 1_397, width: 373, height: 189)

        #expect(!frameWriteApproximatelySettled(
            target: target,
            actual: actual,
            tolerance: Double(frameWriteSettleTolerance)
        ))
        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .failed, .constrained, .clamped:
            break
        case .converged:
            #expect(Bool(false), "Expected a stale frame not to converge")
        }
    }
}
