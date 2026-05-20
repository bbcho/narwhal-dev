import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Hotkey execution policy model")
struct HotkeyExecutionPolicyModelTests {
    @Test("Layout and focus commands wait for stable workspace topology")
    func layoutAndFocusCommandsWaitForStableWorkspaceTopology() {
        #expect(workspaceStabilityPolicy(for: .command(.push(.left))) == .waitForStableWorkspace)
        #expect(workspaceStabilityPolicy(for: .command(.focusCycle(.next))) == .waitForStableWorkspace)
        #expect(workspaceStabilityPolicy(for: .command(.focusDirection(.right))) == .waitForStableWorkspace)
    }

    @Test("Overlay, Finder, pause, and reset can run immediately")
    func nonLayoutCommandsRunImmediately() {
        #expect(workspaceStabilityPolicy(for: .showCommands) == .runImmediately)
        #expect(workspaceStabilityPolicy(for: .openFinderWindow) == .runImmediately)
        #expect(workspaceStabilityPolicy(for: .command(.togglePause)) == .runImmediately)
        #expect(workspaceStabilityPolicy(for: .command(.resetLayout)) == .runImmediately)
    }
}
