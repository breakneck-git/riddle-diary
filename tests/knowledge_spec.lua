require("sqlite_shim")
local t = require("t")
local knowledge = require("riddle.knowledge")

local paths = {}

local function fresh()
  local path = os.tmpname()
  paths[#paths + 1] = path
  return knowledge.open(path), path
end

local function cleanup()
  for _, p in ipairs(paths) do os.remove(p) end
end

-- значение первой колонки первой строки запроса
local function scalar(K, sql)
  local stmt = K.conn:prepare(sql)
  local row = stmt:step()
  local v = row and row[1]
  stmt:close()
  if type(v) == "cdata" then v = tonumber(v) end
  return v
end

local function doc(id, edited, text, source_id)
  return { id = id, source_id = source_id, title = "Т-" .. id, edited = edited, text = text, props_json = "[]" }
end

local tests = {}

function tests.test_path_and_schema_version()
  t.eq(knowledge.PATH, "/mnt/us/riddle/knowledge.sqlite3")
  local K = fresh()
  t.eq(scalar(K, "PRAGMA user_version"), 4)
  t.eq(scalar(K, "PRAGMA busy_timeout"), 2000)
  K:close()
end

-- чтение без ожидания (поток интерфейса): второй аргумент open — свой busy_timeout, общий (2000) остаётся по умолчанию
function tests.test_open_busy_ms_overrides_default()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local K = knowledge.open(path, 0)
  t.eq(scalar(K, "PRAGMA busy_timeout"), 0)
  K:close()
  K = knowledge.open(path)
  t.eq(scalar(K, "PRAGMA busy_timeout"), 2000)
  K:close()
end

function tests.test_put_doc_and_edited_map()
  local K = fresh()
  K:put_source("ds1", "Фильмы")
  K:put_doc(doc("a", "2026-10-25T10:00:00.000Z", "текст а", "ds1"))
  K:put_doc(doc("b", "2026-10-25T11:00:00.000Z", "текст б"))
  K:put_doc(doc("a", "2026-10-25T12:00:00.000Z", "текст а2", "ds1")) -- замена
  local m = K:edited_map()
  t.eq(m.a, "2026-10-25T12:00:00.000Z")
  t.eq(m.b, "2026-10-25T11:00:00.000Z")
  t.eq(scalar(K, "SELECT count(*) FROM docs"), 2)
  t.eq(scalar(K, "SELECT text FROM docs WHERE id = 'a'"), "текст а2")
  t.eq(scalar(K, "SELECT source_id FROM docs WHERE id = 'a'"), "ds1")
  t.eq(scalar(K, "SELECT title FROM sources WHERE id = 'ds1'"), "Фильмы")
  K:put_source("ds1", "Кино")
  t.eq(scalar(K, "SELECT title FROM sources WHERE id = 'ds1'"), "Кино")
  K:close()
end

-- forget_edited: документ и текст остаются, edited снят — в edited_map его нет (sync перечитает)
function tests.test_forget_edited_keeps_doc()
  local K = fresh()
  K:put_doc(doc("a", "2026-10-25T10:00:00.000Z", "текст а"))
  K:put_doc(doc("b", "2026-10-25T11:00:00.000Z", "текст б"))
  K:forget_edited("a")
  local m = K:edited_map()
  t.eq(m.a, nil)
  t.eq(m.b, "2026-10-25T11:00:00.000Z")
  t.eq(scalar(K, "SELECT text FROM docs WHERE id = 'a'"), "текст а")
  t.eq(scalar(K, "SELECT count(*) FROM docs"), 2)
  K:close()
end

function tests.test_delete_missing()
  local K = fresh()
  K:put_source("ds1", "Фильмы")
  K:put_source("ds2", "Книги")
  K:put_doc(doc("a", "e1", "а", "ds1"))
  K:put_doc(doc("b", "e1", "б", "ds2"))
  K:put_doc(doc("c", "e1", "в"))
  local n = K:delete_missing({ a = true, c = true, ds1 = true })
  t.eq(n, 1, "удалён один документ")
  local m = K:edited_map()
  t.ok(m.a and m.c and not m.b)
  t.eq(scalar(K, "SELECT count(*) FROM sources"), 1)
  t.eq(scalar(K, "SELECT id FROM sources"), "ds1")
  t.eq(K:delete_missing({}), 2, "пустой набор — удалить всё")
  t.eq(K:stats().docs, 0)
  K:close()
end

function tests.test_meta_roundtrip_survives_reopen()
  local K, path = fresh()
  t.eq(K:meta("last_ok"), nil)
  K:set_meta("last_ok", 1761400000)
  K:set_meta("started_prev", "1761399000")
  K:set_meta("last_ok", 1761400500)
  K:close()
  local K2 = knowledge.open(path)
  t.eq(K2:meta("last_ok"), "1761400500")
  t.eq(K2:meta("started_prev"), "1761399000")
  t.eq(scalar(K2, "PRAGMA user_version"), 4, "повторное открытие схему не трогает")
  K2:close()
end

-- метки по префиксу (sync: "read:<id>"); % и _ в префиксе — обычные символы, не шаблон LIKE
function tests.test_meta_prefix_and_delete_prefix()
  local K = fresh()
  K:set_meta("read:a", 10)
  K:set_meta("read:b", "20")
  K:set_meta("reading", "x")
  K:set_meta("last_ok", 5)
  K:set_meta("r%_d:c", 1)
  local m = K:meta_prefix("read:")
  t.eq(m.a, "10")
  t.eq(m.b, "20")
  local n = 0
  for _ in pairs(m) do n = n + 1 end
  t.eq(n, 2, "только read:*")
  t.eq(next(K:meta_prefix("r%_")), "d:c", "без шаблона LIKE")
  K:delete_meta_prefix("read:")
  t.eq(next(K:meta_prefix("read:")), nil)
  t.eq(K:meta("reading"), "x")
  t.eq(K:meta("last_ok"), "5")
  t.eq(K:meta("r%_d:c"), "1")
  K:close()
end

function tests.test_stats_counts_chars_not_bytes()
  local K = fresh()
  K:put_doc(doc("a", "e", "дюна")) -- 4 знака, 8 байт
  K:put_doc(doc("b", "e", "ab"))
  local s = K:stats()
  t.eq(s.docs, 2)
  t.eq(s.chars, 6)
  K:close()
end

-- COMMIT упал (диск, занято): откат, транзакция не остаётся открытой, документа нет
function tests.test_failed_commit_rolls_back()
  local K = fresh()
  local real = K.conn
  K.conn = setmetatable({
    exec = function(_, sql)
      if sql == "COMMIT" then error("disk I/O error", 0) end
      return real:exec(sql)
    end,
  }, { __index = function(_, k) return function(_, ...) return real[k](real, ...) end end })
  local ok, err = pcall(K.put_doc, K, doc("a", "e", "текст"))
  t.eq(ok, false)
  t.eq(err, "disk I/O error")
  K.conn = real
  t.ok(pcall(real.exec, real, "BEGIN"), "транзакция не осталась открытой")
  real:exec("ROLLBACK")
  t.eq(K:edited_map().a, nil, "документ не записан")
  K:close()
end

function tests.test_close_twice_is_safe()
  local K = fresh()
  K:close()
  K:close()
end

-- тексты документов разделов подряд (разделы и документы — в их порядке)
local function flat(sections)
  local out = {}
  for _, sec in ipairs(sections) do
    for _, d in ipairs(sec.docs) do out[#out + 1] = d.text end
  end
  return out
end

-- тексты разделов множеством: недавнее отбирает по свежести, а раскладывает по базам
local function text_set(sections)
  local out = flat(sections)
  table.sort(out)
  return table.concat(out, "|")
end

-- знание разделами по базам (по названию базы), внутри — по названию документа; страницы вне баз — последним
-- разделом без названия. Название базы первой строкой документа (так его пишет источник) в разделе не повторяется
function tests.test_sections_group_by_source()
  local K = fresh()
  local empty, none = K:sections()
  t.eq(#empty, 0, "пустая база")
  t.eq(none, 0)
  K:put_source("ds2", "Фильмы")
  K:put_source("ds1", "Книги")
  K:put_doc({ id = "p", title = "Аптечка", edited = "e", text = "Аптечка\n\nСТРАНИЦА" })
  K:put_doc({ id = "f2", source_id = "ds2", title = "Брат", edited = "e2", text = "Фильмы\nName: Брат\n\nФИЛЬМ-Б" })
  K:put_doc({ id = "k1", source_id = "ds1", title = "Ясно", edited = "e", text = "Книги\nName: Ясно" })
  K:put_doc({ id = "f1", source_id = "ds2", title = "Апокалипсис", edited = "e1", text = "Фильмы\nName: Апокалипсис" })
  local secs, chars = K:sections()
  t.eq(#secs, 3, "две базы и страницы вне баз")
  t.eq(secs[1].title, "Книги")
  t.eq(secs[1].total, 1)
  t.eq(secs[2].title, "Фильмы")
  t.eq(secs[2].total, 2)
  t.eq(secs[3].title, nil, "вне баз — без названия")
  t.eq(secs[3].total, 1)
  t.eq(table.concat(flat(secs), "|"), "Name: Ясно|Name: Апокалипсис|Name: Брат\n\nФИЛЬМ-Б|Аптечка\n\nСТРАНИЦА",
    "по названию документа; название базы не повторяется, у страницы вне баз своё название осталось")
  t.eq(secs[2].docs[1].edited, "e1", "свежесть — для урезания")
  t.eq(chars, K:stats().chars, "знаки всех документов")
  -- документ, первая строка которого не название базы (база переименована), — как есть
  K:put_source("ds1", "Книги-2")
  t.eq(K:sections()[1].docs[1].text, "Книги\nName: Ясно", "чужая первая строка не срезается")
  K:close()
end

-- название базы срезается только целой первой строкой: строка, которая с него лишь начинается, — часть документа
function tests.test_sections_keep_line_that_only_starts_with_source_title()
  local K = fresh()
  K:put_source("ds", "Фильмы")
  K:put_doc({ id = "a", source_id = "ds", title = "А", edited = "e", text = "Фильмы 2024\nName: А" })
  K:put_doc({ id = "b", source_id = "ds", title = "Б", edited = "e", text = "Фильмы" })
  local sec = K:sections()[1]
  t.eq(sec.docs[1].text, "Фильмы 2024\nName: А", "«Фильмы 2024» — не название базы")
  t.eq(#sec.docs, 1, "документ из одного названия базы пуст — его нет")
  t.eq(sec.total, 1, "всего — без пустого")
  K:close()
end

-- документ, в котором после названия базы только пробелы и переводы строк, или пустой вне баз, — не знание:
-- в раздел не идёт, во «всего» не считается; база из одних пустых раздела не даёт
function tests.test_sections_skip_empty_docs()
  local K = fresh()
  K:put_source("ds", "Фильмы")
  K:put_source("e", "Пусто")
  K:put_doc({ id = "a", source_id = "ds", title = "А", edited = "e", text = "Фильмы\nName: А" })
  K:put_doc({ id = "b", source_id = "ds", title = "Б", edited = "e", text = "Фильмы\n \t\n" })
  K:put_doc({ id = "c", source_id = "e", title = "В", edited = "e", text = "Пусто" })
  K:put_doc({ id = "d", title = "Г", edited = "e", text = "Аптечка" })
  K:put_doc({ id = "f", title = "Д", edited = "e", text = " \n" })
  local secs = K:sections()
  t.eq(#secs, 2, "«Пусто» — только пустые: раздела нет")
  t.eq(secs[1].title, "Фильмы")
  t.eq(secs[1].total, 1)
  t.eq(table.concat(flat({ secs[1] }), "|"), "Name: А")
  t.eq(secs[2].title, nil)
  t.eq(secs[2].total, 1)
  t.eq(table.concat(flat({ secs[2] }), "|"), "Аптечка")
  K:close()
end

-- пустой документ не съедает порог недавнего: свежий пустой не отбирается, старый непустой влезает
function tests.test_sections_recent_skip_empty_docs()
  local K = fresh()
  K:put_source("ds", "Фильмы")
  K:put_doc({ id = "e", source_id = "ds", title = "Е", edited = "2026-10-25T12:00:00.000Z", text = "Фильмы" })
  K:put_doc({ id = "a", source_id = "ds", title = "А", edited = "2026-10-25T10:00:00.000Z", text = "Фильмы\nА" })
  local secs, chars = K:sections(8)
  t.eq(table.concat(flat(secs), "|"), "А")
  t.eq(chars, 8)
  t.eq(secs[1].total, 1)
  K:close()
end

-- недавнее: по edited убыв., документы целиком, сумма знаков (не байтов) ≤ max_chars; не влез — пропущен,
-- следующие ещё могут влезть; без edited (снят forget_edited) — последними
function tests.test_sections_recent_newest_first_within_cap()
  local K = fresh()
  local ten = string.rep("я", 10)
  K:put_doc({ id = "a", edited = "2026-10-25T10:00:00.000Z", text = "а" .. ten:sub(3) })
  K:put_doc({ id = "b", edited = "2026-10-25T12:00:00.000Z", text = "б" .. ten:sub(3) })
  K:put_doc({ id = "c", edited = "2026-10-25T11:00:00.000Z", text = "в" .. ten:sub(3) })
  K:put_doc({ id = "big", edited = "2026-10-25T13:00:00.000Z", text = string.rep("ж", 40) })
  K:put_doc({ id = "old", edited = "2026-10-25T09:00:00.000Z", text = "г" .. ten:sub(3) })
  K:put_doc({ id = "nul", edited = "x", text = "д" .. ten:sub(3) })
  K:forget_edited("nul")
  local secs, chars = K:sections(30)
  t.eq(text_set(secs), text_set({ { docs = { { text = "б" .. ten:sub(3) }, { text = "в" .. ten:sub(3) },
    { text = "а" .. ten:sub(3) } } } }))
  t.eq(chars, 30, "знаки, не байты")
  t.eq(secs[1].total, 6, "всего — все документы раздела, не только отобранные")
  secs, chars = K:sections(50)
  t.eq(text_set(secs), text_set({ { docs = { { text = string.rep("ж", 40) }, { text = "б" .. ten:sub(3) } } } }))
  t.eq(chars, 50)
  -- без edited — последним: влезает, только когда влезли все с edited
  t.ok(not text_set(K:sections(80)):find("д", 1, true), "без edited не раньше свежих")
  t.ok(text_set(K:sections(90)):find("д", 1, true), "без edited — последним")
  -- база, из которой ничего не отобрано, раздела не даёт
  K:put_source("ds", "Старьё")
  K:put_doc({ id = "s1", source_id = "ds", title = "С", edited = "2026-01-01T00:00:00.000Z", text = "Старьё\nС" })
  secs = K:sections(30)
  t.eq(#secs, 1, "раздела без документов нет")
  t.eq(secs[1].title, nil)
  K:close()
end

-- обёртка над настоящим соединением sqlite: вызовы уходят в него как есть, каждое значение каждой строки
-- выборки попадает в seen; выражения вида stmt:bind(...):step() тоже идут через обёртку
local function recording(conn, seen)
  local function proxy(obj, on_result)
    local p
    p = setmetatable({}, { __index = function(_, k)
      local f = obj[k]
      if type(f) ~= "function" then return f end
      return function(_, ...)
        local res = { f(obj, ...) }
        for i = 1, #res do
          if res[i] == obj then res[i] = p end
        end
        return on_result(k, unpack(res))
      end
    end })
    return p
  end
  local function on_stmt(k, row, ...)
    if k == "step" and type(row) == "table" then
      for _, v in ipairs(row) do seen[#seen + 1] = v end
    end
    return row, ...
  end
  return proxy(conn, function(k, stmt, ...)
    if k == "prepare" then return proxy(stmt, on_stmt), ... end
    return stmt, ...
  end)
end

-- недавнее читает из базы тексты только тех документов, что уходят в ответ: сначала id и знаки,
-- потом тексты отобранных; тексты не влезших до цикла интерфейса не доходят
function tests.test_sections_recent_reads_only_chosen_texts()
  local K = fresh()
  local texts = {
    a = "ТЕКСТ-А" .. string.rep("я", 3), b = "ТЕКСТ-Б" .. string.rep("я", 3),
    big = "ТЕКСТ-БОЛЬШОЙ" .. string.rep("ж", 40), old = "ТЕКСТ-СТАРЫЙ" .. string.rep("я", 3),
  }
  K:put_doc({ id = "a", edited = "2026-10-25T10:00:00.000Z", text = texts.a })
  K:put_doc({ id = "b", edited = "2026-10-25T12:00:00.000Z", text = texts.b })
  K:put_doc({ id = "big", edited = "2026-10-25T13:00:00.000Z", text = texts.big })
  K:put_doc({ id = "old", edited = "2026-10-25T09:00:00.000Z", text = texts.old })
  local real, seen = K.conn, {}
  K.conn = recording(real, seen)
  local secs, chars = K:sections(20)
  K.conn = real
  t.eq(text_set(secs), text_set({ { docs = { { text = texts.b }, { text = texts.a } } } }))
  t.eq(chars, 20)
  local fetched = {}
  for _, v in ipairs(seen) do
    for id, tx in pairs(texts) do
      if v == tx then fetched[#fetched + 1] = id end
    end
  end
  table.sort(fetched)
  t.ok(#seen > 0, "шпион видел строки выборки")
  t.eq(table.concat(fetched, ","), "a,b", "из базы прочитаны только тексты отобранных документов")
  K:close()
end

-- синхронизация пишет в ту же базу из дочернего процесса: удаление между выбором id и чтением текстов
-- не ломает недавнее — оба шага видят одну и ту же базу (второе соединение = писатель, без ожидания)
function tests.test_sections_consistent_while_sync_writes()
  local K, path = fresh()
  K:put_doc({ id = "a", edited = "2026-10-25T10:00:00.000Z", text = "А" })
  K:put_doc({ id = "b", edited = "2026-10-25T12:00:00.000Z", text = "Б" })
  local writer = knowledge.open(path)
  writer.conn:exec("PRAGMA busy_timeout = 0")
  local real, prepares, attempted = K.conn, 0, false
  K.conn = setmetatable({}, { __index = function(_, k)
    local f = real[k]
    if type(f) ~= "function" then return f end
    return function(_, ...)
      if k == "prepare" then
        prepares = prepares + 1
        if prepares == 3 then -- id и строки разделов уже выбраны, тексты ещё нет
          attempted = true
          pcall(writer.delete_missing, writer, {})
        end
      end
      return f(real, ...)
    end
  end })
  local ok, secs, chars = pcall(K.sections, K, 100)
  K.conn = real
  t.ok(attempted, "писатель вмешался между запросами")
  t.ok(ok, "недавнее не упало: " .. tostring(secs))
  t.eq(ok and text_set(secs), "А|Б")
  t.eq(chars, 2)
  -- после чтения база отпущена, хотя соединение ещё открыто: писатель удаляет без ожидания
  local wok, werr = pcall(writer.delete_missing, writer, {})
  writer:close()
  t.ok(wok, "база заперта после недавнего: " .. tostring(werr))
  K:close()
end

-- недавнее по прежнему правилу (запрос среза 4: все тексты по edited убыв., жадно до порога) — тот же текст
-- и те же знаки на разных порогах: повторы edited, без edited (NULL), пустой edited, не влезающие документы
local function old_recent_text(K, max_chars)
  local parts, total = {}, 0
  local stmt = K.conn:prepare("SELECT text, chars FROM docs ORDER BY edited IS NULL, edited DESC, id")
  while true do
    local r = stmt:step()
    if not r then break end
    local c = tonumber(r[2])
    if total + c <= max_chars then
      parts[#parts + 1] = r[1]
      total = total + c
    end
  end
  stmt:close()
  table.sort(parts)
  return table.concat(parts, "|"), total
end

function tests.test_sections_recent_same_as_old_rule()
  local K = fresh()
  math.randomseed(20261025)
  local letters = { "a", "я", "ж", "€", "z" }
  for i = 1, 80 do
    local n = math.random(1, 60)
    local buf = {}
    for j = 1, n do buf[j] = letters[math.random(#letters)] end
    local edited = ({ "2026-10-25T10:00:00.000Z", "2026-10-24T10:00:00.000Z",
      string.format("2026-10-%02dT08:00:00.000Z", math.random(1, 23)), nil })[math.random(4)]
    K:put_doc({ id = string.format("d%03d", 81 - i), edited = edited, text = "#" .. i .. table.concat(buf) })
    if i % 9 == 0 then K:forget_edited(string.format("d%03d", 81 - i)) end
  end
  for _, cap in ipairs({ 0, 1, 5, 40, 61, 333, 1000, 2400, 100000 }) do
    local want_text, want_chars = old_recent_text(K, cap)
    local secs, chars = K:sections(cap)
    t.eq(chars, want_chars, "знаки при пороге " .. cap)
    t.ok(text_set(secs) == want_text, "документы при пороге " .. cap)
  end
  K:close()
end

-- база v1 (таблицы до общего формата) с документом: open доводит до v4 и не трогает sources, docs, meta
function tests.test_migration_v1_keeps_docs()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("CREATE TABLE sources(id TEXT PRIMARY KEY, title TEXT)")
  conn:exec("CREATE TABLE docs(id TEXT PRIMARY KEY, source_id TEXT, title TEXT, edited TEXT, " ..
    "text TEXT, props_json TEXT, chars INT)")
  conn:exec("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)")
  conn:exec("INSERT INTO sources VALUES('ds1', 'Фильмы')")
  conn:exec("INSERT INTO docs VALUES('a', 'ds1', 'Т-а', '2026-10-25T10:00:00.000Z', 'текст а', '[]', 7)")
  conn:exec("INSERT INTO meta VALUES('last_ok', '1761400000')")
  conn:exec("PRAGMA user_version = 1")
  conn:close()

  local K = knowledge.open(path)
  t.eq(scalar(K, "PRAGMA user_version"), 4)
  t.eq(K:edited_map().a, "2026-10-25T10:00:00.000Z", "документ v1 на месте")
  t.eq(scalar(K, "SELECT text FROM docs WHERE id = 'a'"), "текст а")
  t.eq(scalar(K, "SELECT title FROM sources WHERE id = 'ds1'"), "Фильмы")
  t.eq(K:meta("last_ok"), "1761400000")
  t.eq(table.concat(flat(K:sections()), "|"), "текст а")
  t.eq(#K:collections(), 0, "общий формат пуст")
  K:close()
end

-- база v2 руками; extra_docs_col — лишний столбец docs (имитация сорванной миграции)
local function v2_db(extra_docs_col)
  local path = os.tmpname()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("CREATE TABLE sources(id TEXT PRIMARY KEY, title TEXT)")
  conn:exec("CREATE TABLE docs(id TEXT PRIMARY KEY, source_id TEXT, title TEXT, edited TEXT, " ..
    "text TEXT, props_json TEXT, chars INT" .. (extra_docs_col and (", " .. extra_docs_col) or "") .. ")")
  conn:exec("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)")
  conn:exec("CREATE TABLE collections(id TEXT PRIMARY KEY, title TEXT, source TEXT, items INT, " ..
    "task_candidate INT, native_tasks INT, depth INT, model_pick INT)")
  conn:exec("CREATE TABLE tasks(id TEXT PRIMARY KEY, collection_id TEXT, title TEXT, open INT, " ..
    "archived INT, project TEXT, due TEXT, edited TEXT)")
  conn:exec("CREATE TABLE core(k TEXT PRIMARY KEY, v TEXT)")
  conn:exec("INSERT INTO sources VALUES('ds', 'Фильмы')")
  local cols = "(id, source_id, title, edited, text, props_json, chars)"
  conn:exec("INSERT INTO docs" .. cols .. " VALUES('a', 'ds', 'А', 'e', 'Фильмы' || char(10) || 'Name: А', '[]', 14)")
  conn:exec("INSERT INTO docs" .. cols .. " VALUES('b', 'ds', 'Б', 'e', 'Фильмы', '[]', 6)")
  conn:exec("INSERT INTO docs" .. cols .. " VALUES('c', 'ds', 'В', 'e', 'Фильмы' || char(10, 32, 9, 10), '[]', 10)")
  conn:exec("INSERT INTO docs" .. cols .. " VALUES('d', NULL, 'Г', 'e', ' ' || char(10), '[]', 2)")
  conn:exec("INSERT INTO docs" .. cols .. " VALUES('f', NULL, 'Д', 'e', 'Аптечка', '[]', 7)")
  conn:exec("INSERT INTO docs" .. cols .. " VALUES('g', 'late', 'Е', 'e', 'Поздно', '[]', 6)")
  conn:exec("INSERT INTO docs" .. cols .. " VALUES('n', NULL, 'Ж', 'e', NULL, '[]', 0)")
  conn:exec("INSERT INTO core VALUES('tasks_source', 'Дела')")
  conn:exec("PRAGMA user_version = 2")
  conn:close()
  return path
end

local function nonempty_of(K)
  local out = {}
  for _, id in ipairs({ "a", "b", "c", "d", "f", "g", "n" }) do
    out[#out + 1] = id .. "=" .. tostring(scalar(K, "SELECT nonempty FROM docs WHERE id = '" .. id .. "'"))
  end
  return table.concat(out, " ")
end

-- v2 → v3: колонка nonempty заполнена для уже лежащих документов тем же условием, что раньше считалось в запросе;
-- документ, чья база ещё не записана, — непуст по своему тексту, после put_source базы — пересчитан
function tests.test_migration_v2_to_v3_fills_nonempty()
  local K = knowledge.open(v2_db())
  t.eq(scalar(K, "PRAGMA user_version"), 4)
  t.eq(nonempty_of(K), "a=1 b=0 c=0 d=0 f=1 g=1 n=0")
  t.eq(table.concat(flat(K:sections()), "|"), "Name: А|Аптечка|Поздно", "разделы как до миграции")
  t.eq(K:core("tasks_source"), "Дела", "v2 не тронута")
  K:put_source("late", "Поздно")
  t.eq(nonempty_of(K), "a=1 b=0 c=0 d=0 f=1 g=0 n=0", "база записана — её название срезано, документ пуст")
  t.eq(table.concat(flat(K:sections()), "|"), "Name: А|Аптечка")
  K:close()
end

-- миграция 3 сорвалась посреди (колонка уже есть — ADD COLUMN падает): open — ошибка, шаг откатан целиком
function tests.test_migration_v3_failure_rolls_back()
  local path = v2_db("nonempty INT")
  local ok, err = pcall(knowledge.open, path)
  t.ok(not ok, "open падает")
  t.ok(tostring(err):find("nonempty", 1, true), tostring(err))
  local conn = require("lua-ljsqlite3/init").open(path)
  local stmt = conn:prepare("PRAGMA user_version")
  t.eq(tonumber(stmt:step()[1]), 2, "версия не сдвинута")
  stmt:close()
  stmt = conn:prepare("SELECT count(*), count(nonempty) FROM docs")
  local row = stmt:step()
  t.eq(tonumber(row[1]), 7, "документы целы")
  t.eq(tonumber(row[2]), 0, "backfill откатан")
  stmt:close()
  conn:close()
end

-- непустота читается из колонки, а не считается по тексту в запросе
function tests.test_sections_read_nonempty_column()
  local K = fresh()
  K:put_doc({ id = "a", edited = "2026-10-25T10:00:00.000Z", text = "А" })
  K:put_doc({ id = "b", edited = "2026-10-25T12:00:00.000Z", text = "Б" })
  K.conn:exec("UPDATE docs SET nonempty = 0 WHERE id = 'b'")
  t.eq(table.concat(flat(K:sections()), "|"), "А", "весь")
  t.eq(table.concat(flat(K:sections(100)), "|"), "А", "недавнее")
  K:close()
end

-- непустота следует за названием базы: переименование, база записана после документа, база удалена
function tests.test_nonempty_follows_source_title()
  local K = fresh()
  K:put_source("ds", "Фильмы")
  K:put_doc({ id = "b", source_id = "ds", title = "Б", edited = "e", text = "Фильмы" })
  t.eq(#K:sections(), 0, "одно название базы — пуст")
  K:put_source("ds", "Кино")
  t.eq(table.concat(flat(K:sections()), "|"), "Фильмы", "база переименована — первая строка уже знание")
  K:put_source("ds", "Фильмы")
  t.eq(#K:sections(), 0, "переименована обратно — снова пуст")
  K:put_doc({ id = "h", source_id = "late", title = "Х", edited = "e", text = "Поздно" })
  t.eq(table.concat(flat(K:sections()), "|"), "Поздно", "базы ещё нет — текст как есть")
  K:put_source("late", "Поздно")
  t.eq(#K:sections(), 0, "база записана — пуст")
  t.eq(K:delete_missing({ b = true, h = true }), 0, "документы остались")
  t.eq(table.concat(flat(K:sections()), "|"), "Фильмы|Поздно", "базы удалены — названия не срезаются")
  K:close()
end

-- один оператор SQL с параметрами через prepare (conn:exec режет текст по «;», а тело триггера их содержит)
local function raw(conn, sql_text, ...)
  local stmt = conn:prepare(sql_text)
  stmt:bind(...)
  stmt:step()
  stmt:close()
end

-- запись сборкой до 227ff27 (SCHEMA_VERSION 2): docs без колонки nonempty, базы без пересчёта документов
local old_build = {
  put_source = function(conn, id, title)
    raw(conn, "INSERT OR REPLACE INTO sources(id, title) VALUES(?, ?)", id, title)
  end,
  put_doc = function(conn, id, source_id, text)
    raw(conn, "INSERT OR REPLACE INTO docs(id, source_id, title, edited, text, props_json, chars) " ..
      "VALUES(?, ?, ?, 'e', ?, '[]', 1)", id, source_id, "Т-" .. id, text)
  end,
  delete_source = function(conn, id)
    raw(conn, "DELETE FROM sources WHERE id = ?", id)
  end,
}

-- откат на старую сборку: её записи в базу новой схемы новый код видит так же, как свои
function tests.test_nonempty_survives_old_build_writes()
  local K = fresh()
  old_build.put_source(K.conn, "ds", "Фильмы")
  old_build.put_doc(K.conn, "a", "ds", "Фильмы\nName: А")
  K:put_doc({ id = "c", source_id = "ds", title = "Т-c", edited = "e", text = "Фильмы\nName: В" })
  old_build.put_doc(K.conn, "b", "ds", "Фильмы")
  t.eq(table.concat(flat(K:sections()), "|"), "Name: А|Name: В", "документ старой сборки виден, пустой — нет")
  old_build.put_source(K.conn, "ds", "Кино")
  t.eq(table.concat(flat(K:sections()), "|"), "Фильмы\nName: А|Фильмы|Фильмы\nName: В",
    "база переименована старой сборкой (INSERT OR REPLACE) — пересчитано")
  old_build.put_source(K.conn, "ds", "Фильмы")
  old_build.put_doc(K.conn, "h", "late", "Поздно")
  t.eq(table.concat(flat(K:sections()), "|"), "Name: А|Name: В|Поздно", "обратно; база документа h ещё не записана")
  old_build.put_source(K.conn, "late", "Поздно")
  t.eq(table.concat(flat(K:sections()), "|"), "Name: А|Name: В", "база записана старой сборкой — h пуст")
  old_build.delete_source(K.conn, "late")
  t.eq(table.concat(flat(K:sections()), "|"), "Name: А|Name: В|Поздно", "база удалена старой сборкой")
  K:close()
end

-- UPDATE прямым SQL (триггеры docs_nonempty_update / sources_nonempty_update): nonempty пересчитан в базе, не кодом
function tests.test_nonempty_update_triggers()
  local K = fresh()
  K:put_source("ds", "Фильмы")
  K:put_source("other", "Кино")
  K:put_doc({ id = "a", source_id = "ds", title = "А", edited = "e", text = "Фильмы" })
  local function ne() return scalar(K, "SELECT nonempty FROM docs WHERE id = 'a'") end
  t.eq(ne(), 0, "одно название базы — пуст")
  K.conn:exec("UPDATE docs SET text = 'Фильмы\nName: А' WHERE id = 'a'")
  t.eq(ne(), 1, "UPDATE text: появилось знание")
  K.conn:exec("UPDATE docs SET text = 'Фильмы' WHERE id = 'a'")
  t.eq(ne(), 0, "UPDATE text: снова только название")
  K.conn:exec("UPDATE docs SET source_id = 'other' WHERE id = 'a'")
  t.eq(ne(), 1, "UPDATE source_id: название другой базы не срезает 'Фильмы'")
  K.conn:exec("UPDATE docs SET source_id = 'ds' WHERE id = 'a'")
  t.eq(ne(), 0, "UPDATE source_id: вернули в базу 'Фильмы' — пуст")
  K.conn:exec("UPDATE sources SET title = 'Кино' WHERE id = 'ds'")
  t.eq(ne(), 1, "UPDATE title базы: первая строка уже знание")
  K.conn:exec("UPDATE sources SET title = 'Фильмы' WHERE id = 'ds'")
  t.eq(ne(), 0, "UPDATE title базы обратно — пуст")
  -- смена sources.id: документы старого id теряют базу (название не срезается), документы под новым id — получают
  K:put_doc({ id = "b", source_id = "moved", title = "Б", edited = "e", text = "Фильмы" })
  local function neb() return scalar(K, "SELECT nonempty FROM docs WHERE id = 'b'") end
  t.eq(neb(), 1, "базы 'moved' ещё нет — название не срезается")
  K.conn:exec("UPDATE sources SET id = 'moved' WHERE id = 'ds'")
  t.eq(neb(), 0, "UPDATE id базы: документ под NEW.id — название базы срезано, пуст")
  t.eq(ne(), 1, "UPDATE id базы: документ под OLD.id остался без базы — первая строка снова знание")
  K:close()
end

-- база v3, в которую писала старая сборка (nonempty = 0 у всех по DEFAULT): open пересчитывает колонку
function tests.test_migration_v3_to_v4_refreshes_nonempty()
  local path = v2_db()
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("ALTER TABLE docs ADD COLUMN nonempty INT NOT NULL DEFAULT 0")
  conn:exec("PRAGMA user_version = 3")
  conn:close()
  local K = knowledge.open(path)
  t.eq(scalar(K, "PRAGMA user_version"), 4)
  t.eq(nonempty_of(K), "a=1 b=0 c=0 d=0 f=1 g=1 n=0")
  t.eq(table.concat(flat(K:sections()), "|"), "Name: А|Аптечка|Поздно")
  K:close()
end

-- миграция сорвалась уже после ALTER / CREATE TRIGGER (на пересчёте): шаг откатан целиком, версия прежняя
function tests.test_migration_failure_after_first_step_rolls_back()
  local function abort_on_update(conn)
    raw(conn, "CREATE TRIGGER test_boom BEFORE UPDATE ON docs BEGIN SELECT RAISE(ABORT, 'boom'); END")
  end
  local function inspect(path)
    local conn = require("lua-ljsqlite3/init").open(path)
    local function one(sql_text)
      local stmt = conn:prepare(sql_text)
      local v = stmt:step()[1]
      stmt:close()
      return tonumber(v) or v
    end
    local out = {
      version = one("PRAGMA user_version"),
      column = one("SELECT count(*) FROM pragma_table_info('docs') WHERE name = 'nonempty'"),
      triggers = one("SELECT group_concat(name) FROM sqlite_master WHERE type = 'trigger'"),
      docs = one("SELECT count(*) FROM docs"),
    }
    conn:close()
    return out
  end

  local v2 = v2_db()
  local conn = require("lua-ljsqlite3/init").open(v2)
  abort_on_update(conn)
  conn:close()
  local ok, err = pcall(knowledge.open, v2)
  t.ok(not ok and tostring(err):find("boom", 1, true), "v2: open падает на пересчёте: " .. tostring(err))
  local s = inspect(v2)
  t.eq(s.version, 2, "v2: версия не сдвинута")
  t.eq(s.column, 0, "v2: ALTER откатан")
  t.eq(s.triggers, "test_boom", "v2: триггеры не созданы")
  t.eq(s.docs, 7, "v2: документы целы")

  local v3 = v2_db()
  conn = require("lua-ljsqlite3/init").open(v3)
  conn:exec("ALTER TABLE docs ADD COLUMN nonempty INT NOT NULL DEFAULT 0")
  conn:exec("PRAGMA user_version = 3")
  abort_on_update(conn)
  conn:close()
  ok, err = pcall(knowledge.open, v3)
  t.ok(not ok and tostring(err):find("boom", 1, true), "v3: open падает на пересчёте: " .. tostring(err))
  s = inspect(v3)
  t.eq(s.version, 3, "v3: версия не сдвинута")
  t.eq(s.triggers, "test_boom", "v3: CREATE TRIGGER откатан")
  t.eq(s.docs, 7, "v3: документы целы")
end

-- put_source: пересчёт документов сорвался — название базы не записано (одна транзакция)
function tests.test_put_source_failure_keeps_title()
  local K = fresh()
  K:put_source("ds", "Фильмы")
  K:put_doc({ id = "b", source_id = "ds", title = "Б", edited = "e", text = "Фильмы" })
  raw(K.conn, "CREATE TRIGGER test_boom BEFORE UPDATE ON docs BEGIN SELECT RAISE(ABORT, 'boom'); END")
  local ok, err = pcall(K.put_source, K, "ds", "Кино")
  t.ok(not ok and tostring(err):find("boom", 1, true), tostring(err))
  t.eq(scalar(K, "SELECT title FROM sources WHERE id = 'ds'"), "Фильмы", "название прежнее")
  K.conn:exec("DROP TRIGGER test_boom")
  t.eq(#K:sections(), 0, "документ по-прежнему пуст")
  t.ok(pcall(K.conn.exec, K.conn, "BEGIN"), "транзакция не осталась открытой")
  K.conn:exec("ROLLBACK")
  K:close()
end

-- текст дочернего процесса для гонки миграции: open базы arg[1] после метки arg[2]; печатает «ok|err … секунд»
local RACE_CHILD = [[
require("sqlite_shim")
local ffi = require("ffi")
ffi.cdef("typedef struct { long tv_sec; int tv_usec; } race_tv; int gettimeofday(race_tv *, void *);")
local function now()
  local tv = ffi.new("race_tv")
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end
local f = io.open(arg[2], "w")
f:close()
local t0 = now()
local ok, K = pcall(require("riddle.knowledge").open, arg[1])
local dt = now() - t0
if ok then K:close() end
io.write(ok and "ok" or ("err " .. tostring(K)), " ", string.format("%.3f", dt))
]]

-- два процесса открывают базу v2 одновременно: проигравший ждёт блокировку победителя и, перечитав версию,
-- не повторяет его шаг. Победитель — этот тест: держит запись с уже сделанным шагом 3, пока дочерний не прочтёт
-- версию 2. Дочерний обязан именно ждать (open ≥ 0.3 с): прочитай он версию после COMMIT — тест не о гонке, FAIL
function tests.test_migration_concurrent_open_waits_and_rereads_version()
  local path = v2_db()
  local script, marker = os.tmpname(), os.tmpname()
  paths[#paths + 1] = script
  paths[#paths + 1] = marker
  os.remove(marker)
  local f = assert(io.open(script, "w"))
  f:write(RACE_CHILD)
  f:close()

  local holder = require("lua-ljsqlite3/init").open(path)
  holder:exec("PRAGMA busy_timeout = 5000")
  holder:exec("BEGIN IMMEDIATE")
  holder:exec("ALTER TABLE docs ADD COLUMN nonempty INT NOT NULL DEFAULT 0")
  holder:exec("PRAGMA user_version = 3")
  local child = io.popen("luajit '" .. script .. "' '" .. path .. "' '" .. marker .. "'")
  local started = false
  for _ = 1, 100 do
    local m = io.open(marker)
    if m then
      m:close()
      started = true
      break
    end
    os.execute("sleep 0.05")
  end
  os.execute("sleep 0.5")
  local cok, cerr = pcall(holder.exec, holder, "COMMIT")
  holder:close()
  local out = child:read("*a")
  child:close()
  t.ok(started, "дочерний процесс запустился")
  t.ok(cok, "COMMIT победителя: " .. tostring(cerr))
  local status, dt = out:match("^(%S+).* ([%d.]+)$")
  t.eq(status, "ok", "open проигравшего: " .. out)
  t.ok(tonumber(dt or 0) >= 0.3, "проигравший ждал блокировку: " .. out)

  local K = knowledge.open(path)
  t.eq(scalar(K, "PRAGMA user_version"), 4)
  t.eq(nonempty_of(K), "a=1 b=0 c=0 d=0 f=1 g=1 n=0", "шаг 4 проигравшего пересчитал колонку")
  K:close()
end

local function coll(id, source, extra)
  local c = { id = id, title = "К-" .. id, source = source, items = 2, task_candidate = true, native_tasks = false,
    depth = 1, model_pick = false }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

local function task(id, collection_id, extra)
  local r = { id = id, collection_id = collection_id, title = "З-" .. id, open = true, archived = false,
    project = nil, due = nil, edited = "2026-10-25T10:00:00.000Z" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

-- снимок источника заменяет его коллекции и их задачи целиком; коллекции другого источника и их задачи целы
function tests.test_put_snapshot_replaces_only_its_source()
  local K = fresh()
  K:put_snapshot("other", { coll("o1", "other") }, { task("x", "o1") })
  K:put_snapshot("notion", { coll("n1", "notion", { native_tasks = true, depth = 0 }), coll("n2", "notion") },
    { task("a", "n1", { project = "Дом", due = "2026-11-01" }), task("b", "n1"), task("c", "n2") })
  K:put_snapshot("notion", { coll("n1", "notion", { title = "Дела", items = 5, model_pick = true }) },
    { task("a", "n1", { open = false, archived = true }) })

  local cs = K:collections()
  t.eq(#cs, 2, "n1 и o1; n2 из старого снимка снята")
  t.eq(cs[1].id, "n1")
  t.eq(cs[1].title, "Дела")
  t.eq(cs[1].source, "notion")
  t.eq(cs[1].items, 5)
  t.eq(cs[1].task_candidate, true)
  t.eq(cs[1].native_tasks, false)
  t.eq(cs[1].model_pick, true)
  t.eq(cs[1].depth, 1)
  t.eq(cs[2].id, "o1")

  local n1 = K:tasks_of("n1")
  t.eq(#n1, 1, "b снята вместе со старым снимком")
  t.eq(n1[1].id, "a")
  t.eq(n1[1].collection_id, "n1")
  t.eq(n1[1].title, "З-a")
  t.eq(n1[1].open, false)
  t.eq(n1[1].archived, true)
  t.eq(n1[1].project, nil, "project nil — NULL")
  t.eq(n1[1].due, nil)
  t.eq(n1[1].edited, "2026-10-25T10:00:00.000Z")
  t.eq(#K:tasks_of("n2"), 0, "задачи снятой коллекции сняты")
  t.eq(#K:tasks_of("o1"), 1, "чужой источник цел")
  t.eq(K:tasks_of("o1")[1].id, "x")
  K:close()
end

-- project и due доходят до tasks_of как есть; ошибка посреди снимка — откат, прежний снимок цел
function tests.test_put_snapshot_fields_and_rollback()
  local K = fresh()
  K:put_snapshot("notion", { coll("n1", "notion") }, { task("a", "n1", { project = "Дом", due = "2026-11-01" }) })
  local a = K:tasks_of("n1")[1]
  t.eq(a.project, "Дом")
  t.eq(a.due, "2026-11-01")
  t.eq(a.open, true)
  t.eq(a.archived, false)
  local ok = pcall(K.put_snapshot, K, "notion", { coll("n2", "notion") }, { task("b", "n2", { title = {} }) })
  t.ok(not ok, "битая задача — ошибка")
  t.eq(#K:collections(), 1, "откат: прежняя коллекция")
  t.eq(K:collections()[1].id, "n1")
  t.eq(K:tasks_of("n1")[1].id, "a")
  K:close()
end

-- depth не известна (nil) — NULL, читается nil: не корень, по правилу depth не выигрывает у известной
function tests.test_put_snapshot_depth_nil_stays_unknown()
  local tasks = require("riddle.tasks")
  local K = fresh()
  local b = coll("b", "notion")
  b.depth = nil
  K:put_snapshot("notion", { coll("a", "notion", { depth = 3 }), b }, {})
  local cs = K:collections()
  t.eq(cs[1].depth, 3)
  t.eq(cs[2].depth, nil, "depth nil — NULL")
  local c, why = tasks.pick_source(cs)
  t.eq(c and c.id, "a", "известная depth раньше неизвестной")
  t.eq(why, "depth")
  K:close()
end

-- в снимок идут только задачи его коллекций: сирота и задача чужого источника не пишутся
function tests.test_put_snapshot_keeps_only_tasks_of_its_collections()
  local K = fresh()
  K:put_snapshot("other", { coll("o1", "other") }, { task("x", "o1") })
  K:put_snapshot("notion", { coll("n1", "notion") }, { task("a", "n1"), task("orph", "zz"), task("y", "o1") })
  t.eq(scalar(K, "SELECT count(*) FROM tasks WHERE collection_id = 'zz'"), 0, "сироты нет")
  t.eq(#K:tasks_of("o1"), 1, "задача чужой коллекции не дописана")
  t.eq(K:tasks_of("o1")[1].id, "x")
  t.eq(#K:tasks_of("n1"), 1)
  K:put_snapshot("notion", {}, {})
  t.eq(#K:collections(), 1, "пустой снимок — у источника ни одной коллекции")
  t.eq(scalar(K, "SELECT count(*) FROM tasks"), 1, "и ни одной задачи; чужая цела")
  K:close()
end

function tests.test_core_set_and_clear()
  local K, path = fresh()
  t.eq(K:core("tasks_source"), nil)
  K:set_core("tasks_source", "Дела")
  K:set_core("tasks_source", "Задачи")
  K:close()
  local K2 = knowledge.open(path)
  t.eq(K2:core("tasks_source"), "Задачи", "переживает переоткрытие, повтор перезаписывает")
  K2:set_core("tasks_source", nil)
  t.eq(K2:core("tasks_source"), nil, "nil — удалить")
  t.eq(scalar(K2, "SELECT count(*) FROM core"), 0)
  t.eq(K2:meta("tasks_source"), nil, "не в meta")
  K2:close()
end

-- у документа раздела — его название (docs.title): по нему контроллер сверяет советы модели (picks)
function tests.test_sections_docs_carry_title()
  local K = fresh()
  K:put_source("ds", "Фильмы")
  K:put_doc({ id = "f", source_id = "ds", title = "Брат", edited = "e", text = "Фильмы\nName: Брат" })
  K:put_doc({ id = "g", source_id = "ds", edited = "e", text = "Фильмы\nName: Без названия" })
  local docs = K:sections()[1].docs
  t.eq(docs[1].title, "", "нет названия — пустая строка")
  t.eq(docs[2].title, "Брат")
  K:close()
end

-- счётчики для страницы состояния: документы и базы (коллекции общего формата) — числами Lua, пусто — нули
function tests.test_stats_count_docs_and_collections()
  local K = fresh()
  local s = K:stats()
  t.eq(s.docs, 0); t.eq(s.collections, 0); t.eq(s.chars, 0)
  K:put_doc(doc("a", "e", "раз"))
  K:put_doc(doc("b", "e", "два"))
  K:put_snapshot("notion", { coll("n1", "notion"), coll("n2", "notion"), coll("n3", "notion") }, {})
  s = K:stats()
  t.eq(s.docs, 2, "документы")
  t.eq(s.collections, 3, "базы")
  t.eq(type(s.collections), "number", "число Lua, не int64")
  K:close()
end

local ok, err = pcall(t.run, tests)
cleanup()
if not ok then error(err) end
