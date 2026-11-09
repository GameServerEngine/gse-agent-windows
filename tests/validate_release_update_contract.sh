#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent_pl="$repo_root/AgentScripts/agent_core.pl"
launch_sh="$repo_root/AgentScripts/agent_launch.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

require_text() {
	local file="$1"
	local pattern="$2"
	grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in ${file#$repo_root/}"
}

# --- static contract: the release-update RPC and its dispatch registration exist ---
require_text "$agent_pl" "sub agent_release_update"
require_text "$agent_pl" "agent_release_update			=> \&agent_release_update,"
require_text "$agent_pl" "Release archive URL must be an http(s) .zip URL."
require_text "$agent_pl" "Release checksum must be a SHA-256 hex digest."

# --- static contract: the restart-time wrapper has both acquisition modes wired,
# and reuses the existing patch pipeline's backup/rollback/validate helpers ---
require_text "$launch_sh" "apply_archive_update"
require_text "$launch_sh" "find_release_payload_root"
require_text "$launch_sh" 'UPDATE_MODE="archive"'
require_text "$launch_sh" 'UPDATE_MODE="patch"'
grep -Fq 'rollback_patch "$created_list"' "$launch_sh" || fail "apply_archive_update does not reuse the existing rollback_patch helper"
grep -Fq 'validate_patch_result' "$launch_sh" || fail "apply_archive_update does not reuse the existing validate_patch_result helper"

bash -n "$launch_sh" || fail "agent_launch.sh failed bash -n"

if command -v perl >/dev/null 2>&1; then
	tmp_cfg_dir="$(mktemp -d "${TMPDIR:-/tmp}/gse-win-agent-syntax.XXXXXX")"
	trap 'rm -rf "$tmp_cfg_dir"' EXIT
	cp "$repo_root/AgentScripts/Cfg/Config.pm.default" "$tmp_cfg_dir/Config.pm"
	cp "$repo_root/AgentScripts/Cfg/Preferences.pm.default" "$tmp_cfg_dir/Preferences.pm"
	( cd "$repo_root/AgentScripts" && cp "$tmp_cfg_dir/Config.pm" Cfg/Config.pm && cp "$tmp_cfg_dir/Preferences.pm" Cfg/Preferences.pm && perl -c agent_core.pl; rc=$?; rm -f Cfg/Config.pm Cfg/Preferences.pm; exit $rc ) \
		|| fail "agent_core.pl failed perl -c"
else
	echo "SKIP: perl is not available for agent_core.pl -c check"
fi

echo "Windows release-update RPC and restart-time wrapper contract validation passed."
echo "NOTE: the end-to-end download/checksum/extract/backup/swap/restart-wrapper flow was verified"
echo "live on the WinDev test VM in C:\\gse-test\\agent-update (isolated from C:\\gse and C:\\ogp64;"
echo "removed after the test). See STATUS-RELEASE-STOREFRONT.md for the run details."
