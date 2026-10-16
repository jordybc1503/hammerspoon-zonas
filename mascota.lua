-- Claude Code mascot: a pet that runs to the terminal window whose Claude session finished, has a
-- question or needs an approval. The "mascota" Claude Code mod drops one JSON request per event in
-- INBOX; taking the file (deleting it) tells the mod we are here, and an approval is answered by
-- writing <id>.answer next to it.
local M = {}

local INBOX = os.getenv("HOME") .. "/Library/Caches/mascota"
local TERMINALS = { ["com.mitchellh.ghostty"] = true, ["com.googlecode.iterm2"] = true, ["com.apple.Terminal"] = true }
local BW = 308 -- bubble width; the pet takes the right side
local W, H, PET -- canvas size and where the pet sits in it: layout() sets them for the pet's size

-- The pet is the first Codex pet found (~/.codex/pets/<id>): an 8 × 11 sheet of 192 × 208 frames,
-- one animation per row. Without one, a small drawn creature stands in.
local PETS = os.getenv("HOME") .. "/.codex/pets"
local FW, FH = 192, 208
local ROWS = { idle = { 0, 6 }, right = { 1, 8 }, left = { 2, 8 }, wave = { 3, 4 }, jump = { 4, 5 },
  fail = { 5, 8 }, wait = { 6, 6 }, review = { 8, 6 } }
local MOOD = { done = "wave", question = "wait", ask = "review", needs = "review" }
local EVENT = { done = "done", question = "question", ask = "needs", needs = "needs" } -- kind → setting
local SIZES = { s = 0.4, m = 0.5, l = 0.62 }
-- Seconds per frame: calm loops, quicker reactions, like the pets in Codex.
local SPEED = { idle = 0.24, wave = 0.17, wait = 0.22, review = 0.22, jump = 0.11, fail = 0.14, right = 0.1, left = 0.1 }

local STR = {
  es = { done = "¡Listo!", question = "Tengo una pregunta", needs = "Te necesito en la terminal", ask = "¿Puedo usar %s?", allow = "Aprobar",
    deny = "Rechazar", go = "Ir a la terminal →", click = "Clic para ir a la terminal" },
  en = { done = "Done!", question = "I have a question", needs = "I need you in the terminal", ask = "May I use %s?", allow = "Approve",
    deny = "Deny", go = "Go to terminal →", click = "Click to go to the terminal" },
}
local function t(k) return (STR[require("zonas").lang()] or STR.en)[k] end
-- The pet's settings live with the zones (zonas.json), edited in the ▦ editor's Pet tab.
local function settings() return require("zonas").pet() end

local function layout(size)
  local k = SIZES[size] or SIZES.m
  PET = { w = math.floor(192 * k), h = math.floor(208 * k) }
  W, H = BW + PET.w + 24, math.max(136, PET.h + 32)
  PET.x, PET.y = W - PET.w - 8, H - PET.h - 8
end

local windows = {} -- session → id of the window you last typed into
local bubbles = {} -- session → { canvas, timer, runner, runTimer, req, window, mood, tick }
local leaving = {} -- bubble → timer of its goodbye animation (kept so it is not collected)
local sheet, frames, petName, loadedId = nil, {}, nil, nil
local watcher, focusFilter

-- One Codex pet folder: its pet.json and its sprite sheet, or nil.
local function readPet(dir)
  local file = PETS .. "/" .. dir .. "/pet.json"
  local info = dir:sub(1, 1) ~= "." and hs.fs.attributes(file) and hs.json.read(file)
  local img = type(info) == "table" and type(info.spritesheetPath) == "string"
    and hs.image.imageFromPath(PETS .. "/" .. dir .. "/" .. info.spritesheetPath)
  if img then return info, img end
end

-- id "" takes the first pet found; "drawn" (or no pet) leaves the drawn stand-in.
local function loadPet(id)
  if id == loadedId then return end
  loadedId, sheet, frames, petName = id, nil, {}, nil
  if id == "drawn" or not hs.fs.attributes(PETS) then return end
  for dir in hs.fs.dir(PETS) do
    if id == "" or dir == id then
      local info, img = readPet(dir)
      if img then sheet, petName = img, info.displayName or dir; return end
    end
  end
end

-- The pets the editor offers: id, name and a small picture of each.
function M.pets()
  local list = {}
  if not hs.fs.attributes(PETS) then return list end
  for dir in hs.fs.dir(PETS) do
    local info, img = readPet(dir)
    if img then
      local thumb = img:croppedCopy({ x = 0, y = 0, w = FW, h = FH }):setSize({ w = 96, h = 104 }, false)
      list[#list + 1] = { id = dir, name = info.displayName or dir, description = info.description or "",
        thumb = thumb:encodeAsURLString() }
    end
  end
  return list
end

local function cell(row, col)
  local key = row * 8 + col
  frames[key] = frames[key] or sheet:croppedCopy({ x = col * FW, y = row * FH, w = FW, h = FH })
  return frames[key]
end

local function frame(mood, n) return cell(ROWS[mood][1], n % ROWS[mood][2]) end

-- Rows 9 and 10 hold 16 look directions, clockwise from straight up.
local function look(angle)
  local dir = math.floor(angle / (2 * math.pi) * 16 + 0.5) % 16
  return cell(9 + dir // 8, dir % 8)
end

local function play(b, mood, once)
  b.mood, b.n, b.at, b.once = mood, 0, hs.timer.secondsSinceEpoch(), once
end

-- One step of the pet's life: it plays its mood once, then breathes (idle) and plays it again now
-- and then; while you move the mouse it turns to look at it.
local function animate(b, image)
  local now = hs.timer.secondsSinceEpoch()
  local mouse = hs.mouse.absolutePosition()
  if b.mouse and math.abs(mouse.x - b.mouse.x) + math.abs(mouse.y - b.mouse.y) > 2 then b.movedAt = now end
  b.mouse = mouse
  if b.look and not b.once and b.movedAt and now - b.movedAt < 1.2 then
    local f = b.canvas:frame()
    return image(look(math.atan(mouse.x - (f.x + PET.x + PET.w / 2), (f.y + PET.y + PET.h / 3) - mouse.y)))
  end
  if now - b.at < SPEED[b.mood] then return end
  b.at, b.n = now, b.n + 1
  if b.n >= ROWS[b.mood][2] then
    if b.leaving then b.n = ROWS[b.mood][2] - 1 -- a goodbye holds its last pose
    elseif b.once then play(b, "idle", false); b.again = now + 6 + math.random() * 4
    else b.n = 0 end
  end
  if b.mood == "idle" and b.again and now >= b.again then play(b, b.home, true) end
  image(frame(b.mood, b.n))
end

local function answer(req, value)
  local path = INBOX .. "/" .. req.id .. ".answer"
  local f = io.open(path .. ".tmp", "w")
  if not f then return end
  f:write(value)
  f:close()
  os.rename(path .. ".tmp", path)
end

local function remove(b)
  for _, timer in pairs({ b.timer, b.runTimer, leaving[b] }) do timer:stop() end
  leaving[b] = nil
  if b.runner then b.runner:delete() end
  b.canvas:delete()
end

-- A pending approval always gets an answer: "terminal" hands it back to the normal prompt.
-- After Approve or Deny the pet jumps or droops for a moment before it leaves.
local function hide(session, reply)
  local b = bubbles[session]
  if not b then return end
  bubbles[session] = nil
  if b.req.kind == "ask" then answer(b.req, reply or "terminal") end
  if sheet and (reply == "allow" or reply == "deny") and b.canvas:isShowing() then
    local mood = reply == "allow" and "jump" or "fail"
    play(b, mood, true)
    b.leaving = true
    leaving[b] = hs.timer.doAfter(ROWS[mood][2] * SPEED[mood] + 0.3, function() remove(b) end)
  else
    remove(b)
  end
end

local function windowOf(session)
  local id = windows[session]
  return id and hs.window.get(id)
end

local function goTo(session)
  local w = windowOf(session)
  if w then w:focus() else hs.application.launchOrFocusByBundleID("com.mitchellh.ghostty") end
end

-- Bottom-right corner inside the window, stacked above other bubbles on the same window.
local function frameFor(session, w)
  local area = w and w:frame() or hs.screen.mainScreen():frame()
  local below = 0
  for s, b in pairs(bubbles) do
    if s ~= session and b.window == (w and w:id()) then below = below + 1 end
  end
  local s = (w and w:screen() or hs.screen.mainScreen()):frame()
  local x = math.max(s.x, math.min(area.x + area.w - W - 16, s.x + s.w - W))
  local y = math.max(s.y, math.min(area.y + area.h - H - 16 - below * (H + 8), s.y + s.h - H))
  return { x = x, y = y, w = W, h = H }, s
end

-- The stand-in when there is no Codex pet: a round orange creature with a badge for the kind.
local function drawnPet(kind)
  local mx, my = W - 104, H - 100
  local dark, orange = { hex = "#1c1c1e" }, { hex = "#D97757" }
  local badge = ({ done = { "✓", "#2e9d5b" }, question = { "?", "#3b6fd6" }, ask = { "!", "#e0a01e" }, needs = { "!", "#e0a01e" } })[kind]
  return {
    { type = "oval", action = "fill", fillColor = orange, frame = { x = mx + 14, y = my + 10, w = 24, h = 24 } },
    { type = "oval", action = "fill", fillColor = orange, frame = { x = mx + 58, y = my + 10, w = 24, h = 24 } },
    { type = "oval", action = "fill", fillColor = { hex = "#b85c3e" }, frame = { x = mx + 22, y = my + 82, w = 18, h = 9 } },
    { type = "oval", action = "fill", fillColor = { hex = "#b85c3e" }, frame = { x = mx + 56, y = my + 82, w = 18, h = 9 } },
    { type = "oval", action = "fill", fillColor = orange, frame = { x = mx + 8, y = my + 20, w = 80, h = 66 } },
    { type = "oval", action = "fill", fillColor = { white = 1 }, frame = { x = mx + 24, y = my + 38, w = 18, h = 20 } },
    { type = "oval", action = "fill", fillColor = { white = 1 }, frame = { x = mx + 54, y = my + 38, w = 18, h = 20 } },
    { type = "oval", action = "fill", fillColor = dark, frame = { x = mx + 26, y = my + 45, w = 10, h = 11 } },
    { type = "oval", action = "fill", fillColor = dark, frame = { x = mx + 56, y = my + 45, w = 10, h = 11 } },
    { type = "oval", action = "fill", fillColor = { hex = "#ff9aa2", alpha = 0.6 }, frame = { x = mx + 14, y = my + 60, w = 12, h = 7 } },
    { type = "oval", action = "fill", fillColor = { hex = "#ff9aa2", alpha = 0.6 }, frame = { x = mx + 70, y = my + 60, w = 12, h = 7 } },
    { type = "segments", action = "stroke", closed = false, strokeColor = dark, strokeWidth = 2.5,
      coordinates = { { x = mx + 41, y = my + 64 }, { x = mx + 48, y = my + 69 }, { x = mx + 55, y = my + 64 } } },
    { type = "oval", action = "fill", fillColor = { hex = badge[2] }, frame = { x = mx + 74, y = my + 2, w = 24, h = 24 } },
    { type = "text", text = hs.styledtext.new(badge[1], { font = { name = "Helvetica-Bold", size = 15 },
      color = { white = 1 }, paragraphStyle = { alignment = "center" } }), frame = { x = mx + 74, y = my + 4, w = 24, h = 22 } },
  }
end

local function text(s, size, color, bold, font)
  return hs.styledtext.new(s or "", { font = { name = font or (bold and "Helvetica-Bold" or "Helvetica"), size = size },
    color = color, paragraphStyle = { lineBreak = "truncateTail" } })
end

local function button(id, label, x, w, color)
  return {
    { id = id, trackMouseUp = true, type = "rectangle", action = "fill", fillColor = { hex = color },
      roundedRectRadii = { xRadius = 7, yRadius = 7 }, frame = { x = x, y = H - 44, w = w, h = 28 } },
    { id = id, trackMouseUp = true, type = "text", text = hs.styledtext.new(label, { font = { name = "Helvetica-Bold", size = 13 },
      color = { white = 1 }, paragraphStyle = { alignment = "center" } }), frame = { x = x, y = H - 39, w = w, h = 20 } },
  }
end

local function floating(c)
  c:level(hs.canvas.windowLevels.floating)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c:clickActivating(false)
  return c
end

-- The pet trots in from the side with more room and slows down as it arrives; the bubble opens
-- where it stops.
local RUN = 340 -- pixels per second
local function runIn(b, place, screen, arrive)
  local dest = { x = place.x + PET.x, y = place.y + PET.y }
  local fromLeft = dest.x - screen.x > screen.x + screen.w - dest.x
  local from = { x = fromLeft and math.max(screen.x, dest.x - 380) or math.min(screen.x + screen.w - PET.w, dest.x + 380), y = dest.y }
  local mood = fromLeft and "right" or "left"
  local seconds = math.max(0.4, math.abs(dest.x - from.x) / RUN)
  b.runner = floating(hs.canvas.new({ x = from.x, y = from.y, w = PET.w, h = PET.h }))
  b.runner:appendElements({ type = "image", image = frame(mood, 0), imageScaling = "scaleProportionally",
    frame = { x = 0, y = 0, w = PET.w, h = PET.h } })
  b.runner:show(0.2)
  local start = hs.timer.secondsSinceEpoch()
  b.runTimer = hs.timer.doEvery(1 / 30, function()
    local t = math.min(1, (hs.timer.secondsSinceEpoch() - start) / seconds)
    local eased = 1 - (1 - t) ^ 2
    b.runner[1].image = frame(mood, math.floor((hs.timer.secondsSinceEpoch() - start) / SPEED[mood]))
    b.runner:topLeft({ x = from.x + (dest.x - from.x) * eased, y = dest.y })
    if t >= 1 then
      b.runTimer:stop()
      b.runner:delete()
      b.runner = nil
      arrive()
    end
  end)
end

local function show(req)
  hide(req.session)
  local p = settings()
  layout(p.size)
  loadPet(p.id)
  local w = windowOf(req.session)
  local place, screen = frameFor(req.session, w)
  local title = req.kind == "ask" and string.format(t("ask"), req.tool or "?") or t(req.kind)
  M.last = req
  local where = "▸ " .. (req.label or "") .. (req.seconds and ("  ·  " .. req.seconds .. " s") or "")
  local detail = req.kind == "done" and req.text or req.detail
  local c = floating(hs.canvas.new(place))
  c:appendElements(
    { type = "rectangle", action = "strokeAndFill", fillColor = { hex = "#1f2329", alpha = 0.97 },
      strokeColor = { hex = "#3a4150" }, strokeWidth = 1, roundedRectRadii = { xRadius = 12, yRadius = 12 },
      frame = { x = 1, y = 4, w = BW, h = H - 8 }, withShadow = true },
    { type = "segments", action = "fill", fillColor = { hex = "#1f2329", alpha = 0.97 },
      coordinates = { { x = BW, y = H / 2 - 4 }, { x = BW + 14, y = H / 2 + 8 }, { x = BW, y = H / 2 + 14 } } },
    { type = "text", text = text(title, 15, { white = 1 }, true), frame = { x = 14, y = 12, w = BW - 26, h = 20 } },
    { type = "text", text = text(where, 12, { hex = "#9aa5b5" }), frame = { x = 14, y = 34, w = BW - 26, h = 16 } },
    { type = "text", text = text(detail, 12, { hex = "#dcdcdc" }, false, "Menlo"),
      frame = { x = 14, y = 54, w = BW - 26, h = req.kind == "ask" and 34 or 48 } }
  )
  if req.kind == "ask" then
    for _, e in ipairs(button("allow", t("allow"), 14, 92, "#2e9d5b")) do c:appendElements(e) end
    for _, e in ipairs(button("deny", t("deny"), 112, 92, "#c94a4a")) do c:appendElements(e) end
    c:appendElements({ id = "go", trackMouseUp = true, type = "text", text = text(t("go"), 12, { hex = "#8fb0ff" }),
      frame = { x = 212, y = H - 38, w = BW - 220, h = 18 } })
  else
    c:appendElements({ type = "text", text = text(t("click"), 11, { hex = "#7b8494" }), frame = { x = 14, y = H - 28, w = BW - 26, h = 14 } })
  end
  local b = { canvas = c, req = req, window = w and w:id(), home = MOOD[req.kind], look = p.look }
  if sheet then
    play(b, b.home, true)
    c:appendElements({ type = "image", image = frame(b.mood, 0), imageScaling = "scaleProportionally", frame = PET })
    local pet = #c
    b.timer = hs.timer.doEvery(0.05, function() animate(b, function(img) c[pet].image = img end) end)
  else
    c:appendElements(table.unpack(drawnPet(req.kind)))
    local base, up = place, false
    b.timer = hs.timer.doEvery(0.6, function()
      up = not up
      c:topLeft({ x = base.x, y = base.y - (up and 3 or 0) })
    end)
  end
  c:canvasMouseEvents(false, true)
  c:mouseCallback(function(_, msg, id)
    if msg ~= "mouseUp" then return end
    if id == "allow" or id == "deny" then return hide(req.session, id) end
    hide(req.session, "terminal")
    goTo(req.session)
  end)
  bubbles[req.session] = b
  if sheet and p.run then runIn(b, place, screen, function() c:show(0.15) end) else c:show(0.15) end
end

-- Switched off (▦ menu or the editor): the pet stays away and every approval goes to the terminal.
function M.enabled() return settings().enabled end

function M.name()
  loadPet(settings().id)
  return petName
end

function M.toggle()
  local p = settings()
  p.enabled = not p.enabled
  require("zonas").save()
  if not p.enabled then
    for session in pairs(bubbles) do hide(session, "terminal") end
  end
end

local function handle(req)
  if req.kind == "bind" then
    local w = hs.window.focusedWindow()
    local app = w and w:application()
    if app and TERMINALS[app:bundleID()] then windows[req.session] = w:id() end
    return hide(req.session, "terminal")
  end
  local p = settings()
  if not p.enabled or not p.events[EVENT[req.kind]] then
    if req.kind == "ask" then answer(req, "terminal") end
    return
  end
  -- You are already in that window: the terminal shows it, no pet needed.
  local w, focused = windowOf(req.session), hs.window.focusedWindow()
  if w and focused and w:id() == focused:id() then
    if req.kind == "ask" then answer(req, "terminal") end
    return
  end
  show(req)
end

local function poll()
  local files = {}
  for file in hs.fs.dir(INBOX) do
    if file:match("%.json$") then files[#files + 1] = file end
  end
  for _, file in ipairs(files) do
    local path = INBOX .. "/" .. file
    local req = hs.json.read(path)
    os.remove(path)
    -- The id names files: anything but letters, digits and dashes is not ours.
    if type(req) == "table" and type(req.session) == "string" and type(req.id) == "string"
      and req.id:match("^[%w%-]+$") then handle(req) end
  end
end

-- Shows a pop-up without the mod, to see how it looks: require("mascota").demo("ask").
function M.demo(kind)
  show({ kind = kind or "done", session = "demo-" .. (kind or "done"), id = "demo", label = "demo", tool = "Bash",
    detail = "git push origin feature/mascota", text = "This is how a finished session looks.", seconds = 42 })
end

function M.start()
  hs.fs.mkdir(INBOX)
  -- Requests left from before a reload are stale: their callers already gave up.
  for file in hs.fs.dir(INBOX) do
    if file ~= "." and file ~= ".." then os.remove(INBOX .. "/" .. file) end
  end
  watcher = hs.pathwatcher.new(INBOX, poll):start()
  focusFilter = hs.window.filter.new(function(w)
    local app = w:application()
    return app ~= nil and TERMINALS[app:bundleID()] == true
  end)
  -- Going to the window yourself answers for the pet: the normal prompt is right there.
  focusFilter:subscribe(hs.window.filter.windowFocused, function(w)
    for session, b in pairs(bubbles) do
      if b.window == w:id() then hide(session, "terminal") end
    end
  end)
end

return M
