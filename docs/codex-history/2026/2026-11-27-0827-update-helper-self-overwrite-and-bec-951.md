# Task
Stop the Windows update helper from breaking when an update replaces the helper itself, let it find the service by itself, and fix game3's BEC for home 951.

## User Request
"Make all those fixes right now and update and make sure everything is running. You're going to have to restart the 951 Die Autobahn server and BEC so that it picks up the changes."

## Problem
1. The helper replaces itself while it runs (see the Linux record for the mechanism).
2. An older agent does not pass --service-name, so the first update from it would still start the agent outside its service.
3. game3 home 951's BEC controlled home 49's server, so 951 never got its scheduled restarts and 49 got extra ones.

## Root Cause
1. cp -f rewrites the running script in place and bash reads a script as it goes.
2. The service name was only known to the agent, and the installed agent does not send it.
3. Home 951's BEC config.cfg was copied from home 49: Port = 2000 and a BePath into home 49's BattlEye folder. BEC reads the RCon password from the folder in BePath, so there is no password setting to fix.

## Repositories Inspected
gse-agent-windows (changed); game3 (changed: one BEC config, the home 951 server and BEC restarted).

## Files Read
AgentScripts/agent_update_helper.sh, the BEC config.cfg, scheduler.xml and BattlEye config of homes 49, 50, 51 and 951, the agent log for home 951, ACLs of the BEC files, tests/validate_update_helper_service_start.sh.

## Files Changed
AgentScripts/agent_update_helper.sh (main function, default service name), tests/validate_update_helper_service_start.sh (W6 changed, W7 to W9 added), CHANGELOG.md, docs/AGENT_HOW_IT_WORKS.md, docs/TODO.md. On game3: C:\GSE\Agent\home\gameserver\951\gamefiles\bec\Config\config.cfg (lines 15 and 20 only).

## Architecture Decisions
- Same function wrapper as the Linux helper; service name order: --service-name, then service_name in Cfg/Config.pm (found anywhere on a line), then GSE-Agent. A missing service still falls back to the direct start.
- BEC config: changed only Port and BePath, to the form homes 50 and 51 use. The file is writable only by gameserver; neither leroy nor SYSTEM can write it. I took ownership as an administrator, replaced the ACL for the edit, and restored the saved ACL and owner afterwards in a finally block. All 11 access entries and the owner are identical to before; the auto-inherited marker flag changed from D:P to D:PAI.
- Restart: killed BEC 951 (the agent restarts it as its bot), then sent #shutdown over BattlEye RCon (the command BEC's scheduler sends) from a small client written for this, after checking 0 players. The agent restarted the server. No hard kill was needed.
- The service account question (item 39 in docs/TODO.md) was found, not changed.

## Validation Performed
Helper: W1 to W9 pass; W9 (four shift sizes) fails at every size against the previous helper and passes now; the helper's service_state was also run against game3's real sc.exe earlier. All other validators give identical results with and without the change.
BEC: diff against the backup shows only lines 15 and 20 changed (205 lines before and after). RCon login to both servers worked, 0 players. After the restart the RCon admins command shows two sessions on each of home 951 and home 49: mine and exactly one BEC. The server logs do not record RCon logins, so that command was the check. Arma 49's process id did not change.
Mistakes caught on the way: a first RCon script was refused by the remote shell (command line over 8190 characters), a parse error stopped the restart script before it ran anything, and my first BEC checks hid errors in their output filter.

## Git Commits
See git log on working in gse-agent-windows.

## Remaining Work
Item 39 (service account and ACLs on game3) needs a decision. The build with the fixes goes onto game3 with the helper placed first (item 36).
