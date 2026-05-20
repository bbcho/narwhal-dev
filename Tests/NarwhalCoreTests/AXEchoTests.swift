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

    @Test("Consuming middle frame echo preserves surrounding order")
    func consumingMiddleFrameEchoPreservesSurroundingOrder() {
        let first = WindowID(raw: 10)
        let middle = WindowID(raw: 11)
        let last = WindowID(raw: 12)
        let target = CGRect(x: 1, y: 2, width: 300, height: 400)
        let state = [
            first,
            middle,
            last
        ].reduce(AXEchoState.empty) { state, windowID in
            expectFrameEcho(windowID: windowID, targetFrame: target, now: 100, ttl: 5, in: state)
        }

        let result = consumeExpectedEcho(.windowMoved(middle, target), now: 101, tolerance: 1, in: state)

        #expect(result.isEcho)
        #expect(result.state.frameEchoes.map(\.windowID) == [first, middle, last])
        #expect(result.state.frameEchoes[1].expectsMove == false)
        #expect(result.state.frameEchoes[1].expectsResize == true)
    }

    @Test("Consuming middle focus echo removes only that echo")
    func consumingMiddleFocusEchoRemovesOnlyThatEcho() {
        let first = WindowID(raw: 20)
        let middle = WindowID(raw: 21)
        let last = WindowID(raw: 22)
        let state = [
            first,
            middle,
            last
        ].reduce(AXEchoState.empty) { state, windowID in
            expectFocusEcho(windowID: windowID, now: 100, ttl: 5, in: state)
        }

        let result = consumeExpectedEcho(.windowFocused(middle), now: 101, tolerance: 1, in: state)

        #expect(result.isEcho)
        #expect(result.state.focusEchoes.map(\.windowID) == [first, last])
    }
}
