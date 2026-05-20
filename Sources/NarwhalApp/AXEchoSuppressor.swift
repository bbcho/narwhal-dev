import CoreGraphics
import Foundation
import NarwhalCore

@MainActor
final class AXEchoSuppressor {
    private var state = AXEchoState.empty
    private let ttl: TimeInterval
    private let tolerance: CGFloat
    private let now: () -> TimeInterval

    init(
        ttl: TimeInterval = 1.5,
        tolerance: CGFloat = 2,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.ttl = ttl
        self.tolerance = tolerance
        self.now = now
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

}
