# start_hidden.ps1 - starts one process with no window and prints its PID.
# Output goes to <WorkDir>\<OutBase>.out and .err, so the process does not
# hold the caller's console or pipe handles open.
#
# This uses Win32_Process.Create (WMI) instead of Start-Process. Start-Process
# (System.Diagnostics.Process) inherits ALL of the caller's inheritable
# handles, not just the ones it explicitly redirects -- when the caller is
# itself a child of an SSH session, the hidden process ends up holding a
# duplicate handle to the SSH channel's own stdout pipe. The SSH command
# never sees EOF and hangs forever, even after the launcher process exits.
# Win32_Process.Create runs via the WMI provider host, so the new process
# tree is not forked from the caller at all and inherits nothing from it.
# Redirection is done with cmd.exe's own shell redirection (which handles
# NUL correctly, unlike Start-Process -RedirectStandardInput).
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [string]$Args = "",
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [string]$OutBase = ""
)
if ($OutBase -eq "") { $OutBase = [System.IO.Path]::GetFileNameWithoutExtension($Exe) }
$outFile = Join-Path $WorkDir "$OutBase.out"
$errFile = Join-Path $WorkDir "$OutBase.err"
$exeName = [System.IO.Path]::GetFileName($Exe)

# A CommandLine with several quoted segments ("cmd.exe /c ""exe" args > "out" ...")
# hits cmd.exe's ambiguous /c quote-stripping heuristic: it sometimes leaves
# the leading quote stuck to the program name ('"exe"' is not recognized...),
# intermittently, depending on the exact string. Side-step this by writing
# the real command into its own .cmd file (one quoted segment per line, no
# nesting) and pointing cmd.exe /c at that single quoted path instead.
$launcherFile = Join-Path $WorkDir "$OutBase.launch.cmd"
@"
@echo off
"$Exe" $Args > "$outFile" 2> "$errFile" < NUL
"@ | Set-Content -Path $launcherFile -Encoding ASCII
$cmdLine = "cmd.exe /c `"$launcherFile`""

# Unlike Start-Process, Win32_Process.Create does not inherit the caller's
# environment by default -- it gets the WMI provider host's own environment.
# Pass the caller's current environment through explicitly so things like
# the watchdog's CHECK_SECONDS/BACKOFF_* test overrides still reach it.
$envList = Get-ChildItem Env: | ForEach-Object { "$($_.Name)=$($_.Value)" }
$startupInfo = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{
  EnvironmentVariables = [string[]]$envList
}

$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
  CommandLine               = $cmdLine
  CurrentDirectory          = $WorkDir
  ProcessStartupInformation = $startupInfo
}
if ($result.ReturnValue -ne 0) {
  Write-Error "Win32_Process.Create failed with code $($result.ReturnValue)"
  exit 1
}

# $result.ProcessId is cmd.exe's PID. Find the real exe among its children
# (cmd.exe may also spawn a conhost.exe child; skip that one).
#
# Under deep nesting (a WMI-created process itself making another
# Win32_Process.Create call -- e.g. the watchdog, started hidden, starting
# the game hidden) this lookup has been observed to occasionally take
# noticeably longer than a shallow call, and the launcher cmd.exe can exit
# almost immediately if the real exe failed to start at all. Poll longer
# than the shallow case needs, and bail out early -- as an explicit
# failure, not a silent fallback -- the moment the launcher itself is gone,
# since no child will ever appear after that.
$deadline = (Get-Date).AddSeconds(8)
$target = $null
$launcherAlive = $true
while (-not $target -and $launcherAlive -and (Get-Date) -lt $deadline) {
  $target = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($result.ProcessId) AND Name='$exeName'"
  if (-not $target) {
    Start-Sleep -Milliseconds 100
    $launcherAlive = [bool](Get-CimInstance Win32_Process -Filter "ProcessId=$($result.ProcessId)")
  }
}
if ($target) {
  Write-Output $target.ProcessId
} elseif ($launcherAlive) {
  # Exe may be named differently than expected but the launcher is still
  # up. Fall back to cmd.exe's own PID: taskkill /T on it still reaches
  # the child.
  Write-Output $result.ProcessId
} else {
  # The launcher exited before any child was ever observed: the real exe
  # never started (or failed instantly). Returning a PID here would make
  # the caller believe it has a live process when it does not. Report
  # failure explicitly so the caller can retry instead of recording a
  # false crash.
  Write-Error "start_hidden: launcher exited before '$exeName' appeared as its child (see $errFile)"
  exit 2
}
