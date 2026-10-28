#!/usr/bin/env bash
# (mt277, private: part E) The tree a multi-team run's agents run from: this branch's HEAD as files (git archive, no
# .git, so no branch or commit of it is readable there), without what names the teams or this mode, plus the built
# host. Agents' workspaces live in its runs/ (kept across updates); the operator's files stay in this checkout.
#   tools/mt/launch-tree.sh [DIR]     make or update it (default worktrees/pog-mt-launch); prints DIR
#   tools/mt/launch-tree.sh --scan DIR   the words that would name the mode, with the files they are in (none: exit 0)
# Left out: tools/mt (the operator's tools), agent/mt (the teams files), the Python tests, the public repo export (its
# scan names the mode), tools/imac-copy.sh, the harness mod (only install and deploy read it: runtime.lua names the
# teams module) and the harness's mt tests. Codex, agy and Muse read any
# path on the Mac; this keeps incidental reads of the agents' own tree clean, not deliberate ones.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
WORDS='multi-?team|multiteam|mt27[0-9]|mt_map|start-mt|POG_MT|other teams'
scan() {
  grep -rIlE -i "$WORDS" "$1" --exclude-dir=runs --exclude-dir=node_modules --exclude-dir=.git 2>/dev/null | sed "s|^$1/||" || true
}
if [ "${1:-}" = --scan ]; then
  hits=$(scan "$2"); [ -z "$hits" ] && { echo "scan: clean"; exit 0; }
  echo "scan: $(echo "$hits" | wc -l | tr -d ' ') files: $(echo "$hits" | head -20 | tr '\n' ' ')"; exit 1
fi
tree=${1:-/Users/owner/code/personal/player-of-games/worktrees/pog-mt-launch}
case $tree in "$root"|"$root"/*) echo "the launch tree must be outside this checkout" >&2; exit 64 ;; esac
[ -e "$tree" ] && [ ! -f "$tree/.launch-tree" ] && { echo "$tree exists and is not a launch tree" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git -C "$root" archive HEAD | tar -x -C "$tmp"
rm -rf "$tmp/tools/mt" "$tmp/agent/mt" "$tmp"/tools/test_*.py "$tmp"/tools/stream/test_*.py "$tmp"/site/test_*.py \
  "$tmp/vendor/factorio-harness/mod" "$tmp"/vendor/factorio-harness/tests/mt27*.lua \
  "$tmp"/tools/public_export.py "$tmp"/tools/public_sync.py "$tmp"/tools/public-push.sh "$tmp"/tools/public-start.sh \
  "$tmp"/tools/imac-copy.sh
(cd "$root/vendor/factorio-harness" && npm run build >/dev/null)
mkdir -p "$tmp/vendor/factorio-harness/dist"
cp -R "$root/vendor/factorio-harness/dist/." "$tmp/vendor/factorio-harness/dist/"
git -C "$root" rev-parse --short HEAD > "$tmp/.launch-tree"
mkdir -p "$tree"
rsync -a --delete --exclude /runs/ "$tmp/" "$tree/"
echo "$tree"
