#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent_file="$repo_root/AgentScripts/agent_core.pl"
contract_file="$repo_root/docs/GAME_SERVER_LIFECYCLE_CONTRACT.md"
process_doc="$repo_root/docs/PROCESS_MANAGEMENT.md"
panel_doc="$repo_root/docs/PANEL_INTEGRATION.md"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$agent_file" ] || fail "missing AgentScripts/agent_core.pl"
[ -f "$contract_file" ] || fail "missing docs/GAME_SERVER_LIFECYCLE_CONTRACT.md"

perl -Mstrict -Mwarnings - "$agent_file" "$contract_file" "$process_doc" "$panel_doc" <<'PERL' || exit 1
use strict;
use warnings;

my ($agent_file, $contract_file, $process_doc, $panel_doc) = @ARGV;

sub read_file {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "FAIL: cannot read $path: $!\n";
	my $content = do { local $/; <$fh> };
	close($fh);
	return $content;
}

sub fail {
	my ($message) = @_;
	die "FAIL: $message\n";
}

sub require_text {
	my ($text, $needle, $description) = @_;
	index($text, $needle) >= 0 or fail("missing $description");
}

sub reject_text {
	my ($text, $needle, $description) = @_;
	index($text, $needle) < 0 or fail("unexpected $description");
}

sub require_order {
	my ($text, $first, $second, $description) = @_;
	my $first_index = index($text, $first);
	my $second_index = index($text, $second);
	$first_index >= 0 or fail("missing first marker for $description");
	$second_index >= 0 or fail("missing second marker for $description");
	$first_index < $second_index or fail("wrong order for $description");
}

my $source = read_file($agent_file);
my $contract = read_file($contract_file);
my $process_doc_text = read_file($process_doc);
my $panel_doc_text = read_file($panel_doc);

require_text($source, 'use File::Spec;', "File::Spec path normalization import");

$source =~ /sub validate_game_key_without_decrypt\s*\{(.*?)\n\}\n\n# Normalizes/s
	or fail("cannot locate validate_game_key_without_decrypt body");
my $validator = $1;
require_text($validator, 'game_key is required', "required game_key rejection");
require_text($validator, 'm![/\\\\]!', "slash and backslash rejection");
require_text($validator, '$game_key =~ /:/', "drive and stream prefix rejection");
require_text($validator, '$game_key =~ /[\\x00-\\x1f\\x7f]/', "control character rejection");
require_text($validator, '$game_key eq "." || $game_key eq ".." || $game_key =~ /\\.\\./', "traversal rejection");
require_text($validator, '$game_key =~ /[. ]$/', "Windows trailing dot/space rejection");
require_text($validator, 'con|prn|aux|nul|com[1-9]|lpt[1-9]', "reserved Windows name rejection");

$source =~ /sub resolve_game_payload_root_without_decrypt\s*\{(.*?)\n\}\n\n# Resolves a relative payload path/s
	or fail("cannot locate resolve_game_payload_root_without_decrypt body");
my $root_resolver = $1;
require_text($root_resolver, 'File::Spec->catdir($management_abs, $game_key)', "game_root under management_home");
require_text($root_resolver, 'abs_path($candidate)', "existing symlink escape check");
require_text($root_resolver, 'lifecycle_path_is_inside_without_decrypt($management_abs, $candidate_compare)', "management containment check");

$source =~ /sub resolve_game_payload_child_path_without_decrypt\s*\{(.*?)\n\}\n\n# Temporary compatibility/s
	or fail("cannot locate resolve_game_payload_child_path_without_decrypt body");
my $child_resolver = $1;
require_text($child_resolver, 'File::Spec->file_name_is_absolute($part)', "absolute child path rejection");
require_text($child_resolver, '$part =~ /^[A-Za-z]:/', "drive-prefixed child path rejection");
require_text($child_resolver, '$segment eq ".."', "child traversal rejection");
require_text($child_resolver, 'lifecycle_path_is_inside_without_decrypt($root_abs, $candidate_compare)', "game_root containment check");

$source =~ /sub resolve_payload_root_for_current_rpc_without_decrypt\s*\{(.*?)\n\}\n\nsub encode_list/s
	or fail("cannot locate current RPC compatibility resolver");
my $compat = $1;
require_text($compat, 'resolve_game_payload_root_without_decrypt($management_home, $game_key)', "new RPC game_key payload resolution");
require_text($compat, 'temporary Panel compatibility', "temporary compatibility log message");
require_text($compat, 'return ($management_home, "")', "current RPC fallback to supplied payload path");

$source =~ /sub replace_Env_Vars\s*\{(.*?)\n\}\n\n# Validates the XML game_key/s
	or fail("cannot locate replace_Env_Vars body");
my $tokens = $1;
require_text($tokens, '{GAME_HOME_DIR}', "legacy home token remains");
require_text($tokens, '{GAME_HOME_DIR_WINDOWS}', "legacy Windows home token remains");
require_text($tokens, 'cygpath -wa "$homepath"', "quoted game-root cygpath conversion");
require_text($tokens, '{MANAGEMENT_HOME_DIR}', "new GSP management-home token");
require_text($tokens, '{MANAGEMENT_HOME_DIR}', "new GSE management-home token");
require_text($tokens, '{MANAGEMENT_HOME_DIR_WINDOWS}', "new Windows GSP management-home token");
require_text($tokens, '{MANAGEMENT_HOME_DIR_WINDOWS}', "new Windows GSE management-home token");
require_text($tokens, 'cygpath -wa "$management_homepath"', "quoted management-home cygpath conversion");

$source =~ /sub universal_start_without_decrypt\s*\{(.*?)\n\}\n\n# Returns the number of CPUs available\./s
	or fail("cannot locate universal_start_without_decrypt body");
my $start = $1;
require_text($start, 'my $management_home = $home_path', "RPC home_path kept as management_home");
require_text($start, 'resolve_game_payload_root_without_decrypt($management_home, $game_key)', "Start requires validated game_key root");
require_text($start, 'Existing homes must be manually rearranged', "no migration fallback on missing game_root");
require_order($start, 'lifecycle_hard_stop_without_decrypt($home_id, $server_ip, $server_port, $management_home', 'resolve_game_payload_child_path_without_decrypt($management_home, $run_dir)', "hard-stop preflight before payload launch resolution");
require_text($start, 'resolve_game_payload_child_path_without_decrypt($game_binary_dir, $server_exe)', "executable under game run directory");
require_text($start, 'cygpath -wa "$game_binary_dir"', "quoted game working-directory cygpath conversion");
require_text($start, 'set_desired_state_without_decrypt($management_home, "running")', "running marker in management_home");
require_text($start, 'prepare_server_content_runtime_without_decrypt($management_home)', "Server Content runtime in management_home");
require_text($start, 'replace_Env_Vars($screen_id, $home_id, $game_root, $startup_cmd, $game_key, $management_home)', "startup replacements use game_root plus management_home tokens");
require_text($start, 'create_screen_cmd_loop($screen_id, $management_home', "serverStart.bat generated in management_home");
require_text($start, 'backup_home_log( $home_id, $log_file, $game_root . "/" . $console_log )', "console log backup targets game_root");
require_text($start, 'run_before_start_commands($home_id, $management_home, $game_root', "pre-start management script targets game_root");
require_text($start, 'management_home_path => $management_home', "event reports management home");
require_text($start, 'game_home_path => $game_root', "event reports game root");
require_text($start, '"$home_id,$management_home,$server_exe,$run_dir,$startup_cmd,$server_port,$server_ip,$cpu,$nice,$preStart,$envVars,$game_key,$console_log"', "startup replay stores management_home plus game_key");
reject_text($start, 'set_desired_state_without_decrypt($game_root', "desired state under game_root");
reject_text($start, 'prepare_server_content_runtime_without_decrypt($game_root', "Server Content runtime under game_root");
reject_text($start, 'write_bot_definition_without_decrypt($game_root', "bot.def under game_root");
reject_text($start, 'write_bot_definition_without_decrypt($management_home', "bot.def under management_home");

$source =~ /sub run_before_start_commands\s*\{(.*?)\n\}\n\nsub multiline_to_startup_comma_format/s
	or fail("cannot locate run_before_start_commands body");
my $prestart = $1;
require_text($prestart, 'my ($server_id, $management_home, $game_root, $beforestartcmd, $envVars, $game_key)', "pre-start split signature");
require_text($prestart, 'my $prestartcmdfile = $windows_management_home . \'\\_prestart.bat\'', "pre-start script in management_home");
require_text($prestart, 'print FILE "cd \\"$windows_game_root\\"\\r\\n";', "pre-start command executes from game_root");

$source =~ /sub start_rsync_install\s*\{(.*?)\n\}\n\n### \@return PID/s
	or fail("cannot locate start_rsync_install body");
my $rsync = $1;
require_text($rsync, '$game_key) = decrypt_params(@_)', "rsync accepts optional game_key");
require_text($rsync, 'resolve_payload_root_for_current_rpc_without_decrypt($home_path, $game_key, "start_rsync_install")', "rsync payload resolver");
require_text($rsync, 'create_bash_scripts( $payload_root, $bash_scripts_path', "rsync scripts cd to payload root");

$source =~ /sub steam_cmd_without_decrypt\s*\{(.*?)\n\}\n\nsub fetch_steam_version/s
	or fail("cannot locate steam_cmd_without_decrypt body");
my $steam = $1;
require_text($steam, '$arch_bits, $game_key) = @_;', "steam update accepts optional game_key");
require_text($steam, 'resolve_payload_root_for_current_rpc_without_decrypt($home_path, $game_key, "steam_cmd")', "steam payload resolver");
require_text($steam, 'print FILE "force_install_dir \\"$windows_payload_root\\"\\n";', "SteamCMD installs to payload root");
require_text($steam, 'create_bash_scripts( $payload_root, $bash_scripts_path', "Steam scripts cd to payload root");

$source =~ /sub automatic_steam_update\s*\{(.*?)\n\}\n\nsub rsync_progress/s
	or fail("cannot locate automatic_steam_update body");
my $auto_steam = $1;
require_text($auto_steam, '$arch_bits, $game_key)', "automatic update passes game_key into Steam update");
require_text($auto_steam, 'universal_start_without_decrypt($home_id, $game_home', "automatic restart still uses management_home RPC argument");

foreach my $doc ($contract, $process_doc_text, $panel_doc_text)
{
	require_text($doc, '<management_home>/<game_key>', "documented game-key payload root");
	require_text($doc, 'No automatic', "documented no migration tooling");
}
require_text($contract, 'Panel And Linux Handoff', "Panel/Linux handoff section");
require_text($contract, 'KCWin Smoke Test', "KCWin smoke test section");

print "Game-key payload boundary validation passed.\n";
PERL
