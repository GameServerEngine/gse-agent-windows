#!/bin/bash
# Per-bot watchdog. One per bot, started by the game watchdog when the bot is enabled.
# usage: bot_watchdog.sh <game_mgmt_dir> <bot_id>
# Reads: <game_mgmt>/status.env (game state) and <game_mgmt>/bots/<id>/bot.env (policy and command).
# Writes: <game_mgmt>/bots/<id>/status.env and events.log. Never writes into the game folder.
GM="$1"; BID="$2"; BM="$GM/bots/$BID"
LOOP="${WD_LOOP:-5}"; LIMIT="${WD_LIMIT:-3}"; WINDOW="${WD_WINDOW:-600}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/watchdog_lib.sh"
. "$HERE/platform.sh"
. "$BM/bot.env"
echo $$ > "$BM/bot.wd.pid"
ev() { echo "[$(date '+%F %T')] $*" >> "$BM/events.log"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
kill_tree() { local p="$1" c; for c in $(child_pids "$p"); do kill_tree "$c"; done; kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null; }
game_state() { grep '^state=' "$GM/status.env" 2>/dev/null | cut -d= -f2; }
write_bot_status() { # state pid
  local tmp="$BM/status.env.tmp"
  { echo "state=$1"; echo "pid=${2:-0}"; echo "lifecycle=$LIFECYCLE"; echo "on_game_stop=$ON_GAME_STOP"; echo "restart_on_crash=$RESTART_ON_CRASH"; echo "crashes=$CRASHES"; echo "updated=$(date '+%FT%T%z')"; } > "$tmp" && mv -f "$tmp" "$BM/status.env"
}
CRASHES=$(grep '^crashes=' "$BM/status.env" 2>/dev/null | cut -d= -f2-); STARTED=0; LIMIT_HIT=0
ev "bot watchdog started ($BID lifecycle=$LIFECYCLE on_game_stop=$ON_GAME_STOP)"
while true; do
  GS=$(game_state); [ -z "$GS" ] && GS=UNKNOWN
  BPID=$(cat "$BM/bot.pid" 2>/dev/null); A=0; alive "$BPID" && A=1
  NOW=$(date +%s)
  # Game is stopped: with_game bots go, even if hung. always bots keep running.
  if [ "$GS" = "STOPPED" ] && [ "$LIFECYCLE" = "with_game" ]; then
    if [ "$A" = "1" ]; then kill_tree "$BPID"; ev "game stopped: killed bot pid $BPID (with_game)"; fi
    write_bot_status STOPPED 0; ev "bot stopped"; rm -f "$BM/bot.wd.pid"; exit 0
  fi
  if [ "$A" = "0" ]; then
    want=0
    if [ "$LIFECYCLE" = "always" ]; then want=1; fi
    if [ "$GS" = "RUNNING" ] || [ "$GS" = "STARTING" ]; then want=1; fi
    if [ "$want" = "1" ] && [ "$LIMIT_HIT" = "0" ]; then
      if [ "$STARTED" = "1" ]; then
        if [ "$RESTART_ON_CRASH" = "yes" ]; then
          ev "BOT CRASHED: pid $BPID gone unexpectedly"
          PRIOR=$(echo "$CRASHES" | tr ',' ' ')
          if crash_allowed "$NOW" "$LIMIT" "$WINDOW" $PRIOR; then
            RW=$(crash_count_in_window "$NOW" "$WINDOW" $PRIOR); CRASHES="${CRASHES:+$CRASHES,}$NOW"
            ev "bot restarted after crash (restart $((RW+1)) of $LIMIT in ${WINDOW}s)"
          else
            LIMIT_HIT=1; ev "BOT CRASHED_LIMIT: $LIMIT crashes in ${WINDOW}s, not restarting"; write_bot_status CRASHED_LIMIT 0; sleep "$LOOP"; continue
          fi
        else
          ev "bot died and restart_on_crash=no; leaving stopped"; write_bot_status STOPPED 0; sleep "$LOOP"; continue
        fi
      else
        ev "starting bot"
      fi
      ( cd "$BOT_DIR" && setsid bash -c "$BOT_CMD" >> "$BM/bot.log" 2>&1 < /dev/null & echo $! > "$BM/bot.pid" )
      STARTED=1; BPID=$(cat "$BM/bot.pid"); A=1
    fi
  fi
  if [ "$A" = "1" ]; then write_bot_status RUNNING "$BPID"; else write_bot_status STOPPED 0; fi
  sleep "$LOOP"
done
