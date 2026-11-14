# Start an instance's dedicated server in Nick's interactive session via a scheduled task (survives SSH disconnects).
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$Save = 'world',
  [ValidateSet('2.0.77','2.1.24')][string]$Version = '2.0.77',
  [int]$GamePort = 34197,
  [int]$RconPort = 27015
)
$ErrorActionPreference = 'Stop'
$dir = "D:\pog\inst\$Name"
$installed = Get-Content "D:\pog\factorio-$Version\data\base\info.json" -Raw | ConvertFrom-Json
if ($installed.version -ne $Version) { throw "engine version mismatch: expected $Version" }
if (-not (Test-Path "$dir\rcon.pw")) { throw "missing $dir\rcon.pw" }
$runner = @"
`$pw = (Get-Content '$dir\rcon.pw' -Raw).Trim()
& "D:\pog\factorio-$Version\bin\x64\factorio.exe" --config '$dir\config\config.ini' --start-server '$dir\saves\$Save.zip' ``
  --server-settings '$dir\server-settings.json' --bind 127.0.0.1:$GamePort --rcon-bind 127.0.0.1:$RconPort --rcon-password `$pw *> '$dir\server-stdout.log'
"@
Set-Content -Encoding ascii "$dir\run-server.ps1" $runner
$task = "pog-$Name-server"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\run-server.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds 12
Get-Content "$dir\factorio-current.log" -Tail 6
