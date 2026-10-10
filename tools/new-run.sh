#!/usr/bin/env bash
# Create an agent workspace: tools/new-run.sh RUN_ID WORLD PLAYER MINUTES
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run=$1 world=$2 player=$3 minutes=$4
# Co-op overrides: POG_WS (workspace name), POG_CLIENT (client dir on the box), POG_PLAYER_INDEX,
# POG_TEAMMATE, POG_TEAMMATE_WS, POG_ROLE.
ws=${POG_WS:-$world}
client=${POG_CLIENT:-$world-client}
index=${POG_PLAYER_INDEX:-1}
dir="$root/runs/$run/$ws"
mkdir -p "$dir/shots"
mode=${POG_TIME_MODE:-realtime}
time_text=$(cat "$root/agent/time-$mode.md")
coop=""
if [ -n "${POG_TEAMMATE:-}" ]; then coop=$(cat "$root/agent/coop.md"); fi
python3 - "$root/agent/PLAYBOOK.md" "$dir/AGENTS.md" "$player" "$time_text" "$coop" "${POG_TEAMMATE:-}" \
  "$root/runs/$run/${POG_TEAMMATE_WS:-}/notes.md" "${POG_ROLE:-}" <<'EOP'
import sys
src, dst, player, time_text, coop, mate, mate_notes, role = sys.argv[1:]
text = open(src).read().replace("{{TIME}}", time_text) + coop
for k, v in {"PLAYER": player, "TEAMMATE": mate, "TEAMMATE_NOTES": mate_notes, "ROLE": role}.items():
    text = text.replace("{{%s}}" % k, v)
open(dst, "w").write(text)
EOP
ln -sf AGENTS.md "$dir/CLAUDE.md"
cat > "$dir/fh" <<EOS
#!/usr/bin/env bash
export POG_WORLD=$world
# Every request and reply is journaled for the run analysis.
exec "$root/bin/fh" "\$@" --player $index --journal "$dir/journal.jsonl"
EOS
cat > "$dir/shot" <<EOS
#!/usr/bin/env bash
# Real screenshot from the agent's game client, centred on the character: ./shot NAME [WIDTH HEIGHT]
# tools/shot-sync.sh copies it from the game box into shots/.
set -euo pipefail
name=\${1:?name}; w=\${2:-1280}; h=\${3:-720}
cd "\$(dirname "\$0")"
tag="\$name-\$(date +%s)-\$RANDOM"
POG_WORLD=$world "$root/bin/fh" --player $index call screenshot --args "{\"path\":\"pog/\$tag.png\",\"width\":\$w,\"height\":\$h}" >/dev/null
for i in \$(seq 1 40); do
  if [ -f "shots/\$tag.png" ]; then mv "shots/\$tag.png" "shots/\$name.png"; echo "shots/\$name.png"; exit 0; fi
  sleep 0.5
done
echo "screenshot failed: not delivered within 20 s" >&2; exit 1
EOS
chmod +x "$dir/fh" "$dir/shot"
date -v+"${minutes}"M "+%Y-%m-%d %H:%M %Z" > "$dir/deadline.txt"
printf '# Notes (%s, world %s)\n\n' "$player" "$world" > "$dir/notes.md"
echo "$dir"
