-- Тайный выход: палец 3 с неподвижно в правом верхнем углу -> обычный KOReader.
-- Пока цикл UIManager стоит (respond синхронно ждёт LLM), касание копится в буфере ядра и
-- приходит пачкой: таймер угла от момента обработки не успевает, penUp его снимает. Поэтому
-- удержание меряется ещё и по времени ядра (tev.timev). Живые попытки 2026-10-23 07:47–07:48
-- (отрыв через ~1.5 с) этим не объясняются — для них devmode-трасса угла ниже.
local t = require("t")

local LOG, TASKS, CLOSED = {}, {}, {}
local function stub(name, mod) package.preload[name] = function() return mod end end
local nop = function() end
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  LOG[#LOG + 1] = table.concat(parts, " ")
end

local canvas = { fill = nop, paintRect = nop, free = nop }
stub("ffi/blitbuffer", { COLOR_WHITE = 0xFF, COLOR_BLACK = 0, TYPE_BB8 = 1, new = function() return canvas end })
stub("device", { isKindle = function() return false end,
                 screen = { getTouchRotation = function() return 0 end } })
stub("ffi/freetype", { newFaceSize = function() return {} end })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/rendertext", {})
stub("ui/uimanager", {
  scheduleIn = function(_, s, fn) TASKS[#TASKS + 1] = { s = s, fn = fn } end,
  unschedule = function(_, fn)
    for i = #TASKS, 1, -1 do if TASKS[i].fn == fn then table.remove(TASKS, i) end end
  end,
  nextTick = nop,
  close = function(_, w) CLOSED[#CLOSED + 1] = w end,
  event_hook = { execute = nop },
})
stub("ui/widget/widget", { extend = function(_, o) return o end })
stub("logger", { info = log, warn = log, err = log, dbg = nop })
-- fts как в KOReader: целые микросекунды
stub("ui/time", { monotonic = function() return 0 end, to_s = function(x) return x / 1e6 end,
                  to_ms = function(x) return x / 1e3 end, to_us = function(x) return x end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop, mkdir = nop })

local Diary = require("riddle_diarywidget")

local function diary()
  LOG, TASKS, CLOSED = {}, {}, {}
  local d = setmetatable({
    canvas = canvas, tasks = {}, queue = {}, inflight = 0, strokes = {}, epoch = 0, w = 758, h = 1024,
    prompt = {},
    stats = { frames = 0, frame_us = 0, frame_us_max = 0, sink_ticks = 0, sink_us = 0, sink_us_max = 0,
              ans_steps = 0, ans_us_max = 0, grey_px = 0, lost_ink = 0 },
  }, { __index = Diary })
  d.push = nop
  return d
end

local S = 1e6
local function down(x, y, tv) return { { slot = 0, id = 5, x = x, y = y, timev = tv } } end
local function lift(tv) return { { slot = 0, id = -1, timev = tv } } end

-- касание целиком одной пачкой: задачи UIManager между кадрами не выполняются
local function batch(d, frames)
  for _, f in ipairs(frames) do d:onRawTouch(f) end
end

local function exited() return #CLOSED == 1 end

local T = {}

function T.test_batched_still_hold_exits()
  local d = diary()
  batch(d, { down(711, 38, 0), down(711, 45, 1 * S), down(710, 50, 2 * S),
             down(710, 52, 3.1 * S), lift(3.2 * S) })
  t.ok(exited(), "удержание 3.2 с по времени ядра — выход, даже если таймер не успел")
end

function T.test_batched_short_touch_stays()
  local d = diary()
  batch(d, { down(711, 38, 0), down(711, 40, 0.5 * S), lift(1.0 * S) })
  t.ok(not exited(), "1 с — не выход")
end

function T.test_batched_slide_out_stays()
  local d = diary()
  batch(d, { down(740, 29, 0), down(690, 29, 1 * S), lift(3.5 * S) })
  t.ok(not exited(), "сдвиг больше slop снимает выход")
end

function T.test_timer_exits_while_held()
  local d = diary()
  d:onRawTouch(down(740, 29, 0))
  local corner
  for _, task in ipairs(TASKS) do if task.s == 3 then corner = task end end
  t.ok(corner, "таймер угла на 3 с поставлен")
  corner.fn()
  t.ok(exited(), "таймер при неподвижном пальце — выход")
end

function T.test_zone_150_px()
  local d = diary()
  -- живая попытка 07:47:35: палец лёг на x=635
  batch(d, { down(635, 87, 0), down(636, 90, 1 * S), lift(3.2 * S) })
  t.ok(exited(), "x=635 — в зоне 150 px")
  d = diary()
  batch(d, { down(600, 87, 0), lift(3.2 * S) })
  t.ok(not exited(), "x=600 — вне зоны")
  d = diary()
  batch(d, { down(740, 160, 0), lift(3.2 * S) })
  t.ok(not exited(), "y=160 — вне зоны")
end

function T.test_lift_without_timev_stays()
  local d = diary()
  batch(d, { { { slot = 0, id = 5, x = 740, y = 29 } }, { { slot = 0, id = -1 } } })
  t.ok(not exited(), "без времени ядра выход только по таймеру")
end

function T.test_exit_mid_batch_does_not_draw_on_closed_page()
  local d = diary()
  d.exit = function(self)
    CLOSED[#CLOSED + 1] = self
    self.canvas = nil -- как onCloseWidget
  end
  local ok, err = pcall(batch, d, { down(740, 29, 0),
    { { slot = 0, id = -1, timev = 3.2 * S }, { slot = 1, id = 6, x = 300, y = 300, timev = 3.2 * S } } })
  t.ok(ok, tostring(err))
  t.ok(exited(), "выход")
end

-- devmode: каждое сырое событие касания, начатого в углу, — строкой с временем ядра от касания;
-- живой лог 07:47–07:48 показал отрыв через ~1.5 с, и откуда он — неизвестно
local function lines(prefix)
  local out = {}
  for _, l in ipairs(LOG) do if l:find(prefix, 1, true) then out[#out + 1] = l end end
  return out
end

function T.test_devmode_logs_raw_corner_events()
  local d = diary()
  d.devmode = true
  batch(d, { down(740, 29, 0), down(738, 30, 0.5 * S),
             { { slot = 0, id = -1, timev = 1.5 * S }, { slot = 1, id = 9, timev = 1.5 * S } } })
  -- после отрыва ещё 6 с по времени ядра: видно, вернулся ли палец
  batch(d, { down(300, 300, 7.5 * S) })
  local l = lines("riddle: corner ")
  t.eq(#l, 5, table.concat(l, "\n"))
  t.ok(l[1]:find("corner tev slot=0 id=5 x=740 y=29 +0.000", 1, true), l[1])
  t.ok(l[2]:find("corner tev slot=0 id=5 x=738 y=30 +0.500", 1, true), l[2])
  t.ok(l[3]:find("corner lift, held 1.50 s", 1, true), l[3])
  t.ok(l[4]:find("corner tev slot=0 id=-1 x=nil y=nil +1.500", 1, true), l[4])
  t.ok(l[5]:find("corner tev slot=1 id=9 x=nil y=nil +1.500", 1, true), l[5])
end

function T.test_devmode_logs_timer_fire()
  local d = diary()
  d.devmode = true
  d:onRawTouch(down(740, 29, 0))
  for _, task in ipairs(TASKS) do if task.s == 3 then task.fn() end end
  t.eq(#lines("riddle: corner timer fired"), 1)
end

function T.test_no_corner_lines_without_devmode()
  local d = diary()
  batch(d, { down(740, 29, 0), down(738, 30, 0.5 * S), lift(1.5 * S) })
  t.eq(#lines("riddle: corner"), 0)
end

function T.test_devmode_silent_outside_corner()
  local d = diary()
  d.devmode = true
  batch(d, { down(300, 300, 0), down(310, 300, 0.5 * S), lift(1.5 * S) })
  t.eq(#lines("riddle: corner"), 0)
end

t.run(T)
