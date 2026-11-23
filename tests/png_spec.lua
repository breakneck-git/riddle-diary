local t = require("t")
local png = require("riddle.png")

local T = {}

local DIR = "tests/fixtures/png/"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- узор фикстур — тот же, что в tests/fixtures/png/gen.py
local function px(x, y, c)
  if (x + y) % 5 ~= 0 then return 255 end
  return (x * 7 + y * 13 + c * 50) % 200
end

-- серые 1/2/4 бит — tests/fixtures/png/gen.py lowbit(), в decode растянуты до 8 бит
local function lowbit8(depth)
  local top = 2 ^ depth - 1
  return function(x, y)
    local v = (x + y) % 5 ~= 0 and top or (x * 7 + y * 13) % (top + 1)
    return v * 255 / top
  end
end

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- размеры из IHDR, без декодера модуля
local function dims(bytes)
  t.eq(bytes:sub(1, 8), "\137PNG\r\n\26\n", "сигнатура PNG")
  t.eq(bytes:sub(13, 16), "IHDR", "первый чанк")
  return be32(bytes, 17), be32(bytes, 21)
end

-- CRC-32 и Adler-32 своими силами (побитово, без таблиц модуля): декодер модуля их не проверяет
local bit = require("bit")
local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bit.bxor(c, s:byte(i))
    for _ = 1, 8 do
      local lsb = bit.band(c, 1)
      c = bit.rshift(c, 1)
      if lsb == 1 then c = bit.bxor(c, 0xEDB88320) end
    end
  end
  return bit.tobit(bit.bnot(c)) % 2 ^ 32
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

-- контрольные векторы: сами функции теста верны
function T.test_checksum_reference_vectors()
  t.eq(crc32("123456789"), 0xCBF43926, "crc32 check")
  t.eq(crc32("IEND"), 0xAE426082, "crc32 IEND")
  t.eq(adler32("Wikipedia"), 0x11E60398, "adler32")
end

-- каждый чанк: CRC по kind .. data; IDAT: zlib-заголовок, stored-блоки с LEN/NLEN, Adler-32 сырых строк
local function check_container(out)
  local pos, raw, idat = 9, {}, {}
  while pos <= #out do
    local len, kind = be32(out, pos), out:sub(pos + 4, pos + 7)
    local data = out:sub(pos + 8, pos + 7 + len)
    t.eq(be32(out, pos + 8 + len), crc32(kind .. data), "CRC чанка " .. kind)
    if kind == "IDAT" then idat[#idat + 1] = data end
    pos = pos + 12 + len
  end
  t.eq(pos, #out + 1, "чанки до конца файла")
  local z = table.concat(idat)
  local cmf, flg = z:byte(1, 2)
  t.eq(cmf % 16, 8, "deflate")
  t.eq((cmf * 256 + flg) % 31, 0, "проверка FCHECK")
  local i, final = 3, 0
  while final == 0 do
    local hdr = z:byte(i)
    final = hdr % 2
    t.eq(math.floor(hdr / 2) % 4, 0, "stored-блок")
    local len = z:byte(i + 1) + z:byte(i + 2) * 256
    local nlen = z:byte(i + 3) + z:byte(i + 4) * 256
    t.eq(len + nlen, 65535, "NLEN = ~LEN")
    raw[#raw + 1] = z:sub(i + 5, i + 4 + len)
    i = i + 5 + len
  end
  t.eq(i + 3, #z, "после блоков — только Adler-32")
  t.eq(be32(z, i), adler32(table.concat(raw)), "Adler-32")
end

-- исходник лежит в центре (сдвиг вниз-вправо — пол половины поля), поля белые
local function check_padded(out, w, h, chans, W, H, want_px)
  want_px = want_px or px
  check_container(out)
  local ow, oh = dims(out)
  t.eq(ow, W, "ширина")
  t.eq(oh, H, "высота")
  local img = assert(png.decode(out))
  t.eq(img.w, W, "decode w")
  t.eq(img.h, H, "decode h")
  t.eq(img.chans, chans, "каналы")
  local ox, oy = math.floor((W - w) / 2), math.floor((H - h) / 2)
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      for c = 0, chans - 1 do
        local v = img.pix:byte((y * W + x) * chans + c + 1)
        local sx, sy = x - ox, y - oy
        local want = 255
        if sx >= 0 and sx < w and sy >= 0 and sy < h then want = want_px(sx, sy, c) end
        t.eq(v, want, string.format("пиксель %d,%d,%d", x, y, c))
      end
    end
  end
end

function T.test_decode_reads_all_filters_and_deflate_kinds()
  for _, kind in ipairs({ "dynamic", "fixed", "stored" }) do
    local img = assert(png.decode(read(DIR .. "g17x31_" .. kind .. ".png")))
    t.eq(img.w, 17, kind .. " w")
    t.eq(img.h, 31, kind .. " h")
    for y = 0, 30 do
      for x = 0, 16 do
        t.eq(img.pix:byte(y * 17 + x + 1), px(x, y, 0), string.format("%s %d,%d", kind, x, y))
      end
    end
  end
end

-- устройство (lodepng) пишет ч/б страницу 1-битным серым
function T.test_decode_low_bit_gray_to_8bit()
  for name, d in pairs({ ["b1_17x31_dynamic"] = { 1, 17, 31 }, ["b2_13x9_dynamic"] = { 2, 13, 9 },
      ["b4_11x7_fixed"] = { 4, 11, 7 } }) do
    local img = assert(png.decode(read(DIR .. name .. ".png")))
    local depth, w, h = d[1], d[2], d[3]
    t.eq(img.w, w, name .. " w")
    t.eq(img.h, h, name .. " h")
    t.eq(img.chans, 1, name .. " chans")
    t.eq(#img.pix, w * h, name .. " размер")
    local want = lowbit8(depth)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        t.eq(img.pix:byte(y * w + x + 1), want(x, y), string.format("%s %d,%d", name, x, y))
      end
    end
  end
end

function T.test_pad_1bit_17x31_to_32x32()
  local out, info = png.pad(read(DIR .. "b1_17x31_dynamic.png"), 32)
  check_padded(out, 17, 31, 1, 32, 32, lowbit8(1))
  t.eq(info, "17x31 -> 32x32")
end

function T.test_pad_17x31_to_32x32()
  for _, kind in ipairs({ "dynamic", "fixed", "stored" }) do
    local out, info = png.pad(read(DIR .. "g17x31_" .. kind .. ".png"), 32)
    check_padded(out, 17, 31, 1, 32, 32)
    t.eq(info, "17x31 -> 32x32", kind .. " info")
  end
end

function T.test_pad_keeps_large_side()
  local out = png.pad(read(DIR .. "g40x10_dynamic.png"), 32)
  check_padded(out, 40, 10, 1, 40, 32)
end

function T.test_pad_rgb()
  local out = png.pad(read(DIR .. "rgb5x5_dynamic.png"), 32)
  check_padded(out, 5, 5, 3, 32, 32)
end

function T.test_big_enough_untouched()
  local src = read("tools/samples/01_ok.png") -- 758x150, lodepng с устройства
  local out, info = png.pad(src, 32)
  t.eq(out, src, "те же байты")
  t.eq(info, nil, "без info")
end

function T.test_real_device_png_decodes()
  local img = assert(png.decode(read("tools/samples/01_ok.png")))
  t.eq(img.w, 758, "w")
  t.eq(img.h, 150, "h")
  t.eq(#img.pix, 758 * 150, "размер пикселей")
end

function T.test_not_png_untouched()
  local out, info = png.pad("PNGBYTES", 32)
  t.eq(out, "PNGBYTES", "не PNG — как есть")
  t.eq(info, nil, "без info")
end

function T.test_broken_png_untouched()
  local src = read(DIR .. "g17x31_dynamic.png")
  local broken = src:sub(1, 60) .. string.rep("\0", 20) .. src:sub(81)
  local out, info = png.pad(broken, 32)
  t.eq(out, broken, "битый PNG — как есть, без ошибки")
  t.eq(info, nil, "без info")
end

-- IHDR обещает 2×2, а IDAT распаковывается в мегабайт: inflate останавливается на потолке (stride+1)*h,
-- а не съедает память устройства; pad отдаёт такие байты как есть
function T.test_inflate_output_capped_by_header()
  local big = png.encode({ w = 1000, h = 1000, chans = 1, ctype = 0, pix = string.rep("\0", 1000 * 1000) })
  local function be32s(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  local ihdr = be32s(2) .. be32s(2) .. string.char(8, 0, 0, 0, 0)
  local liar = big:sub(1, 16) .. ihdr .. be32s(crc32("IHDR" .. ihdr)) .. big:sub(34)
  t.eq(#liar, #big)
  local ok, err = pcall(png.decode, liar)
  t.ok(not ok, "лишний вывод inflate — ошибка, а не картинка 2×2")
  t.ok(tostring(err):find("png: too much data", 1, true), tostring(err))
  local out, info = png.pad(liar, 32)
  t.eq(out, liar, "pad: как есть")
  t.eq(info, nil)
  -- сжатые: копии (мегабайт нулей) и одни литералы (седьмой байт при потолке 6) — tests/fixtures/png/gen.py
  for _, name in ipairs({ "bomb2x2_copies", "bomb2x2_literals" }) do
    local ok2, err2 = pcall(png.decode, read(DIR .. name .. ".png"))
    t.ok(not ok2, name .. ": ожидалась ошибка")
    t.ok(tostring(err2):find("png: too much data", 1, true), name .. ": " .. tostring(err2))
  end
  -- ровно (stride+1)*h — не ошибка
  local exact = png.encode({ w = 2, h = 2, chans = 1, ctype = 0, pix = "\1\2\3\4" })
  t.eq(png.decode(exact).pix, "\1\2\3\4")
end

-- IHDR задаёт потолок вывода inflate: огромные w×h дали бы огромный потолок, и бомба в IDAT съела бы память.
-- Потолок — байты вывода decode (w·h·каналы, 8 бит на канал): больше png.MAX_BYTES — ошибка до распаковки;
-- ровно MAX_BYTES — дальше (здесь падает на коротких данных)
local function forged(w, h, depth, ctype)
  local function be32s(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  local small = png.encode({ w = 2, h = 2, chans = 1, ctype = 0, pix = "\1\2\3\4" })
  local ihdr = be32s(w) .. be32s(h) .. string.char(depth or 8, ctype or 0, 0, 0, 0)
  return small:sub(1, 16) .. ihdr .. be32s(crc32("IHDR" .. ihdr)) .. small:sub(34)
end

local function passes_size(w, h, depth, ctype)
  local ok, err = pcall(png.decode, forged(w, h, depth, ctype))
  return not ok and tostring(err):find("short image data", 1, true) ~= nil, tostring(err)
end

function T.test_huge_ihdr_rejected_before_inflate()
  local M = png.MAX_BYTES
  for _, c in ipairs({ { 1, M + 1, 8, 0 }, { M + 1, 1, 8, 0 }, { 65536, 65536, 8, 0 },
                       { 1, M / 4 + 1, 8, 6 }, { 1, math.floor(M / 3) + 1, 8, 2 }, { 1, M / 2 + 1, 8, 4 }, { 1, M + 1, 1, 0 } }) do
    local liar = forged(c[1], c[2], c[3], c[4])
    local name = string.format("%dx%d depth=%d color=%d", c[1], c[2], c[3], c[4])
    local ok, err = pcall(png.decode, liar)
    t.ok(not ok, name .. ": ожидалась ошибка")
    t.ok(tostring(err):find("png: too big", 1, true), name .. ": " .. tostring(err))
    t.eq(png.pad(liar, 32), liar, "pad: как есть")
  end
  t.ok(passes_size(1, M, 8, 0), "ровно MAX_BYTES серым проходит проверку размера")
  t.ok(passes_size(1, M / 4, 8, 6), "ровно MAX_BYTES RGBA проходит проверку размера")
end

-- RGBA 4M px — ~16M элементов Lua-таблиц, на Kindle PW2 (256 МБ) OOM: потолок в байтах, не в пикселях.
-- Страница устройства (1-битный серый), обложка (серый) и записи до 32×32 в любом цвете проходят
function T.test_max_bytes_fits_device_but_not_rgba_megapixels()
  t.ok(png.MAX_BYTES < 4 * 1024 * 1024, "меньше 4M байт вывода")
  t.ok(not passes_size(2048, 2048, 8, 6), "RGBA 4M px — отказ")
  for _, c in ipairs({ { 1072, 1448, 1, 0 }, { 1072, 1448, 8, 0 }, { 758, 1024, 8, 0 },
                       { 32, 32, 8, 6 }, { 32, 32, 8, 2 }, { 32, 32, 8, 4 } }) do
    local ok, err = passes_size(c[1], c[2], c[3], c[4])
    t.ok(ok, string.format("%dx%d depth=%d color=%d: %s", c[1], c[2], c[3], c[4], err))
  end
end

-- граница случайного касания: обе стороны строго меньше MIN_SIDE
function T.test_tiny_boundary()
  local m = png.MIN_SIDE
  t.eq(m, 32)
  t.eq(png.tiny(m - 1, m - 1), true, "31x31 — касание")
  t.eq(png.tiny(m, m - 1), false, "32x31 — не касание")
  t.eq(png.tiny(m - 1, m), false, "31x32 — не касание")
  t.eq(png.tiny(m, m), false, "32x32 — не касание")
  t.eq(png.tiny(1, 1), true)
  t.eq(png.tiny(5, 400), false, "одна узкая сторона — запись")
end

t.run(T)
