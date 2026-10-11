# Install the Aitum Vertical OBS plugin (docs/VERTICAL-PROPOSAL.md): download the release's Windows installer, check
# its SHA-256, run it silently (Inno Setup), and list what it installed. OBS must be closed (it loads plugins at start).
#   tools/winps.sh tools/win/install-aitum-vertical.ps1
param(
  [string]$Version = '1.6.6',
  # GitHub's digest for 1.6.6's vertical-canvas-windows-installer.exe (3,910,392 bytes), read 2026-10-11
  [string]$Sha256 = '01a81d1ea7489062ba51cc92a980b6870498a213fdd872d59a697a8136ce1fd8',
  [string]$Dir = 'D:\pog\installers'
)
$ErrorActionPreference = 'Stop'
if (Get-Process obs64 -ErrorAction SilentlyContinue) { throw 'OBS is running: close it on the desktop first (File > Exit)' }
New-Item -ItemType Directory -Force $Dir | Out-Null
$exe = "$Dir\vertical-canvas-$Version-windows-installer.exe"
$url = "https://github.com/Aitum/obs-vertical-canvas/releases/download/$Version/vertical-canvas-windows-installer.exe"
if (-not (Test-Path $exe)) { Invoke-WebRequest -UseBasicParsing $url -OutFile $exe }
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
if ($hash -ne $Sha256.ToLower()) { Remove-Item $exe; throw "sha256 $hash, expected ${Sha256}; not installed" }
"verified $exe ($((Get-Item $exe).Length) bytes)"
$log = "$Dir\vertical-canvas-$Version-install.log"
# The installer finds OBS from the registry (else Program Files\obs-studio) and refuses an OBS older than 31.
$p = Start-Process $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/LOG=`"$log`"" -Wait -PassThru
"installer exit code $($p.ExitCode) (0 is success); log $log"
Select-String -Path $log -Pattern 'Dest filename|Installation process succeeded|Error|Uninstall' | Select-Object -First 20 |
  ForEach-Object { $_.Line }
