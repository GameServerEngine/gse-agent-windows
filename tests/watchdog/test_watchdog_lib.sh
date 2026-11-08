#!/bin/bash
# T1 unit/logic tests for watchdog/watchdog_lib.sh. Exit 0 only if every case passes.
cd "$(dirname "$0")/../.." || exit 1
. watchdog/watchdog_lib.sh
pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: expected '$2' got '$3'"; fi
}
# status matrix: requested pid port was -> expected
check "stop/none"        STOPPED  "$(status_derive STOPPED 0 0 1)"
check "stop/pid up"      STOPPING "$(status_derive STOPPED 1 1 1)"
check "stop/port still"  STOPPING "$(status_derive STOPPED 0 1 1)"
check "run/both"         RUNNING  "$(status_derive RUNNING 1 1 0)"
check "run/pid no port"  STARTING "$(status_derive RUNNING 1 0 0)"
check "run/crashed"      CRASHED  "$(status_derive RUNNING 0 0 1)"
check "run/fresh start"  STARTING "$(status_derive RUNNING 0 0 0)"
# crash limit: 3 restarts allowed per 600s, 4th blocked
now=10000
check "no crashes yet allowed"        0 "$(crash_allowed $now 3 600; echo $?)"
check "two crashes allowed"           0 "$(crash_allowed $now 3 600 9900 9950; echo $?)"
check "three in window blocked"       1 "$(crash_allowed $now 3 600 9500 9900 9950; echo $?)"
check "old crash rolls out of window" 0 "$(crash_allowed $now 3 600 9000 9900 9950; echo $?)"
check "count in window"               2 "$(crash_count_in_window $now 600 9000 9900 9950)"
check "future timestamp ignored"      1 "$(crash_count_in_window $now 600 10500 9950)"
echo "T1 result: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
