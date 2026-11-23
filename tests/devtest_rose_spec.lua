-- devtest rose=N: роза пером на странице открывает карту, роза на пергаменте закрывает её — без пальца.
-- Роза harness'а — своя синтетика (фикстуры тестов на устройство не уезжают); rose.detect обязан её узнавать.
-- Виджет здесь — упрощённый двойник: штрихи из feedEvent собираются в страницу, через idle_s тишины rose.detect
-- решает (открыть карту / закрыть её), время — виртуальные часы. resetPage настоящего виджета двойник не повторяет:
-- раунд через настоящие openMap/closeMap — test_devtest_rose_counts_cycles_through_real_open_and_close в async_answer_spec.
local t = require("t")
local rose = require("riddle.rose")

local clock = 0 -- мс
local log = {}
local jobs = {} -- таймеры двойника и UIManager (таймеры раунда розы идут мимо self:schedule) на одних часах
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
local OPEN_MS = 4000 -- рассыпание чернил и появление пергамента после страницы-розы

local function lines(prefix)
  local out = {}
  for _, l in ipairs(log) do
    if l:find(prefix, 1, true) then out[#out + 1] = l end
  end
  return out
end

-- двойник виджета: react=true — роза открывает и закрывает карту; false — карта не реагирует (проверка таймаута);
-- "open_only" — открывает, но розой на пергаменте не закрывает (проверка: карта осталась открытой)
local function newDiary(react, seal_open, dir)
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
  Diary.fed = 0 -- событий пера, поданных в feedEvent
  Diary.closed_by = {} -- причины closeMap
  function Diary:closeMap(why)
    Diary.closed_by[#Diary.closed_by + 1] = why
    Diary.map = nil
  end
  Diary.controller = { seal_open = seal_open ~= false }
  -- сон: печать закрыта, resetPage снимает все задачи self:schedule (таймеры UIManager раунда он не трогает)
  function Diary:sleep()
    Diary.controller.seal_open = false
    for _, j in ipairs(jobs) do
      if j.id then j.dead = true end
    end
    Diary.map = nil
  end
  local page, cur, page_task = {}, nil, nil
  local function pageDone()
    local pg = page
    page = {}
    if not rose.detect(pg) then return end
    if react == false then return end
    if react == "open_only" and Diary.map then return end
    Diary:schedule(OPEN_MS / 1000, function() Diary.map = (not Diary.map) and {} or nil end)
  end
  Diary.gd = { feedEvent = function(_, tevs)
    for _, tev in ipairs(tevs) do
      Diary.fed = Diary.fed + 1
      if tev.id == -1 then
        cur = nil
        Diary:cancel(page_task)
        page_task = Diary:schedule(IDLE_MS / 1000, pageDone)
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

-- testmode-файл на диске: maybeStartTest читает его и удаляет
local function start(react, seal_open, content)
  local dir = os.tmpname()
  os.remove(dir)
  os.execute('mkdir -p "' .. dir .. '"')
  local f = io.open(dir .. "/testmode", "w"); f:write(content); f:close()
  return newDiary(react, seal_open, dir), dir
end

local T = {}

function T.test_synthetic_rose_is_recognized_by_rose_detect()
  local ok = rose.detect(devtest.roseStrokes())
  t.ok(ok, "синтетика devtest — роза для rose.detect")
end

function T.test_parseRose_reads_the_testmode_line()
  t.eq(devtest.parseRose("rose=2"), 2)
  t.eq(devtest.parseRose("exit=1 rose=10"), 10)
  t.eq(devtest.parseRose("cycles=3"), nil)
  t.eq(devtest.parseRose("feed=2 gap=1"), nil)
end

function T.test_rose_2_opens_and_closes_the_map_twice_and_logs_it()
  local Diary, dir = start(true, true, "rose=2")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  local cycles = lines("riddle: ROSE cycle")
  t.eq(#cycles, 2)
  for i, l in ipairs(cycles) do
    t.ok(l:match("^riddle: ROSE cycle " .. i .. " open=%d+ close=%d+$"), "строка цикла: " .. l)
    t.ok(not l:find("=-1", 1, true), "карта открылась и закрылась: " .. l)
    local open, close = l:match("open=(%d+) close=(%d+)")
    t.ok(tonumber(open) >= OPEN_MS and tonumber(close) >= OPEN_MS, "время ожидания настоящее, не 0: " .. l)
  end
  t.eq(lines("riddle: ROSE done")[1], "riddle: ROSE done n=2 opened=2 closed=2")
  t.eq(Diary.map, nil, "карта закрыта в конце")
  t.eq(io.open(dir .. "/testmode", "r"), nil, "testmode одноразовый")
end

function T.test_map_that_never_opens_is_logged_not_waited_forever()
  local Diary = start(false, true, "rose=1")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("riddle: ROSE cycle 1 open=-1 close=-1"), 1)
  t.eq(lines("riddle: ROSE done")[1], "riddle: ROSE done n=1 opened=0 closed=0")
end

function T.test_closed_seal_aborts_the_mode_and_feeds_no_rose()
  local Diary = start(true, false, "rose=2")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("ERROR riddle: ROSE seal closed"), 1, "печать закрыта: строка ERROR")
  t.eq(Diary.fed, 0, "ни одной розы в модель")
  t.eq(#lines("riddle: ROSE cycle"), 0)
  t.eq(#lines("riddle: ROSE done"), 0)
end

function T.test_map_left_open_by_a_failed_close_is_closed_not_counted_as_a_new_opening()
  local Diary = start("open_only", true, "rose=2")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  local cycles = lines("riddle: ROSE cycle")
  t.eq(#cycles, 2)
  t.ok(cycles[1]:match("^riddle: ROSE cycle 1 open=%d+ close=%-1$"), cycles[1])
  t.eq(cycles[2], "riddle: ROSE cycle 2 open=-1 close=-1")
  t.eq(lines("riddle: ROSE done")[1], "riddle: ROSE done n=2 opened=1 closed=0")
  t.eq(Diary.closed_by[1], "devtest", "карта закрыта штатно closeMap")
  t.eq(#Diary.closed_by, 1)
  t.eq(Diary.map, nil)
end

-- таймер раунда виджета закрытого (canvas = nil) не срабатывает; открытого — срабатывает. Без проверки раунд писал бы
-- розу в уже закрытый виджет
function T.test_roseSchedule_runs_only_while_the_widget_is_open()
  local Diary = newDiary(true, true)
  local hit = 0
  Diary:roseSchedule(1, function() hit = hit + 1 end)
  Diary.canvas = nil
  Diary:run(5000)
  t.eq(hit, 0, "виджет закрыт — таймер молчит")
  Diary.canvas = {}
  Diary:roseSchedule(1, function() hit = hit + 1 end)
  Diary:run(10000)
  t.eq(hit, 1, "виджет открыт — таймер сработал")
end

-- сон посреди подачи розы снимает задачи self:schedule — подача обрывается, и раунд раньше умирал молча
function T.test_sleep_in_the_middle_of_the_feed_is_logged_not_silent()
  local Diary = start(true, true, "rose=2")
  Diary:maybeStartTest()
  Diary:run(2500) -- подача розы идёт (старт через 2 с)
  t.ok(Diary.fed > 0 and Diary.fed < 50, "подача началась и не кончилась: " .. Diary.fed)
  Diary:sleep()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("riddle: ROSE aborted (sleep)"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: ROSE done"), 0, "раунд не доведён до конца")
end

-- сон, пока раунд ждёт карту: следующий цикл не пишет розу под закрытой печатью (это сообщение модели)
function T.test_sleep_while_waiting_stops_before_the_next_rose()
  local Diary = start(false, true, "rose=3")
  Diary:maybeStartTest()
  Diary:run(60 * 1000) -- первая роза подана, карта не открывается, идёт ожидание
  local fed = Diary.fed
  t.ok(fed > 0, "роза подана")
  Diary:sleep()
  Diary:run(10 * 60 * 1000)
  t.eq(Diary.fed, fed, "под закрытой печатью роз больше нет")
  t.eq(#lines("riddle: ROSE aborted (sleep)"), 1, table.concat(log, "\n"))
end

-- rose=0 — нулевой прогон: строка done с пометкой, а не голое «n=0»
function T.test_rose_0_is_marked_as_a_zero_run()
  local Diary = start(true, true, "rose=0")
  Diary:maybeStartTest()
  Diary:run(60 * 1000)
  t.eq(lines("riddle: ROSE done")[1], "riddle: ROSE done n=0 opened=0 closed=0 (zero run)")
  t.eq(Diary.fed, 0)
end

-- последний цикл не закрыл карту (close=-1): по окончании режима карту закрывает сам режим
function T.test_map_left_open_by_the_last_cycle_is_closed_at_the_end()
  local Diary = start("open_only", true, "rose=1")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  local cycles = lines("riddle: ROSE cycle")
  t.ok(cycles[1]:match("^riddle: ROSE cycle 1 open=%d+ close=%-1$"), cycles[1])
  t.eq(lines("riddle: ROSE done")[1], "riddle: ROSE done n=1 opened=1 closed=0 (map left open, closed)")
  t.eq(Diary.map, nil, "карта закрыта в конце режима")
  t.eq(Diary.closed_by[1], "devtest")
  t.eq(#Diary.closed_by, 1)
end

-- подача, которую сторож уже объявил потерянной ("feed lost"), потом всё же дошла до конца: раунд дальше не идёт
function T.test_late_feed_after_the_watchdog_does_not_continue_the_round()
  local Diary = start(false, true, "rose=2")
  Diary.slow = 5 -- подача идёт в 5 раз медленнее, чем рассчитан сторож
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("riddle: ROSE aborted (feed lost)"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: ROSE cycle"), 0, "поздний конец подачи раунд не продолжил: " .. table.concat(log, "\n"))
  t.eq(#lines("riddle: ROSE done"), 0)
end

-- сон, пока раунд ждёт закрытия карты: карту закрыл сон, не роза — closed не растёт
function T.test_sleep_while_waiting_for_the_close_is_not_counted_as_closed()
  local Diary = start(true, true, "rose=2")
  local UIManager = require("ui/uimanager")
  local per_rose = 0
  for _, st in ipairs(devtest.roseStrokes()) do per_rose = per_rose + #st.p / 2 + 1 end
  local feed = Diary.gd.feedEvent
  Diary.gd.feedEvent = function(g, tevs)
    feed(g, tevs)
    if Diary.fed == 2 * per_rose then -- вторая роза (на пергаменте) подана целиком
      UIManager:scheduleIn(0.5, function() Diary:sleep() end) -- таймер UIManager сон не снимает
    end
  end
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  local cycle = lines("riddle: ROSE cycle 1")[1]
  t.ok(cycle and cycle:match("^riddle: ROSE cycle 1 open=%d+ close=%-1 %(sleep%)$"), tostring(cycle))
  t.eq(#lines("riddle: ROSE aborted (sleep)"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: ROSE done"), 0)
end

-- сторож «feed lost» при открытой карте: режим кончается закрытой картой, а не оставляет её открытой
function T.test_aborted_round_closes_the_map_it_left_open()
  local Diary = start("open_only", true, "rose=2")
  Diary:maybeStartTest()
  local seen
  for limit = 500, 5 * 60 * 1000, 500 do
    Diary:run(limit)
    if Diary.map then
      seen = true
      break
    end
  end
  t.ok(seen, "карта открылась")
  Diary.slow = 5 -- вторая подача (роза на пергаменте) — медленная: сторож её бросает
  -- сразу после обрыва: брошенная подача потом дойдёт до конца и розой снова откроет карту (двойник на неё реагирует)
  for limit = clock + 500, clock + 5 * 60 * 1000, 500 do
    Diary:run(limit)
    if #lines("riddle: ROSE aborted") > 0 then break end
  end
  t.eq(#lines("riddle: ROSE aborted (feed lost)"), 1, table.concat(log, "\n"))
  t.eq(Diary.map, nil, "карта закрыта в конце режима")
  t.eq(Diary.closed_by[1], "devtest")
  t.eq(#Diary.closed_by, 1)
end

-- задачи подачи двойника (self:schedule), которые ещё не отработали и не сняты
local function pendingFeedJobs()
  local n = 0
  for _, j in ipairs(jobs) do
    if j.id and not j.dead and not j.done then n = n + 1 end
  end
  return n
end

-- подача, которую сторож объявил потерянной, дальше не идёт: хвост розы не открывает карту заново
function T.test_feed_given_up_by_the_watchdog_stops_and_does_not_reopen_the_map()
  local Diary = start(true, true, "rose=2")
  Diary.slow = 5 -- подача идёт в 5 раз медленнее, чем рассчитан сторож
  Diary:maybeStartTest()
  for limit = 500, 5 * 60 * 1000, 500 do
    Diary:run(limit)
    if #lines("riddle: ROSE aborted") > 0 then break end
  end
  t.eq(#lines("riddle: ROSE aborted (feed lost)"), 1, table.concat(log, "\n"))
  local fed = Diary.fed
  Diary:run(30 * 60 * 1000)
  t.eq(Diary.fed, fed, "после обрыва в feedEvent не подано ни одного события")
  t.eq(Diary.map, nil, "хвост брошенной розы карту не открыл")
  t.eq(pendingFeedJobs(), 0, "таймеров подачи не осталось")
  t.eq(#lines("riddle: ROSE aborted"), 1, "обрыв один: " .. table.concat(log, "\n"))
  t.eq(#lines("riddle: ROSE feed stopped"), 1, "остановка подачи записана в лог: " .. table.concat(log, "\n"))
end

-- сон закрыл печать посреди подачи, а задачи подачи не снялись: следующий штрих не подаётся
function T.test_sleep_in_the_middle_of_the_feed_stops_the_feed_and_the_map_stays_shut()
  local Diary = start(true, true, "rose=2")
  Diary:maybeStartTest()
  Diary:run(2500) -- подача розы идёт (старт через 2 с)
  t.ok(Diary.fed > 0 and Diary.fed < 50, "подача началась и не кончилась: " .. Diary.fed)
  Diary.controller.seal_open = false -- сон: печать закрыта; задачи self:schedule здесь остаются
  local fed = Diary.fed
  Diary:run(30 * 60 * 1000)
  t.ok(Diary.fed <= fed + 1, "после сна подача встала (не больше одного события): " .. Diary.fed .. " из " .. fed)
  t.eq(Diary.map, nil, "карта не открыта")
  t.eq(pendingFeedJobs(), 0, "таймеров подачи не осталось")
  t.eq(#lines("riddle: ROSE aborted (sleep)"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: ROSE feed stopped"), 1, "остановка подачи записана в лог")
end

t.run(T)
