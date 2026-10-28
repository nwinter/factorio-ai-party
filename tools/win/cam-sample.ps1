# Read-only: one sample a second of the box's memory and GPU and of every factorio* and obs64 process, for a camera test
# (d27 batch285 A: three camera clients slowed world n while RAM was full). Run it next to tools/cam_sample.py ticks
# (world n's game.tick each second, from the Mac); tools/cam_sample.py merge joins the two by UTC second.
#   tools/winps.sh tools/win/cam-sample.ps1 -Seconds 1920              # 32 min; holds the ssh session that long
# Writes two CSVs under $Dir (its own files; nothing else is written) and prints their paths:
#   camtest-STAMP-box.csv   utc, local, available/free+zero/standby/modified MB, commit GB, hard page reads and writes
#                           a second (Pages Input/Output), nonpaged pool MB, GPU 3D and copy engine %, GPU dedicated and
#                           shared MB, how long the sample took
#   camtest-STAMP-proc.csv  utc, process, pid, working set and private MB, page faults a second (soft and hard; Windows
#                           has no per-process hard-fault counter), CPU % of one core, GPU dedicated and shared MB, GPU 3D %
# Times are UTC: pogwin's own clock reads an hour behind PDT (d27).
param(
  [int]$Seconds = 1920,
  [string]$Dir = 'D:\pog\memtest'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Dir | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$boxOut = Join-Path $Dir "camtest-$stamp-box.csv"
$procOut = Join-Path $Dir "camtest-$stamp-proc.csv"
'utc,local,available_mb,free_zero_mb,standby_mb,modified_mb,commit_gb,pages_in_s,pages_out_s,nonpaged_mb,gpu_3d_pct,gpu_copy_pct,gpu_dedicated_mb,gpu_shared_mb,sample_ms' |
  Set-Content -Encoding ascii $boxOut
'utc,process,pid,ws_mb,private_mb,faults_s,cpu_pct,gpu_dedicated_mb,gpu_shared_mb,gpu_3d_pct' | Set-Content -Encoding ascii $procOut
"box:  $boxOut"
"proc: $procOut"

$paths = @(
  '\Memory\Available MBytes', '\Memory\Free & Zero Page List Bytes', '\Memory\Standby Cache Core Bytes',
  '\Memory\Standby Cache Normal Priority Bytes', '\Memory\Standby Cache Reserve Bytes', '\Memory\Modified Page List Bytes',
  '\Memory\Committed Bytes', '\Memory\Pages Input/sec', '\Memory\Pages Output/sec', '\Memory\Pool Nonpaged Bytes',
  '\GPU Engine(*engtype_3D)\Utilization Percentage', '\GPU Engine(*engtype_Copy)\Utilization Percentage',
  '\GPU Adapter Memory(*)\Dedicated Usage', '\GPU Adapter Memory(*)\Shared Usage',
  '\GPU Process Memory(*)\Dedicated Usage', '\GPU Process Memory(*)\Shared Usage')
foreach ($p in 'factorio*', 'obs64') {
  foreach ($c in 'ID Process', 'Working Set', 'Private Bytes', 'Page Faults/sec', '% Processor Time') { $paths += "\Process($p)\$c" }
}
$inv = [Globalization.CultureInfo]::InvariantCulture
function F($v) { [string]::Format($inv, '{0:0.#}', [double]$v) }

$last = Get-Date
# One Get-Counter run streams a sample set a second (rate counters need the interval); each set becomes rows at once.
Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples $Seconds -ErrorAction SilentlyContinue | ForEach-Object {
  $now = Get-Date
  $utc = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); $local = $now.ToString('HH:mm:ss')
  $box = @{}; $proc = @{}; $gpuPid = @{}
  foreach ($s in $_.CounterSamples) {
    $counter = ($s.Path -split '\\')[-1].ToLower(); $inst = $s.InstanceName; $v = $s.CookedValue
    if ($s.Path -match '\\memory\\') { $box[$counter] = $v }
    elseif ($s.Path -match '\\gpu engine\(') {
      $eng = if ($inst -match 'engtype_3d$') { '3d' } else { 'copy' }
      $box["gpu_$eng"] += $v
      if ($eng -eq '3d' -and $inst -match '^pid_(\d+)_') { $k = [int]$Matches[1]; if (-not $gpuPid[$k]) { $gpuPid[$k] = @{} }; $gpuPid[$k]['3d'] += $v }
    }
    elseif ($s.Path -match '\\gpu adapter memory\(') { $box["adapter $counter"] += $v }
    elseif ($s.Path -match '\\gpu process memory\(' -and $inst -match '^pid_(\d+)_') {
      $k = [int]$Matches[1]; if (-not $gpuPid[$k]) { $gpuPid[$k] = @{} }; $gpuPid[$k][$counter] += $v
    }
    elseif ($s.Path -match '\\process\(') { if (-not $proc[$inst]) { $proc[$inst] = @{} }; $proc[$inst][$counter] = $v }
  }
  $standby = $box['standby cache core bytes'] + $box['standby cache normal priority bytes'] + $box['standby cache reserve bytes']
  $row = @($utc, $local, (F $box['available mbytes']), (F ($box['free & zero page list bytes'] / 1MB)), (F ($standby / 1MB)),
    (F ($box['modified page list bytes'] / 1MB)), [string]::Format($inv, '{0:0.00}', $box['committed bytes'] / 1GB),
    (F $box['pages input/sec']), (F $box['pages output/sec']), (F ($box['pool nonpaged bytes'] / 1MB)),
    (F $box['gpu_3d']), (F $box['gpu_copy']), (F ($box['adapter dedicated usage'] / 1MB)), (F ($box['adapter shared usage'] / 1MB)),
    [int]($now - $last).TotalMilliseconds)
  ($row -join ',') | Add-Content -Encoding ascii $boxOut
  $last = $now
  $lines = foreach ($inst in ($proc.Keys | Sort-Object)) {
    $p = $proc[$inst]; $id = [int]$p['id process']; $g = if ($gpuPid[$id]) { $gpuPid[$id] } else { @{} }
    (@($utc, $inst, $id, (F ($p['working set'] / 1MB)), (F ($p['private bytes'] / 1MB)), (F $p['page faults/sec']),
      (F $p['% processor time']), (F ($g['dedicated usage'] / 1MB)), (F ($g['shared usage'] / 1MB)), (F $g['3d'])) -join ',')
  }
  if ($lines) { $lines | Add-Content -Encoding ascii $procOut }
}
"done: $boxOut $procOut"
