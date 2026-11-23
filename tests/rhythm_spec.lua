-- Ритм напоминаний о задачах: счёт из меток реплик сессии (Memory:marks), режим ответа, выбор 1–3 задач
local t = require("t")
local rhythm = require("riddle.rhythm")

local T = {}

-- метки сессии: "-" — owner без задачи (""), "?" — owner «неизвестно» (nil), "#id" — owner о задаче id,
-- "d" — diary без предложения, "d:<offer>" — diary с предложением
local function marks(spec)
  local out = {}
  for w in spec:gmatch("%S+") do
    if w == "-" then out[#out + 1] = { role = "owner", task = "" }
    elseif w == "?" then out[#out + 1] = { role = "owner" }
    elseif w:sub(1, 1) == "#" then out[#out + 1] = { role = "owner", task = w:sub(2) }
    elseif w == "d" then out[#out + 1] = { role = "diary" }
    else out[#out + 1] = { role = "diary", offer = (w:gsub("^d:", ""):gsub("_", " ")) } end
  end
  return out
end

-- n записей без задачи парой owner/diary; offers[i] — предложение у i-го ответа
local function unrelated(n, offers)
  local parts = {}
  for i = 1, n do
    parts[#parts + 1] = "-"
    parts[#parts + 1] = (offers and offers[i]) and ("d:" .. offers[i]) or "d"
  end
  return marks(table.concat(parts, " "))
end

local function items(n, skip)
  local out = {}
  for i = 1, n do
    if not (skip and skip[i]) then out[#out + 1] = { label = "t" .. i, id = "id" .. i, title = "Дело " .. i } end
  end
  return out
end

local function ids(list)
  local out = {}
  for i, it in ipairs(list) do out[i] = it.id end
  return table.concat(out, " ")
end

function T.test_first_entry_names_tasks()
  local mode, cond = rhythm.mode({}, true, true)
  t.eq(mode, "name"); t.eq(cond, false, "первая запись — безусловно")
end

function T.test_first_entry_without_tasks_gives_themes()
  local mode, cond = rhythm.mode({}, false, true)
  t.eq(mode, "themes"); t.eq(cond, false)
end

function T.test_third_unrelated_is_drift_sixth_is_name()
  t.eq(rhythm.count(unrelated(2)), 2)
  local mode, cond = rhythm.mode(unrelated(2), true, true)
  t.eq(mode, "drift", "3-я подряд без задачи"); t.eq(cond, true)
  t.eq((rhythm.mode(unrelated(1), true, true)), "none", "2-я")
  t.eq((rhythm.mode(unrelated(3), true, true)), "none", "4-я")
  t.eq((rhythm.mode(unrelated(4), true, true)), "none", "5-я")
  mode, cond = rhythm.mode(unrelated(5), true, true)
  t.eq(mode, "name", "6-я"); t.eq(cond, true)
  t.eq((rhythm.mode(unrelated(5), false, true)), "themes", "6-я без задач — темы")
  -- предложение на 6-й не легло (сбой ритма, записи diary, ответ «неизвестно»): 7-я, 8-я — всё равно предложение
  t.eq((rhythm.mode(unrelated(6), true, true)), "name", "7-я без предложения на 6-й")
  t.eq((rhythm.mode(unrelated(7), false, true)), "themes", "8-я без задач")
  t.eq((rhythm.mode(unrelated(2), false, true)), "none", "3-я без задач — намёка нет")
end

-- 1…12 без задачи, на 6-й предложение: 9-я — намёк, 12-я — предложение
function T.test_after_offer_count_restarts_9_drift_12_name()
  local offers = { [6] = "id1_id2" }
  local want = { [3] = "drift", [6] = "name", [9] = "drift", [12] = "name" }
  for k = 2, 12 do
    local m = unrelated(k - 1, offers)
    local mode = rhythm.mode(m, true, true)
    t.eq(mode, want[k] or "none", "запись " .. k)
  end
  t.eq(rhythm.count(unrelated(8, offers)), 2, "после предложения счёт с нуля")
end

function T.test_task_entry_resets_and_drift_does_not()
  t.eq(rhythm.count(marks("- d - d #id1 d")), 0, "запись о задаче обнуляет")
  t.eq(rhythm.count(marks("- d - d #id1 d - d")), 1)
  -- намёк (drift) меток не пишет: diary без offer — счёт идёт дальше
  t.eq(rhythm.count(marks("- d - d - d - d")), 4, "намёк не обнуляет")
  t.eq(rhythm.count(marks("- d:themes - d")), 1, "темы — предложение, обнуляют")
end

function T.test_unknown_does_not_count()
  t.eq(rhythm.count(marks("- d ? d - d")), 2, "неизвестно не растит")
  t.eq(rhythm.count(marks("- d - d ? d")), 2, "и не обнуляет")
  t.eq((rhythm.mode(marks("- d ? d - d"), true, true)), "drift", "неизвестно в середине — счёт тот же")
  t.eq((rhythm.mode(marks("? d"), true, true)), "none", "запись owner есть — уже не первая")
end

-- прямой вопрос не о делах ("ask"): ответ только на него, напоминание откладывается — счёт не растёт и не
-- обнуляется, первая запись остаётся первой (владелец 2026-10-26, 812f)
function T.test_direct_question_defers_reminder()
  t.eq(rhythm.count(marks("- d - d #ask d")), 2, "вопрос не растит")
  t.eq(rhythm.count(marks("- d #ask d - d")), 2, "и не обнуляет")
  local mode, cond = rhythm.mode(marks("#ask d #ask d"), true, true)
  t.eq(mode, "name", "одни вопросы — запись всё ещё первая"); t.eq(cond, false)
  t.eq((rhythm.mode(marks("- d - d #ask d"), true, true)), "drift", "намёк — на следующую после вопроса")
  t.eq((rhythm.mode(marks("#ask d - d:id1"), true, true)), "none", "напоминание легло — дальше обычный счёт")
end

-- после паузы от часа (rhythm.PAUSE_S) первая запись — снова «первая»: дела называются безусловно; сессия при этом
-- та же (владелец 2026-10-26, 812e). Пары owner/diary: { ts, task, offer }
local function timed(spec)
  local out = {}
  for _, p in ipairs(spec) do
    out[#out + 1] = { role = "owner", ts = p[1], task = p[2] }
    out[#out + 1] = { role = "diary", ts = p[1], offer = p[3] }
  end
  return out
end

function T.test_first_entry_after_pause_names_tasks()
  t.eq(rhythm.PAUSE_S, 3600, "пауза — час")
  local m = timed({ { 0, "", "id1" }, { 100, "" } })
  local mode, cond = rhythm.mode(m, true, true, 100 + rhythm.PAUSE_S)
  t.eq(mode, "name", "после паузы — дела"); t.eq(cond, false, "безусловно, как первая")
  t.eq((rhythm.mode(m, true, true, 100 + rhythm.PAUSE_S - 1)), "none", "пауза меньше часа — обычный счёт")
  t.eq((rhythm.mode(m, true, true)), "none", "без now — как раньше")
  -- пауза внутри сессии: считается только то, что после неё
  local mid = timed({ { 0, "" }, { 10, "" }, { 5000, "", "id2" }, { 5100, "" } })
  t.eq((rhythm.mode(mid, true, true, 5200)), "none", "после паузы предложение было — счёт с него")
  -- граница: пауза между записями ровно PAUSE_S — уже пауза
  local edge = timed({ { 0, "", "id1" }, { rhythm.PAUSE_S, "ask" } })
  t.eq((rhythm.mode(edge, true, true, rhythm.PAUSE_S + 10)), "name", "пауза ровно час между записями")
  t.eq((rhythm.mode(timed({ { 0, "", "id1" }, { rhythm.PAUSE_S - 1, "ask" } }), true, true, rhythm.PAUSE_S + 10)),
    "none", "на секунду меньше — не пауза")
  local ask = timed({ { 0, "", "id1" }, { 5000, "ask" } })
  t.eq((rhythm.mode(ask, true, true, 5100)), "name", "после паузы одни вопросы — напоминание ещё ждёт")
  -- без дел пауза ничего не меняет: темы — только первой записью сессии
  local themes = timed({ { 0, "", "themes" } })
  t.eq((rhythm.mode(themes, false, true, rhythm.PAUSE_S)), "none", "темы после паузы — нет")
  -- старые метки без ts — паузы не видно
  t.eq((rhythm.mode(marks("- d:id1"), true, true, 10 * rhythm.PAUSE_S)), "none", "без ts — как раньше")
end

function T.test_no_titles_no_themes()
  t.eq((rhythm.mode({}, false, false)), "none", "первая без задач и названий")
  t.eq((rhythm.mode(unrelated(5), false, false)), "none", "6-я без задач и названий")
  t.eq((rhythm.mode({}, true, false)), "name", "задачи есть — названия не нужны")
end

function T.test_offered_by_last_offer_oldest_first()
  local m = marks("- d:id1_id2_id3 - d:id4_id5 - d:themes - d:id2_id1")
  t.eq(table.concat(rhythm.offered(m), " "), "id3 id4 id5 id2 id1", "по последнему показу, темы — не id")
  t.eq(#rhythm.offered(marks("- d - d")), 0)
end

function T.test_pick_skips_offered_then_oldest_offered()
  t.eq(ids(rhythm.pick(items(5), { "id1", "id2" }, 3)), "id3 id4 id5")
  t.eq(ids(rhythm.pick(items(5), {}, 3)), "id1 id2 id3", "ничего не предлагал — с головы, не больше трёх")
  t.eq(ids(rhythm.pick(items(5), { "id1", "id2", "id3", "id4" }, 3)), "id5", "есть непредложенные — только они")
  t.eq(ids(rhythm.pick(items(2), { "id2", "id1" }, 3)), "id2 id1", "все предлагались — давние первыми")
  t.eq(#rhythm.pick({}, {}, 3), 0)
end

-- четыре предложения подряд: {1,2,3} → {4,5} → {1,2,3} → {4,5,1}
function T.test_pick_rotates_by_last_offer()
  local m, got = {}, {}
  for i = 1, 4 do
    local picked = rhythm.pick(items(5), rhythm.offered(m), 3)
    got[i] = ids(picked)
    m[#m + 1] = { role = "owner", task = "" }
    m[#m + 1] = { role = "diary", offer = ids(picked) }
  end
  t.eq(got[1], "id1 id2 id3")
  t.eq(got[2], "id4 id5")
  t.eq(got[3], "id1 id2 id3")
  t.eq(got[4], "id4 id5 id1", "по последнему показу, а не по первому")
end

function T.test_pick_skips_offered_now_closed()
  local open = items(5, { [1] = true }) -- задача 1 закрыта и выпала из блока
  t.eq(ids(rhythm.pick(open, { "id1", "id2", "id3", "id4", "id5" }, 3)), "id2 id3 id4")
end

-- ядро не знает источник: ни адаптера Notion, ни синхронизации, ни классификации
-- (require через «/» в плагине запрещён отдельно — tests/require_style_spec.lua)
function T.test_rhythm_requires_no_source_module()
  for _, name in ipairs({ "rhythm", "controller", "prompt" }) do
    local path = "plugin/riddlediary.koplugin/riddle/" .. name .. ".lua"
    local f = assert(io.open(path, "rb"), path)
    local s = f:read("*a")
    f:close()
    for _, bad in ipairs({ "riddle.notion", "riddle.sync", "riddle.classify" }) do
      t.ok(not s:find(bad, 1, true), path .. ": " .. bad)
    end
  end
end

t.run(T)
