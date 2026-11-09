# GSE Windows Agent

The GSE Windows agent is the execution engine for GameServer Engine (GSE) on Windows hosts. It runs game servers, installs and updates them, and reports status to the panel. The repository root is the bundled Cygwin root and contains the agent runtime, startup scripts, installer and supporting files.

Status: the `working` branch is in development. Updated behaviour has been committed but not yet run on a real Windows host. Test on a real host before any live deployment.

## Features

**Runtime**
- Service mode is the default production mode. The Windows service runs the agent in the background through bundled Cygwin. Game servers launched by the service run in the service session.
- Foreground mode (`agent_start.bat`) is for interactive troubleshooting only, so Windows game consoles are visible. `agent_stop.bat` stops only the foreground agent.
- The launch guard (`AgentScripts/agent_launch.sh`) refuses to start when the configured port is already listening or a valid PID file shows another instance.
- Protocol version 1 is reported in `agent_version` and check-in responses, so the panel can confirm it can talk to this agent.

**Game manager**
- Game states, crash restarts with a restart limit, and bot lifecycle (bots start once the game is running and stop when it stops).
- Game launch options pass through to the game manager.
- Game keys are resolved from the game's own folder under the management home, with traversal, drive-prefix and reserved-name checks.

**Games and the agent**
- The agent starts, stops, monitors and restarts game server processes, and starts and stops their bots (for example BattlEye/BEC) when the game is running.
- Once a game server is started, it does not need the agent to keep running. The game process runs on its own.
- Stopping, restarting or updating the agent does not stop, restart or otherwise change running games or bots. While the agent is down, the games keep running but the panel cannot see or control them until the agent is back.
- When the agent starts again, it reads each game's status and resumes monitoring and bot management for it.

**Updates (on demand only)**
- The agent never updates at startup or restart. An update runs only when the panel asks for it.
- The panel sends the release archive URL, its SHA-256 checksum, the version and the protocol version. The agent refuses a URL that is not https, a checksum that is not 64 hex characters, and an invalid version.
- The agent downloads the archive to a staging folder, verifies the SHA-256 checksum, writes state, and starts `AgentScripts/agent_update_helper.sh` in the background.
- The helper waits for the agent to stop, re-checks the checksum, backs up the current install, copies the new files in and starts the agent again. If the new agent does not stay up, the helper restores the backup.
- Config, runtime data and customer state are preserved: `etc/`, `var/`, `startups/`, `Cfg/Preferences.pm`, `Cfg/bash_prefs.cfg`, the update state and request files, the update log, and the `agent_update_*` folders.
- Rollback keeps only the current install. The backup is the version that was running before the update, not a history.

**FTP**
- Bundled Cygwin Pure-FTPd, with one agent-managed account per game server. `ftp_mgr` manages the same `pure-pw` virtual-user layout used by the Linux agent.
- `agent_launch.sh` starts the bundled Pure-FTPd when FTP is configured.
- FileZilla Server is not supported. Legacy `ftp_method => 'FZ'` configuration is treated as Pure-FTPd.

**SteamCMD**
- Release payloads include an offline SteamCMD bootstrap at `AgentScripts/steamcmd/steamcmd.exe`.
- Agent startup does not run SteamCMD and does not need internet access. Non-Steam servers work without it.
- Steam installs, updates and Workshop operations need SteamCMD and its own network access.
- Install and repair keep an existing `AgentScripts/steamcmd` folder, including `steamapps` and runtime downloads.

## Important paths

| Path | Purpose |
| --- | --- |
| `bin/` | Bundled Cygwin runtime binaries |
| `AgentScripts/agent_core.pl` | Core Windows agent Perl service |
| `AgentScripts/agent_launch.sh` | Shared service and foreground launch guard |
| `AgentScripts/agent_update_helper.sh` | On-demand update helper: stop, verify, back up, copy, start, restore on failure |
| `AgentScripts/perl_env.sh` | Bundled Perl module search path and preflight |
| `AgentScripts/Cfg/` | Runtime configuration and templates |
| `agent_start.bat` | Foreground-only desktop-session launcher |
| `agent_stop.bat` | Foreground-only stop helper |
| `Installer-Agent-Windows.cmd` | The downloadable entry point. Elevates, resolves an online, offline or reconfigure payload source, then hands off to PowerShell. |
| `Installer-Agent-Windows.ps1` | Install, repair, reconfigure and uninstall logic, always run through the CMD bootstrap or directly once a payload is staged |
| `Install_Agent.bat` | Compatibility wrapper that forwards to `Installer-Agent-Windows.cmd` |
| `install_apache.sh` | Optional manual utility that registers Cygwin's Apache `httpd` as a service. Not part of the agent install. |

## Installation

Run the CMD bootstrap as Administrator on a clean host:

```bat
Installer-Agent-Windows.cmd
```

The bootstrap asks for the install directory (default `C:\GSE\Agent`) and whether to use an online archive, an offline payload, or reconfigure an existing install.

- **Online** needs `curl.exe` on `PATH`. It downloads one ZIP from the archive URL in the installer. For testing or private hosting, pass `/ReleaseZipUrl`.
- **Offline** uses an extracted release ZIP as the source. The source must include `Installer-Agent-Windows.cmd`, `Installer-Agent-Windows.ps1` and `AgentScripts/install_payload_manifest.txt`.

```bat
Installer-Agent-Windows.cmd /Offline /SourcePath "D:\Install Media\Agent-Windows" /InstallPath "C:\GSE\Agent"
```

Install and repair validate the source in a staging step, stop and remove the existing `GSPAgent` service before activation, preserve customer and runtime state, and move any existing `AgentScripts` folder aside. During install, repair and reconfigure, the installer resets inherited ACLs only on the managed script files.

Repair, reconfigure and uninstall work on an installed payload:

```powershell
.\Installer-Agent-Windows.ps1 -Mode Repair
.\Installer-Agent-Windows.ps1 -Mode Reconfigure
.\Installer-Agent-Windows.ps1 -Mode Uninstall
```

The installer is currently PowerShell. This is a known deviation from the preference to avoid PowerShell for agent deployment (see Planned work).

A Linux-runnable static check of the installer contract is at `tests/validate_offline_installer_contract.sh`.

## Planned work

From the feature backlog, grouped by area. Nothing here is a committed date.

**Testing and release**
- Run the on-demand update path on a real Windows host, starting with one agent, then roll out. Use the testing branch as the fallback if the working branch fails.
- Confirm the installer archive default and the update archive URL on the current git host (`git.isaserver.net/workspace/gse-agent-windows`).

**Installer**
- Remove the restart-time update question from the installer and its generated config.
- Move installer logic off PowerShell, as recorded in the deployment preference, using bash or wmic.

**Updates and protocols**
- Scheduled updates: panel issue #16.
- Protocol design for the panel-agent API and the version handshake: panel issue #17.
- Game query protocol updates: panel issue #19.

**FTP**
- Redeploy the Windows agent's `ftp_mgr` to the KCWin agent and test account management.
- Per-server Windows accounts (for example `server49`), so each game runs as its own user and cannot reach admin files. Needs a permissions design.

**Linux parity**
- The Linux agent (`gse-agent-linux`) still has the startup-update path and the `agent_auto_update` setting. Those are to be removed the same way.

## Known issues

- The installer still asks the restart-time update question, which no longer applies.
- `AgentScripts/agent_launch.sh` and `tests/validate_offline_installer_contract.sh` still refer to `AGENT_SKIP_AUTO_UPDATE`, from the removed startup-update path.
- The installer's default archive URL may still point at the old git host. Check before use.
- The Perl syntax of the agent has not been checked on a Windows host (the Cfg modules are missing in the Linux test environment).
- Nothing in this branch has been run on a real Windows host yet.

## Documentation

This README is the main document for the Windows agent. These deeper references are kept because the validation scripts read them:

- [`docs/GAME_SERVER_LIFECYCLE_CONTRACT.md`](docs/GAME_SERVER_LIFECYCLE_CONTRACT.md)
- [`docs/PROCESS_MANAGEMENT.md`](docs/PROCESS_MANAGEMENT.md)
- [`docs/PANEL_INTEGRATION.md`](docs/PANEL_INTEGRATION.md)
- [`docs/WINDOWS_OPERATIONS.md`](docs/WINDOWS_OPERATIONS.md)
- [`AgentScripts/README.md`](AgentScripts/README.md)
- [`AgentScripts/documentation/agent-guide.md`](AgentScripts/documentation/agent-guide.md)
