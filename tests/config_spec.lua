local t = require("t")
local config = require("riddle.config")

local files = {}
local function write_cfg(text)
  local path = os.tmpname()
  files[#files + 1] = path
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  return path
end

local tests = {}

function tests.test_missing_file_gives_keyless_defaults()
  local cfg = config.load("/nonexistent/riddle/config.lua")
  t.eq(cfg.gemini_key, nil)
  t.eq(cfg.openrouter_key, nil)
  t.eq(cfg.seal.on, false, "печати по умолчанию нет")
end

function tests.test_loads_fields()
  local cfg = config.load(write_cfg([[return {
    gemini_key = "m", notion_token = "o",
    seal = { key = true } }]]))
  t.eq(cfg.gemini_key, "m")
  t.eq(cfg.notion_token, "o")
  t.eq(cfg.seal.on, true)
end

function tests.test_notion_token_cleaned()
  t.eq(config.load(write_cfg('return { notion_token = "  ntn_abc123\\n" }')).notion_token, "ntn_abc123")
  t.eq(config.load(write_cfg('return { notion_token = "your_token_here" }')).notion_token, nil, "заглушка")
  t.eq(config.load(write_cfg('return { notion_token = "   " }')).notion_token, nil)
  t.eq(config.load(write_cfg('return { notion_token = 42 }')).notion_token, nil)
  t.eq(config.load("/nonexistent/riddle/config.lua").notion_token, nil)
end

-- watched_values — значения свойства знания, при которых документ пройден (сверка советов, Notion 8152): список
-- непустых строк без пробелов по краям, без дублей; нет, не список или пусто — пустой список (сверка выключена)
function tests.test_watched_values_cleaned()
  local function load(src) return config.load(write_cfg(src)).watched_values end
  local v = load('return { watched_values = { " Просмотрено ", "Прочитано", "", 5, "Прочитано" } }')
  t.eq(#v, 2); t.eq(v[1], "Просмотрено"); t.eq(v[2], "Прочитано")
  t.eq(#load('return { watched_values = "Просмотрено" }'), 0, "не список")
  t.eq(#load('return { watched_values = {} }'), 0)
  t.eq(#load('return {}'), 0, "нет ключа")
  t.eq(#config.load("/nonexistent/riddle/config.lua").watched_values, 0)
  t.eq(#config.load("config.example.lua").watched_values, 0, "в примере — только комментарий: сверка выключена")
end

-- tasks_source — название или id базы задач; не ключ: заглушки нет, внутренние пробелы целы
function tests.test_tasks_source_cleaned()
  t.eq(config.load(write_cfg('return { tasks_source = "  Мои задачи \\n" }')).tasks_source, "Мои задачи")
  t.eq(config.load(write_cfg('return { tasks_source = "   " }')).tasks_source, nil)
  t.eq(config.load(write_cfg('return { tasks_source = 42 }')).tasks_source, nil)
  t.eq(config.load("/nonexistent/riddle/config.lua").tasks_source, nil)
  t.eq(config.load("config.example.lua").tasks_source, nil, "в примере — только комментарий: дневник ищет сам")
  local f = assert(io.open("config.example.lua", "r"))
  local text = f:read("*a")
  f:close()
  t.ok(text:find("tasks_source", 1, true), "пример называет ключ")
end

-- OpenRouter убран из цепочки (2026-10-25): старый конфиг с openrouter_key грузится, ключ игнорируется
function tests.test_openrouter_key_is_ignored()
  local llm = require("riddle.llm")
  local cfg = config.load(write_cfg('return { gemini_key = "m", openrouter_key = "or", whose = "w" }'))
  t.eq(cfg.openrouter_key, nil, "поле не читается")
  t.eq(cfg.gemini_key, "m")
  t.eq(cfg.whose, "w", "остальное загружено")
  t.eq(#llm.providers(cfg), 1, "только Gemini")
  t.eq(#llm.providers(config.load(write_cfg('return { openrouter_key = "or" }'))), 0)
end

-- max_tokens провайдера (BeatAPI обрезает ответ на 200): целое 1..4096, иначе поле отброшено
function tests.test_provider_max_tokens_is_kept_when_valid()
  local cfg = config.load(write_cfg([[return { providers = {
    { name = "a", url = "https://a.test/c", model = "m", key = "k1", max_tokens = 400 },
    { name = "b", url = "https://b.test/c", model = "m", key = "k2", max_tokens = 0 },
    { name = "c", url = "https://c.test/c", model = "m", key = "k3", max_tokens = "400" },
    { name = "d", url = "https://d.test/c", model = "m", key = "k4", max_tokens = 1.5 },
    { name = "e", url = "https://e.test/c", model = "m", key = "k5" },
  } }]]))
  t.eq(#cfg.providers, 5, "плохой max_tokens запись не убирает")
  t.eq(cfg.providers[1].max_tokens, 400)
  for i = 2, 5 do t.eq(cfg.providers[i].max_tokens, nil, "запись " .. i) end
end

-- max_input_chars — лимит входа провайдера в знаках (Groq: ITPM 7000): целое 1..MAX_INPUT_CHARS_CAP, иначе отброшено
function tests.test_provider_max_input_chars_is_kept_when_valid()
  local cfg = config.load(write_cfg([[return { providers = {
    { name = "a", url = "https://a.test/c", model = "m", key = "k1", max_input_chars = 14000 },
    { name = "b", url = "https://b.test/c", model = "m", key = "k2", max_input_chars = 0 },
    { name = "c", url = "https://c.test/c", model = "m", key = "k3", max_input_chars = "14000" },
    { name = "d", url = "https://d.test/c", model = "m", key = "k4", max_input_chars = 1.5 },
    { name = "e", url = "https://e.test/c", model = "m", key = "k5", max_input_chars = math.huge },
    { name = "f", url = "https://f.test/c", model = "m", key = "k6", max_input_chars = 0/0 },
    { name = "g", url = "https://g.test/c", model = "m", key = "k7" },
    { name = "h", url = "https://h.test/c", model = "m", key = "k8", max_input_chars = -5 },
    { name = "i", url = "https://i.test/c", model = "m", key = "k9", max_input_chars = 2e6 },
  } }]]))
  t.eq(#cfg.providers, 9, "плохой max_input_chars запись не убирает")
  t.eq(cfg.providers[1].max_input_chars, 14000)
  for i = 2, 9 do t.eq(cfg.providers[i].max_input_chars, nil, "запись " .. i) end
end

-- бесконечность проходила проверку на целое (floor(inf) == inf) и уходила в JSON как inf: потолок 4096
function tests.test_provider_max_tokens_has_upper_bound()
  local cfg = config.load(write_cfg([[return { providers = {
    { name = "a", url = "https://a.test/c", model = "m", key = "k1", max_tokens = math.huge },
    { name = "b", url = "https://b.test/c", model = "m", key = "k2", max_tokens = 4097 },
    { name = "c", url = "https://c.test/c", model = "m", key = "k3", max_tokens = 4096 },
    { name = "d", url = "https://d.test/c", model = "m", key = "k4", max_tokens = 0/0 },
  } }]]))
  t.eq(#cfg.providers, 4)
  t.eq(cfg.providers[1].max_tokens, nil, "math.huge")
  t.eq(cfg.providers[2].max_tokens, nil, "4097")
  t.eq(cfg.providers[3].max_tokens, 4096)
  t.eq(cfg.providers[4].max_tokens, nil, "nan")
end

-- лишние ключи (Groq, Cloudflare из старых конфигов): загрузка не ломается, поля не читаются, провайдера нет
function tests.test_extra_keys_do_not_break_load_and_give_no_provider()
  local llm = require("riddle.llm")
  local alone = config.load(write_cfg('return { groq_key = "g", cf_token = "c", cf_account = "a", stale = 1, whose = "w" }'))
  t.eq(alone.groq_key, nil, "Groq из цепочки исключён — поле не читается")
  t.eq(alone.cf_token, nil, "Cloudflare из цепочки исключён — поле не читается")
  t.eq(alone.cf_account, nil)
  t.eq(alone.whose, "w", "остальное загружено")
  t.eq(#llm.providers(alone), 0, "лишние ключи провайдера не дают")
  local mixed = config.load(write_cfg('return { cf_token = "c", gemini_key = "m" }'))
  t.eq(mixed.gemini_key, "m")
  t.eq(mixed.cf_token, nil)
  t.eq(#llm.providers(mixed), 1)
end

function tests.test_partial_file_fills_defaults()
  local cfg = config.load(write_cfg('return { gemini_key = "m" }'))
  t.eq(cfg.gemini_key, "m")
  t.eq(cfg.openrouter_key, nil)
  t.eq(cfg.seal.on, false)
end

function tests.test_syntax_error_gives_keyless_defaults()
  local cfg = config.load(write_cfg("return { gemini_key = "))
  t.eq(cfg.gemini_key, nil)
end

function tests.test_runtime_error_gives_keyless_defaults()
  local cfg = config.load(write_cfg('error("boom")'))
  t.eq(cfg.gemini_key, nil)
end

function tests.test_non_table_result_gives_defaults()
  local cfg = config.load(write_cfg('return "oops"'))
  t.eq(cfg.gemini_key, nil)
end

function tests.test_placeholder_and_empty_keys_are_absent()
  local cfg = config.load(write_cfg([[return {
    notion_token = "your_token_here", gemini_key = 42 }]]))
  t.eq(cfg.notion_token, nil, "заглушка из примера — не ключ")
  t.eq(cfg.gemini_key, nil, "не строка — не ключ")
  cfg = config.load(write_cfg('return { notion_token = "", gemini_key = "real" }'))
  t.eq(cfg.notion_token, nil, "пустая строка — не ключ")
  t.eq(cfg.gemini_key, "real")
end

function tests.test_key_whitespace_is_trimmed()
  local cfg = config.load(write_cfg([[return {
    notion_token = "  tok_x\t\n", gemini_key = " \n " }]]))
  t.eq(cfg.notion_token, "tok_x", "пробелы, табуляция и перевод строки по краям срезаны")
  t.eq(cfg.gemini_key, nil, "одни пробелы — нет ключа")
end

function tests.test_placeholder_with_whitespace_is_absent()
  local cfg = config.load(write_cfg('return { gemini_key = " your_token_here\\n" }'))
  t.eq(cfg.gemini_key, nil)
end

function tests.test_inner_whitespace_is_kept()
  local cfg = config.load(write_cfg('return { gemini_key = "a b" }'))
  t.eq(cfg.gemini_key, "a b")
end

function tests.test_example_file_is_keyless()
  local cfg = config.load("config.example.lua")
  t.eq(cfg.gemini_key, nil)
  t.eq(cfg.openrouter_key, nil)
  t.eq(#cfg.providers, 0, "в примере ключ-заглушка: провайдер из примера не подключается")
end

function tests.test_default_path_is_device_path()
  t.eq(config.DEFAULT_PATH, "/mnt/us/riddle/config.lua")
  -- вызов без пути на Mac: файла нет → пустой конфиг, не падение
  local cfg = config.load()
  t.eq(cfg.seal.on, false)
end

function tests.test_loads_are_independent()
  local path = write_cfg('return { seal = { key = true } }')
  local a = config.load(path)
  a.seal.key = false
  t.eq(config.load(path).seal.key, true)
end

-- печать (spec 2026-11-20 §3): таблица seal, всегда есть в cfg
local function seal_of(body)
  return config.load(write_cfg("return { " .. body .. " }")).seal
end

function tests.test_seal_absent_is_off()
  for _, s in ipairs({ seal_of(""), config.load("/nonexistent/riddle/config.lua").seal, seal_of("seal = {}"),
      seal_of("seal = { remember = false }"), seal_of("seal = { on_sleep = false }") }) do
    t.eq(s.on, false, "правил нет — печати нет")
    t.eq(s.invalid, nil)
    t.eq(s.key, false)
    t.eq(s.minutes, nil)
    t.eq(s.on_sleep, false)
    t.eq(s.off, false)
  end
  t.eq(seal_of("").remember, true, "remember по умолчанию true")
end

function tests.test_seal_key_only()
  local s = seal_of("seal = { key = true }")
  t.eq(s.on, true)
  t.eq(s.key, true)
  t.eq(s.minutes, nil)
  t.eq(s.on_sleep, false)
  t.eq(s.remember, true)
  t.eq(s.invalid, nil)
end

function tests.test_seal_all_rules()
  local s = seal_of("seal = { key = true, minutes = 30, on_sleep = true }")
  t.eq(s.on, true)
  t.eq(s.minutes, 30)
  t.eq(s.on_sleep, true)
  t.eq(s.invalid, nil)
end

function tests.test_seal_off_wins()
  local s = seal_of("seal = { key = true, minutes = 5, off = true }")
  t.eq(s.on, false)
  t.eq(s.off, true)
  -- off — выход из битого конфига: снимает и битую печать
  local bad = seal_of("seal = { minutes = 5, off = true }")
  t.eq(bad.on, false, "off побеждает и правило без key")
  t.eq(bad.invalid, nil)
end

function tests.test_seal_rule_without_key_invalid()
  for _, body in ipairs({ "seal = { minutes = 5 }", "seal = { on_sleep = true }",
      "seal = { key = false, minutes = 5 }" }) do
    local s = seal_of(body)
    t.eq(s.on, true, "закрыта: " .. body)
    t.ok(type(s.invalid) == "string" and s.invalid:find("key", 1, true), "причина про key: " .. body .. " / " ..
      tostring(s.invalid))
  end
end

function tests.test_seal_bad_minutes_invalid()
  for _, v in ipairs({ "0", "2.5", '"5"', "-1", "true" }) do
    local s = seal_of("seal = { key = true, minutes = " .. v .. " }")
    t.eq(s.on, true, "закрыта: " .. v)
    t.ok(type(s.invalid) == "string" and s.invalid:find("minutes", 1, true), "причина про minutes: " .. v)
  end
end

function tests.test_seal_non_bool_flags_invalid()
  for _, body in ipairs({ 'key = "yes"', "key = 1", 'key = true, on_sleep = "y"', "key = true, remember = 0",
      'key = true, off = "true"' }) do
    local s = seal_of("seal = { " .. body .. " }")
    t.eq(s.on, true, "закрыта: " .. body)
    t.ok(type(s.invalid) == "string", "invalid: " .. body)
  end
  local s = seal_of('seal = "key"')
  t.eq(s.on, true, "seal не таблица — закрыта")
  t.ok(type(s.invalid) == "string")
end

function tests.test_seal_remember_false()
  local s = seal_of("seal = { key = true, remember = false }")
  t.eq(s.remember, false)
  t.eq(s.on, true)
end

-- файл есть, но не загрузился: что в нём было, неизвестно — печать закрыта
function tests.test_broken_file_closes_seal()
  for _, text in ipairs({ "return { gemini_key = ", 'error("boom")', 'return "oops"' }) do
    local s = config.load(write_cfg(text)).seal
    t.eq(s.on, true, "закрыта: " .. text)
    t.ok(type(s.invalid) == "string", "invalid: " .. text)
  end
end

-- старое слово (Review Focus 5): не читается, печати нет, флаг для лога
function tests.test_legacy_word_ignored()
  local cfg = config.load(write_cfg('return { password_variants = { "x" }, hints = { "h" }, hint_every = 2 }'))
  t.eq(cfg.seal.on, false)
  t.eq(cfg.seal.invalid, nil)
  t.eq(cfg.legacy_word, true)
  t.eq(cfg.password_variants, nil)
  t.eq(cfg.hints, nil)
  t.eq(cfg.hint_every, nil)
  t.eq(cfg.seal_invalid, nil)
  t.eq(config.load(write_cfg('return { seal = { key = true } }')).legacy_word, nil, "без слова флага нет")
end

function tests.test_example_file_has_seal_fields()
  local s = config.load("config.example.lua").seal
  t.eq(s.on, true, "пример показывает таблицу seal")
  t.eq(s.invalid, nil, "пример печати валиден")
  t.eq(s.key, true)
end

function tests.test_gemini_keys_list_is_cleaned()
  local cfg = config.load(write_cfg([[return {
    gemini_key = "k1", gemini_keys = { " k2 ", "", 7, "k2", "your_token_here", "k3", "k1" } }]]))
  t.eq(cfg.gemini_key, "k1")
  t.eq(table.concat(cfg.gemini_keys, ","), "k2,k3,k1", "пустые, не-строки, заглушки и дубли отброшены")
  t.eq(#config.load(write_cfg('return { gemini_keys = "k" }')).gemini_keys, 0, "не таблица — нет списка")
  t.eq(#config.load("/nonexistent/riddle/config.lua").gemini_keys, 0)
end

-- providers: любой OpenAI-совместимый провайдер строкой в конфиге; порядок списка сохраняется,
-- key необязателен (локальный сервер без ключа), битые записи пропускаются, загрузка не падает
function tests.test_providers_loaded_in_order_key_optional()
  local cfg = config.load(write_cfg([[return { providers = {
    { name = "lite", url = " https://lite.test/v1/chat/completions ", model = " m1 ", key = " k1 " },
    { name = "local", url = "https://local.test/v1/chat/completions", model = "m2" },
    { url = "https://noname.test/chat/completions", model = "m3" },
  } }]]))
  t.eq(#cfg.providers, 3)
  t.eq(cfg.providers[1].name, "lite")
  t.eq(cfg.providers[1].url, "https://lite.test/v1/chat/completions", "пробелы по краям убраны")
  t.eq(cfg.providers[1].model, "m1")
  t.eq(cfg.providers[1].key, "k1")
  t.eq(cfg.providers[2].name, "local")
  t.eq(cfg.providers[2].key, nil, "без ключа — без ключа")
  t.eq(cfg.providers[3].name, "noname.test", "имя по умолчанию — хост")
end

-- after_legacy: только булево true; всё прочее — как без флага
function tests.test_provider_after_legacy_flag_kept_only_for_true()
  local cfg = config.load(write_cfg([[return { providers = {
    { name = "a", url = "https://a.test/c", model = "m", after_legacy = true },
    { name = "b", url = "https://b.test/c", model = "m", after_legacy = "yes" },
    { name = "c", url = "https://c.test/c", model = "m" },
  } }]]))
  t.eq(cfg.providers[1].after_legacy, true)
  t.eq(cfg.providers[2].after_legacy, nil)
  t.eq(cfg.providers[3].after_legacy, nil)
end

function tests.test_bad_provider_entries_are_skipped()
  local cfg = config.load(write_cfg([[return { providers = {
    "строка", 7,
    { name = "no_url", model = "m" },
    { name = "no_model", url = "https://x.test/chat/completions" },
    { name = "num_url", url = 5, model = "m" },
    { name = "empty_model", url = "https://x.test/chat/completions", model = "  " },
    { name = "bad_key", url = "https://x.test/chat/completions", model = "m", key = 42 },
    { name = "placeholder", url = "https://x.test/chat/completions", model = "m", key = "your_token_here" },
    { name = "empty_key", url = "https://x.test/chat/completions", model = "m", key = "" },
    { name = "good", url = "https://good.test/chat/completions", model = "m", key = "k" },
  } }]]))
  t.eq(#cfg.providers, 1, "остались только целые записи")
  t.eq(cfg.providers[1].name, "good")
  t.eq(#config.load(write_cfg('return { providers = "x" }')).providers, 0, "не список — пусто")
  t.eq(#config.load(write_cfg("return {}")).providers, 0)
  t.eq(#config.load("/nonexistent/riddle/config.lua").providers, 0)
end

-- транспорт знает только https: запись с другой схемой отбрасывается при загрузке, а не при каждом запросе
function tests.test_provider_url_must_be_https()
  local cfg = config.load(write_cfg([[return { providers = {
    { name = "plain", url = "http://plain.test/chat/completions", model = "m" },
    { name = "ftp", url = "ftp://x.test/c", model = "m" },
    { name = "bare", url = "lite.test/chat/completions", model = "m" },
    { name = "good", url = "https://good.test/chat/completions", model = "m" },
  } }]]))
  t.eq(#cfg.providers, 1)
  t.eq(cfg.providers[1].name, "good")
end

-- gemini-proxy: format "gemini" и proxy_auth (токен прокси) проходят; другой format, пустой токен или заглушка —
-- запись отброшена (запрос ушёл бы не туда или без авторизации)
function tests.test_provider_gemini_format_and_proxy_auth()
  local cfg = config.load(write_cfg([[return { providers = {
    { name = "gemini-proxy", format = "gemini", url = "https://p.test", model = "m", proxy_auth = " tok_1 " },
    { name = "b", format = "anthropic", url = "https://b.test", model = "m" },
    { name = "c", format = "gemini", url = "https://c.test", model = "m", proxy_auth = "" },
    { name = "d", format = "gemini", url = "https://d.test", model = "m", proxy_auth = "your_token_here" },
    { name = "e", format = "gemini", url = "https://e.test", model = "m", proxy_auth = 5 },
    { name = "f", url = "https://f.test/c", model = "m", key = "k" },
  } }]]))
  t.eq(#cfg.providers, 2)
  t.eq(cfg.providers[1].format, "gemini")
  t.eq(cfg.providers[1].proxy_auth, "tok_1")
  t.eq(cfg.providers[2].name, "f")
  t.eq(cfg.providers[2].format, nil)
  t.eq(cfg.providers[2].proxy_auth, nil)
end

-- whose — чей это дневник, свободный текст (спека 2026-10-31, пункт 1); не ключ: внутренние пробелы и кавычки целы
function tests.test_whose_trimmed_or_nil()
  t.eq(config.load(write_cfg('return { whose = "  Гермиона Грейнджер \\n" }')).whose, "Гермиона Грейнджер")
  t.eq(config.load(write_cfg('return { whose = "Том Реддл из «Методов»" }')).whose, "Том Реддл из «Методов»")
  t.eq(config.load(write_cfg('return { whose = "   " }')).whose, nil)
  t.eq(config.load(write_cfg('return { whose = 42 }')).whose, nil)
  t.eq(config.load("/nonexistent/riddle/config.lua").whose, nil)
end

local ok, err = pcall(t.run, tests)
for _, p in ipairs(files) do os.remove(p) end
if not ok then error(err, 0) end
