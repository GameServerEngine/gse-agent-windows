# Permissions of a game home on Windows

Every game server lives in a home folder (`C:\GSE\Agent\home\gameserver\<home id>`). The agent must be able to read and
write all of it (start scripts, configs, installs and updates, the file manager), and so must anything else that works in
the home, such as the FTP service. Nobody else should.

## Who gets access

| Account | Why |
| --- | --- |
| SYSTEM and the Administrators group | Given by SID, so it works whatever the service account is called. |
| The account the agent runs as | `SYSTEM` when the service uses LocalSystem, or the named account chosen in the installer. |
| Any account that already has full control of the home | For example the account the FTP service runs as (`gameserver` on game3). It keeps full control. |

With `windows_home_acl_isolation` on (the default, `Cfg/Preferences.pm`), Everyone, Authenticated Users, Users and Guests are
also removed from the home folder.

## What the agent does, and when

`take_ownership` in `agent_core.pl` runs before every panel-initiated start of a game and after installs. It asks
`GSE::HomeAcl::plan_for_home` for the commands and runs them:

1. `takeown /F <home> /R /A /D Y`: ownership goes to the Administrators group.
2. `icacls <home> /reset /T /C /Q`: every file and folder inherits from the home folder again. This removes odd entries,
   such as the Cygwin-style ones that files copied in by Cygwin tools carry.
3. `icacls <home> /grant:r` for SYSTEM, Administrators and the accounts above, with `(OI)(CI)F`, on the **home folder only**.
4. With isolation on: `icacls <home> /inheritance:r` and `/remove:g` for the broad groups, on the **home folder only**.

The files then inherit exactly the entries of the home folder.

## Why the order and the "home folder only" matter

Found on game3 on 2026-11-27, after the agent was switched from `gameserver` to LocalSystem. The old routine ran
`takeown /U <user>` and `icacls <home> /inheritance:r /grant:r <user>:(OI)(CI)F /T`:

* `takeown /U` is only valid together with `/S` (a remote computer), so it always failed ("Invalid syntax"). That went
  unnoticed while the agent was the owner of the files.
* `/inheritance:r` with `/T` removes the inherited entries from every file. Those were the only entries that gave the agent
  access, and the explicit grant did not replace them, so files ended up with no entries at all. The owner can repair
  that; any other account, including SYSTEM, cannot. Homes 49 to 52 were fine because they had been reset while the agent
  was `gameserver`; home 951 was created by a copy with Cygwin-style entries and was never repaired, so SYSTEM could not
  write 146 of 150 sampled files in it, nor any `server.cfg`.

On a new install with LocalSystem the old routine would have locked the agent out of every file of a home on the second start.

## Checking a home by hand

`icacls "<home>"` should list full control `(OI)(CI)(F)` for SYSTEM, Administrators and the FTP account, and nothing for Users
or Everyone. A file inside should list the same entries as inherited, `(I)(F)`.

To repair a home by hand, run the commands the agent would run, from a SYSTEM or administrator prompt:
`perl -I AgentScripts -MGSE::HomeAcl=plan_for_home -e 'print "$_\n" for plan_for_home(path => $ARGV[0], running_user => "SYSTEM", isolate => 1)' "<home>"`
prints them. Save the old entries first with `icacls "<home>" /save acls.txt /T /C`.

## Tests

`tests/home_acl_test.pl` (no Windows needed) covers the account detection, the exact commands and their order, the shell
quoting, and that `agent_core.pl` never goes back to `takeown /U` or to `/inheritance:r` with `/T`.
