-- Знание из Notion: базы (sources), документы (docs), служебные метки (meta); общий формат задач любого
-- источника (collections, tasks) и состояние ядра (core). Отдельная SQLite:
-- пишет синхронизация в дочернем процессе, родитель открывает только на одно чтение и закрывает до fork.
local ffi = require("ffi")
local sqlite = require("lua-ljsqlite3/init")
local str = require("riddle.str")

local knowledge = {}
knowledge.PATH = "/mnt/us/riddle/knowledge.sqlite3"
-- весь текст знаний не больше стольких знаков — уходит в ответ целиком («маленький Notion»)
knowledge.SMALL_CHARS = 30000
-- граница между документами в тексте знаний (внутри документа пустая строка — между свойствами и телом)
knowledge.SEP = "\n\n---\n\n"

-- документ не пуст (условие над docs d LEFT JOIN sources s): после среза названия базы первой строкой — так же,
-- как в K:sections, — остаётся не только пробельное
local WS = "' ' || char(9, 10, 11, 12, 13)"
local NONEMPTY = "trim(CASE WHEN s.title <> '' AND (d.text = s.title OR " ..
  "substr(d.text, 1, length(s.title) + 1) = s.title || char(10)) THEN substr(d.text, length(s.title) + 1) " ..
  "ELSE coalesce(d.text, '') END, " .. WS .. ") <> ''"
-- пересчитать docs.nonempty по тексту и текущему названию базы; дописывается WHERE по docs (без него — все).
-- Зависит и от названия базы: пересчитывают триггеры (миграция 4) на запись документа, базы и удаление баз.
local REFRESH_NONEMPTY = "UPDATE docs SET nonempty = (SELECT " .. NONEMPTY ..
  " FROM docs d LEFT JOIN sources s ON s.id = d.source_id WHERE d.id = docs.id)"

-- Версия схемы — PRAGMA user_version; open доводит базу до SCHEMA_VERSION по шагам MIGRATIONS.
-- 1: базы, документы, метки.
-- 2: общий формат задач (collections, tasks — пишет источник) и состояние ядра (core); таблицы 1 не трогаются.
-- id коллекций и задач уникальны среди всех источников: при втором источнике нужен ключ (source, id), иначе
-- INSERT OR REPLACE перенесёт чужую строку в свой снимок.
-- 3: docs.nonempty — непустота документа (NONEMPTY), считается при записи, а не в каждом запросе; уже лежащие
-- документы заполняются тем же условием (REFRESH_NONEMPTY).
-- 4: пересчёт nonempty — триггерами в самой базе, а не кодом: сборка схемы 2 (откат) пишет документы без колонки
-- (DEFAULT 0) и базы без пересчёта, триггер срабатывает и на её записи. Плюс полный пересчёт — для документов,
-- уже записанных так в базу v3. REPLACE в sources вызывает только INSERT-триггер (recursive_triggers выкл.);
-- UPDATE nonempty из триггера не задевает UPDATE OF … — без рекурсии.
local SCHEMA_VERSION = 4
local MIGRATIONS = {
  [1] = {
    "CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY, title TEXT)",
    "CREATE TABLE IF NOT EXISTS docs(id TEXT PRIMARY KEY, source_id TEXT, title TEXT, edited TEXT, " ..
      "text TEXT, props_json TEXT, chars INT)",
    "CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)",
  },
  [2] = {
    "CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY, title TEXT, source TEXT, items INT, " ..
      "task_candidate INT, native_tasks INT, depth INT, model_pick INT)",
    "CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, collection_id TEXT, title TEXT, open INT, " ..
      "archived INT, project TEXT, due TEXT, edited TEXT)",
    "CREATE TABLE IF NOT EXISTS core(k TEXT PRIMARY KEY, v TEXT)",
  },
  [3] = {
    "ALTER TABLE docs ADD COLUMN nonempty INT NOT NULL DEFAULT 0",
    REFRESH_NONEMPTY,
  },
  [4] = {
    "CREATE TRIGGER IF NOT EXISTS docs_nonempty_insert AFTER INSERT ON docs BEGIN " ..
      REFRESH_NONEMPTY .. " WHERE id = NEW.id; END",
    "CREATE TRIGGER IF NOT EXISTS docs_nonempty_update AFTER UPDATE OF id, text, source_id ON docs BEGIN " ..
      REFRESH_NONEMPTY .. " WHERE id = NEW.id; END",
    "CREATE TRIGGER IF NOT EXISTS sources_nonempty_insert AFTER INSERT ON sources BEGIN " ..
      REFRESH_NONEMPTY .. " WHERE source_id = NEW.id; END",
    "CREATE TRIGGER IF NOT EXISTS sources_nonempty_update AFTER UPDATE OF id, title ON sources BEGIN " ..
      REFRESH_NONEMPTY .. " WHERE source_id IN (OLD.id, NEW.id); END",
    "CREATE TRIGGER IF NOT EXISTS sources_nonempty_delete AFTER DELETE ON sources BEGIN " ..
      REFRESH_NONEMPTY .. " WHERE source_id = OLD.id; END",
    REFRESH_NONEMPTY,
  },
}

local K = {}
K.__index = K

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

-- f() одной транзакцией (mode — "IMMEDIATE": блокировка записи сразу); ошибка f или COMMIT — откат и наружу
local function tx(conn, f, mode)
  conn:exec(mode and ("BEGIN " .. mode) or "BEGIN")
  local ok, res = pcall(f)
  if ok then
    local cok, cerr = pcall(conn.exec, conn, "COMMIT")
    if cok then return res end
    res = cerr
  end
  pcall(conn.exec, conn, "ROLLBACK")
  error(res, 0)
end

-- Версия актуальна — без блокировки. Иначе каждый шаг — BEGIN IMMEDIATE и версия перечитывается внутри: два
-- процесса открыли базу одновременно — второй ждёт запись первого (busy_timeout) и сделанный шаг пропускает.
-- Перечитать в простом BEGIN мало: оба держат чтение, повышение до записи — BUSY без ожидания.
local function migrate(conn)
  local version = rows(conn, "PRAGMA user_version")[1][1]
  for v = version + 1, SCHEMA_VERSION do
    tx(conn, function()
      if rows(conn, "PRAGMA user_version")[1][1] >= v then return end
      for _, sql_text in ipairs(MIGRATIONS[v]) do run(conn, sql_text) end
      conn:exec("PRAGMA user_version = " .. v)
    end, "IMMEDIATE")
  end
end

local utf8_len = str.utf8_len

-- busy_ms — сколько ждать занятую базу (по умолчанию 2000; 0 — не ждать: чтение на потоке интерфейса отказывает сразу)
function knowledge.open(path, busy_ms)
  local conn = sqlite.open(path)
  local ok, err = pcall(function()
    conn:exec("PRAGMA busy_timeout = " .. math.floor(busy_ms or 2000))
    migrate(conn)
  end)
  if not ok then
    conn:close()
    error(err, 0)
  end
  return setmetatable({ conn = conn }, K)
end

function K:close()
  if self.conn then
    self.conn:close()
    self.conn = nil
  end
end

-- { [id] = edited } всех документов
function K:edited_map()
  local out = {}
  for _, r in ipairs(rows(self.conn, "SELECT id, edited FROM docs")) do out[r[1]] = r[2] end
  return out
end

-- база и непустота её документов (название базы срезается с их первой строки; пересчёт — триггер),
-- одной транзакцией
function K:put_source(id, title)
  tx(self.conn, function()
    run(self.conn, "INSERT OR REPLACE INTO sources(id, title) VALUES(?, ?)", id, title or "")
  end)
end

-- документ целиком, одной транзакцией
function K:put_doc(d)
  local text = d.text or ""
  tx(self.conn, function()
    run(self.conn,
      "INSERT OR REPLACE INTO docs(id, source_id, title, edited, text, props_json, chars) VALUES(?, ?, ?, ?, ?, ?, ?)",
      d.id, d.source_id, d.title or "", d.edited or "", text, d.props_json or "[]", I(utf8_len(text)))
  end)
end

-- снять edited документа (текст остаётся): в edited_map его нет, следующий прогон sync его перечитает
function K:forget_edited(id)
  run(self.conn, "UPDATE docs SET edited = NULL WHERE id = ?", id)
end

-- удалить документы и базы, чьих id нет в seen (набор { [id] = true }); у оставшихся документов удалённой базы
-- непустота — без среза её названия (пересчёт — триггер). -> число удалённых документов
function K:delete_missing(seen)
  return tx(self.conn, function()
    local deleted = 0
    for _, r in ipairs(rows(self.conn, "SELECT id FROM docs")) do
      if not seen[r[1]] then
        run(self.conn, "DELETE FROM docs WHERE id = ?", r[1])
        deleted = deleted + 1
      end
    end
    for _, r in ipairs(rows(self.conn, "SELECT id FROM sources")) do
      if not seen[r[1]] then
        run(self.conn, "DELETE FROM sources WHERE id = ?", r[1])
      end
    end
    return deleted
  end)
end

-- f() одной транзакцией (правила классификации: обрыв не оставляет смеси старых и новых)
function K:tx(f)
  return tx(self.conn, f)
end

-- значение метки строкой | nil
function K:meta(k)
  local r = rows(self.conn, "SELECT v FROM meta WHERE k = ?", k)[1]
  return r and r[1]
end

function K:set_meta(k, v)
  run(self.conn, "INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", k, tostring(v))
end

function K:delete_meta(k)
  run(self.conn, "DELETE FROM meta WHERE k = ?", k)
end

-- { [остаток ключа] = значение } меток, чей ключ начинается с prefix
function K:meta_prefix(prefix)
  local out = {}
  for _, r in ipairs(rows(self.conn, "SELECT k, v FROM meta WHERE substr(k, 1, ?) = ?", I(#prefix), prefix)) do
    out[r[1]:sub(#prefix + 1)] = r[2]
  end
  return out
end

function K:delete_meta_prefix(prefix)
  run(self.conn, "DELETE FROM meta WHERE substr(k, 1, ?) = ?", I(#prefix), prefix)
end

local function bit01(v)
  return I(v and 1 or 0)
end

-- строки запроса записями { [имя] = значение }: колонки по именам, NULL — nil (в rows дыра обрезала бы строку)
local function records(conn, names, sql_text, ...)
  local stmt = conn:prepare(sql_text)
  stmt:bind(...)
  local out = {}
  while true do
    local row = stmt:step()
    if not row then break end
    local rec = {}
    for i, name in ipairs(names) do
      local v = row[i]
      if type(v) == "cdata" then v = tonumber(v) end
      rec[name] = v
    end
    out[#out + 1] = rec
  end
  stmt:close()
  return out
end

local COLLECTION = { "id", "title", "source", "items", "task_candidate", "native_tasks", "depth", "model_pick" }
local TASK = { "id", "collection_id", "title", "open", "archived", "project", "due", "edited" }
local COLLECTION_FLAGS = { "task_candidate", "native_tasks", "model_pick" }
local TASK_FLAGS = { "open", "archived" }

local function flags(rec, names)
  for _, name in ipairs(names) do rec[name] = rec[name] == 1 end
  return rec
end

-- снимок источника одной транзакцией: его коллекции и их задачи заменяются целиком, чужие — не трогаются;
-- задачи не из коллекций снимка не пишутся. depth nil — NULL (неизвестна, не корень).
-- collection = {id, title, source, items, task_candidate, native_tasks, depth, model_pick},
-- task = {id, collection_id, title, open, archived, project, due, edited}; булевы — true/false, в базе 0/1
function K:put_snapshot(source, collections, tasks)
  tx(self.conn, function()
    run(self.conn, "DELETE FROM tasks WHERE collection_id IN (SELECT id FROM collections WHERE source = ?)", source)
    run(self.conn, "DELETE FROM collections WHERE source = ?", source)
    local own = {}
    for _, c in ipairs(collections) do
      own[c.id] = true
      run(self.conn, "INSERT OR REPLACE INTO collections(id, title, source, items, task_candidate, native_tasks, " ..
        "depth, model_pick) VALUES(?, ?, ?, ?, ?, ?, ?, ?)", c.id, c.title or "", source, I(c.items or 0),
        bit01(c.task_candidate), bit01(c.native_tasks), c.depth and I(c.depth), bit01(c.model_pick))
    end
    for _, r in ipairs(tasks) do
      if own[r.collection_id] then
        run(self.conn, "INSERT OR REPLACE INTO tasks(id, collection_id, title, open, archived, project, due, edited) " ..
          "VALUES(?, ?, ?, ?, ?, ?, ?, ?)", r.id, r.collection_id, r.title or "", bit01(r.open), bit01(r.archived),
          r.project, r.due, r.edited)
      end
    end
  end)
end

-- все коллекции общего формата, по id
function K:collections()
  local out = records(self.conn, COLLECTION, "SELECT " .. table.concat(COLLECTION, ", ") ..
    " FROM collections ORDER BY id")
  for _, c in ipairs(out) do flags(c, COLLECTION_FLAGS) end
  return out
end

-- задачи коллекции, по id
function K:tasks_of(collection_id)
  local out = records(self.conn, TASK, "SELECT " .. table.concat(TASK, ", ") ..
    " FROM tasks WHERE collection_id = ? ORDER BY id", collection_id)
  for _, r in ipairs(out) do flags(r, TASK_FLAGS) end
  return out
end

-- состояние ядра (слово пользователя о базе и т. п.): строка | nil
function K:core(k)
  local r = rows(self.conn, "SELECT v FROM core WHERE k = ?", k)[1]
  return r and r[1]
end

-- v = nil — удалить
function K:set_core(k, v)
  if v == nil then
    run(self.conn, "DELETE FROM core WHERE k = ?", k)
  else
    run(self.conn, "INSERT OR REPLACE INTO core(k, v) VALUES(?, ?)", k, tostring(v))
  end
end

-- { docs, chars, collections }: число документов, знаков (не байтов) в их текстах и баз (коллекций общего формата)
-- — одним запросом
function K:stats()
  local r = rows(self.conn, "SELECT count(*), coalesce(sum(chars), 0), (SELECT count(*) FROM collections) FROM docs")[1]
  return { docs = r[1], chars = r[2], collections = r[3] }
end

-- id документов недавнего: по edited убыв. (без edited — последними), документы целиком, пока сумма их знаков
-- ≤ max_chars; не влезший пропускается, следующие ещё могут влезть. -> { [id] = true }, знаков в них
local function recent_ids(conn, max_chars)
  local ids, total = {}, 0
  for _, r in ipairs(rows(conn, "SELECT id, chars FROM docs WHERE nonempty = 1 " ..
      "ORDER BY edited IS NULL, edited DESC, id")) do
    if total + r[2] <= max_chars then
      ids[r[1]] = true
      total = total + r[2]
    end
  end
  return ids, total
end

-- знание разделами по базам: { {title = название базы | nil (страницы вне баз), total = документов в базе,
-- docs = { {text, edited ("" — неизвестно), title (название документа, "" — нет)} … }} … }; разделы — по названию
-- базы (вне баз — последним), документы — по названию.
-- Название базы первой строкой документа (так его пишет источник, notion_text.doc) не повторяется: раздел его
-- уже назвал; документ, в котором после этого остались одни пробелы (NONEMPTY), — не знание: ни в docs, ни в total, ни
-- в пороге недавнего. max_chars — только недавно изменённое до порога (recent_ids); раздел, из которого ничего не
-- отобрано, не отдаётся. Сначала id и знаки, потом тексты отобранных: по текстам остальных запрос не считает
-- (непустота — колонка docs.nonempty, её пишет запись) и их не отдаёт.
-- Всё — одной транзакцией: синхронизация из дочернего процесса не удалит и не перепишет документ между шагами.
-- -> sections, знаков в отобранных документах
function K:sections(max_chars)
  local out, total = {}, 0
  tx(self.conn, function()
    local chosen = max_chars and recent_ids(self.conn, max_chars)
    -- без NULL: rows копирует строку до первой дыры
    local list = rows(self.conn, "SELECT d.id, d.chars, coalesce(d.source_id, ''), coalesce(s.title, ''), " ..
      "coalesce(d.edited, ''), coalesce(d.title, '') FROM docs d LEFT JOIN sources s ON s.id = d.source_id " ..
      "WHERE d.nonempty = 1" ..
      " ORDER BY s.title IS NULL, s.title, d.source_id, d.title, d.id")
    local stmt = self.conn:prepare("SELECT text FROM docs WHERE id = ?")
    local sec, key
    for _, r in ipairs(list) do
      local id, chars, source_id, title, edited, doc_title = r[1], r[2], r[3], r[4], r[5], r[6]
      if source_id ~= key then
        key = source_id
        sec = { title = title ~= "" and title or nil, total = 0, docs = {} }
        out[#out + 1] = sec
      end
      sec.total = sec.total + 1
      if not chosen or chosen[id] then
        stmt:reset()
        stmt:bind(id)
        local text = stmt:step()[1]
        if sec.title and (text == sec.title or text:sub(1, #sec.title + 1) == sec.title .. "\n") then
          text = text:sub(#sec.title + 1):gsub("^\n+", "")
        end
        sec.docs[#sec.docs + 1] = { text = text, edited = edited, title = doc_title }
        total = total + chars
      end
    end
    stmt:close()
  end)
  local nonempty = {}
  for _, sec in ipairs(out) do
    if #sec.docs > 0 then nonempty[#nonempty + 1] = sec end
  end
  return nonempty, total
end

return knowledge
