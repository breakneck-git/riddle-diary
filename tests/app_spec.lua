-- Связка на устройстве: controller + llm + http (фейковый post и часы).
require("sqlite_shim")
local t = require("t")
local stand = require("seal_stand")
local json = require("dkjson")
local app = require("riddle.app")
local texts = require("riddle.texts")
local llm = require("riddle.llm")

local T = {}

local PNG = "/mnt/us/riddle/samples/1.png"

-- запасной провайдер боевого конфига (tools/push_config.sh): BeatAPI после Gemini
local BEAT = { name = "beatapi", url = "https://api.beatapi.io/v1/chat/completions", model = "deepseek-v4.1-flash-free",
  key = "bt-secret-CCCC3333", after_legacy = true, max_tokens = 400 }

local function resp(obj, extra)
  local body = { choices = { { message = { content = json.encode(obj) }, finish_reason = "stop" } },
                 usage = { completion_tokens = 31 } }
  for k, v in pairs(extra or {}) do body[k] = v end
  return json.encode(body)
end

-- env: posts — журнал вызовов post; script — очередь {cost | hang, status, body | err}
local function make(cfg, devmode)
  local env = { clock = 0, posts = {}, script = {}, logs = {}, removed = {} }
  cfg = cfg or { gemini_key = "km", seal = stand.key() }
  -- config.load всегда отдаёт seal: стенд без него — как файл конфига без таблицы seal (печати нет)
  if cfg.seal == nil then cfg.seal = stand.none() end
  env.deps = {
    cfg = cfg,
    memory = nil,
    http = {
      post = function(url, headers, body, timeout_s)
        env.posts[#env.posts + 1] = { url = url, headers = headers, body = body, timeout_s = timeout_s }
        local step = table.remove(env.script, 1) or { err = "no script" }
        env.clock = env.clock + (step.hang and timeout_s or step.cost or 0.1) -- hang: висит до таймаута
        if step.err then return nil, step.err, step.phase end
        return step.status or 200, step.body
      end,
    },
    clock = function() return env.clock end,
    wall = function() return 1000 end,
    log = function(msg) env.logs[#env.logs + 1] = msg end,
    read_file = function() return "PNG" end,
    remove = function(path) env.removed[#env.removed + 1] = path end,
    file_mtime = function() return nil end,
    random = function() return 1 end,
    b64 = function(s) return "B64" .. s end,
    devmode = devmode,
  }
  env.ctrl = app.new_controller(env.deps)
  return env
end

local function logged(env, needle)
  for _, l in ipairs(env.logs) do
    if l:find(needle, 1, true) then return l end
  end
end

function T.test_page_goes_through_llm_and_http_post()
  local env = make()
  env.script[1] = { body = resp({ read = "кто ты", reply = "Мои страницы молчат." }) }
  t.eq(env.ctrl:on_page(PNG), "Мои страницы молчат.")
  t.eq(#env.posts, 1)
  t.ok(env.posts[1].url:find("generativelanguage.googleapis.com", 1, true), "первый — Gemini")
  t.ok(env.posts[1].body:find("B64PNG", 1, true), "картинка ушла base64")
  t.eq(env.removed[1], PNG, "PNG удалён")
end

function T.test_budget_is_8s_and_uses_monotonic_clock()
  local env = make()
  t.eq(app.BUDGET_S, 8)
  env.script[1] = { cost = 4, err = "timeout" }
  local text = env.ctrl:on_page(PNG)
  t.ok(texts.fail_slow[1] == text, "модель не успела")
  t.eq(env.posts[1].timeout_s, 8, "единственный провайдер — весь бюджет")
  t.eq(#env.posts, 1, "Gemini один, второго захода нет")
end

function T.test_gemini_429_gives_limit_not_cloudflare()
  local env = make()
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  t.ok(texts.fail_limit[1] == env.ctrl:on_page(PNG), "лимит провайдера")
  t.eq(#env.posts, 1)
  t.ok(env.posts[1].url:find("generativelanguage.googleapis.com", 1, true))
  t.ok(logged(env, "riddle: llm failed:"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do t.ok(not l:find("cloudflare", 1, true), l) end
end

function T.test_extra_keys_only_fail_without_network()
  local env = make({ stale_key = "kc", seal = stand.key() })
  t.ok(texts.fail_other[1] == env.ctrl:on_page(PNG))
  t.eq(#env.posts, 0, "с одними лишними ключами сеть не трогаем")
end

function T.test_log_names_provider_status_time_without_secrets()
  local env = make()
  env.script[1] = { cost = 0.64, body = resp({ read = "кто ты", reply = "Нет." }) }
  env.ctrl:on_page(PNG)
  local ok_line = logged(env, "riddle: llm generativelanguage.googleapis.com gemini key 1 -> 200 in 640 ms")
  t.ok(ok_line, table.concat(env.logs, "\n"))
  t.ok(ok_line:find("finish=stop", 1, true), "finish_reason в логе")
  t.ok(ok_line:find("out_tokens=31", 1, true), "токены ответа в логе")
  t.ok(logged(env, "riddle: llm done ok in 640 ms"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    t.ok(not l:find("kg", 1, true) and not l:find("ACC", 1, true), "ни ключа, ни аккаунта: " .. l)
  end
end

-- сколько токенов входа провайдер взял из кэша: решение о кэше на устройстве; в лог — только число
function T.test_describe_logs_cached_tokens()
  local env = make()
  env.script[1] = { body = resp({ read = "кто ты", reply = "Нет." },
    { usage = { completion_tokens = 31, prompt_tokens = 16600, prompt_tokens_details = { cached_tokens = 14100 } } }) }
  env.ctrl:on_page(PNG)
  local line = logged(env, "-> 200")
  t.ok(line and line:find(" cached=14100", 1, true), tostring(line))
end

function T.test_describe_without_cache_details_logs_dash()
  local env = make()
  env.script[1] = { body = resp({ read = "кто ты", reply = "Нет." }) }
  env.ctrl:on_page(PNG)
  local line = logged(env, "-> 200")
  t.ok(line and line:find(" cached=-", 1, true), tostring(line))
end

-- clock доходит из app в контроллер: тесты контроллера ставят deps.clock руками и проводку не видят
function T.test_app_wires_clock_into_controller_build_time_log()
  local env = make({ gemini_key = "km" })
  local ticks = { 5.000, 5.012 }
  env.deps.clock = function() return table.remove(ticks, 1) or 5.012 end
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end,
    summaries = function() return {} end,
    recent = function() return {} end,
    lore_text = function() return "" end,
    lore_mtime = function() return nil end,
    add = function() end,
  }
  env.ctrl = app.new_controller(env.deps)
  env.ctrl.seal.open = true
  env.script[1] = { body = resp({ read = "кто ты", reply = "Нет." }) }
  env.ctrl:on_page(PNG)
  local line = logged(env, "riddle: prompt built in 12 ms chars=")
  t.ok(line, table.concat(env.logs, "\n"))
end

-- закрытая печать без базы (memory.open упала): ответ модели показан, в devmode — что прочитано и через кого
function T.test_closed_seal_log_names_answering_provider()
  local env = make(nil, true)
  env.script[1] = { body = resp({ read = "кто ты", reply = "Нет." }) }
  t.eq(env.ctrl:on_page(PNG), "Нет.")
  t.ok(logged(env, 'riddle: open read "кто ты"') and logged(env, "via gemini"), table.concat(env.logs, "\n"))
end

-- devmode доходит до контроллера через app.new_controller: без него текст read в лог не идёт
function T.test_seal_log_without_devmode_hides_read_text()
  local env = make()
  env.script[1] = { body = resp({ read = "кто ты", reply = "Нет." }) }
  t.eq(env.ctrl:on_page(PNG), "Нет.")
  t.ok(not logged(env, "open read"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    t.ok(not l:find("кто ты", 1, true), "текст read не в логе: " .. l)
  end
end

function T.test_no_keys_fail_without_network()
  local env = make({ seal = stand.none() })
  t.ok(texts.fail_other[1] == env.ctrl:on_page(PNG))
  t.eq(#env.posts, 0)
end

function T.test_hosts_cover_every_provider()
  local cfg = { gemini_key = "d", providers = { BEAT } }
  local hosts = {}
  for _, h in ipairs(app.hosts(cfg)) do hosts[h] = true end
  local llm = require("riddle.llm")
  for _, p in ipairs(llm.providers(cfg)) do
    t.ok(hosts[p.url:match("^https://([^/]+)")], "прогрев знает " .. p.url:match("^https://([^/]+)"))
  end
end

-- BeatAPI берёт хост из providers конфига; в хостах по умолчанию OpenRouter больше нет
function T.test_hosts_include_beatapi_and_drop_openrouter()
  local seen = {}
  for _, h in ipairs(app.hosts({ providers = { BEAT } })) do seen[h] = true end
  t.ok(seen["api.beatapi.io"], "хост BeatAPI греется")
  t.ok(seen["generativelanguage.googleapis.com"], "Gemini на месте")
  t.eq(seen["openrouter.ai"], nil, "OpenRouter убран")
  for _, h in ipairs(app.HOSTS) do t.ok(not h:find("openrouter", 1, true), "OpenRouter не греем: " .. h) end
end

-- прогрев DNS знает и хосты providers из конфига (без дублей, без битых url)
function T.test_hosts_include_config_providers()
  local cfg = { providers = {
    { name = "a", url = "https://lite.test/v1/chat/completions", model = "m" },
    { name = "b", url = "https://lite.test:8443/other", model = "m" },
    { name = "c", url = "https://generativelanguage.googleapis.com/v1/other", model = "m" },
    { name = "d", url = "http://plain.test/c", model = "m" },
  } }
  local hosts = app.hosts(cfg)
  local seen, n = {}, 0
  for _, h in ipairs(hosts) do seen[h] = (seen[h] or 0) + 1; n = n + 1 end
  t.eq(seen["lite.test"], 1, "хост провайдера, один раз")
  t.eq(seen["generativelanguage.googleapis.com"], 1, "дубль с Gemini по умолчанию не добавлен")
  t.ok(seen["generativelanguage.googleapis.com"], "хосты по умолчанию на месте")
  t.eq(seen["plain.test"], nil, "http без TLS транспорт не поддерживает — не греем")
  t.eq(n, #app.HOSTS + 1)
  t.eq(#app.hosts({}), #app.HOSTS, "без providers — только хосты по умолчанию")
end

-- свой провайдер: ключ уходит в заголовок, в лог — только хост и статус
function T.test_custom_provider_key_never_reaches_log()
  local env = make({ providers = { { name = "lite", url = "https://lite.test/v1/chat/completions",
    model = "gpt-x", key = "SECRET-CUSTOM-KEY" } }, seal = stand.key() })
  env.script[1] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(#env.posts, 1)
  t.eq(env.posts[1].url, "https://lite.test/v1/chat/completions")
  t.eq(env.posts[1].headers["Authorization"], "Bearer SECRET-CUSTOM-KEY")
  t.ok(env.posts[1].body:find("gpt-x", 1, true), "модель из конфига")
  t.ok(logged(env, "llm lite.test -> 200"), "в логе хост")
  for _, l in ipairs(env.logs) do t.ok(not l:find("SECRET-CUSTOM-KEY", 1, true), "ключ в логе: " .. l) end
end

-- свой провайдер с неверным ключом (401) не опрашивается на каждой странице: мёртв до перезапуска
function T.test_custom_provider_with_401_is_dead_for_following_calls()
  local env = make({ providers = { { name = "lite", url = "https://lite.test/v1/chat/completions",
    model = "gpt-x", key = "CUSTOM-KEY-1" } }, gemini_key = "km", seal = stand.key() })
  env.script[1] = { status = 401, body = '{"error":"invalid token"}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.ok(env.posts[1].url:find("lite.test", 1, true) and env.posts[2].url:find("generativelanguage", 1, true))
  t.ok(logged(env, "provider lite dead"), table.concat(env.logs, "\n"))
  env.script[1] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 3)
  t.ok(env.posts[3].url:find("generativelanguage", 1, true), "следующая страница — сразу Gemini")
end

-- 401 с пустым телом (прокси, обрыв) своего провайдера не хоронит
function T.test_custom_provider_not_dead_on_empty_401()
  local env = make({ providers = { { name = "lite", url = "https://lite.test/v1/chat/completions",
    model = "gpt-x", key = "CUSTOM-KEY-1" } }, gemini_key = "km", seal = stand.key() })
  env.script[1] = { status = 401, body = "" }
  env.script[2] = { status = 429, body = "{}" }
  env.ctrl:on_page(PNG)
  env.script[1] = { status = 429, body = "{}" }
  env.script[2] = { status = 429, body = "{}" }
  env.ctrl:on_page(PNG)
  t.ok(env.posts[3].url:find("lite.test", 1, true), "свой провайдер жив и пробуется снова")
  t.ok(not logged(env, "dead"), table.concat(env.logs, "\n"))
end

-- два своих провайдера на одном url с разными ключами: умирает только тот, чей ключ получил 401
function T.test_custom_providers_on_same_url_die_separately()
  local url = "https://lite.test/v1/chat/completions"
  local env = make({ providers = { { name = "a", url = url, model = "m", key = "KEY-AAAAAA" },
                                   { name = "b", url = url, model = "m", key = "KEY-BBBBBB" } },
                     gemini_key = "km", seal = stand.key() })
  env.script[1] = { status = 401, body = '{"error":"invalid token"}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.ok(logged(env, "provider a dead"), table.concat(env.logs, "\n"))
  t.ok(not logged(env, "provider b dead"))
  env.script[1] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 3)
  t.eq(env.posts[3].headers["Authorization"], "Bearer KEY-BBBBBB", "b ещё в цепочке")
end

-- 401 от прокси/портала (HTML) и прочие статусы свой провайдер не хоронят
function T.test_custom_provider_not_dead_on_portal_html_or_429()
  local env = make({ providers = { { name = "lite", url = "https://lite.test/v1/chat/completions",
    model = "gpt-x", key = "CUSTOM-KEY-1" } }, gemini_key = "km", seal = stand.key() })
  env.script[1] = { status = 401, body = "<html>Please log in</html>" }
  env.script[2] = { status = 429, body = "{}" }
  env.ctrl:on_page(PNG)
  env.script[1] = { status = 429, body = "{}" }
  env.script[2] = { status = 429, body = "{}" }
  env.ctrl:on_page(PNG)
  t.ok(env.posts[3].url:find("lite.test", 1, true), "свой провайдер жив и пробуется снова")
  t.ok(not logged(env, "dead"))
end

function T.test_gemini_429_falls_to_beatapi_through_app()
  local env = make({ gemini_key = "km", providers = { BEAT }, seal = stand.key() })
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(#env.posts, 2)
  t.ok(env.posts[1].url:find("generativelanguage.googleapis.com", 1, true))
  t.ok(env.posts[2].url:find("api.beatapi.io", 1, true), "второй — BeatAPI")
  t.eq(json.decode(env.posts[2].body).max_tokens, 400, "BeatAPI: max_tokens 400")
  t.eq(json.decode(env.posts[1].body).max_tokens, 200, "Gemini: 200")
end

-- Groq с лимитом входа (ITPM 7000): открытой печати уходит урезанный запрос — знание срезано, персона,
-- история и картинка записи на месте; Gemini получает полный
function T.test_open_page_to_provider_with_input_limit_is_fitted()
  local prompt = require("riddle.prompt")
  local GROQ = { name = "groq", url = "https://api.groq.com/openai/v1/chat/completions", model = "qwen/qwen3.8-27b",
    key = "gq-secret-DDDD4444", after_legacy = true, max_input_chars = 6000 }
  local env = make({ gemini_key = "km", providers = { GROQ } })
  local know = {}
  for i = 1, 400 do know[i] = string.format("знание-%03d о мире пишущего", i) end
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end,
    summaries = function() return {} end,
    recent = function() return { { role = "owner", text = "ЗАПИСЬ-ИСТОРИИ" }, { role = "diary", text = "ОТВЕТ-ИСТОРИИ" } } end,
    lore_text = function() return "ЛОР-МАРКЕР" end,
    lore_mtime = function() return nil end,
    add = function() end,
  }
  env.ctrl = app.new_controller(env.deps)
  env.ctrl.deps.knowledge_text = function() return table.concat(know, "\n") end
  env.ctrl.seal.open = true
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Память." }) }
  t.eq(env.ctrl:on_page(PNG), "Память.")
  t.eq(#env.posts, 2)
  local full, cut = json.decode(env.posts[1].body).messages, json.decode(env.posts[2].body).messages
  t.ok(full[1].content:find("знание-400", 1, true), "Gemini: знание целиком")
  t.ok(prompt.chars(full) > 6000, "без лимита запрос больше")
  t.ok(prompt.chars(cut) <= 6000, "Groq: в лимите, " .. prompt.chars(cut))
  t.ok(not cut[1].content:find("знание-400", 1, true), "Groq: знание урезано")
  t.ok(cut[1].content:find("Ты — дневник Тома Реддла", 1, true), "персона")
  t.ok(cut[1].content:find("ЛОР-МАРКЕР", 1, true), "лор в лимит влез")
  t.eq(#cut, #full, "история целиком")
  t.eq(cut[2].content, "ЗАПИСЬ-ИСТОРИИ")
  t.eq(cut[#cut].content[2].image_url.url, "data:image/png;base64,B64PNG", "картинка записи")
  t.ok(logged(env, "riddle: llm groq fit chars="), table.concat(env.logs, "\n"))
end

-- лимит меньше несрезаемого (персона, правила, запись): запрос уходит урезанным до предела, в логе флаг — только числа
function T.test_limited_provider_over_limit_logs_fit_over()
  local GROQ = { name = "groq", url = "https://api.groq.com/openai/v1/chat/completions", model = "qwen/qwen3.8-27b",
    key = "gq-secret-DDDD4444", after_legacy = true, max_input_chars = 1000 }
  local env = make({ gemini_key = "km", providers = { GROQ } })
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end,
    summaries = function() return { "ПЕРЕСКАЗ-МАРКЕР" } end,
    recent = function() return { { role = "owner", text = "ЗАПИСЬ-ИСТОРИИ" } } end,
    lore_text = function() return "ЛОР-МАРКЕР" end,
    lore_mtime = function() return nil end,
    add = function() end,
  }
  env.ctrl = app.new_controller(env.deps)
  env.ctrl.seal.open = true
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Память." }) }
  t.eq(env.ctrl:on_page(PNG), "Память.")
  local cut = json.decode(env.posts[2].body).messages
  t.ok(not cut[1].content:find("ПЕРЕСКАЗ-МАРКЕР", 1, true), "пересказ срезан")
  t.eq(cut[2].content, "ЗАПИСЬ-ИСТОРИИ", "история цела")
  local line
  for _, l in ipairs(env.logs) do if l:find("fit over", 1, true) then line = l end end
  t.ok(line, table.concat(env.logs, "\n"))
  t.ok(line and line:find("^riddle: llm groq fit over chars=%d+ limit=1000$"), "только числа: " .. tostring(line))
end

-- маленький Notion (по названию) и Groq с лимитом: урезанный запрос теряет самые старые документы, не хвост по названию.
-- Лимит — чуть выше несрезаемой части запроса «Методов»; у неё с картой (срез 3) блок prompt.MAP_FORMAT, ~400 знаков
function T.test_open_page_to_limited_provider_keeps_newest_knowledge()
  local GROQ = { name = "groq", url = "https://api.groq.com/openai/v1/chat/completions", model = "qwen/qwen3.8-27b",
    key = "gq-secret-DDDD4444", after_legacy = true, max_input_chars = 6400 }
  local env = make({ gemini_key = "km", providers = { GROQ } })
  local docs = {}
  for i = 1, 400 do -- 400 — самый свежий
    docs[i] = { text = string.format("знание-%03d о мире пишущего", i), edited = string.format("2026-%04d", i) }
  end
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end, summaries = function() return {} end,
    recent = function() return {} end, lore_text = function() return "ЛОР-МАРКЕР" end,
    lore_mtime = function() return nil end, add = function() end,
  }
  env.ctrl = app.new_controller(env.deps)
  env.ctrl.deps.knowledge_text = function()
    return { { title = "БАЗА", total = 400, docs = docs } }, "small"
  end
  env.ctrl.seal.open = true
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Память." }) }
  t.eq(env.ctrl:on_page(PNG), "Память.")
  local full, cut = json.decode(env.posts[1].body).messages, json.decode(env.posts[2].body).messages
  t.ok(full[1].content:find("знание-001 о мире", 1, true) and full[1].content:find("знание-400", 1, true), "Gemini: всё, по названию")
  t.ok(full[1].content:find("знание-001", 1, true) < full[1].content:find("знание-400", 1, true), "Gemini: порядок по названию")
  t.ok(cut[1].content:find("знание-400", 1, true), "Groq: самый свежий документ")
  t.ok(not cut[1].content:find("знание-001 ", 1, true), "Groq: самый старый срезан")
end

-- пересказ прошлой сессии уходит с потолком SUMMARY_MAX_TOKENS, ответ на страницу — с потолком провайдера
function T.test_summary_request_has_its_own_max_tokens()
  local controller = require("riddle.controller")
  local env = make({ gemini_key = "km", providers = { BEAT } })
  local saved = {}
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 2, 1 end,
    entries = function() return { { role = "owner", text = "запись" }, { role = "diary", text = "ответ" } } end,
    set_summary = function(_, sid, text) saved[#saved + 1] = { sid = sid, text = text } end,
  }
  env.ctrl = app.new_controller(env.deps)
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  env.script[2] = { body = json.encode({ choices = { { message = { content = "Мне писали о прошлом." },
    finish_reason = "stop" } } }) }
  env.ctrl:on_unlocked_followup()
  t.eq(#env.posts, 2)
  t.eq(json.decode(env.posts[1].body).max_tokens, controller.SUMMARY_MAX_TOKENS, "Gemini: потолок пересказа")
  t.eq(json.decode(env.posts[2].body).max_tokens, controller.SUMMARY_MAX_TOKENS, "BeatAPI: потолок пересказа")
  t.eq(saved[1] and saved[1].text, "Мне писали о прошлом.")
end

-- тот же потолок у пересказа через дочерний процесс: begin_followup -> job.run() -> finish_followup
function T.test_summary_in_child_has_its_own_max_tokens()
  local controller = require("riddle.controller")
  local env = make({ gemini_key = "km", providers = { BEAT } })
  local saved = {}
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 2, 1 end,
    entries = function() return { { role = "owner", text = "запись" }, { role = "diary", text = "ответ" } } end,
    set_summary = function(_, sid, text) saved[#saved + 1] = { sid = sid, text = text } end,
  }
  env.ctrl = app.new_controller(env.deps)
  local job = env.ctrl:begin_followup()
  t.eq(#env.posts, 0, "в родителе запроса нет")
  env.script[1] = { body = json.encode({ choices = { { message = { content = "Мне писали о прошлом." },
    finish_reason = "stop" } } }) }
  local payload = job.run()
  t.eq(json.decode(env.posts[1].body).max_tokens, controller.SUMMARY_MAX_TOKENS, "потолок пересказа")
  env.ctrl:finish_followup(job, payload)
  t.eq(saved[1] and saved[1].text, "Мне писали о прошлом.")
end

-- Gemini съел свои 4 с — BeatAPI получает весь остаток бюджета (≥ 3.5 с)
function T.test_gemini_timeout_leaves_beatapi_real_timeout()
  local env = make({ gemini_key = "km", providers = { BEAT }, seal = stand.key() })
  env.script[1] = { cost = 4, err = "timeout" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(#env.posts, 2)
  t.ok(env.posts[2].timeout_s >= 3.5, "BeatAPI: таймаут ≥ 3.5 с, а было " .. tostring(env.posts[2].timeout_s))
end

-- ключ, ответивший 401/403 с «API key» в теле, мёртв до перезапуска: в следующие вызовы не попадает
local function auth_of(env, i) return env.posts[i].headers["Authorization"] end

function T.test_key_with_401_is_dead_for_following_calls()
  local env = make({ gemini_keys = { "kA", "kB" }, seal = stand.key() })
  env.script[1] = { status = 401, body = '{"error":{"message":"API key not valid."}}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(auth_of(env, 1), "Bearer kA"); t.eq(auth_of(env, 2), "Bearer kB")
  -- второй вызов стартует с kB (ротация); kB отказал по 429 — kA мёртв, пробовать его нельзя
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 3, "после 429 на kB мёртвый kA не пробуем")
  t.eq(auth_of(env, 3), "Bearer kB")
  t.ok(logged(env, "gemini key 1 dead"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    t.ok(not l:find("kA", 1, true) and not l:find("kB", 1, true), "значение ключа не в логе: " .. l)
  end
end

function T.test_403_also_marks_key_dead()
  local env = make({ gemini_keys = { "kA", "kB" }, seal = stand.key() })
  env.script[1] = { status = 403, body = '{"error":{"message":"API key not valid."}}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  env.script[1] = { status = 429, body = '{}' }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 3)
  t.ok(logged(env, "gemini key 1 dead"))
end

function T.test_429_does_not_mark_key_dead()
  local env = make({ gemini_keys = { "kA", "kB" }, seal = stand.key() })
  env.script[1] = { status = 429, body = '{}' }
  env.script[2] = { status = 429, body = '{}' }
  env.ctrl:on_page(PNG)
  env.script[1] = { status = 429, body = '{}' }
  env.script[2] = { status = 429, body = '{}' }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 4, "оба ключа живы и пробуются снова")
  t.ok(not logged(env, "dead"))
end

-- 403 captive-портала или прокси (без «API key» в теле) ключ не хоронит
function T.test_403_from_portal_body_keeps_key_alive()
  local env = make({ gemini_keys = { "kA", "kB" }, seal = stand.key() })
  env.script[1] = { status = 403, body = "<html>Please log in to the Wi-Fi</html>" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(auth_of(env, 2), "Bearer kB", "после 403 портала — следующий ключ")
  -- второй вызов стартует с kB; он отказал — kA должен быть жив и пробоваться
  env.script[1] = { status = 429, body = '{}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 4, "kA жив")
  t.eq(auth_of(env, 4), "Bearer kA")
  t.ok(not logged(env, "dead"), table.concat(env.logs, "\n"))
end

function T.test_401_without_api_key_in_body_keeps_key_alive()
  local env = make({ gemini_key = "kA", seal = stand.key() })
  env.script[1] = { status = 401, body = "proxy auth required" }
  env.ctrl:on_page(PNG)
  env.script[1] = { status = 429, body = '{}' }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 2, "ключ жив и пробуется снова")
  t.ok(not logged(env, "dead"))
end

function T.test_403_from_beatapi_marks_nothing()
  local env = make({ gemini_key = "kA", providers = { BEAT }, seal = stand.key() })
  env.script[1] = { status = 429, body = '{}' }
  env.script[2] = { status = 403, body = '{"error":"API key not valid"}' }
  env.ctrl:on_page(PNG)
  env.script[1] = { status = 429, body = '{}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(#env.posts, 4, "Gemini и BeatAPI пробуются снова")
  t.ok(not logged(env, "dead"), table.concat(env.logs, "\n"))
end

-- итоговая строка «llm done» несёт текст ошибки провайдера — тоже через mask
function T.test_llm_done_line_masks_secrets()
  local env = make()
  env.script[1] = { err = "connect failed https://x/?key=AIzaSyLEAK" }
  env.ctrl:on_page(PNG)
  local line = logged(env, "riddle: llm done fail")
  t.ok(line, table.concat(env.logs, "\n"))
  t.ok(not line:find("LEAK", 1, true) and line:find("***", 1, true), line)
end

function T.test_all_keys_dead_behaves_like_no_keys()
  local env = make({ gemini_key = "kA", seal = stand.key() })
  env.script[1] = { status = 401, body = '{"error":{"status":"API_KEY_INVALID"}}' }
  t.ok(texts.fail_other[1] == env.ctrl:on_page(PNG))
  t.eq(#env.posts, 1)
  local second, is_other = env.ctrl:on_page(PNG), false
  for _, v in ipairs(texts.fail_other) do if v == second then is_other = true end end
  t.ok(is_other, "прочий сбой")
  t.eq(#env.posts, 1, "мёртвый единственный ключ — сеть не трогаем")
end

function T.test_dead_gemini_keys_leave_beatapi()
  local env = make({ gemini_key = "kA", providers = { BEAT }, seal = stand.key() })
  env.script[1] = { status = 401, body = '{"error":{"status":"API_KEY_INVALID"}}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  env.script[1] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(#env.posts, 3)
  t.ok(env.posts[3].url:find("api.beatapi.io", 1, true), "Gemini мёртв — сразу BeatAPI")
end

-- тело ошибки провайдера идёт в лог до 160 символов: всё, похожее на секрет, маскируется
function T.test_error_body_secrets_are_masked_in_log()
  local env = make()
  env.script[1] = { status = 400, body = '{"error":"bad Bearer abc123.def at ?key=AIzaSyD-leak_1&x=1 sk-proj_Zz9 AIzaSyOther"}' }
  env.ctrl:on_page(PNG)
  local line = logged(env, "riddle: llm generativelanguage.googleapis.com gemini key 1 -> 400")
  t.ok(line, table.concat(env.logs, "\n"))
  for _, secret in ipairs({ "abc123", "AIza", "sk-proj", "leak_1" }) do
    t.ok(not line:find(secret, 1, true), secret .. " не в логе: " .. line)
  end
  t.ok(line:find("***", 1, true), "на месте секретов ***: " .. line)
  t.ok(line:find("x=1", 1, true), "остальное тело на месте: " .. line)
end

function T.test_secret_cut_by_160_limit_is_masked_before_truncation()
  local env = make()
  env.script[1] = { status = 400, body = string.rep("x", 150) .. " AIzaSyABCDEFGHIJKLMNOP" }
  env.ctrl:on_page(PNG)
  local line = logged(env, "-> 400")
  t.ok(line and not line:find("AIza", 1, true), "обрезанный префикс ключа не в логе: " .. tostring(line))
end

-- ключ из конфига, разрезанный границей 160: шаблоны (AIza…, sk-…) обрезанный кусок поймали бы и сами,
-- а дословная маскировка — нет; маскировать надо до обрезки
function T.test_config_key_cut_by_160_limit_is_masked_before_truncation()
  local env = make({ gemini_key = "km", seal = stand.key(),
                     providers = { { name = "mine", url = "https://llm.example.org/v1/chat/completions",
                                     model = "m", key = "mistral_ZZZZ9999_LONGKEY" } } })
  env.script[1] = { status = 400, body = string.rep("x", 150) .. " mistral_ZZZZ9999_LONGKEY" }
  env.ctrl:on_page(PNG)
  local line = logged(env, "-> 400")
  t.ok(line, table.concat(env.logs, "\n"))
  t.ok(not line:find("mistral", 1, true), "обрезанный кусок ключа не в логе: " .. line)
end

-- тело ошибки в строке лога — одной строкой (str.one_line): переводы строк и неразрывные пробелы — один пробел
function T.test_error_body_in_log_is_one_line()
  local env = make()
  env.script[1] = { status = 500, body = "upstream\n\n  failed\194\160\194\160badly\n" }
  env.ctrl:on_page(PNG)
  local line = logged(env, "-> 500")
  t.ok(line and line:find("upstream failed badly", 1, true), table.concat(env.logs, "\n"))
end

-- метка суточной/минутной квоты в строке лога 429: ищется по всему телу, а не по первым 160 знакам
local function quota_body(quota_id)
  return '{"error":{"code":429,"message":"' .. string.rep("You exceeded your current quota. ", 8)
    .. '","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure",'
    .. '"violations":[{"quotaId":"' .. quota_id .. '"}]}]}}'
end

function T.test_429_daily_quota_gets_label_in_log_beyond_160_chars()
  local env = make()
  env.script[1] = { status = 429, body = quota_body("GenerateRequestsPerDayPerProjectPerModel-FreeTier") }
  env.ctrl:on_page(PNG)
  local line = logged(env, "-> 429")
  t.ok(line and line:find(" quota=day", 1, true), tostring(line))
  t.ok(not line:find("PerDay", 1, true), "тело обрезано до 160: " .. tostring(line))
end

function T.test_429_minute_quota_gets_label_in_log()
  local env = make()
  env.script[1] = { status = 429, body = quota_body("GenerateRequestsPerMinutePerProjectPerModel-FreeTier") }
  env.ctrl:on_page(PNG)
  local line = logged(env, "-> 429")
  t.ok(line and line:find(" quota=minute", 1, true), tostring(line))
end

function T.test_429_with_both_quotas_is_day_and_other_statuses_have_no_label()
  local env = make({ gemini_key = "km", gemini_keys = { "kn" }, seal = stand.key(), providers = { BEAT } })
  env.script[1] = { status = 429, body = quota_body("GenerateRequestsPerMinutePerProjectPerModel-FreeTier PerDay") }
  env.script[2] = { status = 429, body = '{"error":"rate"}' }
  env.script[3] = { status = 503, body = quota_body("GenerateRequestsPerDayPerProjectPerModel-FreeTier") }
  env.ctrl:on_page(PNG)
  local day, plain, srv = nil, nil, nil
  for _, l in ipairs(env.logs) do
    if l:find("-> 429", 1, true) and l:find("quota=day", 1, true) then day = l end
    if l:find("-> 429", 1, true) and l:find("rate", 1, true) then plain = l end
    if l:find("-> 503", 1, true) then srv = l end
  end
  t.ok(day, "минута+сутки — day: " .. table.concat(env.logs, "\n"))
  t.ok(plain and not plain:find("quota=", 1, true), "429 без квоты — без метки: " .. tostring(plain))
  t.ok(srv and not srv:find("quota=", 1, true), "503 — без метки: " .. tostring(srv))
end

function T.test_transport_error_text_is_masked_in_log()
  local env = make()
  env.script[1] = { err = "connect failed https://x/?key=AIzaSyLEAK" }
  env.ctrl:on_page(PNG)
  local line = logged(env, "riddle: llm generativelanguage.googleapis.com")
  t.ok(line and not line:find("LEAK", 1, true), tostring(line))
end

-- ключ из конфига (формат любого провайдера, шаблонам mask не известен) маскируется дословно
function T.test_config_key_values_are_masked_verbatim_in_log()
  local env = make({ gemini_key = "gk-secret-AAAA1111", gemini_keys = { "gk-secret-BBBB2222" },
                     providers = { { name = "mine", url = "https://llm.example.org/v1/chat/completions",
                                     model = "m", key = "mistral_ZZZZ9999" }, BEAT },
                     seal = stand.key() })
  env.script[1] = { status = 400, body = '{"error":"bad token mistral_ZZZZ9999 gk-secret-AAAA1111"}' }
  env.script[2] = { err = "connect failed https://x/?t=gk-secret-BBBB2222" }
  env.script[3] = { err = "bt-secret-CCCC3333 refused" }
  env.ctrl:on_page(PNG)
  t.ok(#env.logs > 0, "лог не пуст")
  for _, l in ipairs(env.logs) do
    for _, secret in ipairs({ "mistral_ZZZZ9999", "gk-secret-AAAA1111", "gk-secret-BBBB2222", "bt-secret-CCCC3333" }) do
      t.ok(not l:find(secret, 1, true), secret .. " не в логе: " .. l)
    end
  end
  t.ok(logged(env, "-> 400"):find("***", 1, true), "на месте ключа ***")
end

-- ключ в конфиге с пробелами по краям уходит провайдеру обрезанным, и сервер эхом вернёт его без пробелов:
-- маскируется обрезанное значение, иначе секрет в логе открытым текстом
function T.test_padded_config_key_is_masked_trimmed_in_log()
  local env = make({ gemini_key = "  gk-secret-AAAA1111\n", notion_token = "\tntn_NOTION4242secret ",
                     seal = stand.key() })
  env.script[1] = { status = 400, body = '{"error":"echo gk-secret-AAAA1111 ntn_NOTION4242secret"}' }
  env.ctrl:on_page(PNG)
  t.ok(#env.logs > 0, "лог не пуст")
  for _, l in ipairs(env.logs) do
    t.ok(not l:find("gk-secret-AAAA1111", 1, true), "ключ не в логе: " .. l)
    t.ok(not l:find("NOTION4242", 1, true), "токен Notion не в логе: " .. l)
  end
  t.ok(logged(env, "-> 400"):find("***", 1, true), "на месте ключа ***")
end

-- токен Notion (формат ntn_…, шаблонам mask не известен) тоже секрет конфига
function T.test_notion_token_masked_in_logs()
  local env = make({ gemini_key = "km", notion_token = "ntn_NOTION4242secret", seal = stand.key() })
  env.script[1] = { status = 400, body = '{"error":"echo ntn_NOTION4242secret"}' }
  env.ctrl:on_page(PNG)
  t.ok(#env.logs > 0, "лог не пуст")
  for _, l in ipairs(env.logs) do
    t.ok(not l:find("NOTION4242", 1, true), "токен Notion не в логе: " .. l)
  end
  t.ok(logged(env, "-> 400"):find("***", 1, true), "на месте токена ***")
end

function T.test_hosts_do_not_warm_cloudflare()
  for _, h in ipairs(app.HOSTS) do t.ok(not h:find("cloudflare", 1, true), "Cloudflare не греем: " .. h) end
end

function T.test_hosts_do_not_warm_groq()
  for _, h in ipairs(app.HOSTS) do t.ok(not h:find("groq", 1, true), "Groq не греем: " .. h) end
end

-- ключ BeatAPI (формат шаблонам mask не известен) не доходит до лога ни в теле ответа, ни в тексте ошибки
function T.test_beatapi_key_masked_in_logs()
  local env = make({ gemini_key = "km", providers = { BEAT }, seal = stand.key() })
  env.script[1] = { status = 429, body = '{}' }
  env.script[2] = { status = 400, body = '{"error":"bad key bt-secret-CCCC3333"}' }
  env.ctrl:on_page(PNG)
  env.script[1] = { status = 429, body = '{}' }
  env.script[2] = { err = "refused bt-secret-CCCC3333" }
  env.ctrl:on_page(PNG)
  t.ok(#env.logs > 0, "лог не пуст")
  for _, l in ipairs(env.logs) do t.ok(not l:find("CCCC3333", 1, true), "ключ BeatAPI не в логе: " .. l) end
  t.ok(logged(env, "-> 400"):find("***", 1, true), "на месте ключа ***")
end

-- старый конфиг с openrouter_key (прямо в cfg): ключ игнорируется — ни запроса к OpenRouter, ни в хостах
function T.test_stale_openrouter_key_is_ignored()
  local env = make({ gemini_key = "km", openrouter_key = "or-stale-KEY9999", seal = stand.key() })
  env.script[1] = { status = 429, body = '{}' }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 1, "после Gemini запасного нет")
  for _, h in ipairs(app.hosts({ gemini_key = "km", openrouter_key = "or-stale-KEY9999" })) do
    t.ok(not h:find("openrouter", 1, true), h)
  end
end

function T.test_b64_matches_reference()
  t.eq(app.b64(""), "")
  t.eq(app.b64("f"), "Zg==")
  t.eq(app.b64("fo"), "Zm8=")
  t.eq(app.b64("foo"), "Zm9v")
  t.eq(app.b64("\0\255\128 PNG"), "AP+AIFBORw==")
end

-- when_idle: блокирующая работа (прогрев DNS) — только когда перо поднято ----------

local function scheduler()
  local s = { queue = {} }
  function s.schedule(delay, fn) s.queue[#s.queue + 1] = { delay = delay, fn = fn } end
  function s.tick()
    local item = table.remove(s.queue, 1)
    if item then item.fn() end
    return item
  end
  return s
end

function T.test_when_idle_runs_at_once_when_pen_is_up()
  local s, ran = scheduler(), 0
  app.when_idle(function() return false end, s.schedule, function() ran = ran + 1 end, 1)
  t.eq(ran, 1)
  t.eq(#s.queue, 0)
end

function T.test_when_idle_waits_for_pen_up()
  local s, ran, busy = scheduler(), 0, true
  app.when_idle(function() return busy end, s.schedule, function() ran = ran + 1 end, 1)
  t.eq(ran, 0, "под пером не блокируем")
  t.eq(s.queue[1].delay, 1)
  s.tick()
  t.eq(ran, 0, "перо всё ещё опущено")
  busy = false
  s.tick()
  t.eq(ran, 1, "перо поднято — выполнили")
  t.eq(#s.queue, 0, "и больше не перепланируем")
end

-- несколько ключей Gemini: стартовый ключ сдвигается от вызова к вызову, 429 -> следующий ключ
local MULTI = { gemini_key = "kA", gemini_keys = { "kB", "kC" }, seal = stand.key() }

function T.test_start_key_rotates_between_calls()
  local env = make(MULTI)
  for i = 1, 4 do env.script[i] = { body = resp({ read = "кто ты", reply = "Мои страницы молчат." }) } end
  for _ = 1, 4 do env.ctrl:on_page(PNG) end
  local got = {}
  for _, p in ipairs(env.posts) do got[#got + 1] = (p.headers["Authorization"]:gsub("^Bearer ", "")) end
  t.eq(table.concat(got, " "), "kA kB kC kA")
end

function T.test_429_moves_to_next_key_and_log_has_number_not_value()
  local env = make(MULTI)
  env.script[1] = { status = 429, body = '{"error":"rate"}', cost = 0.2 }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Мои страницы молчат." }) }
  t.eq(env.ctrl:on_page(PNG), "Мои страницы молчат.")
  t.eq(#env.posts, 2)
  t.ok(logged(env, "gemini key 1 -> 429"), table.concat(env.logs, "\n"))
  t.ok(logged(env, "gemini key 2 -> 200"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do
    for _, k in ipairs({ "kA", "kB", "kC" }) do t.ok(not l:find(k, 1, true), "ключ в логе: " .. l) end
  end
end

-- цепочка через дочерний процесс: remote_fn в родителе, fn() «в дочернем», payload по pipe (JSON),
-- absorb в родителе ------------------------------------------------------------------------------
local prompt = require("riddle.prompt")
local function via_pipe(payload) return json.decode(json.encode(payload)) end
local KEYS2 = { gemini_keys = { "kA", "kB" }, seal = stand.key() }

function T.test_remote_payload_carries_logs_and_dead_keys()
  local env = make(KEYS2)
  local chain = app.chain(env.deps)
  env.script[1] = { status = 401, body = '{"error":{"message":"API key not valid."}}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  local fn = chain:remote_fn(prompt.open("B64", { seal = "closed" }), true)
  t.eq(#env.posts, 0, "remote_fn в родителе сети не трогает")
  local payload = via_pipe(fn())
  t.eq(payload.result.reply, "Я — страницы.")
  t.eq(payload.err, nil)
  local dead1 = false
  for _, k in ipairs(payload.dead) do if k == 1 then dead1 = true end end
  t.ok(dead1, "в payload.dead ключ 1")
  local logs = table.concat(payload.logs, "\n")
  t.ok(logs:find("gemini key 1 dead", 1, true), logs)
  t.ok(logs:find("riddle: llm done ok", 1, true), logs)
  t.eq(#env.logs, 0, "в дочернем d.log не зовётся")
  t.ok(not logs:find("kA", 1, true) and not logs:find("kB", 1, true), "значения ключей не в логе")
end

function T.test_absorb_marks_dead_and_next_call_skips_key()
  local env = make(KEYS2)
  local chain = app.chain(env.deps)
  env.script[1] = { status = 401, body = '{"error":{"message":"API key not valid."}}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  local payload = via_pipe(chain:remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  local result, err = chain:absorb(payload)
  t.eq(result.reply, "Я — страницы.")
  t.eq(err, nil)
  t.ok(logged(env, "gemini key 1 dead"), table.concat(env.logs, "\n"))
  t.ok(logged(env, "gemini key 1 -> 401"), "строки дочернего — в лог родителя")
  -- второй вызов стартует с kB (ротация в родителе); kB отказал по 429 — мёртвый kA не пробуем
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  chain:call(prompt.open("B64", { seal = "closed" }), true)
  t.eq(#env.posts, 3, "после 429 на kB мёртвый kA не пробуем")
  t.eq(auth_of(env, 3), "Bearer kB")
end

-- gemini-proxy ответил перегрузкой модели (503 Google) — прямой Gemini той же модели не вызывается, в логе ответа —
-- строка о пропуске; запрос сразу у следующего провайдера
function T.test_remote_fn_proxy_overload_skips_direct_gemini_and_logs()
  local env = make({ gemini_keys = { "kA" }, seal = stand.key(), providers = {
    { name = "gemini-proxy", format = "gemini", url = "https://proxy.test", model = "gemini-3.5-flash-lite",
      proxy_auth = "tok" },
    { name = "groq", url = "https://api.groq.test/v1/chat/completions", model = "m", key = "kg", after_legacy = true },
  } })
  local chain = app.chain(env.deps)
  env.script[1] = { status = 503, body = '{"error":{"code":503,"message":"This model is currently experiencing high '
    .. 'demand.","status":"UNAVAILABLE"}}' }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  local payload = via_pipe(chain:remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  t.eq(payload.result and payload.result.reply, "Я — страницы.", tostring(payload.err))
  t.eq(#env.posts, 2)
  t.ok(env.posts[2].url:find("groq", 1, true), "второй запрос — Groq, не прямой Gemini: " .. env.posts[2].url)
  local logs = table.concat(payload.logs, "\n")
  t.ok(logs:find("riddle: llm gemini key 1 skipped: gemini-proxy overloaded gemini-3.5-flash-lite", 1, true), logs)
end

-- транспортный сбой: в строке лога — фаза обрыва из http.post (wantread luasec — и рукопожатие, и ожидание ответа)
function T.test_chain_logs_transport_failure_phase()
  local env = make(KEYS2)
  local chain = app.chain(env.deps)
  env.script[1] = { err = "wantread", phase = "wait", hang = true }
  env.script[2] = { err = "timeout" }
  chain:call(prompt.open("B64", { seal = "closed" }), true)
  t.ok(logged(env, "gemini key 1 -> wantread (wait) in "), table.concat(env.logs, "\n"))
end

-- remote_fn доносит reply_optional до llm.call (чтение страницы на карте, Controller:map_read_job): пустой reply
-- при прочитанном — ответ первого ключа, второй не опрашивается
function T.test_remote_fn_passes_reply_optional()
  local env = make(KEYS2)
  local chain = app.chain(env.deps)
  env.script[1] = { body = resp({ read = "шалость удалась", map = "close" }) }
  env.script[2] = { body = resp({ read = "шалость удалась", reply = "x" }) }
  local payload = via_pipe(chain:remote_fn(prompt.open("B64", { seal = "closed" }), true, { reply_optional = true })())
  t.eq(#env.posts, 1, "второй ключ не опрашивался")
  t.eq(payload.result.map, "close")
  t.eq(payload.result.reply, "")
end

function T.test_remote_fn_rotates_start_key_in_parent()
  local env = make(MULTI)
  local chain = app.chain(env.deps)
  local fns = {}
  for i = 1, 3 do
    env.script[i] = { body = resp({ read = "кто ты", reply = "Мои страницы молчат." }) }
    fns[i] = chain:remote_fn(prompt.open("B64", { seal = "closed" }), true) -- все созданы в родителе до запуска
  end
  for i = 1, 3 do fns[i]() end
  local got = {}
  for _, p in ipairs(env.posts) do got[#got + 1] = (p.headers["Authorization"]:gsub("^Bearer ", "")) end
  t.eq(table.concat(got, " "), "kA kB kC")
end

-- то же на настоящем fork: счётчик ротации, сдвинутый в дочернем, родитель бы не увидел
function T.test_remote_fn_rotates_start_key_across_real_fork()
  local shim = require("subprocess_shim")
  local worker = require("riddle.worker")
  local env = make(MULTI)
  for i = 1, 3 do env.script[i] = { body = resp({ read = "кто ты", reply = "Мои страницы молчат." }) } end
  local chain = app.chain(env.deps)
  local loop = shim.loop()
  local runner = worker.new{ sys = shim.sys(), schedule = loop.schedule, clock = shim.clock }
  local keys = {}
  for _ = 1, 3 do
    local payload
    runner:start("answer", chain:remote_fn(prompt.open("B64", { seal = "closed" }), true),
      { timeout_s = 5, on_done = function(p) payload = p end })
    loop.run(0.5)
    t.ok(payload, "ответ дочернего пришёл")
    for _, l in ipairs(payload.logs) do
      local k = l:match("gemini key (%d+) %->")
      if k then keys[#keys + 1] = k end
    end
  end
  t.eq(table.concat(keys, " "), "1 2 3")
end

function T.test_remote_err_is_masked()
  local env = make({ gemini_key = "SECRETKEY123", seal = stand.key() })
  local chain = app.chain(env.deps)
  env.script[1] = { err = "connect failed SECRETKEY123" }
  local payload = via_pipe(chain:remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  t.eq(payload.result, nil)
  t.ok(payload.err and payload.err:find("***", 1, true), tostring(payload.err))
  t.ok(not payload.err:find("SECRETKEY123", 1, true), payload.err)
  for _, l in ipairs(payload.logs) do t.ok(not l:find("SECRETKEY123", 1, true), "ключ в логе: " .. l) end
  local _, err = chain:absorb(payload)
  t.ok(not err:find("SECRETKEY123", 1, true))
end

function T.test_controller_gets_remote_fn_and_absorb()
  local env = make()
  env.script[1] = { body = resp({ read = "кто ты", reply = "Мои страницы молчат." }) }
  local job = env.ctrl:begin(PNG)
  t.eq(#env.posts, 0)
  t.eq(env.ctrl:finish(job, via_pipe(job.run())), "Мои страницы молчат.")
  t.eq(#env.posts, 1)
  t.ok(logged(env, "riddle: llm done ok"), "лог дочернего дошёл до родителя")
end

-- путь ответа (дочерний процесс, потолок 30 с): бюджет цепочки 25 с, попытка провайдера до 12 с
-- (на проде Gemini дважды не уложился в 4 с); синхронные вызовы — прежние 8 с и 4 с
function T.test_remote_answer_budget_25s()
  local env = make()
  t.eq(app.ANSWER_BUDGET_S, 25)
  env.script[1] = { cost = 20, err = "timeout" }
  local payload = via_pipe(app.chain(env.deps):remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  t.eq(#env.posts, 1)
  t.eq(env.posts[1].timeout_s, 25, "единственный провайдер — весь бюджет ответа")
  t.eq(payload.result, nil)
end

-- потолок попытки на пути ответа — по длине ответа: ANSWER_ATTEMPT_BASE_S + потолок токенов × ANSWER_ATTEMPT_PER_TOKEN_S,
-- не больше ANSWER_ATTEMPT_S. Ответ дневника (200 токенов) — 10,5 с; пересказ (1500) — прежние 12 с
function T.test_remote_answer_attempt_ceiling_by_answer_size()
  local env = make({ gemini_key = "km", providers = { BEAT }, seal = stand.key() })
  t.eq(app.ANSWER_ATTEMPT_S, 12)
  local chain = app.chain(env.deps)
  env.script[1] = { hang = true, err = "wantread", phase = "wait" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  local payload = via_pipe(chain:remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  t.eq(payload.result.reply, "Я — страницы.")
  t.eq(env.posts[1].timeout_s, 10.5, "Gemini на пути ответа (200 токенов) ждёт до 10,5 с")
  t.eq(env.posts[2].timeout_s, 14.5, "BeatAPI — остаток бюджета 25 с")
  env.script[1] = { hang = true, err = "wantread" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  via_pipe(chain:remote_fn(prompt.open("B64", { seal = "closed" }), false, { max_tokens = 1500 })())
  t.eq(env.posts[3].timeout_s, 12, "пересказ (1500 токенов) — прежний потолок 12 с")
  -- синхронный вызов той же цепочки — прежние 4 с на попытку
  env.script[1] = { cost = 4, err = "timeout" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  chain:call(prompt.open("B64", { seal = "closed" }), true)
  t.eq(env.posts[5].timeout_s, 4, "синхронный путь — 4 с")
  t.ok(math.abs(env.posts[6].timeout_s - 4) < 0.01, "синхронный путь — остаток бюджета 8 с: " .. env.posts[6].timeout_s)
end

-- Gemini и Groq висят до потолка попытки: BeatAPI на пути ответа получает резерв, а не 25 − 12 − 12 = 1 с
function T.test_remote_answer_reserve_for_last_provider()
  local GROQ = { name = "groq", url = "https://api.groq.com/openai/v1/chat/completions", model = "m",
    key = "gq-secret", after_legacy = true }
  local env = make({ gemini_key = "km", providers = { GROQ, BEAT }, seal = stand.key() })
  t.ok(app.ANSWER_RESERVE_S >= 6 and app.ANSWER_RESERVE_S <= 8, "резерв 6–8 с: " .. tostring(app.ANSWER_RESERVE_S))
  local chain = app.chain(env.deps)
  env.script[1] = { hang = true, err = "timeout" }
  env.script[2] = { hang = true, err = "timeout" }
  env.script[3] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  local payload = via_pipe(chain:remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  t.eq(payload.result.reply, "Я — страницы.")
  t.eq(#env.posts, 3)
  t.ok(env.posts[2].url:find("groq", 1, true))
  t.ok(env.posts[3].url:find("beatapi", 1, true))
  t.ok(env.posts[3].timeout_s >= app.ANSWER_RESERVE_S,
    "BeatAPI получил " .. tostring(env.posts[3].timeout_s) .. " с, резерв " .. tostring(app.ANSWER_RESERVE_S))
end

-- знания из Notion (срез 4): маленький Notion целиком, больше SMALL_CHARS и без отпечатков — недавнее ------

local function knowledge_db(n_docs, chars_each)
  local knowledge = require("riddle.knowledge")
  local path = os.tmpname()
  local K = knowledge.open(path)
  for i = 1, n_docs do
    K:put_doc({ id = "d" .. i, edited = string.format("2026-10-25T%02d:00:00.000Z", i % 24),
      title = "Т" .. i, text = string.rep("ф", chars_each) })
  end
  K:close()
  return path
end

function T.test_knowledge_small_vs_recent_by_threshold()
  local knowledge = require("riddle.knowledge")
  t.eq(knowledge.SMALL_CHARS, 30000)
  local big, small = knowledge_db(31, 1000), knowledge_db(20, 1000)
  local env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1" })
  env.deps.knowledge_path = big
  local text, mode = app.knowledge_text(env.deps)()
  t.eq(mode, "recent")
  t.eq(select(2, json.encode(text):gsub("ф", "")), 30000, "недавнее до порога")
  t.ok(logged(env, "riddle: knowledge recent chars=30000 of 31000"), table.concat(env.logs, "\n"))
  env.deps.knowledge_path = small
  text, mode = app.knowledge_text(env.deps)()
  t.eq(mode, "small")
  t.eq(select(2, json.encode(text):gsub("ф", "")), 20000, "маленький Notion целиком")
  t.ok(logged(env, "riddle: knowledge small chars=20000"), table.concat(env.logs, "\n"))
  local edge = knowledge_db(30, 1000)
  env.deps.knowledge_path = edge
  t.eq(select(2, app.knowledge_text(env.deps)()), "small", "ровно SMALL_CHARS — ещё целиком")
  os.remove(big); os.remove(small); os.remove(edge)
end

-- знание разделами по базам (knowledge:sections) в обоих режимах; свежесть — у документа (для prompt.fit),
-- отдельного порядка по свежести нет: третье значение — nil
function T.test_knowledge_returns_sections()
  local knowledge = require("riddle.knowledge")
  local path = os.tmpname()
  local K = knowledge.open(path)
  K:put_source("ds", "БАЗА")
  K:put_doc({ id = "a", source_id = "ds", edited = "2026-10-01T00:00:00.000Z", title = "А-старый", text = "БАЗА\nСТАРЫЙ" })
  K:put_doc({ id = "b", source_id = "ds", edited = "2026-10-20T00:00:00.000Z", title = "Б-свежий", text = "БАЗА\nСВЕЖИЙ" })
  K:put_doc({ id = "c", edited = "2026-10-10T00:00:00.000Z", title = "В-страница", text = "СТРАНИЦА" })
  K:close()
  local env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1",
    providers = { { name = "groq", url = "https://g.test/c", model = "m", key = "gq-KEY", max_input_chars = 6000 } } })
  env.deps.knowledge_path = path
  local secs, mode, recent = app.knowledge_text(env.deps)()
  t.eq(mode, "small")
  t.eq(#secs, 2, "база и страницы вне баз")
  t.eq(secs[1].title, "БАЗА")
  t.eq(secs[1].total, 2)
  t.eq(secs[1].docs[1].text, "СТАРЫЙ", "по названию, без названия базы")
  t.eq(secs[1].docs[2].edited, "2026-10-20T00:00:00.000Z", "свежесть — у документа")
  t.eq(secs[2].docs[1].text, "СТРАНИЦА")
  t.eq(recent, nil, "отдельного порядка по свежести нет")
  local big = knowledge_db(31, 1000)
  env.deps.knowledge_path = big
  local bsecs, bmode, brecent = app.knowledge_text(env.deps)()
  t.eq(bmode, "recent")
  t.ok(type(bsecs) == "table" and #bsecs == 1, "разделы и в недавнем")
  t.eq(brecent, nil)
  os.remove(path); os.remove(big)
end

-- без токена Notion и до первого чтения (документов нет) — как до среза: знания нет, база не открывается
function T.test_knowledge_none_without_token_or_docs()
  local env = make({ gemini_key = "km" })
  env.deps.knowledge_path = "/nonexistent/dir/knowledge.sqlite3"
  env.logs = {}
  t.eq(app.knowledge_text(env.deps)(), nil, "без токена")
  t.eq(#env.logs, 0, "без токена база не открывалась")
  local empty = knowledge_db(0, 0)
  env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1" })
  env.deps.knowledge_path = empty
  t.eq(app.knowledge_text(env.deps)(), nil, "документов нет")
  os.remove(empty)
end

-- сбой чтения базы: nil и строка лога без секретов, ответ не падает
function T.test_knowledge_read_failure_is_logged_masked()
  local env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1" })
  env.deps.knowledge_path = "/nonexistent/dir/secret_notion_TOKEN1.sqlite3"
  local text, mode = app.knowledge_text(env.deps)()
  t.eq(text, nil); t.eq(mode, nil)
  local l = logged(env, "riddle: knowledge read failed: ")
  t.ok(l, table.concat(env.logs, "\n"))
  t.ok(not l:find("secret_notion_TOKEN1", 1, true), "токен в логе: " .. l)
  -- ошибка с секретом в тексте (ключ из конфига, Bearer) маскируется
  local real = package.loaded["riddle.knowledge"]
  package.loaded["riddle.knowledge"] = { PATH = "x", SMALL_CHARS = 30000,
    open = function() error("boom secret_notion_TOKEN1 Bearer abc.def", 0) end }
  env.logs = {}
  local ok2, t2 = pcall(app.knowledge_text(env.deps))
  package.loaded["riddle.knowledge"] = real
  t.ok(ok2 and t2 == nil, "сбой — nil, не исключение")
  l = logged(env, "riddle: knowledge read failed: boom ***")
  t.ok(l and not l:find("TOKEN1", 1, true) and not l:find("abc.def", 1, true), table.concat(env.logs, "\n"))
end

-- база знаний закрывается после каждого чтения: настоящее соединение sqlite (conn._closed), не счётчик вызовов.
-- spy_open подменяет open у модуля знаний на обёртку, запоминающую открытые соединения; undo возвращает как было
local function spy_open(fail_after_open)
  local knowledge = require("riddle.knowledge")
  local real_open, conns = knowledge.open, {}
  knowledge.open = function(path)
    local K = real_open(path)
    conns[#conns + 1] = K.conn
    if fail_after_open then fail_after_open(K) end
    return K
  end
  return conns, function() knowledge.open = real_open end
end

function T.test_knowledge_closed_after_successful_read()
  local env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1" })
  for _, case in ipairs({ { 20, "small" }, { 31, "recent" } }) do
    local path = knowledge_db(case[1], 1000)
    env.deps.knowledge_path = path
    local conns, undo = spy_open()
    local ok, text, mode = pcall(app.knowledge_text(env.deps))
    undo()
    os.remove(path)
    t.ok(ok and text and mode == case[2], "чтение удалось: " .. tostring(text) .. " / " .. tostring(mode))
    t.eq(#conns, 1, case[2] .. ": база открыта один раз")
    t.ok(conns[1]._closed, case[2] .. ": соединение закрыто после успешного чтения")
  end
end

function T.test_knowledge_closed_after_query_error()
  local env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1" })
  local path = knowledge_db(2, 5)
  env.deps.knowledge_path = path
  local conns, undo = spy_open(function(K) K.stats = function() error("boom запрос", 0) end end)
  local ok, text = pcall(app.knowledge_text(env.deps))
  undo()
  os.remove(path)
  t.ok(ok and text == nil, "сбой запроса — nil, не исключение")
  t.ok(logged(env, "riddle: knowledge read failed: boom запрос"), table.concat(env.logs, "\n"))
  t.eq(#conns, 1)
  t.ok(conns[1]._closed, "соединение закрыто после ошибки запроса")
end

-- ошибка открытия (файл не база): knowledge.open сам закрывает соединение, app его не получает и закрыть не может
function T.test_knowledge_closed_after_open_error()
  local sqlite = require("lua-ljsqlite3/init")
  local real_open, conns = sqlite.open, {}
  sqlite.open = function(...)
    local conn = real_open(...)
    conns[#conns + 1] = conn
    return conn
  end
  local path = os.tmpname()
  local f = io.open(path, "wb"); f:write(string.rep("не база данных ", 200)); f:close()
  local env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1" })
  env.deps.knowledge_path = path
  local ok, text = pcall(app.knowledge_text(env.deps))
  sqlite.open = real_open
  os.remove(path)
  t.ok(ok and text == nil, "сбой открытия — nil, не исключение")
  t.ok(logged(env, "riddle: knowledge read failed: "), table.concat(env.logs, "\n"))
  t.eq(#conns, 1)
  t.ok(conns[1]._closed, "соединение закрыто после ошибки открытия")
end

-- new_controller подключает знание: открытая печать (печати нет) со знанием в системном промпте
function T.test_new_controller_wires_knowledge()
  local path = knowledge_db(2, 5)
  local env = make({ gemini_key = "km", notion_token = "secret_notion_TOKEN1" })
  env.deps.knowledge_path = path
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end, summaries = function() return {} end, recent = function() return {} end,
    lore_text = function() return "" end, lore_mtime = function() return nil end,
  }
  env.ctrl = app.new_controller(env.deps)
  local job = env.ctrl:begin(PNG)
  t.ok(job and job.mode == "open", "печати нет — открытая")
  t.ok(job.messages[1].content:find("ффффф", 1, true), "знание в промпте")
  os.remove(path)
end

-- незакрытые задачи (общий формат knowledge v2): контекст задач в том же открытии базы, что и знание --------

-- две коллекции-кандидата: «КНИГА-ДЕЛ» (глубина 1, выбирается сама) и «ВТОРАЯ-КНИГА» (глубина 3); в первой
-- 40 задач, из них 35 незакрытых; n_docs документов знания
local function tasks_db(opts)
  opts = opts or {}
  local knowledge = require("riddle.knowledge")
  local path = os.tmpname()
  local K = knowledge.open(path)
  for i = 1, opts.docs or 0 do
    K:put_doc({ id = "d" .. i, edited = "2026-10-25T10:00:00.000Z", title = "Т" .. i, text = "ЗНАНИЕ-" .. i })
  end
  local list = {}
  for i = 1, 40 do
    list[i] = { id = string.format("task%02d", i), collection_id = "c1", title = string.format("СЕКРЕТ-ДЕЛО-%02d", i),
      open = not opts.all_closed and i <= 35, archived = false, edited = "2026-10-25T10:00:00.000Z" }
  end
  list[#list + 1] = { id = "other1", collection_id = "c2", title = "ДЕЛО-ВТОРОЙ-КНИГИ", open = true, archived = false }
  K:put_snapshot("notion", {
    { id = "c1", title = "КНИГА-ДЕЛ", items = 40, task_candidate = true, depth = 1 },
    { id = "c2", title = "ВТОРАЯ-КНИГА", items = 1, task_candidate = true, depth = 3 },
  }, list)
  K:close()
  return path
end

local function tasks_env(cfg_extra)
  local cfg = { gemini_key = "km", notion_token = "secret_notion_TOKEN1" }
  for k, v in pairs(cfg_extra or {}) do cfg[k] = v end
  return make(cfg)
end

function T.test_tasks_context_nil_without_token()
  local path = tasks_db()
  local env = make({ gemini_key = "km" })
  env.deps.knowledge_path = path
  local conns, undo = spy_open()
  local n = select("#", app.knowledge_text(env.deps)())
  local a, b, c, d = app.knowledge_text(env.deps)()
  undo()
  os.remove(path)
  t.ok(a == nil and b == nil and c == nil and d == nil, "без токена — ни знания, ни задач")
  t.ok(n <= 1, "значений: " .. n)
  t.eq(#conns, 0, "база не открывалась")
end

function T.test_tasks_context_picks_and_logs_counts()
  local path = tasks_db()
  local env = tasks_env()
  env.deps.knowledge_path = path
  local text, mode, recent, ctx = app.knowledge_text(env.deps)()
  os.remove(path)
  t.ok(text == nil and mode == nil and recent == nil, "документов нет — знания нет")
  t.ok(ctx, "задачи есть и без документов")
  t.eq(ctx.collection.id, "c1"); t.eq(ctx.collection.title, "КНИГА-ДЕЛ")
  t.eq(ctx.why, "depth")
  t.eq(#ctx.block.items, 30, "в блоке ≤ 30")
  t.eq(ctx.block.total, 35, "всего незакрытых")
  t.eq(#ctx.open, 35)
  t.eq(#ctx.collections, 2)
  t.eq(#ctx.titles, 2); t.eq(ctx.titles[1], "КНИГА-ДЕЛ"); t.eq(ctx.titles[2], "ВТОРАЯ-КНИГА")
  t.ok(logged(env, "riddle: tasks open=35 shown=30 via=depth"), table.concat(env.logs, "\n"))
  local all = table.concat(env.logs, "\n")
  for _, secret in ipairs({ "СЕКРЕТ-ДЕЛО", "КНИГА-ДЕЛ", "ВТОРАЯ-КНИГА", "task0", "c1" }) do
    t.ok(not all:find(secret, 1, true), "в логе: " .. secret)
  end
end

-- ключ конфига tasks_source (поле в config.lua — срез 4): название второй книги — выбрана она
function T.test_tasks_context_via_config()
  local path = tasks_db()
  local env = tasks_env({ tasks_source = "вторая-книга" })
  env.deps.knowledge_path = path
  local ctx = select(4, app.knowledge_text(env.deps)())
  t.eq(ctx.collection.id, "c2", "выбрана книга из конфига")
  t.eq(ctx.why, "config")
  t.eq(ctx.block.total, 1)
  t.ok(logged(env, "riddle: tasks open=1 shown=1 via=config"), table.concat(env.logs, "\n"))
  -- слово пользователя (core) старше конфига
  local K = require("riddle.knowledge").open(path)
  K:set_core("tasks_source", "c1")
  K:close()
  ctx = select(4, app.knowledge_text(env.deps)())
  os.remove(path)
  t.eq(ctx.collection.id, "c1"); t.eq(ctx.why, "user")
end

function T.test_tasks_context_zero_open_has_no_block()
  local path = tasks_db({ all_closed = true })
  local env = tasks_env()
  env.deps.knowledge_path = path
  local ctx = select(4, app.knowledge_text(env.deps)())
  os.remove(path)
  t.ok(ctx, "контекст есть")
  t.eq(ctx.collection.id, "c1")
  t.eq(ctx.block, nil, "0 незакрытых — блока нет")
  t.eq(#ctx.titles, 2, "названия книг есть")
  t.ok(logged(env, "riddle: tasks open=0 shown=0 via=depth"), table.concat(env.logs, "\n"))
  -- коллекций нет вовсе — nil
  local empty = knowledge_db(1, 5)
  env.deps.knowledge_path = empty
  local text, _, _, none = app.knowledge_text(env.deps)()
  os.remove(empty)
  t.ok(text, "знание есть")
  t.eq(none, nil, "без коллекций — nil")
end

function T.test_tasks_read_failure_keeps_knowledge()
  local path = tasks_db({ docs = 2 })
  local env = tasks_env()
  env.deps.knowledge_path = path
  local conns, undo = spy_open(function(K) K.collections = function() error("boom задач secret_notion_TOKEN1", 0) end end)
  local ok, text, mode, _, ctx = pcall(app.knowledge_text(env.deps))
  undo()
  os.remove(path)
  t.ok(ok, "без исключения")
  t.ok(text and json.encode(text):find("ЗНАНИЕ-1", 1, true), "знание на месте")
  t.eq(mode, "small")
  t.eq(ctx, nil, "задач нет")
  local l = logged(env, "riddle: tasks read failed: boom задач ***")
  t.ok(l and not l:find("TOKEN1", 1, true), table.concat(env.logs, "\n"))
  t.ok(conns[1]._closed, "база закрыта")
end

-- длинные названия: блок урезан по знакам (prompt.fit_tasks) уже в контексте — метки контроллера = показанные
function T.test_tasks_context_block_limited_by_chars()
  local knowledge = require("riddle.knowledge")
  local path = os.tmpname()
  local K = knowledge.open(path)
  local list = {}
  for i = 1, 30 do
    list[i] = { id = string.format("task%02d", i), collection_id = "c1", open = true, archived = false,
      title = string.format("ДЕЛО-%02d ", i) .. string.rep("я", 192) }
  end
  K:put_snapshot("notion", { { id = "c1", title = "КНИГА-ДЕЛ", items = 30, task_candidate = true, depth = 1 } }, list)
  K:close()
  local env = tasks_env()
  env.deps.knowledge_path = path
  local ctx = select(4, app.knowledge_text(env.deps)())
  os.remove(path)
  local shown = #ctx.block.items
  t.ok(shown < 30, "показано " .. shown)
  t.eq(ctx.block.total, 30)
  t.eq(ctx.block.by_label["t" .. (shown + 1)], nil, "у скрытых меток нет")
  t.ok(logged(env, string.format("riddle: tasks open=30 shown=%d via=depth", shown)), table.concat(env.logs, "\n"))
end

-- одно открытие базы на ответ: знание и задачи читаются вместе, блок доходит до промпта
function T.test_knowledge_and_tasks_in_one_open()
  local path = tasks_db({ docs = 2 })
  local env = tasks_env()
  env.deps.knowledge_path = path
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end, summaries = function() return {} end, recent = function() return {} end,
    lore_text = function() return "" end, lore_mtime = function() return nil end,
  }
  env.ctrl = app.new_controller(env.deps)
  local conns, undo = spy_open()
  local job = env.ctrl:begin(PNG)
  undo()
  os.remove(path)
  t.eq(#conns, 1, "одно открытие на ответ")
  t.ok(conns[1]._closed, "закрыта")
  local s = job.messages[1].content
  t.ok(s:find("ЗНАНИЕ-1", 1, true), "знание в промпте")
  t.ok(s:find("[t1] СЕКРЕТ-ДЕЛО-01", 1, true), "блок задач в промпте")
  t.eq(job.tasks.collection.id, "c1", "контекст задач у задания")
end


-- М4: remote_fn с opts.temperature (классификация баз) — запрос с temperature 0; ответ дневника — прежние 0.8
function T.test_remote_fn_temperature_only_from_opts()
  local env = make()
  env.script[1] = { body = resp({ read = "привет", reply = "Здравствуй." }) }
  via_pipe(app.chain(env.deps):remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  t.eq(json.decode(env.posts[1].body).temperature, 0.8, "ответ дневника")
  env.script[1] = { body = json.encode({ choices = { { message = { content = "{}" }, finish_reason = "stop" } } }) }
  local p = via_pipe(app.chain(env.deps):remote_fn({ { role = "user", content = "x" } }, false,
    { max_tokens = 1500, temperature = 0 })())
  t.eq(json.decode(env.posts[2].body).temperature, 0, "классификация")
  t.eq(json.decode(env.posts[2].body).max_tokens, 1500)
  t.eq(p.result.text, "{}")
end

-- слово пользователя о книге дел: запись в core и стирание; сбой открытия — nil и ошибка без секретов
function T.test_set_tasks_source_roundtrip()
  local path = tasks_db()
  local env = tasks_env()
  env.deps.knowledge_path = path
  local set = app.set_tasks_source(env.deps)
  t.eq(set("c2"), true, "записано")
  local ctx = select(4, app.knowledge_text(env.deps)())
  t.eq(ctx.collection.id, "c2"); t.eq(ctx.why, "user")
  t.eq(set(nil), true, "стёрто")
  ctx = select(4, app.knowledge_text(env.deps)())
  t.eq(ctx.collection.id, "c1"); t.eq(ctx.why, "depth")
  local K = require("riddle.knowledge").open(path)
  t.eq(K:core("tasks_source"), nil, "в core пусто")
  K:close()
  os.remove(path)
  local bad = app.set_tasks_source({ cfg = { notion_token = "secret_notion_TOKEN1" },
    knowledge_path = "/nonexistent-dir/secret_notion_TOKEN1/k.sqlite3" })
  local ok, err = bad("c1")
  t.eq(ok, nil, "сбой — nil")
  t.ok(type(err) == "string" and err ~= "", "есть причина")
  t.ok(not err:find("secret_notion_TOKEN1", 1, true), "без токена: " .. err)
end

-- совет уже просмотренного (Notion 8152, круг 3): названия из picks сверяются со статусом документа знания; есть
-- «Просмотрено» — один повтор с поправкой в остаток бюджета; опять просмотренное (или повтор не удался) — ответ как
-- есть, такие названия выкинуты из picks, в лог — только числа
local WATCHED_KNOW = { { title = "Фильмы и сериалы", total = 2, docs = {
  { title = "Презумпция невиновности", edited = "",
    text = "Название: Презумпция невиновности\nОценка: 7\nСтатус просмотра: Просмотрено\nТип: Мини-сериал" },
  { title = "Идентификация", edited = "", text = "Название: Идентификация\nСтатус просмотра: На просмотр" } } } }

-- значения "пройдено" — из конфига (cfg.watched_values), в коде плагина слов данных нет
-- false — ключа в конфиге нет
local function picks_env(watched_values, keys)
  if watched_values == nil then watched_values = { "Просмотрено", "Прочитано" } end
  local env = make({ gemini_key = not keys and "km" or nil, gemini_keys = keys, seal = stand.key(),
    watched_values = watched_values or nil })
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end, summaries = function() return {} end,
    recent = function() return {} end, lore_text = function() return "" end,
    lore_mtime = function() return nil end, add = function() end,
  }
  env.ctrl = app.new_controller(env.deps)
  env.ctrl.deps.knowledge_text = function() return WATCHED_KNOW, "small" end
  env.ctrl.seal.open = true
  return env
end

local function picks_step(picks, reply, cost)
  return { body = resp({ read = "что посоветуешь", picks = picks, reply = reply }), cost = cost }
end

-- синхронно (devtest) и через дочерний процесс (виджет) — одно и то же
local function page(env, async)
  if not async then return env.ctrl:on_page(PNG) end
  local job = env.ctrl:begin(PNG)
  return env.ctrl:finish(job, via_pipe(job.run()))
end

local function user_text(post)
  local m = json.decode(post.body).messages
  return m[#m].content[1].text
end

function T.test_watched_pick_retries_once_with_note()
  for _, async in ipairs({ false, true }) do
    local env = picks_env()
    env.script[1] = picks_step({ " «презумпция   НЕВИНОВНОСТИ» " }, "Посмотри Презумпцию.")
    env.script[2] = picks_step({ "Идентификация" }, "Посмотри Идентификацию.")
    t.eq(page(env, async), "Посмотри Идентификацию.", "ответ повтора")
    t.eq(#env.posts, 2, "один повтор")
    local first, second = json.decode(env.posts[1].body).messages, json.decode(env.posts[2].body).messages
    t.eq(second[1].content, first[1].content, "системный тот же")
    local note = user_text(env.posts[2])
    t.ok(note:find("«Презумпция невиновности» — Просмотрено", 1, true), "название и фактическое значение: " .. note)
    t.ok(not note:find("На просмотр", 1, true), "значений других документов в поправке нет: " .. note)
    t.ok(not user_text(env.posts[1]):find("Поправка", 1, true), "в первом поправки нет")
    t.ok(logged(env, "riddle: picks watched retry n=1"), table.concat(env.logs, "\n"))
    t.ok(logged(env, "riddle: picks n=1 watched=0"), table.concat(env.logs, "\n"))
    t.ok(not logged(env, "picks watched dropped"), "после повтора чисто")
    t.ok(not table.concat(env.logs, "\n"):find("Идентификация", 1, true), "названий в логе нет")
  end
end

function T.test_watched_again_after_retry_is_dropped_reply_kept()
  for _, async in ipairs({ false, true }) do
    local env = picks_env()
    env.script[1] = picks_step({ "Презумпция невиновности" }, "Первый.")
    env.script[2] = picks_step({ "Презумпция невиновности", "Идентификация" }, "Второй.")
    t.eq(page(env, async), "Второй.", "текст ответа не переписан")
    t.eq(#env.posts, 2, "повтор один")
    t.ok(logged(env, "riddle: picks n=2 watched=1"), table.concat(env.logs, "\n"))
    t.ok(logged(env, "riddle: picks watched dropped n=1"), table.concat(env.logs, "\n"))
  end
end

function T.test_unwatched_or_unknown_pick_no_retry()
  local env = picks_env()
  env.script[1] = picks_step({ "Идентификация", "Нет такого" }, "Посмотри Идентификацию.")
  t.eq(page(env, true), "Посмотри Идентификацию.")
  t.eq(#env.posts, 1, "без повтора")
  t.ok(not logged(env, "picks watched"), table.concat(env.logs, "\n"))
  t.ok(logged(env, "riddle: picks n=2 watched=0"), table.concat(env.logs, "\n"))
end

-- ответ с map (открывашка карты) не повторяется: второй годный ответ без map затёр бы её. Просмотренное из picks в таком
-- ответе всё равно выкидывается (picks watched dropped)
function T.test_watched_pick_with_map_answer_is_not_retried()
  for _, async in ipairs({ false, true }) do
    local env = picks_env()
    env.script[1] = { body = resp({ read = "что посоветуешь", picks = { "Презумпция невиновности" },
      reply = "Посмотри карту.", map = "open" }) }
    env.script[2] = picks_step({ "Идентификация" }, "Без карты.")
    local text, action
    if async then
      local job = env.ctrl:begin(PNG)
      text, action = env.ctrl:finish(job, via_pipe(job.run()))
    else
      text, action = env.ctrl:on_page(PNG)
    end
    t.eq(action, "map", "открывашка цела")
    t.eq(text, nil, "ответа на странице нет")
    t.eq(#env.posts, 1, "без повтора")
    t.ok(not logged(env, "picks watched retry"), table.concat(env.logs, "\n"))
  end
end

-- закрывашка (map="close") открывашкой не является: повтор по просмотренному идёт как обычно
function T.test_watched_pick_with_map_close_answer_is_still_retried()
  local env = picks_env()
  env.script[1] = { body = resp({ read = "что посоветуешь", picks = { "Презумпция невиновности" },
    reply = "Первый.", map = "close" }) }
  env.script[2] = picks_step({ "Идентификация" }, "Посмотри Идентификацию.")
  t.eq(page(env, false), "Посмотри Идентификацию.", "ответ повтора")
  t.eq(#env.posts, 2, "повтор был")
end

-- сверка — по cfg.watched_values: нет ключа, пустой список или значения документа в нём нет — повтора нет, picks
-- только журналируются
function T.test_no_watched_values_no_retry_no_picks_log()
  for _, values in ipairs({ false, {} }) do
    local env = picks_env(values)
    env.script[1] = picks_step({ "Презумпция невиновности" }, "Посмотри Презумпцию.")
    t.eq(page(env, true), "Посмотри Презумпцию.")
    t.eq(#env.posts, 1, "без повтора")
    t.ok(not logged(env, "riddle: picks"), "журнала picks нет: " .. table.concat(env.logs, "\n"))
  end
end

-- значений нет в документе — повтора нет, названия только считаются
function T.test_values_without_match_no_retry_picks_counted()
  local env = picks_env({ "Прочитано" })
  env.script[1] = picks_step({ "Презумпция невиновности" }, "Посмотри Презумпцию.")
  t.eq(page(env, true), "Посмотри Презумпцию.")
  t.eq(#env.posts, 1, "без повтора")
  t.ok(logged(env, "riddle: picks n=1 watched=0"), table.concat(env.logs, "\n"))
end

-- правило picks уходит в запрос, только когда есть чем сверять (cfg.watched_values)
function T.test_picks_rule_sent_only_with_watched_values()
  for _, case in ipairs({ { false, false }, { {}, false }, { { "Просмотрено" }, true } }) do
    local env = picks_env(case[1])
    env.script[1] = picks_step({}, "Ответ.")
    page(env, true)
    local sys = json.decode(env.posts[1].body).messages[1].content
    t.eq(sys:find('"picks"', 1, true) ~= nil, case[2], "values=" .. tostring(case[1] and #case[1]))
  end
end

-- повтор: к пройденному в picks — ещё не тронутое из того же раздела (Notion «Советы: повтор не убирает просмотренное»,
-- 26.10: модель вписала в picks и опоры ответа, повтор «выбери другое» ничего не подсказывал и ответ не менялся)
local function doc(title, status)
  return { title = title, edited = "", text = "Название: " .. title .. "\nСтатус просмотра: " .. status }
end

local function utf8_len(s) return select(2, s:gsub("[^\128-\191]", "")) end

local function untouched_part(note)
  return note:match("ещё не тронуто: (.-) — выбирай отсюда%.")
end

function T.test_watched_retry_note_lists_untouched_of_section()
  local env = picks_env()
  env.ctrl.deps.knowledge_text = function()
    return { { title = "Фильмы и сериалы", total = 5, docs = {
      doc("Презумпция невиновности", "Просмотрено"), doc("Идентификация", "На просмотр"),
      doc("Другие", "На просмотр"), doc("Законопослушный гражданин", "Просмотрено"), doc("Заброшенный", "Бросил") } },
      { title = "Книги", total = 1, docs = { doc("Дюна", "На прочтение") } } }, "small"
  end
  env.script[1] = picks_step({ "Презумпция невиновности" }, "Первый.")
  env.script[2] = picks_step({ "Идентификация" }, "Второй.")
  t.eq(page(env, true), "Второй.")
  local note = user_text(env.posts[2])
  t.eq(untouched_part(note), "Идентификация; Другие; Заброшенный", "не тронутое раздела, в порядке документов: " .. note)
  t.ok(note:find("«Презумпция невиновности» — Просмотрено", 1, true), note)
  t.ok(not note:find("Законопослушный", 1, true), "просмотренное не в «не тронуто»: " .. note)
  t.ok(not note:find("Дюна", 1, true), "раздела без просмотренного в поправке нет: " .. note)
  t.ok(not table.concat(env.logs, "\n"):find("Идентификация", 1, true), "названий в логе нет")
end

function T.test_watched_retry_untouched_capped_by_whole_titles()
  local env = picks_env()
  env.ctrl.deps.knowledge_text = function()
    local docs = { doc("Просмотренный", "Просмотрено") }
    for i = 1, 60 do docs[#docs + 1] = doc(string.format("Название номер %02d для проверки", i), "На просмотр") end
    return { { title = "Фильмы и сериалы", total = 61, docs = docs } }, "small"
  end
  env.script[1] = picks_step({ "Просмотренный" }, "Первый.")
  env.script[2] = picks_step({}, "Второй.")
  page(env, true)
  local list = untouched_part(user_text(env.posts[2]))
  t.ok(list, "список есть")
  t.ok(utf8_len(list) <= 600, "потолок 600 знаков: " .. utf8_len(list))
  t.ok(utf8_len(list) > 500, "потолок выбран почти полностью: " .. utf8_len(list))
  for title in (list .. "; "):gmatch("(.-); ") do
    t.ok(title:match("^Название номер %d%d для проверки$"), "названия целиком: " .. title)
  end
end

function T.test_watched_retry_without_untouched_keeps_plain_note()
  local env = picks_env()
  env.ctrl.deps.knowledge_text = function()
    return { { title = "Фильмы и сериалы", total = 1, docs = { doc("Презумпция невиновности", "Просмотрено") } } }, "small"
  end
  env.script[1] = picks_step({ "Презумпция невиновности" }, "Первый.")
  env.script[2] = picks_step({}, "Второй.")
  page(env, true)
  local note = user_text(env.posts[2])
  t.ok(note:find("«Презумпция невиновности» — Просмотрено", 1, true), note)
  t.ok(not note:find("не тронуто", 1, true), "нечего предложить — без списка: " .. note)
end

-- два документа с одним названием, один просмотрен: название не предлагается как не тронутое (Notion 40513e60…8125)
function T.test_watched_retry_untouched_skips_title_of_watched_namesake()
  local env = picks_env()
  env.ctrl.deps.knowledge_text = function()
    return { { title = "Фильмы и сериалы", total = 3, docs = {
      doc("Дубль", "На просмотр"), doc("Дубль", "Просмотрено"), doc("Идентификация", "На просмотр") } } }, "small"
  end
  env.script[1] = picks_step({ "Дубль" }, "Первый.")
  env.script[2] = picks_step({ "Идентификация" }, "Второй.")
  t.eq(page(env, true), "Второй.")
  local note = user_text(env.posts[2])
  t.eq(untouched_part(note), "Идентификация", "просмотренное название не в «не тронуто»: " .. note)
end

-- Groq (max_input_chars 10000): длинные реплики истории и поправка повтора по максимуму — оба запроса в лимите
-- (Notion 40513e60…8133: запись и поправку prompt.fit не режет, реплики по 1000 знаков выводили запрос за лимит)
function T.test_groq_retry_with_long_history_stays_in_limit()
  local prompt = require("riddle.prompt")
  local GROQ = { name = "groq", url = "https://api.groq.com/openai/v1/chat/completions", model = "qwen/qwen3.8-27b",
    key = "gq-secret-DDDD4444", after_legacy = true, max_input_chars = 10000 }
  local env = make({ gemini_key = "km", seal = stand.key(), watched_values = { "Просмотрено" },
    providers = { GROQ } })
  local recent = {}
  for i = 1, 40 do
    recent[i] = { role = i % 2 == 1 and "owner" or "diary", text = string.format("%02d", i) .. string.rep("ж", 998) }
  end
  env.deps.memory = {
    use_persona = function() return true end, session = function() return 1 end,
    summaries = function() return { string.rep("п", 300), string.rep("р", 300) } end,
    recent = function() return recent end, lore_text = function() return string.rep("л", 2000) end,
    lore_mtime = function() return nil end, add = function() end,
  }
  local docs, picks = {}, {}
  for i = 1, 30 do
    local title = string.format("Просмотренный фильм с длинным названием номер %02d", i)
    docs[#docs + 1] = doc(title, "Просмотрено")
    picks[i] = title
  end
  for i = 1, 60 do docs[#docs + 1] = doc(string.format("Не тронутый фильм номер %02d", i), "На просмотр") end
  env.ctrl = app.new_controller(env.deps)
  env.ctrl.deps.knowledge_text = function() return { { title = "Фильмы и сериалы", total = #docs, docs = docs } }, "small" end
  env.ctrl.seal.open = true
  env.script[1] = { status = 429, body = '{"error":"rate"}' }
  env.script[2] = picks_step(picks, "Первый.")
  env.script[3] = picks_step({}, "Второй.")
  t.eq(env.ctrl:on_page(PNG), "Второй.")
  t.eq(#env.posts, 3, "Gemini, Groq, повтор на Groq")
  for i = 2, 3 do
    local m = json.decode(env.posts[i].body).messages
    t.ok(prompt.chars(m) <= 10000, "Groq: запрос " .. i .. " в лимите, " .. prompt.chars(m))
    t.ok(m[#m - 1].content:find("^40"), "последняя реплика истории на месте")
  end
  local done = user_text(env.posts[3]):match("Поправка: (.-)%. Такое не советуй")
  t.ok(done and utf8_len(done) <= 400, "найденное — в потолок 400: " .. tostring(done and utf8_len(done)))
  t.ok(done and done:find("^«Просмотренный фильм с длинным названием номер 01» — Просмотрено"), "пункты целиком")
  t.ok(not logged(env, "fit over"), table.concat(env.logs, "\n"))
end

-- первый найденный пункт длиннее потолка 400: режется по знакам с «…», UTF-8 цел (Notion 40513e60-bc8d-81f4)
function T.test_watched_retry_first_item_over_cap_is_truncated()
  local env = picks_env()
  local long = string.rep("Ж", 500)
  env.ctrl.deps.knowledge_text = function()
    return { { title = "Фильмы и сериалы", total = 2, docs = {
      doc(long, "Просмотрено"), doc("Идентификация", "На просмотр") } } }, "small"
  end
  env.script[1] = picks_step({ long }, "Первый.")
  env.script[2] = picks_step({ "Идентификация" }, "Второй.")
  t.eq(page(env, true), "Второй.")
  local note = user_text(env.posts[2])
  local done = note:match("Поправка: (.-)%. Такое не советуй")
  t.ok(done and utf8_len(done) <= 400, "найденное в потолок 400: " .. tostring(done and utf8_len(done)))
  t.eq(done and done:gsub("Ж", ""), "«…", "обрезано с «…», остались только целые «Ж»: UTF-8 цел")
  t.eq(untouched_part(note), "Идентификация", note)
end

-- повтор советов идёт с провайдера, давшего первый ответ: упавший в первом проходе (мёртвый ключ, 5xx) не повторяется
function T.test_retry_starts_from_answering_provider()
  for _, first in ipairs({
    { status = 401, body = '{"error":{"message":"API key not valid."}}' }, { status = 500, body = "{}" } }) do
    local env = picks_env(nil, { "kA", "kB" })
    env.script[1] = first
    env.script[2] = picks_step({ "Презумпция невиновности" }, "Первый.")
    env.script[3] = picks_step({ "Идентификация" }, "Второй.")
    t.eq(page(env, true), "Второй.", "status=" .. first.status)
    t.eq(#env.posts, 3, "упавший ключ в повторе не пробуется")
    t.eq(auth_of(env, 2), "Bearer kB"); t.eq(auth_of(env, 3), "Bearer kB")
  end
end

-- значение — любое из списка, без регистра и пробелов; в поправке — то, что стоит в документе
function T.test_watched_value_from_list_any_case_and_note_has_actual_value()
  local env = picks_env({ "  прочитано ", "ПРОСМОТРЕНО" })
  env.script[1] = picks_step({ "Презумпция невиновности" }, "Первый.")
  env.script[2] = picks_step({ "Идентификация" }, "Второй.")
  t.eq(page(env, true), "Второй.")
  t.eq(#env.posts, 2, "повтор")
  t.ok(user_text(env.posts[2]):find("«Презумпция невиновности» — Просмотрено", 1, true), user_text(env.posts[2]))
end

-- повтор вернул непригодное (пустой reply — запасной результат llm.call; read "?") — первый хороший ответ цел
local function unusable_retry_keeps_first(read, reply)
  for _, async in ipairs({ false, true }) do
    local env = picks_env()
    env.script[1] = picks_step({ "Презумпция невиновности" }, "Первый.")
    env.script[2] = { body = resp({ read = read, picks = {}, reply = reply }) }
    t.eq(page(env, async), "Первый.", "async=" .. tostring(async))
    t.eq(#env.posts, 2, "повтор был")
  end
end

-- генерация персоны (opts.limits = "gen", потолок дочернего CFG.gen_ceil_s = 60 с): ответ на тысячи токенов —
-- свой бюджет 50 с и попытка до 20 с (по длине ответа не урезается); путь ответа — 25 и 10,5 (короткий ответ)
function T.test_remote_gen_budget_and_attempt()
  local env = make({ gemini_key = "km", providers = { BEAT }, seal = stand.key() })
  t.eq(app.GEN_BUDGET_S, 50)
  t.eq(app.GEN_ATTEMPT_S, 20)
  local chain = app.chain(env.deps)
  env.script[1] = { cost = 20, err = "timeout" }
  env.script[2] = { body = resp({ read = "x", reply = "y" }) }
  chain:remote_fn(prompt.gen_persona("Гермиона"), false, { max_tokens = 3000, limits = "gen" })()
  t.eq(env.posts[1].timeout_s, 20, "Gemini на генерации ждёт до 20 с")
  t.eq(env.posts[2].timeout_s, 30, "BeatAPI — остаток бюджета 50 с")
  env.script[1] = { hang = true, err = "timeout" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  chain:remote_fn(prompt.open("B64", { seal = "closed" }), true)()
  t.eq(env.posts[3].timeout_s, 10.5, "путь ответа — 10,5 с по длине ответа")
end

function T.test_retry_with_empty_reply_keeps_first_answer()
  unusable_retry_keeps_first("что посоветуешь", "")
end

function T.test_retry_with_unreadable_keeps_first_answer()
  unusable_retry_keeps_first("?", "Что-то.")
end

function T.test_retry_with_empty_read_keeps_first_answer()
  unusable_retry_keeps_first("", "Что-то.")
end

function T.test_retry_with_spaces_read_keeps_first_answer()
  unusable_retry_keeps_first("   ", "Что-то.")
end

-- повтор не удался — первый ответ; повтор — только в остаток бюджета ответа
function T.test_failed_retry_keeps_first_answer_within_budget()
  for _, async in ipairs({ false, true }) do
    local env = picks_env()
    local budget = async and app.ANSWER_BUDGET_S or app.BUDGET_S
    env.script[1] = picks_step({ "Презумпция невиновности" }, "Первый.", budget - 2)
    env.script[2] = { status = 500, body = "{}" }
    t.eq(page(env, async), "Первый.")
    t.ok(#env.posts == 2 and env.posts[2].timeout_s <= 2 + 1e-9, "повтор — в остаток: " ..
      tostring(env.posts[2] and env.posts[2].timeout_s))
    t.ok(logged(env, "riddle: picks watched dropped n=1"), table.concat(env.logs, "\n"))
  end
end

-- gemini-proxy (format = "gemini", Cloudflare Worker rss_bot): токен прокси — заголовком X-Proxy-Auth --------
local function proxy_cfg(tok, extra)
  local cfg = { gemini_key = "km", seal = stand.key(), providers = {
    { name = "gemini-proxy", format = "gemini", url = "https://proxy.test", model = "gemini-3.5-flash-lite",
      proxy_auth = tok or "proxy_tok_SECRET_9f8e7d" } } }
  for _, e in ipairs(extra or {}) do cfg.providers[#cfg.providers + 1] = e end
  return cfg
end
local function native_resp(obj)
  local f = assert(io.open("tests/fixtures/gemini/image_200.json", "rb"))
  local body = json.decode(f:read("*a"))
  f:close()
  body.candidates[1].content.parts[1].text = json.encode(obj)
  return json.encode(body)
end

function T.test_proxy_answers_page_in_native_format()
  local env = make(proxy_cfg())
  env.script[1] = { body = native_resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.eq(#env.posts, 1)
  t.eq(env.posts[1].url, "https://proxy.test/v1beta/models/gemini-3.5-flash-lite:generateContent")
  t.ok(env.posts[1].body:find('"inlineData"', 1, true), "картинка — inlineData")
  -- describe: usageMetadata вместо usage, finishReason вместо finish_reason
  local line = logged(env, "llm proxy.test -> 200")
  t.ok(line and line:find("finish=STOP out_tokens=16", 1, true), tostring(line))
end

-- воркер на неверный токен отвечает 401 «unauthorized»: прокси мёртв до перезапуска, дальше прямой Gemini
function T.test_proxy_401_unauthorized_is_dead_for_following_calls()
  local env = make(proxy_cfg())
  env.script[1] = { status = 401, body = "unauthorized" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.ok(env.posts[2].url:find("generativelanguage", 1, true))
  t.ok(logged(env, "provider gemini-proxy dead"), table.concat(env.logs, "\n"))
  env.script[1] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  t.eq(#env.posts, 3)
  t.ok(env.posts[3].url:find("generativelanguage", 1, true), "следующая страница — сразу Gemini")
end

-- два прокси на одном url с разными токенами умирают порознь (custom_id учитывает X-Proxy-Auth)
function T.test_proxies_on_same_url_die_separately()
  local env = make(proxy_cfg("TOKEN-AAAAAA", { { name = "proxy-b", format = "gemini", url = "https://proxy.test",
    model = "gemini-3.5-flash-lite", proxy_auth = "TOKEN-BBBBBB" } }))
  env.script[1] = { status = 401, body = "unauthorized" }
  env.script[2] = { body = native_resp({ read = "кто ты", reply = "Я — страницы." }) }
  t.eq(env.ctrl:on_page(PNG), "Я — страницы.")
  t.ok(not logged(env, "provider proxy-b dead"), table.concat(env.logs, "\n"))
  env.script[1] = { body = native_resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  t.eq(env.posts[3].headers["X-Proxy-Auth"], "TOKEN-BBBBBB", "proxy-b ещё в цепочке")
end

-- токен прокси, попавший в тело ошибки, в лог не идёт (config_secrets)
function T.test_proxy_token_never_reaches_log()
  local env = make(proxy_cfg())
  env.script[1] = { status = 502, body = "upstream fetch error: proxy_tok_SECRET_9f8e7d" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  env.ctrl:on_page(PNG)
  t.ok(logged(env, "llm proxy.test -> 502"), table.concat(env.logs, "\n"))
  for _, l in ipairs(env.logs) do t.ok(not l:find("proxy_tok_SECRET_9f8e7d", 1, true), "токен в логе: " .. l) end
end

-- gemini-proxy на пути ответа ждёт до ANSWER_PROXY_ATTEMPT_S (7 с); прямой Gemini получает остаток: min(12, 25 − 7 − 7)
function T.test_remote_answer_hung_proxy_capped_direct_gemini_gets_10_5s()
  local env = make(proxy_cfg(nil, { BEAT }))
  t.eq(app.ANSWER_PROXY_ATTEMPT_S, 7)
  env.script[1] = { hang = true, err = "timeout" }
  env.script[2] = { hang = true, err = "timeout" }
  env.script[3] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  local payload = via_pipe(app.chain(env.deps):remote_fn(prompt.open("B64", { seal = "closed" }), true)())
  t.eq(payload.result.reply, "Я — страницы.")
  t.eq(env.posts[1].timeout_s, 7, "прокси — потолок 7 с")
  t.ok(env.posts[2].url:find("generativelanguage", 1, true))
  t.eq(env.posts[2].timeout_s, 10.5, "прямой Gemini — min(11, 10,5 по длине ответа)")
  t.ok(env.posts[3].url:find("beatapi", 1, true))
  t.ok(env.posts[3].timeout_s >= app.ANSWER_RESERVE_S, "резерв последнего цел")
end

-- синхронный путь потолка прокси не знает
function T.test_sync_call_proxy_not_capped_by_answer_ceiling()
  local env = make(proxy_cfg(nil, { BEAT }))
  env.script[1] = { hang = true, err = "timeout" }
  env.script[2] = { body = resp({ read = "кто ты", reply = "Я — страницы." }) }
  app.chain(env.deps):call(prompt.open("B64", { seal = "closed" }), true)
  t.eq(env.posts[1].timeout_s, 4, "синхронно — 4 с, как прежде")
end

-- повтор по picks на пути ответа — с тем же потолком попытки по длине ответа (10,5 с), а не прежними 12 с
function T.test_retry_keeps_answer_size_ceiling()
  local env = picks_env()
  env.deps.cfg.providers = { BEAT }
  env.script[1] = picks_step({ "Презумпция невиновности" }, "Первый.")
  env.script[2] = { hang = true, err = "wantread" }
  env.script[3] = { body = resp({ read = "что посоветуешь", picks = {}, reply = "Второй." }) }
  page(env, true)
  t.eq(#env.posts, 3, "повтор был: Gemini повис, затем BeatAPI")
  t.eq(env.posts[2].timeout_s, 10.5, "повтор: потолок попытки по длине ответа")
end

-- повтор по picks идёт с того же провайдера и с тем же потолком прокси
function T.test_watched_retry_keeps_proxy_ceiling()
  local env = picks_env()
  env.deps.cfg.providers = { { name = "gemini-proxy", format = "gemini", url = "https://proxy.test",
    model = "gemini-3.5-flash-lite", proxy_auth = "tok" } }
  env.script[1] = { body = native_resp({ read = "что посоветуешь", picks = { "Презумпция невиновности" },
    reply = "Посмотри Презумпцию." }) }
  env.script[2] = { hang = true, err = "timeout" }
  env.script[3] = { body = resp({ read = "что посоветуешь", picks = { "Идентификация" }, reply = "Посмотри Идентификацию." }) }
  t.eq(page(env, true), "Посмотри Идентификацию.")
  t.ok(env.posts[2].url:find("proxy.test", 1, true), "повтор начался с прокси")
  t.eq(env.posts[2].timeout_s, 7, "повтор: потолок прокси 7 с")
end

-- суточная квота всей цепочки (Notion 40313e60-bc8d-81a5): каждый опрошенный провайдер отказал суточной квотой —
-- пул fail_daily, иначе прежний. Тела 429 по провайдерам: Gemini — прямой и gemini-proxy (воркер rss_bot
-- cloudflare/gemini-proxy/worker.js отдаёт тело Google как есть) — google.rpc.QuotaFailure, quotaId …PerDay… /
-- …PerMinute…; Groq — суточные лимиты (RPD, TPD) различимы только по заголовкам x-ratelimit-*, тело не
-- задокументировано (console.groq.com/docs/rate-limits); BeatAPI — error{code, message, retryable,
-- retry_after_seconds}, суточного лимита в документации нет (docs.beatapi.io/development). Признак суточной квоты у
-- Groq и BeatAPI неизвестен: их 429 суточным не считается, даже со словами о сутках в теле
local DAY_429 = quota_body("GenerateRequestsPerDayPerProjectPerModel-FreeTier")
local MINUTE_429 = quota_body("GenerateRequestsPerMinutePerProjectPerModel-FreeTier")
local BEAT_429 = '{"error":{"code":"rate_limit_exceeded","message":"Too many requests. Wait 12 seconds, then retry.",'
  .. '"retryable":true,"request_id":"req_1","retry_after_seconds":12}}'
local GROQ = { name = "groq", url = "https://api.groq.com/openai/v1/chat/completions", model = "qwen/qwen3.8-27b",
  key = "gq-secret-DDDD4444", after_legacy = true }

local function pool_of(text)
  for _, name in ipairs({ "fail_daily", "fail_limit", "fail_slow", "fail_other", "fail_offline" }) do
    for _, s in ipairs(texts[name] or {}) do if s == text then return name end end
  end
  return "нет пула: " .. tostring(text)
end

-- цепочка gemini-proxy → два ключа Gemini (+ extra после них); script — ответы по порядку -> имя пула фразы, env
local function chain_pool(script, extra)
  local cfg = proxy_cfg(nil, extra)
  cfg.gemini_keys = { "kn" }
  local env = make(cfg)
  for i, s in ipairs(script) do env.script[i] = s end
  local text = env.ctrl:on_page(PNG)
  return pool_of(text), env
end

function T.test_all_providers_daily_quota_gives_fail_daily()
  local pool, env = chain_pool({ { status = 429, body = DAY_429 }, { status = 429, body = DAY_429 },
    { status = 429, body = DAY_429 } })
  t.eq(#env.posts, 3, "опрошены прокси и оба ключа")
  t.eq(pool, "fail_daily", table.concat(env.logs, "\n"))
end

function T.test_one_minute_quota_keeps_fail_limit()
  local pool, env = chain_pool({ { status = 429, body = DAY_429 }, { status = 429, body = MINUTE_429 },
    { status = 429, body = DAY_429 } })
  t.eq(#env.posts, 3)
  t.eq(pool, "fail_limit", "минутная у одного — прежний пул")
end

function T.test_daily_then_503_keeps_old_pool()
  local pool = chain_pool({ { status = 429, body = DAY_429 }, { status = 429, body = DAY_429 },
    { status = 503, body = DAY_429 } })
  t.eq(pool, "fail_other", "503 последним — прежний пул")
  pool = chain_pool({ { status = 429, body = DAY_429 }, { status = 429, body = DAY_429 }, { err = "timeout" } })
  t.eq(pool, "fail_slow", "таймаут последним — прежний пул")
  pool = chain_pool({ { status = 429, body = DAY_429 }, { status = 429, body = '{"error":"rate"}' },
    { status = 429, body = DAY_429 } })
  t.eq(pool, "fail_limit", "429 без quotaId — не суточная")
end

-- Groq и BeatAPI: признак неизвестен — их 429 не суточный, даже если в теле есть «PerDay»
function T.test_unknown_provider_429_is_never_daily()
  local pool, env = chain_pool({ { status = 429, body = DAY_429 }, { status = 429, body = DAY_429 },
    { status = 429, body = DAY_429 }, { status = 429, body = DAY_429 }, { status = 429, body = BEAT_429 } },
    { GROQ, BEAT })
  t.eq(#env.posts, 5, "опрошена вся цепочка")
  t.eq(pool, "fail_limit")
  local groq = logged(env, "llm api.groq.com -> 429")
  t.ok(groq and not groq:find("quota=", 1, true), "признак — одно место: у Groq и в логе нет: " .. tostring(groq))
end

-- «опрошен» = запрос ушёл (ответ или транспортный сбой); суточная квота цепочки — когда ВСЕ опрошенные отказали ею.
-- Пропущенный по бюджету провайдер не опрошен (Notion 41013e60-bc8d-8111): прокси №1 отвечает суточной 429 за 6,5 с
-- (остаток бюджета 8 с — 1,5 < MIN_ATTEMPT_S), прокси №2 не-последний — пропущен без запроса; оба ключа Gemini опрошены
-- и тоже отказали суточной: цепочка суточная. Если считать пропущенного опрошенным — «daily == polled» не сойдётся
function T.test_budget_skipped_provider_is_not_polled_for_daily_quota()
  local proxy2 = { name = "gemini-proxy-2", format = "gemini", url = "https://proxy2.test",
    model = "gemini-3.5-flash-lite", proxy_auth = "proxy_tok_SECOND_1a2b3c" }
  local pool, env = chain_pool({ { status = 429, body = DAY_429, cost = 6.5 }, { status = 429, body = DAY_429 },
    { status = 429, body = DAY_429 } }, { proxy2 })
  t.eq(#env.posts, 3, "прокси №1 и оба ключа; прокси №2 по бюджету не опрошен")
  for _, post in ipairs(env.posts) do t.ok(not post.url:find("proxy2.test", 1, true), "прокси №2 вызван: " .. post.url) end
  t.eq(pool, "fail_daily", table.concat(env.logs, "\n"))
end

-- несобранный запрос тоже не опрошен: у прокси (нативный формат) нет ни одной части user/assistant — в сеть не идём,
-- Gemini перед ним отказал суточной квотой: ошибка цепочки с llm.DAILY. Если считать несобранного опрошенным — без префикса
function T.test_unbuilt_provider_is_not_polled_for_daily_quota()
  local list = llm.providers({ gemini_key = "km", providers = { { name = "gemini-proxy", format = "gemini",
    url = "https://proxy.test", model = "gemini-3.5-flash-lite", proxy_auth = "proxy_tok_SECRET_9f8e7d",
    after_legacy = true } } })
  t.eq(#list, 2, "Gemini и после него прокси")
  local posts = 0
  local res, err = llm.call(list, { { role = "system", content = "s" } }, {
    post = function() posts = posts + 1 return 429, DAY_429 end, now = function() return 0 end, budget_s = 8 })
  t.eq(res, nil)
  t.eq(posts, 1, "прокси без частей запроса по сети не вызван")
  t.ok(llm.daily(err), "ошибка цепочки без llm.DAILY: " .. tostring(err))
  t.eq(err, llm.DAILY .. "gemini-proxy: empty contents")
end

t.run(T)
