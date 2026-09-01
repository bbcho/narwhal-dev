#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Darwin
import Foundation
import NarwhalCore

@MainActor
enum RealFrameAssertions {
    static func currentFrames(
        _ windows: [RealAppOriginal],
        using axClient: AXClient
    ) throws -> [WindowID: CGRect] {
        try Dictionary(uniqueKeysWithValues: windows.map { window in
            let metadata = try RealAppLaunchSupport.currentMetadata(for: window, using: axClient)
            return (metadata.id, metadata.frame)
        })
    }

    static func requireAXAndWindowServerFrames(
        _ actual: [WindowID: CGRect],
        expected: [WindowID: CGRect],
        context: String,
        tolerance: CGFloat = frameWriteSettleTolerance
    ) throws {
        guard Set(actual.keys) == Set(expected.keys) else {
            throw RealAppWindowVerifierFailure(
                "\(context) window IDs differ: expected=\(expected.keys) actual=\(actual.keys)"
            )
        }
        for (windowID, expectedFrame) in expected {
            guard let axFrame = actual[windowID],
                  axFrame.narwhalApproximatelyEquals(expectedFrame, tolerance: tolerance)
            else {
                throw RealAppWindowVerifierFailure(
                    "\(context) AX frame mismatch for \(windowID.description): expected=\(expectedFrame) actual=\(String(describing: actual[windowID]))"
                )
            }
            let serverFrame = LiveWindowServerVerification.waitForFrame(
                windowNumber: Int(windowID.raw),
                matching: axFrame,
                tolerance: tolerance
            )
            guard serverFrame?.narwhalApproximatelyEquals(axFrame, tolerance: tolerance) == true else {
                throw RealAppWindowVerifierFailure(
                    "\(context) WindowServer frame mismatch for \(windowID.description): AX=\(axFrame) WindowServer=\(String(describing: serverFrame))"
                )
            }
        }
        try requireDisjoint(Array(actual.values), context: context)
    }

    static func requireExactFrames(
        _ actual: [WindowID: CGRect],
        expected: [WindowID: CGRect],
        context: String
    ) throws {
        guard actual == expected else {
            throw RealAppWindowVerifierFailure(
                "\(context) exact frame mismatch: expected=\(expected) actual=\(actual)"
            )
        }
    }

    static func requireProductionBorders(
        frames: [WindowID: CGRect],
        focusedWindowID: WindowID,
        ownerPID: pid_t,
        display: DisplayInfo,
        context: String
    ) throws {
        guard let focusFrame = frames[focusedWindowID] else {
            throw RealAppWindowVerifierFailure("\(context) omitted focused border target \(focusedWindowID.description)")
        }
        let expected = frames.values.map { productionBorderFrame(forAXFrame: $0, on: display) }
            + [productionBorderFrame(forAXFrame: focusFrame, on: display)]
        let deadline = Date().addingTimeInterval(1.5)
        var actual: [CGRect] = []
        while Date() < deadline {
            actual = productionOverlayFrames(ownerPID: ownerPID)
            if actual.count == expected.count,
               uniquelyMatches(expected: expected, actual: actual, tolerance: 0.5) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        throw RealAppWindowVerifierFailure(
            "\(context) production borders do not match current frames: expected=\(expected) actual=\(actual)"
        )
    }

    static func requireNoForbiddenRuntimeOutcomes(_ log: String, context: String) throws {
        let forbidden = [
            "source workspace changed before commit",
            "planned layout was not committed",
            "stale parent focus border remained visible",
            "visible frames overlap",
            "reconciliation required",
            "rollback failed"
        ]
        let matches = forbidden.filter { log.localizedCaseInsensitiveContains($0) }
        guard matches.isEmpty else {
            throw RealAppWindowVerifierFailure("\(context) logged forbidden outcomes: \(matches)")
        }
    }

    private static func requireDisjoint(_ frames: [CGRect], context: String) throws {
        for firstIndex in frames.indices {
            for secondIndex in frames.indices where secondIndex > firstIndex {
                let overlap = frames[firstIndex].intersection(frames[secondIndex])
                guard overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5 else {
                    throw RealAppWindowVerifierFailure(
                        "\(context) visible frames overlap: first=\(frames[firstIndex]) second=\(frames[secondIndex]) overlap=\(overlap)"
                    )
                }
            }
        }
    }

    private static func productionBorderFrame(forAXFrame frame: CGRect, on display: DisplayInfo) -> CGRect {
        let proposed = appKitFrame(forAXFrame: frame, on: display).insetBy(dx: -1, dy: -1)
        return axFrame(
            forAppKitFrame: LiveWindowServerVerification.constrainedBorderContentFrame(proposed, on: display.id),
            on: display
        )
    }

    private static func uniquelyMatches(expected: [CGRect], actual: [CGRect], tolerance: CGFloat) -> Bool {
        var remaining = actual
        for frame in expected {
            guard let index = remaining.firstIndex(where: {
                LiveWindowServerVerification.borderSurfaceMatches(
                    $0,
                    contentFrame: frame,
                    tolerance: tolerance
                )
            }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    private static func productionOverlayFrames(ownerPID: pid_t) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid == ownerPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == NSWindow.Level.normal.rawValue,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.narwhalIsFinitePositive
            else { return nil }
            return frame
        }
    }

    private static func appKitFrame(forAXFrame frame: CGRect, on display: DisplayInfo) -> CGRect {
        let screenFrame = screen(for: display.id)?.frame ?? display.frame
        return CGRect(
            x: screenFrame.minX + (frame.minX - display.frame.minX),
            y: screenFrame.minY + (display.frame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    private static func axFrame(forAppKitFrame frame: CGRect, on display: DisplayInfo) -> CGRect {
        let screenFrame = screen(for: display.id)?.frame ?? display.frame
        return CGRect(
            x: display.frame.minX + (frame.minX - screenFrame.minX),
            y: display.frame.maxY - (frame.maxY - screenFrame.minY),
            width: frame.width,
            height: frame.height
        )
    }

    private static func screen(for displayID: DisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID.raw
        }
    }
}
#endif
