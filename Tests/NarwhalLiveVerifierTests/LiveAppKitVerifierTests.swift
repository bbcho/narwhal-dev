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
    init() {
        _ = NSApplication.shared
    }

    @Test("Command overlay layout")
    func commandOverlayLayout() throws {
        try expectPassed(CommandOverlayVerification.verifyDefaultTwoColumnLayout())
    }

    @Test("Visual artifacts and pixel rules")
    func visualArtifactsAndPixelRules() throws {
        try expectPassed(VisualArtifactVerification.verifySavedArtifacts())
    }

    @Test("Focus border radius and stacking")
    func focusBorderRadiusAndStacking() throws {
        try expectPassed(FocusBorderVerification.verifyPerWindowCornerRadii())
    }

    @Test("Tiled border stale target suppression")
    func tiledBorderStaleTargetSuppression() throws {
        try expectPassed(FocusBorderVerification.verifyTiledBorderStaleTargetSuppression())
    }

    @Test("Menubar icon")
    func menubarIcon() throws {
        try expectPassed(MenubarIconVerification.verifyStatusItemUsesToolbarIcon())
    }

    @Test("Copy Diagnostics menu action")
    func copyDiagnosticsMenuAction() throws {
        try expectPassed(DiagnosticsMenuVerification.verifyCopyDiagnosticsAction())
    }

    @Test("Degraded runtime recovery menu")
    func degradedRuntimeRecoveryMenu() throws {
        try expectPassed(RecoveryMenuVerification.verifyDegradedRuntimeActions())
    }

    @Test("Support bundle save panel")
    func supportBundleSavePanel() throws {
        try expectPassed(SupportBundlePanelVerification.verifyConfiguration())
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
        try expectPassed(LiveMultiDisplayVerification.verifyDisplayScopedPushAndCycle())
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

    // Keep these workflows in one case because the main-actor test host can
    // terminate between separate serialized cases at the end of the suite.
    @Test("Live focus + command workflows")
    func liveFocusAndCommandWorkflows() async throws {
        let focusResult = await LiveFocusWorkflowVerification.verifyCycleMouseAndBorderWorkflow()
        let commandResult = await LiveCommandWorkflowVerification.verifyCommandWorkflows()
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

/// Returns true when the current session cannot expose user windows to AX.
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
