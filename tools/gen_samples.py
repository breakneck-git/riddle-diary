#!/usr/bin/env python3
"""Синтетические «пальцевые» образцы рукописного русского текста.

Рукописный шрифт MarckScript -> по-символьно с дрожанием базовой линии,
размера, наклона; толстая линия (обводка) + шум по контуру.
Выход: tools/samples/NN_<slug>.png, ширина 758, ч/б, + samples.json с эталоном.

  --out DIR      писать в DIR вместо tools/samples; в DIR не должно быть *.png
  --phrase TEXT  (повторяемый) свои фразы вместо зашитых PHRASES, уровень 0;
                 имена NN_<slug>.png идут по порядку ввода; требует --out
                 (иначе легли бы поверх закоммиченного tools/samples)
"""
import argparse
import json
import random
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT = ROOT / "assets/fonts/MarckScript-Regular.ttf"
OUT = Path(__file__).resolve().parent / "samples"
W = 758

PHRASES = [
    ("Привет, кто ты?", 0),
    ("Как тебя зовут?", 0),
    ("Что ты знаешь о моём будущем?", 0),
    ("Сегодня был длинный день", 0),
    ("Ты живой?", 0),
    ("Где спрятан ключ от старой комнаты?", 0),
    ("Я боюсь темноты. Расскажи сказку", 0),
    ("Кто написал этот дневник?", 0),
    ("Привет, кто ты?", 1),          # «хуже»: крупнее и кривее
    ("Что ты знаешь о моём будущем?", 1),
]


TRANSLIT = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя", [
    "a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n",
    "o", "p", "r", "s", "t", "u", "f", "h", "c", "ch", "sh", "sch", "", "y", "",
    "e", "yu", "ya"]))


def slug(text, limit=24):
    """ASCII-имя для файла: транслит, не-алфавитное -> «_», обрезка по limit."""
    s = "".join(TRANSLIT.get(c, c) for c in text.lower())
    s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")[:limit].strip("_")
    return s or "phrase"


def wrap(text, font, size, maxw):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if font.getlength(t) * size / font.size > maxw and cur:
            lines.append(cur)
            cur = w
        else:
            cur = t
    lines.append(cur)
    return lines


def render(text, bad, seed):
    rnd = random.Random(seed)
    base = 58 if not bad else 92
    jitter_y = 5 if not bad else 12
    jitter_s = 0.08 if not bad else 0.2
    rot = 4 if not bad else 10
    stroke = 0 if not bad else 1
    probe = ImageFont.truetype(str(FONT), base)
    lines = wrap(text, probe, base, (W - 60) / (1.15 if not bad else 1.4))
    line_h = int(base * 1.35)
    H = max(150, min(600, 40 + line_h * len(lines) + 30))
    img = Image.new("L", (W, H), 255)
    y = 25
    for line in lines:
        x = 20 + rnd.randint(0, 20)
        drift = rnd.uniform(-0.12, 0.12) if not bad else rnd.uniform(-0.3, 0.3)
        for ch in line:
            size = int(base * (1 + rnd.uniform(-jitter_s, jitter_s)))
            f = ImageFont.truetype(str(FONT), size)
            adv = f.getlength(ch)
            if ch == " ":
                x += adv * rnd.uniform(0.9, 1.6)
                continue
            pad = size
            tile = Image.new("L", (int(adv) + 2 * pad, size * 2 + pad), 0)
            ImageDraw.Draw(tile).text((pad, pad // 2), ch, font=f, fill=255,
                                      stroke_width=stroke, stroke_fill=255)
            tile = tile.rotate(rnd.uniform(-rot, rot) - 8, resample=Image.BICUBIC,
                               expand=False)
            yy = int(y + (x - 20) * drift * 0.15 + rnd.uniform(-jitter_y, jitter_y))
            img.paste(0, (int(x) - pad, yy - pad // 2), tile)
            x += adv * rnd.uniform(0.92, 1.12 if not bad else 1.3)
            if x > W - 20:
                break
        y += line_h + (rnd.randint(-6, 10) if bad else 0)
    # «пальцевый» неровный край: блюр + порог, ч/б 1 бит
    img = img.filter(ImageFilter.GaussianBlur(0.8 if not bad else 1.2))
    img = img.point(lambda v: 0 if v < 170 else 255, mode="1")
    return img


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--phrase", action="append", default=None)
    args = ap.parse_args(argv)
    if args.phrase and args.out is None:
        ap.exit(2, "gen_samples: --phrase требует --out (tools/samples — закоммиченный набор)\n")
    if args.out is not None and any(args.out.glob("*.png")):
        ap.exit(2, f"gen_samples: в {args.out} уже есть *.png — выбери пустой каталог\n")
    if args.phrase and not all(t.strip() for t in args.phrase):
        ap.exit(2, "gen_samples: --phrase не может быть пустой или из одних пробелов\n")
    out = args.out or OUT
    if args.phrase:
        items = [(t, 0, slug(t)) for t in args.phrase]
    else:
        items = [(t, bad, "bad" if bad else "ok") for t, bad in PHRASES]
    out.mkdir(parents=True, exist_ok=True)
    meta = []
    width = max(2, len(str(len(items))))
    for i, (text, bad, tag) in enumerate(items, 1):
        img = render(text, bad, seed=1000 + i)
        name = f"{i:0{width}d}_{tag}.png"
        img.save(out / name, optimize=True)
        meta.append({"file": name, "text": text, "bad": bool(bad),
                     "size": list(img.size)})
    (out / "samples.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    for m in meta:
        p = out / m["file"]
        print(m["file"], m["size"], p.stat().st_size, "B", m["text"])


if __name__ == "__main__":
    sys.exit(main())
