# Narwhal Layout Reliability Design

## Purpose

Narwhal must make window-management commands behave as one coherent operation even though macOS Accessibility frame writes are sequential and external applications retain final control over their windows. A command must never leave the model, history, borders, and visible windows describing different layouts.

This design addresses the production resize regression and the cross-cutting review findings in correctness, test reliability, maintainability, performance, and system-integration coverage.

## User-visible contract

1. A successful layout operation leaves every affected real window at its verified target frame, commits one history transition, and renders borders from those verified frames.
2. A failed layout operation does not enter history. Every already-moved window is restored to its verified pre-operation frame.
3. If restoration is incomplete, Narwhal refreshes from live AX and WindowServer state, marks only the affected workspace as requiring reconciliation, hides that workspace's stale tiled borders, and refuses automatic layout retries in that workspace until a complete refresh clears the condition.
4. One failed workspace does not pause Narwhal globally. Commands in unaffected workspaces remain available.
5. Manual resizing preserves the window under the pointer. In a 2-by-2 layout, moving the vertical seam segment within the bottom row changes only the two bottom windows; the top row remains unchanged.
6. Manual resize bursts are latest-wins. Narwhal does not queue obsolete sibling corrections or rewrite the source window during the gesture.
7. Focus and tiled borders are rendered only from current live frames. A dialog or sheet occludes its parent borders and receives the focus border when AX identifies it as the focused container.
8. Configured gaps remain constant after every successful command, manual resize, display reflow, rollback, and restore convergence.

## Transaction invariants

Every layout transaction obeys these invariants:

- **Currency before effects:** the plan's `sourceWorld` must still equal the actor's current world immediately before the first external write.
- **Complete snapshot:** every moving window that is not intentionally preserved must have both AX and WindowServer pre-operation frames before any write begins.
- **Single writer:** no environment reconciliation, display reflow, open-rule application, manual-resize transaction, hotkey command, IPC command, or Workbench command may mutate the world while another workspace mutation is suspended.
- **Source preservation:** a manually resized source window is an anchored input, never a transaction write target.
- **Complete validation:** success requires final AX and WindowServer readback for every affected tiled window, no overlaps, and configured gaps within the existing tolerance.
- **Currency before commit:** the plan must still be current after validation and immediately before history/model commit.
- **Compensating rollback:** any write, validation, or currency failure after the first effect restores already-written windows in reverse write order and validates their AX and WindowServer frames.
- **Truth after failure:** if rollback validation fails, the next model state is derived from one complete live snapshot, never from the intended plan or the successfully written prefix.
- **Presentation last:** history, restore persistence, Workbench presentation, focus borders, and tiled borders update only after commit or completed failure reconciliation.

## Architecture

### 1. `LayoutFrameTransaction`

Create `Sources/NarwhalAppRuntime/LayoutFrameTransaction.swift` as the only component that performs a multi-window geometry effect.

It consumes a `CommandPlanResult`, a set of preserved source frames, and `WindowFrameWriter`. It produces one of:

- `committedCandidate(appliedFrames:)`: all requested writes and final geometry validation succeeded; model commit has not happened yet.
- `constraintObserved(originalFrames:observations:)`: an app exposed a new stable constraint; all written windows have already been restored.
- `rolledBack(originalFrames:failure:)`: application or validation failed and every external effect was restored.
- `reconciliationRequired(originalFrames:liveFrames:failure:rollbackFailures:)`: rollback could not restore or verify every affected window.

The transaction captures originals using a dedicated `WindowFrameWriter.readFrame` operation. Rollback uses the same application-specific adapter as forward writes, including Terminal bounds handling, and validates both AX and WindowServer readback.

`LayoutApplier` is reduced to deterministic write ordering, target reflow, and validation helpers used by `LayoutFrameTransaction`; it no longer exposes a successful prefix as an acceptable final result.

### 2. `LayoutTransactionCoordinator`

Create `Sources/NarwhalAppRuntime/LayoutTransactionCoordinator.swift` to own the complete plan/effect/commit/retry lifecycle now duplicated between `App.swift` and `RealAppWindowVerification.swift`.

The coordinator owns:

- pre-effect and pre-commit currency checks through `WorldActor`;
- bounded constraint learning and replanning;
- model/history commit only after `committedCandidate`;
- live reconciliation after incomplete rollback;
- affected-workspace reconciliation state;
- a structured `LayoutTransactionOutcome` used by AppDelegate, IPC replies, Workbench, diagnostics, and live verifiers.

The coordinator does not render UI or persist restore state. It returns verified frames, affected workspace keys, focus updates, constraint observations, and failure evidence so AppDelegate can publish presentation effects once.

### 3. `WorkspaceMutationGate`

Replace `MainActorCommandExecutionGate` with `WorkspaceMutationGate`. All operations that can change `WorldActor` enter this gate:

- hotkeys and IPC commands;
- drag/drop and Workbench commands;
- AX external-geometry processing;
- environment refresh completion;
- active-Space and display reconciliation;
- startup convergence and pending open rules;
- config-driven managed-rule activation where it changes world state.

Code already executing inside the gate calls helpers with a `Locked` suffix. Timer, observer, and IPC entry points acquire the gate exactly once. This prevents reentrant deadlock while making mutation ownership visible in function names.

Coalescers may gather reasons and replace pending events while the gate is occupied. They may not apply their snapshots until they acquire the gate. After acquiring it they capture a fresh snapshot rather than applying a snapshot collected before the wait.

### 4. `ExternalGeometryCoordinator`

Create `Sources/NarwhalAppRuntime/ExternalGeometryCoordinator.swift` for manual move/resize state.

Behavior:

- AX notifications update a per-window latest-event slot.
- The first event marks the source `.manualAdjustment` and hides affected tiled borders.
- A short trailing-edge settle window collapses a gesture burst to the latest complete live frame. The existing notification throttle remains responsible only for limiting AX polling; it no longer starts sibling transactions at 30 Hz.
- Once settled, the coordinator plans from the current world and anchors the source frame.
- A newer event arriving before transaction start replaces the pending event.
- A newer event arriving during sibling application is retained and processed after the current transaction; it does not mutate the active plan.
- Successful handoff clears interaction state and publishes verified borders once.
- Application constraints detach only the affected source window; incomplete rollback marks the workspace as requiring reconciliation.

The default settle interval is 120 milliseconds. The interval is an internal constant, not a user-facing configuration option.

### 5. Workspace reconciliation state

Extend `WorldRuntimeState` with `workspaceReconciliationIssues: [WorkspaceKey: WorkspaceReconciliationIssue]`. The issue records the operation label, affected window IDs, and concise failure reason; it does not persist across application restarts.

`WorkspaceHealth` gains `.reconciliationRequired`. A complete environment refresh clears the issue only after all tiled window frames in that workspace can be solved without overlap or gap violations. Workbench and the workspace popover show the state and offer the existing refresh/reset recovery paths.

### 6. Overlay publication

Extract the transaction-related overlay rules from `App.swift` into `LayoutPresentationCoordinator.swift`:

- at transaction start, hide tiled borders only for affected workspace windows;
- during manual adjustment, update the focus border from the source's live frame when unobscured;
- on commit, render tiled and focus borders from verified frames;
- on verified rollback, restore borders from verified original frames;
- on incomplete rollback, keep affected tiled borders hidden until reconciliation succeeds;
- never render a planned frame that was not confirmed by WindowServer.

The WindowServer focus-border verifier must throw if it cannot resolve the actual border surface. Debug AppKit state alone is not sufficient.

## Manual resize semantics

Manual resizing is derived from the visible partition, not from whichever BSP topology happened to produce it. This distinction is required because the same 2-by-2 geometry can be stored as either two column subtrees or two row subtrees. A bottom-row seam must remain local even when the historical tree stores one root seam shared by both rows.

The Core operation performs these steps:

1. Render every occupied and empty tree slot to a stable slot identity and frame before the resize.
2. Compare the settled source frame with its prior frame to identify the one moved edge. Ambiguous multi-edge changes are treated as a move/detach rather than guessed as a resize.
3. Find the visible neighbors whose opposite edges coincide with the old source edge and whose orthogonal spans overlap the moved edge.
4. Move only that contiguous visible seam segment. Adjust the source and directly adjacent slot rectangles; preserve every nonparticipant rectangle exactly.
5. Validate positive extents, the configured gap, no overlap, and complete coverage of the original partition.
6. Reconstruct a guillotine BSP from the adjusted occupied and empty slot rectangles. Cut selection is deterministic: prefer a full-span cut matching the changed seam, then preserve original ancestor grouping where compatible, then use vertical-before-horizontal coordinate order as the final tie-breaker.
7. Assign split weights from reconstructed cell extents and verify that solving the rebuilt tree reproduces the intended rectangles within configured-gap tolerance.

This reconstruction intentionally rotates a column-shaped 2-by-2 tree into a row-shaped tree when that is necessary to localize the bottom-row vertical seam segment. Empty slots participate in reconstruction so zone capacity is not lost.

If the changed seam is not adjacent to another slot, the adjusted rectangles are not guillotine-partitionable, reconstruction does not reproduce the intended frames, or more than one source edge changed, Narwhal records the live geometry and temporarily detaches the source instead of resizing an unrelated ancestor.

## Performance contract

- One AX window inventory snapshot per settled manual-resize handoff.
- No more than one pending external-geometry event per window.
- No frame write for a window whose canonical target already matches both live readbacks.
- No overlay render between individual writes; one transition render at start and one final render after commit, rollback, or reconciliation.
- Constraint retry is bounded by distinct new observations, as today, but each failed attempt restores before replanning.
- Preserve existing runtime metrics and add `layout_transaction`, `layout_rollback`, and `workspace_reconciliation` metrics.
- Focused live verification requires manual-resize handoff to finish within 800 milliseconds after the settle interval. Deterministic tests assert snapshot and write counts rather than machine-dependent elapsed time.

## Verification design

### Deterministic tests

- Transaction succeeds only after every AX and WindowServer frame validates.
- Failure on the second or third write restores earlier writes in reverse order.
- Constraint discovery restores before retry and never records partial frames.
- Rollback refusal produces `reconciliationRequired` from live frames and no history entry.
- A refresh scheduled during a suspended write executes afterward and cannot stale the commit.
- Exact 2-by-2 top-row and bottom-row vertical seam cases preserve the unrelated row.
- Exact directional semantics replace “any direction succeeds” assertions for swap and resize.
- The visual helper fails when the WindowServer border surface cannot be resolved.
- External geometry bursts collapse to one settled event and one inventory snapshot.

### Production-path AppKit and real-app verification

- Start the production AppDelegate/runtime and drive four real Terminal windows into a 2-by-2 layout. Resize the bottom-left window externally, let the real AX observer deliver the event, then verify top-row AX and WindowServer frames remain unchanged, the bottom-right window adjusts, gaps are exact, and production-owned borders match current live frames.
- Convert the Chrome/Firefox/Terminal manual-resize workflow to use the production observer and transaction coordinator instead of a fabricated `AXEvent` helper.
- Post a real Carbon hotkey to the production runtime and verify the expected real-window result.
- Post modifier mouse-down/drag/up events through the production event tap and verify preview, drop, resulting live frame, and cleanup.
- Activate Workbench controls through AppKit target/action and verify that they use the production coordinator; retain screenshot artifacts for visual states.
- Drive display-change notification handling through an injectable current-display provider in the production runtime. Cover larger-to-smaller, smaller-to-larger, origin changes, and visible-frame changes. Retain an explicit physical dock/undock manual release check because software injection cannot prove macOS hardware notification behavior.
- Launch the staged installed bundle through LaunchServices, identify its exact executable and signing requirement, and make Accessibility trust attribution explicit. Never reset TCC implicitly.
- Exercise `SMAppService` only in an explicit system-integration smoke that restores its original registration state in cleanup.

The full live gate remains sequential and must fail on skips, missing suites, missing applications, absent Accessibility trust, unresolved WindowServer surfaces, or zero matching tests.

## Maintainability boundaries

- `App.swift` retains lifecycle wiring and user-facing presentation only; planning/effect/retry algorithms move to the coordinators above.
- `RealAppWindowVerification.swift` retains application launch/cleanup and assertions; it does not reimplement production transaction control flow.
- Shared real-app helpers move into focused files grouped by launch tracking, frame assertions, production runtime control, and scenario definitions.
- No new protocol hierarchy is introduced. Dependencies are concrete structs with closure-based test initializers, matching `WindowFrameWriter` and existing project style.
- Existing public Core and AppSupport APIs remain source-compatible unless a test demonstrates that their current semantics are unsafe.

## Documentation and operational truth

- Correct the active agent-rule text to state that `install_local.sh` does not reset Accessibility, but never stage the existing user-owned `AGENTS.md` type change or replace the repository's tracked symlink.
- Correct development and architecture documentation so “covered” means an automated test or named manual release gate actually exercises the operating-system boundary.
- Document stable signing requirements for repeated installed-app Accessibility verification.
- Document which display and `SMAppService` checks necessarily mutate local system state and how they restore it.

## Non-goals

- Narwhal will not attempt simultaneous AX writes; macOS exposes no atomic multi-window API.
- Narwhal will not add configurable animation or resize-settle timing in this change.
- Narwhal will not silently relax configured gaps or accept overlap to make a layout pass.
- Narwhal will not reset Accessibility or enable Launch at Login without an explicit operator action.
- This work does not redesign unrelated Workbench visuals or add new layout commands.
