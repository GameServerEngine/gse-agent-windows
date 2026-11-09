#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent_file="$repo_root/AgentScripts/agent_core.pl"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$agent_file" ] || fail "missing AgentScripts/agent_core.pl"

perl -Mstrict -Mwarnings - "$agent_file" <<'PERL' || exit 1
use strict;
use warnings;

my ($agent_file) = @ARGV;
open(my $fh, '<', $agent_file) or die "FAIL: cannot read $agent_file: $!\n";
my $source = do { local $/; <$fh> };
close($fh);
my $repo_root = $agent_file;
$repo_root =~ s{/AgentScripts/agent_core\.pl\z}{};

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

sub reject_regex {
	my ($text, $pattern, $description) = @_;
	$text !~ $pattern or fail("unexpected $description");
}

sub require_order {
	my ($text, $first, $second, $description) = @_;
	my $first_index = index($text, $first);
	my $second_index = index($text, $second);
	$first_index >= 0 or fail("missing first marker for $description");
	$second_index >= 0 or fail("missing second marker for $description");
	$first_index < $second_index or fail("wrong order for $description");
}

sub require_count {
	my ($text, $needle, $expected, $description) = @_;
	my $count = 0;
	my $offset = 0;
	while(($offset = index($text, $needle, $offset)) >= 0)
	{
		$count++;
		$offset += length($needle);
	}
	$count == $expected or fail("$description expected $expected occurrence(s), found $count");
}

# Models the generated BAT :SECONDS_NOW normalization so Linux-side tests can
# verify live WMIC suffix/CRLF handling without executing cmd.exe.
sub batch_model_seconds_from_wmic_localdatetime {
	my ($raw_value) = @_;
	return undef unless(defined($raw_value) && $raw_value ne "");
	my $timestamp = substr($raw_value, 0, 14);
	return undef unless($timestamp =~ /^\d{14}\z/);
	my $hour = substr($timestamp, 8, 2) + 0;
	my $minute = substr($timestamp, 10, 2) + 0;
	my $second = substr($timestamp, 12, 2) + 0;
	return undef if($hour > 23 || $minute > 59 || $second > 59);
	return ($hour * 3600) + ($minute * 60) + $second;
}

# Models the generated BAT post-launch restart decision from two WMIC readings.
sub batch_model_runtime_branch {
	my ($start_raw, $end_raw) = @_;
	my $start_seconds = batch_model_seconds_from_wmic_localdatetime($start_raw);
	my $end_seconds = batch_model_seconds_from_wmic_localdatetime($end_raw);
	return "clock-error" unless(defined($start_seconds) && defined($end_seconds));
	my $runtime_seconds = $end_seconds - $start_seconds;
	$runtime_seconds += 86400 if($runtime_seconds < 0);
	return $runtime_seconds < 15 ? "rapid-exit" : "restart";
}

$source =~ /sub create_screen_cmd_loop\s*\{(.*?)\n\}\n\nsub replace_Env_Vars/s
	or fail("cannot locate create_screen_cmd_loop body");
my $loop = $1;

$source =~ /sub windows_relative_game_executable_name_without_decrypt\s*\{(.*?)\n\}\n\n# Builds the stable Windows console title/s
	or fail("cannot locate relative game executable helper");
my $relative_executable = $1;
require_text($relative_executable, 'game executable path is required', "relative executable required path rejection");
require_text($relative_executable, 'game executable path must not end with a separator', "relative executable trailing separator rejection");
require_text($relative_executable, 'game executable filename must not contain traversal', "relative executable traversal rejection");
require_text($relative_executable, 'game executable filename must not contain a Windows drive or stream prefix', "relative executable drive/stream rejection");
require_text($relative_executable, 'game executable filename must not contain BAT metacharacters', "relative executable BAT metacharacter rejection");
require_text($relative_executable, 'game executable filename must contain only letters, digits, dot, underscore, and hyphen', "relative executable strict unquoted basename rejection");
require_text($relative_executable, 'game executable filename uses a reserved Windows device name', "relative executable reserved device rejection");
require_text($relative_executable, 'return ($relative_name, "")', "relative executable basename return");

$source =~ /sub windows_start_priority_switch_without_decrypt\s*\{(.*?)\n\}\n\n# Derives the pathless executable name/s
	or fail("cannot locate Windows START priority helper");
my $priority_switch = $1;
require_text($priority_switch, 'normal => "/normal"', "normal priority switch mapping");
require_text($priority_switch, 'belownormal => "/belownormal"', "below-normal priority switch mapping");
require_text($priority_switch, 'abovenormal => "/abovenormal"', "above-normal priority switch mapping");
require_text($priority_switch, 'realtime => "/realtime"', "realtime priority switch mapping");
require_text($priority_switch, 'return (undef, "unsupported Windows START priority class: $priority_class")', "unsupported priority rejection");

require_text($loop, 'Path::Class::File->new($management_home, "serverStart.bat")', "management-home serverStart.bat generation");
require_text($loop, '@echo off', "batch echo disable");
require_text($loop, 'setlocal EnableExtensions EnableDelayedExpansion', "standard setlocal flags");
require_text($loop, 'for %%I in (\"%~dp0.\") do set \"INSTANCE=%%~nxI\"', "instance folder name derivation");
require_text($loop, 'set \"WATCHDOG_TITLE=%INSTANCE%_watchdog\"', "watchdog title");
require_text($loop, 'set \"BOT_TITLE=%INSTANCE%_bot\"', "bot title");
require_text($loop, 'set \"GAME_TITLE=%INSTANCE%_game\"', "game title");
require_text($loop, 'set \"BOT_SUPERVISOR_MARKER=BOT_SUPERVISOR_%INSTANCE%\"', "per-instance BOT supervisor marker");
require_text($loop, 'set \"STOP_FILE=%~dp0status.stopped\"', "stop marker path");
require_text($loop, 'if /I not \"%~1\"==\"bot-supervisor\" if exist \"%STOP_FILE%\" del \"%STOP_FILE%\"', "old stop marker removal only on fresh main start");
require_text($loop, 'windows_relative_game_executable_name_without_decrypt($game_file)', "relative game executable derivation");
require_text($loop, 'set \"GAME_WORKDIR=$batch_game_workdir\"', "game working-directory assignment");
require_text($loop, 'set \"GAME_COMMAND=$batch_game_file\"', "game command assignment");
require_text($loop, 'set \"GAME_EXECUTABLE=$batch_game_relative_executable\"', "relative game executable assignment");
require_text($loop, 'set \"GAME_OPTIONS=$batch_game_args\"', "game options assignment");
require_text($loop, 'set \"GAME_PORT=$batch_game_port\"', "single game port assignment");
require_text($loop, 'windows_start_priority_switch_without_decrypt($priority_class)', "generator-side priority normalization");
require_text($loop, 'set \"GAME_PRIORITY=$batch_priority_switch\"', "normalized priority assignment");
require_text($loop, 'title %WATCHDOG_TITLE%', "watchdog console title");
require_text($loop, 'if exist \"%~dp0_alsorun.cmd\" set \"ALSO_FILE=%~dp0_alsorun.cmd\"', "current _alsorun.cmd load");
require_text($loop, 'if not defined ALSO_FILE if exist \"%~dp0_alsoRun.cmd\" set \"ALSO_FILE=%~dp0_alsoRun.cmd\"', "legacy _alsoRun.cmd load");
require_text($loop, 'if /I \"!ALSO_KEY!\"==\"workdir\" set \"ALSO_WORKDIR=!ALSO_VALUE!\"', "workdir compatibility mapping");
require_text($loop, 'if /I \"!ALSO_KEY!\"==\"executable\" set \"ALSO_COMMAND=!ALSO_VALUE!\"', "executable compatibility mapping");
require_text($loop, 'if /I \"!ALSO_KEY!\"==\"arguments\" set \"ALSO_OPTIONS=!ALSO_VALUE!\"', "arguments compatibility mapping");
require_text($loop, 'if defined ALSO_WORKDIR if defined ALSO_COMMAND set \"HAS_BOT=1\"', "usable bot gate");
require_text($loop, 'if /I \"%~1\"==\"bot-supervisor\" goto BOT_SUPERVISOR', "single BAT bot supervisor mode");

require_text($loop, ':WATCHDOG_LOOP', "main watchdog loop label");
require_text($loop, 'if exist \"%STOP_FILE%\" goto SHUTDOWN', "stop marker guard");
require_text($loop, 'call :ENSURE_BOT_SUPERVISOR', "BOT supervisor from main watchdog");
require_text($loop, 'cd /d \"%GAME_WORKDIR%\"', "game working-directory change before launch");
require_text($loop, 'Unable to change to game workdir', "working-directory failure log");
require_text($loop, 'call :SECONDS_NOW START_SECONDS', "game launch start timestamp");
require_text($loop, 'if errorlevel 1', "clock failure stop path");
require_text($loop, 'if defined GAME_PRIORITY set \"GAME_START_FLAGS=!GAME_START_FLAGS! %GAME_PRIORITY%\"', "complete priority switch append");
require_text($loop, 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%', "blocking unquoted relative supervised game launch");
require_text($loop, 'set \"GAME_EXIT_CODE=%ERRORLEVEL%\"', "game exit code capture");
require_text($loop, 'call :SECONDS_NOW END_SECONDS', "game launch end timestamp");
require_text($loop, 'set /A RUNTIME_SECONDS=END_SECONDS-START_SECONDS', "game runtime measurement");
require_text($loop, 'if !RUNTIME_SECONDS! LSS 0 set /A RUNTIME_SECONDS+=86400', "midnight rollover runtime handling");
require_text($loop, 'if !RUNTIME_SECONDS! LSS 15', "upstream-style rapid exit threshold");
require_text($loop, 'type nul > \"%STOP_FILE%\"', "rapid exit writes stop marker");
require_text($loop, 'call :WAIT_SECONDS 30', "controlled normal crash restart delay");
require_order($loop, 'cd /d \"%GAME_WORKDIR%\"', 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%', "workdir change before relative game launch");
require_order($loop, 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%', 'if !RUNTIME_SECONDS! LSS 15', "restart decision only after blocking game returns");
require_order($loop, 'if !RUNTIME_SECONDS! LSS 15', 'call :WAIT_SECONDS 30', "rapid-exit protection before normal restart delay");

require_text($loop, ':WAIT_SECONDS', "stop-aware wait helper");
require_text($loop, ':WAIT_SECONDS_ALWAYS', "shutdown grace wait helper");
require_text($loop, 'ping -n 2 127.0.0.1 >nul', "non-interactive ping wait");
require_text($loop, 'call :WAIT_SECONDS_ALWAYS 60', "bounded shutdown grace without timeout");

require_text($loop, ':SECONDS_NOW', "runtime clock helper label");
require_text($loop, 'wmic os get LocalDateTime /value', "WMIC LocalDateTime runtime clock source");
require_text($loop, 'set \"WMIC_TIMESTAMP=!WMIC_LOCALDATETIME:~0,14!\"', "WMIC timestamp suffix/control trimming");
require_text($loop, 'echo(!WMIC_TIMESTAMP!|findstr /R /C:\"^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\$\" >nul || (', "no-space exact 14-digit timestamp validation pipeline");
require_text($loop, '^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\$', "exact 14-digit timestamp validation");
require_text($loop, 'set \"WMIC_HOUR=!WMIC_TIMESTAMP:~8,2!\"', "WMIC hour parsing from normalized timestamp");
require_text($loop, 'set \"WMIC_MINUTE=!WMIC_TIMESTAMP:~10,2!\"', "WMIC minute parsing from normalized timestamp");
require_text($loop, 'set \"WMIC_SECOND=!WMIC_TIMESTAMP:~12,2!\"', "WMIC second parsing from normalized timestamp");
require_text($loop, 'set /A WMIC_HOUR_NUM=1!WMIC_HOUR!-100', "leading-zero-safe hour arithmetic");
require_text($loop, 'set /A WMIC_MINUTE_NUM=1!WMIC_MINUTE!-100', "leading-zero-safe minute arithmetic");
require_text($loop, 'set /A WMIC_SECOND_NUM=1!WMIC_SECOND!-100', "leading-zero-safe second arithmetic");
require_text($loop, 'set /A \"%~1=(WMIC_HOUR_NUM*3600)+(WMIC_MINUTE_NUM*60)+WMIC_SECOND_NUM\"', "seconds since midnight assignment");
require_text($loop, 'Unable to read WMIC LocalDateTime for lifecycle runtime calculation; stopping watchdog.', "missing WMIC lifecycle error");
require_text($loop, 'Invalid WMIC LocalDateTime', "invalid WMIC lifecycle error");

require_text($loop, ':FIND_BOT_SUPERVISOR', "BOT supervisor marker lookup");
require_text($loop, 'wmic process where \"name=\'cmd.exe\'\" get ProcessId^,CommandLine /FORMAT:LIST', "BOT supervisor WMIC command-line lookup");
require_text($loop, 'findstr /I /C:\"%BOT_SUPERVISOR_MARKER%\"', "BOT supervisor marker match");
require_text($loop, 'start \"\" /B /D \"%~dp0\" cmd.exe /V:ON /C \"\"%~f0\" bot-supervisor \"%BOT_SUPERVISOR_MARKER%\"\"', "background no-new-window BOT supervisor launch");
require_text($loop, ':FIND_BOT_PROCESS', "BOT process identity lookup");
require_text($loop, 'wmic process get ProcessId^,ExecutablePath^,CommandLine /FORMAT:LIST', "BOT process WMIC executable/command-line lookup");
require_text($loop, 'set \"BOT_COMMAND_NORM=%ALSO_COMMAND:\\\\=/%\"', "normalized BOT executable path");
require_text($loop, 'set \"BOT_WORKDIR_NORM=%ALSO_WORKDIR:\\\\=/%\"', "normalized BOT working directory");
require_text($loop, 'set \"BOT_OPTIONS_NORM=%ALSO_OPTIONS:\\\\=/%\"', "normalized BOT command-line/config identity");
require_text($loop, ':BOT_SUPERVISOR', "BOT supervisor mode label");
require_text($loop, 'start \"\" /B /D \"%ALSO_WORKDIR%\" /WAIT \"%ALSO_COMMAND%\" %ALSO_OPTIONS%', "blocking background no-new-window BOT launch inside BOT supervisor");
require_text($loop, ':KILL_BOT_INSTANCE', "BOT cleanup label");
require_text($loop, 'taskkill /F /T /PID !BOT_SUPERVISOR_PID!', "BOT supervisor tree cleanup");
require_text($loop, 'taskkill /F /T /PID !BOT_PROCESS_PID!', "direct matching BOT tree cleanup");
require_text($loop, 'taskkill /F /T /FI \"WINDOWTITLE eq %BOT_TITLE%\"', "title-only BOT cleanup fallback");
require_order($loop, ':BOT_SUPERVISOR', 'start \"\" /B /D \"%ALSO_WORKDIR%\" /WAIT', "BOT supervisor owns BOT restart without creating another game");

require_text($loop, 'netstat -ano ^| findstr /R /C:\"^[ ][ ]*TCP\" /C:\"^[ ][ ]*UDP\"', "shutdown TCP-or-UDP netstat scan");
require_text($loop, 'findstr /R /C:\":%GAME_PORT%\\$\"', "local endpoint ending in configured port");
require_text($loop, 'if not \"!PORT_PID!\"==\"0\" if not \"!PORT_PID!\"==\"4\" taskkill /F /T /PID !PORT_PID!', "non-System port PID cleanup");
require_text($loop, 'cmd.exe /c "%2$s"', "direct screen-owned serverStart.bat command");

reject_text($loop, 'timeout /T', "interactive timeout wait");
reject_text($loop, 'timeout /t', "interactive timeout wait");
reject_text($loop, 'powershell.exe', "PowerShell in generated BAT");
reject_text($loop, 'Start-Process', "PowerShell process launcher");
reject_text($loop, 'watchdog.pid', "BAT-created watchdog PID file");
reject_text($loop, 'game.pid', "BAT-created game PID file");
reject_text($loop, 'bot.pid', "BAT-created bot PID file");
reject_text($loop, 'bot.def', "generated bot definition file");
reject_text($loop, '_serverStart.bat', "obsolete _serverStart.bat generation");
reject_text($loop, '_serverStartPid.ps1', "generated PowerShell PID helper");
reject_text($loop, '_serverStartupdated.bat', "nested replacement batch");
reject_text($loop, 'set \"GAME_RUNNING=0\"', "detached port-poll launch loop");
reject_text($loop, 'tasklist /V /FI \"WINDOWTITLE eq %BOT_TITLE%\" /NH', "title-only BOT running test");
reject_text($loop, 'start \"%GAME_TITLE%\" /D \"%GAME_WORKDIR%\" /WAIT', "full-path /D game launch form");
reject_text($loop, 'start /B /WAIT \"%GAME_TITLE%\"', "hidden game launch");
reject_text($loop, 'start /WAIT /B \"%GAME_TITLE%\"', "hidden game launch");
reject_text($loop, 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! \"%GAME_EXECUTABLE%\"', "quoted relative executable launch form");
reject_text($loop, 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! \"%GAME_COMMAND%\"', "full game command used for launch");
reject_text($loop, 'start \"%GAME_TITLE%\" /D \"%GAME_WORKDIR%\" \"%GAME_COMMAND%\"', "detached game launch");
reject_text($loop, 'start \"%BOT_TITLE%\" /D \"%~dp0\" cmd.exe', "visible BOT supervisor launch");
reject_text($loop, 'start \"%BOT_TITLE%\" /D \"%ALSO_WORKDIR%\" /WAIT', "visible BEC launch");
reject_text($loop, '&gt;', "HTML-escaped greater-than token");
reject_regex($loop, qr/(?:^|[^A-Za-z])gt(?:[^A-Za-z]|\z)/, "plain gt comparison token");
require_text($loop, 'GTR 23', "valid hour GTR comparison");
require_text($loop, 'GTR 59', "valid minute/second GTR comparison");
reject_text($loop, '/%GAME_PRIORITY%', "runtime priority slash prefix");
reject_text($loop, '%TIME: =0%', "locale-sensitive TIME runtime clock");
reject_text($loop, '1%%B', "broken TIME minute arithmetic");
reject_text($loop, 'echo(!WMIC_TIMESTAMP! | findstr', "timestamp validation pipeline with trailing echoed space");

my $live_wmic_value = "20260728054737.569000-420\r\n";
my $live_seconds = batch_model_seconds_from_wmic_localdatetime($live_wmic_value);
defined($live_seconds) && $live_seconds == 20857
	or fail("live WMIC suffix/CRLF value did not normalize to seconds since midnight");
defined(batch_model_seconds_from_wmic_localdatetime("20260728054737"))
	or fail("exact 14-digit WMIC value was rejected");
!defined(batch_model_seconds_from_wmic_localdatetime(""))
	or fail("missing WMIC value was accepted");
!defined(batch_model_seconds_from_wmic_localdatetime("2026072805473"))
	or fail("short WMIC value was accepted");
!defined(batch_model_seconds_from_wmic_localdatetime("2026072805x737.569000-420\r\n"))
	or fail("nonnumeric WMIC timestamp was accepted");
!defined(batch_model_seconds_from_wmic_localdatetime("20260728246000.000000-420\r\n"))
	or fail("out-of-range WMIC timestamp was accepted");
batch_model_runtime_branch("20260728054737.569000-420\r\n", "20260728054751.999000-420\r\n") eq "rapid-exit"
	or fail("14-second runtime did not select rapid-exit branch");
batch_model_runtime_branch("20260728054737.569000-420\r\n", "20260728054752.000000-420\r\n") eq "restart"
	or fail("15-second runtime did not select restart branch");
batch_model_runtime_branch("20260728235958.000000-420\r\n", "20260729000010.000000-420\r\n") eq "rapid-exit"
	or fail("midnight rollover runtime branch was not preserved");
batch_model_runtime_branch("20260728235958.000000-420\r\n", "20260729000020.000000-420\r\n") eq "restart"
	or fail("midnight rollover restart branch was not preserved");
batch_model_runtime_branch("2026072805x737.569000-420\r\n", "20260728054752.000000-420\r\n") eq "clock-error"
	or fail("malformed WMIC timestamp did not select clock-error branch");

$source =~ /sub find_windows_cmd_pids_by_command_marker_without_decrypt\s*\{(.*?)\n\}\n\nsub command_marker_is_present_without_decrypt/s
	or fail("cannot locate command marker PID helper");
my $marker_lookup = $1;
require_text($marker_lookup, 'wmic process where "name=\'cmd.exe\'" get ProcessId,CommandLine /FORMAT:LIST', "agent-side WMIC cmd marker lookup");
require_text($marker_lookup, 'bot-supervisor', "agent-side marker filters bot supervisor");
require_text($marker_lookup, 'serverstart.bat', "agent-side marker filters generated BAT command line");

$source =~ /sub read_also_run_definition_without_decrypt\s*\{(.*?)\n\}\n\nsub also_run_option_identity_without_decrypt/s
	or fail("cannot locate _alsoRun definition parser");
my $also_parser = $1;
require_text($also_parser, 'Path::Class::File->new($home_path, "_alsorun.cmd")', "current _alsorun parser");
require_text($also_parser, 'Path::Class::File->new($home_path, "_alsoRun.cmd")', "legacy _alsoRun parser");
require_text($also_parser, '$definition{workdir}', "workdir parser output");
require_text($also_parser, '$definition{command}', "executable parser output");
require_text($also_parser, '$definition{options}', "arguments parser output");

$source =~ /sub find_windows_pids_for_also_run_without_decrypt\s*\{(.*?)\n\}\n\n# A port owner/s
	or fail("cannot locate _alsoRun process lookup");
my $also_lookup = $1;
require_text($also_lookup, 'wmic process get ProcessId,ExecutablePath,CommandLine /FORMAT:LIST', "agent-side WMIC BOT executable/command-line lookup");
require_text($also_lookup, 'process_text_matches_also_run_without_decrypt', "agent-side normalized BOT identity match");

$source =~ /sub kill_windows_command_marker_without_decrypt\s*\{(.*?)\n\}\n\nsub kill_also_run_processes_without_decrypt/s
	or fail("cannot locate command marker cleanup");
my $marker_kill = $1;
require_text($marker_kill, 'kill_windows_pid_with_escalation_without_decrypt($pid)', "agent-side BOT supervisor tree cleanup");

$source =~ /sub kill_also_run_processes_without_decrypt\s*\{(.*?)\n\}\n\nsub kill_home_pid_files_without_decrypt/s
	or fail("cannot locate _alsoRun process cleanup");
my $also_kill = $1;
require_text($also_kill, 'find_windows_pids_for_also_run_without_decrypt($home_path)', "agent-side direct BOT lookup before cleanup");
require_text($also_kill, 'kill_lifecycle_pid_without_decrypt($pid, $home_path, "_alsoRun.cmd BOT process", 0)', "agent-side direct BOT tree cleanup with home attribution");

$source =~ /sub universal_start_without_decrypt\s*\{(.*?)\n\}\n\n# Returns the number of CPUs available\./s
	or fail("cannot locate universal_start_without_decrypt body");
my $start = $1;
require_count($start, 'system($cli_bin);', 1, "one Start RPC screen/BAT launch");
require_order($start, 'Start requested for HOME ID:$home_id while screen', 'lifecycle_hard_stop_without_decrypt($home_id, $server_ip, $server_port, $management_home', "duplicate screen guard before preflight cleanup");
require_order($start, 'lifecycle_hard_stop_without_decrypt($home_id, $server_ip, $server_port, $management_home', 'create_screen_cmd_loop($screen_id, $management_home', "hard-stop preflight before watchdog generation");
require_order($start, 'Start generation skipped for HOME ID:$home_id because screen', 'create_screen_cmd_loop($screen_id, $management_home', "duplicate screen recheck before BAT generation");
require_order($start, 'Start launch skipped for HOME ID:$home_id because screen', 'set_desired_state_without_decrypt($management_home, "running")', "duplicate screen recheck before launch");
require_order($start, 'set_desired_state_without_decrypt($management_home, "running")', 'system($cli_bin);', "running marker before watchdog launch");
require_order($start, 'system($cli_bin);', 'wait_for_home_screen_survival_without_decrypt($home_id, 3)', "screen survival checked after the single launch");
require_text($start, 'tracked_pid => $watchdog_pid ne "" ? $watchdog_pid : $screen_pid', "screen PID fallback when watchdog title PID is unavailable");
reject_text($start, 'operation => "launch_failed"', "fatal title-based launch failure");

$source =~ /sub server_status_without_decrypt\s*\{(.*?)\n\}\n\n# Universal startup function/s
	or fail("cannot locate server_status_without_decrypt body");
my $server_status = $1;
require_text($server_status, 'my $session_running = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0', "status reads live named screen");
require_text($server_status, 'my $process_running = ($session_running || $pid_running) ? 1 : 0', "live screen contributes to running/starting status without watchdog title PID");

$source =~ /sub kill_lifecycle_port_owner_without_decrypt\s*\{(.*?)\n\}\n\nsub tracked_lifecycle_pids_without_decrypt/s
	or fail("cannot locate port owner cleanup");
my $port_cleanup = $1;
require_text($port_cleanup, 'Attempting forced stop for untracked $source PID $pid.', "assigned port cleanup kills non-System untracked owners");
require_text($port_cleanup, 'protected_port_owner', "assigned port cleanup still protects reserved/agent owners");

$source =~ /sub lifecycle_hard_stop_without_decrypt\s*\{(.*?)\n\}\n\nsub get_screen_pid_without_decrypt/s
	or fail("cannot locate lifecycle_hard_stop_without_decrypt body");
my $hard_stop = $1;
require_order($hard_stop, 'set_desired_state_without_decrypt($home_path, "stopped")', 'sleep 3 if($operation eq "stop" || $operation eq "force_stop")', "stopped marker before cleanup wait");
require_text($hard_stop, 'force_kill_tracked_and_port_without_decrypt($home_id, $server_port, $home_path)', "shared tracked and port cleanup");
require_text($hard_stop, 'kill_windows_command_marker_without_decrypt(windows_lifecycle_bot_marker_without_decrypt($home_path), "BOT supervisor marker")', "agent-side BOT supervisor marker cleanup");
require_text($hard_stop, 'kill_also_run_processes_without_decrypt($home_path)', "agent-side direct BOT identity cleanup");
require_text($hard_stop, 'kill_windows_window_title_without_decrypt(windows_lifecycle_title_without_decrypt($home_path, "bot"), "bot window title")', "title fallback cleanup");
require_text($hard_stop, 'system("screen -S " . create_screen_id', "screen cleanup after process tree cleanup");
require_text($hard_stop, 'verify_runtime_stop_complete_without_decrypt($home_id, $server_ip, $server_port, $home_path)', "shared verification");

$source =~ /sub verify_runtime_stop_complete_without_decrypt\s*\{(.*?)\n\}\n\nsub force_stop_server/s
	or fail("cannot locate verify_runtime_stop_complete_without_decrypt body");
my $verify = $1;
require_text($verify, 'collect_port_owners_without_decrypt($server_port, "any")', "TCP and UDP owner verification");
require_text($verify, 'command_marker_is_present_without_decrypt(windows_lifecycle_bot_marker_without_decrypt($home_path))', "BOT marker verification");
require_text($verify, 'find_windows_pids_for_also_run_without_decrypt($home_path)', "direct BOT process verification");
require_text($verify, 'window_title_is_present_without_decrypt(windows_lifecycle_title_without_decrypt($home_path, "bot"))', "BOT title fallback verification");

foreach my $fixture (
	{
		path => "$repo_root/tests/fixtures/windows-supervision/server-4-port-2000-serverStart.fixture.bat",
		port => 'set "GAME_PORT=2000"',
		workdir => 'set "GAME_WORKDIR=C:\ogp64\home\gameserver\4\arma2"',
		command => 'set "GAME_COMMAND=C:\ogp64\home\gameserver\4\arma2\arma2oaserver.exe"',
		executable => 'set "GAME_EXECUTABLE=arma2oaserver.exe"',
		mod => '@dayz;@hive',
		options => 'set "GAME_OPTIONS=-port=2000 -mod=@dayz;@hive -config=C:\ogp64\home\gameserver\4\arma2\server.cfg"',
		bot => 'C:\ogp64\home\gameserver\4\BEC\BEC.exe',
		description => 'server 4 DayZ/2000 fixture'
	},
	{
		path => "$repo_root/tests/fixtures/windows-supervision/server-6-port-2200-serverStart.fixture.bat",
		port => 'set "GAME_PORT=2200"',
		workdir => 'set "GAME_WORKDIR=C:\ogp64\home\gameserver\6\epoch"',
		command => 'set "GAME_COMMAND=C:\ogp64\home\gameserver\6\epoch\arma2oaserver.exe"',
		executable => 'set "GAME_EXECUTABLE=arma2oaserver.exe"',
		mod => '@dayz_epoch;@epochserver',
		options => 'set "GAME_OPTIONS=-port=2200 -mod=@dayz_epoch;@epochserver -config=C:\ogp64\home\gameserver\6\epoch\server.cfg"',
		bot => 'C:\ogp64\home\gameserver\6\BEC\BEC.exe',
		description => 'server 6 Epoch/2200 fixture'
	}
)
{
	open(my $fixture_fh, '<', $fixture->{path}) or fail("missing $fixture->{description}");
	my $fixture_text = do { local $/; <$fixture_fh> };
	close($fixture_fh);
	require_text($fixture_text, $fixture->{port}, "$fixture->{description} port");
	require_text($fixture_text, $fixture->{workdir}, "$fixture->{description} workdir");
	require_text($fixture_text, $fixture->{command}, "$fixture->{description} full command evidence");
	require_text($fixture_text, $fixture->{executable}, "$fixture->{description} relative executable");
	require_text($fixture_text, $fixture->{mod}, "$fixture->{description} mod arguments");
	require_text($fixture_text, $fixture->{options}, "$fixture->{description} exact options");
	require_text($fixture_text, $fixture->{bot}, "$fixture->{description} BEC path");
	require_text($fixture_text, 'set "GAME_PRIORITY=/normal"', "$fixture->{description} normalized priority switch");
	require_text($fixture_text, 'BOT_SUPERVISOR_MARKER=BOT_SUPERVISOR_%INSTANCE%', "$fixture->{description} BOT marker");
	require_text($fixture_text, 'if /I not "%~1"=="bot-supervisor" if exist "%STOP_FILE%" del "%STOP_FILE%"', "$fixture->{description} main-only stop marker removal");
	require_text($fixture_text, 'cd /d "%GAME_WORKDIR%"', "$fixture->{description} game workdir change");
	require_text($fixture_text, 'if defined GAME_PRIORITY set "GAME_START_FLAGS=!GAME_START_FLAGS! %GAME_PRIORITY%"', "$fixture->{description} priority switch append");
	require_text($fixture_text, 'start /WAIT "%GAME_TITLE%" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%', "$fixture->{description} blocking unquoted relative game launch");
	require_text($fixture_text, 'start "" /B /D "%~dp0" cmd.exe /V:ON /C ""%~f0" bot-supervisor "%BOT_SUPERVISOR_MARKER%""', "$fixture->{description} background BOT supervisor launch");
	require_text($fixture_text, 'start "" /B /D "%ALSO_WORKDIR%" /WAIT "%ALSO_COMMAND%" %ALSO_OPTIONS%', "$fixture->{description} blocking background BEC launch");
	require_text($fixture_text, 'set "ALSO_FILE=%~dp0_alsoRun.cmd"', "$fixture->{description} representative _alsoRun.cmd value");
	require_text($fixture_text, 'if errorlevel 1', "$fixture->{description} clock failure stop path");
	require_text($fixture_text, 'wmic os get LocalDateTime /value', "$fixture->{description} WMIC runtime clock source");
	require_text($fixture_text, 'set "WMIC_TIMESTAMP=!WMIC_LOCALDATETIME:~0,14!"', "$fixture->{description} WMIC timestamp suffix/control trimming");
	require_text($fixture_text, 'echo(!WMIC_TIMESTAMP!|findstr /R /C:"^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$" >nul || (', "$fixture->{description} no-space exact timestamp validation pipeline");
	require_text($fixture_text, '^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$', "$fixture->{description} exact 14-digit timestamp validation");
	require_text($fixture_text, 'set "WMIC_HOUR=!WMIC_TIMESTAMP:~8,2!"', "$fixture->{description} WMIC hour parsing from normalized timestamp");
	require_text($fixture_text, 'set /A "%~1=(WMIC_HOUR_NUM*3600)+(WMIC_MINUTE_NUM*60)+WMIC_SECOND_NUM"', "$fixture->{description} seconds since midnight assignment");
	require_text($fixture_text, 'if !RUNTIME_SECONDS! LSS 0 set /A RUNTIME_SECONDS+=86400', "$fixture->{description} midnight rollover");
	require_text($fixture_text, 'Unable to read WMIC LocalDateTime for lifecycle runtime calculation; stopping watchdog.', "$fixture->{description} missing WMIC lifecycle error");
	require_text($fixture_text, 'Invalid WMIC LocalDateTime', "$fixture->{description} invalid WMIC lifecycle error");
	require_text($fixture_text, 'if !RUNTIME_SECONDS! LSS 15', "$fixture->{description} rapid exit protection");
	require_text($fixture_text, 'ping -n 2 127.0.0.1 >nul', "$fixture->{description} ping wait");
	require_text($fixture_text, 'wmic process get ProcessId,ExecutablePath,CommandLine /FORMAT:LIST', "$fixture->{description} BOT process identity");
	reject_text($fixture_text, 'start "%GAME_TITLE%" /D "%GAME_WORKDIR%" /WAIT', "$fixture->{description} full-path /D launch form");
	reject_text($fixture_text, 'start /B /WAIT "%GAME_TITLE%"', "$fixture->{description} hidden game launch");
	reject_text($fixture_text, 'start /WAIT /B "%GAME_TITLE%"', "$fixture->{description} hidden game launch");
	reject_text($fixture_text, 'start /WAIT "%GAME_TITLE%" "%GAME_EXECUTABLE%"', "$fixture->{description} quoted relative executable launch form");
	reject_text($fixture_text, 'start /WAIT "%GAME_TITLE%" "%GAME_COMMAND%"', "$fixture->{description} full command launch");
	reject_text($fixture_text, 'start "%BOT_TITLE%" /D "%~dp0" cmd.exe', "$fixture->{description} visible BOT supervisor launch");
	reject_text($fixture_text, 'start "%BOT_TITLE%" /D "%ALSO_WORKDIR%" /WAIT', "$fixture->{description} visible BEC launch");
	reject_text($fixture_text, '&gt;', "$fixture->{description} HTML-escaped greater-than token");
	reject_regex($fixture_text, qr/(?:^|[^A-Za-z])gt(?:[^A-Za-z]|\z)/, "$fixture->{description} plain gt comparison token");
	require_text($fixture_text, 'GTR 23', "$fixture->{description} valid hour GTR comparison");
	require_text($fixture_text, 'GTR 59', "$fixture->{description} valid minute/second GTR comparison");
	reject_text($fixture_text, '//normal', "$fixture->{description} double-slash priority switch");
	reject_text($fixture_text, '%TIME: =0%', "$fixture->{description} locale-sensitive TIME runtime clock");
	reject_text($fixture_text, '1%%B', "$fixture->{description} broken TIME minute arithmetic");
	reject_text($fixture_text, 'echo(!WMIC_TIMESTAMP! | findstr', "$fixture->{description} timestamp validation pipeline with trailing echoed space");
	reject_text($fixture_text, 'timeout /T', "$fixture->{description} timeout dependency");
	reject_text($fixture_text, 'tasklist /V /FI "WINDOWTITLE eq %BOT_TITLE%"', "$fixture->{description} title-only BOT running test");
}

print "Windows OGP-style supervised watchdog lifecycle validation passed.\n";
PERL
