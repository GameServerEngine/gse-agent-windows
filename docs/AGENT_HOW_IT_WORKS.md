# How the GSE Windows Agent Works (read before touching the agent or a running server)

This page records behavior verified in the code (AgentScripts/GameManager.pm,
AgentScripts/agent_launch.sh) and in docs/GAME_SERVER_LIFECYCLE_CONTRACT.md.
Where something is not verified, it says so. Do not assume the opposite of what is written here.

## 1. What runs where

- The production agent is the Windows service `GSPAgent`. It runs the Perl agent
  (`AgentScripts/agent_core.pl`) through `AgentScripts/agent_launch.sh`.
- Start and stop of the service belong to Windows Services. `agent_stop.bat` only
  stops the foreground instance (`agent_core_foreground.pid`). It must not stop the service.
- The Panel is authoritative. It sends commands (start, stop, restart, status); the agent executes them.

## 2. Game servers are NOT children of the agent

- The agent launches a game by asking Windows (WMI create, via the `launch` callback)
  to start a `cmd.exe` launcher that runs the server's `serverStart.bat`. The launcher
  is created by WMI, so its parent is not the agent process.
- The game executable is a child of that launcher, or it is found by port owner or by
  executable path in the server folder (`_find_live_pid`, `_probe_pid`).
- Consequence: stopping or restarting the agent service does not, by design, stop running
  game servers. Other servers and games may survive an agent restart.
- Do not assume a game's parent is the agent when checking for it. Check by executable
  name, by the listening port, and by the saved PID in the home state file.

## 3. Per-server state (the home state file)

Each managed server has a state file with these fields: `status`, `pid`, `port`,
`crashes`, `reason`, `command`, `workdir`, `desired`, `launcher`, `updated_at`.

- `desired` is `RUNNING` or `STOPPED`. Panel Start sets it to RUNNING; Panel Stop sets
  it to STOPPED (`start()`, `stop()`, `set_desired()`). The state file is only an intent plus
  a record: what is running is decided by the real process and port on every check.
- Start, Stop, Set desired and the 30 second check (and the bot check) each take the server's
  lock (`status.lock` in the server folder) before changing anything, so they never overlap.
  The check skips a server that is busy and sees the result on the next pass.
- `status` is the observed state (STOPPED, STARTING, RUNNING, FAILED, ...).
- `launcher` is the PID of the cmd.exe that was launched. `pid` is the game's own PID,
  saved once the game is found. Use `pid` and `port` together to check a server.

## 4. Starting a server

1. The port must be configured and greater than zero. Never start a game with port 0 or an unset port.
2. Before launching, the agent frees the assigned game port (`_free_port`). Every
   nonzero, non-System owner of that TCP or UDP port is killed. The game executable
   for that home is killed too.
3. The launch goes through the cmd.exe launcher. The agent records `launcher` and
   then waits for the game (STARTING state).
4. A start that does not come up within the timeout is treated as hung. The agent
   kills and retries. After the attempts run out, the state is FAILED with a reason,
   and a Failed to Start crash ticket is opened from the Panel side.

## 5. Watchdog and status

- A game that is really up (a live process holding its port) while `desired` is RUNNING is
  adopted as RUNNING, whatever the state file says (FAILED, STOPPED, CRASHED). It is never
  killed or launched a second time. A saved PID that has died does not hide it: the game is
  looked for by port and by folder.
- On the host an admin uses `startserver.bat` and `stopserver.bat` in the server folder. They
  call `AgentScripts\gse_ctl.pl`, which only records RUNNING or STOPPED and waits for the agent
  to confirm; the agent's check then launches, adopts or stops the game and keeps the status
  file and the bot right. Closing or killing the game by hand while RUNNING is wanted gets it
  restarted: use `stopserver.bat`. `serverStart.bat` is the agent's own launcher, not for hand use.

- A periodic check (`tick()`) runs on the agent's scheduler and reads each home's
  state. The cadence is reported as every 30 seconds; confirm in the scheduler code
  before relying on the exact number.
- A home with `desired` RUNNING whose game has exited is restarted. Restarts are
  counted in `crashes`. Too many crashes give FAILED with "restart limit reached".

## 6. Agent start (including after a service restart)

`agent_start_recover()` runs for each home:

- If `desired` is STOPPED, it leaves the home alone.
- If the saved PID is alive AND the port is listening AND state is RUNNING, it adopts
  the server and leaves it running.
- Otherwise it calls `start()` for that home. That start frees the port first.

WARNING: because of step 4, a home whose state is wrong (for example desired RUNNING
but not adopted) will kill another running server that owns its port. Check the
state files and running processes before restarting the service.

## 7. Protected processes (never kill)

- PID 0 and PID 4 (Windows System).
- The running agent process and its parent tree.
- Process infrastructure needed to keep the agent alive.
- Any process that cannot be attributed to this home, its game root, its bot, or the assigned port.

If a protected process owns the assigned port, Start, Stop, and Restart return an
error instead of killing it.

## 8. Updates

- The agent does not replace its own files while running. `agent_self_update` records
  a pending request in `AgentScripts/agent_core_update_request.json`.
- `agent_launch.sh` applies the pending update before Perl starts. Service and foreground
  both do this.
- `AgentScripts/agent_update_helper.sh` waits for the agent to exit, checks the SHA-256,
  keeps one backup of the install being replaced, copies new files, starts the agent,
  and rolls back if it does not stay up. Config and runtime data are preserved.
- Runtime git clone or pull updates are not supported.

## 9. Tooling rules

- PowerShell is allowed for the Windows agent and its deployment only so the Windows
  agent stays close to the Linux agent. Starting and managing game servers on Windows
  uses the command prompt (cmd): the game is started by `cmd.exe /c serverStart.bat`.
  PowerShell (CIM) is used only to read the process list (`GameManagerWin::process_table`,
  one call shared by all servers for a few seconds) and to create that cmd.exe process
  (`Win32_Process Create`, so the game is not a child of the agent service). wmic is no longer
  used; Windows 10 or Windows Server 2016 or newer is required.
- Use `taskkill /F /T /PID <pid>` for known PID-tree termination (per the lifecycle contract).
- Check game processes by executable name, by listening port (`netstat -ano`), and by
  saved PID. Do not check only one process name: the Arma 2 servers run as
  `arma2oaserver.exe` with BEC (`Bec.exe`) and `blnsvr.exe`, not as DayZ executables.

## 10. Known doc drift (fix before relying on these files)

- `docs/WINDOWS_OPERATIONS.md` still points at an unstable archive URL and a 0.1.0
  release, and `AGENTS.md` uses old workspace paths (`/home/dev/Projects/GSP`). Use this
  page and the code as the reference until those are corrected.
- `docs/GAME_SERVER_LIFECYCLE_CONTRACT.md` describes an earlier batch-file launch model in
  places. Read the code (`GameManager.pm`) for the current launch behavior.

## 11. Before any restart of the GSPAgent service on a live host

1. List all game processes by name and port, and the saved state file for each home.
2. Confirm which running servers have a matching state (PID alive, port listening).
3. Confirm no home with desired RUNNING would start on a port held by a running server.
4. Get the approval of the owner before restarting if any game server is running.
