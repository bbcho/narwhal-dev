import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("AX echo suppression")
struct AXEchoTests {
    @Test("Frame echo suppresses move and resize callbacks independently")
    func frameEchoSuppressesMoveAndResizeIndependently() {
        let window = WindowID(raw: 1)
        let target = CGRect(x: 10, y: 20, width: 300, height: 400)
        let initial = expectFrameEcho(windowID: window, targetFrame: target, now: 100, ttl: 5, in: .empty)

        let moved = consumeExpectedEcho(.windowMoved(window, target), now: 101, tolerance: 2, in: initial)
        let resized = consumeExpectedEcho(.windowResized(window, target.size), now: 102, tolerance: 2, in: moved.state)

        #expect(moved.isEcho)
        #expect(moved.state.frameEchoes == [
            AXExpectedFrameEcho(
                windowID: window,
                targetFrame: target,
                expiresAt: 105,
                expectsMove: false,
                expectsResize: true
            )
        ])
        #expect(resized.isEcho)
        #expect(resized.state == .empty)
    }

    @Test("Nonmatching frame event is not suppressed")
    func nonmatchingFrameEventIsNotSuppressed() {
        let window = WindowID(raw: 1)
        let target = CGRect(x: 10, y: 20, width: 300, height: 400)
        let state = expectFrameEcho(windowID: window, targetFrame: target, now: 100, ttl: 5, in: .empty)

        let result = consumeExpectedEcho(
            .windowMoved(window, CGRect(x: 50, y: 20, width: 300, height: 400)),
            now: 101,
            tolerance: 2,
            in: state
        )

        #expect(!result.isEcho)
        #expect(result.state == state)
    }

    @Test("Focus echo is consumed once")
    func focusEchoIsConsumedOnce() {
        let window = WindowID(raw: 7)
        let state = expectFocusEcho(windowID: window, now: 10, ttl: 5, in: .empty)

        let first = consumeExpectedEcho(.windowFocused(window), now: 11, tolerance: 2, in: state)
        let second = consumeExpectedEcho(.windowFocused(window), now: 12, tolerance: 2, in: first.state)

        #expect(first.isEcho)
        #expect(first.state == .empty)
        #expect(!second.isEcho)
        #expect(second.state == .empty)
    }

    @Test("Expired echoes are pruned and not suppressed")
    func expiredEchoesArePruned() {
        let window = WindowID(raw: 3)
        let target = CGRect(x: 1, y: 2, width: 3, height: 4)
        let state = expectFrameEcho(windowID: window, targetFrame: target, now: 100, ttl: 5, in: .empty)

        let result = consumeExpectedEcho(.windowMoved(window, target), now: 106, tolerance: 2, in: state)

        #expect(!result.isEcho)
        #expect(result.state == .empty)
    }
}
