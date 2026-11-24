-- Склейка: PNG -> LLM -> печать -> память -> текст для экрана.
-- Все зависимости приходят снаружи (deps), поэтому модуль тестируется без устройства.
-- Инварианты: on_page и begin всегда удаляют PNG; finish всегда возвращает непустой текст,
-- on_page и неудачный begin — тоже, кроме случайного касания (PNG меньше png.MIN_SIDE по обеим
-- сторонам): тогда nil (begin — nil, nil), модель не вызывается, показывать нечего.

local seal = require("riddle.seal")
local glyph = require("riddle.glyph")
local texts = require("riddle.texts")
local prompt = require("riddle.prompt")
local str = require("riddle.str")
local png = require("riddle.png")
local rhythm = require("riddle.rhythm")
local tasks = require("riddle.tasks")
local persona = require("riddle.persona")
local llm = require("riddle.llm")
local net = require("riddle.net")
local mapdata = require("riddle.mapdata")
local json = require("dkjson")

local Controller = {}

-- строка personas встроенной персоны «Методов», когда её данные карты читать неоткуда (контроллер без базы, сбой
-- чтения): разделов нет — генерировать некуда, карта на запасных
local METHODS_ROW = { id = persona.METHODS_ID, state = "ready", source = "builtin" }

local SUMMARIES_N = 5
-- потолок ответа пересказа: 2–3 предложения по-русски с рассуждением модели не влезают в 200 токенов
-- ответа на страницу, а обрезок (finish_reason=length) — промах, и пересказа не было бы никогда
Controller.SUMMARY_MAX_TOKENS = 800

-- свёртка выпавшего из окна внутри сессии: когда несвёрнутых реплик набирается на целое окно истории, старейшие
-- ROLL_BATCH сворачиваются в пересказ (вместе с прежним) — так окно покрывает все несвёрнутые. Пересказ длиннее
-- 2–3 предложений — потолок ответа выше. Неудача (кроме отмены) — пауза до ROLL_RETRY новых реплик
Controller.ROLL_AT = prompt.MAX_RECENT
Controller.ROLL_BATCH = 20
Controller.ROLL_MAX_TOKENS = 1200
Controller.ROLL_RETRY = 6

-- имя пула фраз по причине сбоя; err — ошибка llm_call, у цепочки это ошибка последнего провайдера
-- (llm.call: «имя: причина» или «budget»; каждый опрошенный отказал суточной квотой — с префиксом llm.DAILY);
-- причины — из http.lua и llm.parse
local function fail_pool(err)
  if llm.daily(err) then return "fail_daily" end
  if err == "budget" then return "fail_slow" end
  local kind = net.fail_kind(err)
  return kind and ("fail_" .. kind) or "fail_other"
end

-- запись прочитана: read не пуст и не "?". Одно правило для ответа, страницы настройки (setup) и ответа на вопрос
-- о строке: нечитаемое не должно ни записываться, ни отвергать строку
function Controller.readable(result)
  local read = result.read or ""
  return read ~= "" and read ~= "?"
end

-- ответ модели годен к показу: запись прочитана и есть reply. Одно условие для _answer и для повтора запроса
-- (app Chain:_run_retry): плохой повтор не вытесняет первый хороший ответ
function Controller.usable(result)
  return Controller.readable(result) and (result.reply or "") ~= ""
end

function Controller.new(deps)
  local self = {
    deps = deps,
    seal = seal.new(deps.cfg.seal),
    -- реплики { role, text } с момента закрытия печати: связность разговора без памяти (spec §4). Живут в процессе,
    -- сбрасывает открытие (seal_toggle)
    closed_turns = {},
    -- растёт на каждом открытии и закрытии печати (seal_toggle, _opened): ответ, собранный до сдвига, не
    -- показывается (finish)
    seal_epoch = 0,
    bags = {},
    pools = {}, -- сгенерированные наборы фраз: "id:name" -> { src, list } (Controller:texts)
  }
  self = setmetatable(self, {
    __index = function(t, k)
      if k == "seal_open" then return t.seal.open end
      return Controller[k]
    end,
  })
  self.pending = self:_load_pending()
  self:_load_key()
  if self.seal.invalid then
    -- битые правила в конфиге: печать закрыта и ключом не открывается — опечатка дневник не открывает
    self:_log("riddle: seal config invalid: " .. self.seal.invalid)
  elseif not self.seal.configured then
    -- печати нет: дневник открыт сразу, разблокировки не будет — хвост (лор, пересказ) положен с старта
    self.followup_due = true
    self:_log(deps.cfg.seal.off and "riddle: seal off by flag" or "riddle: seal off (no rules in config)")
  end
  return self
end

function Controller:_log(msg)
  if self.deps.log then pcall(self.deps.log, msg) end
end

-- образец ключа на старте (спека §5, §9): флаг off — образец удаляется (решение владельца «А»: знак забыт, флаг
-- снят — режим «задать ключ» с нуля); ключ в правилах — образец читается: нет файла — режим задания, битый — печать
-- закрыта (Review Focus 2). deps.load_key / forget_key передаёт app.new_controller (seal.load_key, seal.forget_key);
-- стенд без них образца не знает — печать как до ключа
function Controller:_load_key()
  local deps, s = self.deps, self.seal
  local path = deps.key_path or seal.KEY_PATH
  self.key_path = path
  if s.rules.off then
    if deps.forget_key then
      local ok, err = deps.forget_key(path)
      if not ok then self:_log("riddle: seal key forget failed: " .. tostring(err)) end
    end
    return
  end
  if not (s:wants_key() and deps.load_key) then return end
  local drawings, err = deps.load_key(path)
  s:key_loaded(drawings, err)
  if s.setting then
    self:_log("riddle: seal key absent, setting mode")
  elseif not drawings then
    self:_log("riddle: seal key unreadable")
  end
end

-- страница из штрихов (виджет, до треугольника) -> фраза | nil. Ключ задан — страница, совпавшая с образцом
-- (glyph.match), сдвигает печать (seal_toggle): закрытую открывает, открытую закрывает; модель не зовётся.
-- В режиме «задать ключ» страница до glyph.MAX_STROKES штрихов — попытка знака: модель её не видит, в память она
-- не идёт (спека §5, шаги 2–6).
-- Первый рисунок живёт только в памяти (key_first; сон, закрытие и перезапуск его сбрасывают); второй
-- сверяется с ним, совпал — образец из обоих пишется на устройство и печать открывается. Не совпал — режим заново,
-- без счётчика попыток. Иначе nil: страница идёт дальше по порядку
function Controller:key_page(strokes)
  if #strokes == 0 or #strokes > glyph.MAX_STROKES then return nil end
  local drawings = self.seal.drawings
  if drawings then
    if not glyph.match(strokes, drawings) then return nil end
    return self:seal_toggle()
  end
  if not self.seal.setting then return nil end
  local fits, why = glyph.fits(strokes)
  if not fits then return why == "size" and texts.key_bigger or texts.key_taken end
  local first = self.key_first
  if not first then
    self.key_first = strokes
    return texts.key_again
  end
  self.key_first = nil
  if not glyph.match(strokes, { first }) then
    self:_log("riddle: seal key setting, drawings differ")
    return texts.key_retry
  end
  local drawings = { first, strokes }
  local ok, err = self.deps.write_key(self.key_path, seal.encode(drawings))
  if not ok then
    self:_log("riddle: seal key write failed: " .. tostring(err))
    return texts.key_retry
  end
  self:_log("riddle: seal key saved")
  self.seal:key_saved(drawings, self.deps.now())
  self:_opened()
  return texts.key_saved
end

-- «мешок» на каждый список: фраза не вернётся, пока не показаны все остальные;
-- на стыке мешков последняя показанная не идёт первой
function Controller:_pick(list)
  local bag = self.bags[list] or { left = {} }
  self.bags[list] = bag
  local held
  if #bag.left == 0 then
    for i = 1, #list do
      if i == bag.last and #list > 1 then held = i else bag.left[#bag.left + 1] = i end
    end
  end
  local i = table.remove(bag.left, self.deps.random(#bag.left))
  if held then bag.left[#bag.left + 1] = held end
  bag.last = i
  return list[i]
end

-- фраза из пула без повторов подряд (мешок на список); для виджета: раздумье, отказы.
-- used — уже показанные в этом ожидании (фраза -> true): мешок после пересыпки мог бы вернуть
-- одну из них; берётся другая, пока в пуле есть непоказанные, и она добавляется в used
function Controller:pick(list, used)
  local s = self:_pick(list)
  if used then
    for _ = 1, #list do
      if not used[s] then break end
      s = self:_pick(list)
    end
    used[s] = true
  end
  return s
end

-- запись в память не должна терять ответ: ошибка логируется, текст всё равно уйдёт на экран.
-- job — страница (_begin): её сессия (job.sid) и решение о записи (job.write).
-- owner_marks, diary_marks — метки реплик (memory.add), nil — без меток. -> true, если метки пишущего легли
function Controller:_remember(job, read, reply, owner_marks, diary_marks)
  if not job.write then return false end
  local saved
  local ok, err = pcall(function()
    local now = self.deps.now()
    saved = self.deps.memory:add(job.sid, "owner", read, now, owner_marks)
    self.deps.memory:add(job.sid, "diary", reply, now, diary_marks)
  end)
  if not ok then self:_log("riddle: memory write failed: " .. tostring(err)) end
  return ok and saved == true
end

-- к какой задаче запись: job.tasks — контекст задач (app.tasks_context), task — поле ответа модели.
-- Контекста нет — nil, как до задач. Блока нет (книги нет или 0 незакрытых) — "": запись не может касаться
-- дела, которого нет. Иначе метка блока -> id, "" -> "", "all" (о делах вообще) и "ask" (вопрос не о делах) — как
-- есть, чужое (не метка, нет поля) -> nil — неизвестно.
-- -> метка | nil, вид для лога ("yes" | "all" | "ask" | "none" | "unknown") | nil
local function task_mark(tasks_ctx, task)
  if not tasks_ctx then return nil end
  if not tasks_ctx.block then return "", "none" end
  if task == "" then return "", "none" end
  if task == "all" or task == "ask" then return task, task end
  local id = type(task) == "string" and tasks_ctx.block.by_label[task]
  if id then return id, "yes" end
  return nil, "unknown"
end

-- знание из Notion для открытой печати: deps.knowledge_text() -> знание | nil (разделы app.knowledge_text или
-- текст — prompt.open берёт оба), mode, nil, контекст задач | nil; сбой — ответ без знания и задач.
-- -> знание, контекст задач
function Controller:_knowledge()
  if not self.deps.knowledge_text then return nil end
  local ok, knowledge, _, _, tasks_ctx = pcall(self.deps.knowledge_text)
  if not ok then
    self:_log("riddle: knowledge read failed: " .. tostring(knowledge))
    return nil
  end
  return knowledge, tasks_ctx
end

-- текущая персона по строке конфига (cfg.whose; спека 2026-10-31, «Как работает» 1, 6) -> view | nil, row | nil,
-- parts | nil. Строки нет или «Методов» — встроенная. Иначе строка personas по ключу (нет — заводится, разделов
-- нет); view — когда раздел persona готов. Хранилища нет (миграция 5 не прошла) — всё nil.
-- В лог — вид и состояние при смене, без строки: это данные пользователя
-- последняя строка, сохранённая ответом пером (Memory:last_asked) -> row | nil, доступно, сбой. Хранилища персон нет
-- (или память без него — подделки тестов) — nil, false. Сбой чтения — не то же самое, что «хранилища нет»: nil, false,
-- true; дневник тогда не знает, чей он, и отвечает фразой сбоя (_builtin ложно, _current без строки), а не голосом и
-- памятью «Методов». Сбой запоминается до следующей страницы (_begin сбрасывает): чтение и строка лога — раз на страницу.
-- Строка в самой базе не меняется, пока не сохранён новый ответ (_ask_answer сбрасывает кэш)
function Controller:_asked()
  local memory = self.deps.memory
  if not (memory and memory.last_asked) then return nil, false end
  local cached = self.saved_ask
  if not cached then
    local ok, row, avail = pcall(memory.last_asked, memory)
    if ok then
      cached = { row = row, avail = avail == true }
    else
      self:_log("riddle: persona asked read failed: " .. tostring(row))
      cached = { avail = false, failed = true }
    end
    self.saved_ask = cached
  end
  return cached.row, cached.avail, cached.failed
end

-- строка конфига, если она действует -> line | nil. Отвергнутая («нет» на вопрос о ней, мир неизвестен; state =
-- "rejected") — как строки нет: дневник спрашивает «Чей это дневник?» пером, по кругу, пока не появится личность
-- (владелец 2026-11-06). Новая строка в конфиге — новый ключ, своя строка personas: снова действует.
-- Чтение — раз на страницу (_begin и opening_text сбрасывают self.config_seen) и после смены состояния строки
-- (_config_changed).
-- Сбой чтения (не «нет таблицы») — строка действует, как до отказа: дальше _current под pcall отдаёт фразу сбоя;
-- сбой запоминается до следующей страницы, в лог — раз
function Controller:_config_line()
  local line, memory = self.deps.cfg.whose, self.deps.memory
  -- «Методов» в базе не заводится и не отвергается: без чтения
  if not (line and memory and memory.persona_by_key) or persona.is_methods(line) then return line end
  local seen = self.config_seen
  if not (seen and seen.line == line) then
    local ok, row = pcall(memory.persona_by_key, memory, persona.key(line))
    if not ok then self:_log("riddle: persona config read failed: " .. tostring(row)) end
    seen = { line = line, rejected = ok and row ~= nil and row.state == "rejected" }
    self.config_seen = seen
  end
  if seen.rejected then return nil end
  return line
end

-- состояние строки personas сменилось (ответ на вопрос о строке, разбор): строку конфига перечитать. «Да» пером
-- строку конфига не меняет: другой ключ — она как была, тот же — та же строка, что и сохранённая
function Controller:_config_changed()
  self.config_seen = nil
end

-- строка, по которой живёт дневник: действующая строка конфига важнее сохранённой ответом пером; ни той, ни другой — nil
function Controller:_line()
  return self:_config_line() or (self:_asked() or {}).line
end

-- дневник спрашивает «Чей это дневник?»: действующей строки нет ни в конфиге, ни среди сохранённых, а хранилище персон
-- есть. Хранилища нет — «Методов», как до персонажей
function Controller:_asking()
  if self:_config_line() then return false end
  local row, avail = self:_asked()
  return avail and not row
end

-- строки нет (хранилища персон тоже) или она «Методов» — встроенная персона: база не нужна. Вопрос — не встроенная
function Controller:_builtin()
  if self:_asking() then return false end
  local line = self:_line()
  if not line then return not select(3, self:_asked()) end
  return persona.is_methods(line)
end

-- разделы «Методов» (только данные карты, persona.MAP_SECTIONS) и её строка personas id 1: по строке генерация
-- просит мир «Методов» (план карты, раздел 2). -> parts, row | nil (нет базы; сбой чтения — в лог): «Методов»
-- отвечает как прежде, карта — на запасных
function Controller:_methods_store()
  local memory = self.deps.memory
  if not memory then return nil end
  local ok, parts, row = pcall(function()
    local p = memory:parts(persona.METHODS_ID)
    return p, p and memory:persona_by_id(persona.METHODS_ID)
  end)
  if not ok then
    self:_log("riddle: methods map read failed: " .. tostring(parts))
    return nil
  end
  if parts and row then return parts, row end
end

function Controller:_current()
  local line = self:_line()
  local view, row, parts, kind
  if self:_asking() then
    kind = "ask"
  elseif not line and not self:_builtin() then
    kind = "none" -- чтение сохранённой строки упало (_asked): персоны нет, страница получит фразу сбоя
  elseif self:_builtin() then
    view, kind = persona.METHODS_VIEW, "methods"
    parts, row = self:_methods_store()
    row = row or METHODS_ROW
  else
    local memory = self.deps.memory
    local key = persona.key(line)
    row = memory:persona_by_key(key)
    if not row and memory:add_persona{ key = key, line = line, source = "config", state = "new",
        ts = self.deps.now() } then
      row = memory:persona_by_key(key)
    end
    parts = row and memory:parts(row.id)
    view = parts and persona.view(row, parts)
    kind = not parts and "none" or view and "generated" or "pending"
  end
  local tag = "riddle: persona " .. kind .. " state=" .. tostring(row and row.state)
  if tag ~= self.persona_logged then
    self.persona_logged = tag
    self:_log(tag)
  end
  return view, row, parts
end

-- память текущей персоны (миграция 6, memory:use_persona) -> true | false: персона не «Методов», а помнить её негде
-- (шаг 6 не прошёл; память общая — «Методов»). Без памяти (контроллер без базы) — true: читать нечего
function Controller:_use_memory()
  local memory = self.deps.memory
  if not memory then return true end
  if self:_asking() then return false end -- вопрос ещё без ответа: помнить некого, и жаловаться не на что
  local id = persona.METHODS_ID
  if not self:_builtin() then
    local _, row = self:_current()
    if not row then return false end
    id = row.id
  end
  if memory:use_persona(id) then return true end
  self:_log("riddle: persona has no memory")
  return false
end

-- как дневник говорит о себе в служебных промптах (пересказ, свёртка): «Методов» — METHODS_VIEW
-- (прежний текст), сгенерированная — свой вид, персонажа нет (вопрос «чей дневник», раздела persona ещё нет, сбой
-- чтения) — persona.NONE_VIEW: на языке записи, о себе без рода
function Controller:_self_view()
  if self:_builtin() then return persona.METHODS_VIEW end
  local ok, view = pcall(self._current, self)
  return ok and view or persona.NONE_VIEW
end

-- данные карты мародёров текущей персоны (riddle.mapdata) — та же персона, что отвечает на страницы (_current);
-- сбой чтения — запасные (карта открывается всё равно: пергамент и надпись blind). Не только чтение: _current у
-- персоны из конфига без строки personas заводит её (как первая страница) — карта, открытая раньше первой страницы,
-- оставляет в базе строку персонажа
function Controller:map()
  local ok, view, row, parts = pcall(self._current, self)
  if not ok then
    self:_log("riddle: map data failed: " .. tostring(view))
    return mapdata.of(nil, nil, nil)
  end
  local got, owner = pcall(self.owner_name, self)
  if not got then
    -- без текста ошибки: в нём может оказаться имя (спека карты, решение 3 от 2026-11-16 — имя владельца в лог не пишется)
    self:_log("riddle: owner name failed")
    owner = nil
  end
  return mapdata.of(view, row, parts, owner)
end

-- имя, которым владелец представился дневнику текущей персоны (книга с именем на карте: срез 13а) | nil — не
-- представлялся, персоны нет (вопрос «Чей это дневник?» без ответа), нет базы. Пишет его _answer (срез 13б)
function Controller:owner_name()
  local memory = self.deps.memory
  if not memory then return nil end
  local _, row = self:_current()
  return row and memory:owner_name(row.id)
end

-- как пишущий назвал себя в записи (ключ "name", prompt.NAME_FORMAT) -> строке персоны страницы (job.persona_id), если
-- страница пишет в память (job.write); негодное (mapdata.owner) — мимо, прежнее имя остаётся. В лог — только итог, без
-- имени и без текста ошибки (в нём может быть имя)
function Controller:_save_owner_name(job, name)
  name = mapdata.owner(name)
  if not (job.persona_id and name and job.write) then return end
  local memory = self.deps.memory
  local ok, saved = pcall(memory.set_owner_name, memory, job.persona_id, name)
  self:_log((ok and saved) and "riddle: owner name saved" or "riddle: owner name save failed")
end

-- имя дневника в меню KOReader: «Методов» — «Дневник Реддла», сгенерированной — title её раздела persona, иначе
-- «Дневник / Diary». Только чтение: меню строку в базу не заводит (это делает страница, _current); сбой — нейтральное
function Controller:title()
  local ok, title = pcall(function()
    if self:_builtin() then return persona.METHODS_VIEW.title end
    local memory, line = self.deps.memory, self:_line()
    if not (memory and line) then return nil end
    local row = memory:persona_by_key(persona.key(line))
    local view = row and persona.view(row, memory:parts(row.id))
    return view and view.title
  end)
  return ok and title or persona.DEFAULT_TITLE
end

-- первый недостающий раздел текущей персоны -> section, row, view | nil
function Controller:_gen_next()
  local view, row, parts = self:_current()
  if not parts then return nil end
  return persona.next_section(row, parts), row, view
end

local function known_lang(l) return (l == "ru" or l == "en") and l or nil end

-- язык нейтрального голоса: персоны (view.lang), иначе строки personas (row.lang — у ответа пером cfg.whose нет),
-- иначе язык вопроса, на который ждут ответ, — только пока он ждёт (режим вопроса): поднятый из базы при действующей
-- строке вопрос спит и языка не меняет (ревью 5e1523b); язык персонажа неизвестен (строка не разобрана) — "en"
-- (владелец 2026-11-06: «на англ»), по алфавиту строки язык не угадывается
function Controller:_neutral_lang(view, row)
  return known_lang(view and view.lang) or known_lang(row and row.lang)
    or (self.pending and self:_asking() and known_lang(self.pending.lang)) or "en"
end

-- нейтральный пул вместо набора name (texts.NEUTRAL_FOR). Списки константы: мешок _pick держится
function Controller:_neutral(name, view, row)
  return texts.neutral[self:_neutral_lang(view, row)][texts.NEUTRAL_FOR[name]]
end

-- фразы пула name (texts.SETS) текущей персоны: её набор (раздел texts.<name>); его нет (персона не готова, набор не
-- сгенерирован, чтение упало) — нейтральный пул (texts.neutral), не «Методов». У «Методов» — пулы texts как есть.
-- Таблица одна на текст набора: мешок _pick держится, пока набор тот же. Фраза нужна всегда, в том числе на сбой
function Controller:texts(name)
  if self:_builtin() then return texts[name] end
  local ok, view, row, parts = pcall(self._current, self)
  local src = ok and parts and parts["texts." .. name]
  if not src then return self:_neutral(name, ok and view or nil, ok and row or nil) end
  local key = row.id .. ":" .. name
  local hit = self.pools[key]
  if hit and hit.src == src then return hit.list end
  local list = json.decode(src)
  if type(list) ~= "table" or #list == 0 then return self:_neutral(name, view, row) end
  self.pools[key] = { src = src, list = list }
  return list
end

-- вопрос «Так это дневник …?», на который строка ждёт ответа (state = "confirm") | nil
local function pending_ask(row)
  if row and row.state == "confirm" and type(row.ask) == "string" and row.ask ~= "" then return row.ask end
end

-- вопрос текущей персоны, если он есть. «Методов» не спрашивается никогда; сбой чтения — вопроса нет
function Controller:_pending_ask()
  if self:_builtin() then return nil end
  local ok, _, row = pcall(self._current, self)
  return ok and pending_ask(row) or nil
end

-- вопрос «чей дневник», пока строки нет: названный пером персонаж ждёт «да» — вопрос с миром, иначе общее
-- «Чей это дневник?» (двуязычное). Показанный вопрос — self.asked: запись после него читается как ответ
function Controller:_ask_open()
  local q = self.pending and self.pending.ask
  if q then
    self.asked = q
    return q
  end
  return self:_pick(texts.neutral.ru.ask)
end

local trimmed = require("riddle.str").trim

-- ждущий вопрос «Так это дневник …?» из базы (Memory:asked_pending, миграция 8): перезапуск KOReader его не теряет.
-- Хранилища нет (память без него — подделки тестов, шаг 8 не прошёл) или чтение упало — вопроса нет, как до шага
function Controller:_load_pending()
  local memory = self.deps.memory
  if not (memory and memory.asked_pending) then return nil end
  local ok, row = pcall(memory.asked_pending, memory)
  if not ok then
    self:_log("riddle: persona pending read failed: " .. tostring(row))
    return nil
  end
  return row
end

-- ждущий вопрос в базу (f — { lang, ask, line }) или снят (nil). Пишет только _ask_answer. Сбой записи — вопрос живёт
-- в процессе, как до шага 8; в лог — без строки и вопроса (данные пользователя)
function Controller:_store_pending(f)
  local memory = self.deps.memory
  if not (memory and memory.set_asked_pending) then return end
  local ok, err
  if f then
    ok, err = pcall(memory.set_asked_pending, memory,
      { line = f.line, ask = f.ask, lang = f.lang, ts = self.deps.now and self.deps.now() or 0 })
  else
    ok, err = pcall(memory.clear_asked_pending, memory)
  end
  if not ok then self:_log("riddle: persona pending store failed: " .. tostring(err)) end
end

-- запись, прочитанная на вопрос «Чей это дневник?» (job.stage = "ask", строки нет): «да» на названного (self.pending)
-- сохраняет строку «персонаж — мир»; названный персонаж без «да» — новый вопрос с миром (по-прежнему не сохранён);
-- имени нет: был вопрос с миром — снова «Чей это дневник?» (владелец 2026-11-06), не было — фраза модели.
-- Нечитаемое — вопрос остаётся. В память дневника ответ не ложится; в лог — решение, без имён
function Controller:_ask_answer(job, result)
  if not Controller.readable(result) then return self:_pick(self:texts("unreadable")) end
  local memory = self.deps.memory
  local pending = self.pending
  if pending and result.yes then
    local ok, id = pcall(memory.save_asked, memory,
      { key = persona.key(pending.line), line = pending.line, lang = pending.lang, ts = self.deps.now() })
    if not (ok and id) then
      self:_log("riddle: persona asked save failed: " .. tostring(ok and "no store" or id))
      return self:_pick(self:texts("fail_other"))
    end
    self.pending, self.saved_ask, self.asked = nil, nil, nil
    -- падение до снятия оставит строку в базе, но её не читают: личность уже есть (_asking ложно)
    self:_store_pending(nil)
    self:_log("riddle: persona asked saved")
    -- дневник пока без голоса (генерация только начнётся): «загляни позже»; «Методов» — их голосом
    return self:_pick(self:texts("sleepy"))
  end
  -- who, world, lang разобраны на входе (llm.parse): пустого и фраз вместо кода нет
  local who, world = result.who, result.world
  if not who then
    -- «нет» на «Так это дневник …?» — снова «Чей это дневник?», по кругу до «да» (владелец 2026-11-06)
    self.pending, self.asked = nil, nil
    if pending then
      self:_store_pending(nil)
      return self:_ask_open()
    end
    local reply = trimmed(result.reply)
    return reply ~= "" and reply or self:_pick(texts.neutral.ru.ask)
  end
  local lang = known_lang(result.lang and result.lang:lower()) or persona.lang_of(who)
  local ask = trimmed(result.reply)
  if ask == "" then ask = persona.ask_line(who, world, lang) end
  self.pending = { lang = lang, ask = ask, line = world and (who .. " — " .. world) or who }
  self:_store_pending(self.pending)
  self.asked = ask
  self:_log("riddle: persona asked (pending)")
  return ask
end

-- первая строка на чистой странице (открытие, пробуждение): вопрос о строке, если он ждёт; иначе без печати —
-- приветствие персонажа (мешок), с печатью — его приглашение; приглашения нет или персонаж не готов (persona.ready), сбой чтения — нейтральное; «Методов» — texts.invitation
function Controller:opening_text()
  -- чистая страница — как новая: строка конфига читается заново. Иначе сбой чтения до сна держал бы её действующей
  -- до первой записи, и отвергнутая строка давала бы приветствие вместо «Чей это дневник?»
  self:_config_changed()
  -- ключ ещё не задан: страница ждёт знак (спека §5, шаг 1); вопрос о строке — после, когда печать откроется
  if self.seal.setting then return texts.key_draw end
  -- вопрос о строке — и при закрытой печати: страница отвечает на вопрос, который был на экране (spec §4)
  -- строки нет вовсе: «Чей это дневник?» (задача 8); ответ уже прочитан и ждёт «да» — тот же вопрос с миром
  if self:_asking() then return self:_ask_open() end
  -- строка без мира в конфиге: вместо приветствия — вопрос о ней (задача 7); следующая запись — ответ на него
  local ask = self:_pending_ask()
  if ask then
    self.asked = ask
    return ask
  end
  if not self.seal.configured then return self:pick(self:texts("greetings")) end
  if self:_builtin() then return texts.invitation end
  local ok, view, row, parts = pcall(self._current, self)
  -- своё приглашение — когда персонаж готов целиком (persona и world), раньше — нейтральное
  if ok and view and persona.ready(row, parts) and view.invitation then return view.invitation end
  return self:pick(self:_neutral("greetings", ok and view or nil, ok and row or nil))
end

-- файл forget_persona (main.lua): сгенерированные разделы текущей персоны стёрты — генерация начнётся заново.
-- Встроенную «Методов» не трогает. -> true, если стёрто
function Controller:forget_persona()
  local _, row = self:_current()
  if not row or row.id == persona.METHODS_ID then return false end
  self.deps.memory:forget_parts(row.id)
  self.gen_hold = nil
  self:_log("riddle: persona forgotten")
  return true
end

-- недостающий раздел, который пора генерировать -> section | nil: нет паузы после сбоя (gen_hold — до следующей
-- страницы; map_hold — у разделов карты, до следующего открытия дневника или сна). Печать не мешает: генерация берёт
-- только строку персоны (prompt.gen_*), данных пользователя не читает (spec §4). Сбой чтения — nil
function Controller:_gen_due_section()
  if self.gen_hold then return nil end
  local ok, sec = pcall(self._gen_next, self)
  if not ok then
    self:_log("riddle: gen check failed: " .. tostring(sec))
    return nil
  end
  if sec and self.map_hold and persona.is_map(sec.name) then return nil end
  return sec
end

-- генерация персоны нужна (в том числе данных карты): виджет ставит хвост на открытии и следующий за хвостом
function Controller:gen_due()
  return self:_gen_due_section() ~= nil
end

-- генерация — повод для хвоста после ответа: нужна и это не данные карты. Сведения карты ответу не нужны: их генерирует
-- хвост открытия (maybeStartGen) и цепочка после хвоста (finish_followup), страница ради них хвост не берёт — иначе
-- стабильный сбой карты или синхронный путь без runner звали бы модель на каждой странице
function Controller:_gen_tail_due()
  local sec = self:_gen_due_section()
  return sec ~= nil and not persona.is_map(sec.name)
end

-- данные пользователя (память, лор, знания, задачи) доступны: печать открыта или её нет. Одно условие на все пути,
-- что их читают или отправляют модели (spec §4)
function Controller:_data_ok()
  return self.seal.open
end

-- сказанное на странице ложится в память дневника: база открыта, и печать открыта или правило remember (ответ
-- владельца 20.11: разговор при закрытой печати по умолчанию запоминается). Спрашивает _begin — в начале страницы
-- (job.write)
function Controller:_may_write()
  return self.deps.memory ~= nil and (self:_data_ok() or self.seal.rules.remember == true)
end

-- реплика при закрытой печати — в связность разговора; хранится не больше окна истории промпта
local function add_closed_turn(turns, read, reply)
  turns[#turns + 1] = { role = "owner", text = read }
  turns[#turns + 1] = { role = "diary", text = reply }
  while #turns > prompt.MAX_RECENT do table.remove(turns, 1) end
end

-- данные для ответа -> ctx для prompt.open, контекст задач | nil. Единственная точка отсечения: при закрытой печати
-- ни память, ни лор, ни знания, ни задачи не читаются — только реплики с момента закрытия.
-- parts — разделы текущей персоны (nil у «Методов»): мир уходит в лор после lore.md
function Controller:_open_context(sid, parts)
  if not self:_data_ok() then return { seal = "closed", recent = self.closed_turns }, nil end
  local memory = self.deps.memory
  local summaries = {}
  for _, s in ipairs(memory:summaries(SUMMARIES_N)) do
    if s ~= "" then summaries[#summaries + 1] = s end
  end
  -- в родителе, до fork: дочерний процесс базу не открывает
  local knowledge, tasks_ctx = self:_knowledge()
  -- свёртка — не ценой ответа: сбой чтения — промпт без неё
  local ok, rolling = pcall(memory.rollup, memory, sid)
  if not ok then self:_log("riddle: roll read failed: " .. tostring(rolling)) end
  return {
    lore = prompt.lore_block(memory:lore_text(), parts and parts.world, memory.LORE_CAP),
    summaries = summaries,
    rolling = ok and rolling or nil,
    recent = memory:recent(sid, prompt.MAX_RECENT),
    knowledge = knowledge,
    tasks = tasks_ctx and tasks_ctx.block,
    titles = tasks_ctx and tasks_ctx.titles,
  }, tasks_ctx
end

-- сырое поле ответа модели для лога: строка — в кавычках, переводы строк — \n; иначе tostring (nil -> nil)
local function raw(v)
  if type(v) ~= "string" then return tostring(v) end
  return string.format('"%s"', (v:gsub("\n", "\\n")))
end

local function present(s) return type(s) == "string" and s:find("%S") ~= nil end

-- режим ответа по меткам сессии (riddle.rhythm) -> { mode, conditional, line, offer, labels } | nil. Контекста задач нет
-- (нет источника, сбой чтения) — nil, как до ритма. Меток нет (миграция 3 не прошла) — ритм выключен: иначе
-- пустые метки — «первая запись сессии» на каждом ответе. offer — что пометить у реплики diary: id выбранных
-- задач через пробел или "themes"; labels — метки выбранных задач (prompt.fit их из блока не режет). Сбой — nil:
-- ответ важнее ритма. В лог — только режим и счёт
function Controller:_rhythm(sid, tasks_ctx)
  if not tasks_ctx then return nil end
  local ok, r = pcall(function()
    local marks = self.deps.memory:marks(sid)
    if not marks then
      self:_log("riddle: rhythm mode=none n=-")
      return nil
    end
    local block, titles = tasks_ctx.block, tasks_ctx.titles or {}
    local has_titles = false
    for _, s in ipairs(titles) do
      if present(s) then has_titles = true break end
    end
    local mode, conditional, k = rhythm.mode(marks, block ~= nil, has_titles, self.deps.now())
    local out = { mode = mode, conditional = conditional }
    if mode == "name" then
      local picked = rhythm.pick(block.items, rhythm.offered(marks), rhythm.PICK)
      local ids, labels = {}, {}
      for i, it in ipairs(picked) do ids[i], labels[i] = it.id, it.label end
      out.offer, out.line = table.concat(ids, " "), prompt.mode_line(mode, conditional, picked)
      out.labels = labels -- prompt.fit не режет названные дела из блока
    elseif mode == "themes" then
      out.offer, out.line = "themes", prompt.mode_line(mode, conditional, titles)
    else
      out.line = prompt.mode_line(mode, conditional)
    end
    if not out.line then out.offer = nil end -- назвать нечего: и предлагать нечего
    self:_log(string.format("riddle: rhythm mode=%s n=%d", mode, k))
    return out
  end)
  if not ok then
    self:_log("riddle: rhythm failed: " .. tostring(r))
    return nil
  end
  return r
end

-- название для сверки советов (picks) с документами знания: без регистра, лишних пробелов и кавычек вокруг
local function pick_key(s)
  return tasks.fold((tasks.fold(s):gsub("[«»\"'“”„]", " ")))
end

-- пройденное в знании (ctx.knowledge разделами, у документов — название): { [pick_key] = { title, value, sec } } —
-- документы, у которых значение свойства целиком (без регистра и пробелов) — одно из values (cfg.watched_values,
-- слова данных — в конфиге, не в коде); value — как оно стоит в документе, sec — номер раздела. Вторым значением —
-- { [sec] = { название … } }: остальные документы раздела (чей статус не из values), в порядке раздела — из них
-- повтор советует выбирать. Знание текстом или его нет — nil (сверять не с чем); values пусто — тоже nil (сверка
-- выключена: правило picks не шлётся, журнала picks нет)
local function watched_titles(knowledge, values)
  if type(knowledge) ~= "table" then return nil end
  local marks, out, untouched = {}, {}, {}
  for _, v in ipairs(type(values) == "table" and values or {}) do
    if type(v) == "string" then marks[tasks.fold(v)] = true end
  end
  if next(marks) == nil then return nil end
  for si, sec in ipairs(knowledge) do
    for _, d in ipairs(sec.docs or {}) do
      if present(d.title) and type(d.text) == "string" then
        local seen
        for line in d.text:gmatch("[^\n]+") do
          local v = line:match("^[^:]+:(.*)$")
          if v and marks[tasks.fold(v)] then
            out[pick_key(d.title)] = { title = d.title, value = trimmed(v), sec = si }
            seen = true
            break
          end
        end
        if not seen then
          untouched[si] = untouched[si] or {}
          table.insert(untouched[si], d.title)
        end
      end
    end
  end
  -- одноимённый просмотренный документ — название пройдено: иначе поправка велит его не советовать и тут же предлагает
  for si, titles in pairs(untouched) do
    local kept = {}
    for _, title in ipairs(titles) do
      if not out[pick_key(title)] then kept[#kept + 1] = title end
    end
    untouched[si] = kept
  end
  return out, untouched
end

-- пройденное из picks (без повторов) -> { {title, value, sec} … }
local function watched_picks(watched, picks)
  local out, seen = {}, {}
  for _, p in ipairs(type(picks) == "table" and picks or {}) do
    local w = type(p) == "string" and watched[pick_key(p)]
    if w and not seen[w] then
      seen[w] = true
      out[#out + 1] = w
    end
  end
  return out
end

local utf8_len = str.utf8_len

-- не тронутое из разделов найденного пройденного -> "название; название …" (названия целиком, в потолок
-- prompt.RETRY_UNTOUCHED_MAX_CHARS вместе с разделителями) | nil — нечего предложить
local function untouched_list(found, untouched)
  local secs, picked = {}, {}
  for _, w in ipairs(found) do
    if not picked[w.sec] then
      picked[w.sec] = true
      secs[#secs + 1] = w.sec
    end
  end
  table.sort(secs)
  local names, used = {}, 0
  for _, si in ipairs(secs) do
    for _, title in ipairs(untouched[si] or {}) do
      local add = utf8_len(title) + (#names > 0 and 2 or 0)
      if used + add > prompt.RETRY_UNTOUCHED_MAX_CHARS then return #names > 0 and table.concat(names, "; ") or nil end
      used = used + add
      names[#names + 1] = title
    end
  end
  return #names > 0 and table.concat(names, "; ") or nil
end

-- повтор запроса по ответу (Chain:_run_retry): в picks пройденное — тот же запрос с поправкой («название» — значение
-- статуса из документа; и что в тех же разделах ещё не тронуто), иначе nil. В лог — только число
local function picks_retry(messages, watched, untouched)
  if not (watched and next(watched)) then return nil end
  return function(result)
    -- ответ с открывашкой карты не повторяется: второй годный ответ без map затёр бы её (как в _answer)
    if result.map == "open" then return nil end
    local found = watched_picks(watched, result.picks)
    if #found == 0 then return nil end
    -- пункты целиком в потолок prompt.RETRY_DONE_MAX_CHARS вместе с разделителями; первый — всегда,
    -- а длиннее потолка — обрезан по знакам с «…»
    local items, used = {}, 0
    for _, w in ipairs(found) do
      local item = string.format("«%s» — %s", w.title, w.value)
      if #items == 0 and utf8_len(item) > prompt.RETRY_DONE_MAX_CHARS then
        item = prompt.utf8_head(item, prompt.RETRY_DONE_MAX_CHARS - 1) .. "…"
      end
      local add = utf8_len(item) + (#items > 0 and 2 or 0)
      if #items > 0 and used + add > prompt.RETRY_DONE_MAX_CHARS then break end
      used = used + add
      items[#items + 1] = item
    end
    local list = untouched_list(found, untouched or {})
    local done = table.concat(items, "; ")
    local note = list and string.format(prompt.PICKS_RETRY, done, list) or string.format(prompt.PICKS_RETRY_PLAIN, done)
    return prompt.with_note(messages, note), string.format("riddle: picks watched retry n=%d", #found)
  end
end

-- PNG страницы -> base64 | nil, текст сбоя | nil (случайное касание). Файл одноразовый: удаляется при любом исходе.
-- Одно чтение для страницы дневника (_begin) и страницы на карте (map_read_job)
function Controller:_page_b64(png_path)
  local deps = self.deps
  local ok, png_b64, tiny = pcall(function()
    local bytes = deps.read_file(png_path)
    local w, h = png.size(bytes)
    if w and png.tiny(w, h) then return nil, string.format("%dx%d", w, h) end
    -- меньше 32 px Groq не принимает (400); дополняем для всех провайдеров, штрих не меняется
    local padded
    bytes, padded = png.pad(bytes, png.MIN_SIDE)
    if padded then self:_log("riddle: image padded " .. padded) end
    return deps.b64(bytes)
  end)
  -- PNG одноразовый: удаляем при любом исходе
  local rm_ok, rm_err = pcall(deps.remove, png_path)
  if not rm_ok then self:_log("riddle: remove failed: " .. tostring(rm_err)) end
  if ok and tiny then
    -- что на странице, в лог не идёт: только размеры
    self:_log("riddle: page too small " .. tiny .. " -> skipped")
    return nil, nil
  end
  if not ok then
    self:_log("riddle: on_page failed: " .. tostring(png_b64))
    return nil, self:_pick(self:texts("fail_other"))
  end
  return png_b64
end

-- страница -> job: PNG прочитан, закодирован и удалён (всегда, при любом исходе), запрос собран.
-- Случайное касание -> nil, nil: PNG удалён, запроса нет.
-- with_run: job.run для дочернего процесса (deps.remote_fn; создаётся в родителе — сдвиг ключа)
function Controller:_begin(png_path, with_run)
  local deps = self.deps
  self:_config_changed() -- строка конфига читается заново раз на страницу
  local png_b64, fail = self:_page_b64(png_path)
  if not png_b64 then return nil, fail end
  local ok
  -- персона: страница снимает паузу генерации; хранилища нет — фраза сбоя, а при закрытой печати нейтральный ответ
  -- (не Волдеморт: строка просит другого персонажа). Голосом персонажа — когда есть и персона, и мир (persona.ready); раньше страница читается без образа
  -- (prompt.setup, setup = true) и ложится в память нового персонажа
  -- Закрытая печать — тот же путь (spec §4): персона, вопрос о строке и генерация данных пользователя не читают
  local view, parts, setup, ask, row
  self.gen_hold = nil
  -- строки нет: страница — ответ на «Чей это дневник?» (читается без образа и без памяти, _ask_answer)
  if self.saved_ask and self.saved_ask.failed then self.saved_ask = nil end -- сбой чтения — перечитать
  local asking = self:_asking()
  if not asking and not deps.memory and not self:_data_ok() and not self:_builtin() then
    -- база не открылась (main.lua), а строка не «Методов»: персону взять негде. Закрытой печати она не нужна — ответ
    -- нейтральный (persona.NONE_VIEW: без персонажа, на языке записи), без данных и без записи. Открытой нужна
    -- память — она идёт в _current ниже и получает фразу сбоя
    view = persona.NONE_VIEW
  elseif not asking then
    ok, view, row, parts = pcall(self._current, self)
    if not ok then
      self:_log("riddle: on_page failed: " .. tostring(view))
      return nil, self:_pick(self:texts("fail_other"))
    end
    if not row then return nil, self:_pick(self:texts("fail_other")) end
    -- вопрос о строке ещё не показан (разбор закончился после открытия): страница — не ответ, а повод его задать
    ask = pending_ask(row)
    if ask and self.asked ~= ask then
      self.asked = ask
      return nil, ask
    end
    setup = ask ~= nil or not (view and persona.ready(row, parts))
    -- чужую память не подставлять: персоне без своей памяти — фраза сбоя
    local mine
    ok, mine = pcall(self._use_memory, self)
    if not (ok and mine) then
      if not ok then self:_log("riddle: on_page failed: " .. tostring(mine)) end
      return nil, self:_pick(self:texts("fail_other"))
    end
  end
  -- пишется ли сказанное на странице в память — решается сейчас, по печати в начале страницы: печать, сдвинувшаяся
  -- до ответа, его не меняет (_answer читает job.write)
  local write = self:_may_write()
  local job
  ok, job = pcall(function()
    if asking then
      return { mode = "setup", stage = "ask", messages = prompt.setup(png_b64, self.pending and self.pending.ask) }
    end
    if ask then
      -- ответ на вопрос о строке: запись читается вместе с ним (yes), в память не ложится
      return { mode = "setup", stage = "confirm", persona_id = row.id,
        messages = prompt.setup(png_b64, ask) }
    end
    if setup then
      -- запись во время генерации: из ответа берётся только read (_answer)
      return { mode = "setup", stage = "gen", sid = deps.memory:session(deps.now()), messages = prompt.setup(png_b64),
        write = write }
    end
    -- закрытая печать — тот же ответ без данных: их не отдаёт _open_context (spec §4)
    local data = self:_data_ok()
    if data and self.followup_due then pcall(self._sync_lore, self) end -- лор — к ответам до начала хвоста
    -- база не открылась: закрытая печать отвечает и без неё (нейтрально — NONE_VIEW выше, у «Методов» — её голосом),
    -- сессии нет; открытой нужна память
    local sid = deps.memory and deps.memory:session(deps.now())
    local t0 = deps.clock and deps.clock()
    local ctx, tasks_ctx = self:_open_context(sid, parts)
    ctx.persona = view
    local rhythm_job = self:_rhythm(sid, tasks_ctx)
    ctx.mode_line = rhythm_job and rhythm_job.line
    ctx.mode_labels = rhythm_job and rhythm_job.line and rhythm_job.labels
    -- правило picks — только если есть чем сверять (cfg.watched_values): иначе оно зря ест лимит запроса
    local watched, untouched = watched_titles(ctx.knowledge, deps.cfg.watched_values)
    ctx.picks = watched ~= nil
    -- открывашка карты: у «Методов» — всегда (мир Поттера), у сгенерированной — когда есть раздел map. Карта, как
    -- и роза (riddle_diarywidget onPageDone), открывается только при открытой печати
    local map = data and mapdata.of(view, row, parts)
    ctx.map = map and map.open and map or nil
    local messages = prompt.open(png_b64, ctx)
    if t0 then -- сборка идёт в родителе: сколько она стоит на фоне ответа (в лог — только числа)
      self:_log(string.format("riddle: prompt built in %d ms chars=%d",
        math.floor((deps.clock() - t0) * 1000 + 0.5), prompt.chars(messages)))
    end
    -- job.tasks и job.rhythm остаются в родителе (в дочерний уходят только messages): метки — в _answer.
    -- job.watched — сверка советов в _answer, job.retry — повтор (в дочернем: замыкание создано до fork)
    -- job.map: запрос спрашивал о карте — только тогда "map":"open" в ответе действие (_answer).
    -- job.persona_id — чья запись: имя из ответа ложится этой персоне, даже если строка сменилась до ответа.
    -- job.closed — запрос собран без данных: реплика идёт в связность закрытой печати (_answer).
    -- job.write — сказанное ложится в память (реплики и имя): решено по печати в начале страницы
    return { mode = "open", sid = sid, messages = messages, tasks = tasks_ctx, rhythm = rhythm_job,
      watched = watched, retry = picks_retry(messages, watched, untouched), map = ctx.map ~= nil,
      persona_id = row and row.id, closed = not data or nil, write = write }
  end)
  if ok and with_run then
    ok, job.run = pcall(deps.remote_fn, job.messages, true, job.retry and { retry = job.retry } or nil)
    if not ok then job = job.run end
  end
  if not ok then
    self:_log("riddle: on_page failed: " .. tostring(job))
    return nil, self:_pick(self:texts("fail_other"))
  end
  return job
end

-- «ничего» словами, которыми модели заполняют поле вместо пустой строки (tasks.fold): не название и не сброс
local NO_WORD = { ["нет"] = true, ["нету"] = true, ["ничего"] = true, ["пусто"] = true, ["none"] = true,
  ["null"] = true, ["nil"] = true, ["no"] = true, ["n/a"] = true, ["na"] = true, ["false"] = true,
  ["undefined"] = true, ["empty"] = true }

-- слово пишущего о книге дел (поле tasks_source, правило — prompt.TITLES_FORMAT) -> текст переспроса | nil.
-- Ключ теперь в каждом ответе, поэтому всё, что не название и не сброс, — ничего: поля нет, нет контекста задач,
-- значение без букв и цифр ("", "-", "—"), «ничего» словами (NO_WORD). "reset" в любом регистре стирает выбор.
-- Название — tasks.match_word по коллекциям контекста (равенство или целые слова): нашлась — запомнить
-- (deps.set_tasks_source; действует со следующего ответа, контекст задач читается заново); подходит к нескольким —
-- не запоминать, переспросить; ни к одной — не запоминать и не переспрашивать: от мусора модели не отличить, ответ
-- модели как есть. Сбой записи — выбор прежний, ответ модели как есть: слово можно повторить следующей записью.
-- В лог — ни названий, ни слов записи
function Controller:_tasks_source(tasks_ctx, value)
  local set = self.deps.set_tasks_source
  if type(value) ~= "string" or not tasks_ctx or not set then return nil end
  local word = tasks.fold(value)
  if not word:find("[%w\208\209]") or NO_WORD[word] then return nil end
  local id
  if word ~= "reset" then
    local c, why = tasks.match_word(tasks_ctx.collections or {}, value)
    if not c then
      self:_log("riddle: tasks source unclear (" .. tostring(why) .. ")")
      return why == "many" and self:_pick(self:texts("tasks_source_unclear")) or nil
    end
    id = c.id
  end
  local ok, done, err = pcall(set, id)
  if not (ok and done) then
    self:_log("riddle: tasks source set failed: " .. tostring(ok and err or done))
  else
    self:_log(id and "riddle: tasks source set" or "riddle: tasks source cleared")
  end
  return nil
end

-- запись, прочитанная вместе с вопросом «Так это дневник …?» (job.stage = "confirm"): «да» (result.yes) — строка
-- подтверждена, генерация пойдёт; иначе строка отвергнута, и дневник снова спрашивает «Чей это дневник?» (_config_line).
-- Нечитаемое — вопрос остаётся. Это не запись
-- в дневник: в память она не ложится, в лог — только решение
function Controller:_confirm_answer(job, result)
  if not Controller.readable(result) then return self:_pick(self:texts("unreadable")) end
  local state = result.yes and "ready" or "rejected"
  local ok, accepted = pcall(self.deps.memory.answer_persona, self.deps.memory, job.persona_id, state)
  self:_config_changed()
  if not ok then
    self:_log("riddle: persona answer failed: " .. tostring(accepted))
    return self:_pick(self:texts("fail_other"))
  end
  -- запоздалый ответ (строка уже решена другим) решением не называется
  self:_log(not accepted and "riddle: persona answer ignored"
    or result.yes and "riddle: persona confirmed" or "riddle: persona rejected")
  -- строка отвергнута, и личности нет — снова «Чей это дневник?»; иначе (подтверждена, запоздалый ответ, после отказа
  -- действует сохранённая пером) дневник пока без голоса: «загляни позже», как у записи во время генерации
  if self:_asking() then return self:_ask_open() end
  return self:_pick(self:texts("sleepy"))
end

-- ответ модели на страницу карты (map_read_job) -> nil, "map" — фраза закрытия; иначе nil: на карте не отвечают, в
-- память ничего. В лог — только решение, без текста страницы
function Controller:_map_answer(result, err)
  if not result then
    self:_log("riddle: map read failed: " .. tostring(err))
    return nil
  end
  if result.map ~= "close" or not Controller.readable(result) then return nil end
  self:_log("riddle: map phrase close")
  return nil, "map"
end

-- ответ модели (result | nil, err) -> текст для экрана | nil, действие ("map" — открыть или закрыть карту); печать,
-- память
function Controller:_answer(job, result, err)
  local deps = self.deps
  if job.mode == "map" then return self:_map_answer(result, err) end
  if not result then
    self:_log("riddle: llm failed: " .. tostring(err))
    return self:_pick(self:texts(fail_pool(err)))
  end

  if job.mode == "open" then
    -- диагностика ответа модели — только в devmode: без него в лог Kindle не идёт написанное на странице
    if deps.devmode then
      self:_log(string.format("riddle: open read %s task=%s tasks_source=%s via %s", raw(result.read),
        raw(result.task), raw(result.tasks_source), tostring(result.via or "?")))
    end
    -- открывашка карты (план карты, раздел 3 п.2): не запись — ни ответа, ни памяти, свёртка не назревает
    -- (job.answered нет), повод пересказа цел. Только если запрос спрашивал о карте (job.map)
    if job.map and result.map == "open" and Controller.readable(result) then
      self:_log("riddle: map phrase open")
      return nil, "map"
    end
    if not Controller.usable(result) then return self:_pick(self:texts("unreadable")) end
    local read = result.read
    -- советы при знании: сколько названо и сколько из них просмотрено; просмотренное после повтора (или повтор не
    -- удался) — ответ как есть, в лог («dropped») — сколько таких. В лог — только числа
    if job.watched and result.picks then
      local names = watched_picks(job.watched, result.picks)
      self:_log(string.format("riddle: picks n=%d watched=%d", #result.picks, #names))
      if #names > 0 then
        self:_log(string.format("riddle: picks watched dropped n=%d", #names))
      end
    end
    local mark, kind = task_mark(job.tasks, result.task)
    -- предложение: безусловный режим — если запись не вопрос; условный — только если запись ни к какой задаче.
    -- На вопрос напоминания нет — оно ждёт следующей записи (rhythm: "ask" не двигает счёт)
    local offer = job.rhythm and job.rhythm.offer
    if offer and (mark == "ask" or (job.rhythm.conditional and mark ~= "")) then offer = nil end
    -- переспрос о книге дел вместо ответа модели: напоминания в нём нет — и предложения нет
    local reply = self:_tasks_source(job.tasks, result.tasks_source)
    if reply then offer = nil else reply = result.reply end
    local saved = self:_remember(job, read, reply, job.tasks and { task = mark } or nil,
      offer and { offer = offer } or nil)
    -- метка не легла (миграция 3 сорвалась, сбой записи) — флаг; ритм её не увидит
    if kind then self:_log("riddle: entry task=" .. kind .. (saved and "" or " saved=no")) end
    self:_save_owner_name(job, result.name)
    -- связность закрытой печати; печать успела открыться — список уже сброшен, реплика ему не принадлежит
    if job.closed and not self:_data_ok() then add_closed_turn(self.closed_turns, read, reply) end
    job.answered = true -- реплики записаны: finish проверит, не назрела ли свёртка
    return reply
  end

  if job.mode == "setup" and job.stage == "confirm" then return self:_confirm_answer(job, result) end
  if job.mode == "setup" and job.stage == "ask" then return self:_ask_answer(job, result) end

  if job.mode == "setup" then
    -- персонаж ещё генерируется: запись — в его память, ответ — «загляни позже» (sleepy -> нейтральный later), не
    -- «ответ идёт»: ответа на эту запись не будет. Нечитаемое — не записывается. Текст записи в лог не идёт
    if not Controller.readable(result) then return self:_pick(self:texts("unreadable")) end
    local reply = self:_pick(self:texts("sleepy"))
    self:_remember(job, result.read, reply)
    job.answered = true -- реплики записаны: finish проверит, не назрела ли свёртка
    return reply
  end
end

-- печать только что открыта ключом (seal_toggle, key_page): данные снова доступны — разговор идёт из памяти,
-- хвост (лор, пересказ ждущей сессии) положен, как на старте без печати
function Controller:_opened()
  self:_log("riddle: seal opened by key")
  self.seal_epoch = self.seal_epoch + 1
  self.closed_turns = {}
  self.followup_due = true
end

-- ключ узнан (задача 6): закрытую печать открывает приветствием, открытую закрывает фразой texts.seal_closed.
-- Модель не зовётся, в память ничего. -> текст | nil: печать не сдвинулась (её нет или конфиг битый)
function Controller:seal_toggle()
  local s = self.seal
  if not s.configured then return nil end
  if s.open then
    s:lock("key")
    self.seal_epoch = self.seal_epoch + 1
    self:_log("riddle: seal closed by key")
    return texts.seal_closed
  end
  if not s:unlock(self.deps.now()) then return nil end
  self:_opened()
  local welcome = self:_pick(self:texts("welcomes"))
  -- строка ждёт ответа: вопрос идёт вместе с приветствием (страница при закрытой печати тоже задала бы его —
  -- opening_text и _begin, — но ключ открывает печать без страницы)
  local ask = self:_pending_ask()
  if ask then
    self.asked = ask
    return welcome .. " " .. ask
  end
  -- строки нет вовсе: после ключа — вопрос «Чей это дневник?» (решение 7 плана)
  if self:_asking() then return welcome .. " " .. self:_ask_open() end
  return welcome
end

-- -> текст | nil, действие (_answer); сбой разбора — фраза сбоя (на карте — ничего: там не отвечают)
function Controller:_safe_answer(job, get)
  local ok, text, action = pcall(function() return self:_answer(job, get()) end)
  if not ok then
    self:_log("riddle: on_page failed: " .. tostring(text))
    if job.mode == "map" then return nil end
    return self:_pick(self:texts("fail_other"))
  end
  return text, action
end

-- асинхронный путь (виджет + riddle.worker): begin в родителе, job.run() в дочернем,
-- finish в родителе с его payload (через deps.absorb) или ошибкой runner'а ("timeout", "crashed", …)
-- job.epoch — эпоха печати на начало страницы (finish сверяет)
function Controller:begin(png_path)
  local job, text = self:_begin(png_path, true)
  if job then job.epoch = self.seal_epoch end
  return job, text
end

-- Свёртка назрела — хвост после этого ответа (take_followup). Только здесь: свёртка идёт лишь через runner, и в
-- синхронном пути (on_page) повода для хвоста нет; страница разблокировки реплик не пишет
-- -> текст | nil, действие ("map": страница открыла карту, или страница на карте её закрыла)
-- Печать сдвинулась, пока ответ был в пути (ключ, задача 6; Review Focus 1): ответ разговора (mode "open") собран
-- при другой печати — не показывается и не пишется (nil); payload всё же уходит в цепочку (deps.absorb: логи, мёртвые
-- ключи). Задания разбора строки и карты — как всегда
function Controller:finish(job, payload, err)
  if job.mode == "open" and job.epoch ~= nil and job.epoch ~= self.seal_epoch then
    if payload ~= nil then pcall(self.deps.absorb, payload) end
    self:_log("riddle: answer dropped, seal changed")
    return nil
  end
  local text, action = self:_safe_answer(job, function()
    if payload == nil then return nil, err end
    return self.deps.absorb(payload)
  end)
  if job.answered and job.sid and self:_roll_total(job.sid) then self.roll_due = true end
  return text, action
end

-- страница на открытой карте (не роза) -> задание чтения (prompt.map_read: без образа и памяти, пустой reply не
-- «запасной») | nil: закрывашки нет (персона без раздела map — закрывает только роза), случайное касание, сбой.
-- Ответ — тот же finish (_map_answer). Есть ли связь, решает виджет: без сети задание не строится
function Controller:map_read_job(png_path)
  local map = self:map()
  if not map.close then
    pcall(self.deps.remove, png_path)
    self:_log("riddle: map read skipped (no phrase)")
    return nil
  end
  local png_b64 = self:_page_b64(png_path)
  if not png_b64 then return nil end
  local ok, job = pcall(function()
    local messages = prompt.map_read(png_b64, map)
    return { mode = "map", messages = messages, run = self.deps.remote_fn(messages, true, { reply_optional = true }) }
  end)
  if not ok then
    self:_log("riddle: map read failed: " .. tostring(job))
    return nil
  end
  return job
end

-- проба модели для страницы состояния: один короткий запрос без JSON в дочернем; ответ не читается — только дошёл ли.
-- -> { run } | nil, ошибка (цепочка не собралась в родителе). Есть ли связь, решает виджет
function Controller:probe_job()
  local ok, run = pcall(self.deps.remote_fn, { { role = "user", content = "ok" } }, false, { max_tokens = 1 })
  if not ok then return nil, tostring(run) end
  return { run = run }
end

-- итог пробы в родителе: payload дочернего (логи и мёртвые ключи — в цепочку, deps.absorb) или ошибка раннера
-- ("timeout", "crashed", "cancelled", …) -> true | nil, ошибка
function Controller:probe_finish(payload, err)
  if payload == nil then return nil, err end
  local result, rerr = self.deps.absorb(payload)
  if result == nil then return nil, rerr or "no result" end
  return true
end

-- синхронный путь (devtest, виджет без runner): begin -> llm_call -> тот же разбор ответа (текст | nil, действие);
-- случайное касание -> nil
function Controller:on_page(png_path)
  local job, text = self:_begin(png_path, false)
  if not job then return text end
  return self:_safe_answer(job, function()
    return self.deps.llm_call(job.messages, true, job.retry and { retry = job.retry } or nil)
  end)
end

-- lore.md -> лор текущей персоны: файл изменён (mtime не её) и ещё ничей — импорт. Файл, уже импортированный к
-- другому персонажу, не идёт (решение 6а плана): к новому — только изменённый
function Controller:_sync_lore()
  local deps = self.deps
  local mtime = deps.file_mtime(deps.lore_path)
  if not mtime or not self:_use_memory() then return end
  local memory = deps.memory
  if mtime ~= memory:lore_mtime() and not memory:lore_owner(mtime) then
    deps.memory:import_lore(deps.read_file(deps.lore_path), mtime)
  end
end

local SUMMARY_OPTS = { max_tokens = Controller.SUMMARY_MAX_TOKENS }
local ROLL_OPTS = { max_tokens = Controller.ROLL_MAX_TOKENS }

-- число несвёрнутых реплик сессии sid | nil: нет таблицы rollups (миграция 4), сбой памяти. Сбой — в лог: ответ
-- на страницу от свёртки не зависит
function Controller:_unrolled_total(sid)
  local ok, total = pcall(function()
    local _, n = self.deps.memory:unrolled(sid, 0)
    return n
  end)
  if not ok then
    self:_log("riddle: roll check failed: " .. tostring(total))
    return nil
  end
  return total
end

-- пауза свёртки сессии sid после неудачи: до ROLL_RETRY новых реплик сверх total
local function roll_hold(sid, total)
  return { sid = sid, at = total + Controller.ROLL_RETRY }
end

-- свёртка сессии sid назрела -> число несвёрнутых реплик | nil: не назрела, пауза после неудачи, нет таблицы, сбой
function Controller:_roll_total(sid)
  local total = self:_unrolled_total(sid)
  if not total or total < Controller.ROLL_AT then return nil end
  local hold = self.roll_hold
  if hold and hold.sid == sid and total < hold.at then return nil end
  return total
end

-- запрос свёртки сессии sid: старейшие ROLL_BATCH несвёрнутых вместе с прежним пересказом
-- -> job { kind = "roll", sid, upto, total, messages, opts, hold } | nil (не назрела); hold — пауза при неудаче
function Controller:_roll_job(sid)
  local total = self:_roll_total(sid)
  if not total then return nil end
  local memory = self.deps.memory
  local list = memory:unrolled(sid, Controller.ROLL_BATCH)
  return { kind = "roll", sid = sid, upto = list[#list].id, total = total,
    messages = prompt.roll(memory:rollup(sid), list, self:_self_view()), opts = ROLL_OPTS, hold = roll_hold(sid, total) }
end

-- запрос хвоста -> job { kind, sid, messages, opts } | nil (пересказывать нечего). Генерация персоны ("gen",
-- section, persona_id; with_gen) первой: без неё дневник не отвечает; затем пересказ прошлой сессии
-- ("session", cur — текущая сессия); его нет — свёртка текущей ("roll"), если with_roll.
-- gen_only — хвост взят ради генерации (take_followup(true)): задание только её, а отпала (пауза после сбоя, печать
-- закрыта) — nil, пересказ и свёртка ждут настоящего ответа
function Controller:_summary_job(with_roll, with_gen, gen_only)
  local gen
  if with_gen and self:gen_due() then
    local sec, row, view = self:_gen_next()
    gen = { kind = "gen", section = sec.name, persona_id = row.id, lang = view and view.lang, line = row.line,
      messages = sec.messages(row, view), opts = { max_tokens = sec.max_tokens, limits = "gen" } }
  end
  -- данные карты ответу не нужны и хвост не держат: любое готовое задание пересказа или свёртки — раньше них (и с
  -- печатью: пересказ ждущей сессии на разблокировке), карта — когда таких нет. Сбой уступившего задания (map_next)
  -- отдаёт карте следующий хвост: иначе цепочка (finish_followup -> gen_due) повторяла бы падающий пересказ без конца
  local map = gen and persona.is_map(gen.section)
  local map_yields = map and not gen_only and not self.map_next
  if gen and not map_yields then
    if map then self.map_next = nil end
    return gen
  end
  if gen_only then return nil end
  -- пересказ и свёртка отправляют память модели: при закрытой печати они ждут открытия, их поводы не гаснут
  if not self:_data_ok() then return gen end
  -- хвост дошёл до пересказа и свёртки: их поводы погашены здесь, и только здесь. Хвост, не начавшийся (закрытие,
  -- сон) или ушедший на генерацию, поводов не тратит — их возьмёт хвост следующего ответа. Повод пересказа едет в
  -- задании (followup_due): отменённый хвост возвращает его в finish_followup. Повод свёртки не едет — его заново
  -- ставит каждый ответ (finish), пока свёртка назрела
  local followup_due = self.followup_due == true
  self.followup_due, self.roll_due = false, false
  if not self:_use_memory() then return gen end -- пересказывать чужие сессии нельзя
  local memory = self.deps.memory
  local cur, sid = memory:session(self.deps.now(), SUMMARIES_N)
  if sid then
    -- свёрнутое — свёрткой, реплики — только несвёрнутый хвост; свёртки нет (или нет таблицы, сбой) — все реплики
    local ok, earlier = pcall(memory.rollup, memory, sid)
    if not ok then self:_log("riddle: roll read failed: " .. tostring(earlier)) end
    earlier = ok and earlier or nil
    local entries = earlier and memory:unrolled(sid, nil) or memory:entries(sid)
    if #entries > 0 or earlier then
      return { kind = "session", sid = sid, cur = cur, followup_due = followup_due, before_map = map_yields,
        messages = prompt.summarize(entries, earlier, self:_self_view()),
        opts = SUMMARY_OPTS }
    end
    memory:set_summary(sid, "") -- пустая сессия: пометить, чтобы не возвращаться
  end
  local job = with_roll and self:_roll_job(cur)
  if not job then return gen end
  job.followup_due, job.before_map = followup_due, map_yields
  return job
end

-- пустой или неудачный пересказ не сохраняется: сессия останется без пересказа и спросится снова.
-- Свёртка — одной строкой в потолок, в свою сессию (job.sid: сессия могла смениться, пока она была в пути);
-- запоздалая (upto не больше сохранённого) не пишется. В лог — только числа
function Controller:_save_summary(job, result)
  local text = result and result.text
  if job.kind == "gen" and job.section == persona.RESOLVE.name then
    -- разбор строки: итог ложится в строку personas одной командой, только у новой строки (повтор безопасен)
    local r, err = persona.decode_resolve(text, job.line)
    if not r then error(err, 0) end
    self.deps.memory:resolve_persona(job.persona_id, r)
    self:_config_changed()
    self:_log("riddle: gen resolve saved " .. r.state)
    return
  end
  if job.kind == "gen" then
    -- раздел персоны — одной командой (повтор даёт то же); негодный ответ — неудача, раздел не пишется
    local part, err = persona.section(job.section).decode(text, job.lang)
    if not part then error(err, 0) end
    self.deps.memory:set_part(job.persona_id, job.section, part, self.deps.now())
    self:_log("riddle: gen " .. job.section .. " saved")
    return
  end
  if job.kind == "roll" then
    self.roll_hold = nil
    text = prompt.roll_text(text)
    -- пустой ответ — неудача (finish_followup ставит паузу), как таймаут и отказ модели
    if text == "" then error("roll empty", 0) end
    if self.deps.memory:set_rollup(job.sid, text, job.upto, self.deps.now()) then
      self:_log(string.format("riddle: roll saved upto=%d chars=%d", job.upto, utf8_len(text)))
    end
    return
  end
  if text and text ~= "" then
    self.deps.memory:set_summary(job.sid, text)
  end
end

function Controller:_followup_lore()
  if not self:_data_ok() then return end -- лор — данные пользователя: ждёт открытия
  local ok, err = pcall(self._sync_lore, self)
  if not ok then self:_log("riddle: lore sync failed: " .. tostring(err)) end
end

-- после показа приветствия: лор и пересказ прошлой сессии; любой сбой — молча.
-- Синхронный путь (виджет без runner): цикл интерфейса ждёт пересказ до BUDGET_S; свёртки и генерации персоны
-- здесь нет — иначе он ждал бы свёртку каждые ROLL_BATCH / 2 страниц, а генерацию — до минуты
function Controller:on_unlocked_followup()
  self:_followup_lore()
  local ok, err = pcall(function()
    local job = self:_summary_job(false, false)
    if job then self:_save_summary(job, self.deps.llm_call(job.messages, false, job.opts)) end
  end)
  if not ok then self:_log("riddle: summary failed: " .. tostring(err)) end
end

-- асинхронный путь (виджет + riddle.worker): лор и запрос — в родителе, job.run() — в дочернем,
-- finish_followup — в родителе с его payload или ошибкой runner'а. -> job | nil (пересказывать нечего).
-- Хвост, поднятый одной свёрткой (roll_tail): сбой и пересказа прошлой сессии ставит паузу свёртки текущей — иначе
-- стабильно падающий пересказ тратил бы вызов на каждой странице, а свёртка не наступала бы никогда
function Controller:begin_followup()
  self:_followup_lore()
  local roll_tail, gen_only = self.roll_tail, self.tail == "gen"
  self.roll_tail, self.tail = false, false
  local ok, job = pcall(function()
    local job = self:_summary_job(true, true, gen_only)
    if job then
      if roll_tail and job.kind == "session" then
        local total = self:_unrolled_total(job.cur)
        job.hold = total and roll_hold(job.cur, total)
      end
      job.run = self.deps.remote_fn(job.messages, false, job.opts)
    end
    return job
  end)
  if not ok then
    self:_log("riddle: summary failed: " .. tostring(job))
    return nil
  end
  -- идущий хвост — здесь, и только здесь: контроллер, как и runner, живёт весь процесс KOReader, виджет — до
  -- закрытия. Снимает finish_followup
  self.followup_job = job
  return job
end

-- виджет убил идущий хвост (перо, сон; Runner:cancel его on_done не зовёт): итог хвоста — отмена. Хвоста нет (не
-- начат, уже с итогом) — ничего
function Controller:cancel_followup()
  local job = self.followup_job
  if job then self:finish_followup(job, nil, "cancelled") end
end

-- таймаут, вытеснение ответом, ошибка модели — пересказ не сохраняется (повторится в следующий раз).
-- Задание с паузой (job.hold: свёртка; пересказ в хвосте, поднятом свёрткой) после неудачи (и пустой свёртки),
-- кроме отмены (перо, сон, вытеснение), ставит паузу свёртки: ROLL_RETRY новых реплик, иначе при суточном 429
-- каждый ответ тратил бы второй вызов. Пауза — только в памяти процесса.
-- Генерация персоны: сбой (кроме отмены) — пауза генерации до следующей страницы (_begin), иначе стабильно
-- падающая генерация занимала бы runner хвост за хвостом. Сбой раздела карты — пауза до следующего открытия или сна
-- (map_hold).
-- -> true: генерация ещё нужна — виджет ставит следующий хвост
function Controller:finish_followup(job, payload, err)
  if self.followup_job == job then self.followup_job = nil end
  local ok, e = pcall(function()
    if payload == nil then error(err, 0) end
    local result, rerr = self.deps.absorb(payload)
    if not result then error(rerr, 0) end
    self:_save_summary(job, result)
  end)
  if not ok then
    if job.kind == "gen" then
      self:_log("riddle: gen " .. job.section .. " failed (" .. tostring(e) .. ")")
      -- раздел карты — одна попытка за открытие: стабильный сбой не тратит вызов на каждой странице
      if e ~= "cancelled" then
        if persona.is_map(job.section) then self.map_hold = true else self.gen_hold = true end
      end
    else
      self:_log("riddle: summary failed: " .. tostring(e))
    end
    if job.hold and e ~= "cancelled" then self.roll_hold = job.hold end
    -- начатый хвост отменён до итога (ответ вытеснил его, в том числе после закрытия и открытия дневника; перо и
    -- сон убили его — cancel_followup): повод пересказа — хвосту следующего ответа, иначе пересказ
    -- прошлой сессии ждал бы сна. Сбой (таймаут, сеть, модель) повода не возвращает: стабильно падающий вызов шёл бы
    -- на каждой странице, мимо паузы свёртки
    if job.followup_due and e == "cancelled" then self.followup_due = true end
  end
  -- карта уступила этому заданию: следующий хвост цепочки — ей, каков бы ни был итог (кроме отмены). Иначе
  -- пересказ, который не сохраняется (сбой, пустой ответ), строился бы цепочкой снова и снова. Флаг — только если
  -- следующий хвост и правда карта и данные доступны: печать закрыта (сон посреди хвоста) — пересказ ждёт открытия,
  -- и лежащий флаг отдал бы карте хвост раньше пересказа на разблокировке; пауза карты (map_hold) — следовать некому
  local due = self:_gen_due_section()
  if job.before_map and self:_data_ok() and (ok or e ~= "cancelled") and due and persona.is_map(due.name) then
    self.map_next = true
  end
  return due ~= nil
end

-- хвост после ответа: true — повод есть. Печати нет — после первого ответа после старта и после каждого сна (лор,
-- пересказ прошлой сессии); и с печатью, и без — когда назрела свёртка (только путь через runner, см. finish) и пока
-- нужна генерация персоны. Флаги пересказа и свёртки взятие не гасит — их гасит начало хвоста (_summary_job), поэтому
-- до него каждый ответ берёт хвост снова (виджет переставляет таймер). roll_tail — хвост поднят одной свёрткой (для
-- begin_followup и метки лога виджета)
-- gen_only — страница без задания (фраза сбоя, «думаю» до готовности персоны): хвост берётся только ради генерации
-- персоны, пересказ и свёртка ждут настоящего ответа
function Controller:take_followup(gen_only)
  -- tail — вид взятого, ещё не начатого хвоста: "full" — обычный (пересказ, свёртка, генерация), "gen" — ради
  -- генерации (begin_followup строит только её задание, если она к тому времени ещё нужна), false — нет.
  -- Страница без задания поднимает до "gen" только не взятый обычным хвост. Обычный ответ без хвоста опускает "gen",
  -- ждущий "full" остаётся. Гасят вид begin_followup, закрытие и сон; синхронный путь (on_unlocked_followup) его не
  -- читает и не гасит — "full" живёт там до закрытия или сна
  if gen_only then
    local due = self:_gen_tail_due()
    if due and self.tail ~= "full" then self.tail = "gen" end
    return due
  end
  local data = self:_data_ok()
  local followup = data and self.followup_due == true
  local roll = data and self.roll_due == true
  local gen = self:_gen_tail_due()
  self.roll_tail = roll and not followup and not gen
  local taken = followup or roll or gen
  if taken then
    self.tail = "full"
  elseif self.tail == "gen" then
    self.tail = false
  end
  return taken
end

-- дневник закрыт: таймер ждущего хвоста упал вместе с виджетом (onCloseWidget), хвост не начнётся — гаснут его вид
-- и метка свёртки (как во сне); флаги пересказа и свёртки остаются хвосту следующего ответа
function Controller:on_close()
  self.key_first = nil -- задание ключа, прерванное закрытием, начинается заново
  self.tail, self.roll_tail = false, false
  self.map_hold, self.map_next = nil, nil -- следующее открытие — новая попытка данных карты, пересказ раньше неё
end

function Controller:on_sleep()
  self.key_first = nil -- задание ключа, прерванное сном, начинается заново (Review Focus 4)
  self.map_hold, self.map_next = nil, nil -- после сна — новая попытка данных карты, пересказ раньше неё
  self.roll_tail = false -- хвост свёртки, не начатый до сна, — не повод для паузы у хвоста после него
  self.tail = false -- и хвост, не начатый до сна: после него хвост берётся заново
  if self.seal:closes_on_sleep() then self.seal:lock("sleep") end
  -- после сна хвост берётся заново, если данные доступны (печати нет или сон её не закрыл); закрытая — откроет ключ
  if self:_data_ok() then self.followup_due = true end
end

return Controller
