import CoreGraphics
import Foundation
import WinMgrCore

@MainActor
final class AXEchoSuppressor {
    private var state = AXEchoState.empty
    private let ttl: TimeInterval
    private let tolerance: CGFloat

    init(ttl: TimeInterval = 1.5, tolerance: CGFloat = 2) {
        self.ttl = ttl
        self.tolerance = tolerance
    }

    func expectFrame(windowID: WindowID, targetFrame: CGRect) {
        state = expectFrameEcho(
            windowID: windowID,
            targetFrame: targetFrame,
            now: now(),
            ttl: ttl,
            in: state
        )
    }

    func expectFocus(windowID: WindowID) {
        state = expectFocusEcho(windowID: windowID, now: now(), ttl: ttl, in: state)
    }

    func isExpectedEcho(_ event: AXEvent) -> Bool {
        let result = consumeExpectedEcho(event, now: now(), tolerance: tolerance, in: state)
        state = result.state
        return result.isEcho
    }

    private func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }
}
