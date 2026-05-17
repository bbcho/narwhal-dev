# Sprint Gates

This file defines the checks that prove a phase is complete. Passing tests or
having scripts in the tree is not enough; each gate must have an observable
pass/fail result.

## Sprint 1 MVP Gate

Sprint 1 is complete only when all four gates pass:

- Full automated Swift test suite passes.
- Local package contains the app executable, CLI, embedded Lua runtime, default
  config, valid app plist, valid LaunchAgent plist, and no broken Lua linkage.
- Local install lifecycle can install into test directories and uninstall the
  installed app and LaunchAgent.
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

## Manual Smoke Gate

Prerequisites:

- Accessibility permission is granted for the executable being tested.
- Any old `WinMgrApp` process is stopped before starting the candidate build.
- `/tmp/winmgr.log` is readable while the candidate build runs.

Start one of:

```sh
swift run WinMgrApp
.build/winmgr-package-next/WinMgr.app/Contents/MacOS/WinMgrApp
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

Record manual results here:

| Date | Commit | Automated suite | Package gate | Install gate | Manual tiling/focus/swap/reset | Known failures |
|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |
