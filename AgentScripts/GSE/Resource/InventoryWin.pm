package GSE::Resource::InventoryWin;
# Read-only hardware inventory for the Windows agent (GSE Resource Intelligence, Phase 2).
# Produces the same schema (version 1) as GSE::Resource::Inventory on the Linux agent.
# PowerShell collects raw facts as JSON; normalize_windows_inventory() turns them into the schema,
# so the logic is testable without Windows. Unknown values are null, never 0.
# Windows has no cgroups: memory.cgroup_limit and cpu.quota report source 'none' to keep the schema identical.
use strict;
use warnings;
use Exporter 'import';
use JSON::PP;

our @EXPORT_OK = qw(collect_windows_inventory normalize_windows_inventory windows_collect_script windows_drive_from_path);
use constant INVENTORY_SCHEMA_VERSION => 1;

# The PowerShell that gathers raw facts. __DRIVE__ is replaced with a validated drive letter such as C:.
# Every source is wrapped so one missing CIM class (an Invalid Class error) only adds a warning.
# Available memory uses the Windows memory API (includes standby memory) because performance counters are
# broken on some hosts (game3: Get-Counter and the PerfOS CIM classes both fail).
my $COLLECT_PS = <<'PS';
$ErrorActionPreference = 'Stop'
$warnings = New-Object System.Collections.ArrayList
function Get-Safe([string]$what, [scriptblock]$block) {
  try { return (& $block) } catch { [void]$warnings.Add($what + ' unavailable'); return $null }
}
function Num($v) { if ($v -eq $null) { return $null } else { return [int64]$v } }
$drive = '__DRIVE__'
$cs   = Get-Safe 'Win32_ComputerSystem' { Get-CimInstance Win32_ComputerSystem }
$os   = Get-Safe 'Win32_OperatingSystem' { Get-CimInstance Win32_OperatingSystem }
$cpus = Get-Safe 'Win32_Processor' { @(Get-CimInstance Win32_Processor) }
$availBytes = Get-Safe 'ComputerInfo.AvailablePhysicalMemory' { Add-Type -AssemblyName Microsoft.VisualBasic; [int64](New-Object Microsoft.VisualBasic.Devices.ComputerInfo).AvailablePhysicalMemory }
$pds  = Get-Safe 'Get-PhysicalDisk' { @(Get-PhysicalDisk) }
$vol  = Get-Safe 'Win32_LogicalDisk' { Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $drive + "'") }
$logical = $null; $cores = $null
if ($cpus) {
  $logical = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
  $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
}
$disks = @()
if ($pds) {
  foreach ($d in $pds) {
    $disks += [ordered]@{ name = [string]$d.FriendlyName; media_type = [string]$d.MediaType; bus_type = [string]$d.BusType; size_bytes = (Num $d.Size) }
  }
}
$volume = $null
if ($vol) { $volume = [ordered]@{ drive = $drive; filesystem = [string]$vol.FileSystem; size_bytes = (Num $vol.Size); free_bytes = (Num $vol.FreeSpace) } }
$out = [ordered]@{
  os_caption = $(if ($os) { [string]$os.Caption } else { $null })
  os_version = $(if ($os) { [string]$os.Version } else { $null })
  architecture = $(if ($os) { [string]$os.OSArchitecture } else { $null })
  cpu_model = $(if ($cpus) { [string]$cpus[0].Name } else { $null })
  cpu_sockets = $(if ($cpus) { @($cpus).Count } else { $null })
  logical_processors = (Num $logical)
  physical_cores = (Num $cores)
  hypervisor_present = $(if ($cs) { [bool]$cs.HypervisorPresent } else { $null })
  total_visible_kib = $(if ($os) { Num $os.TotalVisibleMemorySize } else { $null })
  free_physical_kib = $(if ($os) { Num $os.FreePhysicalMemory } else { $null })
  available_mbytes = $(if ($availBytes -ne $null) { [int64][math]::Floor($availBytes / 1MB) } else { $null })
  disks = $disks
  volume = $volume
  warnings = @($warnings)
}
ConvertTo-Json -InputObject $out -Depth 5 -Compress
PS

sub windows_drive_from_path {
    my ($path) = @_;
    return undef unless defined $path && $path ne '';
    return uc($1) . ':' if $path =~ m{^([A-Za-z]):(?:[\\/]|$)};
    return uc($1) . ':' if $path =~ m{^/cygdrive/([A-Za-z])(?:/|$)};
    return undef;
}

sub windows_collect_script {
    my ($drive) = @_;
    die "invalid drive\n" unless defined $drive && $drive =~ /^[A-Za-z]:$/;
    (my $script = $COLLECT_PS) =~ s/__DRIVE__/\U$drive\E/;
    return $script;
}

sub _clean {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s eq '' ? undef : $s;
}

sub _int_or_undef {
    my ($v) = @_;
    return undef unless defined $v && !ref($v) && $v =~ /^-?\d+$/;
    return $v + 0;
}

sub _bool_or_undef {
    my ($v) = @_;
    return undef unless defined $v;
    return $v ? JSON::PP::true : JSON::PP::false;
}

sub _list {
    my ($v) = @_;
    return [] unless defined $v;
    return $v if ref($v) eq 'ARRAY';
    return [$v] if ref($v) eq 'HASH';   # PowerShell 5.1 unwraps single-element arrays
    return [];
}

sub _architecture {
    my ($raw) = @_;
    my $a = _clean($raw);
    return undef unless defined $a;
    return 'x86_64' if $a =~ /^64-bit$/i;
    return 'x86'    if $a =~ /^32-bit$/i;
    return 'arm64'  if $a =~ /^arm.*64/i;
    return lc $a;
}

sub _rotational {
    my ($media) = @_;
    my $m = defined $media ? lc $media : '';
    return JSON::PP::true  if $m eq 'hdd';
    return JSON::PP::false if $m eq 'ssd' || $m eq 'scm';
    return undef;   # Unspecified or unknown: do not guess.
}

# Turn the raw PowerShell JSON (already decoded to a hash) into the version 1 inventory.
sub normalize_windows_inventory {
    my ($raw, %opt) = @_;
    my @warnings = @{ _list(ref($raw) eq 'HASH' ? $raw->{warnings} : undef) };
    $raw = {} unless ref($raw) eq 'HASH';

    my $total_kib = _int_or_undef($raw->{total_visible_kib});
    my $avail_mib = _int_or_undef($raw->{available_mbytes});
    if (!defined $avail_mib) {
        my $free_kib = _int_or_undef($raw->{free_physical_kib});
        if (defined $free_kib) {
            $avail_mib = int($free_kib / 1024);
            push @warnings, 'available memory is free memory only (excludes standby cache); real availability is higher';
        }
    }
    push @warnings, 'cpu model missing' unless defined _clean($raw->{cpu_model});

    my @devices;
    for my $d (@{ _list($raw->{disks}) }) {
        next unless ref($d) eq 'HASH';
        push @devices, {
            name => _clean($d->{name}),
            rotational => _rotational($d->{media_type}),
            size_bytes => _int_or_undef($d->{size_bytes}),
            media_type => _clean($d->{media_type}),
            bus_type => _clean($d->{bus_type}),
        };
    }

    my $vol = $raw->{volume};
    my $volume;
    if (ref($vol) eq 'HASH') {
        $volume = {
            path => $opt{game_path},
            mount => _clean($vol->{drive}),
            filesystem => _clean($vol->{filesystem}),
            total_bytes => _int_or_undef($vol->{size_bytes}),
            available_bytes => _int_or_undef($vol->{free_bytes}),
        };
    } else {
        $volume = { path => $opt{game_path}, total_bytes => undef, available_bytes => undef, error => 'volume not found' };
    }
    push @warnings, 'game volume drive unknown, defaulted to C:' if $opt{drive_defaulted};

    return {
        schema_version => INVENTORY_SCHEMA_VERSION,
        platform => 'windows',
        kernel => _clean($raw->{os_version}),
        os_name => _clean($raw->{os_caption}),
        architecture => _architecture($raw->{architecture}),
        cpu => {
            model => _clean($raw->{cpu_model}),
            logical_cpus_allowed => _int_or_undef($raw->{logical_processors}),
            cpus_allowed_list => undef,
            sockets => _int_or_undef($raw->{cpu_sockets}),
            physical_cores => _int_or_undef($raw->{physical_cores}),
            quota => { source => 'none', quota_us => undef, period_us => undef, unlimited => undef },
            hypervisor_flag => _bool_or_undef($raw->{hypervisor_present}),
        },
        memory => {
            total_mib => (defined $total_kib ? int($total_kib / 1024) : undef),
            available_mib => $avail_mib,
            cgroup_limit => { source => 'none', limit_bytes => undef },
        },
        storage => {
            game_volume => $volume,
            block_devices => \@devices,
        },
        warnings => \@warnings,
    };
}

# Collect the Windows inventory.
# Options: game_path (Windows path of the game volume), run_ps (coderef returning (output, error)),
#          raw_json (use this instead of running PowerShell; for tests).
sub collect_windows_inventory {
    my (%opt) = @_;
    my $drive = windows_drive_from_path($opt{game_path});
    my $defaulted = 0;
    unless (defined $drive) { $drive = 'C:'; $defaulted = 1; }

    my ($json, $err);
    if (defined $opt{raw_json}) {
        $json = $opt{raw_json};
    } else {
        my $run = $opt{run_ps} or die "run_ps is required\n";
        ($json, $err) = $run->(windows_collect_script($drive));
        die(($err || 'powershell returned nothing') . "\n") unless defined $json && $json ne '';
    }
    my $raw = eval { JSON::PP->new->decode($json) };
    die "powershell output was not valid JSON\n" unless ref($raw) eq 'HASH';
    return normalize_windows_inventory($raw, game_path => $opt{game_path}, drive_defaulted => $defaulted);
}

1;
