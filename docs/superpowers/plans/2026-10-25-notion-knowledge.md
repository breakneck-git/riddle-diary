# Знания дневника из Notion — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** дневник отвечает в образе по содержимому Notion пользователя (любого, одним токеном), не замораживая интерфейс: ответ готовится в отдельном процессе, медленный ответ прикрыт фразой-раздумьем, запись во время раздумья получает отказ из пула.

**Architecture:** путь ответа (сеть, разбор) уходит в дочерний процесс KOReader (`ffiutil.runInSubProcess`), родитель готовит запрос и пишет память; один дочерний процесс за раз, ответ вытесняет синхронизацию. Notion читается фоном (тоже в дочернем процессе) в отдельную SQLite `knowledge.sqlite3`; маленький Notion целиком идёт в системный промпт, большой — поиском по отпечаткам (bge-m3, OpenAI-совместимый `/embeddings`).

**Tech Stack:** LuaJIT + FFI, KOReader v2025.08 (`ffi/util`), SQLite (`lua-ljsqlite3`), dkjson, тесты — `tests/run.sh` на Mac.

**Spec:** `docs/superpowers/specs/2026-10-25-notion-knowledge-design.md` (утверждено владельцем 2026-10-25: «ОК на всё»). План от описания не отступает; расхождения с кодом — в конце.

**Статус:** план утверждён оркестратором 2026-10-25. D0 закрыт: `/mnt/us/koreader/ffi/util.lua` на устройстве совпадает с копией целиком (md5 `673824960a434d428dc14f9729827358`).

## Global Constraints

- Тест до кода; каждый срез — `tests/run.sh` зелёный целиком (полный = быстрый, CLAUDE.md «Прогон тестов»).
- Ключи и токен Notion — только в `/mnt/us/riddle/config.lua`, кладёт `tools/push_config.sh` (запускает оркестратор). В лог — ни токена, ни ключа, ни заголовков и текстов страниц Notion: только числа, хосты, статусы. Все новые секреты конфига — в `config_secrets` (`app.lua:61-76`).
- Только https для любого внешнего адреса (как `clean_providers`, `config.lua:47`).
- Тексты плагина проходят гард `tests/no_event_spec.lua:95-106`: нельзя «загадк», «отсылк», «руна/руны/руну», «квест», «ивент», «хранител». Новые фразы: обращение на «ты» без рода (не «хозяйка», не женские формы — владелец 2026-10-25), 1 предложение, без эмодзи и латиницы (голос — `prompt.lua:21-22`).
- Дочерний процесс не трогает соединения SQLite родителя (`diary.sqlite3` открыт в родителе, `main.lua:48`). `knowledge.sqlite3` родитель открывает только на время одного чтения и закрывает до `fork`; дочерний открывает своё соединение сам. Источник правила — запрет SQLite на перенос открытого соединения через fork; `os.exit(0)` в дочернем не закрывает Lua-состояние (проверено: финализатор `__gc` не вызывается, `luajit -e '…os.exit(0)'`), т.е. унаследованное соединение не закрывается и не трогается.
- Не больше одного дочернего процесса одновременно (RAM: свободно ~9 МБ + ~120 МБ кэша, KOReader ~27 МБ — описание, «Ограничения»).
- Запушенные коммиты не переписывать; коммит на каждый срез в клоне, без push.

## Review Focus

1. **Kindle уснул посреди ответа или синхронизации.** Ожидание: дочерний процесс ответа убит, его ответ не появляется после пробуждения, зомби нет; синхронизация продолжается со следующей несохранённой страницы. Тесты: срез 1 `test_suspend_cancels_answer_child`, срез 3 `test_partial_sync_keeps_committed_docs`.
2. **Токен отозван / Notion 429 / нет сети.** Ожидание: дневник отвечает как без Notion, в логе причина без токена. Тесты: срез 3 `test_401_is_unauthorized_without_token`, `test_429_waits_retry_after`, срез 4 `test_knowledge_read_failure_still_answers`.
3. **Три и больше страниц во время раздумья.** Ожидание: на каждую — отказ по порядку, модель вызвана один раз, ответ на первую приходит последним; очередь не растёт без конца (отказы держатся по `answer_hold_s`). Тест: срез 2 `test_three_pages_during_ponder_three_refusals_one_call`.
4. **Дочерний процесс завис дольше бюджета** (getaddrinfo без интернета, `http.lua:4-7`). Ожидание: через `ceil_s` = 30 с — фраза «медленно» (`texts.fail_slow`), процесс убит, следующая страница уходит в модель. Тест: срез 1 `test_timeout_kills_child`, срез 2 `test_ceiling_gives_slow_phrase_and_frees_runner`.
5. **Странный Notion:** ноль открытых страниц, строка только с названием, тип свойства, которого нет в таблице (`button`, `verification`, будущий тип). Ожидание: не падает, неизвестное свойство пропущено, пустое знание = поведение «Без Notion». Тесты: срез 3 `test_unknown_property_type_skipped`, `test_empty_workspace_sync_ok`, срез 4 `test_prompt_without_knowledge_unchanged`.

---

## Опоры в коде (проверено)

| Факт | Источник |
|---|---|
| Ответ синхронный: `Diary:respond` зовёт `ctl:on_page(png)` в цикле интерфейса | `riddle_diarywidget.lua:366-385`, комментарий `:27-29` |
| Страница → `onPageDone` → PNG → `responder` после растворения чернил; `inflight` — страниц без ответа | `riddle_diarywidget.lua:886-925`, `:349` |
| Касание растворяет ответ на экране | `riddle_diarywidget.lua:746`, `:1059-1066` |
| Удержание ответа: таймер, только если за ним кто-то есть | `riddle/hold.lua:8-11`, `riddle_diarywidget.lua:944-948` |
| Сон: `resetPage` поднимает `epoch`, ответы старых страниц отбрасываются | `riddle_diarywidget.lua:478-511`, `:912-915` |
| Контроллер: `on_page` = `_handle` (печать закрыта/открыта) + удаление PNG при любом исходе | `riddle/controller.lua:82-127` |
| Фразы сбоя по ошибке: `"budget"`/`…timeout` → `fail_slow` | `riddle/controller.lua:16-22` |
| Цепочка провайдеров: бюджет `app.BUDGET_S = 8`, потолок на провайдера 4 с, мёртвые ключи и счётчик `calls` живут в замыкании | `riddle/app.lua:11`, `:107-153`; `riddle/llm.lua:9`, `:160-208` |
| Пересказ сессии и лор — тем же `llm_call`, синхронно после приветствия | `riddle/controller.lua:137-160`, `riddle_diarywidget.lua:390-406` |
| Контроллер и состояние живут в `state` плагина, `onSuspend` закрывает печать | `main.lua:21-22`, `:38-73`, `:181-187` |
| `runInSubProcess(func, with_pipe)` → `pid, read_fd`; дочерний вызывает `func(pid, write_fd)` в `xpcall` и `os.exit(0)`; `isSubProcessDone(pid)` (WNOHANG), `terminateSubProcess(pid)` (SIGKILL группе), `getNonBlockingReadSize(fd)`, `readAllFromFD(fd)` (до EOF), `writeToFD(fd, data, close)` | копия KOReader `…/d9697eeb-…/scratchpad/ko/ffi/util.lua:317-401`, `:406-417`, `:420-433`, `:443-458`, `:465-477`, `:502-522`; строка 317 совпадает с замером в описании (на устройстве) |
| Штатный образец опроса: `getNonBlockingReadSize ~= 0` → `readAllFromFD`; завершился без вывода → закрыть fd | `ko/frontend/apps/reader/modules/readerthumbnail.lua:346-411` |
| Тесты виджета — на заглушках KOReader со своими часами и планировщиком | `tests/answer_cycle_spec.lua:1-58` |
| Notion API: версия `2025-09-03`, `POST /v1/search` с пагинацией, строки — `POST /v1/data_sources/{id}/query`, тела — `GET /v1/blocks/{id}/children?page_size=100` рекурсивно, `last_edited_time` у объекта | `scripts/notion_census.py:11`, `:52-66`, `:96-108`, `:127-152`, `:80` |
| Пути значений свойств страниц (title/rich_text `[].plain_text`, number, select/status `.name`, multi_select `[].name`, date `.start/.end`, formula/rollup по `.type`, relation `[].id` ≤ 25, people `[].id` + иногда `name`, files `[].name`, unique_id `prefix+number`) | developers.notion.com/reference/page-property-values (прочитано 2026-10-25) |
| `last_edited_time` у страницы — «when this page was updated»; про округление документация молчит | developers.notion.com/reference/page |
| Отпечатки: `POST {base}/v1/embeddings {model, input:[…]}` → `data[i].embedding`, сортировка по `index` | `scripts/cf_common.py:9`, `:54-58` |
| Переменные окружения замеров: `NOTION_DIARY_API`, `CF_WORKERS_AI_ACCOUNT_ID`, `CF_WORKERS_AI_TOKEN` | `scripts/notion_census.py:7`, `scripts/cf_common.py:4-5` |
| top-K по косинусу на LuaJIT FFI: варианты float32 / unroll4 / int8 | `scripts/bench_topk.lua` |

`scripts/` — временный каталог автора для замеров (в репозиторий не входит).

## Срезы

| # | Срез | Что видит тестер | Зависит от |
|---|---|---|---|
| 1 | Ответ в отдельном процессе | перо пишет, пока дневник «думает» | — |
| 2 | Раздумье, отказ на запись, потолок 30 с | фраза через ~2 с, отказ на вторую запись | 1 |
| 3 | Notion → хранилище на Kindle | в логе `sync done …` после сна | 1 (только запуск через runner) |
| 4 | Маленький Notion в ответе | «топ-5 фильмов» отвечен в образе | 3 |
| 5 | Отпечатки кусков при синхронизации | в логе `embed N chunks` | 3 |
| 6 | Большой Notion: поиск по смыслу | ответ из большой базы (синтетика) | 4, 5 |

Параллельно можно: модули среза 3 (`notion.lua`, `notion_text.lua`, `knowledge.lua`, `sync.lua`) — сразу, параллельно срезам 1–2; к `main.lua` и виджету срез 3 подключается после среза 1. Срезы 4 и 5 не правят одни файлы, кроме `knowledge.lua` и `config.lua` — их ставить последовательно.

---

### Срез 1: Ответ в отдельном процессе

Результат: запрос к модели идёт в дочернем процессе, цикл интерфейса свободен; поведение ответов и тексты прежние. Бюджет цепочки пока 8 с, жёсткий потолок 30 с уже работает (убивает зависший процесс).

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/worker.lua`
- Create: `tests/subprocess_shim.lua` (настоящие fork/pipe через FFI на Mac, тот же контракт, что `worker.koreader_sys()`)
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua:82-127` (разрезать `_handle`)
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua:97-153`, `:182-197`
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua:27-29`, `:321-333`, `:365-385`, `:455-511`, `:886-925`
- Modify: `plugin/riddlediary.koplugin/main.lua:38-73`, `:160-178`
- Test: `tests/worker_spec.lua` (новый), `tests/controller_spec.lua`, `tests/app_spec.lua`, `tests/async_answer_spec.lua` (новый, харнес как `answer_cycle_spec.lua:1-58`)

**Interfaces:**
- Produces:
  - `worker.new{ sys, schedule = fn(s, f), clock = fn() -> s, log = fn(msg) } -> Runner`
  - `sys = { spawn = fn(child_fn) -> pid, fd | false, err; has_data = fn(fd) -> bool; done = fn(pid) -> bool; read_all = fn(fd) -> string; kill = fn(pid); write = fn(fd, data) }`; `child_fn(write_fd)` выполняется в дочернем.
  - `worker.koreader_sys() -> sys` поверх `require("ffi/util")` (spawn = `runInSubProcess(function(_, wfd) child_fn(wfd) end, true)`, has_data = `getNonBlockingReadSize(fd) ~= 0`, done = `isSubProcessDone`, read_all = `readAllFromFD`, kill = `terminateSubProcess`, write = `writeToFD(fd, data, true)`).
  - `Runner:start(kind, fn, opts) -> true | nil, err`; `kind` ∈ `"answer"`, `"sync"`; `fn()` в дочернем возвращает таблицу (JSON через dkjson); `opts = { timeout_s, on_done = fn(payload | nil, err) }`; `err` ∈ `"timeout"`, `"crashed"` (вышел без вывода), `"child: <msg>"` (ошибка в `fn`), `"payload"` (> `worker.MAX_PAYLOAD`), `"decode"`, `"spawn: <msg>"`. `"answer"` вытесняет идущий `"sync"` (его `on_done(nil, "cancelled")`); `"sync"` при занятом runner → `nil, "busy"`.
  - `Runner:cancel(kind?)` — убить текущий (только этого вида, если задан); `on_done` отменённого не зовётся (кроме вытесненного sync, см. выше). Убитые дожимаются `done(pid)` по таймеру, пока не соберутся (без зомби).
  - `Runner:busy() -> kind | nil`.
  - `worker.MAX_PAYLOAD = 32768`, `worker.POLL_S = 0.2`. В payload дочерний добавляет `rss_kb` из `/proc/self/status` (nil на Mac).
  - `Controller:begin(png_path) -> job | nil, text` — читает PNG, кодирует, удаляет PNG (всегда, как `on_page:119-121`), собирает messages; `job = { mode = "open" | "locked", messages, sid, run = fn() -> payload }`. Ошибка → `nil, текст сбоя`.
  - `Controller:finish(job, payload | nil, err) -> text` — вся логика после ответа (`controller.lua:89-114`); `payload` проходит `deps.absorb`.
  - `Controller:on_page(png)` = `begin` → `deps.llm_call` → `finish` (поведение и тесты прежние; devtest зовёт его синхронно, `devtest.lua:353`).
  - `app.chain(d) -> chain`: `chain:call(messages, want_json) -> result, err` (бывший `llm_caller`, `app.llm_caller(d)` остаётся обёрткой); `chain:remote_fn(messages, want_json) -> fn() -> payload` (сдвиг ключа Gemini `calls` растёт в родителе при создании; в дочернем лог копится в `payload.logs`, новые мёртвые — в `payload.dead`, `payload.result`, `payload.err` уже через `mask`); `chain:absorb(payload) -> result, err` (в родителе: каждая строка `payload.logs` → `d.log`, `payload.dead` → мёртвые).
  - Новые deps контроллера из `app.new_controller`: `remote_fn`, `absorb`.
  - Виджет: поле `runner` (`Diary:new{ runner = … }`); `nil` → прежний синхронный путь.

- [ ] **Step 1: Тест-шим и тесты runner (падают: модуля нет)** — `tests/worker_spec.lua` на `tests/subprocess_shim.lua` (родитель делает `io.stdout:flush()` до fork, дочерний выходит `_exit(0)`, чтобы буфер вывода не печатался дважды):
  - `test_child_result_comes_back_through_pipe`: `fn` → `{ a = 1, s = "ё" }`; `on_done` получает `a == 1`, `s == "ё"`.
  - `test_parent_free_while_child_works`: `fn` спит 0.5 с; `start` возвращается < 0.1 с по часам.
  - `test_timeout_kills_child`: `fn` спит 5 с, `timeout_s = 0.3` → `on_done(nil, "timeout")` < 1 с; затем `sys.done(pid) == true` (собран).
  - `test_child_error_reported`: `fn` бросает `"boom"` → `err` начинается с `"child: "` и содержит `boom`.
  - `test_child_exit_without_output_is_crashed`.
  - `test_payload_over_cap_is_error`: строка 40 000 байт → `err == "payload"`.
  - `test_answer_preempts_sync`, `test_sync_refused_while_answer_busy`, `test_cancel_drops_on_done`.
- [ ] **Step 2: Запустить** `luajit tests/worker_spec.lua` (с `LUA_PATH` из `tests/run.sh:4`) — FAIL `module 'riddle.worker' not found`.
- [ ] **Step 3: Реализовать `riddle/worker.lua`** — опрос по `schedule(POLL_S)`: `has_data` → `read_all` → decode; `done` без данных → `"crashed"`; время старта по `clock`, дедлайн `timeout_s` → `kill` + `"timeout"`. Образец — `readerthumbnail.lua:376-411`.
- [ ] **Step 4: `tests/worker_spec.lua` PASS.**
- [ ] **Step 5: Тесты контроллера и app (падают)**:
  - `controller_spec`: `test_begin_finish_equals_on_page_open`, `test_begin_finish_equals_on_page_locked` (тот же текст, те же записи памяти, тот же лог), `test_begin_removes_png_even_on_error`, `test_finish_timeout_gives_fail_slow` (`finish(job, nil, "timeout")` ∈ `texts.fail_slow`).
  - `app_spec`: `test_remote_payload_carries_logs_and_dead_keys` (401 с «API key» → `payload.dead` содержит ключ 1, `payload.logs` содержит `"gemini key 1 dead"`, `d.log` не вызван), `test_absorb_marks_dead_and_next_call_skips_key`, `test_remote_err_is_masked` (ключ из конфига в тексте ошибки → `***`).
- [ ] **Step 6: Реализовать `begin`/`finish`, `app.chain`.** `_handle` остаётся как `begin` + `llm_call` + `finish`.
- [ ] **Step 7: Тесты виджета (падают)** — `tests/async_answer_spec.lua`, поддельный runner с ручным `on_done`:
  - `test_async_respond_returns_before_answer`: после `onPageDone` → `runner.started == 1`, `inflight == 1`, ответа нет; `on_done` → ответ в очереди и проявляется.
  - `test_async_sends_without_ink_wait`: `start` вызван в том же такте, что `onPageDone` (без `inkLeft`, `:923-924`, и без ожидания `self.cur`, `:906-909`).
  - `test_second_page_waits_while_answer_busy`: вторая страница уходит в runner только после `on_done` первой (до среза 2).
  - `test_suspend_cancels_answer_child`: `onSuspend` → `runner:cancel("answer")` вызван, поздний `on_done` ничего не показывает.
  - `test_close_cancels_answer_child`: `onCloseWidget` → то же.
  - `test_runner_failure_gives_fail_text`: `on_done(nil, "crashed")` → текст ∈ `texts.fail_other`.
- [ ] **Step 8: Реализовать в виджете** `Diary:respond` с runner (`timeout_s = CFG.ceil_s`, `CFG.ceil_s = 30`), отмену в `resetPage`/`onCloseWidget`; лог `riddle: worker answer done in %d ms (child RSS KB %s)` / `riddle: worker answer failed: %s`. Комментарии `:27-29`, `:365` — привести к асинхронному пути. В `main.lua` — `state.runner = worker.new{ sys = worker.koreader_sys(), schedule = UIManager:scheduleIn, clock = time.monotonic → s, log = logger.info }`, передать в `DiaryWidget:new`.
- [ ] **Step 9: `tests/run.sh` — все зелёные.**
- [ ] **Step 10: Commit** `feat(worker): ответ дневника в отдельном процессе KOReader, интерфейс не ждёт сеть`.

**Тестер на Kindle:** написать страницу и сразу продолжать писать — штрихи появляются под пальцем во время запроса (раньше замирали до ответа); ответы и печать как прежде. Улики: `crash.log` — `riddle: worker answer done in … ms (child RSS KB …)` на каждый ответ; после 10 ответов нет строк `worker answer failed`.

---

### Срез 2: Раздумье, отказ на запись, потолок 30 с

Результат: ответ дольше `ponder_s` прикрыт фразой-раздумьем, которая уходит, как только пришёл ответ; страница, законченная во время раздумья, в модель не уходит — на неё отказ из пула; бюджет цепочки ответа 25 с, потолок 30 с.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/texts.lua` (+`texts.thinking`, `texts.busy`)
- Modify: `plugin/riddlediary.koplugin/riddle/hold.lua:8-11`
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua` (+`Controller:pick(list)` = `_pick`, `:44-57`)
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua` (+`app.ANSWER_BUDGET_S = 25` для `remote_fn`; `app.BUDGET_S = 8` остаётся для синхронных вызовов — пересказ, devtest)
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua:69-101` (`CFG.ponder_s = 2.0`), `:886-965`
- Test: `tests/ponder_spec.lua` (новый), `tests/hold_spec.lua`, `tests/texts_spec.lua`, `tests/app_spec.lua`

**Interfaces:**
- Consumes: `Runner:start/cancel/busy`, `Controller:begin/finish` (срез 1).
- Потолок попытки провайдера на пути ответа — 12 с (`app.ANSWER_ATTEMPT_S = 12`), тест `app_spec`: `test_remote_answer_attempt_ceiling_12s`; синхронные вызовы — прежние 4 с.
- Produces: элемент очереди ответов `{ text, top, page, unlocked, kind }`, `kind` ∈ `nil` (ответ), `"think"`, `"busy"`; `hold.seconds(timed_s, queued, inflight, kind) -> s | nil` — для `kind == "think"` при `queued > 0` → `0`.

- [ ] **Step 1: Тесты (падают)** — `tests/ponder_spec.lua` (харнес `answer_cycle_spec`, поддельный runner, свои часы):
  - `test_fast_answer_has_no_ponder`: `on_done` через 1.5 с → проявлен только ответ, ни одной фразы из `texts.thinking`.
  - `test_slow_answer_ponder_then_answer`: `on_done` через 5 с → первой проявлена фраза ∈ `texts.thinking` (лог `riddle: ponder shown after 2000 ms`), затем ответ; между приходом ответа и началом растворения фразы нет удержания `answer_hold_s` (начало растворения ≤ конец проявления фразы + 1 такт).
  - `test_queued_ponder_dropped_when_answer_arrives`: фраза в очереди ждёт чернил, ответ пришёл → фраза не проявлялась.
  - `test_page_during_ponder_gets_refusal_without_model`: вторая страница закончена при `inflight > 0` → `runner.started == 1`, `saveSample` вызван 1 раз (для первой), проявлены по порядку: отказ ∈ `texts.busy`, затем ответ первой; лог `riddle: page during ponder -> refusal` без текста.
  - `test_three_pages_during_ponder_three_refusals_one_call`.
  - `test_ceiling_gives_slow_phrase_and_frees_runner`: `on_done(nil, "timeout")` → текст ∈ `texts.fail_slow`; следующая страница уходит в runner.
  - `hold_spec`: `test_think_with_follower_releases_at_once` (`hold.seconds(6, 1, 0, "think") == 0`), `test_think_alone_waits_for_touch` (`== nil`).
  - `texts_spec`: `test_thinking_and_busy_pools` — по 5–10 строк, без повторов, без латиницы и эмодзи.
  - `app_spec`: `test_remote_answer_budget_25s` — один провайдер, `timeout_s` первой попытки == 25; `test_budget_is_8s_and_uses_monotonic_clock` (`app_spec.lua:64-66`) остаётся зелёным.
- [ ] **Step 2: Запустить** `tests/run.sh` — новые тесты FAIL.
- [ ] **Step 3: Реализовать.** Таймер раздумья ставится в момент `Runner:start` для страницы; пришёл ответ раньше — таймер снят. Отказ: `onPageDone` при `inflight > 0` в асинхронном режиме — без `saveSample`, `inflight` не растёт. Тексты фраз — по 6–10 в голосе персонажа (Global Constraints), это «Тексты фраз-раздумий и отказов» из «Оставлено исполнителю».
- [ ] **Step 4: `tests/run.sh` — все зелёные.**
- [ ] **Step 5: Commit** `feat(widget): фраза-раздумье через 2 с, отказ на запись во время раздумья, потолок ответа 30 с`.

**Тестер на Kindle:** (а) обычный ответ быстрее 2 с — без фразы; (б) медленный (Wi-Fi слабый) — фраза ~2 с после конца страницы, затем ответ её сменяет; (в) во время фразы написать ещё строку — чернила гаснут, отказ, потом ответ на первую; (г) Wi-Fi без интернета — фраза, затем «медленная» фраза не позже 30 с. Улики: строки `ponder shown after`, `page during ponder -> refusal`, `worker answer failed: timeout` с временем ≤ 30 000 мс.

---

### Срез 3: Notion → хранилище на Kindle

Результат: при сне Kindle и при открытии дневника (если удачному чтению больше часа) Notion читается фоном в `/mnt/us/riddle/knowledge.sqlite3`; перечитываются только изменённые; ошибки Notion не мешают дневнику.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/http.lua:337-349` (+`http.request(method, url, headers, body, timeout_s)`; `post` = `request("POST", …)`)
- Modify: `plugin/riddlediary.koplugin/riddle/config.lua:57-103` (+`cfg.notion_token` через `clean_key`)
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua:61-76` (секрет `notion_token`)
- Create: `plugin/riddlediary.koplugin/riddle/notion.lua`, `riddle/notion_text.lua`, `riddle/knowledge.lua`, `riddle/sync.lua`
- Modify: `plugin/riddlediary.koplugin/main.lua:160-187` (запуск синхронизации), `riddle_diarywidget.lua` (`penDown` → `runner:cancel("sync")`; `maybeIdle` → `self.on_idle()`)
- Modify: `tools/push_config.sh` (`NOTION_DIARY_API` → `notion_token = "…"`, как `add openrouter_key`, `push_config.sh:73`)
- Test: `tests/notion_spec.lua`, `tests/notion_text_spec.lua`, `tests/knowledge_spec.lua`, `tests/sync_spec.lua` (новые), `tests/http_direct_spec.lua`, `tests/config_spec.lua`, `tests/app_spec.lua`, `tests/push_config_spec.lua`

**Interfaces:**
- Produces:
  - `notion.new{ token, request, sleep, clock, min_interval_s = 0.34, version = "2025-09-03", timeout_s = 20 } -> client`; `client:search_all() -> objs | nil, err`; `client:query_all(data_source_id) -> pages | nil, err`; `client:blocks_text(page_id, max_chars = 20000) -> text | nil, err` (рекурсия по `has_children`, кроме `child_page`/`child_database`, глубина ≤ 3; строка таблицы — ячейки через ` | `). 429 → `sleep(Retry-After или 1)`, ≤ 5 повторов; 401/403 → `"unauthorized"`; прочее → `"http <код>"` или ошибка транспорта. В `err` никогда нет токена (строится из статуса и `code`).
  - `notion_text.title(obj) -> string`; `notion_text.props(page, titles_by_id) -> { {name, value}, … }` (сначала свойство-title, остальные по имени; пустые и неизвестные типы пропущены; relation → названия из `titles_by_id`, неизвестные id пропущены; people → `name`, если есть; date → `start` или `start – end`; checkbox → «да»/«нет»); `notion_text.doc(source_title | nil, page, body, titles_by_id) -> text` — строка базы: первой строкой название базы, затем строки `Свойство: значение`, затем пустая строка и тело, если есть; страница вне базы — название, тело.
  - `knowledge.PATH = "/mnt/us/riddle/knowledge.sqlite3"`; `knowledge.open(path) -> K` (схема через `PRAGMA user_version`, как `memory.lua:20-28`, `busy_timeout` 2000 мс); `K:close()`; `K:edited_map() -> { [id] = edited }`; `K:put_source(id, title)`; `K:put_doc{ id, source_id, title, edited, text, props_json }` (одна транзакция на документ); `K:delete_missing(seen_ids_set)`; `K:meta(k)`, `K:set_meta(k, v)`; `K:stats() -> { docs, chars }`.
  - `sync.run(d) -> stats` (выполняется в дочернем): `d = { client, store_path, wall, clock }`; шаги: `search_all` → базы и страницы (`in_trash` пропускаются) → `query_all` по каждой базе → карта id→название → для документа с `edited ~= stored` **или** `edited ≥ meta("started_prev") − 120 с` (точность `last_edited_time` документацией не обещана — перечитываем окно) → `blocks_text` → `put_doc` → `delete_missing` → `set_meta("last_ok", wall)` и `set_meta("started_prev", start)` только если без ошибок. `stats = { seen, updated, deleted, chars, ms, err? }`.
  - `sync.STALE_S = 3600`; `sync.should_start(now, last_ok, busy) -> bool`.
  - Плагин: `startSync(why)` — есть `cfg.notion_token`, runner свободен → `runner:start("sync", …, { timeout_s = 600 })`. Триггеры: `onSuspend` (всегда), открытие дневника и `on_idle` виджета (если `should_start`, не чаще раза в 60 с). `last_ok` родитель читает: открыть → `meta` → закрыть.

- [ ] **Step 1: Тесты (падают)**:
  - `http_direct_spec`: `test_get_sends_method_without_body`.
  - `notion_spec` (поддельный `request` с журналом): `test_search_paginates_until_has_more_false`, `test_query_uses_data_sources_path`, `test_429_waits_retry_after` (`sleep(2)` при `Retry-After: 2`), `test_401_is_unauthorized_without_token` (токен `secret_abc123` не входит в `err`), `test_min_interval_between_requests` (между вызовами по часам ≥ 0.34 с), `test_blocks_recursion_depth_and_cap`.
  - `notion_text_spec`: по тесту на каждый тип из таблицы «Опоры» (`title`, `rich_text`, `number`, `select`, `multi_select`, `status`, `date`, `checkbox`, `url`, `email`, `phone_number`, `formula`, `rollup`, `relation`, `people`, `files`, `unique_id`); `test_row_text_format` — ровно `"Фильмы\nНазвание: Дюна\nОценка: 9\n\nтело"`; `test_unknown_property_type_skipped` (`button`, `verification`, `"future_type"`).
  - `knowledge_spec`: `test_put_doc_and_edited_map`, `test_delete_missing`, `test_meta_roundtrip_survives_reopen`, `test_stats_counts_chars_not_bytes`.
  - `sync_spec` (поддельный client): `test_first_sync_reads_all`, `test_unchanged_docs_not_refetched` (второй прогон: `blocks_text` не вызван), `test_recent_window_refetched` (edited внутри окна 120 с — перечитан), `test_changed_doc_refetched_only`, `test_removed_doc_deleted`, `test_partial_sync_keeps_committed_docs` (ошибка на 3-м документе: первые 2 в базе, `last_ok` не обновлён, `stats.err` есть), `test_empty_workspace_sync_ok`, `test_should_start_after_hour`.
  - `config_spec`: `test_notion_token_cleaned` (пробелы, заглушка `your_token_here` → nil). `app_spec`: `test_notion_token_masked_in_logs`. `push_config_spec`: `test_notion_token_written`.
- [ ] **Step 2: Запустить** `tests/run.sh` — новые FAIL.
- [ ] **Step 3: Реализовать модули** (порядок: http → notion_text → notion → knowledge → sync). Лог синхронизации — `riddle: sync start (%s)`, `riddle: sync done seen=%d updated=%d deleted=%d chars=%d in %d ms`, `riddle: sync stopped: %s (updated=%d)`; без названий и текстов.
- [ ] **Step 4: Подключить в `main.lua` и виджете** (триггеры выше, отмена на `penDown`; ответ вытесняет sync сам — срез 1).
- [ ] **Step 5: `tests/run.sh` — все зелёные.**
- [ ] **Step 6: Commit** `feat(notion): фоновое чтение Notion в knowledge.sqlite3 при сне и открытии дневника`.

**Тестер на Kindle** (токен кладёт оркестратор `tools/push_config.sh`): кнопка сна (`lipc-set-prop … powerButton 1`) → в `crash.log` `sync start (suspend)` и `sync done …` либо `sync stopped: … (updated=N)`; открыть дневник через > 1 ч после неудачи — `sync start (stale)`; во время синхронизации писать — `sync` отменён, перо без задержек. Отозванный токен (оркестратор) → `sync stopped: unauthorized`, дневник отвечает.

---

### Срез 4: Маленький Notion в ответе

Результат: если весь текст знаний ≤ `SMALL_CHARS`, он целиком идёт в системный промпт открытой печати с правилами роли; больше порога и нет отпечатков — недавно изменённое до порога. До первого чтения и без токена — как сейчас.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/knowledge.lua` (+`all_text`, `recent_text`)
- Modify: `plugin/riddlediary.koplugin/riddle/prompt.lua:45-66`
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua:69-80` (`_open_context` + `ctx.knowledge`)
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua:182-197` (dep `knowledge_text`)
- Test: `tests/knowledge_spec.lua`, `tests/prompt_spec.lua`, `tests/controller_spec.lua`, `tests/app_spec.lua`

**Interfaces:**
- Consumes: `knowledge.open/K:stats` (срез 3), `Controller:begin` (срез 1).
- Produces: `knowledge.SMALL_CHARS = 30000`; `K:all_text() -> text` (по базам, внутри по названию); `K:recent_text(max_chars) -> text` (по `edited` убыв., документы целиком до лимита); dep контроллера `knowledge_text() -> text | nil, mode` (`mode` ∈ `"small"`, `"recent"`; открывает и закрывает базу; любая ошибка → nil + лог `riddle: knowledge read failed: <masked>`); `prompt.open(png_b64, ctx)` с `ctx.knowledge`.

- [ ] **Step 1: Тесты (падают)**:
  - `prompt_spec`: `test_prompt_without_knowledge_unchanged` (системный промпт байт-в-байт как до среза при `ctx.knowledge == nil` и `""`), `test_knowledge_section_and_rules` — раздел со знанием и правила: отвечать на заданный вопрос; отбирать и сортировать по полям, если спрошено; не пересказывать; не называть, откуда знание, не упоминать Notion, таблицы, базы, поля, токены; не выдумывать фактов о хозяйке и её данных; нет в знании — сказать в образе, что не знаешь. Лор (`ctx.lore`) остаётся отдельным разделом.
  - `knowledge_spec`: `test_all_text_groups_by_source`, `test_recent_text_newest_first_within_cap`.
  - `controller_spec`: `test_begin_open_includes_knowledge`, `test_begin_locked_has_no_knowledge`, `test_knowledge_read_failure_still_answers`.
  - `app_spec`: `test_knowledge_small_vs_recent_by_threshold` (31 000 знаков без отпечатков → `"recent"`, лог `riddle: knowledge recent chars=30000 of 31000`; 20 000 → `"small"`).
- [ ] **Step 2: Запустить** — FAIL.
- [ ] **Step 3: Реализовать.** Знание читается в `begin` в родителе, до `fork`.
- [ ] **Step 4: `tests/run.sh` — зелёные.**
- [ ] **Step 5: Commit** `feat(prompt): знания из Notion в ответе открытой печати, маленький Notion целиком`.

**Тестер на Kindle:** после `sync done` открыть печать и написать «какие фильмы нам двоим понравились?» — ответ называет фильмы из базы с верхними оценками (сверка с базой — оркестратор), в голосе персонажа, без «Notion», «таблица», «поле», без перечисления свойств; вопрос о том, чего в Notion нет, — без выдуманных фактов. Улики: `knowledge small chars=…`, `worker answer done in … ms`.

---

### Срез 5: Отпечатки кусков при синхронизации

Результат: при заданном в конфиге провайдере отпечатков синхронизация режет документы на куски и сохраняет нормированные векторы; изменённые документы переотпечатываются, остальные нет.

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/config.lua` (+`cfg.embeddings = { url, model, key }`: только https, ключ через `clean_key`, иначе nil)
- Modify: `plugin/riddlediary.koplugin/riddle/app.lua:17-27`, `:61-76` (хост — в прогрев DNS; ключ — в секреты)
- Create: `plugin/riddlediary.koplugin/riddle/chunk.lua`, `riddle/embed.lua`
- Modify: `plugin/riddlediary.koplugin/riddle/knowledge.lua` (таблица `chunks`, миграция версии), `riddle/sync.lua`
- Modify: `tools/push_config.sh` (`CF_WORKERS_AI_ACCOUNT_ID` + `CF_WORKERS_AI_TOKEN` → `embeddings = { url = "https://api.cloudflare.com/client/v4/accounts/<id>/ai/v1/embeddings", model = "@cf/baai/bge-m3", key = … }`)
- Test: `tests/chunk_spec.lua`, `tests/embed_spec.lua` (новые), `tests/knowledge_spec.lua`, `tests/sync_spec.lua`, `tests/config_spec.lua`, `tests/push_config_spec.lua`

**Interfaces:**
- Consumes: `K`, `sync.run` (срез 3).
- Produces: `chunk.split(text) -> { text, … }` (≤ `chunk.WHOLE = 1500` знаков — один кусок; длиннее — по абзацам, пакуя до ~1500, перекрытие — хвост предыдущего ≤ `chunk.OVERLAP = 300`; жёсткий потолок `chunk.CAP = 8000`, резка по кодпойнтам UTF-8); `embed.new{ url, model, key, request, timeout_s = 20 } -> E`; `E:vectors(texts) -> { float[1024]… }, tokens | nil, err` (пакеты ≤ `embed.BATCH = 200`, порядок по `index`, нормировка L2); `K:put_chunks(doc_id, texts)` (заменяет куски документа, векторы сбрасывает); `K:chunks_without_vec(limit) -> { {id, text}… }`; `K:set_vec(id, blob)` (float32, `dim` в строке); `meta("embed_model")` — смена модели сбрасывает все векторы.

- [ ] **Step 1: Тесты (падают)**: `chunk_spec` — `test_short_text_one_chunk`, `test_long_text_paragraph_packing_with_overlap`, `test_cap_8000`, `test_no_broken_utf8`; `embed_spec` — `test_body_model_and_input`, `test_450_texts_three_calls`, `test_vectors_sorted_by_index_and_normalized`, `test_error_masks_key`; `knowledge_spec` — `test_vec_blob_roundtrip_1024`, `test_model_change_drops_vectors`; `sync_spec` — `test_changed_doc_rechunked_and_reembedded`, `test_unchanged_doc_not_reembedded`, `test_embed_quota_error_keeps_done_vectors` (429 на 2-м пакете: векторы 1-го сохранены, `stats.err`); `config_spec` — `test_embeddings_https_only`; `push_config_spec` — `test_embeddings_written_from_cf_env`.
- [ ] **Step 2: Запустить** — FAIL.
- [ ] **Step 3: Реализовать.** Отпечатки — после текстового прохода, тем же дочерним процессом; лог `riddle: embed %d chunks tokens=%d in %d ms`.
- [ ] **Step 4: `tests/run.sh` — зелёные.**
- [ ] **Step 5: Commit** `feat(knowledge): куски и отпечатки bge-m3 при синхронизации Notion`.

**Тестер на Kindle** (ключи CF кладёт оркестратор): после сна — `embed N chunks tokens=…`; повторный сон без правок в Notion — `embed 0 chunks`.

---

### Срез 6: Большой Notion — поиск по смыслу в ответе

Результат: если текста знаний больше `SMALL_CHARS` и есть векторы, ответ идёт в два вызова в дочернем процессе: чтение рукописи → отпечаток записи → top-K кусков → (находки в одной базе — вся база компактной таблицей) → ответ со знанием. Сбой отпечатка — ответ с недавним текстом (срез 4).

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/search.lua`
- Modify: `plugin/riddlediary.koplugin/riddle/knowledge.lua` (+`iter_vectors`, `chunk_texts`, `source_table`, `toc`)
- Modify: `plugin/riddlediary.koplugin/riddle/prompt.lua` (+`prompt.read_only`, `prompt.answer`)
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua` (`begin`, режим `"search"`), `riddle/app.lua` (`remote_fn` для двух вызовов в общем бюджете 25 с)
- Test: `tests/search_spec.lua` (новый), `tests/knowledge_spec.lua`, `tests/prompt_spec.lua`, `tests/app_spec.lua`, `tests/controller_spec.lua`

**Interfaces:**
- Consumes: `E:vectors` (срез 5), `K:recent_text` (срез 4), `chain:remote_fn` (срез 1).
- Produces: `search.topk(iter, qvec, k) -> { {chunk_id, doc_id, source_id, score}… }` (векторы нормированы → скалярное произведение, FFI, как `bench_topk.lua:49-64`); `search.pick(hits, opts) -> { mode = "table", source_id } | { mode = "chunks", ids }` (`search.TOP_K = 8`, `search.CONC = 5`: ≥ 5 из 8 находок из одной базы → таблица); `K:source_table(source_id, max_rows = 200, max_chars = 20000) -> text` (первая строка — названия свойств через ` | `, далее строки значений; обрезка по лимиту с пометкой «…ещё N»); `K:toc() -> text` (базы с числом строк, страницы корня); `prompt.read_only(png_b64)` (JSON `{"read"}`), `prompt.answer(read, ctx)` (текстовые messages: персона, лор, пересказы, `ctx.toc`, `ctx.knowledge` с правилами среза 4, недавние реплики, запись хозяйки текстом). Дочерний открывает `knowledge.sqlite3` сам (Global Constraints).

- [ ] **Step 1: Тесты (падают)**: `search_spec` — `test_topk_matches_bruteforce` (N = 500, D = 1024, сид), `test_k_greater_than_n`, `test_pick_table_when_concentrated`, `test_pick_chunks_when_spread`; `knowledge_spec` — `test_source_table_limits`, `test_toc_counts`; `prompt_spec` — `test_answer_prompt_has_read_text_and_rules`; `app_spec` — `test_search_mode_calls_order_read_embed_answer` (журнал поддельного http: chat → embeddings → chat), `test_second_call_gets_remaining_budget`, `test_embed_failure_falls_back_to_recent`, `test_unreadable_skips_search` (`read == "?"` → без embeddings и второго вызова); `controller_spec` — `test_begin_picks_search_mode_only_when_big_and_vectors`.
- [ ] **Step 2: Запустить** — FAIL.
- [ ] **Step 3: Реализовать.** Режим выбирается в `begin` (родитель): `stats.chars > SMALL_CHARS` и `cfg.embeddings` и векторы есть. Лог `riddle: knowledge search hits=%d mode=%s in %d ms`.
- [ ] **Step 4: `tests/run.sh` — зелёные.**
- [ ] **Step 5: Commit** `feat(knowledge): большой Notion — поиск по отпечаткам и таблица базы в ответе`.

**Тестер на Kindle:** у владельца Notion маленький, поэтому проверка на синтетике: оркестратор кладёт тестовый `knowledge.sqlite3` (> 30 000 знаков, база «Фильмы» на 300 строк) — вопрос о топ-5 по оценке → режим `table`, ответ по данным; вопрос о странице вне баз → режим `chunks`. Улики: `knowledge search hits=8 mode=table`, время ответа.

---

## «Оставлено исполнителю» → срез и замер

| Пункт описания | Срез | Чем решается |
|---|---|---|
| Порог «маленький Notion» ~30 000 знаков | 4 | D6: время ответа с полным знанием и верность «топ-5»; D5 даёт фактический объём Notion владельца |
| Число кусков в запрос (`TOP_K`), лимит таблицы базы | 6 | D8: время двух вызовов и качество на синтетике; старт — 8 кусков, 200 строк / 20 000 знаков |
| 2 с до фразы-раздумья | 2 | D3: доля ответов < 2 с по `worker answer done in` за сессию тестера |
| Потолок ~30 с | 2 (+ пересмотр в 4, 6) | D4 и максимум `worker answer done in` в D6/D8 |
| Формат хранения | 3, 5 | решено: отдельная `knowledge.sqlite3` (пишет дочерний, родитель читает коротко); векторы float32, int8 — если D8 даёт поиск > 300 мс |
| Один или два вызова | 4, 6 | маленький — один вызов (как сейчас, знание в системном); большой — два (без текста записи искать нечем); D8 — задержка двух вызовов |
| Тексты фраз-раздумий и отказов | 2 | 6–10 заготовок каждого пула в голосе текущего персонажа |
| Ошибки Notion | 3 | тесты `notion_spec`/`sync_spec`; живьём — отозванный токен у тестера |

## Замер на устройстве (делает исполнитель с правом деплоя / тестер)

- **D0 (до среза 1):** `ffi/util.lua` устройства совпадает с копией в строках 317–522 (`runInSubProcess`, `isSubProcessDone`, `terminateSubProcess`, `getNonBlockingReadSize`, `writeToFD`, `readAllFromFD`). Нужен вывод `sed -n 317,522p /mnt/us/koreader/ffi/util.lua` — через оркестратора (у исполнителя w3 нет произвольного `ssh`).
- **D1 (срез 1):** RSS дочернего процесса и задержка fork: `child RSS KB` в логе на 10 ответах; время ответа до и после среза (`on_page -> text` против `worker answer done`).
- **D2 (срез 1):** нет зомби: после 10 ответов и одного сна посреди ответа — ни одной строки `worker answer failed` кроме ожидаемых, `RSS` родителя (`answer gone … RSS KB`) не растёт.
- **D3 (срез 2):** распределение времени ответа → проверка `ponder_s = 2.0`.
- **D4 (срез 2):** Wi-Fi без интернета → `worker answer failed: timeout` ≤ 30 000 мс.
- **D5 (срез 3):** после кнопки сна: сколько живут CPU и Wi-Fi до настоящего сна (сколько документов успевает `sync`), время полного первого чтения, `chars=` (подтверждает «маленький» у владельца), RSS дочернего при синхронизации.
- **D6 (срез 4):** время ответа с ~30 000 знаков знания (Gemini flash-lite + картинка). Решение оркестратора 2026-10-25: путь ответа (`remote_fn`, бюджет 25 с) получает свой потолок попытки провайдера 12 с вместо 4 с (`llm.lua:9`) — закладывается в срезе 2 вместе с бюджетом 25 с; синхронные вызовы (пересказ, devtest) остаются на 4 с. D6 подтверждает или сдвигает 12 с.
- **D7 (срез 5):** время отпечатков полного Notion и `tokens=` за проход (квота 10 000 нейронов/сутки ≈ 9,3 млн токенов).
- **D8 (срез 6):** `luajit bench_topk.lua` на Kindle (KOReader luajit) для N = 2000 / 10 000 + сканирование векторов из SQLite на FAT; задержка двух вызовов.

## ASSUMPTION

Нет. Всё, что нельзя проверить на Mac, — в списке «Замер на устройстве».

## Расхождения описания с кодом

1. Описание называет базу памяти `diary.sqlite`; в коде `/mnt/us/riddle/diary.sqlite3` (`main.lua:18`).
2. Комментарии виджета говорят о бюджете 5 с (`riddle_diarywidget.lua:28`, `:365`), в коде 8 с (`app.lua:11`) — комментарии устарели; правятся в срезе 1.
3. Описание: чтение Notion «не во время записи» и повтор «в паузах между страницами». В плане синхронизация идёт в дочернем процессе и отменяется на касание пера (`penDown`) и на ответ; прогресс не теряется (транзакция на документ). Это исполнение описания, не отступление — отмечено, потому что механизма «пауз» в коде сейчас нет.
4. Пересказ прошлой сессии (`controller.lua:137-148`) остаётся синхронным с бюджетом 8 с — описание переносит в отдельный процесс только путь ответа.

## Вне плана

- Сеттинг, режим настройки, граница лора персонажа, удаление `lore.md` / `lore_push.sh` / таблицы `lore` — следующее описание.
- Запись в Notion.
- Перенос пересказа сессии в дочерний процесс.
