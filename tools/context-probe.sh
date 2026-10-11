#!/usr/bin/env bash
# Live check of a harness's compaction settings, no game needed:
#   tools/context-probe.sh [-C CHECKOUT] KIND MODEL [COMPACT_AT]
#   KIND: claude | codex | grok | agy | muse. COMPACT_AT overrides agent/context.tsv (lower = cheaper probe).
# Makes CHECKOUT/runs/ctxtest/probe-KIND (default: this checkout) with tools/new-run.sh (world n is only named in the
# unused ./fh wrapper; the probe never calls ./fh), applies tools/context.py setup, has the CLI read synthetic files
# headless until the context passes the compaction point, then prints context.log and the harness's compaction markers.
# The run dir must be in a folder the CLIs trust: Grok loads workspace hooks only in trusted folders (Codex trusts a
# git worktree through its main repository). From an untrusted worktree use -C /Users/owner/code/player-of-games.
#
# Clean-profile check: tools/context-probe.sh [-C CHECKOUT] --profile KIND MODEL [ROUTE] [EXTRA CLI ARGS...]
#   Prepares runs/ctxtest/profile-KIND as tools/launch-agent.sh does (settings, tools/clean-profile.py and the words in
#   tools/profile-flags.sh), runs one short headless turn and prints what the agent was given (profile.txt).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
base=$root
[ "${1:-}" = -C ] && { base=$2; shift 2; }
if [ "${1:-}" = --profile ]; then
  shift
  exec bash "$root/tools/profile-probe.sh" "$base" "$@"
fi
kind=$1 model=$2
[ -n "${3:-}" ] && export POG_CTX_AT=$3
ws=probe-$kind
rm -rf "$base/runs/ctxtest/$ws"
dir=$(POG_WS=$ws "$base/tools/new-run.sh" ctxtest n "$ws" 30)
env_words=$(python3 "$root/tools/context.py" setup "$kind" "$model" "$dir")
at=${POG_CTX_AT:-$(python3 "$root/tools/context.py" limit "$kind" "$model")}
# ~8K tokens per file (Claude counted ~38 tokens per 12-word line); enough files to pass the compaction point once.
# Keep files well under compact_at minus the starting context, or Claude Code stops with "Autocompact is thrashing".
python3 - "$dir" "$at" <<'EOF'
import random, sys
d, at = sys.argv[1], int(sys.argv[2]) or 300000
words = "iron copper coal stone gear circuit belt inserter furnace drill pole boiler engine lab science".split()
for i in range(1, at // 8000 + 4):
    rnd = random.Random(i)
    open(f"{d}/big{i:02d}.txt", "w").write("\n".join(" ".join(rnd.choice(words) for _ in range(12)) for _ in range(210)))
EOF
n=$(ls "$dir"/big*.txt | wc -l | tr -d ' ')
task="Context probe. Read big01.txt through big$(printf %02d "$n").txt in order, one file per tool call, reading each whole file. Do not skip files, do not use shell loops, and write no message until every file is read (a message ends your turn). Then reply with one line per file: the file name and how many times the word 'lab' appears on its first line, then DONE."
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
    # Hooks come from the git root's .grok/hooks/context.json. GROK_FOLDER_TRUST=0 (this process only) lets the probe
    # load them from a checkout that is not in ~/.grok/trusted_folders.toml, such as an engineer's worktree.
    env $env_words GROK_FOLDER_TRUST=0 RUST_LOG=debug GROK_LOG_FILE="$dir/grok.log" grok -p "$task" -m "$model" --permission-mode dontAsk --allow Read --output-format streaming-json \
      > probe.jsonl 2> probe.err || true
    grep -o '"auto_compact_[a-z]*"[^}]*' probe.jsonl | head -3 || true
    ;;
  agy)
    # agy cannot be told when to compact; the launcher's loop starts a fresh conversation past compact_at. This
    # checks that the loop can read the conversation's size.
    agy -p "$task" --model "$model" --sandbox --dangerously-skip-permissions > probe.out 2> probe.err || true
    conv() { python3 -c 'import json,os,sys; print(json.load(open(os.path.expanduser("~/.gemini/antigravity-cli/cache/last_conversations.json"))).get(os.path.realpath(sys.argv[1]),"-"))' "$dir"; }
    tokens=$(python3 "$root/tools/context.py" agy-tokens "$dir")
    echo "agy-tokens: $tokens (loop starts a fresh conversation at $at); conversation $(conv)"
    if [ "$tokens" -ge "$at" ]; then   # the .agy-loop.sh branch
      echo "{\"time\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"event\": \"agy-fresh\", \"tokens\": $tokens}" >> context.log
      agy -p "This is a fresh conversation. Reply with the first line of notes.md and nothing else." --model "$model" \
        --sandbox --dangerously-skip-permissions >> probe.out 2>> probe.err || true
      echo "after fresh start: agy-tokens $(python3 "$root/tools/context.py" agy-tokens "$dir"); conversation $(conv)"
      tail -3 probe.out
    fi
    ;;
  muse)
    # $env_words are -c context_compaction.* options; --trust-workspace loads the workspace's .muse/hooks.json.
    muse exec $env_words --model "$model" --effort low --workspace "$dir" --trust-workspace --approval-mode never \
      --json "$task" > probe.jsonl 2> probe.err || true
    grep -o '"payload_type":"context\.compaction[a-z_.]*"[^}]*}' probe.jsonl | cut -c1-300 | head -6 || true
    ;;
esac
echo "--- context.log"; cat context.log 2>/dev/null || echo "(no hook events)"
echo "--- stderr (tail)"; tail -5 probe.err 2>/dev/null || true
