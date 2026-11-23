-- Состояние Kindle (спека 2026-11-19-status-triangle): факты с самого устройства и вёрстка страницы.
-- Чистые функции: источники внедряет вызывающий (файлы, lipc, KOReader), сеть не трогаем. Каждый источник — в pcall:
-- упал или ответил не тем — поле nil, на странице «—», сбор не падает.
local str = require("riddle.str")
local net = require("riddle.net")

local status = {}

status.SSH_PORT = 2222
status.BUILD_NAME = "version" -- имя файла сборки в каталоге плагина (пишет deploy.sh); полный путь собирает вызывающий
status.DISK_PATH = "/mnt/us"
status.BATTERY_LOW_PCT = 15 -- ниже и не на зарядке — поломка
status.DISK_LOW_KB = 50 * 1024
status.SYNC_STALE_S = 86400 -- удачной синхронизации не было дольше — поломка страницы (не sync.STALE_S: тот — частота опроса)
status.MODEL_ROW = 9 -- индекс строки «модель» в lines().rows: её дописывает фоновая проверка

-- ---- разбор текстов /proc и ip (образцы — в tests/status_spec.lua) ----

-- /proc/net/tcp: порт слушает, если есть строка с local_address …:%04X и st == "0A". tcp6 на Kindle нет.
function status.ssh_listening(proc_tcp_text, port)
  for line in tostring(proc_tcp_text or ""):gmatch("[^\n]+") do
    local hex, st = line:match("^%s*%d+:%s+%x+:(%x+)%s+%x+:%x+%s+(%x+)")
    if hex and st == "0A" and tonumber(hex, 16) == port then return true end
  end
  return false
end

-- Свободная RAM, кБ: MemAvailable на ядре 3.0.35 нет, берём MemFree + Buffers + Cached; нет любой — nil.
function status.mem_free_kb(meminfo_text)
  local kb = {}
  for line in tostring(meminfo_text or ""):gmatch("[^\n]+") do
    local key, v = line:match("^(%w+):%s+(%d+)%s*kB")
    if key then kb[key] = tonumber(v) end
  end
  if not (kb.MemFree and kb.Buffers and kb.Cached) then return nil end
  return kb.MemFree + kb.Buffers + kb.Cached
end

function status.uptime_s(proc_uptime_text)
  return tonumber(tostring(proc_uptime_text or ""):match("^%s*(%d+%.?%d*)"))
end

function status.ip(ip_addr_text)
  return tostring(ip_addr_text or ""):match("inet (%d+%.%d+%.%d+%.%d+)/")
end

-- Единственное правило «ответ power() -> факт батареи» (страница состояния и значки угла): процент — число, не NaN,
-- обрезан до 0..100 и округлён до целого; зарядка — только true. Не таблица или нет процента — nil.
function status.battery(p)
  if type(p) ~= "table" then return nil end
  local pct = p.pct
  if type(pct) ~= "number" or pct ~= pct then return nil end
  return { pct = math.floor(math.max(0, math.min(100, pct)) + 0.5), charging = p.charging == true }
end

-- ---- сбор ----

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil
end

local function num(v) return type(v) == "number" and v or nil end
local function text(v) return type(v) == "string" and v ~= "" and v or nil end
local function count(v) return type(v) == "number" and v >= 0 and v < math.huge and v == math.floor(v) and v or nil end

-- d: read(path) -> string|nil, build() -> string|nil (файл status.BUILD_NAME в каталоге плагина), power() -> {pct, charging}|nil, net() -> "up"|"down"|"off", wifi() -> {essid, ip}|nil,
-- disk(path) -> {free_kb, total_kb}|nil, sync_last() -> {at, err}|nil, now() -> number,
-- store() -> {ok_at, docs, collections} — база знаний одним чтением: метка удачной синхронизации и число документов и
-- баз Notion в ней (спека 2026-11-19-status-notion-design); числа — оба или никакого.
function status.collect(d)
  d = d or {}
  local f = { sync = {} }
  f.at = num(try(d.now))

  f.battery = status.battery(try(d.power))

  local net = try(d.net)
  if net == "up" or net == "down" or net == "off" then f.net = net end
  local wifi = try(d.wifi)
  if type(wifi) == "table" then f.essid, f.ip = text(wifi.essid), text(wifi.ip) end

  local tcp = try(d.read, "/proc/net/tcp")
  if type(tcp) == "string" then f.ssh = status.ssh_listening(tcp, status.SSH_PORT) end
  f.mem_free_kb = status.mem_free_kb(try(d.read, "/proc/meminfo"))
  f.uptime_s = status.uptime_s(try(d.read, "/proc/uptime"))

  local disk = try(d.disk, status.DISK_PATH)
  if type(disk) == "table" then f.disk_free_kb = num(disk.free_kb) end

  f.build = text(str.one_line(try(d.build)))

  local last = try(d.sync_last)
  if type(last) == "table" then f.sync.last_at, f.sync.err = num(last.at), text(last.err) end
  local store = try(d.store)
  if type(store) == "table" then
    f.sync.ok_at = num(store.ok_at)
    local docs, cols = count(store.docs), count(store.collections)
    if docs and cols then f.notion = { docs = docs, collections = cols } end
  end
  return f
end

-- ---- вёрстка ----

status.DASH = "—" -- нет данных; общий для страницы состояния и строки лога угла
local DASH = status.DASH

local function age(secs)
  if secs < 60 then return "только что" end
  if secs < 3600 then return string.format("%d мин назад", math.floor(secs / 60)) end
  if secs < 86400 then return string.format("%d ч назад", math.floor(secs / 3600)) end
  return string.format("%d д назад", math.floor(secs / 86400))
end

local function span(secs)
  secs = math.floor(secs)
  local days, hours, mins = math.floor(secs / 86400), math.floor(secs % 86400 / 3600), math.floor(secs % 3600 / 60)
  if days > 0 then
    return hours > 0 and string.format("%d д %d ч", days, hours) or string.format("%d д", days)
  end
  if hours > 0 then return string.format("%d ч %d мин", hours, mins) end
  return string.format("%d мин", mins)
end

local function mb(kb) return string.format("%d МБ", math.floor(kb / 1024 + 0.5)) end

-- целое с разрядами через пробел: 1234567 -> «1 234 567» (во шрифте страницы неразрывного пробела нет)
local function grouped(n)
  local s = string.format("%d", n)
  return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", ""))
end

-- n — {docs, collections} | nil (база занята или недоступна)
local function notion(n)
  if type(n) ~= "table" then return DASH end
  if n.docs == 0 and n.collections == 0 then return "пусто" end
  return string.format("%s %s, %s %s", grouped(n.docs), str.plural(n.docs, "документ", "документа", "документов"),
    grouped(n.collections), str.plural(n.collections, "база", "базы", "баз"))
end

-- Ошибка синхронизации для страницы -> короткая фраза по классу, routine (true — не сбой: шапка её не считает).
-- Полный текст — в sync_last и журнале. Источники текста: http.lua и luasocket (offline, dns: …, timeout, тексты
-- сокета), main.lua (deadline), worker.lua (cancelled), notion.lua (unauthorized, http <код>[ <code>], incomplete,
-- bad json), sync.lua (store: … — база, lua: … — код)
local NET_REASON = { offline = "нет сети", slow = "Notion не ответил вовремя", limit = "Notion просит подождать" }
local UNKNOWN = "ошибка, подробности в журнале"

function status.sync_reason(err)
  local e = tostring(err)
  -- ответ вытеснил синхронизацию; maybeSync запустит её снова (удачная не сдвинулась)
  if e == "cancelled" then return "прервана ответом, повторится", true end
  if e:sub(1, 5) == "lua: " then return UNKNOWN end
  if e:sub(1, 7) == "store: " then return "не записалось в память Kindle" end
  if e == "unauthorized" then return "Notion не пускает — проверь ключ" end
  if e == "incomplete" then return "прервалась на середине" end
  local kind = net.fail_kind(e)
  if kind then return NET_REASON[kind] end
  if e:match("^http 404") then return "Notion не нашёл страницу" end
  if e:match("^http 5%d%d") then return "сбой на стороне Notion" end
  local l = e:lower()
  if l:find("connection", 1, true) or l:find("closed$") then return "связь с Notion оборвалась" end
  return UNKNOWN
end

-- Что сломано: только известное; неизвестное («—» в подробностях) поломкой не считается.
local function problems(f, now)
  local list = {}
  local b = f.battery
  if b and b.pct < status.BATTERY_LOW_PCT and not b.charging then
    list[#list + 1] = string.format("Батарея %d%%", b.pct)
  end
  if f.net == "off" then list[#list + 1] = "Wi‑Fi выключен"
  elseif f.net == "down" then list[#list + 1] = "Wi‑Fi без связи" end
  if f.ssh == false then list[#list + 1] = "ssh не слушает порт " .. status.SSH_PORT end
  if f.disk_free_kb and f.disk_free_kb < status.DISK_LOW_KB then
    list[#list + 1] = "Мало места: " .. mb(f.disk_free_kb)
  end
  local s = f.sync or {}
  if s.err then
    local why, routine = status.sync_reason(s.err)
    if not routine then list[#list + 1] = "Синхронизация: " .. why end
  end
  if s.ok_at and now and now - s.ok_at > status.SYNC_STALE_S then
    list[#list + 1] = "Синхронизации не было дольше " .. span(status.SYNC_STALE_S)
  end
  return list
end

local function head(list)
  if #list == 0 then return { "Всё в порядке" } end
  -- две строки: первая поломка и всё остальное через «; » — ничего не теряется
  if #list <= 2 then return list end
  return { list[1], table.concat(list, "; ", 2) }
end

local function rows(f, now)
  local r = {}
  -- заряд батареи — в углу дневника (спека 2026-11-19-corner-icons-design); здесь только поломка в шапке
  local wifi = DASH
  if f.net == "up" then wifi = string.format("на связи, сеть %s, IP %s", f.essid or DASH, f.ip or DASH)
  elseif f.net == "down" then wifi = "включён, нет связи"
  elseif f.net == "off" then wifi = "выключен" end
  r[1] = "Wi‑Fi: " .. wifi

  local ssh = DASH
  if f.ssh ~= nil then ssh = (f.ssh and "слушает" or "не слушает") .. " порт " .. status.SSH_PORT end
  r[2] = "ssh: " .. ssh

  r[3] = "Память: " .. (f.mem_free_kb and ("свободно " .. mb(f.mem_free_kb)) or DASH)
  r[4] = "Место на /mnt/us: " .. (f.disk_free_kb and ("свободно " .. mb(f.disk_free_kb)) or DASH)
  r[5] = "Без перезагрузки: " .. (f.uptime_s and span(f.uptime_s) or DASH)
  r[6] = "Сборка: " .. (f.build or DASH)

  local s = f.sync or {}
  local sy = DASH
  if s.ok_at then sy = "удачная " .. (now and age(now - s.ok_at) or DASH) end
  if s.err then
    local when = (s.last_at and now) and (age(now - s.last_at) .. ", ") or ""
    sy = (s.ok_at and (sy .. "; ") or "") .. "последняя попытка — " .. when .. status.sync_reason(s.err)
  end
  r[7] = "Синхронизация: " .. sy
  r[8] = "Notion: " .. notion(f.notion)

  r[status.MODEL_ROW] = status.model_line(nil)
  return r
end

-- Строка модели: m — итог фоновой проверки | nil (не проверялась — «—»). m.state: "checking" | "offline" |
-- "busy" (m.kind — чем занят раннер) | "ok" (m.ms — сколько шёл ответ) | "err" (m.err)
function status.model_line(m)
  local s = m and m.state
  if s == "checking" then return "Модель: проверяю…" end
  if s == "offline" then return "Модель: нет сети" end
  if s == "busy" then return "Модель: не проверена (занято: " .. tostring(m.kind) .. ")" end
  if s == "ok" then return string.format("Модель отвечает (%d мс)", m.ms) end
  if s == "err" then return "Модель: " .. tostring(m.err) end
  return "Модель: " .. DASH
end

-- now — время показа; без него берётся время сбора (facts.at). Нет и его — «когда» на странице «—».
function status.lines(facts, now)
  facts = facts or {}
  now = now or facts.at
  return { head = head(problems(facts, now)), rows = rows(facts, now) }
end

return status
