#!/usr/bin/env python3
"""Обложка экрана сна: cover_A.png, cover_B.png, cover_B2.png, cover_C.png (758x1024, серый) из фото дневника с клыком.

Использование: python3 -I tools/make_cover.py <diary_fang_original.jpg> <каталог вывода>
Зависимости: Pillow, numpy. Оригинал в git не лежит (assets/img/CREDITS.md).

Шаги: серый -> поворот на 20 градусов по часовой (боковые края обложки встают по вертикали) -> маска клыка по
яркости (порог на 1/4 масштаба, заливка от точки на клыке) -> фон вне книги гасится в чёрный -> кадр 758x1024.
 A: без клыка: нижняя часть обложки плавно уходит в чёрный над местом, где клык ложится на книгу.
 B: книга целиком, клык закрашен чёрным с мягким краем, нижний левый угол под клыком уходит в тень.
 B2: как B, но после поворота обложка ещё выпрямлена перспективой: четырёхугольник по четырём краям
     (QUAD) переведён в прямоугольник. Одним поворотом не обойтись: верх обложки идёт на -3,9 градуса,
     низ на -0,4, левый край на +0,9, правый на -0,4 (съёмка под углом).
 C (экран сна, assets/img/cover_sleep.png): выпрямленная обложка B2 во весь экран, без чёрных полей.
     Кадр FRAME_C — от верха верхнего уголка до низа нижнего по высоте, от левого края обложки (внутрь,
     без тёмной кромки) до правого края нижнего уголка; уголки целиком, с полями в 4–5 px. Всё, что в кадре
     не обложка (клык, тень под ним, чёрный фон у выступающих уголков и у обреза страниц), дорисовано
     патчами из самой обложки (Criminisi: заполнение от края дыры, порядок — по уверенности и продолжению
     линий, патч 9x9 ищется по SSD рядом). Нижний левый угол под клыком — кожа обложки, кромки (верхняя
     левее уголка, нижняя левее уголка) тоже дорисованы: обложка уходит за край экрана. Обрез страниц
     дорисовывается только из обреза, остальное — только из кожи; уголки источником не бывают. Поля у
     уголков (там патч повторяется патч в патч) сглажены в тень не светлее кожи рядом.
     Кадр по ширине меньше экрана (0,63 против 0,74): по ширине растяжение 5 %, остальное — вставка швов (seam carving
     наоборот: дублируются вертикальные швы наименьшей энергии, по однородной коже, мимо уголков и обреза).
Координаты ниже — в пикселях повёрнутого изображения, уменьшенного в 4 раза (PV); для C — в PV после перспективы B2.
"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SRC, OUT = sys.argv[1], sys.argv[2]
ANGLE = 20          # поворот по часовой, градусы (замер по левому и правому краю обложки)
Q = 4               # во сколько раз PV меньше полного разрешения
W, H = 758, 1024    # экран Kindle PW2
FANG_SEED = (200, 600)
BOOK = (374, 314, 834, 1032)   # рамка книги в PV: x0, y0, x1, y1 (с запасом на уголки и обрез страниц)
TOUCH_Y = 860                  # в PV: ниже клык ложится на обложку
CHIP = (678, 1012, 706, 1040)  # в PV: осколок под нижним краем книги (B)
# углы обложки в PV после поворота: пересечения прямых, подогнанных по точкам кромки (верх, низ, лево, право;
# уголки и клык в подгонку не входят): TL, TR, BR, BL
QUAD = ((373.0, 340.7), (829.9, 309.9), (824.7, 1010.5), (383.4, 1013.5))
BOOK_MARGIN = (-1, -4, 8, 19)  # поля рамки B2 вокруг прямоугольника обложки: лево, верх, право, низ
FRAME_C = (386.0, 317.5, 835.0, 1033.0)  # кадр C: x0, y0, x1, y1
RIMS_C = ((0, 0, 684.9, 329.8), (0, 996.3, 720.7, 1100))  # кромки обложки левее уголков: верхняя, нижняя (дорисовать)
CORNERS_C = ((684.9, 316.3, 813.4, 467.5), (719.4, 923.8, 834.4, 1033.8))  # уголки: верхний, нижний
PAGES_X_C = 812.4              # правее — обрез страниц
STRETCH_C = 1.05               # растяжение C по ширине; остальное до W — швы

im = Image.open(SRC).convert("L")
rot0 = im.rotate(-ANGLE, resample=Image.BICUBIC, expand=True, fillcolor=0)


def homography(src, dst):
    """3x3: src -> dst по четырём парам точек."""
    a, b = [], []
    for (x, y), (u, v) in zip(src, dst):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    h = np.linalg.solve(np.array(a, float), np.array(b, float))
    return np.append(h, 1).reshape(3, 3)


def apply(h, p):
    x, y, w = h @ np.array([p[0], p[1], 1.0])
    return x / w, y / w


def rect_target():
    d = lambda p, q: np.hypot(p[0] - q[0], p[1] - q[1])
    tl, tr, br, bl = QUAD
    w, h = (d(tl, tr) + d(bl, br)) / 2, (d(tl, bl) + d(tr, br)) / 2
    cx, cy = np.mean([p[0] for p in QUAD]), np.mean([p[1] for p in QUAD])
    return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)


def fang_flood(pv):
    """Клык в PV: яркое (> 170), связное с FANG_SEED; 255 — клык."""
    m = Image.fromarray(((np.asarray(pv) > 170) * 255).astype(np.uint8))
    m = m.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5))
    assert m.getpixel(FANG_SEED) == 255, "точка заливки не на клыке"
    ImageDraw.floodfill(m, FANG_SEED, 128)
    return Image.fromarray((np.asarray(m) == 128).astype(np.uint8) * 255)


def build(rot, book_box, chip_box, name_a, name_b):
    """Маски и кадры по повёрнутому изображению rot; name_a / name_b — имена файлов или None."""
    pv = rot.resize((rot.width // Q, rot.height // Q), Image.LANCZOS)

    def fang_mask():
        return fang_flood(pv).filter(ImageFilter.MaxFilter(21)).filter(ImageFilter.GaussianBlur(6))

    def rect_mask(box, feather):
        m = Image.new("L", pv.size, 0)
        ImageDraw.Draw(m).rectangle(box, fill=255)
        return m.filter(ImageFilter.GaussianBlur(feather))

    def mul(a, b):
        return Image.fromarray((np.asarray(a).astype(np.float32) * np.asarray(b).astype(np.float32) / 255).astype(np.uint8))

    def vignette_corner(cx, cy, r):
        """Спад от угла (cx, cy) в PV: 0 в углу, 255 дальше r."""
        yy, xx = np.mgrid[0:pv.height, 0:pv.width]
        d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / r
        return Image.fromarray((np.clip(d, 0, 1) ** 1.5 * 255).astype(np.uint8))

    def render(mask_pv, scale, cx, cy_pv, cy_screen):
        """Полноразмерный rot * маска (PV, растянутая) -> кадр W x H: точка PV (cx, cy_pv) в (W/2, cy_screen)."""
        m = mask_pv.resize(rot.size, Image.BILINEAR)
        full = Image.fromarray((np.asarray(rot).astype(np.float32) * np.asarray(m).astype(np.float32) / 255).astype(np.uint8))
        x0 = cx - (W / 2) / scale
        y0 = cy_pv - cy_screen / scale
        box = (x0 * Q, y0 * Q, (x0 + W / scale) * Q, (y0 + H / scale) * Q)
        return full.resize((W, H), Image.LANCZOS, box=box)

    book_box = tuple(book_box)
    not_fang = Image.eval(fang_mask(), lambda v: 255 - v)
    book = rect_mask((book_box[0] - 6, book_box[1] - 6, book_box[2] + 6, book_box[3] + 6), 8)   # фон вне книги -> чёрный
    cx = (book_box[0] + book_box[2]) / 2

    if name_a:
        # A: слева обрезка по краю книги, снизу плавный спад в чёрный над точкой касания клыка
        keep_a = rect_mask((book_box[0] - 6, book_box[1] - 6, book_box[2] + 6, TOUCH_Y - 30), 18)
        mask_a = mul(mul(book, keep_a), not_fang)
        s_a = 1.38
        shown = (TOUCH_Y - book_box[1]) * s_a
        render(mask_a, s_a, cx, book_box[1], (H - shown) / 2).save(f"{OUT}/{name_a}")

    if name_b:
        # B: книга целиком; клык закрашен, угол под клыком уходит в тень
        vig = vignette_corner(book_box[0] - 10, book_box[3] + 10, 330)
        keep_b = Image.fromarray(np.minimum(np.asarray(vig).astype(np.uint16) * 3, 255).astype(np.uint8))
        chip = Image.new("L", pv.size, 255)
        ImageDraw.Draw(chip).rectangle(chip_box, fill=0)
        chip = chip.filter(ImageFilter.GaussianBlur(2))
        mask_b = mul(mul(mul(book, not_fang), keep_b), chip)
        s_b = 1.25
        render(mask_b, s_b, cx, (book_box[1] + book_box[3]) / 2, H / 2).save(f"{OUT}/{name_b}")


build(rot0, BOOK, CHIP, "cover_A.png", "cover_B.png")

# B2: перспектива. Выходной пиксель (в полном разрешении) берётся из rot0 по обратной гомографии
x0, y0, x1, y1 = rect_target()
target = ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
back = homography([(x * Q, y * Q) for x, y in target], [(x * Q, y * Q) for x, y in QUAD])
coeffs = (back / back[2, 2]).flatten()[:8]
rot1 = rot0.transform(rot0.size, Image.PERSPECTIVE, tuple(coeffs), resample=Image.BICUBIC, fillcolor=0)
fwd = homography(QUAD, target)
cc = apply(fwd, ((CHIP[0] + CHIP[2]) / 2, (CHIP[1] + CHIP[3]) / 2))
chip2 = (cc[0] - 14, cc[1] - 14, cc[0] + 14, cc[1] + 14)
m = BOOK_MARGIN
book2 = (x0 + m[0], y0 + m[1], x1 + m[2], y1 + m[3])
build(rot1, book2, chip2, None, "cover_B2.png")


def inpaint(img, hole, sources, ignore, patch=9, radius=110):
    """Criminisi: дыра hole (bool) в img (float32) заполняется патчами patch x patch из нетронутых пикселей.
    sources(y, x) -> bool-карта допустимых пикселей-источников для точки дыры (y, x); пиксели ignore в сравнении
    патчей не участвуют (иначе у яркого уголка дорисуется яркое). Ищется в окне ±radius,
    при пустом окне оно удваивается; лёгкий штраф за расстояние держит тон соседей."""
    p = patch // 2
    img, hole = img.copy(), hole.copy()
    h, w = img.shape
    conf = (~hole).astype(np.float32)
    img[hole] = 0
    valid = {}
    g = np.asarray(Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.5)), np.float32)
    gy, gx = np.gradient(g)
    gmag = np.hypot(gx, gy) * (~hole)
    while hole.any():
        known = ~hole
        nb = np.zeros_like(hole)
        nb[1:] |= known[:-1]; nb[:-1] |= known[1:]; nb[:, 1:] |= known[:, :-1]; nb[:, :-1] |= known[:, 1:]
        fy, fx = np.nonzero(hole & nb)
        # приоритет = уверенность (доля известного в патче) x продолжение линий (изофота поперёк края дыры)
        cs = swv(np.pad(conf, p), (patch, patch))[fy, fx].sum(axis=(1, 2)) / patch ** 2
        mb = np.asarray(Image.fromarray(hole.astype(np.uint8) * 255).filter(ImageFilter.GaussianBlur(2)), np.float32)
        ny, nx = np.gradient(mb)
        nn = np.hypot(nx, ny) + 1e-6
        j = swv(np.pad(gmag, p), (patch, patch))[fy, fx].reshape(len(fy), -1).argmax(axis=1)
        qy = np.clip(fy + j // patch - p, 0, h - 1)
        qx = np.clip(fx + j % patch - p, 0, w - 1)
        ds = np.abs(-gx[qy, qx] * ny[fy, fx] + gy[qy, qx] * nx[fy, fx]) / nn[fy, fx] / 255 + 0.001
        k = int((cs * ds).argmax())
        py, px = fy[k], fx[k]
        y0, y1, x0, x1 = max(py - p, 0), min(py + p + 1, h), max(px - p, 0), min(px + p + 1, w)
        tp, tk = img[y0:y1, x0:x1], (known & ~ignore)[y0:y1, x0:x1].astype(np.float32)
        ph, pw, oy, ox = y1 - y0, x1 - x0, py - y0, px - x0
        src = sources(py, px)
        if id(src) not in valid:   # центр годен, если весь его патч — источник
            valid[id(src)] = swv(np.pad(src, p, constant_values=False), (patch, patch)).all(axis=(2, 3))
        ok = valid[id(src)]
        r = radius
        while True:
            sy0, sy1 = max(py - r, p), min(py + r + 1, h - p)
            sx0, sx1 = max(px - r, p), min(px + r + 1, w - p)
            if ok[sy0:sy1, sx0:sx1].any():
                break
            r *= 2
        cand = swv(img[sy0 - oy:sy1 - oy + ph - 1, sx0 - ox:sx1 - ox + pw - 1], (ph, pw))
        cost = np.einsum("abij,ij->ab", (cand - tp) ** 2, tk) / max(tk.sum(), 1)
        yy, xx = np.mgrid[sy0:sy1, sx0:sx1]
        cost += 0.002 * ((yy - py) ** 2 + (xx - px) ** 2)
        cost[~ok[sy0:sy1, sx0:sx1]] = np.inf
        cy, cx = np.unravel_index(np.argmin(cost), cost.shape)
        cy, cx = cy + sy0, cx + sx0
        fill = hole[y0:y1, x0:x1]
        tp[fill] = img[cy - oy:cy - oy + ph, cx - ox:cx - ox + pw][fill]
        conf[y0:y1, x0:x1][fill] = cs[k]
        hole[y0:y1, x0:x1] = False
    return img


def widen(img, protect, w_out):
    """Вставка вертикальных швов до ширины w_out: швы наименьшей энергии (сглаженный градиент) ищутся
    последовательным удалением, protect (bool) для них закрыт, соседство с уже найденными штрафуется
    (швы не слипаются в одну растянутую полосу); каждый найденный столбец дублируется средним с соседом."""
    h, w = img.shape
    g = np.asarray(Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1)), np.float32)
    gy, gx = np.gradient(g)
    e = swv(np.pad(np.hypot(gx, gy), 3, mode="edge"), (7, 7)).mean(axis=(2, 3))
    e[protect] += 1e5
    pen = np.zeros_like(e)
    idx = np.tile(np.arange(w), (h, 1))
    rows = np.arange(h)
    seams = []
    for _ in range(w_out - w):
        m = np.take_along_axis(e + pen, idx, axis=1)
        ww = m.shape[1]
        back = np.zeros((h, ww), np.int8)
        for r in range(1, h):
            prev = m[r - 1]
            st = np.stack([np.r_[np.inf, prev[:-1]], prev, np.r_[prev[1:], np.inf]])
            a = st.argmin(axis=0)
            m[r] += st[a, np.arange(ww)]
            back[r] = a - 1
        path = np.empty(h, int)
        j = int(m[-1].argmin())
        for r in range(h - 1, -1, -1):
            path[r] = j
            j += back[r, j]
        col = idx[rows, path]
        seams.append(col)
        for dx in range(-3, 4):
            pen[rows, np.clip(col + dx, 0, w - 1)] += 40.0 * (4 - abs(dx))
        keep = np.ones((h, ww), bool)
        keep[rows, path] = False
        idx = idx[keep].reshape(h, ww - 1)
    cols = np.sort(np.array(seams).T, axis=1)
    out = np.empty((h, w_out), np.float32)
    for r in range(h):
        row = img[r]
        out[r] = np.insert(row, cols[r] + 1, (row[cols[r]] + row[np.minimum(cols[r] + 1, w - 1)]) / 2)
    return out


# C: B2 во весь экран. Работа идёт в высоте экрана: кадр -> H по высоте (ширина ~643), дорисовка, расширение
from numpy.lib.stride_tricks import sliding_window_view as swv

fbox = tuple(v * Q for v in FRAME_C)
sc = H / (fbox[3] - fbox[1])
wc = int(round((fbox[2] - fbox[0]) * sc))
to_c = lambda x, y: ((x * Q - fbox[0]) * sc, (y * Q - fbox[1]) * sc)   # PV -> кадр C
img_c = np.asarray(rot1.resize((wc, H), Image.LANCZOS, box=fbox), np.float32)


def box_mask(boxes):
    m = Image.new("L", (wc, H), 0)
    for x0_, y0_, x1_, y1_ in boxes:
        ImageDraw.Draw(m).rectangle((to_c(x0_, y0_), to_c(x1_, y1_)), fill=255)
    return np.asarray(m) > 0


def grow(mask, n):
    return np.asarray(Image.fromarray(mask.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(n))) > 0


pv1 = rot1.resize((rot1.width // Q, rot1.height // Q), Image.LANCZOS)
fang_c = np.asarray(fang_flood(pv1).filter(ImageFilter.MaxFilter(7)).resize(rot1.size, Image.BILINEAR)
                    .resize((wc, H), Image.BILINEAR, box=fbox)) > 64
# фон: тёмное (< 45 после размытия), связное с краем кадра
dark = np.asarray(Image.fromarray(img_c.astype(np.uint8)).filter(ImageFilter.GaussianBlur(2))) < 45
ring = Image.fromarray(np.pad(dark.astype(np.uint8) * 255, 1, constant_values=255)).copy()  # copy: floodfill по буферу numpy не пишет
ImageDraw.floodfill(ring, (0, 0), 128)
hole_c = grow(fang_c | (np.asarray(ring)[1:-1, 1:-1] == 128) | box_mask(RIMS_C), 5)
# недостижимое от середины обложки, не пересекая дыру (нижняя часть клыка за тёмной трещиной), — тоже дыра
reach = Image.fromarray((~hole_c).astype(np.uint8) * 255).copy()
ImageDraw.floodfill(reach, (wc // 2, H // 2), 128)
hole_c = grow(np.asarray(reach) != 128, 3)

corners_c = box_mask(CORNERS_C)
metal = corners_c & (np.asarray(Image.fromarray(img_c.astype(np.uint8)).filter(ImageFilter.GaussianBlur(1))) > 75)
hole_c &= ~metal          # расширение дыры не съедает кромку уголков
pages_xc = to_c(PAGES_X_C, 0)[0]
cols_c = np.arange(wc)[None, :]
src_pages = ~hole_c & ~corners_c & (cols_c >= pages_xc - 4)
src_leather = ~hole_c & ~corners_c & (cols_c < pages_xc - 4)
filled_c = inpaint(img_c, hole_c, lambda y, x: src_pages if x >= pages_xc else src_leather, corners_c)


# поля вокруг уголков (фон у металла): патч там повторяется патч в патч — вместо узора тень: размытое
# дорисованное, не светлее кожи рядом; к металлу полностью, дальше 6 px — плавно на нет
def blur_n(a, mask, r):
    """Размытие a только по пикселям mask (нормированное); вес — доля mask в окрестности."""
    f = lambda v: np.asarray(Image.fromarray(np.clip(v, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r)), np.float32)
    wgt = f(np.where(mask, 255.0, 0.0))
    return f(np.where(mask, a, 0)) * 255 / np.maximum(wgt, 1), wgt / 255


soft, _ = blur_n(filled_c, hole_c, 2.5)
near, wn = blur_n(filled_c, ~hole_c & ~corners_c & (cols_c < pages_xc - 4), 12)
shade = np.minimum(soft, np.where(wn > 0.02, near, soft))
alpha = np.asarray(Image.fromarray(grow(metal, 13).astype(np.uint8) * 255).filter(ImageFilter.GaussianBlur(3)), np.float32) / 255
alpha = np.where(hole_c & corners_c, alpha, 0)
filled_c = (filled_c * (1 - alpha) + shade * alpha).astype(np.float32)

w1 = int(round(wc * STRETCH_C))
img_w = np.asarray(Image.fromarray(filled_c).resize((w1, H), Image.LANCZOS), np.float32)
protect = np.asarray(Image.fromarray(corners_c.astype(np.uint8) * 255).resize((w1, H), Image.NEAREST)) > 0
protect[:, int(w1 * 0.93):] = True   # обрез страниц и правая кромка обложки
protect[:, :3] = True
Image.fromarray(np.clip(widen(img_w, protect, W), 0, 255).round().astype(np.uint8)).save(f"{OUT}/cover_C.png")
