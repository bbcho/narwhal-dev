import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

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
        preserving preservedFrames: [WindowID: CGRect] = [:]
    ) async -> LayoutApplyResult {
        var applyResult = LayoutApplyResult(applied: preservedFrames, clamps: [], failures: [])
        reporter.info("Applying layout generation=\(result.desiredLayout.generation.raw) tiledCount=\(result.desiredLayout.layout.tiled.count)")

        applyLoop: for intent in layoutFrameWriteIntents(for: result, excluding: Set(preservedFrames.keys)) {
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
                let writeResult: AXFrameWriteOutcome
                echoSuppressor?.expectFrame(windowID: windowID, targetFrame: frame)
                writeResult = await axClient.setFrame(metadata, to: frame)

                switch writeResult {
                case .converged(let actual):
                    reporter.info("Applied \(windowID.description) target=\(frame.debugDescription) actual=\(actual.debugDescription)")
                    applyResult = recordLayoutFrameWrite(
                        windowID: windowID,
                        targetFrame: frame,
                        observation: .converged(actual: actual),
                        in: applyResult
                    ).result
                case .clamped(let actual, let observed):
                    reporter.info(
                        "Clamped \(windowID.description) target=\(frame.debugDescription) actual=\(actual.debugDescription) observed=\(observed.debugDescription)"
                    )
                    applyResult = recordLayoutFrameWrite(
                        windowID: windowID,
                        targetFrame: frame,
                        observation: .clamped(actual: actual, observed: observed),
                        in: applyResult
                    ).result
                    break applyLoop
                case .failed(let error):
                    reporter.error("Failed applying \(windowID.description): \(error.description)")
                    applyResult = recordLayoutFrameWrite(
                        windowID: windowID,
                        targetFrame: frame,
                        observation: .failed(message: error.description),
                        in: applyResult
                    ).result
                    break applyLoop
                }
            }
        }

        return applyResult
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
