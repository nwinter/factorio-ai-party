#!/usr/bin/env bash
# Create an agent workspace: tools/new-run.sh RUN_ID WORLD PLAYER MINUTES
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run=$1 world=$2 player=$3 minutes=$4
dir="$root/runs/$run/$world"
mkdir -p "$dir/shots"
mode=${POG_TIME_MODE:-realtime}
time_text=$(cat "$root/agent/time-$mode.md")
python3 - "$root/agent/PLAYBOOK.md" "$dir/AGENTS.md" "$player" "$time_text" <<'EOP'
import sys
src, dst, player, time_text = sys.argv[1:]
open(dst, "w").write(open(src).read().replace("{{PLAYER}}", player).replace("{{TIME}}", time_text))
EOP
ln -sf AGENTS.md "$dir/CLAUDE.md"
cat > "$dir/fh" <<EOS
#!/usr/bin/env bash
export POG_WORLD=$world
exec "$root/bin/fh" "\$@"
EOS
cat > "$dir/shot" <<EOS
#!/usr/bin/env bash
# Real screenshot from the agent's game client, centred on the character: ./shot NAME [WIDTH HEIGHT]
# tools/shot-sync.sh copies it from the game box into shots/.
set -euo pipefail
name=\${1:?name}; w=\${2:-1280}; h=\${3:-720}
cd "\$(dirname "\$0")"
tag="\$name-\$(date +%s)-\$RANDOM"
POG_WORLD=$world "$root/bin/fh" call screenshot --args "{\"path\":\"pog/\$tag.png\",\"width\":\$w,\"height\":\$h}" >/dev/null
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
