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
        let planned = plan.desiredLayout.layout.tiled.mapValues(canonicalFrameWriteTarget)
        let movingWindowIDs = Set(plan.desiredLayout.delta.moves.keys)
            .subtracting(preservedFrames.keys)
        var result = LayoutApplyResult(
            applied: initiallyAcceptedFrames(
                planned: planned,
                movingWindowIDs: movingWindowIDs,
                windows: plan.windows,
                preservedFrames: preservedFrames
            ),
            clamps: [],
            failures: []
        )
        reporter.info(
            "Applying layout generation=\(plan.desiredLayout.generation.raw) "
                + "tiledCount=\(planned.count) writeCount=\(movingWindowIDs.count)"
        )

        let orderedWindowIDs = leadingFrameWriteOrder(
            planned: planned,
            candidates: movingWindowIDs,
            innerGap: plan.plannedWorld.config.gaps.inner
        )
        for windowID in orderedWindowIDs {
            guard let metadata = plan.windows[windowID],
                  let plannedFrame = planned[windowID]
            else {
                let target = planned[windowID] ?? .null
                reporter.error("No metadata for \(windowID.description); stopping frame writes")
                return recordLayoutFrameWrite(
                    windowID: windowID,
                    targetFrame: target,
                    observation: .failed(message: "missing window metadata"),
                    in: result
                ).result
            }

            let actualAndPending = planned.merging(result.applied) { _, actual in actual }
            let target: CGRect
            switch reflowSnappedFrames(
                planned: planned,
                actual: actualAndPending,
                innerGap: plan.plannedWorld.config.gaps.inner,
                anchoredWindowIDs: Set(result.applied.keys),
                tolerance: Double(configuredGapTolerance)
            ) {
            case .success(let reflowed):
                target = canonicalFrameWriteTarget(reflowed[windowID] ?? plannedFrame)
            case .failure(let conflict):
                return gapConflictFailure(
                    conflict,
                    targetFrame: plannedFrame,
                    startingWith: result
                )
            }

            echoSuppressor?.expectFrame(windowID: windowID, targetFrame: target)
            let adapter = metadata.bundleID.raw == "com.apple.Terminal" ? "Terminal bounds" : "Accessibility"
            reporter.info(
                "Writing \(windowID.description) adapter=\(adapter) target=\(target.debugDescription)"
            )
            let outcome = await frameWriter.setFrame(metadata, to: target)
            result = record(outcome, windowID: windowID, targetFrame: target, in: result)
            switch outcome {
            case .converged, .constrained:
                continue
            case .clamped, .failed:
                return result
            }
        }

        return validateAppliedLayout(plan: plan, planned: planned, result: result)
    }

    private func initiallyAcceptedFrames(
        planned: [WindowID: CGRect],
        movingWindowIDs: Set<WindowID>,
        windows: [WindowID: WindowMetadata],
        preservedFrames: [WindowID: CGRect]
    ) -> [WindowID: CGRect] {
        planned.reduce(into: preservedFrames) { accepted, entry in
            guard !movingWindowIDs.contains(entry.key),
                  accepted[entry.key] == nil,
                  let frame = windows[entry.key]?.frame
            else {
                return
            }
            accepted[entry.key] = frame
        }
    }

    private func validateAppliedLayout(
        plan: CommandPlanResult,
        planned: [WindowID: CGRect],
        result: LayoutApplyResult
    ) -> LayoutApplyResult {
        let missing = planned.keys
            .filter { result.applied[$0] == nil }
            .sorted { $0.raw < $1.raw }
        if let windowID = missing.first, let target = planned[windowID] {
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: target,
                observation: .failed(message: "missing final frame readback"),
                in: result
            ).result
        }

        let violations = innerGapViolations(
            planned: planned,
            actual: result.applied,
            innerGap: plan.plannedWorld.config.gaps.inner,
            tolerance: Double(configuredGapTolerance)
        )
        if let violation = violations.first,
           let target = planned[violation.after] {
            return recordLayoutFrameWrite(
                windowID: violation.after,
                targetFrame: target,
                observation: .failed(
                    message: "configured gap expected=\(violation.expected) actual=\(violation.actual)"
                ),
                in: result
            ).result
        }

        if let overlap = firstOverlap(in: result.applied),
           let target = planned[overlap.second] {
            return recordLayoutFrameWrite(
                windowID: overlap.second,
                targetFrame: target,
                observation: .failed(
                    message: "visible frames overlap \(overlap.first.description) and \(overlap.second.description)"
                ),
                in: result
            ).result
        }
        return result
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

    private func gapConflictFailure(
        _ conflict: SnappedFrameGapConflict,
        targetFrame: CGRect,
        startingWith result: LayoutApplyResult
    ) -> LayoutApplyResult {
        let windows = conflict.windows.map(\.description).joined(separator: ",")
        let windowID = conflict.windows.first ?? WindowID(raw: 0)
        return recordLayoutFrameWrite(
            windowID: windowID,
            targetFrame: targetFrame,
            observation: .failed(
                message: "configured \(conflict.axis.rawValue) gap is physically inconsistent for \(windows)"
            ),
            in: result
        ).result
    }

    private func record(
        _ outcome: AXFrameWriteOutcome,
        windowID: WindowID,
        targetFrame: CGRect,
        in result: LayoutApplyResult
    ) -> LayoutApplyResult {
        switch outcome {
        case .converged(let actual):
            reporter.info(
                "Applied \(windowID.description) target=\(targetFrame.debugDescription) "
                    + "AX=\(actual.debugDescription) WindowServer=\(actual.debugDescription) outcome=exact"
            )
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: targetFrame,
                observation: .converged(actual: actual),
                in: result
            ).result
        case .constrained(let actual):
            reporter.info(
                "Applied \(windowID.description) target=\(targetFrame.debugDescription) "
                    + "AX=\(actual.debugDescription) WindowServer=\(actual.debugDescription) outcome=constrained"
            )
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: targetFrame,
                observation: .converged(actual: actual),
                in: result
            ).result
        case .clamped(let actual, let observed):
            reporter.info(
                "Clamped \(windowID.description) target=\(targetFrame.debugDescription) "
                    + "actual=\(actual.debugDescription) observed=\(observed.debugDescription)"
            )
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: targetFrame,
                observation: .clamped(actual: actual, observed: observed),
                in: result
            ).result
        case .failed(let error):
            reporter.error("Failed applying \(windowID.description): \(error.description)")
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: targetFrame,
                observation: .failed(message: error.description),
                in: result
            ).result
        }
    }
}

private extension WindowConstraints {
    var debugDescription: String {
        [
            "minWidth=\(minWidth.map { String($0) } ?? "nil")",
            "minHeight=\(minHeight.map { String($0) } ?? "nil")",
            "maxWidth=\(maxWidth.map { String($0) } ?? "nil")",
            "maxHeight=\(maxHeight.map { String($0) } ?? "nil")",
            "widthAnchor=\(widthAnchor?.rawValue ?? "nil")",
            "heightAnchor=\(heightAnchor?.rawValue ?? "nil")"
        ].joined(separator: " ")
    }
}
