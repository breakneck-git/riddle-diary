# Свёртка выпавшего из окна разговора внутри сессии — план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** реплики текущей сессии, выпавшие из окна истории, модель видит в виде краткого пересказа перед историей.

**Architecture:** новая таблица `rollups` (миграция 4) хранит по сессии один пересказ и id последней свёрнутой
реплики. Когда несвёрнутых реплик набирается на целое окно, контроллер просит у фонового worker'а («summary»,
тот же путь, что пересказ прошлой сессии) свернуть старейшие 20 реплик вместе с прежним пересказом. Ответ на
страницу свёртку не ждёт; пока её нет — всё как сейчас.

**Tech Stack:** Lua (LuaJIT), KOReader-плагин, SQLite (`lua-ljsqlite3`), тесты `tests/run.sh`.

**Spec:** задача Notion 40413e60-bc8d-8125 «Сворачивать выпавший из окна разговор в пересказ внутри сессии»
(решение владельца 2026-10-28 «да»); общая спека — `docs/superpowers/specs/2026-10-22-riddle-diary-design.md`.

## 1. Как сейчас (факты, HEAD 5749dbf)

| Что | Факт | Источник |
|---|---|---|
| Окно истории | `prompt.MAX_RECENT = 40` реплик (12 → 40 в 9056da1, коммит в main) | `riddle/prompt.lua:7`; `git merge-base --is-ancestor 9056da1 HEAD` — да |
| Чтение окна | `memory:recent(sid, prompt.MAX_RECENT)` — последние N реплик сессии по id | `riddle/controller.lua:159`, `riddle/memory.lua:193-197` |
| Граница сессии | `SESSION_GAP_S = 4 * 3600`; новая сессия, если с последней записи > 4 ч | `riddle/memory.lua:6`, `:131` |
| Порядок системного сообщения | персона → лор → знание + правила совета → задачи → названия книг → пересказы прошлых сессий → READ_FORMAT → форматы ответа → `HISTORY_HEAD` (последним); дальше реплики истории, последней — картинка | `riddle/prompt.lua:291-345` |
| `prompt.fit` (лимит знаков провайдера) режет по порядку | знание → лор → старые реплики истории (кроме последних `FIT_KEEP_RECENT = 6`) → пересказы прошлых сессий целиком, со старых → названия книг → дела блока до одного → укорачивание оставшихся реплик до `FIT_REPLY_MIN_CHARS = 300` | `riddle/prompt.lua:413-416`, `:432-604` |
| Лимит входа | только у Groq: `max_input_chars = 10000`; цепочка: gemini-proxy → прямой Gemini (`gemini-3.5-flash-lite`) → Groq → BeatAPI | `tools/push_config.sh:80-104`, `riddle/llm.lua:105` |
| Пересказ прошлой сессии: когда | хвост разблокировки: с печатью — после открытия, без печати — после первого ответа после старта и после каждого сна (`take_followup`) | `riddle/controller.lua:586-600`, `riddle_diarywidget.lua:422`, `:1299` *(слово заменено ключом, см. spec 2026-11-20)* |
| … как | `_summary_job` берёт самую свежую прошлую сессию без пересказа (`memory:session` второе значение), все её реплики → `prompt.summarize` | `riddle/controller.lua:522-532`, `riddle/memory.lua:137-141` |
| … чем | та же цепочка провайдеров, что ответ; в дочернем процессе через `remote_fn` (бюджет `ANSWER_BUDGET_S = 25`, попытка 12 с), `max_tokens = 800`, потолок дочернего `ceil_s = 30` | `riddle/controller.lua:19`, `:544`, `:562-573`; `riddle/app.lua:15-18`, `:356-366`; `riddle_diarywidget.lua:100`, `:520` |
| … куда | `sessions.summary`; в промпт — 5 последних (`SUMMARIES_N = 5`) | `riddle/memory.lua:204-216`, `riddle/controller.lua:16`, `:150-153` |
| … сбой | таймаут, вытеснение ответом, ошибка — не сохраняется, спросится в следующий хвост | `riddle/controller.lua:575-584` |
| Отмена фоновой | ответ вытесняет «summary»; штрих пера и сон её убивают | `riddle/worker.lua:123-131`, `riddle_diarywidget.lua:894-897`, `:609` |
| Синхронный путь без runner | `on_unlocked_followup` ждёт пересказ в цикле интерфейса до `BUDGET_S = 8` | `riddle/controller.lua:548-557`, `riddle/app.lua:12` |
| Правило пересказа сессии | «без рода, без имени и без обращений по роли», 2–3 предложения | `riddle/prompt.lua:606-617` (введено в bf459da) |
| Подсказка истории | «Опирайся на сказанное: имя того, кто пишет, …» | `riddle/prompt.lua:177-178` |
| Схема памяти | `sessions(id, started, last_ts, summary)`, `entries(id, session_id, ts, role, text, task, offer)`, `lore(section, text, mtime)`; `PRAGMA user_version`, сейчас **3** (метки задач) | `riddle/memory.lua:10-32` |
| Миграции | по шагам `MIGRATIONS[v]`, каждый шаг + версия — одной транзакцией; сбой — строка лога `riddle: memory migrate failed`, база открывается как есть | `riddle/memory.lua:80-110` |
| Отсутствие колонки миграции 3 | функции ловят «no such column» и выключают ритм, дневник отвечает | `riddle/memory.lua:112-116`, `:165-185` |
| База на Kindle | `/mnt/us/riddle/diary.sqlite3` | `main.lua:18` |
| Конверт дочернего | ≤ `MAX_PAYLOAD = 32768` байт; один дочерний за раз | `riddle/worker.lua:2`, `:13` |
| В лог Kindle | содержимое записи не пишется, только длины | `riddle/controller.lua:466-469` |
| Тесты сейчас | `tests/run.sh` → «43 specs, OK» | вывод команды 2026-10-28 |

Поправка к задаче Notion: «миграция diary v3» занята метками задач (`riddle/memory.lua:24-31`) — здесь шаг **4**.

## 2. Дизайн

**Когда сворачивать.** U — несвёрнутые реплики сессии (id > `upto`). Свёртка нужна, когда `U ≥ ROLL_AT =
prompt.MAX_RECENT` (40): окно целиком из несвёрнутых, следующая пара реплик выпадет. Сворачиваются старейшие
`ROLL_BATCH = 20` несвёрнутых. Так при успешных свёртках выпавших несвёрнутых нет вовсе: окно (40) всегда покрывает
все U ≤ 40. Цена — до 20 реплик одновременно в пересказе и в окне (пересказ ≤ 1500 знаков, безвредно). Порог в
репликах, не в знаках: окно тоже в репликах. Вызов модели — раз в 10 страниц, первый — на 20-й странице сессии.

**Чем.** Тот же хвост («followup») и worker «summary»: `take_followup` возвращает true и тогда, когда свёртка
назрела (флаг `roll_due` ставится после записи ответа), виджет зовёт `scheduleFollowup` → `begin_followup`, без
изменений в виджете. В `_summary_job` пересказ прошлой сессии идёт первым, свёртка — если его нет. Ответ на
страницу вытесняет свёртку (как сейчас пересказ). В синхронном пути без runner свёртки нет: иначе цикл интерфейса
ждал бы до 8 с каждые 10 страниц.

**Запрос свёртки.** `prompt.roll(earlier, entries)`: прежний пересказ + 20 реплик → один пересказ до 8 предложений.
В отличие от пересказа прошлой сессии, сохраняет, как пишущий назвал себя сам (так же, как `HISTORY_HEAD` велит
опираться на «имя того, кто пишет»), кто он дневнику по его словам, о чём договорились. Без рода пишущего и без
обращений по роли — как везде. `max_tokens = 1200` (пересказ длиннее 2–3 предложений, с рассуждением модели).
Сохранённый текст — в одну строку (`one_line`) и не длиннее `ROLL_MAX_CHARS = 1500` знаков.

**Где хранить.** Таблица `rollups(session_id INTEGER PRIMARY KEY, upto INT NOT NULL, text TEXT NOT NULL, ts INT)`
шагом `MIGRATIONS[4]` (`SCHEMA_VERSION = 4`), не в `SCHEMA`: сбой создания (например, полный диск) не роняет
`Memory.open` (`riddle/memory.lua:102-106` — ошибка `SCHEMA` закрывает базу), а только выключает свёртку.
Таблица, а не колонки `sessions`: миграция не трогает ни одной существующей строки, без `ALTER` живой таблицы.
`set_rollup` пишет, только если новый `upto` больше сохранённого: запоздалый ответ не откатит свёртку.

**Старая база на Kindle.** Шаг 4 — один `CREATE TABLE`, в транзакции с `user_version = 4`
(`riddle/memory.lua:84-94`): сессии, реплики, лор не меняются. Сбой — откат шага, строка лога, дневник отвечает
без свёртки.

**Откат.** Деплой прежнего sha: код с `SCHEMA_VERSION = 3` на базе с `user_version = 4` миграций не делает (цикл
`for v = version + 1, SCHEMA_VERSION` пуст, `riddle/memory.lua:83`), лишнюю таблицу не читает — дневник работает как
до плана. Ручного отката базы не нужно.

**В промпте.** Раздел `prompt.ROLLING_HEAD .. "\n" .. текст` — последним перед `HISTORY_HEAD` (хронология:
пересказ начала → разговор). `prompt.fit` срезает его целиком после пересказов прошлых сессий и до названий книг:
своя сессия ценнее прошлых, форматы задач нужнее пересказа.

**Офлайн и отказ модели.** Пересказа нет — промпт как сейчас. Неудача свёртки (кроме «cancelled»; пустой текст
после `roll_text` — тоже неудача, решение оркестратора 2026-10-28) — в памяти
контроллера пауза: следующая попытка, когда U вырастет на `ROLL_RETRY = 6` (3 страницы), иначе при суточном 429
каждый ответ тратил бы второй вызов. «cancelled» (перо, сон, вытеснение) — снова после следующего ответа. Пауза
только в RAM: после перезапуска — сразу.

## 3. Риски

- **Данные пишущего.** Миграция только добавляет таблицу; всё равно перед первым деплоем среза 1 — копия
  `/mnt/us/riddle/diary.sqlite3` на Mac (тестер, шаг в задаче 1). Восстановление — вернуть копию при выключенном
  дневнике.
- **Квота.** +1 вызов на 10 страниц (≈ +10 % к ответам; при 30 страницах в час — 3 вызова в час), вход ≤ ~1500 + 20
  реплик. При паузе после отказа — не чаще раза в 3 страницы. Без свёрток (короткие сессии) — 0.
- **Память Kindle.** Тот же один дочерний `fork`, что у ответа и пересказа (`riddle/worker.lua:2`), конверт ≤ 32 КБ;
  в базе ≤ 1 строка на сессию (~3 КБ).
- **Перо гасит свёртку.** Штрих отменяет «summary» (`riddle_diarywidget.lua:894-897`); если пишут без пауз, свёртка
  может не успевать, и U растёт сверх окна — выпавшее снова не видно (не хуже, чем сейчас). Тестер замеряет по
  логу; лечение (свёртка в паузу, приоритет) — отдельной задачей по замеру.
- **Пересказ сессии и имя.** Прошлые сессии по-прежнему пересказываются «без имени» (`riddle/prompt.lua:609`):
  имя переживает окно, но не границу сессии — вопрос оркестратору ниже.

## 3а. Поправки по живому прогону (2026-10-28)

- **Окно пересказов прошлых сессий (9ff892b).** `Memory:session(now, window)` предлагает на пересказ только
  самую свежую без пересказа среди последних `SUMMARIES_N` (5) прошлых сессий с репликами; старше не
  пересказываются никогда — в промпт они всё равно не попадают (`Memory:summaries`, LIMIT 5). Причина: в живой базе
  было 15 старых сессий без пересказа, хвост пересказывал их по одной раньше свёртки, свёртка ждала ~15 страниц.
- **Хвост, поднятый свёрткой (8591229).** Любой сбой его задания (и `session`, и `roll`), кроме «cancelled», —
  пауза `ROLL_RETRY`; без runner `roll_due` хвоста не поднимает.
- **Живая проверка.** `feed=N` идёт синхронным `on_page` и хвостов не поднимает — свёртку и пересказ на Kindle
  проверять страницами виджета (`cycles=N samples=1`).

## 4. Вариант D (SESSION_GAP_S 4 ч → 30–60 мин) — нет

- В целевом случае разговор идёт часами без пауз ≥ 30 мин — граница не наступает (`riddle/memory.lua:131`), D
  ничего не даёт.
- На границе пересказ сессии — 2–3 предложения «без имени» (`riddle/prompt.lua:609`): имя и «я тебя создал» теряются
  и с D.
- В промпт идут 5 пересказов (`riddle/controller.lua:16`): короткие сессии быстрее вытесняют старую память.
- Ритму задач D не нужен: у него своя пауза 1 ч внутри сессии (`riddle/rhythm.lua:12-14`).

Не вместо и не в дополнение. Вернуться — если после свёртки замер покажет, что прошлые сессии всплывают слишком редко.

## Global Constraints

- Содержимое записей и пересказов в лог Kindle не пишется — только числа (`riddle/controller.lua:466-469`).
- О пишущем — без рода и без обращений по роли (`riddle/prompt.lua:609-610`); дневник о себе — в мужском роде.
- Ответ на страницу не ждёт свёртки и не ломается от её сбоя: каждый вызов памяти для свёртки — под `pcall`,
  сбой — свёртки нет, строка лога.
- Тесты — `tests/run.sh`, все зелёные перед каждым коммитом. Коммит — в main клона, без push.

## Review Focus

1. Запоздалая свёртка (ответ дочернего пришёл после следующей) не откатывает `upto` — тест `test_set_rollup_keeps_newest` (задача 1).
2. Модель вернула пустой, многострочный или очень длинный текст — пустой не сохраняется, остальное — одна строка ≤ 1500 — `test_roll_text_one_line_capped` (1), `test_roll_empty_not_saved` (2).
3. Миграция 4 не прошла (нет таблицы) — дневник отвечает как сейчас, свёртка не зовётся — `test_rollups_missing_table_off` (1), `test_roll_off_without_table` (2).
4. Сессия сменилась, пока свёртка в пути — сохраняется в свою (старую) сессию по `job.sid`, в новую не попадает — `test_roll_saved_to_job_session` (2).
5. Свёртка ведёт к лишним вызовам при отказах — пауза `ROLL_RETRY` — `test_roll_failure_holds_until_retry` (2).

---

## Срез 1 (задача 1): память и промпт свёртки

~120 строк кода + ~150 тестов. Поведение на устройстве не меняется (свёрток ещё никто не пишет): деплой проверяет
только миграцию живой базы.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/memory.lua` (шаг 4, три метода)
- Modify: `plugin/riddlediary.koplugin/riddle/prompt.lua` (`ROLLING_HEAD`, `ROLL_MAX_CHARS`, `roll_text`, `roll`, раздел в `open`, срез в `fit`)
- Test: `tests/memory_spec.lua`, `tests/prompt_spec.lua`

**Interfaces — Produces:**
- `Memory:rollup(sid) -> text | nil, upto` — нет строки: `nil, 0`; нет таблицы: `nil, nil` и строка лога `riddle: memory rollups unavailable` (не чаще раза на открытие).
- `Memory:unrolled(sid, limit) -> list, total | nil` — `list` — `{ { id, role, text } … }` с id > upto, старые первыми, не больше `limit` (`nil` — все); `total` — число всех несвёрнутых; нет таблицы — `nil`.
- `Memory:set_rollup(sid, text, upto, now) -> true | false` — false: `upto` не больше сохранённого или нет таблицы.
- `prompt.ROLLING_HEAD = "Раньше в этой сессии (пересказ; разговор ниже его продолжает):"`
- `prompt.ROLL_MAX_CHARS = 1500`; `prompt.roll_text(s) -> строка` (`one_line`, затем `utf8_head` до `ROLL_MAX_CHARS`; пустая/пробельная → `""`).
- `prompt.roll(earlier, entries) -> messages` (system + user, без картинки и `response_format`).
- `prompt.open(png, ctx)`: новое поле `ctx.rolling` (строка | nil).

- [ ] **Шаг 1: снять копию живой базы (тестер, до любого деплоя этого среза)**

`scp kindle:/mnt/us/riddle/diary.sqlite3 ~/riddle-backup/diary-2026-10-28.sqlite3` и
`sqlite3 ~/riddle-backup/diary-2026-10-28.sqlite3 "PRAGMA user_version; SELECT COUNT(*) FROM entries; SELECT COUNT(*) FROM sessions"` — ожидается `3` и два числа; записать их в отчёт.

- [ ] **Шаг 2: тесты памяти (падают)** — `tests/memory_spec.lua`:

```lua
function tests.test_migration_v4_adds_rollups()      -- новая база: user_version 4; база v3 (сессия и 2 реплики с task/offer, PRAGMA user_version = 3 — по образцу строк 490-500) доведена до 4, реплики и сессии на месте (те же COUNT и тексты)
function tests.test_rollup_empty_session()            -- rollup(sid) == nil, 0; unrolled(sid, 20) -> {}, 0
function tests.test_unrolled_after_upto()              -- 30 реплик, set_rollup(sid, "П", id10, now): unrolled(sid, 5) -> ids 11..15, total 20; rollup -> "П", id10
function tests.test_set_rollup_keeps_newest()          -- set_rollup(.., id20) затем (.., id10) -> false; rollup -> upto id20, прежний текст
function tests.test_rollups_per_session()              -- свёртка сессии 1 не видна в сессии 2
function tests.test_rollups_missing_table_off()        -- DROP TABLE rollups: rollup -> nil, nil; unrolled -> nil; set_rollup -> false; add/recent работают; в логе одна строка "riddle: memory rollups unavailable"
function tests.test_migration_v4_failure_logs_and_opens() -- по образцу test_migration_failure_logs_and_opens (строки 104-123): шаг 4 сорван — user_version 3, база открыта
```

Существующие проверки `user_version == 3` (`tests/memory_spec.lua:74`, `:87`, `:155`, `:456`, `:462`) → 4.

- [ ] **Шаг 3:** `tests/run.sh` — FAIL на новых тестах.

- [ ] **Шаг 4: реализация в `memory.lua`.** `SCHEMA_VERSION = 4`; `MIGRATIONS[4] = { "CREATE TABLE IF NOT EXISTS rollups(session_id INTEGER PRIMARY KEY, upto INT NOT NULL, text TEXT NOT NULL, ts INT)" }`; строка в комментарии версий: «4: свёртка выпавшего из окна внутри сессии: rollups — пересказ и id последней свёрнутой реплики». `no_table(err)` — «no such table» по образцу `no_column`. `set_rollup` — без upsert (`ON CONFLICT DO UPDATE` требует SQLite ≥ 3.24, версия в KOReader на Kindle не проверялась): в `BEGIN`/`COMMIT` прочитать `upto`; строки нет — `INSERT`, `upto` меньше нового — `UPDATE`, иначе `false`. `unrolled` — `id > COALESCE((SELECT upto FROM rollups WHERE session_id = ?), 0)`, `LIMIT ?` (`-1` при `nil`), total — отдельным `COUNT(*)`.

- [ ] **Шаг 5:** `tests/run.sh` — PASS.

- [ ] **Шаг 6: тесты промпта (падают)** — `tests/prompt_spec.lua`:

```lua
function T.test_rolling_section_before_history()   -- ctx.rolling = "СВЁРТКА-МАРКЕР", recent из 2 реплик: в system есть ROLLING_HEAD .. "\nСВЁРТКА-МАРКЕР", его позиция < позиции HISTORY_HEAD и > позиции ANSWER_FORMAT
function T.test_rolling_absent_without_text()      -- ctx.rolling nil и "" — ROLLING_HEAD нет
function T.test_rolling_multiline_is_one_line()    -- ctx.rolling = "а\n\nб" -> в system "а б", нет "\n\n" внутри раздела
function T.test_fit_drops_rolling_after_summaries() -- контекст как в test_fit_trims_oldest_summaries_after_history (строка 902) + rolling 1500 знаков; лимит, при котором уходят все пересказы и ещё мало: пересказов нет, ROLLING_HEAD нет, названия книг и дела блока на месте; лимит, при котором хватает срезать пересказы: ROLLING_HEAD на месте
function T.test_roll_text_one_line_capped()        -- roll_text("  \n ") == ""; roll_text("а\nб") == "а б"; roll_text(rep("я", 2000)) — 1500 знаков (utf8)
function T.test_roll()                              -- prompt.roll("ПРЕЖНЕЕ", {owner "ЗАП", diary "ОТВ"}): в dump есть "ПРЕЖНЕЕ", "Запись: ЗАП", "Дневник: ОТВ", "как пишущий назвал себя", "без рода"; нет "хозяйк", "image_url", "response_format"; prompt.roll(nil, …) — без строки прежнего пересказа
```

Ещё: в `tests/no_event_spec.lua` четыре таблицы промптов гардов (строка `summarize = …` у каждой: 237, 308, 383, 489) — добавить рядом `roll = prompt.roll(nil, { { role = "owner", text = "x" } })[1].content`, чтобы гарды голоса и повторов покрывали и его.

- [ ] **Шаг 7:** `tests/run.sh` — FAIL на новых.

- [ ] **Шаг 8: реализация в `prompt.lua`.** Раздел `rolling` — в `open` сразу перед строкой `if #recent > 0 then parts[#parts + 1] = HISTORY_HEAD end` (`prompt.lua:328`), текст через `one_line`. В `fit` — после блока пересказов (`prompt.lua:525-540`) и определений `section`/`drop_span` (`:542-550`), до цикла названий книг (`:551`): `section(prompt.ROLLING_HEAD)` → `drop_span` целиком, если `over > 0`. Системное сообщение `prompt.roll` — как в коде fe7a20c (первый вариант плана валили гарды рода `no_event_spec`:
прошедшее время и «он/его» о пишущем; о пишущем — только настоящее время и без местоимений):

```
Ты — магический дневник. Тебе дают реплики разговора и, если есть, пересказ того, что было до них. Сверни всё в один пересказ до 8 предложений от своего лица, о себе в мужском роде. Сохрани то, на что опираться дальше: как пишущий называет себя сам, кем приходится тебе по собственным словам, что рассказывает о себе, о чём вы договорились и о чём тебя просили. О том, кто пишет, — без рода и без обращений по роли. Только текст пересказа, без заголовков и без markdown.
```

User: `"Пересказ до этого: " .. earlier .. "\n\n"` (если `earlier` непуст) и строки `"Запись: "`/`"Дневник: "`, как в `prompt.summarize`.

- [ ] **Шаг 9:** `tests/run.sh` — «specs, OK».

- [ ] **Шаг 10: коммит** — `git add plugin/riddlediary.koplugin/riddle/memory.lua plugin/riddlediary.koplugin/riddle/prompt.lua tests/memory_spec.lua tests/prompt_spec.lua tests/no_event_spec.lua && git commit -m "feat(memory): таблица rollups (миграция 4) и раздел свёртки сессии в промпте (Notion 40413e60-bc8d-8125)"`

**Тестер на Kindle (после шага 1):** деплой, перезапуск; в `crash.log` нет `riddle: memory migrate failed`; копия базы с устройства: `PRAGMA user_version` = 4, `.schema rollups` есть, `COUNT(*)` entries и sessions — не меньше, чем в шаге 1; одна страница — ответ как обычно.

---

## Срез 2 (задача 2): свёртка в работе

~80 строк кода + ~170 тестов.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua`
- Test: `tests/controller_memory_spec.lua` (настоящая SQLite), `tests/async_answer_spec.lua` (виджет + фейковый runner), `tests/controller_spec.lua` (флаги)

**Interfaces:**
- Consumes: всё из Produces задачи 1.
- Produces: `Controller.ROLL_AT = prompt.MAX_RECENT`, `Controller.ROLL_BATCH = 20`, `Controller.ROLL_MAX_TOKENS = 1200`, `Controller.ROLL_RETRY = 6`; job свёртки `{ kind = "roll", sid, upto, total, messages, opts = { max_tokens = ROLL_MAX_TOKENS } }`, job пересказа сессии получает `kind = "session"`, `opts = SUMMARY_OPTS`.

- [ ] **Шаг 1: тесты (падают).** В `controller_memory_spec.lua` `make()` дополнить `remote_fn = function(m, wj, opts) return function() return { result = table.remove(env.script, 1) } end end` с записью вызова в `env.calls`, `absorb = function(p) return p.result, p.err end`; страница без печати — конфиг без `password_variants` (как `test_no_password_followup_due_after_start_and_sleep`, `tests/controller_spec.lua:676`) или открыть печать первой страницей. *(слово заменено ключом, см. spec 2026-11-20)*

```lua
function T.test_roll_due_when_window_full()        -- 19 страниц (38 реплик): take_followup ложь (после первого раза); 20-я: истина; begin_followup -> job.kind "roll"
function T.test_roll_job_folds_oldest_batch()      -- 20 страниц "З1".."З20": messages job — реплики З1..З10 (20 шт.), нет З11; job.upto — id 20-й реплики; total 40
function T.test_roll_saved_and_reaches_prompt()    -- finish_followup(job, {result={text="СВЁРТКА\nДВА"}}) -> memory:rollup == "СВЁРТКА ДВА", upto; следующая страница: в system ROLLING_HEAD и "СВЁРТКА ДВА"
function T.test_roll_second_includes_earlier()     -- ещё 10 страниц: второй job — "Пересказ до этого: СВЁРТКА ДВА" + реплики З11..З20
function T.test_roll_empty_not_saved()             -- result.text "" или "  " -> rollup nil; пауза как у неудачи: 2 страницы take_followup ложь, 3-я — истина
function T.test_roll_failure_holds_until_retry()   -- finish_followup(job, nil, "timeout"): 2 страницы — take_followup ложь; 3-я — истина
function T.test_roll_cancelled_retries_next_answer() -- finish_followup(job, nil, "cancelled"): следующая страница — take_followup истина
function T.test_session_summary_before_roll()      -- прошлая сессия без пересказа и назревшая свёртка: первый job — "session" (sid прошлой), после сохранения — "roll"
function T.test_roll_saved_to_job_session()        -- job свёртки сессии 1, затем now += 5 ч и страница (сессия 2), потом finish_followup: rollup(1) есть, rollup(2) — nil, 0
function T.test_sync_followup_does_not_roll()      -- свёртка назрела, on_unlocked_followup(): llm_call не зван (нечего пересказывать из прошлой)
function T.test_roll_off_without_table()           -- DROP TABLE rollups: 25 страниц — ответы как обычно, take_followup ложь, begin_followup -> nil
```

В `async_answer_spec.lua`: `T.test_async_roll_goes_to_runner` — по образцу `test_async_followup_summary_goes_to_runner` (строки 338-354): фейковая память с `rollup`/`unrolled`/`set_rollup` и `total = 40`; после ответа на страницу без разблокировки в runner уходит `kind = "summary"`, `opts.timeout_s > 0`; `d.runner:done({ result = { text = "С" } })` → `set_rollup` вызван с `upto` из job.
В `controller_spec.lua`: `test_sealed_take_followup_is_false` (строка 684) остаётся зелёным без правок — свёртка не назрела. *(слово заменено ключом, см. spec 2026-11-20)*

- [ ] **Шаг 2:** `tests/run.sh` — FAIL на новых.

- [ ] **Шаг 3: реализация.**
  - `Controller:_roll_job(sid) -> job | nil` — под `pcall`; `nil`, если `unrolled` вернул `nil`, `total < ROLL_AT` или пауза (`self.roll_hold` для этого `sid` и `total < roll_hold.at`).
  - `_summary_job(with_roll)`: прежний путь → `kind = "session"`; иначе при `with_roll` — `_roll_job(cur)` (`cur` — первое значение `memory:session`). `begin_followup` → `_summary_job(true)` и `remote_fn(job.messages, false, job.opts)`; `on_unlocked_followup` → `_summary_job(false)`.
  - `_save_summary`: `roll` → `set_rollup(job.sid, prompt.roll_text(result.text), job.upto, now)` если текст непуст; сбросить `roll_hold`; строка лога `riddle: roll saved upto=%d chars=%d` (только числа).
  - `finish_followup`: у `roll` при ошибке, кроме `"cancelled"`, — `self.roll_hold = { sid = job.sid, at = job.total + ROLL_RETRY }`.
  - После `_remember` в ветке открытой печати `_answer` (`controller.lua:462`) — `self.roll_due = true`, если `_roll_job` вернул бы job (проверка без сборки messages: `total` из `unrolled(sid, 0)` против `ROLL_AT` и `roll_hold`). Страницы считаются только в открытой печати: страница разблокировки реплик не пишет. *(слово заменено ключом, см. spec 2026-11-20)*
  - `take_followup`: `local due = (not self.sealed and self.followup_due == true) or self.roll_due == true`, оба флага сбросить. *(слово заменено ключом, см. spec 2026-11-20)*
  - `_open_context`: `rolling = (pcall → memory:rollup(sid))` — текст или nil.

- [ ] **Шаг 4:** `tests/run.sh` — «specs, OK».

- [ ] **Шаг 5: коммит** — `git add plugin/riddlediary.koplugin/riddle/controller.lua tests/controller_memory_spec.lua tests/async_answer_spec.lua && git commit -m "feat(controller): свёртка выпавшего из окна через worker summary, раз в 20 реплик (Notion 40413e60-bc8d-8125)"`

**Тестер на Kindle:** одна сессия ≥ 21 страницы; на первой странице пишущий называет себя. Страницы — рукой
или `testmode feed=40 new=1` + одна живая страница (feed пишет в живую базу новой сессией — согласовать с
оркестратором). Ждать в `crash.log`: после 20-й страницы `riddle: worker summary done` и `riddle: roll saved
upto=… chars=…`; сосчитать `worker summary … cancelled|preempted` на 10 страниц (риск «перо гасит свёртку»). После
свёртки страница «как меня зовут?» — ответ с именем с первой страницы. Копия базы: в `rollups` одна строка этой
сессии.

---

## Срез 3 (задача 3): пересказ прошлой сессии с учётом свёртки

~30 строк кода + ~60 тестов. Без него пересказ долгой сессии строится из всех её реплик одним сообщением
(`riddle/controller.lua:525`), которое `prompt.fit` не режет (у него нет истории между system и последним).

**Files:** Modify `riddle/controller.lua` (`_summary_job`), `riddle/prompt.lua` (`summarize`); Test `tests/controller_memory_spec.lua`, `tests/prompt_spec.lua`.

**Interfaces:** `prompt.summarize(entries, earlier)` — `earlier` (строка | nil) первой строкой user: `"Раньше в этой сессии: " .. earlier`; без него — как сейчас.

- [ ] **Шаг 1: тесты (падают).** `T.test_summarize_with_earlier` (prompt_spec: строка «Раньше в этой сессии: Р» первой, реплики после; без `earlier` — вывод как у `test_summarize`, строка 169). `T.test_session_summary_uses_rollup` (controller_memory_spec: сессия 1 — 15 страниц «З1».. «З15», `memory:set_rollup(1, "СВ", id 20-й реплики, now)`, сон, +5 ч, страница: job `session` содержит «СВ» и реплики с 21-й («З11»), нет «З1 »). `T.test_session_summary_all_rolled` (все реплики свёрнуты: job есть, user — только строка «Раньше…»; пустая сессия без свёртки — по-прежнему `set_summary(sid, "")`).
- [ ] **Шаг 2:** `tests/run.sh` — FAIL.
- [ ] **Шаг 3: реализация.** `_summary_job`: `earlier, upto = memory:rollup(prev)` под `pcall`; есть `earlier` — реплики `memory:unrolled(prev, nil)`, иначе `memory:entries(prev)`; «пусто» — нет ни реплик, ни `earlier`.
- [ ] **Шаг 4:** `tests/run.sh` — OK.
- [ ] **Шаг 5: коммит** — `git commit -m "feat(summary): пересказ прошлой сессии из её свёртки и хвоста (Notion 40413e60-bc8d-8125)"` (те же 4 файла).

**Тестер на Kindle:** после сессии со свёрткой — сон > 4 ч (или `feed new=1`): `riddle: worker summary done`, в
копии базы `sessions.summary` прошлой сессии непуст.

## Решения владельца (были открытыми вопросами)

1. Пересказ прошлой сессии «без имени» (`riddle/prompt.lua:613`, bf459da), а свёртка сохраняет, как пишущий назвал
   себя сам. Владелец 2026-10-28 на «сохранять имя и между сессиями?»:

   > сохраняй

   → в срезе 3 `prompt.summarize` сохраняет, как пишущий назвал себя сам; «без рода и без обращений по роли»
   остаются (как в `prompt.roll`). Срезы 2 и 3 идут одним куском (оба правят `controller.lua`).
2. Живой прогон среза 2 через `feed new=1` (синтетическая сессия в живой базе пишущего). Владелец 2026-10-28:

   > синтетика

   Копия базы до миграции 4: `~/riddle-backup/diary-2026-10-28.sqlite3` (user_version 3, entries 200, sessions 19).
