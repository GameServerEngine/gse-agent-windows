#!/usr/bin/perl
# Tests for GSE::FtpAccounts and for the way agent_core.pl uses it. No Windows needed.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../AgentScripts";
use File::Temp qw(tempdir);
use GSE::FtpAccounts qw(ftp_account_command);

my $failures = 0;
sub check { my ($ok, $name) = @_; print(($ok ? "ok" : "FAIL") . " - $name\n"); $failures++ unless $ok; }

my %base = (passwd_file => '/etc/ftp/pureftpd.passwd', db_file => '/etc/ftp/pureftpd.pdb', uid => 18, gid => 18);
my $env = q{PURE_PASSWDFILE='/etc/ftp/pureftpd.passwd' PURE_DBFILE='/etc/ftp/pureftpd.pdb'; export PURE_PASSWDFILE PURE_DBFILE; };

check(ftp_account_command(%base, action => 'list') eq $env . q{pure-pw list -f '/etc/ftp/pureftpd.passwd'}, 'list: the files are set in the environment and with -f');
check(ftp_account_command(%base, action => 'show', login => 'bob') eq $env . q{pure-pw show 'bob' -f '/etc/ftp/pureftpd.passwd'}, 'show');
check(ftp_account_command(%base, action => 'userdel', login => 'bob') eq $env . q{pure-pw userdel 'bob' -f '/etc/ftp/pureftpd.passwd' && pure-pw mkdb '/etc/ftp/pureftpd.pdb' -f '/etc/ftp/pureftpd.passwd'}, 'userdel rebuilds the database');
check(ftp_account_command(%base, action => 'useradd', login => 'bob', password => 'pw', home_path => '/home/gameserver/5') =~ /pure-pw useradd 'bob' -f '[^']+' -u 18 -g 18 -d '\/home\/gameserver\/5' && pure-pw mkdb/, 'useradd rebuilds the database');
check(ftp_account_command(%base, action => 'passwd', login => 'bob', password => 'pw') =~ /\| pure-pw passwd 'bob' .* && pure-pw mkdb/, 'passwd rebuilds the database');
check(ftp_account_command(%base, action => 'usermod', login => 'bob', home_path => '/x') =~ /pure-pw usermod 'bob' -f '[^']+' -d '\/x' && pure-pw mkdb/, 'usermod rebuilds the database');
check(!defined ftp_account_command(%base, action => 'format-disk'), 'an unknown action gives nothing to run');
check(!defined ftp_account_command(action => 'list'), 'no files given: nothing to run');
check(ftp_account_command(%base, action => 'useradd', login => 'a', password => 'p', home_path => '/h', uid => '18; rm -rf /') =~ /-u 18 /, 'a uid is a number, never shell text');

# --- run the commands through the shell with a stand-in pure-pw: it must see the environment and the exact arguments ---
my $bin = tempdir(CLEANUP => 1);
open(my $fh, '>', "$bin/pure-pw") or die;
print $fh <<'SHIM';
#!/bin/sh
{ echo "ENV $PURE_PASSWDFILE $PURE_DBFILE"; for a in "$@"; do echo "ARG $a"; done; if [ "$1" = useradd ] || [ "$1" = passwd ]; then read p1; read p2; echo "PW $p1 $p2"; fi; } >> "$GSE_LOG"
SHIM
close $fh; chmod 0755, "$bin/pure-pw";
$ENV{GSE_LOG} = "$bin/log"; $ENV{PATH} = "$bin:$ENV{PATH}";
my $tricky_login = "o'brien x";
my $tricky_pass  = q{p"a$s'w ord};
system(ftp_account_command(%base, action => 'useradd', login => $tricky_login, password => $tricky_pass, home_path => "/home/game server/it's"));
open(my $log, '<', "$bin/log") or die; my @lines = <$log>; close $log; chomp @lines;
check((grep { $_ eq 'ENV /etc/ftp/pureftpd.passwd /etc/ftp/pureftpd.pdb' } @lines) == 2, 'pure-pw sees PURE_PASSWDFILE and PURE_DBFILE on both of its runs (useradd and mkdb)');
check((grep { $_ eq "ARG $tricky_login" } @lines) == 1, 'a login with a space and a quote arrives as one argument');
check((grep { $_ eq "ARG /home/game server/it's" } @lines) == 1, 'a home path with a space and a quote arrives as one argument');
check((grep { $_ eq "PW $tricky_pass $tricky_pass" } @lines) == 1, 'a password with quotes and a dollar sign is typed twice unchanged');

# --- agent_core.pl uses the module and builds no pure-pw command itself -------------------------------------------
open(my $src, '<', "$Bin/../AgentScripts/agent_core.pl") or die; local $/; my $core = <$src>; close $src;
check(scalar($core =~ /use GSE::FtpAccounts qw\(ftp_account_command\)/) ? 1 : 0, 'agent_core.pl uses GSE::FtpAccounts');
check(($core =~ s/"pure-pw /"pure-pw /g) == 0, 'agent_core.pl builds no pure-pw command text itself');

print "\n" . ($failures ? "$failures FTP account check(s) FAILED\n" : "all FTP account checks passed\n");
exit($failures ? 1 : 0);
