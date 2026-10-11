# Context management per harness

Agents play for hours, so every harness compacts its context several times per run. This branch sets each
harness's compaction point per model, tells the summarizer what to keep, gives agents a structured `notes.md` to
fall back on, and puts `notes.md` back in front of the agent after a compaction. Nothing touches global CLI
config: settings are written into the run workspace or passed on the launch command line.

## What happens in a run

1. `tools/new-run.sh` writes `notes.md` as a skeleton (`## Now`, `## Claims and coordinates`, `## Team agreements`,
   `## Open board items`, `## Milestones`, `## Lessons`, `## Log`). `agent/PLAYBOOK.md` "Memory" tells the agent to
   keep it in that layout, under ~6 KB, with exact coordinates and ids, and to read it first after a compaction.
2. `AGENTS.md` (and its `CLAUDE.md` symlink) ends with `## Compact instructions`, copied from `agent/compact.md`:
   keep who/where/deadline, the current goal and exact next step, the last 5 actions with results, anything learned
   since `notes.md` was last written (claims, agreements, board items, chat promises), and new tool lessons; drop
   dumps and poll output; end with "read notes.md and deadline.txt, update notes.md, check status and chat".
3. `tools/launch-agent.sh` calls `tools/context.py setup KIND MODEL DIR`, which reads `agent/context.tsv` and writes
   the harness's workspace settings and hooks (below).
4. Hooks call `tools/context.py hook ...`. They log to `DIR/context.log` (one JSON line per pre-compact,
   post-compact, re-inject and nudge) and save each compaction summary the harness hands over to
   `DIR/compactions.md`, so a run's compactions can be studied afterwards: `tools/context.py report runs/RUN_ID`
   prints compactions, re-injects, nudges, agy fresh starts and the token count at each compaction per agent.
   (Codex agents write no `context.log`; their compactions show as `"type":"compacted"` in the rollout JSONL.)

## Per-harness settings

| Harness (models) | Compaction point | How it is set | After a compaction |
|---|---|---|---|
| Claude Code 2.1.296 (Opus, Sonnet, Haiku 5.5; 1M windows) | Opus 250K, Sonnet 200K, Haiku 80K | workspace `.claude/settings.json`: `autoCompactWindow` (+ `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` for Haiku) | `SessionStart` hook, matcher `compact`, prints `notes.md` into context |
| Codex 0.162.1 (Astra, Sol, Luna; 272K windows) | 150K | workspace `.codex/config.toml`: `model_context_window`, `model_auto_compact_token_limit` | AGENTS.md (re-injected by Codex) says to read `notes.md` |
| Grok Build 1.0.50 (grok-4.7, 256K) | 60% = 154K | `GROK_AUTO_COMPACT_THRESHOLD_PERCENT=60` on the launch command | `PostCompact` hook marks, next `PostToolUse` hook injects `notes.md`; `--rules` line |
| Antigravity 1.3.3 (gemini-3.8-flash-high) | 200K (own ~280K still applies within a turn) | none exists; `.agy-loop.sh` starts a fresh conversation past 200K | fresh conversation's prompt says to read `notes.md` |
| Muse Code 1.4.4 (muse-spark-1.3, 1M) | harness default (no setting) | none exists | `SessionStart` hook, matcher `compact`, prints `notes.md` |

Per-model values live in `agent/context.tsv` (model, kind, window, compact_at; `*` rows are per-kind fallbacks), so
`agent/team-nine.tsv` keeps its seven columns.

### Claude Code

- Threshold, from the 2.1.296 binary: compaction fires at `min(floor(W * pct / 100), W - 13000)`, where `W` is the
  auto-compact window (`autoCompactWindow` setting, `--autocompact`, or `CLAUDE_CODE_AUTO_COMPACT_WINDOW`; floor
  100000, capped at the model window) and `pct` is `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (it can only lower it). So
  `context.py` writes `autoCompactWindow = compact_at + 13000` (Opus 263000 -> 250000, Sonnet 213000 -> 200000),
  and for Haiku, whose target is below the 100K floor, `autoCompactWindow = 100000` plus `pct = 80` -> exactly
  80000 (without the env var it would be 87000).
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is on the binary's list of env vars that project settings may set (the `zc`
  set used by `nut()`), so the workspace `env` block works without touching user settings.
- Why these points: Haiku 5.5 is billed at a higher rate once the prompt passes 100K tokens, so 80K leaves room for
  a turn's growth. Opus and Sonnet have 1M windows and the default (`auto`) would let a session grow toward that;
  every turn re-sends the whole context (cache reads are cheaper, not free), and in our runs most of it is stale
  `observe`/`status`/wait output. 200-250K keeps several hours of play affordable while leaving plenty of working
  room; Opus gets more because it plans over longer histories.
- Defaults without our settings (model-config docs): models with a native 1M window (Haiku 5.5, Sonnet 5+, Opus
  4.7+) compact at about 967K. A Haiku 5.5 request "costs more per token when its prompt is longer than 100K
  tokens". Precedence: `CLAUDE_CODE_AUTO_COMPACT_WINDOW` > `--autocompact` > settings; within the binary's merge, a
  higher scope's top-level `autoCompactWindow` replaces lower scopes' per-model `/autocompact` values, so the
  workspace (project) setting wins over user settings. None of the Claude profiles' user settings set any of these.
- What a compaction keeps: `## Compact instructions` in CLAUDE.md is the documented way to steer auto-compaction.
  `PreCompact` stdout is not added to the summary prompt (docs), so it only logs. After a compaction Claude Code
  re-injects the project CLAUDE.md and re-reads up to five recently edited files (under 5,000 tokens each), so
  `notes.md` often comes back by itself; the `SessionStart` hook makes it certain (~1-2K tokens per compaction).
- Nudge: a `PostToolUse` hook reads the latest assistant `usage` in the transcript (input + cache creation + cache
  read + output) and, once per context window, when it is within `max(12000, compact_at / 10)` of the compaction
  point, adds "Context is at N tokens ... Update notes.md now" to the agent's context. The window re-arms at the
  next compaction (usage written before the compaction is ignored).
- Docs: https://code.claude.com/docs/en/context-window, https://code.claude.com/docs/en/model-config#set-the-auto-compact-window,
  https://code.claude.com/docs/en/settings-reference#autocompactwindow, https://code.claude.com/docs/en/hooks,
  https://code.claude.com/docs/en/hooks-guide#re-inject-context-after-compaction.

### Codex

- `model_auto_compact_token_limit` is absolute tokens and can only lower the default, which is 90% of the context
  window (244,800 for 272K; upstream `openai_models.rs`). `gpt-6.1-sol` (team-nine) is not in either profile's model
  catalog; without `model_context_window` Codex would have no window to compact against, so the workspace config
  always sets both.
- `ai-session spawn` has no way to pass `-c` flags, so the settings go in `DIR/.codex/config.toml`. Codex loads a
  project config layer only for trusted projects; run dirs are inside `/Users/owner/code/player-of-games`, which is
  trusted in both `~/.codex/config.toml` and `~/.codex-account-b/config.toml`. Codex drops some keys from project
  configs ("Ignored unsupported project-local config keys", provider, notify, profile and telemetry keys per the
  config reference); the three keys we write are not among them. If a probe shows that warning for them, set the
  values with `-c` instead (that needs launching Codex without ai-session).
- Codex compacts remotely on OpenAI's servers (our rollouts show `"type":"compacted"` with an encrypted
  `compaction` item), and that path ignores `compact_prompt` / `experimental_compact_prompt_file`. The workspace
  config still points `experimental_compact_prompt_file` at `agent/compact.md` for the local fallback.
- After a compaction Codex re-injects AGENTS.md (seen in a rollout), so the Memory section's "read notes.md first"
  survives. A `SessionStart` hook with matcher `^compact$` would print `notes.md` directly, but project hooks need
  persisted hook trust or `--dangerously-bypass-hook-trust`, which ai-session cannot pass; not used.
- Docs: https://developers.openai.com/codex/config-reference, https://learn.chatgpt.com/docs/config-file/config-reference,
  https://developers.openai.com/codex/config-basic, https://learn.chatgpt.com/docs/hooks.md.

### Grok Build

- `GROK_AUTO_COMPACT_THRESHOLD_PERCENT` (0-100) is read by the binary (`resolve/compaction.rs`) but is not in the
  docs; `[session] auto_compact_threshold_percent` is user-config only, and project `.grok/config.toml` cannot set
  it. The server's model catalog says 80% for grok-4.7 (256K window). The launcher puts the env var on the
  `herdr pane run` command line.
- `.grok/hooks/context.json` in the workspace (project hooks load because the repo folder is trusted in
  `~/.grok/trusted_folders.toml`): `PreCompact`/`PostCompact` log (Grok's payload includes `context_tokens`),
  `PostCompact --mark` sets a marker and the next `PostToolUse` returns `notes.md` as `additionalContext`. Grok has
  no `SessionStart` "compact" source and no compaction-prompt setting (`/compact [context]` is manual only).
- `--rules` adds "After any context compaction, read notes.md and deadline.txt before acting" to the system prompt.
- Docs: `~/.grok/docs/user-guide/10-hooks.md`, `13-memory.md`, `26-config-reference.md`; https://docs.x.ai/build/cli/reference.

### Antigravity (agy)

- No threshold setting, env var, flag, compaction hook or prompt override (CLI reference, hooks and rules docs;
  forum request for one is unanswered). In shake1 it compacted at ~280K (`input_tokens + cache_read_tokens` of the
  step before each `CHECKPOINT` in `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`).
- Our launcher already runs agy as a loop of print-mode turns. Before each continuation, `context.py agy-tokens DIR`
  reads the workspace's latest conversation (`cache/last_conversations.json`) and its last planner step's size; at
  200K or more the loop runs a fresh `agy -p` (no `-c`) whose prompt says the old conversation was closed and to
  read `notes.md` first, and logs `agy-fresh` to `context.log`. Within one long turn agy's own ~280K compaction
  still applies. AGENTS.md is auto-loaded by agy in every conversation.

### Muse Code

- No threshold setting: the docs only say it "compacts automatically when context fills", `muse model-profile show`
  lists no compaction knob, and the 1M window means the first compaction comes late. Left at the default.
- `.muse/hooks.json` in the workspace (loaded because the launcher passes `--trust-workspace`): `SessionStart`
  matcher `compact` prints `notes.md` (plain stdout is added for SessionStart), `PreCompact`/`PostCompact` log.

## Verification

Done in this session (offline):
- `python3 tools/test_context.py`: threshold math for 80K/200K/250K against the binary's formula; generated Claude,
  Codex (parsed with `tomllib`), Grok and Muse files; the hook flows with synthetic payloads (no nudge at 50K, one
  nudge at 70K for Haiku, none repeated, pre/post-compact logged, summary saved, SessionStart prints notes.md,
  nudge re-arms after a compaction and ignores usage from before it, Grok marker re-injects once and caps notes at
  9000 chars); `limit` fallbacks; `report`.
- The `.agy-loop.sh` heredoc was checked by reading its expansion (the session refused running a generated script).
- `tools/context.py agy-tokens` on shake1's gemini workspace returned 80923 (= 2224 + 78699 of its last step).
- The `new-run.sh` AGENTS.md generator, run on scratch output, ends with the Compact instructions section.
- `bash -n` on `launch-agent.sh`, `new-run.sh`, `context-probe.sh`.

Not done here, and why: this engineer session's sandbox denies network to the model APIs
(`deny network-outbound api.anthropic.com:443`), refused running `codex exec` and the repo's shell scripts, and
cannot reach the Herdr socket. So no CLI was run against a model and no compaction was observed live.

To verify live (outside the sandbox, from the main checkout so Codex trusts the workspace):

```sh
tools/context-probe.sh claude haiku           # production 80K; expect pre-compact tokens ~80000 in context.log
tools/context-probe.sh claude sonnet 90000    # lower point keeps the probe cheap; same mechanism as 200K
tools/context-probe.sh codex gpt-6-luna 60000 # expect "compacted"/context_compaction events in probe.jsonl
tools/context-probe.sh grok grok-4.7          # expect auto_compact_started with percentage ~60
tools/context-probe.sh agy gemini-3.8-flash-high   # prints agy-tokens of the probe conversation
tools/context-probe.sh muse muse-spark-1.3    # checks that the workspace hooks fire on a manual /compact
```

Each probe uses `runs/ctxtest/probe-KIND` (made by `tools/new-run.sh ctxtest n ...`; it never calls `./fh`, so world
n is untouched) and prints `context.log`.

## Open points

- Grok: whether the env var beats the server's 80% default and whether project hooks load from a run dir are
  unverified; the probe answers both.
- Claude: the binary says threshold compaction can be "not enforced" when an experiment defers to the API's
  prompt-too-long handling; the probe's `context.log` shows the real compaction point.
- Codex: hooks unused (trust); a `SessionStart ^compact$` hook would be the more direct re-read if ai-session ever
  passes `--dangerously-bypass-hook-trust` or the hooks get trusted once.
- Muse: compaction point not controllable; the supervisor could send `/compact` at a token budget read from the
  session log, if Muse context costs become a problem.
- The nudge exists only for Claude Code (the harness whose hook payload points at a transcript with usage).
