#!/bin/bash
# Agent start: restore watchdogs for every home whose startup record says it should run.
# usage: restore_script.sh <startups_dir> <homes_dir> <watchdog_dir>
STARTUPS="$1"; HOMES="$2"; WD="$3"
for f in "$STARTUPS"/status-*; do
  [ -e "$f" ] || continue
  id="${f##*-}"; want=$(cut -d, -f2 "$f" | tr -d '[:space:]')
  case "$want" in RUNNING|STARTING|CRASHED) ;; *) continue ;; esac
  M="$HOMES/$id"; [ -f "$M/launch.env" ] || { echo "home $id: no launch.env, skipped"; continue; }
  if [ -f "$M/watchdog.pid" ] && kill -0 "$(cat "$M/watchdog.pid")" 2>/dev/null; then echo "home $id: watchdog already running"; continue; fi
  . "$M/launch.env"; echo RUNNING > "$M/request"
  setsid bash "$WD/watchdog_script.sh" "$M" "$GAME_DIR" "$GAME_CMD" "$GAME_PORT" "$GAME_PROTO" >> "$M/watchdog.out" 2>&1 < /dev/null &
  echo "home $id: watchdog restored"
done
