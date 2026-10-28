#!/usr/bin/env bash
# Rebuild and deploy the companion site, so the long run's page (/runs/long/) has the shift that just ended:
#   tools/site-refresh.sh [--last-run RUN] [--no-deploy]
# 1. --last-run RUN: site/live/status.json's last run becomes RUN (site/status_update.py: "Shift N of the long run").
# 2. Build: python3 site/build.py --runs-dir RUNS (the main checkout's runs/, where the shift folders are; POG_SITE_RUNS
#    overrides).
# 3. Check: site/check.py, site/test_live.py, site/test_longrun.py, site/test_archive.py, site/test_agents.py. Any
#    failure stops here:
#    nothing is deployed.
# 4. Deploy: wrangler pages deploy to the preview branch, then to production (main) only if the preview went up.
# Exit 0 when deployed (or built and checked with --no-deploy), 1 when a step failed (the log says which).
# tools/shift-change.sh runs it in the background after the previous shift stops; it never blocks a shift.
# Stubs for tests: POG_WRANGLER (the deploy command, split on spaces; default npx wrangler), POG_SITE_OUT (build dir),
# POG_SITE_STATUS (the status.json to update), POG_SITE_SOURCE and POG_SITE_WORKTREE (the clean copy of main, below).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
last="" deploy=1 args=("$@")
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
# (d22 batch97 BG3) one refresh at a time: the hourly one (tools/start-team.sh) and a shift change's can meet; the
# second waits for the first (a lock directory with its pid; one whose pid is gone is taken over), up to 10 minutes.
lock=${POG_SITE_REFRESH_LOCK:-${TMPDIR:-/tmp}/pog-site-refresh.lock}
waited=0
until [ -n "${POG_SITE_INNER:-}" ] || mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  [ $waited -ge ${POG_SITE_REFRESH_WAIT:-600} ] && fail "another site refresh (pid ${holder:-?}) held the lock for ${waited} s"
  [ $waited = 0 ] && step "waiting for another site refresh (pid ${holder:-?})"
  sleep 5; waited=$((waited + 5))
done
if [ -z "${POG_SITE_INNER:-}" ]; then
  echo $$ > "$lock/pid"
  trap 'rm -rf "$lock"' EXIT
fi
# (d27 batch290) never from a half-merged tree, and never skipped for one: the gate merges a branch in this checkout,
# runs the tests, then commits, all afternoon (batch265 skipped while MERGE_HEAD existed, and the site stayed at its
# 15:19 build). The refresh runs the clean copy of main's own site-refresh.sh (tools/clean-main.sh: a detached worktree,
# POG_SITE_WORKTREE, default worktrees/pog-site-refresh) under this lock, with what the build reads and writes outside
# git linked to this checkout's: runs/, site/live/status.json (changed here by status_update.py), site/content/r2.json,
# site/og/shifts/, site/og/thumbs/ and site/.wrangler/; the build goes to this checkout's site/dist as before.
# POG_SITE_CLEAN=0 builds in place (a test run without POG_SITE_WORKTREE always does).
if [ -z "${POG_SITE_INNER:-}" ] && [ "${POG_SITE_CLEAN:-1}" != 0 ] &&
   { [ "${POG_TEST:-0}" != 1 ] || [ -n "${POG_SITE_WORKTREE:-}" ]; }; then
  wt=${POG_SITE_WORKTREE:-$HOME/code/personal/player-of-games/worktrees/pog-site-refresh}
  at=$(tools/clean-main.sh "${POG_SITE_SOURCE:-$root}" "$wt" runs/ site/live/status.json site/content/r2.json \
       site/og/shifts/ site/og/thumbs/ site/.wrangler/ 2>&1) || fail "the clean copy of main: $(echo "$at" | tail -1)"
  step "from the clean copy of main ${at:0:8} ($wt)"
  POG_SITE_INNER=1 POG_SITE_OUT=$out POG_SITE_RUNS=$runs bash "$wt/tools/site-refresh.sh" ${args[@]+"${args[@]}"}
  exit $?
fi
# (d26 batch241) OUT.deployed: the build in OUT is the one production has (site/chart_deploy.py deploys the chart only
# into such a build); gone from the start of a build until its production deploy
rm -f "$out.deployed"
if [ -n "$last" ]; then
  python3 site/status_update.py "$last" --runs-dir "$runs" --status "$status" || fail "status.json update"
fi
# each shift's link-preview card, drawn again only when its numbers changed; a failure keeps the site's card
# (POG_SITE_CARDS=0 skips it: tests)
if [ "${POG_SITE_CARDS:-1}" != 0 ]; then
  python3 site/og_card.py --shifts --runs-dir "$runs" || step "shift cards failed (shift pages keep the site's card)"
fi
# (batch265) /videos/: which shifts play on R2 now (each master playlist must answer 200) and the thumbnails; a failure
# keeps the last r2.json (POG_SITE_VIDEOS=0 skips it and builds without video data: tests)
videos=()
if [ "${POG_SITE_VIDEOS:-1}" != 0 ]; then
  python3 site/videos_page.py refresh --runs-dir "$runs" || step "videos refresh failed (the last r2.json stays)"
  # build.py reads the video data only when named (a test's build never sees this checkout's files)
  videos=(--videos site/content/videos.json --r2 site/content/r2.json --thumbs site/og/thumbs)
fi
# (batch290) the public repo sync's status on the Updates page (tools/public-push.sh); a test run only with POG_PUBLIC_DIR
pubdir=${POG_PUBLIC_DIR:-}; [ -z "$pubdir" ] && [ "${POG_TEST:-0}" != 1 ] && pubdir=$HOME/.cache/pog-public
[ -n "$pubdir" ] && [ -f "$pubdir/status.json" ] && videos+=(--public-status "$pubdir/status.json")
python3 site/build.py --out "$out" --runs-dir "$runs" ${videos[@]+"${videos[@]}"} || fail "build"
[ "$status" = "$root/site/live/status.json" ] || cp "$status" "$out/live/status.json"  # a test's own status file
python3 site/check.py "$out" || fail "check.py"
python3 site/test_live.py || fail "test_live.py"
python3 site/test_longrun.py || fail "test_longrun.py"
python3 site/test_archive.py || fail "test_archive.py"
python3 site/test_agents.py || fail "test_agents.py"
python3 site/test_moderation.py || fail "test_moderation.py"
python3 site/test_videos_page.py || fail "test_videos_page.py"
step "built and checked"
[ $deploy = 1 ] || { step "done (--no-deploy)"; exit 0; }
for branch in preview main; do
  "${wrangler[@]}" pages deploy "$out" --project-name player-of-games --branch "$branch" --commit-dirty=true \
    || fail "deploy to $branch (production left as it was$([ $branch = main ] && echo '; preview has the new build'))"
  step "deployed to $branch"
done
date +%s > "$out.deployed"
cp "$out.deployed" "$out.last-deploy"   # kept through later builds: tools/freshness.py reads it
step "done"
