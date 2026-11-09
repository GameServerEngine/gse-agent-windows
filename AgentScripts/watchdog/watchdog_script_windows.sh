#!/bin/bash
# watchdog_script_windows.sh - keeps ONE game server running (Windows, Cygwin bash).
#
# Usage: watchdog_script_windows.sh <server_folder>
#
# Same flow as watchdog_script_linux.sh. Only the process commands differ:
# processes start hidden through start_hidden.ps1, and stop with taskkill.
# server.conf uses Windows paths (C:\...) for GAME_EXE, GAME_ARGS, BOT_EXE, BOT_ARGS.
#
# Files written in the server folder:
#   watchdog.pid  this script's Windows PID
#   game.pid      the game's Windows PID
#   bot.pid       the bot's Windows PID
#   watchdog.log  one line per event

export PATH=/usr/bin:/bin:/cygdrive/c/Windows/System32:/cygdrive/c/Windows/System32/WindowsPowerShell/v1.0

SERVER_DIR="$1"
cd "$SERVER_DIR" || exit 1
. ./server.conf

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$(cygpath -w "$HELPER_DIR/start_hidden.ps1")"
WORK_DIR="$(cygpath -w "$(pwd)")"

CHECK_SECONDS=${CHECK_SECONDS:-30}
FAST_EXIT_SECONDS=${FAST_EXIT_SECONDS:-120}
MAX_FAST_CRASHES=${MAX_FAST_CRASHES:-4}
BACKOFF_1=${BACKOFF_1:-30}
BACKOFF_2=${BACKOFF_2:-60}
BACKOFF_3=${BACKOFF_3:-300}

# Record this script's Windows PID. Its parent is bash.exe.
powershell.exe -NoProfile -Command '[Console]::Out.Write((Get-CimInstance Win32_Process -Filter ("ProcessId=" + $PID)).ParentProcessId)' | tr -d '\r' > watchdog.pid

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> watchdog.log
}

# True if the Windows PID in this file is still running.
is_running() {
  [ -f "$1" ] && tasklist /FI "PID eq $(cat "$1")" 2>/dev/null | tr -d '\r' | grep -q "[[:space:]]$(cat "$1")[[:space:]]"
}

# Kill a process and its children from its PID file, then remove the file.
stop_one() {
  if [ -f "$1" ]; then
    taskkill /F /T /PID "$(cat "$1")" >/dev/null 2>&1
    rm -f "$1"
  fi
}

# Start a hidden process. $1 = PID file, $2 = exe, $3 = args
#
# start_hidden.ps1 can hit a launcher-level failure (its own process exits
# before the real exe is ever observed as its child) under the extra layer
# of WMI nesting this script runs under when it is itself started hidden.
# That is a launch failure, not the game crashing on its own; retry once
# immediately rather than letting it masquerade as a fast crash and eat
# into MAX_FAST_CRASHES.
start_proc() {
  local pid_out
  local outbase="${1%.pid}"
  local attempt
  for attempt in 1 2 3 4; do
    pid_out=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HELPER" -Exe "$2" -Args "$3" -WorkDir "$WORK_DIR" -OutBase "$outbase" 2>>watchdog.log | tr -d '\r')
    if [ -n "$pid_out" ]; then
      printf '%s' "$pid_out" > "$1"
      return 0
    fi
    log "start_proc attempt $attempt for $1 produced no PID; retrying"
    sleep 1
  done
  : > "$1"
}

start_game() {
  log "starting game"
  start_proc game.pid "$GAME_EXE" "$GAME_ARGS"
  started=$(date +%s)
}

start_bot() {
  if [ -n "$BOT_EXE" ]; then
    log "starting bot"
    start_proc bot.pid "$BOT_EXE" "$BOT_ARGS"
  fi
}

stop_all() {
  stop_one bot.pid
  stop_one game.pid
  for port in $GAME_PORTS; do
    for pid in $(netstat -ano | tr -d '\r' | grep -E ":$port[[:space:]]" | awk '{print $NF}' | sort -u); do
      if [ "$pid" -gt 4 ] 2>/dev/null; then
        taskkill /F /T /PID "$pid" >/dev/null 2>&1
      fi
    done
  done
  sleep 5
}

fails=0
start_game
start_bot

while true; do
  if ! is_running game.pid; then
    ran=$(( $(date +%s) - started ))
    log "game stopped after $ran seconds"
    stop_all

    if [ "$ran" -lt "$FAST_EXIT_SECONDS" ]; then
      fails=$((fails + 1))
    else
      fails=0
    fi

    if [ "$fails" -ge "$MAX_FAST_CRASHES" ]; then
      log "game crashed $fails times in a row. giving up until a person starts it."
      rm -f watchdog.pid
      exit 1
    fi

    case "$fails" in
      0) wait_s=0 ;;
      1) wait_s=$BACKOFF_1 ;;
      2) wait_s=$BACKOFF_2 ;;
      *) wait_s=$BACKOFF_3 ;;
    esac
    log "waiting $wait_s seconds before restart"
    sleep "$wait_s"

    start_game
    start_bot
  elif [ -n "$BOT_EXE" ] && ! is_running bot.pid; then
    log "bot stopped; restarting bot only"
    start_bot
  fi

  sleep "$CHECK_SECONDS"
done
