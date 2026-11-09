#!/bin/bash
# Tests for watchdog_script_windows.sh on a Windows host (run with Cygwin bash).
# Usage: test_watchdog_windows.sh <watchdog .sh (Cygwin path)> <start_hidden.ps1 (Cygwin path)> <game .exe (Windows path)>
WD="$1"
GAME_WIN="$3"
ROOT="/cygdrive/c/gse-test/wd/run"
ROOT_WIN="C:\\gse-test\\wd\\run"
PASS=0; FAIL=0
export PATH=/usr/bin:/bin:/cygdrive/c/Windows/System32:/cygdrive/c/Windows/System32/WindowsPowerShell/v1.0
export CHECK_SECONDS=1 FAST_EXIT_SECONDS=120 MAX_FAST_CRASHES=2 BACKOFF_1=1 BACKOFF_2=1 BACKOFF_3=1
check() { if [ "$2" = "ok" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
count() { grep -c "$2" "$1/watchdog.log" 2>/dev/null || echo 0; }
alive() { [ -n "$1" ] && tasklist /FI "PID eq $1" 2>/dev/null | tr -d '\r' | grep -q "[[:space:]]$1[[:space:]]"; }
# Waits up to 20s for a PID file to appear. start_proc can retry once on a
# launch failure (see watchdog_script_windows.sh), so the first game.pid write
# is not guaranteed within the first couple of seconds.
wait_for_file() { for _ in $(seq 1 45); do [ -s "$1" ] && return 0; sleep 1; done; return 1; }
mkdir -p "$ROOT"
start_wd() { # $1 = server folder (Cygwin path). Starts the watchdog hidden.
  # -OutBase must be unique per call: start_hidden.ps1 defaults it to the
  # exe's own name ("bash"), so without this every watchdog launch in this
  # suite would share one bash.out/bash.err pair. A leftover wrapper cmd.exe
  # from a previous test (e.g. one whose bash.exe child was just force-killed
  # by the stop-order test, cmd.exe itself not yet exited) can still be
  # holding that shared file open, and the next launch's cmd.exe then fails
  # its own redirection setup with a sharing violation before bash.exe ever
  # starts -- silently, since this call's own output is discarded below.
  local outbase="wd_$(basename "$1")"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$(dirname "$WD")/start_hidden.ps1")" -Exe "C:\\gse-test\\cygwin\\bin\\bash.exe" -Args "/cygdrive/c/gse-test/wd/watchdog_script_windows.sh $1" -WorkDir "C:\\gse-test\\cygwin\\bin" -OutBase "$outbase" >/dev/null
}

# Test 1: a game that crashes right away is restarted, then the watchdog gives up
D1="$ROOT/s1"; mkdir -p "$D1"
cat > "$D1/server.conf" <<CONF
GAME_EXE="$GAME_WIN"
GAME_ARGS="game --port 17401 --log $ROOT_WIN\\s1\\game.log --heartbeat 1s --crash-after 2s --exit-code 7"
GAME_PORTS="17401"
BOT_EXE=""
BOT_ARGS=""
CONF
start_wd "/cygdrive/c/gse-test/wd/run/s1"
for i in $(seq 1 90); do grep -q "giving up" "$D1/watchdog.log" 2>/dev/null && break; sleep 1; done
sleep 2
check "crash restart count is 2 starts" "$([ "$(count "$D1" 'starting game')" = 2 ] && echo ok)"
check "gives up after max fast crashes" "$(grep -q 'giving up' "$D1/watchdog.log" && echo ok)"
check "no game left running after give-up" "$(alive "$(cat "$D1/game.pid" 2>/dev/null)" && echo no || echo ok)"
taskkill /F /T /PID "$(cat "$D1/watchdog.pid" 2>/dev/null)" >/dev/null 2>&1

# Test 2: stop order. Killing the watchdog first stops restarts, even after the game dies
D2="$ROOT/s2"; mkdir -p "$D2"
cat > "$D2/server.conf" <<CONF
GAME_EXE="$GAME_WIN"
GAME_ARGS="game --port 17402 --log $ROOT_WIN\\s2\\game.log --heartbeat 1s"
GAME_PORTS="17402"
BOT_EXE=""
BOT_ARGS=""
CONF
start_wd "/cygdrive/c/gse-test/wd/run/s2"
wait_for_file "$D2/game.pid"
sleep 3
G2=$(cat "$D2/game.pid")
taskkill /F /T /PID "$(cat "$D2/watchdog.pid")" >/dev/null 2>&1; sleep 2
check "game still running after watchdog is stopped" "$(alive "$G2" && echo ok)"
taskkill /F /T /PID "$G2" >/dev/null 2>&1; sleep 6
check "no restart after watchdog is stopped" "$([ "$(count "$D2" 'starting game')" = 1 ] && echo ok)"

# Test 3: bot restarts alone while the game keeps running
D3="$ROOT/s3"; mkdir -p "$D3"
cat > "$D3/server.conf" <<CONF
GAME_EXE="$GAME_WIN"
GAME_ARGS="game --port 17403 --log $ROOT_WIN\\s3\\game.log --heartbeat 1s"
GAME_PORTS="17403"
BOT_EXE="$GAME_WIN"
BOT_ARGS="game --port 17493 --log $ROOT_WIN\\s3\\bot.log --heartbeat 1s"
CONF
start_wd "/cygdrive/c/gse-test/wd/run/s3"
wait_for_file "$D3/bot.pid"
sleep 3
taskkill /F /T /PID "$(cat "$D3/bot.pid")" >/dev/null 2>&1
for _ in $(seq 1 40); do [ "$(count "$D3" 'starting bot')" -ge 2 ] && break; sleep 1; done
sleep 1
G3=$(cat "$D3/game.pid")
check "bot restarted alone" "$([ "$(count "$D3" 'starting bot')" -ge 2 ] && echo ok)"
check "game not restarted when only bot died" "$([ "$(count "$D3" 'starting game')" = 1 ] && echo ok)"
check "game still running" "$(alive "$G3" && echo ok)"
for d in "$D1" "$D2" "$D3"; do
  for f in watchdog.pid game.pid bot.pid; do taskkill /F /T /PID "$(cat "$d/$f" 2>/dev/null)" >/dev/null 2>&1; done
done

echo "RESULT pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
