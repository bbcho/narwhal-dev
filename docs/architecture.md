# Architecture

This is the spine of the codebase: the module boundaries, the one path every
layout change travels, the single owner of each concern, and the invariants
that hold across them. Read it before adding a command, an observer, or a new
file. When code and this document disagree, fix one of them in the same change.

Narwhal is a pure core wrapped by a thin macOS shell. Layout decisions are
replayable from value inputs. AppKit, Accessibility (AX), Carbon hotkeys, the
event tap, Lua, the filesystem, and IPC stay at the edge.

## Module Map

| Target | Role | Depends on |
|---|---|---|
| `NarwhalCore` | Pure domain types and functions: commands, BSP tree operations, layout solving, seam resize, focus navigation, drag zones, world reconciliation, restore projection, config parsing, rules, named layouts, echo and coalescer state machines, IPC DTOs. | nothing |
| `NarwhalAppSupport` | Pure shell decisions that need no AppKit: the `*Model.swift` policy functions, service lifecycle, restore save scheduling, and the JSON stores for restore state, managed rules, and named layouts. | Core |
| `NarwhalIPC` | Unix socket transport and socket path resolution. | Core |
| `NarwhalAppRuntime` | The macOS shell: `AppDelegate`, `WorldActor`, AX reads and writes, frame transactions, observers, hotkeys, event tap, Lua loading, config watching, overlays, menubar, workbench, logging. | Core, AppSupport, IPC, CLua |
| `NarwhalApp` | Executable entry point; calls into `NarwhalAppRuntime`. | AppRuntime |
| `NarwhalCtl` | `narwhalctl` command-line client. | Core, IPC |
| `CLua` | C shim over Lua 5.5: allocator and instruction limits, sandboxed library set. | Homebrew Lua |

The dependency direction is enforced by `Package.swift`. Core imports only
CoreGraphics and Foundation and touches no files, AX, or AppKit; if a Core change
needs one of those, the logic belongs in the shell.

## The Spine: How a Layout Change Happens

Every change to tiled layout follows one path. A new command adds a step-4
function and a step-2 handler; it does not add a new path.

```text
 1. Input        hotkey (HotkeyManager) | IPC (IPCServer) | drag-drop (EventTapClient)
                 | overlay or workbench | AX notification / inventory poll
                        |
 2. Handler      AppDelegate.performX / handleSerializedIPCCommand / drop handler
                        |
 3. Gate         WorkspaceMutationGate.perform        FIFO, one mutation at a time
                        |
 4. Plan         WorldActor.planX  ->  NarwhalCore apply / tree ops / solveLayout
                 returns CommandPlanResult (planned World + DesiredLayout); no effects
                        |
 5. Apply        AppDelegate.applyPlannedLayout
                   LayoutTransactionCoordinator.execute    retry once on min-size clamp
                     LayoutFrameTransaction.execute        write, read back, roll back
                       WindowFrameWriter.setFrame          AX path or Terminal path
                         AXClient                          AX attribute writes
                        |
 6. Commit       WorldActor.commit(plan, appliedFrames)   only if isCurrent(plan)
                        |
 7. Persist      AppDelegate.persistRestore  ->  RestoreManager (debounced, atomic)
                        |
 8. Present      LayoutPresentationCoordinator (borders), overlays, menubar status
```

Rules of the spine:

- `World` changes only inside `WorldActor`, and only inside the gate.
- Frames are written only by `LayoutFrameTransaction`. Nothing else calls
  `WindowFrameWriter.setFrame` for a tiled window.
- A plan is committed only when every write converged and the world has not
  changed since planning (`WorldActor.isCurrent`). Otherwise the transaction
  rolls windows back and the model stays at its previous state.
- Before writing, the transaction registers each target frame with
  `AXEchoSuppressor`, so the AX notifications caused by Narwhal's own writes are
  not read back as user edits.

### Side paths into the spine

User geometry (the user drags or resizes a tiled window):

```text
AXObserverService -> AXEchoSuppressor (drop own echoes) -> ExternalGeometryCoordinator
(settle debounce) -> gate -> WorldActor.planExternalGeometry
-> Core spacesByApplyingExternalResize -> resizeVisibleSeamInTree
   success: rebuilt tree, continue at step 5
   failure: the window is detached to floating
```

Environment changes (window opened or closed, Space switch, display change):

```text
AXObserverService inventory poll / DisplayObserverService / SpaceClient
-> scheduleEnvironmentRefresh (Core coalescer) -> gate
-> WorldActor.refreshEnvironment -> Core reconcileEnvironment -> step 7
```

Config:

```text
init.lua -> StartupConfigLoader (CLua, limits) -> LuaConfigData
-> Core parseConfig -> Config -> WorldActor.reloadConfig; HotkeyManager rebinds
ConfigFileWatcherService triggers the same path on save.
```

Startup restore:

```text
RestoreManager.load -> StoredWorld -> WorldActor.restore (Core restoreWorld)
-> AppDelegate.startServices (ServiceLifecycle, rolls back on any failure)
```

## Single Owners

Each concern has exactly one owner. Extend the owner; do not add a second.

| Concern | Owner |
|---|---|
| Mutable runtime state | `WorldActor` |
| Serializing mutations | `WorkspaceMutationGate` |
| Command semantics | `NarwhalCore/Apply.swift` (`apply`) and `Command.swift` |
| Tree shape changes | `NarwhalCore/TreeOperations.swift` |
| Frame computation and min-size solving | `NarwhalCore/LayoutSolver.swift` |
| Mouse seam resize | `NarwhalCore/VisiblePartitionResize.swift` |
| Reconciling live windows, Spaces, displays | `NarwhalCore/WorldReconciliation.swift` |
| Restore projection and matching | `NarwhalCore/Restore.swift` |
| Restore file I/O and save debounce | `NarwhalAppSupport/RestoreManager.swift` |
| Config validation | `NarwhalCore/ConfigParsing.swift` |
| Lua execution and sandbox | `LuaConfigLoader.swift` and `Sources/CLua/shim.h` |
| Writing frames | `LayoutFrameTransaction` -> `WindowFrameWriter` -> `AXClient` |
| Retry on minimum-size clamp and commit | `LayoutTransactionCoordinator` |
| Distinguishing own writes from user edits | `AXEchoSuppressor` (state machine in `NarwhalCore/AXEcho.swift`) |
| Window inventory and AX notifications | `AXObserverService` |
| Hotkey registration and key mapping | `HotkeyManager` |
| Drag-to-zone gesture | `EventTapClient` + `NarwhalAppSupport/DragGestureModel.swift` |
| Service start and rollback | `NarwhalAppSupport/ServiceLifecycle.swift` |
| IPC framing, auth, socket lifecycle | `NarwhalIPC/IPCTransport.swift` |
| Log redaction | `NarwhalAppSupport/LogLineModel.swift` |

`AppDelegate` (`App.swift`) wires these together. It should route, not decide:
when a branch in `App.swift` makes a policy decision, that decision belongs in a
Core function or an AppSupport model with its own tests.

## Domain Data

- `World`: displays, active Space, per-Space display layouts, live windows,
  window-display ownership, observed constraints, pending rules, and config.
- `SpaceState`: display layouts and focused window for one Space.
- `DisplaySpaceState`: BSP tree plus floating window order for one display.
- `Node`: `.void`, `.leaf(WindowID)`, or `.split(Split)`.
- `Split`: axis plus two or more weighted cells.
- `Cell`: positive finite weight plus child node.
- `WindowMetadata`: identity, bundle, title, role, pid, frame, resizability,
  minimization.
- `CommandPlanResult` / `DesiredLayout`: the planned world and the frames the
  shell should apply.
- `StoredWorld`: restore projection keyed by stable references, never raw window
  IDs.

## Invariants

| Invariant | Enforced by | Tested by |
|---|---|---|
| A `Split` has at least two cells. | `Split.create` | `ADTTests` |
| A `Cell` weight is finite and positive. | `Cell.create` | `ADTTests` |
| Tiled frames are disjoint, inside the display, and cover it with configured gaps. | `solveLayout` | `SlotSequenceTests` (all insertion sequences up to six windows), `SnappedFrameGapTests` |
| Tree operations preserve `.void` slots unless a reset clears them. | `TreeOperations.swift` | `MVPLayoutTests` |
| Non-resizable windows never enter a tree. | Core `apply` | `MVPLayoutTests`, `RulesTests` |
| The model commits only frames that AX confirmed. | `LayoutTransactionCoordinator` + `WorldActor.commit` | `LayoutTransactionCoordinatorTests` |
| Config numbers are finite and in range; hotkeys are unique. | `parseConfig` | `ConfigTests` |
| Lua cannot reach `os`, `io`, `require`, or files. | `shim.h` library set | `LuaConfigLoaderTests` (`os` only) |
| IPC peers must share the server's effective UID; socket and lock are owner-only. | `IPCTransport.swift` | `IPCTransportTests` |
| Restore never trusts raw window IDs across launches. | `Restore.swift` | `RestoreTests` |

## Concurrency Model

- AppKit-facing code runs on `@MainActor`.
- `WorldActor` serializes state; `WorkspaceMutationGate` serializes whole
  workflows (plan, apply, commit), so AX settling can suspend without another
  mutation interleaving.
- AX frame writes settle with async delays; production code never spins a nested
  run loop.
- Timers schedule back onto `@MainActor`.
- IPC runs blocking socket calls in detached tasks and closes every client socket
  on shutdown.
- Restore save scheduling is a pure state machine wrapped by a `@MainActor`
  scheduler.

Anything that waits on user input or external code inside the gate blocks every
other workflow until it returns. Keep modal UI and config execution outside it.

## Error Model

Expected domain failures return `Result` with a domain enum: `CommandError`,
`ConfigError`, `RestoreError`, `TreeResizeError`,
`VisiblePartitionResizeError`. Shell failures throw shell types:
`StartupConfigError`, `AXClientError`, `IPCTransportError`,
`RestoreManagerError`, `ServiceStartupError`. The shell converts both to log
lines, IPC replies, or menubar status at the boundary.

## Restore

A stored window reference holds bundle ID, title, role, duplicate occurrence
index, last known frame, display slot, and display fingerprint. On restore,
references are matched to live windows; raw window IDs are never treated as
stable across launches.

## Config

Config crosses two boundaries. `StartupConfigLoader` runs Lua and decodes the
returned table into `LuaConfigData`, rejecting unsupported types, sparse arrays,
mixed table and array keys, cycles, and excessive depth. `parseConfig` then
validates semantics (finite numbers, ranges, duplicate hotkeys, regexes, zone
bounds) into an immutable `Config`. Keys a user omits inherit defaults; an
explicit empty collection replaces the default collection.

## IPC

Newline-delimited JSON over a per-user Unix socket at
`"$(getconf DARWIN_USER_TEMP_DIR)narwhal.sock"`, with `narwhal.lock` beside it
for exclusive ownership. `IPCCommandDTO` and `IPCReplyDTO` live in Core because
they are pure protocol values shared by the app, the CLI, and tests.

## Where New Code Goes

| You are adding | Put it in | Test it with |
|---|---|---|
| A layout rule or decision | Core function | Core unit test with exact frames |
| A shell policy (when to retry, what to log, whether to act) | AppSupport `*Model.swift` function | AppSupport unit test |
| A new command | `Command`, Core `apply`, `WorldActor.planX`, one `AppDelegate` handler that calls `applyPlannedLayout` | Core test for the plan; live verifier for the AX effect |
| A new macOS effect | A client type in AppRuntime that returns values | Live verifier |
| A config field | `Config`, `parseConfig`, `docs/configuration.md` | `ConfigTests` and a `LuaConfigLoaderTests` round trip |

Do not add a second frame writer, a second mutation queue, or state outside
`WorldActor` that decides layout.

## Testing Shape

- Core and AppSupport: unit tests, about 92% line coverage. These run in CI.
- AppRuntime: about 23% line coverage from unit tests; `App.swift`, `Overlay.swift`,
  `HotkeyManager`, `AXObserverService`, and `ConfigFileWatcherService` have none.
- Live verifiers (`Tests/NarwhalLiveVerifierTests`) drive real AppKit and real
  app windows. They compile only with `-DNARWHAL_ENABLE_VERIFIERS` and run only
  through `scripts/live_verify_all.sh` on an Accessibility-trusted machine; CI
  does not run them.
