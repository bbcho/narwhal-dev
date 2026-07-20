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
}
