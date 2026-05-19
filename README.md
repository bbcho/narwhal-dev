# Narwhal

Narwhal is a macOS BSP tiling window manager for people who want manual,
persistent window zones instead of automatic rearrangement. Windows float by
default; a push, drag zone, or IPC command explicitly tiles a window.

The program is built as:

- `NarwhalApp`: menu-bar app, hotkey handler, AX window writer, display/Space
  observer, Lua config loader, restore persistence, and IPC server.
- `narwhalctl`: command-line client for the local Unix socket.
- `NarwhalCore`: pure layout, command, restore, config, rule, focus, and solver
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
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/build_app_bundle.sh --configuration debug --output .build/narwhal-package-next --replace
```

Install for the current user:

```sh
scripts/install_local.sh --replace --configuration debug
```

Control the running app:

```sh
$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl reset
$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl push left
$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl balance
```

Default hotkeys:

- `control-option-H/J/K/L`: focus left/down/up/right.
- `control-option-U/I`: cycle previous/next non-tiled window.
- `control-option-P`: focus the previously focused window.
- `control-option-shift-H/J/K/L`: swap with neighbor.
- `control-option-command-H/J/K/L`: push focused window left/down/up/right.
- `control-option-command-A`: cascade reset windows into an offset stack.
- `control-option-command-C`: place focused window in the center half.
- `control-option-command-E`: pop focused window out of the tile layout.
- `control-option-command-F`: open a new Finder window.
- `control-option-command-M`: maximize focused window and reset tile memory.
- `control-option-command-N`: move focused window to the next display.
- `control-option-command-S`: shuffle reset resizable windows into random quarter-screen frames.
- `control-option-shift-command-H/J/K/L`: resize the nearest split.
- `control-option-command-return`: balance split weights.
- `control-option-Z`: undo the last layout command.
- `control-option-space`: pause or resume tiling actions.
- `control-option-/`: show two-column command overlay. While open, scroll it with `control-option-J/K`.
- `control-option-delete`: reset layout memory.

Logs are written to `/tmp/narwhal.log`. The IPC socket is
`/tmp/narwhal-$(id -u).sock`.
