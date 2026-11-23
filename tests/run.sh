#!/bin/sh
# Гоняет каждый tests/*_spec.lua через luajit; exit≠0 при любом провале.
cd "$(dirname "$0")/.." || exit 1
export LUA_PATH="plugin/riddlediary.koplugin/?.lua;tests/vendor/?.lua;tests/?.lua;;"
export DYLD_LIBRARY_PATH="$(brew --prefix sqlite 2>/dev/null)/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
n=0; bad=0; failed=""
for f in tests/*_spec.lua; do
  [ -e "$f" ] || continue
  n=$((n + 1))
  echo "== $f"
  luajit "$f" || { bad=$((bad + 1)); failed="$failed $f"; }
done
if [ "$bad" -gt 0 ]; then
  echo "$n specs, $bad FAILED:$failed"
  exit 1
fi
echo "$n specs, OK"
