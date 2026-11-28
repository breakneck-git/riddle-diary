# Знаки управления Kindle — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** знак пером на странице дневника (↑, ↓, полумесяц, квадрат, молния) выполняет команду устройства (подсветка, ночной режим, полное обновление, Wi‑Fi) и печатает короткий итог на месте страницы.

**Architecture:** один распознаватель — `glyph.match` по вшитым шаблонам (`riddle/sign_shapes.lua`) со своим порогом и своими воротами размера (параметр `opts` у `glyph.match`, не копия). `riddle/signs.lua` — таблица знаков и `detect` в контракте `isSign` (как у треугольника и розы). `riddle/control.lua` — чистая таблица «знак → команда» над внедрёнными источниками устройства. Виджет ставит знак в очередь как фразу ключа (`kind = "control"`), команда выполняется в свою очередь, когда чернила растворились.

**Tech Stack:** Lua (LuaJIT), плагин KOReader, тесты `tests/run.sh` (luajit на Mac).

**Spec:** `docs/superpowers/specs/2026-11-28-control-signs-design.md` (4a8ba9e).

## Global Constraints

- Ложное срабатывание хуже пропуска; знак не путается с треугольником, розой, ключом печати (спека «Анти-цель»).
- Порядок проверок: ключ печати → треугольник → знаки → роза → случайное касание → модель (спека «Решено»).
- Знаки работают при любой печати; под закрытой печатью с ключом попытка, не ставшая знаком, файлом не пишется (спека «Решено»).
- Итоги: «Подсветка N из 25», «Подсветка выключена», «Ночной режим включён/выключен», «Wi‑Fi выключен/включён» (дефис U+2011, как в `riddle/status.lua`); квадрат — без текста.
- Громкости, меню кнопок, знаков владельца-образцов нет (спека «Не цель»).
- Один распознаватель (подход А): новый знак — строка в `signs.LIST`, шаблон в `sign_shapes`, команда в `control.COMMANDS`.
- Срез 100–400 строк диффа, тест до кода, `sh tests/run.sh` зелёный (база 4a8ba9e: «75 specs, OK», 60 с) перед каждым коммитом; коммит в `main` клона, без push.
- Запреты: `/mnt/us/riddle/seal_key.lua` не читать; `~/.envs` не читать; на Kindle только чтение; деплой и перезапуск — оркестратор/владелец.

## Факты (заземление)

### Код (4a8ba9e)

| # | Факт | Улика |
|---|------|-------|
| K1 | Порядок в `onPageDone`: ключ (`key_try`, `ctl:key_page`) → `record` → `isSign(triangle…)` → роза под открытой печатью → `tiny` | `riddle_diarywidget.lua:1451-1464, 1465-1468, 1469-1472, 1473-1476, 1479-1483` |
| K2 | `record`: под закрытой печатью `false`, если была сверка ключа и образец есть, иначе `"hits"`; под открытой — `nil` | `riddle_diarywidget.lua:1465-1468` |
| K3 | `isSign(mod, name, strokes, record)` зовёт `mod.detect` → `ok, score, why`; без devmode возвращает `ok`; в devmode пишет файл при `#strokes <= mod.MAX_STROKES` и строку `riddle: <name> yes|no score=… <crit>=… n=… file=…` по `mod.CRITERIA`; возвращает `ok` как есть (истинное значение любого типа) | `riddle_diarywidget.lua:1892-1904` |
| K4 | `recordStrokes` пишет страницу один раз, сколько бы знаков её ни проверило | `riddle_diarywidget.lua:1910-1926` |
| K5 | Фраза ключа — в очередь `{ text, top, page, kind = "key" }` + `nextAnswer`; особого разбора у `"key"` нет, кроме «не ответ модели» | `riddle_diarywidget.lua:1458-1462, 1727-1728, 1792` |
| K6 | `nextAnswer`: ждёт растворения чернил страницы, снимает голову очереди, `MODES[q.kind]` открывает режим, иначе `revealAnswer(q.text, q.top, q.unlocked, q.kind, q.release, q.page)` | `riddle_diarywidget.lua:1658-1682`, `MODES` — `:181` |
| K7 | `hold.seconds`: всё, кроме `"think"`, держится как ответ | `riddle/hold.lua:15-23` |
| K8 | Полное обновление дневника — `self:push(0, 0, self.w, self.h, "full")`; `paintTo` блитит холст — `setDirty("all","full")` перерисует дневник целиком | `riddle_diarywidget.lua:2072, 2156, 698-700` |
| K9 | Источники устройства в виджете — методами, тесты их подменяют (`traySources`, `statusSources`) | `riddle_diarywidget.lua:1018, 2085` |
| K18 | «Включён ли канал связи» знает только `net.state()` (`net.CHANNELS` — методы NetworkMgr); его читают `traySources` и `statusSources` | `riddle/net.lua:7-28`; `riddle_diarywidget.lua:1019, 2091` |
| K19 | В devmode каждая строка оценки `isSign` несёт `file=` (имя одно — `recordStrokes`); тест «оба знака» ждёт 2 таких строки | `riddle_diarywidget.lua:1896-1902, 1911-1914`; `tests/status_page_spec.lua:499-509` |
| K10 | `glyph.match(strokes, drawings)`: ворота `count` (1..MAX_STROKES и совместимость по числу штрихов), `size` (меньшая сторона < `glyph.SIZE` = 150), `dist` (> `glyph.DIST` = 3.0) — порог и размер зашиты | `riddle/glyph.lua:185-200, 21, 24` |
| K11 | `glyph.fits` «занятыми» считает только треугольник и розу; `glyph` требует `riddle.rose`, `riddle.triangle` на верхнем уровне | `riddle/glyph.lua:204-210, 13-15` |
| K12 | Задание ключа: `glyph.fits` → `texts.key_taken` / `key_bigger` | `riddle/controller.lua:150-152` |
| K13 | devmode читается при загрузке модуля виджета (нужен перезапуск KOReader); `deploy.sh --dev` ставит `/mnt/us/riddle/devmode` | `riddle_diarywidget.lua:2296-2300`, `tools/deploy.sh:42` |
| K14 | Квадрат — образец ключа во всех тестах ключа: `TR.square`/`SQUARE` | `tests/seal_key_spec.lua:23-24`, `tests/status_page_spec.lua:783-784`, `tests/controller_spec.lua:499`, `tests/glyph_spec.lua:351-363` |
| K15 | `TF.square` на странице в тестах виджета: «оба знака — один файл» (открытая печать) и «закрытая печать, квадрат — файла нет» | `tests/status_page_spec.lua:499-509, 522` |
| K16 | Стенд виджета с очередью, раннером, логом, `page_done`, `run(s)`, `count(needle)` — в `status_page_spec.lua`; знаки на странице (треугольник, роза, ключ) тестируются там же | `tests/status_page_spec.lua:57-192, 232-268, 805-900` |
| K17 | Тест-уровень записи знака без контроллера — `rose_record_spec.lua` (стенд `diary(devmode)` + `isRose`) | `tests/rose_record_spec.lua:48-110` |

### KOReader на Kindle (ssh kindle, 2026-11-28, только чтение)

| # | Факт | Улика |
|---|------|-------|
| D1 | PW2: `fl_max = 24`, `canTurnFrontlightOff = no` → `fl_max + 1` = 25 | `frontend/device/kindle/powerd.lua:9, 23-25`; `kindle/device.lua:914-918` |
| D2 | Рецепт KOReader для шага подсветки: `new = powerd:frontlightIntensity() + delta`; `<= 0` → `turnOffFrontlight()`, иначе `setIntensity(new)`; затем `updateResumeFrontlightState()` | `frontend/device/devicelistener.lua:102-121` |
| D3 | `frontlightIntensity()` — 0, если свет выключен; `setIntensity` сама ограничивает `[fl_min, fl_max]` | `device/generic/powerd.lua:126-133, 210-226` |
| D4 | Ночной режим — `DeviceListener:onToggleNightMode`: `Screen:toggleNightMode()`, `setDirty("all","full")`, `G_reader_settings` `night_mode` | `devicelistener.lua:14-24` |
| D5 | На PW2 инверсия аппаратная (`setHWNightmode`); в ночном режиме подменяется только partial-волна, быстрые A2/DU пера не трогаются | `ffi/framebuffer.lua:476-490`; `ffi/framebuffer_mxcfb.lua:389-411, 89-91` |
| D6 | `NetworkMgr:turnOnWifi` на Kindle → `reconnectOrShowNetworkMenu`, который показывает `InfoMessage` «Scanning for networks…»; `restoreWifiAsync` — только `kindleEnableWifi(1)`; `turnOffWifi` — `kindleEnableWifi(0)` | `kindle/device.lua:375-378, 389-394, 401-403`; `ui/network/manager.lua:1060-1063` |
| D9 | Пара KOReader для включения в фоне: `restoreWifiAsync()` + `scheduleConnectivityCheck()`; проверка связи шлёт `NetworkConnected` (его ловит прогрев DNS дневника), сдаётся через 180 × 0.25 с (~45 с) через `_abortWifiConnection` без окна (окно только при `widget`) и на Kindle сам выключает Wi‑Fi (`hasSeamlessWifiToggle` = yes по умолчанию) | `ui/network/manager.lua:40-54, 74-95, 121-124, 143-146`; `device/generic/device.lua:53, 323-326`; `ui/network/networklistener.lua:221-224`; `main.lua:474-482` |
| D10 | Выключение по-KOReader: `NetworkMgr:disableWifi(cb, interactive)` — события `NetworkDisconnecting/Disconnected`, снимает проверку связи, при `interactive` пишет `wifi_was_on = false` (сон не вернёт Wi‑Fi сам); окна нет (окно — у `toggleWifiOff`) | `ui/network/manager.lua:370-395, 411-420` |
| D11 | Kindle `setIntensityHW` в конце зовёт `_decideFrontlightState()` → `is_fl_on` по железу: из выключенной `setIntensity(5)` → `frontlightIntensity() == 5`, следующий ↑ — 10 | `device/kindle/powerd.lua:122-153`; `device/generic/powerd.lua:112-115, 126-133` |
| D7 | Выключение Wi‑Fi рвёт ssh (ssh ходит по `wlan0`) | спека, «Проверенные факты» |
| D8 | В `/mnt/us/riddle/roses` 115 старых файлов (последний 2026-11-20); фикс «попытка ключа не пишется» — 87e4bbb от 2026-11-25 → старые файлы могут нести попытки ключа | `ls /mnt/us/riddle/roses`; `git log -1 87e4bbb` |

### Замеры (luajit, скретч-скрипт на `riddle.glyph`, 4a8ba9e; шаблоны — вершины из Task 1–2, редкие и плотные ломаные дают одно и то же)

| # | Пара | Расстояние |
|---|------|------------|
| M1 | свои варианты синтетических стрелок (поворот ±10°, шире, короче, другой порядок штрихов) против шаблона | 0.00–1.33 |
| M2 | ↑ в 1 штрих против молнии / ↓ в 1 штрих против молнии | 2.94 / 3.06 |
| M3 | `R.cross_only` против ↓ в 2 штриха / ↑ в 2 штриха | 2.97 / 3.20 |
| M4 | `TF.digit_4_closed` против ↓ в 2 штриха; `TF.digit_4_closed_one` против ↓ в 1 штрих | 3.01; 3.21 |
| M5 | квадрат против `TF.square` / `TF.circle` / `TF.pentagon`; полумесяц против `TF.pentagon` | 0.35 / 3.37 / 3.90; 4.15 |
| M6 | узкая стрелка (меньшая сторона 120 px) — ворота `size` при `glyph.SIZE` = 150 | gate `size` |
| M7 | ↑ против ↓: 1 штрих / 2 штриха | 4.10 / 3.12 |
| M8 | поворот своего шаблона ±10° / ±5°: стрелки, полумесяц, молния; квадрат | ≤ 1.26 / ≤ 0.69; **2.50–2.63** / 1.40–1.76 |

Вывод: порог ключа 3.0 для знаков не годится (M2–M4 ниже); до калибровки — `signs.DIST = 2.0`, `signs.SIZE = 100`. Облако не прощает поворот квадрата (M8): наклон своей руки покрывают шаблоны владельца (Task 3).

## ASSUMPTION (снимаются в срезе 5, живой прогон)

1. Аппаратная инверсия накрывает экран дневника (он пишет в `Screen.bb` мимо UIManager), чернила A2 видны в ночном режиме, `ToggleNightMode` и `SetFlIntensity` (подсветка — событием KOReader, ревью Task 1, B1) через `UIManager:broadcastEvent` доходят до `DeviceListener`, пока дневник открыт (D4, D5 — код; вживую не видели).
2. Wi‑Fi через `restoreWifiAsync` + `scheduleConnectivityCheck` сам подключается к известной сети и шлёт `NetworkConnected` (D9 — по коду; окна нет по коду; само подключение и прогрев DNS — вживую).
3. Пороги и шаблоны по живым рисункам владельца дают зазор «свои < порог < чужие» ≥ 0.4 (срез 3).
4. Ключ печати владельца не похож ни на один из пяти знаков (образец читать нельзя): иначе этот знак не сработает никогда — ключ проверяется первым. Вопрос владельцу.

## Review Focus

1. Знак поверх проявляющегося ответа: перо гасит ответ, страница-знак выполняет команду и не становится «перебиванием» — тест в срезе 1 (`test_sign_over_answer_no_interjection`).
2. ↑ на максимуме и ↓ при выключенной подсветке — видимый итог, не тишина — срез 1 (`control_spec`).
3. Источник устройства бросил ошибку — строка лога и «Не вышло.», дневник жив — срез 1 (`test_run_source_error_visible`).
4. Знак, пока ответ модели в полёте: страница в модель не уходит, команда — в свою очередь, ответ приходит потом — срез 1 (`test_sign_during_inflight`).
5. Сон с командой в очереди: очередь сброшена, после пробуждения команда не выполняется — срез 1 (`test_sleep_drops_queued_control`).

---

### Task 1: Каркас знаков и подсветка ↑/↓ (≈350 строк)

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/glyph.lua:181-200` (параметр `opts`)
- Create: `plugin/riddlediary.koplugin/riddle/sign_shapes.lua`, `riddle/signs.lua`, `riddle/control.lua`
- Modify: `plugin/riddlediary.koplugin/riddle/texts.lua` (после `:305`)
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua:1469-1472` (знаки после треугольника), `:1658-1682` (`nextAnswer`), новый `Diary:runControl`, `Diary:controlSources`
- Test: `tests/glyph_spec.lua`, `tests/signs_spec.lua` (новый), `tests/control_spec.lua` (новый), `tests/status_page_spec.lua`

**Interfaces:**
- Produces:
  - `glyph.match(strokes, drawings, opts) -> ok, dist, gate` — `opts = { dist = number?, size = number? }`, `nil` → `glyph.DIST`, `glyph.SIZE`.
  - `sign_shapes` — `{ [name] = { drawing, … } }`, рисунок — список штрихов `{ p = { x1, y1, … } }`.
  - `signs.LIST = { "up", "down" }` (порядок лога), `signs.CRITERIA = signs.LIST`, `signs.DIST = 2.0`, `signs.SIZE = 100`, `signs.MAX_STROKES = glyph.MAX_STROKES`.
  - `signs.detect(strokes) -> name|false, score, why` — `score` — наименьшее расстояние (`math.huge` — не с чем сравнить), `why[name] = dist / signs.DIST` для знаков, дошедших до облака.
  - `control.LIGHT_STEP = 5`; `control.light(cur, max, dir) -> level` (`dir` = 1 | −1); `control.COMMANDS[name] = function(dev) -> text|nil, note`; `control.run(name, dev) -> text|nil, note`.
  - `dev = { light = { get = fn() -> n, set = fn(n), max = n }, night = { get = fn() -> bool, toggle = fn() }, wifi = { get = fn() -> bool, set = fn(bool) }, refresh = fn() }` — любое поле может отсутствовать.
  - `Diary:controlSources() -> dev`; очередь: `{ kind = "control", sign = name, top = top, page = pg }`.

- [ ] **Step 1: тесты `glyph_spec` на `opts`**

```lua
function T.test_match_opts_dist_and_size()
  local key = { TR.equilateral }
  local ok, d = glyph.match(TR.wobbly, key)
  t.ok(ok)
  local ok2, d2, gate = glyph.match(TR.wobbly, key, { dist = d / 2 })
  t.eq(ok2, false); t.eq(gate, "dist"); t.eq(d2, d)
  local narrow = { { p = { 380, 650, 380, 300, 320, 380, 380, 300, 440, 380 } } } -- меньшая сторона 120
  t.eq(select(3, glyph.match(narrow, { narrow })), "size")
  t.eq(glyph.match(narrow, { narrow }, { size = 100 }), true)
end
```

- [ ] **Step 2: тесты `control_spec`** — чистая подсветка и `run` на поддельном `dev`:
  - `test_light_up_from_off_first_step`: `control.light(0, 25, 1) == 5`; `light(23, 25, 1) == 25`; `light(25, 25, 1) == 25`.
  - `test_light_down_to_off`: `light(10, 25, -1) == 5`; `light(3, 25, -1) == 0`; `light(0, 25, -1) == 0`.
  - `test_run_up_sets_and_reports`: `dev.light` с `get = 5`, `max = 25` → `run("up", dev)` == `"Подсветка 10 из 25"`, `set` вызван с 10; `note` содержит `"light 5->10"`.
  - `test_run_up_at_max_still_visible`: `get = 25` → `"Подсветка 25 из 25"`.
  - `test_run_down_off_text`: `get = 3` → `"Подсветка выключена"`, `set(0)`.
  - `test_run_source_error_visible`: `get` бросает → `run` == `texts.control_failed` (`"Не вышло."`), `note` начинается с `"error"`.
  - `test_run_missing_source`: `dev = {}` → `texts.control_failed`, `note == "no source"`.
- [ ] **Step 3: тесты `signs_spec`**:
  - `test_shapes_cover_list`: каждое имя `signs.LIST` есть в `sign_shapes` и в `control.COMMANDS`; лишних ключей ни там, ни там нет.
  - `test_detect_own_variants`: для каждого шаблона ↑/↓ — сдвиг, масштаб 0.7 и 1.3, поворот ±10°, обратный порядок и направление штрихов → `signs.detect` == имя.
  - `test_up_down_not_swapped`: каждый шаблон ↑ → не `"down"` и наоборот (M7).
  - `test_why_shares`: `select(3, signs.detect(up))` содержит `up` ≤ 1 и `down` > 1.
- [ ] **Step 4: тесты виджета в `status_page_spec.lua`** — в `diary()` стенда добавить `d.dev` (поддельный `light` с журналом `set`) и `d.controlSources = function() return d.dev end`:
  - `test_up_sign_brightens_any_seal`: закрытая печать без ключа, страница-↑ → `run(1)` → `d.dev.light.sets == {10}` (было 5), `revealed` == `"Подсветка 10 из 25"`, `not_probe(d) == 0`, `inflight == 0`; то же под открытой печатью.
  - `test_triangle_before_sign` (`TF.equilateral` → статус, `sets` пуст) и `test_key_before_sign` (ключевая печать `keyed_diary`, страница `O.owner_03` → печать открыта, `sets` пуст).
  - `test_sign_under_keyed_closed_seal_no_file`: devmode, `keyed_diary`, страница-↑ → команда выполнена, `#files(rose_dir) == 0`, `count("riddle: sign yes") == 1`.
  - `test_sign_over_answer_no_interjection`, `test_sign_during_inflight`, `test_sleep_drops_queued_control` — по Review Focus 1, 4, 5.
  - Старый `test_devmode_both_signs_one_file` (K19) ломается законно: страницу `TF.square` под открытой печатью теперь проверяют три знака. Переименовать в `test_devmode_all_signs_one_file`, добавить `count("riddle: sign no") == 1`, ожидание `count("file=" .. names[1])` — 3.
- [ ] **Step 5: прогнать новые тесты — падают** (`luajit` через `LUA_PATH` из `tests/run.sh`): нет `riddle.signs`, `riddle.control`, `opts` не читается.
- [ ] **Step 6: `glyph.match(strokes, drawings, opts)`** — `opts.size` в воротах `size` (`:188`), `opts.dist` в `:198`; комментарий над функцией — про параметр.
- [ ] **Step 7: `sign_shapes.lua`** — синтетические шаблоны (вершины ломаной, экранные px; заменятся рисунками владельца в Task 3):
  - `up` — `{380,700 → 380,300 → 300,400 → 380,300 → 460,400}` (1 штрих) и `{380,700 → 380,300}`, `{300,400 → 380,300 → 460,400}` (2 штриха);
  - `down` — то же, отражённое по вертикали около y = 500.
- [ ] **Step 8: `signs.lua`** — `detect` сверяет по каждому имени `glyph.match(strokes, sign_shapes[name], { dist = signs.DIST, size = signs.SIZE })` и берёт ближайший совпавший; заголовок модуля — зачем свой порог (M2–M4).
- [ ] **Step 9: `control.lua` и тексты** — `texts.control_light = "Подсветка %d из %d"`, `control_light_off = "Подсветка выключена"`, `control_failed = "Не вышло."`. `run` вызывает команду под `pcall`; источника нет — `control_failed`, `"no source"`.
- [ ] **Step 10: виджет.** После треугольника (`:1472`): `local sign = self:isSign(signs, "sign", pg.strokes, record)` → в очередь `{ kind = "control", sign = sign, top = top, page = pg }`, `self:nextAnswer()`, `return`. В `nextAnswer` после `table.remove` (`:1672`): `if q.kind == "control" then return self:runControl(q) end`. `runControl`: `control.run(q.sign, self:controlSources())`, строка `riddle: control <name> <note>` (всегда, без координат), текст есть → `revealAnswer(text, q.top, nil, "control", nil, q.page)`, нет → `nextAnswer()`. `controlSources`: `light` — только при `Device:hasFrontlight()`, `get` — `powerd:frontlightIntensity()`, `max` — `powerd.fl_max`, `set` — рецепт D2 дословно. `require` KOReader-модулей (`ui/event`, `ui/network/manager`) — внутри `controlSources`, не на верхнем уровне: 18 спеков виджета их не стабят.
- [ ] **Step 11: `sh tests/run.sh`** → `77 specs, OK` (два новых спека; из старых меняется только ожидание K19 — Step 4).
- [ ] **Step 12: коммит** `feat(signs): каркас знаков управления, подсветка ↑/↓`.

### Task 2: Полумесяц, квадрат, молния и матрица коллизий (≈300 строк)

**Files:**
- Modify: `riddle/sign_shapes.lua`, `riddle/signs.lua` (`LIST`), `riddle/control.lua` (`COMMANDS`), `riddle/texts.lua`, `riddle_diarywidget.lua` (`controlSources`: `night`, `wifi`, `refresh`)
- Create: `tools/sign_matrix.lua` (отчёт расстояний, не тест)
- Test: `tests/signs_spec.lua`, `tests/control_spec.lua`, `tests/status_page_spec.lua:499-509, 522`

**Interfaces:**
- Consumes: всё из Task 1.
- Produces: `signs.LIST = { "up", "down", "moon", "square", "bolt" }`; тексты `control_night_on = "Ночной режим включён"`, `control_night_off = "Ночной режим выключен"`, `control_wifi_on = "Wi‑Fi включён"`, `control_wifi_off = "Wi‑Fi выключен"`; `tools/sign_matrix.lua [fixture-module …]` печатает по каждому знаку: наибольшее «своё», наименьшее «чужое» с именем фикстуры, зазор.

- [ ] **Step 1: тесты `control_spec`**: `moon` при `get = false` → `toggle` вызван раз, текст по `get()` после него (`"Ночной режим включён"`), обратно — `"выключен"`; `bolt` при `get = true` → `set(false)`, `"Wi‑Fi выключен"`; при `false` → `set(true)`, `"Wi‑Fi включён"` (итог — цель, подключение асинхронно); `square` → `refresh` вызван, текст `nil`, `note == "refresh"`.
- [ ] **Step 2: матрица в `signs_spec`** (данные — по `signs.LIST`, новый знак попадает в неё сам):
  - `test_each_sign_own_variants` — как в Task 1, для всех пяти; поворот у квадрата — ±5° (M8);
  - `test_signs_never_match_each_other` — каждый шаблон A: `detect` == A; для каждой пары A ≠ B `glyph.match(шаблон A, sign_shapes[B], opts знаков)` ложно;
  - `test_one_stroke_arrows_not_bolt` (обязательный): варианты ↑/↓ в 1 штрих → не `"bolt"`; варианты молнии → не `"up"`/`"down"` (M2);
  - `test_cross_only_not_down` (обязательный): `signs.detect(R.cross_only) == false`, расстояние до `down` > `signs.DIST` (M3);
  - `test_triangles_not_signs`: все рисунки `fixtures.triangle_strokes`, кроме `square`, → `false`; `TF.square` → `"square"` (M5);
  - `test_roses_and_letters_not_signs`: все рисунки `fixtures.rose_strokes` (`ROSES`, `NON_ROSES`, буквы, слова) и `fixtures.rose_owner` → `false`.
- [ ] **Step 3: тесты виджета**: полумесяц, квадрат, молния на странице — `dev.night.toggle`/`dev.refresh`/`dev.wifi.set` вызваны по разу, тексты по Global Constraints, квадрат не печатает ничего и очередь идёт дальше (следующая страница со словами уходит в модель). Источник `wifi` настоящего `controlSources` — `test_wifi_source_via_net_and_networkmgr`: `ui/network/manager` подменён в `package.preload` (журнал вызовов), `net.state` подменён → `get()` == (`net.state() ~= "off"`); `set(true)` → `restoreWifiAsync`, `scheduleConnectivityCheck`; `set(false)` → `disableWifi(nil, true)`; `isWifiOn` знаком не вызывается напрямую. Два старых теста с `TF.square` на странице (K15) переписать на `TF.pentagon` — квадрат стал знаком; ожидания — как после Task 1 (`all_signs`: строки `triangle no`, `sign no`, `rose no`, `file=` — 3; закрытая печать — файла нет).
- [ ] **Step 4: прогнать — падают.**
- [ ] **Step 5: шаблоны** (1 штрих каждый): `square` — `{200,300 → 550,300 → 550,650 → 200,650 → 200,300}`; `bolt` — `{460,250 → 320,480 → 440,480 → 300,750}`; `moon` — внешняя дуга центр (380,500), r 200, от −110° до 110° с шагом 10°, затем внутренняя центр (300,500), r 150, от 70° до −70°.
- [ ] **Step 6: команды и источники.** `night`: `get` — `G_reader_settings:isTrue("night_mode")`, `toggle` — `UIManager:broadcastEvent(Event:new("ToggleNightMode"))` (D4: перерисовка full — его). `wifi`: только при `Device:hasWifiToggle()`; `get` — `net.state() ~= "off"` (K18: методы NetworkMgr знает только `net`, новый канал попадёт в знак сам); `set(true)` — `NetworkMgr:restoreWifiAsync()` и `NetworkMgr:scheduleConnectivityCheck()` (D9: пара KOReader, `NetworkConnected` → прогрев DNS; не `turnOnWifi` — D6, окно «Scanning…»); `set(false)` — `NetworkMgr:disableWifi(nil, true)` (D10). `refresh` — `self:push(0, 0, self.w, self.h, "full")`.
- [ ] **Step 7: `tools/sign_matrix.lua`** — запуск `LUA_PATH="plugin/riddlediary.koplugin/?.lua;tests/?.lua;;" luajit tools/sign_matrix.lua fixtures.rose_strokes fixtures.triangle_strokes fixtures.rose_owner`; печатает таблицу; на синтетике зазор каждого знака > 0.
- [ ] **Step 8: `sh tests/run.sh`** → OK.
- [ ] **Step 9: коммит** `feat(signs): ночной режим, полное обновление, Wi‑Fi; матрица коллизий`.

### Task 3: Калибровка по руке владельца (≈250 строк кода и тестов + данные)

**Files:**
- Create: `tests/fixtures/signs_owner.lua` (живые рисунки, не вошедшие в шаблоны)
- Modify: `riddle/sign_shapes.lua` (шаблоны — рисунки владельца), `riddle/signs.lua` (`DIST`, `SIZE` с комментарием-обоснованием)
- Test: `tests/signs_spec.lua`

**Interfaces:**
- Consumes: `signs.detect`, матрица Task 2, `tools/sign_matrix.lua`.
- Produces: `signs_owner` — `F.<sign>_NN` (`up_01`…), `F.foreign_<буква>` и списки `F.SIGNS = { up = {…имена}, … }`, `F.FOREIGN = {…}`.

- [ ] **Step 1: запись (владелец; оркестратор ставит `tools/deploy.sh --dev` на сборку без молнии — до деплоя Task 2 или на текущей: молния на сборке Task 2 выключит Wi‑Fi посреди записи).** Под **открытой** печатью (K2: `record = nil`, пишется каждая страница до 5 штрихов — триангл и роза уже пишут файл, K3/K4). Каждый рисунок — своя страница, ждать, пока чернила растворятся (`idle_s` 2.5 с). Размер — как знак, не как буква. Порядок:
  1. ↑ — 12 раз, ↓ — 12, полумесяц — 12, квадрат — 12, молния — 12; штрихов — как ведёт рука (если стрелка выходит то в 1, то в 2 штриха — так и оставить); полумесяц — всегда в одну сторону.
  2. чужие, крупно, по разу: Л, V, Z, N, С, О, П, Т, Г, 1, 7, 4.

  Итого 72 страницы, ~10 мин. Записать время начала. Сбилась — назвать номер страницы.

  **Побочный эффект — сказать владельцу до записи:** под открытой печатью страница, не узнанная знаком, уходит модели и в память персонажа (K1: после розы — модель). На текущей сборке это все 72 страницы, включая 12 «чужих» букв, — как при калибровке роз. Нет согласия владельца — запись не начинать.
- [ ] **Step 2: забрать файлы** (только чтение): `ssh kindle 'ls /mnt/us/riddle/roses'`, `scp` только имён с меткой времени не раньше начала записи (D8: старые не трогать). Сверить число (72) и каждый глазом по отрисовке, как `rose_owner.lua:2`.
- [ ] **Step 3: шаблоны.** По каждому знаку и каждому числу штрихов (≥ 4 рисунка, иначе — вопрос владельцу): медоид (наименьшая сумма расстояний до своих) + два «дальних» (каждый следующий — дальше всех от уже взятых) → в `sign_shapes`; остальные → `signs_owner.F.SIGNS`. Синтетические шаблоны уходят.
- [ ] **Step 4: пороги по `tools/sign_matrix.lua`** на `signs_owner` + фикстурах Task 2. `signs.DIST` = середина между наибольшим «своим» и наименьшим «чужим», округление до 0.05; зазор < 0.4 хоть у одного знака — **стоп**, таблицу оркестратору (решение о новом параметре ворот `glyph` — не здесь). `signs.SIZE` = ⌊0.7 × наименьшая меньшая сторона среди своих⌋, не ниже 60.
- [ ] **Step 5: тесты**: `test_owner_signs_detected` (каждый рисунок `F.SIGNS[name]` → `name`), `test_owner_signs_never_other` (никогда не другой знак), `test_owner_foreign_not_signs` (все `F.FOREIGN` → `false`), `test_gap` (наибольшее своё < `signs.DIST` < наименьшее чужое по всем фикстурам). Обязательные пары Task 2 и `test_triangles_not_signs` — на новых шаблонах.
- [ ] **Step 6: `sh tests/run.sh`** → OK. Коммит `feat(signs): шаблоны и порог знаков по руке владельца`.

### Task 4: Знаки заняты для ключа печати (≈120 строк)

**Files:**
- Modify: `riddle/glyph.lua:202-210` (`fits`: `"taken"` и для знака)
- Test: `tests/glyph_spec.lua:351-363`, `tests/seal_key_spec.lua:23-24`, `tests/status_page_spec.lua:783-784`, `tests/controller_spec.lua:499`

**Interfaces:**
- Consumes: `signs.detect`.
- Produces: `glyph.fits(strokes) -> false, "taken"` для знака управления.

- [ ] **Step 1: тесты**: `test_fits_rejects_control_signs` (каждый шаблон `sign_shapes` → `false, "taken"`); в `status_page_spec` — `test_up_in_setting_is_taken` по образцу `test_triangle_in_setting_is_taken` (`:828-835`): ↑ в режиме задания → `texts.key_taken`, `dev.light.sets` пуст.
- [ ] **Step 2: образец ключа в тестах — не квадрат** (K14): `SQUARE`/`TR.square` → `TR.pentagon`, `SQUARE_AGAIN` → тот же пятиугольник сдвигом и дрожью руки; тест-страж `glyph.match(AGAIN, { KEY }) == true` и `glyph.fits(KEY) == true` рядом с определением. Граничный тест размера (`glyph_spec:351-357`) — пятиугольник со стороной рамки `SIZE`.
- [ ] **Step 3: прогнать — падают** (`fits` пропускает знаки).
- [ ] **Step 4: `glyph.fits`** — `require("riddle.signs")` внутри функции (цикл: `signs` требует `glyph`), комментарий об этом.
- [ ] **Step 5: `sh tests/run.sh`** → OK. Коммит `feat(seal): знаки управления заняты для ключа`.

### Task 5: Живой прогон (без кода; дефекты — багфиксом сразу)

Деплой — оркестратор (`tools/deploy.sh --dev`). Лог — `tools/kindle_log.sh`, строки `riddle: sign yes|no`, `riddle: control <name> <note>`.

- [ ] ↑ трижды от выключенной → «Подсветка 5/10/15 из 25», свет виден (D11 и ASSUMPTION 1 вживую: событие `SetFlIntensity` услышано; не услышано — итог честно «5 из 25» без шага); ↓ четырежды → 10, 5, «выключена», 0.
- [ ] Полумесяц → экран инвертирован, чернила пера видны и растворяются, итог читается; ещё раз → обратно; закрыть и открыть дневник — режим сохранён (ASSUMPTION 1).
- [ ] Квадрат → полное обновление, текста нет, следующая страница — обычный разговор.
- [ ] Молния → «Wi‑Fi выключен» (ssh рвётся — ожидаемо); молния → «Wi‑Fi включён», ни одного окна KOReader; через ≤ 60 с треугольник показывает «Wi‑Fi: на связи», в логе — `riddle: dns warm (network connected): N hosts cached` (`main.lua:373`; ASSUMPTION 2); сон и пробуждение после молнии-«выкл» Wi‑Fi не возвращают (D10); молния-«вкл» вдали от сети → через ~45 с Wi‑Fi выключен сам, в логе `Failed to restore Wi-Fi (after … seconds)!` (D9).
- [ ] Закрытая печать с ключом: ↑ работает, число файлов в `roses` до и после одно (K2).
- [ ] 10 страниц обычного письма (строки слов, подпись, рисунок) — ни одной `riddle: control` (анти-цель).
- [ ] Итог — оркестратору: что сошлось, строки лога, снятые ASSUMPTION.

## Вопросы владельцу

Шаг подсветки 5 — решено оркестратором (2026-11-28).

1. Твой ключ печати похож на ↑, ↓, полумесяц, квадрат или молнию? Если да — этот знак не сработает, пока ключ не сменишь.
2. Когда удобно 10 минут на запись 72 рисунков (Task 3, шаг 1)? Все 72 страницы уйдут модели и в память персонажа, как было с розами, — согласен?
