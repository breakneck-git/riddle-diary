-- Состояние Kindle (спека 2026-11-19-status-triangle): факты с устройства и вёрстка страницы — чистые функции.
-- Образцы /proc и ip — литералы с устройства (план, «Kindle (живая сверка)» L2–L6, 2026-11-19).
local t = require("t")
local status = require("riddle.status")

local T = {}

local PROC_TCP = table.concat({
  "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode",
  "   0: 0100007F:D903 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 8012 1 00000000 100 0 0 10 -1",
  "   1: 00000000:08AE 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 8934 1 00000000 100 0 0 10 -1",
  "   2: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 7711 1 00000000 100 0 0 10 -1",
  "",
}, "\n")

local MEMINFO = table.concat({
  "MemTotal:         254828 kB",
  "MemFree:           25380 kB",
  "Buffers:           40272 kB",
  "Cached:           100212 kB",
  "SwapCached:            0 kB",
  "Active:            90000 kB",
  "",
}, "\n")

local IP_ADDR = "9: wlan0    inet 192.0.2.220/24 brd 192.0.2.255 scope global wlan0\\       valid_lft forever preferred_lft forever"

local NOW = 1763500000

-- здоровое устройство; тест подменяет нужное поле
local function healthy(over)
  local f = {
    battery = { pct = 88, charging = false },
    net = "up", essid = "home", ip = "192.0.2.220",
    ssh = true, mem_free_kb = 165864, disk_free_kb = 784 * 1024,
    uptime_s = 2208707.9, build = "a2105ce",
    sync = { ok_at = NOW - 600, last_at = NOW - 600, err = nil },
    notion = { docs = 1234, collections = 12 },
  }
  for k, v in pairs(over or {}) do f[k] = v end
  return f
end

local function joined(list) return table.concat(list, "\n") end

-- ---- разбор /proc и ip ----

function T.test_ssh_listening()
  t.eq(status.ssh_listening(PROC_TCP, 2222), true, "0x08AE = 2222, st 0A")
  t.eq(status.ssh_listening(PROC_TCP, 2223), false)
  t.eq(status.ssh_listening(PROC_TCP, 22), true, "0x0016 тоже слушает — порт берётся из аргумента")
  local established = PROC_TCP:gsub("00000000:08AE 00000000:0000 0A", "00000000:08AE 00000000:0000 01")
  t.eq(status.ssh_listening(established, 2222), false, "тот же порт, но st 01 — не LISTEN")
  t.eq(status.ssh_listening("", 2222), false)
  local remote_only = PROC_TCP .. "   3: 0100007F:D903 00000000:08AE 0A 00000000:00000000 00:00000000 00000000     0        0 9000 1 00000000 100 0 0 10 -1\n"
  t.eq(status.ssh_listening((PROC_TCP:gsub("00000000:08AE", "00000000:0FFF")), 2222), false, "2222 нет ни в одной строке")
  t.eq(status.ssh_listening(remote_only, 2222), true, "контроль: 2222 слушается строкой 1")
  local only_remote = table.concat({
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode",
    "   0: 0100007F:D903 00000000:08AE 0A 00000000:00000000 00:00000000 00000000     0        0 8012 1 00000000 100 0 0 10 -1",
    "",
  }, "\n")
  t.eq(status.ssh_listening(only_remote, 2222), false, "2222 только в remote_address — не слушаем")
end

function T.test_mem_free_kb()
  t.eq(status.mem_free_kb(MEMINFO), 165864, "MemFree + Buffers + Cached (MemAvailable на ядре 3.0.35 нет)")
  t.ok(MEMINFO:find("SwapCached:", 1, true), "образец содержит SwapCached")
  t.eq(status.mem_free_kb((MEMINFO:gsub("\nCached:[^\n]*", ""))), nil, "нет Cached, но есть SwapCached — не подхватывать его")
  t.eq(status.mem_free_kb((MEMINFO:gsub("Buffers:[^\n]*\n", ""))), nil, "нет Buffers")
  t.eq(status.mem_free_kb((MEMINFO:gsub("MemFree:[^\n]*\n", ""))), nil, "нет MemFree")
  t.eq(status.mem_free_kb(""), nil)
end

function T.test_uptime_s()
  t.eq(status.uptime_s("2208707.90 285648.98\n"), 2208707.90)
  t.eq(status.uptime_s("ерунда"), nil)
  t.eq(status.uptime_s(""), nil)
end

function T.test_ip()
  t.eq(status.ip(IP_ADDR), "192.0.2.220")
  t.eq(status.ip(""), nil)
  t.eq(status.ip("9: wlan0    inet6 fe80::1/64 scope link"), nil, "inet6 — не IPv4")
end

-- ---- сбор ----

function T.test_collect_reads_every_source()
  local reads = {}
  local files = { ["/proc/net/tcp"] = PROC_TCP, ["/proc/meminfo"] = MEMINFO, ["/proc/uptime"] = "2208707.90 285648.98\n" }
  local build_calls = 0
  local d = {
    read = function(path)
      reads[#reads + 1] = path
      return files[path]
    end,
    build = function() build_calls = build_calls + 1; return "a2105ce-dirty\n" end,
    power = function() return { pct = 88, charging = true } end,
    net = function() return "up" end,
    wifi = function() return { essid = "home", ip = "192.0.2.220" } end,
    disk = function(path) t.eq(path, "/mnt/us"); return { free_kb = 784 * 1024, total_kb = 1360 * 1024 } end,
    sync_last = function() return { at = NOW - 60, err = "http 401" } end,
    store = function() return { ok_at = NOW - 7200, docs = 1234, collections = 12 } end,
    now = function() return NOW end,
  }
  local f = status.collect(d)
  t.eq(f.notion.docs, 1234); t.eq(f.notion.collections, 12)
  t.eq(f.battery.pct, 88); t.eq(f.battery.charging, true)
  t.eq(f.net, "up"); t.eq(f.essid, "home"); t.eq(f.ip, "192.0.2.220")
  t.eq(f.ssh, true)
  t.eq(f.mem_free_kb, 165864)
  t.eq(f.disk_free_kb, 784 * 1024)
  t.eq(f.uptime_s, 2208707.90)
  t.eq(f.build, "a2105ce-dirty", "строка версии без перевода строки")
  t.eq(build_calls, 1, "версию отдаёт внедрённый источник: путь к плагину знает вызывающий")
  t.eq(status.BUILD_NAME, "version", "имя файла — для вызывающего, полный путь у него")
  t.eq(status.BUILD_FILE, nil, "каталога плагина в status нет")
  t.eq(f.sync.ok_at, NOW - 7200); t.eq(f.sync.last_at, NOW - 60); t.eq(f.sync.err, "http 401")
  -- tcp6 на этом ядре нет (L2): читается только /proc/net/tcp
  for _, p in ipairs(reads) do t.ok(p ~= "/proc/net/tcp6", "tcp6 не читаем") end
end

function T.test_collect_survives_every_source_failing()
  local function boom() error("boom") end
  local f = status.collect({ read = boom, build = boom, power = boom, net = boom, wifi = boom, disk = boom,
                             sync_last = boom, store = boom, now = boom })
  t.eq(type(f), "table")
  t.eq(f.notion, nil, "база знаний занята или недоступна — числа неизвестны")
  t.eq(f.battery, nil); t.eq(f.net, nil); t.eq(f.ssh, nil); t.eq(f.mem_free_kb, nil)
  t.eq(f.disk_free_kb, nil); t.eq(f.uptime_s, nil); t.eq(f.build, nil)
  local l = status.lines(f, NOW)
  t.eq(l.head[1], "Всё в порядке", "неизвестное — не поломка")
  for i, row in ipairs(l.rows) do t.ok(row:find("—", 1, true), "строка " .. i .. " без данных — «—»: " .. row) end
end

function T.test_collect_one_failure_does_not_hide_others()
  local f = status.collect({
    read = function(path) if path == "/proc/meminfo" then return MEMINFO end end,
    power = function() error("boom") end,
    net = function() return "off" end,
  })
  t.eq(f.battery, nil)
  t.eq(f.net, "off")
  t.eq(f.mem_free_kb, 165864)
end

function T.test_collect_ignores_malformed_source_answers()
  local f = status.collect({
    power = function() return "88" end,
    net = function() return "weird" end,
    wifi = function() return 5 end,
    disk = function() return {} end,
    sync_last = function() return "x" end,
    store = function() return { ok_at = "вчера", docs = "много", collections = 2 } end,
  })
  t.eq(f.battery, nil); t.eq(f.net, nil); t.eq(f.ip, nil); t.eq(f.disk_free_kb, nil)
  t.eq(f.sync.ok_at, nil); t.eq(f.sync.err, nil)
  t.eq(f.notion, nil, "не число — числа неизвестны целиком")
  for _, bad in ipairs({ -1, 1.5, 0 / 0, math.huge }) do
    local g = status.collect({ store = function() return { docs = bad, collections = 1 } end })
    t.eq(g.notion, nil, "документов " .. tostring(bad))
    g = status.collect({ store = function() return { docs = 1, collections = bad } end })
    t.eq(g.notion, nil, "баз " .. tostring(bad))
  end
  t.eq(status.collect({ store = function() return "x" end }).notion, nil)
end

-- метка хранилища и числа — одним ответом источника (одно соединение), но метка не зависит от чисел
function T.test_collect_store_ok_at_without_counts()
  local f = status.collect({ store = function() return { ok_at = NOW - 60 } end })
  t.eq(f.sync.ok_at, NOW - 60)
  t.eq(f.notion, nil)
end

-- ---- вёрстка ----

function T.test_lines_healthy()
  local l = status.lines(healthy(), NOW)
  t.eq(l.head[1], "Всё в порядке")
  t.eq(l.head[2], nil)
  local all = joined(l.rows)
  t.ok(not all:find("Батарея", 1, true) and not all:find("88%%"), "батареи в строках нет — она в углу")
  t.ok(all:find("home", 1, true), "сеть")
  t.ok(all:find("192.0.2.220", 1, true), "IP")
  t.ok(all:find("2222", 1, true), "порт ssh")
  t.ok(all:find("162", 1, true), "свободная RAM в МБ (165864 кБ = 162 МБ)")
  t.ok(all:find("784", 1, true), "место на /mnt/us в МБ")
  t.ok(all:find("25 д 13 ч", 1, true), "uptime 2208707 с = 25 д 13 ч")
  t.ok(all:find("a2105ce", 1, true), "сборка")
  t.ok(all:find("10 мин назад", 1, true), "синхронизация 600 с назад")
end

function T.test_battery_row_gone()
  local l = status.lines(healthy(), NOW)
  t.eq(#l.rows, 9, "батареи нет, строка Notion добавлена")
  t.ok(l.rows[1]:find("Wi‑Fi: ", 1, true) == 1, l.rows[1])
end

-- строка Notion — сразу под строкой синхронизации (спека 2026-11-19-status-notion-design)
function T.test_notion_row_under_sync()
  local l = status.lines(healthy(), NOW)
  t.ok(l.rows[7]:find("Синхронизация: ", 1, true) == 1, l.rows[7])
  t.eq(l.rows[8], "Notion: 1 234 документа, 12 баз")
end

function T.test_notion_row_forms()
  local function row(docs, cols) return status.lines(healthy({ notion = { docs = docs, collections = cols } }), NOW).rows[8] end
  t.eq(row(1, 1), "Notion: 1 документ, 1 база")
  t.eq(row(21, 3), "Notion: 21 документ, 3 базы")
  t.eq(row(5, 0), "Notion: 5 документов, 0 баз")
  t.eq(row(0, 4), "Notion: 0 документов, 4 базы", "базы есть, документов нет — не «пусто»")
  t.eq(row(999, 2), "Notion: 999 документов, 2 базы")
  t.eq(row(1234567, 12), "Notion: 1 234 567 документов, 12 баз")
  t.eq(row(0, 0), "Notion: пусто", "синхронизаций ещё не было")
  t.eq(status.lines(healthy({ notion = false }), NOW).rows[8], "Notion: —", "база занята или недоступна")
end

function T.test_lines_wifi_off()
  local l = status.lines(healthy({ net = "off", essid = false, ip = false }), NOW)
  t.ok(l.head[1]:find("Wi‑Fi выключен", 1, true), l.head[1])
  t.ok(l.head[1] ~= "Всё в порядке")
end

function T.test_lines_wifi_down()
  local l = status.lines(healthy({ net = "down" }), NOW)
  t.ok(l.head[1]:find("Wi‑Fi", 1, true) and l.head[1] ~= "Всё в порядке", l.head[1])
  t.ok(not l.head[1]:find("выключен", 1, true), "включён, но без связи — не «выключен»")
end

-- ошибка синхронизации на странице — короткая фраза по классу, не сырой текст (в sync_last и журнале — полный):
-- в шапке «Синхронизация: <фраза>», в подробностях «…последняя попытка — <когда>, <фраза>»
local function sync_says(err, phrase)
  local l = status.lines(healthy({ sync = { ok_at = NOW - 600, last_at = NOW - 60, err = err } }), NOW)
  t.ok(joined(l.head):find("Синхронизация: " .. phrase, 1, true), err .. " -> шапка: " .. joined(l.head))
  t.ok(l.rows[7]:find("последняя попытка — 1 мин назад, " .. phrase, 1, true), err .. " -> подробности: " .. l.rows[7])
  t.ok(not joined(l.head):find(err, 1, true) and not l.rows[7]:find(err, 1, true), "сырого текста нет: " .. err)
end

-- http: нет сети (http.lua: «offline», «dns: …») — одно правило с фразами дневника (fail_offline)
function T.test_sync_error_offline()
  sync_says("offline", "нет сети")
  sync_says("dns: timeout", "нет сети")
end

-- http: вышло время запроса (http.lua: «timeout»)
function T.test_sync_error_timeout()
  sync_says("timeout", "Notion не ответил вовремя")
end

-- notion: 429 после повторов (notion.lua: «http 429»)
function T.test_sync_error_rate_limit()
  sync_says("http 429", "Notion просит подождать")
end

-- notion: 401/403 (notion.lua: «unauthorized»)
function T.test_sync_error_unauthorized()
  sync_says("unauthorized", "Notion не пускает — проверь ключ")
end

-- notion: 404 вне страниц (поиск, база): «http 404 <code>»
function T.test_sync_error_not_found()
  sync_says("http 404 object_not_found", "Notion не нашёл страницу")
end

-- notion: 5xx и 529 после повторов
function T.test_sync_error_server()
  sync_says("http 502", "сбой на стороне Notion")
  sync_says("http 529", "сбой на стороне Notion")
end

-- notion: оборванная пагинация (notion.lua: «incomplete»)
function T.test_sync_error_incomplete()
  sync_says("incomplete", "прервалась на середине")
end

-- sync: база знаний не открылась или упала посреди прохода (sync.lua: «store: …»)
function T.test_sync_error_store()
  sync_says("store: database is locked", "не записалось в память Kindle")
end

-- сокет: обрыв соединения (luasocket, с устройства: «Connection reset by peer»)
function T.test_sync_error_connection()
  sync_says("Connection reset by peer", "связь с Notion оборвалась")
end

-- раннер: синхронизацию вытеснил ответ (worker.lua: «cancelled») — не сбой: шапка «Всё в порядке», в подробностях —
-- что прервана и повторится (maybeSync снова запустит её по старой удачной)
function T.test_sync_cancelled_by_answer_is_not_a_problem()
  local l = status.lines(healthy({ sync = { ok_at = NOW - 600, last_at = NOW - 60, err = "cancelled" } }), NOW)
  t.eq(l.head[1], "Всё в порядке", joined(l.head))
  t.eq(l.head[2], nil)
  t.ok(l.rows[7]:find("последняя попытка — 1 мин назад, прервана ответом, повторится", 1, true), l.rows[7])
  t.ok(not l.rows[7]:find("cancelled", 1, true), "сырого текста нет: " .. l.rows[7])
end

-- main.lua: потолок времени синхронизации в дочернем («deadline») — тот же класс, что timeout
function T.test_sync_error_deadline()
  sync_says("deadline", "Notion не ответил вовремя")
end

-- luasocket: закрытое соединение — обрыв; сети нет — «нет сети»; регистр не важен
function T.test_sync_error_socket_texts()
  sync_says("closed", "связь с Notion оборвалась")
  sync_says("Network is unreachable", "нет сети")
  sync_says("network is unreachable", "нет сети")
  sync_says("No route to host", "нет сети")
  sync_says("CONNECTION RESET BY PEER", "связь с Notion оборвалась")
end

-- ошибка кода внутри прохода синхронизации (sync.lua: «lua: …», не «store: ») — общая фраза, а не «память Kindle»
function T.test_sync_error_code_is_not_store()
  sync_says("lua: riddle/sync.lua:240: attempt to index a number value", "ошибка, подробности в журнале")
  -- текст ошибки кода со словами сетевых классов — всё равно не они
  sync_says("lua: x.lua:1: attempt to index field 'connection'", "ошибка, подробности в журнале")
  sync_says("lua: x.lua:1: socket closed", "ошибка, подробности в журнале")
  sync_says("lua: x.lua:1: wait timeout", "ошибка, подробности в журнале")
end

-- неизвестное (notion.lua: «bad json» и прочее) — общая фраза
function T.test_sync_error_unknown()
  sync_says("bad json", "ошибка, подробности в журнале")
end

function T.test_lines_sync_error_shows_when_attempt_was()
  local l = status.lines(healthy({ sync = { ok_at = NOW - 7200, last_at = NOW - 1800, err = "unauthorized" } }), NOW)
  local row = l.rows[7]
  t.ok(row:find("2 ч назад", 1, true), "когда была удачная: " .. row)
  t.ok(row:find("30 мин назад", 1, true), "когда была неудачная попытка: " .. row)
  t.ok(row:find("Notion не пускает", 1, true), row)
  local no_ok = status.lines(healthy({ sync = { last_at = NOW - 1800, err = "timeout" } }), NOW)
  t.ok(no_ok.rows[7]:find("30 мин назад", 1, true) and no_ok.rows[7]:find("не ответил вовремя", 1, true),
       no_ok.rows[7])
end

function T.test_lines_sync_stale_after_a_day()
  local day = status.SYNC_STALE_S
  t.eq(day, 86400, "порог тревоги страницы — сутки, отдельно от sync.STALE_S")
  local fresh = status.lines(healthy({ sync = { ok_at = NOW - day, last_at = NOW - day } }), NOW)
  t.eq(fresh.head[1], "Всё в порядке", "ровно сутки — ещё не «давно»")
  local stale = status.lines(healthy({ sync = { ok_at = NOW - day - 1, last_at = NOW - day - 1 } }), NOW)
  t.ok(stale.head[1] ~= "Всё в порядке", "больше суток — поломка")
  t.ok(stale.head[1]:find("1 д", 1, true), "надпись выводится из порога: " .. stale.head[1])
end

function T.test_lines_battery_low_only_when_not_charging()
  local low = status.lines(healthy({ battery = { pct = 14, charging = false } }), NOW)
  t.ok(low.head[1]:find("14", 1, true), low.head[1])
  local edge = status.lines(healthy({ battery = { pct = 15, charging = false } }), NOW)
  t.eq(edge.head[1], "Всё в порядке", "15% — ещё норма")
  local charging = status.lines(healthy({ battery = { pct = 3, charging = true } }), NOW)
  t.eq(charging.head[1], "Всё в порядке", "на зарядке малый заряд — не поломка")
  t.ok(not joined(charging.rows):find("Батарея", 1, true))
end

function T.test_lines_ssh_down_and_low_disk()
  local l = status.lines(healthy({ ssh = false }), NOW)
  t.ok(l.head[1]:find("ssh", 1, true), l.head[1])
  local d = status.lines(healthy({ disk_free_kb = 50 * 1024 - 1 }), NOW)
  t.ok(d.head[1] ~= "Всё в порядке", "меньше 50 МБ — поломка")
  local ok = status.lines(healthy({ disk_free_kb = 50 * 1024 }), NOW)
  t.eq(ok.head[1], "Всё в порядке", "ровно 50 МБ — норма")
end

function T.test_lines_head_holds_two_lines_and_loses_nothing()
  local l = status.lines(healthy({ net = "off", ssh = false, battery = { pct = 5, charging = false },
                                   sync = { ok_at = NOW - 600, last_at = NOW - 60, err = "timeout" } }), NOW)
  t.ok(l.head[1] and l.head[2], "две строки")
  t.eq(l.head[3], nil, "не больше двух")
  local h = joined(l.head)
  for _, word in ipairs({ "Wi‑Fi выключен", "ssh", "5%", "не ответил вовремя" }) do
    t.ok(h:find(word, 1, true), "в перечне нет: " .. word)
  end
end

function T.test_model_row_is_reserved_for_task_6()
  local l = status.lines(healthy(), NOW)
  t.eq(type(status.MODEL_ROW), "number")
  t.ok(l.rows[status.MODEL_ROW]:find("[Мм]одель"), "строка модели на своём месте: " .. tostring(l.rows[status.MODEL_ROW]))
  t.ok(l.rows[status.MODEL_ROW]:find("—", 1, true), "пока не проверена — «—»")
  t.eq(#l.rows, status.MODEL_ROW, "модель — последняя: дописывать вниз")
end

function T.test_lines_now_defaults_to_collection_time()
  local f = status.collect({ now = function() return NOW end, store = function() return { ok_at = NOW - 7200 } end })
  t.ok(joined(status.lines(f).rows):find("2 ч назад", 1, true), "без now берётся время сбора")
end

function T.test_battery_rule()
  local b = status.battery({ pct = 87.4, charging = true })
  t.eq(b.pct, 87); t.eq(b.charging, true)
  t.eq(status.battery({ pct = 130 }).pct, 100); t.eq(status.battery({ pct = -5 }).pct, 0)
  t.eq(status.battery({ pct = 99.5 }).pct, 100)
  t.eq(status.battery({ pct = 50, charging = 1 }).charging, false)
  t.eq(status.battery({ pct = 0 / 0 }), nil); t.eq(status.battery({ pct = "88" }), nil)
  t.eq(status.battery({}), nil); t.eq(status.battery(nil), nil); t.eq(status.battery(7), nil)
  t.eq(status.collect({ power = function() return { pct = 87.4 } end }).battery.pct, 87)
end

t.run(T)
