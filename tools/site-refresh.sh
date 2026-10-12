#!/usr/bin/env bash
# Rebuild and deploy the companion site, so the long run's page (/runs/long/) has the shift that just ended:
#   tools/site-refresh.sh [--last-run RUN] [--no-deploy]
# 1. --last-run RUN: site/live/status.json's last run becomes RUN (site/status_update.py: "Shift N of the long run").
# 2. Build: python3 site/build.py --runs-dir RUNS (the main checkout's runs/, where the shift folders are; POG_SITE_RUNS
#    overrides).
# 3. Check: site/check.py, site/test_live.py, site/test_longrun.py. Any failure stops here: nothing is deployed.
# 4. Deploy: wrangler pages deploy to the preview branch, then to production (main) only if the preview went up.
# Exit 0 when deployed (or built and checked with --no-deploy), 1 when a step failed (the log says which).
# tools/shift-change.sh runs it in the background after the previous shift stops; it never blocks a shift.
# Stubs for tests: POG_WRANGLER (the deploy command, split on spaces; default npx wrangler), POG_SITE_OUT (build dir),
# POG_SITE_STATUS (the status.json to update).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
last="" deploy=1
while [ $# -gt 0 ]; do
  case $1 in
    --last-run) last=${2:?--last-run needs a run id}; shift ;;
    --no-deploy) deploy=0 ;;
    *) echo "usage: tools/site-refresh.sh [--last-run RUN] [--no-deploy]" >&2; exit 64 ;;
  esac
  shift
done
runs=${POG_SITE_RUNS:-}
if [ -z "$runs" ]; then
  runs=$root/runs
  ls "$runs"/*/resumed-from >/dev/null 2>&1 || runs=$HOME/code/player-of-games/runs  # a worktree without the shifts
fi
out=${POG_SITE_OUT:-$root/site/dist}
status=${POG_SITE_STATUS:-$root/site/live/status.json}
read -ra wrangler <<<"${POG_WRANGLER:-npx wrangler}"
ts() { date +%H:%M:%S; }
step() { echo "$(ts) site-refresh: $*"; }
fail() { step "FAILED: $*"; exit 1; }

step "start (runs $runs, out $out${last:+, last run $last})"
if [ -n "$last" ]; then
  python3 site/status_update.py "$last" --runs-dir "$runs" --status "$status" || fail "status.json update"
fi
python3 site/build.py --out "$out" --runs-dir "$runs" || fail "build"
[ "$status" = "$root/site/live/status.json" ] || cp "$status" "$out/live/status.json"  # a test's own status file
python3 site/check.py "$out" || fail "check.py"
python3 site/test_live.py || fail "test_live.py"
python3 site/test_longrun.py || fail "test_longrun.py"
step "built and checked"
[ $deploy = 1 ] || { step "done (--no-deploy)"; exit 0; }
for branch in preview main; do
  "${wrangler[@]}" pages deploy "$out" --project-name player-of-games --branch "$branch" --commit-dirty=true \
    || fail "deploy to $branch (production left as it was$([ $branch = main ] && echo '; preview has the new build'))"
  step "deployed to $branch"
done
step "done"
