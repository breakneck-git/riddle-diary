-- Текст документа знания из объекта Notion: название, свойства строки базы, тело.
-- Пути значений — developers.notion.com/reference/page-property-values. Неизвестный тип свойства
-- (button, verification, будущие) и пустое значение пропускаются.
local nt = {}

local function str(v)
  if type(v) == "string" then return v end
  return ""
end

-- склейка plain_text массива rich text
local function rich(arr)
  if type(arr) ~= "table" then return "" end
  local out = {}
  for _, seg in ipairs(arr) do
    if type(seg) == "table" then out[#out + 1] = str(seg.plain_text) end
  end
  return table.concat(out)
end
nt.rich = rich

local function number(n)
  if type(n) ~= "number" then return "" end
  return string.format("%.15g", n)
end

local function date(d)
  if type(d) ~= "table" or type(d.start) ~= "string" then return "" end
  if type(d["end"]) == "string" and d["end"] ~= "" then return d.start .. " – " .. d["end"] end
  return d.start
end

local function bool(b)
  if type(b) ~= "boolean" then return "" end
  return b and "да" or "нет"
end

local function join(list)
  local out = {}
  for _, s in ipairs(list) do
    if s ~= "" then out[#out + 1] = s end
  end
  return table.concat(out, ", ")
end

local function names(arr)
  if type(arr) ~= "table" then return "" end
  local out = {}
  for _, it in ipairs(arr) do
    if type(it) == "table" then out[#out + 1] = str(it.name) end
  end
  return join(out)
end

local value -- значение свойства { type = …, [type] = … } строкой; "" — пропустить

local VALUE = {
  title = rich,
  rich_text = rich,
  number = number,
  select = function(v) return type(v) == "table" and str(v.name) or "" end,
  multi_select = names,
  date = date,
  checkbox = bool,
  url = str,
  email = str,
  phone_number = str,
  formula = function(v)
    if type(v) ~= "table" then return "" end
    if v.type == "string" then return str(v.string) end
    if v.type == "number" then return number(v.number) end
    if v.type == "boolean" then return bool(v.boolean) end
    if v.type == "date" then return date(v.date) end
    return ""
  end,
  rollup = function(v, titles)
    if type(v) ~= "table" then return "" end
    if v.type == "number" then return number(v.number) end
    if v.type == "date" then return date(v.date) end
    if v.type == "array" and type(v.array) == "table" then
      local out = {}
      for _, item in ipairs(v.array) do out[#out + 1] = value(item, titles) end
      return join(out)
    end
    return ""
  end,
  relation = function(v, titles)
    if type(v) ~= "table" then return "" end
    local out = {}
    for _, ref in ipairs(v) do
      if type(ref) == "table" and titles[ref.id] then out[#out + 1] = titles[ref.id] end
    end
    return join(out)
  end,
  people = names,
  files = names,
  unique_id = function(v)
    if type(v) ~= "table" or type(v.number) ~= "number" then return "" end
    if type(v.prefix) == "string" and v.prefix ~= "" then return v.prefix .. "-" .. number(v.number) end
    return number(v.number)
  end,
}
VALUE.status = VALUE.select

function value(p, titles)
  if type(p) ~= "table" then return "" end
  local f = VALUE[p.type]
  if not f then return "" end
  return f(p[p.type], titles or {})
end

-- название страницы (свойство-title) или базы (title массивом rich text). У базы в properties —
-- схема, а не значения (у свойства-title там "title": {}), поэтому properties — только не у базы
function nt.title(obj)
  if type(obj) ~= "table" then return "" end
  if obj.object == "data_source" or obj.object == "database" then return rich(obj.title) end
  if type(obj.properties) == "table" then
    for _, p in pairs(obj.properties) do
      if type(p) == "table" and p.type == "title" then return rich(p.title) end
    end
  end
  return rich(obj.title)
end

-- { {name, value}, … }: свойство-title первым, остальные по имени; пустые и неизвестные пропущены
function nt.props(page, titles_by_id)
  local title_item, rest = nil, {}
  if type(page) ~= "table" or type(page.properties) ~= "table" then return {} end
  for name, p in pairs(page.properties) do
    local v = value(p, titles_by_id)
    if v ~= "" then
      if p.type == "title" then
        title_item = { name, v }
      else
        rest[#rest + 1] = { name, v }
      end
    end
  end
  table.sort(rest, function(a, b) return a[1] < b[1] end)
  if title_item then table.insert(rest, 1, title_item) end
  return rest
end

-- строка базы: название базы, «Свойство: значение» построчно, пустая строка, тело;
-- страница вне базы (source_title == nil): название, пустая строка, тело
function nt.doc(source_title, page, body, titles_by_id)
  local lines = {}
  if source_title then
    if source_title ~= "" then lines[1] = source_title end
    for _, kv in ipairs(nt.props(page, titles_by_id)) do
      lines[#lines + 1] = kv[1] .. ": " .. kv[2]
    end
  else
    local title = nt.title(page)
    if title ~= "" then lines[1] = title end
  end
  if type(body) == "string" and body ~= "" then
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = body
  end
  return table.concat(lines, "\n")
end

return nt
