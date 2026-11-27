#!/usr/bin/env bash
# The installer must set up the Pure-FTPd service for a fresh install. The service itself was exercised on a real Windows
# machine (scratch instance); this guards the choices that test showed to matter.
set -u
cd "$(dirname "$0")/.."
f=Installer-Agent-Windows.ps1
fail=0
check() { if grep -q -E -- "$2" "$f"; then echo "ok - $1"; else echo "FAIL - $1"; fail=$((fail+1)); fi; }
absent() { if grep -q -E -- "$2" "$f"; then echo "FAIL - $1"; fail=$((fail+1)); else echo "ok - $1"; fi; }

check  "the installer registers the FTP service with cygrunsrv"            'function Register-FtpService'
check  "the FTP service is set to start at boot"                            'config", \$Name, "start=", "auto"'
check  "the FTP service restarts after a crash (three restart actions)"      'failure", \$Name, "reset=", "86400", "actions=", "restart/60000/restart/60000/restart/300000"'
check  "the start-at-boot and recovery settings are verified afterwards"     'is not set to start automatically at boot'
check  "stdin is given with -0 (cygrunsrv -i means interactive, and breaks the command)" '"-0", "/dev/null"'
absent "no -i option is passed to cygrunsrv for the FTP service"            '"-i", "/dev/null"'
check  "the FTP service runs as the agent's account (no -u for LocalSystem)" 'Test-LocalSystemAccount \$AccountName'
check  "the account database is created when missing"                       'Created the empty FTP account database'
check  "pure-pw is told the files through the environment as well as -f"     'PURE_PASSWDFILE'
check  "a TLS certificate is created when missing"                          'Created a self-signed TLS certificate'
check  "the installer waits for the FTP greeting after starting the service" 'function Wait-FtpBanner'
check  "the service is started and verified during install and reconfigure"  'Install-FtpServiceIfWanted -PlainPassword \$password'
check  "the FTP passive range gets a firewall rule"                         'FTP passive'
check  "the FTP service is removed with the agent service (update and uninstall)" 'Remove-FtpService -Name \$Script:FtpServiceName'
check  "a default passive range is set"                                     'FtpPasvRange = "40000:50000"'
n=$(grep -c 'Install-FtpServiceIfWanted -PlainPassword' "$f"); [ "$n" -eq 2 ] && echo "ok - install and reconfigure both call it ($n calls)" || { echo "FAIL - install and reconfigure must both call it exactly once each (found $n)"; fail=$((fail+1)); }
echo
if [ $fail -eq 0 ]; then echo "Windows installer FTP service checks passed."; else echo "$fail Windows installer FTP check(s) FAILED."; exit 1; fi
