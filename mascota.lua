-- Claude Code mascot: one pet that runs to the terminal window whose Claude session finished, has a
-- question or needs an approval, with a bubble you can answer in. Several messages share the one
-- pet: the bubble pages through them (‹ 1/3 ›) and the pet walks to the window of the one shown.
-- The "mascota" Claude Code plugin drops one JSON request per event in INBOX; taking the file
-- (deleting it) tells the plugin we are here. A request with `wait` is answered by writing
-- <id>.answer next to it; a reply typed in a "done" bubble goes to replies/<session>.reply, which
-- that session's plugin submits as a prompt.
local M = {}

local INBOX = os.getenv("HOME") .. "/Library/Caches/mascota"
local REPLIES = INBOX .. "/replies"
local TERMINALS = { ["com.mitchellh.ghostty"] = true, ["com.googlecode.iterm2"] = true, ["com.apple.Terminal"] = true }
local BW = 340 -- bubble width; the pet stands to its right
local GAP = 10 -- between the bubble and the pet

-- The pet is a Codex pet (~/.codex/pets/<id>): an 8 × 11 sheet of 192 × 208 frames, one animation
-- per row. Without one, a small drawn creature stands in.
local PETS = os.getenv("HOME") .. "/.codex/pets"
local FW, FH = 192, 208
local ROWS = { idle = { 0, 6 }, right = { 1, 8 }, left = { 2, 8 }, wave = { 3, 4 }, jump = { 4, 5 },
  fail = { 5, 8 }, wait = { 6, 6 }, review = { 8, 6 } }
local MOOD = { done = "wave", question = "wait", ask = "review", needs = "review" }
local EVENT = { done = "done", question = "question", ask = "needs", needs = "needs" } -- kind → setting
-- What each request says about its session, for the counts: working, idle or waiting for you.
local STATE = { bind = "working", working = "working", done = "idle", question = "waiting", needs = "waiting", ask = "waiting" }
local SIZES = { s = 0.4, m = 0.5, l = 0.62 }
-- Seconds per frame: calm loops, quicker reactions, like the pets in Codex.
local SPEED = { idle = 0.24, wave = 0.17, wait = 0.22, review = 0.22, jump = 0.11, fail = 0.14, right = 0.1, left = 0.1 }
local RUN = 340 -- pixels per second

local STR = {
  es = { done = "¡Listo!", question = "Tengo una pregunta", needs = "Te necesito en la terminal", ask = "¿Puedo usar %s?",
    allow = "Aprobar", deny = "Rechazar", go = "Ir a la terminal →", reply = "Responde a Claude…", send = "Enviar",
    other = "Otra respuesta…", working = "trabajando", waiting = "te esperan", close = "Cerrar" },
  en = { done = "Done!", question = "I have a question", needs = "I need you in the terminal", ask = "May I use %s?",
    allow = "Approve", deny = "Deny", go = "Go to terminal →", reply = "Reply to Claude…", send = "Send",
    other = "Another answer…", working = "working", waiting = "waiting for you", close = "Close" },
}
local function t(k) return (STR[require("zonas").lang()] or STR.en)[k] end
-- The pet's settings live with the zones (zonas.json), edited in the ▦ editor's Pet tab.
local function settings() return require("zonas").pet() end

local windows = {} -- session → id of the window you last typed into
local status = {} -- session → { state, at }
local pet -- the pet on screen: { canvas, web, items, index, size, ... } or nil
local drag -- the pet being dragged: { from, at, moved }
local sheet, frames, petName, loadedId = nil, {}, nil, nil
local watcher, focusFilter, mouseTap, tapGuard

-- Pet sprites ----------------------------------------------------------------------------

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

local function play(mood, once)
  pet.mood, pet.n, pet.at, pet.once = mood, 0, hs.timer.secondsSinceEpoch(), once
end

-- The stand-in when there is no Codex pet: a round orange creature with a badge for the kind.
local function drawnPet(kind, size)
  local mx, my = (size.w - 96) / 2, size.h - 96
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

-- One step of the pet's life: it plays its mood once, then breathes (idle) and plays it again now
-- and then; while you move the mouse it turns to look at it. Nothing while it runs or is dragged.
local function animate()
  if drag and not hs.eventtap.checkMouseButtons().left then drag = nil end
  if pet.running and not (pet.runTimer and pet.runTimer:running()) then pet.running = false end
  if not sheet or pet.running or drag then return end
  local now = hs.timer.secondsSinceEpoch()
  local mouse = hs.mouse.absolutePosition()
  if pet.mouse and math.abs(mouse.x - pet.mouse.x) + math.abs(mouse.y - pet.mouse.y) > 2 then pet.movedAt = now end
  pet.mouse = mouse
  if pet.look and not pet.once and pet.movedAt and now - pet.movedAt < 1.2 then
    local f = pet.canvas:frame()
    pet.canvas[1].image = look(math.atan(mouse.x - (f.x + f.w / 2), (f.y + f.h / 3) - mouse.y))
    return
  end
  if now - pet.at < SPEED[pet.mood] then return end
  pet.at, pet.n = now, pet.n + 1
  if pet.n >= ROWS[pet.mood][2] then
    if pet.leaving then pet.n = ROWS[pet.mood][2] - 1 -- a goodbye holds its last pose
    elseif pet.once then play("idle", false); pet.again = now + 6 + math.random() * 4
    else pet.n = 0 end
  end
  if pet.mood == "idle" and pet.again and now >= pet.again then play(pet.home, true) end
  pet.canvas[1].image = frame(pet.mood, pet.n)
end

-- Files ------------------------------------------------------------------------------------

local function write(path, text)
  local f = io.open(path .. ".tmp", "w")
  if not f then return end
  f:write(text)
  f:close()
  os.rename(path .. ".tmp", path)
end

local function answer(req, value) write(INBOX .. "/" .. req.id .. ".answer", value) end

-- Counts -----------------------------------------------------------------------------------

-- A session silent for 3 hours is gone (closed without telling us).
local function counts()
  local working, waiting, now = 0, 0, os.time()
  for session, st in pairs(status) do
    if now - st.at > 3 * 3600 then status[session] = nil
    elseif st.state == "working" then working = working + 1
    elseif st.state == "waiting" then waiting = waiting + 1 end
  end
  return working, waiting
end

local function refreshCounts()
  local working, waiting = counts()
  require("zonas").badge((working > 0 and ("  ⚙" .. working) or "") .. (waiting > 0 and ("  ✋" .. waiting) or ""))
  if pet and pet.web then pet.web:evaluateJavaScript(string.format("counts(%d, %d)", working, waiting)) end
end

local function setStatus(session, state)
  status[session] = state and { state = state, at = os.time() } or nil
  refreshCounts()
end

-- The bubble -------------------------------------------------------------------------------

local CSS = [[
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { margin: 0; background: transparent; overflow: hidden;
  font: 13px/1.35 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; color: #e8ebf0; }
.b { position: relative; margin: 2px 12px 4px 2px; padding: 10px 12px 12px; border-radius: 12px;
  background: rgba(31, 35, 41, 0.97); border: 1px solid #3a4150; }
.b::after { content: ""; position: absolute; right: -9px; bottom: 22px;
  border: 8px solid transparent; border-right: 0; border-left-color: #3a4150; }
.top { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; min-height: 18px; }
.counts { display: flex; gap: 12px; font-size: 11px; color: #9aa5b5; }
.counts span { display: inline-flex; align-items: center; gap: 5px; }
.counts i { width: 7px; height: 7px; border-radius: 50%; display: inline-block; }
.counts .work i { background: #4f8cff; } .counts .wait i { background: #f0a24a; }
.nav { margin-left: auto; display: flex; align-items: center; gap: 2px; font-size: 11px; color: #9aa5b5; }
.nav button { background: none; color: #c9d1dc; padding: 0 6px; font-size: 15px; line-height: 18px; }
.nav button:hover { color: #fff; }
h1 { font-size: 15px; margin: 0 0 2px; }
.where { color: #9aa5b5; font-size: 12px; margin-bottom: 6px; }
.detail { font: 12px/1.35 Menlo, monospace; color: #dcdcdc; max-height: 4.1em; overflow: hidden;
  margin-bottom: 8px; word-break: break-word; }
.answer { font: 13px/1.45 -apple-system, system-ui, sans-serif; max-height: 15em; overflow-y: auto;
  white-space: pre-wrap; padding-right: 4px; }
.row { display: flex; gap: 6px; align-items: center; }
.col { display: grid; gap: 5px; margin-bottom: 6px; }
button { font: 600 13px -apple-system, system-ui, sans-serif; border: 0; border-radius: 7px; padding: 6px 12px;
  color: #fff; cursor: pointer; }
.allow { background: #2e9d5b; } .deny { background: #c94a4a; } .send { background: #3b6fd6; }
.opt { background: #2c3442; border: 1px solid #45506a; font-weight: 500; text-align: left; }
.opt:hover { border-color: #8fb0ff; }
.opt small { display: block; color: #9aa5b5; font-weight: 400; font-size: 11px; }
.link { background: none; color: #8fb0ff; padding: 6px 2px; font-weight: 500; margin-left: auto; }
input { flex: 1; min-width: 0; font: 13px -apple-system, system-ui, sans-serif; color: #e8ebf0;
  background: #12161d; border: 1px solid #45506a; border-radius: 7px; padding: 6px 8px; outline: none; }
input:focus { border-color: #8fb0ff; }
]]

local JS = [[
const post = m => window.webkit.messageHandlers.mascota.postMessage(m);
function counts(working, waiting) {
  document.getElementById("counts").innerHTML =
    (working ? `<span class="work"><i></i>${working} ${WORDS.working}</span>` : "")
    + (waiting ? `<span class="wait"><i></i>${waiting} ${WORDS.waiting}</span>` : "");
  size();
}
function size() { post({ action: "size", h: document.querySelector(".b").offsetHeight + 8 }); }
function bind(root) { for (const b of root.querySelectorAll("[data-a]")) b.onclick = () => post({ action: b.dataset.a }); }
// The pager is redrawn on its own, so a new message never wipes what you are typing.
function pager(i, n) {
  const nav = document.getElementById("nav");
  nav.innerHTML = (n > 1 ? `<button data-a="prev">‹</button>${i}/${n}<button data-a="next">›</button>` : "")
    + `<button data-a="close" title="${WORDS.close}">×</button>`;
  bind(nav);
}
bind(document);
for (const b of document.querySelectorAll("[data-i]")) {
  b.onclick = () => post({ action: "answer", answers: { [Q.question]: Q.options[b.dataset.i].label } });
}
const box = document.getElementById("text");
if (box) {
  const send = () => {
    const text = box.value.trim();
    if (!text) return;
    post(Q ? { action: "answer", answers: { [Q.question]: text } } : { action: "reply", text });
  };
  box.onkeydown = e => { if (e.key === "Enter") send(); if (e.key === "Escape") post({ action: "close" }); };
  document.getElementById("send").onclick = send;
}
]]

local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- The bubble as a small web page: the counts and the pager on top, then the message, then what
-- you can do about it.
local function bubbleHTML(req, index, total)
  local title = req.kind == "ask" and string.format(t("ask"), req.tool or "?") or t(req.kind)
  local where = "▸ " .. (req.label or "") .. (req.seconds and ("  ·  " .. req.seconds .. " s") or "")
  local q = req.kind == "question" and req.questions and #req.questions == 1 and not req.questions[1].multiSelect
    and req.questions[1] or nil
  local detail = q and q.question or (req.kind == "done" and req.text or req.detail)
  local go = '<button class="link" data-a="go">' .. esc(t("go")) .. "</button>"
  local controls
  if req.kind == "ask" then
    controls = '<div class="row"><button class="allow" data-a="allow">' .. esc(t("allow")) .. '</button>'
      .. '<button class="deny" data-a="deny">' .. esc(t("deny")) .. "</button>" .. go .. "</div>"
  elseif q then
    local opts = {}
    for i, o in ipairs(q.options or {}) do
      opts[#opts + 1] = string.format('<button class="opt" data-i="%d">%s<small>%s</small></button>', i - 1, esc(o.label), esc(o.description))
    end
    controls = '<div class="col">' .. table.concat(opts) .. "</div>"
      .. '<div class="row"><input id="text" placeholder="' .. esc(t("other")) .. '">'
      .. '<button class="send" id="send">' .. esc(t("send")) .. "</button></div>"
      .. '<div class="row">' .. go .. "</div>"
  elseif req.kind == "done" then
    controls = '<div class="row"><input id="text" placeholder="' .. esc(t("reply")) .. '">'
      .. '<button class="send" id="send">' .. esc(t("send")) .. "</button></div>"
      .. '<div class="row">' .. go .. "</div>"
  else
    controls = '<div class="row">' .. go .. "</div>"
  end
  local working, waiting = counts()
  local data = string.format("const Q = %s; const WORDS = %s;",
    q and hs.json.encode(q) or "null", hs.json.encode({ working = t("working"), waiting = t("waiting"), close = t("close") }))
  return "<!doctype html><html><head><meta charset=\"utf-8\"><style>" .. CSS .. "</style></head><body>"
    .. '<div class="b"><div class="top"><div class="counts" id="counts"></div><div class="nav" id="nav"></div></div>'
    .. "<h1>" .. esc(title) .. "</h1>"
    .. '<div class="where">' .. esc(where) .. "</div>"
    .. (detail and detail ~= "" and ('<div class="detail' .. (req.kind == "done" and " answer" or "") .. '">'
      .. esc(detail) .. "</div>") or "")
    .. controls .. "</div><script>" .. data:gsub("</", "<\\/") .. JS
    .. string.format("pager(%d, %d); counts(%d, %d);", index, total, working, waiting) .. "</script></body></html>"
end

-- Placing and moving -----------------------------------------------------------------------

local function windowOf(session)
  local id = windows[session]
  return id and hs.window.get(id)
end

local function goTo(session)
  local w = windowOf(session)
  if w then w:focus() else hs.application.launchOrFocusByBundleID("com.mitchellh.ghostty") end
end

-- Where the pet stands for a message: the bottom-right corner inside its session's window.
local function spotFor(req)
  local w = windowOf(req.session)
  local area = w and w:frame() or hs.screen.mainScreen():frame()
  local s = (w and w:screen() or hs.screen.mainScreen()):frame()
  local x = math.max(s.x + BW + GAP, math.min(area.x + area.w - pet.size.w - 16, s.x + s.w - pet.size.w))
  local y = math.max(s.y, math.min(area.y + area.h - pet.size.h - 16, s.y + s.h - pet.size.h))
  return { x = x, y = y }, s
end

-- The bubble stands to the pet's left, bottoms lined up.
local function placeBubble()
  if not pet.web then return end
  local f = pet.canvas:frame()
  pet.web:frame({ x = f.x - GAP - BW - 12, y = f.y + f.h - pet.webH, w = BW + 12, h = pet.webH })
end

-- The pet trots from where it is to `dest`, slowing down as it arrives; the bubble waits for it.
local function runTo(dest, from, arrive)
  from = from or pet.canvas:topLeft()
  if math.abs(dest.x - from.x) + math.abs(dest.y - from.y) < 4 or not sheet or not pet.run then
    pet.canvas:topLeft(dest)
    return arrive()
  end
  local mood = dest.x >= from.x and "right" or "left"
  local seconds = math.max(0.4, math.sqrt((dest.x - from.x) ^ 2 + (dest.y - from.y) ^ 2) / RUN)
  local start = hs.timer.secondsSinceEpoch()
  pet.running = true
  if pet.web then pet.web:hide() end
  if pet.runTimer then pet.runTimer:stop() end
  pet.runTimer = hs.timer.doEvery(1 / 30, function()
    local elapsed = hs.timer.secondsSinceEpoch() - start
    local k = math.min(1, elapsed / seconds)
    local eased = 1 - (1 - k) ^ 2
    pet.canvas[1].image = frame(mood, math.floor(elapsed / SPEED[mood]))
    pet.canvas:topLeft({ x = from.x + (dest.x - from.x) * eased, y = from.y + (dest.y - from.y) * eased })
    if k >= 1 then
      pet.runTimer:stop()
      pet.running = false
      arrive()
    end
  end)
end

local function remove()
  if not pet then return end
  for _, timer in pairs({ pet.timer, pet.runTimer, pet.leaveTimer }) do timer:stop() end
  pet.canvas:delete()
  if pet.web then pet.web:delete() end
  pet = nil
end

-- Shows the message at pet.index: its mood, its bubble, and the walk to its window unless you
-- have dragged the pet somewhere yourself.
local function render(walk)
  local req = pet.items[pet.index]
  pet.home = MOOD[req.kind]
  if sheet then play(pet.home, true) else pet.canvas:replaceElements(table.unpack(drawnPet(req.kind, pet.size))) end
  pet.web:html(bubbleHTML(req, pet.index, #pet.items))
  local function open()
    placeBubble()
    pet.web:show(0.12)
  end
  if walk and not pet.dragged then runTo((spotFor(req)), nil, open) else open() end
end

-- Taking a message off: a waiting one gets its answer ("terminal" hands it back to the normal
-- prompt). With none left the pet leaves, after a jump (or a droop on Deny) for an answer.
local function removeAt(i, reply)
  local req = table.remove(pet.items, i)
  if req.wait then answer(req, reply or "terminal") end
  if #pet.items == 0 then
    if sheet and reply and reply ~= "terminal" then
      pet.web:delete()
      pet.web = nil
      local mood = reply == "deny" and "fail" or "jump"
      play(mood, true)
      pet.leaving = true
      pet.leaveTimer = hs.timer.doAfter(ROWS[mood][2] * SPEED[mood] + 0.3, remove)
    else
      remove()
    end
    return
  end
  local shown = i == pet.index
  if i < pet.index or pet.index > #pet.items then pet.index = pet.index - 1 end
  if shown then render(true) else pet.web:evaluateJavaScript(string.format("pager(%d, %d)", pet.index, #pet.items)) end
end

local function removeSession(session, reply)
  if not pet or pet.leaving then return end
  for i = #pet.items, 1, -1 do
    if pet and pet.items[i] and pet.items[i].session == session then removeAt(i, reply) end
  end
end

local onMessage

local function create(req)
  local p = settings()
  loadPet(p.id)
  local k = SIZES[p.size] or SIZES.m
  pet = { size = { w = math.floor(FW * k), h = math.floor(FH * k) }, items = { req }, index = 1,
    look = p.look, run = p.run, webH = 160 }
  local dest, screen = spotFor(req)
  local fromLeft = dest.x - screen.x > screen.x + screen.w - dest.x
  local from = { x = fromLeft and math.max(screen.x, dest.x - 380) or math.min(screen.x + screen.w - pet.size.w, dest.x + 380), y = dest.y }
  pet.canvas = hs.canvas.new({ x = (sheet and p.run) and from.x or dest.x, y = dest.y, w = pet.size.w, h = pet.size.h })
  pet.canvas:level(hs.canvas.windowLevels.floating)
  pet.canvas:behavior({ "canJoinAllSpaces", "stationary" })
  pet.canvas:clickActivating(false)
  if sheet then
    pet.canvas:appendElements({ type = "image", image = frame("idle", 0), imageScaling = "scaleProportionally",
      frame = { x = 0, y = 0, w = pet.size.w, h = pet.size.h } })
    play(MOOD[req.kind], true)
  else
    pet.canvas:appendElements(table.unpack(drawnPet(req.kind, pet.size)))
  end
  pet.timer = hs.timer.doEvery(0.05, animate)
  local uc = hs.webview.usercontent.new("mascota")
  uc:setCallback(function(m) if type(m.body) == "table" then onMessage(m.body) end end)
  pet.web = hs.webview.new({ x = dest.x - GAP - BW - 12, y = dest.y, w = BW + 12, h = pet.webH }, {}, uc)
    :windowStyle({ "borderless", "nonactivating" })
    :transparent(true)
    :allowTextEntry(true)
    :shadow(false)
    :level(hs.drawing.windowLevels.floating)
    :behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  pet.canvas:show(0.2)
  pet.web:html(bubbleHTML(req, 1, 1))
  runTo(dest, from, function()
    placeBubble()
    if pet and pet.web then pet.web:show(0.15) end
  end)
end

-- A new message joins the pet on screen (one per session: a newer one replaces the older) and
-- the bubble keeps showing what you are reading.
local function add(req)
  if pet and pet.leaving then remove() end
  if not pet then return create(req) end
  local current = pet.items[pet.index]
  for i = #pet.items, 1, -1 do
    local old = pet.items[i]
    if old.session == req.session then
      table.remove(pet.items, i)
      if old.wait then answer(old, "terminal") end
      if i < pet.index then pet.index = pet.index - 1 end
    end
  end
  table.insert(pet.items, req)
  -- Another session's message waits its turn; a newer one from the session on show replaces it.
  if current and current.session ~= req.session then
    for i, item in ipairs(pet.items) do
      if item == current then pet.index = i end
    end
    pet.web:evaluateJavaScript(string.format("pager(%d, %d)", pet.index, #pet.items))
  else
    pet.index = #pet.items
    render(true)
  end
end

onMessage = function(m)
  if not pet or pet.leaving then return end
  local req = pet.items[pet.index]
  if m.action == "size" then
    pet.webH = math.ceil(m.h)
    placeBubble()
    -- The page has loaded: a message that came while it loaded missed the pager, so set it now.
    pet.web:evaluateJavaScript(string.format("pager(%d, %d)", pet.index, #pet.items))
  elseif m.action == "prev" or m.action == "next" then
    pet.index = (pet.index - 1 + (m.action == "next" and 1 or -1)) % #pet.items + 1
    render(true)
  elseif m.action == "allow" or m.action == "deny" then
    setStatus(req.session, "working")
    removeAt(pet.index, m.action)
  elseif m.action == "answer" and type(m.answers) == "table" then
    setStatus(req.session, "working")
    removeAt(pet.index, hs.json.encode(m.answers))
  elseif m.action == "reply" and type(m.text) == "string" then
    write(REPLIES .. "/" .. req.session .. ".reply", m.text)
    setStatus(req.session, "working")
    local back = pet.back
    removeAt(pet.index, "reply")
    if back then back:focus() end
  elseif m.action == "close" then
    removeAt(pet.index, "terminal")
  else
    removeAt(pet.index, "terminal")
    goTo(req.session)
  end
end

-- Mouse ------------------------------------------------------------------------------------

local function inside(p, f) return f and p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h end

-- Dragging the pet moves it and its bubble, and it stays where you leave it; a click without
-- moving goes to the terminal. A click on the bubble is taken here too: the bubble is a window
-- that is not active, and macOS spends the first click on activating it. So the bubble becomes
-- active (for typing) and the button or box under the pointer is pressed or focused at once.
local function onMouse(e)
  if not pet then return false end
  local types = hs.eventtap.event.types
  local kind, p = e:getType(), e:location()
  if kind == types.leftMouseDown and inside(p, pet.canvas:frame()) then
    drag = { from = p, at = pet.canvas:topLeft(), moved = false }
    return true
  end
  if drag and kind == types.leftMouseDragged then
    local dx, dy = p.x - drag.from.x, p.y - drag.from.y
    drag.moved = drag.moved or math.abs(dx) + math.abs(dy) > 3
    pet.canvas:topLeft({ x = drag.at.x + dx, y = drag.at.y + dy })
    placeBubble()
    return true
  end
  if drag and kind == types.leftMouseUp then
    local moved = drag.moved
    drag = nil
    if moved then pet.dragged = true else hs.timer.doAfter(0, function() onMessage({ action = "go" }) end) end
    return true
  end
  local f = kind == types.leftMouseDown and pet.web and pet.web:isVisible() and pet.web:frame()
  if not inside(p, f) then return false end
  local x, y = math.floor(p.x - f.x), math.floor(p.y - f.y)
  hs.timer.doAfter(0, function()
    if not (pet and pet.web) then return end
    local win = pet.web:hswindow()
    if win and hs.window.focusedWindow() ~= win then
      pet.back = hs.window.focusedWindow()
      win:focus()
    end
    pet.web:evaluateJavaScript(string.format([[(() => {
      const el = document.elementFromPoint(%d, %d);
      const target = el && el.closest("button, input");
      if (target && target.tagName === "INPUT") target.focus(); else if (target) target.click();
    })()]], x, y))
  end)
  return true
end

-- Requests ---------------------------------------------------------------------------------

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
  if not p.enabled and pet then
    while pet and not pet.leaving do removeAt(#pet.items, "terminal") end
  end
end

local function handle(req)
  if req.kind == "end" then
    removeSession(req.session, "terminal")
    windows[req.session] = nil
    return setStatus(req.session, nil)
  end
  setStatus(req.session, STATE[req.kind])
  if req.kind == "working" then return end
  if req.kind == "bind" then
    local w = hs.window.focusedWindow()
    local app = w and w:application()
    if app and TERMINALS[app:bundleID()] then windows[req.session] = w:id() end
    return removeSession(req.session, "terminal")
  end
  local p = settings()
  local w, focused = windowOf(req.session), hs.window.focusedWindow()
  -- Switched off, not wanted for this event, or you are already in that window: no pet.
  if not p.enabled or not p.events[EVENT[req.kind]] or (w and focused and w:id() == focused:id()) then
    if req.wait then answer(req, "terminal") end
    return
  end
  add(req)
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
    -- Ids and sessions name files: anything but letters, digits and dashes is not ours.
    if type(req) == "table" and type(req.session) == "string" and req.session:match("^[%w%-]+$")
      and type(req.id) == "string" and req.id:match("^[%w%-]+$") then handle(req) end
  end
end

-- For checking from the hs command line: the pet on screen, or nil.
function M.current() return pet end

-- Shows a message without the plugin, to see how it looks: require("mascota").demo("question").
function M.demo(kind)
  kind = kind or "done"
  add({ kind = kind, session = "demo-" .. kind, id = "demo-" .. kind, label = "demo", tool = "Bash",
    detail = "git push origin feature/mascota", text = "This is how a finished session looks.", seconds = 42,
    questions = { { question = "Which layout should the laptop use?", multiSelect = false, options = {
      { label = "Halves", description = "Two columns" }, { label = "Thirds", description = "Three columns" } } } } })
end

function M.start()
  hs.fs.mkdir(INBOX)
  hs.fs.mkdir(REPLIES)
  -- Requests left from before a reload are stale: their callers already gave up.
  for file in hs.fs.dir(INBOX) do
    if file:match("%.json$") or file:match("%.answer$") then os.remove(INBOX .. "/" .. file) end
  end
  watcher = hs.pathwatcher.new(INBOX, poll):start()
  local types = hs.eventtap.event.types
  mouseTap = hs.eventtap.new({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp }, onMouse):start()
  -- macOS turns off a mouse listener that answered too slowly once; turn it back on.
  tapGuard = hs.timer.doEvery(3, function() if not mouseTap:isEnabled() then drag = nil; mouseTap:start() end end)
  focusFilter = hs.window.filter.new(function(w)
    local app = w:application()
    return app ~= nil and TERMINALS[app:bundleID()] == true
  end)
  -- Going to a window yourself answers for the pet: the normal prompt is right there.
  focusFilter:subscribe(hs.window.filter.windowFocused, function(w)
    if not pet then return end
    for session, id in pairs(windows) do
      if id == w:id() then removeSession(session, "terminal") end
    end
  end)
end

return M
