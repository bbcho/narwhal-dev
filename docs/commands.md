# Command Reference

WinMgr commands can come from hotkeys, drag zones, the menu bar, `winmgrctl`,
or direct IPC JSON.

## Direction Names

Text commands use:

- `left`
- `right`
- `up`
- `down`

Default key mnemonics:

- `H`: left
- `J`: down
- `K`: up
- `L`: right

## Default Hotkeys

| Hotkey | Command |
|---|---|
| `control-option-H` | Focus left |
| `control-option-J` | Focus down |
| `control-option-K` | Focus up |
| `control-option-L` | Focus right |
| `control-option-U` | Focus previous visible window |
| `control-option-I` | Focus next visible window |
| `control-option-shift-H` | Swap left |
| `control-option-shift-J` | Swap down |
| `control-option-shift-K` | Swap up |
| `control-option-shift-L` | Swap right |
| `control-option-command-H` | Push left |
| `control-option-command-J` | Push down |
| `control-option-command-K` | Push up |
| `control-option-command-L` | Push right |
| `control-option-/` | Show command overlay |
| `control-option-delete` | Reset layout memory |

## Command Overlay

The command overlay lists active hotkey bindings from the current config. Toggle
it with:

```text
control-option-/
```

or configure another hotkey with:

```lua
{ key = "/", modifiers = { "control", "option" }, action = { type = "show_commands" } }
```

The overlay is informational. It does not take mouse or keyboard input.

## CLI

The CLI talks to the app over the per-user Unix socket:

```text
/tmp/winmgr-$(id -u).sock
```

Installed path:

```sh
$HOME/Applications/WinMgr.app/Contents/MacOS/winmgrctl
```

During development:

```sh
swift run WinMgrCtl -- reset
```

### Global Option

```sh
--socket PATH
```

Use a non-default socket path. This is mainly useful for tests.

### `reset`

```sh
winmgrctl reset
```

Clears layout memory and persists an empty restore snapshot.

Aliases:

```sh
winmgrctl reset-layout
winmgrctl resetLayout
```

### `balance`

```sh
winmgrctl balance
```

Refreshes the active environment, requires a complete AX snapshot, normalizes
all split weights in the active Space, applies the solved layout, and persists
restore state.

### `quit`

```sh
winmgrctl quit
```

Asks the app to flush pending restore state and terminate.

### `push`

```sh
winmgrctl push left
winmgrctl push right --window 12345
```

Without `--window`, push uses the focused window. With `--window`, it applies to
the explicit macOS window ID.

### `swap`

```sh
winmgrctl swap up
winmgrctl swap down --window 12345
```

Without `--window`, swap uses the focused window.

### `resize`

```sh
winmgrctl resize right --delta 0.25
winmgrctl resize left --delta -0.5 --window 12345
```

Aliases:

```sh
winmgrctl resize-split right --delta 0.25
winmgrctl resizeSplit right --delta 0.25
```

`--delta` is required and must be finite.

### `center`

```sh
winmgrctl center --window 12345
```

`center` currently requires an explicit window ID in the CLI.

## IPC JSON

The socket protocol is newline-delimited JSON. Each request is one JSON object
ending with `\n`. Each reply is one JSON object ending with `\n`.

Replies:

```json
{"commandID":"ipc-1","status":"ok"}
```

```json
{"code":"window_not_found","commandID":"ipc-2","message":"Window missing","status":"error"}
```

Command forms:

```json
{"command":"push","direction":"left"}
{"command":"push","direction":"left","windowID":12345}
{"command":"swap","direction":"right"}
{"command":"swap","direction":"right","windowID":12345}
{"command":"resizeSplit","direction":"right","delta":0.25}
{"command":"resizeSplit","direction":"right","delta":0.25,"windowID":12345}
{"command":"center","windowID":12345}
{"command":"eject","windowID":12345}
{"command":"toggleFloat","windowID":12345}
{"command":"focusDirection","direction":"up"}
{"command":"focusCycle","direction":"next"}
{"command":"focus","windowID":12345}
{"command":"balance"}
{"command":"resetLayout"}
{"command":"quit"}
```

Focused IPC forms such as `push` without `windowID` are resolved by the app
shell after reading the currently focused window.

## Command Behavior

### Push

Push tiles a resizable window into a persistent edge lane. If the window was
already tiled, its old leaf becomes `.void` before insertion.

Failure cases include:

- Accessibility is not trusted.
- Active Space is unavailable.
- Focused or explicit window cannot be read.
- Window is not resizable.
- Target display is unavailable.
- Solved layout violates observed minimum sizes.
- AX frame write fails.

### Center

Center uses a three-column root when necessary. Repeated center pushes stack
within the center anchor.

### Eject

Eject removes a tiled window from the tree and appends it to the display floating
order. The tree shape is preserved.

### Toggle Float

Toggle float ejects tiled windows and centers floating windows.

### Swap

Swap exchanges window IDs in the tree. It does not change axes, weights, empty
leaves, floating order, or metadata. If the windows are on different displays,
display ownership is exchanged.

### Resize Split

Resize finds the innermost ancestor split in the requested direction family and
transfers weight between the focused cell and the adjacent sibling.

### Balance

Balance sets every split cell weight to `1` in the active Space. It preserves
tree shape and window membership.

### Focus

Directional focus uses the solved layout geometry. Cycle focus walks visible
windows in frame order and wraps.

### Reset

Reset clears all BSP trees, floating lists, focused window memory, pending rules,
and observed minimum-size constraints.
