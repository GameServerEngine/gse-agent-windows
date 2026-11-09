# GSE Windows Agent Runtime

This directory contains the Perl agent and runtime files exposed inside Cygwin as `/AgentScripts`.

## Configuration

Production configuration lives under `Cfg/`:

- `Config.pm` contains the Panel shared key, listen address, listen port, protocol version, and Steam license preference.
- `Preferences.pm` contains agent behavior preferences such as log retention, FTP integration, autorestart, per-home ACL isolation, and port validation.
- `bash_prefs.cfg` contains launcher preferences such as restart-time update metadata and optional PureFTPd startup.

The tracked `.default` files are templates only. Production installs create local config files through `Installer-Agent-Windows.ps1`.

## Startup

Use the repository-root scripts:

- `agent_start.bat` starts a foreground troubleshooting agent in the current desktop session.
- `agent_stop.bat` stops only the foreground troubleshooting agent.
- Windows Services controls production service start, stop, and restart.

Both service and foreground paths run `AgentScripts/agent_launch.sh`, which validates configuration, refuses duplicate PID/lock state, refuses to start when the configured agent port is already in use, and checks `agent_core.pl` with Perl before launch.

Queued agent updates are applied in the same launcher before Perl starts. The running agent records `agent_self_update` requests as pending state only; service restarts and `agent_start.bat` foreground starts apply the pending request when `agent_auto_update=1`.

## Service Mode

Service mode is installed by:

```powershell
.\Installer-Agent-Windows.ps1
```

Repair, reconfigure, and uninstall use the same script with `-Mode Repair`, `-Mode Reconfigure`, or `-Mode Uninstall`.
