# Sprint Gates

This file defines the checks that prove a phase is complete. Passing tests or
having scripts in the tree is not enough; each gate must have an observable
pass/fail result.

## Sprint 1 MVP Gate

Status: done. Ben accepted the MVP on 2026-05-17. Remaining work in this file is
post-MVP hardening and feature completion.

Sprint 1 is complete only when all five gates pass:

- Full automated Swift test suite passes.
- Local package contains the app executable, CLI, embedded Lua runtime, default
  config, valid app plist, valid LaunchAgent plist, and no broken Lua linkage.
- Local install lifecycle can install into test directories and uninstall the
  installed app and LaunchAgent.
- User LaunchAgent lifecycle can install into the default user paths, start the
  app through launchd, and accept an installed `narwhalctl reset`.
- Manual smoke confirms the packaged app can tile, focus, swap, reset, refresh
  on display/Space changes, and keep the focus border aligned.

## Automated Suite

Command:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
```

Pass criteria:

- The command exits with status 0.
- Every test suite passes.
- Any new test failure blocks the gate, even if the packaging and manual smoke
  gates pass.

Current baseline when this checklist was added: 113 tests in 16 suites.

## Rung 12: Local Package

Commands:

```sh
scripts/build_app_bundle.sh --configuration debug --output .build/narwhal-package-next --replace
find .build/narwhal-package-next -maxdepth 5 -type f | sort
plutil -p .build/narwhal-package-next/Narwhal.app/Contents/Info.plist
plutil -p .build/narwhal-package-next/com.ben.narwhal.plist
otool -L .build/narwhal-package-next/Narwhal.app/Contents/MacOS/NarwhalApp | sed -n '1,4p'
```

Pass criteria:

- `.build/narwhal-package-next/Narwhal.app/Contents/MacOS/NarwhalApp` exists and
  is executable.
- `.build/narwhal-package-next/Narwhal.app/Contents/MacOS/narwhalctl` exists and
  is executable.
- `.build/narwhal-package-next/Narwhal.app/Contents/Frameworks/liblua.dylib`
  exists.
- `.build/narwhal-package-next/Narwhal.app/Contents/Resources/DefaultConfig/init.lua`
  exists.
- `Info.plist` is valid and identifies the `NarwhalApp` executable.
- `com.ben.narwhal.plist` is valid and `ProgramArguments[0]` points at the
  packaged `NarwhalApp` executable.
- `otool -L` shows Lua linked as
  `@executable_path/../Frameworks/liblua.dylib`.

## Rung 13: Local Install Lifecycle

Commands:

```sh
scripts/install_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents --replace --configuration debug
plutil -p .build/install-test/LaunchAgents/com.ben.narwhal.plist
test -x .build/install-test/Applications/Narwhal.app/Contents/MacOS/NarwhalApp
test -x .build/install-test/Applications/Narwhal.app/Contents/MacOS/narwhalctl
test -f .build/install-test/Applications/Narwhal.app/Contents/Resources/DefaultConfig/init.lua
test -f .build/install-test/Applications/Narwhal.app/Contents/Frameworks/liblua.dylib
otool -L .build/install-test/Applications/Narwhal.app/Contents/MacOS/NarwhalApp | sed -n '1,4p'
scripts/uninstall_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents
test ! -e .build/install-test/Applications/Narwhal.app
test ! -e .build/install-test/LaunchAgents/com.ben.narwhal.plist
```

Pass criteria:

- Install command exits with status 0.
- Installed LaunchAgent plist is valid.
- Installed LaunchAgent `ProgramArguments[0]` points at
  `.build/install-test/Applications/Narwhal.app/Contents/MacOS/NarwhalApp`.
- Installed app contains executable `NarwhalApp`, executable `narwhalctl`,
  `Resources/DefaultConfig/init.lua`, and `Frameworks/liblua.dylib`.
- Installed executable links Lua as
  `@executable_path/../Frameworks/liblua.dylib`.
- Uninstall command exits with status 0.
- Uninstall removes the installed app and installed LaunchAgent plist.
- Package scratch files under `.build/install-test/package` may remain; they are
  not installed runtime artifacts.

## Rung 14: User LaunchAgent Smoke

This gate writes to the real user install paths. It should only be run when the
candidate build is intended to become the active local Narwhal instance.

Commands:

```sh
scripts/install_local.sh --replace --configuration debug
plutil -p "$HOME/Library/LaunchAgents/com.ben.narwhal.plist"
launchctl print "gui/$(id -u)/com.ben.narwhal"
"$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl" reset
tail -n 40 "$HOME/Library/Logs/Narwhal/narwhal.log"
```

Pass criteria:

- Install command exits with status 0.
- Installed LaunchAgent plist is valid.
- Installed LaunchAgent `ProgramArguments[0]` points at
  `$HOME/Applications/Narwhal.app/Contents/MacOS/NarwhalApp`.
- `launchctl print` reports `state = running`.
- `launchctl print` reports `program =
  $HOME/Applications/Narwhal.app/Contents/MacOS/NarwhalApp`.
- Installed `narwhalctl reset` exits with status 0 and prints `ok` followed by an
  IPC request ID.
- `~/Library/Logs/Narwhal/narwhal.log` records `IPC reset layout memory`.
- Startup logs show Accessibility trusted, hotkey registration, IPC server,
  display observer, and drag zones ready.

## Manual Smoke Gate

Prerequisites:

- Accessibility permission is granted for the executable being tested.
- Any old `NarwhalApp` process is stopped before starting the candidate build.
- `~/Library/Logs/Narwhal/narwhal.log` is readable while the candidate build runs.

Start one of:

```sh
swift run NarwhalApp
.build/narwhal-package-next/Narwhal.app/Contents/MacOS/NarwhalApp
scripts/install_local.sh --replace --configuration debug
```

Reset state:

```sh
.build/narwhal-package-next/Narwhal.app/Contents/MacOS/narwhalctl reset
```

Equivalent hotkey: `control-option-delete`.

Pass criteria:

- Startup logs show Accessibility trusted and hotkey registration succeeded.
- `control-option-command-H/J/K/L` pushes the focused window into the tree.
- `control-option-H/J/K/L` moves focus between tiled windows.
- `control-option-U/I` cycles through windows outside the current tree.
- `control-option-P` returns to the previously focused window.
- `control-option-shift-H/J/K/L` swaps windows in the requested direction.
- `control-option-shift-command-H/J/K/L` resizes the nearest matching split.
- `control-option-command-return` balances split weights in the active Space.
- `control-option-command-N` moves the focused window to the next display.
- `control-option-Z` undoes the previous layout command.
- `control-option-space` pauses and resumes tiling actions.
- Reset clears the active tree; the next push starts from an empty layout.
- Observed BSP layouts match the documented sequence behavior in
  `layout-sequences-0-6.md`.
- Windows that hit application minimum-size constraints are clamped without
  corrupting the tree or committing a partially failed layout.
- Focus border tracks the focused window and hides or redraws after Space/display
  changes.
- Switching Spaces and connecting or disconnecting a display emits one coalesced
  environment refresh per burst, not a long sequence of redundant refreshes.

Observed gate results:

| Date | Commit | Automated suite | Package gate | Test install gate | User LaunchAgent gate | Manual tiling/focus/swap/reset | Known failures |
|---|---|---|---|---|---|---|---|
| 2026-05-17 | `a80f016` | 113 tests / 16 suites passed | Passed | Passed | Passed: launchctl running PID 23158; installed `narwhalctl reset` returned `ok ipc-AD0BA665-E8B0-48D9-BA9D-D0782146B030` | Not rerun in this gate | None from launch/install gate |

## Rung 15: Config Hot Reload

This is a post-MVP gate. It requires the app to be running with Accessibility
trusted because hotkey rebinding and drag-modifier updates only happen after the
normal app services start.

Commands:

```sh
scripts/smoke_config_hot_reload.sh
```

Pass criteria:

- Startup logs include `Config watcher ready`.
- Editing the active config file logs `Config file changed; reloading`.
- A valid config edit logs `Config reload completed (file watcher)`.
- Hotkeys are rebound to the new keymap without restarting the app.
- Drag modifier, border, HUD, zones, rules, and layout gaps use the reloaded
  config without restarting the app.
- An invalid config edit logs `Config reload failed (file watcher)`.
- After an invalid config edit, the previous hotkeys and drag modifier still
  work. This proves last-good fallback, not just error reporting.

Observed Rung 15 results:

| Date | Commit | Config path | Watcher ready | Valid edit | Invalid edit | Last-good proof | Known failures |
|---|---|---|---|---|---|---|---|
| 2026-05-17 | `2aed5dc` | `/private/tmp/narwhal-hot-reload-smoke/init.lua` | Passed: `Config watcher ready` logged | Passed: `duration_millis` edit logged `Config reload completed (file watcher)`, `Rebound hotkeys`, and `Updated drag-zone modifier to shift` | Passed: invalid Lua logged `Config reload failed (file watcher)` | Passed: process stayed alive and `.build/debug/NarwhalCtl reset` returned `ok ipc-D9598BD7-5D08-4C18-B1EA-120C807241F3` afterward | Hotkey keypress behavior not manually retested in this smoke |

## Rung 16: Startup/Shutdown Smoke

This post-MVP shell gate proves that the app can start all runtime services and
shut down through an IPC command that allows AppKit cleanup to run. The smoke
uses `--restore-state` so it never mutates the installed user restore file.

Commands:

```sh
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- Startup logs show Accessibility trusted, hotkeys registered, AX focus observer,
  display observer, config watcher, IPC server, drag zones, and layout loop.
- Startup logs show the temp restore-state path.
- `narwhalctl reset` returns `ok` and logs `IPC reset layout memory`.
- `narwhalctl quit` returns `ok` and logs `IPC quit requested`.
- `NarwhalApp stopped` is logged.
- The NarwhalApp process exits.
- `/tmp/narwhal-$(id -u).sock` is removed after shutdown.

Observed Rung 16 results:

| Date | Commit | Restore path | Startup services | IPC reset | IPC quit | Shutdown cleanup | Known failures |
|---|---|---|---|---|---|---|---|
| 2026-05-17 | `a33f825` | `/private/tmp/narwhal-startup-shutdown-smoke/state.json` | Passed: Accessibility, hotkeys, AX focus observer, display observer, config watcher, IPC server, drag zones, and layout loop logged | Passed: `NarwhalCtl reset` returned `ok` and logged `IPC reset layout memory` | Passed: `NarwhalCtl quit` returned `ok` and logged `IPC quit requested` | Passed: process exited, `NarwhalApp stopped` logged, and `/tmp/narwhal-501.sock` was removed | None |

## Rung 17: Service Lifecycle Orchestration

This post-MVP shell-support gate removes the partial-startup hole where an
early service could remain live after a later service failed to start.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- Unit tests prove service startup order is exact.
- Unit tests prove normal shutdown stops services in reverse order and is
  idempotent.
- Unit tests prove a later startup failure stops already-started services in
  reverse order and does not start later services.
- `NarwhalApp` startup uses the same service sequence primitive.
- Startup/shutdown smoke still passes, including IPC socket cleanup.

Observed Rung 17 results:

| Date | Commit | Unit lifecycle tests | App startup wiring | Startup/shutdown smoke | Known failures |
|---|---|---|---|---|---|
| 2026-05-17 | `64b421f` | Passed: 3 tests prove exact startup order, reverse-order idempotent shutdown, and reverse-order rollback after `ipc` startup failure | Passed: `NarwhalApp` starts menubar, hotkeys, AX observer, display observer, config watcher, IPC server, and drag zones through `startServiceSequence` | Passed: startup services logged, `narwhalctl reset` and `narwhalctl quit` returned `ok`, process exited, and `/tmp/narwhal-501.sock` was removed | None |

## Rung 18: Startup Failure Rollback Smoke

This post-MVP shell gate proves the actual AppDelegate service chain rolls back
real started services when a later service fails. The smoke injects failure at
`dragZones`, after the IPC socket is live, so socket removal is observable.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_failure_rollback.sh
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- `--debug-fail-service-start dragZones` fails before drag-zone event tap startup.
- Logs show IPC server became ready before the injected failure.
- Logs show `service startup failed at dragZones after starting menubar,
  hotkeys, axObserver, displayObserver, configWatcher, ipcServer`.
- Logs show `Runtime service startup failed; terminating`.
- Logs do not show `Drag zones ready` or `Layout command loop ready`.
- The app process exits.
- `/tmp/narwhal-$(id -u).sock` is removed after rollback.
- Normal startup/shutdown smoke still passes.

Observed Rung 18 results:

| Date | Commit | Failure injection | Rollback proof | Normal startup/shutdown | Known failures |
|---|---|---|---|---|---|
| 2026-05-18 | `11902b2` | Passed: `--debug-fail-service-start dragZones` failed before `Drag zones ready` and before `Layout command loop ready` | Passed: IPC server logged ready, failure logged after `ipcServer`, process exited, and `/tmp/narwhal-501.sock` was removed | Passed: `scripts/smoke_startup_shutdown.sh` still completed reset, quit, process exit, and socket cleanup | None |

## Rung 19: Startup Failure Matrix

This post-MVP shell gate expands Rung 18 from one late failure to every runtime
service boundary. It proves the injected failure runs before the target service
effect and that rollback leaves no running process or IPC socket.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_failure_matrix.sh
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- Matrix covers `menubar`, `hotkeys`, `axObserver`, `displayObserver`,
  `configWatcher`, `ipcServer`, and `dragZones`.
- Each case logs `service startup failed at <service> after starting <exact prior services>`.
- Each case logs `Runtime service startup failed; terminating`.
- No case logs `Drag zones ready` or `Layout command loop ready`.
- Each case exits its `NarwhalApp` process.
- `/tmp/narwhal-$(id -u).sock` is absent after every case.
- The `dragZones` case proves IPC was live before rollback by observing
  `IPC server ready at /tmp/narwhal-$(id -u).sock`.
- Normal startup/shutdown smoke still passes.

Observed Rung 19 results:

| Date | Commit | Matrix cases | Rollback proof | Normal startup/shutdown | Known failures |
|---|---|---|---|---|---|
| 2026-05-18 | `8a667c0` | Passed: `menubar`, `hotkeys`, `axObserver`, `displayObserver`, `configWatcher`, `ipcServer`, and `dragZones` each logged the exact prior-service list | Passed: no case reached `Drag zones ready` or `Layout command loop ready`; every case exited and left `/tmp/narwhal-501.sock` absent; `dragZones` observed IPC ready before rollback | Passed: `scripts/smoke_startup_shutdown.sh` still completed reset, quit, process exit, and socket cleanup | None |

## Rung 20: Restore Persistence Boundary

This post-MVP shell-support gate makes restore JSON persistence a directly
tested boundary. The pure restore model and validation stay in `NarwhalCore`;
filesystem decode/encode lives in `NarwhalAppSupport`.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- `RestoreManager` is owned by `NarwhalAppSupport`, not the executable target.
- Unit tests prove a missing restore file returns `nil`.
- Unit tests prove an unsupported `schemaVersion` returns `nil`.
- Unit tests prove corrupt JSON throws `RestoreManagerError.decodeFailed`.
- Unit tests prove invalid persisted `StoredWorld` throws the exact validation
  failure from `NarwhalCore`.
- Unit tests prove `save(_:)` creates the parent directory and `load()` returns
  the exact saved `StoredWorld`.
- Startup/shutdown smoke still passes with `--restore-state`, proving the app
  still uses the moved restore boundary at runtime.

Observed Rung 20 results:

| Date | Commit | Restore tests | App runtime proof | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `3a5ad57` | Passed: 5 `Restore persistence boundary` tests cover missing file, unsupported schema, corrupt JSON, invalid stored world, and save/load round-trip; full suite passed 123 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` used `/private/tmp/narwhal-startup-shutdown-smoke/state.json`, logged restore miss, saved state on IPC reset, handled IPC quit, exited, and removed the socket | None |

## Rung 21: Debounced Restore Persistence Scheduling

This post-MVP shell-support gate keeps command handling from blocking on restore
JSON writes. Successful outcomes schedule a debounced save of the latest
`StoredWorld`; app-owned quit paths and `applicationWillTerminate` flush any
pending save before exit. Local install/uninstall requests graceful IPC quit
before falling back to `launchctl bootout`, so replacement/removal can use the
same flush path when the running app is responsive.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- Unit tests prove pure scheduler state transitions for latest-wins scheduling,
  stale generation rejection, flush-once, and explicit cancellation.
- Shell tests prove `flushPending()` writes the latest pending save immediately
  and cancels the delayed write.
- Shell tests prove explicit cancellation drops the pending write.
- Shell tests prove a failed save emits an exact failure event and a later
  scheduled flush can still succeed.
- `NarwhalApp` schedules restore persistence after successful command outcomes
  instead of writing synchronously on the main command path.
- App-owned quit paths and AppKit termination flush any pending restore save
  before `NarwhalApp stopped`.
- Local install/uninstall scripts attempt `narwhalctl quit` and wait briefly for
  the IPC socket to disappear before `launchctl bootout`.
- Startup/shutdown smoke still passes with `--restore-state`, proving IPC reset
  schedules restore persistence and IPC quit exits cleanly after the pending
  save is flushed.

Observed Rung 21 results:

| Date | Commit | Scheduler tests | App runtime proof | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `6e7102a` | Passed: 7 restore scheduler tests cover pure latest-wins state, stale timer rejection, flush-once, cancellation, synchronous shell flush of latest save, failed-save event, and later successful flush; full suite passed 130 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` logged IPC reset, IPC quit, `Restore state saved (ipc reset)` to `/private/tmp/narwhal-startup-shutdown-smoke/state.json`, `NarwhalApp stopped`, process exit, and socket removal; `bash -n` passed for install/uninstall; no-launchctl install/uninstall completed | None |
| 2026-05-18 | `55d649a` | Passed: 4 scheduler tests cover latest-wins debounce, immediate flush canceling delayed write, explicit cancellation, failed-save event, and later successful save; full suite passed 127 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` logged IPC reset, IPC quit, `Restore state saved (ipc reset)` to `/private/tmp/narwhal-startup-shutdown-smoke/state.json`, `NarwhalApp stopped`, process exit, and socket removal | None |

## Rung 22: Quarter Drag-Zone Actions

This post-MVP core gate makes configured Lua/API zones with
`insert_as_quarter` executable. The drag hit-test still returns a stable
`.dropAtZone` command; `apply` owns the zone action lookup and maps a quarter
zone to pure BSP insertion.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
```

Pass criteria:

- Pure tree tests prove `.topLeft`, `.topRight`, `.bottomLeft`, and
  `.bottomRight` quarter insertion produce exact corner frames from an empty
  tree.
- Pure tree tests prove quarter insertion preserves durable void lanes and
  repeated insertion splits the corner cell toward the screen center without
  duplicating windows.
- Drop-zone integration tests prove each configured quarter zone applies to the
  exact display corner through `.dropAtZone`.
- Unsupported `.insertAtSubtree` zones still fail with an exact
  `.configInvalid` message.

Observed Rung 22 results:

| Date | Commit | Quarter insertion tests | Drop-zone integration | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `0a4fc40` | Passed: pure tests cover all four empty-tree corners, durable opposite void lanes, and repeated top-left insertion splitting toward center without duplicate occupied windows; full suite passed 134 tests / 18 suites | Passed: configured `.insertAsQuarter` zones for top-left, top-right, bottom-left, and bottom-right each produce exact display-corner frames through `.dropAtZone`; unsupported `.insertAtSubtree([0, 1])` still fails explicitly | None |

## Rung 23: Eject Command

This post-MVP core gate makes the existing `Command.eject` executable instead
of a placeholder. Eject is a tiling-state operation: it removes a tiled window
from the BSP tree, leaves that zone as `.void`, and moves the window into the
display's floating order. It does not close, hide, resize, or delete the live
window metadata.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- `apply(.eject(windowID), to:)` succeeds only for live windows currently tiled
  in the active Space.
- Eject preserves the surrounding zone tree by replacing the ejected leaf with
  `.void`.
- Eject preserves `windows`, `windowDisplay`, `windowConstraints`, and
  `pendingRules` while appending the window once to the display floating order.
- IPC JSON encodes and decodes the stable `{"command":"eject","windowID":...}`
  shape.
- App shell hotkey/config routing and explicit IPC routing plan the same core
  command and hide the focus border when the focused tiled window leaves the
  tiled layout.

Observed Rung 23 results:

| Date | Commit | Core/DTO tests | App smoke | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `006f000` | Passed: exact core tests cover tiled-window eject to floating, preserved `.void` zone slots, preserved metadata/display/constraints/pending rules, already-floating rejection, missing-window rejection, and stable IPC `eject` JSON; full suite passed 137 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` launched `NarwhalApp`, loaded startup config, completed environment refresh, registered 15 hotkeys, brought IPC online, accepted IPC reset and quit, flushed restore state, stopped the app, and removed the socket | None |

## Rung 24: Toggle-Float Command

This post-MVP core gate makes the existing `Command.toggleFloat` executable.
The behavior is deliberately deterministic because the command has no
direction argument: tiled windows use the same transition as eject, while
floating windows re-enter tiling through the center anchor on their current
display.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- Tiled-to-floating toggle preserves the BSP shape by replacing the tiled leaf
  with `.void`, preserves live metadata/display/constraints/pending rules, and
  appends the window once to the display floating order.
- Floating-to-tiled toggle removes the window from the display floating order,
  inserts it with `centerIntoTree`, and produces the exact center-anchor frame.
- Floating-to-tiled toggle can create the active `SpaceState` when the active
  Space is known but has no prior layout memory.
- Floating-to-tiled toggle rejects non-resizable windows with
  `.windowNotResizable`.
- IPC JSON encodes and decodes the stable
  `{"command":"toggleFloat","windowID":...}` shape.
- Hotkey/config and explicit IPC shell routing plan the same core command and
  reuse the existing layout apply, clamp-retry, focus-border, and restore-save
  path.

Observed Rung 24 results:

| Date | Commit | Core/DTO tests | App smoke | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `f14bd27` | Passed: exact core tests cover tiled-to-floating toggle, floating-to-center-tiled toggle, active `SpaceState` creation, non-resizable floating-window rejection, preserved metadata/display/constraints/pending rules, and stable IPC `toggleFloat` JSON; full suite passed 141 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` launched `NarwhalApp`, loaded startup config, completed environment refresh, registered 15 hotkeys, brought IPC online, accepted IPC reset and quit, flushed restore state, stopped the app, and removed the socket | None |

## Rung 25: Explicit Focus Command

This post-MVP gate makes existing `Command.focus` and IPC `focus` executable.
Focus is intentionally not a layout operation: the pure core records active
Space focus state, and the shell performs the AX raise/focus effect.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- `apply(.focus(windowID), to:)` records `SpaceState.focused` without changing
  tree shape, floating order, displays, windows, display ownership,
  constraints, pending rules, or config.
- `apply(.focus(windowID), to:)` can create an empty active `SpaceState` when
  `World.activeSpace` is known.
- Missing windows fail with `.windowNotFound`; missing active Space fails with
  `.activeSpaceUnavailable`.
- IPC JSON encodes and decodes the stable
  `{"command":"focus","windowID":...}` shape.
- Explicit IPC focus refreshes a complete environment snapshot, plans against
  live metadata, calls the existing AX focus path, records the expected focus
  echo, updates the focus border, and returns structured IPC errors on failure.

Observed Rung 25 results:

| Date | Commit | Core/DTO tests | App smoke | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `c2f64d1` | Passed: exact core tests cover focused-state update without layout mutation, empty active `SpaceState` creation, `.windowNotFound`, `.activeSpaceUnavailable`, and stable IPC `focus` JSON; full suite passed 144 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` launched `NarwhalApp`, loaded startup config, completed environment refresh, registered 15 hotkeys, brought IPC online, accepted IPC reset and quit, flushed restore state, stopped the app, and removed the socket; startup logged a transient focused-window AX read error but the gate completed | None |

## Rung 26: Balance Command Core

This post-MVP core gate makes existing `Command.balance(spaceID)` executable
for pure world transitions. Balance is not yet exposed through IPC or default
key bindings because the command surface still needs an explicit active-Space
resolution rule.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- `balanceTree(_:)` recursively resets every split `Cell.weight` to `1`.
- Balance preserves every split axis, cell count, occupied leaf path, and
  `.void` path.
- `apply(.balance(spaceID), to:)` normalizes every display tree in the selected
  Space only.
- Balance preserves floating order, focused window, active Space pointer,
  display inventory, live window metadata, display ownership, observed
  constraints, pending rules, and config.
- Missing Spaces fail with `.spaceNotFound(spaceID)`.

Observed Rung 26 results:

| Date | Commit | Core tests | App smoke | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `de05512` | Passed: exact core tests cover recursive split-weight normalization, preserved occupied and void paths, selected-Space-only application, preserved floating/focus/metadata/display/constraint/pending/config state, and `.spaceNotFound`; full suite passed 147 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` launched `NarwhalApp`, loaded startup config, completed environment refresh, registered 15 hotkeys, brought IPC online, accepted IPC reset and quit, flushed restore state, stopped the app, and removed the socket | None |

## Rung 27: Balance Shell Route

This post-MVP shell gate exposes balance without accepting raw Space IDs from
users. The shell resolves the active Space at execution time after a fresh
environment read.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- IPC JSON encodes and decodes the stable `{"command":"balance"}` shape.
- `IPCCommandDTO.balance.toCommand()` remains `.shellCommandOnly`, because only
  the shell can resolve the current active Space.
- `narwhalctl balance` sends the balance IPC command without requiring a window
  ID or exposing a Space ID.
- Lua config accepts `action = { type = "balance" }` for user-defined hotkeys,
  and the renderer emits the same exact action shape.
- App hotkey/IPC routing refreshes the environment, requires a complete AX
  snapshot, plans `.balance(activeSpace)` through `WorldActor`, applies layout,
  and persists restore state.
- No default balance hotkey is added in this rung.

Observed Rung 27 results:

| Date | Commit | Core/DTO/config tests | App smoke | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `b3d5623` | Passed: exact tests cover stable IPC `balance` JSON, `.shellCommandOnly` active-Space resolution, Lua parser support for `action = { type = "balance" }`, exact Lua renderer output for balance actions, and unchanged default keymap; full suite passed 148 tests / 18 suites | Passed: updated `scripts/smoke_startup_shutdown.sh` launched `NarwhalApp`, loaded startup config with 15 default hotkeys, completed environment refresh, registered hotkeys, brought IPC online, `narwhalctl balance` returned `ok`, logged active-Space resolution and `IPC balance completed`, then accepted IPC reset and quit, flushed restore state, stopped the app, and removed the socket | None |

## Rung 28: Resize-Split Command Core

This post-MVP core gate makes existing
`Command.resizeSplit(windowID, direction, delta)` executable as a pure tree
weight edit. It does not expose any new user-facing key binding by itself.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- `resizeSplitInTree(_:_:delta:_:)` targets the innermost ancestor split with
  a matching axis and adjacent sibling in the requested direction.
- A successful resize transfers weight between the target cell and adjacent
  sibling while preserving total split weight, tree shape, occupied paths,
  `.void` paths, and every unrelated weight.
- Missing windows fail with `.windowNotFound`; missing adjacent siblings fail
  with `.noNeighbor(direction)`; non-finite deltas fail with
  `.nonFiniteDelta`; collapsing weights fail with `.nonPositiveWeight`.
- `apply(.resizeSplit(...), to:)` updates only the selected display tree in the
  active Space and preserves floating order, live metadata, display ownership,
  observed constraints, pending rules, and config.
- Core command failures map to stable `CommandError` values:
  `.windowNotFound`, `.windowNotResizable`, `.windowIsFloating`,
  `.activeSpaceUnavailable`, `.noNeighbor`, `.invalidResizeDelta`, and
  `.resizeWouldCollapseSplit`.

Observed Rung 28 results:

| Date | Commit | Core tests | App smoke | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `0a00be4` | Passed: exact tests cover nearest matching ancestor selection, exact split weight transfer, preserved occupied and void paths, `.windowNotFound`, `.noNeighbor`, `.nonFiniteDelta`, `.nonPositiveWeight`, stable `CommandError` mapping, non-resizable rejection, and min-size-aware flattened frames; full suite passed 155 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` launched `NarwhalApp`, loaded startup config with unchanged 15 default hotkeys, completed environment refresh, registered hotkeys, brought IPC online, accepted IPC balance/reset/quit, flushed restore state, stopped the app, and removed the socket | None |

## Rung 29: Resize-Split Shell Route

This post-MVP shell gate exposes resize-split through IPC, `narwhalctl`, and
Lua-configurable hotkeys without choosing a default global hotkey. The shell
keeps active focus/window lookup and AX writes outside the pure resize core.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
scripts/smoke_config_hot_reload.sh
```

Pass criteria:

- IPC JSON encodes and decodes focused resize as
  `{"command":"resizeSplit","direction":"right","delta":0.25}` and explicit
  resize as the same shape plus `windowID`.
- `IPCCommandDTO.resizeFocused(...).toCommand()` requires a focused
  `WindowID`; explicit resize resolves directly to `.resizeSplit`.
- `narwhalctl resize <direction> --delta <weight>` requires a finite explicit
  delta and optionally accepts `--window WINDOW_ID`.
- Lua config accepts `action = { type = "resize_split", direction = "...",
  delta = ... }`, rejects non-finite deltas at the exact key, and the renderer
  emits the same action shape.
- App hotkey/IPC routing refreshes the environment, plans through
  `WorldActor.planResize`, applies layout through the existing min-size-aware
  `LayoutApplier`, persists restore state after success, and reports
  structured IPC failures.
- No default resize hotkey is added in this rung.

Observed Rung 29 results:

| Date | Commit | Core/DTO/config tests | App smoke | Known failures |
|---|---|---|---|---|
| 2026-05-18 | `0a00be4` | Passed: exact tests cover focused and explicit IPC `resizeSplit` JSON, focused-window resolution failure, explicit `.resizeSplit` resolution, Lua parser support for `resize_split`, exact Lua renderer output, non-finite Lua delta rejection at `keymap[1].action.delta`, CLI build, and unchanged default keymap; full suite passed 155 tests / 18 suites | Passed: `scripts/smoke_startup_shutdown.sh` completed the app shell route startup/IPC lifecycle, and `scripts/smoke_config_hot_reload.sh` proved config watcher reload/last-good behavior still works after adding the resize action parser | None |
