import Foundation
import Testing
@testable import NarwhalCore

@Suite("Runtime diagnostics")
struct RuntimeDiagnosticsTests {
    @Test("Diagnostics JSON round-trips without private window metadata")
    func diagnosticsJSONRoundTripsWithoutPrivateMetadata() throws {
        let diagnostics = fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(diagnostics)
        let json = String(decoding: data, as: UTF8.self)

        #expect(try JSONDecoder().decode(RuntimeDiagnostics.self, from: data) == diagnostics)
        #expect(!json.contains("Secret Project"))
        #expect(!json.contains("com.example.private-app"))
        #expect(!json.contains("/Users/ben/private-config.toml"))
    }

    @Test("Diagnostics expose a versioned stable operational shape")
    func diagnosticsHaveStableOperationalShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(fixture()), as: UTF8.self)

        #expect(json.contains(#""schemaVersion":1"#))
        #expect(json.contains(#""snapshotQuality":"complete""#))
        #expect(json.contains(#""metric":"window_snapshot""#))
        #expect(json.contains(#""activeSpaceID":37"#))
    }

    private func fixture() -> RuntimeDiagnostics {
        RuntimeDiagnostics(
            generatedAt: "2026-07-19T17:30:00Z",
            appVersion: "0.1.0",
            buildVersion: "1",
            accessibilityTrusted: true,
            notificationFastPathActive: true,
            configHealthy: true,
            paused: false,
            activeSpaceID: 37,
            displayCount: 2,
            windowCount: 5,
            tiledWindowCount: 3,
            snapshotQuality: .complete,
            focusedWindowID: 42,
            lastCommand: "Resize right",
            pendingHotkeyCount: 0,
            pendingGeometryEventCount: 1,
            droppedLogLineCount: 0,
            latency: [
                RuntimeMetricSummary(
                    metric: .windowSnapshot,
                    sampleCount: 4,
                    retainedSampleCount: 4,
                    latestMilliseconds: 3,
                    medianMilliseconds: 2,
                    p95Milliseconds: 5,
                    maximumMilliseconds: 5
                )
            ]
        )
    }
}
