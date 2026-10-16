# Read-only: what grows per hour. Samples every factorio* process (the live cams, the servers, a memtest client),
# obs64 and the box's commit and pools, and appends CSV rows to $Out (its own file). Each camera client starts at
# ~3.1 GB private and grows ~350 MB/h (d16 15:06): if the world's server process grows alike, it is game state (the
# map, the mods' Lua storage), which every client holds too; if only clients grow, it is drawing (sprites streamed in,
# the chart's map textures); if no process grows but "no owner" in mem-audit.ps1 does, it is a driver.
#   tools/winps.sh tools/win/mem-sample.ps1                      # one sample now
#   tools/winps.sh tools/win/mem-sample.ps1 -Samples 13 -EveryMin 5   # an hour (holds the ssh session that long)
param(
  [int]$Samples = 1,
  [double]$EveryMin = 5,
  [string]$Out = 'D:\pog\memtest\samples.csv'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
if (-not (Test-Path $Out)) { 'time,process,pid,started,private_mb,working_set_mb,gpu_shared_mb,gpu_dedicated_mb,handles,commit_gb,nonpaged_gb,available_gb' | Set-Content -Encoding ascii $Out }
for ($i = 0; $i -lt $Samples; $i++) {
  if ($i) { Start-Sleep -Seconds ([int]($EveryMin * 60)) }
  $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
  $gpu = @{}
  try {
    foreach ($s in (Get-Counter '\GPU Process Memory(*)\Shared Usage', '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples) {
      if ($s.InstanceName -match '^pid_(\d+)_') {
        $k = [int]$Matches[1]
        if (-not $gpu[$k]) { $gpu[$k] = @(0.0, 0.0) }
        if ($s.Path -match 'shared usage$') { $gpu[$k][0] += $s.CookedValue } else { $gpu[$k][1] += $s.CookedValue }
      }
    }
  } catch { }
  $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $rows = foreach ($p in (Get-Process factorio*, obs64 -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $g = if ($gpu[$p.Id]) { $gpu[$p.Id] } else { @(0.0, 0.0) }
    [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9:F2},{10:F2},{11:F2}',
      $now, $p.ProcessName, $p.Id, $(try { $p.StartTime.ToString('MM-dd HH:mm') } catch { '' }),
      [int]($p.PrivateMemorySize64 / 1MB), [int]($p.WorkingSet64 / 1MB), [int]($g[0] / 1MB), [int]($g[1] / 1MB),
      $p.HandleCount, ($m.CommittedBytes / 1GB), ($m.PoolNonpagedBytes / 1GB), ($m.AvailableBytes / 1GB))
  }
  $rows | Add-Content -Encoding ascii $Out
  $rows
}
