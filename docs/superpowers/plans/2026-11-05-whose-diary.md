# Чей это дневник — персонаж и вселенная по строке — план (черновик)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** дневник становится дневником любого персонажа: строка в конфиге (или ответ пером на «Чей это дневник?») →
разовая фоновая генерация персоны, мира и 12 наборов фраз → ответы его голосом, память — своя у каждого персонажа;
Kindle владельца остаётся Волдемортом из «Методов».

**Architecture:** новый модуль `riddle/persona.lua` — встроенная персона «Методов», узнавание её строки, реестр
разделов генерации и разбор ответов модели. Сгенерированное хранится в `diary.sqlite3` (миграция 5: `personas`,
`persona_parts`); память и лор помечаются персонажем (миграция 6). Генерация — задания хвоста (`begin_followup`,
вид дочернего «summary»), по разделу на вызов, по цепочке; каждый раздел пишется одной командой, обрыв — продолжение
с первого недостающего. Пока персонажа нет — нейтральный голос: пулы фраз без модели, страница читается промптом
`prompt.setup` без образа.

**Tech Stack:** Lua (LuaJIT), KOReader-плагин, SQLite (`lua-ljsqlite3`), тесты `tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-10-31-whose-diary-design.md` (утверждена владельцем 2026-11-01). Задача Notion
40a13e60-bc8d-813e.

## 1. Как сейчас (факты, HEAD e04513d)

| Что | Факт | Источник |
|---|---|---|
| Конфиг | `config.load(path)`; строковые поля — `clean_str` (пусто → nil); полей персонажа нет | `riddle/config.lua:30-34`, `:81-153` |
| Конфиг на Kindle | пишет `tools/push_config.sh`; строковое поле пользователя с отказом на кавычку, `\`, перевод строки — образец `RIDDLE_TASKS_SOURCE` | `tools/push_config.sh:124-138` |
| Персона | зашита: `PERSONA_HEAD` (Волдеморт), `SEAL_OFF`, `VOICE`, `PERSONA` (в нём «О себе говоришь в мужском роде», `NO_GENDER`, «Отвечай по-русски, коротко: 1–3 предложения, без эмодзи и без markdown», «Никогда не называй себя ИИ») | `riddle/prompt.lua:23-31`, `:44`, `:45`, `:49`, `:51` *(слово заменено ключом, см. spec 2026-11-20)* |
| Сборка ответа | system = `PERSONA_HEAD .. (sealed and SEAL_OFF) .. PERSONA`, затем лор, знание, задачи, пересказы, форматы, история, картинка | `riddle/prompt.lua:293-347` *(слово заменено ключом, см. spec 2026-11-20)* |
| Запечатанный режим | «старый магический дневник», «по-русски, о себе в мужском роде» | `riddle/prompt.lua:33-38` *(слово заменено ключом, см. spec 2026-11-20)* |
| Пересказ / свёртка | «Ты — магический дневник… о себе в мужском роде» | `riddle/prompt.lua:624`, `:649-650` |
| `prompt.fit` и лор | раздел лора режется с хвоста, голова остаётся | `riddle/prompt.lua:443-465`, `:521` |
| Фразы | `texts.invitation` (строка) + 12 списков: greetings, welcomes, sleepy, fail_offline, fail_slow, fail_limit, fail_other, unreadable, thinking, busy, interrupted, tasks_source_unclear; каждый ≥ 30 (владелец 2026-10-25) | `riddle/texts.lua:2`, `:7-392`; `tests/texts_spec.lua:384` |
| Кто берёт фразы | контроллер `:31-37`, `:367`, `:400`, `:428`, `:455`, `:488`, `:491`, `:498`; виджет `:405`, `:479`, `:774-775`, `:1114`, `:1123`, `:1147` | `riddle/controller.lua`, `riddle_diarywidget.lua` |
| Память | `sessions`, `entries`, `lore(section PRIMARY KEY, text, mtime)`; `MIGRATIONS`, `SCHEMA_VERSION = 4`; шаг + версия — одна транзакция, сбой — откат шага, строка лога, база открывается | `riddle/memory.lua:10-18`, `:29-35`, `:92-121` |
| Сессия | последняя по id, новая через 4 ч; пересказы — последние 5 | `riddle/memory.lua:144-160`, `:226-234` |
| Лор | `import_lore` стирает весь лор; импорт, если mtime файла ≠ `MAX(mtime)`; потолок `DEFAULT_LORE_CAP = 10000` | `riddle/memory.lua:7`, `:329-359`; `riddle/controller.lua:530-536` |
| Хвост | лор + пересказ прошлой сессии / свёртка; `take_followup` → виджет `scheduleFollowup` (ждёт занятый runner) → `begin_followup` → дочерний «summary», потолок `CFG.ceil_s = 30` → `finish_followup` | `riddle/controller.lua:582-599`, `:642-690`; `riddle_diarywidget.lua:102`, `:493-537` |
| Отмена фонового | ответ вытесняет не-«answer»; перо и сон убивают «summary» | `riddle/worker.lua:123-131`; `riddle_diarywidget.lua:616`, `:934-935` |
| Конверт дочернего | ≤ 32768 байт | `riddle/worker.lua:13`, `:45-47` |
| Бюджеты дочернего | `remote_fn` всегда с `ANSWER_BUDGET_S = 25`, попытка 12 с, gemini-proxy 7 с, резерв последнему 7 с | `riddle/app.lua:15-20`, `:356-366` |
| Потолок ответа | `max(provider.max_tokens or 200, opts.max_tokens)`; BeatAPI в конфиге 400; Groq `max_input_chars = 10000` | `riddle/llm.lua:150`; `config.example.lua:16-21`; `tools/push_config.sh:103-110` |
| Цепочка | gemini-proxy → Gemini → Groq → BeatAPI | `riddle/llm.lua:59-109`; `tools/push_config.sh:9` |
| Разбор ответа | `want_json`: нужен `read`, отдаются read, reply, task, tasks_source, picks; без `want_json` — `{ text }`; пустой reply при прочитанном → «запасной», цепочка идёт к следующему провайдеру | `riddle/llm.lua:243-258`, `:308-311`; `llm.find_object` — `:189` |
| Печать | нечёткое сравнение `seal.matches(read, variants)`, Левенштейн ≤ 2 у вариантов длиннее 7 букв | `riddle/seal.lua:101-104`, `:189-200` *(слово заменено ключом, см. spec 2026-11-20)* |
| Меню | `text = "Дневник Реддла"`; KOReader берёт `text_func`, если задан | `main.lua:366`; Kindle `/mnt/us/koreader/frontend/ui/widget/touchmenu.lua:967` |
| Конфиг и контроллер | раз на процесс KOReader | `main.lua:38-74` |
| Гарды промптов | `no_event_spec` читает `prompt.locked`, `open("B64", {})`, `summarize`, `roll` | `tests/no_event_spec.lua:232-238`, `:304-310`, `:380-386`, `:396` |
| Тесты | `tests/run.sh` → «44 specs, OK» | вывод команды 2026-11-05 на e04513d |

## 2. Дизайн

**Персона.** `persona.view` — то, что читают промпт и фразы: `{ id, builtin, head, body, lang, lang_name, gender,
kind, title, pools }`. Встроенная «Методов» (`id = 1`) — нынешние `PERSONA_HEAD`/`PERSONA`, `texts.*`, «Дневник Реддла»;
её промпты байт в байт прежние (снимок до правок — `tests/fixtures/methods_prompts.lua`). Сгенерированная:
`head`/`body` из раздела `persona` + общие правила формы в коде (язык и род подставлены), пулы — из разделов
`texts.<name>`.

**Чья строка действует.** `cfg.whose` → иначе последняя подтверждённая пером → иначе вопрос. Узнана «Методов»
(`persona.is_methods`) — встроенная, без вызовов модели и без переспроса.

**Состояния персоны** (`personas.state`): `new` (строка из конфига, не разобрана) → вызов `resolve` → `confirm`
(мир дописала модель; вопрос в `personas.ask`) или `ready`; `confirm` + «да» → `ready`, иначе `rejected`. У ответа
пером строка разбирается в самом ответе (`prompt.setup`), в базу попадает уже `ready`. Генерация идёт у `ready`, пока
есть недостающий раздел.

**Разделы** (`persona.SECTIONS`, по порядку генерации): `persona` (JSON: head, body, lang, lang_name, gender m|f|n,
kind, title, invitation), `world` (текст ≤ `persona.WORLD_MAX_CHARS = 4000`), затем `texts.thinking`,
`texts.unreadable`, `texts.greetings`, `texts.welcomes`, `texts.busy`, `texts.interrupted`, `texts.fail_offline`,
`texts.fail_slow`, `texts.fail_limit`, `texts.fail_other`, `texts.sleepy`, `texts.tasks_source_unclear`. Раздел —
`{ name, max_tokens, messages = fn(view, line), decode = fn(text, lang) -> value | nil, err }`; карта мародёров
добавит свою запись, не трогая остальные. Встроенная персона перечисляет, какие разделы у неё свои
(`provides`) — у «Методов» все нынешние, генерировать нечего.

**Готовность.** Ответы голосом персонажа — когда есть `persona` и `world`. Наборы фраз включаются по одному по мере
генерации; недостающий — нейтральный пул (`texts.NEUTRAL_FOR`). До готовности запись читается `prompt.setup`,
ложится в память нового персонажа, ответ — нейтральное «загляни позже» (пул `later`: ответа не будет, обещать его нельзя); конец генерации дневник не озвучивает.

**Генерация фоном.** `begin_followup` первым отдаёт задание `gen` (`resolve` или первый недостающий раздел), затем
пересказ и свёртку, как сейчас. Задание — один вызов модели в дочернем «summary» (перо и сон его убивают, ответ
вытесняет) с бюджетом `app.GEN_*` и потолком дочернего `CFG.gen_ceil_s = 60`. Сохранение — `set_part` одной командой
`INSERT OR REPLACE` в персону задания (`job.persona_id`). `finish_followup` возвращает true, если генерация ещё нужна,
— виджет ставит следующий хвост; неудача (не отмена) — пауза до следующего ответа на страницу. Старт без ответа —
виджет при открытии, если `ctl:gen_due()`. Синхронный путь без runner (`on_unlocked_followup`) не генерирует: цикл
интерфейса ждал бы вызов до 50 с — как и свёртки там нет (`riddle/controller.lua:627-629`).

**Память на персонажа.** Миграция 6: `sessions.persona_id INT NOT NULL DEFAULT 1`, лор пересобран с ключом
`(persona_id, section)` и `persona_id DEFAULT 1`. `entries` и `rollups` идут за сессией. `DEFAULT 1` — старый код
после отката пишет в «Методов», а не в NULL. `Memory:use_persona(id)` — фильтр сессий, пересказов, лора.

**lore.md и мир.** В промпт — один раздел лора: `lore.md` персонажа первым (до потолка 10 000), сгенерированный мир —
в остаток, при обоих — правило `prompt.LORE_WINS` первой строкой. `prompt.fit` режет раздел с хвоста — уходит мир, не
`lore.md`. Файл импортируется к текущему персонажу, если его mtime не записан ни у одного персонажа.

**Язык и род.** Из `persona.view`: язык ответа, род о себе, «чем себя считает» — в общих правилах, запечатанном режиме,
пересказе, свёртке. У «Методов» — нынешние слова; персонажа ещё нет — «на языке записи, о себе без рода».

**Откат** (деплой прежнего sha): код с `SCHEMA_VERSION = 4` на базе 6 миграций не делает; его `INSERT` в sessions и
lore получают `persona_id = 1` по умолчанию; лишние таблицы не читаются. Ручного отката базы не нужно.
Оговорка: пока второго персонажа нет, откат бесследен. Когда он есть, старый код читает сессии и лор всех
персонажей вместе (запросы без `persona_id`). Лор он трогает только если `lore.md` менялся за время отката: его
`_sync_lore` импортирует файл при `mtime ~= lore_mtime()` (`MAX(mtime)` по всему лору; c901ef2 controller.lua:533,
memory.lua:350) — тогда `import_lore` делает `DELETE FROM lore` (лор всех персонажей) и пишет лор файла с
`persona_id = 1`, то есть «Методам». Файл не менялся — лор цел. После возврата `lore_owner(mtime)` отдаёт этот файл
«Методам» и другому персонажу его не импортирует: лор второго персонажа вернётся только при следующем изменении
`lore.md` (новый mtime — импорт к текущему персонажу). Сессии не теряются. На Kindle владельца сейчас только
«Методы», так что оговорка до появления второго персонажа теоретическая.

## 3. Проверить при плане (ASSUMPTION спеки) — ответы

**(а) Вызовов на генерацию.** Новый персонаж из конфига без мира: `resolve` 1 + `persona` 1 + `world` 1 + 12 наборов =
**15**; с названным миром или из ответа пером — **14** (чтение ответа — обычный вызов страницы). Невалидный набор —
+1 вызов на повтор (после следующего ответа). Оценка по коду:
- выход: набор — 36 фраз × ≤ 70 знаков ≈ 2,5 тыс. знаков ≈ 0,8–1,1 тыс. токенов (`max_tokens = 2000`); `persona` и
  `world` ≈ 1,5–2 тыс. (`3000`); `resolve` — `400`. Потолок вызова поднимает потолок провайдера (`llm.lua:150`), поэтому
  BeatAPI просит не 400, а потолок вызова — так уже ходят пересказ (800) и свёртка (1200, `controller.lua:19`, `:26`);
- вход: ≤ 4 тыс. знаков (персона + правила набора) — под `max_input_chars = 10000` Groq без урезания;
- конверт: мир 4000 знаков ≈ 8 КБ, набор ≈ 5 КБ — под 32768 (`worker.lua:13`);
- время: бюджеты ответа (gemini-proxy 7 с, попытка 12 с, `app.lua:16-20`) для 1–2 тыс. токенов тесны — у `gen` свои:
  `GEN_BUDGET_S = 50`, `GEN_ATTEMPT_S = 20`, `GEN_PROXY_ATTEMPT_S = 15`, `GEN_RESERVE_S = 15`, дочерний `gen_ceil_s = 60`;
  при 4–15 с на вызов вся генерация ≈ 1–4 мин открытого дневника (перо её прерывает, продолжение с раздела).
- **ASSUMPTION A1 (замер, тестер на Kindle):** на каждый вызов `gen` — строки `riddle: llm … -> 200 in N ms finish=…
  out_tokens=…` и `riddle: gen <раздел> saved|failed`: время в лимитах `GEN_*`, `finish` не `length`/`MAX_TOKENS`.
- **ASSUMPTION A2 (замер, тестер):** BeatAPI отдаёт больше 400 токенов при `max_tokens = 2000` (`finish=stop`) —
  проверка: временно только BeatAPI в цепочке (конфиг без ключей Gemini, Groq — пишет оркестратор), один раздел.

**(б) Каким промптом читать ответ на «Чей это дневник?».** Не `prompt.open`: он отвечает в образе (персона первой
частью system, `prompt.lua:295`) и тянет память — образ Реддла сбивает и чтение, и разбор имени. Новый
`prompt.setup(png_b64, pending)`: нейтральный system без персоны и памяти, правило чтения `FORMAT_STEPS`
(`prompt.lua:10-12`, «не угадывай — "?"»), JSON `{"read","reply","who","world","lang","yes"}`: `reply` — вопрос
«Так это дневник <персонаж> из <мир>?» на языке записи (непустой — иначе `llm.call` сочтёт ответ запасным и пойдёт к
следующему провайдеру, `llm.lua:308`); `yes` — согласие с `pending` на любом языке. Тот же промпт читает записи, пока
идёт генерация (берётся только `read`).

## 4. Решения

Оставленные спекой исполнителю:
1. **Хранение** — таблицы `personas` и `persona_parts` в `diary.sqlite3` миграцией 5: один писатель (контроллер в
   родителе), раздел — одна команда, бэкап и откат вместе с памятью; файл на FAT без атомарной замены не проверен.
2. **«Методы» в строке** — `persona.is_methods(line)`: точное вхождение в `seal.lower(line)` маркера мира
   (`рациональн`, `hpmor`, `rationality`) **и** маркера героя (`реддл`, `волдеморт`, `riddle`, `voldemort`); без
   маркера мира «Том Реддл» — канон Роулинг (анти-цель спеки). Не нечёткое `seal.matches`: строку пишет
   `tools/push_config.sh` точной, а нечёткий поиск принимал «национального» за «рационального» (`riddle/persona.lua`). *(слово заменено ключом, см. spec 2026-11-20)*
3. **Вызовы** — по разделу на вызов (15/14, раздел 3а): меньший ответ реже обрывается по потолку, обрыв теряет один
   раздел; продолжение — с первого недостающего, `INSERT OR REPLACE` раздела даёт то же состояние при повторе.
4. **Метка «Методов» при миграции** — `persona_id INT NOT NULL DEFAULT 1` у `sessions` и лора, строка персоны `id = 1`
   в шаге 5 (`INSERT OR IGNORE`); шаги — по одной транзакции (`memory.lua:92-107`): обрыв откатывает шаг, повтор
   приводит к тому же.

Свои (спека молчит; 5, 6 и lore.md при смене персонажа подтвердил оркестратор 2026-11-05):
5. Нейтральные пулы — на русском и английском (язык строки: есть кириллица → ru, иначе en); вопрос и приглашение до
   строки — двуязычные (спека, «Языки в объёме»).
6. «Не да» на строку из конфига (и мир неизвестен): строка отвергнута (`rejected`) и действует как строки нет —
   дневник снова спрашивает «Чей это дневник?» пером, по кругу, пока не появится личность; ответ пером идёт тем же
   разбором (переспрос с миром), «да» сохраняет строку (`save_asked`), и она действует, пока строка конфига
   отвергнута. Новая строка в конфиге (другой ключ) снова важнее. «Нет» на вопрос с миром пером — тоже сразу снова
   «Чей это дневник?» (владелец 2026-11-06; Notion 41013e60-bc8d-8133; было: фраза `fix_config` без модели — пул снят).
6а. Прежний `lore.md` при смене персонажа к новому не импортируется, если его mtime уже записан у другого; к новому —
   только изменённый файл (задача 3).
7. Приветствие после печати, пока персонажа нет: `neutral.welcome .. " " .. neutral.ask` одной репликой.
8. Пересоздание для разработчика — файл `/mnt/us/riddle/forget_persona`: при запуске стираются разделы текущей
   персоны (кроме встроенной), файл удаляется (образец — файл `devmode`, `main.lua:54-55`).

## Global Constraints

- Владелец 2026-10-31: «Если у нас совсем ничего нет, человек вписывает, оно генерируется, где надо. Если у человека уже есть какой-то чего-то, что-то, он в конфиге пишет, чей это дневник. И там всё остальное дегенерируется.»
- Владелец 2026-10-31: «По дефолту, Tom Reddle, без каких-то пояснений, это Tom Reddle, который был придуман Джон Роулинг, а не Tom Reddle, который в методах рационального мышления.»
- Владелец 2026-10-31: «Всё верно, на Kindle оставь Волдеморта из «Методов»».
- Владелец 2026-10-31: «переспросить, указать и мир тоже. например это дневник р2-д2 из звездных войн, а не просто р2-д2, мало ли где есть еще есть персонаж с похожим именем»
- Владелец 2026-10-25: «он и должен отвечать, сам он не может активироваться» — конец генерации не озвучивается.
- Каждый пул фраз — от 30 вариантов, и у сгенерированного (`riddle/texts.lua:2`).
- Код не привязан к данным владельца: строка «Методов» — только в `tools/push_config.sh` (как `watched_values`, `:143`).
- Правила формы — в коде, одни на всех: язык персонажа, 1–3 предложения, без эмодзи и markdown, не ИИ, не выдумывать, «ты» без рода.
- В лог Kindle — ни строки персонажа, ни текста записей и разделов: только имена разделов, числа, состояния.
- Промпты «Методов» не меняются ни на байт (снимок `tests/fixtures/methods_prompts.lua`).
- `tests/run.sh` зелёный перед каждым коммитом; коммит в main клона, без push.

## Review Focus

1. Kindle владельца после обновления: строка «Методов» — без вопроса, промпты прежние, память и лор на месте, меню «Дневник Реддла» — `test_methods_prompts_unchanged` (1), `test_migration_v6_marks_existing_memory_methods` (3), `test_methods_line_never_asks` (7).
2. Генерацию прервали посередине (перо, ответ, сон, перезапуск KOReader) — продолжение с недостающего раздела, готовые не теряются и не дублируются — `test_gen_resumes_from_missing_section` (2), `test_gen_cancel_keeps_due_failure_pauses` (1).
3. Модель вернула мусор, обрезок, < 30 годных фраз, эмодзи, markdown — раздел не сохраняется, работает нейтральный пул, повтор после следующего ответа — `test_persona_decode_rejects_garbage` (1), `test_set_under_30_not_saved` (2).
4. Первый запуск без сети — нейтральная фраза «нет сети», не пустая страница; вопрос — снова при следующей записи — `test_offline_first_run_neutral_phrase` (6), `test_ask_repeats_after_offline` (8).
5. Строка A → B → A: B начинает с пустой памятью и без лора A, у A всё возвращается — `test_switch_persona_new_memory_then_back` (3), `test_lore_md_not_imported_to_other_persona` (3).

---

## Задача 1: строка в конфиге → персона → ответ новым голосом (тонкий сквозной срез)

~380 строк. Временно (до задач 2, 3, 5): фразы — «Методов», память общая, до готовности персоны ответ — фраза
`texts.thinking` без вызова модели. На Kindle владельца не видно: строка — «Методов».

**Files:**
- Modify: `riddle/config.lua` (`cfg.whose`), `config.example.lua`, `tools/push_config.sh` (`RIDDLE_WHOSE`)
- Create: `riddle/persona.lua`
- Modify: `riddle/memory.lua` (шаг 5, хранилище), `riddle/prompt.lua` (`ctx.persona`, `prompt.gen_persona`), `riddle/controller.lua`, `riddle/app.lua` (`GEN_*`), `riddle_diarywidget.lua` (`gen_ceil_s`, цепочка хвостов)
- Test: `tests/fixtures/methods_prompts.lua`, `tests/whose_spec.lua` (новый), `tests/config_spec.lua`, `tests/push_config_spec.lua`, `tests/memory_spec.lua`, `tests/prompt_spec.lua`, `tests/async_answer_spec.lua`, `tests/no_event_spec.lua`

**Interfaces — Produces:**
- `cfg.whose -> string | nil` (`clean_str`).
- `Memory.SCHEMA_VERSION` (экспорт); шаг 5: `personas(id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, line TEXT NOT NULL, source TEXT NOT NULL, state TEXT NOT NULL, ask TEXT, lang TEXT, ts INT)`, `persona_parts(persona_id INT NOT NULL, name TEXT NOT NULL, text TEXT NOT NULL, ts INT, PRIMARY KEY(persona_id, name))`, `INSERT OR IGNORE INTO personas VALUES(1, ':methods', 'Том Реддл из «Методов рационального мышления»', 'builtin', 'ready', NULL, 'ru', 0)`.
- `Memory:persona_by_key(key) -> row | nil` (нет таблицы — `nil` и строка лога `riddle: memory personas unavailable` раз на открытие); `Memory:add_persona{ key, line, source, state, ask, lang } -> id` (`INSERT OR IGNORE` + `SELECT`); `Memory:set_persona_state(id, state, ask)`; `Memory:parts(id) -> { [name] = text }`; `Memory:set_part(id, name, text, now)` (`INSERT OR REPLACE`).
- `persona.METHODS_ID = 1`; `persona.key(line) -> string` — обрезка, пробелы в один, буквы через `seal.lower(s)` (новый экспорт: `fold`, `riddle/seal.lua:40-47`, для букв; цифры и знаки как есть — «R2-D2» не склеивается с «RD»); `persona.is_methods(line) -> bool`; `persona.SECTIONS` (пока `{ persona }`); `persona.next_section(row, parts) -> section | nil` (у `row.id == 1` — `METHODS.provides`); `persona.view(row, parts) -> view | nil` (nil — `persona`-раздела нет); `persona.METHODS_VIEW`.
- `prompt.open(png, ctx)`: `ctx.persona = view | nil` (nil — «Методов», как сейчас); `prompt.gen_persona(line) -> messages`.
- `Controller:gen_due() -> bool`; `begin_followup()` может вернуть `{ kind = "gen", section, persona_id, messages, opts = { max_tokens, limits = "gen" } }`; `finish_followup(job, payload, err) -> bool` (ещё нужен хвост).
- `Chain:remote_fn(messages, want_json, opts)`: `opts.limits == "gen"` — `app.GEN_BUDGET_S = 50`, `GEN_ATTEMPT_S = 20`, `GEN_PROXY_ATTEMPT_S = 15`, `GEN_RESERVE_S = 15`.
- Виджет: `CFG.gen_ceil_s = 60`; лог `riddle: gen <раздел> saved|failed (<причина>)`, `riddle: persona <methods|generated|none> state=<…>`.

- [ ] **Шаг 1: снимок промптов «Методов» до правок.** Скриптом в scratchpad на e04513d снять в `tests/fixtures/methods_prompts.lua` строки: `prompt.open("B64", ctx)[1].content` при `sealed = true` и `false` с лором, знанием, задачами, пересказами, свёрткой (контекст из `test_fit_trims_oldest_summaries_after_history`, `tests/prompt_spec.lua`); `prompt.locked("B64")[1].content`; `prompt.summarize(…)` и `prompt.roll(…)` — system. Тест `test_methods_prompts_unchanged` (`tests/prompt_spec.lua`) сравнивает с снимком — **зелёный на старом коде**.
- [ ] **Шаг 2: тесты (падают).**
  - `config_spec`: `test_whose_trimmed_or_nil` — `"  Гермиона  "` → `"Гермиона"`, `""`/число → nil.
  - `push_config_spec`: `test_whose_default_methods_line` (без `RIDDLE_WHOSE` в конфиге `whose = "Том Реддл из «Методов рационального мышления»"`), `test_whose_from_env`, `test_whose_quote_refused` (кавычка → exit 1, ничего не записано).
  - `memory_spec`: `test_migration_v5_adds_personas` (новая база и база v4: версия = `SCHEMA_VERSION`, строка id 1 `:methods`, прежние данные на месте); `test_migration_v5_failure_logs_and_opens` (имя `personas` занято индексом — версия 4, база открыта, `persona_by_key` → nil); `test_set_part_twice_same_state`. Проверки `user_version == 4` (`:74`, `:87`, `:155`, `:497`, `:503`, `:643`, `:649`) → `Memory.SCHEMA_VERSION`.
  - `whose_spec`: `test_is_methods` — true: «Том Реддл из «Методов рационального мышления»», «Волдеморт, Методы рационального мышления», «Tom Riddle, HPMOR»; false: «Том Реддл», «Tom Riddle», «Гермиона Грейнджер», «Шерлок, рациональный детектив». `test_persona_decode_rejects_garbage` — не JSON, нет `head`/`body`/`lang`, `gender` не m|f|n → nil. `test_config_line_generates_persona_then_answers_in_its_voice` — реальная `Memory` на временной базе, фейковые `remote_fn`/`absorb`: `gen_due()` true; `begin_followup()` → `kind = "gen"`, `section = "persona"`, в messages есть строка конфига; `finish_followup` с JSON персоны → true→false (`gen_due` false); `begin(png)` → system начинается с `"Ты — " .. head`, нет «Волдеморт». `test_methods_line_needs_no_generation` — `gen_due()` false, `begin(png)` = снимок. `test_not_ready_answer_is_thinking_without_llm` — до готовности `begin(png)` → nil, фраза из `texts.thinking`, PNG удалён. `test_gen_cancel_keeps_due_failure_pauses` — `"cancelled"` → `gen_due()` true; `"timeout"` → false до следующего `finish` ответа.
  - `async_answer_spec`: `test_gen_followups_chain` — после `on_done` задания `gen` с `finish_followup` = true виджет ставит новый хвост; `timeout_s == CFG.gen_ceil_s`; `test_gen_starts_at_open_when_due`.
  - `no_event_spec`: в четыре таблицы гардов (`:232`, `:304`, `:380`, `:396`) — `open_gen = prompt.open("B64", { persona = <образец view> })`.
- [ ] **Шаг 3:** `tests/run.sh` — FAIL на новых, снимок PASS.
- [ ] **Шаг 4: реализация.** `prompt.open`: `local p = ctx.persona or METHODS` (`METHODS = { head = PERSONA_HEAD, body = PERSONA }`); у сгенерированной `body = "\n" .. p.body .. " " .. prompt.rules(p)` — общие правила формы из `PERSONA` (`prompt.lua:51`, хвост с «Отвечай…» и `NO_GENDER`) вынести в `prompt.rules(view)`, у «Методов» — прежний текст. `prompt.gen_persona(line)` — system: персонаж по строке, канон автора, если версия не уточнена; JSON-пример ключей; правила формы ответа не генерировать. Контроллер: текущая персона — `cfg.whose`; «Методов» → `persona.METHODS_VIEW`; иначе строка `personas` по `persona.key` (нет — `add_persona{ state = "ready", source = "config" }`; переспрос — задача 7). `_open_context` кладёт `ctx.persona`. Хвост: `gen` первым в `_summary_job` (`riddle/controller.lua:582`).
- [ ] **Шаг 5:** `tests/run.sh` — PASS.
- [ ] **Шаг 6: коммит** `feat(whose): строка «чей дневник» в конфиге — персона генерируется фоном, ответы её голосом (Notion 40a13e60-bc8d-813e)`.
- [ ] **Шаг 7 (оркестратор):** деплой и `tools/push_config.sh` одним выкатом (строка «Методов» на Kindle с этого среза).
  Тестер: лог `riddle: persona methods state=ready`, ответы как прежде. Замер A1 на втором персонаже (строку
  «Гермиона Грейнджер» пишет оркестратор через `RIDDLE_WHOSE`, затем возвращает «Методов»).

## Задача 2: наборы фраз персонажа

~350 строк. Фразы берутся только через `Controller:texts(name)`; недостающий набор — пока «Методов» (задача 5 меняет
на нейтральный).

**Files:** Modify: `riddle/texts.lua`, `riddle/persona.lua`, `riddle/prompt.lua` (`gen_texts`), `riddle/controller.lua`, `riddle_diarywidget.lua`, `main.lua` (файл `forget_persona`). Test: `tests/texts_spec.lua`, `tests/whose_spec.lua`, `tests/async_answer_spec.lua`.

**Interfaces — Produces:**
- `texts.SETS` — `{ { name, about, max_cps, sentences } … }` для 12 наборов (`about` — когда фраза звучит; `max_cps` 70, у `interrupted` 90; `sentences` 1 у thinking/busy/tasks_source_unclear, 2 у interrupted — как в `tests/texts_spec.lua:74-82`, `:208-260`); `texts.MIN_POOL = 30`; `texts.FORBIDDEN = { ru = {…из texts_spec:9-11}, en = { "network", "internet", "server", "error", "wifi", "wi-fi", "connection" } }` — `texts_spec` читает отсюда.
- `texts.clean(name, list, lang) -> kept` — отбрасывает пустые, повторы, длиннее `max_cps`, с эмодзи, с `* # \``, с запрещёнными словами, больше `sentences` предложений.
- `persona.SECTIONS` += 12 `texts.<name>` (порядок — раздел 2 Дизайна); раздел `persona` получает поле `invitation`.
- `prompt.gen_texts(set, view) -> messages` — 36 фраз JSON-массивом, правила набора, голос — `view.head .. view.body`.
- `Controller:texts(name) -> list` (стабильная таблица на персону — мешки `_pick` держатся); `Controller:opening_text() -> string` (вместо `Diary:invitationText`, `riddle_diarywidget.lua:772-776`).
- `Memory:forget_parts(id)`.

- [ ] **Шаг 1: тесты (падают).** `texts_spec`: `test_builtin_pools_pass_clean` (каждый пул «Методов» после `texts.clean(name, list, "ru")` без потерь); `test_clean_drops_bad` (эмодзи, 71 знак, повтор, «**», «сеть», два предложения в `thinking` — выкинуты). `whose_spec`: `test_set_under_30_not_saved` (29 годных → `set_part` не вызван, `gen_due` false до следующего ответа, лог `riddle: gen texts.busy failed (pool 29)`); `test_gen_resumes_from_missing_section` (сохранены persona и 3 набора, новый контроллер на той же базе → следующее задание — 4-й набор; повтор сохранения того же набора — те же `parts`); `test_generated_pool_used` (`ctl:texts("busy")` — сгенерированный список; `fail_texts` берёт пулы через `texts`); `test_invitation_from_persona_when_sealed`. `async_answer_spec`: `test_busy_and_thinking_from_controller_pools`.
- [ ] **Шаг 2:** `tests/run.sh` — FAIL.
- [ ] **Шаг 3: реализация.** Все места из таблицы «Кто берёт фразы» — через `ctl:texts(name)`; без контроллера (виджет `:405`) — как сейчас. `forget_persona`: в `getController` (`main.lua:38-74`) после создания контроллера.
- [ ] **Шаг 4:** `tests/run.sh` — PASS. **Шаг 5: коммит** `feat(whose): наборы фраз персонажа — 12 наборов фоном, проверка ≥30 годных (Notion 40a13e60-bc8d-813e)`.

## Задача 3: память на персонажа (миграция 6)

~300 строк.

**Files:** Modify: `riddle/memory.lua`, `riddle/controller.lua` (`use_persona`, `_sync_lore`). Test: `tests/memory_spec.lua`, `tests/whose_spec.lua`.

**Interfaces — Produces:**
- `MIGRATIONS[6]`: `ALTER TABLE sessions ADD COLUMN persona_id INT NOT NULL DEFAULT 1`; `CREATE TABLE lore_p(persona_id INT NOT NULL DEFAULT 1, section TEXT NOT NULL, text TEXT, mtime INT, PRIMARY KEY(persona_id, section))`; `INSERT INTO lore_p(persona_id, section, text, mtime) SELECT 1, section, text, mtime FROM lore ORDER BY rowid`; `DROP TABLE lore`; `ALTER TABLE lore_p RENAME TO lore`.
- `Memory:use_persona(id) -> true | false` (false — колонки нет, тогда доступна только id 1; лог `riddle: memory personas unavailable`). `session`, `summaries`, `lore_text`, `lore_mtime`, `import_lore` — в пределах текущей персоны; новая сессия — с `persona_id`.
- `Memory:lore_owner(mtime) -> persona_id | nil`.
- Контроллер: персона без памяти (миграция 6 не прошла, персона не 1) — ответ `fail_other`, лог; `_sync_lore` — импорт, если mtime ≠ своему и `lore_owner(mtime)` пуст.

- [ ] **Шаг 1: тесты (падают).** `memory_spec`: `test_migration_v6_marks_existing_memory_methods` (база v4 с 2 сессиями, репликами, свёрткой, лором из 3 разделов → версия 6, все сессии `persona_id = 1`, лор тех же разделов в том же порядке, `recent`/`summaries`/`rollup`/`lore_text` персоны 1 — как до миграции); `test_migration_v6_twice_same_state` (два открытия — одинаковый дамп таблиц); `test_migration_v6_failure_rolls_back` (имя `lore_p` занято — версия 5, лор и сессии как были, база открыта; убрали препятствие — следующее открытие даёт тот же дамп, что чистый прогон); `test_old_code_inserts_default_to_methods` (`INSERT INTO sessions(started, last_ts)` и `INSERT INTO lore(section, text, mtime)` → `persona_id = 1`); `test_switch_persona_new_memory_then_back` (A: сессия, 2 реплики, пересказ; B — `session` новая, `summaries` пусто, `lore_text` пусто; снова A — всё на месте). `whose_spec`: `test_lore_md_not_imported_to_other_persona` (lore.md импортирован к A; переключение на B — не импортирован; файл изменён (новый mtime) — к B).
- [ ] **Шаг 2:** FAIL. **Шаг 3: реализация.** **Шаг 4:** PASS. **Шаг 5: коммит** `feat(memory): разговоры, пересказы и лор — у своего персонажа, нынешние — «Методов» (миграция 6; Notion 40a13e60-bc8d-813e)`.
- [ ] **Шаг 6 (тестер, до деплоя):** копия живой базы `scp kindle:/mnt/us/riddle/diary.sqlite3` и `PRAGMA user_version`, `COUNT(*)` sessions/entries/lore; после деплоя — те же числа (через копию) и версия 6.

## Задача 4: мир персонажа, lore.md важнее

~180 строк.

**Files:** Modify: `riddle/persona.lua` (раздел `world`), `riddle/prompt.lua` (`gen_world`, `lore_block`, `LORE_WINS`), `riddle/controller.lua`. Test: `tests/prompt_spec.lua`, `tests/whose_spec.lua`.

**Interfaces — Produces:** `persona.WORLD_MAX_CHARS = 4000`; раздел `world` вторым в `SECTIONS`; готовность — `persona` и `world`; `prompt.lore_block(lore_md, world, cap) -> string` (lore.md первым до `cap`, мир — в остаток; оба — `prompt.LORE_WINS` первой строкой); `memory.LORE_CAP` (экспорт `DEFAULT_LORE_CAP`).

- [ ] **Шаг 1: тесты (падают).** `test_lore_md_first_world_in_rest` (lore 9000 + мир 4000 → 10000 знаков, начало — lore.md, `LORE_WINS` есть); `test_lore_only_unchanged` (мира нет → как сейчас; снимок «Методов» зелёный); `test_fit_cuts_world_before_lore_md` (`prompt.fit` с 10000 знаков у Groq: строк мира нет, lore.md целиком); `test_ready_needs_world` (только `persona` → ответ ещё не голосом).
- [ ] **Шаг 2–4:** FAIL → реализация → PASS. **Шаг 5: коммит** `feat(whose): мир персонажа — в лор после lore.md, при расхождении верен lore.md (Notion 40a13e60-bc8d-813e)`.

## Задача 5: нейтральный голос

~120 строк кода + пулы (7 × ≥30 × ru/en — данные).

**Files:** Modify: `riddle/texts.lua` (`texts.neutral`, `NEUTRAL_FOR`), `riddle/persona.lua` (`lang_of`), `riddle/controller.lua` (`texts`, `opening_text`). Test: `tests/texts_spec.lua`, `tests/whose_spec.lua`.

**Interfaces — Produces:** `texts.neutral = { ru = { invitation, ask, offline, unreadable, thinking, later, welcome }, en = {…} }` (`ask` и `invitation` — двуязычные «Чей это дневник? / Whose diary is this?», общие для ru и en); `texts.NEUTRAL_FOR = { greetings = "invitation", welcomes = "welcome", sleepy = "later", fail_offline = "offline", fail_slow = "later", fail_limit = "later", fail_other = "later", unreadable = "unreadable", thinking = "thinking", busy = "thinking", interrupted = "thinking", tasks_source_unclear = "unreadable" }`; `persona.lang_of(line) -> "ru" | "en"`.

- [ ] **Шаг 1: тесты (падают).** `test_neutral_pools_30_clean` (каждый ≥ 30 после `texts.clean`, нет «Реддл», «Волдеморт», «Лорд», «Riddle», «Voldemort»; о себе без рода: нет «понял», «поняла», «ждал», «ждала», «рад», «рада», «готов», «готова»); `test_every_set_has_neutral` (`NEUTRAL_FOR` покрывает все 12 из `texts.SETS`); `test_missing_set_uses_neutral` (у персоны нет `texts.busy` → `ctl:texts("busy")` — нейтральный, не «Методов»).
- [ ] **Шаг 2–4:** FAIL → пулы и подмена → PASS. **Шаг 5: коммит** `feat(texts): нейтральный голос — пулы до персонажа и вместо недостающих наборов (Notion 40a13e60-bc8d-813e)`. Пулы читает владелец в ревью (решение оркестратора в спеке).
  Доработка по ревью (Б1, Б2, бэклог 1, 4; решения оркестратора): `later` — пул «загляни/напиши позже» без обещания ответа (тест: ни «ответ», ни «answer»); сбой при готовой персоне без набора и ответ неготовой персоне — `later`, не `thinking`; род о себе — правило, не список слов (прошедшее и краткие формы в предложении с «я», «тем/той/сам/сама…», безличное прошедшее в начале); `NEUTRAL_FOR` сверяется целиком; двуязычные фразы — « / », кириллица слева, латиница справа; `ask` и `invitation` не спрашивают о пишущем; `fix_config` не обещает ответа (пул снят 2026-11-06, решение 6).

## Задача 6: запись во время генерации и без сети

~250 строк.

**Files:** Modify: `riddle/prompt.lua` (`prompt.setup`), `riddle/llm.lua` (поля `who`, `world`, `lang`, `yes`), `riddle/controller.lua` (`job.mode = "setup"`). Test: `tests/prompt_spec.lua`, `tests/llm_spec.lua`, `tests/whose_spec.lua`, `tests/async_answer_spec.lua`.

**Interfaces — Produces:** `prompt.setup(png_b64, pending) -> messages` (раздел 3б); `llm.parse` добавляет `who`, `world`, `lang` (`opt_string`) и `yes` (`obj.yes == true`); `Controller:_begin` при неготовой персоне — `{ mode = "setup", stage = "gen" }`; `_answer`: `read` пишется в память персоны, ответ — `texts("sleepy")` (нейтральный `later`; `thinking` — только индикатор «думаю» при живом ответе), нечитаемое — `texts("unreadable")`, сбой — `fail_texts` через нейтральные пулы.

- [ ] **Шаг 1: тесты (падают).** `test_setup_prompt_reads_without_persona` (нет «Волдеморт», есть правило «"read":"?"», ключи примера `read`, `reply`, `who`, `world`, `lang`, `yes`); `test_parse_setup_fields` (`yes` строкой `"true"` → nil; `who` с пробелами — обрезан); `test_entry_during_generation_saved_to_new_persona` (`recent` персоны B — запись и нейтральная фраза, у «Методов» пусто); `test_generation_done_diary_stays_silent` (виджет: последнее `on_done` задания `gen` — очередь ответов пуста, `revealAnswer` не звался); `test_offline_first_run_neutral_phrase` (`net.state() == "off"` → нейтральный `offline` на языке строки, не пусто).
- [ ] **Шаг 2–4:** FAIL → реализация → PASS. **Шаг 5: коммит** `feat(whose): запись во время генерации — в память нового персонажа, ответ нейтральный (Notion 40a13e60-bc8d-813e)`.

## Задача 7: переспрос строки из конфига

~250 строк.

**Files:** Modify: `riddle/prompt.lua` (`prompt.resolve`), `riddle/persona.lua` (`decode_resolve`), `riddle/controller.lua`. Test: `tests/whose_spec.lua`.

**Interfaces — Produces:** новая строка конфига (не «Методов») → `state = "new"`; задание `gen` с `section = "resolve"`: `prompt.resolve(line)` → JSON `{ who, world, world_named, lang, ask }`; `world_named` → `ready`; мир не назван и модель его не знает (`world == ""`) → `rejected` (решение оркестратора по ревью 9720cba B-2: неоднозначное имя в генерацию не идёт; с 2026-11-06 дневник спрашивает «Чей это дневник?», решение 6); иначе `confirm` + `ask`. В `confirm`: `opening_text()` = `ask`; запись → `prompt.setup(png, ask)`; `yes` → `ready` (ответ — `texts("sleepy")`, нейтральный `later`: ответа не будет, см. Б1 ревью задачи 5), иначе `rejected` (ответ той же страницы — «Чей это дневник?», `_ask_open`). `rejected` → строка конфига не действует (`Controller:_config_line`): вопрос «Чей это дневник?» пером (решение 6). Исполнение: итог `resolve` ложится в строку `personas` (`Memory:resolve_persona`: `state`, `ask`, `lang` и `line` = «персонаж — мир», если мир дописала модель; только у `state = "new"`), ключ прежний; ответ на вопрос — `Memory:answer_persona` (только у `confirm`). Вопрос показывается раньше ответа: `opening_text()` и приветствие после печати (`welcome .. " " .. ask`) отмечают его показанным; страница, пришедшая до показа (разбор закончился после открытия), — не ответ: дневник отвечает самим вопросом без вызова модели. Запись-ответ в память не ложится.

- [ ] **Шаг 1: тесты (падают).** `test_config_line_without_world_asks_once` («R2-D2» → resolve `world_named=false` → `opening_text()` = `ask`; «да» → `ready`; новый контроллер на той же базе — вопроса нет); `test_config_line_with_world_not_asked`; `test_methods_line_never_asks` (никакого `resolve`); `test_config_no_reasks_whose_until_persona` (не «да» → `rejected`; снова «Чей это дневник?», по кругу до «да»; было `test_config_no_means_fix_config`); `test_resolve_failure_retried_next_answer`.
- [ ] **Шаг 2–4:** FAIL → реализация → PASS. **Шаг 5: коммит** `feat(whose): строку без мира дневник переспрашивает один раз — «Так это дневник … из …?» (Notion 40a13e60-bc8d-813e)`.

## Задача 8: вопрос «Чей это дневник?» при пустой строке

~300 строк.

**Files:** Modify: `riddle/controller.lua`, `riddle/memory.lua` (`last_asked`), `riddle_diarywidget.lua` (начальный текст). Test: `tests/whose_spec.lua`, `tests/async_answer_spec.lua`.

**Interfaces — Produces:** нет `cfg.whose` и нет подтверждённой → состояние `ask` (в процессе): `opening_text()` = `neutral.ask`; запись → `prompt.setup(png)`: нечитаемо → `unreadable`; есть `who` → `pending = { who, world, lang, line = reply }`, ответ — `reply` (вопрос с миром; пуст — шаблон `"Так это дневник %s из %s?"` / `"So this is the diary of %s from %s?"` по `lang`). Запись при `pending` → `prompt.setup(png, pending.line)`: `yes` → `add_persona{ source = "asked", state = "ready", line = pending.line, key = persona.key(pending.line), lang }` (строка «Методов» → персона 1); не `yes` → новый ответ на вопрос. `Memory:last_asked() -> row | nil`. С печатью: приглашение нейтральное, разблокировка — `welcome .. " " .. ask`. Строка конфига важнее сохранённой.

- [ ] **Шаг 1: тесты (падают).** `test_no_line_asks_whose_bilingual`; `test_answer_then_confirm_with_world`; `test_yes_saves_line_and_starts_gen` (`gen_due()` true, новый контроллер — `ready` без вопроса); `test_other_answer_reasks`; `test_ask_repeats_after_offline` (сбой сети → `offline`, следующая чистая страница — снова вопрос); `test_sealed_then_question`; `test_config_line_overrides_asked`; `test_methods_answer_maps_to_methods_memory`.
- [ ] **Шаг 2–4:** FAIL → реализация → PASS. **Шаг 5: коммит** `feat(whose): без строки дневник спрашивает «Чей это дневник?» пером и запоминает ответ (Notion 40a13e60-bc8d-813e)`.

## Задача 9: язык, род и имя дневника из персонажа

~200 строк.

**Files:** Modify: `riddle/prompt.lua` (`locked`, `summarize`, `roll`, `rules`), `riddle/controller.lua` (`title`), `main.lua:366`. Test: `tests/prompt_spec.lua`, `tests/whose_spec.lua`, `tests/no_event_spec.lua`.

**Interfaces — Produces:** `prompt.locked(png, view)`, `prompt.summarize(entries, earlier, view)`, `prompt.roll(earlier, entries, view)` — `view` nil или «Методов» → снимок; сгенерированная — язык (`lang_name`), род (`m` «в мужском роде («понял», «ждал»)», `f` «в женском роде («поняла», «ждала»)», `n` «о себе без рода»), `kind` вместо «дневник»; персонажа нет — «на языке записи, о себе без рода». `Controller:title() -> string` («Методов» — «Дневник Реддла», сгенерированная — `view.title`, нет — «Дневник / Diary»); меню — `text_func = function() return ctl and ctl:title() or … end`.
- Факт (проверил оркестратор на Kindle 2026-11-05): меню KOReader берёт `text_func` — `/mnt/us/koreader/frontend/ui/widget/touchmenu.lua:967` `local entry_text = v.text_func and v.text_func() or v.text`.

- [ ] **Шаг 1: тесты (падают).** `test_methods_prompts_unchanged` (снимок, всё ещё зелёный); `test_locked_prompt_english_female` (нет «по-русски», нет «мужском», есть `lang_name`, «женском»); `test_summarize_uses_persona_gender_and_kind`; `test_title_from_persona`; гарды `no_event_spec` — с образцом сгенерированной персоны и в `locked`/`summarize`/`roll`.
- [ ] **Шаг 2–4:** FAIL → реализация → PASS. **Шаг 5: коммит** `feat(whose): язык, род и имя дневника — от персонажа (Notion 40a13e60-bc8d-813e)`.

## Задача 10: выкат на Kindle владельца (пункт 10 спеки)

Кода нет: проверка, что Kindle владельца после всех срезов работает как до них.

- [ ] **Шаг 1 (тестер):** копия базы до выката (`scp kindle:/mnt/us/riddle/diary.sqlite3`), числа sessions/entries/lore.
- [ ] **Шаг 2 (оркестратор, одним выкатом):** `tools/push_config.sh` (строка «Том Реддл из «Методов рационального мышления»» из умолчания `RIDDLE_WHOSE`) и `tools/deploy.sh`; перезапуск — через devmode, не `killall reader.lua`.
- [ ] **Шаг 3 (тестер), по пунктам с уликой:** (1) открытие — не «Чей это дневник?», приглашение/приветствие «Методов»; лог `riddle: persona methods state=ready`, ни одной строки `riddle: gen`; (2) вопрос о прошлом разговоре — ответ его помнит; (3) вопрос по `lore.md` — ответ из лора; (4) меню — «Дневник Реддла»; (5) копия базы после — версия 6, те же числа, все сессии `persona_id = 1`; (6) печать, если настроена, открывается прежним словом. *(слово заменено ключом, см. spec 2026-11-20)*

## Самопроверка плана

- Пункты «Как работает» 1–10: 1 → з.1; 2 → з.7, з.8; 3 → з.1, 2, 4; 4 → реестр `SECTIONS` (з.1–2); 5 → з.4 (+ лор у персонажа — з.3); 6 → з.1 (`provides`), з.7; 7 → з.3; 8 → з.1, 9; 9 → з.9; 10 → з.1 (строка в выкате), з.10.
- Анти-цели: «Том Реддл» → не «Методов» (`test_is_methods`); ИИ/эмодзи/markdown/длина — общие правила в коде (`prompt.rules`) + гарды `no_event_spec`; перекрытие lore.md (з.4); пустая страница без сети (з.6, з.8); память прежнего (з.3).
