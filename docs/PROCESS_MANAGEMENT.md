# GSE Windows Agent Process Management

Workspace reference: [`GSP-WORKSPACE.md`](../../GSP-WORKSPACE.md)

The Windows agent manages customer servers through the Cygwin runtime and the GSP Perl agent.

## Current model

- the repository root is the Cygwin root for the maintained launcher
- process state is tracked through the agent runtime and PID files
- configured port validation is handled by `server_status` in `AgentScripts/agent_core.pl`
- production startup and shutdown are handled by the Windows service
- foreground troubleshooting startup and shutdown are handled by the root batch scripts
- Windows-specific user and service assumptions belong here, not in the Panel

`Installer-Agent-Windows.ps1` is the owner of Windows service registration. It removes the known legacy `GSP Windows Agent` scheduled task when present, generates `AgentScripts/agent_service_wrapper.sh`, registers the service through bundled `bin/cygrunsrv.exe` as `/bin/bash /AgentScripts/agent_service_wrapper.sh`, sets Automatic startup, configures restart recovery actions, enables recovery on non-crash failures, and verifies those settings before installation or repair is considered successful. Startup validation polls service state for up to 180 seconds and records `sc`, `cygrunsrv`, service stdout/stderr, and agent log diagnostics when startup fails.

## Important files

- `agent_start.bat`
- `agent_stop.bat`
- `AgentScripts/agent_launch.sh`
- `AgentScripts/agent_core.pl`
- `AgentScripts/Cfg/`

## Rule

Keep startup and stop behavior visible and explicit. Failures should be reported in the same console when launched manually. Service start, stop, and restart must remain under Windows Services.

## Agent Instance Guard

Both service and foreground mode run `AgentScripts/agent_launch.sh` before starting Perl. The guard refuses startup when:

- the configured agent port is already listening
- a valid `agent_core.pid`, `agent_core_service.pid`, `agent_core_foreground.pid`, or legacy `agent_core_run.pid` points to a live process
- the exact main `key` config field is blank or still contains a placeholder value
- bundled Perl module preflight fails through `AgentScripts/perl_env.sh`
- `AgentScripts/agent_core.pl` fails Perl validation
- PureFTPd failures are logged as warnings and do not block agent RPC startup

Before Perl starts, the same launcher checks for a pending queued agent update. When `agent_auto_update=1`, it resolves release metadata or an explicit patch URL, verifies the patch SHA-256, extracts into a staging directory, applies complete changed/new files plus explicit deletions, validates Perl, shell, and release-manifest checksums, rolls back on apply or validation failure, records `completed`, `failed`, or `rolled_back`, and then starts the agent. When restart-time updates are disabled, the request remains `pending`.

`agent_stop.bat` calls the same guard in `stop-foreground` mode and only stops `agent_core_foreground.pid`. It must not stop the service instance. The batch files do not register, start, stop, repair, or recover the Windows service.

## Port validation

Detailed status validation design:

- [`WINDOWS_AGENT_PORT_VALIDATION.md`](WINDOWS_AGENT_PORT_VALIDATION.md)

## Lifecycle tracking

The Windows agent now tracks per-home runtime metadata under:

- `AgentScripts/runtime_status/pid-<home_id>.kv`

Tracked fields include PID/session information used to stop the right process reliably:

- `screen_pid`
- `windows_pid` (optional actual watchdog `cmd.exe` PID when the unique title is visible outside Cygwin screen)
- `game_pid`
- `ip`
- `port`

Server-owned content runtimes are tracked separately under each server home:

- `_game_content/hooks/`
- `_game_content/generated/`
- `_game_content/runtime/`
- `_game_content/runtime/server_content.pids`

The game server is actively supervised by the generated Windows batch through one blocking `start /wait` launch inside the named screen-owned `serverStart.bat`. The assigned game port remains the cleanup and readiness signal, and its owner may be mirrored as `game_pid` in `runtime_status/pid-<home_id>.kv` for compatibility. It must not be written to `server_content.pids`; that file is reserved for hook, sidecar, bot, watchdog, and generated content application PIDs owned by that server.

## Game-key payload boundary

The server-ID directory supplied by the Panel as `home_path` is the
`management_home`. Windows Start requires a validated XML `game_key` and
resolves the game payload root as:

```text
<management_home>/<game_key>
```

The validator rejects empty keys, traversal, separators, drive or stream
prefixes, control characters, trailing dot/space values, reserved Windows
device names, and any resolved path that escapes `management_home`.

Game executables, run directories, Steam/rsync payload, configs, mods, missions,
saves, Workshop payload, and user content belong under `game_root`. Lifecycle
management files remain in `management_home`: `serverStart.bat`,
`status.running`, `status.stopped`, `watchdog.pid`, `game.pid`, `bot.pid`,
legacy cleanup-only `bot.def`, `game.launch_ts`, `lifecycle.log`, and
`_game_content/`.

No automatic or manual migration tooling is included in the Windows agent for
this layout. Operators manually rearrange existing homes before enabling it. Current install/update
RPCs that do not yet send `game_key` retain temporary compatibility by treating
the supplied path as the payload root; Start does not use that fallback.

## Per-home ACL isolation

Windows keeps game processes in the configured service account session. Unlike Linux, the verified OGP Windows source does not safely switch each game process to a generated per-home OS user, so GSP restores per-home isolation at the filesystem boundary.

The `windows_home_acl_isolation` preference defaults to `1`. When enabled, the agent repairs a game home before start, rsync update, and Steam update by:

- setting ownership for the configured service account
- disabling inherited ACLs on the game home
- granting full control only to the service account, SYSTEM, and local Administrators
- removing broad grants for Everyone, Authenticated Users, built-in Users, and Guests
- applying Cygwin mode `700`

Set `windows_home_acl_isolation => '0'` only for legacy hosts that depend on inherited home ACLs. That mode keeps OGP-compatible service-account and Administrators grants with Cygwin mode `775`.

## Desired State And Hard Stop

The active Windows lifecycle writes desired state in the management home with
exactly one marker file:

- `status.running`
- `status.stopped`

Missing, duplicate, conflicting, or unreadable marker state is treated as
stopped. These files are desired state only; process existence is still proven
from the named screen session, home PID files, compatibility PID metadata, and
TCP/UDP owner checks for the assigned game port.

Stop, Force Stop, Restart, and Start preflight all use
`lifecycle_hard_stop_without_decrypt` in `AgentScripts/agent_core.pl`. The shared
operation:

1. writes `status.stopped` before killing anything
2. removes the persistent startup flag for `<ip>-<port>` when the operation is
   Stop or Force Stop
3. waits briefly for the generated BAT shutdown path to clean the optional BOT
   supervisor/process identity and configured game port
4. terminates `watchdog.pid`, `bot.pid`, then `game.pid` trees from the
   management home with `taskkill /F /T /PID`
5. cleans server-owned content PIDs and imports legacy `_alsoRun.pid` entries
   for cleanup only
6. terminates compatibility runtime metadata PIDs when they are still safely
   attributable to the selected home
7. resolves both TCP and UDP owners of the assigned game port with `netstat -ano`
8. kills every nonzero/non-System owner of the assigned game port while still
   refusing protected agent or system infrastructure
9. terminates the exact `GAME_HOME_<home_id>` screen session
10. verifies the BOT supervisor marker, matching `_alsoRun.cmd` process
    identity, fallback BOT title, screen, tracked PIDs, and both TCP and UDP
    ownership checks show the assigned port is clear
11. removes stale `watchdog.pid`, `bot.pid`, `game.pid`, `game.launch_ts`,
    `serverStart.bat`, `bot.def`, obsolete generated watchdog helpers,
    `runtime_status/pid-<home_id>.kv`, and legacy `startups/status-<home_id>`
    only after verification succeeds

The agent no longer creates or reads `SERVER_STOPPED`/`Server_Stopped` marker files for lifecycle control.
Legacy `AgentScripts/startups/status-<home_id>` files are compatibility cleanup
artifacts only and are no longer required by the active Start, Stop, Force Stop,
or Restart control path.

Every Windows Start first refuses to relaunch while the exact `GAME_HOME_<home_id>` screen already exists. A fresh Start regenerates `<management_home>/serverStart.bat` and launches one named screen that directly owns `cmd.exe /c <management_home>\serverStart.bat`. The successful Start invariant is that this expected named screen session exists and remains alive after the bounded post-launch grace period. The batch watchdog derives unique `%INSTANCE%_watchdog`, `%INSTANCE%_bot`, and `%INSTANCE%_game` titles plus a `BOT_SUPERVISOR_%INSTANCE%` command-line marker from the containing folder. It deletes any stale `status.stopped` marker at fresh start, checks `status.stopped` before every game or BOT launch path, starts the optional `_alsorun.cmd`/`_alsoRun.cmd` BOT through a same-file BOT supervisor only when its `workdir`/`executable` compatibility values are usable, launches both the BOT supervisor and BEC with `start "" /B` so they do not create foreground consoles, and supervises the game through one visible blocking `start /wait` launch.

The game launch remains attached to the screen-owned batch with `start /wait`, so the watchdog can restart only after the game process exits. Before each game launch, the batch changes into `GAME_WORKDIR` with `cd /d` and starts the validated relative `GAME_EXECUTABLE` basename instead of the full `GAME_COMMAND` path; `GAME_COMMAND` remains present as full-path evidence for validation and cleanup compatibility. The batch measures runtime from `wmic os get LocalDateTime /value`, normalizes that value to exactly the first 14 `YYYYMMDDhhmmss` digits before validation, converts the parsed local hour/minute/second to seconds since midnight with leading-zero-safe arithmetic, and adds 86400 when the calculated delta crosses midnight. If WMIC is missing or the normalized timestamp is short or nonnumeric, the batch logs the precise lifecycle clock error, writes `status.stopped`, and exits through shutdown cleanup instead of treating the run as a rapid exit or normal crash. If the game exits in less than 15 seconds, the batch writes `status.stopped`, logs a crash-storm note, cleans the instance BOT and assigned port, and exits instead of spawning copies. A normal exit after the minimum runtime waits 30 seconds with `ping`, not `timeout`, before one relaunch pass.

The agent records the actual titled watchdog `cmd.exe` PID after launch in `watchdog.pid` and `runtime_status/pid-<home_id>.kv` only when that title is visible to `tasklist`. A CMD hosted inside a detached Cygwin screen may not expose a normal Windows window title, so missing watchdog PID metadata is nonfatal and must not kill a healthy screen. Stop writes `status.stopped`, waits briefly so the readable BAT can run its shutdown path, then uses the stored watchdog PID only as optional additional cleanup. The screen/session tree, BOT supervisor command marker, direct `_alsoRun.cmd` executable/config identity, fallback BOT title cleanup, and assigned TCP-or-UDP game port cleanup are the authoritative cleanup signals. The BAT shutdown path terminates the instance BOT supervisor tree, any matching BOT process tree, every nonzero/non-System TCP or UDP PID using the configured game port, waits 60 seconds with `ping` for the agent to terminate the watchdog tree, and exits. Production evidence on 2026-07-28 showed the visible stale consoles with `'gt' is not recognized` were old BOT supervisor/BEC windows; the current watchdog screen-owned BATs used valid `GTR` comparisons, so stale BOT consoles are removed through the normal corrected instance recycle rather than by changing watchdog screen ownership.

Legacy `_alsoRun.bat` and `_alsoRun.pid` are cleanup-only compatibility artifacts. The active optional BOT input is `_alsorun.cmd` in the management home, parsed directly by `serverStart.bat` for `workdir`, `executable`, and `arguments`.

Force Stop follows the same shared hard-stop cleanup order as normal stop, but it skips control-protocol shutdown attempts and always targets only the selected home/IP/port. It removes the startup flag, cleans server-content and legacy helper PIDs, kills tracked main PIDs and safe TCP/UDP port owners, verifies shutdown, and does not restart the server.

## Restart behavior

Restart remains stop-first and has no independent process-management algorithm:

- verified hard stop is attempted first through the normal stop path
- waits 60 seconds
- fresh Start is called only after the hard stop has already verified that the
  previous screen, tracked processes, and assigned TCP/UDP port owners are gone
- Start then performs its own preflight hard stop while staying in stopped
  desired state before writing `status.running` and launching the watchdog
