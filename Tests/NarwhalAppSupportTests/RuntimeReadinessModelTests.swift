import Testing
@testable import NarwhalAppSupport

@Suite("Runtime readiness model")
struct RuntimeReadinessModelTests {
    @Test("Only non-operational startup states offer retry")
    func retryPolicyMatchesReadiness() {
        #expect(RuntimeReadiness.starting.canRetryStartup == false)
        #expect(RuntimeReadiness.waitingForAccessibility.canRetryStartup)
        #expect(RuntimeReadiness.operational.canRetryStartup == false)
        #expect(RuntimeReadiness.operationalWithWarning(.configFallback).canRetryStartup == false)
        #expect(RuntimeReadiness.operationalWithWarning(.restoreRecovered(
            quarantinedFilenames: ["state.json.corrupt-test"]
        )).canRetryStartup == false)
        #expect(RuntimeReadiness.degraded(.activeSpaceUnavailable).canRetryStartup)
    }

    @Test("Readiness summaries are actionable and omit quarantine names")
    func summariesAreActionableAndPrivate() {
        let warning = RuntimeReadiness.operationalWithWarning(.restoreReset(
            quarantinedFilenames: ["state.json.corrupt-private"]
        ))

        #expect(warning.summary == "operational - invalid restore quarantined")
        #expect(warning.summary.contains("private") == false)
        #expect(RuntimeReadiness.operationalWithWarning(.configFallback).summary ==
            "operational - using built-in config")
        #expect(RuntimeReadiness.operationalWithWarning(.configReloadFailed).summary ==
            "operational - last config reload failed")
        #expect(RuntimeReadiness.degraded(.serviceStartupFailed(service: "hotkeys")).summary ==
            "degraded - hotkeys failed to start")
    }
}
