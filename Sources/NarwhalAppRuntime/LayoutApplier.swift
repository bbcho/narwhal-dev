import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

enum LayoutFrameWriteStrategy {
    case sequential
    case coordinated
}

@MainActor
struct LayoutApplier {
    let axClient: AXClient
    let reporter: StartupReporter
    let echoSuppressor: AXEchoSuppressor?

    init(axClient: AXClient, reporter: StartupReporter, echoSuppressor: AXEchoSuppressor? = nil) {
        self.axClient = axClient
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
        switch strategy {
        case .sequential:
            return await applySequentially(intents, startingWith: applyResult)
        case .coordinated:
            return await applyCoordinated(intents, startingWith: applyResult)
        }
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
                echoSuppressor?.expectFrame(windowID: windowID, targetFrame: frame)
                let outcome = await axClient.setFrame(metadata, to: frame)
                applyResult = record(outcome, windowID: windowID, targetFrame: frame, in: applyResult)
                guard case .converged = outcome else {
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
            echoSuppressor?.expectFrame(windowID: windowID, targetFrame: frame)
            return (windowID, metadata, frame)
        }
        let outcomes = await axClient.setFramesCoordinated(writes.map { ($0.metadata, $0.frame) })

        for write in writes {
            let outcome = outcomes[write.windowID]
                ?? .failed(.frameDidNotConverge(target: write.frame, actual: .null, attempts: 0))
            applyResult = record(
                outcome,
                windowID: write.windowID,
                targetFrame: write.frame,
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
