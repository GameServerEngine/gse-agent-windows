#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent_file="$repo_root/AgentScripts/gse_agent.pl"
preferences_file="$repo_root/AgentScripts/Cfg/Preferences.pm.default"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local file="$1"
    local text="$2"
    grep -Fq "$text" "$file" || fail "missing expected text in ${file#$repo_root/}: $text"
}

require_text "$agent_file" "use GSE::Container::Runtime;"
require_text "$agent_file" "container_capabilities"
require_text "$agent_file" "container_create"
require_text "$agent_file" "container_inspect"
require_text "$agent_file" "container_start"
require_text "$agent_file" "container_stop"
require_text "$agent_file" "container_restart"
require_text "$agent_file" "container_delete"
require_text "$agent_file" "sub container_lifecycle_rpc"
require_text "$agent_file" "Container runtime is disabled on this agent."
require_text "$agent_file" "default_for_legacy_game_records => JSON::PP::false()"

require_text "$preferences_file" "container_runtime_enabled => '0'"
require_text "$preferences_file" "container_runtime => 'docker'"
require_text "$preferences_file" "container_runtime_docker_binary => 'docker'"
require_text "$preferences_file" "container_data_root => ''"

if grep -E "universal_start[[:space:]]*=>[[:space:]]*\\\\&container_|stop_server[[:space:]]*=>[[:space:]]*\\\\&container_|restart_server[[:space:]]*=>[[:space:]]*\\\\&container_|server_status[[:space:]]*=>[[:space:]]*\\\\&container_" "$agent_file" >/dev/null; then
    fail "legacy lifecycle dispatch was routed to the container boundary"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/AgentScripts/Cfg" "$tmp_dir/AgentScripts/GSE/Container"
cp "$agent_file" "$tmp_dir/AgentScripts/gse_agent.pl"
cp "$repo_root/AgentScripts/GSE/Container/Runtime.pm" "$tmp_dir/AgentScripts/GSE/Container/Runtime.pm"
cp "$repo_root/AgentScripts/Cfg/Config.pm.default" "$tmp_dir/AgentScripts/Cfg/Config.pm"
cp "$repo_root/AgentScripts/Cfg/Preferences.pm.default" "$tmp_dir/AgentScripts/Cfg/Preferences.pm"

perl -I "$repo_root/AgentScripts" -c "$tmp_dir/AgentScripts/gse_agent.pl" >/dev/null

echo "Container RPC boundary validation passed."
