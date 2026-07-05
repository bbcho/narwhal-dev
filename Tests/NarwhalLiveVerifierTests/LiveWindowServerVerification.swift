#if NARWHAL_ENABLE_VERIFIERS
import CoreGraphics
import Foundation
import NarwhalCore

enum LiveWindowServerVerification {
    static func waitForFrame(windowNumber: Int, matching expected: CGRect, tolerance: CGFloat = 2) -> CGRect? {
        let deadline = Date().addingTimeInterval(0.6)
        var lastFrame: CGRect?
        while Date() < deadline {
            lastFrame = frame(for: windowNumber)
            if lastFrame?.matches(expected, tolerance: tolerance) == true {
                reviewPause("window \(windowNumber) matched WindowServer frame \(expected.debugDescription)")
                return lastFrame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return lastFrame
    }

    static func frame(for windowNumber: Int) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return nil }

        for window in windows {
            let number: Int?
            if let value = window[kCGWindowNumber as String] as? CGWindowID {
                number = Int(value)
            } else {
                number = window[kCGWindowNumber as String] as? Int
            }
            guard number == windowNumber,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }
            return frame
        }
        return nil
    }

    static func reviewPause(_ message: String) {
        guard ProcessInfo.processInfo.environment["NARWHAL_LIVE_VERIFIER_REVIEW"] == "1" else { return }
        let rawDelay = ProcessInfo.processInfo.environment["NARWHAL_LIVE_VERIFIER_REVIEW_DELAY"]
            .flatMap(Double.init)
        let delay = rawDelay.map { $0.isFinite && $0 > 0 ? $0 : 1.5 } ?? 1.5
        print("LIVE REVIEW: \(message)")
        RunLoop.current.run(until: Date().addingTimeInterval(delay))
    }
}

private extension CGRect {
    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        narwhalApproximatelyEquals(other, tolerance: tolerance)
    }
}
#endif
