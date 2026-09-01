#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import Darwin
import Foundation
import NarwhalCore

enum FreshWindowIdentityExpectation: Equatable {
    case exact(WindowID)
    case uniqueToken
}

struct FreshWindowSelectionRequest {
    let identity: FreshWindowIdentityExpectation
    let protectedWindowIDs: Set<WindowID>
    let expectedBundleID: String
    let allowedPIDs: Set<pid_t>
    let requiredTitleSubstring: String
    let minimumSize: CGSize
}

enum FreshWindowSelectionFailure: Error, Equatable {
    case missing
    case ambiguous([WindowID])
}

func selectFreshWindow(
    request: FreshWindowSelectionRequest,
    candidates: [WindowMetadata]
) -> Result<WindowMetadata, FreshWindowSelectionFailure> {
    let eligible = candidates.filter { candidate in
        !request.protectedWindowIDs.contains(candidate.id)
            && candidate.bundleID.raw == request.expectedBundleID
            && request.allowedPIDs.contains(candidate.pid)
            && (request.requiredTitleSubstring.isEmpty
                || candidate.title.localizedCaseInsensitiveContains(request.requiredTitleSubstring))
            && candidate.isResizable
            && !candidate.isMinimized
            && candidate.frame.width >= request.minimumSize.width
            && candidate.frame.height >= request.minimumSize.height
    }
    switch request.identity {
    case .exact(let windowID):
        guard let match = eligible.first(where: { $0.id == windowID }) else {
            return .failure(.missing)
        }
        return .success(match)
    case .uniqueToken:
        let ordered = eligible.sorted { $0.id.raw < $1.id.raw }
        guard ordered.count == 1 else {
            return ordered.isEmpty
                ? .failure(.missing)
                : .failure(.ambiguous(ordered.map(\.id)))
        }
        return .success(ordered[0])
    }
}

@MainActor
enum RealAppLaunchSupport {
    static func launchTerminal(
        token: String,
        excluding excludedIDs: Set<WindowID>,
        using axClient: AXClient
    ) async throws -> RealAppOriginal {
        let preexisting = terminalWindows(using: axClient).map(\.id)
        let protectedIDs = Set(preexisting).union(excludedIDs)
        let output = try await runAppleScript(
            """
            tell application "Terminal"
                activate
                do script "printf '\\\\e]0;Narwhal Production Verifier \(token)\\\\a'; echo Narwhal production verifier \(token)"
                set custom title of front window to "Narwhal Production Verifier \(token)"
                return id of front window
            end tell
            """,
            failure: "Terminal verification window launch failed"
        )
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count == 1,
              let rawID = UInt32(lines[0].trimmingCharacters(in: .whitespaces)),
              rawID > 0
        else {
            throw RealAppWindowVerifierFailure("Terminal launch returned invalid window ID: \(output.debugDescription)")
        }
        let launchedWindowID = WindowID(raw: rawID)

        let deadline = Date().addingTimeInterval(14)
        var lastFailure: FreshWindowSelectionFailure = .missing
        var lastCandidates: [WindowMetadata] = []
        while Date() < deadline {
            let allowedPIDs = Set(
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
                    .map(\.processIdentifier)
            )
            let request = FreshWindowSelectionRequest(
                identity: .exact(launchedWindowID),
                protectedWindowIDs: protectedIDs,
                expectedBundleID: "com.apple.Terminal",
                allowedPIDs: allowedPIDs,
                requiredTitleSubstring: "",
                minimumSize: terminalSpec().minimumWindowSize
            )
            lastCandidates = terminalWindows(using: axClient)
            switch selectFreshWindow(request: request, candidates: lastCandidates) {
            case .success(let candidate)
                where LiveWindowServerVerification.frame(for: Int(candidate.id.raw)) != nil:
                return RealAppOriginal(
                    spec: terminalSpec(),
                    bundleID: candidate.bundleID.raw,
                    metadata: candidate,
                    frame: candidate.frame,
                    createdByVerifier: true
                )
            case .success:
                lastFailure = .missing
            case .failure(let failure):
                lastFailure = failure
            }
            await settleLiveVerifier(for: 0.2)
        }

        let created = terminalWindows(using: axClient).filter { !protectedIDs.contains($0.id) }
        for metadata in created {
            await closeBestEffort(RealAppOriginal(
                spec: terminalSpec(),
                bundleID: metadata.bundleID.raw,
                metadata: metadata,
                frame: metadata.frame,
                createdByVerifier: true
            ), using: axClient)
        }
        throw RealAppWindowVerifierFailure(
            "Terminal did not expose exact fresh AX/WindowServer window \(launchedWindowID.description) for token \(token); protected=\(protectedIDs) selection=\(lastFailure) candidates=\(lastCandidates)"
        )
    }

    static func currentMetadata(
        for tracked: RealAppOriginal,
        using axClient: AXClient
    ) throws -> WindowMetadata {
        guard let current = axClient.windowSnapshot().windows.first(where: { $0.id == tracked.metadata.id }) else {
            throw RealAppWindowVerifierFailure("tracked window \(tracked.metadata.id.description) disappeared")
        }
        return current
    }

    static func setFrame(
        _ tracked: RealAppOriginal,
        to target: CGRect,
        using axClient: AXClient,
        context: String
    ) async throws -> CGRect {
        let current = try currentMetadata(for: tracked, using: axClient)
        let actual: CGRect
        switch await axClient.setFrame(current, to: target) {
        case .converged(let frame), .constrained(let frame):
            actual = frame
        case .clamped(let frame, let observed):
            guard frameWriteApproximatelySettled(
                target: target,
                actual: frame,
                tolerance: Double(frameWriteSettleTolerance)
            ) else {
                throw RealAppWindowVerifierFailure(
                    "\(context) was clamped away from target: target=\(target) actual=\(frame) observed=\(observed)"
                )
            }
            actual = frame
        case .failed(let error):
            throw RealAppWindowVerifierFailure("\(context) AX frame write failed: \(error.description)")
        }
        guard actual.narwhalApproximatelyEquals(target, tolerance: frameWriteSettleTolerance) else {
            throw RealAppWindowVerifierFailure("\(context) missed target: target=\(target) actual=\(actual)")
        }
        return actual
    }

    static func cleanup(_ windows: [RealAppOriginal], using axClient: AXClient) async throws {
        for window in windows.reversed() {
            try await close(window, using: axClient)
        }
    }

    static func cleanupBestEffort(
        _ windows: [RealAppOriginal],
        using axClient: AXClient,
        context: String
    ) async {
        for window in windows.reversed() {
            do {
                try await close(window, using: axClient)
            } catch {
                print("\(context): failed to close \(window.metadata.id.description): \(error)")
            }
        }
    }

    private static func terminalWindows(using axClient: AXClient) -> [WindowMetadata] {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
                .map(\.processIdentifier)
        )
        return axClient.windowSnapshot().windows.filter {
            $0.bundleID.raw == "com.apple.Terminal" || pids.contains($0.pid)
        }
    }

    private static func close(_ tracked: RealAppOriginal, using axClient: AXClient) async throws {
        let windowID = tracked.metadata.id
        _ = try await runAppleScript(
            """
            tell application "Terminal"
                if exists window id \(windowID.raw) then
                    try
                        do script "exit" in selected tab of window id \(windowID.raw)
                    end try
                    delay 0.1
                    close (window id \(windowID.raw)) saving no
                end if
            end tell
            """,
            failure: "Terminal close failed for \(windowID.description)"
        )
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if LiveWindowServerVerification.frame(for: Int(windowID.raw)) == nil {
                return
            }
            await settleLiveVerifier(for: 0.05)
        }

        if let current = axClient.windowSnapshot().windows.first(where: { $0.id == windowID }),
           case .success = await axClient.closeWindow(current) {
            let fallbackDeadline = Date().addingTimeInterval(1.5)
            while Date() < fallbackDeadline {
                if LiveWindowServerVerification.frame(for: Int(windowID.raw)) == nil {
                    return
                }
                await settleLiveVerifier(for: 0.05)
            }
        }
        throw RealAppWindowVerifierFailure("Terminal window \(windowID.description) remained visible after cleanup")
    }

    private static func closeBestEffort(_ tracked: RealAppOriginal, using axClient: AXClient) async {
        try? await close(tracked, using: axClient)
    }

    private static func runAppleScript(_ source: String, failure: String) async throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline {
            await settleLiveVerifier(for: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning, Date() < grace {
                await settleLiveVerifier(for: 0.05)
            }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            let forced = Date().addingTimeInterval(1)
            while process.isRunning, Date() < forced {
                await settleLiveVerifier(for: 0.05)
            }
        }
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard !process.isRunning else {
            throw RealAppWindowVerifierFailure("\(failure) did not terminate pid=\(process.processIdentifier) stdout=\(stdout) stderr=\(stderr)")
        }
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure("\(failure) with status \(process.terminationStatus) stdout=\(stdout) stderr=\(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
