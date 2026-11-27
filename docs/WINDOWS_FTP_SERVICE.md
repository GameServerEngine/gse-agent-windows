# FTP on the Windows agent

Customers reach their game home over FTP. The server is Pure-FTPd with virtual users, run as a Windows service (`GSE-PureFTPd`).

## What the installer sets up

When managed FTP is on and the method is PureFTPd (the defaults), install and reconfigure do this after the agent service is running:

1. Create `etc\ftp\pureftpd.passwd` and its database `pureftpd.pdb` if they are missing. Existing ones are never touched.
2. Create a self-signed TLS certificate at `etc\ssl\private\pure-ftpd.pem` if there is none, and turn TLS on when one exists.
3. Register the service with `cygrunsrv`: start type automatic, restart after a crash (60 s, 60 s, then 5 minutes), log in `var\log\GSE-PureFTPd.log`, same account as the agent.
4. Open the control port and the passive range in the firewall.
5. Start the service and wait for the FTP greeting on the control port.

The service is stopped before an update replaces files and removed on uninstall.

Settings (installer parameters): `-FtpManaged`, `-FtpMethod`, `-RunPureFtpd`, `-FtpPort` (21), `-FtpIp` (0.0.0.0), `-FtpPasvRange` (40000:50000),
`-FtpPublicIp` (the address clients are told to connect to for passive transfers; leave empty when clients are on the same network).

## Why it runs as the agent's account

Pure-FTPd creates uploaded files as the account it runs as. The agent also writes to the game homes, so both must be the same account, or files the customer uploads can end up with a permission set that only their owner can write (see `WINDOWS_HOME_PERMISSIONS.md`). On a LocalSystem install the FTP service is LocalSystem too.

game3 is the exception: its FTP service was set up by hand and runs as `.\gameserver`. It starts at boot and works. It cannot be switched to LocalSystem and back without that account's password, so it was left; the agent repairs a home's permissions before every panel start.

## Managing accounts

The panel calls the agent's `ftp_mgr`, which runs `pure-pw` (see `AgentScripts/GSE/FtpAccounts.pm`). The Cygwin `pure-pw` ignores `-f` for `list` and `show`, so the files are also given in `PURE_PASSWDFILE` and `PURE_DBFILE`.

## Tests

`tests/validate_windows_installer_ftp.sh` guards the installer's choices (for example `cygrunsrv -0` is stdin, `-i` is "interactive" and breaks the command). `tests/ftp_accounts_test.pl` covers the account commands. The service itself was exercised on a real machine with a scratch instance (own port, own database): registration, boot start, recovery, a real login, upload and listing, and removal.
