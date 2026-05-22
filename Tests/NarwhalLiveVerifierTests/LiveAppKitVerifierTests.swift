#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
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

    @Test("Live focus workflow")
    func liveFocusWorkflow() throws {
        try expectPassed(LiveFocusWorkflowVerification.verifyCycleMouseAndBorderWorkflow())
    }

    @Test("Live command workflows")
    func liveCommandWorkflows() throws {
        try expectPassed(LiveCommandWorkflowVerification.verifyCommandWorkflows())
    }

    private func expectPassed(_ result: (passed: Bool, message: String)) throws {
        guard result.passed else {
            throw LiveVerifierFailure(result.message)
        }
    }
}

private struct LiveVerifierFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
