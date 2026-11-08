#!/bin/bash
# gse_watchdog_linux.sh - keeps ONE game server running (Linux).
#
# Usage: gse_watchdog_linux.sh <server_folder>
#
# The agent writes server.conf in the server folder. This script reads it.
# Files this script writes in the server folder:
#   watchdog.pid  this script's own PID
#   game.pid      the game's PID
#   bot.pid       the bot's PID
#   watchdog.log  one line per event
#
# To stop a server, the agent does three things in this order:
#   1. kill watchdog.pid      (so nothing restarts the game)
#   2. kill game.pid and bot.pid
#   3. free the game ports

SERVER_DIR="$1"
cd "$SERVER_DIR" || exit 1
. ./server.conf

# Timing. Tests can shorten these by setting the variables first.
CHECK_SECONDS=${CHECK_SECONDS:-30}
FAST_EXIT_SECONDS=${FAST_EXIT_SECONDS:-120}
MAX_FAST_CRASHES=${MAX_FAST_CRASHES:-4}
BACKOFF_1=${BACKOFF_1:-30}
BACKOFF_2=${BACKOFF_2:-60}
BACKOFF_3=${BACKOFF_3:-300}

echo $$ > watchdog.pid

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> watchdog.log
}

# True if the process in this PID file is still running.
is_running() {
  [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

# Kill a process group from its PID file, then remove the file.
stop_one() {
  if [ -f "$1" ]; then
    kill -KILL -- "-$(cat "$1")" 2>/dev/null
    rm -f "$1"
  fi
}

start_game() {
  log "starting game"
  setsid $GAME_EXE $GAME_ARGS >> game.out 2>&1 &
  echo $! > game.pid
  started=$(date +%s)
}

start_bot() {
  if [ -n "$BOT_EXE" ]; then
    log "starting bot"
    setsid $BOT_EXE $BOT_ARGS >> bot.out 2>&1 &
    echo $! > bot.pid
  fi
}

stop_all() {
  stop_one bot.pid
  stop_one game.pid
  for port in $GAME_PORTS; do
    fuser -k "$port/tcp" "$port/udp" >/dev/null 2>&1
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
