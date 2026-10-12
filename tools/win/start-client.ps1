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
# Factorio 2.0's graphics-quality takes only high or medium (sprite resolution); the old 'low'/'normal' were not valid,
# so every client fell back to high ("[Graphics quality: high]" in shake5's cam3 log). Directors get medium-resolution
# sprites (a quarter of the pixels) to cut the ~5.2 GB each Space Age client committed; see docs/STREAM-NOTES.md.
$quality = 'medium'   # a person too: high took 6 GB next to the stream's three cameras (2026-10-11)
$vram = if ($Human) { 'all' } else { 'low' }
# Camera clients (pog-cam*, pog-director*) draw no game chat: the overlay shows chat, and lines the engine broadcasts to
# every client (the operator typing as `server`, joins) printed on the on-air picture, cut off by the crop (shift01
# 16:39). [interface] output-console-delay is how long a console line stays on screen, in ticks (default 1200, the
# Interface setting "Chat message delay"): 1 tick. The harness already prints agents' and viewers' lines only to
# players who are not directors (cameras.lua audience).
$console = if (-not $Human -and $PlayerName -match '^pog-(cam|director)') { "`r`n[interface]`r`noutput-console-delay=1" } else { '' }
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
texture-streaming=true$console
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
if ($Human) {
  # A person runs this from their own desktop (the shortcut): start the game directly. Registering a task fails when
  # an elevated session created it first (Access is denied), and a task adds nothing in the person's own session.
  Start-Process -FilePath $exe -ArgumentList "--config `"$dir\config\config.ini`" --mp-connect 127.0.0.1:$GamePort"
  return
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
