-- Значки угла на странице дневника (спека 2026-11-19-corner-icons, план — Task 2): слой угла кладётся в холст при
-- показе без push, раз в минуту перерисовывается только прямоугольник угла (объединение старого и нового), перо
-- откладывает тик, сон снимает его, пробуждение показывает угол заново; карты и страницы состояния угол не касается.
-- Стенд — как async_answer_spec.lua (заглушки KOReader, часы, timeline), но холст и слои — настоящие буферы W × H
-- байт, виджет собирается настоящим Diary.init.
local t = require("t")
local ffi = require("ffi")

local clock, timeline, LOG = 0, {}, {}

local function stub(name, mod) package.preload[name] = function() return mod end end

local nop = function() end
local W, H = 758, 1024

-- буфер w × h байт, белый: fill, paintRect и colorblitFrom (глиф — сплошная тушь) с обрезкой по краям, free
local function buf(w, h)
  local data = ffi.new("uint8_t[?]", w * h)
  ffi.fill(data, w * h, 0xFF)
  local function rect(x, y, rw, rh, c)
    for yy = math.max(0, y), math.min(h, y + rh) - 1 do
      for xx = math.max(0, x), math.min(w, x + rw) - 1 do data[yy * w + xx] = c end
    end
  end
  return { data = data, stride = w, getWidth = function() return w end, getHeight = function() return h end,
           fill = function(_, c) ffi.fill(data, w * h, c) end, free = nop,
           paintRect = function(_, x, y, rw, rh, c) rect(x, y, rw, rh, c) end,
           colorblitFrom = function(_, src, x, y, _, _, rw, rh, c) rect(x, y, rw, rh, c) end }
end

-- глиф: 8 × 14 сплошной туши над базовой линией; пробел — пустой
local GLYPH = { ax = 10, l = 0, t = 14, bb = { getWidth = function() return 8 end, getHeight = function() return 14 end } }
local SPACE = { ax = 10, l = 0, t = 0, bb = { getWidth = function() return 0 end, getHeight = function() return 0 end } }

stub("ffi/blitbuffer", { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, TYPE_BB8 = 1, new = function(w, h) return buf(w, h) end })
stub("device", { isKindle = function() return false end,
                 screen = { getWidth = function() return W end, getHeight = function() return H end } })
stub("ffi/freetype", { newFaceSize = function()
  return { getHeightAndAscender = function() return 26, 16 end }
end })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/rendertext", { getGlyph = function(_, _, cp) return cp == 32 and SPACE or GLYPH end })
stub("ui/uimanager", {
  scheduleIn = function(_, s, fn) timeline[#timeline + 1] = { at = clock + s, fn = fn } end,
  unschedule = function(_, fn)
    for i = #timeline, 1, -1 do if timeline[i].fn == fn then table.remove(timeline, i) end end
  end,
  nextTick = function(self, fn) self:scheduleIn(0, fn) end,
  setDirty = nop, close = nop,
})
stub("ui/widget/widget", { extend = function(_, o) return o end })
stub("logger", {
  info = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOG[#LOG + 1] = table.concat(parts, " ")
  end,
  warn = nop, err = nop, dbg = nop,
})
stub("ui/time", { monotonic = function() return clock end, to_ms = function(x) return x * 1000 end,
                  to_us = function(x) return x * 1e6 end, to_s = function(x) return x end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop, mkdir = nop })

local Diary = require("riddle_diarywidget")
local CFG = Diary.CFG

local function run(s)
  local stop = clock + s
  while true do
    local k
    for i, task in ipairs(timeline) do
      if task.at <= stop and (not k or task.at < timeline[k].at) then k = i end
    end
    if not k then break end
    local task = table.remove(timeline, k)
    clock = task.at
    task.fn()
  end
  clock = stop
end

local function count(needle)
  local n = 0
  for _, line in ipairs(LOG) do if line:find(needle, 1, true) then n = n + 1 end end
  return n
end

-- управляемые источники угла: TM — часы (время открытия, дальше идут вместе с clock), PW — заряд, NET — связь
local TM, PW, NET

-- настоящий Diary.init на стенде; d.pushes — { x, y, w, h, mode } каждого обновления экрана
local function open_diary(opts)
  clock, timeline, LOG = 0, {}, {}
  Diary.map_kept = nil
  TM = { hour = 21, min = 40, sec = 0 }
  PW = { pct = 87, charging = false }
  NET = "up"
  for k, v in pairs(opts or {}) do TM[k] = v end
  local d = setmetatable({}, { __index = Diary })
  d.traySources = function()
    return {
      clock = function()
        local s = ((TM.hour * 60 + TM.min) * 60 + TM.sec + math.floor(clock + 1e-6)) % 86400
        return { hour = math.floor(s / 3600), min = math.floor(s / 60) % 60, sec = s % 60 }
      end,
      power = function() return { pct = PW.pct, charging = PW.charging } end,
      net = function() return NET end,
    }
  end
  d.pushes = {}
  d.push = function(_, x, y, w, h, mode) d.pushes[#d.pushes + 1] = { x = x, y = y, w = w, h = h, mode = mode } end
  d.onPageDone = function(self) self.page = nil end -- страница не уходит в ответ: здесь только угол
  d:init()
  return d
end

local function black_in(bb, r)
  local n = 0
  for y = r.y, r.y + r.h - 1 do
    for x = r.x, r.x + r.w - 1 do if bb.data[y * bb.stride + x] == 0 then n = n + 1 end end
  end
  return n
end

local function snapshot(bb, r)
  local s = {}
  for y = r.y, r.y + r.h - 1 do
    for x = r.x, r.x + r.w - 1 do s[#s + 1] = bb.data[y * bb.stride + x] end
  end
  return s
end

local function copy(r) return { x = r.x, y = r.y, w = r.w, h = r.h } end

local function inside(a, b) -- a ⊆ b
  return a.x >= b.x and a.y >= b.y and a.x + a.w <= b.x + b.w and a.y + a.h <= b.y + b.h
end

-- задачи угла в реестре виджета (всё, что стоит, кроме задачи угла, — не его)
local function tray_tasks(d)
  local n = 0
  for fn in pairs(d.tasks) do if fn == d.tray.task then n = n + 1 end end
  return n
end

local function in_timeline(fn)
  local n = 0
  for _, task in ipairs(timeline) do if task.fn == fn then n = n + 1 end end
  return n
end

local BAND -- нижняя полоса правой половины, где живёт угол
local function band() return { x = W / 2, y = H - CFG.tray.band, w = W / 2, h = CFG.tray.band } end

local T = {}

function T.test_show_paints_icons_without_push()
  local d = open_diary()
  local r = d.tray.rect
  t.ok(r, "угол показан при открытии")
  t.ok(black_in(d.canvas, r) > 0, "в прямоугольнике угла есть тушь")
  t.eq(#d.pushes, 0, "показ без push: первая отрисовка — полное обновление")
  t.ok(r.x > W / 2, "правее середины: " .. r.x)
  t.ok(r.y >= H - CFG.tray.band, "ниже h - band: " .. r.y)
  t.ok(r.x + r.w <= W and r.y + r.h <= H, "внутри экрана")
  -- квадрат выхода [w - corner, w) × [0, corner] угол не задевает
  t.ok(r.y > CFG.corner or r.x + r.w <= W - CFG.corner, "не в зоне выхода")
  t.eq(count("riddle: tray show open 21:40 87% wifi rect=" .. r.x .. "," .. r.y .. "," .. r.w .. "," .. r.h), 1)
  t.eq(tray_tasks(d), 1, "тик стоит")
  d:onCloseWidget()
end

function T.test_tick_on_minute_repaints_only_corner()
  BAND = band()
  local d = open_diary({ sec = 50 })
  run(9.9)
  t.eq(#d.pushes, 0, "до смены минуты — ничего")
  run(0.2)
  t.eq(#d.pushes, 1, "в начале минуты — ровно одно обновление")
  local p = d.pushes[1]
  t.ok(inside(p, BAND), string.format("только угол: %d,%d,%d,%d", p.x, p.y, p.w, p.h))
  t.eq(p.mode, CFG.dissolve.wf, "частичное обновление растворения")
  run(59.8)
  t.eq(#d.pushes, 1, "следующий не раньше чем через минуту")
  run(0.2)
  t.eq(#d.pushes, 2, "следующий — через 60 с")
  t.eq(count("riddle: tray tick "), 0, "без devmode тики не пишутся")
  d:onCloseWidget()
end

function T.test_tick_repaints_union_when_wifi_drops()
  local d = open_diary()
  local old = copy(d.tray.rect)
  NET = "down"
  run(60.1)
  t.eq(#d.pushes, 1)
  local p, new = d.pushes[1], d.tray.rect
  t.ok(inside(old, p), "push покрывает старый прямоугольник целиком")
  t.ok(new.x > old.x, "без Wi‑Fi угол уже")
  -- там, где были дуги, туши нет
  t.eq(black_in(d.canvas, { x = old.x, y = old.y, w = new.x - old.x, h = old.h }), 0, "старые дуги стёрты")
  t.ok(black_in(d.canvas, new) > 0, "остальное на месте")
  t.eq(count("riddle: tray wifi off"), 1)
  t.eq(count("riddle: tray charging"), 0, "зарядка не менялась")
  NET = "up"
  PW.charging = true
  run(60)
  t.eq(count("riddle: tray wifi on"), 1)
  t.eq(count("riddle: tray charging on"), 1)
  d:onCloseWidget()
end

function T.test_tick_waits_for_pen()
  local d = open_diary({ sec = 50 })
  run(9.9)
  d.cur = { p = { 100, 100 }, b = { 100, 100, 100, 100 }, lvl = 0 } -- перо на странице (далеко от угла)
  run(0.15)
  t.eq(#d.pushes, 0, "перо на странице — угол ждёт")
  run(0.35)
  t.eq(#d.pushes, 0, "всё ещё ждёт")
  d.cur = nil
  run(0.1)
  t.eq(#d.pushes, 1, "после отрыва — в пределах тика стока")
  local n
  for _, line in ipairs(LOG) do n = n or line:match("^riddle: tray tick after pen (%d+) ms 21:41 87%% wifi$") end
  t.ok(n and tonumber(n) >= 400 and tonumber(n) <= 500, "строка ожидания пера с мс: " .. tostring(n))
  t.eq(count("riddle: tray tick "), 1, "одна строка на тик")
  t.eq(tray_tasks(d), 1, "дальше — следующий тик по минуте")
  d:onCloseWidget()
end

-- пиксели угла, которые молния меняет: тот же заряд с зарядкой и без -> { {x, y, было, стало} … }
local function bolt_diff(pct)
  local function canvas(charging)
    local d = open_diary()
    PW.pct, PW.charging = pct, charging
    d:trayShow("test")
    local r = copy(d.tray.rect)
    local s = snapshot(d.canvas, r)
    d:onCloseWidget()
    return s, r
  end
  local off, r = canvas(false)
  local on, r2 = canvas(true)
  t.eq(r2.x, r.x, "рамка на том же месте"); t.eq(r2.w, r.w)
  local out = {}
  for i = 1, #off do
    if off[i] ~= on[i] then
      local k = i - 1
      out[#out + 1] = { x = r.x + k % r.w, y = r.y + math.floor(k / r.w), was = off[i], now = on[i] }
    end
  end
  return out
end

-- молния не касается рамки: верхняя и нижняя линии рамки (line px у icon_h от базовой линии) без белых точек
function T.test_bolt_keeps_off_the_frame()
  local M = CFG.tray
  local base = H - M.pad_b
  local y0, y1 = base - M.icon_h + M.line, base - M.line -- внутренность рамки по высоте: [y0, y1)
  for _, pct in ipairs({ 0, 55, 87, 100 }) do
    local diff = bolt_diff(pct)
    t.ok(#diff > 0, "молния видна при " .. pct .. "%")
    for _, p in ipairs(diff) do
      t.ok(p.y >= y0 and p.y < y1, string.format("%d%%: точка молнии (%d,%d) на рамке, внутри [%d,%d)", pct, p.x, p.y, y0, y1))
    end
  end
end

-- закрытие дневника освобождает буфер слоя угла (иначе он течёт с каждым открытием)
function T.test_close_frees_tray_layer()
  local d = open_diary()
  local bb, freed = d.tray.layer.bb, 0
  bb.free = function() freed = freed + 1 end
  d:onCloseWidget()
  t.eq(freed, 1, "буфер слоя угла освобождён ровно раз")
end

-- провод на устройстве: часы — map_clock виджета (os.date("*t")), заряд — powerd устройства, связь — riddle.net
function T.test_device_tray_sources()
  local Device, rnet = require("device"), require("riddle.net")
  local saved_state = rnet.state
  Device.getPowerDevice = function()
    return { getCapacity = function() return 42 end, isCharging = function() return true end }
  end
  rnet.state = function() return "down" end
  local ok, err = pcall(function()
    clock, timeline, LOG = 0, {}, {}
    local d = setmetatable({}, { __index = Diary })
    d.map_clock = function() return { hour = 7, min = 5, sec = 30 } end
    d.push = nop
    d.onPageDone = function(self) self.page = nil end
    d:init()
    t.eq(count("riddle: tray show open 7:05 42%+ nowifi"), 1, table.concat(LOG, " | "))
    local at
    for _, task in ipairs(timeline) do if task.fn == d.tray.task then at = task.at end end
    t.eq(at, 30, "тик — через 30 с, по секундам часов виджета")
    d:onCloseWidget()
  end)
  Device.getPowerDevice, rnet.state = nil, saved_state
  t.ok(ok, tostring(err))
end

-- ширина текста угла — та, с которой он рисуется: цифры кончаются левее правого отступа, тушь не заходит за w − pad_r
-- (мерка уже настоящей — цифры наезжают вправо и друг на друга)
function T.test_tray_text_fits_its_measure()
  local d = open_diary()
  local r, right = d.tray.rect, W - CFG.tray.pad_r
  local max_x = -1
  for y = r.y, r.y + r.h - 1 do
    for x = r.x, r.x + r.w - 1 do
      if d.canvas.data[y * d.canvas.stride + x] == 0 and x > max_x then max_x = x end
    end
  end
  t.ok(max_x < right, "тушь угла до " .. max_x .. ", правый отступ " .. right)
  t.ok(max_x >= right - 10, "цифры у правого отступа: " .. max_x)
  d:onCloseWidget()
end

-- молния видна и на заливке, и на пустой части: на полной батарее — белая по чёрному, на пустой — чёрная по белому
function T.test_bolt_white_on_fill_black_on_empty()
  local full, empty = bolt_diff(100), bolt_diff(0)
  t.ok(#full > 0 and #empty > 0, "молния видна в обоих случаях")
  for _, p in ipairs(full) do t.ok(p.was == 0 and p.now == 0xFF, string.format("100%%: (%d,%d) белеет", p.x, p.y)) end
  for _, p in ipairs(empty) do t.ok(p.was == 0xFF and p.now == 0, string.format("0%%: (%d,%d) чернеет", p.x, p.y)) end
end

-- перо «залипло» (отрыв потерян): угол ждёт не дольше CFG.tray.pen_wait_s, потом рисует всё равно, и дальше —
-- тик по минуте, а не опрос каждые sink_tick_s без конца
function T.test_stuck_pen_wait_has_a_ceiling()
  local cap = CFG.tray.pen_wait_s
  t.ok(type(cap) == "number" and cap > 0 and cap < 60, "потолок — меньше минуты: " .. tostring(cap))
  local d = open_diary({ sec = 50 })
  d.cur = { p = { 100, 100 }, b = { 100, 100, 100, 100 }, lvl = 0 }
  run(10 + cap - 0.05)
  t.eq(#d.pushes, 0, "до потолка — ждёт")
  run(0.2)
  t.eq(#d.pushes, 1, "потолок — угол нарисован, хоть перо и не оторвано")
  local ms
  for _, line in ipairs(LOG) do ms = ms or line:match("^riddle: tray tick pen still down (%d+) ms 21:41 87%% wifi$") end
  ms = tonumber(ms)
  t.ok(ms and ms >= cap * 1000 and ms <= cap * 1000 + 150, "строка потолка с мс: " .. tostring(ms))
  t.eq(count("riddle: tray tick after pen"), 0)
  local plans = 0
  local plan = d.trayPlan
  d.trayPlan = function(self, s) plans = plans + 1; return plan(self, s) end
  run(60 - cap - 0.2)
  t.eq(plans, 0, "до следующей минуты угол не просыпается")
  d.cur = nil
  run(0.3)
  t.eq(#d.pushes, 2, "следующий тик — в начале минуты")
  d:onCloseWidget()
end

-- ожидание пера кончилось с его отрывом: следующий тик по минуте — обычный, без строки «after pen» (лог не шумит)
function T.test_tick_after_pen_wait_is_plain_again()
  local d = open_diary({ sec = 50 })
  run(9.9)
  d.cur = { p = { 100, 100 }, b = { 100, 100, 100, 100 }, lvl = 0 }
  run(0.3)
  d.cur = nil
  run(0.2)
  t.eq(count("riddle: tray tick after pen"), 1, "тик, ждавший перо")
  run(60)
  t.eq(#d.pushes, 2, "следующий тик по минуте прошёл")
  t.eq(count("riddle: tray tick after pen"), 1, "и без строки ожидания пера")
  d:onCloseWidget()
end

function T.test_suspend_drops_tick_resume_reshows()
  local d = open_diary({ sec = 50 })
  -- сон посреди ожидания пера
  d.cur = { p = { 100, 100 }, b = { 100, 100, 100, 100 }, lvl = 0 }
  run(10.3)
  t.eq(#d.pushes, 0)
  d:onSuspend()
  t.eq(d.tray.task, nil, "тик снят")
  t.eq(d.tray.layer, nil, "слой освобождён")
  t.eq(d.tray.rect, nil)
  run(600)
  t.eq(#d.pushes, 0, "во сне угол не обновляется")
  d:onResume()
  local r = d.tray.rect
  t.ok(d.tray.layer and r, "угол показан заново")
  t.ok(black_in(d.canvas, r) > 0, "слой в холсте")
  t.eq(count("riddle: tray show resume"), 1)
  local n = 0
  for _ in pairs(d.tasks) do n = n + 1 end
  t.eq(n, 1, "в реестре виджета только тик угла")
  t.eq(tray_tasks(d), 1)
  t.eq(in_timeline(d.tray.task), 1, "в timeline ровно одна задача угла")
  t.eq(#d.pushes, 0, "показ без push: обновит полный setDirty пробуждения")
  d:onCloseWidget()
end

-- пробуждение при живом тике угла (Resume без Suspend перед ним, ответ на странице — resetPage не зовётся): показ
-- снимает прежний тик, цепочка тиков одна — ровно одно обновление угла в минуту. Сон сам снимает все задачи
-- (resetPage), так что этот путь — единственный, где показ застаёт тик живым
function T.test_resume_over_live_tick_keeps_one_tick_chain()
  local d = open_diary({ sec = 50 })
  d:revealAnswer("Да.", 300, false)
  run(5)
  t.ok(d.answer, "ответ на странице")
  d:onResume() -- 21:40:55: тик открытия ещё стоит на :00
  local function corner_pushes()
    local n, b = 0, band()
    for _, p in ipairs(d.pushes) do if inside(p, b) then n = n + 1 end end
    return n
  end
  t.eq(corner_pushes(), 0)
  for m = 1, 3 do
    run(60)
    t.eq(corner_pushes(), m, "минута " .. m .. ": ровно одно обновление угла")
  end
  d:onCloseWidget()
end

-- здоровое устройство для status.collect (как healthy() в status_page_spec.lua)
local NOW = 1763500000
local function healthy()
  return {
    read = function(path)
      if path == "/proc/meminfo" then return "MemFree: 25380 kB\nBuffers: 40272 kB\nCached: 100212 kB\n" end
      if path == "/proc/uptime" then return "2208707.90 285648.98" end
    end,
    build = function() return "21171e3" end,
    power = function() return { pct = 88, charging = false } end,
    net = function() return "up" end,
    wifi = function() return { essid = "home", ip = "192.0.2.220" } end,
    disk = function() return { free_kb = 784000, total_kb = 1360000 } end,
    sync_last = function() return { at = NOW - 60 } end,
    store = function() return { ok_at = NOW - 60, docs = 3, collections = 1 } end,
    now = function() return NOW end,
  }
end

function T.test_map_and_status_have_no_icons()
  local d = open_diary()
  d.statusSources = function() return healthy() end
  d:openStatus("test")
  t.ok(d.status, "страница состояния открыта")
  t.eq(d.tray.layer, nil, "на странице состояния угла нет")
  t.eq(d.tray.task, nil, "и тика нет")
  run(120)
  t.eq(count("riddle: tray "), 1, "только показ при открытии")
  d:penDown(300, 300)
  d:penUp()
  t.eq(d.status, nil, "касание закрыло")
  t.ok(d.tray.layer, "угол вернулся")
  t.eq(tray_tasks(d), 1, "тик стоит")
  t.eq(count("riddle: tray show back"), 1)

  d:openMap("test")
  t.ok(d.map, "карта открыта")
  t.eq(d.tray.layer, nil, "на карте угла нет")
  t.eq(d.tray.task, nil, "и тика нет")
  local before = #LOG
  run(60)
  for i = before + 1, #LOG do t.ok(not LOG[i]:find("riddle: tray ", 1, true), "на карте угол молчит: " .. LOG[i]) end
  d:closeMap("idle")
  t.eq(d.map, nil)
  t.ok(d.tray.layer, "угол вернулся")
  t.ok(black_in(d.canvas, d.tray.rect) > 0, "и он в холсте")
  t.eq(tray_tasks(d), 1, "тик стоит")
  t.eq(count("riddle: tray show back"), 2)
  d:onCloseWidget()
end

function T.test_stroke_over_tray_dissolves_back_to_icons()
  local d = open_diary()
  local r = copy(d.tray.rect)
  t.ok(black_in(d.canvas, r) > 0, "угол на странице")
  local before = snapshot(d.canvas, r)
  local y = r.y + math.floor(r.h / 2)
  d:penDown(r.x - 10, y)
  for x = r.x - 8, r.x + r.w + 10, 2 do d:penMove(x, y + (x % 6 == 0 and 1 or 0)) end
  d:penUp()
  local inked = snapshot(d.canvas, r)
  local diff = 0
  for i = 1, #before do if before[i] ~= inked[i] then diff = diff + 1 end end
  t.ok(diff > 0, "штрих лёг на угол")
  run(CFG.sink_delay_s + 2)
  t.eq(#d.strokes, 0, "штрих растворился")
  local after = snapshot(d.canvas, r)
  local bad = 0
  for i = 1, #before do if before[i] ~= after[i] then bad = bad + 1 end end
  t.eq(bad, 0, "угол цел после растворения туши")
  d:onCloseWidget()
end

function T.test_devmode_logs_every_tick_else_silent()
  local d = open_diary()
  run(120.1)
  t.eq(#d.pushes, 2, "два тика")
  t.eq(count("riddle: tray tick "), 0, "без devmode — ни строки")
  d:onCloseWidget()
  d = open_diary()
  d.devmode = true
  run(120.1)
  t.eq(#d.pushes, 2)
  t.eq(count("riddle: tray tick "), 2, "devmode — строка на каждый тик")
  t.eq(count("riddle: tray tick 21:41 87% wifi"), 1)
  t.eq(count("riddle: tray tick 21:42 87% wifi"), 1)
  d:onCloseWidget()
end

-- ответ, который кончился бы в нижней полосе угла, ложится от textFloor() + 10; кончающийся выше полосы — у своей туши
local function two_lines() return string.rep("а", 45) .. " " .. string.rep("б", 45) end

function T.test_answer_near_bottom_keeps_band_free()
  local d = open_diary()
  local limit = H - CFG.tray.band
  local top = limit - 40 -- два ряда: низ rect заходит за h - band, но не за h
  d:revealAnswer(two_lines(), top, false)
  local r = d.answer.block.rect
  t.ok(r.y + r.h <= limit, "низ ответа " .. (r.y + r.h) .. " не заходит в полосу, граница " .. limit)
  t.eq(r.y, d:textFloor() + 10 - 8, "переложен от textFloor() + 10")
  d:onCloseWidget()
end

-- граница: низ ответа ровно на h - band — это ещё «выше полосы» (план, срез 3: «кончающийся выше h − band»)
function T.test_answer_above_band_stays_at_its_top()
  local limit = H - CFG.tray.band
  local d = open_diary()
  d:revealAnswer(two_lines(), 200, false) -- высота двух рядов от top не зависит: мерим её вдали от полосы
  local h = d.answer.block.rect.h
  d:onCloseWidget()
  d = open_diary()
  local top = limit - h + 8 -- rect.y = top - 8: низ rect == limit
  t.ok(d:textFloor() + 10 ~= top, "переложенный ответ встал бы иначе — граница различима")
  d:revealAnswer(two_lines(), top, false)
  local r = d.answer.block.rect
  t.eq(r.y + r.h, limit, "низ ответа ровно на границе полосы")
  t.eq(r.y, top - 8, "ответ остался у туши")
  d:onCloseWidget()
end

-- ответ, не влезающий и от textFloor() + 10, обрезается по строкам до h − band: последняя видимая строка кончается
-- целым предложением, если на ней есть его конец, иначе — словом и «…» (задача 8127, вариант A)

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
  return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

-- что ответ покажет: его глифы по рядам ("\n" между рядами, пробел перед словом внутри ряда)
local function shown(d)
  local out, base = {}, nil
  for _, g in ipairs(d.answer.block.glyphs) do
    if base and g.base ~= base then out[#out + 1] = "\n"
    elseif base and g.word_start then out[#out + 1] = " " end
    base = g.base
    out[#out + 1] = utf8_char(g.cp)
  end
  return table.concat(out)
end

local function rows(s)
  local r = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do r[#r + 1] = line end
  return r
end

-- открытый дневник без приглашения: оно растворено, как после первого касания
local function open_clean()
  local d = open_diary()
  d:fadeInvitation()
  run(30)
  t.ok(not d.prompt.layer, "приглашения нет")
  return d
end

local function lines_text(n, word)
  local r = {}
  for i = 1, n do r[i] = (word or "строка") .. " " .. i end
  return table.concat(r, "\n")
end

-- ряды, которые влезают от textFloor() + 10 до h − band на стенде (ряд 26 px, подъём 16): низ = top + 8 + 16 + 26 n
local function fit_rows(top) return math.floor((H - CFG.tray.band - top - 8 - 16) / 26) end

function T.test_long_list_answer_is_clipped_above_band()
  local d = open_clean()
  local limit = H - CFG.tray.band
  local n = fit_rows(d:textFloor() + 10)
  d:revealAnswer(lines_text(n + 10), 300, false)
  local r = d.answer.block.rect
  t.ok(r.y + r.h <= limit, "низ ответа " .. (r.y + r.h) .. " не заходит в полосу, граница " .. limit)
  t.eq(r.y, d:textFloor() + 10 - 8, "переложен от textFloor() + 10")
  local s = rows(shown(d))
  t.eq(#s, n, "видно ровно столько рядов, сколько влезает")
  t.eq(s[1], "строка 1", "начало ответа на месте")
  t.eq(s[n], "строка " .. n .. "…", "последний видимый ряд — словом и «…»")
  t.ok(count("riddle: answer clipped to " .. n .. " lines") == 1, "обрезка в журнале")
  d:onCloseWidget()
end

function T.test_long_answer_under_two_row_invitation_is_clipped_above_band()
  local d = open_clean()
  d.invitationText = function() return string.rep("пригл ", 20) end -- 20 слов по 56 px (12 в ряд): два ряда
  d:showInvitation(false)
  local pr = d.prompt.rect
  t.eq(pr.h, 16 + 26 + 26 + 16, "приглашение в два ряда")
  local limit = H - CFG.tray.band
  local sentence = "Ты пишешь мне так, будто каждое слово стоит дороже золота. "
  d:revealAnswer(string.rep(sentence, 40), 300, false) -- ~2400 знаков сплошным текстом с переносами
  local r = d.answer.block.rect
  t.ok(r.y + r.h <= limit, "низ ответа " .. (r.y + r.h) .. " не заходит в полосу, граница " .. limit)
  t.eq(r.y, pr.y + pr.h + 10 + 10 - 8, "ответ под приглашением, от textFloor() + 10")
  local s = rows(shown(d))
  t.eq(#s, fit_rows(d:textFloor() + 10), "видно ровно столько рядов, сколько влезает")
  t.ok(s[#s]:find("золота%.$"), "последний ряд кончается целым предложением: «" .. s[#s] .. "»")
  d:onCloseWidget()
end

function T.test_clipped_answer_ends_on_sentence_or_word_with_ellipsis()
  local d = open_clean()
  local n = fit_rows(d:textFloor() + 10)
  local head = lines_text(n - 1)
  -- конец предложения на последнем видимом ряду: хвост ряда после него не показан
  d:revealAnswer(head .. "\nКонец мысли. И начало новой\n" .. lines_text(5), 300, false)
  local s = rows(shown(d))
  t.eq(#s, n)
  t.eq(s[n], "Конец мысли.", "ряд кончается целым предложением")
  d:onCloseWidget()
  -- конец предложения в кавычках и с «?»: тоже конец
  d = open_clean()
  d:revealAnswer(head .. "\nТы спросил: «Кто ты?» А я молчу\n" .. lines_text(5), 300, false)
  s = rows(shown(d))
  t.eq(s[n], "Ты спросил: «Кто ты?»", "закрывающая кавычка остаётся с предложением")
  d:onCloseWidget()
  -- конца предложения на последнем ряду нет: обрезка по слову и «…», запятая перед ней снимается
  d = open_clean()
  d:revealAnswer(head .. "\nслова без точки,\n" .. lines_text(5), 300, false)
  s = rows(shown(d))
  t.eq(s[n], "слова без точки…", "словом и «…»")
  d:onCloseWidget()
  -- последний ряд полон: «…» не влезает за последнее слово — слово уходит, «…» встаёт за предыдущим
  d = open_clean()
  local maxw = W - 2 * CFG.margin
  local words, x = {}, 0 -- слова по 9 знаков (90 px) через пробел 6 px, пока ряд не полон
  while x + 90 <= maxw do words[#words + 1] = "ааааааааа"; x = x + 90 + 6 end
  t.ok(x - 6 + 10 > maxw, "«…» за последним словом не влезает в ряд")
  d:revealAnswer(head .. "\n" .. table.concat(words, " ") .. "\n" .. lines_text(5), 300, false)
  s = rows(shown(d))
  t.eq(s[n], table.concat(words, " ", 1, #words - 1) .. "…", "последнее слово ушло, «…» за предыдущим")
  local right = 0
  for _, g in ipairs(d.answer.block.glyphs) do right = math.max(right, g.x + 10) end
  t.ok(right <= CFG.margin + maxw, "тушь не шире ряда: " .. right)
  d:onCloseWidget()
end

function T.test_short_answer_is_shown_whole()
  local d = open_clean()
  local text = "Короткий ответ. Без обрезки"
  d:revealAnswer(text, H - CFG.tray.band - 30, false) -- у полосы: переложен, но целиком
  t.eq(shown(d), text, "показан весь текст, без «…»")
  t.eq(d.answer.block.rect.y, d:textFloor() + 10 - 8, "переложен от textFloor() + 10")
  t.eq(count("riddle: answer clipped"), 0, "обрезки нет")
  d:onCloseWidget()
end

-- последний видимый ряд — tail; что после него, на экран не попадает. -> ряды, что показаны
local function clip_last_row(tail)
  local d = open_clean()
  local n = fit_rows(d:textFloor() + 10)
  local text = (n > 1 and lines_text(n - 1) .. "\n" or "") .. tail .. "\n" .. lines_text(5)
  d:revealAnswer(text, 300, false)
  local s = rows(shown(d))
  d:onCloseWidget()
  return s, n
end

-- номер пункта и сокращение — не конец предложения (ревью fde2188, п. 1): «.!?…» после буквы, без точки внутри
function T.test_clip_numbers_and_abbreviations_are_not_sentence_ends()
  local d = open_clean()
  local n = fit_rows(d:textFloor() + 10)
  d:revealAnswer(lines_text(n - 4) .. "\nВот список:\n1. Первый пункт\n2. Второй пункт\n3. Третий пункт\n4. Четвёртый",
    300, false)
  local s = rows(shown(d))
  t.eq(#s, n)
  t.eq(s[n], "3. Третий пункт…", "номер пункта — не конец предложения")
  d:onCloseWidget()
  t.eq(clip_last_row("т.е. всё сложно")[fit_rows(CFG.margin + 10)], "т.е. всё сложно…", "сокращение — не конец")
  t.eq(clip_last_row("и т.д. и т.п.")[fit_rows(CFG.margin + 10)], "и т.д. и т.п.…", "точка внутри слова — не конец")
  t.eq(clip_last_row("Он сказал «да». Потом ушёл")[fit_rows(CFG.margin + 10)], "Он сказал «да».",
    "кавычка перед точкой — всё ещё конец")
  t.eq(clip_last_row("Правда?! Не верю")[fit_rows(CFG.margin + 10)], "Правда?!", "«?!» после буквы — конец")
end

-- одиночное тире в конце ряда: после снятия пусто — слово уходит, «…» за предыдущим (ревью fde2188, п. 2)
function T.test_clip_drops_lone_dash_before_ellipsis()
  local s, n = clip_last_row("вторая это —")
  t.eq(#s, n)
  t.eq(s[n], "вторая это…", "«…» за словом, не отдельно")
end

-- пустой ряд «\n\n» на границе обрезки: видно на ряд меньше, «…» за последним словом (ревью fde2188, п. 3)
function T.test_clip_blank_row_at_the_cut()
  local d = open_clean()
  local n = fit_rows(d:textFloor() + 10)
  d:revealAnswer(lines_text(n - 3) .. "\nПервая строка\nвторая\n\nчетвёртая\nпятая", 300, false) -- пустой — ряд n
  local s = rows(shown(d))
  t.eq(#s, n - 1, "пустой последний ряд не показан")
  t.eq(s[n - 1], "вторая…")
  local r = d.answer.block.rect
  t.ok(r.y + r.h <= H - CFG.tray.band, "низ над полосой")
  t.eq(r.h, 16 + 26 * (n - 1) + 16, "блок высотой в n − 1 рядов: пустой ряд не держит место")
  d:onCloseWidget()
end

-- fn(...) под потолком в счётчик инструкций: зависание (цикл укорачивания слова) — ошибка теста, а не повисший прогон.
-- Хук считает инструкции только без JIT: на время вызова JIT выключен
local function no_hang(fn, ...)
  jit.off()
  debug.sethook(function() error("не вернулся за 5e7 инструкций: завис", 2) end, "", 5e7)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  jit.on()
  t.ok(ok, tostring(err))
end

-- одно слово шире ряда последним: «…» не выводит тушь за ряд — слово укорачивается (ревью fde2188, п. 4)
function T.test_clip_word_wider_than_row_is_shortened()
  local d = open_clean()
  local n = fit_rows(d:textFloor() + 10)
  local maxw = W - 2 * CFG.margin
  local long = string.rep("ж", math.floor(maxw / 10) + 3) -- шире ряда на 3 знака
  no_hang(d.revealAnswer, d, lines_text(n - 1) .. "\n" .. long .. "\n" .. lines_text(5), 300, false)
  local s = rows(shown(d))
  t.eq(#s, n)
  t.ok(s[n]:find("…$"), "кончается «…»: " .. s[n])
  t.eq(s[n], string.rep("ж", math.floor((maxw - 10) / 10)) .. "…", "начало слова и «…» во всю ширину ряда")
  local right = 0
  for _, g in ipairs(d.answer.block.glyphs) do right = math.max(right, g.x + 10) end
  t.ok(right <= CFG.margin + maxw, "тушь не шире ряда: " .. right)
  d:onCloseWidget()
end


-- слово шире ряда с байтом вне UTF-8 в конце (\255): укорачивание идёт по знакам str и кончается (повторное ревью
-- ebb6cee), под no_hang
function T.test_clip_shortens_word_ending_in_invalid_utf8_byte()
  local d = open_clean()
  local n = fit_rows(d:textFloor() + 10)
  local maxw = W - 2 * CFG.margin
  local word = "абв" .. ("\255"):rep(math.floor(maxw / 10) + 10) -- шире ряда, каждый \255 — знак U+FFFD
  no_hang(d.revealAnswer, d, lines_text(n - 1) .. "\n" .. word .. "\n" .. lines_text(5), 300, false)
  local s = rows(shown(d))
  t.eq(#s, n)
  t.ok(s[n]:find("…$"), "ряд кончается «…»")
  local right = 0
  for _, g in ipairs(d.answer.block.glyphs) do right = math.max(right, g.x + 10) end
  t.ok(right <= CFG.margin + maxw, "тушь не шире ряда: " .. right)
  d:onCloseWidget()
end

t.run(T)
