# riddle-diary MVP — план реализации

> **Печать:** заветное слово (`password_variants`, `hints`, `hint_every`, `seal.matches`) в этом плане — история:
> слово заменено графическим ключом, см. spec 2026-11-20 (`docs/superpowers/specs/2026-11-20-seal-key-design.md`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Плагин KOReader на Kindle PW2 — магический дневник одной хозяйки: письмо пальцем, чернила растворяются без мерцания, печать с заветным словом из конфига, ответы бесплатной vision-LLM < 5 с, память в SQLite, лор, автозапуск при включении.

**Architecture:** Чистая логика (печать, промпты, цепочка LLM, память, контроллер) — отдельные Lua-модули без зависимостей от UI, тестируются на Mac через luajit. Виджет из спайка B (`riddle_diarywidget.lua`) рисует, растворяет, снимает PNG и зовёт контроллер. HTTP — блокирующий вызов в процессе KOReader (без подпроцессов: устройство разгружаем), один запрос на запись, цепочка Gemini (по ключу) → запасные из `providers` конфига: Groq, BeatAPI (OpenRouter убран 2026-10-25), все через OpenAI-совместимый `chat/completions`.

**Tech Stack:** LuaJIT (KOReader v2025.08), `ssl.https`/`socket` (luasocket+luasec), `mime.b64`, `dkjson` (чистый Lua, есть на устройстве), `lua-ljsqlite3` (FFI, есть на устройстве), KOReader UIManager/Screen/BlitBuffer.

**Spec:** `docs/superpowers/specs/2026-10-22-riddle-diary-design.md`

## Global Constraints

- Устройство: Kindle PW2, 758×1024, KOReader v2025.08 в `/mnt/us/koreader`, доступ `ssh kindle` / `scp kindle:`; данные дневника — `/mnt/us/riddle/`.
- Ввод только пальцем; никакой клавиатуры и UI KOReader в режиме дневника.
- Только русский; дневник о себе — женский род; обращение «хозяйка».
- Бесплатные модели (`llm.providers`): 1) Gemini `gemini-3.5-flash-lite` `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions` — по провайдеру на каждый ключ (`gemini_key`, затем `gemini_keys`, без дублей); 2) запасные — записи `providers` с `after_legacy = true`: Groq, затем BeatAPI `deepseek-v4.1-flash-free` `https://api.beatapi.io/v1/chat/completions` (`max_tokens` провайдера, у BeatAPI 400; по умолчанию 200); пишет `tools/push_config.sh` при `GROQ_API_KEY` / `BEATAPI_API_KEY`. OpenRouter убран (решение владельца 2026-10-25), `openrouter_key` в старом конфиге игнорируется. Хосты для прогрева DNS — `app.hosts(cfg)`: Gemini + хосты `providers`.
- Каждый запрос шлёт заголовок `User-Agent: riddle-diary/1.0`.
- Бюджет цепочки: 8 с (`app.BUDGET_S`); таймаут провайдера = `min(4, остаток бюджета)`, если за ним есть провайдер другого хоста, иначе весь остаток; транспортный сбой на ключе Gemini — остальные ключи пропускаются; бюджет кончился → фраза из `texts.fail_slow`. Без stream.
- Картинка: ширина ~380 px (½ экрана), серый 8-бит PNG, перо 3–4 px до уменьшения; удаляется сразу после ответа модели.
- Исчезание: штрих начинает растворяться через **3 с** (`sink_delay_s = 3`), без мерцания и вспышек.
- Тишина перед отправкой: 2.5 с (`idle_s = 2.5`).
- Заветное слово и его написания — из конфига (`password_variants`), регистр не важен, Левенштейн ≤ 2 после нормализации; LLM слово не видит никогда.
- Подсказка (стих из конфига, `hints`, по кругу) на каждую 3-ю неудачную разобранную попытку (`hint_every`); счётчик живёт, пока печать закрыта.
- Сон экрана и перезапуск закрывают печать.
- Сессия памяти = 4 ч от последней записи.
- Ключи, слово и подсказки — только в `/mnt/us/riddle/config.lua` (не в git); в репо — `config.example.lua` с `your_token_here`.
- Секреты не печатать в логи, отчёты, коммиты. Перед коммитом — grep на `gsk_|sk-[a-z]+-|Bearer [A-Za-z0-9]|BEGIN .* PRIVATE KEY`.
- Тексты приглашения и приветствий — дословно из спеки, раздел «Тексты»; подсказок в коде нет — они в конфиге.

## Review Focus

1. Модель вернула не-JSON, JSON в ```-обёртке, пустой `reply` или `read` латиницей-двойниками → разбор терпим, иначе следующий провайдер; на экране никогда нет технического текста. Тест — Task 2 `test_parse_*`.
2. Слово написано с пробелом/переносом, смесью латиницы и кириллицы, с лишней буквой → засчитывается; слово внутри фразы → тоже засчитывается. Тест — Task 1 `test_match_*`.
3. Wi‑Fi пропал / DNS не резолвится → фраза из `texts.fail_offline`; провайдер завис → из `texts.fail_slow` в пределах бюджета; без падения. Тест — Task 4 `test_all_providers_fail_closed`/`_open`, `test_fail_reason_picks_its_pool_open_and_locked`, Task 2 `test_budget_exhausted_stops_chain`.
4. Kindle засыпает посреди запроса или проявления ответа → после пробуждения печать закрыта, страница чистая, приглашение на месте, без падения. Проверка — Task 5 шаг на устройстве.
5. Хозяйка исписала всю страницу → PNG ≤ 15 КБ, ответ пришёл в пределах бюджета. Проверка — Task 5 шаг на устройстве.

---

## Порядок и параллельность

Параллельно сразу: **Task 1, Task 2, Task 3** (новые чистые модули, разные файлы), **Task 6** (виджет на устройстве), **Task 8 шаги 1–2** (опись, только чтение). Затем Task 4 → Task 5 → Task 7 → Task 9. Task 6 и Task 5 правят один файл виджета — строго последовательно. Устройство одно: деплой/перезапуски KOReader в один момент делает только один исполнитель (Task 6 до Task 5).

## Файлы

```
plugin/riddlediary.koplugin/
  main.lua                    # регистрация плагина, автооткрытие (из спайка)
  riddle_diarywidget.lua      # экран: перо, растворение, PNG, проявление (из спайка)
  riddle/texts.lua            # все тексты из спеки
  riddle/seal.lua             # печать: нормализация, сравнение, подсказки
  riddle/prompt.lua           # сборка messages для закрытой/открытой печати и пересказа
  riddle/llm.lua              # запрос/разбор OpenAI-формата, цепочка с бюджетом
  riddle/memory.lua           # SQLite: сессии, записи, пересказы, лор
  riddle/controller.lua       # склейка: PNG → LLM → печать → память → текст для экрана
  riddle/http.lua             # адаптер ssl.https с таймаутом (только устройство)
  riddle/config.lua           # загрузка /mnt/us/riddle/config.lua
config.example.lua
lore.md
tests/run.sh, tests/*_spec.lua, tests/vendor/{dkjson.lua,lua-ljsqlite3/}
tools/deploy.sh, tools/push_config.sh, tools/lore_push.sh, tools/install_autostart.sh, tools/kindle_inventory.sh
system/riddle-koreader.conf
```

Тесты: `tests/run.sh` гоняет каждый `tests/*_spec.lua` через `luajit` с `package.path` на `plugin/riddlediary.koplugin/?.lua;tests/vendor/?.lua`. Каждый spec — набор `local function test_*()` + общий мини-раннер `tests/t.lua` (`t.eq(a,b,msg)`, `t.ok(v,msg)`, `t.run(tbl)`; выход 1 при провале). Без busted.

---

### Task 1: Печать и тексты + тестовый каркас

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/texts.lua`, `plugin/riddlediary.koplugin/riddle/seal.lua`
- Create: `tests/run.sh`, `tests/t.lua`, `tests/seal_spec.lua`, `tests/vendor/dkjson.lua` (копия `/mnt/us/koreader/common/dkjson.lua` с устройства)

**Interfaces:**
- Produces:
  - `texts.invitation : string` = «Кто касается моих страниц?»; `texts.welcomes : {string}` (12 из спеки); `texts.hints` нет — подсказки из конфига; `texts.sleepy : {string}` (≥ 4 фразы вида «Чернила густеют… вернись ко мне чуть позже»); `texts.unreadable : {string}` (≥ 4 фразы вида «Чернила расплылись… напиши ещё раз, медленнее»).
  - `seal.normalize(s: string, latin?: boolean) -> string` — нижний регистр, удаление пробелов/переносов/пунктуации; по умолчанию латинские двойники → кириллица (`a e o p c x y k m t b h` → `а е о р с х у к м т в н`), при `latin=true` — наоборот, кириллические двойники → латиница.
  - `seal.matches(read: string, variants: {string}) -> boolean`
  - `seal.new(variants: {string}, hint_every: integer, random?, hints: {string}) -> Seal` (`hints` — из `cfg.hints`)
  - `Seal:feed(read: string) -> {kind="unlock"|"refuse"|"hint"|"unreadable", hint?: string, welcome?: string}`; `Seal:lock()`; `Seal.open : boolean`

- [ ] **Step 1: Каркас тестов.** `tests/t.lua`, `tests/run.sh` (exit≠0 при любом провале), `scp kindle:/mnt/us/koreader/common/dkjson.lua tests/vendor/`. Run: `tests/run.sh` → `0 specs, OK`.
- [ ] **Step 2: Тесты печати** в `tests/seal_spec.lua`:
  - `V` — слово-фикстура тестов (не настоящее слово): `V = {"salandusa","шаландуша","шаланда"}`
  - `test_match_exact`: `matches("Salandusa", V)` true
  - `test_match_case_spaces`: `"SALAN dusa"`, `"Шалан\nдуша"` → true
  - `test_match_homoglyphs`: `"Sаlаndusа"` (кириллические «а») → true; `"Шaлaндушa"` (латинские «a») → true
  - `test_match_typos`: `"Salandsa"`, `"Salendusa"`, `"Шаландушша"` → true; `"Шасточка"`, `"Salender ois"` → false
  - `test_match_in_phrase`: `"Моё слово — Salandusa!"`, `"шаланда плывёт к берегу"` → true (поиск по окну длины варианта ±2)
  - `test_unreadable`: `feed("?")` → kind `unreadable`, счётчик не растёт
  - `test_hint_every_third`: три `feed("кто ты")` → `refuse, refuse, hint` с `hint == hints[1]` (`hints` из конфига); ещё три → вторая подсказка; дальше — по кругу; пустой `hints` → только `refuse`
  - `test_unlock`: `feed("Salandusa")` → `unlock`, `welcome ∈ texts.welcomes`, `open == true`; дальнейший `feed` при открытой → `nil` (не дело печати)
  - `test_lock_resets`: 2 неудачи → `lock()` → 1 неудача → `refuse` (не `hint`)
  - `test_texts_verbatim`: `#texts.welcomes == 12`, `texts.hints == nil`, `texts.invitation == "Кто касается моих страниц?"`
- [ ] **Step 3:** Run `tests/run.sh` → FAIL (модулей нет).
- [ ] **Step 4:** Реализовать `texts.lua` (дословно из спеки) и `seal.lua`. Совпадение: нормализовать `read` двумя способами (кириллица / латиница), для каждого варианта скользящее окно длиной `#variant-2..#variant+2` по нормализованной строке (UTF-8 по кодпойнтам), Левенштейн ≤ 2.
- [ ] **Step 5:** Run `tests/run.sh` → все PASS.
- [ ] **Step 6:** Commit `feat(seal): печать, подсказки, тексты`.

### Task 2: Промпты и цепочка LLM

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/prompt.lua`, `plugin/riddlediary.koplugin/riddle/llm.lua`
- Create: `tests/prompt_spec.lua`, `tests/llm_spec.lua`

**Interfaces:**
- Consumes: `dkjson` (`require("dkjson")`).
- Produces:
  - `prompt.locked(png_b64: string) -> messages` — системный промпт закрытой печати: дневник прочитывает запись и отвечает уклончивым отказом, не раскрывая ничего о себе, хозяйке, памяти, лоре; формат ответа строго `{"read":"...","reply":"..."}`; не разобрал — `"read":"?"`; не выдумывать текст. Ни слова-пароля, ни лора, ни памяти в нём нет.
  - `prompt.open(png_b64, ctx) -> messages`, `ctx = {lore: string, summaries: {string}, recent: {{role="owner"|"diary", text}}}` — персона из спеки (хранит её записи и тайны, тёплая, загадочная, 1–3 предложения, женский род, «хозяйка»), лор, пересказы прошлых сессий, последние реплики как диалог; тот же формат JSON.
  - `prompt.summarize(entries: {{role,text}}) -> messages` — свернуть сессию в 2–3 предложения от лица дневника; ответ — просто текст.
  - `llm.providers(cfg) -> {Provider}`; `Provider = {name, url, model, headers, key?}`; порядок: providers без `after_legacy` → gemini по ключу → providers с `after_legacy`; провайдер без ключа пропускается.
  - `llm.build(provider, messages) -> url, headers, body_json` (OpenAI `chat/completions`, `temperature=0.8`, `max_tokens=200`, без `response_format`).
  - `llm.parse(status: integer, body: string, want_json: boolean) -> result|nil, err` где `result = {read, reply}` или `{text}`.
  - `llm.call(providers, messages, opts) -> result|nil, err`, `opts = {post: fn(url, headers, body, timeout_s) -> status, body | nil, err; now: fn() -> seconds; budget_s (по умолчанию 5, на устройстве `app.BUDGET_S` = 8); want_json}`.
- [ ] **Step 1: Тесты** `tests/prompt_spec.lua`:
  - `test_locked_has_no_secrets`: в сериализованных messages нет заветного слова, текста лора, пересказов
  - `test_open_has_context`: lore/summaries/recent присутствуют, картинка — `image_url` `data:image/png;base64,`
  - `test_open_limits`: recent обрезается до последних 12 реплик
- [ ] **Step 2: Тесты** `tests/llm_spec.lua` (fake `post`/`now`):
  - `test_parse_plain_json`, `test_parse_fenced_json` (```json … ```), `test_parse_json_inside_text` → `{read, reply}`
  - `test_parse_empty_reply` → nil, err; `test_parse_http_429` / `500` → nil, err
  - `test_parse_latin_homoglyph_reply`: `reply` с латиницей внутри русских слов → исправлено на кириллицу
  - `test_fallback_on_429`: первый 429 → второй 200 → результат второго, первый вызван 1 раз; `test_gemini_429_falls_to_openrouter`
  - `test_budget_remainder_goes_to_next_provider`, `test_budget_exhausted_stops_chain`: первый «висит» до потолка 4 с, следующий получает остаток; бюджет исчерпан → nil, `"budget"`
  - `test_user_agent`: каждый вызов `post` содержит `User-Agent: riddle-diary/1.0`
  - `test_providers_openrouter_follows_gemini`, `test_openrouter_alone_without_gemini_key`, `test_empty_gemini_key_is_not_a_key`: провайдер без ключа пропускается
- [ ] **Step 3:** Run `tests/run.sh` → FAIL.
- [ ] **Step 4:** Реализовать `prompt.lua`, `llm.lua`. Исправление двойников в `reply`: заменить латинскую букву на кириллическую, только если соседи — кириллица.
- [ ] **Step 5:** Run `tests/run.sh` → PASS (живые вызовы — в Task 5 на устройстве).
- [ ] **Step 6:** Commit `feat(llm): промпты и цепочка Gemini→OpenRouter с бюджетом`.

### Task 3: Память и лор (SQLite)

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/memory.lua`, `tests/memory_spec.lua`, `tests/vendor/lua-ljsqlite3/` (копия с устройства `/mnt/us/koreader/common/lua-ljsqlite3/`), `lore.md`, `tools/lore_push.sh`

**Interfaces:**
- Consumes: `require("lua-ljsqlite3/init")` (как в `plugins/statistics.koplugin/main.lua:17`).
- Produces:
  - `memory.open(path: string) -> Memory` (создаёт схему: `sessions(id INTEGER PK, started INT, last_ts INT, summary TEXT)`, `entries(id INTEGER PK, session_id INT, ts INT, role TEXT, text TEXT)`, `lore(section TEXT PK, text TEXT, mtime INT)`)
  - `Memory:session(now: integer) -> session_id, unsummarized_id|nil` — продолжает сессию, если `now - last_ts ≤ 4*3600`, иначе новая; второе значение — id прошлой сессии без пересказа, если есть
  - `Memory:add(session_id, role, text, now)`; `Memory:recent(session_id, n) -> {{role,text}}` (по времени, старые первыми)
  - `Memory:entries(session_id) -> {{role,text}}`; `Memory:set_summary(session_id, text)`; `Memory:summaries(limit) -> {string}` (новые первыми, limit 5)
  - `Memory:import_lore(md_text: string, mtime: integer)` — разделы по заголовкам `## `; `Memory:lore_mtime() -> integer|nil`; `Memory:lore_text(max_chars) -> string` (по умолчанию 10000 знаков — `DEFAULT_LORE_CAP`, считаются кодпойнты UTF-8, обрезка с конца)
  - `Memory:close()`
- [ ] **Step 1:** Скопировать `lua-ljsqlite3` с устройства в `tests/vendor/`. Проверить, что на Mac `luajit -e 'require("lua-ljsqlite3/init")'` грузит системную `libsqlite3.dylib`; если нет — в `tests/run.sh` выставить `DYLD_LIBRARY_PATH` на `$(brew --prefix sqlite)/lib`.
- [ ] **Step 2: Тесты** `tests/memory_spec.lua` (БД в `os.tmpname()`):
  - `test_session_continues_within_4h`: `session(0)`, `add`, `session(4*3600)` → тот же id
  - `test_session_new_after_4h`: `session(4*3600+1)` → новый id и `unsummarized_id` = старый
  - `test_recent_order_and_limit`: 15 записей → `recent(id,12)` 12 штук, последняя — самая новая
  - `test_summaries`: `set_summary` → `summaries(5)` содержит текст; `session()` больше не отдаёт эту сессию как `unsummarized`
  - `test_lore_import_replace`: импорт `## Мир\nА\n## Герои\nБ` → `lore_text()` содержит «А» и «Б»; повторный импорт без «Герои» → «Б» исчезло
  - `test_lore_cap_counts_characters_not_bytes`: лор с 15000 «я» → `lore_text()` ровно 10000 знаков, первый раздел цел
  - `test_persist`: `close()` → `open()` того же пути → записи на месте
- [ ] **Step 3:** Run → FAIL. **Step 4:** Реализовать `memory.lua`. **Step 5:** Run → PASS.
- [ ] **Step 6:** `lore.md` — шаблон с разделами `## Что дневник должен сказать` (первым: обрезка идёт с конца), `## Хозяйка`, `## События`, `## Мир` и пометкой «заполняет владелец»; `tools/lore_push.sh` — `scp lore.md kindle:/mnt/us/riddle/lore.md` (импорт делает контроллер по mtime, Task 4).
- [ ] **Step 7:** Commit `feat(memory): SQLite-память, сессии 4 ч, лор`.

### Task 4: Контроллер

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/controller.lua`, `tests/controller_spec.lua`

**Interfaces:**
- Consumes: Task 1 `seal`, `texts`; Task 2 `prompt`, `llm`; Task 3 `memory`.
- Produces:
  - `controller.new(deps) -> Controller`, `deps = {cfg, memory, llm_call: fn(messages, want_json) -> result|nil, err, read_file: fn(path) -> bytes, b64: fn(bytes) -> string, remove: fn(path), now: fn() -> integer, lore_path: string, file_mtime: fn(path) -> integer|nil, random: fn(n) -> integer}`
  - `Controller:on_page(png_path: string) -> text: string` — главный путь; **всегда** удаляет PNG и **всегда** возвращает непустой текст для экрана
  - `Controller:on_unlocked_followup()` — после показа приветствия: импорт лора при сменившемся mtime, пересказ прошлой сессии без пересказа (один LLM-вызов без картинки; провал — молча пропустить)
  - `Controller:on_sleep()` — `seal:lock()`
  - `Controller.seal_open : boolean` (чтение)
- [ ] **Step 1: Тесты** (все зависимости — фейки):
  - `test_locked_refuse`: llm → `{read="кто ты", reply="Мои страницы молчат…"}` → текст = reply модели, в память ничего не пишется
  - `test_locked_hint_on_third`: третья неудача → текст = `cfg.hints[1]`
  - `test_unlock_no_llm_reply`: llm → `{read="Salandusa", reply="…"}` → текст ∈ `texts.welcomes`, reply модели не показан, `seal_open == true`
  - `test_open_writes_memory`: открыта; llm → `{read="Мне грустно", reply="Я с тобой"}` → в памяти 2 записи (`owner`, `diary`), в `prompt.open` переданы recent/summaries/lore
  - `test_unreadable`: `read="?"` → текст ∈ `texts.unreadable`, память не тронута
  - `test_all_providers_fail`: llm → nil, `"budget"` → текст ∈ `texts.sleepy`
  - `test_png_always_removed`: во всех тестах выше `remove` вызван ровно 1 раз с путём PNG, в т.ч. при ошибке
  - `test_sleep_locks`: открыта → `on_sleep()` → следующий `on_page` идёт через `prompt.locked`
  - `test_followup_lore_and_summary`: новая сессия с `unsummarized_id` → вызван summarize, `set_summary`; mtime лора изменился → `import_lore`
- [ ] **Step 2:** Run → FAIL. **Step 3:** Реализовать. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(controller): склейка печати, LLM и памяти`.

### Task 5: Сборка на устройстве — сеть, конфиг, PNG, сон

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/http.lua`, `plugin/riddlediary.koplugin/riddle/config.lua`, `config.example.lua`, `tools/push_config.sh`, `tools/deploy.sh` (перенос `spike/deploy.sh`)
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua` (после Task 6), `plugin/riddlediary.koplugin/main.lua`

**Interfaces:**
- Consumes: Task 4 `controller`.
- Produces:
  - `http.post(url, headers, body, timeout_s) -> status, body | nil, err` через `ssl.https` + `ltn12`, таймаут на сокет.
  - `config.load(path="/mnt/us/riddle/config.lua") -> {gemini_key, gemini_keys, openrouter_key, password_variants, hints, hint_every=3}`; нет файла → нет провайдеров и слова, дневник отвечает фразами сбоя, не падает.
  - `tools/push_config.sh` — читает `~/.envs` (`GEMINI_API_KEY`, `GEMINI_API_KEY_*`, `GEMINI_API_KEYS`, `OPENROUTER_API_KEY`), слово и подсказки — из файла печати `RIDDLE_SEAL`, пишет `config.lua` на устройство через `ssh kindle 'cat > …'` из stdin, права 600; значения не выводит.
- [ ] **Step 0:** Связка: `controller.new{ llm_call = function(m, want_json) return llm.call(llm.providers(cfg), m, {post = http.post, now = <монотонное время KOReader>, budget_s = app.BUDGET_S, want_json = want_json}) end, b64 = require("mime").b64, … }`.
- [ ] **Step 1:** Виджет: приглашение = `texts.invitation`; перо 3–4 px; `saveSample` → серый 8-бит PNG шириной ~380 px (кроп по чернилам + ½), путь `/mnt/us/riddle/samples/<ts>.png`; после PNG — `controller:on_page(path)` → `revealAnswer(text)`; при `kind=unlock` после приветствия — `on_unlocked_followup()`.
- [ ] **Step 2:** Сон: в `main.lua` обработчики `onSuspend` (→ `controller:on_sleep()`, сброс страницы, отмена таймеров) и `onResume` (чистая страница + приглашение). Автосон KOReader (`autosuspend.koplugin`) на время дневника — 30 мин бездействия (спека, «Запуск и выход»); касания дневника сбрасывают таймер автосна (`UIManager:event_hook` / `Device.input` активность — проверить, что сырые касания через подменённый `feedEvent` его сбрасывают, иначе вызывать сброс вручную).
- [ ] **Step 3:** Удалить из виджета тестовый харнес спайка (`testWrite`, `synthStrokes`, `testCycleDone`, `instrumentRefresh`, `logRefresh`, `testShot`, `maybeStartTest`, `testBase64`) в отдельный `riddle/devtest.lua`, грузится только при `/mnt/us/riddle/devmode`.
- [ ] **Step 4:** `tools/push_config.sh` → `ssh kindle 'ls -l /mnt/us/riddle/config.lua'` → `-rw-------`. Diff на секреты пустой.
- [ ] **Step 5: Живой прогон на устройстве** (devtest скармливает синтетические штрихи — образцы `tools/samples/*.png` вместо снятого PNG через `devmode`): лог `/mnt/us/koreader/crash.log` с `riddle:` строками показывает провайдера и время; ожидается: закрытая печать → отказ ≤ 5 с; образец с заветным словом (сгенерировать `tools/gen_samples.py`) → приветствие мгновенно; открытая → ответ с учётом лора; SQLite `/mnt/us/riddle/diary.sqlite3` содержит записи (`ssh kindle 'cd /mnt/us/koreader && ./luajit -e …'` или `sqlite3`, если есть); `ls /mnt/us/riddle/samples` пуст.
- [ ] **Step 6: Review Focus 4–5 на устройстве:** запрос + `powerd` suspend (`lipc-set-prop com.lab126.powerd powerButton 1`) посреди проявления → после пробуждения печать закрыта, приглашение на месте, в логе нет ошибок; синтетика на всю страницу → PNG ≤ 15 КБ, ответ пришёл.
- [ ] **Step 7:** Замер на устройстве: время от `on_page` до текста p50/p90 на 10 запросах (лог) — ожидается < 5 с; RSS после 30 циклов — прирост ≤ 2 МБ.
- [ ] **Step 8:** Commit `feat: дневник на устройстве — сеть, конфиг, сон, одноразовые PNG`.

### Task 6: Растворение без мерцания (параллельно с Tasks 1–3)

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua` (`sinkTick`, `repaintRegion`, `fadeAnswer`, `push`)

**Interfaces:**
- Produces: `Diary:sinkTick()` и `Diary:fadeAnswer()` — растворение россыпью: на каждом шаге стирается (в белый) случайная доля оставшихся чёрных пикселей штриха (детерминированная маска по координатам, 4 шага по ~25 %), обновление только `a2`/`du` региона, **никаких** серых уровней и GL16 для чернил и ответа; проявление ответа — тем же режимом без серых.
- [ ] **Step 1:** Снять текущее мерцание на видео не можем — приёмка глазом владельца. Подготовить 3 варианта в `devtest` (режим из `/mnt/us/riddle/testmode`): `dissolve-a2`, `dissolve-du`, `dissolve-du-4steps-slower`.
- [ ] **Step 2:** Реализовать растворение; полная сборка мусора (190 мс) → пошаговая `collectgarbage("step")` в тиках простоя.
- [ ] **Step 3:** Деплой `tools/deploy.sh`; владелец пишет пальцем 2–3 строки в каждом варианте; выбирает вариант. **Блокирует приёмку задачи.**
- [ ] **Step 4:** Зафиксировать выбранный режим константой, остальные убрать; RSS после 10 циклов — без роста > 1 МБ.
- [ ] **Step 5:** Commit `feat(ui): растворение чернил без мерцания`.

### Task 7: Автозапуск при включении Kindle

**Files:**
- Create: `system/riddle-koreader.conf`, `tools/install_autostart.sh`

- [ ] **Step 1:** `system/riddle-koreader.conf`: `start on framework_ready`, задание: пауза 15 с; если нет `/mnt/us/riddle/no_boot` — `cd /mnt/us/koreader && setsid ./koreader.sh --kual >/dev/null 2>&1 </dev/null &`; не блокирует загрузку. `/mnt/us/emergency.sh` не трогать.
- [ ] **Step 2:** `tools/install_autostart.sh`: бэкап `/etc/upstart/` листинга в `/mnt/us/riddle/backup/`, `mntroot rw`, `scp` conf, `mntroot ro`; `--uninstall` удаляет.
- [ ] **Step 3:** Установить; холодная перезагрузка `ssh kindle reboot`; через ≤ 3 мин дневник на экране (снимок экрана `fbgrab`/KOReader в `spike/boot.png`), SSH поднимается.
- [ ] **Step 4:** Проверка выключателя: `touch /mnt/us/riddle/no_boot`, reboot → обычный интерфейс Kindle; `rm` → снова дневник.
- [ ] **Step 5:** Commit `feat(boot): автозапуск дневника при включении Kindle`.

### Task 8: Чистка Kindle

**Files:**
- Create: `tools/kindle_inventory.sh`

- [ ] **Step 1:** Опись (только чтение): `/mnt/us/*.core`, `Indexer_Dump_*`, `/mnt/us/koreader/cache`, `crash.log*`, `*.old`, `/mnt/us/system` logs, остатки установки WinterBreak в корне (`jb.sh`, `patchedUks.sqsh`, `index.html`, `main.js`, … — **только** если не нужны для работы джейлбрейка; сверить с документацией WinterBreak), `/var/local` логи; размеры. Вывод — таблица.
- [ ] **Step 2:** Отчёт оркестратору → владельцу на одобрение списка. **Без одобрения ничего не удалять.**
- [ ] **Step 3:** Копия одобренного в `~/backups/kindle/2026-10-22/` (`scp -r`), сверка размеров.
- [ ] **Step 4:** Удаление одобренного; `df -h /mnt/us /var/local` до/после; KOReader стартует.
- [ ] **Step 5:** Commit скрипта `chore: опись мусора Kindle`.

### Task 9: Приёмка на устройстве

- [ ] **Step 1:** `rm /mnt/us/riddle/devmode`, `rm /mnt/us/riddle/testmode`; автооткрытие включено; Wi‑Fi внесён владельцем.
- [ ] **Step 2:** Холодная перезагрузка → дневник сам → полный сценарий пальцем владельца: 3 неудачи → подсказка; заветное слово → приветствие; 5 реплик; сон → печать закрыта; повторное открытие → разговор продолжается; `lore_push.sh` → дневник знает новое.
- [ ] **Step 3:** `tests/run.sh` → PASS; лог без ошибок за прогон; `/mnt/us/riddle/samples` пуст.
- [ ] **Step 4:** Push по команде владельца; Notion — заметка-итог (тег `runbook`: как запустить, выключить, восстановить).
