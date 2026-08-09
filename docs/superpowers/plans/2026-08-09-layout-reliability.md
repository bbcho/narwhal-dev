# Narwhal Layout Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Narwhal layout mutation externally atomic, serialize reconciliation with commands, localize manual resize by visible geometry, and prove user-facing behavior through the production runtime.

**Architecture:** A geometry-first Core operation rebuilds BSP topology from the visible partition when manual seams move. A `LayoutFrameTransaction` supplies compensating rollback around sequential AX writes, while `LayoutTransactionCoordinator` owns currency, constraint retry, commit, and workspace-scoped reconciliation. One `WorkspaceMutationGate` serializes all `WorldActor` mutations, and production-path live verifiers drive the same runtime coordinators rather than duplicating them.

**Tech Stack:** Swift 6/macOS 26, Swift Testing, AppKit, Accessibility APIs, WindowServer/CGWindow inspection, Carbon hotkeys, CGEvent taps, SwiftPM shell smokes.

## Global Constraints

- Use xhigh planning, medium implementation, and low test-evaluation phases when the runner exposes effort controls; otherwise state that limitation and preserve the phase discipline.
- Run every test command with command-scoped `/usr/bin/caffeinate -dimsu`; `scripts/live_verify_all.sh` already caffeinates itself and must not receive a redundant wrapper.
- A skipped or zero-case live verifier is a failure.
- Real resize coverage must open Chrome, Firefox, System Settings, and Terminal and verify both AX and WindowServer frames.
- Do not narrow or remove a failing live scenario to make the suite pass.
- Write a failing test before each production behavior change and observe the expected failure.
- Commit every independently verified task with the scoped commit shown below.
- Preserve unrelated user changes and do not reset or rewrite existing history.

---

## File structure after implementation

### New production files

- `Sources/NarwhalCore/VisiblePartitionResize.swift` — render slot rectangles, move a visible seam, rebuild a deterministic guillotine BSP, and verify reconstructed geometry.
- `Sources/NarwhalAppRuntime/LayoutFrameTransaction.swift` — preflight snapshots, ordered writes, complete validation, reverse rollback, and structured external-effect outcomes.
- `Sources/NarwhalAppRuntime/LayoutTransactionCoordinator.swift` — plan currency, bounded constraint retry, `WorldActor` commit, and incomplete-rollback reconciliation.
- `Sources/NarwhalAppRuntime/WorkspaceMutationGate.swift` — single-owner serialization for every mutation of `WorldActor`.
- `Sources/NarwhalAppRuntime/ExternalGeometryCoordinator.swift` — latest-wins settle state and production manual-resize handoff.
- `Sources/NarwhalAppRuntime/LayoutPresentationCoordinator.swift` — transaction-scoped border visibility and final live-frame publication.
- `Tests/NarwhalLiveVerifierTests/RealAppLaunchSupport.swift` — tracked real-application launch and cleanup only.
- `Tests/NarwhalLiveVerifierTests/RealFrameAssertions.swift` — AX/WindowServer/gap/overlap assertions only.
- `Tests/NarwhalLiveVerifierTests/ProductionRuntimeHarness.swift` — production AppDelegate process, IPC, hotkey, event-tap, and log control only.
- `Tests/NarwhalLiveVerifierTests/ProductionManualResizeVerification.swift` — 2-by-2 and Chrome/Firefox production-observer scenarios.
- `Tests/NarwhalLiveVerifierTests/ProductionInputVerification.swift` — Carbon hotkey and modifier-drag production scenarios.

### Files deliberately reduced

- `Sources/NarwhalAppRuntime/App.swift` — lifecycle wiring, entry points, and user feedback; no transaction, retry, or external-geometry algorithm.
- `Sources/NarwhalAppRuntime/LayoutApplier.swift` — deterministic order, reflow, and geometry validation helpers only.
- `Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift` — scenario registration and app-specific cases; no copied apply/commit/retry state machine.

---

### Task 1: Rebuild external resize from the visible partition

**Files:**
- Create: `Sources/NarwhalCore/VisiblePartitionResize.swift`
- Modify: `Sources/NarwhalCore/TreeOperations.swift`
- Modify: `Sources/NarwhalCore/Apply.swift`
- Test: `Tests/NarwhalCoreTests/VisiblePartitionResizeTests.swift`
- Test: `Tests/NarwhalCoreTests/MVPLayoutTests.swift`

**Interfaces:**
- Produces:

```swift
public enum VisiblePartitionResizeError: Error, Equatable, Sendable {
    case windowNotFound(WindowID)
    case ambiguousChangedEdges
    case noVisibleNeighbor(Direction)
    case invalidPartition
    case nonGuillotinePartition
    case reconstructionMismatch
}

public func resizeVisibleSeamInTree(
    _ windowID: WindowID,
    from oldFrame: CGRect,
    to newFrame: CGRect,
    rootFrame: CGRect,
    innerGap: Double,
    _ tree: Node
) -> Result<Node, VisiblePartitionResizeError>
```

- `resizeSplitInTree` remains unchanged for keyboard resize semantics.
- `spacesByApplyingExternalResize` calls only `resizeVisibleSeamInTree` for manual geometry.

- [ ] **Step 1: Write failing 2-by-2 topology tests**

Create a column-root 2-by-2 fixture and assert that moving the bottom-left right edge changes only bottom-left and bottom-right, leaves both top frames exact, and reconstructs to a row-root tree. Add the mirrored top, right-to-left, and row-root cases.

```swift
@Test("Bottom seam resize rotates a column-shaped 2-by-2 tree without moving the top row")
func bottomSeamIsLocalAcrossHistoricalTopology() throws {
    let oldBottomLeft = frames[bottomLeft]!
    let requestedBottomLeft = CGRect(
        x: oldBottomLeft.minX,
        y: oldBottomLeft.minY,
        width: oldBottomLeft.width + 120,
        height: oldBottomLeft.height
    )
    let resized = try resizeVisibleSeamInTree(
        bottomLeft,
        from: oldBottomLeft,
        to: requestedBottomLeft,
        rootFrame: root,
        innerGap: 8,
        columnRootTree
    ).get()
    let actual = solvedFrames(resized, rootFrame: root, innerGap: 8)
    #expect(actual[topLeft] == frames[topLeft])
    #expect(actual[topRight] == frames[topRight])
    #expect(actual[bottomLeft]!.width == frames[bottomLeft]!.width + 120)
    #expect(actual[bottomRight]!.width == frames[bottomRight]!.width - 120)
}
```

- [ ] **Step 2: Run the focused test and observe the expected failure**

Run:

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalCoreTests.VisiblePartitionResizeTests
```

Expected: compilation or assertion failure because geometry-first seam reconstruction does not exist.

- [ ] **Step 3: Implement slot rendering and deterministic partition reconstruction**

Represent every occupied or empty slot with its original `NodePath`, `TreeSlotOccupancy`, and rendered cell frame. Move only the source and coincident visible neighbors. Recursively find full-span cuts; prefer the moved seam, then original grouping, then vertical-before-horizontal coordinate order. Derive weights from un-inset cell extents and materialize `.void` for empty slots.

- [ ] **Step 4: Verify reconstruction before returning**

Solve the rebuilt tree, compare every occupied and empty slot rectangle to the adjusted partition within `configuredGapTolerance`, and return `.reconstructionMismatch` rather than a best-effort tree.

- [ ] **Step 5: Route external geometry through the new operation**

Change `spacesByApplyingExternalResize` to call one geometry-first resize for the old/new frame pair. More than one changed edge returns no tree change so the caller records live geometry and detaches instead of changing an arbitrary ancestor.

- [ ] **Step 6: Run Core regression coverage**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalCoreTests.VisiblePartitionResizeTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalCoreTests.MVPLayoutTests
```

Expected: all tests pass; replace the old test that expected an ancestor resize to move an entire column with separate keyboard-resize and manual-visible-seam contracts.

- [ ] **Step 7: Commit**

```bash
git add Sources/NarwhalCore/VisiblePartitionResize.swift Sources/NarwhalCore/TreeOperations.swift Sources/NarwhalCore/Apply.swift Tests/NarwhalCoreTests/VisiblePartitionResizeTests.swift Tests/NarwhalCoreTests/MVPLayoutTests.swift
git commit -m "fix: localize manual resize to visible seams"
```

---

### Task 2: Make frame application compensating-transactional

**Files:**
- Create: `Sources/NarwhalAppRuntime/LayoutFrameTransaction.swift`
- Modify: `Sources/NarwhalAppRuntime/WindowFrameWriter.swift`
- Modify: `Sources/NarwhalAppRuntime/LayoutApplier.swift`
- Modify: `Sources/NarwhalAppSupport/LayoutApplyModel.swift`
- Test: `Tests/NarwhalAppRuntimeTests/LayoutFrameTransactionTests.swift`
- Test: `Tests/NarwhalAppRuntimeTests/WindowFrameWriterTests.swift`
- Test: `Tests/NarwhalAppSupportTests/LayoutApplyModelTests.swift`

**Interfaces:**
- Produces:

```swift
struct LayoutFrameTransactionFailure: Equatable, Sendable {
    let windowID: WindowID?
    let stage: Stage
    let message: String
    enum Stage: String, Equatable, Sendable { case preflight, apply, validate, currency, rollback }
}

enum LayoutFrameTransactionOutcome: Equatable, Sendable {
    case applied(originalFrames: [WindowID: CGRect], appliedFrames: [WindowID: CGRect])
    case constraintObserved(
        originalFrames: [WindowID: CGRect],
        observations: [WindowID: WindowConstraints],
        failure: LayoutFrameTransactionFailure
    )
    case rolledBack(originalFrames: [WindowID: CGRect], failure: LayoutFrameTransactionFailure)
    case reconciliationRequired(
        originalFrames: [WindowID: CGRect],
        liveFrames: [WindowID: CGRect],
        failure: LayoutFrameTransactionFailure,
        rollbackFailures: [LayoutFrameTransactionFailure]
    )
}

@MainActor
struct LayoutFrameTransaction {
    func execute(
        _ plan: CommandPlanResult,
        preserving preservedFrames: [WindowID: CGRect] = [:],
        isCurrent: @MainActor () async -> Bool
    ) async -> LayoutFrameTransactionOutcome
}
```

- `WindowFrameWriter` gains `readFrame(_:) async -> Result<WindowFrameReadback, AXClientError>`.
- `LayoutApplier` exports deterministic ordered targets and complete-layout validation but no longer makes a partial prefix a final decision.

- [ ] **Step 1: Write failing rollback tests**

Cover failure on write two, failure on final validation, new constraint on write two, rollback failure, missing preflight readback, and stale currency before/after effects. Assert reverse rollback order and both AX/WindowServer restoration.

```swift
@Test("Failure on the second write restores the first window before returning")
func secondWriteFailureRollsBackFirst() async throws {
    let outcome = await fixture(failForwardWrite: second).transaction.execute(plan) { true }
    #expect(outcome == .rolledBack(originalFrames: originals, failure: expectedFailure))
    #expect(fixture.writes == [
        .forward(first, targets[first]!),
        .forward(second, targets[second]!),
        .rollback(first, originals[first]!)
    ])
}
```

- [ ] **Step 2: Run the focused test and observe failure**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutFrameTransactionTests
```

Expected: compilation failure because `LayoutFrameTransaction` is absent.

- [ ] **Step 3: Add readback preflight and transaction execution**

Capture originals for every moving non-preserved window before the first write. Skip a forward write only when both original AX and WindowServer frames already match the canonical target. After all writes, validate every tiled frame, gaps, and overlap.

- [ ] **Step 4: Add reverse rollback with validation**

Restore all windows whose observed frame differs from their original, in reverse forward-write order. A rollback counts as successful only when AX and WindowServer both match the original.

- [ ] **Step 5: Remove partial-success semantics from AppSupport**

Delete `PlannedLayoutApplyDecision.fail(appliedFrames:)` and `.clamp(appliedFrames:)`. Preserve failure summaries and bounded distinct constraint observations, but make restoration an invariant of the runtime transaction rather than recording the prefix.

- [ ] **Step 6: Run focused runtime/support tests**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutFrameTransactionTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.WindowFrameWriterTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.LayoutApplyModelTests
```

- [ ] **Step 7: Commit**

```bash
git add Sources/NarwhalAppRuntime/LayoutFrameTransaction.swift Sources/NarwhalAppRuntime/WindowFrameWriter.swift Sources/NarwhalAppRuntime/LayoutApplier.swift Sources/NarwhalAppSupport/LayoutApplyModel.swift Tests/NarwhalAppRuntimeTests/LayoutFrameTransactionTests.swift Tests/NarwhalAppRuntimeTests/WindowFrameWriterTests.swift Tests/NarwhalAppSupportTests/LayoutApplyModelTests.swift
git commit -m "fix: roll back incomplete layout writes"
```

---

### Task 3: Track workspace-scoped reconciliation truth

**Files:**
- Modify: `Sources/NarwhalAppSupport/WorldRuntimeModel.swift`
- Modify: `Sources/NarwhalAppSupport/WorkspacePresentationModel.swift`
- Modify: `Sources/NarwhalAppRuntime/WorldActor.swift`
- Modify: `Sources/NarwhalAppRuntime/WorkspaceOverviewPopoverController.swift`
- Modify: `Sources/NarwhalAppRuntime/LayoutWorkbenchController.swift`
- Test: `Tests/NarwhalAppSupportTests/WorldRuntimeModelTests.swift`
- Test: `Tests/NarwhalAppSupportTests/WorkspacePresentationModelTests.swift`
- Test: `Tests/NarwhalAppRuntimeTests/WorldActorHistoryTests.swift`

**Interfaces:**

```swift
public struct WorkspaceReconciliationIssue: Equatable, Sendable {
    public let operation: String
    public let windowIDs: [WindowID]
    public let reason: String
}

public enum WorkspaceHealth: Equatable, Sendable {
    // existing cases
    case reconciliationRequired(WorkspaceReconciliationIssue)
}
```

`WorldRuntimeState` gains `workspaceReconciliationIssues`, and `WorldActor` gains `recordWorkspaceReconciliationIssue`, `clearWorkspaceReconciliationIssue`, and `workspaceReconciliationIssue`.

- [ ] **Step 1: Write failing state and presentation tests**

Assert that an issue is scoped to one `WorkspaceKey`, does not alter history, prunes when the workspace disappears, renders “Reconciliation required,” and leaves another display/Space healthy.

- [ ] **Step 2: Observe focused test failures**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.WorldRuntimeModelTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.WorkspacePresentationModelTests
```

- [ ] **Step 3: Implement runtime state and WorldActor operations**

Keep the issue session-only. Do not add it to `StoredWorld`. Complete environment reconciliation clears it only through an explicit actor method after the caller verifies live layout consistency.

- [ ] **Step 4: Render recovery state**

Use existing refresh/reset actions. Do not add a modal alert or global paused state.

- [ ] **Step 5: Run focused tests and commit**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.WorldRuntimeModelTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.WorkspacePresentationModelTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.WorldActorHistoryTests
git add Sources/NarwhalAppSupport/WorldRuntimeModel.swift Sources/NarwhalAppSupport/WorkspacePresentationModel.swift Sources/NarwhalAppRuntime/WorldActor.swift Sources/NarwhalAppRuntime/WorkspaceOverviewPopoverController.swift Sources/NarwhalAppRuntime/LayoutWorkbenchController.swift Tests/NarwhalAppSupportTests/WorldRuntimeModelTests.swift Tests/NarwhalAppSupportTests/WorkspacePresentationModelTests.swift Tests/NarwhalAppRuntimeTests/WorldActorHistoryTests.swift
git commit -m "feat: scope reconciliation failures to workspaces"
```

---

### Task 4: Centralize plan, effect, retry, and commit

**Files:**
- Create: `Sources/NarwhalAppRuntime/LayoutTransactionCoordinator.swift`
- Modify: `Sources/NarwhalAppRuntime/WorldActor.swift`
- Test: `Tests/NarwhalAppRuntimeTests/LayoutTransactionCoordinatorTests.swift`

**Interfaces:**

```swift
struct LayoutTransactionCommit: Equatable, Sendable {
    let appliedFrames: [WindowID: CGRect]
    let focusUpdate: PlannedLayoutFocusUpdate?
    let affectedWorkspaces: Set<WorkspaceKey>
}

enum LayoutTransactionOutcome: Equatable, Sendable {
    case committed(LayoutTransactionCommit)
    case failed(operation: String, reason: String, restoredFrames: [WindowID: CGRect])
    case reconciliationRequired(workspaces: Set<WorkspaceKey>, reason: String)
}

@MainActor
final class LayoutTransactionCoordinator {
    func execute(
        initialPlan: CommandPlanResult,
        operation: String,
        retryOnConstraint: Bool,
        preserving: [WindowID: CGRect],
        replan: @escaping @MainActor () async -> Result<CommandPlanResult, CommandError>,
        reconcileLiveWorld: @escaping @MainActor () async -> EnvironmentRefreshResult
    ) async -> LayoutTransactionOutcome
}
```

- [ ] **Step 1: Write failing coordinator tests**

Cover successful one-history commit, stale-before-effect rejection with zero writes, stale-after-effect rollback, constraint restore/replan/commit, retry exhaustion, rollback failure live reconciliation, and unaffected-workspace history preservation.

- [ ] **Step 2: Observe failure**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutTransactionCoordinatorTests
```

- [ ] **Step 3: Implement the coordinator state machine**

Never call `recordAppliedFrames` for failure or constraint paths. Record constraints only after rollback succeeds. On incomplete rollback, refresh live state once, record the affected workspace issue, and return `.reconciliationRequired`.

- [ ] **Step 4: Make successful commit consume verified frames only**

Retain `WorldActor.commit` currency checking, but call it only after `LayoutFrameTransaction.applied`. If the final currency check fails, request transaction rollback rather than refreshing after visible effects.

- [ ] **Step 5: Run and commit**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutTransactionCoordinatorTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.WorldActorHistoryTests
git add Sources/NarwhalAppRuntime/LayoutTransactionCoordinator.swift Sources/NarwhalAppRuntime/WorldActor.swift Tests/NarwhalAppRuntimeTests/LayoutTransactionCoordinatorTests.swift Tests/NarwhalAppRuntimeTests/WorldActorHistoryTests.swift
git commit -m "refactor: centralize layout transaction commits"
```

---

### Task 5: Serialize every world mutation

**Files:**
- Create: `Sources/NarwhalAppRuntime/WorkspaceMutationGate.swift`
- Delete: `Sources/NarwhalAppRuntime/MainActorCommandExecutionGate.swift`
- Modify: `Sources/NarwhalAppRuntime/App.swift`
- Test: `Tests/NarwhalAppRuntimeTests/WorkspaceMutationGateTests.swift`
- Delete: `Tests/NarwhalAppRuntimeTests/MainActorCommandExecutionGateTests.swift`

**Interfaces:**

```swift
@MainActor
final class WorkspaceMutationGate {
    func perform<Value>(_ operation: @MainActor () async -> Value) async -> Value
    var isExecutingForVerification: Bool { get }
}
```

- [ ] **Step 1: Write the failing refresh-interleaving test**

Hold the first operation on a continuation, schedule a refresh mutation and another command, and assert neither starts until release; then assert FIFO order.

```swift
@Test("A refresh cannot mutate world state during a suspended frame transaction")
func refreshWaitsForTransaction() async {
    // Expected order: transaction-start, transaction-end, refresh, command.
}
```

- [ ] **Step 2: Observe the failure against current App behavior**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.WorkspaceMutationGateTests
```

- [ ] **Step 3: Rename the gate and route all mutation entry points through it**

Add `refreshEnvironmentLocked`, `runCoalescedEnvironmentRefreshLocked`, `applyPendingTileRulesLocked`, `applySettledDisplayLayoutLocked`, and `applyStartupConvergeLocked`. Public timer/observer/IPC/hotkey/drag entry points acquire the gate once. Audit every `worldActor` mutating call with `rg -n "worldActor\\.(refresh|commit|record|remove|reload|restore|set|upsert)" Sources/NarwhalAppRuntime`.

- [ ] **Step 4: Ensure fresh snapshots are captured after gate acquisition**

Coalescers retain reasons/generations only. Do not retain AX/display snapshots across a wait.

- [ ] **Step 5: Run startup and gate coverage**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.WorkspaceMutationGateTests
/usr/bin/caffeinate -dimsu scripts/smoke_startup_shutdown.sh
/usr/bin/caffeinate -dimsu scripts/smoke_startup_failure_matrix.sh
```

- [ ] **Step 6: Commit**

```bash
git add Sources/NarwhalAppRuntime/WorkspaceMutationGate.swift Sources/NarwhalAppRuntime/MainActorCommandExecutionGate.swift Sources/NarwhalAppRuntime/App.swift Tests/NarwhalAppRuntimeTests/WorkspaceMutationGateTests.swift Tests/NarwhalAppRuntimeTests/MainActorCommandExecutionGateTests.swift
git commit -m "fix: serialize reconciliation with layout commands"
```

---

### Task 6: Integrate transactions and publish borders from verified frames

**Files:**
- Create: `Sources/NarwhalAppRuntime/LayoutPresentationCoordinator.swift`
- Modify: `Sources/NarwhalAppRuntime/App.swift`
- Modify: `Sources/NarwhalAppRuntime/AppDelegateSupport.swift`
- Modify: `Sources/NarwhalAppSupport/OverlayModel.swift`
- Test: `Tests/NarwhalAppRuntimeTests/LayoutPresentationCoordinatorTests.swift`
- Test: `Tests/NarwhalAppRuntimeTests/LayoutTransactionRoutingTests.swift`
- Test: `Tests/NarwhalAppSupportTests/OverlayModelTests.swift`

**Interfaces:**

```swift
@MainActor
final class LayoutPresentationCoordinator {
    func begin(affectedWindowIDs: Set<WindowID>, source: FocusBorderTarget?)
    func committed(_ commit: LayoutTransactionCommit, windows: [WindowID: WindowMetadata])
    func rolledBack(frames: [WindowID: CGRect], windows: [WindowID: WindowMetadata])
    func reconciliationRequired(affectedWindowIDs: Set<WindowID>)
}
```

- [ ] **Step 1: Write failing presentation tests**

Assert that only affected tiled borders hide at start, focus uses the current live source frame, commit publishes verified frames, rollback restores original frames, and reconciliation keeps affected tiled borders absent.

- [ ] **Step 2: Observe failure**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutPresentationCoordinatorTests
```

- [ ] **Step 3: Replace the central interactive apply path**

Replace `applyPlannedLayout` internals with `LayoutTransactionCoordinator.execute`. Publish exactly one terminal outcome, persist only commits, and never call `recordAppliedFrames` on failure. Because push, drop, center, eject, float, swap, keyboard resize, move display, shuffle, cascade, max reset, undo, redo, and Workbench already converge on this function, retain their thin planning wrappers and add table-driven routing tests that assert each operation reaches one transaction with its exact operation label, retry policy, preservation set, and focus update.

- [ ] **Step 4: Run and commit the interactive transaction path**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutPresentationCoordinatorTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutTransactionRoutingTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.OverlayModelTests
/usr/bin/caffeinate -dimsu scripts/smoke_config_hot_reload.sh
/usr/bin/caffeinate -dimsu scripts/smoke_startup_shutdown.sh
git add Sources/NarwhalAppRuntime/LayoutPresentationCoordinator.swift Sources/NarwhalAppRuntime/App.swift Sources/NarwhalAppRuntime/AppDelegateSupport.swift Sources/NarwhalAppSupport/OverlayModel.swift Tests/NarwhalAppRuntimeTests/LayoutPresentationCoordinatorTests.swift Tests/NarwhalAppRuntimeTests/LayoutTransactionRoutingTests.swift Tests/NarwhalAppSupportTests/OverlayModelTests.swift
git commit -m "refactor: publish interactive layout transactions"
```

- [ ] **Step 5: Remove remaining background apply bypasses**

Route startup convergence, pending open rules, resume/config rule activation, undo/redo convergence, and restore convergence through the same coordinator. Manual external geometry and display notification reflow remain isolated until Tasks 7 and 12 supply their production-observer tests. Add failure-injection cases proving startup/rule paths roll back without history or restore persistence and an App-source assertion that no direct `layoutApplier.apply` call remains.

- [ ] **Step 6: Run and commit the background transaction path**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutTransactionRoutingTests
/usr/bin/caffeinate -dimsu scripts/smoke_startup_shutdown.sh
/usr/bin/caffeinate -dimsu scripts/smoke_startup_failure_matrix.sh
rg -n "layoutApplier\.apply" Sources/NarwhalAppRuntime/App.swift
```

Expected: tests and smokes pass; the final `rg` exits 1 with no direct apply bypasses.

```bash
git add Sources/NarwhalAppRuntime/App.swift Tests/NarwhalAppRuntimeTests/LayoutTransactionRoutingTests.swift
git commit -m "fix: transact background layout convergence"
```

---

### Task 7: Collapse manual-resize bursts before sibling writes

**Files:**
- Create: `Sources/NarwhalAppRuntime/ExternalGeometryCoordinator.swift`
- Modify: `Sources/NarwhalAppSupport/ExternalGeometryEventModel.swift`
- Modify: `Sources/NarwhalAppRuntime/AXObserverService.swift`
- Modify: `Sources/NarwhalAppRuntime/App.swift`
- Modify: `Sources/NarwhalCore/RuntimeDiagnostics.swift`
- Modify: `Sources/NarwhalAppRuntime/RuntimeMetrics.swift`
- Test: `Tests/NarwhalAppSupportTests/ExternalGeometryEventModelTests.swift`
- Test: `Tests/NarwhalAppRuntimeTests/ExternalGeometryCoordinatorTests.swift`
- Test: `Tests/NarwhalAppSupportTests/RuntimeMetricsModelTests.swift`

**Interfaces:**

```swift
@MainActor
final class ExternalGeometryCoordinator {
    static let settleInterval: TimeInterval = 0.120
    func observe(_ event: AXEvent, snapshot: FocusedWindowSnapshot?)
    func cancel(windowID: WindowID)
    func cancelAll()
}
```

- [ ] **Step 1: Write failing latest-wins tests**

Send 30 resize notifications for one window, fire the settle timer, and assert one handoff with the last live frame, one inventory snapshot, and no source-window write. Cover a newer event arriving while the sibling transaction is suspended.

- [ ] **Step 2: Observe failure**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.ExternalGeometryCoordinatorTests
```

- [ ] **Step 3: Implement trailing settle and transaction handoff**

AXObserver may continue polling at its existing throttle, but `emit` only updates the coordinator's latest slot. The coordinator acquires `WorkspaceMutationGate` after 120 ms of quiet, captures one complete live snapshot, anchors the source, and invokes `LayoutTransactionCoordinator`.

- [ ] **Step 4: Add count-based performance assertions and metrics**

Add runtime metric cases `layoutTransaction`, `layoutRollback`, and `workspaceReconciliation`. Tests assert one snapshot and the minimal sibling write set; live tests retain the 800 ms post-settle deadline.

- [ ] **Step 5: Run and commit**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.ExternalGeometryCoordinatorTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.ExternalGeometryEventModelTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppSupportTests.RuntimeMetricsModelTests
git add Sources/NarwhalAppRuntime/ExternalGeometryCoordinator.swift Sources/NarwhalAppSupport/ExternalGeometryEventModel.swift Sources/NarwhalAppRuntime/AXObserverService.swift Sources/NarwhalAppRuntime/App.swift Sources/NarwhalCore/RuntimeDiagnostics.swift Sources/NarwhalAppRuntime/RuntimeMetrics.swift Tests/NarwhalAppSupportTests/ExternalGeometryEventModelTests.swift Tests/NarwhalAppRuntimeTests/ExternalGeometryCoordinatorTests.swift Tests/NarwhalAppSupportTests/RuntimeMetricsModelTests.swift
git commit -m "perf: settle manual resize before reflow"
```

---

### Task 8: Make visual verification strict

**Files:**
- Modify: `Tests/NarwhalLiveVerifierTests/LiveFocusWorkflowVerification.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/LiveWindowServerVerification.swift`
- Modify: `Sources/NarwhalAppRuntime/OverlayVerification.swift`
- Test: `Tests/NarwhalLiveVerifierTests/LiveAppKitVerifierTests.swift`

- [ ] **Step 1: Add a failing negative-control test**

Add `missingWindowServerBorderFailsVerification`. Give the focus-border helper an impossible WindowServer number and assert it throws `LiveFocusWorkflowFailure` instead of returning success.

- [ ] **Step 2: Run the focused live AppKit case and observe failure**

```bash
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LIVE_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.LiveAppKitVerifierTests.missingWindowServerBorderFailsVerification
```

Expected: the negative control fails because the current helper silently returns success when no WindowServer border surface can be resolved.

- [ ] **Step 3: Replace the permissive return with a diagnostic failure**

The error must include target window number, proposed border number, expected frame, and current front-to-back numbers. Search the live verifier for other assertion helpers that return on missing evidence and make optional behavior explicit in their names.

- [ ] **Step 4: Run AppKit visual coverage**

```bash
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LIVE_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.LiveAppKitVerifierTests
```

Expected: real sheet/dialog focus, parent/tiled-border occlusion, AppKit geometry, pixel artifacts, and WindowServer ordering all pass without skips.

- [ ] **Step 5: Commit**

```bash
git add Tests/NarwhalLiveVerifierTests/LiveFocusWorkflowVerification.swift Tests/NarwhalLiveVerifierTests/LiveWindowServerVerification.swift Sources/NarwhalAppRuntime/OverlayVerification.swift Tests/NarwhalLiveVerifierTests/LiveAppKitVerifierTests.swift
git commit -m "test: require visible WindowServer borders"
```

---

### Task 9: Replace “first successful” tests with exact command contracts

**Files:**
- Modify: `Tests/NarwhalCoreTests/CommandWorkflowMatrixTests.swift`
- Modify: `Tests/NarwhalCoreTests/MVPLayoutTests.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/LiveCommandWorkflowVerification.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift`

- [ ] **Step 1: Write exact expected-frame tables**

For canonical 1–8-window trees, specify valid/invalid directions, exact changed window IDs, unchanged window IDs, expected frame relationships, and history effect for swap and keyboard resize. Preserve existing exact push-sequence tables.

- [ ] **Step 2: Prove the current suite still contains permissive selection**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalCoreTests.CommandWorkflowMatrixTests
rg -n "commandSucceeds|verifyFirstSuccessfulTreeCommand|applyFirstSuccessfulWorkflowCommand" Tests
```

Expected: any genuine semantic mismatch fails an exact table assertion, and the source audit definitely finds the permissive helpers. The task remains red until those helpers are absent even if current production semantics happen to satisfy every new exact table row.

- [ ] **Step 3: Delete permissive selection helpers**

Remove `commandSucceeds`, `verifyFirstSuccessfulTreeCommand`, and `applyFirstSuccessfulWorkflowCommand`. A scenario chooses its requested direction before invoking the model and fails if that direction is invalid or changes the wrong windows.

- [ ] **Step 4: Run Core and AppKit command coverage**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalCoreTests.CommandWorkflowMatrixTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalCoreTests.MVPLayoutTests
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LIVE_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.LiveAppKitVerifierTests.liveFocusAndCommandWorkflows
rg -n "commandSucceeds|verifyFirstSuccessfulTreeCommand|applyFirstSuccessfulWorkflowCommand" Tests
```

Expected: tests pass and the final `rg` exits 1 with no permissive selection helpers.

- [ ] **Step 5: Commit**

```bash
git add Tests/NarwhalCoreTests/CommandWorkflowMatrixTests.swift Tests/NarwhalCoreTests/MVPLayoutTests.swift Tests/NarwhalLiveVerifierTests/LiveCommandWorkflowVerification.swift Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift
git commit -m "test: assert exact directional layout semantics"
```

---

### Task 10: Drive manual resize through the production runtime

**Files:**
- Create: `Tests/NarwhalLiveVerifierTests/RealAppLaunchSupport.swift`
- Create: `Tests/NarwhalLiveVerifierTests/RealFrameAssertions.swift`
- Create: `Tests/NarwhalLiveVerifierTests/ProductionRuntimeHarness.swift`
- Create: `Tests/NarwhalLiveVerifierTests/ProductionManualResizeVerification.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/LiveAppKitVerifierTests.swift`

- [ ] **Step 1: Add a production 2-by-2 test that fails on current behavior**

Start the real AppDelegate process, create four tracked Terminal windows, tile them into 2-by-2 through `narwhalctl`, externally resize bottom-left once, and wait for the real AX observer. Assert:

- both top AX and WindowServer frames are byte-for-byte unchanged;
- bottom-left is preserved at the externally requested frame;
- bottom-right alone consumes the remaining row width;
- all four configured gaps are within tolerance;
- production-owned tiled/focus borders match current WindowServer frames;
- no stale-commit or partial-apply log entry appears.

- [ ] **Step 2: Run only this case and observe failure**

```bash
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_REAL_APP_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.RealAppWindowVerificationTests.productionTwoByTwoManualResize
```

- [ ] **Step 3: Convert mixed browser manual resize to production observer delivery**

Keep fresh Chrome and Firefox launch rules. Remove fabricated `AXEvent` and direct `applyExternalGeometryWorkflowEvent`; resize externally and wait for production logs/state. Retain Terminal companion, AX and WindowServer assertions, gap checks, and cleanup.

- [ ] **Step 4: Split the verifier without changing its scenarios**

Move launch/cleanup, assertions, and runtime process control into the new focused files. Delete copied apply/commit/clamp helpers. `RealAppWindowVerification.swift` remains the suite registry and app-specific scenario composition.

- [ ] **Step 5: Run required focused real-app cases**

```bash
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_REAL_APP_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.RealAppWindowVerificationTests.productionTwoByTwoManualResize
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_REAL_APP_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.RealAppWindowVerificationTests.chromeAndFirefoxCompleteRealManualTileResize
```

- [ ] **Step 6: Commit**

```bash
git add Tests/NarwhalLiveVerifierTests/RealAppLaunchSupport.swift Tests/NarwhalLiveVerifierTests/RealFrameAssertions.swift Tests/NarwhalLiveVerifierTests/ProductionRuntimeHarness.swift Tests/NarwhalLiveVerifierTests/ProductionManualResizeVerification.swift Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift Tests/NarwhalLiveVerifierTests/LiveAppKitVerifierTests.swift
git commit -m "test: verify manual resize through production runtime"
```

---

### Task 11: Verify real hotkey, drag, and Workbench input boundaries

**Files:**
- Create: `Tests/NarwhalLiveVerifierTests/ProductionInputVerification.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/LiveCommandWorkflowVerification.swift`
- Modify: `Tests/NarwhalAppRuntimeTests/LayoutWorkbenchControllerTests.swift`
- Modify: `Sources/NarwhalAppRuntime/LayoutWorkbenchController.swift`

- [ ] **Step 1: Write a failing Carbon hotkey production test**

Start production runtime with a temporary nonconflicting key binding, post key-down/up through `CGEvent` at the HID tap, and verify the expected real Terminal frame/history change. Merely finding “Registered hotkeys” is insufficient.

- [ ] **Step 2: Write a failing modifier-drag production test**

Post Shift mouse-down on a tracked Terminal title bar, drag into a configured zone, and mouse-up. Verify preview appearance through WindowServer, real drop geometry, configured gaps, and preview cleanup. Preserve and restore the pointer location.

- [ ] **Step 3: Write a failing Workbench target/action test**

Use actual `NSButton.performClick`, table selection, and sheet save/cancel actions. Inject the real `LayoutTransactionCoordinator` with deterministic frame writer dependencies; assert one transaction request and the resulting presentation, not debug setter state.

- [ ] **Step 4: Observe failures**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutWorkbenchControllerTests
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_REAL_APP_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.RealAppWindowVerificationTests.productionInputBoundaries
```

- [ ] **Step 5: Implement only the injection/accessibility seams required by the tests**

Do not expose new production IPC commands solely for testing. Use existing closure-style initializers and `#if NARWHAL_ENABLE_VERIFIERS` inspection for preview surfaces.

- [ ] **Step 6: Remove the direct `.dropAtZone` case as proof of event-tap integration**

Retain it as Core/AppKit layout-command coverage under an accurate name; production drag coverage now lives in `ProductionInputVerification`.

- [ ] **Step 7: Run and commit**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LayoutWorkbenchControllerTests
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_REAL_APP_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.RealAppWindowVerificationTests.productionInputBoundaries
git add Tests/NarwhalLiveVerifierTests/ProductionInputVerification.swift Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift Tests/NarwhalLiveVerifierTests/LiveCommandWorkflowVerification.swift Tests/NarwhalAppRuntimeTests/LayoutWorkbenchControllerTests.swift Sources/NarwhalAppRuntime/LayoutWorkbenchController.swift
git commit -m "test: exercise production input boundaries"
```

---

### Task 12: Exercise production display reflow in both directions

**Files:**
- Modify: `Sources/NarwhalAppRuntime/DisplayClient.swift`
- Modify: `Sources/NarwhalAppRuntime/DisplayObserverService.swift`
- Modify: `Sources/NarwhalAppRuntime/App.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/DisplayTopologyReflowVerification.swift`
- Test: `Tests/NarwhalAppRuntimeTests/DisplayObserverServiceTests.swift`
- Modify: `docs/operations.md`

**Interfaces:**

```swift
struct DisplayClient {
    let currentDisplays: @MainActor () -> [DisplayID: DisplayInfo]
}
```

The default initializer retains the current `NSScreen` implementation; tests inject ordered snapshots.

- [ ] **Step 1: Write failing notification-to-transaction tests**

Post `NSApplication.didChangeScreenParametersNotification` and feed snapshots for two-displays→small-laptop, small-laptop→large-monitor, changed origin, and changed visible frame. Assert one gated refresh and one transaction using the fresh post-gate snapshot.

- [ ] **Step 2: Observe failure**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.DisplayObserverServiceTests
```

- [ ] **Step 3: Inject display snapshots and replace fictional-display live proof**

The AppKit live verifier may use synthetic snapshots but must drive `DisplayObserverService`, `WorkspaceMutationGate`, reconciliation, transaction, and overlay publication. Rename its result so it does not claim physical unplug coverage.

- [ ] **Step 4: Document the physical dock/undock release gate**

Specify laptop→external and external→laptop checks with expected full-screen reflow, gaps, focus border, and reverse transition. Label them manual hardware coverage.

- [ ] **Step 5: Run and commit**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.DisplayObserverServiceTests
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LIVE_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.LiveAppKitVerifierTests.displayTopologyReflowGeometry
git add Sources/NarwhalAppRuntime/DisplayClient.swift Sources/NarwhalAppRuntime/DisplayObserverService.swift Sources/NarwhalAppRuntime/App.swift Tests/NarwhalLiveVerifierTests/DisplayTopologyReflowVerification.swift Tests/NarwhalAppRuntimeTests/DisplayObserverServiceTests.swift docs/operations.md
git commit -m "test: drive display reflow through production observer"
```

---

### Task 13: Make installation, Accessibility, and login-item claims truthful

**Files:**
- Modify outside Git commits: `AGENTS.md` (patch only the stale Accessibility-reset sentence in the active user-owned regular file; never stage it or replace it with Git's tracked symlink)
- Modify: `Sources/NarwhalAppRuntime/StartupArguments.swift`
- Modify: `Sources/NarwhalAppRuntime/LoginItemController.swift`
- Modify: `Sources/NarwhalAppRuntime/App.swift`
- Modify: `scripts/smoke_install_upgrade.sh`
- Create: `scripts/smoke_installed_identity.sh`
- Create: `scripts/smoke_login_item.sh`
- Test: `Tests/NarwhalAppRuntimeTests/StartupArgumentsTests.swift`
- Test: `Tests/NarwhalAppRuntimeTests/LoginItemControllerTests.swift`
- Modify: `docs/development.md`
- Modify: `docs/architecture.md`
- Modify: `docs/operations.md`
- Modify: `docs/user-guide.md`

- [ ] **Step 1: Add failing shell assertions for documented behavior**

`smoke_installed_identity.sh --app PATH` launches the supplied installed bundle with `open -na`, resolves the running executable path and designated requirement, checks that the bundle identifier is `com.ben.narwhal`, and confirms through runtime diagnostics that this exact process is Accessibility trusted. It must fail clearly if the exact caller is not trusted; it must never invoke `tccutil reset`. With `--require-stable-signing`, it also rejects an ad-hoc designated requirement. The ordinary mode reports ad-hoc signing as an explicit persistence limitation without misreporting the launch/trust check.

`smoke_login_item.sh --app PATH` requires `NARWHAL_RUN_LOGIN_ITEM_SMOKE=1`. It queries the supplied bundle executable with `--login-item-status`, invokes `--register-login-item` and the existing `--unregister-login-item`, validates each `SMAppService.mainApp.status` transition, and restores the captured original state in `trap` cleanup. If the original or resulting state is `requiresApproval`, it fails with an explicit manual-approval message after restoring any state it can restore; it never opens System Settings automatically.

- [ ] **Step 2: Run scripts and observe the current missing behavior**

```bash
/usr/bin/caffeinate -dimsu scripts/smoke_installed_identity.sh --app "$HOME/Applications/Narwhal.app"
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LOGIN_ITEM_SMOKE=1 scripts/smoke_login_item.sh --app "$HOME/Applications/Narwhal.app"
```

Expected before implementation: script missing or assertion failure.

- [ ] **Step 3: Implement staged installed-bundle identity verification**

Before launch, record any running `com.ben.narwhal` instances and refuse to test if one cannot be stopped and restored safely. Launch the supplied path with LaunchServices, resolve its new PID back to the same standardized bundle and executable paths, inspect that executable's designated requirement, and query `accessibilityTrusted` through that instance's bundled `narwhalctl`. Use a stable `NARWHAL_SIGNING_IDENTITY` when provided. When only ad-hoc signing is available, report that TCC persistence cannot be proven across rebuilds; fail only when `--require-stable-signing` was explicitly requested. Cleanup terminates only the PID created by the smoke and relaunches the prior exact bundle if one was running.

Add explicit `--login-item-status` and `--register-login-item` startup commands beside the existing unregister command. The controller returns a stable machine-readable status token and never toggles implicitly. Unit tests cover command precedence, all `SMAppService.Status` mappings through an injected closure client, register, unregister, approval-required, and not-found behavior.

- [ ] **Step 4: Correct documentation drift**

Replace broad “smokes cover” claims with the exact script or named manual gate providing each boundary. Patch only the stale Accessibility-reset sentence in the active, user-owned `AGENTS.md`; first verify the expected sentence is still present, preserve the regular-file type and every unrelated line, and never stage the file or write through Git's external symlink target.

- [ ] **Step 5: Run install/system integration smokes**

```bash
/usr/bin/caffeinate -dimsu scripts/smoke_install_upgrade.sh
/usr/bin/caffeinate -dimsu scripts/smoke_installed_identity.sh --app "$HOME/Applications/Narwhal.app"
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LOGIN_ITEM_SMOKE=1 scripts/smoke_login_item.sh --app "$HOME/Applications/Narwhal.app"
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.StartupArgumentsTests
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.LoginItemControllerTests
```

- [ ] **Step 6: Commit**

```bash
git add Sources/NarwhalAppRuntime/StartupArguments.swift Sources/NarwhalAppRuntime/LoginItemController.swift Sources/NarwhalAppRuntime/App.swift scripts/smoke_install_upgrade.sh scripts/smoke_installed_identity.sh scripts/smoke_login_item.sh Tests/NarwhalAppRuntimeTests/StartupArgumentsTests.swift Tests/NarwhalAppRuntimeTests/LoginItemControllerTests.swift docs/development.md docs/architecture.md docs/operations.md docs/user-guide.md
git commit -m "test: verify installed system integrations"
```

---

### Task 14: Remove orchestration duplication and enforce performance budgets

**Files:**
- Modify: `Sources/NarwhalAppRuntime/App.swift`
- Modify: `Sources/NarwhalAppRuntime/LayoutApplier.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift`
- Modify: `Tests/NarwhalLiveVerifierTests/ObservationReplayVerification.swift`
- Modify: `Tests/NarwhalAppRuntimeTests/RuntimeMetricsTests.swift`
- Modify: `docs/architecture.md`

- [ ] **Step 1: Write structural and performance assertions**

Add tests proving one settled manual gesture yields one `windowSnapshot` increment, one `manualResizeHandoff`, no duplicate frame target per window, and at most two overlay publication events. Add an architecture test or script assertion that the removed helper names `applyWorkflowCommand`, `applyExternalGeometryWorkflowEvent`, and `applyFirstSuccessfulWorkflowCommand` do not reappear in live verifiers.

- [ ] **Step 2: Observe failure before cleanup**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.RuntimeMetricsTests
rg -n "applyWorkflowCommand|applyExternalGeometryWorkflowEvent|applyFirstSuccessfulWorkflowCommand" Tests/NarwhalLiveVerifierTests
```

- [ ] **Step 3: Move remaining orchestration to focused components**

Delete copied retry/commit logic from tests and dead partial-apply helpers. Keep AppDelegate entry points short and explicit. Remove comments that explain obsolete workarounds, repeated wrappers that only rename coordinator calls, and test fixtures unused by the production-path suites.

- [ ] **Step 4: Verify compiler, metrics, and no-slop checks**

```bash
/usr/bin/caffeinate -dimsu swift test --filter NarwhalAppRuntimeTests.RuntimeMetricsTests
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LIVE_VERIFIERS=1 swift test --disable-sandbox -Xswiftc -DNARWHAL_ENABLE_VERIFIERS --filter NarwhalLiveVerifierTests.LiveAppKitVerifierTests.observationReplay
/usr/bin/caffeinate -dimsu swift build --build-tests
rg -n "applyWorkflowCommand|applyExternalGeometryWorkflowEvent|applyFirstSuccessfulWorkflowCommand" Tests/NarwhalLiveVerifierTests
```

Expected: tests/build pass and the final `rg` exits 1 with no matches.

- [ ] **Step 5: Commit**

```bash
git add Sources/NarwhalAppRuntime/App.swift Sources/NarwhalAppRuntime/LayoutApplier.swift Tests/NarwhalLiveVerifierTests/RealAppWindowVerification.swift Tests/NarwhalLiveVerifierTests/ObservationReplayVerification.swift Tests/NarwhalAppRuntimeTests/RuntimeMetricsTests.swift docs/architecture.md
git commit -m "refactor: remove duplicated layout orchestration"
```

---

### Task 15: Complete the full verification gate

**Files:**
- Modify only files required by failures discovered in this task.

- [ ] **Step 1: Run all deterministic tests**

```bash
/usr/bin/caffeinate -dimsu swift test
```

Expected: every suite passes with zero issues and zero skipped enabled tests.

- [ ] **Step 2: Run compiler/build verification**

```bash
/usr/bin/caffeinate -dimsu swift build --build-tests
```

- [ ] **Step 3: Run relevant shell smokes**

```bash
/usr/bin/caffeinate -dimsu scripts/smoke_startup_shutdown.sh
/usr/bin/caffeinate -dimsu scripts/smoke_config_hot_reload.sh
/usr/bin/caffeinate -dimsu scripts/smoke_startup_failure_matrix.sh
/usr/bin/caffeinate -dimsu scripts/smoke_install_upgrade.sh
/usr/bin/caffeinate -dimsu scripts/smoke_installed_identity.sh --app "$HOME/Applications/Narwhal.app"
/usr/bin/caffeinate -dimsu env NARWHAL_RUN_LOGIN_ITEM_SMOKE=1 scripts/smoke_login_item.sh --app "$HOME/Applications/Narwhal.app"
```

- [ ] **Step 4: Run the full live UI/real-app gate from Accessibility-trusted Terminal**

```bash
scripts/live_verify_all.sh
```

Expected coverage, all sequential and unskipped:

- AppKit artifacts, Workbench, focus/tiled borders, real sheet/dialog occlusion, Spaces, and display notification reflow;
- Firefox, Chrome, System Settings, and Terminal real frame writes;
- production 2-by-2 bottom-row vertical-seam resize;
- production Chrome/Firefox/Terminal manual resize;
- three-window Firefox and Chrome vertical stacks;
- four-through-eight Terminal horizontal/vertical layouts and mixed push sequences;
- Outlook side transfer;
- production Carbon hotkey and modifier drag;
- AX and WindowServer frame agreement plus production-owned borders.

- [ ] **Step 5: Inspect the live log for forbidden outcomes**

```bash
rg -n "source workspace changed before commit|planned layout was not committed|stale parent focus border remained visible|configured .* gap is physically inconsistent|visible frames overlap|skipped" "$HOME/Library/Logs/Narwhal/narwhal.log"
```

Expected: no entries from the final verification run. Distinguish historical lines by the run start timestamp rather than deleting the user's log.

- [ ] **Step 6: Review repository state**

```bash
git diff --check
git status --short
git diff --stat
```

Expected: the branch contains only the scoped commits from Tasks 1–14 and no unstaged task changes. Do not create an empty final commit.

---

If a final verification failure requires code changes, return to the owning task's red-green-refactor loop and make a new scoped commit there. Do not create a catch-all final correction commit.

## Plan self-review checklist

- Every correctness finding maps to Tasks 1–7.
- Permissive and circular tests map to Tasks 8–11.
- Display, Accessibility, install, and `SMAppService` gaps map to Tasks 12–13.
- Maintainability and performance findings map to Tasks 7, 10, and 14.
- Required real applications and AX plus WindowServer assertions are explicit in Tasks 10, 11, and 15.
- All test commands use command-scoped caffeination except `scripts/live_verify_all.sh`, which already provides it.
- Every implementation task ends in a scoped commit.
