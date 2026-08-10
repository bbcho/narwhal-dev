import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

struct LayoutFrameTransactionFailure: Error, Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case preflight
        case apply
        case validate
        case currency
        case rollback
    }

    let windowID: WindowID?
    let stage: Stage
    let message: String
}

enum LayoutFrameTransactionOutcome: Equatable, Sendable {
    case applied(
        originalFrames: [WindowID: CGRect],
        appliedFrames: [WindowID: CGRect]
    )
    case constraintObserved(
        originalFrames: [WindowID: CGRect],
        observations: [WindowID: WindowConstraints],
        failure: LayoutFrameTransactionFailure
    )
    case rolledBack(
        originalFrames: [WindowID: CGRect],
        failure: LayoutFrameTransactionFailure
    )
    case reconciliationRequired(
        originalFrames: [WindowID: CGRect],
        liveFrames: [WindowID: CGRect],
        failure: LayoutFrameTransactionFailure,
        rollbackFailures: [LayoutFrameTransactionFailure]
    )
}

@MainActor
struct LayoutFrameTransaction {
    let frameWriter: WindowFrameWriter
    let reporter: StartupReporter
    let echoSuppressor: AXEchoSuppressor?

    init(
        frameWriter: WindowFrameWriter,
        reporter: StartupReporter,
        echoSuppressor: AXEchoSuppressor? = nil
    ) {
        self.frameWriter = frameWriter
        self.reporter = reporter
        self.echoSuppressor = echoSuppressor
    }

    init(
        axClient: AXClient,
        reporter: StartupReporter,
        echoSuppressor: AXEchoSuppressor? = nil
    ) {
        self.init(
            frameWriter: WindowFrameWriter(axClient: axClient),
            reporter: reporter,
            echoSuppressor: echoSuppressor
        )
    }

    func execute(
        _ plan: CommandPlanResult,
        preserving preservedFrames: [WindowID: CGRect] = [:],
        isCurrent: @MainActor () async -> Bool
    ) async -> LayoutFrameTransactionOutcome {
        let applier = LayoutApplier(
            frameWriter: frameWriter,
            reporter: reporter,
            echoSuppressor: echoSuppressor
        )
        let planned = applier.plannedFrames(for: plan)
        let moving = applier.movingWindowIDs(for: plan, preserving: preservedFrames)
        let ordered = applier.orderedWindowIDs(
            planned: planned,
            movingWindowIDs: moving,
            innerGap: plan.plannedWorld.config.gaps.inner
        )
        var originals = preservedFrames.filter { planned[$0.key] != nil }
        var originalReadbacks: [WindowID: WindowFrameReadback] = [:]

        for windowID in ordered {
            guard let metadata = plan.windows[windowID] else {
                return .rolledBack(
                    originalFrames: originals,
                    failure: failure(
                        windowID,
                        stage: .preflight,
                        message: "missing window metadata"
                    )
                )
            }
            switch await frameWriter.readFrame(metadata) {
            case .success(let readback):
                guard readback.accessibility.narwhalIsFinitePositive,
                      readback.windowServer.narwhalIsFinitePositive,
                      framesMatch(readback.accessibility, readback.windowServer)
                else {
                    return .rolledBack(
                        originalFrames: originals,
                        failure: failure(
                            windowID,
                            stage: .preflight,
                            message: readbackMismatchMessage(readback)
                        )
                    )
                }
                originalReadbacks[windowID] = readback
                originals[windowID] = readback.accessibility
            case .failure(let error):
                return .rolledBack(
                    originalFrames: originals,
                    failure: failure(windowID, stage: .preflight, message: error.description)
                )
            }
        }

        guard await isCurrent() else {
            return .rolledBack(
                originalFrames: originals,
                failure: failure(nil, stage: .currency, message: "layout plan became stale before frame writes")
            )
        }

        var applied = applier.initiallyAcceptedFrames(
            planned: planned,
            movingWindowIDs: moving,
            windows: plan.windows,
            preservedFrames: preservedFrames
        )
        var attempted: [WindowID] = []

        for windowID in ordered {
            guard let metadata = plan.windows[windowID] else {
                let cause = failure(windowID, stage: .apply, message: "missing window metadata")
                return await restore(
                    plan: plan,
                    originals: originals,
                    attempted: attempted,
                    cause: cause
                )
            }

            let target: CGRect
            switch applier.resolvedTargetFrame(
                for: windowID,
                planned: planned,
                applied: applied,
                innerGap: plan.plannedWorld.config.gaps.inner
            ) {
            case .success(let frame):
                target = frame
            case .failure(let resolutionFailure):
                let cause = failure(
                    resolutionFailure.windowID,
                    stage: .apply,
                    message: resolutionFailure.message
                )
                return await restore(
                    plan: plan,
                    originals: originals,
                    attempted: attempted,
                    cause: cause
                )
            }

            if let original = originalReadbacks[windowID],
               framesMatch(original.accessibility, target),
               framesMatch(original.windowServer, target) {
                applied[windowID] = original.accessibility
                continue
            }

            attempted.append(windowID)
            echoSuppressor?.expectFrame(windowID: windowID, targetFrame: target)
            reporter.info(
                "Transaction writing \(windowID.description) target=\(target.debugDescription)"
            )
            switch await frameWriter.setFrame(metadata, to: target) {
            case .converged(let actual), .constrained(let actual):
                applied[windowID] = actual
            case .clamped(_, let observed):
                let cause = failure(
                    windowID,
                    stage: .apply,
                    message: "window frame was constrained while applying the layout"
                )
                return await restore(
                    plan: plan,
                    originals: originals,
                    attempted: attempted,
                    cause: cause,
                    observations: [windowID: observed]
                )
            case .failed(let error):
                let cause = failure(windowID, stage: .apply, message: error.description)
                return await restore(
                    plan: plan,
                    originals: originals,
                    attempted: attempted,
                    cause: cause
                )
            }
        }

        switch await readCompleteLayout(plan: plan, planned: planned) {
        case .success(let liveFrames):
            applied = liveFrames
        case .failure(let cause):
            return await restore(
                plan: plan,
                originals: originals,
                attempted: attempted,
                cause: cause
            )
        }

        if let validationFailure = applier.validationFailure(
            plan: plan,
            planned: planned,
            applied: applied
        ) {
            return await restore(
                plan: plan,
                originals: originals,
                attempted: attempted,
                cause: failure(
                    validationFailure.windowID,
                    stage: .validate,
                    message: validationFailure.message
                )
            )
        }

        guard await isCurrent() else {
            return await restore(
                plan: plan,
                originals: originals,
                attempted: attempted,
                cause: failure(
                    nil,
                    stage: .currency,
                    message: "layout plan became stale after frame writes"
                )
            )
        }

        return .applied(originalFrames: originals, appliedFrames: applied)
    }

    func rollback(
        _ plan: CommandPlanResult,
        originalFrames: [WindowID: CGRect],
        preserving preservedFrames: [WindowID: CGRect] = [:],
        failure: LayoutFrameTransactionFailure
    ) async -> LayoutFrameTransactionOutcome {
        let applier = LayoutApplier(
            frameWriter: frameWriter,
            reporter: reporter,
            echoSuppressor: echoSuppressor
        )
        let planned = applier.plannedFrames(for: plan)
        let moving = applier.movingWindowIDs(for: plan, preserving: preservedFrames)
        let ordered = applier.orderedWindowIDs(
            planned: planned,
            movingWindowIDs: moving,
            innerGap: plan.plannedWorld.config.gaps.inner
        )
        return await restore(
            plan: plan,
            originals: originalFrames,
            attempted: ordered,
            cause: failure
        )
    }

    private func readCompleteLayout(
        plan: CommandPlanResult,
        planned: [WindowID: CGRect]
    ) async -> Result<[WindowID: CGRect], LayoutFrameTransactionFailure> {
        var frames: [WindowID: CGRect] = [:]
        for windowID in planned.keys.sorted(by: { $0.raw < $1.raw }) {
            guard let metadata = plan.windows[windowID] else {
                return .failure(failure(
                    windowID,
                    stage: .validate,
                    message: "missing window metadata during final validation"
                ))
            }
            switch await frameWriter.readFrame(metadata) {
            case .success(let readback):
                guard readback.accessibility.narwhalIsFinitePositive,
                      readback.windowServer.narwhalIsFinitePositive,
                      framesMatch(readback.accessibility, readback.windowServer)
                else {
                    return .failure(failure(
                        windowID,
                        stage: .validate,
                        message: readbackMismatchMessage(readback)
                    ))
                }
                frames[windowID] = readback.accessibility
            case .failure(let error):
                return .failure(failure(windowID, stage: .validate, message: error.description))
            }
        }
        return .success(frames)
    }

    private func restore(
        plan: CommandPlanResult,
        originals: [WindowID: CGRect],
        attempted: [WindowID],
        cause: LayoutFrameTransactionFailure,
        observations: [WindowID: WindowConstraints] = [:]
    ) async -> LayoutFrameTransactionOutcome {
        var rollbackFailures: [LayoutFrameTransactionFailure] = []
        for windowID in attempted.reversed() {
            guard let metadata = plan.windows[windowID],
                  let original = originals[windowID]
            else {
                rollbackFailures.append(failure(
                    windowID,
                    stage: .rollback,
                    message: "missing metadata or original frame"
                ))
                continue
            }

            let current = await frameWriter.readFrame(metadata)
            if case .success(let readback) = current,
               framesMatch(readback.accessibility, original),
               framesMatch(readback.windowServer, original) {
                continue
            }

            reporter.info(
                "Transaction restoring \(windowID.description) target=\(original.debugDescription)"
            )
            echoSuppressor?.expectFrame(windowID: windowID, targetFrame: original)
            let writeOutcome = await frameWriter.setFrame(metadata, to: original)
            let verification = await frameWriter.readFrame(metadata)
            let restored: Bool
            if case .success(let readback) = verification {
                restored = framesMatch(readback.accessibility, original)
                    && framesMatch(readback.windowServer, original)
            } else {
                restored = false
            }
            guard !restored else { continue }

            let message: String
            switch writeOutcome {
            case .failed(let error):
                message = error.description
            case .converged, .constrained, .clamped:
                switch verification {
                case .success(let readback):
                    message = "rollback readback did not match original: \(readbackMismatchMessage(readback))"
                case .failure(let error):
                    message = error.description
                }
            }
            rollbackFailures.append(failure(windowID, stage: .rollback, message: message))
        }

        guard rollbackFailures.isEmpty else {
            return .reconciliationRequired(
                originalFrames: originals,
                liveFrames: await readableFrames(
                    plan: plan,
                    windowIDs: Set(plan.desiredLayout.layout.tiled.keys)
                ),
                failure: cause,
                rollbackFailures: rollbackFailures
            )
        }
        if !observations.isEmpty {
            return .constraintObserved(
                originalFrames: originals,
                observations: observations,
                failure: cause
            )
        }
        return .rolledBack(originalFrames: originals, failure: cause)
    }

    private func readableFrames(
        plan: CommandPlanResult,
        windowIDs: Set<WindowID>
    ) async -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        for windowID in windowIDs.sorted(by: { $0.raw < $1.raw }) {
            guard let metadata = plan.windows[windowID],
                  case .success(let readback) = await frameWriter.readFrame(metadata)
            else {
                continue
            }
            frames[windowID] = readback.accessibility
        }
        return frames
    }

    private func failure(
        _ windowID: WindowID?,
        stage: LayoutFrameTransactionFailure.Stage,
        message: String
    ) -> LayoutFrameTransactionFailure {
        LayoutFrameTransactionFailure(windowID: windowID, stage: stage, message: message)
    }

    private func framesMatch(_ first: CGRect, _ second: CGRect) -> Bool {
        first.narwhalApproximatelyEquals(second, tolerance: configuredGapTolerance)
    }

    private func readbackMismatchMessage(_ readback: WindowFrameReadback) -> String {
        "AX and WindowServer frames disagree AX=\(readback.accessibility.debugDescription) "
            + "WindowServer=\(readback.windowServer.debugDescription)"
    }
}
