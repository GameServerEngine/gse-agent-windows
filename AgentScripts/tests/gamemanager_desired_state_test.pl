#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/..";
require GameManager;

sub manager {
    my ($root, $alive, $launches, $exists) = @_;
    return GameManager->new(
        state_dir => $root, dir_for => sub { "$root/$_[0]" }, now => sub { 1000 },
        pid_alive => sub { $alive->{$_[0]} ? 1 : 0 },
        port_listening => sub { 0 }, port_owner_pids => sub { () }, kill_pid => sub { 1 },
        launch => sub { push @$launches, $_[0]; $alive->{9000 + @$launches} = 1; return 9000 + @$launches },
        executable_exists => sub { $exists }, log => sub { }, miss_limit => 1,
    );
}

my $root = tempdir(CLEANUP => 1); make_path("$root/52");
my (%alive, @launches);
my $gm = manager($root, \%alive, \@launches, 1);
my $s = $gm->read_state('52'); $s->{command} = 'C:\\games\\server.exe'; $s->{workdir} = "$root/52"; $s->{port} = 2302; $s->{desired} = 'RUNNING'; $gm->write_state($s);
$gm->tick('52'); is(scalar @launches, 1, 'desired RUNNING with no process starts');

$gm->set_desired('52', 'STOPPED'); $alive{9001} = 1; $s = $gm->read_state('52'); $s->{pid} = 9001; $s->{state} = 'RUNNING'; $gm->write_state($s); $gm->tick('52');
is($gm->read_state('52')->{desired}, 'STOPPED', 'desired STOPPED persists'); is($gm->read_state('52')->{state}, 'STOPPED', 'desired STOPPED stops process');

my $missing = manager($root, {}, [], 0); $s = $missing->read_state('52'); $s->{command} = 'C:\\games\\Dzsalmodserver.exe'; $s->{port} = 2302; $s->{desired} = 'RUNNING'; $missing->write_state($s); $missing->tick('52');
is($missing->read_state('52')->{state}, 'FAILED', 'missing executable fails'); like($missing->read_state('52')->{reason}, qr/^executable missing: C:\\games\\Dzsalmodserver\.exe \(command: C:\\games\\Dzsalmodserver\.exe\)$/, 'missing executable reason names the path and the stored command');

my $limited = manager($root, {}, [], 1); $s = $limited->read_state('52'); $s->{desired} = 'RUNNING'; $s->{state} = 'RUNNING'; $s->{command} = 'C:\\games\\server.exe'; $s->{crashes} = join(',', 1..5); $limited->write_state($s); $limited->tick('52');
is($limited->read_state('52')->{state}, 'FAILED', 'restart limit fails'); is($limited->read_state('52')->{reason}, 'restart limit reached', 'restart limit reason recorded');

my $dead_root = tempdir(CLEANUP => 1); make_path("$dead_root/49");
my $dead_now = 2000; my %dead_alive = (4901 => 0);
my $dead = GameManager->new(
    state_dir => $dead_root, dir_for => sub { "$dead_root/$_[0]" }, now => sub { $dead_now },
    pid_alive => sub { $dead_alive{$_[0]} ? 1 : 0 },
    pid_executable_matches => sub { 1 }, port_listening => sub { 0 },
    executable_exists => sub { 1 }, launch => sub { 0 }, log => sub { }, miss_limit => 1,
);
my $dead_state = $dead->read_state('49');
$dead_state->{state} = 'RUNNING'; $dead_state->{desired} = 'RUNNING'; $dead_state->{pid} = 4901;
$dead_state->{command} = 'C:\\games\\server.exe'; $dead_state->{port} = 27015; $dead->write_state($dead_state);
my $old_updated = $dead->read_state('49')->{updated_at};
$dead_now = 2005; $dead->tick('49'); $dead_state = $dead->read_state('49');
is($dead_state->{state}, 'CRASHED', 'dead recorded PID becomes crashed');
is($dead_state->{reason}, 'process died', 'dead PID records process died');
is($dead_state->{process_running}, 0, 'dead PID writes process_running=0');
is($dead_state->{port_listening}, 0, 'tick writes port_listening=0');
is($dead_state->{updated_at}, 2005, 'tick rewrites updated_at when only observation changed');
isnt($dead_state->{updated_at}, $old_updated, 'state file timestamp changed');

# ---- Port, owner, PID, hang and retry rules (version 1.5.2) ----
# A small fake Windows host: which PIDs are alive, who listens on which port, and each PID's
# executable path. Killing a PID frees its port. The clock only moves when a test moves it.
my ($now, %up, %listener, %exe_path, @killed_pids, @launch_log, @log_lines, $next_launch, $launch_listens);
sub host_reset {
    $now = 5000; %up = (); %listener = (); %exe_path = (); @killed_pids = (); @launch_log = (); @log_lines = ();
    $next_launch = 7000; $launch_listens = 0;
}
sub host_manager {
    my ($dir, %extra) = @_;
    return GameManager->new(
        state_dir => $dir, dir_for => sub { "$dir/$_[0]" }, now => sub { $now },
        pid_alive => sub { $up{$_[0]} ? 1 : 0 },
        pid_executable_matches => sub { 1 },
        port_owner_pids => sub { my @p = grep { $listener{$_} == $_[0] } sort keys %listener; return @p },
        port_listening => sub { my $port = $_[0]; return (grep { $listener{$_} == $port } keys %listener) ? 1 : 0 },
        pid_path => sub { $exe_path{$_[0]} },
        kill_pid => sub { my $p = shift; push @killed_pids, $p; delete $up{$p}; delete $listener{$p}; 1 },
        launch => sub {
            my $pid = $next_launch++;
            push @launch_log, { command => $_[0], workdir => $_[1], pid => $pid };
            $up{$pid} = 1;
            # A game that listens at once: the launcher's child holds the port.
            if ($launch_listens) { $up{$pid + 500} = 1; $listener{$pid + 500} = $launch_listens; $exe_path{$pid + 500} = "$dir/50/gamefiles/server.exe"; }
            return $pid;
        },
        sleep => sub { }, executable_exists => sub { 1 }, log => sub { push @log_lines, $_[0] },
        miss_limit => 1, %extra,
    );
}
sub host_server {
    my ($dir, $port) = @_;
    my $m = host_manager($dir);
    return $m;
}
my $cmd = '"C:\\GSE\\home\\50\\gamefiles\\server.exe" -port=2302';

# Port 0 and a missing port are rejected, and nothing is launched.
host_reset(); my $r50 = tempdir(CLEANUP => 1); make_path("$r50/50");
my $m = host_manager($r50);
my $res = $m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 0);
is($res->{reason}, 'port not configured', 'port 0 is rejected');
is(scalar @launch_log, 0, 'port 0 does not launch');
is($m->read_state('50')->{state}, 'FAILED', 'port 0 leaves state FAILED');
$res = $m->start('50', command => $cmd, workdir => "$r50/50/gamefiles");
is($res->{reason}, 'port not configured', 'start with no port is rejected');
is(scalar @launch_log, 0, 'start with no port does not launch');
$m->tick('50');
is(scalar @launch_log, 0, 'a later check does not launch a server with no port');

# A port owner from another server's folder is not killed, and the start fails.
host_reset(); $r50 = tempdir(CLEANUP => 1); make_path("$r50/50", "$r50/51");
$up{4242} = 1; $listener{4242} = 2302; $exe_path{4242} = "$r50/51/gamefiles/server.exe";
$m = host_manager($r50);
$res = $m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
ok(!$res->{ok}, 'start fails when another server holds the port');
is($m->read_state('50')->{port}, 2302, 'the expected port is stored in the state');
is(scalar @launch_log, 0, 'no launch while another server holds the port');
ok(!(grep { $_ == 4242 } @killed_pids), 'the other server\'s process is not killed');
ok($up{4242}, 'the other server\'s process is still alive');
ok((grep { /port in use by server\.exe 4242, could not free/ } @log_lines), 'the port-in-use reason is logged');

# A port owner from this server's folder is killed, then the launch goes ahead.
host_reset(); $r50 = tempdir(CLEANUP => 1); make_path("$r50/50");
$up{4343} = 1; $listener{4343} = 2302; $exe_path{4343} = "$r50/50/gamefiles/server.exe";
$m = host_manager($r50);
$res = $m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
ok((grep { $_ == 4343 } @killed_pids), 'the owner from this server\'s folder is killed');
ok($res->{ok}, 'the launch proceeds once the port is free');
is(scalar @launch_log, 1, 'launched once');
ok((grep { /launching command=\[.*server\.exe.*\] exe=\[.*server\.exe\] workdir=\[.*gamefiles\] expected port=2302 killed=\[.*4343/ } @log_lines), 'the launch log has the command, exe, folder, port and killed PIDs');

# An unrelated process (not any server's) on the port is killed too.
host_reset(); $r50 = tempdir(CLEANUP => 1); make_path("$r50/50");
$up{4444} = 1; $listener{4444} = 2302; $exe_path{4444} = 'C:/Tools/stray.exe';
$m = host_manager($r50);
$res = $m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
ok((grep { $_ == 4444 } @killed_pids) && $res->{ok}, 'an unrelated port owner is killed and the launch proceeds');

# A game PID is saved, the launcher is kept separately, and the game is RUNNING when its owner holds the port.
host_reset(); $r50 = tempdir(CLEANUP => 1); make_path("$r50/50"); $launch_listens = 2302;
$m = host_manager($r50);
$m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
my $st = $m->read_state('50');
is($st->{launcher}, 7000, 'the launcher PID is kept');
is($m->tick('50'), 'RUNNING', 'port listening with the game as its owner is RUNNING');
$st = $m->read_state('50');
is($st->{pid}, 7500, 'the game PID (the port owner) is saved as pid');
isnt($st->{pid}, $st->{launcher}, 'pid is not the launcher');

# Stop kills the launcher, the game and the port owner and confirms the port is free.
@killed_pids = ();
my $stop = $m->stop('50');
ok((grep { $_ == 7000 } @killed_pids) && (grep { $_ == 7500 } @killed_pids), 'stop kills the launcher and the game');
is($m->read_state('50')->{state}, 'STOPPED', 'stop reports STOPPED once the port is free');

# Starting, not yet listening: STARTING. Still starting at 300 seconds: HUNG, then restarted.
host_reset(); $r50 = tempdir(CLEANUP => 1); make_path("$r50/50"); $launch_listens = 0;
$m = host_manager($r50);
$m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
$now += 299;
is($m->tick('50'), 'STARTING', 'not listening at 299 seconds is still STARTING');
is(scalar @launch_log, 1, 'no restart before the timeout');
$now += 1;
$m->tick('50');
ok((grep { /Server ID 50 HUNG/ } @log_lines), 'a game still STARTING at 300 seconds is marked HUNG');
ok((grep { /HUNG log tail/ } @log_lines) && (grep { /HUNG dialog text/ } @log_lines), 'the hang logs the log tail and dialog text');
ok((grep { $_ == 7000 } @killed_pids), 'the hung launcher tree is killed');
is(scalar @launch_log, 2, 'the hung game is restarted');
is($m->read_state('50')->{state}, 'STARTING', 'state is STARTING again after the restart');
is($m->read_state('50')->{attempts}, 1, 'one failed attempt is counted');

# The second failure gives FAILED with the exact reason, and nothing restarts after that.
$now += 300;
$m->tick('50');
$st = $m->read_state('50');
is($st->{state}, 'FAILED', 'the second failure sets FAILED');
is($st->{reason}, 'Failed to Start: max restarts reached', 'the failure reason is exact');
is(scalar @launch_log, 2, 'no third launch');
$now += 600; $m->tick('50');
is(scalar @launch_log, 2, 'FAILED stays failed on later checks');
is($m->read_state('50')->{attempts}, 2, 'the attempt counter is kept across checks');

# An explicit Start clears the attempt counter and tries again.
$m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
is($m->read_state('50')->{attempts}, 0, 'an explicit Start resets the attempt counter');
is(scalar @launch_log, 3, 'an explicit Start launches again');

# A per-server start_timeout overrides the 300 second default.
host_reset(); $r50 = tempdir(CLEANUP => 1); make_path("$r50/50");
$m = host_manager($r50);
$m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
$st = $m->read_state('50'); $st->{start_timeout} = 60; $m->write_state($st);
$now += 61; $m->tick('50');
is(scalar @launch_log, 2, 'start_timeout 60 hangs the game after 60 seconds');

# A port that cannot be freed fails both attempts and ends in FAILED, with no launch.
host_reset(); $r50 = tempdir(CLEANUP => 1); make_path("$r50/50", "$r50/51");
$up{4242} = 1; $listener{4242} = 2302; $exe_path{4242} = "$r50/51/gamefiles/server.exe";
$m = host_manager($r50);
$res = $m->start('50', command => $cmd, workdir => "$r50/50/gamefiles", port => 2302);
is($res->{reason}, 'Failed to Start: max restarts reached', 'two port failures end in FAILED');
is(scalar @launch_log, 0, 'never launched');
done_testing();
