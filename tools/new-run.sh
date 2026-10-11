#!/usr/bin/env bash
# Create an agent workspace: tools/new-run.sh RUN_ID WORLD PLAYER MINUTES
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run=$1 world=$2 player=$3 minutes=$4
# Co-op overrides: POG_WS (workspace name), POG_CLIENT (client dir on the box), POG_PLAYER_INDEX,
# POG_TEAMMATE, POG_TEAMMATE_WS, POG_ROLE.
# Team (bot) runs: POG_BOT (bot name, replaces --player), POG_TEAM (file: "name|model" per line), POG_MODEL,
# POG_ENEMIES (peaceful|normal, default peaceful), POG_SPACE_AGE=1 (Space Age world: appends agent/spaceage.md).
ws=${POG_WS:-$world}
client=${POG_CLIENT:-$world-client}
index=${POG_PLAYER_INDEX:-1}
if [ -n "${POG_BOT:-}" ]; then target="--bot $POG_BOT"; else target="--player $index"; fi
dir="$root/runs/$run/$ws"
mkdir -p "$dir/shots"
mode=${POG_TIME_MODE:-realtime}
time_text=$(cat "$root/agent/time-$mode.md")
coop=""
if [ -n "${POG_TEAMMATE:-}" ]; then coop=$(cat "$root/agent/coop.md"); fi
if [ -n "${POG_TEAM:-}" ]; then
  coop=$(python3 - "$root/agent/team.md" "$POG_TEAM" "$player" "${POG_MODEL:-}" <<'EOT'
import os, sys
tpl, team, me, model = sys.argv[1:]
rows = [l.strip().split("|", 1) for l in open(team) if l.strip()]
roster = "\n".join(f"- `{n}`: {m}" for n, m in rows if n != me)
try:  # stream voices this machine can speak (tools/stream/voices.py: providers with a key, plus Aura-2)
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(tpl)), "..", "tools", "stream"))
    import voices
    voice_list = voices.catalog_markdown(voices.available_providers()).rstrip("\n")
except Exception:
    voice_list = open(os.path.join(os.path.dirname(tpl), "voices.md")).read().rstrip("\n")
voice_list = "\n".join("  " + line for line in voice_list.splitlines())  # nested under the "Voice:" item
print(open(tpl).read().replace("{{TEAM_SIZE}}", str(len(rows))).replace("{{ROSTER}}", roster).replace("{{MODEL}}", model)
      .replace("{{VOICES}}", voice_list), end="")
EOT
)
fi
# AGENTS.md ends with the compaction instructions: Claude Code reads a "Compact instructions" section, and every
# harness's summarizer sees the instructions file.
python3 - "$root/agent/PLAYBOOK.md" "$dir/AGENTS.md" "$player" "$time_text" "$coop" "${POG_TEAMMATE:-}" \
  "$root/runs/$run/${POG_TEAMMATE_WS:-}/notes.md" "${POG_ROLE:-}" "$root/agent/compact.md" <<'EOP'
import sys
src, dst, player, time_text, coop, mate, mate_notes, role, compact = sys.argv[1:]
import os
text = open(src).read().replace("{{TIME}}", time_text) + coop
if os.environ.get("POG_SPACE_AGE") == "1":
    text = text.replace("base game, default map", "Space Age (with Quality and Elevated Rails), default map")
    text = text.rstrip("\n") + "\n" + open(os.path.join(os.path.dirname(src), "spaceage.md")).read()
text = text.rstrip("\n") + "\n\n## Compact instructions\n\n" + open(compact).read()
for k, v in {"PLAYER": player, "TEAMMATE": mate, "TEAMMATE_NOTES": mate_notes, "ROLE": role,
             "ENEMIES": os.environ.get("POG_ENEMIES", "peaceful"), "SEED": os.environ.get("POG_SEED", "20261010")}.items():
    text = text.replace("{{%s}}" % k, v)
open(dst, "w").write(text)
EOP
ln -sf AGENTS.md "$dir/CLAUDE.md"
# The only key fh needs is this world's RCON password: a copy sits beside the workspaces, so the launcher can deny
# agents ~/.config/pog (obs.pw, youtube.key, other worlds' passwords). docs/LAUNCH-NOTES.md: what stays exposed.
keys="$root/runs/$run/.keys"
mkdir -p "$keys" && chmod 700 "$keys"
if [ -f "$HOME/.config/pog/rcon-$world.pw" ]; then
  install -m 600 "$HOME/.config/pog/rcon-$world.pw" "$keys/rcon-$world.pw"
fi
cat > "$dir/fh" <<EOS
#!/usr/bin/env bash
export POG_WORLD=$world POG_RCON_PASSWORD_FILE="$keys/rcon-$world.pw"
# The clock: line on every reply ends with the time left until this deadline.
export FH_DEADLINE_FILE="$dir/deadline.txt"
# Every request and reply is journaled for the run analysis.
exec "$root/bin/fh" "\$@" $target --journal "$dir/journal.jsonl"
EOS
cat > "$dir/shot" <<EOS
#!/usr/bin/env bash
# Real game screenshot centred on the character: ./shot NAME [WIDTH HEIGHT]. A game client renders it (yours, or a
# director's for a bot) into script-output/pog/$ws/; tools/shot-sync.sh copies it from the game box into shots/.
set -euo pipefail
name=\$(printf %s "\${1:?usage: ./shot NAME [WIDTH HEIGHT]}" | tr -c 'A-Za-z0-9_-' _); w=\${2:-1280}; h=\${3:-720}
cd "\$(dirname "\$0")"
tag="\$name-\$(date +%s)-\$RANDOM"
if ! out=\$(POG_WORLD=$world POG_RCON_PASSWORD_FILE="$keys/rcon-$world.pw" "$root/bin/fh" $target call screenshot --args "{\"path\":\"pog/$ws/\$tag.png\",\"width\":\$w,\"height\":\$h}" 2>&1); then
  echo "\$out" >&2; exit 1
fi
for i in \$(seq 1 60); do
  if [ -f "shots/\$tag.png" ]; then mv "shots/\$tag.png" "shots/\$name.png"; echo "shots/\$name.png"; exit 0; fi
  sleep 0.5
done
client=\$(printf '%s\n' "\$out" | sed -n 's/^client: //p')
echo "screenshot failed: \${client:-the game client} rendered it but it was not copied into shots/ within 30 s (operator: is tools/shot-sync.sh running?)" >&2; exit 1
EOS
chmod +x "$dir/fh" "$dir/shot"
date -v+"${minutes}"M "+%Y-%m-%d %H:%M %Z" > "$dir/deadline.txt"
# A later shift of the same world (tools/start-team.sh, POG_RESUME): the agent starts from its notes of that shift.
prev_notes="${POG_RESUME_DIR:-}/$ws/notes.md"
if [ -n "${POG_RESUME:-}" ] && [ -n "${POG_RESUME_DIR:-}" ] && [ -f "$prev_notes" ]; then
  { echo "(Carried over from the previous shift, run $POG_RESUME: its notes.md for $player, as that shift left it.)"
    echo; cat "$prev_notes"; } > "$dir/notes.md"
  echo "$dir"
  exit 0
fi
cat > "$dir/notes.md" <<EON
# Notes ($player, world $world)

## Now
Goal:
Next:
Waiting on:

## Claims and coordinates

## Team agreements

## Open board items

## Milestones

## Lessons

## Log
EON
echo "$dir"
