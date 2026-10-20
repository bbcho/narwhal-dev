import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Layout apply model")
struct LayoutApplyModelTests {
    @Test("Observed constraints merge repeated clamp observations by maximum")
    func observedConstraintsMergeRepeatedClampObservations() {
        let window = WindowID(raw: 40)
        let target = CGRect(x: 0, y: 0, width: 300, height: 200)
        let result = LayoutApplyResult(
            applied: [:],
            clamps: [
                LayoutApplyClamp(
                    windowID: window,
                    targetFrame: target,
                    actualFrame: CGRect(x: 0, y: 0, width: 180, height: 100),
                    observed: WindowConstraints(minWidth: 180)
                ),
                LayoutApplyClamp(
                    windowID: window,
                    targetFrame: target,
                    actualFrame: CGRect(x: 0, y: 0, width: 170, height: 140),
                    observed: WindowConstraints(minHeight: 140)
                ),
            ],
            failures: []
        )

        #expect(result.observedConstraints == [
            window: WindowConstraints(minWidth: 180, minHeight: 140)
        ])
    }

    @Test("Frame writes follow seam dependencies from leading to trailing")
    func frameWritesFollowSeamDependencies() {
        let right = WindowID(raw: 100)
        let topLeft = WindowID(raw: 101)
        let focusedBottomLeft = WindowID(raw: 102)
        let planned = [
            right: CGRect(x: 756, y: 33, width: 756, height: 871),
            topLeft: CGRect(x: 0, y: 33, width: 756, height: 435.5),
            focusedBottomLeft: CGRect(x: 0, y: 468.5, width: 756, height: 435.5)
        ]

        let order = leadingFrameWriteOrder(planned: planned, candidates: Set(planned.keys), innerGap: 0)

        #expect(order == [topLeft, focusedBottomLeft, right])
    }

    @Test("Clamp retries continue only for new observations within the attempt bound")
    func clampRetryStateRequiresBoundedProgress() throws {
        let first = WindowID(raw: 80)
        let second = WindowID(raw: 81)
        let initial = LayoutClampRetryState(maxAttempts: 2)

        let afterFirst = try #require(initial.recording([
            first: WindowConstraints(minHeight: 119)
        ]))
        #expect(afterFirst.remainingAttempts == 1)
        #expect(afterFirst.recording([
            first: WindowConstraints(minHeight: 119)
        ]) == nil)

        let afterSecond = try #require(afterFirst.recording([
            second: WindowConstraints(minHeight: 119)
        ]))
        #expect(afterSecond.remainingAttempts == 0)
        #expect(afterSecond.observedConstraints == [
            first: WindowConstraints(minHeight: 119),
            second: WindowConstraints(minHeight: 119)
        ])
        #expect(afterSecond.recording([
            WindowID(raw: 82): WindowConstraints(minHeight: 119)
        ]) == nil)
    }
}
