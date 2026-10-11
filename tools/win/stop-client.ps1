# Stop one graphical client (the same match as tools/rejoin.sh): tools/winps.sh tools/win/stop-client.ps1 -Name n -Slot -cam3
# start-client.ps1 does nothing while the client's task still runs, so stop it first to restart with new settings.
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$Slot = ''
)
Get-CimInstance Win32_Process -Filter "Name like 'factorio%.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape("inst\$Name-client$Slot\") } |
  ForEach-Object { "stopping $($_.Name) ($($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force }
