#!/bin/bash
# GSE per-game watchdog (Linux; Windows runs the same file under Cygwin).
# usage: watchdog_script.sh <mgmt_dir> <game_dir> <command> <port> <tcp|udp>
# Source of truth: <mgmt_dir>/status.env (state, pids, crash times). Panel and agent only READ it
# and WRITE the request file (RUNNING|STOPPED).
MGMT="$1"; GAME="$2"; CMD="$3"; PORT="$4"; PROTO="$5"
LOOP="${WD_LOOP:-5}"; LIMIT="${WD_LIMIT:-3}"; WINDOW="${WD_WINDOW:-600}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/watchdog_lib.sh"
. "$HERE/platform.sh"
# Refuse to start with a bad launch definition. Name the field; launch nothing.
if [ -z "$CMD" ]; then echo "[$(date '+%F %T')] REFUSED: start command is empty (field: GAME_CMD)" >> "$MGMT/events.log"; mkdir -p "$MGMT"; printf 'state=ERROR\nreason=empty_command\nfield=GAME_CMD\nupdated=%s\n' "$(date '+%FT%T%z')" > "$MGMT/status.env"; exit 2; fi
if [ ! -d "$GAME" ]; then echo "[$(date '+%F %T')] REFUSED: game folder missing (field: GAME_DIR=$GAME)" >> "$MGMT/events.log"; mkdir -p "$MGMT"; printf 'state=ERROR\nreason=missing_game_dir\nfield=GAME_DIR\nupdated=%s\n' "$(date '+%FT%T%z')" > "$MGMT/status.env"; exit 2; fi
mkdir -p "$MGMT"; echo $$ > "$MGMT/watchdog.pid"
ev() { echo "[$(date '+%F %T')] $*" >> "$MGMT/events.log"; }
port_open() { port_listening "$PROTO" "$PORT"; }
port_owner() { port_owner_pid "$PROTO" "$PORT"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
kill_tree() { local p="$1" c; for c in $(child_pids "$p"); do kill_tree "$c"; done; kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null; }
read_env() { # key default
  local v; v=$(grep "^$1=" "$MGMT/status.env" 2>/dev/null | tail -1 | cut -d= -f2-); echo "${v:-$2}"; }
CRASHES=$(read_env crashes ""); LAST_CRASH_PID=$(read_env last_crash_pid ""); LIMIT_HIT=0; [ "$(read_env state "")" = "CRASHED_LIMIT" ] && LIMIT_HIT=1
write_status() { # state pid alive port_open
  local tmp="$MGMT/status.env.tmp" rw
  rw=$(crash_count_in_window "$(date +%s)" "$WINDOW" $(echo "$CRASHES" | tr ',' ' '))
  { echo "state=$1"; echo "requested=$REQ"; echo "pid=${2:-0}"; echo "alive=$3"; echo "port=$PORT"; echo "port_open=$4"; echo "proto=$PROTO"
    echo "restarts_window=$rw"; echo "limit=$LIMIT"; echo "window=$WINDOW"; echo "crashes=$CRASHES"; echo "last_crash_pid=$LAST_CRASH_PID"; echo "updated=$(date '+%FT%T%z')"; } > "$tmp" && mv -f "$tmp" "$MGMT/status.env"
}
launch() { ( cd "$GAME" && setsid bash -c "$CMD" >> "$MGMT/game.log" 2>&1 < /dev/null & echo $! > "$MGMT/game.pid" ); }

# Bots: start a per-bot watchdog for every enabled bot (bots/<id>/enabled exists). Never touches the game folder.
ensure_bots() {
  local bd id
  for bd in "$MGMT"/bots/*/; do
    [ -f "$bd/enabled" ] || continue
    id=$(basename "$bd")
    if [ ! -f "$bd/bot.wd.pid" ] || ! kill -0 "$(cat "$bd/bot.wd.pid")" 2>/dev/null; then
      ev "bot $id: starting bot watchdog"
      setsid bash "$HERE/bot_watchdog.sh" "$MGMT" "$id" >> "$bd/watchdog.out" 2>&1 < /dev/null &
    fi
  done
}
was_running=0
GPID=$(cat "$MGMT/game.pid" 2>/dev/null)
if alive "$GPID"; then
  ev "adopted running game pid $GPID (watchdog restarted)"; was_running=1
elif port_open; then
  OWN=$(port_owner); if [ -n "$OWN" ]; then echo "$OWN" > "$MGMT/game.pid"; GPID=$OWN; ev "adopted external process pid $OWN already listening on port $PORT"; was_running=1; fi
fi
REQ=$(tr -d '[:space:]' < "$MGMT/request" 2>/dev/null); [ -z "$REQ" ] && REQ=RUNNING
ev "watchdog started (pid $$, port $PORT/$PROTO, loop ${LOOP}s, limit $LIMIT/${WINDOW}s)"
while true; do
  REQ=$(tr -d '[:space:]' < "$MGMT/request" 2>/dev/null); [ -z "$REQ" ] && REQ=STOPPED
  GPID=$(cat "$MGMT/game.pid" 2>/dev/null); A=0; alive "$GPID" && A=1
  PO=0; port_open && PO=1; NOW=$(date +%s)
  ensure_bots
  if [ "$REQ" = "STOPPED" ]; then
    if [ "$A" = "1" ]; then kill_tree "$GPID"; ev "stop requested: killed game pid $GPID"; A=0; fi
    write_status "$(status_derive STOPPED "$A" "$PO" "$was_running")" "$GPID" "$A" "$PO"
    if [ "$PO" = "0" ]; then ev "stopped confirmed: ports closed"; CRASHES=""; LAST_CRASH_PID=""; LIMIT_HIT=0; write_status STOPPED "$GPID" 0 0; rm -f "$MGMT/watchdog.pid"; exit 0; fi
  else
    if [ "$A" = "0" ]; then
      if [ "$was_running" = "1" ]; then
        if [ "$LIMIT_HIT" = "1" ] && [ "$(crash_allowed "$NOW" "$LIMIT" "$WINDOW" $(echo "$CRASHES" | tr ',' ' '); echo $?)" = "1" ]; then write_status CRASHED_LIMIT "$GPID" 0 "$PO"; sleep "$LOOP"; continue; fi
        if [ "$GPID" != "$LAST_CRASH_PID" ]; then
          LAST_CRASH_PID="$GPID"; ev "CRASHED: game pid $GPID gone unexpectedly"
          PRIOR=$(echo "$CRASHES" | tr ',' ' ')
          if crash_allowed "$NOW" "$LIMIT" "$WINDOW" $PRIOR; then
            CRASHES="${CRASHES:+$CRASHES,}$NOW"; RW=$(crash_count_in_window "$NOW" "$WINDOW" $PRIOR)
            ev "restarted after crash (restart $((RW+1)) of $LIMIT in ${WINDOW}s)"; launch; GPID=$(cat "$MGMT/game.pid"); A=1
          else
            LIMIT_HIT=1; ev "CRASHED_LIMIT: $LIMIT crashes in ${WINDOW}s, not restarting; request STOPPED to reset"
            write_status CRASHED_LIMIT "$GPID" 0 "$PO"; sleep "$LOOP"; continue
          fi
        else
          write_status CRASHED "$GPID" 0 "$PO"; sleep "$LOOP"; continue
        fi
      else
        ev "starting game"; launch; GPID=$(cat "$MGMT/game.pid"); A=1; was_running=1
      fi
    fi
    [ "$A" = "1" ] && was_running=1
    write_status "$(status_derive RUNNING "$A" "$PO" "$was_running")" "$GPID" "$A" "$PO"
  fi
  sleep "$LOOP"
done
