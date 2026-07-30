import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

enum LayoutFrameWriteStrategy {
    case sequential
    case coordinated
}

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
        _ result: CommandPlanResult,
        preserving preservedFrames: [WindowID: CGRect] = [:],
        strategy: LayoutFrameWriteStrategy = .sequential
    ) async -> LayoutApplyResult {
        let applyResult = LayoutApplyResult(applied: preservedFrames, clamps: [], failures: [])
        reporter.info("Applying layout generation=\(result.desiredLayout.generation.raw) tiledCount=\(result.desiredLayout.layout.tiled.count)")

        let intents = layoutFrameWriteIntents(for: result, excluding: Set(preservedFrames.keys))
        let initial: LayoutApplyResult
        switch strategy {
        case .sequential:
            initial = await applySequentially(intents, startingWith: applyResult)
        case .coordinated:
            initial = await applyCoordinated(intents, startingWith: applyResult)
        }
        guard initial.succeeded else { return initial }
        return await reconcileConfiguredGaps(
            for: result,
            after: initial,
            preserving: Set(preservedFrames.keys),
            strategy: strategy
        )
    }

    private func reconcileConfiguredGaps(
        for plan: CommandPlanResult,
        after initial: LayoutApplyResult,
        preserving preservedWindowIDs: Set<WindowID>,
        strategy: LayoutFrameWriteStrategy
    ) async -> LayoutApplyResult {
        let plannedFrames = plan.desiredLayout.layout.tiled
        let observedFrames = plannedFrames.reduce(into: [WindowID: CGRect]()) { frames, entry in
            if let frame = initial.applied[entry.key] ?? plan.windows[entry.key]?.frame {
                frames[entry.key] = frame
            }
        }
        guard observedFrames.count == plannedFrames.count else {
            let missing = plannedFrames.keys
                .filter { observedFrames[$0] == nil }
                .sorted { $0.raw < $1.raw }
            guard let windowID = missing.first, let target = plannedFrames[windowID] else { return initial }
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: target,
                observation: .failed(message: "missing actual frame for configured-gap reconciliation"),
                in: initial
            ).result
        }

        var reflowed = observedFrames
        var idsByDisplay: [DisplayID: [WindowID]] = [:]
        for windowID in plannedFrames.keys {
            guard let displayID = plan.plannedWorld.windowDisplay[windowID] else { continue }
            idsByDisplay[displayID, default: []].append(windowID)
        }
        guard idsByDisplay.values.reduce(0, { $0 + $1.count }) == plannedFrames.count else {
            let missing = plannedFrames.keys
                .filter { plan.plannedWorld.windowDisplay[$0] == nil }
                .sorted { $0.raw < $1.raw }
            guard let windowID = missing.first, let target = plannedFrames[windowID] else { return initial }
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: target,
                observation: .failed(message: "missing display ownership for configured-gap reconciliation"),
                in: initial
            ).result
        }
        var bestEffortDisplays = Set<DisplayID>()
        var stableBestEffortDisplays = Set<DisplayID>()
        for (displayID, windowIDs) in idsByDisplay {
            let ids = Set(windowIDs)
            let displayPlanned = plannedFrames.filter { ids.contains($0.key) }
            let displayActual = observedFrames.filter { ids.contains($0.key) }
            switch reflowSnappedFrames(
                planned: displayPlanned,
                actual: displayActual,
                innerGap: plan.plannedWorld.config.gaps.inner,
                anchoredWindowIDs: preservedWindowIDs.intersection(ids),
                tolerance: Double(configuredGapTolerance)
            ) {
            case .success(let frames):
                reflowed.merge(frames) { _, replacement in replacement }
            case .failure(let conflict):
                switch reflowSnappedFramesBestEffort(
                    planned: displayPlanned,
                    actual: displayActual,
                    innerGap: plan.plannedWorld.config.gaps.inner,
                    anchoredWindowIDs: preservedWindowIDs.intersection(ids),
                    tolerance: Double(configuredGapTolerance),
                    maximumOuterDrift: Double(appGridOuterDriftTolerance)
                ) {
                case .success(let frames):
                    let stableFrames = frames.reduce(into: [WindowID: CGRect]()) { result, entry in
                        guard let observed = displayActual[entry.key] else {
                            result[entry.key] = entry.value
                            return
                        }
                        var origin = entry.value.origin
                        if abs(origin.x - observed.minX) <= appGridGapFallbackTolerance {
                            origin.x = observed.minX
                        }
                        if abs(origin.y - observed.minY) <= appGridGapFallbackTolerance {
                            origin.y = observed.minY
                        }
                        result[entry.key] = CGRect(origin: origin, size: entry.value.size)
                    }
                    let stableResiduals = innerGapViolations(
                        planned: displayPlanned,
                        actual: stableFrames,
                        innerGap: plan.plannedWorld.config.gaps.inner,
                        tolerance: Double(configuredGapTolerance)
                    )
                    let stableFramesAreBounded = stableResiduals.allSatisfy {
                        $0.actual >= -Double(configuredGapTolerance)
                            && abs($0.actual - $0.expected) <= Double(appGridGapFallbackTolerance)
                    }
                    let candidateFrames = stableFramesAreBounded ? stableFrames : frames
                    let residuals = stableFramesAreBounded
                        ? stableResiduals
                        : innerGapViolations(
                            planned: displayPlanned,
                            actual: frames,
                            innerGap: plan.plannedWorld.config.gaps.inner,
                            tolerance: Double(configuredGapTolerance)
                        )
                    guard residuals.allSatisfy({
                        $0.actual >= -Double(configuredGapTolerance)
                            && abs($0.actual - $0.expected) <= Double(appGridGapFallbackTolerance)
                    }) else {
                        return gapConflictFailure(
                            conflict,
                            plannedFrames: plannedFrames,
                            startingWith: initial
                        )
                    }
                    bestEffortDisplays.insert(displayID)
                    if stableFramesAreBounded {
                        stableBestEffortDisplays.insert(displayID)
                    }
                    reflowed.merge(candidateFrames) { _, replacement in replacement }
                    reporter.info(
                        "Using bounded gap reconciliation display=\(displayID.raw) "
                            + "maximumDeviation=\(residuals.map { abs($0.actual - $0.expected) }.max() ?? 0)"
                    )
                case .failure:
                    return gapConflictFailure(
                        conflict,
                        plannedFrames: plannedFrames,
                        startingWith: initial
                    )
                }
            }
        }

        let correctionFrames = reflowed.mapValues { frame in
            CGRect(
                x: frame.minX.rounded(),
                y: frame.minY.rounded(),
                width: frame.width,
                height: frame.height
            )
        }
        let corrections = correctionFrames.keys
            .filter { windowID in
                guard !preservedWindowIDs.contains(windowID),
                      let before = observedFrames[windowID],
                      let after = correctionFrames[windowID]
                else {
                    return false
                }
                let tolerance = plan.plannedWorld.windowDisplay[windowID].map {
                    stableBestEffortDisplays.contains($0)
                        ? appGridGapFallbackTolerance
                        : configuredGapTolerance
                } ?? configuredGapTolerance
                return !before.origin.narwhalApproximatelyEquals(
                    after.origin,
                    tolerance: tolerance
                )
            }
            .sorted { $0.raw < $1.raw }
            .map { windowID -> LayoutFrameWriteIntent in
                guard let metadata = plan.windows[windowID], let frame = correctionFrames[windowID] else {
                    return .missingMetadata(windowID: windowID, targetFrame: plannedFrames[windowID] ?? .null)
                }
                return .write(windowID: windowID, metadata: metadata, targetFrame: frame)
            }

        var reconciled = LayoutApplyResult(
            applied: observedFrames,
            clamps: initial.clamps,
            failures: initial.failures
        )
        if !corrections.isEmpty {
            reporter.info("Reconciling configured gaps correctionCount=\(corrections.count)")
            switch strategy {
            case .sequential:
                reconciled = await applySequentially(corrections, startingWith: reconciled)
            case .coordinated:
                reconciled = await applyCoordinated(corrections, startingWith: reconciled)
            }
        }
        guard reconciled.succeeded else { return reconciled }

        for (displayID, windowIDs) in idsByDisplay {
            let ids = Set(windowIDs)
            let violations = innerGapViolations(
                planned: plannedFrames.filter { ids.contains($0.key) },
                actual: reconciled.applied.filter { ids.contains($0.key) },
                innerGap: plan.plannedWorld.config.gaps.inner,
                tolerance: Double(configuredGapTolerance)
            )
            let violation = bestEffortDisplays.contains(displayID)
                ? violations.first {
                    $0.actual < -Double(configuredGapTolerance)
                        || abs($0.actual - $0.expected) > Double(appGridGapFallbackTolerance)
                }
                : violations.first
            guard let violation,
                  let target = plannedFrames[violation.after]
            else {
                continue
            }
            return recordLayoutFrameWrite(
                windowID: violation.after,
                targetFrame: target,
                observation: .failed(
                    message: "configured gap expected=\(violation.expected) actual=\(violation.actual)"
                ),
                in: reconciled
            ).result
        }
        return reconciled
    }

    private func gapConflictFailure(
        _ conflict: SnappedFrameGapConflict,
        plannedFrames: [WindowID: CGRect],
        startingWith result: LayoutApplyResult
    ) -> LayoutApplyResult {
        guard let windowID = conflict.windows.first,
              let target = plannedFrames[windowID]
        else {
            return result
        }
        let windows = conflict.windows.map(\.description).joined(separator: ",")
        return recordLayoutFrameWrite(
            windowID: windowID,
            targetFrame: target,
            observation: .failed(
                message: "configured \(conflict.axis.rawValue) gap is physically inconsistent for \(windows)"
            ),
            in: result
        ).result
    }

    private func applySequentially(
        _ intents: [LayoutFrameWriteIntent],
        startingWith initial: LayoutApplyResult
    ) async -> LayoutApplyResult {
        var applyResult = initial
        applyLoop: for intent in intents {
            switch intent {
            case .missingMetadata(let windowID, let frame):
                reporter.error("No metadata for \(windowID.description); skipping frame write")
                applyResult = recordLayoutFrameWrite(
                    windowID: windowID,
                    targetFrame: frame,
                    observation: .failed(message: "missing window metadata"),
                    in: applyResult
                ).result
                break applyLoop

            case .write(let windowID, let metadata, let frame):
                let target = canonicalFrameWriteTarget(frame)
                echoSuppressor?.expectFrame(windowID: windowID, targetFrame: target)
                let outcome = await frameWriter.setFrame(metadata, to: target)
                applyResult = record(outcome, windowID: windowID, targetFrame: target, in: applyResult)
                guard case .converged = outcome else {
                    if case .constrained = outcome {
                        continue
                    }
                    break applyLoop
                }
            }
        }

        return applyResult
    }

    private func applyCoordinated(
        _ intents: [LayoutFrameWriteIntent],
        startingWith initial: LayoutApplyResult
    ) async -> LayoutApplyResult {
        var applyResult = initial
        let missing = intents.compactMap { intent -> (WindowID, CGRect)? in
            guard case .missingMetadata(let windowID, let frame) = intent else { return nil }
            return (windowID, frame)
        }
        guard missing.isEmpty else {
            for (windowID, frame) in missing {
                reporter.error("No metadata for \(windowID.description); skipping coordinated frame writes")
                applyResult = recordLayoutFrameWrite(
                    windowID: windowID,
                    targetFrame: frame,
                    observation: .failed(message: "missing window metadata"),
                    in: applyResult
                ).result
            }
            return applyResult
        }

        let writes = intents.compactMap { intent -> (windowID: WindowID, metadata: WindowMetadata, frame: CGRect)? in
            guard case .write(let windowID, let metadata, let frame) = intent else { return nil }
            return (windowID, metadata, frame)
        }
        for write in writes {
            let target = canonicalFrameWriteTarget(write.frame)
            echoSuppressor?.expectFrame(windowID: write.windowID, targetFrame: target)
            let outcome = await frameWriter.setFrame(write.metadata, to: target)
            applyResult = record(
                outcome,
                windowID: write.windowID,
                targetFrame: target,
                in: applyResult
            )
        }
        return applyResult
    }

    private func record(
        _ outcome: AXFrameWriteOutcome,
        windowID: WindowID,
        targetFrame: CGRect,
        in result: LayoutApplyResult
    ) -> LayoutApplyResult {
        switch outcome {
        case .converged(let actual):
            reporter.info("Applied \(windowID.description) target=\(targetFrame.debugDescription) actual=\(actual.debugDescription)")
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: targetFrame,
                observation: .converged(actual: actual),
                in: result
            ).result
        case .constrained(let actual):
            reporter.info(
                "Constrained \(windowID.description) target=\(targetFrame.debugDescription) actual=\(actual.debugDescription)"
            )
            return recordLayoutFrameWrite(
                windowID: windowID,
                targetFrame: targetFrame,
                observation: .converged(actual: actual),
                in: result
            ).result
        case .clamped(let actual, let observed):
            reporter.info(
                "Clamped \(windowID.description) target=\(targetFrame.debugDescription) actual=\(actual.debugDescription) observed=\(observed.debugDescription)"
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
