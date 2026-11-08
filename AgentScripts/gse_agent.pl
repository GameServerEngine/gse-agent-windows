#!/usr/bin/perl
BEGIN { $ENV{PATH} = "/usr/bin:/bin:" . ($ENV{PATH} || ""); }
#
# GSE - Game Server Engine
# Copyright (C) 2008 - 2014 The GSP Development Team
#
#
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

use warnings;
use strict;

use Cwd qw(getcwd abs_path);	 # Fast way to get the current directory
use FindBin qw($Bin);
use lib $Bin;
use FindBin;
use lib $FindBin::Bin;
use GameManager;
use GameManagerWin;   # start/stop/monitor per docs/server-lifecycle.md

# The Windows service (cygrunsrv -p /bin/bash -a agent_service_wrapper.sh) is launched
# without a login shell, so /etc/profile never runs and PATH is whatever the Windows
# service environment provides (typically just system32/etc, with no Cygwin bin dirs).
# Every `cygpath`/`screen`/`wmic`/`tasklist` backtick call below relies on PATH already
# containing those Cygwin bin directories. Without this, cygpath silently returns "",
# which previously produced a screen command with an empty batch path (cmd.exe /c "").
# Prepend the install's own bin directories so these calls resolve regardless of how
# the agent was launched.
{
	my $gsp_root = abs_path("$Bin/..");
	if(defined($gsp_root) && $gsp_root ne "")
	{
		my @gsp_bin_dirs = grep { -d $_ } ("$gsp_root/bin", "$gsp_root/usr/bin", "$gsp_root/usr/sbin");
		$ENV{PATH} = join(":", @gsp_bin_dirs, ($ENV{PATH} || "")) if(@gsp_bin_dirs);
	}
}
use Frontier::Daemon::GSP::Forking;	# Forking XML-RPC server
use File::Copy;				   # Simple file copy functions
use File::Copy::Recursive
  qw(fcopy rcopy dircopy fmove rmove dirmove pathempty pathrmdir)
  ;							   # Used to copy whole directories
use File::Basename; # Used to get the file name or the directory name from a given path
use Crypt::XXTEA;	# Encryption between webpages and agent.
use Cfg::Config;	 # Config file
use Cfg::Preferences;   # Preferences file
use Fcntl ':flock';  # Import LOCK_* constants for file locking
use LWP::UserAgent; # Used for fetching URLs
use MIME::Base64;	# Used to ensure data travelling right through the network.
use Getopt::Long;	# Used for command line params.
use Path::Class::File;	# Used to handle files and directories.
use File::Glob qw(bsd_glob GLOB_NOSORT);
use File::Path qw(mkpath);
use Archive::Extract;	 # Used to handle archived files.
use File::Find;
use Schedule::Cron; # Used for scheduling tasks
use JSON::PP;
use Digest::SHA qw(hmac_sha256_hex);
use Sys::Hostname qw(hostname);
use File::Spec;
use POSIX ();
use GSE::Container::Runtime;

# Compression tools
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error); # Used to compress files to bz2.
use Compress::Zlib; # Used to compress file download buffers to zlib.
use Archive::Tar; # Used to create tar, tgz or tbz archives.
use Archive::Zip qw( :ERROR_CODES :CONSTANTS ); # Used to create zip archives.

# Current location of the agent.
use constant AGENT_RUN_DIR => getcwd();

# Load our config file values
use constant AGENT_KEY	  => $Cfg::Config{key};
use constant AGENT_IP	   => $Cfg::Config{listen_ip};
use constant AGENT_LOG_FILE => $Cfg::Config{logfile};
use constant AGENT_PORT	 => $Cfg::Config{listen_port};
# The release tag is written to release_version.txt by the update helper.
# Cfg/Config.pm is per-install and is not replaced by updates, so it is only a fallback.
use constant AGENT_VERSION => do {
	my $vf = AGENT_RUN_DIR . '/release_version.txt';
	my $v = '';
	if (open(my $vfh, '<', $vf)) { local $/; $v = <$vfh>; $v = '' unless defined $v; close($vfh); $v =~ s/\s+//g; }
	$v ne '' ? $v : $Cfg::Config{version};
};
use constant AGENT_PROTOCOL_VERSION => 1;
use constant WEB_ADMIN_API_KEY  => $Cfg::Config{web_admin_api_key};
use constant WEB_API_URL => $Cfg::Config{web_api_url};
use constant STEAM_DL_LIMIT => $Cfg::Config{steam_dl_limit};
use constant SCREEN_LOG_LOCAL  => $Cfg::Preferences{screen_log_local};
use constant DELETE_LOGS_AFTER  => $Cfg::Preferences{delete_logs_after};
use constant PORT_VALIDATION_ENABLED =>
  defined($Cfg::Preferences{PortValidationEnabled}) ? $Cfg::Preferences{PortValidationEnabled} : 1;
use constant STARTUP_VALIDATION_TIMEOUT =>
  defined($Cfg::Preferences{StartupValidationTimeoutSeconds}) ? $Cfg::Preferences{StartupValidationTimeoutSeconds} : 180;
use constant PORT_CHECK_INTERVAL_SECONDS =>
  defined($Cfg::Preferences{PortCheckIntervalSeconds}) ? $Cfg::Preferences{PortCheckIntervalSeconds} : 5;
use constant WINDOWS_HOME_ACL_ISOLATION =>
  defined($Cfg::Preferences{windows_home_acl_isolation}) ? $Cfg::Preferences{windows_home_acl_isolation} : 1;
use constant CONTAINER_RUNTIME_ENABLED =>
  defined($Cfg::Preferences{container_runtime_enabled}) && $Cfg::Preferences{container_runtime_enabled} eq "1" ? 1 : 0;
use constant CONTAINER_RUNTIME =>
  defined($Cfg::Preferences{container_runtime}) && $Cfg::Preferences{container_runtime} ne "" ? $Cfg::Preferences{container_runtime} : "docker";
use constant CONTAINER_RUNTIME_DOCKER_BINARY =>
  defined($Cfg::Preferences{container_runtime_docker_binary}) && $Cfg::Preferences{container_runtime_docker_binary} ne "" ? $Cfg::Preferences{container_runtime_docker_binary} : "docker";
use constant CONTAINER_DATA_ROOT =>
  defined($Cfg::Preferences{container_data_root}) && $Cfg::Preferences{container_data_root} ne "" ? $Cfg::Preferences{container_data_root} : File::Spec->catdir(AGENT_RUN_DIR, "containers");
use constant AGENT_PID_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'gsp_agent.pid');
use constant AGENT_RSYNC_GENERIC_LOG =>
  Path::Class::File->new(AGENT_RUN_DIR, 'rsync_update_generic.log');
use constant STEAM_LICENSE_OK => "Accept";
use constant STEAM_LICENSE	=> $Cfg::Config{steam_license};
use constant MANUAL_TMP_DIR   => Path::Class::Dir->new(AGENT_RUN_DIR, 'tmp');
use constant SHARED_GAME_TMP_DIR   => Path::Class::Dir->new(AGENT_RUN_DIR, 'shared');
use constant STEAMCMD_CLIENT_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'steamcmd');
use constant STEAMCMD_CLIENT_BIN =>
  Path::Class::File->new(STEAMCMD_CLIENT_DIR, 'steamcmd.exe');
use constant SCREEN_LOGS_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'screenlogs');
use constant WATCHDOG_MODE => 1;
# Install root: the agent may run from AgentScripts (Windows) or from the install folder (Linux).
use constant WD_ROOT_DIR => (AGENT_RUN_DIR =~ m{[/\\]AgentScripts/?$}i) ? Path::Class::Dir->new(AGENT_RUN_DIR)->parent : Path::Class::Dir->new(AGENT_RUN_DIR);
use constant WATCHDOG_DIR => WD_ROOT_DIR->subdir('watchdog');
use constant WD_HOMES_DIR => WD_ROOT_DIR->subdir('home');
use constant GAME_STARTUP_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'startups');
use constant SERVER_RUNTIME_DIR =>
	Path::Class::Dir->new(AGENT_RUN_DIR, 'runtime_status');
use constant AGENT_EVENTS_DIR =>
	Path::Class::Dir->new(AGENT_RUN_DIR, 'events');
use constant AGENT_EVENT_QUEUE_FILE =>
	Path::Class::File->new(AGENT_EVENTS_DIR, 'pending-events.jsonl');
use constant AGENT_UPDATE_STATE_FILE =>
	Path::Class::File->new(AGENT_RUN_DIR, 'gsp_agent_update_state.json');
use constant AGENT_UPDATE_REQUEST_FILE =>
	Path::Class::File->new(AGENT_RUN_DIR, 'gsp_agent_update_request.json');
use constant AGENT_UPDATE_LOG_FILE =>
	Path::Class::File->new(AGENT_RUN_DIR, 'gsp_agent_update.log');
use constant SCREENRC_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'gsp_screenrc');
use constant SCREENRC_FILE_BK =>
  Path::Class::File->new(AGENT_RUN_DIR, 'gsp_screenrc_bk');
use constant SCREEN_TYPE_HOME   => "HOME";
use constant SCREEN_TYPE_UPDATE => "UPDATE";
use constant FD_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'FastDownload');
use constant FD_ALIASES_DIR => Path::Class::Dir->new(FD_DIR, 'aliases');
use constant FD_PID_FILE => Path::Class::File->new(FD_DIR, 'fd.pid');
use constant SCHED_PID => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.pid');
use constant SCHED_TASKS => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.tasks');
use constant SCHED_LOG_FILE => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.log');
use constant USER_RUNNING_SCRIPT => getlogin || getpwuid($<) || "gameserver";

my $no_startups	= 0;
my $clear_startups = 0;
my $pidfile_arg = "";
our $log_std_out = 0;

GetOptions(
		   'no-startups'	=> \$no_startups,
		   'clear-startups' => \$clear_startups,
		   'pidfile=s' => \$pidfile_arg,
		   'log-stdout'	 => \$log_std_out
		  );

# Starting the agent as root user is not supported anymore.
if ($< == 0)
{
	print "ERROR: You are trying to start the agent as root user.";
	print "This is not currently supported. If you wish to start the";
	print "you need to create a normal user account for it.";
	exit 1;
}

### Logger function.
### @param line the line that is put to the log file.
sub logger
{
	my $logcmd	 = $_[0];
	my $also_print = 0;

	if (@_ == 2)
	{
		($also_print) = $_[1];
	}

	$logcmd = localtime() . " $logcmd\n";

	if ($log_std_out == 1)
	{
		print "$logcmd";
		return;
	}
	if ($also_print == 1)
	{
		print "$logcmd";
	}

	open(LOGFILE, '>>', AGENT_LOG_FILE)
	  or die("Can't open " . AGENT_LOG_FILE . " - $!");
	flock(LOGFILE, LOCK_EX) or die("Failed to lock log file.");
	seek(LOGFILE, 0, 2) or die("Failed to seek to end of file.");
	print LOGFILE "$logcmd" or die("Failed to write to log file.");
	flock(LOGFILE, LOCK_UN) or die("Failed to unlock log file.");
	close(LOGFILE) or die("Failed to close log file.");
}

sub agent_event_panel_url
{
	return $Cfg::Config{agent_event_url} if(defined($Cfg::Config{agent_event_url}) && $Cfg::Config{agent_event_url} ne "");
	if(defined($Cfg::Config{web_api_url}) && $Cfg::Config{web_api_url} ne "")
	{
		my $url = $Cfg::Config{web_api_url};
		$url =~ s/gsp_api\.php(?:\?.*)?$/agent_event_receiver.php/;
		return $url if($url =~ /agent_event_receiver\.php$/);
		$url =~ s/\/+$//;
		return "$url/agent_event_receiver.php";
	}
	return "";
}

sub agent_event_remote_server_id
{
	return $Cfg::Config{remote_server_id} if(defined($Cfg::Config{remote_server_id}) && $Cfg::Config{remote_server_id} =~ /^\d+$/);
	return $Cfg::Config{agent_remote_server_id} if(defined($Cfg::Config{agent_remote_server_id}) && $Cfg::Config{agent_remote_server_id} =~ /^\d+$/);
	return "";
}

sub prepare_server_content_runtime_without_decrypt
{
	my ($home_path) = @_;
	return if(!defined($home_path) || $home_path eq "");
	foreach my $dir (
		"$home_path/_gsp_content",
		"$home_path/_gsp_content/hooks",
		"$home_path/_gsp_content/generated",
		"$home_path/_gsp_content/runtime"
	)
	{
		mkpath($dir) if(!-d $dir);
	}
	my $pid_file = "$home_path/_gsp_content/runtime/server_content.pids";
	if(!-e $pid_file && open(my $fh, '>', $pid_file))
	{
		close($fh);
	}
}

sub append_server_content_pid_without_decrypt
{
	my ($pid_file, $pid, $role, $label) = @_;
	return unless(defined($pid_file) && $pid_file ne "" && defined($pid) && $pid =~ /^\d+$/);
	$role = "app" unless(defined($role) && $role =~ /^(watchdog|app|main_server)$/i);
	$label = "" unless(defined($label));
	if(open(my $fh, '>>', $pid_file))
	{
		print $fh "$role $pid $label\n";
		close($fh);
	}
}

sub import_legacy_also_run_pids_without_decrypt
{
	my ($home_path) = @_;
	return if(!defined($home_path) || $home_path eq "");
	prepare_server_content_runtime_without_decrypt($home_path);
	my $pid_file = "$home_path/_gsp_content/runtime/server_content.pids";
	my %seen;
	foreach my $legacy_pid_file ("$home_path/_alsoRun.pid", bsd_glob("$home_path/*/_alsoRun.pid"))
	{
		next if(!defined($legacy_pid_file) || $legacy_pid_file eq "" || !-f $legacy_pid_file);
		if(open(my $in, '<', $legacy_pid_file))
		{
			while(my $line = <$in>)
			{
				chomp($line);
				my ($pid) = $line =~ /(\d{2,})/;
				next unless(defined($pid) && !$seen{$pid});
				$seen{$pid} = 1;
				append_server_content_pid_without_decrypt($pid_file, $pid, "app", "legacy_alsoRun");
			}
			close($in);
		}
	}
}

sub cleanup_server_content_pid_group_without_decrypt
{
	my ($pid_file, $wanted_role) = @_;
	return if(!-f $pid_file);
	my @remaining;
	my %killed;
	my $in;
	if(!open($in, '<', $pid_file))
	{
		logger "Could not read server content PID file $pid_file: $!";
		return;
	}
	while(my $line = <$in>)
	{
		chomp($line);
		my $original = $line;
		$line =~ s/^\s+|\s+$//g;
		next if($line eq "");
		my ($pid) = $line =~ /(?:^|[^\d])(\d{2,})(?:[^\d]|$)/;
		my $role = ($line =~ /watchdog/i) ? "watchdog" : "app";
		$role = "main_server" if($line =~ /main[_-]?server/i);
		if(defined($pid) && $role eq $wanted_role)
		{
			next if($killed{$pid});
			$killed{$pid} = 1;
			logger "Stopping server-content $role PID $pid from $pid_file.";
			system("cmd /C taskkill /F /T /PID $pid >nul 2>&1");
			next;
		}
		push(@remaining, $original);
	}
	close($in);
	if(open(my $out, '>', $pid_file))
	{
		foreach my $line (@remaining)
		{
			print $out "$line\n";
		}
		close($out);
	}
}

sub cleanup_server_content_hooks_without_decrypt
{
	my ($home_path) = @_;
	return if(!defined($home_path) || $home_path eq "");
	import_legacy_also_run_pids_without_decrypt($home_path);
	my $pid_file = "$home_path/_gsp_content/runtime/server_content.pids";
	cleanup_server_content_pid_group_without_decrypt($pid_file, "watchdog");
	cleanup_server_content_pid_group_without_decrypt($pid_file, "app");
}

sub new_correlation_id
{
	return time() . "-" . $$ . "-" . int(rand(1000000000));
}

sub new_agent_event_uuid
{
	return "agent-" . new_correlation_id();
}

sub build_agent_event
{
	my ($event_type, $severity, $fields) = @_;
	$fields = {} unless(ref($fields) eq 'HASH');
	my %event = %$fields;
	$event{event_uuid} ||= new_agent_event_uuid();
	$event{timestamp_utc} ||= gmtime() . " UTC";
	$event{event_type} = $event_type;
	$event{severity} = $severity;
	$event{source} = "agent";
	$event{agent_os} ||= "Windows";
	$event{agent_hostname} ||= hostname();
	$event{remote_server_id} ||= agent_event_remote_server_id();
	$event{correlation_id} ||= new_correlation_id();
	foreach my $secret_key (qw(password control_password steam_password encryption_key database_password envVars environment_variables))
	{
		delete $event{$secret_key};
	}
	return \%event;
}

sub agent_event_json
{
	my ($event) = @_;
	return JSON::PP->new->ascii->canonical->encode($event);
}

sub send_agent_event
{
	my ($event) = @_;
	my $url = agent_event_panel_url();
	my $remote_server_id = agent_event_remote_server_id();
	return 0 if($url eq "" || $remote_server_id eq "" || AGENT_KEY eq "");
	my $body = agent_event_json($event);
	my $timestamp = time();
	my $signature = "sha256=" . hmac_sha256_hex($timestamp . "." . $body, AGENT_KEY);
	my $ua = LWP::UserAgent->new(timeout => 5, ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0x00 });
	my $response = $ua->post($url,
		'Content-Type' => 'application/json',
		'X-GSP-Agent-Id' => $remote_server_id,
		'X-GSP-Agent-Timestamp' => $timestamp,
		'X-GSP-Agent-Signature' => $signature,
		Content => $body
	);
	return ($response && $response->is_success) ? 1 : 0;
}

sub append_agent_event_queue
{
	my ($event) = @_;
	mkpath(AGENT_EVENTS_DIR) unless(-d AGENT_EVENTS_DIR);
	if(open(EVENTQ, '>>', AGENT_EVENT_QUEUE_FILE))
	{
		flock(EVENTQ, LOCK_EX);
		print EVENTQ agent_event_json($event) . "\n";
		flock(EVENTQ, LOCK_UN);
		close(EVENTQ);
	}
	if(-e AGENT_EVENT_QUEUE_FILE && -s AGENT_EVENT_QUEUE_FILE > 1048576)
	{
		rename(AGENT_EVENT_QUEUE_FILE, AGENT_EVENT_QUEUE_FILE . "." . time() . ".old");
	}
}

sub flush_agent_event_queue
{
	return 0 unless(-e AGENT_EVENT_QUEUE_FILE);
	open(EVENTQ, '<', AGENT_EVENT_QUEUE_FILE) or return 0;
	my @lines = <EVENTQ>;
	close(EVENTQ);
	my @remaining;
	my $delivered = 0;
	foreach my $line (@lines)
	{
		chomp($line);
		next if($line eq "");
		my $event = eval { JSON::PP->new->decode($line) };
		if($@ || ref($event) ne 'HASH')
		{
			next;
		}
		if(send_agent_event($event))
		{
			$delivered++;
		}
		else
		{
			push(@remaining, $line);
		}
	}
	if(open(EVENTQ, '>', AGENT_EVENT_QUEUE_FILE))
	{
		flock(EVENTQ, LOCK_EX);
		print EVENTQ join("\n", @remaining) . (@remaining ? "\n" : "");
		flock(EVENTQ, LOCK_UN);
		close(EVENTQ);
	}
	return $delivered;
}

sub queue_agent_event
{
	my ($event_type, $severity, $fields) = @_;
	my $event = build_agent_event($event_type, $severity, $fields);
	if(send_agent_event($event))
	{
		flush_agent_event_queue();
		return 1;
	}
	append_agent_event_queue($event);
	return 0;
}

sub agent_event_state_path
{
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	return Path::Class::File->new(AGENT_EVENTS_DIR, "state-$home_id.kv");
}

sub read_agent_event_state
{
	my ($home_id) = @_;
	my %state;
	my $file = agent_event_state_path($home_id);
	return \%state unless(-e $file);
	open(STATE, '<', $file) or return \%state;
	while(my $line = <STATE>)
	{
		chomp($line);
		next unless($line =~ /^([^=]+)=(.*)$/);
		$state{$1} = $2;
	}
	close(STATE);
	return \%state;
}

sub write_agent_event_state
{
	my ($home_id, $state) = @_;
	mkpath(AGENT_EVENTS_DIR) unless(-d AGENT_EVENTS_DIR);
	my $file = agent_event_state_path($home_id);
	open(STATE, '>', $file) or return 0;
	foreach my $key (sort keys %$state)
	{
		my $value = defined($state->{$key}) ? $state->{$key} : "";
		$value =~ s/[\r\n]//g;
		print STATE "$key=$value\n";
	}
	close(STATE);
	return 1;
}

sub record_server_state_transition
{
	my ($status_info) = @_;
	return unless(ref($status_info) eq 'HASH');
	my $home_id = $status_info->{home_id};
	return unless(defined($home_id) && $home_id =~ /^\d+$/);
	my $previous = read_agent_event_state($home_id);
	my $current_status = $status_info->{status} || "UNKNOWN";
	my $previous_status = $previous->{status} || "";
	my $now = time();
	my ($hint_time, $hint) = read_status_hint($home_id);
	my ($event_type, $severity);
	if($hint eq "AUTORESTARTING" && !($previous->{autorestart_pending} || 0))
	{
		($event_type, $severity) = ("automatic_restart_started", "warning");
		$previous->{autorestart_pending} = 1;
	}
	elsif(($previous->{autorestart_pending} || 0) && $current_status eq "ONLINE")
	{
		($event_type, $severity) = ("automatic_restart_succeeded", "info");
		delete $previous->{autorestart_pending};
	}
	elsif(($previous->{autorestart_pending} || 0) && $current_status eq "UNRESPONSIVE")
	{
		($event_type, $severity) = ("automatic_restart_failed", "error");
		delete $previous->{autorestart_pending};
	}
	elsif($previous_status eq "ONLINE" && $current_status eq "OFFLINE")
	{
		($event_type, $severity) = ($hint eq "STOPPING" || $hint eq "STOPPED") ? ("server_stop_confirmed", "info") : ("server_crash_detected", "warning");
	}
	elsif($previous_status ne "ONLINE" && $current_status eq "ONLINE")
	{
		($event_type, $severity) = ("server_start_confirmed", "info");
	}
	elsif($current_status eq "UNRESPONSIVE" && $previous_status ne "UNRESPONSIVE")
	{
		($event_type, $severity) = ("server_unresponsive", "warning");
	}
	elsif($current_status eq "WARNING" && $previous_status ne "WARNING")
	{
		$event_type = $status_info->{process_running} ? "server_process_found_without_port" : "server_port_found_without_managed_process";
		$severity = "warning";
	}
	elsif(($previous_status eq "WARNING" || $previous_status eq "UNRESPONSIVE") && $current_status eq "ONLINE")
	{
		($event_type, $severity) = ("server_port_restored", "notice");
	}
	if($event_type)
	{
		my $last_sent = $previous->{"sent_$event_type"} || 0;
		if($previous_status ne $current_status || ($now - $last_sent) > 900)
		{
			queue_agent_event($event_type, $severity, $status_info);
			$previous->{"sent_$event_type"} = $now;
		}
	}
	$previous->{status} = $current_status;
	$previous->{updated_at} = $now;
	write_agent_event_state($home_id, $previous);
}

# If for some reason the screenrc file doesn't exist, restore it from the backup copy
# I've seen this happen a few times
if (! -e SCREENRC_FILE)
{
	copy(SCREENRC_FILE_BK,SCREENRC_FILE);
}

# Check the screen logs folder
if (!-d SCREEN_LOGS_DIR && !mkdir SCREEN_LOGS_DIR)
{
	logger "Could not create " . SCREEN_LOGS_DIR . " directory $!.", 1;
	exit -1;
}

# Check the global shared games folder
if (!-d SHARED_GAME_TMP_DIR && !mkdir SHARED_GAME_TMP_DIR)
{
	logger "Could not create " . SHARED_GAME_TMP_DIR . " directory $!.", 1;
	exit -1;
}

# Rotate the log file
if (-e AGENT_LOG_FILE)
{
	if (-e AGENT_LOG_FILE . ".bak")
	{
		unlink(AGENT_LOG_FILE . ".bak");
	}
	logger "Rotating log file";
	move(AGENT_LOG_FILE, AGENT_LOG_FILE . ".bak");
	logger "New log file created";
}

logger "User running agent script is: " . USER_RUNNING_SCRIPT;

# create the directory for startup flags
if (!-e GAME_STARTUP_DIR)
{
	logger "Creating the startups directory " . GAME_STARTUP_DIR . "";
	if (!mkdir GAME_STARTUP_DIR)
	{
		my $message =
			"Failed to create the "
		  . GAME_STARTUP_DIR
		  . " directory - check permissions. Errno: $!";
		logger $message, 1;
		exit 1;
	}
}

if (!-d SERVER_RUNTIME_DIR && !mkdir SERVER_RUNTIME_DIR)
{
	logger "Could not create " . SERVER_RUNTIME_DIR . " directory $!.", 1;
	exit -1;
}

elsif ($clear_startups)
{
	opendir(STARTUPDIR, GAME_STARTUP_DIR);
	while (my $startup_file = readdir(STARTUPDIR))
	{

		# Skip . and ..
		next if $startup_file =~ /^\./;
		$startup_file = Path::Class::File->new(GAME_STARTUP_DIR, $startup_file);
		logger "Removing " . $startup_file . ".";
		unlink($startup_file);
	}
	closedir(STARTUPDIR);
}
# If the directory already existed check if we need to start some games.
elsif ($no_startups != 1)
{
	system('screen -wipe > /dev/null 2>&1');
	# Loop through all the startup flags, and call universal startup
	opendir(STARTUPDIR, GAME_STARTUP_DIR);
	logger "Reading startup flags from " . GAME_STARTUP_DIR . "";
	while (my $dirlist = readdir(STARTUPDIR))
	{

		# Skip . and .. plus runtime marker files that are not startup flags.
		next if $dirlist =~ /^\./;
		next if $dirlist =~ /^(?:status|pid)-/;
		logger "Found $dirlist";
		open(STARTFILE, '<', Path::Class::Dir->new(GAME_STARTUP_DIR, $dirlist))
		  || logger "Error opening start flag $!";
		while (<STARTFILE>)
		{
			my (
				$home_id,   $home_path,   $server_exe,
				$run_dir,   $startup_cmd, $server_port,
				$server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log
			   ) = split(',', $_);

			if (is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) ==
				1)
			{
				logger
				  "This server ($server_exe on $server_ip : $server_port) is already running (ID: $home_id).";
				next;
			}

			# Only restart servers whose saved status says they should be running.
			my $want_running = 0;
			if (open(my $stf, '<', Path::Class::File->new(GAME_STARTUP_DIR, "status-$home_id"))) {
				my $stl = <$stf>;
				close($stf);
				$want_running = 1 if(defined $stl && $stl =~ /(RUNNING|STARTING)/);
			}
			if (!$want_running) { logger "Not restarting home $home_id: saved status is not RUNNING or STARTING."; next; }
			logger "Starting server_exe $server_exe from home $home_path.";
			universal_start_without_decrypt(
										 $home_id,   $home_path,   $server_exe,
										 $run_dir,   $startup_cmd, $server_port,
										 $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log
										   );
		}
		close(STARTFILE);
	}
	closedir(STARTUPDIR);
}

# Create the pid file
open(PID, '>', AGENT_PID_FILE)
  or die("Can't write to pid file - " . AGENT_PID_FILE . "\n");
print PID "$$\n";
close(PID);
if(defined($pidfile_arg) && $pidfile_arg ne "")
{
	if(open(my $PIDARG, ">", $pidfile_arg))
	{
		print $PIDARG "$$\n";
		close($PIDARG);
	}
	else
	{
		logger "Cannot write requested pidfile $pidfile_arg: $!";
	}
}

logger "Game Server Engine - Agent started - "
  . AGENT_VERSION
  . " - port "
  . AGENT_PORT
  . " - PID $$", 1;

# Log fatal errors and the final exit status so a crash leaves a trace in the agent log.
my $agent_main_pid = $$;
$SIG{__DIE__} = sub { logger("FATAL: $_[0]"); };
END { logger("Agent process exiting, status $?.") if ($$ == $agent_main_pid); }
# Foreground runs (agent_launch.sh foreground) keep the main process serving requests.
my $foreground = (defined($pidfile_arg) && $pidfile_arg =~ /foreground/i) ? 1 : 0;
GameManagerWin::set_window_style($foreground);
# Stop previous scheduler process if exists
scheduler_stop();
# Create new object with default dispatcher for scheduled tasks
my $cron = new Schedule::Cron( \&scheduler_dispatcher, {
                                        nofork => 1,
                                        loglevel => 0,
                                        log => sub { }
                                       } );

$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # 5s checks; adaptive interval inside gm_monitor_all
# Run scheduler
if ($foreground) {
	# Run the scheduler in a child so this process keeps serving requests.
	my $sched_pid = fork();
	if (defined $sched_pid && $sched_pid == 0) { $cron->run( {detach=>0, pid_file=>SCHED_PID} ); exit 0; }
} else {
	$cron->run( {detach=>1, pid_file=>SCHED_PID} );
}

if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
{
	require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
	if(defined($FastDownload::Settings{autostart_on_agent_startup}) && $FastDownload::Settings{autostart_on_agent_startup} eq "1")
	{
		start_fastdl();
	}
}

my $d = Frontier::Daemon::GSP::Forking->new(
					 methods => {
							 is_screen_running				=> \&is_screen_running,
							 set_desired					=> \&set_desired,
						 server_status					=> \&server_status,
						 force_stop_server				=> \&force_stop_server,
						 universal_start				=> \&universal_start,
				 cpu_count						=> \&cpu_count,
				 rfile_exists					=> \&rfile_exists,
				 quick_chk						=> \&quick_chk,
				 steam_cmd						=> \&steam_cmd,
				 fetch_steam_version			=> \&fetch_steam_version,
				 installed_steam_version		=> \&installed_steam_version,
				 automatic_steam_update			=> \&automatic_steam_update,
				 get_log						=> \&get_log,
				 stop_server					=> \&stop_server,
				 send_rcon_command				=> \&send_rcon_command,
				 dirlist						=> \&dirlist,
				 dirlistfm						=> \&dirlistfm,
				 readfile						=> \&readfile,
				 writefile						=> \&writefile,
				 rebootnow						=> \&rebootnow,
				 what_os						=> \&what_os,
				 start_file_download			=> \&start_file_download,
				 is_file_download_in_progress	=> \&is_file_download_in_progress,
				 uncompress_file				=> \&uncompress_file,
				 discover_ips					=> \&discover_ips,
				 mon_stats						=> \&mon_stats,
				 exec							=> \&exec,
				 clone_home						=> \&clone_home,
				 remove_home					=> \&remove_home,
				 start_rsync_install			=> \&start_rsync_install,
				 rsync_progress					=> \&rsync_progress,
				 restart_server					=> \&restart_server,
				 sudo_exec						=> \&sudo_exec,
				 master_server_update			=> \&master_server_update,
				 secure_path					=> \&secure_path,
				 get_chattr						=> \&get_chattr,
				 ftp_mgr						=> \&ftp_mgr,
				 compress_files					=> \&compress_files,
				 stop_fastdl					=> \&stop_fastdl,
				 restart_fastdl					=> \&restart_fastdl,
				 fastdl_status					=> \&fastdl_status,
				 fastdl_get_aliases				=> \&fastdl_get_aliases,
				 fastdl_add_alias				=> \&fastdl_add_alias,
				 fastdl_del_alias				=> \&fastdl_del_alias,
				 fastdl_get_info				=> \&fastdl_get_info,
				 fastdl_create_config			=> \&fastdl_create_config,
				 agent_restart					=> \&agent_restart,
				 component_update				=> \&component_update,
				 agent_self_update				=> \&agent_self_update,
				 agent_release_update			=> \&agent_release_update,
				 agent_update_status			=> \&agent_update_status,
				 agent_version					=> \&agent_version,
				 agent_resource_snapshot			=> \&agent_resource_snapshot,
				 container_capabilities			=> \&container_capabilities,
				 container_create				=> \&container_create,
				 container_inspect				=> \&container_inspect,
				 container_start				=> \&container_start,
				 container_stop					=> \&container_stop,
				 container_restart				=> \&container_restart,
				 container_delete				=> \&container_delete,
				 scheduler_add_task				=> \&scheduler_add_task,
				 scheduler_del_task				=> \&scheduler_del_task,
				 scheduler_list_tasks			=> \&scheduler_list_tasks,
				 scheduler_edit_task			=> \&scheduler_edit_task,
				 get_file_part					=> \&get_file_part,
				 stop_update					=> \&stop_update,
				 shell_action					=> \&shell_action,
				 remote_query					=> \&remote_query,
				 send_steam_guard_code  		=> \&send_steam_guard_code,
				 steam_workshop					=> \&steam_workshop,
				 get_workshop_mods_info			=> \&get_workshop_mods_info,
				restic_job_start			=> \&restic_job_start,
				restic_job_status			=> \&restic_job_status
			 },
			 debug	 => 4,
			 LocalPort => AGENT_PORT,
			 LocalAddr => AGENT_IP,
			 ReuseAddr => '1'
) or die "Couldn't start GSE Agent: $!";

sub backup_home_log
{
	my ($home_id, $log_file, $console_log_file) = @_;

	my $home_backup_dir = SCREEN_LOGS_DIR . "/home_id_" . $home_id;

	if( ! -e $home_backup_dir )
	{
		if( ! mkdir $home_backup_dir )
		{
			logger "Can not create a backup directory at $home_backup_dir.";
			return 1;
		}
	}

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

	my $backup_file_name =  $mday . $mon . $year . '_' . $hour . 'h' . $min . 'm' . $sec . "s.log";

	my $output_path = $home_backup_dir . "/" . $backup_file_name;

	# Used for deleting log files older than DELETE_LOGS_AFTER
	my @file_list;
	my @find_dirs; # directories to search
	my $now = time(); # get current time
	my $days;
	if((DELETE_LOGS_AFTER =~ /^[+-]?\d+$/) && (DELETE_LOGS_AFTER > 0)){
		$days = DELETE_LOGS_AFTER; # how many days old
	}else{
		$days = 30; # how many days old
	}
	my $seconds_per_day = 60*60*24; # seconds in a day
	my $AGE = $days*$seconds_per_day; # age in seconds
	push (@find_dirs, $home_backup_dir);

	# Create local copy of log file backup in the log_backups folder and current user home directory if SCREEN_LOG_LOCAL = 1
	if(SCREEN_LOG_LOCAL == 1)
	{
		# Create local backups folder
		my $local_log_folder = Path::Class::Dir->new("logs_backup");

		if(!-e $local_log_folder){
			mkdir($local_log_folder);
		}

		# Add full path to @find_dirs so that log files older than DELETE_LOGS_AFTER are deleted
		my $fullpath_to_local_logs = Path::Class::Dir->new(getcwd(), "logs_backup");
		push (@find_dirs, $fullpath_to_local_logs);

		my $log_local = $local_log_folder . "/" . $backup_file_name;

		# Delete the local log file if it already exists
		if(-e $log_local){
			unlink $log_local;
		}

		# If the log file contains UPDATE in the filename, do not allow users to see it since it will contain steam credentials
		# Will return -1 for not existing
		my $isUpdate = index($log_file,SCREEN_TYPE_UPDATE);

		if($isUpdate == -1){
			copy($log_file,$log_local);
		}
	}

	# Delete all files in @find_dirs older than DELETE_LOGS_AFTER days
	find ( sub {
		my $file = $File::Find::name;
		if ( -f $file ) {
			push (@file_list, $file);
		}
	}, @find_dirs);

	# Include the custom console path - and also do a size check on it
	if(defined $console_log_file && $console_log_file ne ""){
		my $path_to_console_file = $console_log_file;
		if( -f $path_to_console_file){
			push (@file_list, $path_to_console_file);

			# Backup and delete this specific file as well if it's over 20MB
			my @stats = stat($path_to_console_file);
			if($stats[7] >= 20971520){
				if(SCREEN_LOG_LOCAL == 1){
					# Copy it to local log folder as well
					my $local_log_folder = Path::Class::Dir->new("logs_backup");
					my $log_local = $local_log_folder . "/" . $backup_file_name . "_console_log";
					copy($path_to_console_file, $log_local);
				}
				# Copy it to the main log folder as well
				move($path_to_console_file,$output_path . "_console_log");
			}
		}
	}

	for my $file (@file_list) {
		if( -f $file ){
			my @stats = stat($file);
			if ($now-$stats[9] > $AGE) {
				unlink $file;
			}
		}
	}

	move($log_file,$output_path);

	return 0;
}

sub create_screen_id
{
	my ($screen_type, $home_id) = @_;
	return sprintf("GSP_%s_%09d", $screen_type, $home_id);
}

sub create_screen_cmd
{
	my ($screen_id, $exec_cmd) = @_;
	$exec_cmd = replace_GSP_Env_Vars($screen_id, "", "", $exec_cmd);
	return
	  sprintf('screen -d -m -t "%1$s" -c ' . SCREENRC_FILE . ' -S %1$s %2$s',
			  $screen_id, $exec_cmd);

}

sub batch_escape_double_percent
{
	my ($value) = @_;
	$value = "" unless(defined($value));
	$value =~ s/%/%%/g;
	return $value;
}

# Escapes values that are written inside CMD set "name=value" assignments.
sub batch_assignment_value
{
	my ($value) = @_;
	$value = "" unless(defined($value));
	$value =~ s/\^/^^/g;
	$value = batch_escape_double_percent($value);
	$value =~ s/!/^^!/g;
	$value =~ s/&/^&/g;
	$value =~ s/\|/^|/g;
	$value =~ s/</^</g;
	$value =~ s/>/^>/g;
	$value =~ s/\r?\n/ /g;
	return $value;
}

# Normalizes the optional Windows START priority hint into one supported switch.
sub windows_start_priority_switch_without_decrypt
{
	my ($priority_class) = @_;
	$priority_class = "" unless(defined($priority_class));
	$priority_class =~ s/^\s+|\s+$//g;
	return ("", "") if($priority_class eq "");

	$priority_class =~ s{^/}{};
	my $priority_key = lc($priority_class);
	$priority_key =~ s/[\s_-]+//g;

	my %priority_switches = (
		low => "/low",
		idle => "/low",
		belownormal => "/belownormal",
		normal => "/normal",
		abovenormal => "/abovenormal",
		high => "/high",
		realtime => "/realtime",
	);

	return ($priority_switches{$priority_key}, "") if(exists($priority_switches{$priority_key}));
	return (undef, "unsupported Windows START priority class: $priority_class");
}

# Derives the pathless executable name used after the BAT changes into
# GAME_WORKDIR, and rejects names that are unsafe to emit into CMD.
sub windows_relative_game_executable_name_without_decrypt
{
	my ($game_file) = @_;
	$game_file = "" unless(defined($game_file));
	$game_file =~ s/^\s+|\s+$//g;
	return (undef, "game executable path is required") if($game_file eq "");
	return (undef, "game executable path must not contain control characters") if($game_file =~ /[\x00-\x1f\x7f]/);
	return (undef, "game executable path must not contain quotes") if($game_file =~ /"/);
	return (undef, "game executable path must not end with a separator") if($game_file =~ /[\\\/]\z/);

	my ($relative_name) = $game_file =~ /([^\\\/]+)\z/;
	return (undef, "game executable filename is required") unless(defined($relative_name) && $relative_name ne "");
	return (undef, "game executable filename must not contain traversal") if($relative_name eq "." || $relative_name eq "..");
	return (undef, "game executable filename must not contain a Windows drive or stream prefix") if($relative_name =~ /:/);
	return (undef, "game executable filename must not contain Windows wildcard characters") if($relative_name =~ /[*?]/);
	return (undef, "game executable filename must not contain BAT metacharacters") if($relative_name =~ /[&|<>^%!]/);
	return (undef, "game executable filename must not end with a dot or space") if($relative_name =~ /[. ]\z/);
	return (undef, "game executable filename must contain only letters, digits, dot, underscore, and hyphen")
		if($relative_name !~ /\A[A-Za-z0-9._-]+\z/);

	my $reserved_check = $relative_name;
	$reserved_check =~ s/[. ].*\z//;
	return (undef, "game executable filename uses a reserved Windows device name")
		if($reserved_check =~ /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$/i);

	return ($relative_name, "");
}

# Builds the stable Windows console title prefix shared by the generated BAT and
# the agent-side Start/Stop verification code.
sub windows_lifecycle_instance_without_decrypt
{
	my ($management_home) = @_;
	$management_home = "" unless(defined($management_home));
	$management_home =~ s![\\/]+$!!;
	return basename($management_home);
}

sub windows_lifecycle_title_without_decrypt
{
	my ($management_home, $role) = @_;
	$role = "" unless(defined($role));
	return windows_lifecycle_instance_without_decrypt($management_home) . "_$role";
}

sub windows_lifecycle_bot_marker_without_decrypt
{
	my ($management_home) = @_;
	return "GSE_BOT_SUPERVISOR_" . windows_lifecycle_instance_without_decrypt($management_home);
}

# Returns PIDs whose verbose task-list window title matches the exact lifecycle
# title. The optional image filter is used for the watchdog cmd.exe lookup.
sub find_windows_pids_by_window_title_without_decrypt
{
	my ($title, $image_name) = @_;
	my @pids;
	return @pids unless(defined($title) && $title ne "");
	$title =~ s/"/ /g;
	my $image_filter = "";
	if(defined($image_name) && $image_name ne "")
	{
		$image_name =~ s/"/ /g;
		$image_filter = qq! /FI "IMAGENAME eq $image_name"!;
	}
	my $output = `tasklist /V$image_filter /FI "WINDOWTITLE eq $title" /NH 2>/dev/null`;
	foreach my $line (split(/\r?\n/, $output || ""))
	{
		next if($line =~ /^\s*INFO:/i);
		next if(index($line, $title) < 0);
		push(@pids, $1) if($line =~ /^\s*\S+\s+([0-9]+)\s+/);
	}
	my %seen;
	return grep { !$seen{$_}++ } @pids;
}

sub window_title_is_present_without_decrypt
{
	my ($title, $image_name) = @_;
	return find_windows_pids_by_window_title_without_decrypt($title, $image_name) ? 1 : 0;
}

# Finds the per-home BOT supervisor cmd.exe by its generated command-line marker.
sub find_windows_cmd_pids_by_command_marker_without_decrypt
{
	my ($marker) = @_;
	my @pids;
	return @pids unless(defined($marker) && $marker ne "");
	$marker =~ s/[\r\n"]//g;
	my $marker_lc = lc($marker);
	my $current_command = "";
	my $output = `wmic process where "name='cmd.exe'" get ProcessId,CommandLine /FORMAT:LIST 2>/dev/null`;
	foreach my $line (split(/\r?\n/, $output || ""))
	{
		if($line =~ /^CommandLine=(.*)$/i)
		{
			$current_command = lc($1 || "");
			next;
		}
		if($line =~ /^ProcessId=([0-9]+)$/i)
		{
			if(index($current_command, $marker_lc) >= 0 && index($current_command, "bot-supervisor") >= 0 && index($current_command, "serverstart.bat") >= 0)
			{
				push(@pids, $1);
			}
			$current_command = "";
		}
	}
	my %seen;
	return grep { !$seen{$_}++ } @pids;
}

sub command_marker_is_present_without_decrypt
{
	my ($marker) = @_;
	return find_windows_cmd_pids_by_command_marker_without_decrypt($marker) ? 1 : 0;
}

# Waits for serverStart.bat to set its watchdog console title, then returns the
# actual long-lived cmd.exe PID that Stop must later terminate.
sub wait_for_watchdog_cmd_pid_without_decrypt
{
	my ($management_home, $max_wait_seconds) = @_;
	$max_wait_seconds = 15 unless(defined($max_wait_seconds) && $max_wait_seconds =~ /^[0-9]+$/ && $max_wait_seconds > 0);
	my $watchdog_title = windows_lifecycle_title_without_decrypt($management_home, "watchdog");
	for(my $i = 0; $i < $max_wait_seconds; $i++)
	{
		my @pids = find_windows_pids_by_window_title_without_decrypt($watchdog_title, "cmd.exe");
		return $pids[0] if(@pids);
		sleep 1;
	}
	return "";
}

# Confirms the named HOME screen exists and remains present for the post-launch
# grace period. This is the authoritative Windows Start success invariant.
sub wait_for_home_screen_survival_without_decrypt
{
	my ($home_id, $grace_seconds) = @_;
	$grace_seconds = 3 unless(defined($grace_seconds) && $grace_seconds =~ /^[0-9]+$/ && $grace_seconds > 0);
	for(my $i = 0; $i < $grace_seconds; $i++)
	{
		return 0 if(is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) != 1);
		sleep 1;
	}
	return is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;
}

sub write_home_pid_file_without_decrypt
{
	my ($home_path, $pid_name, $pid) = @_;
	return 0 unless(defined($home_path) && $home_path ne "" && defined($pid_name) && $pid_name =~ /^(?:watchdog|bot|game)\.pid$/);
	return 0 unless(defined($pid) && $pid =~ /^\d+$/);
	my $pid_file = Path::Class::File->new($home_path, $pid_name);
	if(open(my $PIDFILE, '>', $pid_file))
	{
		print {$PIDFILE} "$pid\n";
		close($PIDFILE);
		return 1;
	}
	logger "Unable to write $pid_name in $home_path: $!";
	return 0;
}

sub create_bot_screen_cmd
{
	my ($screen_id, $management_home) = @_;
	my ($bot_dir, $bot_exe, $bot_args) = ('', '', '');
	foreach my $bot_file ("$management_home/_alsoRun.cmd", "$management_home/_alsorun.cmd")
	{
		next unless(-e $bot_file);
		open(my $bf, '<', $bot_file) or next;
		while(my $bl = <$bf>)
		{
			$bl =~ s/[\r\n]+$//;
			$bot_dir  = $1 if($bl =~ /^workdir=(.*)$/);
			$bot_exe  = $1 if($bl =~ /^executable=(.*)$/);
			$bot_args = $1 if($bl =~ /^arguments=(.*)$/);
		}
		close($bf);
		last;
	}
	return '' if($bot_dir eq '' || $bot_exe eq '');
	my $mgmt_win = clean(`cygpath -wa "$management_home"`);
	chomp($mgmt_win);
	return '' if($mgmt_win eq '');
	my $bot_dir_win = ($bot_dir =~ /^[A-Za-z]:/) ? $bot_dir : $mgmt_win . '\\' . $bot_dir;
	my @b = (
		'@echo off',
		'REM Bot loop. Restarts the bot if it stops. Stops when status.stopped appears.',
		':BOT_LOOP',
		"if exist \"$mgmt_win\\status.stopped\" exit /b 0",
		"cd /d \"$bot_dir_win\"",
		"\"$bot_exe\" $bot_args",
		'ping -n 11 127.0.0.1 >nul',
		'goto BOT_LOOP',
	);
	open(my $bo, '>', "$management_home/botStart.bat") or return '';
	print $bo join("\r\n", @b) . "\r\n";
	close($bo);
	return sprintf('screen -d -m -t "%1$s_bot" -c ' . SCREENRC_FILE . ' -S %1$s_bot /cygdrive/c/Windows/System32/cmd.exe /c "%2$s\\botStart.bat"', $screen_id, $mgmt_win);
}

sub create_screen_cmd_loop
{
	my ($screen_id, $management_home, $game_file, $game_args, $game_workdir, $game_port, $priority_class, $affinity_mask, $envVars) = @_;
	my $server_start_batfile = Path::Class::File->new($management_home, 'serverStart.bat');
	$game_file    = replace_GSP_Env_Vars($screen_id, '', '', $game_file);
	$game_args    = replace_GSP_Env_Vars($screen_id, '', '', $game_args);
	$game_workdir = replace_GSP_Env_Vars($screen_id, '', '', $game_workdir);

	my $management_win = clean(`cygpath -wa "$management_home"`);
	chomp($management_win);
	if($management_win eq '')
	{
		logger "Unable to resolve Windows path for $management_home (cygpath returned nothing).";
		return '';
	}
	my $server_start_batfile_windows = $management_win . '\\serverStart.bat';

	# Optional bot, from the settings written when bot content was installed.
	my ($bot_dir, $bot_exe, $bot_args) = ('', '', '');
	foreach my $bot_file ("$management_home/_alsoRun.cmd", "$management_home/_alsorun.cmd")
	{
		next unless(-e $bot_file);
		open(my $bf, '<', $bot_file) or next;
		while(my $bl = <$bf>)
		{
			$bl =~ s/[\r\n]+$//;
			$bot_dir  = $1 if($bl =~ /^workdir=(.*)$/);
			$bot_exe  = $1 if($bl =~ /^executable=(.*)$/);
			$bot_args = $1 if($bl =~ /^arguments=(.*)$/);
		}
		close($bf);
		last;
	}
	my $has_bot = 0; # bot runs in its own screen session
	my $bot_dir_win = !$has_bot ? '' : (($bot_dir =~ /^[A-Za-z]:/) ? $bot_dir : $management_win . '\\' . $bot_dir);
	my $bot_exe_win = !$has_bot ? '' : $bot_dir_win . '\\' . $bot_exe;

	# Game paths come from the panel in Cygwin form (/home/...); the script needs Windows form (C:\...).
	my $to_win = sub { my ($p) = @_; return $p unless(defined $p && $p =~ m{[/\\]home[/\\]gameserver[/\\]\d+(?:[/\\](.*))?$}); my $rel = defined($1) ? $1 : ''; $rel =~ s{/}{\\}g; return $management_win . $rel; };
	# The agent decides where the game files are. The panel's paths are ignored; only the executable name is used.
	my $exe_base = defined($game_file) ? $game_file : '';
	$exe_base =~ s{.*[\\/]}{};
	$game_workdir = $management_win . '\gamefiles';
	$game_file = $game_workdir . '\\' . $exe_base;
	my $mg = $management_win;
	my @b;
	push @b, '@echo off';
	push @b, 'REM GSE game server start script. Written by the agent.';
	push @b, 'REM It starts the game and bot if they are not running, and checks again every 10 seconds.';
	push @b, 'REM To stop the server, create the file status.stopped in this folder.';
	push @b, 'setlocal EnableDelayedExpansion';
	push @b, "cd /d \"$game_workdir\"";
	push @b, ':TOP';
	push @b, "if exist \"$mg\\status.stopped\" goto STOP";
	push @b, 'set "GAME_PID="';
	push @b, "if exist \"$mg\\game.pid\" set /p GAME_PID=<\"$mg\\game.pid\"";
	push @b, 'set "GAME_RUNNING=0"';
	push @b, 'if defined GAME_PID tasklist /FI "PID eq !GAME_PID!" | findstr "!GAME_PID!" >nul 2>&1 && set "GAME_RUNNING=1"';
	push @b, 'if "!GAME_RUNNING!"=="0" (';
	push @b, "  > \"$mg\\game.pid\" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"\$p = Start-Process -FilePath '$game_file' -ArgumentList '$game_args' -WorkingDirectory '$game_workdir' -PassThru; \$p.Id\"";
	push @b, ')';
	if($has_bot)
	{
		push @b, 'set "BOT_PID="';
		push @b, "if exist \"$mg\\bot.pid\" set /p BOT_PID=<\"$mg\\bot.pid\"";
		push @b, 'set "BOT_RUNNING=0"';
		push @b, 'if defined BOT_PID tasklist /FI "PID eq !BOT_PID!" | findstr "!BOT_PID!" >nul 2>&1 && set "BOT_RUNNING=1"';
		push @b, 'if "!BOT_RUNNING!"=="0" (';
		push @b, "  > \"$mg\\bot.pid\" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"\$p = Start-Process -FilePath '$bot_exe_win' -ArgumentList '$bot_args' -WorkingDirectory '$bot_dir_win' -PassThru; \$p.Id\"";
		push @b, ')';
	}
	push @b, 'ping -n 11 127.0.0.1 >nul';
	push @b, 'goto TOP';
	push @b, ':STOP';
	push @b, 'if exist "' . $mg . '\\game.pid" for /f %%p in ("' . $mg . '\\game.pid") do taskkill /F /T /PID %%p >nul 2>&1';
	push @b, 'if exist "' . $mg . '\\bot.pid" for /f %%p in ("' . $mg . '\\bot.pid") do taskkill /F /T /PID %%p >nul 2>&1';
	push @b, 'exit /b 0';

	open(my $sb, '>', $server_start_batfile) or do { logger "Unable to create $server_start_batfile: $!"; return ''; };
	print $sb join("\r\n", @b) . "\r\n";
	close($sb);
	chmod 0755, $server_start_batfile;

	return
	  sprintf('screen -d -m -t "%1$s" -c ' . SCREENRC_FILE . ' -S %1$s /cygdrive/c/Windows/System32/cmd.exe /c "%2$s"',
			  $screen_id, $server_start_batfile_windows);
}

sub replace_GSP_Env_Vars{
	# This function replaces constants from environment variables set in the XML
	my ($screen_id, $homeid, $homepath, $exec_cmd, $game_key, $management_homepath) = @_;

	# Handle steam specific replacements
	if(defined $screen_id && $screen_id ne ""){
		my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
		my $steamInsFile = $screen_id_for_txt_update . "_install.txt";
		my $steamCMDPath = STEAMCMD_CLIENT_DIR;
		my $fullPath = Path::Class::File->new($steamCMDPath, $steamInsFile);

		my $windows_steamCMDPath= clean(`cygpath -wa $steamCMDPath`);
		$windows_steamCMDPath =~ s#/#\\#g;

		# If the install file exists, the game can be auto updated, else it will be ignored by the game for improper syntax
		# To generate the install file, the "Install/Update via Steam" button must be clicked on at least once!
		if(-e $fullPath){
			$exec_cmd =~ s/{GSP_STEAM_CMD_DIR}/$windows_steamCMDPath/g;
			$exec_cmd =~ s/{STEAMCMD_INSTALL_FILE}/$steamInsFile/g;
		}
	}

	# Handle home directory replacement
	if(defined $homepath && $homepath ne ""){
		$exec_cmd =~ s/{GSP_HOME_DIR}/$homepath/g;
	}

	# Handle windows directory replacement
	if(defined $homepath && $homepath ne ""){
		my $windows_home_path = clean(`cygpath -wa "$homepath"`);
		$exec_cmd =~ s/{GSP_HOME_DIR_WINDOWS}/$windows_home_path/g;
	}

	# Under the game-key payload contract, legacy HOME variables continue to
	# point at game_root. New management-home variables expose the parent home.
	if(defined $management_homepath && $management_homepath ne ""){
		$exec_cmd =~ s/{GSP_MANAGEMENT_HOME_DIR}/$management_homepath/g;
		$exec_cmd =~ s/{GSE_MANAGEMENT_HOME_DIR}/$management_homepath/g;
		my $windows_management_home_path = clean(`cygpath -wa "$management_homepath"`);
		$exec_cmd =~ s/{GSP_MANAGEMENT_HOME_DIR_WINDOWS}/$windows_management_home_path/g;
		$exec_cmd =~ s/{GSE_MANAGEMENT_HOME_DIR_WINDOWS}/$windows_management_home_path/g;
	}

	# Handle global game shared directory replacement
	if(defined $game_key && $game_key ne ""){
		my $readable_game_key = lc(substr($game_key, 0, rindex($game_key,"_")));
		my $shared_path = Path::Class::Dir->new(SHARED_GAME_TMP_DIR, $readable_game_key);
		# Create the folder if it doesn't exist
		if (!-d $shared_path && !mkdir $shared_path)
		{
			logger "Could not create " . $shared_path . " directory $!.", 1;
		}

		$exec_cmd =~ s/{GSP_GAME_SHARED_DIR}/$shared_path/g;
	}

	return $exec_cmd;
}

# Validates the XML game_key before it can become a game payload directory.
sub validate_game_key_without_decrypt
{
	my ($game_key) = @_;
	return (0, "game_key is required") unless(defined($game_key));
	return (0, "game_key is required") if($game_key eq "");
	return (0, "game_key must not contain leading or trailing whitespace") if($game_key =~ /^\s|\s$/);
	return (0, "game_key must be one path segment") if($game_key =~ m![/\\]!);
	return (0, "game_key must not contain a Windows drive or stream prefix") if($game_key =~ /:/);
	return (0, "game_key must not contain control characters") if($game_key =~ /[\x00-\x1f\x7f]/);
	return (0, "game_key must not contain traversal") if($game_key eq "." || $game_key eq ".." || $game_key =~ /\.\./);
	return (0, "game_key must not end with a dot or space") if($game_key =~ /[. ]$/);

	my $reserved_check = $game_key;
	$reserved_check =~ s/[. ].*$//;
	return (0, "game_key uses a reserved Windows device name")
		if($reserved_check =~ /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$/i);

	return (1, "");
}

# Normalizes a path for containment checks without following nonexistent leaf paths.
sub normalize_lifecycle_path_for_compare_without_decrypt
{
	my ($path) = @_;
	$path = "" unless(defined($path));
	$path = File::Spec->canonpath($path);
	$path =~ s/\\/\//g;
	$path =~ s{^/cygdrive/([A-Za-z])(?=/|\z)}{lc($1).":"}e;
	$path =~ s{/+}{/}g;
	$path =~ s{/\z}{};
	return lc($path);
}

# Returns true only when the resolved child path stays beneath the parent path.
sub lifecycle_path_is_inside_without_decrypt
{
	my ($parent, $child) = @_;
	my $parent_norm = normalize_lifecycle_path_for_compare_without_decrypt($parent);
	my $child_norm = normalize_lifecycle_path_for_compare_without_decrypt($child);
	return 0 if($parent_norm eq "" || $child_norm eq "");
	return 1 if($child_norm eq $parent_norm);
	return index($child_norm, "$parent_norm/") == 0 ? 1 : 0;
}

# Resolves management_home/<game_key> and refuses keys that escape the home,
# including existing symlinked payload roots that point elsewhere.
sub resolve_game_payload_root_without_decrypt
{
	my ($management_home, $game_key) = @_;
	my ($valid, $message) = validate_game_key_without_decrypt($game_key);
	return (undef, $message) unless($valid);
	return (undef, "management_home is required") unless(defined($management_home) && $management_home ne "");

	my $management_abs = abs_path($management_home);
	return (undef, "management_home does not exist: $management_home") unless(defined($management_abs) && $management_abs ne "");

	my $candidate = File::Spec->catdir($management_abs, "gamefiles");
	my $candidate_compare = -e $candidate ? abs_path($candidate) : File::Spec->rel2abs($candidate);
	$candidate_compare = File::Spec->canonpath($candidate) unless(defined($candidate_compare) && $candidate_compare ne "");
	return (undef, "game_key escapes management_home") unless(lifecycle_path_is_inside_without_decrypt($management_abs, $candidate_compare));

	return ($candidate, "");
}

# Resolves a relative payload path beneath game_root while rejecting traversal,
# absolute paths, drive prefixes, and control characters.
sub resolve_game_payload_child_path_without_decrypt
{
	my ($game_root, @parts) = @_;
	return (undef, "game_root is required") unless(defined($game_root) && $game_root ne "");
	my @safe_parts;
	foreach my $part (@parts)
	{
		next unless(defined($part) && $part ne "");
		return (undef, "payload path must be relative") if(File::Spec->file_name_is_absolute($part) || $part =~ /^[A-Za-z]:/);
		return (undef, "payload path must not contain control characters") if($part =~ /[\x00-\x1f\x7f]/);
		foreach my $segment (split(/[\\\/]+/, $part))
		{
			next if($segment eq "" || $segment eq ".");
			return (undef, "payload path must not contain traversal") if($segment eq "..");
			push(@safe_parts, $segment);
		}
	}

	my $candidate = File::Spec->catfile($game_root, @safe_parts);
	my $root_abs = -e $game_root ? abs_path($game_root) : File::Spec->rel2abs($game_root);
	my $candidate_compare = -e $candidate ? abs_path($candidate) : File::Spec->rel2abs($candidate);
	$root_abs = File::Spec->canonpath($game_root) unless(defined($root_abs) && $root_abs ne "");
	$candidate_compare = File::Spec->canonpath($candidate) unless(defined($candidate_compare) && $candidate_compare ne "");
	return (undef, "payload path escapes game_root") unless(lifecycle_path_is_inside_without_decrypt($root_abs, $candidate_compare));
	return ($candidate, "");
}

# Temporary compatibility for existing install/update RPCs: later Panel phases
# must send game_key so the agent can resolve the payload root from management_home.
sub resolve_payload_root_for_current_rpc_without_decrypt
{
	my ($management_home, $game_key, $operation) = @_;
	if(defined($game_key) && $game_key ne "")
	{
		return resolve_game_payload_root_without_decrypt($management_home, $game_key);
	}
	$operation = "RPC" unless(defined($operation) && $operation ne "");
	logger "$operation did not provide game_key; using supplied path as the payload root for temporary Panel compatibility.";
	return ($management_home, "");
}

sub encode_list
{
	my $encoded_content = '';
	if(@_)
	{
		foreach my $line (@_)
		{
			$encoded_content .= encode_base64($line, "") . '\n';
		}
	}
	return $encoded_content;
}

sub decrypt_param
{
	my ($param) = @_;
	$param = decode_base64($param);
	$param = Crypt::XXTEA::decrypt($param, AGENT_KEY);
	$param = decode_base64($param);
	return $param;
}

sub decrypt_params
{
	my @params;
	foreach my $param (@_)
	{
		$param = &decrypt_param($param);
		push(@params, $param);
	}
	return @params;
}

# Reports the explicit container boundary without changing legacy lifecycle routing.
sub container_capabilities
{
	return container_bad_encryption_response_without_decrypt()
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return container_capabilities_without_decrypt();
}

# Handles explicit container create requests through the opt-in runtime boundary.
sub container_create
{
	return container_lifecycle_rpc("create", @_);
}

# Handles explicit container inspect requests through the opt-in runtime boundary.
sub container_inspect
{
	return container_lifecycle_rpc("inspect", @_);
}

# Handles explicit container start requests through the opt-in runtime boundary.
sub container_start
{
	return container_lifecycle_rpc("start", @_);
}

# Handles explicit container stop requests through the opt-in runtime boundary.
sub container_stop
{
	return container_lifecycle_rpc("stop", @_);
}

# Handles explicit container restart requests through the opt-in runtime boundary.
sub container_restart
{
	return container_lifecycle_rpc("restart", @_);
}

# Handles explicit container delete requests through the opt-in runtime boundary.
sub container_delete
{
	return container_lifecycle_rpc("delete", @_);
}

# Builds the capability document the Panel can read before enabling container mode.
sub container_capabilities_without_decrypt
{
	return {
		contract => GSE::Container::Models::CONTRACT_VERSION(),
		success => JSON::PP::true(),
		status => "ok",
		message => "Container runtime boundary is installed. Legacy game-process RPCs remain unchanged.",
		configuration => {
			enabled => CONTAINER_RUNTIME_ENABLED ? JSON::PP::true() : JSON::PP::false(),
			runtime => CONTAINER_RUNTIME,
			docker_binary => CONTAINER_RUNTIME_DOCKER_BINARY,
			data_root => CONTAINER_DATA_ROOT
		},
		operations => [
			"container_capabilities",
			"container_create",
			"container_inspect",
			"container_start",
			"container_stop",
			"container_restart",
			"container_delete"
		],
		features => {
			stable_names => JSON::PP::true(),
			ownership_labels => JSON::PP::true(),
			cpu_limits => JSON::PP::true(),
			hard_memory_limits => JSON::PP::true(),
			optional_burst_memory => JSON::PP::true(),
			persistent_volume_mapping => JSON::PP::true(),
			assigned_tcp_udp_port_publishing => JSON::PP::true(),
			structured_results => JSON::PP::true(),
			idempotent_lifecycle_where_observable => JSON::PP::true(),
			logs => JSON::PP::false(),
			console_exec => JSON::PP::false(),
			scoped_files => JSON::PP::false(),
			backup_restore_points => JSON::PP::false(),
			health_monitoring => JSON::PP::false()
		},
		proof_gates => {
			live_windows_docker_poc => JSON::PP::false(),
			steamcmd_outbound_networking => JSON::PP::false(),
			resource_enforcement => JSON::PP::false(),
			port_allocation_enforcement => JSON::PP::false(),
			storage_quota_enforcement => JSON::PP::false()
		},
		compatibility => {
			default_for_legacy_game_records => JSON::PP::false(),
			legacy_lifecycle_rpcs_unchanged => JSON::PP::true(),
			requires_explicit_panel_container_mode => JSON::PP::true()
		}
	};
}

# Runs one explicit container RPC after decrypting and validating the request envelope.
sub container_lifecycle_rpc
{
	my ($operation, @encrypted_params) = @_;
	return container_bad_encryption_response_without_decrypt()
		unless(decrypt_param(pop(@encrypted_params)) eq "Encryption checking OK");
	return container_failure_without_decrypt(
		status => "unsupported",
		code => "container_runtime_disabled",
		category => "unsupported",
		message => "Container runtime is disabled on this agent. Set container_runtime_enabled=1 only after the host passes the Docker proof-of-concept gates.",
		retryable => 0
	) unless(CONTAINER_RUNTIME_ENABLED);
	return container_failure_without_decrypt(
		status => "unsupported",
		code => "unsupported_runtime",
		category => "unsupported",
		message => "Only the docker container runtime adapter is available in this migration slice.",
		retryable => 0
	) unless(CONTAINER_RUNTIME eq "docker");

	my ($payload) = decrypt_params(@encrypted_params);
	my ($request, $request_error) = container_decode_request_without_decrypt($payload);
	return $request_error unless($request);
	return container_failure_without_decrypt(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container request contract must be " . GSE::Container::Models::CONTRACT_VERSION() . ".",
		retryable => 0
	) unless(defined($request->{contract}) && $request->{contract} eq GSE::Container::Models::CONTRACT_VERSION());

	my $runtime = container_runtime_adapter_without_decrypt();
	my $result;
	my $ok = eval {
		if($operation eq "create")
		{
			$result = $runtime->create($request);
		}
		elsif($operation eq "inspect")
		{
			$result = $runtime->inspect($request);
		}
		elsif($operation eq "start")
		{
			$result = $runtime->start($request);
		}
		elsif($operation eq "stop")
		{
			$result = $runtime->stop($request);
		}
		elsif($operation eq "restart")
		{
			$result = $runtime->restart($request);
		}
		elsif($operation eq "delete")
		{
			$result = $runtime->delete($request);
		}
		else
		{
			$result = container_failure_without_decrypt(
				status => "unsupported",
				code => "unsupported_operation",
				category => "unsupported",
				message => "Unsupported container operation.",
				retryable => 0
			);
		}
		1;
	};
	return $result if($ok);
	logger "Container $operation RPC failed unexpectedly: $@";
	return container_failure_without_decrypt(
		status => "failed",
		code => "internal_error",
		category => "internal",
		message => "Container operation failed inside the agent boundary.",
		retryable => 0
	);
}

# Creates the currently supported Docker-backed container runtime adapter.
sub container_runtime_adapter_without_decrypt
{
	return GSE::Container::DockerRuntime->new(
		docker_binary => CONTAINER_RUNTIME_DOCKER_BINARY,
		data_root => CONTAINER_DATA_ROOT
	);
}

# Decodes the JSON request body carried by the encrypted XML-RPC compatibility wrapper.
sub container_decode_request_without_decrypt
{
	my ($payload) = @_;
	return (undef, container_failure_without_decrypt(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container request payload must be a JSON object.",
		retryable => 0
	)) unless(defined($payload) && $payload ne "");
	my $request = eval { JSON::PP->new->decode($payload) };
	return (undef, container_failure_without_decrypt(
		status => "validation_failed",
		code => "invalid_contract",
		category => "validation",
		message => "Container request payload is not valid JSON.",
		retryable => 0
	)) if($@ || ref($request) ne "HASH");
	return ($request, undef);
}

# Builds a structured container failure for transport-level and integration errors.
sub container_failure_without_decrypt
{
	my (%args) = @_;
	return GSE::Container::Result->failure(%args);
}

# Returns the standard bad-encryption response for container RPCs.
sub container_bad_encryption_response_without_decrypt
{
	return container_failure_without_decrypt(
		status => "bad_encryption",
		code => "bad_encryption",
		category => "authorization",
		message => "Bad Encryption Key",
		retryable => 0
	);
}

sub check_steam_cmd_client
{
	if (STEAM_LICENSE ne STEAM_LICENSE_OK)
	{
		logger "Steam license not accepted, stopping Steam client check.";
		return 0;
	}
	if (!-d STEAMCMD_CLIENT_DIR)
	{
		logger "SteamCMD is not installed at " . STEAMCMD_CLIENT_DIR . ". Steam-specific operations require a prepared SteamCMD directory.", 1;
		return -1;
	}
	if (!-w STEAMCMD_CLIENT_DIR)
	{
		logger "Steam client dir '"
		  . STEAMCMD_CLIENT_DIR
		  . "' not writable. Unable to get Steam client.";
		return -1;
	}
	if (!-f STEAMCMD_CLIENT_BIN)
	{
		my $steam_client_url = "https://media.steampowered.com/installer/steamcmd.zip";
		logger "SteamCMD executable is missing at " . STEAMCMD_CLIENT_BIN . ". Current GSE Windows Agent payloads bundle the offline bootstrap at this path; repair the agent from a complete payload or restore steamcmd.exe from $steam_client_url before running Steam-specific operations.", 1;
		return -1;
	}
	if (!-x STEAMCMD_CLIENT_BIN)
	{
		if ( ! chmod 0755, STEAMCMD_CLIENT_BIN )
		{
			logger "Unable to apply execution permission to ".STEAMCMD_CLIENT_BIN.".";
		}
	}
	return 1;
}

sub is_screen_running
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id) = decrypt_params(@_);
	return is_screen_running_without_decrypt($screen_type, $home_id);
}

sub is_screen_running_without_decrypt
{
	my ($screen_type, $home_id) = @_;
	if ($screen_type eq SCREEN_TYPE_HOME) {
		# Game servers are not in screen any more: the game manager status file + live PID decide.
		return log_server_is_running($screen_type, $home_id) ? 1 : 0;
	}

	my $screen_id = create_screen_id($screen_type, $home_id);

	my $is_running = `screen -list | grep $screen_id`;

	if ($is_running =~ /^\s*$/)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

our %GM_WINDOW;     # epoch of the last start/stop per server: drives the check interval
our %GM_LAST_TICK;  # epoch of the last check per server
sub gm {
	our $GM;
	$GM ||= GameManager->new(
		state_dir       => GAME_STARTUP_DIR,
		dir_for         => sub { my ($gid) = @_; return "C:\\GSE\\Agent\\home\\gameserver\\$gid"; },
		now             => sub { time() },
		pid_alive       => \&GameManagerWin::pid_alive,
		pid_executable_matches => \&GameManagerWin::pid_executable_matches,
		port_listening  => \&GameManagerWin::port_listening,
		port_owner_pids => \&GameManagerWin::port_owner_pids,
		kill_pid        => \&GameManagerWin::kill_pid,
		launch          => sub { my ($cmd, $wd, $opt) = @_; return GameManagerWin::launch($cmd, $wd, $opt); },
		log             => sub { logger($_[0]); },
		startup_timeout => 180,
		restart_limit   => 5,
		restart_window  => 1800,
	);
	return $GM;
}

# The panel only reads the status file: one quick reply, no process or port checks here.
sub gm_status_reply {
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	my $st = gm()->read_state($home_id);
	my $s  = $st->{state};
	my %ui = (RUNNING => 'RUNNING', STARTING => 'STARTING', STOPPED => 'OFFLINE', STOPPING => 'STOPPING', FAILED => 'FAILED', UNKNOWN => 'UNKNOWN');
	return {
		status => ($ui{$s} // 'OFFLINE'), state => $s,
		ready => ($s eq 'RUNNING' && $st->{process_running} && $st->{port_listening} ? 1 : 0),
		process_running => ($st->{process_running} ? 1 : 0),
		session_running => ($st->{session_running} ? 1 : 0),
		game_port_listening => ($st->{port_listening} ? 1 : 0),
		query_port_listening => 0, rcon_port_listening => 0,
		desired_state => $st->{desired}, desired => $st->{desired}, updated_at => ($st->{updated_at} || $st->{ts}),
		reason => $st->{reason}, pid => $st->{pid}, last_error => $st->{reason},
		ip => '', port => '', query_port => '', rcon_port => '', query_info => '',
	};
}

# Scheduler job, every 30 seconds: bring every server with a status file in line with its state.
sub gm_monitor_all {
	# Every home is checked on every scheduler invocation.
	my $now = time();
	opendir(my $dh, "C:\\GSE\\Agent\\home\\gameserver") or return;
	my @ids = map { (/^(\d+)$/ && -e "C:\\GSE\\Agent\\home\\gameserver\\$_\\status") ? $_ : () } readdir($dh);
	closedir $dh;
	for my $id (sort @ids) {
		# A server still STARTING after an agent restart is checked on the fast schedule too.
		$GM_WINDOW{$id} = $now if (!defined $GM_WINDOW{$id} && gm()->read_state($id)->{state} eq 'STARTING');
		eval { gm()->tick($id); 1 } or logger("Monitor error for HOME ID:$id: $@");
		my $home_win = "C:\\GSE\\Agent\\home\\gameserver\\$id";
		eval { gm()->ensure_bot($id, GameManager::read_bot_config("$home_win\\_alsoRun.cmd"), $home_win); 1 } or logger("Bot monitor error for HOME ID:$id: $@");
	}
}

sub server_status
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return server_status_without_decrypt(decrypt_params(@_));
}

sub set_desired
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $desired) = decrypt_params(@_);
	return gm()->set_desired($home_id, $desired);
}

sub get_status_hint_path
{
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	return Path::Class::File->new(GAME_STARTUP_DIR, "status-$home_id");
}

sub write_status_hint
{
	my ($home_id, $state) = @_;
	my $hint_file = get_status_hint_path($home_id);
	if(open(STATUSHINT, '>', $hint_file))
	{
		print STATUSHINT time() . "," . $state;
		close(STATUSHINT);
	}
}

sub read_status_hint
{
	my ($home_id) = @_;
	my $hint_file = get_status_hint_path($home_id);
	return (0, "") unless(-e $hint_file);
	open(STATUSHINT, '<', $hint_file) or return (0, "");
	my $line = <STATUSHINT>;
	close(STATUSHINT);
	chomp($line);
	my ($timestamp, $state) = split(/,/, $line, 2);
	$timestamp = 0 unless(defined($timestamp) && $timestamp =~ /^\d+$/);
	$state = "" unless(defined($state));
	return ($timestamp, $state);
}

# Desired state is home-local intent only. It never proves that a process or
# port is alive; process checks below must provide actual runtime evidence.
sub get_desired_state_file_without_decrypt
{
	my ($home_path, $state) = @_;
	return "" unless(defined($home_path) && $home_path ne "");
	return "" unless(defined($state) && ($state eq "running" || $state eq "stopped"));
	return Path::Class::File->new($home_path, "status.$state");
}

# Atomically publishes exactly one desired-state marker in the management home.
sub set_desired_state_without_decrypt
{
	my ($home_path, $state) = @_;
	return 0 unless(defined($home_path) && $home_path ne "" && -d $home_path);
	return 0 unless(defined($state) && ($state eq "running" || $state eq "stopped"));

	my $target = get_desired_state_file_without_decrypt($home_path, $state);
	my $opposite_state = $state eq "running" ? "stopped" : "running";
	my $opposite = get_desired_state_file_without_decrypt($home_path, $opposite_state);
	my $tmp = Path::Class::File->new($home_path, "status.$state.$$." . time() . ".tmp");

	if(open(my $STATE, '>', $tmp))
	{
		print {$STATE} time() . "\n";
		close($STATE);
	}
	else
	{
		logger "Unable to write desired lifecycle state $state in $home_path: $!";
		return 0;
	}

	unlink($opposite) if($opposite ne "" && -e $opposite);
	if(!rename($tmp, $target))
	{
		logger "Unable to publish desired lifecycle state $state in $home_path: $!";
		unlink($tmp) if(-e $tmp);
		return 0;
	}
	unlink($opposite) if($opposite ne "" && -e $opposite);
	return 1;
}

# Reads desired state as fail-safe intent: anything except one valid marker is stopped.
sub read_desired_state_without_decrypt
{
	my ($home_path) = @_;
	return "stopped" unless(defined($home_path) && $home_path ne "" && -d $home_path);
	my $running = get_desired_state_file_without_decrypt($home_path, "running");
	my $stopped = get_desired_state_file_without_decrypt($home_path, "stopped");
	my $has_running = ($running ne "" && -f $running && -r $running) ? 1 : 0;
	my $has_stopped = ($stopped ne "" && -f $stopped && -r $stopped) ? 1 : 0;
	return "running" if($has_running && !$has_stopped);
	return "stopped";
}

sub get_pid_metadata_path
{
	my ($home_id) = @_;
	$home_id =~ s/[^0-9]//g;
	return Path::Class::File->new(SERVER_RUNTIME_DIR, "pid-$home_id.kv");
}

sub write_pid_metadata
{
	my ($home_id, $values) = @_;
	return 0 unless(ref($values) eq 'HASH');
	my $file = get_pid_metadata_path($home_id);
	if(open(PIDMETA, '>', $file))
	{
		foreach my $key (sort keys %$values)
		{
			my $value = defined($values->{$key}) ? $values->{$key} : "";
			$value =~ s/[\r\n]//g;
			print PIDMETA "$key=$value\n";
		}
		close(PIDMETA);
		return 1;
	}
	return 0;
}

sub read_pid_metadata
{
	my ($home_id) = @_;
	my %values;
	my $file = get_pid_metadata_path($home_id);
	return \%values unless(-e $file);
	if(open(PIDMETA, '<', $file))
	{
		while(my $line = <PIDMETA>)
		{
			chomp($line);
			next unless($line =~ /^([^=]+)=(.*)$/);
			$values{$1} = $2;
		}
		close(PIDMETA);
	}
	return \%values;
}

sub clear_pid_metadata
{
	my ($home_id) = @_;
	my $file = get_pid_metadata_path($home_id);
	unlink($file) if(-e $file);
}

sub is_pid_alive_without_decrypt
{
	my ($pid) = @_;
	return 0 unless(defined($pid) && $pid =~ /^\d+$/ && $pid > 0);
	my $retval = system(qq!tasklist /FI "PID eq ${pid}" /NH 2>/dev/null | findstr /R /C:"[ ]${pid}[ ]" >/dev/null 2>&1!);
	return $retval == 0 ? 1 : 0;
}

sub find_process_pid_by_port_without_decrypt
{
	my ($port, $protocol) = @_;
	my @owners = collect_port_owners_without_decrypt($port, $protocol);
	return @owners ? $owners[0]->{pid} : "";
}

# Returns TCP and UDP owner PIDs for an assigned port without deciding whether
# those owners are safe to terminate.
sub collect_port_owners_without_decrypt
{
	my ($port, $protocol) = @_;
	my @owners;
	my %seen;
	return @owners unless(defined($port) && $port =~ /^\d+$/ && $port > 0 && $port <= 65535);
	$protocol = "any" unless(defined($protocol) && $protocol =~ /^(tcp|udp|any)$/i);
	$protocol = lc($protocol);

	my $output = `netstat -ano 2>/dev/null`;
	foreach my $line (split(/\r?\n/, $output || ""))
	{
		if(($protocol eq "tcp" || $protocol eq "any") && $line =~ /^\s*TCP\s+\S+[:.]$port\s+\S+\s+LISTENING\s+([0-9]+)\s*$/i)
		{
			my $pid = $1;
			next if($seen{"tcp:$pid"});
			$seen{"tcp:$pid"} = 1;
			push(@owners, {protocol => "tcp", pid => $pid});
		}
		if(($protocol eq "udp" || $protocol eq "any") && $line =~ /^\s*UDP\s+\S+[:.]$port\s+\S*\s*([0-9]+)\s*$/i)
		{
			my $pid = $1;
			next if($seen{"udp:$pid"});
			$seen{"udp:$pid"} = 1;
			push(@owners, {protocol => "udp", pid => $pid});
		}
	}
	return @owners;
}

# Reads process metadata used to avoid killing protected or unrelated Windows processes.
sub get_windows_process_info_without_decrypt
{
	my ($pid) = @_;
	my %info = (pid => $pid, name => "", executable_path => "", command_line => "", parent_pid => "");
	return \%info unless(defined($pid) && $pid =~ /^\d+$/ && $pid > 0);
	my $output = `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$p=Get-CimInstance Win32_Process -Filter 'ProcessId=$pid' -ErrorAction SilentlyContinue; if(\$p){'Name='+\$p.Name;'ExecutablePath='+\$p.ExecutablePath;'CommandLine='+\$p.CommandLine;'ParentProcessId='+\$p.ParentProcessId}" 2>/dev/null`;
	foreach my $line (split(/\r?\n/, $output || ""))
	{
		$info{name} = $1 if($line =~ /^Name=(.*)$/);
		$info{executable_path} = $1 if($line =~ /^ExecutablePath=(.*)$/);
		$info{command_line} = $1 if($line =~ /^CommandLine=(.*)$/);
		$info{parent_pid} = $1 if($line =~ /^ParentProcessId=([0-9]+)$/);
	}
	return \%info;
}

sub normalize_process_match_path_without_decrypt
{
	my ($value) = @_;
	$value = "" unless(defined($value));
	$value =~ s/\\/\//g;
	$value =~ s/"//g;
	$value = lc($value);
	return $value;
}

sub read_also_run_definition_without_decrypt
{
	my ($home_path) = @_;
	my %definition = (workdir => "", command => "", options => "");
	return \%definition unless(defined($home_path) && $home_path ne "");
	my @definition_files = (
		Path::Class::File->new($home_path, "_alsorun.cmd"),
		Path::Class::File->new($home_path, "_alsoRun.cmd")
	);
	foreach my $definition_file (@definition_files)
	{
		next unless(-e $definition_file);
		if(open(my $ALSO, '<', $definition_file))
		{
			while(my $line = <$ALSO>)
			{
				chomp($line);
				$line =~ s/^\s*set\s+//i;
				next unless($line =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/);
				my $key = lc($1);
				my $value = $2;
				$value =~ s/^"//;
				$value =~ s/"$//;
				$definition{workdir} = $value if($key eq "workdir" || $key eq "also_workdir");
				$definition{command} = $value if($key eq "executable" || $key eq "also_command");
				$definition{options} = $value if($key eq "arguments" || $key eq "also_options");
			}
			close($ALSO);
		}
		last if($definition{workdir} ne "" || $definition{command} ne "");
	}
	return \%definition;
}

sub also_run_option_identity_without_decrypt
{
	my ($options) = @_;
	$options = "" unless(defined($options));
	return $1 if($options =~ /([A-Za-z]:[\\\/][^"\s]+)/);
	return $1 if($options =~ /([\\\/][^"\s]+)/);
	return "";
}

sub process_text_matches_also_run_without_decrypt
{
	my ($process_text, $definition) = @_;
	return 0 unless(ref($definition) eq 'HASH');
	my $command = normalize_process_match_path_without_decrypt($definition->{command});
	my $workdir = normalize_process_match_path_without_decrypt($definition->{workdir});
	my $identity_option = normalize_process_match_path_without_decrypt(also_run_option_identity_without_decrypt($definition->{options}));
	$process_text = normalize_process_match_path_without_decrypt($process_text);
	return 0 if($process_text eq "" || ($command eq "" && $workdir eq ""));

	my $command_match = ($command ne "" && index($process_text, $command) >= 0) ? 1 : 0;
	my $workdir_match = ($workdir ne "" && index($process_text, $workdir) >= 0) ? 1 : 0;
	return 0 unless($command_match || $workdir_match);
	return 1 if($identity_option eq "");
	return index($process_text, $identity_option) >= 0 ? 1 : 0;
}

sub find_windows_pids_for_also_run_without_decrypt
{
	my ($home_path) = @_;
	my @pids;
	my $definition = read_also_run_definition_without_decrypt($home_path);
	return @pids unless($definition->{workdir} ne "" && $definition->{command} ne "");
	my $output = `wmic process get ProcessId,ExecutablePath,CommandLine /FORMAT:LIST 2>/dev/null`;
	my $current_text = "";
	foreach my $line (split(/\r?\n/, $output || ""))
	{
		if($line =~ /^CommandLine=(.*)$/i || $line =~ /^ExecutablePath=(.*)$/i)
		{
			$current_text .= " " . ($1 || "");
			next;
		}
		if($line =~ /^ProcessId=([0-9]+)$/i)
		{
			push(@pids, $1) if(process_text_matches_also_run_without_decrypt($current_text, $definition));
			$current_text = "";
		}
		$current_text = "" if($line =~ /^\s*$/);
	}
	my %seen;
	return grep { !$seen{$_}++ } @pids;
}

# A port owner is attributable only when its executable or command line points
# at the selected home; otherwise hard-stop must fail instead of guessing.
sub process_info_matches_home_without_decrypt
{
	my ($info, $home_path) = @_;
	return 0 unless(ref($info) eq 'HASH' && defined($home_path) && $home_path ne "");
	my @home_prefixes = (normalize_process_match_path_without_decrypt($home_path));
	my $abs_home = abs_path($home_path);
	push(@home_prefixes, normalize_process_match_path_without_decrypt($abs_home)) if(defined($abs_home) && $abs_home ne "");
	my $win_home = clean(`cygpath -wa "$home_path" 2>/dev/null`);
	push(@home_prefixes, normalize_process_match_path_without_decrypt($win_home)) if($win_home ne "");
	my $process_text = normalize_process_match_path_without_decrypt(($info->{executable_path} || "") . " " . ($info->{command_line} || ""));
	foreach my $prefix (@home_prefixes)
	{
		next if($prefix eq "");
		return 1 if(index($process_text, $prefix) >= 0);
	}
	return 0;
}

sub protected_windows_process_reason_without_decrypt
{
	my ($pid, $info) = @_;
	return "invalid PID" unless(defined($pid) && $pid =~ /^\d+$/);
	return "PID $pid is reserved by Windows" if($pid == 0 || $pid == 4);
	$info = get_windows_process_info_without_decrypt($pid) unless(ref($info) eq 'HASH');
	my $name = lc($info->{name} || "");
	my $command_line = lc($info->{command_line} || "");
	return "agent Perl process" if($name eq "perl.exe" && $command_line =~ /gse_agent\.pl/);
	return "agent launch shell" if(($name eq "bash.exe" || $name eq "sh.exe") && $command_line =~ /agent_(?:launch|service_wrapper)\.sh/);
	return "Windows service wrapper" if($name eq "cygrunsrv.exe");
	return "managed screen infrastructure" if($name eq "screen.exe");
	return "";
}

sub read_home_pid_file_without_decrypt
{
	my ($home_path, $pid_name) = @_;
	my @pids;
	return @pids unless(defined($home_path) && $home_path ne "" && defined($pid_name) && $pid_name =~ /^(?:watchdog|bot|game)\.pid$/);
	my $pid_file = "$home_path/$pid_name";
	return @pids unless(-e $pid_file);
	if(open(my $PIDFILE, '<', $pid_file))
	{
		while(my $pid = <$PIDFILE>)
		{
			chomp($pid);
			push(@pids, $pid) if($pid =~ /^\d+$/);
		}
		close($PIDFILE);
	}
	return @pids;
}

# Terminates a PID tree only after checking protected-process rules and
# home ownership evidence.
sub kill_lifecycle_pid_without_decrypt
{
	my ($pid, $home_path, $source, $tracked) = @_;
	$source = "unknown" unless(defined($source) && $source ne "");
	return {success => 1, pid => $pid || "", status => "invalid_pid", message => "No valid PID supplied for $source."}
		unless(defined($pid) && $pid =~ /^\d+$/ && $pid > 0);
	return {success => 1, pid => $pid, status => "not_running", message => "PID $pid from $source is not running."}
		unless(is_pid_alive_without_decrypt($pid));
	if($tracked)
	{
		if($pid == 0 || $pid == 4)
		{
			my $message = "Refusing to kill PID $pid from $source: PID $pid is reserved by Windows.";
			logger $message;
			return {success => 0, pid => $pid, status => "protected_process", message => $message};
		}
		logger "Attempting forced stop for $source PID $pid.";
		my $killed = kill_windows_pid_with_escalation_without_decrypt($pid);
		return {
			success => $killed ? 1 : 0,
			pid => $pid,
			status => $killed ? "killed" : "kill_failed",
			message => $killed ? "PID $pid from $source was terminated." : "PID $pid from $source survived taskkill."
		};
	}

	my $info = get_windows_process_info_without_decrypt($pid);
	my $protected_reason = protected_windows_process_reason_without_decrypt($pid, $info);
	if($protected_reason ne "")
	{
		my $message = "Refusing to kill PID $pid from $source: $protected_reason.";
		logger $message;
		return {success => 0, pid => $pid, status => "protected_process", message => $message};
	}

	if(!process_info_matches_home_without_decrypt($info, $home_path))
	{
		my $message = "Refusing to kill PID $pid from $source: process is not attributable to $home_path.";
		logger $message;
		return {success => 0, pid => $pid, status => "ambiguous_process", message => $message};
	}

	logger "Attempting forced stop for $source PID $pid.";
	my $killed = kill_windows_pid_with_escalation_without_decrypt($pid);
	return {
		success => $killed ? 1 : 0,
		pid => $pid,
		status => $killed ? "killed" : "kill_failed",
		message => $killed ? "PID $pid from $source was terminated." : "PID $pid from $source survived taskkill."
	};
}

sub kill_lifecycle_port_owner_without_decrypt
{
	my ($owner, $server_port, $home_path, $tracked_seen) = @_;
	return {success => 1, pid => "", status => "invalid_port_owner", message => "Invalid port owner."}
		unless(ref($owner) eq 'HASH' && defined($owner->{pid}) && $owner->{pid} =~ /^\d+$/);
	my $pid = $owner->{pid};
	my $protocol = uc($owner->{protocol} || "UNKNOWN");
	my $source = "$protocol port $server_port owner";
	my $tracked = (ref($tracked_seen) eq 'HASH' && $tracked_seen->{$pid}) ? 1 : 0;
	if(!$tracked)
	{
		if($pid == 0 || $pid == 4)
		{
			return {success => 0, pid => $pid, status => "protected_port_owner", message => "$source PID $pid is reserved by Windows."};
		}
		my $info = get_windows_process_info_without_decrypt($pid);
		my $protected_reason = protected_windows_process_reason_without_decrypt($pid, $info);
		if($protected_reason ne "")
		{
			return {success => 0, pid => $pid, status => "protected_port_owner", message => "Refusing to kill $source PID $pid: $protected_reason."};
		}
		logger "Attempting forced stop for untracked $source PID $pid.";
		my $killed = kill_windows_pid_with_escalation_without_decrypt($pid);
		return {
			success => $killed ? 1 : 0,
			pid => $pid,
			status => $killed ? "killed" : "kill_failed",
			message => $killed ? "$source PID $pid was terminated." : "$source PID $pid survived taskkill."
		};
	}
	my $result = kill_lifecycle_pid_without_decrypt($pid, $home_path, $source, $tracked);
	if(ref($result) eq 'HASH' && !$result->{success})
	{
		$result->{status} = "protected_port_owner" if($result->{status} eq "protected_process");
		$result->{status} = "ambiguous_port_owner" if($result->{status} eq "ambiguous_process");
	}
	return $result;
}

sub tracked_lifecycle_pids_without_decrypt
{
	my ($home_id, $home_path) = @_;
	my @tracked;
	my $pid_meta = read_pid_metadata($home_id);
	push(@tracked, $pid_meta->{windows_pid}) if(defined($pid_meta->{windows_pid}) && $pid_meta->{windows_pid} =~ /^\d+$/);
	push(@tracked, $pid_meta->{game_pid}) if(defined($pid_meta->{game_pid}) && $pid_meta->{game_pid} =~ /^\d+$/);
	foreach my $pid_name ("watchdog.pid", "bot.pid", "game.pid")
	{
		push(@tracked, read_home_pid_file_without_decrypt($home_path, $pid_name));
	}
	my %seen;
	return grep { defined($_) && $_ =~ /^\d+$/ && !$seen{$_}++ } @tracked;
}

sub remove_verified_lifecycle_runtime_files_without_decrypt
{
	my ($home_id, $home_path) = @_;
	if(defined($home_path) && $home_path ne "")
	{
		foreach my $runtime_name ("watchdog.pid", "bot.pid", "game.pid", "game.launch_ts", "serverStart.bat", "bot.def", "_serverStart.bat", "_gsp_wmic.out", "_serverStartPid.ps1", "_serverStartupdated.bat")
		{
			my $runtime_file = "$home_path/$runtime_name";
			unlink($runtime_file) if(-e $runtime_file);
		}
	}
	clear_pid_metadata($home_id);
	my $legacy_hint = get_status_hint_path($home_id);
	unlink($legacy_hint) if(-e $legacy_hint);
}

sub kill_windows_pid_with_escalation_without_decrypt
{
	my ($pid) = @_;
	return 0 unless(defined($pid) && $pid =~ /^\d+$/);
	system("cmd /C taskkill /F /T /PID $pid >nul 2>&1");
	return is_pid_alive_without_decrypt($pid) ? 0 : 1;
}

sub kill_windows_window_title_without_decrypt
{
	my ($title, $source) = @_;
	$source = "window title" unless(defined($source) && $source ne "");
	return {success => 1, pid => "", status => "no_title", message => "No window title supplied for $source."}
		unless(defined($title) && $title ne "");
	$title =~ s/"/ /g;
	my @before = find_windows_pids_by_window_title_without_decrypt($title);
	return {success => 1, pid => "", status => "not_running", message => "$source $title is not running."}
		unless(@before);
	system(qq!cmd /C taskkill /F /T /FI "WINDOWTITLE eq $title" >nul 2>&1!);
	my @after = find_windows_pids_by_window_title_without_decrypt($title);
	return {
		success => @after ? 0 : 1,
		pid => join(',', @before),
		status => @after ? "kill_failed" : "killed",
		message => @after ? "$source $title survived taskkill." : "$source $title was terminated."
	};
}

sub kill_windows_command_marker_without_decrypt
{
	my ($marker, $source) = @_;
	$source = "command marker" unless(defined($source) && $source ne "");
	my @pids = find_windows_cmd_pids_by_command_marker_without_decrypt($marker);
	return {success => 1, pid => "", status => "not_running", message => "$source is not running."}
		unless(@pids);
	my @results;
	foreach my $pid (@pids)
	{
		next if($pid == 0 || $pid == 4);
		logger "Attempting forced stop for $source PID $pid.";
		push(@results, kill_windows_pid_with_escalation_without_decrypt($pid));
	}
	my @after = find_windows_cmd_pids_by_command_marker_without_decrypt($marker);
	return {
		success => @after ? 0 : 1,
		pid => join(',', @pids),
		status => @after ? "kill_failed" : "killed",
		message => @after ? "$source survived taskkill." : "$source was terminated."
	};
}

sub kill_also_run_processes_without_decrypt
{
	my ($home_path) = @_;
	my @pids = find_windows_pids_for_also_run_without_decrypt($home_path);
	return {success => 1, pid => "", status => "not_running", message => "_alsoRun.cmd BOT process is not running."}
		unless(@pids);
	my @results;
	foreach my $pid (@pids)
	{
		push(@results, kill_lifecycle_pid_without_decrypt($pid, $home_path, "_alsoRun.cmd BOT process", 0));
	}
	my @failed = grep { ref($_) eq 'HASH' && !$_->{success} } @results;
	return {
		success => @failed ? 0 : 1,
		pid => join(',', @pids),
		status => @failed ? ($failed[0]->{status} || "kill_failed") : "killed",
		message => @failed ? join("; ", map { $_->{message} || "BOT cleanup failed" } @failed) : "_alsoRun.cmd BOT process tree was terminated."
	};
}

sub kill_home_pid_files_without_decrypt
{
	my ($home_path) = @_;
	return () unless(defined($home_path) && $home_path ne "");
	my @results;
	foreach my $pid_name ("watchdog.pid", "bot.pid", "game.pid")
	{
		foreach my $pid (read_home_pid_file_without_decrypt($home_path, $pid_name))
		{
			push(@results, kill_lifecycle_pid_without_decrypt($pid, $home_path, $pid_name, 1));
		}
	}
	return @results;
}

sub force_kill_tracked_and_port_without_decrypt
{
	my ($home_id, $server_port, $home_path) = @_;
	my $pid_meta = read_pid_metadata($home_id);
	my @results;
	my @tracked_pids = ();
	push(@tracked_pids, $pid_meta->{windows_pid}) if(defined($pid_meta->{windows_pid}) && $pid_meta->{windows_pid} =~ /^\d+$/);
	push(@tracked_pids, $pid_meta->{game_pid}) if(defined($pid_meta->{game_pid}) && $pid_meta->{game_pid} =~ /^\d+$/);
	my %seen;
	foreach my $pid (@tracked_pids)
	{
		next if($seen{$pid});
		$seen{$pid} = 1;
		logger "Attempting forced stop for tracked PID $pid.";
		push(@results, kill_lifecycle_pid_without_decrypt($pid, $home_path, "runtime_status", 1));
	}
	foreach my $owner (collect_port_owners_without_decrypt($server_port, "any"))
	{
		push(@results, kill_lifecycle_port_owner_without_decrypt($owner, $server_port, $home_path, \%seen));
	}
	return @results;
}

# Definitive hard-stop operation shared by Stop, Force Stop, Restart, and Start
# preflight. It sets stopped intent before killing and only removes runtime
# files after verification proves the screen, tracked PIDs, and port owners are gone.
sub lifecycle_hard_stop_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $home_path, $options) = @_;
	$options = {} unless(ref($options) eq 'HASH');
	my $remove_startup = exists($options->{remove_startup}) ? $options->{remove_startup} : 1;
	my $clean_content = exists($options->{clean_content}) ? $options->{clean_content} : 1;
	my $operation = $options->{operation} || "hard_stop";

	if(!defined($home_id) || $home_id !~ /^[0-9]+$/ || !defined($server_port) || $server_port !~ /^[0-9]+$/ || $server_port < 1 || $server_port > 65535 || !defined($home_path) || $home_path eq "" || !-d $home_path)
	{
		return {success => 0, status => "invalid_target", message => "Invalid lifecycle target.", home_id => $home_id || "", ip => $server_ip || "", port => $server_port || "", attempted_pids => [], remaining_pids => []};
	}

	if(!set_desired_state_without_decrypt($home_path, "stopped"))
	{
		return {success => 0, status => "state_write_failed", message => "Unable to set desired state to stopped for $home_path.", home_id => $home_id, ip => $server_ip || "", port => $server_port, attempted_pids => [], remaining_pids => []};
	}

	my $startup_file = Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");
	if($remove_startup && -e $startup_file)
	{
		logger "Removing startup flag " . $startup_file . "";
		unlink($startup_file) or logger "Cannot remove the startup flag file $startup_file $!";
	}

		logger "Lifecycle $operation requested for HOME ID:$home_id $server_ip:$server_port.";
		sleep 3 if($operation eq "stop" || $operation eq "force_stop");

		my @kill_results = kill_home_pid_files_without_decrypt($home_path);
		cleanup_server_content_hooks_without_decrypt($home_path) if($clean_content);
		push(@kill_results, force_kill_tracked_and_port_without_decrypt($home_id, $server_port, $home_path));
		push(@kill_results, kill_windows_command_marker_without_decrypt(windows_lifecycle_bot_marker_without_decrypt($home_path), "BOT supervisor marker"));
		push(@kill_results, kill_also_run_processes_without_decrypt($home_path));
		push(@kill_results, kill_windows_window_title_without_decrypt(windows_lifecycle_title_without_decrypt($home_path, "bot"), "bot window title"));
		system("screen -wipe > /dev/null 2>&1");

	my @failed_kills = grep { ref($_) eq 'HASH' && !$_->{success} } @kill_results;
	if(@failed_kills)
	{
		my $message = join("; ", map { $_->{message} || "cleanup failed" } @failed_kills);
		return {success => 0, status => $failed_kills[0]->{status} || "cleanup_failed", message => $message, home_id => $home_id, ip => $server_ip || "", port => $server_port, kill_results => \@kill_results, attempted_pids => [map { $_->{pid} || "" } @kill_results], remaining_pids => []};
	}

	my $verify = verify_runtime_stop_complete_without_decrypt($home_id, $server_ip, $server_port, $home_path);
	if($verify == 0)
	{
		remove_verified_lifecycle_runtime_files_without_decrypt($home_id, $home_path);
		return {success => 1, status => "STOPPED", message => "Lifecycle hard stop completed and verified.", home_id => $home_id, ip => $server_ip || "", port => $server_port, kill_results => \@kill_results, attempted_pids => [map { $_->{pid} || "" } @kill_results], remaining_pids => []};
	}

	my @remaining = grep { is_pid_alive_without_decrypt($_) } tracked_lifecycle_pids_without_decrypt($home_id, $home_path);
	return {success => 0, status => "cleanup_failed", message => "Lifecycle hard stop could not verify that all screen, process, and port evidence is gone.", home_id => $home_id, ip => $server_ip || "", port => $server_port, kill_results => \@kill_results, attempted_pids => [map { $_->{pid} || "" } @kill_results], remaining_pids => \@remaining};
}

sub get_screen_pid_without_decrypt
{
	my ($home_id) = @_;
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $screen_line = `screen -list | grep $screen_id`;
	return $1 if($screen_line =~ /([0-9]+)\.$screen_id/);
	return "";
}

sub add_expected_port
{
	my ($ports, $seen, $name, $port, $protocol) = @_;
	return unless(defined($port) && $port =~ /^[0-9]+$/ && $port > 0 && $port <= 65535);
	$protocol = "any" unless(defined($protocol) && $protocol =~ /^(tcp|udp|any)$/i);
	$protocol = lc($protocol);
	my $key = $protocol . ":" . $port;
	return if($seen->{$key});
	$seen->{$key} = 1;
	push(@$ports, {name => $name, port => int($port), protocol => $protocol});
}

sub parse_port_list
{
	my ($ports, $seen, $name, $value) = @_;
	return unless(defined($value) && $value ne "");
	foreach my $part (split(/[,\s;]+/, $value))
	{
		next if($part eq "");
		if($part =~ /^([0-9]{1,5})(?:\/(tcp|udp|any))?$/i ||
		   $part =~ /^(tcp|udp|any):([0-9]{1,5})$/i)
		{
			my ($port, $protocol);
			if($part =~ /^([0-9]{1,5})(?:\/(tcp|udp|any))?$/i)
			{
				($port, $protocol) = ($1, $2 || "any");
			}
			else
			{
				($protocol, $port) = ($1, $2);
			}
			add_expected_port($ports, $seen, $name, $port, $protocol);
		}
	}
}

sub build_expected_ports
{
	my ($server_port, $query_port, $rcon_port) = @_;
	my @ports;
	my %seen;
	parse_port_list(\@ports, \%seen, "game", $server_port);
	parse_port_list(\@ports, \%seen, "query", $query_port);
	parse_port_list(\@ports, \%seen, "rcon", $rcon_port);
	return @ports;
}

sub collect_listening_ports_without_decrypt
{
	my (%listening_tcp, %listening_udp);
	my $ps_cmd = q!powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$p=[System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties();\$p.GetActiveTcpListeners()|ForEach-Object{'TCP '+\$_.Port};\$p.GetActiveUdpListeners()|ForEach-Object{'UDP '+\$_.Port}" 2>/dev/null!;
	my $out = `$ps_cmd`;

	if(defined($out) && $out =~ /\S/)
	{
		foreach my $line (split(/\r?\n/, $out))
		{
			$listening_tcp{$1} = 1 if($line =~ /^TCP\s+([0-9]{1,5})$/i);
			$listening_udp{$1} = 1 if($line =~ /^UDP\s+([0-9]{1,5})$/i);
		}
		return (\%listening_tcp, \%listening_udp) if(keys(%listening_tcp) || keys(%listening_udp));
	}

	$out = `netstat -an 2>/dev/null`;
	foreach my $line (split(/\r?\n/, $out))
	{
		if($line =~ /^\s*TCP\s+\S+[:.]([0-9]{1,5})\s+\S+\s+LISTENING/i)
		{
			$listening_tcp{$1} = 1;
		}
		elsif($line =~ /^\s*UDP\s+\S+[:.]([0-9]{1,5})\s+/i)
		{
			$listening_udp{$1} = 1;
		}
	}
	return (\%listening_tcp, \%listening_udp);
}

sub validate_expected_ports
{
	my (@expected_ports) = @_;
	my ($listening_tcp, $listening_udp) = collect_listening_ports_without_decrypt();
	my (@listening, @missing);

	foreach my $expected (@expected_ports)
	{
		my $port = $expected->{port};
		my $protocol = $expected->{protocol};
		my $found = 0;
		$found = 1 if(($protocol eq "tcp" || $protocol eq "any") && $listening_tcp->{$port});
		$found = 1 if(($protocol eq "udp" || $protocol eq "any") && $listening_udp->{$port});
		if($found)
		{
			push(@listening, $expected);
		}
		else
		{
			push(@missing, $expected);
		}
	}
	return (\@listening, \@missing);
}

sub has_listening_port_named
{
	my ($ports, $name) = @_;
	foreach my $port (@$ports)
	{
		return 1 if($port->{name} eq $name);
	}
	return 0;
}

sub is_port_listening_without_decrypt
{
	my ($server_ip, $port, $protocol) = @_;
	return 0 unless(defined($port) && $port =~ /^[0-9]+$/ && $port > 0 && $port <= 65535);
	$protocol = "any" unless(defined($protocol) && $protocol =~ /^(tcp|udp|any)$/i);
	my ($listening_tcp, $listening_udp) = collect_listening_ports_without_decrypt();
	return 1 if(($protocol eq "tcp" || $protocol eq "any") && $listening_tcp->{$port});
	return 1 if(($protocol eq "udp" || $protocol eq "any") && $listening_udp->{$port});
	return 0;
}

sub get_agent_cpu_usage_percent
{
	open(STAT, '/proc/stat') or return "";
	my $line = <STAT>;
	close STAT;
	return "" unless(defined($line) && $line =~ /^cpu\s+/);
	my @first = split(/\s+/, $line);
	sleep 1;
	open(STAT, '/proc/stat') or return "";
	$line = <STAT>;
	close STAT;
	return "" unless(defined($line) && $line =~ /^cpu\s+/);
	my @second = split(/\s+/, $line);
	my $idle_diff = ($second[4] || 0) - ($first[4] || 0);
	my $total_first = 0;
	my $total_second = 0;
	for(my $i = 1; $i < @first; $i++) { $total_first += $first[$i] || 0; }
	for(my $i = 1; $i < @second; $i++) { $total_second += $second[$i] || 0; }
	my $total_diff = $total_second - $total_first;
	return "" if($total_diff <= 0);
	return sprintf("%.2f", (100 * ($total_diff - $idle_diff)) / $total_diff);
}

sub get_agent_memory_usage_percent
{
	my($total, $available, $free, $buffers, $cached) = qw(0 0 0 0 0);
	open(STAT, '/proc/meminfo') or return "";
	while (<STAT>)
	{
		$total += $1 if /MemTotal:\s+(\d+) kB/;
		$available += $1 if /MemAvailable:\s+(\d+) kB/;
		$free += $1 if /MemFree:\s+(\d+) kB/;
		$buffers += $1 if /Buffers:\s+(\d+) kB/;
		$cached += $1 if /^Cached:\s+(\d+) kB/;
	}
	close STAT;
	return "" if($total <= 0);
	my $used = $available > 0 ? $total - $available : $total - $free - $buffers - $cached;
	return sprintf("%.2f", (100 * $used) / $total);
}

sub server_status_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $query_port, $rcon_port, $startup_timeout, $state_hint) = @_;
	return gm_status_reply($home_id);
	$startup_timeout = STARTUP_VALIDATION_TIMEOUT unless(defined($startup_timeout) && $startup_timeout =~ /^[0-9]+$/ && $startup_timeout > 0);
	$query_port = "" unless(defined($query_port) && $query_port =~ /^[0-9,;:\s\/a-zA-Z]+$/);
	$rcon_port = "" unless(defined($rcon_port) && $rcon_port =~ /^[0-9,;:\s\/a-zA-Z]+$/);
	$state_hint = "" unless(defined($state_hint));

	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $session_running = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;
	my $screen_pid = $session_running ? get_screen_pid_without_decrypt($home_id) : "";
	my $pid_meta = read_pid_metadata($home_id);
	my $windows_pid = defined($pid_meta->{windows_pid}) ? $pid_meta->{windows_pid} : "";
	my $game_pid = defined($pid_meta->{game_pid}) ? $pid_meta->{game_pid} : "";
	my $pid_running = 0;
	$pid_running = 1 if($screen_pid ne "" && is_pid_alive_without_decrypt($screen_pid) == 1);
	$pid_running = 1 if(!$pid_running && $windows_pid ne "" && is_pid_alive_without_decrypt($windows_pid) == 1);
	$pid_running = 1 if(!$pid_running && $game_pid ne "" && is_pid_alive_without_decrypt($game_pid) == 1);
	my $process_running = ($session_running || $pid_running) ? 1 : 0;
	# A saved STOPPED state is authoritative: stale PIDs must not make a stopped server look running.
	my (undef, $saved_hint) = read_status_hint($home_id);
	if (defined $saved_hint && $saved_hint eq "STOPPED") { $session_running = 0; $pid_running = 0; $process_running = 0; }
	my @expected_ports = build_expected_ports($server_port, $query_port, $rcon_port);
	my ($listening_ports, $missing_ports) = PORT_VALIDATION_ENABLED ? validate_expected_ports(@expected_ports) : ([], []);
	my $expected_count = scalar(@expected_ports);
	my $listening_count = scalar(@$listening_ports);
	my $missing_count = scalar(@$missing_ports);
	my $game_port_listening = has_listening_port_named($listening_ports, "game");
	my $query_port_listening = has_listening_port_named($listening_ports, "query");
	my $rcon_port_listening = has_listening_port_named($listening_ports, "rcon");
	if(!PORT_VALIDATION_ENABLED)
	{
		$game_port_listening = is_port_listening_without_decrypt($server_ip, $server_port);
		$query_port_listening = $query_port ne "" ? is_port_listening_without_decrypt($server_ip, $query_port) : 0;
		$rcon_port_listening = $rcon_port ne "" ? is_port_listening_without_decrypt($server_ip, $rcon_port) : 0;
	}
	my ($hint_timestamp, $stored_hint) = read_status_hint($home_id);
	my $effective_hint = $state_hint ne "" ? $state_hint : $stored_hint;
	if($game_port_listening && $stored_hint eq "STARTING") { write_status_hint($home_id, "RUNNING"); $stored_hint = "RUNNING"; $effective_hint = "RUNNING" if($state_hint eq ""); }
	my $last_error = "";
	my $status = "UNKNOWN";
	my $status_state = "Unknown";
	my $ready = 0;

	if(!$process_running && ((!PORT_VALIDATION_ENABLED && $game_port_listening) || ($expected_count > 0 && $listening_count > 0)))
	{
		$status = "WARNING";
		$status_state = "Warning";
		$last_error = "Required port is listening but the managed screen session is not running.";
	}
	elsif($process_running)
	{
		if(!PORT_VALIDATION_ENABLED && $game_port_listening)
		{
			$status = "ONLINE";
			$status_state = "Running";
			$ready = 1;
		}
		elsif(PORT_VALIDATION_ENABLED && $expected_count > 0 && $missing_count == 0)
		{
			$status = "ONLINE";
			$status_state = "Running";
			$ready = 1;
		}
		elsif(PORT_VALIDATION_ENABLED && $expected_count > 0 && $listening_count > 0)
		{
			$status = "ONLINE";
			$status_state = "Warning";
			$ready = 1;
			$last_error = "Process/session exists, but some required ports are not listening.";
		}
		elsif($effective_hint eq "STOPPING")
		{
			$status = "STOPPING";
			$status_state = "Stopping";
		}
		elsif($hint_timestamp > 0 && (time() - $hint_timestamp) > $startup_timeout)
		{
			$status = "UNRESPONSIVE";
			$status_state = "Failed";
			$last_error = "Process/session exists but no required ports are listening after startup timeout.";
		}
		else
		{
			$status = "STARTING";
			$status_state = "Starting";
		}
	}
	else
	{
		$status = "OFFLINE";
		$status_state = "Stopped";
	}

	my $status_info = {
		home_id => $home_id,
		status => $status,
		StatusState => $status_state,
		status_state => $status_state,
		ready => $ready,
		ProcessRunning => $process_running,
		process_running => $process_running,
		session_running => $session_running,
		pid_running => $pid_running,
		game_port_listening => $game_port_listening ? 1 : 0,
		query_port_listening => $query_port_listening ? 1 : 0,
		rcon_port_listening => $rcon_port_listening ? 1 : 0,
		PortValidationEnabled => PORT_VALIDATION_ENABLED ? 1 : 0,
		StartupValidationTimeoutSeconds => $startup_timeout,
		PortCheckIntervalSeconds => PORT_CHECK_INTERVAL_SECONDS,
		ExpectedPorts => \@expected_ports,
		expected_ports => \@expected_ports,
		ListeningPorts => $listening_ports,
		listening_ports => $listening_ports,
		MissingPorts => $missing_ports,
		missing_ports => $missing_ports,
		CPUUsage => get_agent_cpu_usage_percent(),
		MemoryUsage => get_agent_memory_usage_percent(),
		pid => $game_pid ne "" ? $game_pid : ($windows_pid ne "" ? $windows_pid : $screen_pid),
		screen_pid => $screen_pid,
		windows_pid => $windows_pid,
		linux_pid => "",
		session_name => $screen_id,
		ip => $server_ip,
		port => $server_port,
		query_port => $query_port,
		rcon_port => $rcon_port,
		game_port => $server_port,
		last_error => $last_error,
		query_info => ""
	};
	apply_watchdog_status_without_decrypt($status_info, $home_id);
	record_server_state_transition($status_info);
	return $status_info;
}

# Universal startup function
sub universal_start
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return universal_start_without_decrypt(decrypt_params(@_));
}

# Split to two parts because of internal calls.
sub universal_start_without_decrypt
{
	logger "Start request received by agent (universal_start).";
	my (
		$home_id, $home_path, $server_exe, $run_dir, $startup_cmd,
		$server_port, $server_ip, $cpu,	$nice, $preStart, $envVars, $game_key, $console_log
	   ) = @_;
	my $management_home = $home_path;
	{
		my $mgmt_win = clean(`cygpath -wa "$management_home"`); chomp($mgmt_win);
		my $exe_base = defined($server_exe) ? $server_exe : "";
		$exe_base =~ s{.*[\\/]}{};
		$GM_WINDOW{$home_id} = time();
		# Fix permissions before the watchdog launches the game (see take_ownership).
		take_ownership($management_home);
		my $gm_result = gm()->start($home_id, command => "\"$mgmt_win\\gamefiles\\$exe_base\" $startup_cmd", workdir => "$mgmt_win\\gamefiles", port => $server_port);
		logger "Start for HOME ID:$home_id returned " . ($gm_result->{ok} ? "started" : "not started: $gm_result->{reason}") . ".";
		return $gm_result->{ok} ? 1 : -14;
	}

	if (!-e $management_home)
	{
		logger "Can't find server management home [ $management_home ].";
		return -10;
	}

	my ($game_root, $game_key_error) = resolve_game_payload_root_without_decrypt($management_home, $game_key);
	if(!defined($game_root) || $game_root eq "")
	{
		logger "Invalid game payload root for HOME ID:$home_id: $game_key_error.";
		return -15;
	}
	if(!-d $game_root)
	{
		logger "Can't find game payload root [ $game_root ]. Existing homes must be manually rearranged under the validated game_key directory.";
		return -10;
	}

	if(is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1)
	{
		logger "Start requested for HOME ID:$home_id while screen " . create_screen_id(SCREEN_TYPE_HOME, $home_id) . " is already running; no new serverStart.bat launch will be attempted.";
		return 1;
	}

	# Watchdog mode: the watchdog owns stop and cleanup, so the screen-era hard-stop preflight is skipped.
	my $preflight = WATCHDOG_MODE ? { success => 1 } : lifecycle_hard_stop_without_decrypt($home_id, $server_ip, $server_port, $management_home, {
		remove_startup => 0,
		clean_content => 1,
		operation => "start_preflight"
	});
	if(!$preflight->{success})
	{
		logger "Start preflight failed for HOME ID:$home_id $server_ip:$server_port: " . ($preflight->{message} || "unknown cleanup failure");
		return -14;
	}

	if(is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1)
	{
		logger "Start generation skipped for HOME ID:$home_id because screen " . create_screen_id(SCREEN_TYPE_HOME, $home_id) . " appeared after preflight.";
		return 1;
	}

	# Some games require that the launch process starts in the executable directory.
	# $run_dir is "game_key/exe_location" relative to $management_home (set by the
	# Panel as game_key . "/" . exe_location, and persisted verbatim in the startup
	# flag files replayed above) - it already includes the game_key segment that
	# $game_root also carries, so it must be resolved against $management_home, not
	# $game_root. Joining against $game_root here double-prepended game_key and
	# pointed at a run directory that can never exist, failing every start with
	# "Invalid or missing game run directory" (confirmed live: a fresh home with no
	# exe_location configured resolved to game_root/game_key instead of game_root).
	my $run_rel = defined($run_dir) ? $run_dir : "";
	if (defined($game_key) && $game_key ne "" && $run_rel =~ m{^\Q$game_key\E(?:[\\/]|\z)}) { $run_rel =~ s{^\Q$game_key\E[\\/]?}{}; }
	my ($game_binary_dir, $run_dir_error) = resolve_game_payload_child_path_without_decrypt($game_root, $run_rel);
	if(!defined($game_binary_dir) || $game_binary_dir eq "" || !-d $game_binary_dir)
	{
		logger "Invalid or missing game run directory for HOME ID:$home_id: " . ($run_dir_error || $game_binary_dir || "");
		return -12;
	}
	if (!chdir $game_binary_dir)
	{
		logger "Could not change to server binary directory $game_binary_dir.";
		return -12;
	}

	my ($game_executable_path, $server_exe_error) = resolve_game_payload_child_path_without_decrypt($game_binary_dir, $server_exe);
	if(!defined($game_executable_path) || $game_executable_path eq "")
	{
		logger "Invalid game executable path for HOME ID:$home_id: $server_exe_error.";
		return -12;
	}
	if (!-x $game_executable_path)
	{
		if (!chmod 0755, $game_executable_path)
		{
			logger "The $game_executable_path file is not executable.";
			return -13;
		}
	}

	if(defined $preStart && $preStart ne ""){
		# Get it in the format that the startup file can use
		$preStart = startup_comma_format_to_multiline($preStart);
	}else{
		$preStart = "";
	}

	if(defined $envVars && $envVars ne ""){
		# Get it in the format that the startup file can use
		$envVars = startup_comma_format_to_multiline($envVars);

		# Replace variables in the envvars if they exist
		my @prestartenvvars = split /[\r\n]+/, $envVars;
		my $envVarStr = "";
		foreach my $line (@prestartenvvars) {
			$line = replace_GSP_Env_Vars("", $home_id, $game_root, $line, $game_key, $management_home);
			if($line ne ""){
				logger "Configuring environment variable: $line";
				$envVarStr .= "$line\r\n";
			}
		}

		if(defined $envVarStr && $envVarStr ne ""){
			$envVars = $envVarStr;
		}
	}else{
		$envVars = "";
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	prepare_server_content_runtime_without_decrypt($management_home);

	# Replace any GSP variables
	$startup_cmd = replace_GSP_Env_Vars($screen_id, $home_id, $game_root, $startup_cmd, $game_key, $management_home);
	if(WATCHDOG_MODE)
	{
		my $exe_name = defined($server_exe) ? $server_exe : "";
		$exe_name =~ s{.*[\\/]}{};
		my $win_game = defined($game_root) ? $game_root : "";
		$win_game =~ s{^/cygdrive/([A-Za-z])}{uc($1).":"}e;
		$win_game =~ s{/}{\\}g;
		my $body = "cd /d \"$win_game\"\r\n";
		if ($exe_name ne "" && index(lc($startup_cmd), lc($exe_name)) < 0) { $body .= "\"$exe_name\" $startup_cmd"; } else { $body .= $startup_cmd; }
		unlink("$management_home/status.stopped") if(-e "$management_home/status.stopped");
		my $screen_cmd = create_screen_cmd_loop(create_screen_id(SCREEN_TYPE_HOME, $home_id), $management_home, $win_game . "\\" . $exe_name, $startup_cmd, $win_game, $server_port, "", "", "");
		return -14 unless($screen_cmd);
		my $mgmt_w = $management_home;
		$mgmt_w =~ s{^/cygdrive/([A-Za-z])}{uc($1).":"}e;
		$mgmt_w =~ s{/}{\\}g;
		# Record what to restart after a reboot (read by the boot loop below).
		if (defined $server_ip && defined $server_port) {
			if (open(my $rf, '>', Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port"))) {
				print $rf join(',', $home_id, $management_home, $server_exe, $run_dir, $startup_cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) . "\n";
				close($rf);
			}
		}
		my $screen_rc = system("$screen_cmd </dev/null >/dev/null 2>&1"); logger "Watchdog screen launch for HOME ID:$home_id returned $screen_rc."; write_status_hint($home_id, "STARTING");
		my $bot_screen = create_bot_screen_cmd(create_screen_id(SCREEN_TYPE_HOME, $home_id), $management_home);
		my $bot_rc = system("$bot_screen </dev/null >/dev/null 2>&1") if($bot_screen ne ''); logger "Bot screen launch for HOME ID:$home_id returned " . (defined $bot_rc ? $bot_rc : "skipped") . ".";
		return 1;
	}

	my $priority_class = "";
	if($nice ne "NA")
	{
		if( $nice <= 19 and $nice >= 11 )
		{
			$priority_class = "Idle";
		}
		elsif( $nice <= 10 and $nice >= 1 )
		{
			$priority_class = "BelowNormal";
		}
		elsif( $nice == 0 )
		{
			$priority_class = "Normal";
		}
		elsif( $nice <= -1 and $nice >= -8  )
		{
			$priority_class = "AboveNormal";
		}
		elsif( $nice <= -9 and $nice >= -18 )
		{
			$priority_class = "High";
		}
		elsif( $nice == -19 )
		{
			$priority_class = "RealTime";
		}
	}

	my $affinity_mask = "";
	if($cpu ne "NA" and $cpu ne "" )
	{
		$affinity_mask = $cpu;
	}

	my $run_before_start;

	my $win_game_binary_dir = clean(`cygpath -wa "$game_binary_dir"`);
	chomp $win_game_binary_dir;
	my $win_game_executable_path = clean(`cygpath -wa "$game_executable_path"`);
	chomp $win_game_executable_path;

	# Create the startup string.
	my ($file_extension) = $server_exe =~ /(\.[^.]+)$/;

	my $cli_bin;

	# Create bash file to respawn process if it crashes or exits without user interaction
	# If a user stops the server, the process will not respawn

	if($file_extension eq ".jar")
	{
		$cli_bin = create_screen_cmd_loop($screen_id, $management_home, "cmd.exe", "/C $startup_cmd", $win_game_binary_dir, $server_port, $priority_class, $affinity_mask, $envVars);
	}
	elsif(($file_extension eq ".sh")||($file_extension eq ".bash"))
	{
		# There is no software made for windows that uses bash by default,
		# but it can be a good way to improve the server startup. To be able to use
		# sh/bash scripts as server executable I added this piece to the agent:
		$cli_bin = create_screen_cmd_loop($screen_id, $management_home, "cmd.exe", "/C bash $game_executable_path $startup_cmd", $win_game_binary_dir, $server_port, $priority_class, $affinity_mask, $envVars);
	}
	else
	{
		$cli_bin = create_screen_cmd_loop($screen_id, $management_home, $win_game_executable_path, "$startup_cmd", $win_game_binary_dir, $server_port, $priority_class, $affinity_mask, $envVars);
	}

	if(!defined($cli_bin) || $cli_bin eq "")
	{
		logger "Unable to generate serverStart.bat for HOME ID:$home_id.";
		return -14;
	}

	$management_home =~ s/\\/\//g;
	$game_root =~ s/\\/\//g;

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log( $home_id, $log_file, $game_root . "/" . $console_log );

	my $clean_cli_bin = $cli_bin;
	$clean_cli_bin =~ s/\\\\/\\/g;
	logger
	  "Startup command [ $clean_cli_bin ] will be executed in dir $game_binary_dir.";

	# Fix permissions
	my $ownerShipResults = take_ownership($management_home);

	# Run before start script from the management home while targeting game_root.
	$run_before_start = run_before_start_commands($home_id, $management_home, $game_root, $preStart, $envVars, $game_key);

	if(is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1)
	{
		logger "Start launch skipped for HOME ID:$home_id because screen " . create_screen_id(SCREEN_TYPE_HOME, $home_id) . " appeared before launch.";
		return 1;
	}

	if(!set_desired_state_without_decrypt($management_home, "running"))
	{
		logger "Unable to set desired lifecycle state to running for HOME ID:$home_id.";
		return -14;
	}
	system($cli_bin);
	my $screen_survived = wait_for_home_screen_survival_without_decrypt($home_id, 3);
	if(!$screen_survived)
	{
		logger "Unable to verify named screen " . create_screen_id(SCREEN_TYPE_HOME, $home_id) . " after launch for HOME ID:$home_id.";
		lifecycle_hard_stop_without_decrypt($home_id, $server_ip, $server_port, $management_home, {
			remove_startup => 0,
			clean_content => 1,
			operation => "screen_launch_failed"
		});
		return -14;
	}
	my $screen_pid = get_screen_pid_without_decrypt($home_id);
	my $watchdog_pid = wait_for_watchdog_cmd_pid_without_decrypt($management_home, 2);
	if($watchdog_pid eq "")
	{
		logger "Watchdog cmd.exe PID title " . windows_lifecycle_title_without_decrypt($management_home, "watchdog") . " is not visible for HOME ID:$home_id; continuing because the named screen session is alive.";
	}
	write_home_pid_file_without_decrypt($management_home, "watchdog.pid", $watchdog_pid) if($watchdog_pid ne "");
	my $game_pid = find_process_pid_by_port_without_decrypt($server_port, "any");
	write_pid_metadata($home_id, {
		screen_pid => $screen_pid,
		windows_pid => $watchdog_pid,
		game_pid => $game_pid,
		ip => $server_ip,
		port => $server_port
	});
	queue_agent_event("server_process_started", "info", {
		home_id => $home_id,
		management_home_path => $management_home,
		game_home_path => $game_root,
			ip => $server_ip,
			game_port => $server_port,
			screen_session_name => $screen_id,
			tracked_pid => $watchdog_pid ne "" ? $watchdog_pid : $screen_pid,
			detected_process_pid => $game_pid,
			actual_process_state => "starting",
			actual_session_state => "present",
			actual_port_state => "pending_validation",
		message => "Server process start command completed and the named screen survived launch; status polling will confirm port readiness."
	});

	if(defined $preStart && $preStart ne ""){
		# Get it in the format that the startup file can use
		$preStart = multiline_to_startup_comma_format($preStart);
	}else{
		$preStart = "";
	}

	if(defined $envVars && $envVars ne ""){
		# Get it in the format that the startup file can use
		$envVars = multiline_to_startup_comma_format($envVars);
	}else{
		$envVars = "";
	}

	# Create startup file for the server.
	my $startup_file =
	  Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");

	if (open(STARTUP, '>', $startup_file))
	{
		print STARTUP
		  "$home_id,$management_home,$server_exe,$run_dir,$startup_cmd,$server_port,$server_ip,$cpu,$nice,$preStart,$envVars,$game_key,$console_log";
		logger "Created startup flag for $server_ip-$server_port";
		close(STARTUP);
	}
	else
	{
		logger "Cannot create file in " . $startup_file . " : $!";
	}
	return 1;
}

# Returns the number of CPUs available.
sub cpu_count
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if (!-e "/proc/cpuinfo")
	{
		return "ERROR - Missing /proc/cpuinfo";
	}

	open(CPUINFO, '<', "/proc/cpuinfo")
	  or return "ERROR - Cannot open /proc/cpuinfo";

	my $cpu_count = 0;

	while (<CPUINFO>)
	{
		chomp;
		next if $_ !~ /^processor/;
		$cpu_count++;
	}
	close(CPUINFO);
	return "$cpu_count";
}

### File exists check ####
# Simple a way to check if a file exists using the remote agent
#
# @return 0 when file exists.
# @return 1 when file does not exist.
sub rfile_exists
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $checkFile = decrypt_param(@_);

	if (-e $checkFile)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

##### Quick check to verify agent is up and running
# Used to quickly see if the agent is online, and if the keys match.
# The message that is sent to the agent must be hello, if not then
# it is intrepret as encryption key missmatch.
#
# @return 1 when encrypted message is not 'hello'
# @return 0 when check is ok.
sub quick_chk
{
	my $dec_check = &decrypt_param(@_);
	if ($dec_check ne 'hello')
	{
		logger "ERROR - Encryption key mismatch! Returning 1 to asker.";
		return 1;
	}
	return 0;
}

sub log_path_has_wildcards
{
	my ($path) = @_;
	return defined($path) && $path =~ /[*?\[]/ ? 1 : 0;
}

sub wildcard_pattern_to_regex
{
	my ($pattern) = @_;
	return undef unless defined($pattern);

	my $regex = '';
	my @chars = split(//, $pattern);
	my $in_class = 0;
	for (my $i = 0; $i <= $#chars; $i++)
	{
		my $c = $chars[$i];
		if (!$in_class)
		{
			if ($c eq '*')
			{
				$regex .= '[^/]*';
			}
			elsif ($c eq '?')
			{
				$regex .= '[^/]';
			}
			elsif ($c eq '[')
			{
				$in_class = 1;
				$regex .= '[';
			}
			else
			{
				$regex .= quotemeta($c);
			}
		}
		else
		{
			if ($c eq ']')
			{
				$in_class = 0;
				$regex .= ']';
			}
			else
			{
				$regex .= $c;
			}
		}
	}

	return undef if $in_class;
	return qr/^$regex\z/i;
}

sub resolve_latest_log_match
{
	my ($home_path, $pattern) = @_;
	return undef if !defined($home_path) || !defined($pattern) || $pattern eq "";

	$pattern =~ s{\\}{/}g;
	$pattern =~ s{^\./+}{};
	return undef if $pattern =~ /\0/;
	return undef if $pattern =~ m{^/};
	return undef if $pattern =~ m{(^|/)\.\.(?:/|$)};

	my $home_abs = abs_path($home_path);
	return undef unless defined($home_abs);
	my $regex = wildcard_pattern_to_regex($pattern);
	return undef unless defined($regex);
	my $glob_pattern = $pattern;
	$glob_pattern =~ s/\[([^\]]+)\]/\*/g;
	my @matches = bsd_glob("$home_path/$glob_pattern", GLOB_NOSORT);
	my @candidates = ();
	foreach my $candidate (@matches)
	{
		next unless -f $candidate;
		my $candidate_abs = abs_path($candidate);
		next unless defined($candidate_abs);
		next unless $candidate_abs eq $home_abs || index($candidate_abs, "$home_abs/") == 0;
		my $candidate_rel = $candidate_abs;
		$candidate_rel =~ s{\\}{/}g;
		my $home_norm = $home_abs;
		$home_norm =~ s{\\}{/}g;
		$candidate_rel =~ s/^\Q$home_norm\E\/?//;
		next unless $candidate_rel =~ $regex;
		my $mtime = (stat($candidate_abs))[9] || 0;
		push(@candidates, [ $candidate_abs, $mtime ]);
	}

	return undef unless scalar(@candidates) > 0;
	@candidates = sort { $b->[1] <=> $a->[1] || $b->[0] cmp $a->[0] } @candidates;
	return $candidates[0]->[0];
}

### Return -10 If home path is not found.
### Return -9  If log type was invalid.
### Return -8  If log file was not found.
### 0 reserved for connection problems.
### Return 1;content If log found and screen running.
### Return 2;content If log found but screen is not running.
# Is the game server up? The game manager is the source of truth (status file + live PID).
# Screen is only a fallback for non-game screens.
sub log_server_is_running
{
	my ($screen_type, $home_id) = @_;
	if ($screen_type eq SCREEN_TYPE_HOME) {
		my $st = gm()->read_state($home_id);
		return 1 if (($st->{state} eq 'RUNNING' || $st->{state} eq 'STARTING')
			&& $st->{pid} && GameManagerWin::pid_alive($st->{pid}));
		return 0;
	}
	return is_screen_running_without_decrypt($screen_type, $home_id) == 1 ? 1 : 0;
}

sub get_log
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id, $home_path, $nb_of_lines, $log_file) = decrypt_params(@_);
	my $log_request_wildcard = 0;

	if (!chdir $home_path)
	{
		logger "Can't change to server's install path [ $home_path ].";
		return -10;
	}

	if (   ($screen_type eq SCREEN_TYPE_UPDATE)
		&& ($screen_type eq SCREEN_TYPE_HOME))
	{
		logger "Invalid screen type '$screen_type'.";
		return -9;
	}

	if(!$log_file)
	{
		my $screen_id = create_screen_id($screen_type, $home_id);
		$log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	}
	else
	{
		if (log_path_has_wildcards($log_file))
		{
			$log_request_wildcard = 1;
			my $resolved_log_file = resolve_latest_log_match($home_path, $log_file);
			if (!defined($resolved_log_file))
			{
				logger "No log files matched wildcard pattern '$log_file' in '$home_path'.";
				return "-8;" . encode("No log files matched pattern: $log_file");
			}
			logger "Wildcard log '$log_file' resolved to '$resolved_log_file'.";
			$log_file = Path::Class::File->new($resolved_log_file);
		}
		else
		{
			$log_file = Path::Class::File->new($home_path, $log_file);
		}
	}

	chmod 0644, $log_file;

	# Create local copy of current log file if SCREEN_LOG_LOCAL = 1
	if(SCREEN_LOG_LOCAL == 1)
	{
		my $log_local = Path::Class::File->new($home_path, "LOG_$screen_type.txt");
		if ( -e $log_local )
		{
			unlink $log_local;
		}

		# Copy log file only if it's not an UPDATE type as it may contain steam credentials
		if($screen_type eq SCREEN_TYPE_HOME){
			copy($log_file, $log_local);
		}
	}

	# Regenerate the log file if it doesn't exist
	unless ( -e $log_file )
	{
		if ($log_request_wildcard)
		{
			logger "Wildcard log file does not resolve to an existing file: " . $log_file;
			return -8;
		}

		if (open(NEWLOG, '>', $log_file))
		{
			logger "Log file missing, regenerating: " . $log_file;
			print NEWLOG "Log file missing, started new log\n";
			close(NEWLOG);
		}
		else
		{
			logger "Cannot regenerate log file in " . $log_file . " : $!";
			return -8;
		}
	}

	# Return a few lines of output to the web browser
	my(@modedlines) = `tail -n $nb_of_lines $log_file`;

	my $linecount = 0;

	foreach my $line (@modedlines) {
		#Remove unwanted characters (https://superuser.com/questions/99128/removing-the-escape-characters-from-gnu-screens-screenlog-n)
		$line =~ s/\x1b[[()=][;?0-9]*[0-9A-Za-z]?//g;
		$line =~ s/\r//g;
		$line =~ s/\007//g;
		#Text replacements to remove the Steam user login from steamcmd logs for security reasons.
		$line =~ s/login .*//g;
		$line =~ s/Logging .*//g;
		$line =~ s/set_steam_guard_code.*//g;
		$line =~ s/force_install_dir.*//g;
		#Text replacements to remove empty lines.
		$line =~ s/^ +//g;
		$line =~ s/^\t+//g;
		$line =~ s/^\e+//g;
		#Remove � from console output when master server update is running.
		$line =~ s/�//g;
		$modedlines[$linecount]=$line;
		$linecount++;
	}

	my $encoded_content = encode_list(@modedlines);
	chdir AGENT_RUN_DIR;
	if( log_server_is_running($screen_type, $home_id) )
	{
		return "1;" . $encoded_content;
	}
	else
	{
		return "2;" . $encoded_content;
	}
}

# stop server function
sub stop_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_server_without_decrypt(decrypt_params(@_));
}

##### Stop server without decrypt
### Return 1 when error occurred on decryption.
### Return 0 on success
sub stop_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $home_path) = @_;
	logger "Stop request received for HOME ID:$home_id.";
	$GM_WINDOW{$home_id} = time();
	gm()->stop($home_id);
	return 0;

	# 1. Tell the watchdog and bot to exit.
	if (open(my $sf, '>', "$home_path/status.stopped")) { close($sf); }

	# 2. Kill the PIDs we recorded for the game and the bot.
	foreach my $pidfile ("$home_path/game.pid", "$home_path/bot.pid")
	{
		next unless(-e $pidfile);
		open(my $ph, '<', $pidfile) or next;
		my $pid = <$ph>;
		close($ph);
		if (defined $pid) { $pid =~ s/\s+//g; system("taskkill /F /T /PID $pid >nul 2>&1") if($pid =~ /^\d+$/); }
	}

	# 3. Kill whatever process owns the game port, even if its PID file is gone.
	if (defined $server_port && $server_port =~ /^\d+$/)
	{
		my @net = (`netstat -ano -p UDP 2>nul`, `netstat -ano -p TCP 2>nul`);
		my %owners;
		foreach my $line (@net)
		{
			next unless($line =~ /:$server_port\s/);
			my ($pid) = $line =~ /(\d+)\s*$/;
			$owners{$pid} = 1 if(defined $pid && $pid > 4);
		}
		foreach my $pid (keys %owners) { system("taskkill /F /T /PID $pid >nul 2>&1"); }
	}

	# 4. Close the screen sessions for this server (watchdog and bot).
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	system("screen -S $screen_id -X quit >/dev/null 2>&1");
	system("screen -S ${screen_id}_bot -X quit >/dev/null 2>&1");
	# Quitting screen can fail and leave the session alive. Kill any session process left for this server by PID.
	foreach my $sid ($screen_id, "${screen_id}_bot")
	{
		foreach my $line (`screen -ls 2>/dev/null`)
		{
			if ($line =~ /^\s*(\d+)\.\Q$sid\E\s/) { my $spid = $1; system("kill -9 $spid >/dev/null 2>&1"); logger "Killed leftover screen session $sid (pid $spid)."; }
		}
	}

	# 5. Clear the startup flag and record the server as stopped.
	my $startup_file = Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");
	unlink($startup_file) if(-e $startup_file);
	set_desired_state_without_decrypt($home_path, "stopped");
	write_status_hint($home_id, "STOPPED");
	foreach my $pf ("$home_path/game.pid", "$home_path/bot.pid") { unlink($pf) if(-e $pf); }
	logger "Stop completed for HOME ID:$home_id.";
	return 0;
}

sub verify_runtime_stop_complete_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $home_path) = @_;
	for(my $i = 0; $i < 30; $i++)
	{
		my $session_running = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;
		my @running_pids = grep { is_pid_alive_without_decrypt($_) } tracked_lifecycle_pids_without_decrypt($home_id, $home_path);
		my @port_owners = collect_port_owners_without_decrypt($server_port, "any");
		my $bot_title_running = window_title_is_present_without_decrypt(windows_lifecycle_title_without_decrypt($home_path, "bot"));
		my $bot_marker_running = command_marker_is_present_without_decrypt(windows_lifecycle_bot_marker_without_decrypt($home_path));
		my @bot_pids = grep { is_pid_alive_without_decrypt($_) } find_windows_pids_for_also_run_without_decrypt($home_path);
		if(!$session_running && !@running_pids && !@port_owners && !$bot_title_running && !$bot_marker_running && !@bot_pids)
		{
			queue_agent_event("server_stop_confirmed", "info", {
				home_id => $home_id,
				ip => $server_ip,
				game_port => $server_port,
				tracked_pid => "",
				actual_process_state => "stopped",
				actual_session_state => "stopped",
				actual_port_state => "closed",
				message => "Server stop confirmed after process, session, and port validation."
			});
			return 0;
		}
		sleep 2;
	}
	my $session_running = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;
	my @running_pids = grep { is_pid_alive_without_decrypt($_) } tracked_lifecycle_pids_without_decrypt($home_id, $home_path);
	my @port_owners = collect_port_owners_without_decrypt($server_port, "any");
	my $bot_title_running = window_title_is_present_without_decrypt(windows_lifecycle_title_without_decrypt($home_path, "bot"));
	my $bot_marker_running = command_marker_is_present_without_decrypt(windows_lifecycle_bot_marker_without_decrypt($home_path));
	my @bot_pids = grep { is_pid_alive_without_decrypt($_) } find_windows_pids_for_also_run_without_decrypt($home_path);
	if($session_running || @running_pids || @port_owners || $bot_title_running || $bot_marker_running || @bot_pids)
	{
		logger "Server $server_ip:$server_port still has screen, process, BOT marker/process/title, or port evidence after stop escalation.";
		queue_agent_event("server_unresponsive", "error", {
			home_id => $home_id,
			ip => $server_ip,
			game_port => $server_port,
			tracked_pid => join(',', @running_pids, @bot_pids),
			actual_process_state => (@running_pids || $bot_title_running || $bot_marker_running || @bot_pids) ? "running" : "stopped",
			actual_session_state => $session_running ? "running" : "stopped",
			actual_port_state => @port_owners ? "listening" : "closed",
			message => "Server remained active after stop escalation; verify watchdog PID, BOT marker/process identity, and configured game port."
		});
		return 1;
	}
	queue_agent_event("server_stop_confirmed", "info", {
		home_id => $home_id,
		ip => $server_ip,
		game_port => $server_port,
		tracked_pid => "",
		actual_process_state => "stopped",
		actual_session_state => "stopped",
		actual_port_state => "closed",
		message => "Server stop confirmed after escalation."
	});
	return 0;
}

sub force_stop_server
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $server_ip, $server_port, $home_path) = decrypt_params(@_);
	return force_stop_server_without_decrypt($home_id, $server_ip, $server_port, $home_path);
}

sub force_stop_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $home_path) = @_;
	my $result = lifecycle_hard_stop_without_decrypt($home_id, $server_ip, $server_port, $home_path, {
		remove_startup => 1,
		clean_content => 1,
		operation => "force_stop"
	});
	my $session_running = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;
	my @remaining = ref($result->{remaining_pids}) eq 'ARRAY' ? @{$result->{remaining_pids}} : ();
	my $process_running = @remaining ? 1 : 0;
	my @port_owners = collect_port_owners_without_decrypt($server_port, "any");
	my $port_listening = @port_owners ? 1 : 0;
	my $success = $result->{success} ? 1 : 0;
	my $message = $success ? 'Force Stop completed. The game server was not restarted.' : 'Force Stop could not fully stop the server. Review remaining process/session/port state.';
	queue_agent_event($success ? "server_force_stop_confirmed" : "server_force_stop_failed", $success ? "warning" : "error", {
		home_id => $home_id,
		ip => $server_ip,
		game_port => $server_port,
		message => $message
	});
	return component_update_response(
		success => $success,
		status => $success ? 'STOPPED' : ($result->{status} || 'UNRESPONSIVE'),
		message => $success ? $message : ($result->{message} || $message),
		home_id => $home_id,
		ip => $server_ip,
		port => $server_port,
		session_running => $session_running,
		process_running => $process_running,
		port_listening => $port_listening,
		attempted_pids => join(',', @{ $result->{attempted_pids} || [] }),
		killed_pids => join(',', @{ $result->{attempted_pids} || [] }),
		remaining_pids => join(',', @remaining),
		log_hint => AGENT_LOG_FILE
	);
}

##### Send RCON command
### Return 0 when error occurred on decryption.
### Return 1 on success
sub send_rcon_command
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $rconCommand) = decrypt_params(@_);

	# legacy console
	if ($control_protocol eq "lcon")
	{
		my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
		system('screen -S '.$screen_id.' -p 0 -X stuff "'.$rconCommand.'$(printf \\\\r)"');
		logger "Sending legacy console command to ".$screen_id.": \n$rconCommand \n .";
		if ($? == 0)
		{
			my(@modedlines) = "$rconCommand";
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		return 0;
	}

	# Some validation checks for the variables.
	if ($server_ip =~ /^\s*$/ || $server_port < 0 || $server_port > 65535)
	{
		logger("Invalid IP:Port given $server_ip:$server_port.");
		return 0;
	}

	if ($control_password !~ /^\s*$/)
	{
		if ($control_protocol eq "rcon")
		{
			use KKrcon::KKrcon;
			my $rcon = new KKrcon(
								  Password => $control_password,
								  Host	 => $server_ip,
								  Port	 => $server_port,
								  Type	 => $control_type
								 );

			logger "Sending RCON command to $server_ip:$server_port: \n$rconCommand \n  .";

			my(@modedlines) = $rcon->execute($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		elsif ($control_protocol eq "rcon2")
		{
			use KKrcon::HL2;
			my $rcon2 = new HL2(
								  hostname => $server_ip,
								  port	 => $server_port,
								  password => $control_password,
								  timeout  => 2
								 );

			logger "Sending RCON command to $server_ip:$server_port: \n $rconCommand \n  .";

			my(@modedlines) = $rcon2->run($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		elsif ($control_protocol eq "armabe")
		{
			use ArmaBE::ArmaBE;
			my $armabe = new ArmaBE(
								  hostname => $server_ip,
								  port	 => $server_port, # Uses server port for now (Arma 2), Arma 3 BE uses a different, user definable port
								  password => $control_password,
								  timeout  => 2
								 );

			logger "Sending RCON command via ArmaBE module to $server_ip:$server_port: \n $rconCommand \n  .";

			my(@modedlines) = $armabe->run($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
	}
	else
	{
		logger "Control protocol PASSWORD NOT SET.";
		return -10;
	}
}

##### Returns a directory listing
### @return List of directories if everything OK.
### @return 0 If the directory is not found.
### @return -1 If cannot open the directory.
sub dirlist
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($datadir) = &decrypt_param(@_);
	logger "Asked for dirlist of $datadir directory.";
	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}
	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}
	my @dirlist = readdir(DIR);
	closedir(DIR);
	return join(";", @dirlist);
}

##### Returns a directory listing with extra info the filemanager
### @return List of directories if everything OK.
### @return 1 If the directory is empty.
### @return -1 If the directory is not found.
### @return -2 If cannot open the directory.
sub dirlistfm
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $datadir = &decrypt_param(@_);

	logger "Asked for dirlist of $datadir directory.";

	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}

	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}

	my %dirfiles = ();

	my (
		$dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		$size, $atime, $mtime, $ctime, $blksize, $blocks
	   );

	my $count = 0;

	chdir($datadir);

	while (readdir(DIR))
	{
		#skip the . and .. special dirs
		next if $_ eq '.';
		next if $_ eq '..';
		#print "Dir list is" . $_."\n";
		#Stat the file to get ownership and size
		(
		 $dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		 $size, $atime, $mtime, $ctime, $blksize, $blocks
		) = stat($_);

		if(defined $uid)
		{
			$uid = getpwuid($uid);
		}
		else
		{
			$uid = '';
		}

		if(defined $gid)
		{
			$gid = getgrgid($gid);
		}
		else
		{
			$gid = '';
		}

		#This if else logic determines what it is, File, Directory, other
		if (-T $_)
		{
			# print "File\n";
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
		}
		elsif (-d $_)
		{
			# print "Dir\n";
			$dirfiles{'directorys'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'directorys'}{$count}{'size'}		= $size;
			$dirfiles{'directorys'}{$count}{'user'}		= $uid;
			$dirfiles{'directorys'}{$count}{'group'}	= $gid;
		}
		elsif (-B $_)
		{
			#print "File\n";
			$dirfiles{'binarys'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'binarys'}{$count}{'size'}		= $size;
			$dirfiles{'binarys'}{$count}{'user'}		= $uid;
			$dirfiles{'binarys'}{$count}{'group'}		= $gid;
		}
		else
		{
			#print "Unknown\n"
			#will be listed as common files;
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
		}
		$count++;
	}
	closedir(DIR);

	if ($count eq 0)
	{
		logger "Empty directory $datadir.";
		return 1;
	}

	chdir AGENT_RUN_DIR;
	#Now we return it to the webpage, as array
	return {%dirfiles};
}

###### Returns the contents of a text file
sub readfile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $userfile = &decrypt_param(@_);

	unless ( -e $userfile )
	{
		if (open(BLANK, '>', $userfile))
		{
			close(BLANK);
		}
	}

	if (!open(USERFILE, '<', $userfile))
	{
		logger "ERROR - Can't open file $userfile for reading.";
		return -1;
	}

	my ($wholefile, $buf);

	while (read(USERFILE, $buf, 60 * 57))
	{
		$wholefile .= encode_base64($buf);
	}
	close(USERFILE);

	if(!defined $wholefile)
	{
		return "1; ";
	}

	return "1;" . $wholefile;
}

###### Backs up file, then writes data to new file
### @return 1 On success
### @return 0 In case of a failure
sub writefile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	# $writefile = file we're editing, $filedata = the contents were writing to it
	my ($writefile, $filedata) = &decrypt_params(@_);
	if (!-e $writefile)
	{
		open FILE, ">", $writefile;
	}
	else
	{
		# backup the existing file
		logger
		  "Backing up file $writefile to $writefile.bak before writing new databefore writing new data.";
		if (!copy("$writefile", "$writefile.bak"))
		{
			logger
			  "ERROR - Failed to backup $writefile to $writefile.bak. Error: $!";
			return 0;
		}
	}
	if (!-w $writefile)
	{
		logger "ERROR - File [ $writefile ] is not writeable!";
		return 0;
	}
	if (!open(WRITER, '>', $writefile))
	{
		logger "ERROR - Failed to open $writefile for writing.";
		return 0;
	}
	$filedata = decode_base64($filedata);
	$filedata =~ s/\r//g;
	print WRITER "$filedata";
	close(WRITER);
	logger "Wrote $writefile successfully!";
	return 1;
}

###### Reboots the server remotely through panel
### @return 1 On success
### @return 0 In case of a failure
sub rebootnow
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	system('shutdown -r -t 10');
	logger "Scheduled system reboot to occur in 10 seconds successfully!";
	return 1;
}

# Determine the os of the agent machine.
sub what_os
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	logger "Asking for OS type";
	my $ret = system('which uname >/dev/null 2>&1');
	if ($ret eq 0)
	{
		my $os = `\$(which uname) -a`;
		chomp $os;
		logger "OS is $os";
		return "$os";
	}
	else
	{
		logger "Cannot determine OS..that is odd";
		return "Unknown";
	}
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub start_file_download
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($url, $destination, $filename, $action, $post_script) = &decrypt_params(@_);
	logger
	  "Starting to download URL $url. Destination: $destination - Filename: $filename";

	if (!-e $destination)
	{
		logger "Creating destination directory.";
		if (!mkpath $destination )
		{
			logger "Could not create destination '$destination' directory : $!";
			return -2;
		}
	}

	my $download_file_path = Path::Class::File->new($destination, "$filename");

	my $pid = fork();
	if (not defined $pid)
	{
		logger "Could not allocate resources for download.";
		return -3;
	}

	# Only the forked child goes here.
	elsif ($pid == 0)
	{
		my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0,
													SSL_verify_mode => 0x00 } );
		$ua->agent('Mozilla/5.0');
		my $response = $ua->get($url, ':content_file' => "$download_file_path");

		if ($response->is_success)
		{
			logger "Successfully fetched $url and stored it to $download_file_path. Retval: ".$response->status_line;

			if (!-e $download_file_path)
			{
				logger "File $download_file_path does not exist.";
				exit(0);
			}

			if ($action eq "uncompress")
			{
				logger "Starting file uncompress as ordered.";
				uncompress_file_without_decrypt($download_file_path,
												$destination);
			}
		}
		else
		{
			logger
			  "Unable to fetch $url, or save to $download_file_path. Retval: ".$response->status_line;
			exit(0);
		}

		# Child process must exit.
		exit(0);
	}
	else
	{
		if ($post_script ne "")
		{
			logger "Running postscript commands.";
			my @postcmdlines = split /[\r\n]+/, $post_script;
			my $postcmdfile = $destination."/".'postinstall.sh';
			open  FILE, '>', $postcmdfile;
			print FILE "cd $destination\n";
			print FILE "while kill -0 $pid >/dev/null 2>&1\n";
			print FILE "do\n";
			print FILE "	sleep 1\n";
			print FILE "done\n";
			foreach my $line (@postcmdlines) {
				print FILE "$line\n";
			}
			print FILE "rm -f $destination/postinstall.sh\n";
			close FILE;
			chmod 0755, $postcmdfile;
			my $screen_id = create_screen_id("post_script", $pid);
			my $cli_bin = create_screen_cmd($screen_id, "bash $postcmdfile");
			system($cli_bin);
		}
		logger "Download process for $download_file_path has pid number $pid.";
		return "$pid";
	}
}

sub run_before_start_commands
{
	#return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($server_id, $management_home, $game_root, $beforestartcmd, $envVars, $game_key) = @_;
	$game_root = $management_home unless(defined($game_root) && $game_root ne "");

	if ($management_home ne "" && $server_id ne ""){
		my $windows_management_home = clean(`cygpath -wa "$management_home"`);
		my $windows_game_root = clean(`cygpath -wa "$game_root"`);

		# Run any prestart scripts
		if (defined $beforestartcmd && $beforestartcmd ne "")
		{
			logger "Running pre-start XML commands before starting server ID $server_id with management home $management_home and game root $game_root.";
			my @prestartcmdlines = split /[\r\n]+/, $beforestartcmd;
			my $prestartcmdfile = $windows_management_home . '\_prestart.bat';
			open  FILE, '>', $prestartcmdfile;
			print FILE "cd \"$windows_game_root\"\r\n";
			foreach my $line (@prestartcmdlines) {
				$line = replace_GSP_Env_Vars("", $server_id, $game_root, $line, $game_key, $management_home);
				print FILE "$line\r\n";
			}
			print FILE "exit\r\n";
			close FILE;
			chmod 0755, $prestartcmdfile;
			system("cmd /Q /C start /wait \"$prestartcmdfile\"");
			system("cmd /Q /C del \"$prestartcmdfile\"");
		}


		# Set and export any environment variables for game server developers unwilling to properly learn Linux
		if (defined $envVars && $envVars ne ""){
			my @prestartenvvars = split /[\r\n]+/, $envVars;
			foreach my $line (@prestartenvvars) {
				$line = replace_GSP_Env_Vars("", $server_id, $game_root, $line, $game_key, $management_home);
				if($line ne ""){
					logger "Configuring environment variable: $line";
					system($line);
				}
			}
		}

	}else{
		return -2;
	}

	return 1;
}

sub multiline_to_startup_comma_format{
	my ($multiLineVar) = @_;
	$multiLineVar =~ s/,//g; # commas are invalid anyways in bash
	$multiLineVar =~ s/[\r]+//g;
	$multiLineVar =~ s/[\n]+/{GSPNEWLINE}/g;
	return $multiLineVar;
}

sub startup_comma_format_to_multiline{
	my ($multiLineVar) = @_;
	$multiLineVar =~ s/{GSPNEWLINE}/\r\n/g;
	return $multiLineVar;
}

sub check_b4_chdir
{
	my ( $path ) = @_;

	if (!-e $path)
	{
		logger "$path does not exist yet. Trying to create it...";

		eval { mkpath($path); 1 } or logger "Error creating $path with Perl mkpath command. Errno: $! - Trying again with sudo...";

		if (!-e $path)
		{
			sudo_exec_without_decrypt('mkdir -p ' . $path);
		}

		if (!-e $path)
		{
			return -1;
		}
	}

	if (!chdir $path)
	{
		logger "Unable to change dir to '$path'.";
		return -1;
	}

	return 0;
}

sub create_bash_scripts
{
	my ( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds ) = @_;

	$home_path         =~ s/('+)/'\"$1\"'/g;
	$bash_scripts_path =~ s/('+)/'\"$1\"'/g;

	my @precmdlines = split /[\r\n]+/, $precmd;
	my $precmdfile = 'preinstall.sh';
	open  FILE, '>', $precmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@precmdlines) {
		print FILE "$line\n";
	}
	close FILE;
	chmod 0755, $precmdfile;

	my @postcmdlines = split /[\r\n]+/, $postcmd;
	my $postcmdfile = 'postinstall.sh';
	open  FILE, '>', $postcmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@postcmdlines) {
		print FILE "$line\n";
	}
	print FILE "cd '$bash_scripts_path'\n".
			   "rm -f preinstall.sh\n".
			   "rm -f postinstall.sh\n".
			   "rm -f runinstall.sh\n";
	close FILE;
	chmod 0755, $postcmdfile;

	my $installfile = 'runinstall.sh';
	open  FILE, '>', $installfile;
	print FILE "#!/bin/bash\n".
			   "cd '$bash_scripts_path'\n".
			   "./$precmdfile\n";
	foreach my $installcmd (@installcmds)
	{
		print FILE "$installcmd\n";
	}
	print FILE "wait ".'${!}'."\n".
			   "cd '$bash_scripts_path'\n".
			   "./$postcmdfile\n";
	close FILE;
	chmod 0755, $installfile;

	return $installfile;
}

#### Run the rsync update ####
### @return 1 If update started
### @return 0 In error case.
sub start_rsync_install
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $home_path, $url, $exec_folder_path, $exec_path, $precmd, $postcmd, $game_key) = decrypt_params(@_);

	if ( check_b4_chdir($home_path) != 0)
	{
		return 0;
	}
	my ($payload_root, $payload_error) = resolve_payload_root_for_current_rpc_without_decrypt($home_path, $game_key, "start_rsync_install");
	if(!defined($payload_root) || $payload_root eq "")
	{
		logger "Invalid rsync payload root for HOME ID:$home_id: $payload_error.";
		return 0;
	}
	if ( check_b4_chdir($payload_root) != 0)
	{
		return 0;
	}

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path) != 0)
	{
		return 0;
	}

	# Rsync install require the rsync binary to exist in the system
	# to enable this functionality.
	my $rsync_binary = Path::Class::File->new("/usr/bin", "rsync");

	if (!-f $rsync_binary)
		{
			logger "Failed to start rsync update from "
			  . $url
			  . " to $payload_root. Error: Rsync client not installed.";
			return 0;
		}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");

	backup_home_log( $home_id, $log_file );

	my $path	= $payload_root;
	$path		=~ s/('+)/'\"$1\"'/g;
	my @installcmds = ("/usr/bin/rsync --log-file='" . AGENT_RSYNC_GENERIC_LOG . "' --archive --compress --copy-links --update --verbose rsync://$url '$path'",
					   "cd '$path'",
					   "find -iname \\\*.exe -exec chmod -f +x {} \\\;",
					   "find -iname \\\*.bat -exec chmod -f +x {} \\\;");

	# Fix permissions
	my $ownerShipResults = take_ownership($home_path, "str");
	if(defined $ownerShipResults && $ownerShipResults ne ""){
		$postcmd .= "\n" . $ownerShipResults;
	}

		my $installfile = create_bash_scripts( $payload_root, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running rsync update: /usr/bin/rsync --log-file='" . AGENT_RSYNC_GENERIC_LOG . "' --archive --compress --copy-links --update --verbose rsync://$url '$payload_root'";
	system($screen_cmd);

	chdir AGENT_RUN_DIR;
	return 1;
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub master_server_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id,$home_path,$ms_home_id,$ms_home_path,$exec_folder_path,$exec_path,$precmd,$postcmd,$game_key,$ms_game_key) = decrypt_params(@_);

	if ( check_b4_chdir($home_path) != 0)
	{
		return 0;
	}
	my ($payload_root, $payload_error) = resolve_payload_root_for_current_rpc_without_decrypt($home_path, $game_key, "master_server_update");
	if(!defined($payload_root) || $payload_root eq "")
	{
		logger "Invalid master-server target payload root for HOME ID:$home_id: $payload_error.";
		return 0;
	}
	my ($source_payload_root, $source_error) = resolve_payload_root_for_current_rpc_without_decrypt($ms_home_path, $ms_game_key, "master_server_update source");
	if(!defined($source_payload_root) || $source_payload_root eq "")
	{
		logger "Invalid master-server source payload root for HOME ID:$ms_home_id: $source_error.";
		return 0;
	}
	if ( check_b4_chdir($payload_root) != 0)
	{
		return 0;
	}

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path) != 0)
	{
		return 0;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");

	backup_home_log( $home_id, $log_file );

	my $my_home_path = $payload_root;
	$my_home_path =~ s/('+)/'\"$1\"'/g;
	$source_payload_root =~ s/('+)/'\"$1\"'/g;

	my @installcmds = ("cp -vuRf  '$source_payload_root'/* '$my_home_path'");
	my $installfile = create_bash_scripts( $payload_root, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running master server update from home ID $home_id to home ID $ms_home_id";
	system($screen_cmd);

	chdir AGENT_RUN_DIR;
	return 1;
}

sub steam_cmd
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return steam_cmd_without_decrypt(decrypt_params(@_));
}

#### Run the steam client ####
### @return 1 If update started
### @return 0 In error case.
sub steam_cmd_without_decrypt
{
	my ($home_id, $home_path, $mod, $modname, $betaname, $betapwd, $user, $pass, $guard, $exec_folder_path, $exec_path, $precmd, $postcmd, $cfg_os, $filesToLockUnlock, $arch_bits, $game_key, $mode) = @_;
	# mode: '' (default, same as before), 'validate' or 'reinstall'.
	$mode = '' unless(defined $mode);

	# Creates home path if it doesn't exist
	if ( check_b4_chdir($home_path) != 0)
	{
		return 0;
	}
	my ($payload_root, $payload_error) = resolve_payload_root_for_current_rpc_without_decrypt($home_path, $game_key, "steam_cmd");
	if(!defined($payload_root) || $payload_root eq "")
	{
		logger "Invalid Steam payload root for HOME ID:$home_id: $payload_error.";
		return 0;
	}
	if ( check_b4_chdir($payload_root) != 0)
	{
		return 0;
	}
	if ( check_steam_cmd_client() == -1 )
	{
		logger "SteamCMD is unavailable; cannot run Steam update for home ID $home_id.", 1;
		return 0;
	}

    # Changes into root steamcmd GSP directory
	if ( check_b4_chdir(STEAMCMD_CLIENT_DIR) != 0)
	{
		return 0;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
	my $steam_binary = Path::Class::File->new(STEAMCMD_CLIENT_DIR, "steamcmd.exe");
	my $installSteamFile = $screen_id_for_txt_update . "_install.txt";

	my $windows_payload_root = clean(`cygpath -wa "$payload_root"`);

	my $installtxt = Path::Class::File->new($installSteamFile);

	open  FILE, '>', $installtxt;
	print FILE "\@ShutdownOnFailedCommand 1\n";
	print FILE "\@NoPromptForPassword 1\n";

	# Handle requested SteamCMD architecture
	if(defined $arch_bits && $arch_bits ne ""){
		print FILE "\@sSteamCmdForcePlatformBitness " . $arch_bits . "\n";
	}

	if(defined STEAM_DL_LIMIT && STEAM_DL_LIMIT ne "" && is_integer(STEAM_DL_LIMIT) && STEAM_DL_LIMIT > 0){
		print FILE "set_download_throttle " . STEAM_DL_LIMIT . "\n";
	}

	print FILE "force_install_dir \"$windows_payload_root\"\n";

	if($guard ne '')
	{
		print FILE "set_steam_guard_code $guard\n";
	}
	if($user ne '' && $user ne 'anonymous')
	{
		print FILE "login $user $pass\n";
	}
	else
	{
		print FILE "login anonymous\n";
	}

	my $vsuf = ($mode eq "validate") ? " validate" : "";
	if($modname ne "")
	{
		print FILE "app_set_config $mod mod $modname\n";
		print FILE "app_update $mod mod $modname" . ($mode eq "reinstall" ? "" : " validate") . "\n";
	}

	if($betaname ne "" && $betapwd ne "")
	{
		print FILE "app_update $mod -beta $betaname -betapassword $betapwd$vsuf\n";
	}
	elsif($betaname ne "" && $betapwd eq "")
	{
		print FILE "app_update $mod -beta $betaname$vsuf\n";
	}
	else
	{
		print FILE "app_update $mod$vsuf\n";
	}

	print FILE "exit\n";
	close FILE;

    my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path) != 0)
	{
		return 0;
	}

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log( $home_id, $log_file );

	my $postcmd_mod = $postcmd;

	# Fix permissions
	my $ownerShipResults = take_ownership($home_path, "str");
	if(defined $ownerShipResults && $ownerShipResults ne ""){
		$postcmd_mod .= "\n" . $ownerShipResults;
	}

	my @installcmds = ("$steam_binary +runscript $installtxt +exit; rm -f '$installtxt'");
	my $installfile = create_bash_scripts( $payload_root, $bash_scripts_path, $precmd, $postcmd_mod, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running steam update: $steam_binary +runscript $installtxt +exit";
	system($screen_cmd);

	return 1;
}

sub fetch_steam_version
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($appId, $pureOutput) = &decrypt_params(@_);
	my $ua = LWP::UserAgent->new;

	# Windows steam_cmd is bugged. So we cannot use the following until it's fixed.
	# https://github.com/ValveSoftware/Source-1-Games/issues/1929
	#my $steam_binary = Path::Class::File->new(STEAMCMD_CLIENT_DIR, "steamcmd.exe");
	#my $steam_options = "+login anonymous +app_info_update 1 +app_info_print \"$appId\" +quit";
	#my $grep = $pureOutput != "0" ? "" : '| grep -EA 1000 "^\s+\"branches\"$" | grep -EA 5 "^\s+\"public\"$" | grep -m 1 -EB 10 "^\s+}$" | grep -E "^\s+\"buildid\"\s+" | tr \'[:blank:]"\' \' \' | tr -s \' \' | cut -d\' \' -f3';

	#my $response = `$steam_binary $steam_options $grep`;

	logger "Getting latest version info for AppId $appId";

	$ua->agent('GSE Windows Agent v/' . AGENT_VERSION);
	$ua->timeout(10);

	my $response = $ua->get("http://gsp-panel.local/supported_games/api.php?appid=$appId&action=getBuildId");

	if ($response->is_success)
	{
		my $content = $response->decoded_content;

		if ($content =~ /^\d+\z/)
		{
			return $content;
		} else {
			return -9;
		}
	} else {
		return -10;
	}
}

sub installed_steam_version
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($game_home, $mod, $pureOutput) = &decrypt_params(@_);
	my $appFile = $game_home."/steamapps/appmanifest_$mod.acf";
	my $grep = $pureOutput != "0" ? "" : '| grep buildid | tr \'[:blank:]"\' \' \' | tr -s \' \' | cut -d\' \' -f3';

	if ( ! -f $appFile)
	{
		return "-10";
	}

	return `cat $appFile $grep`;
}

sub automatic_steam_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $game_home, $server_ip, $server_port, $exec_path, $exec_folder_path,
		$control_protocol, $control_password, $control_type,
		$appId, $modname, $betaname, $betapwd, $user, $pass, $guard, $precmd, $postcmd, $cfg_os, $filesToLockUnlock,
		$startup_cmd, $cpu, $nice, $preStart, $envVars, $game_key, $arch_bits, $console_log) = &decrypt_params(@_);

	# Is the server currently running? if it is, we'll try to start it after updating.
	my $isServerRunning = is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1 ? 1 : 0;

	# Check if an update is already happening.
	if (is_screen_running_without_decrypt(SCREEN_TYPE_UPDATE, $home_id) == 1)
	{
		logger("Update already running for server $home_id, unable to start automatic update.");
		return -10;
	}

	# Stop the server if it's running.
	if ($isServerRunning == 1)
	{
		logger("Stopping server $home_id for automatic update.");

		if (stop_server_without_decrypt($home_id, $server_ip, $server_port, $control_protocol, $control_password, $control_type, $game_home) != 0)
		{
			logger("Failed to stop server $home_id for automatic update. Exiting update procedure.");
			return -9
		}

	}

	# steam_cmd: Returns 0 if the update failed, in which case, don't try starting the server - because we may have an incomplete or corrupt installation.
	if (steam_cmd_without_decrypt($home_id, $game_home, $appId, $modname, $betaname, $betapwd, $user, $pass, $guard, $exec_folder_path, $exec_path, $precmd, $postcmd, $cfg_os, $filesToLockUnlock, $arch_bits, $game_key) == 0)
	{
		logger("Failed to start steam_cmd for server $home_id.");
		return -8;

	} else {

		if ($isServerRunning == 1)
		{
			while (1)
			{
				# If the update screen for $home_id isn't running, attempt to start the server.
				if (is_screen_running_without_decrypt(SCREEN_TYPE_UPDATE, $home_id) == 0)
				{

					if (universal_start_without_decrypt($home_id, $game_home, $exec_path, $exec_folder_path, $startup_cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) != 1)
					{
						logger("Failed to start server $home_id after automatic update.");
						return -7;
					} else {
						logger("Starting server $home_id after automatic update.");
						return 1;
					}

					last;
				}

				sleep 5;
			}

		} else {
			# Update was started, but server wasn't initially running.
			return 2;
		}

	}

}

sub rsync_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($running_home) = &decrypt_param(@_);
	logger "User requested progress on rsync job on home $running_home.";
	if (-r $running_home)
	{
		$running_home =~ s/('+)/'"$1"'/g;
		my $progress = `du -sk '$running_home'`;
		chomp($progress);
		my ($bytes, $junk) = split(/\s+/, $progress);
		logger("Found $bytes and $junk");
		return $bytes;
	}
	return "0";
}

sub is_file_download_in_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($pid) = &decrypt_param(@_);
	logger "User requested if download is in progress with pid $pid.";
	my @pids = `ps -ef`;
	@pids = grep(/$pid/, @pids);
	logger "Number of pids for file download: @pids";
	if (@pids > '0')
	{
		return 1;
	}
	return 0;
}

### \return 1 If file is uncompressed succesfully.
### \return 0 If file does not exist.
### \return -1 If file could not be uncompressed.
sub uncompress_file
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return uncompress_file_without_decrypt(decrypt_params(@_));
}

sub uncompress_file_without_decrypt
{

	# File must include full path.
	my ($file, $destination) = @_;

	logger "Uncompression called for file $file to dir $destination.";

	if (!-e $file)
	{
		logger "File $file could not be found for uncompression.";
		return 0;
	}

	if (!-e $destination)
	{
		mkpath($destination, {error => \my $err});
		if (@$err)
		{
			logger "Failed to create destination dir $destination.";
			return 0;
		}
	}

	my $ae = Archive::Extract->new(archive => $file);

	if (!$ae)
	{
		logger "Could not create archive instance for file $file.";
		return -1;
	}

	my $ok = $ae->extract(to => $destination);

	if (!$ok)
	{
		logger "File $file could not be uncompressed.";
		return -1;
	}

	system("chmod -Rf 755 $destination");
	system("cd $destination && find -iname \\\*.exe -exec chmod -f +x {} \\\;");
	system("cd $destination && find -iname \\\*.bat -exec chmod -f +x {} \\\;");

	logger "File uncompressed/extracted successfully.";
	return 1;
}

### \return 1 If files are compressed succesfully.
### \return -1 If files could not be compressed.
sub compress_files
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return compress_files_without_decrypt(decrypt_params(@_));
}

sub compress_files_without_decrypt
{
	my ($files,$destination,$archive_name,$archive_type) = @_;

	if (!-e $destination)
	{
		logger "compress_files: Destination path ( $destination ) could not be found.";
		return -1;
	}

	chdir $destination;
	my @items = split /\Q\n/, $files;
	my @inventory;
	if($archive_type eq "zip")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $zip = Archive::Zip->new();
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$zip->addFile( $item );
				}
				elsif (-d $item)
				{
					$zip->addTree( $item, $item );
				}
			}
		}
		# Save the file
		unless ( $zip->writeToFileNamed($archive_name.'.zip') == AZ_OK ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tbz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				}
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_BZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tgz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				}
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_GZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tar")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				}
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type") ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "bz2")
	{
		logger $archive_type." compression called.";
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					bzip2 $item => "$item.bz2";
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					foreach my $relative_item (@inventory) {
						bzip2 $relative_item => "$relative_item.bz2";
					}
				}
			}
		}
		logger $archive_type." archives created successfully at $destination";
		return 1;
	}
}

sub discover_ips
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($check) = decrypt_params(@_);

	if ($check ne "chk")
	{
		logger "Invalid parameter '$check' given for discover_ips function.";
		return "";
	}

	my $iplist = "";

	my @data = `ipconfig /all`;

	foreach my $temp (@data)
	{
		if ($temp =~ /ip.+: (\d+\.\d+\.\d+\.\d+)/si)
		{
			chomp $1;
			logger "Found an IP $1";
			$iplist .= "$1,";
		}
	}
	logger "IPlist is $iplist";
	chop $iplist;
	return "$iplist";
}

### Return -1 In case of invalid param
### Return 1;content in case of success
sub mon_stats
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($mon_stats) = decrypt_params(@_);
	if ($mon_stats ne "mon_stats")
	{
		logger "Invalid parameter '$mon_stats' given for $mon_stats function.";
		return -1;
	}

	my @disk			= `df -hP -x tmpfs`;
	my $encoded_content = encode_list(@disk);
	my @uptime		  = `net stats srv`;
	$encoded_content .= encode_list(@uptime);
	return "1;$encoded_content";
}

# ---------------------------------------------------------------------------
# restic job runner for the panel's self-service backup / restore (Cygwin agent).
#
# Secrets (RESTIC_REPOSITORY, RESTIC_PASSWORD) arrive XXTEA-encrypted like every
# other RPC parameter and reach restic only through its environment. They never
# appear in argv, in the job log, or in any file on disk.
#
# argv is checked against an allowlist of exact shapes, one per operation the
# panel needs. Anything else is refused. Backup paths must sit under the game
# home root.
#
# A job runs detached from the RPC request (double fork: the supervisor is
# re-parented to init, so the agent never has to reap it). Its state stays in the
# job directory until the panel reads it. A job whose supervisor is gone and that
# has no recorded result is reported as 'lost'.
# ---------------------------------------------------------------------------
use constant RESTIC_JOB_ROOT    => ($ENV{GSE_RESTIC_JOB_ROOT} || '/cygdrive/c/GSE/Agent/restic-jobs');
use constant RESTIC_HOME_ROOT   => 'C:\\GSE\\Agent\\home\\gameserver';
use constant RESTIC_OUTPUT_TAIL => 65536;

# A sub, not a file-scope hash: the RPC daemon serves requests before the
# file-scope statements below its start have run, so a hash assigned there is empty.
sub restic_env_key_ok
{
	my ($k) = @_;
	return ($k eq "RESTIC_REPOSITORY" || $k eq "RESTIC_PASSWORD") ? 1 : 0;
}

sub restic_job_id_ok
{
	my ($job_id) = @_;
	return (defined $job_id && $job_id =~ /^[a-f0-9]{32}\z/) ? 1 : 0;
}

sub restic_job_dir
{
	my ($job_id) = @_;
	return RESTIC_JOB_ROOT . "/$job_id";
}

sub restic_job_slurp
{
	my ($path) = @_;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $data = <$fh>;
	close($fh);
	return $data;
}

sub restic_job_write_file
{
	my ($path, $data) = @_;
	open(my $fh, '>', "$path.tmp") or return 0;
	print $fh $data;
	close($fh);
	return rename("$path.tmp", $path) ? 1 : 0;
}

sub restic_bin_path
{
	return $ENV{GSE_RESTIC_BIN} if ($ENV{GSE_RESTIC_BIN} && -f $ENV{GSE_RESTIC_BIN} && -x $ENV{GSE_RESTIC_BIN});
	foreach my $candidate ('/usr/bin/restic', '/usr/local/bin/restic', '/cygdrive/c/GSE/Agent/bin/restic.exe')
	{
		return $candidate if (-f $candidate && -x $candidate);
	}
	return undef;
}

# Paths restic may touch: a game server folder (<home root>\<digits>) or a path inside one.
# restic.exe is native Windows, so these are real Windows paths; no Cygwin paths and no '.' or '..' segments.
sub restic_arg_home_path_ok
{
	my ($path) = @_;
	return 0 unless (defined $path && length($path) <= 4096);
	my $root = RESTIC_HOME_ROOT;
	return 0 unless ($path =~ /\A\Q$root\E\\[0-9]{1,10}(?:\\[^\\\/:*?"<>|\x00-\x1f]+)*\z/);
	foreach my $seg (split /\\/, $path) { return 0 if ($seg eq '.' || $seg eq '..'); }
	return 1;
}

# The only restic invocations the panel uses. The repository is never an argument:
# it comes from RESTIC_REPOSITORY.
sub restic_job_argv_ok
{
	my ($argv) = @_;
	return 0 unless (ref($argv) eq 'ARRAY' && @$argv >= 2 && $argv->[0] eq 'restic');
	foreach my $arg (@$argv)
	{
		return 0 if (!defined($arg) || ref($arg) || $arg =~ /\x00/);
	}
	# Optional upload cap: restic --limit-upload <KiB/s> backup ... (flag must come before the subcommand).
	my @list = @$argv;
	if (@list >= 3 && $list[1] eq '--limit-upload')
	{
		return 0 unless ($list[2] =~ /^[0-9]{1,5}\z/ && $list[2] >= 256 && $list[2] <= 8192);
		splice(@list, 1, 2);
	}
	return 0 unless (@list >= 2);
	my ($sub, @args) = @list[1 .. $#list];

	if ($sub eq 'init')
	{
		return (@args == 0) ? 1 : 0;
	}
	if ($sub eq 'cat')
	{
		return (@args == 1 && $args[0] eq 'config') ? 1 : 0;
	}
	if ($sub eq 'backup')
	{
		# backup <game folder> --exclude <game folder>\restic-restore --tag <kind> --tag home-N --json
		# The exclude keeps restore staging out of the next backup.
		return (@args == 8
			&& restic_arg_home_path_ok($args[0])
			&& $args[1] eq '--exclude' && $args[2] eq $args[0] . '\restic-restore'
			&& $args[3] eq '--tag' && ($args[4] eq 'baseline' || $args[4] eq 'customer')
			&& $args[5] eq '--tag' && $args[6] =~ /^home-[0-9]{1,10}\z/
			&& $args[7] eq '--json') ? 1 : 0;
	}
	if ($sub eq 'restore')
	{
		# restore <snapshot> [--include <game folder path>] --target <game folder path>
		return 0 unless (@args >= 3 && $args[0] =~ /^[a-f0-9]{8,64}\z/);
		my @rest = @args[1 .. $#args];
		if (@rest && $rest[0] eq '--include')
		{
			return 0 unless (@rest >= 2 && restic_arg_home_path_ok($rest[1]));
			splice(@rest, 0, 2);
		}
		return (@rest == 2 && $rest[0] eq '--target' && restic_arg_home_path_ok($rest[1])) ? 1 : 0;
	}
	if ($sub eq 'forget')
	{
		return 0 unless (@args >= 2 && $args[0] eq '--prune');
		foreach my $id (@args[1 .. $#args])
		{
			return 0 unless ($id =~ /^[a-f0-9]{8,64}\z/);
		}
		return 1;
	}
	return 0;
}

sub restic_job_env_ok
{
	my ($env) = @_;
	return 0 unless (ref($env) eq 'HASH');
	foreach my $key (keys %$env)
	{
		return 0 unless (restic_env_key_ok($key) && defined($env->{$key}) && !ref($env->{$key}));
	}
	return (defined $env->{RESTIC_REPOSITORY} && defined $env->{RESTIC_PASSWORD}) ? 1 : 0;
}

# The result the supervisor wrote, or undef while the job has not finished.
sub restic_job_result
{
	my ($dir) = @_;
	my $raw = restic_job_slurp("$dir/status.json");
	return undef unless defined $raw;
	my $parsed = eval { JSON::PP->new->decode($raw) };
	return (ref($parsed) eq 'HASH' && defined $parsed->{exit}) ? $parsed : undef;
}

sub restic_supervisor_alive
{
	my ($dir) = @_;
	my $pid = restic_job_slurp("$dir/supervisor.pid");
	return 0 unless (defined $pid && $pid =~ /^(\d+)\s*$/);
	return kill(0, $1) ? 1 : 0;
}

sub restic_job_output_tail
{
	my ($dir) = @_;
	my $path = "$dir/output.log";
	return '' unless -f $path;
	my $size = -s $path;
	my $from = ($size > RESTIC_OUTPUT_TAIL) ? $size - RESTIC_OUTPUT_TAIL : 0;
	open(my $fh, '<', $path) or return '';
	seek($fh, $from, 0);
	local $/;
	my $tail = <$fh>;
	close($fh);
	return defined $tail ? $tail : '';
}

# Runs in the forked supervisor: detach, record own pid, run restic, record the result.
sub restic_run_supervisor
{
	my ($dir, $bin, $argv, $env) = @_;
	POSIX::setsid();
	$SIG{CHLD} = 'DEFAULT';
	restic_job_write_file("$dir/supervisor.pid", "$$\n");
	open(STDIN,  '<', '/dev/null');
	open(STDOUT, '>', '/dev/null');
	open(STDERR, '>&', \*STDOUT);
	POSIX::close($_) for (3 .. 255);

	my $worker = fork();
	POSIX::_exit(1) unless defined $worker;
	if ($worker == 0)
	{
		open(STDIN,  '<', '/dev/null');
		open(STDOUT, '>>', "$dir/output.log");
		open(STDERR, '>&', \*STDOUT);
		$SIG{CHLD} = 'DEFAULT';
		delete $ENV{$_} for grep { /^RESTIC_/ } keys %ENV;
		$ENV{$_} = $env->{$_} for keys %$env;
		exec { $bin } @$argv or POSIX::_exit(127);
	}
	waitpid($worker, 0);
	my $code = ($? & 127) ? 128 + ($? & 127) : ($? >> 8);
	restic_job_write_file("$dir/status.json",
		JSON::PP->new->canonical->encode({ state => 'done', exit => $code + 0, finished => time() }));
	POSIX::_exit(0);
}

# restic_job_start(job_id, argv_json, env_json, check)
# Returns "1;" + encode_list(state, ...). state: started | exists | error
sub restic_job_start
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($job_id, $argv_json, $env_json) = decrypt_params(@_);

	return "1;" . encode_list('error', 'bad_job_id') unless restic_job_id_ok($job_id);
	my $argv = eval { JSON::PP->new->utf8->decode($argv_json) };
	return "1;" . encode_list('error', 'bad_argv') unless restic_job_argv_ok($argv);
	my $env = eval { JSON::PP->new->utf8->decode($env_json) };
	return "1;" . encode_list('error', 'bad_env') unless restic_job_env_ok($env);
	my $bin = restic_bin_path();
	return "1;" . encode_list('error', 'no_restic') unless defined $bin;

	utf8::encode($_) for @$argv;
	utf8::encode($_) for values %$env;

	mkpath(RESTIC_JOB_ROOT, 0, 0700) unless -d RESTIC_JOB_ROOT;
	return "1;" . encode_list('error', 'job_root') unless -d RESTIC_JOB_ROOT;

	my $dir = restic_job_dir($job_id);
	# mkdir is the claim: only one start can create the job directory.
	if (!mkdir($dir, 0700))
	{
		return "1;" . encode_list(-e $dir ? 'exists' : 'error');
	}

	my $launcher = fork();
	if (!defined $launcher)
	{
		rmdir($dir);
		return "1;" . encode_list('error', 'fork');
	}
	if ($launcher == 0)
	{
		# Second fork: the supervisor is re-parented to init, so the agent never has to reap it.
		my $supervisor = fork();
		POSIX::_exit(1) unless defined $supervisor;
		restic_run_supervisor($dir, $bin, $argv, $env) if ($supervisor == 0);
		POSIX::_exit(0);
	}
	waitpid($launcher, 0);

	# Answer only once the supervisor has recorded itself, so the panel never polls
	# a job the agent cannot yet see.
	for (1 .. 100)
	{
		last if -e "$dir/supervisor.pid";
		select(undef, undef, undef, 0.05);
	}
	if (!-e "$dir/supervisor.pid")
	{
		# The supervisor never started. Clear the directory so the panel can retry under a new job id.
		File::Path::remove_tree($dir);
		return "1;" . encode_list('error', 'no_supervisor');
	}
	return "1;" . encode_list('started');
}

# restic_job_status(job_id, check)
# Returns "1;" + encode_list(state, exit_code, output_tail). state: running | done | lost | missing
sub restic_job_status
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($job_id) = decrypt_params(@_);
	return "1;" . encode_list('error', 'bad_job_id') unless restic_job_id_ok($job_id);

	my $dir = restic_job_dir($job_id);
	return "1;" . encode_list('missing') unless -d $dir;

	my $result = restic_job_result($dir);
	if (!defined $result && !restic_supervisor_alive($dir))
	{
		# The supervisor may have written its result just after the first read.
		$result = restic_job_result($dir);
	}
	if (defined $result)
	{
		return "1;" . encode_list('done', $result->{exit}, restic_job_output_tail($dir));
	}
	my $state = restic_supervisor_alive($dir) ? 'running' : 'lost';
	return "1;" . encode_list($state, '', restic_job_output_tail($dir));
}


sub exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($command) = decrypt_params(@_);
	my @cmdret		   = `$command 2>/dev/null`;
	my $encoded_content = encode_list(@cmdret);
	return "1;$encoded_content";
}

# used in conjunction with the clone_home feature in the web panel
# this actually does the file copies
sub clone_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($source_home, $dest_home, $owner) = decrypt_params(@_);
	my ($time_start, $time_stop, $time_diff);
	logger "Copying from $source_home to $dest_home...";

	# check size of source_home, make sure we have space to copy
	if (!-e $source_home)
	{
		logger "ERROR - $source_home does not exist";
		return 0;
	}
	logger "Game home $source_home exists...copy will proceed";

	# start the copy, and a timer
	$time_start = time();
	if (!dircopy("$source_home", "$dest_home"))
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Error occured after $time_diff seconds during copy of $source_home to $dest_home - $!";
		return 0;
	}
	else
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Home clone completed successfully to $dest_home in $time_diff seconds";
		return 1;
	}
}

# used to delete the game home from the file system when it's removed from the panel
sub remove_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_path_del) = decrypt_params(@_);

	if (!-e $home_path_del)
	{
		logger "ERROR - $home_path_del does not exist...nothing to do";
		return 0;
	}

	sleep 1 while ( !pathrmdir("$home_path_del") );

	logger "Deletetion of $home_path_del successful!";
	return 1;
}

sub restart_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_server_without_decrypt(decrypt_params(@_));
}

### Restart the server
## return -2 CANT STOP
## return -1  CANT START (no startup file found that mach the home_id, port and ip)
## return 1 Restart OK
sub restart_server_without_decrypt
{
    my ($home_id, $server_ip, $server_port, $control_protocol,
        $control_password, $control_type, $home_path, $server_exe, $run_dir,
        $cmd, $cpu, $nice, $preStart, $envVars, $game_key, $console_log, $restart_reason) = @_;
	$restart_reason = "panel_restart" unless(defined($restart_reason) && $restart_reason ne "");
	my $correlation_id = new_correlation_id();
	my $restart_started_event = $restart_reason eq "scheduled_restart" ? "scheduled_restart_started" : "automatic_restart_started";
	my $restart_success_event = $restart_reason eq "scheduled_restart" ? "scheduled_restart_succeeded" : "automatic_restart_succeeded";
	my $restart_failed_event = $restart_reason eq "scheduled_restart" ? "scheduled_restart_failed" : "automatic_restart_failed";
	my $report_restart_events = ($restart_reason eq "scheduled_restart" || $restart_reason eq "automatic_restart") ? 1 : 0;
	queue_agent_event($restart_started_event, "info", {
		home_id => $home_id,
		ip => $server_ip,
		game_port => $server_port,
		restart_reason => $restart_reason,
		correlation_id => $correlation_id,
		message => "Restart operation started."
	}) if($report_restart_events);

    if (stop_server_without_decrypt($home_id, $server_ip,
                                    $server_port, $control_protocol,
                                    $control_password, $control_type, $home_path) == 0)
    {
        logger "Waiting 60 seconds before starting the server again.";
        sleep 60;
        if (universal_start_without_decrypt($home_id, $home_path, $server_exe, $run_dir,
                                            $cmd, $server_port, $server_ip, $cpu, $nice, $preStart, $envVars, $game_key, $console_log) == 1)
        {
			queue_agent_event($restart_success_event, "info", {
				home_id => $home_id,
				game_home_path => $home_path,
				ip => $server_ip,
				game_port => $server_port,
				restart_reason => $restart_reason,
				correlation_id => $correlation_id,
				message => "Restart command completed; status polling will confirm process and port readiness."
			}) if($report_restart_events);
            return 1;
        }
        else
        {
			queue_agent_event($restart_failed_event, "error", {
				home_id => $home_id,
				game_home_path => $home_path,
				ip => $server_ip,
				game_port => $server_port,
				restart_reason => $restart_reason,
				correlation_id => $correlation_id,
				message => "Restart failed because the server start path returned an error."
			}) if($report_restart_events);
            return -1;
        }
    }
    else
    {
		queue_agent_event($restart_failed_event, "error", {
			home_id => $home_id,
			ip => $server_ip,
			game_port => $server_port,
			restart_reason => $restart_reason,
			correlation_id => $correlation_id,
			message => "Restart failed because the server could not be stopped."
		}) if($report_restart_events);
        return -2;
    }
}
sub sudo_exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $sudo_exec = &decrypt_param(@_);
	return sudo_exec_without_decrypt($sudo_exec);
}

sub sudo_exec_without_decrypt
{
	my ($command) = @_;
	my @cmdret = `$command`;
	if ($? == 0)
	{
		return "1;".encode_list(@cmdret);
	}
	return 0;
}

sub secure_path
{
	return "1;";
}

sub get_chattr
{
	return "1;";
}

sub ftp_mgr
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $login, $password, $home_path) = decrypt_params(@_);

	# Pure-FTPd virtual users: one password file and one database, both under /etc/ftp (C:\\GSE\\Agent\\etc\\ftp).
	my $pwf = '/etc/ftp/pureftpd.passwd';
	my $pdb = '/etc/ftp/pureftpd.pdb';
	my $uid = `id -u`; chomp $uid;
	my $gid = `id -g`; chomp $gid;
	# Quote a value for the shell (single quotes, with embedded quotes escaped).
	my $q = sub { my $s = defined $_[0] ? $_[0] : ''; $s =~ s/'/'\\''/g; return "'$s'"; };

	my $cmd;
	if ($action eq 'list') { $cmd = "pure-pw list -f $pwf"; }
	elsif ($action eq 'show') { $cmd = "pure-pw show " . $q->($login) . " -f $pwf"; }
	elsif ($action eq 'userdel') { $cmd = "pure-pw userdel " . $q->($login) . " -f $pwf && pure-pw mkdb $pdb -f $pwf"; }
	elsif ($action eq 'useradd') {
		$cmd = "(printf '%s\\n%s\\n' " . $q->($password) . " " . $q->($password) . ") | pure-pw useradd " . $q->($login) . " -f $pwf -u $uid -g $gid -d " . $q->($home_path) . " && pure-pw mkdb $pdb -f $pwf";
	}
	elsif ($action eq 'passwd') {
		$cmd = "(printf '%s\\n%s\\n' " . $q->($password) . " " . $q->($password) . ") | pure-pw passwd " . $q->($login) . " -f $pwf && pure-pw mkdb $pdb -f $pwf";
	}
	elsif ($action eq 'usermod') {
		$cmd = "pure-pw usermod " . $q->($login) . " -f $pwf -d " . $q->($home_path) . " && pure-pw mkdb $pdb -f $pwf";
	}
	else { return "ERROR: unknown FTP action '$action'"; }

	my $out = `$cmd 2>&1`;
	my $rc = $? >> 8;
	return $rc == 0 ? $out : "ERROR: $out";
}

sub start_fastdl
{
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		system('CYGWIN="${CYGWIN} nodosfilewarning"; export CYGWIN; perl FastDownload/ForkedDaemon.pm &');
		sleep(1);
		return 1;
	}
	else
	{
		return -2;
	}
}

sub stop_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_fastdl_without_decrypt();
}

sub stop_fastdl_without_decrypt
{
	my $pid;
	open(PIDFILE, '<', FD_PID_FILE)
	  || logger "Error reading pid file $!",1;
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 9, $pid;
	if ($cnt == 1)
	{
		logger "Fast Download Daemon Stopped.",1;
		return 1;
	}
	else
	{
		logger "Fast Download Daemon with pid $pid can not be stopped.",1;
		return -1;
	}
}

sub take_ownership{
	# Keep the service account able to execute while optionally removing broad inherited home ACLs.
	my ($home_path, $action) = @_;

	my $icaclsStr = "";
	my $icaclsAdminGroupFullPerms = "";
	my $icaclsSystemFullPerms = "";
	my $icaclsRemoveBroadGroups = "";
	my $takeownCommand = "";
	my $chmodCommand = "";
	my $fullCommands = "";
	my $isolate_home_acl = WINDOWS_HOME_ACL_ISOLATION eq "1" ? 1 : 0;

	if (defined $home_path && $home_path ne "" && -e "$home_path"){
		my $windows_home_path = clean(`cygpath -wa $home_path`);

		logger "Running takeown commands on path of $home_path and $windows_home_path";

		#cygwin path handling
		$takeownCommand = 'takeown /U ' . USER_RUNNING_SCRIPT . ' /f "' . $home_path . '" /r >/dev/null 2>&1';
				$chmodCommand = 'icacls "' . ($windows_home_path =~ s{\\}{/}gr) . '" /reset /T /C >/dev/null 2>&1';
		if(defined $action && $action eq "str"){
			$fullCommands .= $takeownCommand . "\n";
			$fullCommands .= $chmodCommand . "\n";
		}else{
			system($takeownCommand);
			system($chmodCommand);
		}

		# Windows path handling
		if(defined $windows_home_path && $windows_home_path ne ""){
			$takeownCommand = 'takeown /U ' . USER_RUNNING_SCRIPT . ' /f "' . $windows_home_path . '" /r >/dev/null 2>&1';
			$chmodCommand = 'icacls "' . ($windows_home_path =~ s{\\}{/}gr) . '" /reset /T /C >/dev/null 2>&1';
			if($isolate_home_acl == 1){
				$icaclsStr = 'icacls "' . $windows_home_path . '" /inheritance:r /grant:r "' . USER_RUNNING_SCRIPT . '":\\(OI\\)\\(CI\\)F /T /C /Q >/dev/null 2>&1';
				$icaclsSystemFullPerms = 'icacls "' . $windows_home_path . '" /grant:r \\*S-1-5-18:\\(OI\\)\\(CI\\)F /T /C /Q >/dev/null 2>&1';
				$icaclsAdminGroupFullPerms = 'icacls "' . $windows_home_path . '" /grant:r \\*S-1-5-32-544:\\(OI\\)\\(CI\\)F /T /C /Q >/dev/null 2>&1';
				$icaclsRemoveBroadGroups = 'icacls "' . $windows_home_path . '" /remove:g \\*S-1-1-0 \\*S-1-5-11 \\*S-1-5-32-545 \\*S-1-5-32-546 /T /C /Q >/dev/null 2>&1';
			}else{
				$icaclsStr = 'icacls "' . $windows_home_path . '" /grant ' . USER_RUNNING_SCRIPT . ':\\(OI\\)\\(CI\\)F /T >/dev/null 2>&1';
				$icaclsAdminGroupFullPerms = 'icacls "' . $windows_home_path . '" /grant administrators:F /T >/dev/null 2>&1';
			}

			if(defined $action && $action eq "str"){
				$fullCommands .= $takeownCommand . "\n";
				$fullCommands .= $chmodCommand . "\n";
				$fullCommands .= $icaclsStr . "\n";
				$fullCommands .= $icaclsSystemFullPerms . "\n" if($icaclsSystemFullPerms ne "");
				$fullCommands .= $icaclsAdminGroupFullPerms . "\n";
				$fullCommands .= $icaclsRemoveBroadGroups . "\n" if($icaclsRemoveBroadGroups ne "");
			}else{
				logger "Running icacls command: $icaclsStr";
				logger "Running icacls SYSTEM command: $icaclsSystemFullPerms" if($icaclsSystemFullPerms ne "");
				logger "Running icacls admin group command: $icaclsAdminGroupFullPerms";
				logger "Running icacls broad group removal command: $icaclsRemoveBroadGroups" if($icaclsRemoveBroadGroups ne "");
				system($takeownCommand);
				system($chmodCommand);
				system($icaclsStr);
				system($icaclsSystemFullPerms) if($icaclsSystemFullPerms ne "");
				system($icaclsAdminGroupFullPerms);
				system($icaclsRemoveBroadGroups) if($icaclsRemoveBroadGroups ne "");
			}
		}
	}

	if($fullCommands ne ""){
		return $fullCommands;
	}

	return 1;
}

sub clean {
    my $text = shift;
    $text =~ s/\n//g;
    $text =~ s/\r//g;
    $text = trim($text);
    return $text;
}

sub trim {
	my $s = shift;
	$s =~ s/^\s+|\s+$//g;
	return $s
};

sub restart_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_fastdl_without_decrypt();
}

sub restart_fastdl_without_decrypt
{
	if((fastdl_status_without_decrypt() == -1) || (stop_fastdl_without_decrypt() == 1))
	{
		if(start_fastdl() == 1)
		{
			# Success
			return 1;
		}
		# Cant start
		return -2;
	}
	# Cant stop
	return -3;
}

sub fastdl_status
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return fastdl_status_without_decrypt();
}

sub fastdl_status_without_decrypt
{
	my $pid;
	if(!open(PIDFILE, '<', FD_PID_FILE))
	{
		logger "Error reading pid file $!";
		return -1;
	}
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 0, $pid;
	if ($cnt == 1)
	{
		return 1;
	}
	else
	{
		return -1;
	}
}

sub fastdl_get_aliases
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my %aliases;
	my $i;
	my @file_lines;
	if(-d FD_ALIASES_DIR)
	{
		if( !opendir(ALIASES, FD_ALIASES_DIR) )
		{
			logger "Error openning aliases directory " . FD_ALIASES_DIR . ", $!";
		}
		else
		{
			while (my $alias = readdir(ALIASES))
			{
				# Skip . and ..
				next if $alias =~ /^\./;
				if( !open(ALIAS, '<', Path::Class::Dir->new(FD_ALIASES_DIR, $alias)) )
				{
					logger "Error reading alias '$alias', $!";
				}
				else
				{
					$i = 0;
					@file_lines = ();
					while (<ALIAS>)
					{
						chomp $_;
						$file_lines[$i] = $_;
						$i++;
					}
					close(ALIAS);
					$aliases{$alias}{home}                  = $file_lines[0];
					$aliases{$alias}{match_file_extension}  = $file_lines[1];
					$aliases{$alias}{match_client_ip}       = $file_lines[2];
				}
			}
			closedir(ALIASES);
		}
	}
	else
	{
		logger "Aliases directory '" . FD_ALIASES_DIR . "' does not exist or is inaccessible.";
	}
	return {%aliases};
}

sub fastdl_del_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	foreach my $alias (decrypt_params(@_))
	{
		unlink Path::Class::File->new(FD_ALIASES_DIR, $alias);
	}
	return restart_fastdl_without_decrypt();
}

sub fastdl_add_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($alias,$home,$match_file_extension,$match_client_ip) = decrypt_params(@_);
	if(!-e FD_ALIASES_DIR)
	{
		if(!mkdir FD_ALIASES_DIR)
		{
			logger "ERROR - Failed to create " . FD_ALIASES_DIR . " directory.";
			return -1;
		}
	}
	my $alias_path = Path::Class::File->new(FD_ALIASES_DIR, $alias);
	if (!open(ALIAS, '>', $alias_path))
	{
		logger "ERROR - Failed to open ".$alias_path." for writing.";
		return -1;
	}
	else
	{
		print ALIAS "$home\n";
		print ALIAS "$match_file_extension\n";
		print ALIAS "$match_client_ip";
		close(ALIAS);
		return restart_fastdl_without_decrypt();
	}
}

sub fastdl_get_info
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		delete $INC{"FastDownload/Settings.pm"};
		require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
		if(not defined $FastDownload::Settings{autostart_on_agent_startup})
		{
			$FastDownload::Settings{autostart_on_agent_startup} = 0;
		}
		return {'port'						=>	$FastDownload::Settings{port},
				'ip'						=>	$FastDownload::Settings{ip},
				'listing'					=>	$FastDownload::Settings{listing},
				'autostart_on_agent_startup'=>	$FastDownload::Settings{autostart_on_agent_startup}};
	}
	return -1
}

sub fastdl_create_config
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(!-e FD_DIR)
	{
		if(!mkdir FD_DIR)
		{
			logger "ERROR - Failed to create " . FD_DIR . " directory.";
			return -1;
		}
	}
	my ($fd_address, $fd_port, $listing, $autostart_on_agent_startup) = decrypt_params(@_);
	my $settings_string = "%FastDownload::Settings = (\n".
						  "\tport  => $fd_port,\n".
						  "\tip => '$fd_address',\n".
						  "\tlisting => $listing,\n".
						  "\tautostart_on_agent_startup => $autostart_on_agent_startup,\n".
						  ");";
	my $settings = Path::Class::File->new(FD_DIR, 'Settings.pm');
	if (!open(SETTINGS, '>', $settings))
	{
		logger "ERROR - Failed to open $settings for writing.";
		return -1;
	}
	else
	{
		print SETTINGS $settings_string;
		close(SETTINGS);
	}
	logger "$settings file written successfully.";
	return 1;
}

sub agent_read_first_line
{
	my ($path) = @_;
	return '' unless(defined($path) && -f $path);
	if(open(my $fh, '<', $path))
	{
		my $line = <$fh>;
		close($fh);
		chomp($line) if defined($line);
		return defined($line) ? $line : '';
	}
	return '';
}

sub agent_version
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $os = `uname -sr 2>/dev/null`;
	chomp($os);
	return component_update_response(success => 1, status => 'ok', agent_version => AGENT_VERSION, protocol_version => AGENT_PROTOCOL_VERSION, os => $os, install_path => AGENT_RUN_DIR);
}

sub agent_win_os_name
{
	my $ver = `cmd /c ver 2>NUL`;
	$ver = '' unless(defined $ver);
	$ver =~ s/[\r\n]+//g;
	return $ver =~ /(Microsoft Windows[^\[]*)/ ? do { my $n = $1; $n =~ s/\s+$//; $n } : 'Windows';
}

sub agent_win_wmic_value
{
	my ($args, $key) = @_;
	my $out = `wmic $args /value 2>NUL`;
	$out = '' unless(defined $out);
	return $out =~ /^\Q$key\E=(\d+)/m ? $1 : undef;
}

sub agent_win_cpu_percent
{
	my $out = `powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average" 2>NUL`;
	$out = '' unless(defined $out);
	return $out =~ /(\d+(?:\.\d+)?)/ ? sprintf('%d', $1) : '';
}

sub agent_win_ram_percent
{
	my $out = `wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /value 2>NUL`;
	$out = '' unless(defined $out);
	my ($free) = $out =~ /FreePhysicalMemory=(\d+)/;
	my ($total) = $out =~ /TotalVisibleMemorySize=(\d+)/;
	return '' unless($free && $total);
	return sprintf('%d', 100 - (100 * $free / $total));
}

sub agent_win_disk_percent
{
	my $out = `wmic logicaldisk where "DeviceID='C:'" get FreeSpace,Size /value 2>NUL`;
	$out = '' unless(defined $out);
	my ($free) = $out =~ /FreeSpace=(\d+)/;
	my ($size) = $out =~ /Size=(\d+)/;
	return '' unless($free && $size);
	return sprintf('%d', 100 - (100 * $free / $size));
}

sub agent_resource_snapshot
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return component_update_response(
		success => 1,
		status => 'ok',
		message => 'Resource snapshot collected.',
		os => agent_win_os_name(),
		agent_version => AGENT_VERSION,
		protocol_version => AGENT_PROTOCOL_VERSION,
		install_path => AGENT_RUN_DIR,
		cpu_percent => agent_win_cpu_percent(),
		ram_percent => agent_win_ram_percent(),
		disk_percent => agent_win_disk_percent(),
		load_average => ''
	);
}

sub agent_update_status
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my %data = (success => 0, status => 'not_started', message => 'No agent update has been recorded.', state_path => AGENT_UPDATE_STATE_FILE, request_path => AGENT_UPDATE_REQUEST_FILE, log_path => AGENT_UPDATE_LOG_FILE);
	if(open(my $fh, '<', AGENT_UPDATE_STATE_FILE))
	{
		local $/;
		my $json = <$fh>;
		close($fh);
		my $decoded = eval { decode_json($json) };
		if(ref($decoded) eq 'HASH')
		{
			%data = (%data, %$decoded);
			$data{success} = ($data{status} && $data{status} eq 'completed') ? 1 : 0;
		}
	}
	return component_update_response(%data);
}

# Downloads a release zip, verifies its SHA-256, then starts the on-demand
# update helper detached. The helper stops this agent, swaps the files,
# starts the agent again, and restores the backup if it does not come back.
sub agent_update_shell_quote
{
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/'\\''/g;
	return "'$value'";
}

sub write_agent_update_state
{
	my (%state) = @_;
	my $state_file = AGENT_UPDATE_STATE_FILE . '';
	my $tmp = $state_file . ".tmp.$$";
	open(my $fh, '>', $tmp) or return 0;
	print $fh encode_json(\%state) . "\n";
	close($fh);
	return rename($tmp, $state_file) ? 1 : 0;
}

sub start_agent_update
{
	my (%cfg) = @_;
	my $component = $cfg{component} || 'windows_agent';
	my $archive_url = $cfg{archive_url} || '';
	my $checksum = lc($cfg{checksum} || '');
	my $version = $cfg{version} || '';
	return component_update_response(success => 0, status => 'invalid_component', message => 'Invalid component.') if($component ne 'linux_agent' && $component ne 'windows_agent');
	return component_update_response(success => 0, status => 'invalid_archive_url', message => 'Provide an https archive_url.') if($archive_url !~ m{^https://} || $archive_url =~ /[\r\n\0\s]/);
	return component_update_response(success => 0, status => 'invalid_checksum', message => 'Invalid SHA-256 checksum.') if($checksum !~ /^[0-9a-f]{64}$/);
	return component_update_response(success => 0, status => 'invalid_version', message => 'Invalid release version.') if($version !~ /^[A-Za-z0-9._\/-]{1,128}$/);

	my $stage_dir = Path::Class::Dir->new(AGENT_RUN_DIR, 'agent_update_stage')->stringify;
	system('rm', '-rf', $stage_dir);
	mkdir($stage_dir) or return component_update_response(success => 0, status => 'write_failed', message => "Cannot create staging folder: $!");
	my $zip = "$stage_dir/release.zip";

	if(system('curl', '-fsSL', '--max-time', '300', '-o', $zip, $archive_url) != 0)
	{
		return component_update_response(success => 0, status => 'download_failed', message => 'Could not download the release archive.');
	}

	my $sha_output = `sha256sum \Q$zip\E 2>/dev/null`;
	my ($actual) = $sha_output =~ /^([0-9a-fA-F]{64})/;
	$actual = lc($actual || '');
	if($actual ne $checksum)
	{
		write_agent_update_state(status => 'failed', message => 'Downloaded release checksum did not match; nothing was changed.', version_target => $version, component => $component, updated_at => scalar gmtime(), rollback_performed => 0);
		return component_update_response(success => 0, status => 'checksum_mismatch', message => 'Downloaded release checksum did not match; nothing was changed.');
	}

	my %state = (
		status => 'running',
		message => 'Release downloaded and verified. The agent is stopping; the update helper will install it and restart the agent.',
		version_target => $version,
		version_before => AGENT_VERSION,
		component => $component,
		rollback_performed => 0,
		updated_at => scalar gmtime(),
	);
	write_agent_update_state(%state);

	my $helper = "$Bin/agent_update_helper.sh";
	my $launcher = "$Bin/agent_launch.sh";
	my $command = join(' ',
		'nohup', 'bash', agent_update_shell_quote($helper),
		'--agent-dir', agent_update_shell_quote(AGENT_RUN_DIR . ''),
		'--zip', agent_update_shell_quote($zip),
		'--sha256', agent_update_shell_quote($checksum),
		'--version', agent_update_shell_quote($version),
		'--agent-pid', $$,
		'--launcher', agent_update_shell_quote($launcher),
		'--state-file', agent_update_shell_quote(AGENT_UPDATE_STATE_FILE . ''),
		'--log-file', agent_update_shell_quote(AGENT_UPDATE_LOG_FILE . ''),
		'>/dev/null 2>&1', '&'
	);
	system($command);
	logger("Agent update to $version started; update helper launched.");
	return component_update_response(%state, success => 1);
}


sub agent_self_update
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($payload) = decrypt_params(@_);
	my %cfg = component_update_parse_payload($payload);
	return start_agent_update(%cfg);
}

# Release-archive update request from the panel (version, archive_url,
# checksum). Same on-demand path as agent_self_update.
sub agent_release_update
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($payload) = decrypt_params(@_);
	my %cfg = component_update_parse_payload($payload);
	return start_agent_update(%cfg);
}

sub component_update_shell_quote
{
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/'"'"'/g;
	return "'" . $value . "'";
}

sub component_update_response
{
	my (%data) = @_;
	my %encoded = ();
	foreach my $key (keys %data)
	{
		$encoded{$key} = encode_base64(defined $data{$key} ? $data{$key} : '', '');
	}
	return \%encoded;
}

sub component_update_parse_payload
{
	my ($payload) = @_;
	my %data = ();
	foreach my $line (split(/\r?\n/, $payload || ''))
	{
		next if $line !~ /^([A-Za-z0-9_]+)=(.*)$/;
		$data{$1} = decode_base64($2);
	}
	return %data;
}

sub component_update
{
	return component_update_response(success => 0, status => 'bad_encryption', message => 'Bad Encryption Key')
		unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($payload) = decrypt_params(@_);
	my %cfg = component_update_parse_payload($payload);
	if (($cfg{metadata_url} || $cfg{patch_url} || '') ne '')
	{
		return start_agent_update(%cfg);
	}
	return component_update_response(
		success => 0,
		status => 'unsupported_update_source',
		message => 'Runtime Git component updates are no longer supported. Queue a manifest-driven release patch with metadata_url or patch_url.'
	);
}

sub agent_restart
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $dec_check = decrypt_param(@_);
	if ($dec_check eq 'restart')
	{
		# Windows agents run as the GSPAgent service. Restart it from a detached
		# helper so this RPC reply is sent before the service stops.
		if ($^O eq 'MSWin32' || $^O eq 'cygwin')
		{
			system('cmd.exe /c start "" /B powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 5; Restart-Service -Name GSPAgent -Force"');
			return 1;
		}
		chdir AGENT_RUN_DIR;
		if(-e "gsp_agent_run.pid")
		{
			my $init_pid	= `cat gsp_agent_run.pid`;
			chomp($init_pid);

			if(kill 0, $init_pid)
			{
				my $or_exist	= "";
				my $rm_pid_file	= "";
				my $agent_pid = "";
				my $restart_scr_log = Path::Class::File->new(SCREEN_LOGS_DIR, 'screenlog.agent_restart');
				my $agent_scr_log = Path::Class::File->new(SCREEN_LOGS_DIR, 'screenlog.gsp_agent');

				if(-e $restart_scr_log)
				{
					unlink $restart_scr_log;
				}

				if(-e $agent_scr_log)
				{
					unlink $agent_scr_log;
				}

				if(-e "gsp_agent.pid")
				{
					$rm_pid_file .= " gsp_agent.pid";
					$agent_pid = `cat gsp_agent.pid`;
					chomp($agent_pid);
					if( kill 0, $agent_pid )
					{
						$or_exist .= " -o -e /proc/$agent_pid";
					}
				}

				my $pureftpd_pid = "";
				if(-e "/var/run/pure-ftpd.pid")
				{
					$rm_pid_file .= " /var/run/pure-ftpd.pid";
					$pureftpd_pid = `cat /var/run/pure-ftpd.pid`;
					chomp($pureftpd_pid);
					if( kill 0, $pureftpd_pid )
					{
						$or_exist .= " -o -e /proc/$pureftpd_pid";
					}
				}

				open (AGENT_RESTART_SCRIPT, '>', 'tmp_restart.sh');
				my $restart = "echo -n \"Stopping GSE Agent...\"\n".
							  "kill $init_pid $agent_pid $pureftpd_pid\n".
							  "while [ -e /proc/$init_pid $or_exist ];do echo -n .;sleep 1;done\n".
							  "rm -f $rm_pid_file\necho \" [OK]\"\n".
							  "echo -n \"Starting GSE Agent...\"\n".
							  "screen -d -m -t \"gsp_agent\" -c \"" . SCREENRC_FILE . "\" -S gsp_agent bash gsp_agent -pidfile /AgentScripts/gsp_agent_run.pid\n".
							  "while [ ! -e 'gsp_agent.pid' ];do echo -n .;sleep 1;done\n".
							  "echo \" [OK]\"\n".
							  "rm -f tmp_restart.sh\n".
							  "exit 0\n";
				print AGENT_RESTART_SCRIPT $restart;
				close (AGENT_RESTART_SCRIPT);
				if( -e 'tmp_restart.sh' )
				{
					system('screen -d -m -t "agent_restart" -c "' . SCREENRC_FILE . '" -S agent_restart bash tmp_restart.sh');
				}
			}
		}
	}
	return -1;
}

# Subroutines to be called
sub scheduler_dispatcher {
	my ($task, $args) = @_;
	my $response = `$args`;
	chomp($response);
	my $log = "Executed command: $args";
	if($response ne "")
	{
		$log .= ", response:\n$response";
	}
	scheduler_log_events($log);
}

sub scheduler_server_action
{
	my ($task, $args) = @_;
	my ($action, @server_args) = split('\|\%\|', $args);
	if($action eq "%ACTION=start")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[6], $server_args[5]);
		my $ret = universal_start_without_decrypt(@server_args);
		if($ret == 1)
		{
			scheduler_log_events("Started server home ID $home_id on address $ip:$port");
		}
		else
		{
			scheduler_log_events("Failed starting server home ID $home_id on address $ip:$port (Check agent log)");
		}
	}
	elsif($action eq "%ACTION=stop")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = stop_server_without_decrypt(@server_args);
		if($ret == 0)
		{
			scheduler_log_events("Stopped server home ID $home_id on address $ip:$port");
		}
		elsif($ret == 1)
		{
			scheduler_log_events("Failed stopping server home ID $home_id on address $ip:$port (Invalid IP:Port given)");
		}
	}
	elsif($action eq "%ACTION=restart")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = restart_server_without_decrypt(@server_args, "scheduled_restart");
		if($ret == 1)
		{
			scheduler_log_events("Restarted server home ID $home_id on address $ip:$port");
		}
		elsif($ret == -1)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be started, check agent log)");
		}
		elsif($ret == -2)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be stopped, check agent log)");
		}
	}
	return 1;
}

sub scheduler_log_events
{
	my $logcmd	 = $_[0];
	$logcmd = localtime() . " $logcmd\n";
	logger "Can't open " . SCHED_LOG_FILE . " - $!" unless open(LOGFILE, '>>', SCHED_LOG_FILE);
	logger "Failed to lock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_EX);
	logger "Failed to seek to end of " . SCHED_LOG_FILE . "." unless seek(LOGFILE, 0, 2);
	logger "Failed to write to " . SCHED_LOG_FILE . "." unless print LOGFILE "$logcmd";
	logger "Failed to unlock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_UN);
	logger "Failed to close " . SCHED_LOG_FILE . "." unless close(LOGFILE);
}

sub scheduler_add_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $new_task = decrypt_param(@_);
	if (open(TASKS, '>>', SCHED_TASKS))
	{
		print TASKS "$new_task\n";
		logger "Created new task: $new_task";
		close(TASKS);
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { }
											   } );
		$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # re-register the game monitor job on every new scheduler object

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot create task: $new_task ( $! )";
	return -1;
}

sub scheduler_del_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $name = decrypt_param(@_);
	my @cronJobIDs = split(',', $name);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next if ( grep { $_ eq $task->{args}[0]} @cronJobIDs );
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if(defined $task->{args}[1])
			{
				print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
			}
			else
			{
				print TASKS $task->{time} . "\n";
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { }
											   } );
		$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # re-register the game monitor job on every new scheduler object

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for deleting task(s) id: $name ( $! )",1;
	return -1;
}

sub scheduler_edit_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($name, $new_task) = decrypt_params(@_);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if($name eq $task->{args}[0])
			{
				print TASKS "$new_task\n";
			}
			else
			{
				if(defined $task->{args}[1])
				{
					print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
				}
				else
				{
					print TASKS $task->{time} . "\n";
				}
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { }
											   } );
		$cron->add_entry( "* * * * * */5", \&gm_monitor_all );   # re-register the game monitor job on every new scheduler object

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for editing task id: $name ( $! )",1;
	return -1;
}

sub scheduler_read_tasks
{
	if( open(TASKS, '<', SCHED_TASKS) )
	{
		$cron->clean_timetable();
	}
	else
	{
		# No tasks file yet means there are no scheduled tasks; that is not an error.
		return 0 if (! -e SCHED_TASKS);
		logger "Error reading tasks file $!";
		scheduler_stop();
		return -1;
	}

	my $i = 0;
	while (<TASKS>)
	{
		next if $_ =~ /^(#.*|[\s|\t]*?\n)/;
		my ($minute, $hour, $dayOfTheMonth, $month, $dayOfTheWeek, @args) = split(' ', $_);
		my $time = "$minute $hour $dayOfTheMonth $month $dayOfTheWeek";
		if("@args" =~ /^\%ACTION.*/)
		{
			$cron->add_entry($time, \&scheduler_server_action, 'task_' . $i++, "@args");
		}
		else
		{
			$cron->add_entry($time, 'task_' . $i++, "@args");
		}
	}
	close(TASKS);
	return 1;
}

sub scheduler_stop
{
	my $pid;
	if(open(PIDFILE, '<', SCHED_PID))
	{
		$pid = <PIDFILE>;
		chomp $pid;
		close(PIDFILE);
		if($pid ne "")
		{
			if( kill 0, $pid )
			{
				my $cnt = kill 9, $pid;
				if ($cnt == 1)
				{
					unlink SCHED_PID;
					return 1;
				}
			}
		}
	}
	return -1;
}

sub scheduler_list_tasks
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	my %entries_array;
	foreach my $task ( @entries ) {
		if( defined $task->{args}[1] )
		{
			$entries_array{$task->{args}[0]} = encode_base64(join(" ", $task->{time}, $task->{args}[1]));
		}
		else
		{
			$entries_array{$task->{args}[0]} = encode_base64($task->{time});
		}
	}
	if( %entries_array )
	{
		return {%entries_array};
	}
	return -1;
}

sub get_file_part
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($file, $offset) = decrypt_params(@_);
	if (!open(FILE, '<', $file))
	{
		logger "ERROR - Can't open file $file for reading.";
		return -1;
	}

	binmode(FILE);

	if($offset != 0)
	{
		return -1 unless seek FILE, $offset, 0;
	}

	my $data = "";
	my ($n, $buf);
	my $limit = $offset + 60 * 57 * 1000; #Max 3420Kb (1000 iterations) (top statistics ~ VIRT 116m, RES 47m)
	while (($n = read FILE, $buf, 60 * 57) != 0 && $offset <= $limit ) {
		$data .= $buf;
		$offset += $n;
	}
	close(FILE);

    if( $data ne "" )
	{
		my $b64zlib = encode_base64(compress($data,9));
		return "$offset;$b64zlib";
	}
	else
	{
		return -1;
	}
}

sub stop_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $home_id = decrypt_param(@_);
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	system('screen -S '.$screen_id.' -p 0 -X stuff $\'\003\'');
	if ($? == 0)
	{
		return 0;
	}
	return 1
}

sub shell_action
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $arguments) = decrypt_params(@_);

	if($action eq 'remove_file')
	{
		chomp($arguments);
		unlink($arguments);
		return "1;";
	}
	elsif($action eq 'remove_recursive')
	{
		my @items = split(';', $arguments);
		foreach my $item ( @items ) {
			chomp($item);
			if(-d $item)
			{
				pathrmdir($item);
			}
			else
			{
				unlink($item);
			}
		}
		return "1;";
	}
	elsif($action eq 'create_dir')
	{
		chomp($arguments);
		mkpath($arguments);
		return "1;";
	}
	elsif($action eq 'move')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dirmove($src, $dest);
		}
		else
		{
			fmove($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'rename')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			dirmove($src, $dest);
		}
		else
		{
			fmove($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'copy')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dircopy($src, $dest);
		}
		else
		{
			fcopy($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'touch')
	{
		chomp($arguments);
		open(FH, '>', $arguments);
		print FH "";
		close(FH);
		return "1;";
	}
	elsif($action eq 'size')
	{
		chomp($arguments);
		my $size = 0;
		if(-d $arguments)
		{
			find(sub { $size += -s }, $arguments ? $arguments : '.');
		}
		else
		{
			$size += (stat($arguments))[7];
		}
		return "1;" . encode_list($size);
	}
	elsif($action eq 'get_cpu_usage')
	{
		my %prev_idle;
		my %prev_total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$prev_idle{$1} = $stat[4];
			$prev_total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		sleep 1;
		my %idle;
		my %total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$idle{$1} = $stat[4];
			$total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		my %cpu_percent_usage;
		foreach my $key ( keys %idle )
		{
			my $diff_idle = $idle{$key} - $prev_idle{$key};
			my $diff_total = $total{$key} - $prev_total{$key};
			my $percent = (100 * ($diff_total - $diff_idle)) / $diff_total;
			$percent = sprintf "%.2f", $percent unless $percent == 0;
			$cpu_percent_usage{$key} = encode_base64($percent);
		}
		return {%cpu_percent_usage};
	}
	elsif($action eq 'get_ram_usage')
	{
		my($total, $buffers, $cached, $free) = qw(0 0 0 0);
		open(STAT, '/proc/meminfo');
		while (<STAT>) {
			$total   += $1 if /MemTotal\:\s+(\d+) kB/;
			$buffers += $1 if /Buffers\:\s+(\d+) kB/;
			$cached  += $1 if /Cached\:\s+(\d+) kB/;
			$free    += $1 if /MemFree\:\s+(\d+) kB/;
		}
		close STAT;
		my $used = $total - $free - $cached - $buffers;
		my $percent = 100 * $used / $total;
		my %mem_usage;
		$mem_usage{'used'}    = encode_base64($used * 1024);
		$mem_usage{'total'}   = encode_base64($total * 1024);
		$mem_usage{'percent'} = encode_base64($percent);
		return {%mem_usage};
	}
	elsif($action eq 'get_disk_usage')
	{
		my($total, $used, $free) = qw(0 0 0);
		if(open(DF, "df -lP 2>/dev/null |"))
		{
			while(my $line = <DF>)
			{
				next unless($line =~ /^.:\s+/);
				my @fields = split(/\s+/, $line);
				next unless(@fields >= 4);
				$total += $fields[1] || 0;
				$used += $fields[2] || 0;
				$free += $fields[3] || 0;
			}
			close DF;
		}
		return {free => encode_base64(0), used => encode_base64(0), total => encode_base64(0), percent => encode_base64(0)} if($total <= 0);
		my $percent = 100 * $used / $total;
		my %disk_usage;
		$disk_usage{'free'}    = encode_base64($free * 1024);
		$disk_usage{'used'}    = encode_base64($used * 1024);
		$disk_usage{'total'}   = encode_base64($total * 1024);
		$disk_usage{'percent'} = encode_base64($percent);
		return {%disk_usage};
	}
	elsif($action eq 'get_uptime')
	{
		open(STAT, '/proc/uptime');
		my $uptime = 0;
		while (<STAT>) {
			$uptime += $1 if /^([0-9]+)/;
		}
		close STAT;
		my %upsince;
		$upsince{'0'} = encode_base64($uptime);
		$upsince{'1'} = encode_base64(time - $uptime);
		return {%upsince};
	}
	elsif($action eq 'get_tasklist')
	{
		my %taskList;
		$taskList{'task'} = encode_base64(`tasklist /fo TABLE`);
		return {%taskList};
	}
	elsif($action eq 'get_timestamp')
	{
		return "1;" . encode_list(time);
	}
	return 0;
}

sub remote_query
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($protocol, $game_type, $ip, $c_port, $q_port, $s_port) = decrypt_params(@_);
	my $PHP_CGI = system('which php-cgi >/dev/null 2>&1');
	if ($PHP_CGI eq 0)
	{
		$PHP_CGI = `which php-cgi`;
		chomp($PHP_CGI);
	}
	else
	{
		return -1;
	}
	my $php_query_dir = Path::Class::Dir->new(AGENT_RUN_DIR, 'php-query');
	if($protocol eq 'lgsl')
	{
		chdir($php_query_dir->subdir('lgsl'));
		my $cmd = $PHP_CGI .
				" -f lgsl_feed.php" .
				" lgsl_type=" . $game_type .
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port .
				" request=sp";
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	elsif($protocol eq 'gameq')
	{
		chdir($php_query_dir->subdir('gameq'));
		my $cmd = $PHP_CGI .
				" -f gameq_feed.php" .
				" game_type=" . $game_type .
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port;
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	return -1;
}

sub send_steam_guard_code
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $sgc) = decrypt_params(@_);
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	system('screen -S '.$screen_id.' -p 0 -X stuff "'.$sgc.'$(printf \\\\r)"');
	if ($? == 0)
	{
		return 0;
	}
	return 1
}

sub steam_workshop
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return steam_workshop_without_decrypt(decrypt_params(@_));
}

#### Run the steam client ####
### @return 1 If installation started
### @return -1 In error case.
sub steam_workshop_without_decrypt
{
	my ($home_id, $mods_full_path,
		$workshop_id, $mods_list,
		$regex, $mods_backreference_index,
		$variable, $place_after, $mod_string,
		$string_separator, $config_file_path,
		$post_install, $mod_names_list,
		$anonymous_login, $user, $pass,
		$download_method, $url_list, $filename_list) = @_;

	# Creates mods path if it doesn't exist
	if ( check_b4_chdir($mods_full_path) != 0)
	{
		return -1;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	my @workshop_mods = split /,/, $mods_list;
	my @installcmds;

	if($download_method eq 'steamcmd')
	{
		if ( check_steam_cmd_client() == -1 )
		{
			logger "SteamCMD is unavailable; cannot run Steam Workshop installation for home ID $home_id.", 1;
			return -1;
		}
		my $steam_binary = STEAMCMD_CLIENT_BIN;
		my $installSteamFile = $screen_id . "_workshop.txt";
		my $installtxt = Path::Class::File->new(STEAMCMD_CLIENT_DIR, $installSteamFile);
		my $windows_mods_path = clean(`cygpath -wa $mods_full_path`);

		open  FILE, '>', $installtxt;
		print FILE "\@ShutdownOnFailedCommand 1\n";
		print FILE "\@NoPromptForPassword 1\n";
		if($anonymous_login eq "0")
		{
			print FILE "login $user $pass\n";
		}
		else
		{
			print FILE "login anonymous\n";
		}
		print FILE "force_install_dir \"$windows_mods_path\"\n";
		foreach my $workshop_mod (@workshop_mods)
		{
			print FILE "workshop_download_item $workshop_id $workshop_mod\n";
		}
		print FILE "exit\n";
		close FILE;
		my $windows_installtxt = clean(`cygpath -wa $installtxt`);
		$windows_installtxt =~ s/\\/\\\\/g;
		@installcmds = ("$steam_binary +runscript $windows_installtxt +exit; rm -f '$installtxt'");
	}

	if($download_method eq 'steamapi')
	{
		my @urls =  split /,/, $url_list;
		my @filenames =  split /,/, $filename_list;
		my $index = 0;
		foreach my $workshop_mod_id (@workshop_mods)
		{
			my $steamcmd_download_path = '/steamapps/workshop/content/'.$workshop_id.'/'.$workshop_mod_id.'/';

			my $workshop_mod_path = $mods_full_path.$steamcmd_download_path;
			if(!-d $workshop_mod_path && !mkpath $workshop_mod_path)
			{
				logger "Folder $workshop_mod_path could not be created.";
				$index++;
				next;
			}
			my $url = $urls[$index];
			my $filename = $filenames[$index];
			my $download_file_path = Path::Class::File->new($workshop_mod_path, "$filename");
			$installcmds[$index] = "wget -O \"$download_file_path\" \"$url\"";
			$index++;
		}
	}

	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log($home_id, $log_file);

	my $precmd = "";
	my $postcmd = "";

	$postcmd .= generate_post_install_scripts($mods_full_path, $workshop_id, $mods_list,
											  $regex, $mods_backreference_index,
											  $variable, $place_after, $mod_string,
											  $string_separator, $config_file_path,
											  $post_install, $mod_names_list, $home_id);

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;

	if ( check_b4_chdir($bash_scripts_path) != 0)
	{
		return -1;
	}

	my $installfile = create_bash_scripts($mods_full_path, $bash_scripts_path, $precmd, $postcmd, @installcmds);

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");

	logger "Installing Steam Workshop content on server Home ID " . $home_id;
	system($screen_cmd);

	return 1;
}

sub	generate_post_install_scripts
{
	my ($mods_full_path, $workshop_id, $mods_list,
		$regex, $mods_backreference_index,
		$variable, $place_after, $mod_string,
		$string_separator, $config_file_path,
		$post_install, $mod_names_list, $home_id) = @_;

	my $post_install_scripts = "";
	my $mods_info_path = Path::Class::Dir->new(AGENT_RUN_DIR, 'WorkshopModsInfo');
	$post_install_scripts .= "mods_full_path=\"$mods_full_path\"\n".
							 "workshop_id=\"$workshop_id\"\n".
							 "home_id=\"$home_id\"\n".
							 "regex=\"$regex\"\n".
							 "mods_backreference_index=\"$mods_backreference_index\"\n".
							 "variable=\"$variable\"\n".
							 "place_after=\"$place_after\"\n".
							 "string_separator=\"$string_separator\"\n".
							 "config_file_path=\"$config_file_path\"\n".
							 "mods_info_path=\"$mods_info_path/\"\n".
							 "mods_info_home_path=\"$mods_info_path/home_$home_id/\"\n".
							 "workshop_status_path=\"$mods_full_path/WorkshopInstallStatus.json\"\n".
							 "write_workshop_status(){ status=\"\$1\"; message=\"\$2\"; now=\"\$(date '+%Y-%m-%d %H:%M:%S')\"; message_json=\$(printf '%s' \"\$message\"|sed 's/\\\\/\\\\\\\\/g;s/\"/\\\\\"/g'); printf '{\"operation\":\"steam_workshop\",\"home_id\":\"%s\",\"workshop_app_id\":\"%s\",\"status\":\"%s\",\"message\":\"%s\",\"updated_at\":\"%s\"}\\n' \"\$home_id\" \"\$workshop_id\" \"\$status\" \"\$message_json\" \"\$now\" > \"\$workshop_status_path\"; }\n".
							 "write_workshop_status running \"Workshop install running\"\n".
							 "trap 'rc=\$?; if [ \$rc -ne 0 ]; then write_workshop_status failed \"Workshop install failed\"; echo GSP_WORKSHOP_INSTALL_FAILED; fi' EXIT\n";
	my @workshop_mods = split /,/, $mods_list;
	my @mod_names = split /,/, $mod_names_list;

	my $index = 0;
	foreach my $workshop_mod_id (@workshop_mods)
	{
		my $steamcmd_download_path = '/steamapps/workshop/content/'.$workshop_id.'/'.$workshop_mod_id.'/';
		my $workshop_mod_path = $mods_full_path.$steamcmd_download_path;
		my $this_mod_string = $mod_string;
		if(!defined $this_mod_string || $this_mod_string eq '')
		{
			$this_mod_string = '%workshop_mod_id%';
		}
		$this_mod_string =~ s/\%workshop_mod_id\%/$workshop_mod_id/g;

		$post_install_scripts .= "mod_string[$index]=\"$this_mod_string\"\n".
								 "mod_name[$index]=\"".$mod_names[$index]."\"\n".
								 "workshop_mod_id[$index]=\"$workshop_mod_id\"\n".
								 "workshop_mod_path[$index]=\"$workshop_mod_path\"\n";
		$index++;
	}

	$post_install_scripts .= 'i=0'."\n".
							 'for mod_id in "${workshop_mod_id[@]}"'."\n".
							 'do'."\n".
							 '	first_file="$(ls "${workshop_mod_path[$i]}"| sort -n | head -1)"'."\n";

	my @post_install_lines = split /[\r\n]+/, $post_install;
	foreach my $line (@post_install_lines) {
		if($line ne ""){
			$line =~ s/\%mods_full_path\%/\$mods_full_path/g;
			$line =~ s/\%workshop_mod_id\%/\$mod_id/g;
			$line =~ s/\%first_file\%/\$first_file/g;
			$post_install_scripts .= "\t".$line."\n";
		}
	}

	$post_install_scripts .= '	first_file_string="\%first_file%"'."\n".
							 '	if [ -z "${mod_string[$i]##*$first_file_string*}" ];then'."\n".
							 '		mod_string[$i]="${mod_string[$i]/$first_file_string/$first_file}"'."\n".
							 '	fi'."\n";

	if(defined $config_file_path && $config_file_path ne '')
	{
		$post_install_scripts .= '	if [ ! -e "$config_file_path" ];then'."\n".
								 '		if [ ! -d "$(dirname "$config_file_path")" ];then mkdir -p "$(dirname "$config_file_path")";fi'."\n".
								 '		echo -e "${place_after}\n${variable}" > "$config_file_path"'."\n".
								 '	fi'."\n".
								 '	file_content=$(cat "$config_file_path")'."\n".
								 '	if [[ $file_content =~ $regex ]]; then'."\n".
								 '		full_match="${BASH_REMATCH[0]}"'."\n".
								 '		mods_match="${BASH_REMATCH[$mods_backreference_index]}"'."\n".
								 '		found=1'."\n".
								 '	else'."\n".
								 '		found=0'."\n".
								 '	fi'."\n".
								 '	if [ $found == 1 ] && [ "X$full_match" != "X" ];then'."\n".
								 '		if [ "X$mods_match" == "X" ];then'."\n".
								 '			new_mods=$(echo -e "${full_match}${mod_string[$i]}")'."\n".
								 '			echo -e "${file_content/$full_match/$new_mods}">"$config_file_path"'."\n".
								 '		else'."\n".
								 '			if [ ! -z "${mods_match##*${mod_string[$i]}*}" ];then'."\n".
								 '				new_mods=$(echo -e "${full_match}${string_separator}${mod_string[$i]}")'."\n".
								 '				echo -e "${file_content/$full_match/$new_mods}">"$config_file_path"'."\n".
								 '			fi'."\n".
								 '		fi'."\n".
								 '	else'."\n".
								 '		if [ "X$place_after" == "X" ];then'."\n".
								 '			echo -e "${file_content}${variable}${mod_string[$i]}">"$config_file_path"'."\n".
								 '		else'."\n".
								 '			if [ -z "${file_content##*${place_after}*}" ];then'."\n".
								 '				new_var="${variable}${mod_string[$i]}"'."\n".
								 '				place_after_esc=$(echo -e "$place_after"|sed -e \'s/[]\\/$*.^[]/\\\\&/g\')'."\n".
								 '				echo -e "$file_content"|sed \'/\'$place_after_esc\'/a \'$new_var>"$config_file_path"'."\n".
								 '			else'."\n".
								 '				echo -e "${file_content}${place_after}\n${variable}${mod_string[$i]}">"$config_file_path"'."\n".
								 '			fi'."\n".
								 '		fi'."\n".
								 '	fi'."\n";
	}

	$post_install_scripts .=
							 '	if [ ! -d "${mods_info_path}" ];then mkdir -p "${mods_info_path}";fi'."\n".
							 '	if [ ! -d "${mods_info_home_path}" ];then mkdir -p "${mods_info_home_path}";fi'."\n".
							 '	installed_path=""'."\n".
							 '	if [ -e "$mods_full_path/${mod_string[$i]}" ];then installed_path="$mods_full_path/${mod_string[$i]}";fi'."\n".
							 '	if [ -z "$installed_path" ] && [ -e "$mods_full_path/@$mod_id" ];then installed_path="$mods_full_path/@$mod_id";fi'."\n".
							 '	if [ -z "$installed_path" ] && [ -e "$mods_full_path/$mod_id" ];then installed_path="$mods_full_path/$mod_id";fi'."\n".
							 '	installed_folder="$(basename "$installed_path")"'."\n".
							 "	install_time=\"\$(date '+%Y-%m-%d %H:%M:%S')\"\n".
							 '	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "${mod_string[$i]}" "$mod_id" "${mod_name[$i]}" "$installed_folder" "$installed_path" "$workshop_id" "installed" "$install_time" "$install_time" > "${mods_info_home_path}${mod_id}.gspmod"'."\n".
							 '	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "${mod_string[$i]}" "$mod_id" "${mod_name[$i]}" "$installed_folder" "$installed_path" "$workshop_id" "installed" "$install_time" "$install_time" > "${mods_info_path}${mod_string[$i]}.gspmod"'."\n".
							 '	i=$(expr $i + 1)'."\n".
							 'done'."\n".
							 'write_workshop_status completed "Workshop install completed"'."\n".
							 'trap - EXIT'."\n".
							 'echo GSP_WORKSHOP_INSTALL_COMPLETE'."\n";
	return "$post_install_scripts";
}

sub get_workshop_mods_info()
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");

	my ($home_id) = decrypt_params(@_);
	my $mods_info_dir_path = Path::Class::Dir->new(AGENT_RUN_DIR, 'WorkshopModsInfo');
	if(defined $home_id && $home_id =~ /^\d+$/)
	{
		my $home_mods_info_dir_path = Path::Class::Dir->new($mods_info_dir_path, "home_$home_id");
		$mods_info_dir_path = $home_mods_info_dir_path if(-d $home_mods_info_dir_path);
	}

	if(-d $mods_info_dir_path)
	{
		opendir(MODS_INFO_DIR, $mods_info_dir_path) or return -1;
		my @mods_info;
		while(my $mod_info_file = readdir(MODS_INFO_DIR))
		{
			if($mod_info_file =~ /\.gspmod$/)
			{
				my $mod_info_file_path = Path::Class::File->new($mods_info_dir_path, $mod_info_file);
				if(open(my $fh, '<:encoding(UTF-8)', $mod_info_file_path))
				{
					my $row = <$fh>;
					chomp $row;
					if($row ne "")
					{
						my ($string_name, $ext) = split(/\.gsp/, $mod_info_file);
						if(index($row, "\t") >= 0)
						{
							push @mods_info, $row;
						}
						else
						{
							push @mods_info, "$string_name:$row";
						}
					}
					close($fh);
				}
			}
		}
		closedir(MODS_INFO_DIR);
		return "1;".encode_list(@mods_info);
	}

	return -1;
}

sub get_setting_using_api
{
	my ($setting_name) = @_;

	if(defined WEB_API_URL && WEB_API_URL ne "" && defined WEB_ADMIN_API_KEY && WEB_ADMIN_API_KEY ne ""){
		my $url = WEB_API_URL . "?setting/get&setting_name=" . $setting_name . "&token=" . WEB_ADMIN_API_KEY;
		my $ua = LWP::UserAgent->new;
		$ua->agent('Mozilla/5.0');
		$ua->timeout(5);
		$ua->ssl_opts( verify_hostname => 0 ,SSL_verify_mode => 0x00);
		my $response = $ua->get($url);
		return $response->decoded_content();
	}

	return -1;
}

sub is_integer {
   defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

sub get_minecraft_rcon_port{
	my ($home_dir) = @_;
	my $port = -1;
	my $findStr = "rcon.port=";
	my $file = Path::Class::File->new($home_dir, "server.properties");

	open(FH, '<', $file) or return -1;

	while(<FH>){
		if (begins_with($_,$findStr)){
			$port = int(substr($_, length($findStr)));
			last;
		}
	}

	close(FH);

	return $port;
}

sub begins_with
{
    return substr($_[0], 0, length($_[1])) eq $_[1];
}

# ---- Watchdog integration (WATCHDOG_MODE) -------------------------------------------
# Converts a Windows path (C:\...) to a Cygwin path (/cygdrive/c/...). Other paths pass through.
sub wd_cygpath_without_decrypt
{
	my ($p) = @_;
	return $p unless(defined $p);
	if($p =~ /^([A-Za-z]):[\\\/](.*)$/)
	{
		my ($d, $rest) = (lc($1), $2);
		$rest =~ s/\\/\//g;
		return "/cygdrive/$d/$rest";
	}
	$p =~ s/\\/\//g;
	return $p;
}

# Single-quotes a value for bash.
sub wd_shell_quote_without_decrypt
{
	my ($v) = @_;
	$v = "" unless(defined $v);
	$v =~ s/'/'\\''/g;
	return "'$v'";
}

# Start a home through its watchdog. The watchdog launches the game and owns status from here.
sub watchdog_start_without_decrypt
{
	my ($home_id, $mgmt, $run_dir, $startup_cmd, $port, $ip, $game_key) = @_;
	my $script = WATCHDOG_DIR->file('gse_watchdog.sh')->stringify;
	if(!-e $script)
	{
		logger "Watchdog start refused for HOME ID:$home_id: watchdog script missing at $script.";
		return -15;
	}
	if(!defined $startup_cmd || $startup_cmd eq "")
	{
		logger "Watchdog start refused for HOME ID:$home_id: start command is empty.";
		return -14;
	}
	my $mgmt_path = defined $mgmt && $mgmt ne "" ? $mgmt : WD_HOMES_DIR->subdir($home_id)->stringify;
	mkdir $mgmt_path unless(-d $mgmt_path);
	# An explicit start from the panel is an operator action: clear the crash history from the previous run.
	unlink(File::Spec->catfile($mgmt_path, "status.env"));
	# The start line goes into start.cmd in the home folder, so no quoting is needed on the way to cmd.exe.
	my $cmd_file = File::Spec->catfile($mgmt_path, "serverStart.bat");
	if (defined($startup_cmd) && $startup_cmd ne "") {
	open(my $cf, '>', File::Spec->catfile($mgmt_path, "start.cmd")) or do { logger "Watchdog start refused for HOME ID:$home_id: cannot write start.cmd ($!)."; return -14; };
	print $cf "\@echo off\r\n" . $startup_cmd . "\r\n";
	close($cf);
	$cmd_file = File::Spec->catfile($mgmt_path, "start.cmd");
	}
	my $cmd = "/cygdrive/c/Windows/System32/cmd.exe /C " . wd_shell_quote_without_decrypt($cmd_file);
	open(my $fh, '>', File::Spec->catfile($mgmt_path, 'launch.env')) or do { logger "Watchdog start refused for HOME ID:$home_id: cannot write launch.env in $mgmt_path ($!)."; return -14; };
	# run_dir is relative to the home folder (game_key/exe_location); the watchdog needs the full path.
	my $abs_run = ($run_dir =~ m{^([A-Za-z]:|/)}) ? $run_dir : File::Spec->catdir($mgmt_path, $run_dir);
	print $fh "GAME_DIR=" . wd_shell_quote_without_decrypt(wd_cygpath_without_decrypt($abs_run)) . "\n";
	print $fh "GAME_CMD=" . wd_shell_quote_without_decrypt($cmd) . "\n";
	print $fh "GAME_PORT=" . wd_shell_quote_without_decrypt($port) . "\n";
	print $fh "GAME_PROTO=tcp\n";
	close($fh);
	open(my $rq, '>', File::Spec->catfile($mgmt_path, 'request')) or return -14;
	print $rq "RUNNING\n";
	close($rq);
	# Record the desired state where the restore step reads it, then run the restore once for this home.
	my $startups = GAME_STARTUP_DIR->stringify;
	if(open(my $sf, '>', File::Spec->catfile($startups, "status-$home_id")))
	{
		print $sf time() . ",STARTING\n";
		close($sf);
	}
	my $bash_exe = 'bash';
	for my $cand (WD_ROOT_DIR->file('bin', 'bash.exe')->stringify, '/bin/bash.exe', 'C:/GSE/Agent/bin/bash.exe')
	{
		if(-e $cand) { $bash_exe = $cand; last; }
	}
	# The restore script calls setsid and bash by name, so the install's Cygwin folders must be on PATH for this call.
	local $ENV{PATH} = join(';', WD_ROOT_DIR->subdir('bin')->stringify, WD_ROOT_DIR->subdir('usr', 'bin')->stringify, $ENV{PATH} || '');
	my $rc = system($bash_exe, wd_cygpath_without_decrypt(WATCHDOG_DIR->file('gse_restore.sh')->stringify),
		wd_cygpath_without_decrypt($startups), wd_cygpath_without_decrypt(WD_HOMES_DIR->stringify),
		wd_cygpath_without_decrypt(WATCHDOG_DIR->stringify));
	logger "Watchdog start requested for HOME ID:$home_id (restore rc=$rc).";
	return 1;
}

# Reads <home>/status.env written by the watchdog and maps it onto the status fields the panel uses.
sub apply_watchdog_status_without_decrypt
{
	my ($info, $home_id) = @_;
	my $file = File::Spec->catfile(WD_HOMES_DIR->subdir($home_id)->stringify, 'status.env');
	return 0 unless(-e $file && open(my $fh, '<', $file));
	my %e;
	while(my $line = <$fh>) { chomp $line; my ($k, $v) = split(/=/, $line, 2); $e{$k} = $v if defined $k; }
	close($fh);
	my %map = (RUNNING => 'ONLINE', STARTING => 'STARTING', STOPPING => 'STOPPING', STOPPED => 'OFFLINE',
		CRASHED => 'CRASHED', CRASHED_LIMIT => 'CRASHED_LIMIT', ERROR => 'ERROR');
	my $state = $e{state} || 'UNKNOWN';
	$info->{status} = $map{$state} || $state;
	$info->{status_state} = $state;
	$info->{process_running} = $e{alive} ? 1 : 0;
	$info->{game_port_listening} = $e{port_open} ? 1 : 0;
	$info->{pid} = $e{pid} || '';
	$info->{last_error} = ($state eq 'ERROR' || $state eq 'CRASHED_LIMIT') ? ($e{reason} || $state) : '';
	return 1;
}
