#!/usr/bin/env bash
# A clean copy of main for jobs that must not read the main checkout's working tree (the gate merges branches there,
# uncommitted, all day): tools/clean-main.sh SRC WORKTREE [PATH...]
# WORKTREE becomes a detached worktree of SRC's repository at refs/heads/main's commit, with nothing else in it
# (made when missing; tracked files reset, untracked ones removed; ignored ones stay). Each PATH (relative, ignored or
# locally changed in SRC: run folders, caches, files the jobs write) becomes a symlink in WORKTREE to SRC/PATH, so
# what the job reads and writes there is the main checkout's (a missing SRC/PATH/ ending in / is made as a folder).
# Prints the commit; exit 1 with one line on stderr when WORKTREE exists and is not a worktree of SRC (left as it is)
# or the copy cannot be made or moved. Callers hold their own lock (tools/public-push.sh, tools/site-refresh.sh).
set -uo pipefail
src=${1:?SRC} wt=${2:?WORKTREE}
shift 2
err() { echo "clean-main: $*" >&2; exit 1; }
head=$(git -C "$src" rev-parse -q --verify refs/heads/main) || err "no main in $src"
common=$(git -C "$src" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || err "$src is not a git checkout"
if [ ! -e "$wt" ]; then
  git -C "$src" worktree prune 2>/dev/null
  out=$(git -C "$src" worktree add -q --detach "$wt" "$head" 2>&1) || err "git worktree add $wt: $(echo "$out" | tail -1)"
else
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -z "$top" ] || [ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$common" ] ||
     [ "$(cd "$top" && pwd -P)" != "$(cd "$wt" && pwd -P)" ]; then
    err "$wt is not a worktree of $src: left as it is"
  fi
fi
out=$({ git -C "$wt" checkout -q --detach --force "$head" && git -C "$wt" clean -qfd; } 2>&1) ||
  err "moving $wt to main ${head:0:8}: $(echo "$out" | tail -1)"
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] && [ -z "$(git -C "$wt" status --porcelain)" ] ||
  err "$wt is not clean at main ${head:0:8}"
srcabs=$(cd "$src" && pwd -P)
for p in "$@"; do
  rel=${p%/}
  case "$rel" in /*|*..*|"") err "not a relative path: $p" ;; esac
  [ "$rel" != "$p" ] && mkdir -p "$srcabs/$rel"
  link=$wt/$rel
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    # a tracked file the main checkout changed locally (site/live/status.json): the checkout above put main's back
    if [ -f "$link" ] && git -C "$wt" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then rm -f "$link"
    else err "$link is not a link (left as it is)"; fi
  fi
  mkdir -p "$(dirname "$link")"
  ln -sfn "$srcabs/$rel" "$link" || err "cannot link $link"
done
echo "$head"
