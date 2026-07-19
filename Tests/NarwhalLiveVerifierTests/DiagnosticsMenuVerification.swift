#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import Foundation
import NarwhalCore

@MainActor
enum DiagnosticsMenuVerification {
    static func verifyCopyDiagnosticsAction() -> (passed: Bool, message: String) {
        let pasteboard = NSPasteboard.withUniqueName()
        let diagnostics = diagnosticsFixture()
        let menubar = Menubar()
        var copyError: Error?
        menubar.start(
            reload: {},
            copyDiagnostics: {
                do {
                    try copyRuntimeDiagnostics(diagnostics, to: pasteboard)
                } catch {
                    copyError = error
                }
            },
            reset: {},
            quit: {}
        )
        defer {
            menubar.stop()
            pasteboard.releaseGlobally()
        }

        guard menubar.debugPerformMenuItem(titled: "Copy Diagnostics") else {
            return (false, "Copy Diagnostics menu item was missing or could not perform its action")
        }
        if let copyError {
            return (false, "Copy Diagnostics action failed: \(String(describing: copyError))")
        }
        guard let encoded = pasteboard.string(forType: .string),
              let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RuntimeDiagnostics.self, from: data)
        else {
            return (false, "Copy Diagnostics action did not write decodable JSON to the pasteboard")
        }
        guard decoded == diagnostics else {
            return (false, "Copy Diagnostics pasteboard JSON did not preserve the diagnostics value")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == approvedTopLevelKeys
        else {
            return (false, "Copy Diagnostics pasteboard JSON contained fields outside the approved schema")
        }

        return (true, "Copy Diagnostics menu action wrote privacy-safe JSON to an AppKit pasteboard")
    }

    private static func diagnosticsFixture() -> RuntimeDiagnostics {
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

    private static var approvedTopLevelKeys: Set<String> {
        [
            "schemaVersion", "generatedAt", "appVersion", "buildVersion",
            "accessibilityTrusted", "notificationFastPathActive", "configHealthy", "paused",
            "activeSpaceID", "displayCount", "windowCount", "tiledWindowCount",
            "snapshotQuality", "focusedWindowID", "lastCommand", "pendingHotkeyCount",
            "pendingGeometryEventCount", "droppedLogLineCount", "latency"
        ]
    }
}
#endif
