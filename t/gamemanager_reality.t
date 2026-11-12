#!/usr/bin/perl
# The status file must follow what is really running, whoever started or stopped the game
# (the panel, the agent, or an admin on the host). Each block below is one real situation.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use Fcntl qw(:flock);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../AgentScripts";
use GameManager;

# Fake world: which PIDs are alive, which ports are open, who owns a port, and the clock.
my ($world, $next_pid, @launched, $root);
sub new_world {
	$world = { now => 1000, alive => {}, port => {}, owners => {}, killed => [] };
	$next_pid = 100;
	@launched = ();
	$root = tempdir(CLEANUP => 1);
	mkdir File::Spec->catdir($root, $_) for (49, 52);
}
sub make_gm {
	return GameManager->new(
		state_dir       => $root,
		dir_for         => sub { File::Spec->catdir($root, $_[0]) },
		agent_dir       => 'C:\\GSE\\Agent',
		now             => sub { $world->{now} },
		pid_alive       => sub { $world->{alive}{$_[0]} ? 1 : 0 },
		port_listening  => sub { $world->{port}{$_[0]} ? 1 : 0 },
		port_owner_pids => sub { @{ $world->{owners}{$_[0]} || [] } },
		kill_pid        => sub {
			my $p = shift; delete $world->{alive}{$p}; push @{ $world->{killed} }, $p;
			for my $port (keys %{ $world->{owners} }) {
				$world->{owners}{$port} = [ grep { $_ != $p } @{ $world->{owners}{$port} } ];
				$world->{port}{$port} = 0 unless @{ $world->{owners}{$port} };
			}
			1;
		},
		launch          => sub { my $pid = $next_pid++; $world->{alive}{$pid} = 1; push @launched, $pid; return $pid },
		sleep           => sub { },
		log             => sub { },
		lock_wait       => 0,
		startup_timeout => 180,
	);
}
sub state { my ($gm, $id) = @_; return $gm->read_state($id)->{state}; }
sub game_up { my ($pid, $port) = @_; $world->{alive}{$pid} = 1; $world->{owners}{$port} = [$pid]; $world->{port}{$port} = 1; }

# Server 52's real history: the panel Start stamps launched_at, so the check that follows
# is not fooled by an old launch time and does not launch a second copy.
new_world();
my $gm = make_gm();
$gm->write_state({ id => 52, state => 'STOPPED', ts => 1, launched_at => 5, desired => 'STOPPED', port => 2300, command => 'game.exe', workdir => 'C:/g' });
$world->{now} = 90000;
my $r = $gm->start(52, command => 'game.exe', workdir => 'C:/g', port => 2300);
ok($r->{ok}, 'panel Start works');
is($gm->read_state(52)->{launched_at}, 90000, 'Start stamps launched_at with the time of this launch');
$world->{now} += 40;
$gm->tick(52);
is(state($gm, 52), 'STARTING', 'a check just after Start does not call the new start hung');
is(scalar(@launched), 1, 'the game was launched once, not twice');

# A game that is really up under FAILED (what 52 looked like) is taken over, not left FAILED.
new_world();
$gm = make_gm();
$gm->write_state({ id => 52, state => 'FAILED', ts => 1, reason => 'Failed to Start: max restarts reached', desired => 'RUNNING', port => 2300, command => 'game.exe', workdir => 'C:/g', crashes => '1,2,3' });
game_up(555, 2300);
$gm->tick(52);
is(state($gm, 52), 'RUNNING', 'live game under FAILED shows RUNNING');
is($gm->read_state(52)->{pid}, 555, 'the live PID is recorded');
is(scalar(@launched), 0, 'nothing was launched on top of it');
is(scalar(@{ $world->{killed} }), 0, 'nothing was killed');

# Started by hand: the status file says STOPPED but the game is up. It is adopted, not killed.
new_world();
$gm = make_gm();
$gm->write_state({ id => 52, state => 'STOPPED', ts => 1, desired => 'RUNNING', port => 2300, command => 'game.exe', workdir => 'C:/g' });
game_up(556, 2300);
$gm->tick(52);
is(state($gm, 52), 'RUNNING', 'hand-started game is adopted as RUNNING');
is(scalar(@{ $world->{killed} }), 0, 'hand-started game is not killed as a zombie');

# The saved PID is dead but the same game is up under another PID: still RUNNING, no restart.
new_world();
$gm = make_gm();
$gm->write_state({ id => 52, state => 'RUNNING', ts => 1, pid => 100, desired => 'RUNNING', port => 2300, command => 'game.exe', workdir => 'C:/g' });
game_up(557, 2300);
$gm->tick(52);
is(state($gm, 52), 'RUNNING', 'dead saved PID with a live game on the port stays RUNNING');
is($gm->read_state(52)->{pid}, 557, 'the PID is corrected to the live one');
is(scalar(@launched), 0, 'no second copy is launched');

# Admin stop on the host: stopserver.bat records STOPPED, the check stops the game and keeps it stopped.
$gm->set_desired(52, 'STOPPED');
$gm->tick(52);
is(state($gm, 52), 'STOPPED', 'after an admin stop the next check stops the game');
ok(!$world->{alive}{557}, 'the game process is gone');
$gm->tick(52);
is(state($gm, 52), 'STOPPED', 'it stays stopped (no relaunch)');
is(scalar(@launched), 0, 'and nothing was launched');

# Admin start on the host: startserver.bat records RUNNING, the check launches. FAILED does not block it.
new_world();
$gm = make_gm();
$gm->write_state({ id => 52, state => 'FAILED', ts => 1, reason => 'restart limit reached', desired => 'STOPPED', port => 2300, command => 'game.exe', workdir => 'C:/g', crashes => '1,2,3' });
$r = $gm->set_desired(52, 'RUNNING');
ok($r->{ok}, 'set_desired RUNNING works');
is(state($gm, 52), 'STOPPED', 'a new wish to run clears FAILED');
$gm->tick(52);
is(state($gm, 52), 'STARTING', 'the next check launches the game');
is(scalar(@launched), 1, 'launched once');

# A game that died while RUNNING is noticed (the 49/50/51 case): after the missed checks it is restarted.
new_world();
$gm = make_gm();
$gm->write_state({ id => 49, state => 'RUNNING', ts => 1, pid => 100, desired => 'RUNNING', port => 2302, command => 'game.exe', workdir => 'C:/g' });
$gm->tick(49) for 1 .. 4;
isnt(state($gm, 49), 'RUNNING', 'a dead game does not stay RUNNING');
ok(scalar(@launched) >= 1, 'and it is restarted because RUNNING is wanted');

# One worker per server: while another process holds the server's lock, Start and the check do nothing.
new_world();
$gm = make_gm();
$gm->write_state({ id => 52, state => 'STOPPED', ts => 1, desired => 'RUNNING', port => 2300, command => 'game.exe', workdir => 'C:/g' });
open(my $held, '>>', File::Spec->catfile($root, 52, 'status.lock')) or die;
flock($held, LOCK_EX) or die;
$r = $gm->start(52, command => 'game.exe', workdir => 'C:/g', port => 2300);
ok(!$r->{ok}, 'Start refuses while another request is working on the server');
like($r->{reason}, qr/busy/, 'and says why');
$gm->tick(52);
is(scalar(@launched), 0, 'the check launches nothing while the lock is held');
is($gm->stop(52)->{ok}, 0, 'Stop also waits its turn');
close $held;
$r = $gm->start(52, command => 'game.exe', workdir => 'C:/g', port => 2300);
ok($r->{ok}, 'once the lock is free Start works');

# The lock is per game: the bot shares its game's lock, and tick calling start inside the lock does not deadlock.
new_world();
$gm = make_gm();
$gm->write_state({ id => 52, state => 'STOPPED', ts => 1, desired => 'RUNNING', port => 2300, command => 'game.exe', workdir => 'C:/g' });
is($gm->tick(52), 'STARTING', 'tick can start the game while holding the lock');

# The admin scripts are short and call the agent's gse_ctl.pl.
new_world();
$gm = make_gm();
$gm->start(52, command => 'game.exe', workdir => 'C:/g', port => 2300);
for my $action (qw(start stop)) {
	my $file = File::Spec->catfile($root, 52, "${action}server.bat");
	ok(-f $file, "${action}server.bat is written into the server folder");
	open(my $fh, '<', $file) or die; local $/; my $text = <$fh>; close $fh;
	like($text, qr/gse_ctl\.pl" $action 52\r\n/, "${action}server.bat calls gse_ctl.pl $action 52");
	ok(($text =~ tr/\n//) <= 3, "${action}server.bat is three lines or fewer");
}

done_testing();
