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
        executable_exists => sub { $exists }, log => sub { },
    );
}

my $root = tempdir(CLEANUP => 1); make_path("$root/52");
my (%alive, @launches);
my $gm = manager($root, \%alive, \@launches, 1);
my $s = $gm->read_state('52'); $s->{command} = 'C:\\games\\server.exe'; $s->{workdir} = "$root/52"; $s->{desired} = 'RUNNING'; $gm->write_state($s);
$gm->tick('52'); is(scalar @launches, 1, 'desired RUNNING with no process starts');

$gm->set_desired('52', 'STOPPED'); $alive{9001} = 1; $s = $gm->read_state('52'); $s->{pid} = 9001; $s->{state} = 'RUNNING'; $gm->write_state($s); $gm->tick('52');
is($gm->read_state('52')->{desired}, 'STOPPED', 'desired STOPPED persists'); is($gm->read_state('52')->{state}, 'STOPPED', 'desired STOPPED stops process');

my $missing = manager($root, {}, [], 0); $s = $missing->read_state('52'); $s->{command} = 'C:\\games\\Dzsalmodserver.exe'; $s->{desired} = 'RUNNING'; $missing->write_state($s); $missing->tick('52');
is($missing->read_state('52')->{state}, 'FAILED', 'missing executable fails'); like($missing->read_state('52')->{reason}, qr/^executable missing:/, 'missing executable reason recorded');

my $limited = manager($root, {}, [], 1); $s = $limited->read_state('52'); $s->{desired} = 'RUNNING'; $s->{state} = 'RUNNING'; $s->{command} = 'C:\\games\\server.exe'; $s->{crashes} = join(',', 1..5); $limited->write_state($s); $limited->tick('52');
is($limited->read_state('52')->{state}, 'FAILED', 'restart limit fails'); is($limited->read_state('52')->{reason}, 'restart limit reached', 'restart limit reason recorded');

my $dead_root = tempdir(CLEANUP => 1); make_path("$dead_root/49");
my $dead_now = 2000; my %dead_alive = (4901 => 0);
my $dead = GameManager->new(
    state_dir => $dead_root, dir_for => sub { "$dead_root/$_[0]" }, now => sub { $dead_now },
    pid_alive => sub { $dead_alive{$_[0]} ? 1 : 0 },
    pid_executable_matches => sub { 1 }, port_listening => sub { 0 },
    executable_exists => sub { 1 }, launch => sub { 0 }, log => sub { },
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
done_testing();
