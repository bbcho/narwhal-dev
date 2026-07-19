import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Support bundle builder")
struct SupportBundleBuilderTests {
    @Test("Bundle contains only diagnostics and redacted bounded logs")
    func privacySafeArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-support-tests-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("narwhal.log")
        let archiveURL = root.appendingPathComponent("support.zip")
        let extractedURL = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"Focused bundle=com.secret.mail title="person@example.com" role=AXWindow path=/Users/person/private"#
            .write(to: logURL, atomically: true, encoding: .utf8)

        try SupportBundleBuilder(logURL: logURL).write(
            diagnostics: diagnosticsFixture(),
            to: archiveURL
        )
        try extract(archiveURL, to: extractedURL)

        let filenames = try FileManager.default.contentsOfDirectory(atPath: extractedURL.path).sorted()
        #expect(filenames == ["diagnostics.json", "narwhal.log"])
        let log = try String(
            contentsOf: extractedURL.appendingPathComponent("narwhal.log"),
            encoding: .utf8
        )
        #expect(log.contains("com.secret.mail") == false)
        #expect(log.contains("person@example.com") == false)
        #expect(log.contains("/Users/person") == false)
        #expect(log.contains("role=AXWindow"))
        _ = try JSONDecoder().decode(
            RuntimeDiagnostics.self,
            from: Data(contentsOf: extractedURL.appendingPathComponent("diagnostics.json"))
        )
    }

    private func extract(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func diagnosticsFixture() -> RuntimeDiagnostics {
        RuntimeDiagnostics(
            generatedAt: "2026-07-19T18:00:00Z",
            appVersion: "1.0.0",
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
