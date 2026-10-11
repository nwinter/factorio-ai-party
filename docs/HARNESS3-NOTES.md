# Harness3 notes: the shake2 harness bugs (branch eng/harness3)

Round 4 (shake3 fixes, for shake4) is the next section; the shake2 round follows it.

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
