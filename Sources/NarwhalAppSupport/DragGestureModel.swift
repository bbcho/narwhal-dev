import CoreGraphics
import NarwhalCore

public struct DragGestureState: Equatable, Sendable {
    public let isCandidate: Bool
    public let hasDragged: Bool

    public init(isCandidate: Bool, hasDragged: Bool) {
        self.isCandidate = isCandidate
        self.hasDragged = hasDragged
    }

    public static let empty = DragGestureState(isCandidate: false, hasDragged: false)
}

public enum DragGestureInput: Equatable, Sendable {
    case mouseDown(location: CGPoint, modifiers: ModifierSet)
    case mouseDragged(location: CGPoint, modifiers: ModifierSet)
    case mouseUp(location: CGPoint)
    case cancel
}

public enum DragGestureEffect: Equatable, Sendable {
    /// The first drag of a modifier gesture: record the focused window to tell
    /// a window drag from, say, extending a text selection with shift held.
    /// Not at mouse-down, when a clicked window has not been activated yet.
    case began
    case preview(CGPoint)
    case endPreview
    case drop(CGPoint)
}

public struct DragGestureTransition: Equatable, Sendable {
    public let state: DragGestureState
    public let effects: [DragGestureEffect]

    public init(state: DragGestureState, effects: [DragGestureEffect]) {
        self.state = state
        self.effects = effects
    }
}

public func reduceDragGesture(
    state: DragGestureState,
    input: DragGestureInput,
    requiredModifier: ModifierSet
) -> DragGestureTransition {
    switch input {
    case .mouseDown(let location, let modifiers):
        guard modifiers == requiredModifier else {
            return DragGestureTransition(state: .empty, effects: [])
        }
        return DragGestureTransition(
            state: DragGestureState(isCandidate: true, hasDragged: false),
            effects: [.preview(location)]
        )

    case .mouseDragged(let location, let modifiers):
        guard state.isCandidate else {
            return DragGestureTransition(state: state, effects: [])
        }
        guard modifiers == requiredModifier else {
            return DragGestureTransition(state: .empty, effects: [.endPreview])
        }
        return DragGestureTransition(
            state: DragGestureState(isCandidate: true, hasDragged: true),
            effects: state.hasDragged ? [.preview(location)] : [.began, .preview(location)]
        )

    case .mouseUp(let location):
        let effects: [DragGestureEffect] = state.isCandidate && state.hasDragged
            ? [.endPreview, .drop(location)]
            : [.endPreview]
        return DragGestureTransition(state: .empty, effects: effects)

    case .cancel:
        let effects: [DragGestureEffect] = state.isCandidate ? [.endPreview] : []
        return DragGestureTransition(state: .empty, effects: effects)
    }
}

public struct DragStartWindow: Equatable, Sendable {
    public let windowID: WindowID
    public let frame: CGRect

    public init(windowID: WindowID, frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

/// A modifier drag tiles a window only if the window focused at the gesture's
/// first drag is still focused and moved; otherwise it was not dragging that window.
public func dragMovedWindow(from start: DragStartWindow?, to end: DragStartWindow) -> Bool {
    guard let start, start.windowID == end.windowID else { return false }
    return !start.frame.narwhalApproximatelyEquals(end.frame, tolerance: frameWriteSettleTolerance)
}
