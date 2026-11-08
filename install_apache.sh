#!/bin/bash
# Optional, manually-run utility inherited from upstream OGP-Agent-Windows.
#
# Purpose: registers Cygwin's Apache HTTPD ("httpd") package as a Windows
# service via cygrunsrv, then starts it. This is NOT part of the GSE agent
# install/repair/reconfigure/uninstall flow driven by
# Installer-Agent-Windows.cmd/.ps1, is not invoked automatically by any
# agent script, and is not required for the agent RPC service, FTP
# (Pure-FTPd), or game server hosting to work.
#
# When it is used: only on hosts where an operator has separately installed
# Cygwin's apache2/httpd package (e.g. to serve a legacy OGP-style web file
# manager or static content alongside the agent) and wants it running as a
# Cygwin service. Run manually, once, after installing that package.
#
# Requirements: this repo's bundled Cygwin tree does NOT include the httpd
# package (no /etc/rc.d/init.d/httpd, no bin/httpd.exe). cygrunsrv.exe is
# bundled (bin/cygrunsrv.exe). Installing Apache is out of scope for the
# GSE Windows agent installer; do so via Cygwin's own package manager
# (setup-x86_64.exe) before running this script.
/etc/rc.d/init.d/httpd install
cygrunsrv -S httpd
/etc/rc.d/init.d/httpd reload
