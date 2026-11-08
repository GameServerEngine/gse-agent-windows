# Windows Agent Operations Guide

## Purpose

The Windows agent bundles Cygwin, Perl, GNU Screen, and helper scripts so GameServer Engine (GSE) can manage Windows Server 2019/2022 game hosts. It exposes the same RPC surface as the Linux agent and expects the same shared key.

## Requirements

- Windows Server 2019 or 2022
- Administrator privileges for installation and service registration
- Reliable network access to the Panel on the configured agent port, default TCP 12679
- Outbound HTTPS for Panel callbacks and release artifact download when using online install or repair mode
- A complete extracted release ZIP when using offline install or repair mode

## SteamCMD Bootstrap

The Windows release payload bundles the SteamCMD bootstrap at `AgentScripts/steamcmd/steamcmd.exe`. Startup does not run SteamCMD and does not require internet access. Non-Steam servers can start, stop, update through non-Steam methods, and report status without SteamCMD.

Steam-specific server installs, Steam updates, and Steam Workshop jobs validate `AgentScripts/steamcmd/steamcmd.exe` when the operation starts. SteamCMD may self-update and then download Steam content, so those operations can require outbound internet even though agent install, repair, reconfigure, and startup do not.

Install and repair preserve the installed `AgentScripts/steamcmd` directory, including `steamapps` and runtime state. If the existing directory is present but missing only the bundled `steamcmd.exe`, repair from a complete payload restores the bootstrap without deleting local SteamCMD state.

## Installation Workflow

On a clean Windows host, run the CMD bootstrap as Administrator:

Download the published bootstrap from:

```text
https://git.runlevelsystems.com/GSE/Agent-Windows/releases/download/installer/Installer-Agent-Windows.cmd
```

Then run it from an elevated Command Prompt:

```bat
Installer-Agent-Windows.cmd
```

The CMD bootstrap elevates when needed, prompts for the install directory with a default of `C:\GSE\Agent`, asks whether to use the online current development archive, an offline local payload, or reconfigure the existing installed version when no explicit source mode was supplied. Online install or repair downloads exactly one release ZIP with `curl.exe`, extracts the payload, and hands off to the source PowerShell installer with `-PayloadSourcePath`. Reconfigure mode validates the installed agent entry points and can use a supplied or current extracted payload manifest for installed-file validation, without download, extraction, source prompting, or payload staging. Neither installer initializes, fetches, checks out, resets, or requires Git.

Use `/ReleaseZipUrl` when testing a specific release or private artifact host. The bootstrap still downloads exactly one ZIP from that URL.

Offline mode is explicit and never falls back online. Use it with a complete extracted release ZIP:

```bat
Installer-Agent-Windows.cmd /Offline /SourcePath "D:\Install Media\Agent-Windows" /InstallPath "C:\GSE\Agent"
Installer-Agent-Windows.cmd /Offline /SourcePath "D:\Install Media\Agent-Windows"
```

The source must contain `AgentScripts/install_payload_manifest.txt` and every file listed in it. That manifest covers the PowerShell installer, bundled runtime executables, service wrapper/startup files, config templates, `AgentScripts/perl_env.sh`, the SteamCMD bootstrap, and the agent entrypoint. The CMD bootstrap validates the local source before handing it to PowerShell. The PowerShell installer rejects incomplete sources, sources under the destination, and destination paths under the source because those layouts would be unsafe or recursive. `.git` metadata is not copied into the installed destination.

If `Installer-Agent-Windows.cmd` is run from the root of a complete extracted payload and no explicit mode was supplied, interactive mode offers that directory as the offline source. The PowerShell installer can also run directly when the payload is already present in the target install directory:

```powershell
.\Installer-Agent-Windows.ps1 -InstallPath "C:\GSE\Agent"
```

You can also run from an elevated PowerShell session when the repository is already present:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Installer-Agent-Windows.ps1
```

The installer:

- downloads one release ZIP for online clean installs and repairs
- validates and activates the staged source payload in install/repair mode
- migrates legacy `GSP` application state into `AgentScripts`
- verifies the bundled repository-root Cygwin runtime
- creates or updates the configured Windows service account
- prompts for OGP-compatible agent settings
- writes `AgentScripts/Cfg/Config.pm`, `AgentScripts/Cfg/Preferences.pm`, and `AgentScripts/Cfg/bash_prefs.cfg`
- validates `AgentScripts/gse_agent.pl` with bundled Cygwin Perl
- registers the `GSPAgent` Windows service through bundled `cygrunsrv.exe`
- removes the known legacy `GSP Windows Agent` scheduled task when present
- sets and verifies Automatic startup, Windows service recovery restart actions, and non-crash failure recovery
- starts the service

## Repair, Reconfigure, Uninstall

```powershell
.\Installer-Agent-Windows.ps1 -Mode Repair
.\Installer-Agent-Windows.ps1 -Mode Reconfigure
.\Installer-Agent-Windows.ps1 -Mode Uninstall
```

Online repair through the CMD bootstrap refreshes the installed release payload from one release ZIP and verifies bundled runtime executables while preserving local config and runtime/customer state. Offline repair or upgrade through the CMD bootstrap activates the validated local payload while preserving configuration, server files, schedules, homes, logs, backups, runtime state, update state, and local credential databases. Direct PowerShell repair operates on the existing installed payload; direct PowerShell reconfigure may use `-PayloadSourcePath` as the validation manifest source without copying payload files. Operations that need missing local files fail instead of going online. Reconfigure rewrites config and service registration. Uninstall removes the service and leaves files in place by default.

During install, repair, and reconfigure, the PowerShell installer resets inherited ACLs only on `AgentScripts\agent_launch.sh`, `AgentScripts\perl_env.sh`, and `AgentScripts\gse_agent.pl`, normalizes those managed scripts to LF line endings, and leaves customer-owned configuration, homes, server files, logs, backups, schedules, and runtime state untouched. Those scripts are interpreter-invoked through Bash and Perl, so the installer and restart-time update validator do not need to mutate executable bits for them.

## Foreground Troubleshooting

Production service lifecycle is managed through Windows Services.

For interactive troubleshooting only:

```bat
agent_start.bat
agent_stop.bat
```

`agent_start.bat` runs the agent in the current desktop session so game consoles launched by that foreground agent can be visible. `agent_stop.bat` stops only that foreground agent and never stops the Windows service.

## Production And Debug Workflows

Production hosts should run the agent through the registered Windows service:

```powershell
Get-Service GSPAgent
Restart-Service GSPAgent
```

Service registration, Automatic startup, and service recovery are owned by `Installer-Agent-Windows.ps1`. The service starts `/bin/bash /AgentScripts/agent_service_wrapper.sh` through bundled `cygrunsrv.exe`; the generated wrapper then runs `/bin/bash /AgentScripts/agent_launch.sh service`. The installer verifies Automatic startup and restart recovery settings after registration; a repair or install fails if Windows does not report the expected service behavior.

Foreground mode is only for interactive debugging:

```bat
agent_start.bat
agent_stop.bat
```

`agent_start.bat` calls `AgentScripts/agent_launch.sh foreground`; `agent_stop.bat` calls `AgentScripts/agent_launch.sh stop-foreground`. The batch files do not start, stop, restart, register, or repair the Windows service, and the service path does not manage foreground sessions.

## Restart-Time Updates

The running Windows agent records `agent_self_update` requests as pending state only. It writes `AgentScripts/gsp_agent_update_request.json` and `AgentScripts/gsp_agent_update_state.json`; it does not replace its own files.

On service startup or foreground `agent_start.bat`, `AgentScripts/agent_launch.sh` checks `agent_auto_update` in `AgentScripts/Cfg/bash_prefs.cfg`. When enabled and a pending request exists, the launcher resolves release metadata or uses the explicit patch URL, verifies the patch SHA-256, extracts the patch into a staging directory, applies complete changed/new files plus explicit deletions, validates Perl, shell, and release-manifest checksums, rolls back on apply or validation failure, records `completed`, `failed`, or `rolled_back`, and then starts Perl.

If restart-time updates are disabled, the request remains `pending`. Terminal failure states remove the pending request so the same failed update does not repeat on every service restart.

## Duplicate Startup Protection

Both service and foreground startup run `AgentScripts/agent_launch.sh`. Startup fails before launching Perl when:

- the configured agent port is already listening
- `gsp_agent.pid`, `gsp_agent_service.pid`, `gsp_agent_foreground.pid`, or legacy `gsp_agent_run.pid` contains a live PID
- the exact main `key` field in `Config.pm` is blank or still contains a placeholder value
- `AgentScripts/gse_agent.pl` fails Perl validation

## Logging And Troubleshooting

- Main log: `/AgentScripts/gsp_agent.log`
- Service stdout: `/AgentScripts/gse_agent_service.out.log`
- Service stderr: `/AgentScripts/gse_agent_service.err.log`
- Foreground PID: `/AgentScripts/gsp_agent_foreground.pid`
- Service PID: `/AgentScripts/gsp_agent_service.pid`
- Perl daemon PID: `/AgentScripts/gsp_agent.pid`
- Server readiness uses the `server_status` RPC and validates only ports supplied by the Panel.
- Port validation settings live in `/AgentScripts/Cfg/Preferences.pm`.
- Port validation smoke test: `bash /AgentScripts/tests/port_validation_smoke.sh 2302/udp 2303/udp`.

Authentication errors usually mean the `key` in `AgentScripts/Cfg/Config.pm` does not match the value stored in the Panel remote-server record.
