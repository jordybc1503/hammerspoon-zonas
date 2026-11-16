-- A language for each keyboard: type on the laptop's keyboard and the Mac writes in its language,
-- type on the external one and it writes in that one's. macOS has a single input source for the
-- whole Mac, so this switches it when a key comes from a keyboard whose language is not the active
-- one: the key is held back, the source switched, and the key sent again so it comes out right.
--
-- A keystroke does not say which device sent it, only its keyboard type (ANSI, ISO, JIS and a
-- number per model). A MacBook's keyboard and an external one report different types, so that is
-- what each keyboard is recognised by. Two keyboards of the same type cannot be told apart.
-- The keyboards and their languages are set in the ▦ editor's Keyboards tab (zonas.json).
local M = {}

local P = hs.eventtap.event.properties
local MARK = 0x7465636c -- "tecl": the keys this sends again carry it, so they are let through
-- Time for apps to take the new input source before the held key is sent again. Raise it if the
-- first letter after changing keyboard still comes out in the other language.
local DELAY = 0.04

local tap, guard, held
local last -- keyboard type of the last key pressed, for the editor's "Add a keyboard"
local detecting = false

local function settings() return require("zonas").keyboards() end

local function sourceFor(kind)
  for _, k in ipairs(settings().list) do
    if k.type == kind then return k.source end
  end
end

-- Sent with the same key and modifiers as new events, made after the switch, so their characters
-- come from the new language.
local function flush()
  local keys = held
  held = nil
  for _, e in ipairs(keys) do
    hs.eventtap.event.newKeyEvent(e:getKeyCode(), true):setFlags(e:getFlags())
      :setProperty(P.eventSourceUserData, MARK):post()
  end
end

local function onKey(e)
  if e:getProperty(P.eventSourceUserData) == MARK then return false end
  last = e:getProperty(P.keyboardEventKeyboardType)
  -- Keys typed while a switch is on its way wait behind it, to keep their order.
  -- ponytail: they come out in the language of that switch even from the other keyboard; only a
  -- key pressed within DELAY of changing keyboard could hit that.
  if held then held[#held + 1] = e:copy(); return true end
  local want = settings().enabled and sourceFor(last)
  if not want or want == hs.keycodes.currentSourceID() then return false end
  if not hs.keycodes.currentSourceID(want) then return false end -- a language since removed
  held = { e:copy() }
  hs.timer.doAfter(DELAY, flush)
  return true
end

-- Listens only when there is something to do: every key on the Mac passes through the listener.
-- macOS also turns off a listener that answered too slowly once; this turns it back on.
local function check()
  if not tap then return end -- zonas saved before start
  local s = settings()
  local want = detecting or (s.enabled and #s.list > 0)
  if want and not tap:isEnabled() then tap:start()
  elseif not want and tap:isEnabled() then tap:stop() end
end

-- The editor's "Add a keyboard": it listens while the editor waits for a key, then asks which
-- keyboard that key came from. The listener sees the key before the editor does.
function M.detect(on)
  detecting = on
  if on then last = nil end
  check()
  return last
end

M.refresh = check

function M.start()
  tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKey)
  guard = hs.timer.doEvery(3, check)
  check()
end

-- The languages a keyboard can have: the input sources added in System Settings › Keyboard.
function M.sources()
  local out = {}
  for _, kind in ipairs({ hs.keycodes.layouts, hs.keycodes.methods }) do
    local ids, names = kind(true), kind()
    for i, id in ipairs(ids) do out[#out + 1] = { id = id, name = names[i] or id } end
  end
  return out
end

return M
