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
