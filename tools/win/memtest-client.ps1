# A camera-like client for memory tests, isolated from the stream: its own write dir (D:\pog\memtest\<Variant>), its
# own exe name (factorio-memtest.exe, which OBS does not capture) and task, and a COPY of a world's save loaded as a
# local game (--load-game): it never joins a server and never touches the live cams. Same [graphics] as a camera
# (start-client.ps1) plus the variant's changes. It refuses to start without memory headroom (d16 15:06 the box had
# 0.4 GB free and cam2 and cam3 died at 14:59), and it runs one more copy of the simulation (CPU).
#   tools/winps.sh tools/win/memtest-client.ps1 -Variant base
#   tools/winps.sh tools/win/memtest-client.ps1 -Variant noaudio -NoAudio
#   tools/winps.sh tools/win/memtest-client.ps1 -Variant nodeco -Graphics 'show-decoratives=false'
#   tools/winps.sh tools/win/memtest-client.ps1 -Stop
# Then tools/winps.sh tools/win/mem-sample.ps1 (factorio-memtest's rows) after load and every few minutes.
param(
  [string]$Variant = 'base',
  [string]$World = 'n',
  [string]$Save = '',                                   # default: the world's newest save
  [string]$Factorio = 'D:\pog\factorio-2.0.77-expansion',
  [string]$Graphics = '',                               # 'key=value,key=value' replacing or adding [graphics] keys
  [switch]$NoAudio,                                     # --disable-audio: no sound loaded at all
  [double]$MinHeadroomGB = 8,
  [switch]$Stop
)
$ErrorActionPreference = 'Stop'
$task = 'pog-memtest-client'
if ($Stop) {
  Get-Process factorio-memtest -ErrorAction SilentlyContinue | Stop-Process -Force
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  'memtest client stopped'
  return
}
if ($Variant -notmatch '^[\w-]{1,24}$') { throw "variant: letters, digits, - or _" }
if (Get-Process factorio-memtest -ErrorAction SilentlyContinue) { throw 'a memtest client is running (-Stop first)' }
$m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
$head = ($m.CommitLimit - $m.CommittedBytes) / 1GB
if ($head -lt $MinHeadroomGB -or $m.AvailableBytes / 1GB -lt $MinHeadroomGB / 2) {
  throw ("not enough memory for a test client: commit headroom {0:N1} GB, available {1:N1} GB (want {2} and {3})" -f
    $head, ($m.AvailableBytes / 1GB), $MinHeadroomGB, ($MinHeadroomGB / 2))
}
$srv = "D:\pog\inst\$World"
if (-not $Save) { $Save = (Get-ChildItem "$srv\saves\*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
$dir = "D:\pog\memtest\$Variant"
New-Item -ItemType Directory -Force "$dir\config", "$dir\mods", "$dir\saves" | Out-Null
Copy-Item $Save "$dir\saves\memtest.zip" -Force   # reads the server's save; the test loads its own copy
robocopy "$srv\mods" "$dir\mods" /E /XF mod-list.json /NFL /NDL /NJH /NJS /NP | Out-Null
$list = (Get-Content "$srv\mods\mod-list.json" -Raw | ConvertFrom-Json).mods | Where-Object { $_.enabled }
(@{mods = @($list)} | ConvertTo-Json -Depth 4) | Set-Content -Encoding ascii "$dir\mods\mod-list.json"
# a camera's [graphics] (start-client.ps1 for pog-cam*), then the variant's keys
$g = [ordered]@{'full-screen' = 'false'; 'graphics-quality' = 'medium'; 'video-memory-usage' = 'low'; 'texture-streaming' = 'true'}
foreach ($kv in ($Graphics -split ',' | Where-Object { $_ -match '=' })) {
  $k, $v = $kv -split '=', 2
  $g[$k.Trim()] = $v.Trim()
}
$fwd = $dir -replace '\\', '/'
$ini = "[path]`r`nread-data=$(($Factorio -replace '\\', '/') + '/data')`r`nwrite-data=$fwd`r`n[other]`r`ncheck-updates=false`r`n" +
  "show-tips-and-tricks=false`r`n[sound]`r`nmaster-muted=true`r`nmusic-volume=0`r`nalerts-muted=true`r`n[graphics]`r`n" +
  (($g.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n[interface]`r`noutput-console-delay=1`r`n"
Set-Content -Encoding ascii "$dir\config\config.ini" $ini
if (-not (Test-Path "$dir\player-data.json")) {
  (@{'service-username' = 'pog-memtest'} | ConvertTo-Json) | Set-Content -Encoding ascii "$dir\player-data.json"
}
$exe = "$Factorio\bin\x64\factorio-memtest.exe"
if (-not (Test-Path $exe)) { Copy-Item "$Factorio\bin\x64\factorio.exe" $exe }
$arg = "--config `"$dir\config\config.ini`" --load-game `"$dir\saves\memtest.zip`"" + $(if ($NoAudio) { ' --disable-audio' } else { '' })
# the desktop session, as start-client.ps1 does (a window needs it; an ssh session has none)
$action = New-ScheduledTaskAction -Execute $exe -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
"memtest client '$Variant' from $Save; [graphics] $(($g.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')$(if ($NoAudio) { ' + --disable-audio' })"
Start-Sleep -Seconds 60
Get-Content "$dir\factorio-current.log" -TotalCount 40 | Select-String -Pattern 'Graphics|Video memory|Physical memory|Audio|Loading map|Error'
