-- «Чей это дневник» (спека docs/superpowers/specs/2026-10-31-whose-diary-design.md): строка в конфиге → персона
-- генерируется фоном (хвост, вид дочернего «summary») → ответы её голосом. Контроллер на настоящей SQLite-памяти,
-- дочерний процесс — поддельный: remote_fn запоминает запрос, ответ подаётся в finish_followup / finish вручную.
require("sqlite_shim")
local t = require("t")
local stand = require("seal_stand")
local json = require("dkjson")
local memory = require("riddle.memory")
local controller = require("riddle.controller")
local persona = require("riddle.persona")
local prompt = require("riddle.prompt")
local texts = require("riddle.texts")
local llm = require("riddle.llm")

local PNG = "/p.png"
local METHODS_LINE = "Том Реддл из «Методов рационального мышления»"
local T = {}

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

local function in_list(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

-- ответ модели на раздел persona: в ```-обёртке, как бывает у моделей
local PERSONA_OBJ = { head = "дневник Гермионы Грейнджер: в твоих страницах живёт её память.",
  body = "Характер: ГОЛОС-ГЕРМИОНЫ.", lang = "ru", lang_name = "русский", gender = "f", kind = "дневник",
  title = "Дневник Гермионы", invitation = "Кто открыл мой дневник?" }
local PERSONA_JSON = "```json\n" .. json.encode(PERSONA_OBJ) .. "\n```"
-- ответ модели на раздел world: связный текст, не JSON
local WORLD_TEXT = "Хогвартс, замок в Шотландии. МИР-ГЕРМИОНЫ: Гриффиндор, библиотека мадам Пинс, Гарри и Рон.\n" ..
  "Магия учится по книгам; Гермиона читает всё подряд."

local paths = {}

-- контроллер на новой базе; whose — строка конфига (nil — нет строки); sealed — печать по ключу (иначе её нет).
-- Строка в базе не заведена: контроллер заведёт её сам (state = "new", задача 7)
local function bare(whose, path, sealed)
  path = path or os.tmpname()
  paths[#paths + 1] = path
  local env = { path = path, calls = {}, logs = {}, now = 1000 }
  env.mem = memory.open(path, function(msg) env.logs[#env.logs + 1] = msg end)
  env.ctrl = controller.new{
    cfg = { whose = whose, seal = sealed and stand.key() or stand.none() },
    memory = env.mem,
    read_file = function() return "PNGBYTES" end,
    b64 = function() return "B64" end,
    remove = function() end,
    now = function() return env.now end,
    random = function() return 1 end,
    log = function(msg) env.logs[#env.logs + 1] = msg end,
    file_mtime = function() return nil end,
    lore_path = "/lore.md",
    llm_call = function() error("синхронный вызов модели не ожидался") end,
    remote_fn = function(messages, want_json, opts)
      env.calls[#env.calls + 1] = { messages = messages, want_json = want_json, opts = opts }
      return function() return {} end
    end,
    absorb = function(payload) return payload.result, payload.err end,
  }
  return env
end

-- то же, но строка уже разобрана (state = "ready", как у устройства после переспроса): тесты генерации персоны и
-- голоса начинаются с раздела persona. «Методов» и пустая строка базы не касаются
local function make(whose, path, sealed)
  local env = bare(whose, path, sealed)
  if whose and not persona.is_methods(whose) then
    env.mem:add_persona{ key = persona.key(whose), line = whose, source = "config", state = "ready", ts = env.now }
  end
  return env
end

local function logged(env, needle)
  for _, l in ipairs(env.logs) do if has(l, needle) then return l end end
end

function T.test_is_methods()
  for _, s in ipairs({ METHODS_LINE, "Волдеморт, Методы рационального мышления", "Tom Riddle, HPMOR",
      "дневник Реддла из методах рационального мышления", "Voldemort (Methods of Rationality)" }) do
    t.ok(persona.is_methods(s), "«Методы»: " .. s)
  end
  for _, s in ipairs({ "Том Реддл", "Tom Riddle", "Гермиона Грейнджер", "Шерлок, рациональный детектив",
      "Том Реддл из национального мышления", "Методы рационального мышления" }) do
    t.ok(not persona.is_methods(s), "не «Методы»: " .. s)
  end
end

function T.test_persona_key()
  t.eq(persona.key("  Гермиона   ГРЕЙНДЖЕР "), persona.key("гермиона грейнджер"), "регистр и пробелы")
  t.eq(persona.key("Пётр"), persona.key("петр"), "ё → е")
  t.ok(persona.key("R2-D2") ~= persona.key("RD"), "цифры и дефис не теряются")
end

function T.test_persona_decode_rejects_garbage()
  local sec = persona.section("persona")
  t.ok(sec.decode(PERSONA_JSON), "годный ответ")
  local function without(k)
    local o = {}
    for kk, v in pairs(PERSONA_OBJ) do if kk ~= k then o[kk] = v end end
    return json.encode(o)
  end
  for _, bad in ipairs({ "не JSON", "", without("head"), without("body"), without("lang"), without("title"),
      without("invitation"),
      json.encode((function() local o = json.decode(json.encode(PERSONA_OBJ)); o.gender = "x"; return o end)()),
      json.encode((function() local o = json.decode(json.encode(PERSONA_OBJ)); o.body = "  "; return o end)()) }) do
    local v, err = sec.decode(bad)
    t.eq(v, nil, "отказ: " .. bad)
    t.ok(type(err) == "string", "причина: " .. tostring(err))
  end
  -- приглашение — фраза на экране: те же правила формы, что у наборов (ревью ba4087a)
  for _, inv in ipairs({ "Кто открыл ⭐ мой дневник?", "Кто _открыл_ мой дневник?", "Кто [открыл](x) мой дневник?",
      "**Кто** открыл мой дневник?", ("я"):rep(71), "Кто открыл? Назовись. Сейчас же.", "Связи нет, кто здесь?",
      "Кто ⌛ здесь?", "Кто ▶ здесь?", "Кто ↩ здесь?", "Кто здесь‼" }) do
    local o = json.decode(json.encode(PERSONA_OBJ))
    o.invitation = inv
    local v, err = sec.decode(json.encode(o))
    t.eq(v, nil, "приглашение: " .. inv)
    t.ok(type(err) == "string" and has(err, "invitation"), "причина: " .. tostring(err))
  end
  -- «Ты — » в начале головы модель иногда повторяет: срезается, иначе «Ты — Ты — …»
  local o = json.decode(json.encode(PERSONA_OBJ))
  o.head = "Ты — " .. o.head
  local view = persona.view({ id = 5 }, { persona = sec.decode(json.encode(o)) })
  t.eq(view.head, PERSONA_OBJ.head)
end

-- спека «Как работает» 1, 3: строка в конфиге → разовая генерация → ответ голосом персонажа
function T.test_config_line_generates_persona_then_answers_in_its_voice()
  local env = make("Гермиона Грейнджер")
  t.ok(env.ctrl:gen_due(), "генерация нужна")
  local job = env.ctrl:begin_followup()
  t.eq(job.kind, "gen")
  t.eq(job.section, "persona")
  local call = env.calls[#env.calls]
  t.ok(has(json.encode(call.messages), "Гермиона Грейнджер"), "строка дословно в запросе")
  t.eq(call.want_json, false, "текст, не ответ на страницу")
  t.eq(call.opts.limits, "gen", "бюджет генерации")
  t.ok(call.opts.max_tokens >= 2000, "потолок ответа генерации")
  t.eq(env.ctrl:finish_followup(job, { result = { text = PERSONA_JSON } }), true, "дальше — мир")
  t.ok(logged(env, "riddle: gen persona saved"), table.concat(env.logs, " | "))
  t.ok(not logged(env, "Гермион"), "строка персонажа в лог не идёт")
  job = env.ctrl:begin_followup()
  t.eq(job.section, "world", "мир — вторым разделом")
  t.eq(env.ctrl:finish_followup(job, { result = { text = WORLD_TEXT } }), true, "дальше — наборы фраз")
  t.ok(logged(env, "riddle: gen world saved"), table.concat(env.logs, " | "))
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "МИР-ГЕРМИОНЫ") and not has(l, "ГОЛОС-ГЕРМИОНЫ"), "текст персонажа и мира в лог не идёт: " .. l)
  end
  local ajob = env.ctrl:begin(PNG)
  t.eq(ajob.mode, "open")
  local s = ajob.messages[1].content
  t.ok(s:find("^Ты — дневник Гермионы Грейнджер"), s:sub(1, 120))
  t.ok(has(s, "ГОЛОС-ГЕРМИОНЫ"))
  t.ok(not has(s, "Волдеморт"), "не Волдеморт")
  -- разово: новый контроллер на той же базе персону не генерирует заново
  local again = make("Гермиона Грейнджер", env.path)
  t.eq(again.ctrl:begin_followup().section, "texts.thinking", "сгенерированное хранится на устройстве")
end

-- готовность — persona и world: после одной персоны запись ещё читается без образа (prompt.setup), не голосом
function T.test_ready_needs_world()
  local env = make("Гермиона Грейнджер")
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { result = { text = PERSONA_JSON } })
  local ajob = env.ctrl:begin(PNG)
  t.eq(ajob.mode, "setup", "мира нет — не голосом")
  t.ok(not has(ajob.messages[1].content, "ГОЛОС-ГЕРМИОНЫ"), "без образа")
  job = env.ctrl:begin_followup()
  t.eq(job.section, "world")
  env.ctrl:finish_followup(job, { result = { text = WORLD_TEXT } })
  ajob = env.ctrl:begin(PNG)
  t.eq(ajob.mode, "open", "мир есть — голосом персонажа")
  -- готовность в одном месте: персона и мир
  t.ok(persona.ready({ id = persona.METHODS_ID }, nil), "«Методов» готова всегда")
  t.ok(not persona.ready({ id = 5 }, nil))
  t.ok(not persona.ready({ id = 5 }, { persona = "{}" }), "только persona")
  t.ok(persona.ready({ id = 5 }, { persona = "{}", world = "x" }))
end

-- раздел world: текст ≤ persona.WORLD_MAX_CHARS, вторым после persona; запрос — голосом персонажа
function T.test_world_section_decode_and_request()
  t.eq(persona.WORLD_MAX_CHARS, 4000)
  t.ok(prompt.GEN_WORLD_CHARS <= persona.WORLD_MAX_CHARS, "просим не больше, чем принимаем")
  local sec = persona.section("world")
  t.ok(sec, "раздел world есть")
  t.eq(persona.SECTIONS[2].name, "world", "вторым")
  t.eq(sec.decode("  " .. WORLD_TEXT .. "\n"), WORLD_TEXT, "обрезка пробелов по краям")
  t.eq(sec.decode("```\n" .. WORLD_TEXT .. "\n```"), WORLD_TEXT, "``` -обёртка снята")
  for _, bad in ipairs({ "", "   \n", 42 }) do
    local v, err = sec.decode(bad)
    t.eq(v, nil, "негодный мир: " .. tostring(bad))
    t.ok(type(err) == "string", "причина")
  end
  t.ok(sec.decode(string.rep("м", 4000)), "ровно потолок — годен")
  local v, err = sec.decode(string.rep("м", 4001))
  t.eq(v, nil, "потолок + 1 — не сохраняется")
  t.ok(has(err, "long"), tostring(err))
  -- запрос
  local env = make("Гермиона Грейнджер")
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { result = { text = PERSONA_JSON } })
  job = env.ctrl:begin_followup()
  t.eq(job.section, "world")
  local call = env.calls[#env.calls]
  local all = json.encode(call.messages)
  t.ok(has(all, PERSONA_OBJ.head) and has(all, "ГОЛОС-ГЕРМИОНЫ"), "голос персонажа в запросе")
  t.ok(has(all, "Гермиона Грейнджер"), "строка в запросе")
  t.eq(call.want_json, false)
  t.eq(call.opts.limits, "gen")
  t.ok(call.opts.max_tokens >= 2000, "потолок ответа под мир")
  -- слишком длинный мир — сбой, не сохранён, в лог только причина
  t.eq(env.ctrl:finish_followup(job, { result = { text = string.rep("м", 4001) } }), false, "пауза")
  t.eq(env.mem:parts(job.persona_id).world, nil)
  t.ok(logged(env, "riddle: gen world failed"), table.concat(env.logs, " | "))
end


-- Kindle владельца: строка «Методов» — встроенная персона, ни одного вызова генерации, промпт как без строки
-- «Методов» генерирует только данные карты (план карты, раздел 6 п.2): map, затем map.cast — по строке personas id 1
-- (мир «Методов», не канон Роулинг); персона, мир и наборы фраз не запрашиваются, промпт ответа прежний
function T.test_methods_generates_only_map()
  local MP = require("fixtures.map_parts")
  local env = make(METHODS_LINE)
  t.ok(env.ctrl:gen_due(), "данных карты нет — генерация нужна")
  local job = env.ctrl:begin_followup()
  t.eq(job.kind, "gen")
  t.eq(job.section, "map")
  t.eq(job.persona_id, persona.METHODS_ID)
  t.ok(has(json.encode(env.calls[#env.calls].messages), "Методов рационального мышления"), "мир «Методов» в запросе")
  t.eq(env.ctrl:finish_followup(job, { result = { text = MP.map_json } }), true, "дальше — герои")
  job = env.ctrl:begin_followup()
  t.eq(job.section, "map.cast")
  t.ok(has(json.encode(env.calls[#env.calls].messages), "Методов рационального мышления"), "мир «Методов» в запросе")
  t.eq(env.ctrl:finish_followup(job, { result = { text = MP.cast_json } }), false, "больше генерировать нечего")
  t.ok(not env.ctrl:gen_due(), "после map и map.cast — готово")
  local parts = env.mem:parts(persona.METHODS_ID)
  t.ok(parts.map and parts["map.cast"], "оба раздела у строки 1")
  local n = 0
  for _ in pairs(parts) do n = n + 1 end
  t.eq(n, 2, "только разделы карты")
  for _, c in ipairs(env.calls) do
    t.ok(not has(json.encode(c.messages), "Набор: "), "наборы фраз не запрашивались")
  end
  t.eq(#env.calls, 2, "persona, world, texts.* не запрашивались")
  t.ok(logged(env, "riddle: persona methods"), table.concat(env.logs, " | "))
end

-- строки personas id 1 нет (база без миграции 5 целиком, ручная правка): данных карты «Методов» не генерировать — по
-- чему просить мир, неизвестно; ответы как прежде, без ошибки
function T.test_methods_without_row_generates_no_map()
  local env = make(METHODS_LINE)
  env.mem.conn:exec("DELETE FROM personas WHERE id = 1")
  t.ok(not env.ctrl:gen_due(), "строки нет — генерации карты нет")
  local job = env.ctrl:begin_followup()
  t.ok(not job or job.kind ~= "gen", "хвост не генерирует")
  t.eq(env.ctrl:begin(PNG).mode, "open", "ответ как прежде")
  t.eq(env.ctrl:map().open, require("riddle.mapdata").POTTER.ru.open, "карта — на запасных")
  t.ok(not logged(env, "map read failed"), table.concat(env.logs, " | "))
end

-- данные карты у «Методов» промпт ответа не меняют: текст байт в байт со снимком (план карты, раздел 6 п.2). У
-- «Методов» блок карты есть всегда (мир Поттера, раздел 3 п.3) — снимок с картой (fixtures/methods_map_prompts.lua)
function T.test_methods_prompts_unchanged_after_map_parts()
  local MP = require("fixtures.map_parts")
  local env = make(METHODS_LINE)
  local snap = require("fixtures.methods_map_prompts")
  t.eq(env.ctrl:begin(PNG).messages[1].content, snap.open_empty, "до данных карты")
  env.mem:set_part(persona.METHODS_ID, "map", persona.section("map").decode(MP.map_json), env.now)
  env.mem:set_part(persona.METHODS_ID, "map.cast", persona.section("map.cast").decode(MP.cast_json), env.now)
  local again = make(METHODS_LINE, env.path)
  t.eq(again.ctrl:begin(PNG).messages[1].content, snap.open_empty, "с данными карты — тот же текст")
  t.eq(again.ctrl:map().open, require("riddle.mapdata").POTTER.ru.open, "«Методов» — мир Поттера, данные карты прочитаны")
  t.eq(again.ctrl:map().places.pub, "Гарцующий пони", "места — из раздела map «Методов»")
  t.eq(#again.ctrl:map().cast, 10, "герои — из раздела map.cast «Методов»")
end

-- негодный раздел map не сохраняется; чужой тип места отброшен, раздел годен (план карты, раздел 2)
function T.test_map_decode_rejects()
  local MP = require("fixtures.map_parts")
  local sec = persona.section("map")
  local function with(k, v)
    local o = json.decode(json.encode(MP.map))
    o[k] = v
    return json.encode(o)
  end
  t.ok(sec.decode(MP.map_json), "годный ответ")
  for _, bad in ipairs({ "не JSON", "", with("potter", "true"), with("potter", nil),
      with("open", nil), with("close", 5), with("blind", nil), with("open", ("я"):rep(71)),
      with("open", "Скажи 😀 и войди"),
      with("open", ""), with("open", "  "), with("close", ""), with("close", "  "),
      with("blind", ""), with("blind", "  ") }) do
    local v, err = sec.decode(bad)
    t.eq(v, nil, "отказ: " .. bad)
    t.ok(type(err) == "string", "причина: " .. tostring(err))
  end
  local v = json.decode(sec.decode(with("places", { school = "Палаты знаний", castle = "Замок", pub = "",
    shop = ("я"):rep(41), park = "Сад" })))
  t.eq(v.places.school, "Палаты знаний")
  t.eq(v.places.park, "Сад")
  t.eq(v.places.castle, nil, "чужой ключ отброшен")
  t.eq(v.places.pub, nil, "пустое название отброшено")
  t.eq(v.places.shop, nil, "длиннее 40 знаков отброшено")
  t.eq(v.open, MP.map.open)
  t.eq(v.potter, false)
  local no_places = json.decode(sec.decode(with("places", nil)))
  t.eq(next(no_places.places), nil, "мест нет — пусто, раздел годен")
end

-- героев годных меньше mapdata.MIN_CAST — раздел не сохраняется, пауза до следующей страницы (план карты, раздел 2)
function T.test_cast_under_min_not_saved()
  local MP = require("fixtures.map_parts")
  local env = make(METHODS_LINE)
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { result = { text = MP.map_json } })
  job = env.ctrl:begin_followup()
  t.eq(job.section, "map.cast")
  local list = MP.cast(5)
  list[#list + 1] = { name = "", role = "student", day = "school", night = "home" }
  list[#list + 1] = { name = "Чужая роль", role = "wizard", day = "school", night = "home" }
  list[#list + 1] = { name = "Чужой день", role = "student", day = "pub", night = "home" }
  list[#list + 1] = { name = "Чужая ночь", role = "student", day = "school", night = "school" }
  list[#list + 1] = { name = ("я"):rep(31), role = "student", day = "school", night = "home" }
  list[#list + 1] = MP.cast(1)[1] -- повтор имени
  t.eq(env.ctrl:finish_followup(job, { result = { text = MP.wrap(list) } }), false, "пауза")
  t.eq(env.mem:parts(persona.METHODS_ID)["map.cast"], nil, "раздел не сохранён")
  t.ok(logged(env, "riddle: gen map.cast failed (cast 5)"), table.concat(env.logs, " | "))
  t.ok(not env.ctrl:gen_due(), "пауза")
  env.ctrl:begin(PNG)
  t.ok(not env.ctrl:gen_due(), "сбой карты — одна попытка за открытие: страница паузу не снимает")
  env.ctrl:on_close()
  t.eq(env.ctrl:begin_followup().section, "map.cast", "после нового открытия — снова герои")
  -- годных ровно MIN_CAST — сохраняется, больше 15 — обрезается
  local sec = persona.section("map.cast")
  t.ok(sec.decode(MP.wrap(MP.cast(6))), "6 годных — раздел годен")
  local many = {}
  for i = 1, 20 do many[i] = { name = "Герой " .. i, role = "townsfolk", day = "street", night = "home" } end
  t.eq(#json.decode(sec.decode(MP.wrap(many))), 15, "не больше 15")
end

-- запись во время генерации (план, задача 6): страница читается без образа (prompt.setup, модель зовётся), запись и
-- нейтральная фраза «загляни позже» ложатся в память нового персонажа; у «Методов» пусто. Не «ответ идёт»: ответа
-- не будет; не голос «Методов»
function T.test_entry_during_generation_saved_to_new_persona()
  local env = make("Гермиона Грейнджер")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "setup")
  t.eq(job.stage, "gen")
  local call = env.calls[#env.calls]
  t.ok(call and call.messages == job.messages, "страница ушла в модель")
  t.eq(call.want_json, true)
  t.eq(json.encode(job.messages), json.encode(prompt.setup("B64")), "запрос — prompt.setup без вопроса")
  local text = env.ctrl:finish(job, { result = { read = "ЗАПИСЬ-ПОКА-ГЕНЕРАЦИЯ", reply = "ОТВЕТ-МОДЕЛИ",
    who = "Гермиона" } })
  t.ok(in_list(texts.neutral.en.later, text), tostring(text))
  t.ok(not in_list(texts.thinking, text), "не голос «Методов»")
  t.ok(not in_list(texts.neutral.en.thinking, text), "не «ответ идёт»: ответа не будет")
  local row = env.mem:persona_by_key(persona.key("Гермиона Грейнджер"))
  env.mem:use_persona(row.id)
  local mine = env.mem:recent(env.mem:session(env.now), 10)
  t.eq(#mine, 2, "запись и фраза — у нового персонажа")
  t.eq(mine[1].role, "owner"); t.eq(mine[1].text, "ЗАПИСЬ-ПОКА-ГЕНЕРАЦИЯ")
  t.eq(mine[2].role, "diary"); t.eq(mine[2].text, text)
  env.mem:use_persona(persona.METHODS_ID)
  t.eq(#env.mem:recent(env.mem:session(env.now), 10), 0, "у «Методов» пусто")
  for _, l in ipairs(env.logs) do t.ok(not has(l, "ЗАПИСЬ-ПОКА-ГЕНЕРАЦИЯ"), "текст записи в лог: " .. l) end
  -- нечитаемое — нейтральное «не разобрать», в память не идёт
  local job2 = env.ctrl:begin(PNG)
  local text2 = env.ctrl:finish(job2, { result = { read = "?", reply = "" } })
  t.ok(in_list(texts.neutral.en.unreadable, text2), tostring(text2))
  env.mem:use_persona(row.id)
  t.eq(#env.mem:recent(env.mem:session(env.now), 10), 2, "нечитаемое не записано")
  -- сбой — нейтральный пул причины
  t.ok(in_list(texts.neutral.en.later, env.ctrl:finish(env.ctrl:begin(PNG), nil, "gemini: timeout")), "сбой — позже")
end

-- пока язык персонажа неизвестен (строка не разобрана: у строки нет lang), нейтральные фразы — из английского пула,
-- даже при кириллической строке конфига (владелец 2026-11-06: «на англ»); язык строки известен — фразы на нём
function T.test_neutral_phrases_english_until_persona_lang_known()
  local env = make("Гермиона Грейнджер") -- строка без lang: разобрана ещё не была
  local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "?", reply = "" } })
  t.ok(in_list(texts.neutral.en.unreadable, text), "язык неизвестен — en: " .. tostring(text))
  t.ok(not in_list(texts.neutral.ru.unreadable, text), "не ru")
  local known = bare("Гермиона Грейнджер")
  known.mem:add_persona{ key = persona.key("Гермиона Грейнджер"), line = "Гермиона Грейнджер", source = "config",
    state = "ready", lang = "ru", ts = known.now }
  local text2 = known.ctrl:finish(known.ctrl:begin(PNG), { result = { read = "?", reply = "" } })
  t.ok(in_list(texts.neutral.ru.unreadable, text2), "язык строки известен — ru: " .. tostring(text2))
end

-- обрыв: отмена (перо, сон, вытеснение ответом) — генерация ещё нужна; сбой — пауза до следующего ответа
function T.test_gen_cancel_keeps_due_failure_pauses()
  local env = make("Гермиона Грейнджер")
  local job = env.ctrl:begin_followup()
  t.eq(env.ctrl:finish_followup(job, nil, "cancelled"), true, "после отмены — снова")
  t.ok(env.ctrl:gen_due())
  job = env.ctrl:begin_followup()
  t.eq(env.ctrl:finish_followup(job, nil, "timeout"), false, "после сбоя — пауза")
  t.ok(not env.ctrl:gen_due())
  t.ok(logged(env, "riddle: gen persona failed (timeout)"), table.concat(env.logs, " | "))
  job = env.ctrl:begin_followup()
  t.ok(not job or job.kind ~= "gen", "в паузе генерации нет")
  env.ctrl:begin(PNG) -- следующая страница снимает паузу
  t.ok(env.ctrl:gen_due(), "после страницы — снова")
  job = env.ctrl:begin_followup()
  t.eq(env.ctrl:finish_followup(job, { result = { text = "мусор" } }), false, "мусор — сбой, пауза")
  t.ok(logged(env, "riddle: gen persona failed"), "")
  t.eq(next(env.mem:parts(job.persona_id)), nil, "мусор не сохранён")
end

-- синхронный путь (без runner) не генерирует: цикл интерфейса ждал бы вызов до минуты
function T.test_sync_followup_does_not_generate()
  local env = make("Гермиона Грейнджер")
  env.ctrl:on_unlocked_followup() -- llm_call бросил бы ошибку в лог
  t.ok(not logged(env, "синхронный вызов"), table.concat(env.logs, " | "))
  t.ok(env.ctrl:gen_due(), "генерация ждёт runner")
end

-- хранилище персон недоступно (миграция 5 не прошла): не «Методов» — фраза сбоя, не Волдеморт
function T.test_no_persona_store_fails_soft()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("CREATE TABLE personas_x(a); CREATE INDEX personas ON personas_x(a);")
  conn:close()
  local env = make("Гермиона Грейнджер", path)
  t.ok(not env.ctrl:gen_due())
  local job, text = env.ctrl:begin(PNG)
  t.eq(job, nil)
  t.ok(in_list(texts.neutral.en.later, text), tostring(text))
end

-- наборы фраз персонажа (план, задача 2) ------------------------------------------------------------------------

-- годный набор: n разных фраз в одно предложение; prefix различает наборы. «_» из имени набора убран: подчёркивание
-- — разметка, а «offline» в «fail_offline» — запрещённое слово (texts.fits)
local function phrases(n, prefix)
  local list = {}
  local tag = (prefix or "Фраза"):gsub("_", "")
  for i = 1, n do list[i] = tag .. " номер " .. i .. " голосом Гермионы." end
  return list
end

local function set_json(list) return "```json\n" .. json.encode(list) .. "\n```" end

-- порядок генерации наборов (план, раздел 2 «Разделы»)
local SET_ORDER = { "thinking", "unreadable", "greetings", "welcomes", "busy", "interrupted", "fail_offline",
  "fail_slow", "fail_limit", "fail_daily", "fail_other", "sleepy", "tasks_source_unclear" }

-- генерация через хвост, как на устройстве: разделы persona и world, затем первые n наборов (каждый — свой префикс)
local function generate(env, n)
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "persona")
  env.ctrl:finish_followup(job, { result = { text = PERSONA_JSON } })
  job = env.ctrl:begin_followup()
  t.eq(job.section, "world")
  env.ctrl:finish_followup(job, { result = { text = WORLD_TEXT } })
  for i = 1, n do
    job = env.ctrl:begin_followup()
    t.eq(job.section, "texts." .. SET_ORDER[i])
    env.ctrl:finish_followup(job, { result = { text = set_json(phrases(36, SET_ORDER[i])) } })
  end
end

function T.test_text_sections_follow_persona_in_order()
  local names = {}
  for _, s in ipairs(persona.SECTIONS) do names[#names + 1] = s.name end
  local want = { "persona", "world" }
  for _, n in ipairs(SET_ORDER) do want[#want + 1] = "texts." .. n end
  want[#want + 1] = "map"
  want[#want + 1] = "map.cast"
  t.eq(table.concat(names, ","), table.concat(want, ","))
  t.eq(persona.SECTIONS[#persona.SECTIONS - 1], persona.MAP_SECTIONS[1], "те же таблицы, что MAP_SECTIONS")
  t.eq(persona.SECTIONS[#persona.SECTIONS], persona.MAP_SECTIONS[2])
  t.eq(#persona.MAP_SECTIONS, 2)
end

-- разделы карты — после всех наборов фраз (план карты, раздел 2): map, затем map.cast, потом генерация закончена
function T.test_map_sections_after_texts()
  local MP = require("fixtures.map_parts")
  local env = make("Гермиона Грейнджер")
  generate(env, #SET_ORDER)
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "map", "после последнего набора — карта")
  t.ok(job.opts.max_tokens >= 1500, "потолок ответа раздела map")
  t.eq(env.ctrl:finish_followup(job, { result = { text = MP.map_json } }), true)
  job = env.ctrl:begin_followup()
  t.eq(job.section, "map.cast")
  t.eq(env.ctrl:finish_followup(job, { result = { text = MP.cast_json } }), false)
  t.ok(not env.ctrl:gen_due(), "всё сгенерировано")
  local m = env.ctrl:map()
  t.eq(m.open, MP.map.open)
  t.eq(m.potter, false)
  t.eq(#m.cast, 10)
  t.ok(logged(env, "riddle: gen map.cast saved"), table.concat(env.logs, " | "))
end

-- запрос набора — голосом персонажа: голова и тело персоны, 36 фраз, бюджет генерации, ответ текстом
function T.test_gen_texts_request_in_persona_voice()
  local env = make("Гермиона Грейнджер")
  generate(env, 0)
  t.ok(env.ctrl:gen_due(), "после персоны — наборы")
  local job = env.ctrl:begin_followup()
  t.eq(job.kind, "gen")
  t.eq(job.section, "texts.thinking")
  local call = env.calls[#env.calls]
  local all = json.encode(call.messages)
  t.ok(has(all, PERSONA_OBJ.head), "голова персоны в запросе")
  t.ok(has(all, "ГОЛОС-ГЕРМИОНЫ"), "тело персоны в запросе")
  t.ok(has(all, "36"), "36 фраз")
  t.eq(call.want_json, false)
  t.eq(call.opts.limits, "gen")
  t.eq(call.opts.max_tokens, 2000)
end

-- годных фраз меньше 30 — набор не сохраняется, пауза до следующей страницы, в лог — число
function T.test_set_under_30_not_saved()
  local env = make("Гермиона Грейнджер")
  generate(env, 4)
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "texts.busy")
  local list = phrases(29, "Занят")
  list[#list + 1] = "Занят 😀 эмодзи."
  list[#list + 1] = "**Занят** жирно."
  list[#list + 1] = list[1] -- повтор
  list[#list + 1] = "Сеть занята, вернись позже."
  t.eq(env.ctrl:finish_followup(job, { result = { text = set_json(list) } }), false, "пауза")
  t.ok(not env.ctrl:gen_due())
  t.eq(env.mem:parts(job.persona_id)["texts.busy"], nil, "набор не сохранён")
  t.ok(logged(env, "riddle: gen texts.busy failed (pool 29)"), table.concat(env.logs, " | "))
  env.ctrl:begin(PNG)
  t.ok(env.ctrl:gen_due(), "после страницы — снова")
  t.eq(env.ctrl:begin_followup().section, "texts.busy", "тот же набор")
end

-- граница texts.MIN_POOL (ревью ba4087a): ровно 30 годных — набор сохранён, цепочка идёт дальше; 29 — нет
function T.test_set_exactly_30_saved_29_not()
  for _, case in ipairs({ { n = 30, saved = true }, { n = 29, saved = false } }) do
    local env = make("Гермиона Грейнджер")
    generate(env, 0)
    local job = env.ctrl:begin_followup()
    t.eq(job.section, "texts.thinking")
    local list = phrases(case.n, "Думаю")
    t.eq(env.ctrl:finish_followup(job, { result = { text = set_json(list) } }), case.saved, case.n .. ": дальше?")
    local got = env.mem:parts(job.persona_id)["texts.thinking"]
    if case.saved then
      t.eq(got, json.encode(list), "30 — сохранены все")
    else
      t.eq(got, nil, "29 — не сохранён")
    end
  end
end

-- обрыв посередине: новый контроллер на той же базе продолжает с первого недостающего; повтор сохранения того же
-- набора даёт то же состояние
function T.test_gen_resumes_from_missing_section()
  local env = make("Гермиона Грейнджер")
  generate(env, 3)
  local again = make("Гермиона Грейнджер", env.path)
  local job = again.ctrl:begin_followup()
  t.eq(job.section, "texts.welcomes", "4-й набор")
  local text = set_json(phrases(36, "welcomes"))
  again.ctrl:finish_followup(job, { result = { text = text } })
  local before = env.mem:parts(job.persona_id)
  again.ctrl:finish_followup(job, { result = { text = text } })
  local after = env.mem:parts(job.persona_id)
  local n = 0
  for k, v in pairs(before) do
    n = n + 1
    t.eq(after[k], v, k)
  end
  for k in pairs(after) do t.ok(before[k] ~= nil, "лишний раздел " .. k) end
  t.eq(n, 6, "persona, world и 4 набора")
end

-- сгенерированный набор — в фразах дневника; недостающий — нейтральный пул
function T.test_generated_pool_used()
  local env = make("Гермиона Грейнджер")
  generate(env, 7) -- до fail_offline включительно
  local busy = env.ctrl:texts("busy")
  t.eq(table.concat(busy, "|"), table.concat(phrases(36, "busy"), "|"))
  t.ok(env.ctrl:texts("busy") == busy, "та же таблица: мешок _pick держится")
  t.ok(env.ctrl:texts("sleepy") == texts.neutral.ru.later, "недостающий — нейтральный, не «Методов»")
  -- сбой ответа — фраза из сгенерированного пула причины
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open")
  t.ok(in_list(phrases(36, "fail_offline"), env.ctrl:finish(job, nil, "gemini: offline")), "fail_offline свой")
  -- «Методов» — пулы texts как есть
  local m = make(METHODS_LINE)
  t.ok(m.ctrl:texts("busy") == texts.busy)
end

-- первая строка на чистой странице: с печатью — приглашение персонажа, без печати — его приветствие
function T.test_invitation_from_persona_when_sealed()
  local env = make("Гермиона Грейнджер", nil, true)
  env.mem:add_persona{ key = persona.key("Гермиона Грейнджер"), line = "Гермиона Грейнджер", source = "config",
    state = "ready" }
  local row = env.mem:persona_by_key(persona.key("Гермиона Грейнджер"))
  env.mem:set_part(row.id, "persona", persona.section("persona").decode(PERSONA_JSON), 1)
  -- мир ещё не готов (persona.ready — persona и world): приглашение персонажа рано, нейтральное
  t.ok(in_list(texts.neutral.ru.invitation, env.ctrl:opening_text()), "без мира — нейтральное приглашение")
  env.mem:set_part(row.id, "world", WORLD_TEXT, 1)
  t.eq(env.ctrl:opening_text(), PERSONA_OBJ.invitation)
  t.eq(make(METHODS_LINE, nil, true).ctrl:opening_text(), texts.invitation, "«Методов» — прежнее")
  t.ok(in_list(texts.neutral.ru.invitation, make("Гермиона Грейнджер", nil, true).ctrl:opening_text()),
    "персоны ещё нет — нейтральное приглашение")
  local open = make("Гермиона Грейнджер")
  generate(open, 3) -- greetings третьим
  t.ok(in_list(phrases(36, "greetings"), open.ctrl:opening_text()), "без печати — приветствие персонажа")
end

-- файл forget_persona (main.lua): разделы текущей персоны стёрты — генерация заново; «Методов» не трогается
function T.test_forget_persona_clears_generated_keeps_methods()
  local env = make("Гермиона Грейнджер")
  generate(env, 2)
  env.ctrl:forget_persona()
  t.ok(env.ctrl:gen_due(), "генерация заново")
  t.eq(env.ctrl:begin_followup().section, "persona")
  t.ok(logged(env, "riddle: persona forgotten"), table.concat(env.logs, " | "))
  local m = make(METHODS_LINE)
  local MP = require("fixtures.map_parts")
  m.mem:set_part(persona.METHODS_ID, "map", persona.section("map").decode(MP.map_json), m.now)
  t.eq(m.ctrl:forget_persona(), false)
  t.ok(not logged(m, "riddle: persona forgotten"), "встроенную не стирает")
  t.ok(m.mem:parts(persona.METHODS_ID).map, "данные карты «Методов» не стёрты (план карты, раздел 6 п.4)")
end

-- память на персонажа (план, задача 3) --------------------------------------------------------------------------

-- персона строки line готова (разделы persona и world; world == false — без мира), без наборов
local function ready(env, line, world)
  local key = persona.key(line)
  env.mem:add_persona{ key = key, line = line, source = "config", state = "ready" }
  local o = json.decode(json.encode(PERSONA_OBJ))
  o.head = "дневник персонажа " .. line .. "."
  local id = env.mem:persona_by_key(key).id
  env.mem:set_part(id, "persona", persona.section("persona").decode(json.encode(o)), 1)
  if world ~= false then env.mem:set_part(id, "world", WORLD_TEXT, 1) end
end

-- lore.md на устройстве: mtime и текст задаёт тест
local function with_lore_file(env, file)
  local read = env.ctrl.deps.read_file
  env.ctrl.deps.file_mtime = function(p) return p == "/lore.md" and file.mtime or nil end
  env.ctrl.deps.read_file = function(p) if p == "/lore.md" then return file.text end return read(p) end
end

local function system_of(env)
  return env.ctrl:begin(PNG).messages[1].content
end

-- решение 6а плана: lore.md, уже импортированный к A, к B не идёт; изменённый файл (новый mtime) — к тому, кто
-- сейчас, а A свой прежний лор не теряет
function T.test_lore_md_not_imported_to_other_persona()
  local file = { mtime = 100, text = "## Мир\nЛОР-ФАЙЛА-1" }
  local a = make("Гермиона Грейнджер")
  ready(a, "Гермиона Грейнджер")
  with_lore_file(a, file)
  a.ctrl:on_unlocked_followup()
  t.ok(has(system_of(a), "ЛОР-ФАЙЛА-1"), "лор импортирован к A")
  local b = make("Рон Уизли", a.path)
  ready(b, "Рон Уизли")
  with_lore_file(b, file)
  b.ctrl:on_unlocked_followup()
  t.ok(not has(system_of(b), "ЛОР-ФАЙЛА-1"), "лор A к B не импортирован")
  file.mtime, file.text = 200, "## Мир\nЛОР-ФАЙЛА-2"
  b.ctrl:on_unlocked_followup()
  t.ok(has(system_of(b), "ЛОР-ФАЙЛА-2"), "изменённый файл — к B")
  local a2 = make("Гермиона Грейнджер", a.path)
  with_lore_file(a2, file)
  a2.ctrl:on_unlocked_followup()
  local s = system_of(a2)
  t.ok(has(s, "ЛОР-ФАЙЛА-1") and not has(s, "ЛОР-ФАЙЛА-2"), "у A — свой прежний лор")
end

-- строка A → B → A через контроллер: B начинает с пустой памятью, у A всё возвращается
function T.test_switch_persona_memory_through_controller()
  local a = make("Гермиона Грейнджер")
  ready(a, "Гермиона Грейнджер")
  local job = a.ctrl:begin(PNG)
  a.ctrl:finish(job, { result = { read = "ЗАПИСЬ-ГЕРМИОНЕ", reply = "ОТВЕТ-ГЕРМИОНЫ" } })
  local b = make("Рон Уизли", a.path)
  ready(b, "Рон Уизли")
  t.ok(not has(json.encode(b.ctrl:begin(PNG).messages), "ЗАПИСЬ-ГЕРМИОНЕ"), "у B нет реплик A")
  local a2 = make("Гермиона Грейнджер", a.path)
  t.ok(has(json.encode(a2.ctrl:begin(PNG).messages), "ЗАПИСЬ-ГЕРМИОНЕ"), "у A реплики на месте")
end

-- миграция 6 не прошла: «Методов» отвечает с памятью, у другого персонажа памяти нет — фраза сбоя и лог, не чужая
-- память
function T.test_persona_without_memory_fails_soft()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("CREATE TABLE x(a); CREATE INDEX lore_p ON x(a);")
  conn:close()
  -- «Методов» отвечает как прежде: его сессия с репликами — в общей памяти
  local m = make(METHODS_LINE, path)
  local mjob = m.ctrl:begin(PNG)
  t.eq(mjob.mode, "open", "«Методов» — как прежде")
  m.ctrl:finish(mjob, { result = { read = "ЗАПИСЬ-РЕДДЛУ", reply = "ОТВЕТ-РЕДДЛА" } })
  local env = make("Гермиона Грейнджер", path)
  env.now = 1000 + 5 * 3600 -- сессия «Методов» уже прошлая: её пересказ назрел бы
  ready(env, "Гермиона Грейнджер")
  local job, text = env.ctrl:begin(PNG)
  t.eq(job, nil)
  t.ok(in_list(texts.neutral.ru.later, text), tostring(text))
  t.ok(logged(env, "riddle: memory personas unavailable"), table.concat(env.logs, " | "))
  t.ok(logged(env, "riddle: persona has no memory"), table.concat(env.logs, " | "))
  for _ = 1, #persona.SECTIONS do -- генерация памяти не требует: наборы фраз — своим чередом
    local tail = env.ctrl:begin_followup()
    if not tail then break end
    t.eq(tail.kind, "gen", "пересказа сессии «Методов» голосом Гермионы нет")
    env.ctrl:finish_followup(tail, { result = { text = set_json(phrases(36, tail.section)) } })
  end
  t.eq(env.ctrl:begin_followup(), nil, "после генерации хвоста нет")
end

-- ревью среза 3, п.3: у персонажа нет строки в personas (шаг 5 не прошёл) — чужая память не подставляется:
-- лор из lore.md к нему не идёт, пересказа сессии «Методов» нет
function T.test_persona_without_row_gets_no_lore_and_no_summary()
  local path = os.tmpname()
  paths[#paths + 1] = path
  local conn = require("lua-ljsqlite3/init").open(path)
  conn:exec("CREATE TABLE personas_x(a); CREATE INDEX personas ON personas_x(a);")
  conn:close()
  local m = make(METHODS_LINE, path)
  local mjob = m.ctrl:begin(PNG)
  m.ctrl:finish(mjob, { result = { read = "ЗАПИСЬ-РЕДДЛУ", reply = "ОТВЕТ-РЕДДЛА" } })
  local env = make("Гермиона Грейнджер", path)
  env.now = 1000 + 5 * 3600 -- сессия «Методов» уже прошлая: её пересказ назрел бы
  with_lore_file(env, { mtime = 100, text = "## Мир\nЛОР-ФАЙЛА" })
  t.eq(env.ctrl:begin_followup(), nil, "пересказа сессии «Методов» голосом Гермионы нет")
  t.eq(env.mem:lore_mtime(), nil, "лор из lore.md к персонажу без строки не идёт")
end

-- язык строки без персоны: кириллица — ru, иначе en
function T.test_lang_of()
  t.eq(persona.lang_of("Гермиона Грейнджер"), "ru")
  t.eq(persona.lang_of("R2-D2 from Star Wars"), "en")
  t.eq(persona.lang_of("Гарри Поттер, Harry Potter"), "ru")
  t.eq(persona.lang_of(""), "en")
end

-- нет сгенерированного набора (персона не готова, набора нет, чтение упало) — нейтральный пул, не «Методов»; язык персонажа
-- ещё не известен (у строки нет lang) — английский, даже при русской строке
function T.test_missing_set_uses_neutral()
  local ru = make("Гермиона Грейнджер")
  t.ok(ru.ctrl:texts("busy") == texts.neutral.en.thinking, "язык неизвестен, en: busy -> thinking")
  t.ok(ru.ctrl:texts("fail_offline") == texts.neutral.en.offline, "язык неизвестен, en: fail_offline -> offline")
  t.ok(ru.ctrl:texts("welcomes") == texts.neutral.en.welcome, "язык неизвестен, en: welcomes -> welcome")
  t.ok(ru.ctrl:texts("tasks_source_unclear") == texts.neutral.en.source_unclear, "язык неизвестен, en: tasks_source_unclear -> source_unclear")
  for _, n in ipairs({ "fail_slow", "fail_limit", "fail_other", "sleepy" }) do
    t.ok(ru.ctrl:texts(n) == texts.neutral.en.later, "язык неизвестен, en: " .. n .. " -> later")
  end
  t.ok(ru.ctrl:texts("greetings") == texts.neutral.en.invitation, "язык неизвестен, en: greetings -> invitation")
  t.ok(ru.ctrl:texts("fail_daily") == texts.neutral.en.tomorrow, "язык неизвестен, en: fail_daily -> tomorrow, не later")
  local en = make("R2-D2 from Star Wars")
  t.ok(en.ctrl:texts("busy") == texts.neutral.en.thinking, "en: busy -> thinking")
  t.ok(en.ctrl:texts("unreadable") == texts.neutral.en.unreadable, "en: unreadable")
  -- персона готова, но набора busy нет: нейтральный, на языке её view (PERSONA_OBJ.lang = "ru")
  ready(ru, "Гермиона Грейнджер")
  t.ok(ru.ctrl:texts("busy") == texts.neutral.ru.thinking, "готова, набора нет — нейтральный")
  t.ok(ru.ctrl:texts("busy") ~= texts.busy)
end

-- ревью задачи 5, Б1: сбой при готовой персоне без набора — «позже», а не «ответ идёт»
function T.test_failure_without_set_says_later_not_thinking()
  for _, case in ipairs({ { "gemini: timeout", "fail_slow" }, { "http 429", "fail_limit" }, { "boom", "fail_other" } }) do
    local env = make("Гермиона Грейнджер")
    ready(env, "Гермиона Грейнджер")
    local job = env.ctrl:begin(PNG)
    t.eq(job.mode, "open")
    local text = env.ctrl:finish(job, nil, case[1])
    t.ok(in_list(texts.neutral.ru.later, text), case[2] .. ": " .. tostring(text))
    t.ok(not in_list(texts.neutral.ru.thinking, text), case[2] .. ": обещает ответ: " .. tostring(text))
  end
  -- en: язык персоны
  local en = make("R2-D2 from Star Wars")
  t.ok(en.ctrl:texts("fail_slow") == texts.neutral.en.later, "en: fail_slow -> later")
end

-- персона, сгенерированная до набора fail_daily (Notion 40313e60-bc8d-81a5): все прежние наборы есть, нового нет. Суточный
-- сбой цепочки — нейтральное «завтра» на её языке; недостающий набор догенерируется штатно (следующий хвост), после —
-- фраза её набора. Миграции нет: набор — ещё одна строка persona_parts
function T.test_old_persona_gets_fail_daily_set_and_neutral_until_then()
  local env = make("Гермиона Грейнджер")
  ready(env, "Гермиона Грейнджер")
  local id = env.mem:persona_by_key(persona.key("Гермиона Грейнджер")).id
  for _, name in ipairs(SET_ORDER) do
    if name ~= "fail_daily" then env.mem:set_part(id, "texts." .. name, json.encode(phrases(36, name)), 1) end
  end
  require("fixtures.map_parts").seed(env.mem, id, 1) -- данные карты есть: недостаёт только набора
  local daily = (llm.DAILY or "?") .. "gemini: http 429"
  local text = env.ctrl:finish(env.ctrl:begin(PNG), nil, daily)
  t.ok(in_list(texts.neutral.ru.tomorrow or {}, text), "до набора — нейтральное «завтра»: " .. tostring(text))
  local limit = env.ctrl:finish(env.ctrl:begin(PNG), nil, "gemini: http 429")
  t.ok(in_list(phrases(36, "fail_limit"), limit), "минутный — набор fail_limit персоны: " .. tostring(limit))
  t.ok(env.ctrl:gen_due(), "недостающий набор — генерация нужна")
  local job = env.ctrl:begin_followup()
  t.eq(job and job.section, "texts.fail_daily")
  env.ctrl:finish_followup(job, { result = { text = set_json(phrases(36, "fail_daily")) } })
  t.ok(not env.ctrl:gen_due(), "наборы полны")
  text = env.ctrl:finish(env.ctrl:begin(PNG), nil, daily)
  t.ok(in_list(phrases(36, "fail_daily"), text), "после генерации — набор персоны: " .. tostring(text))
end

-- ревью задачи 5, бэклог 1: пустой/не-массив набор в хранилище — нейтральный пул, не «Методов»
function T.test_broken_stored_set_uses_neutral_not_methods()
  for _, bad in ipairs({ "[]", "{}", "5", '"строка"', "null", "[не json" }) do
    local env = make("Гермиона Грейнджер")
    ready(env, "Гермиона Грейнджер")
    local row = env.mem:persona_by_key(persona.key("Гермиона Грейнджер"))
    env.mem:set_part(row.id, "texts.busy", bad, 1)
    local pool = env.ctrl:texts("busy")
    t.ok(pool == texts.neutral.ru.thinking, "набор " .. bad .. " -> нейтральный")
    t.ok(pool ~= texts.busy, "набор " .. bad .. ": не «Методов»")
  end
end

-- язык нейтрального пула: язык персоны (view.lang); незнакомый (вне ru/en) — как неизвестный: en, строка не в счёт
function T.test_neutral_language_follows_persona_then_line()
  local function with_lang(line, lang)
    local env = make(line)
    ready(env, line)
    local row = env.mem:persona_by_key(persona.key(line))
    local o = json.decode(json.encode(PERSONA_OBJ))
    o.lang = lang
    env.mem:set_part(row.id, "persona", json.encode(o), 1) -- мимо decode: язык задан как есть
    return env
  end
  -- строка русская, язык персонажа английский -> английский пул
  t.ok(with_lang("Гермиона Грейнджер", "en").ctrl:texts("busy") == texts.neutral.en.thinking, "persona en, строка ru")
  -- строка английская, язык персонажа русский -> русский пул
  t.ok(with_lang("R2-D2 from Star Wars", "ru").ctrl:texts("busy") == texts.neutral.ru.thinking, "persona ru, строка en")
  -- язык вне ru/en — en, без падения, даже при русской строке
  t.ok(with_lang("Гермиона Грейнджер", "de").ctrl:texts("busy") == texts.neutral.en.thinking, "persona de -> en")
  t.ok(with_lang("R2-D2 from Star Wars", "de").ctrl:texts("busy") == texts.neutral.en.thinking, "persona de -> en")
end

-- ревью задачи 4: потолок лора держится на уровне контроллера — правило, lore.md и мир вместе не длиннее
-- memory.LORE_CAP (cap = nil и «правило сверх потолка» дали бы ~14 000 знаков)
function T.test_lore_with_world_fits_cap_through_controller()
  local env = make("Гермиона Грейнджер")
  ready(env, "Гермиона Грейнджер")
  local id = env.mem:persona_by_key(persona.key("Гермиона Грейнджер")).id
  -- знаки, которых нет в остальном промпте: границы блока видны
  env.mem:set_part(id, "world", string.rep("界", 3000), 2)
  with_lore_file(env, { mtime = 100, text = "## Мир\n" .. string.rep("字", 9000) })
  env.ctrl:on_unlocked_followup()
  local s = system_of(env)
  local from = s:find(prompt.LORE_WINS, 1, true)
  t.ok(from, "правило «верен lore.md» в блоке")
  local to = select(2, s:find(".*界"))
  t.ok(to, "мир в блоке")
  local block = s:sub(from, to)
  t.ok(prompt.utf8_len(block) <= memory.LORE_CAP, "блок лора " .. prompt.utf8_len(block) .. " знаков, потолок " .. memory.LORE_CAP)
  t.ok(select(2, block:gsub("字", "")) == 9000, "lore.md цел")
  t.ok(select(2, block:gsub("界", "")) < 3000, "мир урезан до остатка")
end

-- мир — в лор после lore.md: правило «верен lore.md» первой строкой; мира нет — лор как был
function T.test_world_in_prompt_after_lore_md()
  local env = make("Гермиона Грейнджер")
  ready(env, "Гермиона Грейнджер", true)
  local file = { mtime = 100, text = "## Мир\nЛОР-ФАЙЛА" }
  with_lore_file(env, file)
  env.ctrl:on_unlocked_followup()
  local s = env.ctrl:begin(PNG).messages[1].content
  local lore_at = s:find("ЛОР-ФАЙЛА", 1, true)
  local world_at = s:find("МИР-ГЕРМИОНЫ", 1, true)
  t.ok(lore_at and world_at and lore_at < world_at, "lore.md раньше мира")
  local wins_at = s:find(prompt.LORE_WINS, 1, true)
  t.ok(wins_at and wins_at < lore_at, "LORE_WINS — перед обоими")
  -- мир без lore.md: правила нет, мир на месте
  local solo = make("Рон Уизли", env.path)
  ready(solo, "Рон Уизли", true)
  local s2 = solo.ctrl:begin(PNG).messages[1].content
  t.ok(has(s2, "МИР-ГЕРМИОНЫ"), "мир без lore.md — в лоре")
  t.ok(not has(s2, prompt.LORE_WINS), "правила нет")
end

-- мир не раздувает лог устройства: ни строки мира, ни lore.md
function T.test_no_world_text_in_log()
  local env = make("Гермиона Грейнджер")
  ready(env, "Гермиона Грейнджер", true)
  with_lore_file(env, { mtime = 100, text = "## Мир\nЛОР-ФАЙЛА" })
  env.ctrl:on_unlocked_followup()
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "ЗАПИСЬ", reply = "ОТВЕТ" } })
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "МИР-ГЕРМИОНЫ") and not has(l, "ЛОР-ФАЙЛА") and not has(l, "ГОЛОС-ГЕРМИОНЫ"), l)
  end
end

-- переспрос строки из конфига (план, задача 7) -------------------------------------------------------------------

local R2_LINE = "R2-D2"
-- ответ resolve: мира в строке нет, модель дописала его
local R2_ASK = "So this is the diary of R2-D2 from Star Wars?"
local R2_OBJ = { who = "R2-D2", world = "Star Wars", world_named = false, lang = "en", ask = R2_ASK }

local function resolve_json(o) return "```json\n" .. json.encode(o) .. "\n```" end

local function state_of(env, line)
  local row = env.mem:persona_by_key(persona.key(line))
  return row and row.state, row
end

-- первое задание хвоста — resolve; ответ модели подан -> задание, нужна ли ещё генерация
local function resolve(env, obj)
  local job = env.ctrl:begin_followup()
  t.eq(job.kind, "gen")
  t.eq(job.section, "resolve")
  return job, env.ctrl:finish_followup(job, { result = { text = resolve_json(obj) } })
end

function T.test_config_line_without_world_asks_once()
  local path = os.tmpname()
  local env = bare(R2_LINE, path)
  t.ok(env.ctrl:gen_due(), "строка новая — разбор нужен")
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "resolve", "разбор строки — первым")
  local call = env.calls[#env.calls]
  t.ok(has(json.encode(call.messages), R2_LINE), "строка дословно в запросе")
  t.eq(call.want_json, false)
  t.eq(call.opts.limits, "gen")
  t.eq(env.ctrl:finish_followup(job, { result = { text = resolve_json(R2_OBJ) } }), false,
    "мир дописала модель — пока не подтвердят, генерации нет")
  t.eq(state_of(env, R2_LINE), "confirm")
  t.ok(not env.ctrl:gen_due())
  t.ok(logged(env, "riddle: gen resolve saved"), table.concat(env.logs, " | "))
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "R2-D2") and not has(l, "Star Wars"), "строка и мир в лог не идут: " .. l)
  end
  -- чистая страница: вопрос вместо приветствия
  t.eq(env.ctrl:opening_text(), R2_ASK)
  -- «да»: запись читается вместе с вопросом
  local ajob = env.ctrl:begin(PNG)
  t.eq(ajob.mode, "setup")
  t.eq(ajob.stage, "confirm")
  t.eq(json.encode(ajob.messages), json.encode(prompt.setup("B64", R2_ASK)), "запрос — prompt.setup с вопросом")
  local text = env.ctrl:finish(ajob, { result = { read = "yes", reply = "ОТВЕТ-МОДЕЛИ", yes = true } })
  t.ok(in_list(texts.neutral.en.later, text), "ответ на «да» — нейтральное «позже»: " .. tostring(text))
  local state, row = state_of(env, R2_LINE)
  t.eq(state, "ready")
  t.eq(row.ask, nil, "вопрос снят")
  t.ok(logged(env, "riddle: persona confirmed"), table.concat(env.logs, " | "))
  -- генерация пошла с миром в строке
  t.ok(env.ctrl:gen_due())
  local gjob = env.ctrl:begin_followup()
  t.eq(gjob.section, "persona", "разбор не повторяется")
  local gen_req = json.encode(env.calls[#env.calls].messages)
  t.ok(has(gen_req, "R2-D2") and has(gen_req, "Star Wars"), "в строке генерации — персонаж и мир")
  -- новый контроллер на той же базе: вопроса нет
  local again = bare(R2_LINE, path)
  t.ok(again.ctrl:opening_text() ~= R2_ASK, "подтверждённое не переспрашивается")
  t.eq(again.ctrl:begin_followup().section, "persona")
end

function T.test_config_line_with_world_not_asked()
  local line = "R2-D2 from Star Wars"
  local env = bare(line)
  local _, more = resolve(env, { who = "R2-D2", world = "Star Wars", world_named = true, lang = "en" })
  t.eq(more, true, "мир назван — сразу генерация")
  t.eq(state_of(env, line), "ready")
  t.ok(env.ctrl:opening_text() ~= R2_ASK)
  local gen_req = json.encode(env.ctrl:begin_followup().messages)
  t.ok(has(gen_req, line), "строка как написана")
  t.ok(not has(gen_req, "R2-D2 —"), "строка не переписана")
end

function T.test_methods_line_never_asks()
  local env = bare(METHODS_LINE)
  local job = env.ctrl:begin_followup()
  t.eq(job and job.section, "map", "ни resolve, ни разделов персоны — только данные карты")
  t.eq(#env.calls, 1, "модель звалась только за картой")
  env.ctrl:finish_followup(job, nil, "cancelled")
  t.eq(env.mem:persona_by_key(persona.key(METHODS_LINE)), nil, "строка «Методов» в базе не заводится")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open", "ответ как прежде")
end

-- потолки разбора resolve (ревью 9720cba, выжившие B9, B10): длинное имя/мир — отказ, длинный «язык» — язык строки
function T.test_decode_resolve_caps()
  local function decode(o) return persona.decode_resolve(resolve_json(o), R2_LINE) end
  local at_cap, over = ("я"):rep(100), ("я"):rep(101)
  t.ok(decode({ who = at_cap, world = "Мир", world_named = false, lang = "ru" }), "100 знаков — годно")
  t.ok(decode({ who = "R2-D2", world = at_cap, world_named = false, lang = "ru" }), "мир в 100 знаков — годен")
  local v, err = decode({ who = over, world = "Мир", world_named = false, lang = "ru" })
  t.eq(v, nil); t.eq(err, "too long")
  v, err = decode({ who = "R2-D2", world = over, world_named = false, lang = "ru" })
  t.eq(v, nil); t.eq(err, "too long")
  -- lang: до 8 байт — как есть (строчными), длиннее — язык строки (кириллица — ru)
  t.eq(decode({ who = "R2-D2", world = "Мир", lang = "PT-BR" }).lang, "pt-br")
  t.eq(persona.decode_resolve(resolve_json({ who = "Р2", world = "Мир", lang = "english-us" }), "р2-д2").lang, "ru",
    "9 байт — не код языка")
  t.eq(decode({ who = "R2-D2", world = "Мир", lang = "" }).lang, "en", "пусто — язык строки")
end

-- сбой записи ответа на вопрос о строке: не «позже» (ответ принят), а фраза сбоя; состояние не менялось. Нейтральные
-- пулы fail_other и sleepy — один и тот же `later`, поэтому наборы строки разведены своими фразами
function T.test_answer_persona_failure_is_fail_other()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  local _, row = state_of(env, R2_LINE)
  env.mem:set_part(row.id, "texts.fail_other", json.encode({ "СБОЙ-ФРАЗА" }), 1)
  env.mem:set_part(row.id, "texts.sleepy", json.encode({ "ПОЗЖЕ-ФРАЗА" }), 1)
  env.mem.answer_persona = function() error("disk full") end
  local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "yes", reply = "x", yes = true } })
  t.eq(text, "СБОЙ-ФРАЗА", "ответ принят не был — фраза сбоя")
  t.ok(logged(env, "riddle: persona answer failed"), table.concat(env.logs, " | "))
  t.eq(state_of(env, R2_LINE), "confirm", "строка ждёт ответа")
  t.ok(not logged(env, "riddle: persona confirmed"), "решение не залогировано")
end

-- сбой чтения строки конфига из базы (не «нет таблицы»: I/O, busy) — не исключение в виджет: страница и фразы идут
-- путём сбоя, как до отвергнутой строки (ревью 623fe64, Б1)
function T.test_config_line_read_failure_is_fail_other_not_error()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "no", reply = "x" } })
  t.eq(state_of(env, R2_LINE), "rejected")
  env.mem.persona_by_key = function() error("disk I/O error", 0) end
  local ok, text = pcall(env.ctrl.texts, env.ctrl, "fail_other")
  t.ok(ok, "texts не бросает: " .. tostring(text))
  t.ok(in_list(texts.neutral.en.later, text[1] and text[1] or ""), "нейтральный пул сбоя")
  local ok2, job, reply = pcall(env.ctrl.begin, env.ctrl, PNG)
  t.ok(ok2, "begin не бросает: " .. tostring(job))
  t.eq(job, nil, "модель не зовётся")
  t.ok(in_list(texts.neutral.en.later, reply), "фраза сбоя: " .. tostring(reply))
  local ok3, open = pcall(env.ctrl.opening_text, env.ctrl)
  t.ok(ok3 and type(open) == "string", "opening_text не бросает: " .. tostring(open))
  t.ok(logged(env, "riddle: persona config read failed"), table.concat(env.logs, " | "))
  -- база снова читается: сбой помнится только до следующей страницы — строка отвергнута, снова вопрос
  env.mem.persona_by_key = nil
  local job2 = env.ctrl:begin(PNG)
  t.eq(job2 and job2.stage, "ask", "следующая страница — ответ на «Чей это дневник?»")
end

-- пробуждение (открытие) после сбоя чтения строки конфига, до первой записи: база перечитывается — отвергнутая строка
-- снова даёт «Чей это дневник?», а не приветствие по строке, сочтённой при сбое действующей (Notion 41013e60-bc8d-816b)
function T.test_opening_after_config_read_failure_rereads_config_line()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "no", reply = "x" } })
  t.eq(state_of(env, R2_LINE), "rejected")
  env.mem.persona_by_key = function() error("disk I/O error", 0) end
  env.ctrl:begin(PNG) -- страница при сбое чтения: строка сочтена действующей до следующей страницы
  env.ctrl:on_sleep()
  env.mem.persona_by_key = nil -- база снова читается
  local text = env.ctrl:opening_text() -- пробуждение до первой записи
  t.ok(in_list(texts.neutral.ru.ask, text), "«Чей это дневник?», не приветствие: " .. tostring(text))
end

-- нет сети на странице-ответе о строке: строка остаётся в confirm, следующая страница снова читается как ответ на
-- тот же вопрос (ревью 9720cba, наблюдение 1; в ask — test_ask_repeats_after_offline)
function T.test_confirm_repeats_after_offline()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  local job = env.ctrl:begin(PNG)
  t.eq(job.stage, "confirm")
  local text = env.ctrl:finish(job, nil, "offline")
  t.ok(in_list(texts.neutral.en.offline, text), "нейтральное «нет сети»: " .. tostring(text))
  t.eq(state_of(env, R2_LINE), "confirm", "ни да, ни отказ")
  local again = env.ctrl:begin(PNG)
  t.eq(again.stage, "confirm", "следующая страница — снова ответ на вопрос")
  t.eq(json.encode(again.messages), json.encode(prompt.setup("B64", R2_ASK)), "вопрос в запросе тот же")
  local ok_text = env.ctrl:finish(again, { result = { read = "yes", reply = "x", yes = true } })
  t.ok(in_list(texts.neutral.en.later, ok_text))
  t.eq(state_of(env, R2_LINE), "ready")
end

-- нечитаемое на вопрос о строке — не отказ: вопрос остаётся, строка ждёт ответа (ревью 9720cba, выживший B8)
function T.test_unreadable_answer_to_question_keeps_confirm()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  for _, read in ipairs({ "?", "" }) do
    local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = read, reply = "x", yes = false } })
    t.ok(in_list(texts.neutral.en.unreadable, text), "не разобрать: " .. tostring(text))
    t.eq(state_of(env, R2_LINE), "confirm", "строка ждёт ответа, не rejected")
  end
  t.eq(env.ctrl:begin(PNG).stage, "confirm", "вопрос всё ещё ждёт ответа")
end

-- два ответа на вопрос в пути: решение первого не отменяется вторым
function T.test_second_answer_does_not_overturn_first()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  local first, second = env.ctrl:begin(PNG), env.ctrl:begin(PNG)
  t.eq(first.stage, "confirm")
  t.eq(second.stage, "confirm")
  env.ctrl:finish(first, { result = { read = "no", reply = "x" } })
  env.ctrl:finish(second, { result = { read = "yes", reply = "x", yes = true } })
  t.eq(state_of(env, R2_LINE), "rejected", "отказ остаётся")
end

-- запоздалое «да» строку не подтвердило — в лог не «confirmed» (ревью a23cbf2, бэклог 4, Notion 41013e60-bc8d-8132)
function T.test_late_answer_is_not_logged_as_a_decision()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  local first, second = env.ctrl:begin(PNG), env.ctrl:begin(PNG)
  env.ctrl:finish(first, { result = { read = "no", reply = "x" } })
  env.ctrl:finish(second, { result = { read = "yes", reply = "x", yes = true } })
  t.ok(logged(env, "riddle: persona rejected"), "первый ответ — решение")
  t.ok(not logged(env, "riddle: persona confirmed"), "запоздалое «да» решением не названо: " .. table.concat(env.logs, " | "))
  t.ok(logged(env, "riddle: persona answer ignored"), "и сказано, что оно не принято")
  t.eq(state_of(env, R2_LINE), "rejected")
end

function T.test_resolve_failure_retried_next_answer()
  local env = bare(R2_LINE)
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "resolve")
  t.eq(env.ctrl:finish_followup(job, nil, "timeout"), false, "сбой — пауза")
  t.eq(state_of(env, R2_LINE), "new", "строка не разобрана")
  t.ok(not env.ctrl:gen_due(), "в паузе")
  -- следующая страница снимает паузу
  local page = env.ctrl:begin(PNG)
  t.eq(page.stage, "gen")
  t.ok(env.ctrl:gen_due(), "после страницы разбор снова нужен")
  job = env.ctrl:begin_followup()
  t.eq(job.section, "resolve", "повтор")
  -- негодный ответ — тоже неудача
  t.eq(env.ctrl:finish_followup(job, { result = { text = "не JSON" } }), false)
  t.eq(state_of(env, R2_LINE), "new")
  env.ctrl:begin(PNG)
  job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { result = { text = resolve_json(R2_OBJ) } })
  t.eq(state_of(env, R2_LINE), "confirm")
end

-- запоздалый или повторный ответ resolve не откатывает уже принятое
function T.test_late_resolve_does_not_revert_state()
  local env = bare(R2_LINE)
  local job = resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "yes", reply = "x", yes = true } })
  t.eq(state_of(env, R2_LINE), "ready")
  env.ctrl:finish_followup(job, { result = { text = resolve_json(R2_OBJ) } })
  local state, row = state_of(env, R2_LINE)
  t.eq(state, "ready", "повтор resolve ничего не меняет")
  t.eq(row.ask, nil)
end

-- вопрос ещё не показан (разбор закончился после открытия): страница — не ответ на него, дневник задаёт вопрос
function T.test_unseen_question_is_shown_before_it_is_answered()
  local env = bare(R2_LINE)
  resolve(env, R2_OBJ)
  local calls = #env.calls
  local job, reply = env.ctrl:begin(PNG)
  t.eq(job, nil, "первая запись — не ответ на невиданный вопрос")
  t.eq(reply, R2_ASK)
  t.eq(#env.calls, calls, "модель не звалась")
  t.eq(state_of(env, R2_LINE), "confirm")
  local ajob = env.ctrl:begin(PNG)
  t.eq(ajob.stage, "confirm", "вопрос показан — запись читается как ответ")
end

-- с печатью: закрытая страница — приглашение, вопрос идёт после ключа, вместе с приветствием
function T.test_sealed_question_comes_with_welcome()
  local env = bare(R2_LINE, nil, true)
  local first = env.ctrl:seal_toggle()
  t.ok(in_list(texts.neutral.en.welcome, first), "строка ещё не разобрана — только приветствие: " .. tostring(first))
  resolve(env, R2_OBJ)
  env.ctrl:seal_toggle() -- ключ снова закрыл печать
  t.ok(in_list(texts.neutral.en.invitation, env.ctrl:opening_text()), "закрытая страница — приглашение, не вопрос")
  t.eq(env.ctrl:begin(PNG).mode, "locked")
  local text = env.ctrl:seal_toggle()
  t.ok(has(text, R2_ASK), "приветствие и вопрос одной репликой: " .. tostring(text))
  local welcome = text:sub(1, #text - #R2_ASK - 1)
  t.ok(in_list(texts.neutral.en.welcome, welcome), "приветствие нейтральное: " .. welcome)
  local ajob = env.ctrl:begin(PNG)
  t.eq(ajob.stage, "confirm", "вопрос показан вместе с приветствием")
end

function T.test_resolve_prompt_and_decode()
  local msgs = prompt.resolve(R2_LINE)
  t.ok(has(json.encode(msgs), R2_LINE))
  for _, k in ipairs({ "who", "world", "world_named", "lang", "ask" }) do
    t.ok(has(msgs[1].content, '"' .. k .. '"'), "ключ " .. k)
  end
  -- названный мир — ready, строка как есть
  local r = persona.decode_resolve(resolve_json({ who = "R2-D2", world = "Star Wars", world_named = true, lang = "en" }),
    "R2-D2 from Star Wars")
  t.eq(r.state, "ready")
  t.eq(r.line, "R2-D2 from Star Wars")
  t.eq(r.lang, "en")
  -- мир дописан — confirm, вопрос модели, строка с миром
  r = persona.decode_resolve(resolve_json(R2_OBJ), R2_LINE)
  t.eq(r.state, "confirm")
  t.eq(r.ask, R2_ASK)
  t.ok(has(r.line, "R2-D2") and has(r.line, "Star Wars"), r.line)
  -- вопроса нет или он негоден — шаблон по языку
  local no_ask = { who = "R2-D2", world = "Star Wars", world_named = false, lang = "en" }
  t.eq(persona.decode_resolve(resolve_json(no_ask), R2_LINE).ask, "So this is the diary of R2-D2 from Star Wars?")
  no_ask.lang = "ru"
  no_ask.ask = "**Так это** дневник?"
  t.eq(persona.decode_resolve(resolve_json(no_ask), "р2-д2").ask, "Так это дневник R2-D2 из Star Wars?")
  -- "true" строкой — не названный
  no_ask.world_named, no_ask.ask = "true", nil
  t.eq(persona.decode_resolve(resolve_json(no_ask), R2_LINE).state, "confirm")
  -- мира нет вовсе (модель его не знает), в строке он не назван: неоднозначное имя в генерацию не идёт — rejected
  -- (ревью 9720cba B-2, решение оркестратора: просьба дописать мир в строку)
  local nowhere = persona.decode_resolve(resolve_json({ who = "R2-D2", world = "", world_named = false, lang = "en" }),
    R2_LINE)
  t.eq(nowhere.state, "rejected")
  t.eq(nowhere.line, R2_LINE, "строка как написана")
  t.eq(nowhere.ask, nil)
  t.eq(persona.decode_resolve(resolve_json({ who = "R2-D2", world = "", world_named = true, lang = "en" }),
    R2_LINE).state, "ready", "мир назван в строке — подтверждать нечего")
  -- мусор
  for _, bad in ipairs({ "", "не JSON", resolve_json({ world = "Star Wars" }), resolve_json({ who = "  " }) }) do
    local v, err = persona.decode_resolve(bad, R2_LINE)
    t.eq(v, nil, "отказ: " .. bad)
    t.ok(type(err) == "string", "причина")
  end
end

-- вопрос «Чей это дневник?» при пустой строке (план, задача 8) ----------------------------------------------------

local ASK_ANS = { read = "Гермиона из Хогвартса", who = "Гермиона Грейнджер", world = "Хогвартс", lang = "ru",
  reply = "Так это дневник Гермионы Грейнджер из Хогвартса?" }
local HERMIONE_LINE = "Гермиона Грейнджер — Хогвартс"

local function rows_count(env, tbl)
  return tonumber(env.mem.conn:rowexec("SELECT COUNT(*) FROM " .. tbl))
end

-- ни строки в конфиге, ни сохранённой: дневник спрашивает на двух языках, запись читается без образа и без памяти
function T.test_no_line_asks_whose_bilingual()
  local env = bare(nil)
  local ask = env.ctrl:opening_text()
  t.ok(in_list(texts.neutral.ru.ask, ask), "вопрос из нейтрального пула: " .. ask)
  t.ok(has(ask, " / "), "на двух языках: " .. ask)
  t.ok(not env.ctrl:gen_due(), "генерировать нечего")
  t.eq(env.ctrl:begin_followup(), nil)
  t.ok(not has(ask, "Реддл") and not has(ask, "Волдеморт"), "не голос «Методов»")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "setup")
  t.eq(job.stage, "ask")
  t.eq(json.encode(job.messages), json.encode(prompt.setup("B64")), "запрос — prompt.setup без вопроса")
  t.ok(not has(json.encode(job.messages), "Волдеморт"), "образа «Методов» нет")
  -- нечитаемое — нейтральное «не разобрать»; ничего не сохранено
  local text = env.ctrl:finish(job, { result = { read = "?", reply = "" } })
  t.ok(in_list(texts.neutral.en.unreadable, text), tostring(text))
  t.eq(rows_count(env, "personas"), 1, "только встроенная")
  t.eq(rows_count(env, "entries"), 0, "ответ на вопрос в память не ложится")
  t.eq(env.mem:last_asked(), nil)
  for _, l in ipairs(env.logs) do t.ok(not has(l, "Гермиона"), "в лог ничего: " .. l) end
end

-- ответ пером -> вопрос с миром (модель); «да» -> строка сохранена как строка из конфига
function T.test_answer_then_confirm_with_world()
  local env = bare(nil)
  local job = env.ctrl:begin(PNG)
  local text = env.ctrl:finish(job, { result = ASK_ANS })
  t.eq(text, ASK_ANS.reply, "ответ — вопрос с миром")
  t.eq(env.mem:last_asked(), nil, "до «да» ничего не сохранено")
  t.eq(env.ctrl:opening_text(), ASK_ANS.reply, "чистая страница повторяет вопрос")
  local job2 = env.ctrl:begin(PNG)
  t.eq(job2.stage, "ask")
  t.eq(json.encode(job2.messages), json.encode(prompt.setup("B64", ASK_ANS.reply)), "запрос — с вопросом")
  local ok_text = env.ctrl:finish(job2, { result = { read = "да", reply = "x", yes = true, lang = "ru" } })
  t.ok(in_list(texts.neutral.ru.later, ok_text), "после «да» — нейтральное «позже» на языке ответа: " .. tostring(ok_text))
  local row = env.mem:last_asked()
  t.eq(row.source, "asked")
  t.eq(row.state, "ready")
  t.eq(row.lang, "ru")
  t.ok(has(row.line, "Гермиона Грейнджер") and has(row.line, "Хогвартс"), row.line)
  t.eq(row.key, persona.key(row.line))
  t.eq(rows_count(env, "entries"), 0, "и «да» в память не ложится")
  for _, l in ipairs(env.logs) do t.ok(not has(l, "Гермиона") and not has(l, "Хогвартс"), "в лог ничего: " .. l) end
end

-- модель вопроса не дала — шаблон по языку; мир не назван — без «из»
function T.test_ask_reply_template_when_model_empty()
  local env = bare(nil)
  local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "x", who = "Гермиона", world = "Хогвартс",
    lang = "ru", reply = "" } })
  t.eq(text, "Так это дневник Гермиона из Хогвартс?")
  env = bare(nil)
  text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "x", who = "R2-D2", world = "", lang = "en",
    reply = "  " } })
  t.eq(text, "So this is the diary of R2-D2?")
end

-- «да»: строка сохранена и генерация пошла; новый контроллер на той же базе — персонаж готов, вопроса нет
function T.test_yes_saves_line_and_starts_gen()
  local path = os.tmpname()
  local env = bare(nil, path)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  t.ok(not env.ctrl:gen_due(), "до «да» генерации нет")
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  t.ok(env.ctrl:gen_due(), "после «да» генерация нужна")
  local gjob = env.ctrl:begin_followup()
  t.eq(gjob.section, "persona", "разбирать нечего — сразу персона")
  local req = json.encode(env.calls[#env.calls].messages)
  t.ok(has(req, "Гермиона Грейнджер") and has(req, "Хогвартс"), "в запросе персонаж и мир")
  -- новый контроллер: вопроса нет, строка действует как из конфига
  local again = bare(nil, path)
  t.ok(not in_list(texts.neutral.ru.ask, again.ctrl:opening_text()), "не переспрашивает")
  t.ok(again.ctrl:gen_due())
  t.eq(again.ctrl:begin_followup().section, "persona")
  t.eq(again.ctrl:begin(PNG).stage, "gen", "персона не готова — запись читается без образа")
end

-- не «да» — новый ответ на «Чей это дневник?»: переспрос с новым именем
function T.test_other_answer_reasks()
  local env = bare(nil)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  local other = { read = "нет, Шерлок", who = "Шерлок Холмс", world = "Бейкер-стрит", lang = "ru",
    reply = "Так это дневник Шерлока Холмса с Бейкер-стрит?" }
  local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = other })
  t.eq(text, other.reply, "новый вопрос")
  t.eq(env.mem:last_asked(), nil, "ничего не сохранено")
  t.eq(json.encode(env.ctrl:begin(PNG).messages), json.encode(prompt.setup("B64", other.reply)),
    "ответ читается уже на новый вопрос")
  -- имени нет вовсе — не «да» на названного: вопрос начинается сначала, сразу (владелец 2026-11-06, Notion 41013e60-bc8d-8133)
  local text2 = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "привет", reply = "Страницы слушают." } })
  t.ok(in_list(texts.neutral.ru.ask, text2), "снова «Чей это дневник?»: " .. tostring(text2))
  t.eq(env.ctrl:begin(PNG).messages[1].content, prompt.setup("B64")[1].content, "вопроса о персонаже больше нет")
  -- на сам «Чей это дневник?» без имени — фраза модели: вопрос уже на странице
  local fresh = bare(nil)
  t.eq(fresh.ctrl:finish(fresh.ctrl:begin(PNG), { result = { read = "привет", reply = "Страницы слушают." } }),
    "Страницы слушают.")
end

-- «нет» на «Так это дневник …?» пером — снова «Чей это дневник?», и так по кругу, пока не «да» (владелец 2026-11-06:
-- «бесконечный цикл до тех пор, пока у дневника не появится личность»; Notion 41013e60-bc8d-8133)
function T.test_pen_no_reasks_whose_until_yes()
  local env = bare(nil)
  for round = 1, 2 do
    t.eq(env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS }), ASK_ANS.reply, "круг " .. round .. ": вопрос с миром")
    local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "нет", yes = false, lang = "ru",
      reply = "Страницы слушают." } })
    t.ok(in_list(texts.neutral.ru.ask, text), "круг " .. round .. ": «нет» — снова «Чей это дневник?»: " .. tostring(text))
    t.ok(in_list(texts.neutral.ru.ask, env.ctrl:opening_text()), "круг " .. round .. ": чистая страница — тот же вопрос")
    local job = env.ctrl:begin(PNG)
    t.eq(job.stage, "ask")
    t.eq(json.encode(job.messages), json.encode(prompt.setup("B64")), "круг " .. round .. ": вопрос с миром забыт")
    t.eq(env.mem:last_asked(), nil, "ничего не сохранено")
  end
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  t.eq(env.mem:last_asked().line, HERMIONE_LINE, "«да» — личность есть")
  t.ok(not in_list(texts.neutral.ru.ask, env.ctrl:opening_text()), "больше не спрашивает")
end

-- ждущий вопрос «Так это дневник …?» переживает перезапуск KOReader: новый контроллер на той же базе задаёт тот же
-- вопрос и читает запись как ответ на него; «да» сохраняет строку персоны (Notion 41013e60-bc8d-815b)
function T.test_pending_ask_survives_restart_yes()
  local path = os.tmpname()
  local env = bare(nil, path)
  t.eq(env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS }), ASK_ANS.reply, "вопрос с миром")
  local again = bare(nil, path)
  t.eq(again.ctrl:opening_text(), ASK_ANS.reply, "после перезапуска — тот же вопрос")
  local job = again.ctrl:begin(PNG)
  t.eq(job.stage, "ask")
  t.eq(json.encode(job.messages), json.encode(prompt.setup("B64", ASK_ANS.reply)), "запись читается как ответ на него")
  again.ctrl:finish(job, { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  t.eq(again.mem:last_asked().line, HERMIONE_LINE, "«да» — строка персоны сохранена")
  t.eq(again.mem:asked_pending(), nil, "ждущий вопрос снят и в базе (ревью 5e1523b, выжившая мутация 2)")
  local third = bare(nil, path)
  t.ok(not in_list(texts.neutral.ru.ask, third.ctrl:opening_text()), "не переспрашивает")
  t.ok(third.ctrl:opening_text() ~= ASK_ANS.reply, "вопрос с миром не всплывает")
  for _, l in ipairs(again.logs) do t.ok(not has(l, "Гермиона") and not has(l, "Хогвартс"), "в лог ничего: " .. l) end
end

-- «нет» после перезапуска — снова «Чей это дневник?», ничего не сохранено; и следующий перезапуск вопроса с миром не
-- поднимает
function T.test_pending_ask_survives_restart_no()
  local path = os.tmpname()
  local env = bare(nil, path)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  local again = bare(nil, path)
  local text = again.ctrl:finish(again.ctrl:begin(PNG), { result = { read = "нет", yes = false, lang = "ru",
    reply = "Страницы слушают." } })
  t.ok(in_list(texts.neutral.ru.ask, text), "«нет» — снова «Чей это дневник?»: " .. tostring(text))
  t.eq(again.mem:last_asked(), nil, "ничего не сохранено")
  local third = bare(nil, path)
  t.ok(in_list(texts.neutral.ru.ask, third.ctrl:opening_text()), "после перезапуска — «Чей это дневник?»")
  t.eq(json.encode(third.ctrl:begin(PNG).messages), json.encode(prompt.setup("B64")), "вопрос с миром забыт")
end

-- методы Memory на время f подменены (fakes: имя -> функция); после — прежние, и при падении f
local function with_memory(fakes, f)
  local saved = {}
  for name, fn in pairs(fakes) do saved[name], memory[name] = memory[name], fn end
  local ok, err = pcall(f)
  for name, fn in pairs(saved) do memory[name] = fn end
  if not ok then error(err, 0) end
end

local function broken() error("disk I/O error", 0) end

-- хранилище ждущего вопроса сломано: вопрос живёт в процессе, как до миграции 8 — задан, «да» сохраняет строку
-- персоны; в лог — сбой, без строки персонажа (ревью 5e1523b, выжившая мутация 1)
function T.test_pending_store_failure_keeps_question_in_process()
  with_memory({ asked_pending = broken, set_asked_pending = broken, clear_asked_pending = broken }, function()
    local env = bare(nil)
    t.eq(env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS }), ASK_ANS.reply, "вопрос задан")
    t.ok(logged(env, "riddle: persona pending store failed"), "сбой записи — в лог")
    local job = env.ctrl:begin(PNG)
    t.eq(json.encode(job.messages), json.encode(prompt.setup("B64", ASK_ANS.reply)), "ответ читается на вопрос")
    env.ctrl:finish(job, { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
    t.eq(env.mem:last_asked().line, HERMIONE_LINE, "«да» — строка персоны сохранена")
    local again = bare(nil)
    t.ok(logged(again, "riddle: persona pending read failed"), "сбой чтения при старте — в лог")
    t.ok(in_list(texts.neutral.ru.ask, again.ctrl:opening_text()), "чтение упало — «Чей это дневник?»")
    for _, e in ipairs({ env, again }) do
      for _, l in ipairs(e.logs) do t.ok(not has(l, "Гермиона") and not has(l, "Хогвартс"), "в лог ничего: " .. l) end
    end
  end)
end

-- «да» не сохранилось (сбой save_asked) — вопрос ждёт и после перезапуска (ревью 5e1523b, выжившая мутация 3)
function T.test_save_failure_keeps_pending_after_restart()
  local path = os.tmpname()
  local env = bare(nil, path)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  with_memory({ save_asked = broken }, function()
    env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  end)
  t.eq(env.mem:last_asked(), nil, "ничего не сохранено")
  local again = bare(nil, path)
  t.eq(again.ctrl:opening_text(), ASK_ANS.reply, "после перезапуска — тот же вопрос с миром")
  again.ctrl:finish(again.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  t.eq(again.mem:last_asked().line, HERMIONE_LINE, "«да» теперь сохраняет")
end

-- строка конфига действует: спящий вопрос в базе не поднимается и язык нейтрального голоса не меняет — "en", пока
-- язык строки не известен, как до миграции 8 (ревью 5e1523b, пункт 4)
function T.test_sleeping_pending_ignored_while_config_line_active()
  local path = os.tmpname()
  local m = memory.open(path)
  m:set_asked_pending{ line = HERMIONE_LINE, ask = ASK_ANS.reply, lang = "ru", ts = 1 }
  m:close()
  local env = make("R2-D2 from Star Wars", path)
  t.ok(env.ctrl:texts("busy") == texts.neutral.en.thinking, "язык неизвестен — en")
end

-- «нет» на вопрос о строке конфига: строка отвергнута — дневник спрашивает «Чей это дневник?» пером, по кругу, пока
-- не «да»; ответ пером идёт тем же разбором (переспрос с миром) и действует, пока строка конфига отвергнута.
-- Новая строка в конфиге (другой ключ) снова важнее (владелец 2026-11-06, Notion 41013e60-bc8d-8133)
function T.test_config_no_reasks_whose_until_persona()
  local path = os.tmpname()
  local env = bare(R2_LINE, path)
  resolve(env, R2_OBJ)
  env.ctrl:opening_text()
  local removed = {}
  env.ctrl.deps.remove = function(p) removed[#removed + 1] = p end
  local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "no", reply = "x" } })
  t.eq(state_of(env, R2_LINE), "rejected")
  t.ok(in_list(texts.neutral.ru.ask, text), "«нет» — «Чей это дневник?»: " .. tostring(text))
  t.ok(in_list(texts.neutral.ru.ask, env.ctrl:opening_text()), "чистая страница — тот же вопрос")
  t.ok(not env.ctrl:gen_due(), "генерировать некого")
  t.eq(env.ctrl:begin_followup(), nil, "и хвоста нет")
  -- второй круг: названный пером — вопрос с миром, «нет» — снова «Чей это дневник?»
  local other = { read = "Шерлок", who = "Шерлок Холмс", world = "Бейкер-стрит", lang = "ru",
    reply = "Так это дневник Шерлока Холмса с Бейкер-стрит?" }
  local job = env.ctrl:begin(PNG)
  t.eq(job.stage, "ask", "запись — ответ на «Чей это дневник?»")
  t.eq(json.encode(job.messages), json.encode(prompt.setup("B64")))
  t.eq(env.ctrl:finish(job, { result = other }), other.reply, "разбор ответа пером — вопрос с миром")
  t.ok(in_list(texts.neutral.ru.ask, env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "нет", yes = false,
    reply = "x" } })), "второе «нет» — снова вопрос")
  t.eq(env.ctrl:begin(PNG).stage, "ask")
  -- новый персонаж и «да»: личность есть, генерация — её
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  t.ok(in_list(texts.neutral.ru.later, env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true,
    reply = "x", lang = "ru" } })), "«да» — «позже»")
  t.eq(env.mem:last_asked().line, HERMIONE_LINE)
  t.ok(env.ctrl:gen_due())
  local gjob = env.ctrl:begin_followup()
  t.eq(gjob.section, "persona")
  local req = json.encode(env.calls[#env.calls].messages)
  t.ok(has(req, "Гермиона Грейнджер") and not has(req, "R2-D2"), "генерируется названная пером, не строка конфига")
  t.eq(#removed, 6, "PNG удалён каждый раз")
  t.eq(rows_count(env, "entries"), 0, "ответы на вопрос в память не ложатся")
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "Гермиона") and not has(l, "Шерлок") and not has(l, "R2-D2"), "в лог без имён: " .. l)
  end
  -- перезапуск с той же строкой в конфиге: она отвергнута — действует сохранённая пером, вопроса нет
  local again = bare(R2_LINE, path)
  t.ok(not in_list(texts.neutral.ru.ask, again.ctrl:opening_text()), "не переспрашивает")
  again.ctrl:begin_followup()
  t.ok(has(json.encode(again.calls[#again.calls].messages), "Гермиона"), "сохранённая пером")
  -- новая строка в конфиге — снова важнее сохранённой: её разбор
  local newer = bare("Шерлок Холмс", path)
  local rjob = newer.ctrl:begin_followup()
  t.eq(rjob.section, "resolve")
  t.ok(has(json.encode(newer.calls[#newer.calls].messages), "Шерлок Холмс"), "разбирается новая строка")
end

-- мир неизвестен (строка отвергнута разбором) — тот же путь: «Чей это дневник?» пером, запись идёт в модель
function T.test_world_unknown_reasks_whose()
  local env = bare("Вася")
  local job = env.ctrl:begin_followup()
  t.eq(job.section, "resolve")
  t.eq(env.ctrl:finish_followup(job, { result = { text = resolve_json({ who = "Вася", world = "", world_named = false,
    lang = "ru" }) } }), false, "генерации нет")
  t.eq(state_of(env, "Вася"), "rejected")
  t.ok(not env.ctrl:gen_due())
  t.ok(in_list(texts.neutral.ru.ask, env.ctrl:opening_text()), "чистая страница — «Чей это дневник?»")
  local page = env.ctrl:begin(PNG)
  t.eq(page and page.stage, "ask", "запись — ответ на вопрос, модель зовётся")
  t.eq(env.ctrl:finish(page, { result = ASK_ANS }), ASK_ANS.reply)
end

-- нет сети — нейтральное «нет сети»; вопрос остаётся и повторяется со следующей записью
function T.test_ask_repeats_after_offline()
  local env = bare(nil)
  local job = env.ctrl:begin(PNG)
  local text = env.ctrl:finish(job, nil, "offline")
  t.ok(in_list(texts.neutral.en.offline, text), "нейтральное «нет сети»: " .. tostring(text))
  t.eq(env.mem:last_asked(), nil)
  local again = env.ctrl:begin(PNG)
  t.eq(again.stage, "ask", "следующая чистая страница — снова вопрос")
  -- и с вопросом в руках: сбой не забывает его
  env.ctrl:finish(again, { result = ASK_ANS })
  env.ctrl:finish(env.ctrl:begin(PNG), nil, "gemini: timeout")
  local third = env.ctrl:begin(PNG)
  t.eq(json.encode(third.messages), json.encode(prompt.setup("B64", ASK_ANS.reply)), "вопрос на месте")
  -- сбой нейтральной фразой на языке вопроса
  t.ok(in_list(texts.neutral.ru.later, env.ctrl:finish(third, nil, "gemini: timeout")), "язык вопроса — русский")
end

-- с печатью: закрытая страница — нейтральное приглашение; ключ снимает печать, вопрос идёт вместе с приветствием
function T.test_sealed_then_question()
  local env = bare(nil, nil, true)
  t.ok(in_list(texts.neutral.en.invitation, env.ctrl:opening_text()), "приглашение нейтральное")
  t.eq(env.ctrl:begin(PNG).mode, "locked", "сначала печать, потом вопрос")
  local first = env.ctrl:seal_toggle()
  local joined
  for _, w in ipairs(texts.neutral.en.welcome) do
    for _, a in ipairs(texts.neutral.en.ask) do
      if first == w .. " " .. a then joined = true end
    end
  end
  t.ok(joined, "нейтральное приветствие и вопрос одной репликой: " .. tostring(first))
  t.eq(env.ctrl:begin(PNG).stage, "ask", "теперь запись — ответ на вопрос")
end

-- строка конфига важнее сохранённой; без неё действует сохранённая
function T.test_config_line_overrides_asked()
  local path = os.tmpname()
  local env = bare(nil, path)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  -- конфиг называет другого: он и генерируется
  local cfg = bare("Шерлок Холмс", path)
  cfg.mem:add_persona{ key = persona.key("Шерлок Холмс"), line = "Шерлок Холмс", source = "config", state = "ready",
    ts = 1 }
  cfg.ctrl:begin_followup()
  local req = json.encode(cfg.calls[#cfg.calls].messages)
  t.ok(has(req, "Шерлок Холмс") and not has(req, "Гермиона"), "строка конфига важнее сохранённой")
  -- конфиг убрали: сохранённая
  local saved = bare(nil, path)
  saved.ctrl:begin_followup()
  t.ok(has(json.encode(saved.calls[#saved.calls].messages), "Гермиона"), "без конфига — сохранённая")
  -- последняя из нескольких сохранённых
  saved.mem:add_persona{ key = "позже", line = "Позже — Мир", source = "asked", state = "ready", lang = "ru", ts = 2000 }
  t.eq(saved.mem:last_asked().line, "Позже — Мир")
end

-- ответ «Методы»: встроенная персона, память и промпты «Методов», генерации нет; после перезапуска — так же, без вопроса
function T.test_methods_answer_maps_to_methods_memory()
  local path = os.tmpname()
  local env = bare(nil, path)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "Том Реддл, методы", who = "Том Реддл",
    world = "Методы рационального мышления", lang = "ru", reply = "Так это дневник Тома Реддла из «Методов»?" } })
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  local gen = env.ctrl:begin_followup()
  t.eq(gen and gen.section, "map", "генерировать — только данные карты")
  env.ctrl:finish_followup(gen, nil, "cancelled")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open", "ответы как прежде")
  t.eq(job.messages[1].content, require("fixtures.methods_map_prompts").open_empty,
    "промпт «Методов» прежний, по снимку (с блоком карты)")
  env.ctrl:finish(job, { result = { read = "ЗАПИСЬ-МЕТОДОВ", reply = "ОТВЕТ" } })
  -- в памяти персоны 1, и новый контроллер без конфига её видит
  local again = bare(nil, path)
  t.ok(not in_list(texts.neutral.ru.ask, again.ctrl:opening_text()), "не переспрашивает")
  again.mem:use_persona(persona.METHODS_ID)
  local mine = again.mem:recent(again.mem:session(again.now), 10)
  t.eq(mine[1] and mine[1].text, "ЗАПИСЬ-МЕТОДОВ", "запись — в память «Методов»")
  t.eq(again.ctrl:begin(PNG).mode, "open")
end

-- бэклог ревью задачи 5: язык нейтральных фраз персоны из вопроса — по её строке, не по cfg.whose (его нет)
function T.test_asked_persona_neutral_phrases_in_answer_language()
  local env = bare(nil)
  env.mem:add_persona{ key = persona.key(HERMIONE_LINE), line = HERMIONE_LINE, source = "asked", state = "ready",
    lang = "ru", ts = 1 }
  local job = env.ctrl:begin(PNG)
  t.eq(job.stage, "gen", "персона ещё не готова")
  t.ok(in_list(texts.neutral.ru.later, env.ctrl:finish(job, { result = { read = "привет" } })),
    "запись во время генерации — «позже» по-русски")
  t.ok(in_list(texts.neutral.ru.offline, env.ctrl:finish(env.ctrl:begin(PNG), nil, "offline")), "нет сети — по-русски")
  t.ok(in_list(texts.neutral.ru.unreadable, env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "?" } })),
    "не разобрать — по-русски")
  t.eq(env.ctrl:texts("greetings"), texts.neutral.ru.invitation, "и пул по умолчанию — по-русски")
  -- язык строки базы негоден — как неизвестный: en
  local e2 = bare(nil)
  e2.mem:add_persona{ key = persona.key(HERMIONE_LINE), line = HERMIONE_LINE, source = "asked", state = "ready",
    lang = "klingon", ts = 1 }
  t.ok(in_list(texts.neutral.en.later, e2.ctrl:finish(e2.ctrl:begin(PNG), { result = { read = "привет" } })),
    "язык не ru/en — en")
  local e3 = bare(nil)
  e3.mem:add_persona{ key = "hermione", line = "Hermione Granger", source = "asked", state = "ready", lang = "en", ts = 1 }
  t.ok(in_list(texts.neutral.en.later, e3.ctrl:finish(e3.ctrl:begin(PNG), { result = { read = "hi" } })), "en — en")
end

-- «да» на персонажа, чья строка уже есть в базе (из конфига, отвергнутая прежде): ответ пером делает её последней
-- сохранённой и готовой — иначе дневник спрашивал бы «Чей это дневник?» по кругу (ревью 0a33f27, бэклог 2, Notion 41013e60-bc8d-8132)
function T.test_yes_on_line_already_in_base_makes_it_the_saved_one()
  local path = os.tmpname()
  local seed = bare(nil, path)
  seed.mem:add_persona{ key = persona.key(HERMIONE_LINE), line = HERMIONE_LINE, source = "config", state = "rejected",
    ts = 1 }
  t.eq(seed.mem:last_asked(), nil, "из конфига — ещё не «сохранённая ответом»")
  local env = bare(nil, path)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
  local row = env.mem:last_asked()
  t.ok(row, "строка стала сохранённой ответом")
  t.eq(row.line, HERMIONE_LINE)
  t.eq(row.state, "ready")
  t.eq(rows_count(env, "personas"), 2, "новой строки не заведено — только встроенная и эта")
  local again = bare(nil, path)
  t.ok(not in_list(texts.neutral.ru.ask, again.ctrl:opening_text()), "после перезапуска не переспрашивает")
end

-- язык вопроса — ответ модели, а не язык имени: «R2-D2 — Star Wars» по-русски остаётся русской персоной, и нейтральные
-- фразы до готовности — по-русски (ревью 0a33f27, бэклог 3, Notion 41013e60-bc8d-8132)
function T.test_asked_language_comes_from_the_answer_not_from_the_name()
  local env = bare(nil)
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "R2-D2 из Star Wars", who = "R2-D2", world = "Star Wars",
    lang = "ru", reply = "Так это дневник R2-D2 из Star Wars?" } })
  env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "en" } })
  local row = env.mem:last_asked()
  t.eq(row.lang, "ru", "язык — из ответа на вопрос, не из латиницы имени")
  t.ok(in_list(texts.neutral.ru.later, env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "привет" } })),
    "и фразы до готовности — по языку строки базы, не по имени")
  -- модель язык не назвала — по имени
  local e2 = bare(nil)
  t.eq(e2.ctrl:finish(e2.ctrl:begin(PNG), { result = { read = "x", who = "R2-D2", world = "Star Wars" } }),
    "So this is the diary of R2-D2 from Star Wars?")
  local e3 = bare(nil)
  t.eq(e3.ctrl:finish(e3.ctrl:begin(PNG), { result = { read = "x", who = "Гермиона", world = "Хогвартс" } }),
    "Так это дневник Гермиона из Хогвартс?")
end

-- сбой сохранения «да» (нет таблицы или ошибка SQLite): фраза сбоя, ответ не теряется — вопрос на месте, следующее «да»
-- сохраняет (ревью 0a33f27, бэклог 4, Notion 41013e60-bc8d-8132)
function T.test_save_asked_failure_keeps_the_question_for_the_next_yes()
  for name, broken in pairs({ no_store = function() return nil end, sqlite_error = function() error("disk I/O error") end }) do
    local env = bare(nil)
    env.ctrl:finish(env.ctrl:begin(PNG), { result = ASK_ANS })
    local real = env.mem.save_asked
    env.mem.save_asked = broken
    local text = env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
    t.ok(in_list(texts.neutral.ru.later, text), name .. ": фраза сбоя, не «сохранено»: " .. tostring(text))
    t.eq(rows_count(env, "personas"), 1, name .. ": ничего не сохранено")
    t.ok(logged(env, "riddle: persona asked save failed"), name .. ": " .. table.concat(env.logs, " | "))
    t.ok(not logged(env, "riddle: persona asked saved"), name .. ": успехом не назван")
    t.eq(json.encode(env.ctrl:begin(PNG).messages), json.encode(prompt.setup("B64", ASK_ANS.reply)),
      name .. ": вопрос на месте")
    env.mem.save_asked = real
    env.ctrl:finish(env.ctrl:begin(PNG), { result = { read = "да", yes = true, reply = "x", lang = "ru" } })
    t.ok(env.mem:last_asked(), name .. ": следующее «да» сохраняет")
    for _, l in ipairs(env.logs) do t.ok(not has(l, "Гермиона"), name .. ": в лог ничего: " .. l) end
  end
end

-- сбой чтения сохранённой строки — не «хранилища нет»: страница не уходит голосом и в память «Методов» (ревью 0a33f27
-- B-1); фраза сбоя, как у строки из конфига; чтение — раз на страницу, в лог не чаще раза на страницу
function T.test_asked_read_failure_is_fail_other_not_methods()
  local path = os.tmpname()
  local setup = bare(nil, path)
  setup.mem:save_asked{ key = persona.key(HERMIONE_LINE), line = HERMIONE_LINE, lang = "ru", ts = 1 }
  local env = bare(nil, path)
  local real = env.mem.last_asked
  env.mem.last_asked = function() error("disk I/O error") end
  local job, text = env.ctrl:begin(PNG)
  t.eq(job, nil, "модель не зовётся")
  t.ok(in_list(texts.neutral.ru.later, text) or in_list(texts.neutral.en.later, text),
    "нейтральная фраза сбоя, не голос «Методов»: " .. tostring(text))
  t.ok(not in_list(texts.fail_other, text) and not in_list(texts.sleepy, text), "не «Методов»")
  t.eq(rows_count(env, "entries"), 0, "в память «Методов» ничего не легло")
  local fails = 0
  for _, l in ipairs(env.logs) do if has(l, "persona asked read failed") then fails = fails + 1 end end
  t.eq(fails, 1, "в лог — раз на страницу")
  -- чтение починено: следующая страница читает заново
  env.mem.last_asked = real
  local again = env.ctrl:begin(PNG)
  t.eq(again.stage, "gen", "сохранённая персона найдена, она ещё не готова")
end

function T.test_ask_text_template_without_world()
  t.eq(persona.ask_line("R2-D2", "", "en"), "So this is the diary of R2-D2?")
  t.eq(persona.ask_line("R2-D2", "Star Wars", "ru"), "Так это дневник R2-D2 из Star Wars?")
end

-- язык, род и имя дневника — от персонажа (план, задача 9) ------------------------------------------------------

local EN_OBJ = { head = "diary of Hermione Granger.", body = "Характер: GOLOS.", lang = "en", lang_name = "английский",
  gender = "f", kind = "записная книжка", title = "Hermione's Diary", invitation = "Who touches my pages?" }

-- персона line готова целиком: persona (EN_OBJ), world и все наборы — генерировать нечего
local function ready_full(env, line, obj)
  local key = persona.key(line)
  env.mem:add_persona{ key = key, line = line, source = "config", state = "ready" }
  local id = env.mem:persona_by_key(key).id
  env.mem:set_part(id, "persona", json.encode(obj), 1)
  env.mem:set_part(id, "world", WORLD_TEXT, 1)
  for _, name in ipairs(SET_ORDER) do env.mem:set_part(id, "texts." .. name, json.encode(phrases(36, name)), 1) end
  require("fixtures.map_parts").seed(env.mem, id, 1)
  return id
end

function T.test_title_from_persona()
  t.eq(make(METHODS_LINE).ctrl:title(), "Дневник Реддла", "«Методов» — прежнее имя меню")
  t.eq(bare(nil).ctrl:title(), "Дневник / Diary", "строки нет — вопрос «чей дневник»")
  local env = make("Гермиона Грейнджер")
  t.eq(env.ctrl:title(), "Дневник / Diary", "персоны ещё нет")
  local job = env.ctrl:begin_followup()
  env.ctrl:finish_followup(job, { result = { text = PERSONA_JSON } })
  t.eq(env.ctrl:title(), PERSONA_OBJ.title, "title персоны — как только есть раздел persona")
  -- сбой чтения не роняет меню
  env.mem.persona_by_key = function() error("db locked") end
  t.eq(env.ctrl:title(), "Дневник / Diary", "сбой — нейтральное имя")
end

function T.test_title_not_methods_without_memory()
  local env = make("Гермиона Грейнджер")
  env.ctrl.deps.memory = nil
  t.eq(env.ctrl:title(), "Дневник / Diary", "строка не «Методов», а помнить негде — не имя Реддла")
end

function T.test_title_creates_nothing()
  local env = bare("Рон Уизли")
  t.eq(env.ctrl:title(), "Дневник / Diary")
  t.eq(env.mem:persona_by_key(persona.key("Рон Уизли")), nil, "меню строку в базу не заводит")
end

function T.test_sealed_page_uses_persona_language_gender_and_kind()
  local env = make("Hermione Granger", nil, true)
  ready_full(env, "Hermione Granger", EN_OBJ)
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "locked")
  local s = job.messages[1].content
  t.ok(has(s, "английский") and has(s, "женском роде") and has(s, "Ты — записная книжка"), s)
  t.ok(not has(s, "по-русски") and not has(s, "мужском") and not has(s, "магический дневник"), s)
end

-- персонажа ещё нет (раздела persona нет; вопрос без ответа): язык записи, без рода — не «по-русски» и не «мужском»
function T.test_sealed_page_without_persona_uses_record_language()
  for name, env in pairs({ pending = make("Hermione Granger", nil, true),
      asking = bare(nil, nil, true) }) do
    local s = env.ctrl:begin(PNG).messages[1].content
    t.ok(has(s, "на языке записи") and has(s, "о себе без рода"), name .. ": " .. s)
    t.ok(not has(s, "по-русски") and not has(s, "мужском"), name .. ": нет русского и мужского")
  end
end

-- «Методов» — снимок: закрытая печать через контроллер та же, что без персон
function T.test_methods_locked_through_controller_unchanged()
  local env = make(METHODS_LINE, nil, true)
  t.eq(env.ctrl:begin(PNG).messages[1].content, prompt.locked("B64")[1].content, "закрытая печать")
end

-- пересказ прошлой сессии и свёртка текущей — голосом персонажа
function T.test_summary_and_roll_use_persona_style()
  local env = make("Hermione Granger")
  local id = ready_full(env, "Hermione Granger", EN_OBJ)
  env.mem:use_persona(id)
  local sid = env.mem:session(env.now)
  env.mem:add(sid, "owner", "ЗАП-ПРОШЛОЙ", env.now)
  env.mem:add(sid, "diary", "ОТВ-ПРОШЛОЙ", env.now)
  env.now = env.now + 5 * 3600 -- новая сессия: прошлая назрела для пересказа
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  local s = job.messages[1].content
  t.ok(has(s, "Ты — записная книжка") and has(s, "женском роде") and has(s, "английский"), s)
  t.ok(not has(s, "мужском") and not has(s, "магический дневник"), s)
  t.ok(has(job.messages[2].content, "ЗАП-ПРОШЛОЙ"), "реплики те же")
  env.ctrl:finish_followup(job, { result = { text = "пересказ" } })
  -- текущая сессия набрала окно — свёртка
  local cur = env.mem:session(env.now)
  for i = 1, controller.ROLL_AT do env.mem:add(cur, i % 2 == 0 and "diary" or "owner", "р" .. i, env.now) end
  local roll = env.ctrl:begin_followup()
  t.eq(roll and roll.kind, "roll")
  local r = roll.messages[1].content
  t.ok(has(r, "Ты — записная книжка") and has(r, "женском роде") and has(r, "английский"), r)
  t.ok(not has(r, "мужском") and not has(r, "магический дневник"), r)
end

-- «Методов»: пересказ и свёртка — прежние слова (снимок prompt_spec) и через контроллер
function T.test_methods_summary_through_controller_unchanged()
  local env = make(METHODS_LINE)
  require("fixtures.map_parts").seed(env.mem) -- данные карты «Методов» готовы: хвост — пересказ
  local sid = env.mem:session(env.now)
  env.mem:add(sid, "owner", "ЗАП-ПРОШЛОЙ", env.now)
  env.now = env.now + 5 * 3600
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  t.eq(job.messages[1].content, prompt.summarize({ { role = "owner", text = "ЗАП-ПРОШЛОЙ" } })[1].content)
end

-- «Методов»: свёртка текущей сессии через контроллер — прежние слова (системный промпт без вида персоны)
function T.test_methods_roll_through_controller_unchanged()
  local env = make(METHODS_LINE)
  require("fixtures.map_parts").seed(env.mem) -- данные карты «Методов» готовы: хвост — свёртка
  local cur = env.mem:session(env.now)
  for i = 1, controller.ROLL_AT do env.mem:add(cur, i % 2 == 0 and "diary" or "owner", "р" .. i, env.now) end
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "roll")
  t.eq(job.messages[1].content, prompt.roll(nil, {})[1].content, "свёртка «Методов»")
end

-- персонажа нет (строка ждёт ответа на вопрос о ней, раздела persona нет), а сессия есть: пересказ — язык записи, без
-- рода. Отвергнутая строка сюда не годится: она — «строки нет», дневник спрашивает «Чей это дневник?» и памяти не берёт
function T.test_summary_without_persona_uses_record_language()
  local env = bare("Hermione Granger")
  env.mem:add_persona{ key = persona.key("Hermione Granger"), line = "Hermione Granger", source = "config",
    state = "confirm", ts = 1 }
  env.mem:use_persona(env.mem:persona_by_key(persona.key("Hermione Granger")).id)
  local sid = env.mem:session(env.now)
  env.mem:add(sid, "owner", "ЗАП", env.now)
  env.now = env.now + 5 * 3600
  local job = env.ctrl:begin_followup()
  t.eq(job and job.kind, "session")
  local s = job.messages[1].content
  t.ok(has(s, "на языке записи") and has(s, "о себе без рода"), s)
  t.ok(not has(s, "мужском") and not has(s, "по-русски"), s)
end

-- карта, срез 3: фраза-открывашка читается тем же чтением страницы (prompt.MAP_FORMAT). Страница с ней при открытой
-- печати — не запись: Реддл не отвечает, в память и историю она не ложится, повод пересказа не тратится; finish
-- отдаёт действие "map". В лог — только «riddle: map phrase open», без текста страницы
function T.test_phrase_opens_map_without_memory()
  local env = make(METHODS_LINE)
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open")
  t.ok(has(job.messages[1].content, 'Ключ "map"'), "у «Методов» блок карты есть всегда")
  local entries, due = rows_count(env, "entries"), env.ctrl.followup_due
  t.eq(due, true, "повод пересказа положен с открытия")
  local text, action = env.ctrl:finish(job, { result = { read = "Торжественно клянусь", reply = "ОТВЕТ-МОДЕЛИ",
    map = "open" } })
  t.eq(text, nil, "Реддл не отвечает")
  t.eq(action, "map")
  t.eq(job.answered, nil, "свёртка не назревает")
  t.ok(not env.ctrl.roll_due, "свёртка не назначена")
  t.eq(rows_count(env, "entries"), entries, "в память не легло")
  t.eq(env.ctrl.followup_due, due, "повод пересказа не потрачен")
  t.ok(logged(env, "riddle: map phrase open"), table.concat(env.logs, " | "))
  for _, l in ipairs(env.logs) do t.ok(not has(l, "Торжественно"), "текст страницы в логе: " .. l) end
  -- не прочитано — не фраза: обычное «не разобрать»
  job = env.ctrl:begin(PNG)
  text, action = env.ctrl:finish(job, { result = { read = "?", reply = "", map = "open" } })
  t.eq(action, nil)
  t.ok(in_list(texts.unreadable, text), tostring(text))
  -- обычная страница: ответ как прежде, в память
  job = env.ctrl:begin(PNG)
  text, action = env.ctrl:finish(job, { result = { read = "ЗАПИСЬ", reply = "ОТВЕТ", map = "" } })
  t.eq(text, "ОТВЕТ")
  t.eq(action, nil)
  t.eq(rows_count(env, "entries"), entries + 2, "обычная запись — в память")
end

-- персона ещё генерируется (режим setup): фразу не понимает — открывает только роза; запись ложится как прежде
function T.test_setup_mode_ignores_map()
  local env = make("Гермиона Грейнджер")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "setup")
  t.ok(not has(json.encode(job.messages), 'Ключ \\"map\\"'), "в настройке блока карты нет")
  local text, action = env.ctrl:finish(job, { result = { read = "клянусь, что замышляю шалость", reply = "x",
    map = "open" } })
  t.eq(action, nil)
  t.ok(in_list(texts.neutral.en.later, text), tostring(text))
  t.eq(rows_count(env, "entries"), 2, "запись во время генерации — в память, как прежде")
  t.ok(not logged(env, "map phrase"))
end

-- сгенерированная персона: блок карты — только когда есть её фраза-открывашка (раздел map); без него ключ "map" в
-- ответе (модель выдумала) — обычная запись
function T.test_generated_phrase_only_with_map_section()
  local MP = require("fixtures.map_parts")
  local env = make("Гермиона Грейнджер")
  ready(env, "Гермиона Грейнджер")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open")
  t.ok(not has(job.messages[1].content, 'Ключ "map"'), "раздела map нет — блока нет")
  local text, action = env.ctrl:finish(job, { result = { read = "ЗАПИСЬ", reply = "ОТВЕТ", map = "open" } })
  t.eq(text, "ОТВЕТ")
  t.eq(action, nil)
  local id = env.mem:persona_by_key(persona.key("Гермиона Грейнджер")).id
  env.mem:set_part(id, "map", persona.section("map").decode(MP.map_json), env.now)
  job = env.ctrl:begin(PNG)
  t.ok(has(job.messages[1].content, MP.map.open), "фраза своего мира в блоке")
  text, action = env.ctrl:finish(job, { result = { read = "Скажи друг", reply = "ОТВЕТ", map = "open" } })
  t.eq(text, nil)
  t.eq(action, "map")
end

-- чтение страницы на карте: задание без образа и памяти (prompt.map_read), пустой reply не «запасной»; фраза
-- закрытия -> nil, "map"; иное, сбой — nil (без фразы сбоя: на карте не отвечают). Закрывашки нет — задания нет
function T.test_map_read_job()
  local env = make(METHODS_LINE)
  local entries = rows_count(env, "entries")
  local job = env.ctrl:map_read_job(PNG)
  t.ok(job and job.run, "задание с run для дочернего")
  local call = env.calls[#env.calls]
  t.eq(json.encode(call.messages), json.encode(prompt.map_read("B64", env.ctrl:map())), "запрос — prompt.map_read")
  t.eq(call.want_json, true)
  t.eq(call.opts and call.opts.reply_optional, true, "пустой reply не запасной")
  local text, action = env.ctrl:finish(job, { result = { read = "Шалость удалась", reply = "", map = "close" } })
  t.eq(text, nil)
  t.eq(action, "map")
  t.ok(logged(env, "riddle: map phrase close"), table.concat(env.logs, " | "))
  for _, l in ipairs(env.logs) do t.ok(not has(l, "Шалость"), "текст страницы в логе: " .. l) end
  text, action = env.ctrl:finish(job, { result = { read = "просто слова", reply = "", map = "" } })
  t.eq(text, nil)
  t.eq(action, nil)
  text, action = env.ctrl:finish(job, { result = { read = "x", reply = "", map = "open" } })
  t.eq(action, nil, "open на карте не закрывает")
  text, action = env.ctrl:finish(job, nil, "timeout")
  t.eq(text, nil, "сбой — без фразы")
  t.eq(action, nil)
  t.ok(logged(env, "riddle: map read failed: timeout"))
  t.eq(rows_count(env, "entries"), entries, "в память ничего")
  t.ok(not env.ctrl.roll_due)
  -- персона без закрывашки (раздела map нет): закрывает только роза
  local other = make("Гермиона Грейнджер")
  ready(other, "Гермиона Грейнджер")
  local n = #other.calls
  t.eq(other.ctrl:map_read_job(PNG), nil)
  t.eq(#other.calls, n, "модель не звалась")
end

-- раздел map не несёт заголовка: ответ без title годен, title в ответе модели не сохраняется
function T.test_map_decode_has_no_title()
  local MP = require("fixtures.map_parts")
  local sec = persona.section("map")
  local without = json.decode(json.encode(MP.map))
  without.title = nil
  local saved = sec.decode(json.encode(without))
  t.ok(saved, "ответ без title годен")
  t.eq(json.decode(saved).title, nil)
  local with = json.decode(json.encode(MP.map))
  with.title = "Карта Средиземья"
  local kept = sec.decode(json.encode(with))
  t.ok(kept, "лишний title в ответе — не отказ")
  t.eq(json.decode(kept).title, nil, "title не сохраняется")
end

-- срез 13а: имя владельца на карте — mapdata.of(…, owner) обрезает и ограничивает его тем же потолком, что имя героя;
-- Controller:map берёт его из owner_name (источник — срез 13б), сбой чтения — nil и строка лога без имени
function T.test_mapdata_owner_trimmed_and_capped()
  local mapdata = require("riddle.mapdata")
  t.eq(mapdata.of(nil, nil, nil, " Гарри ").owner, "Гарри", "обрезано")
  t.eq(mapdata.of(nil, nil, nil, "").owner, nil, "пустое — nil")
  t.eq(mapdata.of(nil, nil, nil, " \t ").owner, nil, "одни пробелы — nil")
  local cap = string.rep("я", mapdata.NAME_MAX)
  t.eq(mapdata.of(nil, nil, nil, cap).owner, cap, mapdata.NAME_MAX .. " знаков (кириллица — вдвое больше байт) — годится")
  t.eq(mapdata.of(nil, nil, nil, cap .. "я").owner, nil, mapdata.NAME_MAX + 1 .. " знак — nil")
  t.eq(mapdata.of(nil, nil, nil, nil).owner, nil, "имени нет")
  t.eq(mapdata.of(nil, nil, nil, 42).owner, nil, "не строка — nil")
  local env = make(METHODS_LINE)
  t.eq(env.ctrl:owner_name(), nil, "не назывался — имени нет")
  t.eq(env.ctrl:map().owner, nil, "карта без имени")
  t.eq(env.ctrl:map().open, mapdata.POTTER.ru.open, "остальные данные карты на месте")
  env.ctrl.owner_name = function() return "  Гермиона " end
  t.eq(env.ctrl:map().owner, "Гермиона", "имя из owner_name, обрезано")
  -- текст ошибки может нести имя (значение в сообщении SQLite, чужой код): в лог — ни имени, ни текста
  env.ctrl.owner_name = function() error("db locked near Гарри") end
  local m = env.ctrl:map()
  t.eq(m.owner, nil, "сбой чтения имени — книга без имени")
  t.eq(m.open, mapdata.POTTER.ru.open, "карта открывается")
  t.ok(logged(env, "riddle: owner name failed"), table.concat(env.logs, " | "))
  for _, l in ipairs(env.logs) do
    t.ok(not has(l, "Гарри") and not has(l, "db locked"), "имя или текст ошибки в логе: " .. l)
  end
end

-- имя владельца в логе — ни в каком виде (спека карты, решение 3 от 2026-11-16): ни имени, ни его части
local function no_name_logged(env, names)
  for _, l in ipairs(env.logs) do
    for _, n in ipairs(names) do t.ok(not has(l, n), "имя в логе: " .. l) end
  end
end

-- срез 13б (вариант А): ключ "name" ответа открытой печати — как пишущий назвался — ложится на текущую персону;
-- без имени, пустое, длиннее потолка имени на карте — прежнее остаётся; назвался иначе — новое. Не запись (фраза
-- карты, не разобрано) — не пишется. В лог — без значения
function T.test_answer_with_name_saves_owner_name()
  local env = make(METHODS_LINE)
  t.eq(env.ctrl:owner_name(), nil, "пока не назвался")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open")
  t.eq(env.ctrl:finish(job, { result = { read = "Меня зовут Гарри", reply = "ОТВЕТ", name = " Гарри " } }), "ОТВЕТ")
  t.eq(env.ctrl:owner_name(), "Гарри", "назвался — имя у персоны")
  t.eq(env.mem:owner_name(persona.METHODS_ID), "Гарри", "в строке «Методов»")
  t.ok(logged(env, "riddle: owner name saved"), table.concat(env.logs, " | "))
  local mapdata = require("riddle.mapdata")
  for _, v in ipairs({ false, "", string.rep("я", mapdata.NAME_MAX + 1) }) do
    job = env.ctrl:begin(PNG)
    env.ctrl:finish(job, { result = { read = "ЗАПИСЬ", reply = "ОТВЕТ", name = v or nil } })
    t.eq(env.ctrl:owner_name(), "Гарри", "не назвался (" .. tostring(v and #v) .. ") — имя прежнее")
  end
  -- не запись: фраза карты, не разобрано — имя не пишется
  job = env.ctrl:begin(PNG)
  t.eq(select(2, env.ctrl:finish(job, { result = { read = "Торжественно клянусь", reply = "x", map = "open",
    name = "Сириус" } })), "map")
  job = env.ctrl:begin(PNG)
  env.ctrl:finish(job, { result = { read = "?", reply = "", name = "Сириус" } })
  t.eq(env.ctrl:owner_name(), "Гарри", "фраза карты и неразобранное имени не меняют")
  job = env.ctrl:begin(PNG)
  env.ctrl:finish(job, { result = { read = "Вообще-то я Невилл", reply = "ОТВЕТ", name = "Невилл" } })
  t.eq(env.ctrl:owner_name(), "Невилл", "назвался иначе — новое имя")
  -- та же запись дважды (повтор ответа) — то же состояние
  env.ctrl:finish(job, { result = { read = "Вообще-то я Невилл", reply = "ОТВЕТ", name = "Невилл" } })
  t.eq(env.ctrl:owner_name(), "Невилл")
  -- сбой записи: ответ как прежде, строка лога без имени и без текста ошибки
  env.mem.set_owner_name = function() error("db locked Луна") end
  job = env.ctrl:begin(PNG)
  t.eq(env.ctrl:finish(job, { result = { read = "Я Луна", reply = "ОТВЕТ", name = "Луна" } }), "ОТВЕТ")
  t.ok(logged(env, "riddle: owner name save failed"), table.concat(env.logs, " | "))
  no_name_logged(env, { "Гарри", "Невилл", "Сириус", "Луна", "яяя" })
end

-- имя — на персону: назвался под «Методов» — у другой персоны его нет, и наоборот
function T.test_owner_name_per_persona_in_controller()
  local path = os.tmpname()
  local methods = make(METHODS_LINE, path)
  methods.ctrl:finish(methods.ctrl:begin(PNG), { result = { read = "Я Гарри", reply = "ОТВЕТ", name = "Гарри" } })
  local herm = make("Гермиона Грейнджер", path)
  ready(herm, "Гермиона Грейнджер")
  t.eq(herm.ctrl:owner_name(), nil, "у другой персоны имени нет")
  local job = herm.ctrl:begin(PNG)
  t.eq(job.mode, "open")
  herm.ctrl:finish(job, { result = { read = "Я Рон", reply = "ОТВЕТ", name = "Рон" } })
  t.eq(herm.ctrl:owner_name(), "Рон")
  t.eq(herm.ctrl:map().owner, "Рон", "на карте — имя своей персоны")
  t.eq(make(METHODS_LINE, path).ctrl:owner_name(), "Гарри", "имя «Методов» не задето")
  no_name_logged(methods, { "Гарри", "Рон" })
  no_name_logged(herm, { "Гарри", "Рон" })
end

-- имя — той персоне, чья это запись (job.persona_id), а не той, что текущая к приходу ответа: строка конфига сменилась
-- между begin и finish (ревью 13б)
function T.test_owner_name_goes_to_persona_of_job()
  local env = make(METHODS_LINE)
  ready(env, "Гермиона Грейнджер")
  local herm = env.mem:persona_by_key(persona.key("Гермиона Грейнджер")).id
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "open")
  env.ctrl.deps.cfg.whose = "Гермиона Грейнджер"
  t.eq(env.ctrl:begin(PNG).mode, "open", "теперь текущая — Гермиона")
  env.ctrl:finish(job, { result = { read = "Я Гарри", reply = "ОТВЕТ", name = "Гарри" } })
  t.eq(env.mem:owner_name(persona.METHODS_ID), "Гарри", "имя — у «Методов», чья запись")
  t.eq(env.mem:owner_name(herm), nil, "у Гермионы — нет")
  t.eq(env.ctrl:owner_name(), nil, "у текущей (Гермионы) имени нет")
  no_name_logged(env, { "Гарри" })
end

-- режим настройки (вопрос «Чей это дневник?», персона генерируется, вопрос о строке) имени не пишет: ключ "name"
-- в ответе настройки (модель выдумала) — мимо
function T.test_setup_mode_ignores_name()
  -- персона генерируется
  local env = make("Гермиона Грейнджер")
  local job = env.ctrl:begin(PNG)
  t.eq(job.mode, "setup")
  t.ok(not has(json.encode(job.messages), '\\"name\\"'), "в настройке ключа имени нет")
  env.ctrl:finish(job, { result = { read = "Меня зовут Гарри", reply = "x", name = "Гарри" } })
  t.eq(env.mem:owner_name(env.mem:persona_by_key(persona.key("Гермиона Грейнджер")).id), nil, "генерация — не пишется")
  -- вопрос «Чей это дневник?»: ответ — строка персоны, не имя владельца
  local asked = bare(nil)
  job = asked.ctrl:begin(PNG)
  t.eq(job.mode, "setup")
  asked.ctrl:finish(job, { result = { read = "Гермиона", who = "Гермиона Грейнджер", world = "Гарри Поттер",
    lang = "ru", reply = "Так это дневник Гермионы?", name = "Гарри" } })
  local n = tonumber(asked.mem.conn:rowexec("SELECT COUNT(*) FROM personas WHERE owner_name IS NOT NULL"))
  t.eq(n, 0, "вопрос — не пишется")
  -- вопрос о строке («Так это дневник …?», стадия confirm — единственная с persona_id): ответ «да» — не имя владельца
  local conf = bare("Гермиона")
  conf.mem:add_persona{ key = persona.key("Гермиона"), line = "Гермиона", source = "config", state = "confirm",
    ask = "Так это дневник Гермионы Грейнджер?", ts = conf.now }
  local id = conf.mem:persona_by_key(persona.key("Гермиона")).id
  t.eq(conf.ctrl:begin(PNG), nil, "первая страница — повод задать вопрос")
  job = conf.ctrl:begin(PNG)
  t.eq(job.mode, "setup"); t.eq(job.stage, "confirm"); t.eq(job.persona_id, id)
  conf.ctrl:finish(job, { result = { read = "да, я Гарри", yes = true, reply = "x", name = "Гарри" } })
  t.eq(conf.mem:owner_name(id), nil, "confirm — не пишется")
  t.eq(conf.mem:owner_name(persona.METHODS_ID), nil)
  no_name_logged(env, { "Гарри" })
  no_name_logged(asked, { "Гарри" })
  no_name_logged(conf, { "Гарри" })
end

-- карта берёт имя текущей персоны из базы (Controller:owner_name); вопрос «Чей это дневник?» без ответа — имени нет
function T.test_map_has_owner_name()
  local env = make(METHODS_LINE)
  t.eq(env.ctrl:map().owner, nil, "не назвался — книга без имени")
  env.mem:set_owner_name(persona.METHODS_ID, "Гарри")
  t.eq(env.ctrl:owner_name(), "Гарри")
  t.eq(env.ctrl:map().owner, "Гарри", "имя у книги")
  t.eq(env.ctrl:map().open, require("riddle.mapdata").POTTER.ru.open, "остальные данные карты на месте")
  local asked = bare(nil, env.path)
  t.eq(asked.ctrl:owner_name(), nil, "персоны нет — имени нет")
  t.eq(asked.ctrl:map().owner, nil)
  no_name_logged(env, { "Гарри" })
  no_name_logged(asked, { "Гарри" })
end

local ok, err = pcall(t.run, T)
for _, p in ipairs(paths) do os.remove(p) end
if not ok then error(err, 0) end
