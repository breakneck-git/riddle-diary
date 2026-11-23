# Карта мародёров — план (утверждён оркестратором 2026-11-06)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** роза ветров (или фраза вселенной) на странице дневника открывает на весь экран карту настоящей местности
вокруг Kindle в стиле вселенной персонажа — улицы и дома тушью, подписи зданий на языке вселенной, 2–6 героев
следами с именами, правдоподобно для часа, дня недели и сезона; закрывается розой, фразой или сама.

**Architecture:** данные карты (признак «мир Поттера», название, фразы, словарь зданий, герои) — два новых раздела
`persona.SECTIONS` (`map`, `map.cast`) в существующей фоновой генерации, один формат для всех персон, у «Методов»
генерируются только они. Распознавание розы, точка, местность, расстановка героев — чистые модули без UI
(`riddle/rose.lua`, `riddle/mapdata.lua`, `riddle/geo.lua`, `riddle/terrain.lua`, `riddle/cast.lua`), тесты на Mac.
Сеть (Wi‑Fi скан, BeaconDB, IP, Overpass) — одно задание дочернего процесса `"map"`; оно же единственный писатель
файлов `/mnt/us/riddle/map/`. Экран карты — режим виджета дневника (`riddle_mapview.lua`): ввод, холст, таймеры и
`push` остаются у `Diary`.

**Tech Stack:** LuaJIT (KOReader v2025.08), luasocket+luasec (`riddle/http.lua`), `dkjson`, SQLite (`lua-ljsqlite3`),
KOReader `Blitbuffer`/`RenderText`/`UIManager`; тесты `tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-06-marauders-map-design.md` (одобрена владельцем 2026-11-06: «Одобряю.»).
Задача Notion 40a13e60-bc8d-8163. Запрос владельца дословно — в локальных заметках автора (в репозиторий не входит).

## 1. Как сейчас (факты, HEAD 9001258, `tests/run.sh` → «47 specs, OK»)

Пути от `plugin/riddlediary.koplugin/`; W = `riddle_diarywidget.lua`.

| Что | Факт | Источник |
|---|---|---|
| Разделы генерации | `persona.SECTIONS`: `persona`, `world`, затем `texts.<name>` по `texts.SETS`; раздел — `{ name, max_tokens, messages(row, view), decode(text, lang) -> part \| nil, err }` | `riddle/persona.lua:90-125`, `:68-80` |
| «Методов» не генерирует | `next_section` → nil при `row.id == METHODS_ID` | `riddle/persona.lua:181-182` |
| «Методов» без разделов | `_current` у встроенной отдаёт `METHODS_VIEW, METHODS_ROW`, `parts = nil`; `_gen_next` без parts → nil | `riddle/controller.lua:20`, `:246-254`, `:316-320` |
| Хранилище разделов | `persona_parts(persona_id, name, text, ts, PK(persona_id,name))`, строка `personas` id 1 `:methods` — миграция 5; `set_part` — `INSERT OR REPLACE` | `riddle/memory.lua:45-52`, `:475-495` |
| Схема | `SCHEMA_VERSION = 6` | `riddle/memory.lua:39` |
| Генерация фоном | задание `gen` первым в `_summary_job`; сохранение — `_save_summary`: `decode` → `set_part`, лог `riddle: gen <раздел> saved`; сбой (не отмена) — `gen_hold` до следующей страницы | `riddle/controller.lua:989-994`, `:1038-1044`, `:1121-1132`, `:453-461` |
| Фразы «Методов» | `Controller:texts` у встроенной — `texts[name]` до чтения parts | `riddle/controller.lua:340-341` |
| `forget_persona` | «Методов» не трогает | `riddle/controller.lua:443-449` |
| Порядок разделов в тестах | `test_text_sections_follow_persona_in_order`, `test_gen_resumes_from_missing_section`; фабрики `bare`, `make` | `tests/whose_spec.lua:356`, `:422`, `:38`, `:66` |
| Снимок промптов «Методов» | `tests/fixtures/methods_prompts.lua`, сравнение с `prompt.open("B64", ctx)` фиксированного ctx | `tests/prompt_spec.lua:1526`; `tests/whose_spec.lua:226`, `:1357` |
| Сборка `prompt.open` | блоки формата добавляются по ctx (`with_tasks` → `TASK_FORMAT` и `,"task":""` в пример), затем `ANSWER_FORMAT` | `riddle/prompt.lua:375-414`, `:19` |
| Разбор ответа | `want_json`: обязателен `read`; отдаются read, reply, task, tasks_source, picks, who, world, lang, yes | `riddle/llm.lua:262-273` |
| Пустой reply | прочитано, reply пуст → «запасной», цепочка идёт к следующему провайдеру | `riddle/llm.lua:347-351`, `:362` |
| User-Agent | `riddle-diary/1.0` | `riddle/llm.lua:10` |
| Решение «записать и ответить» | режим `open`: `usable` → `_remember(sid, read, reply…)`, `job.answered = true`; печать закрыта — `seal:feed(read)` | `riddle/controller.lua:818-857`, `:868-870` |
| Страница → задание | `_begin`: PNG прочитан и удалён, ветка по `seal.open` | `riddle/controller.lua:653-730` |
| Штрих | `{ p = {x1,y1,x2,y2,…}, b = {x0,y0,x1,y1}, t_end, lvl }`, точки без времени; `self.page = { strokes, ink }` | W:946-947, `:968-972` |
| Ввод | сырые касания: `hookInput` подменяет `feedEvent`, `onRawTouch` → `penDown`/`penMove`/`penUp`; жестов KOReader нет | W:864, `:891`, `:950`, `:995`, `:1019` |
| Не-чернила | только угол выхода (квадрат 150 px, 3 с) | W:952-961, CFG `corner` W:119 |
| Конец страницы | `penUp` → таймер `idle_s = 2.5` → `onPageDone`: крошечная — пропуск; ответ в пути — отказ `busy` в очередь; иначе PNG → `responder` | W:1040, `:1118-1150`, `:1197` |
| Ответ → экран | `respond` → `ctl:begin` → `runner:start("answer")` → `ctl:finish` → `cb(answer, unlocked)`; очередь `queue` → `nextAnswer` → `revealAnswer` | W:411-446, `:1197-1241`, `:1306`, `:1381`; `riddle/controller.lua:905`, `:911` |
| Перо гасит фон | `penDown`: `runner:cancel("sync")`, `cancelSummary()` | W:964-966 |
| Экран | холст BB8 `canvas`; `Diary:push(x,y,w,h,mode)`: `blitFrom` + прямой `mech_refresh` для A2/DU; полный — `setDirty(self,"full")` | W:370, `:745`, `:67-71`, `:670` |
| Рисование | перо `stamp` 4 px, `line(bb,x0,y0,x1,y1,c,pen)` — локальные функции виджета; текст — ручная раскладка `layoutText`/`drawGlyph` шрифтом `fonts/MarckScript-Regular.ttf` | W:215-224, `:170`, `:204`, `:75` |
| Таймеры | `Diary:schedule/cancel` (все снимаются в `resetPage`) | W:725-741, `:691` |
| Сон | `onSuspend` → `controller:on_sleep()`, страница стёрта; `onResume` → чистая страница + приглашение | W:645-674; `riddle/controller.lua:1183` |
| Дочерний процесс | один за раз; `start(kind, fn, {timeout_s, on_done})`; вытесняет только `"answer"`; конверт ≤ 32768 байт; опрос 0.2 с | `riddle/worker.lua:13-14`, `:121-140`, `:126`, `:45` |
| Фоновое при открытии | `maybeSync` (раз в 60 с), `startSync` — образец нового задания | `main.lua:225`, `:141`, `:96` |
| HTTP | `http.request(method,url,headers,body,timeout_s)`; **только https** (`^https://`, иначе `unsupported url`); verify none; без gzip и без потолка размера ответа | `riddle/http.lua:341`, `:276-278`, `:42`, `:255` |
| Сеть | `net.state()` → `up`/`down`/`off` без сетевых вызовов | `riddle/net.lua:14` |
| Shell | `io.popen` в плагине нет; один `os.execute("mkdir -p …")` | `riddle/devtest.lua:168` |
| Время | часа/дня недели/сезона/часового пояса в коде нет; `os.time` внедряется как `wall` | `main.lua:71`, `:179`; W:1353 |
| Файлы-кэши | только SQLite; атомарной записи (`os.rename`) нет | grep по плагину |
| Бюджеты | `ANSWER_BUDGET_S = 25`, `GEN_BUDGET_S = 50` | `riddle/app.lua:16`, `:24` |

## 2. Дизайн

**Данные карты — один формат.** Раздел `map` (JSON-объект) и раздел `map.cast` (JSON-массив) в `persona_parts`,
добавлены в конец `persona.SECTIONS` (порядок прежних не меняется). Чтение — только `mapdata.of(view, row, parts)` →
`{ potter, title, open, close, blind, places = { [kind] = name }, cast = { {name, role, day, night} } }`:
- `potter = (row.id == persona.METHODS_ID) or map.potter == true` — правило «Методы — мир Поттера» в одном месте;
- `potter` → `title`, `open`, `close` — канонические из `mapdata.POTTER` (ru/en), сгенерированные игнорируются
  (спека, раздел 1);
- раздела нет — запасные: `title` «Карта»/«Map» по языку персоны, `blind` — `mapdata.BLIND[lang]`, `places = {}`,
  `cast = {}` (карта рисуется, героев нет).

Формат `map`: `{ "potter": bool, "title": str, "open": str, "close": str, "blind": str, "places": { kind: str } }`,
ключи `places` — из `terrain.KINDS` (единственный список типов зданий: `school`, `worship`, `pub`, `shop`,
`hospital`, `station`, `library`, `park`, `house`). Формат `map.cast`: 10–15 объектов
`{ "name": str ≤ 30 знаков, "role": "student"|"teacher"|"guard"|"villain"|"townsfolk", "day": "school"|"work"|"street"|"home", "night": "home"|"street" }`;
годных < `mapdata.MIN_CAST = 6` — раздел не сохраняется (как пул < 30 у фраз).

**«Методов».** `persona.next_section` у `METHODS_ID` — первый недостающий из `persona.MAP_SECTIONS`
(`{ map, map.cast }`); `_current` у встроенной читает `memory:parts(1)` (нет таблицы — `nil`, как сейчас).
`METHODS_VIEW`, её промпт и фразы не меняются; `persona.ready`, `Controller:texts` у неё по-прежнему не смотрят parts.
`messages(row, view)` разделов карты у «Методов» получает `row.line` из строки personas id 1 (миграция 5) — мир
«Методов», не канон Роулинг.

**Открытие.** (а) Роза: `onPageDone` при открытой печати (`ctl.seal_open`) зовёт `rose.detect(pg.strokes)` до PNG;
да → страница не уходит ни в модель, ни в память, в очередь встаёт элемент `{ kind = "map" }` — карта открывается,
когда очередь дошла до него (ответ в пути сначала проявится). Печать закрыта — страница идёт в печать как обычно
(решение 4). (б) Фраза: `prompt.open` с `ctx.map` добавляет блок `prompt.MAP_FORMAT` и ключ `"map"` в пример;
`llm.parse` отдаёт `map = "open"` (только эта строка); `_answer` в режиме `open` при `result.map == "open"` не
пишет память, не ставит `job.answered`, возвращает `nil, "map"`; `respond` передаёт действие в `cb` третьим
значением, виджет ставит в очередь `{ kind = "map" }`. Режим `setup` (персона генерируется) фразу не понимает —
открывает только роза.

**Закрытие.** На карте штрихи вне зон сдвига — чернила, как на странице; после `idle_s` — `rose.detect` → закрыть;
иначе (сеть есть) — чтение `prompt.map_read(png_b64, map)` → `{ read, map = "close"|"" }` через тот же runner
(`"answer"`) с `opts.reply_optional = true` (пустой reply не «запасной»). Закрывают также: сон (`onSuspend`),
`CFG.map_idle_s = 180` без касаний, угол выхода (как сейчас — выходит из дневника). После закрытия — чистая
страница дневника (`resetPage` + приглашение).

**Точка.** Задание `"map"` в дочернем процессе: `run("wpa_cli scan_results")` → `geo.parse_scan` → BeaconDB
(`POST https://api.beacondb.net/v1/geolocate`, `{"wifiAccessPoints":[{macAddress,signalStrength}],"considerIp":false}`)
→ нет — IP (`GET https://ipinfo.io/json`, поле `loc` «lat,lon»). Выбор — `geo.choose(saved, fresh, now)`: точка по IP
не заменяет сохранённую по Wi‑Fi ближе `geo.CITY_M = 25000` м; иначе свежая. Точка — `map/point.json`
`{ lat, lon, source = "wifi"|"ip", acc, ts }`. Координаты и BSSID в лог не идут — только источник и точность.

**Местность.** Поле — экран + по полэкрана с каждой стороны (2 × экран по каждой оси), масштаб
`terrain.M_PER_PX = 0.7` (экран 758 px ≈ 530 м — «несколько улиц»; подбирает тестер). Новая точка дальше полуэкрана от
центра сохранённой местности (или местности нет) — Overpass (`POST https://overpass-api.de/api/interpreter`, QL с
`[out:json][timeout:20]`, bbox поля: `way[highway~…]`, `way[building]`, `out geom qt;`). Дочерний процесс сжимает
ответ `terrain.compact(raw, center)` в целые пиксели поля (полилинии улиц, контуры зданий, `kind` по тегам) и сам
пишет `map/terrain.json` (временный файл → `os.rename`); в конверт — только `{ ok, ways, bytes }`, не данные
(конверт ≤ 32 КБ). Ближе экрана — та же местность, центр карты сдвинут на разницу. Родитель файлы только читает и
проверяет; негодный — как нет.

**Герои.** `cast.place(cast, terrain, t, seed) -> { {name, x, y, at = "street"|kind|"home"} }` — чистая функция:
`t = { hour, wday, month }` из `os.date("*t")`; ночь (22–6): `night == "street"` — на улицах, остальные дома, школа
пуста; день будни: `day == "school"` — в школе (есть в местности, 8–15 ч, не каникулы июнь–август), `work` — в
не-жилом здании или на улице, `street` — на улице, `home` — дома; выходные — школа пуста, школьники на улицах или
дома; зима — меньше на улицах. Дом героя — `hash(name) mod #жилых зданий` местности: тот же между открытиями, пока
местность та же. Состав — 2–6 из `cast`, ротация по `seed` (номер открытия); ≥ 1 на экране, 0–3 в запасе поля.
Шаг движения — `cast.step(state, terrain, dt)` раз в `CFG.map_step_s = 2.5`: уличные идут по полилинии, из запаса
заходят на экран; след — пара отпечатков + подпись, старые гаснут через `CFG.map_trail = 4` шага.

**Экран.** `riddle_mapview.lua` рисует на холст `Diary`: пергамент (белый фон, рамка), улицы — `line` пером 2 px,
здания — контуры 1 px, подписи и имена — `layoutText`/`drawGlyph` (MarckScript). Заголовок и атрибуция «© OpenStreetMap»
не рисуются (владелец 2026-11-16: «опенстритмап можно убрать снизу и "карта мародеров" сверху? чтобы хотябы 90% занимала
карта»; вернуть атрибуцию, если дневник станет публичным). Подписи мест: каждое имя — один раз на всё поле, у здания
этого типа с наибольшей площадью (равенство — ближе к центру поля); здание за экраном — подписи нет; парк меньше
1/40 экрана не подписывается; кегль 32 px (владелец 2026-11-16: «несколько хогвартсов… надписи вообще не читаются»).
Подложек нет (владелец 2026-11-16: «сделай без плашек, но чернее и жирным»): подписи и имена героев — `inkTexts`/`labelOpts`,
порог 0xC0, жирность +1 px по x, белая обводка по контуру букв 2 px (не прямоугольник), только внутри поля туши. Проявление: улицы и здания партиями по `CFG.map_ink_batches = 4` с шагом 0.3 с (`push` DU), потом
следы. Перо и `stamp`/`line` выносятся из W в `riddle_ink.lua` — одно перо на дневник и карту.

**Сдвиг поля.** `mapview.zone(x, y, w, h) -> "edge"|"pad"|nil`: полоса `CFG.map_edge_px = 83` (≈ 1 см при 212 ppi) у
любого края — штрих, начатый в ней, сдвигает поле на вектор штриха (на penUp); нижняя полоса `CFG.map_pad_px = 167`
(≈ 2 см) — тачпад: пока палец лежит, движение тащит карту (перерисовка не чаще `CFG.map_drag_s = 0.4`, A2). Сдвиг
ограничен полем. Касания в зонах — не чернила и не страница.

## 3. Изменения потока данных и памяти (утверждены оркестратором 2026-11-06, раздел 6)

1. **У «Методов» появляются строки `persona_parts`** (`map`, `map.cast` при `persona_id = 1`) — впервые у встроенной;
   `_current` читает её parts. Миграции нет, схема та же (`riddle/memory.lua:45-52`). `forget_persona` по-прежнему её
   не трогает — пересоздать карту «Методов» можно только руками в базе (решение оркестратора: так и оставить,
   `forget_persona` не меняется).
2. **Прочитанная страница при открытой печати впервые не ложится в память**: `result.map == "open"` → без
   `_remember`, без `job.answered` (свёртка не назревает, повод пересказа не тратится).
3. **Ответ модели получает ключ `"map"`**; живой промпт «Методов» меняется: блок `MAP_FORMAT` добавляется при
   `ctx.map`, а у «Методов» `ctx.map` есть всегда (мир Поттера). Снимок `tests/fixtures/methods_prompts.lua` остаётся
   зелёным (его ctx без `map`), но правило «промпты Методов ни на байт» (план whose-diary, Global Constraints)
   нарушается по замыслу спеки (решение 3).
4. **Новые файлы вне SQLite** — `/mnt/us/riddle/map/point.json` (точка владельца) и `map/terrain.json` (кэш OSM).
   Единственный писатель — задание `"map"` в дочернем процессе; родитель только читает. Удаление файлов безопасно
   (как первое открытие).
5. **Новые внешние хосты** — `api.beacondb.net` (список BSSID соседних сетей), `ipinfo.io` (IP), `overpass-api.de`
   (bbox поля); все https, `User-Agent: riddle-diary/1.0`.
6. **Новое задание runner `"map"`**: ответ его вытесняет (`worker.lua:126`), перо на карте его не отменяет. Пока карта открыта, хвосты (генерация, пересказ, свёртка) и синхронизация Notion не стартуют — runner и батарея за картой; после закрытия — как после ответа.

## 4. ASSUMPTION и замеры

Живых вызовов в плане не делалось. Каждый пункт снимает замер тестера на Kindle (лог `riddle:`), срез указан.

| # | Допущение | Кто снимает |
|---|---|---|
| A1 | `wpa_cli scan_results` у процесса KOReader; формат `bssid / frequency / signal level / flags / ssid` | **снято 2026-11-06, с поправкой:** `/usr/bin/wpa_cli`, KOReader и ssh — root; формат подтверждён (таб, частота, сигнал, флаги). Без `wpa_cli -i wlan0 scan` список несвежий (1 сеть вместо 5) — задание `"map"` сначала зовёт `scan` (ответ `OK`), ждёт 1–2 с, потом `scan_results`; свежий список за ≤ 1 с, 2,4 ГГц |
| A2 | BeaconDB — Ichnaea-совместимый API (`location.lat/lng`, `accuracy`), точность на сетях владельца | **снято 2026-11-06:** скан с Kindle (5 сетей) → accuracy 34 м, IP-точка в ~0,9 км (спека, раздел 1). Формат 404 — тест `test_parse_beacondb_ok_and_404` по документации, живьём — тестер в срезе 4 |
| A3 | `https://ipinfo.io/json` без ключа отдаёт `loc` «lat,lon» с точностью до города | **снято 2026-11-06:** с Kindle HTTP 200, `loc` «число,число», `city` есть |
| A4 | Overpass на bbox поля (≈ 1,1 × 1,4 км) у дома владельца отвечает < 10 с и < 1,5 МБ | **не держится (срез 5, живьём):** 38 с / 1,9 МБ; центр Парижа — 2,71 МБ / TTFB 30,7 с. Порог снят: первое открытие ждёт местность, дальше — кэш (срез 10, «Потом» — подгрузка заранее) |
| A5 | разбор ответа Overpass (`dkjson`) в дочернем процессе PW2 < 5 с, сжатый `terrain.json` — десятки КБ (спека, раздел 3) | **замер тестера (срез 5):** лог `riddle: map terrain compact ways=N bytes=B in T ms, child RSS KB` |
| A6 | `os.date("*t")` на Kindle даёт местное время владельца | **снято 2026-11-06 для `date`:** расхождение с Mac ≤ 1 с; `/etc/localtime` → `/var/local/system/tz`, строка зоны странная (`GMT+4:0100`) — зону не разбирать, брать `os.date("*t")`/epoch. В процессе KOReader подтверждает тестер в срезе 7 логом часа |
| A7 | полная отрисовка местности + проявление укладывается в «несколько секунд» | **замер тестера (срез 6):** лог `riddle: map drawn ways=N in T ms` |
| A8 | `os.rename` на FAT `/mnt/us` заменяет файл целиком (обрыв не оставляет половину) | снято проверкой при чтении: негодный JSON — как файла нет (срез 4, тест `test_bad_point_file_is_missing`) |
| A9 | 1 см ≈ 83 px (PW2 212 ppi) | тестер линейкой (срез 9) |
| A10 | роза пальцем распознаётся порогами среза 1 | **замер тестера (срез 1):** 10 роз и 10 обычных страниц (буквы, крест, «о», круг без креста), devmode-лог `riddle: rose yes|no score=…` |
| A11 | модель узнаёт клятву по любой узнаваемой части ключевых слов (ru/en) | **замер тестера (срез 3):** 6 вариантов из таблицы теста `test_map_format_keywords` пером |
| A12 | батарея: шаг 2,5 с частичным обновлением, 3 мин до автозакрытия — расход приемлем | **замер тестера (срез 8):** заряд до/после 10 мин открытой карты (3 цикла) |

## 5. Решения (оставленные спекой исполнителю)

1. **Роза** — `rose.detect(strokes) -> ok, score`: штрих-круг (замкнут: зазор ≤ 25 % диаметра; радиусы точек от
   центра — разброс ≤ 25 %; обход ≥ 300°) и два почти прямых штриха (отклонение от хорды ≤ 12 % длины), длиной
   ≥ 60 % диаметра, пересекаются внутри круга под 60–120°; прочие штрихи ≤ 1 (неровный росчерк). Порядок штрихов любой;
   круг из двух дуг — склеить соседние концы ≤ 30 px. Пороги — константы `rose.*`, подбираются по A10.
2. **Хранение** — JSON-файлы `map/` (раздел 2): кэш, не память; один писатель.
3. **Расстановка и шаг** — раздел 2; шаг 2,5 с.
4. **Автозакрытие** — 180 с без касаний.
5. **Рисунок** — линии пером, без растров; пергамент — белый с рамкой в 2 линии и розой в углу (своё SVG-подобное
   из линий).
6. **Надпись «карта не видит»** — поле `blind` раздела `map` (вопрос 1 ниже).
7. **Роза, пока ответ в пути** — карта ждёт в очереди, пока ответ проявится (ответ на записанное не теряется).

## 6. Решения оркестратора (2026-11-06)

1. **`blind`** — да: поле раздела `map`, генерируется для всех персон, включая мир Поттера и «Методов» (канона у фразы
   нет); до генерации и без раздела — `mapdata.BLIND` ru/en.
2. **Промпт «Методов»** — блок `MAP_FORMAT` при `ctx.map` разрешён (спека, решение 1 с уточнением 2026-11-06). Условие:
   текст персоны «Методов» байт в байт прежний, блок идёт отдельным куском после него; снимок
   `tests/fixtures/methods_prompts.lua` без `ctx.map` — зелёный без правки; с `ctx.map` — отдельный новый снимок.
3. **Замер BeaconDB** — сделан (A2 снято). До среза 4 остаются A1 и A3, до среза 7 — A6.
4. **Поток данных** — изменения 1, 2, 4, 5, 6 раздела 3 приняты как написаны; предложение про `forget_persona` у
   «Методов» отклонено (YAGNI). BSSID соседних сетей уходят в BeaconDB, IP — в ipinfo.io — покрыто одобренной спекой
   (решение 5, раздел 1).

## Global Constraints

- Владелец 2026-10-31: «Будем называть её картой мародёров, но это не карта мародёров, это будет карта конкретно по вселенной, которую выбрал пользователь.»
- Владелец 2026-10-31: «Причём я хочу, чтобы это была не конкретно, вся фраза целиком, обязательно, чтобы это были ключевые слова в этой фразе.»
- Владелец 2026-11-06: «Давай этот сантиметр, как ты говоришь, но ещё плюс сделаем снизу область сантиметра два для того, чтобы положить палец, и пока не оторвал, это будет двигать карту».
- LLM при открытии карты не зовётся (кроме чтения фразы — тем же чтением страницы); построение после распознавания — несколько секунд.
- Картинки — только свои, линии; чужих тайлов и картинок нет; атрибуция «© OpenStreetMap» снята по слову владельца 2026-11-16 (личный дневник) — вернуть при публичном показе.
- Сеть — только `riddle/http.lua` (https), в дочернем процессе, по одному заданию; заголовок `User-Agent: riddle-diary/1.0`.
- В лог Kindle — ни координат, ни BSSID, ни текста страниц, ни имён героев: только источники, числа, состояния.
- Нет сети, гео или данных карты — карта открывается (пергамент, надпись `blind`), дневник не падает.
- Данные карты — только через `mapdata.of`; типы зданий — только `terrain.KINDS`; перо — только `riddle_ink.lua`.
- `tests/run.sh` зелёный перед каждым коммитом; коммит в main клона, без push.

## Review Focus

1. Роза при закрытой печати, во время ответа в пути, во время проявления ответа → печать как обычно / карта после ответа / карта после проявления; ни одна страница-роза не в памяти — `test_rose_sealed_goes_to_seal`, `test_rose_during_ponder_waits_answer` (1).
2. Сон, автозакрытие, угол выхода при открытой карте посреди загрузки местности → после пробуждения чистая страница и приглашение, задание `"map"` снято или его файл дописан целиком — `test_sleep_closes_map_and_cancels_job` (1), `test_bad_point_file_is_missing` (4).
3. Модель вернула `map` строкой, отличной от `"open"` (`"true"`, `"Open"`, `true`), или ключа нет → обычный ответ — `test_parse_map_only_open` (3).
4. Персона ещё генерируется (раздела `map` нет) или Kindle офлайн при первом открытии → пергамент с надписью `blind`, без героев, без падения — `test_mapdata_defaults_without_parts` (2), `test_first_open_offline_blind` (4).
5. Местность без школы, без жилых зданий, без улиц (поле, лес) → герои только на доступных местах, число 2–6, ≥ 1 на экране либо 0 героев при пустой местности — `test_place_no_school_no_houses` (7).

---

## Порядок

Строго последовательно: 1 → 2 → 3; 4 → 5 → 6 → 7 → 8; 9 и 10 после 5. Срезы 11–13 — после 10: 11 и 12 правят
W и MV — по очереди; 13а — после 12 (оба трогают `heroes`/раскладку MV); 13б — после выбора оркестратора, правит
`memory/llm/prompt/controller` и может идти параллельно с 11–13а. Срезы 2 и 4 правят разные файлы и могут идти
параллельно (2 — `persona/prompt/controller`, 4 — `geo/main/worker`), если оркестратор даст двух исполнителей. Виджет
(W) правят 1, 3, 8, 9 — только по очереди. Устройство деплоит один исполнитель.

## Срез 1: роза открывает пустой пергамент и закрывает его

~350 строк. Страница с розой не идёт в модель и в память, Реддл не отвечает.

**Files:**
- Create: `riddle/rose.lua`, `riddle/mapdata.lua` (только `title` и `blind` по языку; `potter` по правилу «Методов»), `riddle_mapview.lua`, `riddle_ink.lua`
- Modify: `riddle_diarywidget.lua` (`onPageDone`, `penDown`/`penMove`/`penUp` в режиме карты, очередь `kind = "map"`, `onSuspend`, вынос `stamp`/`line`)
- Test: `tests/rose_spec.lua` (новый), `tests/mapview_spec.lua` (новый), `tests/async_answer_spec.lua`, `tests/fixtures/rose_strokes.lua` (новый)

**Interfaces — Produces:**
- `rose.detect(strokes) -> ok: bool, score: number` (strokes — формат W:946).
- `mapdata.of(view, row, parts) -> { potter, title, blind, open?, close?, places, cast }`; `mapdata.POTTER = { ru = { title = "Карта мародёров", open = "Торжественно клянусь, что замышляю шалость, и только шалость", close = "Шалость удалась" }, en = { title = "The Marauder's Map", open = "I solemnly swear that I am up to no good", close = "Mischief managed" } }`; `mapdata.BLIND = { ru = …, en = … }`.
- `Controller:map() -> mapdata` (текущая персона; сбой чтения — запасные).
- `MapView.new(diary, data) -> view`; `view:open()`, `view:close()`, `view:onStrokeDone(stroke)`; `Diary:openMap()`, `Diary:closeMap(why)`; лог `riddle: map open (rose|phrase)`, `riddle: map close (rose|phrase|idle|sleep)`.
- `riddle_ink.stamp(bb,x,y,c)`, `riddle_ink.line(bb,x0,y0,x1,y1,c,pen)` — те же, что W:215-224.

- [ ] **Шаг 1: фикстуры** `tests/fixtures/rose_strokes.lua` — синтетика: `rose_ccw`, `rose_cw_cross_first`, `rose_two_arcs`, `rose_tilted_30`; не-розы: `circle_only`, `cross_only`, `letter_o`, `word_salandusa` (штрихи букв), `x_in_square`, `spiral`.
- [ ] **Шаг 2: тесты (падают).** `rose_spec`: `test_detect_roses` (4 розы → true), `test_detect_non_roses` (6 → false), `test_stroke_order_irrelevant`. `async_answer_spec` (фейковый runner, настоящий контроллер): `test_rose_opens_map_without_model_or_memory` — `onPageDone` со штрихами розы при открытой печати → `runner:start` не вызван, `memory:add` не вызван, `diary.map ~= nil`; `test_rose_sealed_goes_to_seal` — печать закрыта → обычный `respond`; `test_rose_during_ponder_waits_answer` — `inflight = 1` → карта открывается после `revealAnswer` ответа; `test_rose_on_map_closes`; `test_map_idle_closes` (`CFG.map_idle_s` без касаний); `test_sleep_closes_map_and_cancels_job`; `test_no_followup_while_map_open` (хвост, назначенный до открытия, не стартует, пока карта открыта; после закрытия — стартует). `mapview_spec`: `test_title_methods_is_marauders` (`mapdata.of(METHODS_VIEW, METHODS_ROW, nil).title == "Карта мародёров"`), `test_title_default_by_lang`.
- [ ] **Шаг 3:** `tests/run.sh` — FAIL на новых.
- [ ] **Шаг 4: реализация.** `stamp`/`line` → `riddle_ink.lua`, W читает оттуда. В `onPageDone` до `sampleBox`: `if ctl and ctl.seal_open and rose.detect(pg.strokes)` → очередь `{ kind = "map", page = pg }`; `nextAnswer` на `kind == "map"` зовёт `openMap`. Режим карты: `penDown`/`penMove`/`penUp` пишут штрихи в `self.map.page`; таймер `idle_s` → `view:onStrokeDone` → роза → `closeMap("rose")`. Пергамент: белый холст, рамка, название по центру сверху (`layoutText`, `prompt_px`), `push(…, "full")` на открытии и закрытии. `onSuspend`: `closeMap("sleep")` до `resetPage`.
- [ ] **Шаг 5:** `tests/run.sh` — PASS.
- [ ] **Шаг 6: коммит** `feat(map): роза ветров открывает и закрывает пустой пергамент — страница не в память, ответа нет (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 7 (тестер):** после печати нарисовать розу → пергамент «Карта мародёров»; роза на нём → страница дневника чистая, Реддл молчит; 3 мин без касаний → закрылась; сон на карте → после пробуждения приглашение. Замер A10 (devmode: `riddle: rose yes|no score=…`). Копия базы до/после: `COUNT(*) entries` не вырос.

## Срез 2: данные карты в генерации персонажа

~350 строк.

**Files:**
- Modify: `riddle/persona.lua` (`MAP_SECTIONS`, `next_section` у «Методов»), `riddle/prompt.lua` (`gen_map`, `gen_cast`), `riddle/mapdata.lua` (полный разбор), `riddle/controller.lua` (`_current` у встроенной читает parts; `Controller:map`)
- Create: `riddle/terrain.lua` (пока только `terrain.KINDS`)
- Test: `tests/whose_spec.lua`, `tests/mapview_spec.lua`, `tests/prompt_spec.lua`

**Interfaces — Produces:**
- `persona.MAP_SECTIONS = { map, map.cast }` (те же таблицы — в конце `persona.SECTIONS`); раздел `map`: `max_tokens = 1500`, `decode` → JSON по формату раздела 2 (обязательны `potter` boolean, непустые `title`, `open`, `close`, `blind`, проверка `texts.fits` как у `invitation`; `places` — только ключи `terrain.KINDS`, значения ≤ 40 знаков, лишние ключи отброшены); `map.cast`: `max_tokens = 2000`, массив, годных ≥ `mapdata.MIN_CAST = 6`, не больше 15.
- `prompt.gen_map(view, row_line) -> messages`, `prompt.gen_cast(view, row_line) -> messages` — мир по строке; для «Методов» — мир «Методов рационального мышления»; роли и распорядок — словами ключей формата.
- `terrain.KINDS = { "school", "worship", "pub", "shop", "hospital", "station", "library", "park", "house" }`.

- [ ] **Шаг 1: тесты (падают).** `whose_spec`: `test_map_sections_after_texts` (у сгенерированной после последнего `texts.*` — `map`, затем `map.cast`); `test_methods_generates_only_map` (`make` «Методов»: `gen_due()` true, задание `section == "map"`, в messages есть «Методов»; после `map` и `map.cast` — `gen_due()` false; `persona`/`world`/`texts.*` не запрашивались); `test_methods_prompts_unchanged_after_map_parts` (`job.messages[1].content` ответа «Методов» с parts карты — снимок `open_empty`); `test_map_decode_rejects` (не JSON; `potter` строкой; пустой `title`; `places` с чужим ключом — ключ отброшен, раздел годен); `test_cast_under_min_not_saved` (5 годных → `set_part` не вызван, лог `riddle: gen map.cast failed (cast 5)`). `mapview_spec`: `test_mapdata_defaults_without_parts`, `test_mapdata_potter_canonical` (сгенерированный `title` «Карта Хогвартса» при `potter = true` → «Карта мародёров»), `test_mapdata_other_world` («Карта Средиземья», свои фразы).
- [ ] **Шаг 2:** `tests/run.sh` — FAIL.
- [ ] **Шаг 3: реализация.** `next_section`: `row.id == METHODS_ID` → первый недостающий из `MAP_SECTIONS`. `_current` у встроенной: `parts = memory:parts(METHODS_ID)` (pcall; ошибка — `nil`), `view`/`row` прежние. `mapview` берёт `ctl:map()`.
- [ ] **Шаг 4:** `tests/run.sh` — PASS. **Шаг 5: коммит** `feat(map): данные карты — разделы map и map.cast в генерации персонажа, у «Методов» только они (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** после ответа на Kindle в логе `riddle: gen map saved`, `riddle: gen map.cast saved` (хвосты); роза → «Карта мародёров». Замер A1 плана whose-diary для двух вызовов (`finish` не `length`).

## Срез 3: фраза открывает и закрывает карту

~300 строк.

**Files:**
- Modify: `riddle/prompt.lua` (`MAP_FORMAT`, `map_read`), `riddle/llm.lua` (`map`, `opts.reply_optional`), `riddle/controller.lua` (`_answer`, `_open_context` → `ctx.map`, `Controller:map_read_job`), `riddle_diarywidget.lua` (`respond`/`cb` — третье значение), `riddle_mapview.lua` (чтение на карте)
- Test: `tests/prompt_spec.lua`, `tests/llm_spec.lua`, `tests/whose_spec.lua`, `tests/async_answer_spec.lua`

**Interfaces — Produces:**
- `prompt.MAP_FORMAT` — ключ `"map"`: `"open"`, если запись — фраза, открывающая карту (`map.open`; хватает узнаваемой части ключевых слов, любой перевод; для мира Поттера — «замышляю», «шалость», «клянусь» / «solemnly swear», «up to no good»), иначе `""`; в примере `,"map":""`. Добавляется, только если `ctx.map`.
- `prompt.map_read(png_b64, map) -> messages` — нейтральное чтение без образа и памяти: `{"read":"…","map":"close"|""}`, «close» — фраза закрытия (`map.close`; для Поттера — «шалость удалась» / «mischief managed»).
- `llm.parse` → `map = "open"|"close"|nil` (только эти строки); `llm.call(…, { reply_optional = true })` — пустой reply не «запасной».
- `Controller:finish(job, payload, err) -> text | nil, action` (`action = "map"`); `Controller:map_read_job(png) -> job | nil` (сеть нет — nil).
- Лог `riddle: map phrase open|close` (без текста страницы).

- [ ] **Шаг 1: тесты (падают).** `prompt_spec`: `test_map_format_only_with_ctx_map` (без `ctx.map` — снимок «Методов» прежний; с ним — блок и `,"map":""`); `test_map_format_keywords` (в блоке — оба набора ключевых слов у Поттера, у другого мира — его `open`); `test_map_read_has_no_persona_no_memory`. `llm_spec`: `test_parse_map_only_open` (`"open"`, `"close"` → как есть; `"true"`, `"Open"`, `true`, нет ключа → nil); `test_reply_optional_not_spare`. `whose_spec`: `test_phrase_opens_map_without_memory` (результат `{read="…", reply="…", map="open"}` → `finish` → `nil, "map"`, `memory:add` не вызван, `job.answered` nil, `followup_due` не потрачен); `test_setup_mode_ignores_map`. `async_answer_spec`: `test_phrase_action_queues_map`; `test_map_phrase_closes` (на карте, после `idle_s`, не роза, сеть up → runner `"answer"` с `map_read`; `map = "close"` → `closeMap("phrase")`); `test_map_offline_phrase_does_not_close` (`net.state() == "down"` → runner не вызван, карта открыта).
- [ ] **Шаг 2:** FAIL. **Шаг 3: реализация.** **Шаг 4:** PASS.
- [ ] **Шаг 5: коммит** `feat(map): клятва вселенной открывает карту, «Шалость удалась» закрывает — чтением страницы, без записи в память (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** замер A11 — пером: «Торжественно клянусь, что замышляю шалость», «замышляю шалость», «клянусь, что я негодяй», «I solemnly swear», «up to no good», «ничего кроме шалости» → карта; «шалость удалась», «Mischief managed» на карте → дневник; обычная фраза → обычный ответ Реддла. `COUNT(*) entries` вырос только на обычную фразу.

## Срез 4: точка — Wi‑Fi, BeaconDB, IP

~300 строк.

**Files:**
- Create: `riddle/geo.lua`, `riddle/mapjob.lua` (задание дочернего процесса: точка; в срезе 5 — местность)
- Modify: `main.lua` (`run(cmd)` через `io.popen`, путь `map/`, запуск задания), `riddle_mapview.lua` (надпись `blind` без точки), `riddle_diarywidget.lua` (`openMap` → `startMapJob`)
- Test: `tests/geo_spec.lua` (новый), `tests/mapjob_spec.lua` (новый), `tests/async_answer_spec.lua`

**Interfaces — Produces:**
- `geo.parse_scan(text) -> { {mac, signal} }` (сортировка по сигналу, ≤ 20, без скрытых `_nomap` — исключение по правилу MLS).
- `geo.beacondb_body(aps) -> json`; `geo.parse_beacondb(status, body) -> { lat, lon, acc } | nil, err`; `geo.parse_ip(status, body) -> { lat, lon, acc = 20000 } | nil, err`.
- `geo.choose(saved, fresh) -> point` — правило раздела 2; `geo.distance_m(a, b)`.
- `mapjob.run(deps) -> { point_source, acc, terrain? }`, `deps = { run, request, read_file, write_file, rename, now, dir }`; пишет `dir/point.json` через `.tmp` + rename.
- `mapjob.read_point(read_file, dir) -> point | nil` (негодный — nil).
- Виджет: `CFG.map_ceil_s = 40`; runner `"map"`; лог `riddle: map point wifi|ip|saved|none acc=N in T ms`.

- [ ] **Шаг 1: тесты (падают).** `geo_spec`: `test_parse_scan` (фикстура вывода по A1: заголовок, 5 сетей, одна `_nomap`, одна без сигнала → 4); `test_parse_beacondb_ok_and_404`; `test_parse_ip_loc`; `test_ip_does_not_replace_wifi_same_city` (сохранена wifi, свежая ip в 3 км → сохранённая); `test_ip_replaces_wifi_other_city` (300 км → ip); `test_wifi_replaces_anything`. `mapjob_spec` (фейковые `run`/`request`): `test_wifi_then_beacondb`; `test_beacondb_miss_falls_to_ip`; `test_no_network_keeps_saved`; `test_point_written_atomically` (запись в `.tmp`, затем rename); `test_bad_point_file_is_missing`; `test_user_agent_on_every_request`; `test_log_has_no_coordinates`. `async_answer_spec`: `test_first_open_offline_blind` (`net.state() == "down"`, файла нет → надпись `blind`, runner не вызван); `test_open_starts_map_job_when_up`.
- [ ] **Шаг 2:** FAIL. **Шаг 3: реализация.** `run` — `io.popen(cmd):read("*a")` только в дочернем процессе. **Шаг 4:** PASS.
- [ ] **Шаг 5: коммит** `feat(map): точка карты — Wi‑Fi через BeaconDB, иначе IP; IP не сбивает домашнюю точку (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** дома с Wi‑Fi — лог `riddle: map point wifi acc=N`; `map/point.json` есть; Wi‑Fi выключен и файл удалён — надпись `blind` на пергаменте. Замеры A1–A3 — до кода этого среза.

## Срез 5: местность из OpenStreetMap тушью

~400 строк.

**Files:**
- Modify: `riddle/terrain.lua` (запрос, сжатие, проекция), `riddle/mapjob.lua` (местность), `riddle_mapview.lua` (улицы, здания, атрибуция)
- Test: `tests/terrain_spec.lua` (новый), `tests/fixtures/overpass_small.json` (новый, синтетика ~20 путей: 2 улицы, 6 домов, школа, храм, паб), `tests/mapjob_spec.lua`

**Interfaces — Produces:**
- `terrain.M_PER_PX = 0.7`; `terrain.field(center, screen_w, screen_h) -> { bbox, w, h }` (2 × экран).
- `terrain.query(bbox) -> string` (Overpass QL).
- `terrain.compact(raw_json, center, field) -> { center, w, h, streets = { {x1,y1,…} }, buildings = { { pts = {…}, kind? } } }` (целые пиксели поля; `kind` по тегам: `amenity=school|building=school` → `school`, `amenity=place_of_worship` → `worship`, `amenity=pub|bar` → `pub`, `shop=*` → `shop`, `amenity=hospital` → `hospital`, `railway=station|public_transport=station` → `station`, `amenity=library` → `library`, `leisure=park` → `park`, `building=house|residential|apartments|detached` → `house`).
- `terrain.needs_fetch(terrain, point, screen) -> bool` (нет местности или точка дальше полуэкрана от её центра: поле 2 × экран, иначе края экрана пустые; уточнено оркестратором 2026-11-16 по ревью среза 5).
- `mapjob` пишет `map/terrain.json`; конверт — `{ terrain = { ways, bytes } }`.
- Лог `riddle: map terrain fetched N bytes in T ms`, `riddle: map terrain compact ways=N bytes=B in T ms`.

- [ ] **Шаг 1: тесты (падают).** `terrain_spec`: `test_query_has_bbox_and_timeout`; `test_compact_projects_to_field` (центр → `w/2, h/2`, север вверху); `test_compact_kinds` (школа, храм, паб, жилой дом); `test_compact_drops_outside_field`; `test_needs_fetch_within_screen_false`, `_beyond_screen_true`. `mapjob_spec`: `test_terrain_fetched_once` (второй запуск с той же точкой — Overpass не вызван); `test_overpass_failure_keeps_old_terrain`; `test_envelope_small` (конверт < 1 КБ при местности 100 КБ).
- [ ] **Шаг 2:** FAIL. **Шаг 3: реализация.** Отрисовка: смещение = центр точки − центр местности; улицы `riddle_ink.line` пером 2 px, здания — 1 px; атрибуция в нижней полосе. **Шаг 4:** PASS.
- [ ] **Шаг 5: коммит** `feat(map): улицы и дома вокруг из OpenStreetMap — тушью по пергаменту, кэш на Kindle (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** роза дома → узнаваемые улицы вокруг; второе открытие без Wi‑Fi — та же местность. Замеры A4, A5; размер `map/terrain.json`.

## Срез 6: подписи на языке вселенной и проявление чернилами

~250 строк.

**Files:** Modify: `riddle_mapview.lua`, `riddle/mapdata.lua` (`label(kind)`). Test: `tests/mapview_spec.lua`.

**Interfaces — Produces:** `mapdata.label(data, kind) -> string | nil` (`places[kind]`; `house` не подписывается); `MapView:inkSteps() -> { {streets…}, … }` (`CFG.map_ink_batches = 4` партии, шаг 0.3 с, DU); подписи — по центру контура, не пересекаются (пропуск следующей), не выходят за экран; лог `riddle: map drawn ways=N labels=M in T ms`.

- [ ] **Шаг 1: тесты (падают).** `test_label_from_places` (школа → «Класс трансфигурации» из фикстуры раздела `map`); `test_no_label_for_house_or_unknown`; `test_labels_do_not_overlap`; `test_ink_batches_cover_all_once`.
- [ ] **Шаг 2:** FAIL. **Шаг 3:** реализация. **Шаг 4:** PASS. **Шаг 5: коммит** `feat(map): подписи зданий на языке вселенной, линии проступают как чернила (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** у школы/храма/паба на экране — подписи вселенной; линии появляются за 4 шага без вспышки. Замер A7.

## Срез 7: герои на своих местах

~350 строк.

**Files:** Create: `riddle/cast.lua`. Modify: `riddle_mapview.lua` (следы, имена). Test: `tests/cast_spec.lua` (новый).

**Interfaces — Produces:**
- `cast.clock(t) -> { night: bool, school_day: bool, weekend: bool, winter: bool }` (`t = os.date("*t")`).
- `cast.home(name, terrain) -> building_index | nil`.
- `cast.place(cast, terrain, t, seed, screen) -> { {name, x, y, at} }` — правила раздела 2; инварианты: 2–6 героев (меньше — если меньше в составе), ≥ 1 в пределах экрана, ≤ 3 в запасе поля, школа пуста ночью и в выходные, никого в школе без школы в местности.
- Отрисовка: пара отпечатков (`riddle_ink.stamp`) + имя `answer_px/2`; лог `riddle: map cast n=N visible=V`.

- [ ] **Шаг 1: тесты (падают).** `test_night_students_home_guard_street` (23:00 будни: ученик дома, сторож/злодей `night = street` на улице, в школе никого); `test_weekday_noon_students_in_school`; `test_weekend_school_empty`; `test_summer_no_school`; `test_bandit_villain_street_by_day` (`role = villain, day = street`); `test_home_stable_between_opens`; `test_count_and_visibility` (100 seed: 2–6, ≥ 1 видим, ≤ 3 в запасе); `test_place_no_school_no_houses` (только улицы → все на улицах; пусто → 0); `test_rotation_changes_cast` (разные seed — разные составы).
- [ ] **Шаг 2:** FAIL. **Шаг 3:** реализация. **Шаг 4:** PASS. **Шаг 5: коммит** `feat(map): герои вселенной на карте — по часу, дню недели, сезону и типу здания (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** днём в будни и ночью — разные расстановки (скриншоты `testShot`), имена читаются. Замер A6 до кода среза.

## Срез 8: следы движутся

~250 строк.

**Files:** Modify: `riddle/cast.lua` (`step`), `riddle_mapview.lua` (таймер шага, частичное обновление, след гаснет). Test: `tests/cast_spec.lua`, `tests/mapview_spec.lua`.

**Interfaces — Produces:** `cast.step(state, terrain, dt) -> state, dirty_rects` (уличные — вдоль полилинии на 20–40 px за шаг; из запаса — к экрану; в зданиях — на месте); `CFG.map_step_s = 2.5`, `CFG.map_trail = 4`; таймер шага только при открытой карте; `push` только `dirty_rects` (DU).

- [ ] **Шаг 1: тесты (падают).** `test_step_moves_along_street`; `test_step_reserve_enters_screen` (за 20 шагов хотя бы один из запаса на экране); `test_trail_fades_after_n`; `test_dirty_rects_only_changed`; `test_step_timer_stops_on_close` (нет таймеров после `closeMap`).
- [ ] **Шаг 2:** FAIL. **Шаг 3:** реализация. **Шаг 4:** PASS. **Шаг 5: коммит** `feat(map): следы героев проявляются шаг за шагом (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** следы идут без мерцания всего экрана; замер A12.

## Срез 9: сдвиг поля пальцем

~300 строк.

**Files:** Modify: `riddle_mapview.lua` (`zone`, сдвиг, тачпад), `riddle_diarywidget.lua` (касания в зонах не идут в страницу). Test: `tests/mapview_spec.lua`, `tests/async_answer_spec.lua`.

**Interfaces — Produces:** `MapView.zone(x, y, w, h, cfg) -> "edge"|"pad"|nil`; `MapView:pan(dx, dy)` (ограничение полем); `CFG.map_edge_px = 83`, `CFG.map_pad_px = 167`, `CFG.map_drag_s = 0.4`; лог `riddle: map pan edge|pad`.

- [ ] **Шаг 1: тесты (падают).** `test_zone_edges_and_pad` (углы: нижний край — `pad`); `test_edge_stroke_pans_not_ink` (штрих из полосы → `pan`, страница карты пуста); `test_pad_drag_follows_finger` (перерисовок не больше раза в `map_drag_s`); `test_pan_clamped_to_field`; `test_short_cross_in_middle_is_ink` (крест розы в центре — чернила, роза закрывает); `test_corner_exit_still_works_on_map`.
- [ ] **Шаг 2:** FAIL. **Шаг 3:** реализация. **Шаг 4:** PASS. **Шаг 5: коммит** `feat(map): поле двигается пальцем — от края и нижней полосой-тачпадом (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** штрих от края сдвигает карту, герои из запаса видны; палец в нижней полосе тащит карту; роза в центре закрывает. Замер A9.

## Срез 10: владелец переместился

~200 строк.

**Files:** Modify: `riddle/mapjob.lua`, `riddle_mapview.lua` (сдвиг центра на открытии, подмена местности по готовности). Test: `tests/mapjob_spec.lua`, `tests/async_answer_spec.lua`.

**Interfaces — Produces:** на открытии — сохранённые местность и точка сразу (без ожидания сети), задание `"map"` в фоне; пришла точка ближе экрана → карта сдвигается на разницу; дальше → новая местность подменяет старую после записи файла (перерисовка `full`); лог `riddle: map moved near|far`.

- [ ] **Шаг 1: тесты (падают).** `test_open_draws_cached_before_job`; `test_near_move_shifts_same_terrain`; `test_far_move_fetches_and_swaps`; `test_far_move_offline_keeps_old`; `test_close_during_fetch_drops_result_keeps_file`.
- [ ] **Шаг 2:** FAIL. **Шаг 3:** реализация. **Шаг 4:** PASS. **Шаг 5: коммит** `feat(map): карта идёт за владельцем — сдвиг рядом, новая местность далеко (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** в другом месте с Wi‑Fi (или подменой `map/point.json` — пишет тестер) — новая местность; дома после отказа BeaconDB (сеть без Wi‑Fi-точки) — та же домашняя карта.

## Срезы 11–13 (владелец 2026-11-16, спека — «Добавлено 2026-11-16»)

Строки кода — на срезе 10 (клон w3, `5dbdc33`) для `riddle_mapview.lua` (дальше — MV), `riddle_diarywidget.lua` (W),
`tests/mapview_spec.lua`, `tests/async_answer_spec.lua`; остальное — `dbbc539`.

**Факты (проверены чтением кода):**
- Зоны касаний — одна чистая функция `MapView.zone(x, y, w, h, cfg)` (MV:724-729): `pad` при `y >= h - map_pad_px`,
  иначе `edge` при `x < e or x >= w - e or y < e or y >= h - e`, `e = map_edge_px`. Зовёт её только `dragStart`
  (MV:805). CFG: `map_edge_px = 83`, `map_pad_px = 167` (W:139-140). Тест зон — `test_zone_edges_and_pad`
  (`tests/mapview_spec.lua:527`, `ZONES` на :525; `z(83, H/2) == nil`), числа CFG — `async_answer_spec.lua:2530`.
- Герои ставятся один раз на местность: `MapView:heroes()` (MV:310-322) — `cast.place(self.data.cast, t, now,
  self.seed or 1, screen)`, состояние `self.cast_state = { heroes, trail }`, ключ `self.cast_for = t` (таблица
  местности). Шаг — `cast.step({ heroes, screen, trail, tick }, terrain, dt) -> state, moved` (`riddle/cast.lua:375`,
  `tick` растёт на :376); MV:696 передаёт `tick`. Координаты героев и следов — пиксели поля.
- Местность читается заново на каждое открытие: `MapView.new` → `readTerrain(diary)` (MV:106-108) — новая таблица;
  «та же местность» — `sameTerrain(a, b)` (MV:490-494: центр, w, h, m_per_px, число улиц и зданий), сейчас local.
- Открытие: `Diary:openMap` (W:1711-1723) — `Diary.map_opens` в таблице модуля (живёт до перезапуска KOReader),
  `MapView.new(self, data, point, Diary.map_opens)`. Закрытие: `Diary:closeMap(why)` (W:1752-1766) — `view:close()`
  для любого `why`, включая `sleep`/`exit`. Часы героев — `Diary.map_clock = os.date("*t")` (W:400), тесты его
  подменяют (`async_answer_spec.lua:1709`).
- Точка владельца на экране: `MapView:anchor()` (MV:746-751) — точка, если местность её покрывает
  (`terrain.covers`), иначе центр местности; книга рисуется только в первом случае. Пиксель точки на поле —
  `terrain.offset(t, point)` + `t.w/2, t.h/2` (как `origin`, MV:114-117).
- Раскладка: подписи мест — `MapView:labels(ways)` (MV:241-263), занятые прямоугольники `out[k].edges`, проверка
  `layout.near(edges, o.edges, LABEL_GAP)`; следы героев уходят из-под подписей в `foot()` (MV:343-354), имя героя
  пропускается у подписи или чужих следов (MV:374-393); шаг перерисовывает прямоугольник `repaintRect` (MV:663-685) —
  линии, подписи, `drawInk`, страница; тест «шаги = полная перерисовка» — `test_review_steps_equal_full_repaint`
  (`mapview_spec.lua:1259`).
- Имя владельца: структурного поля нет. Есть только свободный текст: промпт сводки сессии «Сохрани, как пишущий
  называет себя сам, если называет» (`riddle/prompt.lua:766-779`), промпт свёртки (`prompt.lua:796-807`), голова
  истории «Опирайся на сказанное: имя того, кто пишет» (`prompt.lua:259`); хранятся `sessions.summary`
  (`riddle/memory.lua:12-13`) и `rollups.text` (миграция 4, `memory.lua:44`). Ключа имени в ответе нет:
  `llm.parse` читает `read, reply, task, tasks_source, picks, who, world, lang, yes, map` (`riddle/llm.lua:278-280`);
  `who` — чей дневник, не владелец (`prompt.lua:341`). `lore` под имя не годится: `import_lore` стирает строки
  персоны (`DELETE FROM lore WHERE …`, `memory.lua:534`). Схема — `SCHEMA_VERSION = 6` (`memory.lua:41`).
- Свои ширина и высота экрана в тестах — 758 × 1024 (`mapview_spec.lua:127`). Начала штрихов фикстур роз
  (`tests/fixtures/rose_strokes.lua`, прогон по всем): x 79–599, y 221–760; `rose_tilted_30` начинает штрих на
  x = 599.

### Срез 11: края шире

~80 строк.

**Files:** Modify: `riddle_mapview.lua` (`MapView.zone`), `riddle_diarywidget.lua` (CFG). Test: `tests/mapview_spec.lua`,
`tests/async_answer_spec.lua`.

**Interfaces — Produces:**
- `CFG.map_edge_extra = 0.10` — доля экрана, на которую шире полосы края: слева и справа — от ширины, сверху — от
  высоты (одно место; владелец 2026-11-16: «на 10% (от размера экрана)»).
- `MapView.zone(x, y, w, h, cfg)` — та же сигнатура; `side = cfg.map_edge_px + round(cfg.map_edge_extra * w)`,
  `top = cfg.map_edge_px + round(cfg.map_edge_extra * h)`; низ — как был: `pad` первым, полоса `map_edge_px` над ним
  (её перекрывает `pad`). При 758 × 1024: бока 159 px, верх 185 px, середина для чернил x 159–598, y 185–856.

- [ ] **Шаг 1: тесты (падают).** `mapview_spec`: `ZONES` получает `map_edge_extra = 0` — `test_zone_edges_and_pad`
  проверяет прежнюю геометрию без правок чисел; новый `test_zone_wider_sides_and_top` (`map_edge_extra = 0.10`,
  W × H = 758 × 1024): `z(158, H/2) == "edge"`, `z(159, H/2) == nil`, `z(W - 159, H/2) == "edge"`,
  `z(W - 160, H/2) == nil`, `z(W/2, 184) == "edge"`, `z(W/2, 185) == nil`, `z(W/2, H - 167) == "pad"`,
  `z(W/2, H - 168) == nil` (низ не изменился), `z(0, 0) == "edge"`; `test_zone_scales_with_screen` (W × H = 1072 × 1448:
  бока 83 + 107, верх 83 + 145). `async_answer_spec` рядом с :2530: `t.eq(Diary.CFG.map_edge_extra, 0.10)`.
- [ ] **Шаг 2:** `tests/run.sh` — FAIL на новых.
- [ ] **Шаг 3: реализация** — две строки в `zone`, ключ CFG рядом с `map_edge_px` (W:139) с комментарием-цитатой.
- [ ] **Шаг 4:** `tests/run.sh` — PASS, в т.ч. `test_short_cross_in_middle_is_ink`, `test_corner_exit_still_works_on_map`.
- [ ] **Шаг 5: коммит** `feat(map): полосы сдвига шире — +10% экрана слева, справа и сверху (владелец 2026-11-16) (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** штрих, начатый в 1,5 см от левого/правого края и в 2 см от верхнего, двигает карту; роза в
  середине экрана закрывает карту (5 раз подряд); лог `riddle: map pan edge`.

### Срез 12: те же герои 15 минут

~200 строк.

**Files:** Modify: `riddle_mapview.lua` (`MapView.new`, `heroes`, `sameTerrain` → `MapView.sameTerrain`),
`riddle_diarywidget.lua` (CFG, `openMap`, `closeMap`). Test: `tests/mapview_spec.lua`, `tests/async_answer_spec.lua`.

**Interfaces — Produces:**
- `CFG.map_keep_s = 900` — сколько после закрытия карта помнит героев (владелец: «хотябы на 10-15 мин»).
- `MapView.sameTerrain(a, b) -> bool` — нынешняя local MV:490, открыта модулю (одно правило «та же местность» для
  `setPoint` и памяти героев).
- `MapView.new(diary, data, point, seed, kept)` — `kept = { terrain, state, at } | nil`; `MapView:kept() -> { terrain,
  state } | nil` (только если `self.cast_for == self.terrain` и `cast_state` есть).
- `MapView:heroes()`: если героев ещё нет, `kept` дан, `MapView.sameTerrain(kept.terrain, self.terrain)` и все имена
  `kept.state.heroes` есть в `self.data.cast` — `self.cast_for, self.cast_state = self.terrain, kept.state` (места,
  следы, `tick` — как были), лог `riddle: map cast kept n=N visible=V`; иначе — `cast.place` как сейчас.
- `Diary.map_kept` — в таблице модуля (как `Diary.map_opens`), единственный писатель — `Diary:closeMap` при любом
  `why`: `view:kept()` + `at = os.time(Diary.map_clock())`; `nil`, если `view:kept()` nil. `Diary:openMap` передаёт
  его в `MapView.new`, только если `0 <= now - at < CFG.map_keep_s` (`now = os.time(Diary.map_clock())`), иначе — `nil`.

- [ ] **Шаг 1: тесты (падают).** `mapview_spec`: `test_kept_heroes_same_terrain` (вид A ставит героев, сделал 3 шага;
  `kept = A:kept()`; вид B с той же местностью, прочитанной заново (новая таблица), и `kept` → `B:heroes()` —
  те же имена, `x, y`, `trail`, `tick`; `cast.place` не зван — подмена-счётчик); `test_kept_ignored_other_terrain`
  (другой центр → расстановка заново); `test_kept_ignored_when_cast_changed` (в `data.cast` нет одного из имён →
  заново); `test_kept_nil_before_heroes` (карта «blind» → `kept()` nil). `async_answer_spec` (часы — подмена
  `map_clock`): `test_reopen_within_keep_same_heroes` (открыл, 2 шага, `closeMap("rose")`, +14 мин, открыл → те же
  места и следы, шаги идут дальше от того же `tick`); `test_reopen_after_keep_places_anew` (+16 мин → `cast.place`
  зван); `test_sleep_close_keeps_heroes` (`closeMap("sleep")`, +5 мин → те же); `test_clock_back_places_anew`
  (часы назад на 1 ч → заново); `test_far_move_then_close_keeps_new_terrain` (`setPoint` far → закрыл → открыл на
  новой местности → герои новой местности). `t.eq(Diary.CFG.map_keep_s, 900)`.
- [ ] **Шаг 2:** FAIL. **Шаг 3: реализация.** **Шаг 4:** PASS (в т.ч. `test_same_terrain_keeps_heroes` :979,
  `test_map_opens_number_the_cast_rotation` :1701 — ротация после 15 мин прежняя).
- [ ] **Шаг 5: коммит** `feat(map): те же герои на тех же местах, если карту открыли снова в течение 15 минут (владелец 2026-11-16) (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** открыл, запомнил героев (`testShot`), закрыл розой, через 5 мин открыл — те же имена на тех
  же местах, следы продолжаются; через 16 мин — другая расстановка. Лог `riddle: map cast kept n=N visible=V` /
  `riddle: map cast n=N visible=V hour=H`.

### Срез 13: книга с именем владельца

Два куска: 13а — книга и имя по готовому интерфейсу (уровень 1, идёт сразу); 13б — откуда имя (уровень 2, после
выбора оркестратора). До 13б `owner` всегда `nil` — книга без имени, как велит решение 3 для неизвестного имени.

#### 13а: книга и имя на карте

~250 строк.

**Files:** Modify: `riddle_mapview.lua` (книга, имя, раскладка, `repaintRect`), `riddle/mapdata.lua`
(`of(view, row, parts, owner)`), `riddle/controller.lua` (`Controller:map` передаёт имя). Test: `tests/mapview_spec.lua`,
`tests/whose_spec.lua`.

**Interfaces — Produces:**
- `mapdata.of(view, row, parts, owner) -> { …, owner = string | nil }` — `owner` обрезан `str.trim`, пустой → nil,
  длиннее `mapdata.NAME_MAX = 30` (`mapdata.lua:33`) → nil. `Controller:map()` (`controller.lua:326-333`) зовёт
  `mapdata.of(view, row, parts, self:owner_name())`; `Controller:owner_name() -> string | nil` — в 13а возвращает nil
  (источник — 13б), сбой чтения → nil и лог `riddle: owner name failed`.
- `MapView:ownerMark() -> { book = { x0, y0, x1, y1 }, name = { text, rect = { x, y, w, h }, edges } | nil } | nil` —
  nil без ink box или если `MapView:anchor()` — не точка владельца (точки нет или местность её не покрывает) или
  книга вне ink box. Книга — открытая книга линиями `riddle_ink.line` (две страницы и корешок), `MapView.BOOK = 12`
  px от точки владельца (полуширина), по центру пикселя точки на экране (с учётом сдвига пальцем). Имя — под книгой
  (`answer_px/2`, `labelOpts` как у героев), у нижнего края — над книгой, шире ink box — без имени.
- Раскладка: `ownerMark` строится первым; его прямоугольники (книга, имя с `layout.text_reach(LABEL_HALO)`) —
  занятые для `labels` (подпись места пропускается при `layout.near(…, LABEL_GAP)`) и для героев (как подписи в
  `foot()` и при пропуске имени героя). `self.drawn.owner` хранит метку; `repaintRect` рисует её, если она задевает
  прямоугольник.
- Лог при отрисовке: `riddle: map owner book=0|1 name=0|1` — без имени и координат.

- [ ] **Шаг 1: тесты (падают).** `mapview_spec`: `test_book_at_owner_point` (точка покрыта — чернила книги в
  прямоугольнике центра экрана, `ownerMark().book` вокруг пикселя точки); `test_no_book_when_point_off_terrain`
  (точка вне поля — `ownerMark() == nil`, центр экрана без чернил книги); `test_book_moves_with_pan` (`pan(50, 0)` —
  книга на 50 px левее); `test_owner_name_under_book` (`data.owner = "Гермиона"` — текст в прямоугольнике под
  книгой); `test_no_name_book_only` (`owner = nil` — книга есть, имени нет); `test_label_skips_owner_mark` (здание
  с подписью в центре — подпись пропущена, `labels()` не пересекает книгу и имя); `test_hero_off_owner_mark`
  (герой в точке владельца — следы не на книге, имя героя не на имени владельца); `test_steps_keep_owner_mark`
  (вариант `test_review_steps_equal_full_repaint` с книгой и именем: после шагов холст = полной перерисовке);
  `test_owner_log_no_name` (лог `riddle: map owner book=1 name=1`, имени и цифр координат в логе нет).
  `whose_spec`: `test_mapdata_owner_trimmed_and_capped` (`" Гарри "` → `"Гарри"`, `""` и 31 знак → nil).
- [ ] **Шаг 2:** FAIL. **Шаг 3: реализация.** **Шаг 4:** PASS.
- [ ] **Шаг 5: коммит** `feat(map): книга владельца в его точке и имя рядом — не под подписями и героями (владелец 2026-11-16) (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** книга в центре при открытии; сдвиг пальцем уносит её с полем; подписи и следы её не
  перекрывают; лог `riddle: map owner book=1 name=0`.

#### 13б: откуда имя (уровень 2 — новый столбец БД; выбор за оркестратором)

Общее для обоих вариантов: миграция 7 — `ALTER TABLE personas ADD COLUMN owner_name TEXT` (имя — на персону: под
другим дневником владелец может назваться иначе); `Memory:owner_name(persona_id) -> string | nil`,
`Memory:set_owner_name(persona_id, name)`; `Controller:owner_name()` читает его для текущей персоны. Пустое или
длиннее `mapdata.NAME_MAX` не пишется. Повтор безопасен: та же запись — то же значение.

- **Вариант А (рекомендую): ключ `"name"` в ответе.** `prompt.NAME_FORMAT` по образцу `TASK_FORMAT` (`prompt.lua:180`):
  `"name"` — как пишущий называет себя в этой записи, если называет, иначе `""`; в пример открытой печати.
  `llm.parse` — `name = opt_text(obj.name)` рядом с `who` (`llm.lua:279`); контроллер после ответа пишет непустое
  `name`. Цена: ~200 строк; новых вызовов LLM нет; +~40 токенов формата в каждом ответе; меняются снимки промпта
  «Методов» (как при блоке `map`, решение 1 спеки) — нужно «да» на это; слабые модели пропускают условные ключи
  (комментарий ANSWER_FORMAT, `prompt.lua:20-22`) — имя может не поймать. Имя на карте — сразу после страницы, где
  владелец представился.
- **Вариант Б: отдельный короткий вызов после сводки сессии.** Тот же фон, что сводка (`prompt.summarize`,
  `prompt.lua:766-779`): `prompt.owner_name(summaries) -> messages`, ответ `{"name":"…"}`. Цена: ~220 строк; +1 вызов LLM
  на сессию (~300 токенов входа); промпт ответа и снимки не меняются; имя появляется только после конца сессии
  (сводки), в той же сессии на карте его ещё нет. ASSUMPTION Б1: задание сводки может нести второй вызов в том же
  слоте раннера — не проверено, проверить до кода (controller, где зовётся `prompt.summarize`).
- Отвергнуто: строка в `lore` (стирается `import_lore`, `memory.lua:534`); поиск «меня зовут …» регуляркой по
  `entries.text` (текст — чтение почерка моделью, формы представления разные — ложные и пропущенные имена).

- [ ] **Шаг 1: тесты (падают)** — по выбранному варианту: `memory_spec` `test_migration_7_owner_name` (старая база
  v6 → столбец есть, значения nil), `test_owner_name_per_persona`; А — `llm_spec` `test_parse_name_optional`
  (`"Гарри"` → как есть, `""`/нет ключа → nil), `prompt_spec` `test_name_format_in_open_seal`, `whose_spec`
  `test_answer_with_name_saves_owner_name` (и `test_setup_mode_ignores_name`); Б — `whose_spec`
  `test_summary_then_owner_name_saved`, `test_owner_name_call_offline_skipped`. Общий: `whose_spec`
  `test_map_has_owner_name` (`ctl:map().owner`).
- [ ] **Шаг 2:** FAIL. **Шаг 3: реализация.** **Шаг 4:** PASS.
- [ ] **Шаг 5: коммит** `feat(map): дневник помнит, как назвался владелец, — имя у книги на карте (Notion 40a13e60-bc8d-8163)`.
- [ ] **Шаг 6 (тестер):** на чистой персоне написать «Меня зовут <имя>» → (А: сразу; Б: после конца сессии) роза →
  имя у книги; копия базы: `SELECT owner_name FROM personas` — имя у текущей персоны. Лог без имени.

### Review Focus срезов 11–13

1. Роза, начатая у правого края (x ≥ 599 при 758: фикстура `rose_tilted_30` начинает штрих на 599), — теперь сдвиг,
   а не чернила: срез 11 `test_zone_wider_sides_and_top` фиксирует границу; тестер — розу «как пишет владелец» 5 раз.
2. Часы назад (перевод, синхронизация) между закрытием и открытием → расстановка заново, не «вечные» герои —
   `test_clock_back_places_anew` (12).
3. Персона сменилась за 15 минут → чужие герои не остаются — `test_kept_ignored_when_cast_changed` (12).
4. Шаг героя рядом с книгой не стирает книгу и имя — `test_steps_keep_owner_mark` (13а).
5. Имя владельца в логе — ни в каком виде — `test_owner_log_no_name` (13а); в 13б лог миграции и записи — без значения.

## Потом (не влезло)

- Подгрузка местности заранее, фоном при открытии дневника (первое открытие без ожидания).
- Несколько местностей в кэше (дом, работа, аэропорт).
- Сезон в рисунке (снег, листья), погода.
- Пересоздание данных карты «Методов» (`forget_persona` для `map*`) — если оркестратор не возьмёт в срез 2.
- Смещение часового пояса из конфига — если A6 провалится.

## Самопроверка плана

- Спека, раздел 1: открытие роза/фраза — 1, 3; мир Поттера и канон — 2; закрытие — 1, 3; центр — 4; сдвиг меньше экрана — 10; масштаб и поле — 5; OSM и атрибуция — 5; подписи — 2, 6.
- Раздел 2: состав и ротация — 2, 7; 2–6 и запас — 7; следы с именем — 7; логика времени — 7; LLM только при генерации — 2; дом героя — 7; шаг 2–3 с — 8; сдвиг пальцем — 9; автозакрытие — 1.
- Раздел 3: весь экран — 1; тушь и подписи — 5, 6; проявление — 6; закрытие → страница — 1; другие вселенные — 2; хранение местности — 5; без интернета — 4, 10.
- Решения оркестратора 1–5: 1 — срез 2; 2 — 1, 3, 9; 3 — 1, 3; 4 — 1; 5 — 4.
- Добавлено 2026-11-16: решение 1 (края) — 11; решение 2 (те же герои 15 мин) — 12; решение 3 (книга, имя, раскладка,
  имя не в лог) — 13а; источник имени — 13б (уровень 2).
- Анти-цели: время построения — A5, A7; батарея — 1 (автозакрытие), 8 (A12); нелогичные места — 7; падение без сети/гео/данных — Review Focus 4, срезы 2, 4; «навигационный вид» — 5, 6 (тушь, подписи вселенной, без значков).
