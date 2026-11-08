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

use constant CONTRACT_VERSION => "gse.container.v1";
use constant DEFAULT_DATA_ROOT => "AgentScripts/containers";
use constant DEFAULT_STOP_TIMEOUT_SECONDS => 30;
use constant DEFAULT_COMMAND_TIMEOUT_SECONDS => 60;

# Creates a validator/model helper with an agent-owned data root.
sub new
{
	my ($class, %args) = @_;
	my $data_root = defined($args{data_root}) && $args{data_root} ne "" ? $args{data_root} : DEFAULT_DATA_ROOT;
	return bless({
		data_root => _absolute_path($data_root)
	}, $class);
}

# Returns the absolute agent-owned root under which host volume paths must stay.
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
		"gse.agent" => "windows",
		"gse.allocation_id" => "" . $target->{allocation_id},
		"gse.contract_version" => CONTRACT_VERSION,
		"gse.home_id" => "" . $target->{home_id},
		"gse.managed" => "true",
		"gse.owner_user_id" => "" . $target->{owner_user_id},
		"gse.server_id" => "" . $target->{server_id}
	};
}

# Validates and normalizes a create request into deterministic command inputs.
sub validate_create_request
{
	my ($self, $request) = @_;
	return (undef, _validation_error("invalid_contract", "request must be a hash")) unless(ref($request) eq "HASH");
	my ($target, $target_error) = $self->validate_target($request->{target});
	return (undef, $target_error) unless($target);
	return (undef, _validation_error("invalid_contract", "contract must be " . CONTRACT_VERSION))
		unless(defined($request->{contract}) && $request->{contract} eq CONTRACT_VERSION);
	my $payload = $request->{payload};
	return (undef, _validation_error("invalid_contract", "payload must be a hash")) unless(ref($payload) eq "HASH");

	my ($image, $image_error) = _validate_image($payload->{image});
	return (undef, $image_error) unless($image);
	my ($resources, $resource_error) = _validate_resources($payload->{resources});
	return (undef, $resource_error) unless($resources);
	my ($ports, $port_error) = _validate_ports($payload->{ports});
	return (undef, $port_error) unless($ports);
	my ($volumes, $volume_error) = $self->_validate_volumes($payload->{storage});
	return (undef, $volume_error) unless($volumes);
	my ($environment, $environment_error) = _validate_environment($payload->{environment});
	return (undef, $environment_error) unless($environment);
	my ($command, $command_error) = _validate_optional_argv($payload->{command}, "command");
	return (undef, $command_error) unless(defined($command));
	my ($entrypoint, $entrypoint_error) = _validate_optional_entrypoint($payload->{entrypoint});
	return (undef, $entrypoint_error) unless(defined($entrypoint));
	my ($restart_policy, $restart_error) = _validate_restart_policy($payload->{restart_policy});
	return (undef, $restart_error) unless($restart_policy);

	my $container_name = __PACKAGE__->container_name($target);
	my $labels = __PACKAGE__->labels_for_target($target);
	return ({
		contract => CONTRACT_VERSION,
		target => $target,
		container_name => $container_name,
		labels => $labels,
		image => $image,
		resources => $resources,
		ports => $ports,
		volumes => $volumes,
		environment => $environment,
		command => $command,
		entrypoint => $entrypoint,
		restart_policy => $restart_policy
	}, undef);
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

# Confirms runtime labels match the platform-owned target.
sub verify_ownership
{
	my ($class, $target, $labels) = @_;
	return (0, "ownership labels are missing") unless(ref($labels) eq "HASH");
	my $expected = $class->labels_for_target($target);
	foreach my $key (sort keys %$expected)
	{
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
	return "running" if($state->{Running});
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

# Returns true when the child path is contained by the configured data root.
sub _path_is_inside
{
	my ($root, $child) = @_;
	my $root_abs = _absolute_path($root);
	my $child_abs = _absolute_path($child);
	$root_abs =~ s{[\\/]+\z}{};
	$child_abs =~ s{[\\/]+\z}{};
	return $child_abs eq $root_abs || index($child_abs . "/", $root_abs . "/") == 0;
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
	return (0, "$field is required") unless(defined($value));
	return (0, "$field must be a positive integer") unless($value =~ /^\d+\z/ && $value > 0);
	return (1, "");
}

# Validates a Docker image reference without accepting shell syntax.
sub _validate_image
{
	my ($image) = @_;
	return (undef, _validation_error("invalid_image", "image must be a hash")) unless(ref($image) eq "HASH");
	my $reference = $image->{reference};
	return (undef, _validation_error("invalid_image", "image reference is required")) unless(defined($reference) && $reference ne "");
	return (undef, _validation_error("invalid_image", "image reference contains invalid characters"))
		unless($reference =~ /\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,254}\z/);
	return (undef, _validation_error("invalid_image", "image reference contains traversal or empty path segments"))
		if($reference =~ m{(^|/)\.\.?(/|\z)} || $reference =~ m{//});
	my $pull_policy = $image->{pull_policy} || "if_missing";
	return (undef, _validation_error("invalid_image", "unsupported image pull policy"))
		unless($pull_policy =~ /\A(?:if_missing|always|never)\z/);
	if(defined($image->{digest}) && $image->{digest} ne "")
	{
		return (undef, _validation_error("invalid_image", "image digest must be sha256 hex"))
			unless($image->{digest} =~ /\Asha256:[a-fA-F0-9]{64}\z/);
	}
	return ({
		reference => $reference,
		pull_policy => $pull_policy,
		digest => $image->{digest} || ""
	}, undef);
}

# Validates CPU, memory, and declared storage limits.
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
	my $memory_burst_mb = $resources->{memory_burst_mb};
	if(defined($memory_burst_mb) && $memory_burst_mb ne "")
	{
		return (undef, _validation_error("invalid_resource_limit", "memory_burst_mb must be at least memory_mb"))
			unless($memory_burst_mb =~ /^\d+\z/ && $memory_burst_mb >= $memory_mb && $memory_burst_mb <= 2097152);
	}
	my $storage_mb = $resources->{storage_mb};
	return (undef, _validation_error("invalid_resource_limit", "storage_mb must be a positive integer"))
		unless(defined($storage_mb) && $storage_mb =~ /^\d+\z/ && $storage_mb > 0);
	return ({
		cpu_cores => 0 + $cpu_cores,
		memory_mb => 0 + $memory_mb,
		memory_burst_mb => defined($memory_burst_mb) && $memory_burst_mb ne "" ? 0 + $memory_burst_mb : undef,
		storage_mb => 0 + $storage_mb
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
		push(@publish, $normalized);
	}
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

# Validates persistent volume mappings under the platform-owned root.
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
		return (undef, _validation_error("invalid_volume_path", "host_path is required")) unless(defined($host_path) && $host_path ne "");
		return (undef, _validation_error("invalid_volume_path", "host_path must not contain control characters"))
			if($host_path =~ /[\x00-\x1f\x7f]/);
		my $host_abs = _absolute_path($host_path);
		return (undef, _validation_error("invalid_volume_path", "host_path must stay inside the container data root"))
			unless(_path_is_inside($self->{data_root}, $host_abs));
		my $container_path = $volume->{container_path};
		return (undef, _validation_error("invalid_volume_path", "container_path must be absolute"))
			unless(defined($container_path) && $container_path =~ m{\A/[A-Za-z0-9._/-]+\z} && $container_path !~ m{/\.\.?(/|\z)});
		my $mode = $volume->{mode} || "rw";
		return (undef, _validation_error("invalid_volume_path", "volume mode must be ro or rw"))
			unless($mode =~ /\A(?:ro|rw)\z/);
		push(@volumes, {
			name => $name,
			host_path => $host_abs,
			container_path => $container_path,
			mode => $mode,
			persistent => $volume->{persistent} ? JSON::PP::true() : JSON::PP::false()
		});
	}
	return ([ sort { $a->{name} cmp $b->{name} } @volumes ], undef);
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
			unless($key =~ /\A[A-Z_][A-Z0-9_]{0,63}\z/);
		my $value = $environment->{$key};
		return (undef, _validation_error("invalid_environment", "environment value must be scalar"))
			if(ref($value));
		$value = "" unless(defined($value));
		return (undef, _validation_error("invalid_environment", "environment value contains a NUL byte"))
			if($value =~ /\x00/);
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

# Validates Docker restart policy values controlled by the platform.
sub _validate_restart_policy
{
	my ($restart_policy) = @_;
	$restart_policy = "unless-stopped" unless(defined($restart_policy) && $restart_policy ne "");
	return (undef, _validation_error("invalid_contract", "unsupported restart policy"))
		unless($restart_policy =~ /\A(?:no|on-failure|always|unless-stopped)\z/);
	return ($restart_policy, undef);
}

package GSE::Container::Runtime;

use strict;
use warnings;

# Interface placeholder for create implementations.
sub create { die "create is not implemented by this container runtime"; }

# Interface placeholder for inspect/status implementations.
sub inspect { die "inspect is not implemented by this container runtime"; }

# Interface placeholder for start implementations.
sub start { die "start is not implemented by this container runtime"; }

# Interface placeholder for stop implementations.
sub stop { die "stop is not implemented by this container runtime"; }

# Interface placeholder for restart implementations.
sub restart { die "restart is not implemented by this container runtime"; }

# Interface placeholder for delete implementations.
sub delete { die "delete is not implemented by this container runtime"; }

package GSE::Container::CommandRunner;

use strict;
use warnings;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Select;
use IPC::Open3;
use Symbol qw(gensym);
use Time::HiRes qw(time sleep);

# Creates a command runner that executes argv arrays with a bounded timeout.
sub new
{
	my ($class) = @_;
	return bless({}, $class);
}

# Runs a command argv directly without shell interpolation and captures output.
sub run
{
	my ($self, $argv, $timeout_seconds) = @_;
	$timeout_seconds = GSE::Container::Models::DEFAULT_COMMAND_TIMEOUT_SECONDS()
		unless(defined($timeout_seconds) && $timeout_seconds =~ /^\d+\z/ && $timeout_seconds > 0);
	return { exit_code => 127, stdout => "", stderr => "command argv must be a non-empty array", timed_out => 0 }
		unless(ref($argv) eq "ARRAY" && @$argv);

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
				$buffer{"$handle"} .= $chunk;
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
use JSON::PP;

# Creates a Docker-backed runtime adapter with injectable command execution.
sub new
{
	my ($class, %args) = @_;
	return bless({
		docker_binary => $args{docker_binary} || "docker",
		runner => $args{runner} || GSE::Container::CommandRunner->new(),
		models => $args{models} || GSE::Container::Models->new(data_root => $args{data_root}),
		command_timeout_seconds => $args{command_timeout_seconds} || GSE::Container::Models::DEFAULT_COMMAND_TIMEOUT_SECONDS(),
		stop_timeout_seconds => $args{stop_timeout_seconds} || GSE::Container::Models::DEFAULT_STOP_TIMEOUT_SECONDS()
	}, $class);
}

# Creates a container when absent, returning already_exists for owned matches.
sub create
{
	my ($self, $request) = @_;
	my ($spec, $error) = $self->{models}->validate_create_request($request);
	return _result_from_validation_error($error) unless($spec);
	my $current = $self->inspect({ target => $spec->{target} });
	return $current if(!$current->{success} && $current->{error}{code} ne "container_not_found");
	if($current->{success} && $current->{state} ne "absent")
	{
		return GSE::Container::Result->success(
			status => "already_exists",
			state => $current->{state},
			message => "Owned container already exists.",
			target => _target_response($spec->{target}, $spec->{container_name}, $current->{target}{container_id}),
			result => { inspect => $current->{result}{inspect} || {} }
		);
	}
	my $argv = $self->build_create_argv($spec);
	my $run = $self->_run($argv, $self->{command_timeout_seconds});
	return $self->_runtime_failure($spec->{target}, "create", $run) unless($run->{exit_code} == 0);
	my $container_id = _trim($run->{stdout});
	return GSE::Container::Result->success(
		status => "created",
		state => "created",
		message => "Container created.",
		target => _target_response($spec->{target}, $spec->{container_name}, $container_id),
		result => { argv => $argv }
	);
}

# Inspects an owned container and maps runtime state to contract state.
sub inspect
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
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
			details => { stderr => _safe_stderr($run->{stderr}) }
		) if(($run->{stderr} || "") =~ /No such object|not found/i);
		return $self->_runtime_failure($target, "inspect", $run);
	}
	my $inspect = eval { JSON::PP->new->decode($run->{stdout}) };
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
		result => { inspect => $inspect, argv => $argv }
	);
}

# Starts an owned container, treating an already-running container as success.
sub start
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	my $current = $self->inspect({ target => $target });
	return $current unless($current->{success});
	if($current->{state} eq "running")
	{
		return GSE::Container::Result->success(
			status => "already_running",
			state => "running",
			message => "Container is already running.",
			target => $current->{target},
			result => { inspect => $current->{result}{inspect} || {} }
		);
	}
	my $argv = $self->build_start_argv($target);
	my $run = $self->_run($argv, $self->{command_timeout_seconds});
	return $self->_runtime_failure($target, "start", $run) unless($run->{exit_code} == 0);
	return GSE::Container::Result->success(
		status => "started",
		state => "running",
		message => "Container started.",
		target => _target_response($target, $target->{container_name}),
		result => { argv => $argv }
	);
}

# Stops an owned container, treating a stopped container as success.
sub stop
{
	my ($self, $request) = @_;
	my ($target, $error) = $self->{models}->validate_target($request->{target});
	return _result_from_validation_error($error) unless($target);
	my $allow_absent = $request->{allow_absent} ? 1 : 0;
	my $current = $self->inspect({ target => $target });
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
	if($current->{state} ne "running")
	{
		return GSE::Container::Result->success(
			status => "already_stopped",
			state => "stopped",
			message => "Container is already stopped.",
			target => $current->{target},
			result => { inspect => $current->{result}{inspect} || {} }
		);
	}
	my $timeout = _operation_timeout($request, $self->{stop_timeout_seconds});
	my $argv = $self->build_stop_argv($target, $timeout);
	my $run = $self->_run($argv, $timeout + 10);
	return $self->_runtime_failure($target, "stop", $run) unless($run->{exit_code} == 0);
	return GSE::Container::Result->success(
		status => "stopped",
		state => "stopped",
		message => "Container stopped.",
		target => _target_response($target, $target->{container_name}),
		result => { argv => $argv }
	);
}

# Restarts by using the same bounded stop and start lifecycle path.
sub restart
{
	my ($self, $request) = @_;
	my $stop = $self->stop($request);
	return $stop unless($stop->{success});
	my $start = $self->start($request);
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
	my $current = $self->inspect({ target => $target });
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
	if($current->{state} eq "running")
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
	my $argv = $self->build_delete_argv($target, $request->{remove_volumes} ? 1 : 0);
	my $run = $self->_run($argv, $self->{command_timeout_seconds});
	return $self->_runtime_failure($target, "delete", $run) unless($run->{exit_code} == 0);
	return GSE::Container::Result->success(
		status => "deleted",
		state => "absent",
		message => "Container deleted.",
		target => _target_response($target, $target->{container_name}),
		result => { argv => $argv }
	);
}

# Builds deterministic docker create argv from a validated create spec.
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
	push(@argv, "--memory-swap", $spec->{resources}{memory_burst_mb} . "m") if(defined($spec->{resources}{memory_burst_mb}));
	push(@argv, "--restart", $spec->{restart_policy});
	foreach my $volume (@{$spec->{volumes}})
	{
		push(@argv, "--volume", $volume->{host_path} . ":" . $volume->{container_path} . ":" . $volume->{mode});
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
	push(@argv, $spec->{image}{reference});
	push(@argv, @{$spec->{command}});
	return \@argv;
}

# Builds docker inspect argv for the stable platform-owned name.
sub build_inspect_argv
{
	my ($self, $target) = @_;
	return [$self->{docker_binary}, "inspect", "--format", "{{json .}}", $target->{container_name}];
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

# Builds docker rm argv and never forces removal of running containers.
sub build_delete_argv
{
	my ($self, $target, $remove_volumes) = @_;
	my @argv = ($self->{docker_binary}, "rm");
	push(@argv, "--volumes") if($remove_volumes);
	push(@argv, $target->{container_name});
	return \@argv;
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
	return GSE::Container::Result->failure(
		status => "failed",
		state => "unknown",
		code => $code,
		category => $category,
		message => "Docker $operation command failed.",
		retryable => $run->{timed_out} ? 1 : 0,
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
	my $timeout = $request->{timeout_seconds};
	return $default_timeout unless(defined($timeout) && $timeout =~ /^\d+\z/);
	return 1 if($timeout < 1);
	return 300 if($timeout > 300);
	return 0 + $timeout;
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

# Keeps runtime diagnostics bounded for panel-safe error details.
sub _safe_stderr
{
	my ($stderr) = @_;
	$stderr = "" unless(defined($stderr));
	$stderr =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/?/g;
	return substr($stderr, 0, 2048);
}

1;
