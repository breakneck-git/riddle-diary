-- Дневник — без ивента 2026-10-23/24: ни квеста «шесть миров», ни рун, ни ключа, ни намёков на места
-- (решение владельца 2026-10-24: «код должен быть чистым»). Тексты ивента живут только в конфиге.
local t = require("t")

local PLUGIN = "plugin/riddlediary.koplugin"

-- блок незакрытых задач: его правила — тоже правила промпта, на них те же гарды
local TASKS_BLOCK = require("riddle.tasks").block({ { id = "a", title = "x", due = "2026-10-30", project = "y" } })
-- названия книг пишущего (раздел и правило tasks_source) — тоже правила промпта
local TITLES = { "x" }
-- сгенерированная персона (спека «чей это дневник»): её общие правила формы — те же гарды о пишущем
local GEN_VIEW = { id = 7, head = "дневник x.", body = "x.", lang = "en", lang_name = "английский", gender = "f",
  kind = "дневник", title = "x" }

-- строки режима ритма (prompt.mode_line) — правила к записи, на них те же гарды; по строке на режим
local function mode_lines()
  local prompt = require("riddle.prompt")
  local out = {}
  for _, cond in ipairs({ false, true }) do
    out[#out + 1] = prompt.mode_line("name", cond, TASKS_BLOCK.items)
    out[#out + 1] = prompt.mode_line("drift", cond, TASKS_BLOCK.items)
    out[#out + 1] = prompt.mode_line("themes", cond, { "x" })
  end
  return table.concat(out, "\n")
end

-- строки, которым имя старой таблицы нужно по делу: миграция, которая её удаляет
local ALLOWED = {
  [PLUGIN .. "/riddle/memory.lua"] = { ['[2] = { "DROP TABLE IF EXISTS quest", "DELETE FROM lore" },'] = true },
}

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- нижний регистр с кириллицей: string.lower понижает только ASCII. UTF-8: А–П D0 90–9F → D0 B0–BF,
-- Р–Я D0 A0–AF → D1 80–8F, Ё D0 81 → D1 91
local function lower(s)
  s = s:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)
  s = s:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)
  s = s:gsub("\208\129", "\209\145")
  return s:lower()
end

-- needles — Lua-шаблоны в нижнем регистре; строка сравнивается без учёта регистра
local function find_words(line, needles)
  local low, found = lower(line), {}
  for _, needle in ipairs(needles) do
    if low:find(needle) then found[#found + 1] = needle end
  end
  return found
end

-- все .lua плагина
local function plugin_sources()
  local out = {}
  local p = assert(io.popen("find " .. PLUGIN .. " -name '*.lua' | sort"))
  for path in p:lines() do out[#out + 1] = path end
  p:close()
  t.ok(#out > 5, "исходники плагина найдены")
  return out
end

-- имя хозяйки — с заглавной («Дана», «Дане», «Даны»): в нижнем регистре это слова вроде «переданы»
local function grep(paths, needles, with_name)
  local hits = {}
  for _, path in ipairs(paths) do
    local allowed, n = ALLOWED[path] or {}, 0
    for line in (assert(read(path), path) .. "\n"):gmatch("(.-)\n") do
      n = n + 1
      if not allowed[line:match("^%s*(.-)%s*$")] then
        if with_name and line:find("Дан[аеыуо]") then hits[#hits + 1] = path .. ":" .. n .. ": имя" end
        for _, w in ipairs(find_words(line, needles)) do hits[#hits + 1] = path .. ":" .. n .. ": " .. w end
      end
    end
  end
  return hits
end

-- спека и план описывают механику дневника: ни хозяйки по имени, ни ивента, ни слова и стихов печати.
-- «## Мир» — раздел шаблона lore.md, поэтому «мир» не ищем; ищем «миры»/«миров» квеста
local DOCS = { "docs/superpowers/specs/2026-10-22-riddle-diary-design.md", "docs/superpowers/plans/2026-10-22-riddle-diary-mvp.md" }
local DOCS_NEEDLES = { "ивент", "сюжет", "ролев", "квест", "руны", "миры", "миров", "хранител" }

local T = {}

function T.test_matcher_ignores_cyrillic_case()
  local needles = { "квест", "руна", "ивент", "хранител" }
  for _, line in ipairs({ "-- Квест", "«Руна» —", "ключ КВЕСТА", "ИВЕНТ", "Хранитель", "квест" }) do
    t.eq(#find_words(line, needles), 1, line)
  end
  t.eq(#find_words("Ёлка и ЁЖ", { "ёлка", "ёж" }), 2, "Ё")
  t.eq(#find_words("дневник", needles), 0)
end

-- заголовки docs с заглавной («### Квест (лор)») ловятся тем же гардом, что и плагин
function T.test_docs_guard_catches_capitalized_headings()
  for _, line in ipairs({ "### Квест (лор)", "### Руны (лор)", "Шесть Миров", "Миры хозяйки", "ИВЕНТ — 2026-10-23" }) do
    t.ok(#find_words(line, DOCS_NEEDLES) > 0, line)
  end
end

function T.test_event_modules_are_gone()
  for _, m in ipairs({ "quest", "quest_data", "runes", "lore" }) do
    t.ok(read(PLUGIN .. "/riddle/" .. m .. ".lua") == nil, "модуль ивента остался: riddle/" .. m .. ".lua")
  end
end

-- квест, руны, миры и загадки ивента
function T.test_plugin_has_no_quest_or_runes()
  local hits = grep(plugin_sources(), { "%f[%a]quest", "%f[%a]rune", "руна", "руны", "руну", "шесть миров",
    "загадк", "отсылк", "classifyrune", "strokes_dir", "квест" })
  t.eq(#hits, 0, "следы квеста в плагине:\n" .. table.concat(hits, "\n"))
end

-- персона и тексты дневника — без ведущего ивента
function T.test_plugin_has_no_event_people()
  local hits = grep(plugin_sources(), { "хранител", "ивент" }, true)
  t.eq(#hits, 0, "люди и праздник ивента в плагине:\n" .. table.concat(hits, "\n"))
end

-- дневник подходит любому, кто в нём пишет: ни «хозяйки»/«хозяина», ни обращения по роли
-- (владелец 2026-10-25: «называет меня хозяйкой … ты точно не всё еще стёр с прошлого ивента»)
function T.test_plugin_does_not_call_user_by_role()
  -- lore.md уходит в промпт открытой печати (lore_push.sh → import_lore → prompt.open)
  local paths = plugin_sources()
  paths[#paths + 1] = "lore.md"
  local hits = grep(paths, { "хозяйк", "хозяин", "хозяев" })
  t.eq(#hits, 0, "обращение по роли в плагине:\n" .. table.concat(hits, "\n"))
end

-- слово после «ты» в прошедшем времени: «ты вернулась», «ты мне писала», «ты вернулся», «ты писал» —
-- род того, кто пишет, неизвестен, прошедшее время его выдаёт
local function genders_user(s)
  -- многобайтные знаки — по одному: в классе [] их байты задели бы кириллицу
  local low = lower(s):gsub("%p", " ")
  for _, mark in ipairs({ "«", "»", "—", "–", "…" }) do low = low:gsub(mark, " ") end
  local words = {}
  for w in low:gmatch("%S+") do words[#words + 1] = w end
  for i, w in ipairs(words) do
    if w == "ты" then
      for j = i + 1, math.min(i + 3, #words) do
        local v = words[j]
        if v:find("ла$") or v:find("лась$") or v:find("л$") or v:find("лся$") then return v end
      end
    end
  end
end

function T.test_matcher_finds_gendered_user()
  t.eq(genders_user("Ты вернулся."), "вернулся")
  t.eq(genders_user("Я помню всё, о чём ты мне писал."), "писал")
  t.eq(genders_user("Ты пишешь, я слушаю."), nil)
  t.eq(genders_user("Ты вернулась."), "вернулась")
  t.eq(genders_user("Я помню всё, о чём ты мне писала."), "писала")
  t.eq(genders_user("Я устала… вернись позже."), nil, "род дневника — его голос")
  t.eq(genders_user("Ты снова здесь, я ждала."), nil)
end

-- фразы дневника пользователю — без рода пользователя (род дневника — его голос, он остаётся)
function T.test_texts_do_not_gender_the_user()
  local texts = require("riddle.texts")
  local hits = {}
  for name, v in pairs(texts) do
    for _, s in ipairs(type(v) == "table" and v or { v }) do
      if type(s) == "string" then
        local w = genders_user(s)
        if w then hits[#hits + 1] = name .. ": " .. s end
      end
    end
  end
  table.sort(hits)
  t.eq(#hits, 0, "род пользователя в текстах:\n" .. table.concat(hits, "\n"))
end

-- дневник Тома Реддла говорит о себе в мужском роде (владелец 2026-10-24: «сеттинг гарри поттера,
-- а дневник соответственно тома реддла»); женский род дневника — остаток ивента
local DIARY_FEMININE = { "рада", "ждала", "берегла", "задремала", "положила", "чувствовала", "устала",
  "уверена", "смогла", "разобрала", "разглядела", "поймала", "искала", "сказала", "прочла",
  "перевернулась", "свернулась", "ушла", "узнала" }

-- слово дневника о себе в женском роде: из списка или прошедшее на -ла/-лась в трёх словах после «я»
local function diary_feminine(s)
  local low = lower(s):gsub("%p", " ")
  for _, mark in ipairs({ "«", "»", "—", "–", "…" }) do low = low:gsub(mark, " ") end
  local words = {}
  for w in low:gmatch("%S+") do words[#words + 1] = w end
  for i, w in ipairs(words) do
    for _, f in ipairs(DIARY_FEMININE) do
      -- «печать узнала» — род печати, не дневника
      if w == f and not (f == "узнала" and words[i - 1] == "печать") then return w end
    end
    if w == "я" then
      for j = i + 1, math.min(i + 3, #words) do
        if words[j]:find("ла$") or words[j]:find("лась$") then return words[j] end
      end
    end
  end
end

function T.test_matcher_finds_feminine_diary()
  t.eq(diary_feminine("Рада тебя видеть."), "рада")
  t.eq(diary_feminine("Я слишком долго искала слова."), "искала")
  t.eq(diary_feminine("Странице стало щекотно, а слова я не поймала."), "поймала")
  t.eq(diary_feminine("Печать узнала твою руку."), nil)
  t.eq(diary_feminine("Рад тебя видеть. Я берёг каждую строчку."), nil)
end

function T.test_texts_diary_speaks_masculine()
  local texts = require("riddle.texts")
  local hits = {}
  for name, v in pairs(texts) do
    for _, s in ipairs(type(v) == "table" and v or { v }) do
      if type(s) == "string" and diary_feminine(s) then hits[#hits + 1] = name .. ": " .. s end
    end
  end
  table.sort(hits)
  t.eq(#hits, 0, "дневник о себе в женском роде:\n" .. table.concat(hits, "\n"))
end

function T.test_prompts_diary_speaks_masculine()
  local prompt = require("riddle.prompt")
  local function dump(m)
    local out = {}
    for _, msg in ipairs(m) do
      if type(msg.content) == "string" then out[#out + 1] = msg.content end
    end
    return table.concat(out, "\n")
  end
  local all = { locked = dump(prompt.locked("B64")), open = dump(prompt.open("B64", {})),
    open_knowledge = dump(prompt.open("B64", { knowledge = "x" })),
    open_sections = dump(prompt.open("B64", { knowledge = { { title = "x", total = 1, docs = { { text = "x" } } },
      { total = 1, docs = { { text = "x" } } } } })),
    open_tasks = dump(prompt.open("B64", { tasks = TASKS_BLOCK, titles = TITLES })),
    summarize = dump(prompt.summarize({ { role = "owner", text = "x" } })),
    roll = dump(prompt.roll(nil, { { role = "owner", text = "x" } })) }
  for name, s in pairs(all) do
    t.ok(not s:find("женском роде", 1, true), name .. ": «в женском роде»")
    t.ok(s:find("мужском роде", 1, true), name .. ": нет «в мужском роде»")
    for _, bad in ipairs({ "«рада»", "«ждала»", "тёплая", "ты узнала" }) do
      t.ok(not s:find(bad, 1, true), name .. ": " .. bad)
    end
  end
end

-- подсказок печати в коде нет: печать — графический ключ, слова и стихов-подсказок больше нет
function T.test_seal_texts_only_in_config()
  t.eq(require("riddle.texts").hints, nil, "texts.hints")
end

function T.test_docs_have_no_event()
  local hits = grep(DOCS, DOCS_NEEDLES, true)
  t.eq(#hits, 0, "ивент в docs:\n" .. table.concat(hits, "\n"))
end

-- «пишущий» + глагол прошедшего времени в правилах промпта (ревью 83c981a: «что пишущий утверждал» в
-- HISTORY_HEAD выдавало род): слово на -л/-ла/-лся/-лась в окне ±3 слова от «пишущ*» (и после, и до:
-- «что утверждал пишущий»); примеры в «ёлочках» не считаются. Голое «-л» — только после гласной
-- (сказал, был, ушёл), чтобы «пол» (существительное) не считался глаголом; «сказали» (мн. ч.) не род
local function past_form(v)
  return v:find("ла$") or v:find("лась$") or v:find("лся$") or v:find("[аеиыуяё]л$") or v == "был"
end

local function genders_writer(s)
  local low = lower(s):gsub("«.-»", " "):gsub("%p", " ")
  for _, mark in ipairs({ "«", "»", "—", "–", "…" }) do low = low:gsub(mark, " ") end
  local words = {}
  for w in low:gmatch("%S+") do words[#words + 1] = w end
  for i, w in ipairs(words) do
    if w:find("^пишущ") then
      for j = math.max(1, i - 3), math.min(i + 3, #words) do
        if j ~= i and past_form(words[j]) then return w .. " " .. words[j] end
      end
    end
  end
end

function T.test_matcher_finds_writer_past()
  for _, s in ipairs({ "что пишущий утверждал", "пишущий написал", "что пишущий сказал", "пишущая спросила",
    "пишущему говорил" }) do
    t.ok(genders_writer(s), s)
  end
  -- обратный порядок: глагол прошедшего времени до «пишущ*»
  for _, s in ipairs({ "что утверждал пишущий", "то, что сказал пишущий", "спросила у пишущей" }) do
    t.ok(genders_writer(s), s)
  end
  t.eq(genders_writer("что сказано в записях пишущего"), nil)
  t.eq(genders_writer("О пишущем не говори в прошедшем времени («ты написал»)"), nil, "пример в ёлочках")
  t.eq(genders_writer("пол пишущего тебе неизвестен"), nil)
  t.eq(genders_writer("пишущему сказали"), nil, "мн. ч. — не род")
  t.eq(genders_writer("пишущему сказали, что"), nil)
  t.eq(genders_writer("стол пишущего"), nil, "существительное на -л")
end

function T.test_prompts_do_not_gender_writer_in_past()
  local prompt = require("riddle.prompt")
  local recent = { { role = "owner", text = "x" }, { role = "diary", text = "y" } }
  local all = { locked = prompt.locked("B64")[1].content,
    open = prompt.open("B64", { recent = recent, knowledge = "x", summaries = { "x" }, lore = "x",
      tasks = TASKS_BLOCK, titles = TITLES })[1].content,
    open_sealed = prompt.open("B64", { sealed = true, recent = recent })[1].content,
    open_gen = prompt.open("B64", { persona = GEN_VIEW, recent = recent })[1].content,
    setup = prompt.setup("B64", "x")[1].content,
    modes = mode_lines(),
    locked_gen = prompt.locked("B64", GEN_VIEW)[1].content,
    summarize = prompt.summarize({ { role = "owner", text = "x" } })[1].content,
    summarize_gen = prompt.summarize({ { role = "owner", text = "x" } }, nil, GEN_VIEW)[1].content,
    roll = prompt.roll(nil, { { role = "owner", text = "x" } })[1].content,
    roll_gen = prompt.roll(nil, { { role = "owner", text = "x" } }, GEN_VIEW)[1].content }
  for name, s in pairs(all) do
    local w = genders_writer(s)
    t.eq(w, nil, name .. ": «" .. tostring(w) .. "» — прошедшее время о пишущем")
  end
end

-- краткое прилагательное или причастие при «ты» — тоже род (тестер 2026-10-25, 12:27:05: «сколько ты
-- готова просчитать» — пишущий сам написал о себе «НАШЛА», модель подхватила): шаблонная краткая форма в
-- том же предложении, что и «ты» (до . ! ? или конца строки); примеры в «ёлочках» — это само правило
local SHORT_FORMS = {}
for _, w in ipairs({ "готов", "готова", "рад", "рада", "уверен", "уверена", "прав", "права", "должен", "должна",
  "способен", "способна", "согласен", "согласна", "доволен", "довольна", "свободен", "свободна", "занят",
  "занята", "один", "одна", "одинок", "одинока", "счастлив", "счастлива", "похож", "похожа", "знаком",
  "знакома", "умён", "умен", "умна", "смел", "смела", "честен", "честна", "нужен", "нужна" }) do
  SHORT_FORMS[w] = true
end
-- «права» после этих слов — существительное («ты имеешь права»)
local HAVE = { "имеешь", "иметь", "имеет" }
for _, w in ipairs(HAVE) do HAVE[w] = true end

local STOP = "ккконец" -- граница предложения — отдельным словом

local function short_form_of_writer(s)
  local low = lower(s):gsub("«.-»", " "):gsub("[%.!%?\n]", " " .. STOP .. " "):gsub("%p", " ")
  for _, mark in ipairs({ "«", "»", "—", "–", "…" }) do low = low:gsub(mark, " ") end
  local words = {}
  for w in low:gmatch("%S+") do words[#words + 1] = w end
  local from = 1 -- начало текущего предложения
  for i, w in ipairs(words) do
    if w == STOP then
      from = i + 1
    elseif w == "ты" then
      local to = i
      while to < #words and words[to + 1] ~= STOP do to = to + 1 end
      for j = from, to do
        local f = words[j]
        if SHORT_FORMS[f] and not (f == "права" and HAVE[words[j - 1]]) then return "ты " .. f end
      end
    end
  end
end

function T.test_matcher_finds_short_forms_of_writer()
  for _, s in ipairs({ "Сколько ты готова просчитать?", "Готов ли ты платить цену?", "Ты, кажется, права.",
    "ты уверен в этом", "Рада ли ты?" }) do
    t.ok(short_form_of_writer(s), s)
  end
  t.eq(short_form_of_writer("Не пиши о нём «готов» или «готова»: ты не знаешь пола."), nil, "примеры в ёлочках")
  t.eq(short_form_of_writer("Я готов слушать."), nil, "род дневника — его голос")
  t.eq(short_form_of_writer("Ты готовишь ход."), nil, "глагол, не краткая форма")
  t.eq(short_form_of_writer("Хватит ли тебе духу?"), nil)
end

-- окно — всё предложение с «ты» (до . ! ? или конца строки), а не ±3 слова: вставное «как и все» отодвигает
-- краткую форму дальше трёх слов; «права» после «имеешь» — существительное
function T.test_matcher_window_is_sentence()
  for _, s in ipairs({ "Ты, как и все, должна выбрать.", "Ты, кажется, по-прежнему уверена." }) do
    t.ok(short_form_of_writer(s), s)
  end
  for _, s in ipairs({ "Ты имеешь права.", "Тебе нужна сила.", "Я готов." }) do
    t.eq(short_form_of_writer(s), nil, s)
  end
  t.eq(short_form_of_writer("Ты пришёл. Она готова."), nil, "другое предложение")
  t.eq(short_form_of_writer("Ты пришёл\nОна готова"), nil, "другая строка")
end

function T.test_prompts_have_no_short_forms_of_writer()
  local prompt = require("riddle.prompt")
  local recent = { { role = "owner", text = "x" }, { role = "diary", text = "y" } }
  local all = { locked = prompt.locked("B64")[1].content,
    open = prompt.open("B64", { recent = recent, knowledge = "x", summaries = { "x" }, lore = "x",
      tasks = TASKS_BLOCK, titles = TITLES })[1].content,
    open_sealed = prompt.open("B64", { sealed = true, recent = recent })[1].content,
    open_gen = prompt.open("B64", { persona = GEN_VIEW, recent = recent })[1].content,
    setup = prompt.setup("B64", "x")[1].content,
    modes = mode_lines(),
    locked_gen = prompt.locked("B64", GEN_VIEW)[1].content,
    summarize = prompt.summarize({ { role = "owner", text = "x" } })[1].content,
    summarize_gen = prompt.summarize({ { role = "owner", text = "x" } }, nil, GEN_VIEW)[1].content,
    roll = prompt.roll(nil, { { role = "owner", text = "x" } })[1].content,
    roll_gen = prompt.roll(nil, { { role = "owner", text = "x" } }, GEN_VIEW)[1].content }
  for name, s in pairs(all) do
    local w = short_form_of_writer(s)
    t.eq(w, nil, name .. ": «" .. tostring(w) .. "» — краткая форма о пишущем")
  end
end

-- правило рода называет краткие формы и не подхватывает род, которым пишущий говорит о себе сам
function T.test_gender_rule_covers_short_forms_and_writer_own_gender()
  local prompt = require("riddle.prompt")
  for name, s in pairs({ locked = prompt.locked("B64")[1].content, open = prompt.open("B64", {})[1].content,
      open_gen = prompt.open("B64", { persona = GEN_VIEW })[1].content }) do
    t.ok(s:find("краткие прилагательные и причастия", 1, true), name .. ": краткие формы — тоже род")
    for _, w in ipairs({ "«готов»", "«готова»", "«уверен»", "«уверена»", "«прав»", "«права»" }) do
      t.ok(s:find(w, 1, true), name .. ": пример " .. w)
    end
    t.ok(s:find("не подхватывай", 1, true), name .. ": род, которым пишущий говорит о себе, не подхватывается")
  end
end

-- образец замены краткой формы — не вопрос (ревью 1b1134e: «хватит ли тебе духу»; урок у NO_GENDER —
-- примеры-вопросы превращали каждый ответ во встречный вопрос): ни «?», ни «ли» в правиле о кратких формах
function T.test_short_form_rule_examples_are_not_questions()
  local prompt = require("riddle.prompt")
  for name, s in pairs({ locked = prompt.locked("B64")[1].content, open = prompt.open("B64", {})[1].content }) do
    local rule = s:match("Род выдают и краткие.-Даже если пишущий")
    t.ok(rule, name .. ": правило о кратких формах на месте")
    rule = rule or ""
    t.ok(not rule:find("?", 1, true), name .. ": «?» в образце: " .. rule)
    t.ok(not (" " .. lower(rule):gsub("%p", " ") .. " "):find(" ли ", 1, true), name .. ": «ли» в образце: " .. rule)
  end
end

-- род пишущего через «сам/самого», ласковые обращения («дорогой», «друг мой») и «он/его» о пишущем в
-- правилах промпта (ревью a5d8720: «Напиши о том, что волнует тебя самого», «Напиши мне, мой дорогой
-- друг», «Ты сам знаешь…» гарды пропускали). Запрещённые формы в «ёлочках» — это примеры в самом правиле
local USER_WORDS = { "сам", "сама", "самого", "самой", "самому", "самим", "самих",
  "дорогой", "дорогая", "дорогого", "дорогую", "милый", "милая" }
local USER_PAIRS = { "друг мой", "мой друг", "подруга моя", "моя подруга" }
local PRONOUNS = { "он", "его", "нём", "ему", "него", "нему" }

local COMMA = "ккомма" -- запятая — отдельным словом: обращение отделено запятой
local function words_of(s, drop_quoted)
  local low = lower(s)
  if drop_quoted then low = low:gsub("«.-»", " ") end
  low = low:gsub(",", " " .. COMMA .. " ")
  low = low:gsub("%p", " ")
  for _, mark in ipairs({ "«", "»", "—", "–", "…" }) do low = low:gsub(mark, " ") end
  local words = {}
  for w in low:gmatch("%S+") do words[#words + 1] = w end
  return words
end

-- «сам/самой/дорогой» — о пишущем только рядом с «ты/тебя/тебе» или в обращении после запятой:
-- «в самой глубине», «шёл дорогой» — не о нём
local NEAR_USER = { ["ты"] = true, ["тебя"] = true, ["тебе"] = true, ["тобой"] = true, [COMMA] = true,
  ["мой"] = true, ["моя"] = true }

local function user_form(s, drop_quoted, extra)
  local words = words_of(s, drop_quoted)
  local bad, any = {}, {}
  for _, w in ipairs(USER_WORDS) do bad[w] = true end
  for _, w in ipairs(extra or {}) do any[w] = true end
  for i, w in ipairs(words) do
    if any[w] then return w end
    if bad[w] and (NEAR_USER[words[i - 1] or ""] or NEAR_USER[words[i - 2] or ""]) then return w end
    local pair = w .. " " .. (words[i + 1] or "")
    for _, p in ipairs(USER_PAIRS) do if pair == p then return pair end end
  end
end

function T.test_matcher_finds_user_forms()
  t.eq(user_form("Напиши о том, что волнует тебя самого."), "самого")
  t.eq(user_form("Напиши мне, мой дорогой друг."), "дорогой")
  t.eq(user_form("Ты сам знаешь…"), "сам")
  t.eq(user_form("Расскажи, друг мой, что тебя тревожит."), "друг мой")
  t.eq(user_form("Не называй его «сам» или «сама».", true), nil, "пример в ёлочках — не обращение")
  t.eq(user_form("Не называй его «сам».", true, PRONOUNS), "его", "о пишущем — без «его»")
  t.eq(user_form("Я ждал тебя."), nil)
  t.eq(user_form("Я храню это в самой глубине страниц."), nil, "«самой» не о пишущем")
  t.eq(user_form("Он шёл дорогой, которой никто не ходит."), nil, "«дорогой» — путь")
  t.eq(user_form("Я сам удивлён."), nil, "«сам» о дневнике")
end

function T.test_texts_have_no_user_forms()
  local texts = require("riddle.texts")
  local hits = {}
  for name, v in pairs(texts) do
    for _, s in ipairs(type(v) == "table" and v or { v }) do
      if type(s) == "string" and user_form(s) then hits[#hits + 1] = name .. ": " .. s end
    end
  end
  table.sort(hits)
  t.eq(#hits, 0, "обращения с родом в текстах:\n" .. table.concat(hits, "\n"))
end

-- правила промпта говорят о пишущем без «он/его», запретные формы — только примерами в ёлочках
function T.test_prompts_have_no_user_forms()
  local prompt = require("riddle.prompt")
  local all = { locked = prompt.locked("B64")[1].content, open = prompt.open("B64", {})[1].content,
    open_sealed = prompt.open("B64", { sealed = true })[1].content,
    open_knowledge = prompt.open("B64", { knowledge = "x" })[1].content,
    open_sections = prompt.open("B64", { knowledge = { { title = "x", total = 1, docs = { { text = "x" } } },
      { total = 1, docs = { { text = "x" } } } } })[1].content,
    open_tasks = prompt.open("B64", { tasks = TASKS_BLOCK, titles = TITLES })[1].content,
    open_history = prompt.open("B64", { recent = { { role = "owner", text = "x" } } })[1].content,
    modes = mode_lines(),
    locked_gen = prompt.locked("B64", GEN_VIEW)[1].content,
    summarize = prompt.summarize({ { role = "owner", text = "x" } })[1].content,
    summarize_gen = prompt.summarize({ { role = "owner", text = "x" } }, nil, GEN_VIEW)[1].content,
    roll = prompt.roll(nil, { { role = "owner", text = "x" } })[1].content,
    roll_gen = prompt.roll(nil, { { role = "owner", text = "x" } }, GEN_VIEW)[1].content }
  for name, s in pairs(all) do
    local w = user_form(s, true, PRONOUNS)
    t.eq(w, nil, name .. ": «" .. tostring(w) .. "» о пишущем")
  end
  local s = all.open
  for _, w in ipairs({ "«самого»", "«дорогой»", "«друг мой»" }) do
    t.ok(s:find(w, 1, true), "правило запрещает " .. w)
  end
end

t.run(T)
