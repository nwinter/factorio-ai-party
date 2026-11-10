# Create an isolated Factorio instance (config, mods, settings, fresh map) under D:\pog\inst\<Name>.
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$Save = 'world',
  [ValidateSet('2.0.77','2.1.24')][string]$Version = '2.0.77',
  [long]$Seed = 20261010,
  [string]$ModSource = 'D:\pog\mods',
  [switch]$SpaceAge,
  [switch]$Peaceful
)
$ErrorActionPreference = 'Stop'
$bin = "D:\pog\factorio-$Version\bin\x64\factorio.exe"
$dir = "D:\pog\inst\$Name"
$installed = Get-Content "D:\pog\factorio-$Version\data\base\info.json" -Raw | ConvertFrom-Json
if ($installed.version -ne $Version) { throw "engine version mismatch: expected $Version" }
$modInfo = Get-Content "$ModSource\agent-harness_0.1.0\info.json" -Raw | ConvertFrom-Json
if ($modInfo.factorio_version -ne ($Version -replace '\.[^.]+$','')) { throw 'harness/engine version mismatch' }
if (Test-Path "$dir\saves\$Save.zip") { throw "$dir\saves\$Save.zip already exists" }
New-Item -ItemType Directory -Force "$dir\config","$dir\mods","$dir\saves" | Out-Null
robocopy $ModSource "$dir\mods" /E /NFL /NDL /NJH /NJS /NP | Out-Null
$fwd = $dir -replace '\\','/'
Set-Content -Encoding ascii "$dir\config\config.ini" "[path]`r`nread-data=D:/pog/factorio-$Version/data`r`nwrite-data=$fwd`r`n"
$sa = [bool]$SpaceAge
$mods = @(
  @{name='base'; enabled=$true}, @{name='agent-harness'; enabled=$true},
  @{name='elevated-rails'; enabled=$sa}, @{name='quality'; enabled=$sa}, @{name='space-age'; enabled=$sa}
)
if ($Version -eq '2.1.24') { $mods += @{name='recycler'; enabled=$sa} }
(@{mods=$mods} | ConvertTo-Json -Depth 4) | Set-Content -Encoding ascii "$dir\mods\mod-list.json"
$server = [ordered]@{
  name = "pog-$Name"; description = 'player-of-games agent world'; tags = @('pog')
  max_players = 0; visibility = @{public=$false; lan=$false}
  username = ''; password = ''; token = ''; game_password = ''
  require_user_verification = $false; allow_commands = 'admins-only'
  autosave_interval = 15; autosave_slots = 12; afk_autokick_interval = 0
  auto_pause = $true; auto_pause_when_players_connect = $false
  only_admins_can_pause_the_game = $true; autosave_only_on_server = $true; non_blocking_saving = $false
}
($server | ConvertTo-Json -Depth 4) | Set-Content -Encoding ascii "$dir\server-settings.json"
$gen = Get-Content "D:\pog\factorio-$Version\data\map-gen-settings.example.json" -Raw | ConvertFrom-Json
$gen.seed = $Seed
$gen.peaceful_mode = [bool]$Peaceful
($gen | ConvertTo-Json -Depth 8) | Set-Content -Encoding ascii "$dir\map-gen-settings.json"
& $bin --config "$dir\config\config.ini" --create "$dir\saves\$Save.zip" --map-gen-settings "$dir\map-gen-settings.json" 2>&1 |
  Select-String -Pattern 'error|Error|Loading mod|Saving|finished' | Select-Object -Last 8
Get-Item "$dir\saves\$Save.zip" | Select-Object FullName,Length | Format-List | Out-String
