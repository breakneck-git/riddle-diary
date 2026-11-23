# Генератор фикстур для tests/png_spec.lua: 8-битные PNG с узором px(x, y, c) (тот же — в спеке),
# серые 1/2/4 бит (так пишет устройство) — узор lowbit(x, y, depth); строки с фильтрами 0..4
# по кругу, IDAT сжат zlib разными способами (dynamic, fixed, stored).
# Запуск: python3 tests/fixtures/png/gen.py
import os, struct, zlib

def px(x, y, c):
    return 255 if (x + y) % 5 else (x * 7 + y * 13 + c * 50) % 200

def lowbit(x, y, depth):
    top = (1 << depth) - 1
    return top if (x + y) % 5 else (x * 7 + y * 13) % (top + 1)

def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)

def packed(w, y, depth):
    out, acc, n = bytearray(), 0, 0
    for x in range(w):
        acc = (acc << depth) | lowbit(x, y, depth)
        n += depth
        if n == 8:
            out.append(acc); acc, n = 0, 0
    if n:
        out.append(acc << (8 - n))
    return bytes(out)

def png(w, h, ctype, chans, mode, depth=8):
    stride = (w * chans * depth + 7) // 8
    raw, prev = b"", bytes(stride)
    bpp = max(1, chans * depth // 8)
    for y in range(h):
        if depth == 8:
            row = bytes(px(x, y, c) for x in range(w) for c in range(chans))
        else:
            row = packed(w, y, depth)
        f = y % 5
        out = bytearray([f])
        for i, v in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            p = [0, a, b, (a + b) // 2, paeth(a, b, c)][f]
            out.append((v - p) % 256)
        raw += bytes(out)
        prev = row
    if mode == "stored":
        z = zlib.compressobj(0)
    elif mode == "fixed":
        z = zlib.compressobj(9, zlib.DEFLATED, 15, 9, zlib.Z_FIXED)
    else:
        z = zlib.compressobj(9)
    data = z.compress(raw) + z.flush()
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", data) + chunk(b"IEND", b"")

# IHDR обещает w×h, а IDAT распаковывается в raw (больше (stride+1)*h): проверка потолка inflate
def liar(w, h, raw, strategy):
    z = zlib.compressobj(9, zlib.DEFLATED, 15, 9, strategy)
    data = z.compress(raw) + z.flush()
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", data) + chunk(b"IEND", b"")

here = os.path.dirname(os.path.abspath(__file__))
for name, data in {
    # мегабайт нулей — почти одни копии (length/distance)
    "bomb2x2_copies.png": liar(2, 2, bytes(1000000), zlib.Z_DEFAULT_STRATEGY),
    # 2×2 — 6 байт строк; седьмой литерал лишний (только литералы, без копий)
    "bomb2x2_literals.png": liar(2, 2, b"\0\1\2\0\3\4\5", zlib.Z_HUFFMAN_ONLY),
}.items():
    with open(os.path.join(here, name), "wb") as f:
        f.write(data)
for name, args in {
    "g17x31_dynamic.png": (17, 31, 0, 1, "dynamic"),
    "g17x31_fixed.png": (17, 31, 0, 1, "fixed"),
    "g17x31_stored.png": (17, 31, 0, 1, "stored"),
    "g40x10_dynamic.png": (40, 10, 0, 1, "dynamic"),
    "rgb5x5_dynamic.png": (5, 5, 2, 3, "dynamic"),
    "b1_17x31_dynamic.png": (17, 31, 0, 1, "dynamic", 1),
    "b2_13x9_dynamic.png": (13, 9, 0, 1, "dynamic", 2),
    "b4_11x7_fixed.png": (11, 7, 0, 1, "fixed", 4),
}.items():
    with open(os.path.join(here, name), "wb") as f:
        f.write(png(*args))
