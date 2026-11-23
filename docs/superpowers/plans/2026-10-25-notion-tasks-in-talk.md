# Задачи и темы из Notion в разговоре — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** дневник сам, в образе и по ритму, вспоминает 1–3 незакрытые задачи пользователя (без задач — намекает на темы его баз); база задач находится без настройки у любого пользователя, может быть указана в конфиге или словами в дневнике.

**Architecture:** источник (адаптер Notion, `riddle/notion_tasks.lua` + `riddle/classify.lua`) при синхронизации в дочернем процессе пишет в `knowledge.sqlite3` общий формат — таблицы `collections` и `tasks`; ядро (`riddle/tasks.lua`, `riddle/rhythm.lua`) знает только этот формат: выбирает базу, список незакрытых, режим ответа. Связь записи с задачей и слово пользователя о базе модель отдаёт тем же JSON-ответом (`task`, `tasks_source`); метки лежат у реплик в `diary.sqlite3`, ритм считается из них.

**Tech Stack:** LuaJIT + FFI, KOReader v2025.08, SQLite (`lua-ljsqlite3`), dkjson, Notion API `2025-09-03`, тесты — `tests/run.sh` на Mac.

**Spec:** `docs/superpowers/specs/2026-10-25-notion-tasks-in-talk-design.md` (утверждено владельцем 2026-10-25). Прошлая фича — `docs/superpowers/plans/2026-10-25-notion-knowledge.md`.

## Global Constraints

- Тест до кода; каждый срез — `tests/run.sh` зелёный целиком. Коммит на срез в своём клоне, без push.
- Ядро (`tasks.lua`, `rhythm.lua`, контроллер, промпт) не `require` ни `riddle.notion*`, ни `riddle.sync`, ни `riddle.classify`; про Notion знает только адаптер. Добавить источник = адаптер в общий формат. `app.lua` — точка сборки, не ядро: ему можно знать конфиг источника (`notion_token`), как уже `app.knowledge_text` (`app.lua:122`). Гард — текстом файла: срез 2 на `tasks.lua`, срез 5 на `rhythm.lua`, `controller.lua`, `prompt.lua`.
- Нет id баз, названий полей и слов на конкретном языке, по которым код толкует данные пользователя. Единственная строка API, по которой код решает, — имя группы status `"Complete"` (константа Notion API, см. «Проверка ASSUMPTION», п. 2).
- Лог: только числа, хосты, статусы, флаги и причина сбоя (через `mask`, `app.lua:86-102`). Ни названий баз, задач и свойств, ни текста записей, ни токена.
- Кэш со стороны API (`cachedContents`) в код не вводится (описание, «Кэш»). Кэш на устройстве — только по журналу среза 1 (решение после среза 1, не срез).
- Не больше одного дочернего процесса; родитель открывает `knowledge.sqlite3` на одно чтение/запись и закрывает до fork (`knowledge.lua:1-2`).
- Тексты плагина проходят гард `tests/no_event_spec.lua` (нет «загадк», «отсылк», «квест», «хранител», …; в правилах промпта нет «он/его»); новые фразы — на «ты» без рода, без эмодзи и латиницы, 1 предложение (голос — `prompt.lua:15-27`). Латиница запрещена во фразах пулов и в словах голоса, не в служебной разметке правил: ключи JSON (`"task"`, `"tasks_source"`) и метки `t<N>` в правилах формата остаются. В правилах и фразах о задачах — ни «Notion», ни «статус», «поле», «таблица», «база» (анти-цели описания).
- Блок задач в промпте — ≤ `tasks.LIMIT = 30` задач + общее число незакрытых; `prompt.fit` его не режет.

## Review Focus

1. **Groq (`max_input_chars`) урезает запрос.** Ожидание: знания и лор срезаны, блок задач и правило поля `task` целы. Сейчас `prompt.fit` режет знание до `SUMMARIES_HEAD`/`READ_FORMAT` (`prompt.lua:180-181`) и съел бы блок, стоящий после знаний. Тест: срез 3 `test_fit_keeps_tasks_block`.
2. **Миграция `diary.sqlite3` v3 не прошла** (`Memory.open` логирует и открывает как есть, `memory.lua:103-104`). Ожидание: реплика пишется без меток, `Memory:marks` отдаёт nil без ошибки, дневник отвечает; ритм выключен (режим `"none"`, меток предложений нет), а не «первая запись сессии» на каждом ответе. Тесты: срез 3 `test_add_without_mark_columns_still_writes`, `test_marks_without_mark_columns_is_nil`; срез 5 `test_rhythm_off_without_marks`.
3. **Название базы словами — другой регистр, «ё/е», латиница.** Ожидание: «задачи», «ЗАДАЧИ», «Задачи» находят одну базу; `string.lower` кириллицу не понижает (в плагине есть только локальная `fold` по кодпойнтам в `seal.lua:40`, она отбрасывает не-буквы и наружу не экспортируется; в тестах — `tests/texts_spec.lua:23-24`). Тест: срез 2 `test_match_title_folds_cyrillic_case`.
4. **Модель вернула в `task` чужое** (`"t99"`, название задачи, число `3`, `null`). Ожидание: «неизвестно», без падения, счёт ритма не меняется. Тест: срез 3 `test_bad_task_label_is_unknown`.
5. **Синхронизацию вытеснил ответ посреди классификации** (ответ вытесняет sync, `worker.lua:122-129`: `Runner:start("answer")` гасит текущий sync, тот завершается `"cancelled"`). Ожидание: старые правила баз остаются, классификация повторяется в следующую синхронизацию, задачи не пропадают. Тест: срез 6 `test_classify_failure_keeps_rules_and_retries`.
6. **У пользователя нет базы задач** (только фильмы, рецепты) или в выбранной 0 незакрытых. Ожидание: контроллер сам метит записи `owner` как «ни к какой задаче» (`task = ""`), не спрашивая модель, — темы баз приходят на 1-й записи сессии и на 6-й несвязанной после неё, а не только на 1-й. Тесты: срез 3 `test_no_block_marks_owner_none`, срез 5 `test_without_tasks_themes_first_and_sixth`.

---

## Проверка ASSUMPTION описания (2026-10-25, до плана)

Живые вызовы — с Mac, токен `NOTION_DIARY_API`, только `POST /v1/search`, `POST /v1/data_sources/{id}/query`, `GET /v1/{data_sources,databases,pages}/{id}`; 32 + 2 вызова, в Notion ничего не записано. Notion владельца: 160 объектов поиска (153 страницы, 7 data source), 147 строк баз.

| # | ASSUMPTION | Итог | Улика |
|---|---|---|---|
| 1 | В API есть признак «база задач» | **Опровергнуто** | Ключи data source (поиск и `GET`): `archived, cover, created_by, created_time, database_parent, database_type, description, icon, id, in_trash, is_inline, last_edited_by, last_edited_time, object, parent, properties, public_url, title, url`; у database — те же + `data_sources, is_locked, show_data_source_title`; ни одного ключа с «task». `database_type` = `null` у всех 7; документация: «The type of typed database this data source belongs to. `null` for a regular data source», пример значения — `"skills"` (developers.notion.com/reference/data-source). → `native_tasks` всегда «нет» (запасной вариант описания). |
| 2 | Схема status отдаёт группы с вариантами | **Подтверждено** | 6 свойств status в 5 базах: `status = {options, groups, default_option}`; у каждой ровно три группы по порядку `To-do`, `In progress`, `Complete`, у группы `{id, name, color, option_ids}`, у варианта `{id, name, color, description}`. Схема приходит уже в объекте data source из `/v1/search` (`properties`) — лишних запросов нет. |
| 3 | Глубину можно получить через `parent` | **Подтверждено** | `data_source.parent.type = database_id`, `data_source.database_parent.type ∈ {page_id, workspace}`, `database_parent == database.parent` 7/7. Дальше — `page.parent.type ∈ {page_id, data_source_id, workspace}`, у data source — его `database_parent`. Все предки всех 7 баз есть в результатах `/v1/search` → глубина считается без единого лишнего вызова; глубины 0, 3, 3, 3, 3, 3, 1. |
| 4 | `GET /v1/pages/{id}` архивной страницы — 200 с `in_trash`/`archived`, не 404 | **Не проверяемо без записи — остаётся ASSUMPTION** | В поиске 0 из 160 объектов в корзине; целей relation вне поиска — 0 (по 147 строкам), т.е. у владельца этот путь сейчас не срабатывает ни разу. Документация (reference/retrieve-a-page): у страницы поля `in_trash` («Whether the page is in trash») и `is_archived`; «A missing page or missing access returns 404»; про корзину — молчит. Исход 200 с `in_trash`/`archived`/`is_archived` = true → архив. Исход «404 для страницы в корзине» план **не** обрабатывает: по описанию 404 — «не архив», и задачи такого проекта были бы названы незакрытыми (против описания, «Незакрытая задача»). **Ждёт решения владельца** (живая проверка записью в его Notion или принятие риска) — см. срез 4, шаг 3b, и вопрос 4. |
| 5 | В дочернем процессе синхронизации доступны ключи LLM | **Подтверждено чтением кода** | Синхронизация — замыкание в `runner:start("sync", …)` (`main.lua:121`), дочерний — fork родителя (`ffiutil.runInSubProcess`, план прошлой фичи, «Опоры»); конфиг — `syncConfig()` = `state.cfg` (`main.lua:110-113`), это полный `config.load()` (`main.lua:46-47`) с `gemini_key`, `gemini_keys`, `providers[].key` (`config.lua:89-106`); `riddle.http` в дочернем уже грузится (`main.lua:127`). Оговорка: учёт цепочки (мёртвые ключи, сдвиг `calls`) живёт в замыкании контроллера (`app.lua:299-300`), у дочернего — свежая цепочка; мёртвые ключи из классификации родителю не передаются. Живой вызов модели из дочернего на Kindle — проверка среза 6. |

## Опоры в коде (проверено)

| Факт | Источник |
|---|---|
| Ответ JSON `{"read","reply"}` разбирается `find_object` (как есть / в ```-обёртке / от `{` до `}`), без `read` — ошибка | `llm.lua:122-166` |
| Порядок system: персона → лор → знания → пересказы → `READ_FORMAT` → `HISTORY_HEAD`; история; последним — user с `USER_TEXT` и картинкой | `prompt.lua:85-113`, `:59-69` |
| `prompt.fit` режет знание до `SUMMARIES_HEAD`/`READ_FORMAT`, лор — до `KNOWLEDGE_HEAD`/… | `prompt.lua:149-186` |
| Метаданные ответа 200 в лог — `describe(body)`: `finish`, `out_tokens`, `chars`, `think` | `app.lua:52-61`, `:196` |
| Gemini отдаёт попадание кэша в `usage.prompt_tokens_details.cached_tokens` | описание, «Кэш» (замер w2 2026-10-25) |
| Контекст ответа собирается в родителе до fork: `_open_context` (лор, пересказы, история, знания) | `controller.lua:110-125`, `:155-160` |
| Реплики пишутся парой `owner`/`diary` в `_remember` | `controller.lua:89-96`, `:182-188` |
| Память: `entries(id, session_id, ts, role, text)`, `user_version = 2`, миграции шагами; сессия — пауза > 4 ч | `memory.lua:6`, `:10-28`, `:117-132` |
| Знание: `user_version = 1`, `sources`, `docs`, `meta`; миграции шагами в транзакции | `knowledge.lua:13-23`, `:72-80` |
| Синхронизация: `/v1/search` → data sources и страницы, строки каждой базы `query_all`; корзина отбрасывается (`trashed`) | `sync.lua:62-103` |
| Конец удачного прогона — `delete_missing`, `last_ok` | `sync.lua:167-177` |
| Строка лога sync пишется и в `sync.run`, и в `on_done` родителя | `sync.lua:200-208`, `main.lua:155-166` |
| `Chain:remote_fn(messages, want_json, opts)()` выполняет цепочку в текущем процессе с бюджетом ответа 25 с и возвращает `{result, err, logs, dead}` | `app.lua:245-255`, `:15-18` |
| Потолок payload дочернего — 32768 байт | `worker.lua:13` |
| `push_config.sh` пишет конфиг целиком (`cat >`), Notion-токен — из `NOTION_DIARY_API` | `tools/push_config.sh:98-103`, `:138` |
| Конфиг: строковые поля чистит `clean_str` | `config.lua:30`, `:77-131` |

## Решения плана (в описании оставлены исполнителю)

- **Схема общего формата** — в `knowledge.sqlite3` v2, отдельно от таблиц Notion (`sources`, `docs`, `meta`): `collections`, `tasks`, `core` (состояние ядра: слово пользователя). Правила толкования баз (результат классификации, хэш схемы, кэш проектов) — служебные данные адаптера в `meta` с префиксами `cls:`, `proj:`.
- **Режим «намёк» и «предложение» — условные**: контроллер считает счёт по прошлым записям сессии, а строка режима говорит модели «если запись не касается ни одного дела — …». Касается ли текущая запись задачи, известно только из этого же ответа (`task`), поэтому иначе 3-я несвязанная запись не получила бы намёк. Первая запись сессии — безусловно.
- **Глубина** — по результатам `/v1/search`; предка нет в поиске — один `GET` по его типу (`pages`/`blocks`/`data_sources`), 404 — глубина считается до него.
- **Классификация** — один вызов модели на все базы со свойствами status/select/checkbox, только когда хэш их схем изменился; ответ — JSON, проверяется по схеме (несуществующие свойства и варианты отбрасываются).
- **Слово о базе не нашлось / несколько похожих** — ответ заменяется фразой из пула `texts.tasks_source_unclear` (дневник в образе переспрашивает).
- **Переменная окружения ключа конфига** — `RIDDLE_TASKS_SOURCE`.

## Схема и формат ответа (что меняется)

- **`knowledge.sqlite3` v1 → v2 (срез 2):** `collections(id TEXT PRIMARY KEY, title TEXT, source TEXT, items INT, task_candidate INT, native_tasks INT, depth INT, model_pick INT)`, `tasks(id TEXT PRIMARY KEY, collection_id TEXT, title TEXT, open INT, archived INT, project TEXT, due TEXT, edited TEXT)`, `core(k TEXT PRIMARY KEY, v TEXT)`. Старые таблицы не трогаются.
- **`diary.sqlite3` v2 → v3 (срез 3):** `ALTER TABLE entries ADD COLUMN task TEXT`, `ADD COLUMN offer TEXT`. У реплики `owner`: `task` NULL — неизвестно, `""` — ни к какой задаче, иначе id задачи. У реплики `diary`: `offer` NULL — ничего не предлагал, `"themes"` — темы, иначе id предложенных задач через пробел.
- **Ответ модели (срезы 3, 7):** к `{"read","reply"}` — необязательные `"task"` (метка `t<N>` из блока или `""`) и `"tasks_source"` (название базы из списка или `""`). Нет поля — нет значения; `llm.parse` их не требует.

## Срезы

| # | Срез | Что видит тестер на Kindle | Зависит от | Дифф, оценка строк |
|---|---|---|---|---|
| 1 | Журнал `cached_tokens` и времени сборки | в логе `cached=…` у ответа Gemini и `prompt built in N ms` | — | ~100 |
| 2 | Общий формат и ядро выбора базы | `knowledge.sqlite3` `user_version = 2`, дневник отвечает как раньше | — | ~300 |
| 3 | Блок незакрытых задач и поле `task` | на «что мне надо сделать?» — ответ по незакрытым; в логе `tasks open=…`, `entry task=…` | 2, 1 (общие `app.lua`, `controller.lua`) | ~400 |
| 4 | Адаптер Notion: базы, глубина, задачи; ключ конфига | в логе `sync done … collections=7 tasks=N`; с `RIDDLE_TASKS_SOURCE` блок задач в ответах | 2 | ~400 |
| 5 | Ритм: 1–3 задачи, намёк, предложение, темы | 1-я запись сессии — 1–3 задачи; 3-я несвязанная — намёк; 6-я — другие задачи | 3 | ~300 |
| 6 | Классификация баз моделью при синхронизации | без `tasks_source` база задач найдена сама; в логе `classify … pick=yes`; повторная sync — без classify | 3 (`llm.lua`), 4 | ~380 |
| 7 | Слово пользователя о базе | «мои дела — в такой-то книге» → блок из неё сразу; «ищи сам» — сброс | 4, 5 | ~250 |

Срезы 3 и 4 — у верхней границы 400; вылезут — делить по файлам: 3 → (память + `llm.parse`) и (контекст + промпт), 4 → (адаптер + sync) и (конфиг + `push_config.sh`).

Параллельно: 1 ∥ 2 (разные файлы). После них 3 ∥ 4: срез 3 — `prompt.lua`, `llm.lua`, `controller.lua`, `memory.lua`, `app.lua`; срез 4 — `notion.lua`, `notion_tasks.lua`, `sync.lua`, `config.lua`, `config.example.lua`, `tools/push_config.sh`, `main.lua`. Затем 5 ∥ 6: срез 5 — `rhythm.lua`, `controller.lua`, `prompt.lua`; срез 6 — `classify.lua`, `notion_tasks.lua`, `sync.lua`, `main.lua` (`llm.lua` не трогает: экспорт `llm.find_object` делает срез 3). Срез 3 читает `cfg.tasks_source` (`app.tasks_context`), а поле в `config.lua` появляется в срезе 4: тесты среза 3 передают `cfg` руками, на устройстве `via=config` — только когда готовы оба. Срез 7 — строго после 5 (те же `controller.lua`, `prompt.lua`). Живые проверки 3 и 5 на Kindle требуют задач в хранилище — после среза 4 (с `RIDDLE_TASKS_SOURCE`) или 6.

---

### Срез 1: Журнал `cached_tokens` и времени сборки запроса

Результат: в логе каждого ответа 200 — сколько токенов входа пришло из кэша провайдера; у каждого ответа открытой печати — время сборки запроса в родителе. Нужен для решения о кэше на устройстве (описание: вводим, только если сборка заметна на фоне ~1,5 с ответа).

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua:52-61` (`describe`), `:299-318` (dep `clock` контроллеру)
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua:155-162` (`_begin`)
- Test: `tests/app_spec.lua`, `tests/controller_spec.lua`

**Interfaces:**
- Produces: в строке `riddle: llm <host> -> 200 …` хвост ` cached=<n|->` (`usage.prompt_tokens_details.cached_tokens`, нет — `-`); строка `riddle: prompt built in <ms> ms chars=<prompt.chars>` для `mode = "open"`. Dep контроллера `clock` (монотонные секунды; нет — строки нет).

- [ ] **Step 1: Тесты (падают)** — `app_spec`: `test_describe_logs_cached_tokens` (тело 200 с `usage = {prompt_tokens = 16600, prompt_tokens_details = {cached_tokens = 14100}}` → строка лога содержит `cached=14100`), `test_describe_without_cache_details_logs_dash` (`cached=-`). `controller_spec`: `test_open_begin_logs_build_time` (поддельный `clock` 1.000 → 1.012 → лог содержит `prompt built in 12 ms chars=`), `test_locked_begin_logs_no_build_time`.
- [ ] **Step 2:** `tests/run.sh` — FAIL на четырёх тестах.
- [ ] **Step 3: Реализовать** — в `describe` добавить поле; в `_begin` замерить `prompt.open` + `_open_context` по `deps.clock`.
- [ ] **Step 4:** `tests/run.sh` — OK целиком.
- [ ] **Step 5:** деплой `tools/deploy.sh`, 5 записей подряд, `tools/kindle_log.sh 200` — строки `cached=` и `prompt built`; цифры (медиана `prompt built`, доля попаданий) — в отчёт оркестратору.
- [ ] **Step 6: Commit** `feat(log): cached_tokens ответа и время сборки запроса`.

### Срез 2: Общий формат и ядро выбора базы

Результат: `knowledge.sqlite3` v2 с таблицами общего формата; чистые функции ядра: выбор базы по старшинству, совпадение названия, список незакрытых в порядке выбора, блок ≤ 30. Источника ещё нет — на устройстве поведение прежнее.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/knowledge.lua:13-23` (миграция 2), новые методы после `:174`
- Create: `plugin/riddlediary.koplugin/riddle/tasks.lua`
- Test: `tests/knowledge_spec.lua`, `tests/tasks_spec.lua` (новый)

**Interfaces:**
- Produces (`knowledge`):
  - `K:put_snapshot(source, collections, tasks)` — одной транзакцией заменить все коллекции этого `source` и задачи этих коллекций. `collection = {id, title, source, items, task_candidate, native_tasks, depth, model_pick}` (булевы — `true/false`, в базе 0/1); `task = {id, collection_id, title, open, archived, project, due, edited}` (`project`, `due` — строка или nil).
  - `K:collections() -> {collection…}` (по `id`); `K:tasks_of(collection_id) -> {task…}`.
  - `K:core(k) -> string | nil`; `K:set_core(k, v | nil)` (nil — удалить).
- Produces (`tasks`):
  - `tasks.LIMIT = 30`.
  - `tasks.fold(s) -> s` — нижний регистр латиницы и кириллицы, `ё` → `е`, пробелы по краям срезаны, внутри сжаты.
  - `tasks.match_title(collections, name) -> collection | nil, "none" | "many"` — равенство `fold`; иначе единственная, чьё `fold(title)` содержит `fold(name)` или наоборот.
  - `tasks.pick_source(collections, user_word, cfg_value) -> collection | nil, why` — `why ∈ "user","config","native","model","depth"`; `user_word`/`cfg_value` — сначала как `id`, потом `match_title`; по `user_word`/`cfg_value` — любая коллекция, дальше — только `task_candidate`; среди кандидатов `native_tasks` → `model_pick` → меньшая `depth` (равенство — по `id`).
  - `tasks.open_list(task_rows) -> {task…}` — `open and not archived`, с непустым `title`; по `due` возр. (без срока — после), затем `edited` убыв., затем `id`.
  - `tasks.block(open_list) -> { items = {{label = "t1", id, title, due, project}…} (≤ LIMIT), total = #open_list, by_label = {t1 = id…} }`.

- [ ] **Step 1: Тесты (падают)** — `knowledge_spec`: `test_migration_v1_to_v2_keeps_docs` (база v1 с документом → после `open` `user_version = 2`, документ на месте), `test_put_snapshot_replaces_only_its_source` (снимок `"notion"` дважды — вторая версия без одной задачи, коллекция `source = "other"` цела), `test_core_set_and_clear`. `tasks_spec`: `test_pick_order_user_config_native_model_depth` (по одному кандидату на каждое правило; убирая старшее, получаем следующее `why`), `test_user_word_beats_config_and_may_name_non_candidate`, `test_config_value_as_id_or_title`, `test_match_title_folds_cyrillic_case` («ЗАДАЧИ», «задачи», «Задачи » → одна; «ёлки» = «Елки»), `test_match_title_many_and_none`, `test_open_list_drops_closed_archived_untitled`, `test_open_list_order_due_then_edited`, `test_block_caps_at_30_and_counts_total` (45 открытых → 30 `items`, `total = 45`, метки `t1..t30`), `test_core_requires_no_source_module` (текст `tasks.lua` не содержит `require("riddle.notion`, `riddle.sync`, `riddle.classify`).
- [ ] **Step 2:** `tests/run.sh` — FAIL (`module 'riddle.tasks' not found`, нет методов).
- [ ] **Step 3: Реализовать** миграцию 2 (схема — раздел «Схема и формат ответа») и методы; `tasks.lua` по Interfaces. Таблица понижения кириллицы — по кодам UTF-8 (`А`–`Я` → `а`–`я`, `Ё`/`ё` → `е`), как `tests/texts_spec.lua:23-24`.
- [ ] **Step 4:** `tests/run.sh` — OK.
- [ ] **Step 5:** деплой; после первой синхронизации `ssh kindle` → `sqlite3 /mnt/us/riddle/knowledge.sqlite3 'PRAGMA user_version'` = 2 (или по логу: `sync done` без `store:`); 2 записи — ответы как раньше.
- [ ] **Step 6: Commit** `feat(tasks): общий формат задач в knowledge v2 и выбор базы ядром`.

> Внесено по ревью плана (передано исполнителю среза 2 вместе с брифом): **м4** — поиск подстроки в `match_title` — `string.find(…, 1, true)` (plain), иначе `-`, `(`, `%` в названии ломают шаблон; **м11** — `user_version = 2` в шаге 5 проверяется только прямым запросом `PRAGMA user_version`, строка лога `sync done` без `store:` этого не доказывает.

### Срез 3: Блок незакрытых задач и поле `task`

Результат: когда база выбрана и в ней есть незакрытые, в system сразу после знаний — блок задач с метками; модель отмечает, к какой задаче запись; метка ложится в `diary.sqlite3`. Режима ещё нет: дневник называет задачи, только если спросить, и не называет закрытые незакрытыми.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/memory.lua:10-28` (миграция 3), `:134-157`
- Modify: `plugin/riddlediary.koplugin/riddle/prompt.lua:49-113`, `:149-186`
- Modify: `plugin/riddlediary.koplugin/riddle/llm.lua:122-166`
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua:104-148` (`knowledge_text` + рядом `app.tasks_context(K, d)`; новой dep в `:299-318` нет)
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua:89-125`, `:155-188`
- Test: `tests/memory_spec.lua`, `tests/prompt_spec.lua`, `tests/llm_spec.lua`, `tests/app_spec.lua`, `tests/controller_memory_spec.lua`

**Interfaces:**
- Consumes: срез 2 — `K:collections`, `K:tasks_of`, `K:core`, `tasks.pick_source`, `tasks.open_list`, `tasks.block`.
- Produces:
  - `Memory:add(sid, role, text, now, marks)` — `marks = {task = string|nil, offer = string|nil}` необязательно; колонок нет (миграция не прошла) — запись без меток. `Memory:marks(sid) -> {{role, task, offer}…} | nil` по порядку записей сессии; колонок нет — `nil` и строка лога `riddle: memory marks unavailable`, без ошибки (вызов идёт в `_begin` под `pcall`, `controller.lua:155-161`: ошибка там дала бы `fail_other` на каждый ответ).
  - `app.tasks_context(K, d) -> ctx | nil` — чистое чтение из уже открытой базы: `tasks.pick_source(K:collections(), K:core("tasks_source"), d.cfg.tasks_source)` (`cfg.tasks_source` появится в `config.lua` срезом 4, до того nil). `ctx = { collection = {id, title}, why, block = tasks.block(...), open = open_list, collections = K:collections(), titles = {название каждой коллекции…} }`; выбранной коллекции нет **или в ней 0 незакрытых** — `ctx.block = nil`, `collections` и `titles` есть; коллекций нет — nil. Лог: `riddle: tasks open=<total> shown=<#items> via=<why|none>`.
  - Одно `knowledge.open` на ответ (м14): `app.knowledge_text(d)` (`app.lua:112-148`) в том же открытии базы зовёт `app.tasks_context(K, d)` и отдаёт `ctx` **четвёртым значением**: `text, mode, recent, tasks`; текста нет (0 документов) — `nil, nil, nil, tasks`. Сбой чтения задач — свой `pcall`: `tasks = nil`, строка `riddle: tasks read failed: <mask>`, знания отдаются как раньше. Гейт по `notion_token` — прежний (`app.lua:122`; `app.lua` — точка сборки, см. Global). Новой dep контроллеру нет.
  - Контроллер: `_knowledge` (`controller.lua:100-108`) берёт четвёртое значение; `_open_context` кладёт его в контекст, `job.tasks = ctx`.
  - `prompt.open(png, ctx)`: `ctx.tasks = block` → раздел `TASKS_HEAD .. "\n" .. строки` после знаний, до пересказов; строка — `[t1] Название (срок 2026-10-30; Проект)` (части, что есть); последней строкой раздела — «всего незакрытых: N». Раздел и правило `TASK_FORMAT` (сразу после `READ_FORMAT`) — постоянный текст, есть всегда, когда есть блок.
  - `prompt.fit`: концы раздела знаний — `{TASKS_HEAD, SUMMARIES_HEAD, READ_FORMAT}`, лора — `{KNOWLEDGE_HEAD, TASKS_HEAD, SUMMARIES_HEAD, READ_FORMAT}`.
  - `llm.parse(…, true)` → результат с `task` (строка без пробелов по краям, если в JSON строка; иначе nil) и `tasks_source` (так же). `llm.find_object(content) -> table | nil` — экспорт.
  - Контроллер: `task` ответа → `job.tasks.block.by_label[task]` (id) / `""` / иначе nil; пишет `marks.task` реплике `owner`. **Есть `job.tasks`, а `block` нет** (базы не выбрано или 0 незакрытых) — `marks.task = ""` без оглядки на ответ: запись не может касаться дела, которого нет, а без этого счёт ритма у пользователя без задач не растёт никогда (темы только на 1-й записи сессии). `job.tasks = nil` (нет источника, сбой чтения) — как раньше, nil. Лог: `riddle: entry task=<yes|none|unknown>`.
- Текст `TASKS_HEAD` (смысл; слова — исполнителю, голосом персоны): это дела, которые пишущий собирался сделать и ещё не сделал; не перечислять всё разом. В разделе — две отдельные экспортные строки правил, чтобы тест видел их дословно: `prompt.TASKS_ONLY_OPEN` — называть незакрытыми только дела этого списка, всё остальное о делах в памяти — сделано или отложено; `prompt.TASKS_QUIET` — самому о делах не заговаривать: только если пишущий спросил о них, запись касается одного из них или так велит пометка к этой записи (строка режима среза 5). Блок лежит в каждом запросе ради кэша, без `TASKS_QUIET` дела всплывали бы в обычных ответах (анти-цель «задачи в каждом ответе»). `TASK_FORMAT`: если запись касается одного из дел списка — `"task":"<метка>"`, иначе `"task":""`.

- [ ] **Step 1: Тесты (падают)**:
  - `memory_spec`: `test_migration_v3_adds_mark_columns`, `test_marks_in_order_with_nulls` (owner `task = nil`, owner `task = ""`, diary `offer = "id1 id2"` → три записи с этими значениями), `test_add_without_mark_columns_still_writes` (база, где миграцию 3 сорвали — колонок нет → `add` с `marks` пишет текст), `test_marks_without_mark_columns_is_nil` (та же база → `marks` = nil, без ошибки, строка лога `memory marks unavailable`).
  - `prompt_spec`: `test_tasks_block_after_knowledge_before_summaries`, `test_no_tasks_block_without_block`, `test_task_format_only_with_block`, `test_fit_keeps_tasks_block` (знание 20 000 знаков, блок 30 задач, `fit(m, 8000)` → блок и `TASK_FORMAT` целиком, знание урезано), `test_tasks_texts_stay_in_role` (`TASKS_HEAD`, `TASKS_ONLY_OPEN`, `TASKS_QUIET`, `TASK_FORMAT` без «Notion», «статус», «поле», «таблиц», «баз»), `test_tasks_section_carries_rules` (раздел задач в system содержит `prompt.TASKS_ONLY_OPEN` и `prompt.TASKS_QUIET` дословно; без блока — ни того, ни другого).
  - `llm_spec`: `test_parse_reads_optional_task_and_tasks_source`, `test_parse_without_task_field_gives_nil`, `test_parse_non_string_task_gives_nil` (`3`, `null`, `{}`).
  - `app_spec`: `test_tasks_context_nil_without_token`, `test_tasks_context_picks_and_logs_counts` (fixture-база: 2 коллекции, 40 задач, 35 незакрытых → `shown=30`, `open=35`, в логе нет названий), `test_tasks_context_via_config` (снимок с двумя кандидатами, `d.cfg.tasks_source` = название второй → `ctx.collection.id` второй, лог `via=config`), `test_tasks_context_zero_open_has_no_block` (выбранная база, все закрыты → `ctx.block = nil`, `titles` есть), `test_tasks_read_failure_keeps_knowledge` (сбой `K:collections` → четвёртое значение nil, текст знаний есть, строка `tasks read failed`), `test_knowledge_and_tasks_in_one_open` (подменённый `knowledge.open` со счётчиком → 1 вызов на ответ).
  - `controller_memory_spec`: `test_task_label_maps_to_id_on_owner_entry` (`"t2"` → id второй задачи блока), `test_empty_task_is_none`, `test_bad_task_label_is_unknown` (`"t99"`, `"Купить хлеб"` → `task` NULL, лог `entry task=unknown`), `test_no_block_marks_owner_none` (`job.tasks` без `block`, ответ без поля `task` → у `owner` `task = ""`, лог `entry task=none`), `test_no_tasks_context_keeps_old_behaviour`.
- [ ] **Step 2:** `tests/run.sh` — FAIL на новых.
- [ ] **Step 3: Реализовать** по Interfaces. Миграция 3 — `ALTER TABLE` (раздел «Схема»); `Memory:add` с `marks` при ошибке «no such column» повторяет вставку без меток; `Memory:marks` при той же ошибке — nil.
- [ ] **Step 4:** `tests/run.sh` — OK.
- [ ] **Step 5:** на Kindle (после среза 4, `RIDDLE_TASKS_SOURCE` = база задач): «что мне надо сделать?» — ответ называет незакрытые; «что я сделал?» — по закрытым из знаний, не как незакрытые; лог `tasks open=… via=config`, `entry task=yes|none`.
- [ ] **Step 6: Commit** `feat(tasks): блок незакрытых задач в промпте и метка задачи у записи`.

### Срез 4: Адаптер Notion — базы, глубина, задачи; ключ конфига

Результат: каждая удачная синхронизация пишет снимок общего формата: все data source как коллекции (глубина, число строк), задачи — строки кандидатов и базы, указанной словом или конфигом. Без классификации (срез 6) кандидатов нет: задачи есть только у базы из `tasks_source` / слова. Закрытость — по группе `Complete` свойств status; архив — корзина и архивный проект.

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/notion_tasks.lua`
- Modify: `plugin/riddlediary.koplugin/riddle/notion.lua` (после `:130` — `Client:get`)
- Modify: `plugin/riddlediary.koplugin/riddle/sync.lua:66-103` (`collect` отдаёт и объекты поиска), `:167-208`
- Modify: `plugin/riddlediary.koplugin/main.lua:148-166` (`tasks_source` в `sync.run`, хвост строки лога)
- Modify: `plugin/riddlediary.koplugin/riddle/config.lua:77-131`, `config.example.lua`, `tools/push_config.sh:98-103`
- Test: `tests/notion_tasks_spec.lua` (новый), `tests/sync_spec.lua`, `tests/notion_spec.lua`, `tests/config_spec.lua`, `tests/push_config_spec.lua`

**Interfaces:**
- Consumes: срез 2 — `K:put_snapshot`, `K:core("tasks_source")`, `tasks.pick_source`.
- Produces:
  - `Client:get(kind, id) -> obj | nil, err`; `kind ∈ "pages","blocks","data_sources"`; `GET /v1/<kind>/<id>`.
  - `notion_tasks.depth(src, by_id, fetch) -> n` — по `database_parent`, потом `parent` страниц/блоков и `database_parent` data source; объект берётся из `by_id` (результаты поиска), нет — `fetch(kind, id)`; nil — стоп; не больше 12 шагов.
  - `notion_tasks.default_rules(src) -> rules` — `{ status = {[prop] = {[имя варианта] = true}} }` из группы `name == "Complete"` (`option_ids` → имена).
  - `notion_tasks.task(row, collection_id, rules, look) -> task` — `open = false`, если закрыта хоть по одному правилу (`status`, а со среза 6 и `closed_select`, `done_checkbox`); `archived` — по правилам архива (срез 6) или архивному проекту; `project`/`due` — по `rules.project`/`rules.due` (срез 6), иначе nil; `edited = row.last_edited_time`. `look = {title_of = fn(id) -> string|nil, project_archived = fn(task_id, edited, project_id) -> bool}`.
  - `notion_tasks.snapshot(d) -> collections, tasks` — `d = {sources, rows_by_source, by_id, docs_titles, rules_by_id, chosen_id, fetch, proj_cache}`; кандидат = `rules_by_id[id].tasks == true` или `id == chosen_id`; у выбранного не-кандидата без правил — все строки `open = true` (кроме status-правила по умолчанию, если status есть).
  - Проект в архиве: цель relation есть среди строк синхронизации — по её `archived`; нет — `fetch("pages", id)`: `in_trash`/`archived`/`is_archived` = true → архив, 404/ошибка → не архив; ответ кэшируется в `meta` `proj:<task_id>` = `"<edited> <0|1>"` до изменения `edited` задачи. Кэш переписывается целиком при каждом снимке (м12): `K:delete_meta_prefix("proj:")` (`knowledge.lua:172-174`) и запись меток только задач этого снимка — метки удалённых задач не копятся (`sync.lua:168-173` чистит только `fail:`/`gap:`).
  - **Ветка «проект в корзине → 404» (Б7) ждёт решения владельца:** живая проверка `GET /v1/pages` страницы в корзине записью в его Notion (создать → в корзину → `GET` → удалить) или явное принятие риска. До решения срез 4 делается без неё: код и тесты выше — по букве описания (404 → не архив); что делать при 404 для корзины — отдельным шагом 3b после решения.
  - `sync.run{…, tasks_source = cfg.tasks_source}`; `chosen_id` = `tasks.pick_source(колл., K:core("tasks_source"), d.tasks_source)` только по `why ∈ "user","config"`. Снимок — перед `last_ok`; сбой снимка — ошибка прогона (`store: …`).
  - Статистика: `stats.collections`, `stats.tasks`, `stats.open`; хвост строки лога в `sync.run` и `main.lua` on_done: ` collections=%d tasks=%d open=%d`.
  - `cfg.tasks_source` — `clean_str(raw.tasks_source)`; `config.example.lua` — строка с комментарием «название или id базы задач; по умолчанию дневник ищет сам». `push_config.sh`: `RIDDLE_TASKS_SOURCE` непусто → `tasks_source = "<значение>",`; значение с `"`, `\` или переводом строки — ошибка, конфиг не пишется.
  - Owner-ный Notion (проверка 3): 0 лишних вызовов на глубину.

- [ ] **Step 1: Тесты (падают)** — `notion_tasks_spec` на фикстурах формы из «Проверки ASSUMPTION» (data source с `database_parent`, `properties.status.status.groups`):
  - `test_depth_from_search_objects_without_fetch` (цепочка `page_id → data_source_id → page_id → workspace` = 3, `fetch` не вызван), `test_depth_fetches_missing_ancestor_once`, `test_depth_stops_on_404`.
  - `test_status_in_complete_group_is_closed`, `test_status_in_progress_is_open`, `test_two_status_props_closed_if_any_closed`.
  - `test_chosen_non_candidate_rows_are_open_without_rules`.
  - `test_project_missing_from_sync_trashed_is_archived` (`fetch` → `{in_trash = true}`), `test_project_404_is_not_archived`, `test_project_lookup_cached_until_task_edited` (второй прогон с тем же `edited` — `fetch` не вызван; `edited` новый — вызван), `test_project_cache_drops_deleted_tasks` (задача пропала из второго снимка → её `proj:` в `meta` нет).
  - `sync_spec`: `test_sync_writes_collections_and_chosen_tasks` (`tasks_source` = название → снимок с задачами этой базы, лог `collections=2 tasks=3 open=2`), `test_sync_word_in_core_beats_config`, `test_snapshot_failure_keeps_last_ok`.
  - `notion_spec`: `test_get_builds_path_and_rejects_bad_id`.
  - `config_spec`: `test_tasks_source_cleaned`; `push_config_spec`: `test_tasks_source_from_env_written`, `test_tasks_source_with_quote_rejected`.
- [ ] **Step 2:** `tests/run.sh` — FAIL.
- [ ] **Step 3: Реализовать** по Interfaces. В лог — только числа.
- [ ] **Step 3b (после решения владельца по Б7, отдельным коммитом):** проверка подтвердила 200 с `in_trash` — шаг закрыт без кода; подтвердила 404 — способ отличить корзину от «нет доступа» решает оркестратор с владельцем, тест до кода; владелец принял риск — строка в описании и плане, кода нет.
- [ ] **Step 4:** `tests/run.sh` — OK.
- [ ] **Step 5:** оркестратор заливает конфиг с `RIDDLE_TASKS_SOURCE`; деплой; после сна — `sync done … collections=7 tasks=18 open=N`; запрос к API на глубину в логе не растёт (`seen=` как раньше). Тестеру (м7): между срезами 4 и 6 закрытость считается только по status-группе `Complete`; у базы из конфига, где «сделано» — чекбокс или select, все строки открыты, и дневник назовёт закрытые незакрытыми. Это не баг среза 4 — проверять на базе со status.
- [ ] **Step 6: Commit** `feat(notion): снимок баз и задач в общий формат, tasks_source в конфиге`.

### Срез 5: Ритм — 1–3 задачи, намёк, предложение, темы

Результат: контроллер считает режим ответа из меток сессии и кладёт строку режима в последнее user-сообщение (не в system). Первая запись сессии — 1–3 непредлагавшиеся задачи (нет задач — намёк на темы баз); 3-я подряд запись без задачи — намёк «отклонились»; 6-я — другие задачи (нет задач — темы), счёт с нуля; запись о задаче обнуляет; «неизвестно» не меняет.

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/rhythm.lua`
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua` (`_open_context`, `_answer`)
- Modify: `plugin/riddlediary.koplugin/riddle/prompt.lua:59-69` (`image_user` с текстом режима), тексты режимов
- Test: `tests/rhythm_spec.lua` (новый), `tests/prompt_spec.lua`, `tests/controller_memory_spec.lua`

**Interfaces:**
- Consumes: срез 3 — `Memory:marks` (`nil` — меток нет), `ctx.block` (`has_tasks = ctx.block ~= nil`), `ctx.titles`; при `ctx.block = nil` записи `owner` уже помечены `""` (срез 3), поэтому счёт без задач растёт.
- Produces:
  - `rhythm.count(marks) -> n` — по порядку: `owner.task` непустой → 0; `""` → +1; nil → без изменений; `diary.offer` не nil → 0.
  - `rhythm.mode(marks, has_tasks, has_titles) -> mode, conditional` — нет записей `owner` в сессии → `"name"` (нет задач → `"themes"`), `conditional = false`; иначе `k = count + 1`: `k >= 6` → `"name"`/`"themes"`; `k == 3` → `"drift"` (нет задач — `"none"`, см. вопрос 2); иначе `"none"`; `conditional = true`. `"themes"` без `has_titles` → `"none"`.
  - `rhythm.offered(marks) -> {id…}` — id из `diary.offer` (кроме `"themes"`), каждый один раз, по времени **последнего** предложения, давние первыми (равные — в порядке id в строке `offer`).
  - `rhythm.pick(items, offered, n) -> {item…}` — `items` = `ctx.block.items` (≤ 30, порядок `open_list`, у каждой есть метка — м3: задача вне блока не получила бы метку, и запись о ней посчиталась бы несвязанной). До `n = 3` из `items`, которых нет в `offered`, в порядке `items`; таких нет совсем — до `n` из `offered ∩ items` в порядке `offered` (давно предложенные первыми; описание: «все уже предлагались — снова задачи, начиная с давно предложенных»). Предложенная, а потом закрытая задача из `items` выпала — снова не будет названа.
  - Контроллер: `Memory:marks` = nil (миграция 3 не прошла) — ритм выключен: режим `"none"`, `offer` не пишется, лог `rhythm mode=none n=-`. Иначе пустые метки дали бы «нет записей owner» → `"name"` на каждом ответе.
  - `prompt.open(png, ctx)`: `ctx.mode_line` (строка) — дописывается к `USER_TEXT` последнего сообщения. `prompt.mode_line(mode, conditional, items | titles) -> string | nil`: `"name"` — назвать эти 1–3 дела своими словами, не все и без списка; `"drift"` — намекнуть, что разговор ушёл от задуманного; `"themes"` — намекнуть на то, что пишущий собирает (по названиям), без конкретных строк; `conditional` — с условием «если запись не касается ни одного дела из списка; если касается — о других делах не говорить».
  - Контроллер: `offer` реплике `diary` — `"name"` безусловный → id выбранных; условный — только если `task` ответа `""`; `"themes"` — так же, значение `"themes"`. Лог: `riddle: rhythm mode=<mode> n=<k>`.

- [ ] **Step 1: Тесты (падают)** — `rhythm_spec`: `test_first_entry_names_tasks`, `test_first_entry_without_tasks_gives_themes`, `test_third_unrelated_is_drift_sixth_is_name` (марки 2 → `drift`, 5 → `name`), `test_after_offer_count_restarts_9_drift_12_name` (последовательность 1…12 несвязанных с offer на 6 → `drift` на 9, `name` на 12), `test_task_entry_resets_and_drift_does_not`, `test_unknown_does_not_count`, `test_no_titles_no_themes`, `test_pick_skips_offered_then_oldest_offered` (5 открытых, предложены 1,2 → 3,4,5), `test_pick_rotates_by_last_offer` (5 открытых, четыре предложения подряд: {1,2,3} → {4,5} → {1,2,3} → {4,5,1}; по первому показу четвёртое было бы снова {1,2,3}, а 4 и 5 не вернулись бы никогда), `test_pick_skips_offered_now_closed` (предложены 1–5, задача 1 закрыта и выпала из `items` → 1 не выбрана), `test_rhythm_requires_no_source_module` (тексты `rhythm.lua`, `controller.lua`, `prompt.lua` без `require("riddle.notion`, `riddle.sync`, `riddle.classify` — м9). `prompt_spec`: `test_mode_line_in_last_user_message_not_system`, `test_conditional_mode_line_mentions_condition`, `test_mode_texts_stay_in_role` (без «Notion», «статус», «поле», «таблиц», «баз»; гард `no_event_spec` зелёный). `controller_memory_spec`: `test_first_answer_marks_offer_ids`, `test_conditional_offer_marked_only_if_task_empty`, `test_themes_offer_marked`, `test_without_tasks_themes_first_and_sixth` (`ctx` без `block`, `titles` есть, ответы модели без поля `task`: 1-я запись сессии — `themes`; записи 2–6 — `none` (намёка без задач нет, вопрос 2); 7-я — 6-я несвязанная после 1-й — `themes`; у всех `owner` `task = ""`), `test_rhythm_off_without_marks` (`marks` = nil → режим `none`, строки режима в user нет, `offer` не пишется, ответ есть).
- [ ] **Step 2:** `tests/run.sh` — FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** `tests/run.sh` — OK.
- [ ] **Step 5:** Kindle (пауза > 4 ч или новая сессия): 1-я запись «привет» → ответ в образе с 1–3 задачами; 2 записи о задаче → другие не предлагаются; 3 несвязанных → намёк; ещё 3 → другие задачи; лог `rhythm mode=…`.
- [ ] **Step 6: Commit** `feat(tasks): ритм напоминаний о задачах и темах`.

### Срез 6: Классификация баз моделью при синхронизации

Результат: без `tasks_source` дневник сам находит базу задач: при изменении схемы баз синхронизация один раз спрашивает модель, какие базы — задачи, какие варианты select и чекбоксы значат «сделано/отменено», что значит «архив», какое свойство — проект и срок, какая база — база задач (`model_pick`). Правила сохраняются; без изменения схемы модель не вызывается.

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/classify.lua`
- Modify: `plugin/riddlediary.koplugin/riddle/notion_tasks.lua` (правила из классификации), `plugin/riddlediary.koplugin/riddle/sync.lua`
- Modify: `plugin/riddlediary.koplugin/main.lua:121-166` (`classify` в `sync.run`, логи цепочки из payload)
- Test: `tests/classify_spec.lua` (новый), `tests/notion_tasks_spec.lua`, `tests/sync_spec.lua`

**Interfaces:**
- Consumes: `llm.find_object` (срез 3); `app.chain(d):remote_fn(messages, false, {max_tokens = 1500})()` — в дочернем, в своём процессе (`app.lua:245-255`).
- Produces:
  - `notion_tasks.schema(src) -> {props = {{name, type, options = {…}, groups = {…}}…}}` только для свойств `status`, `select`, `checkbox`, `relation`, `date`; базы без status/select/checkbox — не в классификации. `notion_tasks.schema_hash(list) -> hex` (FNV-1a 32 по `json.encode` упорядоченной схемы: `id` базы и её `props`; `items` и `title` в хэш не входят — м8: иначе каждая новая строка или переименование базы запускали бы классификацию; `items` и `title` идут только в сообщение модели).
  - Правила архива (`archive_select`, `archive_checkbox`) классификация отдаёт для **всех** баз схемы, не только кандидатов (м6): база проектов обычно не кандидат. `notion_tasks.row_archived(row, rules) -> bool` — для любой строки синхронизации; `task()` по-прежнему строится только для кандидатов, а «цель relation есть среди строк синхронизации — по её `archived`» (срез 4) = `row_archived(строка цели, rules_by_id[её база])`.
  - `classify.messages(schemas) -> messages` — system: задача и формат ответа; user: JSON `[{c = "c1", title, items, props}…]`.
  - `classify.parse(text, schemas) -> {rules_by_id, pick_id | nil} | nil, err`. Ответ модели: `{"collections":[{"c":"c1","tasks":true,"closed_select":{"prop":"…","options":["…"]},"done_checkbox":"…","archive_select":{"prop":"…","options":["…"]},"archive_checkbox":"…","project":"…","due":"…"}],"pick":"c1"}`; свойства и варианты не из схемы, `pick` не кандидат — отброшены.
  - `sync.run{…, classify = fn(messages) -> text | nil, err, logs}`; хэш всех схем совпал с `meta` `cls_hash` — правила из `meta` `cls:<id>` и `cls_pick`; не совпал — `classify`, удача → записать правила и хэш, сбой/нет `classify` → старые правила, хэш не пишется (повтор в следующий раз). `model_pick = (id == pick_id)`, `task_candidate = rules.tasks == true`.
  - `stats.classify = "ok" | "skip" | "fail"`, `stats.llm_logs` (≤ 20 строк, каждая уже через `mask`); родитель пишет их в лог; строка `riddle: classify <ok|skip|fail> candidates=<n> pick=<yes|no> in <ms> ms`.

- [ ] **Step 1: Тесты (падают)** — `classify_spec`: `test_messages_carry_schema_not_rows`, `test_parse_valid_answer`, `test_parse_drops_unknown_props_and_options`, `test_parse_pick_must_be_candidate`, `test_parse_garbage_is_error`. `notion_tasks_spec`: `test_closed_select_option_closes`, `test_done_checkbox_closes`, `test_archive_option_archives_task`, `test_project_row_archived_archives_its_tasks` (база проектов — не кандидат, у неё только `archive_select`; строка проекта с этим вариантом → задачи кандидата с relation на неё `archived`), `test_status_open_checkbox_done_is_closed` (м13: status в группе `In progress`, `done_checkbox` отмечен → `open = false`), `test_due_from_rules`, `test_schema_hash_ignores_items_and_title`. `sync_spec`: `test_classify_called_once_per_schema` (два прогона, одна схема → один вызов; схема изменилась → второй), `test_classify_failure_keeps_rules_and_retries`, `test_model_pick_without_config_selects_collection` (через `tasks.pick_source` → `why = "model"`), `test_stats_payload_under_worker_cap` (20 строк логов по 200 знаков → `json.encode(stats)` < `worker.MAX_PAYLOAD`).
- [ ] **Step 2:** `tests/run.sh` — FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** `tests/run.sh` — OK.
- [ ] **Step 5:** оркестратор заливает конфиг без `RIDDLE_TASKS_SOURCE`; деплой; первая sync — `classify ok candidates=… pick=yes`, следующая — `classify skip`; ответ на «привет» новой сессии называет задачи нужной базы; ответ во время классификации вытесняет sync — в следующую sync `classify ok`.
- [ ] **Step 6: Commit** `feat(notion): классификация баз задач моделью при изменении схемы`.

### Срез 7: Слово пользователя о базе

Результат: пользователь пишет, где его дела, — дневник запоминает выбор (таблица `core`), блок задач меняется со следующего ответа без синхронизации; повторное слово перезаписывает, «ищи сам» стирает; не нашлось или неоднозначно — дневник в образе переспрашивает.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/prompt.lua` (список названий баз и правило `tasks_source`)
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua` (`_answer`)
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua` (`app.set_tasks_source`, dep)
- Modify: `plugin/riddlediary.koplugin/riddle/texts.lua` (пул `tasks_source_unclear`)
- Test: `tests/prompt_spec.lua`, `tests/controller_memory_spec.lua`, `tests/app_spec.lua`, `tests/texts_spec.lua`

**Interfaces:**
- Consumes: `ctx.titles` (срез 3), `tasks.match_title` (срез 2), `K:set_core`.
- Produces:
  - `prompt.open`: при `ctx.titles` — раздел `TITLES_HEAD .. "\n" ..` названия собраний пишущего и правило: назвал, где его дела, — `"tasks_source":"<название из списка>"`; просит искать самому — `"tasks_source":"reset"`; иначе — `"tasks_source":""` (ключ в каждом ответе; пример ответа один, со всеми ключами — `prompt.ANSWER_FORMAT`). Место раздела — сразу после блока задач (блока нет — сразу после знаний), до пересказов: меняется только синхронизацией, как блок (описание, «Кэш»).
  - `prompt.fit` (Б5): `TITLES_HEAD` — в концах обоих `cut` (`prompt.lua:180-181`): знаний — `{TASKS_HEAD, TITLES_HEAD, SUMMARIES_HEAD, READ_FORMAT}`, лора — `{KNOWLEDGE_HEAD, TASKS_HEAD, TITLES_HEAD, SUMMARIES_HEAD, READ_FORMAT}`. Без этого при блоке `nil` (базы не выбрано — ровно когда пользователь её и называет) `cut` знаний срезал бы раздел названий вместе с хвостом знаний, и у Groq слово о базе не запомнилось бы.
  - `app.set_tasks_source(d) -> fn(id | nil) -> true | nil, err` (открыть, `set_core("tasks_source", id)`, закрыть).
  - Контроллер: `tasks_source == nil`, значение без букв и цифр (`""`, `-`, `—`) или «ничего» словами (`NO_WORD`: `нет`, `none`, `null`, `n/a`, …) — ничего; `fold == "reset"` → `set(nil)`, лог `riddle: tasks source cleared`; иначе `tasks.match_word(ctx.collections, value)` (равенство fold, затем целые слова; `match_title` с подстрокой — только для конфига): нашлась → `set(id)`, лог `riddle: tasks source set`; `many` → не запоминать, ответ = `pick(texts.tasks_source_unclear)`; `none` → не запоминать, ответ модели как есть; лог `riddle: tasks source unclear (<none|many>)`. `set` вернул ошибку (м10: база занята синхронизацией дольше `busy_timeout = 2000`, `knowledge.lua:89`) — выбор не запомнен, ответ модели остаётся как есть, лог `riddle: tasks source set failed: <mask>`; повторить слово пользователь может следующей записью.
  - `texts.tasks_source_unclear` — ≥ 10 фраз, 1 предложение, в образе, без рода, без слов «база», «Notion», «таблица».

- [ ] **Step 1: Тесты (падают)** — `controller_memory_spec`: `test_word_sets_source_and_next_answer_uses_it` (без sync: следующий `tasks_context` → `via=user`), `test_repeat_word_overwrites`, `test_empty_word_clears_choice`, `test_unclear_word_asks_again_and_keeps_choice` (два похожих названия → ответ из пула, `core` прежний), `test_word_may_name_non_candidate`, `test_set_failure_keeps_answer_and_choice` (поддельный `set` → `nil, "database is locked"` → ответ модели, `core` прежний, лог `tasks source set failed`). `app_spec`: `test_set_tasks_source_roundtrip`. `prompt_spec`: `test_titles_section_and_rule_only_with_titles`, `test_titles_section_after_tasks_before_summaries`, `test_fit_keeps_titles_section` (знание 20 000 знаков, блока нет, `titles` есть, `fit(m, 8000)` → раздел названий и правило `tasks_source` целиком, знание урезано), `test_titles_texts_stay_in_role` (`TITLES_HEAD` и правило без «Notion», «статус», «поле», «таблиц», «баз»). `texts_spec`: `test_tasks_source_unclear_pool_clean` (как `test_unreadable_30_unique_short_clean`, без запретных слов).
- [ ] **Step 2:** `tests/run.sh` — FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** `tests/run.sh` — OK.
- [ ] **Step 5:** Kindle: написать название другой базы как «мои дела — там» → лог `tasks source set`, следующий ответ — `via=user`; «найди сам» → `cleared`, `via=model|depth`; неясное название → переспрос в образе.
- [ ] **Step 6: Commit** `feat(tasks): слово пользователя о базе задач`.

---

## Вопросы оркестратору (расхождения и пробелы описания)

1. **Признак «база задач» (ASSUMPTION 1 опровергнут):** в API есть только `database_type` («typed database», пример `"skills"`, у владельца `null` везде). План: `native_tasks` всегда «нет». Брать ли будущее непустое `database_type` как признак — не решено.
2. **3-я запись без задачи, когда незакрытых задач нет:** описание даёт темам только 1-ю запись и 6-е сообщение; намёк «отклонились» без задач не о чем делать. План: `"none"`.
3. **Условные режимы** (раздел «Решения плана»): описание говорит «режим считает контроллер»; план считает счёт контроллером, а условие «если запись не о задаче» отдаёт модели — иначе 3-я несвязанная запись намёк не получит.
4. **Архивный проект через `GET /v1/pages` (ASSUMPTION 4, ревью Б7) — ждёт решения владельца.** Если на страницу в корзине API отвечает 404, по описанию это «не архив», и задачи такого проекта будут названы незакрытыми. Варианты: живая проверка записью в Notion владельца (создать тестовую страницу → в корзину → `GET` → удалить) или явное принятие риска. Срез 4 делается без этой ветки, она — шаг 3b после решения. Сейчас у владельца путь не срабатывает ни разу (0 целей relation вне поиска).

### Ревью плана: что не внесено

- **м5** (неясное слово о базе заменяет весь ответ модели фразой из пула) — не внесено: описание прямо велит «дневник в образе переспрашивает»; дописывание переспроса к ответу упирается в длину страницы на Kindle, а неясность редка (модель берёт название из списка). Решать после живой проверки среза 7.
