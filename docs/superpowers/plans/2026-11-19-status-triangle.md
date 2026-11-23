# Состояние Kindle по треугольнику — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** треугольник пером на странице дневника открывает печатную страницу состояния Kindle (батарея, Wi‑Fi/ssh, память, uptime, сборка, синхронизация, модель); касание закрывает её.

**Architecture:** распознаватель `riddle/triangle.lua` — чистая функция на общих с розой геометрических хелперах (`riddle/pen.lua`, выносятся из `rose.lua`). Сбор и вёрстка фактов — чистый `riddle/status.lua` с внедрёнными читателями (файлы, lipc, KOReader). Виджет открывает страницу как режим (по образцу карты: очередь → open → касание → close), проверку модели гонит отдельной задачей раннера и дописывает строку по приходу.

**Tech Stack:** Lua (LuaJIT), KOReader-плагин, тесты `tests/run.sh` (luajit на Mac).

**Spec:** `docs/superpowers/specs/2026-11-19-status-triangle-design.md` (e809f25).

## Global Constraints

- Страница открывается без сети и не ждёт её; «модель отвечает» дописывается позже (спека:31–33, :17).
- Ложное срабатывание хуже пропуска; роза не путается с треугольником (спека:17–18).
- Знак проверяется там же, где роза; в devmode — тот же лог критериев и запись штрихов (спека:37–38).
- Касание закрывает страницу, дневник на прежнем месте (спека:12–13).
- Не цель: разблокировка знаком (задача 811d), управление устройством, история (спека:14–15).
- Не трогать: `tools/kindle_inventory.sh`, задачу 811d, файлы на Kindle (бриф).
- Срез 100–400 строк диффа, тест до кода.

## Факты (заземление)

### Код

| # | Факт | Улика |
|---|------|-------|
| K1 | Роза проверяется в `onPageDone` только при открытой печати: `if ctl and ctl.seal_open and self:isRose(pg.strokes)` → `queueMap(pg, "rose")` | `riddle_diarywidget.lua:1223-1226` |
| K2 | `isRose`: `rose.detect`; без devmode — только `ok`; в devmode пишет файл штрихов, если `#strokes <= rose.MAX_STROKES`, и строку `riddle: rose yes|no score=… <crit>=… n=… file=…` | `riddle_diarywidget.lua:1631-1642` |
| K3 | `recordRose` пишет `<rose_dir or RIDDLE_DIR/roses>/<%Y%m%d-%H%M%S>-<n>.lua` в формате фикстур | `riddle_diarywidget.lua:1644-1656` |
| K4 | Тест записи розы держит `d.rose_dir`, `d:isRose`, «по файлу на страницу», без devmode — 0 файлов | `tests/rose_record_spec.lua:50-110` |
| K5 | Общие хелперы розы — локальные: `pts`, `dist`, `reversed`, `resample`, `percentile`, `fitCenter`; поворот хорд — цикл внутри `shape`; изогнутость — `bar` | `riddle/rose.lua:31-72, 141-152, 204-221` |
| K6 | `test_every_constant_is_read` требует ≥2 вхождений `rose.<CONST>` в `rose.lua` и ≥16 констант | `tests/rose_spec.lua:96-110` |
| K7 | Фикстуры: `F.ROSES`, `F.NON_ROSES` (буквы, слова, `x_in_square`, спираль, смайлик…) и 12 живых роз владельца | `tests/fixtures/rose_strokes.lua:347-349`, `tests/fixtures/rose_owner.lua` |
| K8 | Карта как режим: `queueMap` (за ответом в полёте — `map_due`, иначе в очередь), `nextAnswer` при `q.kind == "map"` → `openMap`; `openMap` → `resetPage`; `closeMap(why)` → чистая страница + приглашение + full refresh; сон/выход — `closeMap("sleep"|"exit")` | `riddle_diarywidget.lua:1660-1667, 1425-1428, 1722-1739, 1768-1787, 668, 698` |
| K9 | `penDown` в режиме карты уходит в карту, чернил нет | `riddle_diarywidget.lua:1013-1018` |
| K10 | Раннер: один дочерний; `start` при занятом — `nil,"busy"`, только `"answer"` вытесняет не-answer; `busy()` → kind | `riddle/worker.lua:72-74, 122-130` |
| K11 | Запрос модели в дочернем: `deps.remote_fn(messages, want_json, opts)`; `opts.max_tokens` принимается (sync шлёт `max_tokens = 1500`), но только поднимает потолок провайдера, не опускает: `llm.build` берёт `math.max(provider.max_tokens or DEFAULT, max_tokens)` — проба с `max_tokens = 1` уходит с потолком провайдера (200) | `riddle/controller.lua:1086`, `riddle/app.lua:362`, `main.lua:189`, `riddle/llm.lua:151` |
| K12 | Сеть без обращений: `net.state()` → `"up"|"down"|"off"` по NetworkMgr `isWifiOn`/`isConnected` | `riddle/net.lua:7-28` |
| K13 | Деплой копирует `$PLUG/*` и не пишет ни sha, ни версии; `_meta.lua` версии не содержит | `tools/deploy.sh:20-28`, `_meta.lua:1-6` |
| K14 | Деплой тестируется на поддельных ssh/scp, лог команд — в `FAKE_DIR/log` | `tests/deploy_spec.lua:1-25` |
| K15 | Время последней **успешной** синхронизации уже хранится: `K:set_meta("last_ok", d.wall())` в конце `pass`; читает родитель (`maybeSync`) | `riddle/sync.lua:301`, `main.lua:236-248` |
| K16 | Итог синхронизации (ошибка, падение, таймаут дочернего) нигде не хранится — только строки лога: в дочернем `sync.lua:340`, в родителе `on_done` `main.lua:197-208` (сюда приходит и `rerr` смерти/таймаута) | `riddle/sync.lua:338-347`, `main.lua:197-201` |
| K17 | `rssKB()` читает `/proc/self/status` VmRSS — образец чтения `/proc` в виджете | `riddle_diarywidget.lua:154-160` |
| K18 | `resetPage` обнуляет очередь и `inflight` | `riddle_diarywidget.lua:743-759` |

### Kindle (живая сверка, только чтение)

Снято 2026-11-19 по `ssh kindle`, только чтение. KOReader на устройстве — `v2025.08` (`/mnt/us/koreader/git-rev`).

| # | Вопрос | Команда | Вывод → решение |
|---|--------|---------|-----------------|
| L1 | Батарея/зарядка | `grep … device/kindle/powerd.lua`, `device/generic/powerd.lua`; `lipc-get-prop com.lab126.powerd battLevel` / `isCharging` | `kindle/powerd.lua:174-176` `getCapacityHW` → lipc `battLevel`; `:191-194` `isChargingHW` → lipc `isCharging`; `generic/powerd.lua:252-271` `getCapacity` кэширует HW на 60 с, `isCharging` → HW; `generic/device.lua:340` `Device:getPowerDevice()`. Живое: `battLevel=88`, `isCharging=0`. → источник `Device:getPowerDevice():getCapacity()` / `:isCharging()` |
| L2 | ssh слушает 2222 | `awk '$4=="0A"{print $2}' /proc/net/tcp /proc/net/tcp6` | `tcp 00000000:08AE` (2222, LISTEN на всех адресах), ещё `:0016` и `0100007F:D903`; `/proc/net/tcp6: No such file or directory`. → только `/proc/net/tcp`; отсутствующий tcp6 — не ошибка |
| L3 | Wi‑Fi: вкл/сеть/IP | `lipc-get-prop com.lab126.wifid cmState`, `currentEssid`; `ifconfig wlan0`; `ip -4 -o addr show wlan0`; `grep getCurrentNetwork device/kindle/device.lua` | `cmState=CONNECTED`; `currentEssid` через CLI — `lipcErrNoSuchProperty` (это hasharray); KOReader читает его так: `kindle/device.lua:66-80` `kindleGetCurrentProfile` (libopenlipclua hasharray) → `:461-462` `NetworkMgr:getCurrentNetwork() → { ssid }` (объявлен внутри ветки — может отсутствовать). `ip -4 -o addr show wlan0` → `9: wlan0 inet 192.0.2.220/24 …`. → вкл/связь — `net.state()` (K12); сеть — `pcall(NetworkMgr.getCurrentNetwork)`; IP — разбор вывода `/sbin/ip -4 -o addr show wlan0` |
| L4 | Свободная RAM | `head -6 /proc/meminfo; grep -c MemAvailable /proc/meminfo; uname -r` | `MemTotal 254828`, `MemFree 25380`, `Buffers 40272`, `Cached 100212` kB; `MemAvailable` — 0 строк; ядро `3.0.35-lab126`. → свободная = `MemFree + Buffers + Cached` (165864 kB) |
| L5 | Место на `/mnt/us` | `sed -n 920,946p frontend/util.lua`; `df -kP /mnt/us` | `util.diskUsage(dir)` (`util.lua:920-946`) — `df -kP` через popen → `{ total, used, available }` в **байтах**; `fsp 1392632 589816 802816 42% /mnt/us`. → источник `util.diskUsage("/mnt/us").available` |
| L6 | uptime | `cat /proc/uptime` | `2208707.90 285648.98` → первое число, секунды (25.6 сут) |

## Решение оркестратора

- **Треугольник срабатывает в любом состоянии печати** (оркестратор 2026-11-19). Основание — слова владельца в спеке: «во всех случаях» (спека:6); страница не показывает содержимого дневника. Роза остаётся только при открытой печати (K1).

## Файлы

- Create `plugin/riddlediary.koplugin/riddle/pen.lua` — геометрия штриха, общая для знаков.
- Modify `plugin/riddlediary.koplugin/riddle/rose.lua` — хелперы из `pen`, поведение то же.
- Create `plugin/riddlediary.koplugin/riddle/triangle.lua` — распознаватель.
- Create `tests/fixtures/triangle_strokes.lua`, `tests/pen_spec.lua`, `tests/triangle_spec.lua`.
- Create `plugin/riddlediary.koplugin/riddle/status.lua`, `tests/status_spec.lua` — факты и вёрстка.
- Modify `tools/deploy.sh`, `tests/deploy_spec.lua` — файл версии.
- Modify `plugin/riddlediary.koplugin/main.lua` (`on_done` синхронизации) + `tests/sync_trigger_spec.lua` или новый — итог синхронизации.
- Modify `plugin/riddlediary.koplugin/riddle_diarywidget.lua` — знак, режим «состояние», проверка модели; `tests/rose_record_spec.lua`, новый `tests/status_page_spec.lua`.
- Modify `plugin/riddlediary.koplugin/riddle/controller.lua` — `probe_job`.

## Срезы

| # | Срез | ~строк | widget |
|---|------|--------|--------|
| 1 | `pen.lua` из `rose.lua` (рефакторинг) | 150 | нет |
| 2 | `triangle.detect` + фикстуры | 350 | нет |
| 3 | `status.lua`: факты и вёрстка | 300 | нет |
| 4 | Версия при деплое + итог синхронизации | 150 | нет |
| 5 | Знак → страница состояния → касание | 350 | **да** |
| 6 | «Модель отвечает» в фоне | 200 | **да** |

1–4 независимы (разные файлы) и могут идти параллельно, кроме 2 после 1. 5 после 2, 3, 4. 6 после 5 (тот же `riddle_diarywidget.lua` — последовательно).

## Review Focus

1. Буквы с треугольной формой — «А», «Д», «4», «△» мелко в слове, галочка «V» — не треугольник (тест в задаче 2).
2. Треугольник, нарисованный начиная с середины стороны (стык не в углу), — треугольник (задача 2).
3. Треугольник при ответе в полёте — страница открывается после ответа, ответ не теряется (задача 5, как `map_due`).
4. Сон/выход при открытой странице состояния — режим снят, ничего не рисуется (задача 5).
5. Раннер занят синхронизацией — строка «модель: не проверена (занято: sync)», страница не ждёт (задача 6).

---

### Task 1: общая геометрия штриха `riddle/pen.lua`

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/pen.lua`
- Modify: `plugin/riddlediary.koplugin/riddle/rose.lua:31-72, 141-152, 204-221`
- Test: `tests/pen_spec.lua`, `tests/rose_spec.lua` (без правок — закрепляет поведение)

**Interfaces:**
- Produces:
  - `pen.points(stroke) -> {{x,y},…}` (бывш. `pts`)
  - `pen.dist(a, b) -> number`
  - `pen.reversed(list) -> list`
  - `pen.resample(list, n) -> list | nil` (nil — нулевая длина)
  - `pen.percentile(sorted, q) -> number`
  - `pen.turn(s, i, k) -> радианы 0..π` — поворот между хордами `s[i-k]→s[i]` и `s[i]→s[i+k]`; индексы вне `1..#s` — вызывающий не передаёт (цикличность — у вызывающего)
  - `pen.bend(list, samples, trim) -> { a, b, len }, dev_ratio | nil` — хорда концов и максимальное отклонение средних точек от их хорды долей её длины (без деления на порог)

- [ ] **Step 1: тест `tests/pen_spec.lua`**: `resample` даёт ровно n точек и сохраняет концы; `resample` нулевой длины → nil; `turn` на прямом угле = π/2 ± 1e-6, на прямой = 0; `bend` прямой черты → dev_ratio < 1e-6, дуги в 90° → > 0.1; `points({p={1,2,3,4}})` → `{{1,2},{3,4}}`.
- [ ] **Step 2:** `tests/run.sh` → `pen_spec` FAIL (`module 'riddle.pen' not found`).
- [ ] **Step 3:** `pen.lua` — тела переносятся из `rose.lua` без изменений; `rose.lua` берёт их из `pen` (`bar` = `pen.bend(list, rose.BAR_SAMPLES, rose.BAR_TRIM)` + деление на `rose.BEND`; цикл углов в `shape` — через `pen.turn`). Константы `rose.*` остаются в `rose.lua` (K6).
- [ ] **Step 4:** `tests/run.sh` → все specs OK, `rose_spec` и `rose_record_spec` без правок зелёные.
- [ ] **Step 5:** коммит `refactor(pen): геометрия штриха — общая для знаков, rose берёт из pen`.

### Task 2: распознаватель треугольника

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/triangle.lua`, `tests/fixtures/triangle_strokes.lua`, `tests/triangle_spec.lua`

**Interfaces:**
- Consumes: `pen.*` (задача 1).
- Produces: `triangle.detect(strokes) -> ok:boolean, score:number, why:table|nil` — контракт как у `rose.detect` (score ≤ 1 — годен; why — доли порогов); `triangle.CRITERIA` (порядок лога); `triangle.MAX_STROKES`.

Алгоритм (форма штриха не задаётся тестом однозначно):
1. Штрихов > `MAX_STROKES` (=2: линия может прерваться один раз) → `false, MISS`. Два штриха склеиваются всеми 4 способами (как `circles` в розе), берётся лучший; прыжок пера между ними — в критерий `gap` со своим порогом `JUMP` (0.05 периметра): без него «А», крест и крупная «4» склеивались в треугольник.
2. `resample` до `SAMPLES` (96). Стык: ближайшая пара точек из начальной и конечной доли `ENDS` (0.25) длины; линия между ними — контур (перетянутый конец и росчерк отрезаются). Зазор / периметр → `gap` ≤ `GAP` (0.15). Отрезанная доля длины → `trim` ≤ `TRIM` (0.13; ревью среза 2: иначе закрытая «4» после срезки хвостов — треугольник). Склейка и длина — `pen.joins`, `pen.length` (общие с розой).
3. Контур замыкается и передискретизуется; поворот в каждой точке **циклически** (стык может прийтись на середину стороны): `pen.turn` по хордам `k = SAMPLES / CORNER_STEPS`. Углы — локальные максимумы поворота ≥ `CORNER_MIN` (50°) в окне ±k. Критерий `corners`: при 3 углах — `CORNER_MIN / слабейший`, иначе `1 + |n−3|`.
4. Стороны между углами: `pen.bend(side, SIDE_SAMPLES, SIDE_TRIM)` → `bend` ≤ `BEND` (0.15); короткая сторона → `side` (доля периметра ≥ `SIDE` 0.15).
5. Размер: меньшая сторона описанного прямоугольника ≥ `SIZE` (150 px, как `rose.SIZE`) → `size`.

Критерия «обход 360°» нет: у замкнутой ломаной с тремя углами и прямыми сторонами он всегда 360°, петли дают лишние углы.

Пороги — с запасом; живая подстройка — по devmode-файлам (задача 5), как роза (`rose.lua:3-4`).

- [ ] **Step 1: фикстуры** `tests/fixtures/triangle_strokes.lua` в формате `rose_strokes.lua` (детерминированное дрожание): `F.TRIANGLES` = равносторонний, тупоугольный, прямоугольный против часовой, повёрнутый на 37°, начат с середины стороны, со скруглёнными углами, недотянут на 8%, перетянут на 10% стороны, двумя штрихами, дрожащий, с росчерком после замыкания. `F.NON_TRIANGLES` = квадрат, пятиугольник, трапеция, «V», «Λ», «А», «Д», крупная «4», △ 60 px, круг, восьмёрка, выгнутая сторона, игла, лучина (основание 110 px), зигзаг. Порог держит свой пример (мутация ослабления валит тест): GAP — недотянут на полстороны, JUMP — «∠» двумя штрихами, TRIM — три закрытые «4», BEND — выгнутая сторона, SIDE — лучина, SIZE 75 — △120 px, CORNER_MIN 35 — излом стороны (позитив), MAX_STROKES 3 — треугольник двумя штрихами + третий штрих.
- [ ] **Step 2: тесты** `tests/triangle_spec.lua`:
  - `test_detect_triangles`: все `F.TRIANGLES` → `ok == true`.
  - `test_not_triangles`: все `F.NON_TRIANGLES` → `false`.
  - `test_roses_and_letters_not_triangles`: все `F.ROSES`, `F.NON_ROSES` (`rose_strokes.lua`) и `F.owner_01..12` (`rose_owner.lua`) → `false`.
  - `test_triangles_not_roses`: `rose.detect` на всех `F.TRIANGLES` → `false`.
  - `test_order_and_direction_irrelevant`: штрих задом наперёд, перестановка двух штрихов — тот же `ok`.
  - `test_parts`: `why` содержит каждый ключ из `triangle.CRITERIA`, `score == max(why)`.
  - `test_every_constant_is_read`: как `rose_spec.lua:96-110` для `triangle.*`.
  - `test_degenerate`: `{}`, `nil`, штрих из одной точки, все точки на прямой → `false`, число.
  - `test_many_strokes`: 3+ штриха → `false` без перебора.
- [ ] **Step 3:** `tests/run.sh` → `triangle_spec` FAIL (нет модуля).
- [ ] **Step 4:** `triangle.lua` по алгоритму выше.
- [ ] **Step 5:** `tests/run.sh` → все OK.
- [ ] **Step 6:** коммит `feat(triangle): распознаватель треугольника — чистая функция на pen, не путается с розой и буквами`.

### Task 3: факты и вёрстка `riddle/status.lua`

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/status.lua`, `tests/status_spec.lua`

**Interfaces:**
- Produces:
  - `status.collect(d) -> facts` — `d` внедряет источники: `d.read(path) -> string|nil`, `d.build() -> string|nil` (текст файла сборки), `d.power() -> { pct, charging } | nil`, `d.net() -> "up"|"down"|"off"`, `d.wifi() -> { essid, ip } | nil`, `d.disk(path) -> { free_kb, total_kb } | nil`, `d.sync_last() -> { at, err } | nil`, `d.sync_ok() -> number | nil`, `d.now() -> number`. Источник упал или nil — поле `nil`, сбор не падает (каждый — `pcall`).
  - `facts` = `{ battery = {pct, charging}, net, essid, ip, ssh = true|false|nil, mem_free_kb, disk_free_kb, uptime_s, build, sync = { ok_at, last_at, err } }`
  - `status.ssh_listening(proc_tcp_text, port) -> boolean` — строка с `local_address` `…:%04X` и `st == "0A"`.
  - `status.mem_free_kb(meminfo_text) -> number|nil` — `MemFree + Buffers + Cached` (L4: `MemAvailable` на ядре 3.0.35 нет); любой из трёх не найден — nil.
  - `status.uptime_s(proc_uptime_text) -> number|nil` — первое число (L6).
  - `status.ip(ip_addr_text) -> string|nil` — адрес из `inet A.B.C.D/…` (L3).
  - `status.lines(facts, now) -> { head = {строка, строка?}, rows = {…} }` — `head`: «Всё в порядке» или перечень сломанного (батарея < 15% без зарядки, Wi‑Fi не `up`, ssh не слушает, место < 50 МБ, синхронизация с ошибкой или старше `sync.STALE_S`·24); `rows` — подробности по одной на пункт спеки:34–36; неизвестное — «—».
  - `status.MODEL_ROW` — индекс строки «модель», которую дописывает задача 6.
- Источники на устройстве (подключает задача 5, в `status.collect` они внедрены): батарея — `Device:getPowerDevice():getCapacity()` / `:isCharging()` (L1); ssh — `/proc/net/tcp`, порт 2222; `tcp6` нет (L2); Wi‑Fi — `net.state()` (K12), сеть — `pcall` на `NetworkMgr:getCurrentNetwork().ssid`, IP — `/sbin/ip -4 -o addr show wlan0` (L3); RAM — `/proc/meminfo` (L4); диск — `util.diskUsage("/mnt/us").available` в байтах (L5); uptime — `/proc/uptime` (L6); сборка — `d.build()` читает `PLUGIN_DIR .. "/" .. status.BUILD_NAME` (`PLUGIN_DIR` — riddle_diarywidget.lua:74; имя — одна константа `status.BUILD_NAME`, её же проверяет deploy_spec); синхронизация — `last_ok` (K15) + `sync.parse_last(read(sync.LAST_PATH))` (задача 4: путь, формат и разбор — в riddle/sync.lua; запись — `riddle/file.write_atomic`). Popen (`ip`, `df` в `diskUsage`) — короткие локальные команды, сеть не трогают.

- [ ] **Step 1: тесты** `tests/status_spec.lua`: `ssh_listening` на образце `/proc/net/tcp` из L2 (шапка + строки `0100007F:D903`, `00000000:08AE`, `00000000:0016` с `st 0A` литералом) → true для 2222, false для 2223 и для той же строки с `st 01`; `mem_free_kb` на образце L4 → 165864; без строки `Cached` → nil; `uptime_s("2208707.90 285648.98")` → 2208707.90; `ip("9: wlan0    inet 192.0.2.220/24 brd …")` → `"192.0.2.220"`, пустая строка → nil; `collect` со всеми источниками, кидающими ошибку → таблица без падения, `lines` даёт «—»; `lines` здоровых фактов → `head[1] == "Всё в порядке"`; Wi‑Fi `off` → в `head` «Wi‑Fi выключен»; синхронизация с `err="http 401"` → в `head` ошибка.
- [ ] **Step 2:** FAIL (нет модуля). **Step 3:** код. **Step 4:** `tests/run.sh` OK.
- [ ] **Step 5:** коммит `feat(status): факты состояния Kindle и вёрстка страницы — чистые функции`.

### Task 4: версия сборки и итог синхронизации на устройстве

**Files:**
- Modify: `tools/deploy.sh:26` (после `scp`), `tests/deploy_spec.lua`
- Modify: `plugin/riddlediary.koplugin/main.lua:197-208`
- Test: `tests/deploy_spec.lua`, `tests/sync_trigger_spec.lua` (или новый `tests/sync_last_spec.lua`, если там нет стенда `on_done`)

**Interfaces:**
- Produces: файл `/mnt/us/koreader/plugins/riddlediary.koplugin/version` — одна строка `git describe --always --dirty` (единственный писатель — `deploy.sh`); файл `/mnt/us/riddle/sync_last` — `<os.time()> ok` или `<os.time()> <err>` одной строкой (единственный писатель — `on_done` синхронизации в `main.lua`; запись через временный файл и `os.rename`). Читатели — `status.collect` (задача 3).

- [ ] **Step 1: тесты.** `deploy_spec`: в логе поддельного ssh/scp есть запись `version` в `$DEST` со строкой, совпадающей с `git describe --always --dirty` клона. Синхронизация: `on_done` с `{updated=3}` → файл `<t> ok`; с `nil, "timeout"` → `<t> timeout`; повторный вызов перезаписывает (идемпотентно).
- [ ] **Step 2:** FAIL. **Step 3:** код. **Step 4:** `tests/run.sh` OK.
- [ ] **Step 5:** коммит `feat(deploy,sync): версия сборки и итог последней синхронизации — файлами на устройстве`.

### Task 5: треугольник открывает страницу состояния, касание закрывает

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua:1220-1226` (onPageDone), `:1425-1428` (nextAnswer), `:1013-1018` (penDown), `:668, :698` (выход, сон), `:1628-1667` (isRose/recordRose/queueMap)
- Test: `tests/rose_record_spec.lua` (держит поведение розы), новый `tests/status_page_spec.lua`

**Interfaces:**
- Consumes: `triangle.detect` (2), `status.collect`, `status.lines` (3), файлы (4).
- Produces:
  - `Diary:isSign(mod, name, strokes) -> boolean` — одно место для розы и треугольника: `mod.detect`; devmode — строка `riddle: <name> yes|no score=… <crit>=… n=… file=…` (формат K2 без изменений для `name="rose"`), файл штрихов при `#strokes <= mod.MAX_STROKES` через `recordStrokes`. `isRose(strokes)` = `isSign(rose, "rose", strokes)` (тест K4 зелёный без правок).
  - `Diary:recordStrokes(strokes) -> name|nil` — бывш. `recordRose`, тот же каталог `rose_dir` (все живые попытки знаков в одном месте; страница пишется **один раз**, даже если её проверили оба знака).
  - `Diary:queueMode(kind, pg, why)` — бывш. `queueMap` с параметром `kind` (`"map"|"status"`); `map_due` → `mode_due = { kind, page, why }`. `cancelMap` снимает любой ожидающий режим.
  - `Diary:openStatus()` / `Diary:closeStatus(why)` — `self.status = { facts, rects }`; open: `resetPage`, `paintTexts` строк `status.lines`, full refresh; close: как `closeMap` (K8) — чистая страница + приглашение + full refresh; `"sleep"|"exit"` — ничего не рисует.
- Порядок в `onPageDone`: треугольник проверяется первым, без условия печати («Решение оркестратора»), затем роза.

- [ ] **Step 1: тесты** `tests/status_page_spec.lua` (стенд виджета как `rose_record_spec.lua:1-60`): треугольник из `F.TRIANGLES` → `onPageDone` → `nextAnswer` → `self.status ~= nil`, на холст выведена строка `head[1]`, запроса модели «answer» нет; `penDown` при открытой странице → `self.status == nil`, чернил нет (`#self.strokes == 0`), `closeStatus` вызван с `"touch"`; `onSuspend` при открытой → `self.status == nil`, `push` не вызван; **треугольник при закрытой печати (`ctl.seal_open == false`) открывает страницу**, страница не уходит контроллеру как попытка слова; треугольник при `inflight > 0` → страница открывается только после ответа (`mode_due`); роза под открытой печатью → карта, как раньше; источники фактов, кидающие ошибку, → страница всё равно открывается; devmode: страница с треугольником — одна строка `riddle: triangle yes …` и **один** файл штрихов.
- [ ] **Step 2:** FAIL. **Step 3:** код. **Step 4:** `tests/run.sh` OK (вкл. `rose_record_spec`, `devtest_rose_spec` без правок).
- [ ] **Step 5:** живая проверка (тестер): деплой `--dev`, треугольник → страница; касание → дневник; лог `riddle: triangle yes score=…`; Wi‑Fi выключен — страница открывается и показывает «Wi‑Fi выключен».
- [ ] **Step 6:** коммит `feat(diary): треугольник открывает страницу состояния, касание закрывает`.

### Task 6: «модель отвечает» в фоне

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle/controller.lua` (рядом с `map_read_job`, `:1075-1086`), `plugin/riddlediary.koplugin/riddle_diarywidget.lua` (`openStatus`, `closeStatus`, CFG `:91-140`)
- Test: `tests/status_page_spec.lua`, `tests/controller_spec.lua`

**Interfaces:**
- Consumes: `Diary:openStatus` / `closeStatus` (5), `status.MODEL_ROW` (3).
- Produces: `Controller:probe_job() -> { run = deps.remote_fn({{role="user", content="ok"}}, false, { max_tokens = 1 }) }` (K11); `CFG.probe_ceil_s` (таймаут задачи раннера).
- Поведение: `openStatus` рисует страницу сразу со строкой «модель: проверяю…», затем `runner:start("probe", job.run, { timeout_s = CFG.probe_ceil_s, on_done })`. `net.state() ~= "up"` → строка «модель: нет сети», задача не стартует. `start` → `nil,"busy"` → «модель: не проверена (занято: <busy()>)» (K10). `on_done`: страница всё ещё та же (`self.status == view`) → строка «модель отвечает (N мс)» или «модель: <err>», частичный refresh только этой строки. `closeStatus` → `runner:cancel("probe")`.

- [ ] **Step 1: тесты**: поддельный раннер — `openStatus` выводит страницу **до** вызова `on_done`; `on_done` с payload → строка «модель отвечает»; с `nil,"timeout"` → «модель: timeout»; `on_done` после `closeStatus` ничего не рисует; `busy()=="sync"` → «занято: sync», `start` не зовётся повторно; `net.state()=="off"` → «нет сети», раннер не трогается. `controller_spec`: `probe_job().run` — функция, `remote_fn` получил `max_tokens = 1`.
- [ ] **Step 2:** FAIL. **Step 3:** код. **Step 4:** `tests/run.sh` OK.
- [ ] **Step 5:** живая проверка (тестер): страница появляется сразу, строка модели дописывается; при выключенном Wi‑Fi — «нет сети» без задержки.
- [ ] **Step 6:** коммит `feat(diary): страница состояния дописывает, отвечает ли модель — в фоне, без задержки показа`.
