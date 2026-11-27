# Task
Make the Windows update helper start the agent through its Windows service.

## User Request
"Fix the helper issues" (after the update of game3 left the GSE-Agent service Stopped while the agent was running).

## Problem
After a release update the GSE-Agent service showed Stopped while the agent ran, and the panel's restart (Restart-Service) could not restart it.

## Root Cause
agent_update_helper.sh had no service support at all: it takes --launcher and always ran nohup bash agent_launch.sh service. The agent did not pass a service name to it.

## Repositories Inspected
gse-agent-windows (changed). gse-agent-linux (read only, whose helper already started a systemd service when there is one).

## Files Read
AgentScripts/agent_update_helper.sh, AgentScripts/agent_core.pl (helper launch and the restart function's service name), agent_stop.bat, the helper log and update state on game3, game3's real sc.exe output.

## Files Changed
AgentScripts/agent_update_helper.sh, AgentScripts/agent_core.pl (passes --service-name), tests/validate_update_helper_service_start.sh (new), CHANGELOG.md, README.md, docs/AGENT_HOW_IT_WORKS.md, docs/TODO.md.

## Architecture Decisions
- The helper starts the service with sc.exe when it exists and is STOPPED. If the service says RUNNING with no agent it is stopped first. It falls back to the old direct start when there is no service, no sc.exe, the service is in another state, or sc start fails, so an update never ends with no agent.
- sc.exe is found by name, then under SYSTEMROOT through cygpath, because the helper may run with a short PATH.
- The agent passes the same validated service name its restart function uses (default GSE-Agent).
- Unlike Linux there is no supervisor that restarts the agent on Windows, so no hold is needed.
- The fix cannot protect the update that installs it: the helper that runs an update is the installed one.

## Validation Performed
tests/validate_update_helper_service_start.sh with a fake sc.exe whose state follows the agent process: service present (started through the service), no such service, sc start failing, no sc.exe, a service stuck at RUNNING with no agent, and an older agent that passes no name. All pass; against the old helper the service case fails (it does not know --service-name). The helper's real service_state function was run in game3's own Cygwin against the real sc.exe: GSE-Agent RUNNING, a missing service empty, GSE-PureFTPd RUNNING.
The test signals every process matching perl.*agent_core.pl, so it refuses to run where a real agent is visible and was run in a PID namespace.
The seven validators that already failed still fail in the same way; nothing else changed (validate_release_update_contract.sh checks an older update design that no longer exists).

## Git Commits
See git log on working in gse-agent-windows.

## Remaining Work
Install the build with the fix on game3 (item 36).
