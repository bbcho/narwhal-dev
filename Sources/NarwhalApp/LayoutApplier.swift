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

    func apply(_ result: CommandPlanResult) -> LayoutApplyResult {
        var applyResult = LayoutApplyResult.empty
        reporter.info("Applying layout generation=\(result.desiredLayout.generation.raw) tiledCount=\(result.desiredLayout.layout.tiled.count)")

        applyLoop: for windowID in frameWriteOrder(for: result.desiredLayout.layout, focused: result.focusedWindowID) {
            guard let frame = result.desiredLayout.layout.tiled[windowID] else { continue }
            guard let metadata = result.windows[windowID] else {
                reporter.error("No metadata for \(windowID.description); skipping frame write")
                applyResult = recordLayoutFrameWrite(
                    windowID: windowID,
                    targetFrame: frame,
                    observation: .failed(message: "missing window metadata"),
                    in: applyResult
                ).result
                break applyLoop
            }

            let writeResult: AXFrameWriteOutcome
            echoSuppressor?.expectFrame(windowID: windowID, targetFrame: frame)
            writeResult = axClient.setFrame(metadata, to: frame)

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

        return applyResult
    }
}

private extension WindowConstraints {
    var debugDescription: String {
        "minWidth=\(minWidth.map { String($0) } ?? "nil") minHeight=\(minHeight.map { String($0) } ?? "nil")"
    }
}
