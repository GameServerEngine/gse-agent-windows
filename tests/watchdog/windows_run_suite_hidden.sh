#!/bin/bash
# Runs test_watchdog_windows.sh on WinDev. Meant to be launched hidden via
# windows_run_suite_hidden.ps1 (see that file for why), not run directly over
# an interactive SSH session -- the suite takes longer than the ~280s
# foreground SSH timeout used in this environment.
export PATH=/usr/bin:/bin:/cygdrive/c/Windows/System32:/cygdrive/c/Windows/System32/WindowsPowerShell/v1.0
cd /cygdrive/c/gse-test/wd || exit 1
bash test_watchdog_windows.sh \
  /cygdrive/c/gse-test/wd/watchdog_script_windows.sh \
  /cygdrive/c/gse-test/wd/start_hidden.ps1 \
  C:\\gse-test\\tools\\spt-test.exe
