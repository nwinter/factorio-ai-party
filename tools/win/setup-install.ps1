# Copy the Steam Factorio install to a version-pinned directory on D:.
$ErrorActionPreference = 'Stop'
$src = 'C:\Program Files (x86)\Steam\steamapps\common\Factorio'
$ver = '2.0.77'
$dst = "D:\pog\factorio-$ver"
New-Item -ItemType Directory -Force 'D:\pog\inst' | Out-Null
if (-not (Test-Path "$dst\bin\x64\factorio.exe")) {
  robocopy $src $dst /E /XF factorio.pdb /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }
}
Set-Content -Encoding ascii "$dst\config-path.cfg" "config-path=__PATH__executable__/../../config`r`nuse-system-read-write-data-directories=false"
& "$dst\bin\x64\factorio.exe" --version | Select-Object -First 3
