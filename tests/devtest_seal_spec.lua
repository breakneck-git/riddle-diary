-- devtest seal=<страницы>: знак печати пером без человека. Фигуры — своя синтетика (фикстуры тестов на устройство не
-- уезжают); здесь закреплено то, чего от них ждёт чек-лист на Kindle: A и A2 — один знак, B — другой, tiny — мелкий,
-- но не случайное касание, ни одна не треугольник и не роза. Режим работает с отдельным образцом (app.test_key_path).
-- Виджет в прогоне — упрощённый двойник: штрихи из feedEvent собираются в страницу, через idle_s тишины страница
-- получает ответ по своему виду (знак A — фраза, треугольник — страница состояния), время — виртуальные часы.
require("sqlite_shim") -- riddle.app тянет хранилище
local t = require("t")
local glyph = require("riddle.glyph")
local triangle = require("riddle.triangle")
local rose = require("riddle.rose")
local png = require("riddle.png")
local seal = require("riddle.seal")
local app = require("riddle.app")
local stand = require("seal_stand")

local clock = 0 -- мс
local log = {}
local jobs = {}
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
local PHRASE = "Печать открыта, входи."

local function lines(prefix)
  local out = {}
  for _, l in ipairs(log) do
    if l:find(prefix, 1, true) then out[#out + 1] = l end
  end
  return out
end

local function fig(name) return devtest.sealFigure(name) end

local function newDiary(dir)
  clock, log, jobs = 0, {}, {}
  local Diary = { canvas = {}, status_opened = 0 }
  function Diary:schedule(delay, fn)
    jobs[#jobs + 1] = { at = clock + delay * 1000, fn = fn }
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
  function Diary:closeStatus() Diary.status = nil end
  function Diary:onSuspend() Diary:closeStatus() end
  function Diary:revealAnswer(text, _, _, kind)
    Diary.answer = { phase = "hold", kind = kind }
    Diary.shown = text
  end
  -- знак A — одна фраза; треугольник — страница состояния; остальное молчит (мелочь, чужой знак)
  local sample = fig("A")
  local page, cur, page_task = {}, nil, nil
  local function pageDone()
    local pg = page
    page = {}
    if triangle.detect(pg) then
      Diary:schedule(1, function() Diary.status = {} Diary.status_opened = Diary.status_opened + 1 end)
    elseif glyph.match(pg, { sample }) then
      Diary:schedule(1, function() Diary:revealAnswer(PHRASE, 0, true, "key") end)
    end
  end
  Diary.gd = { feedEvent = function(_, tevs)
    for _, tev in ipairs(tevs) do
      if tev.id == -1 then
        cur = nil
        Diary:cancel(page_task)
        if #page > 0 then page_task = Diary:schedule(IDLE_MS / 1000, pageDone) end
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

local function tmpdir()
  local dir = os.tmpname()
  os.remove(dir)
  os.execute('mkdir -p "' .. dir .. '"')
  return dir
end

local function start(content)
  local dir = tmpdir()
  local f = io.open(dir .. "/testmode", "w"); f:write(content); f:close()
  return newDiary(dir), dir
end

local T = {}

-- фигуры: что обещает чек-лист
function T.test_A_and_A2_are_one_sign()
  local ok, d = glyph.match(fig("A2"), { fig("A") })
  t.ok(ok, "A2 совпадает с образцом A, расстояние " .. tostring(d))
  t.ok(glyph.match(fig("A"), { fig("A2") }), "и наоборот")
end

function T.test_B_is_another_sign()
  local ok, d = glyph.match(fig("B"), { fig("A") })
  t.eq(ok, false, "B не совпадает с A, расстояние " .. tostring(d))
  t.ok(d > 2 * glyph.DIST, "заметно другой, не на грани допуска: " .. tostring(d))
end

function T.test_A_A2_B_fit_the_key_and_are_neither_triangle_nor_rose()
  for _, name in ipairs({ "A", "A2", "B" }) do
    local s = fig(name)
    local fits, why = glyph.fits(s)
    t.eq(fits, true, name .. " годится в знак: " .. tostring(why))
    t.ok(not triangle.detect(s), name .. " не треугольник")
    t.ok(not rose.detect(s), name .. " не роза")
    t.ok(#s <= 2, name .. ": штрихов 1–2")
  end
end

function T.test_tiny_is_under_glyph_SIZE_but_no_accidental_touch()
  local fits, why = glyph.fits(fig("tiny"))
  t.eq(fits, false)
  t.eq(why, "size")
  -- рамка PNG страницы, как виджет считает sampleBox: поля 8 px, масштаб 2 (CFG.sample_scale)
  local p = fig("tiny")[1].p
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #p - 1, 2 do
    x0, y0 = math.min(x0, p[i]), math.min(y0, p[i + 1])
    x1, y1 = math.max(x1, p[i]), math.max(y1, p[i + 1])
  end
  local w, h = math.floor((x1 - x0 + 16) / 2) + 1, math.floor((y1 - y0 + 16) / 2) + 1
  t.eq(png.tiny(w, h), false, string.format("PNG %dx%d — не случайное касание", w, h))
end

function T.test_triangle_page_is_a_triangle()
  t.ok(triangle.detect(fig("triangle")))
end

function T.test_figures_are_deterministic_and_A2_is_not_a_copy_of_A()
  t.eq(table.concat(fig("A")[1].p, ","), table.concat(fig("A")[1].p, ","))
  t.ok(table.concat(fig("A")[1].p, ",") ~= table.concat(fig("A2")[1].p, ","), "A2 — дрожание, не копия")
end

function T.test_parseSeal_reads_the_testmode_line()
  t.eq(table.concat(devtest.parseSeal("seal=A,B,A2,triangle,tiny"), "|"), "A|B|A2|triangle|tiny")
  t.eq(table.concat(devtest.parseSeal("exit=1 seal=A"), "|"), "A")
  t.eq(devtest.parseSeal("rose=3"), nil)
  t.eq(devtest.parseSeal("cycles=3"), nil)
end

-- отдельный образец в тестовом режиме
function T.test_testmode_seal_takes_its_own_key_path()
  t.ok(app.test_key_path("seal=A,B") ~= seal.KEY_PATH, "в testmode образец — не ключ владельца")
  t.eq(app.test_key_path("seal=A,B"), app.TEST_KEY_PATH)
  t.eq(app.test_key_path("exit=1 seal=A"), app.TEST_KEY_PATH)
  t.eq(app.TEST_KEY_PATH, "/mnt/us/riddle/test/seal_key.lua")
end

function T.test_other_testmodes_and_no_testmode_keep_the_owners_key()
  t.eq(app.test_key_path("rose=2"), nil)
  t.eq(app.test_key_path("cycles=3 exit=1"), nil)
  t.eq(app.test_key_path(nil), nil)
  t.eq(app.test_key_path(""), nil)
end

local function controller(key_path)
  return app.new_controller{
    cfg = { seal = stand.key() },
    memory = nil,
    http = { post = function() error("сеть не нужна") end },
    clock = function() return 0 end,
    wall = function() return 1000 end,
    log = function() end,
    read_file = function() return "PNG" end,
    remove = function() end,
    file_mtime = function() return nil end,
    random = function() return 1 end,
    key_path = key_path,
  }
end

function T.test_controller_takes_the_path_it_is_given_and_defaults_to_the_owners()
  t.ok(controller(app.test_key_path("seal=A")).key_path ~= seal.KEY_PATH, "в testmode — не путь владельца")
  t.eq(controller(app.test_key_path("seal=A")).key_path, app.TEST_KEY_PATH)
  t.eq(controller(app.test_key_path("rose=1")).key_path, seal.KEY_PATH, "без seal= — образец владельца")
  t.eq(controller(app.test_key_path(nil)).key_path, seal.KEY_PATH, "без testmode — образец владельца")
end

function T.test_the_sample_is_written_to_the_test_path_not_the_owners()
  local dir = tmpdir()
  local path = dir .. "/test/seal_key.lua"
  os.execute('mkdir -p "' .. dir .. '/test"')
  local ctl = controller(path)
  t.eq(ctl:key_page(fig("A")), require("riddle.texts").key_again)
  t.eq(ctl:key_page(fig("A2")), require("riddle.texts").key_saved)
  t.ok(io.open(path, "r"), "образец лёг в тестовый путь")
end

-- прогон страниц
function T.test_seal_run_logs_every_page_with_its_phrase()
  local Diary, dir = start("seal=A,B,A2,triangle,tiny")
  Diary:maybeStartTest()
  Diary:run(30 * 60 * 1000)
  local all = table.concat(log, "\n")
  t.eq(#lines("riddle: devtest seal start pages=5"), 1, all)
  t.eq(lines("riddle: devtest seal page A ->")[1], "riddle: devtest seal page A -> " .. PHRASE, all)
  t.eq(lines("riddle: devtest seal page B ->")[1], "riddle: devtest seal page B -> nil", all)
  t.eq(lines("riddle: devtest seal page A2 ->")[1], "riddle: devtest seal page A2 -> " .. PHRASE, all)
  t.eq(lines("riddle: devtest seal page triangle ->")[1], "riddle: devtest seal page triangle -> nil", all)
  t.eq(lines("riddle: devtest seal page tiny ->")[1], "riddle: devtest seal page tiny -> nil", all)
  t.eq(#lines("riddle: devtest seal done pages=5"), 1, all)
  t.eq(Diary.status_opened, 1, "треугольник открыл страницу состояния")
  t.eq(Diary.status, nil, "и режим закрыл её сам")
  t.eq(io.open(dir .. "/testmode", "r"), nil, "testmode одноразовый")
  local order = {}
  for _, l in ipairs(lines("riddle: devtest seal page ")) do order[#order + 1] = l:match("page (%S+) %->") end
  t.eq(table.concat(order, ","), "A,B,A2,triangle,tiny", "порядок — как в сценарии")
end

function T.test_phrase_is_cut_to_the_first_words()
  local Diary = start("seal=A")
  Diary:maybeStartTest()
  local reveal = Diary.revealAnswer
  Diary.revealAnswer = function(self, _, ...) return reveal(self, "один два три четыре пять шесть семь", ...) end
  Diary:run(10 * 60 * 1000)
  t.eq(lines("riddle: devtest seal page A ->")[1], "riddle: devtest seal page A -> один два три четыре пять")
end

function T.test_log_has_names_and_phrases_not_strokes()
  local Diary = start("seal=A,tiny")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.ok(#lines("riddle: devtest seal page") == 2, table.concat(log, "\n"))
  for _, l in ipairs(lines("riddle: devtest seal")) do
    t.ok(not l:find("%d+,%d+"), "в строке нет координат: " .. l)
  end
end

function T.test_unknown_page_draws_nothing()
  local Diary = start("seal=A,oops")
  Diary:maybeStartTest()
  Diary:run(10 * 60 * 1000)
  t.eq(#lines("ERROR riddle: devtest seal unknown page oops"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: devtest seal start"), 0)
  t.eq(#lines("riddle: devtest seal page"), 0, "ни одной страницы не нарисовано")
end

function T.test_sleep_aborts_the_run()
  local Diary = start("seal=A,B,A")
  Diary:maybeStartTest()
  Diary:run(10 * 1000)
  Diary.slept = 1
  Diary:run(30 * 60 * 1000)
  t.eq(#lines("riddle: devtest seal aborted (sleep)"), 1, table.concat(log, "\n"))
  t.eq(#lines("riddle: devtest seal done"), 0)
end

t.run(T)
