-- PNG записи: дополнение белыми полями до минимального размера (Groq: 400 «Image must have at
-- least 32 pixels in each dimension»; короткий штрих обрезается до картинки меньше 32 px).
-- Чистый Lua (LuaJIT bit): inflate, снятие фильтров строк, запись без сжатия (stored).
-- Поддержано: без чересстрочности; серый 1/2/4/8 бит (ч/б страницу устройства lodepng пишет
-- 1-битным серым), RGB и с альфой — 8 бит. Остальное и битый файл pad отдаёт как есть;
-- результат pad — 8 бит на канал (серый растянут: 1 бит 0/1 -> 0/255).

local bit = require("bit")
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local png = {}

-- px: меньше по стороне Groq не принимает; меньше по обеим — случайное касание (владелец
-- 2026-10-25), в модель не уходит
png.MIN_SIDE = 32
-- больше байт вывода decode (w·h·каналы из IHDR, 8 бит на канал) — отказ до распаковки: потолок вывода inflate
-- берётся из IHDR, а каждый байт — элемент Lua-таблицы (8 байт, и таблиц две: вывод inflate и pix), на Kindle
-- PW2 (256 МБ) RGBA 4M px — OOM. 2 МиБ: страница устройства 1072×1448 серым — 1.5 МиБ, обложка 758×1024 серым
png.MAX_BYTES = 2 * 1024 * 1024

local SIG = "\137PNG\r\n\26\n"
local CHANS = { [0] = 1, [2] = 3, [4] = 2, [6] = 4 }

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then error("png: truncated") end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function be32s(n)
  return string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
end

-- inflate (RFC 1951) ---------------------------------------------------------

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
  131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
  2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CLORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- канонический код Хаффмана: число кодов каждой длины и символы по порядку
local function huffman(lengths, n)
  local count, offs, symbol = {}, {}, {}
  for len = 0, 15 do count[len] = 0 end
  for s = 0, n - 1 do count[lengths[s] or 0] = count[lengths[s] or 0] + 1 end
  offs[1] = 0
  for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
  for s = 0, n - 1 do
    local len = lengths[s] or 0
    if len ~= 0 then
      symbol[offs[len]] = s
      offs[len] = offs[len] + 1
    end
  end
  return { count = count, symbol = symbol }
end

-- max_out — потолок вывода (байт): больше — ошибка до записи, а не мегабайты в памяти устройства
local function inflate(data, pos, max_out)
  local bitbuf, bitcnt = 0, 0
  local out, n = {}, 0

  local function bits(need)
    while bitcnt < need do
      local b = data:byte(pos)
      if not b then error("png: deflate truncated") end
      pos = pos + 1
      bitbuf = bor(bitbuf, lshift(b, bitcnt))
      bitcnt = bitcnt + 8
    end
    local v = band(bitbuf, lshift(1, need) - 1)
    bitbuf = rshift(bitbuf, need)
    bitcnt = bitcnt - need
    return v
  end

  local function decode(h)
    local code, first, index = 0, 0, 0
    for len = 1, 15 do
      code = bor(code, bits(1))
      local count = h.count[len]
      if code - count < first then return h.symbol[index + code - first] end
      index = index + count
      first = lshift(first + count, 1)
      code = lshift(code, 1)
    end
    error("png: bad huffman code")
  end

  local function codes(lit, dist)
    while true do
      local sym = decode(lit)
      if sym < 256 then
        if n >= max_out then error("png: too much data") end
        n = n + 1
        out[n] = sym
      elseif sym == 256 then
        return
      else
        sym = sym - 257
        if sym >= 29 then error("png: bad length") end
        local len = LBASE[sym + 1] + bits(LEXT[sym + 1])
        local ds = decode(dist)
        if ds >= 30 then error("png: bad distance") end
        local d = DBASE[ds + 1] + bits(DEXT[ds + 1])
        if d > n then error("png: distance too far") end
        if n + len > max_out then error("png: too much data") end
        for _ = 1, len do
          n = n + 1
          out[n] = out[n - d]
        end
      end
    end
  end

  local fixed_lit, fixed_dist
  repeat
    local final = bits(1)
    local kind = bits(2)
    if kind == 0 then
      bitbuf, bitcnt = 0, 0 -- до границы байта
      local len = data:byte(pos) + data:byte(pos + 1) * 256
      local nlen = data:byte(pos + 2) + data:byte(pos + 3) * 256
      if band(bxor(len, nlen), 0xffff) ~= 0xffff then error("png: bad stored block") end
      pos = pos + 4
      if pos + len - 1 > #data then error("png: stored truncated") end
      if n + len > max_out then error("png: too much data") end
      for i = pos, pos + len - 1 do
        n = n + 1
        out[n] = data:byte(i)
      end
      pos = pos + len
    elseif kind == 1 then
      if not fixed_lit then
        local l = {}
        for s = 0, 143 do l[s] = 8 end
        for s = 144, 255 do l[s] = 9 end
        for s = 256, 279 do l[s] = 7 end
        for s = 280, 287 do l[s] = 8 end
        fixed_lit = huffman(l, 288)
        local d = {}
        for s = 0, 29 do d[s] = 5 end
        fixed_dist = huffman(d, 30)
      end
      codes(fixed_lit, fixed_dist)
    elseif kind == 2 then
      local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
      local cl = {}
      for i = 1, ncode do cl[CLORDER[i]] = bits(3) end
      local clh = huffman(cl, 19)
      local lengths, i = {}, 0
      while i < nlen + ndist do
        local sym = decode(clh)
        if sym < 16 then
          lengths[i] = sym
          i = i + 1
        else
          local v, rep = 0, 0
          if sym == 16 then
            if i == 0 then error("png: repeat without length") end
            v, rep = lengths[i - 1], 3 + bits(2)
          elseif sym == 17 then
            rep = 3 + bits(3)
          else
            rep = 11 + bits(7)
          end
          if i + rep > nlen + ndist then error("png: too many lengths") end
          for _ = 1, rep do
            lengths[i] = v
            i = i + 1
          end
        end
      end
      local ll, dl = {}, {}
      for s = 0, nlen - 1 do ll[s] = lengths[s] end
      for s = 0, ndist - 1 do dl[s] = lengths[nlen + s] end
      codes(huffman(ll, nlen), huffman(dl, ndist))
    else
      error("png: bad block type")
    end
  until final == 1
  return out, n
end

-- PNG ------------------------------------------------------------------------

local function header(bytes)
  if type(bytes) ~= "string" or bytes:sub(1, 8) ~= SIG or bytes:sub(13, 16) ~= "IHDR" then return nil end
  return be32(bytes, 17), be32(bytes, 21)
end

-- -> { w, h, chans, ctype, pix }: pix — 8 бит на канал, строки подряд, без байтов фильтра
function png.decode(bytes)
  local w, h = header(bytes)
  if not w then error("png: not a png") end
  local depth, ctype, comp, filter, interlace = bytes:byte(25, 29)
  local chans = CHANS[ctype]
  local low = ctype == 0 and (depth == 1 or depth == 2 or depth == 4)
  if not (depth == 8 or low) or not chans or comp ~= 0 or filter ~= 0 or interlace ~= 0 then
    error(string.format("png: unsupported depth=%s color=%s interlace=%s", tostring(depth), tostring(ctype),
      tostring(interlace)))
  end
  if w * h * chans > png.MAX_BYTES then error(string.format("png: too big %dx%d×%d", w, h, chans)) end
  local idat, pos = {}, 9
  while pos + 7 <= #bytes do
    local len, kind = be32(bytes, pos), bytes:sub(pos + 4, pos + 7)
    if kind == "IDAT" then idat[#idat + 1] = bytes:sub(pos + 8, pos + 7 + len) end
    if kind == "IEND" then break end
    pos = pos + 12 + len
  end
  local z = table.concat(idat)
  local cmf, flg = z:byte(1, 2)
  if not flg or band(cmf, 15) ~= 8 or (cmf * 256 + flg) % 31 ~= 0 or band(flg, 32) ~= 0 then
    error("png: bad zlib header")
  end
  local stride = math.ceil(w * chans * depth / 8) -- байт в строке
  local raw, n = inflate(z, 3, (stride + 1) * h)
  local bpp = math.max(1, chans * depth / 8)        -- шаг фильтра, байт
  if n < (stride + 1) * h then error("png: short image data") end
  local pix, prev = {}, 0 -- prev: начало предыдущей строки в pix (0 — нет)
  local k, r = 0, 1
  for y = 0, h - 1 do
    local f = raw[r]
    r = r + 1
    local row = k
    for i = 1, stride do
      local v = raw[r]
      r = r + 1
      local a = i > bpp and pix[row + i - bpp] or 0
      local b = y > 0 and pix[prev + i] or 0
      if f == 1 then
        v = v + a
      elseif f == 2 then
        v = v + b
      elseif f == 3 then
        v = v + math.floor((a + b) / 2)
      elseif f == 4 then
        local c = (y > 0 and i > bpp) and pix[prev + i - bpp] or 0
        local p = a + b - c
        local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
        if pa <= pb and pa <= pc then v = v + a elseif pb <= pc then v = v + b else v = v + c end
      elseif f ~= 0 then
        error("png: bad filter " .. tostring(f))
      end
      pix[row + i] = v % 256
    end
    prev = row
    k = k + stride
  end
  if low then -- распаковка бит (старшие первыми) и растяжка до 8 бит
    local top, per = 2 ^ depth - 1, 8 / depth
    local wide = {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local b = pix[y * stride + math.floor(x / per) + 1]
        local v = band(rshift(b, 8 - depth * (x % per + 1)), top)
        wide[y * w + x + 1] = v * 255 / top
      end
    end
    pix = wide
  end
  local parts = {}
  for i = 1, #pix, 4096 do parts[#parts + 1] = string.char(unpack(pix, i, math.min(i + 4095, #pix))) end
  return { w = w, h = h, chans = chans, ctype = ctype, pix = table.concat(parts) }
end

local CRC
local function crc32(s)
  if not CRC then
    CRC = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if band(c, 1) == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
      end
      CRC[i] = c
    end
  end
  local c = 0xFFFFFFFF
  for i = 1, #s do c = bxor(CRC[band(bxor(c, s:byte(i)), 255)], rshift(c, 8)) end
  return bxor(c, 0xFFFFFFFF)
end

local function chunk(kind, data)
  return be32s(#data) .. kind .. data .. be32s(crc32(kind .. data))
end

-- img -> PNG: фильтр 0, deflate без сжатия (картинка мала — дополняются только маленькие)
function png.encode(img)
  local stride = img.w * img.chans
  local rows = {}
  for y = 0, img.h - 1 do rows[#rows + 1] = "\0" .. img.pix:sub(y * stride + 1, (y + 1) * stride) end
  local raw = table.concat(rows)
  local a, b = 1, 0
  for i = 1, #raw do
    a = (a + raw:byte(i)) % 65521
    b = (b + a) % 65521
  end
  local z = { "\120\1" }
  local i = 1
  repeat
    local len = math.min(65535, #raw - i + 1)
    local final = (i + len > #raw) and 1 or 0
    z[#z + 1] = string.char(final, band(len, 255), rshift(len, 8), band(bxor(len, 0xffff), 255),
      rshift(bxor(len, 0xffff), 8))
    z[#z + 1] = raw:sub(i, i + len - 1)
    i = i + len
  until i > #raw
  z[#z + 1] = be32s(b * 65536 + a)
  local ihdr = be32s(img.w) .. be32s(img.h) .. string.char(8, img.ctype, 0, 0, 0)
  return SIG .. chunk("IHDR", ihdr) .. chunk("IDAT", table.concat(z)) .. chunk("IEND", "")
end

-- bytes -> ширина, высота из IHDR; не PNG или обрывок — nil
function png.size(bytes)
  local ok, w, h = pcall(header, bytes)
  if ok and w then return w, h end
end

-- обе стороны меньше MIN_SIDE: случайное касание, не запись
function png.tiny(w, h)
  return w < png.MIN_SIDE and h < png.MIN_SIDE
end

-- bytes, min -> PNG не меньше min×min (исходник в центре, поля белые) и "WxH -> W'xH'";
-- уже достаточно большой, не PNG или битый — те же байты и nil
function png.pad(bytes, min)
  local w, h = png.size(bytes)
  if not w or (w >= min and h >= min) then return bytes end
  local ok2, img = pcall(png.decode, bytes)
  if not ok2 then return bytes end
  local W, H = math.max(w, min), math.max(h, min)
  local ox, oy = math.floor((W - w) / 2), math.floor((H - h) / 2)
  local c = img.chans
  local white = string.rep("\255", W * c)
  local left, right = string.rep("\255", ox * c), string.rep("\255", (W - w - ox) * c)
  local rows = {}
  for y = 0, H - 1 do
    local sy = y - oy
    if sy >= 0 and sy < h then
      rows[#rows + 1] = left .. img.pix:sub(sy * w * c + 1, (sy + 1) * w * c) .. right
    else
      rows[#rows + 1] = white
    end
  end
  local out = png.encode({ w = W, h = H, chans = c, ctype = img.ctype, pix = table.concat(rows) })
  return out, string.format("%dx%d -> %dx%d", w, h, W, H)
end

return png
