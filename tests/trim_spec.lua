-- Обрезка пробелов по краям: одно правило на llm.parse, llm.find_object, persona.decode_resolve, texts.fits/clean.
-- Правило: срезаются %s (пробел, \t \n \v \f \r) с обоих краёв; неразрывный пробел (U+00A0) — не пробел, остаётся;
-- не строка и пустая — "". Тесты идут через публичные входы, не через локальную функцию обрезки.
local t = require("t")
local json = require("dkjson")
local llm = require("riddle.llm")
local persona = require("riddle.persona")
local texts = require("riddle.texts")
local str = require("riddle.str")

local T = {}

local NBSP = "\194\160"
local PADS = { " ", "\n", "\t", "\r\n", " \t\n " }

local function resp(content) return json.encode({ choices = { { message = { content = content } } } }) end
local function parse_json(o) return llm.parse(200, resp(json.encode(o)), true) end

function T.test_llm_text_answer_is_trimmed()
  for _, pad in ipairs(PADS) do
    local r = llm.parse(200, resp(pad .. "привет, друг" .. pad), false)
    t.eq(r.text, "привет, друг", "pad=" .. pad)
  end
  t.eq(llm.parse(200, resp("привет  \n  друг"), false).text, "привет  \n  друг", "внутри не трогается")
end

function T.test_llm_text_answer_blank_is_empty()
  for _, pad in ipairs(PADS) do
    local r, err = llm.parse(200, resp(pad), false)
    t.eq(r, nil, "pad=" .. pad)
    t.eq(err, "empty text")
  end
end

function T.test_llm_nbsp_is_not_trimmed()
  t.eq(llm.parse(200, resp(NBSP .. "привет" .. NBSP), false).text, NBSP .. "привет" .. NBSP)
  t.eq(llm.parse(200, resp(NBSP), false).text, NBSP, "один неразрывный пробел — не пустой ответ")
end

function T.test_llm_json_read_reply_are_trimmed()
  local r = parse_json({ read = " \n прочитал\t", reply = "\r\n ответ \n" })
  t.eq(r.read, "прочитал")
  t.eq(r.reply, "ответ")
  t.eq(parse_json({ read = NBSP .. "x" .. NBSP, reply = NBSP }).read, NBSP .. "x" .. NBSP)
  t.eq(parse_json({ read = NBSP .. "x" .. NBSP, reply = NBSP }).reply, NBSP)
end

function T.test_llm_json_reply_blank_or_not_string_is_empty()
  t.eq(parse_json({ read = "x", reply = " \n\t " }).reply, "")
  t.eq(parse_json({ read = "x", reply = 5 }).reply, "")
  t.eq(parse_json({ read = "x" }).reply, "")
  t.eq(parse_json({ read = "x", reply = json.null }).reply, "")
end

function T.test_llm_json_optional_strings_trimmed()
  local r = parse_json({ read = "x", task = "  дело \n", tasks_source = "\tкнига ", who = " Гарри ", world = "\nМир\n",
    lang = " RU " })
  t.eq(r.task, "дело")
  t.eq(r.tasks_source, "книга")
  t.eq(r.who, "Гарри")
  t.eq(r.world, "Мир")
  t.eq(r.lang, "RU")
end

function T.test_llm_json_optional_strings_blank_or_not_string()
  local r = parse_json({ read = "x", task = "  ", tasks_source = 7, who = " \n", world = false, lang = "\t" })
  t.eq(r.task, "")
  t.eq(r.tasks_source, nil)
  t.eq(r.who, nil)
  t.eq(r.world, nil)
  t.eq(r.lang, nil)
end

function T.test_llm_json_picks_trimmed_and_blank_dropped()
  local r = parse_json({ read = "x", picks = { " a ", "", "  \n", 5, "\tb\n" } })
  t.eq(#r.picks, 2)
  t.eq(r.picks[1], "a")
  t.eq(r.picks[2], "b")
  t.eq(parse_json({ read = "x", picks = "  одно \n" }).picks[1], "одно")
end

function T.test_llm_find_object_through_padding_and_fence()
  for _, pad in ipairs(PADS) do
    t.eq(llm.find_object(pad .. '{"a":1}' .. pad).a, 1, "pad=" .. pad)
    t.eq(llm.find_object(pad .. '```json' .. pad .. '{"a":2}' .. pad .. '```' .. pad).a, 2, "fence pad=" .. pad)
  end
  t.eq(llm.find_object("   "), nil)
end

local function decode(o) return persona.decode_resolve(json.encode(o), "гарри поттер") end

function T.test_persona_resolve_fields_trimmed()
  local r = decode({ who = " \n Гарри Поттер\t", world = "\tХогвартс \r\n", lang = " RU\n", ask = "  Так это  \n дневник?  " })
  t.eq(r.state, "confirm")
  t.eq(r.line, "Гарри Поттер — Хогвартс")
  t.eq(r.lang, "ru")
  t.eq(r.ask, "Так это дневник?", "края срезаны, внутренние пробелы схлопнуты")
end

function T.test_persona_resolve_blank_or_not_string_fields()
  t.eq(select(2, decode({ who = " \n\t", world = "м" })), "no who")
  t.eq(select(2, decode({ who = 5, world = "м" })), "no who")
  t.eq(decode({ who = "Гарри", world = "  \n" }).state, "rejected")
  t.eq(decode({ who = "Гарри", world = 42 }).state, "rejected")
  local r = decode({ who = "Гарри", world = "Мир", ask = "  \n " })
  t.eq(r.ask, "Так это дневник Гарри из Мир?", "пустой вопрос модели — шаблон")
end

function T.test_persona_resolve_nbsp_not_trimmed()
  local r = decode({ who = NBSP .. "Гарри", world = "Мир" })
  t.eq(r.line, NBSP .. "Гарри — Мир")
  t.eq(decode({ who = NBSP, world = "Мир" }).state, "confirm", "один NBSP — не пустое имя")
end

local RULE = { max_cps = 20, sentences = 1 }

function T.test_texts_fits_ignores_padding()
  for _, pad in ipairs(PADS) do
    t.ok(texts.fits(RULE, pad .. "привет" .. pad), "pad=" .. pad)
    t.ok(not texts.fits(RULE, pad), "пустая pad=" .. pad)
  end
  t.ok(not texts.fits(RULE, 5))
  t.ok(not texts.fits(RULE, nil))
  -- длина считается по обрезанной фразе
  t.ok(texts.fits(RULE, "  " .. string.rep("а", 20) .. "  "))
  t.ok(not texts.fits(RULE, string.rep("а", 21)))
end

function T.test_texts_fits_nbsp_not_trimmed()
  t.ok(texts.fits(RULE, NBSP), "NBSP — не пробел: фраза не пустая")
  t.ok(not texts.fits(RULE, NBSP .. string.rep("а", 20)), "NBSP входит в длину")
end

function T.test_texts_clean_trims_and_dedups()
  local kept = texts.clean("greetings", { " Здравствуй. ", "Здравствуй.", "\n", 5, "\tПривет.\n" }, "ru")
  t.eq(#kept, 2)
  t.eq(kept[1], "Здравствуй.")
  t.eq(kept[2], "Привет.")
end

-- Прямой вход str.trim: края контракта и время. Раньше match("^%s*(.-)%s*$") был квадратичен на длинной серии
-- пробелов внутри строки (10k ≈ 440 мс); линейная обрезка укладывается в доли миллисекунды, порог — с большим запасом.
function T.test_str_trim_contract_edges()
  t.eq(str.trim(""), "")
  t.eq(str.trim(" \t\n\v\f\r "), "", "только пробелы")
  t.eq(str.trim("\t\n a b \n\t"), "a b")
  t.eq(str.trim("a"), "a")
  t.eq(str.trim("a \n b"), "a \n b", "внутри не трогается")
  t.eq(str.trim(NBSP .. "x" .. NBSP), NBSP .. "x" .. NBSP, "NBSP по краям остаётся")
  t.eq(str.trim(" " .. NBSP .. " "), NBSP, "NBSP среди пробелов остаётся")
  t.eq(str.trim(nil), "")
  t.eq(str.trim(5), "")
  t.eq(str.trim({}), "")
end

function T.test_str_trim_long_inner_whitespace_run_is_linear()
  local mid = string.rep(" ", 10000)
  local s = "  a" .. mid .. "b  "
  local t0 = os.clock()
  local r = str.trim(s)
  local dt = os.clock() - t0
  t.eq(r, "a" .. mid .. "b")
  t.ok(dt < 0.05, "10k пробелов внутри: " .. string.format("%.1f мс", dt * 1000))
  t0 = os.clock()
  t.eq(str.trim(string.rep(" ", 10000)), "")
  t.eq(str.trim(string.rep(" ", 10000) .. "x"), "x")
  t.eq(str.trim("x" .. string.rep(" ", 10000)), "x")
  dt = os.clock() - t0
  t.ok(dt < 0.05, "10k пробелов по краям: " .. string.format("%.1f мс", dt * 1000))
end

t.run(T)
