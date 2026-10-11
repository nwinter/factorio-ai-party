# Engineer task: context management per harness (branch eng/context)

Agents run for hours, so their contexts fill up. Implement smart compaction per harness in our launcher, without
changing anyone's global CLI config (per-launch flags, env vars, or per-workspace settings only):
- Claude Code (Opus, Sonnet, Haiku): find the documented controls for the auto-compact threshold and for what a
  compaction keeps (compact instructions, PreCompact hooks). Haiku 5.5 is much cheaper below 100K tokens of context:
  make Haiku always compact well before 100K (target ~80K); pick sensible thresholds for Opus/Sonnet.
- Codex (Astra, Sol, Luna): `model_auto_compact_token_limit` and any compaction prompt settings via `-c` overrides.
- Grok Build, Antigravity (agy), Muse Code: find their equivalents (`--help`, docs URLs in
  ~/.profiles/claude/account-c/skills/ai-usage/references/native-agents.md).
- Make compaction smart: agents keep durable state in `notes.md` (agent/PLAYBOOK.md "Memory"); define a compact,
  structured notes layout (current goal, claims and coordinates, team agreements, open board items, lessons) and
  compaction instructions that keep those plus the last few actions; after a compaction the agent re-reads notes.md.
- Wire it into `tools/launch-agent.sh` / `tools/new-run.sh` (per-model settings in `agent/team-nine.tsv` or a
  sibling config), and document it in `docs/SETUP.md`.
Verify each harness: launch a short probe in a scratch run dir (no game needed: `POG_WS=x tools/new-run.sh ctxtest n
x 5`, then the CLI in headless/print mode with a long synthetic task, or force a compaction if the CLI allows) and show
the setting took effect. Use WebFetch/WebSearch for docs. Never start agents in worlds a, b, c, n. Commit to
eng/context with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; don't push or touch main. Write
`docs/CONTEXT-NOTES.md`. Stop by the deadline in deadline.txt.
