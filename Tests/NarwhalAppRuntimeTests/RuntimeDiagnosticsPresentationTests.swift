import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Runtime diagnostics presentation")
struct RuntimeDiagnosticsPresentationTests {
    @Test("Encoded diagnostics are pretty-printed and decodable")
    func encodedDiagnosticsArePrettyPrintedAndDecodable() throws {
        let encoded = try encodedRuntimeDiagnostics(diagnosticsFixture())
        let decoded = try JSONDecoder().decode(RuntimeDiagnostics.self, from: Data(encoded.utf8))

        #expect(decoded == diagnosticsFixture())
        #expect(encoded.hasPrefix("{\n  \"accessibilityTrusted\""))
    }

    private func diagnosticsFixture() -> RuntimeDiagnostics {
        RuntimeDiagnostics(
            generatedAt: "2026-07-19T18:00:00Z",
            appVersion: "0.1.0",
            buildVersion: "1",
            accessibilityTrusted: true,
            notificationFastPathActive: true,
            configHealthy: true,
            paused: false,
            activeSpaceID: 4,
            displayCount: 2,
            windowCount: 5,
            tiledWindowCount: 3,
            snapshotQuality: .complete,
            focusedWindowID: 42,
            lastCommand: "Resize right",
            pendingHotkeyCount: 0,
            pendingGeometryEventCount: 0,
            droppedLogLineCount: 0,
            latency: []
        )
    }
}
