# Harness requests from shakes 7 and 8 (branch eng/requests, REQUESTS.md)

Each request was reproduced in the Lua tests, fixed in the tool and tested. Runtime-only (no control.lua change), so
`fh deploy` can install it into a running shift; the locals guard passes. Answers are written for the operator to
post on each item (`tools/harness-requests.py answer`).

## #69 astra: transfer with keep and up_to near the cap

Cause: `move_stacks` counted down what was left to move and stopped only at exactly 0. An engine slot that took more
than asked (merging a stack) left the count negative, and the next `transfer_stack` got that negative amount: "Given
amount value(-1) too small". Fixed: the count stops at 0 and the reply reports what the engine moved; a target already
at `up_to` moves 0 and says `at_up_to: true`. Test: `mod/tests/runtime_test.lua` (a slot that takes 3 more than asked;
before the fix the next call got -3).

Answer: "Fixed: transfer never hands the game an amount under 1 now; when keep or up_to leave nothing to move it
returns transferred=0 (with at_up_to=true when the target is already at up_to) instead of failing."

## #124 astra: transfer into an empty rocket refused while the silo's automatic requests were on

The game fills a silo's rocket for the platforms' requests and takes no cargo by hand while the silo's automatic
requests are on (`use_transitional_requests`), empty rocket or not. The harness does not switch that setting behind an
agent's back; the refusal now says why and how: `entity_full.auto_requests: true` and a note naming `launch {position,
auto_requests=false}`. Test: `mod/tests/runtime_test.lua`.

Answer: "The silo refused because its automatic requests were on (the game loads the rocket only for platform
requests then). transfer now says so in entity_full (auto_requests, note). Turn them off with launch {position,
auto_requests=false}, then transfer and launch with platform=..."

## #68 opus: assembling-machine-2 built over an assembling-machine-1 left both

shake5's fix (06:50 today) already refused that build for bots (they always place directly, where create_entity
skips the fast-replace the placement check allows). Now the build replaces the machine, as a player's build does, when
the new one is on the same centre with the same footprint: the old machine and its contents go into the inventory, its
recipe is set on the new one, and the result says `replaced: {name, recipe, recipe_kept}`. No room in the inventory for
the old machine, or an overlap that is not on the same centre, is refused and nothing changes. Test: `tests/bots.lua`.

Answer: "build assembling-machine-2 on an assembling-machine-1's centre now replaces it like a player's build: the old
machine and its contents go to your inventory, its recipe carries over (result: replaced). Off-centre overlaps and a
full inventory are refused."

## #89 sol: grenades and capsules

New action `use_item {item, position}` (capsules.lua). It throws a capsule you hold (grenade, cluster grenade, poison or
slowdown capsule, defender/distractor/destroyer capsule) at a position in sight: the capsule's own projectile (or
stream) from its capsule action, created from the character as its source, so the game's effects, damage and kill
credit apply. The item prototype's range, minimum range and cooldown are enforced (cooldown per character), one item is
used, and the reply says kind, projectile, distance, range, cooldown_ticks and left. `use_item {item: "raw-fish"}`
uses a capsule on yourself (heal). Other capsule kinds (cliff explosives, remotes) and non-capsules are refused with
the reason. Bots have no LuaPlayer cursor, so every agent throws this one way rather than with use_from_cursor. Test:
`tests/capsules.lua`. Live check: hold 2 grenades and throw one at a biter 10 tiles away (`fh call use_item --args
'{"item":"grenade","position":{"x":X,"y":Y}}'`): it flies and explodes, one is used, a second call within half a
second says cooling down. Check the projectile names the game uses (taken from the prototype's action, with the item
name as the fallback).

Answer: "New: use_item {item, position} throws a grenade or capsule you hold (the game's own projectile, its range and
cooldown; out of range and cooling down are refused with the numbers); use_item {item: \"raw-fish\"} heals you."

## #144 sol: platform foundation tiles

`deconstruct {area, tiles}` marks tiles as a planner in tile mode does: `tiles: true` (every minable tile in the area)
or tile names (`["space-platform-foundation"]`), on your platform with `platform`. Each tile goes to the engine
(`LuaTile.order_deconstruction`); the reply counts tiles_marked, tiles_already, tiles_refused by reason
(under_entity, engine, not_minable, error) and tiles_blocked (marked tiles under an entity that is not marked, named
in a note: robots take a tile once what stands on it is gone). With `tiles`, entities are marked only when
entity_names or entity_types name them; without `tiles` nothing changed. `cancel_deconstruction {area, tiles}` clears
tile marks. Tile queries are capped at 16,384. Tests (written by a helper session, implementation here):
`tests/blueprints.lua`. Live check: on a platform, mark a 2x2 of bare foundation at the edge and watch the hub's
robots take it; mark one under a chest and see under_entity or tiles_blocked.

Answer: "New: deconstruct {platform, area, tiles: [\"space-platform-foundation\"]} (or tiles: true) marks platform
tiles as a planner does; the reply counts marked, refused (and why) and tiles blocked by an entity on them;
cancel_deconstruction takes tiles too."

## #57 astra: move_to into an attacked area, kite stopping at low health

- `move_to {position, combat: true}` (or a radius 1..32, default 20) fires at enemies in range while walking, as
  `shoot {auto: true}` does, and stops firing when the walk ends (`last_combat.outcome: move_ended`, `ammo_used`).
- `kite {retreat: {x,y}}`: below min_health or out of ammunition the character walks to the retreat point, still
  firing at units in reach while ammunition lasts, and ends `retreated` there (before, it stopped where it stood).
- Every kite end says why in words (`last.why`: "health 36% fell below min_health 40%; retreating to (-20,0)", "out
  of ammunition", "no enemies left within the scan radius", "time up"), with ammo_left, enemies_left and
  retreated_from.

The retreat walks straight (as kite always moves), not by pathfinder. Tests: `mod/tests/runtime_test.lua`. Live
check: kite a few biters with retreat set behind the wall and min_health 0.9; it should turn and walk back firing.

Answer: "move_to now takes combat=true (fires at enemies in range while you walk, until you arrive); kite takes
retreat={x,y} (low health or no ammo walks you there still firing) and every kite end says why, with ammo and enemies
left."

## #167 astra: construct leaves tree blockers behind after ghost placement

Cause: `mark_obstacles` (place_ghosts and construct) searched an area 0.05 tiles inside the ghost's footprint. A tree
whose collision box only reaches the ghost's edge (tree-08 at (-80.9375,3.25) by the belt at (-81.5,2.5)) lies outside
that area, yet the engine counts the touching edge as blocking; it was never marked, construct tried the belt twice and
reported it failed. Fix: every tree or rock whose box reaches the entity's placement box (its collision box at the ghost,
edges touching included) is marked and mined first. When a build still fails, construct looks 0.3 tiles further, marks
and mines what it finds and builds again without spending a try. The result lists `blockers` (name, position, the
ghost and where, cleared), a ghost left blocked names the blocker and its position, and the compact `--wait` reply now
shows construct's built, mined, missing, failed and blockers (it showed only the outcome). Tests:
`tests/construction.lua` (a tree touching the edge; one the plan misses that the build bumps into; one that cannot be
mined), now part of `npm test`; `tests/waits.test.ts` (the compact reply). Live check: place a belt ghost beside a
tree whose trunk edge meets the tile and run `construct --wait`: the tree is mined and the belt built, and
`blockers` names the tree.

Answer: "Fixed: construct marks and mines trees and rocks whose box only touches a ghost's edge, and when a build still
bumps into one it mines that blocker and builds again; the --wait result lists blockers with their coordinates (and
built, failed, missing)."

## Deploying

Runtime only, no control.lua change; the locals guard passes. `fh deploy` during a shift is safe for running agents:
existing arguments behave as before, except build over a same-group machine (now replaces instead of refusing). The
new arguments and `use_item` appear in `./fh describe` at once; the agents' `describe.json` is written at launch, so
running agents see them only through describe or the answers above. `npm test`: everything passes except the 6 tests
that need a listening socket (bridge and broker), which this sandbox refuses.
