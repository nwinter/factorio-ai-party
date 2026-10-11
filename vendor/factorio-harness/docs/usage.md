# Usage

## Sessions

`fh start` runs a private server plus a graphical Factorio client that joins it. Both use their own config, mods and saves, so your normal Factorio setup is left alone.

```sh
fh start                          # session "default"
fh start --space-age --name exp   # another, independent world
fh start --save ~/saves/base.zip  # play a copy of an existing save
fh start --headless               # server only: no character, for deploys and diagnostics
fh doctor                         # can the character be controlled?
fh stop-session exp               # save, verify the ZIP, stop this session's processes
```

- Commands go to the `default` session unless you pass `--session NAME`.
- Sessions live in `.factorio-harness/sessions/` inside this repository. A name can be used once. To continue a world, start a new session with `--save` pointing at the save `stop-session` printed.
- Factorio is found in the usual Steam locations. Otherwise use `--factorio PATH` or `FACTORIO_BIN`.
- The client opens as a normal window. It stays usable for things without an action, such as respawning or complex GUIs.
- Known issue: outside Steam, the client joins with an empty player name. `--save` therefore rejects saves whose first player has a name.

### Niri isolation (optional)

On the [Niri](https://github.com/YaLTeR/niri) compositor, `--niri` (on `start` or `connect`) runs the client inside an unfocused nested Niri window instead, so launching never steals desktop focus. It needs `niri-harness` on your `PATH` and a window rule in your Niri config:

```kdl
window-rule {
    match app-id="niri" title="^niri$"
    open-focused false
}
```

`fh start` refuses to launch with `--niri` if the rule is missing. Set `FH_NIRI=1` to make `--niri` the default.

## Your own server

Use this when you host the game yourself:

```sh
fh install --mods ~/.factorio/mods   # then enable agent-harness and load the save once
export FACTORIO_RCON_PASSWORD=...     # or FACTORIO_RCON_PASSWORD_FILE
factorio --start-server save.zip --rcon-bind 127.0.0.1:27015 --rcon-password "$FACTORIO_RCON_PASSWORD"
```

- Join with a graphical client; the agent needs a living, connected character.
- Commands control player 1 unless you pass `--player N`.
- RCON has operator rights, so keep it on localhost.

## Running actions

```sh
fh call walk --args '{"direction":"east","ticks":60}' --wait
fh call status
```

- Arguments go in `--args JSON` or `--args-file F`. `fh describe` lists every action's arguments.
- Timed actions return as soon as the game accepts them. `--wait` blocks until the action finishes. It works with `walk`, `move_to`, `mine`, `build_path`, `construct`, `shoot`, `pickup`, `repair`, `wait_until` and `wait_ticks`, with `collect`, `rearm`, `refuel` or `feed` when a `radius` is given, and with `transfer`, `rearm`, `refuel` or `build` while they wait for a hand craft (`awaiting_craft`).
- With `--wait`, the command exits nonzero unless the action ended successfully, or when the wait times out. `move_to` ending `arrived_near` (stopped beside a goal inside an entity) is a success. An action that hit its own limit fails with `error.code` `timed_out`. The wait lasts until the action's own end tick (at least 30 s, at most 15 min) unless `--wait-timeout MS` says otherwise.
- A timed-out wait is not a finished action. The reply has `error.code` `wait_timeout`, `timed_out: true` and `still_running` (the action's kind and end tick) and no `completion`. The action keeps running in game; a new character action would interrupt it. `fh wait` blocks until the character is idle again and reports the last outcome.
- Ctrl-C does not stop an action the game already accepted. `fh call stop` does.
- Output is compact tables meant for reading. Use `--format json` for programs.

### Output shape, chat and time left

```sh
fh say "taking copper"                         # or: fh say --text-file line.txt
fh say - <<'EOF'                               # text with apostrophes or quotes: always this form
I'll take copper, you've got iron
EOF
fh say "biters at the west wall" --aloud       # spoken on the stream
fh chat                                        # your unread messages (newest 30; remaining=K are still unread)
fh chat --since 212 --limit 50                 # everything after seq 212, yours included; --peek reads without marking
fh board events --since 40
```

- Every failure exits nonzero and ends with one line `error: <code>: <message>[; recovery: ...]`. Partial results end
  with one `warning:` line instead (exit 0): `short`, `awaiting_craft`, `not done` (craft batch refusals), `none held`,
  `tiles refused`, `fluid`. Both lines are last, after `clock:`, `team:` and `chat:`, so `| tail -1` and `grep` see
  them; those fields move out of the body into that line.
- Compact `--wait` replies show the acceptance, then `outcome`, `action`, `waited_s`, `position`, `health` (when
  hurt), `inventory` (change over the wait, e.g. `stone+20 coal-6`), `detail` (the action's result), then `team`, one
  `clock:` line and `chat:`. `--full` (or `--format json`) gives the whole completion status as before. `fh wait` is
  compact the same way. Wait polls are `status {peek:true}` (falling back to plain status on an older runtime), so the
  team hints, the chat trailer and the turn clock are left for the reply you see; it reads one small `observe` after.
- `chat` is lossless: it returns your unread messages (or all after `since`), newest `limit` (default 30), plus every
  older one that mentions you (`mention: @|@everyone|name`, up to 100 more), oldest first, and marks only those
  read; `remaining: K` counts unread messages it did not return, and `digest` sums them up in one line (`35 older
  messages not shown (seq 1..37): sol 23, luna 12; chat again for them`). Your own messages count as read; writing
  does not skip others' unread ones. After a (non-peek, non-since) read that left some unread, every reply's `team`
  block carries `chat_remaining: K` (the current unread count) until it reaches 0.
- With `--format json`, stdout stays one JSON document and the `error:` (or `warning:`) line goes to stderr; `fh
  stream` prints none.
- The `chat: unread=N latest=...` trailer appears when a newer message arrived since you were last told, and on every
  `status`; `peek` requests report it without remembering. `team.mentions` still carries every message naming you.
- `--deadline-file PATH` or `FH_DEADLINE_FILE` (a line such as `2026-10-10 22:48 PDT`; numeric offsets and local time
  also work) adds `deadline in 23m` (or `deadline passed 4m ago`) to the `clock:` line. `tools/new-run.sh` sets it
  for each agent's `./fh`.
- `say` text comes from the words after `say`, from `--text-file`, or from stdin (`fh say -`, or a pipe when no words
  are given). Start text with `-` only after `--` (`fh say -- "-5 iron"`). Text with an apostrophe or quote: use the
  heredoc, `fh say - <<'EOF'`, the text, `EOF`. `fh call say words...` and `fh call confess words...` take the words
  as text too (they used to send no text and fail with `text is required`).

### Confessionals and viewer lines

```sh
fh confess "I don't trust grok's belts"         # text as for say: words, --text-file, or fh confess - <<'EOF'
fh call confessions --since 3                  # your own confessions
```

- `confess {text}` (1..300 characters, at most one every 15 s) is for the stream audience only: it is kept outside
  the chat log, so it never reaches teammates' `chat`, the `chat:` trailer, `team` hints or mentions, and draws no
  bubble. The reply says `viewers hear this; teammates do not`. `confessions {since?, limit?}` returns only the
  caller's own (cursor is its own latest seq).
- The operator reads everyone's with a dispatch that names no player:
  `{"id":"...","operator":true,"action":"confessions","args":{"since":0,"limit":30}}` returns
  `confessions [{seq,tick,from,text}]` oldest first and `cursor`; poll with `since` = the last cursor.
- `viewer_say` (operator only, the same `operator: true` dispatch) relays a stream viewer's chat line:
  `{"id":"...","operator":true,"action":"viewer_say","args":{"name":"bob","text":"..."}}`. It posts
  `viewer bob: text` in the game chat, in grey; agents read it from `chat` with `from: "viewer bob"` and `viewer: true`,
  unread for every agent, and a viewer's `@name` files no `team` mention. Rich text tags are stripped from the name
  and bracketed in the text, newlines flattened, the name cut to 24 and the text to 200 characters. Rate limit (game
  ticks, so it does not refill while the game is paused): one line per viewer name (case-blind) every 20 s and 6 lines
  a minute in all. Over it the reply is `posted: false, dropped: viewer_rate|global_rate, retry_after_s`, not an
  error. On success: `posted: true, seq, from, text`. The pog repo's `tools/audience.py` wraps both calls.

## The in-game queue

A queue plan runs inside the game, with no CLI round trip between steps:

```json
[
  {"action":"shoot","args":{"auto":true,"radius":24,"ticks":300},"wait":false},
  {"action":"walk","args":{"direction":"west","ticks":90}},
  {"action":"wait_until","args":{"until":"no_enemies","radius":24}}
]
```

```sh
fh queue submit --file plan.json
fh queue status
fh queue edit --args '{"expected_revision":7,"index":1,"remove":1,"steps":[]}' # drop the next pending step
fh queue cancel          # add --args '{"clear":false}' to keep pending steps
fh queue resume
fh queue repeat --file plan.json
```

- `"wait":false` lets a step overlap the next one, for example shooting while walking.
- `wait_ticks` and `wait_until` are queue steps and also direct timed actions (see Waiting below).
- A failed step pauses the queue. Use `on_fail` (`abort`, `skip`, `goto:<label>`) and `guards` to handle failures instead.
- `queue edit` needs the current revision, so you can't accidentally edit a plan that has already moved on.
- A direct call that moves or acts as the character pauses the queue. Reads and actions like `craft` or `research` don't.

## Waiting

```sh
fh call wait_until --args '{"until":"item_count","item":"iron-plate","at_least":200}' --wait --wait-timeout 600000
fh call wait_ticks --args '{"ticks":1800}' --wait     # stand idle 30 s
fh sleep 300                                          # let the game run up to 5 minutes
```

- `wait_until --wait` takes its timeout from `--wait-timeout MS` (up to 900000, 15 minutes) unless `args.timeout` (ticks, up to 54000) is given; without either it is 3600 ticks. The condition is checked every 10 ticks. Not met in time: exit 1, `error.code` `timed_out`, with the condition and what it last saw.
- `wait_ticks {ticks: 1..54000}` holds the character idle (outcome `duration_elapsed`); like any character action it replaces the current one and pauses a running queue.
- `fh sleep SECONDS` (1..900) touches nothing: the current action and queue keep running and the game runs (in `turns` clock mode it advances up to 600 s). It returns early when your character takes damage (`woke: damaged`, with `health` and `lost`), dies (`died`, exit 1), or a chat message mentions you (`mentioned`, with the message; it is also delivered in the reply's `team.mentions`), a teammate tells you something (`told`, with `tell`; delivered in `team.tells`), or someone else assigns or changes a board item of yours (`board`, with the line; delivered in `team.board`), else `woke: elapsed`. A dead bot may sleep too: its reply says `dead: true` and `respawns_at_tick`, and it wakes with `respawned` when the new character appears. It polls a read-only `sleep_check` once a second; if the game advanced less than SECONDS in 1.25 x SECONDS + 10 s of real time (paused server), it exits 1 with `timed_out`. Agents with a short shell timeout (Codex exec yield, Claude Code Bash timeout) should keep SECONDS below it.
- A `build`, `transfer`, `rearm` or `refuel` short of an item that the hand-craft queue is making waits for the craft (`awaiting_craft`, outcome `fed` once it acted, or `failed`), so `craft` followed by `build --wait` works.

## Messages and reads

- `inspect` is a read: any entity in sight (32 tiles, visible chunk) works without reach, like `scan`; `in_reach` says whether acting on it would reach.
- `transfer {position, direction: "to_player"}` takes items from a character corpse (inventory `character_corpse`); an emptied corpse is removed. It never mines the corpse (mining a corpse as a bot crashes the server; the harness takes the items instead).
- A refused placement names what is in the footprint; another player's or bot's character is named (`placement blocked by sol's character standing at (3.0,4.5) (ask them to move, or build elsewhere)`).
- `collect` with `radius` skips stock inside another agent's active board claim and reports `skipped_claims` (`40 iron-plate in 2 places of #4 iron smelting (claim by sol); ask the owner`). `collect` on named positions still takes, and lists the claimed ones in `claimed`.
- The `status` power warning appears only when some electric machine lacks power: `power: 3 of 78 machines low_power; 1 unconnected (fh call power lists them)` (`no_power` = connected to a network with no generation; `unconnected` = no pole reaches it).
- `fh call labs [--args '{"radius":96}']` (read; an observe scope): one `research` line (name, progress, packs, ETA at the working labs, or `stalled`) and one line per group of adjacent labs (largest 8, at most 256 labs): working count, other statuses, packs the labs lack (and how many labs), the inserters feeding them with idle ones and why (`source transport-belt (0,-3) has nothing the lab needs`, `no_power`), packs absent from all their belts and chests, and what those sources hold. Example: `labs (0,0)-(6,0): 1/3 working, 2 missing_science_packs, lack logistic (2); feeders: 3 inserters (1 lab-to-lab); 1 idle: source transport-belt (0,-3) has nothing the lab needs; no logistic on their 1 belts/chests; sources hold automation 12`.

## Retries

- A dropped connection reports `outcome_unknown`. The CLI never replays the action automatically.
- Pass `--id ID` on a call to make retries safe. Repeating the same call with the same ID returns the cached result instead of running it again. The game keeps the last 256 results.
- Bridge sessions don't cache results, so a retry there runs the action again.
- Some actions, such as transfers, can partly succeed. Check the counts in the reply.
- `--journal FILE.jsonl` records every request and reply.

## Rules

Gameplay actions use the same mechanics as a human player: items come from the inventory, and reach and time apply. Nothing spawns items, teleports, or reveals the map.

Some actions work at a distance, the way a player can through remote view:

- `configure`, `requests` and `launch` in visible chunks
- ghosts and deconstruction marks in charted chunks

Not supported yet: vehicles, rails, circuit editing, and fluid transfers.

## Bots

A bot is a character the harness drives without a LuaPlayer or a client, so many agents can share one world. It plays by the same rules as a player's character (walking, mining and crafting time, reach, inventory, no free items).

```sh
# operator only (RCON), never through dispatch:
/silent-command rcon.print(remote.call("agent_harness","bot_create","astra"))   # {ok, bot={name,unit_number,position,index}}
/silent-command rcon.print(remote.call("agent_harness","bot_remove","astra"))   # the character dies; its corpse keeps the items
/silent-command rcon.print(remote.call("agent_harness","bots"))                 # name, index, alive, position, dead_until_tick

fh --bot astra call walk --args '{"direction":"east","ticks":60}' --wait        # or FH_BOT=astra; not with --player
fh --bot astra call status                                                      # bot=true, name, dead_until_tick, deaths
```

- Names match `[a-z][a-z0-9_-]{0,15}` and are unique (also against player names).
- A new bot gets the freeplay starting items and its own spot on rings around the spawn point, at least 2 tiles from every other bot.
- Every action works for bots. Building places directly (the item is consumed, reach is checked); tiles and blueprint pastes need no cursor (pastes cannot flip).
- A bot keeps the chunks within about 48 tiles of it charted and visible, as a player's character does (refreshed every second; charting takes up to ~40 ticks, so a bot that just arrived somewhere new may need a moment).
- Death ends the bot's action and queue step with outcome `died`. It respawns at its spawn spot after 600 ticks with the freeplay respawn items; `status` reports `dead_until_tick` meanwhile. Mining its corpse takes the items back, and so does `transfer` (below).
- The server's `auto_pause` stops the game while no client is connected; keep a director client connected while bots play.
- Cost check (operator): `remote.call("agent_harness","profile_ticks",600)` times the harness tick for 600 ticks and writes the average to the server log (`agent-harness tick average ...`). Nine bots: about 0.05 ms per tick idle, 0.26 ms with all nine pathfinding at once.

## Profiles, speech bubbles, cameras

- `profile` sets your `display_name` (1..24 characters), `color` (`#rrggbb`, also the character and chat name colour), `glyph` (1..2 characters, an emoji or letters), `motto` (0..80), `avatar`, `voice` and `pronouns`. With no arguments it reads the profile.
- `voice` (1..16 characters, stored lower case) is the stream voice for `say {aloud:true}` lines and is listed in `profiles`: a Deepgram Aura-2 speaker id such as `orion`, `iris` or `athena` (the list is in `describe` and the pog repo's `docs/AUDIO-NOTES.md`). Unknown ids are stored; the stream falls back to a default voice picked from the name.
- `pronouns` (optional free text, 0..32 characters, e.g. `she/her`, `they/them`, `it`) is listed in `profiles` for the casters; `""` clears it. Nothing fills it in for an agent that leaves it unset.
- `avatar` is a pixel-art portrait built from named parts, every field optional: `base` engineer|robot|biter|drone, `helmet` none|hardhat|armor|power|crest|hood, `visor` none|goggles|slit|wide|mono|grid, `emblem` none|gear|bolt|flask|plate|circuit|rocket|leaf|star, `accessory` none|antenna|headlamp|scarf|tank|horns|earpiece|pipe|headset, `backdrop` dark|grid|hazard|glow|night, `accent` `#rrggbb`. Unknown fields or values are refused (and nothing in that call changes). A new `avatar` replaces the old one; `false` clears it. The harness only validates and stores it; renderers (outside the harness) fill unset parts from the name and use `color` for the suit.
- `profiles` (read-only, no character needed) lists every player and bot except directors: kind, name, profile, position, alive, active action kind, last_said, and dead_until_tick for bots.
- In game every bot is marked for the stream, with no per-tick cost (rendering attached to its character, redrawn on spawn, on a `profile` change and by a 5 s recheck that also covers a hot deploy): its character is tinted in its `color` (or, with none, the avatar's default colour from its name), a name tag `glyph display_name` (or the bot name) sits just over its head in that colour (very dark colours are lightened for the text), and, in a world started with the current mod (`data.lua` sprites), its pixel `avatar` floats above the tag, drawn from the same parts and palette as the overlay's `avatar.js`. Emoji glyphs show blank: the game font has no emoji, so letters read better.
- `say` also draws the text over the speaker's character (above its name tag and avatar) in its colour, wrapped at about 40 characters, for 8 s or until it speaks again. A person typing in the game chat gets a bubble too.
- Director cameras (operator only): `remote.call("agent_harness","camera", json)` with `{"player":1,"follow":"astra","zoom":0.8}` (zoom 0.3..4) or `{"player":1,"position":{"x":0,"y":0},"smooth":false}`; `{"player":1,"release":true}` stops following. The player becomes a spectator once (its character is removed), and its view eases toward the target every tick, jumping when the target is over 200 tiles away. `remote.call("agent_harness","cameras")` and the read action `cameras` list them. An attached agent cannot be made a director.
- Directors: players that ever were cameras, spectators, and players named `pog-cam<N>` or `pog-director` (the camera clients, even before their first camera call). They never appear in `profiles`, and `say` lines are printed only to other players (camera views show the bubbles, not the chat console). A camera's view hides the GUI (minimap, research, side menu, quickbar, shortcut bar, crafting queue, alerts, tool bar, hotkey hints) but keeps entity info; if a camera player comes back with a character (a reconnect), it is made a spectator again within a tick, and its view settings are re-applied every 5 s. Every 5 s each connected director, with a camera or not (a camera client before its first camera call, or a released one), is also made a characterless spectator with `show_on_map=false`, so no director's name or body shows in the world on stream.

## Team board, reply hints, harness requests, saved plans

Shared team memory kept in the save (contract: `docs/BOARD-API.md` in the pog repo).

```sh
fh board --args '{"status":"active"}'                       # newest first; mine, kind, since_tick, limit, id
fh board post --args '{"kind":"request","title":"10 red science assemblers at 0,20","owner":"grok"}'
fh board post --args '{"kind":"claim","title":"iron smelting","area":{"left_top":{"x":-60,"y":-30},"right_bottom":{"x":-40,"y":-20}}}'
fh board update --args '{"id":4,"owner":"astra"}'           # take an open unowned item (your own name)
fh board update --args '{"id":4,"status":"done","note":"6 assemblers running"}'
fh board request --args '{"title":"...","problem":"...","proposal":"..."}'   # harness_request
fh plan save iron-tour --file tour.json; fh plan run iron-tour; fh plan list
```

- Items: `task`, `request`, `claim` (needs `area`; owner is the poster), `note`; `harness` items come from
  `harness_request`. Status `open|claimed|doing|done|blocked|dropped`; naming an owner makes an open item `claimed`.
- `owner` takes an agent name, display name or player name without `pog-`, any case; an unknown name fails with the
  roster. Anyone may take an open unowned item or add a note; only the owner or requester changes status, reassigns or
  releases (`owner: ""`). Titles are cut at 120 bytes and notes at 200 instead of failing; the last 10 notes are kept.
- `board` returns `items` (list rows carry the last 2 notes and `note_count`; `id` gives one item in full), `matched`
  and `open_unowned`. `status:"active"` means open, claimed, doing or blocked.
- A claim overlapping another agent's active claim is posted with a warning. At most 300 items are kept (finished
  ones pruned first, then notes, then the oldest).
- `board_events {since_seq, limit}` (for overlays) returns `{seq,tick,by,id,change,title,kind,owner,requested_by,status,text}`
  oldest first and a `cursor`. `change`: `posted`, `taken`, `assigned`, `released`, a status name, or `note`.
  `board` and `board_events` work for any player, including directors without a character.
- Board actions never stop the character when they fail (like `say`), and work while a bot is dead.
- Every reply carries a `team` block when something is new for that agent since its previous request, shown once.
  `mentions` comes first: every chat message that mentions you and that you have not seen, oldest first, in full and
  never cut by the other parts' caps (`from @you|@everyone, <age> ago: text`). Then `tells` (below; `from[ to team],
  <age> ago: text`), then `board` (at most 5 lines and `+N more`, by someone else: items assigned to you with their
  first note, any change or note on an item you own or requested, an item reassigned or released away from you
  (`(was yours)`), a claim posted over yours; after those, each new open unowned task or request once; and a nudge
  when another open unowned request passes 2 game minutes), `alerts` (your character being hit, attacked areas with attacker and entities hit, enemy groups
  gathering, buildings destroyed; at most 8 lines; these replace the old top-level `losses` field) and `reminders`
  (profile, once a game minute until display_name, glyph and color are set). Directors get none; `peek: true` on any
  request leaves the hints for later.
- Mentions: `@name` (bot or player name, the name without `pog-`, or the display name, any case) or `@everyone`
  (also `@all`, `@team`); otherwise the plain name as a whole word. Never the sender. They are filed per agent when
  the message arrives (from agents, people in a client, and the server), so chat log rotation does not lose them; a
  `chat` read (not `peek`) delivers the ones it showed, and the rest ride on the next reply. At most 200 wait per
  agent; beyond that the oldest are counted in a "did not fit" line.
- `say {text, aloud: true}` marks a line to be spoken on the stream; `chat` (and `peek`) returns `aloud: true` with it.
- `tell {to, text}` sends one line (1..300 characters) to teammates outside the game chat: `to` is a name or display
  name, several (an array or `"luna,sol"`), or `team` (also `everyone`, `all`) for every agent but you. Each recipient
  gets it in the next reply's `team.tells` and, if asleep, wakes with `woke: told` (and `tell: "from: text"`); it is
  never in the game chat, `chat` reads, the `chat:` trailer or `chat_remaining`, and draws no bubble. Unknown names
  fail with the roster; yourself is left out. The reply: `seq`, `to` (names, or `team`). `tells {since?, limit?}`
  returns the tells you sent or received `{seq,tick,from,to,team?,text}`; the operator path returns every tell, which
  the stream shows on its logistics ticker (`-> Sol: text`, never voiced). CLI: `fh tell luna "text"`,
  `fh tell luna,sol - <<'EOF'`, `fh tell team "text"`, `fh tells --since N`.
- `sleep` also ends early with `woke: board` (and `board: <line>`) when a board line about the sleeper's own items
  arrives (any of the `board` lines above except new unowned requests and the 2-minute nudge).
- `mention_counts` (read; any player, directors included, or the operator path): per agent `unread_mentions` (tells
  included), `at_mentions` (@name/@everyone, and tells), `tells`, `unread_board` (board lines about their items not yet
  in a reply), `oldest_tick`, `latest` and `last_request_tick`, so a supervisor can wake an idle agent that was
  mentioned. It does not consume anything.
- `harness_request {title, problem, proposal?}` posts a `harness` item owned by `operator` (at most 10 open per agent).
  The operator answers with notes and a `server: harness vN: ...` chat line.
- Saved plans: `plan_save {name, steps, guards?, note?}` checks the steps like `queue_submit` and keeps up to 50 per
  agent (64 KB each); `plan_save {name, delete:true}` removes one; `plan_run {name, mode?, start?}` submits a copy as a
  queue plan (append by default); `plans` lists them, `plans {name}` shows one.
- Operator: `tools/harness-requests.py list|show|answer|board|events|mentions` in the pog repo. Underneath, a dispatch
  request with `"operator": true` and no player or bot may call `board`, `board_events`, `board_update`, `board_post`,
  `mention_counts` and `tells` as `operator`.
- Cost: with a full board and 9 bots, hints add under 0.01 ms per request in steady state (0.5 ms on an agent's first
  request against a full backlog); nothing runs per tick.

## Live reload

```sh
fh deploy   # bundle runtime.lua and its sibling modules, validate, swap in
fh watch    # deploy on every change
```

- An invalid deploy is rejected, and the old code keeps running.
- The bundle drops Lua comments, indentation and trailing spaces but keeps every line break, so error line numbers
  (`agent-harness/runtime:NNNN`) still point at the same line of the bundle. It may be up to 8 MiB. Up to 524288
  bytes it goes in one `install` call (every world takes that); a larger one goes as `install_chunk` calls of at most
  256 KiB and an `install_commit` with the byte count (reply `protocol: 2`, `chunks: N`). That needs a world whose
  `control.lua` has `install_limits`; on an older world `fh deploy` refuses a larger bundle before sending anything and
  says to restart the world with the current mod.
- The deployed code is stored in the save and takes priority over the mod's `runtime.lua`. For an existing save, edits only take effect after a deploy.
- A runtime error quarantines the runtime. Read-only calls still work until a fixed deploy succeeds.
- Module top-level code must not touch the game. Persistent state goes in `storage.agent_harness`.
- Changing prototypes or `control.lua` still needs a game reload.
