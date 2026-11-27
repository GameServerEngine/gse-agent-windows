#!/usr/bin/perl
# Tests for GSE::HomeAcl and for the way agent_core.pl uses it. No Windows needed: the module only builds and reads text.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../AgentScripts";
use File::Temp qw(tempdir);
use GSE::HomeAcl qw(home_acl_commands accounts_with_full_control plan_for_home);

my $failures = 0;
sub check { my ($ok, $name) = @_; print(($ok ? "ok" : "FAIL") . " - $name\n"); $failures++ unless $ok; }

# --- what `icacls <home>` prints for the three kinds of home seen on game3 -------------------------------------
my $home49 = <<'EOT';
C:\GSE\Agent\home\gameserver\49 GAME3\gameserver:(OI)(CI)(F)
                                GAME3\gameserver:(I)(OI)(CI)(F)
                                NT AUTHORITY\SYSTEM:(I)(OI)(CI)(F)
                                BUILTIN\Administrators:(I)(OI)(CI)(F)
                                BUILTIN\Users:(I)(OI)(CI)(RX)
                                BUILTIN\Users:(I)(CI)(WD,AD,WEA,WA)
                                CREATOR OWNER:(I)(OI)(CI)(IO)(F)

Successfully processed 1 files; Failed processing 0 files
EOT
my $home951_cygwin = <<'EOT';
C:\GSE\Agent\home\gameserver\951 NULL SID:(DENY)(S,X,DC,RC)
                                 GAME3\gameserver:(F)
                                 BUILTIN\Users:(DENY)(DC,WD,AD,WEA,WA)
                                 GAME3\None:(RX)
                                 NT AUTHORITY\SYSTEM:(DC,WD,AD,WEA,WA,RX)
                                 BUILTIN\Administrators:(DC,WD,AD,WEA,WA,RX)
                                 BUILTIN\Users:(DC,WD,AD,WEA,WA,RX)
                                 Everyone:(RX)

Successfully processed 1 files; Failed processing 0 files
EOT
my $healed = <<'EOT';
C:\GSE\Agent\home\gameserver\951 GAME3\gameserver:(OI)(CI)(F)
                                 BUILTIN\Administrators:(OI)(CI)(F)
                                 NT AUTHORITY\SYSTEM:(OI)(CI)(F)

Successfully processed 1 files; Failed processing 0 files
EOT
my $only_builtin = "C:\\h NT AUTHORITY\\SYSTEM:(OI)(CI)(F)\n    BUILTIN\\Administrators:(OI)(CI)(F)\n    BUILTIN\\Users:(OI)(CI)(RX)\n";
my $two_accounts = "C:\\h GAME3\\gameserver:(OI)(CI)(F)\n    GAME3\\ftpuser:(OI)(CI)(F)\n    GAME3\\gameserver:(I)(F)\n    GAME3\\readonly:(OI)(CI)(RX)\n";

check(join(',', accounts_with_full_control($home49)) eq 'GAME3\gameserver', 'a normal home: only the ordinary account is kept (not SYSTEM, Administrators, Users, CREATOR OWNER)');
check(join(',', accounts_with_full_control($home951_cygwin)) eq 'GAME3\gameserver', 'a home with Cygwin-style entries: gameserver is kept, deny entries and read-only groups are not');
check(join(',', accounts_with_full_control($healed)) eq 'GAME3\gameserver', 'a healed home: gameserver is kept (so the second run keeps FTP working)');
check(scalar(accounts_with_full_control($only_builtin)) == 0, 'only built-in accounts: nothing to keep');
check(join(',', accounts_with_full_control($two_accounts)) eq 'GAME3\gameserver,GAME3\ftpuser', 'two accounts, repeats removed, read-only account skipped');
check(scalar(accounts_with_full_control(undef)) == 0 && scalar(accounts_with_full_control('')) == 0, 'no output at all gives no accounts and no error');

# --- the commands -------------------------------------------------------------------------------------------
my @c = home_acl_commands(path => 'C:/GSE/Agent/home/gameserver/951', keep => ['GAME3\gameserver'], running_user => 'SYSTEM', isolate => 1);
check(scalar(@c) == 5, 'isolation on: five commands');
check($c[0] eq q{takeown /F 'C:\GSE\Agent\home\gameserver\951' /R /A /D Y}, 'takeown assigns ownership to Administrators and has no /U');
check($c[1] eq q{icacls 'C:\GSE\Agent\home\gameserver\951' /reset /T /C /Q}, 'everything is reset once, recursively');
check($c[2] eq q{icacls 'C:\GSE\Agent\home\gameserver\951' /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 'GAME3\gameserver:(OI)(CI)F' /C /Q}, 'SYSTEM and Administrators by SID, and the existing account, on the home folder only');
check($c[3] eq q{icacls 'C:\GSE\Agent\home\gameserver\951' /inheritance:r /C /Q}, 'inheritance is removed AFTER the grants, on the home folder only');
check($c[4] eq q{icacls 'C:\GSE\Agent\home\gameserver\951' /remove:g '*S-1-1-0' '*S-1-5-11' '*S-1-5-32-545' '*S-1-5-32-546' /C /Q}, 'Everyone, Authenticated Users, Users and Guests are removed');
check((grep { /\/U\b/ } @c) == 0, 'no command uses /U');
check((grep { /\/T\b/ && !/\/reset/ } @c) == 0, '/T (recursive) is only used by the reset');
my @off = home_acl_commands(path => 'C:\h', keep => [], running_user => 'SYSTEM', isolate => 0);
check(scalar(@off) == 3 && !(grep { /inheritance|remove:g/ } @off), 'isolation off: no inheritance removal and no group removal');
my @named = home_acl_commands(path => 'C:\h', keep => ['GAME3\gameserver'], running_user => 'gameserver', isolate => 1);
check((() = $named[2] =~ /gameserver:\(OI\)\(CI\)F/g) == 1, 'the running account is not granted twice when it is already kept');
my @svc = home_acl_commands(path => 'C:\h', keep => [], running_user => 'svcaccount', isolate => 1);
check(scalar($svc[2] =~ /'svcaccount:\(OI\)\(CI\)F'/) ? 1 : 0, 'a named service account gets full control too');
my @quote = home_acl_commands(path => "C:\\it's here", keep => [], running_user => 'SYSTEM', isolate => 0);
check($quote[1] eq q{icacls 'C:\it'\''s here' /reset /T /C /Q}, 'a quote in the path is escaped for the shell');

# --- the shell must split the commands into exactly the arguments we mean -----------------------------------
my $bin = tempdir(CLEANUP => 1);
for my $tool (qw(takeown icacls)) {
	open(my $fh, '>', "$bin/$tool") or die; print $fh "#!/bin/sh\nprintf '%s\\n' \"\$0 \$#\" \"\$@\" >> \"\$GSE_ARGS_LOG\"\n"; close $fh; chmod 0755, "$bin/$tool";
}
$ENV{GSE_ARGS_LOG} = "$bin/args.log"; $ENV{PATH} = "$bin:$ENV{PATH}";
system($_ . ' >/dev/null 2>&1') for @c;
open(my $log, '<', "$bin/args.log") or die; my @lines = <$log>; close $log; chomp @lines;
check((grep { $_ eq q{*S-1-5-18:(OI)(CI)F} } @lines) == 1 && (grep { $_ eq q{GAME3\gameserver:(OI)(CI)F} } @lines) == 1, 'the shell passes each grant as one argument, parentheses and * intact');
check((grep { $_ eq q{C:\GSE\Agent\home\gameserver\951} } @lines) == 5, 'the path reaches every command as one argument');

# --- plan_for_home reads the folder with icacls first (a shim prints a canned answer for a one-argument query) ------
{
	open(my $cf, '>', "$bin/icacls.canned") or die; print $cf $home951_cygwin; close $cf;
	open(my $sh, '>', "$bin/icacls") or die;
	print $sh <<'SHIM';
#!/bin/sh
if [ "$#" -eq 1 ]; then cat "$(dirname "$0")/icacls.canned"; else printf '%s\n' "$@" >> "$GSE_ARGS_LOG"; fi
SHIM
	close $sh; chmod 0755, "$bin/icacls";
	my @planned = plan_for_home(path => 'C:\GSE\Agent\home\gameserver\951', running_user => 'SYSTEM', isolate => 1);
	check(scalar(@planned) == 5, 'plan_for_home: five commands for a home');
	check(scalar($planned[2] =~ /'GAME3\\gameserver:\(OI\)\(CI\)F'/) ? 1 : 0, 'plan_for_home: the account that has full control now is carried into the grants');
}

# --- agent_core.pl uses the module and keeps none of the broken commands ---------------------------------------
open(my $src, '<', "$Bin/../AgentScripts/agent_core.pl") or die; local $/; my $core = <$src>; close $src;
check($core !~ /takeown\s+\/U/, 'agent_core.pl never runs takeown /U');
check($core !~ /inheritance:r[^\n]*\/T\b/, 'agent_core.pl never combines /inheritance:r with /T');
check(scalar($core =~ /use GSE::HomeAcl qw\(plan_for_home\)/) ? 1 : 0, 'agent_core.pl uses GSE::HomeAcl');

print "\n" . ($failures ? "$failures home ACL check(s) FAILED\n" : "all home ACL checks passed\n");
exit($failures ? 1 : 0);
