#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../AgentScripts";
use GameManager;
use File::Spec;

# Fake world: which PIDs are alive, which ports are open, who owns a port, and the clock.
my ($world, $next_pid, @launched);
sub new_world { $world = { now => 1000, alive => {}, port => {}, owners => {}, killed => [] }; $next_pid = 100; @launched = (); }
sub make_gm {
	my (%o) = @_;
	return GameManager->new(
		state_dir      => $o{dir},
		now            => sub { $world->{now} },
		pid_alive      => sub { $world->{alive}{$_[0]} ? 1 : 0 },
		port_listening => sub { $world->{port}{$_[0]} ? 1 : 0 },
		port_owner_pids => sub { @{ $world->{owners}{$_[0]} || [] } },
		kill_pid       => sub {
			my $p = shift; delete $world->{alive}{$p}; push @{$world->{killed}}, $p;
			# Killing a port owner frees the port, as it does on Windows.
			for my $port (keys %{ $world->{owners} }) {
				$world->{owners}{$port} = [ grep { $_ != $p } @{ $world->{owners}{$port} } ];
				$world->{port}{$port} = 0 unless @{ $world->{owners}{$port} };
			}
			1;
		},
		launch         => sub { my $pid = $next_pid++; $world->{alive}{$pid} = 1; push @launched, $pid; return $pid },
		log            => sub { },
		startup_timeout => 180,
		restart_limit   => $o{limit} // 5,
		restart_window  => 1800,
	);
}
sub state { my ($gm,$id)=@_; return $gm->read_state($id)->{state}; }

my $dir = tempdir(CLEANUP => 1);

# 1. Start: STARTING, PID recorded, launched once.
new_world();
my $gm = make_gm(dir => $dir);
my $r = $gm->start(49, command => 'arma2oaserver.exe -port=2302', workdir => 'C:/game', port => 2302);
ok($r->{ok}, 'start succeeds on a fresh server');
is(state($gm,49), 'STARTING', 'start writes STARTING, not RUNNING');
ok(scalar(@launched) == 1, 'start launches the game once');

# 2. PID alive but port not answering yet: stays STARTING.
$gm->tick(49);
is(state($gm,49), 'STARTING', 'PID alive, port closed -> STARTING');

# 3. PID and port both alive: RUNNING.
$world->{port}{2302} = 1;
$gm->tick(49);
is(state($gm,49), 'RUNNING', 'PID and port alive -> RUNNING');

# 4. Start refused while the server is really up.
$r = $gm->start(49, port => 2302);
ok(!$r->{ok}, 'start refused when already running');
is($r->{reason}, 'already running', 'refusal reason is given');

# 5. PID dies while RUNNING: CRASHED, leftovers killed, auto-restarted to STARTING.
$world->{alive}{ $gm->read_state(49)->{pid} } = 0; delete $world->{alive}{ $gm->read_state(49)->{pid} };
$gm->tick(49);
is(state($gm,49), 'STARTING', 'PID dead -> crashed, then auto-restarted to STARTING');
ok(scalar(@launched) == 2, 'auto-restart launched a new process');
ok(scalar(split(/,/, $gm->read_state(49)->{crashes})) == 1, 'crash is counted in the status file');

# 6. Port closes while RUNNING (PID alive): CRASHED and the port owner is killed.
$world->{port}{2302} = 1; $gm->tick(49);
$world->{owners}{2302} = [ 777 ]; $world->{alive}{777} = 1;
$world->{port}{2302} = 0;
$gm->tick(49);
ok((grep { $_ == 777 } @{$world->{killed}}), 'port owner (zombie) is killed on crash');

# 7. Startup timeout: PID alive, port never answers -> CRASHED.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$gm->start(50, command => 'x', workdir => 'd', port => 2312);
$world->{now} += 200;
$gm->tick(50);
isnt(state($gm,50), 'RUNNING', 'startup timeout never reaches RUNNING');
ok(scalar(@launched) >= 2, 'timeout crash triggers a restart (not a silent stop)');

# 8. Restart limit: too many crashes in the window stays CRASHED.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir, limit => 2);
$gm->start(51, command => 'x', workdir => 'd', port => 2322);
for my $i (1..4) {
	my $pid = $gm->read_state(51)->{pid};
	delete $world->{alive}{$pid};
	$gm->tick(51);
	$world->{now} += 10;
}
is(state($gm,51), 'CRASHED', 'restart limit reached -> stays CRASHED');
is($gm->read_state(51)->{reason}, 'restart limit reached', 'limit reason recorded');

# 9. Stop: STOPPED written, PID and port owner killed, port closed.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$gm->start(52, command => 'x', workdir => 'd', port => 2332);
$world->{port}{2332} = 1; $gm->tick(52);
$world->{owners}{2332} = [ 888 ]; $world->{alive}{888} = 1;
my $s = $gm->stop(52);
is(state($gm,52), 'STOPPED', 'stop writes STOPPED');
ok($s->{ok}, 'stop reports the port closed');
ok((grep { $_ == 888 } @{$world->{killed}}), 'stop kills the port owner');

# 10. Stop with nothing running succeeds.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$s = $gm->stop(53);
ok($s->{ok}, 'stop succeeds when nothing is running');

# 11. Stale PID is not trusted: a recorded PID that is not alive does not block start.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$gm->start(54, command => 'x', workdir => 'd', port => 2342);
$world->{port}{2342} = 1; $gm->tick(54);
delete $world->{alive}{ $gm->read_state(54)->{pid} };
$r = $gm->start(54, port => 2342);
ok($r->{ok}, 'stale recorded PID does not block a start');

# 12. Start frees a zombie holding the assigned port instead of refusing.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$world->{owners}{2352} = [ 999 ]; $world->{alive}{999} = 1; $world->{port}{2352} = 1;
$r = $gm->start(55, command => 'x', workdir => 'd', port => 2352);
ok($r->{ok}, 'start proceeds when a zombie owns the port');
ok((grep { $_ == 999 } @{$world->{killed}}), 'zombie on the assigned port is killed before launch');

# 13. Bot is killed when the game is STOPPED.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$gm->start(56, command => 'x', workdir => 'd', port => 2362);
$gm->write_state({ id => '56-bot', ts => 1000, state => 'RUNNING', pid => 4242, port => 0, crashes => '', reason => '', command => '', workdir => '' });
$world->{alive}{4242} = 1;
$gm->stop(56);
$gm->tick_bot(56);
ok((grep { $_ == 4242 } @{$world->{killed}}), 'bot is killed when the game is STOPPED');

# 14. Status file keeps the "<epoch>,<STATE>" first line the panel reads.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$gm->start(57, command => 'x', workdir => 'd', port => 2372);
open(my $fh, '<', "$dir/status-57") or die; my $first = <$fh>; close $fh;
like($first, qr/^\d+,STARTING$/, 'first line is "<epoch>,<STATE>"');


# 15. Bot config is read from _alsoRun.cmd.
my $cfgfile = File::Spec->catfile($dir, '_alsoRun.cmd');
open(my $cf, '>', $cfgfile) or die; print $cf "workdir=gamefiles\\bec\r\nexecutable=bec.exe\r\narguments=--dsc --dec -f config.cfg\r\n"; close $cf;
my $bc = GameManager::read_bot_config($cfgfile);
like($bc->{executable}, qr/cmd\.exe$/i, 'bot runs through cmd.exe');
like($bc->{arguments}, qr{/c \"}, 'bot config: runs the batch file');
ok(!defined GameManager::read_bot_config(File::Spec->catfile($dir, 'missing.cmd')), 'no bot config means no bot');

# 16. Bot starts when the game is RUNNING, and is not started twice.
new_world(); $dir = tempdir(CLEANUP => 1); $gm = make_gm(dir => $dir);
$gm->start(58, command => 'x', workdir => 'd', port => 2382);
$world->{port}{2382} = 1; $gm->tick(58);
my $n0 = scalar(@launched);
$gm->ensure_bot(58, $bc, 'C:\\home');
ok(scalar(@launched) == $n0 + 1, 'bot launches when the game is RUNNING');
$gm->ensure_bot(58, $bc, 'C:\\home');
ok(scalar(@launched) == $n0 + 1, 'bot is not launched twice');

# 17. Bot is stopped when the game is not RUNNING.
$gm->stop(58);
$gm->ensure_bot(58, $bc, 'C:\\home');
is($gm->read_state('58-bot')->{state}, 'STOPPED', 'bot stops when the game is stopped');


# 18. State lives in the game folder when dir_for is given.
new_world(); my $gdir = tempdir(CLEANUP => 1); my $gm2 = GameManager->new(state_dir => $gdir, dir_for => sub { $gdir }, now => sub { $world->{now} }, pid_alive => sub { $world->{alive}{$_[0]} ? 1 : 0 }, port_listening => sub { $world->{port}{$_[0]} ? 1 : 0 }, port_owner_pids => sub { () }, kill_pid => sub { 1 }, launch => sub { 555 }, log => sub { });
$gm2->start(59, command => 'x', workdir => $gdir, port => 2392);
ok(-e File::Spec->catfile($gdir, 'status'), 'status file is in the game folder');
ok(-e File::Spec->catfile($gdir, 'serverStart.bat'), 'serverStart.bat is written to the game folder');


# 19. A bot's state lives in its server folder as bot-status (not in a folder named after the bot).
new_world(); my $bdir = tempdir(CLEANUP => 1); my $gm3 = GameManager->new(state_dir => $bdir, dir_for => sub { $bdir }, now => sub { $world->{now} }, pid_alive => sub { 0 }, port_listening => sub { 0 }, port_owner_pids => sub { () }, kill_pid => sub { 1 }, launch => sub { 777 }, log => sub { });
$gm3->write_state({ id => '60-bot', ts => 1000, state => 'STOPPED', pid => 0, port => 0, crashes => '', reason => '', command => '', workdir => '' });
ok(-e File::Spec->catfile($bdir, 'bot-status'), 'bot state is bot-status in the server folder');
ok(!-e File::Spec->catfile($bdir, 'status-60-bot'), 'no separate bot folder or file for the bot');


# 20. Log lines: one per real state change, in capitals, as "Server ID 49 RUNNING".
new_world(); my $ldir = tempdir(CLEANUP => 1); my @lines;
my $gl = GameManager->new(state_dir => $ldir, dir_for => sub { $ldir }, now => sub { $world->{now} }, pid_alive => sub { $world->{alive}{$_[0]} ? 1 : 0 }, port_listening => sub { $world->{port}{$_[0]} ? 1 : 0 }, port_owner_pids => sub { () }, kill_pid => sub { 1 }, launch => sub { 4242 }, log => sub { push @lines, $_[0] });
$gl->start(49, command => 'x', workdir => $ldir, port => 2302);
$world->{alive}{4242} = 1; $world->{port}{2302} = 1;
$gl->tick(49); $gl->tick(49);
is_deeply(\@lines, ['Server ID 49 STARTING', 'Server ID 49 RUNNING'], 'log has one line per state change, in capitals');


# 21. Bot: starts with the game, goes RUNNING on PID alone (no port), never checks a port.
new_world(); my $bd2 = tempdir(CLEANUP => 1); my $portcalls = 0; my @blines;
my $gb = GameManager->new(state_dir => $bd2, dir_for => sub { $bd2 }, now => sub { $world->{now} }, pid_alive => sub { $world->{alive}{$_[0]} ? 1 : 0 }, port_listening => sub { $portcalls++; 0 }, port_owner_pids => sub { () }, kill_pid => sub { my $p = shift; delete $world->{alive}{$p}; 1 }, launch => sub { my $pid = $next_pid++; $world->{alive}{$pid} = 1; $pid }, log => sub { push @blines, $_[0] }, restart_limit => 2, restart_window => 1800);
$gb->write_state({ id => '70', ts => 1000, state => 'RUNNING', pid => 1, port => 2302, crashes => '', reason => '', command => 'x', workdir => $bd2 });
my $bcfg = { workdir => $bd2, executable => 'cmd.exe', arguments => '/c x.cmd' };
$gb->ensure_bot(70, $bcfg, $bd2);
is($gb->read_state('70-bot')->{state}, 'STARTING', 'bot starts when the game is RUNNING');
$gb->ensure_bot(70, $bcfg, $bd2);
is($gb->read_state('70-bot')->{state}, 'RUNNING', 'bot is RUNNING on PID alone');
is($portcalls, 0, 'bot never checks a port');

# 22. Bot crash while the game is RUNNING: CRASHED, then restarted, and reported.
my $bpid = $gb->read_state('70-bot')->{pid}; delete $world->{alive}{$bpid};
$gb->ensure_bot(70, $bcfg, $bd2);
ok((grep { /Bot for server ID 70 CRASHED/ } @blines), 'bot crash is reported');
is($gb->read_state('70-bot')->{state}, 'STARTING', 'bot is restarted after a crash');
ok((grep { /Bot for server ID 70 STARTING/ } @blines), 'bot restart is reported');

# 23. Restart limit for the bot: stays CRASHED.
for (1..4) { my $p = $gb->read_state('70-bot')->{pid}; delete $world->{alive}{$p}; $gb->ensure_bot(70, $bcfg, $bd2); }
is($gb->read_state('70-bot')->{state}, 'CRASHED', 'bot stays CRASHED at the restart limit');

# 24. Game stopped: bot is stopped.
$gb->write_state({ id => '70', ts => 1000, state => 'STOPPED', pid => 0, port => 2302, crashes => '', reason => '', command => 'x', workdir => $bd2 });
$world->{alive}{ 9999 } = 1;
$gb->write_state({ id => '70-bot', ts => 1000, state => 'RUNNING', pid => 9999, port => 0, crashes => '', reason => '', command => '', workdir => '' });
$gb->ensure_bot(70, $bcfg, $bd2);
is($gb->read_state('70-bot')->{state}, 'STOPPED', 'bot is stopped when the game is stopped');

done_testing();
