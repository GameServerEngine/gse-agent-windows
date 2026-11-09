# GSE Windows Agent Operations

## Release Host Connectivity

The Windows installer and repair flow use release artifacts, not deployed-agent Git synchronization.

The CMD bootstrap downloads exactly one online installer archive with `curl.exe` from:

```text
https://git.runlevelsystems.com/GSE/Agent-Windows/archive/unstable.zip
```

The bootstrap does not request release metadata, checksum sidecars, release base URLs, release versions, or any second network resource. It extracts the ZIP with PowerShell, then invokes the source PowerShell installer with `-PayloadSourcePath`. The PowerShell installer validates the source payload, preserves local/customer state, migrates legacy `GSP` application state into `AgentScripts`, activates the complete staged payload with rollback for failed activation, validates the installed payload, then performs configuration, service account setup, permissions, service registration, and service start.

For already installed hosts, bootstrap reconfigure mode does not download, extract, prompt for an offline source, or copy payload files. When run from a complete extracted payload or with `/SourcePath`, it uses that payload manifest to validate installed files before reconfiguring; otherwise it runs the installed `Installer-Agent-Windows.ps1` directly with `-Mode Reconfigure`.

The PowerShell installer repairs only the managed script file ACLs needed for launch, `AgentScripts\agent_launch.sh`, `AgentScripts\perl_env.sh`, `AgentScripts\agent_core.pl`, and the generated `AgentScripts\agent_service_wrapper.sh`, with `icacls /reset`, then normalizes those files to LF line endings. It must not recursively alter customer-owned homes, server files, configuration, schedules, backups, logs, or runtime state for this preparation step.

Startup normalization must preserve file identity and ACLs. On Windows/Cygwin, replacement-style edits such as `sed -i` can recreate a managed script or config path with new NTFS/Cygwin ACL metadata. Production evidence from `kcwin` showed that legacy startup normalization replaced `agent_core.pl`, leaving Cygwin mode `0600` and causing Windows error 126 when the file was directly executed. The maintained launcher therefore performs CRLF/CR cleanup by reading raw bytes, skipping unchanged files, and reopening the same path for raw truncating output instead of renaming or replacing the target.

The startup chain also keeps explicit Bash and Perl interpreters as defense in depth. Foreground startup runs bundled Bash and then `/bin/bash /AgentScripts/agent_launch.sh foreground`; service startup runs `/bin/bash /AgentScripts/agent_service_wrapper.sh`, which execs `/bin/bash /AgentScripts/agent_launch.sh service`; the launcher validates the bundled Perl environment and ends with `exec perl "$AGENT_FILE"`. The managed scripts do not depend on Cygwin executable bits or direct execution of the Perl source.

Online mode requires `curl.exe` on `PATH`. If `curl.exe` is unavailable, run offline mode with an extracted release payload.

Validate HTTPS connectivity on port 443 before installing or repairing:

```powershell
Test-NetConnection git.runlevelsystems.com -Port 443
```

For private hosting or pre-production validation, pass an explicit ZIP location:

```cmd
Installer-Agent-Windows.cmd /ReleaseZipUrl "https://example.invalid/gse-windows-agent-0.1.0.zip"
```

The installer must not edit the hosts file automatically and must not replace release URLs with IP addresses or non-HTTPS ports.

## Release Version

The release artifact version starts at semantic version `0.1.0`. This is not the same concept as the agent RPC protocol version `v1.4`.
