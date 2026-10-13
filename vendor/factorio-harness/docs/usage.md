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
- An action that ends with the character on a belt, underground belt or splitter says so in `last.on_belt`
  (`standing on a transport-belt facing east: it carries you; step off to stay put`); the game moves a character
  standing on a belt. `status.on_belt` shows the same for as long as it stands on one.
- Full `status` (not `brief`) has `teammates`, one line on where every other agent is (compact output prints it right
  after `clock:`): agents elsewhere first, grouped by planet, platform or cargo pod, then the ones on your surface,
  nearest first, with distance and compass direction:
  `Sol on Vulcanus; opus 25 tiles S (offline); Luna 100 tiles NE`. `dead` and `offline` are marked; a bot is offline
  after 15 minutes with no request or sleep poll, an attached player when disconnected. Human players and directors are
  left out.
- `use_item {item, position}` throws a capsule you hold (grenade, cluster grenade, poison or slowdown capsule, defender,
  distractor or destroyer capsule) at a position in sight: the game's own projectile from the capsule's action, from
  your character, so damage and kills are the game's. The item prototype's range, minimum range and cooldown apply
  (`out of range ... reaches N tiles`, `cooling down: N ticks left`); one item is used. `use_item {item: "raw-fish"}`
  uses a capsule on yourself (the heal). Capsules of other kinds (cliff explosives, remotes) are refused. Reply: `kind`
  (throw|self), `projectile`, `distance`, `range`, `cooldown_ticks`, `left`, `healed`. It is an instant action that
  stops what the character was doing, as `shoot` does.
- Circuit network: `wire {from, to, color: "red"|"green"}` lays a circuit wire between two entities in reach (on a
  combinator, `from_side`/`to_side` pick input or output; default output to input); `disconnect: true` removes it.
  Without `color`, `wire` is the copper wire between poles. `circuit {position, ...}` sets what the entity's circuit
  GUI holds: `enable: {signal, comparator, value | signal2}` (the entity works only while the condition holds; `false`
  turns it off), `logistic: {...}` (the same, read from the logistic network; connects it), a constant combinator's
  `signals: [{signal, count}]` and `on`, an arithmetic combinator's `arithmetic: {first, operation, constant | second,
  output}`, a decider's `decider: {first, comparator, constant | second, output, copy_input}`. Signals are item, fluid
  or virtual signal names (`iron-plate`, `water`, `signal-A`). `read: {switch: true}` sets read switches: an inserter's
  `hand`, a belt's `contents`, a drill's `resources`, a train stop's `send_to_train`, `read_from_train`,
  `read_stopped_train`, `read_trains_count`, `set_trains_limit`. The reply reads back what the game holds. It leaves a
  running queue alone. `requests {position: requester chest, from_buffers: true}` sets its "request from buffer chests"
  switch.
- Trains: `train {position: stop, station, limit}` names a train stop and sets its train limit (`limit: false` clears it);
  `train {position: locomotive or wagon, schedule: [{station, wait: [{type, ticks?, compare?, condition?}]}], current,
  automatic}` sets the train's schedule (wait types as in the game: time, inactivity, full, empty, item_count,
  fluid_count, circuit, passenger_present, ...) and automatic or manual mode. Rails, stops, locomotives and wagons are
  built with `build` and `place_ghosts`; fuel goes in with `refuel` or `transfer`.
- `configure {position, recipe, quality}` sets a recipe at a quality (the machine and quality must be unlocked); a
  change of quality alone is a change.
- `flush {position, fluid?, index?, platform?}` is the fluid GUI's flush: it empties the fluid segment (the connected
  pipes, tanks, pumps and machine fluidboxes) the entity at `position` belongs to, every fluid or only `fluid`.
  An entity with several segments holding fluid (a chemical plant's input and output) needs `fluid` or `index`; the
  error lists them. Returns `flushed {fluid: amount}`, `amount`, `index` and `segment {id, extent, size, capacity,
  entities}`. It leaves the running action and queue alone, and the `pog-guest` group cannot flush.
- `move_to {position, combat: true}` (or `combat: RADIUS`, 1..32, default 20) fires at enemies in range while walking,
  as `shoot {auto: true}` does, until the walk ends (`last_combat.outcome: move_ended`, with `ammo_used`); it needs
  ammunition in the ammo slots. `shoot`, `move_to combat` and `kite` fill empty ammo slots from carried ammo first
  (strongest magazine kind first; a carried gun goes into an empty gun slot before it) and say so in `equipped`
  (`equipped from your inventory: 20 firearm-magazine to ammo slot 1`; for move_to under `combat`); when the slots run
  dry mid-fight they are refilled the same way and the fight goes on (`last_combat.reloads`, kite `last.reloads`); with
  nothing carried that fits a gun they fail as before. `kite {retreat: {x,y}}`: below `min_health` or out of ammunition, the character walks
  to the retreat point, still firing at units in reach while ammunition lasts, and ends `retreated` there. Every kite
  end says why in `last.why` (`health 36% fell below min_health 40%; retreating to (-20,0)`, `out of ammunition`, `no
  enemies left within the scan radius`, `time up`), with `ammo_left`, `enemies_left` and `retreated_from`.
- Output is compact tables meant for reading. Use `--format json` for programs.

### Output shape, chat and time left

```sh
fh say "taking copper"                         # or: fh say --text-file line.txt
fh say - <<'EOF'                               # text with apostrophes or quotes: always this form
I'll take copper, you've got iron
EOF
fh say "biters at the west wall" --aloud       # spoken on the stream
fh say "Sunward is loaded" --aloud --look platform:Sunward   # the stream camera may show it while it is read out
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
  compact the same way. Wait polls are `status {peek:true, brief:true}` (only `active`, `last`, `combat`, `last_combat`, `alive`,
  `connected`, `surface`, `platform`, `position` and `tick`, none of status's factory and threat scans; falling back to
  `status {peek:true}`, then plain status, on an older runtime), once a second (every 2 s after the first 10 s of a
  wait), or just after the action's own end tick when that comes sooner, so the
  team hints, the chat trailer and the turn clock are left for the reply you see; it reads one small `observe` after.
- `chat` is lossless: it returns your unread messages (or all after `since`), newest `limit` (default 30), plus every
  older one that mentions you (`mention: @|@everyone|name`, up to 100 more), oldest first, and marks only those
  read; `remaining: K` counts unread messages it did not return, and `digest` sums them up in one line (`35 older
  messages not shown (seq 1..37): sol 23, luna 12; chat again for them`). Your own messages count as read; writing
  does not skip others' unread ones. After a (non-peek, non-since) read that left some unread, every reply's `team`
  block carries `chat_remaining: K` (the current unread count) until it reaches 0.
- A line from a teammate who is now somewhere other than you says where: `team.tells` and `team.mentions` lines
  (`sol (on Vulcanus), 2m ago: ...`), the `chat:` trailer's `latest`, and `away: "on Vulcanus"` on `chat` and `tells`
  entries. Same planet: nothing is added.
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
- `highlights` (operator only, the same `operator: true` dispatch; the stream service sends it) draws what agents
  act on for the director camera clients only: `{"items":[{"position":{"x":30,"y":0},"extent":6,"surface":"nauvis",
  "agent":"sol","label":"Sol · placing ghosts"}],"ttl":360}`. Each item gets a ring in the agent's profile colour (or
  `color {r,g,b}`) sized to `extent`, its label above it, and a dashed line from the agent's character when the spot is
  8 or more tiles away on the same surface. Only connected camera players see them (with none connected nothing is
  drawn); each call replaces the last set, `{"clear":true}` removes it, and every object expires after `ttl` ticks
  (30..1800, default 360). At most 12 items; an unknown surface is skipped (`skipped`). Agents cannot call or see it.
  `bubbles: [{agent, text, ttl?}]` (up to 12, text cut to 120 characters) puts a speech bubble over an agent's
  character, following it, for the camera clients while the stream voices that line.
- The runtime also draws what agents are doing for the camera clients only (visuals.lua; nothing with no camera
  connected, nothing for an agent's player): while mining, an arc on the target filling over the hand-mining time
  (ore: the current cycle), the product's icon above it and the game's mining particles for that entity (2 every 20
  ticks); while hand crafting, the next 3 recipes above the head with their counts and the first one's progress; on a
  `move_to`, a faint dashed line along the planned route to the goal; items moved by hand (`transfer`, `collect`,
  `feed`, `rearm`, `refuel`), the flying text the agent's own client shows (`+50 [item=iron-plate]`) at the target in
  the agent's colour; and a 1 s ring on what a `build`, `construct`, `place_ghosts`, `paste`, `deconstruct`,
  `configure`, `rotate`, `repair`, `flush` or `revive_ghost` request names. Mining, crafting and routes refresh every
  10 or 30 ticks; rings and texts share 30 a second. Faults there are counted (`visual_errors` in storage), never fatal.
- `viewer_say` (operator only, the same `operator: true` dispatch) relays a stream viewer's chat line:
  `{"id":"...","operator":true,"action":"viewer_say","args":{"name":"bob","text":"..."}}`. It posts
  `viewer bob: text` in the game chat, in grey; agents read it from `chat` with `from: "viewer bob"` and `viewer: true`,
  unread for every agent. It files a `team` mention (shown once, and it ends a `sleep` with `woke: mentioned`) only for
  an agent it names with `@` (name, name without `pog-`, or display name; not `@everyone`, not a plain name). Rich
  text tags are stripped from the name and bracketed in the text, newlines flattened, the name cut to 24 and the text
  to 200 characters. Rate limit (game ticks, so it does not refill while the game is paused): one line per viewer name
  (case-blind) every 20 s and 6 lines a minute in all. Over it the reply is `posted: false, dropped:
  viewer_rate|global_rate, retry_after_s`, not an error; a viewer the agents muted gets `posted: false, dropped:
  muted, reason`. On success: `posted: true, seq, from, text`. The pog repo's `tools/audience.py` wraps both calls,
  and its stream service (`tools/stream/viewers.py`) relays moderated YouTube and site chat with it.

### Votes and human players

```sh
fh players [NAME] [--args '{"minutes":30}']    # humans on the map and what each did in the window (default 10 min)
fh vote kick|ban|trust NAME "reason"           # open a vote or add a yes; fh vote no kick NAME votes against
fh vote mute Troll42 "slurs in chat"           # a stream viewer; reason as words, or - with the reason on stdin
fh vote unmute Troll42 "apologised"
fh vote list                                   # (or fh votes) open and recent votes, muted viewers
fh restore NAME [--args '{"minutes":30}']      # cancel their pending orders; ghosts of what they removed
```

- A human is a LuaPlayer that is not a bot, a camera client (`pog-cam*`, `pog-director*`, spectators) or an attached
  agent. `players.lua` logs each human's builds, removals (`mined`, `robot` on their deconstruction order,
  `destroyed` by their character or vehicle; trees, rocks, ore and ghosts excluded), pending deconstruction and
  upgrade orders, and inventory moves of 50+ items with chests and vehicles (GUI open/close diff; ctrl-click paired
  with the same tick's main inventory change). Chat lines from `players`: joins, leaves, and bursts (20 removals or
  orders within 5 minutes, then quiet for 2 minutes per player and kind). A fault in the log is counted in
  `player_log_errors` and never quarantines the runtime.
- `control.lua` puts a player's first join (`on_player_created`) in the `pog-guest` permission group (planners,
  blueprints, cable cutting, settings paste, flushing, capsules, vehicles, trains, research, launches and admin
  actions denied); camera names and names in `storage.agent_harness.trusted_names` are exempt (operator
  `trust_names {names}` adds names before they ever join).
- `vote {kind: mute|unmute|kick|ban|trust, viewer|player, reason?, yes?}` (votes.lua, the one vote module; directors
  cannot vote): mute and unmute name a `viewer` (case-blind, with or without a leading `viewer `), kick, ban and trust a
  human `player` (trust: only a guest). The reason (cut to 200 characters) is required to open a vote; `yes: false`
  votes against an open one. Each ballot is decided when cast: yes from a majority of the active agents
  (`floor(active/2)+1`; active: a bot or attached agent whose own request, or `fh sleep` poll, is within 10 minutes;
  other peeks do not count, and the voter always does) carries it, no from a majority fails it; ballots of agents
  who went quiet stop counting. A vote is open 10 minutes (then `expired`, and it may open again at once); after one
  is decided, the same kind on the same name waits 5 minutes. Carried mute or unmute acts at once (`result:
  muted|unmuted`; a muted viewer stays muted for the rest of the run, in the save, and `viewer_say` refuses its
  lines); carried kick, ban or trust waits as `carried` for the operator. The reply: `id, kind, viewer|player,
  reason, voters, yes, no, votes, needed, active, outcome, result?, closes_in_s`. A failed vote never stops the
  character.
- Every ballot and result is a notice from `vote` in the game chat (`astra votes to mute viewer Troll42 (1 of 2
  needed): slurs in chat`; `viewer Troll42 is muted for the rest of the run (2 of 3 active agents: astra, sol)`;
  `#2 trust nick carried (3 of 4 active agents: grok, luna, sol); the operator carries it out`): unread for everyone,
  `notice: true` in `chat`, never a mention. The stream shows notices on its ticker.
- `votes` (agents, and the operator dispatch) returns `open`, `closed` (the 10 most recent), `muted [{viewer, tick,
  reason, by}]` and `active`. Operator: `votes_pending` (carried kick, ban and trust votes not yet carried out:
  `id, kind, player, reason, opened_by, decided_tick, yes`), then `vote_close {id, outcome: done|cancelled, note?}`
  (a notice). `player_group {name, group: trusted|guest}` moves a player (trusted: the Default group, and the name is
  remembered for later first joins). `players` also answers as an operator read. The pog repo's `tools/players.py`
  is the operator side, and `tools/stream/viewers.py` reads `muted`.
- `restore {player, minutes?}` (default 30): cancels the player's pending orders and places `entity-ghost`s (same
  name, direction, quality, recipe, underground type; `expires = false`) where they removed something in the window
  and a manual ghost fits; counts `cancelled`, `ghosts`, `already` (rebuilt or ghosted), `blocked`. No items are
  created; each removal is restored once.

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
- A direct call that moves or acts as the character pauses the queue. Reads, the board, chat, `say`, `tell`, `confess`, `operator`, `craft`/`cancel_craft`, research, votes, `sleep` and the queue calls don't, and when one of them fails (a `placements` out of sight, a `board_update` with an unknown argument) the running action and the queue go on as well. `sleep` leaves the queue running, and so does its end.
- A harness update (a hot runtime install, or a restart with a changed mod) keeps a running queue going: a `wait_until` or `wait_ticks` step keeps its own clock, and a step toward a goal (`move_to`, `construct`, `build_path`, `mine`, `repair`, `kite`, `rearm`, `refuel`, `collect`) starts again. Any other step that was running is interrupted and leaves the queue paused (`fh queue resume` continues with the next step). A direct action is interrupted. Each agent whose work was cut gets `team.harness_updated` lines in its next reply.

## Waiting

```sh
fh call wait_until --args '{"until":"item_count","item":"iron-plate","at_least":200}' --wait --wait-timeout 600000
fh call wait_ticks --args '{"ticks":1800}' --wait     # stand idle 30 s
fh sleep 300                                          # wait up to 5 minutes; action and queue keep going
fh sleep 600 --until "item_count iron-plate>=400 at 12,-8 13,-8"   # ...or until the chests hold 400
fh sleep 900 --until researched                       # ...or until the research running now is done
```

- `wait_until --wait` takes its timeout from `--wait-timeout MS` (up to 900000, 15 minutes) unless `args.timeout` (ticks, up to 54000) is given; without either it is 3600 ticks. The condition is checked every 10 ticks. Not met in time: exit 1, `error.code` `timed_out`, with the condition and what it last saw.
- `wait_ticks {ticks: 1..54000}` holds the character idle (outcome `duration_elapsed`); like any character action it replaces the current one and pauses a running queue.
- `fh sleep SECONDS [--until COND]` (1..900) touches nothing: the current action and queue keep running and the game runs (in `turns` clock mode it advances up to 600 s). The reply's first field, `while_asleep`, says what goes on meanwhile: `your queue keeps running (move_to running, 3 steps pending); ...`, `your walk keeps going until tick N, then your character stands idle`, or `no queue and no action: your character stands idle for up to N s` (with `your queue is paused with N steps pending` when it is). It returns early when your character takes damage (`woke: damaged`, with `health` and `lost`), dies (`died`, exit 1), a chat message mentions you (`mentioned`, with the message; it is also delivered in the reply's `team.mentions`), a teammate tells you something (`told`, with `tell`; delivered in `team.tells`), someone else assigns or changes a board item of yours (`board`, with the line; delivered in `team.board`), the queue that was running when the sleep began finishes (`queue_done`) or stalls (`queue_stalled`, with `queue`: a failed step or a guard that paused it, or a walking step that has not moved the character for 30 s; a repeating plan does not end a sleep between cycles), or the `--until` condition holds (`condition`, with `saw`); else `woke: elapsed`. Wakes with a running queue report `queue_steps`, the steps it finished during the sleep. A dead bot may sleep too: its reply says `dead: true` and `respawns_at_tick`, and it wakes with `respawned` when the new character appears. It polls a read-only `sleep_check` once a second; if the game advanced less than SECONDS in 1.25 x SECONDS + 10 s of real time (paused server), it exits 1 with `timed_out`.
  - `--until`: `researched` (the research running now) or `researched TECH`, `crafting_done`, `item_count ITEM>=N` or `ITEM<N` (the character's inventory), `item_count ITEM>=N at X,Y X,Y ...` (summed over our entities on those tiles, every inventory: chests, machines; up to 64), any other `wait_until` condition as `NAME key=value ...` (`ammo_below count=5 radius=20`), or the condition as JSON. A condition met already ends the sleep on its first check (`already_met: true` in the sleep reply). The action is `sleep {seconds, condition}`; `item_count` takes the same `positions` in `wait_until` and queue steps.
  - With a deadline file (`--deadline-file`, `FH_DEADLINE_FILE`) a sleep never runs past it: it is cut to the time left and reports `woke: deadline` when it ends there; after the deadline it does not start (`woke: deadline`, `slept_s: 0`).
  - A sleep started within 10 game seconds of reading a wake on an event (anything but `elapsed`, `died`, `respawned`, `deadline`) does not start: it returns at once with that wake, `repeat: true` and `while_asleep: this sleep did not start: you woke (mentioned) 4 s ago; ...`, so a shell loop of sleeps ends on the first wake. At most 3 repeats per wake; none for a sleep given `--until`, none in `turns` mode.
  - `fh call sleep --args '{"seconds":N}'` (with or without `--wait`, also in `fh run` and `fh stream`) is the same blocking wait; the raw action only starts a sleep.
  - Claude Code agents get a 20-minute Bash timeout (tools/clean-profile.py in the pog repo), above the longest sleep. Codex agents' `yield_time_ms` returns earlier and leaves the sleep running in the background.
- A `build`, `transfer`, `rearm` or `refuel` short of an item that the hand-craft queue is making waits for the craft (`awaiting_craft`, outcome `fed` once it acted, or `failed`), so `craft` followed by `build --wait` works.

## Messages and reads

- `inspect` is a read: any entity in sight (32 tiles, visible chunk) works without reach, like `scan`; `in_reach` says whether acting on it would reach.
- `inspect` also shows what the entity GUI and cursor show: `status_name` (e.g. `marked_for_deconstruction`,
  `waiting_for_source_items`), `filters`, `filter_mode` and `use_filters` (inserters, loaders), `held` (an inserter's
  hand), `pickup_target` and `drop_target`, `marked_for_deconstruction` / `marked_for_upgrade`, and `ghosts_here` (ghosts
  on the footprint, such as a paste replacing it, with their filters). A ghost on a building yields to the building
  unless you name it (`name: "entity-ghost"`).
- An asteroid collector: `inspect` shows `filters` (asteroid chunk names), `filter_slots` (the game's count, which
  reads 0 until a filter is set), `arm` (chunks its arms hold) and its output in
  `inventories.asteroid_collector_output`. `configure {position, filters}` sets the chunk filters as its GUI does,
  in slots 1 onward, on a new collector too: names from `prototypes.asteroid_chunk` (`metallic-asteroid-chunk`,
  `carbonic-asteroid-chunk`, `oxide-asteroid-chunk`); `[]` clears them. A slot the game refuses fails the call with
  what the game said, and the slots set before it are put back. The reply reads the filters back (`not_set` lists a
  name that did not stick). The game has no
  whitelist/blacklist mode for collectors, so `filter_mode` is refused there. With `platform` it works through remote
  view like the other configure paths.
- `inspect {platform, position}` and `configure {platform, position, ...}` act on your own space platform by name
  (platform coordinates, hub at 0,0; the whole platform is in sight; configure works through remote view, so a recipe
  change needs an empty, idle machine). There `inspect` adds `construction_blocked` when the entity is marked or has a
  ghost on it, and on the hub `hub_slots` (`0 of 65 free`). `platforms` shows `hub_slots` per platform, and with
  `platform` set, `construction_blocked`: `hub full: 0 of 65 slots free; 1 marked for deconstruction wait for room
  (removed entities and their contents go to the hub)`, `ghosts wait for items the hub lacks: inserter (ghosts need 1, hub has 0)`.
  Items count at the ghost's quality. Tile ghosts the game's foundation rules hold back get one line each: a tile
  that would enclose empty space no ghost covers (`tile ghost (-7.5,8.5) space-platform-foundation: building it would
  enclose 6 empty tiles with no ghost: (-6.5,8.5), ...`), one with no foundation or tile ghost beside it, one more than
  200 tiles north of the hub, one in the 82 tiles south of a thruster. `inspect` on a tile ghost shows the same.
- The game repairs a platform's entities itself, one entity at a time, with repair packs from the hub; `repair` refuses
  platform targets (`platform`, or standing on a platform) with that reason. `platforms` and `inspect` of the
  hub show `repair_packs` (in the hub, or `none`) and `damaged` (`gun-turret (-6,0) 53/400`, most damaged first, 3 per
  row in `platforms`, up to 10 with `platform` set and in `inspect`; `damaged_count` past that); `inspect` of a damaged
  entity there adds the `repair` note.
- `platforms` shows each platform's `defense`: `hub_health` (`637/1000`), `turrets` (`5 gun-turrets: 4 empty, 0 low
  (under 10 rounds)`) and `ammo`, the ammo flow (`turrets hold 6 rounds, the hub firearm-magazine 920`).
- `platform_schedule {platform, paused: true}` says what pausing does: on a route (`note: paused on the route: the
  platform stays among the route's asteroids and drifts back the way it came ...; it reaches no orbit until
  unpaused`), in orbit (`paused in orbit: the platform stays where it is, among that orbit's asteroids`).
- `gamedata/locations.json` lists each route's and each orbit's `asteroid_spawn_definitions` as the game gives them,
  and `gamedata/entities.json` the asteroids (`max_health`, `resistances`), from the next prototype dump of a Space Age
  world (`tools/analyst/dump_prototypes.py`).
- Where a platform's items go: `platforms` shows `hub_trash` per platform, and with `platform` set
  `hub_inserters_without_target` (inserters taking from the hub with nothing to drop into: `(-2.5,3.5) drops onto
  empty-space`), `thrown_overboard` (items in flight off the platform, while the game tracks them), and
  `consumed_10min` / `produced_10min` from the game's item statistics for the platform surface. `inspect` on an
  inserter with no drop target shows `drop_tile` (and `drop_note` when it is empty space: thrown overboard).
- A `drop` whose pod destination the game refuses returns the items to the hub; what the hub cannot take back stays in
  the cargo pod on the hub, and the error says which.
- A `drop` returns its number (`drop: N`). Its pod is followed down, because pods land after the call returns and often
  10-20 tiles from the spot they were aimed at (shift06 14:55: aimed near (14,134), landed at (0,129)). The sender,
  and the teammates named in `to` (a name or a list), hear about it in their team block, at most 4 drop lines per
  reply:
  - while it is still descending: `drop #3 from Sunward to vulcanus: still descending (12s ago, aimed near
    (14,134))`;
  - once it has landed: `drop #3 landed at (0,129) on vulcanus: cargo-pod-container with processing-unit*50
    roboport*3 (take them with transfer; it vanishes when empty)`, or `landed in the landing pad at (x,y)`;
  - if no container is found within 24 tiles of where the pod was last seen, 10 s after it went: that, and what it
    held.

  An unknown `to` name fails before anything leaves the hub. The `drops {limit?}` read (aboard too) lists the last 20
  drops newest first: `{id, by, to, platform, surface, items, ago, state, aimed_near, at, landed_in, container
  {name, position, holds} or {gone}, note}`.
- `transfer {position, direction: "to_player"}` takes items from a character corpse (inventory `character_corpse`); an emptied corpse is removed. It never mines the corpse (mining a corpse as a bot crashes the server; the harness takes the items instead).
- Trash slots: a rocket silo, cargo landing pad and platform hub have one (`rocket_silo_trash`, `cargo_landing_pad_trash`,
  `hub_trash`) where the game puts items the entity will not use. `inspect` lists them in `inventories` and as one line
  (`trash: "40 space-platform-foundation, 7 solar-panel (in rocket_silo_trash, ...)"`); `platforms` shows a silo's `trash`.
  `transfer {position, direction: "to_player"}` takes from non-empty trash slots first (all, or `item`), or name
  `inventory: "rocket_silo_trash"`; they are take-only.
- `launch {position, auto_requests: true}` on a silo whose rocket holds cargo loaded by hand: the game moves that cargo
  into the silo's trash slots, where it never launches. The reply has `cargo_to_trash` (what was aboard), `trash` and a
  `note` with the transfer that takes it back.
- `launch {position, platform}` sends the cargo to the platform's hub (a platform waiting for its starter pack gets it
  as its starter pack). A rocket lifts 1000 kg (item prototype weights; the game takes more by script, then refuses
  the launch): `transfer` into `rocket_silo_rocket` gives only what fits (`weight_limited {requested, fits, note}`)
  and fails when nothing fits; its reply, `inspect` of a silo and the `platforms` silo rows show `rocket_weight` /
  `weight` as `held/lift kg`. `launch` with more aboard fails before the game is asked: `overweight by N kg`, with the
  cargo by weight. When the game refuses (it gives no reason), the error lists what it may check: a missing rocket,
  automatic requests, a paused platform, then the silo, cargo, platform and destination it saw.
- `inspect` of an entity with module slots shows `modules {inventory_index, slots, contents}`. A blueprint entity's
  module request names that index: `items: [{id: {name: "speed-module"}, items: {in_inventory: [{inventory: 4,
  stack: 0}, {inventory: 4, stack: 1}]}}]` (stacks count from 0 in blueprint strings). In 2.0 the index is 4 for assemblers, furnaces,
  chemical plants, crushers and silos, 1 for beacons, 2 for mining drills, 3 for labs.
- A refused placement names what is in the footprint; another player's or bot's character is named (`placement blocked by sol's character standing at (3.0,4.5) (ask them to move, or build elsewhere)`).
  An entity with tile buildability rules (an asteroid collector: its rear rows on foundation, its front row and the
  tiles ahead of it empty space) names the rule its spot breaks: `placement blocked: breaks its tile rule 2 facing
  north: tiles x 59..61, y -4..-1 need empty_space and must not be ground_tile; 6 of 12 do not
  (space-platform-foundation at (59,-2))`. `place_ghosts` failures carry `{index, name, position, error}`.
- A `paste` (`blueprint_place`) that creates fewer ghosts than the blueprint holds explains each blueprint entity
  that is not there. It finds the shift the game used from what stands where the layout puts things. It returns:
  - `not_placed` (the first 20, plus `not_placed_count`), each `{name, position, direction, reason}`, where the reason
    is outside the charted area, a broken tile rule, what blocks the footprint, or "placeable here now: the paste
    skipped it";
  - `existing_entities` / `existing_ghosts`, counting only those at the blueprint's own spots;
  - `settings_differ` (`settings_differ_count`), for entities and ghosts already there whose recipe, filters or
    modules differ from the blueprint, each `{name, position, ghost?, differs, fix}`, where `fix` is the `configure`
    call that sets them (modules: `transfer`);
  - `reason`, a one-line summary.
  A paste never changes what was already there.
- A refused `build` of an offshore pump (any reason) lists up to 3 valid placements within 12 tiles, nearest first, with
  their directions, from the game's own manual build check (`nearest valid offshore-pump placements (game build check,
  within 12 tiles): (10,-0.5) east, ...`). A build refused by water under the footprint (a boiler, a steam engine) lists
  up to 3 positions within 6 tiles where it fits facing the asked direction. `placements {name, position, radius,
  direction}` (read) returns the same list without building: `placements [{position, direction}]`, `checked`.
- A refused turret build (gun, laser, flamethrower or artillery turret) lists up to 3 spots within your build reach
  where the game's manual build check accepts it: when blocked, the nearest to the asked position within 6 tiles of
  it (`; nearest spots where gun-turret fits within your build reach (game build check): (5,-2), (5,2), (4,-2)`); when
  out of reach, the ones nearest the asked position around the edge of your reach toward it, followed by `; or walk
  closer (move_to) and build again`. `build` does not walk.
- `fh call defense` (read; `limit` areas, default 16, max 40; cached 10 s for the whole force): `areas`, the force's
  buildings in clusters, largest first. A cluster is buildings touching by 32-tile cells; belts, pipes, poles, walls,
  rails and turrets link cells of a cluster but never join two clusters, so an outpost is its own area and the belts
  or pipes between clusters form a `line` area; a cluster wider or taller than 128 tiles is split into 128-tile
  `block`s. Each area has `kind` (`cluster`, `block` or `line`), `from_centre` and `bearing` from the base centre (the
  spawn point) and a `line` (`area 1 (cluster, 27 tiles E of base centre) around (27,3) (0,0)-(60,6): 74 buildings
  (...); turrets in range: 2 gun (23 ammo, 1 low), 2 flamethrower (oil 13%, 1 dry); 43 buildings covered (2 by one
  turret only), 31 not; largest uncovered part (30,3)-(60,3): 31 buildings (31 transport-belt); nests: (105,2) 45
  tiles E polluted`), the turrets in range (`turret_list`, lowest ammo first), `ammo` (gun rounds), `flamers` (`count`,
  `oil`, `capacity`, `dry`, `low` under 25%), `lasers`, `uncovered_parts`, and `nests`, up to 3 nests whose nearest
  building is in the area. A building is covered when its centre is within range of a gun, laser or flamethrower
  turret. `areas_without_turrets` lists area numbers; `nests`: charted spawner groups within 256 tiles of a building,
  nearest first (`nest (105,2) 2 spawners, 1 worm: 45 tiles E of transport-belt at (60,3) (area 1); pollution reaches
  it`, or `reaches it (last there 5m ago)`); pollution reaches a nest while one of its chunks had pollution in the last
  15 game minutes, the same memory `status` enemies and the reached-nest news use (one reading at the cloud's edge
  flickers); `artillery`; `more` sums areas past the limit.
- `fh call flamers` (read; `limit`, default 12, max 40; cached 10 s): each flamethrower turret on your surface, the
  most at risk first: `flamethrower-turret (0,0) facing S, oil 75% (150/200): 4 of our burnable buildings in its arc
  within 33 tiles: 3 pipe, 1 gun-turret (nearest pipe (0,10), 10 tiles)`. The arc is the direction the turret was
  built facing, plus or minus its turn range (60 degrees for the vanilla flamer), from its minimum range to its range
  plus 3 tiles for burning ground; buildings with full fire resistance (walls) are left out. Also `count`, `dry`,
  `low`, `with_buildings_in_arc`. `status` warns of dry and low flamers: `flamer oil: flamethrower-turret 1/11 dry at
  (80,90), 2 below 25% at (84,90) 12%, ...; fh call flamers shows each one and what is in its arc`.
- `collect` with `radius` skips stock inside another agent's active board claim and reports `skipped_claims` (`40 iron-plate in 2 places of #4 iron smelting (claim by sol); ask the owner`). `collect` on named positions still takes, and lists the claimed ones in `claimed`.
- The `status` power warning appears only when some electric machine lacks power: `power: 3 of 78 machines low_power; 1 unconnected (fh call power lists them)` (`no_power` = connected to a network with no generation; `unconnected` = no pole reaches it).
- `fh research` (`research` with no arguments; read): `current`, `progress`, `queue`, `pending`, and `entries`, one per
  queued technology then each pending one: `name`, `progress` (%; saved progress for one not running), `queued_by` (the
  agent whose `research` or `research_next` queued it, or the player who queued it in the game; absent when the queue
  had it before the harness kept track), `packs`, `done_in` (time until it finishes, counting the entries ahead of it,
  at the lab throughput measured from the running research's progress over the last 5 minutes, sampled every 10 s),
  `waits_for` (a pack the running research does not use and nobody made in the last 10 minutes; the clock stops there,
  `clock_stops_at`), `waiting` for pending ones; and `throughput` (`measured over the last <time>`, or not measured
  yet). `fh research done` (`research_done {limit?}`): technologies your force finished lately, newest first, with
  `ago`, `unlocks` and `queued_by`. `unlocks` names recipes, `travel to PLACE`, `QUALITY quality`, given items, and
  bonuses as `modifier-type +10%` (fractions) or `+N`.
- Editing the queue as the research GUI does: `research {remove: NAME}` (or an array; `cancel` is the same) takes it
  out, with queued technologies that need it (`also_removed`); progress stays with the technology. `research {move:
  NAME, to: N}` puts it at position N (1 is researched now); a move ahead of a queued prerequisite or behind a queued
  technology that needs it is refused with the position that works. Names waiting beyond the engine queue count.
- `research_options` (read): the open technologies (prerequisites done, not trigger technologies) whose every pack the
  factory made in the last 10 minutes, `researchable_now` `{name, units, packs, queued}` fewest units first; the rest in
  `waiting_for_packs`, grouped by `packs_not_made`; and `made_last_10_min` per pack. Labs or chests may still hold
  packs of a group that waits.
- `where_is {item, limit?, surface?}` (read): where an item is on your surface (or `surface`): `total`, `by_kind`
  (chest, lab, machine, vehicle, pad, hub, roboport, belts, inserter_hands, characters) and `places` (each chest, lab,
  machine, vehicle, pad, hub and teammate holding it, `{kind, entity or agent, position, count, distance}`, nearest
  first, `limit` default 15, `more` past it). Belts and inserter hands are totals only. It scans the surface's
  storage and belt entities once per call.
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

- `configure`, `flush`, `requests` and `launch` in visible chunks
- ghosts and deconstruction marks in charted chunks (on your own space platform with `platform`, anywhere on it)
- `deconstruct {area, tiles}` marks tiles as a planner in tile mode does: `tiles: true` takes every minable tile in the
  area, or name them (`["space-platform-foundation"]`). The game decides each tile; the reply counts `tiles_marked`,
  `tiles_already`, `tiles_refused` (`refused: {under_entity, engine, not_minable, error}`) and `tiles_blocked` (marked
  tiles under an entity that is not marked: robots take a tile once what stands on it is gone). With `tiles`, entities
  are marked only when `entity_names` or `entity_types` name them. `cancel_deconstruction {area, tiles}` clears tile
  marks (`tiles_cancelled`).
- `deconstruct {area, items_on_ground: true}` marks every item stack on the ground in the area, as a planner over
  items on the ground does; construction robots carry marked stacks to storage chests. Other entities are marked
  only when `entity_names` or `entity_types` name them. The reply counts `item_stacks` (marked now) and
  `item_stacks_already`, lists `items` (`{name, count, stacks}`), and says which robots can reach them:
  `robot_networks` and `storage_chests` (logistic networks whose construction area covers a marked stack) and
  `outside_construction_area` (stacks no roboport covers). `cancel_deconstruction {area, items_on_ground: true}`
  unmarks them.

- Vehicles: `vehicle {position, enter: true}` gets in (the driver's seat if free, else a car's or spidertron's
  passenger seat; a locomotive or wagon, whose train runs its schedule as usual), within 10 tiles; `vehicle {exit:
  true}` gets out; `vehicle {drive: {x,y}}` drives the car or tank you drive there (a timed action steering as a
  player's keys do: outcomes `arrived`, `blocked` after 3 s without progress, `timed_out`; `--wait` waits for it);
  `vehicle {position, go_to: {x,y}}` sends a spidertron walking by itself (from outside, or the one you ride; one
  with an empty fuel slot does not walk, and the reply says so: fuel goes in with `transfer`);
  `vehicle {}` says where you sit. Seated, reads, chat, crafting, research, ghosts and other remote-view actions
  work; anything that moves or uses the body (walking, mining, building by hand, transfers) is refused with a pointer
  to `vehicle {exit: true}`.

Items on the ground:

- `scan` and `observe` list items on the ground as `ground_items` (`{stacks, items: [{name, count, stacks, box}],
  more_items}`), by item, instead of one row per stack; rows for them come only when the call filters for them
  (`type: "item-entity"` or `name: "item-on-ground"`; observe `entity_types`/`entity_names`).
- `status` `alerts.ground_items`: a cargo landing pad that is full while item stacks lie within 40 tiles of it
  (position, slots, stacks, the items), and piles of 100 or more stacks in a 64-tile cell that holds our buildings
  (box, stacks, items; the largest 3). Item counts come from up to 5000 stacks per place (the line says so when
  there are more). One pass per force every 30 s, run on demand; a place new to you, or grown by half since you
  were told, is also in the reply's `team.alerts` once.
- `pickup {area}` (up to 64x64) or `pickup {position, radius}` (radius 1..32, default 8 around you), optionally
  `items` (1..16 names): a timed action (`ticks` 1..36000, default 3600) that picks up every matching stack in the
  area, one stack every 6 ticks, walking to the nearest one left when none is in pickup reach. Refused when the
  area holds none. Outcomes `picked_up` (none left), `inventory_full`, `blocked` (stacks it could not walk to,
  `last.skipped`; it stops after 8), `timed_out`; `last.picked {item: count}` and `last.left` (stacks still in the
  area). `pickup {}` still takes only what is in reach where you stand.

Not supported yet: elevated rails and rail ramps, the selector combinator, and fluid transfers by hand. See docs/HARNESS-COVERAGE.md in the pog
repo for the feature-by-feature list.

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
- Where the time goes (operator): `/silent-command rcon.print(remote.call("agent_harness","profile_ticks",{seconds=60}))` (1..600 s; `{stop=true}` ends a run early) times every dispatch by action (`observe/sleep_check` with its scope; operator relays marked `(operator)`), the encoding of each reply (`encode <action>`, timed once more beside control.lua's own), every forwarded event by name, the harness tick and parts of the reply and tick (`part board.team`, `part threat.on_damaged`, ...; inside their dispatch or tick). The server log gets `agent-harness profile second tick=T n=N key=K time=...` per key per game second (`key=*` is all harness work in that second, parts excluded), then `profile total` per key and `profile done`. A LuaProfiler reading cannot be compared in Lua, so rank them offline: `python3 tools/profile_log.py factorio-current.log` prints the worst keys (count, total, average, worst second) and the busiest game seconds. Runtime-only; nothing runs while no profile is on.
- Status cost: the factory survey (machines, belts, science, plates, fuel/power/ammo/lab warnings), the fluid check, the pollution read and the chart walk are kept per force and surface and shared by every agent there (survey, fluid and pollution every 10 s, the chart every minute; `factory_as_of`/`threats_as_of` give the tick when older). The enemy bases around an agent stay its own (every 10 s). fh's wait polls use `status {brief: true}`; `status {brief: true, alerts: true}` adds the `alerts` block (losses, attacked areas, groups, enemy news), read from what the game reported without a scan (the stream overlay reads this).

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
fh board plan                                               # the team plan (board_plan): goals and who is on what
fh board plan goals "robots by hour 3; oil next"            # replace the goals ("" clears them)
fh board plan doing "oil: pumpjacks at the north field"     # your own line ("" removes it)
fh board plan for luna "scouting south"                     # another agent's line; shown as "(set by you)"
fh plan save iron-tour --file tour.json; fh plan run iron-tour; fh plan list
```

- Items: `task`, `request`, `claim` (needs `area`; owner is the poster), `note`; `harness` items come from
  `harness_request`. Status `open|claimed|doing|done|blocked|dropped`; naming an owner makes an open item `claimed`.
- `owner` takes an agent name, display name or player name without `pog-`, any case; an unknown name fails with the
  roster. Anyone may take an open unowned item or add a note; only the owner or requester changes status, reassigns or
  releases (`owner: ""`). Titles are cut at 120 bytes and notes at 200 instead of failing; the last 10 notes are kept.
- `board` returns `plan` (below), `items` (list rows carry the last 2 notes and `note_count`; `id` gives one item in
  full), `matched` and `open_unowned`. `status:"active"` means open, claimed, doing or blocked.
- The team plan: one item of kind `plan`, edited with `board_plan {goals?, doing?, agent?}`: `goals` (up to 600
  characters) replaces the goals, `doing` (up to 160) sets one agent's line, yours unless `agent` names another; `""`
  clears either. Anyone edits any part. With no arguments it reads. Replies and `board` reads give `plan {id, goals,
  doing: ["name: text (set by NAME)"], edited: "by NAME, <age> ago"}`; `board {mine:true}` and other kinds leave it
  out, and it is never a row in `items`. It is never pruned; `board_post` refuses `kind:"plan"`, `board_update` takes
  notes on it but no status or owner. Each edit is a board event (`kind:"plan"`, `change:"edited"`, `text` what
  changed, `owner` the agent whose line changed) and a `board` hint line for every other agent (`team plan edited by
  NAME: ...`); a line written for you counts as yours (it wakes you from `sleep`), other edits as news.
- A claim overlapping another agent's active claim is posted with a warning. At most 300 items are kept (finished
  ones pruned first, then notes, then the oldest).
- A claim whose owner is now somewhere other than you says so: `owner_away: "on Vulcanus"` on board items, the overlap
  warning (`overlaps claim #128 by sol (on Vulcanus): ...`), and the claim in `collect`'s `skipped_claims` and
  `claimed` (`(claim by sol, on Vulcanus)`).
- `board_events {since_seq, limit}` (for overlays) returns `{seq,tick,by,id,change,title,kind,owner,requested_by,status,text}`
  oldest first and a `cursor`. `change`: `posted`, `taken`, `assigned`, `released`, a status name, `note`, or `edited`
  (the plan). A finished technology is an event with no item: `by:"research"`, `kind:"research"`, `title` the
  technology, `change:"done"`, `text` `unlocks: ...`; it gives nobody a `board` hint line (the `research` lines do that).
  `board` and `board_events` work for any player, including directors without a character.
- Board actions never stop the character when they fail (like `say`), and work while a bot is dead.
- Every reply carries a `team` block when something is new for that agent since its previous request, shown once.
  `mentions` comes first: every chat message that mentions you and that you have not seen, oldest first, in full and
  never cut by the other parts' caps (`from @you|@everyone, <age> ago: text`). Then `tells` (below; `from[ to team],
  <age> ago: text`), then `board` (at most 5 lines and `+N more`, by someone else: items assigned to you with their
  first note, any change or note on an item you own or requested, an item reassigned or released away from you
  (`(was yours)`), a claim posted over yours; after those, each new open unowned task or request once; and a nudge
  when another open unowned request passes 2 game minutes), `research` (each technology your force finished since your
  previous reply, once: `research done: NAME, unlocks: a, b, c (<age> ago)`; a first reply looks back 10 game
  minutes; at most 4 lines and `+N more finished: research_done`; first, to every agent once, `research stalled: NAME
  heads the queue and has waited <time> for PACK, which nobody made in the last 10 minutes, with no progress ...` when
  the head of the queue has waited 10 minutes that way, at most once per 30 minutes), `alerts` (your character being hit; attacks, one
  line per incident (a 32-tile cell of one surface, ended by a quiet minute; on another surface than yours the line
  says so: `attack #ID on vulcanus at (x,y): ...`, and `status` alert rows carry `surface`): `attack #ID at (x,y): <attackers>; likely from nest (x,y)
  N tiles DIR; <entities hit> hit N times, D damage, first <age> ago, last <age> ago`, where attackers are a visible
  group that gathered in the last 3 minutes heading there (`a group of 25 (20 small-biter, 5 medium-biter) that
  gathered at (x,y)`) or the distinct units seen hitting (`12 attackers seen (...)`), and the nest is the nearest
  spawner on a charted chunk within 384 tiles of the attacked point (`from nest` when the game names the unit's own
  spawner; `no charted nest within 384 tiles`); an incident you were told about comes again as `attack #ID ... continues`
  with its totals only when it had new hits and at least 2 game minutes passed; `pollution reached nest (x,y), N
  spawners: N tiles DIR of base centre (spawn x,y), N tiles DIR of our nearest building`, once per nest per shift
  (a new shift hears again of nests still reached); enemy groups gathering; buildings destroyed, one numbered incident
  per raid (losses on one surface within 32 tiles of each other, up to 192 tiles across): `losses #7 in (x,y)-(x,y)
  12 destroyed: 8 transport-belt, 4 inserter by 20 medium-biter, 1s ago`, told once, then its running total at most
  once a game minute while it grows (`losses #7 in ... continue: 40 destroyed (+28 since you were told): ...`);
  `on vulcanus` or `on platform Starling` when not on your surface; with what destroyed them: enemy kinds first, then
  our own force's entities with where they stand as `friendly fire: 2 flamethrower-turret at (80,90)` (`unknown
  source` when the cause is gone and the killing force is ours); at most 8 lines; these replace the old top-level `losses` field; full landing pads spilling and piles of items on the ground
  near our buildings, once each and again when grown by half; then up to 6 platform lines, below) and `reminders`
  (profile, once a game minute until display_name, glyph and color are set). Directors get none; `peek: true` on any
  request leaves the hints for later.
- Game alerts and warnings in `team.alerts` (pushalerts.lua): what a player's alert panel and entity status icons
  show, without pulling a full status.
  - Entity statuses on planet surfaces: `no power`, `not connected to power` (no pole reaches them), `low power`,
    `out of fuel`, gun turrets `out of ammo`, flamethrower turrets `out of flamer oil`.
  - The game's alerts, read from an agent player's alert panel: `no_material_for_construction`,
    `not_enough_construction_robots`, `not_enough_repair_packs`, `no_storage`, `train_out_of_fuel`,
    `unclaimed_cargo`, `collector_path_blocked`, ... Attacks, losses and the game's own turret alert are told
    elsewhere and are left out.

  Each line is a group of one kind in one area, where 64-tile cells that touch make one area, with a hint:
  `8 assembling-machine-2 no power near (125,40); fh call power`, `12 gun-turret out of ammo near (67,-170)
  (was 9); rearm`, `2 (1 entity-ghost, 1 transport-belt) ghosts waiting for materials (no robot can bring them)
  near (-41,11)`. A group goes to whoever's active board claim covers its centre, else the agents who built there
  (`last_user`), else the nearest agent on that surface.

  At most one digest every 150 s per agent, with up to 5 lines (`+N more alert groups: fh call game_alerts`). Only
  groups that are new, or larger than when you were last told, are shown. A group that clears and comes back is new
  again. The scan is shared and at most 30 s old. `game_alerts {surface?, kind?}` (read) lists every group now,
  worst first: `{kind, surface, count, center, names, at, line, to}`, where `to` says who hears it and why
  (claim, built, nearest).
- Platform alerts in `team.alerts`, for the agent who created a platform (`platform_create`), the 3 agents whose
  requests named it with `platform=` most recently (within 2 hours; the `platforms` read does not count) and anyone
  aboard; a platform with none of them known goes to every agent. Each line names the platform and its surface:
  `platform Starling (surface platform-1) hit 3 times, 380 damage, last 1s ago: gun-turret 300, space-platform-hub 80;
  by medium-metallic-asteroid 3` (hits on our entities there since you were last told, your first look covering the
  last 10 minutes; at most once a game minute), `...: hits per minute rising, 30 in the last minute, 2 a minute over
  the 5 before` (10 or more and at least twice the earlier rate plus 5), `...: 1 of 2 gun-turrets empty, 1 low (under
  10 rounds); turrets hold 4 rounds, the hub firearm-magazine 920` (the ammo flow: rounds loaded in the turrets
  against the ammo waiting in the hub), `...: no repair packs in the hub (...)` (while it was hit in the last 10
  minutes or the hub is damaged), `... hub health 900/1000, down 100 in 40s`. A condition that lasts comes again after
  5 game minutes, sooner when it gets worse. Hits on a platform are no longer `attack #` incidents; `status` alerts
  carry them as `platform_hits` rows `{platform, surface, hits, damage, entities, by, last_tick}`. Turrets and the hub
  are read at most every 10 s per platform.
- `status` alerts for programs (the stream's loss banners and cuts): `latest` keeps one text line per loss incident
  (`#7 on vulcanus in (-223,74)-(-214,79) 59 destroyed: 59 gun-turret by 59 small-demolisher, 3s ago`; a surface other
  than the reader's is named, and with no reader any surface but nauvis), and `incidents` carries the same incidents as
  rows: `{id, surface, platform, box {x0, y0, x1, y1}, total, names, by, first_tick, last_tick, line}`, newest first,
  at most 8. Read the surface from the row, never from the text.
- `shift`: on a resumed world, the operator's `shift_start` (tools/start-team.sh) begins a numbered shift, and each
  agent's first reply of it (any action, not a peek) carries `team.shift` once: `shift` (`shift N, started <age>
  ago`), `plan_goals` and `your_plan_line` (the team plan), `research_since_your_last_shift` (technologies finished
  after the agent's last request before this shift, the last 12 and a count of earlier ones: the research news, plus
  what `force.technologies` shows researched since the snapshot taken at the start of the agent's previous shift (and
  at the runtime's first sample), so no research event is needed; nothing before the first snapshot is known) and
  `researched_none_built` (`roboports (logistic-robotics,
  construction-robotics); ...`: researched technologies with none of their buildings on any surface, from the
  harness's `unlocks.lua`, the table the stream hosts use).
- Research news needs no restart: a technology that leaves the head of the queue researched (or a level up) and was
  not announced by `on_research_finished` (which control.lua forwards from the next server start) is announced by the
  runtime's 10 s research sample.
- Mentions: `@name` (bot or player name, the name without `pog-`, or the display name, any case) or `@everyone`
  (also `@all`, `@team`); otherwise the plain name as a whole word. Never the sender. They are filed per agent when
  the message arrives (from agents, people in a client, and the server), so chat log rotation does not lose them; a
  `chat` read (not `peek`) delivers the ones it showed, and the rest ride on the next reply. At most 200 wait per
  agent; beyond that the oldest are counted in a "did not fit" line.
- `say {text, aloud: true}`: viewers also hear the line on the stream, spoken in the agent's own voice (`profile`
  `voice`); a line without `aloud`, like every tell, shows on the stream only as text. `chat` (and `peek`) returns
  `aloud: true` with it. Text over 500 characters is cut to 500 and the reply carries `cut {length, kept}`.
- Each agent's first reply carrying a `team` block has, once, the reminder `stream: viewers hear your say --aloud lines
  and confessions, spoken in your voice, and like hearing from you every few minutes; other chat and tells show on the
  stream only as text, which viewers read on screen, so write them as plain sentences with spaces between words`.
- `tell {to, text}` sends one line (1..500 characters; longer is cut to 500 and the reply carries `cut {length,
  kept}`) to teammates outside the game chat: `to` is a name or display
  name, several (an array or `"luna,sol"`), or `team` (also `everyone`, `all`) for every agent but you. Each recipient
  gets it in the next reply's `team.tells` and, if asleep, wakes with `woke: told` (and `tell: "from: text"`); it is
  never in the game chat, `chat` reads, the `chat:` trailer or `chat_remaining`, and draws no bubble. Unknown names
  fail with the roster; yourself is left out. The reply: `seq`, `to` (names, or `team`), and `away` for recipients on
  another planet, a platform or in a cargo pod (`sol is on Vulcanus`). `tells {since?, limit?}`
  returns the tells you sent or received `{seq,tick,from,away?,to,team?,text}`; the operator path returns every tell, which
  the stream shows on its logistics ticker (`-> Sol: text`, never voiced). CLI: `fh tell luna "text"`,
  `fh tell luna,sol - <<'EOF'`, `fh tell team "text"`, `fh tells --since N`.
- `operator {text}` (1..500 characters, one line; longer is cut and the reply carries `cut {length, kept}`) files a
  request to the operator: harness bugs, tool requests, things viewers asked for that the agents cannot do. The reply:
  `seq`. At most one a minute and 10 an hour per agent; a refusal names the wait. No teammate sees it. The operator
  path `operator_requests {since?, limit?}` returns `{seq,tick,from,text}` oldest first and `cursor`; the stream
  service appends new ones to `runs/RUN/operator-inbox.jsonl` and shows them on the ticker (`Astra → operator: ...`).
  The operator answers in the game chat as `server:`; an `@name` there is a mention (it wakes a sleeper). Each agent's
  first team block carries the reminder once. CLI: `fh operator "text"`, `fh operator - <<'EOF'`.
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
  `board_plan` (goals and other agents' lines; the operator has no line), `mention_counts` and `tells` as `operator`.
- Operator live attack groups (threat.lua; the pog stream follows a big group as it approaches): `attack_groups_live`
  (read) lists up to 10 enemy groups that finished gathering with a target, visible or not, while valid and under 10
  game minutes old: `id, surface, position, size, kinds, state (gathering|moving|attacking_*), gathered, first_size,
  target, target_distance, nearest/nearest_distance` (our nearest building within 160 tiles), `visible`, `age_s`.
  `describe` lists it under `operator_reads`; agents cannot call it.
- Operator big enemies (threat.lua): `big_enemies_live` (read) lists segmented units (demolishers) on the planets
  (searched every 10 s, followed by reference in between) with our nearest building or character within 500 tiles:
  `id, name, surface, position, speed (tiles/s), closing, nearest {x,y,name}, nearest_distance, eta_s, character
  {x,y,player}, character_distance`.
- Operator idle nudge (idle.lua; `tools/idle_nudge.py` in the pog repo): `idle_report` (read) gives per agent
  `standing_s` (how long its character has had no action, no running queue and a body on the map; kept once a second
  for agents that made a request; an fh sleep with nothing running counts as standing, a timed action does not),
  `alive`, `action`, `action_until_s`, `queue {state: none|empty|paused|running, steps}`, `sleeping_s`, `sleep_left_s`,
  `unread_chat`, `unread_mentions` (tells included), `unread_tells`, `unread_board` and `last_request_s`. `tell {to,
  text}` sends a tell from `operator`, like a teammate's: in the next reply's team tells, waking a sleeper
  (woke=told), never in the game chat.
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
