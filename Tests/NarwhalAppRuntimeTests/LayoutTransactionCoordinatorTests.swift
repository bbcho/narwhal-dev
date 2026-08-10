import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Layout transaction coordinator")
struct LayoutTransactionCoordinatorTests {
    @Test("Successful frame application commits exactly one new history entry")
    func successCommitsOnce() async throws {
        let fixture = try await CoordinatorFixture.make()

        let outcome = await fixture.execute()

        guard case .committed(let commit) = outcome else {
            Issue.record("Expected committed transaction, got \(outcome)")
            return
        }
        #expect(commit.appliedFrames == fixture.targets)
        #expect(commit.focusUpdate == .target(
            windowID: fixture.first,
            frame: fixture.targets[fixture.first]!
        ))
        #expect(commit.affectedWorkspaces == [fixture.workspaceKey])
        #expect(await fixture.actor.layoutHistoryAvailability(
            spaceID: fixture.workspaceKey.spaceID
        ).undoLabel == "Resize right")
        let undo = try #require(try await fixture.actor.planUndoLastLayout().get())
        await fixture.actor.commit(undo, appliedFrames: undo.desiredLayout.delta.moves)
        #expect(await fixture.actor.layoutHistoryAvailability(
            spaceID: fixture.workspaceKey.spaceID
        ).undoLabel == "Push right")
    }

    @Test("A stale plan before effects performs zero frame writes")
    func staleBeforeEffectsWritesNothing() async throws {
        let fixture = try await CoordinatorFixture.make()
        await fixture.actor.recordObservedConstraints([
            fixture.first: WindowConstraints(minHeight: 1)
        ])

        let outcome = await fixture.execute()

        guard case .failed(_, let reason, _) = outcome else {
            Issue.record("Expected stale transaction failure, got \(outcome)")
            return
        }
        #expect(reason.contains("stale"))
        #expect(fixture.store.writes.isEmpty)
        #expect(fixture.store.frames == fixture.originals)
        #expect(await fixture.actor.layoutHistoryAvailability(
            spaceID: fixture.workspaceKey.spaceID
        ).undoLabel == "Push right")
    }

    @Test("World currency changing after effects restores every written frame")
    func staleAfterEffectsRollsBack() async throws {
        let fixture = try await CoordinatorFixture.make()
        fixture.store.onRead = { readCount in
            guard readCount == 5 else { return }
            await fixture.actor.recordObservedConstraints([
                fixture.first: WindowConstraints(minHeight: 1)
            ])
        }

        let outcome = await fixture.execute()

        guard case .failed(_, let reason, let restored) = outcome else {
            Issue.record("Expected restored stale transaction, got \(outcome)")
            return
        }
        #expect(reason.contains("stale"))
        #expect(restored == fixture.originals)
        #expect(fixture.store.frames == fixture.originals)
        #expect(fixture.store.writes.suffix(2).map(\.frame) == [
            fixture.originals[fixture.second]!,
            fixture.originals[fixture.first]!,
        ])
    }

    @Test("A constraint restores, replans, and commits one coherent layout")
    func constraintRestoresThenReplans() async throws {
        let fixture = try await CoordinatorFixture.make()
        fixture.store.clampWritesRemaining = 1
        var replans = 0
        var replannedConstraints: [WindowID: WindowConstraints] = [:]

        let outcome = await fixture.execute(replan: {
            replans += 1
            let result = await fixture.actor.planResize(
                fixture.first,
                direction: .right,
                delta: 0.1
            )
            if case .success(let plan) = result {
                replannedConstraints = plan.sourceWorld.windowConstraints
            }
            return result
        })

        guard case .committed = outcome else {
            Issue.record("Expected constraint retry to commit, got \(outcome)")
            return
        }
        #expect(replans == 1)
        #expect(replannedConstraints[fixture.first] != nil)
        #expect(await fixture.actor.layoutHistoryAvailability(
            spaceID: fixture.workspaceKey.spaceID
        ).undoLabel == "Resize right")
    }

    @Test("Constraint retries stop at the bounded attempt count")
    func constraintRetryExhaustion() async throws {
        let fixture = try await CoordinatorFixture.make()
        fixture.store.clampEveryForwardWrite = true
        var replans = 0

        let outcome = await fixture.execute(replan: {
            replans += 1
            return await fixture.forcedResizePlan(seam: 560 + CGFloat(replans * 20))
        })

        guard case .failed(_, let reason, _) = outcome else {
            Issue.record("Expected bounded constraint failure, got \(outcome)")
            return
        }
        #expect(reason.contains("constraint"))
        #expect(replans <= fixture.plan.desiredLayout.delta.moves.count)
        #expect(fixture.store.frames == fixture.originals)
        #expect(await fixture.actor.layoutHistoryAvailability(
            spaceID: fixture.workspaceKey.spaceID
        ).undoLabel == "Push right")
    }

    @Test("Incomplete rollback reconciles once and records a workspace issue")
    func rollbackFailureReconcilesOnce() async throws {
        let fixture = try await CoordinatorFixture.make()
        fixture.store.failForwardWindow = fixture.second
        fixture.store.failRollbackWindows = [fixture.first]
        var reconciliationCount = 0

        let outcome = await fixture.execute(reconcile: {
            reconciliationCount += 1
            return await fixture.refreshFromLiveFrames()
        })

        guard case .reconciliationRequired(let workspaces, let reason) = outcome else {
            Issue.record("Expected reconciliation-required result, got \(outcome)")
            return
        }
        #expect(workspaces == [fixture.workspaceKey])
        #expect(reason.contains("rollback"))
        #expect(reconciliationCount == 1)
        let issue = await fixture.actor.workspaceReconciliationIssue(for: fixture.workspaceKey)
        #expect(issue?.operation == "Resize Right")
        #expect(issue?.windowIDs == [fixture.first, fixture.second])
        #expect(issue?.reason.contains("rollback") == true)
        #expect(await fixture.actor.layoutHistoryAvailability(
            spaceID: fixture.workspaceKey.spaceID
        ).undoLabel == "Push right")
    }

    @Test("A failed transaction leaves another workspace's history unchanged")
    func unaffectedWorkspaceHistoryIsPreserved() async throws {
        let fixture = try await CoordinatorFixture.makeDualWorkspace()
        let otherHistory = await fixture.actor.layoutHistoryAvailability(spaceID: fixture.otherSpaceID!)
        fixture.store.failForwardWindow = fixture.second

        _ = await fixture.execute()

        #expect(await fixture.actor.layoutHistoryAvailability(
            spaceID: fixture.otherSpaceID!
        ) == otherHistory)
    }
}

private struct RecordedFrameWrite: Equatable {
    let windowID: WindowID
    let frame: CGRect
}

@MainActor
private final class CoordinatorFrameStore {
    let originals: [WindowID: CGRect]
    var frames: [WindowID: CGRect]
    var windowServerFrames: [WindowID: CGRect]
    var writes: [RecordedFrameWrite] = []
    var readCount = 0
    var clampWritesRemaining = 0
    var clampEveryForwardWrite = false
    var failForwardWindow: WindowID?
    var failRollbackWindows: Set<WindowID> = []
    var onRead: ((Int) async -> Void)?

    init(originals: [WindowID: CGRect]) {
        self.originals = originals
        frames = originals
        windowServerFrames = originals
    }

    func writer() -> WindowFrameWriter {
        WindowFrameWriter(
            writeAccessibility: { [weak self] window, target in
                guard let self else { return .failed(.windowElementNotFound(window.id)) }
                writes.append(RecordedFrameWrite(windowID: window.id, frame: target))
                let isRollback = target == originals[window.id]
                if isRollback, failRollbackWindows.contains(window.id) {
                    return .failed(.windowElementNotFound(window.id))
                }
                if !isRollback, failForwardWindow == window.id {
                    return .failed(.windowElementNotFound(window.id))
                }
                if !isRollback, clampEveryForwardWrite || clampWritesRemaining > 0 {
                    clampWritesRemaining = max(0, clampWritesRemaining - 1)
                    let actual = CGRect(
                        x: target.minX,
                        y: target.minY,
                        width: target.width + 10,
                        height: target.height
                    )
                    frames[window.id] = actual
                    windowServerFrames[window.id] = actual
                    return .clamped(
                        actual: actual,
                        observed: WindowConstraints(minWidth: Double(actual.width))
                    )
                }
                frames[window.id] = target
                windowServerFrames[window.id] = target
                return .converged(actual: target)
            },
            writeTerminal: { _, _ in .failure(.invalidFrame(.null)) },
            readback: { [weak self] window in
                guard let self,
                      let accessibility = frames[window.id],
                      let windowServer = windowServerFrames[window.id]
                else {
                    return .failure(.windowServerFrameUnavailable(window.id))
                }
                readCount += 1
                await onRead?(readCount)
                return .success(WindowFrameReadback(
                    accessibility: accessibility,
                    windowServer: windowServer
                ))
            }
        )
    }
}

@MainActor
private final class CoordinatorFixture {
    let actor: WorldActor
    let first: WindowID
    let second: WindowID
    let plan: CommandPlanResult
    let store: CoordinatorFrameStore
    let coordinator: LayoutTransactionCoordinator
    let workspaceKey: WorkspaceKey
    let otherSpaceID: SpaceID?

    var originals: [WindowID: CGRect] { store.originals }
    var targets: [WindowID: CGRect] {
        plan.desiredLayout.layout.tiled.mapValues(canonicalFrameWriteTarget)
    }

    static func make() async throws -> CoordinatorFixture {
        let actor = WorldActor()
        let first = metadata(1, x: 0)
        let second = metadata(2, x: 500)
        _ = await actor.refreshEnvironment(snapshot(windows: [first, second]))
        let firstPush = try await actor.planPush(first.id, direction: .left).get()
        await actor.commit(firstPush, appliedFrames: firstPush.desiredLayout.delta.moves)
        let secondPush = try await actor.planPush(second.id, direction: .right).get()
        await actor.commit(secondPush, appliedFrames: secondPush.desiredLayout.delta.moves)
        let plan = try await actor.planResize(first.id, direction: .right, delta: 0.1).get()
        return fixture(actor: actor, first: first.id, second: second.id, plan: plan)
    }

    static func makeDualWorkspace() async throws -> CoordinatorFixture {
        let actor = WorldActor()
        let first = metadata(1, x: 0)
        let second = metadata(2, x: 500)
        let other = metadata(3, x: 1_000)
        _ = await actor.refreshEnvironment(dualSnapshot(first: first, second: second, other: other))
        let firstPush = try await actor.planPush(first.id, direction: .left).get()
        await actor.commit(firstPush, appliedFrames: firstPush.desiredLayout.delta.moves)
        let secondPush = try await actor.planPush(second.id, direction: .right).get()
        await actor.commit(secondPush, appliedFrames: secondPush.desiredLayout.delta.moves)
        let otherPush = try await actor.planPush(other.id, direction: .left).get()
        await actor.commit(otherPush, appliedFrames: otherPush.desiredLayout.delta.moves)
        let plan = try await actor.planResize(first.id, direction: .right, delta: 0.1).get()
        return fixture(
            actor: actor,
            first: first.id,
            second: second.id,
            plan: plan,
            otherSpaceID: SpaceID(raw: 2)
        )
    }

    private static func fixture(
        actor: WorldActor,
        first: WindowID,
        second: WindowID,
        plan: CommandPlanResult,
        otherSpaceID: SpaceID? = nil
    ) -> CoordinatorFixture {
        let originals = plan.windows.mapValues(\.frame)
        let store = CoordinatorFrameStore(originals: originals)
        let reporter = StartupReporter(
            logPath: "/tmp/narwhal-layout-coordinator-\(UUID().uuidString).log"
        )
        let transaction = LayoutFrameTransaction(
            frameWriter: store.writer(),
            reporter: reporter
        )
        return CoordinatorFixture(
            actor: actor,
            first: first,
            second: second,
            plan: plan,
            store: store,
            coordinator: LayoutTransactionCoordinator(
                worldActor: actor,
                frameTransaction: transaction
            ),
            workspaceKey: WorkspaceKey(displayID: DisplayID(raw: 1), spaceID: SpaceID(raw: 1)),
            otherSpaceID: otherSpaceID
        )
    }

    init(
        actor: WorldActor,
        first: WindowID,
        second: WindowID,
        plan: CommandPlanResult,
        store: CoordinatorFrameStore,
        coordinator: LayoutTransactionCoordinator,
        workspaceKey: WorkspaceKey,
        otherSpaceID: SpaceID?
    ) {
        self.actor = actor
        self.first = first
        self.second = second
        self.plan = plan
        self.store = store
        self.coordinator = coordinator
        self.workspaceKey = workspaceKey
        self.otherSpaceID = otherSpaceID
    }

    func execute(
        replan: (() async -> Result<CommandPlanResult, CommandError>)? = nil,
        reconcile: (() async -> EnvironmentRefreshResult)? = nil
    ) async -> LayoutTransactionOutcome {
        await coordinator.execute(
            initialPlan: plan,
            operation: "Resize Right",
            retryOnConstraint: true,
            preserving: [:],
            replan: replan ?? { .failure(.activeSpaceUnavailable) },
            reconcileLiveWorld: reconcile ?? { await self.refreshFromLiveFrames() }
        )
    }

    func refreshFromLiveFrames() async -> EnvironmentRefreshResult {
        let windows = plan.windows.values.map { metadata in
            WindowMetadata(
                id: metadata.id,
                bundleID: metadata.bundleID,
                title: metadata.title,
                role: metadata.role,
                pid: metadata.pid,
                frame: store.frames[metadata.id] ?? metadata.frame,
                isResizable: metadata.isResizable,
                isMinimized: metadata.isMinimized
            )
        }
        return await actor.refreshEnvironment(Self.snapshot(windows: windows))
    }

    func forcedResizePlan(seam: CGFloat) async -> Result<CommandPlanResult, CommandError> {
        let baseResult = await actor.planResize(first, direction: .right, delta: 0.1)
        guard case .success(let base) = baseResult else { return baseResult }
        let frames = [
            first: CGRect(x: 0, y: 0, width: seam, height: 800),
            second: CGRect(x: seam, y: 0, width: 1_000 - seam, height: 800),
        ]
        return .success(CommandPlanResult(
            focusedWindowID: first,
            desiredLayout: DesiredLayout(
                generation: base.desiredLayout.generation,
                layout: Layout(tiled: frames, floatingZOrder: [], hidden: []),
                delta: LayoutDelta(moves: frames, raises: [], hides: [], shows: [])
            ),
            windows: base.windows,
            sourceWorld: base.sourceWorld,
            plannedWorld: base.plannedWorld,
            undoWorld: base.undoWorld,
            historyAction: base.historyAction
        ))
    }

    private static func metadata(_ raw: UInt32, x: CGFloat) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.\(raw)"),
            title: "Window \(raw)",
            role: "AXWindow",
            pid: ProcessID(raw),
            frame: CGRect(x: x, y: 0, width: 500, height: 800),
            isResizable: true,
            isMinimized: false
        )
    }

    private static func snapshot(windows: [WindowMetadata]) -> EnvironmentSnapshot {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        return EnvironmentSnapshot(
            activeSpace: space,
            displays: [display: displayInfo(display, slot: 0, x: 0)],
            axSnapshot: AXWindowSnapshot(windows: windows, quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [display: space],
                windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, space) }),
                quality: .managedDisplaySpaces
            )
        )
    }

    private static func dualSnapshot(
        first: WindowMetadata,
        second: WindowMetadata,
        other: WindowMetadata
    ) -> EnvironmentSnapshot {
        let firstDisplay = DisplayID(raw: 1)
        let secondDisplay = DisplayID(raw: 2)
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        return EnvironmentSnapshot(
            activeSpace: firstSpace,
            displays: [
                firstDisplay: displayInfo(firstDisplay, slot: 0, x: 0),
                secondDisplay: displayInfo(secondDisplay, slot: 1, x: 1_000),
            ],
            axSnapshot: AXWindowSnapshot(windows: [first, second, other], quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [firstDisplay: firstSpace, secondDisplay: secondSpace],
                windowSpace: [first.id: firstSpace, second.id: firstSpace, other.id: secondSpace],
                quality: .managedDisplaySpaces
            )
        )
    }

    private static func displayInfo(
        _ id: DisplayID,
        slot: Int,
        x: CGFloat
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: slot,
            fingerprint: nil,
            frame: CGRect(x: x, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: 1_000, height: 800)
        )
    }
}
