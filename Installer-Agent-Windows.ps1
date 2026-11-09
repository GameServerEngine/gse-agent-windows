# GSE Windows Agent interactive installer.
# Installs or repairs the repo-root Cygwin runtime and registers service mode.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateSet("Install", "Repair", "Reconfigure", "Uninstall")]
    [string]$Mode = "Install",
    [string]$InstallPath = "C:\GSE\Agent",
    [string]$ServiceName = "GSPAgent",
    [string]$ServiceDisplayName = "GSE Windows Agent",
    [string]$AgentUser = "gameserver",
    [string]$PayloadSourcePath = "",
    [switch]$AgentUserWasSet,
    # Canonical interactive prompts (mirrors the GSE Linux agent's guided
    # config prompt list). Pass these to skip the matching prompt.
    [string]$AgentKey = "",
    [switch]$AgentKeyWasSet,
    [string]$PanelApiUrl = "",
    [switch]$PanelApiUrlWasSet,
    [string]$ListenIp = "0.0.0.0",
    [switch]$ListenIpWasSet,
    [string]$ListenPort = "12679",
    [switch]$ListenPortWasSet,
    [string]$FtpManaged = "1",
    [switch]$FtpManagedWasSet,
    [string]$FtpMethod = "PureFTPd",
    [switch]$FtpMethodWasSet,
    [string]$AutoRestart = "1",
    [switch]$AutoRestartWasSet,
    [string]$AutoUpdate = "0",
    [switch]$AutoUpdateWasSet,
    [string]$RemoteServerId = "",
    [switch]$RemoteServerIdWasSet,
    # Flag-only settings. These used to be prompted interactively; they now
    # always take their default unless explicitly overridden on the command
    # line, so the guided flow only asks the canonical questions above.
    [string]$SteamLicense = "Accept",
    [string]$ScreenLogLocal = "1",
    [string]$DeleteLogsAfterDays = "30",
    [string]$ProtocolShutdownWaitSeconds = "10",
    [string]$HomeAclIsolation = "1",
    [string]$PortValidationEnabled = "1",
    [string]$StartupValidationTimeoutSeconds = "180",
    [string]$PortCheckIntervalSeconds = "5",
    [string]$UpdateMetadataUrl = "",
    [string]$RunPureFtpd = "",
    [string]$FtpPort = "21",
    [string]$FtpIp = "0.0.0.0",
    [string]$FtpPasvRange = ""
)

$ErrorActionPreference = "Stop"
$Script:LogDir = Join-Path $InstallPath "logs"
$Script:LogFile = Join-Path $Script:LogDir "install.log"
$Script:AgentAccountName = $AgentUser
$Script:AgentUserExplicit = $AgentUserWasSet.IsPresent -or $PSBoundParameters.ContainsKey("AgentUser")
$Script:AgentAccountResolved = $false
$Script:DefaultUpdateMetadataUrl = "https://git.runlevelsystems.com/GSE/Agent-Windows/releases/download/stable/gse-windows-agent-latest.json"
$Script:ApplicationDirName = "AgentScripts"
$Script:LegacyApplicationDirName = "GSP"

# Explicit-flag tracking for the canonical guided prompts. When the caller
# passes one of these on the command line, the matching interactive prompt
# is skipped and the supplied value is used as-is.
$Script:AgentKeyExplicit = $AgentKeyWasSet.IsPresent -or $PSBoundParameters.ContainsKey("AgentKey")
$Script:PanelApiUrlExplicit = $PanelApiUrlWasSet.IsPresent -or $PSBoundParameters.ContainsKey("PanelApiUrl")
$Script:ListenIpExplicit = $ListenIpWasSet.IsPresent -or $PSBoundParameters.ContainsKey("ListenIp")
$Script:ListenPortExplicit = $ListenPortWasSet.IsPresent -or $PSBoundParameters.ContainsKey("ListenPort")
$Script:FtpManagedExplicit = $FtpManagedWasSet.IsPresent -or $PSBoundParameters.ContainsKey("FtpManaged")
$Script:FtpMethodExplicit = $FtpMethodWasSet.IsPresent -or $PSBoundParameters.ContainsKey("FtpMethod")
$Script:AutoRestartExplicit = $AutoRestartWasSet.IsPresent -or $PSBoundParameters.ContainsKey("AutoRestart")
$Script:AutoUpdateExplicit = $AutoUpdateWasSet.IsPresent -or $PSBoundParameters.ContainsKey("AutoUpdate")
$Script:RemoteServerIdExplicit = $RemoteServerIdWasSet.IsPresent -or $PSBoundParameters.ContainsKey("RemoteServerId")

function Write-Log {
    param([string]$Message, [switch]$ErrorMessage)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    if ($ErrorMessage) {
        Write-Host $line -ForegroundColor Red
    } else {
        Write-Host $line
    }
    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }
    Add-Content -Path $Script:LogFile -Value $line -Encoding ASCII
}

function Ask-String {
    param([string]$Prompt, [string]$Default = "")
    if ($Default -ne "") {
        $answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer
    }
    return (Read-Host $Prompt)
}

function Ask-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $label = if ($Default) { "Y/n" } else { "y/N" }
    while ($true) {
        $answer = Read-Host "$Prompt [$label]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host "Type yes or no."
    }
}

function Convert-SecureStringToPlainText {
    param([securestring]$SecureValue)
    if ($null -eq $SecureValue) { return "" }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = "",
        [string]$DisplayArguments = ""
    )
    $argLine = if ($DisplayArguments) { $DisplayArguments } else { $Arguments -join " " }
    Write-Log "Running: $FilePath $argLine"
    $pushedLocation = $false
    $exitCode = $null
    if ($WorkingDirectory) {
        Push-Location -LiteralPath $WorkingDirectory
        $pushedLocation = $true
    }
    try {
        # Discard the native command's stdout rather than letting it flow onto
        # this function's output stream: callers such as New-AgentServiceWrapper
        # capture that stream as their own return value (e.g. $serviceWrapper =
        # New-AgentServiceWrapper, which calls Reset-ManagedFileAcl -> here), and
        # leaked icacls.exe/schtasks.exe stdout text would silently get appended
        # into that captured value, corrupting downstream command lines built
        # from it (observed: icacls "Successfully processed 1 files..." text
        # spliced into the cygrunsrv -a argument).
        & $FilePath @Arguments | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        if ($pushedLocation) {
            Pop-Location
        }
    }
    if ($null -eq $exitCode) {
        throw "Command did not return a native exit code: $FilePath $argLine"
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $argLine"
    }
}

function Reset-ManagedFileAcl {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Managed file does not exist: $Path"
    }

    Invoke-Checked -FilePath "icacls.exe" -Arguments @($Path, "/reset") -DisplayArguments ('"{0}" /reset' -f $Path)
    Write-Log "Reset inherited ACLs for managed file $Path"
}

function Convert-ToUnixLineEndings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File does not exist for line-ending normalization: $Path"
    }

    $content = [System.IO.File]::ReadAllText($Path)
    $normalized = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($normalized -eq $content) {
        Write-Log "Unix line endings already normalized for $Path"
        return
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
    Write-Log "Normalized Unix line endings for $Path"
}

function Write-Utf8NoBomLfFile {
    param([string]$Path, [string[]]$Lines)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $content = ($Lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
}

function Invoke-ScChecked {
    param([string[]]$Arguments)
    $argLine = $Arguments -join " "
    Write-Log "Running: sc.exe $argLine"
    $result = Invoke-NativeCapture -FilePath "sc.exe" -Arguments $Arguments
    $outputText = Get-NativeCaptureText -Result $result
    foreach ($line in ($outputText -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log "sc.exe: $line"
        }
    }
    if ($result.ExitCode -ne 0) {
        throw "sc.exe $argLine failed with exit code $($result.ExitCode)"
    }
    return $outputText
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = "",
        [string]$DisplayArguments = ""
    )

    $argLine = if ($DisplayArguments) { $DisplayArguments } else { $Arguments -join " " }
    Write-Log "Running: $FilePath $argLine"
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $pushedLocation = $false
    $exitCode = $null
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        if ($WorkingDirectory) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushedLocation = $true
        }
        $ErrorActionPreference = "Continue"
        & $FilePath @Arguments > $stdout 2> $stderr
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)
            StdErr = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($pushedLocation) {
            Pop-Location
        }
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-NativeCaptureText {
    param([object]$Result)
    return "$($Result.StdErr)$($Result.StdOut)"
}

function Test-CygrunsrvServiceExists {
    param([string]$Cygrunsrv, [string]$Name)

    $query = Invoke-NativeCapture -FilePath $Cygrunsrv -Arguments @("-Q", $Name)
    $queryText = Get-NativeCaptureText -Result $query
    if ($query.ExitCode -eq 0) {
        return $true
    }
    if ($queryText -match '(?i)(Win32 error 1060|specified service does not exist|does not exist as an installed service)') {
        Write-Log "Service $Name is not registered with cygrunsrv."
        return $false
    }

    $message = $queryText.Trim()
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "<no output>"
    }
    throw "Could not query service $Name with cygrunsrv. cygrunsrv exit code $($query.ExitCode): $message"
}

function Invoke-CygrunsrvChecked {
    param([string]$Cygrunsrv, [string[]]$Arguments)

    $result = Invoke-NativeCapture -FilePath $Cygrunsrv -Arguments $Arguments
    $outputText = Get-NativeCaptureText -Result $result
    if ($result.ExitCode -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            Write-Host $outputText.Trim()
        }
        return
    }

    $message = $outputText.Trim()
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "<no output>"
    }
    throw "cygrunsrv $($Arguments -join ' ') failed with exit code $($result.ExitCode): $message"
}

function Wait-ServiceStopped {
    param([string]$Name, [int]$TimeoutSeconds = 45)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            return $true
        }
        if ($service.Status -eq "Stopped") {
            return $true
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-ServiceAbsent {
    param([string]$Name, [int]$TimeoutSeconds = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            return $true
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Stop-CygrunsrvServiceForRemoval {
    param([string]$Cygrunsrv, [string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Log "Service $Name is not registered with Windows Services."
        return
    }
    if ($service.Status -eq "Stopped") {
        Write-Log "Service $Name is already stopped."
        return
    }

    Write-Log "Stopping service $Name before removal. Current state: $($service.Status)."
    try {
        Invoke-CygrunsrvChecked -Cygrunsrv $Cygrunsrv -Arguments @("-E", $Name)
    } catch {
        Write-Log "cygrunsrv stop failed for $Name; trying sc.exe stop. $($_.Exception.Message)"
        $stop = Invoke-NativeCapture -FilePath "sc.exe" -Arguments @("stop", $Name)
        if ($stop.ExitCode -ne 0 -and (Get-NativeCaptureText -Result $stop) -notmatch '(?i)(not been started|already stopped|1062)') {
            throw "Could not stop service $Name. sc.exe exit code $($stop.ExitCode): $((Get-NativeCaptureText -Result $stop).Trim())"
        }
    }

    if (-not (Wait-ServiceStopped -Name $Name -TimeoutSeconds 60)) {
        $query = Invoke-NativeCapture -FilePath "sc.exe" -Arguments @("queryex", $Name)
        throw "Service $Name did not stop before replacement. Current queryex output: $((Get-NativeCaptureText -Result $query).Trim())"
    }
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-InstallFolders {
    foreach ($path in @($InstallPath, $Script:LogDir, (Join-Path $InstallPath "backups"))) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Assert-NotReparsePoint {
    param([string]$Path, [string]$Description)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to operate on reparse point for ${Description}: $Path"
    }
}

function Get-StatePreservationMap {
    $applicationItems = @(
        "Cfg",
        "ServerFiles",
        "Schedule",
        "screenlogs",
        "startups",
        "runtime_status",
        "events",
        "tmp",
        "shared",
        "steamcmd",
        "logs",
        "agent_core_update_request.json",
        "agent_core_update_state.json",
        "agent_core_update.log"
    )

    $map = @()
    foreach ($appDir in @($Script:ApplicationDirName, $Script:LegacyApplicationDirName)) {
        foreach ($item in $applicationItems) {
            $map += [pscustomobject]@{
                Source = Join-Path $appDir $item
                Target = Join-Path $Script:ApplicationDirName $item
            }
        }
    }

    foreach ($item in @("etc\passwd", "etc\group", "etc\pureftpd.passwd", "etc\pureftpd.pdb", "home", "logs", "backups")) {
        $map += [pscustomobject]@{ Source = $item; Target = $item }
    }
    return $map
}

function Preserve-LocalState {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $preserveRoot = Join-Path $env:TEMP "gse-agent-preserve-$stamp"
    $saved = @()
    $savedTargets = @{}
    foreach ($entry in (Get-StatePreservationMap)) {
        if ($savedTargets.ContainsKey($entry.Target)) {
            continue
        }
        $source = Join-Path $InstallPath $entry.Source
        if (Test-Path -LiteralPath $source) {
            Assert-NotReparsePoint -Path $source -Description "local state $($entry.Source)"
            $target = Join-Path $preserveRoot $entry.Target
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
            $saved += [pscustomobject]@{ Source = (Join-Path $InstallPath $entry.Target); Target = $target; Relative = $entry.Target }
            $savedTargets[$entry.Target] = $true
            Write-Log "Preserved local state: $($entry.Source) -> $($entry.Target)"
        }
    }
    return $saved
}

function Restore-LocalState {
    param([array]$SavedItems)
    foreach ($entry in $SavedItems) {
        if (Test-Path -LiteralPath $entry.Target) {
            if ($entry.Relative -eq "AgentScripts\steamcmd") {
                if (Test-Path -LiteralPath $entry.Source) {
                    Assert-NotReparsePoint -Path $entry.Source -Description "restore target $($entry.Relative)"
                } else {
                    New-Item -ItemType Directory -Path $entry.Source -Force | Out-Null
                }
                Get-ChildItem -LiteralPath $entry.Target -Force | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $entry.Source -Recurse -Force
                }
                Write-Log "Merged preserved local state over bundled SteamCMD bootstrap: $($entry.Relative)"
                continue
            }
            if (Test-Path -LiteralPath $entry.Source) {
                Assert-NotReparsePoint -Path $entry.Source -Description "restore target $($entry.Relative)"
                Remove-Item -LiteralPath $entry.Source -Recurse -Force
            }
            New-Item -ItemType Directory -Path (Split-Path $entry.Source -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $entry.Target -Destination $entry.Source -Recurse -Force
            Write-Log "Restored local state: $($entry.Relative)"
        }
    }
    if ($SavedItems.Count -gt 0) {
        $root = Split-Path $SavedItems[0].Target -Parent
        while ($root -and (Split-Path $root -Leaf) -notlike "gse-agent-preserve-*") {
            $root = Split-Path $root -Parent
        }
        if ($root -and (Test-Path $root)) {
            Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Backup-ApplicationTrees {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupRoot = Join-Path $env:TEMP "gse-agent-app-tree-rollback-$stamp"
    $backups = @()
    foreach ($dirName in @($Script:ApplicationDirName, $Script:LegacyApplicationDirName)) {
        $source = Join-Path $InstallPath $dirName
        if (Test-Path -LiteralPath $source) {
            Assert-NotReparsePoint -Path $source -Description "application tree $dirName"
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            $target = Join-Path $backupRoot $dirName
            Move-Item -LiteralPath $source -Destination $target -Force
            $backups += [pscustomobject]@{ Source = $source; Target = $target; Name = $dirName }
            Write-Log "Moved existing application tree to rollback staging: $dirName"
        }
    }
    return $backups
}

function Restore-ApplicationTreeBackups {
    param([array]$Backups)
    foreach ($dirName in @($Script:ApplicationDirName, $Script:LegacyApplicationDirName)) {
        $current = Join-Path $InstallPath $dirName
        if (Test-Path -LiteralPath $current) {
            Remove-Item -LiteralPath $current -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($entry in $Backups) {
        if (Test-Path -LiteralPath $entry.Target) {
            Move-Item -LiteralPath $entry.Target -Destination $entry.Source -Force
            Write-Log "Restored application tree rollback copy: $($entry.Name)"
        }
    }
}

function Remove-ApplicationTreeBackups {
    param([array]$Backups)
    foreach ($entry in $Backups) {
        if (Test-Path -LiteralPath $entry.Target) {
            Remove-Item -LiteralPath $entry.Target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($Backups.Count -gt 0) {
        $root = Split-Path $Backups[0].Target -Parent
        if ($root -and (Test-Path -LiteralPath $root)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PayloadManifestPath {
    param([string]$Root)
    return (Join-Path $Root "AgentScripts\install_payload_manifest.txt")
}

function Get-RequiredPayloadFiles {
    param([string]$Root, [string]$ManifestRoot = "")
    if ([string]::IsNullOrWhiteSpace($ManifestRoot)) {
        $ManifestRoot = $Root
    }
    $manifestPath = Get-PayloadManifestPath -Root $ManifestRoot
    if (-not (Test-Path $manifestPath)) {
        throw "Payload manifest is missing. Expected AgentScripts\install_payload_manifest.txt under $ManifestRoot."
    }
    $files = Get-Content -LiteralPath $manifestPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
    if (-not $files -or $files.Count -eq 0) {
        throw "Payload manifest at $manifestPath does not list any required files."
    }
    return $files
}

function Assert-CompleteLocalSource {
    param([string]$Root, [string]$ManifestRoot = "")
    if (-not (Test-Path $Root -PathType Container)) {
        throw "Installed payload path does not exist or is not a directory: $Root"
    }
    $requiredFiles = Get-RequiredPayloadFiles -Root $Root -ManifestRoot $ManifestRoot
    $missing = @()
    foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $Root $relativePath
        if (-not (Test-Path $path -PathType Leaf)) {
            $missing += $relativePath
        }
    }
    if ($missing.Count -gt 0) {
        throw "Installed payload is incomplete under $Root. Missing required files: $($missing -join ', ')"
    }
}

function Assert-CompletePayloadSource {
    param([string]$Root)
    Assert-NotReparsePoint -Path $Root -Description "payload source"
    Assert-CompleteLocalSource -Root $Root
    foreach ($relativePath in @(
        "Installer-Agent-Windows.cmd",
        "Installer-Agent-Windows.ps1",
        "AgentScripts\install_payload_manifest.txt",
        "AgentScripts\agent_launch.sh",
        "AgentScripts\perl_env.sh",
        "AgentScripts\agent_core.pl"
    )) {
        $path = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Payload source is incomplete. Missing $relativePath under $Root."
        }
    }
}

function Copy-PayloadRoot {
    param([string]$SourceRoot, [string]$DestinationRoot)
    Get-ChildItem -LiteralPath $SourceRoot -Force | Where-Object { $_.Name -ne ".git" } | ForEach-Object {
        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to copy reparse point from payload source: $($_.FullName)"
        }
        Copy-Item -LiteralPath $_.FullName -Destination $DestinationRoot -Recurse -Force
    }
}

function Sync-StagedPayload {
    param([string]$SourceRoot)

    $resolvedSource = [System.IO.Path]::GetFullPath($SourceRoot)
    $resolvedInstall = [System.IO.Path]::GetFullPath($InstallPath)
    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) {
        throw "Payload source path is not a directory: $resolvedSource"
    }
    if ($resolvedSource.Equals($resolvedInstall, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "Payload source is already the install directory; staged activation is not required."
        return
    }

    $installPrefix = $resolvedInstall.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $sourcePrefix = $resolvedSource.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedSource.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Payload source path resolves inside the install destination."
    }
    if ($resolvedInstall.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Install destination resolves inside the payload source and would recursively copy itself."
    }

    Assert-CompletePayloadSource -Root $resolvedSource
    $saved = Preserve-LocalState
    $appBackups = @()
    try {
        Remove-AgentService
        $appBackups = Backup-ApplicationTrees
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Copy-PayloadRoot -SourceRoot $resolvedSource -DestinationRoot $InstallPath
        Restore-LocalState -SavedItems $saved
        Assert-CompleteLocalSource -Root $InstallPath
        if (Test-Path -LiteralPath (Join-Path $InstallPath $Script:LegacyApplicationDirName)) {
            throw "Legacy application tree still exists after staged activation: $(Join-Path $InstallPath $Script:LegacyApplicationDirName)"
        }
        Remove-ApplicationTreeBackups -Backups $appBackups
        Write-Log "Activated complete AgentScripts payload from $resolvedSource"
    } catch {
        Write-Log "Staged payload activation failed; restoring previous application tree. $($_.Exception.Message)" -ErrorMessage
        Restore-ApplicationTreeBackups -Backups $appBackups
        throw
    }
}

function Test-InstallPathHasSeed {
    param([string]$ManifestRoot = "")
    try {
        Assert-CompleteLocalSource -Root $InstallPath -ManifestRoot $ManifestRoot
        return $true
    } catch {
        return $false
    }
}

function Assert-BundledRuntime {
    param([string]$ManifestRoot = "")
    $requiredFiles = Get-RequiredPayloadFiles -Root $InstallPath -ManifestRoot $ManifestRoot
    foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $InstallPath $relativePath
        if (-not (Test-Path $path)) {
            throw "Installed payload is incomplete. Missing $relativePath under $InstallPath."
        }
    }
    Write-Log "Verified installed payload and bundled runtime files."
}

function Repair-CygwinSymlinkMarkers {
    # Cygwin's default (non-native) symlinks are plain files containing the
    # literal bytes "!<symlink>target\0" plus the Windows FILE_ATTRIBUTE_SYSTEM
    # flag; Cygwin's runtime only treats a file as a symlink when that
    # attribute is set. PowerShell's Expand-Archive (used by the CMD
    # bootstrap and by hand here) does not restore that attribute on
    # extraction, so every bundled Cygwin symlink (bin\awk -> gawk.exe, and
    # many others) silently becomes an inert text file. Programs that exec
    # it then fail with "Exec format error" instead of following the link.
    # Restore the attribute on any small file whose content still carries
    # the Cygwin symlink magic so the bundled runtime works after a fresh
    # extraction.
    $magic = [byte[]][System.Text.Encoding]::ASCII.GetBytes("!<symlink>")
    $fixed = 0
    Get-ChildItem -LiteralPath $InstallPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 -and $_.Length -le 1024 -and ($_.Attributes -band [System.IO.FileAttributes]::System) -eq 0 } |
        ForEach-Object {
            $head = New-Object byte[] $magic.Length
            $stream = [System.IO.File]::OpenRead($_.FullName)
            try {
                $read = $stream.Read($head, 0, $head.Length)
            } finally {
                $stream.Close()
            }
            if ($read -eq $magic.Length) {
                $matches = $true
                for ($i = 0; $i -lt $magic.Length; $i++) {
                    if ($head[$i] -ne $magic[$i]) { $matches = $false; break }
                }
                if ($matches) {
                    $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::System
                    $fixed++
                }
            }
        }
    if ($fixed -gt 0) {
        Write-Log "Restored the Cygwin symlink attribute on $fixed file(s) stripped by archive extraction."
    }
}

function Initialize-RuntimeDirectories {
    foreach ($relativePath in @("tmp", "var\run", "AgentScripts\tmp")) {
        $path = Join-Path $InstallPath $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-Log "Created runtime directory $path"
        }
    }
}

function Prepare-CygwinLaunchEnvironment {
    Initialize-RuntimeDirectories

    $bash = Join-Path $InstallPath "bin\bash.exe"
    $launchScript = Join-Path $InstallPath "AgentScripts\agent_launch.sh"
    $perlEnvScript = Join-Path $InstallPath "AgentScripts\perl_env.sh"
    $agentFile = Join-Path $InstallPath "AgentScripts\agent_core.pl"
    if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { throw "Missing bundled bash.exe at $bash" }
    if (-not (Test-Path -LiteralPath $launchScript -PathType Leaf)) { throw "Missing launcher script at $launchScript" }
    if (-not (Test-Path -LiteralPath $perlEnvScript -PathType Leaf)) { throw "Missing bundled Perl environment script at $perlEnvScript" }
    if (-not (Test-Path -LiteralPath $agentFile -PathType Leaf)) { throw "Missing Perl agent at $agentFile" }

    foreach ($managedFile in @($launchScript, $perlEnvScript, $agentFile)) {
        Reset-ManagedFileAcl -Path $managedFile
        Convert-ToUnixLineEndings -Path $managedFile
    }

    $cygwinCommand = "mkdir -p /tmp /var/run /AgentScripts/tmp"
    Invoke-Checked -FilePath $bash -Arguments @("-lc", $cygwinCommand)
    Write-Log "Prepared Cygwin runtime directories and managed script files."
}

function Test-LocalSystemAccount {
    param([string]$AccountName)
    return ($AccountName -match '^(LocalSystem|SYSTEM|NT AUTHORITY\\SYSTEM)$')
}

function Resolve-AgentAccountName {
    if ($Script:AgentAccountResolved) {
        return
    }
    if (-not $Script:AgentUserExplicit) {
        $Script:AgentAccountName = Ask-String "Agent Windows user" $Script:AgentAccountName
    }
    if ([string]::IsNullOrWhiteSpace($Script:AgentAccountName)) {
        throw "Agent Windows user cannot be blank."
    }
    $Script:AgentAccountResolved = $true
    Write-Log "Service account=$Script:AgentAccountName"
}

function Get-AdministratorsGroupName {
    $sid = New-Object System.Security.Principal.SecurityIdentifier "S-1-5-32-544"
    $account = $sid.Translate([System.Security.Principal.NTAccount]).Value
    return ($account -split "\\")[-1]
}

function Ensure-AgentAccount {
    Resolve-AgentAccountName
    $accountName = $Script:AgentAccountName

    if (Test-LocalSystemAccount $accountName) {
        Write-Log "Using LocalSystem service account."
        return ""
    }

    $securePassword = Read-Host "Password for Windows service account '$accountName'" -AsSecureString
    $plainPassword = Convert-SecureStringToPlainText $securePassword
    if ([string]::IsNullOrWhiteSpace($plainPassword)) {
        throw "A password is required when using a named service account."
    }

    $localUser = Get-LocalUser -Name $accountName -ErrorAction SilentlyContinue
    if ($null -ne $localUser) {
        Write-Log "Updating existing Windows account $accountName"
        Set-LocalUser -Name $accountName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires $true
        Enable-LocalUser -Name $accountName
    } else {
        Write-Log "Creating Windows account $accountName"
        New-LocalUser -Name $accountName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires | Out-Null
        Enable-LocalUser -Name $accountName
    }

    $localUser = Get-LocalUser -Name $accountName -ErrorAction Stop
    $adminGroup = Get-AdministratorsGroupName
    $isAdmin = Get-LocalGroupMember -Group $adminGroup -ErrorAction Stop | Where-Object { $_.SID -eq $localUser.SID } | Select-Object -First 1
    if (-not $isAdmin) {
        Add-LocalGroupMember -Group $adminGroup -Member "$env:COMPUTERNAME\$accountName"
        Write-Log "Added $accountName to local Administrators."
    } else {
        Write-Log "$accountName is already a local Administrator."
    }

    $ntrights = Join-Path $InstallPath "tools\ntrights.exe"
    if (Test-Path $ntrights) {
        & $ntrights +r SeServiceLogonRight -u $accountName | Out-Null
        Write-Log "Granted Log on as a service to $accountName"
    } else {
        Write-Log "tools\ntrights.exe not found; grant Log on as a service to $accountName if service registration fails."
    }

    & icacls.exe $InstallPath /grant "${accountName}:(OI)(CI)F" /T /C | Out-Null
    return $plainPassword
}

function Remove-LegacyScheduledTasks {
    $schtasks = Join-Path $env:SystemRoot "System32\schtasks.exe"
    if (-not (Test-Path $schtasks)) {
        Write-Log "schtasks.exe not found; skipping legacy scheduled task cleanup."
        return
    }

    foreach ($taskName in @("GSP Windows Agent", "\GSP Windows Agent")) {
        $query = Invoke-NativeCapture -FilePath $schtasks -Arguments @("/Query", "/TN", $taskName)
        $queryText = "$($query.StdErr)$($query.StdOut)"
        if ($query.ExitCode -eq 0) {
            Write-Log "Removing legacy scheduled task '$taskName'; the agent is managed by Windows Services."
            Invoke-Checked -FilePath $schtasks -Arguments @("/Delete", "/TN", $taskName, "/F")
        } elseif ($queryText -match '(?i)(cannot find|not found|does not exist)') {
            Write-Log "Legacy scheduled task '$taskName' is not present."
        } else {
            throw "Could not query legacy scheduled task '$taskName'. schtasks.exe exit code $($query.ExitCode): $($queryText.Trim())"
        }
    }
}

function Write-AgentConfiguration {
    $cfgDir = Join-Path $InstallPath "AgentScripts\Cfg"
    if (-not (Test-Path $cfgDir)) {
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    }

    $configFile = Join-Path $cfgDir "Config.pm"
    $prefsFile = Join-Path $cfgDir "Preferences.pm"
    $bashPrefsFile = Join-Path $cfgDir "bash_prefs.cfg"

    $overwrite = $true
    if (Test-Path $configFile) {
        $overwrite = Ask-YesNo "Overwrite existing agent configuration files?" $false
    }
    if (-not $overwrite) {
        Write-Log "Preserving existing configuration files."
        return
    }

    Write-Host ""
    Write-Host "GSE Windows Agent configuration"
    Write-Host "Use values from Panel -> Administration -> Game Servers for this remote server."
    Write-Host ""

    # Canonical guided prompt order (mirrors the GSE Linux agent installer's
    # actual order: install.sh asks the agent user first, then agent_conf.sh
    # asks key, listen IP, listen port, panel API URL, remote server ID,
    # FTP management, auto-restart, auto-update):
    #   1. Agent Windows user (resolved here so it prompts first, matching
    #      install.sh; the Windows account itself is created later by
    #      Ensure-AgentAccount)
    #   2. Agent key / shared secret
    #   3. Listen IP
    #   4. Listen port
    #   5. Panel API URL
    #   6. Remote server ID (only needed when the Panel cannot supply it)
    #   7. FTP management yes/no, and method when yes
    #   8. Auto-restart crashed servers yes/no
    #   9. Auto-update yes/no
    # Everything else below is flag-only with a sensible default; pass the
    # matching parameter to override it without being prompted.

    Resolve-AgentAccountName

    if ($Script:AgentKeyExplicit) {
        $key = $AgentKey
    } else {
        $key = Ask-String "Agent key/shared secret" $AgentKey
    }
    if ([string]::IsNullOrWhiteSpace($key)) { throw "Agent key/shared secret is required." }

    if ($Script:ListenIpExplicit) {
        $listenIp = $ListenIp
    } else {
        $listenIp = Ask-String "Listen IP" $ListenIp
    }

    if ($Script:ListenPortExplicit) {
        $listenPort = $ListenPort
    } else {
        $listenPort = Ask-String "Listen port" $ListenPort
    }

    if ($Script:PanelApiUrlExplicit) {
        $webApiUrl = $PanelApiUrl
    } else {
        $webApiUrl = Ask-String "Panel API URL, usually https://panel.example.com/api.php" $PanelApiUrl
    }

    if ($Script:RemoteServerIdExplicit) {
        $remoteServerId = $RemoteServerId
    } else {
        $remoteServerId = Ask-String "Panel remote server ID, leave blank if the Panel supplies it automatically" $RemoteServerId
    }

    if ($Script:FtpManagedExplicit) {
        $manageFtpBool = ($FtpManaged -eq "1")
    } else {
        $manageFtpBool = Ask-YesNo "Manage FTP accounts?" ($FtpManaged -eq "1")
    }
    $manageFtp = if ($manageFtpBool) { "1" } else { "0" }
    if ($manageFtpBool) {
        if ($Script:FtpMethodExplicit) {
            $ftpMethod = $FtpMethod
        } else {
            $ftpMethod = Ask-String "FTP method" $FtpMethod
        }
    } else {
        $ftpMethod = $FtpMethod
    }

    if ($Script:AutoRestartExplicit) {
        $autoRestartBool = ($AutoRestart -eq "1")
    } else {
        $autoRestartBool = Ask-YesNo "Automatically restart crashed game servers?" ($AutoRestart -eq "1")
    }
    $autoRestart = if ($autoRestartBool) { "1" } else { "0" }

    if ($Script:AutoUpdateExplicit) {
        $autoUpdateBool = ($AutoUpdate -eq "1")
    } else {
        $autoUpdateBool = Ask-YesNo "Enable restart-time release patch updates?" ($AutoUpdate -eq "1")
    }
    $autoUpdate = if ($autoUpdateBool) { "1" } else { "0" }

    $steamLicense = $SteamLicense
    $screenLogLocal = $ScreenLogLocal
    $deleteLogsAfter = $DeleteLogsAfterDays
    $shutdownWait = $ProtocolShutdownWaitSeconds
    $homeAclIsolation = $HomeAclIsolation
    $portValidation = $PortValidationEnabled
    $startupTimeout = $StartupValidationTimeoutSeconds
    $portCheckInterval = $PortCheckIntervalSeconds
    $updateMetadataUrl = if ([string]::IsNullOrWhiteSpace($UpdateMetadataUrl)) { $Script:DefaultUpdateMetadataUrl } else { $UpdateMetadataUrl }
    $runPureFtpd = if ([string]::IsNullOrWhiteSpace($RunPureFtpd)) { $manageFtp } else { $RunPureFtpd }
    $ftpPort = $FtpPort
    $ftpIp = $FtpIp
    $ftpPasv = $FtpPasvRange

    $configLines = @(
        "%Cfg::Config = (",
        "`tlogfile => '/AgentScripts/agent_core.log',",
        "`tlisten_port => '$listenPort',",
        "`tlisten_ip => '$listenIp',",
        "`tversion => 'v1.4',",
        "`tkey => '$key',",
        "`tsteam_license => '$steamLicense',",
        "`tweb_api_url => '$webApiUrl',",
        "`tremote_server_id => '$remoteServerId',",
        ");",
        "",
        "1;"
    )
    Set-Content -Path $configFile -Value $configLines -Encoding ASCII

    $prefsLines = @(
        "%Cfg::Preferences = (",
        "`tscreen_log_local => '$screenLogLocal',",
        "`tdelete_logs_after => '$deleteLogsAfter',",
        "`tmanages_ftp => '$manageFtp',",
        "`tftp_method => '$ftpMethod',",
        "`tautorestart_server => '$autoRestart',",
        "`tprotocol_shutdown_waittime => '$shutdownWait',",
        "`twindows_home_acl_isolation => '$homeAclIsolation',",
        "`tPortValidationEnabled => '$portValidation',",
        "`tStartupValidationTimeoutSeconds => '$startupTimeout',",
        "`tPortCheckIntervalSeconds => '$portCheckInterval',",
        ");",
        "",
        "1;"
    )
    Set-Content -Path $prefsFile -Value $prefsLines -Encoding ASCII

    $bashLines = @(
        "agent_auto_update=$autoUpdate",
        "agent_update_metadata_url=$updateMetadataUrl",
        "agent_update_patch_url=",
        "agent_update_patch_sha256=",
        "agent_update_source_version=",
        "agent_update_target_version=",
        "agent_update_manifest_url=",
        "agent_update_manifest_sha256=",
        "run_pureftpd=$runPureFtpd",
        "ftp_port=$ftpPort",
        "ftp_ip=$ftpIp",
        "ftp_pasv_range=$ftpPasv"
    )
    Set-Content -Path $bashPrefsFile -Value $bashLines -Encoding ASCII
    Write-Log "Wrote agent configuration under $cfgDir"
}

function Validate-AgentSyntax {
    $bash = Join-Path $InstallPath "bin\bash.exe"
    if (-not (Test-Path $bash)) { throw "Missing bundled bash.exe at $bash" }
    $cygwinCommand = "cd /AgentScripts && . ./perl_env.sh && perl_preflight && perl -c ./agent_core.pl"
    Invoke-Checked -FilePath $bash -Arguments @("-lc", $cygwinCommand)
}

function New-AgentServiceWrapper {
    $wrapper = Join-Path $InstallPath "AgentScripts\agent_service_wrapper.sh"
    $wrapperLines = @(
        "#!/usr/bin/env bash",
        "cd /AgentScripts || exit 1",
        "exec /bin/bash /AgentScripts/agent_launch.sh service"
    )
    Write-Utf8NoBomLfFile -Path $wrapper -Lines $wrapperLines
    Reset-ManagedFileAcl -Path $wrapper
    Convert-ToUnixLineEndings -Path $wrapper
    Write-Log "Generated service wrapper at $wrapper"
    return "/AgentScripts/agent_service_wrapper.sh"
}

function Redact-DiagnosticText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $redacted = $Text -replace '(?i)(-w\s+)(\S+)', '$1<redacted>'
    $redacted = $redacted -replace '(?i)(password\s*[=:]\s*)(\S+)', '$1<redacted>'
    $redacted = $redacted -replace '(?i)(pass\s*[=:]\s*)(\S+)', '$1<redacted>'
    return $redacted
}

function Write-DiagnosticBlock {
    param([string]$Title, [string]$Content)
    $safeContent = Redact-DiagnosticText -Text $Content
    if ([string]::IsNullOrWhiteSpace($safeContent)) {
        $safeContent = "<no output>"
    }
    Write-Log "${Title}:"
    foreach ($line in ($safeContent -split "`r?`n")) {
        Write-Log "  $line"
    }
}

function Capture-FileTail {
    param([string]$Path, [int]$Lines = 80)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return "File not found: $Path"
    }
    return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue) -join "`n")
}

function Write-ServiceStartupDiagnostics {
    param([string]$Reason)

    Write-Log "Collecting service startup diagnostics for $ServiceName. Reason: $Reason" -ErrorMessage
    foreach ($args in @(
        @("queryex", $ServiceName),
        @("qc", $ServiceName)
    )) {
        $result = Invoke-NativeCapture -FilePath "sc.exe" -Arguments $args
        Write-DiagnosticBlock -Title ("sc.exe " + ($args -join " ")) -Content (Get-NativeCaptureText -Result $result)
    }

    $cygrunsrv = Join-Path $InstallPath "bin\cygrunsrv.exe"
    if (Test-Path -LiteralPath $cygrunsrv -PathType Leaf) {
        $result = Invoke-NativeCapture -FilePath $cygrunsrv -Arguments @("-V", "-Q", $ServiceName)
        Write-DiagnosticBlock -Title "cygrunsrv -V -Q $ServiceName" -Content (Get-NativeCaptureText -Result $result)
    } else {
        Write-Log "cygrunsrv.exe not found at $cygrunsrv"
    }

    foreach ($relativePath in @(
        "AgentScripts\agent_core_service.out.log",
        "AgentScripts\agent_core_service.err.log",
        "AgentScripts\agent_core.log"
    )) {
        $path = Join-Path $InstallPath $relativePath
        Write-DiagnosticBlock -Title "Tail $relativePath" -Content (Capture-FileTail -Path $path)
    }
}

function Verify-AgentServiceConfiguration {
    $escapedServiceName = $ServiceName.Replace("'", "''")
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedServiceName'" -ErrorAction Stop
    if (-not $service) {
        throw "Service $ServiceName was not found after registration."
    }
    if ($service.StartMode -ne "Auto") {
        throw "Service $ServiceName StartMode is '$($service.StartMode)', expected 'Auto'."
    }

    $configOutput = Invoke-ScChecked -Arguments @("qc", $ServiceName)
    if ($configOutput -notmatch "AUTO_START") {
        throw "Service $ServiceName is not configured for Automatic startup."
    }

    $failureOutput = Invoke-ScChecked -Arguments @("qfailure", $ServiceName)
    $restartActions = ([regex]::Matches($failureOutput, "RESTART")).Count
    if ($restartActions -lt 3) {
        throw "Service $ServiceName recovery actions are not configured for three restart attempts."
    }

    $failureFlagOutput = Invoke-ScChecked -Arguments @("qfailureflag", $ServiceName)
    if ($failureFlagOutput -notmatch "(?i)(:\s*1|:\s*TRUE\b)") {
        throw "Service $ServiceName recovery is not enabled for non-crash failures."
    }

    Write-Log "Verified service startup and recovery behavior for $ServiceName."
}

function Register-AgentService {
    param([string]$PlainPassword)
    $cygrunsrv = Join-Path $InstallPath "bin\cygrunsrv.exe"
    if (-not (Test-Path $cygrunsrv)) { throw "Missing cygrunsrv.exe at $cygrunsrv" }

    Remove-LegacyScheduledTasks

    if (Test-CygrunsrvServiceExists -Cygrunsrv $cygrunsrv -Name $ServiceName) {
        Write-Log "Removing existing service $ServiceName"
        Stop-CygrunsrvServiceForRemoval -Cygrunsrv $cygrunsrv -Name $ServiceName
        Invoke-CygrunsrvChecked -Cygrunsrv $cygrunsrv -Arguments @("-R", $ServiceName)
        if (-not (Wait-ServiceAbsent -Name $ServiceName -TimeoutSeconds 60)) {
            $query = Invoke-NativeCapture -FilePath "sc.exe" -Arguments @("queryex", $ServiceName)
            throw "Service $ServiceName was removed but is still visible to Windows. It may be marked for deletion: $((Get-NativeCaptureText -Result $query).Trim())"
        }
    }

    $serviceWrapper = New-AgentServiceWrapper
    $arguments = @(
        "-I", $ServiceName,
        "-d", $ServiceDisplayName,
        "-p", "/bin/bash",
        "-a", $serviceWrapper,
        "-c", "/AgentScripts",
        "-o",
        "-1", "/AgentScripts/agent_core_service.out.log",
        "-2", "/AgentScripts/agent_core_service.err.log",
        "-e", "CYGWIN=server ntsec",
        "-y", "tcpip"
    )

    if (-not (Test-LocalSystemAccount $Script:AgentAccountName)) {
        $arguments += @("-u", "$env:COMPUTERNAME\$Script:AgentAccountName", "-w", $PlainPassword)
    }

    Write-Log "Registering service $ServiceName with cygrunsrv"
    $displayArgs = ($arguments | ForEach-Object { if ($_ -eq $PlainPassword) { "<redacted>" } else { $_ } }) -join " "
    Write-Log "Service command: $cygrunsrv $displayArgs"
    Invoke-Checked -FilePath $cygrunsrv -Arguments $arguments -DisplayArguments $displayArgs

    Invoke-ScChecked -Arguments @("config", $ServiceName, "start=", "auto") | Out-Null
    Invoke-ScChecked -Arguments @("failure", $ServiceName, "reset=", "86400", "actions=", "restart/60000/restart/60000/restart/300000") | Out-Null
    Invoke-ScChecked -Arguments @("failureflag", $ServiceName, "1") | Out-Null
    Verify-AgentServiceConfiguration
    Invoke-CygrunsrvChecked -Cygrunsrv $cygrunsrv -Arguments @("-V", "-Q", $ServiceName)
}

function Ensure-FirewallRule {
    param([string]$RuleName, [string]$Port)
    if ([string]::IsNullOrWhiteSpace($Port)) {
        return
    }
    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Firewall rule '$RuleName' already present for TCP port $Port."
        return
    }
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
    Write-Log "Created inbound firewall rule '$RuleName' allowing TCP port $Port."
}

function Ensure-AgentFirewallRules {
    # Windows Firewall blocks unsolicited inbound connections by default for
    # any listener without an explicit allow rule, even though the agent
    # itself binds 0.0.0.0 and answers fine over loopback. Without this, the
    # Panel (or any other remote caller) sees the TCP handshake succeed but
    # never gets a response - cygrunsrv/the Perl agent are never involved,
    # so nothing in their logs shows the problem.
    Ensure-FirewallRule -RuleName "GSE Windows Agent ($ServiceName)" -Port $ListenPort
    if ($FtpManaged -eq "1") {
        Ensure-FirewallRule -RuleName "GSE Windows Agent FTP ($ServiceName)" -Port $FtpPort
    }
}

function Start-AgentService {
    Write-Log "Starting service $ServiceName"
    Invoke-ScChecked -Arguments @("start", $ServiceName) | Out-Host
    $deadline = (Get-Date).AddSeconds(180)
    $lastState = ""
    do {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        if ($service.Status -eq "Running") {
            Write-Log "Verified service $ServiceName is running."
            return
        }
        if ($lastState -ne $service.Status.ToString()) {
            $lastState = $service.Status.ToString()
            Write-Log "Service $ServiceName state is $lastState; waiting for Running."
        }
        if ($service.Status -eq "Stopped") {
            Write-ServiceStartupDiagnostics -Reason "Service stopped during startup polling."
            throw "Service $ServiceName stopped before reaching Running state."
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    Write-ServiceStartupDiagnostics -Reason "Service did not reach Running within 180 seconds."
    throw "Service $ServiceName did not reach Running state within 180 seconds."
}

function Remove-AgentService {
    Remove-LegacyScheduledTasks

    $cygrunsrv = Join-Path $InstallPath "bin\cygrunsrv.exe"
    if (Test-Path $cygrunsrv) {
        if (Test-CygrunsrvServiceExists -Cygrunsrv $cygrunsrv -Name $ServiceName) {
            Write-Log "Stopping and removing service $ServiceName"
            Stop-CygrunsrvServiceForRemoval -Cygrunsrv $cygrunsrv -Name $ServiceName
            Invoke-CygrunsrvChecked -Cygrunsrv $cygrunsrv -Arguments @("-R", $ServiceName)
            if (-not (Wait-ServiceAbsent -Name $ServiceName -TimeoutSeconds 60)) {
                $query = Invoke-NativeCapture -FilePath "sc.exe" -Arguments @("queryex", $ServiceName)
                throw "Service $ServiceName was removed but is still visible to Windows. It may be marked for deletion: $((Get-NativeCaptureText -Result $query).Trim())"
            }
            return
        }
    }

    $query = Invoke-NativeCapture -FilePath "sc.exe" -Arguments @("query", $ServiceName)
    if ($query.ExitCode -eq 0) {
        Write-Log "Removing Windows service $ServiceName with sc.exe"
        $stop = Invoke-NativeCapture -FilePath "sc.exe" -Arguments @("stop", $ServiceName)
        if ($stop.ExitCode -ne 0 -and (Get-NativeCaptureText -Result $stop) -notmatch '(?i)(not been started|already stopped|1062)') {
            throw "Could not stop service $ServiceName with sc.exe. Exit code $($stop.ExitCode): $((Get-NativeCaptureText -Result $stop).Trim())"
        }
        if (-not (Wait-ServiceStopped -Name $ServiceName -TimeoutSeconds 60)) {
            throw "Service $ServiceName did not stop before sc.exe delete."
        }
        Invoke-ScChecked -Arguments @("delete", $ServiceName) | Out-Null
        if (-not (Wait-ServiceAbsent -Name $ServiceName -TimeoutSeconds 60)) {
            throw "Service $ServiceName is still visible after sc.exe delete."
        }
    } else {
        Write-Log "Service $ServiceName is not registered."
    }
}

function Invoke-InstallOrRepair {
    Initialize-InstallFolders
    if (-not [string]::IsNullOrWhiteSpace($PayloadSourcePath)) {
        Sync-StagedPayload -SourceRoot $PayloadSourcePath
    }
    Assert-BundledRuntime
    Repair-CygwinSymlinkMarkers
    Prepare-CygwinLaunchEnvironment
    $password = Ensure-AgentAccount
    Write-AgentConfiguration
    Validate-AgentSyntax
    Register-AgentService -PlainPassword $password
    Ensure-AgentFirewallRules
    Start-AgentService
}

function Invoke-Reconfigure {
    $manifestRoot = $InstallPath
    if (-not [string]::IsNullOrWhiteSpace($PayloadSourcePath)) {
        $manifestRoot = [System.IO.Path]::GetFullPath($PayloadSourcePath)
        Assert-CompletePayloadSource -Root $manifestRoot
        Write-Log "Using reconfigure payload manifest from $manifestRoot"
    }
    if (-not (Test-InstallPathHasSeed -ManifestRoot $manifestRoot)) {
        throw "$InstallPath is not a valid installed GSE Windows Agent payload."
    }
    Assert-BundledRuntime -ManifestRoot $manifestRoot
    Repair-CygwinSymlinkMarkers
    Prepare-CygwinLaunchEnvironment
    $password = Ensure-AgentAccount
    Write-AgentConfiguration
    Validate-AgentSyntax
    Register-AgentService -PlainPassword $password
    Ensure-AgentFirewallRules
    Start-AgentService
}

function Invoke-Uninstall {
    Remove-AgentService
    if (Ask-YesNo "Remove installed agent files at $InstallPath? Customer homes/config/logs are left by default when you answer no." $false) {
        $saved = Preserve-LocalState
        $backupParent = Split-Path $InstallPath -Parent
        $backup = Join-Path $backupParent ("gse-agent-uninstall-preserved-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($entry in $saved) {
            if (Test-Path $entry.Target) {
                $relative = $entry.Source.Substring($InstallPath.Length).TrimStart('\')
                $target = Join-Path $backup $relative
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item -Path $entry.Target -Destination $target -Recurse -Force
            }
        }
        Remove-Item -Path $InstallPath -Recurse -Force
        Write-Host "Preserved local state backup: $backup"
    }
}

if (-not (Test-Admin)) {
    throw "Run this installer from an elevated PowerShell session."
}

Write-Log "GSE Windows Agent $Mode"
Write-Log "InstallPath=$InstallPath"
Write-Log "ServiceName=$ServiceName"
if (-not [string]::IsNullOrWhiteSpace($PayloadSourcePath)) {
    Write-Log "PayloadSourcePath=$PayloadSourcePath"
}

switch ($Mode) {
    "Install" { Invoke-InstallOrRepair }
    "Repair" { Invoke-InstallOrRepair }
    "Reconfigure" { Invoke-Reconfigure }
    "Uninstall" { Invoke-Uninstall }
}

Write-Log "GSE Windows Agent $Mode complete."
