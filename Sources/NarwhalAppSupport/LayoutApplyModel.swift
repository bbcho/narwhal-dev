import CoreGraphics
import NarwhalCore

public struct LayoutApplyFailure: Equatable, Sendable {
    public let windowID: WindowID
    public let targetFrame: CGRect
    public let message: String

    public init(windowID: WindowID, targetFrame: CGRect, message: String) {
        self.windowID = windowID
        self.targetFrame = targetFrame
        self.message = message
    }
}

public struct LayoutApplyClamp: Equatable, Sendable {
    public let windowID: WindowID
    public let targetFrame: CGRect
    public let actualFrame: CGRect
    public let observed: WindowConstraints

    public init(
        windowID: WindowID,
        targetFrame: CGRect,
        actualFrame: CGRect,
        observed: WindowConstraints
    ) {
        self.windowID = windowID
        self.targetFrame = targetFrame
        self.actualFrame = actualFrame
        self.observed = observed
    }
}

public struct LayoutApplyResult: Equatable, Sendable {
    public let applied: [WindowID: CGRect]
    public let clamps: [LayoutApplyClamp]
    public let failures: [LayoutApplyFailure]

    public init(
        applied: [WindowID: CGRect],
        clamps: [LayoutApplyClamp],
        failures: [LayoutApplyFailure]
    ) {
        self.applied = applied
        self.clamps = clamps
        self.failures = failures
    }

    public static let empty = LayoutApplyResult(applied: [:], clamps: [], failures: [])

    public var succeeded: Bool {
        clamps.isEmpty && failures.isEmpty
    }

    public var observedConstraints: [WindowID: WindowConstraints] {
        clamps.reduce([WindowID: WindowConstraints]()) { constraints, clamp in
            constraints.merging([
                clamp.windowID: (constraints[clamp.windowID] ?? WindowConstraints()).merged(with: clamp.observed)
            ]) { _, replacement in replacement }
        }
    }
}

public enum PlannedLayoutFocusUpdate: Equatable, Sendable {
    case target(windowID: WindowID, frame: CGRect)
    case clear
}

public enum PlannedLayoutApplyDecision: Equatable, Sendable {
    case commit(appliedFrames: [WindowID: CGRect], focusUpdate: PlannedLayoutFocusUpdate?)
    case fail(appliedFrames: [WindowID: CGRect], failureCount: Int, summary: String)
    case clamp(
        appliedFrames: [WindowID: CGRect],
        observedConstraints: [WindowID: WindowConstraints],
        shouldRetry: Bool,
        summary: String
    )
}

public func plannedLayoutApplyDecision(
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
            appliedFrames: applyResult.applied,
            failureCount: applyResult.failures.count,
            summary: layoutApplyFailureSummary(applyResult.failures)
        )
    }

    return .clamp(
        appliedFrames: applyResult.applied,
        observedConstraints: applyResult.observedConstraints,
        shouldRetry: retryOnClamp,
        summary: layoutApplyClampSummary(applyResult.clamps)
    )
}

public enum LayoutFrameWriteObservation: Equatable, Sendable {
    case converged(actual: CGRect)
    case clamped(actual: CGRect, observed: WindowConstraints)
    case failed(message: String)
}

public enum LayoutApplyProgressDecision: Equatable, Sendable {
    case continueApplying
    case stopApplying
}

public struct LayoutApplyProgress: Equatable, Sendable {
    public let result: LayoutApplyResult
    public let decision: LayoutApplyProgressDecision

    public init(result: LayoutApplyResult, decision: LayoutApplyProgressDecision) {
        self.result = result
        self.decision = decision
    }
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
    "minWidth=\(constraints.minWidth.map { String($0) } ?? "nil") minHeight=\(constraints.minHeight.map { String($0) } ?? "nil")"
}

public func recordLayoutFrameWrite(
    windowID: WindowID,
    targetFrame: CGRect,
    observation: LayoutFrameWriteObservation,
    in result: LayoutApplyResult
) -> LayoutApplyProgress {
    switch observation {
    case .converged(let actual):
        return LayoutApplyProgress(
            result: LayoutApplyResult(
                applied: result.applied.merging([windowID: actual]) { _, replacement in replacement },
                clamps: result.clamps,
                failures: result.failures
            ),
            decision: .continueApplying
        )

    case .clamped(let actual, let observed):
        return LayoutApplyProgress(
            result: LayoutApplyResult(
                applied: result.applied,
                clamps: result.clamps + [
                    LayoutApplyClamp(
                        windowID: windowID,
                        targetFrame: targetFrame,
                        actualFrame: actual,
                        observed: observed
                    )
                ],
                failures: result.failures
            ),
            decision: .stopApplying
        )

    case .failed(let message):
        return LayoutApplyProgress(
            result: LayoutApplyResult(
                applied: result.applied,
                clamps: result.clamps,
                failures: result.failures + [
                    LayoutApplyFailure(
                        windowID: windowID,
                        targetFrame: targetFrame,
                        message: message
                    )
                ]
            ),
            decision: .stopApplying
        )
    }
}
