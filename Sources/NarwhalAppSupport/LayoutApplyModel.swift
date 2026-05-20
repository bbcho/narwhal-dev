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
        clamps.reduce(into: [:]) { result, clamp in
            result[clamp.windowID] = (result[clamp.windowID] ?? WindowConstraints()).merged(with: clamp.observed)
        }
    }
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

public func recordLayoutFrameWrite(
    windowID: WindowID,
    targetFrame: CGRect,
    observation: LayoutFrameWriteObservation,
    in result: LayoutApplyResult
) -> LayoutApplyProgress {
    switch observation {
    case .converged(let actual):
        var applied = result.applied
        applied[windowID] = actual
        return LayoutApplyProgress(
            result: LayoutApplyResult(
                applied: applied,
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
