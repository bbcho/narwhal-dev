#if NARWHAL_ENABLE_VERIFIERS
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

// Verifier-only: the real-app verifier still drives frames through
// LayoutApplier.apply and decides commit/fail/clamp here. Production uses
// LayoutTransactionCoordinator instead.

enum PlannedLayoutApplyDecision: Equatable, Sendable {
    case commit(appliedFrames: [WindowID: CGRect], focusUpdate: PlannedLayoutFocusUpdate?)
    case fail(failureCount: Int, summary: String)
    case clamp(
        observedConstraints: [WindowID: WindowConstraints],
        shouldRetry: Bool,
        summary: String
    )
}

func plannedLayoutApplyDecision(
    plan: CommandPlanResult,
    applyResult: LayoutApplyResult,
    retryOnClamp: Bool
) -> PlannedLayoutApplyDecision {
    if applyResult.succeeded {
        return .commit(
            appliedFrames: applyResult.applied,
            focusUpdate: plannedLayoutFocusUpdate(plan: plan, appliedFrames: applyResult.applied)
        )
    }

    if !applyResult.failures.isEmpty {
        return .fail(
            failureCount: applyResult.failures.count,
            summary: layoutApplyFailureSummary(applyResult.failures)
        )
    }

    return .clamp(
        observedConstraints: applyResult.observedConstraints,
        shouldRetry: retryOnClamp,
        summary: layoutApplyClampSummary(applyResult.clamps)
    )
}

private func plannedLayoutFocusUpdate(
    plan: CommandPlanResult,
    appliedFrames: [WindowID: CGRect]
) -> PlannedLayoutFocusUpdate? {
    guard let focusedWindowID = plan.focusedWindowID else { return nil }
    guard let frame = appliedFrames[focusedWindowID] ?? plan.desiredLayout.layout.tiled[focusedWindowID] else {
        return .clear
    }
    return .target(windowID: focusedWindowID, frame: frame)
}

private func layoutApplyFailureSummary(_ failures: [LayoutApplyFailure]) -> String {
    failures
        .map { "\($0.windowID.description) target=\($0.targetFrame.debugDescription) error=\($0.message)" }
        .joined(separator: "; ")
}

private func layoutApplyClampSummary(_ clamps: [LayoutApplyClamp]) -> String {
    clamps
        .map {
            "\($0.windowID.description) target=\($0.targetFrame.debugDescription) actual=\($0.actualFrame.debugDescription) observed=\(windowConstraintsDebugDescription($0.observed))"
        }
        .joined(separator: "; ")
}

private func windowConstraintsDebugDescription(_ constraints: WindowConstraints) -> String {
    [
        "minWidth=\(constraints.minWidth.map { String($0) } ?? "nil")",
        "minHeight=\(constraints.minHeight.map { String($0) } ?? "nil")",
        "maxWidth=\(constraints.maxWidth.map { String($0) } ?? "nil")",
        "maxHeight=\(constraints.maxHeight.map { String($0) } ?? "nil")",
        "widthAnchor=\(constraints.widthAnchor?.rawValue ?? "nil")",
        "heightAnchor=\(constraints.heightAnchor?.rawValue ?? "nil")"
    ].joined(separator: " ")
}
#endif
