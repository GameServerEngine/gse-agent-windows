#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap_base="Installer-Agent-Windows"
legacy_bootstrap_base="$(printf 'Install-%s-WindowsAgent' 'GSE')"
cmd_file="$repo_root/${bootstrap_base}.cmd"
bat_file="$repo_root/${bootstrap_base}.bat"
ps_file="$repo_root/Installer-Agent-Windows.ps1"
start_file="$repo_root/agent_start.bat"
launch_file="$repo_root/AgentScripts/agent_launch.sh"
perl_env_file="$repo_root/AgentScripts/perl_env.sh"
payload_manifest="$repo_root/AgentScripts/install_payload_manifest.txt"
steamcmd_bootstrap="$repo_root/AgentScripts/steamcmd/steamcmd.exe"
prefs_template="$repo_root/AgentScripts/Cfg/bash_prefs.cfg.default"
release_version_file="$repo_root/AgentScripts/release_version.json"
release_manifest_file="$repo_root/AgentScripts/release_manifest.json"
release_builder="$repo_root/tools/build_windows_agent_release.sh"
default_zip_url="https://git.runlevelsystems.com/GSE/Agent-Windows/archive/unstable.zip"
default_metadata_url="https://git.runlevelsystems.com/GSE/Agent-Windows/releases/download/stable/gse-windows-agent-latest.json"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

require_absent_file() {
    [ ! -e "$1" ] || fail "unexpected file exists: $1"
}

require_text() {
    local file="$1"
    local pattern="$2"
    grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in ${file#$repo_root/}"
}

require_absent() {
    local file="$1"
    local pattern="$2"
    if grep -Fq -- "$pattern" "$file"; then
        fail "unexpected '$pattern' in ${file#$repo_root/}"
    fi
}

count_text() {
    local file="$1"
    local pattern="$2"
    grep -Fo -- "$pattern" "$file" | wc -l | tr -d ' '
}

line_number() {
    local file="$1"
    local pattern="$2"
    grep -nF -- "$pattern" "$file" | head -n 1 | cut -d: -f1
}

assert_no_same_block_percent_reference() {
    local file="$1"
    local var_name="$2"

    perl -Mstrict -Mwarnings - "$file" "$var_name" <<'PERL' || fail "CMD bootstrap assigns and percent-references $var_name inside the same parenthesized block"
my ($file, $var_name) = @ARGV;
open my $fh, '<', $file or die "open $file: $!";
my @stack;
while (my $line = <$fh>) {
    my $opens = () = $line =~ /\(/g;
    for (1 .. $opens) {
        push @stack, '';
    }
    for my $index (0 .. $#stack) {
        $stack[$index] .= $line;
    }
    my $closes = () = $line =~ /\)/g;
    for (1 .. $closes) {
        my $block = pop @stack;
        next if !defined $block;
        if ($block =~ /set\s+"?\Q$var_name\E\s*=/i && $block =~ /%\Q$var_name\E%/i) {
            exit 1;
        }
    }
}
exit 0;
PERL
}

assert_crlf_only() {
    local file="$1"
    local label="${file#$repo_root/}"
    local stats bytes crlf bare_lf bare_cr ends_crlf

    stats="$(perl -0777 -ne '$crlf=()=/\r\n/g; $barelf=()=/(?<!\r)\n/g; $barecr=()=/\r(?!\n)/g; $bytes=length($_); $ends=/\r\n\z/ ? 1 : 0; print "$bytes $crlf $barelf $barecr $ends\n"' "$file")"
    read -r bytes crlf bare_lf bare_cr ends_crlf <<< "$stats"

    [ "$crlf" -gt 0 ] || fail "$label must use CRLF line endings"
    [ "$bare_lf" -eq 0 ] || fail "$label contains bare LF line endings"
    [ "$bare_cr" -eq 0 ] || fail "$label contains bare CR characters"
    [ "$ends_crlf" -eq 1 ] || fail "$label must end with a CRLF line ending"
}

assert_no_legacy_installer_references() {
    local stale_name matches

    for stale_name in "${legacy_bootstrap_base}.cmd" "${legacy_bootstrap_base}.ps1"; do
    if matches="$(git -C "$repo_root" grep -nF -- "$stale_name" -- . ':(exclude).devplus/**' ':(exclude)docs/codex-history/**' ':(exclude)docs/agent-modernization-step-1-divergence-report.md' 2>/dev/null)"; then
            printf '%s\n' "$matches" >&2
            fail "stale installer filename remains outside docs/codex-history: $stale_name"
        fi
    done

    local legacy_install_base
    legacy_install_base="$(printf 'Install-%s-WindowsAgent' 'GSP')"
    for stale_name in "${legacy_install_base}.cmd" "${legacy_install_base}.ps1"; do
        if matches="$(git -C "$repo_root" grep -nF -- "$stale_name" -- . ':(exclude).devplus/**' ':(exclude)docs/codex-history/**' ':(exclude)docs/agent-modernization-step-1-divergence-report.md' 2>/dev/null)"; then
            printf '%s\n' "$matches" >&2
            fail "stale installer filename remains outside historical records: $stale_name"
        fi
    done
}

assert_native_capture_error_action_guard() {
    perl -Mstrict -Mwarnings - "$ps_file" <<'PERL' || fail "Invoke-NativeCapture must temporarily relax ErrorActionPreference around direct native stderr capture and restore it"
my ($file) = @ARGV;
open my $fh, '<', $file or die "open $file: $!";
local $/;
my $text = <$fh>;
my ($body) = $text =~ /(function Invoke-NativeCapture \{.*?^function Test-Admin \{)/ms;
exit 1 if !defined $body;
exit 1 if $body =~ /Start-Process|ArgumentList/;
my $save = index($body, '$previousErrorActionPreference = $ErrorActionPreference');
my $continue = index($body, '$ErrorActionPreference = "Continue"');
my $invoke = index($body, '& $FilePath @Arguments > $stdout 2> $stderr');
my $exit = index($body, '$exitCode = $LASTEXITCODE');
my $finally = index($body, '} finally {');
my $restore = index($body, '$ErrorActionPreference = $previousErrorActionPreference');
exit 1 if grep { $_ < 0 } ($save, $continue, $invoke, $exit, $finally, $restore);
exit 1 unless $save < $continue && $continue < $invoke && $invoke < $exit;
exit 1 unless $exit < $finally && $finally < $restore;
exit 0;
PERL
}

assert_cygrunsrv_absent_service_handling() {
    perl -Mstrict -Mwarnings - "$ps_file" <<'PERL' || fail "cygrunsrv service queries must safely treat Win32 1060 as an absent service"
my ($file) = @ARGV;
open my $fh, '<', $file or die "open $file: $!";
local $/;
my $text = <$fh>;
exit 1 if $text =~ /&\s+\$cygrunsrv\s+-(?:Q|E|R|V)\b/;
for my $required (
    'function Test-CygrunsrvServiceExists',
    'Invoke-NativeCapture -FilePath $Cygrunsrv -Arguments @("-Q", $Name)',
    'Win32 error 1060',
    'specified service does not exist',
    'does not exist as an installed service',
    'Could not query service $Name with cygrunsrv',
    'function Invoke-CygrunsrvChecked',
    'function Stop-CygrunsrvServiceForRemoval',
    'Test-CygrunsrvServiceExists -Cygrunsrv $cygrunsrv -Name $ServiceName',
    'Stop-CygrunsrvServiceForRemoval -Cygrunsrv $cygrunsrv -Name $ServiceName',
    'Invoke-CygrunsrvChecked -Cygrunsrv $Cygrunsrv -Arguments @("-E", $Name)',
    'Invoke-CygrunsrvChecked -Cygrunsrv $cygrunsrv -Arguments @("-R", $ServiceName)',
    'Invoke-CygrunsrvChecked -Cygrunsrv $cygrunsrv -Arguments @("-V", "-Q", $ServiceName)',
	) {
	    exit 1 if index($text, $required) < 0;
	}
	exit 0;
PERL
}

assert_hardened_startup_contracts() {
    perl -Mstrict -Mwarnings - "$ps_file" "$launch_file" "$repo_root/AgentScripts/agent_core.pl" "$repo_root/AgentScripts/Cfg/Config.pm.default" <<'PERL' || fail "Windows service, launcher, config, FTP, and SteamCMD startup contracts regressed"
my ($ps_file, $launch_file, $agent_file, $config_default) = @ARGV;
sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "open $file: $!";
    local $/;
    return <$fh>;
}
my $ps = slurp($ps_file);
my $launch = slurp($launch_file);
my $agent = slurp($agent_file);
my $cfg = slurp($config_default);

for my $required (
    'function New-AgentServiceWrapper',
    '"#!/usr/bin/env bash"',
    '"cd /AgentScripts || exit 1"',
    '"exec /bin/bash /AgentScripts/agent_launch.sh service"',
    'Write-Utf8NoBomLfFile -Path $wrapper -Lines $wrapperLines',
    'Reset-ManagedFileAcl -Path $wrapper',
    '"-p", "/bin/bash"',
    '"-a", $serviceWrapper',
    'Wait-ServiceAbsent -Name $ServiceName -TimeoutSeconds 60',
    'Write-ServiceStartupDiagnostics -Reason "Service did not reach Running within 180 seconds."',
    '@("queryex", $ServiceName)',
    '@("qc", $ServiceName)',
    '@("-V", "-Q", $ServiceName)',
    'AgentScripts\agent_core_service.out.log',
    'AgentScripts\agent_core_service.err.log',
    'AgentScripts\agent_core.log',
    '(?i)(:\s*1|:\s*TRUE\b)'
) {
    die "missing PS contract $required\n" if index($ps, $required) < 0;
}
die "nested cygrunsrv -lc service arguments remain\n" if $ps =~ /serviceBashArguments|-lc "cd \/AgentScripts && \.\/agent_launch\.sh service"/;
die "Config generation still writes obsolete fields\n" if $ps =~ /sudo_password|web_admin_api_key|agent_event_url|steam_dl_limit/;
die "Config generation must write the canonical Panel API URL and remote server ID fields\n" if $ps !~ /web_api_url/ || $ps !~ /remote_server_id/;

for my $required (
    'normalize_text_file_preserving_acl()',
    'open my $input, "<:raw", $file',
    'open my $output, ">:raw", $file',
    'normalize_text_file_preserving_acl "$file" line-endings',
    'normalize_text_file_preserving_acl "$target" line-endings',
    'normalize_text_file_preserving_acl "$PREFS_FILE" preference-assignments',
    'config_value key ""',
    '[ "$key_value" = "CHANGE_ME_PANEL_AGENT_KEY" ]',
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$p=$port; if (Get-NetTCPConnection',
    'continuing without FTP',
    'Pure-FTPd is enabled but $PUREFTPD_BIN is missing',
    'Pure-FTPd did not create a valid PID file',
    'exec perl "$AGENT_FILE" -pidfile "$pidfile" "$@"'
) {
    die "missing launcher contract $required\n" if index($launch, $required) < 0;
}
die "launcher still uses sed -i during startup normalization\n" if $launch =~ /\bsed\s+-i\b/;
die "launcher still uses awk\n" if $launch =~ /\bawk\b/;
die "launcher key validation still greps broad key names\n" if $launch =~ /grep -Eq .*key\[\[:space:\]\]/;

die "global SteamCMD startup gate remains\n" if $agent =~ /if \(check_steam_cmd_client\(\) == -1\)\s*\{\s*print "ERROR: You must download/s;
die "SteamCMD missing directory still exits the agent\n" if $agent =~ /SteamCMD is not installed.*?exit -1/s;
die "SteamCMD downloader still uses HTTP\n" if $agent =~ m{http://media\.steampowered\.com/installer/steamcmd\.zip};
die "SteamCMD helper does not mention bundled bootstrap\n" if index($agent, "payloads bundle the offline bootstrap") < 0;
my $steam_check_count = () = $agent =~ /check_steam_cmd_client\(\)/g;
die "Steam-specific operations do not check availability\n" if $steam_check_count < 2;

for my $obsolete (qw(sudo_password web_admin_api_key agent_event_url steam_dl_limit)) {
    die "obsolete field remains in Config.pm.default: $obsolete\n" if $cfg =~ /\b\Q$obsolete\E\b/;
}
for my $required (qw(web_api_url remote_server_id)) {
    die "Config.pm.default is missing canonical field: $required\n" if $cfg !~ /\b\Q$required\E\b/;
}
die "Config.pm.default missing terminator\n" if $cfg !~ /\n1;\s*\z/;
PERL
}

require_file "$cmd_file"
require_absent_file "$bat_file"
require_absent_file "$repo_root/${legacy_bootstrap_base}.cmd"
require_absent_file "$repo_root/${legacy_bootstrap_base}.ps1"
require_file "$ps_file"
require_file "$start_file"
require_file "$launch_file"
require_file "$perl_env_file"
require_file "$payload_manifest"
require_file "$steamcmd_bootstrap"
require_file "$prefs_template"
require_file "$release_version_file"
require_file "$release_manifest_file"
require_file "$release_builder"
assert_crlf_only "$cmd_file"
assert_crlf_only "$start_file"
assert_no_legacy_installer_references
assert_native_capture_error_action_guard
assert_cygrunsrv_absent_service_handling
assert_hardened_startup_contracts

launcher_basename="agent_launch.sh"
agent_basename="agent_core.pl"
managed_chmod_cygwin="chmod +x /AgentScripts/${launcher_basename} /AgentScripts/${agent_basename}"
managed_chmod_launcher="chmod +x \"\$AGENT_DIR/${launcher_basename}\" \"\$AGENT_FILE\""
managed_sed_cygwin="sed -i 's/\\r\$//' /AgentScripts/${launcher_basename}"

while IFS= read -r relative_path; do
    relative_path="${relative_path%%#*}"
    relative_path="${relative_path#"${relative_path%%[![:space:]]*}"}"
    relative_path="${relative_path%"${relative_path##*[![:space:]]}"}"
    [ -n "$relative_path" ] || continue
    require_file "$repo_root/$relative_path"
done < "$payload_manifest"

for required in \
    "Installer-Agent-Windows.ps1" \
    "Installer-Agent-Windows.cmd" \
    "AgentScripts/agent_core.pl" \
    "AgentScripts/screen_config" \
    "AgentScripts/screen_config_bk" \
    "AgentScripts/agent_launch.sh" \
    "AgentScripts/perl_env.sh" \
    "AgentScripts/steamcmd/steamcmd.exe" \
    "AgentScripts/release_version.json" \
    "AgentScripts/release_manifest.json" \
    "bin/bash.exe" \
    "bin/perl.exe" \
    "usr/share/perl5/5.40/JSON/PP.pm" \
    "lib/perl5/5.40/x86_64-cygwin-threads/Digest/SHA.pm" \
    "usr/share/perl5/vendor_perl/5.40/LWP/UserAgent.pm" \
    "usr/share/perl5/vendor_perl/5.40/LWP.pm" \
    "usr/share/perl5/vendor_perl/5.40/LWP/Protocol.pm" \
    "usr/share/perl5/vendor_perl/5.40/LWP/Protocol/http.pm" \
    "usr/share/perl5/vendor_perl/5.40/LWP/Protocol/https.pm" \
    "usr/share/perl5/vendor_perl/5.40/HTTP/Message.pm" \
    "usr/share/perl5/vendor_perl/5.40/Try/Tiny.pm" \
    "usr/share/perl5/vendor_perl/5.40/Net/HTTP.pm" \
    "usr/share/perl5/vendor_perl/5.40/Net/HTTPS.pm" \
    "usr/share/perl5/vendor_perl/5.40/IO/Socket/SSL.pm" \
    "lib/perl5/vendor_perl/5.40/x86_64-cygwin-threads/HTML/Parser.pm" \
    "lib/perl5/vendor_perl/5.40/x86_64-cygwin-threads/Net/SSLeay.pm" \
    "bin/cygrunsrv.exe" \
    "usr/sbin/pure-ftpd.exe"; do
    require_text "$payload_manifest" "$required"
done
require_absent "$payload_manifest" "bin/git.exe"

for switch_name in "/InstallPath" "/Offline" "/SourcePath" "/ReleaseZipUrl" "/Mode"; do
    require_text "$cmd_file" "$switch_name"
done

require_text "$cmd_file" "set \"RELEASE_ZIP_URL=$default_zip_url\""
require_text "$ps_file" "\$Script:DefaultUpdateMetadataUrl = \"$default_metadata_url\""
require_text "$prefs_template" "agent_update_metadata_url=$default_metadata_url"
require_text "$release_version_file" "\"component\": \"Agent-Windows\""
require_text "$release_manifest_file" "\"component\": \"Agent-Windows\""
require_text "$release_builder" "\"component\": \"Agent-Windows\""
require_absent "$release_version_file" "\"component\": \"GSP-Agent-Windows\""
require_absent "$release_manifest_file" "\"component\": \"GSP-Agent-Windows\""
require_absent "$release_builder" "\"component\": \"GSP-Agent-Windows\""
require_text "$cmd_file" "echo   1. Online current development archive"
require_text "$cmd_file" "echo   2. Offline local payload path"
require_text "$cmd_file" "echo   3. Reconfigure existing installed version"
require_text "$cmd_file" "if /I not \"%AGENT_MODE%\"==\"Uninstall\" if \"%SOURCE_CHOICE%\"==\"3\" set \"AGENT_MODE=Reconfigure\""
require_text "$cmd_file" "ERROR: Choose 1 for online current development archive, 2 for offline local payload path, or 3 to reconfigure the existing installed version."
require_text "$cmd_file" "if /I not \"%AGENT_MODE%\"==\"Reconfigure\" goto after_reconfigure"
require_text "$cmd_file" "echo Reconfiguring existing installation at %INSTALL_PATH%."
require_text "$cmd_file" "if \"%SOURCE_PATH%\"==\"\" if exist \"%BOOTSTRAP_DIR%Installer-Agent-Windows.ps1\" if exist \"%BOOTSTRAP_DIR%AgentScripts\\install_payload_manifest.txt\" set \"SOURCE_PATH=%BOOTSTRAP_DIR%.\""
require_text "$cmd_file" "if not exist \"%INSTALLER_PS%\""
require_absent "$cmd_file" "if not exist \"%INSTALL_PATH%\\AgentScripts\\install_payload_manifest.txt\""
require_text "$cmd_file" "if not exist \"%SOURCE_PATH%\\AgentScripts\\install_payload_manifest.txt\""
require_text "$cmd_file" "if not exist \"%INSTALL_PATH%\\AgentScripts\\agent_launch.sh\""
require_text "$cmd_file" "if not exist \"%INSTALL_PATH%\\AgentScripts\\agent_core.pl\""
require_text "$cmd_file" "goto run_installer"
require_text "$cmd_file" ":run_installer"
require_text "$cmd_file" "set \"DOWNLOAD_WORK=%TEMP%\\gse-agent-unstable-%RANDOM%%RANDOM%\""
require_text "$cmd_file" "set \"DOWNLOAD_ZIP=%DOWNLOAD_WORK%\\unstable.zip\""
require_text "$cmd_file" "set \"DOWNLOAD_EXTRACT=%DOWNLOAD_WORK%\\extract\""
require_text "$cmd_file" "echo Download URL: %RELEASE_ZIP_URL%"
require_text "$cmd_file" "echo Download file: %DOWNLOAD_ZIP%"
require_text "$cmd_file" "where curl.exe"
require_text "$cmd_file" "ERROR: curl.exe was not found."
require_text "$cmd_file" "curl.exe --insecure --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 --output \"%DOWNLOAD_ZIP%\" \"%RELEASE_ZIP_URL%\""
require_text "$cmd_file" "set \"CURL_EXIT=%ERRORLEVEL%\""
require_text "$cmd_file" "echo curl.exe exit code: %CURL_EXIT%"
require_text "$cmd_file" "echo ZIP extraction exit code: %EXTRACT_EXIT%"
require_text "$cmd_file" "echo PowerShell installer exit code: %INSTALL_EXIT%"
require_text "$cmd_file" "Expand-Archive -Path \$zip -DestinationPath \$extract -Force"
require_text "$cmd_file" "Test-PayloadRoot"
require_text "$cmd_file" "Release ZIP did not contain exactly one GSE Windows Agent payload root with Installer-Agent-Windows.cmd and Installer-Agent-Windows.ps1."
require_text "$cmd_file" "Offline source does not contain Installer-Agent-Windows.cmd"
require_text "$cmd_file" "Offline source does not contain Installer-Agent-Windows.ps1"
require_text "$cmd_file" "set \"INSTALLER_PS=%INSTALL_PATH%\\Installer-Agent-Windows.ps1\""
require_text "$cmd_file" "set \"INSTALLER_PS=%SOURCE_PATH%\\Installer-Agent-Windows.ps1\""
require_text "$cmd_file" "if not exist \"%SOURCE_PATH%\\AgentScripts\\install_payload_manifest.txt\""
require_text "$cmd_file" "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%INSTALLER_PS%\" -Mode \"%AGENT_MODE%\" -InstallPath \"%INSTALL_PATH%\" -PayloadSourcePath \"%SOURCE_PATH%\""
require_text "$cmd_file" "if /I \"%AGENT_MODE%\"==\"Reconfigure\" if not \"%SOURCE_PATH%\"==\"\" powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%INSTALLER_PS%\" -Mode \"%AGENT_MODE%\" -InstallPath \"%INSTALL_PATH%\" -PayloadSourcePath \"%SOURCE_PATH%\""
require_text "$cmd_file" "if /I \"%AGENT_MODE%\"==\"Reconfigure\" if \"%SOURCE_PATH%\"==\"\" powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%INSTALLER_PS%\" -Mode \"%AGENT_MODE%\" -InstallPath \"%INSTALL_PATH%\""

[ "$(count_text "$cmd_file" "curl.exe --insecure --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 --output")" -eq 1 ] || fail "CMD bootstrap must contain exactly one curl.exe download path"
require_absent "$cmd_file" "Invoke-WebRequest"
[ "$(count_text "$ps_file" "Invoke-WebRequest")" -eq 0 ] || fail "PowerShell installer must not download payloads"
require_absent "$ps_file" "Start-Process"
require_absent "$ps_file" "ArgumentList"
[ "$(count_text "$ps_file" "& \$FilePath @Arguments")" -eq 2 ] || fail "PowerShell native helpers must invoke executables directly"
require_text "$ps_file" "\$previousErrorActionPreference = \$ErrorActionPreference"
require_text "$ps_file" "\$ErrorActionPreference = \"Continue\""
require_text "$ps_file" "\$ErrorActionPreference = \$previousErrorActionPreference"
require_text "$ps_file" "gse-windows-agent-latest.json"
require_text "$ps_file" "function Reset-ManagedFileAcl"
require_text "$ps_file" "Invoke-Checked -FilePath \"icacls.exe\" -Arguments @(\$Path, \"/reset\")"
require_text "$ps_file" "function Convert-ToUnixLineEndings"
require_text "$ps_file" "New-Object System.Text.UTF8Encoding(\$false)"
require_text "$ps_file" "[string]\$PayloadSourcePath = \"\""
require_text "$ps_file" "\$Script:ApplicationDirName = \"AgentScripts\""
require_text "$ps_file" "\$Script:LegacyApplicationDirName = \"GSP\""
require_text "$ps_file" "function Sync-StagedPayload"
require_text "$ps_file" "Assert-CompletePayloadSource -Root \$resolvedSource"
require_text "$ps_file" "Remove-AgentService"
require_text "$ps_file" "Backup-ApplicationTrees"
require_text "$ps_file" "Copy-PayloadRoot -SourceRoot \$resolvedSource -DestinationRoot \$InstallPath"
require_text "$ps_file" "Restore-LocalState -SavedItems \$saved"
require_text "$ps_file" "Assert-CompleteLocalSource -Root \$InstallPath"
require_text "$ps_file" "Legacy application tree still exists after staged activation"
require_text "$ps_file" "Restore-ApplicationTreeBackups -Backups \$appBackups"
require_text "$ps_file" "Refusing to operate on reparse point"
require_text "$ps_file" "\$perlEnvScript = Join-Path \$InstallPath \"AgentScripts\\perl_env.sh\""
require_text "$ps_file" "foreach (\$managedFile in @(\$launchScript, \$perlEnvScript, \$agentFile))"
require_text "$ps_file" "Reset-ManagedFileAcl -Path \$managedFile"
require_text "$ps_file" "Convert-ToUnixLineEndings -Path \$managedFile"
require_text "$ps_file" "\$cygwinCommand = \"mkdir -p /tmp /var/run /AgentScripts/tmp\""
require_text "$ps_file" "\$cygwinCommand = \"cd /AgentScripts && . ./perl_env.sh && perl_preflight && perl -c ./agent_core.pl\""
require_text "$ps_file" "Invoke-Checked -FilePath \$bash -Arguments @(\"-lc\", \$cygwinCommand)"
require_absent "$ps_file" "$managed_sed_cygwin"
require_absent "$ps_file" "$managed_chmod_cygwin"

work_assign_line="$(line_number "$cmd_file" "set \"DOWNLOAD_WORK=%TEMP%\\gse-agent-unstable-%RANDOM%%RANDOM%\"")"
zip_assign_line="$(line_number "$cmd_file" "set \"DOWNLOAD_ZIP=%DOWNLOAD_WORK%\\unstable.zip\"")"
extract_assign_line="$(line_number "$cmd_file" "set \"DOWNLOAD_EXTRACT=%DOWNLOAD_WORK%\\extract\"")"
curl_line="$(line_number "$cmd_file" "curl.exe --insecure --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 --output")"
[ -n "$work_assign_line" ] || fail "could not locate DOWNLOAD_WORK assignment"
[ -n "$zip_assign_line" ] || fail "could not locate DOWNLOAD_ZIP assignment"
[ -n "$extract_assign_line" ] || fail "could not locate DOWNLOAD_EXTRACT assignment"
[ -n "$curl_line" ] || fail "could not locate curl download command"
[ "$work_assign_line" -lt "$curl_line" ] || fail "DOWNLOAD_WORK must be assigned before curl consumes it"
[ "$zip_assign_line" -lt "$curl_line" ] || fail "DOWNLOAD_ZIP must be assigned before curl consumes it"
[ "$extract_assign_line" -lt "$curl_line" ] || fail "DOWNLOAD_EXTRACT must be assigned before extraction consumes it"
assert_no_same_block_percent_reference "$cmd_file" "DOWNLOAD_WORK"
assert_no_same_block_percent_reference "$cmd_file" "DOWNLOAD_ZIP"
assert_no_same_block_percent_reference "$cmd_file" "DOWNLOAD_EXTRACT"

for forbidden in \
    "ReleaseBaseUrl" \
    "ReleaseVersion" \
    "ReleaseMetadataUrl" \
    "ReleaseChecksumUrl" \
    "Get-FileHash -Algorithm SHA256" \
    "Release ZIP SHA-256" \
    "checksum_verified" \
    "verification_status" \
    "installed_release.json" \
    "Resolve-ReleaseArtifact" \
    "Sync-ReleasePayload" \
    "Sync-Payload" \
    "Find-Git" \
    "Initialize-GitMetadata" \
    "Sync-Repository" \
    "GitRepoUrl" \
    "GitBranch" \
    "GitExe" \
    "fetch\", \"origin" \
    "reset\", \"--hard" \
    "checkout\", \"-B" \
    "git clone" \
    "git fetch" \
    "git checkout" \
    "git reset" \
    "reset --hard"; do
    require_absent "$cmd_file" "$forbidden"
    require_absent "$ps_file" "$forbidden"
done

metadata_line="$(line_number "$cmd_file" "curl.exe --insecure --fail --location --show-error --progress-bar --retry 3 --connect-timeout 20 --output")"
expand_line="$(line_number "$cmd_file" "Expand-Archive")"
root_line="$(line_number "$cmd_file" "Release ZIP did not contain exactly one")"
run_line="$(line_number "$cmd_file" "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%INSTALLER_PS%\"")"
source_installer_line="$(line_number "$cmd_file" "if /I not \"%AGENT_MODE%\"==\"Uninstall\" if /I not \"%AGENT_MODE%\"==\"Reconfigure\" set \"INSTALLER_PS=%SOURCE_PATH%\\Installer-Agent-Windows.ps1\"")"
reconfigure_line="$(line_number "$cmd_file" "if /I not \"%AGENT_MODE%\"==\"Reconfigure\" goto after_reconfigure")"
reconfigure_goto_line="$(line_number "$cmd_file" "goto run_installer")"
[ -n "$metadata_line" ] || fail "could not locate online download"
[ -n "$expand_line" ] || fail "could not locate archive extraction"
[ -n "$root_line" ] || fail "could not locate payload root validation"
[ -n "$source_installer_line" ] || fail "could not locate source installer handoff"
[ -n "$run_line" ] || fail "could not locate PowerShell installer invocation"
[ -n "$reconfigure_line" ] || fail "could not locate reconfigure mode block"
[ -n "$reconfigure_goto_line" ] || fail "could not locate reconfigure bypass"
[ "$reconfigure_line" -lt "$metadata_line" ] || fail "reconfigure handling must run before download setup"
[ "$reconfigure_goto_line" -lt "$metadata_line" ] || fail "reconfigure mode must bypass download and copy paths"
[ "$metadata_line" -le "$expand_line" ] || fail "online download must precede archive extraction"
[ "$expand_line" -le "$root_line" ] || fail "archive extraction must precede payload root validation"
[ "$root_line" -le "$source_installer_line" ] || fail "payload root validation must precede source installer handoff"
[ "$source_installer_line" -lt "$run_line" ] || fail "source installer handoff must precede PowerShell invocation"

require_text "$ps_file" "[ValidateSet(\"Install\", \"Repair\", \"Reconfigure\", \"Uninstall\")]"
require_text "$ps_file" "[string]\$InstallPath = \"C:\\GSE\\Agent\""
require_text "$ps_file" "[string]\$ServiceName = \"GSPAgent\""
require_text "$ps_file" "[string]\$ServiceDisplayName = \"GSE Windows Agent\""
require_text "$ps_file" "[string]\$AgentUser = \"gameserver\""
require_text "$ps_file" "[switch]\$AgentUserWasSet"
require_text "$ps_file" "function Assert-BundledRuntime"
require_text "$ps_file" "Verified installed payload and bundled runtime files."
require_text "$ps_file" "param([string]\$Root, [string]\$ManifestRoot = \"\")"
require_text "$ps_file" "\$requiredFiles = Get-RequiredPayloadFiles -Root \$Root -ManifestRoot \$ManifestRoot"
require_text "$ps_file" "Using reconfigure payload manifest from \$manifestRoot"
require_text "$ps_file" "Assert-BundledRuntime -ManifestRoot \$manifestRoot"
require_text "$ps_file" "function Invoke-InstallOrRepair"
require_text "$ps_file" "function Invoke-Reconfigure"
require_text "$ps_file" "function Invoke-Uninstall"
require_text "$ps_file" "& \$FilePath @Arguments"
require_text "$ps_file" "function Test-CygrunsrvServiceExists"
require_text "$ps_file" "function Invoke-CygrunsrvChecked"
require_text "$ps_file" "function Stop-CygrunsrvServiceForRemoval"
require_text "$ps_file" "function New-AgentServiceWrapper"
require_text "$ps_file" "\$exitCode = \$LASTEXITCODE"
require_text "$ps_file" "Push-Location -LiteralPath \$WorkingDirectory"
require_text "$ps_file" "Pop-Location"
require_text "$ps_file" "Assert-BundledRuntime"
require_text "$ps_file" "Register-AgentService -PlainPassword \$password"
require_text "$ps_file" "Start-AgentService"
require_text "$ps_file" "switch (\$Mode)"
require_absent "$ps_file" "Start-Process -ArgumentList"
require_absent "$ps_file" "[switch]\$Offline"
require_absent "$ps_file" "[string]\$SourcePath"
require_absent "$ps_file" "[string]\$ReleaseZipUrl"

require_text "$start_file" "set \"SERVICE_NAME=GSPAgent\""
require_text "$start_file" "Checking Windows service %SERVICE_NAME%"
require_text "$start_file" "START_PENDING"
require_text "$start_file" "STOP_PENDING"
require_text "$start_file" "\"%ROOT%bin\\bash.exe\" -lc \"cd /AgentScripts && exec /bin/bash /AgentScripts/agent_launch.sh foreground\""
require_text "$launch_file" "ensure_pureftpd()"
require_text "$launch_file" "PERL_ENV_FILE=\"\$AGENT_DIR/perl_env.sh\""
require_text "$launch_file" "load_perl_env || fail \"Bundled Perl environment initialization failed.\""
require_text "$launch_file" "perl_preflight || fail \"Bundled Perl module preflight failed for \$AGENT_FILE\""
require_text "$launch_file" "is_managed_script_path()"
require_text "$launch_file" "AgentScripts/agent_launch.sh|AgentScripts/perl_env.sh|AgentScripts/agent_core.pl) return 0"
require_text "$launch_file" "cp \"\$patch_root/files/\$rel\" \"\$dest\" || return 1"
require_text "$launch_file" "cp -p \"\$patch_root/files/\$rel\" \"\$dest\" || return 1"
require_text "$launch_file" "AGENT_SKIP_AUTO_UPDATE=1 exec bash \"\$AGENT_DIR/agent_launch.sh\" \"\$MODE\""
require_absent "$launch_file" "$managed_chmod_launcher"
require_absent "$launch_file" "git clone"
require_absent "$launch_file" "git ls-remote"

require_text "$perl_env_file" "configure_bundled_perl()"
require_text "$perl_env_file" "detect_perl_version()"
require_text "$perl_env_file" "detect_perl_arch()"
require_text "$perl_env_file" "perl_preflight()"
require_text "$perl_env_file" "/usr/share/perl5/vendor_perl/\$version"
require_text "$perl_env_file" "/lib/perl5/vendor_perl/\$version/\$arch"
require_text "$perl_env_file" "LWP::UserAgent"

for preserved in \
    "Cfg" \
    "ServerFiles" \
    "Schedule" \
    "runtime_status" \
    "steamcmd" \
    "Merged preserved local state over bundled SteamCMD bootstrap" \
    "agent_core_update_state.json" \
    "etc\\passwd" \
    "etc\\pureftpd.pdb" \
    "home" \
    "logs" \
    "backups"; do
    require_text "$ps_file" "$preserved"
done

if stale_matches="$(
    git -C "$repo_root" grep -n -I -E 'GSP/|GSP\\|/GSP|C:\\GSE\\Agent\\GSP|cd /GSP' -- . \
        ':(exclude).devplus/**' \
        ':(exclude)docs/codex-history/**' \
        ':(exclude)docs/agent-modernization-step-1-divergence-report.md' 2>/dev/null |
    grep -Ev '^(AGENTS\.md|docs/GAME_SERVER_LIFECYCLE_CONTRACT\.md):|GSP-WORKSPACE\.md|../GSP/docs/|AgentScripts/GSP\.pid|LegacyApplicationDirName|root/GSP/\(|grep -n -I -E|tests/validate_agent_scripts_layout\.sh|tests/validate_offline_installer_contract\.sh' || true
)"; then
    if [ -n "$stale_matches" ]; then
        printf '%s\n' "$stale_matches" >&2
        fail "stale active filesystem reference to legacy application directory remains"
    fi
fi

if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -NonInteractive -Command "\$errors=\$null; [System.Management.Automation.Language.Parser]::ParseFile('$ps_file', [ref]\$null, [ref]\$errors) > \$null; if (\$errors.Count -gt 0) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }"
else
    echo "pwsh not found; skipped PowerShell AST parse."
fi

require_text "$cmd_file" 'set "RESTIC_ZIP_SHA256='
require_text "$cmd_file" 'set "RESTIC_EXE_SHA256='
require_text "$cmd_file" ':install_restic'
require_text "$cmd_file" 'call :install_restic'
if grep -Fq -- '--insecure' <(sed -n '/^:install_restic/,$p' "$cmd_file"); then fail "restic download must not disable TLS verification"; fi
echo "Simplified Windows installer contract validation passed."
