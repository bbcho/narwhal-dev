import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Drag gesture model")
struct DragGestureModelTests {
    @Test("Mouse down with matching modifier starts preview candidate")
    func matchingMouseDownStartsPreviewCandidate() {
        let location = CGPoint(x: 10, y: 20)

        let transition = reduceDragGesture(
            state: .empty,
            input: .mouseDown(location: location, modifiers: [.shift]),
            requiredModifier: [.shift]
        )

        #expect(transition.state == DragGestureState(isCandidate: true, hasDragged: false))
        #expect(transition.effects == [.preview(location)])
    }

    @Test("A drop counts only when the window focused at the first drag actually moved")
    func dropRequiresTheFocusedWindowToMove() {
        let window = WindowID(raw: 4)
        let start = DragStartWindow(windowID: window, frame: CGRect(x: 0, y: 0, width: 600, height: 800))

        #expect(dragMovedWindow(from: start, to: DragStartWindow(windowID: window, frame: CGRect(x: 240, y: 30, width: 600, height: 800))))
        #expect(!dragMovedWindow(from: start, to: DragStartWindow(windowID: window, frame: start.frame)))
        #expect(!dragMovedWindow(from: start, to: DragStartWindow(windowID: WindowID(raw: 5), frame: CGRect(x: 240, y: 30, width: 600, height: 800))))
        #expect(!dragMovedWindow(from: nil, to: start))
    }

    @Test("Mouse down with wrong modifier stays inert")
    func wrongMouseDownStaysInert() {
        let transition = reduceDragGesture(
            state: .empty,
            input: .mouseDown(location: CGPoint(x: 10, y: 20), modifiers: [.control]),
            requiredModifier: [.shift]
        )

        #expect(transition.state == .empty)
        #expect(transition.effects == [])
    }

    @Test("The first drag of a gesture begins it, after the clicked window has activated")
    func firstDragBeginsGesture() {
        let location = CGPoint(x: 30, y: 40)

        let transition = reduceDragGesture(
            state: DragGestureState(isCandidate: true, hasDragged: false),
            input: .mouseDragged(location: location, modifiers: [.shift]),
            requiredModifier: [.shift]
        )

        #expect(transition.state == DragGestureState(isCandidate: true, hasDragged: true))
        #expect(transition.effects == [.began, .preview(location)])
    }

    @Test("Later drags of the same gesture only update the preview")
    func laterDragsOnlyUpdatePreview() {
        let location = CGPoint(x: 50, y: 60)

        let transition = reduceDragGesture(
            state: DragGestureState(isCandidate: true, hasDragged: true),
            input: .mouseDragged(location: location, modifiers: [.shift]),
            requiredModifier: [.shift]
        )

        #expect(transition.state == DragGestureState(isCandidate: true, hasDragged: true))
        #expect(transition.effects == [.preview(location)])
    }

    @Test("Drag with changed modifier cancels preview without dropping")
    func changedModifierCancelsPreview() {
        let transition = reduceDragGesture(
            state: DragGestureState(isCandidate: true, hasDragged: true),
            input: .mouseDragged(location: CGPoint(x: 30, y: 40), modifiers: [.control]),
            requiredModifier: [.shift]
        )

        #expect(transition.state == .empty)
        #expect(transition.effects == [.endPreview])
    }

    @Test("Mouse up drops only after a real drag")
    func mouseUpDropsOnlyAfterDrag() {
        let location = CGPoint(x: 50, y: 60)

        let noDrag = reduceDragGesture(
            state: DragGestureState(isCandidate: true, hasDragged: false),
            input: .mouseUp(location: location),
            requiredModifier: [.shift]
        )
        let dragged = reduceDragGesture(
            state: DragGestureState(isCandidate: true, hasDragged: true),
            input: .mouseUp(location: location),
            requiredModifier: [.shift]
        )

        #expect(noDrag.state == .empty)
        #expect(noDrag.effects == [.endPreview])
        #expect(dragged.state == .empty)
        #expect(dragged.effects == [.endPreview, .drop(location)])
    }

    @Test("Cancel clears active candidate and hides preview")
    func cancelClearsActiveCandidate() {
        let active = reduceDragGesture(
            state: DragGestureState(isCandidate: true, hasDragged: true),
            input: .cancel,
            requiredModifier: [.shift]
        )
        let inactive = reduceDragGesture(
            state: .empty,
            input: .cancel,
            requiredModifier: [.shift]
        )

        #expect(active.state == .empty)
        #expect(active.effects == [.endPreview])
        #expect(inactive.state == .empty)
        #expect(inactive.effects == [])
    }
}
