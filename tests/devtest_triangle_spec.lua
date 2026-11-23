-- devtest triangle=N: треугольник пером на странице открывает страницу состояния, касание закрывает её — без пальца.
-- Треугольник harness'а — своя синтетика (фикстуры тестов на устройство не уезжают); triangle.detect обязан её узнавать.
-- Виджет здесь — упрощённый двойник: штрихи из feedEvent собираются в страницу, через idle_s тишины triangle.detect
-- решает (открыть страницу состояния), касание при открытой странице закрывает её, время — виртуальные часы.
-- Раунд через настоящие openStatus/closeStatus — в status_page_spec.lua.
local t = require("t")
local triangle = require("riddle.triangle")

local clock = 0 -- мс
local log = {}
local jobs = {} -- таймеры двойника и UIManager на одних часах
local function stub(name, mod) package.preload[name] = function() return mod end end
stub("device", { screen = {} })
stub("ui/uimanager", { scheduleIn = function(_, delay, fn)
  jobs[#jobs + 1] = { at = clock + delay * 1000, fn = fn }
end })
stub("logger", {
  info = function(...) log[#log + 1] = table.concat({ ... }, " ") end,
  warn = function(...) log[#log + 1] = "WARN " .. table.concat({ ... }, " ") end,
  err = function(...) log[#log + 1] = "ERROR " .. table.concat({ ... }, " ") end,
})
stub("ui/time", { monotonic = function() return clock end, to_ms = function(x) return x end })
stub("libs/libkoreader-lfs", {})

local devtest = require("riddle.devtest")

local IDLE_MS = 2500 -- CFG.idle_s виджета
local OPEN_MS = 4000 -- рассыпание чернил и открытие страницы состояния после треугольника

local function lines(prefix)
  local out = {}
  for _, l in ipairs(log) do
    if l:find(prefix, 1, true) then out[#out + 1] = l end
  end
  return out
end

-- двойник виджета: react=true — треугольник открывает страницу, касание закрывает; false — страница не открывается
-- (проверка таймаута); "stuck" — открывается, но касание её не закрывает (проверка: страница осталась открытой)
local function newDiary(react, dir)
  clock, log, jobs = 0, {}, {}
  local Diary = { canvas = {} }
  function Diary:schedule(delay, fn)
    jobs[#jobs + 1] = { at = clock + delay * 1000 * (Diary.slow or 1), fn = fn, id = #jobs }
    return jobs[#jobs]
  end
  function Diary:cancel(job) if job then job.dead = true end end
  function Diary:run(limit_ms)
    while true do
      local best
      for _, j in ipairs(jobs) do
        if not j.dead and not j.done and (not best or j.at < best.at) then best = j end
      end
      if not best or best.at > limit_ms then return end
      best.done, clock = true, best.at
      best.fn()
    end
  end
  Diary.fed = 0
  Diary.closed_by = {} -- причины closeStatus
  function Diary:closeStatus(why)
    Diary.closed_by[#Diary.closed_by + 1] = why
    Diary.status = nil
  end
  -- сон, как у виджета (onSuspend): страница состояния закрывается без рисования; таймеры UIManager сон не снимает
  function Diary:onSuspend() Diary:closeStatus("sleep") end
  -- печать закрыта: страница состояния всё равно открывается — треугольник идёт мимо модели (onPageDone виджета)
  Diary.controller = { seal_open = false }
  local page, cur, page_task = {}, nil, nil
  local function pageDone()
    local pg = page
    page = {}
    if not triangle.detect(pg) then return end
    if react == false then return end
    Diary:schedule(OPEN_MS / 1000, function() Diary.status = {} end)
  end
  Diary.gd = { feedEvent = function(_, tevs)
    for _, tev in ipairs(tevs) do
      Diary.fed = Diary.fed + 1
      if tev.id == -1 then
        cur = nil
        Diary:cancel(page_task)
        if #page > 0 then page_task = Diary:schedule(IDLE_MS / 1000, pageDone) end
      elseif Diary.status then -- касание при открытой странице: закрывает её, чернил нет
        if react ~= "stuck" then Diary:closeStatus("touch") end
      else
        if not cur then
          cur = { p = {} }
          page[#page + 1] = cur
          Diary:cancel(page_task)
        end
        cur.p[#cur.p + 1], cur.p[#cur.p + 2] = tev.x, tev.y
      end
    end
  end }
  devtest.install(Diary, { rssKB = function() return 0 end, RIDDLE_DIR = dir })
  return Diary
end

local function start(react, content)
  local dir = os.tmpname()
  os.remove(dir)
  os.execute('mkdir -p "' .. dir .. '"')
  local f = io.open(dir .. "/testmode", "w"); f:write(content); f:close()
  return newDiary(react, dir), dir
end

local T = {}

function T.test_synthetic_triangle_is_recognized_by_triangle_detect()
  local ok = triangle.detect(devtest.triangleStrokes())
  t.ok(ok, "синтетика devtest — треугольник для triangle.detect")
end

function T.test_parseTriangle_reads_the_testmode_line()
  t.eq(devtest.parseTriangle("triangle=2"), 2)
  t.eq(devtest.parseTriangle("exit=1 triangle=10"), 10)
  t.eq(devtest.parseTriangle("rose=3"), nil)
  t.eq(devtest.parseTriangle("cycles=3"), nil)
end

function T.test_triangle_2_opens_and_closes_the_status_twice_and_logs_every_step()
  local Diary, dir = start(true, "triangle=2")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  for i = 1, 2 do
    local o = lines("riddle: TRIANGLE cycle " .. i .. " open=")[1]
    t.ok(o and o:match("^riddle: TRIANGLE cycle " .. i .. " open=%d+$"), "шаг «открылась»: " .. tostring(o))
    t.ok(tonumber(o:match("open=(%d+)")) >= OPEN_MS, "время ожидания настоящее, не 0: " .. o)
    local c = lines("riddle: TRIANGLE cycle " .. i .. " close=")[1]
    t.ok(c and c:match("^riddle: TRIANGLE cycle " .. i .. " close=%d+$"), "шаг «закрылась»: " .. tostring(c))
  end
  t.eq(lines("riddle: TRIANGLE n=")[1], "riddle: TRIANGLE n=2 opened=2 closed=2")
  t.eq(Diary.status, nil, "страница закрыта в конце")
  t.eq(Diary.closed_by[1], "touch", "закрыла страницу именно подача касания")
  t.eq(io.open(dir .. "/testmode", "r"), nil, "testmode одноразовый")
end

function T.test_status_that_never_opens_is_logged_not_waited_forever()
  local Diary = start(false, "triangle=1")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("riddle: TRIANGLE cycle 1 open=-1 close=-1"), 1, table.concat(log, "\n"))
  t.eq(lines("riddle: TRIANGLE n=")[1], "riddle: TRIANGLE n=1 opened=0 closed=0")
end

-- касание не закрыло страницу: close=-1, страницу по окончании режима закрывает сам режим
function T.test_status_left_open_by_a_failed_touch_is_closed_at_the_end()
  local Diary = start("stuck", "triangle=1")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  local c = lines("riddle: TRIANGLE cycle 1 close=")[1]
  t.eq(c, "riddle: TRIANGLE cycle 1 close=-1", table.concat(log, "\n"))
  t.eq(lines("riddle: TRIANGLE n=")[1], "riddle: TRIANGLE n=1 opened=1 closed=0 (status left open, closed)")
  t.eq(Diary.status, nil)
  t.eq(Diary.closed_by[#Diary.closed_by], "devtest")
end

-- закрытая печать — не причина для отмены: треугольник идёт мимо модели при любой печати (виджет: onPageDone)
function T.test_closed_seal_does_not_abort_the_triangle()
  local Diary = start(true, "triangle=1")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("ERROR"), 0, table.concat(log, "\n"))
  t.ok(Diary.fed > 0, "треугольник подан")
  t.eq(lines("riddle: TRIANGLE n=")[1], "riddle: TRIANGLE n=1 opened=1 closed=1")
end

-- подача, которую сторож объявил потерянной (сон снимает задачи подачи): строка в лог, а не молчание; метка не «ROSE»
function T.test_lost_feed_is_logged_as_triangle()
  local Diary = start(true, "triangle=2")
  Diary.slow = 5
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("riddle: TRIANGLE aborted (feed lost)"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: ROSE"), 0, table.concat(log, "\n"))
  t.eq(#lines("riddle: TRIANGLE n="), 0)
end

-- triangle=0 — нулевой прогон
function T.test_triangle_0_is_marked_as_a_zero_run()
  local Diary = start(true, "triangle=0")
  Diary:maybeStartTest()
  Diary:run(60 * 1000)
  t.eq(lines("riddle: TRIANGLE n=")[1], "riddle: TRIANGLE n=0 opened=0 closed=0 (zero run)")
  t.eq(Diary.fed, 0)
end

-- ждём, пока в логе появится строка prefix (шаг 0.5 с виртуального времени)
local function runUntilLogged(Diary, prefix)
  for limit = 500, 10 * 60 * 1000, 500 do
    Diary:run(limit)
    if #lines(prefix) > 0 then return true end
  end
  return false
end

-- сон закрыл страницу, пока раунд ждёт: это не закрытие касанием — closed не растёт, касание поверх скринсейвера
-- не подаётся, раунд кончается «aborted (sleep)» (треугольник идёт под любой печатью — по печати сон не узнать)
function T.test_sleep_after_the_status_opened_aborts_and_is_not_counted_as_closed()
  local Diary = start(true, "triangle=1")
  Diary:maybeStartTest()
  t.ok(runUntilLogged(Diary, "riddle: TRIANGLE cycle 1 open="), table.concat(log, "\n"))
  Diary:onSuspend()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("riddle: TRIANGLE aborted (sleep)"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: TRIANGLE cycle 1 close="), 0, "закрытие сном не засчитано: " .. table.concat(log, "\n"))
  t.eq(#lines("riddle: TRIANGLE n="), 0, "прогон не доведён до итога")
  t.eq(Diary.closed_by[1], "sleep")
  t.eq(#Diary.closed_by, 1, "режим сам ничего не закрывал: страница уже закрыта сном")
end

-- после сна раунды не продолжаются: ни одного события пера, ни второго цикла
function T.test_after_sleep_no_more_rounds_and_no_pen_events()
  local Diary = start(true, "triangle=3")
  Diary:maybeStartTest()
  t.ok(runUntilLogged(Diary, "riddle: TRIANGLE cycle 1 open="), table.concat(log, "\n"))
  Diary:onSuspend()
  local fed = Diary.fed
  Diary:run(30 * 60 * 1000)
  t.eq(Diary.fed, fed, "после сна перо не подаёт событий")
  t.eq(#lines("riddle: TRIANGLE cycle 2"), 0, table.concat(log, "\n"))
  t.eq(#lines("riddle: TRIANGLE n="), 0)
end

-- сон до начала прогона прогон не отменяет: считается сон «с начала прогона»
function T.test_sleep_before_the_run_does_not_abort_it()
  local Diary = start(true, "triangle=1")
  Diary:onSuspend()
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(lines("riddle: TRIANGLE n=")[1], "riddle: TRIANGLE n=1 opened=1 closed=1", table.concat(log, "\n"))
end

t.run(T)
