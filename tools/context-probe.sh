#!/usr/bin/env bash
# Live check of a harness's compaction settings, no game needed: tools/context-probe.sh KIND MODEL [COMPACT_AT]
#   KIND: claude | codex | grok | agy | muse. COMPACT_AT overrides agent/context.tsv (lower = cheaper probe).
# Makes runs/ctxtest/probe-KIND with tools/new-run.sh (world n is only named in the unused ./fh wrapper; the probe
# never calls ./fh), applies tools/context.py setup, has the CLI read synthetic files headless until the context
# passes the compaction point, then prints context.log and the harness's own compaction markers.
# Run it from a checkout the CLIs trust (Codex loads the workspace's .codex/config.toml only in trusted projects).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
kind=$1 model=$2
[ -n "${3:-}" ] && export POG_CTX_AT=$3
ws=probe-$kind
rm -rf "$root/runs/ctxtest/$ws"
dir=$(POG_WS=$ws "$root/tools/new-run.sh" ctxtest n "$ws" 30)
env_words=$(python3 "$root/tools/context.py" setup "$kind" "$model" "$dir")
at=${POG_CTX_AT:-$(python3 "$root/tools/context.py" limit "$kind" "$model")}
# ~10K tokens per file; enough files to pass the compaction point once.
python3 - "$dir" "$at" <<'EOF'
import random, sys
d, at = sys.argv[1], int(sys.argv[2]) or 300000
words = "iron copper coal stone gear circuit belt inserter furnace drill pole boiler engine lab science".split()
for i in range(1, at // 10000 + 4):
    rnd = random.Random(i)
    open(f"{d}/big{i:02d}.txt", "w").write("\n".join(" ".join(rnd.choice(words) for _ in range(12)) for _ in range(800)))
EOF
n=$(ls "$dir"/big*.txt | wc -l | tr -d ' ')
task="Context probe. Read big01.txt through big$(printf %02d "$n").txt in order, one file per tool call, reading each whole file. After each file reply with one line: the file name and how many times the word 'lab' appears on its first line. Do not skip files and do not use shell loops. When done, say DONE."
cd "$dir"
echo "probe: $kind $model compact_at=$at files=$n env=[$env_words] dir=$dir"
case $kind in
  claude)
    claude -p "$task" --model "$model" --permission-mode dontAsk --allowedTools Read --output-format stream-json --verbose \
      > probe.jsonl 2> probe.err || true
    grep -o '"subtype":"compact_boundary"[^}]*}' probe.jsonl | head -3 || true
    ;;
  codex)
    codex exec --json --skip-git-repo-check -C "$dir" -m "$model" -c 'model_reasoning_effort="low"' --sandbox read-only \
      "$task" > probe.jsonl 2> probe.err || true
    grep -o '"type":"[a-z_]*compact[a-z_]*"' probe.jsonl | sort | uniq -c || true
    ;;
  grok)
    env $env_words grok -p "$task" -m "$model" --permission-mode dontAsk --allow Read --output-format streaming-json \
      > probe.jsonl 2> probe.err || true
    grep -o '"auto_compact_[a-z]*"[^}]*' probe.jsonl | head -3 || true
    ;;
  agy)
    # agy cannot be told when to compact; the launcher's loop starts a fresh conversation past compact_at. This
    # checks that the loop can read the conversation's size.
    agy -p "$task" --model "$model" --sandbox --dangerously-skip-permissions > probe.out 2> probe.err || true
    echo "agy-tokens: $(python3 "$root/tools/context.py" agy-tokens "$dir") (loop starts a fresh conversation at $at)"
    ;;
  muse)
    # No threshold setting; this checks that the workspace hooks load and fire on a manual /compact.
    muse exec --workspace "$dir" --trust-workspace --approval-mode never --json "$task" > probe.jsonl 2> probe.err || true
    sid=$(grep -o '"session_id":"[^"]*"' probe.jsonl | head -1 | cut -d'"' -f4)
    [ -n "$sid" ] && muse exec --workspace "$dir" --trust-workspace --session-id "$sid" --json "/compact" >> probe.jsonl 2>> probe.err || true
    ;;
esac
echo "--- context.log"; cat context.log 2>/dev/null || echo "(no hook events)"
echo "--- stderr (tail)"; tail -5 probe.err 2>/dev/null || true
