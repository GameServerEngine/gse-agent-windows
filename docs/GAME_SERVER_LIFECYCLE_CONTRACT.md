# GSE Game Server Lifecycle Contract

This document is the authoritative lifecycle contract for the simplified GSE
game-server runtime. It is written from the Windows agent inspection performed
on 2026-07-27 and is intended for the Windows implementation first, then the
Panel and Linux phases.

The contract is platform-neutral except where this file explicitly names
Windows/Cygwin process mechanics.

## Scope

In scope:

- Start, Stop, Force Stop, Restart, automatic startup replay, runtime status,
  watchdog supervision, optional bot supervision, and Server Content runtime
  boundaries.
- The new management-home and game-root layout.
- Compatibility readers needed to clean stale legacy artifacts.

Out of scope:

- Automatic migration of existing homes.
- Moving existing game payload folders.
- Changing Panel business decisions during the Windows-agent phase.
- Editing reference material.

Operators will manually rearrange existing homes before enabling the new layout.

## Authoritative Layout

`management_home` is the server-ID directory assigned to one managed game
server. Example:

```text
<agent server root>/ServerFiles/<home_id>
```

`game_root` is a child directory under `management_home` named exactly from the
validated XML `game_key`:

```text
<management_home>/<validated game_key>
```

The `game_key` must be validated before path construction. It must be a single
path segment and must not contain traversal, slashes, backslashes, drive
prefixes, control characters, empty values, Windows reserved device names, or
any value that escapes `management_home`.

No GSP/GSE management artifact may be written beneath `game_root`. This
includes scripts, PID files, desired-state files, status files, watchdog files,
bot definition files, Server Content management directories, runtime metadata,
or lifecycle logs that exist only for agent control. User game files, game save
data, installed game payload, mods, Workshop payload, and content-module
payloads belong beneath `game_root` when their intended destination is the game
payload.

Current Windows implementation detail:

- Start treats the RPC `home_path` as `management_home`.
- Start requires a valid XML `game_key` and resolves `game_root` as
  `management_home/<game_key>`.
- Start rejects missing or unsafe `game_key` values instead of launching from
  `management_home`.
- Existing homes must be manually rearranged by the operator before Start is
  used with this contract. No automatic or manual migration tool is part of
  this phase.

Temporary compatibility:

- Current Panel install/update RPCs do not all send `game_key`. Where an RPC
  lacks `game_key`, the Windows agent logs a compatibility note and uses the
  supplied path as the payload root.
- When later Panel phases send `game_key` to install/update RPCs, Windows
  resolves the payload root through the same validation path used by Start.
- This compatibility does not apply to Start; Start is the enforcement point
  for the new lifecycle layout.

## Runtime Filenames

These files are owned by the new lifecycle contract and live in
`management_home`:

| File | Purpose |
| --- | --- |
| `serverStart.bat` | Windows watchdog batch regenerated on every Start. |
| `serverStart.sh` | Linux equivalent generated supervisor, when the Linux phase implements this contract. |
| `status.running` | Desired state: Panel/agent intend this home to be running. |
| `status.stopped` | Desired state: Panel/agent intend this home to be stopped. |
| `watchdog.pid` | Optional agent-written PID of the actual titled watchdog `cmd.exe` process when visible outside Cygwin screen. |
| `game.pid` | Legacy cleanup-only PID evidence. The active Windows game health signal is the configured game port. |
| `game.launch_ts` | Legacy cleanup-only launch timestamp evidence. |
| `bot.pid` | Legacy cleanup-only optional bot PID evidence. The active Windows BOT cleanup signal is the per-instance BOT supervisor command marker, matching `_alsoRun.cmd` executable/config command line, and only then the unique BOT window title as a fallback. |
| `_alsorun.cmd` | Optional compatibility BOT definition consumed directly by the generated Windows BAT when present. |
| `bot.def` | Legacy cleanup-only bot definition from the prior lifecycle phase. |
| `lifecycle.log` | Optional concise lifecycle diagnostics for crash-loop or hard-stop failures. |

These agent-root files remain outside `management_home` and are not game
payload:

| File or directory | Purpose |
| --- | --- |
| `AgentScripts/startups/<ip>-<port>` | Persistent automatic-start registration only. |
| `AgentScripts/runtime_status/pid-<home_id>.kv` | Legacy runtime PID metadata compatibility until later phases remove it. |
| `AgentScripts/screenlogs/screenlog.GSP_HOME_<home_id_9_digits>` | Screen log output. |

Exactly one desired-state marker may exist in `management_home` at a time:

- `status.running`
- `status.stopped`

Missing, duplicate, conflicting, unreadable, or invalid desired-state markers
must be treated as stopped and safe failure.

## Screen Naming

The managed game screen name remains:

```text
GSP_HOME_<home_id zero-padded to 9 digits>
```

For example, home ID `42` maps to:

```text
GSP_HOME_000000042
```

There must be at most one managed screen session for a home. A Start request
must remove stale sessions using this exact name before launching a new
watchdog. Stop, Force Stop, and Restart must target this exact name and must not
operate on unrelated screen sessions.

## Desired State

Desired state is intent only. It is not proof that a process exists or that a
port is listening.

State transitions:

| Operation | First desired-state write | Later desired-state write |
| --- | --- | --- |
| Start | `status.stopped` during preflight cleanup | Replace with only `status.running` immediately before launching the watchdog. |
| Stop | Replace with only `status.stopped` before killing anything | No later running marker may be written. |
| Force Stop | Replace with only `status.stopped` before killing anything | No later running marker may be written. |
| Restart | Stop transition first | Start transition only after verified hard stop succeeds. |
| Invalid marker state | Treat as stopped | Do not launch until Start explicitly rewrites state. |

The agent must update desired state atomically enough that readers never observe
both `status.running` and `status.stopped` as valid desired state.

## Actual State

Actual runtime state is proven from live evidence:

- the named screen session
- `watchdog.pid`
- the actual titled watchdog `cmd.exe` PID in runtime metadata
- the optional BOT supervisor command marker, matching `_alsoRun.cmd` process identity, and fallback window title
- the configured TCP-or-UDP game port
- legacy `game.pid` and optional `bot.pid` cleanup evidence
- safe TCP and UDP owner lookup for the assigned game port
- optional compatibility PID metadata from `runtime_status/pid-<home_id>.kv`

Status, Stop, Force Stop, and Restart must not trust desired-state markers as
proof of actual process state.

## Start Contract

Every Start request must regenerate the watchdog from current resolved inputs:

- executable
- startup arguments
- environment variables
- working directories
- assigned port
- user selections
- replace-text results
- optional `_alsorun.cmd` compatibility BOT definition

Start preflight order:

1. Validate `home_id`, `management_home`, `game_key`, and `game_root`.
2. Return already-running success without regenerating or launching when the
   expected named screen session already exists.
3. Write desired state as stopped.
4. Remove stale desired-state conflicts and stale runtime files that are safe to
   remove.
5. Kill the tracked `watchdog.pid` process tree if present.
6. Kill the tracked `bot.pid` process tree if present.
7. Kill the tracked `game.pid` process tree if present.
8. Terminate the exact managed screen session for this home if present.
9. Read legacy cleanup-only PID sources and terminate safe matching processes.
10. Resolve TCP and UDP owners of the anticipated assigned game port.
11. Kill safe matching port owners.
12. Refuse Start if a protected or ambiguous process owns the port.
13. Verify the screen is absent, tracked PIDs are gone, and TCP/UDP port owners
    are clear.
14. Regenerate `serverStart.bat` or platform equivalent in `management_home`.
15. Recheck the expected named screen before launch and return already-running
    success if a concurrent Start created it.
16. Write desired state as running.
17. Launch one watchdog directly inside one named screen session.
18. Verify that the expected named screen exists and remains alive after the
    bounded post-launch grace period.
19. Poll the unique watchdog window title only as optional metadata. Record the
    actual watchdog `cmd.exe` PID in `watchdog.pid` and runtime metadata when
    visible, but never fail Start or kill a healthy screen merely because the
    title lookup is empty.

Windows screen launch target:

```text
screen -d -m -t "GSP_HOME_<id>" -c <screenrc> -S GSP_HOME_<id> cmd.exe /c <management_home>\serverStart.bat
```

No extra generated screen-launch wrapper may be part of the active path.

Windows screen-survival root cause corrected on 2026-07-28:

- `universal_start_without_decrypt` already launched `cmd.exe /c
  serverStart.bat` inside the detached named Cygwin screen.
- It then treated `wait_for_watchdog_cmd_pid_without_decrypt` as fatal when the
  unique watchdog title could not be discovered by `tasklist`.
- A CMD hosted inside Cygwin screen does not reliably expose a normal Windows
  window title, so the agent killed the healthy screen, returned failure, and
  let Panel retries create multiple detached game/BOT process pairs.
- The corrected invariant is the named `GSP_HOME_<home_id>` screen surviving
  launch. The title-based `cmd.exe` PID is useful Stop metadata when available,
  but it is not Start success evidence.

## Watchdog Contract

The generated watchdog is short, deterministic, and readable from top to
bottom. It must use standard Windows BAT commands only and must not depend on
nested generated scripts, generated PowerShell programs, WMIC output files,
backup watchdog batches, BAT-created PID files, or duplicate PID authorities.

Loop behavior:

1. Start with `@echo off` and `setlocal EnableExtensions EnableDelayedExpansion`.
2. Determine `%INSTANCE%` from `%~dp0.` and derive unique
   `%INSTANCE%_watchdog`, `%INSTANCE%_bot`, and `%INSTANCE%_game` titles.
3. Set `STOP_FILE=%~dp0status.stopped` and delete an old marker only when the
   fresh main watchdog starts, never from BOT-supervisor mode.
4. Set generated `GAME_WORKDIR`, full `GAME_COMMAND`, relative
   `GAME_EXECUTABLE`, `GAME_OPTIONS`, and `GAME_PORT` values from the Panel
   request. `GAME_COMMAND` remains full-path evidence for validation and
   cleanup compatibility; `GAME_EXECUTABLE` is the pathless command used for
   launch after validation.
5. Set the watchdog console title.
6. If `%~dp0_alsorun.cmd` or legacy-cased `%~dp0_alsoRun.cmd` exists, parse
   `workdir`, `executable`, and `arguments` compatibility keys into
   `ALSO_WORKDIR`, `ALSO_COMMAND`, and `ALSO_OPTIONS`; enable BOT supervision
   only when workdir and command are usable.
7. At the top of every pass, go to shutdown when `status.stopped` exists.
8. Ensure at most one same-file BOT supervisor `cmd.exe` exists for the
   `GSE_BOT_SUPERVISOR_%INSTANCE%` command-line marker. The BOT supervisor is
   launched with `start "" /B` so it does not create a foreground console, uses
   WMIC command-line/executable matching for the configured BOT process, and
   restarts only that BOT while the game remains supervised. The supervised BEC
   launch also uses `start "" /B /D ... /WAIT` so it stays hidden while the BOT
   supervisor still blocks until BEC exits.
9. Change into `GAME_WORKDIR` with `cd /d`, then launch the game with
   `start /wait "%GAME_TITLE%" ... %GAME_EXECUTABLE% ...` so the screen-owned
   watchdog blocks until the safe relative executable launch returns. Optional
   Windows priority is normalized by the generator into one supported complete
   `START` switch such as `/normal`; the BAT appends that switch directly and
   must not prepend another slash.
10. After the blocking game launch returns, measure runtime with
    `wmic os get LocalDateTime /value`, retain exactly the first 14
    `YYYYMMDDhhmmss` characters, validate those characters as decimal digits,
    parse local hour/minute/second from that normalized timestamp, convert those
    values to seconds since midnight with leading-zero-safe arithmetic, and add
    86400 when a negative delta indicates midnight rollover. If WMIC is missing
    or the normalized timestamp is short or nonnumeric, log the precise
    lifecycle clock error, write `status.stopped`, perform instance cleanup, and
    exit rather than assuming either a rapid exit or a normal crash.
11. If the game ran less than 15 seconds, write `status.stopped`, log the rapid
    exit, perform instance cleanup, and exit rather than spawning copies.
12. After a normal exit or crash, wait 30 seconds using `ping -n 2 127.0.0.1`
    based waits before looping to a single relaunch pass.

The watchdog must not relaunch anything while desired state is stopped or
invalid.

Windows watchdog-supervision root cause corrected on 2026-07-28:

- Live kcwin evidence showed 8 `arma2oaserver.exe` and 10 `BEC.exe` processes
  while both panel hints and `status.stopped` markers said stopped.
- `tasklist /V` reported `N/A` for every Arma and BEC window title, so exact
  `WINDOWTITLE` matching was not valid process identity on that host.
- The previous generated BAT launched the game and BOT with detached `start`
  commands, polled the configured port in a 60-iteration loop, and used
  `timeout /T 1` inside a Cygwin-screen-hosted CMD. Detached children survived
  after the screen disappeared, and a subsequent pass or Panel retry could
  launch more Arma/BEC processes before the previous copies were cleaned up.
- The corrected invariant follows upstream OGP's Windows principle: screen owns
  one batch, the batch owns one blocking game launch, restart is considered
  only after that launch returns, rapid exits under 15 seconds stop the
  watchdog, and BOT supervision uses instance command-line/config identity
  rather than title-only detection.

Windows relative-launch root cause corrected on 2026-07-28:

- After the OGP-style blocking lifecycle was deployed, kcwin server 4 still
  exited immediately because the generated BAT launched Arma with the full
  quoted executable path and `start /D "%GAME_WORKDIR%"`.
- A controlled task under the same `gameserver` identity proved the upstream
  form works for this Arma binary: `cd /d` into the game directory first, then
  run `start /wait "<title>" <flags> arma2oaserver.exe ...`.
- The corrected invariant preserves the blocking `start /wait` lifecycle but
  derives a safe pathless game executable from the validated panel executable
  path, emits it as `GAME_EXECUTABLE`, changes into `GAME_WORKDIR`, and starts
  the relative executable instead of the full `GAME_COMMAND` path.

## Optional Bot Contract

At most one optional bot process is supervised by the main watchdog.

`_alsorun.cmd` lives in `management_home` when a compatibility BOT is configured
and contains resolved current values:

```text
workdir=<absolute working directory>
executable=<resolved executable or command>
arguments=<resolved arguments>
```

The optional bot is independent from the game process:

- Missing bot with healthy game: restart bot only.
- Missing game after a blocking launch returns with healthy bot: restart the
  game only after the controlled delay and crash-storm check.
- Stop/Force Stop/Restart: terminate the BOT supervisor marker, matching BOT
  process tree, and title fallback before final game-port verification.

No bot definition, bot PID, or bot management-only file may be placed beneath
`game_root`. The generated BAT does not create BOT PID files. The title remains
cosmetic and a cleanup fallback only; it is not the primary BOT-running test.

Production finding from 2026-07-28:

- The current affected server 5 and 6 generated BATs used valid `GTR`
  comparisons and contained no plain `gt` or HTML `&gt;` tokens.
- The foreground windows showing `'gt' is not recognized` were stale BOT
  supervisor/BEC consoles created by an earlier generated BAT, not the active
  Cygwin screen-owned watchdog console.
- Corrected instances must recycle those stale BOT supervisors only after the
  generated BAT launches the BOT supervisor and BEC with no-new-window
  background `start "" /B` semantics.

## Replacement Tokens

For compatibility with existing game XML, `{GSP_HOME_DIR}` and
`{GSP_HOME_DIR_WINDOWS}` continue to resolve to `game_root` in Windows Start
commands, pre-start commands, environment variables, and bot definitions.

The explicit management-home tokens for the next Panel/Linux phases are:

| Token | Meaning |
| --- | --- |
| `{GSP_MANAGEMENT_HOME_DIR}` | Cygwin/POSIX management-home path. |
| `{GSE_MANAGEMENT_HOME_DIR}` | Cygwin/POSIX management-home path. |
| `{GSP_MANAGEMENT_HOME_DIR_WINDOWS}` | Native Windows management-home path. |
| `{GSE_MANAGEMENT_HOME_DIR_WINDOWS}` | Native Windows management-home path. |

Panel XML and generated commands should use game-root tokens for game files,
configs, mods, missions, saves, and Workshop/content payload. They should use
management-home tokens only for agent-owned lifecycle files or management
runtime references.

## Hard Stop Contract

Stop and Force Stop must use one shared hard-stop implementation. Restart must
be exactly verified hard stop followed by fresh Start.

Hard-stop order:

1. Validate `home_id`, `management_home`, assigned IP, and assigned port.
2. Write desired state as stopped before killing anything.
3. Remove persistent automatic-start registration for `<ip>-<port>` when the
   operation means the server should not auto-start.
4. Wait briefly for the BAT shutdown path.
5. Kill the stored watchdog `cmd.exe` process tree with `taskkill /F /T /PID`.
6. Stop the exact named screen session after the watchdog tree is targeted.
7. Kill legacy `bot.pid` and `game.pid` process trees when present.
8. Read and clean compatibility PID sources.
9. Resolve TCP and UDP owners for the assigned game port with `netstat -ano`.
10. Kill every nonzero/non-System owner of the assigned game port while still
    refusing protected agent or system infrastructure.
11. Verify the BOT supervisor marker, matching `_alsoRun.cmd` process identity,
    and fallback BOT title are absent.
12. Verify the exact screen is absent.
13. Verify tracked PIDs are absent.
14. Verify no process owns the assigned TCP or UDP port.
15. Remove stale runtime PID/timestamp files only after verification proves the
    processes are gone.

Stop may try a configured graceful control-protocol stop before or during the
hard-stop flow only if it cannot race with watchdog relaunch and does not
weaken the required final verification. Force Stop skips graceful
control-protocol shutdown and performs hard stop directly.

## Protected Process Rules

The lifecycle must never kill:

- PID `0`
- PID `4` on Windows
- the running agent process
- the agent parent process tree
- process infrastructure required to keep the agent alive
- unrelated `screen`, Cygwin, service wrapper, shell, PowerShell, or system
  processes that cannot be attributed to this home
- any process whose executable path, command line, or owner cannot be safely
  associated with `management_home`, `game_root`, the optional bot definition,
  or the assigned port cleanup policy

If a protected agent or system process owns the assigned port, Start, Stop,
Force Stop, and Restart must return an actionable failure instead of killing it.
Ordinary nonzero/non-System owners of the assigned game port are treated as
stale server owners for this Windows lifecycle and are terminated.

## Port Owner Cleanup

The assigned game port is Panel-owned input. Agents must not invent ports or
hardcode game-specific port rules for lifecycle cleanup.

Both TCP and UDP ownership must be checked for the assigned port. On Windows,
the assigned game port is an instance cleanup boundary: every nonzero/non-System
owner is terminated unless it is protected agent or system infrastructure. This
matches the production failure where orphaned Arma processes held ports
2000/2200 while the screen and status markers said stopped.

Windows mechanics:

- Generated `serverStart.bat` and Stop cleanup use standard Windows commands:
  `wmic`, `netstat`, `start`, `ping`, and `taskkill`; `tasklist /V
  WINDOWTITLE` may remain only as a fallback cleanup signal.
- Use `taskkill /F /T /PID <pid>` for known PID-tree termination.
- Use one `netstat -ano` TCP-or-UDP owner pass for the configured game port.

## Panel And Linux Handoff

Next Panel phase:

1. Continue sending `home_path` as the server-ID `management_home`.
2. Send the validated XML `game_key` on Start and every install/update/content
   RPC that needs to resolve a game payload destination.
3. Build game executable, run directory, config, mod, mission, save, Workshop,
   and user-content paths relative to `game_root`.
4. Keep lifecycle and content-management artifacts in `management_home` or
   agent-root runtime directories.
5. Do not request, generate, or offer migration tooling for this contract.

Next Linux phase:

1. Apply the same `game_key` validator and containment check.
2. Treat Start `home_path` as `management_home` and resolve `game_root` beneath
   it.
3. Regenerate `serverStart.sh`, PID files, status markers, and
   `_gsp_content` only in `management_home`.
4. Resolve Steam, rsync, Workshop, config, mod, mission, and user-content
   payload operations beneath `game_root` when `game_key` is available.
5. Preserve the same compatibility boundary only for current RPCs that cannot
   yet include `game_key`.

## KCWin Smoke Test

Post-deployment validation on `kcwin` should be bounded to a disposable test
home and must not move customer data:

1. Manually arrange one test home as `<management_home>/<game_key>/`.
2. Start the test server from the Panel and verify `serverStart.bat`,
   `status.running`, `watchdog.pid`, `game.pid`, optional `bot.pid`,
   `_gsp_content/`, and `lifecycle.log` are absent from `game_root`.
3. Change a user option in the Panel, Start again, and confirm
   `serverStart.bat` was regenerated in `management_home`.
4. Bind the assigned TCP and UDP port from a process under the test home, then
   Start and verify preflight clears the safe stale owners before launch.
5. Bind the assigned port from a protected agent/system process and verify
   Start refuses with an actionable protected port-owner failure.
6. Stop and Force Stop from the Panel and verify the named screen, watchdog,
   game, bot, and assigned TCP/UDP owners are gone.
7. Terminate the screen manually and confirm status reports stopped/safe
   failure rather than relaunching while desired state is stopped.

## Status Contract

Runtime status must combine desired state and actual evidence:

- `Stopped`: desired stopped or invalid, no screen, no tracked process, no
  assigned port owner.
- `Starting`: desired running and watchdog/screen or process evidence exists,
  but required ports are not ready within the startup window.
- `Running`: desired running and expected process/port evidence is present.
- `Warning`: conflicting actual evidence exists, such as assigned port owner
  without a managed screen or tracked PID.
- `Failed`: desired running but verification fails after timeout or an
  ambiguous/protected owner blocks cleanup.

The Panel may continue to consume compatibility fields, but the future source
of truth is the verified actual evidence, not legacy screen-only checks or
desired-state markers alone.

## Error Responses

Implementations must keep existing XML-RPC names and return conventions during
the transition. Where structured responses are available, failures must include:

- `success => 0`
- stable `status` string
- human-actionable `message`
- `home_id`
- assigned `ip`
- assigned `port`
- remaining screen/process/port evidence when available

Required failure cases:

| Status | Meaning |
| --- | --- |
| `invalid_target` | Missing or invalid home ID, path, IP, port, or game key. |
| `protected_port_owner` | A protected process owns the assigned port. |
| `ambiguous_port_owner` | A process owns the assigned port but cannot be safely attributed to this home. |
| `cleanup_failed` | A targeted screen, PID, or port owner survived hard stop. |
| `generation_failed` | Watchdog generation failed. |
| `launch_failed` | The watchdog screen could not be launched or verified. |

Legacy scalar return values may remain for compatibility until the Panel phase
adopts structured lifecycle responses everywhere.

## Current Windows Implementation Map

Current code paths inspected in `AgentScripts/gse_agent.pl`:

| Concern | Current evidence |
| --- | --- |
| Startup and runtime dirs | `GAME_STARTUP_DIR` and `SERVER_RUNTIME_DIR` constants at lines 93-96. |
| Automatic startup replay | Startup directory read at lines 601-643; skips `status-` and `pid-` marker-like files. |
| Server Content runtime | `_gsp_content/hooks`, `_gsp_content/generated`, `_gsp_content/runtime`, and `server_content.pids` prepared and cleaned at lines 201-304. |
| Legacy `_alsoRun.pid` import | Root and one-level-below `_alsoRun.pid` files imported at lines 229-251. |
| Screen name | `create_screen_id` returns `GSP_<type>_<home_id>` zero-padded to 9 digits at lines 869-873. |
| Generic screen command | `create_screen_cmd` wraps commands in `screen -d -m ... -S <screen_id>` at lines 875-882. |
| Current generated watchdog | `create_screen_cmd_loop` generates `serverStart.bat` in `management_home`; the named screen directly owns `cmd.exe /c <management_home>\serverStart.bat`. |
| Current bot parser | Generated `serverStart.bat` reads management-home `_alsorun.cmd` or legacy `_alsoRun.cmd` directly, maps `workdir`, `executable`, and `arguments`, and supervises the BOT through a same-file BOT supervisor identified by a per-instance WMIC command-line marker plus normalized executable/config matching. The unique window title is fallback cleanup only. |
| Current game tracking | Generated `serverStart.bat` launches the game with blocking `start /wait`, measures runtime from the first 14 `YYYYMMDDhhmmss` characters of WMIC `LocalDateTime` after the launch returns, stops deterministically on missing/short/nonnumeric clock data, stops on rapid exits under 15 seconds, and waits 30 seconds before a normal restart pass. The assigned TCP/UDP game port remains cleanup and readiness evidence. |
| Current watchdog PID tracking | Start accepts the surviving named screen as success, then polls the unique `%INSTANCE%_watchdog` title only as optional metadata. When visible, the actual watchdog `cmd.exe` PID is stored in `watchdog.pid` and runtime metadata. |
| Home desired state | `status.running`/`status.stopped` helpers publish one marker in the management home and treat invalid marker state as stopped. |
| Legacy desired hint | `AgentScripts/startups/status-<home_id>` helpers remain compatibility readers/cleanup only; the active lifecycle no longer writes them. |
| Legacy PID metadata | `runtime_status/pid-<home_id>.kv` helpers at lines 1185-1235. |
| Current port PID lookup | `netstat -ano` TCP/UDP owner parsing supplies both runtime metadata and Stop verification. |
| Current home PID cleanup | Cleanup reads `watchdog.pid`, `bot.pid`, then `game.pid` and uses `taskkill /F /T /PID`. |
| Current tracked/port kill | Shared lifecycle helpers collect home PID files, compatibility PID metadata, and both TCP and UDP port owners, then kill tracked owners and every nonzero/non-System owner of the assigned game port before verification. Protected agent/system owners are refused. |
| Runtime status | `server_status_without_decrypt` combines screen, metadata PIDs, legacy hint, and port evidence at lines 1495-1624. |
| Start | `universal_start_without_decrypt` refuses duplicate launch while the expected screen exists, calls shared hard-stop preflight while desired state remains stopped, regenerates `serverStart.bat`, rechecks the screen before launch, writes `status.running`, launches the screen once, accepts the surviving named screen as success, records optional titled watchdog PID metadata when available, writes PID metadata, and writes the automatic-start flag. |
| Stop | `stop_server_without_decrypt` delegates to the shared hard-stop helper and returns success only after verification. |
| Verification | `verify_runtime_stop_complete_without_decrypt` checks the named screen, home PID files, compatibility PID metadata, BOT supervisor marker, matching `_alsoRun.cmd` process identity, fallback BOT title, and TCP/UDP assigned-port owners for up to 30 passes. |
| Force Stop | `force_stop_server_without_decrypt` delegates to the same hard-stop helper and returns a structured response including protected/ambiguous cleanup failures. |
| Restart | `restart_server_without_decrypt` calls verified stop, waits, then calls fresh Start without a separate process-management algorithm. |
| Workshop | `steam_workshop_without_decrypt` uses Panel-supplied content paths and generated temp scripts at lines 5151-5267. |

The original HEAD source at `f80cd0a` showed the older Windows watchdog
generated `_serverStart.bat` without a status guard or `watchdog.pid`, and home
PID cleanup only processed `bot.pid` then `game.pid`. The current dirty
worktree now replaces that active generator with `serverStart.bat`, keeps legacy
watchdog helpers as cleanup-only artifacts, and validates the direct screen-owned
watchdog contract with `tests/validate_windows_watchdog_stop_generation.sh`.

## Current Generated Management Artifacts

Current Windows lifecycle and related code can generate or consume these
management artifacts:

| Artifact | Current location | Contract status |
| --- | --- | --- |
| `_serverStart.bat` | Current working/home path during start | Stop generating; replace with `serverStart.bat` in `management_home`. |
| `watchdog.pid` | Home path | Agent-written actual watchdog `cmd.exe` PID in `management_home`. |
| `game.pid` | Home path | Legacy cleanup-only file in `management_home`; the generated BAT does not create it. |
| `bot.pid` | Home path | Legacy cleanup-only file in `management_home`; the generated BAT does not create it. |
| `_alsorun.cmd` | Management home | Active optional BOT compatibility input parsed directly by `serverStart.bat`. |
| `_alsoRun.cmd` | Former legacy casing/location | Compatibility cleanup/input artifact only; prefer `_alsorun.cmd` in `management_home`. |
| `_alsoRun.pid` | Home root or one level below | Compatibility cleanup reader only. |
| `_alsoRun.bat` | Legacy Linux cleanup/generation artifact | Compatibility cleanup only; do not generate. |
| `AgentScripts/startups/<ip>-<port>` | Agent root | Keep as automatic-start registration only. |
| `AgentScripts/startups/status-<home_id>` | Agent root | Legacy desired-state hint retained only for compatibility reads and cleanup; active lifecycle state uses home markers. |
| `AgentScripts/runtime_status/pid-<home_id>.kv` | Agent root | Compatibility cleanup/status reader only. |
| `_gsp_content/hooks` | Current home path | Move to `management_home/_gsp_content/hooks` when game-root split is implemented. |
| `_gsp_content/generated` | Current home path | Move to `management_home/_gsp_content/generated` when game-root split is implemented. |
| `_gsp_content/runtime/server_content.pids` | Current home path | Move to `management_home/_gsp_content/runtime/server_content.pids`; cleanup reader only for managed content PIDs. |
| `screenlogs/screenlog.GSP_HOME_<id>` | Agent root | Keep outside game payload. |
| `SERVER_STOPPED` / `Server_Stopped` | Legacy marker names | Do not generate or read as active lifecycle state. Cleanup may remove stale files only when safe. |
| `_gsp_wmic.out` | Legacy generated PID helper output | Do not generate. Cleanup may remove stale file only. |
| `_serverStartPid.ps1` | Legacy generated PowerShell helper | Do not generate. Cleanup may remove stale file only. |
| `_serverStartupdated.bat` | Legacy generated replacement batch | Do not generate. Cleanup may remove stale file only. |
| Backup watchdog batches | Legacy generated backups | Do not generate. Cleanup may remove stale files only. |

## Implementation Plan For Later Steps

1. Add shared lifecycle helpers for desired state, path validation, protected PID
   classification, port-owner lookup, and hard stop.
2. Make Start call hard stop as preflight while remaining in stopped desired
   state.
3. Replace `_serverStart.bat` generation with `serverStart.bat`.
4. Keep `_alsorun.cmd` as the direct compatibility BOT input until Panel/Server
   Content replaces it with a later explicit BOT contract.
5. Move all management artifacts out of `game_root` and into
   `management_home`.
6. Keep compatibility readers for old PID files, `_alsoRun.*`,
   `runtime_status/pid-<home_id>.kv`, old status hints, and obsolete generated
   watchdog helpers until cleanup no longer needs them.
7. Update Panel to pass `management_home` plus `game_key` as the authoritative
   payload boundary and stop treating `home_path` as the game payload root.
8. Update Linux to implement the same filenames, desired-state markers, hard
   stop order, and game-root split using Linux-native process mechanics.

Legacy files that can stop being generated immediately in the new active path:

- `_serverStart.bat`
- `_alsoRun.cmd`
- `_alsoRun.bat`
- `_gsp_wmic.out`
- `_serverStartPid.ps1`
- `_serverStartupdated.bat`
- backup watchdog batches
- `AgentScripts/startups/status-<home_id>`
- any `starting`, `stopping`, `SERVER_STOPPED`, or `Server_Stopped` marker

Temporary compatibility readers required for cleanup only:

- `_alsoRun.pid`
- `_alsoRun.cmd`
- old `watchdog.pid`, `bot.pid`, and `game.pid` in the former home location
- `AgentScripts/runtime_status/pid-<home_id>.kv`
- `AgentScripts/startups/status-<home_id>`
- obsolete generated watchdog helper files listed above

Compatibility readers must not recreate these legacy files or treat them as
primary desired state.
