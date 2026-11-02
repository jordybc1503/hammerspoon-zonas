-- One input language per keyboard: the Mac's own in Spanish, an external one in English. Each key
-- press says what kind of keyboard sent it (its keyboard type); the keyboards are saved in
-- zonas.json (set in ▦ → Edit zones and shortcuts → Keyboards) with that type and their layout.
-- ponytail: macOS does not say which device sent a key, only its type, so two keyboards of the same
-- type look the same. Changing one's type (System Settings → Keyboard → Change Keyboard Type…) splits them.
local M = {}

local TYPE = hs.eventtap.event.properties.keyboardEventKeyboardType
local tap, guard, onDetect

local function keyboards() return require("zonas").keyboards() end

local function onKey(e)
  local kind = e:getProperty(TYPE)
  if onDetect then
    local cb = onDetect
    onDetect = nil
    M.apply()
    cb(kind)
    return false
  end
  for _, k in ipairs(keyboards()) do
    if k.type == kind then
      if k.layout == hs.keycodes.currentSourceID() or not hs.keycodes.currentSourceID(k.layout) then return false end
      -- The app may still read this key with the old layout: send it again once the switch has landed.
      local again = e:copy()
      hs.timer.doAfter(0.03, function() again:post() end)
      return true
    end
  end
  return false
end

-- The listener runs only while there is a keyboard to watch, or one to detect.
function M.apply()
  local on = onDetect ~= nil or #keyboards() > 0
  if on and not tap:isEnabled() then tap:start() elseif not on and tap:isEnabled() then tap:stop() end
end

-- The next key pressed, on any keyboard, calls back with that keyboard's type.
function M.detect(cb)
  onDetect = cb
  M.apply()
end

-- The layouts and input methods turned on in the Mac, for the editor's lists.
function M.sources()
  local out = {}
  for _, get in ipairs({ hs.keycodes.layouts, hs.keycodes.methods }) do
    local ids, names = get(true), get()
    for i, id in ipairs(ids) do out[#out + 1] = { id = id, name = names[i] or id } end
  end
  return out
end

function M.start()
  tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKey)
  M.apply()
  -- macOS turns off a listener that answered too slowly once; turn it back on.
  guard = hs.timer.doEvery(3, function() if not tap:isEnabled() then M.apply() end end)
end

return M
