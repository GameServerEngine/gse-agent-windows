# TODO

Open work for this repo. Types: todo, issue, goal, need. One row per item; never delete rows.

| ID | Type | Item | Status | Owner | GitLab |
| --- | --- | --- | --- | --- | --- |
| 1 | todo | Port rule, game PID, 5 minute hang timeout and 2-attempt retry in GameManager.pm (1.5.2) | done | Claude | |
| 2 | todo | Verify 1.5.2 start/stop/hang behaviour on a Windows host: netstat owner lookup, taskkill /T of launcher and game, wmic exe path and child lookup | todo | | |
| 3 | issue | Port-owner rule: "kill whatever owns the port" and "never kill a process from another folder" conflict. Implemented: a process whose exe is under ANOTHER server's folder (sibling of this home folder) is never killed and fails the start; every other owner is killed. Confirm with the user. | todo | | |
| 4 | need | Hang diagnostics: dialog text is a hook (`dialog_text`) with no Windows implementation yet; log tail reads last-start.txt only | todo | | |
| 5 | issue | HUNG has no panel screen: panel_status_for maps it to STARTING. Add a HUNG screen in the Panel if wanted | todo | | |
| 6 | issue | t/gamemanager.t dies at `tick_bot` (method no longer exists) and fails 7 older tests; t/lifecycle.t needs ServerLifecycle.pm which is missing; gamemanager_bot_test.pl fails 2. All fail before 1.5.2 too | todo | | |
| 7 | issue | AGENT_VERSION in agent_core.pl is read from release_version.txt or Cfg Config version (no literal in code). 1.5.2 is set in VERSION and Cfg/Config.pm.default | todo | | |
| 8 | need | RUNNING health check does not require the port owner to be the saved PID (only the STARTING to RUNNING step does) | todo | | |
| todo | Write docs/AGENT_HOW_IT_WORKS.md from the code (launch via WMI, adopt on start, port cleanup risk, PowerShell rule) and link it from CLAUDE.md. | done | Claude | |
| 9 | issue | Server 52 showed FAILED while its game ran; two launches at once (stale launched_at, no lock between Panel Start and the check); hand-started games not adopted. Fixed in 1.5.3 (lock, launched_at, adopt, set_desired clears FAILED, startserver.bat and stopserver.bat). Needs a live check on a Windows host | doing | Claude | |
| 10 | todo | Replace wmic with PowerShell CIM (process list, launch, memory, disk) in 1.5.3. Check on kcwin as the GSPAgent service account (not only as an admin) and count wmiApSrv.exe churn before and after | doing | Claude | |
| 11 | issue | Hung but alive games (pid and port up, game frozen) are not detected: the check only looks at pid and port | todo | | |
| 12 | need | Legacy generated BAT watchdog code in agent_core.pl (wmic loops in the bot supervisor, asserted by tests/validate_windows_watchdog_stop_generation.sh and tests/validate_kcwin_wmic_pipe_artifact.sh) looks unused; remove it with its tests or port it off wmic | todo | | |
| 13 | need | Panel: show "agent not checking" when the state file `updated_at` is older than about 3 minutes, instead of a stale RUNNING | todo | | |
| 14 | issue | Nine tests/validate_*.sh scripts fail on the untouched code too (layout, container rpc, default archive, game key payload, kcwin wmic artifact, offline installer, release update, screen cmd path, watchdog stop generation); same nine before and after 1.5.3 | todo | | |
