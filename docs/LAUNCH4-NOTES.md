# Launch round 4: clean profiles, launch readiness, late compaction (branch eng/launch2)

Implements `docs/studies/shake3.md` P2 items 8 (clean profiles, round 4), 9 (launch readiness) and 11 (Grok's
compaction at the deadline). Nothing in the owner's CLI folders changed: every switch is a workspace file, an env
variable or a flag on the launch line. The launch words live in `tools/profile-flags.sh`, which both
`tools/launch-agent.sh` and the new probe read.

## Live probe

`tools/context-probe.sh --profile KIND MODEL [ROUTE] [EXTRA CLI ARGS]` (outside the sandbox) prepares
`runs/ctxtest/profile-KIND` the way the launcher does, runs one short headless turn with the same env and flags, and
prints what reached the model (also in that directory's `profile.txt`). Results on 2026-10-11, 02:07 to 02:17:

| Harness | What shake3 had | Change | Probe evidence |
|---|---|---|---|
| Codex | `<skills_instructions>` (5.4K characters, the owner's `~/.agents/skills` and the route's `.system` skills), `<multi_agent_role>` (2,400) and its `<multi_agent_mode>` revocation | Workspace `.codex/config.toml`: `[skills] include_instructions = false`, `[skills.bundled] enabled = false`, and `[features.multi_agent_v2]` with `enabled = false`, `usage_hint_enabled = false`, `root_agent_usage_hint_text = ""`, `multi_agent_mode_hint_text = ""` | Developer blocks in the rollout, before: permissions, collaboration_mode, multi_agent_role, multi_agent_mode (skills already gone with `[skills]`). After: permissions, collaboration_mode only, on codex-b/gpt-6-luna and codex/gpt-6.1-sol. `multi_agent = false` and `multi_agent_v2 = false`, even as `-c` flags, left the role block; `enabled` and `usage_hint_enabled` alone did too; the empty hint texts remove it. |
| Claude Code | "The user hasn't heard from you in a while" (Opus 36, Sonnet 29); the route's email and git status with recent commits at start and after compaction | `CLAUDE_CODE_SILENT_TURN_REMINDER=0` and `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1` on the launch line and in the workspace settings `env`; `includeGitInstructions: false` | With the reminder forced on after 1 s and 1 turn (`CLAUDE_CODE_SILENT_TURN_REMINDER_SECONDS=1`, `_TURNS=1`), the clean run had 0 reminders in its transcript and the model reported `reminder: none`; the control (switch back on) had 5 and quoted the text. Same on routes claude and claude-b. Git status: headless runs carry none even in the control, so the smoke test checks it in the interactive transcript (`gitStatus=` in its report; shake3's Opus transcript held it in a `session_context` attachment). |
| Grok Build | `~/.grok/rules/agent-tooling.md`, 3 MCP servers failing at every start, the owner's global hooks | `GROK_CURSOR_{SKILLS,MCPS,RULES,HOOKS,AGENTS}_ENABLED=false` and `GROK_CLAUDE_AGENTS_ENABLED=false` added to the earlier switches | `grok inspect`: the 3 MCP servers (mcp-linear, Linear, cube from Cursor's `.mcp.json`) and cube-local now `[disabled]`; the model reported `mcp: none`; 0 MCP errors in its log. Still loaded (no switch): the home rule `agent-tooling.md` (~625 tokens; the model listed "Nick's shared agent tooling"), the 5 skills in `~/.agents/skills`, the 2 hooks in `~/.grok/hooks` (both `herdr-session`/herdr state recorders, nothing reaches the model) and 2 Claude plugins. |
| Muse Code | The owner's hooks from `~/.config/muse/settings.json`; 356 skill-reminder decisions | `-c 'hooks={}'`; `MUSE_EXPERIMENTAL_SKILL_REMINDER=0`, `MUSE_EXPERIMENTAL_MEMORY=0`, `MUSE_EXPERIMENTAL_MEMORY_REMINDER=0` | Hooks run: only the workspace's `.muse/hooks.json` (its `PostToolUse` set `hooks_seen`); none from the owner's settings. 0 skill-reminder decisions (2 without the switch); the memory tools (`read_memory`, `add_memory`, `edit_memory`) gone; reminder agents left: todo, goal, verify (Muse's own). |

Shake3's Muse already lost the tooling-context hook in round 3 (no "shared agent tooling" text in its session); the
hooks it still ran were the two `herdr-session record muse` calls, which only record the session for the owner's
resume tools.

Why the Grok leftovers stay: Grok always reads rules and hooks from `$GROK_HOME` (docs `12-project-rules.md`), the
`GROK_CONFIG` overlay accepts only `models`, `features`, `toolset` and a shell-environment filter, and a workspace
`.grok/config.toml` is read but its `[skills]` and `[plugins]` lists were not applied (`grok inspect`). A run-local
`GROK_HOME` would drop all of them, but it moves the login: the OIDC token in `~/.grok/auth.json` expires at 03:56
PDT and refreshes with a refresh token, so a copy or a replaced symlink could leave the owner's own Grok signed out.

## Launch readiness

`tools/launch-agent.sh` waited up to 40 s per pane for a trust prompt or a working screen; in shake3 five panes ran it
to the end (44 to 49 s each), so nine agents took 4.5 minutes. Now `tools/clear-prompts.sh SECONDS PANE DIR ...`
watches all panes together and marks a pane done when it answers its trust prompt, sees a working screen, or sees the
workspace journal grow (the agent made a request, so it is past any prompt; the launcher's own `describe` call is
counted out). `tools/start-team.sh` and `tools/smoke-launch.sh` start every pane with `POG_NO_WAIT=1` and then run one
90 s pass, logging each pane's outcome (`pane P: trust|working|journal|timeout` in `start.log`). A single
`launch-agent.sh` call still clears its own prompts (40 s). Estimate for nine agents: about 7 s of setup per pane
(Sol's launch in shake3) plus one shared wait, well under 2 minutes; the smoke test prints the measured times.

Offline check: two fake panes, one whose journal grew after 1.5 s (`journal`) and one that never did (`timeout`
at 4 s). Herdr is not reachable from the engineer sandbox, so the timing needs the smoke test.

## No compaction in the last 2 minutes

| Harness | Control | Done |
|---|---|---|
| Claude Code | A `PreCompact` hook that exits 2 blocks the compaction; Claude Code continues uncompacted | `tools/context.py hook pre-compact --skip-late 120 --at N` blocks an automatic compaction while the deadline is under 120 s away and the context is under compact_at + 5,000 (past that it compacts rather than hit the hard limit). Probe `tools/context-probe.sh --late claude haiku 40000` (deadline 10 minutes out, window widened to 15): two blocks at 35.3K, compaction allowed at 48.4K; Claude Code went on reading after each block. The transcript lags Claude Code's own count by the pending tool result (48.4K seen, 59.7K compacted, 8K files), hence the small margin. |
| Antigravity | Our loop decides fresh starts | `.agy-loop.sh` starts no fresh conversation in the last 120 s. agy's own compaction (near 280K) has no setting. |
| Grok Build | None: `PreCompact` cannot block (docs `10-hooks.md`), and the 60% threshold is read at launch | Not done. |
| Codex | Hooks include `PreCompact` with a blocked state, but Codex runs a hook only after its hash is trusted in the owner's config | Not done (it would mean writing trust entries into the owner's Codex config). |
| Muse Code | Compacts in the background past soft (shake3: no stall) | Not needed. |

Tests: `python3 tools/test_context.py` covers the block (auto blocked at 80.5K with 30 to 90 s left, manual allowed,
allowed past 85K, allowed with 10 minutes left).

## Still open

- Grok: the home rule, the owner's skills, hooks and 2 Claude plugins (above). The 2 secret-like strings in Grok's
  events log need rotating by the owner.
- Claude Code: the account email (`userEmail`) has no switch for an OAuth login (it comes from the account record;
  only `ANTHROPIC_UNIX_SOCKET` skips it).
- Keep route `codex` free of the owner's own sessions during a run (shake3: six `codex exec` sessions on it).
- Smoke test outside the sandbox for the launch timing and the interactive checks:
  `tools/smoke-launch.sh smoke-l4 3` on world live prints per agent `gitStatus=` and `silent_reminders=` (Claude),
  `skills_instructions=` and `multi_agent_role=` (Codex), `owner_hooks=` and `skill_reminders=` (Muse), and the
  launch time.
