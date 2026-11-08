# Launches windows_run_suite_hidden.sh hidden on WinDev via start_hidden.ps1,
# so a long test run survives past the foreground SSH timeout.
#
# Pass the suite's own invocation as a SCRIPT FILE, not as a "bash -c '...'"
# string containing embedded quotes and redirection operators
# (-Args '-c "... > suite.out 2>&1"'). That shape used to be how this was
# invoked, and it silently corrupted the game executable path passed further
# down the chain: cmd.exe's /c parsing of the launcher file start_hidden.ps1
# writes has to count quotes to know where the single argument to bash.exe
# ends, and an inner double-quoted bash -c string that itself contains
# further double quotes and a `>`/`2>&1` meant for the *inner* shell throws
# that counting off, which showed up three layers down as GAME_EXE losing
# every backslash in its path (e.g. "C:\gse-test\tools\spt-test.exe" became
# "gse-testtoolsspt-test.exe", which then made the game fail to start at
# all -- misread at the time as a liveness-check race, because the launcher
# process that was supposed to hold the real child's PID also died almost
# immediately once the path it had didn't resolve to a real file).
# Point -Args at a plain script path instead (no -c, no nested quoting) and
# let that script's own content set env vars, cd, and run the real suite --
# exactly how start_wd already invokes each individual watchdog, which never
# had this problem.
$wd = 'C:\gse-test\wd'
New-Item -ItemType Directory -Force 'C:\gse-test\cygwin\tmp' | Out-Null
Remove-Item -Recurse -Force "$wd\run" -ErrorAction SilentlyContinue
Remove-Item -Force "$wd\suite.out", "$wd\suite.err" -ErrorAction SilentlyContinue
& "$wd\start_hidden.ps1" -Exe 'C:\gse-test\cygwin\bin\bash.exe' -Args '/cygdrive/c/gse-test/wd/windows_run_suite_hidden.sh' -WorkDir $wd -OutBase suite
