# Task: Verify and fix Admin Servers agent interface visibility

## Context

The previous Codex run partially implemented a new Admin -> Servers lightweight fleet overview and a dedicated per-agent interface page, but the run reported FAILED/FAILED. The user deployed/updated the Panel and shared a screenshot showing the Admin -> Servers page still appears like the old UI:

- title/header: CONFIGURED REMOTE HOST
- rows show ID#, Server Name, Agent Status
- buttons: Delete, Edit, Remote Server Reboot, Restart Agent, View Log
- no visible Manage Agent button
- no visible CPU/RAM/Disk/resource columns
- no visible Game Servers count column

The repo copy of `Panel/Panel/modules/server/servers.php` currently appears to have the new code, so investigate why the new UI may not be visible or usable and fix it.

## Goals

1. Verify the actual Panel server module routing and ensure the updated `servers.php` is the page shown for `?m=server`.
2. Ensure the main Admin -> Servers page visibly displays the new lightweight fleet overview:
   - ID
   - Agent name
   - address
   - online/offline status
   - OS/version
   - game server count
   - CPU/RAM/Disk/load resource summary
   - warning badges
   - prominent `[Manage Agent]` or button linking to the dedicated per-agent page
3. Ensure the dedicated per-agent page is reachable through the existing module loader, for example:
   - `?m=server&p=agent_interface&rhost_id=1`
4. Fix any missing module routing/subpage registration if needed.
5. Make it visually obvious when the new code is active. For example add a small heading or subtitle: `Agent Fleet Overview` and a `Manage Agent` button in each row.
6. Verify the page does not silently fall back to the old layout.

## Files to inspect

- `Panel/Panel/modules/server/module.php`
- `Panel/Panel/modules/server/servers.php`
- `Panel/Panel/modules/server/agent_interface.php`
- `Panel/Panel/modules/server/agent_helpers.php`
- Panel module loader/router files that decide which `p=` file to include
- Theme/template/CSS files if they transform table output
- Any duplicate server module files under `Panel/Panel/modules/server/`
- Do not modify `references/`

## Important checks

- Confirm `agent_interface.php` is discoverable through `?m=server&p=agent_interface`.
- Confirm no menu/module metadata prevents direct subpage loading.
- Confirm `servers.php` has no PHP fatal or helper include error that causes fallback/old render.
- Confirm `agent_helpers.php` include path is correct from the module runtime working directory.
- Confirm `getAgentResourceSnapshot`, `upsertAgentResourceSnapshot`, and `getGameHomesByRemoteServerId` are in the active DB class/interface where needed.
- Confirm the page does not call expensive snapshot polling for all agents on each load.
- Confirm no generated/cached module files need update.

## If the new UI cannot be made safe immediately

At minimum:

- Add a prominent `Manage Agent` button to the existing old-looking row layout.
- Add a dedicated `agent_interface.php` page reachable from that button.
- Add resource warning badges to the row using cached snapshots only.
- Keep old edit/delete/reboot/restart/log actions working.

## Validation required

Run available syntax checks:

- PHP lint for changed files, especially:
  - `Panel/Panel/modules/server/servers.php`
  - `Panel/Panel/modules/server/agent_interface.php`
  - `Panel/Panel/modules/server/agent_helpers.php`
  - `Panel/Panel/includes/lib_remote.php`
  - `Panel/Panel/includes/database_mysqli.php`

If runtime web testing is not available, add a short debug/deployment note explaining exactly which file/version should be present on production and what text should appear when active.

## Documentation / history

Create or update a codex history entry under:

`Panel/docs/codex-history/2026/`

Include:

- User report: production still looked like old Admin Servers page
- Root cause found
- Files changed
- Validation performed
- Deployment verification steps

## Final report must state

- process_status and verification_status from this run
- whether the main Servers page now visibly shows the new overview
- whether `Manage Agent` is present
- whether the dedicated per-agent page is routed/reachable
- any remaining deployment steps
