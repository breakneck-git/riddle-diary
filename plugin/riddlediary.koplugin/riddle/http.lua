-- HTTPS-запрос (POST для llm.call, GET/POST для Notion): блокирующий, с ПОЛНЫМ дедлайном timeout_s на весь запрос.
--
-- Прямой путь (socket + socket.http + ssl): свой create для http.request. Каждой операции сокета
-- (connect, TLS-рукопожатие, send, receive) выставляется таймаут = остаток дедлайна. Имя хоста
-- резолвится своим DNS-запросом по UDP с тем же дедлайном (getaddrinfo не прерывается: Wi‑Fi без
-- интернета вешал его > 5 с); IP запоминается (http.warm прогревает кэш заранее), при сбое connect
-- запись сбрасывается. Нет UDP или nameserver в resolv.conf — по имени, как раньше.
-- Запасной путь (только ssl.https): таймаут на операцию + проверка дедлайна в sink. Идёт в ход, если
-- прямой путь упал Lua-ошибкой (не сетевым сбоем), с остатком времени.
-- Модули ищутся при загрузке; на Mac в тестах их подменяют через package.preload.

local http = {}

local function try_require(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
end

local socket = try_require("socket")
local shttp = socket and try_require("socket.http")
local ssl = socket and try_require("ssl")
local https = try_require("ssl.https")

-- Есть ли сеть: NetworkMgr:isConnected() (на Kindle — наличие адреса у интерфейса, без обращений
-- к сети). isOnline() не берём: он делает блокирующий DNS-запрос. Не удалось узнать — считаем, что онлайн.
local function networkmgr_online()
  local ok, mgr = pcall(require, "ui/network/manager")
  if not ok or type(mgr) ~= "table" or type(mgr.isConnected) ~= "function" then return true end
  local ok2, connected = pcall(mgr.isConnected, mgr)
  if not ok2 then return true end
  return connected and true or false
end

-- IP хоста после первого успешного соединения; поля переопределяются в тестах
http.dns_cache = {}
http.online = networkmgr_online
http.clock = function()
  if socket and socket.gettime then return socket.gettime() end
  return os.time()
end
-- параметры TLS как у ssl.https по умолчанию (проверки сертификата нет)
http.tls = { mode = "client", protocol = "any", verify = "none", options = { "all", "no_sslv2", "no_sslv3" } }

local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

http.log = function() end

-- DNS по UDP: запрос A/IN с рекурсией -------------------------------------------

local WARM_BUDGET_S = 3
local DNS_TIMEOUT_S = 2 -- обычный ответ — десятки мс; дольше — DNS не работает
local DNS_DOWN_S = 10   -- после таймаута столько не спрашиваем: цепочка провайдеров не ждёт DNS трижды

http.dns_down_until = 0

-- сеть поднялась заново: снова спрашивать DNS
function http.dns_reset()
  http.dns_down_until = 0
end

-- nameserver'ы IPv4 из resolv.conf; переопределяется в тестах
function http.nameservers()
  local out = {}
  local f = io.open("/etc/resolv.conf", "r")
  if not f then return out end
  for line in f:lines() do
    local ip = line:match("^%s*nameserver%s+(%d+%.%d+%.%d+%.%d+)%s*$")
    if ip then out[#out + 1] = ip end
  end
  f:close()
  return out
end

function http._dns_query(host, id)
  local parts = { string.char(math.floor(id / 256), id % 256, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0) }
  for label in host:gmatch("[^.]+") do parts[#parts + 1] = string.char(#label) .. label end
  parts[#parts + 1] = "\0\0\1\0\1"
  return table.concat(parts)
end

-- первый A-адрес ответа; nil, причина — если ответа нет или он чужой/битый
function http._dns_parse(data, id)
  if type(data) ~= "string" or #data < 12 then return nil, "short" end
  local function u16(i)
    local a, b = data:byte(i, i + 1)
    if not b then return nil end
    return a * 256 + b
  end
  if u16(1) ~= id then return nil, "id" end
  local rcode = data:byte(4) % 16
  if rcode ~= 0 then return nil, "rcode " .. rcode end
  local qd, an = u16(5), u16(7)
  local pos = 13
  local function skip_name()
    while true do
      local len = data:byte(pos)
      if not len then return false end
      if len >= 192 then pos = pos + 2 return true end
      pos = pos + 1
      if len == 0 then return true end
      pos = pos + len
    end
  end
  for _ = 1, qd do
    if not skip_name() then return nil, "bad" end
    pos = pos + 4
  end
  for _ = 1, an do
    if not skip_name() then return nil, "bad" end
    local typ, rdlen = u16(pos), u16(pos + 8)
    if not rdlen then return nil, "bad" end
    pos = pos + 10
    if typ == 1 and rdlen == 4 then
      local a, b, c, d = data:byte(pos, pos + 3)
      if d then return string.format("%d.%d.%d.%d", a, b, c, d) end
      return nil, "bad"
    end
    pos = pos + rdlen
  end
  return nil, "no A"
end

-- ip | nil, err; err == "unavailable" — своего DNS нет (нет UDP или nameserver), решать вызывающему
function http.resolve(host, timeout_s)
  if host:match("^%d+%.%d+%.%d+%.%d+$") then return host end
  if not (socket and socket.udp) then return nil, "unavailable" end
  local servers = http.nameservers()
  if #servers == 0 then return nil, "unavailable" end
  if http.clock() < http.dns_down_until then return nil, "timeout" end
  local udp = socket.udp()
  if not udp then return nil, "unavailable" end
  local deadline = http.clock() + math.min(timeout_s, DNS_TIMEOUT_S)
  local id = math.random(0, 65535)
  local q = http._dns_query(host, id)
  for _, ns in ipairs(servers) do udp:sendto(q, ns, 53) end
  local answers, last_err = 0, "timeout"
  while true do
    local left = deadline - http.clock()
    if left <= 0 then last_err = "timeout" break end
    udp:settimeout(left)
    local data, from = udp:receivefrom()
    if not data then last_err = tostring(from) break end
    local ip, err = http._dns_parse(data, id)
    if ip then
      udp:close()
      return ip
    end
    if err ~= "id" then
      -- отказ сервера; ждём остальных, пока не ответили все
      answers, last_err = answers + 1, err
      if answers >= #servers then break end
    end
  end
  udp:close()
  if last_err == "timeout" then http.dns_down_until = http.clock() + DNS_DOWN_S end
  return nil, last_err
end

-- прогрев кэша DNS: вызывать вне ожидания ответа, когда Wi‑Fi уже есть; не дольше WARM_BUDGET_S
function http.warm(hosts)
  if not socket or not http.online() then return end
  local deadline = http.clock() + WARM_BUDGET_S
  for _, host in ipairs(hosts) do
    local left = deadline - http.clock()
    if left <= 0 then return end
    local ok, ip, err = pcall(http.resolve, host, math.min(left, 1.5))
    if ok and ip then
      http.dns_cache[host] = ip
    elseif ok and err == "unavailable" and socket.dns then
      -- своего DNS нет: блокирующий getaddrinfo, как раньше
      local ok2, ip2 = pcall(socket.dns.toip, host)
      if ok2 and type(ip2) == "string" then http.dns_cache[host] = ip2 end
    end
  end
end

-- create для luasocket http.request: сокет с таймаутом = остаток дедлайна на каждую операцию.
-- state.phase — операция, идущая сейчас (последняя начатая): connect | tls | send | wait (ответа ещё нет: первый receive) |
-- read (после первого байта ответа); при сбое это фаза обрыва
local function make_create(remaining, state)
  return function()
    local sock, err = socket.tcp()
    if not sock then return nil, err end
    local conn = {}

    -- выставить остаток; false — время вышло
    local function arm()
      local left = remaining()
      if left <= 0 then return false end
      sock:settimeout(left)
      return true
    end

    function conn:settimeout() return 1 end -- таймауты ставим сами перед каждой операцией

    function conn:connect(host, port)
      state.phase = "connect"
      if not arm() then return nil, "timeout" end
      local ip = http.dns_cache[host]
      local ok, cerr = sock:connect(ip or host, port)
      if not ok then
        http.dns_cache[host] = nil
        return nil, cerr
      end
      if not ip then
        local peer = sock:getpeername()
        if peer then http.dns_cache[host] = peer end
      end
      state.phase = "tls"
      if not arm() then return nil, "timeout" end
      local wrapped, werr = ssl.wrap(sock, http.tls)
      if not wrapped then return nil, werr end
      sock = wrapped
      if sock.sni then sock:sni(host) end
      if not arm() then return nil, "timeout" end
      local hs_ok, hs_err = sock:dohandshake()
      if not hs_ok then return nil, hs_err end
      return 1
    end

    function conn:send(...)
      state.phase = "send"
      if not arm() then return nil, "timeout" end
      return sock:send(...)
    end

    local answered = false
    function conn:receive(...)
      state.phase = answered and "read" or "wait"
      if not arm() then return nil, "timeout" end
      local data, rerr, partial = sock:receive(...)
      if data or (partial and partial ~= "") then answered = true end
      return data, rerr, partial
    end

    function conn:close() return sock:close() end

    -- остальные методы сокета (getstats, shutdown, …) — как есть
    return setmetatable(conn, {
      __index = function(_, key)
        local f = sock[key]
        if type(f) == "function" then
          return function(_, ...) return f(sock, ...) end
        end
      end,
    })
  end
end

-- третье значение "lua" — запрос упал Lua-ошибкой, а не сетевым сбоем; четвёртое — заголовки ответа
local function run(request, reqt, parts)
  local ok, res, code, headers = pcall(request, reqt)
  if not ok then return nil, tostring(res), "lua" end
  if not res then return nil, tostring(code) end
  if type(code) ~= "number" then return nil, tostring(code) end
  return code, table.concat(parts), nil, headers or {}
end

-- sink собирает ответ; по истечении дедлайна обрывает запрос
local function make_sink(parts, deadline)
  return function(chunk)
    if chunk then
      if http.clock() > deadline then return nil, "timeout" end
      parts[#parts + 1] = chunk
    end
    return 1
  end
end

-- тело и его заголовок; без тела (GET) — ни source, ни Content-Length
local function make_source(body, hdrs)
  if body == nil then return nil end
  hdrs["Content-Length"] = tostring(#body)
  local sent = false
  return function()
    if sent or #body == 0 then return nil end
    sent = true
    return body
  end
end

local function request_direct(method, url, headers, body, timeout_s)
  local host, port, rest = url:match("^https://([^/:?#]+):?(%d*)(.*)$")
  if not host then return nil, "unsupported url" end
  port = tonumber(port) or 443
  local deadline = http.clock() + timeout_s
  -- IP в кэше — DNS не нужен, пробуем (isConnected мог ошибиться); но если сети нет и попытка не
  -- удалась — причина «offline», а не текст ошибки сокета. Иначе без сети getaddrinfo повис бы сверх дедлайна
  local offline_hint = http.dns_cache[host] ~= nil and not http.online()
  if not http.dns_cache[host] then
    if not http.online() then return nil, "offline" end
    local ip, err = http.resolve(host, timeout_s)
    if ip then
      http.dns_cache[host] = ip
    elseif err ~= "unavailable" then
      return nil, "dns: " .. tostring(err)
    end
  end
  local path, query = rest:match("^([^?]*)%??(.*)$")
  if path == "" then path = "/" end
  if query == "" then query = nil end

  local hdrs = copy(headers)
  hdrs.Host = port == 443 and host or (host .. ":" .. port)

  local parts, state = {}, {}
  local status, resp, kind, resp_headers = run(shttp.request, {
    method = method,
    scheme = "https", -- без url luasocket берёт схему отсюда (SCHEMES[reqt.scheme], иначе nil-индекс)
    host = host,
    port = port,
    path = path,
    query = query,
    headers = hdrs,
    source = make_source(body, hdrs),
    sink = make_sink(parts, deadline),
    create = make_create(function() return deadline - http.clock() end, state),
  }, parts)
  if status == nil and offline_hint and kind ~= "lua" then return nil, "offline" end
  -- сбой — четвёртым фаза обрыва вместо заголовков
  if status == nil then return nil, resp, kind, state.phase end
  return status, resp, kind, resp_headers
end

local function request_simple(method, url, headers, body, timeout_s)
  if not https then return nil, "ssl.https unavailable" end
  if not http.online() then return nil, "offline" end
  local hdrs = copy(headers)
  local deadline = http.clock() + timeout_s
  local parts = {}

  -- luasec ставит сокетам ssl.https.TIMEOUT (conn:settimeout игнорирует аргумент)
  https.TIMEOUT = timeout_s

  local source = make_source(body, hdrs)
  local status, resp, _, resp_headers = run(https.request, {
    url = url,
    method = method,
    headers = hdrs,
    source = source,
    sink = make_sink(parts, deadline),
  }, parts)
  return status, resp, resp_headers
end

-- процентное кодирование (RFC 3986): всё, кроме букв, цифр и - _ . ~ — %XX побайтно. Для параметра URL
-- (курсор Notion) и значения формы application/x-www-form-urlencoded (запрос Overpass)
function http.urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- request(method, url, headers, body | nil, timeout_s) -> status, body, headers | nil, err, phase
-- headers ответа — как отдал luasocket (имена в нижнем регистре); phase — фаза обрыва прямого пути (make_create) | nil
function http.request(method, url, headers, body, timeout_s)
  if not (shttp and ssl) then return request_simple(method, url, headers, body, timeout_s) end
  local t0 = http.clock()
  local ok, status, resp, lua_err, resp_headers = pcall(request_direct, method, url, headers, body, timeout_s)
  if ok and lua_err ~= "lua" then return status, resp, resp_headers end
  local why = ok and resp or status
  pcall(http.log, "riddle: http direct path failed, fallback to ssl.https: " .. tostring(why))
  local left = timeout_s - (http.clock() - t0)
  if left <= 0 then return nil, "timeout" end
  return request_simple(method, url, headers, body, left)
end

-- post(url, headers, body, timeout_s) -> status, body | nil, err, phase (фаза обрыва — для лога цепочки)
function http.post(url, headers, body, timeout_s)
  local status, resp, phase = http.request("POST", url, headers, body, timeout_s)
  if status == nil then return nil, resp, phase end
  return status, resp
end

return http
