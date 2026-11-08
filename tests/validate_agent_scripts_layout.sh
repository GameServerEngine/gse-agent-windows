#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ps_file="$repo_root/Installer-Agent-Windows.ps1"
cmd_file="$repo_root/Installer-Agent-Windows.cmd"
manifest="$repo_root/AgentScripts/install_payload_manifest.txt"

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

require_count() {
    local file="$1"
    local pattern="$2"
    local expected="$3"
    local actual
    actual="$(grep -Fx -- "$pattern" "$file" | wc -l | tr -d ' ')"
    [ "$actual" = "$expected" ] || fail "expected $expected occurrences of '$pattern' in ${file#$repo_root/}, found $actual"
}

require_file "$ps_file"
require_file "$cmd_file"
require_file "$manifest"
require_file "$repo_root/AgentScripts/perl_env.sh"
require_file "$repo_root/AgentScripts/gse_agent.pl"
require_file "$repo_root/AgentScripts/agent_launch.sh"

if git -C "$repo_root" ls-files | grep -q '^GSP/'; then
    git -C "$repo_root" ls-files | grep '^GSP/' >&2
    fail "tracked legacy GSP application tree remains"
fi

require_count "$manifest" "AgentScripts/perl_env.sh" 1
require_count "$manifest" "AgentScripts/gse_agent.pl" 1
require_count "$manifest" "AgentScripts/agent_launch.sh" 1
if grep -Eq '^GSP/(perl_env.sh|gse_agent.pl|agent_launch.sh)$' "$manifest"; then
    fail "manifest still references legacy GSP entry points"
fi

require_text "$ps_file" '[string]$ServiceName = "GSPAgent"'
require_text "$ps_file" 'function New-AgentServiceWrapper'
require_text "$ps_file" '"exec /bin/bash /AgentScripts/agent_launch.sh service"'
require_text "$ps_file" '"-p", "/bin/bash"'
require_text "$ps_file" '"-a", $serviceWrapper'
require_text "$ps_file" '$cygwinCommand = "cd /AgentScripts && . ./perl_env.sh && gsp_perl_preflight && perl -c ./gse_agent.pl"'
require_text "$cmd_file" '-PayloadSourcePath "%GSP_SOURCE_PATH%"'
require_text "$cmd_file" '%GSP_SOURCE_PATH%\AgentScripts\install_payload_manifest.txt'

require_text "$ps_file" '$Script:LegacyApplicationDirName = "GSP"'
require_text "$ps_file" 'Source = Join-Path $appDir $item'
require_text "$ps_file" 'Target = Join-Path $Script:ApplicationDirName $item'
require_text "$ps_file" 'Remove-AgentService'
require_text "$ps_file" 'Backup-ApplicationTrees'
require_text "$ps_file" 'Move-Item -LiteralPath $source -Destination $target -Force'
require_text "$ps_file" 'Copy-PayloadRoot -SourceRoot $resolvedSource -DestinationRoot $InstallPath'
require_text "$ps_file" 'Restore-LocalState -SavedItems $saved'
require_text "$ps_file" 'Assert-CompleteLocalSource -Root $InstallPath'
require_text "$ps_file" 'Legacy application tree still exists after staged activation'
require_text "$ps_file" 'Restore-ApplicationTreeBackups -Backups $appBackups'
require_text "$ps_file" 'Refusing to operate on reparse point'

if stale_matches="$(
    git -C "$repo_root" grep -n -I -E 'GSP/|GSP\\|/GSP|C:\\GSE\\Agent\\GSP|cd /GSP' -- . \
        ':(exclude).devplus/**' \
        ':(exclude)docs/codex-history/**' \
        ':(exclude)docs/agent-modernization-step-1-divergence-report.md' 2>/dev/null |
    grep -Ev '^(AGENTS\.md|docs/GAME_SERVER_LIFECYCLE_CONTRACT\.md):|GSP-WORKSPACE\.md|../GSP/docs/|AgentScripts/GSP\.pid|LegacyApplicationDirName|root/GSP/\(|grep -n -I -E|tests/validate_agent_scripts_layout\.sh' || true
)"; then
    if [ -n "$stale_matches" ]; then
        printf '%s\n' "$stale_matches" >&2
        fail "stale active filesystem reference to legacy application directory remains"
    fi
fi

echo "AgentScripts layout and migration validation passed."
