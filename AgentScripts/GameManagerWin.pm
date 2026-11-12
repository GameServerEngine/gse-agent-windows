package GameManagerWin;
# Windows process and port checks for GameManager. Uses tasklist, netstat and taskkill, plus
# PowerShell (CIM) for the process list and for launching. All of them run from Cygwin on the game
# server box. Needs Windows 10 or Windows Server 2016 or newer.
use strict;
use warnings;
use JSON::PP ();
use MIME::Base64 ();
use Encode ();

# Window style for launched games: Hidden in service mode, Normal (visible) in foreground mode.
our $WINDOW_STYLE = 'Hidden';
sub set_window_style { $WINDOW_STYLE = ($_[0] ? 'Normal' : 'Hidden'); return 1; }
sub foreground_enabled { return $WINDOW_STYLE eq 'Normal' ? 1 : 0; }

# Full path to powershell.exe. The Windows service's PATH is not trusted, so the full /cygdrive
# form is used (Cygwin turns it into the native path when it runs the program).
use constant POWERSHELL_EXE => '/cygdrive/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';

# Pure parser (tested without Windows). Reads the one line the launch script prints,
# "<ProcessId>,<ReturnValue>" (the two results of Win32_Process Create).
# Returns ($pid, '') on success, or (0, $reason) on failure.
sub parse_ps_create_result {
	my ($text) = @_;
	$text = '' unless defined $text;
	my ($pid, $rv) = $text =~ /^\s*(\d*),(\d+)\s*$/m;
	return (0, 'no result from the create call') unless defined $rv;
	return (0, "create failed, ReturnValue=$rv") unless $rv == 0;
	return (0, 'create succeeded but gave no ProcessId') unless defined $pid && length $pid && $pid > 0;
	return ($pid, '');
}

# Pure parser (tested without Windows). The process list the PowerShell script prints as JSON
# becomes an arrayref of { ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine } hashes.
# Returns undef when the text is not that list (unknown, never "no processes").
sub parse_ps_process_json {
	my ($text) = @_;
	return undef unless defined $text && $text =~ /\S/;
	my $rows = eval { JSON::PP->new->utf8->decode($text) };
	return undef unless ref($rows) eq 'ARRAY' && @$rows;
	return [ grep { ref($_) eq 'HASH' && defined $_->{ProcessId} && $_->{ProcessId} =~ /^\d+$/ } @$rows ];
}

sub parse_tasklist_has_pid {
	my ($text, $pid) = @_;
	return 0 unless defined $pid && $pid =~ /^\d+$/;
	for my $line (split /\n/, $text // '') {
		return 1 if $line =~ /\s$pid\s/;
	}
	return 0;
}

# Returns the PIDs listening on a port, from netstat -ano output.
# TCP rows: proto local foreign state pid (state must be LISTENING). UDP rows: proto local foreign pid.
sub parse_netstat_owners {
	my ($text, $port) = @_;
	my %owners;
	return () unless defined $port && $port =~ /^\d+$/;
	for my $line (split /\n/, $text // '') {
		my @f = split ' ', $line;
		next unless @f >= 4 && $f[0] =~ /^(TCP|UDP)$/i;
		next unless $f[1] =~ /:$port$/;
		my $pid = $f[-1];
		next unless $pid =~ /^\d+$/ && $pid > 4;
		if (uc($f[0]) eq 'TCP') { next unless @f >= 5 && uc($f[3]) eq 'LISTENING'; }
		$owners{$pid} = 1;
	}
	return sort { $a <=> $b } keys %owners;
}

# Splits a command line into the executable and its arguments.
sub split_command {
	my ($cmd) = @_;
	return ('', '') unless defined $cmd;
	if ($cmd =~ /^\s*"([^"]+)"\s*(.*)$/) { return ($1, $2); }
	if ($cmd =~ /^\s*(\S+?\.exe)\s*(.*)$/i) { return ($1, $2); }
	return ('', $cmd);
}

# Runs a PowerShell script with no shell involved: the script goes in as one -EncodedCommand
# argument, so there is no quoting to get wrong. Returns ($stdout, '') on success, or
# (undef, $reason) when PowerShell could not run (callers treat that as unknown, not "none").
sub run_ps {
	my ($script) = @_;
	$script = "\$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = [Text.Encoding]::UTF8; $script";
	my $encoded = MIME::Base64::encode_base64(Encode::encode('UTF-16LE', $script), '');
	my $pid = open(my $fh, '-|');
	return (undef, "run_ps: fork failed: $!") unless defined $pid;
	if ($pid == 0) {
		open(STDERR, '>', '/dev/null');
		exec(POWERSHELL_EXE, '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) or exit(127);
	}
	local $/ = undef;
	my $out = <$fh>;
	close $fh;
	my $exit = $? >> 8;
	return (undef, 'powershell not runnable: ' . POWERSHELL_EXE) if $exit == 127;
	return (undef, "powershell failed (exit $exit)") if $exit != 0;
	$out = '' unless defined $out;
	$out =~ s/\A\xEF\xBB\xBF//;   # a UTF-8 byte order mark, if PowerShell wrote one
	return ($out, '');
}

# PowerShell single-quoted string: the only character to double is the quote itself.
sub ps_quote {
	my ($s) = @_;
	$s = '' unless defined $s;
	$s =~ s/'/''/g;
	return "'$s'";
}

# The list of running processes, read with ONE PowerShell call and kept for a few seconds so that
# every server checked in the same 30 second pass shares it (it used to be one call per server).
# Launching or killing a process drops it. Returns an arrayref, or undef when it could not be read.
my ($PROCESS_TABLE, $PROCESS_TABLE_AT) = (undef, 0);
sub forget_process_table { $PROCESS_TABLE = undef; return 1; }
sub process_table {
	return $PROCESS_TABLE if $PROCESS_TABLE && time() - $PROCESS_TABLE_AT < 5;
	my ($out, $err) = run_ps('ConvertTo-Json -Compress -InputObject @(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine)');
	if ($err) {
		warn "GameManagerWin::process_table: $err\n";
		return undef;
	}
	my $rows = parse_ps_process_json($out);
	unless ($rows) {
		warn "GameManagerWin::process_table: the process list could not be read\n";
		return undef;
	}
	($PROCESS_TABLE, $PROCESS_TABLE_AT) = ($rows, time());
	return $rows;
}

# Converts a Cygwin path (/cygdrive/c/x/y) or a forward-slash path (C:/x/y) to the
# native Windows form that cmd.exe and PowerShell expect.
sub to_windows_path {
	my ($p) = @_;
	return '' unless defined $p;
	# Cygwin paths (/home/gameserver/49, /cygdrive/c/...) are real on this box, but cmd.exe and
	# Windows cannot read them. cygpath gives the native path the Windows side resolves.
	if ($p =~ m{^/}) {
		my $w = `cygpath -w "$p" 2>/dev/null`;
		if (defined $w) {
			$w =~ s/[\r\n]+\z//;
			return $w if length $w;
		}
	}
	$p =~ s{^/cygdrive/([A-Za-z])(?=/|\z)}{uc($1) . ':'}e;
	$p =~ s{/}{\\}g;
	return $p;
}

# Port check that can tell "no listener" apart from "netstat could not run".
# Returns 1 or 0, or undef when the check itself failed (callers must treat undef as unknown).
sub port_probe {
	my ($port) = @_;
	my $out = `netstat -ano 2>/dev/null`;
	return undef if $? != 0;
	my @owners = parse_netstat_owners($out, $port);
	return @owners ? 1 : 0;
}

# Live checks (run on Windows).
sub pid_alive {
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^\d+$/;
	my $out = `tasklist /FI "PID eq $pid" /NH 2>/dev/null`;
	return parse_tasklist_has_pid($out, $pid);
}

# Does this PID belong to the expected executable? Uses tasklist (the image name), which is
# cheap and does not depend on the process list.
# Returns 1 or 0, or undef when tasklist itself could not run (unknown, not "no match").
sub pid_executable_matches {
	my ($pid, $expected) = @_;
	return 1 unless defined $expected && length $expected;
	return 0 unless $pid && $pid =~ /^\d+$/;
	my $out = `tasklist /FI "PID eq $pid" /FO CSV /NH 2>/dev/null`;
	return undef if $? != 0;
	return tasklist_image_matches($out, $expected);
}

# Pure parser (tested without Windows): tasklist /FO CSV /NH output for one PID -> 1 if its image
# name is the expected executable, 0 if it is another image or there is no such process.
sub tasklist_image_matches {
	my ($out, $expected) = @_;
	return 0 unless defined $out && defined $expected && length $expected;
	(my $name = $expected) =~ s{.*[\\/]}{};
	my ($image) = $out =~ /^"([^"]+)"/m;
	return 0 unless defined $image && length $image;
	return lc($image) eq lc($name) ? 1 : 0;
}


# Pure parser (tested without Windows): the first line whose PID's executable path is
# inside dir. Lines are "pid,path", as produced by find_pid_in_dir after it has already
# turned the process list into this simpler shape.
sub parse_pid_in_dir {
	my ($text, $dir) = @_;
	return 0 unless defined $dir && length $dir;
	(my $norm = $dir) =~ s{/}{\\}g;
	$norm =~ s{\\+$}{};
	return 0 unless length $norm;
	for my $line (split /\n/, $text // '') {
		$line =~ s/\r$//;
		next unless $line =~ /^(\d+),(.+)$/;
		my ($pid, $path) = ($1, $2);
		$path =~ s{/}{\\}g;
		next unless length($path) > length($norm);
		return $pid if lc(substr($path, 0, length($norm) + 1)) eq lc("$norm\\");
	}
	return 0;
}

# Finds a live process whose image name matches the expected executable and whose
# executable path is inside dir (a home's gamefiles folder, or a bot's working
# directory). Used to recognise a game or bot that is already running under a PID the
# agent no longer has recorded, so the agent does not launch a second copy on top of it.
# All live processes whose image is <expected> and whose executable lives in <dir>: the home's own
# copies. Reads the shared process list (see process_table); the old "where name=" form
# does not survive the Cygwin argv path on KCWIN. Returns an arrayref of PIDs (possibly empty),
# or undef when the process list could not be read (unknown, never "none").
sub find_all_pids_in_dir {
	my ($expected, $dir) = @_;
	return undef unless defined $expected && length $expected && defined $dir && length $dir;
	(my $name = $expected) =~ s{.*[\\/]}{};
	$name =~ s/"//g;
	return undef unless length $name;
	my $norm = to_windows_path($dir);
	$norm =~ s{\\+$}{};
	return undef unless length $norm;
	my $table = process_table() or return undef;
	my @pids;
	for my $row (@$table) {
		my $path = $row->{ExecutablePath} // '';
		next unless length $path;
		(my $p = $path) =~ s{/}{\\}g;
		next unless lc(substr($p, 0, length($norm) + 1)) eq lc("$norm\\");
		(my $base = $p) =~ s{.*\\}{};
		next unless lc($base) eq lc($name);
		push @pids, $row->{ProcessId};
	}
	return [ sort { $a <=> $b } @pids ];
}

sub find_pid_in_dir {
	my ($expected, $dir) = @_;
	my $all = find_all_pids_in_dir($expected, $dir);
	return undef unless defined $all;
	return @$all ? $all->[0] : 0;
}


# Executable path of a live PID, or undef if unknown (read from the shared process list).
sub pid_exe_path {
	my ($pid) = @_;
	return undef unless $pid && $pid =~ /^\d+$/;
	my $table = process_table() or return undef;
	for my $row (@$table) {
		return $row->{ExecutablePath} if $row->{ProcessId} == $pid && length($row->{ExecutablePath} // '');
	}
	return undef;
}

# Pure parser (tested without Windows): from process rows with ProcessId and ParentProcessId,
# every child, grandchild and so on of root_pid, nearest first.
sub parse_descendants {
	my ($root, @rows) = @_;
	my %kids;
	for my $row (@rows) {
		my ($pid, $parent) = ($row->{ProcessId} // '', $row->{ParentProcessId} // '');
		push @{ $kids{$parent} }, $pid if $pid =~ /^\d+$/ && $parent =~ /^\d+$/;
	}
	my (@found, @queue);
	@queue = ($root);
	while (@queue) {
		my $next = shift @queue;
		for my $kid (@{ $kids{$next} || [] }) {
			next if $kid == $root || grep { $_ == $kid } @found;
			push @found, $kid;
			push @queue, $kid;
		}
	}
	return @found;
}

# Descendants of a process (the launcher cmd.exe). Empty if the process list could not be read.
sub child_pids {
	my ($pid) = @_;
	return () unless $pid && $pid =~ /^\d+$/;
	my $table = process_table() or return ();
	return parse_descendants($pid, @$table);
}

sub port_owner_pids {
	my ($port) = @_;
	my $out = `netstat -ano 2>/dev/null`;
	return parse_netstat_owners($out, $port);
}

sub port_listening {
	my ($port) = @_;
	my @owners = port_owner_pids($port);
	return @owners ? 1 : 0;
}

sub kill_pid {
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^\d+$/;
	system("taskkill /F /T /PID $pid >nul 2>&1");
	my $ok = $? == 0 ? 1 : 0;
	forget_process_table();
	return $ok;
}

# Games are started with Win32_Process Create, so they are not children of the agent service and
# keep running when the service stops or restarts. Returns ($pid, $reason): $reason is '' on
# success, and on failure says which step failed. A visible window is not possible this way, so
# the foreground option is ignored here.
sub launch {
	my ($command, $workdir, $opt) = @_;
	my $script = $opt ? $opt->{script} : undef;
	my ($cmdline, $dir);
	if ($script) {
		# Start through a batch file (a game's serverStart.bat or a bot's _alsoRun.cmd). cmd.exe is
		# then the parent of what the batch file starts, so taskkill /T on it stops the whole tree.
		# The batch file does its own "cd /d", so no folder is passed.
		$cmdline = 'cmd.exe /c ' . to_windows_path($script);
	} else {
		my ($exe, $args) = split_command($command);
		return (0, 'launch failed: empty command') unless $exe;
		$cmdline = $exe =~ /\s/ ? "\"$exe\"" : $exe;
		$cmdline .= " $args" if defined $args && $args ne '';
		$dir = to_windows_path($workdir) if defined $workdir && length $workdir;
	}
	my $arguments = '@{ CommandLine = ' . ps_quote($cmdline) . ($dir ? '; CurrentDirectory = ' . ps_quote($dir) : '') . ' }';
	my ($out, $err) = run_ps('$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments ' . $arguments . '; "$($r.ProcessId),$($r.ReturnValue)"');
	forget_process_table();
	if ($err) {
		warn "GameManagerWin::launch: $err\n";
		return (0, "launch failed: $err");
	}
	my ($pid, $reason) = parse_ps_create_result($out);
	if (!$pid) {
		warn "GameManagerWin::launch: $reason\n" if $reason;
		return (0, "launch failed: $reason");
	}
	return ($pid, '');
}

1;
