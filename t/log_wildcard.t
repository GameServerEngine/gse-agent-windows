#!/usr/bin/perl
# Tests resolve_latest_log_match from agent_core.pl (subs are extracted, the script is not run).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Glob qw(bsd_glob GLOB_NOSORT GLOB_NOCASE GLOB_QUOTE);
use Cwd qw(abs_path);
use FindBin;

open(my $fh, '<', "$FindBin::Bin/../AgentScripts/agent_core.pl") or die $!;
my $src = do { local $/; <$fh> };
my $code = '';
for my $name (qw(log_path_has_wildcards wildcard_pattern_to_regex resolve_latest_log_match)) {
	$src =~ /^(sub \Q$name\E\n\{.*?^\})/ms or die "sub $name not found";
	$code .= $1 . "\n";
}
eval $code; die $@ if $@;

my $home = abs_path(tempdir(CLEANUP => 1));
make_path("$home/profile", "$home/cfg");
sub touch { my ($f, $t) = @_; open(my $o, '>', "$home/$f") or die; print $o "x\n"; close $o; utime($t, $t, "$home/$f"); }
touch('cfg/arma2oaserver.RPT', 1000);
touch('profile/DayZServer_x64_1.RPT', 1000);
touch('profile/DayZServer_x64_2.RPT', 2000);
touch('profile/DayZServer_x64_3.rpt', 1500);
touch('profile/other.log', 9000);

is(log_path_has_wildcards('cfg/arma2oaserver.RPT'), 0, 'exact path has no wildcards');
is(log_path_has_wildcards('profile/*.RPT'), 1, '* detected');

is(resolve_latest_log_match($home, 'cfg/arma2oaserver.RPT'), "$home/cfg/arma2oaserver.RPT", 'exact path');
is(resolve_latest_log_match($home, 'profile/DayZServer_x64_*.RPT'), "$home/profile/DayZServer_x64_2.RPT", 'newest of several');
is(resolve_latest_log_match($home, 'profile\\DayZServer_x64_?.RPT'), "$home/profile/DayZServer_x64_2.RPT", 'backslash and ?');
is(resolve_latest_log_match($home, 'profile/*.rpt'), "$home/profile/DayZServer_x64_2.RPT", 'case-insensitive');
touch('profile/DayZServer_x64_4.RPT', 2000);
is(resolve_latest_log_match($home, 'profile/*.RPT'), "$home/profile/DayZServer_x64_4.RPT", 'tie: lexically last');
is(resolve_latest_log_match($home, 'profile/*.nomatch'), undef, 'no match');
is(resolve_latest_log_match($home, '../*.RPT'), undef, '.. escape rejected');
is(resolve_latest_log_match($home, 'profile/../../*'), undef, 'nested .. rejected');
is(resolve_latest_log_match($home, '/etc/*'), undef, 'absolute rejected');
is(resolve_latest_log_match($home, 'C:/Windows/*'), undef, 'drive path rejected');

my $out = tempdir(CLEANUP => 1);
open(my $o, '>', "$out/secret.RPT") or die; close $o;
if (symlink($out, "$home/link")) {
	is(resolve_latest_log_match($home, 'link/*.RPT'), undef, 'symlink escape not followed');
}
done_testing;
