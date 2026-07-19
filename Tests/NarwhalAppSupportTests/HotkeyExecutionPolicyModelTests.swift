import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Hotkey execution policy model")
struct HotkeyExecutionPolicyModelTests {
    @Test("Empty hotkey queue has no execution batch")
    func emptyQueueHasNoExecutionBatch() {
        #expect(nextHotkeyExecutionBatch(in: []) == nil)
    }

    @Test("Non-resize hotkeys execute one at a time")
    func nonResizeHotkeysExecuteOneAtATime() {
        let batch = nextHotkeyExecutionBatch(in: [.showCommands, .command(.resizeSplit(.right, delta: 0.1))])

        #expect(batch == HotkeyExecutionBatch(action: .showCommands, resizeDeltas: [], consumedCount: 1))
    }

    @Test("Consecutive resize hotkeys in one direction form one ordered batch")
    func consecutiveResizeHotkeysFormOneOrderedBatch() {
        let first = HotkeyAction.command(.resizeSplit(.right, delta: 0.1))
        let batch = nextHotkeyExecutionBatch(in: [
            first,
            .command(.resizeSplit(.right, delta: 0.2)),
            .command(.resizeSplit(.right, delta: -0.05)),
            .command(.resizeSplit(.left, delta: 0.3)),
            .showCommands
        ])

        #expect(batch == HotkeyExecutionBatch(
            action: first,
            resizeDeltas: [0.1, 0.2, -0.05],
            consumedCount: 3
        ))
    }

    @Test("Resize batches stop before a different command")
    func resizeBatchesStopBeforeDifferentCommand() {
        let first = HotkeyAction.command(.resizeSplit(.down, delta: 0.1))
        let batch = nextHotkeyExecutionBatch(in: [
            first,
            .command(.balance),
            .command(.resizeSplit(.down, delta: 0.2))
        ])

        #expect(batch == HotkeyExecutionBatch(action: first, resizeDeltas: [0.1], consumedCount: 1))
    }

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
