# Dedicated camera files/task/executable. Never modifies world n or its cameras.
param([ValidateSet('start','stop','status')][string]$Action = 'status', [int]$Port = 34478)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = 'D:\pog\mt-stream\client'
$config = "$dir\config\config.ini"
$pidfile = 'D:\pog\mt-stream\camera.pid'
$task = 'pog-mt-stream-camera'
$build = 'D:\pog\factorio-2.0.77-expansion'
$exe = "$build\bin\x64\factorio-mtcam.exe"
function Owned {
  if (Test-Path $pidfile) {
    $savedPid = [int](Get-Content $pidfile)
    Get-CimInstance Win32_Process -Filter "ProcessId=$savedPid" | Where-Object {
      $_.ExecutablePath -eq $exe -and $_.CommandLine.Contains($config)
    }
  }
}
if ($Action -eq 'status') { Owned | Select-Object ProcessId,Name | ConvertTo-Json -Compress; exit }
if ($Action -eq 'stop') {
  $owned = Owned
  if ($owned) { Stop-Process -Id $owned.ProcessId -Force }
  if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $task
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
  }
  Remove-Item $pidfile -ErrorAction SilentlyContinue
  exit
}
if (Owned) { throw 'mt camera already running; stop its owning run first' }
$others = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'factorio*.exe' })
if ($others.Count) { throw 'Factorio is already running on pogwin; one camera only. Inspect and stop its owning run first.' }
if (-not (Test-Path "$build\data\space-age")) { throw 'The public camera requires the installed 2.0.77 Space Age build' }
New-Item -ItemType Directory -Force "$dir\config" | Out-Null
Set-Content -Encoding ascii $config @"
[path]
read-data=D:/pog/factorio-2.0.77-expansion/data
write-data=D:/pog/mt-stream/client
[other]
check-updates=false
show-tips-and-tricks=false
[sound]
master-muted=true
music-volume=0
alerts-muted=true
[graphics]
full-screen=false
graphics-quality=medium
video-memory-usage=low
texture-streaming=true
[interface]
output-console-delay=1
"@
Set-Content -Encoding ascii "$dir\player-data.json" '{"service-username":"pog-director2"}'
if (-not (Test-Path $exe)) { Copy-Item "$build\bin\x64\factorio.exe" $exe }
$args = "--config `"$config`" --mp-connect 127.0.0.1:$Port --disable-audio"
$actionSpec = New-ScheduledTaskAction -Execute $exe -Argument $args
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $actionSpec -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
for ($i = 0; $i -lt 30; $i++) {
  $p = Get-CimInstance Win32_Process -Filter "Name='factorio-mtcam.exe'" | Where-Object { $_.CommandLine.Contains($config) }
  if ($p) { Set-Content $pidfile $p.ProcessId; Write-Output "camera PID $($p.ProcessId)"; exit }
  Start-Sleep -Seconds 1
}
throw 'camera task did not start'
