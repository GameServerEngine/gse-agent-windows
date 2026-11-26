package GSE::Container::Result;

use strict;
use warnings;
use JSON::PP;

# Builds the common structured response shape for container lifecycle calls.
sub success
{
	my ($class, %args) = @_;
	return {
		contract => GSE::Container::Models::CONTRACT_VERSION(),
		success => JSON::PP::true(),
		status => $args{status} || "completed",
		state => $args{state} || "unknown",
		message => $args{message} || "",
		target => $args{target} || {},
		result => $args{result} || {},
		error => undef,
		warnings => $args{warnings} || []
	};
}

# Builds a structured failure response without exposing shell command strings.
sub failure
{
	my ($class, %args) = @_;
	return {
		contract => GSE::Container::Models::CONTRACT_VERSION(),
		success => JSON::PP::false(),
		status => $args{status} || "failed",
		state => $args{state} || "error",
		message => $args{message} || "",
		target => $args{target} || {},
		result => $args{result} || {},
		error => {
			code => $args{code} || "internal_error",
			category => $args{category} || "internal",
			message => $args{message} || "Container operation failed.",
			retryable => $args{retryable} ? JSON::PP::true() : JSON::PP::false(),
			details => $args{details} || {}
		},
		warnings => $args{warnings} || []
	};
}

package GSE::Container::Models;

use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Spec;
use JSON::PP;
use Digest::SHA qw(sha256_hex);

use constant CONTRACT_VERSION => "gse.container.v1";
use constant DEFAULT_DATA_ROOT => "containers";
use constant DEFAULT_STOP_TIMEOUT_SECONDS => 30;
use constant DEFAULT_COMMAND_TIMEOUT_SECONDS => 60;
use constant DEFAULT_PULL_TIMEOUT_SECONDS => 900;
use constant DEFAULT_PIDS_LIMIT => 512;
use constant MAX_PIDS_LIMIT => 8192;
use constant DEFAULT_NETWORK => "gse-games";
use constant DEFAULT_LOG_MAX_SIZE => "10m";
use constant DEFAULT_LOG_MAX_FILE => "3";
use constant DEFAULT_TMPFS => "/tmp:rw,nosuid,nodev,size=512m";
use constant PLATFORM => ($^O eq "cygwin" || $^O eq "MSWin32") ? "windows" : "linux";

# Host paths a container may never mount, whatever the caller says.
use constant FORBIDDEN_MOUNT_ROOTS => qw(
	/ /bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /opt /proc /root /run /sbin /srv /sys /usr /var
	/var/run /var/lib/docker /home /tmp
);
use constant FORBIDDEN_MOUNT_PREFIXES => qw(
	/bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /root /run /sbin /sys /usr /var/run /var/lib/docker
);

# Creates a validator/model helper with an agent-owned data root.
sub new
{
	my ($class, %args) = @_;
	my $data_root = defined($args{data_root}) && $args{data_root} ne "" ? $args{data_root} : DEFAULT_DATA_ROOT;
	return bless({
		data_root => _absolute_path($data_root)
	}, $class);
}

# Returns the absolute agent-owned root under which legacy host volume paths must stay.
sub data_root
{
	my ($self) = @_;
	return $self->{data_root};
}

# Generates the stable platform-owned container name for a Panel target.
sub container_name
{
	my ($class, $target) = @_;
	my ($ok, $message) = _validate_positive_int($target->{home_id}, "home_id");
	return undef unless($ok);
	($ok, $message) = _validate_positive_int($target->{allocation_id}, "allocation_id");
	return undef unless($ok);
	return "gse-h" . $target->{home_id} . "-a" . $target->{allocation_id};
}

# Builds deterministic platform labels used for ownership checks.
sub labels_for_target
{
	my ($class, $target) = @_;
	return {
		"gse.agent" => PLATFORM,
		"gse.allocation_id" => "" . $target->{allocation_id},
		"gse.contract_version" => CONTRACT_VERSION,
		"gse.home_id" => "" . $target->{home_id},
		"gse.managed" => "true",
		"gse.owner_user_id" => "" . $target->{owner_user_id},
		"gse.server_id" => "" . $target->{server_id}
	};
}

# Validates and normalizes a create request into deterministic command inputs.
# $context comes from the agent itself (never from the Panel JSON): the game folder the agent
# resolved and checked, the Linux user to run as, the console control folder, the launch
# command, the network and the approved image prefixes.
sub validate_create_request
{
	my ($self, $request, $context) = @_;
	$context = {} unless(ref($context) eq "HASH");
	return (undef, _validation_error("invalid_contract", "request must be a hash")) unless(ref($request) eq "HASH");
	my ($target, $target_error) = $self->validate_target($request->{target});
	return (undef, $target_error) unless($target);
	return (undef, _validation_error("invalid_contract", "contract must be " . CONTRACT_VERSION))
		unless(defined($request->{contract}) && $request->{contract} eq CONTRACT_VERSION);
	my $payload = $request->{payload};
	return (undef, _validation_error("invalid_contract", "payload must be a hash")) unless(ref($payload) eq "HASH");

	my ($image, $image_error) = _validate_image($payload->{image}, $context->{allowed_image_prefixes});
	return (undef, $image_error) unless($image);
	my ($resources, $resource_error) = _validate_resources($payload->{resources});
	return (undef, $resource_error) unless($resources);
	my ($ports, $port_error) = _validate_ports($payload->{ports});
	return (undef, $port_error) unless($ports);

	my ($volumes, $volume_error);
	if(ref($context->{mounts}) eq "ARRAY")
	{
		# Game mode: only the mounts the agent resolved itself; Panel storage is ignored.
		($volumes, $volume_error) = $self->_validate_agent_mounts($context->{mounts}, $context->{forbidden_roots});
	}
	else
	{
		($volumes, $volume_error) = $self->_validate_volumes($payload->{storage});
	}
	return (undef, $volume_error) unless($volumes);

	my ($environment, $environment_error) = _validate_environment($payload->{environment});
	return (undef, $environment_error) unless($environment);
	if(ref($context->{environment}) eq "HASH")
	{
		my ($agent_env, $agent_env_error) = _validate_environment($context->{environment});
		return (undef, $agent_env_error) unless($agent_env);
		$environment = { %$environment, %$agent_env };
	}

	my ($command, $command_error) = _validate_optional_argv(
		exists($context->{command}) ? $context->{command} : $payload->{command}, "command");
	return (undef, $command_error) unless(defined($command));
	my ($entrypoint, $entrypoint_error) = _validate_optional_entrypoint(
		exists($context->{entrypoint}) ? $context->{entrypoint} : $payload->{entrypoint});
	return (undef, $entrypoint_error) unless(defined($entrypoint));
	my ($restart_policy, $restart_error) = _validate_restart_policy($payload->{restart_policy});
	return (undef, $restart_error) unless($restart_policy);

	my ($run_as, $run_as_error) = _validate_run_as($context->{run_as});
	return (undef, $run_as_error) unless(defined($run_as));
	my $workdir = defined($context->{workdir}) ? $context->{workdir} : "";
	return (undef, _validation_error("invalid_contract", "workdir must be an absolute container path"))
		if($workdir ne "" && !_container_path_ok($workdir));
	my $network = defined($context->{network}) && $context->{network} ne "" ? $context->{network} : DEFAULT_NETWORK;
	return (undef, _validation_error("invalid_contract", "network name contains invalid characters"))
		unless($network =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/);
	my $stop_timeout = _bounded_int($payload->{stop_timeout_seconds}, DEFAULT_STOP_TIMEOUT_SECONDS, 1, 300);

	my $container_name = __PACKAGE__->container_name($target);
	my $spec = {
		contract => CONTRACT_VERSION,
		target => $target,
		container_name => $container_name,
		image => $image,
		resources => $resources,
		ports => $ports,
		volumes => $volumes,
		environment => $environment,
		command => $command,
		entrypoint => $entrypoint,
		restart_policy => $restart_policy,
		run_as => $run_as,
		workdir => $workdir,
		network => $network,
		read_only_rootfs => exists($context->{read_only_rootfs}) ? ($context->{read_only_rootfs} ? 1 : 0) : 1,
		stop_timeout_seconds => $stop_timeout
	};
	my $labels = __PACKAGE__->labels_for_target($target);
	$labels->{"gse.config_hash"} = __PACKAGE__->config_hash($spec);
	$spec->{labels} = $labels;
	return ($spec, undef);
}

# Hash of everything that is fixed when the container is created. A different hash means
# the container must be recreated (the launch script is mounted, so startup changes are not in it).
sub config_hash
{
	my ($class, $spec) = @_;
	my %copy = map { $_ => $spec->{$_} } grep { $_ ne "labels" && $_ ne "environment" } keys %$spec;
	# Environment values may be secrets: hash them rather than include them.
	$copy{environment_hash} = sha256_hex(JSON::PP->new->canonical->encode($spec->{environment} || {}));
	return substr(sha256_hex(JSON::PP->new->canonical->encode(\%copy)), 0, 32);
}

# Validates the target identity used by inspect/start/stop/restart/delete.
sub validate_target
{
	my ($self, $target) = @_;
	return (undef, _validation_error("invalid_contract", "target must be a hash")) unless(ref($target) eq "HASH");
	foreach my $field (qw(server_id home_id allocation_id owner_user_id))
	{
		my ($ok, $message) = _validate_positive_int($target->{$field}, $field);
		return (undef, _validation_error("invalid_contract", $message)) unless($ok);
	}
	my %normalized = map { $_ => 0 + $target->{$_} } qw(server_id home_id allocation_id owner_user_id);
	$normalized{container_name} = __PACKAGE__->container_name(\%normalized);
	return (\%normalized, undef);
}

# Confirms runtime labels match the platform-owned target. gse.agent is checked loosely:
# agents before this change wrote "windows" on Linux too.
sub verify_ownership
{
	my ($class, $target, $labels) = @_;
	return (0, "ownership labels are missing") unless(ref($labels) eq "HASH");
	my $expected = $class->labels_for_target($target);
	foreach my $key (sort keys %$expected)
	{
		if($key eq "gse.agent")
		{
			return (0, "container ownership label gse.agent does not match")
				unless(defined($labels->{$key}) && $labels->{$key} =~ /\A(?:linux|windows)\z/);
			next;
		}
		return (0, "container ownership label $key does not match")
			unless(defined($labels->{$key}) && $labels->{$key} eq $expected->{$key});
	}
	return (1, "");
}

# Maps Docker state fields into the container contract lifecycle state.
sub state_from_inspect
{
	my ($class, $inspect) = @_;
	return "unknown" unless(ref($inspect) eq "HASH");
	my $state = ref($inspect->{State}) eq "HASH" ? $inspect->{State} : {};
	return "running" if($state->{Running} && !$state->{Restarting});
	return "restarting" if($state->{Restarting});
	return "oom" if($state->{OOMKilled} && defined($state->{Status}) && $state->{Status} =~ /^(exited|dead)$/);
	return "stopped" if(defined($state->{Status}) && $state->{Status} =~ /^(exited|dead)$/);
	return "created" if(defined($state->{Status}) && $state->{Status} eq "created");
	return "unknown";
}

# Normalizes a filesystem path without requiring the leaf directory to exist.
sub _absolute_path
{
	my ($path) = @_;
	return File::Spec->rel2abs($path, getcwd()) unless(defined($path) && File::Spec->file_name_is_absolute($path));
	return File::Spec->rel2abs($path);
}

# Resolves symlinks; returns undef when the path does not exist.
sub _real_path
{
	my ($path) = @_;
	return undef unless(defined($path) && $path ne "" && -e $path);
	my $real = abs_path($path);
	return undef unless(defined($real) && $real ne "");
	$real =~ s{[\\/]+\z}{} unless($real eq "/");
	return $real;
}

# Returns true when the child path is contained by the root, comparing real (symlink-free) paths.
sub _path_is_inside
{
	my ($root, $child) = @_;
	my $root_abs = _real_path($root);
	my $child_abs = _real_path($child);
	return 0 unless(defined($root_abs) && defined($child_abs));
	return $child_abs eq $root_abs || index($child_abs . "/", $root_abs . "/") == 0;
}

# A bind source must exist, be a directory, contain no symlinks and avoid system folders.
sub _bind_source_error
{
	my ($host_path, $extra_forbidden) = @_;
	return "host_path is required" unless(defined($host_path) && $host_path ne "");
	return "host_path must not contain control characters or commas" if($host_path =~ /[\x00-\x1f\x7f,]/);
	return "host_path must be absolute" unless(File::Spec->file_name_is_absolute($host_path));
	my $clean = $host_path;
	$clean =~ s{[\\/]+\z}{};
	$clean = "/" if($clean eq "");
	return "host_path must exist as a directory" unless(-d $clean);
	my $real = _real_path($clean);
	return "host_path cannot be resolved" unless(defined($real));
	return "host_path must not contain symlinks" unless($real eq $clean);
	my $real_lc = PLATFORM eq "windows" ? lc($real) : $real;
	foreach my $root (FORBIDDEN_MOUNT_ROOTS)
	{
		return "host_path is a protected system folder" if($real_lc eq $root);
	}
	foreach my $prefix (FORBIDDEN_MOUNT_PREFIXES)
	{
		return "host_path is inside a protected system folder" if(index($real_lc . "/", $prefix . "/") == 0);
	}
	return "host_path points at the Docker socket" if($real_lc =~ m{docker\.sock|docker_engine}i);
	foreach my $forbidden (@{ref($extra_forbidden) eq "ARRAY" ? $extra_forbidden : []})
	{
		my $forbidden_real = _real_path($forbidden);
		next unless(defined($forbidden_real));
		return "host_path overlaps a protected agent folder"
			if(index($real . "/", $forbidden_real . "/") == 0 || index($forbidden_real . "/", $real . "/") == 0);
	}
	return "";
}

sub _container_path_ok
{
	my ($container_path) = @_;
	return defined($container_path) && $container_path =~ m{\A/[A-Za-z0-9._/-]+\z} && $container_path !~ m{/\.\.?(/|\z)} ? 1 : 0;
}

# Builds a validation error tuple suitable for structured responses.
sub _validation_error
{
	my ($code, $message) = @_;
	my %category_for = (
		invalid_contract => "validation",
		invalid_image => "validation",
		invalid_resource_limit => "validation",
		invalid_port_block => "validation",
		invalid_volume_path => "validation",
		invalid_environment => "validation"
	);
	return {
		code => $code,
		category => $category_for{$code} || "validation",
		message => $message,
		retryable => 0
	};
}

# Validates IDs that are used in names, labels, and lock scopes.
sub _validate_positive_int
{
	my ($value, $field) = @_;
	return (0, "$field is required") unless(defined($value) && $value ne "");
	return (0, "$field must be a positive integer") unless($value =~ /^\d+\z/ && $value > 0);
	return (1, "");
}

sub _bounded_int
{
	my ($value, $default, $min, $max) = @_;
	return $default unless(defined($value) && $value =~ /^\d+\z/);
	return $min if($value < $min);
	return $max if($value > $max);
	return 0 + $value;
}

# Validates the image reference against the approved prefixes and pins it by digest when given.
sub _validate_image
{
	my ($image, $allowed_prefixes) = @_;
	return (undef, _validation_error("invalid_image", "image must be a hash")) unless(ref($image) eq "HASH");
	my $reference = $image->{reference};
	return (undef, _validation_error("invalid_image", "image reference is required")) unless(defined($reference) && $reference ne "");
	return (undef, _validation_error("invalid_image", "image reference contains invalid characters"))
		unless($reference =~ /\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,254}\z/);
	return (undef, _validation_error("invalid_image", "image reference contains traversal or empty path segments"))
		if($reference =~ m{(^|/)\.\.?(/|\z)} || $reference =~ m{//});
	if(ref($allowed_prefixes) eq "ARRAY" && @$allowed_prefixes)
	{
		my $approved = 0;
		foreach my $prefix (@$allowed_prefixes)
		{
			next unless(defined($prefix) && $prefix ne "");
			if($reference eq $prefix || index($reference, $prefix) == 0)
			{
				$approved = 1;
				last;
			}
		}
		return (undef, _validation_error("invalid_image", "image is not on this agent's approved list")) unless($approved);
	}
	my $pull_policy = $image->{pull_policy} || "if_missing";
	return (undef, _validation_error("invalid_image", "unsupported image pull policy"))
		unless($pull_policy =~ /\A(?:if_missing|always|never)\z/);
	my $digest = defined($image->{digest}) ? $image->{digest} : "";
	if($digest ne "")
	{
		return (undef, _validation_error("invalid_image", "image digest must be sha256 hex"))
			unless($digest =~ /\Asha256:[a-fA-F0-9]{64}\z/);
	}
	my $base = $reference;
	$base =~ s/\@sha256:[a-fA-F0-9]{64}\z//;
	my $resolved = $digest ne "" ? "$base\@$digest" : $reference;
	return ({
		reference => $reference,
		pull_policy => $pull_policy,
		digest => $digest,
		resolved => $resolved
	}, undef);
}

# Validates CPU, memory, swap, process and declared storage limits.
sub _validate_resources
{
	my ($resources) = @_;
	return (undef, _validation_error("invalid_resource_limit", "resources must be a hash")) unless(ref($resources) eq "HASH");
	my $cpu_cores = $resources->{cpu_cores};
	return (undef, _validation_error("invalid_resource_limit", "cpu_cores must be between 0.1 and 128"))
		unless(defined($cpu_cores) && $cpu_cores =~ /^\d+(?:\.\d+)?\z/ && $cpu_cores >= 0.1 && $cpu_cores <= 128);
	my $memory_mb = $resources->{memory_mb};
	return (undef, _validation_error("invalid_resource_limit", "memory_mb must be between 128 and 1048576"))
		unless(defined($memory_mb) && $memory_mb =~ /^\d+\z/ && $memory_mb >= 128 && $memory_mb <= 1048576);
	# --memory-swap is RAM plus swap combined. Unset means no swap at all (equal to memory).
	my $memory_burst_mb = $resources->{memory_burst_mb};
	if(defined($memory_burst_mb) && $memory_burst_mb ne "")
	{
		return (undef, _validation_error("invalid_resource_limit", "memory_burst_mb (RAM plus swap) must be at least memory_mb"))
			unless($memory_burst_mb =~ /^\d+\z/ && $memory_burst_mb >= $memory_mb && $memory_burst_mb <= 2097152);
	}
	else
	{
		$memory_burst_mb = $memory_mb;
	}
	my $pids_limit = $resources->{pids_limit};
	if(defined($pids_limit) && $pids_limit ne "")
	{
		return (undef, _validation_error("invalid_resource_limit", "pids_limit must be between 32 and " . MAX_PIDS_LIMIT))
			unless($pids_limit =~ /^\d+\z/ && $pids_limit >= 32 && $pids_limit <= MAX_PIDS_LIMIT);
	}
	else
	{
		$pids_limit = DEFAULT_PIDS_LIMIT;
	}
	my $storage_mb = $resources->{storage_mb};
	if(defined($storage_mb) && $storage_mb ne "")
	{
		return (undef, _validation_error("invalid_resource_limit", "storage_mb must be a positive integer"))
			unless($storage_mb =~ /^\d+\z/ && $storage_mb > 0);
	}
	return ({
		cpu_cores => 0 + $cpu_cores,
		memory_mb => 0 + $memory_mb,
		memory_burst_mb => 0 + $memory_burst_mb,
		pids_limit => 0 + $pids_limit,
		# Recorded only: Docker cannot cap a bind mount, so this is not enforced.
		storage_mb => defined($storage_mb) && $storage_mb ne "" ? 0 + $storage_mb : undef,
		storage_enforced => JSON::PP::false()
	}, undef);
}

# Validates assigned/published TCP and UDP port ranges.
sub _validate_ports
{
	my ($ports) = @_;
	return (undef, _validation_error("invalid_port_block", "ports must be a hash")) unless(ref($ports) eq "HASH");
	my $ip = $ports->{ip} || "0.0.0.0";
	return (undef, _validation_error("invalid_port_block", "host IP contains invalid characters"))
		unless($ip =~ /\A[0-9A-Fa-f:.]+\z/);
	$ip = "[$ip]" if($ip =~ /:/);
	my $assigned_blocks = ref($ports->{assigned_blocks}) eq "ARRAY" ? $ports->{assigned_blocks} : $ports->{blocks};
	my $publish_blocks = ref($ports->{publish}) eq "ARRAY" ? $ports->{publish} : $ports->{blocks};
	return (undef, _validation_error("invalid_port_block", "ports.blocks must be a non-empty array"))
		unless(ref($publish_blocks) eq "ARRAY" && @$publish_blocks);
	return (undef, _validation_error("invalid_port_block", "assigned port blocks must be a non-empty array"))
		unless(ref($assigned_blocks) eq "ARRAY" && @$assigned_blocks);
	my @assigned = map { _normalize_port_block($_) } @$assigned_blocks;
	foreach my $assigned (@assigned)
	{
		return (undef, _validation_error("invalid_port_block", $assigned->{error})) if($assigned->{error});
	}
	my @publish;
	my $published_count = 0;
	foreach my $block (@$publish_blocks)
	{
		my $normalized = _normalize_port_block($block);
		return (undef, _validation_error("invalid_port_block", $normalized->{error})) if($normalized->{error});
		my $inside = 0;
		foreach my $assigned (@assigned)
		{
			next unless($assigned->{protocol} eq $normalized->{protocol});
			if($normalized->{host_start} >= $assigned->{host_start} && $normalized->{host_end} <= $assigned->{host_end})
			{
				$inside = 1;
				last;
			}
		}
		return (undef, _validation_error("invalid_port_block", "published port block is outside the assigned block")) unless($inside);
		$published_count += $normalized->{host_end} - $normalized->{host_start} + 1;
		push(@publish, $normalized);
	}
	return (undef, _validation_error("invalid_port_block", "too many published ports (max 256)")) if($published_count > 256);
	return ({
		ip => $ip,
		assigned_blocks => [ sort { $a->{protocol} cmp $b->{protocol} || $a->{host_start} <=> $b->{host_start} } @assigned ],
		publish => [ sort { $a->{protocol} cmp $b->{protocol} || $a->{host_start} <=> $b->{host_start} } @publish ]
	}, undef);
}

# Normalizes a single port block for deterministic command construction.
sub _normalize_port_block
{
	my ($block) = @_;
	return { error => "port block must be a hash" } unless(ref($block) eq "HASH");
	my $protocol = lc($block->{protocol} || "");
	return { error => "protocol must be tcp or udp" } unless($protocol =~ /\A(?:tcp|udp)\z/);
	foreach my $field (qw(host_start host_end container_start))
	{
		return { error => "$field must be a valid TCP/UDP port" }
			unless(defined($block->{$field}) && $block->{$field} =~ /^\d+\z/ && $block->{$field} >= 1 && $block->{$field} <= 65535);
	}
	return { error => "host_end must be greater than or equal to host_start" } if($block->{host_end} < $block->{host_start});
	my $count = $block->{host_end} - $block->{host_start};
	return { error => "container port range exceeds 65535" } if($block->{container_start} + $count > 65535);
	return {
		protocol => $protocol,
		host_start => 0 + $block->{host_start},
		host_end => 0 + $block->{host_end},
		container_start => 0 + $block->{container_start}
	};
}

# Validates legacy persistent volume mappings under the platform-owned root.
sub _validate_volumes
{
	my ($self, $storage) = @_;
	return (undef, _validation_error("invalid_volume_path", "storage.volumes must be an array"))
		unless(ref($storage) eq "HASH" && ref($storage->{volumes}) eq "ARRAY" && @{$storage->{volumes}});
	my @volumes;
	foreach my $volume (@{$storage->{volumes}})
	{
		return (undef, _validation_error("invalid_volume_path", "volume must be a hash")) unless(ref($volume) eq "HASH");
		my $name = $volume->{name};
		return (undef, _validation_error("invalid_volume_path", "volume name contains invalid characters"))
			unless(defined($name) && $name =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/);
		my $host_path = $volume->{host_path};
		my $source_error = _bind_source_error(defined($host_path) ? _absolute_path($host_path) : undef);
		return (undef, _validation_error("invalid_volume_path", $source_error)) if($source_error ne "");
		my $host_abs = _real_path($host_path);
		return (undef, _validation_error("invalid_volume_path", "host_path must stay inside the container data root"))
			unless(_path_is_inside($self->{data_root}, $host_abs));
		my $container_path = $volume->{container_path};
		return (undef, _validation_error("invalid_volume_path", "container_path must be absolute"))
			unless(_container_path_ok($container_path));
		my $mode = $volume->{mode} || "rw";
		return (undef, _validation_error("invalid_volume_path", "volume mode must be ro or rw"))
			unless($mode =~ /\A(?:ro|rw)\z/);
		push(@volumes, {
			name => $name,
			host_path => $host_abs,
			docker_source => $host_abs,
			container_path => $container_path,
			mode => $mode,
			persistent => $volume->{persistent} ? JSON::PP::true() : JSON::PP::false()
		});
	}
	return ([ sort { $a->{name} cmp $b->{name} } @volumes ], undef);
}

# Validates mounts the agent resolved for a game server (gamefiles and the control folder).
sub _validate_agent_mounts
{
	my ($self, $mounts, $forbidden) = @_;
	return (undef, _validation_error("invalid_volume_path", "agent mounts must be a non-empty array"))
		unless(ref($mounts) eq "ARRAY" && @$mounts);
	my @volumes;
	my %seen_target;
	foreach my $mount (@$mounts)
	{
		return (undef, _validation_error("invalid_volume_path", "mount must be a hash")) unless(ref($mount) eq "HASH");
		my $name = $mount->{name};
		return (undef, _validation_error("invalid_volume_path", "mount name contains invalid characters"))
			unless(defined($name) && $name =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/);
		my $source_error = _bind_source_error($mount->{host_path}, $mount->{allow_inside_agent} ? [] : $forbidden);
		return (undef, _validation_error("invalid_volume_path", "$name: $source_error")) if($source_error ne "");
		return (undef, _validation_error("invalid_volume_path", "$name: container_path must be absolute"))
			unless(_container_path_ok($mount->{container_path}));
		return (undef, _validation_error("invalid_volume_path", "$name: duplicate container_path"))
			if($seen_target{$mount->{container_path}}++);
		my $mode = $mount->{mode} || "rw";
		return (undef, _validation_error("invalid_volume_path", "$name: mode must be ro or rw")) unless($mode =~ /\A(?:ro|rw)\z/);
		my $docker_source = defined($mount->{docker_source}) && $mount->{docker_source} ne "" ? $mount->{docker_source} : $mount->{host_path};
		return (undef, _validation_error("invalid_volume_path", "$name: docker source contains invalid characters"))
			if($docker_source =~ /[\x00-\x1f\x7f,]/);
		push(@volumes, {
			name => $name,
			host_path => _real_path($mount->{host_path}),
			docker_source => $docker_source,
			container_path => $mount->{container_path},
			mode => $mode,
			persistent => JSON::PP::true()
		});
	}
	return ([ sort { $a->{name} cmp $b->{name} } @volumes ], undef);
}

# Validates the Linux uid/gid the container runs as. Root (0) is refused.
sub _validate_run_as
{
	my ($run_as) = @_;
	return ({}, undef) unless(defined($run_as));
	return (undef, _validation_error("invalid_contract", "run_as must be a hash")) unless(ref($run_as) eq "HASH");
	foreach my $field (qw(uid gid))
	{
		return (undef, _validation_error("invalid_contract", "run_as.$field must be a non-root numeric id"))
			unless(defined($run_as->{$field}) && $run_as->{$field} =~ /^\d+\z/ && $run_as->{$field} > 0);
	}
	return ({ uid => 0 + $run_as->{uid}, gid => 0 + $run_as->{gid} }, undef);
}

# Validates environment variables as explicit key/value data.
sub _validate_environment
{
	my ($environment) = @_;
	return ({}, undef) unless(defined($environment));
	return (undef, _validation_error("invalid_environment", "environment must be a hash")) unless(ref($environment) eq "HASH");
	my %normalized;
	foreach my $key (sort keys %$environment)
	{
		return (undef, _validation_error("invalid_environment", "environment key contains invalid characters"))
			unless($key =~ /\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/);
		my $value = $environment->{$key};
		return (undef, _validation_error("invalid_environment", "environment value must be scalar"))
			if(ref($value));
		$value = "" unless(defined($value));
		return (undef, _validation_error("invalid_environment", "environment value contains a NUL or newline"))
			if($value =~ /[\x00\n\r]/);
		$normalized{$key} = "" . $value;
	}
	return (\%normalized, undef);
}

# Validates an optional structured command argv.
sub _validate_optional_argv
{
	my ($argv, $field) = @_;
	return ([], undef) unless(defined($argv));
	return (undef, _validation_error("invalid_contract", "$field must be an array of arguments")) unless(ref($argv) eq "ARRAY");
	my @normalized;
	foreach my $arg (@$argv)
	{
		return (undef, _validation_error("invalid_contract", "$field argument must be scalar")) if(ref($arg));
		$arg = "" unless(defined($arg));
		return (undef, _validation_error("invalid_contract", "$field argument contains a NUL byte")) if($arg =~ /\x00/);
		push(@normalized, "" . $arg);
	}
	return (\@normalized, undef);
}

# Validates the optional entrypoint without allowing shell fragments.
sub _validate_optional_entrypoint
{
	my ($entrypoint) = @_;
	return ("", undef) unless(defined($entrypoint) && $entrypoint ne "");
	return (undef, _validation_error("invalid_contract", "entrypoint must be a scalar path or executable")) if(ref($entrypoint));
	return (undef, _validation_error("invalid_contract", "entrypoint contains invalid characters"))
		unless($entrypoint =~ /\A[A-Za-z0-9_\/:.-]+\z/);
	return ($entrypoint, undef);
}

# Validates Docker restart policy values controlled by the platform. The GSE watchdog owns
# restarts, so the default is "no".
sub _validate_restart_policy
{
	my ($restart_policy) = @_;
	$restart_policy = "no" unless(defined($restart_policy) && $restart_policy ne "");
	return (undef, _validation_error("invalid_contract", "unsupported restart policy"))
		unless($restart_policy =~ /\A(?:no|on-failure(?::\d{1,2})?|always|unless-stopped)\z/);
	return ($restart_policy, undef);
}

package GSE::Container::Runtime;

use strict;
use warnings;

# Defines the runtime adapter interface used by the agent RPC boundary.
sub new
{
	my ($class, %args) = @_;
	return bless({ %args }, $class);
}

# Creates a managed container from a validated platform request.
sub create { die "create is not implemented by this container runtime"; }

# Inspects a managed container by stable platform identity.
sub inspect { die "inspect is not implemented by this container runtime"; }

# Starts a managed container by stable platform identity.
sub start { die "start is not implemented by this container runtime"; }

# Stops a managed container by stable platform identity.
sub stop { die "stop is not implemented by this container runtime"; }

# Restarts a managed container by stable platform identity.
sub restart { die "restart is not implemented by this container runtime"; }

# Deletes a managed container by stable platform identity.
sub delete { die "delete is not implemented by this container runtime"; }

package GSE::Container::CommandRunner;

use strict;
use warnings;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Select;
use IPC::Open3;
use Symbol qw(gensym);
use Time::HiRes qw(time sleep);

use constant MAX_CAPTURE_BYTES => 4 * 1024 * 1024;

# Creates a command runner that executes argv arrays with a bounded timeout.
sub new
{
	my ($class) = @_;
	return bless({}, $class);
}

# Runs a command argv directly without shell interpolation and captures bounded output.
sub run
{
	my ($self, $argv, $timeout_seconds) = @_;
	$timeout_seconds = GSE::Container::Models::DEFAULT_COMMAND_TIMEOUT_SECONDS()
		unless(defined($timeout_seconds) && $timeout_seconds =~ /^\d+\z/ && $timeout_seconds > 0);
	return { exit_code => 127, stdout => "", stderr => "command argv must be a non-empty array", timed_out => 0 }
		unless(ref($argv) eq "ARRAY" && @$argv);

	# The agent's RPC processes ignore SIGCHLD, which makes waitpid lose the exit code.
	local $SIG{CHLD} = 'DEFAULT';
	my ($stdin, $stdout);
	my $stderr = gensym();
	my $pid = eval { open3($stdin, $stdout, $stderr, @$argv) };
	return { exit_code => 127, stdout => "", stderr => $@ || "failed to start command", timed_out => 0 } unless($pid);
	close($stdin);
	_set_nonblocking($stdout);
	_set_nonblocking($stderr);
	my $selector = IO::Select->new($stdout, $stderr);
	my %buffer = ("$stdout" => "", "$stderr" => "");
	my $deadline = time() + $timeout_seconds;
	my $timed_out = 0;

	while($selector->count)
	{
		if(time() >= $deadline)
		{
			$timed_out = 1;
			kill 9, $pid;
			last;
		}
		foreach my $handle ($selector->can_read(0.1))
		{
			my $chunk = "";
			my $read = sysread($handle, $chunk, 8192);
			if(defined($read) && $read > 0)
			{
				$buffer{"$handle"} .= $chunk if(length($buffer{"$handle"}) < MAX_CAPTURE_BYTES);
			}
			else
			{
				$selector->remove($handle);
				close($handle);
			}
		}
	}

	waitpid($pid, 0);
	my $exit_code = $timed_out ? 124 : (($? >> 8) || 0);
	return {
		exit_code => $exit_code,
		stdout => $buffer{"$stdout"} || "",
		stderr => $buffer{"$stderr"} || "",
		timed_out => $timed_out ? 1 : 0
	};
}

# Applies nonblocking mode to a child output handle.
sub _set_nonblocking
{
	my ($handle) = @_;
	my $flags = fcntl($handle, F_GETFL, 0);
	fcntl($handle, F_SETFL, $flags | O_NONBLOCK) if(defined($flags));
}

package GSE::Container::DockerRuntime;

use strict;
use warnings;
use parent -norequire, 'GSE::Container::Runtime';
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;

# Creates a Docker-backed runtime adapter with injectable command execution.
sub new
{
	my ($class, %args) = @_;
	my $models = $args{models} || GSE::Container::Models->new(data_root => $args{data_root});
	return bless({
		docker_binary => $args{docker_binary} || "docker",
		runner => $args{runner} || GSE::Container::CommandRunner->new(),
		models => $models,
		lock_dir => defined($args{lock_dir}) ? $args{lock_dir} : File::Spec->catdir($models->data_root, "locks"),
		command_timeout_seconds => $args{command_timeout_seconds} || GSE::Container::Models::DEFAULT_COMMAND_TIMEOUT_SECONDS(),
		pull_timeout_seconds => $args{pull_timeout_seconds} || GSE::Container::Models::DEFAULT_PULL_TIMEOUT_SECONDS(),
		stop_timeout_seconds => $args{stop_timeout_seconds} || GSE::Container::Models::DEFAULT_STOP_TIMEOUT_SECONDS(),
		network_options => $args{network_options} || {}
	}, $class);
}

# Runs $code while holding the per-container lock so concurrent RPCs cannot race.
sub _with_lock
{
	my ($self, $name, $code) = @_;
	return $code->() unless(defined($self->{lock_dir}) && $self->{lock_dir} ne "");
	make_path($self->{lock_dir}) unless(-d $self->{lock_dir});
	my $path = File::Spec->catfile($self->{lock_dir}, "$name.lock");
	open(my $fh, '>>', $path) or return $code->();
	flock($fh, LOCK_EX);
	my @result = eval { $code->() };
	my $error = $@;
	flock($fh, LOCK_UN);
	close($fh);
	die $error if($error);
	return wantarray ? @result : $result[0];
}

# Creates a container when absent. An existing owned container with the same configuration is
# kept; a stopped one with a changed configuration is recreated when recreate_if_changed is set.
sub create
{
	my ($self, $request, $context) = @_;
	my ($spec, $error) = $self->{models}->validate_create_request($request, $context);
	return _result_from_validation_error($error) unless($spec);
	return $self->_with_lock($spec->{container_name}, sub {
		my $current = $self->_inspect_unlocked($spec->{target});
		return $current if(!$current->{success} && $current->{error}{code} ne "container_not_found");
		if($current->{success})
		{
			my $existing_hash = $current->{result}{config_hash} || "";
			if($existing_hash eq $spec->{labels}{"gse.config_hash"})
			{
				return GSE::Container::Result->success(
					status => "already_exists",
					state => $current->{state},
					message => "Owned container already exists with the same configuration.",
					target => _target_response($spec->{target}, $spec->{container_name}, $current->{target}{container_id}),
					result => { config_hash => $existing_hash, summary => $current->{result}{summary} }
				);
			}
			return GSE::Container::Result->failure(
				status => "conflict",
				state => $current->{state},
				code => "config_changed",
				category => "conflict",
				message => "Container configuration changed; stop the server so it can be recreated.",
				target => _target_response($spec->{target}, $spec->{container_name}, $current->{target}{container_id}),
				details => {}
			) if($current->{state} eq "running" || $current->{state} eq "restarting" || !$request->{recreate_if_changed});
			my $rm = $self->_run($self->build_delete_argv($spec->{target}, 0), $self->{command_timeout_seconds});
			return $self->_runtime_failure($spec->{target}, "delete", $rm) unless($rm->{exit_code} == 0);
		}
		my $image_result = $self->_ensure_image($spec);
		return $image_result unless($image_result->{success});
		my $network_result = $self->_ensure_network($spec);
		return $network_result unless($network_result->{success});
		my $argv = $self->build_create_argv($spec);
		my $run = $self->_run($argv, $self->{command_timeout_seconds});
		return $self->_runtime_failure($spec->{target}, "create", $run) unless($run->{exit_code} == 0);
		my $container_id = _trim($run->{stdout});
		return GSE::Container::Result->success(
			status => $current->{success} ? "recreated" : "created",
			state => "created",
			message => $current->{success} ? "Container recreated with the new configuration." : "Container created.",
			target => _target_response($spec->{target}, $spec->{container_name}, $container_id),
			result => {
				config_hash => $spec->{labels}{"gse.config_hash"},
				image => $spec->{image}{resolved},
				storage_limit_enforced => JSON::PP::false()
			}
		);
	});
}

# Pulls the image when policy requires it.
sub _ensure_image
{
	my ($self, $spec) = @_;
	my $policy = $spec->{image}{pull_policy};
	my $reference = $spec->{image}{resolved};
	if($policy ne "always")
	{
		my $have = $self->_run([$self->{docker_binary}, "image", "inspect", "--format", "{{.Id}}", $reference], $self->{command_timeout_seconds});
		return GSE::Container::Result->success(status => "present") if($have->{exit_code} == 0);
		return GSE::Container::Result->failure(
			status => "failed",
			state => "error",
			code => "image_missing",
			category => "runtime",
			message => "Image is not present and the pull policy is never.",
			target => _target_response($spec->{target}, $spec->{container_name}),
			details => {}
		) if($policy eq "never");
	}
	my $pull = $self->_run([$self->{docker_binary}, "pull", "--quiet", $reference], $self->{pull_timeout_seconds});
	return $self->_runtime_failure($spec->{target}, "pull", $pull) unless($pull->{exit_code} == 0);
	return GSE::Container::Result->success(status => "pulled");
}

# Creates the shared game network when it is missing: a bridge with container-to-container
# traffic disabled. Host and private-network blocking is done by the host firewall script.
sub _ensure_network
{
	my ($self, $spec) = @_;
	my $network = $spec->{network};
	my $have = $self->_run([$self->{docker_binary}, "network", "inspect", "--format", "{{.Id}}", $network], $self->{command_timeout_seconds});
	return GSE::Container::Result->success(status => "present") if($have->{exit_code} == 0);
	my @argv = ($self->{docker_binary}, "network", "create", "--driver", "bridge",
		"--opt", "com.docker.network.bridge.enable_icc=false",
		"--opt", "com.docker.network.bridge.name=gse0",
		"--label", "gse.managed=true");
	push(@argv, "--subnet", $self->{network_options}{subnet}) if($self->{network_options}{subnet});
	push(@argv, $network);
	my $create = $self->_run(\@argv, $self->{command_timeout_seconds});
	return GSE::Container::Result->success(status => "created") if($create->{exit_code} == 0);
	return GSE::Container::Result->success(status => "present") if(($create->{stderr} || "") =~ /already exists/i);
	return $self->_runtime_failure($spec->{target}, "network create", $create);
}

# Inspects an owned container and maps runtime state to contract state.
sub inspect
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	return $self->_inspect_unlocked($target);
}

sub _inspect_unlocked
{
	my ($self, $target) = @_;
	my $name = $target->{container_name};
	my $argv = $self->build_inspect_argv($target);
	my $run = $self->_run($argv, $self->{command_timeout_seconds});
	if($run->{exit_code} != 0)
	{
		return GSE::Container::Result->failure(
			status => "not_found",
			state => "absent",
			code => "container_not_found",
			category => "not_found",
			message => "Container was not found.",
			target => _target_response($target, $name),
			details => {}
		) if(($run->{stderr} || "") =~ /No such object|No such container|not found/i);
		return $self->_runtime_failure($target, "inspect", $run);
	}
	my $inspect = eval { JSON::PP->new->decode($run->{stdout}) };
	$inspect = $inspect->[0] if(ref($inspect) eq "ARRAY");
	if($@ || ref($inspect) ne "HASH")
	{
		return GSE::Container::Result->failure(
			status => "failed",
			state => "unknown",
			code => "runtime_command_failed",
			category => "runtime",
			message => "Docker inspect returned invalid JSON.",
			target => _target_response($target, $name),
			details => {}
		);
	}
	my $labels = ref($inspect->{Config}) eq "HASH" && ref($inspect->{Config}{Labels}) eq "HASH" ? $inspect->{Config}{Labels} : {};
	my ($owned, $owner_message) = GSE::Container::Models->verify_ownership($target, $labels);
	return GSE::Container::Result->failure(
		status => "conflict",
		state => "unknown",
		code => "ownership_conflict",
		category => "conflict",
		message => $owner_message,
		target => _target_response($target, $name),
		details => {}
	) unless($owned);
	my $state = GSE::Container::Models->state_from_inspect($inspect);
	return GSE::Container::Result->success(
		status => "completed",
		state => $state,
		message => "Container inspected.",
		target => _target_response($target, $name, $inspect->{Id}),
		result => {
			config_hash => $labels->{"gse.config_hash"} || "",
			summary => _inspect_summary($inspect),
			mount_sources => [ map { $_->{Source} } grep { ref($_) eq "HASH" } @{ref($inspect->{Mounts}) eq "ARRAY" ? $inspect->{Mounts} : []} ]
		}
	);
}

# Only the parts of docker inspect the Panel needs. Environment, command line and mounts are
# left out because they can carry secrets and host paths.
sub _inspect_summary
{
	my ($inspect) = @_;
	my $state = ref($inspect->{State}) eq "HASH" ? $inspect->{State} : {};
	my $host = ref($inspect->{HostConfig}) eq "HASH" ? $inspect->{HostConfig} : {};
	my $config = ref($inspect->{Config}) eq "HASH" ? $inspect->{Config} : {};
	return {
		id => $inspect->{Id} || "",
		image => $config->{Image} || "",
		created => $inspect->{Created} || "",
		status => $state->{Status} || "",
		running => $state->{Running} ? JSON::PP::true() : JSON::PP::false(),
		oom_killed => $state->{OOMKilled} ? JSON::PP::true() : JSON::PP::false(),
		exit_code => defined($state->{ExitCode}) ? 0 + $state->{ExitCode} : undef,
		started_at => $state->{StartedAt} || "",
		finished_at => $state->{FinishedAt} || "",
		restart_count => defined($inspect->{RestartCount}) ? 0 + $inspect->{RestartCount} : 0,
		memory_bytes => defined($host->{Memory}) ? 0 + $host->{Memory} : undef,
		nano_cpus => defined($host->{NanoCpus}) ? 0 + $host->{NanoCpus} : undef,
		pids_limit => defined($host->{PidsLimit}) ? 0 + $host->{PidsLimit} : undef,
		health => ref($state->{Health}) eq "HASH" ? ($state->{Health}{Status} || "") : ""
	};
}

# Starts an owned container, treating an already-running container as success. When the agent
# passes expected mounts, their sources are checked again right before Docker resolves them.
sub start
{
	my ($self, $request, $context) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	return $self->_with_lock($target->{container_name}, sub {
		my $current = $self->_inspect_unlocked($target);
		return $current unless($current->{success});
		if($current->{state} eq "running")
		{
			return GSE::Container::Result->success(
				status => "already_running",
				state => "running",
				message => "Container is already running.",
				target => $current->{target},
				result => { summary => $current->{result}{summary} }
			);
		}
		if(ref($context) eq "HASH" && ref($context->{mounts}) eq "ARRAY")
		{
			my %expected = map { $_->{docker_source} || $_->{host_path} => 1 } @{$context->{mounts}};
			foreach my $mount (@{$context->{mounts}})
			{
				my $source_error = GSE::Container::Models::_bind_source_error($mount->{host_path},
					$mount->{allow_inside_agent} ? [] : $context->{forbidden_roots});
				return GSE::Container::Result->failure(
					status => "failed", state => $current->{state}, code => "mount_rejected", category => "validation",
					message => "Mount $mount->{name} failed its safety check: $source_error",
					target => $current->{target}, details => {}
				) if($source_error ne "");
			}
			foreach my $source (@{$current->{result}{mount_sources} || []})
			{
				return GSE::Container::Result->failure(
					status => "conflict", state => $current->{state}, code => "config_changed", category => "conflict",
					message => "Container mounts no longer match the server folder; it must be recreated.",
					target => $current->{target}, details => {}
				) unless($expected{$source});
			}
		}
		my $argv = $self->build_start_argv($target);
		my $run = $self->_run($argv, $self->{command_timeout_seconds});
		return $self->_runtime_failure($target, "start", $run) unless($run->{exit_code} == 0);
		return GSE::Container::Result->success(
			status => "started",
			state => "running",
			message => "Container started.",
			target => _target_response($target, $target->{container_name})
		);
	});
}

# Stops an owned container, treating a stopped container as success.
sub stop
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	my $allow_absent = $request->{allow_absent} ? 1 : 0;
	return $self->_with_lock($target->{container_name}, sub {
		my $current = $self->_inspect_unlocked($target);
		if(!$current->{success})
		{
			return GSE::Container::Result->success(
				status => "already_absent",
				state => "absent",
				message => "Container is already absent.",
				target => _target_response($target, $target->{container_name})
			) if($allow_absent && $current->{error}{code} eq "container_not_found");
			return $current;
		}
		if($current->{state} ne "running" && $current->{state} ne "restarting")
		{
			return GSE::Container::Result->success(
				status => "already_stopped",
				state => $current->{state} eq "oom" ? "oom" : "stopped",
				message => "Container is already stopped.",
				target => $current->{target},
				result => { summary => $current->{result}{summary} }
			);
		}
		my $timeout = _operation_timeout($request, $self->{stop_timeout_seconds});
		my $argv = $self->build_stop_argv($target, $timeout);
		my $run = $self->_run($argv, $timeout + 15);
		return $self->_runtime_failure($target, "stop", $run) unless($run->{exit_code} == 0);
		return GSE::Container::Result->success(
			status => "stopped",
			state => "stopped",
			message => "Container stopped.",
			target => _target_response($target, $target->{container_name})
		);
	});
}

# Restarts by using the same bounded stop and start lifecycle path.
sub restart
{
	my ($self, $request, $context) = @_;
	my $stop = $self->stop($request);
	return $stop unless($stop->{success});
	my $start = $self->start($request, $context);
	return $start unless($start->{success});
	return GSE::Container::Result->success(
		status => "restarted",
		state => "running",
		message => "Container restarted.",
		target => $start->{target},
		result => { stop => $stop->{status}, start => $start->{status} }
	);
}

# Deletes an owned stopped container, optionally treating absent as success.
sub delete
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	my $allow_absent = $request->{allow_absent} ? 1 : 0;
	return $self->_with_lock($target->{container_name}, sub {
		my $current = $self->_inspect_unlocked($target);
		if(!$current->{success})
		{
			return GSE::Container::Result->success(
				status => "already_absent",
				state => "absent",
				message => "Container is already absent.",
				target => _target_response($target, $target->{container_name})
			) if($allow_absent && $current->{error}{code} eq "container_not_found");
			return $current;
		}
		if($current->{state} eq "running" || $current->{state} eq "restarting")
		{
			return GSE::Container::Result->failure(
				status => "conflict",
				state => "running",
				code => "container_running",
				category => "conflict",
				message => "Container must be stopped before delete.",
				target => $current->{target},
				details => {}
			);
		}
		# Game files are bind mounts on the host, so they are never removed here.
		my $argv = $self->build_delete_argv($target, 0);
		my $run = $self->_run($argv, $self->{command_timeout_seconds});
		return $self->_runtime_failure($target, "delete", $run) unless($run->{exit_code} == 0);
		return GSE::Container::Result->success(
			status => "deleted",
			state => "absent",
			message => "Container deleted.",
			target => _target_response($target, $target->{container_name})
		);
	});
}

# Returns the last lines of the container's own output (bounded).
sub logs
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	my $current = $self->_inspect_unlocked($target);
	return $current unless($current->{success});
	my $lines = GSE::Container::Models::_bounded_int($request->{lines}, 200, 1, 5000);
	my $run = $self->_run([$self->{docker_binary}, "logs", "--tail", "" . $lines, $target->{container_name}], $self->{command_timeout_seconds});
	return $self->_runtime_failure($target, "logs", $run) unless($run->{exit_code} == 0);
	my $text = ($run->{stdout} || "") . ($run->{stderr} || "");
	$text =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
	return GSE::Container::Result->success(
		status => "completed",
		state => $current->{state},
		message => "Container output.",
		target => $current->{target},
		result => { lines => [ split(/\n/, $text) ] }
	);
}

# Returns one CPU/memory/pids sample for a running container.
sub stats
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	my $current = $self->_inspect_unlocked($target);
	return $current unless($current->{success});
	return GSE::Container::Result->success(
		status => "completed", state => $current->{state}, message => "Container is not running.",
		target => $current->{target}, result => {}
	) unless($current->{state} eq "running");
	my $run = $self->_run([$self->{docker_binary}, "stats", "--no-stream", "--format", "{{json .}}", $target->{container_name}], $self->{command_timeout_seconds});
	return $self->_runtime_failure($target, "stats", $run) unless($run->{exit_code} == 0);
	my $sample = eval { JSON::PP->new->decode(_trim($run->{stdout})) } || {};
	return GSE::Container::Result->success(
		status => "completed",
		state => $current->{state},
		message => "Container resource sample.",
		target => $current->{target},
		result => {
			cpu_percent => $sample->{CPUPerc} || "",
			memory_usage => $sample->{MemUsage} || "",
			memory_percent => $sample->{MemPerc} || "",
			pids => $sample->{PIDs} || "",
			net_io => $sample->{NetIO} || "",
			block_io => $sample->{BlockIO} || ""
		}
	);
}

# Builds deterministic docker create argv from a validated create spec. Security options are
# always applied and cannot be turned off by a request.
sub build_create_argv
{
	my ($self, $spec) = @_;
	my @argv = ($self->{docker_binary}, "create", "--name", $spec->{container_name});
	foreach my $key (sort keys %{$spec->{labels}})
	{
		push(@argv, "--label", "$key=$spec->{labels}{$key}");
	}
	push(@argv, "--cpus", "" . $spec->{resources}{cpu_cores});
	push(@argv, "--memory", $spec->{resources}{memory_mb} . "m");
	push(@argv, "--memory-swap", $spec->{resources}{memory_burst_mb} . "m");
	push(@argv, "--pids-limit", "" . $spec->{resources}{pids_limit});
	push(@argv, "--restart", $spec->{restart_policy});
	push(@argv, "--stop-timeout", "" . $spec->{stop_timeout_seconds});
	push(@argv, "--network", $spec->{network});
	push(@argv, "--init");
	push(@argv, "--cap-drop", "ALL");
	push(@argv, "--security-opt", "no-new-privileges:true");
	push(@argv, "--ipc", "private");
	push(@argv, "--log-driver", "json-file",
		"--log-opt", "max-size=" . GSE::Container::Models::DEFAULT_LOG_MAX_SIZE(),
		"--log-opt", "max-file=" . GSE::Container::Models::DEFAULT_LOG_MAX_FILE());
	if($spec->{read_only_rootfs})
	{
		push(@argv, "--read-only");
		push(@argv, "--tmpfs", GSE::Container::Models::DEFAULT_TMPFS());
	}
	push(@argv, "--user", $spec->{run_as}{uid} . ":" . $spec->{run_as}{gid}) if(defined($spec->{run_as}{uid}));
	push(@argv, "--workdir", $spec->{workdir}) if($spec->{workdir} ne "");
	foreach my $volume (@{$spec->{volumes}})
	{
		# --mount fails when the source is missing (--volume would silently create it).
		my $mount = "type=bind,source=" . $volume->{docker_source} . ",target=" . $volume->{container_path};
		$mount .= ",readonly" if($volume->{mode} eq "ro");
		push(@argv, "--mount", $mount);
	}
	foreach my $block (@{$spec->{ports}{publish}})
	{
		for(my $host_port = $block->{host_start}; $host_port <= $block->{host_end}; $host_port++)
		{
			my $container_port = $block->{container_start} + ($host_port - $block->{host_start});
			push(@argv, "--publish", $spec->{ports}{ip} . ":" . $host_port . ":" . $container_port . "/" . $block->{protocol});
		}
	}
	foreach my $key (sort keys %{$spec->{environment}})
	{
		push(@argv, "--env", "$key=$spec->{environment}{$key}");
	}
	push(@argv, "--entrypoint", $spec->{entrypoint}) if($spec->{entrypoint} ne "");
	push(@argv, $spec->{image}{resolved});
	push(@argv, @{$spec->{command}});
	return \@argv;
}

# Builds docker inspect argv for the stable platform-owned name.
sub build_inspect_argv
{
	my ($self, $target) = @_;
	return [$self->{docker_binary}, "container", "inspect", "--format", "{{json .}}", $target->{container_name}];
}

# Builds docker start argv for the stable platform-owned name.
sub build_start_argv
{
	my ($self, $target) = @_;
	return [$self->{docker_binary}, "start", $target->{container_name}];
}

# Builds docker stop argv with an explicit bounded timeout.
sub build_stop_argv
{
	my ($self, $target, $timeout_seconds) = @_;
	return [$self->{docker_binary}, "stop", "--time", "" . $timeout_seconds, $target->{container_name}];
}

# Builds docker rm argv and never forces removal of running containers or removes volumes.
sub build_delete_argv
{
	my ($self, $target) = @_;
	return [$self->{docker_binary}, "rm", $target->{container_name}];
}

# Executes an argv vector through the injected runner.
sub _run
{
	my ($self, $argv, $timeout_seconds) = @_;
	return $self->{runner}->run($argv, $timeout_seconds);
}

# Converts validation failures into the shared response shape.
sub _result_from_validation_error
{
	my ($error) = @_;
	return GSE::Container::Result->failure(
		status => "validation_failed",
		state => "error",
		code => $error->{code},
		category => $error->{category},
		message => $error->{message},
		retryable => $error->{retryable},
		details => {}
	);
}

# Converts Docker command failures into structured runtime failures.
sub _runtime_failure
{
	my ($self, $target, $operation, $run) = @_;
	my $code = $run->{timed_out} ? "timeout" : "runtime_command_failed";
	my $category = $run->{timed_out} ? "timeout" : "runtime";
	if(!$run->{timed_out} && ($run->{stderr} || "") =~ /Cannot connect to the Docker daemon|permission denied while trying to connect|docker: command not found|No such file or directory.*docker/i)
	{
		$code = "runtime_unavailable";
		$category = "unavailable";
	}
	return GSE::Container::Result->failure(
		status => "failed",
		state => "unknown",
		code => $code,
		category => $category,
		message => "Docker $operation command failed.",
		retryable => ($run->{timed_out} || $code eq "runtime_unavailable") ? 1 : 0,
		target => _target_response($target, $target->{container_name}),
		details => {
			exit_code => $run->{exit_code},
			stderr => _safe_stderr($run->{stderr})
		}
	);
}

# Normalizes timeout input while keeping hard bounds.
sub _operation_timeout
{
	my ($request, $default_timeout) = @_;
	return GSE::Container::Models::_bounded_int($request->{timeout_seconds}, $default_timeout, 1, 300);
}

# Builds the target portion of a structured response.
sub _target_response
{
	my ($target, $container_name, $container_id) = @_;
	return {
		server_id => $target->{server_id},
		home_id => $target->{home_id},
		allocation_id => $target->{allocation_id},
		owner_user_id => $target->{owner_user_id},
		container_name => $container_name,
		defined($container_id) && $container_id ne "" ? (container_id => $container_id) : ()
	};
}

# Removes leading/trailing whitespace from runtime command output.
sub _trim
{
	my ($value) = @_;
	$value = "" unless(defined($value));
	$value =~ s/\A\s+//;
	$value =~ s/\s+\z//;
	return $value;
}

# Keeps runtime diagnostics bounded for panel-safe error details. Values after --env and
# anything that looks like a password are masked.
sub _safe_stderr
{
	my ($stderr) = @_;
	$stderr = "" unless(defined($stderr));
	$stderr =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/?/g;
	$stderr =~ s/((?:password|passwd|secret|token|key)[A-Za-z0-9_]*\s*[=:]\s*)\S+/$1***/gi;
	return substr($stderr, 0, 2048);
}

1;
