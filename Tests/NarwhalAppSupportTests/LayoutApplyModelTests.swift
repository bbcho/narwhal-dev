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

    @Test("Planned layout apply decision commits with focused applied frame")
    func plannedLayoutApplyDecisionCommitsWithFocusedAppliedFrame() {
        let focused = WindowID(raw: 50)
        let desiredFrame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let appliedFrame = CGRect(x: 0, y: 0, width: 300, height: 199)
        let plan = commandPlanFixture(focused: focused, tiled: [focused: desiredFrame])
        let applyResult = LayoutApplyResult(applied: [focused: appliedFrame], clamps: [], failures: [])

        let decision = plannedLayoutApplyDecision(plan: plan, applyResult: applyResult, retryOnClamp: true)

        #expect(decision == .commit(
            appliedFrames: [focused: appliedFrame],
            focusUpdate: .target(windowID: focused, frame: appliedFrame)
        ))
    }

    @Test("Frame write intents are pure ordered metadata projections")
    func frameWriteIntentsArePureOrderedMetadataProjections() {
        let focused = WindowID(raw: 50)
        let other = WindowID(raw: 51)
        let missing = WindowID(raw: 52)
        let focusedFrame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let otherFrame = CGRect(x: 300, y: 0, width: 300, height: 200)
        let missingFrame = CGRect(x: 600, y: 0, width: 300, height: 200)
        let focusedMetadata = windowMetadata(id: focused, frame: focusedFrame)
        let otherMetadata = windowMetadata(id: other, frame: otherFrame)
        let plan = commandPlanFixture(
            focused: focused,
            tiled: [
                focused: focusedFrame,
                other: otherFrame,
                missing: missingFrame
            ],
            windows: [
                focused: focusedMetadata,
                other: otherMetadata
            ]
        )

        let intents = layoutFrameWriteIntents(for: plan)

        #expect(intents == [
            .write(windowID: other, metadata: otherMetadata, targetFrame: otherFrame),
            .missingMetadata(windowID: missing, targetFrame: missingFrame),
            .write(windowID: focused, metadata: focusedMetadata, targetFrame: focusedFrame)
        ])
    }

    @Test("Planned layout apply decision clears missing focused frame")
    func plannedLayoutApplyDecisionClearsMissingFocusedFrame() {
        let focused = WindowID(raw: 60)
        let plan = commandPlanFixture(focused: focused, tiled: [:])
        let applyResult = LayoutApplyResult(applied: [:], clamps: [], failures: [])

        let decision = plannedLayoutApplyDecision(plan: plan, applyResult: applyResult, retryOnClamp: true)

        #expect(decision == .commit(appliedFrames: [:], focusUpdate: .clear))
    }

    @Test("Planned layout apply decision reports failures without retry")
    func plannedLayoutApplyDecisionReportsFailuresWithoutRetry() {
        let failed = WindowID(raw: 70)
        let target = CGRect(x: 10, y: 20, width: 300, height: 200)
        let plan = commandPlanFixture(focused: nil, tiled: [failed: target])
        let applyResult = LayoutApplyResult(
            applied: [:],
            clamps: [],
            failures: [LayoutApplyFailure(windowID: failed, targetFrame: target, message: "AX failed")]
        )

        let decision = plannedLayoutApplyDecision(plan: plan, applyResult: applyResult, retryOnClamp: true)

        guard case .fail(let appliedFrames, let failureCount, let summary) = decision else {
            Issue.record("Expected failure decision")
            return
        }
        #expect(appliedFrames == [:])
        #expect(failureCount == 1)
        #expect(summary.contains(failed.description))
        #expect(summary.contains("AX failed"))
    }

    @Test("Planned layout apply decision carries clamp retry data")
    func plannedLayoutApplyDecisionCarriesClampRetryData() {
        let clamped = WindowID(raw: 80)
        let target = CGRect(x: 10, y: 20, width: 300, height: 200)
        let actual = CGRect(x: 10, y: 20, width: 180, height: 200)
        let observed = WindowConstraints(minWidth: 180)
        let plan = commandPlanFixture(focused: nil, tiled: [clamped: target])
        let applyResult = LayoutApplyResult(
            applied: [WindowID(raw: 79): CGRect(x: 0, y: 0, width: 100, height: 100)],
            clamps: [LayoutApplyClamp(windowID: clamped, targetFrame: target, actualFrame: actual, observed: observed)],
            failures: []
        )

        let decision = plannedLayoutApplyDecision(plan: plan, applyResult: applyResult, retryOnClamp: false)

        guard case .clamp(let appliedFrames, let observedConstraints, let shouldRetry, let summary) = decision else {
            Issue.record("Expected clamp decision")
            return
        }
        #expect(appliedFrames == applyResult.applied)
        #expect(observedConstraints == [clamped: observed])
        #expect(!shouldRetry)
        #expect(summary.contains(clamped.description))
        #expect(summary.contains("minWidth=180.0"))
    }

    private func commandPlanFixture(
        focused: WindowID?,
        tiled: [WindowID: CGRect],
        windows: [WindowID: WindowMetadata] = [:]
    ) -> CommandPlanResult {
        CommandPlanResult(
            focusedWindowID: focused,
            desiredLayout: DesiredLayout(
                generation: LayoutGeneration(raw: 1),
                layout: Layout(tiled: tiled, floatingZOrder: [], hidden: []),
                delta: LayoutDelta(moves: tiled, raises: [], hides: [], shows: Set(tiled.keys))
            ),
            windows: windows,
            plannedWorld: .empty,
            undoWorld: nil
        )
    }

    private func windowMetadata(id: WindowID, frame: CGRect) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(42),
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }
}
