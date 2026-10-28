#!/usr/bin/env bash
# The public run's first shift, from scratch (Nick, 2026-10-12: it reads as a first attempt to viewers and agents):
#   POG_SEED=N tools/public-start.sh RUN YOUTUBE_VIDEO_ID [MINUTES] [--dry-run]
# 1. Checks, refusing with the reason: POG_SEED set and not the test seed (20261010), RUN new, a video id, no stream
#    service running (the previous shift stopped), OBS reachable.
# 2. Every other run folder moves out of runs/ to POG_ARCHIVE (default ~/code/personal/player-of-games/artifacts/pog-archive/runs-YYYYMMDD; a rename on
#    the same disk): agents list ../.. from their workspaces and could read the test runs' notes. The ones git tracks
#    leave the index in one commit (history keeps them). The site's archive pages build from there again with
#    POG_SITE_RUNS=$POG_ARCHIVE and "archive": true.
# 3. site/content/site.json run_start = RUN (committed); the site's chat so far is hidden (POST /v1/mod clear).
# 4. tools/start-team.sh RUN MINUTES --stream on a fresh world (seed POG_SEED, Space Age, normal enemies) with the
#    long run's switches: broker, full tools, hosts (Opus, Sonnet urgent, Haiku while nobody new is watching),
#    analyst, viewer relay, players' votes off. Later shifts: tools/shift-change.sh RUN NEXT 240 --stream.
# 5. tools/site-refresh.sh in the background (log runs/RUN/site-refresh.log).
# --dry-run: the checks and the plan, with start-team's own dry run; moves and starts nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
dry=0 args=()
for a in "$@"; do [ "$a" = --dry-run ] && dry=1 || args+=("$a"); done
run=${args[0]:-} video=${args[1]:-} minutes=${args[2]:-240}
[ -n "$run" ] && [ -n "$video" ] || { sed -n 2,3p "$0"; exit 2; }
seed=${POG_SEED:-}
archive=${POG_ARCHIVE:-$HOME/code/personal/player-of-games/artifacts/pog-archive/runs-$(date +%Y%m%d)}
fail() { echo "public-start: refused: $*" >&2; exit 1; }
[ -n "$seed" ] || fail "set POG_SEED (a new map; the test runs all used 20261010)"
[ "$seed" != 20261010 ] || fail "POG_SEED 20261010 is the test runs' map"
[ ! -e "runs/$run" ] || fail "runs/$run exists"
if pgrep -f "tools/stream/serve.py" >/dev/null; then
  [ "$dry" = 1 ] && echo "public-start: note: a stream service is running (a real start refuses until it stops)" \
    || fail "a stream service is running: stop the previous shift first"
fi
py=tools/.venv/bin/python
"$py" tools/obs.py stream-status >/dev/null 2>&1 || fail "OBS is not reachable (start it on the box)"
old=$(ls runs | grep -vx "$run" | grep -vx _tests || true)
tracked=$(git ls-files runs | cut -d/ -f2 | sort -u | grep -vx "$run" || true)
switches=(POG_BROKER=1 POG_FULL_TOOLS=1 POG_SPACE_AGE=1 "POG_YOUTUBE=$video" POG_CASTER=1
  POG_CASTER_MODEL=anthropic/claude-opus-5.5 POG_CASTER_URGENT=or:anthropic/claude-sonnet-5.5
  POG_CASTER_LOW_MODEL=anthropic/claude-haiku-5.5 POG_ANALYST=1 POG_PLAYERS=0 POG_VIEWER_RELAY=1
  POG_TEAM_FILE=agent/team-nine.tsv POG_ENEMIES=normal "POG_SEED=$seed")
echo "plan: move $(printf '%s\n' "$old" | grep -c . || true) run folders to $archive ($(printf '%s\n' "$tracked" | grep -c . || true) tracked by git);"
echo "      site run_start=$run, site chat cleared; env ${switches[*]} tools/start-team.sh $run $minutes --stream"
if [ "$dry" = 1 ]; then
  env "${switches[@]}" POG_DRY_RUN=1 tools/start-team.sh "$run" "$minutes" --stream
  exit 0
fi
mkdir -p "$archive"
for r in $old; do mv "runs/$r" "$archive/"; done
if [ -n "$tracked" ]; then
  for r in $tracked; do git rm -r -q --cached "runs/$r"; done
  git commit -q -m "Test runs moved out of the repo to $archive before the public run (history keeps them)"
fi
python3 - "$run" <<'EOF'
import re, sys
p = "site/content/site.json"
t = open(p).read()
t2 = re.sub(r'"run_start": "[^"]*"', f'"run_start": "{sys.argv[1]}"', t, count=1)
assert t2 != t or f'"run_start": "{sys.argv[1]}"' in t, "site.json has no run_start"
open(p, "w").write(t2)
EOF
git add site/content/site.json && git commit -q -m "Site: the public run starts at $run" || true
tok=${POG_LIVE_TOKEN:-$(python3 -c 'import json; print(json.load(open("site/worker/.secrets.json"))["PUBLISH_TOKEN"])')}
curl -fsS -X POST -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d '{"action":"clear"}' \
  https://player-of-games-live.your-subdomain.workers.dev/v1/mod >/dev/null && echo "site chat cleared"
env "${switches[@]}" tools/start-team.sh "$run" "$minutes" --stream
nohup tools/site-refresh.sh >"runs/$run/site-refresh.log" 2>&1 &
echo "public-start: $run started; site refresh in the background (runs/$run/site-refresh.log)"
