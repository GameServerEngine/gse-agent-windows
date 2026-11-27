package GSE::FtpAccounts;

# The shell commands the agent runs to manage Pure-FTPd virtual users (ftp_mgr in agent_core.pl).
#
# The Cygwin pure-pw we ship reads /etc/pureftpd.passwd for `list` and `show` whatever -f says, and that file does not
# exist (the accounts are in /etc/ftp). So listing or showing an account failed with "Unable to open the passwd file".
# PURE_PASSWDFILE and PURE_DBFILE are honoured by every command, so they are always set; -f stays for builds that read it.
#
# This module only builds text, so it can be tested without Windows.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(ftp_account_command);

sub _quote {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/'/'\\''/g;
	return "'$text'";
}

sub _number {
	my ($value) = @_;
	return (defined $value && $value =~ /^\s*(\d+)/) ? $1 : 0;
}

# action: list, show, useradd, passwd, usermod or userdel. Returns undef for anything else.
#   login, password, home_path   as the action needs them
#   passwd_file, db_file         the account file and its database
#   uid, gid                     the owner given to new accounts
sub ftp_account_command {
	my (%a) = @_;
	my ($action, $pwf, $pdb) = ($a{action}, _quote($a{passwd_file}), _quote($a{db_file}));
	return undef unless defined $action && defined $a{passwd_file} && defined $a{db_file};
	my $login = _quote($a{login});
	my $pw    = _quote($a{password});
	my $env   = "PURE_PASSWDFILE=$pwf PURE_DBFILE=$pdb; export PURE_PASSWDFILE PURE_DBFILE; ";
	my $mkdb  = "pure-pw mkdb $pdb -f $pwf";
	my $type_in = "(printf '%s\\n%s\\n' $pw $pw)";

	my $cmd;
	if    ($action eq 'list')    { $cmd = "pure-pw list -f $pwf"; }
	elsif ($action eq 'show')    { $cmd = "pure-pw show $login -f $pwf"; }
	elsif ($action eq 'userdel') { $cmd = "pure-pw userdel $login -f $pwf && $mkdb"; }
	elsif ($action eq 'useradd') { $cmd = "$type_in | pure-pw useradd $login -f $pwf -u " . _number($a{uid}) . " -g " . _number($a{gid}) . " -d " . _quote($a{home_path}) . " && $mkdb"; }
	elsif ($action eq 'passwd')  { $cmd = "$type_in | pure-pw passwd $login -f $pwf && $mkdb"; }
	elsif ($action eq 'usermod') { $cmd = "pure-pw usermod $login -f $pwf -d " . _quote($a{home_path}) . " && $mkdb"; }
	else                         { return undef; }
	return $env . $cmd;
}

1;
