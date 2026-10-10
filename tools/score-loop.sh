#!/usr/bin/env bash
# Append a score snapshot per world every N seconds: tools/score-loop.sh RUN_DIR SECONDS WORLD...
dir=$1 every=$2; shift 2
while true; do
  for w in "$@"; do
    s=$(python3 "$(dirname "$0")/pog.py" --world "$w" score 2>/dev/null) && [ "${s#\{}" != "$s" ] && printf '{"t":"%s","world":"%s","score":%s}\n' "$(date +%FT%T)" "$w" "$s" >> "$dir/scores.jsonl"
  done
  sleep "$every"
done
