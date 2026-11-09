#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module_file="$repo_root/AgentScripts/GSE/Container/Runtime.pm"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$module_file" ] || fail "missing AgentScripts/GSE/Container/Runtime.pm"

perl -I "$repo_root/AgentScripts" -Mstrict -Mwarnings -MTest::More -MJSON::PP -MFile::Spec - "$repo_root" <<'PERL' || exit 1
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Spec;
use GSE::Container::Runtime;

{
	package FakeRunner;

	use strict;
	use warnings;

	# Creates a deterministic command runner double for Docker adapter tests.
	sub new
	{
		my ($class) = @_;
		return bless({ queue => [], calls => [] }, $class);
	}

	# Adds the next command result returned by run().
	sub enqueue
	{
		my ($self, $result) = @_;
		push(@{$self->{queue}}, $result);
	}

	# Captures argv and timeout without executing Docker.
	sub run
	{
		my ($self, $argv, $timeout_seconds) = @_;
		push(@{$self->{calls}}, { argv => [@$argv], timeout => $timeout_seconds });
		return shift(@{$self->{queue}}) || { exit_code => 0, stdout => "", stderr => "", timed_out => 0 };
	}

	# Returns captured calls in order.
	sub calls
	{
		my ($self) = @_;
		return $self->{calls};
	}
}

my ($repo_root) = @ARGV;
my $data_root = File::Spec->catdir($repo_root, "AgentScripts", "containers");
my $host_volume = File::Spec->catdir($data_root, "homes", "42", "data");

# Builds the common valid create request used by command and validation tests.
sub create_request
{
	return {
		contract => "gse.container.v1",
		target => {
			server_id => 1,
			home_id => 42,
			allocation_id => 9001,
			owner_user_id => 456
		},
		payload => {
			image => {
				reference => "registry.example/gse/templates/dayz:2026.08.01",
				pull_policy => "if_missing"
			},
			resources => {
				cpu_cores => 2,
				memory_mb => 4096,
				memory_burst_mb => 6144,
				storage_mb => 51200
			},
			ports => {
				ip => "203.0.113.10",
				assigned_blocks => [
					{ protocol => "udp", host_start => 2302, host_end => 2310, container_start => 2302 },
					{ protocol => "tcp", host_start => 27015, host_end => 27020, container_start => 27015 }
				],
				publish => [
					{ protocol => "udp", host_start => 2302, host_end => 2303, container_start => 2302 },
					{ protocol => "tcp", host_start => 27015, host_end => 27016, container_start => 27015 }
				]
			},
			storage => {
				volumes => [
					{
						name => "data",
						host_path => $host_volume,
						container_path => "/srv/app/data",
						mode => "rw",
						persistent => 1
					}
				]
			},
			environment => {
				HOME_ID => "42",
				SERVER_MODE => "container"
			},
			entrypoint => "/entrypoint",
			command => ["--config", "/srv/app/config.json"],
			restart_policy => "unless-stopped"
		}
	};
}

# Creates Docker inspect JSON with the standard ownership labels.
sub inspect_json
{
	my (%args) = @_;
	my $target = {
		server_id => 1,
		home_id => 42,
		allocation_id => 9001,
		owner_user_id => 456
	};
	my $labels = GSE::Container::Models->labels_for_target($target);
	$labels = $args{labels} if($args{labels});
	return JSON::PP->new->canonical->encode({
		Id => $args{id} || "runtime-id",
		Config => { Labels => $labels },
		State => {
			Running => $args{running} ? JSON::PP::true : JSON::PP::false,
			Status => $args{status} || ($args{running} ? "running" : "exited"),
			ExitCode => $args{exit_code} || 0
		}
	});
}

sub not_found_result
{
	return { exit_code => 1, stdout => "", stderr => "Error: No such object: gse-h42-a9001", timed_out => 0 };
}

my $models = GSE::Container::Models->new(data_root => $data_root);
my ($spec, $error) = $models->validate_create_request(create_request());
ok($spec, "valid create request normalizes successfully");
is($spec->{container_name}, "gse-h42-a9001", "stable platform-owned container name");
is($spec->{labels}{"gse.managed"}, "true", "managed ownership label present");
is($spec->{labels}{"gse.contract_version"}, "gse.container.v1", "contract label present");

my $runner = FakeRunner->new();
$runner->enqueue(not_found_result());
$runner->enqueue({ exit_code => 0, stdout => "created-container-id\n", stderr => "", timed_out => 0 });
my $runtime = GSE::Container::DockerRuntime->new(
	docker_binary => "docker",
	runner => $runner,
	data_root => $data_root,
	command_timeout_seconds => 60,
	stop_timeout_seconds => 30
);
my $create = $runtime->create(create_request());
ok($create->{success}, "create succeeds after not-found inspect");
is($create->{status}, "created", "create returns created status");
is($create->{target}{container_name}, "gse-h42-a9001", "create response carries stable name");
is_deeply($runner->calls->[1]{argv}, [
	"docker", "create", "--name", "gse-h42-a9001",
	"--label", "gse.agent=windows",
	"--label", "gse.allocation_id=9001",
	"--label", "gse.contract_version=gse.container.v1",
	"--label", "gse.home_id=42",
	"--label", "gse.managed=true",
	"--label", "gse.owner_user_id=456",
	"--label", "gse.server_id=1",
	"--cpus", "2",
	"--memory", "4096m",
	"--memory-swap", "6144m",
	"--restart", "unless-stopped",
	"--volume", "$host_volume:/srv/app/data:rw",
	"--publish", "203.0.113.10:27015:27015/tcp",
	"--publish", "203.0.113.10:27016:27016/tcp",
	"--publish", "203.0.113.10:2302:2302/udp",
	"--publish", "203.0.113.10:2303:2303/udp",
	"--env", "HOME_ID=42",
	"--env", "SERVER_MODE=container",
	"--entrypoint", "/entrypoint",
	"registry.example/gse/templates/dayz:2026.08.01",
	"--config", "/srv/app/config.json"
], "docker create argv is deterministic and fully structured");

$runner = FakeRunner->new();
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 1), stderr => "", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
my $already = $runtime->create(create_request());
is($already->{status}, "already_exists", "create is idempotent for owned existing containers");
is(scalar(@{$runner->calls}), 1, "idempotent create does not call docker create");

$runner = FakeRunner->new();
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 1, labels => { "gse.managed" => "true" }), stderr => "", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
my $conflict = $runtime->inspect({ target => create_request()->{target} });
ok(!$conflict->{success}, "inspect rejects matching name without ownership labels");
is($conflict->{error}{code}, "ownership_conflict", "ownership conflict is structured");

$runner = FakeRunner->new();
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 1), stderr => "", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
my $start = $runtime->start({ target => create_request()->{target} });
is($start->{status}, "already_running", "start is idempotent when already running");
is(scalar(@{$runner->calls}), 1, "already-running start does not call docker start");

$runner = FakeRunner->new();
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 1), stderr => "", timed_out => 0 });
$runner->enqueue({ exit_code => 0, stdout => "gse-h42-a9001\n", stderr => "", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
my $stop = $runtime->stop({ target => create_request()->{target}, timeout_seconds => 45 });
is($stop->{status}, "stopped", "stop executes for running container");
is_deeply($runner->calls->[1]{argv}, ["docker", "stop", "--time", "45", "gse-h42-a9001"], "stop argv includes bounded timeout");

$runner = FakeRunner->new();
$runner->enqueue(not_found_result());
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
$stop = $runtime->stop({ target => create_request()->{target}, allow_absent => 1 });
is($stop->{status}, "already_absent", "stop can be idempotent for absent container when requested");

$runner = FakeRunner->new();
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 1), stderr => "", timed_out => 0 });
$runner->enqueue({ exit_code => 0, stdout => "gse-h42-a9001\n", stderr => "", timed_out => 0 });
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 0, status => "exited"), stderr => "", timed_out => 0 });
$runner->enqueue({ exit_code => 0, stdout => "gse-h42-a9001\n", stderr => "", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
my $restart = $runtime->restart({ target => create_request()->{target}, timeout_seconds => 30 });
is($restart->{status}, "restarted", "restart maps through stop then start");
is_deeply($runner->calls->[1]{argv}, ["docker", "stop", "--time", "30", "gse-h42-a9001"], "restart stop argv is explicit");
is_deeply($runner->calls->[3]{argv}, ["docker", "start", "gse-h42-a9001"], "restart start argv is explicit");

$runner = FakeRunner->new();
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 1), stderr => "", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
my $delete = $runtime->delete({ target => create_request()->{target}, remove_volumes => 1 });
ok(!$delete->{success}, "delete refuses running containers");
is($delete->{error}{category}, "conflict", "running delete is a conflict");
is(scalar(@{$runner->calls}), 1, "running delete does not call docker rm");

$runner = FakeRunner->new();
$runner->enqueue({ exit_code => 0, stdout => inspect_json(running => 0, status => "exited"), stderr => "", timed_out => 0 });
$runner->enqueue({ exit_code => 0, stdout => "gse-h42-a9001\n", stderr => "", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, data_root => $data_root);
$delete = $runtime->delete({ target => create_request()->{target}, remove_volumes => 1 });
is($delete->{status}, "deleted", "delete removes stopped owned container");
is_deeply($runner->calls->[1]{argv}, ["docker", "rm", "--volumes", "gse-h42-a9001"], "delete argv is explicit and non-forced");

my $bad = create_request();
$bad->{payload}{image}{reference} = "repo/image;rm";
my ($bad_spec, $bad_error) = $models->validate_create_request($bad);
ok(!$bad_spec && $bad_error->{code} eq "invalid_image", "image validation rejects shell metacharacters");

$bad = create_request();
$bad->{payload}{command} = "sh -c unsafe";
($bad_spec, $bad_error) = $models->validate_create_request($bad);
ok(!$bad_spec && $bad_error->{code} eq "invalid_contract", "command validation requires argv array");

$bad = create_request();
$bad->{payload}{storage}{volumes}[0]{host_path} = File::Spec->catdir($repo_root, "outside");
($bad_spec, $bad_error) = $models->validate_create_request($bad);
ok(!$bad_spec && $bad_error->{code} eq "invalid_volume_path", "volume validation rejects paths outside data root");

$bad = create_request();
$bad->{payload}{ports}{publish}[0]{host_start} = 2400;
$bad->{payload}{ports}{publish}[0]{host_end} = 2401;
($bad_spec, $bad_error) = $models->validate_create_request($bad);
ok(!$bad_spec && $bad_error->{code} eq "invalid_port_block", "port validation rejects publishing outside assigned block");

$bad = create_request();
$bad->{payload}{environment}{"bad-key"} = "value";
($bad_spec, $bad_error) = $models->validate_create_request($bad);
ok(!$bad_spec && $bad_error->{code} eq "invalid_environment", "environment validation rejects unsafe keys");

$bad = create_request();
$bad->{payload}{ports}{publish}[0]{protocol} = "sctp";
($bad_spec, $bad_error) = $models->validate_create_request($bad);
ok(!$bad_spec && $bad_error->{code} eq "invalid_port_block", "port validation rejects unsupported protocols");

$bad = create_request();
$bad->{payload}{resources}{memory_mb} = 64;
($bad_spec, $bad_error) = $models->validate_create_request($bad);
ok(!$bad_spec && $bad_error->{code} eq "invalid_resource_limit", "resource validation rejects unsafe memory limits");

is(GSE::Container::Models->state_from_inspect({ State => { Running => JSON::PP::false, Status => "created" } }), "created", "created runtime state maps to created");
is(GSE::Container::Models->state_from_inspect({ State => { Running => JSON::PP::false, Status => "exited" } }), "stopped", "exited runtime state maps to stopped");

done_testing();
PERL
