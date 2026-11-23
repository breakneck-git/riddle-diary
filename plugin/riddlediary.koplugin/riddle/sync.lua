-- Синхронизация Notion → knowledge.sqlite3 (выполняется в дочернем процессе, своё соединение с базой).
-- Перечитывается документ, у которого last_edited_time не совпадает с сохранённым или попадает в окно
-- RECENT_S от начала прошлого удачного прогона: точность last_edited_time документацией не обещана.
-- Каждый документ — своя транзакция: сбой посреди прогона оставляет уже сохранённое, last_ok не трогает.
-- Прочитанный документ метится "read:<id>" = начало прогона: после сбоя окно у него — от этой метки,
-- а не от прошлого удачного прогона (сохранённое не перечитывается заново); удачный прогон метки снимает.
-- Тело 404 (страница недоступна) или неполное (incomplete: оборвана пагинация блоков) — пропуск со
-- счётчиком skipped, прогон идёт дальше и может быть удачным: пропущенная не сохранена, поэтому её
-- edited не совпадёт и она перечитается в следующий раз; если edited совпадал (читалась из-за окна),
-- сохранённый edited снимается — иначе с уходом окна вперёд она бы не перечиталась.
-- Неполное тело может быть неполным всегда (> MAX_PAGES·100 блоков), а чтение такого — MAX_PAGES запросов:
-- метка "fail:<id>" = "<n> <MAX_PAGES> <edited>" считает неудачи подряд при том же edited и том же
-- notion.MAX_PAGES; после MAX_FAILS страница не читается (пропуск со счётчиком), пока не сменится edited или
-- MAX_PAGES (подняли потолок — тело могло стать полным). Удачное чтение метку снимает.
-- Тело с пропуском (дети вложенного блока 404: synced_block с нерасшаренным источником) сохраняется, но
-- edited страницы не изменится, когда источник расшарят: метка "gap:<id>" = начало прогона, и страница
-- перечитывается не чаще раза в GAP_RETRY_S, пока пропуск есть; тело без пропуска метку снимает.
-- Удачный прогон перед last_ok пишет снимок общего формата задач (коллекции и задачи, notion_tasks.lua);
-- сбой снимка — ошибка прогона, last_ok и прежний снимок не трогаются.
-- Правила толкования баз даёт классификация моделью (classify.lua, d.classify) — только когда хэш схем баз
-- (meta "cls_hash") изменился; правила — "cls:<id>", выбор модели — "cls_pick". Сбой классификации (нет
-- ответа, мусор, ошибка, нет d.classify) — прежние правила, хэш не пишется; метка "cls_fail" = "<хэш> <начало
-- прогона>": та же схема повторяется не чаще раза в CLS_RETRY_S, новая — сразу; удача метку стирает.
-- Правила, pick, хэш и снятие метки пишутся одной транзакцией.
-- Вытеснение ответом убивает дочерний посреди вызова — до записи правил, снимка и last_ok: остаётся прежнее.
-- В лог — только числа и причина сбоя (без названий и текстов).
local json = require("dkjson")
local classify = require("riddle.classify")
local knowledge = require("riddle.knowledge")
local nt = require("riddle.notion_text")
local notion = require("riddle.notion")
local notion_tasks = require("riddle.notion_tasks")
local str = require("riddle.str")
local tasks = require("riddle.tasks")

local sync = {}
sync.STALE_S = 3600
sync.CLOCK_SKEW_S = 60 -- last_ok из будущего не дальше этого — «сейчас»: Kindle подводит часы по сети после сна
sync.LAST_PATH = "/mnt/us/riddle/sync_last" -- итог последнего прогона для страницы состояния; пишет только main.lua
sync.RECENT_S = 120
sync.MAX_FAILS = 3 -- подряд неполных тел при том же edited: дальше страница не читается до правки
sync.GAP_RETRY_S = 6 * 3600 -- страница с пропуском (источник synced_block не расшарен) — не чаще раза в 6 ч
sync.CLS_RETRY_S = 6 * 3600 -- сбой классификации той же схемы — повтор не чаще раза в 6 ч
sync.MAX_LLM_LOGS = 20 -- строк лога цепочки в payload дочернего (потолок worker.MAX_PAYLOAD)
sync.MAX_LLM_LOG_CHARS = 300

-- дни от 1970-01-01 до даты (григорианский календарь)
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- ISO 8601 (2026-10-25T10:00:00.000Z или со смещением ±hh:mm) -> секунды UTC | nil
function sync.iso_epoch(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, sec, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
  if not y then return nil end
  local off = 0
  if rest ~= "Z" then
    local sign, oh, om = rest:match("^([+-])(%d%d):(%d%d)$")
    if not sign then return nil end
    off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec) - off
end

function sync.should_start(now, last_ok, busy)
  if busy then return false end
  local last = tonumber(last_ok)
  -- метка из будущего дальше допуска (часы сбросили назад) не «свежая»: now - last < 0 держал бы её свежей до сна
  return last == nil or last > now + sync.CLOCK_SKEW_S or now - last >= sync.STALE_S
end

-- строка журнала с RSS родителя и дочернего (КБ): when = start | done; неизвестное — «-» (на Mac /proc нет)
function sync.rss_line(when, parent_kb, child_kb)
  return string.format("riddle: sync rss %s parent_kb=%s child_kb=%s", when, tostring(parent_kb or "-"),
    tostring(child_kb or "-"))
end

local function trashed(obj)
  return obj.in_trash == true or obj.archived == true
end

-- документы прогона по порядку: страницы вне баз из поиска, затем строки каждой базы
local function collect(client, K)
  local objs, err = client:search_all()
  if not objs then return nil, err end
  local docs, sources, row_ids = {}, {}, {}
  local loose = {} -- страницы поиска; строки известных баз отсеиваются ниже
  for _, o in ipairs(objs) do
    if type(o) == "table" and type(o.id) == "string" and not trashed(o) then
      if o.object == "data_source" then
        sources[#sources + 1] = o
      elseif o.object == "page" then
        loose[#loose + 1] = o
      end
    end
  end
  local rows_by_source = {}
  for _, src in ipairs(sources) do
    local rows, qerr = client:query_all(src.id)
    if not rows then return nil, qerr end
    K:put_source(src.id, nt.title(src))
    rows_by_source[src.id] = rows
    for _, r in ipairs(rows) do
      if type(r) == "table" and type(r.id) == "string" then row_ids[r.id] = true end
    end
  end
  for _, p in ipairs(loose) do
    if not row_ids[p.id] then docs[#docs + 1] = { page = p } end
  end
  for _, src in ipairs(sources) do
    local title = nt.title(src)
    for _, r in ipairs(rows_by_source[src.id]) do
      if type(r) == "table" and type(r.id) == "string" and not trashed(r) then
        docs[#docs + 1] = { page = r, source_id = src.id, source_title = title }
      end
    end
  end
  local by_id = {}
  for _, o in ipairs(objs) do
    if type(o) == "table" and type(o.id) == "string" then by_id[o.id] = o end
  end
  return docs, sources, rows_by_source, by_id
end

-- правила прошлой удачной классификации из meta -> rules_by_id, pick_id
local function stored_rules(K)
  local rules_by_id = {}
  for id, v in pairs(K:meta_prefix("cls:")) do
    local ok, r = pcall(json.decode, v)
    if ok and type(r) == "table" then rules_by_id[id] = r end
  end
  return rules_by_id, K:meta("cls_pick")
end

-- правила баз: хэш схем совпал — из meta (skip); иначе d.classify -> удача — в meta (ok), сбой — прежние (fail);
-- баз со status/select/checkbox нет — правил нет, stats.classify = nil; сбой той же схемы был меньше
-- CLS_RETRY_S назад — прежние правила без вызова (skip, stats.classify_deferred).
-- stats.classify, stats.llm_logs (≤ MAX_LLM_LOGS строк, уже через mask цепочки), stats.classify_ms
local function rules_for(d, K, stats, sources, rows_by_source, by_id, fetch, start)
  local schemas = {}
  for _, src in ipairs(sources) do
    local sch = notion_tasks.schema(src)
    if sch then
      schemas[#schemas + 1] = { id = src.id, title = nt.title(src), items = #(rows_by_source[src.id] or {}),
        depth = notion_tasks.depth(src, by_id, fetch), props = sch.props }
    end
  end
  if #schemas == 0 then return {}, nil end -- классифицировать нечего: ни вызова, ни строки лога
  table.sort(schemas, function(a, b) return a.id < b.id end)
  local hash = notion_tasks.schema_hash(schemas)
  if K:meta("cls_hash") == hash then
    stats.classify = "skip"
    return stored_rules(K)
  end
  local fail_hash, fail_at = (K:meta("cls_fail") or ""):match("^(%S+) (%d+)$")
  local since = fail_at and start - tonumber(fail_at)
  -- метка из будущего (часы ушли назад) — не откладывать: иначе ожидание растёт на величину отскока
  if fail_hash == hash and since >= 0 and since < sync.CLS_RETRY_S then
    stats.classify, stats.classify_deferred = "skip", true
    return stored_rules(K)
  end
  local res
  if d.classify then
    local t0 = d.clock()
    -- ошибка цепочки — сбой классификации, не прогона: иначе синхронизация вставала бы навсегда
    local ok, text, _, logs = pcall(d.classify, classify.messages(schemas))
    if not ok then text, logs = nil, nil end
    stats.classify_ms = math.floor((d.clock() - t0) * 1000 + 0.5)
    for _, line in ipairs(type(logs) == "table" and logs or {}) do
      if #stats.llm_logs >= sync.MAX_LLM_LOGS then break end
      stats.llm_logs[#stats.llm_logs + 1] = tostring(line):sub(1, sync.MAX_LLM_LOG_CHARS)
    end
    res = classify.parse(text, schemas)
  end
  if not res then
    K:set_meta("cls_fail", hash .. " " .. start)
    stats.classify = "fail"
    return stored_rules(K)
  end
  K:tx(function()
    for id, r in pairs(res.rules_by_id) do K:set_meta("cls:" .. id, json.encode(r)) end
    for id in pairs(K:meta_prefix("cls:")) do
      if not res.rules_by_id[id] then K:delete_meta("cls:" .. id) end
    end
    if res.pick_id then K:set_meta("cls_pick", res.pick_id) else K:delete_meta("cls_pick") end
    K:delete_meta("cls_fail")
    K:set_meta("cls_hash", hash)
  end)
  stats.classify = "ok"
  return res.rules_by_id, res.pick_id
end

-- снимок общего формата задач (notion_tasks): все базы — коллекции, задачи — строки кандидатов
-- классификации и выбранной словом пользователя или конфигом базы. Предок вне поиска — GET (глубина).
local function put_tasks(d, K, stats, sources, rows_by_source, by_id, titles, start)
  local named = {}
  for _, src in ipairs(sources) do named[#named + 1] = { id = src.id, title = nt.title(src) } end
  local chosen, why = tasks.pick_source(named, K:core("tasks_source"), d.tasks_source)
  local client = d.client
  local fetch = client.get and function(kind, id) return client:get(kind, id) end
  local rules_by_id, pick_id = rules_for(d, K, stats, sources, rows_by_source, by_id, fetch, start)
  local present = {}
  for _, src in ipairs(sources) do present[src.id] = true end
  for id, r in pairs(rules_by_id) do
    if present[id] and r.tasks == true then stats.candidates = stats.candidates + 1 end
  end
  stats.pick = pick_id ~= nil and present[pick_id] == true
  local cols, list = notion_tasks.snapshot({
    sources = sources,
    rows_by_source = rows_by_source,
    by_id = by_id,
    docs_titles = titles,
    rules_by_id = rules_by_id,
    chosen_id = (why == "user" or why == "config") and chosen.id or nil,
    pick_id = stats.pick and pick_id or nil,
    fetch = fetch,
  })
  K:put_snapshot(notion_tasks.SOURCE, cols, list)
  stats.collections, stats.tasks = #cols, #list
  for _, r in ipairs(list) do
    if r.open and not r.archived then stats.open = stats.open + 1 end
  end
end

local function pass(d, K, stats, start)
  local docs, sources, rows_by_source, by_id = collect(d.client, K)
  if not docs then return nil, sources end
  local titles, seen = {}, {}
  for _, doc in ipairs(docs) do
    titles[doc.page.id] = nt.title(doc.page)
    seen[doc.page.id] = true
  end
  for _, src in ipairs(sources) do seen[src.id] = true end
  stats.seen = #docs

  local stored = K:edited_map()
  local prev = tonumber(K:meta("started_prev"))
  local read_at = K:meta_prefix("read:")
  local fails = K:meta_prefix("fail:")
  local gaps_at = K:meta_prefix("gap:")
  local max_pages = tostring(notion.MAX_PAGES)
  for _, doc in ipairs(docs) do
    local p = doc.page
    local edited = type(p.last_edited_time) == "string" and p.last_edited_time or ""
    local edited_s = sync.iso_epoch(edited)
    local since = tonumber(read_at[p.id])
    if prev and (not since or prev > since) then since = prev end
    local recent = since ~= nil and (edited_s == nil or edited_s >= since - sync.RECENT_S)
    local n_fail, fail_pages, fail_edited = (fails[p.id] or ""):match("^(%d+) (%d+) (.*)$")
    n_fail = fail_edited == edited and fail_pages == max_pages and tonumber(n_fail) or 0
    local gap_at = tonumber(gaps_at[p.id])
    local gap_due = gap_at ~= nil and start - gap_at >= sync.GAP_RETRY_S
    local want = stored[p.id] ~= edited or recent or gap_due
    local body, err, gaps
    if want and n_fail >= sync.MAX_FAILS then
      stats.skipped = stats.skipped + 1
    elseif want then
      body, err, gaps = d.client:blocks_text(p.id)
      if not body then
        if not (tostring(err):match("^http 404") or err == "incomplete") then return nil, err end
        stats.skipped = stats.skipped + 1
        if err == "incomplete" then K:set_meta("fail:" .. p.id, (n_fail + 1) .. " " .. max_pages .. " " .. edited) end
        -- перечитывалась только из-за окна: после удачного прогона окно уйдёт вперёд и правку с тем же
        -- edited потеряем — снимаем сохранённый edited, чтобы страница перечиталась
        if stored[p.id] == edited then K:forget_edited(p.id) end
      end
    end
    if body then
      K:put_doc({
        id = p.id,
        source_id = doc.source_id,
        title = titles[p.id],
        edited = edited,
        text = nt.doc(doc.source_title, p, body, titles),
        props_json = json.encode(nt.props(p, titles)),
      })
      K:set_meta("read:" .. p.id, start)
      if fails[p.id] then K:delete_meta("fail:" .. p.id) end
      if (tonumber(gaps) or 0) > 0 then
        K:set_meta("gap:" .. p.id, start)
      elseif gaps_at[p.id] then
        K:delete_meta("gap:" .. p.id)
      end
      stats.updated = stats.updated + 1
    end
  end
  stats.deleted = K:delete_missing(seen)
  for id in pairs(fails) do
    if not seen[id] then K:delete_meta("fail:" .. id) end
  end
  for id in pairs(gaps_at) do
    if not seen[id] then K:delete_meta("gap:" .. id) end
  end
  put_tasks(d, K, stats, sources, rows_by_source, by_id, titles, start)
  K:set_meta("last_ok", d.wall())
  K:set_meta("started_prev", start)
  K:delete_meta_prefix("read:") -- все метки ≤ start: окно теперь от started_prev
  return true
end

-- строка лога классификации: только исход и числа
function sync.classify_line(stats)
  return string.format("riddle: classify %s candidates=%d pick=%s in %d ms%s", tostring(stats.classify),
    tonumber(stats.candidates) or 0, stats.pick and "yes" or "no", tonumber(stats.classify_ms) or 0,
    stats.classify_deferred and " deferred" or "")
end

-- d = { client, store_path, wall, clock, log?, tasks_source? (ключ конфига),
--       classify? = fn(messages) -> text | nil, err, logs }
-- -> { seen, updated, deleted, skipped, chars, ms, collections, tasks, open, classify?, candidates, pick,
--      classify_ms, classify_deferred?, llm_logs, err? }
function sync.run(d)
  local t0 = d.clock()
  local start = d.wall()
  local stats = { seen = 0, updated = 0, deleted = 0, skipped = 0, chars = 0, ms = 0,
    collections = 0, tasks = 0, open = 0, candidates = 0, pick = false, classify_ms = 0, llm_logs = {} }
  local ok, K = pcall(knowledge.open, d.store_path)
  if not ok then
    stats.err = "store: " .. tostring(K)
  else
    local pok, res, err = pcall(pass, d, K, stats, start)
    if not pok then
      -- упал проход: ошибка базы (lua-ljsqlite3: «ljsqlite3[код] …») — «store: », иначе ошибка кода — «lua: »
      local e = tostring(res)
      stats.err = (e:find("ljsqlite3[", 1, true) and "store: " or "lua: ") .. e
    elseif not res then
      stats.err = tostring(err)
    end
    local sok, s = pcall(K.stats, K)
    if sok then stats.chars = s.chars end
    K:close()
  end
  stats.ms = math.floor((d.clock() - t0) * 1000 + 0.5)
  if d.log then
    if stats.err then
      d.log(string.format("riddle: sync stopped: %s (updated=%d)", stats.err, stats.updated))
    else
      d.log(string.format("riddle: sync done seen=%d updated=%d deleted=%d chars=%d%s in %d ms" ..
        " collections=%d tasks=%d open=%d",
        stats.seen, stats.updated, stats.deleted, stats.chars,
        stats.skipped > 0 and (" skipped=" .. stats.skipped) or "", stats.ms,
        stats.collections, stats.tasks, stats.open))
    end
    for _, line in ipairs(stats.llm_logs) do d.log(line) end
    if stats.classify then d.log(sync.classify_line(stats)) end
  end
  return stats
end

-- «<unix-время> ok» или «<unix-время> <ошибка одной строкой>» + перевод строки; пустая ошибка — «error»
function sync.last_line(now, err)
  if err == nil then return string.format("%d ok\n", now) end
  local text = str.one_line(tostring(err))
  return string.format("%d %s\n", now, text ~= "" and text or "error")
end

-- обратное last_line: {at, err} (err = nil при ok) | nil на негодном тексте (не строка, не одна строка, нет времени)
function sync.parse_last(text)
  if type(text) ~= "string" then return nil end
  local line = str.trim(text)
  if line:find("[\r\n]") then return nil end
  local at, rest = line:match("^(%d+) (.+)$")
  if not at then return nil end
  return { at = tonumber(at), err = rest ~= "ok" and rest or nil }
end

return sync
