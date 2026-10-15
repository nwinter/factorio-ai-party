# Runs while OBS is closed (tools/win/obs-restart.ps1 StartUp): browser sources without GPU acceleration (19:25
# 2026-10-14: with it on, the overlay page leaked OBS GPU memory, about 1.5 GB a minute, out of system RAM).
$out = @()
foreach ($f in @("$env:APPDATA\obs-studio\global.ini", "$env:APPDATA\obs-studio\user.ini")) {
  if (Test-Path $f) {
    $t = Get-Content $f -Raw
    if ($t -match 'BrowserHWAccel=true') { [IO.File]::WriteAllText($f, ($t -replace 'BrowserHWAccel=true', 'BrowserHWAccel=false'), (New-Object System.Text.UTF8Encoding $false)); $out += "$(Split-Path $f -Leaf): BrowserHWAccel=false" }
    else { $out += "$(Split-Path $f -Leaf): $(if ($t -match 'BrowserHWAccel=false') { 'already false' } else { 'no BrowserHWAccel key' })" }
  }
}
$out -join '; '
