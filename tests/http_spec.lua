-- Фейковый ssl.https через package.preload: luasec на Mac не ставим.
local t = require("t")

local fake = {}
local function install(handler)
  fake.calls = {}
  package.loaded["ssl.https"] = nil
  package.loaded["riddle.http"] = nil
  package.preload["ssl.https"] = function()
    -- как в luasec: сокетам ставится ssl.https.TIMEOUT (по умолчанию 60), поле reqt.timeout не читается
    local mod = { TIMEOUT = 60 }
    function mod.request(reqt)
      fake.calls[#fake.calls + 1] = reqt
      fake.https_timeout = mod.TIMEOUT
      return handler(reqt)
    end
    fake.mod = mod
    return mod
  end
  return require("riddle.http")
end

-- читает тело запроса из reqt.source, как это делает luasocket
local function read_source(reqt)
  local parts = {}
  while true do
    local chunk = reqt.source()
    if not chunk then break end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

local tests = {}

function tests.test_post_ok_returns_status_and_body()
  local http = install(function(reqt)
    reqt.sink('{"ok":')
    reqt.sink("true}")
    reqt.sink(nil)
    return 1, 200, {}, "HTTP/1.1 200 OK"
  end)
  local status, body = http.post("https://x.test/v1", { ["Content-Type"] = "application/json" }, "{}", 3)
  t.eq(status, 200)
  t.eq(body, '{"ok":true}')
end

function tests.test_post_sends_method_url_body_headers()
  local http = install(function(reqt)
    t.eq(read_source(reqt), '{"a":"привет"}', "тело ушло целиком")
    return 1, 200, {}, "OK"
  end)
  http.post("https://x.test/v1", { ["User-Agent"] = "riddle-diary/1.0", Authorization = "Bearer tok" },
    '{"a":"привет"}', 3)
  local r = fake.calls[1]
  t.eq(r.method, "POST")
  t.eq(r.url, "https://x.test/v1")
  t.eq(r.headers["User-Agent"], "riddle-diary/1.0")
  t.eq(r.headers.Authorization, "Bearer tok")
  t.eq(r.headers["Content-Length"], tostring(#'{"a":"привет"}'), "длина в байтах")
end

function tests.test_post_does_not_mutate_caller_headers()
  local http = install(function() return 1, 200, {}, "OK" end)
  local h = { ["User-Agent"] = "x" }
  http.post("https://x.test", h, "{}", 3)
  t.eq(h["Content-Length"], nil)
end

function tests.test_post_sets_ssl_https_timeout()
  local http = install(function() return 1, 200, {}, "OK" end)
  http.post("https://x.test", {}, "{}", 2.5)
  t.eq(fake.https_timeout, 2.5, "luasec берёт таймаут из ssl.https.TIMEOUT")
end

function tests.test_each_post_resets_ssl_https_timeout()
  local http = install(function() return 1, 200, {}, "OK" end)
  http.post("https://x.test", {}, "{}", 2.5)
  http.post("https://x.test", {}, "{}", 1)
  t.eq(fake.https_timeout, 1)
end

function tests.test_simple_path_offline_returns_immediately()
  local http = install(function() error("в сеть не ходим") end)
  http.online = function() return false end
  local status, err = http.post("https://x.test", {}, "{}", 3)
  t.eq(status, nil)
  t.eq(err, "offline")
  t.eq(#fake.calls, 0)
end

function tests.test_post_non_200_is_returned_not_error()
  local http = install(function(reqt)
    reqt.sink("rate limited")
    return 1, 429, {}, "Too Many Requests"
  end)
  local status, body = http.post("https://x.test", {}, "{}", 3)
  t.eq(status, 429)
  t.eq(body, "rate limited")
end

function tests.test_post_network_error_is_nil_err()
  local http = install(function() return nil, "timeout" end)
  local status, err = http.post("https://x.test", {}, "{}", 3)
  t.eq(status, nil)
  t.eq(err, "timeout")
end

function tests.test_post_string_code_is_error()
  -- luasocket при ошибке соединения возвращает 1, "connection refused"
  local http = install(function() return 1, "connection refused" end)
  local status, err = http.post("https://x.test", {}, "{}", 3)
  t.eq(status, nil)
  t.eq(err, "connection refused")
end

function tests.test_post_catches_thrown_error()
  local http = install(function() error("boom: luasec") end)
  local status, err = http.post("https://x.test", {}, "{}", 3)
  t.eq(status, nil)
  t.ok(tostring(err):find("boom", 1, true), "причина в err")
end

function tests.test_post_total_deadline_aborts_sink()
  local http
  http = install(function(reqt)
    reqt.sink("a")
    http.clock = function() return 100 end -- время вышло между порциями
    local ok2, why = reqt.sink("b")
    if not ok2 then return nil, why end
    return 1, 200, {}, "OK"
  end)
  http.clock = function() return 0 end
  local status, err = http.post("https://x.test", {}, "{}", 4)
  t.eq(status, nil)
  t.eq(err, "timeout")
end

function tests.test_post_empty_body_has_no_source_chunk()
  local http = install(function(reqt)
    t.eq(reqt.source(), nil)
    return 1, 200, {}, "OK"
  end)
  http.post("https://x.test", {}, "", 3)
end

function tests.test_missing_ssl_module_does_not_crash_on_load()
  package.preload["ssl.https"] = nil
  package.loaded["ssl.https"] = nil
  package.loaded["riddle.http"] = nil
  local http = require("riddle.http")
  local status, err = http.post("https://x.test", {}, "{}", 3)
  t.eq(status, nil)
  t.ok(err, "ошибка, а не падение")
end

-- кодирование для URL и формы — одна функция (курсор Notion, тело запроса Overpass)
function tests.test_urlencode()
  local http = require("riddle.http")
  t.eq(http.urlencode("aZ09-_.~"), "aZ09-_.~", "незарезервированные как есть")
  t.eq(http.urlencode('[out:json];way["a"=b] ,/'), "%5Bout%3Ajson%5D%3Bway%5B%22a%22%3Db%5D%20%2C%2F")
  t.eq(http.urlencode("é"), "%C3%A9", "UTF-8 побайтно")
  local p = assert(io.popen("grep -rlF '%%%02X' plugin/riddlediary.koplugin --include='*.lua'"))
  local hits = {}
  for l in p:lines() do hits[#hits + 1] = l end
  p:close()
  t.eq(table.concat(hits, ","), "plugin/riddlediary.koplugin/riddle/http.lua", "копий кодирования нет")
end

t.run(tests)
