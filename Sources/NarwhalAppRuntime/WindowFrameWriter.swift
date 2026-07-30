import AppKit
import CoreGraphics
import NarwhalCore

struct WindowFrameReadback: Equatable, Sendable {
    let accessibility: CGRect
    let windowServer: CGRect
}

func canonicalFrameWriteTarget(_ frame: CGRect) -> CGRect {
    let minX = frame.minX.rounded()
    let minY = frame.minY.rounded()
    let maxX = frame.maxX.rounded()
    let maxY = frame.maxY.rounded()
    return CGRect(
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY
    )
}

func terminalBoundsAppleScript(windowID: WindowID, frame: CGRect) -> String? {
    let frame = canonicalFrameWriteTarget(frame)
    guard frame.narwhalIsFinitePositive else { return nil }
    return """
    tell application id "com.apple.Terminal"
        set targetWindow to first window whose id is \(windowID.raw)
        set bounds of targetWindow to {\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.maxX)), \(Int(frame.maxY))}
    end tell
    """
}

@MainActor
struct WindowFrameWriter {
    typealias AccessibilityWrite = @MainActor (WindowMetadata, CGRect) async -> AXFrameWriteOutcome
    typealias TerminalWrite = @MainActor (WindowMetadata, CGRect) -> Result<Void, AXClientError>
    typealias Readback = @MainActor (WindowMetadata) async -> Result<WindowFrameReadback, AXClientError>
    typealias Settle = @MainActor () async -> Void

    private static let readbackAttemptCount = 4
    private static let terminalBundleID = "com.apple.Terminal"

    private let writeAccessibility: AccessibilityWrite
    private let writeTerminal: TerminalWrite
    private let readback: Readback
    private let settle: Settle

    init(axClient: AXClient) {
        writeAccessibility = { window, frame in
            await axClient.setFrame(window, to: frame)
        }
        writeTerminal = Self.executeTerminalBounds
        readback = { window in
            switch await axClient.frame(of: window) {
            case .success(let accessibility):
                return axClient.windowServerFrame(of: window).map {
                    WindowFrameReadback(accessibility: accessibility, windowServer: $0)
                }
            case .failure(let error):
                return .failure(error)
            }
        }
        settle = {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    init(
        writeAccessibility: @escaping AccessibilityWrite,
        writeTerminal: @escaping TerminalWrite,
        readback: @escaping Readback,
        settle: @escaping Settle = {}
    ) {
        self.writeAccessibility = writeAccessibility
        self.writeTerminal = writeTerminal
        self.readback = readback
        self.settle = settle
    }

    func setFrame(_ window: WindowMetadata, to requestedFrame: CGRect) async -> AXFrameWriteOutcome {
        let target = canonicalFrameWriteTarget(requestedFrame)
        guard target.narwhalIsFinitePositive else {
            return .failed(.invalidFrame(target))
        }

        let initial: AXFrameWriteOutcome
        if window.bundleID.raw == Self.terminalBundleID {
            switch writeTerminal(window, target) {
            case .success:
                initial = .converged(actual: target)
            case .failure(let error):
                return .failed(error)
            }
        } else {
            initial = await writeAccessibility(window, target)
        }

        switch initial {
        case .failed:
            return initial
        case .converged, .constrained, .clamped:
            break
        }

        var lastReadback: WindowFrameReadback?
        for attempt in 0..<Self.readbackAttemptCount {
            switch await readback(window) {
            case .success(let observed):
                lastReadback = observed
                if observed.accessibility.narwhalApproximatelyEquals(
                    target,
                    tolerance: configuredGapTolerance
                ), observed.windowServer.narwhalApproximatelyEquals(
                    target,
                    tolerance: configuredGapTolerance
                ) {
                    return .converged(actual: observed.accessibility)
                }
                if observed.accessibility.narwhalApproximatelyEquals(
                    observed.windowServer,
                    tolerance: configuredGapTolerance
                ) {
                    switch initial {
                    case .constrained(let actual)
                        where observed.accessibility.narwhalApproximatelyEquals(
                            actual,
                            tolerance: configuredGapTolerance
                        ):
                        return .constrained(actual: observed.accessibility)
                    case .clamped(let actual, let constraints)
                        where observed.accessibility.narwhalApproximatelyEquals(
                            actual,
                            tolerance: configuredGapTolerance
                        ):
                        return .clamped(actual: observed.accessibility, observed: constraints)
                    case .converged, .constrained, .clamped, .failed:
                        break
                    }
                }
            case .failure(let error):
                if attempt == Self.readbackAttemptCount - 1 {
                    return .failed(error)
                }
            }
            if attempt < Self.readbackAttemptCount - 1 {
                await settle()
            }
        }

        guard let lastReadback else {
            return .failed(.windowServerFrameUnavailable(window.id))
        }
        guard lastReadback.accessibility.narwhalApproximatelyEquals(
            lastReadback.windowServer,
            tolerance: configuredGapTolerance
        ) else {
            return .failed(.frameReadbackDisagreed(
                target: target,
                accessibility: lastReadback.accessibility,
                windowServer: lastReadback.windowServer
            ))
        }

        switch initial {
        case .constrained:
            return .constrained(actual: lastReadback.accessibility)
        case .clamped(_, let observed):
            return .clamped(actual: lastReadback.accessibility, observed: observed)
        case .converged:
            return .failed(.frameDidNotConverge(
                target: target,
                actual: lastReadback.accessibility,
                attempts: Self.readbackAttemptCount
            ))
        case .failed:
            return initial
        }
    }

    private static func executeTerminalBounds(
        _ window: WindowMetadata,
        _ frame: CGRect
    ) -> Result<Void, AXClientError> {
        guard let source = terminalBoundsAppleScript(windowID: window.id, frame: frame),
              let script = NSAppleScript(source: source)
        else {
            return .failure(.invalidFrame(frame))
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return .failure(.automationFailed(
                bundleID: window.bundleID.raw,
                message: errorInfo.description
            ))
        }
        return .success(())
    }
}
