import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Focused window observation model")
struct FocusedWindowObservationModelTests {
    @Test("First focused snapshot emits focus")
    func firstFocusedSnapshotEmitsFocus() {
        let window = WindowID(raw: 100)
        let frame = CGRect(x: 10, y: 20, width: 400, height: 300)

        let transition = reduceFocusedWindowObservation(
            state: .empty,
            input: .observed(windowID: window, frame: frame),
            tolerance: 1
        )

        #expect(transition.state.geometry == FocusedWindowGeometryState(windowID: window, frame: frame))
        #expect(transition.effects == [.emit(.windowFocused(window))])
    }

    @Test("Unavailable focus clears stale state exactly once")
    func unavailableFocusClearsStaleStateOnce() {
        let stale = FocusedWindowObservationState(
            geometry: FocusedWindowGeometryState(
                windowID: WindowID(raw: 101),
                frame: CGRect(x: 10, y: 20, width: 400, height: 300)
            )
        )

        let first = reduceFocusedWindowObservation(
            state: stale,
            input: .unavailable,
            tolerance: 1
        )
        let second = reduceFocusedWindowObservation(
            state: first.state,
            input: .unavailable,
            tolerance: 1
        )

        #expect(first.state == .empty)
        #expect(first.effects == [.focusedWindowUnavailable])
        #expect(second.state == .empty)
        #expect(second.effects == [])
    }

    @Test("New snapshot after unavailable emits fresh focus")
    func snapshotAfterUnavailableEmitsFreshFocus() {
        let oldWindow = WindowID(raw: 102)
        let newWindow = WindowID(raw: 103)
        let oldFrame = CGRect(x: 10, y: 20, width: 400, height: 300)
        let newFrame = CGRect(x: 500, y: 20, width: 400, height: 300)
        let stale = FocusedWindowObservationState(
            geometry: FocusedWindowGeometryState(windowID: oldWindow, frame: oldFrame)
        )

        let unavailable = reduceFocusedWindowObservation(
            state: stale,
            input: .unavailable,
            tolerance: 1
        )
        let observed = reduceFocusedWindowObservation(
            state: unavailable.state,
            input: .observed(windowID: newWindow, frame: newFrame),
            tolerance: 1
        )

        #expect(observed.state.geometry == FocusedWindowGeometryState(windowID: newWindow, frame: newFrame))
        #expect(observed.effects == [.emit(.windowFocused(newWindow))])
    }

    @Test("Focused frame change emits geometry event")
    func focusedFrameChangeEmitsGeometryEvent() {
        let window = WindowID(raw: 104)
        let oldFrame = CGRect(x: 10, y: 20, width: 400, height: 300)
        let newFrame = CGRect(x: 30, y: 40, width: 400, height: 300)
        let state = FocusedWindowObservationState(
            geometry: FocusedWindowGeometryState(windowID: window, frame: oldFrame)
        )

        let transition = reduceFocusedWindowObservation(
            state: state,
            input: .observed(windowID: window, frame: newFrame),
            tolerance: 1
        )

        #expect(transition.state.geometry == FocusedWindowGeometryState(windowID: window, frame: newFrame))
        #expect(transition.effects == [.emit(.windowMoved(window, newFrame))])
    }
}
