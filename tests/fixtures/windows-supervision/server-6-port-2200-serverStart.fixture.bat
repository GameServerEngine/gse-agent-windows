@echo off
setlocal EnableExtensions EnableDelayedExpansion
for %%I in ("%~dp0.") do set "INSTANCE=%%~nxI"
set "WATCHDOG_TITLE=%INSTANCE%_watchdog"
set "BOT_TITLE=%INSTANCE%_bot"
set "GAME_TITLE=%INSTANCE%_game"
set "BOT_SUPERVISOR_MARKER=BOT_SUPERVISOR_%INSTANCE%"
set "STOP_FILE=%~dp0status.stopped"
if /I not "%~1"=="bot-supervisor" if exist "%STOP_FILE%" del "%STOP_FILE%" >nul 2>&1
set "GAME_WORKDIR=C:\ogp64\home\gameserver\6\epoch"
set "GAME_COMMAND=C:\ogp64\home\gameserver\6\epoch\arma2oaserver.exe"
set "GAME_EXECUTABLE=arma2oaserver.exe"
set "GAME_OPTIONS=-port=2200 -mod=@dayz_epoch;@epochserver -config=C:\ogp64\home\gameserver\6\epoch\server.cfg"
set "GAME_PORT=2200"
set "GAME_PRIORITY=/normal"
set "GAME_AFFINITY="
set "ALSO_FILE=%~dp0_alsoRun.cmd"
set "ALSO_WORKDIR=C:\ogp64\home\gameserver\6\BEC"
set "ALSO_COMMAND=C:\ogp64\home\gameserver\6\BEC\BEC.exe"
set "ALSO_OPTIONS=-f Config.cfg"
set "HAS_BOT=1"

:WATCHDOG_LOOP
if exist "%STOP_FILE%" goto SHUTDOWN
if "%HAS_BOT%"=="1" call :ENSURE_BOT_SUPERVISOR
cd /d "%GAME_WORKDIR%" || (
    type nul > "%STOP_FILE%"
    goto SHUTDOWN
)
call :SECONDS_NOW START_SECONDS
if errorlevel 1 (
    type nul > "%STOP_FILE%"
    goto SHUTDOWN
)
set "GAME_START_FLAGS="
if defined GAME_PRIORITY set "GAME_START_FLAGS=!GAME_START_FLAGS! %GAME_PRIORITY%"
if defined GAME_AFFINITY set "GAME_START_FLAGS=!GAME_START_FLAGS! /AFFINITY %GAME_AFFINITY%"
start /WAIT "%GAME_TITLE%" !GAME_START_FLAGS! %GAME_EXECUTABLE% %GAME_OPTIONS%
set "GAME_EXIT_CODE=%ERRORLEVEL%"
call :SECONDS_NOW END_SECONDS
if errorlevel 1 (
    type nul > "%STOP_FILE%"
    goto SHUTDOWN
)
set /A RUNTIME_SECONDS=END_SECONDS-START_SECONDS
if !RUNTIME_SECONDS! LSS 0 set /A RUNTIME_SECONDS+=86400
if exist "%STOP_FILE%" goto SHUTDOWN
if !RUNTIME_SECONDS! LSS 15 (
    type nul > "%STOP_FILE%"
    goto SHUTDOWN
)
call :WAIT_SECONDS 30
goto WATCHDOG_LOOP

:SHUTDOWN
if "%HAS_BOT%"=="1" call :KILL_BOT_INSTANCE
for /f "tokens=1,2,3,4,5" %%A in ('netstat -ano ^| findstr /R /C:"^[ ][ ]*TCP" /C:"^[ ][ ]*UDP"') do (
    set "NET_PROTO=%%A"
    set "NET_LOCAL=%%B"
    set "PORT_PID=%%E"
    if /I "!NET_PROTO!"=="UDP" set "PORT_PID=%%D"
    echo(!NET_LOCAL! | findstr /R /C:":%GAME_PORT%$" >nul && if not "!PORT_PID!"=="0" if not "!PORT_PID!"=="4" taskkill /F /T /PID !PORT_PID! >nul 2>&1
)
call :WAIT_SECONDS_ALWAYS 60
exit /B 0

:ENSURE_BOT_SUPERVISOR
wmic process where "name='cmd.exe'" get ProcessId,CommandLine /FORMAT:LIST | findstr /I /C:"%BOT_SUPERVISOR_MARKER%" >nul && exit /B 0
start "" /B /D "%~dp0" cmd.exe /V:ON /C ""%~f0" bot-supervisor "%BOT_SUPERVISOR_MARKER%""
exit /B 0

:KILL_BOT_INSTANCE
wmic process get ProcessId,ExecutablePath,CommandLine /FORMAT:LIST | findstr /I /C:"C:/ogp64/home/gameserver/6/BEC/BEC.exe" >nul
taskkill /F /T /FI "WINDOWTITLE eq %BOT_TITLE%" >nul 2>&1
exit /B 0

:BOT_SUPERVISOR
if not "%~2"=="%BOT_SUPERVISOR_MARKER%" exit /B 0
if exist "%STOP_FILE%" exit /B 0
if not "%HAS_BOT%"=="1" exit /B 0
start "" /B /D "%ALSO_WORKDIR%" /WAIT "%ALSO_COMMAND%" %ALSO_OPTIONS%
exit /B 0

:WAIT_SECONDS
if exist "%STOP_FILE%" exit /B 1
ping -n 2 127.0.0.1 >nul
exit /B 0

:WAIT_SECONDS_ALWAYS
ping -n 2 127.0.0.1 >nul
exit /B 0

:SECONDS_NOW
set "%~1="
set "WMIC_LOCALDATETIME="
set "WMIC_TIMESTAMP="
for /f "tokens=1,* delims==" %%A in ('wmic os get LocalDateTime /value 2^>nul') do if /I "%%A"=="LocalDateTime" if not defined WMIC_LOCALDATETIME set "WMIC_LOCALDATETIME=%%B"
if not defined WMIC_LOCALDATETIME (
    echo Unable to read WMIC LocalDateTime for lifecycle runtime calculation; stopping watchdog.>>"%~dp0lifecycle.log"
    exit /B 1
)
set "WMIC_TIMESTAMP=!WMIC_LOCALDATETIME:~0,14!"
echo(!WMIC_TIMESTAMP!|findstr /R /C:"^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$" >nul || (
    goto SECONDS_NOW_INVALID
)
set "WMIC_HOUR=!WMIC_TIMESTAMP:~8,2!"
set "WMIC_MINUTE=!WMIC_TIMESTAMP:~10,2!"
set "WMIC_SECOND=!WMIC_TIMESTAMP:~12,2!"
set /A WMIC_HOUR_NUM=1!WMIC_HOUR!-100
set /A WMIC_MINUTE_NUM=1!WMIC_MINUTE!-100
set /A WMIC_SECOND_NUM=1!WMIC_SECOND!-100
if !WMIC_HOUR_NUM! LSS 0 goto SECONDS_NOW_INVALID
if !WMIC_HOUR_NUM! GTR 23 goto SECONDS_NOW_INVALID
if !WMIC_MINUTE_NUM! LSS 0 goto SECONDS_NOW_INVALID
if !WMIC_MINUTE_NUM! GTR 59 goto SECONDS_NOW_INVALID
if !WMIC_SECOND_NUM! LSS 0 goto SECONDS_NOW_INVALID
if !WMIC_SECOND_NUM! GTR 59 goto SECONDS_NOW_INVALID
set /A "%~1=(WMIC_HOUR_NUM*3600)+(WMIC_MINUTE_NUM*60)+WMIC_SECOND_NUM"
exit /B 0
:SECONDS_NOW_INVALID
echo Invalid WMIC LocalDateTime "!WMIC_LOCALDATETIME!" for lifecycle runtime calculation; stopping watchdog.>>"%~dp0lifecycle.log"
exit /B 1
