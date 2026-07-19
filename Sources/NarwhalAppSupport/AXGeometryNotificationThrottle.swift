public struct AXGeometryNotificationThrottleState: Equatable, Sendable {
    public let timerScheduled: Bool
    public let hasPendingNotification: Bool

    public init(timerScheduled: Bool, hasPendingNotification: Bool) {
        self.timerScheduled = timerScheduled
        self.hasPendingNotification = hasPendingNotification
    }

    public static let idle = AXGeometryNotificationThrottleState(
        timerScheduled: false,
        hasPendingNotification: false
    )
}

public enum AXGeometryNotificationThrottleInput: Equatable, Sendable {
    case notificationReceived
    case timerFired
    case cancelled
}

public enum AXGeometryNotificationThrottleEffect: Equatable, Sendable {
    case pollFocusedWindow
    case scheduleTimer
}

public struct AXGeometryNotificationThrottleTransition: Equatable, Sendable {
    public let state: AXGeometryNotificationThrottleState
    public let effects: [AXGeometryNotificationThrottleEffect]

    public init(
        state: AXGeometryNotificationThrottleState,
        effects: [AXGeometryNotificationThrottleEffect]
    ) {
        self.state = state
        self.effects = effects
    }
}

public func reduceAXGeometryNotificationThrottle(
    state: AXGeometryNotificationThrottleState,
    input: AXGeometryNotificationThrottleInput
) -> AXGeometryNotificationThrottleTransition {
    switch input {
    case .notificationReceived where !state.timerScheduled:
        return AXGeometryNotificationThrottleTransition(
            state: AXGeometryNotificationThrottleState(
                timerScheduled: true,
                hasPendingNotification: false
            ),
            effects: [.pollFocusedWindow, .scheduleTimer]
        )

    case .notificationReceived:
        return AXGeometryNotificationThrottleTransition(
            state: AXGeometryNotificationThrottleState(
                timerScheduled: true,
                hasPendingNotification: true
            ),
            effects: []
        )

    case .timerFired where state.hasPendingNotification:
        return AXGeometryNotificationThrottleTransition(
            state: AXGeometryNotificationThrottleState(
                timerScheduled: true,
                hasPendingNotification: false
            ),
            effects: [.pollFocusedWindow, .scheduleTimer]
        )

    case .timerFired, .cancelled:
        return AXGeometryNotificationThrottleTransition(state: .idle, effects: [])
    }
}
