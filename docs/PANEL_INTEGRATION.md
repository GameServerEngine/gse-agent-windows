# GSE Windows Agent Panel Integration

Workspace reference: [`GSP-WORKSPACE.md`](../../GSP-WORKSPACE.md)

The Panel is authoritative. The Windows agent executes the work the Panel requests.

## Integration points

- shared key and RPC configuration live in `AgentScripts/Cfg/Config.pm`
- startup preferences live in `AgentScripts/Cfg/bash_prefs.cfg`
- the Panel talks to the same command surface as the Linux agent wherever practical
- game server readiness is reported through the existing `server_status` RPC, extended with expected/listening/missing port details

## Agent Update Integration

The Windows agent mirrors the Linux queued update contract:

- `agent_self_update(payload)` validates and records a pending update request in `AgentScripts/agent_core_update_request.json`
- `agent_update_status` returns `AgentScripts/agent_core_update_state.json`
- the running Perl agent does not replace its own files
- `AgentScripts/agent_launch.sh` applies a pending request before starting Perl in both service and foreground modes

The restart-time update keys in `AgentScripts/Cfg/bash_prefs.cfg` are:

- `agent_auto_update`
- `agent_update_metadata_url`
- `agent_update_patch_url`
- `agent_update_patch_sha256`
- `agent_update_source_version`
- `agent_update_target_version`
- `agent_update_manifest_url`
- `agent_update_manifest_sha256`

Queued updates use release metadata or a checksum-pinned cumulative patch ZIP. Runtime Git clone/fetch/reset updates are not supported.

The shared status values are `pending`, `running`, `completed`, `failed`, and `rolled_back`. Terminal failures remove the pending request so the service does not retry the same failed update on every restart.

## Compatibility rule

The Windows agent should mirror the Linux agent behaviorally as much as possible so the Panel can treat both platforms as one product family.

`ftp_mgr` uses Pure-FTPd-compatible virtual users on Windows, matching the Linux agent's default `PureFTPd` backend. The Panel command shape is unchanged; FileZilla Server-specific XML configuration is not required or supported.

Per-home Windows ACL isolation is agent-local execution behavior controlled by `AgentScripts/Cfg/Preferences.pm`. It does not change the Panel RPC shape.

## Legacy Workshop RPC

The dedicated Panel `steam_workshop` module still uses the legacy `steam_workshop` XML-RPC call.

Current compatibility rule:

- if the Panel sends a blank `config_file_path`, the Windows agent runs post-install logic only
- the generated script must skip all `cat` / regex / config-write logic in that case
- `WorkshopModsInfo` is still written so the Panel can list/uninstall installed items even when no game config file is edited
- new installs write per-home records under `WorkshopModsInfo/home_<home_id>/`
- each record stores mod string, Workshop item ID, title, installed folder/path, Workshop App ID, install status, and timestamps
- the generated job writes `<game_home>/WorkshopInstallStatus.json` as `running`, `completed`, or `failed`
- the generated job prints `WORKSHOP_INSTALL_COMPLETE` or `WORKSHOP_INSTALL_FAILED` so the Panel can avoid stale `Update in progress` displays if the generic update screen lingers

## Status validation

The Panel remains the source of truth for assigned ports. The Windows agent validates only the ports supplied by the Panel for a specific server.

Detailed design:

- [`WINDOWS_AGENT_PORT_VALIDATION.md`](WINDOWS_AGENT_PORT_VALIDATION.md)

## Agent Operations RPCs

The Windows agent exposes the same per-agent lifecycle operations as the Linux agent wherever practical:

- `force_stop_server(home_id, server_ip, server_port, home_path)` removes the matching startup flag, writes home-local `status.stopped`, cleans server-content and legacy helper PIDs through the shared hard-stop path, kills tracked Windows/game PIDs and safe TCP/UDP owners of the assigned game port, verifies session/process/port shutdown, and returns a structured result. It never restarts the game server.
- `agent_self_update(payload)` records a pending restart-time update request.
- `agent_update_status` returns the latest `AgentScripts/agent_core_update_state.json` content.
- `agent_version` returns OS, agent code build version, and install path.

## Container Capability RPCs

The Windows agent exposes an explicit container-native boundary for the
`gse.container.v1` migration contract:

- `container_capabilities`
- `container_create`
- `container_inspect`
- `container_start`
- `container_stop`
- `container_restart`
- `container_delete`

These methods are separate from legacy game-process lifecycle RPCs. Existing
Panel records must continue to call `universal_start`, `stop_server`,
`restart_server`, and `server_status` unless the Panel has explicitly marked a
record or allocation as container mode.

`container_capabilities` is readable while the runtime is disabled so the Panel
can detect installed support and decide whether a host is eligible for a live
proof of concept. Mutating container methods require
`container_runtime_enabled => '1'` in `AgentScripts/Cfg/Preferences.pm`; the
default template is disabled. The current implementation supports only the
Docker adapter and only create/inspect/start/stop/restart/delete. Logs,
console, files, backup/restore points, health monitoring, resource proof, and
port-overlap enforcement remain later migration phases documented in
[`CONTAINER_AGENT_MIGRATION_ROADMAP.md`](CONTAINER_AGENT_MIGRATION_ROADMAP.md).

Panel dependencies for later phases:

- add wrapper methods for `container_capabilities` and each enabled
  `container_*` RPC
- store a container mode switch or allocation type before invoking container
  lifecycle
- send the `gse.container.v1` JSON request body with target allocation ID,
  owner ID, idempotency key, assigned TCP/UDP blocks, resources, volumes, image
  metadata, and health policy
- keep legacy records on legacy RPCs until an explicit compatibility migration
  is approved

Generated Windows `serverStart.bat` watchdogs do not change the Panel command shape. The active control path uses the home-local `status.stopped` marker for shutdown intent, not `AgentScripts/startups/status-<home_id>` hints. The readable batch watchdog derives unique watchdog, BOT, and game titles plus a per-instance BOT supervisor command marker from the management-home folder, deletes a stale stop marker on a fresh Start, checks `status.stopped` before every BOT or game launch path, supervises the optional `_alsorun.cmd`/`_alsoRun.cmd` BOT by WMIC command-line/executable identity with a title fallback, changes into the generated game working directory, and supervises the game with one blocking `start /wait` launch of the relative executable basename.

Start returns success after the expected named Cygwin screen session survives the bounded post-launch grace period. It records the actual titled watchdog `cmd.exe` PID in runtime metadata only when that title is discoverable; missing title PID metadata is nonfatal for a CMD hosted inside screen. A second Start while the named screen exists is treated as already running and does not regenerate or relaunch the BAT. Stop writes `status.stopped`, waits briefly for the batch cleanup path, uses any stored watchdog PID as optional additional cleanup, terminates the named screen/session tree, kills the matching BOT supervisor/process tree, kills nonzero/non-System owners of the assigned game port, and verifies the BOT marker/process/title plus configured game port are clear.

The current Windows Start contract treats the Panel `home_path` argument as the
server-ID `management_home`, not the game payload root. Start requires the XML
`game_key`, validates it as one safe Windows path segment, and launches the game
from `<management_home>/<game_key>/<run_dir>`. Existing game XML tokens
`{GAME_HOME_DIR}` and `{GAME_HOME_DIR_WINDOWS}` still resolve to the game payload
root for compatibility. New Panel phases should use
`{MANAGEMENT_HOME_DIR}` or `{MANAGEMENT_HOME_DIR}` only when generated
commands intentionally reference lifecycle management files.

Install/update/content RPCs should send `game_key` in the next Panel phase so
the Windows agent can resolve payload destinations under `game_root`. Until
those RPCs are updated, Windows preserves temporary compatibility by treating
the supplied path as the payload root and logging that fallback. The agent does
not migrate existing homes. No automatic or manual migration tooling is part of
this contract; operators manually rearrange homes.

## Server Content Runtime

Windows now mirrors the Linux server-content runtime layout for server-owned sidecars, bots, hooks, and generated content helpers:

- `_game_content/hooks/`
- `_game_content/generated/`
- `_game_content/runtime/`
- `_game_content/runtime/server_content.pids`

Stop and restart clean this runtime before main game process escalation. The main server PID remains tracked through `runtime_status/pid-<home_id>.kv`; `server_content.pids` must only contain server-content watchdog/app PIDs.

Legacy `_alsoRun.bat` support remains compatibility-only. When `_alsoRun.pid` is present, the Windows agent imports those PIDs into the server-content cleanup path so Panel Start/Stop/Restart does not leave legacy helper processes behind.
