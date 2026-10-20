#!/usr/bin/env bash
# Create an agent workspace: tools/new-run.sh RUN_ID WORLD PLAYER MINUTES
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run=$1 world=$2 player=$3 minutes=$4
# Co-op overrides: POG_WS (workspace name), POG_CLIENT (client dir on the box), POG_PLAYER_INDEX,
# POG_TEAMMATE, POG_TEAMMATE_WS, POG_ROLE.
# Team (bot) runs: POG_BOT (bot name, replaces --player), POG_TEAM (file: "name|model" per line), POG_MODEL,
# POG_ENEMIES (peaceful|normal, default peaceful), POG_SPACE_AGE=1 (Space Age world: agent/spaceage.md heads ref/space-age.md).
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
if [ -n "${POG_TEAM:-}" ]; then coop=$(python3 "$root/tools/brief.py" team "$POG_TEAM" "$player" "${POG_MODEL:-}"); fi
# AGENTS.md is the core every agent reads in every context window (PLAYBOOK, team, the index of reference topics, the
# compaction instructions); ref/ holds the topic files `./fh help TOPIC` prints, and ref/commands.tsv the topic of each
# command that fh names in an argument refusal (tools/brief.py).
python3 "$root/tools/brief.py" write "$dir" "$player" "$time_text" "$coop" "${POG_TEAMMATE:-}" \
  "$root/runs/$run/${POG_TEAMMATE_WS:-}/notes.md" "${POG_ROLE:-}"
ln -sf AGENTS.md "$dir/CLAUDE.md"
# The only key fh needs is this world's RCON password: a copy sits beside the workspaces, so the launcher can deny
# agents ~/.config/pog (obs.pw, youtube.key, other worlds' passwords). docs/LAUNCH-NOTES.md: what stays exposed.
# POG_BROKER=1: no key in the run at all. The operator's RCON broker (tools/fh_broker.py) holds the password and
# serves this bot's socket, runs/RUN/.sock/BOT.sock; fh and shot talk to it (POG_FH_SOCKET).
keys="$root/runs/$run/.keys"
if [ "${POG_BROKER:-0}" = 1 ]; then
  conn="POG_FH_SOCKET=\"$root/runs/$run/.sock/${POG_BOT:-$ws}.sock\""
else
  mkdir -p "$keys" && chmod 700 "$keys"
  if [ -f "$HOME/.config/pog/rcon-$world.pw" ]; then
    install -m 600 "$HOME/.config/pog/rcon-$world.pw" "$keys/rcon-$world.pw"
  fi
  conn="POG_RCON_PASSWORD_FILE=\"$keys/rcon-$world.pw\""
fi
cat > "$dir/fh" <<EOS
#!/usr/bin/env bash
export POG_WORLD=$world $conn
# The agents' wait cap (tools/sleepcap/run) is not for fh's own waits.
export POG_SLEEP_CAP=0
# The clock: line on every reply ends with the time left until this deadline.
export FH_DEADLINE_FILE="$dir/deadline.txt"
# fh help TOPIC prints ref/TOPIC.md; an argument refusal names the topic of the call (ref/commands.tsv).
export FH_REF_DIR="$dir/ref"
# Every request and reply is journaled for the run analysis.
exec "$root/bin/fh" "\$@" $target --journal "$dir/journal.jsonl"
EOS
cat > "$dir/shot" <<EOS
#!/usr/bin/env bash
# Real game screenshot: ./shot NAME [WIDTH HEIGHT] [at=X,Y] [surface=PLANET | platform=NAME]. Centred on the character,
# or with at= on that position by remote view (every chunk of the frame one our force sees now; refused otherwise, with
# the nearest radar coverage). A game client renders it (yours, or a director's for a bot) into
# script-output/pog/$ws/; tools/shot-sync.sh copies it from the game box into shots/.
set -euo pipefail
export POG_SLEEP_CAP=0   # the agents' wait cap (tools/sleepcap/run) is not for this script's waits
usage="usage: ./shot NAME [WIDTH HEIGHT] [at=X,Y] [surface=PLANET | platform=NAME]"
name=\$(printf %s "\${1:?\$usage}" | tr -c 'A-Za-z0-9_-' _); shift
dims=(); extra=""
for arg in "\$@"; do
  case "\$arg" in
    at=*) xy=\${arg#at=}; x=\${xy%%,*}; y=\${xy#*,}
      [[ \$xy == *,* && \$x =~ ^-?[0-9]+(\.[0-9]+)?\$ && \$y =~ ^-?[0-9]+(\.[0-9]+)?\$ ]] || { echo "\$usage" >&2; exit 2; }
      extra="\$extra,\\"position\\":{\\"x\\":\$x,\\"y\\":\$y}" ;;
    surface=*|platform=*) v=\${arg#*=}
      [[ \$v =~ ^[A-Za-z0-9\ _.:-]+\$ ]] || { echo "\$usage" >&2; exit 2; }
      extra="\$extra,\\"\${arg%%=*}\\":\\"\$v\\"" ;;
    *) dims+=("\$arg") ;;
  esac
done
w=\${dims[0]:-1280}; h=\${dims[1]:-720}
cd "\$(dirname "\$0")"
tag="\$name-\$(date +%s)-\$RANDOM"
if ! out=\$(env POG_WORLD=$world $conn "$root/bin/fh" $target call screenshot --args "{\"path\":\"pog/$ws/\$tag.png\",\"width\":\$w,\"height\":\$h\$extra}" 2>&1); then
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
  # with a "## Last shift, measured" section from that shift's journal and capped at 16 KB (tools/handover.py; the
  # full text goes to notes-archive.md); plain copy if that fails
  python3 "$root/tools/handover.py" carry "$prev_notes" "${POG_RESUME_DIR}/$ws/journal.jsonl" "$dir/notes.md" \
      "$POG_RESUME" "$player" >/dev/null 2>&1 ||
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
