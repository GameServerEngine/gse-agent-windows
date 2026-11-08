#!/usr/bin/env bash

set -u

MODE="${1:-foreground}"
AGENT_DIR="${GSP_AGENT_DIR:-/AgentScripts}"
CONFIG_FILE="$AGENT_DIR/Cfg/Config.pm"
PREFS_FILE="$AGENT_DIR/Cfg/bash_prefs.cfg"
AGENT_FILE="$AGENT_DIR/gse_agent.pl"
PERL_ENV_FILE="$AGENT_DIR/perl_env.sh"
STATE_FILE="$AGENT_DIR/gsp_agent_update_state.json"
REQUEST_FILE="$AGENT_DIR/gsp_agent_update_request.json"
UPDATE_LOG="$AGENT_DIR/gsp_agent_update.log"
REVISION_FILE="$AGENT_DIR/.gsp_agent_source_revision"
BACKUP_ARCHIVE="$AGENT_DIR/agent_restart_update_backup.tar.gz"
INSTALL_ROOT="$(cd "$AGENT_DIR/.." 2>/dev/null && pwd)"
FOREGROUND_PIDFILE="$AGENT_DIR/gsp_agent_foreground.pid"
SERVICE_PIDFILE="$AGENT_DIR/gsp_agent_service.pid"
LEGACY_RUN_PIDFILE="$AGENT_DIR/gsp_agent_run.pid"
AGENT_PIDFILE="$AGENT_DIR/gsp_agent.pid"
PUREFTPD_PIDFILE="/var/run/pure-ftpd.pid"
PUREFTPD_PASSWD="/etc/pureftpd.passwd"
PUREFTPD_DB="/etc/pureftpd.pdb"
PUREFTPD_BIN="/usr/sbin/pure-ftpd"
PUREPW_BIN="/usr/bin/pure-pw"
UPDATE_ID=""
UPDATE_METADATA_URL=""
UPDATE_PATCH_URL=""
UPDATE_PATCH_SHA256=""
UPDATE_SOURCE_VERSION=""
UPDATE_TARGET_VERSION=""
UPDATE_MANIFEST_URL=""
UPDATE_MANIFEST_SHA256=""
UPDATE_ARCHIVE_URL=""
UPDATE_CHECKSUM=""
UPDATE_VERSION=""
UPDATE_MODE=""

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

load_perl_env() {
	[ -f "$PERL_ENV_FILE" ] || {
		printf 'ERROR: Missing bundled Perl environment file %s\n' "$PERL_ENV_FILE" >&2
		return 1
	}
	. "$PERL_ENV_FILE" || return 1
	gsp_configure_bundled_perl || return 1
}

load_perl_env || fail "Bundled Perl environment initialization failed."



read_pref() {
	local key="$1"
	local default_value="$2"
	local line value
	[ -f "$PREFS_FILE" ] || {
		printf '%s' "$default_value"
		return 0
	}
	line="$(grep -E "^[[:space:]]*${key}=" "$PREFS_FILE" | tail -n 1 || true)"
	[ -n "$line" ] || {
		printf '%s' "$default_value"
		return 0
	}
	value="${line#*=}"
	if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
		value="${value:1:${#value}-2}"
	fi
	printf '%b' "$value"
}




















# A release archive may contain the full install tree directly (AgentScripts/...
# at the top) or nested one level under a single directory (as GitHub/GitLab
# source archives do); return the directory that actually holds that tree.

# Acquires the update source from a full release archive (UPDATE_ARCHIVE_URL),
# verified against its published SHA-256 (UPDATE_CHECKSUM), then runs it
# through the same backup/apply/validate/rollback helpers as the incremental
# patch path above (prepare_patch_backup's path-walk logic, rollback_patch,
# validate_patch_result), just walking the whole release tree instead of a
# patch_root/files + deletions.txt pair. The panel never pulls a working tree
# for this path: only a checked archive.

# Normalize managed startup text by truncating and rewriting the same path so NTFS/Cygwin ACLs stay attached.
normalize_text_file_preserving_acl() {
	local file="$1"
	local transform="$2"
	[ -f "$file" ] || return 0
	perl -Mstrict -Mwarnings - "$file" "$transform" <<'PERL'
my ($file, $transform) = @ARGV;
open my $input, "<:raw", $file or die "open $file for read: $!\n";
local $/;
my $original = <$input>;
close $input or die "close $file after read: $!\n";

my $normalized = $original;
if ($transform eq "line-endings") {
	exit 0 if index($normalized, "\r") < 0;
	$normalized =~ s/\r\n/\n/g;
	$normalized =~ s/\r/\n/g;
} elsif ($transform eq "preference-assignments") {
	$normalized =~ s/^[ \t]+([A-Za-z_][A-Za-z0-9_]*=)/$1/mg;
	exit 0 if $normalized eq $original;
} else {
	die "unknown normalization transform $transform\n";
}

open my $output, ">:raw", $file or die "open $file for same-path write: $!\n";
print {$output} $normalized or die "write $file: $!\n";
close $output or die "close $file after write: $!\n";
PERL
}

normalize_text_files() {
	local root="$1"
	[ -d "$root" ] || return 0
	find "$root" -type f \( -name '*.pl' -o -name '*.pm' -o -name '*.sh' -o -name '*.cfg' \) -print0 2>/dev/null |
		while IFS= read -r -d '' file; do
			normalize_text_file_preserving_acl "$file" line-endings || warn "Could not normalize $file"
		done
}

copy_default_config() {
	local target="$1"
	local template="$2"
	[ -f "$target" ] && return 0
	[ -f "$template" ] || fail "Missing required config template $template"
	cp "$template" "$target" || fail "Could not create $target from $template"
	normalize_text_file_preserving_acl "$target" line-endings || warn "Could not normalize $target"
}

ensure_default_configs() {
	mkdir -p "$AGENT_DIR/Cfg" || fail "Could not create $AGENT_DIR/Cfg"
	copy_default_config "$AGENT_DIR/Cfg/Config.pm" "$AGENT_DIR/Cfg/Config.pm.default"
	copy_default_config "$AGENT_DIR/Cfg/Preferences.pm" "$AGENT_DIR/Cfg/Preferences.pm.default"
	copy_default_config "$AGENT_DIR/Cfg/bash_prefs.cfg" "$AGENT_DIR/Cfg/bash_prefs.cfg.default"
	normalize_text_file_preserving_acl "$PREFS_FILE" preference-assignments || warn "Could not normalize preference assignments in $PREFS_FILE"
}

config_value() {
	local key="$1"
	local default_value="$2"
	[ -f "$CONFIG_FILE" ] || {
		printf '%s\n' "$default_value"
		return 0
	}
	# The lookup key must not reach Perl through @ARGV: with -n, the
	# implicit while(<>) loop opens its first @ARGV element as an input
	# file before the loop body ever runs, so a leading "shift @ARGV"
	# inside that body is too late and Perl tries (and fails) to open the
	# key name itself as a file. That failure is silent (exit 0, no
	# output), so every config_value() call returned "" instead of either
	# the real value or $default_value. Pass the key through the
	# environment instead, leaving only $CONFIG_FILE in @ARGV.
	local value
	value="$(CONFIG_VALUE_LOOKUP_KEY="$key" perl -Mstrict -Mwarnings -ne '
		my $key = $ENV{CONFIG_VALUE_LOOKUP_KEY};
		if (/^\s*\Q$key\E\s*=>\s*([\"\047])([^\"\047]*)\1\s*,?\s*$/) {
			print $2;
			exit;
		}
	' "$CONFIG_FILE" 2>/dev/null)"
	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default_value"
	fi
}

agent_port() {
	local port
	port="$(config_value listen_port 12679)"
	case "$port" in
		''|*[!0-9]*) printf '12679\n' ;;
		*) printf '%s\n' "$port" ;;
	esac
}

validate_required_config() {
	[ -f "$CONFIG_FILE" ] || fail "Missing $CONFIG_FILE"
	local key_value
	key_value="$(config_value key "")"
	if [ -z "$key_value" ] || [ "$key_value" = "CHANGE_ME_PANEL_AGENT_KEY" ] || [ "$key_value" = "{panel_agent_key}" ]; then
		fail "$CONFIG_FILE still contains placeholder key values. Run Installer-Agent-Windows.ps1 -Mode Reconfigure."
	fi
}

valid_pid_file() {
	local file="$1"
	local pid
	[ -f "$file" ] || return 1
	pid="$(tr -cd '0-9' < "$file" 2>/dev/null)"
	[ -n "$pid" ] || return 1
	kill -0 "$pid" >/dev/null 2>&1
}

pid_value() {
	tr -cd '0-9' < "$1" 2>/dev/null
}

remove_stale_pid_file() {
	local file="$1"
	[ -f "$file" ] || return 0
	if ! valid_pid_file "$file"; then
		rm -f "$file" 2>/dev/null || true
	fi
}

refuse_existing_instance() {
	local file
	for file in "$FOREGROUND_PIDFILE" "$SERVICE_PIDFILE" "$LEGACY_RUN_PIDFILE" "$AGENT_PIDFILE"; do
		if valid_pid_file "$file"; then
			fail "Another GSP agent instance appears to be running from $file with PID $(pid_value "$file")"
		fi
		remove_stale_pid_file "$file"
	done
}

port_in_use() {
	local port="$1"
	if command -v powershell.exe >/dev/null 2>&1; then
		powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$p=$port; if (Get-NetTCPConnection -LocalPort \$p -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >/dev/null 2>&1
		case "$?" in
			0) return 0 ;;
			1) return 1 ;;
		esac
	fi
	local line proto token local_port
	while IFS= read -r line; do
		set -- $line
		proto="${1:-}"
		case "$proto" in
			TCP|tcp) ;;
			*) continue ;;
		esac
		case "$line" in
			*LISTEN*|*Listen*|*listen*) ;;
			*) continue ;;
		esac
		shift
		for token in "$@"; do
			case "$token" in
				*:*|*.*)
					local_port="${token##*:}"
					local_port="${local_port##*.}"
					[ "$local_port" = "$port" ] && return 0
					;;
			esac
		done
	done <<EOF
$(netstat -an 2>/dev/null)
EOF
	return 1
}

pureftpd_port() {
	local port
	port="$(read_pref ftp_port 21)"
	case "$port" in
		''|*[!0-9]*) printf '21\n' ;;
		*) printf '%s\n' "$port" ;;
	esac
}

pureftpd_ip() {
	local ip
	ip="$(read_pref ftp_ip 0.0.0.0)"
	[ -n "$ip" ] || ip="0.0.0.0"
	printf '%s\n' "$ip"
}

pureftpd_passive_range() {
	local range
	range="$(read_pref ftp_pasv_range "")"
	if [[ "$range" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
		printf '%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	fi
}

ensure_pureftpd() {
	[ "$(read_pref run_pureftpd 0)" = "1" ] || return 0
	[ -f "$PUREFTPD_BIN" ] || { warn "Pure-FTPd is enabled but $PUREFTPD_BIN is missing; continuing without FTP."; return 0; }
	[ -f "$PUREPW_BIN" ] || { warn "Pure-FTPd is enabled but $PUREPW_BIN is missing; continuing without FTP."; return 0; }

	mkdir -p /var/run /etc || { warn "Could not prepare Pure-FTPd runtime directories; continuing without FTP."; return 0; }
	touch "$PUREFTPD_PASSWD" || { warn "Could not create $PUREFTPD_PASSWD; continuing without FTP."; return 0; }
	"$PUREPW_BIN" mkdb >/dev/null 2>&1 || { warn "Could not rebuild $PUREFTPD_DB from $PUREFTPD_PASSWD; continuing without FTP."; return 0; }

	if valid_pid_file "$PUREFTPD_PIDFILE"; then
		return 0
	fi
	remove_stale_pid_file "$PUREFTPD_PIDFILE"

	local port ip passive
	port="$(pureftpd_port)"
	ip="$(pureftpd_ip)"
	passive="$(pureftpd_passive_range)"
	if port_in_use "$port"; then
		warn "Configured Pure-FTPd port $port is already listening; continuing without starting bundled FTP."
		return 0
	fi

	local args=(-B -A -E -j -lpuredb:"$PUREFTPD_DB" -g "$PUREFTPD_PIDFILE" -S "${ip},${port}")
	if [ -n "$passive" ]; then
		args+=(-p "$passive")
	fi

	printf 'Launching bundled Pure-FTPd on %s:%s...\n' "$ip" "$port"
	"$PUREFTPD_BIN" "${args[@]}" || { warn "Could not launch bundled Pure-FTPd; continuing without FTP."; return 0; }
	sleep 1
	valid_pid_file "$PUREFTPD_PIDFILE" || { warn "Pure-FTPd did not create a valid PID file at $PUREFTPD_PIDFILE; continuing without FTP."; return 0; }
}

refuse_busy_port() {
	local port
	port="$(agent_port)"
	if port_in_use "$port"; then
		fail "Configured agent port $port is already listening. Stop the existing service or foreground agent before launching another instance."
	fi
}

validate_agent_file() {
	[ -f "$AGENT_FILE" ] || fail "Missing $AGENT_FILE"
	gsp_perl_preflight || fail "Bundled Perl module preflight failed for $AGENT_FILE"
	perl -c "$AGENT_FILE" || fail "Perl syntax validation failed for $AGENT_FILE"
}

stop_foreground() {
	if ! valid_pid_file "$FOREGROUND_PIDFILE"; then
		remove_stale_pid_file "$FOREGROUND_PIDFILE"
		fail "No valid foreground agent PID file was found. Use Windows Services to stop service mode."
	fi

	local pid
	pid="$(pid_value "$FOREGROUND_PIDFILE")"
	printf 'Stopping foreground GSP agent PID %s...\n' "$pid"
	kill -TERM "$pid" >/dev/null 2>&1 || fail "Could not signal foreground agent PID $pid"
	sleep 2
	if kill -0 "$pid" >/dev/null 2>&1; then
		kill -KILL "$pid" >/dev/null 2>&1 || fail "Could not force-stop foreground agent PID $pid"
	fi

	rm -f "$FOREGROUND_PIDFILE" "$LEGACY_RUN_PIDFILE" 2>/dev/null || true
	if [ -f "$AGENT_PIDFILE" ] && [ "$(pid_value "$AGENT_PIDFILE")" = "$pid" ]; then
		rm -f "$AGENT_PIDFILE" 2>/dev/null || true
	fi
	return 0
}

launch_agent() {
	local mode="$1"
	local pidfile="$2"
	shift 2

	cd "$AGENT_DIR" || fail "Could not enter $AGENT_DIR"
	normalize_text_files "$AGENT_DIR"
	ensure_default_configs
	validate_required_config
	refuse_existing_instance
	refuse_busy_port
	validate_agent_file
	ensure_pureftpd

	printf 'Launching GSE Windows Agent in %s mode on port %s...\n' "$mode" "$(agent_port)"
	exec perl "$AGENT_FILE" -pidfile "$pidfile" "$@"
}

case "$MODE" in
	foreground)
		launch_agent foreground "$FOREGROUND_PIDFILE" --log-stdout
		;;
	service)
		# Honor the agent mode file: foreground means the service must not run the agent.
		MODE_FILE="$AGENT_DIR/etc/agent-mode"
		if [ -f "$MODE_FILE" ] && [ "$(tr -d '\r\n ' < "$MODE_FILE")" = "foreground" ]; then
			printf 'Agent mode is foreground; service will not start the agent.\n'
			exit 0
		fi
		launch_agent service "$SERVICE_PIDFILE"
		;;
	stop-foreground)
		stop_foreground
		;;
	*)
		fail "Unknown mode '$MODE'. Expected foreground, service, or stop-foreground."
		;;
esac
