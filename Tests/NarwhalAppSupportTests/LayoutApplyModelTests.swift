import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Layout apply model")
struct LayoutApplyModelTests {
    @Test("Converged frame write records applied frame and continues")
    func convergedFrameWriteRecordsAppliedFrameAndContinues() {
        let window = WindowID(raw: 10)
        let target = CGRect(x: 10, y: 20, width: 300, height: 200)
        let actual = CGRect(x: 10, y: 20, width: 300, height: 199)

        let progress = recordLayoutFrameWrite(
            windowID: window,
            targetFrame: target,
            observation: .converged(actual: actual),
            in: .empty
        )

        #expect(progress.decision == .continueApplying)
        #expect(progress.result == LayoutApplyResult(
            applied: [window: actual],
            clamps: [],
            failures: []
        ))
        #expect(progress.result.succeeded)
    }

    @Test("Clamp records observed constraint and stops")
    func clampRecordsObservedConstraintAndStops() {
        let first = WindowID(raw: 20)
        let clamped = WindowID(raw: 21)
        let alreadyApplied = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 100, y: 0, width: 300, height: 200)
        let actual = CGRect(x: 100, y: 0, width: 180, height: 200)
        let observed = WindowConstraints(minWidth: 180)
        let existing = LayoutApplyResult(
            applied: [first: alreadyApplied],
            clamps: [],
            failures: []
        )

        let progress = recordLayoutFrameWrite(
            windowID: clamped,
            targetFrame: target,
            observation: .clamped(actual: actual, observed: observed),
            in: existing
        )

        #expect(progress.decision == .stopApplying)
        #expect(progress.result.applied == [first: alreadyApplied])
        #expect(progress.result.clamps == [
            LayoutApplyClamp(
                windowID: clamped,
                targetFrame: target,
                actualFrame: actual,
                observed: observed
            )
        ])
        #expect(progress.result.failures == [])
        #expect(!progress.result.succeeded)
        #expect(progress.result.observedConstraints == [clamped: observed])
    }

    @Test("Failure records message and stops without dropping prior applied frames")
    func failureRecordsMessageAndStops() {
        let first = WindowID(raw: 30)
        let failed = WindowID(raw: 31)
        let appliedFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 100, y: 0, width: 300, height: 200)
        let existing = LayoutApplyResult(
            applied: [first: appliedFrame],
            clamps: [],
            failures: []
        )

        let progress = recordLayoutFrameWrite(
            windowID: failed,
            targetFrame: target,
            observation: .failed(message: "AX write failed"),
            in: existing
        )

        #expect(progress.decision == .stopApplying)
        #expect(progress.result.applied == [first: appliedFrame])
        #expect(progress.result.clamps == [])
        #expect(progress.result.failures == [
            LayoutApplyFailure(
                windowID: failed,
                targetFrame: target,
                message: "AX write failed"
            )
        ])
        #expect(!progress.result.succeeded)
    }

    @Test("Observed constraints merge repeated clamp observations by maximum")
    func observedConstraintsMergeRepeatedClampObservations() {
        let window = WindowID(raw: 40)
        let target = CGRect(x: 0, y: 0, width: 300, height: 200)
        let first = recordLayoutFrameWrite(
            windowID: window,
            targetFrame: target,
            observation: .clamped(
                actual: CGRect(x: 0, y: 0, width: 180, height: 100),
                observed: WindowConstraints(minWidth: 180)
            ),
            in: .empty
        )
        let second = recordLayoutFrameWrite(
            windowID: window,
            targetFrame: target,
            observation: .clamped(
                actual: CGRect(x: 0, y: 0, width: 170, height: 140),
                observed: WindowConstraints(minHeight: 140)
            ),
            in: first.result
        )

        #expect(second.result.observedConstraints == [
            window: WindowConstraints(minWidth: 180, minHeight: 140)
        ])
    }
}
