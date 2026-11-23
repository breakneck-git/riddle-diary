-- Нарезка текста документа на куски для отпечатков. Знак — кодпойнт UTF-8, режется только по их границам.
-- Текст ≤ WHOLE знаков — один кусок как есть. Длиннее — абзацы (между ними пустая строка) пакуются в кусок,
-- пока он ≤ WHOLE; следующий кусок начинается с хвоста предыдущего ≤ OVERLAP знаков (с начала слова).
-- Абзац длиннее WHOLE — отдельный кусок целиком; длиннее CAP — режется на части по CAP знаков.
local str = require("riddle.str")

local chunk = {}

chunk.WHOLE = 1500
chunk.OVERLAP = 300
chunk.CAP = 8000

local SEP = "\n\n"

local ulen = str.utf8_len

local byte_at = str.utf8_offset

-- последние не больше n знаков; срез пришёлся на середину слова — с начала следующего слова
local function tail(s, n)
  local len = ulen(s)
  if len <= n then return s end
  local from = byte_at(s, len - n + 1)
  local out = s:sub(from)
  if not s:sub(from - 1, from - 1):match("%s") then
    out = out:match("^%S*%s+(.*)$") or out
  end
  return (out:gsub("^%s+", ""))
end

local function paragraphs(text)
  local out = {}
  local norm = text:gsub("\r\n", "\n"):gsub("\n[ \t]+\n", "\n\n")
  for p in (norm .. SEP):gmatch("(.-)\n\n+") do
    p = str.trim(p)
    if p ~= "" then
      local len = ulen(p)
      if len <= chunk.CAP then
        out[#out + 1] = { text = p, len = len }
      else
        local i = 1
        while i <= len do
          local piece = p:sub(byte_at(p, i), byte_at(p, i + chunk.CAP) - 1)
          out[#out + 1] = { text = piece, len = ulen(piece) }
          i = i + chunk.CAP
        end
      end
    end
  end
  return out
end

-- split(text) -> { text, … }; пустой или из одних пробелов — {}
function chunk.split(text)
  if type(text) ~= "string" or not text:find("%S") then return {} end
  if ulen(text) <= chunk.WHOLE then return { text } end
  local out, cur, cur_len, prev = {}, {}, 0, nil
  local function flush()
    if #cur == 0 then return end
    local body = table.concat(cur, SEP)
    local piece = body
    if prev then
      local head = tail(prev, chunk.OVERLAP)
      if head ~= "" and ulen(head) + #SEP + cur_len <= chunk.CAP then piece = head .. SEP .. body end
    end
    out[#out + 1] = piece
    prev, cur, cur_len = body, {}, 0
  end
  for _, p in ipairs(paragraphs(text)) do
    if #cur > 0 and cur_len + #SEP + p.len > chunk.WHOLE then flush() end
    cur[#cur + 1] = p.text
    cur_len = cur_len + (cur_len > 0 and #SEP or 0) + p.len
  end
  flush()
  return out
end

return chunk
