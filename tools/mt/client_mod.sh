#!/usr/bin/env bash
# (mt282, private) The harness mod as human clients get it (report-mt278 H4.1): control.lua, data.lua and
# avatar_parts.lua with comments dropped (host/compact.ts, as the deployed bundle), the avatar sprite sheet, info.json
# and a stub runtime.lua (the contract only: dispatch refuses until a runtime is deployed). No harness module ships:
# the runtime arrives by deploy into the save, as now. The mt server runs the same build (a client's mods must match).
#   tools/mt/client_mod.sh [OUT_DIR]         makes OUT_DIR/agent-harness_0.1.0.zip and OUT_DIR/agent-harness_0.1.0/
#                                           (default /Users/owner/code/personal/player-of-games/artifacts/mt-client), then scans it
#   tools/mt/client_mod.sh --scan ZIP        the scan alone: exit 1 on a private name or a file not in the build
# info.json takes the mod set (agent/mt/mods.tsv) as optional dependencies, so a server or client that has their zips
# loads them first and one without them loads as before.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
mod=$root/vendor/factorio-harness/mod/agent-harness_0.1.0
FILES='agent-harness_0.1.0/
agent-harness_0.1.0/avatar_parts.lua
agent-harness_0.1.0/control.lua
agent-harness_0.1.0/data.lua
agent-harness_0.1.0/graphics/
agent-harness_0.1.0/graphics/avatar-parts.png
agent-harness_0.1.0/info.json
agent-harness_0.1.0/runtime.lua'
# the launch tree's words, the private work's numbers, its modules and the team names
WORDS='multi-?team|multiteam|mt2[0-9][0-9]|mt_[a-z]|mt_map|start-mt|POG_MT|other teams|pacts?\b|pact_|humans?\b|freeze|frozen|\b(red|blue|green|yellow|white)\b|team_stores|as_team|census|contact'
scan() {
  local zip=$1 tmp listed bad hits
  tmp=$(mktemp -d)
  listed=$(unzip -Z1 "$zip" | sort)
  bad=$(comm -23 <(echo "$listed") <(echo "$FILES" | sort))
  [ -z "$bad" ] || { echo "scan: files not in the build: $(echo $bad)"; rm -rf "$tmp"; return 1; }
  unzip -q "$zip" -d "$tmp"
  hits=$(grep -rIoE -i "$WORDS" "$tmp" | sed "s|^$tmp/||" | sort | uniq -c | head -20 || true)
  rm -rf "$tmp"
  [ -z "$hits" ] || { echo "scan: private names:"; echo "$hits"; return 1; }
  echo "scan: clean ($(echo "$listed" | grep -vc '/$') files: $(echo "$listed" | grep -v '/$' | sed 's|agent-harness_0.1.0/||' | tr '\n' ' '))"
}
if [ "${1:-}" = --scan ]; then scan "$2"; exit; fi
out=${1:-/Users/owner/code/personal/player-of-games/artifacts/mt-client}
build=$(mktemp -d)
d=$build/agent-harness_0.1.0
mkdir -p "$d/graphics"
cp "$mod/graphics/avatar-parts.png" "$d/graphics/"
(cd "$root/vendor/factorio-harness" && [ -f dist/host/compact.js ] || npm run build >/dev/null)
for f in control.lua data.lua avatar_parts.lua; do
  node -e "const {compactLua}=require(process.argv[1]); const fs=require('fs'); fs.writeFileSync(process.argv[3], compactLua(fs.readFileSync(process.argv[2],'utf8')))" \
    "$root/vendor/factorio-harness/dist/host/compact.js" "$mod/$f" "$d/$f"
done
cat > "$d/runtime.lua" <<'LUA'
local function none() error('no runtime deployed yet: the operator deploys one (fh deploy)', 0) end
return {dispatch=none, tick=function() end, stop_all=function() end}
LUA
python3 - "$mod/info.json" "$root/agent/mt/mods.tsv" "$d/info.json" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
mods = [l.split("\t")[0] for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")]
info["description"] = "Bounded actions and local observations for external agents. The runtime arrives over RCON."
info["dependencies"] = [d for d in info.get("dependencies", []) if not d.startswith("?")] + ["? " + m for m in mods]
json.dump(info, open(sys.argv[3], "w"), indent=2)
PY
for f in control.lua data.lua avatar_parts.lua runtime.lua; do luac -p "$d/$f"; done
mkdir -p "$out"
rm -f "$out/agent-harness_0.1.0.zip"
(cd "$build" && zip -q -r -X "$out/agent-harness_0.1.0.zip" agent-harness_0.1.0)
rm -rf "$out/agent-harness_0.1.0"
cp -R "$d" "$out/agent-harness_0.1.0"
rm -rf "$build"
echo "$out/agent-harness_0.1.0.zip ($(wc -c < "$out/agent-harness_0.1.0.zip" | tr -d ' ') bytes; sha1 $(shasum "$out/agent-harness_0.1.0.zip" | cut -c1-12))"
scan "$out/agent-harness_0.1.0.zip"
