-- Прямой путь http.post: свой create поверх socket.http + ssl.wrap, полный дедлайн на запрос.
-- Фейки socket/ssl/socket.http и фейковые часы: «зависание» = операция съедает весь выставленный
-- ей таймаут и возвращает nil, "timeout" (как luasocket).
local t = require("t")

local clock
local env -- настройки сценария и журнал
local dns_response -- ниже: ответ DNS на запрос

local function advance(dt) clock = clock + dt end

-- операция с «стоимостью»: съедает min(cost, таймаут), при нехватке — timeout
local function spend(sock, cost)
  local limit = sock.timeout or math.huge
  if cost == "hang" or cost > limit then
    advance(limit)
    return false
  end
  advance(cost)
  return true
end

local function new_sock(kind)
  local s = { kind = kind }
  function s:settimeout(v)
    self.timeout = v
    env.timeouts[#env.timeouts + 1] = kind .. ":" .. tostring(v)
    return 1
  end
  function s:close() env.closed = (env.closed or 0) + 1 return 1 end
  return s
end

local function install(opts)
  clock = 0
  env = {
    timeouts = {}, connects = {}, wraps = 0, snis = {}, requests = {},
    connect_cost = opts.connect_cost or 0,
    handshake_cost = opts.handshake_cost or 0,
    receive_cost = opts.receive_cost or 0,
    send_cost = opts.send_cost or 0,
    connect_err = opts.connect_err,
  }
  for _, m in ipairs({ "socket", "socket.http", "ssl", "ssl.https", "riddle.http", "ui/network/manager" }) do
    package.loaded[m] = nil
    package.preload[m] = nil
  end

  local tcp_sock = function()
    local s = new_sock("tcp")
    function s:connect(host, port)
      env.connects[#env.connects + 1] = host .. ":" .. tostring(port)
      if env.connect_err then return nil, env.connect_err end
      if not spend(self, env.connect_cost) then return nil, "timeout" end
      return 1
    end
    function s:getpeername() return "1.2.3.4", 443 end
    return s
  end

  -- UDP для своего DNS-резолвера: только если сценарий задал opts.dns ("answer" | "hang" | "nx")
  local udp_sock = opts.dns and function()
    local s = new_sock("udp")
    function s:sendto(data, ip, port)
      env.dns_sent[#env.dns_sent + 1] = { data = data, ip = ip, port = port }
      return #data
    end
    function s:receivefrom()
      local q = env.dns_sent[#env.dns_sent]
      if opts.dns == "hang" or not q then
        spend(self, "hang")
        return nil, "timeout"
      end
      advance(opts.dns_cost or 0.01)
      return env.dns_response(q.data, opts.dns), q.ip, 53
    end
    return s
  end
  env.dns_sent = {}
  env.dns_response = function(q, mode) return dns_response(q, mode) end

  package.preload["socket"] = function()
    return {
      tcp = tcp_sock,
      udp = udp_sock,
      gettime = function() return clock end,
      dns = { toip = function(host) env.resolved = (env.resolved or "") .. host .. ";" return "9.9.9.9" end },
    }
  end

  if opts.https then
    package.preload["ssl.https"] = function()
      return {
        TIMEOUT = 60,
        request = function(reqt)
          env.simple = { reqt = reqt, at = clock }
          reqt.sink('{"simple":true}')
          return 1, 200, {}, "HTTP/1.1 200 OK"
        end,
      }
    end
  end

  package.preload["ssl"] = function()
    return {
      wrap = function(sock, params)
        env.wraps = env.wraps + 1
        env.wrap_params = params
        local w = new_sock("tls")
        function w:sni(host) env.snis[#env.snis + 1] = host end
        function w:dohandshake()
          if not spend(self, env.handshake_cost) then return nil, "timeout" end
          return 1
        end
        function w:send(data)
          if not spend(self, env.send_cost) then return nil, "timeout" end
          env.sent = (env.sent or "") .. data
          return #data
        end
        function w:receive(pattern)
          -- receive_costs — стоимость по очереди вызовов (строка статуса, тело); иначе receive_cost на каждый
          local cost = env.receive_cost
          if opts.receive_costs then
            env.receives = (env.receives or 0) + 1
            cost = opts.receive_costs[env.receives] or 0
          end
          if not spend(self, cost) then return nil, "timeout" end
          if pattern == "*l" then return "HTTP/1.1 200 OK" end
          return opts.body or '{"ok":true}'
        end
        return w
      end,
    }
  end

  -- моделируем порядок вызовов luasocket http.request
  package.preload["socket.http"] = function()
    return {
      TIMEOUT = 60,
      request = function(reqt)
        env.requests[#env.requests + 1] = reqt
        -- как luasocket KOReader (common/socket/http.lua:234): без url схема берётся из reqt.scheme
        if not reqt.url and reqt.scheme ~= "https" then
          error("common/socket/http.lua:234: attempt to index a nil value")
        end
        if opts.request_throws then
          advance(opts.request_throws)
          error("attempt to call method 'getfd' (a nil value)")
        end
        local c = reqt.create()
        c:settimeout(60)
        local ok, err = c:connect(reqt.host, reqt.port)
        if not ok then return nil, err end
        local req_body = reqt.source and reqt.source() or ""
        local ok2, err2 = c:send(reqt.method .. " " .. (reqt.path or "/") .. " HTTP/1.1\r\n\r\n" .. req_body)
        if not ok2 then return nil, err2 end
        local line, err3 = c:receive("*l")
        if not line then return nil, err3 end
        local body, err4 = c:receive("*a")
        if not body then return nil, err4 end
        reqt.sink(body)
        c:close()
        return 1, opts.status or 200, opts.resp_headers or {}, line
      end,
    }
  end

  local http = require("riddle.http")
  http.nameservers = function() return opts.nameservers or { "10.0.0.1" } end
  return http
end

-- ответ DNS на запрос q: CNAME со сжатым именем, затем A 5.6.7.8 (как у Cloudflare/Google)
local function u16(n) return string.char(math.floor(n / 256), n % 256) end
function dns_response(q, mode)
  local id = q:sub(1, 2)
  local question = q:sub(13)
  if mode == "nx" then
    return id .. "\129\131" .. u16(1) .. u16(0) .. u16(0) .. u16(0) .. question
  end
  local cname = "\3cdn\192\12" -- cdn.<имя из вопроса>
  local rr1 = "\192\12" .. u16(5) .. u16(1) .. "\0\0\0\60" .. u16(#cname) .. cname
  local rr2 = "\192\12" .. u16(1) .. u16(1) .. "\0\0\0\60" .. u16(4) .. "\5\6\7\8"
  return id .. "\129\128" .. u16(1) .. u16(2) .. u16(0) .. u16(0) .. question .. rr1 .. rr2
end

local tests = {}

function tests.test_direct_ok()
  local http = install({})
  local status, body = http.post("https://api.test/v1/chat?x=1", { ["User-Agent"] = "riddle-diary/1.0" }, '{"a":1}', 4)
  t.eq(status, 200)
  t.eq(body, '{"ok":true}')
  local r = env.requests[1]
  t.eq(r.host, "api.test")
  t.eq(r.port, 443)
  t.eq(r.path, "/v1/chat")
  t.eq(r.query, "x=1")
  t.eq(r.method, "POST")
  t.eq(r.headers.Host, "api.test", "Host без порта")
  t.eq(r.headers["User-Agent"], "riddle-diary/1.0")
  t.eq(r.headers["Content-Length"], "7")
  t.eq(env.connects[1], "api.test:443", "первый раз — по имени")
  t.eq(env.snis[1], "api.test", "SNI = имя хоста")
  t.eq(env.wrap_params.mode, "client")
  t.ok(env.sent:find('{"a":1}', 1, true), "тело ушло")
end

function tests.test_get_sends_method_without_body()
  local http = install({ https = true, status = 429, resp_headers = { ["retry-after"] = "2" } })
  local logs = {}
  http.log = function(msg) logs[#logs + 1] = msg end
  local status, body, headers = http.request("GET", "https://api.test/v1/blocks/x/children?page_size=100",
    { Accept = "application/json" }, nil, 4)
  t.eq(status, 429)
  t.eq(body, '{"ok":true}')
  t.eq(headers and headers["retry-after"], "2", "заголовки ответа — третьим значением")
  local r = env.requests[1]
  t.eq(r.method, "GET")
  t.eq(r.path, "/v1/blocks/x/children")
  t.eq(r.query, "page_size=100")
  t.eq(r.source, nil, "у GET нет тела")
  t.eq(r.headers["Content-Length"], nil, "у GET нет Content-Length")
  t.eq(r.headers.Accept, "application/json")
  t.eq(#logs, 0, "без фолбэка")
end

function tests.test_post_is_request_post()
  local http = install({})
  local status, body = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, 200)
  t.eq(body, '{"ok":true}')
  t.eq(env.requests[1].method, "POST")
  t.eq(env.requests[1].headers["Content-Length"], "2")
end

function tests.test_direct_names_https_scheme_without_fallback()
  local http = install({ https = true })
  local logs = {}
  http.log = function(msg) logs[#logs + 1] = msg end
  local status, body = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, 200)
  t.eq(body, '{"ok":true}', "ответ прямого пути, не запасного")
  t.eq(env.requests[1].scheme, "https")
  t.eq(#logs, 0, "фолбэка не было")
end

function tests.test_direct_default_path_is_root()
  local http = install({})
  http.post("https://api.test", {}, "{}", 4)
  t.eq(env.requests[1].path, "/")
end

function tests.test_direct_second_call_uses_cached_ip()
  local http = install({})
  http.post("https://api.test/v1", {}, "{}", 4)
  http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(env.connects[2], "1.2.3.4:443", "IP из первого соединения")
  t.eq(env.snis[2], "api.test", "SNI всё равно по имени")
  t.eq(env.requests[2].headers.Host, "api.test")
end

function tests.test_direct_connect_failure_drops_cached_ip()
  local http = install({})
  http.post("https://api.test/v1", {}, "{}", 4)
  env.connect_err = "connection refused"
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "connection refused")
  env.connect_err = nil
  http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(env.connects[#env.connects], "api.test:443", "после провала снова по имени")
end

function tests.test_direct_hung_receive_returns_timeout_within_budget()
  local http = install({ connect_cost = 1, handshake_cost = 1, send_cost = 1, receive_cost = "hang" })
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "timeout")
  t.ok(clock <= 4, "ушло " .. clock .. " с при дедлайне 4")
end

-- фаза обрыва — третьим значением post (в лог цепочки): luasec на таймаут чтения отдаёт "wantread" и в рукопожатии, и в
-- ожидании ответа (ssl.c: IO_TIMEOUT -> LSEC_IO_SSL -> ssl_ioerror "wantread"), по тексту ошибки их не различить
function tests.test_direct_failure_names_phase()
  local cases = {
    { { connect_cost = "hang" }, "connect" },
    { { handshake_cost = "hang" }, "tls" },
    { { send_cost = "hang" }, "send" },
    { { receive_cost = "hang" }, "wait" },
    { { receive_costs = { 0.5, "hang" } }, "read" },
  }
  for _, c in ipairs(cases) do
    local http = install(c[1])
    local status, err, phase = http.post("https://api.test/v1", {}, "{}", 4)
    t.eq(status, nil, c[2])
    t.eq(err, "timeout", c[2] .. ": текст ошибки прежний")
    t.eq(phase, c[2])
  end
  local http = install({})
  local status, body, phase = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, 200)
  t.eq(body, '{"ok":true}')
  t.eq(phase, nil, "у ответа фазы нет")
end

function tests.test_direct_hung_handshake_returns_timeout_within_budget()
  local http = install({ connect_cost = 2, handshake_cost = "hang" })
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "timeout")
  t.ok(clock <= 4, "ушло " .. clock .. " с")
end

function tests.test_direct_hung_connect_returns_timeout_within_budget()
  local http = install({ connect_cost = "hang" })
  local status, err = http.post("https://api.test/v1", {}, "{}", 3)
  t.eq(status, nil)
  t.eq(err, "timeout")
  t.ok(clock <= 3, "ушло " .. clock .. " с")
end

function tests.test_direct_slow_dns_then_no_more_operations()
  -- connect «уложился» ровно в дедлайн: на TLS времени не осталось, дальше не идём
  local http = install({ connect_cost = 4 })
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "timeout")
  t.eq(env.wraps, 0, "TLS не начинали")
  t.ok(clock <= 4)
end

function tests.test_direct_each_op_gets_remaining_time()
  local http = install({ connect_cost = 1, handshake_cost = 1, receive_cost = 0.5 })
  http.post("https://api.test/v1", {}, "{}", 4)
  -- tcp:connect — 4 с, handshake — 3 с, дальше остаток 2 с
  t.eq(env.timeouts[1], "tcp:4")
  local tls_first
  for _, v in ipairs(env.timeouts) do
    if v:find("^tls:") then tls_first = v break end
  end
  t.eq(tls_first, "tls:3")
end

function tests.test_direct_ignores_blocking_default_timeout_from_http()
  -- http.request зовёт c:settimeout(60); дедлайн всё равно наш
  local http = install({ connect_cost = 1, handshake_cost = 1, receive_cost = "hang" })
  http.post("https://api.test/v1", {}, "{}", 4)
  t.ok(clock <= 4)
end

function tests.test_non_https_url_is_error_not_crash()
  local http = install({})
  local status, err = http.post("http://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.ok(err)
end

function tests.test_warm_fills_cache_so_first_post_uses_ip()
  local http = install({})
  http.warm({ "api.test", "other.test" })
  t.eq(env.resolved, "api.test;other.test;")
  http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(env.connects[1], "9.9.9.9:443")
end

function tests.test_direct_offline_with_empty_cache_fails_fast()
  local http = install({})
  http.online = function() return false end
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "offline")
  t.eq(#env.connects, 0, "ни DNS, ни connect")
  t.eq(clock, 0)
end

function tests.test_direct_offline_with_cached_ip_still_tries()
  local http = install({})
  http.post("https://api.test/v1", {}, "{}", 4) -- кэш IP заполнен
  http.online = function() return false end
  local status = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, 200, "по IP DNS не нужен — пробуем")
end

-- Wi‑Fi пропал при прогретом кэше DNS: по IP пробуем (isConnected мог ошибиться), но сбой соединения
-- при «нет сети» — это offline, а не прочая ошибка / медленный ответ
function tests.test_direct_offline_with_cached_ip_and_failed_connect_is_offline()
  local http = install({})
  http.post("https://api.test/v1", {}, "{}", 4) -- кэш IP заполнен
  http.online = function() return false end
  env.connect_err = "Network is unreachable"
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "offline")
  t.eq(http.dns_cache["api.test"], nil, "неудачное соединение чистит кэш")
end

function tests.test_direct_offline_with_cached_ip_and_hung_connect_is_offline()
  local http = install({})
  http.post("https://api.test/v1", {}, "{}", 4)
  http.online = function() return false end
  env.connect_cost = "hang"
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "offline")
end

-- онлайн: сбой соединения остаётся собственной причиной
function tests.test_direct_online_failed_connect_keeps_its_error()
  local http = install({ connect_err = "connection refused" })
  http.dns_cache["api.test"] = "1.2.3.4"
  local _, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(err, "connection refused")
end

function tests.test_warm_skipped_when_offline()
  local http = install({})
  http.online = function() return false end
  http.warm({ "api.test" })
  t.eq(env.resolved, nil, "toip не вызывался")
end

function tests.test_default_online_follows_networkmgr_isconnected()
  local http = install({})
  local connected = false
  package.preload["ui/network/manager"] = function()
    return { isConnected = function(self) t.ok(self, "метод, не функция") return connected end }
  end
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "offline")
  connected = true
  t.eq((http.post("https://api.test/v1", {}, "{}", 4)), 200)
end

function tests.test_default_online_true_when_networkmgr_unusable()
  local http = install({})
  package.preload["ui/network/manager"] = function() return { isConnected = function() error("boom") end } end
  t.eq((http.post("https://api.test/v1", {}, "{}", 4)), 200, "сбой проверки — считаем, что онлайн")
  package.loaded["ui/network/manager"] = nil
  package.preload["ui/network/manager"] = function() return {} end
  t.eq((http.post("https://api.test/v1", {}, "{}", 4)), 200, "нет isConnected — онлайн")
end

-- свой DNS (UDP с таймаутом) ------------------------------------------------

function tests.test_dns_parse_cname_then_a()
  local http = install({})
  local q = http._dns_query("api.groq.com", 0x1234)
  t.eq(q:sub(1, 2), "\18\52", "id")
  t.ok(q:find("\3api\4groq\3com\0\0\1\0\1", 1, true), "QNAME + A/IN")
  t.eq(http._dns_parse(dns_response(q, "answer"), 0x1234), "5.6.7.8")
end

function tests.test_dns_parse_rejects_wrong_id_and_nxdomain()
  local http = install({})
  local q = http._dns_query("api.groq.com", 7)
  local ip, err = http._dns_parse(dns_response(q, "answer"), 8)
  t.eq(ip, nil)
  t.eq(err, "id")
  ip, err = http._dns_parse(dns_response(q, "nx"), 7)
  t.eq(ip, nil)
  t.eq(err, "rcode 3")
  t.eq((http._dns_parse("\0\7\129", 7)), nil, "обрывок не роняет")
end

function tests.test_resolve_sends_to_nameserver_port_53()
  local http = install({ dns = "answer", nameservers = { "10.0.0.1", "10.0.0.2" } })
  t.eq(http.resolve("api.test", 2), "5.6.7.8")
  t.eq(env.dns_sent[1].ip, "10.0.0.1")
  t.eq(env.dns_sent[1].port, 53)
  t.eq(env.dns_sent[2].ip, "10.0.0.2", "всем серверам сразу")
end

function tests.test_resolve_hang_times_out_within_budget()
  local http = install({ dns = "hang" })
  local ip, err = http.resolve("api.test", 1.5)
  t.eq(ip, nil)
  t.eq(err, "timeout")
  t.ok(clock <= 1.5, "ушло " .. clock .. " с")
end

function tests.test_post_dns_capped_and_remembered_so_chain_fails_fast()
  -- три провайдера подряд при молчащем DNS: первый ждёт ≤ 2 с, остальные — сразу отказ
  local http = install({ dns = "hang" })
  http.post("https://a.test/v1", {}, "{}", 4)
  t.ok(clock <= 2.01, "первый: " .. clock .. " с")
  local s2, e2 = http.post("https://b.test/v1", {}, "{}", 4)
  local s3 = http.post("https://c.test/v1", {}, "{}", 4)
  t.eq(s2, nil)
  t.eq(s3, nil)
  t.ok(e2:find("timeout", 1, true), e2)
  t.ok(clock <= 2.01, "всего " .. clock .. " с")
  -- сеть поднялась заново — память сбрасывается
  http.dns_reset()
  env.dns_sent = {}
  http.resolve("d.test", 1)
  t.eq(#env.dns_sent, 1, "после сброса снова спрашиваем")
end

function tests.test_resolve_ip_literal_without_network()
  local http = install({ dns = "hang" })
  t.eq(http.resolve("1.2.3.4", 1), "1.2.3.4")
  t.eq(#env.dns_sent, 0)
end

function tests.test_post_uses_own_dns_then_connects_by_ip_with_sni()
  local http = install({ dns = "answer" })
  local status = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, 200)
  t.eq(env.connects[1], "5.6.7.8:443", "getaddrinfo не нужен")
  t.eq(env.snis[1], "api.test")
  t.eq(env.requests[1].headers.Host, "api.test")
end

function tests.test_post_dns_hang_fails_within_deadline_without_connect()
  -- Wi‑Fi без интернета: DNS молчит; getaddrinfo висел бы сверх дедлайна
  local http = install({ dns = "hang" })
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "dns: timeout")
  t.eq(#env.connects, 0)
  t.ok(clock <= 4, "ушло " .. clock .. " с")
end

function tests.test_post_dns_nxdomain_fails_fast()
  local http = install({ dns = "nx" })
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "dns: rcode 3")
  t.ok(clock < 1)
end

function tests.test_post_without_nameservers_falls_back_to_name()
  local http = install({ dns = "answer", nameservers = {} })
  http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(env.connects[1], "api.test:443", "нет resolv.conf — как раньше, по имени")
end

function tests.test_warm_uses_own_dns_with_bounded_time()
  local http = install({ dns = "hang" })
  http.warm({ "a.test", "b.test", "c.test" })
  t.eq(env.resolved, nil, "блокирующий toip не зовётся")
  t.ok(clock <= 3.01, "прогрев ограничен: " .. clock .. " с")
end

function tests.test_warm_own_dns_fills_cache()
  local http = install({ dns = "answer" })
  http.warm({ "api.test" })
  t.eq(http.dns_cache["api.test"], "5.6.7.8")
end

-- запасной путь ssl.https при Lua-ошибке прямого -------------------------------

function tests.test_lua_error_in_direct_path_falls_back_to_simple()
  local http = install({ https = true, request_throws = 0.5 })
  local logs = {}
  http.log = function(msg) logs[#logs + 1] = msg end
  local status, body = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, 200)
  t.eq(body, '{"simple":true}')
  t.ok(logs[1] and logs[1]:find("getfd", 1, true), "причина в логе")
  t.eq(env.simple.reqt.url, "https://api.test/v1")
end

function tests.test_fallback_gets_only_remaining_time()
  local http = install({ https = true, request_throws = 1.5 })
  http.log = function() end
  http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(package.loaded["ssl.https"].TIMEOUT, 2.5, "4 с минус 1.5 с прямого пути")
end

function tests.test_network_error_does_not_fall_back()
  local http = install({ https = true, connect_err = "connection refused" })
  local status, err = http.post("https://api.test/v1", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "connection refused")
  t.eq(env.simple, nil, "сетевой сбой — не повод для второго запроса")
end

t.run(tests)
