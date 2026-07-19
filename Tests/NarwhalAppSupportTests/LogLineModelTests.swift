import Testing
@testable import NarwhalAppSupport

@Suite("Log line model")
struct LogLineModelTests {
    @Test("Formatted log lines are deterministic")
    func formattedLogLinesAreDeterministic() {
        #expect(formattedLogLine(
            timestamp: "2026-05-20T12:34:56Z",
            level: .info,
            message: "NarwhalApp started"
        ) == "2026-05-20T12:34:56Z info: NarwhalApp started\n")
        #expect(formattedLogLine(
            timestamp: "2026-05-20T12:34:57Z",
            level: .error,
            message: "AX focus read failed"
        ) == "2026-05-20T12:34:57Z error: AX focus read failed\n")
    }

    @Test("Log privacy removes titles, bundle identifiers, and full paths")
    func redactsPrivateSupportData() {
        let message = redactedLogMessage(
            #"Focused id=w9 bundle=com.secret.mail title="Inbox • person@example.com" role=AXWindow config=/Users/person/.config/narwhal/init.lua socket(/private/tmp/narwhal.sock)"#
        )

        #expect(message.contains("com.secret.mail") == false)
        #expect(message.contains("person@example.com") == false)
        #expect(message.contains("/Users/person") == false)
        #expect(message.contains("/private/tmp") == false)
        #expect(message.contains("id=w9"))
        #expect(message.contains("role=AXWindow"))
    }

    @Test("Log privacy preserves hotkey slash notation and operational frames")
    func preservesOperationalData() {
        let message = redactedLogMessage(
            "Registered control-option-/ frame=(10.0, 20.0, 300.0, 400.0)"
        )

        #expect(message == "Registered control-option-/ frame=(10.0, 20.0, 300.0, 400.0)")
    }

    @Test("Rotation shifts archives oldest-first and replaces the oldest generation")
    func rotationPlanIsOldestFirst() {
        #expect(logRotationPlan(
            currentByteCount: 5_000_000,
            maximumByteCount: 5_000_000,
            retainedGenerationCount: 3
        ) == [
            .remove(generation: 3),
            .move(fromGeneration: 2, toGeneration: 3),
            .move(fromGeneration: 1, toGeneration: 2),
            .move(fromGeneration: 0, toGeneration: 1)
        ])
    }

    @Test("Rotation does nothing below the limit or without archive generations")
    func rotationPlanRespectsPolicyBoundaries() {
        #expect(logRotationPlan(
            currentByteCount: 99,
            maximumByteCount: 100,
            retainedGenerationCount: 3
        ).isEmpty)
        #expect(logRotationPlan(
            currentByteCount: 100,
            maximumByteCount: 100,
            retainedGenerationCount: 0
        ).isEmpty)
    }
}
