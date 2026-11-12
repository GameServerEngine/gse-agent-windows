# Changelog

Each fixed issue gets an entry under the version that shipped it: a one-line title, then the cause and the fix in plain language, written so a customer can follow it.

## 1.5.3
- **Status follows the real game:** A game that was running could show Stopped or Failed in the Panel (server 52 showed "Failed to Start: max restarts reached" while players were on it). The agent now takes over a game that is really up (its process holding its port) and wanted RUNNING, whatever the status file says. A saved process ID that has died no longer hides a game that is still running under another ID, so a game started by hand is no longer killed as a stray.
- **Agent restart no longer kills a live game:** When the agent started, a game that was really up but marked FAILED or STOPPED (wanted RUNNING) was started again, which first freed its port and killed it. The first pass after the agent starts now adopts a live game instead.
- **Scripts for games already running:** The check now writes `startserver.bat` and `stopserver.bat` for a server that was started before they existed, so no game restart is needed. `gse_ctl.pl` finds its modules from its own path, which Cygwin Perl got wrong.
- **One action at a time per server:** The Panel Start and the 30 second check ran in separate processes with no lock, so the check could judge a fresh start "hung" (it used an old launch time) and launch a second copy. Start, Stop, Set desired and the check now take a per-server lock, the launch time is stamped when Start begins, and a new Start clears FAILED.
- **Start and stop on the host:** Each server folder now gets `startserver.bat` and `stopserver.bat`. They only record RUNNING or STOPPED (through `gse_ctl.pl`) and wait for the agent to confirm, so an admin can start and stop a game on the host and the Panel shows the truth. A game closed by hand while RUNNING is wanted is still restarted; use `stopserver.bat`.
- **wmic replaced by PowerShell (CIM):** The process list, launching games and the memory and disk readings no longer use wmic, which is removed from new Windows. One process list is read per check and shared by all servers. Needs Windows 10 or Windows Server 2016 or newer.

## 1.5.2
- **Game port freed before launch:** A game still holding its port could block the next start. The agent now frees the port first and saves the game's process ID. Commit `8beb0e3c`.
- **Hang timeout set to 5 minutes:** The agent uses a 5 minute hang timeout for game processes. Commit `8beb0e3c`.
- **Windows agent docs:** Added a guide to how the agent starts, adopts running games on start, cleans up ports, and updates. Commit `b1760128`.
- **Release names:** Removed the old GSP, GSE and OGP prefixes from agent names. Commits `488b3bf9`, `87e7763c`.
- **Release workflow:** One rolling working build, and auto-versioned testing releases. Commits `413e41a1`, `8e2a3442`.

## 1.5.1
- **Crash limit:** A game that crashes 3 times within 30 minutes is stopped instead of restarted again. The crash delay is removed, so restarts begin right away. Commit `7411e66a`.
- **One update at a time:** The agent refuses a second update while one is running. Commit `07440589`.
- **Update reports its release:** The agent reports the release tag written by the update, not the old install config. Commit `15b8962d`.
- **Update helper fixes:** The helper finds agent processes correctly, clears stale PID files, keeps the staged release file, and stops the real agent process before a restore. Commits `43f087e8`, `98d02d07`, `45d6ed4a`, `d7609a78`.
