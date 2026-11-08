package GameManagerWin;
# Windows process and port checks for GameManager. Uses tasklist, netstat, taskkill and wmic,
# which all run from Cygwin on the game server box.
use strict;
use warnings;

# Window style for launched games: Hidden in service mode, Normal (visible) in foreground mode.
our $WINDOW_STYLE = 'Hidden';
sub set_window_style { $WINDOW_STYLE = ($_[0] ? 'Normal' : 'Hidden'); return 1; }
sub foreground_enabled { return $WINDOW_STYLE eq 'Normal' ? 1 : 0; }

# Full path to wmic.exe. The Windows service's PATH does not contain
# C:\Windows\System32\wbem (confirmed on KCWIN), so exec('wmic', ...) fails there even
# though wmic.exe itself is present and works; every launch and lookup that went through
# the bare name 'wmic' then silently failed. The /cygdrive form is used (rather than the
# native "C:\Windows\System32\wbem\WMIC.exe" form) because run_wmic's exec() passes argv
# directly with no shell involved to do backslash-escaping for us, and Cygwin's own
# fork+exec path handling resolves /cygdrive paths to the native path internally, so this
# form needs no escaping and is exactly as portable between exec() and backticks.
# Confirmed working on KCWIN.
use constant WMIC_EXE => '/cygdrive/c/Windows/System32/wbem/WMIC.exe';

# Builds the "<CommandLine>","<CurrentDirectory>" parameter wmic's "process call create"
# alias expects (a single wmic argument: two quoted values joined by a comma).
#
# wmic's Win32_Process::Create has no window-style parameter at all, so there is no wmic
# equivalent of the old PowerShell foreground launch (Start-Process -WindowStyle Normal):
# a wmic-created process cannot be made to show a visible window this way, foreground or
# not. $foreground is kept as an explicit, separately-labelled branch (rather than folded
# away) specifically so this limitation stays visible in the code; today both branches
# produce the same command, and a real visible-window launch would need a different
# mechanism entirely (not addressed here - verify on a live host if ever needed again).
sub launch_create_param {
	my ($exe, $args, $workdir, $foreground) = @_;
	my $cmdline = $exe;
	$cmdline = "\"$exe\"" if $exe =~ /\s/;
	$cmdline .= " $args" if defined $args && $args ne '';
	# wmic splits its single alias value on commas, so a comma in the command or the folder
	# cannot be expressed in this form. Refuse rather than launch the wrong thing.
	return undef if $cmdline =~ /,/ || (defined $workdir && $workdir =~ /,/);
	if ($foreground) {
		# No-op branch: wmic cannot show a visible window (see the sub comment above).
	}
	# Form confirmed on KCWIN: exe-and-arguments,folder with no quotes around the pair.
	return "$cmdline,$workdir";
}


# Pure parser (tested without Windows). Reads the "Out Parameters" block that
# "wmic process call create" prints, e.g.:
#   Executing (Win32_Process)->Create()
#   Method execution successful.
#   Out Parameters:
#   instance of __PARAMETERS
#   {
#           ProcessId = 1234;
#           ReturnValue = 0;
#   };
# wmic prints this with CRLF line endings and blank lines around it. Returns
# ($pid, '') on success, or (0, $reason) on failure.
sub parse_wmic_create_result {
	my ($text) = @_;
	$text = '' unless defined $text;
	my ($rv) = $text =~ /ReturnValue\s*=\s*(\d+)/;
	return (0, 'no ReturnValue in wmic create output') unless defined $rv;
	return (0, "wmic process call create failed, ReturnValue=$rv") unless $rv == 0;
	my ($pid) = $text =~ /ProcessId\s*=\s*(\d+)/;
	return (0, 'wmic create succeeded (ReturnValue=0) but no ProcessId in output') unless defined $pid;
	return ($pid, '');
}

# Pure parser (tested without Windows). Parses "wmic ... /format:csv" output into a list
# of { header => value } row hashes. wmic's CSV output has a blank line, then a header
# row, then one row per result, then more blank lines, all CRLF-terminated; the header
# always starts with "Node" followed by the requested fields in alphabetical order
# (not the order they were requested in).
sub parse_wmic_csv {
	my ($text) = @_;
	my (@header, @rows);
	for my $line (split /\n/, (defined $text ? $text : '')) {
		$line =~ s/\r//g;   # wmic can end lines with \r\r\n; a stray \r breaks the last field (the PID)
		next if $line =~ /^\s*$/;
		my @fields = split /,/, $line;
		if (!@header) { @header = @fields; next; }
		next unless @fields == @header;
		my %row;
		@row{@header} = @fields;
		push @rows, \%row;
	}
	return @rows;
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

# Runs wmic with an explicit argument list (no shell involved: each element of @args
# becomes exactly one argv entry), and returns ($out, $error). Going through a shell would
# mean getting wmic's documented quoting (backslash-escaped quotes nested inside a
# quoted WQL clause, e.g. name=\"x.exe\") right twice over - once for the shell Cygwin's
# backticks would invoke, and once for wmic/CommandLineToArgvW. Passing argv directly
# through fork+exec instead means Cygwin's own exec-to-native translation (which already
# has to reproduce CommandLineToArgvW quoting for every native call) does that
# translation exactly once, which is the part that is actually well-tested.
#
# On success $error is '' and $out is wmic's stdout (which may legitimately be empty,
# e.g. a "where" clause that matches no process - that is not a failure). If exec()
# itself could not run wmic (the bug this fixes: PATH missing System32\wbem), the child
# exits 127 and $out is undef and $error names the problem; callers must log $error and
# treat the call as unknown, not as "no result found".
sub run_wmic {
	my (@args) = @_;
	my $pid = open(my $fh, '-|');
	return (undef, "run_wmic: fork failed: $!") unless defined $pid;
	if ($pid == 0) {
		open(STDERR, '>', '/dev/null');
		exec(WMIC_EXE, @args) or exit(127);
	}
	local $/ = undef;
	my $out = <$fh>;
	close $fh;
	if (($? >> 8) == 127) {
		return (undef, 'wmic not runnable: ' . WMIC_EXE);
	}
	return (defined $out ? $out : '', '');
}

# Converts a Cygwin path (/cygdrive/c/x/y) or a forward-slash path (C:/x/y) to the
# native Windows form that cmd.exe and wmic expect.
sub to_windows_path {
	my ($p) = @_;
	return '' unless defined $p;
	# Cygwin paths (/home/gameserver/49, /cygdrive/c/...) are real on this box, but cmd.exe and
	# wmic cannot read them. cygpath gives the native path the Windows side resolves.
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

# Does this PID belong to the expected executable? Uses tasklist (the image name), not wmic:
# on KCWIN wmic cannot see game processes at all, while tasklist and netstat can.
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
# turned wmic's CSV rows into this simpler shape.
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
# copies. Uses one unfiltered wmic listing (ProcessId, ExecutablePath); the "where name=" form
# does not survive the Cygwin argv path on KCWIN. Returns an arrayref of PIDs (possibly empty),
# or undef when wmic could not run (unknown, never "none").
sub find_all_pids_in_dir {
	my ($expected, $dir) = @_;
	return undef unless defined $expected && length $expected && defined $dir && length $dir;
	(my $name = $expected) =~ s{.*[\\/]}{};
	$name =~ s/"//g;
	return undef unless length $name;
	my $norm = to_windows_path($dir);
	$norm =~ s{\\+$}{};
	return undef unless length $norm;
	my ($out, $err) = run_wmic('process', 'get', 'ProcessId,ExecutablePath', '/format:csv');
	if ($err) {
		warn "GameManagerWin::find_all_pids_in_dir: $err\n";
		return undef;
	}
	my @pids;
	for my $row (parse_wmic_csv($out)) {
		my $pid = $row->{ProcessId} // '';
		my $path = $row->{ExecutablePath} // '';
		next unless $pid =~ /^\d+$/ && length $path;
		(my $p = $path) =~ s{/}{\\}g;
		next unless lc(substr($p, 0, length($norm) + 1)) eq lc("$norm\\");
		(my $base = $p) =~ s{.*\\}{};
		next unless lc($base) eq lc($name);
		push @pids, $pid;
	}
	return [ sort { $a <=> $b } @pids ];
}

sub find_pid_in_dir {
	my ($expected, $dir) = @_;
	my $all = find_all_pids_in_dir($expected, $dir);
	return undef unless defined $all;
	return @$all ? $all->[0] : 0;
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
	return $? == 0 ? 1 : 0;
}

# Service launches are detached through WMI so Stop-Service -Force cannot kill the game
# as a child of the agent. Foreground launches intentionally use the interactive console
# - except that, per launch_create_param's comment above, wmic has no way to actually
# give them one; that mismatch predates this change and is not fixed here.
# Returns ($pid, $reason): $reason is '' on success, and on failure names which step
# failed (building the command, running wmic, or wmic's own create call), so a caller's
# "launch failed" log line says what actually went wrong instead of just "launch failed".
sub launch {
	my ($command, $workdir, $opt) = @_;
	my $foreground = $opt && $opt->{foreground} ? 1 : 0;
	my $script = $opt ? $opt->{script} : undef;
	my $wd = to_windows_path($workdir);
	my $param;
	if ($script) {
		# Start through a batch file (a game's serverStart.bat or a bot's _alsoRun.cmd). cmd.exe
		# is then the parent of what the batch file starts, so taskkill /T on the launched
		# cmd.exe stops the whole tree. The batch file does its own "cd /d", and no wmic folder
		# argument is passed: on KCWIN wmic returns ReturnValue=9 (path not found) whenever a
		# folder is given, even C:\Windows, while "cmd.exe /c cd /d <folder> && ..." works.
		$param = 'cmd.exe /c ' . to_windows_path($script);
	} else {
		my ($exe, $args) = split_command($command);
		return (0, 'launch failed: empty command') unless $exe;
		$param = launch_create_param($exe, $args, $wd, $foreground);
		return (0, 'launch failed: command or folder contains a comma') unless defined $param;
	}
	my ($out, $err) = run_wmic('process', 'call', 'create', $param);
	if ($err) {
		warn "GameManagerWin::launch: $err\n";
		return (0, "launch failed: $err");
	}
	my ($pid, $reason) = parse_wmic_create_result($out);
	if (!$pid) {
		warn "GameManagerWin::launch: $reason\n" if $reason;
		return (0, "launch failed: $reason");
	}
	return ($pid, '');
}



1;
