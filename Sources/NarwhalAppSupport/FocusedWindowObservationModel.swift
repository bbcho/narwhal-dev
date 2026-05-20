import CoreGraphics
import NarwhalCore

public struct FocusedWindowObservationState: Equatable, Sendable {
    public let geometry: FocusedWindowGeometryState

    public init(geometry: FocusedWindowGeometryState) {
        self.geometry = geometry
    }

    public static let empty = FocusedWindowObservationState(geometry: .empty)
}

public enum FocusedWindowObservationInput: Equatable, Sendable {
    case observed(windowID: WindowID, frame: CGRect)
    case unavailable
}

public enum FocusedWindowObservationEffect: Equatable, Sendable {
    case emit(AXEvent)
}

public struct FocusedWindowObservationTransition: Equatable, Sendable {
    public let state: FocusedWindowObservationState
    public let effects: [FocusedWindowObservationEffect]

    public init(
        state: FocusedWindowObservationState,
        effects: [FocusedWindowObservationEffect]
    ) {
        self.state = state
        self.effects = effects
    }
}

public func reduceFocusedWindowObservation(
    state: FocusedWindowObservationState,
    input: FocusedWindowObservationInput,
    tolerance: CGFloat
) -> FocusedWindowObservationTransition {
    switch input {
    case .observed(let windowID, let frame):
        let poll = pollFocusedWindowGeometry(
            previous: state.geometry,
            currentWindowID: windowID,
            currentFrame: frame,
            tolerance: tolerance
        )
        let effects = poll.event.map { [FocusedWindowObservationEffect.emit($0)] } ?? []
        return FocusedWindowObservationTransition(
            state: FocusedWindowObservationState(geometry: poll.state),
            effects: effects
        )

    case .unavailable:
        return FocusedWindowObservationTransition(state: state, effects: [])
    }
}
