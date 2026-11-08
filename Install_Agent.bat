@echo off
setlocal

set "BOOTSTRAP=%~dp0Installer-Agent-Windows.cmd"
if not exist "%BOOTSTRAP%" (
    echo Installer-Agent-Windows.cmd was not found next to this compatibility wrapper.
    pause
    exit /b 1
)

call "%BOOTSTRAP%" %*
exit /b %ERRORLEVEL%
