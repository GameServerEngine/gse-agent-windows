#!/bin/bash
# Shared watchdog logic (Linux and Windows under Cygwin). Pure functions, no I/O.

# status_derive <requested:RUNNING|STOPPED> <pid_alive:0|1> <port_open:0|1> <was_running:0|1>
# prints one of: RUNNING STARTING STOPPING STOPPED CRASHED
status_derive() {
  local req="$1" pid="$2" port="$3" was="$4"
  if [ "$req" = "STOPPED" ]; then
    if [ "$pid" = "0" ] && [ "$port" = "0" ]; then echo "STOPPED"; else echo "STOPPING"; fi
    return 0
  fi
  if [ "$pid" = "1" ] && [ "$port" = "1" ]; then echo "RUNNING"
  elif [ "$pid" = "1" ]; then echo "STARTING"
  elif [ "$was" = "1" ]; then echo "CRASHED"
  else echo "STARTING"
  fi
}

# crash_allowed <now_epoch> <limit> <window_seconds> <crash_epochs...>
# exit 0 if another automatic restart is allowed, 1 if the rolling limit is reached.
crash_allowed() {
  local now="$1" limit="$2" window="$3"; shift 3
  local n=0 t
  for t in "$@"; do
    if [ $((now - t)) -lt "$window" ] && [ $((now - t)) -ge 0 ]; then n=$((n + 1)); fi
  done
  [ "$n" -lt "$limit" ]
}

# crash_count_in_window <now_epoch> <window_seconds> <crash_epochs...>  -> prints count
crash_count_in_window() {
  local now="$1" window="$2"; shift 2
  local n=0 t
  for t in "$@"; do
    if [ $((now - t)) -lt "$window" ] && [ $((now - t)) -ge 0 ]; then n=$((n + 1)); fi
  done
  echo "$n"
}
