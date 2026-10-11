# Context management per harness

Agents play for hours, so every harness compacts its context several times per run. This branch sets each
harness's compaction point per model, tells the summarizer what to keep, gives agents a structured `notes.md` to
fall back on, and puts `notes.md` back in front of the agent after a compaction. Nothing touches global CLI
config: settings are written into the run workspace, passed on the launch command line, or (Grok only) kept in the
repo's own `.grok/hooks/`.

## What happens in a run

1. `tools/new-run.sh` writes `notes.md` as a skeleton (`## Now`, `## Claims and coordinates`, `## Team agreements`,
   `## Open board items`, `## Milestones`, `## Lessons`, `## Log`). `agent/PLAYBOOK.md` "Memory" tells the agent to
   keep it in that layout, under ~6 KB, with exact coordinates and ids, and to read it first after a compaction.
2. `AGENTS.md` (and its `CLAUDE.md` symlink) ends with `## Compact instructions`, copied from `agent/compact.md`:
   keep who/where/deadline, the current goal and exact next step, the last 5 actions with results, anything learned
   since `notes.md` was last written (claims, agreements, board items, chat promises), and new tool lessons; drop
   dumps and poll output; end with "read notes.md and deadline.txt, update notes.md, check status and chat".
3. `tools/launch-agent.sh` calls `tools/context.py setup KIND MODEL DIR`, which reads `agent/context.tsv`, writes
   the harness's workspace settings and hooks (below) and a `.context-hooks` marker, and prints extra launch words
   (env assignments for Grok, `-c` options for Muse).
4. Hooks call `tools/context.py hook ...` and do nothing in a directory without the marker. They log to
   `DIR/context.log` (one JSON line per pre-compact, post-compact, re-inject and nudge) and save each compaction
   summary the harness hands over to `DIR/compactions.md`, so a run's compactions can be studied afterwards:
   `tools/context.py report runs/RUN_ID` prints compactions, re-injects, nudges, agy fresh starts and the token count
   at each compaction per agent. (Codex agents write no `context.log`; their compactions show as
   `"type":"compacted"` in the rollout JSONL.)
5. No compaction in the last 2 minutes (shake3: Grok's began 39 s before its deadline and ended its play). Claude
   Code's `PreCompact` hook runs `pre-compact --skip-late 120 --at N` and exits 2, which blocks an automatic
   compaction while the deadline is under 120 s away and the context under compact_at + 5,000 (`skip-late` in
   `context.log`; probe `tools/context-probe.sh --late claude haiku 40000`). The agy loop starts no fresh conversation
   then. Grok's `PreCompact` cannot block, Codex hooks need trust in the owner's config, and Muse compacts in the
   background (`docs/LAUNCH4-NOTES.md`).

## Per-harness settings

| Harness (models) | Compaction point | How it is set | After a compaction | Live probe |
|---|---|---|---|---|
| Claude Code 2.1.296 (Opus, Sonnet, Haiku 5.5; 1M windows) | Opus 250K, Sonnet 200K, Haiku 80K | workspace `.claude/settings.json`: `autoCompactWindow` = compact_at + 33000 | `SessionStart` hook, matcher `compact`, prints `notes.md` | Haiku compacted at 79-83K |
| Codex 0.162.1 (Astra, Sol, Luna; 272K windows) | 140K | workspace `.codex/config.toml`: `model_context_window`, `model_auto_compact_token_limit` | AGENTS.md (re-injected by Codex) says to read `notes.md` | compacted at the 25K test limit |
| Grok Build 1.0.50 (grok-4.7, 256K) | 60% = 154K | `GROK_AUTO_COMPACT_THRESHOLD_PERCENT=60` on the launch command | repo `.grok/hooks/context.json`: `PostCompact` marks, next `PostToolUse` injects `notes.md`; `--rules` line | compacted at the 15% test setting; hooks fired |
| Antigravity 1.3.3 (gemini-3.8-flash-high) | 200K (own ~280K still applies within a turn) | none exists; `.agy-loop.sh` starts a fresh conversation past 200K | fresh conversation's prompt says to read `notes.md` | fresh start at 55.7K over a 30K test limit |
| Muse Code 1.4.4 (muse-spark-1.3, 1M; fractions apply to a 512K effective window) | 200K (soft 0.391, hard 0.441; shake2's 0.191 fired at 97,792) | `muse -c context_compaction.soft_threshold=... -c context_compaction.hard_threshold=...` | workspace `.muse/hooks.json`: `PostCompact` marks, next `PostToolUse` injects `notes.md` | compacted (soft and hard); hooks fired |

Per-model values live in `agent/context.tsv` (model, kind, window, compact_at; `*` rows are per-kind fallbacks), so
`agent/team-nine.tsv` keeps its seven columns.

### Claude Code

- Threshold (2.1.296): compaction fires at `min(floor(E * pct / 100), E - 13000)` with `E = W - 20000`, where `W` is
  the auto-compact window (`autoCompactWindow` setting, `--autocompact`, or `CLAUDE_CODE_AUTO_COMPACT_WINDOW`; floor
  100000, capped at the model window), 20000 is the room kept for the summary, and `pct` is
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (it can only lower the point). The first version of this branch left out the
  20000 and the live probe caught it: `W=100000, pct=80` compacted at 64.7-66.1K (= 0.8 x 80000), `pct=60` at
  46.6-52.9K. `context.py` now writes `autoCompactWindow = compact_at + 33000` (Haiku 113000, Sonnet 233000, Opus
  283000) and uses `pct` only for points below 67000 (probes).
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is on the binary's list of env vars that project settings may set, so the
  workspace `env` block works without touching user settings.
- Why these points: Haiku 5.5 is billed at a higher rate once the prompt passes 100K tokens, so 80K leaves room for
  a turn's growth. Opus and Sonnet have 1M windows and the default would let a session grow toward that; every turn
  re-sends the whole context (cache reads are cheaper, not free), and in our runs most of it is stale
  `observe`/`status`/wait output. 200-250K keeps several hours of play affordable while leaving plenty of working
  room; Opus gets more because it plans over longer histories.
- Defaults without our settings (model-config docs): models with a native 1M window compact at about 967K.
  Precedence: `CLAUDE_CODE_AUTO_COMPACT_WINDOW` > `--autocompact` > settings; a higher scope's top-level
  `autoCompactWindow` replaces lower scopes' per-model values, so the workspace setting wins over user settings.
  None of the Claude profiles' user settings set any of these.
- Thrashing guard: when the context refills to the threshold within 3 turns of a compaction, 3 times in a row,
  Claude Code ends the turn with "Autocompact is thrashing". The probe hit it twice: with a 60K point, a 34K
  starting context (this machine's personal skills, MCP tools and hooks) and 8-30K-token tool results, each
  compaction left 41-42K and the next file crossed the point again. At 80K with 8K results it did not trigger. Game
  tool output is 1-3K per call, but keep compact_at at least ~40K above the post-compaction size (starting context
  plus a ~13K summary).
- What a compaction keeps: `## Compact instructions` in CLAUDE.md steers auto-compaction (documented). `PreCompact`
  stdout is not added to the summary prompt, so it only logs. After a compaction Claude Code re-injects the project
  CLAUDE.md and re-reads up to five recently edited files; the `SessionStart` hook prints `notes.md` as well
  (~1-2K tokens per compaction). In the probe the summary was 3.8-7.3K characters and Haiku's first action after
  the first compaction was reading `notes.md`.
- Nudge: a `PostToolUse` hook reads the latest assistant `usage` in the transcript (input + cache creation + cache
  read + output) and, once per context window, when it is within `max(20000, compact_at / 5)` of the compaction
  point, adds "Context is at N tokens ... Update notes.md now" to the agent's context; it re-arms at the next
  compaction. The probe ran with a 12K margin and the nudge landed in the same step as the compaction (72.9K, then
  compacted at 83.5K), too late to act on, so the margin was widened.
- Docs: https://code.claude.com/docs/en/context-window, https://code.claude.com/docs/en/model-config#set-the-auto-compact-window,
  https://code.claude.com/docs/en/settings-reference#autocompactwindow, https://code.claude.com/docs/en/hooks,
  https://code.claude.com/docs/en/hooks-guide#re-inject-context-after-compaction.

### Codex

- Compaction point 140K for all three models. The shake1 transcript study (`docs/studies/shake1-transcripts.md`
  section 5, item 4) found Codex step latency growing with context (Astra 7 to 29 s, Sol 5 to 38 s median) and asks
  for compaction at about 120-150K.
- `model_auto_compact_token_limit` is absolute tokens and can only lower the default, which is 90% of the context
  window (244,800 for 272K). `gpt-6.1-sol` is not in either profile's model catalog; without `model_context_window`
  Codex would have no window to compact against, so the workspace config always sets both.
- `ai-session spawn` has no way to pass `-c` flags, so the settings go in `DIR/.codex/config.toml`. Codex loads a
  project config layer only for trusted projects; run dirs are inside `/Users/owner/code/player-of-games`, which is
  trusted in both `~/.codex/config.toml` and `~/.codex-account-b/config.toml`. The probe also ran from the
  engineer worktree `pog-context` (not itself in the trust list) and the layer loaded there too, so Codex resolves
  a worktree's trust through its main repository. No "ignored config key" warning named our keys.
- Codex compacts remotely on OpenAI's servers (rollouts show `"type":"compacted"` with an encrypted `compaction`
  item), and that path ignores `compact_prompt` / `experimental_compact_prompt_file`. The workspace config still
  points `experimental_compact_prompt_file` at `agent/compact.md` for the local fallback.
- After a compaction Codex re-injects AGENTS.md, so the Memory section's "read notes.md first" survives. Project
  hooks need persisted hook trust or `--dangerously-bypass-hook-trust`, which ai-session cannot pass; not used.
- Docs: https://developers.openai.com/codex/config-reference, https://learn.chatgpt.com/docs/config-file/config-reference,
  https://developers.openai.com/codex/config-basic, https://learn.chatgpt.com/docs/hooks.md.

### Grok Build

- `GROK_AUTO_COMPACT_THRESHOLD_PERCENT` (0-100) is read by the binary but is not in the docs;
  `[session] auto_compact_threshold_percent` is user-config only. The server's model catalog says 80% for grok-4.7.
  The probe confirms the env var overrides it: with 15 the stream showed `auto_compact_started` with
  `"percentage":15`. The launcher puts the env var on the `herdr pane run` command line.
- Hooks: Grok loads project hooks only from the git root (debug log: `loaded from project source
  .../player-of-games/.grok/hooks`), never from the session's working directory, so a hook file in the run dir is
  ignored. The hooks are therefore a committed repo file, `.grok/hooks/context.json`, calling
  `$GROK_WORKSPACE_ROOT/tools/context.py`; they need the repo folder trusted (it is, in
  `~/.grok/trusted_folders.toml`) and act only in run dirs with the `.context-hooks` marker, so Grok sessions
  elsewhere in the repo are unaffected. `PreCompact`/`PostCompact` log; `PostCompact --mark` sets a marker and the
  next `PostToolUse` returns `notes.md` as `additionalContext` (Grok has no `SessionStart` "compact" source). Grok's
  compaction payload carries no transcript, so `context.log` has no token count for Grok.
- `--rules` adds "After any context compaction, read notes.md and deadline.txt before acting" to the system prompt.
- Docs: `~/.grok/docs/user-guide/10-hooks.md` (locations, trust, `GROK_WORKSPACE_ROOT`), `13-memory.md`,
  `26-config-reference.md`; https://docs.x.ai/build/cli/reference.

### Antigravity (agy)

- No threshold setting, env var, flag, compaction hook or prompt override (CLI reference, hooks and rules docs).
  In shake1 it compacted at ~280K (`input_tokens + cache_read_tokens` of the step before each `CHECKPOINT` in
  `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`).
- Our launcher runs agy as a loop of print-mode turns. Before each continuation, `context.py agy-tokens DIR` reads
  the workspace's latest conversation (`cache/last_conversations.json`) and its last planner step's size; at 200K
  or more the loop runs a fresh `agy -p` (no `-c`) whose prompt says the old conversation was closed and to read
  `notes.md` first, and logs `agy-fresh` to `context.log`. Within one long turn agy's own ~280K compaction still
  applies. AGENTS.md is auto-loaded by agy in every conversation.

### Muse Code

- Threshold: `muse exec --help` lists `--context-compaction-soft-threshold` / `--context-compaction-hard-threshold`
  (fractions of the window), and the binary's settings keys are `context_compaction.soft_threshold`,
  `hard_threshold`, `strategy` and `provider_context_limit_tokens`. The interactive `muse` the launcher runs has no
  such flags but takes any setting per launch with `-c KEY=VALUE`, so `context.py setup muse` prints
  `-c context_compaction.soft_threshold=0.191 -c context_compaction.hard_threshold=0.241` (200K and 250K of 1M).
  Past the soft threshold Muse compacts in the background; at the hard one it blocks the turn. (An earlier note here
  said Muse had no setting; `muse model-profile show` does not list it.)
- Window (shake2): Muse applies the fractions to a 512K effective window, not 1,048,576: its log shows
  `soft_threshold_tokens: 97792` for soft 0.191 (0.191 x 512,000). `agent/context.tsv` now lists Muse's window as
  512000, so 200K gives soft 0.391 and hard 0.441.
- Hooks: `.muse/hooks.json` in the workspace, loaded because the launcher passes `--trust-workspace`. Muse never
  fired `SessionStart` with matcher `compact` after its own compactions in the probe, so `PostCompact --mark` and
  `PostToolUse` re-inject `notes.md` as for Grok (`SessionStart` stays for a manual `/compact`).
- Converging: Muse gives up ("context compaction is not converging") when two compactions in a row fail to get
  below the soft threshold, and a point just above the starting context makes the agent lose its place every few
  steps (below). 200K keeps Muse far from both.

## Verification

Offline: `python3 tools/test_context.py` covers the threshold formula (40K-250K), the generated Claude, Codex
(`tomllib`), Grok and Muse settings, the hook flows with synthetic payloads (nudge window, one nudge per context
window, pre/post-compact logging, summaries, SessionStart re-inject, re-arming, marker re-inject capped at 9000
chars, no action without the marker), `limit` fallbacks and `report`.

Live probes, 2026-10-10, `tools/context-probe.sh` with a low compaction point (each reads synthetic ~8K-token files
one per tool call in a scratch run dir `runs/ctxtest/probe-KIND`; world n is only named in the unused `./fh`
wrapper; no game was touched):

| Probe | Result |
|---|---|
| `claude haiku` (80K, fixed formula) | `autoCompactWindow` 113000. Two auto compactions, `pre_tokens` 83,483 and 79,279 (last assistant usage before them 72.9K and 75.0K); summaries 5.5K and 6.5K chars; post-compaction 13K + starting context. All 13 files read, $0.044. `context.log`: nudge, pre-compact, session-compact (notes.md printed), post-compact, twice. |
| `claude haiku` (80K, old formula `W=100000, pct=80`) | three compactions at 64.8-66.1K: the 20K summary reserve, now in the formula |
| `claude haiku 60000` | compactions at 46.6-52.9K (old formula), then "Autocompact is thrashing" with 34K starting context and 41-42K after each compaction; Haiku read `notes.md` right after its first compaction |
| `codex gpt-6-luna 25000` | rollout `rollout-2026-10-10T20-57-30-01a1291b-cbc9-...`: `"type":"compacted"` three times (03:57:39, :46, :52 UTC) when input reached 21.8-22.3K plus the next result; back to 19.2K each time; window 258,400 |
| `codex gpt-6-luna 60000` | no compaction: Codex truncates each `cat` to ~1.6K tokens, so ten files reached only 34.6K |
| `grok grok-4.7 40000` | env `GROK_AUTO_COMPACT_THRESHOLD_PERCENT=15`; `auto_compact_started` `"percentage":15`, then `auto_compact_completed`. Run-dir hooks: not loaded (git-root rule). Repo hooks: pre-compact, post-compact, and the next `PostToolUse` returned `additional_context=true` (484 bytes, the notes block) |
| `agy gemini-3.8-flash-high 30000` | `agy-tokens` 55,745 >= 30,000, so the loop branch logged `agy-fresh` and started conversation `539bc0d5...` (was `94d31caa...`), which began at 14,970 tokens and answered with the first line of `notes.md` |
| `muse muse-spark-1.3 40000` | `-c` soft 0.038 / hard 0.088 accepted; hooks logged soft and hard compactions; run failed "context compaction is not converging" |
| `muse muse-spark-1.3 80000` | soft 0.076: 50 compactions in 8 minutes, each followed by the notes.md re-inject; the agent kept restarting the file list (182 tool results for 13 files), then the run ended on "missing meta credentials". Shows the setting and hooks work, and that the point must sit well above Muse's starting context |

Grok's probe ran from this worktree with `GROK_FOLDER_TRUST=0` on the probe's own command (the worktree is not in
`~/.grok/trusted_folders.toml`; real runs live in the trusted main checkout). `tools/context-probe.sh -C CHECKOUT`
puts the run dir in another checkout. Commands, outside the sandbox:

```sh
tools/context-probe.sh claude haiku                 # production 80K
tools/context-probe.sh codex gpt-6-luna 25000
tools/context-probe.sh grok grok-4.7 40000
tools/context-probe.sh agy gemini-3.8-flash-high 30000
tools/context-probe.sh muse muse-spark-1.3 80000    # low point; loops (see above). Production is 200K
```

## Open points

- Opus and Sonnet were not probed live (same mechanism and formula as Haiku; cost).
- Muse at 200K and Codex at 140K were not run to their production points; the probes used low points.
- Claude: the binary says threshold compaction can be "not enforced" when an experiment defers to the API's
  prompt-too-long handling; `tools/context.py report` on a real run shows the actual points.
- Codex: hooks unused (trust); a `SessionStart ^compact$` hook would be the more direct re-read if ai-session ever
  passes `--dangerously-bypass-hook-trust` or the hooks get trusted once.
- Grok and Muse log no token counts at compaction (their hook payloads have no transcript path).
- The nudge exists only for Claude Code (the harness whose hook payload points at a transcript with usage).
