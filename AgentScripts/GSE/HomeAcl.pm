package GSE::HomeAcl;

# Permissions of a game home on Windows.
#
# The agent re-applies these before it starts a game (take_ownership in agent_core.pl). The order of the commands is
# not arbitrary. Checked on game3 with the agent running as SYSTEM, on copies of a home whose files carry Cygwin-style
# ACLs that only the owner (gameserver) can write:
#
#   * takeown /U only works together with /S (a remote computer), so it cannot be used. takeown /F ... /R /A /D Y
#     gives ownership to the Administrators group, which works for SYSTEM and for an administrator account.
#   * icacls /inheritance:r with /T removes the inherited entries from EVERY file. If the grants were only inherited
#     too, the files end up with no entries at all and nobody, including the agent, can use them.
#     So: reset every file once so that it inherits from the home folder, grant on the home folder only, and remove
#     inheritance on the home folder only. The files then inherit exactly those entries.
#   * Accounts are given by SID (SYSTEM, Administrators) so the routine does not depend on the name of the account
#     the agent runs as, and works for LocalSystem as well as for a named account.
#   * Any account that already has full control of the home (for example the account the FTP service runs as) keeps it.
#
# Apart from plan_for_home, which runs icacls once to read a folder, this module only builds and reads text, so it can be
# tested without Windows.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(home_acl_commands accounts_with_full_control plan_for_home);

use constant SID_SYSTEM         => '*S-1-5-18';
use constant SID_ADMINISTRATORS => '*S-1-5-32-544';
# Everyone, Authenticated Users, Users, Guests
use constant BROAD_GROUP_SIDS   => ('*S-1-1-0', '*S-1-5-11', '*S-1-5-32-545', '*S-1-5-32-546');

sub _sh_quote {
	my ($text) = @_;
	$text =~ s/'/'\\''/g;
	return "'$text'";
}

# True for accounts that are granted by SID anyway, or that are not worth carrying over.
sub _is_builtin_account {
	my ($name) = @_;
	return 1 unless defined $name && $name ne '';
	(my $short = $name) =~ s/^.*\\//;
	return $short =~ /^(?:system|localsystem|administrators?|trustedinstaller|creator owner|creator group|everyone|users|authenticated users|guests?|none|null sid)$/i ? 1 : 0;
}

# Reads the text printed by `icacls <folder>` and returns the DOMAIN\name of every ordinary account that has full control
# of the folder itself or of what is inside it (explicit or inherited), in the order they appear, without repeats.
sub accounts_with_full_control {
	my ($icacls_output) = @_;
	my (@accounts, %seen);
	return @accounts unless defined $icacls_output;
	for my $line (split /\r?\n/, $icacls_output) {
		next if $line =~ /\(DENY\)/;
		next unless $line =~ /\(F\)\s*$/;
		next if $line =~ /\b(?:NT AUTHORITY|BUILTIN|NT SERVICE|APPLICATION PACKAGE AUTHORITY)\\|CREATOR OWNER|CREATOR GROUP|\bEveryone\b|NULL SID/i;
		next unless $line =~ /([A-Za-z0-9_.-]+\\[^\\:()]+?):((?:\([^)]*\))+)\s*$/;
		my $name = $1;
		next if _is_builtin_account($name);
		next if $seen{lc $name}++;
		push @accounts, $name;
	}
	return @accounts;
}

# Returns the commands (as text for /bin/sh) that give a home its permissions.
#   path          the Windows path of the home
#   keep          reference to a list of account names that keep full control
#   running_user  the account the agent runs as (by name; SYSTEM needs no extra grant)
#   isolate       true: also remove inheritance and the broad groups on the home folder
sub home_acl_commands {
	my (%opt) = @_;
	my $path = $opt{path};
	die "home_acl_commands needs a path\n" unless defined $path && $path ne '';
	(my $win = $path) =~ s{/}{\\}g;
	my $quoted = _sh_quote($win);

	my @accounts = (SID_SYSTEM, SID_ADMINISTRATORS);
	my %have;
	for my $name (@{ $opt{keep} || [] }, $opt{running_user}) {
		next if _is_builtin_account($name);
		(my $short = $name) =~ s/^.*\\//;
		next if $have{lc $short}++;
		push @accounts, $name;
	}
	my $grants = join(' ', map { _sh_quote("$_:(OI)(CI)F") } @accounts);

	my @commands = (
		"takeown /F $quoted /R /A /D Y",
		"icacls $quoted /reset /T /C /Q",
		"icacls $quoted /grant:r $grants /C /Q",
	);
	if ($opt{isolate}) {
		push @commands, "icacls $quoted /inheritance:r /C /Q";
		push @commands, "icacls $quoted /remove:g " . join(' ', map { _sh_quote($_) } BROAD_GROUP_SIDS) . " /C /Q";
	}
	return @commands;
}

# The commands for a home that exists now. It reads the home's current entries first so that an account that has full
# control (for example the FTP account) keeps it, whichever account the agent runs as.
#   path, running_user, isolate   as for home_acl_commands
sub plan_for_home {
	my (%opt) = @_;
	(my $quoted = $opt{path}) =~ s/'/'\\''/g;
	my $current_acl = `icacls '$quoted' 2>/dev/null`;
	return home_acl_commands(
		path         => $opt{path},
		keep         => [ accounts_with_full_control($current_acl) ],
		running_user => $opt{running_user},
		isolate      => $opt{isolate},
	);
}

1;
