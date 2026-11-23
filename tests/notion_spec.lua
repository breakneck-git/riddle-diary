-- Клиент Notion API: пагинация, data_sources, 429/Retry-After, 401 без токена, пауза между запросами,
-- текст тела по блокам. Поддельный request с журналом и поддельные часы.
local t = require("t")
local json = require("dkjson")
local notion = require("riddle.notion")

local TOKEN = "secret_abc123"

-- route(method, url, body_tbl) -> status, body_tbl_or_string, headers
local function fake(route)
  local env = { calls = {}, sleeps = {}, now = 100 }
  env.request = function(method, url, headers, body, timeout_s)
    env.calls[#env.calls + 1] = {
      method = method, url = url, headers = headers, at = env.now, timeout_s = timeout_s,
      body = body and json.decode(body) or nil,
    }
    local status, resp, hdrs = route(method, url, env.calls[#env.calls].body, #env.calls)
    if status == nil then return nil, resp end
    if type(resp) == "table" then resp = json.encode(resp) end
    return status, resp, hdrs or {}
  end
  env.client = notion.new({
    token = TOKEN,
    request = env.request,
    sleep = function(s) env.sleeps[#env.sleeps + 1] = s env.now = env.now + s end,
    clock = function() return env.now end,
  })
  return env
end

local function list(results, next_cursor)
  return { object = "list", results = results, has_more = next_cursor ~= nil, next_cursor = next_cursor }
end

local tests = {}

function tests.test_search_paginates_until_has_more_false()
  local env = fake(function(method, url, body)
    if not body.start_cursor then return 200, list({ { object = "page", id = "a" } }, "c2") end
    if body.start_cursor == "c2" then return 200, list({ { object = "data_source", id = "b" } }, "c3") end
    return 200, list({ { object = "page", id = "c" } }, nil)
  end)
  local objs, err = env.client:search_all()
  t.eq(err, nil)
  t.eq(#objs, 3)
  t.eq(objs[1].id .. objs[2].id .. objs[3].id, "abc")
  t.eq(#env.calls, 3)
  local c = env.calls[1]
  t.eq(c.method, "POST")
  t.eq(c.url, "https://api.notion.com/v1/search")
  t.eq(c.headers.Authorization, "Bearer " .. TOKEN)
  t.eq(c.headers["Notion-Version"], "2025-09-03")
  t.eq(c.headers["Content-Type"], "application/json")
  t.eq(c.body.page_size, 100)
  t.eq(env.calls[3].body.start_cursor, "c3")
  t.eq(c.timeout_s, 20)
end

function tests.test_query_uses_data_sources_path()
  local env = fake(function(method, url, body)
    if not body.start_cursor then return 200, list({ { id = "r1" } }, "n") end
    return 200, list({ { id = "r2" } }, nil)
  end)
  local pages, err = env.client:query_all("ds-1")
  t.eq(err, nil)
  t.eq(#pages, 2)
  t.eq(env.calls[1].method, "POST")
  t.eq(env.calls[1].url, "https://api.notion.com/v1/data_sources/ds-1/query")
  t.eq(env.calls[2].body.start_cursor, "n")
end

-- неполный список нельзя выдавать за полный: sync по нему удалил бы всё за обрезом
function tests.test_incomplete_request_status_is_error()
  local env = fake(function()
    local l = list({ { id = "r1" } }, nil) -- после 10 000-го результата has_more = false
    l.request_status = { type = "incomplete", incomplete_reason = "query_result_limit_reached" }
    return 200, l
  end)
  local pages, err = env.client:query_all("ds-1")
  t.eq(pages, nil)
  t.eq(err, "incomplete")
  local env2 = fake(function()
    local l = list({ { id = "a" } }, nil)
    l.request_status = { type = "incomplete" }
    return 200, l
  end)
  local objs, err2 = env2.client:search_all()
  t.eq(objs, nil)
  t.eq(err2, "incomplete")
end

function tests.test_complete_request_status_is_ok()
  local env = fake(function()
    local l = list({ { id = "r1" } }, nil)
    l.request_status = { type = "complete" }
    return 200, l
  end)
  local pages, err = env.client:query_all("ds-1")
  t.eq(err, nil)
  t.eq(#pages, 1)
end

function tests.test_has_more_without_cursor_is_error()
  local env = fake(function()
    return 200, { object = "list", results = { { id = "a" } }, has_more = true, next_cursor = nil }
  end)
  local objs, err = env.client:search_all()
  t.eq(objs, nil)
  t.eq(err, "incomplete")
end

function tests.test_pages_limit_exhausted_is_error()
  local env = fake(function(_, _, body)
    local n = tonumber(body.start_cursor or "0")
    return 200, list({ { id = tostring(n) } }, tostring(n + 1)) -- курсор не кончается
  end)
  env.client.min_interval_s = 0
  local objs, err = env.client:search_all()
  t.eq(objs, nil)
  t.eq(err, "incomplete")
  t.eq(#env.calls, notion.MAX_PAGES, "не больше MAX_PAGES запросов")
end

function tests.test_query_rejects_strange_id()
  local env = fake(function() return 200, list({}, nil) end)
  local pages, err = env.client:query_all("../search")
  t.eq(pages, nil)
  t.eq(err, "bad id")
  t.eq(#env.calls, 0)
end

-- GET /v1/<kind>/<id>: предок базы вне поиска (глубина); другой kind и странный id — без запроса
function tests.test_get_builds_path_and_rejects_bad_id()
  local env = fake(function(method, url)
    if url:match("/v1/pages/gone$") then return 404, { object = "error", code = "object_not_found" } end
    return 200, { object = "page", id = "abc-1", in_trash = true }
  end)
  for _, kind in ipairs({ "pages", "blocks", "data_sources" }) do
    local obj, err = env.client:get(kind, "abc-1")
    t.eq(err, nil)
    t.eq(obj.id, "abc-1")
    local c = env.calls[#env.calls]
    t.eq(c.method, "GET")
    t.eq(c.url, "https://api.notion.com/v1/" .. kind .. "/abc-1")
    t.eq(c.body, nil)
  end
  local n = #env.calls
  local obj, err = env.client:get("pages", "../search")
  t.eq(obj, nil)
  t.eq(err, "bad id")
  obj, err = env.client:get("users", "abc-1")
  t.eq(obj, nil)
  t.eq(err, "bad kind")
  t.eq(#env.calls, n, "без запроса")
  obj, err = env.client:get("pages", "gone")
  t.eq(obj, nil)
  t.eq(err, "http 404 object_not_found")
end

function tests.test_429_waits_retry_after()
  local env = fake(function(_, _, _, n)
    if n == 1 then return 429, { object = "error", code = "rate_limited" }, { ["retry-after"] = "2" } end
    return 200, list({ { id = "a" } }, nil)
  end)
  local objs, err = env.client:search_all()
  t.eq(err, nil)
  t.eq(#objs, 1)
  t.eq(env.sleeps[1], 2, "Retry-After: 2")
  t.eq(#env.calls, 2)
end

function tests.test_429_without_header_waits_one_second_and_gives_up_after_five_retries()
  local env = fake(function() return 429, { object = "error", code = "rate_limited" } end)
  local objs, err = env.client:search_all()
  t.eq(objs, nil)
  t.eq(err, "http 429")
  t.eq(#env.calls, 6, "1 + 5 повторов")
  t.eq(env.sleeps[1], 1)
end

-- 529 — Notion перегружен: повторяем так же, как 429
function tests.test_529_retried_like_429()
  local env = fake(function(_, _, _, n)
    if n == 1 then return 529, { object = "error", code = "service_unavailable" }, { ["retry-after"] = "2" } end
    return 200, list({ { id = "a" } }, nil)
  end)
  local objs, err = env.client:search_all()
  t.eq(err, nil)
  t.eq(#objs, 1)
  t.eq(env.sleeps[1], 2, "Retry-After: 2")
  local env2 = fake(function() return 529, { object = "error" } end)
  local objs2, err2 = env2.client:search_all()
  t.eq(objs2, nil)
  t.eq(err2, "http 529")
  t.eq(#env2.calls, 6, "1 + 5 повторов")
  t.eq(env2.sleeps[1], 1, "без Retry-After — 1 с")
end

function tests.test_429_with_huge_retry_after_gives_up()
  local env = fake(function() return 429, {}, { ["retry-after"] = "3600" } end)
  local _, err = env.client:search_all()
  t.eq(err, "http 429")
  t.eq(#env.calls, 1, "час не ждём")
end

function tests.test_401_is_unauthorized_without_token()
  local env = fake(function()
    return 401, { object = "error", status = 401, code = "unauthorized",
      message = "API token is invalid: " .. TOKEN }
  end)
  local objs, err = env.client:search_all()
  t.eq(objs, nil)
  t.eq(err, "unauthorized")
  t.ok(not tostring(err):find("abc123", 1, true))
end

function tests.test_403_is_unauthorized()
  local env = fake(function() return 403, { object = "error", code = "restricted_resource" } end)
  local _, err = env.client:query_all("ds")
  t.eq(err, "unauthorized")
end

function tests.test_other_status_has_code_but_not_message()
  local env = fake(function()
    return 400, { object = "error", code = "validation_error", message = "body failed: " .. TOKEN }
  end)
  local _, err = env.client:search_all()
  t.eq(err, "http 400 validation_error")
  local env2 = fake(function() return 502, "<html>bad gateway " .. TOKEN .. "</html>" end)
  local _, err2 = env2.client:search_all()
  t.eq(err2, "http 502")
end

function tests.test_transport_error_and_bad_json()
  local env = fake(function() return nil, "timeout" end)
  local _, err = env.client:search_all()
  t.eq(err, "timeout")
  local env2 = fake(function() return 200, "not json" end)
  local _, err2 = env2.client:search_all()
  t.eq(err2, "bad json")
end

function tests.test_min_interval_between_requests()
  local env = fake(function(_, _, body)
    local n = tonumber(body.start_cursor or "0")
    if n < 3 then return 200, list({ { id = tostring(n) } }, tostring(n + 1)) end
    return 200, list({}, nil)
  end)
  env.client:search_all()
  t.eq(#env.calls, 4)
  for i = 2, #env.calls do
    t.ok(env.calls[i].at - env.calls[i - 1].at >= 0.34 - 1e-9, "между запросами ≥ 0.34 с, шаг " .. i)
  end
end

function tests.test_no_sleep_when_interval_already_passed()
  local env = fake(function() return 200, list({}, nil) end)
  env.client:search_all()
  env.now = env.now + 5
  env.client:search_all()
  t.eq(#env.sleeps, 0)
end

-- дерево блоков: id -> { блоки }, у блока с has_children дети лежат под его id
local function block(id, text, children)
  return { object = "block", id = id, type = "paragraph", has_children = children or false,
    paragraph = { rich_text = { { plain_text = text } } } }
end

local function blocks_env(tree)
  return fake(function(method, url)
    local id, query = url:match("/v1/blocks/([^/]+)/children%?(.*)$")
    assert(method == "GET", "блоки — GET")
    local cursor = query:match("start_cursor=([^&]+)")
    local list_all = tree[id] or {}
    if tree[id .. "#2"] and not cursor then return 200, list(list_all, "p2") end
    if cursor == "p2" then return 200, list(tree[id .. "#2"], nil) end
    return 200, list(list_all, nil)
  end)
end

-- курсор страницы тела уходит в адрес закодированным: «&», «=», «+», «/» и пробел в сыром виде ломают запрос
-- (следующая страница пришла бы не с того места или Notion ответил бы 400)
function tests.test_blocks_cursor_is_url_encoded()
  local raw = "a b/c=d+e&f"
  local env = fake(function(method, url)
    local cursor = url:match("start_cursor=([^&]*)")
    if not cursor then return 200, list({ { object = "block", id = "b1", type = "paragraph", has_children = false,
      paragraph = { rich_text = { { plain_text = "первый" } } } } }, raw) end
    return 200, list({ { object = "block", id = "b2", type = "paragraph", has_children = false,
      paragraph = { rich_text = { { plain_text = "второй" } } } } }, nil)
  end)
  local text = env.client:blocks_text("page")
  t.eq(text, "первый\nвторой")
  t.eq(#env.calls, 2)
  t.eq(env.calls[2].url:match("start_cursor=(.*)$"), "a%20b%2Fc%3Dd%2Be%26f", "курсор закодирован целиком")
end

function tests.test_blocks_recursion_depth_and_cap()
  local env = blocks_env({
    page = { block("b1", "один", true), block("b5", "пять") },
    b1 = { block("b2", "два", true) },
    b2 = { block("b3", "три", true) },
    b3 = { block("b4", "четыре") },
  })
  local text, err = env.client:blocks_text("page")
  t.eq(err, nil)
  t.eq(text, "один\nдва\nтри\nпять", "глубина ≤ 3")
  for _, c in ipairs(env.calls) do
    t.ok(not c.url:find("/blocks/b3/", 1, true), "детей третьего уровня не читаем")
  end
  t.ok(env.calls[1].url:find("page_size=100", 1, true))

  local long = string.rep("я", 30)
  local env2 = blocks_env({
    page = { block("x1", long), block("x2", long) },
    ["page#2"] = { block("x3", long) },
  })
  local capped = env2.client:blocks_text("page", 40)
  t.eq(select(2, capped:gsub("[^\128-\191]", "")), 40, "обрезка по знакам, не байтам")
  t.eq(#env2.calls, 1, "после лимита следующие страницы не читаем")
end

function tests.test_blocks_child_pages_not_recursed_and_table_rows()
  local env = blocks_env({
    page = {
      { id = "cp", type = "child_page", has_children = true, child_page = { title = "Вложенная" } },
      { id = "cd", type = "child_database", has_children = true, child_database = { title = "База" } },
      { id = "tb", type = "table", has_children = true, table = { table_width = 2 } },
      { id = "tr", type = "to_do", has_children = false, to_do = { rich_text = { { plain_text = "купить" } } } },
      { id = "dl", type = "paragraph", in_trash = true, paragraph = { rich_text = { { plain_text = "удалено" } } } },
      { id = "dv", type = "divider", has_children = false, divider = {} },
    },
    tb = {
      { id = "r1", type = "table_row", has_children = false,
        table_row = { cells = { { { plain_text = "а" } }, { { plain_text = "б" }, { plain_text = "в" } } } } },
    },
  })
  local text = env.client:blocks_text("page")
  t.eq(text, "а | бв\nкупить")
  for _, c in ipairs(env.calls) do
    t.ok(not c.url:find("/blocks/cp/", 1, true) and not c.url:find("/blocks/cd/", 1, true),
      "child_page/child_database не раскрываем")
  end
end

-- тело на нескольких страницах: читаем до has_more = false, курсор — в следующий запрос
function tests.test_blocks_follow_pagination()
  local env = blocks_env({
    page = { block("x1", "раз") },
    ["page#2"] = { block("x2", "два") },
  })
  local text, err = env.client:blocks_text("page")
  t.eq(err, nil)
  t.eq(text, "раз\nдва")
  t.eq(#env.calls, 2)
  t.ok(env.calls[2].url:find("start_cursor=p2", 1, true), env.calls[2].url)
end

-- обрыв пагинации блоков (вторая страница или вложенные блоки): ошибка, а не тело без хвоста
function tests.test_blocks_pagination_break_is_error()
  local env = fake(function(_, url)
    if url:find("start_cursor=", 1, true) then return 500, { object = "error", code = "internal_server_error" } end
    return 200, list({ block("x1", "раз") }, "p2")
  end)
  local text, err = env.client:blocks_text("page")
  t.eq(text, nil)
  t.eq(err, "http 500 internal_server_error")
  local env2 = fake(function(_, url)
    if url:find("/blocks/b1/", 1, true) then return nil, "timeout" end
    return 200, list({ block("b1", "раз", true), block("b2", "два") }, nil)
  end)
  local text2, err2 = env2.client:blocks_text("page")
  t.eq(text2, nil)
  t.eq(err2, "timeout")
end

-- has_more без курсора у блоков — неполное тело: ошибка, как у списков, а не тело без хвоста
function tests.test_blocks_has_more_without_cursor_is_incomplete()
  local env = fake(function()
    return 200, { object = "list", results = { block("x1", "раз") }, has_more = true, next_cursor = nil }
  end)
  local text, err = env.client:blocks_text("page")
  t.eq(text, nil)
  t.eq(err, "incomplete")
  local env2 = fake(function(_, url)
    if url:find("/blocks/b1/", 1, true) then
      return 200, { object = "list", results = { block("c1", "вложенный") }, has_more = true, next_cursor = "" }
    end
    return 200, list({ block("b1", "раз", true) }, nil)
  end)
  local text2, err2 = env2.client:blocks_text("page")
  t.eq(text2, nil)
  t.eq(err2, "incomplete", "и во вложенных, и с пустым курсором")
end

-- 404 детей вложенного блока (synced_block с нерасшаренным источником): блок без детей, остальное читается;
-- 404 самой страницы — по-прежнему ошибка (тест ниже)
function tests.test_blocks_nested_404_skips_only_that_block()
  local env = fake(function(_, url)
    if url:find("/blocks/sb/", 1, true) then return 404, { object = "error", code = "object_not_found" } end
    if url:find("/blocks/b1/", 1, true) then return 200, list({ block("c1", "вложенный") }, nil) end
    return 200, list({
      block("x1", "раз"),
      { object = "block", id = "sb", type = "synced_block", has_children = true,
        synced_block = { synced_from = { type = "block_id", block_id = "src" } } },
      block("b1", "два", true),
    }, nil)
  end)
  local text, err, gaps = env.client:blocks_text("page")
  t.eq(err, nil)
  t.eq(text, "раз\nдва\nвложенный")
  t.eq(gaps, 1, "пропуск отмечен: sync перечитает страницу, когда источник расшарят")
end

-- тело без пропусков — gaps = 0
function tests.test_blocks_without_404_has_no_gaps()
  local env = fake(function(_, url)
    if url:find("/blocks/b1/", 1, true) then return 200, list({ block("c1", "вложенный") }, nil) end
    return 200, list({ block("x1", "раз"), block("b1", "два", true) }, nil)
  end)
  local text, err, gaps = env.client:blocks_text("page")
  t.eq(err, nil)
  t.eq(text, "раз\nдва\nвложенный")
  t.eq(gaps, 0)
end

-- 404 на второй странице детей вложенного блока — обрыв тела, а не «нет детей»: ошибка
function tests.test_blocks_nested_404_after_first_page_is_error()
  local env = fake(function(_, url)
    if url:find("/blocks/b1/", 1, true) then
      if url:find("start_cursor=", 1, true) then return 404, { object = "error", code = "object_not_found" } end
      return 200, list({ block("c1", "вложенный") }, "n2")
    end
    return 200, list({ block("b1", "раз", true) }, nil)
  end)
  local text, err = env.client:blocks_text("page")
  t.eq(text, nil)
  t.eq(err, "http 404 object_not_found")
end

-- пустой курсор на верхнем уровне: incomplete сразу, второго запроса с пустым start_cursor нет
-- (иначе ответ на него без has_more дал бы тело без хвоста)
function tests.test_blocks_empty_cursor_is_incomplete_without_next_request()
  local env = fake(function(_, url)
    if url:find("start_cursor=", 1, true) then return 200, list({ block("x2", "хвост?") }, nil) end
    return 200, { object = "list", results = { block("x1", "раз") }, has_more = true, next_cursor = "" }
  end)
  local text, err = env.client:blocks_text("page")
  t.eq(text, nil)
  t.eq(err, "incomplete")
  t.eq(#env.calls, 1)
end

-- зацикленный курсор блоков: не больше MAX_PAGES запросов, затем incomplete, а не тело
function tests.test_blocks_pages_limit_exhausted_is_incomplete()
  local env = fake(function() return 200, list({}, "loop") end)
  local text, err = env.client:blocks_text("page")
  t.eq(text, nil)
  t.eq(err, "incomplete")
  t.eq(#env.calls, notion.MAX_PAGES, "не больше MAX_PAGES запросов")
end

function tests.test_blocks_error_propagates()
  local env = fake(function() return 404, { object = "error", code = "object_not_found" } end)
  local text, err = env.client:blocks_text("page")
  t.eq(text, nil)
  t.eq(err, "http 404 object_not_found")
end

t.run(tests)
