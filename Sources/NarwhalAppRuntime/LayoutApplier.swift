import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

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

    init(
        frameWriter: WindowFrameWriter,
        reporter: StartupReporter,
        echoSuppressor: AXEchoSuppressor? = nil
    ) {
        self.frameWriter = frameWriter
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

    func plannedFrames(for plan: CommandPlanResult) -> [WindowID: CGRect] {
        plan.desiredLayout.layout.tiled.mapValues(canonicalFrameWriteTarget)
    }

    func movingWindowIDs(
        for plan: CommandPlanResult,
        preserving preservedFrames: [WindowID: CGRect]
    ) -> Set<WindowID> {
        Set(plan.desiredLayout.delta.moves.keys).subtracting(preservedFrames.keys)
    }

    func orderedWindowIDs(
        planned: [WindowID: CGRect],
        movingWindowIDs: Set<WindowID>,
        innerGap: Double
    ) -> [WindowID] {
        leadingFrameWriteOrder(
            planned: planned,
            candidates: movingWindowIDs,
            innerGap: innerGap
        )
    }

    func resolvedTargetFrame(
        for windowID: WindowID,
        planned: [WindowID: CGRect],
        applied: [WindowID: CGRect],
        innerGap: Double
    ) -> Result<CGRect, LayoutApplyFailure> {
        guard let plannedFrame = planned[windowID] else {
            return .failure(LayoutApplyFailure(
                windowID: windowID,
                targetFrame: .null,
                message: "missing planned frame"
            ))
        }
        let actualAndPending = planned.merging(applied) { _, actual in actual }
        switch reflowSnappedFrames(
            planned: planned,
            actual: actualAndPending,
            innerGap: innerGap,
            anchoredWindowIDs: Set(applied.keys),
            tolerance: Double(configuredGapTolerance)
        ) {
        case .success(let reflowed):
            return .success(canonicalFrameWriteTarget(reflowed[windowID] ?? plannedFrame))
        case .failure(let conflict):
            let windows = conflict.windows.map(\.description).joined(separator: ",")
            let failedWindowID = conflict.windows.first ?? windowID
            return .failure(LayoutApplyFailure(
                windowID: failedWindowID,
                targetFrame: planned[failedWindowID] ?? plannedFrame,
                message: "configured \(conflict.axis.rawValue) gap is physically inconsistent for \(windows)"
            ))
        }
    }

    func initiallyAcceptedFrames(
        planned: [WindowID: CGRect],
        movingWindowIDs: Set<WindowID>,
        windows: [WindowID: WindowMetadata],
        preservedFrames: [WindowID: CGRect]
    ) -> [WindowID: CGRect] {
        let preserved = preservedFrames.filter { planned[$0.key] != nil }
        return planned.reduce(into: preserved) { accepted, entry in
            guard !movingWindowIDs.contains(entry.key),
                  accepted[entry.key] == nil,
                  let frame = windows[entry.key]?.frame
            else {
                return
            }
            accepted[entry.key] = frame
        }
    }

    func validationFailure(
        plan: CommandPlanResult,
        planned: [WindowID: CGRect],
        applied: [WindowID: CGRect]
    ) -> LayoutApplyFailure? {
        let missing = planned.keys
            .filter { applied[$0] == nil }
            .sorted { $0.raw < $1.raw }
        if let windowID = missing.first, let target = planned[windowID] {
            return LayoutApplyFailure(
                windowID: windowID,
                targetFrame: target,
                message: "missing final frame readback"
            )
        }

        let violations = innerGapViolations(
            planned: planned,
            actual: applied,
            innerGap: plan.plannedWorld.config.gaps.inner,
            tolerance: Double(configuredGapTolerance)
        )
        if let violation = violations.first,
           let target = planned[violation.after] {
            return LayoutApplyFailure(
                windowID: violation.after,
                targetFrame: target,
                message: "configured gap expected=\(violation.expected) actual=\(violation.actual)"
            )
        }

        if let overlap = firstOverlap(in: applied),
           let target = planned[overlap.second] {
            return LayoutApplyFailure(
                windowID: overlap.second,
                targetFrame: target,
                message: "visible frames overlap \(overlap.first.description) and \(overlap.second.description)"
            )
        }
        return nil
    }

    private func firstOverlap(
        in frames: [WindowID: CGRect]
    ) -> (first: WindowID, second: WindowID)? {
        let ids = frames.keys.sorted { $0.raw < $1.raw }
        for firstIndex in ids.indices {
            for secondIndex in ids.indices.dropFirst(firstIndex + 1) {
                let firstID = ids[firstIndex]
                let secondID = ids[secondIndex]
                guard let first = frames[firstID],
                      let second = frames[secondID],
                      first.intersection(second).narwhalArea > configuredGapTolerance
                else {
                    continue
                }
                return (firstID, secondID)
            }
        }
        return nil
    }

}
