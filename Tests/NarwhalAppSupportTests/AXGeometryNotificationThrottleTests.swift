import Testing
@testable import NarwhalAppSupport

@Suite("AX geometry notification throttle")
struct AXGeometryNotificationThrottleTests {
    @Test("The first notification polls immediately and starts the throttle window")
    func firstNotificationIsLeadingEdge() {
        let transition = reduceAXGeometryNotificationThrottle(
            state: .idle,
            input: .notificationReceived
        )

        #expect(transition == AXGeometryNotificationThrottleTransition(
            state: AXGeometryNotificationThrottleState(
                timerScheduled: true,
                hasPendingNotification: false
            ),
            effects: [.pollFocusedWindow, .scheduleTimer]
        ))
    }

    @Test("Notifications inside the throttle window collapse to one trailing poll")
    func burstCollapsesToTrailingPoll() {
        let leading = reduceAXGeometryNotificationThrottle(
            state: .idle,
            input: .notificationReceived
        )
        let pending = reduceAXGeometryNotificationThrottle(
            state: leading.state,
            input: .notificationReceived
        )
        let stillPending = reduceAXGeometryNotificationThrottle(
            state: pending.state,
            input: .notificationReceived
        )
        let trailing = reduceAXGeometryNotificationThrottle(
            state: stillPending.state,
            input: .timerFired
        )

        #expect(pending.effects.isEmpty)
        #expect(stillPending.effects.isEmpty)
        #expect(trailing == AXGeometryNotificationThrottleTransition(
            state: AXGeometryNotificationThrottleState(
                timerScheduled: true,
                hasPendingNotification: false
            ),
            effects: [.pollFocusedWindow, .scheduleTimer]
        ))
    }

    @Test("An idle timer and cancellation both leave no scheduled work")
    func idleAndCancellationClearState() {
        let scheduled = AXGeometryNotificationThrottleState(
            timerScheduled: true,
            hasPendingNotification: false
        )

        #expect(reduceAXGeometryNotificationThrottle(
            state: scheduled,
            input: .timerFired
        ) == AXGeometryNotificationThrottleTransition(state: .idle, effects: []))
        #expect(reduceAXGeometryNotificationThrottle(
            state: AXGeometryNotificationThrottleState(
                timerScheduled: true,
                hasPendingNotification: true
            ),
            input: .cancelled
        ) == AXGeometryNotificationThrottleTransition(state: .idle, effects: []))
    }
}
