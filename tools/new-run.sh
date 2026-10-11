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
import sys
tpl, team, me, model = sys.argv[1:]
rows = [l.strip().split("|", 1) for l in open(team) if l.strip()]
roster = "\n".join(f"- `{n}`: {m}" for n, m in rows if n != me)
print(open(tpl).read().replace("{{TEAM_SIZE}}", str(len(rows))).replace("{{ROSTER}}", roster).replace("{{MODEL}}", model), end="")
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
cat > "$dir/fh" <<EOS
#!/usr/bin/env bash
export POG_WORLD=$world
# The clock: line on every reply ends with the time left until this deadline.
export FH_DEADLINE_FILE="$dir/deadline.txt"
# Every request and reply is journaled for the run analysis.
exec "$root/bin/fh" "\$@" $target --journal "$dir/journal.jsonl"
EOS
cat > "$dir/shot" <<EOS
#!/usr/bin/env bash
# Real screenshot from the agent's game client, centred on the character: ./shot NAME [WIDTH HEIGHT]
# tools/shot-sync.sh copies it from the game box into shots/.
set -euo pipefail
name=\${1:?name}; w=\${2:-1280}; h=\${3:-720}
cd "\$(dirname "\$0")"
tag="\$name-\$(date +%s)-\$RANDOM"
POG_WORLD=$world "$root/bin/fh" $target call screenshot --args "{\"path\":\"pog/\$tag.png\",\"width\":\$w,\"height\":\$h}" >/dev/null
for i in \$(seq 1 40); do
  if [ -f "shots/\$tag.png" ]; then mv "shots/\$tag.png" "shots/\$name.png"; echo "shots/\$name.png"; exit 0; fi
  sleep 0.5
done
echo "screenshot failed: not delivered within 20 s" >&2; exit 1
EOS
chmod +x "$dir/fh" "$dir/shot"
date -v+"${minutes}"M "+%Y-%m-%d %H:%M %Z" > "$dir/deadline.txt"
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
