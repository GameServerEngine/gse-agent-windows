# Changelog

Each fixed issue gets an entry under the version that shipped it: a one-line title, then the cause and the fix in plain language, written so a customer can follow it.

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
