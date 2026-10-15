# Pick the save a new shift continues from and copy it to the new run's name (tools/start-team.sh, POG_RESUME).
#   -Check: report only (which save would be taken, the instance's mods); changes nothing, safe while the world runs.
#   Otherwise (world stopped first): copy that save to saves\<To>.zip and refresh the instance's harness mod from
#   D:\pog\mods, so the server and the directors (start-client.ps1 copies the instance mods) load the current one.
# Which save (operator 17:00: after a crash restart under shift12r, the 15:55 change took shift12.zip from 10:48, 3
# game hours back, because "another save is newer than shift12.zip: autosaves ignored"):
#   - -StopSave and -StopUtc (the previous run's stop record, tools/stop_save.py's stopped.json): that save when it
#     was written at or after the stop;
#   - else the newest save written at or after -StopUtc, whatever its name;
#   - else (no stop record, an older stop-team, or a crash restart mid-run) the newest save, whatever its name.
#   Refused (refuse=REASON, exit 1) when no save was written after the stop, or when the one taken is older than the
#   newest autosave or the stop by more than -MaxGapMinutes. Times are UTC on this box's clock. A copy keeps its
#   source's time (shift13b.zip, copied from shift12r.zip at 16:57, reads 15:56), so start-team also checks the tick.
# Prints key=value lines: seen= (the newest saves), save=, save_time=, base_time=, stop_time=, why=, space_age=, mods=.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$From,
  [string]$To = '',
  [string]$StopUtc = '',
  [string]$StopSave = '',
  [int]$MaxGapMinutes = 10,
  [switch]$Check
)
$ErrorActionPreference = 'Stop'
$dir = "D:\pog\inst\$Name"
$saves = "$dir\saves"
function utc($f) { $f.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function refuse($why) { "refuse=$why"; exit 1 }
$all = @(Get-ChildItem "$saves\*.zip" | Where-Object { -not $To -or $_.BaseName -ne $To } | Sort-Object LastWriteTimeUtc -Descending)
if ($all.Count -eq 0) { refuse "no save in $saves" }
foreach ($f in ($all | Select-Object -First 6)) { "seen=$($f.Name) $(utc $f) $($f.Length)" }
$base = $all | Where-Object { $_.BaseName -eq $From } | Select-Object -First 1
$auto = $all | Where-Object { $_.Name -like '_autosave*' } | Select-Object -First 1
$stop = $null
if ($StopUtc) {
  $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
  $stop = [DateTime]::Parse($StopUtc, [Globalization.CultureInfo]::InvariantCulture, $styles)
}
$pick = $null
$why = ''
if ($stop) {
  # (a minute's slack: file times are whole seconds and the stop was read just before the save)
  $after = @($all | Where-Object { $_.LastWriteTimeUtc -ge $stop.AddMinutes(-1) })
  $named = $after | Where-Object { $StopSave -and $_.Name -eq $StopSave } | Select-Object -First 1
  if ($named) { $pick = $named; $why = "the previous run's stop save ($StopSave, written at or after its stop)" }
  elseif ($after.Count -gt 0) { $pick = $after[0]; $why = "the newest save written at or after the previous run's stop" }
  else { refuse "no save written at or after the previous run's stop ($StopUtc); the newest is $($all[0].Name) at $(utc $all[0])" }
} else {
  $pick = $all[0]
  $why = "the newest save (no stop record from the previous run)"
}
if ($auto -and $pick.LastWriteTimeUtc -lt $auto.LastWriteTimeUtc.AddMinutes(-$MaxGapMinutes)) {
  refuse "$($pick.Name) ($(utc $pick)) is older than the newest autosave $($auto.Name) ($(utc $auto)) by more than $MaxGapMinutes min"
}
if ($stop -and $pick.LastWriteTimeUtc -lt $stop.AddMinutes(-$MaxGapMinutes)) {
  refuse "$($pick.Name) ($(utc $pick)) is older than the previous run's stop ($StopUtc) by more than $MaxGapMinutes min"
}
"save=$($pick.Name)"
"save_time=$(utc $pick)"
"why=$why"
if ($base) { "base_time=$(utc $base)" } else { "base_time=none ($From.zip not found)" }
if ($stop) { "stop_time=$($stop.ToString('yyyy-MM-ddTHH:mm:ssZ'))" }
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
