# Harness3 notes: the shake2 harness bugs (branch eng/harness3)

Round 10 (shake5 P1 harness items) comes first, then round 9 (shake4 P2 items 7, 8, 14 and P3 item 18), round 8
(shake4 P1 items 2 to 4), round 7 (shifts: resuming a team world), round 6 (the runtime.lua locals guard and refactor
plan), round 5 (the agents' own tool requests), round 4 (shake3 fixes) and the shake2 round.

## Round 10: shake5 P1 items 1, 2, 8 and 5 (profiles part)

Main merged first (it brought docs/studies/shake5.md).

- Item 1, loss incidents. `record_loss` joins a loss to its cell's incident only while that incident is open and its
  last loss is at most 5 minutes old; otherwise it starts a new one. A new operator call, `shift_start`
  (`remote.call("agent_harness","shift_start")`, in control.lua and runtime.lua), marks every open incident closed
  and returns `incidents_closed`. `tools/start-team.sh` calls it on a resume right after "resumed at tick" and logs
  the reply. Old incidents stay in `state.losses` (64 kept, as before) and show in `status` with `since`; without
  `since` the last 5 minutes are shown, as before. Game time does not run between shifts, so the 5-minute rule
  alone would not split a raid still going at the save; `shift_start` does (saves from before this change load
  fine: their incidents have no `closed` field and are treated as open).
- Item 2, build over a machine. I chose the refusal: fast-replace for a bot (a character with no player) has no
  inventory the engine can hand the old machine to through `player`, and I could not check the `character` path live.
  `build_direct`, after `can_place_entity` passes, looks in the footprint for an entity of the same
  `fast_replaceable_group` (the only kind the manual check lets overlap) and refuses: "placement blocked by
  assembling-machine-1 (x,y) already on these tiles: building over it would leave both; mine it first (mine at its
  position), then build (its recipe and contents do not carry over)". This also covers belts over belts (an upgrade
  in place now needs a mine first) and players' builds through `build_direct` (undergrounds); a player's cursor
  build keeps the engine's own fast-replace.
- Item 8, items on the ground. `build_direct` takes item-entities in the footprint into the inventory next to
  `clear_remnants` (reply `picked_up {item: count}`); one that does not fit stays and the placement error says to
  free a slot. `pickup` is refused when no item lies within the character's `item_pickup_distance` (1 when unknown)
  and otherwise takes one item stack every 6 ticks by script (a bot's character does not pick up on its own, which
  is why Grok's calls returned ok and the plate stayed), ending `picked_up` when none is left, else
  `duration_elapsed`, `inventory_full` or `nothing_in_reach`; `last.picked` lists what it took. The 6-tick pace is
  my choice, not measured from the game.
- Item 5, profiles part. A `voice` another agent holds is refused before anything changes, naming the holder, like
  glyphs and colours. Existing duplicates in a save stay until someone sets a voice. The TTS fallback for `el-`
  voices (the other half of item 5) is stream code and not in this round.

Files: `mod/agent-harness_0.1.0/{runtime,control,profiles}.lua`, `tests/bots.lua`, `mod/tests/runtime_test.lua`,
`tools/start-team.sh`. runtime.lua keeps 3 free top-level locals.

Tests: every Lua suite passes; tools/test_resume.py passes; `npm test` 97 of 101 (the 4 sandboxed bridge socket tests,
as before). control.lua gained a remote function, so a world needs the mod files copied (start-team's resume path
and new instances do this), not only a runtime deploy, before `shift_start` answers.

Not checked live (deploys need the box). On world `live` after copying the mod and restarting it, with bot `h3-a`:
`tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","shift_start"))'` should print
`incidents_closed`; drop an iron plate, build a stone furnace over it and expect `picked_up`; `fh call pickup` next to
a dropped plate should report `last.picked`; an assembling-machine-2 over an assembling-machine-1 should be refused.

## Round 9: shake4 P2 items 7, 8, 14, P3 item 18

Main merged first (it brought docs/studies/shake4.md).

- Item 7, `board_post` shapes (10 posts resent). A post takes `note` (its first note, 1..200 characters, by the
  poster) and `needs` as an object `{"iron-plate": 200}`, stored as the sorted list `[{name, count}]` the other
  shapes already give. `note` is a describe key the argument check treats as documentation, so `board_post` lists it
  in `EXTRA_ARGS` like `board_update`. `agent/team.md` shows both in one sentence.
- Item 8, `observe` while dead (26 failures). An `observe` (any scope, or a view called by name) from a dead bot
  answers `{dead: true, dead_until_tick, respawns_in_s, note: "bot X is dead until tick N; fh sleep SECONDS wakes at
  the respawn (respawned)"}` with the usual team, clock and chat blocks, instead of failing. A bot riding a cargo pod
  is not dead and keeps the old path. `fh`'s compact waits read `observe` for the self row; with this reply they find
  no player row and fall back to status for the position, as before.
- Item 14, profile colours (four oranges). Like a glyph, a `color` within 90 (redmean RGB distance, 0..765) of
  another agent's is refused before anything changes, naming the holder, the distance and up to four free colours
  from a 20-colour palette. Setting your own colour again is fine. Existing profiles are not re-checked, so a resumed
  shake4 world keeps its oranges until someone changes colour. 90 refuses #ffa500 next to #ff8000 (74) and allows
  #ffb000 (96); tune `MIN_COLOR_DISTANCE` in `profiles.lua` if it is too strict.
- Item 18, name filters. `nearest`, `scan` and `observe`'s `entity_names` go through `M.find_named`, which calls the
  engine and, only when it refuses with "Unknown entity name: X", lists the entity names holding every dash-separated
  part of X ("rock-huge" finds huge-rock; first 12 and the total) and says when X is an entity type ("tree"). Valid
  names cost nothing extra.

Files: `mod/agent-harness_0.1.0/{runtime,board,profiles}.lua`, `tests/{board,bots}.lua`, `mod/tests/runtime_test.lua`,
`agent/team.md`. runtime.lua keeps 3 free top-level locals (`find_named` is a field of M).

Tests: every Lua suite passes; tools/test_{context,describe_lines,permit,resume,supervise}.py pass; `npm test` 97 of
101, the 4 bridge socket tests that cannot listen inside this sandbox, as in round 8.

Not checked live: deploying to world `live` needs the box (`tools/winps.sh`), which this session cannot reach. After
a deploy there, with a bot `h3-a`: `bin/fh --bot h3-a call nearest --args '{"name":"tree"}'` should list tree
names and suggest type; two `profile` calls with `#ff8000` from two bots should refuse the second.

## Round 8: shake4 P1 items 2, 3, 4

Main merged first (19df587).

- Item 2, sleep while dead (19 refused sleeps in shake4). `runtime.dispatch` lets `sleep` through for a dead bot, as
  it does `chat` and `say`. `waits.lua` records `dead_until` at the start of the sleep (from the bot record, through a
  new `dead_until` in the waits api; nil while alive or traveling). The reply says `dead: true`, `respawns_at_tick`
  and `wakes_on='respawn, a message mentioning you'`; `sleep_check` answers `respawned` once the new character
  exists, and a mention or the requested time still wake it first. The requested seconds are not stretched to the
  respawn, so `fh sleep 5` on a 10-second respawn wakes `elapsed`. `wait_until` stays refused while dead: as a
  direct action it holds the character idle and checks conditions per tick, and a dead bot has no character, so the
  dead refusal for every action now ends "fh sleep SECONDS waits and wakes with respawned". The CLI treats
  `respawned` as an ordinary wake (exit 0); `docs/usage.md` says so.
- Item 3, supervisor after a Claude Code turn end. For kind `claude` (from the workspace's `.context-hooks`), an idle
  or done status is the end of the turn, so the "request in the last 2 minutes, working" skip no longer applies and
  the nudge goes after the quiet minute. Other kinds keep the skip.
- Item 4, `item-on-ground` in a build footprint (11 failures). `placement_error` names the item
  (`item-on-ground (iron-plate) (36.5,-28.3)`) and adds "; pick the item up: stand on or next to it and fh call
  pickup". The direct build does not pick items up itself: a remedy keeps the time honest and the change small.

Files: `mod/agent-harness_0.1.0/{runtime,waits,bots}.lua`, `tests/bots.lua`, `tests/waits.test.ts`,
`docs/usage.md`, `tools/supervise.sh`, `tools/test_supervise.py`. runtime.lua still has 3 free top-level locals.

Tests: every `lua tests/*.lua` passes; `tools/test_supervise.py` passes (new case: a claude agent idle 10 s after a
request is nudged). `npm test`: 97 of 101 pass here; the 4 failures are the bridge tests, which cannot listen on a
unix socket inside this sandbox (`listen EPERM ... bridge.sock`), the same before these changes.

Live check (world `live`, not run from this session; `bin/fh` against live is refused here):

```sh
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","h3-a"))'
POG_WORLD=live bin/fh --bot h3-a call status                                   # X,Y
# kill h3-a's character (as in round 4), then within the 10 s respawn wait:
tools/pog.py --world live rcon '/silent-command local c=game.surfaces.nauvis.find_entities_filtered{type="character",position={X,Y},radius=1}[1] if c and not c.player then c.die() end'
POG_WORLD=live bin/fh --bot h3-a sleep 30     # expect woke: respawned after about 10 s
# item on the ground: drop an iron plate at a free spot, build a stone furnace over it
POG_WORLD=live bin/fh --bot h3-a call build --args '{"item":"stone-furnace","position":{"x":X,"y":Y}}'  # expect the pickup remedy
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_remove","h3-a"))'
```

## Round 7: shifts, resuming a team world

### What a resume does

`POG_RESUME=PREVIOUS_RUN tools/start-team.sh RUN MINUTES [--stream]`:

1. `tools/win/resume-save.ps1 -Name n -From PREVIOUS_RUN -Check` (read-only, the world may be running) reports the
   save it would take and the instance's mods. The save is the newest of `saves\PREVIOUS_RUN.zip` (stop-team's
   `/server-save`) and the `_autosave*.zip` written after it, unless another run's save is newer than
   `PREVIOUS_RUN.zip` (another run used the world since; its autosaves are not ours), then `PREVIOUS_RUN.zip`.
   start-team refuses when the instance's `space-age` mod differs from `POG_SPACE_AGE` ("refusing: world n's mods
   have space-age on but POG_SPACE_AGE=0; run again with POG_SPACE_AGE=1").
2. Stop world n; copy the harness mod to `D:\pog\mods`; `resume-save.ps1 -To RUN` copies that save to
   `saves\RUN.zip` (so this shift saves under its own name and the previous run's save stays as it was) and
   refreshes the instance's harness mod (the directors copy the instance's mods). No new instance.
3. The server starts on `RUN.zip`; describe + deploy as before; then `pog.py resume` (a save made while tick-paused
   would load paused) and the log line `world n: resumed at tick T (game Nm)`.
4. Directors join as before. `tools/team_bots.py` lists the save's bots (operator `bots`) and creates only members
   it lacks ("haiku kept (alive, at -24,-13)", "luna created ..."; bots not in the team are listed and left alone).
   Fresh worlds go through the same script (every member created).
5. `runs/RUN/resumed-from` names the previous run. Each workspace's `notes.md` is the previous shift's, under one
   line: "(Carried over from the previous shift, run shake4: its notes.md for haiku, as that shift left it.)"; a
   member new to the world gets the usual empty notes. The prompt gains one sentence: "This is a later shift of the
   same world: your bot and the factory are as the last shift left them, and notes.md is where you left off."
6. The previous run's directory is `runs/PREVIOUS_RUN` in this checkout, else `~/code/player-of-games/runs/...`
   (`POG_RESUME_DIR` overrides). `POG_DRY_RUN=1` prints the plan (save check, per-member notes found or not, the
   previous run's last score tick) and touches nothing. `POG_OBS=0` skips the overlay tunnel, OBS scene, recording
   and stream (test shifts). Between shifts, `POG_STOP_WORLD=1 tools/stop-team.sh RUN` also stops the server and
   directors after the save, so game time moves only while agents play (the default is unchanged: the world keeps
   running, and with directors connected it does not auto-pause).

### Continuation in score, stream and analyst

- Score: `pog.py score` reads `game.tick`, which goes on from the save; the new run's `scores.jsonl` starts there.
- Analyst history (`tools/analyst/history.py`): a run with `resumed-from` joins the first shift's series (one series
  "shake4", labelled "shifts shake4 + shake5"), and a live shift excludes its world's earlier shifts from the
  benchmarks (it is never compared with itself). Pace comparisons were already by game time (tick / 3600).
- Stream service and casters: every time is game ticks, so they continue. The research model primes on its first
  poll, so old research is not announced again. The casters' baseline (shake1, 60 game minutes) gave "the same game
  time" comparisons from its last sample past its end; it now gives none more than 5 minutes past it.

### What else needs care

- The deploy at resume interrupts every active action and pauses every plan (`runtime.stop_all`), except a repeating
  plan resting between cycles: a previous shift's `queue_repeat` courier keeps cycling under the new session, which
  learns of it only from its notes or `queue_status`.
- Chat cursors are in the save: a new session's first `chat` returns what came in since its bot last read, up to the
  200-message log. Board items and claims carry over (as intended); so do profiles, glyphs and voices.
- The clock line shows the save's game time (about 2 h for shake4): the playbook has no first-hour assumption, but `agent/team.md` says "in your
  first minute, choose how you appear" (the profile is already set; a second `profile` with the same glyph is fine).
- stop-team's save is what the next shift continues; if the world kept running with directors after it (default),
  the autosaves taken after it are newer and win (idle bots, and biters, for up to that long).
- Space Age directors need the expansion build: start-team passes it from `POG_SPACE_AGE`, which the check matches
  to the save.
- Not checked in this round: the companion site (`site/push_live.py`) and `tools/report.py`/`tools/watch.py` are
  per-run and start from the new run's files; the site's own run history, if it lists runs, shows shifts as runs.

### Tests

`python3 tools/test_resume.py`: `bash -n` of the four scripts; team_bots keeps/creates (fake RCON, including
`{}` for an empty list and an operator failure); new-run's notes carry-over and a new member's fresh notes; the
resume sentence; the start-team dry run (plan lines, previous last tick, no run directory made, a run id equal to
the previous one refused); resume_check's comparisons. `tools/analyst/test_analyst.py` (shifts as one series),
`tools/stream/caster_selftest.py` (no pace past the baseline). Live, read-only: `team_bots.existing` listed shake4's
nine bots on world n, and `tools/resume_check.py` against a scratch run "resuming" shake4 reported the tick, research,
buildings, both bots and both notes as carried over.

Not run here: anything over ssh (this sandbox refuses <windows-box-ip>:22, "Operation not permitted"), so
`resume-save.ps1` is untested (no PowerShell on the Mac either), and the permission mode refused running
`tools/start-team.sh` itself, even as a dry run.

### The 05:00 test (to run; this session cannot reach the box)

From `/Users/owner/code/pog-harness3` on eng/harness3, after shake4 is stopped and saved (04:55):

```sh
cd /Users/owner/code/pog-harness3
export POG_RESUME=shake4 POG_SPACE_AGE=1 POG_TEAM_FILE=agent/team-resume-test.tsv POG_OBS=0 POG_CASTER=0
POG_DRY_RUN=1 tools/start-team.sh shift-test1 10        # the plan; expect both notes found and shake4's last tick
tools/start-team.sh shift-test1 10                       # haiku and luna, 10 minutes, analyst on, no OBS/stream
python3 tools/resume_check.py runs/shift-test1 n         # tick, research, buildings, bots, notes, prompt
# after the 10 minutes:
tools/stop-team.sh shift-test1 n
python3 tools/analyst/history.py runs | grep shake4      # expect "shifts shake4 + shift-test1"
```

`runs/shift-test1/start.log` has the save chosen, the tick it resumed at and each bot kept or created. shake5 at
06:00 then resumes shake4 itself (`POG_RESUME=shake4`): `shift-test1.zip` is newer than `shake4.zip`, so the check
ignores the autosaves and takes `shake4.zip`, not the test's state. If shake5 runs from this worktree, move
`runs/shift-test1` aside first: its `resumed-from` would make the analyst count it as a shift of shake4 (the analyst
reads this checkout's runs and the main checkout's). From the main checkout it is not seen.

## Round 6: runtime.lua locals

### The guard

`tests/locals.lua` (in `npm test` through `tests/lua.test.ts`, and runnable as `lua tests/locals.lua`) compiles
`mod/agent-harness_0.1.0/runtime.lua` and `control.lua` with N extra locals put in front of the first line, finds the
largest N that still compiles, and fails when fewer than 3 slots are free:

```
locals: runtime.lua has 3 of 200 top-level local slots free
locals: control.lua has 186 of 200 top-level local slots free
```

The failure says to move helpers into a module (require) or group them in a table, and points here. Why it matters: a
fresh world loads runtime.lua through the mod as its own chunk, so a 201st top-level local breaks every new world at
load, even though the hot-deploy bundle (73066da) wraps the body in a function and would still deploy. The count is the
peak of locals alive at once in the main chunk, so a top-level `for` loop's hidden locals count too (the Lua 5.5 used by the tests keeps one more hidden
local per generic `for` than Factorio's 5.2, so the test can only be stricter than the game). Checked: with one local
added to a copy of runtime.lua the test fails with that message; the counter's own assertions (200 locals leave 0,
199 leave 1, 198 leave 2) run every time.

### Refactor plan (for tomorrow, after eng/spaceage's runtime.lua changes land)

runtime.lua's main chunk holds about 200 locals in 4012 lines. Three steps, smallest diff first; run `lua
tests/locals.lua` after each.

1. Module constructors, 13 slots, mechanical. `blueprint_module`, `scheduler_module`, `construction_module`,
   `kite_module`, `threat_module`, `survey_module`, `conditions_module`, `route_module`, `pipes_module`, `rates_module`,
   `stock_module`, `space_module`, `clock_module` (lines 5-21) are each called once, where the module is built (lines
   3005, 3422-3456, 3690-3700, 3782-3784). Call `require('x'){...}` there instead, as `M.chat_module` already avoids a
   local. No behaviour change; one line each at the top and at the call.
2. Constants, about 20 slots. One `local K={...}` (or fields on `M`) for `MAX_TICKS` (6 uses), `WATCH_TICKS`,
   `STUCK_TICKS`, `LOSS_CELL`, `MAX_INCIDENTS`, `STOCK_RADIUS`, `STOCK_REFUSE_S`, `HAND_BACKLOG_S`,
   `COPPER_GROUP_LIMIT`, `FEED_CHECK` (4), `PIPE_LEG`, `PADDED_BOX`, `SLIM_BOX`, `STALL_TICKS`, `SIDESTEP_TICKS`,
   `MAX_STALLS`, `MAX_REPLANS`, `PROGRESS_TICKS`, `MAX_ALERTS`: 19 names, about 33 use sites, each `X` becoming `K.X`.
   The lookup tables used once or twice can join a second table `T` for another ~10 slots: `give_order`, `kind_order`,
   `collect_types`, `GRID_TYPES`, `GRID_SKIP`, `ARROWS`, `ASSEMBLERS`, `STEP`, `drawn_enemy`, `timed_kind`,
   `repeat_shift`, `live_fields`, `DOC_ONLY`, `EXTRA_ARGS`, `VIEW_SCOPES`.
3. Subsystems into modules, when more room is needed (each frees its helpers and moves code out of the 4000 lines):
   - hand crafting, 12 functions: `hand_speed`, `crafting_left`, `crafting_count`, `crafting_line`, `craft_stock`,
     `takes`, `hand_recipe`, `craft_shortfall`, `begin_craft`, `craft_cost`, `best_assembler`, `craft_facts` (plus
     `STOCK_RADIUS`, `STOCK_REFUSE_S`, `ASSEMBLERS`, `HAND_BACKLOG_S`) into the existing `crafting.lua`, with `stock`
     and `survey` passed in;
   - losses and alerts, 7: `record_loss`, `losses_since`, `ago`, `counted`, `describe_incident`, `unseen_losses`,
     `recent_alerts` (plus `LOSS_CELL`, `MAX_INCIDENTS`, `MAX_ALERTS`) into an `alerts.lua`;
   - research, 7: `queue_names`, `trigger_text`, `research_block`, `with_prerequisites`, `set_research_queue`,
     `array_of_names`, `feed_research_plans` into a `research.lua`;
   - pipe routing, 5: `PIPE_LEG`, `free_pipe_tile`, `pipe_leg`, `joined_box`, `route_pumps` into the existing
     `pipes.lua`.

Leave alone: the locals the hot path and many handlers share (`state`, `player`, `body`, `real`, `entity`, `finish`,
`stop`, `steer`, `position`, `distance`, `integer`, `handlers`, `reads`, `passive`, `check_args`): moving them costs
an extra table lookup per call and touches hundreds of lines. Step 1 alone gets back to 16 free; steps 1 and 2 to over
40, enough for the Space Age work.

## Round 5: the agents' tool requests (shake3, sapilot)

main merged first (fast-forward to 6687019). Each change has a fake-engine test that fails on the old code. None is
checked on a live world (this session cannot run `bin/fh`); the checks to run are at the end of this section.

### 1. build with the agent's own character on the footprint

Evidence: Grok's most common shake3 placement error ("the character standing on the footprint (move off it first)", 9
of 20 placement errors); Gemini's sapilot wish "Auto-evasion in `build`: automatic slight nudge of character if
standing on the target building's footprint".

Fix: when the agent's own character is the only thing in the footprint (corpses and ore aside), `build` picks the
nearest free spot just off the footprint that keeps the position in build reach and is not on a belt, walks there with
real walking (steered every tick, as `move_to` does, at most 3 s), and builds. It is the same timed action as a build
waiting for a craft: the reply is `stepping_aside {from,to}` with `until_tick`, the outcome `fed | failed |
timed_out`, and `last.result` holds the build reply. In a batch the entries before stay built (`built`, `placed`) and
the rest run after the step (`built_before` in the final result). Anything else in the footprint, or no free spot in
reach, fails as before with the same error. Queued builds wait through the step (`fed` counts as success).
Test: `tests/bots.lua` (single, batch, queued, no free spot).

### 2. Gemini's inspect misses

Evidence (`runs/shake3/gemini/journal.jsonl.gz`): 30 `inspect` errors. 23 were "entity not found" on empty tiles,
mostly at 08:05-08:11 while checking poles, inserters and belts around the green-science assemblers. Against Gemini's
own earlier scan rows, most were exactly 1 tile from a small entity (pole, inserter, belt), a few beside a character,
and some with nothing within 1.6 tiles: guessed positions, not moved entities or reach. 4 were out of sight (38 to 54
tiles), 1 ambiguous, 1 `position: [-5,-6]`.

Fix (`entity()`, so every targeted action gains it):
- A point inside a building's footprint picks that building when no entity has its centre there, as a player's cursor
  does (any tile of an assembler). This holds for actions too (`transfer`, `rotate`, `mine` on any tile of a building
  act on it), except that ore at the point stays the target of an action: `mine` on an ore tile under a drill mines
  the ore, never the drill; only `inspect` takes the building there.
- A miss says what is near: "entity not found at (25.5,0.5): nearest small-electric-pole (24.5,0.5) 1.0 tiles; target
  an entity's position as scan lists it (observe scope=scan position={x=25.5,y=0.5} radius=3)", or "nothing within 3
  tiles".
- "ambiguous target: small-electric-pole and wooden-chest at (x,y); specify name or unit_number".
- `position` accepts `[x,y]` everywhere; the out-of-sight error adds "move_to within 30 tiles first".
- The describe `target` line says all this.
Test: `mod/tests/runtime_test.lua`.

### 3. The board's harness requests and the notes' tool wishes

The board held two harness items: shake3 #17 (Sol, stumps and ghosts over trees) was fixed in round 4; sapilot #4
(Astra) is answered below. Tool wishes come from `runs/shake3/*/notes.md` and `runs/sapilot/*/notes.md`.

Done (small tool fixes):

| Request | Who | Change | Test |
|---|---|---|---|
| Drill output tile not exposed | Astra, sapilot board #4 and notes | entity summaries (build replies, observe rows) carry a mining drill's `drop` tile and `drop_into`; `inspect` adds `drop_position` and `io` ("-> x,y entity") | runtime_test |
| A chest with an item on its tile is an ambiguous target | Grok, shake3 | an item on the ground is a fallback target like ore (taken only when nothing else is there, or by name) | runtime_test |
| A build that skips blocked tiles; batches stop midway | Grok shake3, Astra sapilot | `build builds=[...] skip_failed=true`: failing entries go into `failed {index,position,error}`, the rest build | runtime_test |
| queue cancel prints 60+ history entries; concise queue results | Opus shake3, Astra sapilot | `queue_submit/repeat/edit/cancel/resume` return the newest 3 history entries and `history_total`; `queue_status` keeps all | `tests/scheduler.lua` |
| engine-unit "not hand-craftable now" with force and ingredients | Grok, shake3 | the engine is right (advanced-crafting is machine-only); the error now says "(category advanced-crafting) cannot be hand-crafted by a character; an assembling machine can make it (configure recipe=engine-unit, then feed it)" | runtime_test |
| A queue that does not pause on chat/say | Opus, sapilot | already so: chat and say are passive and never stop a plan (Opus's one sapilot pause followed an out-of-reach failure); a test pins it | `tests/bots.lua` |
| collect uses count, not want | Opus, shake3 | done in round 4 (`collect want=N`) | |
| Ignore stumps; ghosts over trees | Sol, shake3 board #17 | done in round 4 | |
| Talk while dead | Sonnet (study) | done in round 4 | |

Not done, with the reason:

| Request | Who | Reason |
|---|---|---|
| collect/feed across teammates' claims (trust lists, `teammate_chests`, claim override) | Gemini (both runs), Haiku, Opus, Sonnet, Muse | team policy, not a tool fix: claims protect a teammate's output by design, and named positions already take from them (the reply says whose). Whether to add consent (e.g. a claim flag "open to the team") is Nick's call |
| Inserter direction as the drop side | Opus sapilot; Gemini noted the convention | convention change: every playbook line, describe text and agent habit assumes pickup side; flipping it mid-series would cost more than it saves. Describe states it, and build/inspect show `pickup` and `drop` tiles |
| `place_ghosts` with integer directions | Gemini shake3 | 2.0 directions are 0..15 (east is 4, not 1); accepting numbers invites wrong guesses. The error already names the compass words |
| sleep that ignores chat | Haiku | waking on a mention is what keeps a sleeping agent answerable to the team (study: Haiku slept ~44 of 60 minutes); a CLI flag in `host/cli.ts` (eng/board's file) if Nick wants it |
| mine ticks above 600 | Grok | `max_action_ticks` is 600 by design; a plan or `--wait` loop repeats it |
| A research wait that fails fast when every lab lacks packs | Grok | medium (a new `wait_until` condition reading lab inventories each check); `observe scope=labs` and status warnings ("labs missing packs") already show it |
| feed balancing science across every lab | Grok | strategy-level behaviour of feed; `feed radius=` with `count` tops up every lab in range |
| feed reports out_of_items after delivering | Luna | by design: the tour stops because its items ran out before every target was served; `last.given` shows what went in, and a plan step failing lets `on_fail` react |
| item_count wait needs at_least or below; wait_until has no tick option | Luna, Sonnet | by design: the error names `at_least`/`below`; `wait_ticks` waits N ticks |
| nearest needs name or type; transfer needs item with to_entity; argument names | Gemini sapilot | by design; the errors name the valid arguments (check_args lists them) |
| corpse recovery needs transfer to_player | Sonnet | by design and documented (`take_order`, character_corpse) |
| wait_until replaced silently by a move or build | Muse | one action at a time by design; the replaced action's `last.outcome` is `replaced`. A plan keeps steps in order |
| bottleneck JSON has a trailing warning line | Muse | the CLI prints the warning after the JSON; `host/cli.ts` output format is eng/board's area. Recorded for them |
| build centre rules opaque (integer vs .5) | Muse | the reply's `entity.position` shows where it went; a snapping rule in describe would help (small doc change, not done tonight) |
| courier/loop primitive, attach_buffer, ghost-plan reviewer, power-coverage preview, editable plans mid-run, one view of assembler and lab stock, fluid alignment warning, pole routing around the crash ship, batch craft-before-build | Opus, Gemini, Muse, Luna, Astra | not small: each is a new action or planner. `queue_repeat`, `plan save/run`, `observe scope=labs`, `scan fields=io` and build's awaiting_craft cover parts of them |
| labs query returned empty once | Muse | no repro in the journal |
| chat_remaining stayed in the hundreds | Grok | chat is eng/board's area |

### Files touched (round 5)

- `vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua`: `position()` ([x,y]); `assert_visible` (hint);
  `entity()` (footprint pick, nearest-entity miss, ambiguous names, item on the ground); `summary()` and `scan_fields.io`
  (drill drop); `build_one` (aside check), `handlers.build` (step aside, `skip_failed`), the `feed` branch of
  `M.tick_body` (walk off, rerun); `handlers.inspect` (drill drop); `begin_craft` (machine-only recipe); describe
  entries `target`, `build`, `inspect`. No new top-level locals.
- `.../construction.lua`: `M.in_box`, `M.aside` (new).
- `.../scheduler.lua`: `snapshot(q,recent)` and the five changing handlers; `queue_status` describe text.
- Tests: `tests/bots.lua`, `tests/scheduler.lua`, `mod/tests/runtime_test.lua`.
- `docs/SPACEAGE.md` (coordination section), this file.

### Tests (round 5)

Every `tests/*.lua` and `mod/tests/*.lua` passes. `npm test`: 95 pass, 4 fail (the bridge socket tests this sandbox
refuses with `listen EPERM`, as in rounds 3 and 4).

### Live checks (to run; this session could not)

```sh
cd vendor/factorio-harness && npm run build && cd ../..
POG_WORLD=live bin/fh deploy
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","h3-a"))'
fh() { POG_WORLD=live bin/fh --bot h3-a "$@"; }
fh call status                                                          # X,Y (the bot's position)
# Build where the bot stands: it steps off and builds (stepping_aside, then outcome fed)
fh call build --args '{"item":"stone-furnace","position":{"x":X,"y":Y}}' --wait
# inspect off-centre and on an empty tile next to it
fh call inspect --args '{"position":{"x":X+0.6,"y":Y+0.6}}'             # the furnace
fh call inspect --args '{"position":{"x":X+3,"y":Y}}'                   # "entity not found at ...: nearest stone-furnace ..."
# drill drop tile: the starting burner drill
fh call build --args '{"item":"burner-mining-drill","position":{"x":X+4,"y":Y}}'   # entity.drop, drop_into
# (skip_failed needs items the new bot lacks; its fake-engine test covers it)
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_remove","h3-a"))'
```

## Round 4: shake3 P2 items 7 and 10, P3 item 13 (glyphs)

main merged in first (fast-forward to b2de475). All five items are fixed, each with a fake-engine or offline test that
fails on the old code. None is verified on world `live`: this session's permission mode denied `bin/fh` again
(`POG_WORLD=live bin/fh doctor`), so the live checks are written out below for the operator to run.

| Item | shake3 evidence (`runs/shake3/*/journal.jsonl.gz`) | Cause | Fix | Test |
|---|---|---|---|---|
| `chat` fails while dead | Sonnet 3 times: "bot sonnet is dead; it respawns at tick N" | every non-read action resolved the bot through `player()`, which refuses a dead bot; only `chat peek` skipped it | a bot's `chat` and `say` take its proxy dead or alive (`dispatch_request`), so it reads and answers the team while it waits to respawn | `tests/bots.lua`: dead bot says, another player reads it, dead bot reads the reply, bad `limit` still refused |
| tree stumps block placement | Sol's harness item #17; Haiku 3, Sonnet 3, Sol 1+ direct: "placement blocked by tree-08-stump" right after mining that tree; Sol's queue histories repeat errors that list stumps beside ghosts (counts inflated by repeated `queue_*` replies) | the engine's script placement check (`can_place_entity`, ghost `revive`) refuses remnants (type `corpse`), which a player's build removes | `construction.clear_remnants` removes remnants (never a `character-corpse`) in the footprint before a bot's direct build or ghost revive; the character is in build reach there | `tests/bots.lua`: build over a stump succeeds, the stump goes, a character corpse stays |
| biter corpse blocks placement | Grok 01:02: "placement blocked by small-biter-corpse (-59.9,-13.2), burner-mining-drill (-62,-12), burner-mining-drill (-60,-12)" | the real blockers were the two drills (a 3x3 assembler over them); the corpse was listed first | the same clearing removes the corpse first, so the error names only the drills | `tests/bots.lua`: the error names the drill and no corpse; the corpse is gone |
| ghost over trees refused | Sol's item #17 ("place_ghosts returned placement blocked by tree rather than marking/clearing it as docs promise"); Haiku 4: "placement blocked by tree-08, dead-tree-desert; mine it, or place_ghosts (marks it) + construct" from `place_ghosts` itself | `can_place_entity{build_check_type=manual_ghost, forced=true}` refuses trees in 2.0.77 | `place_ghost` also accepts a footprint holding only neutral trees, plants and rocks, and remnants (`construction.only_obstacles`); the ghost marks the trees and rocks as before, construct mines them, the build clears remnants. A force's own plants (Gleba farms) and anything else still refuse. Remnants under a ghost are not removed at placement (it reaches any charted spot) | `mod/tests/runtime_test.lua`: ghost over tree+stump placed, tree marked, stump left; tree+chest refused naming the chest; own plant refused |
| `collect want` in a queue | Opus 2 (`queue_submit` refused whole: "unknown argument want for collect"), as in shake2 | `want` was never an argument | `collect want=N` (with `item`): hold N, taking only the difference; nothing taken (and `held`, `note`) when the character already has N; not with `count`. Worked out when the step runs, so a queued collect sees earlier steps' gains. Listed in describe | `mod/tests/runtime_test.lua`: direct top-up, already enough, queued step succeeds and takes the difference, errors |
| supervisor nudges a working agent (P2 item 7) | Grok nudged 00:48:57 mid-turn; Muse 5 nudges 01:21 to 01:26 while building | herdr read `idle`/`done` during a backgrounded `--wait` or a long tool call | before nudging, `supervise.sh` reads the last `"event":"request"` line of `WORKSPACE/journal.jsonl`; under 120 s old means working: no nudge, log line `skip nudge (status idle): last request Ns ago, working` | `tools/test_supervise.py` (fake herdr always idle): request 10 s ago not nudged, 5 min ago nudged, no journal nudged |
| shared glyphs (P3 item 13) | Astra and Muse both ✦, Sol and Sonnet both S | glyphs were not checked | `profile` refuses a glyph another agent or player holds: "glyph ✦ is taken by Astra (astra); pick another (profiles lists every glyph in use)", before anything in the call changes. Case and U+FE0F are ignored in the comparison. Setting your own glyph again is fine | `tests/bots.lua` |

Survival rules are unchanged. Remnants give no items; a character corpse (the dead agent's items) is never removed.
A ghost over trees is what a player's ghost does in game.

What players see differently: `chat`/`say` while dead work; builds over stumps work and their errors name the real
blocker; `place_ghosts` over trees works (then `construct`); `collect item=X want=N`; a duplicate glyph is refused.
`agent/team.md` is unchanged (the describe line for `glyph` says it must be unique).

### Files touched (round 4)

- `vendor/factorio-harness/mod/agent-harness_0.1.0/runtime.lua`: `dispatch_request` (dead bot talk), `build_direct`
  (one `clear_remnants` line), `place_ghost` (placement check), `handlers.collect` (`want`), the `collect` describe
  entry. No new top-level locals (main's bundler note, 73066da).
- `.../construction.lua`: `M.box`, `M.clear_remnants`, `M.only_obstacles` (new, before `obstructed`).
- `.../profiles.lua`: `same_glyph`, `holder`, `check_glyph` and one line in `M.handlers.profile`; the glyph describe text.
- `vendor/factorio-harness/tests/bots.lua`, `vendor/factorio-harness/mod/tests/runtime_test.lua`.
- `tools/supervise.sh` (journal check; `POG_SUPERVISE_QUIET`/`POG_SUPERVISE_POLL` for the test; the `.context-hooks`
  read no longer prints an error when the file is missing), `tools/test_supervise.py` (new).
- `docs/SPACEAGE.md`: a coordination section for eng/spaceage (bot travel), listing these hunks. `bots.lua` is not touched.

### Tests (round 4)

- Every `tests/*.lua` and `mod/tests/*.lua`: pass (runtime 720 assertions).
- `npm test`: 95 pass, 4 fail. The 4 are the `tests/bridge.test.ts` socket tests, refused by this sandbox
  (`listen EPERM ... .cache/bridge-*/bridge.sock`), as in round 3 before any change.
- `npm run build`: clean. `python3 tools/test_supervise.py`, `tools/test_shot_sync.py`, `tools/test_describe_lines.py`: pass.

### Live verification on `live` (to run; this session could not)

From the repo root on eng/harness3. Deploying replaces the runtime the other engineers loaded on `live`. Bots `h3-a`
and `h3-b`; X,Y and TX,TY are positions read from the previous reply.

```sh
cd vendor/factorio-harness && npm run build && cd ../..
POG_WORLD=live bin/fh deploy
for b in h3-a h3-b; do tools/pog.py --world live rcon "/silent-command rcon.print(remote.call(\"agent_harness\",\"bot_create\",\"$b\"))"; done
fh() { POG_WORLD=live bin/fh --bot h3-a "$@"; }

# Glyph: h3-a takes it, h3-b is refused naming h3-a
fh call profile --args '{"glyph":"Q"}'
POG_WORLD=live bin/fh --bot h3-b call profile --args '{"glyph":"q"}'      # expect: glyph Q is taken by h3-a

# Stump: mine a tree, see its stump, build the starting stone furnace on it
fh call nearest --args '{"type":"tree","limit":1}'                      # TX,TY
fh call move_to --args '{"position":{"x":TX,"y":TY},"within":2}' --wait
fh call mine --args '{"position":{"x":TX,"y":TY},"ticks":600}' --wait
fh observe --args '{"scope":"scan","position":{"x":TX,"y":TY},"radius":2}'   # a *-stump here makes this a real check
fh call build --args '{"item":"stone-furnace","position":{"x":TX,"y":TY}}'   # expect consumed: 1

# Biter corpse in a footprint that overlaps the furnace: the error names the furnace only (the starting burner drill)
tools/pog.py --world live rcon '/silent-command game.surfaces.nauvis.create_entity{name="small-biter-corpse",position={TX+1.3,TY+0.2}}'
fh call build --args '{"item":"burner-mining-drill","position":{"x":TX+1,"y":TY}}'  # expect: placement blocked by stone-furnace (TX,TY), no corpse

# Ghost over a tree, then construct
fh call nearest --args '{"type":"tree","limit":1}'                      # a second tree, UX,UY
fh call place_ghosts --args '{"entities":[{"name":"stone-furnace","position":{"x":UX,"y":UY}}]}'  # expect placed 1, obstacles_marked 1
fh call construct --args '{"area":{"left_top":{"x":UX-2,"y":UY-2},"right_bottom":{"x":UX+2,"y":UY+2}}}' --wait
# construct mines the tree (mined >= 1); the furnace itself is "missing" (the one furnace is placed above), which is fine

# collect want in a queue: the bot holds 8 iron plates; nothing is taken and the step succeeds
fh call queue_submit --args '{"steps":[{"action":"collect","args":{"item":"iron-plate","want":5,"positions":[{"x":TX,"y":TY}]}}]}'
fh call queue_status                                                    # history: collect ok, note "already holding 8 iron-plate"

# Dead bot talks: kill h3-a's character (no player), then chat and say within its 10 s respawn wait
fh call status                                                          # X,Y
tools/pog.py --world live rcon '/silent-command local c=game.surfaces.nauvis.find_entities_filtered{type="character",position={X,Y},radius=1}[1] if c and not c.player then c.die() end'
fh call status                                                          # alive: false, dead_until_tick
fh call say --args '{"text":"h3 check: talking while dead"}'           # expect seq, not "is dead"
POG_WORLD=live bin/fh --bot h3-b call chat                              # shows h3-a's line
fh call chat

for b in h3-a h3-b; do tools/pog.py --world live rcon "/silent-command rcon.print(remote.call(\"agent_harness\",\"bot_remove\",\"$b\"))"; done
```

The supervisor change needs no live check beyond the next team run: `runs/shake4/*/supervisor.log` should show
`skip nudge ... working` lines and no nudge while the journal has requests.

Scope: the six bugs in `docs/studies/shake2.md` section 13, P2 item 10, with the evidence from section 7. All six are
fixed and covered by fake-engine tests. None is verified on world `live`: this session's permission mode denied every
`bin/fh` command (`bin/fh call status`, `bin/fh doctor`), so I could not deploy or create `h3-*` bots. The commands to
run are in "Live verification" below. `tools/pog.py --world live score` did work (tick 1132557, running).

## The bugs

| Bug | shake2 evidence (journals in `runs/shake2/*/journal.jsonl.gz`) | Cause | Fix | Test |
|---|---|---|---|---|
| `call inventory` unsupported | 17 calls failed with "unsupported action; call describe": Luna 5, Haiku 5, Sonnet 4, Grok 1, Gemini 1, Opus 1 | no such action | new read-only action `inventory`: `inventory` (main), `guns`, `ammo`, `armor`, `free` (status's `free=N/M` line), `crafting`, `warnings`; listed in describe | `mod/tests/runtime_test.lua`: contents, free line, clock line, a running walk keeps going, unknown arguments rejected |
| `describe.json` not greppable by `"name": "craft"` | Grok found nothing, decided the file was missing, tried to regenerate it | lines were `"craft": {...}` | `tools/describe-lines.py` writes `"craft": {"name": "craft", "args": {...}}`; both `grep '"craft"'` and `grep '"name": "craft"'` hit that one line; arguments sit under `args` because `scan` and others take an argument called `name` | `tools/test_describe_lines.py` (fake describe reply); also checked on shake2's real describe |
| `construct`: "Invalid PlayerIdentification" | Sol 04:53:22, `construct {"ticks":3600}` | `construction.lua` marked trees under ghosts with `order_deconstruction(force, p)`, where `p` is the bot (or map-view) proxy table | passes `real(p)`: the LuaPlayer, or nil for a bot | `tests/construction.lua`: the fake `order_deconstruction` rejects anything but a LuaPlayer or nil, as the engine does; the old line fails it |
| `shoot` "did not spend ammo" | Grok's own observes show it did: ammo slots 10 -> 8 after a 400-tick shoot, 12 -> 11 after 500 ticks | the compact `--wait` reply printed `last` (the previous move_to) instead of `last_combat`, and diffed only the main inventory while magazines sit in the ammo slots | CLI: a shoot wait prints `outcome` from `last_combat`, `action: shoot`, `ammo_used`; every wait's `inventory:` diff now covers main inventory plus ammo slots. Runtime: shoot records the ammo at the start, `last_combat.ammo_used` (whole magazines), ends with `out_of_ammo` when the slots empty, and refuses to start with no ammo | `tests/cli.test.ts` (compact shoot wait); `mod/tests/runtime_test.lua` (no ammo fails, ammo_used, out_of_ammo) |
| `observe scope=stock` without an item | Luna once, Muse twice: "item must be a known item name" | `stock.view` required `item` | without `item` it returns `items`: one line per item held in machine outputs and chests within `radius` (default 128), largest first, e.g. `copper-plate 200 in 1 entity (1 chest)`; `limit` 1..64 (default 16), `more`, and a note pointing at `item=NAME` | `tests/stock.lua` |
| `./shot` never delivers | "not delivered within 20 s" in shake1 and shake2 | (1) `start-team.sh` never started `tools/shot-sync.sh`; (2) a bot has no client, so `take_screenshot` got `by_player=nil` and every connected director rendered it into its own folder; (3) shot-sync watched `<ws>-client` folders, which team runs do not have | runtime: a bot's screenshot is rendered by the first connected director (else the first connected player), the reply names it (`client:`), no client is an error. `./shot` asks for `script-output/pog/<ws>/<name>.png`, makes the name path-safe, prints fh's error when the request fails, waits 30 s and names the client on a timeout. `shot-sync.sh RUN_DIR CLIENT_DIR...` routes `pog\<ws>\*.png` to `RUN_DIR/<ws>/shots/`, copying a file only once it was listed on an earlier pass. `start-team.sh` starts it for `<world>-client-cam1..3` (its pid goes in `stream-service.pid`, so `stop-team.sh` stops it) | `tests/bots.lua` (director chosen, player keeps own client, none connected fails); `tools/test_shot_sync.py` (fake ssh/scp box; the generated `./shot` wrapper with a fake `bin/fh`) |

Survival rules are unchanged. Shooting used real ammo before and after; the change only reports it, and a shoot with
empty ammo slots now fails instead of standing there. Screenshots render the bot's own position, which the bot keeps
charted.

## What players should do differently

- `./fh call inventory` works; it is a read and does not interrupt a running action.
- `./fh observe --args '{"scope":"stock"}'` lists what the factory holds; add `"item"` for places and a collect line.
- After `shoot --wait`, read `ammo_used` and the `inventory:` line (it includes the ammo slots now). `out_of_ammo` ends
  shooting early and exits nonzero.
- `grep '"name": "build"' describe.json` and `grep '"build"' describe.json` both return the action's line.
- `./shot NAME` is worth trying again in team runs once shot-sync runs; its failure message now names the client.

`agent/PLAYBOOK.md` is unchanged (eng/board edits the docs side); its "Look:" line could list `./fh call inventory`.

## Files touched

Harness (`vendor/factorio-harness`):
- `host/cli.ts`: `carried()` helper; `brief()` takes the action and reads `last_combat` for shoot; `ammo_used`; the
  `before` read uses `carried()`. Small hunks around `inventoryChange`, `brief` and `execute`.
- `mod/agent-harness_0.1.0/runtime.lua`: `stop_combat`, describe entries (shoot, inventory, stock), `handlers.inventory`
  (after `handlers.status`), `screenshot_client` + `handlers.screenshot`, `handlers.shoot`, the `reads` set,
  `construction_module{... real=real ...}`, one line in the combat loop of `M.tick_body`.
- `mod/agent-harness_0.1.0/construction.lua`: one line in `mark_obstacles`.
- `mod/agent-harness_0.1.0/kite.lua`: exports `ammo_count`.
- `mod/agent-harness_0.1.0/stock.lua`: `M.summary`, start of `M.view`.
- Tests: `tests/cli.test.ts`, `tests/construction.lua`, `tests/stock.lua`, `tests/bots.lua`, `mod/tests/runtime_test.lua`.

Outside the harness (the describe.json and ./shot bugs live there):
- `tools/describe-lines.py`, `tools/test_describe_lines.py` (new)
- `tools/shot-sync.sh` (new interface: `RUN_DIR CLIENT_DIR...`; the old `WS[=CLIENT_DIR]` form is gone, nothing called it)
- `tools/new-run.sh` (the `./shot` wrapper only), `tools/start-team.sh` (starts shot-sync), `tools/test_shot_sync.py` (new)
- `docs/SETUP.md` (the screenshot gotcha line)

Merge notes: eng/board (error lines) may also touch `host/cli.ts`; my hunks there are confined to `brief()` and the
inventory diff. eng/harness2 (cameras, name tags) works in `cameras.lua`/`profiles.lua`; I did not touch them and only
call `M.is_director`. I did not append to `docs/HARNESS-CHANGES.md` to keep merges small; this file is the record.

## Tests

- `npm test`: 90 pass, 4 fail. The 4 are `tests/bridge.test.ts` tests that open a Unix socket under `.cache/`; this
  session's sandbox refuses it (`listen EPERM`). They failed the same way before my first change (89 pass, 4 fail at
  780345f) and do not touch my code.
- Every `tests/*.lua` and `mod/tests/*.lua`: pass.
- `python3 tools/test_describe_lines.py`, `python3 tools/test_shot_sync.py`: pass.

## Live verification (to run; this session could not)

Run from the repo root on eng/harness3. Deploying replaces the runtime the other engineers loaded on `live`; their next
deploy replaces it again.

```sh
cd vendor/factorio-harness && npm run build && cd ../..
POG_WORLD=live bin/fh deploy
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","h3-a"))'

# inventory: main/guns/ammo/armor, free=N/M
POG_WORLD=live bin/fh --bot h3-a call inventory
# stock without an item: items list (empty note on a bare world)
POG_WORLD=live bin/fh --bot h3-a observe --args '{"scope":"stock"}'
# shoot: the bot starts with a pistol and 10 magazines; expect "action: shoot", ammo_used, and an inventory line with
# firearm-magazine-N when there was something to hit (0 used with no target in range)
POG_WORLD=live bin/fh --bot h3-a call shoot --args '{"auto":true,"ticks":120}' --wait
# construct over a tree: find one, place a ghost on it, construct; expect no PlayerIdentification error, mined>=1
POG_WORLD=live bin/fh --bot h3-a call nearest --args '{"type":"tree","limit":1}'
# TX,TY: the tree's position rounded to whole numbers (a stone furnace is 2x2; the bot starts with one)
POG_WORLD=live bin/fh --bot h3-a call place_ghosts --args '{"entities":[{"name":"stone-furnace","position":{"x":TX,"y":TY}}]}'
POG_WORLD=live bin/fh --bot h3-a call construct --args '{"area":{"left_top":{"x":TX-2,"y":TY-2},"right_bottom":{"x":TX+2,"y":TY+2}}}' --wait
# screenshot: needs the live director client connected (D:\pog\inst\live-client-director); expect "client: pog-director"
POG_WORLD=live bin/fh --bot h3-a call screenshot --args '{"path":"pog/h3-a/t1.png"}'
mkdir -p runs/h3test/h3-a/shots && tools/shot-sync.sh runs/h3test live-client-director   # Ctrl-C after t1.png arrives
ls runs/h3test/h3-a/shots/
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_remove","h3-a"))'
```
