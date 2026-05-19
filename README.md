# WinMgr

WinMgr is a macOS BSP tiling window manager for people who want manual,
persistent window zones instead of automatic rearrangement. Windows float by
default; a push, drag zone, or IPC command explicitly tiles a window.

The program is built as:

- `WinMgrApp`: menu-bar app, hotkey handler, AX window writer, display/Space
  observer, Lua config loader, restore persistence, and IPC server.
- `winmgrctl`: command-line client for the local Unix socket.
- `WinMgrCore`: pure layout, command, restore, config, rule, focus, and solver
  logic.

## Documentation

- [User guide](docs/user-guide.md): install, first run, concepts, hotkeys, and
  daily operation.
- [Configuration reference](docs/configuration.md): full Lua config schema,
  actions, rules, zones, defaults, and examples.
- [Command reference](docs/commands.md): hotkeys, command overlay, CLI, IPC JSON,
  and command behavior.
- [Architecture](docs/architecture.md): module boundaries, pure core, shell
  effects, state flow, persistence, and concurrency model.
- [Operations runbook](docs/operations.md): build, package, install, update,
  uninstall, logs, smoke tests, and troubleshooting.
- [Developer guide](docs/development.md): local setup, test strategy, coding
  conventions, and release checks.
- [Design notes](design.md): detailed product and layout semantics.
- [Sprint gates](docs/sprint-gates.md): acceptance gates and smoke-test history.

## Quick Start

Prerequisites:

- macOS 14 or newer.
- Swift toolchain compatible with the installed macOS SDK.
- Homebrew Lua 5.4 at `/opt/homebrew/opt/lua/lib/liblua.dylib`.
- Accessibility permission for the executable you run.

Build and test:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/winmgr-clang-module-cache swift test --disable-sandbox
scripts/build_app_bundle.sh --configuration debug --output .build/winmgr-package-next --replace
```

Install for the current user:

```sh
scripts/install_local.sh --replace --configuration debug
```

Control the running app:

```sh
$HOME/Applications/WinMgr.app/Contents/MacOS/winmgrctl reset
$HOME/Applications/WinMgr.app/Contents/MacOS/winmgrctl push left
$HOME/Applications/WinMgr.app/Contents/MacOS/winmgrctl balance
```

Default hotkeys:

- `control-option-command-H/J/K/L`: push focused window left/down/up/right.
- `control-option-H/J/K/L`: focus left/down/up/right.
- `control-option-shift-H/J/K/L`: swap with neighbor.
- `control-option-U/I`: cycle previous/next visible window.
- `control-option-/`: show command overlay.
- `control-option-delete`: reset layout memory.

Logs are written to `/tmp/winmgr.log`. The IPC socket is
`/tmp/winmgr-$(id -u).sock`.
