# Configuration Reference

Narwhal configuration is a Lua 5.5 file that returns one table.

Default user path:

```text
~/.config/narwhal/init.lua
```

The bundled default lives at:

```text
DefaultConfig/init.lua
```

If the user file is absent, Narwhal uses built-in defaults. If a hot reload fails,
the previous valid config remains active.

Every table is checked against the schema below: a key Narwhal does not define,
such as a misspelled `gap` or `colour`, rejects the config with that key's full
path (for example `border.colour`) instead of being silently ignored.

### Lua environment

Config runs in a restricted Lua: the `base`, `table`, `string`, `math`, and
`utf8` libraries, without `os`, `io`, `require`, `dofile`, or `loadfile`.
Execution is limited to one million instructions and 16 MiB, and catching the
limit error with `pcall` does not extend it. Lua pattern matching
(`string.match`, `string.gmatch`, `string.gsub`, and pattern `string.find`) is
not available because it runs outside the instruction limit; use
`string.find(s, text, init, true)` for a plain search. `load` accepts text only,
and a precompiled (bytecode) config file is rejected.

## Partial Overrides

All top-level fields are optional: missing means inherit, while present collections
replace.

```lua
return {
  gaps = { inner = 8 },
  border = { width = 4 },
}
```

This minimal config inherits the default outer gaps and border color.

`gaps`, `gaps.outer`, `border`, and `hud` merge by named member. Omitted named
members inherit their built-in values.

`keymap`, `zones`, `rules`, and `drag_modifier` replace completely when present.
Use an explicit `{}` to clear one of these collections.

## Full Configuration Reference

Complete configurations remain supported. The skeleton below shows every
top-level field with its default scalar values. Its `keymap = {}` and
`zones = {}` clear those collections, so copying it as-is removes every hotkey
and drag zone; for the complete defaults, copy `DefaultConfig/init.lua`, which
is what the menu's Open Config writes when no user config exists yet.

```lua
return {
  keymap = {},
  gaps = {
    inner = 0,
    outer = { top = 0, left = 0, bottom = 0, right = 0 },
  },
  drag_modifier = { "shift" },
  zones = {},
  border = { width = 2, color = "#4DA3FF" },
  hud = { enabled = true, duration_millis = 700 },
  rules = {},
}
```

## Keymap

`keymap` is an array of hotkey bindings:

```lua
{
  key = "h",
  modifiers = { "control", "option", "command" },
  action = { type = "push", direction = "left" },
}
```

Keys are lowercased during parsing. Supported keys:

- letters `a` to `z` and digits `0` to `9`
- punctuation `-`, `=`, `[`, `]`, `\`, `;`, `'`, `,`, `.`, `/`, and `` ` ``
- `return`, `tab`, `space`, `delete`, `forwarddelete`, `escape`
- `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`
- `f1` to `f12`

Any other key name rejects the config. Letters, digits, and punctuation follow
the active keyboard layout when hotkeys register (at startup and on config
reload): on AZERTY, `key = "a"` is the key labelled A. Switching keyboard
layouts takes effect at the next config reload. If another app already owns a
shortcut, that one binding is skipped with an error in the log and the rest
still register.

Supported modifier names:

- `shift`
- `command` or `cmd`
- `option` or `alt`
- `control` or `ctrl`

Duplicate modifiers inside one binding are rejected. Duplicate key+modifier
bindings are rejected.

## Hotkey Actions

### `push`

Tiles the focused window into an edge lane.

```lua
{ type = "push", direction = "left" }
```

Directions: `left`, `right`, `up`, `down`.

### `center`

Tiles the focused window into the center anchor.

```lua
{ type = "center" }
```

### `eject`

Pops a tiled focused window out to the floating list while preserving the zone tree.

```lua
{ type = "eject" }
```

### `toggle_float`

If focused window is tiled, eject it. If it is floating, tile it into the center
anchor.

```lua
{ type = "toggle_float" }
```

### `swap`

Swaps the focused tiled window with its directional neighbor.

```lua
{ type = "swap", direction = "right" }
```

### `resize_split`

Adjusts the nearest matching split weight for the focused tiled window.

```lua
{ type = "resize_split", direction = "right", delta = 0.25 }
```

`delta` is in weight units, not pixels. It must be finite. A resize that would
make either affected weight non-positive is rejected.

### `focus_direction`

Focuses the nearest tiled neighbor in a direction.

```lua
{ type = "focus_direction", direction = "up" }
```

### `focus_cycle`

Cycles through non-tiled windows in frame order.

```lua
{ type = "focus_cycle", direction = "next" }
```

Directions: `previous`, `next`.

### `focus_previous`

Focuses the previous window in Narwhal's recent focus history.

```lua
{ type = "focus_previous" }
```

### `balance`

Normalizes every split weight in the active Space while preserving tree shape.

```lua
{ type = "balance" }
```

### `shuffle`

Clears tile memory and lays out resizable visible windows as random quarter-screen frames.

```lua
{ type = "shuffle" }
```

### `cascade`

Clears tile memory and lays out resizable visible windows as a down-right offset
stack of quarter-screen frames.

```lua
{ type = "cascade" }
```

### `maximize_reset`

Maximizes the focused window to the display's visible frame and clears tile
memory for the rest of the layout.

```lua
{ type = "maximize_reset" }
```

### `undo_layout`

Restores the previous tiled layout. The undo buffer is one step deep.

```lua
{ type = "undo_layout" }
```

### `move_to_next_display`

Moves the focused window to the next display by display slot order and tiles it
in the center lane.

```lua
{ type = "move_to_next_display" }
```

### `open_finder_window`

Opens a new Finder window rooted at the current user's home folder.

```lua
{ type = "open_finder_window" }
```

### `toggle_pause`

Pauses or resumes layout-mutating tiling actions. Focus movement, command
overlay, config reload, and reset remain available.

```lua
{ type = "toggle_pause" }
```

### `reset_layout`

Clears layout memory.

```lua
{ type = "reset_layout" }
```

### `reload_config`

Reloads the config file.

```lua
{ type = "reload_config" }
```

### `show_commands`

Shows or hides the command overlay. The overlay uses two columns of titled
groups and shows a scrollbar when the content is taller than the available
screen space.

```lua
{ type = "show_commands" }
```

## Gaps

```lua
gaps = {
  inner = 8,
  outer = { top = 4, left = 6, bottom = 8, right = 10 },
}
```

All gap values must be finite and non-negative.

`inner` is split across adjacent tile edges. `outer` is subtracted from the
display visible frame before layout solving.

## Drag Modifier

```lua
drag_modifier = { "shift" }
```

The drag-zone event tap uses this exact modifier set. If the modifier changes
during a drag, the candidate drag is cancelled.

## Zones

`zones` is an array of proportional display regions.

```lua
{
  id = "left-half",
  bounds = { x = 0, y = 0.30, w = 0.20, h = 0.40 },
  action = { type = "insert_as_half", direction = "left" },
}
```

Bounds are normalized to the display visible frame:

- `x`, `y`, `w`, `h` must be finite.
- `x` and `y` must be `>= 0`.
- `w` and `h` must be `> 0`.
- `x + w <= 1`.
- `y + h <= 1`.

Zone IDs must be non-empty and unique.

### Zone Actions

```lua
{ type = "insert_as_half", direction = "left" }
{ type = "insert_as_quarter", corner = "topLeft" }
{ type = "insert_as_center" }
{ type = "insert_at_subtree", path = { 0, 1 } }
```

Corners: `topLeft`, `topRight`, `bottomLeft`, `bottomRight`.

`insert_at_subtree` inserts into the configured tree path. If the path is absent
in the current tree, the command fails explicitly.

## Border

```lua
border = { width = 2, color = "#4DA3FF" }
```

`width` must be finite and non-negative. `color` must be `#RRGGBB`.

## HUD

```lua
hud = { enabled = true, duration_millis = 700 }
```

`duration_millis` must be a non-negative integer that fits in Swift `Int`.

## Rules

Rules are checked in order. The first matching rule wins.

```lua
rules = {
  {
    predicate = { type = "bundle_id", value = "com.apple.finder" },
    action = { type = "force_float" },
  },
}
```

### Predicates

Exact bundle ID:

```lua
{ type = "bundle_id", value = "com.apple.finder" }
```

Bundle regex:

```lua
{ type = "bundle_id_matches", pattern = "^net\\.kovidgoyal\\." }
```

Role:

```lua
{ type = "role", value = "AXDialog" }
```

Title regex:

```lua
{ type = "title_matches", pattern = "scratch" }
```

Composite predicates:

```lua
{
  type = "and",
  predicates = {
    { type = "bundle_id_matches", pattern = "^com\\.example\\." },
    { type = "not", predicate = { type = "title_matches", pattern = "scratch" } },
  },
}
```

`and` and `or` predicate arrays cannot be empty.

### Rule Actions

Force floating:

```lua
{ type = "force_float" }
```

Ignore:

```lua
{ type = "ignore" }
```

Pin to display slot:

```lua
{ type = "pin_to_display", slot = 1 }
```

`slot` must be a non-negative integer that fits in Swift `Int`.

Tile to a configured zone:

```lua
{ type = "tile_to_zone", zone = "center" }
```

`zone` must reference a configured zone ID. Narwhal tracks the opened window,
waits for the coalesced environment refresh to complete, then applies the same
placement action used by drag-to-tile for that zone.

If a rule asks to tile a non-resizable window, the core force-floats it instead.

## Full Example

```lua
return {
  keymap = {
    { key = "h", modifiers = { "control", "option", "command" }, action = { type = "push", direction = "left" } },
    { key = "l", modifiers = { "control", "option", "command" }, action = { type = "push", direction = "right" } },
    { key = "a", modifiers = { "control", "option", "command" }, action = { type = "cascade" } },
    { key = "c", modifiers = { "control", "option", "command" }, action = { type = "center" } },
    { key = "e", modifiers = { "control", "option", "command" }, action = { type = "eject" } },
    { key = "f", modifiers = { "control", "option", "command" }, action = { type = "open_finder_window" } },
    { key = "m", modifiers = { "control", "option", "command" }, action = { type = "maximize_reset" } },
    { key = "n", modifiers = { "control", "option", "command" }, action = { type = "move_to_next_display" } },
    { key = "s", modifiers = { "control", "option", "command" }, action = { type = "shuffle" } },
    { key = "h", modifiers = { "control", "option", "shift", "command" }, action = { type = "resize_split", direction = "left", delta = 0.25 } },
    { key = "l", modifiers = { "control", "option", "shift", "command" }, action = { type = "resize_split", direction = "right", delta = 0.25 } },
    { key = "return", modifiers = { "control", "option", "command" }, action = { type = "balance" } },
    { key = "z", modifiers = { "control", "option" }, action = { type = "undo_layout" } },
    { key = "space", modifiers = { "control", "option" }, action = { type = "toggle_pause" } },
    { key = "r", modifiers = { "control", "option" }, action = { type = "reload_config" } },
    { key = "/", modifiers = { "control", "option" }, action = { type = "show_commands" } },
    { key = "delete", modifiers = { "control", "option" }, action = { type = "reset_layout" } },
  },
  gaps = {
    inner = 8,
    outer = { top = 4, left = 4, bottom = 4, right = 4 },
  },
  drag_modifier = { "shift" },
  zones = {
    { id = "left-half", bounds = { x = 0, y = 0.25, w = 0.22, h = 0.50 }, action = { type = "insert_as_half", direction = "left" } },
    { id = "right-half", bounds = { x = 0.78, y = 0.25, w = 0.22, h = 0.50 }, action = { type = "insert_as_half", direction = "right" } },
    { id = "center", bounds = { x = 0.40, y = 0.35, w = 0.20, h = 0.30 }, action = { type = "insert_as_center" } },
  },
  border = { width = 2, color = "#4DA3FF" },
  hud = { enabled = true, duration_millis = 700 },
  rules = {
    {
      predicate = { type = "role", value = "AXDialog" },
      action = { type = "force_float" },
    },
    {
      predicate = { type = "bundle_id", value = "com.apple.Notes" },
      action = { type = "tile_to_zone", zone = "center" },
    },
  },
}
```
