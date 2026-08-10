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

func terminalAppleScriptFrame(
    target: CGRect,
    sourceFrame: CGRect,
    displayFrames: [CGRect]
) -> CGRect {
    let candidates: [(frame: CGRect, intersectionArea: CGFloat)] = displayFrames.map { displayFrame in
        let intersection = sourceFrame.intersection(displayFrame)
        let area = intersection.isNull ? 0 : intersection.width * intersection.height
        return (frame: displayFrame, intersectionArea: area)
    }
    let sourceDisplay = candidates
        .filter { $0.intersectionArea > 0 }
        .sorted {
            if $0.intersectionArea != $1.intersectionArea {
                return $0.intersectionArea > $1.intersectionArea
            }
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.width != $1.frame.width { return $0.frame.width < $1.frame.width }
            return $0.frame.height < $1.frame.height
        }
        .first?
        .frame

    guard let sourceDisplay else { return target }
    return target.offsetBy(dx: 0, dy: -sourceDisplay.minY)
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

    func readFrame(_ window: WindowMetadata) async -> Result<WindowFrameReadback, AXClientError> {
        await readback(window)
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
        var readbackFrames: [CGRect] = []
        for attempt in 0..<Self.readbackAttemptCount {
            switch await readback(window) {
            case .success(let observed):
                lastReadback = observed
                readbackFrames.append(observed.accessibility)
                if observed.accessibility.narwhalApproximatelyEquals(
                    target,
                    tolerance: configuredGapTolerance
                ), observed.windowServer.narwhalApproximatelyEquals(
                    target,
                    tolerance: configuredGapTolerance
                ) {
                    return .converged(actual: observed.accessibility)
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

        if let observed = confirmedObservedConstraints(
            target: target,
            actualFrames: readbackFrames
        ) {
            return .clamped(
                actual: lastReadback.accessibility,
                observed: observed
            )
        }

        switch initial {
        case .constrained:
            return .constrained(actual: lastReadback.accessibility)
        case .clamped(let initialActual, let observed):
            let remainedAtInitialFrame = readbackFrames.allSatisfy {
                $0.narwhalApproximatelyEquals(
                    initialActual,
                    tolerance: configuredGapTolerance
                )
            }
            if remainedAtInitialFrame {
                return .clamped(actual: lastReadback.accessibility, observed: observed)
            }
            if axFrameWriteConstrainedFrameIsAnchored(
                target: target,
                actual: lastReadback.accessibility
            ) {
                return .constrained(actual: lastReadback.accessibility)
            }
            return .failed(.frameDidNotConverge(
                target: target,
                actual: lastReadback.accessibility,
                attempts: Self.readbackAttemptCount
            ))
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
        let appleScriptFrame = terminalAppleScriptFrame(
            target: frame,
            sourceFrame: window.frame,
            displayFrames: activeDisplayFrames()
        )
        guard let source = terminalBoundsAppleScript(windowID: window.id, frame: appleScriptFrame),
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

    private static func activeDisplayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0
        else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }
        return displayIDs.prefix(Int(count)).map(CGDisplayBounds)
    }
}
