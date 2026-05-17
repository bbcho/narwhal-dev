-- Bundled default configuration.
-- Copy this file to ~/.config/winmgr/init.lua to customize startup config.
return {
  keymap = {
    { key = "h", modifiers = { "control", "option" }, action = { type = "push", direction = "left" } },
    { key = "l", modifiers = { "control", "option" }, action = { type = "push", direction = "right" } },
    { key = "k", modifiers = { "control", "option" }, action = { type = "push", direction = "up" } },
    { key = "j", modifiers = { "control", "option" }, action = { type = "push", direction = "down" } },
    { key = "delete", modifiers = { "control", "option" }, action = { type = "reset_layout" } },
  },
  gaps = {
    inner = 0,
    outer = { top = 0, left = 0, bottom = 0, right = 0 },
  },
  drag_modifier = { "shift" },
  zones = {
    { id = "left-half", bounds = { x = 0, y = 0.3, w = 0.2, h = 0.4 }, action = { type = "insert_as_half", direction = "left" } },
    { id = "right-half", bounds = { x = 0.8, y = 0.3, w = 0.2, h = 0.4 }, action = { type = "insert_as_half", direction = "right" } },
    { id = "top-half", bounds = { x = 0.3, y = 0, w = 0.4, h = 0.2 }, action = { type = "insert_as_half", direction = "up" } },
    { id = "bottom-half", bounds = { x = 0.3, y = 0.8, w = 0.4, h = 0.2 }, action = { type = "insert_as_half", direction = "down" } },
    { id = "center", bounds = { x = 0.4, y = 0.4, w = 0.2, h = 0.2 }, action = { type = "insert_as_center" } },
  },
  border = { width = 2, color = "#4DA3FF" },
  hud = { enabled = true, duration_millis = 700 },
  rules = {},
}
