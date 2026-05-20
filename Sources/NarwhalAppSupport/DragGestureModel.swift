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
            effects: [.preview(location)]
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
