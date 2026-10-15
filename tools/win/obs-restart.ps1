# Restart OBS on the box, unattended (operator 2026-10-13: at 08:29, after 24.5 h in one process, Quick Sync failed
# with MFX_ERR_MEMORY_ALLOC and the stream and recording stopped; only a new OBS process helped):
#   tools/winps.sh tools/win/obs-restart.ps1 [-WaitClose 30] [-WaitStart 90] [-DryRun]
# The caller stops the outputs first (tools/obs-restart.sh). OBS runs in Nick's desktop session and SSH is another
# session, where CloseMainWindow cannot reach it and `taskkill /IM obs64.exe` is refused ("can only be terminated
# forcefully"). So, like obs-dismiss.ps1, this registers a scheduled task with an Interactive principal
# (pog-obs-restart) that runs D:\pog\obs-restart-run.ps1 on the desktop:
# 1. close: CloseMainWindow (File > Exit), answering an exit confirmation or the "Authentication Failure" dialog,
#    for up to WaitClose s; then Stop-Process -Force as the fallback (OBS then thinks it crashed: see 3);
# 2. start: Start-ScheduledTask pog-obs (--disable-shutdown-check --disable-updater);
#    Before starting, stale crash markers (%APPDATA%\obs-studio\.sentinel\run_*, left by a forced stop) are removed
#    while no obs64 runs (15:06: the new process sat on "OBS Studio Crash Detected" and the websocket never came up);
# 3. dialogs: "Safe Mode" or "OBS Studio Crash Detected" (OBS's unclean-shutdown prompts, shown although the task
#    passes --disable-shutdown-check): press the normal-mode button (UI Automation; else Esc, the message box's reject
#    button); "Authentication Failure" (expired Twitch login on the old profile): OK;
# 4. up: OBS's main window ("OBS 32.2.2 - Profile: ...") and obs-websocket listening on 4455;
# 5. Quick Sync: the new process's log must not say "Encoder ID 'obs_qsv11...' not found" (15:06: QSV did not load,
#    StartStream failed, the stream was down 14 min); if it does, OBS is stopped and started once more; a second miss
#    is reported ("qsv: MISSING again").
# Each step's outcome goes to D:\pog\obs-restart.log, printed here when the task ends. Exit 0 when OBS is up again
# with Quick Sync, 2 when it is up without it, 1 when it is not up.
param(
  [int]$WaitClose = 30,
  [int]$WaitStart = 90,
  [string]$ObsTask = 'pog-obs',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$log = 'D:\pog\obs-restart.log'
$inner = 'D:\pog\obs-restart-run.ps1'
$taskName = 'pog-obs-restart'

if ($DryRun) {
  $p = @(Get-Process obs64 -ErrorAction SilentlyContinue)
  $t = Get-ScheduledTask -TaskName $ObsTask -ErrorAction SilentlyContinue
  $ws = Get-NetTCPConnection -State Listen -LocalPort 4455 -ErrorAction SilentlyContinue
  "dry run: nothing closed or started"
  "now: obs64 " + $(if ($p) { "pid $($p[0].Id), up since $($p[0].StartTime.ToString('MM-dd HH:mm')), main window '$($p[0].MainWindowTitle)'" } else { 'not running' }) +
    "; websocket 4455 " + $(if ($ws) { 'listening' } else { 'not listening' })
  "task ${ObsTask}: " + $(if ($t) { "$($t.State), runs $($t.Actions[0].Execute) $($t.Actions[0].Arguments)" } else { 'MISSING (nothing to start OBS with)' })
  "plan: register $taskName (Interactive, user $env:USERNAME) running $inner on the desktop:"
  "  1. close: CloseMainWindow on obs64, answer an exit confirmation or Authentication Failure, wait up to $WaitClose s; else Stop-Process -Force"
  "  2. start: Start-ScheduledTask $ObsTask"
  $runs = @(Get-ChildItem (Join-Path $env:APPDATA 'obs-studio\.sentinel') -Filter 'run_*' -ErrorAction SilentlyContinue)
  "  2b. before starting: remove .sentinel\run_* crash markers while no obs64 runs (now: $($runs.Count))"
  "  3. dialogs for up to $WaitStart s: Safe Mode or Crash Detected -> the normal-mode button (else Esc); Authentication Failure -> OK"
  "  5. Quick Sync: the new log must not say Encoder ID 'obs_qsv11...' not found; else stop and start once more"
  "  4. up: OBS main window and websocket 4455 listening; log $log"
  exit 0
}

$script = @'
$ErrorActionPreference = 'Continue'
$log = '__LOG__'
function Say($m) { Add-Content -Encoding ascii $log ("{0} {1}" -f (Get-Date -Format HH:mm:ss), $m) }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$ws = New-Object -ComObject WScript.Shell
function ObsWindows {
  $ids = @(Get-Process obs64 -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  if (-not $ids) { return @() }
  $all = $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  return @($all | Where-Object { $ids -contains $_.Current.ProcessId })
}
function Press($win, $pattern) {
  $cond = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
  foreach ($b in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
    if ($b.Current.Name -match $pattern) {
      try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return $b.Current.Name } catch { }
    }
  }
  return $null
}
function Keys($title, $keys) {
  if ($ws.AppActivate($title)) { Start-Sleep -Milliseconds 400; $ws.SendKeys($keys); return $true }
  return $false
}
function Dialogs($phase) {
  foreach ($w in ObsWindows) {
    $n = $w.Current.Name
    if ($n -match 'Safe Mode|Crash Detected') {
      # "OBS Studio Crash Detected" (15:06, after a forced stop left .sentinel\run_* behind) is the same prompt
      $b = Press $w 'Normal'
      if (-not $b -and (Keys $n '{ESC}')) { $b = 'Esc (the reject button: normal mode)' }
      Say "${phase}: dialog '$n': pressed $(if ($b) { "'$b'" } else { 'NOTHING (could not reach it)' })"
    } elseif ($n -match 'Authentication Failure') {
      $b = Press $w '^OK$'
      if (-not $b -and (Keys $n '{ENTER}')) { $b = 'Enter' }
      Say "${phase}: dialog '$n': pressed $(if ($b) { "'$b'" } else { 'NOTHING' })"
    } elseif ($phase -eq 'close' -and $n -match 'Exit|Quit|Close|Active|Outputs' -and $n -notmatch '^OBS \d') {
      $b = Press $w '^(&?Yes|&?Exit|&?OK)$'
      Say "close: dialog '$n': pressed $(if ($b) { "'$b'" } else { 'NOTHING' })"
    }
  }
}

# 1. close
$p = Get-Process obs64 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) {
  Say 'close: OBS was not running'
} else {
  $hours = [math]::Round(((Get-Date) - $p.StartTime).TotalHours, 1)
  $sent = $p.CloseMainWindow()
  Say "close: CloseMainWindow on pid $($p.Id) (up $hours h): $(if ($sent) { 'sent' } else { 'no main window to close (dialog in front?)' })"
  $t0 = Get-Date
  while ((Get-Process -Id $p.Id -ErrorAction SilentlyContinue) -and ((Get-Date) - $t0).TotalSeconds -lt __WAITCLOSE__) {
    Dialogs 'close'
    if (-not $sent) { $sent = (Get-Process -Id $p.Id -ErrorAction SilentlyContinue).CloseMainWindow() }
    Start-Sleep -Milliseconds 500
  }
  if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) {
    Stop-Process -Id $p.Id -Force
    Start-Sleep 2
    Say "close: still running after __WAITCLOSE__ s: FORCED (Stop-Process -Force); a Safe Mode prompt may follow"
  } else {
    Say ("close: exited cleanly in {0:N0} s" -f ((Get-Date) - $t0).TotalSeconds)
  }
}

# 2. start, 3. dialogs, 4. up; 5. Quick Sync loaded (else one more restart)
$obsDir = Join-Path $env:APPDATA 'obs-studio'
function ClearSentinel($why) {
  # OBS marks a running session in .sentinel\run_*; a forced stop leaves the marker, and the next start shows the
  # "OBS Studio Crash Detected" dialog (15:06: the websocket never came up behind it). Only while OBS is not running.
  if (Get-Process obs64 -ErrorAction SilentlyContinue) { return }
  $stale = @(Get-ChildItem (Join-Path $obsDir '.sentinel') -Filter 'run_*' -ErrorAction SilentlyContinue)
  if ($stale) {
    $stale | Remove-Item -Force -ErrorAction SilentlyContinue
    Say "start: removed $($stale.Count) stale crash marker(s) .sentinel\run_* ($why)"
  }
}
function StartUp {
  ClearSentinel 'before starting'
  # A config change that must land while OBS is closed (it rewrites its ini files on exit): D:\pog\obs-prestart.ps1,
  # when present, runs here (19:25 2026-10-14: BrowserHWAccel=false against the overlay's GPU memory leak).
  if (Test-Path 'D:\pog\obs-prestart.ps1') {
    try { $r = & 'D:\pog\obs-prestart.ps1' 2>&1 | Out-String; Say "start: obs-prestart.ps1: $($r.Trim())" } catch { Say "start: obs-prestart.ps1 failed: $_" }
  }
  $since = Get-Date
  Start-ScheduledTask -TaskName '__OBSTASK__'
  Say 'start: Start-ScheduledTask __OBSTASK__'
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt __WAITSTART__) {
    Dialogs 'start'
    $main = @(ObsWindows | Where-Object { $_.Current.Name -match '^OBS \d' })
    $listen = Get-NetTCPConnection -State Listen -LocalPort 4455 -ErrorAction SilentlyContinue
    if ($main -and $listen) {
      Say ("start: OBS up in {0:N0} s (window '{1}', websocket 4455 listening)" -f ((Get-Date) - $t0).TotalSeconds, $main[0].Current.Name)
      return $since
    }
    Start-Sleep 1
  }
  $names = (ObsWindows | ForEach-Object { "'" + $_.Current.Name + "'" }) -join ', '
  Say "start: NOT up after __WAITSTART__ s (obs64 windows: $(if ($names) { $names } else { 'none' }); websocket $(if (Get-NetTCPConnection -State Listen -LocalPort 4455 -ErrorAction SilentlyContinue) { 'listening' } else { 'not listening' }))"
  return $null
}
function QsvMissing($since) {
  # The new process's log (the newest in logs\, written since the start): 15:06's had "Encoder ID 'obs_qsv11_v2'
  # not found" (Quick Sync did not load; StartStream then failed). -> the missing encoder IDs, or @() when fine.
  Start-Sleep 3
  $f = Get-ChildItem (Join-Path $obsDir 'logs') -Filter '*.txt' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $since.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $f) { Say 'qsv: no log of the new process found (not checked)'; return @() }
  $hits = @(Select-String -Path $f.FullName -Pattern "Encoder ID '(obs_qsv11[^']*)' not found" -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  return $hits
}
$since = StartUp
$up = [bool]$since
if ($up) {
  $missing = @(QsvMissing $since)
  if ($missing.Count -gt 0) {
    Say "qsv: MISSING in the new process ($($missing -join ', ') not found): restarting once more"
    $p = Get-Process obs64 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { Stop-Process -Id $p.Id -Force; Start-Sleep 2 }
    $since = StartUp
    $up = [bool]$since
    if ($up) {
      $missing = @(QsvMissing $since)
      if ($missing.Count -gt 0) { Say "qsv: MISSING again ($($missing -join ', ') not found): the stream cannot start; a reboot of the box may be needed" }
      else { Say 'qsv: ok after the second start' }
    }
  } else {
    Say 'qsv: ok (no Quick Sync encoder missing in the log)'
  }
}
Say 'done'
'@
$script = $script.Replace('__LOG__', $log).Replace('__WAITCLOSE__', "$WaitClose").Replace('__WAITSTART__', "$WaitStart").Replace('__OBSTASK__', $ObsTask)
Set-Content -Encoding ascii $inner $script
Remove-Item $log -ErrorAction SilentlyContinue
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $inner"
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
"task $taskName started on the desktop session"
$deadline = (Get-Date).AddSeconds($WaitClose + 2 * $WaitStart + 45)  # (a second start when Quick Sync is missing)
while ((Get-Date) -lt $deadline) {
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern ' done$' -Quiet)) { break }
  Start-Sleep 1
}
if (-not (Test-Path $log)) { "no log at ${log}: the task did not run (is Nick's session logged in?)"; exit 1 }
Get-Content $log
$last = Select-String -Path $log -Pattern 'start: (OBS up|NOT up)' | Select-Object -Last 1
if (-not $last -or $last.Line -notmatch 'OBS up') { exit 1 }
if (Select-String -Path $log -Pattern 'qsv: MISSING again' -Quiet) { exit 2 }
exit 0
