# Read-only: memory of every Factorio process, the box's commit charge, and a client's graphics settings as its log
# reports them. tools/winps.sh tools/win/client-mem.ps1 [-Name n] [-Slot -cam3]
param(
  [string]$Name = 'n',
  [string]$Slot = '-cam3'
)
Get-Process factorio* | Sort-Object Name | Format-Table -AutoSize Name, Id,
  @{n = 'private MB'; e = { [int]($_.PrivateMemorySize64 / 1MB) } },
  @{n = 'working set MB'; e = { [int]($_.WorkingSet64 / 1MB) } },
  @{n = 'started'; e = { $_.StartTime.ToString('HH:mm:ss') } }
$m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
"commit: {0:N1} of {1:N1} GB" -f ($m.CommittedBytes / 1GB), ($m.CommitLimit / 1GB)
$log = "D:\pog\inst\$Name-client$Slot\factorio-current.log"
"--- $log"
Get-Content $log -TotalCount 60 | Select-String -Pattern 'Graphics|Video memory|texture|atlas|VRAM|Physical memory'
