local t = require("t")
local json = require("dkjson")
local llm = require("riddle.llm")

local T = {}

local CFG = { groq_key = "k_groq", stale_key = "k_stale", gemini_key = "k_gem" }
local BEAT_URL = "https://api.beatapi.io/v1/chat/completions"
local BEAT = { name = "beatapi", url = BEAT_URL, model = "deepseek-v4.1-flash-free", key = "k_bt", after_legacy = true, max_tokens = 400 }
local CFG2 = { gemini_key = "k_gem", providers = { BEAT } }
-- цепочка из двух провайдеров: проверяет сам механизм call (фолбэк, бюджет), не состав боевой цепочки
local function stub(name, url) return { name = name, url = url, model = "m", headers = { ["User-Agent"] = "riddle-diary/1.0" } } end
local CHAIN = {
  stub("gemini", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
  stub("reserve", "https://reserve.test/chat/completions"),
}
local IMG_MSGS = {
  { role = "system", content = "s" },
  { role = "user", content = { { type = "text", text = "x" }, { type = "image_url", image_url = { url = "data:image/png;base64,AAAA" } } } },
}
local TXT_MSGS = { { role = "system", content = "s" }, { role = "user", content = "x" } }

local function resp(content) return json.encode({ choices = { { message = { content = content } } } }) end
local function ok_json(read, reply) return resp(json.encode({ read = read, reply = reply })) end

local function which(url)
  if url:find("reserve.test", 1, true) then return "reserve" end
  if url:find("proxy.test", 1, true) then return "proxy" end
  if url:find("googleapis", 1, true) then return "gemini" end
  if url:find("beatapi.io", 1, true) then return "beatapi" end
end

-- parse ---------------------------------------------------------------

function T.test_parse_plain_json()
  local r = llm.parse(200, ok_json("привет", "Здравствуй, я слушаю."), true)
  t.eq(r.read, "привет")
  t.eq(r.reply, "Здравствуй, я слушаю.")
end

function T.test_parse_fenced_json()
  local content = "```json\n" .. json.encode({ read = "привет", reply = "Здравствуй." }) .. "\n```"
  local r = llm.parse(200, resp(content), true)
  t.eq(r.read, "привет")
  t.eq(r.reply, "Здравствуй.")
end

function T.test_parse_json_inside_text()
  local content = 'Вот ответ: {"read":"привет","reply":"Здравствуй."} Надеюсь, помогло.'
  local r = llm.parse(200, resp(content), true)
  t.eq(r.read, "привет")
  t.eq(r.reply, "Здравствуй.")
end

function T.test_parse_strips_think()
  local content = "<think>рассуждаю…</think>" .. json.encode({ read = "а", reply = "б" })
  local r = llm.parse(200, resp(content), true)
  t.eq(r.reply, "б")
end

-- обрезанный по max_tokens ответ (finish_reason=length) — промах в обоих режимах: пересказ сессии
-- (want_json=false) не должен сохранить оборванный текст
local function resp_fin(content, fin)
  return json.encode({ choices = { { message = { content = content }, finish_reason = fin } } })
end

function T.test_parse_truncated_is_miss()
  local r, err = llm.parse(200, resp_fin("Сегодня ты писал о море и о", "length"), false)
  t.eq(r, nil, "обрезанный пересказ не принимается")
  t.ok(tostring(err):find("truncated", 1, true), tostring(err))
  local r2, err2 = llm.parse(200, resp_fin(json.encode({ read = "а", reply = "б" }), "length"), true)
  t.eq(r2, nil, "обрезанный ответ в режиме JSON — тоже промах")
  t.ok(tostring(err2):find("truncated", 1, true), tostring(err2))
end

-- причина обрыва по-своему ("max_tokens", любой регистр) — тоже обрезок
function T.test_parse_truncated_other_spelling()
  t.eq(llm.parse(200, resp_fin("Сегодня ты", "max_tokens"), false), nil)
  t.eq(llm.parse(200, resp_fin("Сегодня ты", "MAX_TOKENS"), false), nil)
  t.eq(llm.parse(200, resp_fin("Сегодня ты", "LENGTH"), false), nil)
end

function T.test_parse_stop_is_ok()
  local r = llm.parse(200, resp_fin("Пересказ.", "stop"), false)
  t.eq(r.text, "Пересказ.")
end

-- незакрытый <think> в начале ответа (модель ушла в рассуждение и оборвалась) — вырезается до конца текста
function T.test_parse_strips_unclosed_think()
  local r, err = llm.parse(200, resp("<think>рассуждаю и не закончил"), false)
  t.eq(r, nil, "в пересказ рассуждение не уходит")
  t.eq(err, "empty text")
  local r2, err2 = llm.parse(200, resp(" \n\t<think>рассуждаю"), false)
  t.eq(r2, nil, "пробелы перед <think> — тоже начало ответа")
  t.eq(err2, "empty text")
  local r3, err3 = llm.parse(200, resp("<think>x</think>\n<think>ещё"), false)
  t.eq(r3, nil, "после закрытого рассуждения — снова начало ответа")
  t.eq(err3, "empty text")
end

-- литерал «<think>» не в начале ответа — часть текста: вырезать его до конца — сломать ответ («not json»)
function T.test_parse_keeps_unclosed_think_inside_text()
  local r = llm.parse(200, resp(json.encode({ read = "что такое <think>", reply = "Тег <think> — просто слово." })), true)
  t.ok(r, "JSON с <think> в строке разобран")
  t.eq(r.read, "что такое <think>")
  t.eq(r.reply, "Тег <think> — просто слово.")
  local r2 = llm.parse(200, resp("<think>x</think>" .. json.encode({ read = "а <think>", reply = "б" })), true)
  t.eq(r2 and r2.read, "а <think>", "закрытое рассуждение вырезано, литерал в строке цел")
  local r3 = llm.parse(200, resp("Пересказ. <think>а потом"), false)
  t.eq(r3.text, "Пересказ. <think>а потом", "в пересказе — тоже текст")
end

-- read без reply доходит до контроллера: заветное слово на закрытой печати снимает её и без reply
function T.test_parse_empty_reply_keeps_read()
  local r = llm.parse(200, ok_json("НОЧЬ", ""), true)
  t.eq(r.read, "НОЧЬ")
  t.eq(r.reply, "")
  local r2 = llm.parse(200, ok_json("привет", "   "), true)
  t.eq(r2.read, "привет")
  t.eq(r2.reply, "")
end

function T.test_parse_unreadable_may_have_empty_reply()
  local r = llm.parse(200, ok_json("?", ""), true)
  t.eq(r.read, "?")
  t.eq(r.reply, "")
end

-- ключ карты (prompt.MAP_FORMAT, prompt.map_read): только строки "open" и "close" как есть; иное — nil (карта не
-- открывается и не закрывается от похожего значения)
function T.test_parse_map_only_open()
  local function map_of(v)
    return llm.parse(200, resp(json.encode({ read = "клянусь", reply = "x", map = v })), true).map
  end
  t.eq(map_of("open"), "open")
  t.eq(map_of("close"), "close")
  for _, v in ipairs({ "true", "Open", "OPEN", " open", "", "закрыть", true, 1, { "open" } }) do
    t.eq(map_of(v), nil, "не действие карты: " .. tostring(v))
  end
  t.eq(llm.parse(200, ok_json("клянусь", "x"), true).map, nil, "ключа нет")
end

-- ключ имени (prompt.NAME_FORMAT, карта, срез 13б): как пишущий назвал себя в записи — строка без пробелов по краям;
-- пустая, из пробелов, не строка, нет ключа — nil
function T.test_parse_name_optional()
  local function name_of(v)
    return llm.parse(200, resp(json.encode({ read = "Меня зовут Гарри", reply = "x", name = v })), true).name
  end
  t.eq(name_of("Гарри"), "Гарри")
  t.eq(name_of("  Гарри Поттер "), "Гарри Поттер")
  for _, v in ipairs({ "", "   ", true, 1, { "Гарри" } }) do
    t.eq(name_of(v), nil, "не имя: " .. tostring(v))
  end
  t.eq(llm.parse(200, ok_json("Меня зовут Гарри", "x"), true).name, nil, "ключа нет")
  -- имя на карте — одна строка, как остальной текст ответа — без латинских гомоглифов (ревью 13б)
  t.eq(name_of("Гарри\nПоттер"), "Гарри Поттер", "перевод строки — пробел")
  t.eq(name_of("Гарри \t\r\n  Поттер"), "Гарри Поттер", "повтор пробелов — один")
  t.eq(name_of("Гapри"), "Гарри", "латинские a, p внутри русского имени")
  t.eq(name_of("Harry"), "Harry", "латинское имя целиком не трогается")
end

function T.test_parse_not_json()
  local r, err = llm.parse(200, resp("просто текст без json"), true)
  t.eq(r, nil)
  t.ok(err)
  local r2, err2 = llm.parse(200, "<html>bad gateway</html>", true)
  t.eq(r2, nil)
  t.ok(err2)
end

function T.test_parse_http_429()
  local r, err = llm.parse(429, '{"error":"rate"}', true)
  t.eq(r, nil)
  t.ok(err:find("429", 1, true))
end

function T.test_parse_http_500()
  local r, err = llm.parse(500, "oops", false)
  t.eq(r, nil)
  t.ok(err:find("500", 1, true))
end

function T.test_parse_missing_read()
  local r = llm.parse(200, resp(json.encode({ reply = "привет" })), true)
  t.eq(r, nil, "без read ответ непригоден")
end

function T.test_parse_latin_homoglyph_reply()
  -- латинские p, e, o внутри русских слов
  local r = llm.parse(200, ok_json("x", "Пpивeт, слoвo"), true)
  t.eq(r.reply, "Привет, слово")
  -- слова целиком латиницей не трогаем
  local r2 = llm.parse(200, ok_json("x", "Я вижу OK и iPhone"), true)
  t.eq(r2.reply, "Я вижу OK и iPhone")
end

function T.test_parse_text_mode()
  local r = llm.parse(200, resp("  Ты писала мне о море.  "), false)
  t.eq(r.text, "Ты писала мне о море.")
  local r2, err = llm.parse(200, resp("   "), false)
  t.eq(r2, nil)
  t.ok(err)
end

local function make_post(handlers, log)
  return function(url, headers, body, timeout_s)
    local name = which(url)
    log[#log + 1] = { name = name, headers = headers, body = body, timeout_s = timeout_s }
    return handlers[name](timeout_s)
  end
end

-- providers / build ---------------------------------------------------

-- провайдеров задаёт только gemini_key / gemini_keys / providers: чужие ключи в конфиге цепочку не меняют
-- без providers цепочка — Gemini по ключам (gemini_key, затем gemini_keys); openrouter_key старого конфига игнорируется
function T.test_providers_without_custom_field_are_the_legacy_chain()
  local GEM = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
  local expected = {
    { "gemini", GEM, "gemini-3.5-flash-lite", 1, "Bearer ka" },
    { "gemini", GEM, "gemini-3.5-flash-lite", 2, "Bearer kb" },
  }
  for _, cfg in ipairs({ { gemini_key = "ka", gemini_keys = { "kb" }, openrouter_key = "ko" },
                         { gemini_key = "ka", gemini_keys = { "kb" }, openrouter_key = "ko", providers = {} } }) do
    local list = llm.providers(cfg)
    t.eq(#list, #expected)
    for i, e in ipairs(expected) do
      local p = list[i]
      t.eq(p.name, e[1]); t.eq(p.url, e[2]); t.eq(p.model, e[3]); t.eq(p.key, e[4])
      t.eq(p.headers["Authorization"], e[5]); t.eq(p.headers["Content-Type"], "application/json")
      t.eq(p.headers["User-Agent"], "riddle-diary/1.0")
    end
  end
end

-- providers из конфига идут первыми, затем ключи Gemini; без key нет заголовка Authorization
function T.test_custom_providers_come_first_then_legacy_keys()
  local list = llm.providers({
    gemini_key = "ka",
    providers = {
      { name = "lite", url = "https://lite.test/v1/chat/completions", model = "gpt-x", key = "kl" },
      { name = "local", url = "https://local.test/v1/chat/completions", model = "llava" },
    },
  })
  t.eq(#list, 3)
  t.eq(list[1].name, "lite"); t.eq(list[1].url, "https://lite.test/v1/chat/completions")
  t.eq(list[1].model, "gpt-x"); t.eq(list[1].headers["Authorization"], "Bearer kl")
  t.eq(list[1].key, nil, "key провайдера — номер ключа Gemini: у чужих его нет")
  t.eq(list[1].headers["User-Agent"], "riddle-diary/1.0")
  t.eq(list[2].name, "local"); t.eq(list[2].headers["Authorization"], nil, "без ключа без Authorization")
  t.eq(list[2].headers["Content-Type"], "application/json")
  t.eq(list[3].name, "gemini")
  local only = llm.providers({ providers = { { name = "x", url = "https://x.test/c", model = "m" } } })
  t.eq(#only, 1, "providers одни — цепочка из них")
  local body = select(3, llm.build(list[1], TXT_MSGS))
  t.eq(json.decode(body).model, "gpt-x")
end

-- after_legacy = true: запись идёт после ключей Gemini (запасной); без флага — первой
function T.test_after_legacy_provider_goes_last_others_stay_first()
  local list = llm.providers({
    gemini_key = "ka", gemini_keys = { "kb" },
    providers = {
      { name = "spare", url = "https://spare.test/c", model = "m", key = "ks", after_legacy = true },
      { name = "lite", url = "https://lite.test/c", model = "m", key = "kl" },
    },
  })
  local names = {}
  for i, p in ipairs(list) do names[i] = p.name end
  t.eq(table.concat(names, ","), "lite,gemini,gemini,spare")
  t.eq(list[4].headers["Authorization"], "Bearer ks")
  t.eq(list[4].key, nil, "номер ключа Gemini у запасного пуст")
  local only = llm.providers({ providers = { { name = "spare", url = "https://spare.test/c", model = "m", after_legacy = true } } })
  t.eq(#only, 1, "одного запасного хватает: цепочка из него")
end

-- ротация shift касается только ключей Gemini, порядок своих провайдеров не меняется
function T.test_shift_rotates_gemini_keys_not_custom_providers()
  local cfg = { gemini_key = "ka", gemini_keys = { "kb" },
                providers = { { name = "lite", url = "https://lite.test/c", model = "m", key = "kl" } } }
  local list = llm.providers(cfg, 1)
  t.eq(list[1].name, "lite")
  t.eq(list[2].key, 2); t.eq(list[3].key, 1)
end

-- сбой своего провайдера уводит запрос дальше по цепочке
function T.test_custom_provider_failure_falls_to_gemini()
  local calls = {}
  local post = function(url, headers)
    calls[#calls + 1] = url
    if url:find("lite.test", 1, true) then return 429, '{"error":"rate"}' end
    return 200, ok_json("привет", "Ответ Gemini.")
  end
  local list = llm.providers({ gemini_key = "ka",
    providers = { { name = "lite", url = "https://lite.test/c", model = "m", key = "kl" } } })
  local r = llm.call(list, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 8, want_json = true })
  t.eq(r.reply, "Ответ Gemini.")
  t.eq(#calls, 2)
  t.ok(calls[1]:find("lite.test", 1, true), "сначала свой")
end

-- свой провайдер завис, за ним только Gemini: потолок 4 с у своего, остаток — Gemini (часы идут на timeout_s)
function T.test_hung_custom_provider_leaves_budget_for_gemini()
  local clock, seen = 0, {}
  local post = function(url, headers, body, timeout_s)
    local name = url:find("lite.test", 1, true) and "lite" or "gemini"
    seen[#seen + 1] = string.format("%s@%d", name, timeout_s)
    if name == "lite" then clock = clock + timeout_s; return nil, "timeout" end
    return 200, ok_json("привет", "Ответ Gemini.")
  end
  local list = llm.providers({ gemini_key = "ka",
    providers = { { name = "lite", url = "https://lite.test/c", model = "m", key = "kl" } } })
  local r, err = llm.call(list, IMG_MSGS, { post = post, now = function() return clock end, budget_s = 8, want_json = true })
  t.eq(table.concat(seen, " -> "), "lite@4 -> gemini@4", tostring(err))
  t.eq(r and r.reply, "Ответ Gemini.")
end

function T.test_providers_gemini_only_even_with_extra_keys()
  local p = llm.providers(CFG)
  t.eq(#p, 1, "groq_key и прочие лишние ключи игнорируются: в цепочке один Gemini")
  t.eq(p[1].name, "gemini")
  t.eq(p[1].model, "gemini-3.5-flash-lite")
end

function T.test_extra_keys_alone_give_no_providers()
  t.eq(#llm.providers({ stale_key = "k_stale", other = "x" }), 0)
  t.eq(#llm.providers({ groq_key = "g" }), 0)
  t.eq(#llm.providers({}), 0)
end

function T.test_empty_gemini_key_is_not_a_key()
  t.eq(#llm.providers({ gemini_key = "" }), 0)
  t.eq(#llm.providers({ gemini_key = "  " }), 0, "ключ из пробелов — не ключ")
end

function T.test_gemini_url_and_bearer_header()
  local p = llm.providers(CFG)[1]
  t.eq(p.url, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
  local url, headers = llm.build(p, TXT_MSGS)
  t.eq(url, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
  t.eq(headers["Authorization"], "Bearer k_gem")
  t.eq(headers["Content-Type"], "application/json")
end

function T.test_gemini_429_gives_no_second_attempt()
  local log = {}
  local post = make_post({ gemini = function() return 429, '{"error":"rate"}' end }, log)
  local r, err = llm.call(llm.providers(CFG), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r, nil)
  t.ok(err:find("429", 1, true), tostring(err))
  t.eq(#log, 1)
  t.eq(log[1].name, "gemini")
end

-- BeatAPI (deepseek) — запасной после Gemini, затем Groq (решение владельца 2026-10-25); OpenRouter убран
function T.test_providers_beatapi_follows_gemini()
  local p = llm.providers(CFG2)
  t.eq(#p, 2)
  t.eq(p[1].name, "gemini")
  t.eq(p[2].name, "beatapi")
  t.eq(p[2].model, "deepseek-v4.1-flash-free")
end

function T.test_beatapi_url_and_bearer_header()
  local p = llm.providers(CFG2)[2]
  local url, headers = llm.build(p, IMG_MSGS)
  t.eq(url, "https://api.beatapi.io/v1/chat/completions")
  t.eq(headers["Authorization"], "Bearer k_bt")
  t.eq(headers["Content-Type"], "application/json")
end

-- openrouter_key из старого конфига цепочку не меняет: OpenRouter в ней больше нет
function T.test_openrouter_key_is_ignored()
  local p = llm.providers({ gemini_key = "k_gem", openrouter_key = "k_or" })
  t.eq(#p, 1)
  t.eq(p[1].name, "gemini")
  t.eq(#llm.providers({ openrouter_key = "k_or" }), 0, "одного openrouter_key на цепочку нет")
end

-- BeatAPI режет ответ на 200 токенах (finish_reason=length): max_tokens задаёт провайдер
function T.test_provider_max_tokens_goes_into_body()
  local p = llm.providers(CFG2)
  t.eq(p[2].max_tokens, 400)
  t.eq(json.decode(select(3, llm.build(p[2], IMG_MSGS))).max_tokens, 400)
  t.eq(json.decode(select(3, llm.build(p[1], IMG_MSGS))).max_tokens, 200, "у остальных по-прежнему 200")
end

-- opts.max_tokens (пересказ сессии) поднимает потолок у каждого провайдера цепочки, но не ниже его своего
function T.test_call_max_tokens_raises_ceiling_for_every_provider()
  local function bodies(max_tokens)
    local out = {}
    local post = function(url, _, body)
      out[#out + 1] = json.decode(body).max_tokens
      if which(url) == "gemini" then return 429, '{"error":"rate"}' end
      return 200, resp("Пересказ.")
    end
    llm.call(llm.providers(CFG2), TXT_MSGS, { post = post, now = function() return 0 end, budget_s = 5, max_tokens = max_tokens })
    return out
  end
  local b = bodies(800)
  t.eq(b[1], 800, "Gemini: потолок пересказа")
  t.eq(b[2], 800, "BeatAPI: 800 больше его 400")
  b = bodies(300)
  t.eq(b[1], 300)
  t.eq(b[2], 400, "свой потолок провайдера больше — остаётся он")
  b = bodies(nil)
  t.eq(b[1], 200, "без opts.max_tokens — по умолчанию")
  t.eq(b[2], 400)
end

function T.test_gemini_429_falls_to_beatapi()
  local log = {}
  local post = make_post({
    gemini = function() return 429, '{"error":"rate"}' end,
    beatapi = function() return 200, ok_json("привет", "Здравствуй.") end,
  }, log)
  local r = llm.call(llm.providers(CFG2), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.reply, "Здравствуй.")
  t.eq(r.via, "beatapi")
  t.eq(#log, 2)
  t.eq(log[1].name, "gemini")
end

function T.test_gemini_ok_never_calls_beatapi()
  local log = {}
  local post = make_post({
    gemini = function() return 200, ok_json("привет", "Здравствуй.") end,
    beatapi = function() error("BeatAPI не нужен, пока Gemini отвечает") end,
  }, log)
  local r = llm.call(llm.providers(CFG2), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.via, "gemini")
  t.eq(#log, 1)
end

-- худший случай: Gemini съел свои 4 с, BeatAPI получает остаток — общий срок не выше бюджета
function T.test_chain_worst_case_stays_within_budget()
  local clock = 0
  local log = {}
  local post = make_post({
    gemini = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
    beatapi = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
  }, log)
  local r, err = llm.call(llm.providers(CFG2), IMG_MSGS, { post = post, now = function() return clock end, budget_s = 5, want_json = true })
  t.eq(r, nil)
  t.ok(err:find("beatapi", 1, true), tostring(err))
  t.eq(#log, 2)
  t.ok(clock <= 5, "общий срок цепочки ≤ 5 с, а было " .. clock)
end

function T.test_build_body()
  local p = llm.providers(CFG)
  local url, headers, body = llm.build(p[1], IMG_MSGS)
  t.eq(url, p[1].url)
  t.eq(headers["User-Agent"], "riddle-diary/1.0")
  t.eq(headers["Authorization"], "Bearer k_gem")
  local b = json.decode(body)
  t.eq(b.model, "gemini-3.5-flash-lite")
  t.eq(b.temperature, 0.8)
  t.eq(b.max_tokens, 200)
  t.eq(b.stream, nil)
  t.eq(b.response_format, nil, "response_format не шлём никому")
  t.eq(#b.messages, 2)
end

function T.test_build_has_no_response_format()
  for _, p in ipairs(llm.providers(CFG)) do
    local _, _, with_img = llm.build(p, IMG_MSGS)
    t.eq(json.decode(with_img).response_format, nil, p.name .. " + картинка")
    local _, _, txt = llm.build(p, TXT_MSGS)
    t.eq(json.decode(txt).response_format, nil, p.name .. " без картинки")
  end
end

-- call ----------------------------------------------------------------


function T.test_fallback_on_429()
  local log = {}
  local post = make_post({
    gemini = function() return 429, '{"error":"rate"}' end,
    reserve = function() return 200, ok_json("привет", "Ответ запасного.") end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.reply, "Ответ запасного.")
  t.eq(#log, 2)
  t.eq(log[1].name, "gemini")
  t.eq(log[2].name, "reserve")
end

-- чтение страницы на карте (prompt.map_read) ответа не просит: пустой reply при прочитанном — не «запасной», цепочка
-- не идёт к следующему провайдеру. Без флага — как прежде
function T.test_reply_optional_not_spare()
  local function run(opts)
    local log = {}
    local post = make_post({
      gemini = function() return 200, resp(json.encode({ read = "шалость удалась", map = "close" })) end,
      reserve = function() return 200, ok_json("шалость удалась", "Ответ запасного.") end,
    }, log)
    opts.post, opts.now, opts.budget_s, opts.want_json = post, function() return 0 end, 5, true
    return llm.call(CHAIN, IMG_MSGS, opts), log
  end
  local r, log = run({ reply_optional = true })
  t.eq(#log, 1, "второй провайдер не звался")
  t.eq(r.via, "gemini")
  t.eq(r.map, "close")
  t.eq(r.reply, "")
  r, log = run({})
  t.eq(#log, 2, "без флага пустой reply — запасной")
  t.eq(r.via, "reserve")
end

function T.test_fallback_on_garbage_and_network_error()
  local log = {}
  local post = make_post({
    gemini = function() return nil, "timeout" end,
    reserve = function() return 200, resp("не json") end,
  }, log)
  local r, err = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r, nil)
  t.ok(err:find("reserve", 1, true), "последняя ошибка от запасного: " .. tostring(err))
  t.eq(#log, 2)
  log = {}
  post = make_post({
    gemini = function() return 200, resp("не json") end,
    reserve = function() return 200, ok_json("привет", "Ответ запасного.") end,
  }, log)
  r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.reply, "Ответ запасного.")
  t.eq(#log, 2)
end

-- пустой reply при прочитанной записи — запасной результат: сначала следующий провайдер
function T.test_empty_reply_tries_next_provider()
  local log = {}
  local post = make_post({
    gemini = function() return 200, ok_json("привет", "") end,
    reserve = function() return 200, ok_json("привет", "Ответ запасного.") end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.reply, "Ответ запасного.")
  t.eq(#log, 2)
end

function T.test_empty_reply_returned_when_others_fail()
  local log = {}
  local post = make_post({
    gemini = function() return 200, ok_json("НОЧЬ", "") end,
    reserve = function() return 500, "x" end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.read, "НОЧЬ", "запасной результат: read доходит до контроллера")
  t.eq(r.reply, "")
  t.eq(#log, 2)
end

-- via — провайдер, чей ответ вернулся: у запасного результата это первый, не последний в цепочке
function T.test_via_names_provider_whose_answer_returned()
  local log = {}
  local post = make_post({
    gemini = function() return 200, ok_json("НОЧЬ", "") end,
    reserve = function() return 500, "x" end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.via, "gemini", "запасной результат прочёл gemini, а не упавший reserve")
  post = make_post({
    gemini = function() return 429, "x" end,
    reserve = function() return 200, ok_json("привет", "Ответ запасного.") end,
  }, {})
  r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.via, "reserve")
end

function T.test_empty_reply_returned_when_budget_runs_out()
  local clock = 0
  local log = {}
  local post = make_post({
    gemini = function() clock = clock + 5; return 200, ok_json("НОЧЬ", "") end,
    reserve = function() error("бюджет кончился — reserve вызывать нельзя") end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return clock end, budget_s = 5, want_json = true })
  t.eq(r.read, "НОЧЬ")
  t.eq(#log, 1)
end

function T.test_unreadable_is_final_not_spare()
  local log = {}
  local post = make_post({
    gemini = function() return 200, ok_json("?", "") end,
    reserve = function() error("«?» — окончательный ответ, reserve не нужен") end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.read, "?")
  t.eq(#log, 1)
end

function T.test_all_fail_returns_last_error()
  local log = {}
  local post = make_post({
    gemini = function() return 500, "x" end,
    reserve = function() return 500, "x" end,
  }, log)
  local r, err = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r, nil)
  t.ok(err:find("500", 1, true), "последняя ошибка: " .. tostring(err))
  t.eq(#log, 2)
end

function T.test_budget_remainder_goes_to_next_provider()
  local clock = 0
  local log = {}
  local post = make_post({
    gemini = function() clock = clock + 4; return nil, "timeout" end,
    reserve = function() clock = clock + 1; return nil, "timeout" end,
  }, log)
  local r, err = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return clock end, budget_s = 5, want_json = true })
  t.eq(r, nil)
  t.ok(err:find("reserve", 1, true), tostring(err))
  t.eq(#log, 2)
  t.eq(log[1].timeout_s, 4, "gemini: min(4, 5)")
  t.ok(log[2].timeout_s <= 1, "reserve: остаток бюджета ≤ 1 с, а было " .. tostring(log[2].timeout_s))
  t.ok(log[2].timeout_s > 0)
end

-- последний провайдер цепочки получает весь остаток бюджета, а не min(4, остаток)
function T.test_single_provider_gets_whole_budget()
  local log = {}
  local post = make_post({ gemini = function() return nil, "timeout" end }, log)
  llm.call(llm.providers({ gemini_key = "k_gem" }), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 10, want_json = true })
  t.eq(#log, 1)
  t.eq(log[1].timeout_s, 10, "единственный провайдер: весь бюджет")
end

function T.test_gemini_then_beatapi_first_capped_second_gets_remainder()
  local clock = 0
  local log = {}
  local post = make_post({
    gemini = function() clock = clock + 1; return 429, '{"error":"rate"}' end,
    beatapi = function() return nil, "timeout" end,
  }, log)
  llm.call(llm.providers(CFG2), IMG_MSGS, { post = post, now = function() return clock end, budget_s = 10, want_json = true })
  t.eq(#log, 2)
  t.eq(log[1].timeout_s, 4, "gemini: за ним есть BeatAPI — потолок 4 с")
  t.eq(log[2].timeout_s, 9, "beatapi: весь остаток бюджета")
end

-- за ключом остались только ключи того же хоста: при транспортном сбое они пропустятся — ждём весь остаток
function T.test_two_gemini_keys_without_spare_first_gets_whole_budget()
  local log = {}
  local post = make_post({ gemini = function() return nil, "timeout" end }, log)
  llm.call(llm.providers({ gemini_keys = { "kA", "kB" } }), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 10, want_json = true })
  t.eq(#log, 1, "транспортный сбой — второй ключ пропущен")
  t.eq(log[1].timeout_s, 10, "ключ 1: весь бюджет")
end

function T.test_two_gemini_keys_http_error_second_gets_remainder()
  local clock = 0
  local log = {}
  local post = make_post({ gemini = function() clock = clock + 1; return 429, '{"error":"rate"}' end }, log)
  llm.call(llm.providers({ gemini_keys = { "kA", "kB" } }), IMG_MSGS, { post = post, now = function() return clock end, budget_s = 10, want_json = true })
  t.eq(#log, 2)
  t.eq(log[1].timeout_s, 10)
  t.eq(log[2].timeout_s, 9, "ключ 2: остаток после 429")
end

function T.test_two_gemini_keys_with_beatapi_first_capped()
  local log = {}
  local post = make_post({
    gemini = function() return nil, "timeout" end,
    beatapi = function() return nil, "timeout" end,
  }, log)
  llm.call(llm.providers({ gemini_keys = { "kA", "kB" }, providers = { BEAT } }), IMG_MSGS,
    { post = post, now = function() return 0 end, budget_s = 10, want_json = true })
  t.eq(#log, 2, "ключ 2 пропущен, beatapi идёт")
  t.eq(log[1].timeout_s, 4, "ключ 1: дальше есть BeatAPI — потолок 4 с")
end

-- первые двое висят до потолка попытки: последнему остаётся не меньше reserve_s, а не 25 − 12 − 12 = 1 с
function T.test_hung_first_two_leave_reserve_for_last()
  local clock = 0
  local log = {}
  local GROQ = { name = "groq", url = "https://reserve.test/chat/completions", model = "m", key = "k_gq", after_legacy = true }
  local post = make_post({
    gemini = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
    reserve = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
    beatapi = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
  }, log)
  llm.call(llm.providers({ gemini_key = "k_gem", providers = { GROQ, BEAT } }), IMG_MSGS,
    { post = post, now = function() return clock end, budget_s = 25, attempt_s = 12, reserve_s = 7, want_json = true })
  t.eq(#log, 3)
  t.eq(log[1].name, "gemini")
  t.eq(log[1].timeout_s, 12, "gemini: min(12, 25 − 7)")
  t.eq(log[2].name, "reserve")
  t.eq(log[2].timeout_s, 6, "groq: min(12, 13 − 7)")
  t.eq(log[3].name, "beatapi")
  t.ok(log[3].timeout_s >= 7, "последний получает не меньше резерва, а получил " .. tostring(log[3].timeout_s))
end

-- остаток не больше резерва: не-последний пропускается, весь остаток — последнему
function T.test_no_room_above_reserve_skips_to_last()
  local clock = 0
  local log = {}
  local post = make_post({
    gemini = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
    beatapi = function() return nil, "timeout" end,
  }, log)
  llm.call(llm.providers(CFG2), IMG_MSGS,
    { post = post, now = function() return clock end, budget_s = 6, attempt_s = 12, reserve_s = 7, want_json = true })
  t.eq(#log, 1, "gemini пропущен: места сверх резерва нет")
  t.eq(log[1].name, "beatapi")
  t.eq(log[1].timeout_s, 6)
end

-- места сверх резерва меньше MIN_ATTEMPT_S (2 с), включая ровно 0, — не-последний пропускается:
-- запрос с таймаутом 0 или долями секунды заведомо пропадёт. Ровно 2 с — попытка идёт
local function first_attempt(budget_s)
  local log = {}
  local post = make_post({
    gemini = function() return nil, "timeout" end,
    beatapi = function() return nil, "timeout" end,
  }, log)
  llm.call(llm.providers(CFG2), IMG_MSGS,
    { post = post, now = function() return 0 end, budget_s = budget_s, attempt_s = 12, reserve_s = 7, want_json = true })
  return log[1]
end

function T.test_room_below_min_attempt_skips()
  t.eq(first_attempt(7).name, "beatapi", "room = 0: gemini пропущен")
  t.eq(first_attempt(8.9).name, "beatapi", "room = 1.9 < 2: gemini пропущен")
  local a = first_attempt(9)
  t.eq(a.name, "gemini", "room = 2: попытка идёт")
  t.eq(a.timeout_s, 2)
end

function T.test_beatapi_alone_gets_whole_budget()
  local log = {}
  local post = make_post({ beatapi = function() return nil, "timeout" end }, log)
  llm.call(llm.providers({ providers = { BEAT } }), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 10, want_json = true })
  t.eq(log[1].timeout_s, 10)
end

function T.test_budget_exhausted_stops_chain()
  local clock = 0
  local log = {}
  local post = make_post({
    gemini = function() clock = clock + 5; return nil, "timeout" end,
    reserve = function() error("бюджет кончился — reserve вызывать нельзя") end,
  }, log)
  local r, err = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return clock end, budget_s = 5, want_json = true })
  t.eq(r, nil)
  t.eq(err, "budget")
  t.eq(#log, 1)
end

function T.test_user_agent()
  local log = {}
  local post = make_post({
    gemini = function() return 429, "x" end,
    reserve = function() return 200, ok_json("а", "б") end,
  }, log)
  llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(#log, 2)
  for _, c in ipairs(log) do
    t.eq(c.headers["User-Agent"], "riddle-diary/1.0", c.name)
  end
end

function T.test_call_first_provider_is_gemini()
  local log = {}
  local post = make_post({
    gemini = function() return 200, ok_json("а", "б") end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.reply, "б")
  t.eq(log[1].name, "gemini")
end

function T.test_call_text_mode()
  local log = {}
  local post = make_post({
    gemini = function() return 200, resp("Ты писала мне о море.") end,
  }, log)
  local r = llm.call(CHAIN, TXT_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = false })
  t.eq(r.text, "Ты писала мне о море.")
end

function T.test_post_throws_does_not_crash()
  local log = {}
  local post = make_post({
    gemini = function() error("dns failure") end,
    reserve = function() return 200, ok_json("а", "б") end,
  }, log)
  local r = llm.call(CHAIN, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 5, want_json = true })
  t.eq(r.reply, "б")
end

function T.test_call_no_providers()
  local r, err = llm.call({}, IMG_MSGS, { post = function() error("не должно вызываться") end, now = function() return 0 end, budget_s = 5 })
  t.eq(r, nil)
  t.eq(err, "no providers")
end

-- несколько ключей Gemini -----------------------------------------------

local KEYS = { gemini_key = "k1", gemini_keys = { "k2", "k1", "k3" }, providers = { BEAT } }
local function bearers(list)
  local out = {}
  for _, p in ipairs(list) do out[#out + 1] = p.name .. "=" .. p.headers["Authorization"]:gsub("^Bearer ", "") end
  return table.concat(out, " ")
end

function T.test_each_gemini_key_is_a_provider_before_beatapi()
  local p = llm.providers(KEYS)
  t.eq(bearers(p), "gemini=k1 gemini=k2 gemini=k3 beatapi=k_bt", "дубль k1 убран, BeatAPI последний")
  t.eq(p[1].key, 1); t.eq(p[2].key, 2); t.eq(p[3].key, 3)
end

function T.test_gemini_keys_without_gemini_key()
  t.eq(bearers(llm.providers({ gemini_keys = { "", "  ", 5, "k2" } })), "gemini=k2", "пустые и не-строки — не ключи")
end

function T.test_start_key_rotates_by_shift()
  t.eq(bearers(llm.providers(KEYS, 1)), "gemini=k2 gemini=k3 gemini=k1 beatapi=k_bt")
  t.eq(bearers(llm.providers(KEYS, 5)), "gemini=k3 gemini=k1 gemini=k2 beatapi=k_bt")
  local p = llm.providers(KEYS, 1)
  t.eq(p[1].key, 2, "номер ключа — его место в конфиге, не в очереди")
end

function T.test_429_on_first_key_tries_second()
  local seen = {}
  local post = function(url, headers, body, timeout_s, p)
    seen[#seen + 1] = headers["Authorization"] .. "#" .. tostring(p and p.key)
    if headers["Authorization"] == "Bearer k1" then return 429, '{"error":"rate"}' end
    return 200, ok_json("кто ты", "Я здесь.")
  end
  local r = llm.call(llm.providers(KEYS), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 8, want_json = true })
  t.ok(r, "второй ключ ответил")
  t.eq(r.reply, "Я здесь.")
  t.eq(table.concat(seen, " "), "Bearer k1#1 Bearer k2#2", "post получает провайдера с номером ключа")
end

-- транспортный сбой (таймаут, нет сети) на ключе Gemini: остальные ключи того же хоста пропускаются
function T.test_transport_failure_skips_remaining_gemini_keys_to_beatapi()
  local seen = {}
  local post = function(url, headers, body, timeout_s, p)
    seen[#seen + 1] = headers["Authorization"]
    if p.name == "beatapi" then return 200, ok_json("кто ты", "Я здесь.") end
    return nil, "timeout"
  end
  local r = llm.call(llm.providers(KEYS), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 8, want_json = true })
  t.ok(r, "BeatAPI ответил")
  t.eq(r.via, "beatapi")
  t.eq(table.concat(seen, " "), "Bearer k1 Bearer k_bt", "k2 и k3 пропущены после таймаута k1")
end

function T.test_pcall_error_on_gemini_key_also_skips_remaining_keys()
  local seen = {}
  local post = function(url, headers, body, timeout_s, p)
    seen[#seen + 1] = headers["Authorization"]
    if p.name == "beatapi" then return 200, ok_json("кто ты", "Я здесь.") end
    error("boom")
  end
  local r, err = llm.call(llm.providers(KEYS), IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 8, want_json = true })
  t.ok(r, tostring(err))
  t.eq(table.concat(seen, " "), "Bearer k1 Bearer k_bt")
end

function T.test_transport_failure_without_spare_ends_chain()
  local n = 0
  local post = function() n = n + 1; return nil, "timeout" end
  local r, err = llm.call(llm.providers({ gemini_keys = { "k1", "k2" } }), IMG_MSGS,
    { post = post, now = function() return 0 end, budget_s = 8, want_json = true })
  t.eq(r, nil)
  t.eq(n, 1, "второй ключ не пробуем")
  t.ok(tostring(err):find("timeout", 1, true), tostring(err))
end

-- обрезанный пересказ у первого — цепочка идёт к следующему, а не возвращает обрывок
function T.test_truncated_text_falls_back_to_next()
  local log = {}
  local post = make_post({
    gemini = function() return 200, resp_fin("Сегодня ты писал о", "length") end,
    reserve = function() return 200, resp_fin("Пересказ целиком.", "stop") end,
  }, log)
  local r = llm.call(CHAIN, TXT_MSGS, { post = post, now = function() return 0 end, budget_s = 10, want_json = false })
  t.eq(r.text, "Пересказ целиком.")
  t.eq(r.via, "reserve")
  t.eq(#log, 2)
end


-- лимит входа провайдера (max_input_chars): запрос ему — через opts.fit(messages, лимит); остальным — как есть
function T.test_provider_with_input_limit_gets_fitted_messages()
  local list = llm.providers({ gemini_key = "k_gem", providers = {
    { name = "groq", url = "https://reserve.test/chat/completions", model = "m", key = "k_g", after_legacy = true,
      max_input_chars = 1234 } } })
  t.eq(list[1].max_input_chars, nil, "у Gemini лимита нет")
  t.eq(list[2].max_input_chars, 1234, "лимит из конфига")
  local bodies, fits = {}, {}
  local short = { { role = "system", content = "коротко" }, { role = "user", content = "x" } }
  local post = function(url, _, body)
    bodies[#bodies + 1] = json.decode(body).messages
    if which(url) == "gemini" then return 429, '{"error":"rate"}' end
    return 200, resp("ок")
  end
  local fit = function(messages, limit)
    fits[#fits + 1] = limit
    t.ok(rawequal(messages, TXT_MSGS), "fit получает исходный запрос")
    return short
  end
  llm.call(list, TXT_MSGS, { post = post, now = function() return 0 end, budget_s = 5, fit = fit })
  t.eq(#bodies, 2)
  t.eq(bodies[1][1].content, "s", "Gemini — полный запрос")
  t.eq(#bodies[1], 2)
  t.eq(bodies[2][1].content, "коротко", "провайдер с лимитом — урезанный")
  t.eq(#bodies[2], 2)
  t.eq(#fits, 1, "fit только для провайдера с лимитом")
  t.eq(fits[1], 1234)
end

function T.test_input_limit_without_fit_sends_full_request()
  local list = llm.providers({ providers = {
    { name = "groq", url = "https://reserve.test/chat/completions", model = "m", max_input_chars = 10 } } })
  local sent
  local post = function(_, _, body) sent = json.decode(body).messages return 200, resp("ок") end
  llm.call(list, TXT_MSGS, { post = post, now = function() return 0 end, budget_s = 5 })
  t.eq(sent[1].content, "s", "без opts.fit — как есть")
  t.eq(sent[2].content, "x")
end

-- необязательные поля ответа: task (метка дела из блока) и tasks_source (название книги дел) ----------
function T.test_parse_reads_optional_task_and_tasks_source()
  local r = llm.parse(200, resp(json.encode({ read = "привет", reply = "Ответ", task = "  t2 ", tasks_source = " Дела " })), true)
  t.eq(r.task, "t2", "без пробелов по краям")
  t.eq(r.tasks_source, "Дела")
  r = llm.parse(200, resp(json.encode({ read = "x", reply = "y", task = "", tasks_source = "" })), true)
  t.eq(r.task, "", "пустая строка — значение")
  t.eq(r.tasks_source, "")
  -- в обёртке ``` и с текстом вокруг — те же поля
  r = llm.parse(200, resp('Вот: ```json\n{"read":"a","reply":"b","task":"t1"}\n```'), true)
  t.eq(r.task, "t1", "из обёртки")
  r = llm.parse(200, resp('мысли {"read":"a","reply":"b","task":"t3"} конец'), true)
  t.eq(r.task, "t3", "от { до }")
end

function T.test_parse_without_task_field_gives_nil()
  local r = llm.parse(200, ok_json("привет", "Ответ"), true)
  t.eq(r.read, "привет"); t.eq(r.reply, "Ответ")
  t.eq(r.task, nil); t.eq(r.tasks_source, nil)
  local txt = llm.parse(200, resp("просто текст"), false)
  t.eq(txt.task, nil, "текстовый режим полей не знает")
end

function T.test_parse_non_string_task_gives_nil()
  for _, raw in ipairs({ '3', 'null', '{}', '["t1"]', 'true' }) do
    local r = llm.parse(200, resp('{"read":"a","reply":"b","task":' .. raw .. ',"tasks_source":' .. raw .. '}'), true)
    t.ok(r, raw)
    t.eq(r.task, nil, "task " .. raw)
    t.eq(r.tasks_source, nil, "tasks_source " .. raw)
    t.eq(r.reply, "b", raw)
  end
end

function T.test_find_object_is_exported()
  t.eq(type(llm.find_object), "function")
  t.eq(llm.find_object('```\n{"a":1}\n```').a, 1)
  t.eq(llm.find_object("не json"), nil)
end


-- М4: классификация баз — temperature 0 через opts вызова; без opts — прежние 0.8 (ответы дневника)
function T.test_call_temperature_from_opts()
  local function temps(temperature)
    local out = {}
    local post = function(_, _, body)
      out[#out + 1] = json.decode(body).temperature
      return 200, resp("Да.")
    end
    llm.call(llm.providers(CFG2), TXT_MSGS, { post = post, now = function() return 0 end, budget_s = 5,
      temperature = temperature })
    return out
  end
  t.eq(temps(nil)[1], 0.8)
  t.eq(temps(0)[1], 0)
  t.eq(json.decode(select(3, llm.build({ url = "u", model = "m" }, TXT_MSGS))).temperature, 0.8)
end

-- picks — названия, которые советует ответ (prompt.PICKS_FORMAT): массив строк без пробелов по краям; строка вместо
-- массива — одно название; не строки и пустые — мимо; нет поля — nil
function T.test_parse_reads_picks()
  local r = llm.parse(200, resp(json.encode({ read = "a", picks = { " Брат ", "", 5, "Сестра" }, reply = "b" })), true)
  t.eq(#r.picks, 2)
  t.eq(r.picks[1], "Брат")
  t.eq(r.picks[2], "Сестра")
  r = llm.parse(200, resp(json.encode({ read = "a", picks = " Брат ", reply = "b" })), true)
  t.eq(#r.picks, 1)
  t.eq(r.picks[1], "Брат")
  r = llm.parse(200, resp('{"read":"a","picks":[],"reply":"b"}'), true)
  t.eq(#r.picks, 0, "пустой массив")
  t.eq(llm.parse(200, ok_json("a", "b"), true).picks, nil, "нет поля")
end

-- gemini-proxy (format = "gemini"): нативный generateContent через Cloudflare Worker rss_bot ------------
-- тела ответов — настоящие, сняты живым вызовом через прокси 2026-10-27 (tests/fixtures/gemini)
local function fixture(name)
  local f = assert(io.open("tests/fixtures/gemini/" .. name, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
-- настоящее тело с другим текстом ответа и причиной конца
local function native(text, finish)
  local obj = json.decode(fixture("image_200.json"))
  obj.candidates[1].content.parts[1].text = text
  if finish then obj.candidates[1].finishReason = finish end
  return json.encode(obj)
end
local PROXY = { name = "gemini-proxy", format = "gemini", url = "https://proxy.test", model = "gemini-3.5-flash-lite",
  proxy_auth = "PROXY-TOK" }

function T.test_proxy_goes_first_before_direct_gemini_keys()
  local list = llm.providers({ gemini_key = "k_gem", providers = { PROXY, BEAT } })
  t.eq(#list, 3)
  t.eq(list[1].name, "gemini-proxy")
  t.eq(list[2].name, "gemini")
  t.eq(list[3].name, "beatapi")
end

function T.test_proxy_build_is_native_generate_content()
  local p = llm.providers({ providers = { PROXY } })[1]
  local msgs = {
    { role = "system", content = "s" },
    { role = "user", content = "раньше" },
    { role = "assistant", content = "ответ" },
    IMG_MSGS[2],
  }
  local url, headers, body = llm.build(p, msgs)
  t.eq(url, "https://proxy.test/v1beta/models/gemini-3.5-flash-lite:generateContent")
  t.eq(headers["X-Proxy-Auth"], "PROXY-TOK")
  t.eq(headers["Authorization"], nil, "ключ Google ставит прокси, Bearer не нужен")
  local b = json.decode(body)
  t.eq(b.messages, nil)
  t.eq(b.model, nil, "модель — в url")
  t.eq(b.systemInstruction.parts[1].text, "s")
  t.eq(#b.contents, 3)
  t.eq(b.contents[1].role, "user")
  t.eq(b.contents[1].parts[1].text, "раньше")
  t.eq(b.contents[2].role, "model", "assistant -> model")
  t.eq(b.contents[2].parts[1].text, "ответ")
  t.eq(b.contents[3].parts[1].text, "x")
  t.eq(b.contents[3].parts[2].inlineData.mimeType, "image/png")
  t.eq(b.contents[3].parts[2].inlineData.data, "AAAA", "data: URL -> inlineData без префикса")
  t.eq(b.generationConfig.maxOutputTokens, 200)
  t.eq(b.generationConfig.temperature, 0.8)
  local _, _, body2 = llm.build(p, TXT_MSGS, 600, 0)
  local g = json.decode(body2).generationConfig
  t.eq(g.maxOutputTokens, 600, "потолок вызова поднимает потолок")
  t.eq(g.temperature, 0, "temperature вызова")
end

-- несколько system — одна systemInstruction; подряд одна роль — один ход (пустой текст не уходит)
function T.test_proxy_build_merges_system_and_same_role_turns()
  local p = llm.providers({ providers = { PROXY } })[1]
  local _, _, body = llm.build(p, {
    { role = "system", content = "a" }, { role = "system", content = "b" },
    { role = "user", content = "1" }, { role = "user", content = "" }, { role = "user", content = "2" },
  })
  local b = json.decode(body)
  t.eq(b.systemInstruction.parts[1].text, "a\n\nb")
  t.eq(#b.contents, 1)
  t.eq(#b.contents[1].parts, 2)
  t.eq(b.contents[1].parts[2].text, "2")
end

function T.test_proxy_parse_real_text_body()
  local r, err = llm.parse(200, fixture("text_200.json"), false, "gemini")
  t.eq(r and r.text, "Париж", tostring(err))
end

function T.test_proxy_parse_real_image_body_with_json_answer()
  local r, err = llm.parse(200, native('{"read": "привет", "reply": "Здравствуй."}'), true, "gemini")
  t.eq(r and r.read, "привет", tostring(err))
  t.eq(r.reply, "Здравствуй.")
end

function T.test_proxy_parse_max_tokens_is_truncated()
  local r, err = llm.parse(200, native('{"read": "при', "MAX_TOKENS"), true, "gemini")
  t.eq(r, nil)
  t.eq(err, "truncated")
end

-- текст из всех частей подряд; рассуждение (thought) — мимо
function T.test_proxy_parse_joins_parts_and_skips_thoughts()
  local obj = json.decode(fixture("text_200.json"))
  obj.candidates[1].content.parts = { { text = "думаю", thought = true }, { text = "Па" }, { text = "риж" } }
  t.eq(llm.parse(200, json.encode(obj), false, "gemini").text, "Париж")
end

function T.test_proxy_parse_blocked_prompt_is_bad_body()
  local _, err = llm.parse(200, '{"promptFeedback":{"blockReason":"SAFETY"}}', false, "gemini")
  t.eq(err, "bad body")
end

-- call разбирает ответ по формату провайдера: прокси — нативный, прямой Gemini — OpenAI
function T.test_call_parses_each_provider_by_its_format()
  local calls = {}
  local post = function(url)
    calls[#calls + 1] = url
    if url:find("proxy.test", 1, true) then return 500, "upstream fetch error" end
    return 200, ok_json("привет", "Ответ Gemini.")
  end
  local list = llm.providers({ gemini_key = "k_gem", providers = { PROXY } })
  local r = llm.call(list, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 8, want_json = true })
  t.eq(r.reply, "Ответ Gemini.")
  t.eq(#calls, 2)
  local post2 = function() return 200, native('{"read": "привет", "reply": "Ответ прокси."}') end
  local r2, err = llm.call(list, IMG_MSGS, { post = post2, now = function() return 0 end, budget_s = 8, want_json = true })
  t.eq(r2 and r2.reply, "Ответ прокси.", tostring(err))
  t.eq(r2.via, "gemini-proxy")
end

-- нет ни одной непустой части user/assistant: generateContent с contents = [] Google отвечает 400 — в сеть не идём
function T.test_proxy_build_refuses_empty_contents()
  local p = llm.providers({ providers = { PROXY } })[1]
  local url, _, err = llm.build(p, { { role = "system", content = "s" } })
  t.eq(url, nil, "только system")
  t.eq(err, "empty contents")
  local url2, _, err2 = llm.build(p, {
    { role = "user", content = { { type = "image_url", image_url = { url = "https://x.test/a.png" } } } },
    { role = "assistant", content = "" },
  })
  t.eq(url2, nil, "картинка не data:-URL и пустой текст")
  t.eq(err2, "empty contents")
end

function T.test_call_empty_contents_skips_proxy_and_falls_to_next()
  local calls = {}
  local post = function(url)
    calls[#calls + 1] = url
    return 200, ok_json("привет", "Ответ Gemini.")
  end
  local list = llm.providers({ gemini_key = "k_gem", providers = { PROXY } })
  local r, err = llm.call(list, { { role = "system", content = "s" } },
    { post = post, now = function() return 0 end, budget_s = 8, want_json = true })
  t.eq(#calls, 1, "прокси по сети не вызван")
  t.eq(calls[1] and calls[1]:find("googleapis", 1, true) ~= nil, true, "ушло к следующему провайдеру")
  t.eq(r and r.reply, "Ответ Gemini.", tostring(err))
end

function T.test_call_empty_contents_reports_error_when_proxy_is_the_only_one()
  local posted = false
  local list = llm.providers({ providers = { PROXY } })
  local r, err = llm.call(list, { { role = "system", content = "s" } },
    { post = function() posted = true return 200, "{}" end, now = function() return 0 end, budget_s = 8 })
  t.eq(posted, false)
  t.eq(r, nil)
  t.eq(err, "gemini-proxy: empty contents")
end

-- обрыв по потолку, где одни thought-части: текста нет, но причина — обрезка, не «битое тело»
function T.test_proxy_parse_max_tokens_with_only_thoughts_is_truncated()
  local obj = json.decode(fixture("text_200.json"))
  obj.candidates[1].content.parts = { { text = "думаю", thought = true } }
  obj.candidates[1].finishReason = "MAX_TOKENS"
  local r, err = llm.parse(200, json.encode(obj), false, "gemini")
  t.eq(r, nil)
  t.eq(err, "truncated")
end

-- потолок попытки gemini-proxy на пути ответа (opts.proxy_attempt_s): зависший прокси не съедает 12 с, прямому
-- Gemini остаётся min(12, 25 − 7 − 7) = 11 с вместо 6
function T.test_hung_proxy_capped_direct_gemini_gets_more()
  local clock = 0
  local log = {}
  local post = make_post({
    proxy = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
    gemini = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
    beatapi = function(timeout_s) clock = clock + timeout_s; return nil, "timeout" end,
  }, log)
  llm.call(llm.providers({ gemini_key = "k_gem", providers = { PROXY, BEAT } }), IMG_MSGS,
    { post = post, now = function() return clock end, budget_s = 25, attempt_s = 12, reserve_s = 7,
      proxy_attempt_s = 7, want_json = true })
  t.eq(#log, 3)
  t.eq(log[1].name, "proxy")
  t.eq(log[1].timeout_s, 7, "прокси: min(7, 12, 25 − 7)")
  t.eq(log[2].name, "gemini")
  t.eq(log[2].timeout_s, 11, "прямой Gemini: min(12, 18 − 7)")
  t.eq(log[3].name, "beatapi")
  t.eq(log[3].timeout_s, 7, "последний — весь остаток: резерв цел")
end

-- прокси один (за ним никого) — ждёт весь остаток, потолок прокси не действует
function T.test_proxy_alone_waits_whole_budget_despite_proxy_cap()
  local log = {}
  local post = make_post({ proxy = function() return nil, "timeout" end }, log)
  llm.call(llm.providers({ providers = { PROXY } }), IMG_MSGS,
    { post = post, now = function() return 0 end, budget_s = 25, attempt_s = 12, reserve_s = 7,
      proxy_attempt_s = 7, want_json = true })
  t.eq(#log, 1)
  t.eq(log[1].timeout_s, 25)
end

-- без proxy_attempt_s (синхронный путь) и без прокси в цепочке потолки прежние
function T.test_proxy_cap_absent_or_without_proxy_keeps_old_ceilings()
  local log = {}
  local post = make_post({
    proxy = function() return nil, "timeout" end,
    gemini = function() return nil, "timeout" end,
    beatapi = function() return nil, "timeout" end,
  }, log)
  llm.call(llm.providers({ gemini_key = "k_gem", providers = { PROXY, BEAT } }), IMG_MSGS,
    { post = post, now = function() return 0 end, budget_s = 25, attempt_s = 12, reserve_s = 7, want_json = true })
  t.eq(log[1].timeout_s, 12, "без proxy_attempt_s прокси — как прежде, потолок попытки")
  log = {}
  post = make_post({ gemini = function() return nil, "timeout" end, beatapi = function() return nil, "timeout" end }, log)
  llm.call(llm.providers(CFG2), IMG_MSGS,
    { post = post, now = function() return 0 end, budget_s = 25, attempt_s = 12, reserve_s = 7,
      proxy_attempt_s = 7, want_json = true })
  t.eq(log[1].timeout_s, 12, "прямой Gemini потолком прокси не ограничен")
end


-- поля ответа настройки (prompt.setup, план, задача 6): who, world, lang — строки без пробелов по краям, yes — только
-- булево true (строка "true" — не согласие)
function T.test_parse_setup_fields()
  local r = llm.parse(200, resp(json.encode({ read = "Р2-Д2", reply = "Так это дневник R2-D2?", who = "  R2-D2 ",
    world = " Звёздные войны ", lang = " ru ", yes = true })), true)
  t.eq(r.who, "R2-D2", "who обрезан")
  t.eq(r.world, "Звёздные войны")
  t.eq(r.lang, "ru")
  t.eq(r.yes, true)
  r = llm.parse(200, resp('{"read":"да","reply":"ок","yes":"true","who":3}'), true)
  t.eq(r.yes, nil, "строка \"true\" — не да")
  t.eq(r.who, nil, "не строка — nil")
  r = llm.parse(200, resp('{"read":"нет","reply":"ок","yes":false}'), true)
  t.eq(r.yes, nil)
  t.eq(r.world, nil); t.eq(r.lang, nil)
end

-- просьба о данных при закрытой печати (prompt.SEAL_CLOSED, план seal-key Task 8): needs_data доходит до контроллера
-- только булевым true, как yes
function T.test_parse_needs_data()
  t.eq(llm.parse(200, resp('{"read":"x","reply":"ок","needs_data":true}'), true).needs_data, true)
  t.eq(llm.parse(200, resp('{"read":"x","reply":"ок","needs_data":"true"}'), true).needs_data, nil, "строка — нет")
  t.eq(llm.parse(200, resp('{"read":"x","reply":"ок","needs_data":false}'), true).needs_data, nil)
  t.eq(llm.parse(200, resp('{"read":"x","reply":"ок"}'), true).needs_data, nil)
end

-- пустое после обрезки — не значение (ревью a23cbf2, бэклог 1): `if result.who` не должен срабатывать на ""; lang —
-- только короткий код, не фраза
function T.test_parse_setup_fields_empty_and_long_are_nil()
  local r = llm.parse(200, resp(json.encode({ read = "x", reply = "ок", who = "", world = "   ",
    lang = "Russian language please" })), true)
  t.eq(r.who, nil, "пустая строка — nil")
  t.eq(r.world, nil, "пробелы — nil")
  t.eq(r.lang, nil, "фраза вместо кода — nil")
  r = llm.parse(200, resp(json.encode({ read = "x", reply = "ок", lang = "  " })), true)
  t.eq(r.lang, nil)
  r = llm.parse(200, resp(json.encode({ read = "x", reply = "ок", lang = "pt-BR", who = "Х" })), true)
  t.eq(r.lang, "pt-BR", "короткий код проходит")
  t.eq(r.who, "Х")
end

-- потолок попытки по длине ответа (opts.attempt_base_s + потолок токенов × opts.attempt_per_token_s, не больше
-- attempt_s): повисшее соединение короткого ответа отрезается раньше 12 с, длинный ответ ждёт прежние 12 с.
-- post «висит» до своего таймаута; ответ за cost секунд приходит, если cost ≤ таймаута
local function timed_post(costs, clock)
  return function(url, headers, body, timeout_s, p)
    local cost = costs[p.key and "gemini" or p.name]
    if cost == "hang" or cost > timeout_s then
      clock.now = clock.now + timeout_s
      return nil, "wantread"
    end
    clock.now = clock.now + cost
    return 200, ok_json("кто ты", "Ответ " .. (p.key and "gemini" or p.name) .. ".")
  end
end

local function sized_call(costs, max_tokens)
  local clock, seen = { now = 0 }, {}
  local post = timed_post(costs, clock)
  local spy = function(url, headers, body, timeout_s, p)
    seen[#seen + 1] = timeout_s
    return post(url, headers, body, timeout_s, p)
  end
  local r, err = llm.call(llm.providers({ gemini_key = "k_gem", providers = { BEAT } }), IMG_MSGS,
    { post = spy, now = function() return clock.now end, budget_s = 25, attempt_s = 12, reserve_s = 7,
      attempt_base_s = 9, attempt_per_token_s = 0.0075, max_tokens = max_tokens, want_json = true })
  return r, err, seen, clock.now
end

function T.test_hung_short_answer_cut_by_size_ceiling()
  local r, err, seen, spent = sized_call({ gemini = "hang", beatapi = 1 })
  t.eq(r and r.reply, "Ответ beatapi.", tostring(err))
  t.eq(seen[1], 10.5, "200 токенов: 9 + 200 × 0.0075")
  t.eq(spent, 11.5, "повисший Gemini отрезан на 10,5 с, а не на 12")
end

function T.test_slow_short_answer_within_size_ceiling_kept()
  -- самый медленный удачный ответ прямого Gemini в crash.log — 8,7 с (56 токенов)
  local r, err = sized_call({ gemini = 8.7, beatapi = 1 })
  t.eq(r and r.reply, "Ответ gemini.", tostring(err))
end

function T.test_long_answer_keeps_attempt_ceiling()
  local r, err, seen = sized_call({ gemini = 11.5, beatapi = 1 }, 1500)
  t.eq(seen[1], 12, "1500 токенов: 9 + 11,25 > 12 — прежний потолок попытки")
  t.eq(r and r.reply, "Ответ gemini.", "длинный ответ за 11,5 с не рвётся: " .. tostring(err))
end

-- потолок токенов провайдера (у BeatAPI 400) поднимает его потолок, как в запросе (llm.build); без attempt_base_s — как раньше
function T.test_size_ceiling_uses_provider_max_tokens_and_is_opt_in()
  local log = {}
  local post = make_post({ gemini = function() return nil, "timeout" end,
    beatapi = function() return 200, ok_json("кто ты", "Я здесь.") end }, log)
  llm.call(llm.providers({ gemini_key = "k_gem", providers = { BEAT } }), IMG_MSGS,
    { post = post, now = function() return 0 end, budget_s = 25, attempt_s = 12, reserve_s = 7, want_json = true })
  t.eq(log[1].timeout_s, 12, "без attempt_base_s — потолок попытки, как прежде")
  local GROQ = { name = "groq", url = "https://reserve.test/chat/completions", model = "m", key = "k_gq", max_tokens = 300 }
  local log2 = {}
  local post2 = make_post({ reserve = function() return nil, "timeout" end,
    beatapi = function() return 200, ok_json("кто ты", "Я здесь.") end }, log2)
  llm.call(llm.providers({ providers = { GROQ, BEAT } }), IMG_MSGS,
    { post = post2, now = function() return 0 end, budget_s = 25, attempt_s = 12, reserve_s = 7, attempt_base_s = 9,
      attempt_per_token_s = 0.0075, want_json = true })
  t.eq(log2[1].timeout_s, 11.25, "max_tokens провайдера 300: 9 + 2,25")
end

-- перегрузка модели через gemini-proxy ------------------------------------------------------------------
-- воркер rss_bot отдаёт ответ Google как есть (rss_bot cloudflare/gemini-proxy/worker.js: «any other status returns
-- as-is»); начало тела — из живого crash.log Kindle 19.11 20:04 («-> 503 in 790 ms { "error": { "code": 503, …»),
-- хвост сообщения и status — по формату google.rpc.Status
local OVERLOADED = '{\n  "error": {\n    "code": 503,\n    "message": "This model is currently experiencing high demand. '
  .. 'Spikes in demand are usually temporary. Please try again later.",\n    "status": "UNAVAILABLE"\n  }\n}\n'

-- цепочка как на устройстве: прокси -> два ключа прямого Gemini -> BeatAPI; post отвечает по провайдеру
local function overload_chain(proxy_status, proxy_body, proxy)
  local seen, logs = {}, {}
  local post = function(url, headers, body, timeout_s, p)
    seen[#seen + 1] = p.key and ("gemini#" .. p.key) or p.name
    if p.format == "gemini" then return proxy_status, proxy_body end
    if p.key then return 200, ok_json("кто ты", "Ответ Gemini.") end
    return 200, ok_json("кто ты", "Ответ BeatAPI.")
  end
  local list = llm.providers({ gemini_keys = { "k1", "k2" }, providers = { proxy or PROXY, BEAT } })
  local r, err = llm.call(list, IMG_MSGS, { post = post, now = function() return 0 end, budget_s = 25, want_json = true,
    log = function(msg) logs[#logs + 1] = msg end })
  return r, err, table.concat(seen, " "), logs
end

function T.test_proxy_overload_skips_direct_gemini_of_same_model()
  local r, err, seen, logs = overload_chain(503, OVERLOADED)
  t.eq(r and r.reply, "Ответ BeatAPI.", tostring(err))
  t.eq(seen, "gemini-proxy beatapi", "прямой Gemini той же модели не вызывается")
  t.eq(#logs, 2, "строка о пропуске на каждый ключ")
  t.eq(logs[1], "riddle: llm gemini key 1 skipped: gemini-proxy overloaded gemini-3.5-flash-lite")
  t.eq(logs[2], "riddle: llm gemini key 2 skipped: gemini-proxy overloaded gemini-3.5-flash-lite")
end

-- другие отказы прокси — прямой Gemini пробуется, как раньше: собственные ответы воркера (504 upstream timeout,
-- 502 upstream fetch error), 503 не от Google (HTML Cloudflare), 500 Google, перегрузка другой модели
function T.test_other_proxy_failures_still_try_direct_gemini()
  local cases = {
    { 504, "upstream timeout" },
    { 502, "upstream fetch error: network connection lost" },
    { 503, "<html><body>Service Unavailable</body></html>" },
    { 503, '{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}' },
    { 500, '{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}' },
    { 429, '{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}' },
  }
  for _, c in ipairs(cases) do
    local r, err, seen, logs = overload_chain(c[1], c[2])
    t.eq(r and r.reply, "Ответ Gemini.", c[1] .. " " .. c[2] .. ": " .. tostring(err))
    t.eq(seen, "gemini-proxy gemini#1", c[1] .. " " .. c[2])
    t.eq(#logs, 0, "без строки о пропуске")
  end
  local other = { name = "gemini-proxy", format = "gemini", url = "https://proxy.test", model = "gemini-other",
    proxy_auth = "PROXY-TOK" }
  local r, err, seen = overload_chain(503, OVERLOADED, other)
  t.eq(r and r.reply, "Ответ Gemini.", tostring(err))
  t.eq(seen, "gemini-proxy gemini#1", "перегружена другая модель — прямой Gemini пробуется")
end

-- перегрузка — только на этот запрос: следующий вызов снова идёт через прямой Gemini
function T.test_proxy_overload_is_per_request()
  local list = llm.providers({ gemini_keys = { "k1" }, providers = { PROXY, BEAT } })
  local n = 0
  local post = function(url, headers, body, timeout_s, p)
    n = n + 1
    if p.format == "gemini" then return n == 1 and 503 or 500, n == 1 and OVERLOADED or "x" end
    return 200, ok_json("кто ты", p.key and "Ответ Gemini." or "Ответ BeatAPI.")
  end
  local opts = { post = post, now = function() return 0 end, budget_s = 25, want_json = true }
  t.eq(llm.call(list, IMG_MSGS, opts).reply, "Ответ BeatAPI.")
  t.eq(llm.call(list, IMG_MSGS, opts).reply, "Ответ Gemini.")
end

t.run(T)
