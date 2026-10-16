# client-running.ps1 -Slot -cam1: "running" when that client's Factorio process (factorio-cam1) is up, else "stopped".
param([string]$Slot)
if (Get-Process -Name ("factorio" + $Slot) -ErrorAction SilentlyContinue) { "running" } else { "stopped" }
