# Task

Port rule, saved game PID, 5 minute hang timeout, two-attempt retry (agent 1.5.2).

## User Request

The agent must never start a game while its configured port is in use; kill the port owner and the game executable before launch; save the game PID; give a slow game 5 minutes before HUNG; two attempts then FAILED `Failed to Start: max restarts reached`; log every launch; tests; bump to 1.5.2.

## Problem

Launch did not check or free the port, did not save the real game PID, hung after 180s, and retried by crash count.

## Root Cause

GameManager only killed leftovers that matched the game exe name, adopted a game found by port, and had no attempt counter.

## Repositories Inspected

gse-agent-windows only.

## Files Read

AGENTS.md, AgentScripts/GameManager.pm, GameManagerWin.pm, agent_core.pl (gm(), universal_start), t/*.t, AgentScripts/tests/*.pl.

## Files Changed

AgentScripts/GameManager.pm, GameManagerWin.pm, agent_core.pl, Cfg/Config.pm.default, VERSION, tests, docs/TODO.md.

## Architecture Decisions

Port 0 or missing fails `port not configured`. A process under another server's folder is never killed. Stored PID is trusted first. Attempts counter is separate from the crash list.

## Validation Performed

See the final report: gamemanager_desired_state_test.pl 54/54; older failures listed in docs/TODO.md item 6.

## Git Commits

Repository: gse-agent-windows. Hashes are in the final report.

## Remaining Work

Verify on a Windows host. See docs/TODO.md.
