#!/usr/bin/perl
# gse_ctl.pl start|stop <server id>
# Used by startserver.bat and stopserver.bat in a game folder, for an admin working on the host.
# It only records what is wanted (RUNNING or STOPPED). The agent's 30 second check does the work
# and keeps the status file right, then this script reports what it sees.
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use GameManager;

my ($action, $id) = @ARGV;
my $want = { start => 'RUNNING', stop => 'STOPPED' }->{ lc($action // '') };
die "Usage: gse_ctl.pl start|stop <server id>\n" unless $want && defined $id && $id =~ /^\d+$/;

my $root = 'C:\\GSE\\Agent\\home\\gameserver';
my $gm   = GameManager->new(state_dir => $root, dir_for => sub { "$root\\$_[0]" });

my $r = $gm->set_desired($id, $want);
die "Server $id: could not record the request ($r->{reason})\n" unless $r->{ok};
print "Server $id: $want requested. Waiting for the agent (up to 90 seconds)...\n";

# RUNNING is done when the game is up; STOPPED is done when it is down.
my $done = $want eq 'RUNNING' ? qr/^RUNNING$/ : qr/^STOPPED$/;
my $state = '';
for (1 .. 45) {
	$state = $gm->read_state($id)->{state} // '';
	last if $state =~ $done || $state eq 'FAILED';
	sleep 2;
}
print "Server $id is now $state.\n";
exit($state =~ $done ? 0 : 1);
