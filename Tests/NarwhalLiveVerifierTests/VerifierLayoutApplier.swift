#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

// Verifier-only: drives a layout through LayoutFrameTransaction without the
// coordinator's world commit, and reports it as a LayoutApplyResult for
// VerifierLayoutApplyDecision. Production uses LayoutTransactionCoordinator.
@MainActor
struct LayoutApplier {
    let frameWriter: WindowFrameWriter
    let reporter: StartupReporter
    let echoSuppressor: AXEchoSuppressor?

    init(axClient: AXClient, reporter: StartupReporter, echoSuppressor: AXEchoSuppressor? = nil) {
        frameWriter = WindowFrameWriter(axClient: axClient)
        self.reporter = reporter
        self.echoSuppressor = echoSuppressor
    }

    func apply(
        _ plan: CommandPlanResult,
        preserving preservedFrames: [WindowID: CGRect] = [:]
    ) async -> LayoutApplyResult {
        let outcome = await LayoutFrameTransaction(
            frameWriter: frameWriter,
            reporter: reporter,
            echoSuppressor: echoSuppressor
        ).execute(plan, preserving: preservedFrames) { true }
        return applyResult(from: outcome, plan: plan)
    }

    private func applyResult(
        from outcome: LayoutFrameTransactionOutcome,
        plan: CommandPlanResult
    ) -> LayoutApplyResult {
        switch outcome {
        case .applied(_, let appliedFrames):
            return LayoutApplyResult(applied: appliedFrames, clamps: [], failures: [])
        case .constraintObserved(let originalFrames, let observations, let failure):
            let clamps = observations.keys.sorted(by: { $0.raw < $1.raw }).map { windowID in
                LayoutApplyClamp(
                    windowID: windowID,
                    targetFrame: plan.desiredLayout.layout.tiled[windowID] ?? .null,
                    actualFrame: originalFrames[windowID] ?? plan.windows[windowID]?.frame ?? .null,
                    observed: observations[windowID] ?? WindowConstraints()
                )
            }
            reporter.info("Layout transaction restored after constraint: \(failure.message)")
            return LayoutApplyResult(applied: originalFrames, clamps: clamps, failures: [])
        case .rolledBack(let originalFrames, let failure):
            reporter.error("Layout transaction restored after failure: \(failure.message)")
            return LayoutApplyResult(
                applied: originalFrames,
                clamps: [],
                failures: [layoutApplyFailure(failure, plan: plan)]
            )
        case .reconciliationRequired(let originalFrames, let liveFrames, let failure, let rollbackFailures):
            let rollbackSummary = rollbackFailures.map(\.message).joined(separator: "; ")
            reporter.error(
                "Layout rollback incomplete: \(failure.message); rollback failures: \(rollbackSummary)"
            )
            return LayoutApplyResult(
                applied: liveFrames.isEmpty ? originalFrames : liveFrames,
                clamps: [],
                failures: [LayoutApplyFailure(
                    windowID: failure.windowID ?? WindowID(raw: 0),
                    targetFrame: failure.windowID.flatMap { plan.desiredLayout.layout.tiled[$0] } ?? .null,
                    message: "\(failure.message); rollback failed: \(rollbackSummary)"
                )]
            )
        }
    }

    private func layoutApplyFailure(
        _ failure: LayoutFrameTransactionFailure,
        plan: CommandPlanResult
    ) -> LayoutApplyFailure {
        LayoutApplyFailure(
            windowID: failure.windowID ?? WindowID(raw: 0),
            targetFrame: failure.windowID.flatMap { plan.desiredLayout.layout.tiled[$0] } ?? .null,
            message: failure.message
        )
    }
}
#endif
