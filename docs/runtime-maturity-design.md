# Runtime Maturity Design

This change improves observation latency, runtime diagnostics, filesystem
isolation, and shell-code organization without changing Narwhal's tiling
semantics. `NarwhalCore` remains the authoritative pure layout model.

## Invariants

- The window being manually dragged or resized remains authoritative. A fast
  observation must never cause Narwhal to write the source window's frame.
- AX notifications are an optimization, not a source of truth. A slower full
  inventory reconciliation remains active because applications can omit or
  reorder notifications.
- Event bursts retain the newest geometry per window. Work already in flight
  may finish, but stale queued work must not overwrite newer geometry.
- Layout state commits only after required AX effects converge.
- Restore saves are serialized in request order. An older background write
  must never overwrite a newer restore snapshot.
- Routine logging must not block the main actor. Error logging may synchronously
  flush because it is exceptional and durability matters.
- Diagnostics omit window titles, application names, config contents, and
  filesystem paths. The IPC and clipboard payloads expose only operational
  counts, identifiers, state quality, queue depths, build data, and latency
  summaries.
- Diagnostic sampling is bounded in memory and does not alter runtime behavior.

## Data model

Pure value types live in `NarwhalAppSupport` or `NarwhalCore` when they are also
part of the IPC contract:

- `RuntimeMetricKind`: closed set of measured runtime stages.
- `RuntimeMetricSample`: metric, duration, and optional integer counters.
- `RuntimeMetricsState`: bounded recent samples by metric.
- `RuntimeMetricSummary`: count, latest, median, p95, and maximum duration.
- `RuntimeDiagnostics`: privacy-safe IPC/clipboard snapshot.
- `AXNotificationThrottleState`: whether a fast observation is scheduled and
  whether newer input arrived while it was scheduled.
- Log rotation plan: explicit oldest-first rename/delete operations derived from
  a maximum file size and generation count.

Impossible states are excluded where practical: sample durations must be finite
and non-negative before entering the metrics state; percentile summaries are
absent for empty sample sets; queue depths and counts are non-negative.

## Core and shell boundary

```text
macOS AX notifications ─┐
                       ├─> AXObserverService ─> pure observation reducers
slow CG/AX inventory ──┘             │
                                     v
                         AppDelegate command gate
                                     │
                            pure World planning
                                     │
                                     v
                              coordinated AX writes

timing probes ─> bounded pure metrics state ─> diagnostics snapshot

restore values ─> serialized background writer ─> atomic state.json
log lines      ─> bounded serial writer          ─> rotated narwhal.log
```

`[CORE]` functions:

- Record a valid metric sample into bounded immutable state.
- Summarize bounded samples deterministically.
- Advance notification-throttle state for input, timer fire, and completion.
- Build privacy-safe diagnostics from explicit operational inputs.
- Build and validate a log-rotation plan.

`[SHELL]` adapters:

- Register and remove per-process AX observers on the main run loop.
- Read focused-window and full-window snapshots.
- Emit `os_signpost` intervals and record elapsed monotonic time.
- Execute atomic restore reads/writes on a serial actor.
- Execute log writes and rotation on a private serial queue.
- Encode diagnostics for IPC and the pasteboard.

## Failure contracts

- AX notification registration returns an explicit error to the observer
  service. The service logs it and keeps slow reconciliation running.
- Snapshot and frame-write failures retain their existing `Result`/outcome
  contracts. Instrumentation observes those outcomes and never changes them.
- Restore I/O throws inside the background writer and becomes a
  `RestoreSaveEvent` at the main-actor boundary.
- Log initialization or write failure reports once to stderr; normal app
  execution continues with unified logging.
- Invalid diagnostic IPC JSON is rejected by the existing IPC decoder.
  Diagnostics generation itself is total for valid in-memory state.
- Clipboard encoding failures produce operator feedback and an error log.

## State and concurrency

- `WorldActor` remains the only owner of mutable world state.
- `AXObserverService` remains `@MainActor`; its timers, active AX observer, and
  notification throttle are UI-run-loop state.
- `RuntimeMetrics` stores immutable `RuntimeMetricsState` values behind a small
  lock so `WorldActor` can record completed planning work without hopping onto
  the main actor. The lock never covers AX, planning, or filesystem work.
- Restore I/O uses one actor. Main-actor scheduling remains a pure state machine,
  while an explicit task tail preserves disk-write order and supports awaited
  shutdown flushing.
- Logging uses one bounded serial dispatch queue. The lock protects only queue
  admission counters; file handles never escape the writer queue.
- No I/O occurs inside pure reducers or retryable world transitions.

## Dependency binding

- `AppDelegate` owns one `RuntimeMetrics` instance and passes its recorder to
  AX and layout shell components.
- `AXObserverService` owns one focused-application notification client and
  falls back to injected snapshot closures in tests.
- `RestorePersistence` binds a concrete filesystem actor in production and an
  async save closure in scheduler tests.
- `StartupReporter` owns the bounded file sink; tests inject a temporary path
  and explicitly flush before assertions.

No service locator, generic manager layer, or speculative protocol is added.

## Observability

Signpost and bounded-summary points:

- `window_snapshot`
- `focused_window_snapshot`
- `layout_plan`
- `coordinated_frame_write`
- `manual_resize_handoff`
- `restore_write`

Intervals use monotonic time. Signposts contain counts and outcome labels but no
window titles or user paths. Diagnostics expose aggregated timing only.

## Verification

Pure tests:

- Metrics never retain more than their configured capacity.
- Summary percentiles are deterministic for unsorted samples.
- Invalid durations do not enter state.
- Notification bursts schedule at most one timer and request one follow-up when
  input arrives during a scheduled pass.
- Diagnostics JSON round-trips and contains no title/path fields.
- Log rotation plans preserve the requested generation bound.

Shell tests:

- Failed AX notification registration leaves reconciliation polling active.
- Background restore saves retain request order and `flushPending` awaits disk
  completion.
- Routine log writes are visible after `flush`, errors are durable, buffer
  overflow is bounded, and rotation preserves owner-only files.
- `narwhalctl status` decodes and prints the diagnostics reply.
- The menu contains `Copy Diagnostics`, and the action writes the expected
  privacy-safe JSON to the pasteboard.

Live gates:

- Existing AppKit visual verifiers, including the menu surface.
- Chrome, Firefox, System Settings, Terminal, mixed Chrome/Firefox manual
  resizing, and three-window Chrome/Firefox stacks.
- Both AX-applied and WindowServer-visible frames remain required.
- Skips and missing live suites remain failures.

## Production risks and mitigations

- Some applications do not deliver AX notifications reliably: retain slow
  reconciliation and rebind on application activation.
- Notification storms could outrun AX writes: throttle the fast observation and
  preserve the existing newest-event-per-window queue.
- Background persistence could reorder saves: chain writes explicitly and await
  the chain at shutdown.
- Async logging could lose final lines: provide an explicit flush and call it
  during orderly termination.
- Diagnostics could leak user data: use a closed, privacy-reviewed DTO rather
  than serializing internal world or window metadata.

## De-slop constraints

- Add only the notification client, metrics owner, and filesystem writers that
  correspond to real effect boundaries.
- Prefer value types and free functions for planning, summarization, and DTO
  construction.
- Extract verifier-only code from `Overlay.swift`; do not introduce generic
  coordinators or factories merely to reduce line counts.
- Remove unused hooks and collapse one-use wrappers during the final review.
