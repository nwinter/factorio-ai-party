#!/usr/bin/env bash
# Bring the public repo (github.com/nwinter/factorio-ai-party) up to main, as a fast-forward:
#   tools/public-push.sh
# 1. Skips (one line, exit 0) while a merge is in progress in the main checkout (MERGE_HEAD: the gate merges there and
#    commits after its tests), while another run holds the lock, and when main is the commit the last run pushed or
#    failed on (a failure is said once, not every hour).
# 2. tools/public_sync.py into a fresh WORKDIR: the scrubbed history of main (same source, same hashes) and its scan,
#    with DIR/cache (blobs already rewritten and scanned under the same rules and secrets are not read again).
#    A scan finding (exit 1) or any other failure: a FAILED line, nothing pushed.
# 3. Fetches the public main; pushes main only when the public main is an ancestor of the new one (never forced). A
#    public main that is not an ancestor: a FAILED line, nothing pushed.
# Lines start with HH:MM:SS public-push:, and every failure with "public-push: FAILED". The newest summary is copied to
# DIR/public-sync-summary.md; the two newest run folders are kept.
# tools/start-team.sh runs it hourly with each run (log runs/RUN/public-push.log). Paths and commands (tests):
# POG_PUBLIC_SOURCE (the checkout whose main is published; default the main checkout), POG_PUBLIC_REMOTE,
# POG_PUBLIC_DIR (default ~/.cache/pog-public), POG_PUBLIC_SYNC (the sync command, split on spaces).
set -uo pipefail
# a test run (POG_TEST=1) never pushes to the public repo nor reads the main checkout: it must name both
if [ "${POG_TEST:-0}" = 1 ] && { [ -z "${POG_PUBLIC_REMOTE:-}" ] || [ -z "${POG_PUBLIC_SOURCE:-}" ]; }; then
  echo "POG_TEST=1: no public push without POG_PUBLIC_REMOTE and POG_PUBLIC_SOURCE"; exit 2
fi
src=${POG_PUBLIC_SOURCE:-$HOME/code/player-of-games}
remote=${POG_PUBLIC_REMOTE:-git@github.com:nwinter/factorio-ai-party.git}
dir=${POG_PUBLIC_DIR:-$HOME/.cache/pog-public}
read -ra sync <<<"${POG_PUBLIC_SYNC:-python3 $src/tools/public_sync.py}"
t0=$(date +%s)
ts() { date +%H:%M:%S; }
say() { echo "$(ts) public-push: $*"; }
# fail: said once for this main (a scan finding, not a fast-forward); retry: said and tried again at the next run
retry() { say "FAILED: $* (after $(( $(date +%s) - t0 )) s)"; exit 1; }
fail() { echo "$head failed $(date +%s)" > "$dir/last"; retry "$@"; }
head=""

if git -C "$src" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  say "skipped: a merge is in progress in $src (MERGE_HEAD); the next run syncs"; exit 0
fi
mkdir -p "$dir" || { say "FAILED: cannot make $dir"; exit 1; }
lock=$dir/lock
until mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  say "skipped: another run (pid ${holder:-?}) holds $lock"; exit 0
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

head=$(git -C "$src" rev-parse -q --verify refs/heads/main) || { say "FAILED: no main in $src"; exit 1; }
read -r last_head last_state last_t < "$dir/last" 2>/dev/null || true
if [ "${last_head:-}" = "$head" ]; then
  if [ "$last_state" = failed ]; then
    say "skipped: main ${head:0:8} is the commit that failed at $(date -r "${last_t:-0}" +%H:%M) (see $dir/public-sync-summary.md)"
  else
    say "up to date: main ${head:0:8} was pushed at $(date -r "${last_t:-0}" +%H:%M)"
  fi
  exit 0
fi

run=$dir/runs/$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$run" || retry "cannot make $run"
say "sync of main ${head:0:8} into $run/work"
(cd "$src" && "${sync[@]}" "$run/work" --source "$src" --ref main --cache "$dir/cache") > "$run/sync.log" 2>&1
rc=$?
[ -f "$run/public-sync-summary.md" ] && cp "$run/public-sync-summary.md" "$dir/public-sync-summary.md"
if [ $rc -ne 0 ]; then
  n=$(grep -c ':[0-9]*: ' "$run/sync.log" || true)
  fail "sync exit $rc, $n scan findings; nothing pushed (log $run/sync.log, summary $dir/public-sync-summary.md)"
fi
# the summary's title names the source commit; main may have moved since rev-parse
synced=$(sed -n '1s/^# Public history of main (\([0-9a-f]*\)).*/\1/p' "$run/public-sync-summary.md" 2>/dev/null)
[ -n "$synced" ] && [ "${head:0:${#synced}}" != "$synced" ] && head=$(git -C "$src" rev-parse "$synced")
new=$(git -C "$run/work" rev-parse main) || fail "no main in $run/work"
say "synced in $(( $(date +%s) - t0 )) s: public main would be ${new:0:8}"
git -C "$run/work" fetch -q "$remote" "+refs/heads/main:refs/public/main" 2>"$run/fetch.err" ||
  retry "fetch of the public main from $remote: $(tail -1 "$run/fetch.err")"
old=$(git -C "$run/work" rev-parse refs/public/main)
if [ "$old" = "$new" ]; then
  say "up to date: the public main is already ${new:0:8}"
elif git -C "$run/work" merge-base --is-ancestor "$old" "$new"; then
  count=$(git -C "$run/work" rev-list --count "$old..$new")
  git -C "$run/work" push -q "$remote" "main:refs/heads/main" 2>"$run/push.err" ||
    retry "push ${old:0:8}..${new:0:8}: $(tail -1 "$run/push.err")"
  say "pushed ${old:0:8}..${new:0:8} ($count commits) from main ${head:0:8}"
else
  fail "the public main ${old:0:8} is not an ancestor of ${new:0:8} (the scrub rules or the published history changed): not a fast-forward, nothing pushed"
fi
echo "$head pushed $(date +%s)" > "$dir/last"
ls -1d "$dir"/runs/*/ 2>/dev/null | sort -r | tail -n +3 | while read -r d; do rm -rf "$d"; done
say "done in $(( $(date +%s) - t0 )) s"
