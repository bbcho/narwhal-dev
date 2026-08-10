import CoreGraphics
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("World actor layout history")
struct WorldActorHistoryTests {
    @Test("Workspace reconciliation state survives refresh, preserves history, and clears explicitly")
    func workspaceReconciliationStateIsIndependentOfHistory() async throws {
        let actor = WorldActor()
        let window = metadata(1)
        let environment = snapshot(windows: [window])
        _ = await actor.refreshEnvironment(environment)
        let push = try await actor.planPush(window.id, direction: .left).get()
        await actor.commit(push, appliedFrames: push.desiredLayout.delta.moves)
        let key = WorkspaceKey(displayID: DisplayID(raw: 1), spaceID: SpaceID(raw: 1))
        let issue = WorkspaceReconciliationIssue(
            operation: "Push Left",
            windowIDs: [window.id],
            reason: "rollback failed"
        )
        let historyBefore = await actor.layoutHistoryAvailability(spaceID: key.spaceID)

        await actor.recordWorkspaceReconciliationIssue(issue, for: key)
        _ = await actor.refreshEnvironment(environment)

        #expect(await actor.workspaceReconciliationIssue(for: key) == issue)
        #expect(await actor.layoutHistoryAvailability(spaceID: key.spaceID) == historyBefore)

        await actor.clearWorkspaceReconciliationIssue(for: key)
        #expect(await actor.workspaceReconciliationIssue(for: key) == nil)
        #expect(await actor.layoutHistoryAvailability(spaceID: key.spaceID) == historyBefore)
    }

    @Test("Workspace reconciliation state prunes when its workspace disappears")
    func workspaceReconciliationStatePrunesWithWorkspace() async {
        let actor = WorldActor()
        let window = metadata(1)
        _ = await actor.refreshEnvironment(snapshot(windows: [window]))
        let key = WorkspaceKey(displayID: DisplayID(raw: 1), spaceID: SpaceID(raw: 1))
        await actor.recordWorkspaceReconciliationIssue(
            WorkspaceReconciliationIssue(
                operation: "Balance",
                windowIDs: [window.id],
                reason: "rollback failed"
            ),
            for: key
        )

        _ = await actor.refreshEnvironment(EnvironmentSnapshot(
            activeSpace: nil,
            displays: [:],
            axSnapshot: AXWindowSnapshot(windows: [], quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [:],
                windowSpace: [:],
                quality: .managedDisplaySpaces
            )
        ))

        #expect(await actor.workspaceReconciliationIssue(for: key) == nil)
    }

    @Test("Successful commits create multi-step undo and redo transitions")
    func multiStepUndoRedo() async throws {
        let actor = WorldActor()
        let first = metadata(1)
        let second = metadata(2)
        _ = await actor.refreshEnvironment(snapshot(windows: [first, second]))

        let firstPush = try await actor.planPush(first.id, direction: .left).get()
        await actor.commit(firstPush, appliedFrames: firstPush.desiredLayout.delta.moves)
        let secondPush = try await actor.planPush(second.id, direction: .right).get()
        await actor.commit(secondPush, appliedFrames: secondPush.desiredLayout.delta.moves)

        let undoSecond = try #require(try await actor.planUndoLastLayout().get())
        #expect(undoSecond.historyAction == .undo(SpaceID(raw: 1)))
        await actor.commit(undoSecond, appliedFrames: undoSecond.desiredLayout.delta.moves)
        let undoFirst = try #require(try await actor.planUndoLastLayout().get())
        await actor.commit(undoFirst, appliedFrames: undoFirst.desiredLayout.delta.moves)
        #expect(try await actor.planUndoLastLayout().get() == nil)

        let redoFirst = try #require(try await actor.planRedoLastLayout().get())
        #expect(redoFirst.historyAction == .redo(SpaceID(raw: 1)))
        await actor.commit(redoFirst, appliedFrames: redoFirst.desiredLayout.delta.moves)
        let redoSecond = try #require(try await actor.planRedoLastLayout().get())
        await actor.commit(redoSecond, appliedFrames: redoSecond.desiredLayout.delta.moves)
        #expect(try await actor.planRedoLastLayout().get() == nil)
    }

    @Test("A planned command does not enter history until frame application commits")
    func failedApplyCreatesNoHistory() async throws {
        let actor = WorldActor()
        let window = metadata(1)
        _ = await actor.refreshEnvironment(snapshot(windows: [window]))

        _ = try await actor.planPush(window.id, direction: .left).get()

        #expect(try await actor.planUndoLastLayout().get() == nil)
    }

    @Test("A stale preview cannot replace a newer observed world")
    func stalePreviewIsRejectedAtCommit() async throws {
        let actor = WorldActor()
        let first = metadata(1)
        let second = metadata(2)
        _ = await actor.refreshEnvironment(snapshot(windows: [first, second]))
        let preview = try await actor.planPush(first.id, direction: .left).get()

        await actor.recordExternalFocus(second.id)

        #expect(!(await actor.isCurrent(preview)))
        #expect(!(await actor.commit(preview, appliedFrames: preview.desiredLayout.delta.moves)))
        #expect(try await actor.planUndoLastLayout().get() == nil)
    }

    @Test("Reset is an undoable Space transition instead of clearing history")
    func resetIsUndoable() async throws {
        let actor = WorldActor()
        let window = metadata(1)
        _ = await actor.refreshEnvironment(snapshot(windows: [window]))
        let push = try await actor.planPush(window.id, direction: .left).get()
        await actor.commit(push, appliedFrames: push.desiredLayout.delta.moves)

        let reset = try await actor.planResetLayoutMemory().get()
        guard case .record(let entry) = reset.historyAction else {
            Issue.record("Expected reset to record history")
            return
        }
        #expect(entry.label == "Reset")
        await actor.commit(reset, appliedFrames: reset.desiredLayout.delta.moves)

        let undoReset = try #require(try await actor.planUndoLastLayout().get())
        await actor.commit(undoReset, appliedFrames: undoReset.desiredLayout.delta.moves)
        #expect(try await actor.planEject(window.id).get().historyAction != .none)
    }

    @Test("Named layouts use the regular plan, commit, and history path")
    func namedLayoutPlanUsesCommitGate() async throws {
        let actor = WorldActor()
        let first = metadata(1)
        let second = metadata(2)
        _ = await actor.refreshEnvironment(snapshot(windows: [first, second]))
        let firstPush = try await actor.planPush(first.id, direction: .left).get()
        await actor.commit(firstPush, appliedFrames: firstPush.desiredLayout.delta.moves)
        let secondPush = try await actor.planPush(second.id, direction: .right).get()
        await actor.commit(secondPush, appliedFrames: secondPush.desiredLayout.delta.moves)
        let saved = try await actor.captureNamedLayout(
            id: NamedLayoutID(rawValue: "saved"),
            name: "Saved",
            revision: 1,
            spaceID: SpaceID(raw: 1),
            includeTitleHints: []
        ).get()
        let eject = try await actor.planEject(second.id).get()
        await actor.commit(eject, appliedFrames: eject.desiredLayout.delta.moves)

        let plan = try await actor.planNamedLayout(
            saved,
            spaceID: SpaceID(raw: 1),
            allowPartial: false
        ).get()

        guard case .record(let entry) = plan.historyAction else {
            Issue.record("Expected named layout history")
            return
        }
        #expect(entry.label == "Apply Saved")
        #expect(Set(plan.desiredLayout.layout.tiled.keys) == [first.id, second.id])
        await actor.commit(plan, appliedFrames: plan.desiredLayout.delta.moves)
        #expect(try await actor.planUndoLastLayout().get() != nil)
    }

    @Test("Reset and undo preserve another display's distinct active Space")
    func perSpaceResetPreservesOtherActiveSpace() async throws {
        let actor = WorldActor()
        let first = metadata(1)
        let second = WindowMetadata(
            id: WindowID(raw: 2),
            bundleID: BundleID(raw: "com.example.2"),
            title: "Window 2",
            role: "AXWindow",
            pid: 2,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            isResizable: true,
            isMinimized: false
        )
        _ = await actor.refreshEnvironment(dualSpaceSnapshot(first: first, second: second))
        let firstPush = try await actor.planPush(first.id, direction: .left).get()
        await actor.commit(firstPush, appliedFrames: firstPush.desiredLayout.delta.moves)
        let secondPush = try await actor.planPush(second.id, direction: .right).get()
        await actor.commit(secondPush, appliedFrames: secondPush.desiredLayout.delta.moves)
        let secondSpaceTree = secondPush.plannedWorld.spaces[SpaceID(raw: 2)]?.displays[DisplayID(raw: 2)]?.tree

        let reset = try await actor.planResetLayoutMemory().get()

        #expect(reset.plannedWorld.spaces[SpaceID(raw: 2)]?.displays[DisplayID(raw: 2)]?.tree == secondSpaceTree)
        #expect(reset.desiredLayout.layout.tiled[second.id] != nil)
        await actor.commit(reset, appliedFrames: reset.desiredLayout.delta.moves)
        let undo = try #require(try await actor.planUndoLastLayout().get())
        #expect(undo.desiredLayout.layout.tiled[second.id] != nil)
    }

    private func snapshot(windows: [WindowMetadata]) -> EnvironmentSnapshot {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 1)
        let display = DisplayInfo(
            id: displayID,
            slot: 0,
            fingerprint: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        return EnvironmentSnapshot(
            activeSpace: spaceID,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: windows, quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [displayID: spaceID],
                windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) }),
                quality: .managedDisplaySpaces
            )
        )
    }

    private func metadata(_ raw: UInt32) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.\(raw)"),
            title: "Window \(raw)",
            role: "AXWindow",
            pid: ProcessID(raw),
            frame: CGRect(x: CGFloat(raw - 1) * 500, y: 0, width: 500, height: 800),
            isResizable: true,
            isMinimized: false
        )
    }

    private func dualSpaceSnapshot(
        first: WindowMetadata,
        second: WindowMetadata
    ) -> EnvironmentSnapshot {
        let firstDisplay = DisplayID(raw: 1)
        let secondDisplay = DisplayID(raw: 2)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        return EnvironmentSnapshot(
            activeSpace: firstSpace,
            displays: [
                firstDisplay: DisplayInfo(
                    id: firstDisplay,
                    slot: 0,
                    fingerprint: nil,
                    frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                ),
                secondDisplay: DisplayInfo(
                    id: secondDisplay,
                    slot: 1,
                    fingerprint: nil,
                    frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
                    visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
                )
            ],
            axSnapshot: AXWindowSnapshot(windows: [first, second], quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [firstDisplay: firstSpace, secondDisplay: secondSpace],
                windowSpace: [first.id: firstSpace, second.id: secondSpace],
                quality: .managedDisplaySpaces
            )
        )
    }
}
