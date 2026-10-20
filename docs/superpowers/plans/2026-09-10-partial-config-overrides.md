# Partial Configuration Overrides Implementation Plan

> **Status: implemented** (f585818, 82d114a, the docs in 277bfa3, and the parsing correction in c631679). Kept as a historical record;
> [docs/architecture.md](../../architecture.md) describes the current code.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow Narwhal Lua configuration files to omit unchanged top-level and nested object fields while preserving all existing replacement and validation behavior.

**Architecture:** Keep `Config` as the single immutable runtime value and make `parseConfig` resolve supplied fields against an explicit base `Config`. Keep filesystem and Lua execution in `StartupConfigLoader`; add only the contextual empty-root conversion required by Lua's ambiguous `{}` representation.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Lua 5.5 through `CLua`, ReportLab/pypdf for the existing cheat-sheet generator.

**Spec:** `docs/superpowers/specs/2026-09-10-partial-config-overrides-design.md`

## Global Constraints

- Absence is the only inheritance signal.
- Present `keymap`, `rules`, `zones`, and `drag_modifier` values replace completely; explicit empty values remain empty.
- Missing members of `gaps`, `gaps.outer`, `border`, and `hud` inherit from the corresponding base value.
- Existing complete configs must resolve to the same `Config` values and retain exact validation paths.
- Do not add keymap merging, zone merging, rule appending, deletion markers, version flags, or a second config model.
- Do not create `~/.config/narwhal/init.lua`; the user has no overrides to add.
- Keep imports at the top of each Swift or Python module.
- Run every Swift test command under a command-scoped `/usr/bin/caffeinate -dimsu` assertion.
- No live Accessibility or geometry suite is required because the change does not affect UI, AX access, or window layout behavior.

## File Map

- `Sources/NarwhalCore/ConfigParsing.swift` — pure field-aware resolution and validation against an immutable base config.
- `Tests/NarwhalCoreTests/ConfigTests.swift` — exact inheritance, replacement, compatibility, and failure-path examples.
- `Sources/NarwhalAppRuntime/LuaConfigLoader.swift` — contextual conversion of an empty root Lua table into an empty config object.
- `Tests/NarwhalAppRuntimeTests/LuaConfigLoaderTests.swift` — real Lua decoding and loader-boundary integration coverage.
- `Sources/NarwhalCore/Config.swift` — update the generated full-reference comment only.
- `DefaultConfig/init.lua` — regenerated full reference kept equal to `DefaultConfigLua.render(.default)`.
- `docs/configuration.md` — public omission, nested inheritance, and list replacement semantics.
- `/Users/ben/cheatsheets/build_navigation_cheatsheets.py` — update the Narwhal sheet's configuration guidance.
- `/Users/ben/cheatsheets/narwhal-keybindings.pdf` — regenerated two-page artifact.

---

### Task 1: Resolve Partial Config Values in the Pure Parser

**Files:**
- Modify: `Tests/NarwhalCoreTests/ConfigTests.swift`
- Modify: `Sources/NarwhalCore/ConfigParsing.swift`

**Interfaces:**
- Consumes: `LuaConfigData`, immutable `Config`, and all existing field parsers.
- Produces: `parseConfig(_:base:) -> Result<Config, ConfigError>` with `base` defaulting to `.default`.
- Preserves: the existing `parseConfig(_:)` call form through the default parameter.

- [ ] **Step 1: Add failing tests for empty and top-level partial configs**

Add these tests inside `ConfigTests`:

```swift
@Test("Empty Lua config inherits the complete default")
func emptyLuaConfigInheritsDefault() throws {
    let config = try parseConfig(LuaConfigData(root: [:])).get()

    #expect(config == Config.default)
}

@Test("A supplied top-level collection replaces while omitted fields inherit")
func suppliedTopLevelCollectionReplacesWhileOmittedFieldsInherit() throws {
    let data = LuaConfigData(root: ["keymap": .array([])])

    let config = try parseConfig(data).get()

    #expect(config.keymap.isEmpty)
    #expect(config.rules == Config.default.rules)
    #expect(config.zones == Config.default.zones)
    #expect(config.gaps == Config.default.gaps)
    #expect(config.border == Config.default.border)
    #expect(config.hud == Config.default.hud)
    #expect(config.dragModifier == Config.default.dragModifier)
}
```

- [ ] **Step 2: Run the focused core tests and verify the new cases fail**

Run:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  /usr/bin/caffeinate -dimsu \
  swift test --disable-sandbox --filter ConfigTests
```

Expected: both new tests fail with missing top-level config keys, beginning with `keymap` for the empty root and `zones` for the keymap-only root.

- [ ] **Step 3: Add the explicit base config and top-level fallback resolution**

Change the parser entry point and `ConfigParser` header to:

```swift
public func parseConfig(
    _ data: LuaConfigData,
    base: Config = .default
) -> Result<Config, ConfigError> {
    do {
        return .success(try ConfigParser(root: data.root, base: base).parse())
    } catch let error as ConfigError {
        return .failure(error)
    } catch {
        return .failure(.invalidValue(key: "root", reason: String(describing: error)))
    }
}

private struct ConfigParser {
    let root: [String: LuaValue]
    let base: Config
```

Add one reusable pure helper inside `ConfigParser`:

```swift
private func override<Value>(
    _ value: LuaValue?,
    inheriting fallback: Value,
    parse: (LuaValue) throws -> Value
) throws -> Value {
    guard let value else { return fallback }
    return try parse(value)
}
```

Replace `parse()` with field-aware resolution:

```swift
func parse() throws -> Config {
    let keymap = try override(root["keymap"], inheriting: base.keymap, parse: parseKeymap)
    let zones = try override(root["zones"], inheriting: base.zones, parse: parseZones)
    let rules = try override(root["rules"], inheriting: base.rules, parse: parseRules)
    let config = Config(
        keymap: keymap,
        rules: rules,
        zones: zones,
        gaps: try parseGaps(root["gaps"], base: base.gaps),
        border: try parseBorder(root["border"], base: base.border),
        hud: try parseHUD(root["hud"], base: base.hud),
        dragModifier: try override(
            root["drag_modifier"],
            inheriting: base.dragModifier
        ) { try parseModifiers($0, key: "drag_modifier") },
        managedRules: base.managedRules
    )
    try validateNoDuplicateHotkeys(config.keymap)
    try validateRuleActions(config.rules, zones: config.zones)
    return config
}
```

Remove the now-unused top-level `required(_ key: String)` helper. Keep the existing record-level `required(_:in:path:)` helper because list entries and action records remain atomic.

- [ ] **Step 4: Run the focused core tests and verify the top-level cases pass**

Run the command from Step 2.

Expected: the two new tests pass and the existing `ConfigTests` remain green.

- [ ] **Step 5: Add failing tests for nested inheritance, explicit clears, and a non-default base**

Add:

```swift
@Test("Nested config tables inherit omitted members")
func nestedConfigTablesInheritOmittedMembers() throws {
    let data = LuaConfigData(root: [
        "gaps": .table([
            "inner": .number(8),
            "outer": .table(["left": .number(6)])
        ]),
        "border": .table(["width": .number(4)]),
        "hud": .table(["enabled": .bool(false)])
    ])

    let config = try parseConfig(data).get()

    #expect(config.gaps == Gaps(
        inner: 8,
        outer: Insets(top: 0, left: 6, bottom: 0, right: 0)
    ))
    #expect(config.border == BorderConfig(width: 4, colorHex: Config.default.border.colorHex))
    #expect(config.hud == HUDConfig(
        enabled: false,
        durationMillis: Config.default.hud.durationMillis
    ))
}

@Test("Empty object tables inherit all nested members")
func emptyObjectTablesInheritAllNestedMembers() throws {
    let data = LuaConfigData(root: [
        "gaps": .array([]),
        "border": .array([]),
        "hud": .array([])
    ])

    let config = try parseConfig(data).get()

    #expect(config.gaps == Config.default.gaps)
    #expect(config.border == Config.default.border)
    #expect(config.hud == Config.default.hud)
}

@Test("All explicit empty collections replace inherited values")
func allExplicitEmptyCollectionsReplaceInheritedValues() throws {
    let data = LuaConfigData(root: [
        "keymap": .array([]),
        "zones": .array([]),
        "rules": .array([]),
        "drag_modifier": .array([])
    ])

    let config = try parseConfig(data).get()

    #expect(config.keymap.isEmpty)
    #expect(config.zones.isEmpty)
    #expect(config.rules.isEmpty)
    #expect(config.dragModifier.isEmpty)
}

@Test("Partial parsing inherits from the explicit base config")
func partialParsingInheritsFromExplicitBaseConfig() throws {
    let base = Config(
        keymap: [],
        rules: [],
        zones: [],
        gaps: Gaps(inner: 9, outer: Insets(top: 1, left: 2, bottom: 3, right: 4)),
        border: BorderConfig(width: 5, colorHex: "#112233"),
        hud: HUDConfig(enabled: false, durationMillis: 900),
        dragModifier: [.control]
    )
    let data = LuaConfigData(root: [
        "hud": .table(["duration_millis": .number(250)])
    ])

    let config = try parseConfig(data, base: base).get()

    #expect(config.keymap == base.keymap)
    #expect(config.rules == base.rules)
    #expect(config.zones == base.zones)
    #expect(config.gaps == base.gaps)
    #expect(config.border == base.border)
    #expect(config.hud == HUDConfig(enabled: false, durationMillis: 250))
    #expect(config.dragModifier == base.dragModifier)
}

@Test("Invalid supplied nested member preserves its exact error path")
func invalidSuppliedNestedMemberPreservesExactErrorPath() {
    let data = LuaConfigData(root: [
        "border": .table(["width": .string("wide")])
    ])

    #expect(parseConfig(data) == .failure(
        .wrongType(key: "border.width", expected: "number")
    ))
}
```

- [ ] **Step 6: Run the focused tests and verify nested cases fail for the intended reasons**

Run the command from Step 2.

Expected: nested partial tests fail on missing nested keys, and empty nested object tables fail their table-shape checks. The explicit collection test may pass only after Step 3; that is acceptable because it separately protects replacement semantics.

- [ ] **Step 7: Implement field-aware nested parsing and contextual empty-object handling**

Change the object-table helper so Lua's empty table is accepted only as an empty object when a parser requests an object:

```swift
private func table(_ value: LuaValue, key: String) throws -> [String: LuaValue] {
    switch value {
    case .table(let table):
        return table
    case .array(let values) where values.isEmpty:
        return [:]
    default:
        throw ConfigError.wrongType(key: key, expected: "table")
    }
}
```

Replace the nested parsers with optional-value/base-value forms. The gap parser must implement every leaf explicitly:

```swift
private func parseGaps(_ value: LuaValue?, base: Gaps) throws -> Gaps {
    guard let value else { return base }
    let gapTable = try table(value, key: "gaps")
    let outer = try gapTable["outer"].map {
        try table($0, key: "gaps.outer")
    } ?? [:]
    return Gaps(
        inner: try override(gapTable["inner"], inheriting: base.inner) {
            try boundedNumber($0, key: "gaps.inner", min: 0, max: Gaps.maximumLength)
        },
        outer: Insets(
            top: try override(outer["top"], inheriting: base.outer.top) {
                try gapLength($0, key: "gaps.outer.top")
            },
            left: try override(outer["left"], inheriting: base.outer.left) {
                try gapLength($0, key: "gaps.outer.left")
            },
            bottom: try override(outer["bottom"], inheriting: base.outer.bottom) {
                try gapLength($0, key: "gaps.outer.bottom")
            },
            right: try override(outer["right"], inheriting: base.outer.right) {
                try gapLength($0, key: "gaps.outer.right")
            }
        )
    )
}
```

Implement border and HUD with the same explicit field rule:

```swift
private func parseBorder(_ value: LuaValue?, base: BorderConfig) throws -> BorderConfig {
    guard let value else { return base }
    let values = try table(value, key: "border")
    let color = try override(values["color"], inheriting: base.colorHex) {
        try string($0, key: "border.color")
    }
    guard isHexRGB(color) else {
        throw ConfigError.invalidValue(key: "border.color", reason: "expected #RRGGBB")
    }
    return BorderConfig(
        width: try override(values["width"], inheriting: base.width) {
            try boundedNumber($0, key: "border.width", min: 0, max: BorderConfig.maximumWidth)
        },
        colorHex: color
    )
}

private func parseHUD(_ value: LuaValue?, base: HUDConfig) throws -> HUDConfig {
    guard let value else { return base }
    let values = try table(value, key: "hud")
    return HUDConfig(
        enabled: try override(values["enabled"], inheriting: base.enabled) {
            try bool($0, key: "hud.enabled")
        },
        durationMillis: try override(
            values["duration_millis"],
            inheriting: base.durationMillis
        ) {
            try boundedInt(
                $0,
                key: "hud.duration_millis",
                min: 0,
                max: HUDConfig.maximumDurationMillis
            )
        }
    )
}
```

- [ ] **Step 8: Run focused and full core tests**

Run:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  /usr/bin/caffeinate -dimsu \
  swift test --disable-sandbox --filter ConfigTests
```

Then:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  /usr/bin/caffeinate -dimsu \
  swift test --disable-sandbox --filter NarwhalCoreTests
```

Expected: both commands pass with zero skipped or failed tests.

- [ ] **Step 9: Review the parser diff for scope and commit**

Run:

```bash
git diff --check
git diff -- Sources/NarwhalCore/ConfigParsing.swift Tests/NarwhalCoreTests/ConfigTests.swift
```

Confirm there is no generic deep-merge layer, no collection merging, and no change to existing record-level required fields. Then commit:

```bash
git add Sources/NarwhalCore/ConfigParsing.swift Tests/NarwhalCoreTests/ConfigTests.swift
git commit -m "feat: support partial config overrides"
```

---

### Task 2: Accept Empty Root Tables Through the Real Lua Boundary

**Files:**
- Modify: `Tests/NarwhalAppRuntimeTests/LuaConfigLoaderTests.swift`
- Modify: `Sources/NarwhalAppRuntime/LuaConfigLoader.swift`

**Interfaces:**
- Consumes: Task 1's `parseConfig(_:base:)` behavior and `LuaValue.array([])` representation.
- Produces: `LuaConfigDecoder.decode() -> LuaConfigData` that treats only an empty root array as an empty root object.
- Preserves: resource budgets, non-empty root-array rejection, config source reporting, and all loader error variants.

- [ ] **Step 1: Add a loader-test success helper and three failing integration tests**

Inside `LuaConfigLoaderTests`, add:

```swift
@Test("Empty Lua table loads the complete default config")
func emptyLuaTableLoadsDefaultConfig() throws {
    let loaded = try loadUserConfig("return {}")

    #expect(loaded.config == Config.default)
}

@Test("Empty nested object inherits its default members")
func emptyNestedObjectInheritsDefaultMembers() throws {
    let loaded = try loadUserConfig("return { border = {} }")

    #expect(loaded.config == Config.default)
}

@Test("Real Lua partial config overrides fields and clears explicit collections")
func realLuaPartialConfigOverridesAndClears() throws {
    let loaded = try loadUserConfig("""
    return {
      keymap = {},
      border = { width = 4 },
    }
    """)

    #expect(loaded.config.keymap.isEmpty)
    #expect(loaded.config.border == BorderConfig(
        width: 4,
        colorHex: Config.default.border.colorHex
    ))
    #expect(loaded.config.zones == Config.default.zones)
}

private func loadUserConfig(_ contents: String) throws -> StartupConfigLoad {
    let url = try writeTemporaryConfig(contents)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let loaded = try StartupConfigLoader(
        configURL: url,
        missingFilePolicy: .fail
    ).load().get()
    #expect(loaded.source == .userFile(url))
    return loaded
}
```

Add `import NarwhalCore` at the top of the test module beside the existing imports; do not place it inside a test or helper.

- [ ] **Step 2: Run the loader suite and verify the root test fails at decode**

Run:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  /usr/bin/caffeinate -dimsu \
  swift test --disable-sandbox --filter LuaConfigLoaderTests
```

Expected: `emptyLuaTableLoadsDefaultConfig` fails with `config must return a table`. The nested and explicit-clear tests cannot pass until Task 1 is present.

- [ ] **Step 3: Implement the narrow empty-root conversion**

Replace the root guard in `LuaConfigDecoder.decode()` with an exhaustive switch:

```swift
let root: [String: LuaValue]
switch value {
case .table(let values):
    root = values
case .array(let values) where values.isEmpty:
    root = [:]
default:
    throw StartupConfigError.luaDecodeFailed(
        path: url.path,
        message: "config must return a table"
    )
}
return LuaConfigData(root: root)
```

Do not change `decodeTable`; empty collection fields must continue decoding as `.array([])`.

- [ ] **Step 4: Run loader and startup/runtime config tests**

Run the command from Step 2, then:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  /usr/bin/caffeinate -dimsu \
  swift test --disable-sandbox --filter StartupArgumentsTests
```

Expected: both commands pass with zero skipped or failed tests. Existing resource-limit and sparse-table rejection tests must remain green.

- [ ] **Step 5: Review the boundary diff and commit**

Run:

```bash
git diff --check
git diff -- Sources/NarwhalAppRuntime/LuaConfigLoader.swift Tests/NarwhalAppRuntimeTests/LuaConfigLoaderTests.swift
```

Confirm the decoder change applies only to the root and does not weaken depth, memory, instruction, source-size, dense-array, cyclic-table, or key-type validation. Then commit:

```bash
git add Sources/NarwhalAppRuntime/LuaConfigLoader.swift Tests/NarwhalAppRuntimeTests/LuaConfigLoaderTests.swift
git commit -m "feat: load empty partial config tables"
```

---

### Task 3: Update the Public Configuration Contract and Cheat Sheet

**Files:**
- Modify: `Sources/NarwhalCore/Config.swift`
- Modify: `DefaultConfig/init.lua`
- Modify: `docs/configuration.md`
- Modify: `/Users/ben/cheatsheets/build_navigation_cheatsheets.py`
- Regenerate: `/Users/ben/cheatsheets/narwhal-keybindings.pdf`
- Test: `Tests/NarwhalCoreTests/ConfigTests.swift` (existing render-equality test)

**Interfaces:**
- Consumes: Tasks 1-2's approved inheritance and replacement semantics.
- Produces: synchronized developer docs, generated full reference, and two-page Narwhal PDF.
- Preserves: `DefaultConfigLua.render(.default)` equality with `DefaultConfig/init.lua`.

- [ ] **Step 1: Update the generated reference comment and make the equality test fail**

In `DefaultConfigLua.render`, replace the opening comments with:

```swift
-- Bundled full configuration reference.
-- User configs may include only the fields they override.
```

Run:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  /usr/bin/caffeinate -dimsu \
  swift test --disable-sandbox --filter bundledLuaMirrorsSwiftDefaultConfig
```

Expected: FAIL because `DefaultConfig/init.lua` still has the old comment.

- [ ] **Step 2: Synchronize the bundled Lua reference**

Apply the same two-line comment to `DefaultConfig/init.lua`. Do not alter any rendered default value or list.

Run the focused equality test from Step 1.

Expected: PASS.

- [ ] **Step 3: Rewrite the configuration introduction around partial overrides**

In `docs/configuration.md`:

- Replace “All top-level keys are required” with the exact rules “all top-level fields are optional,” “missing means inherit,” and “present collections replace.”
- Lead with this minimal example:

```lua
return {
  gaps = { inner = 8 },
  border = { width = 4 },
}
```

- State that this inherits the default outer gaps and border color.
- State that `gaps`, `gaps.outer`, `border`, and `hud` merge by named member.
- State that `keymap`, `zones`, `rules`, and `drag_modifier` replace completely when present and that `{}` clears an explicit collection.
- Retain the full example as a reference for every supported field.
- Retain the existing validation and supported-value documentation.

- [ ] **Step 4: Update the Narwhal cheat-sheet source**

In `/Users/ben/cheatsheets/build_navigation_cheatsheets.py`, replace the current configuration rows that say all top-level keys are required with concise rows covering:

```text
return {}|Use all built-in defaults
Missing field|Inherit its built-in value
gaps / border / hud|Omitted nested members inherit
keymap / zones / rules|Present collection replaces completely
Explicit {} list|Clear that collection
Hot reload failure|Previous valid config stays active
```

Keep the current three-column visual system and the `2 / 2` page count.

- [ ] **Step 5: Regenerate and structurally validate the Narwhal PDF**

Immediately before PDF authoring, run the installed PDF skill's marker exactly once. The builder emits three PDFs, even though only the Narwhal output changes:

```bash
node /Users/ben/.codex/plugins/cache/openai-primary-runtime/pdf/26.905.11957/skills/pdf/container_tools/mark_artifact_operation_started.mjs \
  --operation-kind edit \
  --expected-output-count 3 \
  --output-format pdf
```

Then run:

```bash
uv run --with reportlab --with pypdf \
  python /Users/ben/cheatsheets/build_navigation_cheatsheets.py
pdfinfo /Users/ben/cheatsheets/narwhal-keybindings.pdf
pdftotext -layout /Users/ben/cheatsheets/narwhal-keybindings.pdf - \
  | rg 'Missing field|Present collection replaces|2 / 2'
```

Expected: the builder exits zero, `pdfinfo` reports exactly 2 letter-landscape pages, and extracted text contains the new semantics.

- [ ] **Step 6: Render and visually inspect both Narwhal pages**

Render to a task-specific temporary directory:

```bash
mkdir -p /private/tmp/narwhal-partial-config-pdf
pdftoppm -png -r 140 \
  /Users/ben/cheatsheets/narwhal-keybindings.pdf \
  /private/tmp/narwhal-partial-config-pdf/narwhal
```

Inspect both PNGs at original detail. Require zero clipped rows, overlaps, broken glyphs, illegible wrapping, or footer collisions. Remove only `/private/tmp/narwhal-partial-config-pdf` after inspection.

```bash
rm -rf /private/tmp/narwhal-partial-config-pdf
```

- [ ] **Step 7: Run documentation consistency checks and commit**

Run:

```bash
rg -n 'All top-level keys are required|Copy this file' \
  Sources/NarwhalCore/Config.swift DefaultConfig/init.lua docs README.md
git diff --check
```

Expected: no stale required/copy wording in the scoped configuration docs; `git diff --check` exits zero.

Commit repository-owned files:

```bash
git add Sources/NarwhalCore/Config.swift DefaultConfig/init.lua docs/configuration.md
git commit -m "docs: explain partial config overrides"
```

The cheat-sheet source and PDF live outside this Git repository and must remain uncommitted here.

---

### Task 4: Full Verification and Production Review

**Files:**
- Review: all files changed in Tasks 1-3
- Verify: `/Users/ben/cheatsheets/narwhal-keybindings.pdf`

**Interfaces:**
- Consumes: the three task commits and regenerated external cheat-sheet artifacts.
- Produces: evidence that both old and new config paths pass and no unrelated behavior changed.

- [ ] **Step 1: Run the complete Swift test suite**

Run:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  /usr/bin/caffeinate -dimsu \
  swift test --disable-sandbox
```

Expected: exit zero with no failed or skipped tests. A skipped suite is a failure under repository guidance.

- [ ] **Step 2: Run the compiler gate independently**

Run:

```bash
/usr/bin/env CLANG_MODULE_CACHE_PATH=/private/tmp/narwhal-clang-module-cache \
  swift build --disable-sandbox
```

Expected: exit zero with no compiler errors or warnings introduced by the change.

- [ ] **Step 3: Exercise strict config checking with a real partial file**

Create the exact task-scoped directory:

```bash
mkdir -p /private/tmp/narwhal-partial-config-check
```

Create `/private/tmp/narwhal-partial-config-check/valid.lua` with `apply_patch` and this exact content:

```lua
return {
  gaps = { inner = 8 },
  border = { width = 4 },
}
```

Create `/private/tmp/narwhal-partial-config-check/invalid.lua` with `apply_patch` and:

```lua
return {
  border = { width = "wide" },
}
```

Build a dedicated debug bundle:

```bash
scripts/build_app_bundle.sh \
  --configuration debug \
  --output .build/narwhal-partial-config-check \
  --replace
```

Run the valid boundary check:

```bash
.build/narwhal-partial-config-check/Narwhal.app/Contents/MacOS/NarwhalApp \
  --check-config \
  --config /private/tmp/narwhal-partial-config-check/valid.lua
```

Expected: exit zero.

Run the invalid boundary check and capture its expected error:

```bash
if .build/narwhal-partial-config-check/Narwhal.app/Contents/MacOS/NarwhalApp \
    --check-config \
    --config /private/tmp/narwhal-partial-config-check/invalid.lua \
    > /private/tmp/narwhal-partial-config-check/invalid.log 2>&1; then
  echo "invalid partial config was accepted" >&2
  exit 1
fi
rg 'border.width' /private/tmp/narwhal-partial-config-check/invalid.log
```

Expected: the app exits nonzero and the emitted validation error names `border.width`. Remove only `/private/tmp/narwhal-partial-config-check` afterward; retain the ignored `.build` bundle as reusable verification output unless the user requests its removal.

```bash
rm -rf /private/tmp/narwhal-partial-config-check
```

- [ ] **Step 4: Review the actual diff with the FP production-review gate**

Read the required reviewer skill, then inspect:

```bash
git show --stat --oneline HEAD~3..HEAD
git diff HEAD~3..HEAD -- \
  Sources/NarwhalCore/ConfigParsing.swift \
  Sources/NarwhalAppRuntime/LuaConfigLoader.swift \
  Tests/NarwhalCoreTests/ConfigTests.swift \
  Tests/NarwhalAppRuntimeTests/LuaConfigLoaderTests.swift \
  Sources/NarwhalCore/Config.swift \
  DefaultConfig/init.lua \
  docs/configuration.md
```

Require no CRITICAL or HIGH findings. Fix any such finding test-first, rerun the affected focused suite and full test suite, and commit the fix separately. Confirm the de-slop gate: no second config model, generic deep merge, manager, protocol, speculative flag, hidden I/O, mixed failure channel, or unrelated refactor.

- [ ] **Step 5: Run the final evidence gate**

Run:

```bash
git status --short
git log -4 --oneline
pdfinfo /Users/ben/cheatsheets/narwhal-keybindings.pdf \
  | rg '^(Pages|Page size):'
```

Expected: repository status is clean, the task is represented by focused commits, and the PDF reports 2 pages at `792 x 612 pts (letter)`.

Record the residual compatibility fact in the handoff: older Narwhal binaries reject partial files, but no user config was created or rewritten, so rollback has no data migration.
