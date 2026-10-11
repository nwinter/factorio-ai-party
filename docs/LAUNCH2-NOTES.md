# Launch round 2: fixes from the shake2 study (branch eng/launch2)

Implements `docs/studies/shake2.md` section 13: P1 items 1 to 5, P3 items 12, 13 and 15, and the Grok pre-approvals
from item 11. Items 13.6 (oil scouting and defence doctrine) and 14 (science targets) are skipped on purpose: agents
work out strategy themselves, so the playbook changes are tips about tools only.

## What changed

| Item | Change | Files |
|---|---|---|
| 1. Stop rule | "Stopping" no longer says "Then end your turn" after the summary: write the summary in the last three minutes, keep playing, end the turn once the `clock:` line says the deadline has passed; take time left from the `clock:` line. The nudge text drops "Write the final summary only in the last three minutes" and says "keep playing until the deadline has passed"; minutes left round up. The agy continue prompt matches. | `agent/PLAYBOOK.md`, `tools/supervise.sh`, `tools/launch-agent.sh` |
| 2. Denied commands | Playbook tip: a refusal covers that one command; rewrite it as `&&`-joined commands or a short `python3` script and carry on. Claude Code: `tools/permit.py`, a `PreToolUse` hook (matcher `Bash`) that answers `allow` when every simple command starts with a game program (`./fh`, `./shot`, `sleep`, `echo`, `date`, `cat`, `grep`, `python3`, ...), the only syntax is lists, pipes, `for`/`while`/`if`, variables are plain `$name`, and redirects go to `/dev/null` or relative workspace paths; anything else falls through to the normal rules, and commands still run in the sandbox. The supervisor logs a turn that ended on a refusal and adds the rewrite hint to that nudge. | `agent/PLAYBOOK.md`, `tools/permit.py`, `tools/test_permit.py`, `tools/clean-profile.py`, `tools/supervise.sh` |
| 3. Compaction settings | Muse: `agent/context.tsv` lists its window as 512000 (the effective window its fractions apply to), so 200K is soft 0.391 / hard 0.441 (shake2's 0.191 fired at 97,792). Haiku: the floor is cut instead of raising the point: `--tools Bash,Read,Edit,Write,Grep,Glob` drops the other tool definitions and the deferred-tool and agent listings, `--setting-sources project,local` drops user-level additions, the re-injected notes are capped at 7,000 characters, and the playbook asks agents to replace superseded lines. The pre-compaction warning now fires no earlier than halfway between the context right after the last compaction (the first `PostToolUse` of a window) and the point. Antigravity: the loop parses the deadline with seconds 0 (it took the current seconds, so shake2 started a turn at 22:46:12), starts no turn in the last 20 s, and rounds minutes left up. agy's own compaction stays the in-turn fallback (the loop can only act between turns). | `agent/context.tsv`, `tools/context.py`, `tools/launch-agent.sh`, `tools/test_context.py` |
| 4. Nudges | `supervise.sh` logs herdr's exit status and reply for every nudge; when `herdr agent prompt` fails (Muse Code: Herdr has no Muse agent kind) it types the text with `herdr pane send-text` + `enter`. Grok guard: in the last 3 minutes a Grok nudge is skipped (and logged) when `context.py grok-tokens` is within 25K of its compaction point. `POG_NUDGE_TEXT` replaces the text (smoke tests). The supervisor's own deadline parse had the same seconds bug as the agy loop. | `tools/supervise.sh`, `tools/context.py` |
| 5. Clean profiles | Claude Code: `--setting-sources project,local` keeps the route's user `settings.json` out (peon-ping and other hooks, plugins, effort overrides); login is stored outside settings, so auth is unchanged and no separate `CLAUDE_CONFIG_DIR` is needed. The workspace keeps `alwaysThinkingEnabled` and `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`, which shake1 and shake2 got from the user settings. Codex: workspace `[features]` set `skip_host_skill_discovery = true` and turn off `skill_search`, `plugins`, `apps`, `browser_use`, `in_app_browser`, `computer_use`, `multi_agent` and `multi_agent_v2` (names from `codex features list`; whether they remove the skills list and the multi-agent block is for the smoke test to show). Grok: `GROK_CLAUDE_RULES_ENABLED`, `GROK_CLAUDE_HOOKS_ENABLED`, `GROK_MANAGED_MCPS_ENABLED` off and `GROK_MEMORY=0`, on top of the existing skill and MCP switches. Muse: `-c hooks=...` with the owner's hooks minus `native-agent-tooling context muse` (the injected tooling rules); the `herdr-session` hooks stay because they let Herdr, and so the supervisor, see Muse's state. Muse now starts from a generated `.muse-run.sh` (the JSON option is easier to quote in a file). | `tools/launch-agent.sh`, `tools/clean-profile.py` |
| 11. Grok pre-approvals | `--allow 'Bash(./fh *)' 'Bash(./shot *)' 'Bash(python3 *)' 'Edit(./**)' 'Write(./**)'` (redirects into the workspace are checked as edits). Loops are not pre-approved for Grok: it runs without a sandbox, and a `Bash(for *)` rule would approve any loop body; the playbook tip covers it. | `tools/launch-agent.sh` |
| 12. Notes | Memory section: plain sentences with spaces between words, replace old lines instead of keeping superseded ones. | `agent/PLAYBOOK.md` |
| 13. Waits | One tip on which wait fits: queue plans (`plan save` / `plan run`) for repeated rounds, `wait_until` for one condition with a timeout of a few minutes, `./fh sleep` only when a teammate or an attack should wake you (and it does not wake on starving machines). Also: join an action and the `say` about it with `&&`. | `agent/PLAYBOOK.md` |
| 15. Profiles | The avatar example everyone copied is gone (the fields are listed instead), the voice example (`orion`, picked by three agents) points to the list in `describe.json`, and `./fh call profiles` is suggested to pick a colour, glyph and voice nobody has. | `agent/team.md` |

## Verification

Offline, all passing: `python3 tools/test_context.py` (Muse 0.391/0.441; no warning in the first half of the room
above the floor; the re-armed warning after a compaction) and `python3 tools/test_permit.py` (shake2's denied copper
haul, `for`/`while` loops, redirects, pipes and multi-line loops allowed; `rm`, absolute or parent redirects,
`$(...)`, backticks, heredocs, `${x:-y}`, `cd`, other programs and assignments left to the normal rules); `bash -n`
on the shell scripts; the deadline format checked with `date -j`.

Live: `tools/smoke-launch.sh` could not run from the engineer session. Its sandbox denies the herdr socket
("Operation not permitted" on `herdr tab create`) and ai-session's write to `~/.cache/ai-session` (Codex), so no
agent started. The smoke script now checks every item above when run outside the sandbox:

```sh
tools/smoke-launch.sh smoke-l2 5          # all five harnesses, 5 minutes on world live
```

Per agent it prints requests, failures, `hooks_seen` (the workspace `PostToolUse` hook ran: Claude, Muse and Grok
hooks still load with the new flags), `start_context` for Claude (the floor Haiku compacts above), the agent's
`tools:`, `rules:` and `blocked:` lines (clean profile; the prompt's `for a in status board; do ./fh call $a > /dev/null
...; done` and `python3 -c` show whether loops and python pass), its `nudge:` line and the supervisor log (the
supervisors run with a harmless test nudge, so delivery is checked for Codex, Claude, Grok and Muse).

What to look for, and what to do if it fails:
- Muse does not start (`requests=0`): `-c hooks=` was refused; drop `$clean_args` from the Muse line in
  `launch-agent.sh`.
- Codex does not start: one of the `[features]` keys was refused; remove it from `clean-profile.py`.
- `smoke-haiku` lists `blocked:` with the loop: the `PreToolUse` allow does not override dontAsk in this Claude Code
  version; the playbook tip remains the fallback.
- `start_context` for Haiku well above 30K: raise Haiku's `compact_at` in `agent/context.tsv` to about 90K.
- `smoke-muse` has no `nudge:` line and its supervisor log shows the `pane send-text` fallback failing: Muse nudges
  still do not arrive.

## Grok after smoke-l4 (round 4 addendum)

smoke-l4 (02:21, `runs/smoke-l4.out` in the main checkout) passed for Codex, Claude and Muse. Grok still listed the
owner's skills (ai-usage, aws-spot, find-skills, herdr, lifelog), Grok's built-in skills, `spawn_subagent` and
`workflow`, the owner's home rule ("Nick's shared agent tooling"), and its prompt policy refused
`for a in status board; do ./fh call $a ...; done`.

What changed (`tools/grok-home.py`, `tools/profile-flags.sh`, `tools/launch-agent.sh`):
- Each Grok workspace gets its own `GROK_HOME` (`DIR/.grok-home`, git-ignored): a `config.toml` with Claude and
  Cursor compatibility off, `~/.agents/skills` and each skill's real path ignored, Grok's built-in skills disabled by
  name, subagents and workflows off; `sessions` links to `~/.grok/sessions` (so `context.py grok-tokens` and the run
  analysis find the sessions where they were); `hooks/herdr.json` links to Herdr's own Grok integration, which reports
  the session to Herdr for `tools/supervise.sh`. The owner's home rule, `local-session-profile` hook and plugins
  folder are not there.
- Login without touching the owner's: Grok signs the run home in through `GROK_AUTH_PROVIDER_COMMAND`
  (`tools/grok-home.py token`), which reads `~/.grok/auth.json` read-only and prints the current access token and
  its time left. The run home stores that access token only, never the refresh token. Before a launch,
  `grok-home.py setup` checks that the owner's login lasts the run plus 15 minutes; if not, it runs the owner's own
  grok in its own home with a larger early-refresh window (`GROK_AUTH_EARLY_INVALIDATION_SECS`), so Grok refreshes
  that login the way it does in the owner's sessions.
- `GROK_SUBAGENTS=0` and `GROK_WORKFLOWS=0` on the launch line. The launch runs `~/.grok/bin/grok` directly: `grok`
  on PATH is the owner's herdr-session wrapper, which refuses an unknown `GROK_HOME`.

Probe (`tools/context-probe.sh --profile grok grok-4.7`, 02:37): the model reported `skills: none`, `mcp: none`, no
owner rule, no subagent or workflow tool; `grok inspect` lists only the workspace's AGENTS.md as instructions and only
Herdr's hook plus the repo's context hooks; the owner's login went from 4,745 to 21,598 s left during setup (refresh
path, which the 05:00 launch needs since that login expired at 03:56); `python3 -c` with subprocess ran.

What stays:
- Loops: Grok treats control flow (`for`, `while`, `if`) as one unit that always prompts, so under dontAsk it is
  denied whatever the allow rules say (docs `22-permissions-and-safety.md`, "Chained commands"), and a hook's
  "allow" approves nothing. Tried and dropped: `--allow 'Bash(for *)'` with a veto hook (the loop was still denied).
  `agent/harness-grok.md` (added to Grok's AGENTS.md) suggests a `python3` one-liner or a queue plan instead.
  Changing the permission mode to `auto` would let a classifier approve loops but also other commands, unsandboxed.
- Grok's own system prompt and its two generic "user rules" ("State points directly in affirmative language", "verify
  your work in the browser"): they come back in a fresh `GROK_HOME` with no rule files, so they are built in or set on
  the xAI account, not in the owner's files. `--system-prompt-override` did not remove them (or the skills list).
- Grok's product tools (web and X search, image and video generation, scheduler, monitor, plan mode): `--tools` and
  `--disallowed-tools` work only headless, not in the TUI the agents use.
- Two Claude Code plugins (claude-hud, code-simplifier) that Grok reads from `~/.claude/plugins`; `[plugins] disabled`
  did not apply. With subagents off, code-simplifier's agent cannot be called; claude-hud is a status line.
- The agent can read the access token in its own `.grok-home/auth.json`, as it could read `~/.grok/auth.json` before
  (Grok runs unsandboxed); the token expires within 6 hours and the run home holds no refresh token.
- To check: `tools/smoke-launch.sh smoke-l4g 3 grok` (needs Herdr, outside the engineer sandbox).

smoke-l4g (02:41, TUI in a Herdr pane) stalled: the prompt pass timed out and Grok made no request. The run home's
log has only the sign-in process; the TUI process logged nothing there or in `~/.grok/logs`, so it never got as far
as its auth setup. Main reverted 9872fd5 for shake4 (33b21be). What changed since (c57c56d, b940b9f re-applies the
run home on this branch):
- The pane command had grown to about 1,450 characters. Typed into a pane whose shell is not ready yet, input past
  the terminal's 1,024-byte line limit can be cut, and the command never runs (the likely cause; the same env and
  flags start fine under a pseudo-terminal). Grok now starts from `DIR/.grok-run.sh` (`grok_run_script` in
  `tools/profile-flags.sh`, as Muse and agy already do), which writes a start line to `DIR/grok-start.log`.
- A fresh home opens the TUI with a "Help improve Grok [Opt out] [Opt in]" prompt; the run home's config now
  answers it (`[privacy] privacy_banner_acked`, as in the owner's config).
- `tools/context-probe.sh --profile grok grok-4.7 - tui` runs `.grok-run.sh` in a pseudo-terminal
  (`tools/tui-capture.py`) and prints the screen. Result (02:53): start line written, welcome box without the privacy
  prompt, session started at once, answers `skills: none`, `mcp: none`, no owner rule, worked for 24 s.
- The smoke report prints `grok_started=` (the start line) and `grok_processes_logged=` (processes that logged in
  the run home: 1 means only the sign-in, 2 or more means the TUI ran).
- Still to prove under Herdr: `tools/smoke-launch.sh smoke-l4i 2 grok` on world live. If it stalls again with
  `grok_started` set, the cause is inside Grok under Herdr's terminal; if `grok_started=no`, the pane never ran the
  script.

## Compaction after shake4 (round 5)

Sources: Haiku's and Sonnet's Claude Code transcripts (`~/.claude/projects/-Users-...-runs-shake4-{haiku,sonnet}`),
the Codex rollouts for Astra and Luna (`~/.codex-account-b/sessions/2026/10/11/rollout-...T02-52-18-...`, `...T02-52-27-...`)
and Sol (`~/.codex/sessions/2026/10/11/rollout-...T02-52-22-...`), and `runs/shake4/*/notes.md` in the main checkout.

### Haiku's rising floor (P2 item 12)

What came back after each of Haiku's 8 compactions (characters, except the floor):

| # | Time | Before | Floor (tokens) | Summary | notes.md re-attached by Claude Code | notes.md in our hook | Kept messages |
|---|---|---|---|---|---|---|---|
| 1 | 03:07:17 | 79,880 | 24,450 | 7,108 | 2,301 | 2,311 | 4,908 |
| 2 | 03:22:00 | 79,935 | 25,141 | 6,233 | 3,644 | 3,643 | 2,142 |
| 3 | 03:32:09 | 81,852 | 25,897 | 6,743 | 4,162 | 4,155 | 4,856 |
| 4 | 04:01:06 | 80,193 | 27,054 | 8,329 | 4,778 | 4,761 | 4,173 |
| 5 | 04:12:41 | 81,088 | 28,595 | 7,342 | 5,474 | 5,452 | 6,792 |
| 6 | 04:20:44 | 80,825 | 29,003 | 8,673 | 6,132 | 6,108 | 5,340 |
| 7 | 04:34:24 | 81,155 | 31,124 | 9,551 | 6,949 | 6,917 | 6,857 |
| 8 | 04:42:20 | 80,284 | 30,194 | 7,630 | 8,259 | 7,261 (cut at 7,000) | 5,398 |

- The rest of the floor stays the same each time: system prompt and tools (7,382 tokens, cached), CLAUDE.md and
  AGENTS.md (22.4K characters), the start prompt (9.8K), the sandbox note (6.0K) and the small attachments.
- notes.md is what grew: from 2.3K to 8.3K characters, with a `## Log` of 39 lines at the end (the playbook asks for
  about 10). It came back twice after each compaction: once in the SessionStart hook output, and once because Claude
  Code re-attaches files the agent read recently. That is about 12K of the 15K extra characters by the seventh
  compaction; the summary (+0.5 to 2.4K) and the kept messages (+0 to 2K) vary up and down.
- Sonnet shows the same thing at a smaller size: 2 compactions, floor 22.6K then 26.8K, notes.md attached twice
  (4.5K each) the second time.
- Claude Code 2.1.296 has no switch for re-attaching recently read files (no such env var or setting in the binary),
  so the fix is on our side. After a compaction the hook now prints only the last 10 Log lines, with a line asking the
  agent to fold the older ones into the sections above and delete them. The pre-compaction warning also asks the
  agent to cut the Log to 10 lines, which shrinks the copy Claude Code re-attaches too (`tools/context.py`
  `trim_log`, test in `tools/test_context.py`). Haiku's final notes.md prints as 5.3K characters instead of 8.2K.
  Luna's (21.7K) prints as 16.4K and is then cut at 7,000 as before.
- compact_at stays at 80K for Haiku. Requests go up to 81.9K at that setting, and Claude Code's hard limit sits
  about 13K past compact_at, so 90K would bring requests close to the 100K price step. The fix above should hold
  the floor near 25K, which leaves about 55K of working room. Check the floor in the next run's `context.log`.

### Codex compaction stalls (P2 item 13)

| Agent | Compactions | Stall each (s) | Summary written (output tokens) | Context after |
|---|---|---|---|---|
| astra (gpt-6-astra) | 5 | 106, 127, 123, 99, 133 | 3,397 to 5,089 | 22.0 to 23.7K |
| sol (gpt-6.1-sol) | 5 | 93, 197, 132, 100, 56 | 2,019 to 5,471 | 20.7 to 24.2K |
| luna (gpt-6-luna) | 8 | 20, 19, 16, 42, 35, 17, 18, 17 | 1,861 to 2,371 | 19.8 to 20.4K |

- Every compaction is one remote call (`/responses` with the compaction item; no local fallback ran). Its input is
  the whole context, about 140K tokens, and 137 to 140K of it is cached each time. The stall is the time to write
  the summary: Astra writes 3.4 to 5.1K tokens at 32 to 42 tokens per second, Sol 2.0 to 5.5K at 20 to 41, and Luna
  1.9 to 2.4K at about 117. Astra's and Sol's summaries are about twice as long and their output is about 3 times
  slower; Sol's 197-second stall wrote 3.9K tokens at 20 per second.
- The 51 to 84K characters of `replacement_history` are four items. Three are the start of the session and the same
  every time: the developer message (1.9K), and AGENTS.md with the environment plus the start prompt (24.8K). The
  fourth is the encrypted summary (22 to 57K), whose size follows the output tokens. Nothing accumulates across
  compactions: the context after each one is 20 to 24K tokens, flat through the run.
- Nothing in Codex 0.162.1 shortens the summary. The server writes it with its own prompt and ignores
  `experimental_compact_prompt_file` (round 3). `remote_compaction_v2` is listed as "removed" in `codex features list`,
  and there is no setting for a compaction model.
- So total stall is the number of compactions times about 2 minutes (Astra, Sol) or 20 seconds (Luna), and the only
  setting that changes it is `compact_at`. No change made: raising Astra's and Sol's compact_at from 140K to 200K
  (window 272K) would give 178K of room instead of 118K, so about 3.3 compactions in two hours instead of 5, which
  saves about 3.5 minutes each. The cost is a longer average context per request (mostly cached input) and longer
  segments; Astra's and Sol's squashed words in shake4 came in whole segments starting at 56K, so longer segments
  could keep that going longer. That trade is the operator's call before a longer shift; the rows are
  `agent/context.tsv:11-13`.

## Still open

- Muse: no documented per-run switch for user skills (the skill-reminder agent and memory are off, round 4).
- Claude Code's "user hasn't heard from you" reminder (Opus 32 times in shake2) may come from the dropped user
  settings or be built in; check a long run's transcript.
- The Grok events log in `~/.grok/sessions` records an MCP server command line with an API token (shake2 study,
  section 11). The owner should rotate that token; nothing here changes it.
