#!/bin/bash
# Claude Code SessionStart hook (tools/sleepcap/setup.py claude): Claude Code sources CLAUDE_ENV_FILE before every Bash
# command, after its shell snapshot, so the wait cap's sleep comes first on PATH even when the snapshot's login profile
# put /bin ahead of it. Nothing happens outside an agent launched with the cap (tools/sleepcap/run).
[ "${POG_SLEEP_CAP:-0}" = 1 ] && [ -n "${POG_SLEEPCAP_BIN:-}" ] && [ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
printf 'export PATH=%q:"$PATH"\n' "$POG_SLEEPCAP_BIN" >> "$CLAUDE_ENV_FILE"
exit 0
