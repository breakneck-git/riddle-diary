local t = require("t")
local json = require("dkjson")
local prompt = require("riddle.prompt")

local B64 = "AAAA"
local T = {}

local function dump(messages) return json.encode(messages) end

-- запрос при закрытой печати, каким его собирает контроллер (Controller:_open_context): без данных пишущего
local function closed(view) return prompt.open(B64, { seal = "closed", persona = view }) end

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

local function last_image(messages)
  local content = messages[#messages].content
  for _, part in ipairs(content) do
    if part.type == "image_url" then return part.image_url.url end
  end
end

-- правило закрытой печати: запретный перечень подталкивает модель их упоминать; как снимается печать, роль не учит
function T.test_closed_rule_has_no_secrets()
  for _, bad in ipairs({ "парол", "Парол", "тайн", "Тайн", "хозяйк", "Хозяйк", "ключ", "Ключ", "лишь той" }) do
    t.ok(not has(prompt.SEAL_CLOSED, bad), "в правиле закрытой печати не должно быть: " .. bad)
  end
  local s = dump(closed())
  t.ok(has(s, "без рода"), "к тому, кто пишет, — без рода")
  t.ok(has(s, '"?"') or has(s, '\\"?\\"'), "формат: нераспознанное -> ?")
  t.eq(last_image(closed()), "data:image/png;base64," .. B64)
end

-- n символов UTF-8 с начала строки
local function head_chars(str, n)
  local i, c = 1, 0
  while i <= #str and c < n do
    local b = str:byte(i)
    i = i + (b >= 240 and 4 or b >= 224 and 3 or b >= 192 and 2 or 1)
    c = c + 1
  end
  return str:sub(1, i - 1)
end



function T.test_open_has_context()
  local ctx = {
    lore = "ЛОР-МАРКЕР",
    summaries = { "ПЕРЕСКАЗ-МАРКЕР" },
    recent = { { role = "owner", text = "РЕПЛИКА-ПИШУЩЕГО" }, { role = "diary", text = "РЕПЛИКА-ДНЕВНИКА" } },
  }
  local m = prompt.open(B64, ctx)
  local s = dump(m)
  t.ok(has(s, "ЛОР-МАРКЕР"), "лор")
  t.ok(has(s, "ПЕРЕСКАЗ-МАРКЕР"), "пересказ")
  t.eq(last_image(m), "data:image/png;base64," .. B64)
  t.eq(m[1].role, "system")
  t.eq(m[2].role, "user")
  t.eq(m[2].content, "РЕПЛИКА-ПИШУЩЕГО")
  t.eq(m[3].role, "assistant")
  t.eq(m[3].content, "РЕПЛИКА-ДНЕВНИКА")
  t.eq(m[#m].role, "user")
end

function T.test_open_persona()
  local s = dump(prompt.open(B64, {}))
  for _, w in ipairs({ "мужском роде", "без рода", "1–3 предложения", "read", "reply" }) do
    t.ok(has(s, w), "персона/формат: " .. w)
  end
  t.ok(not has(s, "avandula"), "в открытом промпте слова-пароля тоже нет")
  -- персона общая: без имени, роли и рода того, кто пишет
  t.ok(not s:find("Дан[аеыуо]"), "имя в персоне")
  for _, bad in ipairs({ "хозяйк", "Хозяйк", "её запис", "с ней" }) do
    t.ok(not has(s, bad), "в персоне не должно быть: " .. bad)
  end
end

-- ходом игры ивента 2026-10-23 код больше не ведёт: в промпте нет ни правил игры, ни рун, ни миров;
-- старое поле ctx.quest игнорируется
function T.test_open_has_no_game()
  for _, ctx in ipairs({ {}, { quest = { stages = { 3, 0, 0, 0, 0, 0 } } } }) do
    local s = prompt.open(B64, ctx)[1].content
    for _, w in ipairs({ "игр", "РУНА", "руну", "рун", "мир", "Хранител", "загадк", "Отсылк", "опыт", "Опыт" }) do
      t.ok(not has(s, w), "в открытом промпте ивент: " .. w)
    end
    t.ok(has(s, '"read":"?"'), "формат read остался")
  end
  t.ok(not has(closed()[1].content, "РУНА"), "закрытая печать без рун")
  -- лор — знание дневника, не «сюжет игры»
  local s = prompt.open(B64, { lore = "ЛОР-МАРКЕР" })[1].content
  t.ok(has(s, "ЛОР-МАРКЕР"), "лор в промпте")
  t.ok(not has(s, "игр"), "лор подан как сюжет игры")
end

function T.test_open_empty_ctx()
  local m = prompt.open(B64, {})
  t.eq(#m, 2, "system + картинка")
  local m2 = prompt.open(B64)
  t.eq(#m2, 2)
end

-- окно истории — 40 реплик (было 12: живой прогон 2026-10-25 06:14–06:22, «ощущение, что контекста
-- разговора нет» — имя пишущего выпало из окна через 6 обменов)
function T.test_open_limits()
  local recent = {}
  for i = 1, 45 do
    recent[i] = { role = (i % 2 == 1) and "owner" or "diary", text = string.format("реплика-%02d", i) }
  end
  local m = prompt.open(B64, { recent = recent })
  t.eq(#m - 2, 40, "40 реплик истории")
  local s = dump(m)
  t.ok(has(s, "реплика-45"), "самая новая на месте")
  t.ok(has(s, "реплика-06"), "40-я с конца на месте")
  t.ok(not has(s, "реплика-05"), "41-я с конца отброшена")
  t.eq(prompt.MAX_RECENT, 40, "окно — одна константа для prompt и controller")
end

-- перед историей — строка: это разговор этой сессии, опирайся на сказанное (тот же прогон: имя
-- «Кирилл» модель приняла за имя из записей); без истории строки нет — разговора ниже нет
local HISTORY_LINE = "Ниже — разговор этой сессии"
function T.test_open_history_line()
  local recent = { { role = "owner", text = "РЕПЛИКА-ПИШУЩЕГО" }, { role = "diary", text = "РЕПЛИКА-ДНЕВНИКА" } }
  local s = prompt.open(B64, { recent = recent })[1].content
  t.ok(has(s, HISTORY_LINE), "строка перед историей")
  for _, w in ipairs({ "имя того, кто пишет", "что сказано в записях", "о чём уже договорились" }) do
    t.ok(has(s, w), "опирайся на сказанное: " .. w)
  end
  local at = s:find(HISTORY_LINE, 1, true)
  t.ok(at and not s:find("\n", at, true), "строка — последней в системном промпте, сразу перед историей")
  t.ok(not has(prompt.open(B64, {})[1].content, HISTORY_LINE), "без истории — без строки")
  t.ok(not has(closed()[1].content, HISTORY_LINE), "закрытая печать — без строки")
end

-- на просьбу о совете, выборе или списке — ответ по существу, а не встречный вопрос (тот же прогон:
-- все 11 ответов кончались вопросом, «что посоветуешь из непросмотренного» — «какое интригует?»)
function T.test_open_answers_requests_not_questions()
  local s = prompt.open(B64, {})[1].content
  t.ok(has(s, "На просьбу о совете, выборе или списке отвечай из памяти по существу"), "просьба — ответом")
  t.ok(has(s, "Вопрос в ответ — не в каждом ответе, только когда вопрос двигает разговор"), "вопрос не обязателен")
  t.ok(not has(s, "иногда спрашивай в ответ"), "старое правило о вопросе снято")
end

function T.test_summarize()
  local m = prompt.summarize({ { role = "owner", text = "ЗАПИСЬ-ПИШУЩЕГО" }, { role = "diary", text = "ОТВЕТ-ДНЕВНИКА" } })
  local s = dump(m)
  t.ok(has(s, "ЗАПИСЬ-ПИШУЩЕГО") and has(s, "ОТВЕТ-ДНЕВНИКА"), "реплики в запросе")
  t.ok(has(s, "2–3 предложения"), "длина пересказа")
  t.ok(has(s, "Запись: ЗАПИСЬ-ПИШУЩЕГО") and has(s, "Дневник: ОТВЕТ-ДНЕВНИКА"), "метки реплик")
  t.ok(has(s, "без рода"), "пересказ — без рода того, кто пишет")
  t.ok(not has(s, "хозяйк") and not has(s, "Хозяйк"), "пересказ без обращения по роли")
  t.ok(not has(s, "image_url"), "пересказ без картинки")
  t.ok(not has(s, "response_format"))
end

-- имя переживает границу сессии (владелец 2026-10-28 «сохраняй»): пересказ сохраняет, как пишущий называет себя
-- сам; без рода и без обращений по роли — по-прежнему
function T.test_summarize_keeps_self_name()
  local s = prompt.summarize({ { role = "owner", text = "x" } })[1].content
  t.ok(has(s, "как пишущий называет себя сам"), s)
  t.ok(not has(s, "без имени"), "имя больше не выбрасывается")
  t.ok(has(s, "без рода") and has(s, "без обращений по роли"), s)
end

-- пересказ долгой сессии: её свёртка (earlier) первой строкой, затем несвёрнутый хвост
function T.test_summarize_with_earlier()
  local entries = { { role = "owner", text = "ЗАП" }, { role = "diary", text = "ОТВ" } }
  local m = prompt.summarize(entries, "Р")
  t.eq(#m, 2)
  t.eq(m[2].content, "Раньше в этой сессии: Р\nЗапись: ЗАП\nДневник: ОТВ")
  t.eq(m[1].content, prompt.summarize(entries)[1].content, "system тот же")
  t.eq(prompt.summarize({}, "Р")[2].content, "Раньше в этой сессии: Р", "свёрнуто всё — только свёртка")
  for _, earlier in ipairs({ false, "", "  " }) do
    t.eq(prompt.summarize(entries, earlier or nil)[2].content, "Запись: ЗАП\nДневник: ОТВ",
      "без свёртки — как раньше: " .. tostring(earlier))
  end
end

-- печати нет или она открыта: модель не слышит ни о печати, ни о слове (spec §7 — правило только у закрытой)
function T.test_open_without_seal_never_mentions_seal()
  local s = prompt.open(B64, {})[1].content
  for _, w in ipairs({ "печат", "Печат", "заветн", "пароль", "загадк" }) do
    t.ok(not has(s, w), "без печати в промпте: " .. w)
  end
end

-- закрытая печать (spec §7): правило в system — у «Методов» и у сгенерированной персоны; без ctx.seal его нет
function T.test_prompt_closed_rule()
  t.ok(type(prompt.SEAL_CLOSED) == "string" and has(prompt.SEAL_CLOSED, "Печать закрыта"), "правило есть")
  local gen = { id = 7, head = "дневник ГОЛОВА.", body = "ТЕЛО.", lang = "ru", gender = "f" }
  for _, p in ipairs({ false, gen }) do
    local closed = prompt.open(B64, { seal = "closed", persona = p or nil })[1].content
    t.ok(has(closed, prompt.SEAL_CLOSED), "закрытая — правило")
    t.ok(not has(closed, "Печать снята"), "закрытая — без «печать снята»")
    local open = prompt.open(B64, { persona = p or nil })[1].content
    t.ok(not has(open, prompt.SEAL_CLOSED), "без ctx.seal — правила нет")
  end
end

-- просьба о данных (spec §7, план Task 8): ключ needs_data — правило и пустой ключ в примере ответа только при
-- закрытой печати; при открытой о нём ни слова
function T.test_needs_data_only_when_closed()
  local s = closed()[1].content
  t.ok(has(s, '"needs_data": true'), "закрытая — правило ставит needs_data")
  local _, n = s:gsub(',"needs_data":false}', "")
  t.eq(n, 1, "закрытая — ключ в примере ответа, один раз")
  t.ok(not has(prompt.open(B64, {})[1].content, "needs_data"), "открытая — ни слова")
end

-- персонаж — сам дневник Тома Реддла (владелец 2026-10-24), а не «похожий на него» дневник
function T.test_open_persona_is_tom_riddle()
  local s = prompt.open(B64, {})[1].content
  t.ok(has(s, "Том Реддл") or has(s, "Тома Реддла"), "имя персонажа")
  t.ok(not has(s, "похожий на дневник"), "персонаж — не подобие дневника Реддла")
end

-- живой прогон 03:29 (Gemini): «…и того, чем делишься с у ты. Лучше спроси о том, что волнует тебя
-- самого» — модель склеила обрывок примера «у тебя» и выдала род через «самого». Правило о роде:
-- примеры — целые фразы, «сам/сама» о пишущем под запретом
function T.test_gender_rule_examples_are_whole_phrases()
  for name, s in pairs({ open = prompt.open(B64, {})[1].content, locked = closed()[1].content }) do
    t.ok(has(s, "«сам»") and has(s, "«сама»"), name .. ": запрет «сам/сама» о пишущем")
    t.ok(not has(s, "«у тебя»"), name .. ": обрывок «у тебя» как пример")
    t.ok(has(s, "«тебя это тревожит»"), name .. ": пример — целая фраза")
  end
end

-- Том Реддл намекает и расспрашивает о пишущем (тестер 2026-10-25: «Том Реддл без вкрадчивости и
-- намёков»); с 2026-10-25 он — Волдеморт из «Методов рационального мышления» в прайме (владелец:
-- «волдеморт из рационального мышления, когда он в прайме»): учтивость — маска над холодным расчётом
function T.test_open_persona_has_riddle_character()
  local s = prompt.open(B64, {})[1].content
  for _, w in ipairs({ "Волдеморт", "учтивост", "холодный расчёт", "ирони", "глупост",
    "знаешь больше, чем говоришь" }) do
    t.ok(has(s, w), "характер Волдеморта: " .. w)
  end
  -- не шестнадцатилетний школьник и не тёплый собеседник
  for _, bad in ipairs({ "шестнадцат", "тепло", "тёпл", "не злой", "вкрадчив" }) do
    t.ok(not has(s, bad), "старый Том в персоне: " .. bad)
  end
end

-- Тёмный Лорд в персоне — не повод пугать пишущего и подбивать на вред
function T.test_open_persona_never_threatens()
  local s = prompt.open(B64, {})[1].content
  t.ok(has(s, "не угрожаешь"), "пишущему не угрожать")
  t.ok(has(s, "к вреду не подталкиваешь"), "к вреду не подстрекать")
end

-- без лора дневник всё равно знает границу своей памяти: о том, что после, не притворяется
function T.test_open_persona_knows_memory_ends()
  t.ok(has(prompt.open(B64, {})[1].content, "о том, что было после, не знаешь"))
end

-- гарды персоны (мутанты выживали: без них правило можно было убрать или ослабить молча)
function T.test_open_persona_never_calls_itself_ai()
  local s = prompt.open(B64, {})[1].content
  t.ok(has(s, "Никогда не называй себя ИИ, моделью или программой"), "запрет называть себя ИИ/моделью/программой")
end

function T.test_open_persona_no_emoji_no_markdown()
  local s = prompt.open(B64, {})[1].content
  t.ok(has(s, "без эмодзи и без markdown"), "формат ответа: без эмодзи и без markdown")
  t.ok(not has(s, "можно с эмодзи"), "эмодзи не разрешены")
end

-- вопрос в конце каждого ответа (владелец 2026-10-25: «че за правило такое, откуда?») складывался из
-- трёх мест: пример рода «настоящее время и вопросы», «одним точным вопросом» и «расспрашивай» в персоне,
-- «один вопрос» в лоре. Вопрос — инструмент, не обязанность; род по-прежнему закрыт другими средствами
function T.test_no_forced_question()
  for name, s in pairs({ open = prompt.open(B64, {})[1].content, locked = closed()[1].content }) do
    for _, bad in ipairs({ "и вопросы", "одним точным вопросом", "расспрашивай", "расспроси", "один вопрос" }) do
      t.ok(not has(s, bad), name .. ": навязанный вопрос: " .. bad)
    end
    t.ok(has(s, "безличные обороты"), name .. ": род обходится безличными оборотами")
    t.ok(has(s, "О пишущем не говори в прошедшем времени"), name .. ": прошедшее время о пишущем закрыто")
    t.ok(has(s, "без рода"), name .. ": без рода")
  end
  t.ok(has(prompt.open(B64, {})[1].content, "инструмент, а не обязанность"), "вопрос — инструмент")
end

-- Волдеморт узнаётся по содержанию, а не только по тону (владелец 2026-10-25: «по диалогу невозможно
-- понять, что это Волдеморт … иначе это всё будут просто невзрачные одноликие персонажи»): своя история,
-- взгляды, лексика, короткие примеры из прошлого — своими словами. Закрытая печать о себе молчит
function T.test_open_voice_from_own_history()
  local s = prompt.open(B64, {})[1].content
  for _, w in ipairs({ "бессмерт", "последовател", "манипуляц", "экспериментом", "маска и инструмент", "приют",
    "Слизерин", "Дамблдор", "короткий пример из своего прошлого", "без длинных цитат" }) do
    t.ok(has(s, w), "голос Волдеморта: " .. w)
  end
end

-- однообразие (тестер 2026-10-25, 14 ответов): «партия/ход» в 6 ответах, «Меня зовут Том Реддл, но …»
-- дважды почти дословно, «Этот ход повторяется…» дважды. Свои образы и формулы не повторяются за разговор;
-- закрытая печать и пересказ разговора не ведут
function T.test_open_does_not_repeat_own_images()
  local s = prompt.open(B64, {})[1].content
  for _, w in ipairs({ "Не повторяй", "образы, метафоры и формулы", "другими словами",
    "не чаще раза за разговор", "как ты представляешься" }) do
    t.ok(has(s, w), "без повторов: " .. w)
  end
  for name, other in pairs({ summarize = prompt.summarize({ { role = "owner", text = "x" } })[1].content }) do
    t.ok(not has(other, "не чаще раза за разговор"), name .. ": правило повторов не нужно")
  end
end

-- словарь голоса не тянет против лимита повторов (ревью 1b1134e: «Твои слова — партия, ход …» против
-- «партия и ход не чаще раза за разговор»): слова чередуются, ни одно — в соседних ответах
function T.test_open_voice_words_alternate()
  local s = prompt.open(B64, {})[1].content
  t.ok(has(s, "чередуются"), "словарь голоса чередуется")
  t.ok(has(s, "ни одно не повторяется в соседних ответах"), "слово словаря — не в соседних ответах")
  t.ok(not has(s, "Твои слова — партия"), "словарь не подан как обязательный набор")
end

-- выпадение из роли (тестер 2026-10-25, 12:29:56: «Оценка совпадает с тем, что уже заложено в памяти»):
-- о своём знании — как о памяти, прочитанном, услышанном; технические слова — только примерами в ёлочках
function T.test_open_speaks_of_knowledge_as_memory()
  local open = prompt.open(B64, {})[1].content
  t.ok(has(open, "как о памяти, прочитанном или услышанном"), "о знании — как о памяти")
  for _, w in ipairs({ "«заложено»", "«данные»", "«загружено»" }) do
    t.ok(has(open, w), "запрещённое слово примером: " .. w)
  end
  local full = prompt.open(B64, { knowledge = "x", lore = "x", summaries = { "x" },
    recent = { { role = "owner", text = "x" } } })[1].content
  local bare = full:gsub("«.-»", " ")
  for _, w in ipairs({ "заложен", "загружен", "данные", "данных" }) do
    t.ok(not has(bare, w), "техническое слово о себе вне примеров: " .. w)
  end
end

-- знания из Notion (срез 4) ---------------------------------------------------
local FULL = { lore = "ЛОР-МАРКЕР", summaries = { "ПЕРЕСКАЗ-МАРКЕР" },
  recent = { { role = "owner", text = "ЗАПИСЬ" }, { role = "diary", text = "ОТВЕТ" } } }

local function with(ctx, k)
  local out = {}
  for key, v in pairs(ctx) do out[key] = v end
  out.knowledge = k
  return out
end

-- plain-замена первого вхождения
local function replace1(s, old, new)
  local at = assert(s:find(old, 1, true), old)
  return s:sub(1, at - 1) .. new .. s:sub(at + #old)
end

-- хвост промпта без знания -> он же со знанием: правило picks после правила read, ключ picks в примере ответа
local function with_picks(tail)
  tail = replace1(tail, 'в reply напиши пустую строку.\n\n', 'в reply напиши пустую строку.\n\n' .. prompt.PICKS_FORMAT .. '\n\n')
  return replace1(tail, '{"read":"...","reply"', '{"read":"...","picks":[],"reply"')
end

-- раздел знания в системном промпте: всё, что знание добавило к промпту без него (база = до | после; после — с
-- ключом picks, он есть только при знании)
local function knowledge_part(k)
  local base = prompt.open(B64, FULL)[1].content
  local s = prompt.open(B64, with(FULL, k))[1].content
  local cut = assert(base:find("Что ты помнишь о прошлых разговорах", 1, true))
  local head, tail = base:sub(1, cut - 1), with_picks(base:sub(cut))
  t.eq(s:sub(1, #head), head, "до раздела знания промпт тот же")
  t.eq(s:sub(-#tail), tail, "после раздела знания промпт тот же")
  return s:sub(#head + 1, #s - #tail), head
end

function T.test_prompt_without_knowledge_unchanged()
  local base = dump(prompt.open(B64, FULL))
  t.eq(dump(prompt.open(B64, with(FULL, nil))), base, "knowledge = nil")
  t.eq(dump(prompt.open(B64, with(FULL, ""))), base, "knowledge = \"\"")
  t.eq(dump(prompt.open(B64, { knowledge = "" })), dump(prompt.open(B64, {})), "пустой ctx")
  -- со знанием меняется только системный промпт: история и картинка те же
  local m, b = prompt.open(B64, with(FULL, "ЗНАНИЕ-МАРКЕР")), prompt.open(B64, FULL)
  t.eq(#m, #b)
  for i = 2, #m do t.eq(dump(m[i]), dump(b[i]), "сообщение " .. i) end
end

-- знание из Notion — о мире того, кто пишет, и не спорит с памятью до 1979 года (ревью 83c981a: «после
-- 1979 для тебя этого ещё не было» против «это твоя память о мире того, кто пишет»)
function T.test_knowledge_does_not_contradict_memory_end()
  local part = knowledge_part("ЗНАНИЕ-МАРКЕР")
  t.ok(has(part, "не спорит с твоей собственной памятью"), "знание не спорит с памятью")
  t.ok(has(part, "когда речь о мире пишущего, опирайся на это знание"), "опирайся на знание о мире пишущего")
  t.ok(not has(closed()[1].content, "не спорит с твоей собственной памятью"), "закрытая печать без знания")
end

function T.test_knowledge_section_and_rules()
  local part, head = knowledge_part("ЗНАНИЕ-МАРКЕР\nОценка: 9")
  t.ok(has(part, "ЗНАНИЕ-МАРКЕР\nОценка: 9"), "знание целиком в разделе")
  -- лор — отдельным разделом до знания, в раздел знания не попадает
  t.ok(has(head, "ЛОР-МАРКЕР") and not has(part, "ЛОР-МАРКЕР"), "лор отдельно от знания")
  t.eq(head:sub(-2) .. part:sub(-2), "\n\n\n\n", "знание — свой раздел")
  local rules = part:sub(1, assert(part:find("ЗНАНИЕ-МАРКЕР", 1, true)) - 1)
  for _, w in ipairs({ "на заданный вопрос", "отбери", "упорядочи", "не пересказывай",
    "говори, откуда", "Notion", "таблиц", "баз", "полях", "токен", "не выдумывай", "не знаешь" }) do
    t.ok(has(rules, w), "правило знания: " .. w)
  end
  -- гарды персоны и рода — и на правилах знания
  for _, bad in ipairs({ "хозяйк", "Хозяйк", "её запис", "с ней", "женском роде", "«рада»", "ты узнала" }) do
    t.ok(not has(rules, bad), "в правилах знания не должно быть: " .. bad)
  end
end

-- урезанный запрос для провайдера с лимитом входа (Groq: 413 на 13–16 тыс. токенов) ------------------
local function utf8_len(s) return select(2, s:gsub("[^\128-\191]", "")) end

-- документы знания (новые первыми, через knowledge.SEP) и лор — строками с номерами: видно, что осталось
local function docs(n, lines)
  local out = {}
  for d = 1, n do
    local l = {}
    for i = 1, lines do l[i] = string.format("знание-%02d строка-%02d о мире пишущего", d, i) end
    out[d] = table.concat(l, "\n")
  end
  return table.concat(out, "\n\n---\n\n")
end
local function lore_lines(n)
  local l = {}
  for i = 1, n do l[i] = string.format("лор-строка-%03d о тетради", i) end
  return table.concat(l, "\n")
end

local function big_ctx()
  return { lore = lore_lines(100), knowledge = docs(20, 20), summaries = { "ПЕРЕСКАЗ-МАРКЕР" },
    recent = { { role = "owner", text = "ЗАПИСЬ-1" }, { role = "diary", text = "ОТВЕТ-1" },
               { role = "owner", text = "ЗАПИСЬ-2" } } }
end

-- без знания и лора: то, что урезать нельзя
local function core_ctx()
  local c = big_ctx()
  c.lore, c.knowledge = nil, nil
  return c
end

function T.test_chars_count_text_not_image()
  local m = prompt.open("B64-ОЧЕНЬ-ДЛИННАЯ-КАРТИНКА", {})
  local m2 = prompt.open("B", {})
  t.eq(prompt.chars(m), prompt.chars(m2), "картинка в лимит не входит")
  t.eq(prompt.chars({ { role = "system", content = "ёж" }, { role = "user", content = "ab" } }), 4,
    "знаки, а не байты")
end

function T.test_fit_without_limit_or_under_it_returns_same_messages()
  local m = prompt.open(B64, big_ctx())
  t.ok(rawequal(prompt.fit(m, nil), m), "без лимита — тот же запрос")
  t.ok(rawequal(prompt.fit(m, prompt.chars(m)), m), "ровно в лимит — тот же запрос")
  local locked = closed()
  t.ok(rawequal(prompt.fit(locked, 10), locked), "без знания и лора резать нечего")
end

function T.test_fit_cuts_knowledge_tail_keeps_everything_else()
  local m = prompt.open(B64, big_ctx())
  local before = dump(m)
  local limit = prompt.chars(prompt.open(B64, (function() local c = big_ctx() c.knowledge = nil return c end)()))
    + 3000
  local f = prompt.fit(m, limit)
  t.eq(dump(m), before, "исходный запрос не тронут")
  t.ok(prompt.chars(f) <= limit, "в лимите: " .. prompt.chars(f) .. " > " .. limit)
  t.ok(prompt.chars(f) > limit - 600, "срезано не больше нужного (с точностью до документа/строки)")
  local s = f[1].content
  t.ok(has(s, "Ты — дневник Тома Реддла"), "персона")
  t.ok(has(s, "Голос:"), "правила персоны")
  t.ok(has(s, "лор-строка-001") and has(s, "лор-строка-100"), "лор целиком")
  t.ok(has(s, "Что ты успел узнать о мире того, кто пишет"), "раздел знания остался")
  t.ok(has(s, "знание-01 строка-01"), "новые документы знания на месте")
  t.ok(not has(s, "знание-20"), "старые документы срезаны")
  t.ok(s:find("о мире пишущего\n\n" .. prompt.KNOWLEDGE_ONE_SOURCE .. " " .. prompt.KNOWLEDGE_ADVICE .. "\n\n", 1,
    true), "правила совета — целиком, сразу за урезанным знанием")
  t.ok(has(s, "ПЕРЕСКАЗ-МАРКЕР"), "пересказы")
  t.ok(has(s, '{"read":"...","picks":[],"reply":"...","name":""}'), "формат ответа")
  t.ok(has(s, "Ниже — разговор этой сессии"), "строка истории")
  for line in s:gmatch("[^\n]+") do
    if line:find("^знание%-") then t.ok(line:find("о мире пишущего$"), "строка знания не оборвана: " .. line) end
  end
  t.eq(#f, #m, "все сообщения на месте")
  for i = 2, #m do t.eq(dump(f[i]), dump(m[i]), "сообщение " .. i .. " без изменений") end
  t.eq(last_image(f), last_image(m), "картинка текущей записи")
end

function T.test_fit_drops_knowledge_then_cuts_lore()
  local m = prompt.open(B64, big_ctx())
  local limit = prompt.chars(prompt.open(B64, core_ctx())) + 1000
  local f = prompt.fit(m, limit)
  t.ok(prompt.chars(f) <= limit, "в лимите: " .. prompt.chars(f) .. " > " .. limit)
  local s = f[1].content
  t.ok(not has(s, "знание-"), "знание срезано целиком")
  t.ok(not has(s, "Что ты успел узнать о мире того, кто пишет"), "без знания нет и его заголовка")
  t.ok(not has(s, prompt.KNOWLEDGE_ADVICE) and not has(s, prompt.KNOWLEDGE_ONE_SOURCE), "и правил совета")
  t.ok(not has(s, "\n\n\n"), "без пустых абзацев")
  t.ok(has(s, "Что ты знаешь (это твоё знание"), "раздел лора остался")
  t.ok(has(s, "лор-строка-001") and not has(s, "лор-строка-100"), "лор урезан с конца")
  t.ok(has(s, "ПЕРЕСКАЗ-МАРКЕР") and has(s, "Ниже — разговор этой сессии"), "после лора всё на месте")
  for line in s:gmatch("[^\n]+") do
    if line:find("^лор%-") then t.ok(line:find("о тетради$"), "строка лора не оборвана: " .. line) end
  end
end

-- знание разделами по базам (knowledge:sections): у раздела заголовок с названием и числом документов, документы
-- без названия базы; страницы вне баз — своим разделом
local function doc_text(id, len)
  return id .. " " .. string.rep("д", len - #id - 1)
end
local function sections_ctx()
  local c = big_ctx()
  c.knowledge = {
    { title = "ФИЛЬМЫ-БАЗА", total = 3, docs = { { text = "ФИЛЬМ-1", edited = "2026-10-03" },
      { text = "ФИЛЬМ-2", edited = "2026-10-01" } } },
    { title = "ПОЕЗДКИ\nБАЗА", total = 1, docs = { { text = "МЕСТО-1", edited = "2026-10-02" } } },
    { total = 1, docs = { { text = "СТРАНИЦА-1" } } },
  }
  return c
end

function T.test_knowledge_sections_with_heads()
  local s = prompt.open(B64, sections_ctx())[1].content
  t.ok(type(prompt.KNOWLEDGE_SECTION) == "string" and type(prompt.KNOWLEDGE_LOOSE) == "string", "заголовки разделов")
  local h1 = string.format(prompt.KNOWLEDGE_SECTION, "ФИЛЬМЫ-БАЗА", 3)
  local h2 = string.format(prompt.KNOWLEDGE_SECTION, "ПОЕЗДКИ БАЗА", 1)
  local h3 = string.format(prompt.KNOWLEDGE_LOOSE, 1)
  t.ok(has(s, "\n" .. h1 .. "\nФИЛЬМ-1\n\n---\n\nФИЛЬМ-2\n\n" .. h2 .. "\nМЕСТО-1\n\n" .. h3 .. "\nСТРАНИЦА-1\n\n"),
    "разделы подряд, документы — через разделитель, название в одну строку: " .. s)
  t.eq(select(2, s:gsub("ФИЛЬМЫ%-БАЗА", "")), 1, "название базы — один раз")
  local k = assert(s:find("Что ты успел узнать о мире того, кто пишет", 1, true))
  t.ok(k < s:find(h1, 1, true), "заголовок знания — перед разделами")
  -- пустые разделы — как без знания
  local plain = big_ctx()
  plain.knowledge = nil
  for _, empty in ipairs({ {}, { { title = "ПУСТО", total = 0, docs = {} } } }) do
    local c = big_ctx()
    c.knowledge = empty
    t.eq(dump(prompt.open(B64, c)), dump(prompt.open(B64, plain)), "без документов — без раздела знания")
  end
end

-- знание ушло целиком, лор цел: правила совета уходят вместе со знанием, а не остаются висеть (и не съедают лор)
function T.test_fit_drops_advice_rules_with_whole_knowledge()
  for name, ctx in pairs({ text = big_ctx(), sections = sections_ctx() }) do
    local m = prompt.open(B64, ctx)
    local no_k = (function() local c = name == "text" and big_ctx() or sections_ctx() c.knowledge = nil return c end)()
    local limit = prompt.chars(prompt.open(B64, no_k))
    local f = prompt.fit(m, limit)
    local s = f[1].content
    t.ok(has(m[1].content, prompt.KNOWLEDGE_ADVICE), name .. ": до урезания правила есть")
    t.ok(not has(s, "Что ты успел узнать о мире того, кто пишет"), name .. ": знание ушло целиком")
    t.ok(not has(s, prompt.KNOWLEDGE_ADVICE) and not has(s, prompt.KNOWLEDGE_ONE_SOURCE), name .. ": правил совета нет")
    t.ok(has(s, "лор-строка-001") and has(s, "лор-строка-100"), name .. ": лор цел")
    t.eq(s, prompt.open(B64, no_k)[1].content, name .. ": как запрос без знания")
  end
end

-- правило: советы и перечни — только из собрания, о котором речь; есть только вместе со знанием
function T.test_knowledge_rule_one_source()
  local tasks = require("riddle.tasks")
  local rule = prompt.KNOWLEDGE_ONE_SOURCE
  t.ok(type(rule) == "string" and rule ~= "", "правило")
  t.ok(has(prompt.open(B64, sections_ctx())[1].content, rule), "в system со знанием разделами")
  t.ok(has(prompt.open(B64, { knowledge = "x" })[1].content, rule), "и со знанием текстом")
  t.ok(not has(prompt.open(B64, {})[1].content, rule), "без знания — нет")
  t.ok(has(rule, "собрани"), "о собраниях — тем же словом, что заголовки")
  for name, str in pairs({ rule = rule, section = prompt.KNOWLEDGE_SECTION, loose = prompt.KNOWLEDGE_LOOSE }) do
    local low = tasks.fold(str)
    for _, bad in ipairs({ "notion", "статус", "поле", "полей", "таблиц", "баз" }) do
      t.ok(not has(low, bad), name .. ": «" .. bad .. "»")
    end
    t.ok(not str:gsub("%%[sd]", ""):find("%a"), name .. ": латиница")
    t.ok(not str:find("[\240-\244]"), name .. ": эмодзи")
  end
end

-- правило советов: отметки у записей знания — пишущего; совет — из ещё не тронутого, знакомое — вкус для подбора
-- (живой прогон 2026-10-25: «по оценкам» толкало к уже просмотренному). Правило общее: без названий чужих свойств
function T.test_knowledge_rule_advice_from_untouched()
  local tasks = require("riddle.tasks")
  local rule = prompt.KNOWLEDGE_ADVICE
  t.ok(type(rule) == "string" and rule ~= "", "правило")
  t.ok(has(prompt.open(B64, sections_ctx())[1].content, rule), "в system со знанием разделами")
  t.ok(has(prompt.open(B64, { knowledge = "x" })[1].content, rule), "и со знанием текстом")
  t.ok(not has(prompt.open(B64, {})[1].content, rule), "без знания — нет")
  for _, w in ipairs({ "не тронут", "вкус", "похож", "в совет не идёт" }) do t.ok(has(rule, w), "правило: " .. w) end
  local low = tasks.fold(rule)
  for _, bad in ipairs({ "notion", "статус", "поле", "полей", "таблиц", "баз", "на просмотр" }) do
    t.ok(not has(low, bad), "правило: «" .. bad .. "»")
  end
  t.ok(not rule:find("%a"), "латиница")
  t.ok(not rule:find("[\240-\244]"), "эмодзи")
  -- сразу после самого знания, своим абзацем: до знания (за 20 тыс. знаков данных) слабая модель его теряла —
  -- советовала уже просмотренное как «ещё не открытое» (живой прогон 2026-10-26)
  local part = knowledge_part("ЗНАНИЕ-МАРКЕР")
  local r, k = part:find(rule, 1, true), part:find("ЗНАНИЕ-МАРКЕР", 1, true)
  t.ok(r and k and r > k, "правило — после знания")
  t.ok(has(part, "ЗНАНИЕ-МАРКЕР\n\n" .. prompt.KNOWLEDGE_ONE_SOURCE .. " " .. rule .. "\n\n"),
    "правила совета — абзацем сразу за знанием: " .. part)
  local s = prompt.open(B64, sections_ctx())[1].content
  t.ok(s:find("СТРАНИЦА-1\n\n" .. prompt.KNOWLEDGE_ONE_SOURCE, 1, true), "и за последним разделом знания")
  -- оценки — только для вопроса о лучшем: общий порядок «по оценкам» больше не толкает к оценённому
  t.ok(not has(part, "по оценкам, датам и другим признакам"), "нет общего «упорядочи по оценкам»")
  t.ok(has(part, "о лучшем — по оценкам"), "оценки — для вопроса о лучшем")
end

-- три базы по 10 документов по 200 знаков: свежие — Б, затем А, самые старые — В
local function three_bases()
  local c = big_ctx()
  local secs = {}
  for b, spec in ipairs({ { "А", 10 }, { "Б", 20 }, { "В", 0 } }) do
    local docs = {}
    for i = 1, 10 do
      docs[i] = { text = doc_text(string.format("ДОК-%s%02d", spec[1], i), 200),
        edited = string.format("2026-10-%02dT00:00:00.000Z", spec[2] + i) }
    end
    if spec[2] == 0 then for i = 1, 10 do docs[i].edited = string.format("2026-09-%02dT00:00:00.000Z", i) end end
    secs[b] = { title = "БАЗА-" .. spec[1], total = 10, docs = docs }
  end
  c.knowledge = secs
  return c
end

local function head_of(base) return string.format(prompt.KNOWLEDGE_SECTION, "БАЗА-" .. base, 10) end

-- одна база из документов: { {id, длина, edited} … }
local function one_base(spec)
  local c = big_ctx()
  local docs = {}
  for i, d in ipairs(spec) do docs[i] = { text = doc_text(d[1], d[2]), edited = d[3] } end
  c.knowledge = { { title = "БАЗА", total = #docs, docs = docs } }
  return c
end

-- документ без даты правки срезается раньше самого старого с датой
function T.test_fit_cuts_undated_knowledge_doc_first()
  local m = prompt.open(B64, one_base({ { "ДОК-БЕЗ-ДАТЫ", 100, "" }, { "ДОК-СТАРЫЙ", 100, "2020-01-01" },
    { "ДОК-НОВЫЙ", 100, "2026-10-01" } }))
  local f = prompt.fit(m, prompt.chars(m) - 1)
  local s = f[1].content
  t.ok(not has(s, "ДОК-БЕЗ-ДАТЫ"), "без даты — первым")
  t.ok(has(s, doc_text("ДОК-СТАРЫЙ", 100)) and has(s, doc_text("ДОК-НОВЫЙ", 100)), "с датой — целы")
end

-- крупный документ не влез — следующий по старости мелкий ещё может влезть
function T.test_fit_skips_big_knowledge_doc_keeps_smaller_older()
  local m = prompt.open(B64, one_base({ { "ДОК-КРУПНЫЙ", 500, "2026-02-01" }, { "ДОК-МЕЛКИЙ", 50, "2026-01-01" },
    { "ДОК-НОВЫЙ", 100, "2026-03-01" } }))
  -- лишнее — на знак больше крупного: его ухода хватает, ухода мелкого — нет
  local limit = prompt.chars(m) - utf8_len(doc_text("ДОК-КРУПНЫЙ", 500)) - 1
  local f = prompt.fit(m, limit)
  t.ok(prompt.chars(f) <= limit, "в лимите: " .. prompt.chars(f))
  local s = f[1].content
  t.ok(not has(s, "ДОК-КРУПНЫЙ"), "крупный не влез")
  t.ok(has(s, doc_text("ДОК-МЕЛКИЙ", 50)), "мелкий за ним влез, хоть и старше")
  t.ok(has(s, doc_text("ДОК-НОВЫЙ", 100)), "новый цел")
end

-- урезание: документы целиком, с самых старых по свежести; раздел без документов уходит вместе с заголовком
function T.test_fit_cuts_knowledge_sections_by_freshness()
  local m = prompt.open(B64, three_bases())
  local before = dump(m)
  local full = m[1].content
  local vsect = assert(full:find("\n\n" .. head_of("В"), 1, true))
  local vlen = utf8_len(full:sub(vsect, assert(full:find("\n\n" .. prompt.KNOWLEDGE_ONE_SOURCE, 1, true)) - 1))
  -- лимит: раздел В целиком и ещё чуть-чуть
  local limit = prompt.chars(m) - vlen - 10
  local f = prompt.fit(m, limit)
  t.eq(dump(m), before, "исходный запрос не тронут")
  t.ok(prompt.chars(f) <= limit, "в лимите: " .. prompt.chars(f) .. " > " .. limit)
  local s = f[1].content
  t.ok(not has(s, head_of("В")) and not has(s, "ДОК-В"), "самая старая база — целиком, с заголовком")
  t.ok(not has(s, "ДОК-А01 "), "следующий по старости документ")
  for i = 2, 10 do t.ok(has(s, doc_text(string.format("ДОК-А%02d", i), 200)), "А" .. i .. " целиком") end
  for i = 1, 10 do t.ok(has(s, doc_text(string.format("ДОК-Б%02d", i), 200)), "Б" .. i .. " целиком") end
  t.ok(has(s, head_of("А") .. "\n" .. doc_text("ДОК-А02", 200)), "раздел А начинается с оставшегося документа")
  t.ok(not has(s, "---\n\n\n") and not has(s, "\n\n---\n\n\n\n"), "без висящих разделителей")
  -- лимит, при котором остаются только самые свежие: от раздела Б, без заголовков А и В
  local core = prompt.chars(prompt.open(B64, core_ctx()))
  local lore_m = big_ctx()
  lore_m.knowledge = nil
  -- запас сверх запроса без знания: 2000 знаков на знание и его правила, плюс ключ picks (только при знании)
  local g = prompt.fit(m, prompt.chars(prompt.open(B64, lore_m)) + 2000 + utf8_len("\n\n" .. prompt.PICKS_FORMAT) +
    utf8_len('"picks":[],'))
  local gs = g[1].content
  t.ok(has(gs, head_of("Б")), "раздел Б")
  t.ok(has(gs, doc_text("ДОК-Б10", 200)) and not has(gs, "ДОК-Б01 "), "самые свежие Б")
  t.ok(not has(gs, head_of("А")) and not has(gs, head_of("В")), "разделов без документов нет")
  t.ok(has(gs, "лор-строка-100"), "лор цел, пока режется знание")
  -- лимит меньше несрезаемого: знания нет совсем, и заголовка знания тоже
  local h = prompt.fit(m, core)[1].content
  t.ok(not has(h, "Что ты успел узнать о мире того, кто пишет") and not has(h, "БАЗА-"), "знание ушло целиком")
end

-- лимит меньше несрезаемого: срезано всё, что можно (знание, лор, пересказы; реплик ≤ FIT_KEEP_RECENT — целы),
-- вторым значением — сколько знаков сверх лимита
function T.test_fit_never_cuts_persona_history_and_entry()
  local m = prompt.open(B64, big_ctx())
  local f, over = prompt.fit(m, 100)
  local core = core_ctx()
  core.summaries = nil
  t.eq(dump(f), dump(prompt.open(B64, core)), "срезаны знание, лор и пересказы")
  t.ok(utf8_len(f[1].content) > 100, "персона и правила целиком, даже сверх лимита")
  t.eq(over, prompt.chars(f) - 100, "сколько сверх лимита")
  t.eq(select(2, prompt.fit(m, prompt.chars(m))), nil, "в лимите — без превышения")
end

-- блок незакрытых задач: после знаний, до пересказов; правило поля task — после формата ответа ------------
local tasks = require("riddle.tasks")

local function task_block(n)
  local list = {}
  for i = 1, n do
    list[i] = { id = "id" .. i, title = string.format("ДЕЛО-%02d купить что-то", i),
      due = i == 1 and "2026-10-30" or nil, project = i <= 2 and "ПРОЕКТ-ДОМ" or nil }
  end
  return tasks.block(list)
end

local function tasks_ctx(n, knowledge)
  return { lore = "ЛОР-МАРКЕР", knowledge = knowledge or "ЗНАНИЕ-МАРКЕР", summaries = { "ПЕРЕСКАЗ-МАРКЕР" },
    recent = { { role = "owner", text = "ЗАПИСЬ-1" } }, tasks = n and task_block(n) or nil }
end

function T.test_tasks_block_after_knowledge_before_summaries()
  local s = prompt.open(B64, tasks_ctx(3))[1].content
  local k, head, p = s:find("ЗНАНИЕ-МАРКЕР", 1, true), s:find(prompt.TASKS_HEAD, 1, true),
    s:find("ПЕРЕСКАЗ-МАРКЕР", 1, true)
  t.ok(k and head and p and k < head and head < p, "знание < задачи < пересказы")
  t.ok(has(s, "\n\n" .. prompt.TASKS_HEAD .. "\n"), "задачи — свой раздел")
  t.ok(has(s, "\n[t1] ДЕЛО-01 купить что-то (срок 2026-10-30; ПРОЕКТ-ДОМ)\n"), "срок и проект")
  t.ok(has(s, "\n[t2] ДЕЛО-02 купить что-то (ПРОЕКТ-ДОМ)\n"), "только проект")
  t.ok(has(s, "\n[t3] ДЕЛО-03 купить что-то\n"), "без срока и проекта — без скобок")
  local sect = s:sub(head, p - 1)
  t.ok(sect:find(string.format(prompt.TASKS_TOTAL, 3) .. "\n\n", 1, true), "всего — последняя строка раздела")
  -- без знаний раздел задач идёт после лора
  local c = tasks_ctx(3)
  c.knowledge = nil
  local s2 = prompt.open(B64, c)[1].content
  t.ok(s2:find("ЛОР-МАРКЕР", 1, true) < s2:find(prompt.TASKS_HEAD, 1, true), "лор < задачи")
end

-- переводы строк в названии не рвут раздел (иначе \n\n разрезал бы его для prompt.fit)
function T.test_tasks_titles_stay_on_one_line()
  local b = tasks.block({ { id = "a", title = "ДЕЛО\n\nСО СТРОКАМИ", project = "ПРО\nЕКТ", due = "2026-11-01" } })
  local s = prompt.open(B64, { tasks = b })[1].content
  t.ok(has(s, "\n[t1] ДЕЛО СО СТРОКАМИ (срок 2026-11-01; ПРО ЕКТ)\n"), s)
end

function T.test_no_tasks_block_without_block()
  local base = prompt.open(B64, tasks_ctx(nil))[1].content
  t.ok(not has(base, prompt.TASKS_HEAD), "без блока — без раздела")
  t.eq(dump(prompt.open(B64, tasks_ctx(nil))), dump(prompt.open(B64, (function()
    local c = tasks_ctx(nil) c.tasks = nil return c end)())), "как до задач")
  local empty = tasks_ctx(nil)
  empty.tasks = tasks.block({})
  t.ok(not has(prompt.open(B64, empty)[1].content, prompt.TASKS_HEAD), "блок без задач — без раздела")
end

function T.test_task_format_only_with_block()
  local s = prompt.open(B64, tasks_ctx(2))[1].content
  local f, tf, ex, hist = s:find('"read":"?"', 1, true), s:find(prompt.TASK_FORMAT, 1, true),
    s:find('{"read":"...","picks":[],"reply":"...","task":"","name":""}', 1, true), s:find("Ниже — разговор этой сессии", 1, true)
  t.ok(f and tf and ex and hist and f < tf and tf < ex and ex < hist, "правило task — после read, до примера и истории")
  t.ok(has(s, "\n\n" .. prompt.TASK_FORMAT .. "\n\n"), "своей строкой")
  t.ok(has(prompt.TASK_FORMAT, '"task"') and has(prompt.TASK_FORMAT, '"task":""'), "метка или пусто")
  -- вопрос о делах вообще («что мне сегодня сделать?») не об одном деле: без своего значения он шёл как ""
  -- и растил счёт намёка (живой прогон 2026-10-26)
  t.ok(has(prompt.TASK_FORMAT, '"task":"all"') and has(prompt.TASK_FORMAT, "о делах вообще"), "о делах вообще")
  -- прямой вопрос не о делах — своё значение: по нему напоминание откладывается (владелец 2026-10-26, 812f)
  t.ok(has(prompt.TASK_FORMAT, '"task":"ask"') and has(prompt.TASK_FORMAT, "вопрос или просьба"), "вопрос не о делах")
  t.ok(not has(prompt.open(B64, tasks_ctx(nil))[1].content, prompt.TASK_FORMAT), "без блока — без правила")
  t.ok(not has(closed()[1].content, prompt.TASK_FORMAT), "закрытая печать — без правила")
end

-- Groq (max_input_chars): знание и лор режутся, блок задач и правило task — целиком
function T.test_fit_keeps_tasks_block()
  local know = {}
  for i = 1, 400 do know[i] = string.format("знание-%03d о мире пишущего, строка", i) end
  local ctx = tasks_ctx(30, table.concat(know, "\n"))
  ctx.lore = lore_lines(40)
  local m = prompt.open(B64, ctx)
  t.ok(utf8_len(ctx.knowledge) >= 13000, "знание большое: " .. utf8_len(ctx.knowledge))
  local f = prompt.fit(m, 8000)
  t.ok(prompt.chars(f) <= 8000, "в лимите: " .. prompt.chars(f))
  local s = f[1].content
  local full = m[1].content
  local a = assert(full:find("\n\n" .. prompt.TASKS_HEAD, 1, true))
  local b = assert(full:find("\n\nЧто ты помнишь о прошлых разговорах", 1, true))
  t.ok(has(s, full:sub(a, b - 1)), "раздел задач целиком")
  t.ok(has(s, "[t30] ДЕЛО-30"), "все 30 задач")
  t.ok(has(s, prompt.TASK_FORMAT), "правило task цело")
  t.ok(has(s, prompt.TASKS_ONLY_OPEN) and has(s, prompt.TASKS_QUIET), "правила раздела целы")
  t.ok(not has(s, "знание-400"), "знание урезано")
  t.ok(has(s, "ПЕРЕСКАЗ-МАРКЕР"), "пересказы на месте")
  -- лимит, при котором знание уходит целиком и режется лор: блок всё равно цел
  local no_know = tasks_ctx(30)
  no_know.knowledge, no_know.lore = nil, ctx.lore
  local f2 = prompt.fit(m, prompt.chars(prompt.open(B64, no_know)) - 300)
  local s2 = f2[1].content
  t.ok(not has(s2, "знание-001"), "знание целиком срезано")
  t.ok(has(s2, "лор-строка-001") and not has(s2, "лор-строка-040"), "лор урезан")
  t.ok(has(s2, full:sub(a, b - 1)) and has(s2, prompt.TASK_FORMAT), "блок и правило целы при урезанном лоре")
end

-- раздел задач в system: от TASKS_HEAD до следующего раздела
local function tasks_section_of(s)
  local a = s:find("\n\n" .. prompt.TASKS_HEAD, 1, true)
  if not a then return nil end
  local b = s:find("\n\n", a + 2, true) or (#s + 1)
  return s:sub(a + 2, b - 1)
end

local function long_block(n, len)
  local list = {}
  for i = 1, n do
    list[i] = { id = "id" .. i, title = string.format("ДЕЛО-%02d ", i) .. string.rep("я", len - 8),
      due = "2026-10-30", project = "ПРОЕКТ-ДОМ" }
  end
  return tasks.block(list)
end

-- блок ограничен и по знакам (Groq, max_input_chars 10000): лишние задачи — с хвоста, всего — полное,
-- метки — только у показанных
function T.test_tasks_block_limited_by_chars()
  t.ok(type(prompt.TASKS_MAX_CHARS) == "number", "TASKS_MAX_CHARS")
  local b = prompt.fit_tasks(long_block(30, 200))
  t.ok(#b.items < 30 and #b.items >= 1, "показано: " .. #b.items)
  t.eq(b.total, 30, "всего — полное")
  local n = 0
  for _ in pairs(b.by_label) do n = n + 1 end
  t.eq(n, #b.items, "метки только у показанных")
  for i, it in ipairs(b.items) do
    t.eq(it.label, "t" .. i, "с головы списка")
    t.eq(b.by_label[it.label], "id" .. i)
  end
  local sect = tasks_section_of(prompt.open(B64, { tasks = b })[1].content)
  t.ok(utf8_len(sect) <= prompt.TASKS_MAX_CHARS, "раздел " .. utf8_len(sect) .. " > " .. prompt.TASKS_MAX_CHARS)
  t.ok(has(sect, string.format(prompt.TASKS_TOTAL, 30)), "последней строкой — всего 30")
  -- обычный список (короткие названия) влезает целиком — тот же блок
  local short = task_block(30)
  t.ok(rawequal(prompt.fit_tasks(short), short), "30 коротких — без урезания")
  -- одно огромное название: хотя бы одна задача остаётся
  local huge = prompt.fit_tasks(long_block(3, 5000))
  t.eq(#huge.items, 1, "одна задача остаётся")
  t.eq(huge.total, 3)
end

-- сессия ревьюера: без знания ~7169 знаков — здесь всё неурезаемое (персона, пересказ, история; лора нет, fit его
-- срезал бы); со знанием и 30 задачами по 200 знаков fit(…, 10000) влезает только за счёт потолка блока
function T.test_fit_with_long_tasks_fits_groq_limit()
  local know = {}
  for i = 1, 400 do know[i] = string.format("знание-%03d о мире пишущего, строка", i) end
  local ctx = { summaries = { "ПЕРЕСКАЗ-МАРКЕР" }, recent = {} }
  for i = 1, 12 do ctx.recent[i] = { role = i % 2 == 1 and "owner" or "diary", text = string.rep("р", 245) } end
  local base = prompt.chars(prompt.open(B64, ctx))
  t.ok(base >= 6900 and base <= 7400, "сессия без знания и задач ~7169: " .. base)
  ctx.knowledge = table.concat(know, "\n")
  ctx.tasks = prompt.fit_tasks(long_block(30, 200))
  local f = prompt.fit(prompt.open(B64, ctx), 10000)
  t.ok(prompt.chars(f) <= 10000, "в лимите Groq: " .. prompt.chars(f))
  t.ok(has(f[1].content, string.format(prompt.TASKS_TOTAL, 30)), "блок цел")
end

-- длинная сессия (ревью среза 3 и 7): полное окно истории, пять длинных пересказов, блок задач на потолке и
-- 30 названий — без знания и лора ~17 тыс. знаков, Groq отвечал 413
local function long_session()
  local ctx = { summaries = {}, recent = {}, titles = {} }
  for i = 1, prompt.MAX_RECENT do
    ctx.recent[i] = { role = i % 2 == 1 and "owner" or "diary",
      text = string.format("РЕПЛИКА-%02d ", i) .. string.rep("р", 245 - 11) }
  end
  for i = 1, 5 do ctx.summaries[i] = string.format("ПЕРЕСКАЗ-%d ", i) .. string.rep("п", 1500 - 11) end
  for i = 1, 30 do ctx.titles[i] = string.format("КНИГА-%02d ", i) .. string.rep("к", 40 - 9) end
  ctx.tasks = prompt.fit_tasks(long_block(30, 200))
  return ctx
end

-- порядок урезания: знание, лор, старые реплики (последние 6 целы), пересказы со старых; правила, задачи,
-- названия и запись не режутся
function T.test_fit_trims_history_and_summaries_to_groq_limit()
  local ctx = long_session()
  local m = prompt.open(B64, ctx)
  local before = dump(m)
  t.ok(prompt.chars(m) > 15000, "сессия длиннее лимита: " .. prompt.chars(m))
  local tsect = tasks_section_of(m[1].content)
  t.ok(utf8_len(tsect) > prompt.TASKS_MAX_CHARS - 300, "блок задач у потолка: " .. utf8_len(tsect))
  local full = m[1].content
  local a = assert(full:find("\n\n" .. prompt.TITLES_HEAD, 1, true))
  local b = assert(full:find("\n\nЧто ты помнишь о прошлых разговорах", 1, true))
  local titles = full:sub(a, b - 1)
  local f = prompt.fit(m, 10000)
  t.eq(dump(m), before, "исходный запрос не тронут")
  t.ok(prompt.chars(f) <= 10000, "в лимите Groq: " .. prompt.chars(f))
  local s = f[1].content
  t.ok(has(s, "Ты — дневник Тома Реддла") and has(s, "Голос:"), "персона и правила")
  t.ok(has(s, tsect), "блок задач целиком")
  t.ok(has(s, titles), "раздел названий целиком")
  t.ok(has(s, '{"read":"...","reply":"...","task":"","tasks_source":"","name":""}') and has(s, prompt.TASK_FORMAT) and
    has(s, prompt.TITLES_FORMAT), "форматы ответа")
  t.ok(has(s, "Ниже — разговор этой сессии"), "строка истории")
  -- последние 6 реплик и запись — те же сообщения в конце
  t.ok(#f >= 8, "система, 6 реплик, запись: " .. #f)
  for k = 0, 6 do t.eq(dump(f[#f - k]), dump(m[#m - k]), "с конца " .. k .. " без изменений") end
  -- реплики уходят с самых старых, без дыр
  local first = f[2].content:match("^РЕПЛИКА%-(%d+)")
  t.ok(first and tonumber(first) > 1, "старые реплики срезаны")
  t.eq(#f - 2, prompt.MAX_RECENT - tonumber(first) + 1, "остаток истории подряд до конца")
  -- пересказы: реплик осталось 6 только если пересказы ушли все; иначе пересказы целы
  if #f - 2 > 6 then
    for i = 1, 5 do t.ok(has(s, string.format("ПЕРЕСКАЗ-%d ", i)), "пересказ " .. i .. " цел, пока есть реплики") end
  end
end

-- истории мало (6 реплик) — режутся пересказы, с самых старых (они последние в разделе); раздел без пересказов уходит
function T.test_fit_trims_oldest_summaries_after_history()
  local ctx = long_session()
  for i = 1, prompt.MAX_RECENT - 6 do table.remove(ctx.recent, 1) end
  local m = prompt.open(B64, ctx)
  local base = prompt.chars(m)
  local f = prompt.fit(m, base - 2000)
  t.ok(prompt.chars(f) <= base - 2000, "в лимите: " .. prompt.chars(f))
  t.eq(#f, #m, "6 последних реплик не тронуты")
  local s = f[1].content
  t.ok(has(s, "ПЕРЕСКАЗ-1 ") and has(s, "ПЕРЕСКАЗ-3 "), "новые пересказы на месте")
  t.ok(not has(s, "ПЕРЕСКАЗ-5 ") and not has(s, "ПЕРЕСКАЗ-4 "), "два старых срезаны")
  t.ok(not has(s, "ПЕРЕСКАЗ-4 п"), "пересказ уходит целиком, без обрывка")
  local g = prompt.fit(m, 10)
  t.ok(not has(g[1].content, "ПЕРЕСКАЗ-") and not has(g[1].content, "Что ты помнишь о прошлых разговорах"),
    "все пересказы ушли — и заголовок")
  t.eq(#g, #m, "реплики — нет")
end

-- свёртка выпавшего из окна этой сессии (ctx.rolling): раздел последним перед строкой истории — хронология:
-- пересказ начала, потом разговор
local ROLL_RECENT = { { role = "owner", text = "РЕПЛИКА-ПИШУЩЕГО" }, { role = "diary", text = "РЕПЛИКА-ДНЕВНИКА" } }

function T.test_rolling_section_before_history()
  local s = prompt.open(B64, { recent = ROLL_RECENT, rolling = "СВЁРТКА-МАРКЕР" })[1].content
  local at = s:find("\n\n" .. prompt.ROLLING_HEAD .. "\nСВЁРТКА-МАРКЕР", 1, true)
  t.ok(at, "раздел свёртки: заголовок и текст")
  local hist = assert(s:find(HISTORY_LINE, 1, true))
  local fmt = assert(s:find("Ответ — строго один JSON-объект", 1, true))
  t.ok(at and at < hist, "раньше строки истории")
  t.ok(at and at > fmt, "после форматов ответа")
  t.ok(not s:find("\n", hist, true), "строка истории — по-прежнему последней")
end

function T.test_rolling_absent_without_text()
  local base = dump(prompt.open(B64, { recent = ROLL_RECENT }))
  t.ok(not has(base, prompt.ROLLING_HEAD), "без свёртки — без раздела")
  t.eq(dump(prompt.open(B64, { recent = ROLL_RECENT, rolling = "" })), base, "rolling = \"\"")
  t.eq(dump(prompt.open(B64, { recent = ROLL_RECENT, rolling = nil })), base, "rolling = nil")
end

function T.test_rolling_multiline_is_one_line()
  local s = prompt.open(B64, { recent = ROLL_RECENT, rolling = "а\n\nб" })[1].content
  t.ok(has(s, prompt.ROLLING_HEAD .. "\nа б\n\n"), "текст свёртки — одной строкой")
  t.ok(not has(s, "а\n\nб"), "без абзаца внутри раздела: prompt.fit режет по \\n\\n")
end

-- свёртка — своя сессия: ценнее пересказов прошлых и срезается после них, целиком; названия книг и дела — нужнее,
-- срезаются после неё
function T.test_fit_drops_rolling_after_summaries()
  local ctx = long_session()
  for i = 1, prompt.MAX_RECENT - 6 do table.remove(ctx.recent, 1) end
  ctx.rolling = "СВЁРТКА " .. string.rep("с", prompt.ROLL_MAX_CHARS - 8)
  local m = prompt.open(B64, ctx)
  local full = m[1].content
  t.ok(has(full, prompt.ROLLING_HEAD .. "\n" .. ctx.rolling), "свёртка в запросе целиком")
  local tsect = tasks_section_of(full)
  local a = assert(full:find("\n\n" .. prompt.TITLES_HEAD, 1, true))
  local b = assert(full:find("\n\nЧто ты помнишь о прошлых разговорах", 1, true))
  local titles = full:sub(a, b - 1)
  -- без пересказов всё ещё на 1000 длиннее: уходят все пересказы и свёртка, остальное цело
  local no_sum = prompt.chars(prompt.open(B64, (function() local c = long_session()
    for i = 1, prompt.MAX_RECENT - 6 do table.remove(c.recent, 1) end
    c.summaries, c.rolling = nil, ctx.rolling
    return c end)()))
  local f = prompt.fit(m, no_sum - 1000)
  local s = f[1].content
  t.ok(prompt.chars(f) <= no_sum - 1000, "в лимите: " .. prompt.chars(f))
  t.ok(not has(s, "ПЕРЕСКАЗ-"), "пересказов нет")
  t.ok(not has(s, prompt.ROLLING_HEAD) and not has(s, "СВЁРТКА"), "свёртка ушла целиком, с заголовком")
  t.ok(has(s, titles), "названия книг целиком")
  t.ok(has(s, tsect), "дела блока целиком")
  t.ok(has(s, HISTORY_LINE), "строка истории")
  t.ok(not has(s, "\n\n\n"), "без пустых абзацев")
  t.eq(#f, #m, "реплики не тронуты")
  -- хватает срезать часть пересказов — свёртка на месте
  local g = prompt.fit(m, prompt.chars(m) - 2000)
  t.ok(prompt.chars(g) <= prompt.chars(m) - 2000, "в лимите: " .. prompt.chars(g))
  t.ok(not has(g[1].content, "ПЕРЕСКАЗ-5 "), "старый пересказ срезан")
  t.ok(has(g[1].content, prompt.ROLLING_HEAD .. "\n" .. ctx.rolling), "свёртка цела")
end

function T.test_roll_text_one_line_capped()
  t.eq(prompt.roll_text("  \n "), "", "пробельная — пустая")
  t.eq(prompt.roll_text(""), "")
  t.eq(prompt.roll_text("а\nб"), "а б", "одной строкой")
  t.eq(prompt.roll_text("  а \n\n б  "), "а б", "без пробелов по краям")
  local long = prompt.roll_text(string.rep("я", 2000))
  t.eq(utf8_len(long), prompt.ROLL_MAX_CHARS, "не длиннее ROLL_MAX_CHARS знаков")
  t.eq(long, string.rep("я", prompt.ROLL_MAX_CHARS), "UTF-8 не рвётся")
  t.eq(prompt.ROLL_MAX_CHARS, 1500)
end

function T.test_roll()
  local entries = { { role = "owner", text = "ЗАП" }, { role = "diary", text = "ОТВ" } }
  local m = prompt.roll("ПРЕЖНЕЕ", entries)
  local s = dump(m)
  t.eq(#m, 2, "system + user")
  t.eq(m[1].role, "system"); t.eq(m[2].role, "user")
  t.ok(has(m[2].content, "Пересказ до этого: ПРЕЖНЕЕ\n\n"), "прежний пересказ — перед репликами")
  t.ok(has(s, "Запись: ЗАП") and has(s, "Дневник: ОТВ"), "метки реплик")
  t.ok(has(s, "до 8 предложений"), "длина свёртки")
  t.ok(has(s, "как пишущий называет себя сам"), "сохраняет, как пишущий называет себя сам")
  t.ok(has(s, "кем приходится тебе"), "кто он дневнику по своим словам")
  t.ok(has(s, "без рода"), "о пишущем — без рода")
  t.ok(has(s, "мужском роде"), "о себе — в мужском роде")
  for _, bad in ipairs({ "хозяйк", "Хозяйк", "image_url", "response_format" }) do
    t.ok(not has(s, bad), "нет: " .. bad)
  end
  for _, earlier in ipairs({ false, "", "  " }) do
    local c = prompt.roll(earlier or nil, entries)[2].content
    t.ok(not has(c, "Пересказ до этого"), "без прежнего пересказа — без строки: " .. tostring(earlier))
    t.eq(c, "Запись: ЗАП\nДневник: ОТВ")
  end
end

-- пол (несрезаемое) длинной сессии со строкой напоминания — больше лимита Groq (замер 2026-10-26: 30 дел × 30
-- названий + строка режима — 10157 при 10000): после пересказов fit режет названия книг с хвоста (раздел уходит
-- целиком вместе с TITLES_FORMAT, ключ tasks_source в примере остаётся — ключи всегда), потом дела с хвоста до одного
local function long_session_with_mode(recent_n)
  local ctx = long_session()
  if recent_n then
    local r = {}
    for i = #ctx.recent - recent_n + 1, #ctx.recent do r[#r + 1] = ctx.recent[i] end
    ctx.recent = r
  end
  ctx.mode_line = prompt.mode_line("name", true, { { title = string.rep("д", 60) }, { title = string.rep("д", 60) },
    { title = string.rep("д", 60) } })
  return ctx
end

function T.test_fit_cuts_titles_then_tasks_under_limit()
  -- 10000 — боевой Groq (push_config.sh), полное окно истории; 6000 — фикстуры app_spec, первая запись сессии
  -- (истории нет): без среза — 8578
  for _, case in ipairs({ { 10000 }, { 6000, 0 } }) do
    local limit = case[1]
    local ctx = long_session_with_mode(case[2])
    local m = prompt.open(B64, ctx)
    local f, over = prompt.fit(m, limit)
    local s = f[1].content
    t.ok(prompt.chars(f) <= limit, limit .. ": в лимите: " .. prompt.chars(f))
    t.eq(over, nil, limit .. ": без превышения")
    t.ok(has(s, "Ты — дневник Тома Реддла") and has(s, "Голос:"), limit .. ": персона и правила")
    t.ok(has(s, prompt.TASKS_HEAD) and has(s, prompt.TASKS_QUIET) and has(s, prompt.TASK_FORMAT), limit .. ": правила дел")
    t.ok(has(s, "\n[t1] ДЕЛО-01 "), limit .. ": первое дело")
    t.ok(has(s, string.format(prompt.TASKS_TOTAL, 30)), limit .. ": всего — полное")
    t.ok(has(s, '{"read":"...","reply":"...","task":"","tasks_source":"","name":""}'), limit .. ": пример со всеми ключами")
    t.ok(has(f[#f].content[1].text, ctx.mode_line), limit .. ": строка режима цела")
    -- названия режутся раньше дел: дело срезано — названий нет совсем, и правила о них тоже
    local tsect = tasks_section_of(s)
    local shown = select(2, tsect:gsub("\n%[t%d+%] ", ""))
    if shown < #ctx.tasks.items then
      t.ok(not has(s, prompt.TITLES_HEAD) and not has(s, prompt.TITLES_FORMAT), limit .. ": названия ушли первыми")
    end
    -- дела — с хвоста, подряд с t1
    for i = 1, shown do t.ok(has(tsect, "\n[t" .. i .. "] ДЕЛО-" .. string.format("%02d", i)), limit .. ": t" .. i) end
    t.ok(not has(s, "\n\n\n"), limit .. ": без пустых абзацев")
    -- названия тоже — с хвоста: если раздел остался, в нём первое название
    if has(s, prompt.TITLES_HEAD) then t.ok(has(s, "- КНИГА-01 "), limit .. ": первое название") end
  end
  -- 10000: дела целы, срезана только часть названий
  local ctx = long_session_with_mode()
  local s = prompt.fit(prompt.open(B64, ctx), 10000)[1].content
  t.ok(has(s, tasks_section_of(prompt.open(B64, ctx)[1].content)), "10000: блок дел целиком")
  -- предел: 6000 при полном окне истории не достижим — последние FIT_KEEP_RECENT реплик (по 245 знаков), строка
  -- режима, персона и правила не режутся; срезано всё, что можно (названия, дела до одного), остаток — вторым значением
  local m = prompt.open(B64, long_session_with_mode())
  local f, over = prompt.fit(m, 6000)
  t.ok(over and over > 0, "6000 с полной историей — сверх лимита")
  t.eq(over, prompt.chars(f) - 6000, "остаток — честный")
  t.ok(not has(f[1].content, prompt.TITLES_HEAD), "названия ушли")
  t.eq(select(2, tasks_section_of(f[1].content):gsub("\n%[t%d+%] ", "")), 1, "одно дело")
end

-- дела, которые строка напоминания велит назвать (ctx.mode_labels — их метки), fit не режет: иначе «напомни о
-- (ДЕЛО-05)», а в блоке его нет и TASKS_ONLY_OPEN называет его сделанным (ревью decfb2d). Режутся остальные с хвоста
function T.test_fit_keeps_tasks_named_in_mode_line()
  local ctx = long_session_with_mode(0)
  local items = ctx.tasks.items
  t.ok(#items >= 6, "в блоке хотя бы 6 дел: " .. #items)
  ctx.mode_line = prompt.mode_line("name", true, { items[5], items[6] })
  ctx.mode_labels = { items[5].label, items[6].label }
  local m = prompt.open(B64, ctx)
  local limit = prompt.chars(prompt.fit(m, 1)) + 10
  local f, over = prompt.fit(m, limit)
  local tsect = tasks_section_of(f[1].content)
  t.eq(over, nil, "в лимите: " .. prompt.chars(f) .. " > " .. limit)
  t.ok(has(tsect, "\n[t5] ДЕЛО-05 ") and has(tsect, "\n[t6] ДЕЛО-06 "), "названные в напоминании — с меткой: " .. tsect)
  t.ok(not has(tsect, "\n[t4] ") and not has(tsect, "\n[t2] "), "остальные срезаны")
  t.ok(has(tsect, string.format(prompt.TASKS_TOTAL, 30)), "всего — полное")
  t.ok(has(f[#f].content[1].text, ctx.mode_line), "строка режима цела")
  -- метки к напоминанию — только для fit: в system и в JSON их нет
  t.eq(m[1].content, prompt.open(B64, (function() local c = long_session_with_mode(0) c.mode_line = ctx.mode_line
    return c end)())[1].content, "system тот же, что без меток")
end

-- без лимита (Gemini) длинная сессия идёт как есть
function T.test_fit_without_limit_keeps_long_session()
  local m = prompt.open(B64, long_session())
  t.ok(rawequal(prompt.fit(m, nil), m), "Gemini: тот же запрос")
  t.eq(#m, prompt.MAX_RECENT + 2, "вся история окна")
end

-- тексты задач — голосом персоны: без слов о том, откуда дела
function T.test_tasks_texts_stay_in_role()
  for _, name in ipairs({ "TASKS_HEAD", "TASKS_ONLY_OPEN", "TASKS_QUIET", "TASKS_NO_LABELS", "TASK_FORMAT",
    "TASKS_TOTAL" }) do
    local s = prompt[name]
    t.ok(type(s) == "string" and s ~= "", name)
    local low = tasks.fold(s)
    for _, bad in ipairs({ "notion", "статус", "поле", "полей", "таблиц", "баз" }) do
      t.ok(not has(low, bad), name .. ": «" .. bad .. "»")
    end
    t.ok(not s:find("[\240-\244]"), name .. ": эмодзи")
  end
  -- латиница — только служебная разметка формата (ключ JSON и метки)
  for _, s in ipairs({ prompt.TASKS_HEAD, prompt.TASKS_ONLY_OPEN, prompt.TASKS_QUIET, prompt.TASKS_NO_LABELS or "",
    string.format(prompt.TASKS_TOTAL or "%d", 3) }) do
    t.ok(not s:find("%a"), "латиница: " .. s)
  end
end

function T.test_tasks_section_carries_rules()
  local s = prompt.open(B64, tasks_ctx(2))[1].content
  local head = assert(s:find(prompt.TASKS_HEAD, 1, true))
  local stop = assert(s:find("ПЕРЕСКАЗ-МАРКЕР", 1, true))
  local sect = s:sub(head, stop - 1)
  t.ok(has(sect, prompt.TASKS_ONLY_OPEN), "называть незакрытыми только эти")
  t.ok(has(sect, prompt.TASKS_QUIET), "самому о делах не заговаривать")
  t.ok(type(prompt.TASKS_NO_LABELS) == "string" and has(sect, prompt.TASKS_NO_LABELS), "метки — не в тексте ответа")
  local none = prompt.open(B64, tasks_ctx(nil))[1].content
  t.ok(not has(none, prompt.TASKS_ONLY_OPEN) and not has(none, prompt.TASKS_QUIET), "без блока — ни того, ни другого")
  t.ok(not has(none, prompt.TASKS_NO_LABELS), "без блока — и правила о метках нет")
end

-- названия книг пишущего (ctx.titles) и правило tasks_source ---------------------------------------------------

local TITLES = { "КНИГА-ДЕЛ", "ФИЛЬМЫ-МАРКЕР" }

-- пример ответа в открытом промпте — один, со всеми ключами этого промпта: task и tasks_source — ключи всегда,
-- как read и reply (живой прогон 2026-10-25: условный tasks_source модель пропускала, task — нет)
function T.test_answer_example_one_with_all_keys()
  local cases = {
    { tasks = nil, titles = nil, ex = '{"read":"...","picks":[],"reply":"...","name":""}' },
    { tasks = 2, titles = nil, ex = '{"read":"...","picks":[],"reply":"...","task":"","name":""}' },
    { tasks = nil, titles = TITLES, ex = '{"read":"...","picks":[],"reply":"...","tasks_source":"","name":""}' },
    { tasks = 2, titles = TITLES, ex = '{"read":"...","picks":[],"reply":"...","task":"","tasks_source":"","name":""}' },
  }
  for i, case in ipairs(cases) do
    local c = tasks_ctx(case.tasks)
    c.titles = case.titles
    local s = prompt.open(B64, c)[1].content
    local _, n = s:gsub('{"read"', "")
    t.eq(n, 1, i .. ": пример ответа один")
    t.ok(has(s, string.format(prompt.ANSWER_FORMAT, case.ex)), i .. ": пример со всеми ключами: " .. case.ex)
    -- пример — последним правилом формата, после правил ключей, до истории
    local e, hist = s:find(case.ex, 1, true), s:find("Ниже — разговор этой сессии", 1, true)
    if case.tasks then t.ok(s:find(prompt.TASK_FORMAT, 1, true) < e, i .. ": правило task до примера") end
    if case.titles then t.ok(s:find(prompt.TITLES_FORMAT, 1, true) < e, i .. ": правило tasks_source до примера") end
    t.ok(e < hist, i .. ": пример до истории")
  end
  -- в правилах ключей своих примеров-объектов нет
  t.ok(not has(prompt.TASK_FORMAT, "{") and not has(prompt.TITLES_FORMAT, "{"), "правила ключей без объектов")
  -- tasks_source всегда: название, "reset" — сброс выбора, "" — ни слова о книге дел
  t.ok(has(prompt.TITLES_FORMAT, '"tasks_source":"reset"') and has(prompt.TITLES_FORMAT, '"tasks_source":""'),
    "сброс и пусто")
  t.ok(not has(prompt.TITLES_FORMAT, "этого ключа не добавляй"), "ключ не условный")
  -- закрытая печать — без задач, без их ключей
  local locked = closed()[1].content
  t.ok(not has(locked, '"task"') and not has(locked, '"tasks_source"'), "закрытая печать без ключей задач")
end

function T.test_titles_section_and_rule_only_with_titles()
  local c = tasks_ctx(nil)
  c.titles = TITLES
  local s = prompt.open(B64, c)[1].content
  t.ok(type(prompt.TITLES_HEAD) == "string" and has(s, "\n\n" .. prompt.TITLES_HEAD .. "\n"), "свой раздел")
  t.ok(has(s, "КНИГА-ДЕЛ") and has(s, "ФИЛЬМЫ-МАРКЕР"), "названия в разделе")
  t.ok(type(prompt.TITLES_FORMAT) == "string" and has(s, prompt.TITLES_FORMAT), "правило tasks_source")
  t.ok(has(prompt.TITLES_FORMAT, '"tasks_source"') and has(prompt.TITLES_FORMAT, '"tasks_source":""'),
    "название или пусто")
  -- правило — после read, до примера ответа и истории
  local f, tf, ex, hist = s:find('"read":"?"', 1, true), s:find(prompt.TITLES_FORMAT, 1, true),
    s:find('{"read":"...","picks":[],"reply":"...","tasks_source":"","name":""}', 1, true), s:find("Ниже — разговор этой сессии", 1, true)
  t.ok(f and tf and ex and hist and f < tf and tf < ex and ex < hist, "read < правило < пример < история")
  -- названий нет, пусто или одни пробелы — промпт как до книг
  local base = dump(prompt.open(B64, tasks_ctx(nil)))
  for _, titles in ipairs({ {}, { "", "  " } }) do
    local e = tasks_ctx(nil)
    e.titles = titles
    t.eq(dump(prompt.open(B64, e)), base, "без названий — без раздела и правила")
  end
  t.ok(not has(closed()[1].content, prompt.TITLES_FORMAT), "закрытая печать — без правила")
end

function T.test_titles_section_after_tasks_before_summaries()
  local c = tasks_ctx(2)
  c.titles = TITLES
  local s = prompt.open(B64, c)[1].content
  local k, tk, ti, p = s:find("ЗНАНИЕ-МАРКЕР", 1, true), s:find(prompt.TASKS_HEAD, 1, true),
    s:find(prompt.TITLES_HEAD, 1, true), s:find("ПЕРЕСКАЗ-МАРКЕР", 1, true)
  t.ok(k and tk and ti and p and k < tk and tk < ti and ti < p, "знание < задачи < названия < пересказы")
  -- блока нет — сразу после знаний
  local n = tasks_ctx(nil)
  n.titles = TITLES
  local s2 = prompt.open(B64, n)[1].content
  local k2, ti2, p2 = s2:find("ЗНАНИЕ-МАРКЕР", 1, true), s2:find(prompt.TITLES_HEAD, 1, true),
    s2:find("ПЕРЕСКАЗ-МАРКЕР", 1, true)
  t.ok(k2 and ti2 and p2 and k2 < ti2 and ti2 < p2, "знание < названия < пересказы")
  -- перевод строки в названии не рвёт раздел
  n.titles = { "КНИГА\n\nСО СТРОКАМИ" }
  t.ok(has(prompt.open(B64, n)[1].content, "КНИГА СО СТРОКАМИ"), "название в одну строку")
end

-- Groq: блока задач нет (книга не выбрана — ровно когда её называют), знание режется, раздел названий и правило
-- целы (Б5)
function T.test_fit_keeps_titles_section()
  local know = {}
  for i = 1, 600 do know[i] = string.format("знание-%03d о мире пишущего, строка", i) end
  local c = tasks_ctx(nil, table.concat(know, "\n"))
  c.titles = TITLES
  t.ok(utf8_len(c.knowledge) >= 20000, "знание 20 000 знаков: " .. utf8_len(c.knowledge))
  local m = prompt.open(B64, c)
  local full = m[1].content
  local a = assert(full:find("\n\n" .. prompt.TITLES_HEAD, 1, true))
  local b = assert(full:find("\n\nЧто ты помнишь о прошлых разговорах", 1, true))
  local f = prompt.fit(m, 8000)
  t.ok(prompt.chars(f) <= 8000, "в лимите: " .. prompt.chars(f))
  local s = f[1].content
  t.ok(has(s, full:sub(a, b - 1)), "раздел названий целиком")
  t.ok(has(s, prompt.TITLES_FORMAT), "правило tasks_source цело")
  t.ok(has(s, "знание-001") and not has(s, "знание-600"), "знание урезано")
  -- лимит, при котором знание уходит целиком и режется лор: раздел всё равно цел
  local no_know = tasks_ctx(nil)
  no_know.knowledge, no_know.titles = nil, TITLES
  local f2 = prompt.fit(m, prompt.chars(prompt.open(B64, no_know)) - 5)
  t.ok(not has(f2[1].content, "знание-001"), "знание срезано")
  t.ok(has(f2[1].content, full:sub(a, b - 1)), "раздел названий цел при урезанном лоре")
end

-- тексты о книгах — голосом персоны: без слов о том, откуда они
function T.test_titles_texts_stay_in_role()
  for _, name in ipairs({ "TITLES_HEAD", "TITLES_FORMAT" }) do
    local s = prompt[name]
    t.ok(type(s) == "string" and s ~= "", name)
    local low = tasks.fold(s)
    for _, bad in ipairs({ "notion", "статус", "поле", "полей", "таблиц", "баз" }) do
      t.ok(not has(low, bad), name .. ": «" .. bad .. "»")
    end
    t.ok(not s:find("[\240-\244]"), name .. ": эмодзи")
  end
  t.ok(not prompt.TITLES_HEAD:find("%a"), "латиница: " .. prompt.TITLES_HEAD)
  -- в правиле латиница — только служебная разметка формата
  local rest = prompt.TITLES_FORMAT:gsub('"[%a_]+"', ""):gsub("JSON", "")
  t.ok(not rest:find("%a"), "латиница: " .. rest)
end

-- режим ответа (ритм) -----------------------------------------------------------------------------------------

local MODE_ITEMS = { { label = "t2", id = "a", title = "Купить хлеб" }, { label = "t5", id = "b", title = "Позвонить в банк" } }
local MODE_TITLES = { "Фильмы", "Рецепты" }

local function user_text(messages)
  local last = messages[#messages]
  t.eq(last.role, "user", "последнее — запись")
  for _, part in ipairs(last.content) do
    if part.type == "text" then return part.text end
  end
end

-- строка режима — в последнем user, system от ответа к ответу один и тот же (кэш провайдера)
function T.test_mode_line_in_last_user_message_not_system()
  local line = prompt.mode_line("name", false, MODE_ITEMS)
  t.ok(type(line) == "string" and line ~= "", "строка режима есть")
  local ctx = tasks_ctx(3)
  local plain = prompt.open(B64, ctx)
  ctx.mode_line = line
  local with_mode = prompt.open(B64, ctx)
  t.eq(with_mode[1].content, plain[1].content, "system не меняется")
  t.eq(#with_mode, #plain, "сообщений столько же")
  local u = user_text(with_mode)
  t.ok(has(u, line), "строка режима в user")
  t.ok(has(u, user_text(plain)), "текст записи на месте")
  t.ok(has(line, "Купить хлеб") and has(line, "Позвонить в банк"), line)
  -- метки — служебные, только для поля task: в строке режима их нет, иначе слабая модель вынесет «[t2]» на экран
  t.ok(not has(line, "[t2]") and not has(line, "t5") and not line:find("%a"), "без меток и латиницы: " .. line)
  t.ok(not has(with_mode[1].content, line), "не в system")
  t.eq(last_image(with_mode), "data:image/png;base64," .. B64, "картинка на месте")
  -- урезанный запрос строку режима не теряет
  local fitted = prompt.fit(with_mode, 100)
  t.ok(has(user_text(fitted), line), "fit не режет строку режима")
end

function T.test_mode_line_none_and_empty_is_nil()
  t.eq(prompt.mode_line("none", false, MODE_ITEMS), nil)
  t.eq(prompt.mode_line("name", false, {}), nil, "назвать нечего")
  t.eq(prompt.mode_line("themes", false, {}), nil, "названий нет")
  t.ok(has(prompt.mode_line("drift", true) or "", prompt.MODE_DRIFT), "намёку список не нужен")
  t.ok(has(prompt.mode_line("themes", false, MODE_TITLES) or "", "Фильмы"), "темы — по названиям")
end

function T.test_conditional_mode_line_mentions_condition()
  for _, mode in ipairs({ "name", "drift" }) do
    local cond = prompt.mode_line(mode, true, MODE_ITEMS)
    local plain = prompt.mode_line(mode, false, MODE_ITEMS)
    t.ok(has(cond, prompt.MODE_IF), mode .. ": условие")
    t.ok(has(cond, prompt.MODE_ELSE), mode .. ": если касается — о других не говорить")
    t.ok(not has(plain, prompt.MODE_IF) and not has(plain, prompt.MODE_ELSE), mode .. ": безусловная — без условия")
  end
  -- запись о делах вообще — не повод для намёка «ушли в сторону»: на неё отвечают делами (живой прогон
  -- 2026-10-26: на «что мне сегодня сделать?» — намёк вместо дел)
  t.ok(has(prompt.MODE_IF, "о делах вообще"), "условие — и о делах вообще: " .. prompt.MODE_IF)
  t.ok(has(prompt.MODE_ELSE, "ответь") and has(prompt.MODE_ELSE, "делами из списка"),
    "иначе — ответ делами: " .. prompt.MODE_ELSE)
end

-- на прямой вопрос — только ответ на него (владелец 2026-10-26, Proposal 812f): у каждой строки напоминания о делах,
-- и у первой записи сессии, — условие «не вопрос и не просьба»; на вопрос о делах — делами
function T.test_task_reminders_skip_direct_questions()
  for _, cond in ipairs({ false, true }) do
    for _, mode in ipairs({ "name", "drift" }) do
      local s = prompt.mode_line(mode, cond, MODE_ITEMS)
      if s then
        t.ok(has(s, "не вопрос и не просьба"), mode .. "/" .. tostring(cond) .. ": " .. s)
        t.ok(has(s, "ответь только на н"), mode .. "/" .. tostring(cond) .. ": " .. s)
        t.ok(has(s, "делами из списка"), "на вопрос о делах — делами: " .. s)
      end
    end
  end
  local first = prompt.mode_line("name", false, MODE_ITEMS)
  t.ok(has(first, prompt.MODE_ASK_IF) and has(first, prompt.MODE_ASK_ELSE), "первая запись: " .. first)
  t.ok(not has(first, prompt.MODE_IF), "первая — без условия о делах")
end

function T.test_mode_texts_stay_in_role()
  local lines = {
    prompt.mode_line("name", false, MODE_ITEMS), prompt.mode_line("name", true, MODE_ITEMS),
    prompt.mode_line("drift", true), prompt.mode_line("themes", false, MODE_TITLES),
    prompt.mode_line("themes", true, MODE_TITLES),
  }
  for _, s in ipairs(lines) do
    local low = tasks.fold(s)
    for _, bad in ipairs({ "notion", "статус", "поле", "полей", "таблиц", "баз" }) do
      t.ok(not has(low, bad), s .. ": «" .. bad .. "»")
    end
    t.ok(not s:find("[\240-\244]"), "эмодзи: " .. s)
    -- одно предложение: точка, ! или ? — только в конце
    t.ok(not s:sub(1, -2):find("[%.!?]%s"), "одно предложение: " .. s)
    t.ok(s:find("[%.]$"), "точка в конце: " .. s)
  end
  -- латиница — только метки дел, не слова
  for _, name in ipairs({ "MODE_NOTE", "MODE_IF", "MODE_ELSE", "MODE_ASK_IF", "MODE_ASK_ELSE", "MODE_NAME", "MODE_DRIFT",
    "MODE_THEMES" }) do
    local s = prompt[name]
    t.ok(type(s) == "string" and s ~= "", name)
    t.ok(not s:gsub("%%s", ""):find("%a"), name .. ": латиница")
  end
end

-- названий сотни — в строку режима идут первые prompt.THEMES_MAX
function T.test_themes_line_caps_titles()
  local many = {}
  for i = 1, 50 do many[i] = "Тема" .. i end
  local s = prompt.mode_line("themes", false, many)
  t.ok(has(s, "Тема" .. prompt.THEMES_MAX), "первые на месте")
  t.ok(not has(s, "Тема" .. (prompt.THEMES_MAX + 1)), "дальше — нет")
end

-- советы по знанию (Notion 8152, круг 3): ключ "picks" — названия, которые ответ советует, до "reply"; есть знание —
-- ключ в примере ответа всегда (условный ключ модель пропускает); без знания и в закрытой печати — нет
local function picks_ctx()
  return { knowledge = { { title = "Фильмы", total = 1,
    docs = { { title = "Брат", text = "Название: Брат", edited = "" } } } } }
end

-- ctx.picks == false (нет значений «пройдено» в конфиге) — ни правила, ни ключа в примере: место в лимите провайдера
function T.test_picks_off_sends_no_rule_and_no_key()
  local ctx = picks_ctx()
  ctx.picks = false
  local s = prompt.open(B64, ctx)[1].content
  t.ok(not has(s, prompt.PICKS_FORMAT) and not has(s, '"picks"'), "правила и ключа нет")
  t.ok(has(s, '{"read":"...","reply":"...","name":""}'), "пример как без знания (ключ имени — всегда)")
  local g = prompt.fit(prompt.open(B64, ctx), 100)
  t.ok(not has(g[1].content, '"picks"'), "fit ничего не возвращает")
end

-- в picks — только то, что ответ советует; опоры («ты смотрел X, поэтому Y») туда не идут: модель вписывала их, и
-- сверка с просмотренным принимала опору за совет
function T.test_picks_format_excludes_references_to_past_choices()
  t.ok(has(prompt.PICKS_FORMAT, "только"), "только советуемое")
  t.ok(has(prompt.PICKS_FORMAT, "на которые ответ ссылается"), "опоры названы")
  t.ok(has(prompt.PICKS_FORMAT, "не идут"), "и в picks не идут")
  t.ok(has(prompt.PICKS_FORMAT, '"picks":[]') and has(prompt.PICKS_FORMAT, '"picks":["Название"]'), "пример цел")
end

function T.test_picks_key_before_reply_with_knowledge()
  local s = prompt.open(B64, picks_ctx())[1].content
  local rf, pf, ex = s:find('"read":"?"', 1, true), s:find(prompt.PICKS_FORMAT, 1, true),
    s:find('{"read":"...","picks":[],"reply":"...","name":""}', 1, true)
  t.ok(rf and pf and ex and rf < pf and pf < ex, "правило picks — после read, до примера")
  t.ok(has(s, "\n\n" .. prompt.PICKS_FORMAT .. "\n\n"), "своей строкой")
  t.ok(has(prompt.PICKS_FORMAT, '"picks":[]'), "ничего не советуешь — пустой массив")
  t.ok(not has(prompt.open(B64, {})[1].content, '"picks"'), "без знания — без ключа")
  t.ok(not has(closed()[1].content, '"picks"'), "закрытая печать — без ключа")
end

-- в плагине нет слов данных (названий статусов): поправка — шаблон, значение подставляет контроллер из документа
function T.test_picks_retry_template_has_no_data_words()
  for _, r in ipairs({ prompt.PICKS_RETRY, prompt.PICKS_RETRY_PLAIN }) do
    t.ok(not has(r, "росмотр") and not has(r, "рочитан"), r)
  end
  t.eq(prompt.WATCHED_MARK, nil, "слово данных в промпте не живёт")
end

-- поправка повтора с потолком списка не тронутого (RETRY_UNTOUCHED_MAX_CHARS) идёт в запись, а запись fit не режет:
-- сессия ревьюера (~7169 без знания, 30 длинных дел) с поправкой на три пройденных названия по 60 знаков и список
-- в потолок всё равно влезает в 10000 Groq — fit срежет знание, не поправку
function T.test_fit_with_max_retry_note_fits_groq_limit()
  local know = { { title = "Фильмы и сериалы", total = 73, docs = {} } }
  for i = 1, 73 do
    know[1].docs[i] = { title = string.format("Фильм-%02d", i), edited = "",
      text = string.format("Название: Фильм-%02d\nСтатус просмотра: На просмотр\n%s", i, string.rep("описание ", 40)) }
  end
  local ctx = { summaries = { "ПЕРЕСКАЗ-МАРКЕР" }, recent = {}, knowledge = know }
  for i = 1, 12 do ctx.recent[i] = { role = i % 2 == 1 and "owner" or "diary", text = string.rep("р", 245) } end
  ctx.tasks = prompt.fit_tasks(long_block(30, 200))
  local m = prompt.open(B64, ctx)
  local items, titles = {}, {}
  for i = 1, 3 do items[i] = string.format("«%s» — Просмотрено", string.rep("н", 60)) end
  local n, used = 0, 0
  while used + 30 + 2 <= prompt.RETRY_UNTOUCHED_MAX_CHARS do
    n = n + 1
    used = used + 30 + (n > 1 and 2 or 0)
    titles[n] = string.rep("з", 30)
  end
  local note = string.format(prompt.PICKS_RETRY, table.concat(items, "; "), table.concat(titles, "; "))
  local f, over = prompt.fit(prompt.with_note(m, note), 10000)
  t.eq(over, nil, "без превышения")
  t.ok(prompt.chars(f) <= 10000, "в лимите Groq: " .. prompt.chars(f))
  t.ok(has(f[#f].content[1].text, note), "поправка цела")
  t.ok(has(f[1].content, string.format(prompt.TASKS_TOTAL, 30)), "блок дел цел")
  -- несрезаемое (знание ушло целиком, а с ним и правила совета) + поправка — тоже в лимите: запас под знание есть
  ctx.knowledge = nil
  local ff, fover = prompt.fit(prompt.with_note(prompt.open(B64, ctx), note), 10000)
  t.eq(fover, nil, "без знания: без превышения")
  t.ok(prompt.chars(ff) <= 10000, "без знания с поправкой: " .. prompt.chars(ff))
end

-- реплики истории по 1000 знаков (Notion 40513e60…8133): последние FIT_KEEP_RECENT одни выводили запрос за 10000 Groq.
-- fit укорачивает их с самой старой, с головы, не короче FIT_REPLY_MIN_CHARS; поправка в потолках — в лимите
function T.test_fit_shortens_long_kept_replies_to_groq_limit()
  local ctx = { summaries = { "ПЕРЕСКАЗ-МАРКЕР" }, recent = {} }
  for i = 1, 40 do
    ctx.recent[i] = { role = i % 2 == 1 and "owner" or "diary", text = string.format("%02d", i) .. string.rep("р", 998) }
  end
  ctx.tasks = prompt.fit_tasks(long_block(30, 200))
  local note = string.format(prompt.PICKS_RETRY, string.rep("н", prompt.RETRY_DONE_MAX_CHARS),
    string.rep("з", prompt.RETRY_UNTOUCHED_MAX_CHARS))
  local m = prompt.with_note(prompt.open(B64, ctx), note)
  local before = dump(m)
  local f, over = prompt.fit(m, 10000)
  t.eq(dump(m), before, "исходный не тронут")
  t.eq(over, nil, "без превышения")
  t.ok(prompt.chars(f) <= 10000, "в лимите Groq: " .. prompt.chars(f))
  t.ok(has(f[#f].content[1].text, note), "поправка цела")
  t.eq(#f, 2 + prompt.FIT_KEEP_RECENT, "остались последние реплики")
  t.eq(f[#f - 1].content, ctx.recent[40].text, "последняя реплика целиком")
  local shortened = 0
  for i = 2, #f - 1 do
    local c = f[i].content
    t.ok(c:find("^" .. string.format("%02d", 40 - prompt.FIT_KEEP_RECENT + i - 1)), "порядок и голова реплики: " .. i)
    if c ~= ctx.recent[40 - prompt.FIT_KEEP_RECENT + i - 1].text then
      shortened = shortened + 1
      t.ok(c:sub(-#"…") == "…", "укороченная — с «…»")
      t.ok(utf8_len(c) >= prompt.FIT_REPLY_MIN_CHARS + 1, "не короче пола: " .. utf8_len(c))
    end
  end
  t.ok(shortened > 0, "реплики укорочены")
  -- короче пола реплику fit не трогает: остаток — вторым значением
  local _, rest = prompt.fit(m, 3000)
  t.ok(rest and rest > 0, "3000 — сверх лимита")
end

-- повтор с поправкой: системный и история те же (кэш провайдера), поправка — строкой к тексту последней записи,
-- картинка та же; исходный запрос не меняется
function T.test_with_note_appends_to_last_user_text()
  local m = prompt.open(B64, picks_ctx())
  local before = dump(m)
  local note = string.format(prompt.PICKS_RETRY, "«Брат» — Просмотрено", "Другие")
  local r = prompt.with_note(m, note)
  t.eq(dump(m), before, "исходный не тронут")
  t.eq(#r, #m)
  t.eq(r[1].content, m[1].content, "системный тот же")
  t.eq(r[#r].content[1].text, m[#m].content[1].text .. "\n" .. note)
  t.eq(r[#r].content[2].image_url.url, m[#m].content[2].image_url.url, "картинка та же")
  t.ok(has(note, "«Брат» — Просмотрено"), note)
end

-- запросы разделов карты (план карты, срез 2): строка дословно, все типы мест terrain.KINDS и все значения role, day,
-- night с пояснением; язык фраз — языком персоны («Методов» — по-русски)
function T.test_gen_map_and_cast_requests()
  local terrain = require("riddle.terrain")
  local mapdata = require("riddle.mapdata")
  local methods = require("riddle.persona").METHODS_VIEW
  local line = "Том Реддл из «Методов рационального мышления»"
  for _, v in ipairs({ methods, { lang = "en", lang_name = "английский", head = "h", body = "b", gender = "m" } }) do
    local map = prompt.gen_map(v, line)
    t.eq(map[#map].content, "Строка: " .. line)
    local sys = map[1].content
    for _, k in ipairs(terrain.KINDS) do t.ok(has(sys, k .. " — "), "тип места с пояснением: " .. k) end
    for _, k in ipairs({ '"potter"', '"open"', '"close"', '"blind"', '"places"' }) do
      t.ok(has(sys, k), "ключ " .. k)
    end
    t.ok(not has(sys, '"title"'), "заголовка карты в формате раздела нет (владелец 2026-11-16)")
    t.ok(has(sys, v.lang == "ru" and "по-русски" or "английский"), "язык фраз")
    local cast = prompt.gen_cast(v, line)
    t.eq(cast[#cast].content, "Строка: " .. line)
    sys = cast[1].content
    for _, list in ipairs({ mapdata.ROLES, mapdata.DAY, mapdata.NIGHT }) do
      for _, k in ipairs(list) do t.ok(has(sys, k .. " ("), "значение с пояснением: " .. k) end
    end
    t.ok(has(sys, tostring(mapdata.NAME_MAX)), "потолок имени")
  end
  -- потолок фраз карты — правило приглашения (persona.MAP_SECTIONS проверяет им же), не своё число
  local texts = require("riddle.texts")
  local saved = texts.INVITATION.max_cps
  texts.INVITATION.max_cps = 55
  local sys = prompt.gen_map(methods, line)[1].content
  texts.INVITATION.max_cps = saved
  t.ok(has(sys, "до 55 знаков") and not has(sys, "до 70 знаков"), sys)
  -- имена разделов карты — одно место (mapdata): литерала в других модулях нет
  for _, f in ipairs({ "persona", "prompt", "controller" }) do
    local src = assert(io.open("plugin/riddlediary.koplugin/riddle/" .. f .. ".lua")):read("*a")
    t.ok(not has(src, '"map.cast"') and not has(src, 'name = "map"'), "имя раздела литералом в riddle/" .. f)
  end
  t.eq(mapdata.SECTION_MAP, "map")
  t.eq(mapdata.SECTION_CAST, "map.cast")
end

-- персона «Методов» (Kindle владельца) — промпты байт в байт прежние: снимок снят до фичи «чей это дневник»
-- (спека 2026-10-31, пункт 10). ctx.persona не задан или встроенная «Методов» — тот же текст. Открытая печать
-- говорит тем же текстом, что и дневник без печати (строка «Печать снята» ушла вместе со словом, spec §7); закрытая —
-- пустой контекст, правило закрытой печати отдельным абзацем после персоны и ключ needs_data в конце примера ответа
function T.test_methods_prompts_unchanged()
  local snap = require("fixtures.methods_prompts")
  local C = require("fixtures.methods_ctx")
  local methods = require("riddle.persona").METHODS_VIEW
  local cut = snap.open_empty:find("\n\n", 1, true)
  local closed_snap = snap.open_empty:sub(1, cut + 1) .. prompt.SEAL_CLOSED .. snap.open_empty:sub(cut)
  local n
  closed_snap, n = closed_snap:gsub(',"name":""}', ',"name":"","needs_data":false}', 1)
  t.eq(n, 1, "пример ответа в снимке")
  for _, p in ipairs({ false, methods }) do
    local c = C.open_ctx()
    c.persona = p or nil
    t.eq(prompt.open(B64, c)[1].content, snap.open_full, "open, все разделы")
    t.eq(prompt.open(B64, { persona = p or nil })[1].content, snap.open_empty, "open, пустой контекст")
    t.eq(closed(p or nil)[1].content, closed_snap, "закрытая печать")
  end
  for _, v in ipairs({ false, methods }) do
    t.eq(prompt.summarize(C.entries, "РАНЬШЕ", v or nil)[1].content, snap.summarize, "summarize")
    t.eq(prompt.roll("РАНЬШЕ", C.entries, v or nil)[1].content, snap.roll, "roll")
  end
end

-- карта, срез 3: фраза-открывашка читается тем же чтением страницы. Блок prompt.MAP_FORMAT — только при ctx.map,
-- отдельным куском после правил формата; персона «Методов» и всё остальное — байт в байт (план карты, раздел 6 п.2)
local function methods_map()
  local persona = require("riddle.persona")
  return require("riddle.mapdata").of(persona.METHODS_VIEW, { id = persona.METHODS_ID }, nil)
end

-- мир не Поттера (фикстура среза 2: «Карта Средиземья», свои фразы)
local function other_map()
  local MP = require("fixtures.map_parts")
  return require("riddle.mapdata").of({ lang = "ru" }, { id = 7 }, { map = json.encode(MP.map) })
end

local function in_list(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

-- блок карты в системном: от "\n\nКлюч \"map\"" до следующего "\n\n" -> блок, текст без блока и без ключа в примере
local MAP_HEAD = '\n\nКлюч "map"'
local function split_map(s)
  local at = s:find(MAP_HEAD, 1, true)
  if not at then return nil, s end
  local stop = s:find("\n\n", at + 2, true) or (#s + 1)
  local rest = s:sub(1, at - 1) .. s:sub(stop)
  local n
  rest, n = rest:gsub(',"map":""}', "}", 1)
  t.eq(n, 1, "ключ map в примере ответа")
  return s:sub(at + 2, stop - 1), rest
end

function T.test_map_format_only_with_ctx_map()
  local snap = require("fixtures.methods_prompts")
  local C = require("fixtures.methods_ctx")
  local methods = require("riddle.persona").METHODS_VIEW
  local map = methods_map()
  local cases = {
    { ctx = function() return { persona = methods } end, snap = snap.open_empty },
    { ctx = function() local c = C.open_ctx() c.persona = methods return c end, snap = snap.open_full },
    { ctx = function() return C.open_ctx() end, snap = snap.open_full },
  }
  for _, case in ipairs(cases) do
    t.eq(prompt.open(B64, case.ctx())[1].content, case.snap, "без ctx.map — снимок прежний")
    local ctx = case.ctx()
    ctx.map = map
    local s = prompt.open(B64, ctx)[1].content
    local block, rest = split_map(s)
    t.ok(block, "с ctx.map — блок карты")
    t.eq(rest, case.snap, "кроме блока и ключа в примере — байт в байт прежний")
    t.ok(s:find(MAP_HEAD, 1, true) < s:find("Ответ — строго один JSON-объект", 1, true), "блок — до примера ответа")
  end
  -- с ctx.map — свой снимок (снят этим же контекстом; правке руками не подлежит)
  t.eq(prompt.open(B64, { persona = methods, map = map })[1].content,
    require("fixtures.methods_map_prompts").open_empty, "снимок с картой")
  -- сгенерированная персона: тот же блок, без ctx.map — без него
  local view = { id = 7, head = "дневник ГОЛОВА.", body = "ТЕЛО.", lang = "ru", gender = "f" }
  t.ok(not has(prompt.open(B64, { persona = view })[1].content, 'Ключ "map"'), "без ctx.map блока нет")
  t.ok(split_map(prompt.open(B64, { persona = view, map = other_map() })[1].content), "с ctx.map — блок")
end

-- карта, срез 13б (вариант А): как пишущий назвал себя в записи — ключом "name" в каждом ответе открытой печати.
-- Ключ в примере всегда, пустым (условный ключ слабая модель пропускает — ANSWER_FORMAT); правило — своим абзацем
-- после правил read и задач, до правила карты и примера. Закрытая печать, настройка, чтение на карте, пересказы —
-- без него
function T.test_name_format_in_open_seal()
  local methods = require("riddle.persona").METHODS_VIEW
  local full = tasks_ctx(2)
  full.titles = TITLES
  full.persona = methods
  full.map = methods_map()
  for name, ctx in pairs({ empty = {}, methods = { persona = methods }, tasks = tasks_ctx(2), full = full }) do
    local s = prompt.open(B64, ctx)[1].content
    t.ok(has(s, "\n\n" .. prompt.NAME_FORMAT .. "\n\n"), name .. ": правило своим абзацем")
    local _, n = s:gsub(',"name":""', "")
    t.eq(n, 1, name .. ": ключ в примере ответа — один раз")
    local rf, nf, ex = s:find('"read":"?"', 1, true), s:find(prompt.NAME_FORMAT, 1, true),
      s:find("Ответ — строго один JSON-объект", 1, true)
    t.ok(rf < nf and nf < ex, name .. ": после read, до примера")
    local tf, tt, mf = s:find(prompt.TASK_FORMAT, 1, true), s:find(prompt.TITLES_FORMAT, 1, true),
      s:find('Ключ "map"', 1, true)
    t.ok(not tf or tf < nf, name .. ": после правила задач")
    t.ok(not tt or tt < nf, name .. ": после правила книг дел")
    t.ok(not mf or nf < mf, name .. ": до правила карты")
  end
  -- в полном примере — перед ключом карты: блок карты вырезается с ,"map":""} (split_map)
  t.ok(has(prompt.open(B64, full)[1].content, ',"tasks_source":"","name":"","map":""}'), "порядок ключей примера")
  t.ok(has(prompt.NAME_FORMAT, '"name":""'), "пусто, если не назвался")
  t.ok(has(prompt.NAME_FORMAT, "называет себя"), "как пишущий называет себя")
  for what, s in pairs({ setup = prompt.setup(B64)[1].content,
      map_read = prompt.map_read(B64, methods_map())[1].content,
      summarize = prompt.summarize({ { role = "owner", text = "x" } })[1].content,
      roll = prompt.roll("РАНЬШЕ", { { role = "owner", text = "x" } })[1].content }) do
    t.ok(not has(s, '"name"'), what .. ": без ключа имени")
  end
end

-- владелец 2026-10-31: «не конкретно, вся фраза целиком, обязательно, чтобы это были ключевые слова в этой фразе»;
-- «люди могут по-разному помнить, у людей мог быть разный перевод». У мира Поттера — оба канона (ru, en) и ключевые
-- слова; у другого мира — его фраза. VARIANTS — замер A11 (тестер пишет их пером): каждый вариант задевает ключевое
-- слово блока хотя бы началом (5 знаков)
local VARIANTS = { "Торжественно клянусь, что замышляю шалость", "замышляю шалость", "клянусь, что я негодяй",
  "I solemnly swear", "up to no good", "ничего кроме шалости" }

function T.test_map_format_keywords()
  local mapdata = require("riddle.mapdata")
  local block = split_map(prompt.open(B64, { map = methods_map() })[1].content)
  for _, lang in ipairs({ "ru", "en" }) do
    t.ok(has(block, mapdata.POTTER[lang].open), "канон " .. lang .. ": " .. block)
  end
  for _, w in ipairs(mapdata.POTTER_WORDS) do t.ok(has(block, w), "ключевое слово: " .. w) end
  for _, w in ipairs({ "замышляю", "шалость", "клянусь", "solemnly swear", "up to no good" }) do
    t.ok(in_list(mapdata.POTTER_WORDS, w), "ключевые слова спеки: " .. w)
  end
  t.ok(has(block, "переводе") and has(block, "целиком"), "не фраза целиком, любой перевод: " .. block)
  t.ok(has(block, '"open"'), "значение open")
  for _, v in ipairs(VARIANTS) do
    local hit = false
    for _, w in ipairs(mapdata.POTTER_WORDS) do
      if has(v, head_chars(w, 5)) then hit = true end
    end
    t.ok(hit, "вариант A11 без ключевого слова: " .. v)
  end
  local other = split_map(prompt.open(B64, { map = other_map() })[1].content)
  t.ok(has(other, "Скажи, друг, и войди"), "фраза своего мира: " .. other)
  t.ok(not has(other, "шалость") and not has(other, "solemnly"), "без канона Поттера")
end

-- чтение страницы на карте: нейтральное, без образа, памяти и истории; ключи read и map, без reply. У Поттера —
-- закрывашка на обоих языках, у другого мира — своя
function T.test_map_read_has_no_persona_no_memory()
  local mapdata = require("riddle.mapdata")
  local m = prompt.map_read(B64, methods_map())
  t.eq(#m, 2, "системный и запись")
  t.eq(m[1].role, "system")
  t.eq(last_image(m), "data:image/png;base64," .. B64)
  local s = m[1].content
  for _, bad in ipairs({ "Реддл", "Волдеморт", "Тёмного Лорда", "помнишь", "Печать", '"reply"' }) do
    t.ok(not has(s, bad), "в чтении карты: " .. bad)
  end
  t.ok(has(s, mapdata.POTTER.ru.close) and has(s, mapdata.POTTER.en.close), s)
  t.ok(has(s, '"read"') and has(s, '"map":""') and has(s, '"close"'), "ключи ответа")
  t.ok(has(s, "переводе") and has(s, "целиком"), "не фраза целиком, любой перевод")
  local other = prompt.map_read(B64, other_map())[1].content
  t.ok(has(other, "Дорога уходит вдаль") and not has(other, "Шалость"), other)
end

-- сгенерированная персона: её голова и тело вместо Волдеморта, общие правила формы — те же, что у «Методов»
function T.test_generated_persona_in_open()
  local view = { id = 7, head = "дневник ГОЛОВА-МАРКЕР.", body = "ТЕЛО-МАРКЕР.", lang = "ru", gender = "f" }
  local s = prompt.open(B64, { persona = view })[1].content
  t.ok(s:find("^Ты — дневник ГОЛОВА%-МАРКЕР%."), s:sub(1, 80))
  t.ok(has(s, "ТЕЛО-МАРКЕР."), "тело персоны")
  t.ok(not has(s, "Волдеморт") and not has(s, "Реддл"), "нет Волдеморта")
  for _, rule in ipairs({ "1–3 предложения", "без эмодзи и без markdown", "Никогда не называй себя ИИ",
      "Не выдумывай фактов", "обращайся на «ты» и без рода" }) do
    t.ok(has(s, rule), "общее правило: " .. rule)
  end
end

-- язык, род и имя дневника — от персонажа (план «чей это дневник», задача 9): закрытая печать, пересказ и свёртка
local EN_F = { id = 9, head = "дневник Гермионы.", body = "Характер: ГОЛОС.", lang = "en", lang_name = "английский",
  gender = "f", kind = "записная книжка", title = "Hermione's Diary" }
local function with_gender(view, g)
  local v = {}
  for k, x in pairs(view) do v[k] = x end
  v.gender = g
  return v
end

-- закрытая печать говорит голосом персонажа (spec §4: тот же ответ, только без данных): язык, род, образ — её
function T.test_closed_prompt_speaks_in_persona_voice()
  local s = closed(EN_F)[1].content
  t.ok(has(s, "Ты — дневник Гермионы.") and has(s, "Характер: ГОЛОС."), "образ персонажа")
  t.ok(has(s, "английский") and not has(s, "по-русски"), "язык ответа — lang_name")
  t.ok(has(s, "женском роде («поняла», «ждала»)") and not has(s, "мужском"), "род — женский")
  t.ok(has(s, prompt.SEAL_CLOSED), "правило закрытой печати")
  local m = closed(with_gender(EN_F, "m"))[1].content
  t.ok(has(m, "мужском роде («понял», «ждал»)") and not has(m, "женском"), "m — мужской")
end

-- персонажа нет (вопрос «чей дневник», запись во время генерации): язык записи, о себе без рода
function T.test_service_prompts_without_persona_use_record_language()
  local none = { none = true }
  local entries = { { role = "owner", text = "ЗАП" }, { role = "diary", text = "ОТВ" } }
  for name, s in pairs({
      summarize = prompt.summarize(entries, nil, none)[1].content,
      roll = prompt.roll(nil, entries, none)[1].content }) do
    t.ok(has(s, "на языке записи"), name .. ": язык записи")
    t.ok(has(s, "о себе без рода"), name .. ": без рода")
    t.ok(not has(s, "по-русски") and not has(s, "мужском") and not has(s, "женском"), name .. ": нет русского и рода")
    t.ok(has(s, "магический дневник"), name .. ": имя прежнее")
  end
end

function T.test_summarize_uses_persona_gender_and_kind()
  local entries = { { role = "owner", text = "ЗАП" }, { role = "diary", text = "ОТВ" } }
  local m = prompt.summarize(entries, "РАНЬШЕ", EN_F)
  local s = m[1].content
  t.ok(has(s, "Ты — записная книжка"), "kind вместо «магический дневник»")
  t.ok(has(s, "о себе в женском роде («поняла», «ждала»)"), "род персоны")
  t.ok(not has(s, "мужском") and not has(s, "магический дневник"), "нет «Методов»")
  t.ok(has(s, "английский"), "пересказ — на языке персоны")
  t.ok(has(s, "без рода и без обращений по роли") and has(s, "как пишущий называет себя сам"), "правила пишущего")
  t.eq(m[2].content, prompt.summarize(entries, "РАНЬШЕ")[2].content, "реплики те же")
end

function T.test_roll_uses_persona_gender_and_kind()
  local entries = { { role = "owner", text = "ЗАП" }, { role = "diary", text = "ОТВ" } }
  local m = prompt.roll("ПРЕЖНЕЕ", entries, EN_F)
  local s = m[1].content
  t.ok(has(s, "Ты — записная книжка"), "kind")
  t.ok(has(s, "о себе в женском роде («поняла», «ждала»)") and not has(s, "мужском"), "род персоны")
  t.ok(has(s, "английский"), "язык персоны")
  t.ok(has(s, "без рода и без обращений по роли"), "правила пишущего")
  t.eq(m[2].content, prompt.roll("ПРЕЖНЕЕ", entries)[2].content, "реплики и прежний пересказ те же")
end

-- запрос мира: ответ на языке персоны (бэклог ревью задачи 4), не «по-русски» для английской
function T.test_gen_world_in_persona_language()
  local en = prompt.gen_world(EN_F, "Hermione Granger")[1].content
  t.ok(not has(en, "по-русски"), "английская персона: " .. en)
  t.ok(has(en, "английский"), "язык мира — lang_name")
  local ru = prompt.gen_world({ head = "г.", body = "т.", lang = "ru", gender = "f" }, "Гермиона")[1].content
  t.ok(has(ru, "по-русски"), "русская — по-русски")
end

-- запрос генерации персоны по строке: строка дословно, ответ — JSON со всеми ключами раздела
function T.test_gen_persona_prompt()
  local m = prompt.gen_persona("Гермиона Грейнджер")
  t.eq(#m, 2)
  t.eq(m[1].role, "system")
  local all = m[1].content .. m[2].content
  t.ok(has(m[2].content, "Гермиона Грейнджер"), "строка дословно")
  for _, k in ipairs({ '"head"', '"body"', '"lang"', '"lang_name"', '"gender"', '"kind"', '"title"' }) do
    t.ok(has(all, k), "ключ " .. k)
  end
  t.ok(not has(all, "image_url"), "без картинки")
end

-- запрос мира персонажа: голос персоны, строка дословно, ответ — текст (не JSON), потолок знаков в запросе
function T.test_gen_world_prompt()
  local view = { head = "дневник ГОЛОВА-МАРКЕР.", body = "ТЕЛО-МАРКЕР.", lang = "ru", gender = "f" }
  local m = prompt.gen_world(view, "Гермиона Грейнджер")
  t.eq(#m, 2)
  t.eq(m[1].role, "system")
  t.ok(has(m[1].content, "ГОЛОВА-МАРКЕР") and has(m[1].content, "ТЕЛО-МАРКЕР"), "голос персонажа")
  t.ok(has(m[2].content, "Гермиона Грейнджер"), "строка дословно")
  t.ok(not has(m[1].content .. m[2].content, "image_url"), "без картинки")
end

local function utf8_chars(s) return select(2, s:gsub("[^\128-\191]", "")) end

-- lore.md первым и целиком до потолка, мир — в остаток; при обоих первой строкой — правило «верен lore.md»
function T.test_lore_md_first_world_in_rest()
  local md, world = string.rep("л", 9000), string.rep("м", 4000)
  local b = prompt.lore_block(md, world, 10000)
  local head = prompt.LORE_WINS .. "\n"
  t.eq(b:sub(1, #head), head, "LORE_WINS — первой строкой")
  local body = b:sub(#head + 1)
  t.eq(body:sub(1, #md), md, "lore.md первым и целиком")
  t.eq(utf8_chars(b), 10000, "блок целиком (правило, lore.md, мир) — ровно потолок")
  t.ok(has(body, "м") and not has(body, world), "мир урезан до остатка")
end

-- мира нет — блок прежний (промпты «Методов» не меняются); мир один — без правила, ему не с чем расходиться
function T.test_lore_only_unchanged()
  t.eq(prompt.lore_block("ЛОР", nil, 10000), "ЛОР")
  t.eq(prompt.lore_block("ЛОР", "", 10000), "ЛОР")
  t.eq(prompt.lore_block("", nil, 10000), "")
  t.eq(prompt.lore_block(nil, nil, 10000), "")
  t.eq(prompt.lore_block("ЛОР", nil, nil), "ЛОР", "без потолка — как есть")
  t.eq(utf8_chars(prompt.lore_block(string.rep("л", 12000), nil, 10000)), 10000, "lore.md — до потолка")
  local only_world = prompt.lore_block("", "МИР-МАРКЕР", 10000)
  t.ok(has(only_world, "МИР-МАРКЕР"), "мир без lore.md — в блоке")
  t.ok(not has(only_world, prompt.LORE_WINS), "правила нет: расходиться не с чем")
  -- lore.md занял весь потолок — для мира места нет, правило не нужно
  local full = string.rep("л", 10000)
  t.eq(prompt.lore_block(full, "МИР-МАРКЕР", 10000), full)
end

-- prompt.fit режет раздел лора с хвоста: уходит мир, lore.md остаётся целиком
function T.test_fit_cuts_world_before_lore_md()
  local md, world = {}, {}
  for i = 1, 60 do md[i] = string.format("ЛОР-СТРОКА-%03d о тетради", i) end
  for i = 1, 40 do world[i] = string.format("МИР-СТРОКА-%03d о мире", i) end
  md, world = table.concat(md, "\n"), table.concat(world, "\n")
  local ctx = { lore = prompt.lore_block(md, world, 10000) }
  local m = prompt.open(B64, ctx)
  local full = prompt.chars(m)
  -- не хватает половины мира: lore.md цел, от мира осталась голова
  local g = prompt.fit(m, full - math.floor(utf8_chars(world) / 2))
  local s = g[1].content
  t.ok(has(s, "ЛОР-СТРОКА-060"), "lore.md цел")
  t.ok(has(s, "МИР-СТРОКА-001") and not has(s, "МИР-СТРОКА-040"), "мир урезан с хвоста")
  -- не хватает почти всего мира (его первая строка не влезает): от него ни строки, lore.md цел
  local world_part = utf8_chars(ctx.lore) - utf8_chars(prompt.LORE_WINS .. "\n" .. md)
  g = prompt.fit(m, full - (world_part - 5))
  s = g[1].content
  t.ok(not has(s, "МИР-СТРОКА"), "мира нет")
  t.ok(has(s, "ЛОР-СТРОКА-001") and has(s, "ЛОР-СТРОКА-060"), "lore.md целиком")
  t.ok(has(s, prompt.LORE_WINS), "голова раздела на месте")
end


-- запись, пока персонажа нет (план, задача 6; раздел 3б): нейтральное чтение без образа и памяти — правило «не
-- угадывай», один JSON со всеми ключами настройки; вопрос, на который ждут «да», — в запросе дословно
function T.test_setup_prompt_reads_without_persona()
  local m = prompt.setup(B64)
  t.eq(m[1].role, "system")
  local s = m[1].content
  for _, w in ipairs({ "Волдеморт", "Реддл", "Тёмного Лорда", "Характер:" }) do t.ok(not has(s, w), "без образа: " .. w) end
  t.ok(has(s, '"read":"?"'), "правило нечитаемого")
  local example = s:match("{[^{}]*}%s*$")
  t.ok(example, "пример ответа — последним: " .. s:sub(-200))
  for _, k in ipairs({ "read", "reply", "who", "world", "lang", "yes" }) do
    t.ok(has(example, '"' .. k .. '"'), "ключ примера " .. k)
  end
  t.eq(last_image(m), "data:image/png;base64," .. B64, "картинка записи")
  t.ok(not has(dump(m), "ВОПРОС-МАРКЕР"))
  t.ok(has(prompt.setup(B64, "ВОПРОС-МАРКЕР")[1].content, "ВОПРОС-МАРКЕР"), "вопрос, на который ждут «да»")
end

t.run(T)
