# Command Reference

Narwhal commands can come from hotkeys, drag zones, the menu bar, `narwhalctl`,
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
| `control-option-U` | Focus previous non-tiled window |
| `control-option-I` | Focus next non-tiled window |
| `control-option-P` | Focus last focused window |
| `control-option-shift-H` | Swap left |
| `control-option-shift-J` | Swap down |
| `control-option-shift-K` | Swap up |
| `control-option-shift-L` | Swap right |
| `control-option-Z` | Undo last layout command |
| `control-option-command-H` | Push left |
| `control-option-command-J` | Push down |
| `control-option-command-K` | Push up |
| `control-option-command-L` | Push right |
| `control-option-command-A` | Cascade reset windows into an offset stack |
| `control-option-command-C` | Place focused window in the center half |
| `control-option-command-E` | Pop focused window out of the tile layout |
| `control-option-command-M` | Maximize focused window and reset tile memory |
| `control-option-command-N` | Move focused window to next display |
| `control-option-command-S` | Shuffle reset windows into random quarter-screen frames |
| `control-option-shift-command-H` | Resize split left |
| `control-option-shift-command-J` | Resize split down |
| `control-option-shift-command-K` | Resize split up |
| `control-option-shift-command-L` | Resize split right |
| `control-option-command-return` | Balance split weights |
| `control-option-space` | Pause or resume tiling actions |
| `control-option-/` | Show command overlay |
| `control-option-delete` | Reset layout memory |

## Command Overlay

The command overlay lists active hotkey bindings from the current config, plus
the active drag modifier and configured drop zones. Toggle it with:

```text
control-option-/
```

or configure another hotkey with:

```lua
{ key = "/", modifiers = { "control", "option" }, action = { type = "show_commands" } }
```

The overlay is informational. It uses two columns of titled command groups. It
does not take mouse input. If content is taller than the overlay, a scrollbar is
shown and `control-option-J/K` scrolls the overlay while it is open.

Rows are grouped by purpose:

- Movement: focus commands.
- Placing Windows: push, center, pop-out, max-reset, toggle-float, and display move commands.
- Dragging Windows: drag-to-tile gesture and zone list.
- Changing Layout: swap, resize, balance, cascade reset, shuffle reset, and undo.
- Overlay: scroll keys for this command list.
- System: pause, reload, overlay, and reset commands.

## CLI

The CLI talks to the app over the per-user Unix socket:

```text
/tmp/narwhal-$(id -u).sock
```

Installed path:

```sh
$HOME/Applications/Narwhal.app/Contents/MacOS/narwhalctl
```

During development:

```sh
swift run NarwhalCtl -- reset
```

### Global Option

```sh
--socket PATH
```

Use a non-default socket path. This is mainly useful for tests.

### `reset`

```sh
narwhalctl reset
```

Clears layout memory and persists an empty restore snapshot.

Aliases:

```sh
narwhalctl reset-layout
narwhalctl resetLayout
```

### `balance`

```sh
narwhalctl balance
```

Refreshes the active environment, requires a complete AX snapshot, normalizes
all split weights in the active Space, applies the solved layout, and persists
restore state.

### `quit`

```sh
narwhalctl quit
```

Asks the app to flush pending restore state and terminate.

### `push`

```sh
narwhalctl push left
narwhalctl push right --window 12345
```

Without `--window`, push uses the focused window. With `--window`, it applies to
the explicit macOS window ID.

### `swap`

```sh
narwhalctl swap up
narwhalctl swap down --window 12345
```

Without `--window`, swap uses the focused window.

### `resize`

```sh
narwhalctl resize right --delta 0.25
narwhalctl resize left --delta -0.5 --window 12345
```

Aliases:

```sh
narwhalctl resize-split right --delta 0.25
narwhalctl resizeSplit right --delta 0.25
```

`--delta` is required and must be finite.

### `center`

```sh
narwhalctl center --window 12345
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

### Undo Layout

Undo restores the previous tiled layout. The undo buffer is one step deep, so
undoing once swaps the current and previous layouts.

### Move To Next Display

Move-to-display sends the focused window to the next display in display slot
order and tiles it in the center lane on that display. With one display, the
command fails because there is no target display.

### Pause Tiling

Pause blocks layout-mutating tiling actions while leaving focus movement, command
overlay, config reload, and reset available. It also suppresses drag previews
and drag-to-tile drops while paused.

### Focus

Directional focus uses the solved layout geometry. Cycle focus walks non-tiled
windows in frame order and wraps. Previous focus uses Narwhal's recent focus
history and does not mutate the layout.

### Reset

Reset clears all BSP trees, floating lists, focused window memory, pending rules,
and observed minimum-size constraints.
