# Task
Find out why game3's agent cannot write most of home 951's files, and make game home permissions work when the agent runs as SYSTEM, for existing and new installs.

## User Request
"I dont know what I am supposed to decide ... lets just fix what needs fixed and make it work and be deployed correctly in a new install. Better do some research."

## Problem
After the service was switched to LocalSystem, a write test as SYSTEM showed 0 of 11 start scripts, 0 of 3 BEC files, 146 of 150 sampled files in home 951 and every server.cfg could not be written.

## Root Cause
take_ownership (agent_core.pl) runs before every panel-initiated start. It ran takeown /U, which Windows only accepts with /S, so it never took ownership, and icacls /inheritance:r ... /T, which removes the inherited entries from every file so that only the owner can repair them. It worked only while the agent was the owner (gameserver). Homes 49 to 52 had been reset in that time; home 951 was created by a copy with Cygwin-style ACLs and never repaired. The installer allows LocalSystem, so a new install was affected as well.

## Repositories Inspected
gse-agent-windows (changed); game3 (homes repaired).

## Files Read
agent_core.pl (take_ownership, its callers, the constants), Installer-Agent-Windows.ps1 (account handling), Cfg/Preferences.pm, the agent log, ACLs of the homes and of the BEC folder.

## Files Changed
AgentScripts/GSE/HomeAcl.pm (new), AgentScripts/agent_core.pl (take_ownership now asks the module), tests/home_acl_test.pl (new), docs/WINDOWS_HOME_PERMISSIONS.md (new), CHANGELOG.md, docs/TODO.md.

## Architecture Decisions
- Commands: takeown /F /R /A /D Y; icacls /reset /T once; grant by SID (SYSTEM, Administrators) plus the agent's account and any account that already has full control, on the home folder only; remove inheritance and the broad groups on the home folder only. The files inherit the folder's entries.
- The logic is in a module that builds and reads text so it can be tested without Windows; plan_for_home reads the home's current entries with icacls.
- Rejected: a configured account list (the carry-over needs no configuration), skipping the recursive reset when the root looks right (files copied in by Cygwin tools drift), and leaving the routine as it was and changing the service account back (the installer supports LocalSystem and needs the fix anyway).
- Known property: any account with full control is kept, including a stray one (TODO 41).

## Validation Performed
On game3 as SYSTEM: the old order locks SYSTEM out of plain scratch files; the new order does not; home 951's real bec folder went from 13 of 33 writable to 32 of 33 (the other held open). Whole homes repaired in 3 to 5 s each; 0 ACCESS DENIED across about 5400 probed files, the rest writable or held open by the running games (sharing violations); server.cfg now reports in use instead of denied. The installed take_ownership was extracted verbatim and run under Cygwin perl as SYSTEM on an empty folder, in str mode too. All validators give the same results as before; tests/home_acl_test.pl passes.
Mistakes: my replicas never reproduced the blocked state (so the real folder was the proof); a robocopy filter copied the whole cfg folder, secrets included, into the admin-only backup folder and an early return skipped the cleanup (deleted, with other leftovers, and verified); early probes hid errors in an output filter.

## Git Commits
working 1c9d2af1 (fix), merged into testing as 7e0e512c, release testing-1.8.4 (bump 84d53c86); a documentation commit follows.

## Remaining Work
TODO 40 (a panel start end to end) and 41 (new-install FTP account). testing is a documentation commit behind working.
