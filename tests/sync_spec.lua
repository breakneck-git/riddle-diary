-- Синхронизация Notion → knowledge.sqlite3 на поддельном клиенте: перечитываются только изменённые,
-- окно 120 с от начала прошлого прогона, частичный сбой не теряет сохранённое.
require("sqlite_shim")
local t = require("t")
local knowledge = require("riddle.knowledge")
local sync = require("riddle.sync")

local paths = {}
local function tmp()
  local p = os.tmpname()
  paths[#paths + 1] = p
  return p
end
local function cleanup()
  for _, p in ipairs(paths) do os.remove(p) end
end

local function rt(s) return { { plain_text = s } } end

-- 2026-10-25T10:00:00Z
local T0 = 1792922400
local function iso(epoch) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", epoch) end

local function page(id, title, edited, parent)
  return { object = "page", id = id, last_edited_time = iso(edited),
    parent = parent or { type = "workspace", workspace = true },
    properties = { ["Название"] = { type = "title", title = rt(title) } } }
end

local function row(id, title, edited, ds)
  local p = page(id, title, edited, { type = "data_source_id", data_source_id = ds })
  p.properties["Оценка"] = { type = "number", number = 9 }
  return p
end

-- ws: { search = {objs}, rows = { [ds] = {pages} }, bodies = { [id] = text }, fail = { [id] = err },
--       gaps = { [id] = число блоков, чьи дети 404 } }
local function client(ws)
  local c = { blocks = {}, queries = {} }
  function c:search_all()
    if ws.search_err then return nil, ws.search_err end
    return ws.search
  end
  function c:query_all(id)
    c.queries[#c.queries + 1] = id
    if ws.query_err and ws.query_err[id] then return nil, ws.query_err[id] end
    return ws.rows[id] or {}
  end
  c.gets = {}
  function c:get(kind, id)
    c.gets[#c.gets + 1] = kind .. "/" .. id
    if ws.objects and ws.objects[id] then return ws.objects[id] end
    return nil, "http 404 object_not_found"
  end
  function c:blocks_text(id)
    c.blocks[#c.blocks + 1] = id
    if ws.fail and ws.fail[id] then return nil, ws.fail[id] end
    return ws.bodies[id] or "", nil, ws.gaps and ws.gaps[id] or 0
  end
  return c
end

local function workspace()
  return {
    search = {
      page("p1", "Заметки", T0),
      { object = "data_source", id = "ds1", title = rt("Фильмы"), last_edited_time = iso(T0) },
      row("r1", "Дюна", T0, "ds1"), -- строка базы приходит и в поиске: дубля быть не должно
      page("p2", "Корзина", T0),
    },
    rows = { ds1 = { row("r1", "Дюна", T0, "ds1"), row("r2", "Сталкер", T0, "ds1") } },
    bodies = { p1 = "тело заметок", r1 = "песок", r2 = "зона" },
  }
end

-- wall_at: число (часы стоят) или функция; tasks_source — значение ключа конфига
local function run_sync(ws, path, wall_at, logs, tasks_source, classify)
  local c = client(ws)
  local wall = type(wall_at) == "function" and wall_at or function() return wall_at end
  local stats = sync.run({
    client = c, store_path = path,
    wall = wall,
    clock = function() return 0 end,
    log = logs and function(m) logs[#logs + 1] = m end,
    tasks_source = tasks_source,
    classify = classify,
  })
  return stats, c
end

local function read(path)
  local K = knowledge.open(path)
  local m, meta_ok, meta_prev, s = K:edited_map(), K:meta("last_ok"), K:meta("started_prev"), K:stats()
  local stmt = K.conn:prepare("SELECT text FROM docs WHERE id = 'r1'")
  local r = stmt:step()
  local r1 = r and r[1]
  stmt:close()
  K:close()
  return { map = m, last_ok = meta_ok, started_prev = meta_prev, stats = s, r1 = r1 }
end

local tests = {}

function tests.test_first_sync_reads_all()
  local ws = workspace()
  ws.search[4].in_trash = true
  local path = tmp()
  local stats, c = run_sync(ws, path, T0 + 3600)
  t.eq(stats.err, nil)
  t.eq(stats.seen, 3, "p1, r1, r2; p2 в корзине")
  t.eq(stats.updated, 3)
  t.eq(stats.deleted, 0)
  t.eq(#c.blocks, 3)
  t.eq(c.queries[1], "ds1")
  local db = read(path)
  t.ok(db.map.p1 and db.map.r1 and db.map.r2 and not db.map.p2)
  t.eq(db.r1, "Фильмы\nНазвание: Дюна\nОценка: 9\n\nпесок")
  t.eq(db.last_ok, tostring(T0 + 3600))
  t.eq(db.started_prev, tostring(T0 + 3600))
  t.eq(stats.chars, db.stats.chars)
end

function tests.test_unchanged_docs_not_refetched()
  local path = tmp()
  run_sync(workspace(), path, T0 + 3600)
  local stats, c = run_sync(workspace(), path, T0 + 7200)
  t.eq(stats.err, nil)
  t.eq(#c.blocks, 0, "blocks_text не вызван")
  t.eq(stats.updated, 0)
  t.eq(stats.seen, 4, "p1, p2, r1, r2")
end

function tests.test_recent_window_refetched()
  local path = tmp()
  -- первый прогон начался в T0 + 60, документы правлены в T0 (за 60 с до начала — внутри окна 120 с)
  run_sync(workspace(), path, T0 + 60)
  local _, c = run_sync(workspace(), path, T0 + 7200)
  t.eq(#c.blocks, 4, "все правленые не раньше started_prev − 120 с перечитаны")
  local _, c3 = run_sync(workspace(), path, T0 + 9000)
  t.eq(#c3.blocks, 0, "окно теперь от T0 + 7200: перечитывать нечего")
end

function tests.test_changed_doc_refetched_only()
  local path = tmp()
  run_sync(workspace(), path, T0 + 3600)
  local ws = workspace()
  ws.rows.ds1[2] = row("r2", "Сталкер", T0 + 5000, "ds1")
  ws.bodies.r2 = "зона 2"
  local stats, c = run_sync(ws, path, T0 + 9000)
  t.eq(#c.blocks, 1)
  t.eq(c.blocks[1], "r2")
  t.eq(stats.updated, 1)
end

function tests.test_removed_doc_deleted()
  local path = tmp()
  run_sync(workspace(), path, T0 + 3600)
  local ws = workspace()
  table.remove(ws.search, 1) -- p1 удалена
  ws.rows.ds1[2].in_trash = true -- r2 в корзине
  local stats = run_sync(ws, path, T0 + 9000)
  t.eq(stats.deleted, 2)
  local db = read(path)
  t.ok(not db.map.p1 and not db.map.r2 and db.map.r1)
end

function tests.test_partial_sync_keeps_committed_docs()
  local path = tmp()
  local ws = workspace()
  table.remove(ws.search, 4) -- без p2: порядок p1, r1, r2
  ws.fail = { r2 = "timeout" }
  local logs = {}
  local stats = run_sync(ws, path, T0 + 3600, logs)
  t.eq(stats.err, "timeout")
  t.eq(stats.updated, 2)
  local db = read(path)
  t.ok(db.map.p1 and db.map.r1, "первые 2 в базе")
  t.eq(db.map.r2, nil)
  t.eq(db.last_ok, nil, "last_ok не обновлён")
  t.eq(db.started_prev, nil)
  t.eq(logs[#logs], "riddle: sync stopped: timeout (updated=2)")
  -- следующий прогон продолжает с несохранённого
  ws.fail = nil
  local stats2, c = run_sync(ws, path, T0 + 3700)
  t.eq(stats2.err, nil)
  t.eq(#c.blocks, 1, "сохранённые не перечитываются")
  t.eq(c.blocks[1], "r2")
  t.eq(read(path).last_ok, tostring(T0 + 3700))
end

-- постоянный 404 на одной странице не стопорит синхронизацию: страница пропущена со счётчиком,
-- остальные сохранены, прогон удачный (last_ok, started_prev); прежняя версия страницы не удаляется
function tests.test_404_page_skipped_sync_continues()
  local path = tmp()
  run_sync(workspace(), path, T0 + 3600)
  local ws = workspace()
  ws.search[1] = page("p1", "Заметки", T0 + 5000) -- p1 изменена, но тело теперь 404
  ws.rows.ds1[2] = row("r2", "Сталкер", T0 + 5000, "ds1")
  ws.bodies.r2 = "зона 2"
  ws.fail = { p1 = "http 404 object_not_found" }
  local logs = {}
  local stats, c = run_sync(ws, path, T0 + 9000, logs)
  t.eq(stats.err, nil)
  t.eq(stats.skipped, 1)
  t.eq(stats.updated, 1, "r2 сохранена")
  t.eq(#c.blocks, 2, "p1 и r2")
  local db = read(path)
  t.eq(db.map.p1, iso(T0), "старая версия p1 цела")
  t.eq(db.map.r2, iso(T0 + 5000))
  t.eq(db.last_ok, tostring(T0 + 9000))
  t.eq(db.started_prev, tostring(T0 + 9000))
  t.eq(logs[#logs]:match(" skipped=(%d+) "), "1", logs[#logs])
  -- пропущенная перечитывается в следующий раз (edited не совпадает), и только она
  ws.fail = nil
  local stats2, c2 = run_sync(ws, path, T0 + 12000)
  t.eq(stats2.skipped, 0)
  t.eq(#c2.blocks, 1)
  t.eq(c2.blocks[1], "p1")
  t.eq(read(path).map.p1, iso(T0 + 5000))
end

-- перечитывалась только из-за окна (edited совпадает) и получила 404: started_prev уходит вперёд, окно
-- закрывается — stored edited снимается, чтобы страница перечиталась (защита от округления не теряется)
function tests.test_404_in_window_only_refetched_later()
  local path = tmp()
  local ws = workspace()
  table.remove(ws.search, 4) -- без p2
  run_sync(ws, path, T0 + 60) -- документы правлены в T0 — внутри окна от T0 + 60
  ws.fail = { p1 = "http 404 object_not_found" }
  local stats = run_sync(ws, path, T0 + 7200)
  t.eq(stats.err, nil)
  t.eq(stats.skipped, 1)
  local db = read(path)
  t.eq(db.started_prev, tostring(T0 + 7200), "прогон удачный, окно ушло вперёд")
  ws.fail = nil
  local _, c = run_sync(ws, path, T0 + 9000)
  t.eq(#c.blocks, 1, "перечитана только p1: " .. table.concat(c.blocks, ","))
  t.eq(c.blocks[1], "p1")
  t.eq(read(path).map.p1, iso(T0), "p1 сохранена заново")
  local _, c2 = run_sync(ws, path, T0 + 12000)
  t.eq(#c2.blocks, 0, "после удачного чтения снова не перечитывается")
end

function tests.test_404_never_stored_page_skipped()
  local path = tmp()
  local ws = workspace()
  ws.fail = { r1 = "http 404" }
  local stats = run_sync(ws, path, T0 + 3600)
  t.eq(stats.err, nil)
  t.eq(stats.skipped, 1)
  t.eq(read(path).map.r1, nil)
end

-- неполное тело (has_more без курсора, исчерпан MAX_PAGES) — как 404: пропуск со счётчиком, прогон идёт
-- дальше; обрезанное не сохраняется, прежняя версия цела, страница перечитывается в следующий раз
function tests.test_incomplete_body_skipped_sync_continues()
  local path = tmp()
  run_sync(workspace(), path, T0 + 3600)
  local ws = workspace()
  ws.search[1] = page("p1", "Заметки", T0 + 5000)
  ws.rows.ds1[2] = row("r2", "Сталкер", T0 + 5000, "ds1")
  ws.bodies.r2 = "зона 2"
  ws.fail = { p1 = "incomplete" }
  local logs = {}
  local stats = run_sync(ws, path, T0 + 9000, logs)
  t.eq(stats.err, nil)
  t.eq(stats.skipped, 1)
  t.eq(stats.updated, 1, "r2 сохранена")
  local db = read(path)
  t.eq(db.map.p1, iso(T0), "старая версия p1 цела")
  t.eq(db.map.r2, iso(T0 + 5000))
  t.eq(db.last_ok, tostring(T0 + 9000))
  t.eq(logs[#logs]:match(" skipped=(%d+) "), "1", logs[#logs])
  ws.fail = nil
  local _, c2 = run_sync(ws, path, T0 + 12000)
  t.eq(#c2.blocks, 1)
  t.eq(c2.blocks[1], "p1")
  t.eq(read(path).map.p1, iso(T0 + 5000))
end

-- тело неполное всегда (> MAX_PAGES·100 блоков): не больше sync.MAX_FAILS попыток при том же edited,
-- дальше страница не читается (пропуск со счётчиком), пока её не правят; правка — попытки заново
function tests.test_always_incomplete_body_stops_after_max_fails()
  local path = tmp()
  local ws = workspace()
  ws.fail = { p1 = "incomplete" }
  local tries = 0
  for i = 1, sync.MAX_FAILS + 2 do
    local stats, c = run_sync(ws, path, T0 + 3600 * i)
    t.eq(stats.err, nil)
    t.eq(stats.skipped, 1, "прогон " .. i)
    for _, id in ipairs(c.blocks) do if id == "p1" then tries = tries + 1 end end
  end
  t.eq(tries, sync.MAX_FAILS, "p1 читалась не больше MAX_FAILS раз")
  ws.search[1] = page("p1", "Заметки", T0 + 50000) -- правка: попытки заново
  local _, c = run_sync(ws, path, T0 + 60000)
  t.eq(c.blocks[1], "p1", "после правки p1 снова читается")
  ws.fail = nil
  ws.search[1] = page("p1", "Заметки", T0 + 70000)
  run_sync(ws, path, T0 + 80000)
  t.eq(read(path).map.p1, iso(T0 + 70000), "прочиталась — сохранена")
end

-- счётчик неудач — подряд при том же edited: удачное чтение его сбрасывает. Прогоны через 10 с — p1
-- (edited T0) всегда в окне RECENT_S и перечитывается без правки
function tests.test_fail_counter_resets_on_success()
  local path = tmp()
  local ws = workspace()
  ws.fail = { p1 = "incomplete" }
  local at = T0
  local function next_run() at = at + 10; return run_sync(ws, path, at) end
  for _ = 1, sync.MAX_FAILS - 1 do next_run() end
  ws.fail = nil
  next_run()
  t.eq(read(path).map.p1, iso(T0))
  ws.fail = { p1 = "incomplete" }
  local tries = 0
  for _ = 1, sync.MAX_FAILS + 1 do
    local _, c = next_run()
    for _, id in ipairs(c.blocks) do if id == "p1" then tries = tries + 1 end end
  end
  t.eq(tries, sync.MAX_FAILS, "после удачи снова MAX_FAILS попыток, а не остаток")
end

-- замороженная после MAX_FAILS страница перечитывается, когда в коде поднимут notion.MAX_PAGES: тело могло
-- стать полным, а счётчик неудач — по старому потолку. MAX_PAGES хранится в метке, при смене счётчик заново
function tests.test_frozen_page_retried_after_max_pages_change()
  local notion = require("riddle.notion")
  local saved = notion.MAX_PAGES
  local ok, err = pcall(function()
    local path = tmp()
    local ws = workspace()
    ws.fail = { p1 = "incomplete" }
    local at = T0
    local function tries_in(runs)
      local n = 0
      for _ = 1, runs do
        at = at + 3600
        local _, c = run_sync(ws, path, at)
        for _, id in ipairs(c.blocks) do if id == "p1" then n = n + 1 end end
      end
      return n
    end
    t.eq(tries_in(sync.MAX_FAILS + 1), sync.MAX_FAILS, "заморожена при старом MAX_PAGES")
    local K = knowledge.open(path)
    local mark = K:meta_prefix("fail:").p1
    K:close()
    t.ok(mark and mark:find(" " .. saved .. " ", 1, true), "MAX_PAGES в метке: " .. tostring(mark))
    notion.MAX_PAGES = saved * 2
    t.eq(tries_in(sync.MAX_FAILS + 2), sync.MAX_FAILS, "новый MAX_PAGES — снова MAX_FAILS попыток")
    ws.fail = nil
    notion.MAX_PAGES = saved * 4
    tries_in(1)
    t.eq(read(path).map.p1, iso(T0), "тело стало полным — сохранено")
  end)
  notion.MAX_PAGES = saved
  if not ok then error(err, 0) end
end

-- метка старого формата «<n> <edited>» (до MAX_PAGES в метке): не разбирается — счётчик с нуля, страница
-- снова читается и после MAX_FAILS неудач замораживается уже новой меткой
function tests.test_old_format_fail_mark_counts_from_zero()
  local path = tmp()
  local ws = workspace()
  local K = knowledge.open(path)
  K:set_meta("fail:p1", sync.MAX_FAILS .. " " .. iso(T0))
  K:close()
  ws.fail = { p1 = "incomplete" }
  local tries, at = 0, T0
  for _ = 1, sync.MAX_FAILS + 2 do
    at = at + 10 -- прогоны через 10 с: p1 (edited T0) в окне RECENT_S, перечитывается без правки
    local _, c = run_sync(ws, path, at)
    for _, id in ipairs(c.blocks) do if id == "p1" then tries = tries + 1 end end
  end
  t.eq(tries, sync.MAX_FAILS, "старая метка не замораживает: снова MAX_FAILS попыток, потом заморожена")
  K = knowledge.open(path)
  local mark = K:meta_prefix("fail:").p1
  K:close()
  t.eq(mark, sync.MAX_FAILS .. " " .. require("riddle.notion").MAX_PAGES .. " " .. iso(T0), "метка нового формата")
end

-- тело с пропуском (дети synced_block 404: источник не расшарен) сохраняется, но edited страницы не
-- изменится, когда источник расшарят: страница перечитывается не чаще раза в sync.GAP_RETRY_S, пока
-- пропуск есть; тело без пропуска метку снимает
function tests.test_page_with_gap_reread_until_source_shared()
  local path = tmp()
  local ws = workspace()
  ws.bodies.p1 = "тело без источника"
  ws.gaps = { p1 = 1 }
  local function reads_p1(at)
    local stats, c = run_sync(ws, path, at)
    t.eq(stats.err, nil)
    for _, id in ipairs(c.blocks) do if id == "p1" then return true end end
    return false
  end
  t.ok(reads_p1(T0 + 3600), "первый прогон")
  local K = knowledge.open(path)
  t.eq(K:meta_prefix("gap:").p1, tostring(T0 + 3600), "метка пропуска = начало прогона")
  K:close()
  t.ok(not reads_p1(T0 + 3600 + sync.GAP_RETRY_S - 1), "раньше GAP_RETRY_S не перечитывается")
  t.ok(reads_p1(T0 + 3600 + sync.GAP_RETRY_S), "через GAP_RETRY_S перечитывается без правки")
  ws.bodies.p1 = "тело с источником"
  ws.gaps = nil
  local at = T0 + 3600 + 2 * sync.GAP_RETRY_S
  t.ok(reads_p1(at), "источник расшарили — перечитана")
  K = knowledge.open(path)
  local stmt = K.conn:prepare("SELECT text FROM docs WHERE id = 'p1'")
  local r = stmt:step()
  stmt:close()
  t.eq(next(K:meta_prefix("gap:")), nil, "без пропуска метка снята")
  K:close()
  t.ok(r and r[1]:find("тело с источником", 1, true), "сохранено новое тело")
  t.ok(not reads_p1(at + 3 * sync.GAP_RETRY_S), "без пропуска больше не перечитывается")
end

-- метка пропуска ушедшей страницы снимается удачным прогоном
function tests.test_gap_mark_of_gone_page_removed()
  local path = tmp()
  local ws = workspace()
  ws.gaps = { p1 = 1 }
  run_sync(ws, path, T0 + 3600)
  table.remove(ws.search, 1)
  run_sync(ws, path, T0 + 7200)
  local K = knowledge.open(path)
  t.eq(next(K:meta_prefix("gap:")), nil, "метка ушедшей p1 снята")
  K:close()
end

-- метка неудач ушедшей страницы снимается удачным прогоном
function tests.test_fail_mark_of_gone_page_removed()
  local path = tmp()
  local ws = workspace()
  ws.fail = { p1 = "incomplete" }
  run_sync(ws, path, T0 + 3600)
  local K = knowledge.open(path)
  t.ok(K:meta_prefix("fail:").p1, "метка есть")
  K:close()
  table.remove(ws.search, 1)
  run_sync(ws, path, T0 + 7200)
  K = knowledge.open(path)
  t.eq(next(K:meta_prefix("fail:")), nil, "метка ушедшей p1 снята")
  K:close()
end

-- не 404 и не неполное тело (сеть, 500) — по-прежнему стоп прогона, без пропуска
function tests.test_non_404_error_still_stops()
  for _, why in ipairs({ "http 500", "timeout" }) do
    local path = tmp()
    local ws = workspace()
    ws.fail = { p1 = why }
    local stats = run_sync(ws, path, T0 + 3600)
    t.eq(stats.err, why)
    t.eq(stats.skipped, 0, why)
    t.eq(read(path).map.p1, nil, "обрезанное тело не сохранено: " .. why)
    t.eq(read(path).last_ok, nil, why)
  end
end

-- после частичного сбоя уже сохранённое в нём не перечитывается: окно у них — от начала
-- сбойного прогона, а не от прошлого удачного; изменённые не теряются
function tests.test_partial_sync_does_not_refetch_saved_in_failed_run()
  local path = tmp()
  local ws = workspace()
  table.remove(ws.search, 4) -- без p2: порядок p1, r1, r2
  run_sync(ws, path, T0 + 60) -- удачный; документы правлены в T0 — внутри окна от T0 + 60
  ws.fail = { r2 = "timeout" }
  local stats = run_sync(ws, path, T0 + 7200) -- окно: перечитаны p1, r1, на r2 сбой
  t.eq(stats.err, "timeout")
  t.eq(stats.updated, 2)
  ws.fail = nil
  local stats3, c = run_sync(ws, path, T0 + 7300)
  t.eq(stats3.err, nil)
  t.eq(#c.blocks, 1, "p1, r1 прочитаны в сбойном прогоне: " .. table.concat(c.blocks, ","))
  t.eq(c.blocks[1], "r2")
  local _, c4 = run_sync(ws, path, T0 + 9000)
  t.eq(#c4.blocks, 0, "после удачного — окно от T0 + 7300")
end

-- метки "read:<id>" живут только до удачного прогона: сбойный их ставит, удачный снимает все
function tests.test_successful_sync_clears_read_marks()
  local path = tmp()
  local ws = workspace()
  table.remove(ws.search, 4)
  ws.fail = { r2 = "timeout" }
  run_sync(ws, path, T0 + 3600)
  local function marks()
    local K = knowledge.open(path)
    local m = K:meta_prefix("read:")
    K:close()
    local ids = {}
    for id in pairs(m) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ","), m
  end
  local ids, m = marks()
  t.eq(ids, "p1,r1", "сбойный прогон метит прочитанные")
  t.eq(m.p1, tostring(T0 + 3600))
  ws.fail = nil
  local stats = run_sync(ws, path, T0 + 3700)
  t.eq(stats.err, nil)
  t.eq((marks()), "", "удачный прогон снял все метки")
end

function tests.test_partial_sync_keeps_changes_after_failed_run()
  local path = tmp()
  local ws = workspace()
  table.remove(ws.search, 4)
  run_sync(ws, path, T0 + 60)
  -- p1 правлена в T0 + 7150: прочитана сбойным прогоном в T0 + 7200, но могла меняться и после
  -- с тем же last_edited_time (окно 120 с от чтения)
  ws.search[1] = page("p1", "Заметки", T0 + 7150)
  ws.fail = { r2 = "timeout" }
  run_sync(ws, path, T0 + 7200)
  -- r1 правлена после сбойного прогона
  ws.rows.ds1[1] = row("r1", "Дюна", T0 + 7250, "ds1")
  ws.fail = nil
  local _, c = run_sync(ws, path, T0 + 7300)
  local got = {}
  for _, id in ipairs(c.blocks) do got[id] = true end
  t.ok(got.p1, "p1 в окне от своего чтения")
  t.ok(got.r1, "r1 изменена")
  t.ok(got.r2, "r2 не была сохранена")
end

-- started_prev — начало прогона, не конец: правка во время прогона попадает в окно следующего
function tests.test_started_prev_is_run_start()
  local path = tmp()
  local now = T0 + 3600
  local stats = run_sync(workspace(), path, function() now = now + 100 return now end)
  t.eq(stats.err, nil)
  local db = read(path)
  t.eq(db.started_prev, tostring(T0 + 3700), "первое чтение часов")
  t.ok(tonumber(db.last_ok) > T0 + 3700, "last_ok — конец прогона")
end

-- базы в seen: delete_missing не удаляет их строку sources
function tests.test_sources_survive_sync()
  local path = tmp()
  run_sync(workspace(), path, T0 + 3600)
  run_sync(workspace(), path, T0 + 9000)
  local K = knowledge.open(path)
  local stmt = K.conn:prepare("SELECT id, title FROM sources")
  local r = stmt:step()
  local id, title = r and r[1], r and r[2]
  stmt:close()
  K:close()
  t.eq(id, "ds1")
  t.eq(title, "Фильмы")
end

function tests.test_search_error_keeps_store_and_meta()
  local path = tmp()
  run_sync(workspace(), path, T0 + 3600)
  local ws = workspace()
  ws.search_err = "unauthorized"
  local stats = run_sync(ws, path, T0 + 9000)
  t.eq(stats.err, "unauthorized")
  local db = read(path)
  t.ok(db.map.p1 and db.map.r1, "ничего не удалено")
  t.eq(db.last_ok, tostring(T0 + 3600))
end

-- сбой или неполное чтение строк базы: строки за обрезом не удаляются, last_ok не ставится
function tests.test_query_error_stops_sync_without_deletions()
  for _, why in ipairs({ "incomplete", "http 500" }) do
    local path = tmp()
    run_sync(workspace(), path, T0 + 3600)
    local ws = workspace()
    ws.rows.ds1 = {} -- в базе будто бы пусто, но чтение оборвалось
    ws.query_err = { ds1 = why }
    local logs = {}
    local stats = run_sync(ws, path, T0 + 9000, logs)
    t.eq(stats.err, why)
    t.eq(stats.deleted, 0)
    local db = read(path)
    t.ok(db.map.r1 and db.map.r2, "строки базы целы: " .. why)
    t.eq(db.last_ok, tostring(T0 + 3600), "last_ok прежний: " .. why)
    t.eq(logs[#logs], "riddle: sync stopped: " .. why .. " (updated=0)")
  end
end

function tests.test_empty_workspace_sync_ok()
  local path = tmp()
  local stats = run_sync({ search = {}, rows = {}, bodies = {} }, path, T0)
  t.eq(stats.err, nil)
  t.eq(stats.seen, 0)
  t.eq(stats.chars, 0)
  t.eq(read(path).last_ok, tostring(T0))
end

function tests.test_store_open_failure_is_error_not_crash()
  local stats = run_sync(workspace(), "/nonexistent-dir/x/knowledge.sqlite3", T0)
  t.ok(stats.err, "ошибка в stats")
end

-- ошибка базы посреди прохода (запись в базу только для чтения: ljsqlite3[readonly]) — «store: …»; ошибка кода в
-- проходе — «lua: …»: страница состояния различает «не записалось в память Kindle» и «подробности в журнале»
function tests.test_store_error_in_pass_is_store()
  local path = tmp()
  t.eq(run_sync(workspace(), path, T0).err, nil)
  os.execute("chmod 444 '" .. path .. "'")
  local stats = run_sync(workspace(), path, T0 + 3600)
  os.execute("chmod 644 '" .. path .. "'")
  t.ok(tostring(stats.err):find("^store: "), tostring(stats.err))
  t.ok(tostring(stats.err):find("ljsqlite3[readonly]", 1, true), tostring(stats.err))
end

function tests.test_code_error_in_pass_is_not_store()
  local ws = workspace()
  ws.rows.ds1 = 5 -- клиент вернул строки базы не таблицей: проход падает Lua-ошибкой (ipairs)
  local stats = run_sync(ws, tmp(), T0)
  t.ok(tostring(stats.err):find("^lua: .*ipairs"), tostring(stats.err))
end

function tests.test_logs_have_no_titles_or_texts()
  local logs = {}
  run_sync(workspace(), tmp(), T0 + 3600, logs)
  t.eq(#logs, 1)
  t.ok(logs[1]:match("^riddle: sync done seen=%d+ updated=%d+ deleted=%d+ chars=%d+ in %d+ ms" ..
    " collections=%d+ tasks=%d+ open=%d+$"), logs[1])
  for _, w in ipairs({ "Дюна", "Фильмы", "песок", "Заметки" }) do
    t.ok(not logs[1]:find(w, 1, true), "в логе нет «" .. w .. "»")
  end
end

function tests.test_should_start_after_hour()
  t.eq(sync.STALE_S, 3600)
  t.eq(sync.should_start(T0, nil, false), true, "ни разу не было")
  t.eq(sync.should_start(T0 + 3599, T0, false), false)
  t.eq(sync.should_start(T0 + 3600, T0, false), true)
  t.eq(sync.should_start(T0 + 3600, tostring(T0), false), true, "метка строкой из meta")
  t.eq(sync.should_start(T0 + 9999, T0, true), false, "занято")
end

-- часы сброшены назад: last_ok из будущего дальше допуска (sync.CLOCK_SKEW_S) не «свежий до сна», а устаревший;
-- в пределах допуска — «сейчас»: Kindle подводит часы по сети после пробуждения, откат на секунды — не повод для sync
function tests.test_should_start_when_last_ok_in_future()
  t.eq(sync.CLOCK_SKEW_S, 60)
  t.eq(sync.should_start(T0, T0 + 1, false), false, "метка на секунду вперёд — свежая")
  t.eq(sync.should_start(T0, T0 + 60, false), false, "на границе допуска — свежая")
  t.eq(sync.should_start(T0, T0 + 61, false), true, "за допуском — устаревшая")
  t.eq(sync.should_start(T0, T0 + 86400 * 400, false), true, "часы сброшены на год назад")
  t.eq(sync.should_start(T0, tostring(T0 + 5), false), false, "метка строкой из meta")
  t.eq(sync.should_start(T0, tostring(T0 + 61), false), true, "метка строкой из meta за допуском")
  t.eq(sync.should_start(T0, T0, false), false, "метка равна now — свежая")
  t.eq(sync.should_start(T0, T0 + 3600, true), false, "занято — не запускать и при метке из будущего")
end

function tests.test_rss_line_numbers_and_unknown()
  t.eq(sync.rss_line("start", 51234, nil), "riddle: sync rss start parent_kb=51234 child_kb=-")
  t.eq(sync.rss_line("done", 60001, 20480), "riddle: sync rss done parent_kb=60001 child_kb=20480")
  t.eq(sync.rss_line("done", nil, nil), "riddle: sync rss done parent_kb=- child_kb=-", "на Mac /proc нет")
end

function tests.test_iso_to_epoch()
  t.eq(sync.iso_epoch("2026-10-25T10:00:00.000Z"), T0)
  t.eq(sync.iso_epoch("2026-10-25T13:00:00.000+03:00"), T0)
  t.eq(sync.iso_epoch("2024-02-29T00:00:00Z"), 1709164800)
  t.eq(sync.iso_epoch("мусор"), nil)
end

-- задачи: база со свойством status (группа Complete — закрыта), имя базы — ключ конфига или слово пользователя
local function status_ds(id, title)
  local opts = { { id = "o1", name = "В работе" }, { id = "o2", name = "Готово" } }
  return { object = "data_source", id = id, title = rt(title), last_edited_time = iso(T0),
    parent = { type = "database_id", database_id = "db-" .. id },
    database_parent = { type = "page_id", page_id = "p1" },
    properties = { ["Этап"] = { id = "s", name = "Этап", type = "status", status = { options = opts, groups = {
      { id = "g1", name = "To-do", option_ids = {} },
      { id = "g2", name = "In progress", option_ids = { "o1" } },
      { id = "g3", name = "Complete", option_ids = { "o2" } },
    } } } } }
end

local function task_row(id, title, state)
  local r = row(id, title, T0, "ds2")
  r.properties["Этап"] = { type = "status", status = { id = "x", name = state } }
  return r
end

local function tasks_workspace()
  local ws = workspace()
  ws.search[#ws.search + 1] = status_ds("ds2", "Мои задачи")
  ws.rows.ds2 = { task_row("t1", "Купить хлеб", "В работе"), task_row("t2", "Позвонить", "Готово"),
    task_row("t3", "Починить кран", "В работе") }
  return ws
end

local function snapshot_of(path)
  local K = knowledge.open(path)
  local cols, by = K:collections(), {}
  for _, c in ipairs(cols) do by[c.id] = c end
  local out = { cols = cols, by = by, tasks = {} }
  for _, c in ipairs(cols) do
    for _, r in ipairs(K:tasks_of(c.id)) do out.tasks[#out.tasks + 1] = r end
  end
  K:close()
  return out
end

function tests.test_sync_writes_collections_and_chosen_tasks()
  local path = tmp()
  local logs = {}
  local stats, c = run_sync(tasks_workspace(), path, T0 + 3600, logs, "мои ЗАДАЧИ")
  t.eq(stats.err, nil)
  t.eq(stats.collections, 2)
  t.eq(stats.tasks, 3)
  t.eq(stats.open, 2)
  t.ok(logs[1]:find(" collections=2 tasks=3 open=2$"), logs[1])
  local s = snapshot_of(path)
  t.eq(#s.cols, 2)
  t.eq(s.by.ds2.title, "Мои задачи")
  t.eq(s.by.ds2.items, 3)
  t.eq(s.by.ds2.depth, 1, "предок p1 — из поиска")
  t.eq(s.by.ds1.depth, 0)
  t.eq(#s.tasks, 3)
  for _, r in ipairs(s.tasks) do
    t.eq(r.collection_id, "ds2")
    t.eq(r.open, r.id ~= "t2", "открыта: " .. r.id)
  end
  t.eq(#c.gets, 0, "глубина без лишних вызовов API")
end

-- без ключа конфига и слова кандидатов нет (классификация — срез 6): только коллекции
function tests.test_sync_without_choice_writes_collections_only()
  local path = tmp()
  local logs = {}
  local stats = run_sync(tasks_workspace(), path, T0 + 3600, logs)
  t.eq(stats.err, nil)
  t.ok(logs[1]:find(" collections=2 tasks=0 open=0$"), logs[1])
  t.eq(#snapshot_of(path).tasks, 0)
end

function tests.test_sync_word_in_core_beats_config()
  local path = tmp()
  local K = knowledge.open(path)
  K:set_core("tasks_source", "Фильмы")
  K:close()
  local stats = run_sync(tasks_workspace(), path, T0 + 3600, nil, "Мои задачи")
  t.eq(stats.err, nil)
  local s = snapshot_of(path)
  t.eq(#s.tasks, 2, "строки базы из слова пользователя")
  for _, r in ipairs(s.tasks) do t.eq(r.collection_id, "ds1") end
  t.eq(stats.open, 2, "у базы без status все строки незакрыты")
end

-- сбой записи снимка — ошибка прогона: last_ok прежний, снимок прежний
function tests.test_snapshot_failure_keeps_last_ok()
  local path = tmp()
  run_sync(tasks_workspace(), path, T0 + 3600, nil, "Мои задачи")
  local K = knowledge.open(path)
  local mt = getmetatable(K)
  K:close()
  local real = mt.put_snapshot
  -- как бросает lua-ljsqlite3 на SQLITE_FULL (err: «ljsqlite3[<код строчными>] <sqlite3_errmsg>»)
  mt.put_snapshot = function() error("ljsqlite3[full] database or disk is full") end
  local logs = {}
  local stats = run_sync(tasks_workspace(), path, T0 + 9000, logs, "Мои задачи")
  mt.put_snapshot = real
  t.ok(tostring(stats.err):match("^store: "), tostring(stats.err))
  t.eq(read(path).last_ok, tostring(T0 + 3600))
  t.eq(#snapshot_of(path).tasks, 3, "прежний снимок цел")
  t.ok(logs[1]:match("^riddle: sync stopped: store: "), logs[1])
end

-- предок базы есть только через client:get (не в поиске) — глубина считается через GET;
-- архивная задача (строка в корзине) в снимке есть, но open= её не считает
function tests.test_sync_fetches_ancestor_and_open_skips_archived()
  local ws = tasks_workspace()
  local ds2 = ws.search[#ws.search]
  ds2.database_parent = { type = "page_id", page_id = "hidden" }
  ws.objects = { hidden = page("hidden", "Скрытая", T0, { type = "page_id", page_id = "p1" }) }
  local gone = task_row("t4", "Старое", "В работе")
  gone.in_trash = true
  ws.rows.ds2[#ws.rows.ds2 + 1] = gone
  local path = tmp()
  local logs = {}
  local stats, c = run_sync(ws, path, T0 + 3600, logs, "Мои задачи")
  t.eq(stats.err, nil)
  t.eq(table.concat(c.gets, ","), "pages/hidden", "один GET на предка вне поиска")
  local s = snapshot_of(path)
  t.eq(s.by.ds2.depth, 2, "hidden → p1 → корень")
  t.eq(#s.tasks, 4, "архивная задача в снимке")
  t.ok(logs[1]:find(" collections=2 tasks=4 open=2$"), logs[1])
end

function tests.test_task_titles_not_in_log()
  local logs = {}
  run_sync(tasks_workspace(), tmp(), T0 + 3600, logs, "Мои задачи")
  for _, w in ipairs({ "Мои задачи", "Купить хлеб", "Этап", "Готово" }) do
    t.ok(not logs[1]:find(w, 1, true), "в логе нет «" .. w .. "»")
  end
end

-- срез 6: классификация баз моделью при изменении схемы
local json = require("dkjson")
local worker = require("riddle.worker")
local tasks_core = require("riddle.tasks")

local function sel(name) return { type = "select", select = { id = "x", name = name } } end

-- база проектов: select «Состояние» с вариантом архива; не кандидат
local function projects_ds()
  return { object = "data_source", id = "ds3", title = rt("Проекты"), last_edited_time = iso(T0),
    parent = { type = "database_id", database_id = "db-ds3" },
    database_parent = { type = "workspace", workspace = true },
    properties = { ["Состояние"] = { id = "q", name = "Состояние", type = "select", select = { options = {
      { id = "a", name = "Активен" }, { id = "b", name = "Архив" } } } } } }
end

local function cls_workspace()
  local ws = tasks_workspace()
  ws.search[#ws.search + 1] = projects_ds()
  local p1 = row("pr1", "Переезд", T0, "ds3")
  p1.properties["Состояние"] = sel("Архив")
  ws.rows.ds3 = { p1 }
  ws.search[#ws.search - 1].properties["Проект"] = { id = "r", name = "Проект", type = "relation", relation = {} }
  ws.rows.ds2[1].properties["Проект"] = { type = "relation", relation = { { id = "pr1" } } }
  return ws
end

-- поддельная модель: метки c<N> — по названиям из запроса; ds2 — задачи (pick), ds3 — архив по варианту
local function fake_model(opts)
  opts = opts or {}
  local f = { calls = 0, sent = {} }
  setmetatable(f, { __call = function(_, messages)
    f.calls = f.calls + 1
    f.sent[#f.sent + 1] = messages[1].content .. "\n" .. messages[2].content
    if opts.probe then opts.probe() end
    if opts.raise then error(opts.raise) end
    if opts.fail then return nil, opts.fail, { "riddle: llm done fail (http 503)" } end
    local label = {}
    for _, c in ipairs(json.decode(messages[2].content)) do label[c.title] = c.c end
    return json.encode({ collections = {
      { c = label["Мои задачи"], tasks = true, project = "Проект" },
      { c = label["Проекты"], tasks = false, archive_select = { prop = "Состояние", options = { "Архив" } } },
    }, pick = label["Мои задачи"] }), nil, { "riddle: llm host -> 200 in 5 ms", "riddle: llm done ok in 5 ms" }
  end })
  return f
end

function tests.test_classify_called_once_per_schema()
  local path = tmp()
  local model = fake_model()
  local logs = {}
  local stats = run_sync(cls_workspace(), path, T0 + 3600, logs, nil, model)
  t.eq(stats.err, nil)
  t.eq(model.calls, 1)
  t.eq(stats.classify, "ok")
  t.eq(stats.candidates, 1)
  t.eq(stats.pick, true)
  t.eq(stats.tasks, 3, "задачи кандидата без tasks_source")
  local sent = model.sent[1]
  for _, w in ipairs({ "Купить хлеб", "Позвонить", "Переезд", "Дюна", "тело заметок", "песок" }) do
    t.ok(not sent:find(w, 1, true), "в запросе к модели нет строки «" .. w .. "»")
  end
  t.ok(sent:find("Состояние", 1, true) and sent:find("Архив", 1, true), "схема в запросе")
  t.ok(not sent:find("Фильмы", 1, true), "база без status/select/checkbox не классифицируется")
  local s = snapshot_of(path)
  local by = {}
  for _, r in ipairs(s.tasks) do by[r.id] = r end
  t.eq(by.t1.archived, true, "проект в архиве по правилу базы проектов")
  -- та же схема, новые строки и новое название — без вызова
  local ws = cls_workspace()
  ws.rows.ds2[#ws.rows.ds2 + 1] = task_row("t9", "Новая", "В работе")
  ws.search[#ws.search - 1].title = rt("Дела дома")
  stats = run_sync(ws, path, T0 + 9000, nil, nil, model)
  t.eq(model.calls, 1, "схема та же — модель не спрашиваем")
  t.eq(stats.classify, "skip")
  t.eq(stats.candidates, 1)
  t.eq(stats.pick, true)
  t.eq(stats.tasks, 4, "правила из meta")
  -- схема изменилась (новый вариант) — второй вызов
  ws = cls_workspace()
  table.insert(ws.search[#ws.search].properties["Состояние"].select.options, { id = "c", name = "Пауза" })
  stats = run_sync(ws, path, T0 + 15000, nil, nil, model)
  t.eq(model.calls, 2)
  t.eq(stats.classify, "ok")
end

-- Review Focus 5: сбой классификации (вытеснение ответом, ошибка модели) — старые правила остаются,
-- хэш не пишется, классификация повторяется в следующую синхронизацию, задачи не пропадают
function tests.test_classify_failure_keeps_rules_and_retries()
  local path = tmp()
  local H = sync.CLS_RETRY_S
  run_sync(cls_workspace(), path, T0 + 3600, nil, nil, fake_model())
  local changed = function()
    local ws = cls_workspace()
    table.insert(ws.search[#ws.search].properties["Состояние"].select.options, { id = "c", name = "Пауза" })
    return ws
  end
  -- модель не ответила: прогон удачен, правила прежние
  local down = fake_model({ fail = "cancelled" })
  local logs = {}
  local stats = run_sync(changed(), path, T0 + 9000, logs, nil, down)
  t.eq(stats.err, nil)
  t.eq(down.calls, 1)
  t.eq(stats.classify, "fail")
  t.eq(stats.tasks, 3, "задачи по старым правилам")
  t.eq(stats.candidates, 1)
  t.eq(stats.pick, true)
  t.eq(snapshot_of(path).by.ds2.model_pick, true)
  -- ошибка цепочки — тоже сбой классификации, прогон не обрывается
  local broken = fake_model({ raise = "boom" })
  stats = run_sync(changed(), path, T0 + 9000 + H, nil, nil, broken)
  t.eq(broken.calls, 1)
  t.eq(stats.err, nil)
  t.eq(stats.classify, "fail")
  t.eq(stats.tasks, 3)
  -- вытеснение ответом убивает дочерний посреди вызова модели: что лежит в хранилище в этот момент, то и
  -- останется — прежние хэш, правила, снимок и last_ok
  local before = read(path).last_ok
  local hash = (function() local K = knowledge.open(path); local h = K:meta("cls_hash"); K:close(); return h end)()
  local at_kill
  local probe = fake_model({ probe = function()
    local K = knowledge.open(path)
    at_kill = { hash = K:meta("cls_hash"), rules = K:meta("cls:ds2"), pick = K:meta("cls_pick"),
      last_ok = K:meta("last_ok"), tasks = #K:tasks_of("ds2") }
    K:close()
  end, fail = "cancelled" })
  run_sync(changed(), path, T0 + 9000 + 2 * H, nil, nil, probe)
  t.eq(probe.calls, 1)
  t.eq(at_kill.hash, hash, "хэш прежний")
  t.ok(at_kill.rules, "правила прежние")
  t.eq(at_kill.pick, "ds2")
  t.eq(at_kill.last_ok, before, "last_ok не тронут")
  t.eq(at_kill.tasks, 3, "снимок прежний")
  -- следующая синхронизация после паузы — снова спрашивает и успешно
  local up = fake_model()
  stats = run_sync(changed(), path, T0 + 9000 + 3 * H, nil, nil, up)
  t.eq(up.calls, 1, "повтор после сбоя")
  t.eq(stats.classify, "ok")
  stats = run_sync(changed(), path, T0 + 9000 + 3 * H + 60, nil, nil, up)
  t.eq(up.calls, 1, "после удачи — снова skip")
  t.eq(stats.classify, "skip")
  -- без функции классификации — тоже «сбой», хэш не пишется
  local p2 = tmp()
  stats = run_sync(cls_workspace(), p2, T0 + 3600)
  t.eq(stats.classify, "fail")
  t.eq(stats.tasks, 0)
  local again = fake_model()
  run_sync(cls_workspace(), p2, T0 + 3600 + H, nil, nil, again)
  t.eq(again.calls, 1)
end

-- ограничитель повтора: тот же хэш после сбоя — не чаще раза в CLS_RETRY_S; новая схема — сразу;
-- удача стирает метку сбоя
function tests.test_classify_retry_after_failure_is_throttled()
  t.eq(sync.CLS_RETRY_S, 6 * 3600)
  local path = tmp()
  local down = fake_model({ fail = "http 503" })
  local stats = run_sync(cls_workspace(), path, T0, nil, nil, down)
  t.eq(stats.classify, "fail")
  local logs = {}
  stats = run_sync(cls_workspace(), path, T0 + sync.CLS_RETRY_S - 1, logs, nil, down)
  t.eq(down.calls, 1, "в пределах 6 ч модель не зовём")
  t.eq(stats.classify, "skip")
  t.eq(stats.classify_deferred, true)
  local line
  for _, m in ipairs(logs) do if m:match("^riddle: classify ") then line = m end end
  t.ok(line and line:match("^riddle: classify skip candidates=0 pick=no in 0 ms deferred$"), tostring(line))
  stats = run_sync(cls_workspace(), path, T0 + sync.CLS_RETRY_S, nil, nil, down)
  t.eq(down.calls, 2, "через 6 ч — снова")
  t.eq(stats.classify, "fail")
  -- схема изменилась — сразу, без ожидания
  local ws = cls_workspace()
  table.insert(ws.search[#ws.search].properties["Состояние"].select.options, { id = "c", name = "Пауза" })
  local up = fake_model()
  stats = run_sync(ws, path, T0 + sync.CLS_RETRY_S + 60, nil, nil, up)
  t.eq(up.calls, 1, "новая схема — сразу")
  t.eq(stats.classify, "ok")
  local K = knowledge.open(path)
  t.eq(K:meta("cls_fail"), nil, "удача стирает метку сбоя")
  K:close()
  -- вернулась прежняя схема (её сбой был недавно) — метки нет, зовём сразу
  stats = run_sync(cls_workspace(), path, T0 + sync.CLS_RETRY_S + 120, nil, nil, up)
  t.eq(up.calls, 2)
end

-- метка сбоя из будущего (часы Kindle ушли назад) — повтор не откладывается
function tests.test_classify_retry_not_deferred_when_clock_went_back()
  local path = tmp()
  local down = fake_model({ fail = "http 503" })
  t.eq(run_sync(cls_workspace(), path, T0, nil, nil, down).classify, "fail")
  local up = fake_model()
  local stats = run_sync(cls_workspace(), path, T0 - 60, nil, nil, up)
  t.eq(up.calls, 1, "метка из будущего — зовём модель")
  t.eq(stats.classify, "ok")
  t.eq(stats.classify_deferred, nil)
end

-- граница: метка сбоя с тем же временем, что начало прогона (since == 0), — не из будущего, повтор отложен
function tests.test_classify_retry_deferred_at_same_second()
  local path = tmp()
  local down = fake_model({ fail = "http 503" })
  t.eq(run_sync(cls_workspace(), path, T0, nil, nil, down).classify, "fail")
  local stats = run_sync(cls_workspace(), path, T0, nil, nil, down)
  t.eq(down.calls, 1, "та же секунда — модель не зовём")
  t.eq(stats.classify, "skip")
  t.eq(stats.classify_deferred, true)
end

-- М1: правила базы, которую модель больше не назвала, и прежний pick удаляются — не остаются кандидатом
function tests.test_stale_rules_and_pick_removed()
  local path = tmp()
  run_sync(cls_workspace(), path, T0, nil, nil, fake_model())
  t.eq(snapshot_of(path).by.ds2.task_candidate, true)
  local ws = cls_workspace()
  table.insert(ws.search[#ws.search].properties["Состояние"].select.options, { id = "c", name = "Пауза" })
  local only_proj = function(messages)
    local label = {}
    for _, c in ipairs(json.decode(messages[2].content)) do label[c.title] = c.c end
    return json.encode({ collections = { { c = label["Проекты"], tasks = false } } })
  end
  local stats = run_sync(ws, path, T0 + 60, nil, nil, only_proj)
  t.eq(stats.classify, "ok")
  stats = run_sync(ws, path, T0 + 120, nil, nil, only_proj)
  t.eq(stats.classify, "skip", "правила — из meta")
  t.eq(stats.candidates, 0)
  t.eq(stats.pick, false)
  local s = snapshot_of(path)
  t.eq(s.by.ds2.task_candidate, false, "база больше не кандидат")
  t.eq(s.by.ds2.model_pick, false, "прежний pick снят")
  t.eq(#s.tasks, 0)
  local K = knowledge.open(path)
  t.eq(K:meta("cls:ds2"), nil)
  t.eq(K:meta("cls_pick"), nil)
  K:close()
end

-- М2: правила, pick и хэш пишутся одной транзакцией: сбой посреди записи — всё прежнее, без смеси
function tests.test_rules_write_is_atomic()
  local path = tmp()
  run_sync(cls_workspace(), path, T0, nil, nil, fake_model())
  local K = knowledge.open(path)
  local old = { ds2 = K:meta("cls:ds2"), ds3 = K:meta("cls:ds3"), pick = K:meta("cls_pick"), hash = K:meta("cls_hash") }
  local mt = getmetatable(K)
  K:close()
  local ws = cls_workspace()
  table.insert(ws.search[#ws.search].properties["Состояние"].select.options, { id = "c", name = "Пауза" })
  local swap = function(messages)
    local label = {}
    for _, c in ipairs(json.decode(messages[2].content)) do label[c.title] = c.c end
    return json.encode({ collections = { { c = label["Мои задачи"], tasks = false },
      { c = label["Проекты"], tasks = true } }, pick = label["Проекты"] })
  end
  local real = mt.set_meta
  mt.set_meta = function(self, k, v)
    if k == "cls_hash" then error("ljsqlite3[full] database or disk is full") end -- как lua-ljsqlite3 на SQLITE_FULL
    return real(self, k, v)
  end
  local stats = run_sync(ws, path, T0 + 60, nil, nil, swap)
  mt.set_meta = real
  t.ok(tostring(stats.err):match("^store: "), tostring(stats.err))
  K = knowledge.open(path)
  t.eq(K:meta("cls:ds2"), old.ds2, "правила ds2 прежние")
  t.eq(K:meta("cls:ds3"), old.ds3, "правила ds3 прежние")
  t.eq(K:meta("cls_pick"), old.pick)
  t.eq(K:meta("cls_hash"), old.hash)
  K:close()
end

function tests.test_model_pick_without_config_selects_collection()
  local path = tmp()
  run_sync(cls_workspace(), path, T0 + 3600, nil, nil, fake_model())
  local s = snapshot_of(path)
  t.eq(s.by.ds2.task_candidate, true)
  t.eq(s.by.ds2.model_pick, true)
  t.eq(s.by.ds3.task_candidate, false)
  t.eq(s.by.ds3.model_pick, false)
  local c, why = tasks_core.pick_source(s.cols, nil, nil)
  t.eq(c.id, "ds2")
  t.eq(why, "model")
end

function tests.test_classify_log_line_numbers_only()
  local logs = {}
  run_sync(cls_workspace(), tmp(), T0 + 3600, logs, nil, fake_model())
  local line
  for _, m in ipairs(logs) do if m:match("^riddle: classify ") then line = m end end
  t.ok(line, "строка classify")
  t.ok(line:match("^riddle: classify ok candidates=1 pick=yes in %d+ ms$"), line)
  for _, m in ipairs(logs) do
    for _, w in ipairs({ "Мои задачи", "Проекты", "Состояние", "Архив", "Купить" }) do
      t.ok(not m:find(w, 1, true), "в логе нет «" .. w .. "»")
    end
  end
end

-- логи цепочки едут в payload дочернего: не больше 20 строк, строка обрезана — payload под потолком worker
function tests.test_stats_payload_under_worker_cap()
  local long = {}
  for i = 1, 20 do long[i] = string.rep("x", 200) end
  local model = function() return nil, "fail", long end
  local stats = run_sync(cls_workspace(), tmp(), T0 + 3600, nil, nil, model)
  t.eq(#stats.llm_logs, 20)
  t.ok(#json.encode({ ok = stats }) < worker.MAX_PAYLOAD)
  local huge = {}
  for i = 1, 100 do huge[i] = string.rep("y", 5000) end
  stats = run_sync(cls_workspace(), tmp(), T0 + 3600, nil, nil, function() return nil, "fail", huge end)
  t.eq(#stats.llm_logs, 20, "не больше 20 строк")
  t.ok(#json.encode({ ok = stats }) < worker.MAX_PAYLOAD, "под потолком: " .. #json.encode({ ok = stats }))
end

-- итог последней синхронизации: «<время> ok» или «<время> <ошибка>», одна строка; читает status
function tests.test_last_line_ok_and_error()
  t.eq(sync.last_line(100, nil), "100 ok\n")
  t.eq(sync.last_line(100, "timeout"), "100 timeout\n")
end

function tests.test_last_line_error_is_one_trimmed_line()
  t.eq(sync.last_line(100, "  bad\ngateway\r\n "), "100 bad gateway\n")
end

function tests.test_last_line_empty_error_is_still_an_error()
  t.eq(sync.last_line(100, ""), "100 error\n")
  t.eq(sync.last_line(100, " \n"), "100 error\n")
end

function tests.test_parse_last_reads_what_last_line_writes()
  local r = sync.parse_last(sync.last_line(1763500000, nil))
  t.eq(r.at, 1763500000)
  t.eq(r.err, nil)
  r = sync.parse_last(sync.last_line(1763500000, "parent gone"))
  t.eq(r.at, 1763500000)
  t.eq(r.err, "parent gone")
end

function tests.test_parse_last_rejects_bad_text()
  for _, bad in ipairs{ "", "ok", "abc ok", "100", "100 ", "100 ok\n200 ok\n", "-5 ok" } do
    t.eq(sync.parse_last(bad), nil, bad)
  end
  t.eq(sync.parse_last(nil), nil)
  t.eq(sync.parse_last(42), nil)
end

function tests.test_last_path_is_in_riddle_dir()
  t.eq(sync.LAST_PATH, "/mnt/us/riddle/sync_last")
end

local ok, err = pcall(t.run, tests)
cleanup()
if not ok then error(err, 0) end
