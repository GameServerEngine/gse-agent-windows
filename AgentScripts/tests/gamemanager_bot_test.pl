#!/usr/bin/perl
# Bot exits with its game: expected restarts are not counted as crashes.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/..";
require GameManager;

my $root = tempdir(CLEANUP => 1);
make_path("$root/49");
my (%alive, @launches);
my $now = 100;
my $gm = GameManager->new(
	state_dir  => $root,
	dir_for    => sub { "$root/$_[0]" },
	now        => sub { $now },
	pid_alive  => sub { $alive{$_[0]} ? 1 : 0 },
	launch     => sub { push @launches, $_[0]; my $pid = 2000 + scalar(@launches); $alive{$pid} = 1; return $pid; },
	log        => sub { },
);
my $cfg = { workdir => "$root/49", executable => 'cmd.exe', arguments => '/c x' };

sub set_game { my ($pid, $state) = @_; my $g = $gm->read_state('49'); $g->{desired} = 'RUNNING'; $gm->_set($g, $state, pid => $pid, port => 2200); }

# Scenario 1: game restarts after the bot launched -> bot relaunched, no crash counted.
$now = 100; $alive{1000} = 1; set_game(1000, 'RUNNING');
$gm->ensure_bot('49', $cfg, "$root/49");           # launches bot (pid 2001)
$now = 110; $gm->ensure_bot('49', $cfg, "$root/49");  # bot seen alive -> RUNNING
is($gm->read_state('49-bot')->{state}, 'RUNNING', 'bot running with game');
$alive{2001} = 0;                                    # bot exits with the game
$now = 200; $alive{1001} = 1; set_game(1001, 'RUNNING');  # game restarted at 200
$now = 201; $gm->ensure_bot('49', $cfg, "$root/49");
is($gm->read_state('49-bot')->{crashes}, '', 'game restart: no crash counted');
is(scalar(@launches), 2, 'game restart: bot relaunched');

# Scenario 2: game unchanged and its PID alive -> the bot exit is a real crash and is counted.
my $before = scalar(@launches);
$now = 300; $gm->ensure_bot('49', $cfg, "$root/49");  # bot already alive (pid 2002) -> RUNNING
$now = 310; $gm->ensure_bot('49', $cfg, "$root/49");
$alive{2002} = 0;
$now = 320; $gm->ensure_bot('49', $cfg, "$root/49");
ok(length($gm->read_state('49-bot')->{crashes}) > 0, 'healthy game: bot exit counted as crash');
is(scalar(@launches), $before + 1, 'healthy game: bot still relaunched');

# Scenario 3: game PID gone -> expected exit, not counted.
$now = 400; $alive{1001} = 0; $alive{2003} = 1; $gm->_set($gm->read_state('49-bot'), 'RUNNING', pid => 2003);
$now = 410; $gm->ensure_bot('49', $cfg, "$root/49");
$alive{2003} = 0;
my $crashes_before = $gm->read_state('49-bot')->{crashes};
$now = 420; $gm->ensure_bot('49', $cfg, "$root/49");
is($gm->read_state('49-bot')->{crashes}, $crashes_before, 'game PID gone: bot exit not counted');

# Scenario 4: stop clears a dead game PID, keeps a live one.
$now = 500; $alive{3000} = 1; $gm->_set($gm->read_state('49'), 'RUNNING', pid => 3000, port => 2200);
$alive{3000} = 0; $gm->stop('49');
is($gm->read_state('49')->{pid}, 0, 'stop: dead game PID cleared');
$alive{3001} = 1; $gm->_set($gm->read_state('49'), 'RUNNING', pid => 3001, port => 2200);
$gm->stop('49');
is($gm->read_state('49')->{pid}, 3001, 'stop: live game PID kept');
# Scenario 5: a crashed game waits for the backoff before the restart.
$gm->set_desired('49', 'RUNNING');
$now = 1000; $alive{4000} = 1; $gm->_set($gm->read_state('49'), 'RUNNING', pid => 4000, port => 2200);
$alive{4000} = 0; my $launches_before = scalar(@launches);
$now = 1001; $gm->tick('49');
is($gm->read_state('49')->{state}, 'CRASHED', 'crash: state CRASHED');
is(scalar(@launches), $launches_before, 'crash: no immediate relaunch');
$now = 1010; $gm->tick('49');
is(scalar(@launches), $launches_before, 'crash: still waiting inside backoff');
$now = 1035; $gm->tick('49');
is(scalar(@launches), $launches_before + 1, 'crash: relaunched after backoff');
done_testing();
