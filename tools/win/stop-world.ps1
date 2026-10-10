# Stop an instance's client and server processes (save first over RCON from the Mac: tools/pog.py save).
param([Parameter(Mandatory)][string]$Name)
$procs = Get-CimInstance Win32_Process -Filter "Name='factorio.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape("D:\pog\inst\$Name\") -or $_.CommandLine -match [regex]::Escape("D:\pog\inst\$Name-client\") }
foreach ($p in $procs) { "stopping $($p.ProcessId): $($p.CommandLine.Substring(0,[math]::Min(120,$p.CommandLine.Length)))"; Stop-Process -Id $p.ProcessId -Force }
