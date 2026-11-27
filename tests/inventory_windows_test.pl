#!/usr/bin/perl
# Tests for GSE::Resource::InventoryWin (no Windows needed: PowerShell output is a fixture or a stub).
# Run from the repo root: perl -I AgentScripts tests/inventory_windows_test.pl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../AgentScripts";
use JSON::PP;
use GSE::Resource::InventoryWin qw(collect_windows_inventory normalize_windows_inventory windows_collect_script windows_drive_from_path);

my $fail = 0;
sub check { my ($ok, $name) = @_; print(($ok ? 'ok' : 'FAIL'), " - $name\n"); $fail++ unless $ok; }
sub slurp { my ($p) = @_; open(my $fh, '<', $p) or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t; }

# 1. Real output captured from game3 (Windows Server 2022, KVM guest).
my $json = slurp("$FindBin::Bin/fixtures/inventory_windows_game3_raw.json");
my $inv = collect_windows_inventory(raw_json => $json, game_path => 'C:\\GSE\\Agent');
check($inv->{platform} eq 'windows' && $inv->{schema_version} == 1, 'platform windows, schema 1');
check($inv->{cpu}{model} eq 'AMD Ryzen 7 3800X 8-Core Processor', 'CPU model has padding trimmed');
check($inv->{cpu}{logical_cpus_allowed} == 8 && $inv->{cpu}{physical_cores} == 8 && $inv->{cpu}{sockets} == 1, 'CPU counts (8 logical, 8 cores, 1 socket)');
check($inv->{cpu}{hypervisor_flag} && JSON::PP::is_bool($inv->{cpu}{hypervisor_flag}), 'hypervisor flag is a true boolean');
check($inv->{kernel} eq '10.0.20348' && $inv->{architecture} eq 'x86_64', 'OS version and architecture mapped (64-bit -> x86_64)');
check($inv->{memory}{total_mib} == 20460 && $inv->{memory}{available_mib} == 10502, 'memory in MiB (total from KiB, available from memory API)');
check($inv->{storage}{game_volume}{mount} eq 'C:' && $inv->{storage}{game_volume}{filesystem} eq 'NTFS' && $inv->{storage}{game_volume}{total_bytes} == 549081575424, 'game volume C: NTFS with byte totals');
check($inv->{storage}{game_volume}{path} eq 'C:\\GSE\\Agent', 'game volume keeps the path asked for');
my $disk = $inv->{storage}{block_devices}[0];
check($disk->{name} eq 'QEMU HARDDISK' && $disk->{size_bytes} == 549755813888 && $disk->{bus_type} eq 'SATA', 'virtual disk name, size, bus');
check(!defined $disk->{rotational}, 'media type Unspecified gives null rotational, not a guess');
check(scalar(@{$inv->{warnings}}) == 0, 'no warnings when every source answers');
check(!exists $inv->{cpu}{quota}{quota_us} || !defined $inv->{cpu}{quota}{quota_us}, 'no CPU quota on Windows (null, source none)');

# 2. Missing data stays null and is reported, never 0.
my $empty = normalize_windows_inventory({}, game_path => 'C:\\x');
check(!defined $empty->{cpu}{logical_cpus_allowed}, 'missing CPU count is null');
check(!defined $empty->{memory}{total_mib} && !defined $empty->{memory}{available_mib}, 'missing memory is null');
check(!defined $empty->{cpu}{hypervisor_flag}, 'missing hypervisor flag is null, not false');
check($empty->{storage}{game_volume}{error} eq 'volume not found' && !defined $empty->{storage}{game_volume}{total_bytes}, 'missing volume reports an error and null bytes');
check(scalar(@{$empty->{storage}{block_devices}}) == 0, 'no disks gives an empty list');
check((grep { $_ eq 'cpu model missing' } @{$empty->{warnings}}) == 1, 'missing CPU model is a warning');

# 3. Memory fallback: free memory only, with an explicit warning that it understates availability.
my $fallback = normalize_windows_inventory({ total_visible_kib => 8388608, free_physical_kib => 2097152, available_mbytes => undef, cpu_model => 'X' });
check($fallback->{memory}{available_mib} == 2048, 'falls back to free memory when the memory API gave nothing');
check((grep { /free memory only/ } @{$fallback->{warnings}}) == 1, 'the fallback is flagged as free memory only');

# 4. PowerShell 5.1 unwraps a single-element array into a hash; a list must still come out.
my $one = normalize_windows_inventory({ cpu_model => 'X', disks => { name => 'D1', media_type => 'HDD', bus_type => 'SATA', size_bytes => 1000 } });
check(scalar(@{$one->{storage}{block_devices}}) == 1 && $one->{storage}{block_devices}[0]{name} eq 'D1', 'a single disk given as a hash becomes a one-item list');

# 5. Media type mapping.
my $media = normalize_windows_inventory({ cpu_model => 'X', disks => [
    { name => 'a', media_type => 'HDD', size_bytes => 1 }, { name => 'b', media_type => 'SSD', size_bytes => 2 },
    { name => 'c', media_type => 'SCM', size_bytes => 3 }, { name => 'd', media_type => 'Unspecified', size_bytes => 4 } ] });
my @r = map { $_->{rotational} } @{$media->{storage}{block_devices}};
check($r[0] && !$r[1] && !$r[2] && !defined $r[3], 'HDD rotational, SSD and SCM not, Unspecified unknown');

# 6. Garbage numbers become null, not 0.
my $junk = normalize_windows_inventory({ cpu_model => 'X', logical_processors => 'abc', total_visible_kib => '', available_mbytes => [1] });
check(!defined $junk->{cpu}{logical_cpus_allowed} && !defined $junk->{memory}{total_mib} && !defined $junk->{memory}{available_mib}, 'non-numeric values become null');

# 7. Drive from path.
check(windows_drive_from_path('C:\\GSE\\Agent') eq 'C:', 'drive from C:\\path');
check(windows_drive_from_path('d:/games') eq 'D:', 'drive from d:/path, uppercased');
check(windows_drive_from_path('/cygdrive/e/servers') eq 'E:', 'drive from a Cygwin path');
check(!defined windows_drive_from_path('/home/gameserver') && !defined windows_drive_from_path(undef) && !defined windows_drive_from_path(''), 'unknown paths give no drive');

# 8. The PowerShell is only built from a validated drive.
check(windows_collect_script('d:') =~ /\$drive = 'D:'/, 'script uses the validated, uppercased drive');
for my $bad ('C:\\x', "C:'; Remove-Item *", '', 'CC:', 'C') {
    check(!eval { windows_collect_script($bad); 1 }, "rejects drive string '" . ($bad =~ s/\n//gr) . "'");
}
check(!eval { windows_collect_script(undef); 1 }, 'rejects an undefined drive');
check(windows_collect_script('C:') !~ /Remove-Item|Set-Content|Out-File|Stop-|Start-|New-Item|Invoke-Expression|iex /i, 'script contains no write, start, stop or eval commands');

# 9. collect: stubbed PowerShell, errors, and bad output.
my $seen;
my $ok = collect_windows_inventory(game_path => 'D:\\games', run_ps => sub { $seen = shift; return ($json, '') });
check($ok->{platform} eq 'windows' && $seen =~ /\$drive = 'D:'/, 'collect runs the script for the path\'s drive');
check(!eval { collect_windows_inventory(game_path => 'C:\\', run_ps => sub { return (undef, 'powershell failed (exit 1)') }); 1 } && $@ =~ /powershell failed/, 'a PowerShell failure is reported, not hidden');
check(!eval { collect_windows_inventory(game_path => 'C:\\', run_ps => sub { return ('not json', '') }); 1 } && $@ =~ /not valid JSON/, 'invalid JSON from PowerShell is reported');
my $guess = collect_windows_inventory(game_path => '/home/x', raw_json => $json);
check((grep { /defaulted to C:/ } @{$guess->{warnings}}) == 1, 'an unknown drive defaults to C: with a warning');

# 10. Same shape as the Linux inventory, so the panel can treat them alike.
my %want = (top => [qw(schema_version platform kernel architecture cpu memory storage warnings)],
            cpu => [qw(model logical_cpus_allowed cpus_allowed_list quota hypervisor_flag)],
            memory => [qw(total_mib available_mib cgroup_limit)], storage => [qw(game_volume block_devices)]);
check((grep { !exists $inv->{$_} } @{$want{top}}) == 0, 'top-level keys match the Linux inventory');
check((grep { !exists $inv->{cpu}{$_} } @{$want{cpu}}) == 0, 'cpu keys match the Linux inventory');
check((grep { !exists $inv->{memory}{$_} } @{$want{memory}}) == 0, 'memory keys match the Linux inventory');
check((grep { !exists $inv->{storage}{$_} } @{$want{storage}}) == 0, 'storage keys match the Linux inventory');
check(defined eval { JSON::PP->new->canonical->encode($inv) }, 'the inventory encodes to JSON');

print $fail ? "\n$fail FAILED\n" : "\nall Windows inventory tests passed\n";
exit($fail ? 1 : 0);
