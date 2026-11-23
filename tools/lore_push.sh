#!/bin/sh
# Заливает lore.md на Kindle. Контроллер импортирует его в базу по mtime файла.
# usage: tools/lore_push.sh [путь-к-lore.md]
set -e
cd "$(dirname "$0")/.."
SRC="${1:-lore.md}"
[ -f "$SRC" ] || { echo "нет файла: $SRC" >&2; exit 1; }
ssh kindle 'mkdir -p /mnt/us/riddle'
scp -q "$SRC" kindle:/mnt/us/riddle/lore.md
ssh kindle 'ls -l /mnt/us/riddle/lore.md'
