#!/usr/bin/env bash
# The Windows update helper must start the agent through its Windows service when there is one.
#
# What this guards against (seen on game3 on 2026-11-26): after an update the helper started the agent itself
# with nohup, so the GSE-Agent service showed Stopped while the agent was running, and the panel's restart
# (Restart-Service) could not restart it.
#
# The helper runs against a fake agent and a fake sc.exe. The fake service follows the agent process (RUNNING
# while an agent runs, STOPPED otherwise), like the real one, and every call is logged. The fake agent records
# whether the service or the helper itself started it.
#
# The helper signals every process on the host whose command line matches perl.*agent_core.pl, so this test
# refuses to run where a real agent is visible. On a host that has an agent, run it in a PID namespace:
#   sudo unshare --pid --fork --mount-proc sudo -u "$USER" -H bash tests/validate_update_helper_service_start.sh
#
# Scenarios (ONLY="W1 W3" runs a subset):
#   W1  the service exists                      -> started through the service
#   W2  there is no such service                -> started directly
#   W3  sc start fails                          -> started directly
#   W4  sc.exe is not available                 -> started directly
#   W5  the service says RUNNING with no agent  -> stopped, then started through the service
#   W6  the agent passed no service name        -> started directly (an older agent)

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${HELPER_UNDER_TEST:-$REPO/AgentScripts/agent_update_helper.sh}"
ONLY="${ONLY:-W1 W2 W3 W4 W5 W6}"

for tool in python3 unzip perl ps sha256sum find pgrep setsid timeout; do
	command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not installed"; exit 0; }
done
if pgrep -f 'perl.*agent_core\.pl' >/dev/null 2>&1; then
	echo "SKIP: a real agent is running on this host and the helper would signal it."
	echo "      Run in a PID namespace: sudo unshare --pid --fork --mount-proc sudo -u \"\$USER\" -H bash $0"
	exit 0
fi

failures=0
check() {
	if [ "$1" = "0" ]; then echo "ok - $2"; else echo "FAIL - $2"; failures=$((failures + 1)); fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gse-helper-svc.XXXXXX")"
SHIMS="$TMP/shims"
NOSC_SHIMS="$TMP/shims-no-sc"
mkdir -p "$SHIMS" "$NOSC_SHIMS"
cleanup_all() {
	pkill -f "$TMP/" >/dev/null 2>&1 || true
	sleep 1
	rm -rf "$TMP"
}
trap cleanup_all EXIT

# Fake sc.exe. The state follows the agent process. Environment: SC_LOG, SC_MODE_DIR, AGENT_DIR.
cat > "$SHIMS/sc.exe" <<'EOF'
#!/bin/bash
echo "$*" >> "$SC_LOG"
cmd="$1"; name="${2:-}"
agent_up() { pgrep -f "perl $AGENT_DIR/agent_core\\.pl" >/dev/null 2>&1; }
state() {
	if [ -f "$SC_MODE_DIR/missing" ]; then echo MISSING; return; fi
	if [ -f "$SC_MODE_DIR/forced_state" ]; then cat "$SC_MODE_DIR/forced_state"; return; fi
	if agent_up; then echo RUNNING; else echo STOPPED; fi
}
case "$cmd" in
	query)
		st="$(state)"
		if [ "$st" = MISSING ]; then
			printf '[SC] EnumQueryServicesStatus:OpenService FAILED 1060:\r\n\r\nThe specified service does not exist as an installed service.\r\n'
			exit 1060
		fi
		case "$st" in RUNNING) n=4 ;; STOPPED) n=1 ;; START_PENDING) n=2 ;; *) n=3 ;; esac
		printf 'SERVICE_NAME: %s\r\n        TYPE               : 10  WIN32_OWN_PROCESS\r\n        STATE              : %s  %s\r\n        WIN32_EXIT_CODE    : 0  (0x0)\r\n' "$name" "$n" "$st"
		;;
	start)
		if [ -f "$SC_MODE_DIR/start_fails" ]; then echo "[SC] StartService FAILED 1053:"; exit 1053; fi
		( cd "$AGENT_DIR" && GSE_STARTED_BY=service setsid nohup bash "$AGENT_DIR/agent_launch.sh" service >/dev/null 2>&1 & )
		printf 'SERVICE_NAME: %s\r\n        STATE              : 2  START_PENDING\r\n' "$name"
		;;
	stop)
		rm -f "$SC_MODE_DIR/forced_state"
		pkill -f "perl $AGENT_DIR/agent_core\\.pl" 2>/dev/null
		;;
esac
exit 0
EOF
chmod +x "$SHIMS/sc.exe"

port_counter=0

write_agent_files() {	# dir, code version
	cat > "$1/agent_core.pl" <<'EOF'
#!/usr/bin/perl
use strict; use warnings; use FindBin qw($Bin);
open(my $v, '<', "$Bin/CODE_VERSION") or die "no CODE_VERSION";
my $code = <$v>; chomp $code; close $v;
my $by = $ENV{GSE_STARTED_BY} || 'direct';
open(my $log, '>>', "$Bin/agent_starts.log") or die;
printf $log "%d start pid=%d code=%s by=%s\n", time, $$, $code, $by;
close $log;
while (1) { sleep 1 }
EOF
	cat > "$1/agent_launch.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec perl "$PWD/agent_core.pl"
EOF
	echo "$2" > "$1/CODE_VERSION"
	chmod +x "$1/agent_core.pl" "$1/agent_launch.sh"
}

make_sandbox() {	# name
	local dir="$TMP/$1/agent"
	mkdir -p "$dir" "$TMP/$1/mode"
	write_agent_files "$dir" v1
	: > "$TMP/$1/sc.log"
	echo "$dir"
}

make_release() {	# name, dir
	local zip="$TMP/$1/release.zip"
	python3 - "$zip" "$2" <<'PY'
import sys, zipfile
zip_path, agent_dir = sys.argv[1], sys.argv[2]
top = "gse-agent-windows-testing-9.9.9/AgentScripts/"
with zipfile.ZipFile(zip_path, "w") as z:
    z.writestr(top + "CODE_VERSION", "v2\n")
    for name in ("agent_core.pl", "agent_launch.sh"):
        with open(agent_dir + "/" + name) as f:
            z.writestr(top + name, f.read())
PY
	echo "$zip"
}

start_original_agent() {	# dir: the agent as the service started it
	( cd "$1" && GSE_STARTED_BY=service setsid nohup bash "$1/agent_launch.sh" service >/dev/null 2>&1 & )
}

starts_count() { if [ -f "$1/agent_starts.log" ]; then wc -l < "$1/agent_starts.log" | tr -d ' '; else echo 0; fi; }
last_field() { if [ -f "$1/agent_starts.log" ]; then tail -n 1 "$1/agent_starts.log" | sed -E "s/.*$2=//; s/ .*//"; else echo none; fi; }
agents_running() { pgrep -fc "perl $1/agent_core\\.pl" 2>/dev/null || true; }
state_status() { sed -nE 's/.*"status":"([a-z_]+)".*/\1/p' "$1/update_state.json" 2>/dev/null | head -n 1; }

wait_for_starts() {	# dir, count, seconds
	local n=0
	while [ "$n" -lt "$3" ]; do
		[ "$(starts_count "$1")" -ge "$2" ] && return 0
		sleep 1; n=$((n + 1))
	done
	return 1
}

run_helper() {	# name, dir, zip, sha, extra helper args..., with PATHDIRS in env PATH_SHIMS
	local name="$1" dir="$2" zip="$3" sha="$4"; shift 4
	( cd "$dir" && PATH="$PATH_SHIMS:$PATH" SC_LOG="$TMP/$name/sc.log" SC_MODE_DIR="$TMP/$name/mode" AGENT_DIR="$dir" \
		GSE_UPDATE_SETTLE_SECONDS=1 GSE_UPDATE_POLL_SECONDS=1 GSE_UPDATE_STABLE_SECONDS=3 \
		timeout 200 bash "$HELPER" --agent-dir "$dir" --zip "$zip" --sha256 "$sha" --version testing-9.9.9 --agent-pid 0 \
		--launcher "$dir/agent_launch.sh" "$@" --state-file "$dir/update_state.json" --log-file "$dir/update.log" >> "$dir/helper.out" 2>&1 )
}

stop_sandbox() {
	pkill -f "perl $1/agent_core\\.pl" 2>/dev/null || true
	sleep 1
}

# name, expectation (service|direct), extra setup function, extra helper args
scenario() {
	local name="$1" expect="$2" setup="$3"; shift 3
	local dir zip sha rc
	echo "--- $name"
	dir="$(make_sandbox "$name")"
	start_original_agent "$dir"
	wait_for_starts "$dir" 1 15; check $? "$name: the fake agent started (v1)"
	[ -n "$setup" ] && "$setup" "$TMP/$name/mode"
	zip="$(make_release "$name" "$dir")"
	sha="$(sha256sum "$zip" | cut -d' ' -f1)"
	run_helper "$name" "$dir" "$zip" "$sha" "$@"; rc=$?
	check "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "$name: the helper finished successfully (exit $rc)"
	check "$([ "$(state_status "$dir")" = "ok" ] && echo 0 || echo 1)" "$name: the recorded state is ok (is '$(state_status "$dir")')"
	check "$([ "$(last_field "$dir" code)" = "v2" ] && echo 0 || echo 1)" "$name: the agent that is running loaded the new code (loaded '$(last_field "$dir" code)')"
	check "$([ "$(agents_running "$dir")" = "1" ] && echo 0 || echo 1)" "$name: exactly one agent is running ($(agents_running "$dir"))"
	check "$([ "$(last_field "$dir" by)" = "$expect" ] && echo 0 || echo 1)" "$name: the new agent was started by: $expect (was '$(last_field "$dir" by)')"
	case "$name" in
		W1|W5) check "$(grep -q '^start GSE-Agent' "$TMP/$name/sc.log" && echo 0 || echo 1)" "$name: the helper asked the service to start" ;;
		W2|W4|W6) check "$(grep -q '^start' "$TMP/$name/sc.log" && echo 1 || echo 0)" "$name: the helper did not try to start a service" ;;
		W3) check "$(grep -q '^start GSE-Agent' "$TMP/$name/sc.log" && echo 0 || echo 1)" "$name: the helper tried the service first, then fell back" ;;
	esac
	if [ "$name" = "W5" ]; then
		check "$([ "$(grep -n '^stop' "$TMP/$name/sc.log" | head -1 | cut -d: -f1)" -lt "$(grep -n '^start' "$TMP/$name/sc.log" | head -1 | cut -d: -f1)" ] 2>/dev/null && echo 0 || echo 1)" "$name: the stuck service was stopped before it was started"
	fi
	stop_sandbox "$dir"
}

setup_missing() { : > "$1/missing"; }
setup_start_fails() { : > "$1/start_fails"; }
setup_stuck_running() { echo RUNNING > "$1/forced_state"; }

for s in $ONLY; do
	case "$s" in
		W1) PATH_SHIMS="$SHIMS" scenario W1 service "" --service-name GSE-Agent ;;
		W2) PATH_SHIMS="$SHIMS" scenario W2 direct setup_missing --service-name GSE-Agent ;;
		W3) PATH_SHIMS="$SHIMS" scenario W3 direct setup_start_fails --service-name GSE-Agent ;;
		W4) PATH_SHIMS="$NOSC_SHIMS" scenario W4 direct "" --service-name GSE-Agent ;;
		W5) PATH_SHIMS="$SHIMS" scenario W5 service setup_stuck_running --service-name GSE-Agent ;;
		W6) PATH_SHIMS="$SHIMS" scenario W6 direct "" ;;
	esac
done

echo
if [ "$failures" -eq 0 ]; then echo "Windows update helper service start checks passed."; else echo "$failures Windows update helper service start check(s) FAILED."; fi
exit $((failures > 0 ? 1 : 0))
