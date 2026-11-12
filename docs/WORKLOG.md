# Work log

One entry per piece of work: a Goal written before the work, a Result written after.

## 2026-11-12 Status must follow reality (server 52 shown FAILED while its game was running)

### Goal
- Edit: `AgentScripts/GameManager.pm` (lock per server, `launched_at` stamped at Start, `_probe_pid` keeps looking when the saved PID is dead, a live game is adopted from any state, `set_desired` clears FAILED); add `AgentScripts/gse_ctl.pl`; the agent writes `startserver.bat` and `stopserver.bat` into each server folder; add `t/gamemanager_reality.t`; update docs.
- Why: on 2026-11-11 15:46 the panel Start made the agent launch the game twice in one second (a stale `launched_at` let the scheduler judge it HUNG while Start was still launching). The second copy died, the state became FAILED, and FAILED is never re-checked, so a healthy game showed as stopped for 14 hours. A game started by hand is also never adopted, and is killed as a zombie when an old PID is saved.
- Success: the panel request and the 30 second check can never act on one server at once; a live game with desired RUNNING always shows RUNNING; an admin can start and stop on the host with two short scripts and the status stays true; new tests pass and the old test results do not get worse.

### Result
- Done: GameManager.pm (per-server lock, launched_at stamped at Start, probe keeps looking when the saved PID is dead, live game adopted from any state, set_desired clears FAILED, start and stop scripts written); gse_ctl.pl; GameManagerWin.pm and agent_core.pl moved from wmic to PowerShell CIM (one shared process list per check); t/gamemanager_reality.t (35 checks, all pass).
- Checked: t/gamemanager.t and t/gamemanagerwin.t, AgentScripts/tests and tests/validate_*.sh give the same results as before the change (pre-existing failures unchanged, TODO 6). On kcwin, from a temp copy outside the agent folder: process list 1.15 s then cached, launch by script and by command worked, a missing exe gave ReturnValue 9, `perl -c` of agent_core.pl and gse_ctl.pl passed. Nothing deployed.
- Not verified: running as the GSPAgent service account; the effect on the WMI Performance Adapter entries in Task Manager; hung-but-alive games (TODO 11).
