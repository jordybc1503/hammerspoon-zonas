-- Bubble translator: select a word in any app and press its shortcut (⌘⌥T by default; change it
-- in ▦ → Edit zones and shortcuts). It copies the selection, looks it up in the Oxford
-- Spanish-English dictionary that ships with macOS (bin/dict) and shows it in a bubble next to
-- the mouse. No network and no API key.
-- The window zones, the shortcuts and the ▦ menu live in zonas.lua.
require("hs.ipc")
local zonas = require("zonas")


local DICT      = os.getenv("HOME") .. "/.hammerspoon/bin/dict"
local WIDTH     = 520     -- bubble width in pixels
local COLS      = 62      -- characters per line before wrapping
local MAX_LINES = 22      -- a longer entry is cut
local TIMEOUT   = 15      -- seconds the bubble stays on screen

local canvas, timer, tap

local function hide()
  if timer then timer:stop(); timer = nil end
  if tap then tap:stop(); tap = nil end
  if canvas then canvas:delete(); canvas = nil end
end

-- Wraps the text at COLS characters without splitting words.
local function wrap(text)
  local out = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      local candidate = line == "" and word or line .. " " .. word
      if line ~= "" and (utf8.len(candidate) or #candidate) > COLS then
        out[#out + 1] = line
        line = word
      else
        line = candidate
      end
    end
    out[#out + 1] = line
  end
  return out
end

local function show(title, body)
  hide()
  local lines = wrap(body)
  local clipped = #lines > MAX_LINES
  if clipped then
    lines = table.move(lines, 1, MAX_LINES, 1, {})
    lines[MAX_LINES] = lines[MAX_LINES] .. " …"
  end

  local height = 22 + 17 * #lines + 18
  local styled = hs.styledtext.new(title .. "\n", {
      font = { name = "Menlo-Bold", size = 15 }, color = { hex = "#ffffff" },
    }) .. hs.styledtext.new(table.concat(lines, "\n"), {
      font = { name = "Menlo", size = 13 }, color = { hex = "#dcdcdc" },
      paragraphStyle = { lineSpacing = 2 },
    })

  -- Puts the bubble next to the mouse, inside the screen.
  local mouse  = hs.mouse.absolutePosition()
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local x = math.max(screen.x + 8, math.min(mouse.x + 14, screen.x + screen.w - WIDTH - 8))
  local y = math.max(screen.y + 8, math.min(mouse.y + 18, screen.y + screen.h - height - 8))

  canvas = hs.canvas.new({ x = x, y = y, w = WIDTH, h = height })
  canvas:appendElements(
    { type = "rectangle", action = "fill",
      roundedRectRadii = { xRadius = 10, yRadius = 10 },
      fillColor = { hex = "#1c1c1e", alpha = 0.97 },
      withShadow = true },
    { type = "rectangle", action = "stroke",
      roundedRectRadii = { xRadius = 10, yRadius = 10 },
      strokeColor = { hex = "#5a5a5e" }, strokeWidth = 1 },
    { type = "text", text = styled,
      frame = { x = 14, y = 10, w = WIDTH - 28, h = height - 16 } }
  )
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:show()

  -- It closes on its own, or as soon as you type or click.
  timer = hs.timer.doAfter(TIMEOUT, hide)
  tap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.leftMouseDown,
  }, function() hide(); return false end):start()
end

-- Global on purpose, so you can test it from a terminal without the mouse:
-- hs -c 'traducir("scope")'
function traducir(word)
  local output = hs.execute(string.format("%q %q", DICT, word))
  output = (output or ""):match("^%s*(.-)%s*$")
  if output == "" then
    return show(word, zonas.t("notInDict"))
  end
  -- The first token is the word itself: it goes in the title, not the body.
  local body = output:gsub("^" .. word:gsub("%W", "%%%0") .. "%s*", "")
  show(word, (body:gsub("▸", "\n  · ")))
end

local function translateSelection()
  hide()
  -- Copy the selection with ⌘C, then put the clipboard back, so what the user had
  -- copied is not lost.
  local previous = hs.pasteboard.getContents()
  hs.pasteboard.clearContents()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)

  hs.timer.doAfter(0.18, function()
    local selection = hs.pasteboard.getContents()
    if previous then hs.pasteboard.setContents(previous) end
    if not selection or selection:match("^%s*$") then
      return show(zonas.t("noSel"), zonas.t("noSelBody", zonas.translateCombo()))
    end
    traducir(selection:gsub("%s+", " "):match("^%s*(.-)%s*$"))
  end)
end

zonas.start({ translate = translateSelection })
require("mascota").start()

hs.autoLaunch(true)
hs.alert.show(zonas.t("ready"), 2)
