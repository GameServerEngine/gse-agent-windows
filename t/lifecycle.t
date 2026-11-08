use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../AgentScripts";
use ServerLifecycle;
use File::Temp qw(tempdir);
my $n = 0; my $fail = 0;
sub ok { my ($name, $cond) = @_; $n++; if ($cond) { print "ok $n - $name\n" } else { $fail++; print "not ok $n - $name\n" } }
sub st { my ($s, %x) = @_; my ($next, $act, $why) = ServerLifecycle::decide({ state => $s, %x }); return ($next, $act); }

my ($a1,$b1) = st('STARTING', pid_alive => 1, port_owned_by_pid => 1, age => 10);
ok('STARTING with pid and port -> RUNNING', $a1 eq 'RUNNING' && $b1 eq 'none');
($a1,$b1) = st('STARTING', pid_alive => 1, port_owned_by_pid => 0, age => 10);
ok('STARTING with pid alive but no port yet stays STARTING', $a1 eq 'STARTING' && $b1 eq 'none');
($a1,$b1) = st('STARTING', pid_alive => 0, port_owned_by_pid => 0, age => 10);
ok('STARTING with dead pid -> CRASHED', $a1 eq 'CRASHED' && $b1 eq 'crash');
($a1,$b1) = st('STARTING', pid_alive => 1, port_owned_by_pid => 0, age => 999);
ok('STARTING past timeout -> CRASHED', $a1 eq 'CRASHED' && $b1 eq 'crash');
($a1,$b1) = st('RUNNING', pid_alive => 1, port_owned_by_pid => 1);
ok('RUNNING healthy stays RUNNING', $a1 eq 'RUNNING' && $b1 eq 'none');
($a1,$b1) = st('RUNNING', pid_alive => 0, port_owned_by_pid => 0);
ok('RUNNING with dead pid -> CRASHED', $a1 eq 'CRASHED' && $b1 eq 'crash');
($a1,$b1) = st('RUNNING', pid_alive => 1, port_owned_by_pid => 0);
ok('RUNNING with port closed -> CRASHED', $a1 eq 'CRASHED' && $b1 eq 'crash');
($a1,$b1) = st('CRASHED', now => 5000, crash_times => []);
ok('CRASHED with no history -> restart', $a1 eq 'STARTING' && $b1 eq 'restart');
my @five = map { 5000 - $_ } (10,20,30,40,50);
($a1,$b1) = st('CRASHED', now => 5000, crash_times => \@five);
ok('CRASHED at restart limit stays CRASHED', $a1 eq 'CRASHED' && $b1 eq 'none');
my @old = map { 90000 - 7200 - $_ } (10,20,30,40,50);
($a1,$b1) = st('CRASHED', now => 90000, crash_times => \@old);
ok('old crashes outside window do not block restart', $a1 eq 'STARTING' && $b1 eq 'restart');
($a1,$b1) = st('STOPPED', pid_alive => 1);
ok('STOPPED with live pid -> kill', $a1 eq 'STOPPED' && $b1 eq 'kill');
($a1,$b1) = st('STOPPED', pid_alive => 0);
ok('STOPPED with no pid -> nothing', $a1 eq 'STOPPED' && $b1 eq 'none');

my $dir = tempdir(CLEANUP => 1); my $f = "$dir/status-49";
my $w = { state => 'RUNNING', pid => 4242, bot_pid => 4343, restarts => 2, crash_times => [100,200], start_ts => 77, reason => 'ok' };
ServerLifecycle::write_status($f, $w);
my $r = ServerLifecycle::read_status($f);
ok('status round-trip keeps state', $r->{state} eq 'RUNNING');
ok('status round-trip keeps pid and bot pid', $r->{pid} == 4242 && $r->{bot_pid} == 4343);
ok('status round-trip keeps restarts and crash times', $r->{restarts} == 2 && scalar(@{$r->{crash_times}}) == 2);
ok('status file second field is the state (panel compatibility)', (split /,/, do { open my $h,'<',$f; scalar <$h> })[1] eq 'RUNNING');
my $none = ServerLifecycle::read_status("$dir/missing");
ok('missing status file reads as STOPPED', $none->{state} eq 'STOPPED');

print "\n$n tests, $fail failed\n";
exit($fail ? 1 : 0);
