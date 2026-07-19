# User Guide

Narwhal is a manual tiling window manager for macOS. It does not constantly
repack every visible window. Instead, every window starts floating, and you tile
only the windows you choose.

## Mental Model

Narwhal keeps one persistent BSP zone tree per display in the active macOS Space.
The important ideas are:

- A tiled window occupies a leaf in the tree.
- Empty leaves are real zones, represented as `.void`; closing or ejecting a
  window preserves the surrounding shape.
- Pushing a window into an edge grows that edge's insertion lane.
- Centering a window creates or uses a center column.
- Reset is the operation that intentionally clears layout memory.
- Floating windows are tracked but not resized by layout writes.

This makes the layout behave more like persistent FancyZones than an automatic
dynamic tiler.

## Install

Install the current repo build for the current user:

```sh
scripts/install_local.sh --replace --configuration debug
```

The installer:

- Builds `Narwhal.app`.
- Stages and verifies it before copying it to `~/Applications/Narwhal.app`.
- Retains the replaced build as `~/Applications/Narwhal.app.previous`.
- Leaves Accessibility and Launch at Login unchanged.

Use **Launch at Login** in the Narwhal menu to opt in through macOS Login Items.
Use **Check for Updates…** to check the latest stable GitHub release; Narwhal
opens the release page but never downloads or runs an update.

Uninstall:

```sh
scripts/uninstall_local.sh
```

## First Run

Narwhal requires macOS Accessibility permission because it reads and writes window
positions through Accessibility APIs.

1. Start the app with `scripts/install_local.sh --replace --configuration debug`
   or run `swift run NarwhalApp`.
2. If macOS prompts for Accessibility, grant permission to the executable being
   used.
3. Restart the app after granting permission if macOS does not apply the
   permission immediately.
4. Check logs:

```sh
tail -n 80 "$HOME/Library/Logs/Narwhal/narwhal.log"
```

A healthy startup logs Accessibility trust, hotkey registration, observers, IPC
server startup, drag-zone startup, and `Layout command loop ready`.

The menu remains available when config, restore, or runtime service startup is
degraded. It can retry startup, open the config, open Accessibility settings,
reveal logs, copy diagnostics, or export a privacy-safe support bundle.

## Default Hotkeys

Directions use the Vim-style keys:

- `H`: left
- `J`: down
- `K`: up
- `L`: right

Default bindings:

| Hotkey | Action |
|---|---|
| `control-option-H/J/K/L` | Focus the nearest tiled window in that direction. |
| `control-option-U` | Focus previous non-tiled window in screen order. |
| `control-option-I` | Focus next non-tiled window in screen order. |
| `control-option-P` | Focus the previously focused window. |
| `control-option-shift-H/J/K/L` | Swap focused tiled window with the neighbor in that direction. |
| `control-option-command-H/J/K/L` | Push the focused window into that edge lane. |
| `control-option-command-A` | Cascade reset windows into an offset stack. |
| `control-option-command-C` | Place focused window in the center half. |
| `control-option-command-E` | Pop focused window out of the tile layout. |
| `control-option-command-F` | Open a new Finder window. |
| `control-option-command-M` | Maximize focused window and reset tile memory. |
| `control-option-command-N` | Move the focused window to the next display and tile it in the center. |
| `control-option-command-S` | Shuffle reset resizable windows into random quarter-screen frames. |
| `control-option-shift-command-H/J/K/L` | Resize the nearest matching split by `0.25` weight units. |
| `control-option-command-return` | Balance split weights in the active Space. |
| `control-option-Z` | Undo the last layout command. |
| `control-option-space` | Pause or resume tiling actions. |
| `control-option-/` | Show or hide the command overlay. While open, scroll it with `control-option-J/K`. |
| `control-option-delete` | Reset layout memory. |

Toggle-float is available through configuration or IPC, but it does not ship
with a default hotkey.

## Common Workflows

### Tile A Window

Focus a window, then press:

```text
control-option-command-H
```

The first left push creates a left half with a persistent empty right half.
Repeated pushes into the same edge split that edge lane.

### Move Focus

After two or more windows are tiled, use:

```text
control-option-H/J/K/L
```

Directional focus uses geometry from the current solved layout.

To move through floating or otherwise non-tiled windows, use:

```text
control-option-U/I
```

To return to the previous focused window, use:

```text
control-option-P
```

### Swap Windows

Focus a tiled window and press:

```text
control-option-shift-H/J/K/L
```

Swap exchanges window leaves. It does not rewrite axes, weights, or empty zones.

### Resize And Balance

Focus a tiled window and press:

```text
control-option-shift-command-H/J/K/L
```

Resize changes the nearest matching split weight by `0.25`. Use:

```text
control-option-command-return
```

to normalize all split weights in the active Space.

### Undo A Layout Command

Use:

```text
control-option-Z
```

Undo restores the previous tiled layout. It is one step deep; after undoing, the
next undo toggles back to the layout you just left.

### Move To The Next Display

Use:

```text
control-option-command-N
```

The focused window moves to the next display by display slot order and is tiled
in that display's center lane.

### Pause Tiling

Use:

```text
control-option-space
```

Pause blocks tiling mutations such as push, swap, resize, balance, undo,
toggle-float, and drag-to-tile. Focus movement, the command overlay, config
reload, and reset remain available.

### Reset Layout Memory

Use:

```text
control-option-delete
```

or:

```sh
narwhalctl reset
```

Reset clears BSP trees, floating lists, focus memory, pending rules, and observed
minimum-size constraints. It does not close windows.

### Copy Diagnostics

Choose `Copy Diagnostics` from the Narwhal menu-bar menu to place the current
runtime status on the clipboard as JSON. The report includes health, counts,
queue depth, and aggregate latency, but excludes window titles, application
names, and user paths.

### Drag Into A Zone

Hold the configured drag modifier before mouse-down, drag the focused window,
and release inside one of the configured proportional zones. The default
modifier is `shift`.

The default zones are narrow edge and center regions:

- left half
- right half
- top half
- bottom half
- center

If a point matches zero or multiple zones, the drag is ignored.

The command overlay lists active shortcuts in two columns of titled groups,
including the active drag modifier and configured drop zones. If the overlay is
taller than the available screen space, it shows a scrollbar and
`control-option-J/K` scrolls it while it is open.

## Command Line

The packaged CLI lives at:

```sh
$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl
```

Useful commands:

```sh
narwhalctl status
narwhalctl status --json
narwhalctl reset
narwhalctl push left
narwhalctl push right --window 12345
narwhalctl swap up
narwhalctl resize right --delta 0.25
narwhalctl center --window 12345
narwhalctl balance
narwhalctl quit
```

See [Command reference](commands.md) for all CLI and IPC details.

## Configuration

User config path:

```text
~/.config/narwhal/init.lua
```

If the file is missing, Narwhal uses the built-in default config. The config
watcher hot-reloads valid edits while the app runs. Invalid edits are logged and
the previous in-memory config remains active.

See [Configuration reference](configuration.md).

## Restore State

Narwhal persists restore state by default at:

```text
~/Library/Application Support/narwhal/state.json
```

Restore stores stable window descriptors such as bundle ID, title, role,
occurrence, and last known frame. It does not store raw window IDs as stable
identity, because macOS window IDs change across launches.

Narwhal retains the previous valid snapshot. Invalid state is quarantined with
owner-only permissions and recovered from that backup when possible. A future
schema is preserved untouched for a newer Narwhal build.

You can override the restore path for testing:

```sh
NarwhalApp --restore-state /private/tmp/narwhal-state.json
```

## Troubleshooting Basics

Check Accessibility:

```sh
NarwhalApp --check-accessibility
```

Check config:

```sh
NarwhalApp --check-config
```

Check environment:

```sh
NarwhalApp --check-environment
```

Read logs:

```sh
tail -n 100 "$HOME/Library/Logs/Narwhal/narwhal.log"
```

Common failures:

- `Accessibility not trusted`: grant permission to the exact executable.
- `active Space unavailable`: private CoreGraphics Space symbols are not
  available or returned no active Space.
- `IPC failed`: the app is not running, the socket was removed, or you are using
  a different user ID.
- `layout unsatisfiable`: observed app minimum sizes cannot fit into the current
  display and tree shape.
