#!/usr/bin/env python3
"""Execute the launcher's pure graphics builder; never launch a client or touch its files.

No PowerShell on this host: skip. The same script can be passed to native Windows
PowerShell with -EncodedCommand for a read-only check (batch374).
"""
import base64
import configparser
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def script():
    source = base64.b64encode((ROOT / "tools/win/start-client.ps1").read_bytes()).decode()
    return r'''
$ErrorActionPreference = 'Stop'
$source = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('SOURCE'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ClientGraphics'}, $true)
if (-not $fn) { throw 'Missing graphics builder' }
# Only the pure function is evaluated. The launcher body is deliberately never invoked.
. ([scriptblock]::Create($fn.Extent.Text))
@(
  @{name='camera'; text=(Get-ClientGraphics -PlayerName 'pog-cam1')}
  @{name='panel'; text=(Get-ClientGraphics -PlayerName 'pog-cam3')}
  @{name='director'; text=(Get-ClientGraphics -PlayerName 'pog-director')}
  @{name='agent'; text=(Get-ClientGraphics -PlayerName 'pog-agent')}
  @{name='human'; text=(Get-ClientGraphics -PlayerName 'nick' -Human)}
  @{name='human-camera'; text=(Get-ClientGraphics -PlayerName 'pog-cam1' -Human)}
) | ConvertTo-Json
'''.replace("SOURCE", source)


def verify(output):
    rows = json.loads(output)
    assert {r["name"] for r in rows} == {"camera", "panel", "director", "agent", "human", "human-camera"}
    for row in rows:
        cfg = configparser.ConfigParser()
        cfg.read_string("[graphics]\n" + row["text"])
        graphics = dict(cfg["graphics"])
        human = row["name"].startswith("human")
        expected = {"full-screen": "false", "graphics-quality": "medium",
                    "video-memory-usage": "all" if human else "low", "texture-streaming": "true"}
        if row["name"] in {"camera", "panel", "director"}:
            expected.update({"show-particles": "false", "show-smoke": "false"})
        assert graphics == expected, (row["name"], graphics)
    print("camera graphics: 6 native PowerShell cases passed; human and ordinary client settings preserved")


if __name__ == "__main__":
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if shell:
        encoded = base64.b64encode(script().encode("utf-16le")).decode()
        verify(subprocess.check_output([shell, "-NoProfile", "-EncodedCommand", encoded], text=True))
    else:
        print("SKIP camera graphics execution: PowerShell is not installed on this host")
