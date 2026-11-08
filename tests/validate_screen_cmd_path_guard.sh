#!/usr/bin/env bash
set -euo pipefail

# Regression test for the empty-start-command bug: the Windows service is launched by
# cygrunsrv as a non-login bash (cygrunsrv -p /bin/bash -a agent_service_wrapper.sh),
# so /etc/profile never runs and PATH is whatever the Windows service environment
# provides, which does not include the install's own Cygwin bin directories. Every
# `cygpath` backtick call in gse_agent.pl silently returns "" in that environment,
# and create_screen_cmd_loop previously still returned a well-formed screen command
# built around that empty path: `cmd.exe /c ""`. This asserts the fix stays in place:
# (1) PATH is repaired at process start so cygpath/screen/wmic/tasklist resolve, and
# (2) create_screen_cmd_loop refuses to return a command if the batch path is still empty.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent_file="$repo_root/AgentScripts/gse_agent.pl"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$agent_file" ] || fail "missing AgentScripts/gse_agent.pl"

perl -Mstrict -Mwarnings - "$agent_file" <<'PERL' || exit 1
use strict;
use warnings;

my ($agent_file) = @ARGV;
open(my $fh, '<', $agent_file) or die "FAIL: cannot read $agent_file: $!\n";
my $source = do { local $/; <$fh> };
close($fh);

sub fail {
	my ($message) = @_;
	die "FAIL: $message\n";
}

sub require_text {
	my ($text, $needle, $description) = @_;
	index($text, $needle) >= 0 or fail("missing $description");
}

sub require_order {
	my ($text, $first, $second, $description) = @_;
	my $first_index = index($text, $first);
	my $second_index = index($text, $second);
	$first_index >= 0 or fail("missing first marker for $description");
	$second_index >= 0 or fail("missing second marker for $description");
	$first_index < $second_index or fail("wrong order for $description");
}

# (1) PATH repair must happen before any other code (including Cfg::Config load,
# which itself may shell out) runs, and must come from the install's own directory
# rather than assuming an inherited login-shell PATH.
require_order($source, 'use FindBin qw($Bin)', 'abs_path("$Bin/..")', "PATH repair uses FindBin-derived install root");
require_order($source, 'abs_path("$Bin/..")', 'use constant AGENT_RUN_DIR', "PATH repair runs before config/module loads that may shell out");
require_text($source, '$ENV{PATH} = join(":", @gsp_bin_dirs, ($ENV{PATH} || ""))', "PATH is prepended with the install's own bin directories, not replaced");

# (2) create_screen_cmd_loop must never return a non-empty screen command built on an
# empty Windows batch path; the empty-path check must run immediately after the
# cygpath call and before any other use of $server_start_batfile_windows.
$source =~ /sub create_screen_cmd_loop\s*\{(.*?)\n\}\n\nsub replace_GSP_Env_Vars/s
	or fail("cannot locate create_screen_cmd_loop body");
my $loop = $1;

require_text($loop, 'my $server_start_batfile_windows = clean(`cygpath -wa "$server_start_batfile"`);', "cygpath call for the watchdog batch path");
require_order($loop,
	'my $server_start_batfile_windows = clean(`cygpath -wa "$server_start_batfile"`);',
	'if($server_start_batfile_windows eq "")',
	"empty batch-path check follows the cygpath call");
require_order($loop, 'if($server_start_batfile_windows eq "")', 'return "";', "empty batch-path check returns before building any screen command");
require_order($loop,
	'if($server_start_batfile_windows eq "")',
	'my ($game_relative_executable, $game_relative_error) = windows_relative_game_executable_name_without_decrypt($game_file);',
	"empty batch-path check runs before any further command construction");

print "Screen command empty-batch-path guard and service PATH repair validation passed.\n";
PERL
