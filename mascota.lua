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
local BW = 340 -- bubble width until you resize it; the pet stands to its right
-- A background session's bubble is its own terminal: ttyd serves `claude attach <id>` there.
local TTYD = hs.fs.attributes("/opt/homebrew/bin/ttyd") and "/opt/homebrew/bin/ttyd"
  or hs.fs.attributes("/usr/local/bin/ttyd") and "/usr/local/bin/ttyd"
local CLAUDE
for _, path in ipairs({ os.getenv("HOME") .. "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude" }) do
  if not CLAUDE and hs.fs.attributes(path) then CLAUDE = path end
end
local BUBBLE = "mascota.bubble" -- { w, h } you gave the bubble by dragging its top-left corner
local GAP = 10 -- between the bubble and the pet
local SPOT = "mascota.spot" -- { [screen uuid] = { x, y } } where you last dropped the pet, from the screen's top-left
local RECENT = "mascota.recent" -- your last 10 sessions, newest first: { claude, session, name, cwd, bg, at }

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
    other = "Otra respuesta…", working = "trabajando", waiting = "te esperan", idle = "terminadas", close = "Cerrar",
    sWorking = "trabajando", sWaiting = "te espera", sIdle = "terminada",
    prev = "Mensaje anterior", next = "Mensaje siguiente", state = "Qué hace esta sesión ahora", inBubble = "💬 Burbuja", inTerminal = "Terminal ↗",
    recent = "recientes", resume = "Retomar ↗",
    minimize = "Minimizar (clic en la mascota para abrir)", editor = "Abrir en %s ↗", editorDefault = "el editor",
    nobody = "Todavía no hay sesiones que mostrar" },
  en = { done = "Done!", question = "I have a question", needs = "I need you in the terminal", ask = "May I use %s?",
    allow = "Approve", deny = "Deny", go = "Go to terminal →", reply = "Reply to Claude…", send = "Send",
    other = "Another answer…", working = "working", waiting = "waiting for you", idle = "done", close = "Close",
    sWorking = "working", sWaiting = "needs input", sIdle = "done",
    prev = "Previous message", next = "Next message", state = "What this session is doing now", inBubble = "💬 Bubble", inTerminal = "Terminal ↗",
    recent = "recent", resume = "Resume ↗",
    minimize = "Minimize (click the pet to open)", editor = "Open in %s ↗", editorDefault = "the editor",
    nobody = "No sessions to show yet" },
}
local function t(k) return (STR[require("zonas").lang()] or STR.en)[k] end
-- The pet's settings live with the zones (zonas.json), edited in the ▦ editor's Pet tab.
local function settings() return require("zonas").pet() end

local windows = {} -- session → { app, id } of the window you last typed into
local status = {} -- session → { state, at }
local pet -- the pet on screen: { canvas, web, items, index, size, ... } or nil
local drag -- the pet being dragged: { from, at, moved }
local resize -- the bubble being resized: { from, w, h }
local sheet, petName, loadedId = nil, nil, nil
local watcher, mouseTap, tapGuard, idleTimer, jobTimer
local queue, waitingSince = {}, 0 -- messages waiting for you to pause, before the pet comes out

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
  loadedId, sheet, petName = id, nil, nil
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
      -- The first frame, drawn small through a canvas: a crop of the sheet would hold ~56 MB.
      local c = hs.canvas.new({ x = 0, y = 0, w = 96, h = 104 })
      c:appendElements({ type = "image", image = img, imageScaling = "scaleToFit", frame = { x = 0, y = 0, w = 8 * 96, h = 11 * 104 } })
      local thumb = c:imageFromCanvas()
      c:delete()
      list[#list + 1] = { id = dir, name = info.displayName or dir, description = info.description or "",
        thumb = thumb:encodeAsURLString() }
    end
  end
  return list
end

-- A frame is a place on the sheet, not an image of its own: every cut of the sheet held about
-- 56 MB (1.2 GB for the pet's frames), so the canvas shows the whole sheet and moves it under a
-- window the size of one frame.
local function cell(row, col) return { row = row, col = col } end

local function draw(c)
  if pet.cell and pet.cell.row == c.row and pet.cell.col == c.col then return end
  pet.cell = c
  local w, h = pet.size.w, pet.size.h
  pet.canvas[1].frame = { x = -c.col * w, y = -c.row * h, w = 8 * w, h = 11 * h }
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
-- In focus mode it plays a message's mood once and then holds still, without looking at the mouse.
local function animate()
  if pet.running and not (pet.runTimer and pet.runTimer:running()) then pet.running = false end
  if not sheet or pet.running or drag then return end
  local now = hs.timer.secondsSinceEpoch()
  local focus = settings().mode == "focus"
  local mouse = pet.look and not focus and hs.mouse.absolutePosition()
  if mouse and pet.mouse and math.abs(mouse.x - pet.mouse.x) + math.abs(mouse.y - pet.mouse.y) > 2 then pet.movedAt = now end
  pet.mouse = mouse
  if focus and pet.mood == "idle" then return draw(frame("idle", 0)) end
  if mouse and not pet.once and pet.movedAt and now - pet.movedAt < 1.2 then
    local f = pet.canvas:frame()
    draw(look(math.atan(mouse.x - (f.x + f.w / 2), (f.y + f.h / 3) - mouse.y)))
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
  draw(frame(pet.mood, pet.n))
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

-- A background session's name, which its terminal carries as its title ("◐ <name>"); its job
-- folder keeps it, and it can change (Claude names a session after its first prompts).
local function bgName(bg)
  local file = os.getenv("HOME") .. "/.claude/jobs/" .. bg .. "/state.json"
  local state = hs.fs.attributes(file) and hs.json.read(file)
  return type(state) == "table" and type(state.name) == "string" and state.name ~= "" and state.name or nil
end

-- A session's title as Claude Code shows it: the name you gave it (/rename), else the one Claude
-- made up. Both are lines of its transcript, found by Claude's id for it; the file is read whole
-- once, then only the lines added since.
local PROJECTS = os.getenv("HOME") .. "/.claude/projects/"
local titles = {} -- claude id → { path, read, custom, ai }
local function sessionTitle(claude)
  if type(claude) ~= "string" or not claude:match("^[%w%-]+$") then return nil end
  local c = titles[claude]
  if not c then
    for dir in hs.fs.dir(PROJECTS) do
      local path = PROJECTS .. dir .. "/" .. claude .. ".jsonl"
      if hs.fs.attributes(path) then c = { path = path, read = 0 }; break end
    end
    if not c then return nil end
    titles[claude] = c
  end
  if (hs.fs.attributes(c.path, "size") or 0) > c.read then
    local f = io.open(c.path, "rb")
    if f then
      f:seek("set", c.read)
      local lines = (f:read("a") or ""):match("^.*\n") or "" -- a line being written waits
      f:close()
      c.read = c.read + #lines
      for t in lines:gmatch('"customTitle":"([^"]*)"') do c.custom = t end
      for t in lines:gmatch('"aiTitle":"([^"]*)"') do c.ai = t end
    end
  end
  local title = c.custom or c.ai
  return title ~= "" and title or nil
end

-- Every request puts its session first among the recent ones, by Claude's own id for it (the one
-- `claude --resume` takes; a plugin reload gives the same session a new id of ours).
local function remember(req)
  if type(req.claude) ~= "string" or not req.claude:match("^[%w%-]+$") then return end
  local list, old = hs.settings.get(RECENT) or {}, {}
  for i = #list, 1, -1 do
    if list[i].claude == req.claude then old = table.remove(list, i) end
  end
  local repo = type(req.status) == "table" and type(req.status.repo) == "string" and req.status.repo
  table.insert(list, 1, { claude = req.claude, session = req.session, at = os.time(), bg = req.bg or old.bg,
    name = repo or old.name or req.label or "?", cwd = type(req.cwd) == "string" and req.cwd or old.cwd })
  while #list > 10 do table.remove(list) end
  hs.settings.set(RECENT, list)
end

local function ago(s)
  s = math.floor(s)
  return s < 3600 and math.max(1, s // 60) .. " min" or s < 86400 and s // 3600 .. " h" or s // 86400 .. " d" end

-- How many sessions are working, waiting for you and done, and each one ({ name, session }) for
-- the hints, then the recent ones, newest first, open (`live`) or ended. A session silent for 3
-- hours is gone (closed without telling us).
local function counts()
  local by, now = { working = {}, waiting = {}, idle = {} }, os.time()
  for session, st in pairs(status) do
    if now - st.at > 3 * 3600 then status[session], windows[session] = nil, nil
    elseif by[st.state] then
      local name = st.bg and bgName(st.bg)
      table.insert(by[st.state], { name = (st.repo or st.label or "?") .. (name and (" · " .. name) or ""), session = session })
    end
  end
  for _, list in pairs(by) do table.sort(list, function(a, b) return a.name < b.name end) end
  -- Only a session's newest conversation is open: one before its /clear can be resumed.
  by.recent = {}
  local seen = {}
  for _, r in ipairs(hs.settings.get(RECENT) or {}) do
    local name = r.bg and bgName(r.bg)
    table.insert(by.recent, { name = r.name .. (name and (" · " .. name) or ""), session = r.session, claude = r.claude,
      live = status[r.session] ~= nil and not seen[r.session], ago = ago(now - r.at) })
    seen[r.session] = true
  end
  return #by.working, #by.waiting, #by.idle, by
end

-- What the session on show is doing now (the last word from it), else what its message says.
local function stateOf(req)
  local st = req and status[req.session]
  return st and st.state or req and STATE[req.kind] or ""
end

-- The bubble's call that draws the counts and the state of the session on show, and the words
-- its page needs.
local function countsJS()
  local _, _, _, by = counts()
  return string.format("counts(%s); mine(%q);", hs.json.encode(by), stateOf(pet and pet.items[pet.index]))
end
local function words()
  return hs.json.encode({ working = t("working"), waiting = t("waiting"), idle = t("idle"), close = t("close"),
    minimize = t("minimize"), sWorking = t("sWorking"), sWaiting = t("sWaiting"), sIdle = t("sIdle"),
    prev = t("prev"), next = t("next"), state = t("state"), inBubble = t("inBubble"), inTerminal = t("inTerminal"),
    recent = t("recent"), resume = t("resume") })
end

local shownCounts
local function refreshCounts()
  local working, waiting, idle = counts()
  -- The bubble whenever what it shows changed: the session on show may have changed state while
  -- the totals did not.
  if pet and pet.web then
    local js = countsJS()
    if js ~= pet.countsJS then pet.countsJS = js; pet.web:evaluateJavaScript(js) end
  end
  local key = working .. "/" .. waiting .. "/" .. idle
  if key == shownCounts then return end
  shownCounts = key
  require("zonas").badge((working > 0 and ("  ⚙" .. working) or "") .. (waiting > 0 and ("  ✋" .. waiting) or ""))
end

-- What a request says about its session, and where it comes from, for the hints; `last` is its
-- last message the bubble showed, which a count's list opens again.
local function setStatus(session, state, req)
  local old = status[session] or {}
  status[session] = state and { state = state, at = os.time(), label = req and req.label or old.label,
    bg = req and req.bg or old.bg, last = req and MOOD[req.kind] and req or old.last,
    repo = req and type(req.status) == "table" and type(req.status.repo) == "string" and req.status.repo or old.repo } or nil
  refreshCounts()
end

local JOBS = os.getenv("HOME") .. "/.claude/jobs/"
local JOB_STATE = { working = "working", blocked = "waiting", done = "idle" } -- a stopped one is gone

-- Background sessions (`claude agents`) say themselves what they are doing, in their job's
-- state.json, and that wins over what the hooks said: a turn that ended with a shell or a subagent
-- still running is working, which the hooks cannot always tell. A job whose file was not touched
-- for 3 hours is gone; one the pet never heard from (begun before a reload) joins as job-<id>, and
-- a session heard from under two ids of ours (a plugin reload) counts once, as the newest.
local function syncJobs()
  if not hs.fs.attributes(JOBS) then return end
  local jobs, now = {}, os.time()
  for bg in hs.fs.dir(JOBS) do
    local file = JOBS .. bg .. "/state.json"
    local attrs = bg:match("^%w+$") and hs.fs.attributes(file)
    if attrs and now - attrs.modification < 3 * 3600 then
      local d = hs.json.read(file)
      if type(d) == "table" then jobs[bg] = { state = d.state, at = math.floor(attrs.modification), cwd = d.cwd } end
    end
  end
  local newest = {}
  for session, st in pairs(status) do
    if st.bg and (not newest[st.bg] or status[newest[st.bg]].at < st.at) then newest[st.bg] = session end
  end
  for session, st in pairs(status) do
    local job = st.bg and jobs[st.bg]
    if st.bg and (newest[st.bg] ~= session or job and not JOB_STATE[job.state]) then
      status[session], windows[session] = nil, nil
    elseif job then
      st.state, st.at = JOB_STATE[job.state], math.max(st.at, job.at)
    end
  end
  for bg, job in pairs(jobs) do
    if not newest[bg] and JOB_STATE[job.state] then
      status["job-" .. bg] = { state = JOB_STATE[job.state], at = job.at, bg = bg,
        label = type(job.cwd) == "string" and job.cwd:match("[^/]+$") or bg }
    end
  end
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
.counts { display: flex; gap: 10px; font: 600 12px -apple-system, system-ui, sans-serif; }
.counts span { display: inline-flex; align-items: center; gap: 3px; }
.repo { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  font: 600 12px Menlo, monospace; color: #c9d1dc; }
.repo .title { font: 500 12px -apple-system, system-ui, sans-serif; color: #9aa5b5; }
#tip.list { pointer-events: auto; white-space: normal; overflow-y: auto; }
#tip .s { display: flex; align-items: center; gap: 4px; margin-top: 3px; }
#tip .s span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; margin-right: 6px; }
#tip .go { flex: none; padding: 2px 5px; background: none; color: #8fb0ff;
  font: 500 12px -apple-system, system-ui, sans-serif; border-radius: 5px; }
#tip .go:hover { background: #2c3442; }
#tip .sep { color: #45506a; }
#tip { position: fixed; z-index: 9; display: none; max-width: calc(100% - 24px); padding: 6px 9px;
  border-radius: 7px; background: #0d1015; border: 1px solid #45506a; color: #e8ebf0; pointer-events: none;
  font: 12px/1.45 -apple-system, system-ui, sans-serif; white-space: pre-line; box-shadow: 0 4px 14px rgba(0, 0, 0, .5); }
.state { flex: none; font: 600 11px -apple-system, system-ui, sans-serif; padding: 1px 7px; border-radius: 9px; }
.state.work { color: #6f9dff; background: rgba(79, 140, 255, .15); }
.state.wait { color: #f0a24a; background: rgba(240, 162, 74, .15); }
.state.idle { color: #4fbf6f; background: rgba(79, 191, 111, .15); }
.counts .work { color: #6f9dff; } .counts .wait { color: #f0a24a; } .counts .idle { color: #4fbf6f; }
.counts .recent { color: #9aa5b5; }
.nav { margin-left: auto; display: flex; align-items: center; gap: 2px; font-size: 11px; color: #9aa5b5; }
.nav button { background: none; color: #c9d1dc; padding: 0 6px; font-size: 15px; line-height: 18px; }
.nav button:hover { color: #fff; }
h1 { font-size: 15px; margin: 0 0 2px; }
.where { color: #9aa5b5; font-size: 12px; margin-bottom: 6px; }
.foot { display: flex; align-items: center; gap: 8px; margin: 8px -12px -12px; padding: 5px 10px 5px 12px;
  background: #12161d; border-top: 1px solid #2a303c; border-radius: 0 0 12px 12px; }
.sl { flex: 1; min-width: 0; font: 11px/1.5 Menlo, monospace; color: #c9d1dc; }
.sl div { white-space: pre; overflow: hidden; text-overflow: ellipsis; }
.foot .link { flex: none; padding: 4px 0; }
.sl .c { color: #56c2d6; } .sl .g { color: #4fbf6f; } .sl .y { color: #e0b84a; } .sl .r { color: #e06060; }
.grip { position: absolute; left: 4px; top: 4px; width: 8px; height: 8px; cursor: nwse-resize;
  border-top: 2px solid #8d98b0; border-left: 2px solid #8d98b0; border-top-left-radius: 4px; }
body.fixed .b { height: calc(100vh - 6px); display: flex; flex-direction: column; }
body.fixed .detail { flex: 1; max-height: none; overflow-y: auto; }
/* The terminal's scrollbar track is white in this web view: it sits past the clipped edge. */
.tty { flex: 1; min-height: 0; overflow: hidden; border-radius: 6px; background: #12161d; }
.tty iframe { width: calc(100% + 15px); height: 100%; border: 0; }
.top .link { padding: 0 4px; font-size: 12px; }
.path { display: flex; align-items: center; gap: 8px; margin: -2px 0 6px; font: 11px Menlo, monospace; color: #9aa5b5; }
.path span { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.path .link { flex: none; padding: 0 4px; font-size: 12px; }
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
// The session on show: working, waiting for you or done.
function mine(s) {
  const el = document.getElementById("state");
  const m = { working: ["work", "⚙️", WORDS.sWorking], waiting: ["wait", "✋", WORDS.sWaiting], idle: ["idle", "✓", WORDS.sIdle] }[s];
  if (!el) return;
  el.className = m ? "state " + m[0] : "state";
  el.textContent = m ? `${m[1]} ${m[2]}` : "";
  el.dataset.tip = WORDS.state;
}
// Sessions working, waiting for you and done, as an icon and a number each; which ones on hover.
function counts(by) {
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const c = (list, cls, icon, word) => {
    const n = Array.isArray(list) ? list.length : 0;
    if (!n) return "";
    const tip = `${icon} ${n} ${word}`;
    return `<span class="${cls}" data-tip="${esc(tip)}" data-list="${esc(JSON.stringify(list))}">${icon} ${n}</span>`;
  };
  document.getElementById("counts").innerHTML =
    c(by.working, "work", "⚙️", WORDS.working) + c(by.waiting, "wait", "✋", WORDS.waiting) + c(by.idle, "idle", "✓", WORDS.idle)
    + c(by.recent, "recent", "🕘", WORDS.recent);
  size();
}
// The hint under what the pointer is on; Hammerspoon says where the pointer is (-1 when it left).
// A count's hint lists its sessions, each to open in the bubble or in its terminal, and stays while
// the pointer is on it; it overlaps the count a little, so the pointer goes onto it without leaving both.
function hover(x, y) {
  const tip = document.getElementById("tip");
  const hit = x >= 0 && document.elementFromPoint(x, y);
  if (hit && tip.classList.contains("list") && tip.contains(hit)) return;
  const el = hit && hit.closest("[data-tip]");
  const list = el && el.dataset.list && JSON.parse(el.dataset.list);
  tip.classList.toggle("list", !!list);
  if (!el) { tip.style.display = "none"; return; }
  if (list) {
    const go = (s, where, label) => {
      const b = document.createElement("button");
      b.className = "go";
      b.textContent = label;
      b.onclick = () => post({ action: "session", session: s.session, claude: s.claude, where });
      return b;
    };
    // A recent session that ended can only be resumed.
    tip.replaceChildren(el.dataset.tip, ...list.map(s => {
      const row = document.createElement("div"), name = document.createElement("span"), sep = document.createElement("span");
      row.className = "s";
      name.textContent = "• " + s.name + (s.ago ? " · " + s.ago : "");
      sep.className = "sep";
      sep.textContent = "|";
      if (s.live === false) row.append(name, go(s, "resume", WORDS.resume));
      else row.append(name, go(s, "bubble", WORDS.inBubble), sep, go(s, "terminal", WORDS.inTerminal));
      return row;
    }));
  } else tip.textContent = el.dataset.tip;
  tip.style.display = "block";
  const r = el.getBoundingClientRect();
  const top = list ? r.bottom - 2 : r.bottom + 6;
  tip.style.left = Math.max(4, Math.min(r.left, innerWidth - tip.offsetWidth - 16)) + "px";
  tip.style.top = top + "px";
  tip.style.maxHeight = list ? (innerHeight - top - 8) + "px" : "";
}
function size() { post({ action: "size", h: document.querySelector(".b").offsetHeight + 8 }); }
function bind(root) { for (const b of root.querySelectorAll("[data-a]")) b.onclick = () => post({ action: b.dataset.a }); }
// The pager is redrawn on its own, so a new message never wipes what you are typing.
function pager(i, n) {
  const nav = document.getElementById("nav");
  nav.innerHTML = (n > 1 ? `<button data-a="prev" data-tip="${WORDS.prev}">‹</button>${i}/${n}<button data-a="next" data-tip="${WORDS.next}">›</button>` : "")
    + `<button data-a="min" data-tip="${WORDS.minimize}">–</button><button data-a="close" data-tip="${WORDS.close}">×</button>`;
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

-- The session's status line at the foot of the bubble, as Claude Code draws it under its prompt: [model] | 🌿 branch | 🔗 repo, then the
-- context bar, cost and time. Older plugins send no status: just the folder then.
local function statusHTML(req)
  local st = type(req.status) == "table" and req.status
  if not st then return nil end
  local pct = math.max(0, math.min(100, math.floor(tonumber(st.pct) or 0)))
  local color = pct >= 90 and "r" or pct >= 70 and "y" or "g"
  local first = '<span class="c">[' .. esc(st.model) .. "]</span>"
    .. (st.branch and (" | 🌿 " .. esc(st.branch)) or "") .. " | 🔗 " .. esc(st.repo or req.label)
  local second = string.format('<span class="%s">%s%s</span> %d%%', color,
    string.rep("█", pct // 10), string.rep("░", 10 - pct // 10), pct)
    .. (tonumber(st.usd) and string.format(' | <span class="y">$%.2f</span>', st.usd) or "")
    .. (tonumber(st.minutes) and (" | " .. math.floor(st.minutes) .. "m") or "")
    .. (req.seconds and (" | ⏱ " .. req.seconds .. " s") or "")
  return '<div class="sl"><div>' .. first .. "</div><div>" .. second .. "</div></div>"
end

-- The session's repository (named as its status line names it), else its folder, and what it is
-- doing: the top bar says at a glance whose message this is.
local function placeHTML(req)
  local repo = type(req.status) == "table" and type(req.status.repo) == "string" and req.status.repo
  local name = repo or req.label
  if not name or name == "" then return '<span class="state" id="state"></span>' end
  local branch = type(req.status) == "table" and type(req.status.branch) == "string" and ("\n🌿 " .. req.status.branch) or ""
  local title = req.bg and bgName(req.bg) or sessionTitle(req.claude)
  local tip = (repo and "🔗 " or "📁 ") .. name .. (title and ("\n💬 " .. title) or "") .. branch
  return '<span class="repo" data-tip="' .. esc(tip) .. '">' .. (repo and "🔗 " or "📁 ") .. esc(name)
    .. (title and ('<span class="title"> · ' .. esc(title) .. "</span>") or "")
    .. '</span><span class="state" id="state"></span>'
end

-- Your code editor: the app macOS opens a .json file with (its pick for source code as such is
-- usually TextEdit). Asked once, in the background; until then, or with none, Finder opens it.
-- An app is named as Finder names it ("Visual Studio Code", where its own name is "Code").
local function app(id)
  local path = hs.application.pathForBundleID(id) -- "" when it is not installed
  if not path or path == "" then return nil end
  return { id = id, name = path:match("([^/]+)%.app/?$") or hs.application.nameForBundleID(id) or id }
end
local systemEditor
local editorTask = hs.task.new("/usr/bin/osascript", function(_, out)
  local id = out and out:match("^%s*([%w%.%-]+)%s*$")
  systemEditor = id and app(id)
end, { "-l", "JavaScript", "-e", 'ObjC.import("CoreServices"); '
  .. 'ObjC.castRefToObject($.LSCopyDefaultRoleHandlerForContentType($("public.json"), $.kLSRolesAll)).js' })
editorTask:start()

-- The code editors the ▦ menu offers, those installed.
local EDITORS = { "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
  "com.sublimetext.4", "com.vscodium", "com.panic.Nova", "com.macromates.TextMate", "com.apple.dt.Xcode",
  "com.jetbrains.intellij", "com.jetbrains.WebStorm", "com.jetbrains.pycharm" }

-- The one you picked in the ▦ menu (pet.editor), else the system's.
local function editorApp()
  local id = settings().editor
  return id ~= "" and app(id) or systemEditor
end

-- The session's folder under the top bar, with the way to open it in your code editor. Older
-- plugins send no folder: no line then.
local function pathHTML(req)
  if type(req.cwd) ~= "string" or req.cwd == "" then return "" end
  local home = os.getenv("HOME")
  local short = (req.cwd == home or req.cwd:sub(1, #home + 1) == home .. "/") and "~" .. req.cwd:sub(#home + 1) or req.cwd
  local editor = editorApp()
  return '<div class="path"><span data-tip="' .. esc(req.cwd) .. '">📂 ' .. esc(short) .. '</span>'
    .. '<button class="link" data-a="editor">' .. esc(string.format(t("editor"), editor and editor.name or t("editorDefault")))
    .. "</button></div>"
end

-- The bubble as a small web page: the counts and the pager on top, then the message, then what
-- you can do about it, and at the foot the status line with the way to the terminal.
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
      .. '<button class="deny" data-a="deny">' .. esc(t("deny")) .. "</button></div>"
  elseif q then
    local opts = {}
    for i, o in ipairs(q.options or {}) do
      opts[#opts + 1] = string.format('<button class="opt" data-i="%d">%s<small>%s</small></button>', i - 1, esc(o.label), esc(o.description))
    end
    controls = '<div class="col">' .. table.concat(opts) .. "</div>"
      .. '<div class="row"><input id="text" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" placeholder="' .. esc(t("other")) .. '">'
      .. '<button class="send" id="send">' .. esc(t("send")) .. "</button></div>"
  elseif req.kind == "done" then
    controls = '<div class="row"><input id="text" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" placeholder="' .. esc(t("reply")) .. '">'
      .. '<button class="send" id="send">' .. esc(t("send")) .. "</button></div>"
  else
    controls = ""
  end
  local status = statusHTML(req)
  local data = string.format("const Q = %s; const WORDS = %s;", q and hs.json.encode(q) or "null", words())
  return "<!doctype html><html><head><meta charset=\"utf-8\"><style>" .. CSS .. "</style></head>"
    .. (pet and pet.fixedH and '<body class="fixed">' or "<body>")
    .. '<div class="b"><div class="grip"></div><div class="top"><div class="counts" id="counts"></div>' .. placeHTML(req)
    .. '<div class="nav" id="nav"></div></div>' .. pathHTML(req)
    .. "<h1>" .. esc(title) .. "</h1>"
    .. (status and "" or ('<div class="where">' .. esc(where) .. "</div>"))
    .. (detail and detail ~= "" and ('<div class="detail' .. (req.kind == "done" and " answer" or "") .. '">'
      .. esc(detail) .. "</div>") or "")
    .. controls .. '<div class="foot">' .. (status or "") .. go .. '</div></div><div id="tip"></div><script>' .. data:gsub("</", "<\\/") .. JS
    .. string.format("pager(%d, %d); ", index, total) .. countsJS() .. "</script></body></html>"
end

-- The terminal ------------------------------------------------------------------------------

local function stopTerminal()
  if pet and pet.tty then pet.tty.task:terminate(); pet.tty = nil end
end

-- The address of the session's terminal, started if need be; nil for a session in a terminal tab
-- (its screen belongs to that tab) or without ttyd. ttyd listens on the loopback only, under a
-- random path, and talks only to its own page (-O).
local function terminalFor(req)
  if not (TTYD and CLAUDE and req.bg) then return nil end
  if pet.tty and pet.tty.bg == req.bg then return pet.tty.url end
  stopTerminal()
  local port, path = math.random(20000, 40000), hs.host.uuid():gsub("-", "")
  local task = hs.task.new(TTYD, nil, { "-p", tostring(port), "-i", "lo0", "-O", "-W", "-b", "/" .. path,
    "-t", "fontSize=12", "-t", "fontFamily=Menlo", "-t", "disableReconnect=true", "-t", "disableLeaveAlert=true",
    "-t", 'theme={"background":"#12161d","scrollbarSliderBackground":"#3a4150"}', CLAUDE, "attach", req.bg })
  if not task:start() then return nil end
  pet.tty = { task = task, bg = req.bg, url = string.format("http://127.0.0.1:%d/%s/", port, path) }
  return pet.tty.url
end

-- The bubble around the terminal: counts, repository, Go to terminal and the pager on top, the terminal
-- below. The page waits for ttyd to listen before loading it.
local function terminalHTML(url, req, index, total)
  local data = string.format("const Q = null; const WORDS = %s;", words())
  return "<!doctype html><html><head><meta charset=\"utf-8\"><style>" .. CSS .. "</style></head>"
    .. '<body class="fixed"><div class="b"><div class="grip"></div><div class="top"><div class="counts" id="counts"></div>' .. placeHTML(req)
    .. '<button class="link" data-a="go">' .. esc(t("go")) .. '</button><div class="nav" id="nav"></div></div>' .. pathHTML(req)
    .. '<div class="tty"><iframe id="tty"></iframe></div></div><div id="tip"></div><script>' .. data:gsub("</", "<\\/") .. JS
    .. string.format("pager(%d, %d); ", index, total) .. countsJS()
    .. string.format([[(function load(n) {
      fetch(%q, { mode: "no-cors" }).then(() => { document.getElementById("tty").src = %q; })
        .catch(() => { if (n < 40) setTimeout(() => load(n + 1), 150); });
    })(0);]], url, url) .. "</script></body></html>"
end

-- What the bubble shows for a message: the session's terminal when it has one, else the bubble.
-- A question or an approval goes back to that terminal, where the session itself asks it.
local function page(req, index, total)
  local url = terminalFor(req)
  if not url then
    stopTerminal()
    return bubbleHTML(req, index, total)
  end
  if req.wait then answer(req, "terminal"); req.wait = false end
  if not pet.fixedH then pet.fixedH, pet.bw = 460, math.max(pet.bw, 620) end
  return terminalHTML(url, req, index, total)
end

-- Placing and moving -----------------------------------------------------------------------

-- Through the window's own app: hs.window.get(id) asks every app on the Mac for its windows, and
-- one app that does not answer stops Hammerspoon.
local function windowOf(session)
  local entry = windows[session]
  local w = entry and entry.app:getWindow(entry.id)
  if entry and not w and not entry.term then windows[session] = nil end
  return w
end

-- Background sessions (`claude agents`) all share the agent view's window: only a title that
-- carries the session's short id or name is that session.
local function shows(session, w)
  local entry = windows[session]
  if not (entry and w and w:id() == entry.id) then return false end
  if not entry.bg then return true end
  local title, name = w:title() or "", bgName(entry.bg)
  return title:find(entry.bg, 1, true) ~= nil or (name and title:find(name, 1, true) ~= nil)
end

local FRONT = "return id of focused terminal of selected tab of front window"

-- Through osascript in a task: hs.osascript waits on Ghostty on the main thread.
local function ghostty(script, done)
  hs.task.new("/usr/bin/osascript", done and function(code, out) done(code == 0 and out or nil) end,
    { "-e", 'tell application "Ghostty"\n' .. script .. "\nend tell" }):start()
end

-- A recent session that ended opens again in a new Ghostty window: `claude --resume` in its folder.
local function resume(claude)
  for _, r in ipairs(hs.settings.get(RECENT) or {}) do
    if r.claude == claude then
      local cd = r.cwd and ("cd '" .. r.cwd:gsub("'", "'\\''") .. "' && ") or ""
      local line = (cd .. "claude --resume " .. claude):gsub('[\\"]', "\\%0")
      return ghostty('set cfg to new surface configuration\nset initial input of cfg to "' .. line
        .. '" & return\nnew window with configuration cfg\nactivate')
    end
  end
end

local function goTo(req)
  local entry = windows[req.session]
  -- A background session: the terminal showing it (titled with its id or name), else the agent
  -- view you already have open (titled "… claude agents"), else a new window attached to it.
  if req.bg then
    local name = bgName(req.bg) or req.bg
    return ghostty(([[
repeat with term in terminals
  if name of term contains "%s" or name of term contains %s then
    focus term
    activate
    return
  end if
end repeat
repeat with term in terminals
  if name of term ends with "claude agents" then
    focus term
    activate
    return
  end if
end repeat
set cfg to new surface configuration
set initial input of cfg to "claude attach %s" & return
new window with configuration cfg
activate]]):format(req.bg, '"' .. name:gsub('[\\"]', "\\%0") .. '"', req.bg))
  end
  if entry and entry.term then return ghostty(('focus terminal id "%s"\nactivate'):format(entry.term)) end
  local w = windowOf(req.session)
  if w then w:focus() else hs.application.launchOrFocusByBundleID("com.mitchellh.ghostty") end
end

-- Where the pet stands for a message: where you last dropped it on that screen, else the
-- bottom-right corner inside its session's window.
local function spotFor(req)
  local w = windowOf(req.session)
  local screen = w and w:screen() or hs.screen.mainScreen()
  local area, s = w and w:frame() or screen:frame(), screen:frame()
  local mine = (hs.settings.get(SPOT) or {})[screen:getUUID()]
  if mine then area = { x = s.x + mine.x, y = s.y + mine.y, w = pet.size.w + 16, h = pet.size.h + 16 } end
  local x = math.max(s.x + pet.bw + GAP, math.min(area.x + area.w - pet.size.w - 16, s.x + s.w - pet.size.w))
  local y = math.max(s.y, math.min(area.y + area.h - pet.size.h - 16, s.y + s.h - pet.size.h))
  return { x = x, y = y }, s
end

-- The bubble stands to the pet's left, bottoms lined up.
local function placeBubble()
  if not pet.web then return end
  local f = pet.canvas:frame()
  local h = pet.fixedH or pet.webH
  pet.web:frame({ x = f.x - GAP - pet.bw - 12, y = f.y + f.h - h, w = pet.bw + 12, h = h })
end

-- A new walk or a drag ends the run in progress, which would otherwise keep moving the pet.
local function stopRun()
  if pet.runTimer then pet.runTimer:stop() end
  pet.running = false
end

-- The pet trots from where it is to `dest`, slowing down as it arrives; the bubble waits for it.
local function runTo(dest, from, arrive)
  stopRun()
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
  pet.runTimer = hs.timer.doEvery(1 / 30, function()
    local elapsed = hs.timer.secondsSinceEpoch() - start
    local k = math.min(1, elapsed / seconds)
    local eased = 1 - (1 - k) ^ 2
    draw(frame(mood, math.floor(elapsed / SPEED[mood])))
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
  -- With no pet there is nothing to click or drag: the mouse listener rests.
  mouseTap:stop()
  drag, resize = nil, nil
  for _, timer in pairs({ pet.timer, pet.runTimer, pet.leaveTimer }) do timer:stop() end
  stopTerminal()
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
  pet.web:html(page(req, pet.index, #pet.items))
  pet.minimized = false
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
  for i = #queue, 1, -1 do
    if queue[i].session == session then
      if queue[i].wait then answer(queue[i], reply or "terminal") end
      table.remove(queue, i)
    end
  end
  if not pet or pet.leaving then return end
  for i = #pet.items, 1, -1 do
    if pet and pet.items[i] and pet.items[i].session == session then removeAt(i, reply) end
  end
end

-- Calls yes() when you are looking at the session itself: its window, and in Ghostty its very tab
-- (all tabs share one window), else no().
local function inSession(session, w, yes, no)
  local entry = windows[session]
  if not shows(session, w) then return no() end
  if not entry.term then return yes() end
  ghostty(FRONT, function(out)
    if out and out:match("^%s*([%w%-]+)") == entry.term then yes() else no() end
  end)
end

-- Going to a window yourself answers for the pet: the normal prompt is right there. A plain check
-- twice a second, only while the pet is out: hs.window.filter watches every app's windows. A
-- Ghostty session is asked about on every check, as switching tabs keeps the window.
local function checkFocus()
  local w = hs.window.focusedWindow()
  local id = w and w:id()
  if not id then return end
  local changed = id ~= pet.lastFocus
  pet.lastFocus = id
  local shown = {}
  for _, item in ipairs(pet.items) do shown[item.session] = true end
  for session in pairs(shown) do
    if (changed or (windows[session] and windows[session].term)) and shows(session, w) then
      inSession(session, w, function() if pet and not pet.leaving then removeSession(session, "terminal") end end, function() end)
    end
  end
end

-- The bubble's hints: its page cannot see the pointer while the bubble is not active, so it is
-- told where the pointer is, only when it moves.
local function hover()
  if not (pet.web and not pet.minimized and pet.web:isVisible()) then return end
  local m, f = hs.mouse.absolutePosition(), pet.web:frame()
  local over = m.x >= f.x and m.x < f.x + f.w and m.y >= f.y and m.y < f.y + f.h
  local x, y = math.floor(m.x - f.x), math.floor(m.y - f.y)
  local key = over and (x .. "," .. y) or "out"
  if key == pet.hoverKey then return end
  pet.hoverKey = key
  pet.web:evaluateJavaScript(over and string.format("hover(%d, %d)", x, y) or "hover(-1, -1)")
end

local function tick()
  if not pet then return end
  animate()
  hover()
  pet.ticks = pet.ticks + 1
  if pet.ticks % 5 == 0 and not pet.leaving then checkFocus() end
end

local onMessage

local function create(req)
  local p = settings()
  loadPet(p.id)
  local k = SIZES[p.size] or SIZES.m
  pet = { size = { w = math.floor(FW * k), h = math.floor(FH * k) }, items = { req }, index = 1,
    look = p.look, run = p.run, webH = 160 }
  local saved = hs.settings.get(BUBBLE) or {}
  pet.bw, pet.fixedH = saved.w or BW, saved.h
  local dest, screen = spotFor(req)
  local fromLeft = dest.x - screen.x > screen.x + screen.w - dest.x
  local from = { x = fromLeft and math.max(screen.x, dest.x - 380) or math.min(screen.x + screen.w - pet.size.w, dest.x + 380), y = dest.y }
  pet.canvas = hs.canvas.new({ x = (sheet and p.run) and from.x or dest.x, y = dest.y, w = pet.size.w, h = pet.size.h })
  pet.canvas:level(hs.canvas.windowLevels.floating)
  pet.canvas:behavior({ "canJoinAllSpaces", "stationary" })
  pet.canvas:clickActivating(false)
  if sheet then
    pet.canvas:appendElements({ type = "image", image = sheet, imageScaling = "scaleToFit",
      frame = { x = 0, y = 0, w = 8 * pet.size.w, h = 11 * pet.size.h } })
    pet.home = MOOD[req.kind] -- what it plays again after resting; render sets it for later messages
    play(pet.home, true)
  else
    pet.canvas:appendElements(table.unpack(drawnPet(req.kind, pet.size)))
  end
  local focused = hs.window.focusedWindow()
  pet.lastFocus, pet.ticks = focused and focused:id(), 0
  -- 10 ticks a second: the slowest frame lasts 0.24 s and the quickest 0.1 s.
  pet.timer = hs.timer.doEvery(0.1, tick)
  mouseTap:start()
  local uc = hs.webview.usercontent.new("mascota")
  uc:setCallback(function(m) if type(m.body) == "table" then onMessage(m.body) end end)
  -- A link opened in the terminal goes to your browser: in every frame, window.open hands the
  -- address to Hammerspoon (the terminal opens a blank window and sets its address after).
  uc:injectScript({ mainFrame = false, injectionTime = "documentStart", source = [[
    window.open = function (url) {
      const send = u => window.webkit.messageHandlers.mascota.postMessage({ action: "open", url: String(u) });
      if (url) { send(url); return null; }
      return { opener: null, close() {}, location: { set href(u) { send(u); } } };
    };]] })
  pet.web = hs.webview.new({ x = dest.x - GAP - pet.bw - 12, y = dest.y, w = pet.bw + 12, h = pet.fixedH or pet.webH }, {}, uc)
    -- No window of its own for anything: a page asking for one gets your browser instead.
    :policyCallback(function(action, _, nav)
      if action ~= "newWindow" then return true end
      local url = type(nav) == "table" and type(nav.request) == "table" and nav.request.URL
      if type(url) == "string" and url:match("^https?://") then hs.urlevent.openURL(url) end
      return false
    end)
    :windowStyle({ "borderless", "nonactivating" })
    :transparent(true)
    :allowTextEntry(false) -- it cannot take the keyboard from what you are typing until you click it
    :shadow(false)
    :level(hs.drawing.windowLevels.floating)
    :behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  pet.canvas:show(0.2)
  pet.web:html(page(req, 1, 1))
  runTo(dest, from, function()
    placeBubble()
    if pet and pet.web then pet.web:show(0.15) end
  end)
end

-- A new message joins the pet on screen (one per session: a newer one replaces the older) and
-- the bubble keeps showing what you are reading.
local add

-- The pet comes out at a pause in your typing and clicking (1.5 s), so it never jumps in front of
-- what you are writing; after 30 s of non-stop work it comes out anyway.
local function comeOut()
  if hs.host.idleTime() < 1.5 and hs.timer.secondsSinceEpoch() - waitingSince < 30 then return end
  idleTimer:stop()
  local waiting = queue
  queue = {}
  if #waiting == 0 then return end
  create(waiting[1])
  for i = 2, #waiting do add(waiting[i]) end
end

add = function(req)
  if pet and pet.leaving then remove() end
  if not pet then
    queue[#queue + 1] = req
    if idleTimer:running() then return end
    waitingSince = hs.timer.secondsSinceEpoch()
    if hs.host.idleTime() >= 1.5 then return comeOut() end
    idleTimer:start()
    return
  end
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

-- A session's last message again, to read and reply to: an approval or a question it showed was
-- answered already, so it comes back as a plain "I need you in the terminal". A background
-- session with none still opens, as its terminal.
local function lastOf(session)
  local st = status[session]
  local again = st and (st.last and hs.fnutils.copy(st.last) or st.bg and { kind = "done", label = st.label, bg = st.bg })
  if not again then return end
  again.session, again.wait = session, false
  if again.kind ~= "done" then again.kind = "needs" end
  return again
end

onMessage = function(m)
  if not pet or pet.leaving then return end
  local req = pet.items[pet.index]
  if m.action == "size" then
    pet.webH = math.ceil(m.h)
    placeBubble()
    -- The page has loaded: a message that came while it loaded missed the pager, so set it now.
    pet.web:evaluateJavaScript(string.format("pager(%d, %d)", pet.index, #pet.items))
  elseif m.action == "open" then
    if type(m.url) == "string" and m.url:match("^https?://") then hs.urlevent.openURL(m.url) end
  elseif m.action == "min" then
    -- Only the pet stays; a click on it brings the bubble back.
    pet.minimized = true
    pet.web:hide(0.12)
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
  elseif m.action == "session" then
    -- A session picked from a count's list, to open in the bubble or in its terminal, or to resume.
    if m.where == "resume" then return resume(m.claude) end
    local st = type(m.session) == "string" and status[m.session]
    if not st then return end
    if m.where ~= "bubble" then return goTo({ session = m.session, bg = st.bg }) end
    for i, item in ipairs(pet.items) do
      if item.session == m.session then
        pet.index = i
        return render(false)
      end
    end
    local again = lastOf(m.session)
    if again then
      table.insert(pet.items, again)
      pet.index = #pet.items
      return render(false)
    end
    goTo({ session = m.session, bg = st.bg })
  elseif m.action == "editor" then
    if type(req.cwd) == "string" then
      local editor = editorApp()
      hs.task.new("/usr/bin/open", nil, editor and { "-b", editor.id, req.cwd } or { req.cwd }):start()
    end
  elseif m.action == "close" then
    removeAt(pet.index, "terminal")
  else
    removeAt(pet.index, "terminal")
    goTo(req)
  end
end

-- Mouse ------------------------------------------------------------------------------------

local function inside(p, f) return f and p.x >= f.x and p.x < f.x + f.w and p.y >= f.y and p.y < f.y + f.h end

-- Dragging the pet moves it and its bubble, and it stays where you leave it; a click without
-- moving goes to the terminal, or brings a minimized bubble back. A click on the bubble is taken here too: the bubble is a window
-- that is not active, and macOS spends the first click on activating it. So the bubble becomes
-- active (for typing) and the button or box under the pointer is pressed or focused at once.
local function onMouse(e)
  if not pet then return false end
  -- Hammerspoon's own click (the one passed into the terminal below) goes through as is: taken
  -- again while the bubble is not active, it would click again and again, the pointer held there.
  if e:getProperty(hs.eventtap.event.properties.eventSourceUnixProcessID) == hs.processInfo.processID then return false end
  local types = hs.eventtap.event.types
  local kind, p = e:getType(), e:location()
  if kind == types.leftMouseDown and inside(p, pet.canvas:frame()) then
    if pet.running then stopRun(); if pet.web and not pet.minimized then placeBubble(); pet.web:show() end end
    drag = { from = p, at = pet.canvas:topLeft(), moved = false }
    return true
  end
  -- Only the pet moves while dragged: the bubble hides and comes back where you let go.
  if drag and kind == types.leftMouseDragged then
    local dx, dy = p.x - drag.from.x, p.y - drag.from.y
    if not drag.moved and math.abs(dx) + math.abs(dy) > 3 then
      drag.moved = true
      if pet.web then pet.web:hide() end
    end
    if drag.moved then pet.canvas:topLeft({ x = drag.at.x + dx, y = drag.at.y + dy }) end
    return true
  end
  if drag and kind == types.leftMouseUp then
    local moved = drag.moved
    drag = nil
    if moved then
      pet.dragged = true
      -- Remembered for this screen: the next pets come here instead of to their window.
      local screen, at = hs.mouse.getCurrentScreen(), pet.canvas:topLeft()
      local spots = hs.settings.get(SPOT) or {}
      spots[screen:getUUID()] = { x = at.x - screen:frame().x, y = at.y - screen:frame().y }
      hs.settings.set(SPOT, spots)
      if pet.web and not pet.minimized then placeBubble(); pet.web:show() end
    elseif pet.minimized and pet.web then
      pet.minimized = false
      placeBubble()
      pet.web:show(0.12)
    else
      hs.timer.doAfter(0, function() onMessage({ action = "go" }) end)
    end
    return true
  end
  -- The bubble's top-left corner resizes it (the pet and the bottom-right stay put); the size is
  -- kept for the next bubbles. It grows as far as the screen's left and top edges.
  if resize and kind == types.leftMouseDragged then
    local f, s = pet.canvas:frame(), hs.mouse.getCurrentScreen():frame()
    pet.bw = math.max(260, math.min(f.x - GAP - 12 - s.x, resize.w + resize.from.x - p.x))
    pet.fixedH = math.max(120, math.min(f.y + f.h - s.y, resize.h + resize.from.y - p.y))
    placeBubble()
    return true
  end
  if resize and kind == types.leftMouseUp then
    resize = nil
    hs.settings.set(BUBBLE, { w = pet.bw, h = pet.fixedH })
    return true
  end
  local f = kind == types.leftMouseDown and pet.web and pet.web:isVisible() and pet.web:frame()
  if not inside(p, f) then return false end
  if p.x - f.x < 18 and p.y - f.y < 18 then
    resize = { from = p, w = pet.bw, h = pet.fixedH or pet.webH }
    pet.fixedH = resize.h
    pet.web:evaluateJavaScript("document.body.classList.add('fixed')")
    return true
  end
  local win = pet.web:hswindow()
  if win and hs.window.focusedWindow() == win then return false end -- active already: a normal click
  local x, y = math.floor(p.x - f.x), math.floor(p.y - f.y)
  hs.timer.doAfter(0, function()
    if not (pet and pet.web) then return end
    pet.web:allowTextEntry(true)
    local win = pet.web:hswindow()
    if win and hs.window.focusedWindow() ~= win then
      pet.back = hs.window.focusedWindow()
      win:focus()
    end
    -- The terminal takes its keyboard only from a real click of its own (the page cannot click
    -- into it): once the bubble is active, the same click again, which now passes through.
    pet.web:evaluateJavaScript(string.format([[(() => {
      const el = document.elementFromPoint(%d, %d);
      const target = el && el.closest("button, input");
      if (target && target.tagName === "INPUT") target.focus(); else if (target) target.click();
      return el && el.tagName === "IFRAME";
    })()]], x, y), function(inTerminal)
      if inTerminal == true then hs.timer.doAfter(0.05, function() if pet and pet.web then hs.eventtap.leftClick(p) end end) end
    end)
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

-- For the ▦ menu: the system's editor (its name, or nil) and the installed editors, { id, name }.
function M.editors()
  local list = {}
  for _, id in ipairs(EDITORS) do list[#list + 1] = app(id) end
  return systemEditor and systemEditor.name, list
end

function M.toggle()
  local p = settings()
  p.enabled = not p.enabled
  require("zonas").save()
  if not p.enabled and pet then
    while pet and not pet.leaving do removeAt(#pet.items, "terminal") end
  end
end

-- From the ▦ menu: the pet comes back after you closed it, with each session's last message,
-- newest first; on screen but minimized, its bubble opens again.
function M.summon()
  if pet and not pet.leaving then
    if pet.minimized then render(false) end
    return
  end
  local sessions = {}
  for session, st in pairs(status) do sessions[#sessions + 1] = { session = session, at = st.at } end
  table.sort(sessions, function(a, b) return a.at > b.at end)
  local items = {}
  for _, s in ipairs(sessions) do items[#items + 1] = lastOf(s.session) end
  if #items == 0 then return hs.alert.show(t("nobody")) end
  if pet then remove() end
  -- Messages waiting for a pause in your typing join this pet instead of bringing a second one.
  idleTimer:stop()
  local waiting = queue
  queue = {}
  create(items[1])
  for i = 2, #items do table.insert(pet.items, items[i]) end
  for _, req in ipairs(waiting) do add(req) end
end

local function handle(req)
  remember(req)
  if req.kind == "end" then
    removeSession(req.session, "terminal")
    windows[req.session] = nil
    return setStatus(req.session, nil)
  end
  setStatus(req.session, STATE[req.kind], req)
  if req.kind == "working" then return end
  if req.kind == "bind" then
    local w = hs.window.focusedWindow()
    local app = w and w:application()
    if app and TERMINALS[app:bundleID()] then
      local entry = { app = app, id = w:id(), bg = req.bg }
      windows[req.session] = entry
      -- Ghostty's tabs and splits: remember the very terminal you typed in.
      if app:bundleID() == "com.mitchellh.ghostty" and not req.bg then
        ghostty(FRONT, function(out)
          entry.term = out and out:match("^%s*([%w%-]+)")
        end)
      end
    end
    return removeSession(req.session, "terminal")
  end
  local p = settings()
  local wanted = p.enabled and p.events[EVENT[req.kind]]
  -- Switched off, not wanted for this event, or you are already in that tab: no pet. The
  -- settings come first: asking windows can wait on a slow app.
  if not wanted then
    if req.wait then answer(req, "terminal") end
    return
  end
  inSession(req.session, hs.window.focusedWindow(), function()
    if req.wait then answer(req, "terminal") end
  end, function() add(req) end)
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
      and type(req.id) == "string" and req.id:match("^[%w%-]+$")
      and (req.bg == nil or (type(req.bg) == "string" and req.bg:match("^%w+$"))) then handle(req) end
  end
end

-- For checking from the hs command line: the pet on screen, or nil.
function M.current() return pet end

-- Shows a message without the plugin, to see how it looks: require("mascota").demo("question"); with
-- a background session's short id as second argument, its terminal.
function M.demo(kind, bg)
  kind = kind or "done"
  add({ kind = kind, session = "demo-" .. kind, id = "demo-" .. kind, label = "demo", tool = "Bash", bg = bg,
    detail = "git push origin feature/mascota", text = "This is how a finished session looks.", seconds = 42,
    status = { model = "Opus 5.5", branch = "main", repo = "hammerspoon-zonas", pct = 34, usd = 1.27, minutes = 18 },
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
  -- A reload leaves the terminals of the pet it replaced running.
  hs.task.new("/usr/bin/pkill", nil, { "-9", "-f", "ttyd -p [0-9]* -i lo0 -O -W -b /" }):start()
  watcher = hs.pathwatcher.new(INBOX, poll):start()
  idleTimer = hs.timer.new(0.5, comeOut)
  local types = hs.eventtap.event.types
  -- Every click on the Mac passes through this listener, so it runs only while the pet is out.
  mouseTap = hs.eventtap.new({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp }, onMouse)
  -- macOS turns off a mouse listener that answered too slowly once; turn it back on.
  tapGuard = hs.timer.doEvery(3, function() if pet and not mouseTap:isEnabled() then drag = nil; mouseTap:start() end end)
  syncJobs()
  jobTimer = hs.timer.doEvery(5, syncJobs)
end

return M
