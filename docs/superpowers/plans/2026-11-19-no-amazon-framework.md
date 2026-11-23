# Kindle без оболочки Amazon — план

> **Устарел 2026-11-19:** Kindle уже работает без оболочки (см. факт в спеке). Task 1, 3, 4 не нужны; Task 2 сведён к замене `--kual` на `--framework_stop` в запасном пути `tools/deploy.sh` с тестом в `tests/deploy_spec.lua`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** при загрузке Kindle KOReader с дневником стартует в штатном режиме «без оболочки Amazon»; выход из KOReader возвращает оболочку.

**Architecture:** команда запуска KOReader живёт в одном месте — скрипте `kindle/boot_koreader.sh` (в репо), который деплой кладёт в `/mnt/us/riddle/`. Его вызывают и задание upstart `/etc/upstart/riddle-koreader.conf`, и запасной путь `tools/deploy.sh`. Само задание upstart (`start on framework_ready`, пауза, файл-запрет `no_boot`) остаётся, меняется только строка запуска.

**Tech Stack:** sh (busybox на Kindle), upstart, KOReader v2025.08 `koreader.sh`, luajit-тесты `tests/run.sh` с поддельными ssh/scp (`tests/fakebin`).

**Spec:** `docs/superpowers/specs/2026-11-18-no-amazon-framework-design.md`

## Global Constraints

- Kindle PW2, FW 5.12.2.2 — тестовый стенд, деплой без спроса; `/etc` и rootfs — только сисадмин.
- `killall reader.lua` не делать (выключает Wi‑Fi). `/mnt/us` — FAT: chmod не действует, скрипты запускать через `sh <путь>`.
- Устройство в один момент деплоит/перезапускает только назначенный оркестратором исполнитель.
- Анти-цель: Kindle не загружается или не возвращается без ssh/USB; потеря сети, подсветки, сна, зарядки по USB.
- Владельца не просить проверять руками.

## Review Focus

1. KOReader падает при старте без оболочки → оболочка Amazon должна вернуться (не чёрный экран). Проверка — Task 4, шаг «падение».
2. Деплой (выход 85 → перезапуск в `koreader.sh`) не поднимает оболочку обратно. Task 4.
3. Wi‑Fi/ssh после сна без оболочки: Kindle просыпается кнопкой и снова доступен по ssh. Task 1 и Task 4.
4. Подключение USB к Mac без оболочки: зарядка идёт, Kindle не зависает. Task 1 и Task 4.
5. Файл-запрет `/mnt/us/riddle/no_boot` по-прежнему отключает автозапуск. Task 4.

---

### Task 1: Разведка на Kindle (тестер, без правок `/etc`)

Снимает ASSUMPTION 1–3 спеки. Без его PASS Task 2–4 не начинать.

**Files:** нет (отчёт оркестратору).

- [ ] **Step 1:** `ssh kindle 'grep -n -E "framework|--kual|--asap" /mnt/us/koreader/koreader.sh'` — найти флаг режима без оболочки (ожидается `--framework_stop`, ASSUMPTION) и что он делает при старте и на выходе (какое задание upstart останавливает и поднимает).
- [ ] **Step 2:** `ssh kindle 'free -m; cat /etc/upstart/riddle-koreader.conf'` при работающем KOReader с оболочкой — цифры «до» и текущая строка запуска.
- [ ] **Step 3:** через KUAL-эквивалент по ssh: выход из текущего KOReader штатно (не `killall`), затем `cd /mnt/us/koreader && (setsid ./koreader.sh <флаг> >/dev/null 2>&1 </dev/null &)`. Ожидается: на экране KOReader, `pgrep -f cvm` пусто, `free -m` — «после».
- [ ] **Step 4:** без оболочки проверить: Wi‑Fi вкл/выкл из меню KOReader; подсветка; сон и пробуждение (`lipc-set-prop com.lab126.powerd powerButton 1` дважды), ssh после пробуждения; `tools/deploy.sh` (путь «KOReader запущен», ждём `restart confirmed`, оболочка не вернулась); USB к Mac — зарядка, Kindle не завис.
- [ ] **Step 5:** выход из KOReader → оболочка Amazon вернулась (`pgrep -f cvm` не пусто, экран Amazon).
- [ ] **Step 6:** отчёт: флаг, строки `koreader.sh` с номерами, `free -m` до/после, PASS/FAIL по каждому пункту шага 4–5 с выводом команды. Любой FAIL — стоп, к оркестратору.

### Task 2: Скрипт запуска в одном месте + запасной путь деплоя (исполнитель)

**Files:**
- Create: `kindle/boot_koreader.sh`
- Modify: `tools/deploy.sh:61` (запасной путь), `tools/deploy.sh` (копирование скрипта)
- Test: `tests/deploy_spec.lua`

**Interfaces:**
- Consumes: флаг из отчёта Task 1 (далее `<FLAG>`).
- Produces: `/mnt/us/riddle/boot_koreader.sh`, запуск `sh /mnt/us/riddle/boot_koreader.sh` — без аргументов, стартует KOReader отсоединённо с `<FLAG>` и сразу возвращается.

- [ ] **Step 1: Падающие тесты в `tests/deploy_spec.lua`:**
  - `fallback launches via boot script`: при `pidof` = 1 лог поддельного ssh содержит `sh /mnt/us/riddle/boot_koreader.sh` и не содержит `--kual`.
  - `deploy copies boot script`: лог scp содержит `kindle/boot_koreader.sh` → `kindle:/mnt/us/riddle/`.
  - Существующая проверка строки 89 (`koreader.sh --kual`) — заменить на первую.
- [ ] **Step 2:** `tests/run.sh` — новые тесты FAIL.
- [ ] **Step 3:** `kindle/boot_koreader.sh`: `cd /mnt/us/koreader` и запуск `./koreader.sh <FLAG>` через `setsid … >/dev/null 2>&1 </dev/null &`. В `tools/deploy.sh` — scp скрипта в `/mnt/us/riddle/` рядом с копированием плагина; строка 61 → `ssh kindle 'sh /mnt/us/riddle/boot_koreader.sh; sleep 1; echo "koreader launched"'`. Комментарий в шапке deploy.sh про «exactly like KUAL» обновить.
- [ ] **Step 4:** `tests/run.sh` — всё зелёное.
- [ ] **Step 5:** коммит `deploy: запуск KOReader без оболочки Amazon через boot_koreader.sh (8146)`.

### Task 3: Задание автозапуска (сисадмин)

**Interfaces:** Consumes `sh /mnt/us/riddle/boot_koreader.sh` (Task 2, задеплоен на Kindle).

- [ ] **Step 1:** копия `/etc/upstart/riddle-koreader.conf` → `/mnt/us/riddle/backup/riddle-koreader.conf.<дата>`.
- [ ] **Step 2:** в задании заменить строку запуска `koreader.sh --kual` на `sh /mnt/us/riddle/boot_koreader.sh`; `start on framework_ready`, пауза и проверка `no_boot` — без изменений. Rootfs открыть на запись и закрыть обратно по своему порядку.
- [ ] **Step 3:** `diff` старой и новой версии — в отчёт; холодная перезагрузка; через ~1 мин `ssh kindle 'pgrep -f cvm; pidof reader.lua; free -m'`. Ожидается: cvm пусто, reader.lua есть.

### Task 4: Приёмка на Kindle (тестер)

- [ ] **Step 1:** после холодной перезагрузки: KOReader с дневником на экране, оболочки нет (`pgrep -f cvm` пусто), `free -m` против цифр Task 1.
- [ ] **Step 2:** повторить проверки Task 1 шаг 4 (Wi‑Fi, подсветка, сон/пробуждение + ssh, `tools/deploy.sh` → `restart confirmed` и cvm всё ещё пусто, USB).
- [ ] **Step 3:** запасной путь деплоя: штатно выйти из KOReader (оболочка вернулась), затем `tools/deploy.sh` → `koreader launched`, cvm снова пусто.
- [ ] **Step 4 «падение»:** живьём KOReader не убивать (`kill`/`killall reader.lua` гасит Wi‑Fi). По `koreader.sh` (строки из отчёта Task 1) подтвердить: при любом коде выхода, кроме 85, выполняется возврат оболочки Amazon. Цитата строк с номерами — в отчёт. Не так — FAIL, стоп.
- [ ] **Step 5:** `touch /mnt/us/riddle/no_boot`, холодная перезагрузка → загрузилась оболочка Amazon, KOReader не стартовал; файл убрать, перезагрузка → снова KOReader без оболочки.
- [ ] **Step 6:** отчёт по пунктам 1–5 с выводом команд.
