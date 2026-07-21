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

    @Test("Uncorrected Terminal character-grid spill is not accepted as a successful write")
    func uncorrectedTerminalCharacterGridSpillIsNotConverged() {
        let target = CGRect(x: 1504, y: 550.666_666_666_7, width: 1504, height: 520.666_666_666_7)
        let actual = CGRect(x: 1504, y: 551, width: 1507, height: 525)

        switch AXClient().frameWriteDidNotConverge(
            target: target,
            actualFrames: [actual, actual]
        ) {
        case .failed:
            break
        case .converged, .clamped:
            #expect(Bool(false), "Expected an uncorrected frame spill to fail")
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
