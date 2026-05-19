import CoreGraphics
import NarwhalCore

struct LayoutApplyFailure: Sendable {
    let windowID: WindowID
    let targetFrame: CGRect
    let message: String
}

struct LayoutApplyClamp: Sendable {
    let windowID: WindowID
    let targetFrame: CGRect
    let actualFrame: CGRect
    let observed: WindowConstraints
}

struct LayoutApplyResult: Sendable {
    let applied: [WindowID: CGRect]
    let clamps: [LayoutApplyClamp]
    let failures: [LayoutApplyFailure]

    var succeeded: Bool {
        clamps.isEmpty && failures.isEmpty
    }

    var observedConstraints: [WindowID: WindowConstraints] {
        clamps.reduce(into: [:]) { result, clamp in
            result[clamp.windowID] = (result[clamp.windowID] ?? WindowConstraints()).merged(with: clamp.observed)
        }
    }
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

    func apply(_ result: CommandPlanResult) -> LayoutApplyResult {
        var applied: [WindowID: CGRect] = [:]
        var clamps: [LayoutApplyClamp] = []
        var failures: [LayoutApplyFailure] = []
        reporter.info("Applying layout generation=\(result.desiredLayout.generation.raw) tiledCount=\(result.desiredLayout.layout.tiled.count)")

        applyLoop: for windowID in frameWriteOrder(for: result.desiredLayout.layout, focused: result.focusedWindowID) {
            guard let frame = result.desiredLayout.layout.tiled[windowID] else { continue }
            guard let metadata = result.windows[windowID] else {
                reporter.error("No metadata for \(windowID.description); skipping frame write")
                failures.append(LayoutApplyFailure(
                    windowID: windowID,
                    targetFrame: frame,
                    message: "missing window metadata"
                ))
                break applyLoop
            }

            let writeResult: AXFrameWriteOutcome
            echoSuppressor?.expectFrame(windowID: windowID, targetFrame: frame)
            if let focusedWindowID = result.focusedWindowID, windowID == focusedWindowID {
                writeResult = axClient.setFocusedWindowFrame(frame)
            } else {
                writeResult = axClient.setFrame(metadata, to: frame)
            }

            switch writeResult {
            case .converged(let actual):
                reporter.info("Applied \(windowID.description) target=\(frame.debugDescription) actual=\(actual.debugDescription)")
                applied[windowID] = actual
            case .clamped(let actual, let observed):
                reporter.info(
                    "Clamped \(windowID.description) target=\(frame.debugDescription) actual=\(actual.debugDescription) observed=\(observed.debugDescription)"
                )
                clamps.append(LayoutApplyClamp(
                    windowID: windowID,
                    targetFrame: frame,
                    actualFrame: actual,
                    observed: observed
                ))
                break applyLoop
            case .failed(let error):
                reporter.error("Failed applying \(windowID.description): \(error.description)")
                failures.append(LayoutApplyFailure(
                    windowID: windowID,
                    targetFrame: frame,
                    message: error.description
                ))
                break applyLoop
            }
        }

        return LayoutApplyResult(applied: applied, clamps: clamps, failures: failures)
    }
}

private extension WindowConstraints {
    var debugDescription: String {
        "minWidth=\(minWidth.map { String($0) } ?? "nil") minHeight=\(minHeight.map { String($0) } ?? "nil")"
    }
}
