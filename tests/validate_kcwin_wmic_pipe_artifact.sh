#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline_file="$repo_root/.devplus/kcwin-wmic-trim-fix/gsp_agent.fixed.pl"
fixed_file="$repo_root/.devplus/kcwin-wmic-pipe-fix/gsp_agent.fixed.pl"
expected_baseline_hash="62c87377e57c487ab184ed5032c4513baaa5537928efe636231d0e53d6bccd0d"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$baseline_file" ] || fail "missing immutable kcwin WMIC trim baseline"
[ -f "$fixed_file" ] || fail "missing kcwin WMIC pipe fix artifact"

actual_baseline_hash="$(sha256sum "$baseline_file" | awk '{print $1}')"
[ "$actual_baseline_hash" = "$expected_baseline_hash" ] \
    || fail "baseline hash mismatch: expected $expected_baseline_hash, found $actual_baseline_hash"

perl -Mstrict -Mwarnings - "$baseline_file" "$fixed_file" <<'PERL' || exit 1
use strict;
use warnings;

my ($baseline_file, $fixed_file) = @ARGV;

sub read_file {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "FAIL: cannot read $path: $!\n";
	my $text = do { local $/; <$fh> };
	close($fh);
	return $text;
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

sub batch_model_runtime_branch {
	my ($start_raw, $end_raw) = @_;
	my $start_seconds = batch_model_seconds_from_wmic_localdatetime($start_raw);
	my $end_seconds = batch_model_seconds_from_wmic_localdatetime($end_raw);
	return "clock-error" unless(defined($start_seconds) && defined($end_seconds));
	my $runtime_seconds = $end_seconds - $start_seconds;
	$runtime_seconds += 86400 if($runtime_seconds < 0);
	return $runtime_seconds < 15 ? "rapid-exit" : "restart";
}

my $baseline = read_file($baseline_file);
my $fixed = read_file($fixed_file);

my $spaced_pipeline = q{echo(!WMIC_TIMESTAMP! | findstr /R /C:\"^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\$\" >nul || (};
my $no_space_pipeline = q{echo(!WMIC_TIMESTAMP!|findstr /R /C:\"^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\$\" >nul || (};

require_text($baseline, $spaced_pipeline, "known baseline spaced timestamp pipeline");
require_text($fixed, $no_space_pipeline, "fixed no-space timestamp pipeline");
reject_text($fixed, $spaced_pipeline, "spaced timestamp pipeline in fixed artifact");

$fixed =~ /sub create_screen_cmd_loop\s*\{(.*?)\n\}\n\nsub replace_GSP_Env_Vars/s
	or fail("cannot locate production create_screen_cmd_loop body");
my $loop = $1;

require_text($loop, 'set \"WMIC_TIMESTAMP=!WMIC_LOCALDATETIME:~0,14!\"', "trimmed WMIC timestamp variable");
require_text($loop, $no_space_pipeline, "no-space validation of trimmed WMIC timestamp");
require_text($loop, 'set \"WMIC_HOUR=!WMIC_TIMESTAMP:~8,2!\"', "hour parsing from trimmed timestamp");
require_text($loop, 'set \"WMIC_MINUTE=!WMIC_TIMESTAMP:~10,2!\"', "minute parsing from trimmed timestamp");
require_text($loop, 'set \"WMIC_SECOND=!WMIC_TIMESTAMP:~12,2!\"', "second parsing from trimmed timestamp");
require_text($loop, 'set /A WMIC_HOUR_NUM=1!WMIC_HOUR!-100', "leading-zero-safe hour arithmetic");
require_text($loop, 'set /A WMIC_MINUTE_NUM=1!WMIC_MINUTE!-100', "leading-zero-safe minute arithmetic");
require_text($loop, 'set /A WMIC_SECOND_NUM=1!WMIC_SECOND!-100', "leading-zero-safe second arithmetic");
require_text($loop, 'set /A \"%~1=(WMIC_HOUR_NUM*3600)+(WMIC_MINUTE_NUM*60)+WMIC_SECOND_NUM\"', "seconds since midnight assignment");
require_text($loop, 'if !RUNTIME_SECONDS! LSS 0 set /A RUNTIME_SECONDS+=86400', "midnight rollover");
require_text($loop, 'set \"GSE_GAME_PRIORITY=$batch_priority_switch\"', "normalized priority variable");
require_text($loop, 'if defined GSE_GAME_PRIORITY set \"GAME_START_FLAGS=!GAME_START_FLAGS! %GSE_GAME_PRIORITY%\"', "priority appended as complete START switch");
require_text($loop, 'set \"GAME_EXECUTABLE=$batch_game_relative_executable\"', "safe relative executable assignment");
require_text($loop, 'cd /d \"%GAME_WORKDIR%\"', "workdir change before launch");
require_text($loop, 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%', "blocking relative game launch");
require_text($loop, 'if exist \"%STOP_FILE%\" goto SHUTDOWN', "stop marker guard");
require_text($loop, 'type nul > \"%STOP_FILE%\"', "rapid-exit stop marker write");
require_text($loop, 'if !RUNTIME_SECONDS! LSS 15', "rapid-exit protection");
require_text($loop, 'if exist \"%~dp0_alsorun.cmd\" set \"ALSO_FILE=%~dp0_alsorun.cmd\"', "current BOT definition input");
require_text($loop, 'set \"BOT_SUPERVISOR_MARKER=GSE_BOT_SUPERVISOR_%INSTANCE%\"', "per-instance BOT marker");
require_text($loop, 'wmic process get ProcessId^,ExecutablePath^,CommandLine /FORMAT:LIST', "BOT process identity through WMIC");
require_text($loop, 'taskkill /F /T /PID !BOT_SUPERVISOR_PID!', "BOT supervisor cleanup");
require_text($loop, 'netstat -ano ^| findstr /R /C:\"^[ ][ ]*TCP\" /C:\"^[ ][ ]*UDP\"', "TCP and UDP cleanup scan");
require_text($loop, 'taskkill /F /T /PID !PORT_PID!', "assigned port owner cleanup");
require_text($loop, 'cmd.exe /c "%2$s"', "direct screen-owned serverStart.bat launch");
require_order($loop, 'call :SECONDS_NOW START_SECONDS', 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%', "timestamp before blocking game launch");
require_order($loop, 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%', 'call :SECONDS_NOW END_SECONDS', "timestamp after blocking game launch");
require_order($loop, 'call :SECONDS_NOW END_SECONDS', 'if !RUNTIME_SECONDS! LSS 15', "rapid-exit check after runtime calculation");

reject_text($loop, 'echo(!WMIC_TIMESTAMP! | findstr', "timestamp pipeline with echoed trailing space");
reject_text($loop, 'powershell.exe', "PowerShell in generated BAT");
reject_text($loop, 'Start-Process', "PowerShell process launcher in generated BAT");
reject_text($loop, 'watchdog.pid', "BAT-created watchdog PID file");
reject_text($loop, 'game.pid', "BAT-created game PID file");
reject_text($loop, 'bot.pid', "BAT-created bot PID file");
reject_text($loop, '_serverStartPid.ps1', "generated PowerShell PID helper");
reject_text($loop, 'start \"%GAME_TITLE%\" /D \"%GAME_WORKDIR%\" /WAIT', "full-path /D launch form");
reject_text($loop, 'start /WAIT \"%GAME_TITLE%\" !GAME_START_FLAGS! \"%GAME_EXECUTABLE%\"', "quoted relative executable launch form");
reject_text($loop, '/%GSE_GAME_PRIORITY%', "runtime priority slash prefix");
reject_text($loop, '%TIME: =0%', "locale-sensitive TIME runtime clock");
reject_text($loop, 'timeout /T', "interactive timeout wait");

batch_model_seconds_from_wmic_localdatetime("20260728061837.000000-420\r\n") == 22717
	or fail("live probe timestamp did not normalize to seconds since midnight");
defined(batch_model_seconds_from_wmic_localdatetime("20260728061837"))
	or fail("valid 14-digit WMIC timestamp was rejected");
!defined(batch_model_seconds_from_wmic_localdatetime("2026072806183"))
	or fail("short WMIC timestamp was accepted");
!defined(batch_model_seconds_from_wmic_localdatetime("2026072806x837.000000-420\r\n"))
	or fail("malformed WMIC timestamp was accepted");
batch_model_runtime_branch("20260728235958.000000-420\r\n", "20260729000020.000000-420\r\n") eq "restart"
	or fail("midnight rollover restart branch was not preserved");
batch_model_runtime_branch("20260728061837.000000-420\r\n", "20260728061851.000000-420\r\n") eq "rapid-exit"
	or fail("rapid-exit branch was not preserved");

print "kcwin WMIC pipe production artifact validation passed.\n";
PERL

fixed_hash="$(sha256sum "$fixed_file" | awk '{print $1}')"
echo "kcwin WMIC pipe artifact hash: $fixed_hash"
