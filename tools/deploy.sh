#!/bin/sh
# Deploy riddlediary.koplugin to the Kindle and restart KOReader (no full Kindle reboot).
# usage: tools/deploy.sh [--dev] [testmode-string]   e.g. tools/deploy.sh "cycles=10 exit=1"
# Every deploy sets /mnt/us/riddle/watch (the restart watcher is on at the next KOReader start, debug stays off).
# By default devmode is REMOVED before the restart: the new process runs without the devtest harness and
# without the verbose read log. --dev (or a testmode string, which only devtest understands) creates
# /mnt/us/riddle/devmode instead: watcher plus debug, and the devtest sample sets of tools/devsets/ go to
# /mnt/us/riddle/devsamples/<set>/ (devtest "feed=N set=<set>").
#
# Copies the whole plugin including riddle/. Syntax is checked locally before the copy
# and with the device's own LuaJIT after it; a failure stops before the restart.
# Restart (needs KOReader started with watch or devmode): the plugin polls /mnt/us/riddle/restart
# and does UIManager:restartKOReader() (exit 85 -> koreader.sh relaunches in place,
# settings flushed, Kindle framework never comes back). Without a running KOReader,
# start it detached as the boot job does (/etc/upstart/koreader-boot.conf): --framework_stop.
set -e
cd "$(dirname "$0")/.."
DEV=0
if [ "$1" = "--dev" ]; then DEV=1; shift; fi
if [ -n "$1" ]; then DEV=1; fi
PLUG=plugin/riddlediary.koplugin
DEST=/mnt/us/koreader/plugins/riddlediary.koplugin
for f in $PLUG/*.lua $PLUG/riddle/*.lua; do luajit -b "$f" /dev/null; done
ssh kindle "mkdir -p /mnt/us/riddle/samples $DEST"
ssh kindle "touch /mnt/us/riddle/watch"
if [ "$DEV" = 1 ]; then ssh kindle "touch /mnt/us/riddle/devmode"; else ssh kindle "rm -f /mnt/us/riddle/devmode"; fi
scp -q -r $PLUG/* kindle:$DEST/
# build version for the status page: one line, written only here (the plugin dir has no git on the device);
# VER on its own line so set -e catches a git failure, and it goes over stdin, not into the remote command
VER=$(git describe --always --dirty)
printf '%s\n' "$VER" | ssh kindle "cat >$DEST/version"
# syntax check with the device's own LuaJIT
ssh kindle "cd /mnt/us/koreader && for f in plugins/riddlediary.koplugin/*.lua plugins/riddlediary.koplugin/riddle/*.lua; do ./luajit -b \"\$f\" /dev/null || exit 1; done"
# dev only: sample sets for devtest "feed=N set=<name>": tools/devsets/<name>/*.png -> /mnt/us/riddle/devsamples/<name>/.
# The set's old PNGs go first (a renamed sample must not stay in the round); the owner's diary gets none
if [ "$DEV" = 1 ]; then
  for d in tools/devsets/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    ssh kindle "mkdir -p /mnt/us/riddle/devsamples/$name/ && rm -f /mnt/us/riddle/devsamples/$name/*.png"
    scp -q "$d"*.png "kindle:/mnt/us/riddle/devsamples/$name/"
  done
fi
if [ -n "$1" ]; then ssh kindle "echo '$1' >/mnt/us/riddle/testmode"; fi
# KOReader runs: ask the plugin's watcher to restart and wait until the device log confirms it
# ("riddle: dev restart requested"). A lone touch proves nothing: a deploy that lands while KOReader is
# starting loses the file (maybeStartDevWatch drops a restart left by an earlier process), and a watcher
# is on only if KOReader itself started with watch or devmode. So touch again, up to 3 times; no confirmation -> fail.
LOG=/mnt/us/koreader/crash.log
MARK="riddle: dev restart requested"
POLL_S=${RESTART_POLL_S:-1}
# last confirmation line of the device log (empty: none yet, or the log is missing). Not a count:
# koreader.sh cuts the head of crash.log on every start (tail -c 500000), so old lines vanish and a
# count may not grow after a restart. The remote pipeline exits 0, so a nonzero ssh status = link lost.
last_restart() { ssh kindle "grep '$MARK' $LOG 2>/dev/null | tail -1"; }
# pidof: 0 running, 1 not running, anything else (ssh gives 255) = no link: stop, launch nothing
rc=0
ssh kindle 'pidof reader.lua >/dev/null' || rc=$?
case $rc in
  0)
    before=$(last_restart) || { echo "ssh to the Kindle failed while reading $LOG: restart not attempted." >&2; exit 1; }
    for attempt in 1 2 3; do
      ssh kindle 'touch /mnt/us/riddle/restart'
      for _ in 1 2 3 4 5 6; do
        sleep "$POLL_S"
        now=$(last_restart) || now=""
        # confirmed: a line exists and differs from the one before the touch (lines carry a timestamp)
        if [ -n "$now" ] && [ "$now" != "$before" ]; then echo "restart confirmed"; exit 0; fi
      done
    done
    echo "restart NOT confirmed: no '$MARK' in $LOG after 3 tries (or ssh failed)." >&2
    echo "Watcher is off (KOReader started without watch/devmode?): restart KOReader by hand, then deploy again." >&2
    exit 1
    ;;
  1)
    ssh kindle 'cd /mnt/us/koreader && (setsid ./koreader.sh --framework_stop >/dev/null 2>&1 </dev/null &); sleep 1; echo "koreader launched"'
    ;;
  *)
    echo "ssh to the Kindle failed (pidof exit $rc): nothing launched, nothing restarted." >&2
    exit 1
    ;;
esac
