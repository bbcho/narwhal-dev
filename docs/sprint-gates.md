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
  app through launchd, and accept an installed `winmgrctl reset`.
- Manual smoke confirms the packaged app can tile, focus, swap, reset, refresh
  on display/Space changes, and keep the focus border aligned.

## Automated Suite

Command:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/winmgr-clang-module-cache swift test --disable-sandbox
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
scripts/build_app_bundle.sh --configuration debug --output .build/winmgr-package-next --replace
find .build/winmgr-package-next -maxdepth 5 -type f | sort
plutil -p .build/winmgr-package-next/WinMgr.app/Contents/Info.plist
plutil -p .build/winmgr-package-next/com.ben.winmgr.plist
otool -L .build/winmgr-package-next/WinMgr.app/Contents/MacOS/WinMgrApp | sed -n '1,4p'
```

Pass criteria:

- `.build/winmgr-package-next/WinMgr.app/Contents/MacOS/WinMgrApp` exists and
  is executable.
- `.build/winmgr-package-next/WinMgr.app/Contents/MacOS/winmgrctl` exists and
  is executable.
- `.build/winmgr-package-next/WinMgr.app/Contents/Frameworks/liblua.dylib`
  exists.
- `.build/winmgr-package-next/WinMgr.app/Contents/Resources/DefaultConfig/init.lua`
  exists.
- `Info.plist` is valid and identifies the `WinMgrApp` executable.
- `com.ben.winmgr.plist` is valid and `ProgramArguments[0]` points at the
  packaged `WinMgrApp` executable.
- `otool -L` shows Lua linked as
  `@executable_path/../Frameworks/liblua.dylib`.

## Rung 13: Local Install Lifecycle

Commands:

```sh
scripts/install_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents --replace --configuration debug
plutil -p .build/install-test/LaunchAgents/com.ben.winmgr.plist
test -x .build/install-test/Applications/WinMgr.app/Contents/MacOS/WinMgrApp
test -x .build/install-test/Applications/WinMgr.app/Contents/MacOS/winmgrctl
test -f .build/install-test/Applications/WinMgr.app/Contents/Resources/DefaultConfig/init.lua
test -f .build/install-test/Applications/WinMgr.app/Contents/Frameworks/liblua.dylib
otool -L .build/install-test/Applications/WinMgr.app/Contents/MacOS/WinMgrApp | sed -n '1,4p'
scripts/uninstall_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents
test ! -e .build/install-test/Applications/WinMgr.app
test ! -e .build/install-test/LaunchAgents/com.ben.winmgr.plist
```

Pass criteria:

- Install command exits with status 0.
- Installed LaunchAgent plist is valid.
- Installed LaunchAgent `ProgramArguments[0]` points at
  `.build/install-test/Applications/WinMgr.app/Contents/MacOS/WinMgrApp`.
- Installed app contains executable `WinMgrApp`, executable `winmgrctl`,
  `Resources/DefaultConfig/init.lua`, and `Frameworks/liblua.dylib`.
- Installed executable links Lua as
  `@executable_path/../Frameworks/liblua.dylib`.
- Uninstall command exits with status 0.
- Uninstall removes the installed app and installed LaunchAgent plist.
- Package scratch files under `.build/install-test/package` may remain; they are
  not installed runtime artifacts.

## Rung 14: User LaunchAgent Smoke

This gate writes to the real user install paths. It should only be run when the
candidate build is intended to become the active local WinMgr instance.

Commands:

```sh
scripts/install_local.sh --replace --configuration debug
plutil -p "$HOME/Library/LaunchAgents/com.ben.winmgr.plist"
launchctl print "gui/$(id -u)/com.ben.winmgr"
"$HOME/Applications/WinMgr.app/Contents/MacOS/winmgrctl" reset
tail -n 40 /tmp/winmgr.log
```

Pass criteria:

- Install command exits with status 0.
- Installed LaunchAgent plist is valid.
- Installed LaunchAgent `ProgramArguments[0]` points at
  `$HOME/Applications/WinMgr.app/Contents/MacOS/WinMgrApp`.
- `launchctl print` reports `state = running`.
- `launchctl print` reports `program =
  $HOME/Applications/WinMgr.app/Contents/MacOS/WinMgrApp`.
- Installed `winmgrctl reset` exits with status 0 and prints `ok` followed by an
  IPC request ID.
- `/tmp/winmgr.log` records `IPC reset layout memory`.
- Startup logs show Accessibility trusted, hotkey registration, IPC server,
  display observer, and drag zones ready.

## Manual Smoke Gate

Prerequisites:

- Accessibility permission is granted for the executable being tested.
- Any old `WinMgrApp` process is stopped before starting the candidate build.
- `/tmp/winmgr.log` is readable while the candidate build runs.

Start one of:

```sh
swift run WinMgrApp
.build/winmgr-package-next/WinMgr.app/Contents/MacOS/WinMgrApp
scripts/install_local.sh --replace --configuration debug
```

Reset state:

```sh
.build/winmgr-package-next/WinMgr.app/Contents/MacOS/winmgrctl reset
```

Equivalent hotkey: `control-option-delete`.

Pass criteria:

- Startup logs show Accessibility trusted and hotkey registration succeeded.
- `control-option-command-H/J/K/L` pushes the focused window into the tree.
- `control-option-H/J/K/L` moves focus between tiled windows.
- `control-option-U/I` cycles through windows outside the current tree.
- `control-option-shift-H/J/K/L` swaps windows in the requested direction.
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
| 2026-05-17 | `a80f016` | 113 tests / 16 suites passed | Passed | Passed | Passed: launchctl running PID 23158; installed `winmgrctl reset` returned `ok ipc-AD0BA665-E8B0-48D9-BA9D-D0782146B030` | Not rerun in this gate | None from launch/install gate |

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
| 2026-05-17 | `2aed5dc` | `/private/tmp/winmgr-hot-reload-smoke/init.lua` | Passed: `Config watcher ready` logged | Passed: `duration_millis` edit logged `Config reload completed (file watcher)`, `Rebound hotkeys`, and `Updated drag-zone modifier to shift` | Passed: invalid Lua logged `Config reload failed (file watcher)` | Passed: process stayed alive and `.build/debug/WinMgrCtl reset` returned `ok ipc-D9598BD7-5D08-4C18-B1EA-120C807241F3` afterward | Hotkey keypress behavior not manually retested in this smoke |

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
- `winmgrctl reset` returns `ok` and logs `IPC reset layout memory`.
- `winmgrctl quit` returns `ok` and logs `IPC quit requested`.
- `WinMgrApp stopped` is logged.
- The WinMgrApp process exits.
- `/tmp/winmgr-$(id -u).sock` is removed after shutdown.

Observed Rung 16 results:

| Date | Commit | Restore path | Startup services | IPC reset | IPC quit | Shutdown cleanup | Known failures |
|---|---|---|---|---|---|---|---|
| 2026-05-17 | `a33f825` | `/private/tmp/winmgr-startup-shutdown-smoke/state.json` | Passed: Accessibility, hotkeys, AX focus observer, display observer, config watcher, IPC server, drag zones, and layout loop logged | Passed: `WinMgrCtl reset` returned `ok` and logged `IPC reset layout memory` | Passed: `WinMgrCtl quit` returned `ok` and logged `IPC quit requested` | Passed: process exited, `WinMgrApp stopped` logged, and `/tmp/winmgr-501.sock` was removed | None |

## Rung 17: Service Lifecycle Orchestration

This post-MVP shell-support gate removes the partial-startup hole where an
early service could remain live after a later service failed to start.

Commands:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/winmgr-clang-module-cache swift test --disable-sandbox
scripts/smoke_startup_shutdown.sh
```

Pass criteria:

- Unit tests prove service startup order is exact.
- Unit tests prove normal shutdown stops services in reverse order and is
  idempotent.
- Unit tests prove a later startup failure stops already-started services in
  reverse order and does not start later services.
- `WinMgrApp` startup uses the same service sequence primitive.
- Startup/shutdown smoke still passes, including IPC socket cleanup.
