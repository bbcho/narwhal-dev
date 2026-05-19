# Architecture

Narwhal is split into a mostly pure core and a thin macOS shell. The main design
goal is that layout decisions are replayable from value inputs, while AppKit,
Accessibility, Carbon hotkeys, Lua, filesystem, and IPC effects stay at the
edge.

## Module Map

| Target | Role |
|---|---|
| `NarwhalCore` | Pure domain types and functions: config parsing, rules, world reconciliation, tree operations, layout solving, focus navigation, drag-zone resolution, restore projection/remap, echo/coalescer state machines, IPC DTOs. |
| `NarwhalApp` | macOS shell: AppKit lifecycle, AX reads/writes, hotkeys, event tap, display/Space reads, Lua loading, config watching, IPC command handling, overlays, menubar, logging. |
| `NarwhalAppSupport` | Shell-support code that is testable without AppKit app startup: service lifecycle and restore persistence scheduler. |
| `NarwhalIPC` | Unix socket client/server transport. |
| `NarwhalCtl` | CLI wrapper around IPC DTOs. |
| `CLua` | Minimal C shim around Lua 5.4 APIs used by the Swift loader. |

## Boundary Diagram

```text
Hotkeys / CLI / IPC / AX / Display / Space / Lua / Files
                      |
                      v
                NarwhalApp shell
     reads effects, validates boundaries, logs outcomes
                      |
                      v
                 NarwhalCore
   pure commands, layout, restore, rules, config, focus
                      |
                      v
                NarwhalApp shell
       AX writes, restore save, overlay, menubar status
```

## Domain Data

Key value types:

- `World`: displays, active Space, per-Space display layouts, live windows,
  window-display ownership, observed constraints, pending rules, and config.
- `SpaceState`: display layouts and focused window for one Space.
- `DisplaySpaceState`: BSP tree plus floating window order for one display.
- `Node`: `.void`, `.leaf(WindowID)`, or `.split(Split)`.
- `Split`: axis plus two or more weighted cells.
- `Cell`: positive finite weight plus child node.
- `WindowMetadata`: window identity, bundle/title/role/pid, frame, resizability,
  minimization.
- `Command`: domain command or external event translated into domain form.
- `DesiredLayout`: solved layout and delta that the shell should apply.
- `StoredWorld`: stable restore projection independent of raw runtime window IDs.

Important invariants:

- `Split` has at least two cells.
- `Cell.weight` is finite and positive.
- Config numeric fields are finite and range-checked at parse boundaries.
- Tree operations preserve `.void` leaves unless reset explicitly clears them.
- Non-resizable windows are rejected or force-floated by the core.
- Layout writes are committed to `World` only after AX application succeeds.

## Pure Core

The core is designed around value transformations:

- `apply(_:to:) -> Result<World, CommandError>`
- `pushIntoTree`, `centerIntoTree`, `quarterIntoTree`, `ejectFromTree`
- `resizeSplitInTree`
- `balanceTree`
- `flattenedLayout(of:)`
- `solveLayout(...)`
- `reconcileEnvironment(_:in:)`
- `storedWorld(from:)`
- `restoreWorld(...)`
- `parseConfig(_:)`
- `focusTarget(...)`
- `pollWindowInventory(...)`
- `scheduleEnvironmentRefresh(...)`
- `scheduleRestoreSave(...)`

These functions read only parameters and return values. Local mutation is used
inside some functions for efficient construction, but it does not escape.

## Shell Effects

Allowed shell effects:

| Effect | Location |
|---|---|
| App lifecycle and run loop | `App.swift` |
| Accessibility reads/writes | `AXClient.swift`, `AXObserverService.swift`, `LayoutApplier.swift` |
| Carbon hotkeys | `HotkeyManager.swift` |
| Event tap | `EventTapClient.swift` |
| Display reads | `DisplayClient.swift` |
| Private active Space read | `SpaceClient.swift` |
| Lua execution and decoding | `LuaConfigLoader.swift` |
| File watching | `ConfigFileWatcherService.swift` |
| Restore file read/write | `RestoreManager.swift` |
| IPC sockets | `IPCTransport.swift` |
| Logging | `StartupReporter.swift` |
| Overlay windows | `Overlay.swift` |

Shell code should translate effects into value data before calling the core, and
translate core results into effects after planning.

## Command Flow

For layout commands:

1. Shell verifies Accessibility trust.
2. Shell reads focused or explicit window metadata.
3. Shell reads current displays and active Space.
4. Shell refreshes environment into `WorldActor`.
5. Shell reconciles live window IDs when available.
6. Shell asks `WorldActor` to plan a command.
7. Core returns `CommandPlanResult` with desired layout and planned world.
8. `LayoutApplier` writes frames through AX.
9. If all writes converge, `WorldActor.commit` records planned world plus actual
   applied frames.
10. Restore save is scheduled.

If AX reports minimum-size clamping, the shell records observed constraints,
replans once, and retries. If retry still clamps, the planned layout is not
committed.

## WorldActor

`WorldActor` owns mutable runtime `World` state and layout generation numbers.
It serializes access to the domain state while keeping planning work expressed
as calls into pure core functions.

`WorldActor` does not perform AX, filesystem, IPC, or Lua effects. Those remain
in the shell.

## Restore Architecture

Restore uses two layers:

- Pure projection/remap in `NarwhalCore/Restore.swift`.
- File persistence and save debouncing in `NarwhalAppSupport/RestoreManager.swift`.

Stored restore data uses:

- bundle ID
- title
- role
- duplicate occurrence index
- last known frame
- display slot and display fingerprint

On restore, stored references are matched to live windows. Raw window IDs are not
treated as stable across launches.

## Config Architecture

Config crosses two boundaries:

1. `LuaConfigLoader` executes Lua and decodes it into `LuaConfigData`.
2. `ConfigParsing` validates `LuaConfigData` into immutable `Config`.

The Lua decoder rejects unsupported types, sparse arrays, mixed table/array
keys, cyclic tables, and excessive table depth. The parser validates semantic
rules such as duplicate hotkeys, finite numbers, valid regexes, and valid zone
bounds.

## IPC Architecture

IPC uses a newline-delimited JSON protocol over a per-user Unix socket:

```text
/tmp/narwhal-$(id -u).sock
```

The transport layer is intentionally small:

- `IPCClient` connects and sends DTOs.
- `IPCServer` accepts connections and decodes request lines.
- `IPCCommandDTO` and `IPCReplyDTO` live in the core because they are pure
  protocol values shared by app, CLI, and tests.

The server tracks active client sockets so `stop()` closes the listener and all
active clients. This keeps shutdown ownership explicit.

## Error Model

Expected domain failures use `Result` and domain error enums:

- `CommandError`
- `ConfigError`
- `RestoreError`
- `TreeResizeError`

Shell and infrastructure failures use throwing APIs or shell-specific error
types:

- `StartupConfigError`
- `AXClientError`
- `IPCTransportError`
- `RestoreManagerError`
- `ServiceStartupError`

The shell converts errors to logs or IPC replies at the boundary.

## Concurrency Model

- AppKit-facing code runs on `@MainActor`.
- `WorldActor` serializes domain state mutation.
- Timers schedule back onto `@MainActor`.
- IPC uses detached tasks around blocking Unix socket calls, with explicit socket
  cleanup on shutdown.
- Restore-save scheduling is a pure state machine wrapped by a `@MainActor`
  scheduler.

No retryable core update function performs irreversible I/O.

## Testing Shape

Most tests target the pure core:

- BSP insertion and slot invariants.
- Layout solver and minimum-size behavior.
- Rules and config parsing.
- Focus navigation.
- Restore projection and remap.
- Environment coalescing.
- AX echo suppression.
- IPC DTO shape.

Shell-support tests cover:

- Restore persistence boundary.
- Service lifecycle rollback.
- IPC transport behavior.

Manual and script smoke tests cover AppKit, AX, LaunchAgent, and real process
lifecycle behavior.
