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
}
