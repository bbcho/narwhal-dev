# Narwhal Research

These notes capture useful ideas from other macOS, Windows, and Linux window
managers that fit Narwhal's manual, per-Space tiling model.

## Positioning

Narwhal should stay focused on manual, persistent layouts:

- Windows float by default.
- A user explicitly pushes, drops, or commands a window into tile memory.
- Tile memory is visible and per Space.
- Normal macOS movement and resizing remain part of the workflow.

That positions Narwhal between snap tools such as Rectangle, Magnet, Moom, and
PowerToys FancyZones, and automatic or keyboard-owned tilers such as AeroSpace,
yabai, Amethyst, i3, Sway, bspwm, GlazeWM, and Hyprland.

## Ideas To Steal

### Visual Zone And Tree Editor

PowerToys FancyZones, Moom, and Rectangle Pro all make custom layouts visible.
Narwhal already has a BSP tree, so a visual editor could expose that tree as a
layout surface:

- Split and merge zones.
- Drag split dividers.
- Preview target zones before a push or drop.
- Save the active Space layout as a named template.
- Reapply a template to a display profile.

### First-Class Empty Tiles

bspwm's receptacle idea maps well to Narwhal's `.void` leaves. Empty zones
should become visible and addressable instead of hidden internal state:

- Show subtle outlines for remembered empty zones.
- Let users fill a selected empty zone from the current floating-window list.
- Allow named holes such as "terminal", "browser", "notes", or "scratch".
- Preserve holes across Space switches and display profile changes.

### Preselect Next Insertion

bspwm supports preselection before the next window insertion. Narwhal could add
an explicit "next tile goes here" mode:

- Preselect left, right, up, down, or center relative to the focused tile.
- Draw a temporary preview border for the insertion slot.
- Use the preselection for the next push, drag drop, or new-window rule.

This would reduce reliance on heuristics when the existing layout has ambiguous
split history.

### Stack Or Tab Groups Inside A Tile

i3, Pop Shell, GlazeWM, and FancyWM all have some version of stacked or tabbed
windows. Narwhal could let one tile contain a small window stack:

- One visible window owns the tile frame.
- Cycle within the tile separately from global non-tiled cycling.
- Use stacks for chat, notes, logs, terminals, or docs.
- Keep the tile tree stable while swapping the visible member.

### Snap Assist For Empty Zones

Windows Snap Assist suggests other windows after placing one window. Narwhal
could do the same without becoming automatic:

- After pushing a window into a zone, show candidate floating windows for the
  adjacent empty zone.
- Selecting one fills that remembered slot.
- Dismissing the assist leaves the layout unchanged.

### Display-Profile Layouts

Moom, Rectangle Pro, and FancyZones all benefit from display-specific layout
memory. Narwhal should treat display configuration as part of state:

- Laptop only.
- Desk monitor.
- Multiple external displays.
- Different visible frames caused by menu bar, Dock, or display scaling.

Layouts should restore against the matching display profile before falling back
to best-effort per-Space restore.

### Rules With An Inspector

yabai, i3, GlazeWM, Pop Shell, and Hyprland all lean on window rules. Narwhal
should make rules debuggable:

- Show bundle ID, process ID, title, role, subrole, resizable state, Space, and
  display in an inspector.
- Explain why a window is tiled, floating, ignored, stale, or unmapped.
- Add a CLI command such as `narwhalctl explain-window <id>`.
- Surface rule matches in the command overlay or a diagnostics overlay.

### Mode-Based Commands

i3's modes and Pop Shell's adjustment mode reduce modifier-chord overload.
Narwhal could add transient modes:

- Resize mode.
- Move or push mode.
- Layout edit mode.
- Rule inspection mode.

The command overlay should show the active mode, available keys, and exit keys.

### State Overview

niri and PaperWM make window/workspace state spatially understandable. Narwhal
needs a "show me the world" overlay:

- Active Space and display profile.
- Tiled windows.
- Floating windows.
- Empty remembered zones.
- Stale tile memory.
- Ignored Narwhal-owned overlay and border windows.
- Windows missing from Space mapping.

This would double as a user feature and a bug-report tool.

### Window Throw

Rectangle Pro-style throw commands are useful when a user wants speed without a
full tile edit:

- Throw focused window left, right, up, down, or center.
- In Narwhal, a throw should integrate the window into tile memory, not just
  write a one-off frame.
- Throw should be available by hotkey, overlay command, drag gesture, and IPC.

### Scratchpad Or Stash

i3, Hyprland, and several snap tools support hiding or recalling windows outside
the main layout. Narwhal could support a manual stash:

- Stash focused window.
- Recall last stashed window.
- Recall by app or title.
- Keep stashed windows outside tile memory until explicitly tiled again.

### Rich CLI Query And Subscribe

yabai and bspwm are useful because scripts can inspect and control state.
Narwhal should expose more than commands:

- `narwhalctl windows`
- `narwhalctl spaces`
- `narwhalctl layout`
- `narwhalctl explain-window <id>`
- `narwhalctl stale-memory`
- `narwhalctl events`

This would make support and automation much easier.

## Ideas To Avoid

- Do not replace native macOS Spaces with a separate virtual workspace model.
  AeroSpace does this well already, and Narwhal's identity is native Space
  integration.
- Do not make automatic tiling the default. That moves Narwhal into direct
  competition with yabai, Amethyst, AeroSpace, i3, Sway, and GlazeWM.
- Do not hide tile memory as internal state. The user should be able to see what
  Narwhal remembers.

## Strongest Next Product Idea

Visible editable empty zones are the most Narwhal-native feature:

- Green borders mark tiled windows.
- Subtle outlines mark empty remembered zones.
- A command fills an empty zone from the floating-window list.
- Named templates can build on top of the same model later.

This turns "tile memory" from a hidden implementation detail into the product.

## References

- AeroSpace: https://github.com/nikitabobko/AeroSpace
- Amethyst: https://ianyh.com/amethyst/
- bspwm: https://github.com/baskerville/bspwm
- FancyWM: https://fancywm.github.io/fancywm/
- GlazeWM: https://glazewm.com/
- Hyprland: https://wiki.hypr.land/
- i3: https://i3wm.org/docs/userguide.html
- Magnet: https://magnet.crowdcafe.com/
- Moom: https://manytricks.com/moom/
- niri: https://github.com/niri-wm/niri/wiki/Overview
- PaperWM: https://github.com/paperwm/PaperWM
- Pop Shell tiling: https://pop-os.github.io/docs/navigate-pop/tiling-stacking-windows.html
- PowerToys FancyZones: https://learn.microsoft.com/en-us/windows/powertoys/fancyzones
- Rectangle: https://rectangleapp.com/
- Sway: https://swaywm.org/
- Windows Snap: https://support.microsoft.com/windows/snap-your-windows-885a9b1e-a983-a3b1-16cd-c531795e6241
- yabai: https://github.com/asmvik/yabai
