@echo off
setlocal EnableExtensions

set "GSP_MODE=Install"
set "GSP_INSTALL_PATH=C:\GSE\Agent"
set "GSP_INSTALL_PATH_WAS_SET=0"
set "GSP_RELEASE_ZIP_URL=https://git.runlevelsystems.com/GSE/Agent-Windows/archive/unstable.zip"
set "GSP_RESTIC_VERSION=0.19.1"
set "GSP_RESTIC_URL=https://github.com/restic/restic/releases/download/v0.19.1/restic_0.19.1_windows_amd64.zip"
set "GSP_RESTIC_ZIP_SHA256=da948ad707ed690426473aaba2046cd61f8f90f6f0e7dab6be0d5796531de67d"
set "GSP_RESTIC_EXE_SHA256=b0dd1fd21eea5d8fe1325f55f7118213c21f36de8a261e04c0624a5ab9fd7830"
set "GSP_OFFLINE=0"
set "GSP_OFFLINE_WAS_SET=0"
set "GSP_SOURCE_PATH="
set "GSP_SOURCE_CHOICE="
set "GSP_BOOTSTRAP_DIR=%~dp0"
set "GSP_BOOTSTRAP_SELF=%~f0"
set "GSP_LOADED_ARGS_FILE="
set "GSP_FAIL_EXIT=1"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="/LoadArgs" (
    if "%~2"=="" (
        echo ERROR: /LoadArgs requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "GSP_FAIL_EXIT=1"
        goto fail
    )
    set "GSP_LOADED_ARGS_FILE=%~2"
    if not exist "%~2" (
        echo ERROR: /LoadArgs file was not found: %~2
        echo Stage: parse arguments
        echo Exit code: 1
        set "GSP_FAIL_EXIT=1"
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
        set "GSP_FAIL_EXIT=1"
        goto fail
    )
    set "GSP_MODE=%~2"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="/InstallPath" (
    if "%~2"=="" (
        echo ERROR: /InstallPath requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "GSP_FAIL_EXIT=1"
        goto fail
    )
    set "GSP_INSTALL_PATH=%~2"
    set "GSP_INSTALL_PATH_WAS_SET=1"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="/ReleaseZipUrl" (
    if "%~2"=="" (
        echo ERROR: /ReleaseZipUrl requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "GSP_FAIL_EXIT=1"
        goto fail
    )
    set "GSP_RELEASE_ZIP_URL=%~2"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="/Offline" (
    set "GSP_OFFLINE=1"
    set "GSP_OFFLINE_WAS_SET=1"
    shift
    goto parse_args
)
if /I "%~1"=="/SourcePath" (
    if "%~2"=="" (
        echo ERROR: /SourcePath requires a value.
        echo Stage: parse arguments
        echo Exit code: 1
        set "GSP_FAIL_EXIT=1"
        goto fail
    )
    set "GSP_SOURCE_PATH=%~2"
    shift
    shift
    goto parse_args
)
echo ERROR: Unknown argument: %~1
echo Stage: parse arguments
echo Exit code: 1
set "GSP_FAIL_EXIT=1"
goto fail

:args_done
if not "%GSP_LOADED_ARGS_FILE%"=="" del "%GSP_LOADED_ARGS_FILE%" >nul 2>&1

set "GSP_ELEVATION_ARGS_FILE=%TEMP%\gse-agent-bootstrap-%RANDOM%%RANDOM%.args"
net session >nul 2>&1
set "NET_SESSION_EXIT=%ERRORLEVEL%"
if not "%NET_SESSION_EXIT%"=="0" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $vars=@('GSP_MODE','GSP_INSTALL_PATH','GSP_INSTALL_PATH_WAS_SET','GSP_RELEASE_ZIP_URL','GSP_OFFLINE','GSP_OFFLINE_WAS_SET','GSP_SOURCE_PATH','GSP_BOOTSTRAP_DIR','GSP_BOOTSTRAP_SELF'); $lines=$vars | ForEach-Object { $_ + '=' + [Environment]::GetEnvironmentVariable($_) }; Set-Content -LiteralPath $env:GSP_ELEVATION_ARGS_FILE -Value $lines -Encoding ASCII"
if not "%NET_SESSION_EXIT%"=="0" set "ELEVATION_SAVE_EXIT=%ERRORLEVEL%"
if not "%NET_SESSION_EXIT%"=="0" if not "%ELEVATION_SAVE_EXIT%"=="0" (
    echo ERROR: Failed to write elevation reload arguments to %GSP_ELEVATION_ARGS_FILE%.
    echo Stage: prepare elevation reload
    echo Exit code: %ELEVATION_SAVE_EXIT%
    set "GSP_FAIL_EXIT=%ELEVATION_SAVE_EXIT%"
    goto fail
)
if not "%NET_SESSION_EXIT%"=="0" echo Requesting Administrator elevation...
if not "%NET_SESSION_EXIT%"=="0" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $argLine='/d /c """"' + $env:GSP_BOOTSTRAP_SELF + '"""" /LoadArgs """"' + $env:GSP_ELEVATION_ARGS_FILE + '""""'; Start-Process -FilePath $env:ComSpec -ArgumentList $argLine -Verb RunAs"
if not "%NET_SESSION_EXIT%"=="0" set "ELEVATION_START_EXIT=%ERRORLEVEL%"
if not "%NET_SESSION_EXIT%"=="0" if not "%ELEVATION_START_EXIT%"=="0" (
    echo ERROR: Failed to request Administrator elevation.
    echo Stage: start elevated bootstrap
    echo Exit code: %ELEVATION_START_EXIT%
    set "GSP_FAIL_EXIT=%ELEVATION_START_EXIT%"
    goto fail
)
if not "%NET_SESSION_EXIT%"=="0" exit /b 0

if "%GSP_INSTALL_PATH_WAS_SET%"=="0" (
    echo.
    set /p "GSP_INSTALL_PATH=Install directory [C:\GSE\Agent]: "
)
if "%GSP_INSTALL_PATH%"=="" set "GSP_INSTALL_PATH=C:\GSE\Agent"

set "INSTALLER_PS=%GSP_INSTALL_PATH%\Installer-Agent-Windows.ps1"

if /I not "%GSP_MODE%"=="Uninstall" if /I not "%GSP_MODE%"=="Reconfigure" if "%GSP_OFFLINE_WAS_SET%"=="0" (
    echo.
    echo Installation source:
    echo   1. Online current development archive
    echo   2. Offline local payload path
    echo   3. Reconfigure existing installed version
    set /p "GSP_SOURCE_CHOICE=Choose source [1]: "
)
if /I not "%GSP_MODE%"=="Uninstall" if /I not "%GSP_MODE%"=="Reconfigure" if "%GSP_SOURCE_CHOICE%"=="" if "%GSP_OFFLINE_WAS_SET%"=="0" set "GSP_SOURCE_CHOICE=1"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_SOURCE_CHOICE%"=="2" set "GSP_OFFLINE=1"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_SOURCE_CHOICE%"=="3" set "GSP_MODE=Reconfigure"
if /I not "%GSP_MODE%"=="Uninstall" if /I not "%GSP_MODE%"=="Reconfigure" if not "%GSP_SOURCE_CHOICE%"=="" if not "%GSP_SOURCE_CHOICE%"=="1" if not "%GSP_SOURCE_CHOICE%"=="2" (
    echo ERROR: Choose 1 for online current development archive, 2 for offline local payload path, or 3 to reconfigure the existing installed version.
    echo Stage: select installation source
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

if /I not "%GSP_MODE%"=="Reconfigure" goto after_reconfigure

echo.
echo Reconfiguring existing installation at %GSP_INSTALL_PATH%.
if "%GSP_SOURCE_PATH%"=="" if exist "%GSP_BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" if exist "%GSP_BOOTSTRAP_DIR%AgentScripts\install_payload_manifest.txt" set "GSP_SOURCE_PATH=%GSP_BOOTSTRAP_DIR%."

if "%GSP_SOURCE_PATH%"=="" goto validate_installed_reconfigure_installer
if not exist "%GSP_SOURCE_PATH%\." (
    echo ERROR: Reconfigure source path is not a directory: %GSP_SOURCE_PATH%
    echo Stage: validate reconfigure source payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if not exist "%GSP_SOURCE_PATH%\Installer-Agent-Windows.ps1" (
    echo ERROR: Reconfigure source does not contain Installer-Agent-Windows.ps1: %GSP_SOURCE_PATH%
    echo Stage: validate reconfigure source payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if not exist "%GSP_SOURCE_PATH%\AgentScripts\install_payload_manifest.txt" (
    echo ERROR: Reconfigure source does not contain AgentScripts\install_payload_manifest.txt: %GSP_SOURCE_PATH%
    echo Stage: validate reconfigure source payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
set "INSTALLER_PS=%GSP_SOURCE_PATH%\Installer-Agent-Windows.ps1"
goto validate_installed_reconfigure_entrypoints

:validate_installed_reconfigure_installer
if not exist "%INSTALLER_PS%" (
    echo ERROR: Installed PowerShell installer was not found at %INSTALLER_PS%.
    echo Stage: validate installed reconfigure payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

:validate_installed_reconfigure_entrypoints
if not exist "%GSP_INSTALL_PATH%\AgentScripts\agent_launch.sh" (
    echo ERROR: Installed launcher was not found at %GSP_INSTALL_PATH%\AgentScripts\agent_launch.sh.
    echo Stage: validate installed reconfigure payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if not exist "%GSP_INSTALL_PATH%\AgentScripts\gse_agent.pl" (
    echo ERROR: Installed Perl agent was not found at %GSP_INSTALL_PATH%\AgentScripts\gse_agent.pl.
    echo Stage: validate installed reconfigure payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
goto run_installer

:after_reconfigure

set "GSP_DOWNLOAD_WORK=%TEMP%\gse-agent-unstable-%RANDOM%%RANDOM%"
set "GSP_DOWNLOAD_ZIP=%GSP_DOWNLOAD_WORK%\unstable.zip"
set "GSP_DOWNLOAD_EXTRACT=%GSP_DOWNLOAD_WORK%\extract"
set "GSP_PAYLOAD_ROOT_FILE=%GSP_DOWNLOAD_WORK%\payload-root.txt"

if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" if "%GSP_SOURCE_PATH%"=="" if exist "%GSP_BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" set /p "GSP_SOURCE_PATH=Offline payload path [%GSP_BOOTSTRAP_DIR%.]: "
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" if "%GSP_SOURCE_PATH%"=="" if exist "%GSP_BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" set "GSP_SOURCE_PATH=%GSP_BOOTSTRAP_DIR%."
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" if "%GSP_SOURCE_PATH%"=="" if not exist "%GSP_BOOTSTRAP_DIR%Installer-Agent-Windows.ps1" set /p "GSP_SOURCE_PATH=Offline payload path: "
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" if "%GSP_SOURCE_PATH%"=="" (
    echo ERROR: Offline mode requires /SourcePath or a local payload path.
    echo Stage: validate offline source
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" echo.
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" echo Download URL: %GSP_RELEASE_ZIP_URL%
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" echo Download file: %GSP_DOWNLOAD_ZIP%
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" where curl.exe
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" set "WHERE_CURL_EXIT=%ERRORLEVEL%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if not "%WHERE_CURL_EXIT%"=="0" (
    echo ERROR: curl.exe was not found.
    echo Stage: locate curl.exe
    echo Exit code: %WHERE_CURL_EXIT%
    set "GSP_FAIL_EXIT=%WHERE_CURL_EXIT%"
    goto fail
)

if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" mkdir "%GSP_DOWNLOAD_WORK%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" set "MKDIR_WORK_EXIT=%ERRORLEVEL%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if not "%MKDIR_WORK_EXIT%"=="0" (
    echo ERROR: Failed to create download work directory: %GSP_DOWNLOAD_WORK%
    echo Stage: create download work directory
    echo Exit code: %MKDIR_WORK_EXIT%
    set "GSP_FAIL_EXIT=%MKDIR_WORK_EXIT%"
    goto fail
)
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" mkdir "%GSP_DOWNLOAD_EXTRACT%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" set "MKDIR_EXTRACT_EXIT=%ERRORLEVEL%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if not "%MKDIR_EXTRACT_EXIT%"=="0" (
    echo ERROR: Failed to create download extract directory: %GSP_DOWNLOAD_EXTRACT%
    echo Stage: create download extract directory
    echo Exit code: %MKDIR_EXTRACT_EXIT%
    set "GSP_FAIL_EXIT=%MKDIR_EXTRACT_EXIT%"
    goto fail
)

if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" curl.exe --insecure --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 --output "%GSP_DOWNLOAD_ZIP%" "%GSP_RELEASE_ZIP_URL%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" set "CURL_EXIT=%ERRORLEVEL%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" echo curl.exe exit code: %CURL_EXIT%
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if not "%CURL_EXIT%"=="0" (
    echo ERROR: curl.exe failed to download the GSE Windows Agent ZIP.
    echo URL: %GSP_RELEASE_ZIP_URL%
    echo Destination: %GSP_DOWNLOAD_ZIP%
    echo Stage: download release ZIP
    echo Exit code: %CURL_EXIT%
    set "GSP_FAIL_EXIT=%CURL_EXIT%"
    goto fail
)

if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if not exist "%GSP_DOWNLOAD_ZIP%" (
    echo ERROR: Downloaded ZIP was not found: %GSP_DOWNLOAD_ZIP%
    echo Stage: verify downloaded ZIP exists
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" for %%Z in ("%GSP_DOWNLOAD_ZIP%") do set "GSP_DOWNLOAD_SIZE=%%~zZ"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" echo Downloaded ZIP size: %GSP_DOWNLOAD_SIZE% bytes
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if "%GSP_DOWNLOAD_SIZE%"=="0" (
    echo ERROR: Downloaded ZIP is empty: %GSP_DOWNLOAD_ZIP%
    echo Stage: verify downloaded ZIP size
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { function Test-PayloadRoot([string]$path){ return ((Test-Path -LiteralPath (Join-Path $path 'Installer-Agent-Windows.cmd') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $path 'Installer-Agent-Windows.ps1') -PathType Leaf)) }; $zip=$env:GSP_DOWNLOAD_ZIP; $extract=$env:GSP_DOWNLOAD_EXTRACT; Expand-Archive -Path $zip -DestinationPath $extract -Force; $roots=@(); if(Test-PayloadRoot $extract){$roots += (Get-Item -LiteralPath $extract)}; $roots += @(Get-ChildItem -LiteralPath $extract -Directory | Where-Object { Test-PayloadRoot $_.FullName }); if($roots.Count -ne 1){throw 'Release ZIP did not contain exactly one GSE Windows Agent payload root with Installer-Agent-Windows.cmd and Installer-Agent-Windows.ps1.'}; Set-Content -LiteralPath $env:GSP_PAYLOAD_ROOT_FILE -Value $roots[0].FullName -Encoding ASCII } catch { Write-Error $_; exit 1 }"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" set "EXTRACT_EXIT=%ERRORLEVEL%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" echo ZIP extraction exit code: %EXTRACT_EXIT%
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if not "%EXTRACT_EXIT%"=="0" (
    echo ERROR: Failed to extract or locate the GSE Windows Agent payload root.
    echo Stage: extract release ZIP
    echo Exit code: %EXTRACT_EXIT%
    set "GSP_FAIL_EXIT=%EXTRACT_EXIT%"
    goto fail
)
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if not exist "%GSP_PAYLOAD_ROOT_FILE%" (
    echo ERROR: Payload root marker was not written: %GSP_PAYLOAD_ROOT_FILE%
    echo Stage: read extracted payload root
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" set /p "GSP_SOURCE_PATH="<"%GSP_PAYLOAD_ROOT_FILE%"
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="0" if "%GSP_SOURCE_PATH%"=="" (
    echo ERROR: Extracted payload root was empty.
    echo Stage: read extracted payload root
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" echo.
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" echo Offline source: %GSP_SOURCE_PATH%
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" if not exist "%GSP_SOURCE_PATH%\." (
    echo ERROR: Offline source path is not a directory: %GSP_SOURCE_PATH%
    echo Stage: validate offline source
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" if not exist "%GSP_SOURCE_PATH%\Installer-Agent-Windows.cmd" (
    echo ERROR: Offline source does not contain Installer-Agent-Windows.cmd: %GSP_SOURCE_PATH%
    echo Stage: validate offline source payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if /I not "%GSP_MODE%"=="Uninstall" if "%GSP_OFFLINE%"=="1" if not exist "%GSP_SOURCE_PATH%\Installer-Agent-Windows.ps1" (
    echo ERROR: Offline source does not contain Installer-Agent-Windows.ps1: %GSP_SOURCE_PATH%
    echo Stage: validate offline source payload
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

if /I not "%GSP_MODE%"=="Uninstall" if /I not "%GSP_MODE%"=="Reconfigure" set "INSTALLER_PS=%GSP_SOURCE_PATH%\Installer-Agent-Windows.ps1"
if /I not "%GSP_MODE%"=="Uninstall" if /I not "%GSP_MODE%"=="Reconfigure" if not exist "%INSTALLER_PS%" (
    echo ERROR: Payload source did not provide %INSTALLER_PS%.
    echo Stage: verify source PowerShell installer
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)
if /I not "%GSP_MODE%"=="Uninstall" if /I not "%GSP_MODE%"=="Reconfigure" if not exist "%GSP_SOURCE_PATH%\AgentScripts\install_payload_manifest.txt" (
    echo ERROR: Payload source did not provide %GSP_SOURCE_PATH%\AgentScripts\install_payload_manifest.txt.
    echo Stage: verify source payload manifest
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

:run_installer
if not exist "%INSTALLER_PS%" (
    echo ERROR: Installer not found at %INSTALLER_PS%.
    echo Stage: verify PowerShell installer
    echo Exit code: 1
    set "GSP_FAIL_EXIT=1"
    goto fail
)

echo.
echo Running %INSTALLER_PS%.
if /I "%GSP_MODE%"=="Install" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%GSP_MODE%" -InstallPath "%GSP_INSTALL_PATH%" -PayloadSourcePath "%GSP_SOURCE_PATH%"
if /I "%GSP_MODE%"=="Repair" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%GSP_MODE%" -InstallPath "%GSP_INSTALL_PATH%" -PayloadSourcePath "%GSP_SOURCE_PATH%"
if /I "%GSP_MODE%"=="Reconfigure" if not "%GSP_SOURCE_PATH%"=="" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%GSP_MODE%" -InstallPath "%GSP_INSTALL_PATH%" -PayloadSourcePath "%GSP_SOURCE_PATH%"
if /I "%GSP_MODE%"=="Reconfigure" if "%GSP_SOURCE_PATH%"=="" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%GSP_MODE%" -InstallPath "%GSP_INSTALL_PATH%"
if /I "%GSP_MODE%"=="Uninstall" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS%" -Mode "%GSP_MODE%" -InstallPath "%GSP_INSTALL_PATH%"
set "INSTALL_EXIT=%ERRORLEVEL%"
echo PowerShell installer exit code: %INSTALL_EXIT%
set "RESTIC_EXIT=0"
if not "%INSTALL_EXIT%"=="0" goto install_done
if /I not "%GSP_MODE%"=="Uninstall" call :install_restic
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
echo GSE Windows Agent bootstrap failed with exit code %GSP_FAIL_EXIT%.
pause
exit /b %GSP_FAIL_EXIT%
:install_restic
set "RESTIC_EXIT=0"
set "RESTIC_EXE=%GSP_INSTALL_PATH%\bin\restic.exe"
call :restic_hash_ok "%RESTIC_EXE%" "%GSP_RESTIC_EXE_SHA256%"
if "%RESTIC_HASH_OK%"=="1" (
    echo restic %GSP_RESTIC_VERSION% is already installed: %RESTIC_EXE%
    exit /b 0
)
if not exist "%GSP_INSTALL_PATH%\bin" mkdir "%GSP_INSTALL_PATH%\bin"
if "%GSP_OFFLINE%"=="1" if exist "%GSP_SOURCE_PATH%\restic\restic.exe" (
    call :restic_hash_ok "%GSP_SOURCE_PATH%\restic\restic.exe" "%GSP_RESTIC_EXE_SHA256%"
    if "%RESTIC_HASH_OK%"=="1" (
        copy /Y "%GSP_SOURCE_PATH%\restic\restic.exe" "%RESTIC_EXE%" >nul
        echo restic %GSP_RESTIC_VERSION% installed from the offline source: %RESTIC_EXE%
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
echo Downloading restic %GSP_RESTIC_VERSION% from %GSP_RESTIC_URL%
curl.exe --fail --location --show-error --retry 3 --connect-timeout 20 --output "%RESTIC_WORK%\restic.zip" "%GSP_RESTIC_URL%"
if errorlevel 1 (
    echo ERROR: curl.exe failed to download restic. Check the network, or use an offline source with restic\restic.exe.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
call :restic_hash_ok "%RESTIC_WORK%\restic.zip" "%GSP_RESTIC_ZIP_SHA256%"
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
copy /Y "%RESTIC_WORK%\restic_%GSP_RESTIC_VERSION%_windows_amd64.exe" "%RESTIC_EXE%" >nul
if errorlevel 1 (
    echo ERROR: Could not copy restic.exe to %RESTIC_EXE%.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
call :restic_hash_ok "%RESTIC_EXE%" "%GSP_RESTIC_EXE_SHA256%"
if not "%RESTIC_HASH_OK%"=="1" (
    echo ERROR: The installed restic.exe does not match the pinned SHA-256.
    set "RESTIC_EXIT=1"
    goto restic_cleanup
)
echo restic %GSP_RESTIC_VERSION% installed: %RESTIC_EXE%
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
