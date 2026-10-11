# Pick the save a new shift continues from and copy it to the new run's name (tools/start-team.sh, POG_RESUME).
#   -Check: report only (which save would be taken, the instance's mods); changes nothing, safe while the world runs.
#   Otherwise (world stopped first): copy that save to saves\<To>.zip and refresh the instance's harness mod from
#   D:\pog\mods, so the server and the directors (start-client.ps1 copies the instance mods) load the current one.
# The newest of saves\<From>.zip and the autosaves written after it wins, unless another run's save is newer than
# <From>.zip (then the autosaves may be that run's, and <From>.zip is taken). Prints key=value lines.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$From,
  [string]$To = '',
  [switch]$Check
)
$ErrorActionPreference = 'Stop'
$dir = "D:\pog\inst\$Name"
$saves = "$dir\saves"
$base = Get-Item "$saves\$From.zip" -ErrorAction SilentlyContinue
if (-not $base) { throw "no save $saves\$From.zip (stop-team's /server-save writes the run's save there)" }
$all = Get-ChildItem "$saves\*.zip"
$others = $all | Where-Object { $_.Name -notlike '_autosave*' -and $_.FullName -ne $base.FullName -and $_.BaseName -ne $To -and $_.LastWriteTime -gt $base.LastWriteTime }
$pick = $base
if ($others) {
  "note=another save is newer than $From.zip ($(($others | ForEach-Object Name) -join ', ')): autosaves ignored"
} else {
  $auto = $all | Where-Object { $_.Name -like '_autosave*' -and $_.LastWriteTime -gt $base.LastWriteTime } | Sort-Object LastWriteTime -Descending
  if ($auto) { $pick = $auto[0] }
}
"save=$($pick.Name)"
"save_time=$($pick.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
"base_time=$($base.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
$list = (Get-Content "$dir\mods\mod-list.json" -Raw | ConvertFrom-Json).mods
$sa = [bool](($list | Where-Object { $_.name -eq 'space-age' }).enabled)
"space_age=$([int]$sa)"
"mods=$((($list | Where-Object { $_.enabled }) | ForEach-Object name) -join ',')"
if ($Check) { return }
if (-not $To) { throw '-To is required unless -Check' }
if (Test-Path "$saves\$To.zip") { throw "$saves\$To.zip already exists" }
Copy-Item $pick.FullName "$saves\$To.zip"
robocopy 'D:\pog\mods\agent-harness_0.1.0' "$dir\mods\agent-harness_0.1.0" /E /NFL /NDL /NJH /NJS /NP | Out-Null
"copied=$To.zip"
