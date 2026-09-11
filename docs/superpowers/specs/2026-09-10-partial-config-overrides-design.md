# Partial Configuration Overrides Design

## Context

Narwhal loads an optional Lua configuration from
`~/.config/narwhal/init.lua`. The current parser requires every top-level
field and every field inside `gaps`, `gaps.outer`, `border`, and `hud`. A user
who wants to change one visual setting must therefore copy the entire bundled
configuration. That copy freezes defaults in the user file and can drift as
Narwhal evolves.

Narwhal should accept partial configuration tables while preserving the exact
meaning of every existing complete configuration.

## Goals

- Let an empty user table, `return {}`, resolve to `Config.default`.
- Let omitted top-level fields inherit their values from `Config.default`.
- Let omitted fields inside `gaps`, `gaps.outer`, `border`, and `hud` inherit
  their corresponding default values.
- Preserve replacement semantics for explicitly supplied collections and
  modifier arrays.
- Preserve current validation, error paths, resource limits, startup behavior,
  and hot-reload failure behavior.
- Document a minimal configuration workflow without creating a personal user
  configuration when no overrides are needed.

## Non-goals

- Merging keymaps by key chord.
- Merging zones by identifier.
- Appending user rules to default rules.
- Adding deletion markers, inheritance flags, or a second configuration file
  format.
- Rewriting existing user configuration files.
- Changing the runtime `Config` model or its default values.

## Configuration Semantics

Absence is the only inheritance signal. If a field is present, Narwhal parses
and validates that value using its existing rules.

### Top-level fields

The following omitted fields inherit from the base configuration:

- `keymap`
- `rules`
- `zones`
- `gaps`
- `border`
- `hud`
- `drag_modifier`

An explicitly supplied `keymap`, `rules`, or `zones` array replaces the base
collection completely. An explicit empty collection therefore clears that
collection. An explicitly supplied `drag_modifier` array also replaces the
base modifier set completely.

### Nested fields

When `gaps`, `border`, or `hud` is supplied as a table, each omitted member
inherits from the corresponding base value:

- `gaps.inner`
- `gaps.outer`
- `gaps.outer.top`
- `gaps.outer.left`
- `gaps.outer.bottom`
- `gaps.outer.right`
- `border.width`
- `border.color`
- `hud.enabled`
- `hud.duration_millis`

For example:

```lua
return {
  gaps = {
    inner = 8,
  },
  border = {
    width = 4,
  },
}
```

This keeps the default outer gaps and border color. Supplying a wrong type or
invalid value still fails at the supplied field's existing path.

### Empty Lua table decoding

Lua does not distinguish an empty object from an empty array. The decoder
currently represents every empty Lua table as `.array([])`, including the root
`return {}` and empty nested objects such as `border = {}`.

At the loader boundary, an empty root array is accepted as an empty root object
and converted to `LuaConfigData(root: [:])`. In object contexts, the parser
accepts `.array([])` as an empty table so `gaps = {}`, `gaps.outer = {}`,
`border = {}`, and `hud = {}` inherit all nested defaults. Non-empty arrays
remain invalid in object contexts. In collection contexts, `.array([])` keeps
its existing meaning and explicitly clears the collection.

## Architecture

`Config` remains the single immutable runtime configuration value. No
`ConfigPatch` type or generic Lua-table merge layer is introduced.

### Pure core

`parseConfig` remains a pure transformation:

```swift
public func parseConfig(
    _ data: LuaConfigData,
    base: Config = .default
) -> Result<Config, ConfigError>
```

`ConfigParser` receives the decoded root and the immutable base config. Its
top-level parse function uses a supplied field when present and otherwise
copies the corresponding base value. The nested gap, border, and HUD parsers
receive their base values and apply the same field-aware rule.

After resolution, existing whole-config validations run against effective
values. Duplicate hotkey validation therefore sees the effective keymap, and
rule-to-zone validation sees the effective rules and zones.

The explicit `base` parameter makes the fallback dependency visible and lets
tests prove inheritance against a non-default base without reading global
state inside parser helpers. Its default value preserves all existing call
sites.

### Imperative shell

`StartupConfigLoader` retains ownership of filesystem reads, source-size
checks, Lua execution, decoded-value limits, and error translation. The Lua
decoder adds only the contextual conversion from an empty root array to an
empty root object; `StartupConfigLoader` then passes decoded `LuaConfigData` to
`parseConfig` through the existing path. Startup and hot reload continue
through the same loader path, so no new effect boundary or mutable state is
added.

```text
user init.lua
    |
    v
[SHELL] read + sandboxed Lua decode + resource limits
    |
    v
LuaConfigData
    |
    v
[CORE] field-aware parse against immutable base Config
    |
    v
Result<Config, ConfigError>
    |
    v
[SHELL] activate config or retain/report previous valid config
```

## Failure Model

Expected configuration failures remain `ConfigError` values returned through
`Result`:

- `wrongType` for a supplied value of the wrong Lua shape;
- `invalidValue` for a supplied value outside domain constraints;
- `missingKey` for required members inside explicitly supplied list entries,
  actions, predicates, zones, and other atomic records.

Omitted inheritable fields no longer produce `missingKey`. Unexpected decoder,
filesystem, or Lua runtime failures remain `StartupConfigError` values at the
shell boundary. No exception/result mixing is introduced.

## State, Concurrency, and Persistence

The parser works only with immutable value types and local values. It creates
no mutable cell, lock, task, actor, queue, or retry loop. The change performs no
persistence migration and writes no user data. Existing hot-reload
serialization and previous-valid-config retention remain unchanged.

## Compatibility and Rollback

This is an expand-only configuration migration:

1. Existing complete configurations parse to the same `Config` values.
2. Missing configuration files still select the built-in default through
   `MissingConfigFilePolicy`.
3. New partial configurations resolve omitted fields from `Config.default`.
4. Explicit empty collections retain their current clearing behavior.

No mixed-version coordination is required because each process parses its own
local file atomically during startup or reload. Older Narwhal versions will
reject a partial configuration rather than silently reinterpret it. Rollback
requires only reverting the parser and documentation changes; there is no data
rollback because Narwhal does not rewrite user configuration files.

## Test Strategy

### Pure parser tests

- An empty root table resolves exactly to `Config.default`.
- A single top-level override inherits every omitted top-level field.
- Partial `gaps`, `gaps.outer`, `border`, and `hud` tables inherit omitted
  nested values.
- Explicit empty `keymap`, `zones`, and `rules` collections remain empty.
- An explicit empty `drag_modifier` remains empty.
- Empty nested object tables inherit all members despite Lua's empty-table
  array/object ambiguity.
- A complete legacy root still resolves to the exact expected `Config`.
- Wrong types and invalid supplied nested values preserve their precise
  `ConfigError` paths.
- A non-default base config proves fallback values come from the explicit base
  parameter rather than hidden global reads.

Relevant invariants are covered by examples rather than property-based tests:
the parser has a small fixed set of fields, and exhaustive field-specific
examples provide clearer regression signals than generated dictionary
combinations. The principal invariant is that replacing any subset of fields
changes only those fields, which the non-default-base test exercises directly.

### Loader integration test

Temporary Lua files containing `return {}`, an empty nested object, and a
minimal non-empty partial table flow through `StartupConfigLoader`. The
assertions cover Lua execution, empty/object table decoding, pure fallback
resolution, explicit collection clearing, and the returned `.userFile` source.

### Verification

- Run focused `NarwhalCoreTests` and `NarwhalAppRuntimeTests` configuration
  suites under command-scoped `/usr/bin/caffeinate -dimsu`.
- Run full `swift test` under the same command-scoped assertion.
- Run the repository compiler/type-check gate.
- Regenerate the Narwhal cheat sheet, assert it remains exactly two pages, and
  visually inspect both rendered pages.

No live Accessibility/window-geometry verification is required because this
change does not touch UI, AX access, geometry, or runtime window coordination.

## Documentation

- Update `docs/configuration.md` to describe omission, nested inheritance, and
  explicit replacement with minimal examples.
- Update `DefaultConfigLua.render` and `DefaultConfig/init.lua` comments so the
  complete default is presented as a reference rather than a required file to
  copy.
- Update the Narwhal configuration section in the reproducible cheat-sheet
  builder and regenerate `~/cheatsheets/narwhal-keybindings.pdf`.

## Production Risks and Mitigations

- **Accidental list merging:** collection fields use explicit replacement only,
  covered by empty and custom-list tests.
- **Validation against stale defaults:** cross-field validation runs after all
  effective values are resolved.
- **Hidden dependency on global defaults:** the base `Config` is an explicit
  parser input and is replaceable in tests.
- **Decoder ambiguity for `{}`:** the loader converts an empty root array to an
  empty root object, object parsers accept only an empty array as an empty
  object, and integration tests exercise both paths through real Lua.
- **Documentation drift:** the bundled default-render equality test remains in
  place, and the user guide describes semantics rather than duplicating the
  whole default.

## De-slop Check

The implementation should add no new service, manager, protocol, persistence
type, generic merge engine, config version flag, or compatibility adapter. The
existing `Config`, parser, loader, and test files are sufficient. Helpers are
introduced only when they express field-aware fallback at more than one parse
site or keep exact error paths readable.
