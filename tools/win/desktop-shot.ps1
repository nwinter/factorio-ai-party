# Screenshot Nick's desktop (all monitors, downscaled) from his interactive session: -Out D:\pog\desk.png
param([string]$Out = 'D:\pog\desk.png', [double]$Scale = 0.35)
$script = @"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
`$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
`$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height
`$g = [System.Drawing.Graphics]::FromImage(`$bmp); `$g.CopyFromScreen(`$b.Left, `$b.Top, 0, 0, `$bmp.Size)
`$w = [int](`$b.Width * $Scale); `$h = [int](`$b.Height * $Scale)
`$small = New-Object System.Drawing.Bitmap `$bmp, `$w, `$h
`$small.Save('$Out', [System.Drawing.Imaging.ImageFormat]::Png)
"@
Set-Content -Encoding ascii 'D:\pog\desk-shot-run.ps1' $script
if (Test-Path $Out) { Remove-Item $Out }
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File D:\pog\desk-shot-run.ps1'
Register-ScheduledTask -TaskName 'pog-desk-shot' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'pog-desk-shot'
for ($i=0; $i -lt 20 -and -not (Test-Path $Out); $i++) { Start-Sleep 1 }
if (Test-Path $Out) { "saved $Out" } else { "no screenshot" }
