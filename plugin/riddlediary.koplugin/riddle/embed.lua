-- Клиент отпечатков текста: OpenAI-совместимый POST /embeddings (Cloudflare Workers AI, @cf/baai/bge-m3).
-- request(method, url, headers, body | nil, timeout_s) -> status, body, headers | nil, err — http.request.
-- Тело {model, input = [тексты]}, ответ {data = [{index, embedding}], usage = {prompt_tokens} | нет}.
-- Тексты уходят пакетами ≤ BATCH; векторы — в порядке входа (по index), нормированы L2.
-- Сбой любого пакета — nil, err целиком: частичных результатов нет, пакет вызывающий выбирает сам.
-- В err никогда нет ключа и текста ответа: только статус, числовой код Cloudflare или ошибка транспорта.
local json = require("dkjson")

local embed = {}
embed.BATCH = 200

local E = {}
E.__index = E

function embed.new(o)
  return setmetatable({
    url = o.url,
    model = o.model,
    key = o.key,
    request = o.request,
    timeout_s = o.timeout_s or 20,
  }, E)
end

function E:_mask(text)
  text = tostring(text)
  local key = type(self.key) == "string" and self.key or ""
  if #key > 0 then
    local from = 1
    while true do
      local a, b = text:find(key, from, true)
      if not a then break end
      text = text:sub(1, a - 1) .. "***" .. text:sub(b + 1)
      from = a + 3
    end
  end
  return (text:gsub("Bearer%s+%S+", "***"))
end

-- "http <код>" и числовой код ошибки Cloudflare из errors[1].code, если он есть
local function status_err(status, body)
  local data = type(body) == "string" and json.decode(body) or nil
  local first = type(data) == "table" and type(data.errors) == "table" and data.errors[1]
  local code = type(first) == "table" and tonumber(first.code)
  if code and code == math.floor(code) and code >= 0 and code < 1e7 then
    return string.format("http %s cf %d", tostring(status), code)
  end
  return "http " .. tostring(status)
end

local function normalized(v)
  if type(v) ~= "table" or #v == 0 then return nil end
  local s = 0
  for i = 1, #v do
    local x = v[i]
    if type(x) ~= "number" or x ~= x then return nil end
    s = s + x * x
  end
  if s <= 0 or s == math.huge then return nil end
  local n = math.sqrt(s)
  local out = {}
  for i = 1, #v do out[i] = v[i] / n end
  return out
end

-- один пакет -> { vec… } в порядке входа, tokens | nil, err
function E:_batch(texts)
  local headers = {
    Authorization = "Bearer " .. tostring(self.key),
    ["Content-Type"] = "application/json",
    Accept = "application/json",
  }
  local payload = json.encode({ model = self.model, input = texts })
  local status, resp = self.request("POST", self.url, headers, payload, self.timeout_s)
  if status == nil then return nil, self:_mask(resp) end
  if status ~= 200 then return nil, status_err(status, resp) end
  local data = type(resp) == "string" and json.decode(resp) or nil
  if type(data) ~= "table" or type(data.data) ~= "table" then return nil, "bad response" end
  local vecs = {}
  for _, item in ipairs(data.data) do
    local i = type(item) == "table" and tonumber(item.index)
    if not i or i < 0 or i >= #texts or i ~= math.floor(i) or vecs[i + 1] then return nil, "bad index" end
    local v = normalized(item.embedding)
    if not v then return nil, "bad vector" end
    vecs[i + 1] = v
  end
  for i = 1, #texts do
    if not vecs[i] then return nil, string.format("got %d of %d vectors", #data.data, #texts) end
    if #vecs[i] ~= #vecs[1] then return nil, "mixed dimensions" end
  end
  local usage = type(data.usage) == "table" and data.usage or {}
  return vecs, tonumber(usage.prompt_tokens) or tonumber(usage.total_tokens)
end

-- vectors(texts) -> { vec… }, tokens | nil, err
-- tokens — сумма usage по пакетам; хоть у одного пакета usage нет (Cloudflare его не отдаёт) — nil
function E:vectors(texts)
  local out, tokens = {}, 0
  for from = 1, #texts, embed.BATCH do
    local batch = {}
    for i = from, math.min(from + embed.BATCH - 1, #texts) do batch[#batch + 1] = texts[i] end
    local vecs, n = self:_batch(batch)
    if not vecs then return nil, n end
    for _, v in ipairs(vecs) do out[#out + 1] = v end
    tokens = tokens and n and tokens + n or nil
  end
  return out, tokens
end

return embed
