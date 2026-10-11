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

## Still open

- Grok has no per-launch switch for `~/.grok/rules`, skills from `~/.agents/skills` and bundled skills, or the MCP
  servers in its own `config.toml` (`~/.grok/docs`, files 07, 08, 10, 12); only a separate `GROK_HOME` would drop
  them, which moves auth, trust and session paths. Not done.
- Muse: no documented per-run switch for user skills or memory.
- Claude Code's "user hasn't heard from you" reminder (Opus 32 times in shake2) may come from the dropped user
  settings or be built in; check a long run's transcript.
- The Grok events log in `~/.grok/sessions` records an MCP server command line with an API token (shake2 study,
  section 11). The owner should rotate that token; nothing here changes it.
