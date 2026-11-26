#!/usr/bin/env bash
# Checks that get_log refuses customer-controlled symlinks and paths outside the server folder,
# and never runs tail through the shell unquoted.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent_file="$repo_root/AgentScripts/agent_core.pl"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq '`tail -n $nb_of_lines $log_file`' "$agent_file" && fail "get_log still runs tail through the shell unquoted"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/gamefiles/logs" "$tmp/screenlogs" "$tmp/outside"
echo ok > "$tmp/home/gamefiles/logs/latest.log"
echo secret > "$tmp/outside/secret"
ln -s "$tmp/outside/secret" "$tmp/home/gamefiles/logs/link.log"
ln -s "$tmp/outside" "$tmp/home/gamefiles/dirlink"

sub_src="$(perl -0ne 'print $1 if /(sub log_file_is_safe_without_decrypt\n\{.*?\n\}\n)/s' "$agent_file")"
[ -n "$sub_src" ] || fail "log_file_is_safe_without_decrypt not found"

SUB_SRC="$sub_src" TMP="$tmp" perl -e '
use strict; use warnings; use Cwd ();
use constant SCREEN_LOGS_DIR => "$ENV{TMP}/screenlogs";
eval $ENV{SUB_SRC}; die $@ if $@;
my $h = "$ENV{TMP}/home";
my @cases = (
	["$h/gamefiles/logs/latest.log", 1],
	["$h/gamefiles/logs/link.log", 0],
	["$h/gamefiles/dirlink/secret", 0],
	["$ENV{TMP}/outside/secret", 0],
	["$h/gamefiles/logs/missing.log", 0],
);
for my $c (@cases) {
	my ($ok) = log_file_is_safe_without_decrypt($c->[0], $h);
	die "FAIL: $c->[0] expected $c->[1] got $ok\n" unless $ok == $c->[1];
}
'
echo "Log read safety validation passed."
