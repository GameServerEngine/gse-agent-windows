# Task

Wildcard log file support in get_log (agent_core.pl).

## User Request

get_log must accept `*`, `?`, `[ ]` in the game's console_log path, pick the newest matching regular file, stay inside the game home, return -8 when nothing matches, and leave plain paths unchanged.

## Problem

Needed to know what get_log did with wildcards.

## Root Cause

Support already existed (log_path_has_wildcards, wildcard_pattern_to_regex, resolve_latest_log_match; no match returns `-8;<encoded message>`). Gaps: `C:/...` patterns not rejected, glob was case-sensitive, glob characters in the home path were not escaped. No tests.

## Repositories Inspected

gse-agent-windows only.

## Files Read

AGENTS.md, docs/TODO.md, AgentScripts/agent_core.pl (get_log and helpers).

## Files Changed

AgentScripts/agent_core.pl, t/log_wildcard.t, docs/TODO.md.

## Architecture Decisions

No protocol change. The chosen file is logged only, as the response has no field for it.

## Validation Performed

prove t/log_wildcard.t: 13/13. agent_core.pl cannot be compiled on Linux (Windows/Cygwin modules missing), also true before the change.

## Git Commits

See the final report.

## Remaining Work

Live check on Windows (TODO 21).
