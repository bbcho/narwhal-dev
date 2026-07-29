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
        case .converged, .clamped:
            #expect(Bool(false), "Expected the uncorrected Firefox frame spill to fail")
        }
    }

    @Test("A corrected browser-chrome frame inside its planned cell is successful")
    func correctedBrowserFrameIsConverged() {
        let target = CGRect(x: 16, y: 499.36, width: 1_410, height: 1_076.64)
        let actual = CGRect(x: 16, y: 515, width: 1_410, height: 1_060)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .converged(let settled):
            #expect(settled == actual)
        case .clamped, .failed:
            #expect(Bool(false), "Expected the contained Firefox frame to converge")
        }
    }

    @Test("Stable Terminal grid spill is deferred to topology reconciliation")
    func stableTerminalGridSpillConvergesAfterRetries() {
        let target = CGRect(x: 1504, y: 550.666_666_666_7, width: 1504, height: 520.666_666_666_7)
        let actual = CGRect(x: 1504, y: 551, width: 1507, height: 525)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .converged(let settled):
            #expect(settled == actual)
        case .clamped, .failed:
            #expect(Bool(false), "Expected stable grid snapping to reach topology reconciliation")
        }
    }

    @Test("Stable Firefox grid expansion anchored to the trailing edge reaches topology reconciliation")
    func stableFirefoxTrailingEdgeExpansionConvergesAfterRetries() {
        let target = CGRect(x: 0, y: 551, width: 3_008, height: 521)
        let actual = CGRect(x: 0, y: 546, width: 3_000, height: 526)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .converged(let settled):
            #expect(settled == actual)
        case .clamped, .failed:
            #expect(Bool(false), "Expected stable edge-anchored Firefox snapping to reach topology reconciliation")
        }
    }

    @Test("A corrected Terminal frame inside its planned cell is successful")
    func correctedTerminalFrameIsConverged() {
        let target = CGRect(x: 1504, y: 550.666_666_666_7, width: 1504, height: 520.666_666_666_7)
        let actual = CGRect(x: 1504, y: 551, width: 1500, height: 511)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .converged(let settled):
            #expect(settled == actual)
        case .clamped, .failed:
            #expect(Bool(false), "Expected the contained Terminal frame to converge")
        }
    }

    @Test("Contained browser and Terminal grid undershoot remains settled")
    func containedAppGridUndershootIsSettled() {
        #expect(axFrameWriteSettledInsideTarget(
            target: CGRect(x: 0, y: 551, width: 3008, height: 521),
            actual: CGRect(x: 0, y: 551, width: 2966, height: 521)
        ))
        #expect(axFrameWriteSettledInsideTarget(
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

    @Test("Initial write does not correct a stale pre-write position")
    func initialWriteUsesRequestedTarget() {
        let target = CGRect(x: 4, y: 57, width: 2_998, height: 371)
        let stale = CGRect(x: 4, y: 34, width: 2_998, height: 371)

        #expect(axFrameWriteRetryTarget(
            target: target,
            actual: stale,
            previousAttemptCount: 0
        ) == target)
    }

    @Test("A read-back overflow enables bounded containment correction")
    func retryCorrectsObservedOverflow() {
        let target = CGRect(x: 4, y: 34, width: 744, height: 1_554)
        let observed = CGRect(x: 4, y: 34, width: 744, height: 1_561)

        #expect(axFrameWriteRetryTarget(
            target: target,
            actual: observed,
            previousAttemptCount: 1
        ) == CGRect(x: 4, y: 34, width: 744, height: 1_543))
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
        case .failed, .clamped:
            break
        case .converged:
            #expect(Bool(false), "Expected a stale frame not to converge")
        }
    }
}
