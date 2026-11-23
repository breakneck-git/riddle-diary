-- Последняя реплика дневника стоит на экране, пока кто-то не коснётся пальцем (владелец
-- 2026-10-23); растворение запускает только первое касание. Если за ней ещё ответы — прежнее
-- удержание на answer_hold_s и смена. Виджет без KOReader не поднять: правило — в riddle.hold,
-- проводка — храповиком по тексту исходника.
local t = require("t")
local hold = require("riddle.hold")

local T = {}

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local WIDGET = read("plugin/riddlediary.koplugin/riddle_diarywidget.lua")

function T.test_last_answer_has_no_timer()
  t.eq(hold.seconds(6, 0, 0), nil, "ни очереди, ни ответов в пути — таймера растворения нет")
end

function T.test_queued_answer_keeps_timed_hold()
  t.eq(hold.seconds(6, 1, 0), 6, "второй ответ в очереди — первый уходит как раньше")
  t.eq(hold.seconds(6, 2, 0), 6)
end

-- реплика на перебивание, чья страница оказалась случайным касанием: ответа за ней не будет —
-- обычное удержание, а не «до касания» (Notion 40413e60)
function T.test_released_interjection_has_timer_even_alone()
  t.eq(hold.seconds(6, 0, 0, "interject"), nil, "пока ответ может прийти — как ответ")
  t.eq(hold.seconds(6, 0, 0, "interject", true), 6, "ответа не будет — таймер")
end

-- раздумье: остаток think_owed_s, если за ним тоже раздумье; без остатка — сразу; никого — до касания
function T.test_thinking_phrase_owes_remaining_hold()
  t.eq(hold.seconds(6, 1, 1, "think", nil, 7.5), 7.5, "за ним раздумье — стоит остаток")
  t.eq(hold.seconds(6, 1, 1, "think", nil, -2), 0, "остаток вышел — уходит сразу")
  t.eq(hold.seconds(6, 1, 1, "think"), 0, "остатка нет (за ним ответ или отказ) — сразу")
  t.eq(hold.seconds(6, 0, 1, "think", nil, 7.5), nil, "за ним никого — ждёт, пока не придут")
end

function T.test_answer_in_flight_keeps_timed_hold()
  t.eq(hold.seconds(6, 0, 1), 6, "страница ещё думается — текущий ответ не вечный")
end

-- имя функции Diary:..., внутри которой стоит позиция pos
local function enclosing(src, pos)
  local name
  for start, fname in src:gmatch("()function Diary:([%w_]+)") do
    if start > pos then break end
    name = fname
  end
  return name
end

function T.test_hold_timer_scheduled_only_through_hold_seconds()
  local from, n = 1, 0
  while true do
    local s, e = WIDGET:find("CFG.answer_hold_s", from, true)
    if not s then break end
    n = n + 1
    t.eq(enclosing(WIDGET, s), "holdFor", "answer_hold_s — только в holdFor")
    from = e + 1
  end
  t.eq(n, 1, "одно место")
  local holdfor = WIDGET:match("function Diary:holdFor%(.-\nend")
  t.ok(holdfor and holdfor:find("hold.seconds(", 1, true), "holdFor спрашивает riddle.hold")
  local arm = WIDGET:match("function Diary:armHold%(.-\nend")
  t.ok(arm and arm:find("self:holdFor(", 1, true), "armHold ставит таймер по holdFor")
  local sleepy = WIDGET:match("function Diary:replySurvivesSleep%(.-\nend")
  t.ok(sleepy and sleepy:find("self:holdFor(", 1, true), "сон спрашивает то же правило, что и таймер")
end

function T.test_hold_armed_when_reveal_ends_and_when_a_follower_arrives()
  local reveal = WIDGET:match("function Diary:revealAnswer%(.-\nend")
  t.ok(reveal:find('a.phase = "hold"', 1, true) and reveal:find("self:armHold(a)", 1, true),
    "конец проявления -> armHold")
  local nxt = WIDGET:match("function Diary:nextAnswer%(.-\nend")
  t.ok(nxt:find("armHold", 1, true), "вечный ответ получает таймер, если за ним пришёл следующий")
end

function T.test_dissolve_starts_from_touch_in_hold_phase()
  local hurry = WIDGET:match("function Diary:hurryAnswer%(.-\nend")
  t.ok(hurry and hurry:find("self:fadeAnswer()", 1, true), "касание -> растворение")
  t.ok(not hurry:find('"hold"', 1, true), "фазу hold касание не отсекает")
  local pd = WIDGET:match("function Diary:penDown%(.-\nend")
  t.ok(pd and pd:find("self:hurryAnswer()", 1, true), "penDown зовёт hurryAnswer")
end

-- фраза-раздумье уходит, как только за ней пришёл ответ (или отказ): без удержания
function T.test_think_with_follower_releases_at_once()
  t.eq(hold.seconds(6, 1, 0, "think"), 0)
  t.eq(hold.seconds(6, 2, 1, "think"), 0)
end

-- одна фраза-раздумье ждёт ответа (он ещё в пути) или касания: таймера нет
function T.test_think_alone_waits_for_touch()
  t.eq(hold.seconds(6, 0, 0, "think"), nil)
  t.eq(hold.seconds(6, 0, 1, "think"), nil, "ответ в пути — фраза стоит, пока он не придёт")
end

-- отказ на запись — обычное правило: при ответе в пути держится answer_hold_s и уходит
function T.test_busy_keeps_timed_hold()
  t.eq(hold.seconds(6, 0, 1, "busy"), 6)
end

-- что переживает сон (Notion 40813e60): без печати — реплика, которая стоит до касания; фраза-раздумье —
-- не реплика; с печатью сон стирает всё (иначе разговор видит любой, кто взял Kindle)
function T.test_sleep_keeps_the_answer_that_waits_for_a_touch()
  t.ok(hold.survives_sleep(false, nil, "hold", false), "ответ без таймера, печати нет — остаётся")
  t.ok(hold.survives_sleep(false, nil, "reveal", false), "проявление застал сон — остаётся")
end

function T.test_sleep_wipes_everything_under_a_seal()
  t.ok(not hold.survives_sleep(true, nil, "hold", false), "печать закрывается — страница чистая")
  t.ok(not hold.survives_sleep(true, nil, "reveal", false))
end

function T.test_sleep_wipes_think_phrase_and_fading_or_timed_answers()
  t.ok(not hold.survives_sleep(false, "think", "hold", false), "фраза-раздумье — не реплика")
  t.ok(not hold.survives_sleep(false, "think", "reveal", false))
  t.ok(not hold.survives_sleep(false, nil, "fade", false), "и так уходит")
  t.ok(not hold.survives_sleep(false, nil, "hold", true), "ответ на таймере: за ним ждут, сон их роняет")
  t.ok(not hold.survives_sleep(false, nil, "reveal", true), "и проявляющийся, если ему положен таймер")
end

function T.test_sleep_keeps_interjection_that_waits_for_a_touch()
  t.ok(hold.survives_sleep(false, "interject", "hold", false), "реплика на перебивание стоит как ответ")
end

t.run(T)
