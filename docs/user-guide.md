# User Guide

WinMgr is a manual tiling window manager for macOS. It does not constantly
repack every visible window. Instead, every window starts floating, and you tile
only the windows you choose.

## Mental Model

WinMgr keeps one persistent BSP zone tree per display in the active macOS Space.
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

- Builds `WinMgr.app`.
- Copies it to `~/Applications/WinMgr.app`.
- Writes `~/Library/LaunchAgents/com.ben.winmgr.plist`.
- Starts the LaunchAgent unless `--no-launchctl` is passed.

Uninstall:

```sh
scripts/uninstall_local.sh
```

## First Run

WinMgr requires macOS Accessibility permission because it reads and writes window
positions through Accessibility APIs.

1. Start the app with `scripts/install_local.sh --replace --configuration debug`
   or run `swift run WinMgrApp`.
2. If macOS prompts for Accessibility, grant permission to the executable being
   used.
3. Restart the app after granting permission if macOS does not apply the
   permission immediately.
4. Check logs:

```sh
tail -n 80 /tmp/winmgr.log
```

A healthy startup logs Accessibility trust, hotkey registration, observers, IPC
server startup, drag-zone startup, and `Layout command loop ready`.

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
| `control-option-U` | Focus previous visible window. |
| `control-option-I` | Focus next visible window. |
| `control-option-shift-H/J/K/L` | Swap focused tiled window with the neighbor in that direction. |
| `control-option-command-H/J/K/L` | Push the focused window into that edge lane. |
| `control-option-/` | Show or hide the command overlay. |
| `control-option-delete` | Reset layout memory. |

Balance and resize are available through configuration and `winmgrctl`, but they
do not ship with default hotkeys.

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

### Swap Windows

Focus a tiled window and press:

```text
control-option-shift-H/J/K/L
```

Swap exchanges window leaves. It does not rewrite axes, weights, or empty zones.

### Reset Layout Memory

Use:

```text
control-option-delete
```

or:

```sh
winmgrctl reset
```

Reset clears BSP trees, floating lists, focus memory, pending rules, and observed
minimum-size constraints. It does not close windows.

### Drag Into A Zone

Hold the configured drag modifier, drag a window, and release inside one of the
configured proportional zones. The default modifier is `shift`.

The default zones are narrow edge and center regions:

- left half
- right half
- top half
- bottom half
- center

If a point matches zero or multiple zones, the drag is ignored.

## Command Line

The packaged CLI lives at:

```sh
$HOME/Applications/WinMgr.app/Contents/MacOS/winmgrctl
```

Useful commands:

```sh
winmgrctl reset
winmgrctl push left
winmgrctl push right --window 12345
winmgrctl swap up
winmgrctl resize right --delta 0.25
winmgrctl center --window 12345
winmgrctl balance
winmgrctl quit
```

See [Command reference](commands.md) for all CLI and IPC details.

## Configuration

User config path:

```text
~/.config/winmgr/init.lua
```

If the file is missing, WinMgr uses the built-in default config. The config
watcher hot-reloads valid edits while the app runs. Invalid edits are logged and
the previous in-memory config remains active.

See [Configuration reference](configuration.md).

## Restore State

WinMgr persists restore state by default at:

```text
~/Library/Application Support/winmgr/state.json
```

Restore stores stable window descriptors such as bundle ID, title, role,
occurrence, and last known frame. It does not store raw window IDs as stable
identity, because macOS window IDs change across launches.

You can override the restore path for testing:

```sh
WinMgrApp --restore-state /private/tmp/winmgr-state.json
```

## Troubleshooting Basics

Check Accessibility:

```sh
WinMgrApp --check-accessibility
```

Check config:

```sh
WinMgrApp --check-config
```

Check environment:

```sh
WinMgrApp --check-environment
```

Read logs:

```sh
tail -n 100 /tmp/winmgr.log
```

Common failures:

- `Accessibility not trusted`: grant permission to the exact executable.
- `active Space unavailable`: private CoreGraphics Space symbols are not
  available or returned no active Space.
- `IPC failed`: the app is not running, the socket was removed, or you are using
  a different user ID.
- `layout unsatisfiable`: observed app minimum sizes cannot fit into the current
  display and tree shape.
