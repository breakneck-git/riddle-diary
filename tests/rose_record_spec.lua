-- Подбор порогов розы по руке владельца (A10, Notion 40a13e60-bc8d-8163), только devmode: лог «riddle: rose yes|no
-- score=…» с разбором по критериям — на каждой странице под открытой печатью и на пергаменте; страница, похожая по
-- числу штрихов на розу, ещё и пишется файлом штрихов (<rose_dir>/<время>-<n>.lua, формат фикстур), чтобы живые
-- попытки стали фикстурой. Без devmode — ни строки, ни файла: боевой путь как был.
local t = require("t")

local LOG = {}
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
stub("ui/uimanager", { scheduleIn = nop, unschedule = nop, nextTick = nop, close = nop, event_hook = { execute = nop } })
stub("ui/widget/widget", { extend = function(_, o) return o end })
stub("logger", { info = log, warn = log, err = log, dbg = nop })
stub("ui/time", { monotonic = function() return 0 end, to_s = function(x) return x / 1e6 end,
                  to_ms = function(x) return x / 1e3 end, to_us = function(x) return x end })
stub("libs/libkoreader-lfs", { attributes = nop, dir = nop, mkdir = nop })

local Diary = require("riddle_diarywidget")
local F = require("fixtures.rose_strokes")

local function tmpdir()
  local h = io.popen("mktemp -d")
  local dir = h:read("*l")
  h:close()
  return dir
end

local function files(dir)
  local out = {}
  local h = io.popen('ls "' .. dir .. '"')
  for name in h:lines() do out[#out + 1] = name end
  h:close()
  return out
end

local function diary(devmode)
  LOG = {}
  local d = setmetatable({ rose_dir = tmpdir() }, { __index = Diary })
  d.devmode = devmode
  return d
end

local function roseLines()
  local out = {}
  for _, l in ipairs(LOG) do if l:find("riddle: rose ", 1, true) then out[#out + 1] = l end end
  return out
end

local T = {}

-- devmode: роза — лог с оценкой и разбором, файл штрихов читается обратно тем же списком точек
function T.test_devmode_rose_logged_and_recorded()
  local d = diary(true)
  t.ok(d:isRose(F.rose_ccw), "роза узнана")
  local l = roseLines()
  t.eq(#l, 1, table.concat(LOG, "\n"))
  for _, k in ipairs({ "score=", "spread=", "sweep=", "oval=", "corner=", "bend=", "inside=", "tilt=", "short=", "n=3" }) do
    t.ok(l[1]:find(k, 1, true), k .. " в строке: " .. l[1])
  end
  t.ok(l[1]:find("riddle: rose yes", 1, true), l[1])
  local names = files(d.rose_dir)
  t.eq(#names, 1, "один файл штрихов")
  t.ok(l[1]:find(names[1], 1, true), "имя файла в строке лога: " .. l[1])
  local back = dofile(d.rose_dir .. "/" .. names[1])
  t.eq(#back, #F.rose_ccw)
  for i, s in ipairs(F.rose_ccw) do
    t.eq(#back[i].p, #s.p, "штрих " .. i)
    for k = 1, #s.p do t.eq(back[i].p[k], s.p[k], "штрих " .. i .. " точка " .. k) end
  end
end

-- не роза тоже пишется (иначе промах владельца не разобрать), каждая страница — свой файл
function T.test_devmode_miss_recorded_each_page()
  local d = diary(true)
  t.ok(not d:isRose(F.circle_only), "круг без креста — не роза")
  t.ok(not d:isRose(F.cross_only), "крест без круга — не роза")
  local l = roseLines()
  t.eq(#l, 2)
  t.ok(l[1]:find("riddle: rose no", 1, true), l[1])
  t.eq(#files(d.rose_dir), 2, "по файлу на страницу")
end

-- исписанная страница (штрихов больше, чем у розы бывает) — не пишется: это чужой текст
function T.test_devmode_long_page_not_recorded()
  local d = diary(true)
  local many = {}
  for i = 1, 12 do many[i] = { p = { i * 10, 100, i * 10 + 5, 120 } } end
  t.ok(not d:isRose(many))
  t.eq(#files(d.rose_dir), 0)
end

-- без devmode — ни строки оценки в логе, ни штрихов на диске; роза узнаётся как прежде
function T.test_no_devmode_silent()
  local d = diary(false)
  t.ok(d:isRose(F.rose_ccw))
  t.ok(not d:isRose(F.circle_only))
  t.eq(#roseLines(), 0, table.concat(LOG, "\n"))
  t.eq(#files(d.rose_dir), 0)
end

t.run(T)
