#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import Foundation
import Testing

@MainActor
@Suite(
    "Live AppKit verifiers",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["NARWHAL_RUN_LIVE_VERIFIERS"] == "1",
        "Set NARWHAL_RUN_LIVE_VERIFIERS=1 to run live AppKit verification."
    )
)
struct LiveAppKitVerifierTests {
    @Test("Command overlay layout")
    func commandOverlayLayout() throws {
        // Force-init NSApp here (it's the first @Test alphabetically and by
        // source order) so subsequent heavy AppKit tests don't crash on the
        // `NSApp.setActivationPolicy` IUO unwrap.
        _ = NSApplication.shared
        try expectPassed(CommandOverlayVerification.verifyDefaultTwoColumnLayout())
    }

    @Test("Focus border radius and stacking")
    func focusBorderRadiusAndStacking() throws {
        try expectPassed(FocusBorderVerification.verifyPerWindowCornerRadii())
    }

    @Test("Menubar icon")
    func menubarIcon() throws {
        try expectPassed(MenubarIconVerification.verifyStatusItemUsesToolbarIcon())
    }

    @Test("Observation replay")
    func observationReplay() throws {
        try expectPassed(ObservationReplayVerification.verifyPartialTopologyReplay())
    }

    @Test("Workspace scope")
    func workspaceScope() throws {
        try expectPassed(WorkspaceScopeVerification.verifyFocusedCommandsStayOnOneDisplay())
    }

    @Test("Live multi-display workflow")
    func liveMultiDisplayWorkflow() throws {
        let result = LiveMultiDisplayVerification.verifyDisplayScopedPushAndCycle()
        if !result.passed,
           result.message.contains("requires at least two displays")
            || result.message.contains("requires two usable displays") {
            return
        }
        try expectPassed(result)
    }

    @Test("Focused-unavailable polling")
    func focusedUnavailablePolling() throws {
        try expectPassed(FocusedUnavailablePollingVerification.verifyUnavailableFocusIsNotLoggedEveryPoll())
    }

    @Test("Space focus recovery")
    func spaceFocusRecovery() throws {
        try expectPassed(SpaceFocusRecoveryVerification.verifyWorkspaceFocusFallbackMovesOnlyActiveSpace())
    }

    @Test("Live Space switch focus border")
    func liveSpaceSwitchFocusBorder() throws {
        try expectPassed(LiveSpaceSwitchFocusBorderVerification.verifyFocusBorderMovesAcrossRealSpaceSwitch())
    }

    @Test("Display-change focus border")
    func displayChangeFocusBorder() throws {
        try expectPassed(DisplayChangeFocusBorderVerification.verifyDisplayChangePreservesVisibleFocusBorder())
    }

    // Bundle the two heavy AppKit tests into a single @Test. Swift Testing's
    // main-actor drain prematurely exits the process if these run as separate
    // serialized tests at the tail of the suite (the framework calls exit()
    // from `main` after `swift_task_asyncMainDrainQueue` returns, before the
    // next test is scheduled). Running both verifications inside one Task
    // sidesteps that scheduler interaction — both run, both contribute to the
    // single test's pass/fail.
    @Test("Live focus + command workflows")
    func liveFocusAndCommandWorkflows() async throws {
        let focusResult = LiveFocusWorkflowVerification.verifyCycleMouseAndBorderWorkflow()
        let commandResult = LiveCommandWorkflowVerification.verifyCommandWorkflows()
        guard focusResult.passed else {
            throw LiveVerifierFailure("focus workflow failed: \(focusResult.message)")
        }
        guard commandResult.passed else {
            throw LiveVerifierFailure("command workflow failed: \(commandResult.message)")
        }
    }

    private func expectPassed(_ result: (passed: Bool, message: String)) throws {
        guard result.passed else {
            throw LiveVerifierFailure(result.message)
        }
    }
}

/// Returns true when macOS is at the login window or otherwise can't expose
/// user windows to AX (locked screen, screen saver, fast user switch). The
/// live verifier tests query AX state and create NSWindows that AX must be
/// able to see, so they have no chance of succeeding in this state. The
/// verifiers call this and gracefully skip when true rather than fail with
/// the cryptic "focused AX window could not be matched to a CGWindowID".
@MainActor
func isSystemLocked() -> Bool {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return true }
    let id = frontmost.bundleIdentifier ?? ""
    return id == "com.apple.loginwindow" || id == "com.apple.SecurityAgent"
}

private struct LiveVerifierFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
