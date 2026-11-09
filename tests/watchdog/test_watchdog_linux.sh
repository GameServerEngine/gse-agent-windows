#!/bin/bash
# Tests for watchdog_script_linux.sh, using the fake game (server-port-test game mode).
# Usage: test_watchdog_linux.sh <path to watchdog> <path to fake game binary>
WD="$1"
GAME="$2"
ROOT=$(mktemp -d /tmp/wdtest.XXXX)
PASS=0; FAIL=0
check() { if [ "$2" = "ok" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
count() { grep -c "$2" "$1/watchdog.log" 2>/dev/null || echo 0; }

# Fast timing for tests
export CHECK_SECONDS=1 FAST_EXIT_SECONDS=120 MAX_FAST_CRASHES=2 BACKOFF_1=1 BACKOFF_2=1 BACKOFF_3=1

# Test 1: a game that crashes right away is restarted, then the watchdog gives up
D1="$ROOT/s1"; mkdir -p "$D1"
cat > "$D1/server.conf" <<CONF
GAME_EXE="$GAME"
GAME_ARGS="game --port 17301 --log $D1/game.log --heartbeat 1s --crash-after 2s --exit-code 7"
GAME_PORTS="17301"
BOT_EXE=""
BOT_ARGS=""
CONF
bash "$WD" "$D1" & W1=$!
for i in $(seq 1 60); do grep -q "giving up" "$D1/watchdog.log" 2>/dev/null && break; sleep 1; done
wait $W1; RC=$?
check "crash restart count is 2 starts" "$([ "$(count "$D1" 'starting game')" = 2 ] && echo ok)"
check "gives up after max fast crashes" "$(grep -q 'giving up' "$D1/watchdog.log" && echo ok)"
check "watchdog exits with code 1 on give-up" "$([ $RC = 1 ] && echo ok)"
check "no game left running after give-up" "$(kill -0 "$(cat "$D1/game.pid" 2>/dev/null)" 2>/dev/null && echo no || echo ok)"

# Test 2: stop order. Killing the watchdog first stops restarts, even after the game dies
D2="$ROOT/s2"; mkdir -p "$D2"
cat > "$D2/server.conf" <<CONF
GAME_EXE="$GAME"
GAME_ARGS="game --port 17302 --log $D2/game.log --heartbeat 1s"
GAME_PORTS="17302"
BOT_EXE=""
BOT_ARGS=""
CONF
bash "$WD" "$D2" & W2=$!
sleep 3
G2=$(cat "$D2/game.pid")
kill -TERM "$(cat "$D2/watchdog.pid")"; wait $W2 2>/dev/null
check "game still running after watchdog is stopped" "$(kill -0 "$G2" 2>/dev/null && echo ok)"
kill -KILL -- "-$G2" 2>/dev/null; sleep 3
check "no restart after watchdog is stopped" "$([ "$(count "$D2" 'starting game')" = 1 ] && echo ok)"

# Test 3: bot restarts alone while the game keeps running
D3="$ROOT/s3"; mkdir -p "$D3"
cat > "$D3/server.conf" <<CONF
GAME_EXE="$GAME"
GAME_ARGS="game --port 17303 --log $D3/game.log --heartbeat 1s"
GAME_PORTS="17303"
BOT_EXE="$GAME"
BOT_ARGS="game --port 17393 --log $D3/bot.log --heartbeat 1s"
CONF
bash "$WD" "$D3" & W3=$!
sleep 3
B3=$(cat "$D3/bot.pid")
kill -KILL -- "-$B3" 2>/dev/null; sleep 4
G3=$(cat "$D3/game.pid")
check "bot restarted alone" "$([ "$(count "$D3" 'starting bot')" -ge 2 ] && echo ok)"
check "game not restarted when only bot died" "$([ "$(count "$D3" 'starting game')" = 1 ] && echo ok)"
check "game still running" "$(kill -0 "$G3" 2>/dev/null && echo ok)"
kill -TERM "$(cat "$D3/watchdog.pid")" 2>/dev/null; wait $W3 2>/dev/null
kill -KILL -- "-$G3" 2>/dev/null; kill -KILL -- "-$(cat "$D3/bot.pid" 2>/dev/null)" 2>/dev/null

echo "RESULT pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
