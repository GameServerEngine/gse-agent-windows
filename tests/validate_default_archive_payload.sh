#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmd_file="$repo_root/Installer-Agent-Windows.cmd"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

skip() {
    echo "SKIP: $*"
    exit 0
}

command -v curl >/dev/null 2>&1 || skip "curl is not available"
command -v unzip >/dev/null 2>&1 || skip "unzip is not available"

[ -f "$cmd_file" ] || fail "missing CMD bootstrap: $cmd_file"

default_url="$(
    sed -n 's/.*set "GSP_RELEASE_ZIP_URL=\([^"]*\)".*/\1/p' "$cmd_file" | head -n 1
)"

[ "$default_url" = "https://git.runlevelsystems.com/GSE/Agent-Windows/archive/unstable.zip" ] || \
    fail "unexpected default archive URL: ${default_url:-<empty>}"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gse-agent-default-archive.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

zip_file="$tmpdir/default.zip"
if ! curl -fL --show-error --retry 3 --connect-timeout 20 -o "$zip_file" "$default_url"; then
    skip "default archive could not be downloaded from $default_url"
fi

[ -s "$zip_file" ] || fail "downloaded archive is empty"

entries="$tmpdir/entries.txt"
unzip -Z1 "$zip_file" > "$entries"

root_count="$(awk -F/ 'NF {print $1}' "$entries" | sort -u | wc -l | tr -d ' ')"
[ "$root_count" -eq 1 ] || fail "expected exactly one archive payload root, found $root_count"

root="$(awk -F/ 'NF {print $1}' "$entries" | sort -u | head -n 1)"
[ -n "$root" ] || fail "archive did not contain a payload root"

grep -Fxq "$root/Installer-Agent-Windows.cmd" "$entries" || \
    fail "archive payload root does not contain Installer-Agent-Windows.cmd"
grep -Fxq "$root/Installer-Agent-Windows.ps1" "$entries" || \
    fail "archive payload root does not contain Installer-Agent-Windows.ps1"
grep -Fxq "$root/AgentScripts/install_payload_manifest.txt" "$entries" || \
    fail "archive payload root does not contain AgentScripts/install_payload_manifest.txt"
grep -Fxq "$root/AgentScripts/perl_env.sh" "$entries" || \
    fail "archive payload root does not contain AgentScripts/perl_env.sh"
grep -Fxq "$root/AgentScripts/gse_agent.pl" "$entries" || \
    fail "archive payload root does not contain AgentScripts/gse_agent.pl"
grep -Fxq "$root/AgentScripts/agent_launch.sh" "$entries" || \
    fail "archive payload root does not contain AgentScripts/agent_launch.sh"
if grep -Eq "^$root/GSP/(perl_env.sh|gse_agent.pl|agent_launch.sh)$" "$entries"; then
    grep -En "^$root/GSP/(perl_env.sh|gse_agent.pl|agent_launch.sh)$" "$entries" >&2
    fail "archive contains legacy GSP application entry points"
fi

legacy_gsp="$(printf 'Install-%s-WindowsAgent' 'GSP')"
legacy_gse="$(printf 'Install-%s-WindowsAgent' 'GSE')"
legacy_pattern="(^|/)(${legacy_gsp}|${legacy_gse})\\.(cmd|ps1)$"
if grep -Eq "$legacy_pattern" "$entries"; then
    grep -En "$legacy_pattern" "$entries" >&2
    fail "archive contains stale installer filenames"
fi

echo "Default archive payload validation passed: $default_url root=$root"
