#!/usr/bin/env bash
# Mocked Docker tests for GSE/Container/Runtime.pm: no Docker daemon is used.
# Covers hardening flags, agent-resolved bind mounts, symlink and system-path rejection,
# image approval, ownership labels, config-change recreation and secret redaction.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module_dir="$repo_root"
[ -f "$repo_root/GSE/Container/Runtime.pm" ] || module_dir="$repo_root/AgentScripts"
[ -f "$module_dir/GSE/Container/Runtime.pm" ] || { echo "FAIL: missing GSE/Container/Runtime.pm" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/data/homes/42/data" "$tmp/agent/containers/homes/42" "$tmp/users/953/gamefiles" "$tmp/outside"
ln -s "$tmp/outside" "$tmp/users/953/linked"

perl -I "$module_dir" - "$tmp" <<'PERL'
use strict;
use warnings;
use Test::More;
use JSON::PP;
use GSE::Container::Runtime;

{
	package FakeRunner;
	sub new { return bless({ queue => [], calls => [] }, shift); }
	sub enqueue { my ($self, @r) = @_; push(@{$self->{queue}}, @r); }
	sub run
	{
		my ($self, $argv, $timeout) = @_;
		push(@{$self->{calls}}, [@$argv]);
		return shift(@{$self->{queue}}) || { exit_code => 0, stdout => "", stderr => "", timed_out => 0 };
	}
	sub calls { return $_[0]->{calls}; }
}

my ($tmp) = @ARGV;
my $target = { server_id => 1, home_id => 42, allocation_id => 9001, owner_user_id => 456 };
my $ok = { exit_code => 0, stdout => "", stderr => "", timed_out => 0 };
my $not_found = { exit_code => 1, stdout => "", stderr => "Error: No such object: gse-h42-a9001", timed_out => 0 };

sub request
{
	my (%over) = @_;
	return {
		contract => "gse.container.v1",
		target => { %$target },
		payload => {
			image => { reference => "eclipse-temurin:21-jre", digest => "sha256:" . ("a" x 64), pull_policy => "if_missing" },
			resources => { cpu_cores => 2, memory_mb => 2048 },
			ports => {
				ip => "203.0.113.10",
				assigned_blocks => [ { protocol => "tcp", host_start => 25565, host_end => 25570, container_start => 25565 } ],
				publish => [ { protocol => "tcp", host_start => 25565, host_end => 25565, container_start => 25565 } ]
			},
			environment => { RCON_PASSWORD => "hunter2" },
			%over
		}
	};
}

sub context
{
	my (%over) = @_;
	return {
		allowed_image_prefixes => ["eclipse-temurin:"],
		forbidden_roots => ["$tmp/agent"],
		run_as => { uid => 1953, gid => 1000 },
		workdir => "/game",
		entrypoint => "/bin/sh",
		command => ["/run/gse/launch.sh"],
		environment => { HOME => "/tmp" },
		mounts => [
			{ name => "gamefiles", host_path => "$tmp/users/953/gamefiles", container_path => "/game", mode => "rw" },
			{ name => "control", host_path => "$tmp/agent/containers/homes/42", container_path => "/run/gse", mode => "ro", allow_inside_agent => 1 }
		],
		%over
	};
}

sub inspect_json
{
	my (%a) = @_;
	my $labels = GSE::Container::Models->labels_for_target($target);
	$labels->{"gse.config_hash"} = $a{hash} if(defined($a{hash}));
	%$labels = (%$labels, %{$a{labels}}) if($a{labels});
	return { exit_code => 0, timed_out => 0, stderr => "", stdout => JSON::PP->new->encode({
		Id => "cid",
		Config => { Labels => $labels, Env => ["RCON_PASSWORD=hunter2"], Image => "eclipse-temurin:21-jre" },
		State => { Running => $a{running} ? JSON::PP::true : JSON::PP::false, Status => $a{running} ? "running" : "exited", ExitCode => 0 },
		HostConfig => { Memory => 2147483648 },
		Mounts => [ { Source => "$tmp/users/953/gamefiles" }, { Source => "$tmp/agent/containers/homes/42" } ]
	}) };
}

my $models = GSE::Container::Models->new(data_root => "$tmp/data");

# --- validation ---
my ($spec, $err) = $models->validate_create_request(request(), context());
ok($spec, "game-mode request validates") or diag(explain($err));
is($spec->{image}{resolved}, "eclipse-temurin:21-jre\@sha256:" . ("a" x 64), "image is pinned by digest");
is($spec->{resources}{memory_burst_mb}, 2048, "no swap by default (memory-swap equals memory)");
is($spec->{restart_policy}, "no", "Docker restart policy defaults to no (GSE watchdog owns restarts)");
is($spec->{labels}{"gse.agent"}, "linux", "platform label is linux on Linux") if($^O ne "cygwin");
ok(!JSON::PP::is_bool($spec->{resources}{storage_enforced}) || !$spec->{resources}{storage_enforced}, "storage limit is reported as not enforced");

my $runtime = GSE::Container::DockerRuntime->new(runner => FakeRunner->new(), models => $models, lock_dir => "$tmp/locks");
my $argv = join(" ", @{$runtime->build_create_argv($spec)});
like($argv, qr/--cap-drop ALL/, "all capabilities dropped");
like($argv, qr/--security-opt no-new-privileges:true/, "no-new-privileges set");
like($argv, qr/--pids-limit 512/, "pids limit set");
like($argv, qr/--memory 2048m --memory-swap 2048m/, "memory and swap limits set");
like($argv, qr/--read-only --tmpfs \/tmp:/, "read-only root with tmpfs");
like($argv, qr/--user 1953:1000/, "runs as the server's own user");
like($argv, qr/--init/, "init process for signal handling");
like($argv, qr/--network gse-games/, "isolated game network");
like($argv, qr/--log-opt max-size=10m --log-opt max-file=3/, "bounded logs");
like($argv, qr/--mount type=bind,source=\Q$tmp\E\/users\/953\/gamefiles,target=\/game( |$)/, "gamefiles bind mounted at /game");
like($argv, qr/target=\/run\/gse,readonly/, "control folder mounted read-only");
unlike($argv, qr/--volume|--privileged|--pid host|--network host|docker\.sock/, "no --volume, privileged, host namespaces or socket");
like($argv, qr/--publish 203\.0\.113\.10:25565:25565\/tcp/, "only the allocated port is published");

sub rejects
{
	my ($req, $ctx, $pattern, $name) = @_;
	my ($s, $e) = $models->validate_create_request($req, $ctx);
	ok(!$s && $e->{message} =~ $pattern, $name) or diag($s ? "accepted" : $e->{message});
}
rejects(request(), context(mounts => [ { name => "g", host_path => "$tmp/users/953/linked", container_path => "/game" } ]), qr/symlink/, "symlinked mount source rejected");
rejects(request(), context(mounts => [ { name => "g", host_path => "/etc", container_path => "/game" } ]), qr/protected/, "system folder rejected");
rejects(request(), context(mounts => [ { name => "g", host_path => "/", container_path => "/game" } ]), qr/protected/, "root folder rejected");
rejects(request(), context(mounts => [ { name => "g", host_path => "$tmp/agent", container_path => "/game" } ]), qr/agent folder/, "agent folder rejected");
rejects(request(), context(mounts => [ { name => "g", host_path => "$tmp/users/953/missing", container_path => "/game" } ]), qr/exist/, "missing source rejected (never auto-created)");
rejects(request(), context(mounts => [ { name => "g", host_path => "$tmp/users/953/gamefiles", container_path => "/../etc" } ]), qr/container_path/, "container path traversal rejected");
rejects(request(image => { reference => "evil/miner:latest" }), context(), qr/approved/, "unapproved image rejected");
rejects(request(), context(run_as => { uid => 0, gid => 0 }), qr/non-root/, "root user rejected");
rejects(request(ports => { ip => "203.0.113.10", assigned_blocks => [ { protocol => "tcp", host_start => 25565, host_end => 25565, container_start => 25565 } ],
	publish => [ { protocol => "tcp", host_start => 22, host_end => 22, container_start => 22 } ] }), context(), qr/outside the assigned/, "port outside allocation rejected");
rejects(request(environment => { BAD => "a\nb" }), context(), qr/newline/, "env value with newline rejected");

my ($legacy) = $models->validate_create_request(request(storage => { volumes => [ { name => "data", host_path => "$tmp/data/homes/42/data", container_path => "/data" } ] }), { allowed_image_prefixes => ["eclipse-temurin:"] });
ok($legacy, "legacy volume inside data root still accepted");
rejects(request(storage => { volumes => [ { name => "data", host_path => "$tmp/outside", container_path => "/data" } ] }), { allowed_image_prefixes => ["eclipse-temurin:"] }, qr/data root/, "legacy volume outside data root rejected");

# --- ownership ---
ok((GSE::Container::Models->verify_ownership($target, { %{GSE::Container::Models->labels_for_target($target)}, "gse.agent" => "windows" }))[0], "legacy gse.agent=windows label still accepted");
ok(!(GSE::Container::Models->verify_ownership($target, { %{GSE::Container::Models->labels_for_target($target)}, "gse.home_id" => "43" }))[0], "another home's container rejected");

# --- lifecycle with fake Docker ---
my $runner = FakeRunner->new();
$runner->enqueue($not_found, $ok, $ok, { %$ok, stdout => "newid\n" });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
my $r = $runtime->create(request(), context());
ok($r->{success} && $r->{status} eq "created", "create when absent") or diag(explain($r));
is($runner->calls->[1][1], "image", "image presence checked before create");
is($runner->calls->[2][1], "network", "network checked before create");
ok(!exists($r->{result}{argv}), "create result does not return the command line (secrets)");

$runner = FakeRunner->new();
$runner->enqueue(inspect_json(hash => $spec->{labels}{"gse.config_hash"}));
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
$r = $runtime->create(request(), context());
is($r->{status}, "already_exists", "same configuration is kept");
is(scalar(@{$runner->calls}), 1, "no docker create for an unchanged container");

$runner = FakeRunner->new();
$runner->enqueue(inspect_json(hash => "old"), $ok, $ok, $ok, { %$ok, stdout => "id2\n" });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
$r = $runtime->create({ %{request()}, recreate_if_changed => 1 }, context());
is($r->{status}, "recreated", "changed configuration recreates a stopped container");
is($runner->calls->[1][1], "rm", "old container removed first");

$runner = FakeRunner->new();
$runner->enqueue(inspect_json(hash => "old", running => 1));
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
$r = $runtime->create({ %{request()}, recreate_if_changed => 1 }, context());
is($r->{error}{code}, "config_changed", "running container is never recreated");

$runner = FakeRunner->new();
$runner->enqueue(inspect_json(hash => "x"));
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
$r = $runtime->inspect({ target => $target });
my $encoded = JSON::PP->new->allow_blessed->convert_blessed->encode($r);
unlike($encoded, qr/hunter2|RCON_PASSWORD/, "inspect result has no environment values");

$runner = FakeRunner->new();
$runner->enqueue(inspect_json(labels => { "gse.owner_user_id" => "999" }));
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
$r = $runtime->start({ target => $target });
is($r->{error}{code}, "ownership_conflict", "start refuses a container owned by someone else");

$runner = FakeRunner->new();
my $wrong = inspect_json();
$wrong->{stdout} =~ s{\Q$tmp\E/users/953/gamefiles}{/srv/other/gamefiles};
$runner->enqueue($wrong);
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
$r = $runtime->start({ target => $target }, context());
is($r->{error}{code}, "config_changed", "start refuses when mounts no longer match the server folder");

$runner = FakeRunner->new();
$runner->enqueue(inspect_json(), { exit_code => 1, stdout => "", stderr => "Cannot connect to the Docker daemon at unix:///var/run/docker.sock", timed_out => 0 });
$runtime = GSE::Container::DockerRuntime->new(runner => $runner, models => $models, lock_dir => "$tmp/locks");
$r = $runtime->start({ target => $target });
is($r->{error}{code}, "runtime_unavailable", "daemon down is reported as runtime_unavailable, not stopped");

like(GSE::Container::DockerRuntime::_safe_stderr("bad env RCON_PASSWORD=hunter2"), qr/RCON_PASSWORD=\*\*\*/, "secrets masked in diagnostics");

done_testing();
PERL
echo "Container runtime foundation validation passed."
