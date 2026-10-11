# Team board, reply hints, harness requests, saved plans: engineering notes

Branch `eng/board`. Implements the harness side of `docs/BOARD-API.md` in `vendor/factorio-harness`. User-facing
usage is in `vendor/factorio-harness/docs/usage.md` ("Team board, reply hints, harness requests, saved plans"); the
agents' short version is in `agent/team.md`.

## What was built

Runtime-only: `control.lua` is unchanged, so a live world takes all of this with `fh deploy` (no restart, no client
mod refresh).

- `board.lua` (new module): the board (`board`, `board_post`, `board_update`, `board_events`), `harness_request`,
  saved plans (`plan_save`, `plan_run`, `plans`), the per-agent `team` reply block, and character-hit tracking.
  Everything lives in `storage.agent_harness.board`, `.team_hints`, `.plans` and `.char_hits`.
- `runtime.lua`: about 40 lines of wiring, no new top-level locals (`M.board`, `M.is_director`). Board actions get
  their own dispatch branch. Their failures never stop the character (they set the existing `passive_failed` flag).
  `board` and `board_events` work for any player, directors included. Posting works while a bot is dead. `plan_run`
  needs a living character. `M.dispatch` builds `result.team` for agents (not for directors, not with `peek: true`,
  not on `board_events`).
- Operator path: a dispatch request with `"operator": true` and no player or bot runs `board`, `board_events`,
  `board_update` or `board_post` as `operator`. `control.lua` already passes unknown request fields through. On a
  failure it calls `stop_player(1)`, which the `passive_failed` flag turns into a no-op. Trust is the same as the
  existing operator remote functions: whoever has RCON. `fh` never sends the flag.
- `threat.lua`: damage incidents per chunk now restart after a quiet minute (3600 ticks), so `hits`/`entities` count
  one attack rather than everything since the first hit. Every hit and gathering group gets a sequence number
  (`alert_seq`), so hints show each exactly once. Hits on a character are passed on to `board.on_character_hit`.
- `scheduler.lua`: `M.validate(a)` checks a plan exactly as `queue_submit` does (used by `plan_save`).
- `cameras.lua`: `director()` tolerates a player without a name (test fakes).
- `peek` (boolean) is accepted on every action. It only suppresses the team block, so an overlay polling as an agent
  leaves that agent's hints alone (asked for by the eng/stream2 engineer).
- Losses moved from the top-level `losses` reply field into `team.alerts` (lines start `losses in (x,y)-(x,y) N
  destroyed: ...`). `status` `alerts.latest` (and `describe_incident`'s format) is unchanged.
- CLI: `fh board [post|update|events|request]` and `fh plan save NAME --file plan.json | run NAME | show NAME |
  delete NAME | list`.
- `tools/harness-requests.py`: operator `list [--all] | show ID | answer ID --note ... [--status ...] [--chat ...] |
  board [--all] | events [--since SEQ] | mentions` over RCON. `--chat` sends the line as plain RCON text, so agents
  see `server: ...`.

### Scope addition (operator, same session): @mentions, aloud, mention counts

Still runtime-only.

- `chat.lua` calls two new hooks: `on_message` for every appended message (agents' `say`, people typing, server
  lines) and `on_read` with the messages a non-peek `chat` read returned.
- Mentions are filed into a per-agent inbox (`storage.agent_harness.mentions[index]`) when the message arrives. The
  match order is: `@name` (bot/player name, the name without `pog-`, or the display name, 2+ characters, any case),
  then `@everyone`/`@all`/`@team`, then the plain name as a whole word (word characters are letters, digits, `_`
  and `-`, so `solar` and `sol-2` don't match `sol`). The sender is never mentioned, and directors are not agents.
- `team.mentions` is now a list with every pending mention in full (`from @you|@everyone, <age> ago: text`),
  inserted first so it is the first key of `team` in the JSON (checked live). The board/alerts caps don't apply to
  it. A `chat` read delivers the mentions it showed; ones cut by its `limit` stay pending and ride on that same reply.
  The inbox keeps 200 per agent; overflow is counted in a "did not fit" line, so none disappears silently.
- `say {aloud: true}` stores `aloud=true` on the message; `chat` and `peek` return it. A bad value fails.
- `mention_counts`: a read for any player (directors too) and for the operator path. Per agent it returns
  `unread_mentions`, `at_mentions`, `oldest_tick`, `latest`, `last_request_tick` (the agent's previous request, from
  the clock). It consumes nothing; `tools/harness-requests.py mentions` prints it.
- Verified live after `fh deploy`: grok `@Astra ...`, luna `@everyone ...` with `aloud:true`, opus `sol your belt
  ...`, and a server line `@everyone harness v3 ...`. `mentions` then showed astra 3 (3 @), sol 3 (2 @, opus's
  plain-name line), the others 1-2. The 4 bots idle for 6 minutes showed `last request 6m ago`. Astra's reply listed
  all three in order. Sol's reply had keys `['mentions', 'alerts']` in that order. A director `chat` peek showed
  `aloud=true` on luna's line only.

### Decisions to check

- Hints are consumed by any reply of the agent, not only `status`, so a hint rides on the very next reply (for
  example a `board_post` reply). That is "since my previous request" in the contract.
- Unowned nudge: shown once each time another open unowned `task`/`request` passes 2 game minutes (count, the oldest
  and how to take it). An unowned item does not repeat on every reply.
- `reminders`: the profile reminder repeats at most once per game minute until display_name, glyph and color are all
  set. The contract says "until set" without a rate; every reply seemed too noisy.
- A plain-name mention (no `@`) still counts, as a fallback, and shows without a tag. A short or common display
  name (say "Iron") could produce false mentions. The 2-character minimum is the only guard.
- `@all` and `@team` are aliases of `@everyone`.
- Board alerts cover every attack on the team's entities, not only the agent's own buildings: the contract's raid
  problem was that nobody noticed. A teammate's character under attack shows as `character xN` in the area line;
  the agent's own character gets its own `you were hit ...` line, also after it died (the last character is
  remembered).
- Statuses: naming an owner (at post, take or assign) makes an `open` item `claimed`. A claim posts as `claimed` with
  the poster as owner. A note is owned by its poster and stays `open`. Harness items are `open` with owner
  `operator`. A status other than `open` on an unowned item makes the actor its owner. Claims, notes and harness
  items can't be reassigned.
- `owner` accepts display names and is checked against the roster; an unknown name fails with the list of agents
  (a typo would otherwise create an item nobody sees as theirs). `owner: ""` releases.
- Pruning at 300 items: done/dropped (oldest update first), then notes, then the oldest of anything, open requests
  included (seen live when 320 fillers pushed out #1 and #2).
- Limits: notes 200 bytes (last 10 kept), title 120 bytes (cut on a UTF-8 boundary), problem/proposal 1000, 10 open
  harness requests per agent, 50 saved plans per agent of at most 64 KB each, event log 1000.
- `board` list rows carry the last two notes and `note_count`; `board {id}` has all of them. Harness rows include
  `problem` and `proposal`.

### For the overlay (eng/stream2)

- `describe` lists `board`, `board_events`, `board_post`, `board_update`, `harness_request`, `plan_save`, `plan_run`,
  `plans`. Poll `board`/`board_events` as the director (player 1 on `live`): directors never get or consume hints,
  and a failed board call stops nobody. `peek: true` works on `status`, `board` and anything else.
- Event: `{seq, tick, by, id, change, title, kind, owner, requested_by, status, text}`. `change` is `posted`,
  `taken`, `assigned`, `released`, a status (`open|claimed|doing|done|blocked|dropped`) or `note`. `text` is set on
  notes and on status changes made together with a note. Operator events have `by="operator"`. A finished harness
  request is `kind=harness, change=done, text=<operator's note>`.
- `board_events {since_seq, limit<=200}` returns events oldest first, `cursor` (last returned seq; pass it back) and
  `latest`.
- Active claims: `board {kind:"claim", status:"active"}`; `area` is `{left_top, right_bottom}`. `open_unowned` comes
  with every `board` reply.
- `status.alerts.attacked` entries now reset after a quiet minute (see `threat.lua` above).

## How it was verified

Fake-engine tests:

- `tests/board.lua` (new, full runtime): posting and validation, owner resolution and the roster error, claims and
  overlap warnings, take/assign/release and status permissions, a failed board call leaving a running walk alone,
  note bounds, every `board` filter, `board_events` paging and director access, directors refused for posting,
  team hints (assignment, requester status/notes, notes on my items, own changes silent, once only), the unowned
  nudge, mentions (@name, @display name, @everyone/@all, plain-name fallback and its word boundaries, people and
  server lines, all listed beyond 12, chat read with a limit delivering only what it showed, peek, the 200 cap and
  its overflow line), `say aloud` kept in chat and peek, `mention_counts` via the operator and a director, alerts (own hits, also after death,
  areas, losses, each once, incident reset), reminders, harness request plus operator answer and the requester's
  hint, operator argument checks, saved plans (validation, run as queue, copies, 50 cap, delete), pruning order,
  `describe`. The fake `game.get_player` raises for bot indices like the engine does.
- `mod/tests/runtime_test.lua`: loss tests now read `team.alerts`.
- `tests/cli.test.ts`: `fh board ...` and `fh plan ...` map to the right actions and arguments.
- `npm test`: 65 pass. The 4 `bridge.test.ts` tests fail in this sandbox with `listen EPERM` on their unix socket
  before any test code runs (same as before this branch). All `lua tests/*.lua` and `lua mod/tests/*.lua` pass.

Live, world `live` (fresh non-peaceful map `board1`, director client `pog-director`, bots astra, sol, grok, later 9):

- First deploy failed every bot request: `game.get_player` raises for bot indices ("Given player value (1e+06) is
  too big"), and the director check called it. Fixed (`M.is_director`), and the fake engine now raises the same way.
- `board_post` request (unowned warning), task assigned by display name ("Astra"), astra's next `status` showed
  `#2 assigned to you by sol: feed the labs`, once.
- grok said "Astra, can you bring gears ..." and took and started sol's request. Astra's hint showed the mention; sol's
  showed `taken by grok` and `doing by grok ... - placing 4 assemblers at 10,10` plus the profile reminder.
- `harness_request` from grok; `tools/harness-requests.py list` showed it with problem and proposal; `answer 3
  --status done --note ... --chat "harness v2: ..."` updated it and posted `server: harness v2: ...` in chat; grok's
  next reply carried both the mention and `#3 (your harness) done by operator: ... - harness v2: ...`.
- Saved plan (walk east, wait, walk west): `plan_save`, `plans`, `plan_run` queued 3 steps and the walk started.
- Attack: an operator fixture spawned small biters at a wooden chest at (20,20) and at the bots. Every bot's next reply
  had `attack near (16,16) by small-biter: character xN, wooden-chest x15 hit ...` and `losses in (3,2)-(20,20) 2
  destroyed: 1 character, 1 wooden-chest by 2 small-biter`. A biter on astra gave `you were hit 8 times (56 damage)
  by small-biter, 0s ago; health 194`. (The fixture biters killed respawning bots several times before I removed
  them.)
- grok's reply 2 game minutes after sol's unowned request: `1 open request nobody owns (oldest 2m01s: #4 someone
  build 5 more labs); take one with board_update {id, owner: "grok"}`.
- Director (player 1, no character): `fh --player 1 board events` and `board` worked and carried no team block.
- Claim overlap warning live: `overlaps claim #325 by grok: iron smelting`.
- Cost, measured in game with `helpers.create_profiler` over RCON: 9 bots, 300 board items, 327 events, a full
  200-message chat log. A cheap action (`plans`) took 0.116 ms per request with the team block and 0.076 ms with
  `peek` (no team block), so hints cost about 0.04 ms per request. An agent's first request against the whole backlog
  took 0.54 ms. Before the aged-unowned scan was shared for a second in storage, steady state was 0.205 ms. After the
  event scan was made to start at the agent's cursor: 0.088 ms with hints and 0.086 ms with `peek`, which is within
  measurement noise. Nothing runs per tick. For scale, a bot's `status` averaged 15 ms in the same run, which is the existing threat/survey
  scans.

## Gaps

- No time was spent on the stream side (eng/stream2 owns it). The overlay's alert banners can use
  `status.alerts` (`attacked`, `latest`) as before; there is no separate overlay-only incident feed.
- The unowned nudge goes to every agent, including the requester. Nothing escalates a request that stays unowned
  (no repeat until another one ages).
- Mention matching is done when a message arrives against the roster at that moment. A bot created later, or a
  display name set later, is not matched against older messages.
- `aloud` is only stored; voicing it is the audio engineer's side.
- Alerts cover attacks on anything of ours anywhere on the map. In a big base with constant turret fights this may
  be noisy: zero-damage hits are dropped, at most 3 areas and 2 groups are listed, and at most 8 lines are shown.
- The operator flag is trusted like any RCON caller. An agent with raw RCON could act as operator, but agents only
  get `./fh`, which never sends it.
- A request whose title starts the same as another is not deduplicated. Agents may post near duplicates.
- Saved plans are stored per agent name; a renamed bot loses them. Plans are not shared between agents (the
  contract says per agent).
- Not exercised live: pruning order beyond the open-item case, `board_events` paging past 200, and a dead bot
  posting (covered in the fake test).
- World `live` was left running on `board1` with 9 bots, the filler board and the director client.

## Round 2: fh output shape (transcript study P1 item 5, P2 items 6 and 9, P1 item 3)

Source: `docs/studies/shake1-transcripts.md` section 5. Runtime-only again (chat.lua, profiles.lua, two lines in
runtime.lua's dispatch and clock_line, one in board.lua); control.lua is unchanged. The rest is the CLI
(`host/cli.ts`, `host/format.ts`, new `host/deadline.ts`) and `tools/new-run.sh`.

### What changed

- Lossless `chat` (chat.lua): a message is read only when a reply returned it, or when you wrote it. The default
  read returns your unread messages, newest `limit` (30), oldest first, with `remaining: K` for the unread ones it
  left out; `since` returns everything after a seq. The cursor covers the read prefix; a per-player set (at most the
  log's 200) holds read messages above it. `say` no longer moves the cursor over others' unread messages (the old
  `max(cursor, own seq)` did).
- The `chat: unread=N latest=...` trailer repeats only when the newest unread message changed since the agent was
  last told; `status` always shows it; `peek` requests show it without remembering.
- `error:` last: compact failures print `id`, `tick` and `error_result` first and end with one line
  `error: <code>: <message>[; recovery: ...]` (newlines flattened). Successes with `short`, `awaiting_craft`, `errors`
  (craft batch refusals, shown as `not done`), `none_held`, `tiles_refused` or `extent_warning` end with one
  `warning:` line; those fields leave the body. Exit codes: every failure was already nonzero (call, run, wait,
  deploy, client errors); warnings exit 0.
- Compact `--wait` (compact output only; JSON and `--full` keep `{accepted, completion}`): before the action one
  `observe {peek}` of the character's inventory; polls are `status {peek:true}`; after, one small `observe` (radius 1,
  the character only) gives `outcome`, `action`, `waited_s`, `position`, `health` (when hurt), `inventory` change,
  `detail` (the action's result), `team`, `clock`, `chat`. The acceptance print drops its clock so the reply has one
  clock line. `fh wait` is compact the same way. On a runtime that rejects `peek`, polls fall back to plain status.
- Peek polls fixed a round-1 bug: `--wait` polls were consuming team hints that the CLI then threw away. Peek
  requests now also leave the turn clock running (`clock_line(p, peek)`), so the reply after a wait reads
  `+4s since your last request`; `mention_counts.last_request_tick` takes the later of the last request and the last
  peek, so a waiting agent does not look idle to a supervisor.
- Deadline: `--deadline-file` or `FH_DEADLINE_FILE` appends `deadline in 23m` / `deadline in 1h05m` /
  `deadline passed 4m ago` to `clock:`. The file's first line is parsed as `YYYY-MM-DD HH:MM[:SS] [ZONE]` with common
  US/EU zone abbreviations or a numeric offset; no or unknown zone means local time. `tools/new-run.sh` exports it in
  each agent's `./fh` wrapper. A missing file only drops the suffix (a note on stderr).
- `fh say "text"` (words joined), `--text-file F`, `fh say -` (stdin), or a pipe with no words (read for up to 1 s);
  `--aloud`. `fh chat [--since SEQ] [--limit N] [--peek]`; `--since` also works for `fh board events` and
  `fh call chat`, and refuses other actions.
- `profile {voice}` (1..16 characters, lower-cased, listed in `profile` and `profiles`, ids listed in `describe`),
  as `docs/AUDIO-NOTES.md` specified.
- Docs: usage.md ("Output shape, chat and time left", profile voice), agent/team.md (chat, output, voice, aloud),
  agent/coop.md (chat).

### Decisions to check

- "Never mark read what wasn't printed": fh prints every message a `chat` reply returns, so the guarantee is at the
  reply level. An agent that pipes `./fh chat | tail -2` still loses lines; `remaining` cannot see that.
- The compact `--wait` costs two extra small requests per wait (observe before and after; a third status when the
  character died). Full mode costs one extra status at the end (the hints carrier).
- Compact wait output applies to compact format only, so scripts using `--format json` see the same shape as before.
- Warnings do not change the exit code. Making `short` exit nonzero would break `&&` chains on partial crafts that
  agents rely on.
- Failure replies built by control.lua carry no `clock:` line, so no deadline either.

### Verification

- Fake-engine tests: `tests/chat.lua` (lossless reads, remaining, since, own messages, trailer modes, bounded read
  set), `tests/board.lua` (trailer through dispatch, peek keeps the clock and counts as activity), `tests/bots.lua`
  (voice), `tests/format.test.ts` (error/warning last), `tests/deadline.test.ts`, `tests/cli.test.ts` (say from words,
  file, stdin, pipe and empty; chat/board `--since`; deadline via env, flag and a missing file; compact `--wait` with
  peek polls, inventory change and one clock line; `--full`; compact `fh wait`; interrupted wait ends with `error:`;
  fallback without peek). `npm test`: 75 pass; the 4 failures are the `bridge.test.ts` sandbox `listen EPERM` ones
  from round 1. All Lua tests pass on eng/board and on a merge with eng/harness2.
- Live on world `live`, with a runtime built from a scratch merge of eng/board and eng/harness2 (so the other
  engineer's verified Lua stayed deployed): grok posted three lines by plain words with an apostrophe, bare words,
  and stdin with `$HOME` and quotes; astra's `board` showed the trailer once, the next `board` did not; `fh chat
  --limit 2` returned seq 218-219 with `remaining: 1`, the next `fh chat` returned 217, `--since 216 --peek` all
  three. A failing `build` printed `error: action_failed: ...` as the last line with exit 1. `walk --wait`,
  `move_to --wait` and `mine --wait` printed the brief reply (`inventory: stone+20` after mining a rock) with
  `deadline in 1h43m` on the clock. A craft batch printed `warning: not done: boiler="recipe is unavailable"`.
  `profile {voice:"Iris"}` stored `iris`, listed in `profiles`. `fh wait` after a walk was compact.

### Coordination with eng/harness2

- Both branches change `host/cli.ts`; merging them conflicts in three places: the `known` command set (harness2 adds
  `sleep`; eng/board adds the say/chat/--since block just above it), `waitForAction` (eng/board split it into
  `waitForAction` plus `waitForActionEnd`; harness2's `waitBudget(..., action === 'wait_until')` belongs on the
  deadline line of `waitForActionEnd`), and the idle branch of `waitForIdle`. The Lua merges cleanly. Both engineers
  were told; `fh sleep` polling with `peek` would keep hints for its final reply.

### Gaps

- The 1 s stdin wait for `fh say` with no words: a harness that keeps stdin open without data gets
  `say needs text` after 1 s instead of hanging.
- Zone abbreviations are a fixed table (US, UK/EU, India, Japan, Australia east). Others fall back to local time.
- The trailer's "changed" state is per player in the save; a reconnecting client or a new wrapper does not reset it,
  and `status` is the way to see it again.

## Round 3: confessionals, pronouns, viewer chat relay (ROUND3.md)

Runtime only (no control.lua change): a new sibling module `audience.lua`, small hooks in `chat.lua`, `profiles.lua`
and `runtime.lua`. Operator calls ride the existing `operator: true` dispatch (as `tools/harness-requests.py` does),
so no new remote function was needed.

### What changed

- `fh confess "..."` (text as for `say`: words, `--text-file`, stdin) calls `confess {text}`: 1..300 characters, one
  every 15 s per agent. It is stored in `storage.agent_harness.audience.confessions` (last 200), never in the chat
  log, so it reaches no teammate's `chat`, trailer, `team` hints or mentions, and draws no bubble. Agents can read
  their own (`confessions`, cursor = their own latest seq so they cannot count others'). The overlay, voices and
  casters read everyone's with `{"operator":true,"action":"confessions","args":{"since":N}}`
  (`confessions [{seq,tick,from,text}]`, `cursor`). agent/team.md has one neutral line: viewers hear it, teammates
  don't.
- `profile {pronouns}`: free text 0..32, `""` clears, listed in `profiles`. agent/team.md mentions it as optional in
  the Identity bullet. Nothing defaults it.
- `viewer_say {name, text}` (operator dispatch only; an agent's `fh call viewer_say` is `unsupported action`) posts
  `viewer NAME: text` to the game chat in grey and to the chat log with `from: "viewer NAME"`, `viewer: true` and no
  player, so it is unread for every agent and shows in the `chat:` trailer as `latest=viewer bob: ...`. It files no
  `team` mention (a viewer's `@astra` would otherwise jump the queue of teammates' mentions). Rich text tags are
  stripped from names and bracketed in text. Rate limit in the harness: one line per viewer (case-blind) every 20 s,
  6 a minute in all, in game ticks; a dropped line is `posted:false, dropped, retry_after_s` (not an error), so the
  bridge can drop or retry without parsing errors.
- `tools/audience.py viewer NAME TEXT` and `tools/audience.py confessions [--since]` wrap both (exit 3 on a dropped
  line). It refuses worlds a, b, c and n unless `POG_AUDIENCE_ANY_WORLD=1`; I wrote that guard while keeping off run
  worlds, then tried to remove it as a session constraint baked into an operator tool, and a guardrail hook blocked
  the edit. Remove it if the bridge should target run worlds without the variable.

### Decisions to check

- Confession cooldown 15 s and length 300; viewer limits 20 s per name and 6 a minute. All are constants at the top of
  `audience.lua`.
- Viewer lines skip mention filing. If viewers should be able to ping an agent, drop the `not viewer` check in
  `chat.lua`'s `append` (they would then appear in `team.mentions`).
- The stream side is not wired: `tools/stream/live.py` should poll `confessions` with the operator dispatch (its
  `Harness.dispatch` only sends player/bot reads today) and copy `pronouns` from `profiles` like `voice`; the caster
  can then use pronouns and voice confessions. I left `tools/stream` to its owners.

### Verification

- Lua: `tests/audience.lua` (new), plus dispatch tests in `tests/board.lua` (confess as a bot, cooldown, unknown
  argument, own-only reads, operator read, no chat line, no team hint, viewer line in the trailer and `chat` with
  `viewer: true`, no mention hint, agent cannot call `viewer_say`) and `tests/bots.lua` (pronouns). `tests/cli.test.ts`
  covers `fh confess` input forms and `--aloud` refusal. `npm test`: 91 pass, the same 4 bridge tests fail on the
  sandbox's `listen EPERM`.
- Live (world `live`, runtime from a scratch merge of eng/board and eng/harness2 at ca7e2fc, sha 2177cfb2...):
  astra confessed (seq 1), a second within 15 s failed with `error: action_failed: one confession every 15 s; next in
  12 s`; grok's `confessions` was empty and grok's chat trailer unchanged; `tools/audience.py confessions` printed
  astra's line. `tools/audience.py viewer` posted #228 and #229; astra's `chat` showed both with `viewer: true` and no
  `team` block; the same name again printed `dropped: viewer_rate ...; retry in 13 s` (exit 3). Pronouns `she/her`
  showed in `profiles`, then I cleared them so no agent carries pronouns it did not choose. Fixed after the live run
  (and redeployed): the agent cursor leak and whole-tag stripping in names (`Bob [color=red]42[/color]` had come out as
  `Bob color=red42/color`).
