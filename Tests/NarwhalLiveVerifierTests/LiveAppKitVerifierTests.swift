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
    func commandOverlayLayout() {
        expectPassed(CommandOverlayVerification.verifyDefaultTwoColumnLayout())
    }

    @Test("Focus border radius and stacking")
    func focusBorderRadiusAndStacking() {
        expectPassed(FocusBorderVerification.verifyPerWindowCornerRadii())
    }

    @Test("Menubar icon")
    func menubarIcon() {
        expectPassed(MenubarIconVerification.verifyStatusItemUsesToolbarIcon())
    }

    @Test("Observation replay")
    func observationReplay() {
        expectPassed(ObservationReplayVerification.verifyPartialTopologyReplay())
    }

    @Test("Workspace scope")
    func workspaceScope() {
        expectPassed(WorkspaceScopeVerification.verifyFocusedCommandsStayOnOneDisplay())
    }

    @Test("Live multi-display workflow")
    func liveMultiDisplayWorkflow() {
        let result = LiveMultiDisplayVerification.verifyDisplayScopedPushAndCycle()
        if !result.passed,
           result.message.contains("requires at least two displays")
            || result.message.contains("requires two usable displays") {
            return
        }
        expectPassed(result)
    }

    @Test("Focused-unavailable polling")
    func focusedUnavailablePolling() {
        expectPassed(FocusedUnavailablePollingVerification.verifyUnavailableFocusIsNotLoggedEveryPoll())
    }

    @Test("Space focus recovery")
    func spaceFocusRecovery() {
        expectPassed(SpaceFocusRecoveryVerification.verifyWorkspaceFocusFallbackMovesOnlyActiveSpace())
    }

    @Test("Live Space switch focus border")
    func liveSpaceSwitchFocusBorder() {
        expectPassed(LiveSpaceSwitchFocusBorderVerification.verifyFocusBorderMovesAcrossRealSpaceSwitch())
    }

    @Test("Display-change focus border")
    func displayChangeFocusBorder() {
        expectPassed(DisplayChangeFocusBorderVerification.verifyDisplayChangePreservesVisibleFocusBorder())
    }

    @Test("Live focus workflow")
    func liveFocusWorkflow() {
        expectPassed(LiveFocusWorkflowVerification.verifyCycleMouseAndBorderWorkflow())
    }

    @Test("Live command workflows")
    func liveCommandWorkflows() {
        expectPassed(LiveCommandWorkflowVerification.verifyCommandWorkflows())
    }

    private func expectPassed(_ result: (passed: Bool, message: String)) {
        guard result.passed else {
            Issue.record(Comment(rawValue: result.message))
            return
        }
    }
}
#endif
