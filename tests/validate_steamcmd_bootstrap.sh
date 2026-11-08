#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$repo_root/steamcmd.zip"
bootstrap="$repo_root/AgentScripts/steamcmd/steamcmd.exe"
manifest="$repo_root/AgentScripts/install_payload_manifest.txt"
gitignore="$repo_root/.gitignore"
builder="$repo_root/tools/build_windows_agent_release.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing file: ${1#$repo_root/}"
}

require_text() {
    local file="$1"
    local pattern="$2"
    grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in ${file#$repo_root/}"
}

command -v unzip >/dev/null 2>&1 || fail "unzip is required"
command -v file >/dev/null 2>&1 || fail "file is required"

require_file "$bootstrap"
require_file "$manifest"
require_file "$gitignore"
require_file "$builder"

if [ -f "$archive" ]; then
    unzip -t "$archive" >/dev/null || fail "steamcmd.zip failed ZIP integrity validation"

    entries="$(unzip -Z1 "$archive")"
    [ "$entries" = "steamcmd.exe" ] || fail "steamcmd.zip must contain only root steamcmd.exe; found: $entries"

    if printf '%s\n' "$entries" | grep -Eq '(^/|(^|/)\.\.(/|$)|\\|[\r\n])'; then
        fail "steamcmd.zip contains an unsafe path"
    fi

    unzip -p "$archive" steamcmd.exe | cmp -s - "$bootstrap" || fail "tracked bootstrap does not match steamcmd.zip member"
fi

file "$bootstrap" | grep -Fq "PE32 executable" || fail "AgentScripts/steamcmd/steamcmd.exe is not a Windows PE32 executable"

require_text "$manifest" "AgentScripts/steamcmd/steamcmd.exe"

if git -C "$repo_root" check-ignore -q "AgentScripts/steamcmd/steamcmd.exe"; then
    fail "AgentScripts/steamcmd/steamcmd.exe is ignored"
fi
git -C "$repo_root" check-ignore -q "AgentScripts/steamcmd/linux32/example" || fail "SteamCMD linux32 runtime content is not ignored"
git -C "$repo_root" check-ignore -q "AgentScripts/steamcmd/steamapps/example" || fail "SteamCMD steamapps runtime content is not ignored"
git -C "$repo_root" check-ignore -q "AgentScripts/steamcmd/logs/example.log" || fail "SteamCMD logs are not ignored"
git -C "$repo_root" check-ignore -q "AgentScripts/steamcmd/config/config.vdf" || fail "SteamCMD config state is not ignored"
git -C "$repo_root" check-ignore -q "steamcmd.zip" || fail "repository-root steamcmd.zip source archive is not ignored"

if git -C "$repo_root" ls-files | grep -Eq '^AgentScripts/steamcmd/(linux32|steamapps|logs|config|package|public|siteserverui)(/|$)'; then
    git -C "$repo_root" ls-files | grep -E '^AgentScripts/steamcmd/(linux32|steamapps|logs|config|package|public|siteserverui)(/|$)' >&2
    fail "SteamCMD runtime state is tracked"
fi

require_text "$builder" "AgentScripts/steamcmd/linux32|AgentScripts/steamcmd/linux32/*|AgentScripts/steamcmd/steamapps|AgentScripts/steamcmd/steamapps/*"

echo "SteamCMD bootstrap packaging validation passed."
