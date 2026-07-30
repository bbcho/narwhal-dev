#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import ApplicationServices
import Foundation
import NarwhalCore

@MainActor
enum FocusedUnavailablePollingVerification {
    static func verifyUnavailableFocusIsNotLoggedEveryPoll() -> (passed: Bool, message: String) {
        let logPath = "/tmp/narwhal-focused-unavailable-\(UUID().uuidString).log"
        let reporter = StartupReporter(logPath: logPath)
        guard let focusedApplicationFailure = AXError(rawValue: -25212) else {
            return (false, "focused-unavailable polling could not construct AXError -25212")
        }
        let error = AXClientError.copyAttributeFailed(
            kAXFocusedApplicationAttribute,
            focusedApplicationFailure
        )
        var emitted: [AXEvent] = []
        let service = AXObserverService(
            focusedWindowSnapshot: { .failure(error) },
            windowSnapshot: { AXWindowSnapshot(windows: [], quality: .complete) },
            echoSuppressor: AXEchoSuppressor(),
            reporter: reporter,
            activeSpaceByDisplay: { _ in [:] },
            spaceChanged: {},
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
        guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return (false, "focused-unavailable polling could not read log at \(logPath)")
        }
        try? FileManager.default.removeItem(atPath: logPath)

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
}
#endif
