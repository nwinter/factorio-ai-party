#!/usr/bin/env bash
# Bring the public repo (github.com/nwinter/factorio-ai-party) up to main, as a fast-forward:
#   tools/public-push.sh                      one run
#   tools/public-push.sh --start-loop RUNDIR  the loop, once per Mac (tools/start-team.sh); its lines also go to
#                                             RUNDIR/public-push.log while that run is the newest started
#   tools/public-push.sh --check-loop | --stop-loop
# 1. One run at a time (a lock; one whose pid is gone is taken over). A run that finds main is the commit the last run
#    pushed or failed on says so in one line (a failure is said once, not every hour).
# 2. (d27 batch290) The scrub runs from a clean copy of main: a detached worktree of the source (POG_PUBLIC_WORKTREE,
#    made if missing) moved to main's commit at the start of each run, so the main checkout's working tree (the gate
#    merges branches there all day) never matters. batch272 skipped while the main checkout had MERGE_HEAD, and the
#    hourly run landed in a gate merge at 16:22 and 17:22.
# 3. tools/public_sync.py (the worktree's) into a fresh WORKDIR: the scrubbed history of main (same source, same hashes)
#    and its scan, with DIR/cache (blobs already rewritten and scanned under the same rules and secrets are not read
#    again). A scan finding (exit 1) or any other failure: a FAILED line, nothing pushed.
# 4. Fetches the public main; pushes main only when the public main is an ancestor of the new one (never forced). A
#    public main that is not an ancestor: a FAILED line, nothing pushed.
# Exit 0: pushed or up to date (the loop runs again in POG_PUBLIC_EVERY s, 3600); 1: failed for this main (a FAILED
# line); 75: skipped or delayed (the lock was held, the fetch or push failed, main is the commit that failed): the loop
# runs again in POG_PUBLIC_RETRY s (600). Lines start with HH:MM:SS public-push:, every failure with
# "public-push: FAILED". DIR/status.json is what the site's Updates page shows (site/updates.py public_repo): the last
# successful sync (time, public main, the main it came from), when it last checked, and the newest failure or delay
# with a fixed reason (no paths, no error text). The newest summary is copied to DIR/public-sync-summary.md; the two
# newest run folders are kept.
# The loop belongs to no shift: tools/stop-team.sh leaves it running, a stream-service restart does not touch it, and
# each tools/start-team.sh starts it when DIR/loop.pid names no live loop (after a reboot or a kill). Its own log is
# DIR/public-push.log. Paths and commands (tests): POG_PUBLIC_SOURCE (the repo whose main is published; default the
# main checkout), POG_PUBLIC_WORKTREE (the clean copy; default worktrees/pog-public-push), POG_PUBLIC_REMOTE,
# POG_PUBLIC_DIR (default ~/.cache/pog-public), POG_PUBLIC_SYNC (the sync command, split on spaces; run in the
# worktree), POG_PUBLIC_EVERY, POG_PUBLIC_RETRY, POG_PUBLIC_FIRST (the loop's first wait, 600 s).
set -uo pipefail
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
# a test run (POG_TEST=1) never pushes to the public repo nor reads the main checkout: it must name all four
if [ "${POG_TEST:-0}" = 1 ] && { [ -z "${POG_PUBLIC_REMOTE:-}" ] || [ -z "${POG_PUBLIC_SOURCE:-}" ] ||
                                  [ -z "${POG_PUBLIC_WORKTREE:-}" ] || [ -z "${POG_PUBLIC_DIR:-}" ]; }; then
  echo "POG_TEST=1: no public push without POG_PUBLIC_REMOTE, POG_PUBLIC_SOURCE, POG_PUBLIC_WORKTREE and POG_PUBLIC_DIR"
  exit 2
fi
src=${POG_PUBLIC_SOURCE:-$HOME/code/player-of-games}
wt=${POG_PUBLIC_WORKTREE:-$HOME/code/personal/player-of-games/worktrees/pog-public-push}
remote=${POG_PUBLIC_REMOTE:-git@github.com:nwinter/factorio-ai-party.git}
dir=${POG_PUBLIC_DIR:-$HOME/.cache/pog-public}
every=${POG_PUBLIC_EVERY:-3600} retry=${POG_PUBLIC_RETRY:-600}
ts() { date +%H:%M:%S; }

loop_pid() {   # the live loop's pid, else nothing
  local p
  p=$(cat "$dir/loop.pid" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ps -o command= -p "$p" 2>/dev/null | grep -q "public-push.sh --loop" &&
    echo "$p"
}
case "${1:-}" in
  --check-loop)
    if p=$(loop_pid); then echo "running (pid $p, log $dir/public-push.log)"; exit 0; fi
    echo "not running"; exit 1 ;;
  --stop-loop)
    if p=$(loop_pid); then kill "$p" && echo "stopped the loop (pid $p)"; else echo "no loop running"; fi
    exit 0 ;;
  --start-loop)
    run=${2:?--start-loop needs the run folder}
    mkdir -p "$dir" || { echo "$(ts) public-push: FAILED: cannot make $dir"; exit 1; }
    (cd "$run" 2>/dev/null && pwd) > "$dir/current-run"   # where the runs' lines go too (the newest started run)
    if p=$(loop_pid); then echo "public-push loop running (pid $p): kept; log $dir/public-push.log"; exit 0; fi
    nohup bash "$self" --loop >>"$dir/public-push.log" 2>&1 &
    echo $! > "$dir/loop.pid"
    echo "public-push loop started: pid $!, first run in ${POG_PUBLIC_FIRST:-600} s, then every $every s (${retry} s after a skip); log $dir/public-push.log"
    exit 0 ;;
  --loop)
    wait=${POG_PUBLIC_FIRST:-600}
    while sleep "$wait"; do
      bash "$self"   # read again each time: a merged change to this file is the next run's
      rc=$?
      # the site and the public repo older than 2 h: a "freshness: STALE" line here and in the newest run's log
      cur=$(cat "$dir/current-run" 2>/dev/null || true)
      python3 "$(dirname "$self")/freshness.py" ${cur:+--log "$cur/public-push.log"}
      if [ $rc = 0 ]; then wait=$every; else wait=$retry; fi
    done
    exit 0 ;;
  "") ;;
  *) echo "usage: tools/public-push.sh [--start-loop RUNDIR | --check-loop | --stop-loop]" >&2; exit 64 ;;
esac

read -ra sync <<<"${POG_PUBLIC_SYNC:-python3 $wt/tools/public_sync.py}"
t0=$(date +%s)
runlog=$(cat "$dir/current-run" 2>/dev/null || true)
[ -n "$runlog" ] && [ -d "$runlog" ] && runlog=$runlog/public-push.log || runlog=""
say() {
  local line
  line="$(ts) public-push: $*"
  echo "$line"
  [ -n "$runlog" ] && echo "$line" >> "$runlog"
  return 0
}
# DIR/status.json for the site: status checked | ok PUBLIC PUSHED | problem failed|delayed REASON. The reasons are
# fixed phrases (no paths, no error text: the site shows them).
status() {
  python3 - "$dir/status.json" "$head" "$every" "$retry" "$@" <<'PY' || true
import datetime, json, os, sys
path, head, every, retry, what, *rest = sys.argv[1:]
try:
    s = json.load(open(path))
except (OSError, ValueError):
    s = {}
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
num = lambda x: int(float(x)) if float(x).is_integer() else float(x)
s.update(schema=1, checked=now, every_s=num(every), retry_s=num(retry))
if what == "ok":
    s["ok"] = {"t": now, "public": rest[0], "source": head, "pushed": int(rest[1])}
elif what == "problem":
    s["problem"] = {"t": now, "kind": rest[0], "reason": rest[1], "source": head}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=1)
    f.write("\n")
os.replace(tmp, path)
PY
}
# delayed: said, the loop tries again in RETRY s; fail: said once for this main (a scan finding, not a fast-forward)
delayed() { local why=$1; shift; say "FAILED: $* (after $(( $(date +%s) - t0 )) s)"; status problem delayed "$why"; exit 75; }
fail() {
  local why=$1; shift
  echo "$head failed $(date +%s)" > "$dir/last"
  say "FAILED: $* (after $(( $(date +%s) - t0 )) s)"; status problem failed "$why"; exit 1
}
head=""

mkdir -p "$dir" || { say "FAILED: cannot make $dir"; exit 75; }
lock=$dir/lock
until mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  say "skipped: another run (pid ${holder:-?}) holds $lock; the loop tries again in $retry s"
  status problem delayed "another public push was still running"
  exit 75
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

head=$(git -C "$src" rev-parse -q --verify refs/heads/main) ||
  delayed "the source repository had no main branch" "no main in $src"
read -r last_head last_state last_t < "$dir/last" 2>/dev/null || true
if [ "${last_head:-}" = "$head" ]; then
  if [ "$last_state" = failed ]; then
    say "skipped: main ${head:0:8} is the commit that failed at $(date -r "${last_t:-0}" +%H:%M) (see $dir/public-sync-summary.md); the loop looks for a new main in $retry s"
    status checked
    exit 75
  fi
  say "up to date: main ${head:0:8} was pushed at $(date -r "${last_t:-0}" +%H:%M)"
  status checked
  exit 0
fi

# The clean copy of main (tools/clean-main.sh): the worktree at main's commit, nothing else in it. A folder there that
# is not a worktree of the source is left alone (a FAILED line).
made=""; [ -e "$wt" ] || made=1
at=$(bash "$(dirname "$self")/clean-main.sh" "$src" "$wt" 2>"$dir/worktree.err") ||
  delayed "the clean copy of main could not be made" "$(tail -1 "$dir/worktree.err")"
[ -n "$made" ] && say "made the clean copy of main: $wt"
[ "$at" = "$head" ] || head=$at   # main moved since the check above: this run publishes the commit the copy is at

run=$dir/runs/$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$run" || delayed "the run folder could not be made" "cannot make $run"
say "sync of main ${head:0:8} into $run/work (from $wt)"
(cd "$wt" && "${sync[@]}" "$run/work" --source "$src" --ref main --cache "$dir/cache") > "$run/sync.log" 2>&1
rc=$?
[ -f "$run/public-sync-summary.md" ] && cp "$run/public-sync-summary.md" "$dir/public-sync-summary.md"
if [ $rc -ne 0 ]; then
  n=$(grep -c ':[0-9]*: ' "$run/sync.log" || true)
  if [ $rc = 1 ] && [ "$n" -gt 0 ]; then why="the scan found $n findings in main ${head:0:8}; nothing pushed"
  else why="the scrub of main ${head:0:8} failed (exit $rc); nothing pushed"; fi
  fail "$why" "sync exit $rc, $n scan findings; nothing pushed (log $run/sync.log, summary $dir/public-sync-summary.md)"
fi
# the summary's title names the source commit; main may have moved since rev-parse
synced=$(sed -n '1s/^# Public history of main (\([0-9a-f]*\)).*/\1/p' "$run/public-sync-summary.md" 2>/dev/null)
[ -n "$synced" ] && [ "${head:0:${#synced}}" != "$synced" ] && head=$(git -C "$src" rev-parse "$synced")
new=$(git -C "$run/work" rev-parse main) || fail "the scrub of main ${head:0:8} made no main; nothing pushed" "no main in $run/work"
say "synced in $(( $(date +%s) - t0 )) s: public main would be ${new:0:8}"
git -C "$run/work" fetch -q "$remote" "+refs/heads/main:refs/public/main" 2>"$run/fetch.err" ||
  delayed "the public repo could not be reached (fetch)" "fetch of the public main from $remote: $(tail -1 "$run/fetch.err")"
old=$(git -C "$run/work" rev-parse refs/public/main)
count=0
if [ "$old" = "$new" ]; then
  say "up to date: the public main is already ${new:0:8}"
elif git -C "$run/work" merge-base --is-ancestor "$old" "$new"; then
  count=$(git -C "$run/work" rev-list --count "$old..$new")
  git -C "$run/work" push -q "$remote" "main:refs/heads/main" 2>"$run/push.err" ||
    delayed "the push to the public repo failed" "push ${old:0:8}..${new:0:8}: $(tail -1 "$run/push.err")"
  say "pushed ${old:0:8}..${new:0:8} ($count commits) from main ${head:0:8}"
else
  fail "the public main is not an ancestor of the new one (not a fast-forward); nothing pushed" \
    "the public main ${old:0:8} is not an ancestor of ${new:0:8} (the scrub rules or the published history changed): not a fast-forward, nothing pushed"
fi
echo "$head pushed $(date +%s)" > "$dir/last"
status ok "$new" "$count"
ls -1d "$dir"/runs/*/ 2>/dev/null | sort -r | tail -n +3 | while read -r d; do rm -rf "$d"; done
say "done in $(( $(date +%s) - t0 )) s"
