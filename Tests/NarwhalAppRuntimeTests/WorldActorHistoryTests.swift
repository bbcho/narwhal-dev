import CoreGraphics
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("World actor layout history")
struct WorldActorHistoryTests {
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
}
