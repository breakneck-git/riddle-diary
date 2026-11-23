#!/bin/sh
# Read-only: tail of the device log (riddle: lines and errors), powerd state, leftover PNGs.
# usage: tools/kindle_log.sh [lines]   (default 120)
# Groq org id in 429 bodies is cut out of the output. Lines are cut by characters (UTF-8 locale), not bytes:
# Russian text is not chopped mid-letter; 700 chars keep a whole answer line.
n=${1:-120}
# n goes into the remote command: digits only, bounded (no injection through the allow rule)
case "$n" in ''|*[!0-9]*) echo 'n: только число' >&2; exit 2;; esac
# больше 4 цифр — сразу отказ: на ~19+ цифрах [ -gt ] падает и пропускает проверку ниже
case "$n" in ?????*) echo 'n: не больше 2000' >&2; exit 2;; esac
if [ "$n" -gt 2000 ]; then echo 'n: не больше 2000' >&2; exit 2; fi
ssh kindle "tail -n $n /mnt/us/koreader/crash.log | grep -E 'riddle|ERROR'; echo '-- powerd:' \$(lipc-get-prop com.lab126.powerd state); echo '-- samples left:' \$(ls /mnt/us/riddle/samples | wc -l)" \
  | sed -E 's/organization `[^`]*`/organization …/' | LC_ALL=en_US.UTF-8 cut -c1-700
