# Значки Wi‑Fi, батареи и времени в углу дневника — план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** в правом нижнем углу обычной страницы дневника всегда видны (слева направо) дуги Wi‑Fi (только на связи) · батарея с заливкой и `87%` · время `21:40`; раз в минуту перерисовывается только этот прямоугольник.

**Architecture:** чистый модуль `riddle/tray.lua` считает факты (время, заряд, связь) из внедрённых источников и геометрию значков (прямоугольники и ломаные в пикселях). Виджет держит угол слоем `self.tray.layer` (как приглашение и ответ): `paintRegion` кладёт его под штрихи, тик раз в минуту — задача `Diary:schedule`, перерисовка — `renderRegion` прямоугольника угла (DU, частично). Слой и тик живут только на странице дневника: `resetPage` (сон, карта, состояние) их снимает, `init`/`onResume`/`backToDiary` показывают заново.

**Tech Stack:** Lua (LuaJIT), KOReader-плагин, тесты `tests/run.sh` (luajit на Mac).

**Spec:** `docs/superpowers/specs/2026-11-19-corner-icons-design.md`

## Global Constraints

- Место — правый нижний угол обычной страницы дневника, всегда (спека:17–19, владелец: «тогда давай в нижнем правом углу»).
- Справа налево: время `21:40` · батарея с процентами `87%` · дуги Wi‑Fi только при связи (спека:20–22).
- Мельче статус-бара KOReader (спека:20).
- Линиями на холсте BB8, без шрифтов и картинок KOReader; цифры — `fonts/MarckScript-Regular.ttf` (спека:26–33).
- Батарея: рамка с выступом, заливка пропорциональна заряду; при зарядке — молния внутри. Wi‑Fi: три дуги (спека:29–32).
- Раз в минуту — только прямоугольник угла, частичное обновление e‑ink; перо на экране — после штриха; сон — таймер не идёт, пробуждение — угол заново (спека:37–41).
- Заряд — `Device:getPowerDevice():getCapacity()/isCharging()`, не чаще раза за перерисовку; Wi‑Fi — `net.state`; время — `os.date` (спека:42–43).
- Страница состояния: строка «Батарея» уходит, Wi‑Fi остаётся (спека:47–49).
- Не на карте и не на странице состояния; без настройки «скрыть» (спека:53–54).
- Зона выхода `CFG.corner` — правый ВЕРХНИЙ угол (`riddle_diarywidget.lua:128`, `:998`), значки её не касаются.

## Факты (ответы на вопросы брифа, с источниками)

### 1. Куда встаёт отрисовка и как попадает на экран

- Экран — один холст BB8 `self.canvas` (`riddle_diarywidget.lua:410`), `paintTo` целиком блитит его (`:662-664`).
- Любой прямоугольник холста собирается заново из слоёв: белое → приглашение → ответ → штрихи (`paintRegion`, `:815-831`); «ink always wins» (`:18-19`). Растворение штрихов и шаги ответа идут через `renderRegion` (`:834-837`, `:1181`, `:1482`), поэтому значок, нарисованный прямо в холст, стёрся бы первым же растворением штриха над ним. **Решение:** угол — слой `self.tray.layer` (`newLayer`, `:298-302`), `paintRegion` кладёт его без маски после ответа и до штрихов.
- `renderRegion` = `paintRegion` + `push(…, CFG.dissolve.wf)`; `wf = "DU"` (`:100`). `push` на Kindle — прямой `mech_refresh` частичный DU только этого прямоугольника, без очереди UIManager (`:798-810`, `:67-72`); вне Kindle — `setDirty` того же прямоугольника. Тик угла = `renderRegion(прямоугольник угла)`.
- Показ без push: первая отрисовка `init` — полное обновление (`:416`), `onResume` ставит `setDirty(self,"full")` следующим тиком (`:722-724`), `backToDiary` делает `push(0,0,w,h,"full")` (`:1814`). Значит при показе угол только кладётся в холст, push не нужен.

### 2. Таймер раз в минуту, сон, перо

- `Diary:schedule` (`:778-787`) регистрирует задачу в `self.tasks`, выполняет только при живом холсте; `onCloseWidget` снимает все (`:672`), `resetPage` снимает все (`:746`). Тик угла — обычная `self:schedule`, отдельного механизма нет.
- `resetPage` зовут: сон `onSuspend` (`:705`), пробуждение без ответа (`:719`), `openMap` (`:1750`), `backToDiary` (`:1813`), `openStatus` (`:1869`). **Решение:** `resetPage` освобождает слой угла и забывает тик (`self.tray.layer/rect/task = nil`); показ — `trayShow(why)` в трёх местах: `init` (после `showInvitation`, `:416`), `onResume` (обе ветки, до `nextTick`, `:715-724`), `backToDiary` (до `push full`, `:1814`). Карта и состояние зовут `resetPage` → угла там нет без отдельных проверок.
- Сон: `onSuspend` → `resetPage` снимает тик до сна; просроченная задача не выстрелит при пробуждении. Пробуждение: `trayShow("resume")` читает факты заново и ставит тик.
- Выравнивание по минуте: следующий тик через `60 - tm.sec` с (`os.date("*t")`); срабатывает в `(mm+1):00.f`, после смены минуты. Время — местное: `os.date("*t")` на Kindle даёт местное время владельца (`docs/superpowers/plans/2026-11-06-marauders-map.md:171`, A6). Часы виджета — уже есть `self.map_clock` (`:401`, по умолчанию `os.date("*t")`, тесты его подменяют) — угол читает его же, второго источника времени нет.
- Перо: `self.cur` есть от `penDown` (`:1025`) до `inkUp` (`:1130-1131`). Тик при `self.cur ~= nil` переставляет себя через `CFG.sink_tick_s` (0,1 с, `:104`) — тот же приём, что у приглашения и ответа рядом с пером (`:883-885`, `:1506-1508`); рисует после отрыва ≤ 0,1 с. Затем следующий тик — снова по `next_tick_s`.
- Заряд: `getCapacity` кэширует аппаратное значение 60 с, `isCharging` — lipc каждый раз (`docs/superpowers/plans/2026-11-19-status-triangle.md:54`, L1). Факты читаются один раз на перерисовку (тик или показ) — не чаще раза в минуту плюс показы.
- Wi‑Fi: `net.state()` (`riddle/net.lua:13-28`): `"up"` — значок есть, `"down"`/`"off"` — нет. NetworkMgr недоступен → `"up"` (`net.lua:11-12`, `:15`): на Kindle он есть, вне устройства значок рисуется — принимаем, это правило `net` для всего плагина.

### 3. Доходит ли текст до правого нижнего угла

- Да. Ответ раскладывается от `x = CFG.margin` (44, `:132`) шириной `w - 2·margin` (`:1494`), то есть строки доходят до `x = w - 44`. Верх ответа — верх туши страницы минус 10 (`:1247`); проверка только `rect.y + rect.h > self.h` (`:1495`), rect включает +8 снизу (`:216-217`). Страница, написанная внизу, даёт ответ, чьи последние строки стоят в нижних ~30 px справа — там, где угол. Раздумья, отказы, вставки идут тем же `revealAnswer` (`:1441-1444`).
- Приглашение — строки 2–5 сверху (`:858-862`), страница состояния — без угла. Других текстов на странице дневника нет.
- **Решение:** полоса во всю ширину внизу высотой `CFG.tray.band`: проверка `:1495` становится `> self.h - CFG.tray.band`; не влезло — как сейчас, раскладка от `textFloor() + 10` (`:1496`). Полную ширину выбираем вместо укорачивания отдельных строк: одно условие вместо второй раскладки, теряем ≤ 44 px из 1024 только у ответов, начатых у самого низа. Перо полосу не резервирует: тушь поверх угла допустима, после растворения слой угла собирается снова (`paintRegion`).
- Остаток вне задачи: раскладка от `textFloor()+10` сама не проверяется на переполнение (`:1496`) — было и до угла; очень длинный ответ может заехать на угол. Не чиним здесь (см. «Открытые вопросы»).

### 4. Карта, страница состояния, строка «Батарея», тесты

- Карта и состояние: `resetPage` снимает слой и тик (п. 2) — значков нет; закрытие → `backToDiary` → `trayShow("back")`. Карта рисует в `self.diary.canvas` сама (`riddle_mapview.lua:344`, `:382`, `:561`, `:999`), слой угла туда не попадает, потому что его нет.
- `status.lua`: строка `r[1] = "Батарея: …"` (`riddle/status.lua:145`) уходит, остальные сдвигаются вверх на 1; `status.MODEL_ROW` 9 → 8 (`:14`). Поломка в шапке «Батарея 14%» (`:118-120`) остаётся: это перечень сломанного, а не показ заряда (см. «Открытые вопросы»). `status.collect` по-прежнему читает `power` (для шапки).
- Ломаются (и правятся в срезе 3): `tests/status_spec.lua:165` (`88%` в строках), `:196`, `:201` (`rows[8]` — синхронизация станет `rows[7]`), `:221` («заряжается» в строках); `tests/status_page_spec.lua:231`, `:411`, `:438` (строка «Батарея: …» на странице).
- Ломается (и правится в срезе 2): `tests/async_answer_spec.lua:807-827` — единственный тест, зовущий настоящий `Diary.init` (`:814`); его холст и слои — заглушка `bb_stub` без пикселей, `paintRect` и `getWidth` (`:14-15`): рисование угла упадёт. Стенд уже глушит `showInvitation` (`:813`) — рядом добавляется `d.trayShow = nop`.
- Не ломаются: проверки «таймеров не осталось» `async_answer_spec.lua:743` (после `onCloseWidget`), `ponder_spec.lua:535`, `:561` (после `onSuspend`) — стенды без `init` не заводят `self.tray`, а у настоящего виджета тик снимается тем же `resetPage`/`onCloseWidget`.
- Стенды без `init` (спеки собирают виджет через `setmetatable`, например `status_page_spec.lua:135-144`) не имеют `self.tray`: `trayShow`/`trayTick` при `self.tray == nil` ничего не делают. Это граница владения: угол заводит только `init`.

### 5. Проверка на устройстве, строки лога

- Всегда (редкие события): `riddle: tray show <why> <факты> rect=x,y,w,h` — `why` ∈ `open|resume|back`; `riddle: tray tick after pen <N> ms <факты>` — только если тик ждал перо; `riddle: tray wifi on|off`, `riddle: tray charging on|off` — только при смене между перерисовками.
- Только devmode (`Diary.devmode`, `:2040-2046`; ставится `tools/deploy.sh --dev`, `tools/deploy.sh:3-7`, `:25`): каждый тик `riddle: tray tick <факты>`.
- Почему так: `crash.log` один на всё; строка в минуту у владельца — 60 строк в час открытого дневника без пользы. Тестеру нужны тики — он деплоит с `--dev`. Ожидание пера, смена связи/зарядки и показы — редкие и именно то, что спека требует проверить.
- `<факты>` — `tray.describe(f)`: `21:40 87% wifi`, `21:40 87%+ nowifi` (`+` — заряжается), `—:— —% nowifi` при упавших источниках.

## Review Focus

1. Источник упал (powerd нет, `os.date` странный, NetworkMgr бросает) — угол рисуется без этой части, дневник не падает. Тест: `tray_spec` `test_facts_failing_sources`.
2. Ширина угла меняется (`9:05` → `10:00`, `100%` → `99%`, Wi‑Fi пропал) — старые пиксели не остаются: перерисовывается объединение старого и нового прямоугольников. Тест: `tray_widget_spec` `test_tick_repaints_union_when_wifi_drops`.
3. Сон посреди ожидания пера / тик перед самым сном — после пробуждения ровно один тик в очереди. Тест: `tray_widget_spec` `test_suspend_drops_tick_resume_reshows`.
4. Тушь поверх угла растворилась — угол цел. Тест: `tray_widget_spec` `test_stroke_over_tray_dissolves_back_to_icons`.
5. Ответ у самого низа не заезжает на угол. Тест: `tray_widget_spec` `test_answer_near_bottom_keeps_band_free`.

---

### Task 1: чистый модуль `riddle/tray.lua` — факты, тик, геометрия

**Files:**
- Create: `plugin/riddlediary.koplugin/riddle/tray.lua`
- Test: `tests/tray_spec.lua`

**Interfaces:**
- Produces:
  - `tray.facts(src) -> f`: `src.clock() -> {hour, min, sec}`, `src.power() -> {pct, charging}`, `src.net() -> "up"|"down"|"off"`; каждый в `pcall`, неверный тип = упал. `f = { hm = "21:40"|nil, sec = 0..59|nil, pct = 0..100|nil, charging = bool, wifi = bool }`. `hm` — `string.format("%d:%02d", hour, min)`; `pct` — число, обрезанное в 0..100, округлённое.
  - `tray.next_tick_s(f) -> s`: `60 - f.sec`, без `sec` — 60; всегда в [1, 60].
  - `tray.describe(f) -> string`: `"21:40 87% wifi"`, `"21:40 87%+ nowifi"`, `"—:— —% nowifi"`.
  - `tray.layout(f, at, measure, M) -> L`: `at = { right, base, asc }` — правый край, базовая линия (низ значков и цифр), асцендер шрифта цифр; `measure(s) -> ширина`; `M` — метрики `CFG.tray` (ниже). `L = { rect = {x,y,w,h}, texts = { {s=, x=} … }, rects = { {x,y,w,h} … } (рамка, выступ, заливка), polys = { {x1,y1,x2,y2,…} … } (дуги, точка Wi‑Fi), bolt = poly|nil, fill_x1 = x|nil }`. Справа налево: `hm` у `right`, `gap`, `"87%"`, `gap`, батарея, `gap`, Wi‑Fi (если `wifi`). Нет `hm` — нет текста времени; нет `pct` — рамка без заливки и без процентов. `rect` охватывает всё + 2 px.
  - `tray.union(a, b) -> rect` (любой nil — другой).
- Метрики `M` (значения ставит Task 2 в `CFG.tray`): `px` (кегль цифр), `pad_r`, `pad_b`, `gap`, `icon_h`, `batt_w`, `nub_w`, `nub_h`, `line` (толщина рамки), `wifi_r = {r1, r2, r3}`, `band`.

- [ ] **Step 1: тесты** `tests/tray_spec.lua` (стиль `tests/status_spec.lua`, `require("t")`):
  - `test_facts_reads_sources`: clock `{hour=21,min=4,sec=17}`, power `{pct=87.4,charging=true}`, net `"up"` → `hm=="21:04"`, `sec==17`, `pct==87`, `charging==true`, `wifi==true`.
  - `test_facts_failing_sources`: все три бросают → `hm==nil`, `pct==nil`, `charging==false`, `wifi==false`; power `"88"` (строка) → `pct==nil`; net `"down"` и `"off"` → `wifi==false`; pct `130` → 100, `-5` → 0.
  - `test_next_tick_aligns_to_minute`: sec 0 → 60, 17 → 43, 59 → 1, sec nil → 60.
  - `test_describe`: три строки из Interfaces дословно.
  - `test_layout_order_right_to_left`: `measure = function(s) return #s * 10 end`, `at = {right=744, base=1014, asc=16}` → `texts[1].s == "21:40"`, `texts[1].x + 50 == 744`; `texts[2].s == "87%"` и `texts[2].x + 30 + M.gap == texts[1].x`; рамка батареи правее всех дуг Wi‑Fi (`max x` дуг < `x` рамки); `rect.x + rect.w >= 744`, `rect.y + rect.h <= 1014 + 3`.
  - `test_layout_fill_proportional`: внутренняя ширина `iw = batt_w - 2·line`; pct 50 → `fill` шириной `math.floor(iw * 50 / 100 + 0.5)`; pct 0 → заливки нет; pct 100 → `iw`.
  - `test_layout_no_wifi_no_arcs`: `wifi=false` → `#polys == 0`, `rect.w` меньше, чем при `wifi=true`.
  - `test_layout_charging_has_bolt`: `charging=true` → `bolt` — ломаная из ≥ 3 точек целиком внутри рамки; `charging=false` → `bolt == nil`.
  - `test_layout_missing_parts`: `hm=nil` → нет текста времени; `pct=nil` → нет `"…%"` и нет заливки, рамка есть.
  - `test_union`: `{0,0,10,10}` ∪ `{5,5,10,10}` = `{0,0,15,15}`; `nil ∪ r == r`.
- [ ] **Step 2:** `tests/run.sh` → `tests/tray_spec.lua` падает на `module 'riddle.tray' not found`.
- [ ] **Step 3:** реализовать `riddle/tray.lua` (без KOReader, только Lua). Дуги — точки окружности радиуса `r` от 45° до 135° вокруг нижней середины значка Wi‑Fi с шагом, дающим соседние точки ≤ 2 px; точка — короткая ломаная в центре. Молния — 4–5 точек зигзагом по высоте внутренней области рамки. Заливка — прямоугольник от левого внутреннего края.
- [ ] **Step 4:** `tests/run.sh` → все спеки зелёные.
- [ ] **Step 5: Commit** `feat(tray): факты, тик по минуте и геометрия значков угла — чистый модуль`

### Task 2: угол на странице дневника — слой, показ, тик, сон, перо, карта и состояние

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua` — `CFG` (`:95-151`), `layoutText` (`:190-219`), `init` (`:407-437`), `onResume` (`:712-726`), `resetPage` (`:744-760`), `paintRegion` (`:815-831`), `backToDiary` (`:1811-1817`), `statusSources` (`:1827-1836`); новые методы рядом с приглашением (после `:904`).
- Modify: `tests/async_answer_spec.lua:813` — `d.trayShow = nop` рядом с `d.showInvitation = nop`.
- Test: `tests/tray_widget_spec.lua`

**Interfaces:**
- Consumes: `tray.facts`, `tray.next_tick_s`, `tray.describe`, `tray.layout`, `tray.union` (Task 1).
- Produces:
  - `CFG.tray = { px = 22, pad_r = 14, pad_b = 10, gap = 8, icon_h = 12, batt_w = 22, nub_w = 2, nub_h = 6, line = 2, wifi_r = { 4, 8, 12 }, band = 44 }` — стартовые значения; тестер сверяет с статус-баром KOReader на снимке, правится одна таблица.
  - модульная `local function advance(face, word) -> ww, adv` — вынесенный `word_adv` из `layoutText` (`:196-204`); `layoutText` и угол меряют одной функцией.
  - модульная `local function readPower() -> { pct, charging }` — тело `statusSources.power` (`:1832-1835`); `statusSources.power = readPower`.
  - `Diary:traySources() -> { clock = self.map_clock, power = readPower, net = net.state }` (тесты подменяют).
  - `self.tray` — `{}` из `init`; поля `layer`, `rect`, `facts`, `task`, `wait_t0`. Нет `self.tray` — угла нет (стенды без `init`).
  - `Diary:trayShow(why)` — `why` ∈ `"open"|"resume"|"back"`: факты, слой, в холст через `paintRegion(rect)` без push, лог «tray show», тик через `next_tick_s`.
  - `Diary:trayTick()` — перо (`self.cur`) → перепланировать на `CFG.sink_tick_s`, запомнить `wait_t0`; иначе факты, новый слой, `renderRegion(tray.union(old, new))`, логи п. 5, следующий тик.
  - `Diary:trayDrop()` — освободить слой, снять тик (`self:cancel`), `rect/facts = nil`; зовёт `resetPage` и `onCloseWidget`.
- Рисование слоя: `newLayer(rect)`; `rects` — `layer.bb:paintRect(x - rect.x, …, BLACK)`; `polys` — `ink.polyline(layer.bb, p, BLACK, ink.stamp_small, сдвиг)` (`riddle_ink.lua:15`, `:32`); `bolt` — тем же пером, цвет точки `WHITE` при `x < fill_x1`, иначе `BLACK` (молния видна и на заливке, и на пустом); цифры — `layerDrawGlyph(layer, face, g)` (`:304-309`) по глифам `layoutText(face, s, x, base - asc, большая ширина)`, `face = getFace(CFG.tray.px)` (`:174-185`). Базовая линия `base = self.h - CFG.tray.pad_b`, правый край `self.w - CFG.tray.pad_r`.
- `paintRegion`: после ответа (`:822-823`) — `composite(self.canvas, self.tray.layer, x, y, x1, y1)` без маски, если слой есть; штрихи после него.

- [ ] **Step 1: тесты** `tests/tray_widget_spec.lua`. Стенд — как `tests/async_answer_spec.lua:1-60` (заглушки KOReader, `timeline`, `run(s)`, `LOG`), холст — настоящий буфер W×H (758×1024) с `fill`, `paintRect`, `colorblitFrom`, `getWidth/Height`, `free` (как `ink_bb`, `async_answer_spec.lua:2321-2335`, плюс `paintRect`), `Blitbuffer.new` на время теста отдаёт такие же буферы; `d.tray = {}`; `d.traySources` с управляемыми `TM`, `PW`, `NET`; `d.push` пишет прямоугольники и режимы.
  - `test_show_paints_icons_without_push`: `trayShow("open")` → в прямоугольнике `self.tray.rect` есть чёрные пиксели; `#pushes == 0`; `rect` правее `w/2` и ниже `h - CFG.tray.band`; `rect` не пересекает квадрат выхода `[w - CFG.corner, w) × [0, CFG.corner]`; лог `riddle: tray show open 21:40 87% wifi rect=`.
  - `test_tick_on_minute_repaints_only_corner`: `TM.sec = 50` → через 10 с ровно один push, его прямоугольник ⊆ `[w/2, w) × [h - band, h)`, режим `CFG.dissolve.wf`; следующий через 60 с.
  - `test_tick_repaints_union_when_wifi_drops`: `NET = "down"` перед тиком → push покрывает старый `rect` целиком; в старом месте дуг пикселей нет; лог `riddle: tray wifi off`.
  - `test_tick_waits_for_pen`: `d.cur = {b = {…}}` в момент тика → push нет; через 0,35 с `d.cur = nil` → push в ≤ 0,1 с; лог `riddle: tray tick after pen` с числом мс.
  - `test_suspend_drops_tick_resume_reshows`: `onSuspend` → `self.tray.task == nil`, `self.tray.layer == nil`, `run(600)` — ни одного push угла; `onResume` → слой в холсте, в `timeline` ровно одна задача угла.
  - `test_map_and_status_have_no_icons`: `openStatus("test")` (источники — как `healthy()` в `status_page_spec.lua:111-127`) → `self.tray.layer == nil`, тика нет; касание → `closeStatus("touch")` → слой есть, тик стоит. То же для `openMap`/`closeMap("idle")` (стенд карты — как `map_diary`, `async_answer_spec.lua:1594`).
  - `test_stroke_over_tray_dissolves_back_to_icons`: снимок пикселей угла → штрих через угол (`penDown`/`penMove`/`penUp`) → `run(CFG.sink_delay_s + 2)` → пиксели угла совпадают со снимком.
  - `test_devmode_logs_every_tick_else_silent`: без devmode два тика → 0 строк `riddle: tray tick `; с `d.devmode = true` → 2.
- [ ] **Step 2:** `tests/run.sh` → новая спека падает (`trayShow` nil).
- [ ] **Step 3:** реализовать по Interfaces; `init` — `self.tray = {}` и `trayShow("open")` после `showInvitation(false)`; `onResume` — `trayShow("resume")` в обеих ветках до `nextTick`; `backToDiary` — `trayShow("back")` после `showInvitation(false)`, до `push full`; `resetPage` и `onCloseWidget` — `trayDrop()`. В `tests/async_answer_spec.lua:813` — `d.trayShow = nop`.
- [ ] **Step 4:** `tests/run.sh` → все спеки зелёные (включая `async_answer_spec`, `ponder_spec`, `sleep_reply_spec`, `status_page_spec`).
- [ ] **Step 5: Commit** `feat(tray): значки Wi‑Fi, батареи и времени в правом нижнем углу дневника — тик по минуте, сон, перо`

### Task 3: полоса под углом для ответа; строка «Батарея» уходит со страницы состояния

**Files:**
- Modify: `plugin/riddlediary.koplugin/riddle_diarywidget.lua:1495`
- Modify: `plugin/riddlediary.koplugin/riddle/status.lua:14`, `:142-174`
- Modify: `tests/status_spec.lua:165`, `:196`, `:201`, `:221`; `tests/status_page_spec.lua:231`, `:411`, `:438`
- Modify: `docs/superpowers/specs/2026-11-19-status-triangle-design.md:34` — пометка «батарея — в углу дневника (2026-11-19-corner-icons-design)»
- Test: `tests/tray_widget_spec.lua`, `tests/status_spec.lua`, `tests/status_page_spec.lua`

**Interfaces:**
- Consumes: `CFG.tray.band` (Task 2).
- Produces: `status.MODEL_ROW = 8`; `status.lines(...).rows` без строки «Батарея»; Wi‑Fi — `rows[1]`, синхронизация — `rows[7]`.

- [ ] **Step 1: тесты.**
  - `tray_widget_spec` `test_answer_near_bottom_keeps_band_free`: страница с `ink[2]` так, что ответ из 2 строк кончается между `h - band` и `h` → ответ разложен от `textFloor() + 10`; низ его `rect` ≤ `h - band`. И обратный: ответ, кончающийся выше `h - band`, остаётся у туши.
  - `status_spec`: `:165` → строки не содержат `"Батарея"` и `"88%"`; `:196`, `:201` → `rows[7]`; `:221` → вместо поиска «заряжается» в строках — `t.ok(not joined(charging.rows):find("Батарея", 1, true))`; новый `test_battery_row_gone`: `#l.rows == 8`, `rows[1]` начинается с `"Wi‑Fi: "`.
  - `status_page_spec`: `:231`, `:411`, `:438` → ни одна напечатанная строка не начинается с `"Батарея:"`.
- [ ] **Step 2:** `tests/run.sh` → новые/изменённые утверждения падают.
- [ ] **Step 3:** `:1495` → `if block.rect.y + block.rect.h > self.h - CFG.tray.band then`; `status.lua` — убрать `r[1]` батареи, перенумеровать строки, `MODEL_ROW = 8`, шапку `problems` не трогать; пометка в спеке состояния.
- [ ] **Step 4:** `tests/run.sh` → все спеки зелёные.
- [ ] **Step 5: Commit** `feat(tray): ответ не заезжает на угол; батарея ушла со страницы состояния — она в углу`

### Проверка на устройстве (тестер, после среза 3)

`tools/deploy.sh --dev` (devmode — тики в логе), лог — `tools/kindle_log.sh 400`, снимок экрана — как обычно у тестера.

1. Открыть дневник → `riddle: tray show open … rect=` и значки на снимке справа внизу; сравнить высоту цифр со статус-баром KOReader в книге — угол мельче.
2. Ждать 2 минуты без касаний → две строки `riddle: tray tick`, время на снимке сменилось, остальная страница не мигала.
3. Писать пером через смену минуты → `riddle: tray tick after pen N ms`, N ≈ время до отрыва.
4. Выключить Wi‑Fi → на следующем тике `riddle: tray wifi off`, дуг нет; включить — `on`.
5. Поставить на зарядку → `riddle: tray charging on`, молния в батарее.
6. Сон 3+ мин → после пробуждения `riddle: tray show resume`, время верное, тиков за время сна в логе нет.
7. Треугольник → страница состояния без значков и без строки «Батарея»; касание → `riddle: tray show back`. Роза → карта без значков.
8. Написать страницу у самого низа → ответ встал выше, угол не перекрыт.

## Открытые вопросы

1. Шапка страницы состояния «Батарея 14%» (поломка: заряд < 15% без зарядки, `status.lua:118-120`) — план её оставляет: это тревога, а не показ заряда. Убрать вместе со строкой? Нужно «да/нет» владельца.
2. Ответ, разложенный от `textFloor()+10`, не проверяется на переполнение (`:1496`) — старое поведение; очень длинный ответ всё ещё может накрыть угол. Чинить отдельной задачей `bug / refactoring` или оставить?
