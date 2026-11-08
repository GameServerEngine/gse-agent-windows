package GameManager;
# Game manager for GSE servers. Rules are in docs/server-lifecycle.md.
# State lives in one file per server: <state_dir>/status-<id>.
# Process and port checks are injected, so the rules can be tested without a real server.
use strict;
use warnings;
use File::Spec;

our $VERSION = '1.0';

# What the panel shows for each internal state. Every state this module can set must
# have an entry here; a state missing from this table would silently show as OFFLINE,
# which is how a CRASHED home once went invisible to the panel.
our %PANEL_STATUS_FOR = (
	RUNNING  => 'RUNNING',
	STARTING => 'STARTING',
	STOPPED  => 'OFFLINE',
	STOPPING => 'STOPPING',
	CRASHED  => 'CRASHED',
	FAILED   => 'FAILED',
	UNKNOWN  => 'UNKNOWN',
);

sub panel_status_for {
	my ($state) = @_;
	return $PANEL_STATUS_FOR{$state // ''} // 'OFFLINE';
}

sub new {
	my ($class, %args) = @_;
	my $self = {
		state_dir       => $args{state_dir} // die("state_dir required"),
		dir_for         => $args{dir_for},   # id -> game folder; state lives there as 'status'
		now             => $args{now}             // sub { time() },
		pid_alive       => $args{pid_alive}       // sub { 0 },
		pid_executable_matches => $args{pid_executable_matches} // sub { 1 },
		port_listening  => $args{port_listening}  // sub { 0 },
		port_owner_pids => $args{port_owner_pids} // sub { () },
		# A live process matching the expected executable name whose path is inside a
		# given directory (the home's gamefiles folder, or a bot's working directory).
		# Default is permissive-empty so command/state tests do not depend on it.
		find_pid_in_dir => $args{find_pid_in_dir} // sub { 0 },
		# Every live copy of this game's executable in its folder (arrayref, or undef if unknown).
		list_dir_pids   => $args{list_dir_pids},
		kill_pid        => $args{kill_pid}        // sub { 1 },
		launch          => $args{launch}          // sub { undef },
		foreground      => $args{foreground}      // sub { 0 },
		# Platform wiring supplies the real check; the portable manager default is
		# permissive so command/state tests do not depend on the host filesystem.
		executable_exists => $args{executable_exists} // sub { 1 },
		log             => $args{log}             // sub { },
		startup_timeout => $args{startup_timeout} // 180,
		restart_limit   => $args{restart_limit}   // 3,
		# Failed checks in a row before a RUNNING game counts as crashed (3 checks, so a blip is not a crash).
		miss_limit      => $args{miss_limit}      // 3,
		restart_window  => $args{restart_window}  // 1800,
	};
	return bless $self, $class;
}

# The home folder for a server, as the platform path that the folder helpers use.
sub home_dir {
	my ($self, $id) = @_;
	return $self->{dir_for} ? $self->{dir_for}->($id) : undef;
}

# State file: <game folder>\status when dir_for is given (per-server), else <state_dir>\status-<id>.
sub _path {
	my ($self, $id) = @_;
	# A bot lives in its game server folder; its state is bot-status there.
	if ($self->{dir_for} && $id =~ /^(\d+)-bot$/) { return File::Spec->catfile($self->{dir_for}->($1), 'bot-status'); }
	return File::Spec->catfile($self->{dir_for}->($id), 'status') if $self->{dir_for};
	return File::Spec->catfile($self->{state_dir}, "status-$id");
}

# Read the state file. Line 1: "<epoch>,<STATE>" (the panel reads this). Other lines: key=value.
sub read_state {
	my ($self, $id) = @_;
	my %h = (id => $id, state => 'STOPPED', ts => 0, pid => 0, port => 0, crashes => '', reason => '', command => '', workdir => '', desired => 'RUNNING', process_running => 0, port_listening => 0, session_running => 0, query_port_listening => 0, updated_at => 0);
	my $f = $self->_path($id);
	return \%h unless -e $f;
	open(my $fh, '<', $f) or return \%h;
	my $first = <$fh>;
	if (defined $first && $first =~ /^(\d+),(\w+)/) { $h{ts} = $1; $h{state} = $2; }
	while (my $line = <$fh>) {
		# Strip the line ending. Status files written on Windows may end lines with CRLF;
		# plain chomp would leave the \r on the value ("STOPPED\r") and the check would fail.
		$line =~ s/[\r\n]+\z//;
		if ($line =~ /^(\w+)=(.*)$/) { $h{$1} = $2; }
	}
	close $fh;
	return \%h;
}

# Atomic write: temp file, then rename, so a crash mid-write never leaves a broken file.
sub write_state {
	my ($self, $h) = @_;
	my $f = $self->_path($h->{id});
	my $tmp = "$f.tmp";
	open(my $fh, '>', $tmp) or die("cannot write $tmp: $!");
	print $fh "$h->{ts},$h->{state}\n";
	$h->{updated_at} = $h->{ts} unless defined $h->{updated_at} && $h->{updated_at};
	for my $k (qw(status pid port crashes reason command workdir desired process_running port_listening session_running query_port_listening updated_at launcher miss)) {
		$h->{status} = $h->{state} if $k eq 'status';
		print $fh "$k=" . (defined $h->{$k} ? $h->{$k} : '') . "\n";
	}
	close $fh;
	rename($tmp, $f) or die("cannot replace $f: $!");
	return 1;
}

# Logs any time a home's desired state actually changes (not just re-asserted to the
# same value), naming the calling sub and line via caller(), and this process's pid (two
# processes can both be writing status files - see gse_agent.pl's scheduler child - so
# the pid says which one), so a flip that should not have happened (e.g. a stale start
# request reasserting RUNNING) leaves a trace of exactly what wrote it, and from where.
sub _set_desired {
	my ($self, $h, $new) = @_;
	my $old = $h->{desired} // '';
	if ($old ne $new) {
		my @site   = caller(0);
		my @caller = caller(1);
		my $where = ($caller[3] // 'main') . ':' . ($site[2] // 0);
		$self->{log}->("$h->{id}: desired changed from $old to $new (by $where) pid=$$");
	}
	$h->{desired} = $new;
	return $h;
}

sub _set {
	my ($self, $h, $state, %extra) = @_;
	my $old = $h->{state} // '';
	$h->{state} = $state;
	$h->{ts} = $self->{now}->();
	$h->{$_} = $extra{$_} for keys %extra;
	$self->write_state($h);
	# Log only real changes, as "Server ID 49 RUNNING" (bots: "Bot for server ID 49 RUNNING").
	if ($old ne $state) {
		my $reason = $extra{reason} // '';
		my $line = ($h->{id} =~ /^(\d+)-bot$/) ? "Bot for server ID $1 $state" : "Server ID $h->{id} $state";
		$line .= ": $reason" if $reason ne '';
		$self->{log}->($line);
	}
	return $h;
}

# Kill the recorded PID and anything still holding the game port.
# Never kill a PID that is not the expected game executable: it may be an unrelated
# process that simply reused that PID number or that port after the game exited.
sub _kill_leftovers {
	my ($self, $h) = @_;
	# The cmd.exe that launched the batch file: taskkill /T on it also ends the game it started.
	if ($h->{launcher} && $self->{pid_alive}->($h->{launcher}) && $self->{pid_executable_matches}->($h->{launcher}, 'cmd.exe')) {
		$self->{kill_pid}->($h->{launcher});
		$self->{log}->("$h->{id}: killed launcher pid $h->{launcher}");
	}
	my $expected_exe = $self->_executable_path($h);
	if ($h->{pid} && $self->{pid_alive}->($h->{pid}) && $self->{pid_executable_matches}->($h->{pid}, $expected_exe)) {
		$self->{kill_pid}->($h->{pid});
	}
	for my $owner ($self->{port_owner_pids}->($h->{port})) {
		next if $owner == $h->{pid};
		next unless $self->{pid_executable_matches}->($owner, $expected_exe);
		$self->{kill_pid}->($owner);
		$self->{log}->("$h->{id}: killed port $h->{port} owner pid $owner");
	}
}

# Crash times kept as a comma-separated list of epoch seconds.
sub _crash_times { my ($h) = @_; return grep { /^\d+$/ } split(/,/, $h->{crashes} // ''); }

sub _recent_crashes {
	my ($self, $h) = @_;
	my $cutoff = $self->{now}->() - $self->{restart_window};
	return grep { $_ >= $cutoff } _crash_times($h);
}

# Reset the crash counter (and so any restart-limit-reached state) for one status id,
# if that status file exists. A fresh Start request, whether from the panel or from the
# agent's own startup, must not stay blocked by crash history from before the request.
sub _reset_restart_counter {
	my ($self, $id) = @_;
	return unless -e $self->_path($id);
	my $h = $self->read_state($id);
	return if ($h->{crashes} // '') eq '';
	$h->{crashes} = '';
	$self->write_state($h);
}

# Panel Start. Refuses only if the server is already up.
sub start {
	my ($self, $id, %opt) = @_;
	# Logged every time start() is called, regardless of outcome, with the full caller
	# chain (caller(0), caller(1), caller(2): sub name and line for each) and this
	# process's pid. start() always forces desired=RUNNING (see _set_desired below), so
	# any unexpected caller flips a home's desired state; this is what lets a log answer
	# "which code path called GameManager::start, and from where" instead of only seeing
	# the desired-change line below name start() itself as the writer.
	{
		my @chain;
		for my $depth (0 .. 2) {
			my @c = caller($depth);
			last unless @c;
			push @chain, ($c[3] // 'main') . ':' . ($c[2] // 0);
		}
		$self->{log}->("$id: GameManager::start called (pid $$) caller chain: " . join(' <- ', @chain));
	}
	my $h = $self->read_state($id);
	$h->{command} = $opt{command} // $h->{command};
	$h->{workdir} = $opt{workdir} // $h->{workdir};
	$h->{port}    = $opt{port}    // $h->{port};
	$self->_set_desired($h, 'RUNNING');
	# A Start command is a fresh request: crash history (and any restart-limit-reached
	# or FAILED state built on it) from before this command must not block it.
	$h->{crashes} = '';
	$self->_reset_restart_counter("$id-bot");
	# An agent restart must adopt an existing game before considering a new launch.
	# Adopting a PID (recorded, or found by its listening port) is only safe if that
	# PID really is the expected game executable; otherwise a reused PID or port could
	# belong to a different, unrelated process, and the agent must not touch it.
	my $expected_exe = $self->_executable_path($h);
	my ($pid, $probe_ok) = $self->_probe_pid($h);
	return { ok => 0, reason => 'cannot verify whether the server is already running; not launching' } unless $probe_ok;
	if (!$pid && $h->{port}) {
		my ($owner) = $self->{port_owner_pids}->($h->{port});
		# A listening owner is live by definition; do not require a second task
		# query, since the PID may be discoverable only through netstat after restart.
		if ($owner && $owner =~ /^\d+$/ && $self->{pid_executable_matches}->($owner, $expected_exe)) {
			$pid = $owner;
		}
	}
	if ($pid) {
		my $port_ok = $self->{port_listening}->($h->{port}) ? 1 : 0;
		$self->_set($h, $port_ok ? 'RUNNING' : 'STARTING', pid => $pid, desired => 'RUNNING',
			process_running => 1, port_listening => $port_ok, reason => 'reattached to existing game');
		return { ok => 0, attached => 1, pid => $pid, reason => 'already running' } if $port_ok;
		return { ok => 1, attached => 1, pid => $pid };
	}
	if ($h->{state} eq 'RUNNING' && $h->{pid} && $self->{pid_alive}->($h->{pid}) && $self->{port_listening}->($h->{port})) {
		return { ok => 0, reason => 'already running' };
	}
	$self->_kill_leftovers($h);
	if (!$self->_executable_present($h)) {
		$self->_set($h, 'FAILED', pid => 0, desired => 'RUNNING', reason => 'executable missing: ' . $self->_executable_path($h));
		return { ok => 0, reason => $h->{reason} };
	}
	$self->_set($h, 'STARTING', pid => 0, crashes => $h->{crashes}, command => $h->{command}, workdir => $h->{workdir}, port => $h->{port});
	$self->_write_script($h);
	return $self->_launch($h);
}

# serverStart.bat in the game folder: starts the game by hand, or as the restart script.
sub _script_path {
	my ($self, $h) = @_;
	return undef unless $self->{dir_for};
	return File::Spec->catfile($self->{dir_for}->($h->{id}), 'serverStart.bat');
}

# serverStart.bat in the game folder: cd to the run folder, then run the game command.
# No "start": the game stays a child of this cmd.exe, so the launched tree can be stopped as one.
sub _write_script {
	my ($self, $h) = @_;
	my $wd = $h->{workdir} // '';
	my $dir = $self->{dir_for} ? $self->{dir_for}->($h->{id}) : $wd;
	return 0 unless defined $dir && -d $dir;
	open(my $fh, '>', File::Spec->catfile($dir, 'serverStart.bat')) or return 0;
	print $fh "\@echo off\r\necho %date% %time% start > \"%~dp0last-start.txt\"\r\ncd /d \"$wd\"\r\n$h->{command}\r\necho %date% %time% exit %errorlevel% >> \"%~dp0last-start.txt\"\r\n";
	close $fh;
	return 1;
}


sub _launch {
	my ($self, $h) = @_;
	# launch() may be called in list context to get a reason naming which step failed
	# (building the command, running wmic, or wmic's own create call); injected test
	# doubles that return a plain scalar still work, since a single-scalar return in
	# list context just leaves $reason undef.
	my $script = $self->_script_path($h);
	my ($pid, $reason) = $self->{launch}->($h->{command}, $h->{workdir},
		{ foreground => $self->{foreground}->($h) ? 1 : 0, script => $script });
	if (!$pid) {
		$reason = (defined $reason && length $reason) ? $reason : 'launch failed';
		$self->_set($h, 'CRASHED', pid => 0, reason => $reason);
		return { ok => 0, reason => $reason };
	}
	# $pid is the launched cmd.exe. The game's own PID is found by the scheduler (by executable
	# name and folder), and the launcher is kept so stop can take the whole tree down.
	$self->_set($h, 'STARTING', pid => 0, launcher => $pid, reason => '');
	return { ok => 1, pid => $pid };
}


# Panel Stop. Writes STOPPED first, then kills everything for this server.
sub stop {
	my ($self, $id) = @_;
	my $h = $self->read_state($id);
	$self->_set_desired($h, 'STOPPED');
	$self->_kill_leftovers($h);
	# Keep the PID only if that process is still alive, so the status file never holds a stale PID.
	my $alive = ($h->{pid} && $self->{pid_alive}->($h->{pid})) ? $h->{pid} : 0;
	$self->_set($h, 'STOPPED', pid => $alive, reason => 'stop requested');
	my $port_open = $self->{port_listening}->($h->{port}) ? 1 : 0;
	return { ok => !$port_open, port_open => $port_open };
}

# Called once, for every home, on the first scheduler tick after the agent process
# starts. desired RUNNING must be tried again even if the previous agent run left the
# home FAILED with "restart limit reached": that reason describes crashes from the old
# run, not a verdict on whether the home can run now. Reuses start()'s own crash-counter
# reset, so this follows exactly the same fresh-start rule as a panel Start command.
sub agent_start_recover {
	my ($self, $id) = @_;
	my $h = $self->read_state($id);
	return $h->{state} if ($h->{desired} // 'RUNNING') eq 'STOPPED';
	my ($live_pid, $probe_ok) = $self->_probe_pid($h);
	return $h->{state} unless $probe_ok;
	my $pid_ok = $live_pid ? 1 : 0;
	my $port_ok = $self->{port_listening}->($h->{port}) ? 1 : 0;
	if ($pid_ok && $port_ok && $h->{state} eq 'RUNNING') {
		# Really running already: leave it, but a crash-limited bot still gets a fresh start.
		$self->_reset_restart_counter("$id-bot");
		if ($live_pid != ($h->{pid} // 0)) { $h->{pid} = $live_pid; $self->write_state($h); }
		return 'RUNNING';
	}
	my $result = $self->start($id, command => $h->{command}, workdir => $h->{workdir}, port => $h->{port});
	if ($result->{ok}) {
		my $h2 = $self->read_state($id);
		$self->_set($h2, $h2->{state}, reason => 'starting after agent start');
	}
	return $self->read_state($id)->{state};
}

sub set_desired {
	my ($self, $id, $desired) = @_;
	$desired = uc($desired // '');
	return { ok => 0, reason => 'desired must be RUNNING or STOPPED' } unless $desired eq 'RUNNING' || $desired eq 'STOPPED';
	my $h = $self->read_state($id);
	$self->_set_desired($h, $desired);
	$h->{reason} = 'desired state set to ' . $desired;
	$self->write_state($h);
	return { ok => 1, desired => $desired };
}

sub _executable_path {
	my ($self, $h) = @_;
	my $cmd = $h->{command} // '';
	return $1 if $cmd =~ /^\s*"([^"]+)"/;
	return $1 if $cmd =~ /^\s*(\S+)/;
	return '';
}

# A game or bot counts as alive if (a) its recorded PID is alive and is the expected
# executable, or (b) a copy of that executable is already running from this entry's own
# working directory. (b) covers an agent restart (or a launch check that ran too soon)
# losing track of a PID while the process it started keeps running; without it, the
# agent would conclude "process exited during startup" and launch a duplicate on top of
# a game or bot that never actually stopped. Returns the real, live PID, or 0.
# Returns ($pid, $known). $known is 0 when a process check itself failed (wmic, tasklist or
# netstat could not run). An unknown result must never be read as "not running".
# Returns ($pid, $known). $known is 0 when a process check itself failed (tasklist, netstat or
# wmic could not run). An unknown result must never be read as "not running".
# Order: the recorded pid, then whatever owns the game's port (netstat is reliable on KCWIN),
# then a folder scan by wmic (which cannot see game processes there, so it is last).
sub _probe_pid {
	my ($self, $h) = @_;
	my $expected_exe = $self->_executable_path($h);
	my $known = 1;
	if ($h->{pid} && $self->{pid_alive}->($h->{pid})) {
		my $match = $self->{pid_executable_matches}->($h->{pid}, $expected_exe);
		return ($h->{pid}, 1) if $match;
		$known = 0 unless defined $match;
	}
	if ($h->{port}) {
		for my $owner ($self->{port_owner_pids}->($h->{port})) {
			next unless $owner && $owner =~ /^\d+$/;
			my $match = $self->{pid_executable_matches}->($owner, $expected_exe);
			return ($owner, 1) if $match;
			$known = 0 unless defined $match;
		}
	}
	my $found = $self->{find_pid_in_dir}->($expected_exe, $h->{workdir});
	$known = 0 unless defined $found;
	my $pid = ($found && $found =~ /^\d+$/) ? $found : 0;
	return ($pid, $known);
}


sub _find_live_pid {
	my ($self, $h) = @_;
	my ($pid) = $self->_probe_pid($h);
	return $pid;
}


sub _executable_present {
	my ($self, $h) = @_;
	my $path = $self->_executable_path($h);
	return 0 unless $path ne '';
	return $self->{executable_exists}->($path) ? 1 : 0;
}

sub _publish_observation {
	my ($self, $h, $pid_ok, $port_ok, $reason) = @_;
	$h->{process_running} = $pid_ok ? 1 : 0;
	$h->{port_listening} = $port_ok ? 1 : 0;
	$h->{session_running} = 0;
	$h->{reason} = $reason if defined $reason;
	$h->{updated_at} = $self->{now}->();
	$self->write_state($h);
}

# Scheduler tick for one game server. Call every 5 seconds.
# Exit code of the last game run, from last-start.txt in the home folder (written by serverStart.bat).
# undef while the game is still running or the file is missing.
sub _last_exit_code {
	my ($self, $id) = @_;
	return undef unless $self->{dir_for};
	open(my $fh, '<', File::Spec->catfile($self->{dir_for}->($id), 'last-start.txt')) or return undef;
	my $last;
	while (my $line = <$fh>) { $last = $line; }
	close $fh;
	return undef unless defined $last && $last =~ /exit\s+(-?\d+)/;
	return $1;
}

# Keeps exactly one copy of a game: any other process from this home's folder with the game's
# executable is killed, but only once the kept copy is the one holding the game's port. Copies from
# other folders are never touched, and nothing is killed if the port owner is not the kept copy.
sub _kill_duplicates {
	my ($self, $h, $good) = @_;
	return unless $self->{list_dir_pids} && $good;
	my $all = $self->{list_dir_pids}->($self->_executable_path($h), $h->{workdir});
	return unless $all && @$all;
	my %owner = map { $_ => 1 } grep { defined } $self->{port_owner_pids}->($h->{port});
	return unless $owner{$good};
	for my $pid (@$all) {
		next if $pid == $good;
		$self->{log}->("$h->{id}: duplicate copy pid $pid from this home is not holding port $h->{port}; killing it");
		$self->{kill_pid}->($pid);
	}
}

# True while the cmd.exe that launched this server's batch file is still running.
sub _launcher_alive {
	my ($self, $h) = @_;
	return 0 unless $h->{launcher};
	return $self->{pid_alive}->($h->{launcher}) ? 1 : 0;
}

# Scheduler tick for one game server. Call every CHECK_INTERVAL_SECONDS.
sub tick {
	my ($self, $id) = @_;
	my $h = $self->read_state($id);
	my ($live_pid, $probe_ok) = $self->_probe_pid($h);
	my $pid_ok = $live_pid ? 1 : 0;
	# Keep the status file's pid pointed at the real running game, including when it was
	# only found by the directory scan (the recorded pid was lost or never matched).
	if ($pid_ok && $live_pid != ($h->{pid} // 0)) { $h->{pid} = $live_pid; $self->write_state($h); }
	my $port_raw = $self->{port_listening}->($h->{port});
	my $port_ok = $port_raw ? 1 : 0;
	$probe_ok = 0 unless defined $port_raw;
	my $desired = ($h->{desired} // 'RUNNING') eq 'STOPPED' ? 'STOPPED' : 'RUNNING';
	$self->_set_desired($h, $desired);
	if (!$probe_ok) {
		# A check could not run, so the real state is unknown. Change nothing and retry on the
		# next tick: never crash, relaunch or report STOPPED on a failed lookup.
		$self->_publish_observation($h, $pid_ok, $port_ok, 'status unknown: process check failed, retrying');
		return $self->read_state($id)->{state};
	}
	if ($desired eq 'STOPPED') {
		if ($pid_ok || $port_ok) { $self->stop($id); return 'STOPPING'; }
		$self->_set($h, 'STOPPED', pid => 0, reason => 'desired state STOPPED');
		return 'STOPPED';
	}
	if (($h->{state} // '') eq 'FAILED' && ($h->{reason} // '') eq 'restart limit reached') { return 'FAILED'; }
	if (($h->{state} // '') eq 'FAILED' && ($h->{reason} // '') =~ /^executable missing:/) { return 'FAILED'; }
	if (!$pid_ok && ($h->{state} // '') =~ /^(STOPPED|UNKNOWN|OFFLINE)$/) {
		return $self->start($id, command => $h->{command}, workdir => $h->{workdir}, port => $h->{port})->{ok} ? 'STARTING' : $self->read_state($id)->{state};
	}
	my $state = $h->{state};
	if ($state eq 'STARTING') {
		if ($pid_ok && $port_ok) { $self->_set($h, 'RUNNING', reason => ''); return 'RUNNING'; }
		my $timed_out = $self->{now}->() - $h->{ts} > $self->{startup_timeout};
		# The game can take a few seconds to appear after its launcher starts. While the launcher
		# (cmd.exe running serverStart.bat) is still alive, keep waiting. Only a launcher that has
		# exited, or a startup that runs past the timeout, is a failed start.
		if (!$pid_ok && $self->_launcher_alive($h) && !$timed_out) { return 'STARTING'; }
		if (!$pid_ok) { $self->_crash($h, 'process exited during startup'); return $self->read_state($id)->{state}; }
		if ($timed_out) { $self->_crash($h, 'startup timeout: port never answered'); return $self->read_state($id)->{state}; }
		return 'STARTING';
	}
	if (!$pid_ok && $state ne 'RUNNING' && $state ne 'STARTING' && $state ne 'CRASHED' && $state ne 'FAILED') {
		$self->_set($h, 'OFFLINE', pid => 0, reason => 'no process');
		$self->_publish_observation($h, 0, $port_ok);
		return $self->start($id, command => $h->{command}, workdir => $h->{workdir}, port => $h->{port})->{ok} ? 'STARTING' : $self->read_state($id)->{state};
	}
	if ($state eq 'RUNNING') {
		if ($pid_ok && $port_ok) {
			if (($h->{miss} // 0) != 0) { $h->{miss} = 0; $self->write_state($h); }
			$self->_kill_duplicates($h, $live_pid) unless $id =~ /-bot$/;
			# Publish the live process and port state every healthy tick, so the status file the panel
			# reads never says process_running=0 or port_listening=0 while the game is up.
			$self->_publish_observation($h, 1, 1, undef);
			return 'RUNNING';
		}
		# One failed check can be a blip (a slow netstat or tasklist). Only act after several in a row,
		# and never kill a game on a single miss.
		my $miss = ($h->{miss} // 0) + 1;
		if ($miss < $self->{miss_limit}) {
			$h->{miss} = $miss;
			$self->_publish_observation($h, $pid_ok, $port_ok, "check failed $miss of $self->{miss_limit}, confirming");
			return 'RUNNING';
		}
		$h->{miss} = 0;
		if (!$pid_ok && defined($self->_last_exit_code($id)) && $self->_last_exit_code($id) == 0) {
			# The game exited cleanly with code 0: BEC's scheduled #shutdown for a server restart.
			# That is a normal relaunch, not a crash, so no crash is counted.
			$self->{log}->("$id: game exited cleanly (scheduled restart), relaunching");
			return $self->start($id, command => $h->{command}, workdir => $h->{workdir}, port => $h->{port})->{ok} ? 'STARTING' : $self->read_state($id)->{state};
		}
		if (!$pid_ok) { $self->_crash($h, 'process died'); }
		else { $self->_crash($h, 'game port closed'); }
		return $self->read_state($id)->{state};
	}
	if ($state eq 'CRASHED') {
		# Retry only while under the restart limit; otherwise it stays FAILED until a manual Start.
		my $count = scalar($self->_recent_crashes($h));
		if ($count <= $self->{restart_limit} && $self->{now}->() - ($h->{ts} // 0) >= $self->_backoff($count)) {
			$self->_kill_leftovers($h);
			$self->_set($h, 'STARTING', pid => 0, reason => 'auto-restart');
			$self->_launch($self->read_state($id));
		}
		return $self->read_state($id)->{state};
	}
	$self->_publish_observation($self->read_state($id), $pid_ok, $port_ok);
	return $self->read_state($id)->{state};
}


# Crash backoff: 30s after the first crash, doubling, capped at 10 minutes.
sub _backoff {
	my ($self, $count) = @_;
	# No crash delay: a detected crash is restarted at once. Cleanup happens before relaunch.
	return 0;
}

sub _crash {
	my ($self, $h, $reason) = @_;
	my @times = $self->_recent_crashes($h);
	push @times, $self->{now}->();
	$h->{crashes} = join(',', @times);
	$self->_kill_leftovers($h);
	$self->_set($h, 'CRASHED', pid => 0, crashes => $h->{crashes}, reason => $reason);
	if (scalar(@times) >= $self->{restart_limit}) {
		$self->{log}->("$h->{id}: restart limit reached (" . scalar(@times) . " crashes in " . $self->{restart_window} . "s); staying FAILED");
		$self->_set($self->read_state($h->{id}), 'FAILED', reason => 'restart limit reached');
		return;
	}
	# Wait before the restart; tick() relaunches after the backoff.
	# Keep the actionable crash reason in the state file; the crash timestamp drives backoff.
}

# The bot is _alsoRun.cmd in the server folder: a normal batch file (cd to the bot folder, then the command).
# It is run through cmd.exe, so the bot is one process tree and stops with taskkill /T.
sub read_bot_config {
	my ($file) = @_;
	return undef unless defined $file && -e $file;
	my $dir = $file;
	$dir =~ s/[\\\/][^\\\/]+$//;
	# The bot is its own batch file (_alsoRun.cmd), which changes into the bot's folder itself.
	return { script => $file, workdir => $dir, executable => 'C:\\Windows\\System32\\cmd.exe', arguments => "/c \"$file\"" };
}


# Bot rules (PID only, never a port): the bot runs only while its game is RUNNING.
# STARTING -> RUNNING when its PID is alive; a dead PID while RUNNING is a CRASH and is restarted
# under the same restart limit as the game. When the game is not RUNNING, a running bot is stopped.
sub _bot_launch {
	my ($self, $bot, $cfg, $home_win) = @_;
	if ($cfg->{script}) {
		# Same method as the game: run the bot's batch file through cmd.exe. Its PID is the launcher,
		# which stays alive for as long as the bot runs, so the bot is tracked by that PID.
		my $script = $cfg->{script};
		my $wd = $cfg->{workdir} // $home_win;
		my ($pid, $reason) = $self->{launch}->("cmd.exe /c $script", $wd, { script => $script, foreground => 0 });
		if ($pid) { $self->_set($bot, 'STARTING', pid => $pid, command => "C:\\Windows\\System32\\cmd.exe /c $script", workdir => $wd, reason => ''); }
		else { $self->_set($bot, 'CRASHED', pid => 0, reason => 'bot launch failed: ' . ($reason // '')); }
		return;
	}
	my $wd = $cfg->{workdir} // '';
	$wd = $home_win if $wd eq '';
	$wd = "$home_win\\$wd" unless $wd =~ /^[A-Za-z]:/;
	my $exe = $cfg->{executable};
	my $full = $exe =~ /^[A-Za-z]:/ ? $exe : "$wd\\$exe";
	my $command = "\"$full\" " . ($cfg->{arguments} // '');
	my $pid = $self->{launch}->($command, $wd);
	if ($pid) { $self->_set($bot, 'STARTING', pid => $pid, command => $command, workdir => $wd, reason => ''); }
	else { $self->_set($bot, 'CRASHED', pid => 0, reason => 'bot launch failed'); }
	return;
}

sub ensure_bot {
	my ($self, $id, $cfg, $home_win) = @_;
	my $game = $self->read_state($id);
	my $bot  = $self->read_state("$id-bot");
	# A bot PID that is alive but is not actually the bot's own executable is treated as
	# not running, the same safety rule the game server uses, so it is never killed by
	# mistake. _find_live_pid also recognises a bot still running from its own working
	# directory under a PID the agent lost track of, the same rule used for the game.
	my $live_bot_pid = $self->_find_live_pid($bot);
	my $alive = $live_bot_pid ? 1 : 0;
	if ($alive && $live_bot_pid != ($bot->{pid} // 0)) { $bot->{pid} = $live_bot_pid; $self->write_state($bot); }
	if ($game->{state} ne 'RUNNING') {
		if ($alive) {
			$self->{kill_pid}->($bot->{pid});
			$self->_set($bot, 'STOPPED', pid => 0, reason => 'game not running');
		}
		return;
	}
	return unless $cfg;
	if ($alive) {
		$self->_set($bot, 'RUNNING', reason => '') if $bot->{state} eq 'STARTING';
		return;
	}
	if ($bot->{state} eq 'STARTING' || $bot->{state} eq 'RUNNING') {
		# The game restarted (or its PID is gone) after this bot launched: the bot exits with it.
		# That exit is expected, so relaunch the bot without counting a crash.
		my $game_pid_ok = ($game->{pid} && $self->{pid_alive}->($game->{pid})
			&& $self->{pid_executable_matches}->($game->{pid}, $self->_executable_path($game))) ? 1 : 0;
		if (($game->{ts} // 0) > ($bot->{ts} // 0) || !$game_pid_ok) {
			$self->_set($bot, 'STARTING', pid => 0, reason => 'game restarted, bot relaunched');
			$self->_bot_launch($self->read_state("$id-bot"), $cfg, $home_win);
			return;
		}
		# The bot process is gone: a crash. Count it, then restart unless the limit is reached.
		my @times = $self->_recent_crashes($bot);
		push @times, $self->{now}->();
		$bot->{crashes} = join(',', @times);
		$self->_set($bot, 'CRASHED', pid => 0, crashes => $bot->{crashes}, reason => 'bot process exited');
		if (scalar(@times) > $self->{restart_limit}) {
			$self->_set($bot, 'CRASHED', reason => 'bot restart limit reached');
			return;
		}
		$self->_bot_launch($self->read_state("$id-bot"), $cfg, $home_win);
		return;
	}
	if ($bot->{state} eq 'CRASHED') {
		return if scalar($self->_recent_crashes($bot)) > $self->{restart_limit};
		$self->_bot_launch($bot, $cfg, $home_win);
		return;
	}
	# No bot running and none recorded (or stopped): start it.
	$self->_bot_launch($bot, $cfg, $home_win);
	return;
}

1;
