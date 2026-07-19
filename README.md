# Narwhal

Narwhal is a macOS BSP tiling window manager for people who want manual,
per-Space window zones instead of automatic rearrangement. Windows float by
default; a push, drag zone, or IPC command explicitly tiles a window. Tiled
windows keep their layout per Space, show green tile borders, and remain editable
with normal macOS move and resize gestures.

The program is built as:

- `NarwhalApp`: menu-bar accessory app, hotkey handler, AX window writer,
  display/Space observer, Lua config loader, restore persistence, and IPC
  server.
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
- [Privacy](docs/privacy.md): local data, redaction, support bundles, and the
  user-initiated update request.
- [Release process](docs/release.md): signing, notarization, artifacts, and CI
  credentials.
- [Design notes](design.md): detailed product and layout semantics.
- [Sprint gates](docs/sprint-gates.md): acceptance gates and smoke-test history.

## Quick Start

Prerequisites:

- macOS 26 or newer.
- Swift toolchain compatible with the installed macOS SDK.
- Homebrew Lua 5.5 at `/opt/homebrew/opt/lua/lib/liblua.dylib`.
- Accessibility permission for the executable you run.

Build and test:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache swift test --disable-sandbox
scripts/live_verify_all.sh
scripts/build_app_bundle.sh --configuration debug --output .build/narwhal-package-next --replace
```

Install a development build for the current user:

```sh
scripts/install_local.sh --replace --configuration debug
```

For daily use, prefer a release build:

```sh
scripts/install_local.sh --replace --configuration release
```

The local installer writes `~/Applications/Narwhal.app`. Narwhal runs as a
menu-bar accessory app: look for its menu-bar icon rather than a Dock icon. Use
the **Launch at Login** menu item to opt in through macOS Login Items.

Control the running app:

```sh
$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl status
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
- `control-option-command-S`: shuffle reset resizable windows into random
  quarter-screen frames.
- `control-option-shift-command-H/J/K/L`: resize the nearest split.
- `control-option-command-return`: balance split weights.
- `control-option-Z`: undo the last layout command.
- `control-option-space`: pause or resume tiling actions.
- `control-option-/`: show the command overlay. It uses two columns when there
  is room, switches to one column on narrow screens, and scrolls with
  `control-option-J/K`.
- `control-option-delete`: reset layout memory.

## Runtime Behavior

- Windows are not tiled until you explicitly push, drop, or command them into the
  layout.
- Layout memory is per macOS Space. Switching Spaces should preserve each
  Space's tiled windows and restore the green tile borders when you come back.
- Green borders mark tiled windows. Narwhal keeps them above their target window
  when focus changes and updates them after manual window moves or resizes.
- Focus cycling with `control-option-U/I` walks non-tiled windows in the active
  Space and skips tiled windows.
- Narwhal ignores its own border and overlay windows in window inventory, focus
  cycling, and layout commands.

Config, state, logs, and IPC:

- User config: `~/.config/narwhal/init.lua`. If this file is missing, Narwhal
  uses its built-in defaults.
- Restore state: `~/Library/Application Support/narwhal/state.json`.
- Log file: `~/Library/Logs/Narwhal/narwhal.log`.
- IPC socket: `/tmp/narwhal-$(id -u).sock`.

## Known Limitations

- **Tile borders may appear above unfocused floating windows.** macOS 15+
  silently blocks cross-process window-ordering APIs (`SLSOrderWindow`,
  `CGSOrderWindow`) for apps without a Developer ID and the right
  entitlements. Narwhal's tile-border windows therefore sometimes draw on
  top of unfocused windows that visually overlap a tile, even though the
  intent is to keep them strictly between the tile and any obscuring
  window. The same constraint is why tools like yabai require disabling
  SIP. Workarounds: (a) sign Narwhal with a Developer ID + the relevant
  entitlements, or (b) accept the cosmetic glitch.
- **Some apps cannot be focused via `kAXRaiseAction`.** A small set of
  system apps (notably System Settings) refuses the AX raise action.
  Narwhal detects this on first failure and excludes the offending window
  from focus-cycle candidates for the rest of the session. The window
  remains tileable and usable; it just won't appear in the `control-
  option-I/U` rotation.
- **Accessibility trust may be invalidated by rebuilds.** An ad-hoc rebuild can
  change the code identity macOS associates with Accessibility approval. After
  `scripts/install_local.sh` you may need to toggle Narwhal off and back on in
  System Settings → Privacy & Security → Accessibility. A stable signing
  identity avoids that churn.
