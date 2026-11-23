require("sqlite_shim")
local t = require("t")
local memory = require("riddle.memory")

local H = 3600
local paths = {}

local function fresh()
  local path = os.tmpname()
  paths[#paths + 1] = path
  return memory.open(path), path
end

local function cleanup()
  for _, p in ipairs(paths) do os.remove(p) end
end

local tests = {}

-- база дневника после ивента 2026-10-23/24 (схема до 2026-10-24): таблица quest с ходом игры,
-- реплики пишущего — со старой ролью «legacy»
local OLD_EVENT_DB = [[
CREATE TABLE sessions(id INTEGER PRIMARY KEY, started INT, last_ts INT, summary TEXT);
CREATE TABLE entries(id INTEGER PRIMARY KEY, session_id INT, ts INT, role TEXT, text TEXT);
CREATE INDEX entries_session ON entries(session_id, ts, id);
CREATE TABLE lore(section TEXT PRIMARY KEY, text TEXT, mtime INT);
CREATE TABLE quest(key TEXT PRIMARY KEY, value INT);
INSERT INTO sessions VALUES(1, 0, 100, 'ПЕРЕСКАЗ-СТАРЫЙ');
INSERT INTO sessions VALUES(2, 5000, 5100, NULL);
INSERT INTO entries VALUES(1, 1, 50, 'legacy', 'СТАРАЯ-ЗАПИСЬ');
INSERT INTO entries VALUES(2, 1, 60, 'diary', 'СТАРЫЙ-ОТВЕТ');
INSERT INTO entries VALUES(3, 2, 5100, 'legacy', 'СЛОВО');
INSERT INTO lore VALUES('Мир', 'ЛОР-СТАРЫЙ', 7);
INSERT INTO quest VALUES('world1', 3), ('world2', 1), ('world3', 0), ('world4', 0), ('world5', 2),
  ('world6', 0), ('final_given', 0), ('final_solved', 0), ('last', 5);
]]

local function old_event_db()
  local path = os.tmpname()
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec(OLD_EVENT_DB)
  conn:close()
  return path
end

local function scalar(path, sql_text)
  local conn = require("lua-ljsqlite3/init").open(path)
  local v = conn:rowexec(sql_text)
  conn:close()
  return type(v) == "cdata" and tonumber(v) or v
end

-- старая база ивента открывается: сессии, реплики, пересказы на месте; реплики пишущего — с ролью
-- «owner»; таблицы quest больше нет, лор ивента стёрт (метка импорта — вместе с ним)
function tests.test_old_event_db_opens_and_keeps_diary()
  local path = old_event_db()
  paths[#paths + 1] = path
  local m = memory.open(path)
  local s, unsum = m:session(5200)
  t.eq(s, 2, "свежая сессия продолжается")
  t.eq(unsum, nil, "у прошлой сессии пересказ уже есть")
  local e1 = m:entries(1)
  t.eq(#e1, 2)
  t.eq(e1[1].role, "owner"); t.eq(e1[1].text, "СТАРАЯ-ЗАПИСЬ")
  t.eq(e1[2].role, "diary")
  t.eq(m:entries(2)[1].role, "owner")
  t.eq(m:summaries(5)[1], "ПЕРЕСКАЗ-СТАРЫЙ")
  t.eq(m:lore_text(), "", "лор ивента стёрт")
  t.eq(m:lore_mtime(), nil, "метки импорта лора нет: lore.md импортируется заново")
  m:add(s, "owner", "НОВАЯ", 5300)
  t.eq(m:recent(s, 12)[2].text, "НОВАЯ", "запись идёт")
  m:close()
  t.eq(scalar(path, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'quest'"), 0, "таблицы quest нет")
  t.eq(scalar(path, "PRAGMA user_version"), memory.SCHEMA_VERSION, "версия схемы")
end

-- миграция один раз: повторное открытие ничего не меняет, «legacy» больше не появляется
function tests.test_migration_is_idempotent()
  local path = old_event_db()
  paths[#paths + 1] = path
  memory.open(path):close()
  local m = memory.open(path)
  t.eq(m:entries(1)[1].role, "owner")
  m:close()
  t.eq(scalar(path, "SELECT COUNT(*) FROM entries WHERE role = 'legacy'"), 0)
  t.eq(scalar(path, "SELECT COUNT(*) FROM entries"), 3, "реплики не размножились и не пропали")
  t.eq(scalar(path, "PRAGMA user_version"), memory.SCHEMA_VERSION)
end

-- лор, залитый после миграции, второе открытие не стирает
function tests.test_reopen_keeps_new_lore()
  local path = old_event_db()
  paths[#paths + 1] = path
  local m = memory.open(path)
  m:import_lore("## Персонаж\nЛОР-НОВЫЙ", 42)
  m:close()
  m = memory.open(path)
  t.ok(m:lore_text():find("ЛОР-НОВЫЙ", 1, true), "новый лор цел")
  t.eq(m:lore_mtime(), 42)
  m:close()
end

-- сбой шага миграции не валит open: в лог, шаг откатан, база открыта и пишет
function tests.test_migration_failure_logs_and_opens()
  local path = old_event_db()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  -- exec режет по «;», триггер — одним prepare
  local stmt = conn:prepare("CREATE TRIGGER lore_guard BEFORE DELETE ON lore BEGIN SELECT RAISE(ABORT, 'ЗАЩИТА-ЛОРА'); END")
  stmt:step()
  stmt:close()
  conn:close()
  local logs = {}
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.eq(#logs, 1, "одна строка в лог")
  t.ok(logs[1] and logs[1]:find("riddle: memory migrate failed: ", 1, true), tostring(logs[1]))
  t.ok(logs[1] and logs[1]:find("ЗАЩИТА-ЛОРА", 1, true), "текст ошибки в логе")
  local s = m:session(5200)
  m:add(s, "owner", "ПОСЛЕ-СБОЯ", 5300)
  t.eq(m:recent(s, 12)[2].text, "ПОСЛЕ-СБОЯ", "база пишет")
  t.eq(m:entries(1)[1].role, "owner", "шаг 1 применён")
  m:close()
  t.eq(scalar(path, "PRAGMA user_version"), 1, "шаг 2 откатан")
  t.eq(scalar(path, "SELECT COUNT(*) FROM quest"), 9, "откат: quest на месте")
end

-- база не открылась (не SQLite) — ошибка наружу, соединение закрыто
function tests.test_open_failure_closes_connection()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local f = assert(io.open(path, "wb"))
  f:write(string.rep("не база данных ", 200))
  f:close()
  local sqlite = require("lua-ljsqlite3/init")
  local real_open, closed = sqlite.open, 0
  -- соединение — cdata, полей не добавить: прокси с методами настоящего, close считается
  sqlite.open = function(...)
    local c = real_open(...)
    return setmetatable({}, { __index = function(_, k)
      if k == "close" then return function() closed = closed + 1; return c:close() end end
      return function(_, ...) return c[k](c, ...) end
    end })
  end
  local ok = pcall(memory.open, path)
  sqlite.open = real_open
  t.ok(not ok, "open не удался")
  t.eq(closed, 1, "соединение закрыто")
end

-- ревью среза 3, п.4: проверка колонки persona_id упала не «нет колонки» (здесь sessions — вид над пропавшей
-- таблицей: «no such table») — ошибка наружу, соединение закрыто
function tests.test_open_closes_connection_when_persona_col_check_fails()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local sqlite = require("lua-ljsqlite3/init")
  local c = sqlite.open(path)
  c:exec("CREATE VIEW sessions AS SELECT 1 AS id FROM gone;")
  c:close()
  local real_open, closed = sqlite.open, 0
  sqlite.open = function(...)
    local conn = real_open(...)
    return setmetatable({}, { __index = function(_, k)
      if k == "close" then return function() closed = closed + 1; return conn:close() end end
      return function(_, ...) return conn[k](conn, ...) end
    end })
  end
  local ok, err = pcall(memory.open, path)
  sqlite.open = real_open
  t.ok(not ok, "open не удался: " .. tostring(err))
  t.ok(tostring(err):find("no such table", 1, true), "ошибка — исходная: " .. tostring(err))
  t.eq(closed, 1, "соединение закрыто")
end

-- новая база: без таблицы quest, сразу последней версии
function tests.test_new_db_has_no_quest_table()
  local m, path = fresh()
  m:close()
  t.eq(scalar(path, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'quest'"), 0)
  t.eq(scalar(path, "PRAGMA user_version"), memory.SCHEMA_VERSION)
end

function tests.test_session_continues_within_4h()
  local m = fresh()
  local s1 = m:session(0)
  m:add(s1, "owner", "привет", 0)
  local s2 = m:session(4 * H)
  t.eq(s2, s1, "та же сессия ровно через 4 ч")
  m:close()
end

function tests.test_session_new_after_4h()
  local m = fresh()
  local s1 = m:session(0)
  m:add(s1, "owner", "привет", 0)
  local s2, unsum = m:session(4 * H + 1)
  t.ok(s2 ~= s1, "новая сессия через 4 ч + 1 с")
  t.eq(unsum, s1, "прошлая сессия без пересказа")
  m:close()
end

function tests.test_session_first_has_no_unsummarized()
  local m = fresh()
  local s1, unsum = m:session(0)
  t.ok(s1 ~= nil)
  t.eq(unsum, nil, "первой сессии пересказывать нечего")
  m:close()
end

function tests.test_recent_order_and_limit()
  local m = fresh()
  local s = m:session(0)
  for i = 1, 15 do m:add(s, i % 2 == 1 and "owner" or "diary", "реплика " .. i, i) end
  local r = m:recent(s, 12)
  t.eq(#r, 12)
  t.eq(r[#r].text, "реплика 15", "последняя — самая новая")
  t.eq(r[1].text, "реплика 4", "первая — старейшая из двенадцати")
  t.eq(r[#r].role, "owner")
  m:close()
end

function tests.test_entries_all_in_order()
  local m = fresh()
  local s = m:session(0)
  m:add(s, "owner", "а", 1)
  m:add(s, "diary", "б", 2)
  local e = m:entries(s)
  t.eq(#e, 2)
  t.eq(e[1].text, "а")
  t.eq(e[2].role, "diary")
  m:close()
end

function tests.test_session_add_extends_window()
  local m = fresh()
  local s = m:session(0)
  m:add(s, "owner", "а", 3 * H)
  t.eq(m:session(3 * H + 4 * H), s, "окно считается от последней записи")
  m:close()
end

function tests.test_summaries()
  local m = fresh()
  local s1 = m:session(0)
  m:add(s1, "owner", "а", 0)
  local s2, unsum = m:session(5 * H)
  t.eq(unsum, s1)
  m:set_summary(s1, "В записях была грусть.")
  local sums = m:summaries(5)
  t.eq(#sums, 1)
  t.eq(sums[1], "В записях была грусть.")
  m:add(s2, "owner", "б", 5 * H)
  local _, unsum2 = m:session(10 * H + 1)
  t.eq(unsum2, s2, "s1 уже с пересказом — отдаётся s2")
  local _, unsum3 = m:session(10 * H + 2)
  t.eq(unsum3, s2)
  m:set_summary(s2, "Второй пересказ.")
  local sums2 = m:summaries(5)
  t.eq(sums2[1], "Второй пересказ.", "новые первыми")
  t.eq(sums2[2], "В записях была грусть.")
  m:close()
end

function tests.test_summaries_limit()
  local m = fresh()
  local now = 0
  for i = 1, 7 do
    local s = m:session(now)
    m:add(s, "owner", "x", now)
    m:set_summary(s, "пересказ " .. i)
    now = now + 5 * H
  end
  local sums = m:summaries(5)
  t.eq(#sums, 5)
  t.eq(sums[1], "пересказ 7")
  m:close()
end

-- пустая сессия помечена "" (чтобы не пересказывать повторно), но слота в окне не занимает:
-- дневник помнит ровно N последних настоящих разговоров (Notion 40f13e60-bc8d-8135)
function tests.test_summaries_skip_empty_marks()
  local m = fresh()
  local now, ids = 0, {}
  for i = 1, 5 do
    ids[#ids + 1] = m:session(now)
    m:add(ids[#ids], "owner", "x", now)
    m:set_summary(ids[#ids], "пересказ " .. i)
    now = now + 5 * H
    local e = m:session(now) -- пустая между настоящими
    m:set_summary(e, "")
    ids[#ids + 1] = e
    now = now + 5 * H
  end
  local sums = m:summaries(5)
  t.eq(#sums, 5, table.concat(sums, "|"))
  t.eq(sums[1], "пересказ 5")
  t.eq(sums[5], "пересказ 1")
  -- пометка работает: пустая сессия не вернётся к пересказу (summary не NULL)
  local _, unsum = m:session(now)
  t.eq(unsum, nil, "помеченные пустые не пересказываются")
  m:close()
end

function tests.test_lore_import_replace()
  local m = fresh()
  m:import_lore("## Мир\nА\n## Герои\nБ", 100)
  local text = m:lore_text()
  t.ok(text:find("А", 1, true), "А в лоре")
  t.ok(text:find("Б", 1, true), "Б в лоре")
  t.eq(m:lore_mtime(), 100)
  m:import_lore("## Мир\nА", 200)
  local text2 = m:lore_text()
  t.ok(text2:find("А", 1, true))
  t.ok(not text2:find("Б", 1, true), "Б исчезло")
  t.eq(m:lore_mtime(), 200)
  m:close()
end

-- текст раздела хранится без пустых строк и пробелов по краям; внутри абзацы как были
function tests.test_lore_import_trims_section_text()
  local m = fresh()
  m:import_lore("текст до заголовка\n## Мир\n\n \t А\n\nБ \n\n\n## Герои\r\n\r\nВ\r\n\r\n", 100)
  t.eq(m:lore_text(), "## Мир\nА\n\nБ\n\n## Герои\nВ", "края срезаны, внутренняя пустая строка цела")
  m:close()
end

function tests.test_lore_mtime_nil_when_empty()
  local m = fresh()
  t.eq(m:lore_mtime(), nil)
  m:close()
end

-- длина в символах (кодпойнтах), не в байтах
local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

function tests.test_lore_cap_counts_characters_not_bytes()
  local m = fresh()
  m:import_lore("## Первый\nНачало лора.\n## Второй\n" .. string.rep("я", 15000), 1)
  local text = m:lore_text()
  t.eq(chars(text), 10000, "лимит по умолчанию — 10000 знаков")
  t.ok(text:find("## Первый\nНачало лора.", 1, true), "первый раздел на месте целиком")
  t.ok(text:find("## Второй", 1, true), "заголовок второго раздела на месте")
  m:close()
end

-- потолок лора — одна величина: контроллер делит его между lore.md и миром персонажа (prompt.lore_block)
function tests.test_lore_cap_exported()
  t.eq(memory.LORE_CAP, 10000)
  local m = fresh()
  m:import_lore("## Первый\n" .. string.rep("я", memory.LORE_CAP + 500), 1)
  t.eq(chars(m:lore_text()), memory.LORE_CAP, "lore_text режет по экспортированному потолку")
  m:close()
end

function tests.test_lore_under_cap_is_untouched()
  local m = fresh()
  m:import_lore("## Мир\n" .. string.rep("я", 2000), 1)
  t.eq(chars(m:lore_text()), chars("## Мир\n") + 2000)
  m:close()
end

function tests.test_lore_cap_explicit_and_utf8_valid()
  local m = fresh()
  m:import_lore("## Мир\n" .. string.rep("я", 20000), 1)
  local text = m:lore_text(101)
  t.eq(chars(text), 101, "ровно 101 знак")
  t.ok(text:sub(-2) == "я", "последний символ целый")
  m:close()
end

function tests.test_lore_template_has_message_section_first()
  local f = assert(io.open("lore.md", "rb"))
  local md = f:read("*a")
  f:close()
  local m = fresh()
  m:import_lore(md, 1)
  local text = m:lore_text()
  t.ok(text:find("^## Что дневник должен сказать"), "важное — первым: обрезка идёт с конца")
  t.ok(chars(text) <= 10000, "шаблон укладывается в лимит")
  m:close()
end

-- ревью f87faf1: лор не запрещает сочувствие к личной утрате и не подсказывает, как тайно победить
-- реального человека; пишущий в лоре — без рода
function tests.test_lore_template_is_safe()
  local f = assert(io.open("lore.md", "rb"))
  local md = f:read("*a")
  f:close()
  for _, bad in ipairs({ "Не утешай", "не понял, что проиграл", "пишущий готов", "партнёру" }) do
    t.ok(not md:find(bad, 1, true), "в лоре: " .. bad)
  end
  t.ok(md:find("без насмешки", 1, true), "к личной боли — без насмешки")
  t.ok(md:find("не подсказывай способов", 1, true), "вред — без способов")
end

-- лор не навязывает вопрос (владелец 2026-10-25: «че за правило такое, откуда?») и даёт Волдеморту
-- голос: раздел «Как я говорю» — лексика и короткие примеры из прошлого; о пишущем — без «его»
function tests.test_lore_template_voice_without_forced_question()
  local f = assert(io.open("lore.md", "rb"))
  local md = f:read("*a")
  f:close()
  for _, bad in ipairs({ "один вопрос", "один короткий вопрос", "по одному вопросу", "вопросы с двойным дном",
    "расспрашивай", "встречный вопрос", "его ум" }) do
    t.ok(not md:find(bad, 1, true), "в лоре: " .. bad)
  end
  t.ok(md:find("\n## Как я говорю\n", 1, true), "раздел голоса")
  for _, w in ipairs({ "приют", "Пожиратели смерти", "Хогвартс", "партия", "своими словами" }) do
    t.ok(md:find(w, 1, true), "голос в лоре: " .. w)
  end
end

function tests.test_lore_sections_ordered()
  local m = fresh()
  m:import_lore("## Мир\nА\n## Персонаж\nБ\n## События\nВ", 1)
  local text = m:lore_text()
  local a, b, c = text:find("А", 1, true), text:find("Б", 1, true), text:find("В", 1, true)
  t.ok(a < b and b < c, "порядок разделов как в файле")
  m:close()
end


function tests.test_session_with_summary_is_not_offered_again()
  local m = fresh()
  local s1 = m:session(0)
  m:add(s1, "owner", "а", 0)
  m:set_summary(s1, "готово")
  local _, unsum = m:session(5 * H)
  t.eq(unsum, nil, "свежайшая прошлая уже с пересказом")
  m:close()
end

function tests.test_empty_previous_session_is_not_offered()
  local m = fresh()
  m:session(0) -- ни одной записи
  local _, unsum = m:session(5 * H)
  t.eq(unsum, nil, "пустую сессию пересказывать нечего")
  m:close()
end

function tests.test_newest_unsummarized_is_offered()
  local m = fresh()
  local s1 = m:session(0)
  m:add(s1, "owner", "а", 0)
  local s2 = m:session(5 * H)
  m:add(s2, "owner", "б", 5 * H)
  local _, unsum = m:session(10 * H + 1)
  t.eq(unsum, s2, "свежайшая, не старейшая")
  m:close()
end

-- 8 прошлых сессий с записями, у всех пересказ NULL: пересказываются только последние 5 (столько же идёт в промпт)
local function eight_old(m)
  local ids = {}
  for k = 1, 8 do
    ids[k] = m:session((k - 1) * 5 * H)
    m:add(ids[k], "owner", "з" .. k, (k - 1) * 5 * H)
  end
  return ids
end

function tests.test_unsummarized_candidate_only_within_window()
  local m = fresh()
  local ids = eight_old(m)
  local cur, unsum = m:session(8 * 5 * H)
  t.eq(cur, 9)
  t.eq(unsum, ids[8], "свежайшая без пересказа")
  for k = 8, 4, -1 do
    local _, u = m:session(8 * 5 * H)
    t.eq(u, ids[k], "кандидат " .. k)
    m:set_summary(ids[k], "П" .. k)
  end
  local _, none = m:session(8 * 5 * H)
  t.eq(none, nil, "последние 5 пересказаны — старые 3 не предлагаются")
  m:close()
end

function tests.test_window_skips_sessions_without_entries()
  local m = fresh()
  local ids = {}
  for k = 1, 7 do
    ids[k] = m:session((k - 1) * 5 * H)
    if k ~= 7 then m:add(ids[k], "owner", "з" .. k, (k - 1) * 5 * H) end -- 7-я пуста
  end
  local _, unsum = m:session(7 * 5 * H)
  t.eq(unsum, ids[6], "пустая в окно не входит")
  for k = 6, 2, -1 do m:set_summary(ids[k], "П" .. k) end -- окно: 6..2 (5 с записями)
  local _, none = m:session(7 * 5 * H)
  t.eq(none, nil, "пустая не сдвигает окно: сессия 1 вне пяти с записями")
  m:close()
end

function tests.test_import_lore_failure_rolls_back()
  local m = fresh()
  m:import_lore("## Мир\nСтарое", 100)
  local ok = pcall(m.import_lore, m, "## Мир\nНовое\n## Герои\nБ", {}) -- mtime не число: сбой на вставке
  t.ok(not ok, "сбой пробрасывается")
  t.ok(m:lore_text():find("Старое", 1, true), "старый лор цел")
  t.ok(not m:lore_text():find("Новое", 1, true), "новый не попал")
  t.eq(m:lore_mtime(), 100, "mtime цел")
  -- транзакция закрыта: следующий импорт работает
  m:import_lore("## Мир\nИтог", 300)
  t.ok(m:lore_text():find("Итог", 1, true))
  t.eq(m:lore_mtime(), 300)
  m:close()
end

function tests.test_add_ignores_nil_and_empty_text()
  local m = fresh()
  local s = m:session(0)
  m:add(s, "owner", nil, 1)
  m:add(s, "diary", "", 2)
  t.eq(#m:entries(s), 0, "пустое не пишем")
  t.eq(m:session(4 * H + 1) ~= s, true, "пустое не продлевает сессию (last_ts остался 0)")
  m:close()
end

function tests.test_persist()
  local m, path = fresh()
  local s = m:session(0)
  m:add(s, "owner", "помни", 0)
  m:import_lore("## Мир\nА", 5)
  m:set_summary(s, "итог")
  m:close()
  local m2 = memory.open(path)
  t.eq(#m2:entries(s), 1)
  t.eq(m2:entries(s)[1].text, "помни")
  t.eq(m2:summaries(5)[1], "итог")
  t.eq(m2:lore_mtime(), 5)
  t.eq(m2:session(100), s, "сессия продолжается после переоткрытия")
  m2:close()
end

function tests.test_text_with_quotes_and_sql()
  local m = fresh()
  local s = m:session(0)
  local nasty = "Роберт'); DROP TABLE entries;-- «ёлка» \"x\""
  m:add(s, "owner", nasty, 1)
  t.eq(m:entries(s)[1].text, nasty)
  m:close()
end

-- метки реплик (задачи в разговоре): миграция 3 добавляет колонки task, offer ------------------------------

local function columns(path)
  local conn = require("lua-ljsqlite3/init").open(path)
  local out = {}
  local stmt = conn:prepare("PRAGMA table_info(entries)")
  while true do
    local row = stmt:step()
    if not row then break end
    out[row[2]] = true
  end
  stmt:close()
  conn:close()
  return out
end

function tests.test_migration_v3_adds_mark_columns()
  local m, path = fresh()
  m:close()
  t.eq(scalar(path, "PRAGMA user_version"), memory.SCHEMA_VERSION, "новая база")
  local c = columns(path)
  t.ok(c.task and c.offer, "колонки task и offer")
  local old = old_event_db()
  paths[#paths + 1] = old
  memory.open(old):close()
  t.eq(scalar(old, "PRAGMA user_version"), memory.SCHEMA_VERSION, "старая база доведена до последней")
  c = columns(old)
  t.ok(c.task and c.offer, "колонки на старой базе")
  t.eq(scalar(old, "SELECT COUNT(*) FROM entries WHERE task IS NULL AND offer IS NULL"), 3, "старые реплики без меток")
end

function tests.test_marks_in_order_with_nulls()
  local m = fresh()
  local s = m:session(0)
  m:add(s, "owner", "о чём-то", 1)
  m:add(s, "owner", "ни о каком деле", 2, { task = "" })
  m:add(s, "diary", "предлагаю", 3, { offer = "id1 id2" })
  m:add(s, "owner", "о деле", 4, { task = "id7" })
  local other = m:session(5 * H)
  m:add(other, "owner", "другая сессия", 5 * H, { task = "id9" })
  local marks = m:marks(s)
  t.eq(#marks, 4, "все реплики сессии, чужой нет")
  t.eq(marks[1].role, "owner"); t.eq(marks[1].task, nil, "неизвестно"); t.eq(marks[1].offer, nil)
  t.eq(marks[2].task, "", "ни к какой задаче")
  t.eq(marks[3].role, "diary"); t.eq(marks[3].task, nil); t.eq(marks[3].offer, "id1 id2")
  t.eq(marks[4].task, "id7")
  t.eq(marks[1].ts, 1); t.eq(marks[4].ts, 4, "время реплики — для паузы ритма")
  t.eq(m:entries(s)[3].text, "предлагаю", "текст с метками пишется")
  m:close()
end

-- база, где миграция 3 сорвалась: колонка offer уже была, ADD COLUMN offer падает, шаг откатан — task нет
local function broken_v3_db()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec([[
CREATE TABLE sessions(id INTEGER PRIMARY KEY, started INT, last_ts INT, summary TEXT);
CREATE TABLE entries(id INTEGER PRIMARY KEY, session_id INT, ts INT, role TEXT, text TEXT, offer TEXT);
CREATE TABLE lore(section TEXT PRIMARY KEY, text TEXT, mtime INT);
PRAGMA user_version = 2;
]])
  conn:close()
  return path
end

function tests.test_add_without_mark_columns_still_writes()
  local path = broken_v3_db()
  local logs = {}
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.ok(logs[1] and logs[1]:find("riddle: memory migrate failed: ", 1, true), tostring(logs[1]))
  t.eq(scalar(path, "PRAGMA user_version"), 2, "шаг 3 откатан")
  t.ok(not columns(path).task, "колонки task нет")
  local s = m:session(0)
  m:add(s, "owner", "ЗАПИСЬ-БЕЗ-МЕТОК", 1, { task = "id1" })
  m:add(s, "diary", "ОТВЕТ-БЕЗ-МЕТОК", 1, { offer = "themes" })
  local e = m:entries(s)
  t.eq(#e, 2, "обе реплики записаны")
  t.eq(e[1].text, "ЗАПИСЬ-БЕЗ-МЕТОК"); t.eq(e[2].text, "ОТВЕТ-БЕЗ-МЕТОК")
  m:close()
end

-- запасной путь без меток — только «нет колонки»: иная ошибка вставки с метками уходит наружу, как без них,
-- и тихой записи без меток не бывает
function tests.test_add_with_marks_other_error_is_raised()
  local m, path = fresh()
  local s = m:session(0)
  -- сбой только у вставки с меткой: запасная вставка без меток прошла бы — и ошибка исчезла бы молча
  local stmt = m.conn:prepare("CREATE TRIGGER entries_guard BEFORE INSERT ON entries " ..
    "WHEN NEW.task IS NOT NULL BEGIN SELECT RAISE(ABORT, 'ДРУГАЯ-ОШИБКА'); END")
  stmt:step()
  stmt:close()
  local ok, err = pcall(m.add, m, s, "owner", "ЗАПРЕТ", 1, { task = "id1" })
  t.ok(not ok, "ошибка не проглочена")
  t.ok(tostring(err):find("ДРУГАЯ-ОШИБКА", 1, true), tostring(err))
  t.eq(scalar(path, "SELECT COUNT(*) FROM entries"), 0, "записи без меток нет")
  m:close()
end

-- add сообщает, легли ли метки: true — с метками, false — без них (колонок нет), nil — меток не давали
function tests.test_add_reports_whether_marks_saved()
  local m = fresh()
  local s = m:session(0)
  t.eq(m:add(s, "owner", "с меткой", 1, { task = "id1" }), true)
  t.eq(m:add(s, "owner", "без меток", 2), nil)
  m:close()
  local broken = memory.open(broken_v3_db())
  s = broken:session(0)
  t.eq(broken:add(s, "owner", "колонок нет", 1, { task = "id1" }), false, "метка не легла")
  broken:close()
end

function tests.test_marks_without_mark_columns_is_nil()
  local path = broken_v3_db()
  local logs = {}
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  local s = m:session(0)
  m:add(s, "owner", "x", 1)
  logs = {}
  local ok, marks = pcall(m.marks, m, s)
  t.ok(ok, "без ошибки: " .. tostring(marks))
  t.eq(marks, nil)
  t.eq(#logs, 1, "одна строка лога")
  t.eq(logs[1], "riddle: memory marks unavailable")
  m:close()
end

-- свёртка выпавшего из окна внутри сессии: миграция 4 добавляет таблицу rollups ------------------------------

-- база версии 3 (метки задач): сессия и 2 реплики с task/offer
local function v3_db(extra)
  local path = os.tmpname()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec([[
CREATE TABLE sessions(id INTEGER PRIMARY KEY, started INT, last_ts INT, summary TEXT);
CREATE TABLE entries(id INTEGER PRIMARY KEY, session_id INT, ts INT, role TEXT, text TEXT, task TEXT, offer TEXT);
CREATE INDEX entries_session ON entries(session_id, ts, id);
CREATE TABLE lore(section TEXT PRIMARY KEY, text TEXT, mtime INT);
INSERT INTO sessions VALUES(1, 0, 60, NULL);
INSERT INTO entries VALUES(1, 1, 50, 'owner', 'ЗАПИСЬ-V3', 'id1', NULL);
INSERT INTO entries VALUES(2, 1, 60, 'diary', 'ОТВЕТ-V3', NULL, 'themes');
PRAGMA user_version = 3;
]] .. (extra or ""))
  conn:close()
  return path
end

-- id реплики по тексту
local function entry_id(m, text)
  local stmt = m.conn:prepare("SELECT id FROM entries WHERE text = ?")
  stmt:bind(text)
  local row = stmt:step()
  stmt:close()
  return tonumber(row[1])
end

-- n реплик сессии s с текстами r1..rn
local function add_n(m, s, n, from)
  for i = from or 1, n do m:add(s, i % 2 == 1 and "owner" or "diary", "r" .. i, i) end
end

function tests.test_migration_v4_adds_rollups()
  local m, path = fresh()
  m:close()
  t.eq(scalar(path, "PRAGMA user_version"), memory.SCHEMA_VERSION, "новая база")
  t.eq(scalar(path, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'rollups'"), 1, "таблица rollups")
  local old = v3_db()
  local logs = {}
  memory.open(old, function(msg) logs[#logs + 1] = msg end):close()
  t.eq(#logs, 0, "без строк лога: " .. tostring(logs[1]))
  t.eq(scalar(old, "PRAGMA user_version"), memory.SCHEMA_VERSION, "база v3 доведена до 4")
  t.eq(scalar(old, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'rollups'"), 1, "таблица на старой базе")
  t.eq(scalar(old, "SELECT COUNT(*) FROM sessions"), 1, "сессии на месте")
  t.eq(scalar(old, "SELECT COUNT(*) FROM entries"), 2, "реплики на месте")
  t.eq(scalar(old, "SELECT text FROM entries WHERE id = 1"), "ЗАПИСЬ-V3")
  t.eq(scalar(old, "SELECT task FROM entries WHERE id = 1"), "id1", "метки целы")
  t.eq(scalar(old, "SELECT offer FROM entries WHERE id = 2"), "themes")
  t.eq(scalar(old, "SELECT COUNT(*) FROM rollups"), 0, "свёрток нет")
end

function tests.test_rollup_empty_session()
  local m = fresh()
  local s = m:session(0)
  local text, upto = m:rollup(s)
  t.eq(text, nil); t.eq(upto, 0, "строки нет — upto 0")
  local list, total = m:unrolled(s, 20)
  t.eq(#list, 0); t.eq(total, 0)
  m:close()
end

function tests.test_unrolled_after_upto()
  local m = fresh()
  local s = m:session(0)
  add_n(m, s, 30)
  local id10 = entry_id(m, "r10")
  t.eq(m:set_rollup(s, "П", id10, 100), true)
  local list, total = m:unrolled(s, 5)
  t.eq(total, 20, "несвёрнутых — все после upto")
  t.eq(#list, 5, "не больше limit")
  for i = 1, 5 do
    t.eq(list[i].id, entry_id(m, "r" .. (10 + i)), "старые первыми: " .. i)
    t.eq(list[i].text, "r" .. (10 + i))
    t.eq(list[i].role, (10 + i) % 2 == 1 and "owner" or "diary")
  end
  local all, n = m:unrolled(s)
  t.eq(#all, 20, "limit nil — все"); t.eq(n, 20)
  t.eq(all[20].text, "r30")
  local text, upto = m:rollup(s)
  t.eq(text, "П"); t.eq(upto, id10)
  m:close()
end

-- запоздалый ответ дочернего (меньший upto) свёртку не откатывает
function tests.test_set_rollup_keeps_newest()
  local m = fresh()
  local s = m:session(0)
  add_n(m, s, 30)
  local id10, id20 = entry_id(m, "r10"), entry_id(m, "r20")
  t.eq(m:set_rollup(s, "НОВАЯ", id20, 200), true)
  t.eq(m:set_rollup(s, "ЗАПОЗДАЛАЯ", id10, 300), false, "меньший upto — false")
  t.eq(m:set_rollup(s, "ТА-ЖЕ", id20, 300), false, "тот же upto — false")
  local text, upto = m:rollup(s)
  t.eq(text, "НОВАЯ"); t.eq(upto, id20)
  local id30 = entry_id(m, "r30")
  t.eq(m:set_rollup(s, "ДАЛЬШЕ", id30, 400), true, "больший upto — обновление")
  text, upto = m:rollup(s)
  t.eq(text, "ДАЛЬШЕ"); t.eq(upto, id30)
  t.eq(select(2, m:unrolled(s, 20)), 0, "всё свёрнуто")
  m:close()
end

function tests.test_rollups_per_session()
  local m = fresh()
  local s1 = m:session(0)
  add_n(m, s1, 4)
  t.eq(m:set_rollup(s1, "СВЁРТКА-1", entry_id(m, "r2"), 10), true)
  local s2 = m:session(5 * H)
  t.ok(s2 ~= s1, "новая сессия")
  m:add(s2, "owner", "s2-первая", 5 * H)
  local text, upto = m:rollup(s2)
  t.eq(text, nil); t.eq(upto, 0, "у второй сессии свёртки нет")
  local list, total = m:unrolled(s2, 20)
  t.eq(total, 1); t.eq(list[1].text, "s2-первая", "только свои реплики")
  t.eq(select(2, m:unrolled(s1, 20)), 2, "у первой — свои 2 несвёрнутых")
  t.eq(m:rollup(s1), "СВЁРТКА-1")
  m:close()
end

-- таблицы нет (миграция 4 не прошла): свёртка выключена, дневник пишет и читает; одна строка лога на открытие
function tests.test_rollups_missing_table_off()
  local logs = {}
  local path = os.tmpname()
  paths[#paths + 1] = path
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  m.conn:exec("DROP TABLE IF EXISTS rollups")
  local s = m:session(0)
  add_n(m, s, 3)
  local ok, text, upto = pcall(m.rollup, m, s)
  t.ok(ok, "rollup без ошибки: " .. tostring(text))
  t.eq(text, nil); t.eq(upto, nil, "нет таблицы — nil, nil")
  local ok2, list = pcall(m.unrolled, m, s, 20)
  t.ok(ok2, "unrolled без ошибки: " .. tostring(list))
  t.eq(list, nil)
  local ok3, saved = pcall(m.set_rollup, m, s, "П", 1, 10)
  t.ok(ok3, "set_rollup без ошибки: " .. tostring(saved))
  t.eq(saved, false)
  m:rollup(s)
  m:add(s, "owner", "ПОСЛЕ", 4)
  t.eq(m:recent(s, 2)[2].text, "ПОСЛЕ", "add и recent работают")
  t.eq(#logs, 1, "одна строка лога: " .. table.concat(logs, " | "))
  t.eq(logs[1], "riddle: memory rollups unavailable")
  m:close()
end

-- шаг 4 сорван (имя rollups занято индексом): в лог, user_version 3, база открыта, свёртка выключена
function tests.test_migration_v4_failure_logs_and_opens()
  local path = v3_db("CREATE INDEX rollups ON entries(ts);")
  local logs = {}
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.eq(#logs, 1, "одна строка в лог")
  t.ok(logs[1] and logs[1]:find("riddle: memory migrate failed: ", 1, true), tostring(logs[1]))
  local s = m:session(70)
  m:add(s, "owner", "ПОСЛЕ-СБОЯ", 80)
  t.eq(m:recent(s, 12)[3].text, "ПОСЛЕ-СБОЯ", "база пишет")
  t.eq(select(2, m:rollup(s)), nil, "свёртка выключена")
  m:close()
  t.eq(scalar(path, "PRAGMA user_version"), 3, "шаг 4 откатан")
end

-- сорванный set_rollup откатывает свою транзакцию: следующая запись и переоткрытие базы её не теряют
function tests.test_set_rollup_failure_rolls_back_transaction()
  local m, path = fresh()
  local s = m:session(0)
  add_n(m, s, 2)
  local ok = pcall(m.set_rollup, m, s, nil, 1, 10) -- text NOT NULL: INSERT падает внутри BEGIN
  t.ok(not ok, "сбой наружу")
  m:add(s, "owner", "ПОСЛЕ-СБОЯ", 20)
  m:close()
  local m2 = memory.open(path)
  t.eq(m2:recent(s, 1)[1].text, "ПОСЛЕ-СБОЯ", "реплика пережила переоткрытие: транзакция не осталась открытой")
  m2:close()
  t.eq(scalar(path, "SELECT COUNT(*) FROM rollups"), 0, "свёртка не записана")
end

-- сорванный COMMIT (Notion 40613e60-bc8d-8117): conn-обёртка, у которой первый COMMIT бросает ошибку, как диск или
-- блокировка; остальное — на настоящую базу. Транзакция не должна остаться открытой: следующая запись пережила бы
-- только до закрытия базы
local function commit_fails_once(conn)
  local armed = true
  return setmetatable({}, { __index = function(_, k)
    if k == "exec" then
      return function(_, sql_text, ...)
        if armed and sql_text == "COMMIT" then
          armed = false
          error("disk I/O error", 0)
        end
        return conn:exec(sql_text, ...)
      end
    end
    local v = conn[k]
    if type(v) == "function" then return function(_, ...) return v(conn, ...) end end
    return v
  end })
end

-- реплика, записанная после сбоя, пережила закрытие и переоткрытие базы
local function survives_reopen(m, path, s)
  m:add(s, "owner", "ПОСЛЕ-СБОЯ", 20)
  m:close()
  local m2 = memory.open(path)
  local last = m2:recent(s, 1)[1]
  m2:close()
  t.eq(last and last.text, "ПОСЛЕ-СБОЯ", "реплика пережила переоткрытие: транзакция не осталась открытой")
end

function tests.test_set_rollup_commit_failure_rolls_back_transaction()
  local m, path = fresh()
  local s = m:session(0)
  add_n(m, s, 2)
  m.conn = commit_fails_once(m.conn)
  t.ok(not pcall(m.set_rollup, m, s, "П", 1, 10), "сбой COMMIT наружу, как сбой работы")
  survives_reopen(m, path, s)
  t.eq(scalar(path, "SELECT COUNT(*) FROM rollups"), 0, "свёртка не записана")
end

function tests.test_import_lore_commit_failure_rolls_back_transaction()
  local m, path = fresh()
  local s = m:session(0)
  m:import_lore("## Мир\nА", 1)
  m.conn = commit_fails_once(m.conn)
  t.ok(not pcall(m.import_lore, m, "## Мир\nБ", 2), "сбой COMMIT наружу, как сбой работы")
  survives_reopen(m, path, s)
  t.eq(scalar(path, "SELECT text FROM lore WHERE section = 'Мир'"), "А", "лор прежний")
end

function tests.test_migration_commit_failure_rolls_back_transaction()
  local sqlite = require("lua-ljsqlite3/init")
  local orig_open = sqlite.open
  sqlite.open = function(p) return commit_fails_once(orig_open(p)) end
  local logs = {}
  local path = os.tmpname()
  paths[#paths + 1] = path
  local ok, m = pcall(memory.open, path, function(msg) logs[#logs + 1] = msg end)
  sqlite.open = orig_open
  t.ok(ok, "база открывается: " .. tostring(m))
  t.eq(#logs, 1, "сбой миграции — одна строка лога")
  t.ok(logs[1]:find("riddle: memory migrate failed: ", 1, true), tostring(logs[1]))
  survives_reopen(m, path, m:session(10))
end

-- не «нет таблицы», а иная ошибка (таблица rollups другой формы) — наружу, не глотается как «свёртка выключена»
function tests.test_rollup_other_error_is_raised()
  local logs = {}
  local path = os.tmpname()
  paths[#paths + 1] = path
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  m.conn:exec("DROP TABLE rollups; CREATE TABLE rollups(x INT)")
  local s = m:session(0)
  add_n(m, s, 2)
  t.ok(not pcall(m.rollup, m, s), "rollup: ошибка наружу")
  t.ok(not pcall(m.unrolled, m, s, 20), "unrolled: ошибка наружу")
  t.ok(not pcall(m.set_rollup, m, s, "П", 1, 10), "set_rollup: ошибка наружу")
  t.eq(#logs, 0, "«rollups unavailable» — только про отсутствие таблицы")
  m:close()
end

-- база v4 (свёртка уже есть): лор, сессия и реплики — для миграций 5 и дальше
local function v4_db(extra)
  local path = v3_db("CREATE TABLE rollups(session_id INTEGER PRIMARY KEY, upto INT NOT NULL, text TEXT NOT NULL, ts INT);" ..
    "INSERT INTO lore VALUES('Мир', 'ЛОР-V4', 7);" .. "PRAGMA user_version = 4;" .. (extra or ""))
  return path
end

-- миграция 5: персонажи (спека «чей это дневник», 2026-10-31). Строка встроенной персоны «Методов» — id 1
function tests.test_migration_v5_adds_personas()
  local m, path = fresh()
  local row = m:persona_by_key(":methods")
  t.ok(row, "новая база: строка «Методов»")
  t.eq(row.id, 1); t.eq(row.state, "ready"); t.eq(row.source, "builtin")
  m:close()
  local old = v4_db()
  local logs = {}
  m = memory.open(old, function(msg) logs[#logs + 1] = msg end)
  t.eq(#logs, 0, "без строк лога: " .. tostring(logs[1]))
  t.eq(m:persona_by_key(":methods").id, 1, "база v4: строка «Методов»")
  t.eq(m:lore_text(), "## Мир\nЛОР-V4", "лор на месте")
  t.eq(m:entries(1)[1].text, "ЗАПИСЬ-V3", "реплики на месте")
  m:close()
  t.eq(scalar(old, "PRAGMA user_version"), memory.SCHEMA_VERSION)
  memory.open(old):close()
  t.eq(scalar(old, "SELECT COUNT(*) FROM personas"), 1, "повтор миграции не размножил строку")
end

-- шаг 5 сорван (имя personas занято индексом): в лог, версия 4, база открыта, персон нет — без ошибки
function tests.test_migration_v5_failure_logs_and_opens()
  local path = v4_db("CREATE INDEX personas ON entries(ts);")
  local logs = {}
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.ok(logs[1] and logs[1]:find("riddle: memory migrate failed: ", 1, true), tostring(logs[1]))
  local ok, row = pcall(m.persona_by_key, m, ":methods")
  t.ok(ok, "persona_by_key без ошибки: " .. tostring(row))
  t.eq(row, nil)
  local ok2, parts = pcall(m.parts, m, 1)
  t.ok(ok2, "parts без ошибки: " .. tostring(parts))
  t.eq(parts, nil)
  local s = m:session(70)
  m:add(s, "owner", "ПОСЛЕ-СБОЯ", 80)
  t.eq(m:recent(s, 12)[3].text, "ПОСЛЕ-СБОЯ", "база пишет")
  t.eq(#logs, 2, "строка «personas unavailable» — одна: " .. table.concat(logs, " | "))
  t.eq(logs[2], "riddle: memory personas unavailable")
  m:close()
  t.eq(scalar(path, "PRAGMA user_version"), 4, "шаг 5 откатан")
end

-- персона и разделы: add_persona по ключу — та же строка; раздел дважды — то же состояние
function tests.test_add_persona_and_parts()
  local m = fresh()
  local id = m:add_persona{ key = "гермиона", line = "Гермиона", source = "config", state = "ready", lang = "ru" }
  t.ok(id and id ~= 1, "новый id: " .. tostring(id))
  t.eq(m:add_persona{ key = "гермиона", line = "Гермиона", source = "config", state = "ready" }, id, "тот же ключ — та же строка")
  local row = m:persona_by_key("гермиона")
  t.eq(row.line, "Гермиона"); t.eq(row.lang, "ru"); t.eq(row.state, "ready")
  m:set_persona_state(id, "confirm", "Так это?")
  row = m:persona_by_key("гермиона")
  t.eq(row.state, "confirm"); t.eq(row.ask, "Так это?")
  t.eq(next(m:parts(id)), nil, "разделов нет")
  m:set_part(id, "persona", "ТЕКСТ-1", 10)
  m:set_part(id, "persona", "ТЕКСТ-2", 11)
  local parts = m:parts(id)
  t.eq(parts.persona, "ТЕКСТ-2", "повтор раздела — замена, не копия")
  local n = 0
  for _ in pairs(parts) do n = n + 1 end
  t.eq(n, 1)
  t.eq(next(m:parts(1)), nil, "у «Методов» своих разделов нет")
  m:close()
end

-- последняя строка, сохранённая ответом пером (source = asked): ts, затем id. Второе значение — хранилище читается
-- (нет таблицы personas — nil, false: дневник тогда работает как до персонажей)
function tests.test_last_asked_latest_of_asked_only()
  local m = fresh()
  local row, ok = m:last_asked()
  t.eq(row, nil); t.eq(ok, true, "хранилище есть, спрашивали не раз")
  m:add_persona{ key = "a", line = "A", source = "asked", state = "ready", lang = "ru", ts = 10 }
  m:add_persona{ key = "b", line = "B", source = "config", state = "ready", ts = 99 }
  m:add_persona{ key = "c", line = "C", source = "asked", state = "ready", lang = "en", ts = 20 }
  m:add_persona{ key = "d", line = "D", source = "asked", state = "ready", ts = 20 }
  row = m:last_asked()
  t.eq(row.line, "D", "ts равны — позже заведённая"); t.eq(row.source, "asked")
  m:close()
end

function tests.test_last_asked_without_table_is_unavailable()
  local m, path = fresh()
  m.conn:exec("DROP TABLE personas")
  local row, ok = m:last_asked()
  t.eq(row, nil); t.eq(ok, false)
  m:close()
end

-- миграция 6: память и лор — у своего персонажа (план «чей это дневник», задача 3) ----------------------------

-- база v4 владельца в миниатюре: 2 сессии (у первой пересказ), реплики с метками, свёртка второй, лор из 3 разделов
-- не по алфавиту (порядок — rowid)
local V6_FIXTURE = [[
UPDATE sessions SET summary = 'ПЕРЕСКАЗ-1' WHERE id = 1;
INSERT INTO sessions VALUES(2, 9000, 9100, NULL);
INSERT INTO entries VALUES(3, 2, 9000, 'owner', 'ЗАПИСЬ-2', NULL, NULL);
INSERT INTO entries VALUES(4, 2, 9100, 'diary', 'ОТВЕТ-2', NULL, NULL);
INSERT INTO rollups VALUES(2, 3, 'СВЁРТКА-2', 9050);
DELETE FROM lore;
INSERT INTO lore VALUES('Яма', 'ЛОР-Я', 7);
INSERT INTO lore VALUES('Мир', 'ЛОР-М', 7);
INSERT INTO lore VALUES('Герои', 'ЛОР-Г', 7);
]]
local V6_LORE = "## Яма\nЛОР-Я\n\n## Мир\nЛОР-М\n\n## Герои\nЛОР-Г"

-- база v5 (до шага 6): v4 и шаг 5 так, как его делает memory.lua
local V5_STEP = [[
CREATE TABLE personas(id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, line TEXT NOT NULL, source TEXT NOT NULL, state TEXT NOT NULL, ask TEXT, lang TEXT, ts INT);
CREATE TABLE persona_parts(persona_id INT NOT NULL, name TEXT NOT NULL, text TEXT NOT NULL, ts INT, PRIMARY KEY(persona_id, name));
INSERT INTO personas(id, key, line, source, state, lang, ts) VALUES(1, ':methods', 'Том Реддл из «Методов рационального мышления»', 'builtin', 'ready', 'ru', 0);
PRAGMA user_version = 5;
]]

-- дамп базы: версия, схема (таблицы и индексы по имени), строки каждой таблицы по rowid
local function dump(path)
  local conn = require("lua-ljsqlite3/init").open(path)
  local out = { "v=" .. tostring(tonumber(conn:rowexec("PRAGMA user_version"))) }
  local stmt = conn:prepare("SELECT name, type, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
  local tables = {}
  while true do
    local r = stmt:step()
    if not r then break end
    out[#out + 1] = tostring(r[1]) .. ": " .. tostring(r[3])
    if r[2] == "table" then tables[#tables + 1] = r[1] end
  end
  stmt:close()
  for _, name in ipairs(tables) do
    local q = conn:prepare('SELECT * FROM "' .. name .. '" ORDER BY rowid')
    while true do
      local r = q:step()
      if not r then break end
      local cells = {}
      for i = 1, #r do
        local v = r[i]
        cells[i] = type(v) == "cdata" and tostring(tonumber(v)) or tostring(v)
      end
      out[#out + 1] = name .. "| " .. table.concat(cells, " | ")
    end
    q:close()
  end
  conn:close()
  return table.concat(out, "\n")
end

local function texts_of(list)
  local o = {}
  for _, e in ipairs(list) do o[#o + 1] = e.text end
  return table.concat(o, ",")
end

-- то, что видит дневник «Методов» (persona 1): сессия, пересказы, реплики, свёртка, лор и его метка
local function methods_view(m)
  t.eq(m:use_persona(1), true)
  local cur, prev = m:session(9200)
  return table.concat({ "cur=" .. cur, "prev=" .. tostring(prev), "summaries=" .. table.concat(m:summaries(), ","),
    "recent1=" .. texts_of(m:recent(1, 10)), "recent2=" .. texts_of(m:recent(2, 10)),
    "rollup2=" .. tostring((m:rollup(2))), "lore=" .. m:lore_text(), "mtime=" .. tostring(m:lore_mtime()) }, "\n")
end

local METHODS_VIEW_WANT = table.concat({ "cur=2", "prev=nil", "summaries=ПЕРЕСКАЗ-1", "recent1=ЗАПИСЬ-V3,ОТВЕТ-V3",
  "recent2=ЗАПИСЬ-2,ОТВЕТ-2", "rollup2=СВЁРТКА-2", "lore=" .. V6_LORE, "mtime=7" }, "\n")

function tests.test_migration_v6_marks_existing_memory_methods()
  local path = v4_db(V6_FIXTURE)
  local m = memory.open(path)
  t.eq(scalar(path, "PRAGMA user_version"), memory.SCHEMA_VERSION)
  t.eq(scalar(path, "SELECT COUNT(*) FROM sessions WHERE persona_id = 1"), 2, "все сессии — «Методов»")
  t.eq(scalar(path, "SELECT COUNT(*) FROM lore WHERE persona_id = 1"), 3, "весь лор — «Методов»")
  t.eq(scalar(path, "SELECT COUNT(*) FROM entries"), 4, "реплики на месте")
  t.eq(methods_view(m), METHODS_VIEW_WANT)
  m:close()
end

function tests.test_migration_v6_twice_same_state()
  local path = v4_db(V6_FIXTURE)
  memory.open(path):close()
  local first = dump(path)
  memory.open(path):close()
  t.eq(dump(path), first, "второе открытие базу не меняет")
end

-- шаг 6 сорван — на шаге 2 (имя lore_p занято индексом) и на шаге 3 (раздел лора NULL: уже после ALTER и CREATE).
-- Шаг откатан целиком: версия 5, база байт-в-байт по дампу как до шага, «Методов» видит всё; другого персонажа помнить
-- негде. Препятствие убрано — следующее открытие даёт ту же базу, что чистый прогон
function tests.test_migration_v6_failure_rolls_back()
  local clean = v4_db(V6_FIXTURE)
  memory.open(clean):close()
  local want = dump(clean)
  for _, case in ipairs({
    { name = "lore_p занято", obstacle = "CREATE INDEX lore_p ON entries(ts);", clear = "DROP INDEX lore_p;" },
    { name = "раздел NULL", obstacle = "INSERT INTO lore VALUES(NULL, 'БИТЫЙ', 7);",
      clear = "DELETE FROM lore WHERE section IS NULL;" },
  }) do
    local path = v4_db(V6_FIXTURE .. case.obstacle)
    local v5 = v4_db(V6_FIXTURE .. case.obstacle .. V5_STEP)
    local logs = {}
    local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
    t.ok(logs[1] and logs[1]:find("riddle: memory migrate failed: ", 1, true), case.name .. ": " .. tostring(logs[1]))
    t.eq(scalar(path, "PRAGMA user_version"), 5, case.name .. ": шаг 6 откатан")
    t.eq(dump(path), dump(v5), case.name .. ": база как до шага 6")
    t.eq(m:use_persona(2), false, case.name .. ": другого персонажа помнить негде")
    t.eq(logs[2], "riddle: memory personas unavailable", case.name)
    if case.name == "lore_p занято" then
      t.eq(methods_view(m), METHODS_VIEW_WANT, case.name .. ": «Методов» видит всё, как до миграции")
    end
    m:close()
    local conn = require("lua-ljsqlite3/init").open(path)
    conn:exec(case.clear)
    conn:close()
    memory.open(path):close()
    t.eq(dump(path), want, case.name .. ": повтор после сбоя — как чистый прогон")
  end
end

-- откат на старый код (ba4087a и раньше) поверх базы v6: его вставки без persona_id ложатся «Методов»
function tests.test_old_code_inserts_default_to_methods()
  local m, path = fresh()
  m:close()
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("INSERT INTO sessions(started, last_ts) VALUES(1, 2);" ..
    "INSERT INTO lore(section, text, mtime) VALUES('Мир', 'СТАРЫЙ-КОД', 5);")
  conn:close()
  t.eq(scalar(path, "SELECT persona_id FROM sessions"), 1)
  t.eq(scalar(path, "SELECT persona_id FROM lore"), 1)
  m = memory.open(path)
  t.eq(m:lore_text(), "## Мир\nСТАРЫЙ-КОД")
  m:close()
end

-- A: пересказанная сессия, текущая с 2 репликами, лор; B — своя сессия, пусто; снова A — всё на месте
function tests.test_switch_persona_new_memory_then_back()
  local m = fresh()
  local a = m:add_persona{ key = "a", line = "A", source = "config", state = "ready" }
  local b = m:add_persona{ key = "b", line = "B", source = "config", state = "ready" }
  t.eq(m:use_persona(a), true)
  local old = m:session(0)
  m:add(old, "owner", "A-СТАРАЯ", 0)
  m:set_summary(old, "A-ПЕРЕСКАЗ")
  local sa = m:session(5 * H)
  t.ok(sa ~= old, "новая сессия A")
  m:add(sa, "owner", "A-ЗАПИСЬ", 5 * H)
  m:add(sa, "diary", "A-ОТВЕТ", 5 * H + 1)
  m:import_lore("## Мир\nЛОР-A", 70)
  t.eq(m:use_persona(b), true)
  local sb, prev = m:session(5 * H + 2)
  t.ok(sb ~= sa, "у B своя сессия, хоть A писал минуту назад")
  t.eq(prev, nil, "пересказывать B нечего")
  t.eq(#m:recent(sb, 10), 0)
  t.eq(#m:summaries(), 0, "пересказов A у B нет")
  t.eq(m:lore_text(), "", "лора A у B нет")
  t.eq(m:lore_mtime(), nil)
  m:add(sb, "owner", "B-ЗАПИСЬ", 5 * H + 3)
  t.eq(m:use_persona(a), true)
  t.eq(m:session(5 * H + 4), sa, "A продолжает свою сессию")
  t.eq(texts_of(m:recent(sa, 10)), "A-ЗАПИСЬ,A-ОТВЕТ")
  t.eq(table.concat(m:summaries(), ","), "A-ПЕРЕСКАЗ")
  t.eq(m:lore_text(), "## Мир\nЛОР-A")
  t.eq(m:lore_owner(70), a)
  t.eq(m:lore_owner(71), nil)
  m:close()
end

-- миграция 7: имя, которым владелец назвался дневнику, — у персоны (карта, срез 13б) --------------------------------

-- база v6 так, как её оставляет шаг 6 memory.lua; вторая персона — с вопросом, языком и разделом (данные других
-- столбцов и таблиц)
local V6_STEP = [[
ALTER TABLE sessions ADD COLUMN persona_id INT NOT NULL DEFAULT 1;
CREATE TABLE lore_p(persona_id INT NOT NULL DEFAULT 1, section TEXT NOT NULL, text TEXT, mtime INT, PRIMARY KEY(persona_id, section));
INSERT INTO lore_p(persona_id, section, text, mtime) SELECT 1, section, text, mtime FROM lore ORDER BY rowid;
DROP TABLE lore;
ALTER TABLE lore_p RENAME TO lore;
INSERT INTO personas(id, key, line, source, state, ask, lang, ts) VALUES(2, 'гермиона', 'Гермиона', 'asked', 'confirm', 'Так это?', 'ru', 55);
INSERT INTO persona_parts VALUES(2, 'persona', 'ТЕКСТ-ПЕРСОНЫ', 56);
PRAGMA user_version = 6;
]]

local function v6_db()
  return v4_db(V6_FIXTURE .. V5_STEP .. V6_STEP)
end

-- дамп базы последней версии без шагов 7 и дальше: версия 6, без столбца owner_name в схеме и без его значения (NULL,
-- последний столбец) в строках personas; без пустой таблицы asked_pending (шаг 8)
local function without_step7(d)
  d = d:gsub("^v=%d+\n", "v=6\n"):gsub(", owner_name TEXT%)", ")", 1):gsub("\nasked_pending: [^\n]*", "", 1)
  return (d:gsub("(personas| [^\n]*) | nil\n", "%1\n"))
end

function tests.test_migration_7_owner_name()
  local path = v6_db()
  local before = dump(path)
  t.ok(before:find("^v=6\n"), "фикстура — v6")
  local logs = {}
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.eq(#logs, 0, "без строк лога: " .. tostring(logs[1]))
  t.eq(scalar(path, "PRAGMA user_version"), memory.SCHEMA_VERSION)
  t.eq(m:owner_name(1), nil, "«Методов» — имени нет")
  t.eq(m:owner_name(2), nil, "у второй — тоже")
  t.eq(methods_view(m), METHODS_VIEW_WANT, "память «Методов» на месте")
  m:close()
  local after = dump(path)
  t.ok(after:find("owner_name TEXT", 1, true), "столбец есть: " .. after)
  t.eq(without_step7(after), before, "кроме столбца owner_name (NULL) база байт в байт как v6")
end

-- повтор: второе открытие базу не меняет; версия сброшена на 6 при уже добавленном столбце (повтор шага) — без сбоя,
-- имя цело
function tests.test_migration_7_twice_same_state()
  local path = v6_db()
  memory.open(path):close()
  local first = dump(path)
  memory.open(path):close()
  t.eq(dump(path), first, "второе открытие базу не меняет")
  local m = memory.open(path)
  t.eq(m:set_owner_name(2, "Гарри"), true)
  m:close()
  local named = dump(path)
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("PRAGMA user_version = 6")
  conn:close()
  local logs = {}
  m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.eq(#logs, 0, "повтор шага 7 без сбоя: " .. tostring(logs[1]))
  t.eq(m:owner_name(2), "Гарри", "имя цело")
  m:close()
  t.eq(dump(path), named, "повтор шага — то же состояние")
end

-- имя — на персону: у каждой своё, повтор той же записи — то же состояние, новое имя заменяет прежнее
function tests.test_owner_name_per_persona()
  local m, path = fresh()
  local a = m:add_persona{ key = "a", line = "A", source = "config", state = "ready" }
  local b = m:add_persona{ key = "b", line = "B", source = "config", state = "ready" }
  t.eq(m:set_owner_name(a, "Гарри"), true)
  t.eq(m:owner_name(a), "Гарри")
  t.eq(m:owner_name(b), nil, "у B своего имени нет")
  t.eq(m:owner_name(1), nil, "у «Методов» — тоже")
  t.eq(m:set_owner_name(b, "Невилл"), true)
  t.eq(m:owner_name(a), "Гарри", "имя A не задето")
  m:close()
  local once = dump(path)
  m = memory.open(path)
  t.eq(m:set_owner_name(a, "Гарри"), true)
  m:close()
  t.eq(dump(path), once, "та же запись — то же состояние")
  m = memory.open(path)
  m:set_owner_name(a, "Гермиона")
  t.eq(m:owner_name(a), "Гермиона", "назвался иначе — новое имя")
  t.eq(m:owner_name(99), nil, "нет строки — nil")
  m:close()
end

-- шага 7 нет (столбца нет) или персонажей нет вовсе: чтение — nil, запись — false, без ошибки; иная ошибка — наружу
function tests.test_owner_name_without_column_or_table()
  local m = fresh()
  m.conn:exec("ALTER TABLE personas DROP COLUMN owner_name")
  t.eq(m:owner_name(1), nil, "нет столбца — nil")
  t.eq(m:set_owner_name(1, "Гарри"), false, "нет столбца — не записано")
  m.conn:exec("DROP TABLE personas")
  t.eq(m:owner_name(1), nil, "нет таблицы — nil")
  t.eq(m:set_owner_name(1, "Гарри"), false, "нет таблицы — не записано")
  m.conn:exec("CREATE TABLE personas(id INTEGER PRIMARY KEY, owner_name TEXT CHECK(length(owner_name) < 3))")
  m.conn:exec("INSERT INTO personas(id) VALUES(1)")
  t.ok(not pcall(m.set_owner_name, m, 1, "Гарри"), "иная ошибка (CHECK) — наружу")
  m:close()
end

-- миграция 8: ждущий вопрос «Так это дневник …?» в базе (Notion 41013e60-bc8d-815b) ----------------------------------

local PENDING = { line = "Гермиона Грейнджер — Хогвартс", ask = "Так это дневник Гермионы?", lang = "ru", ts = 77 }

-- база v7 доводится до 8: таблица есть, пустая; прочее как было
function tests.test_migration_8_asked_pending()
  local path = v6_db()
  memory.open(path):close()
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("DROP TABLE asked_pending")
  conn:exec("PRAGMA user_version = 7")
  conn:close()
  local before = dump(path)
  local logs = {}
  local m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.eq(#logs, 0, "без строк лога: " .. tostring(logs[1]))
  t.eq(scalar(path, "PRAGMA user_version"), 8)
  t.eq(m:asked_pending(), nil, "ждущего вопроса нет")
  t.eq(methods_view(m), METHODS_VIEW_WANT, "память «Методов» на месте")
  m:close()
  local after = dump(path)
  t.ok(after:find("asked_pending: CREATE TABLE", 1, true), "таблица есть: " .. after)
  local without = after:gsub("^v=8\n", "v=7\n"):gsub("\nasked_pending: [^\n]*", "", 1)
  t.eq(without, before, "кроме таблицы asked_pending база как v7")
end

-- повтор: второе открытие базу не меняет; версия сброшена на 7 при живой таблице со строкой — без сбоя, вопрос цел
function tests.test_migration_8_twice_same_state()
  local m, path = fresh()
  m:close()
  local first = dump(path)
  memory.open(path):close()
  t.eq(dump(path), first, "второе открытие базу не меняет")
  m = memory.open(path)
  t.eq(m:set_asked_pending(PENDING), true)
  m:close()
  local held = dump(path)
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("PRAGMA user_version = 7")
  conn:close()
  local logs = {}
  m = memory.open(path, function(msg) logs[#logs + 1] = msg end)
  t.eq(#logs, 0, "повтор шага 8 без сбоя: " .. tostring(logs[1]))
  t.eq(m:asked_pending().ask, PENDING.ask, "вопрос цел")
  m:close()
  t.eq(dump(path), held, "повтор шага — то же состояние")
end

-- одна строка: запись дважды — то же состояние, новая заменяет прежнюю; стереть дважды — то же
function tests.test_asked_pending_set_replace_clear()
  local m, path = fresh()
  t.eq(m:set_asked_pending(PENDING), true)
  local got = m:asked_pending()
  t.eq(got.line, PENDING.line); t.eq(got.ask, PENDING.ask); t.eq(got.lang, PENDING.lang)
  m:close()
  local once = dump(path)
  m = memory.open(path)
  m:set_asked_pending(PENDING)
  m:close()
  t.eq(dump(path), once, "та же запись — то же состояние")
  m = memory.open(path)
  m:set_asked_pending{ line = "R2-D2", ask = "So this is the diary of R2-D2?", lang = "en", ts = 78 }
  t.eq(m:asked_pending().line, "R2-D2", "новый вопрос заменяет прежний")
  t.eq(scalar(path, "SELECT COUNT(*) FROM asked_pending"), 1, "строка одна")
  m:set_asked_pending{ line = "R2-D2", ask = "So this is the diary of R2-D2?" }
  t.eq(m:asked_pending().lang, nil, "язык не известен — nil")
  t.eq(m:clear_asked_pending(), true)
  t.eq(m:asked_pending(), nil)
  m:close()
  local cleared = dump(path)
  m = memory.open(path)
  t.eq(m:clear_asked_pending(), true)
  m:close()
  t.eq(dump(path), cleared, "стереть дважды — то же состояние")
end

-- шага 8 нет (таблицы нет): чтение — nil, запись и стирание — false, без ошибки; иная ошибка — наружу
function tests.test_asked_pending_without_table()
  local m = fresh()
  m.conn:exec("DROP TABLE asked_pending")
  t.eq(m:asked_pending(), nil)
  t.eq(m:set_asked_pending(PENDING), false)
  t.eq(m:clear_asked_pending(), false)
  m.conn:exec("CREATE TABLE asked_pending(id INTEGER PRIMARY KEY, line TEXT, ask TEXT CHECK(length(ask) < 3), " ..
    "lang TEXT, ts INT)")
  t.ok(not pcall(m.set_asked_pending, m, PENDING), "иная ошибка (CHECK) — наружу")
  m:close()
end

local ok, err = pcall(t.run, tests)
cleanup()
if not ok then error(err, 0) end
