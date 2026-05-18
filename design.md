# WinMgr — Functional Architecture Design

A macOS BSP tiling window manager. Manual push-to-tile, n-ary recursive split, native-Spaces aware, Lua-configurable, mouse-drag + hotkey + IPC controllable.

This is the pre-implementation gate for the fp-architect skill, adapted to Swift. No code may be written until this doc is reviewed clean. Phases reference this doc; the implementation phase does not relitigate decisions made here.

---

## Scope reference (locked)

| Decision | Choice |
|---|---|
| Stack | Swift 5.9 / Swift Concurrency, AppKit, macOS 14+, Swift Testing |
| Tiling model | Manual persistent zone-tree BSP, n-ary cells. Float by default. Push-to-tile only. `.void` leaves are intentional empty zones, like FancyZones cells. |
| Push semantics | Persistent FancyZones-style edge insertion. `H/L` use recursive edge lanes; `K/J` use top/bottom row realms that split horizontally. First push = half-screen + void. |
| Minimum sizes | Pure min-size-aware solver respects observed per-window constraints. Shell infers constraints from AX clamp feedback; unsatisfiable layouts are rejected or handled by explicit fallback policy, never silently committed. |
| Center anchor | Hotkey establishes 3-column root `[1, 2, 1]` weights. Center cell pushes split center vertically (TB stack). |
| Workspaces | Native macOS Spaces. `CGSGetActiveSpace` via `dlsym` (read-only, 1 symbol). One active Space identity is tracked globally; per-display Space identity is deferred because it requires broader private API use. No programmatic Space moves. |
| Restore | Fuzzy match on stable window descriptors `(bundleID, title, role)`. Restore JSON stores descriptors, not raw OS window/display IDs. Native Space pinning is deferred until a stable Space-slot mapping exists. |
| Config | Lua 5.4 embedded via C interop. `~/.config/winmgr/init.lua`. FSEvent hot reload, last-good fallback. |
| Input | Carbon hotkeys + `CGEventTap` shift-drag + Unix-socket IPC + `winmgrctl` CLI. |
| Default key families | `ctrl-option-H/J/K/L` focus, `ctrl-option-shift-H/J/K/L` swap, `ctrl-option-command-H/J/K/L` push, `ctrl-option-U/I` cycle, `ctrl-option-delete` reset. |
| Visuals | Focus border overlay, Space HUD on switch, gaps, NSStatusItem menubar. No animations. |
| Distribution | Notarized `.app` bundle + LaunchAgent + brew cask (later). Private repo. |

---

## Push semantics

Push-to-tile is **persistent FancyZones-style edge insertion** over a persistent zone tree.

The tree is closer to FancyZones than to a dynamic tiler: `.void` leaves are durable empty zones. They are not garbage. Window close, live-window reconciliation, push-reposition, and eject replace a window leaf with `.void` and preserve the surrounding split shape. `resetLayout` is the MVP operation that intentionally deletes all zone memory.

Each direction owns an insertion lane:

| Key | Direction | Lane | Center-facing side |
|---|---|---|---|
| `H` | `.left` | left edge | right / inward |
| `L` | `.right` | right edge | left / inward |
| `K` | `.up` | top edge | down / inward |
| `J` | `.down` | bottom edge | up / inward |

Rules:

1. The first push to an empty tree splits the display into the pushed half plus a `.void` half.
2. A push to an empty lane cell fills that cell.
3. `H/L` use recursive edge lanes. Repeated pushes recurse into the center-facing child created by the previous push.
4. `K/J` use row realms. The top and bottom rows are independent horizontal rows. The second push to a row appends to the row; later pushes insert before the row's inner anchor.
5. Opposite edges keep independent insertion lanes or rows inside the same root split.
6. If the pushed window is already tiled, its old leaf becomes `.void` before reinsertion. The surrounding split is not collapsed. This preserves the vacated lane for later pushes.
7. Live-window reconciliation and explicit eject also preserve split shape by replacing missing/ejected leaves with `.void`.
8. The only MVP operation that discards zone memory is `resetLayout`. A future explicit compact command may collapse orphan splits, but compaction is never implicit.

For left pushes:

```text
H with A:

[A] | void
```

```text
H with B:

[A] | void
[B] |
```

```text
H with C:

[A]    | void
[B][C] |
```

For the sequence `H L H H L` with windows `A B C D E`:

```text
[A]    | [B]
[C][D] | [E]
```

For vertical row realms:

```text
K J K J:

[A][C]
[B][D]
```

```text
K K K J J J:

[A][C][B]
[D][F][E]
```

```text
K J K J K J:

[A][E][C]
[B][F][D]
```

For the sequence `H L J K` with windows `A B C D`, one lane per edge is occupied:

```text
+-------+-------+-------+
|       |   D   |       |
|   A   +-------+   B   |
|       |   C   |       |
+-------+-------+-------+
```

`Axis` means cell layout direction: a horizontal split has cells laid left to right; a vertical split has cells laid top to bottom. The visual split line is perpendicular to that axis.

This rule replaces the earlier "split largest leaf on push side" idea. The tree is not area-greedy and not Dwindle-like; it is directionally stable and zone-preserving. `K/J` are deliberately row-realm operations rather than a pure 90-degree rotation of `H/L`.

---

## Swap semantics

Directional swap exchanges the focused tiled window with the adjacent tiled window selected by the same geometric neighbor rule used for directional focus.

Rules:

1. Swap is bound by default to `ctrl-option-shift-H/J/K/L`.
2. Swap only exchanges the two `WindowID` leaves. It does not change split axes, cell weights, `.void` leaves, or floating lists.
3. The source window remains focused after the swap, now at the neighbor's old tile.
4. If either window is on a different display in the same active Space, their `windowDisplay` ownership is exchanged with the leaves.
5. If the focused window is not tiled, the command fails with `.windowIsFloating`.
6. If there is no tiled neighbor in that direction, the command fails with `.noNeighbor(direction)`.

This makes swap a rearrangement operation, not a new insertion. It must not collapse zone memory or create new voids.

---

## Float Semantics

Floating is tracked per display as back-to-front `WindowID` order. The shell
does not move floating windows during layout writes; it only stops managing
their tiled frame.

Rules:

1. `eject(window)` is one-way: a tiled window leaves the BSP tree, its leaf
   becomes `.void`, and the window is appended once to the display floating
   order.
2. `toggleFloat(window)` is symmetric at the command boundary but still uses
   explicit tree operations:
   - If the window is tiled, it behaves exactly like `eject(window)`.
   - If the window is floating, it is inserted with `centerIntoTree` on its
     current display and removed from the floating order.
3. Floating-to-tiled toggle requires `WindowMetadata.isResizable == true`
   because the next layout write will resize the window. Tiled-to-floating
   toggle does not require resizability because it does not resize the window.
4. Toggle-float does not infer or remember a prior slot. Directional placement
   belongs to push hotkeys and drag zones.

---

## Focus Semantics

Focus is not a layout command. It records intent in `World.spaces[active].focused`
and asks the shell to raise/focus the matching AX window.

Rules:

1. `focus(window)` requires a known live `WindowID` and an active Space.
2. The pure transition may create an empty active `SpaceState` to record focus,
   but it must not change BSP trees, floating order, display ownership,
   constraints, pending rules, or config.
3. The shell must refresh a complete environment snapshot before explicit IPC
   focus so stale window IDs fail as `.windowNotFound`.
4. A successful shell focus call records an expected focus echo and updates the
   focus border using the current tiled frame if available, otherwise the live
   window frame.

---

## Min-size-aware layout solver

macOS apps own their window minimum sizes. Accessibility can request a frame, but it cannot override an app's `NSWindow` or Auto Layout constraints. Finder, for example, may clamp a requested `490.67 px` width to `500 px`.

The layout solver must therefore treat app minimum sizes as **domain constraints**, not shell trivia.

### Data model

```swift
struct WindowConstraints: Equatable, Codable, Sendable {
    let minWidth: Double?
    let minHeight: Double?
}

struct LayoutAdjustment: Equatable, Sendable {
    let windowID: WindowID
    let requested: CGRect
    let adjusted: CGRect
    let reason: LayoutAdjustmentReason
}

enum LayoutAdjustmentReason: Equatable, Sendable {
    case minimumWidth(Double)
    case minimumHeight(Double)
}

struct UnsatisfiableLayout: Equatable, Sendable {
    let displayID: DisplayID
    let axis: Axis
    let available: Double
    let required: Double
    let windows: [WindowID]
}

enum LayoutSolveStatus: Equatable, Sendable {
    case exact
    case adjusted([LayoutAdjustment])
}

enum LayoutSolveResult: Equatable, Sendable {
    case solved(layout: Layout, status: LayoutSolveStatus)
    case unsatisfiable(UnsatisfiableLayout)
}
```

`World` owns observed constraints:

```swift
let windowConstraints: [WindowID: WindowConstraints]
```

Constraint values are finite positive point sizes. `inferObservedConstraints` discards non-finite, zero, or negative dimensions; `recordObservedConstraints` merges by taking the maximum known minimum per axis.

Observed constraints are session-local. They are not written to `StoredWorld` until a later phase proves app-level persistence is useful. Raw observed constraints can be wrong after an app update, display scale change, or different window mode.

### Pure core algorithm

The solver is recursive and deterministic:

1. Compute each subtree's minimum required size bottom-up.
2. For a leaf, required size is the observed `WindowConstraints` plus the leaf's effective inner-gap inset.
3. For a horizontal split, required width is the sum of child minimum widths and required height is the max child minimum height.
4. For a vertical split, required height is the sum of child minimum heights and required width is the max child minimum width.
5. If available space on the split axis is greater than or equal to required minimum space, start from the unconstrained weighted allocation. Any child below its minimum is fixed at its minimum; the remaining space is redistributed among the still-flexible siblings by `Cell.weight`. Iterate until no child violates its minimum.
6. If available space is less than required minimum space, return `.unsatisfiable` with the exact axis, available size, required size, and involved windows.

Water-fill formula for one split axis:

```text
active = all children
remaining = available

repeat:
    ideal_i = remaining * weight_i / sum(weight_j for j in active)
    binding = { i in active where ideal_i < min_i }
    if binding is empty:
        allocation_i = ideal_i for i in active
        stop
    allocation_i = min_i for i in binding
    remaining -= sum(min_i for i in binding)
    active -= binding
```

This preserves BSP shape, avoids overlap, and preserves the unconstrained proportions unless a minimum-size constraint actually binds.

### Shell feedback loop

`AXClient.setFrame` distinguishes three outcomes:

```swift
enum AXFrameWriteOutcome: Sendable {
    case converged(actual: CGRect)
    case clamped(actual: CGRect, observed: WindowConstraints)
    case failed(AXClientError)
}
```

`clamped` is not an infrastructure failure. It is expected domain feedback from the OS/app boundary. The shell derives constraints from target vs actual:

- `actual.width > target.width + tolerance` implies `minWidth >= actual.width`.
- `actual.height > target.height + tolerance` implies `minHeight >= actual.height`.
- Origin drift alone is not a min-size signal.

The command path:

1. `apply(.push(...), baseWorld)` produces a proposed `World`.
2. `solveLayout(..., constraints: baseWorld.windowConstraints)` produces `LayoutSolveResult` for that proposal.
3. If the result is `.unsatisfiable`, reject the command and leave `World` unchanged. The focused window remains floating/uncommitted.
4. If the result is `.solved(layout, .exact)` or `.solved(layout, .adjusted)`, submit the layout to `LayoutApplier`.
5. If AX reports `.clamped`, commit only the constraint observation with `recordObservedConstraints`, re-apply the original command against that constrained base world, and re-solve once.
6. If the re-solve is satisfiable, submit the adjusted layout and commit the proposed tree only after all writes converge.
7. If the re-solve is still unsatisfiable, keep the learned constraint, leave the prior committed tree/layout intact, and log the unsatisfiable reason.

No command may commit a tree whose latest desired layout is known to be unsatisfiable for the active display.

### Default policy

For MVP, the fallback policy is conservative:

- Try min-size-aware reflow once after a new clamp observation.
- Reject the push if constraints remain unsatisfiable.
- Do not auto-float existing tiled windows.
- Do not overlap windows.
- Do not resize below observed minimums.
- Log the exact required vs available size.

Later policies may add "float newest window", "stack within lane", or "move to another display", but those are explicit user-facing policies, not hidden solver behavior.

---

## 0. MVP build ladder

The full architecture below is the destination, not the first slice. The MVP path optimizes for the earliest manual tiling loop that can be run daily:

```sh
swift run WinMgrApp
```

MVP means:
- The app launches as an AppKit accessory daemon and keeps the main run loop alive.
- Accessibility permission is checked before AX work starts.
- The focused macOS window can be discovered through AX.
- One command can move/resize the focused window predictably.
- One hardcoded Carbon hotkey can trigger that command.
- A minimal BSP push path can tile two or more windows on the active display.
- Minimum-size clamps from apps are detected and handled without corrupting the committed tree.
- A manual smoke test with Finder/TextEdit windows passes.

Anything not required for that loop is deferred until after the loop works.

### Rungs

| Rung | Build slice | User-visible proof | May defer |
|---|---|---|---|
| 0 | Package + `WinMgrCore` ADTs + Swift Testing | `swift test` passes | Shell, AX, hotkeys |
| 1 | `WinMgrApp` executable with AppKit run loop and Accessibility gate | `swift run WinMgrApp` stays alive and reports permission state | Config loading, restore, observers |
| 2 | Minimal `AXClient`: focused window snapshot only | Debug log shows focused window id/title/frame | Multi-window listing, AXObserver |
| 3 | Minimal `AXClient.setFrame` plus one built-in command: left half of active display | Running the command moves the focused window | BSP, rules, Lua |
| 4 | One hardcoded Carbon hotkey wired to the built-in command | Hotkey moves focused window | Configurable keymap, rebind |
| 5 | Minimal core command pipeline: `World`, `Command.push`, `layout`, `WorldActor`, `LayoutApplier` | Hotkey pushes focused windows into BSP tiles | Restore, external move handling, focus border |
| 5a | Min-size-aware layout solver + AX clamp feedback | Finder/TextEdit pushes reflow or reject cleanly when any tile would be below observed minimum size | App-level persisted constraints, alternate fallback policies |
| 6 | Default config as Swift value plus bundled `DefaultConfig/init.lua` parity tests | Default keymap is defined in one place and tested | Lua VM, FSEvents |
| 7 | Lua config loader for startup only | User can change hotkeys in `init.lua` before launch | Hot reload, last-good fallback |
| 8 | Environment refresh: list windows, display/Space snapshot, startup convergence | Relaunch preserves a sensible active-display state | Full restore fuzzy matching |
| 9 | Restore JSON for active Space | Relaunch retiles currently matchable windows | Cross-Space restore |
| 10 | Quality-of-life shell adapters: focus border, menubar reload, AXObserver echo filtering | Daily-use loop is tolerable | IPC, drag zones |
| 11a | IPC socket + `winmgrctl` | `winmgrctl reset` works against the running app; IPC tests cover newline-delimited JSON, connection reuse, and invalid command replies | Drag zones |
| 11b | Drag zones | Shift-drag onto configured zones maps to the same push pipeline | Packaging |
| 12 | Local packaging | `scripts/build_app_bundle.sh` emits a runnable `.app`, embeds Lua, copies default config into Resources, and generates a LaunchAgent plist | Notarization, brew cask |
| 13 | Local install lifecycle | `scripts/install_local.sh --no-launchctl --app-dir .build/install-test/Applications --launch-agents-dir .build/install-test/LaunchAgents --replace --configuration debug` installs a test app/plist, and `scripts/uninstall_local.sh --no-launchctl ...` removes them | Notarized installer, brew cask |
| 14 | User LaunchAgent smoke | `scripts/install_local.sh --replace --configuration debug` installs into `~/Applications` and `~/Library/LaunchAgents`; `launchctl print gui/$UID/com.ben.winmgr` reports running; installed `winmgrctl reset` returns `ok` | Notarized installer, brew cask |
| 15 | Config hot reload | FSEvents watches the active config path; file changes debounce into `reloadConfig`; invalid configs leave the last-good runtime config active and report failure in the menu/log | Notarization, brew cask |
| 16 | Startup/shutdown smoke | `scripts/smoke_startup_shutdown.sh` proves service startup, temp restore-state path, IPC reset, IPC quit, `applicationWillTerminate`, process exit, and socket cleanup | Unit-level fake service orchestration |
| 17 | Service lifecycle orchestration | `WinMgrAppSupportTests` prove ordered startup, reverse-order rollback on a later startup failure, and idempotent normal shutdown | Real AX shell startup failure injection |
| 18 | Startup failure rollback smoke | `scripts/smoke_startup_failure_rollback.sh` injects a failure at `dragZones` after IPC startup; app terminates and the IPC socket is removed without reaching layout-loop ready | Broader failure injection matrix |
| 19 | Startup failure matrix | `scripts/smoke_startup_failure_matrix.sh` injects failure at every service boundary and proves each rollback terminates without layout-loop readiness or leftover IPC socket | Adapter-specific failure simulations |
| 20 | Restore persistence boundary | `WinMgrAppSupportTests` prove missing file, unsupported schema, corrupt JSON, invalid persisted `StoredWorld`, and save/load round-trip from a temp restore path | Debounced async persistence scheduling |
| 21 | Debounced restore persistence scheduling | `WinMgrAppSupportTests` prove pure latest-wins coalescing, stale generation rejection, immediate flush, cancellation, failed-save reporting, and successful later save; startup/shutdown smoke proves AppKit termination and app-owned quit flush pending restore state before exit; install/uninstall request graceful IPC quit before `launchctl bootout` | Cross-process crash recovery while a save is still pending |
| 22 | Quarter drag-zone actions | `WinMgrCoreTests` prove configured `.insertAsQuarter` zones place a dragged window into each exact display corner and preserve persistent void lanes; unsupported subtree actions still fail explicitly | Custom subtree-targeted zones |
| 23 | Eject command | `WinMgrCoreTests` prove `.eject` moves a tiled window to the floating layer while preserving the zone shape; IPC DTO tests prove stable JSON; startup/shutdown smoke proves the app shell still boots with the new command route | Toggle-float, resize-split, balance |
| 24 | Toggle-float command | `WinMgrCoreTests` prove `.toggleFloat` ejects tiled windows, center-tiles floating windows, preserves state metadata, and rejects non-resizable floating windows; IPC DTO tests prove stable JSON; startup/shutdown smoke proves the app shell still boots with the new command route | User-selected default key binding, resize-split, balance |
| 25 | Explicit focus command | `WinMgrCoreTests` prove `.focus` records focused window state without layout mutation; IPC DTO tests prove stable JSON; startup/shutdown smoke proves explicit IPC focus routing does not break app startup | Resize-split, balance |

### Fast-path constraints

- Do not scaffold adapters before their rung needs them.
- Do not add Lua, FSEvents, IPC, drag, restore, overlay, or menubar code before Rung 5 passes.
- Rungs 1-4 may use a narrow shell command path that bypasses full `WorldActor`; Rung 5 replaces that path with the core command pipeline.
- Each rung must leave tests or a repeatable smoke command. A screenshot is not a test.
- Core invariants remain non-negotiable: pure data transforms, smart constructors for invalid ADTs, explicit `Result` for expected domain failures.

### MVP approval gate

**Status: done.** Ben accepted the MVP on 2026-05-17. Rungs 0-14 are complete;
the work after this point is post-MVP implementation of the remaining design.

Sprint 1 is done when this exact manual smoke works:

1. Run `swift run WinMgrApp`.
2. Grant Accessibility if prompted.
3. Open three Finder/TextEdit windows on the active display.
4. Press the push hotkey repeatedly.
5. Windows tile without crashing, losing focus permanently, or requiring app restart.
6. If an app refuses a too-small tile, the log reports the observed minimum and the command either reflows or rejects without committing a bad tree.
7. `swift test` still passes.

Post-MVP work starts only after that loop works. The full design below remains the target for replacing fast-path shortcuts with tested adapters.

---

## Module layout (target architecture)

This layout is intentionally larger than the MVP ladder. Create files when their rung requires them; do not pre-create empty adapters or placeholder managers.

```
winMgr/
├── Package.swift
├── design.md                  ← this file
├── Sources/
│   ├── WinMgrCore/            ← PURE. No AppKit. No Foundation I/O.
│   │   ├── ADTs.swift                  (Node, Cell, Axis, Direction, IDs, support types)
│   │   ├── World.swift                 (World, SpaceState, DisplaySpaceState, DisplayInfo)
│   │   ├── Command.swift               (Command enum + CommandError)
│   │   ├── Apply.swift                 (apply(_:to:) -> Result<World, ...>)
│   │   ├── Tree.swift                  (push/eject/walk/find primitives)
│   │   ├── Layout.swift                (unconstrained layout, diff)
│   │   ├── LayoutSolver.swift          (min-size-aware layout solve)
│   │   ├── Focus.swift                 (nearestWindowInDirection)
│   │   ├── Rules.swift                 (matchRule, windowOpenDecision)
│   │   └── Config.swift                (Config, HotkeyBinding, Zone, Gaps)
│   ├── WinMgrShell/           ← IMPURE. AppKit + AX + IPC + Lua.
│   │   ├── AXClient.swift              (read+write AX)
│   │   ├── AXObserver.swift            (AX event source)
│   │   ├── SpaceClient.swift           (dlsym CGSGetActiveSpace)
│   │   ├── DisplayClient.swift         (NSScreen/CGDisplay display snapshot)
│   │   ├── HotkeyManager.swift         (Carbon RegisterEventHotKey)
│   │   ├── EventTapClient.swift        (CGEventTap shift-drag)
│   │   ├── IPCServer.swift             (Unix domain socket)
│   │   ├── LuaEngine.swift             (embed Lua 5.4)
│   │   ├── ConfigLoader.swift          (FSEvent + parse + validate)
│   │   ├── LayoutApplier.swift         (desired layout generation → AX dispatch)
│   │   ├── WorldActor.swift            (state holder)
│   │   ├── Overlay/                    (focus border, zone overlay, HUD)
│   │   ├── Menubar.swift               (NSStatusItem)
│   │   ├── RestoreManager.swift        (fuzzy match)
│   │   ├── Logger.swift                (os.Logger wrapper)
│   │   └── App.swift                   (entry point, DI wiring)
│   ├── CLua/                  ← Vanilla Lua 5.4 sources as C target
│   │   ├── lua.c, lauxlib.c, ...       (vendored)
│   │   └── module.modulemap
│   └── winmgrctl/             ← CLI binary
│       └── main.swift                  (swift-argument-parser → socket)
├── Tests/
│   ├── WinMgrCoreTests/                (Swift Testing + hand-rolled prop)
│   │   ├── TreeTests.swift
│   │   ├── LayoutTests.swift
│   │   ├── FocusTests.swift
│   │   ├── ApplyTests.swift
│   │   ├── PropertyHarness.swift       (hand-rolled gen/shrink)
│   │   └── Generators.swift
│   └── WinMgrShellTests/               (integration, real AX test target)
└── DefaultConfig/init.lua              (ships in app bundle)
```

`WinMgrCore` has **zero dependencies** on AppKit, Foundation I/O, or AX. It links only `CoreGraphics` (for `CGRect`/`CGPoint`/`CGSize`) and the Swift standard library. Core defines its own `Insets`, `ModifierSet`, and serializable DTOs; shell translates to AppKit/Carbon types. This is enforced by the Package.swift target boundary.

---

## 1. Purity classification

Apply the 5-question test to every planned function. Tag `[CORE]` or `[SHELL]`.

### Core (pure) functions

| Function | Module | Notes |
|---|---|---|
| `apply(_ cmd: Command, to: World) -> Result<World, CommandError>` | Apply.swift | Central transition for implemented commands, including push, center, eject, toggle-float, focus, swap, drop-zone actions, reset, restore/reconcile, and config reload. Deterministic. |
| `reconcileEnvironment(_:EnvironmentSnapshot, world:World) -> World` | Apply.swift | Updates active Space/display/window maps from a complete AX snapshot; preserves prior window state on partial snapshots. |
| `resetTilingState(in:World) -> World` | Apply.swift | Clears BSP trees, floating lists, focus, pending rules, and observed min-size constraints while preserving live window/display inventory and config. |
| `recordObservedConstraints(_:WindowConstraints, for:WindowID, in:World) -> World` | Apply.swift | Pure merge of AX clamp feedback into `world.windowConstraints`; maxes minimums, never lowers them during a session. |
| `pushIntoTree(_:WindowID, _:Direction, _:Node) -> Node` | Tree.swift | Center-facing edge-recursive insertion; each edge lane alternates split axes and places the new window inward. Existing-window reposition replaces the old leaf with `.void` without collapsing. |
| `centerIntoTree(_:WindowID, _:Node) -> Node` | Tree.swift | Establishes 3-column root or splits center vertically. |
| `quarterIntoTree(_:WindowID, _:Corner, _:Node) -> Node` | Tree.swift | Creates or targets the left/right side lane, then splits its top/bottom half for exact corner drag-zone placement while preserving void lanes. |
| `swapWindowsInTree(_:WindowID, _:WindowID, _:Node) -> Node` | Tree.swift | Exchanges two occupied leaves without changing split shape, weights, or void leaves. |
| `ejectFromTree(_:WindowID, _:Node) -> Node` | Tree.swift | Replaces the leaf with `.void` and preserves the zone shape. |
| `nodesInTree(_:Node) -> [(NodePath, Node)]` | Tree.swift | Pure traversal materialized as values; callers cannot hide effects in a visitor closure. |
| `nodeAt(_:NodePath, in:Node) -> Node?` | Tree.swift | Path-indexed lookup. |
| `replace(at:NodePath, with:Node, in:Node) -> Node` | Tree.swift | Pure structural update. |
| `slots(in:Node) -> [TreeSlot]` | Tree.swift | Traverses both occupied and empty terminal zone slots. This is the zone-tree view. |
| `occupiedWindows(in:Node) -> [WindowID]` | Tree.swift | Traverses only real windows. This is the AX/layout-effects view. |
| `layout(spaceState: SpaceState, displayID: DisplayID, frame: CGRect, gaps: Gaps) -> Layout` | Layout.swift | Unconstrained recursive frame allocation for one display within the active Space. |
| `solveLayout(spaceState:displayID:frame:gaps:constraints:) -> LayoutSolveResult` | LayoutSolver.swift | Min-size-aware recursive allocation. Returns either a solved layout with exact/adjusted status or an unsatisfiable reason. |
| `inferObservedConstraints(target:actual:tolerance:) -> WindowConstraints?` | LayoutSolver.swift | Pure target-vs-actual inference for AX clamp feedback. Absence means no min-size signal. |
| `diff(old: Layout, new: Layout) -> LayoutDelta` | Layout.swift | Set-difference of `[WindowID: CGRect]`. |
| `nearestWindowInDirection(_:Direction, from:WindowID, layout:Layout, floating:[(WindowID, CGRect)]) -> WindowID?` | Focus.swift | Spatial nearest-center in half-plane. |
| `matchRule(_:WindowMetadata, rules:[WindowRule]) -> RuleAction?` | Rules.swift | First-match wins. Pure predicate eval. |
| `windowOpenDecision(_:WindowMetadata, rules:[WindowRule]) -> WindowOpenDecision` | Rules.swift | Converts a first-match rule into a typed open decision. |
| `validateCommand(_:Command, world:World) -> Result<Command, CommandError>` | Command.swift | Cross-checks command identity/scope before transition. |
| `resolveTemplate(_:CommandTemplate, focused:WindowID?) -> Command?` | Command.swift | Hotkey template + focused window → executable command or nil. |
| `resolveDrop(_:DragEvent, zones:[Zone], displays:[DisplayID:DisplayInfo]) -> Command?` | Rules.swift | Pure zone hit-test with half-open zone bounds and drag-to-command mapping. `.insertAsHalf`, `.insertAsQuarter`, and `.insertAsCenter` are executable; `.insertAtSubtree` remains explicitly unsupported until custom subtree targeting is designed. |
| `restoreWorld(from:StoredWorld, liveWindows:[WindowMetadata], displays:[DisplayID:DisplayInfo], activeSpace:SpaceID?, config:Config) -> World` | Restore.swift | Pure remap from stable stored descriptors to live window IDs. |
| `storedWorld(from:World) -> StoredWorld` | Restore.swift | Pure projection from live World to stable restore DTO. |
| `parseConfig(_:LuaConfigData) -> Result<Config, ConfigError>` | Config.swift | Pure validator on already-decoded Lua values. (Decode lives in shell.) |

All "no" on the 5 questions:
- No globals read (config passed as `World.config`).
- No outlives mutation (returns new value).
- Same args → same return (deterministic).
- No order dependence.
- No exceptions for external state (use `Result`).

### Shell (impure) functions

| Function | Module | Effect |
|---|---|---|
| `AXClient.listWindows() @MainActor async -> AXWindowSnapshot` | AXClient | Reads from OS and returns partial-failure metadata. |
| `AXClient.setFrame(_:WindowID, _:CGRect) @MainActor async -> AXFrameWriteOutcome` | AXClient | Writes window frame to OS. Separates convergence, app clamp, and infrastructure failure. |
| `AXClient.focusWindow(_:WindowMetadata) @MainActor -> Result<Void, AXClientError>` | AXClient | Raises and focuses a macOS window. |
| `AXClient.raiseWindow(_:WindowID) @MainActor async throws` | AXClient | Raises a macOS window without changing core focus. |
| `AXClient.focusedWindowID() @MainActor async -> WindowID?` | AXClient | Reads focused macOS window for hotkey template resolution. |
| `AXObserver.events: AsyncStream<AXEvent>` | AXObserver | OS event source. |
| `AXObserver.start() @MainActor async throws -> ServiceHandle` | AXObserver | Registers per-app AX observers after startup permission check; returns an owned stop handle. |
| `SpaceClient.activeSpaceID() -> SpaceID?` | SpaceClient | Single read-only dlsym call; global active Space only. |
| `SpaceClient.events: AsyncStream<SpaceID>` | SpaceClient | NSWorkspace active-Space notification/poll bridge emitting changed active Space IDs. |
| `SpaceClient.start() @MainActor async throws -> ServiceHandle` | SpaceClient | Registers NSWorkspace notification observer / poll source and returns an owned stop handle. |
| `DisplayClient.currentDisplays() @MainActor -> [DisplayID: DisplayInfo]` | DisplayClient | Reads display frames from AppKit/CoreGraphics. |
| `DisplayClient.events: AsyncStream<[DisplayID: DisplayInfo]>` | DisplayClient | Display hotplug/resolution/visible-frame change source. |
| `DisplayClient.start() @MainActor async throws -> ServiceHandle` | DisplayClient | Registers screen/display change notifications and returns an owned stop handle. |
| `HotkeyManager.bind(_:HotkeyBinding, _:@MainActor @escaping (HotkeyAction) -> Void)` | HotkeyManager | Carbon registration; emits a shell action. |
| `HotkeyManager.start() @MainActor throws -> ServiceHandle` | HotkeyManager | Registers configured Carbon hotkeys; startup fails if registration fails; handle unregisters them. |
| `EventTapClient.events: AsyncStream<DragEvent>` | EventTapClient | CGEventTap stream. |
| `EventTapClient.start() async throws -> ServiceHandle` | EventTapClient | Installs the CGEventTap, starts its runloop thread, and returns an owned stop handle. |
| `IPCServer.start() async throws -> ServiceHandle` | IPCServer | Binds Unix socket, launches accept loop task, and returns an owned stop handle; per-message handler awaits `CommandOutcome` and returns `IPCReplyDTO`. |
| `LuaEngine.eval(_:String) async throws -> LuaValue` | LuaEngine | VM execution on dedicated Lua thread. |
| `ConfigLoader.loadInitial(logger:) throws -> Config` | ConfigLoader | Loads and validates startup config before any adapters bind. |
| `ConfigLoader.startWatching() async throws -> ServiceHandle` | ConfigLoader | Creates FSEvent stream and returns an owned stop handle; emits valid configs through configured send closure. |
| `ConfigLoader.reloadNow() async throws` | ConfigLoader | Manual config reload trigger; emits `.reloadConfig` through configured send closure. |
| `HotkeyManager.rebind(_: [HotkeyBinding]) @MainActor` | HotkeyManager | Replaces Carbon registrations after config reload. |
| `EventTapClient.updateModifier(_: ModifierSet) async` | EventTapClient | Updates drag modifier after config reload. |
| `LayoutApplier.submit(_:DesiredLayout) async` | LayoutApplier | Records latest desired layout immediately and dispatches convergent AX writes in its own worker. |
| `LayoutApplier.expectFocus(_:WindowID) async` | LayoutApplier | Records one expected focus echo before shell calls `AXClient.focusWindow`. |
| `LayoutApplier.isExpectedEcho(_:AXEvent) async -> Bool` | LayoutApplier | Reads echo-suppression table for AX feedback filtering. |
| `WorldActor.handle(_:CommandEnvelope) async -> CommandOutcome` | WorldActor | Owns mutable World. |
| `WorldActor.outcomes: AsyncStream<CommandOutcome>` | WorldActor | Broadcasts every handled outcome to shell effect consumers. |
| `WorldActor.configSnapshot() async -> Config` | WorldActor | Actor-isolated read for drag zone/config lookup. |
| `WorldActor.displaySnapshot() async -> [DisplayID: DisplayInfo]` | WorldActor | Actor-isolated read for drag hit-testing. |
| `Overlay.showSpaceHUD(_:SpaceID) @MainActor` | Overlay | Shows active Space HUD after a Space-sourced environment change. |
| `Overlay.updateFocusBorder(_:FocusBorderEffect) @MainActor` | Overlay | Shows, moves, or hides the focused-window border from explicit effects. |
| `Overlay.updateConfig(border:hud:) @MainActor` | Overlay | Rebinds visual config after accepted config reload. |
| `Menubar.start(reload:quit:) @MainActor -> ServiceHandle` | Menubar | Creates NSStatusItem with reload/quit actions and returns an owned removal handle. |
| `Menubar.updateConfigStatus(_:) @MainActor` | Menubar | Shows last config load state in the status menu. |
| `scheduleRestoreSave`, `fireRestoreSaveTimer`, `flushRestoreSave`, `cancelRestoreSave` | RestoreManager | Pure latest-wins restore-save coalescing policy. |
| `RestorePersistence.scheduleSave(_:reason:) @MainActor` | RestoreManager | Debounced atomic save shell for `~/Library/Application Support/winmgr/state.json`; AppKit termination and app-owned quit paths call `flushPending()` synchronously. |
| `RestoreManager.load() throws -> StoredWorld?` | RestoreManager | Reads restore JSON; returns nil for no file or unsupported schema version. |

**Core:shell ratio**: 25 core / 38 shell function families = ~0.7:1. Target was 4:1, but a window manager is by nature I/O-heavy. The *line-count* ratio matters more here — the core implementations are substantial (tree ops + layout + apply + restore remap/projection + coalescing policies) while shell wrappers are thin. Acceptable.

---

## 2. Functional core / imperative shell

```
┌──────────────────────────────────────────────────────────────────────┐
│ IMPURE SHELL (WinMgrShell)                                           │
│                                                                      │
│  Event sources                       State holder                    │
│  ┌─────────────────┐                ┌──────────────────────┐         │
│  │ AXObserver      │                │ WorldActor           │         │
│  │ HotkeyManager   │   Commands     │   private world      │         │
│  │ EventTapClient  │───────────────▶│   validate + apply   │         │
│  │ IPCServer       │                │   emit CommandEffects│         │
│  │ ConfigLoader    │                │                      │         │
│  │ SpaceClient     │                └──────────┬───────────┘         │
│  │ DisplayClient   │                           │                     │
│  └─────────────────┘                           │                     │
│                                                │ CommandEffects      │
│                       ┌────────────────────────▼──────────┐          │
│                       │ LayoutApplier (MainActor)         │          │
│                       │   latest-generation AX writes     │          │
│                       └──────────────┬────────────────────┘          │
│                                      │                               │
│                                      ▼                               │
│                              AXClient (writes)                       │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │ PURE CORE (WinMgrCore)                                      │     │
│  │   apply(Command, World) -> Result<World, CommandError>      │     │
│  │   solveLayout(..., constraints) -> LayoutSolveResult        │     │
│  │   layout(SpaceState, DisplayID, CGRect, Gaps) -> Layout     │     │
│  │   diff(Layout, Layout) -> LayoutDelta                       │     │
│  │   pushIntoTree, centerIntoTree, swapWindowsInTree, eject    │     │
│  │   nearestWindowInDirection                                  │     │
│  │   matchRule                                                 │     │
│  │   No CoreGraphics calls beyond CGRect arithmetic.           │     │
│  │   No AppKit. No AX. No Foundation I/O.                      │     │
│  └─────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────┘
```

**Atomicity caveat** (per fp-architect Step 2): the shell makes multiple AX writes per Command (e.g., reflow of N windows). These are NOT atomic. If the process dies mid-dispatch, the on-screen state diverges from World. Mitigation:
- `WorldActor` emits `CommandEffects` on every successful Command: optional full `DesiredLayout`, focus target, raise targets, focus-border update, config-change hint, and restore-persistence hint.
- Layout effects are produced from `solveLayout`, not raw `layout`, once Rung 5a lands. Unsatisfiable solve results reject the command before AX writes.
- `LayoutApplier.submit` stores only the latest desired generation and returns after enqueueing. Its worker abandons stale remaining writes and restarts from the latest full layout.
- AX clamp feedback is converted into `windowConstraintObserved` data and merged into `World.windowConstraints` independently of the tree mutation. The original command is then re-applied and re-solved against the constrained world; clamp feedback is not treated as a successful frame write.
- AX move/resize/focus events matching an expected write are filtered as echoes by `(windowID, expectedOrigin?, expectedSize?, expectedFocus?, generation, expiry)`, so split move/resize callbacks and programmatic focus changes from self-generated writes do not feed back as external mutations.
- On daemon restart, we re-query AX state and reconcile with restored `StoredWorld`.
- Half-applied layouts are visually obvious and recoverable on next hotkey.

This is acceptable for a window manager (not a banking system). Documented; not engineered around.

---

## 3. Algebraic data types

ADTs as Swift source. These are the **canonical types** — P1 implements them verbatim, with mechanical `Sendable` conformance added to immutable value types that cross `actor`, `Task`, or `AsyncStream` boundaries.

```swift
// ───── Identity (products) ─────

struct WindowID: Hashable, Codable, CustomStringConvertible {
    let raw: CGWindowID                      // UInt32
    var description: String { "w\(raw)" }
}

struct DisplayID: Hashable, Codable {
    let raw: CGDirectDisplayID               // UInt32
}

struct SpaceID: Hashable, Codable {
    let raw: UInt64                          // from CGSGetActiveSpace
}

struct BundleID: Hashable, Codable {
    let raw: String                          // reverse-DNS, e.g. "com.apple.finder"
}

struct WindowMetadata: Equatable, Codable {
    let id: WindowID
    let bundleID: BundleID
    let title: String
    let role: String                         // kAXWindowRole value
    let pid: ProcessID
    let frame: CGRect
    let isResizable: Bool
    let isMinimized: Bool
}

// ───── Tree (sum + recursive) ─────

indirect enum Node: Equatable, Codable {
    case void                                // empty persistent zone slot
    case leaf(WindowID)
    case split(Split)
}

enum SlotOccupancy: Equatable, Sendable {
    case empty
    case occupied(WindowID)
}

struct TreeSlot: Equatable, Sendable {
    let path: NodePath
    let occupancy: SlotOccupancy
}

struct Split: Equatable, Codable {
    let axis: Axis
    let cells: [Cell]                        // count ≥ 2; invariant enforced by constructor

    private init(axis: Axis, cells: [Cell]) {
        self.axis = axis
        self.cells = cells
    }

    static func create(axis: Axis, cells: [Cell]) -> Result<Split, InvariantError> {
        guard cells.count >= 2 else { return .failure(.splitNeedsAtLeastTwoCells) }
        guard cells.allSatisfy({ $0.weight.isFinite }) else { return .failure(.nonFiniteNumber("cell.weight")) }
        return .success(Split(axis: axis, cells: cells))
    }

    private enum CodingKeys: String, CodingKey { case axis, cells }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let axis = try c.decode(Axis.self, forKey: .axis)
        let cells = try c.decode([Cell].self, forKey: .cells)
        switch Split.create(axis: axis, cells: cells) {
        case .success(let split):
            self = split
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .cells,
                in: c,
                debugDescription: String(describing: error)
            )
        }
    }
}

struct Cell: Equatable, Codable {
    let weight: Double                       // > 0; ratio = weight / Σweights
    let node: Node

    private init(weight: Double, node: Node) {
        self.weight = weight
        self.node = node
    }

    static func create(weight: Double, node: Node) -> Result<Cell, InvariantError> {
        guard weight.isFinite else { return .failure(.nonFiniteNumber("cell.weight")) }
        guard weight > 0 else { return .failure(.cellWeightMustBePositive) }
        return .success(Cell(weight: weight, node: node))
    }

    private enum CodingKeys: String, CodingKey { case weight, node }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let weight = try c.decode(Double.self, forKey: .weight)
        let node = try c.decode(Node.self, forKey: .node)
        switch Cell.create(weight: weight, node: node) {
        case .success(let cell):
            self = cell
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .weight,
                in: c,
                debugDescription: String(describing: error)
            )
        }
    }
}

enum Axis: String, Codable, CaseIterable {
    case horizontal                          // cells laid left → right
    case vertical                            // cells laid top → bottom
}

enum Direction: String, Codable, CaseIterable {
    case left, right, up, down

    var layoutAxisForPush: Axis {            // Axis is cell layout direction, not split-line direction.
        switch self {
        case .left, .right: return .horizontal
        case .up, .down:    return .vertical
        }
    }

    var splitLineAxis: Axis {
        switch self {
        case .left, .right: return .vertical
        case .up, .down:    return .horizontal
        }
    }
}

typealias NodePath = [Int]                   // [] = root; [0, 1] = root.cells[0].node.cells[1].node

// ───── Per-Space + display ─────

struct DisplaySpaceState: Equatable, Codable {
    let displayID: DisplayID
    let tree: Node                           // .void if empty
    let floating: [WindowID]                 // back-to-front z-order on this display
}

struct SpaceState: Equatable, Codable {
    let id: SpaceID
    let displays: [DisplayID: DisplaySpaceState]
    let focused: WindowID?
}

struct DisplayInfo: Equatable, Codable {
    let id: DisplayID
    let slot: Int                             // stable sort order for config/restore
    let fingerprint: String?
    let frame: CGRect                        // global coords
    let visibleFrame: CGRect                 // minus dock + menubar
}

// ───── World (top-level state) ─────

struct World: Equatable {
    let displays: [DisplayID: DisplayInfo]
    let activeSpace: SpaceID?
    let spaces: [SpaceID: SpaceState]
    let windows: [WindowID: WindowMetadata]
    let windowDisplay: [WindowID: DisplayID]                // which display each window is on
    let windowConstraints: [WindowID: WindowConstraints]    // observed app minimum sizes, session-local
    let pendingRules: [WindowID: RuleAction]                // rules waiting for stable window/display metadata
    let config: Config

    static let empty = World(
        displays: [:], activeSpace: nil, spaces: [:],
        windows: [:], windowDisplay: [:], windowConstraints: [:], pendingRules: [:],
        config: .default
    )
}

// ───── Command (sum) ─────

enum Command: Equatable {
    // ── user actions ──
    case push(WindowID, Direction)
    case center(WindowID)
    case eject(WindowID)
    case focusDirection(Direction)
    case focusCycle(FocusCycleDirection)
    case focus(WindowID)
    case swapInTree(WindowID, Direction)
    case resizeSplit(WindowID, Direction, delta: Double)
    case balance(SpaceID)
    case toggleFloat(WindowID)
    case dropAtZone(WindowID, DisplayID, ZoneID)            // from shift-drag
    case resetLayout                                       // clear BSP/floating/focus/constraint memory
    case startupConverge

    // ── system events ──
    case windowOpened(WindowMetadata)
    case windowClosed(WindowID)
    case windowMovedExternally(WindowID, CGRect)
    case windowResizedExternally(WindowID, CGSize)
    case windowFocusedExternally(WindowID)
    case windowConstraintObserved(WindowID, WindowConstraints)
    case environmentChanged(EnvironmentSnapshot)

    // ── config ──
    case reloadConfig(Config)
}

// ───── Failure (sum) ─────

enum CommandError: Error, Equatable {
    case windowNotFound(WindowID)
    case windowIsFloating(WindowID)
    case windowIsTiled(WindowID)
    case windowNotResizable(WindowID)
    case spaceNotFound(SpaceID)
    case displayNotFound(DisplayID)
    case noNeighbor(Direction)
    case zoneNotFound(ZoneID)
    case ruleInvalid(String)
    case configInvalid(String)

    var code: String {
        switch self {
        case .windowNotFound: return "window_not_found"
        case .windowIsFloating: return "window_is_floating"
        case .windowIsTiled: return "window_is_tiled"
        case .windowNotResizable: return "window_not_resizable"
        case .spaceNotFound: return "space_not_found"
        case .displayNotFound: return "display_not_found"
        case .noNeighbor: return "no_neighbor"
        case .zoneNotFound: return "zone_not_found"
        case .ruleInvalid: return "rule_invalid"
        case .configInvalid: return "config_invalid"
        }
    }

    var message: String { String(describing: self) }
}

// ───── Layout (output) ─────

struct Layout: Equatable {
    let tiled: [WindowID: CGRect]
    let floatingZOrder: [WindowID]
    let hidden: Set<WindowID>                               // tracked but not visible (other Space)
}

struct LayoutDelta: Equatable {
    let moves: [WindowID: CGRect]                           // tiled position changes
    let raises: [WindowID]                                  // z-order changes (front-back)
    let hides: Set<WindowID>                                // windows that left visible Space
    let shows: Set<WindowID>                                // windows that entered visible Space
}

struct WindowConstraints: Equatable, Codable {
    let minWidth: Double?
    let minHeight: Double?
}

enum LayoutAdjustmentReason: Equatable {
    case minimumWidth(Double)
    case minimumHeight(Double)
}

struct LayoutAdjustment: Equatable {
    let windowID: WindowID
    let requested: CGRect
    let adjusted: CGRect
    let reason: LayoutAdjustmentReason
}

struct UnsatisfiableLayout: Equatable {
    let displayID: DisplayID
    let axis: Axis
    let available: Double
    let required: Double
    let windows: [WindowID]
}

enum LayoutSolveStatus: Equatable {
    case exact
    case adjusted([LayoutAdjustment])
}

enum LayoutSolveResult: Equatable {
    case solved(layout: Layout, status: LayoutSolveStatus)
    case unsatisfiable(UnsatisfiableLayout)
}

struct LayoutGeneration: Hashable, Codable {
    let raw: UInt64
}

struct DesiredLayout: Equatable {
    let generation: LayoutGeneration
    let layout: Layout                                      // full desired state for convergence
    let delta: LayoutDelta                                  // optimization hint, not authority
}

struct CommandEffects: Equatable {
    let desiredLayout: DesiredLayout?
    let focus: WindowID?
    let raises: [WindowID]
    let focusBorder: FocusBorderEffect?
    let persistRestore: Bool
    let configChanged: Config?

    static let none = CommandEffects(desiredLayout: nil, focus: nil, raises: [], focusBorder: nil, persistRestore: false, configChanged: nil)
}

enum FocusBorderEffect: Equatable {
    case show(WindowID, CGRect)
    case hide
}

enum ConfigStatus: Equatable {
    case loaded
    case failed(String)
}

// ───── Config (sum-of-products) ─────

struct Config: Equatable {
    let keymap: [HotkeyBinding]
    let rules: [WindowRule]
    let zones: [Zone]
    let gaps: Gaps
    let border: BorderConfig
    let hud: HUDConfig
    let dragModifier: ModifierSet                           // bitmask: shift / cmd / alt / ctrl
    static let `default`: Config = Config(
        keymap: DefaultKeymap.entries,
        rules: [], zones: DefaultZones.entries,
        gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0)),
        border: .default, hud: .default,
        dragModifier: [.shift]
    )
}

struct HotkeyBinding: Equatable {
    let key: KeySpec
    let action: HotkeyAction                               // command templates need runtime WindowID
}

enum HotkeyAction: Equatable {
    case command(CommandTemplate)
    case reloadConfig                                      // shell action; loads config before emitting Command.reloadConfig
}

enum CommandTemplate: Equatable {
    case push(Direction)
    case center
    case eject
    case swap(Direction)
    case focusDirection(Direction)
    case focusCycle(FocusCycleDirection)
    case toggleFloat
    case resetLayout
    // template is resolved at hotkey-fire time using "focused window"
}

struct WindowRule: Equatable, Codable {
    let predicate: RulePredicate
    let action: RuleAction
}

indirect enum RulePredicate: Equatable, Codable {
    case bundleID(String)
    case bundleIDMatches(regex: String)
    case role(String)
    case titleMatches(regex: String)
    case and([RulePredicate])
    case or([RulePredicate])
    case not(RulePredicate)
}

enum RuleAction: Equatable, Codable {
    case forceFloat
    case ignore
    case pinToDisplay(slot: Int)                            // resolved through sorted current displays
}

enum WindowOpenDecision: Equatable {
    case tileOrFloatByDefault(WindowMetadata)
    case forceFloat(WindowMetadata)
    case ignore(WindowID)
    case pinToDisplay(WindowMetadata, slot: Int)
}

struct Zone: Equatable {
    let id: ZoneID
    let bounds: ProportionalRect                            // 0..1 coords
    let action: ZoneAction
}

struct ZoneID: Hashable, Codable { let raw: String }

struct ProportionalRect: Equatable, Codable {
    let x: Double, y: Double, w: Double, h: Double          // 0..1
}

enum ZoneAction: Equatable, Codable {
    case insertAsHalf(Direction)
    case insertAsQuarter(corner: Corner)
    case insertAsCenter
    case insertAtSubtree(NodePath)                          // advanced
}

enum Corner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

enum FocusCycleDirection: String, Codable, CaseIterable {
    case previous
    case next
}

// ───── Supporting value types ─────

typealias ProcessID = Int32

struct Insets: Equatable, Codable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double
}

struct Gaps: Equatable, Codable {
    let inner: Double
    let outer: Insets
}

struct ModifierSet: OptionSet, Equatable, Codable {
    let rawValue: UInt8
    static let shift = ModifierSet(rawValue: 1 << 0)
    static let command = ModifierSet(rawValue: 1 << 1)
    static let option = ModifierSet(rawValue: 1 << 2)
    static let control = ModifierSet(rawValue: 1 << 3)
}

struct KeySpec: Equatable, Codable {
    let key: String                                          // normalized key name, e.g. "h", "return"
    let modifiers: ModifierSet
}

struct BorderConfig: Equatable {
    let width: Double
    let colorHex: String
    static let `default` = BorderConfig(width: 2, colorHex: "#4DA3FF")
}

struct HUDConfig: Equatable {
    let enabled: Bool
    let durationMillis: Int
    static let `default` = HUDConfig(enabled: true, durationMillis: 700)
}

enum DefaultKeymap {
    static let entries: [HotkeyBinding] = [
        HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .option]), action: .command(.focusDirection(.left))),
        HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .option]), action: .command(.focusDirection(.right))),
        HotkeyBinding(key: KeySpec(key: "k", modifiers: [.control, .option]), action: .command(.focusDirection(.up))),
        HotkeyBinding(key: KeySpec(key: "j", modifiers: [.control, .option]), action: .command(.focusDirection(.down))),
        HotkeyBinding(key: KeySpec(key: "u", modifiers: [.control, .option]), action: .command(.focusCycle(.previous))),
        HotkeyBinding(key: KeySpec(key: "i", modifiers: [.control, .option]), action: .command(.focusCycle(.next))),
        HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .option, .shift]), action: .command(.swap(.left))),
        HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .option, .shift]), action: .command(.swap(.right))),
        HotkeyBinding(key: KeySpec(key: "k", modifiers: [.control, .option, .shift]), action: .command(.swap(.up))),
        HotkeyBinding(key: KeySpec(key: "j", modifiers: [.control, .option, .shift]), action: .command(.swap(.down))),
        HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .option, .command]), action: .command(.push(.left))),
        HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .option, .command]), action: .command(.push(.right))),
        HotkeyBinding(key: KeySpec(key: "k", modifiers: [.control, .option, .command]), action: .command(.push(.up))),
        HotkeyBinding(key: KeySpec(key: "j", modifiers: [.control, .option, .command]), action: .command(.push(.down))),
        HotkeyBinding(key: KeySpec(key: "delete", modifiers: [.control, .option]), action: .command(.resetLayout))
    ]
}

enum DefaultZones {
    // Bounds are non-overlapping, half-open trigger regions: [minX, maxX) × [minY, maxY).
    // Points on max edges belong to no zone; ZoneAction determines the resulting tile geometry.
    static let entries: [Zone] = [
        Zone(id: ZoneID(raw: "left-half"), bounds: ProportionalRect(x: 0, y: 0.30, w: 0.20, h: 0.40), action: .insertAsHalf(.left)),
        Zone(id: ZoneID(raw: "right-half"), bounds: ProportionalRect(x: 0.80, y: 0.30, w: 0.20, h: 0.40), action: .insertAsHalf(.right)),
        Zone(id: ZoneID(raw: "top-half"), bounds: ProportionalRect(x: 0.30, y: 0, w: 0.40, h: 0.20), action: .insertAsHalf(.up)),
        Zone(id: ZoneID(raw: "bottom-half"), bounds: ProportionalRect(x: 0.30, y: 0.80, w: 0.40, h: 0.20), action: .insertAsHalf(.down)),
        Zone(id: ZoneID(raw: "center"), bounds: ProportionalRect(x: 0.40, y: 0.40, w: 0.20, h: 0.20), action: .insertAsCenter)
    ]
}

indirect enum LuaValue: Equatable {
    case nilValue
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LuaValue])
    case table([String: LuaValue])
}

struct LuaConfigData: Equatable {
    let root: [String: LuaValue]
}

enum ConfigError: Error, Equatable {
    case missingKey(String)
    case wrongType(key: String, expected: String)
    case invalidValue(key: String, reason: String)
}

enum InvariantError: Error, Equatable {
    case splitNeedsAtLeastTwoCells
    case cellWeightMustBePositive
    case nonFiniteNumber(String)
}

struct CommandID: Hashable, Codable {
    let raw: String                                          // generated in shell; no UUID dependency in core
}

enum CommandSource: String, Codable {
    case hotkey
    case drag
    case ipc
    case ax
    case space
    case display
    case config
    case restore
}

struct CommandEnvelope: Equatable {
    let id: CommandID
    let source: CommandSource
    let command: Command
}

enum CommandOutcome: Equatable {
    case success(envelope: CommandEnvelope, newWorld: World, effects: CommandEffects)
    case failure(envelope: CommandEnvelope, error: CommandError)
}

enum IPCReplyDTO: Codable, Equatable {
    case ok(commandID: CommandID)
    case error(commandID: CommandID, code: String, message: String)

    static func from(_ outcome: CommandOutcome) -> IPCReplyDTO {
        switch outcome {
        case .success(let envelope, _, _):
            return .ok(commandID: envelope.id)
        case .failure(let envelope, let error):
            return .error(
                commandID: envelope.id,
                code: error.code,
                message: error.message
            )
        }
    }
}

enum IPCCommandDTO: Codable {
    case pushFocused(Direction)
    case push(windowID: WindowID, direction: Direction)
    case center(windowID: WindowID)
    case eject(windowID: WindowID)
    case focusDirection(Direction)
    case focusCycle(FocusCycleDirection)
    case focus(windowID: WindowID)
    case toggleFloat(windowID: WindowID)
    case resetLayout

    func toCommand(focusedWindowID: WindowID? = nil) -> Result<Command, IPCCommandResolutionError> {
        switch self {
        case .pushFocused(let direction):
            guard let focusedWindowID else { return .failure(.focusedWindowRequired) }
            return .success(.push(focusedWindowID, direction))
        case .push(let windowID, let direction): return .success(.push(windowID, direction))
        case .center(let windowID): return .success(.center(windowID))
        case .eject(let windowID): return .success(.eject(windowID))
        case .focusDirection(let direction): return .success(.focusDirection(direction))
        case .focusCycle(let direction): return .success(.focusCycle(direction))
        case .focus(let windowID): return .success(.focus(windowID))
        case .toggleFloat(let windowID): return .success(.toggleFloat(windowID))
        case .resetLayout: return .success(.resetLayout)
        }
    }
}

struct StoredWindowRef: Hashable, Codable {
    let bundleID: BundleID
    let title: String
    let role: String
    let occurrence: Int                                      // zero-based ordinal among identical bundle/title/role refs at save time
    let lastKnownFrame: CGRect?                              // tie-breaker only; restore never trusts this as current geometry
}

indirect enum StoredNode: Equatable, Codable {
    case void
    case leaf(StoredWindowRef)
    case split(StoredSplit)
}

struct StoredSplit: Equatable, Codable {
    let axis: Axis
    let cells: [StoredCell]

    private init(axis: Axis, cells: [StoredCell]) {
        self.axis = axis
        self.cells = cells
    }

    static func create(axis: Axis, cells: [StoredCell]) -> Result<StoredSplit, InvariantError> {
        guard cells.count >= 2 else { return .failure(.splitNeedsAtLeastTwoCells) }
        guard cells.allSatisfy({ $0.weight.isFinite }) else { return .failure(.nonFiniteNumber("storedCell.weight")) }
        return .success(StoredSplit(axis: axis, cells: cells))
    }

    private enum CodingKeys: String, CodingKey { case axis, cells }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let axis = try c.decode(Axis.self, forKey: .axis)
        let cells = try c.decode([StoredCell].self, forKey: .cells)
        switch StoredSplit.create(axis: axis, cells: cells) {
        case .success(let split):
            self = split
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .cells,
                in: c,
                debugDescription: String(describing: error)
            )
        }
    }
}

struct StoredCell: Equatable, Codable {
    let weight: Double
    let node: StoredNode

    private init(weight: Double, node: StoredNode) {
        self.weight = weight
        self.node = node
    }

    static func create(weight: Double, node: StoredNode) -> Result<StoredCell, InvariantError> {
        guard weight.isFinite else { return .failure(.nonFiniteNumber("storedCell.weight")) }
        guard weight > 0 else { return .failure(.cellWeightMustBePositive) }
        return .success(StoredCell(weight: weight, node: node))
    }

    private enum CodingKeys: String, CodingKey { case weight, node }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let weight = try c.decode(Double.self, forKey: .weight)
        let node = try c.decode(StoredNode.self, forKey: .node)
        switch StoredCell.create(weight: weight, node: node) {
        case .success(let cell):
            self = cell
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .weight,
                in: c,
                debugDescription: String(describing: error)
            )
        }
    }
}

struct StoredDisplayLayout: Equatable, Codable {
    let displaySlot: Int                                     // stable sorted slot, not CGDirectDisplayID
    let displayFingerprint: String?
    let tree: StoredNode
    let floating: [StoredWindowRef]
}

struct StoredSpace: Equatable, Codable {
    let layouts: [StoredDisplayLayout]
    let focused: StoredWindowRef?
}

struct StoredPendingRule: Equatable, Codable {
    let window: StoredWindowRef
    let action: StoredRuleAction
}

enum StoredRuleAction: Equatable, Codable {
    case forceFloat
    case ignore
    case pinToDisplay(displaySlot: Int)
}

struct StoredWorld: Equatable, Codable {
    static let currentSchemaVersion = 1
    static let empty = StoredWorld(schemaVersion: currentSchemaVersion, activeSpace: nil, pendingRules: [])

    let schemaVersion: Int
    let activeSpace: StoredSpace?
    let pendingRules: [StoredPendingRule]
}

struct DragEvent: Equatable {
    let windowID: WindowID
    let location: CGPoint                                    // screen coordinates
    let displayID: DisplayID?
}

enum AXEvent: Equatable {
    case windowOpened(WindowMetadata)
    case windowClosed(WindowID)
    case windowMoved(WindowID, CGRect)
    case windowResized(WindowID, CGSize)
    case windowFocused(WindowID)

    func toCommand() -> Command {
        switch self {
        case .windowOpened(let metadata): return .windowOpened(metadata)
        case .windowClosed(let id): return .windowClosed(id)
        case .windowMoved(let id, let frame): return .windowMovedExternally(id, frame)
        case .windowResized(let id, let size): return .windowResizedExternally(id, size)
        case .windowFocused(let id): return .windowFocusedExternally(id)
        }
    }
}

enum AXSnapshotQuality: Equatable {
    case complete
    case partial([AXWindowReadError])
    case permissionDenied(String)
}

struct EnvironmentSnapshot: Equatable {
    let activeSpace: SpaceID?
    let displays: [DisplayID: DisplayInfo]
    let axSnapshot: AXWindowSnapshot
}

enum StartupError: Error, Equatable {
    case axSnapshotUnavailable(AXSnapshotQuality)
}

enum RestoreError: Error, Equatable {
    case invalidStoredWorld(String)
}

struct AXWindowReadError: Equatable {
    let windowID: WindowID?
    let pid: ProcessID?
    let message: String
}

struct AXWindowSnapshot: Equatable {
    let windows: [WindowMetadata]
    let quality: AXSnapshotQuality
}
```

### Lua rule schema

Rules are explicit data at the Lua boundary. Supported predicate `type` values are `bundle_id`, `bundle_id_matches`, `role`, `title_matches`, `and`, `or`, and `not`. Supported action `type` values are `force_float`, `ignore`, and `pin_to_display`.

```lua
rules = {
  {
    predicate = { type = "bundle_id", value = "com.apple.finder" },
    action = { type = "force_float" },
  },
  {
    predicate = {
      type = "and",
      predicates = {
        { type = "bundle_id_matches", pattern = "^net\\.kovidgoyal\\." },
        { type = "not", predicate = { type = "title_matches", pattern = "scratch" } },
      },
    },
    action = { type = "pin_to_display", slot = 1 },
  },
  {
    predicate = { type = "or", predicates = {
      { type = "bundle_id", value = "com.apple.systempreferences" },
      { type = "role", value = "AXSheet" },
    } },
    action = { type = "ignore" },
  },
}
```

Regex syntax is validated during config parsing. Invalid runtime-constructed regex predicates evaluate to false in the pure matcher so `matchRule` remains total.

### Tree invariants (enforced at construction)

These are not type-level — Swift can't express them — so they live in the `Cell.create`, `Split.create`, `StoredCell.create`, and `StoredSplit.create` smart constructors defined in the canonical ADT block above.

No raw `Split.init`, `Cell.init`, `StoredSplit.init`, or `StoredCell.init` is available outside the type body. All four implement custom `Decodable` through these constructors, so persisted or IPC data cannot instantiate invalid weights or one-cell splits.

Recursive invariants enforced via tests, not types:
- No `.split` with cells.count < 2 (smart constructor)
- No duplicate WindowID across all leaves (tested as property)
- No cycle (impossible by `indirect enum` shape)
- Sum of weights per Split > 0 (smart constructor)

---

## 4. Failure model

Per function, declare exception vs Result vs Optional. Anti-pattern reminder: never mix in one function.

| Function | Mode | Rationale |
|---|---|---|
| `apply(_:Command, to:World)` | `Result<World, CommandError>` | Expected business failures (no neighbor, unknown window). Pipeline-composable. |
| Tree primitives (`pushIntoTree`, `centerIntoTree`, `ejectFromTree`, structural updates) | Total functions — return same type, never fail | Push inserts or repositions deterministically; eject of a missing window is a no-op. Caller checks via `occupiedWindows`. Keeps primitives composable. |
| `nearestWindowInDirection` | `WindowID?` (Optional) | No window in direction is normal. Optional. |
| `matchRule` | `RuleAction?` (Optional) | No match is normal. |
| `windowOpenDecision(_:rules:)` | `WindowOpenDecision` (total) | No matching rule returns `.tileOrFloatByDefault`. |
| `validateCommand(_:world:)` | `Result<Command, CommandError>` | Expected business failures before transition. |
| `resolveTemplate(_:focused:)` | `Command?` (Optional) | No focused window is absence, not an error. |
| `resolveDrop(_:zones:displays:)` | `Command?` (Optional) | No matching zone/display is absence, not an error. |
| `reconcileEnvironment(_:world:)` | `World` (total) | Complete AX snapshots replace live window maps; partial/permission-denied snapshots preserve prior windows/windowDisplay and update only trusted active-Space/display metadata. |
| `resetTilingState(in:)` | `World` (total) | User-requested clean slate is a deterministic state projection, not an error-prone operation. |
| `recordObservedConstraints(_:for:in:)` | `World` (total) | Constraint observation is trusted shell data; merge by taking max of known minimums. |
| `restoreWorld(from:liveWindows:displays:activeSpace:config:)` | `World` (total) | Drops unmatched stored windows and starts from live OS state. |
| `storedWorld(from:)` | `StoredWorld` (total) | Projects active Space only; missing active Space yields empty stored world. |
| `layout(spaceState:displayID:frame:gaps:)` | `Layout` (total) | Cannot fail given valid SpaceState/display; missing display yields empty layout. |
| `solveLayout(spaceState:displayID:frame:gaps:constraints:)` | `LayoutSolveResult` (total) | Unsatisfiable minimum sizes are expected domain state, represented as `.unsatisfiable`, not thrown. |
| `inferObservedConstraints(target:actual:tolerance:)` | `WindowConstraints?` (Optional) | Absence means actual frame does not imply a min-size constraint. |
| `diff(old:new:)` | `LayoutDelta` (total) | Pure subtraction. |
| `parseConfig(_:LuaConfigData)` | `Result<Config, ConfigError>` | Validation errors carry which key failed; every numeric field must be finite and in range. |
| `AXClient.listWindows()` | `@MainActor async -> AXWindowSnapshot` | Never throws, but exposes partial/permission failure metadata so the caller can preserve prior state. |
| `AXClient.setFrame(_:_:)` | `@MainActor async -> AXFrameWriteOutcome` | App clamp is expected domain feedback; AX errors are carried as `.failed`. Do not throw for min-size refusal. |
| `AXClient.focusWindow(_:)` | `@MainActor async throws` | Infrastructure failure from AX focus/raise calls. |
| `AXClient.raiseWindow(_:)` | `@MainActor async throws` | Infrastructure failure from AX raise call. |
| `AXClient.focusedWindowID()` | `@MainActor async -> WindowID?` | Focused window may not exist or may not be accessible; absence has no useful error payload. |
| `AXObserver.start()` | `@MainActor async throws -> ServiceHandle` | Infrastructure failure if AX observer registration fails after startup permission check. |
| `SpaceClient.activeSpaceID()` | `SpaceID?` | dlsym may have failed at load; global active Space only. |
| `SpaceClient.start()` | `@MainActor async throws -> ServiceHandle` | Infrastructure failure if notification/poll source cannot be installed. |
| `DisplayClient.currentDisplays()` | `@MainActor -> [DisplayID: DisplayInfo]` | Display metadata read from AppKit can return empty; empty display map is handled downstream. |
| `DisplayClient.start()` | `@MainActor async throws -> ServiceHandle` | Infrastructure failure if display notifications cannot be registered. |
| `LuaEngine.eval(_:String)` | `async throws -> LuaValue` | Syntax/runtime errors. |
| `HotkeyManager.start()` | `@MainActor throws -> ServiceHandle` | Infrastructure failure if Carbon rejects a configured registration. |
| `EventTapClient.start()` | `async throws -> ServiceHandle` | Infrastructure failure if the event tap cannot be installed or enabled. |
| `IPCServer.start()` | `async throws -> ServiceHandle` | Infrastructure failure if Unix socket bind/listen fails. |
| `ConfigLoader.loadInitial(logger:)` | `throws -> Config` | Startup config file I/O, Lua decode, or validation can fail before last-good exists. |
| `ConfigLoader.startWatching()` | `async throws -> ServiceHandle` | Watcher skips invalid configs (logged), emits valid ones through callback. Startup failure throws. |
| `ConfigLoader.reloadNow()` | `async throws` | Manual reload returns infrastructure/syntax errors to shell caller. Valid config is sent through the same stream path. |
| `Menubar.start(reload:quit:)` | `@MainActor -> ServiceHandle` | NSStatusItem creation has no expected business failure; stop handle removes the status item. |
| `LayoutApplier.submit(_:)` | `async -> LayoutApplyResult` or callback equivalent | Per-window converged/clamped/failed results are returned or emitted as data so the actor can re-solve or reject. |
| `LayoutApplier.expectFocus(_:)` | `async` | Adds an expected focus echo; no failure payload. |
| `LayoutApplier.isExpectedEcho(_:)` | `async -> Bool` (total) | Echo table miss means false. |
| `RestorePersistence.scheduleSave(_:reason:)` | `@MainActor -> Void` | Debounces the latest restore snapshot on the AppKit run loop. Save failures are logged and a later successful outcome can schedule another save; command handling does not wait for the normal delayed write. |
| `RestorePersistence.flushPending()` | `@MainActor -> Void` | Synchronously writes any pending restore snapshot before app-owned quit or AppKit termination returns. |
| `RestoreManager.load()` | `throws -> StoredWorld?` | Throws on unreadable/corrupt JSON. Returns `nil` for "no file yet" or unsupported `schemaVersion`. |

**Result vs throws decision rule used here**: pure-core failures = `Result` (composable with `.flatMap`, no implicit propagation). Shell I/O = `throws` (idiomatic Swift, integrates with `async` cancellation). No function does both.

`validateCommand` rejects tiling/frame-mutating commands (`push`, `center`, `dropAtZone`, `resizeSplit`) for `WindowMetadata.isResizable == false` with `.windowNotResizable`. `windowOpenDecision` defaults non-resizable windows to `.forceFloat` unless a rule explicitly ignores them.

---

## 5. Mutation discipline

For every value the code reads or writes that outlives a call:

| Reference | Owner | Concurrency primitive | Why |
|---|---|---|---|
| `World` | `WorldActor` | Swift `actor` | Single state principal. All Commands serialize through actor → consistency without locks. |
| `World.windowConstraints` | `WorldActor` through pure `recordObservedConstraints` | Swift `actor` + immutable value replacement | AX clamp feedback is stateful, but merge rules are pure and replayable. No shell adapter mutates constraints directly. |
| Current Config in shell adapters | `WorldActor` source of truth; adapters rebound from successful reload outcomes | actor isolation + `@MainActor` hotkey rebind | Prevents FSEvent reload from updating only core while hotkeys/zones keep stale captured config. |
| AX subscription handles | `AXObserver` | Held in actor-isolated `Dictionary`; AX callback hops to actor before mutation | Carbon/AX callbacks fire on arbitrary threads; isolation hop enforced. |
| Hotkey registry | `HotkeyManager` | `@MainActor` (Carbon requires main thread) | Carbon `RegisterEventHotKey` is main-thread-only. |
| Lua VM | `LuaEngine` | Dedicated Lua thread + async request queue | Lua VM is not thread-safe and may assume thread affinity. No synchronous dispatch back into the queue. |
| Event tap | `EventTapClient` | CGEventTap runloop on dedicated thread; events dispatched to actor | CGEventTap callback must not block. Re-enqueue immediately. |
| FSEvent stream | `ConfigLoader` | FSEventStream on dedicated queue → actor handoff | FSEvent callbacks on arbitrary thread. |
| Space changes | `SpaceClient` | NSWorkspace notification plus active-Space dlsym read, de-duplicated in `AsyncStream`; owned by `ServiceHandle` | Native Space switches have no public typed Space ID; shell observes switch then reads current ID. |
| Display changes | `DisplayClient` | CGDisplay/NSApplication screen-change notification → `AsyncStream`; owned by `ServiceHandle` | Display topology and visible frames can change independently of window events. |
| AX inventory refresh coalescer | App shell, with pure policy in `WinMgrCore` | `@MainActor` pending timer + latest-generation token | Window open/close bursts can emit many stale-but-complete inventories. Coalesce shell-triggered environment refreshes before they enter `WorldActor`; user commands still bypass coalescing and force an immediate pre-command refresh. |
| Service task/service handles | `AppDelegate.serviceTasks` + `serviceHandles` | `@MainActor` arrays of `Task<Void, Never>` and `ServiceHandle` | Long-lived stream consumers are cancelled and registered OS services are stopped on startup failure. |
| Restore save scheduler | Pure scheduler state + `RestorePersistence` shell | `RestoreSaveSchedulerState` is immutable value state; `RestorePersistence` owns one AppKit-run-loop `Timer` and one synchronous atomic writer. | Timer callbacks may be stale; generation checks prevent stale callbacks from clearing or saving newer pending state. |
| Restore state on disk | `RestoreManager` | File written atomically (`.atomic` write option) to `~/Library/Application Support/winmgr/state.json` | One writer, one reader. `applicationWillTerminate`, app-owned quit paths, and install/uninstall graceful quit flush pending state before process exit. |
| Logger | `os.Logger` | Apple-provided, thread-safe | Trust framework. |
| AX echo suppression table | `LayoutApplier` / `AXObserver` bridge | actor-isolated map with expiry | Filters self-generated move/resize/focus events by expected origin, expected size, and expected focused `WindowID` independently. |

**No global mutable state.** No singletons (except framework-provided `NSApplication.shared` and `NSWorkspace.shared`, which are stateful but treated as opaque external services). All app-level state passes through DI.

**No `static var` in core.** Static let constants only.

---

## 6. Boundary validation

External-input boundaries and their validation:

| Boundary | Input shape | Validator | Failure mode |
|---|---|---|---|
| AX → AXWindowSnapshot | `AXUIElement` (opaque) | `AXClient.snapshot(_:AXUIElement) -> Result<WindowMetadata, AXWindowReadError>` records per-window failures and aggregate permission state. | Partial snapshot returned; caller preserves prior state when quality is not `.complete`. |
| AX frame write → constraint observation | target `CGRect`, actual `CGRect` | `inferObservedConstraints(target:actual:tolerance:)` accepts only finite positive width/height expansion as a min-size signal. | No inferred constraint for origin drift, non-finite values, zero/negative dimensions, or smaller actual frame; infrastructure errors stay `.failed`. |
| Space/display notification → EnvironmentSnapshot | `SpaceID?`, `[DisplayID: DisplayInfo]`, `AXWindowSnapshot` | Shell reads active Space, current displays, and AX windows together, then emits one `.environmentChanged`. Core reconciliation trusts complete AX snapshots; incomplete snapshots cannot delete or remap existing windows. | On partial/permission-denied AX quality, active Space/display metadata may update, but live window maps and persisted restore state are preserved until a complete snapshot arrives. |
| Lua config → Config | `LuaConfigData` (decoded from Lua stack) | `parseConfig(_:LuaConfigData)` validates types, finite numeric values, ranges, regex syntax, key spec syntax, weight > 0, etc. Returns `Result<Config, ConfigError>`. | Reload aborted; last-good retained. |
| IPC socket → IPCCommandDTO → Command → IPCReplyDTO | newline-delimited JSON | Shell decodes a Codable DTO, awaits `WorldActor.handle`, then converts `CommandOutcome` to `IPCReplyDTO`. | Reply with success/error JSON; connection stays open. |
| Restore JSON → StoredWorld | file content | `Decodable` + `validateStoredWorld(_:)`: supported `schemaVersion`, non-negative `StoredWindowRef.occurrence`, finite `lastKnownFrame`, and constructor-backed stored tree weights. Stored tree uses stable window refs, not raw `WindowID`/`DisplayID`/`SpaceID`. MVP restore applies only to the active Space because stable native-Space enumeration is not available. | Unsupported schema returns nil and starts fresh; corrupt/unreadable JSON throws. Validation failure throws `RestoreError.invalidStoredWorld`. Valid stored refs are remapped from the live AX snapshot; unmatched refs dropped. |
| FSEvent → file path | path string | Whitelist check: must be exactly `~/.config/winmgr/init.lua` (resolved). | Other paths ignored. |
| Drag drop → Command | `DragEvent` with screen point | `resolveDrop(_:zones:displays:)` hit-tests current zones and display using half-open bounds `[minX, maxX) × [minY, maxY)`; exactly one zone yields `.dropAtZone(window, display, zone)`. | Drop discarded. |
| Hotkey fire → Command or shell reload | `HotkeyAction` + active window query | `.command(template)` uses `resolveTemplate(_:focused:)`; `.reloadConfig` calls `ConfigLoader.reloadNow()`. | Window-scoped hotkey ignored with debug log if no focused window; reload errors logged. |

Inputs from the **OS itself** (AX events, NSWorkspace notifications) treated as trusted in *form* but possibly stale (window already closed). Every Command handler in `apply` re-checks identity (`world.windows[id]`) before acting → handles stale events gracefully.

**Pydantic/Malli analog in Swift**: `Codable` + post-decode validation in a `parseFoo() -> Result<Foo, FooError>` function. Decode-then-validate (two-phase) keeps each phase simple.

**Restore matching policy**: `storedWorld(from:)` assigns each `StoredWindowRef.occurrence` by grouping live windows on `(bundleID, title, role)` and sorting by stable frame order. `restoreWorld(...)` builds candidate live windows by that same key, prefers the matching occurrence, then uses `lastKnownFrame` distance as a tie-breaker. Every live `WindowID` is consumed at most once. If ambiguity remains after occurrence and frame distance, the stored leaf is dropped rather than duplicating one live window into multiple tree leaves.

`RestoreManager.load()` is the restore boundary: it decodes JSON, checks `schemaVersion`, runs `validateStoredWorld(_:)`, returns nil for missing/unsupported schema, and throws for unreadable/corrupt/invalid persisted state.

---

## 7. Dependency injection plan

Swift idiom: **constructor injection**, no service locator, no global container.

The composition root below is the post-MVP target. During MVP Rungs 1-4, `App.swift` contains only the AppKit lifecycle, Accessibility gate, minimal AX client, and one hotkey. Rung 5 introduces `WorldActor`/`LayoutApplier`; later rungs add config, observers, restore, overlays, IPC, and drag in the order defined by the MVP ladder.

```swift
// Composition root: WinMgrShell/App.swift.
// AppKit owns the main run loop; async services start from the delegate.

struct ServiceHandle: Sendable {
    let name: String
    let stop: @Sendable () async -> Void
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()
    private let logger = AppLogger()
    private let restorePersistence = RestorePersistence(manager: RestoreManager())
    @MainActor private var serviceTasks: [Task<Void, Never>] = []
    @MainActor private var serviceHandles: [ServiceHandle] = []

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = instance
        app.run()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await startServices(logger: logger)
            } catch {
                await stopStartedServices()
                await MainActor.run {
                    logger.app.fault("startup failed: \(String(describing: error))")
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        restorePersistence.flushPending()
        Task { await stopStartedServices() }
    }

    @MainActor
    private func launchServiceTask(_ operation: @escaping @Sendable () async -> Void) {
        serviceTasks.append(Task(operation: operation))
    }

    @MainActor
    private func registerService(_ handle: ServiceHandle) {
        serviceHandles.append(handle)
    }

    @MainActor
    private func stopStartedServices() async {
        serviceTasks.forEach { $0.cancel() }
        serviceTasks.removeAll()
        let handles = Array(serviceHandles.reversed())
        serviceHandles.removeAll()
        for handle in handles {
            await handle.stop()
        }
    }

    @MainActor
    private func startServices(logger: AppLogger) async throws {
        let config = try ConfigLoader.loadInitial(logger: logger)
        let axClient = AXClient(logger: logger)
        let spaceClient = SpaceClient(logger: logger)
        let displayClient = DisplayClient(logger: logger)
        let restoreManager = RestoreManager(logger: logger)

        let snapshot = await axClient.listWindows()
        guard snapshot.quality == .complete else {
            throw StartupError.axSnapshotUnavailable(snapshot.quality)
        }

        let activeSpace = spaceClient.activeSpaceID()
        let stored = try restoreManager.load()
        let initialWorld = restoreWorld(
            from: stored ?? .empty,
            liveWindows: snapshot.windows,
            displays: displayClient.currentDisplays(),
            activeSpace: activeSpace,
            config: config
        )

        let worldActor = WorldActor(initial: initialWorld, logger: logger)
        let layoutApplier = LayoutApplier(axClient: axClient, logger: logger)
        let axObserver = AXObserver(axClient: axClient, logger: logger)
        let overlay = Overlay(border: config.border, hud: config.hud, logger: logger)
        let menubar = Menubar(logger: logger)

        func envelope(_ command: Command, source: CommandSource) -> CommandEnvelope {
            CommandEnvelope(id: CommandID(raw: UUID().uuidString), source: source, command: command)
        }

        @MainActor
        func sendEnvironmentChanged(
            activeSpace: SpaceID?,
            displays: [DisplayID: DisplayInfo],
            source: CommandSource
        ) async -> CommandOutcome {
            let snapshot = await axClient.listWindows()
            let env = EnvironmentSnapshot(activeSpace: activeSpace, displays: displays, axSnapshot: snapshot)
            return await worldActor.handle(envelope(.environmentChanged(env), source: source))
        }

        let configLoader = ConfigLoader(
            send: { @Sendable cfg in
                Task { await worldActor.handle(envelope(.reloadConfig(cfg), source: .config)) }
            },
            logger: logger
        )

        let hotkeyManager = HotkeyManager(
            config: config,
            fire: { @MainActor action in
                switch action {
                case .command(let template):
                    Task {
                        let focused = await axClient.focusedWindowID()
                        guard let command = resolveTemplate(template, focused: focused) else { return }
                        await worldActor.handle(envelope(command, source: .hotkey))
                    }
                case .reloadConfig:
                    Task {
                        do { try await configLoader.reloadNow() }
                        catch { logger.config.error("manual reload failed: \(String(describing: error))") }
                    }
                }
            },
            logger: logger
        )

        let eventTapClient = try EventTapClient(
            dragModifier: config.dragModifier,
            send: { @Sendable drag in
                Task {
                    let currentConfig = await worldActor.configSnapshot()
                    let displays = await worldActor.displaySnapshot()
                    guard let command = resolveDrop(drag, zones: currentConfig.zones, displays: displays) else { return }
                    await worldActor.handle(envelope(command, source: .drag))
                }
            },
            logger: logger
        )

        let ipcServer = try IPCServer(
            handle: { @Sendable dto async -> IPCReplyDTO in
                let command = dto.toCommand()
                let outcome = await worldActor.handle(envelope(command, source: .ipc))
                return IPCReplyDTO.from(outcome)
            },
            logger: logger
        )

        launchServiceTask {
            for await outcome in await worldActor.outcomes {
                switch outcome {
                case .success(_, let newWorld, let effects):
                    if let updatedConfig = effects.configChanged {
                        await MainActor.run {
                            hotkeyManager.rebind(updatedConfig.keymap)
                            overlay.updateConfig(border: updatedConfig.border, hud: updatedConfig.hud)
                            menubar.updateConfigStatus(.loaded)
                        }
                        await eventTapClient.updateModifier(updatedConfig.dragModifier)
                    }

                    if let desired = effects.desiredLayout {
                        await layoutApplier.submit(desired)
                    }

                    if let focusBorder = effects.focusBorder {
                        await MainActor.run {
                            overlay.updateFocusBorder(focusBorder)
                        }
                    }

                    for raised in effects.raises {
                        do { try await axClient.raiseWindow(raised) }
                        catch { logger.ax.error("raise failed for \(raised.description): \(String(describing: error))") }
                    }

                    if let focused = effects.focus {
                        await layoutApplier.expectFocus(focused)
                        do { try await axClient.focusWindow(focused) }
                        catch { logger.ax.error("focus failed for \(focused.description): \(String(describing: error))") }
                    }

                    if effects.persistRestore {
                        await restoreManager.scheduleSave(storedWorld(from: newWorld))
                    }
                case .failure(let envelope, let error):
                    logger.core.error("command failed id=\(envelope.id.raw) source=\(envelope.source.rawValue) error=\(error.code)")
                    if case .config = envelope.source {
                        await MainActor.run { menubar.updateConfigStatus(.failed(error.message)) }
                    }
                }
            }
        }

        launchServiceTask {
            for await event in await axObserver.events {
                guard await layoutApplier.isExpectedEcho(event) == false else { continue }
                await worldActor.handle(envelope(event.toCommand(), source: .ax))
            }
        }

        launchServiceTask {
            for await spaceID in spaceClient.events {
                let displays = await MainActor.run {
                    displayClient.currentDisplays()
                }
                let outcome = await sendEnvironmentChanged(
                    activeSpace: spaceID,
                    displays: displays,
                    source: .space
                )
                if case .success = outcome {
                    await MainActor.run { overlay.showSpaceHUD(spaceID) }
                }
            }
        }

        launchServiceTask {
            for await displays in displayClient.events {
                await sendEnvironmentChanged(
                    activeSpace: spaceClient.activeSpaceID(),
                    displays: displays,
                    source: .display
                )
            }
        }

        registerService(try await ipcServer.start())
        registerService(try await eventTapClient.start())
        registerService(try await configLoader.startWatching())
        registerService(try await axObserver.start())
        registerService(try await spaceClient.start())
        registerService(try await displayClient.start())
        registerService(try hotkeyManager.start())
        registerService(menubar.start(
            reload: { Task { try? await configLoader.reloadNow() } },
            quit: { @MainActor in NSApplication.shared.terminate(nil) }
        ))

        await worldActor.handle(envelope(.startupConverge, source: .restore))
    }
}
```

The final `.startupConverge` command is intentional even though `initialWorld` is already restored in memory: it leaves `World` unchanged but causes `WorldActor` to emit the first `DesiredLayout`, focus-border effect, and restore persistence decision before any user input, so AX state converges to the restored tree immediately after services are registered.

All `start()` methods in this snippet are registration methods: they bind sockets, install taps/watchers/observers, launch their owned background loop if needed, and return a `ServiceHandle`. Startup registers each handle immediately; if a later registration fails, `stopStartedServices()` cancels stream-consumer tasks and stops registered services in reverse order. `applicationWillTerminate` first flushes pending restore persistence synchronously, then uses the same cleanup path for normal shutdown. Install/uninstall scripts request `winmgrctl quit` before falling back to `launchctl bootout` so the app gets the same flush path when possible. Process lifetime remains `NSApplication.shared.run()`.

**Twenty-parameter caveat (fp-architect Step 7)**: components do approach 4-6 params. Mitigation: pass a `Dependencies` struct only when count exceeds 6. As of design time, each component sits under the threshold; revisit if it creeps.

**Why not Swift's `@Environment` or property wrappers?** Those are for SwiftUI views. The daemon isn't a SwiftUI app. Plain init injection is simpler and more testable.

**Closures over actors as inputs**: callbacks either run on `@MainActor` (Carbon hotkeys/AppKit) or immediately hop with `Task { await worldActor.handle(envelope) }`. This decouples managers from `WorldActor`'s concrete type. HotkeyManager tests pass a closure that records templates.

---

## 8. Concurrency primitive selection

| Surface | Primitive | Rationale |
|---|---|---|
| Mutable World | Swift `actor` (WorldActor) | Single state principal. Built-in serialization. Re-entrant via `await`. Tested with deterministic stubs. |
| AppKit/AX calls | `@MainActor` annotation on functions / `MainActor.run` hop | Apple's frameworks require main thread. Compiler-enforced. |
| AX events from C callbacks | Hop to `WorldActor` via `Task { await worldActor.handle(envelope) }` after echo filtering | AX callbacks fire on framework run loops; filtering prevents self-generated layout and focus writes from reentering as external moves/focus changes. |
| CGEventTap | Dedicated runloop thread; emits via `AsyncStream` continuation | Tap callback must not block. |
| FSEvent | FSEventStream on serial dispatch queue → `AsyncStream` | Same constraint. |
| AppKit/AX-facing adapters | `@MainActor` APIs for AppKit/AX reads and writes; background tasks call them with `await` or `MainActor.run` | Keeps non-Sendable framework interaction compiler-enforced at the boundary. DTOs crossing streams are immutable values. |
| IPC accept loop | `Task` per connection (cap N=8); each reads + dispatches Commands | Bounded concurrency. |
| Lua VM | Dedicated Lua thread with async request queue and continuations | Lua state is not thread-safe and may assume thread affinity. No synchronous dispatch back into the queue; no reentrant deadlock path. |
| LayoutApplier batched writes | `@MainActor`. Batch up to 16 AX writes per tick; yield between batches; drop stale generations. | AX writes are slow (~10-30ms). Yielding keeps the run loop responsive and latest generation wins. |
| Property test harness | Pure sync | Tests are sync. |

**Async coloring (fp-architect §5.9)**: pure core is fully sync. Shell is mostly async. The pure / shell boundary is also the sync / async boundary. WorldActor's `handle(_:)` is `async`, but internally calls `apply(_:to:)` which is sync. Async ends at the actor boundary; doesn't propagate into core.

**Decision: no Combine.** Use `AsyncStream` / `AsyncSequence` directly. Combine adds dependencies and Apple is steering away from it. Plain async sequences integrate cleanly with `for await`.

**Decision: no GCD outside of dispatch-sourced APIs** (CGEventTap, FSEvent require runloops / DispatchQueues; otherwise use Task / actor).

---

## 9. Property-based test plan

Hand-rolled property harness in `Tests/WinMgrCoreTests/PropertyHarness.swift`. ~80 lines: `Gen<T>` w/ random + shrink. Inspired by Hypothesis, not SwiftCheck.

```swift
struct Gen<A> {
    let generate: (inout Random) -> A
    let shrink: (A) -> [A]
}

func property<A>(_ name: String, gen: Gen<A>, _ body: (A) -> Bool, iterations: Int = 100) throws
// Uses Swift Testing's #expect — fails with shrunk minimal example.
```

Generators needed:

- `Gen<WindowID>` (fixed small pool for collision tests)
- `Gen<Node>` (depth-bounded, balanced/skewed/empty mixes)
- `Gen<World>` (small Spaces, per-display trees, varying focus, mixed float/tile)
- `Gen<Direction>` (uniform)
- `Gen<Command>` (focused window guaranteed valid for command type)
- `Gen<StoredWorld>` (active-Space stored layout, stable window refs, display slots, schema version)

### Properties

| Property | Holds for | Statement |
|---|---|---|
| `slots(in: tree)` includes both `.empty` and `.occupied` terminal nodes | Any Node | Empty zones are first-class layout slots, not discarded windows. |
| `occupiedWindows(in: tree)` equals the occupied subset of `slots(in: tree)` | Any Node | AX-facing window traversal cannot accidentally include empty zones. |
| `pushIntoTree(w, dir, tree).occupiedWindows == tree.occupiedWindows ∪ {w}` (when w ∉ tree.occupiedWindows) | Any Node, Direction, fresh WindowID | Push adds exactly the new window. |
| `pushIntoTree(w, dir, tree).occupiedWindows` contains `w` exactly once (when w ∈ tree.occupiedWindows) | Any Node, Direction, present WindowID | Push repositions an already-present window by replacing its old leaf with `.void` and reinserting it, but never duplicates it. |
| `ejectFromTree(w, pushIntoTree(w, dir, tree)).occupiedWindows == tree.occupiedWindows` | Any tree without w | Eject removes the pushed window without removing existing windows. Zone shape may include a new `.void` lane because zones are persistent. |
| `pruneTree(tree, keeping: live).occupiedWindows ⊆ live` and repeated prune is idempotent | Any tree, live window set | Reconciliation removes dead windows but preserves split shape and existing empty zones. |
| `layout(s, displayID, frame, gaps).tiled.values.reduce(0, area) ≤ frame.area` | Any SpaceState, display, frame, gaps | Layout doesn't overflow. |
| Layout rects have finite, non-negative dimensions | Any SpaceState, display, frame, gaps | Large gaps and zero-area frames clamp without NaN/negative sizes. |
| Layout rects pairwise disjoint | Any SpaceState | No overlap. |
| `solveLayout(..., constraints: [:]) == .solved(layout(...), .exact)` | Any valid SpaceState/display/frame/gaps | Constrained solver degenerates to existing layout when no constraints exist. |
| `solveLayout` respects every satisfiable min constraint | Generated tree + constraints where required <= available | Every constrained leaf frame is at least its min width/height after gaps. |
| `solveLayout` returns `.unsatisfiable` exactly when required > available on a split axis | Generated split + constraints | No silent overlap or below-min frames for impossible layouts. |
| `recordObservedConstraints` is monotonic | Any existing/new constraint pair | Merging never lowers an observed minimum. |
| `resetTilingState` preserves live inventory and clears layout memory | Any World | Displays, windows, windowDisplay, and config are unchanged; trees/floating/focus/windowConstraints/pendingRules are empty. |
| `apply(cmd, world).success` is idempotent for system events with no actual change | Repeated `windowMovedExternally(w, f)` where world already has w at f | No-op replay. |
| `nearestWindowInDirection(.right, from: x, ...) != x` | non-empty layout | Returns a different window or nil. |
| `nearestWindowInDirection` is acyclic | Layout | Moving repeatedly in same direction visits each window ≤ once before returning nil. |
| Stored restore round-trip: `decode(encode(stored)) == stored` | Any StoredWorld | Restore JSON codec stability. |
| Diff changed-key exactness: `diff(a, b).moves[id] == b.tiled[id]` for every changed/added tiled rect, and unchanged rects are omitted | Any Layout pair | Delta is an optimization hint over full `DesiredLayout.layout`, not the source of truth. |
| Drop resolution is exclusive: overlapping zones return nil | Any DragEvent + zones | Ambiguous drag zones do not choose arbitrarily; edge hits use half-open bounds. |
| Default zones are exclusive | `DefaultZones.entries` | Every point can match at most one default zone. |

### Per-function test coverage

| Function | Min tests | Property tests |
|---|---|---|
| pushIntoTree | 10 (each Direction × {empty, occupied lane, opposite lane, repeated lane}, plus `HLHHL` and `HLJK`) | edge-lane shape examples + leaf-count + no duplicates |
| quarterIntoTree | 6 (each corner from empty tree, persistent opposite void lane, repeated corner into existing side lane) | exact corner frame + no duplicate occupied windows |
| centerIntoTree | 4 (empty / has root / center already populated / center deeply nested) | preserves outer cells |
| ejectFromTree | 6 (leaf in {top, mid, deep}, with/without sibling voids) | leaf removed, zone shape preserved |
| layout | 8 (void / leaf / binary split / 3-cell / nested / with gaps / degenerate ratios / zero-area) | sum-of-areas + disjoint |
| solveLayout | 10 (no constraints / leaf min / horizontal sum / vertical sum / nested / exact min fit / unsat horizontal / unsat vertical / gap-adjusted min / observed Finder 500px case) | no-constraints equivalence + min-respect + unsat iff required > available |
| inferObservedConstraints | 5 (exact / width clamp / height clamp / both / origin-only drift) | never infers from origin drift; inferred mins equal actual clamped dimension |
| diff | 4 (no change / pure adds / pure removes / mixed) | changed-key exactness; unchanged rects omitted |
| nearestWindowInDirection | 6 (single dir × {tile-only, float-only, mixed, none-in-dir, ties}) | acyclic |
| apply (per Command variant) | 1-2 each | error cases per Command, including `windowConstraintObserved` monotonic merge |
| matchRule | 4 (bundle / regex / role / composite) | first-match-wins |
| windowOpenDecision | 4 (no match / forceFloat / ignore / pinToDisplay) | first matching rule maps to exact decision |
| resolveTemplate | 5 (nil focus / each focused-window command / focus direction without window) | nil focus only suppresses window-scoped commands |
| resolveDrop | 5 (no display / no zone / one zone / overlap / display-specific bounds) | exclusivity |
| resetTilingState | 3 (empty / active tree / multi-Space) | inventory-preserving layout-memory clear |
| reconcileEnvironment | 4 (complete snapshot / partial snapshot / permission denied / display remap) | complete replaces live maps; incomplete preserves windows/windowDisplay and suppresses persist/layout effects |
| restoreWorld / storedWorld | 10 (exact match / fuzzy title / duplicate occurrence / missing window / display remap / active-Space-only restore / pending rule / schema empty / invalid stored split decode / invalid occurrence or frame decode) | stored JSON round-trip + constructor-backed decode rejection |
| parseConfig | 8 (each error case) | accepts valid decoded data; rejects exact bad key/type/range |

Total ≈ 130 example tests + 20 property tests. Achievable in the per-phase budget.

---

## 10. Persistence

| Value type | Representation | Notes |
|---|---|---|
| Small immutable records (WindowID, Direction, etc.) | `struct` with `let` | Swift value semantics + COW. No `pyrsistent`-equivalent needed. |
| Tree (Node, Split, Cell) | `indirect enum` | Recursive enums are reference-counted internally but observed as value types. Sharing happens automatically (copy is cheap until mutation). |
| World | `struct` w/ `Dictionary`/`Array` fields | Swift COW handles persistence efficiency. Update via explicit `with...` helpers. |
| Bulk-build hot path | Direct `[Cell]` array build then construct Split | No mutable scope leakage. |
| Tabular workloads | N/A — we have no tabular data. | If we add metrics: skip Polars, use plain `[Sample]`. |
| Restore JSON | `StoredWorld` via `Codable` to `~/Library/Application Support/winmgr/state.json` | Debounced atomic write. Schema-versioned. Contains active-Space stored layout, stable window refs, and display slots; no raw OS IDs. |

**No `class` types in `WinMgrCore`.** All types are `struct` or `enum`. Reference types (`AXUIElement`, etc.) live only in `WinMgrShell`.

`World` is intentionally **not** `Codable`. It contains live OS identity (`WindowID`, `DisplayID`, `SpaceID`) that is only meaningful for the current session. Persistence goes through `storedWorld(from:)`, which projects only the active Space into stable descriptors, then `restoreWorld(...)` remaps those descriptors to live AX windows.

---

## 11. Simple vs easy

Per design step, the Hickey check:

| Choice | Simple or Easy? | Justification |
|---|---|---|
| Pure `apply(Command, World)` over an OO `World.applyCommand()` method | Simple | Pure function has one role: state transition. Not braided with identity, lifecycle, observation. |
| Swift `actor` for WorldActor | Simple | One concurrency primitive, one purpose (serialization). Built-in language feature, not a runtime library. |
| Vanilla Lua over LuaJIT | Simple AND easy | LuaJIT is "fast but complex" (arm64 packaging, fork maintenance). Lua 5.4 is "slower but simple". For config eval, vanilla is plenty. Saves us a recurring port burden. |
| Hand-rolled property harness over SwiftCheck | Simple | One file, ~80 lines, no external dep, no XCTest binding, plays with Swift Testing. SwiftCheck would be "easy" (familiar) but adds a maintained dep we don't control. |
| N-ary `cells: [Cell]` over nested binary `Split` | Simple | One concept (a split of N parts) instead of two (binary split + composition rules for ternary via nesting). Center-anchor is a 3-cell split, not a contortion of binary. |
| Native Mac Spaces over virtual workspaces | Easy over Simple — deliberate | "Use what's there" wins despite the limitation (no programmatic Space moves). Cost: active-Space-only restore in MVP and no rule action that moves windows across Spaces. Acceptable. |
| One private read-only `dlsym` (CGSGetActiveSpace) | Easy over Simple — deliberate | Strictly public would force one global layout. One symbol gives true runtime active-Space sub-state for the focused environment without taking on private APIs for enumerating every Space. Cost: restore is active-Space-only and macOS major-version retest. |
| Plain init-injection DI | Simple | No container, no service locator, no global registry. Each component's deps are visible at construction. |
| FSEvent + parse + atomic swap for config | Simple | Three small stages, each named. Not a Combine pipeline graph. |
| WorldActor emits `CommandEffects` via `AsyncStream` | Simple | Producer/consumer split. LayoutApplier receives layout submissions non-blockingly; focus/raise effects are explicit shell writes. |
| Lua API surface (`winmgr.keymap`, `winmgr.rule`, `winmgr.zone`) | Easy | Familiar pattern for users from neovim/Hammerspoon. Implementation cost in the engine — three small registrations. |
| Smart constructors (`Split.create`) | Simple | Invariant enforcement at the only entry point. No "TODO: validate elsewhere too." |

**Three deliberate "easy over simple" choices**, each documented with cost. All others trend simple.

---

## 12. Event-sourcing / schema evolution

**N/A — not event-sourced.** The system is command-driven (Commands flow in, World flows forward) but persistence is full-state-snapshot, not append-only event log.

**However**, two persistence artifacts need schema versioning:

| Artifact | Versioning |
|---|---|
| `~/Library/Application Support/winmgr/state.json` (restore) | `schemaVersion: Int`, currently 1. Contains `StoredWorld` only: active-Space stored tree, stable window refs, display slots/fingerprints, and pending rules. On mismatch, ignore file (start fresh). No backward migration. |
| `init.lua` config schema | No versioning needed — schema is enforced at parse time. Old configs that don't use new fields continue to work (defaults applied). Removed fields trigger a parse error (loud, intentional). |

If we ever add an event log (e.g., for analytics or replay debugging), revisit this section with the full §7.3 schema-evolution rules: events immutable, additive fields only, versioned types.

---

## 13. Logging & observability

`os.Logger` (Apple's structured logger) via a thin wrapper. Hierarchical subsystem + category.

```swift
final class AppLogger {
    let app     = Logger(subsystem: "ca.quantim.winmgr", category: "app")
    let core    = Logger(subsystem: "ca.quantim.winmgr", category: "core")
    let ax      = Logger(subsystem: "ca.quantim.winmgr", category: "ax")
    let lua     = Logger(subsystem: "ca.quantim.winmgr", category: "lua")
    let ipc     = Logger(subsystem: "ca.quantim.winmgr", category: "ipc")
    let layout  = Logger(subsystem: "ca.quantim.winmgr", category: "layout")
    let hotkey  = Logger(subsystem: "ca.quantim.winmgr", category: "hotkey")
    let config  = Logger(subsystem: "ca.quantim.winmgr", category: "config")
    let restore = Logger(subsystem: "ca.quantim.winmgr", category: "restore")
}
```

**Logging in pure core**: disallowed. Core returns `CommandOutcome`, `CommandError`, `CommandEffects`, `DesiredLayout`, and other data that shell logs. No core function accepts a logger or logging closure.

**Levels:**
- `.debug` — every Command applied, every AX call dispatched. Verbose. Off by default. Toggled via `--debug` flag.
- `.info` — Space changed, config reloaded, daemon start/stop, restored session.
- `.notice` — rules applied (when a window's behavior was modified by a rule).
- `.error` — AX call failed, Lua eval threw, IPC client sent malformed Command.
- `.fault` — invariant violated (e.g., tree contains duplicate WindowID). Programmer error.

**Sinks:**
- `os.Logger` → Console.app (default, automatic).
- Additional rolling file at `~/Library/Logs/winmgr/winmgr.log` (max 10MB × 5 rotations). Implemented as a direct `FileLogSink` fed by the shell logger wrapper. Optional — debug builds only by default.

**Correlation IDs**: each Command gets a UUID string at the shell boundary (hotkey / drag / IPC / AX / Space / display event). The value flows through logs for tracing as `CommandEnvelope { id: CommandID, source: CommandSource, command: Command }` — *not* in `Command` itself, and generated only in shell.

**Tracing/metrics**: out of scope for MVP. If added later, OpenTelemetry-Swift compatible.

---

## 14. Pipeline naming & introspection

Pure pipelines are short in this app — most flow is in the actor `handle` method. Still, name every stage:

```swift
// WorldActor.handle internal pipeline
actor WorldActor {
    nonisolated let outcomes: AsyncStream<CommandOutcome>
    private let outcomesContinuation: AsyncStream<CommandOutcome>.Continuation
    private let logger: AppLogger
    private var world: World

    init(initial: World, logger: AppLogger) {
        let outcomeStream = AsyncStream.makeStream(of: CommandOutcome.self)
        self.outcomes = outcomeStream.stream
        self.outcomesContinuation = outcomeStream.continuation
        self.logger = logger
        self.world = initial
    }

    func handle(_ envelope: CommandEnvelope) async -> CommandOutcome {
        let validated = validateCommand(envelope.command, world: world)
        let transitioned = validated.flatMap { apply($0, to: world) }

        switch transitioned {
        case .success(let new):
            let previousLayouts = layoutsByDisplay(of: world)
            let nextLayouts = layoutsByDisplay(of: new)
            let desired = DesiredLayout(
                generation: nextGeneration(),
                layout: flatten(nextLayouts),
                delta: diff(old: flatten(previousLayouts), new: flatten(nextLayouts))
            )
            let effects = effectsForCommand(envelope.command, old: world, new: new, desiredLayout: desired)
            let outcome = CommandOutcome.success(envelope: envelope, newWorld: new, effects: effects)
            world = new
            outcomesContinuation.yield(outcome)
            return outcome
        case .failure(let err):
            let outcome = CommandOutcome.failure(envelope: envelope, error: err)
            outcomesContinuation.yield(outcome)
            return outcome
        }
    }
}
```

Each stage named. No anonymous closures inside the pipeline.

Private `WorldActor` helpers used above:
- `layoutsByDisplay(of:) -> [DisplayID: Layout]` computes one layout per display in the active Space.
- `flatten(_:) -> Layout` merges per-display layouts into the `LayoutApplier` input shape.
- `nextGeneration() -> LayoutGeneration` increments an actor-isolated counter; no clock or randomness in core.
- `effectsForCommand(_:old:new:desiredLayout:) -> CommandEffects` turns pure state differences into shell instructions: layout submission, focus target for user commands that require a programmatic focus write, focus-border show/hide from the final focused window frame, raise order from `LayoutDelta.raises`, config-change marker, and restore-persistence marker. For `.windowFocusedExternally`, it updates the focus border but leaves `effects.focus == nil` so external focus observations never trigger another focus write.

For `.windowOpened`, `apply` calls `windowOpenDecision(metadata, rules: world.config.rules)` and applies the resulting `WindowOpenDecision`. This keeps rule handling as a typed domain decision instead of rewriting one command into another command.

For `.environmentChanged`, `apply` calls `reconcileEnvironment`. When `EnvironmentSnapshot.axSnapshot.quality == .complete`, reconciliation replaces `world.windows`, recomputes `windowDisplay` from live frames and current displays, switches `activeSpace`, and replaces closed-window leaves with `.void` for the active Space while preserving split shape. When quality is `.partial` or `.permissionDenied`, reconciliation updates only `activeSpace` and `displays`; it preserves previous `windows`, `windowDisplay`, tree membership, and restore projection. `effectsForCommand` emits no desired layout and sets `persistRestore == false` for incomplete environment snapshots, preventing stale AX reads from moving or persisting the wrong windows.

If a hotkey arrives during that incomplete-snapshot interval, normal `validateCommand` still gates the focused `WindowID` against `world.windows`. Unknown current-Space windows are ignored until the next complete environment snapshot rather than mapped onto stale state.

AX inventory refresh coalescing is a shell-only optimization backed by a pure state machine. `AXObserver` may detect multiple `.windowOpened` / `.windowClosed` events in one app launch, tab detach, window restore, or Space settle burst; `DisplayObserverService` may also detect display topology changes while the app is idle. Those events schedule one coalesced `EnvironmentSnapshot` refresh after a short debounce window, not one refresh per event. The coalescer keeps only shell data: pending reasons, a scheduled timer/task, and a monotonically increasing request generation. It does not buffer or transform `Command`s, and it does not alter `reconcileEnvironment`.

Coalescing rules:
1. User commands (`push`, `center`, `swap`, focus, drag, IPC) bypass the coalescer and perform their existing immediate pre-command environment refresh.
2. AX inventory, Space-settle, and display-change refresh requests are coalesced for 100 ms.
3. A newer coalesced request cancels or supersedes the older scheduled request by generation.
4. A coalesced refresh persists restore state only after a complete AX snapshot is applied.
5. Partial or permission-denied AX snapshots do not clear the pending generation; the next complete snapshot still reconciles live inventory.

Restore persistence uses the same split: `RestoreSaveSchedulerState` is pure value state with schedule/fire/flush/cancel transitions, and the shell owns the AppKit timer plus atomic file write. A stale timer generation is data, not control flow: it cannot clear or save a newer pending request. Normal command outcomes schedule a delayed save; app-owned quit, `applicationWillTerminate`, and graceful install/uninstall quit paths call `flushPending()` synchronously before process exit.

For `.startupConverge`, `apply` returns the existing `World` unchanged. The command exists only to drive `effectsForCommand` through the normal outcome stream after startup restore has constructed the initial in-memory World.

**Schema validation between stages**: not formal — we use the type system. Each stage's return type is its schema.

**Introspection hooks**: in debug builds, `WorldActor` exposes `var lastNCommands: [CommandOutcome]` (ring buffer of last 64) for the IPC `winmgrctl debug history` command. Off by default; gated by `--debug`.

---

## 15. Nested updates

`World` uses `let` fields, so writable key-path mutation does not compile. Use explicit copy helpers instead of pretending immutable fields are writable lenses:

```swift
extension World {
    func withSpaces(_ transform: ([SpaceID: SpaceState]) -> [SpaceID: SpaceState]) -> World {
        World(
            displays: displays,
            activeSpace: activeSpace,
            spaces: transform(spaces),
            windows: windows,
            windowDisplay: windowDisplay,
            pendingRules: pendingRules,
            config: config
        )
    }

    func withSpace(_ id: SpaceID, _ transform: (SpaceState) -> SpaceState) -> World {
        guard let s = spaces[id] else { return self }
        return withSpaces { old in
            var copy = old
            copy[id] = transform(s)
            return copy
        }
    }

    func withDisplaySpace(_ spaceID: SpaceID, _ displayID: DisplayID, _ transform: (DisplaySpaceState) -> DisplaySpaceState) -> World {
        withSpace(spaceID) { space in
            guard let displayState = space.displays[displayID] else { return space }
            var displays = space.displays
            displays[displayID] = transform(displayState)
            return SpaceState(id: space.id, displays: displays, focused: space.focused)
        }
    }
}

// Usage
let newWorld = world.withDisplaySpace(spaceID, displayID) { ds in
    DisplaySpaceState(displayID: ds.displayID, tree: pushIntoTree(w, .left, ds.tree), floating: ds.floating)
}
```

No external lens library needed. Sum types (enums) need custom matchers — done as `extension Node { var asSplit: Split? { ... } }` when needed.

**Depth limit triggering more sophistication**: if World access exceeds 3 levels of nesting routinely, revisit. As designed, max nest is `world.spaces[spaceID]?.displays[displayID]?.tree`.

---

## 16. Verification plan

| Layer | Test type | Where |
|---|---|---|
| Pure core (tree, layout, focus, apply) | Example + property tests via Swift Testing | `Tests/WinMgrCoreTests/` |
| Min-size layout solver | Example + property tests for no-constraint equivalence, constrained allocation, unsatisfiable detection, and observed Finder 500px clamp | `Tests/WinMgrCoreTests/LayoutSolverTests.swift` |
| Smart constructors | Example tests verifying rejection of invalid inputs | `Tests/WinMgrCoreTests/`ADTTests.swift |
| Rules engine | Truth-table/property tests for `and`/`or`/`not`, regex predicates, and first-match-wins ordering | `Tests/WinMgrCoreTests/RulesTests.swift` |
| StoredWorld Codable round-trip | Property | `Tests/WinMgrCoreTests/StoredWorldCodableTests.swift` |
| Restore remap | Example + property tests for fuzzy stored refs to live windows | `Tests/WinMgrCoreTests/RestoreTests.swift` |
| AXClient (shell) | Integration test against real AX with a known test app (e.g. spawn `TextEdit`); assert complete/partial snapshot, setFrame, raise, and focus behavior | `Tests/WinMgrShellTests/AXClientTests.swift` |
| LayoutApplier | Integration: submit stale and current `DesiredLayout`, assert latest generation wins via AX re-query; submit below-min Finder/TextEdit frame and assert clamp is returned as `AXFrameWriteOutcome.clamped` | `Tests/WinMgrShellTests/ApplierTests.swift` |
| AX echo suppression | Integration: self-generated move-only, resize-only, combined frame, and focus callbacks do not persist as external move/resize/focus commands | `Tests/WinMgrShellTests/AXEchoTests.swift` |
| AX inventory refresh coalescing | Pure unit test: open/close/display/Space-settle burst produces one latest-generation request; stale generations cannot run or clear newer pending work; partial AX snapshot retains pending state and does not imply restore persistence | `Tests/WinMgrCoreTests/EnvironmentRefreshCoalescerTests.swift` |
| Overlay | Unit/integration: focus-border effect shows/moves/hides border from outcomes; Space HUD only from Space-sourced environment changes | `Tests/WinMgrShellTests/OverlayTests.swift` |
| HotkeyManager | Unit test with mock Carbon-bind closure; reload rebinds exact new keymap | `Tests/WinMgrShellTests/HotkeyTests.swift` |
| LuaEngine | Unit test: eval simple expressions, exposed function calls return | `Tests/WinMgrShellTests/LuaTests.swift` |
| ConfigLoader | Integration: write a temp init.lua, start watcher with recording callback, mutate file, observe exact callback emission and adapter rebind/update | `Tests/WinMgrShellTests/ConfigLoaderTests.swift` |
| RestoreManager | Unit/integration: load/save boundary returns nil for no file and unsupported schema, throws typed failures for corrupt JSON and invalid persisted `StoredWorld`, round-trips saved state from a temp path, pure scheduler tests prove latest-wins/stale-generation/flush/cancel semantics exactly, shell tests prove synchronous flush writes the latest `StoredWorld`, cancellation drops pending writes, and failures are reported without blocking later successful saves. | `Tests/WinMgrAppSupportTests/RestoreManagerTests.swift` |
| IPC | Integration: in-proc client + server, send valid and invalid commands, assert exact `IPCReplyDTO` success/error JSON and open connection reuse | `Tests/WinMgrShellTests/IPCTests.swift` |
| Menubar | Unit/integration: starts NSStatusItem, reload action invokes loader, quit action terminates app delegate path, stop handle removes item | `Tests/WinMgrShellTests/MenubarTests.swift` |
| Startup/shutdown orchestration | Unit/integration with fake services: each `start()` returns a `ServiceHandle`; a failing later start cancels retained stream tasks and stops registered handles in reverse order, including Space/Display observer-token removal; normal app termination does the same cleanup and unlinks the IPC socket | `Tests/WinMgrShellTests/StartupTests.swift` |
| Initial restore dispatch | Integration: restored `StoredWorld` at launch emits `.startupConverge`, first `DesiredLayout`, focus-border effect, and restore persistence decision before user input | `Tests/WinMgrShellTests/StartupTests.swift` |
| End-to-end (Sprint 1 gate) | Manual smoke + scripted: open Finder × 3, press hotkeys, eyeball window positions | Manual checklist in `docs/sprint-gates.md` |
| Full app | Manual nightly use by user | After Sprint 1 |

**No AX mocks for adapter integration tests**: AX shell tests use a real AX target (spawn a test app, drive it). This catches bugs that stubs miss.

**Property tests are mandatory for**: every pure function in the "Tree primitives" and "Layout" sections. Optional for everything else (covered by example tests).

**Coverage target**: 90%+ line coverage on `WinMgrCore`. Not a target for shell — coverage there is misleading because integration tests hit AX rather than line-counted Swift code.

---

## Anti-pattern checklist (refuse if any appear in stubs/impl)

- [ ] No class with mutable instance state + behavior methods anywhere in core.
- [ ] No function that "sometimes raises and sometimes returns Result."
- [ ] No `print()` outside of CLI output formatting.
- [ ] No string interpolation for shell commands or SQL (we have neither).
- [ ] No global mutable state without explicit reference type.
- [ ] No deep recursion (>200) without `@inlinable` tail-call or iterative form. (Tree recursion is depth-bounded by leaf count, ~50 max in practice.)
- [ ] No narrative comments (`// increment counter` over `counter += 1`).
- [ ] No defensive nil-checks for upstream-validated state.
- [ ] No `Any` / `cast` / type erasure as a workaround.
- [ ] No `for future extensibility` parameters.
- [ ] No docstring template padding — Swift has no NumPy-style docs; use `///` single-line where genuinely needed.

---

## Open issues & deferred decisions

| Item | Decision | Why deferred |
|---|---|---|
| License (MIT vs GPL) | TBD before first public push | Private repo for now. |
| Brew cask publishing | After local packaging and notarization | Need a stable feature set first. |
| Notarized installer package | After local install scripts and signing identity | Requires Apple Developer signing identity and notarization credentials. |
| App icon | After Phase 30 | Aesthetics, not architecture. |
| Notarization automation | After local `.app` bundle works | Need a signing identity and bundle structure finalized first. |
| Multi-display window movement hotkeys | Add later phase | Not in current 31-phase list; can extend `Direction` w/ `.display(.left/.right)` variants. |
| Workspace rename / labels | Later | Not in MVP scope. |
| Tabbed groups (i3-style) | Later | Adds a new Node variant. Reconsider after MVP. |
| Focus border latency during native Space switch animation | Later polish | Current shell hides stale border on `NSWorkspace.activeSpaceDidChangeNotification` and redraws after focused-window refresh. A noticeable delay can remain because macOS/AX focus state settles after the desktop animation. Future fix: measure `space notification -> focused snapshot -> overlay show`, then either subscribe to app/window AX focus notifications or draw from remembered per-Space focus state immediately and reconcile when AX confirms. |

---

## Sign-off

**Implementation may begin only after**:
1. This doc passes a Plan-agent review against the locked spec.
2. Critical/important findings are addressed.
3. User explicitly approves.

Each Phase PR refers back to this doc. Deviations require a doc amendment in the same PR.
