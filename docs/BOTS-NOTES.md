# Bots, profiles, speech bubbles, cameras: engineering notes

Branch `eng/bots`. Implements the Bots, Profiles, Speech bubbles and Cameras sections of `docs/BOTS-API.md` in
`vendor/factorio-harness`. User-facing usage is in `vendor/factorio-harness/docs/usage.md` ("Bots" and
"Profiles, speech bubbles, cameras").

## What was built

New Lua modules (runtime.lua only gained `M.bots`, `M.profiles`, `M.cameras`, `M.lookup`, `M.active` and one local):

- `bots.lua`: bot records in `storage.agent_harness.bots`, creation/removal, the player proxy, death and respawn,
  sight (charting), spawn slots, cursor-free tiles, corpse pickup, scripted repair.
- `profiles.lua`: `profile` and `profiles` actions, speech bubbles.
- `cameras.lua`: director cameras, eased every tick.

Wiring:

- `control.lua`: requests accept `bot` (name, validated; not together with `player`). Operator-only remote functions
  `bot_create`, `bot_remove`, `bots`, `camera`, `cameras`, `profile_ticks` (all return JSON, errors as
  `{ok:false,error:{code:"operator_failed"}}`). `profiles` and `cameras` are read-only. A failed request for an unknown
  bot stops nobody (a request without `player` or `bot` still means player 1).
- `runtime.lua`: a bot name becomes its index (1000000+n) at the top of `dispatch`; from there bots go through the same
  handlers, active-action table, queues, clocks and chat cursors as players. `player(index)` returns the bot proxy;
  cleanup paths use `M.lookup(index)` instead of `game.get_player`.
- `chat.lua`: `say` draws the bubble (decoration only, never fails the message); people typing in chat get one too.
- `clock.lua`: `advance until_crafted` resolves bots.
- `blueprints.lua`: a bot pastes with `build_blueprint` (no cursor; flips refused).
- CLI: `fh --bot NAME` and `FH_BOT`, exclusive with `--player`.

### How the proxy works

`bots.proxy(record)` is a table whose metatable answers player-only fields itself (`index`, `name`, `valid`,
`connected=true`, `controller_type=character`, `cheat_mode=false`, `permission_group=nil`, `chat_color`/`color` from
the profile, no-op `create_local_flying_text`/`print`, and `position`/`surface`/`force` that still work while dead)
and forwards everything else (LuaControl: walking/mining/shooting/picking state, inventories, crafting, reach,
`mine_entity`, `cursor_stack`, ...) to the character entity. `real(p)` returns nil for a bot, so engine calls that
take a player get none.

### Engine behaviour that differs for a character without a player (found live)

| Behaviour | Player | Playerless character | What bots do |
|---|---|---|---|
| Keeping nearby chunks visible | yes | no | chart ±48 tiles once a second, staggered across bots |
| `mine_entity` on a character corpse | moves items | **segfaults the server** (crash at tick 16308 in the first test world) | move the corpse's items to the inventory, destroy it when empty |
| `repair_state` | repairs | ignored | heal `speed/2` HP per tick from the held tool (repair pack: 60 HP/s), drain the same durability |
| `clear_cursor` | returns cursor to inventory | does nothing | insert the cursor stack back into the main inventory |
| Cursor building (`build_from_cursor`) | LuaPlayer only | n/a | direct placement (existing path: item consumed, reach and placement checked); tiles by `set_tiles` with the item's placement condition |

Walking, pathfinding, hand crafting, timed mining (rocks, ore, buildings with contents), picking up items,
shooting and taking damage work natively.

### Spec decisions to check (overlay side)

- Respawn inventory: a respawning bot gets the freeplay respawn items (pistol + 10 magazines) when the freeplay
  interface exists, because that is what a respawning player gets. The spec says "an empty inventory like a player";
  if empty is wanted, change `items('respawn')` in `bots.lua` to return `{}`.
- Respawn place: the bot's own spawn slot (rings around the spawn point, 12 per ring, 4 tiles out then +3 per ring,
  at least 2 tiles from any other living bot; obstacles like the crash site push to the next slot).
- `bot_create` also returns `index`; `profiles` rows add `connected` (players) and `dead_until_tick` (bots); `status`
  for a bot adds `deaths`. A bot's interrupted action reports outcome `died` (or `removed`).
- `cameras` with no cameras serializes as `{}`, not `[]` (Factorio's `table_to_json` on an empty table).
- Directors: a player becomes a spectator on its first `camera` call and its character is destroyed (starter items
  lost, nothing gained). Attached agents (`attach`) are refused. `profiles` skips cameras and any spectator player.
- `chat` with `peek:true` now works for a player without a character (directors, overlay polling as player 1).
- `say` bubbles: scale 1.4 in world units, fixed size (not zoom-scaled), up to 6 lines of 40 characters.

## How it was verified

Fake-engine tests (all wired into `tests/lua.test.ts`):

- `tests/bots.lua`: creation rules and starting items, dispatch by name, actions keep separate state per bot and
  player, direct building, profiles validation (colour, emoji/ZWJ glyphs, lengths), bubble wrap/replace, `profiles`
  rows, cameras (spectator once, easing, jumps, release, attached refusal), director chat peek, death/respawn timing
  and items, corpse pickup without `mine_entity`, scripted repair and cursor return, removal, turn clock, nine bots
  spread at least 2 tiles apart around an obstacle, staggered charting, `profile_ticks`.
- `mod/tests/control_test.lua`: `bot` validation, unknown bot stops nobody, operator calls.
- `tests/cli.test.ts`: `--bot`, `FH_BOT`, exclusivity and name check.
- `npm test`: 62 pass. The 4 `bridge.test.ts` tests fail in this sandbox with `listen EPERM` on their unix socket
  before any test code runs (environment, not code; unrelated files).

Live, world `live` (fresh map `bots1`, peaceful, director client `pog-director`):

- `bot_create` for astra, sol, luna, opus, sonnet, haiku, grok, gemini, muse; invalid and duplicate names refused.
- Per action as a bot: walk, move_to (pathfinding), craft (gears appeared, plates consumed), mine rock (20 stone),
  mine ore (2 ore in 300 ticks, 2.7-tile resource reach like a player), build furnace and burner drill on ore, feed
  fuel, rotate, mine a fuelled furnace (contents returned), place_ghosts + construct, queue (two walks, both
  `duration_elapsed`), pickup of drill output, transfer, research, shoot with `auto` at biters (1 magazine spent,
  3 biters killed, then grok died), repair (130 to 200 HP, pack returned), say, profile, chat, screenshot.
- Second pass: smelt bricks from mined stone, `collect` tour with radius (bricks), tiles (`stone-brick` size 2:
  4 consumed, `stone-path` with the old tile as hidden tile; a repeat is refused), `belt_route` + `construct`
  (`E4`, 4 belts built), `blueprint_capture` + `paste` (4 ghosts) + `deconstruct` of the ghosts, `kite` (ended
  `low_health` with ammo used, as designed), `refuel` tour (`topped_up`), `cancel_craft` (plates refunded), copper
  ore mined and smelted and `collect` from the furnace, `pole_route` dry run.
- Bubble lifecycle in the engine: a 3-line bubble, then a new `say` left 1 render object, 0 after 8 s.
- Death: killing the character ended the action with `died`; `status` showed `dead_until_tick` and `deaths`; actions
  were refused while dead; respawn after 600 ticks at the spawn slot with pistol and magazines; the corpse held the
  full inventory. After the crash fix, gemini mined a removed bot's corpse: all items moved, corpse gone.
- Bubbles: screenshot from the director client shows the wrapped text in the bot's colour above it.
- Cameras: follow (director position matched the bot, controller spectator, no character), position mode with
  `smooth=false`, zoom validation, release, `cameras` read; a desktop screenshot showed the director window
  following haiku with its bubble.
- Turn clock: in `turns` mode a bot's walk unpaused the game and it paused again when the walk ended.
- Cost: `profile_ticks` with nine bots: 0.046 ms per harness tick idle, 0.265 ms with all nine pathfinding at once;
  server held 60 UPS.

## Known gaps

- Not exercised live: rearm, pipe routes, placing pole routes, equipment, wire (small poles need the electronics
  trigger tech, not reached on the test map), research completing in a lab, configure. They use the same proxy and paths as the tested actions, but a playerless-character quirk like the
  corpse crash could still hide in one of them.
- A bot's death shows up in other agents' `losses` lines as a destroyed `character` (the existing loss tracker counts
  every own-force entity; a player's character death already did the same).
- Repair rate (speed/2 HP per tick) is my reading of the game's rate, not measured against a player.
- Sight is charted by script (±48 tiles). A bot that just arrived in uncharted ground may see "outside local visible
  area" for up to ~1.5 s (charting is asynchronous: about 40 ticks to visible).
- Bots have no cursor ghost or selection; `selected`-based behaviours are not used for them.
- `auto_pause` stops the server with no client connected; bots need a connected director (or `auto_pause=false`).
- Bot death detection is polled every tick (no new event needed); a removed bot's corpse stays in the world.
- Vehicles, space platforms and riding rockets are untested for bots (vehicles are unsupported for players too).
- After a `control.lua` change on an existing save, the director client's mod folder must be refreshed too
  (`scp` the mod into `D:/pog/inst/live-client-director/mods/`), or the join fails with `multiplayer.script-mismatch`.
