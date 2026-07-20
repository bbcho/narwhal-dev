# Layout Workbench design and implementation gate

Status: approved for implementation on `codex/layout-workbench`.

## Operator job and context

A person arranging their own macOS workspace uses the Layout Workbench to understand, preview, and change Narwhal's layout for a specific Space; if the scope or effect is misunderstood, several real application windows can move, resize, disappear behind one another, or become difficult to recover.

- Frequency: brief daily adjustments, occasional rule/template maintenance, and incident recovery.
- Time pressure: usually low, but high when a command has disrupted an active workspace.
- Environment: a single-user macOS desktop, often with several displays and Spaces.
- Collaboration: none. The evidence trail is for the same operator returning after an interruption.
- Degraded modes: Accessibility unavailable, partial AX inventory, stale Space topology, unsatisfiable minimum sizes, missing template matches, and an application refusing a requested frame.

## Objects and authority

| Object | Authoritative? | Source | Mutated by |
|---|---:|---|---|
| `World` / Space tree | yes | `WorldActor` | committed commands and environment reconciliation |
| live AX and WindowServer frames | yes for visible reality | macOS | applications, the user, and committed frame writes |
| workbench selection | no | workbench controller | row/canvas selection only |
| command preview | no | pure planner | selecting an operation or dragging a split |
| per-Space history | runtime authority | `WorldActor` | successful committed layout transitions |
| named layout | user-owned persisted artifact | `layouts.json` | explicit save/rename/delete |
| managed app rule | user-owned persisted artifact | `rules.json` | explicit save/delete/reorder |
| Lua configuration | user-owned expert artifact | `init.lua` | external editor and Reload Config |

Preview state never writes AX frames, the `World`, restore state, rules, or layouts. A preview becomes authoritative only after an explicit Apply or a completed split/window drag.

## Workflow and state model

The first screen answers one question: "What is Narwhal managing in this Space, and what will this change do?"

1. Choose a display/Space in the workspace rail.
2. Inspect the BSP tree in the canvas. The actual focused window has a focus glyph; the selected window has a separate selection outline.
3. Choose a concrete action or drag a split/window. The canvas shows baseline and proposed frames and the inspector lists every affected window.
4. Resolve a blocking explanation, or Apply the preview.
5. Verify the resulting history entry and visible frame state. Undo/redo remain scoped to the selected Space.

| State | Meaning | Control | Visible location | Must not affect |
|---|---|---|---|---|
| workspace selection | Space/display being inspected | workspace row | rail and canvas title | macOS focus |
| window selection | window whose details/actions are shown | canvas click | white selection outline and inspector | actual focus |
| actual focus | macOS focused window | external state | `FOCUS` glyph | selection/execution |
| comparison | baseline versus proposed layout | action or drag preview | solid baseline, dashed proposal, change list | authoritative layout |
| execution scope | exact Space and affected windows | Apply row | scope text plus affected count | hidden/filtered objects |
| window management state | tiled, floating, manual adjustment, or temporarily detached | runtime/core | labeled tile and inspector | selection |

Hotkeys remain immediate expert commands. They still plan before applying and show a concrete rejection/recovery message on failure. The workbench is the deliberate preview/apply interface for push, resize, eject, balance, shuffle, cascade, reset, template application, and direct manipulation.

## Critical decisions and friction

| Decision | Consequence if wrong | Information required before action | Friction |
|---|---|---|---|
| Apply a multi-window command | active windows move unexpectedly | Space, affected windows, before/after frames, constraint warnings | explicit Apply in workbench |
| Reset a Space | the complete tree is discarded | Space and affected count | confirmation plus undo entry |
| Apply a named layout | unmatched windows may remain floating | match/unmatched list and target displays | preview plus Apply |
| Save an app rule | future windows change behavior | matcher, policy, precedence, current match count | validation plus explicit Save |
| Delete a rule/layout | user artifact is lost | artifact name and effect | confirmation; no silent deletion |

Undo and redo are bounded to 32 successful layout transitions per Space. A failed or partially applied frame write creates no history transition. New commits after undo clear that Space's redo branch. Manual-resize reconciliation records one coalesced transition, not every AX notification.

## Failure and explanation model

| Class | Treatment | Recovery | Blocks Apply? |
|---|---|---|---:|
| Accessibility permission | lock icon and permission text | Open Accessibility Settings | yes |
| incomplete inventory/topology | warning label with observed coverage | Refresh or switch to active Space | yes for destructive/multi-window commands |
| command rejection | reason plus command-specific next action | e.g. Tile Window, Float Window, reduce minimum size | yes |
| unsatisfiable constraints | required/available dimensions and implicated windows | float a window, relax managed minimum, or change split | yes |
| template mismatch | matched and unmatched slots/windows | edit match or apply partial layout | partial apply requires explicit acknowledgement |
| AX write failure/clamp | applied versus requested frame evidence | Retry after application constraint is learned | yes until replanned |
| empty Space | plain empty state | drag/open a window or apply a matching layout | no |

Errors are typed in the core/presentation model. UI text maps codes to a short reason, evidence, and one recovery action; raw enum dumps are not operator copy.

## Layout and visual contract

The workbench is a dense, native macOS layout instrument. Its adjacent-domain reference is a CAD layer/geometry inspector combined with a debugger's variable pane: spatial truth dominates, state is compact, and edits are reversible. It must not resemble a generic analytics dashboard, preference-card grid, or AI assistant.

| Zone | Content |
|---|---|
| workspace rail (172 pt) | displays/Spaces, health label, window count, focus marker |
| geometry canvas (flexible) | display bounds, BSP cells, empty slots, split weights/handles, baseline/proposal |
| inspector (264 pt) | selected-window state, constraints, exact proposed changes, rules/layout actions |
| action row (canvas bottom) | execution scope, Cancel Preview, Apply Change, Undo, Redo |

Chrome budget:

| Element | Operator job | Why unique |
|---|---|---|
| workspace rail | changes inspected Space/display | the canvas never changes scope implicitly |
| canvas action row | controls the current proposed transition | no duplicate top toolbar or action log |
| inspector | evidence for the selected object/preview | row-specific state does not repeat global scope |

There is no KPI band, card grid, tab strip, decorative gradient, glass, shadow stack, or activity feed. Native AppKit controls and the macOS system typeface are intentional because this is window chrome adjacent to the operating system; monospaced digits are used for frame dimensions and split weights. Corners use 4 pt only where they distinguish a window tile. Motion is limited to native focus/selection transitions; resize previews track the pointer with no interpolation.

Semantic visual tokens:

- surfaces: window background, control background, selected-content background, separator;
- text: label, secondary label, disabled, warning, error;
- tiled: solid border plus `TILED` text;
- floating: dotted border plus `FLOATING` text;
- manual adjustment: double border plus `ADJUSTING` text;
- temporarily detached: broken/dashed border plus `DETACHED` text and reason;
- focus: key-window accent plus `FOCUS` glyph;
- preview: dashed accent outline and directional arrow;
- warning/error: SF Symbol plus label, never color alone.

All controls have keyboard focus rings and tooltips/accessibility labels. The minimum supported workbench size is 860 x 520; below that, the inspector narrows before identifiers truncate, and full identifiers remain available through accessibility help/tooltips. Dark mode uses semantic system colors rather than inversion.

## Workspace overview popover

Clicking the status item opens a compact popover, not the full editor. It lists displays and active Spaces with named health (`Ready`, `Partial inventory`, `Permission required`, `Constraint conflict`), tiled/floating counts, and focused application. The only primary action is `Open Layout Workbench…`; existing maintenance actions remain in a secondary gear menu. The popover and workbench consume the same immutable presentation snapshot so their counts cannot diverge.

## Managed rules and named layouts

Managed rules are a first-match, ordered layer evaluated before Lua rules. Each rule has a stable ID, enabled flag, name, bundle/title/role matcher, placement (`default`, float, ignore, display slot, or configured zone), focus-cycle inclusion, and optional minimum width/height. The editor displays `Managed rule` or `Lua rule` as the source. Lua remains the only interface for compound predicates and custom zone definitions.

Named layouts are separate from crash restoration. A layout stores display slots, a template split tree, split weights, empty cells, and window-slot matchers (bundle ID, AX role, and optional exact/title-regex hint). Application uses deterministic one-window-per-slot matching and reports every unmatched slot/window before Apply. It never stores PIDs, WindowIDs, or document contents beyond an explicitly saved title hint.

Both JSON stores use a versioned envelope, atomic replacement, owner-only permissions, strict decoding, quarantine on malformed content, and a hard entry/count/string-size limit. Store errors leave the last valid in-memory value active and visible as a workbench warning.

## Functional architecture gate

Domain data/ADTs:

- `[CORE]` `WindowManagementState`, `WorkspacePresentation`, `CommandPreview`, `CommandExplanation`;
- `[CORE]` `LayoutHistoryState/Entry/Transition` with per-Space undo and redo;
- `[CORE]` `ManagedWindowRule/Policy` and deterministic precedence/matching;
- `[CORE]` `NamedLayout/TemplateNode/TemplateMatchResult`;
- `[SHELL]` JSON repositories, AppKit controllers/views, and AX/frame application.

Boundary flow:

`AX + displays + WorldActor runtime -> pure presentation snapshot -> AppKit views`

`AppKit intent -> pure plan/preview or typed rejection -> explicit Apply -> existing coordinated LayoutApplier -> successful WorldActor commit/history -> atomic persistence`

Expected domain failures use `Result`/typed enums. Decoder, filesystem, AX, and AppKit failures throw only at the shell and are immediately translated into typed presentation/store failures. Runtime mutation stays inside `WorldActor` and main-actor AppKit controllers; core values remain immutable and `Sendable`. No extra lock or event bus is introduced. Dependencies are initializer-injected closures/repositories rather than global state.

Property/example tests will cover history bounds and branch clearing, undo/redo round trips, deterministic template matching, rule precedence and validation, state classification, command explanation coverage, preview affected-window sets, JSON round trips, malformed/quarantined stores, and no preview mutation. Event sourcing is intentionally rejected: bounded runtime history and two small user stores do not justify a permanent event log.

## Pre-implementation review

Review result: **PASS, no P0/P1 findings**.

Resolved during design:

- P1 risk, invisible execution scope: Apply always names the Space and affected count; proposal frames are visible.
- P1 risk, preview mutating live windows: the workbench uses planner values only until Apply.
- P1 risk, mouse-only split editing: selected splits expose keyboard step controls and Undo/Redo have menu shortcuts.
- P1 risk, permission/no-data conflation: each has a separate typed state and recovery.
- P2 risk, focus versus selection confusion: separate outline/glyph semantics and no click-to-focus side effect.
- P2 risk, stacked dashboard chrome: one rail, one geometry surface, one inspector, one action row.
- P2 risk, rules silently overriding Lua: managed precedence and source are visible.
- P2 risk, template partial matches: unmatched evidence appears before Apply and requires acknowledgement.

## Verification gate

Fast verification:

- unit/property-style tests for every pure model and persistence boundary;
- AppKit geometry tests at minimum and constrained window sizes;
- keyboard focus/action tests and accessibility labels;
- pixel/screenshot verification for tiled/floating/adjusting/detached, focus versus selection, proposal frames, dark mode, permission, partial inventory, empty Space, constraint failure, and template mismatch;
- screenshot review for chrome count, truncation, semantic status without color, and CVD simulations.

Live verification is mandatory after the feature is assembled. `scripts/live_verify_all.sh` must pass from an Accessibility-trusted Terminal runner and must actually open Chrome, Firefox, System Settings, and Terminal; verify AX-applied and WindowServer frames; run mixed Chrome/Firefox manual tile-resize; and run the Chrome and Firefox three-window vertical stacks. A skip, locked-session failure, missing real app, or `No matching test cases were run` is a failure.

## Commit slices

1. design and architecture gate;
2. presentation state, previews, explanations;
3. bounded per-Space history and redo;
4. managed-rule model/store/integration;
5. named-layout model/store/matching;
6. workspace overview and workbench shell;
7. canvas editing, rule/layout sheets, and command wiring;
8. AppDelegate responsibility extraction;
9. visual/live verifier coverage and final de-slop review.
