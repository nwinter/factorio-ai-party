# Read-only: where the box's memory is (d16 15:06: 0.4 GB free of 32, nonpaged pool 3.1 GB, ~13 GB held by no
# process, up since Oct 14 19:30). Also what a reboot would give back. tools/winps.sh tools/win/mem-audit.ps1
param([int]$Top = 12)
$ErrorActionPreference = 'Continue'
$os = Get-CimInstance Win32_OperatingSystem
$m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
$total = [double]$os.TotalVisibleMemorySize * 1KB
$boot = $os.LastBootUpTime
function G($b) { '{0,6:N2} GB' -f ($b / 1GB) }
"uptime: since {0:yyyy-MM-dd HH:mm} ({1:N1} h)" -f $boot, ((Get-Date) - $boot).TotalHours
"physical      $(G $total)"
"available     $(G $m.AvailableBytes)  (free+zero $(G $m.FreeAndZeroPageListBytes), standby $(G ($m.StandbyCacheCoreBytes + $m.StandbyCacheNormalPriorityBytes + $m.StandbyCacheReserveBytes)))"
"modified list $(G $m.ModifiedPageListBytes)  (written to the page file before it is free)"
"commit        $(G $m.CommittedBytes) of $(G $m.CommitLimit)"
"nonpaged pool $(G $m.PoolNonpagedBytes)  (a few hundred MB is usual; it only shrinks when its owner frees it or at reboot)"
"paged pool    $(G $m.PoolPagedBytes)  (resident $(G $m.PoolPagedResidentBytes))"
"drivers       $(G $m.SystemDriverResidentBytes) resident code; system code $(G $m.SystemCodeResidentBytes); cache $(G $m.SystemCacheResidentBytes)"

$procs = Get-Process
$ws = ($procs | Measure-Object WorkingSet64 -Sum).Sum
$priv = ($procs | Measure-Object PrivateMemorySize64 -Sum).Sum
"processes     $(G $ws) working sets, $(G $priv) private ($($procs.Count) processes)"
# In use = physical - available. Working sets count a shared page in each process that maps it, so the accounted
# figure is high and the rest a lower bound: memory no process or pool holds (driver-locked pages, GPU memory shared
# with the system, AWE): RAMMap's "Driver Locked" and "Nonpaged Pool" rows.
$inuse = $total - $m.AvailableBytes
$known = $ws + $m.PoolNonpagedBytes + $m.PoolPagedResidentBytes + $m.SystemDriverResidentBytes + $m.SystemCodeResidentBytes + $m.SystemCacheResidentBytes + $m.ModifiedPageListBytes
"in use        $(G $inuse); processes, pools, drivers, cache and modified list account for $(G $known)"
"no owner      $(G ([math]::Max([double]0, $inuse - $known))) at least (driver-locked or GPU-shared; a reboot frees it)"

"--- GPU memory (WDDM counters)"
try {
  $c = Get-Counter '\GPU Adapter Memory(*)\Shared Usage', '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop
  $c.CounterSamples | Where-Object { $_.CookedValue -gt 0 } | ForEach-Object {
    '{0,-70} {1}' -f ($_.Path -replace '^\\\\[^\\]+\\', ''), (G $_.CookedValue) }
  $pc = (Get-Counter '\GPU Process Memory(*)\Shared Usage', '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
  $byPid = @{}
  foreach ($s in $pc) {
    if ($s.InstanceName -match '^pid_(\d+)_') {
      $k = [int]$Matches[1]
      if (-not $byPid[$k]) { $byPid[$k] = @{shared = 0.0; dedicated = 0.0} }
      if ($s.Path -match 'shared usage$') { $byPid[$k].shared += $s.CookedValue } else { $byPid[$k].dedicated += $s.CookedValue }
    }
  }
  $byPid.GetEnumerator() | Sort-Object { - ($_.Value.shared + $_.Value.dedicated) } | Select-Object -First $Top | ForEach-Object {
    $p = Get-Process -Id $_.Key -ErrorAction SilentlyContinue
    '{0,-28} pid {1,6}  shared {2}  dedicated {3}' -f ($(if ($p) { $p.ProcessName } else { '(gone)' })), $_.Key, (G $_.Value.shared), (G $_.Value.dedicated)
  }
} catch { "GPU counters unavailable: $_" }

"--- top $Top processes by private bytes"
$procs | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First $Top | Format-Table -AutoSize Name, Id,
  @{n = 'private MB'; e = { [int]($_.PrivateMemorySize64 / 1MB) } },
  @{n = 'working set MB'; e = { [int]($_.WorkingSet64 / 1MB) } },
  @{n = 'handles'; e = { $_.HandleCount } },
  @{n = 'started'; e = { try { $_.StartTime.ToString('MM-dd HH:mm') } catch { '' } } } | Out-String -Width 160

"--- tools"
$dirs = @('C:\Tools', 'C:\Sysinternals', 'C:\SysinternalsSuite', 'D:\pog\tools', "$env:ProgramFiles\Windows Kits\10\Tools\x64",
  "${env:ProgramFiles(x86)}\Windows Kits\10\Tools\x64", "$env:USERPROFILE\Downloads")
foreach ($exe in 'RAMMap64.exe', 'RAMMap.exe', 'poolmon.exe') {
  $hit = @(Get-Command $exe -ErrorAction SilentlyContinue | ForEach-Object Source) +
    @($dirs | ForEach-Object { Get-ChildItem -Path $_ -Filter $exe -Recurse -Depth 2 -ErrorAction SilentlyContinue } | ForEach-Object FullName)
  "{0,-12} {1}" -f $exe, $(if ($hit) { ($hit | Select-Object -Unique) -join '; ' } else { 'not found' })
  if ($exe -eq 'poolmon.exe' -and $hit) {
    # one snapshot, sorted by bytes: the pool tags that hold the nonpaged pool (a driver's tag names it)
    $snap = Join-Path $env:TEMP "pog-poolmon-$PID.txt"
    & ($hit | Select-Object -First 1) -b -n $snap 2>$null | Out-Null
    if (Test-Path $snap) { Get-Content $snap | Select-Object -First 30; Remove-Item $snap -ErrorAction SilentlyContinue }
  }
}
