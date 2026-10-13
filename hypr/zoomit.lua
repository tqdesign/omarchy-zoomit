-- ZoomIt hotkeys, matching the Windows defaults. dofile() this from
-- ~/.config/hypr/hyprland.lua or ~/.config/hypr/bindings.lua.
--
-- Digits are bound by keycode (code:10 is 1) so they work on any layout.
-- Ctrl+1..7 are taken from every app while this is loaded, as on Windows;
-- edit the table to move them.

local keys = {
  zoom = "CTRL + code:10",
  draw = "CTRL + code:11",
  break_timer = "CTRL + code:12",
  live_zoom = "CTRL + code:13",
  record = "CTRL + code:14",
  record_region = "CTRL + SHIFT + code:14",
  snip = "CTRL + code:15",
  snip_save = "CTRL + SHIFT + code:15",
  demotype = "CTRL + code:16",
  demotype_back = "CTRL + SHIFT + code:16",
}

local LIVE_DEFAULT = 2
local LIVE_STEP = 1.25
local LIVE_MAX = 16

local zoomit = (os.getenv("HOME") or "") .. "/.config/omarchy/plugins/tqdesign.zoomit/bin/zoomit"

local bind = (o and o.bind) or function(key, description, action, opts)
  opts = opts or {}
  opts.description = description
  if type(action) == "string" then
    action = hl.dsp.exec_cmd(action)
  end
  hl.bind(key, action, opts)
end

-- The overlay shows a still of the screen; a compositor fade would flicker.
hl.layer_rule({ match = { namespace = "tqdesign-zoomit" }, no_anim = true, animation = "none" })

bind(keys.zoom, "ZoomIt: zoom", zoomit .. " zoom")
bind(keys.draw, "ZoomIt: draw", zoomit .. " draw")
bind(keys.break_timer, "ZoomIt: break timer", zoomit .. " break")
bind(keys.record, "ZoomIt: record screen", zoomit .. " record")
bind(keys.record_region, "ZoomIt: record region", zoomit .. " record region")
bind(keys.snip, "ZoomIt: snip to clipboard", zoomit .. " snip")
bind(keys.snip_save, "ZoomIt: snip to file", zoomit .. " snip save")
-- On release, so the typed text isn't sent with Ctrl still held.
bind(keys.demotype, "ZoomIt: DemoType next", zoomit .. " demotype", { release = true })
bind(keys.demotype_back, "ZoomIt: DemoType back", zoomit .. " demotype back", { release = true })

-- Live zoom is the compositor's own magnifier, so the desktop stays usable.
-- Ctrl+Up/Down change the level and are bound only while it is on.
local live_level = LIVE_DEFAULT
local live_binds = {}

local function set_zoom(factor)
  hl.config({ cursor = { zoom_factor = factor } })
end

local function live_step(factor)
  return function()
    live_level = math.max(1.25, math.min(LIVE_MAX, live_level * factor))
    set_zoom(live_level)
  end
end

bind(keys.live_zoom, "ZoomIt: live zoom", function()
  if #live_binds > 0 then
    for _, keybind in ipairs(live_binds) do
      keybind:unbind()
    end
    live_binds = {}
    set_zoom(1)
    return
  end

  set_zoom(live_level)
  live_binds = {
    hl.bind("CTRL + UP", live_step(LIVE_STEP), { description = "ZoomIt: live zoom in", repeating = true }),
    hl.bind("CTRL + DOWN", live_step(1 / LIVE_STEP), { description = "ZoomIt: live zoom out", repeating = true }),
  }
end)
