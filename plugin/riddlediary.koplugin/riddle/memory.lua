-- Память дневника: сессии (4 ч от последней записи), реплики, пересказы, лор. SQLite.
-- Роли реплик: «owner» — тот, кто пишет в дневнике, «diary» — дневник.
local ffi = require("ffi")
local sqlite = require("lua-ljsqlite3/init")
local str = require("riddle.str")

local SESSION_GAP_S = 4 * 3600
local DEFAULT_LORE_CAP = 10000 -- знаков; лор идёт в каждый запрос открытой печати любому провайдеру цепочки (prompt.lua), задержка от него не растёт
local DEFAULT_SUMMARIES = 5

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS sessions(
  id INTEGER PRIMARY KEY, started INT, last_ts INT, summary TEXT);
CREATE TABLE IF NOT EXISTS entries(
  id INTEGER PRIMARY KEY, session_id INT, ts INT, role TEXT, text TEXT);
CREATE INDEX IF NOT EXISTS entries_session ON entries(session_id, ts, id);
CREATE TABLE IF NOT EXISTS lore(
  section TEXT PRIMARY KEY, text TEXT, mtime INT)
]]

-- Версия схемы — PRAGMA user_version; open доводит базу до SCHEMA_VERSION по шагам MIGRATIONS.
-- 1: роль пишущего старого формата (любая, кроме «owner» и «diary») → «owner».
-- 2: удаляется таблица прошлой версии, лор стирается целиком
--    (метка импорта — MAX(mtime) лора — вместе с ним, так что lore.md импортируется заново).
-- 3: метки реплик для ритма задач. У «owner» task: NULL — неизвестно, "" — ни к какой задаче, "all" — о делах вообще,
--    "ask" — вопрос не о делах, иначе id задачи;
--    у «diary» offer: NULL — ничего не предлагал, "themes" — темы, иначе id предложенных задач через пробел.
-- 4: свёртка выпавшего из окна внутри сессии: rollups — пересказ и id последней свёрнутой реплики.
--    Шагом, не в SCHEMA: сбой создания выключает свёртку, а не роняет open.
-- 5: персонажи («чей это дневник»): personas — строка (key — persona.key), откуда (source: builtin | config |
--    asked), состояние; persona_parts — сгенерированные разделы персонажа. id 1 — встроенная персона «Методов».
--    Шагом: сбой выключает персонажей, но не роняет open. Строка «Методов» (или её нет) таблиц не читает —
--    дневник отвечает как прежде; при другой строке персонажа взять негде: ответ — фраза fail_other, генерации нет
--    (controller._current, test_no_persona_store_fails_soft).
-- 6: память на персонажа: sessions.persona_id и лор с ключом (persona_id, section); всё прежнее — «Методов» (1).
--    DEFAULT 1 — и для старого кода после отката: его вставки без persona_id ложатся «Методов». Порядок лора (rowid)
--    сохраняется. Сбой шага — откат шага целиком: память общая, как до шага, другого персонажа помнить негде
--    (use_persona -> false).
-- 7: personas.owner_name — имя, которым владелец назвался дневнику этой персоны (карта, срез 13б; под другим
--    дневником он может назваться иначе). NULL — не назывался. Шаг — «добавить столбец, если его нет»: повтор шага
--    (версия сброшена при уже добавленном столбце) даёт то же состояние. Сбой — имени нет, книга на карте без него.
-- 8: asked_pending — ждущий вопрос «Так это дневник …?» после ответа пером (строка «персонаж — мир», вопрос, язык);
--    одна строка id = 1: ждущий вопрос всегда один. Не в personas: строка там с source = 'asked' читалась бы
--    last_asked как готовая личность. IF NOT EXISTS — повтор шага даёт то же состояние. Сбой — вопрос живёт только
--    в процессе, перезапуск его теряет (как до шага).
local SCHEMA_VERSION = 8
local MIGRATIONS = {
  [1] = { "UPDATE entries SET role = 'owner' WHERE role NOT IN ('owner', 'diary')" },
  [2] = { "DROP TABLE IF EXISTS quest", "DELETE FROM lore" },
  [3] = { "ALTER TABLE entries ADD COLUMN task TEXT", "ALTER TABLE entries ADD COLUMN offer TEXT" },
  [4] = { "CREATE TABLE IF NOT EXISTS rollups(session_id INTEGER PRIMARY KEY, upto INT NOT NULL, text TEXT NOT NULL, ts INT)" },
  [5] = {
    "CREATE TABLE IF NOT EXISTS personas(id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, line TEXT NOT NULL, " ..
      "source TEXT NOT NULL, state TEXT NOT NULL, ask TEXT, lang TEXT, ts INT)",
    "CREATE TABLE IF NOT EXISTS persona_parts(persona_id INT NOT NULL, name TEXT NOT NULL, text TEXT NOT NULL, ts INT, " ..
      "PRIMARY KEY(persona_id, name))",
    "INSERT OR IGNORE INTO personas(id, key, line, source, state, lang, ts) " ..
      "VALUES(1, ':methods', 'Том Реддл из «Методов рационального мышления»', 'builtin', 'ready', 'ru', 0)",
  },
  [6] = {
    "ALTER TABLE sessions ADD COLUMN persona_id INT NOT NULL DEFAULT 1",
    "CREATE TABLE lore_p(persona_id INT NOT NULL DEFAULT 1, section TEXT NOT NULL, text TEXT, mtime INT, " ..
      "PRIMARY KEY(persona_id, section))",
    "INSERT INTO lore_p(persona_id, section, text, mtime) SELECT 1, section, text, mtime FROM lore ORDER BY rowid",
    "DROP TABLE lore",
    "ALTER TABLE lore_p RENAME TO lore",
  },
  -- шаг-таблица — столбец, если его ещё нет (add_column); строка — SQL как есть
  [7] = { { table = "personas", column = "owner_name", type = "TEXT" } },
  [8] = {
    "CREATE TABLE IF NOT EXISTS asked_pending(id INTEGER PRIMARY KEY CHECK(id = 1), line TEXT NOT NULL, " ..
      "ask TEXT NOT NULL, lang TEXT, ts INT)",
  },
}

local Memory = {}
Memory.__index = Memory
Memory.SCHEMA_VERSION = SCHEMA_VERSION
-- потолок лора в знаках: контроллер делит его между lore.md и миром персонажа (prompt.lore_block)
Memory.LORE_CAP = DEFAULT_LORE_CAP

-- числа биндим как int64: библиотека иначе отдаёт Lua-числа SQLite как double
local function I(n)
  return ffi.new("int64_t", n)
end

-- все строки запроса списком (строки копируются, int64 → number)
local function rows(conn, sql_text, ...)
  local stmt = conn:prepare(sql_text)
  stmt:bind(...)
  local out = {}
  while true do
    local row = stmt:step()
    if not row then break end
    local copy = {}
    for i = 1, #row do
      local v = row[i]
      if type(v) == "cdata" then v = tonumber(v) end
      copy[i] = v
    end
    out[#out + 1] = copy
  end
  stmt:close()
  return out
end

local function run(conn, sql_text, ...)
  local stmt = conn:prepare(sql_text)
  stmt:bind(...)
  stmt:step()
  stmt:close()
end

-- обрезка до max символов (кодпойнтов UTF-8), не байтов
local cut_chars = str.utf8_head

-- COMMIT; сорванный (диск, блокировка) оставил бы транзакцию открытой — тогда следующие записи тихо теряются
-- при закрытии базы, поэтому ROLLBACK. -> true | false, ошибка
local function commit(conn)
  local ok, err = pcall(conn.exec, conn, "COMMIT")
  if not ok then pcall(conn.exec, conn, "ROLLBACK") end
  return ok, err
end

-- столбец column у таблицы tbl есть -> true; таблицы нет -> false; схема не читается (вид над пропавшей
-- таблицей и т. п.) — ошибка SQLite наружу. Имена — из кода, не данные
local function has_column(conn, tbl, column)
  for _, col in ipairs(rows(conn, "PRAGMA table_info(" .. tbl .. ")")) do
    if col[2] == column then return true end
  end
  return false
end

-- шаг миграции { table, column, type }: ALTER TABLE … ADD COLUMN, если столбца ещё нет
local function add_column(conn, step)
  if has_column(conn, step.table, step.column) then return end
  run(conn, "ALTER TABLE " .. step.table .. " ADD COLUMN " .. step.column .. " " .. step.type)
end

-- шаги миграции и новая версия — одной транзакцией: сбой оставляет базу как была
local function migrate(conn)
  local version = rows(conn, "PRAGMA user_version")[1][1]
  for v = version + 1, SCHEMA_VERSION do
    conn:exec("BEGIN")
    local ok, err = pcall(function()
      for _, step in ipairs(MIGRATIONS[v]) do
        if type(step) == "table" then add_column(conn, step) else run(conn, step) end
      end
      conn:exec("PRAGMA user_version = " .. v)
    end)
    if ok then
      ok, err = commit(conn)
    else
      conn:exec("ROLLBACK")
    end
    if not ok then error(err, 0) end
  end
end

-- ошибка SQLite «нет такой колонки» (миграция 3 не прошла): SELECT — «no such column», INSERT — «has no column named»
local function no_column(err)
  local e = tostring(err)
  return e:find("no such column", 1, true) ~= nil or e:find("has no column named", 1, true) ~= nil
end

-- ошибка SQLite «нет такой таблицы» (миграция 4 не прошла)
local function no_table(err)
  return tostring(err):find("no such table", 1, true) ~= nil
end

-- log(msg) — необязательно. Сбой миграции не мешает дневнику: в лог, база открывается как есть.
-- Схема не создалась — ошибка наружу, соединение закрыто.
function Memory.open(path, log)
  local conn = sqlite.open(path)
  local ok, err = pcall(conn.exec, conn, SCHEMA)
  if not ok then
    conn:close()
    error(err, 0)
  end
  ok, err = pcall(migrate, conn)
  if not ok and log then log("riddle: memory migrate failed: " .. tostring(err)) end
  -- persona_id — чья память сейчас (use_persona); до выбора — «Методов». Колонки sessions.persona_id нет (шаг 6
  -- не прошёл) -> память общая
  local scoped
  ok, scoped = pcall(has_column, conn, "sessions", "persona_id")
  if not ok then
    conn:close()
    error(scoped, 0)
  end
  return setmetatable({ conn = conn, log = log, persona_id = 1, scoped = scoped }, Memory)
end

-- Память на персонажа (миграция 6): сессии, пересказы и лор — текущей персоны id (строка personas). Реплики, свёртка
-- и метки — по id сессии: сессия уже чья-то. -> true; false — шага 6 нет, а персона не «Методов» (1): её помнить
-- негде (вся память общая и принадлежит «Методов»); строка лога — не чаще раза на открытие
function Memory:use_persona(id)
  if self.scoped then
    self.persona_id = id
    return true
  end
  if id == 1 then return true end
  if self.log and not self.personas_logged then
    self.personas_logged = true
    pcall(self.log, "riddle: memory personas unavailable")
  end
  return false
end

-- условие SQL «своё» текущей персоны; шага 6 нет — всё (оно «Методов», другой use_persona не даёт).
-- Число в текст: id — целое из personas, не данные пользователя
function Memory:_mine()
  return self.scoped and string.format("persona_id = %d", self.persona_id) or "1 = 1"
end

function Memory:close()
  if self.conn then
    self.conn:close()
    self.conn = nil
  end
end

-- Сессия на момент now: продолжается, если с последней записи прошло ≤ 4 ч.
-- Второе значение — самая свежая без пересказа среди последних window (по умолчанию DEFAULT_SUMMARIES — столько
-- пересказов идёт в промпт) прошлых сессий с записями, если есть; что старше окна — не пересказывается никогда.
function Memory:session(now, window)
  local conn = self.conn
  local cur
  local mine = self:_mine()
  local last = rows(conn, "SELECT id, last_ts FROM sessions WHERE " .. mine .. " ORDER BY id DESC LIMIT 1")[1]
  if last and now - last[2] <= SESSION_GAP_S then
    cur = last[1]
  elseif self.scoped then
    run(conn, "INSERT INTO sessions(started, last_ts, persona_id) VALUES(?, ?, ?)", I(now), I(now), I(self.persona_id))
    cur = rows(conn, "SELECT last_insert_rowid()")[1][1]
  else
    run(conn, "INSERT INTO sessions(started, last_ts) VALUES(?, ?)", I(now), I(now))
    cur = rows(conn, "SELECT last_insert_rowid()")[1][1]
  end
  local prev = rows(conn,
    "SELECT id FROM (SELECT id, summary FROM sessions WHERE id < ? AND " .. mine .. " " ..
    "AND EXISTS(SELECT 1 FROM entries WHERE session_id = sessions.id) " ..
    "ORDER BY id DESC LIMIT ?) WHERE summary IS NULL ORDER BY id DESC LIMIT 1",
    I(cur), I(window or DEFAULT_SUMMARIES))[1]
  return cur, prev and prev[1] or nil
end

-- marks = { task, offer } — необязательно (миграция 3); колонок нет — реплика пишется без меток.
-- -> true — метки легли, false — колонок нет (реплика без меток), nil — меток не давали или текст пуст
function Memory:add(session_id, role, text, now, marks)
  -- пустой текст не пишем: NULL в истории ломает prompt.open у всех провайдеров
  if type(text) ~= "string" or text == "" then return end
  local written = false
  if marks then
    local ok, err = pcall(run, self.conn,
      "INSERT INTO entries(session_id, ts, role, text, task, offer) VALUES(?, ?, ?, ?, ?, ?)",
      I(session_id), I(now), role, text, marks.task, marks.offer)
    if not ok and not no_column(err) then error(err, 0) end
    written = ok
  end
  if not written then
    run(self.conn, "INSERT INTO entries(session_id, ts, role, text) VALUES(?, ?, ?, ?)",
      I(session_id), I(now), role, text)
  end
  run(self.conn, "UPDATE sessions SET last_ts = ? WHERE id = ?", I(now), I(session_id))
  if marks then return written end
end

-- метки реплик сессии по порядку: { { role, task, offer, ts }… }. Колонок нет (миграция 3 не прошла) — nil и строка
-- лога, без ошибки: ритм выключается, дневник отвечает
function Memory:marks(session_id)
  local ok, list = pcall(function()
    -- по номерам колонок, не rows: NULL в середине строки обрезал бы её по #
    local stmt = self.conn:prepare("SELECT role, task, offer, ts FROM entries WHERE session_id = ? ORDER BY id ASC")
    stmt:bind(I(session_id))
    local out = {}
    while true do
      local row = stmt:step()
      if not row then break end
      out[#out + 1] = { role = row[1], task = row[2], offer = row[3], ts = tonumber(row[4]) }
    end
    stmt:close()
    return out
  end)
  if ok then return list end
  if not no_column(list) then error(list, 0) end
  if self.log then pcall(self.log, "riddle: memory marks unavailable") end
  return nil
end

local function to_entries(list)
  local out = {}
  for i, r in ipairs(list) do out[i] = { role = r[1], text = r[2] } end
  return out
end

function Memory:recent(session_id, n)
  return to_entries(rows(self.conn,
    "SELECT role, text FROM (SELECT id, role, text FROM entries WHERE session_id = ? " ..
    "ORDER BY id DESC LIMIT ?) ORDER BY id ASC", I(session_id), I(n)))
end

function Memory:entries(session_id)
  return to_entries(rows(self.conn,
    "SELECT role, text FROM entries WHERE session_id = ? ORDER BY id ASC", I(session_id)))
end

function Memory:set_summary(session_id, text)
  run(self.conn, "UPDATE sessions SET summary = ? WHERE id = ?", text, I(session_id))
end

function Memory:summaries(limit)
  local out = {}
  for i, r in ipairs(rows(self.conn,
    -- "" — пометка пустой сессии «не возвращаться»: слота в окне она не занимает
    "SELECT summary FROM sessions WHERE " .. self:_mine() .. " AND summary IS NOT NULL AND summary <> '' " ..
    "ORDER BY id DESC LIMIT ?",
    I(limit or DEFAULT_SUMMARIES))) do
    out[i] = r[1]
  end
  return out
end

-- Свёртка сессии (миграция 4): один пересказ на сессию и id последней свёрнутой реплики (upto).
-- Таблицы нет — свёртка выключена: ошибки нет, строка лога — не чаще раза на открытие; иная ошибка — наружу
local function rollups_off(self, err)
  if not no_table(err) then error(err, 0) end
  if self.log and not self.rollups_logged then
    self.rollups_logged = true
    pcall(self.log, "riddle: memory rollups unavailable")
  end
end

-- -> text, upto; строки нет — nil, 0; таблицы нет — nil, nil
function Memory:rollup(session_id)
  local ok, r = pcall(rows, self.conn, "SELECT text, upto FROM rollups WHERE session_id = ?", I(session_id))
  if not ok then
    rollups_off(self, r)
    return nil, nil
  end
  if not r[1] then return nil, 0 end
  return r[1][1], r[1][2]
end

local UNROLLED = "FROM entries WHERE session_id = ? AND id > COALESCE((SELECT upto FROM rollups WHERE session_id = ?), 0)"

-- несвёрнутые реплики сессии (id > upto), старые первыми, не больше limit (nil — все): { { id, role, text }… }, total —
-- число всех несвёрнутых; таблицы нет — nil
function Memory:unrolled(session_id, limit)
  local sid = I(session_id)
  local ok, res = pcall(function()
    local list = {}
    for i, r in ipairs(rows(self.conn, "SELECT id, role, text " .. UNROLLED .. " ORDER BY id ASC LIMIT ?",
      sid, sid, I(limit or -1))) do
      list[i] = { id = r[1], role = r[2], text = r[3] }
    end
    return { list, rows(self.conn, "SELECT COUNT(*) " .. UNROLLED, sid, sid)[1][1] }
  end)
  if not ok then
    rollups_off(self, res)
    return nil
  end
  return res[1], res[2]
end

-- пишет, только если upto больше сохранённого: запоздалый ответ не откатит свёртку. Без upsert (ON CONFLICT DO UPDATE —
-- SQLite ≥ 3.24, в KOReader на Kindle не проверено). -> true — записано, false — upto не больше или таблицы нет
function Memory:set_rollup(session_id, text, upto, now)
  local conn = self.conn
  conn:exec("BEGIN")
  local ok, res = pcall(function()
    local row = rows(conn, "SELECT upto FROM rollups WHERE session_id = ?", I(session_id))[1]
    if not row then
      run(conn, "INSERT INTO rollups(session_id, upto, text, ts) VALUES(?, ?, ?, ?)",
        I(session_id), I(upto), text, I(now))
      return true
    end
    if row[1] >= upto then return false end
    run(conn, "UPDATE rollups SET upto = ?, text = ?, ts = ? WHERE session_id = ?", I(upto), text, I(now), I(session_id))
    return true
  end)
  if ok then
    local committed, cerr = commit(conn)
    if committed then return res end
    res = cerr
  else
    conn:exec("ROLLBACK")
  end
  rollups_off(self, res)
  return false
end

-- Персонажи (миграция 5). Таблиц нет — персонажи выключены: ошибки нет, nil и строка лога — не чаще раза на
-- открытие; иная ошибка — наружу
local function personas_off(self, err)
  if not no_table(err) then error(err, 0) end
  if self.log and not self.personas_logged then
    self.personas_logged = true
    pcall(self.log, "riddle: memory personas unavailable")
  end
end

local PERSONA_COLS = { "id", "key", "line", "source", "state", "ask", "lang", "ts" }

-- строка personas по запросу sql (SELECT PERSONA_COLS … ) -> { id, key, line, source, state, ask, lang, ts } | nil.
-- Ошибка запроса — наружу (персонажи выключены, если таблицы нет: personas_off)
local function persona_row(self, tail, ...)
  -- по номерам колонок, не rows: NULL в середине строки обрезал бы её по #
  local stmt = self.conn:prepare("SELECT " .. table.concat(PERSONA_COLS, ", ") .. " FROM personas " .. tail)
  stmt:bind(...)
  local r = stmt:step()
  local out
  if r then
    out = {}
    for i, name in ipairs(PERSONA_COLS) do
      local v = r[i]
      out[name] = type(v) == "cdata" and tonumber(v) or v
    end
  end
  stmt:close()
  return out
end

-- строка персонажа по ключу -> { id, key, line, source, state, ask, lang, ts } | nil (нет строки или таблицы)
function Memory:persona_by_key(key)
  local ok, row = pcall(persona_row, self, "WHERE key = ?", key)
  if ok then return row end
  personas_off(self, row)
  return nil
end

-- строка персонажа по номеру -> row | nil (нет строки или таблицы)
function Memory:persona_by_id(id)
  local ok, row = pcall(persona_row, self, "WHERE id = ?", I(id))
  if ok then return row end
  personas_off(self, row)
  return nil
end

-- последняя строка, сохранённая ответом пером (source = "asked"): по ts, затем по id -> row | nil, доступно. Второе
-- значение false — таблицы personas нет (миграция 5 не прошла): дневник тогда работает как до персонажей
function Memory:last_asked()
  local ok, row = pcall(persona_row, self, "WHERE source = 'asked' ORDER BY ts DESC, id DESC LIMIT 1")
  if ok then return row, true end
  personas_off(self, row)
  return nil, false
end

-- f = { key, line, source, state, ask?, lang? }; строка с тем же ключом остаётся как была. -> id | nil (нет таблицы)
function Memory:add_persona(f)
  local ok, err = pcall(run, self.conn,
    "INSERT OR IGNORE INTO personas(key, line, source, state, ask, lang, ts) VALUES(?, ?, ?, ?, ?, ?, ?)",
    f.key, f.line, f.source, f.state, f.ask, f.lang, I(f.ts or 0))
  if not ok then
    personas_off(self, err)
    return nil
  end
  local row = self:persona_by_key(f.key)
  return row and row.id
end

-- ответ «да» на вопрос «Чей это дневник?»: f = { key, line, lang, ts } -> id | nil (нет таблицы). Строка — готовая, из
-- ответа пером; такая же уже была (из конфига, прежним ответом) — становится последней и готовой. Оба шага
-- повторяемы: сбой между ними и повтор дают то же состояние
function Memory:save_asked(f)
  local ok, err = pcall(function()
    run(self.conn, "INSERT OR IGNORE INTO personas(key, line, source, state, lang, ts) VALUES(?, ?, 'asked', 'ready', ?, ?)",
      f.key, f.line, f.lang, I(f.ts or 0))
    run(self.conn, "UPDATE personas SET source = 'asked', state = 'ready', ask = NULL, lang = ?, ts = ? WHERE key = ?",
      f.lang, I(f.ts or 0), f.key)
  end)
  if not ok then
    personas_off(self, err)
    return nil
  end
  local row = self:persona_by_key(f.key)
  return row and row.id
end

function Memory:set_persona_state(id, state, ask)
  run(self.conn, "UPDATE personas SET state = ?, ask = ? WHERE id = ?", state, ask, I(id))
end

-- итог разбора строки (раздел resolve): f = { state = "ready" | "confirm", ask?, line, lang }. Только у новой строки
-- (state = "new"): запоздалый или повторный ответ уже принятого не откатывает — повтор даёт то же состояние
function Memory:resolve_persona(id, f)
  run(self.conn, "UPDATE personas SET state = ?, ask = ?, line = ?, lang = ? WHERE id = ? AND state = 'new'",
    f.state, f.ask, f.line, f.lang, I(id))
end

-- ответ на вопрос «Так это дневник …?»: state = "ready" | "rejected"; только у ждущей ответа строки (confirm).
-- -> true, если ответ принят; false — строка уже не ждала (первый ответ решил)
function Memory:answer_persona(id, state)
  run(self.conn, "UPDATE personas SET state = ?, ask = NULL WHERE id = ? AND state = 'confirm'", state, I(id))
  return rows(self.conn, "SELECT changes()")[1][1] > 0
end

-- Имя, которым владелец назвался дневнику персонажа id (миграция 7). Нет таблицы personas или столбца (шаг 5 или 7 не
-- прошёл) — имени нет: чтение -> nil, запись -> false, без ошибки и без строки лога (сбой миграции уже в логе);
-- иная ошибка — наружу. Значение имени в лог не идёт нигде
local function no_owner_store(err)
  if no_table(err) or no_column(err) then return end
  error(err, 0)
end

-- -> string | nil (не назывался, нет строки или хранилища)
function Memory:owner_name(id)
  local ok, list = pcall(rows, self.conn, "SELECT owner_name FROM personas WHERE id = ?", I(id))
  if not ok then return no_owner_store(list) end
  local v = list[1] and list[1][1]
  return type(v) == "string" and v or nil
end

-- одна команда: повтор (тот же ответ дважды) даёт то же состояние; назвался иначе — новое имя.
-- -> true | false (нет хранилища)
function Memory:set_owner_name(id, name)
  local ok, err = pcall(run, self.conn, "UPDATE personas SET owner_name = ? WHERE id = ?", name, I(id))
  if ok then return true end
  no_owner_store(err)
  return false
end

-- Ждущий вопрос «Так это дневник …?» (миграция 8). Пишет только контроллер (_ask_answer). Нет таблицы (шаг 8 не
-- прошёл) — вопрос не хранится: чтение -> nil, запись -> false, без ошибки и без строки лога (сбой миграции уже в
-- логе); иная ошибка — наружу. Строка и вопрос — данные пользователя, в лог не идут

-- -> { line, ask, lang } | nil (вопроса нет или нет хранилища)
function Memory:asked_pending()
  local ok, list = pcall(rows, self.conn, "SELECT line, ask, lang FROM asked_pending WHERE id = 1")
  if not ok then
    if no_table(list) then return nil end
    error(list, 0)
  end
  local r = list[1]
  if not r then return nil end
  return { line = r[1], ask = r[2], lang = type(r[3]) == "string" and r[3] or nil }
end

-- f = { line, ask, lang?, ts? }; одна команда, строка одна: повтор — то же состояние, новый вопрос заменяет прежний.
-- -> true | false (нет хранилища)
function Memory:set_asked_pending(f)
  local ok, err = pcall(run, self.conn,
    "INSERT OR REPLACE INTO asked_pending(id, line, ask, lang, ts) VALUES(1, ?, ?, ?, ?)",
    f.line, f.ask, f.lang, I(f.ts or 0))
  if ok then return true end
  if no_table(err) then return false end
  error(err, 0)
end

-- вопрос снят («да» сохранено, «нет»): повтор — то же состояние. -> true | false (нет хранилища)
function Memory:clear_asked_pending()
  local ok, err = pcall(run, self.conn, "DELETE FROM asked_pending")
  if ok then return true end
  if no_table(err) then return false end
  error(err, 0)
end

-- сгенерированные разделы персонажа -> { [name] = text } | nil (нет таблицы)
function Memory:parts(id)
  local ok, list = pcall(rows, self.conn, "SELECT name, text FROM persona_parts WHERE persona_id = ?", I(id))
  if not ok then
    personas_off(self, list)
    return nil
  end
  local out = {}
  for _, r in ipairs(list) do out[r[1]] = r[2] end
  return out
end

-- раздел одной командой: повтор (запоздалый ответ, обрыв после записи) даёт то же состояние
function Memory:set_part(id, name, text, now)
  run(self.conn, "INSERT OR REPLACE INTO persona_parts(persona_id, name, text, ts) VALUES(?, ?, ?, ?)",
    I(id), name, text, I(now or 0))
end

-- все сгенерированные разделы персонажа id (пересоздание: файл forget_persona, main.lua); строка personas остаётся
function Memory:forget_parts(id)
  run(self.conn, "DELETE FROM persona_parts WHERE persona_id = ?", I(id))
end

-- Разбор markdown на разделы по заголовкам «## ». Текст до первого заголовка не берётся.
local function parse_sections(md_text)
  local sections, by_name = {}, {}
  local cur
  for line in (md_text .. "\n"):gmatch("(.-)\r?\n") do
    local name = line:match("^## +(.-)%s*$")
    if name then
      cur = by_name[name]
      if not cur then
        cur = { name = name, lines = {} }
        by_name[name] = cur
        sections[#sections + 1] = cur
      end
    elseif cur then
      cur.lines[#cur.lines + 1] = line
    end
  end
  for _, s in ipairs(sections) do
    s.text = str.trim(table.concat(s.lines, "\n"))
  end
  return sections
end

-- Лор текущей персоны заменяется целиком: разделы, которых нет в новом тексте, исчезают. Лор других — как был.
function Memory:import_lore(md_text, mtime)
  local conn = self.conn
  local sections = parse_sections(md_text)
  conn:exec("BEGIN")
  local ok, err = pcall(function()
    run(conn, "DELETE FROM lore WHERE " .. self:_mine())
    for _, s in ipairs(sections) do
      if self.scoped then
        run(conn, "INSERT INTO lore(persona_id, section, text, mtime) VALUES(?, ?, ?, ?)",
          I(self.persona_id), s.name, s.text, I(mtime))
      else
        run(conn, "INSERT INTO lore(section, text, mtime) VALUES(?, ?, ?)", s.name, s.text, I(mtime))
      end
    end
  end)
  if ok then
    ok, err = commit(conn)
  else
    conn:exec("ROLLBACK")
  end
  if not ok then error(err, 0) end
end

function Memory:lore_mtime()
  local r = rows(self.conn, "SELECT MAX(mtime) FROM lore WHERE " .. self:_mine())[1]
  return r and r[1] or nil
end

-- чей лор импортирован из lore.md с этим mtime -> persona_id | nil (ничей). Решение 6а плана: файл, уже
-- импортированный к одному персонажу, к другому не идёт
function Memory:lore_owner(mtime)
  local r = rows(self.conn, "SELECT " .. (self.scoped and "persona_id" or "1") ..
    " FROM lore WHERE mtime = ? ORDER BY 1 LIMIT 1", I(mtime))[1]
  return r and r[1] or nil
end

function Memory:lore_text(max_chars)
  local parts = {}
  for i, r in ipairs(rows(self.conn, "SELECT section, text FROM lore WHERE " .. self:_mine() .. " ORDER BY rowid")) do
    parts[i] = "## " .. r[1] .. "\n" .. r[2]
  end
  return cut_chars(table.concat(parts, "\n\n"), max_chars or DEFAULT_LORE_CAP)
end

return Memory
