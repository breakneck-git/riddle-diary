-- Клиент Notion API (только чтение): поиск, строки баз (data sources), текст тела по блокам.
-- request(method, url, headers, body | nil, timeout_s) -> status, body, headers | nil, err — http.request.
-- Между запросами не меньше min_interval_s (средний лимит Notion — 3 запроса в секунду);
-- 429 и 529 (Notion перегружен) — ждать Retry-After (секунды) или 1 с, не больше MAX_RETRIES повторов.
-- В err никогда нет токена и текста ответа: только статус, code Notion или ошибка транспорта.
local json = require("dkjson")
local nt = require("riddle.notion_text")
local str = require("riddle.str")

local BASE = "https://api.notion.com"
local MAX_RETRIES = 5
local MAX_RETRY_AFTER_S = 60
local MAX_PAGES = 1000 -- страниц пагинации на один список: защита от зацикленного курсора
local MAX_DEPTH = 3

local notion = {}
notion.MAX_PAGES = MAX_PAGES

local Client = {}
Client.__index = Client

function notion.new(o)
  return setmetatable({
    token = o.token,
    request = o.request,
    sleep = o.sleep,
    clock = o.clock,
    min_interval_s = o.min_interval_s or 0.34,
    version = o.version or "2025-09-03",
    timeout_s = o.timeout_s or 20,
    last_at = nil,
  }, Client)
end

local urlencode = require("riddle.http").urlencode

local function header(headers, name)
  if type(headers) ~= "table" then return nil end
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == name then return v end
  end
end

-- "http <код>" и code Notion, если он похож на код (validation_error, object_not_found, …)
local function status_err(status, body)
  local data = type(body) == "string" and json.decode(body) or nil
  local code = type(data) == "table" and data.code
  if type(code) == "string" and code:match("^[a-z_]+$") and #code <= 40 then
    return "http " .. status .. " " .. code
  end
  return "http " .. status
end

function Client:_wait()
  if self.last_at then
    local left = self.min_interval_s - (self.clock() - self.last_at)
    if left > 0 then self.sleep(left) end
  end
  self.last_at = self.clock()
end

-- один вызов API -> разобранный JSON | nil, err
function Client:_call(method, path, body)
  local headers = {
    Authorization = "Bearer " .. tostring(self.token),
    ["Notion-Version"] = self.version,
    Accept = "application/json",
  }
  local payload
  if body ~= nil then
    payload = json.encode(body)
    headers["Content-Type"] = "application/json"
  end
  for attempt = 0, MAX_RETRIES do
    self:_wait()
    local status, resp, resp_headers = self.request(method, BASE .. path, headers, payload, self.timeout_s)
    if status == nil then return nil, tostring(resp) end
    if status == 200 then
      local data = type(resp) == "string" and json.decode(resp) or nil
      if type(data) ~= "table" then return nil, "bad json" end
      return data
    end
    if status == 401 or status == 403 then return nil, "unauthorized" end
    if status ~= 429 and status ~= 529 then return nil, status_err(status, resp) end
    local wait = tonumber(header(resp_headers, "retry-after") or "")
    if not wait or wait < 0 then wait = 1 end
    if wait > MAX_RETRY_AFTER_S or attempt == MAX_RETRIES then return nil, "http " .. status end
    self.sleep(wait)
  end
end

-- все результаты списка; fetch(cursor) -> data | nil, err
-- Неполный список — ошибка "incomplete", не обрезанный результат: по нему sync удалил бы всё за обрезом.
-- Неполнота: request_status.type == "incomplete" (после 10 000-го результата has_more уже false),
-- has_more без курсора, исчерпан MAX_PAGES.
local function collect(fetch)
  local out, cursor = {}, nil
  for _ = 1, MAX_PAGES do
    local data, err = fetch(cursor)
    if not data then return nil, err end
    local rs = data.request_status
    if type(rs) == "table" and rs.type == "incomplete" then return nil, "incomplete" end
    for _, r in ipairs(type(data.results) == "table" and data.results or {}) do out[#out + 1] = r end
    if data.has_more ~= true then return out end
    if type(data.next_cursor) ~= "string" or data.next_cursor == "" then return nil, "incomplete" end
    cursor = data.next_cursor
  end
  return nil, "incomplete"
end

local function list_body(cursor)
  return { page_size = 100, start_cursor = cursor }
end

-- все страницы и базы (data_source), доступные токену
function Client:search_all()
  return collect(function(cursor) return self:_call("POST", "/v1/search", list_body(cursor)) end)
end

local function valid_id(id)
  return type(id) == "string" and id:match("^[%w%-]+$") ~= nil
end

-- все строки базы
function Client:query_all(data_source_id)
  if not valid_id(data_source_id) then return nil, "bad id" end
  local path = "/v1/data_sources/" .. data_source_id .. "/query"
  return collect(function(cursor) return self:_call("POST", path, list_body(cursor)) end)
end

local GET_KINDS = { pages = true, blocks = true, data_sources = true }

-- один объект: GET /v1/<kind>/<id> -> obj | nil, err (предок базы вне поиска — глубина)
function Client:get(kind, id)
  if not GET_KINDS[kind] then return nil, "bad kind" end
  if not valid_id(id) then return nil, "bad id" end
  return self:_call("GET", "/v1/" .. kind .. "/" .. id)
end

local SKIP_CHILDREN = { child_page = true, child_database = true }

-- текст одного блока: rich_text любого типа, строка таблицы — ячейки через « | »
local function block_text(b)
  local v = b[b.type]
  if type(v) ~= "table" then return "" end
  if b.type == "table_row" and type(v.cells) == "table" then
    local cells = {}
    for _, cell in ipairs(v.cells) do cells[#cells + 1] = nt.rich(cell) end
    return table.concat(cells, " | ")
  end
  return nt.rich(v.rich_text)
end

local utf8_len, utf8_head = str.utf8_len, str.utf8_head

-- текст тела страницы: блоки по порядку, вложенные — до глубины MAX_DEPTH, не больше max_chars знаков;
-- оборванная пагинация (has_more без курсора, исчерпан MAX_PAGES) — nil, "incomplete";
-- 404 на детях вложенного блока — блок без детей, 404 самой страницы — ошибка.
-- -> text, nil, gaps: gaps — сколько вложенных блоков пропущено из-за 404 (тело неполное, но edited страницы
-- не изменится, когда источник расшарят: sync перечитывает такую страницу по времени)
function Client:blocks_text(page_id, max_chars)
  max_chars = max_chars or 20000
  local lines, chars, gaps = {}, 0, 0
  local function full() return chars >= max_chars end

  local function walk(id, depth)
    if not valid_id(id) then return true end
    local cursor
    for _ = 1, MAX_PAGES do
      local path = "/v1/blocks/" .. id .. "/children?page_size=100"
      if cursor then path = path .. "&start_cursor=" .. urlencode(cursor) end
      local data, err = self:_call("GET", path)
      if not data then
        -- дети вложенного блока недоступны (synced_block с нерасшаренным источником) — блок без детей
        if depth > 1 and not cursor and tostring(err):match("^http 404") then
          gaps = gaps + 1
          return true
        end
        return nil, err
      end
      for _, b in ipairs(type(data.results) == "table" and data.results or {}) do
        if type(b) == "table" and not b.in_trash and not b.archived then
          local text = block_text(b)
          if text ~= "" then
            lines[#lines + 1] = text
            chars = chars + utf8_len(text) + (#lines > 1 and 1 or 0)
            if full() then return true end
          end
          if b.has_children == true and depth < MAX_DEPTH and not SKIP_CHILDREN[b.type] then
            local ok, werr = walk(b.id, depth + 1)
            if not ok then return nil, werr end
            if full() then return true end
          end
        end
      end
      if data.has_more ~= true then return true end
      -- has_more без курсора — тело неполное: ошибка, как у списков (sync не сохранит обрезанное)
      if type(data.next_cursor) ~= "string" or data.next_cursor == "" then return nil, "incomplete" end
      cursor = data.next_cursor
    end
    return nil, "incomplete"
  end

  local ok, err = walk(page_id, 1)
  if not ok then return nil, err end
  return utf8_head(table.concat(lines, "\n"), max_chars), nil, gaps
end

return notion
