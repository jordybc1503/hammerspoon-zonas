-- Names for the desktops (Spaces). macOS has no way to name them, so the current desktop's name
-- is shown in the menu bar; click it to rename. Names are kept per Space id in hs.settings, and
-- an empty name goes back to "Desktop N". ⌃⌥N and the ▦ menu rename too, for a screen where the
-- menu bar is too full and macOS hides the name behind the notch.
local zonas = require("zonas")

local M = {}
local KEY = "escritorios.names"
local SHOWN = "escritorios.shown" -- the ▦ menu hides or shows the name in the menu bar
local MAX = 12 -- characters shown in the menu bar; a longer name is cut there
local menu, watcher

local function current()
  local id = hs.spaces.focusedSpace()
  local list = hs.spaces.spacesForScreen(hs.spaces.spaceDisplay(id)) or {}
  local name = (hs.settings.get(KEY) or {})[tostring(id)]
  return id, name or zonas.t("deskDefault", hs.fnutils.indexOf(list, id) or 0)
end

local function refresh()
  local _, name = current()
  if utf8.len(name) > MAX then name = name:sub(1, utf8.offset(name, MAX + 1) - 1) .. "…" end
  menu:setTitle(name)
end

local function rename()
  local id, name = current()
  hs.focus()
  local button, text = hs.dialog.textPrompt(zonas.t("deskPrompt"), "", name, "OK", zonas.t("deskCancel"))
  if button ~= "OK" then return end
  local names = hs.settings.get(KEY) or {}
  text = text:match("^%s*(.-)%s*$")
  names[tostring(id)] = text ~= "" and text or nil
  hs.settings.set(KEY, names)
  refresh()
end

M.rename = rename
M.name = function() return select(2, current()) end
M.shown = function() return hs.settings.get(SHOWN) ~= false end
M.toggle = function()
  hs.settings.set(SHOWN, not M.shown())
  if M.shown() then menu:returnToMenuBar() else menu:removeFromMenuBar() end
end

function M.start()
  menu = hs.menubar.new(M.shown()):setTooltip(zonas.t("deskRename")):setClickCallback(rename)
  hs.hotkey.bind({ "ctrl", "alt" }, "n", rename)
  watcher = hs.spaces.watcher.new(refresh):start()
  refresh()
end

return M
