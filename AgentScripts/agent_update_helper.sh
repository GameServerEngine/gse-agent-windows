#!/usr/bin/env bash
# On-demand agent update helper (Windows/Cygwin).
#
# Started detached by the running agent right before the agent stops itself.
# The agent has already downloaded the release zip to a staging folder and
# that download's SHA-256 is passed in. This helper:
#   1. waits for the agent process to exit,
#   2. re-checks the SHA-256 of the staged zip,
#   3. keeps ONE backup of the current install (the install being replaced),
#   4. copies the new files in, leaving config and runtime data untouched,
#   5. starts the agent again and waits for it to stay up,
#   6. on any failure after the swap starts, restores the backup and restarts
#      the previous agent, then records the outcome.
#
# Usage:
#   agent_update_helper.sh --agent-dir DIR --zip FILE --sha256 HEX \
#       --version VER --agent-pid PID --launcher FILE --state-file FILE --log-file FILE

set -u

AGENT_DIR=""; ZIP=""; EXPECTED_SHA=""; VERSION=""; AGENT_PID=""
LAUNCHER=""; STATE_FILE=""; LOG_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--agent-dir) AGENT_DIR="$2"; shift 2 ;;
		--zip) ZIP="$2"; shift 2 ;;
		--sha256) EXPECTED_SHA="$2"; shift 2 ;;
		--version) VERSION="$2"; shift 2 ;;
		--agent-pid) AGENT_PID="$2"; shift 2 ;;
		--launcher) LAUNCHER="$2"; shift 2 ;;
		--state-file) STATE_FILE="$2"; shift 2 ;;
		--log-file) LOG_FILE="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

for v in AGENT_DIR ZIP EXPECTED_SHA VERSION LAUNCHER STATE_FILE LOG_FILE; do
	if [ -z "${!v}" ]; then echo "missing required argument for $v" >&2; exit 2; fi
done

BACKUP_DIR="$AGENT_DIR/agent_update_backup"
STAGE_DIR="$AGENT_DIR/agent_update_stage"

log() {
	mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

write_state() {
	# status, message, version_after, rollback_performed
	local status="$1" message="$2" version_after="$3" rolled_back="$4"
	local tmp="$STATE_FILE.tmp.$$"
	mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
	printf '{"status":"%s","message":"%s","version_target":"%s","version_after":"%s","rollback_performed":%s,"updated_at":"%s"}\n' \
		"$status" "${message//\"/\\\"}" "$VERSION" "$version_after" "$rolled_back" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp" \
		&& mv -f "$tmp" "$STATE_FILE"
}

# Preserved paths: never overwritten by an update and never part of the backup
# restore. Config, runtime data, and the update's own working folders.
is_preserved() {
	case "$1" in
		etc|etc/*|var|var/*|startups|startups/*) return 0 ;;
		agent_update_backup|agent_update_backup/*) return 0 ;;
		agent_update_stage|agent_update_stage/*) return 0 ;;
		Cfg/Preferences.pm|Cfg/bash_prefs.cfg) return 0 ;;
		gsp_agent_update_state.json|gsp_agent_update_request.json|gsp_agent_update.log) return 0 ;;
	esac
	return 1
}

agent_running() {
	[ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" 2>/dev/null
}

start_agent() {
	# Launched detached so this helper can finish and report on its own.
	( cd "$AGENT_DIR" && nohup bash "$LAUNCHER" service >> "$LOG_FILE" 2>&1 & ) >/dev/null 2>&1
}

wait_for_agent_up() {
	# Agent counts as up once it has stayed alive for 30 seconds.
	local waited=0
	while [ "$waited" -lt 120 ]; do
		sleep 5; waited=$((waited + 5))
		if pgrep -f "perl .*gse_agent.pl" >/dev/null 2>&1; then
			local stable=0
			while [ "$stable" -lt 30 ]; do
				sleep 5; stable=$((stable + 5))
				pgrep -f "perl .*gse_agent.pl" >/dev/null 2>&1 || break
			done
			pgrep -f "perl .*gse_agent.pl" >/dev/null 2>&1 && return 0
		fi
	done
	return 1
}

restore_backup() {
	log "Restoring previous install from $BACKUP_DIR"
	if [ ! -d "$BACKUP_DIR" ]; then
		log "No backup folder found; cannot restore"
		return 1
	fi
	( cd "$BACKUP_DIR" && find . -type f ) | while IFS= read -r rel; do
		rel="${rel#./}"
		is_preserved "$rel" && continue
		mkdir -p "$AGENT_DIR/$(dirname "$rel")"
		cp -f "$BACKUP_DIR/$rel" "$AGENT_DIR/$rel"
	done
	return 0
}

fail_and_restore() {
	local message="$1"
	log "FAILED: $message"
	if restore_backup; then
		start_agent
		if wait_for_agent_up; then
			write_state rolled_back "$message; previous agent restored and running" "$(cat "$AGENT_DIR/.gsp_agent_source_revision" 2>/dev/null || true)" true
		else
			write_state failed "$message; restore finished but agent did not start" "" true
		fi
	else
		write_state failed "$message; no backup available to restore" "" false
	fi
	rm -rf "$STAGE_DIR"
	exit 1
}

log "Helper started for version $VERSION"
write_state running "Waiting for agent to stop" "" false

# 1. Ask the agent to stop, then wait for it to exit.
sleep 5
if agent_running; then
	log "Stopping agent $AGENT_PID"
	kill -TERM "$AGENT_PID" 2>/dev/null || true
fi
waited=0
while agent_running && [ "$waited" -lt 120 ]; do sleep 2; waited=$((waited + 2)); done
if agent_running; then
	log "Agent $AGENT_PID did not stop after 120s; ending it"
	kill "$AGENT_PID" 2>/dev/null || true
	sleep 5
fi
log "Agent stopped"

# 2. Re-check the staged zip.
actual_sha="$(sha256sum "$ZIP" 2>/dev/null | cut -d' ' -f1 | tr 'A-F' 'a-f')"
if [ "$actual_sha" != "$(printf '%s' "$EXPECTED_SHA" | tr 'A-F' 'a-f')" ]; then
	log "Checksum mismatch: expected $EXPECTED_SHA got ${actual_sha:-none}"
	write_state failed "Staged release checksum did not match; nothing was changed" "" false
	start_agent
	exit 1
fi
log "Checksum verified"

# 3. Keep one backup of the current install (replaces any older backup).
rm -rf "$BACKUP_DIR" "$STAGE_DIR"
mkdir -p "$BACKUP_DIR" "$STAGE_DIR" || fail_and_restore "Cannot create backup or staging folder"
( cd "$AGENT_DIR" && find . -type f ) | while IFS= read -r rel; do
	rel="${rel#./}"
	is_preserved "$rel" && continue
	mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
	cp -f "$AGENT_DIR/$rel" "$BACKUP_DIR/$rel" || exit 1
done || fail_and_restore "Backup of current install failed"
log "Backup of current install written to $BACKUP_DIR"

# 4. Extract and copy the new files in.
unzip -q -o "$ZIP" -d "$STAGE_DIR/payload" || fail_and_restore "Could not extract release zip"
payload="$STAGE_DIR/payload"
if [ -f "$payload/AgentScripts/gse_agent.pl" ]; then
	payload="$payload/AgentScripts"
fi
[ -f "$payload/gse_agent.pl" ] || fail_and_restore "Release zip does not contain gse_agent.pl"

( cd "$payload" && find . -type f ) | while IFS= read -r rel; do
	rel="${rel#./}"
	is_preserved "$rel" && continue
	mkdir -p "$AGENT_DIR/$(dirname "$rel")"
	cp -f "$payload/$rel" "$AGENT_DIR/$rel" || exit 1
done || fail_and_restore "Copying new files failed"
log "New files copied in"
write_state running "New files installed; starting agent" "$VERSION" false

# 5. Start the new agent and wait for it to stay up.
start_agent
if wait_for_agent_up; then
	log "New agent is running"
	write_state ok "Agent updated to $VERSION and running" "$VERSION" false
	rm -rf "$STAGE_DIR"
	exit 0
fi

fail_and_restore "New agent did not stay running after update"
