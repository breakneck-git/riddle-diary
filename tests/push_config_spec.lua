-- tools/push_config.sh с поддельным ssh и фиктивным env-файлом: настоящие ключи и устройство не нужны.
local t = require("t")
local config = require("riddle.config")

-- io.popen в LuaJIT не отдаёт код возврата: дописываем его в вывод
local function sh(cmd)
  local p = assert(io.popen("(" .. cmd .. ") 2>&1; echo __rc=$?", "r"))
  local out = p:read("*a")
  p:close()
  local rc = tonumber(out:match("__rc=(%d+)%s*$"))
  return (out:gsub("__rc=%d+%s*$", "")), rc == 0
end

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- файл печати (RIDDLE_SEAL): таблица seal, как в config.example.lua
local SEAL = 'seal = { key = true, minutes = 30 },\n'

-- каталог со скриптом-подделкой ssh, который складывает stdin в файл; seal_text = false — без файла печати
local function sandbox(env_text, seal_text)
  local dir = sh("mktemp -d"):gsub("%s+$", "")
  sh("mkdir -p " .. dir .. "/bin")
  write(dir .. "/bin/ssh", "#!/bin/sh\ncat > " .. dir .. "/out.lua\n")
  sh("chmod +x " .. dir .. "/bin/ssh")
  write(dir .. "/envs", env_text)
  if seal_text ~= false then write(dir .. "/seal.lua", seal_text or SEAL) end
  return dir
end

local function run_script(dir)
  return sh("PATH=" .. dir .. "/bin:$PATH RIDDLE_ENVS=" .. dir .. "/envs RIDDLE_SEAL=" .. dir ..
    "/seal.lua sh tools/push_config.sh")
end

local tests = {}

function tests.test_writes_keys_and_seal()
  -- Cloudflare в ~/.envs может быть (чужие проекты), на устройство не пишется
  local dir = sandbox("export CF_WORKERS_AI_TOKEN=fake-cf.BBB\n" ..
    "CF_WORKERS_AI_ACCOUNT_ID=acc123\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, "скрипт завершился успешно: " .. out)
  local cfg = config.load(dir .. "/out.lua")
  t.eq(#cfg.providers, 0, "без GROQ_API_KEY поля providers нет")
  local f = assert(io.open(dir .. "/out.lua", "r"))
  local raw = f:read("*a")
  f:close()
  t.ok(not raw:find("providers", 1, true), "в config.lua нет providers")
  t.ok(not raw:find("fake-cf.BBB", 1, true) and not raw:find("acc123", 1, true), "ключи Cloudflare не ушли")
  t.ok(not raw:find("cf_", 1, true), "в config.lua нет полей cf_*")
  t.eq(cfg.gemini_key, "fake_gem_CCC")
  t.ok(raw:find("seal = {", 1, true), "в config.lua таблица seal: " .. raw)
  t.eq(cfg.seal.on, true, "печать — из файла печати")
  t.eq(cfg.seal.invalid, nil)
  t.eq(cfg.seal.key, true)
  t.eq(cfg.seal.minutes, 30)
  t.eq(cfg.seal.remember, true)
end

-- все поля печати доходят до устройства как есть (в т.ч. off и remember = false)
function tests.test_seal_fields_round_trip()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n",
    'seal = { key = true, minutes = 5, on_sleep = true, remember = false, off = true },\n')
  local out, ok = run_script(dir)
  t.ok(ok, out)
  local s = config.load(dir .. "/out.lua").seal
  t.eq(s.key, true)
  t.eq(s.minutes, 5)
  t.eq(s.on_sleep, true)
  t.eq(s.remember, false)
  t.eq(s.off, true)
  t.eq(s.on, false, "off — печати нет")
  t.ok(out:find("печать: снята", 1, true), out)
end

-- печать необязательна (владелец 2026-10-25): нет файла печати или в нём нет таблицы seal —
-- конфиг пишется БЕЗ полей печати, скрипт говорит «печать: нет»
function tests.test_missing_seal_file_writes_config_without_seal()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n", false)
  local out, ok = run_script(dir)
  t.ok(ok, "без файла печати — успех: " .. out)
  t.ok(out:find("печать: нет", 1, true), out)
  local cfg = config.load(dir .. "/out.lua")
  t.eq(cfg.gemini_key, "fake_gem_CCC")
  t.eq(cfg.seal.on, false, "печати нет")
  t.eq(cfg.seal.invalid, nil)
end

function tests.test_seal_file_without_seal_writes_no_seal_fields()
  for _, text in ipairs({ '', '-- пусто\n', 'password_variants = { "fakeword" },\n',
      'hints = { "только подсказка" },\n' }) do
    local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n", text)
    local out, ok = run_script(dir)
    t.ok(ok, "файл без слова — успех: " .. text .. " / " .. out)
    t.ok(out:find("печать: нет", 1, true), out)
    local f = assert(io.open(dir .. "/out.lua", "r"))
    local raw = f:read("*a")
    f:close()
    t.ok(not raw:find("seal", 1, true) and not raw:find("password_variants", 1, true) and
      not raw:find("hints", 1, true) and not raw:find("fakeword", 1, true), "в конфиге нет полей печати: " .. raw)
  end
end

-- файл печати есть, но не читается — отказ, а не «печать: нет» (иначе слово молча пропало бы)
function tests.test_unreadable_seal_file_writes_nothing_and_fails()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n")
  sh("chmod 000 " .. dir .. "/seal.lua")
  local out, ok = run_script(dir)
  sh("chmod 600 " .. dir .. "/seal.lua")
  t.ok(not ok, "нечитаемый файл печати — ошибка: " .. out)
  t.ok(not out:find("печать: нет", 1, true), out)
  t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло")
end

function tests.test_seal_file_with_seal_says_seal_present()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("печать: есть", 1, true), out)
end

-- битый файл печати (не Lua, seal нарушает правила config.lua) не уходит: на устройстве печать была бы закрыта
-- без выхода, а битый config.lua оставил бы дневник без ключей
function tests.test_bad_seal_file_writes_nothing_and_fails()
  for _, bad in ipairs({ 'seal = { key = true ', 'this is not lua', 'seal = { minutes = 5 },\n',
      'seal = { on_sleep = true },\n', 'seal = { key = true, minutes = 0 },\n',
      'seal = { key = true, minutes = 2.5 },\n', 'seal = { key = "yes" },\n', 'seal = true,\n' }) do
    local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n", bad)
    local out, ok = run_script(dir)
    t.ok(not ok, "битый файл печати — ошибка: " .. bad .. " / " .. out)
    t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло: " .. bad)
    t.ok(not out:find("fake_gem_CCC", 1, true), "ключ в выводе")
  end
end

-- OpenRouter убран (2026-10-25): OPENROUTER_API_KEY в ~/.envs не пишется в конфиг и не считается ключом
function tests.test_openrouter_key_is_not_written()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\nOPENROUTER_API_KEY=fake_or_DDD\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(not out:find("fake_or_DDD", 1, true), "ключ в выводе")
  t.ok(not out:find("openrouter", 1, true), out)
  local f = assert(io.open(dir .. "/out.lua", "r"))
  local raw = f:read("*a"); f:close()
  t.ok(not raw:find("fake_or_DDD", 1, true) and not raw:find("openrouter", 1, true), "в конфиг не ушёл")
  t.eq(config.load(dir .. "/out.lua").gemini_key, "fake_gem_CCC")
end

function tests.test_does_not_print_values()
  local dir = sandbox("GROQ_API_KEY=fake_groq_AAA\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out = run_script(dir)
  t.ok(not out:find("fake_groq_AAA", 1, true), "ключ в выводе")
  t.ok(not out:find("fake_gem_CCC", 1, true), "ключ в выводе")
  t.ok(out:find("providers: 1", 1, true), out)
end

-- GROQ_API_KEY -> запасной провайдер Groq в providers с after_legacy: идёт после Gemini
function tests.test_groq_key_writes_spare_provider()
  local dir = sandbox("GROQ_API_KEY=test-groq-key\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("providers: 1", 1, true), out)
  t.ok(not out:find("test-groq-key", 1, true), "ключ в выводе")
  local cfg = config.load(dir .. "/out.lua")
  t.eq(#cfg.providers, 1)
  local p = cfg.providers[1]
  t.eq(p.name, "groq")
  t.eq(p.url, "https://api.groq.com/openai/v1/chat/completions")
  t.eq(p.model, "qwen/qwen3.8-27b")
  t.eq(p.key, "test-groq-key")
  t.eq(p.after_legacy, true, "Groq — после Gemini")
  t.eq(p.max_input_chars, 10000, "Groq: урезанный запрос (ITPM 7000)")
  t.eq(cfg.gemini_key, "fake_gem_CCC")
end

-- BEATAPI_API_KEY -> второй запасной провайдер после Groq; max_tokens 400 (на 200 ответ обрезается)
function tests.test_beatapi_key_writes_provider_after_groq()
  local dir = sandbox("GROQ_API_KEY=test-groq-key\nBEATAPI_API_KEY=test-beat-key\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("providers: 2", 1, true), out)
  t.ok(not out:find("test-beat-key", 1, true), "ключ в выводе")
  local cfg = config.load(dir .. "/out.lua")
  t.eq(#cfg.providers, 2)
  t.eq(cfg.providers[1].name, "groq", "Groq первым")
  local p = cfg.providers[2]
  t.eq(p.name, "beatapi")
  t.eq(p.url, "https://api.beatapi.io/v1/chat/completions")
  t.eq(p.model, "deepseek-v4.1-flash-free")
  t.eq(p.key, "test-beat-key")
  t.eq(p.after_legacy, true, "BeatAPI — после Gemini")
  t.eq(p.max_tokens, 400)
  t.eq(cfg.providers[1].max_tokens, nil, "у Groq max_tokens не задан")
end

function tests.test_beatapi_alone_without_groq_is_still_written()
  local dir = sandbox("BEATAPI_API_KEY=test-beat-key\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("providers: 1", 1, true), out)
  local cfg = config.load(dir .. "/out.lua")
  t.eq(#cfg.providers, 1)
  t.eq(cfg.providers[1].name, "beatapi")
end

function tests.test_empty_beatapi_key_is_not_written()
  local dir = sandbox("BEATAPI_API_KEY=\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("providers: 0", 1, true), out)
  t.eq(#config.load(dir .. "/out.lua").providers, 0)
end

-- ключ не того формата: отказ всего скрипта, а не молча выпавший провайдер; значение не печатается
local function assert_bad_key_fails(env_text, var)
  local dir = sandbox(env_text .. "GEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(not ok, var .. ": ожидался отказ скрипта: " .. out)
  t.eq(io.open(dir .. "/out.lua", "r"), nil, var .. ": на устройство ничего не ушло")
  t.ok(out:find(var, 1, true), "сообщение называет переменную: " .. out)
  t.ok(out:find("ничего не записано", 1, true), "понятное сообщение: " .. out)
  t.ok(not out:find("a b", 1, true) and not out:find("fake_gem_CCC", 1, true), "значение в выводе: " .. out)
end

function tests.test_bad_beatapi_key_fails_whole_script()
  assert_bad_key_fails("BEATAPI_API_KEY='a b'\n", "BEATAPI_API_KEY")
end

function tests.test_bad_notion_token_fails_whole_script()
  assert_bad_key_fails("NOTION_DIARY_API='a b'\n", "NOTION_DIARY_API")
end

function tests.test_bad_gemini_key_fails_whole_script()
  assert_bad_key_fails("GEMINI_API_KEY_BAD='a b'\n", "GEMINI_API_KEY_BAD")
  assert_bad_key_fails("GEMINI_API_KEYS='gk1,a b'\n", "GEMINI_API_KEYS")
end

-- NOTION_DIARY_API -> notion_token; значение не печатается
function tests.test_notion_token_written()
  local dir = sandbox("NOTION_DIARY_API=ntn_fakeNOTION777\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("notion_token: есть", 1, true), out)
  t.ok(not out:find("fakeNOTION777", 1, true), "токен в выводе")
  local cfg = config.load(dir .. "/out.lua")
  t.eq(cfg.notion_token, "ntn_fakeNOTION777")
  t.eq(cfg.gemini_key, "fake_gem_CCC")
end

function tests.test_no_notion_token_prints_net()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("notion_token: нет", 1, true), out)
  t.eq(config.load(dir .. "/out.lua").notion_token, nil)
end

-- дневник без ключа модели не отвечает: конфиг только с токеном Notion не пишем
function tests.test_only_notion_token_writes_nothing_and_fails()
  local dir = sandbox("NOTION_DIARY_API=ntn_only\n")
  local _, ok = run_script(dir)
  t.ok(not ok, "Notion не ключ цепочки — ошибка")
  t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло")
end

-- значения «пройдено» для сверки советов (Notion 8152) пишутся всегда: слова данных живут в конфиге, не в плагине.
-- «Брошено» — тоже пройдено: не советовать (владелец 2026-10-27), спросить о брошенном можно — знание уходит модели целиком
function tests.test_watched_values_written_by_default()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  local v = config.load(dir .. "/out.lua").watched_values
  t.eq(#v, 3); t.eq(v[1], "Просмотрено"); t.eq(v[2], "Прочитано"); t.eq(v[3], "Брошено")
  t.ok(out:find("watched_values: Просмотрено, Прочитано, Брошено", 1, true), out)
end

-- RIDDLE_TASKS_SOURCE -> tasks_source (название базы задач у владельца не стирается заливкой ключей)
function tests.test_tasks_source_from_env_written()
  local dir = sandbox("RIDDLE_TASKS_SOURCE='Мои задачи (2026)'\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("tasks_source: есть", 1, true), out)
  t.ok(not out:find("Мои задачи", 1, true), "значение не печатается: " .. out)
  local cfg = config.load(dir .. "/out.lua")
  t.eq(cfg.tasks_source, "Мои задачи (2026)")
  t.eq(cfg.gemini_key, "fake_gem_CCC")
end

function tests.test_no_tasks_source_not_written()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("tasks_source: нет", 1, true), out)
  local f = assert(io.open(dir .. "/out.lua", "r"))
  local raw = f:read("*a")
  f:close()
  t.ok(not raw:find("tasks_source", 1, true), raw)
end

-- значение встаёт в строку Lua в кавычках: кавычка, обратная косая или перевод строки — отказ всего скрипта
function tests.test_tasks_source_with_quote_rejected()
  for _, v in ipairs({ "'Мои \"дела\"'", "'C:\\дела'", "'две\nстроки'", "'конец\r'" }) do
    local dir = sandbox("RIDDLE_TASKS_SOURCE=" .. v .. "\nGEMINI_API_KEY=fake_gem_CCC\n")
    local out, ok = run_script(dir)
    t.ok(not ok, "ожидался отказ: " .. v .. " / " .. out)
    t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло: " .. v)
    t.ok(out:find("RIDDLE_TASKS_SOURCE", 1, true), out)
    t.ok(out:find("ничего не записано", 1, true), out)
  end
end

function tests.test_no_groq_key_prints_providers_zero()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("providers: 0", 1, true), out)
  t.eq(#config.load(dir .. "/out.lua").providers, 0)
end

function tests.test_bad_groq_key_fails_whole_script()
  assert_bad_key_fails("GROQ_API_KEY='a b'\n", "GROQ_API_KEY")
end

-- OpenRouter больше не ключ цепочки: конфиг только с ним не пишется
function tests.test_only_openrouter_key_writes_nothing_and_fails()
  local dir = sandbox("OPENROUTER_API_KEY=only_or_token\n")
  local _, ok = run_script(dir)
  t.ok(not ok, "OpenRouter не ключ цепочки — ошибка")
  t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло")
end

function tests.test_only_cloudflare_keys_write_nothing_and_fail()
  local dir = sandbox("CF_WORKERS_AI_TOKEN=only_cf_token\nCF_WORKERS_AI_ACCOUNT_ID=acc123\n")
  local _, ok = run_script(dir)
  t.ok(not ok, "Cloudflare не ключ цепочки — ошибка")
  t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло")
end

function tests.test_only_groq_key_writes_nothing_and_fails()
  local dir = sandbox("GROQ_API_KEY=only_groq_key\n")
  local _, ok = run_script(dir)
  t.ok(not ok, "Groq не ключ цепочки — ошибка")
  t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло")
end

function tests.test_no_keys_writes_nothing_and_fails()
  local dir = sandbox("FOO=1\n")
  local _, ok = run_script(dir)
  t.ok(not ok, "без ключей — ошибка")
  local f = io.open(dir .. "/out.lua", "r")
  t.eq(f, nil, "на устройство ничего не ушло")
end

-- GEMINI_API_KEY, GEMINI_API_KEY_* и GEMINI_API_KEYS (через запятую) -> gemini_keys без дублей
function tests.test_collects_all_gemini_keys()
  local dir = sandbox("GEMINI_API_KEY=gk0\nGEMINI_API_KEY_2=gk2\nexport GEMINI_API_KEY_B=gk3\n" ..
    "GEMINI_API_KEYS=gk4,,gk5,gk2\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  local cfg = config.load(dir .. "/out.lua")
  t.eq(cfg.gemini_key, "gk0", "старое поле — для плагина до деплоя")
  t.eq(table.concat(cfg.gemini_keys, ","), "gk0,gk2,gk3,gk4,gk5", "все ключи, без дублей и пустых")
  t.ok(out:find("gemini_keys: 5", 1, true), out)
  t.ok(not out:find("gk%d"), "значение ключа в выводе: " .. out)
end

function tests.test_only_gemini_keys_list_is_enough()
  local dir = sandbox("GEMINI_API_KEYS=gk4,gk5\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  local cfg = config.load(dir .. "/out.lua")
  t.eq(cfg.gemini_key, "gk4")
  t.eq(table.concat(cfg.gemini_keys, ","), "gk4,gk5")
end

-- gemini-proxy: GEMINI_PROXY_URL + GEMINI_PROXY_AUTH_TOKEN -> первая запись providers (до прямого Gemini);
-- в выводе только «есть/нет», значения не печатаются
function tests.test_gemini_proxy_from_env()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\nGEMINI_PROXY_URL=https://proxy.fake.test/\n" ..
    "GEMINI_PROXY_AUTH_TOKEN=fake_proxy_tok_DDD\nGROQ_API_KEY=fake_groq_EEE\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("gemini-proxy: есть", 1, true), out)
  t.ok(not out:find("fake_proxy_tok_DDD", 1, true) and not out:find("proxy.fake.test", 1, true), out)
  local cfg = config.load(dir .. "/out.lua")
  local p = cfg.providers[1]
  t.eq(p.name, "gemini-proxy")
  t.eq(p.format, "gemini")
  t.eq(p.url, "https://proxy.fake.test", "без косой в конце")
  t.eq(p.model, "gemini-3.5-flash-lite")
  t.eq(p.proxy_auth, "fake_proxy_tok_DDD")
  t.eq(p.after_legacy, nil, "первым, до прямого Gemini")
  t.eq(p.max_input_chars, nil, "fit-лимит как у прямого Gemini — нет")
  t.eq(cfg.providers[2].name, "groq")
  t.eq(cfg.gemini_key, "fake_gem_CCC")
end

function tests.test_gemini_proxy_absent_without_both_vars()
  for _, env in ipairs({ "GEMINI_API_KEY=fake_gem_CCC\n",
                         "GEMINI_API_KEY=fake_gem_CCC\nGEMINI_PROXY_URL=https://proxy.fake.test\n",
                         "GEMINI_API_KEY=fake_gem_CCC\nGEMINI_PROXY_AUTH_TOKEN=fake_proxy_tok_DDD\n" }) do
    local dir = sandbox(env)
    local out, ok = run_script(dir)
    t.ok(ok, out)
    t.ok(out:find("gemini-proxy: нет", 1, true), out)
    t.eq(#config.load(dir .. "/out.lua").providers, 0, env)
  end
end

-- адрес не на https:// — отказ всего скрипта (config.lua такую запись молча выкинул бы)
function tests.test_gemini_proxy_url_must_be_https()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\nGEMINI_PROXY_URL=http://proxy.fake.test\n" ..
    "GEMINI_PROXY_AUTH_TOKEN=fake_proxy_tok_DDD\n")
  local out, ok = run_script(dir)
  t.ok(not ok, out)
  t.ok(not out:find("proxy.fake.test", 1, true), "адрес не печатается: " .. out)
end

-- whose: RIDDLE_WHOSE из ~/.envs; нет — строка Kindle владельца «Методов» (спека 2026-10-31, пункт 10)
function tests.test_whose_default_methods_line()
  local dir = sandbox("GEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.ok(out:find("whose: есть", 1, true), out)
  t.eq(config.load(dir .. "/out.lua").whose, "Том Реддл из «Методов рационального мышления»")
end

function tests.test_whose_from_env()
  local dir = sandbox("RIDDLE_WHOSE='Гермиона Грейнджер'\nGEMINI_API_KEY=fake_gem_CCC\n")
  local out, ok = run_script(dir)
  t.ok(ok, out)
  t.eq(config.load(dir .. "/out.lua").whose, "Гермиона Грейнджер")
  t.ok(not out:find("Гермиона", 1, true), "значение не печатается: " .. out)
end

function tests.test_whose_quote_refused()
  for _, v in ipairs({ "'Мой \"дневник\"'", "'C:\\x'", "'две\nстроки'" }) do
    local dir = sandbox("RIDDLE_WHOSE=" .. v .. "\nGEMINI_API_KEY=fake_gem_CCC\n")
    local out, ok = run_script(dir)
    t.ok(not ok, "ожидался отказ: " .. v .. " / " .. out)
    t.eq(io.open(dir .. "/out.lua", "r"), nil, "на устройство ничего не ушло: " .. v)
    t.ok(out:find("RIDDLE_WHOSE", 1, true), out)
  end
end

t.run(tests)
