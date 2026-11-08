#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launch_file="$repo_root/AgentScripts/agent_launch.sh"
start_file="$repo_root/agent_start.bat"
ps_file="$repo_root/Installer-Agent-Windows.ps1"
offline_contract="$repo_root/tests/validate_offline_installer_contract.sh"
windows_ops="$repo_root/docs/WINDOWS_OPERATIONS.md"

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

require_absent() {
    local file="$1"
    local pattern="$2"
    if grep -Fq -- "$pattern" "$file"; then
        fail "unexpected '$pattern' in ${file#$repo_root/}"
    fi
}

assert_acl_preserving_helper_contract() {
    perl -Mstrict -Mwarnings - "$launch_file" <<'PERL' || fail "startup ACL-preserving normalization contract regressed"
my ($launch_file) = @ARGV;
open my $fh, '<', $launch_file or die "open $launch_file: $!";
local $/;
my $text = <$fh>;

die "launcher still uses sed -i\n" if $text =~ /\bsed\s+-i\b/;

my ($helper) = $text =~ /(normalize_text_file_preserving_acl\(\) \{.*?^}\n\nnormalize_text_files\(\) \{)/ms;
die "missing normalize_text_file_preserving_acl helper\n" if !defined $helper;

for my $required (
    'open my $input, "<:raw", $file',
    'exit 0 if index($normalized, "\r") < 0;',
    '$normalized =~ s/\r\n/\n/g;',
    '$normalized =~ s/\r/\n/g;',
    'open my $output, ">:raw", $file',
    'print {$output} $normalized',
) {
    die "missing helper contract $required\n" if index($helper, $required) < 0;
}

die "helper must not rename or replace target files\n" if $helper =~ /\b(rename|mktemp|mv|Move-Item|ReplaceFile)\b/;
exit 0;
PERL
}

require_file "$launch_file"
require_file "$start_file"
require_file "$ps_file"
require_file "$offline_contract"
require_file "$windows_ops"

assert_acl_preserving_helper_contract

require_absent "$launch_file" "sed -i"
require_text "$launch_file" 'normalize_text_file_preserving_acl "$file" line-endings || warn "Could not normalize $file"'
require_text "$launch_file" 'normalize_text_file_preserving_acl "$target" line-endings || warn "Could not normalize $target"'
require_text "$launch_file" 'normalize_text_file_preserving_acl "$PREFS_FILE" preference-assignments || warn "Could not normalize preference assignments in $PREFS_FILE"'

require_text "$start_file" '"%ROOT%bin\bash.exe" -lc "cd /AgentScripts && exec /bin/bash /AgentScripts/agent_launch.sh foreground"'
require_text "$launch_file" 'exec perl "$AGENT_FILE" -pidfile "$pidfile" "$@"'
require_absent "$launch_file" 'exec "$AGENT_FILE"'

require_text "$ps_file" 'function Reset-ManagedFileAcl'
require_text "$ps_file" 'Invoke-Checked -FilePath "icacls.exe" -Arguments @($Path, "/reset")'
require_text "$ps_file" 'foreach ($managedFile in @($launchScript, $perlEnvScript, $agentFile))'
require_text "$offline_contract" 'function Reset-ManagedFileAcl'
require_text "$offline_contract" 'Reset-ManagedFileAcl -Path \$managedFile'
require_text "$windows_ops" 'Startup normalization must preserve file identity and ACLs'
require_text "$windows_ops" 'explicit Bash and Perl interpreters'

echo "Startup ACL and interpreter contract validation passed."
