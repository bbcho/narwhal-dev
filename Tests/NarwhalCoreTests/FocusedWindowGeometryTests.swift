import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Focused window geometry polling")
struct FocusedWindowGeometryTests {
    @Test("First observation emits focus and records frame")
    func firstObservationEmitsFocusAndRecordsFrame() {
        let window = WindowID(raw: 10)
        let frame = CGRect(x: 100, y: 200, width: 700, height: 500)

        let result = pollFocusedWindowGeometry(
            previous: .empty,
            currentWindowID: window,
            currentFrame: frame,
            tolerance: 1
        )

        #expect(result.event == .windowFocused(window))
        #expect(result.state == FocusedWindowGeometryState(windowID: window, frame: frame))
    }

    @Test("Unchanged focused window emits no event")
    func unchangedFocusedWindowEmitsNoEvent() {
        let window = WindowID(raw: 11)
        let frame = CGRect(x: 100, y: 200, width: 700, height: 500)
        let previous = FocusedWindowGeometryState(windowID: window, frame: frame)

        let result = pollFocusedWindowGeometry(
            previous: previous,
            currentWindowID: window,
            currentFrame: frame,
            tolerance: 1
        )

        #expect(result.event == nil)
        #expect(result.state == previous)
    }

    @Test("Same focused window moved by user emits move event")
    func sameFocusedWindowMovedByUserEmitsMoveEvent() {
        let window = WindowID(raw: 12)
        let previousFrame = CGRect(x: 100, y: 200, width: 700, height: 500)
        let currentFrame = CGRect(x: 140, y: 260, width: 700, height: 500)

        let result = pollFocusedWindowGeometry(
            previous: FocusedWindowGeometryState(windowID: window, frame: previousFrame),
            currentWindowID: window,
            currentFrame: currentFrame,
            tolerance: 1
        )

        #expect(result.event == .windowMoved(window, currentFrame))
        #expect(result.state == FocusedWindowGeometryState(windowID: window, frame: currentFrame))
    }

    @Test("Same focused window resized by user emits resize event")
    func sameFocusedWindowResizedByUserEmitsResizeEvent() {
        let window = WindowID(raw: 13)
        let previousFrame = CGRect(x: 100, y: 200, width: 700, height: 500)
        let currentFrame = CGRect(x: 100, y: 200, width: 900, height: 650)

        let result = pollFocusedWindowGeometry(
            previous: FocusedWindowGeometryState(windowID: window, frame: previousFrame),
            currentWindowID: window,
            currentFrame: currentFrame,
            tolerance: 1
        )

        #expect(result.event == .windowResized(window, currentFrame.size))
        #expect(result.state == FocusedWindowGeometryState(windowID: window, frame: currentFrame))
    }

    @Test("Frame drift inside tolerance emits no event")
    func frameDriftInsideToleranceEmitsNoEvent() {
        let window = WindowID(raw: 14)
        let previousFrame = CGRect(x: 100, y: 200, width: 700, height: 500)
        let currentFrame = CGRect(x: 100.5, y: 199.5, width: 700.5, height: 499.5)
        let previous = FocusedWindowGeometryState(windowID: window, frame: previousFrame)

        let result = pollFocusedWindowGeometry(
            previous: previous,
            currentWindowID: window,
            currentFrame: currentFrame,
            tolerance: 1
        )

        #expect(result.event == nil)
        #expect(result.state == previous)
    }

    @Test("Changed focused window emits focus instead of stale move")
    func changedFocusedWindowEmitsFocusInsteadOfStaleMove() {
        let previous = FocusedWindowGeometryState(
            windowID: WindowID(raw: 15),
            frame: CGRect(x: 0, y: 0, width: 500, height: 500)
        )
        let currentWindow = WindowID(raw: 16)
        let currentFrame = CGRect(x: 600, y: 100, width: 800, height: 700)

        let result = pollFocusedWindowGeometry(
            previous: previous,
            currentWindowID: currentWindow,
            currentFrame: currentFrame,
            tolerance: 1
        )

        #expect(result.event == .windowFocused(currentWindow))
        #expect(result.state == FocusedWindowGeometryState(windowID: currentWindow, frame: currentFrame))
    }
}
