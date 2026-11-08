#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../AgentScripts";
use GameManagerWin;

my $tasklist = <<'T';
"PING.EXE                      3596 Console                    1      2,144 K"
"arma2oaserver.exe            9732 Console                    1    512,000 K"
T
ok(GameManagerWin::parse_tasklist_has_pid($tasklist, 9732), 'tasklist finds a live PID');
ok(!GameManagerWin::parse_tasklist_has_pid($tasklist, 9733), 'tasklist does not match a different PID');
ok(!GameManagerWin::parse_tasklist_has_pid('INFO: No tasks are running which match the specified criteria.', 9732), 'no tasks means not alive');

my $netstat = <<'N';
  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:2302           0.0.0.0:0              LISTENING       9732
  TCP    0.0.0.0:2302           0.0.0.0:0              TIME_WAIT       0
  UDP    0.0.0.0:2302           *:*                                    9732
  UDP    0.0.0.0:2312           *:*                                    4444
  TCP    0.0.0.0:12679         0.0.0.0:0              LISTENING       1169
N
is_deeply([ GameManagerWin::parse_netstat_owners($netstat, 2302) ], [9732], 'port 2302 owner is the game PID, once');
is_deeply([ GameManagerWin::parse_netstat_owners($netstat, 2312) ], [4444], 'UDP owner is found');
is_deeply([ GameManagerWin::parse_netstat_owners($netstat, 2999) ], [], 'no owner for a free port');
is_deeply([ GameManagerWin::parse_netstat_owners($netstat, 2302) ], [9732], 'TIME_WAIT rows are not counted as listeners');

is_deeply([ GameManagerWin::split_command('"C:\\game\\arma2oaserver.exe" -port=2302') ], ['C:\\game\\arma2oaserver.exe', '-port=2302'], 'quoted exe is split from args');
is_deeply([ GameManagerWin::split_command('arma2oaserver.exe -cfg=cfg\\basic.cfg') ], ['arma2oaserver.exe', '-cfg=cfg\\basic.cfg'], 'bare exe is split from args');

# port_listening must count owners correctly (scalar context bug guard).
no warnings 'redefine';
{
	my $real = \&GameManagerWin::port_owner_pids;
	no strict 'refs';
	local *GameManagerWin::port_owner_pids = sub { return (9732) };
	is(GameManagerWin::port_listening(2302), 1, 'port_listening is 1 when a process owns the port');
	local *GameManagerWin::port_owner_pids = sub { return () };
	is(GameManagerWin::port_listening(2302), 0, 'port_listening is 0 when nothing owns the port');
}

done_testing();
