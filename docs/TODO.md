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
