# GSE Windows Agent installer (Windows 10 / Windows Server 2016 or newer).
#
# Before you run it: on the panel, open Administration > Servers and add this machine
# (IP, agent port, an agent key of up to 16 characters, and the agent user). The agent
# is not running yet, so the panel saves the server and waits for this installer.
#
# Put this file in the folder the agent should live in (C:\GSE by default) and run, in an
# elevated (Administrator) PowerShell:
#   powershell -ExecutionPolicy Bypass -File C:\GSE\gse-agent-windows-install.ps1
#
# It asks for the panel address, the agent key and the agent user's password, gets the
# server's settings from the panel, downloads the agent release the panel's update
# settings pick (Cygwin is bundled in it), unpacks it to <folder>\Agent, creates the
# agent user, writes the agent configuration, registers and starts the Windows service
# and tells the panel the agent is ready. Another agent already on this machine is not
# touched: this one gets its own folder, service name and settings.
#
# Options: -Panel URL  -Key KEY  -Path FOLDER  -Zip FILE  -Password PASSWORD
param(
    [string]$Panel = "",
    [string]$Key = "",
    [string]$Path = "",
    [string]$Zip = "",
    [string]$Password = ""
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Repo = "GameServerEngine/gse-agent-windows"

function Say([string]$Text) { Write-Host "==> $Text" }
function Fail([string]$Text) { Write-Host "ERROR: $Text" -ForegroundColor Red; exit 1 }
function Ask([string]$Question, [string]$Default = "") {
    $suffix = if ($Default) { " [$Default]" } else { "" }
    $answer = Read-Host "$Question$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default } else { return $answer.Trim() }
}
function AskSecret([string]$Question) {
    $secure = Read-Host $Question -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail "Run this installer in an elevated (Administrator) PowerShell." }

# ---------- folder ----------
if (-not $Path) {
    $Path = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\GSE" }
    $Path = Ask "Install the agent under this folder" $Path
}
$Path = $Path.TrimEnd('\')
$AgentDir = Join-Path $Path "Agent"
$CfgDir = Join-Path $AgentDir "AgentScripts\Cfg"
if ((Test-Path "$CfgDir\Config.pm") -and (Select-String -Path "$CfgDir\Config.pm" -Pattern "remote_server_id => '[0-9]" -Quiet)) {
    Fail "An agent is already installed in $AgentDir. Update it from the panel."
}

# ---------- panel ----------
if (-not $Panel) { $Panel = Ask "Panel address (as you open it in a browser)" }
if (-not $Panel) { Fail "The panel address is required." }
if ($Panel -notmatch '^https?://') { $Panel = "http://$Panel" }
$Panel = $Panel.TrimEnd('/') -replace '/(index|home)\.php$', ''
if (-not $Key) { $Key = AskSecret "Agent key from the panel's Servers page" }
if (-not $Key) { Fail "The agent key is required." }

# Signed request to the panel's agent_enroll.php (see that file). Returns the parsed reply.
function PanelCall([string]$Step) {
    $body = '{"step":"' + $Step + '","os":"windows"}'
    $ts = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $hmac = New-Object Security.Cryptography.HMACSHA256 (,[Text.Encoding]::UTF8.GetBytes($Key))
    $sig = -join ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ts.$body")) | ForEach-Object { $_.ToString("x2") })
    $request = [Net.HttpWebRequest]::Create("$Panel/agent_enroll.php")
    $request.Method = "POST"; $request.ContentType = "application/json"; $request.Timeout = 60000
    $request.Headers.Add("X-GSE-Timestamp", $ts); $request.Headers.Add("X-GSE-Signature", "sha256=$sig")
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    try {
        $stream = $request.GetRequestStream(); $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
        $response = $request.GetResponse()
    } catch [Net.WebException] {
        $response = $_.Exception.Response
        if (-not $response) { Fail "Could not reach the panel at $Panel ($($_.Exception.Message))." }
    }
    $code = [int]$response.StatusCode
    $text = (New-Object IO.StreamReader($response.GetResponseStream())).ReadToEnd()
    $response.Close()
    $reply = $null; try { $reply = $text | ConvertFrom-Json } catch { }
    if ($code -eq 200 -and $reply) { return $reply }
    if ($code -eq 401 -and $reply.error -eq "unknown_key") { Fail "The panel has no server with this agent key. Add this machine on the panel's Servers page first." }
    if ($code -eq 401 -and $reply.error -eq "bad_timestamp") { Fail "This machine's clock differs from the panel's by more than 5 minutes. Fix the time and run again." }
    if ($code -eq 404) { Fail "$Panel/agent_enroll.php was not found. Check the panel address, and that the panel is up to date." }
    Fail "The panel answered HTTP ${code}: $text"
}

Say "Asking the panel for this server's settings"
$Config = PanelCall "config"
$ServerId = [string]$Config.remote_server_id
$AgentUser = if ($Config.user) { [string]$Config.user } else { "gameserver" }
$AgentPort = [string]$Config.agent_port
$FtpPort = if ($Config.ftp_port) { [string]$Config.ftp_port } else { "21" }
if ($ServerId -notmatch '^\d+$' -or $AgentPort -notmatch '^\d+$') { Fail "The panel's answer is incomplete." }
if ($AgentUser -notmatch '^[A-Za-z0-9_.-]{1,20}$') { Fail "The agent user '$AgentUser' set on the panel is not a valid Windows user name." }
Say "Panel server $ServerId ($($Config.name)): agent user $AgentUser, port $AgentPort"

$LocalIps = @(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $_.IPAddress })
$ListenIp = if ($LocalIps -contains [string]$Config.agent_ip) { [string]$Config.agent_ip } else { "0.0.0.0" }
$FtpIp = if ($LocalIps -contains [string]$Config.ftp_ip) { [string]$Config.ftp_ip } else { "0.0.0.0" }
# Listeners on $Port that this agent's address would clash with.
function Listeners([string]$Ip, [string]$Port) {
    return @(Get-NetTCPConnection -State Listen -LocalPort ([int]$Port) -ErrorAction SilentlyContinue |
        Where-Object { $Ip -eq "0.0.0.0" -or $_.LocalAddress -eq "0.0.0.0" -or $_.LocalAddress -eq $Ip })
}
if ((Listeners $ListenIp $AgentPort).Count -gt 0) { Fail "Port $AgentPort is already in use on this machine. Give this server another agent port on the panel's Servers page." }

# ---------- agent user ----------
$existingUser = Get-LocalUser -Name $AgentUser -ErrorAction SilentlyContinue
if (-not $Password) {
    $Password = AskSecret "Password for the Windows user $AgentUser (created if missing)"
    if (-not $existingUser -and $Password -ne (AskSecret "Type the password again")) { Fail "The passwords do not match." }
}
if (-not $Password) { Fail "A password is required: the agent service runs as this user." }
if ($existingUser) {
    # An existing user's password is checked, never changed: another service may use it.
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $context = New-Object DirectoryServices.AccountManagement.PrincipalContext([DirectoryServices.AccountManagement.ContextType]::Machine)
    if (-not $context.ValidateCredentials($AgentUser, $Password)) { Fail "That is not the password of the existing user $AgentUser." }
}

# ---------- release ----------
$Work = Join-Path $Path "_gse_install_tmp"
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$ZipFile = Join-Path $Work "agent.zip"
if ($Zip) {
    if (-not (Test-Path $Zip)) { Fail "ZIP file not found: $Zip" }
    Copy-Item $Zip $ZipFile
    Say "Using local ZIP $Zip"
} else {
    $Url = [string]$Config.release.url; $SumUrl = [string]$Config.release.sha256_url
    if (-not $Url) {
        Say "The panel did not name a release; looking on GitHub"
        $api = "https://api.github.com/repos/$Repo/releases"
        $Url = ""
        try {
            $latest = Invoke-RestMethod "$api/latest" -UseBasicParsing
            $names = @($latest.assets | ForEach-Object { $_.name })
            $zipAsset = $latest.assets | Where-Object { $_.name -like "*.zip" -and $names -contains "$($_.name).sha256" } | Select-Object -First 1
            if ($zipAsset) { $Url = $zipAsset.browser_download_url }
        } catch { }
        if (-not $Url) {
            $testing = Invoke-RestMethod "$api`?per_page=30" -UseBasicParsing | Where-Object { $_.tag_name -like "testing-*" } | Select-Object -First 1
            if ($testing) { $Url = ($testing.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1).browser_download_url }
        }
        $SumUrl = "$Url.sha256"
    }
    if (-not $Url) { Fail "Could not find an agent release." }
    Say "Downloading $Url (about 400 MB)"
    (New-Object Net.WebClient).DownloadFile($Url, $ZipFile)
    $expected = ((New-Object Net.WebClient).DownloadString($SumUrl).Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $ZipFile -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Fail "Checksum mismatch. Nothing was installed." }
    Say "Checksum OK"
}

Say "Unpacking to $AgentDir"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, "$Work\x")
$top = @(Get-ChildItem "$Work\x")
$src = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { "$Work\x" }
if (-not (Test-Path "$src\bin\bash.exe") -or -not (Test-Path "$src\AgentScripts\agent_core.pl")) { Fail "The ZIP does not contain the Windows agent." }
if (Test-Path $AgentDir) {
    Copy-Item "$src\*" $AgentDir -Recurse -Force
} else {
    Move-Item $src $AgentDir
}
Remove-Item $Work -Recurse -Force

# Zip extraction drops the System attribute that marks Cygwin symlinks (small files that
# start with "!<symlink>"). Without it bin\awk and others stop working; put it back.
$magic = [Text.Encoding]::ASCII.GetBytes("!<symlink>")
Get-ChildItem $AgentDir -Recurse -File -Force | Where-Object { $_.Length -gt 0 -and $_.Length -le 1024 } | ForEach-Object {
    $head = New-Object byte[] $magic.Length
    $fs = [IO.File]::OpenRead($_.FullName)
    try { $n = $fs.Read($head, 0, $head.Length) } finally { $fs.Close() }
    if ($n -eq $magic.Length -and [Text.Encoding]::ASCII.GetString($head) -eq "!<symlink>") {
        $_.Attributes = $_.Attributes -bor [IO.FileAttributes]::System
    }
}
foreach ($dir in "tmp", "var\run", "AgentScripts\tmp") { New-Item -ItemType Directory -Path "$AgentDir\$dir" -Force | Out-Null }

# ---------- user ----------
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
if (-not $existingUser) {
    Say "Creating the Windows user $AgentUser"
    New-LocalUser -Name $AgentUser -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -Description "GSE agent" | Out-Null
}
$adminGroup = (New-Object Security.Principal.SecurityIdentifier "S-1-5-32-544").Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
$user = Get-LocalUser -Name $AgentUser
if (-not (Get-LocalGroupMember -Group $adminGroup | Where-Object { $_.SID -eq $user.SID })) {
    Add-LocalGroupMember -Group $adminGroup -Member $AgentUser
}
& "$AgentDir\tools\ntrights.exe" +r SeServiceLogonRight -u $AgentUser | Out-Null
& icacls.exe $AgentDir /grant "${AgentUser}:(OI)(CI)F" /T /C /Q | Out-Null

# ---------- configuration ----------
$ServiceName = "GSPAgent"
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { $ServiceName = "GSPAgent-$ServerId" }
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { Fail "A Windows service named $ServiceName already exists." }
function PerlQuote([string]$Text) { return $Text.Replace('\', '\\').Replace("'", "\'") }
function WriteLf([string]$File, [string[]]$Lines) {
    [IO.File]::WriteAllText($File, (($Lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}
$version = (Get-Content "$AgentDir\VERSION" -ErrorAction SilentlyContinue | Select-Object -First 1)
WriteLf "$CfgDir\Config.pm" @(
    "%Cfg::Config = (",
    "`tlogfile => '/AgentScripts/agent_core.log',",
    "`tlisten_port => '$AgentPort',",
    "`tlisten_ip => '$ListenIp',",
    "`tversion => '$(PerlQuote $version)',",
    "`tkey => '$(PerlQuote $Key)',",
    "`tsteam_license => 'Accept',",
    "`tweb_api_url => '$(PerlQuote $Panel)/api.php',",
    "`tagent_event_url => '$(PerlQuote $Panel)/agent_event_receiver.php',",
    "`tremote_server_id => '$ServerId',",
    "`tservice_name => '$ServiceName',",
    ");", "", "1;")
Copy-Item "$CfgDir\Preferences.pm.default" "$CfgDir\Preferences.pm" -Force
WriteLf "$CfgDir\bash_prefs.cfg" @(
    "agent_auto_update=0",
    "run_pureftpd=1",
    "ftp_port=$FtpPort",
    "ftp_ip=$FtpIp",
    "ftp_pasv_range=")
WriteLf "$AgentDir\AgentScripts\agent_service_wrapper.sh" @(
    "#!/usr/bin/env bash",
    "cd /AgentScripts || exit 1",
    "exec /bin/bash /AgentScripts/agent_launch.sh service")

Say "Checking the bundled Perl and the agent"
& "$AgentDir\bin\bash.exe" -lc "cd /AgentScripts && . ./perl_env.sh && perl_preflight && perl -c ./agent_core.pl"
if ($LASTEXITCODE -ne 0) { Fail "The agent did not pass its startup check (see the output above)." }

# ---------- service ----------
Say "Registering the Windows service $ServiceName"
& "$AgentDir\bin\cygrunsrv.exe" -I $ServiceName -d "GSE Windows Agent ($ServerId)" -p /bin/bash -a /AgentScripts/agent_service_wrapper.sh `
    -c /AgentScripts -o -1 /AgentScripts/agent_core_service.out.log -2 /AgentScripts/agent_core_service.err.log `
    -e "CYGWIN=server ntsec" -y tcpip -u "$env:COMPUTERNAME\$AgentUser" -w $Password
if ($LASTEXITCODE -ne 0) { Fail "cygrunsrv could not register the service $ServiceName." }
& sc.exe config $ServiceName start= auto | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
& sc.exe failureflag $ServiceName 1 | Out-Null

foreach ($port in $AgentPort, $FtpPort) {
    $rule = "GSE Windows Agent $ServiceName TCP $port"
    if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port | Out-Null
    }
}

Say "Starting $ServiceName"
Start-Service $ServiceName
Say "Waiting for the agent to listen on port $AgentPort (can take a minute)"
$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline -and (Listeners $ListenIp $AgentPort).Count -eq 0) {
    if ((Get-Service $ServiceName).Status -eq "Stopped") { break }
    Start-Sleep -Seconds 3
}
if ((Listeners $ListenIp $AgentPort).Count -eq 0) {
    Fail "The agent did not start. See $AgentDir\AgentScripts\agent_core.log and agent_core_service.err.log."
}

Say "Telling the panel the agent is ready"
$Done = PanelCall "done"
Write-Host ""
if ($Done.online) {
    Write-Host "The agent is installed and the panel reached it (service $ServiceName, folder $AgentDir)."
    Write-Host "IP addresses on the panel: $(@($Done.ips) -join ', ')"
} else {
    Write-Host "The agent is installed and running (service $ServiceName), but the panel could not reach it at $($Config.agent_ip):$AgentPort."
    Write-Host "Check firewalls between the panel and this machine, then open the panel's Servers page."
}
