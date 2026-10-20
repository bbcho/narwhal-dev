import CoreGraphics
import NarwhalCore

public struct LayoutApplyFailure: Error, Equatable, Sendable {
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

public struct LayoutClampRetryState: Equatable, Sendable {
    public let remainingAttempts: Int
    public let observedConstraints: [WindowID: WindowConstraints]

    public init(maxAttempts: Int) {
        remainingAttempts = max(0, maxAttempts)
        observedConstraints = [:]
    }

    private init(
        remainingAttempts: Int,
        observedConstraints: [WindowID: WindowConstraints]
    ) {
        self.remainingAttempts = remainingAttempts
        self.observedConstraints = observedConstraints
    }

    public func recording(
        _ observations: [WindowID: WindowConstraints]
    ) -> LayoutClampRetryState? {
        guard remainingAttempts > 0 else { return nil }
        let merged = observedConstraints.merging(observations) { existing, observation in
            existing.merged(with: observation)
        }
        guard merged != observedConstraints else { return nil }
        return LayoutClampRetryState(
            remainingAttempts: remainingAttempts - 1,
            observedConstraints: merged
        )
    }
}
