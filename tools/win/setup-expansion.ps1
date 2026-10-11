# Portable Space Age (expansion) build for clients at D:\pog\factorio-2.0.77-expansion. Never touches Program Files,
# Nick's Steam install or %APPDATA%\Factorio, and makes no shortcuts.
#   tools/winps.sh tools/win/setup-expansion.ps1 -Username NAME -TokenFile D:\pog\factorio-token.txt   # download API
#   tools/winps.sh tools/win/setup-expansion.ps1 -Installer                                          # Nick's installer
# 1. Download API (preferred): get-download/2.0.77/expansion/win64-manual with the factorio.com username and token
#    (profile page). The zip unpacks to a self-contained folder.
# 2. Fallback: the installer Nick downloaded (Setup_FactorioSpaceAge_2.0.77.exe.zip). Only if it is an Inno Setup
#    installer: silent, per-user, into D:\pog only, no icons. Inno still records an uninstall entry for the user.
param(
  [string]$Username = '',
  [string]$TokenFile = '',
  [switch]$Installer,
  [string]$InstallerZip = 'C:\Users\player\Downloads\Setup_FactorioSpaceAge_2.0.77.exe.zip',
  [string]$Version = '2.0.77'
)
$ErrorActionPreference = 'Stop'
$dst = "D:\pog\factorio-$Version-expansion"
$dl = 'D:\pog\downloads'
New-Item -ItemType Directory -Force $dl | Out-Null
$exe = "$dst\bin\x64\factorio.exe"
if (Test-Path $exe) { "already present: $exe" } else {
  $free = (Get-PSDrive D).Free / 1GB
  if ($free -lt 15) { throw ("D: has {0:N1} GB free; need 15" -f $free) }
  if (-not $Installer) {
    if (-not $Username -or -not $TokenFile) { throw 'give -Username and -TokenFile for the download API, or -Installer' }
    $token = (Get-Content $TokenFile -Raw).Trim()
    $zip = "$dl\factorio-expansion-$Version-win64.zip"
    $url = "https://www.factorio.com/get-download/$Version/expansion/win64-manual?username=$Username&token=$token"
    try {
      $ProgressPreference = 'SilentlyContinue'
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    } catch {
      $code = $_.Exception.Response.StatusCode.value__
      throw "download API refused: HTTP $code (403: the account behind this token does not own the expansion yet)"
    }
    "downloaded $zip ({0:N2} GB)" -f ((Get-Item $zip).Length / 1GB)
    $tmp = "$dl\unzip-$Version"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    tar -xf $zip -C $dl 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Expand-Archive -Path $zip -DestinationPath $tmp; $top = Get-ChildItem $tmp | Select-Object -First 1; Move-Item $top.FullName $dst }
    else { $top = Get-ChildItem $dl -Directory | Where-Object { Test-Path "$($_.FullName)\bin\x64\factorio.exe" } | Select-Object -First 1; Move-Item $top.FullName $dst }
  } else {
    if (-not (Test-Path $InstallerZip)) { throw "no installer zip at $InstallerZip" }
    $setupDir = "$dl\installer-$Version"
    if (-not (Test-Path $setupDir)) { Expand-Archive -Path $InstallerZip -DestinationPath $setupDir }
    $setup = Get-ChildItem $setupDir -Recurse -Filter *.exe | Select-Object -First 1
    if (-not $setup) { throw "no .exe inside $InstallerZip" }
    # Inno Setup check: its marker string sits near the start of the file.
    $fs = [IO.File]::OpenRead($setup.FullName); $buf = New-Object byte[] 4MB; $n = $fs.Read($buf, 0, $buf.Length); $fs.Close()
    if (-not ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -match 'Inno Setup')) { throw "$($setup.Name) is not an Inno Setup installer; not running it (extract by hand)" }
    $log = "$dl\installer-$Version.log"
    $flags = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/NOICONS', '/TASKS=""', "/DIR=`"$dst`"", "/LOG=`"$log`"")
    $p = Start-Process -FilePath $setup.FullName -ArgumentList $flags -PassThru
    if (-not $p.WaitForExit(3600 * 1000)) { $p.Kill(); throw 'installer did not finish within an hour' }
    "installer exit code $($p.ExitCode); log $log"
    if (-not (Test-Path $exe)) { throw "installer finished but $exe is missing; see $log" }
  }
}
# Portable: config and write-data next to the install, never %APPDATA%\Factorio (clients pass --config anyway).
Set-Content -Encoding ascii "$dst\config-path.cfg" "config-path=__PATH__executable__/../../config`r`nuse-system-read-write-data-directories=false"
if (-not (Test-Path "$dst\data\space-age\info.json")) { throw "$dst has no data\space-age: not an expansion build" }
& $exe --version | Select-Object -First 3
Get-ChildItem "$dst\data" -Directory | Select-Object -ExpandProperty Name
