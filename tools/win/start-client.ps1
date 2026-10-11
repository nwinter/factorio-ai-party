# Launch a graphical client (own write-data dir) in Nick's desktop session that joins an instance's server.
# Uses the standalone build: the Steam copy restarts itself through Steam when launched as a client.
param(
  [Parameter(Mandatory)][string]$Name,
  [int]$GamePort = 34197,
  [string]$Factorio = 'D:\pog\factorio-2.0.77-alpha',
  [string]$PlayerName = 'pog-agent',
  [string]$Slot = '',          # several clients in one world: '-astra', '-opus' (own dir, task and exe name)
  [switch]$Sound,              # unmute (stream: only the main director, -Slot -cam1). Music stays off either way:
                               # the soundtrack may draw copyright claims; the stream has its own music slot.
  [switch]$Human               # a person plays this client: sound and music on, normal graphics (not captured by OBS)
)
$ErrorActionPreference = 'Stop'
$srv = "D:\pog\inst\$Name"
$dir = "D:\pog\inst\$Name-client$Slot"
New-Item -ItemType Directory -Force "$dir\config","$dir\mods" | Out-Null
$fwd = $dir -replace '\\','/'
$data = ($Factorio -replace '\\','/') + '/data'
$muted = if ($Sound -or $Human) { 'false' } else { 'true' }
$music = if ($Human) { '0.5' } else { '0' }
$quality = if ($Human) { 'normal' } else { 'low' }
$vram = if ($Human) { 'all' } else { 'low' }
Set-Content -Encoding ascii "$dir\config\config.ini" @"
[path]
read-data=$data
write-data=$fwd
[other]
check-updates=false
show-tips-and-tricks=false
[sound]
master-muted=$muted
music-volume=$music
[graphics]
full-screen=false
graphics-quality=$quality
video-memory-usage=$vram
"@
if (-not (Test-Path "$dir\player-data.json")) {
  (@{'service-username'=$PlayerName} | ConvertTo-Json) | Set-Content -Encoding ascii "$dir\player-data.json"
}
# Same mods as the server, minus built-in DLC entries the standalone base build lacks.
robocopy "$srv\mods" "$dir\mods" /E /XF mod-list.json /NFL /NDL /NJH /NJS /NP | Out-Null
$list = (Get-Content "$srv\mods\mod-list.json" -Raw | ConvertFrom-Json).mods | Where-Object { $_.enabled }
(@{mods=@($list)} | ConvertTo-Json -Depth 4) | Set-Content -Encoding ascii "$dir\mods\mod-list.json"
$task = "pog-$Name-client$Slot"
# A per-slot copy of the executable gives the window a distinct exe name, so OBS can capture it.
$exe = "$Factorio\bin\x64\factorio.exe"
if ($Slot) {
  $exe = "$Factorio\bin\x64\factorio$Slot.exe"
  if (-not (Test-Path $exe)) { Copy-Item "$Factorio\bin\x64\factorio.exe" $exe }
}
$action = New-ScheduledTaskAction -Execute $exe -Argument "--config `"$dir\config\config.ini`" --mp-connect 127.0.0.1:$GamePort"
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds 40
Get-Content "$dir\factorio-current.log" -Tail 8
"--- server"
Get-Content "$srv\factorio-current.log" -Tail 4
