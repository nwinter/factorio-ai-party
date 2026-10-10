# Press OK on OBS's startup "Authentication Failure" dialog (expired Twitch login on Nick's old profile).
$script = @'
$ws = New-Object -ComObject WScript.Shell
for ($i = 0; $i -lt 10; $i++) {
  if ($ws.AppActivate('Authentication Failure')) { Start-Sleep -Milliseconds 400; $ws.SendKeys('{ENTER}'); break }
  Start-Sleep -Milliseconds 500
}
'@
Set-Content -Encoding ascii 'D:\pog\obs-dismiss-run.ps1' $script
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File D:\pog\obs-dismiss-run.ps1'
Register-ScheduledTask -TaskName 'pog-obs-dismiss' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'pog-obs-dismiss'
Start-Sleep 8
Get-NetTCPConnection -State Listen -LocalPort 4455 -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort | Format-Table -HideTableHeaders | Out-String
