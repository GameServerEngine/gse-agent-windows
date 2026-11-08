@echo off
setlocal EnableExtensions

REM Stops only a foreground agent started by agent_start.bat.
REM Production service start/stop/restart is managed through Windows Services.

set "ROOT=%~dp0"
pushd "%ROOT%" >nul 2>&1

set "PATH=%ROOT%bin;%ROOT%usr\sbin;%PATH%"
set "CYGWIN=server ntsec"
set "SHELL=/bin/bash"

echo Stopping GSE Windows Agent foreground session...
echo Cygwin root: %ROOT%

if not exist "%ROOT%bin\bash.exe" (
    echo ERROR: bash.exe not found at "%ROOT%bin\bash.exe"
    pause
    exit /b 1
)

if not exist "%ROOT%AgentScripts\agent_launch.sh" (
    echo ERROR: "%ROOT%AgentScripts\agent_launch.sh" not found.
    pause
    exit /b 1
)

"%ROOT%bin\bash.exe" -lc "cd /AgentScripts && ./agent_launch.sh stop-foreground"
set "STOP_EXIT=%ERRORLEVEL%"

echo.
if "%STOP_EXIT%"=="0" (
    echo Foreground agent stop request completed.
) else (
    echo Foreground agent stop request failed with code %STOP_EXIT%.
)
echo Service mode is controlled through Windows Services.
pause
exit /b %STOP_EXIT%
