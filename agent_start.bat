@echo off
setlocal EnableExtensions

REM Starts the GSE agent locally only when the Windows service is not running.
REM The shell launcher is invoked through Bash so Cygwin execute-bit issues on
REM agent_launch.sh do not prevent startup.

set "ROOT=%~dp0"
pushd "%ROOT%" >nul 2>&1

set "PATH=%ROOT%bin;%ROOT%usr\sbin;%PATH%"
set "CYGWIN=server ntsec"
set "SHELL=/bin/bash"
set "SERVICE_NAME=GSPAgent"

echo Checking Windows service %SERVICE_NAME%...

for /f "tokens=3" %%S in ('sc.exe query "%SERVICE_NAME%" ^| findstr /R /C:"STATE *:" 2^>nul') do set "SERVICE_STATE=%%S"

if /I "%SERVICE_STATE%"=="RUNNING" (
    echo GSE Windows Agent is already running as Windows service %SERVICE_NAME%.
    popd
    exit /b 0
)

if /I "%SERVICE_STATE%"=="START_PENDING" (
    echo Windows service %SERVICE_NAME% is still starting.
    echo Foreground mode was not started to avoid a duplicate agent instance.
    popd
    exit /b 2
)

if /I "%SERVICE_STATE%"=="STOP_PENDING" (
    echo Windows service %SERVICE_NAME% is still stopping.
    echo Wait for it to stop, then run this file again.
    popd
    exit /b 2
)

if not exist "%ROOT%bin\bash.exe" (
    echo ERROR: bash.exe not found at "%ROOT%bin\bash.exe"
    echo Run this script from the installed GSE Windows agent root.
    pause
    exit /b 1
)

if not exist "%ROOT%AgentScripts\agent_launch.sh" (
    echo ERROR: "%ROOT%AgentScripts\agent_launch.sh" not found.
    pause
    exit /b 1
)

echo Starting GSE Windows Agent in local foreground mode...
echo Cygwin root: %ROOT%

"%ROOT%bin\bash.exe" -lc "cd /AgentScripts && exec /bin/bash /AgentScripts/agent_launch.sh foreground"
set "AGENT_EXIT=%ERRORLEVEL%"

echo.
echo GSE Windows Agent foreground session exited with code %AGENT_EXIT%.
popd
pause
exit /b %AGENT_EXIT%
