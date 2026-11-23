#!/bin/sh
# Проверка tools/gen_samples.py: --out/--phrase и неизменность режима без аргументов.
# Запуск: sh tools/check_gen_samples.sh   (нужен python с Pillow: PY=... или python3.11)
cd "$(dirname "$0")/.." || exit 1
fail() { echo "FAIL: $1"; exit 1; }
PY=${PY:-$(command -v python3.11 || command -v python3)}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# 1. --phrase: 2 PNG ширины 758 + samples.json с эталонами в порядке ввода
"$PY" -I tools/gen_samples.py --out "$T/p" --phrase "а" --phrase "б" >/dev/null || fail "gen --phrase"
[ "$(ls "$T/p" | wc -l | tr -d ' ')" = 3 ] || fail "ожидалось 3 файла (2 png + json): $(ls "$T/p")"
"$PY" -I - "$T/p" <<'PY' || fail "содержимое --phrase"
import json, sys
from pathlib import Path
from PIL import Image
d = Path(sys.argv[1])
meta = json.loads((d / "samples.json").read_text())
assert [m["text"] for m in meta] == ["а", "б"], meta
assert [m["file"] for m in meta] == sorted(m["file"] for m in meta), meta
assert meta[0]["file"].startswith("01_") and meta[1]["file"].startswith("02_"), meta
assert all(not m["bad"] for m in meta), meta
for m in meta:
    im = Image.open(d / m["file"])
    assert im.size[0] == 758 and list(im.size) == m["size"], (m, im.size)
PY

# 2. без аргументов: тот же набор, что закоммичен в HEAD:tools/samples (не рабочее дерево) (сделан версией до --out), байт в байт
mkdir -p "$T/new" "$T/head"
git archive HEAD tools/samples | tar -x -C "$T/head" || fail "git archive"
"$PY" -I tools/gen_samples.py --out "$T/new" >/dev/null || fail "gen new"
diff -r "$T/head/tools/samples" "$T/new" >/dev/null || fail "режим без аргументов разошёлся с tools/samples"

# 3. --out в каталог с готовыми *.png: отказ (старые NN_*.png попали бы в прогон devtest), каталог не тронут
mkdir -p "$T/dirty"
: > "$T/dirty/99_old.png"
if "$PY" -I tools/gen_samples.py --out "$T/dirty" --phrase "а" >/dev/null 2>&1; then fail "--out в каталог с png не отказал"; fi
[ "$(ls "$T/dirty")" = "99_old.png" ] || fail "отказ тронул каталог: $(ls "$T/dirty")"

# 4. N >= 100: номер шире (max(2, len(str(N)))), сортировка имён = порядок ввода
set --
i=0
while [ $i -lt 100 ]; do set -- "$@" --phrase "ф$i"; i=$((i + 1)); done
"$PY" -I tools/gen_samples.py --out "$T/n100" "$@" >/dev/null || fail "gen N=100"
"$PY" -I - "$T/n100" <<'PY' || fail "N=100: порядок имён"
import json, sys
from pathlib import Path
d = Path(sys.argv[1])
meta = json.loads((d / "samples.json").read_text())
files = [m["file"] for m in meta]
assert len(files) == 100, len(files)
assert files == sorted(files), "имена не в порядке ввода"
assert files[0].startswith("001_") and files[99].startswith("100_"), (files[0], files[99])
PY

# 5. пустая или пробельная --phrase: отказ, ничего не записано
for bad in "" "   "; do
    if "$PY" -I tools/gen_samples.py --out "$T/empty" --phrase "а" --phrase "$bad" >/dev/null 2>&1; then
        fail "пустая --phrase [$bad] не отказала"
    fi
    [ ! -e "$T/empty" ] || [ -z "$(ls "$T/empty")" ] || fail "отказ на пустой --phrase записал файлы"
done
# 6. --phrase без --out: отказ до любой записи (иначе пишет поверх закоммиченного tools/samples).
# Гоняем копию tools/ и шрифта: OUT скрипта считается от его пути, настоящий tools/samples не рискует
mkdir -p "$T/copy/assets"
cp -R tools "$T/copy/tools"
cp -R assets/fonts "$T/copy/assets/fonts"
"$PY" -I "$T/copy/tools/gen_samples.py" --phrase "а" >/dev/null 2>"$T/err6" && fail "--phrase без --out не отказал"
grep -q -- "--out" "$T/err6" || fail "отказ --phrase без --out не по делу: $(cat "$T/err6")"
diff -r tools/samples "$T/copy/tools/samples" >/dev/null || fail "отказ --phrase без --out тронул tools/samples"
echo "OK"
