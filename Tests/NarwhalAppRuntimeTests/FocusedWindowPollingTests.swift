@testable import NarwhalAppRuntime
import Testing
import ApplicationServices
import Foundation
import NarwhalCore

@MainActor
enum FocusedUnavailablePollingVerification {
    static func verifyUnavailableFocusIsNotLoggedEveryPoll() -> (passed: Bool, message: String) {
        let logPath = "/tmp/narwhal-focused-unavailable-\(UUID().uuidString).log"
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        let reporter = StartupReporter(logPath: logPath)
        guard let focusedApplicationFailure = AXError(rawValue: -25212) else {
            return (false, "focused-unavailable polling could not construct AXError -25212")
        }
        let error = AXClientError.copyAttributeFailed(
            kAXFocusedApplicationAttribute,
            focusedApplicationFailure
        )
        var emitted: [AXEvent] = []
        var reconciled: [FocusedWindowSnapshot] = []
        let service = AXObserverService(
            focusedWindowSnapshot: { .failure(error) },
            windowSnapshot: { AXWindowSnapshot(windows: [], quality: .complete) },
            echoSuppressor: AXEchoSuppressor(),
            reporter: reporter,
            activeSpaceByDisplay: { _ in [:] },
            spaceChanged: {},
            reconcileFocusedWindow: { reconciled.append($0) },
            emit: { event, _ in emitted.append(event) }
        )

        service.start()
        service.pollFocusedWindowNow()
        service.pollFocusedWindowNow()
        service.pollFocusedWindowNow()
        service.stop()
        reporter.flush()

        guard emitted.isEmpty else {
            return (false, "focused-unavailable polling emitted unexpected AX events: \(emitted)")
        }
        guard reconciled.isEmpty else {
            return (false, "focused-unavailable polling reconciled an unavailable snapshot")
        }
        guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return (false, "focused-unavailable polling could not read log at \(logPath)")
        }

        let unavailableCount = log.components(separatedBy: "Focused-window snapshot unavailable;").count - 1
        guard unavailableCount == 1 else {
            return (
                false,
                "focused-unavailable polling logged \(unavailableCount) unavailable lines; expected exactly 1. log=\(log)"
            )
        }
        guard log.contains("AXFocusedApplication failed with AXError(rawValue: -25212)") else {
            return (false, "focused-unavailable polling log did not include the AXFocusedApplication failure: \(log)")
        }

        return (
            true,
            "focused-unavailable polling verified: repeated AXFocusedApplication -25212 failures produced one log line and no focus-border hide events"
        )
    }

    static func verifyStableFocusIsReconciledEveryPoll() -> (passed: Bool, message: String) {
        let stableLogPath = "/tmp/narwhal-stable-focus-polling-\(UUID().uuidString).log"
        let reporter = StartupReporter(logPath: stableLogPath)
        // The sink creates its file asynchronously; flush so deletion runs last.
        defer {
            reporter.flush()
            try? FileManager.default.removeItem(atPath: stableLogPath)
        }
        let snapshot = FocusedWindowSnapshot(
            id: WindowID(raw: 700),
            bundleID: BundleID(raw: "com.ben.narwhal.verifier"),
            processID: 700,
            title: "Stable focus",
            role: kAXWindowRole,
            subrole: kAXStandardWindowSubrole,
            frame: CGRect(x: 10, y: 20, width: 400, height: 300),
            isResizable: true,
            isMinimized: false,
            isFullscreen: false
        )
        var emitted: [AXEvent] = []
        var reconciled: [FocusedWindowSnapshot] = []
        let service = AXObserverService(
            focusedWindowSnapshot: { .success(snapshot) },
            windowSnapshot: { AXWindowSnapshot(windows: [], quality: .complete) },
            echoSuppressor: AXEchoSuppressor(),
            reporter: reporter,
            activeSpaceByDisplay: { _ in [:] },
            spaceChanged: {},
            reconcileFocusedWindow: { reconciled.append($0) },
            emit: { event, _ in emitted.append(event) }
        )

        service.start()
        service.pollFocusedWindowNow()
        service.pollFocusedWindowNow()
        service.pollFocusedWindowNow()
        service.stop()

        guard emitted == [.windowFocused(snapshot.id)] else {
            return (false, "stable focused-window polling emitted unexpected AX events: \(emitted)")
        }
        guard reconciled == [snapshot, snapshot, snapshot, snapshot] else {
            return (false, "stable focused-window polling reconciled \(reconciled.count) snapshots; expected 4")
        }
        return (true, "stable focused-window polling reconciled every snapshot without duplicate focus events")
    }
}

@MainActor
@Suite("Focused-window polling")
struct FocusedWindowPollingTests {
    @Test("Polling an unavailable focused window logs the failure once and reconciles nothing")
    func unavailableFocusIsNotReconciled() {
        let result = FocusedUnavailablePollingVerification.verifyUnavailableFocusIsNotLoggedEveryPoll()
        #expect(result.passed, Comment(rawValue: result.message))
    }

    @Test("Polling a stable focused window reconciles every snapshot without duplicate focus events")
    func stableFocusIsReconciledEveryPoll() {
        let result = FocusedUnavailablePollingVerification.verifyStableFocusIsReconciledEveryPoll()
        #expect(result.passed, Comment(rawValue: result.message))
    }
}
