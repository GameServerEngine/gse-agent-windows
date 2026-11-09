@echo off
setlocal EnableExtensions

set "AGENT_MODE=Install"
set "INSTALL_PATH=C:\GSE\Agent"
set "INSTALL_PATH_WAS_SET=0"
set "RELEASE_ZIP_URL=https://git.runlevelsystems.com/GSE/Agent-Windows/archive/unstable.zip"
set "RESTIC_VERSION=0.19.1"
set "RESTIC_URL=https://github.com/restic/restic/releases/download/v0.19.1/restic_0.19.1_windows_amd64.zip"
set "RESTIC_ZIP_SHA256=da948ad707ed690426473aaba2046cd61f8f90f6f0e7dab6be0d5796531de67d"
set "RESTIC_EXE_SHA256=b0dd1fd21eea5d8fe1325f55f7118213c21f36de8a261e04c0624a5ab9fd7830"
set "AGENT_OFFLINE=0"
set "AGENT_OFFLINE_WAS_SET=0"
set "SOURCE_PATH="
set "SOURCE_CHOICE="
set "BOOTSTRAP_DIR=%~dp0"
set "BOOTSTRAP_SELF=%~f0"
set "LOADED_ARGS_FILE="
set "FAIL_EXIT=1"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="/LoadArgs" (
    if "%~2"=="" (
        echo ERROR: /LoadArgs requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "FAIL_EXIT=1"
        goto fail
    )
    set "LOADED_ARGS_FILE=%~2"
    if not exist "%~2" (
        echo ERROR: /LoadArgs file was not found: %~2
        echo Stage: parse arguments
        echo Exit code: 1
        set "FAIL_EXIT=1"
        goto fail
    )
    for /f "usebackq tokens=1,* delims==" %%A in ("%~2") do set "%%A=%%B"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="/Mode" (
    if "%~2"=="" (
        echo ERROR: /Mode requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "FAIL_EXIT=1"
        goto fail
    )
    set "AGENT_MODE=%~2"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="/InstallPath" (
    if "%~2"=="" (
        echo ERROR: /InstallPath requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "FAIL_EXIT=1"
        goto fail
    )
    set "INSTALL_PATH=%~2"
    set "INSTALL_PATH_WAS_SET=1"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="/ReleaseZipUrl" (
    if "%~2"=="" (
        echo ERROR: /ReleaseZipUrl requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "FAIL_EXIT=1"
        goto fail
    )
    set "RELEASE_ZIP_URL=%~2"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="/Offline" (
    set "AGENT_OFFLINE=1"
    set "AGENT_OFFLINE_WAS_SET=1"
    shift
    goto parse_args
)
if /I "%~1"=="/SourcePath" (
    if "%~2"=="" (
        echo ERROR: /SourcePath requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "FAIL_EXIT=1"
        goto fail
    )
    set "SOURCE_PATH=%~2"
    shift
    shift
    goto parse_args
)
echo ERROR: Unknown argument: %~1
echo Stage: parse arguments
echo Exit code: 1
set "FAIL_EXIT=1"
goto fail

:args_done
if not "%LOADED_ARGS_FILE%"=="" del "%LOADED_ARGS_FILE%" >nul 2>&1

set "ELEVATION_ARGS_FILE=%TEMP%\gse-agent-bootstrap-%RANDOM%%RANDOM%.args"
net session >nul 2>&1
set "NET_SESSION_EXIT=%ERRORLEVEL%"
if not "%NET_SESSION_EXIT%"=="0" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $vars=@('AGENT_MODE','INSTALL_PATH','INSTALL_PATH_WAS_SET','RELEASE_ZIP_URL','AGENT_OFFLINE','AGENT_OFFLINE_WAS_SET','SOURCE_PATH','BOOTSTRAP_DIR','BOOTSTRAP_SELF'); $lines=$vars | ForEach-Object { $_ + '=' + [Environment]::GetEnvironmentVariable($_) }; Set-Content -LiteralPath $env:ELEVATION_ARGS_FILE -Value $lines -Encoding ASCII"
if not "%NET_SESSION_EXIT%"=="0" set "ELEVATION_SAVE_EXIT=%ERRORLEVEL%"
if not "%NET_SESSION_EXIT%"=="0" if not "%ELEVATION_SAVE_EXIT%"=="0" (
    echo ERROR: Failed to write elevation reload arguments to %ELEVATION_ARGS_FILE%.
    echo Stage: prepare elevation reload
    echo Exit code: %ELEVATION_SAVE_EXIT%
    set "FAIL_EXIT=%ELEVATION_SAVE_EXIT%"
    goto fail
)
if not "%NET_SESSION_EXIT%"=="0" echo Requesting Administrator elevation...
if not "%NET_SESSION_EXIT%"=="0" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $argLine='/d /c """"' + $env:BOOTSTRAP_SELF + '"""" /LoadArgs """"' + $env:ELEVATION_ARGS_FILE + '""""'; Start-Process -FilePath $env:ComSpec -ArgumentList $argLine -Verb RunAs"
if not "%NET_SESSION_EXIT%"=="0" set "ELEVATION_START_EXIT=%ERRORLEVEL%"
if not "%NET_SESSION_EXIT%"=="0" if not "%ELEVATION_START_EXIT%"=="0" (
    echo ERROR: Failed to request Administrator elevation.
    echo Stage: start elevated bootstrap
    echo Exit code: %ELEVATION_START_EXIT%
    set "FAIL_EXIT=%ELEVATION_START_EXIT%"
    goto fail
)
if not "%NET_SESSION_EXIT%"=="0" exit /b 0

if "%INSTALL_PATH_WAS_SET%"=="0" (
    echo.
    set /p "INSTALL_PATH=Install directory [C:\GSE\Agent]: "
)
if "%INSTALL_PATH%"=="" set "INSTALL_PATH=C:\GSE\Agent"

set "INSTALLER_PS=%INSTALL_PATH%\Installer-Agent-Windows.ps1"

if /I not "%AGENT_MODE%"=="Uninstall" if /I not "%AGENT_MODE%"=="Reconfigure" if "%AGENT_OFFLINE_WAS_SET%"=="0" (
    echo.
    echo Installation source:
    echo   1. Online current development archive
    echo   2. Offline local payload path
    echo   3. Reconfigure existing installed version
    set /p "SOURCE_CHOICE=Choose source [1]: "
)
if /I not "%AGENT_MODE%"=="Uninstall" if /I not "%AGENT_MODE%"=="Reconfigure" if "%SOURCE_CHOICE%"=="" if "%AGENT_OFFLINE_WAS_SET%"=="0" set "SOURCE_CHOICE=1"
if /I not "%AGENT_MODE%"=="Uninstall" if "%SOURCE_CHOICE%"=="2" set "AGENT_OFFLINE=1"
if /I not "%AGENT_MODE%"=="Uninstall" if "%SOURCE_CHOICE%"=="3" set "AGENT_MODE=Reconfigure"
if /I not "%AGENT_MODE%"=="Uninstall" if /I not "%AGENT_MODE%"=="Reconfigure" if not "%SOURCE_CHOICE%"=="" if not "%SOURCE_CHOICE%"=="1" if not "%SOURCE_CHOICE%"=="2" (
    echo ERROR: Choose 1 for online current development archive, 2 for offline local payload path, or 3 to reconfigure the existing installed version.
    echo Stage: select installation source
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

if /I not "%AGENT_MODE%"=="Reconfigure" goto after_reconfigure

echo.
echo Reconfiguring existing installation at %INSTALL_PATH%.
if "%SOURCE_PATH%"=="" if exist "%BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" if exist "%BOOTSTRAP_DIR%AgentScripts\install_payload_manifest.txt" set "SOURCE_PATH=%BOOTSTRAP_DIR%."

if "%SOURCE_PATH%"=="" goto validate_installed_reconfigure_installer
if not exist "%SOURCE_PATH%\." (
    echo ERROR: Reconfigure source path is not a directory: %SOURCE_PATH%
    echo Stage: validate reconfigure source payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if not exist "%SOURCE_PATH%\Installer-Agent-Windows.ps1" (
    echo ERROR: Reconfigure source does not contain Installer-Agent-Windows.ps1: %SOURCE_PATH%
    echo Stage: validate reconfigure source payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if not exist "%SOURCE_PATH%\AgentScripts\install_payload_manifest.txt" (
    echo ERROR: Reconfigure source does not contain AgentScripts\install_payload_manifest.txt: %SOURCE_PATH%
    echo Stage: validate reconfigure source payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
set "INSTALLER_PS=%SOURCE_PATH%\Installer-Agent-Windows.ps1"
goto validate_installed_reconfigure_entrypoints

:validate_installed_reconfigure_installer
if not exist "%INSTALLER_PS%" (
    echo ERROR: Installed PowerShell installer was not found at %INSTALLER_PS%.
    echo Stage: validate installed reconfigure payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

:validate_installed_reconfigure_entrypoints
if not exist "%INSTALL_PATH%\AgentScripts\agent_launch.sh" (
    echo ERROR: Installed launcher was not found at %INSTALL_PATH%\AgentScripts\agent_launch.sh.
    echo Stage: validate installed reconfigure payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if not exist "%INSTALL_PATH%\AgentScripts\agent_core.pl" (
    echo ERROR: Installed Perl agent was not found at %INSTALL_PATH%\AgentScripts\agent_core.pl.
    echo Stage: validate installed reconfigure payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
goto run_installer

:after_reconfigure

set "DOWNLOAD_WORK=%TEMP%\gse-agent-unstable-%RANDOM%%RANDOM%"
set "DOWNLOAD_ZIP=%DOWNLOAD_WORK%\unstable.zip"
set "DOWNLOAD_EXTRACT=%DOWNLOAD_WORK%\extract"
set "PAYLOAD_ROOT_FILE=%DOWNLOAD_WORK%\payload-root.txt"

if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" if "%SOURCE_PATH%"=="" if exist "%BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" set /p "SOURCE_PATH=Offline payload path [%BOOTSTRAP_DIR%.]: "
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" if "%SOURCE_PATH%"=="" if exist "%BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" set "SOURCE_PATH=%BOOTSTRAP_DIR%."
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" if "%SOURCE_PATH%"=="" if not exist "%BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" set /p "SOURCE_PATH=Offline payload path: "
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" if "%SOURCE_PATH%"=="" (
    echo ERROR: Offline mode requires /SourcePath or a local payload path.
    echo Stage: validate offline source
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" echo.
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" echo Download URL: %RELEASE_ZIP_URL%
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" echo Download file: %DOWNLOAD_ZIP%
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" where curl.exe
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" set "WHERE_CURL_EXIT=%ERRORLEVEL%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if not "%WHERE_CURL_EXIT%"=="0" (
    echo ERROR: curl.exe was not found.
    echo Stage: locate curl.exe
    echo Exit code: %WHERE_CURL_EXIT%
    set "FAIL_EXIT=%WHERE_CURL_EXIT%"
    goto fail
)

if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" mkdir "%DOWNLOAD_WORK%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" set "MKDIR_WORK_EXIT=%ERRORLEVEL%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if not "%MKDIR_WORK_EXIT%"=="0" (
    echo ERROR: Failed to create download work directory: %DOWNLOAD_WORK%
    echo Stage: create download work directory
    echo Exit code: %MKDIR_WORK_EXIT%
    set "FAIL_EXIT=%MKDIR_WORK_EXIT%"
    goto fail
)
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" mkdir "%DOWNLOAD_EXTRACT%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" set "MKDIR_EXTRACT_EXIT=%ERRORLEVEL%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if not "%MKDIR_EXTRACT_EXIT%"=="0" (
    echo ERROR: Failed to create download extract directory: %DOWNLOAD_EXTRACT%
    echo Stage: create download extract directory
    echo Exit code: %MKDIR_EXTRACT_EXIT%
    set "FAIL_EXIT=%MKDIR_EXTRACT_EXIT%"
    goto fail
)

if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" curl.exe --insecure --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 --output "%DOWNLOAD_ZIP%" "%RELEASE_ZIP_URL%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" set "CURL_EXIT=%ERRORLEVEL%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" echo curl.exe exit code: %CURL_EXIT%
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if not "%CURL_EXIT%"=="0" (
    echo ERROR: curl.exe failed to download the GSE Windows Agent ZIP.
    echo URL: %RELEASE_ZIP_URL%
    echo Destination: %DOWNLOAD_ZIP%
    echo Stage: download release ZIP
    echo Exit code: %CURL_EXIT%
    set "FAIL_EXIT=%CURL_EXIT%"
    goto fail
)

if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if not exist "%DOWNLOAD_ZIP%" (
    echo ERROR: Downloaded ZIP was not found: %DOWNLOAD_ZIP%
    echo Stage: verify downloaded ZIP exists
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" for %%Z in ("%DOWNLOAD_ZIP%") do set "DOWNLOAD_SIZE=%%~zZ"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" echo Downloaded ZIP size: %DOWNLOAD_SIZE% bytes
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if "%DOWNLOAD_SIZE%"=="0" (
    echo ERROR: Downloaded ZIP is empty: %DOWNLOAD_ZIP%
    echo Stage: verify downloaded ZIP size
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { function Test-PayloadRoot([string]$path){ return ((Test-Path -LiteralPath (Join-Path $path 'Installer-Agent-Windows.cmd') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $path 'Installer-Agent-Windows.ps1') -PathType Leaf)) }; $zip=$env:DOWNLOAD_ZIP; $extract=$env:DOWNLOAD_EXTRACT; Expand-Archive -Path $zip -DestinationPath $extract -Force; $roots=@(); if(Test-PayloadRoot $extract){$roots += (Get-Item -LiteralPath $extract)}; $roots += @(Get-ChildItem -LiteralPath $extract -Directory | Where-Object { Test-PayloadRoot $_.FullName }); if($roots.Count -ne 1){throw 'Release ZIP did not contain exactly one GSE Windows Agent payload root with Installer-Agent-Windows.cmd and Installer-Agent-Windows.ps1.'}; Set-Content -LiteralPath $env:PAYLOAD_ROOT_FILE -Value $roots[0].FullName -Encoding ASCII } catch { Write-Error $_; exit 1 }"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" set "EXTRACT_EXIT=%ERRORLEVEL%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" echo ZIP extraction exit code: %EXTRACT_EXIT%
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if not "%EXTRACT_EXIT%"=="0" (
    echo ERROR: Failed to extract or locate the GSE Windows Agent payload root.
    echo Stage: extract release ZIP
    echo Exit code: %EXTRACT_EXIT%
    set "FAIL_EXIT=%EXTRACT_EXIT%"
    goto fail
)
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if not exist "%PAYLOAD_ROOT_FILE%" (
    echo ERROR: Payload root marker was not written: %PAYLOAD_ROOT_FILE%
    echo Stage: read extracted payload root
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" set /p "SOURCE_PATH="<"%PAYLOAD_ROOT_FILE%"
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="0" if "%SOURCE_PATH%"=="" (
    echo ERROR: Extracted payload root was empty.
    echo Stage: read extracted payload root
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" echo.
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" echo Offline source: %SOURCE_PATH%
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" if not exist "%SOURCE_PATH%\." (
    echo ERROR: Offline source path is not a directory: %SOURCE_PATH%
    echo Stage: validate offline source
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" if not exist "%SOURCE_PATH%\Installer-Agent-Windows.cmd" (
    echo ERROR: Offline source does not contain Installer-Agent-Windows.cmd: %SOURCE_PATH%
    echo Stage: validate offline source payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if /I not "%AGENT_MODE%"=="Uninstall" if "%AGENT_OFFLINE%"=="1" if not exist "%SOURCE_PATH%\Installer-Agent-Windows.ps1" (
    echo ERROR: Offline source does not contain Installer-Agent-Windows.ps1: %SOURCE_PATH%
    echo Stage: validate offline source payload
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

if /I not "%AGENT_MODE%"=="Uninstall" if /I not "%AGENT_MODE%"=="Reconfigure" set "INSTALLER_PS=%SOURCE_PATH%\Installer-Agent-Windows.ps1"
if /I not "%AGENT_MODE%"=="Uninstall" if /I not "%AGENT_MODE%"=="Reconfigure" if not exist "%INSTALLER_PS%" (
    echo ERROR: Payload source did not provide %INSTALLER_PS%.
    echo Stage: verify source PowerShell installer
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)
if /I not "%AGENT_MODE%"=="Uninstall" if /I not "%AGENT_MODE%"=="Reconfigure" if not exist "%SOURCE_PATH%\AgentScripts\install_payload_manifest.txt" (
    echo ERROR: Payload source did not provide %SOURCE_PATH%\AgentScripts\install_payload_manifest.txt.
    echo Stage: verify source payload manifest
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

:run_installer
if not exist "%INSTALLER_PS%" (
    echo ERROR: Installer not found at %INSTALLER_PS%.
    echo Stage: verify PowerShell installer
    echo Exit code: 1
    set "FAIL_EXIT=1"
    goto fail
)

echo.
echo Running %INSTALLER_PS%.
if /I "%AGENT_MODE%"=="Install" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%AGENT_MODE%" -InstallPath "%INSTALL_PATH%" -PayloadSourcePath "%SOURCE_PATH%"
if /I "%AGENT_MODE%"=="Repair" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%AGENT_MODE%" -InstallPath "%INSTALL_PATH%" -PayloadSourcePath "%SOURCE_PATH%"
if /I "%AGENT_MODE%"=="Reconfigure" if not "%SOURCE_PATH%"=="" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%AGENT_MODE%" -InstallPath "%INSTALL_PATH%" -PayloadSourcePath "%SOURCE_PATH%"
if /I "%AGENT_MODE%"=="Reconfigure" if "%SOURCE_PATH%"=="" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%AGENT_MODE%" -InstallPath "%INSTALL_PATH%"
if /I "%AGENT_MODE%"=="Uninstall" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%AGENT_MODE%" -InstallPath "%INSTALL_PATH%"
set "INSTALL_EXIT=%ERRORLEVEL%"
echo PowerShell installer exit code: %INSTALL_EXIT%
set "RESTIC_EXIT=0"
if not "%INSTALL_EXIT%"=="0" goto install_done
if /I not "%AGENT_MODE%"=="Uninstall" call :install_restic
if not "%RESTIC_EXIT%"=="0" set "INSTALL_EXIT=%RESTIC_EXIT%"
:install_done
echo.
if not "%INSTALL_EXIT%"=="0" (
    echo GSE Windows Agent installer failed with exit code %INSTALL_EXIT%.
) else (
    echo GSE Windows Agent installer completed.
)
pause
exit /b %INSTALL_EXIT%

:fail
echo.
echo GSE Windows Agent bootstrap failed with exit code %FAIL_EXIT%.
pause
exit /b %FAIL_EXIT%
:install_restic
set "RESTIC_EXIT=0"
set "RESTIC_EXE=%INSTALL_PATH%\bin\restic.exe"
call :restic_hash_ok "%RESTIC_EXE%" "%RESTIC_EXE_SHA256%"
if "%RESTIC_HASH_OK%"=="1" (
    echo restic %RESTIC_VERSION% is already installed: %RESTIC_EXE%
    exit /b 0
)
if not exist "%INSTALL_PATH%\bin" mkdir "%INSTALL_PATH%\bin"
if "%AGENT_OFFLINE%"=="1" if exist "%SOURCE_PATH%\restic\restic.exe" (
    call :restic_hash_ok "%SOURCE_PATH%\restic\restic.exe" "%RESTIC_EXE_SHA256%"
    if "%RESTIC_HASH_OK%"=="1" (
        copy /Y "%SOURCE_PATH%\restic\restic.exe" "%RESTIC_EXE%" >nul
        echo restic %RESTIC_VERSION% installed from the offline source: %RESTIC_EXE%
        exit /b 0
    )
    echo ERROR: restic.exe in the offline source does not match the pinned SHA-256.
    set "RESTIC_EXIT=1"
    exit /b 1
)
set "RESTIC_WORK=%TEMP%\gse-restic-%RANDOM%%RANDOM%"
mkdir "%RESTIC_WORK%"
if errorlevel 1 (
    echo ERROR: Failed to create restic work directory: %RESTIC_WORK%
    set "RESTIC_EXIT=1"
    exit /b 1
)
echo Downloading restic %RESTIC_VERSION% from %RESTIC_URL%
curl.exe --fail --location --show-error --retry 3 --connect-timeout 20 --output "%RESTIC_WORK%\restic.zip" "%RESTIC_URL%"
if errorlevel 1 (
    echo ERROR: curl.exe failed to download restic. Check the network, or use an offline source with restic\restic.exe.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
call :restic_hash_ok "%RESTIC_WORK%\restic.zip" "%RESTIC_ZIP_SHA256%"
if not "%RESTIC_HASH_OK%"=="1" (
    echo ERROR: The restic ZIP does not match the pinned SHA-256. Nothing was installed.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
tar.exe -xf "%RESTIC_WORK%\restic.zip" -C "%RESTIC_WORK%"
if errorlevel 1 (
    echo ERROR: tar.exe could not extract the restic ZIP.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
copy /Y "%RESTIC_WORK%\restic_%RESTIC_VERSION%_windows_amd64.exe" "%RESTIC_EXE%" >nul
if errorlevel 1 (
    echo ERROR: Could not copy restic.exe to %RESTIC_EXE%.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
call :restic_hash_ok "%RESTIC_EXE%" "%RESTIC_EXE_SHA256%"
if not "%RESTIC_HASH_OK%"=="1" (
    echo ERROR: The installed restic.exe does not match the pinned SHA-256.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
echo restic %RESTIC_VERSION% installed: %RESTIC_EXE%
:restic_cleanup
rd /s /q "%RESTIC_WORK%" 2>nul
exit /b %RESTIC_EXIT%

:restic_hash_ok
rem %~1 = file, %~2 = expected SHA-256. Sets RESTIC_HASH_OK to 1 on match.
set "RESTIC_HASH_OK=0"
set "RESTIC_HASH="
if not exist "%~1" exit /b 0
for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "%~1" SHA256') do if not defined RESTIC_HASH set "RESTIC_HASH=%%H"
set "RESTIC_HASH=%RESTIC_HASH: =%"
if /I "%RESTIC_HASH%"=="%~2" set "RESTIC_HASH_OK=1"
exit /b 0
