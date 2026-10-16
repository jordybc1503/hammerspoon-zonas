-- Window zones, their shortcuts, the ▦ menu and the editor (zonas.html). Changes made in the
-- editor are saved to zonas.json; without that file, DEFAULTS apply.
local M = {}

local DIR = os.getenv("HOME") .. "/.hammerspoon/"
local FILE = DIR .. "zonas.json"

-- A layout is a tree: a leaf is a zone; a node splits its space into children, side by side
-- ("h") or stacked ("v"). sizes are fractions of the node and add up to 1.
local function leaf(key) return { key = key } end
local function split(dir, sizes, children) return { dir = dir, sizes = sizes, children = children } end

local TEMPLATES = {
  { id = "centro34", name = { es = 'Centro 34"', en = 'Center 34"' },
    root = split("h", { 1 / 6, 2 / 9, 2 / 9, 2 / 9, 1 / 6 },
      { leaf("left"), leaf("1"), leaf("2"), leaf("3"), leaf("right") }) },
  -- Floating zone 4: a 16:9 24" monitor (95 % of the height), at the bottom. A 16:9 29" does not fit: the Dell is 34 cm tall.
  { id = "centro34-lectura", name = { es = 'Centro 34" + lectura 24"', en = 'Center 34" + 24" reading' },
    root = split("h", { 1 / 6, 2 / 9, 2 / 9, 2 / 9, 1 / 6 },
      { leaf("left"), leaf("1"), leaf("2"), leaf("3"), leaf("right") }),
    floats = { { x = 0.2771, y = 0.05, w = 0.4459, h = 0.95, key = "4" } } },
  { id = "mitades", name = { es = "Mitades", en = "Halves" },
    root = split("h", { 1 / 2, 1 / 2 }, { leaf("1"), leaf("2") }) },
  { id = "tercios", name = { es = "Tercios", en = "Thirds" },
    root = split("h", { 1 / 3, 1 / 3, 1 / 3 }, { leaf("1"), leaf("2"), leaf("3") }) },
  { id = "cuadricula", name = { es = "Cuadrícula 2 × 2", en = "Grid 2 × 2" },
    root = split("h", { 1 / 2, 1 / 2 }, {
      split("v", { 1 / 2, 1 / 2 }, { leaf("1"), leaf("3") }),
      split("v", { 1 / 2, 1 / 2 }, { leaf("2"), leaf("4") }) }) },
}

local DEFAULTS = {
  lang = "auto", gap = 0, active = "centro34", layouts = {}, screens = {},
  keys = { mods = { "ctrl", "alt" }, full = "return", drag = "shift", merge = "ctrl",
    translate = { mods = { "cmd", "alt" }, key = "t" } },
  -- The Claude Code pet (mascota.lua). id "" is the first Codex pet found, "drawn" the stand-in.
  pet = { enabled = true, id = "", size = "m", look = true, run = true,
    events = { done = true, question = true, needs = true } },
}

local STR = {
  es = {
    layout = "%s · %s", zone = "Zona %d", full = "Pantalla completa",
    drag = "%s + arrastrar     Soltar la ventana en una zona", merge = "+ %s     Unir varias zonas",
    switch = "Diseño por pantalla", edit = "Editar zonas y atajos…",
    translate = "Traducir la palabra seleccionada", guide = "Ver la guía completa",
    reload = "Recargar configuración", console = "Consola de Hammerspoon",
    prefs = "Preferencias de Hammerspoon", title = "Zonas y atajos",
    ready = "Atajos listos · menú ▦ arriba", notInDict = "No está en el diccionario.",
    noSel = "Sin selección", noSelBody = "Selecciona una palabra y vuelve a pulsar %s.",
    floating = "Zona flotante", pet = "%s: avisos de Claude Code", petDefault = "Mascota",
  },
  en = {
    layout = "%s · %s", zone = "Zone %d", full = "Full screen",
    drag = "%s + drag     Drop the window on a zone", merge = "+ %s     Span several zones",
    switch = "Layout per screen", edit = "Edit zones and shortcuts…",
    translate = "Translate the selected word", guide = "Open the full guide",
    reload = "Reload configuration", console = "Hammerspoon console",
    prefs = "Hammerspoon preferences", title = "Zones and shortcuts",
    ready = "Shortcuts ready · ▦ menu at the top", notInDict = "Not in the dictionary.",
    noSel = "Nothing selected", noSelBody = "Select a word and press %s again.",
    floating = "Floating zone", pet = "%s: Claude Code alerts", petDefault = "Pet",
  },
}

local MOD_ORDER = { "ctrl", "alt", "shift", "cmd" }
local MOD = { ctrl = "⌃", alt = "⌥", shift = "⇧", cmd = "⌘" }
local KEYLABEL = { left = "←", right = "→", up = "↑", down = "↓", ["return"] = "↩", space = "␣", tab = "⇥" }
local FULL = { x = 0, y = 0, w = 1, h = 1 }

local saved, actions, editor, menu, dragTap, screenWatcher
local hotkeys = {}

local function clone(t) return hs.json.decode(hs.json.encode(t)) end

local function systemLang()
  local sys = ((hs.host.locale.preferredLanguages() or {})[1] or "en"):sub(1, 2)
  return STR[sys] and sys or "en"
end

local function lang() return STR[saved.lang] and saved.lang or systemLang() end

function M.t(k, ...)
  local s = STR[lang()][k] or STR.en[k]
  return select("#", ...) > 0 and string.format(s, ...) or s
end

local function nameOf(l) return type(l.name) == "table" and (l.name[lang()] or l.name.en) or l.name end

local function combo(mods, key)
  local s = ""
  for _, m in ipairs(MOD_ORDER) do
    if hs.fnutils.contains(mods, m) then s = s .. MOD[m] end
  end
  return s .. (KEYLABEL[key] or key:upper())
end

function M.translateCombo() return combo(saved.keys.translate.mods, saved.keys.translate.key) end

-- Data from the editor or zonas.json is checked before use: a key Hammerspoon does not know
-- makes hs.hotkey.bind fail, and the whole config with it.
local function validKey(k) return k == "" or (type(k) == "string" and hs.keycodes.map[k] ~= nil) end

local function validMods(m)
  if type(m) ~= "table" then return false end
  for _, x in ipairs(m) do
    if not MOD[x] then return false end
  end
  return true
end

local function validNode(n, depth)
  if type(n) ~= "table" or depth > 10 then return false end
  if n.children == nil then return n.key == nil or validKey(n.key) end
  if (n.dir ~= "h" and n.dir ~= "v") or type(n.sizes) ~= "table" or type(n.children) ~= "table"
    or #n.children == 0 or #n.sizes ~= #n.children then return false end
  for i, c in ipairs(n.children) do
    if type(n.sizes[i]) ~= "number" or n.sizes[i] <= 0 or not validNode(c, depth + 1) then return false end
  end
  return true
end

-- Floating zones: free rectangles (fractions of the screen) on top of the others.
local function validFloats(fs)
  if fs == nil then return true end
  if type(fs) ~= "table" then return false end
  for _, f in ipairs(fs) do
    for _, k in ipairs({ "x", "y", "w", "h" }) do
      if type(f[k]) ~= "number" or f[k] < 0 or f[k] > 1 then return false end
    end
    if f.w <= 0 or f.h <= 0 or not (f.key == nil or validKey(f.key)) then return false end
  end
  return true
end

local function valid(d)
  if type(d) ~= "table" or type(d.active) ~= "string" or type(d.keys) ~= "table" then return false end
  local k = d.keys
  if not validMods(k.mods) or #k.mods == 0 or not validKey(k.full) then return false end
  if not MOD[k.drag] or not MOD[k.merge] or k.drag == k.merge then return false end
  if type(k.translate) ~= "table" or not validMods(k.translate.mods) or not validKey(k.translate.key) then return false end
  if type(d.gap) ~= "number" or d.gap < 0 or d.gap > 100 then return false end
  if d.lang ~= "auto" and not STR[d.lang] then return false end
  if d.screens ~= nil then
    if type(d.screens) ~= "table" then return false end
    for name, id in pairs(d.screens) do
      if type(name) ~= "string" or type(id) ~= "string" then return false end
    end
  end
  local p = d.pet
  if type(p) ~= "table" or type(p.id) ~= "string" or not ({ s = true, m = true, l = true })[p.size]
    or type(p.events) ~= "table" then return false end
  for _, v in ipairs({ p.enabled, p.look, p.run, p.events.done, p.events.question, p.events.needs }) do
    if type(v) ~= "boolean" then return false end
  end
  for _, l in ipairs(d.layouts or {}) do
    if type(l.id) ~= "string" or type(l.name) ~= "string" or not validNode(l.root, 1)
      or not validFloats(l.floats) then return false end
  end
  return true
end

local function load()
  local d = hs.fs.attributes(FILE) and hs.json.read(FILE)
  if type(d) ~= "table" then return clone(DEFAULTS) end
  for k, v in pairs(DEFAULTS) do
    if d[k] == nil then d[k] = clone({ v })[1] end
  end
  for _, part in ipairs({ "keys", "pet" }) do
    if type(d[part]) == "table" then
      for k, v in pairs(DEFAULTS[part]) do
        if d[part][k] == nil then d[part][k] = clone({ v })[1] end
      end
    end
  end
  if type(d.pet) == "table" and type(d.pet.events) == "table" then
    for k, v in pairs(DEFAULTS.pet.events) do
      if d.pet.events[k] == nil then d.pet.events[k] = v end
    end
  end
  return valid(d) and d or clone(DEFAULTS)
end

local function allLayouts()
  local all = hs.fnutils.copy(TEMPLATES)
  for _, l in ipairs(saved.layouts or {}) do all[#all + 1] = l end
  return all
end

local function isWide(screen)
  local f = screen:fullFrame()
  return f.w / f.h >= 2.2
end

-- Each screen has its own layout (saved.screens, by name). A screen with none yet uses
-- saved.active if it is ultrawide, and Halves if not.
local function layoutFor(screen)
  local id = (saved.screens or {})[screen:name()] or (isWide(screen) and saved.active or "mitades")
  return hs.fnutils.find(allLayouts(), function(l) return l.id == id end) or TEMPLATES[1]
end

local function flatten(n, x, y, w, h, out)
  if not n.children then
    out[#out + 1] = { x = x, y = y, w = w, h = h, key = n.key or "" }
    return out
  end
  local pos = 0
  for i, child in ipairs(n.children) do
    local s = n.sizes[i]
    if n.dir == "h" then flatten(child, x + w * pos, y, w * s, h, out)
    else flatten(child, x, y + h * pos, w, h * s, out) end
    pos = pos + s
  end
  return out
end

-- Floating zones go last, so they win when looking up the zone under the mouse.
local function zonesFor(screen)
  local layout = layoutFor(screen)
  local zones = flatten(layout.root, 0, 0, 1, 1, {})
  for _, f in ipairs(layout.floats or {}) do
    zones[#zones + 1] = { x = f.x, y = f.y, w = f.w, h = f.h, key = f.key or "", float = true }
  end
  return zones
end

-- The gap between zones also applies at the screen edges, as in FancyZones.
local function frameOf(screen, z)
  local f, g = screen:frame(), saved.gap
  local x, y, w, h = f.x + g / 2, f.y + g / 2, f.w - g, f.h - g
  return { x = x + w * z.x + g / 2, y = y + h * z.y + g / 2, w = w * z.w - g, h = h * z.h - g }
end

local function place(win, z) win:setFrame(frameOf(win:screen(), z), 0) end

local function moveTo(z)
  local win = hs.window.focusedWindow()
  if win then place(win, z) end
end

local function bind(mods, key, fn)
  if key ~= "" then hotkeys[#hotkeys + 1] = hs.hotkey.bind(mods, key, fn) end
end

-- A zone key looks up its zone in the layout of the window's screen.
local function moveToKey(key)
  local win = hs.window.focusedWindow()
  if not win then return end
  local z = hs.fnutils.find(zonesFor(win:screen()), function(q) return q.key == key end)
  if z then place(win, z) end
end

-- Runs again when a screen is connected or removed.
local function apply()
  for _, hk in ipairs(hotkeys) do hk:delete() end
  hotkeys = {}
  local k, keys = saved.keys, {}
  for _, screen in ipairs(hs.screen.allScreens()) do
    for _, z in ipairs(zonesFor(screen)) do
      if z.key ~= "" then keys[z.key] = true end
    end
  end
  for key in pairs(keys) do bind(k.mods, key, function() moveToKey(key) end) end
  bind(k.mods, k.full, function() moveTo(FULL) end)
  if actions.translate then bind(k.translate.mods, k.translate.key, actions.translate) end
end

local function save()
  hs.json.write(saved, FILE, true, true)
  apply()
end

-- While the editor records a shortcut, ours are off so the key reaches the editor.
local function pause(on)
  for _, hk in ipairs(hotkeys) do
    if on then hk:disable() else hk:enable() end
  end
end

-- Drag to a zone -------------------------------------------------------------------------

local drag = {}

local function zoneAt(zones, screen, p)
  local f = screen:frame()
  local fx, fy = (p.x - f.x) / f.w, (p.y - f.y) / f.h
  for i = #zones, 1, -1 do
    local z = zones[i]
    if fx >= z.x and fx < z.x + z.w and fy >= z.y and fy < z.y + z.h then return i end
  end
end

-- Spans two zones like FancyZones: the rectangle that covers both, grown until it cuts none.
local function span(zones, a, b)
  local A, B = zones[a], zones[b]
  if A.float or B.float then return B, { [b] = true } end
  local x1, y1 = math.min(A.x, B.x), math.min(A.y, B.y)
  local x2, y2 = math.max(A.x + A.w, B.x + B.w), math.max(A.y + A.h, B.y + B.h)
  local picked, grew = {}, true
  while grew do
    grew = false
    for i, z in ipairs(zones) do
      if not picked[i] and not z.float and z.x < x2 - 1e-6 and z.x + z.w > x1 + 1e-6 and z.y < y2 - 1e-6 and z.y + z.h > y1 + 1e-6 then
        picked[i], grew = true, true
        x1, y1 = math.min(x1, z.x), math.min(y1, z.y)
        x2, y2 = math.max(x2, z.x + z.w), math.max(y2, z.y + z.h)
      end
    end
  end
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }, picked
end

local function hideZones()
  if drag.overlay then drag.overlay:delete() end
  drag.overlay, drag.zone, drag.anchor = nil, nil, nil
end

local function showZones(screen, picked)
  local f = screen:frame()
  if not drag.overlay then
    drag.overlay = hs.canvas.new(f):level(hs.canvas.windowLevels.overlay)
    for _, z in ipairs(drag.zones) do
      local r = frameOf(screen, z)
      drag.overlay:appendElements({ type = "rectangle", action = "strokeAndFill",
        frame = { x = r.x - f.x + 4, y = r.y - f.y + 4, w = r.w - 8, h = r.h - 8 },
        roundedRectRadii = { xRadius = 12, yRadius = 12 },
        strokeColor = { hex = z.float and "#e08a1e" or "#2f5fd0", alpha = 0.95 }, strokeWidth = 4,
        strokeDashPattern = z.float and { 14, 8 } or nil })
    end
    drag.overlay:show()
  end
  for i, z in ipairs(drag.zones) do
    drag.overlay[i].fillColor = { hex = z.float and "#e08a1e" or "#2f5fd0", alpha = picked[i] and 0.35 or 0.06 }
  end
end

-- The window under the mouse, not the focused one: ⌘ + drag moves a background window.
local function windowAt(p)
  local point = hs.geometry.point(p.x, p.y)
  for _, w in ipairs(hs.window.orderedWindows()) do
    if w:isStandard() and point:inside(w:frame()) then return w end
  end
end

local function onDrag(e)
  local types = hs.eventtap.event.types
  if e:getType() == types.leftMouseUp then
    local win, z = drag.win, drag.zone
    hideZones()
    drag = {}
    -- Wait for macOS to finish the drop before placing the window.
    if win and z then hs.timer.doAfter(0.05, function() place(win, z) end) end
    return false
  end
  local flags = e:getFlags()
  if not flags[saved.keys.drag] then hideZones(); return false end
  local mouse = hs.mouse.absolutePosition()
  if not drag.win then
    drag.win = windowAt(mouse)
    drag.start = drag.win and drag.win:topLeft()
    return false
  end
  -- Only if the window moves: Shift + drag also selects text.
  local p = drag.win:topLeft()
  if p.x == drag.start.x and p.y == drag.start.y then return false end
  -- On another screen, show that screen's zones, from its own layout.
  local screen = hs.mouse.getCurrentScreen()
  if drag.screen ~= screen then
    hideZones()
    drag.screen, drag.zones = screen, zonesFor(screen)
  end
  local cur = zoneAt(drag.zones, screen, mouse)
  if not cur then return false end
  if flags[saved.keys.merge] then drag.anchor = drag.anchor or cur else drag.anchor = nil end
  local picked
  drag.zone, picked = span(drag.zones, drag.anchor or cur, cur)
  showZones(screen, picked)
  return false
end

-- Editor --------------------------------------------------------------------------------

local function openEditor()
  if editor then editor:show():bringToFront(true); hs.focus(); return end
  local uc = hs.webview.usercontent.new("zonas")
  uc:setCallback(function(msg)
    local b = msg.body
    if b.type == "record" then return pause(b.on) end
    if b.type == "demo" then return require("mascota").demo(b.kind) end
    if b.type == "save" then
      if not valid(b.data) then return editor:evaluateJavaScript("saved(false)") end
      saved = b.data
      save()
      editor:evaluateJavaScript("saved(true)")
    end
  end)
  local s = hs.screen.mainScreen():frame()
  -- Connected screens, plus remembered ones that are not connected now (a closed laptop).
  local screens, seen = {}, {}
  for _, sc in ipairs(hs.screen.allScreens()) do
    local f = sc:frame()
    screens[#screens + 1] = { name = sc:name(), w = f.w, h = f.h, wide = isWide(sc) }
    seen[sc:name()] = true
  end
  for name in pairs(saved.screens or {}) do
    if not seen[name] then screens[#screens + 1] = { name = name } end
  end
  local init = hs.json.encode({ templates = TEMPLATES, saved = saved, defaults = DEFAULTS,
    screen = { w = s.w, h = s.h }, screens = screens, sysLang = systemLang(),
    pets = require("mascota").pets() })
  local file = io.open(DIR .. "zonas.html")
  local html = file:read("a")
  file:close()
  editor = hs.webview.new({ x = s.x + (s.w - 1000) / 2, y = s.y + 70, w = 1000, h = 700 }, {}, uc)
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :windowTitle(M.t("title"))
    :allowTextEntry(true)
    :deleteOnClose(true)
    :windowCallback(function(action) if action == "closing" then editor = nil; pause(false) end end)
    :html((html:gsub("__INIT__", function() return init end)))
    :show()
  editor:bringToFront(true)
  hs.focus()
end

-- ▦ menu ---------------------------------------------------------------------------------

-- It replaces the Hammerspoon icon, so it carries its options too.
-- The zones listed are those of the focused window's screen, the window that will move.
local function menuItems()
  local k = saved.keys
  local win = hs.window.focusedWindow()
  local screen = win and win:screen() or hs.screen.mainScreen()
  local items = { { title = M.t("layout", screen:name(), nameOf(layoutFor(screen))), disabled = true } }
  for i, z in ipairs(zonesFor(screen)) do
    local key = z.key ~= "" and combo(k.mods, z.key) or "—"
    items[#items + 1] = { title = string.format("%s     %s · %d × %d %%", key,
      z.float and M.t("floating") or M.t("zone", i), math.floor(z.w * 100 + 0.5), math.floor(z.h * 100 + 0.5)),
      fn = function() moveTo(z) end }
  end
  local perScreen = {}
  for _, s in ipairs(hs.screen.allScreens()) do
    local current, choices = layoutFor(s), {}
    for _, l in ipairs(allLayouts()) do
      choices[#choices + 1] = { title = nameOf(l), checked = l.id == current.id,
        fn = function() saved.screens = saved.screens or {}; saved.screens[s:name()] = l.id; save() end }
    end
    perScreen[#perScreen + 1] = { title = s:name() .. " · " .. nameOf(current), menu = choices }
  end
  for _, item in ipairs({
    { title = (k.full ~= "" and combo(k.mods, k.full) or "—") .. "     " .. M.t("full"), fn = function() moveTo(FULL) end },
    { title = M.t("drag", MOD[k.drag]), disabled = true },
    { title = M.t("merge", MOD[k.merge]), disabled = true },
    { title = "-" },
    { title = M.t("switch"), menu = perScreen },
    { title = M.t("edit"), fn = openEditor },
    { title = "-" },
    { title = M.translateCombo() .. "     " .. M.t("translate"), disabled = true },
    { title = M.t("pet", require("mascota").name() or M.t("petDefault")), checked = require("mascota").enabled(),
      fn = function() require("mascota").toggle() end },
    { title = "-" },
    { title = M.t("guide"), fn = function() hs.urlevent.openURL("https://github.com/jordybc1503/hammerspoon-zonas#readme") end },
    { title = M.t("reload"), fn = hs.reload },
    { title = M.t("console"), fn = hs.openConsole },
    { title = M.t("prefs"), fn = hs.openPreferences },
  }) do items[#items + 1] = item end
  return items
end

-- actions.translate: the translator function, so its shortcut is configured here too.
function M.start(acts)
  actions = acts or {}
  apply()
  local types = hs.eventtap.event.types
  dragTap = hs.eventtap.new({ types.leftMouseDragged, types.leftMouseUp }, onDrag):start()
  screenWatcher = hs.screen.watcher.new(apply):start()
  menu = hs.menubar.new():setTitle("▦"):setTooltip(M.t("title")):setMenu(menuItems)
  hs.menuIcon(false)
end

saved = load()
M.openEditor = openEditor
M.lang = lang
M.pet = function() return saved.pet end
-- The pet's counts next to the ▦ icon: sessions working and waiting for you.
M.badge = function(text) if menu then menu:setTitle("▦" .. (text or "")) end end
M.save = save
return M
