# Harness changes, 2026-10-10 (branch `pog-eng`, uncommitted)

All changes live in `factorio-harness/` (working tree only). Lua changes were hot-deployed to the dev world `live` and exercised there; the CLI was rebuilt with `npm run build`. Tests: `lua mod/tests/runtime_test.lua` (657 assertions), `lua tests/*.lua`, and `npm test` (57 pass; the 4 `bridge.test` cases fail only because this sandbox refuses Unix sockets, unrelated to these changes).

## 0. Fake-engine test for `clock.lua` (turn mode)

Problem: turn mode (`clock.lua`) had no unit test.

Change: `tests/clock.lua`, wired into `tests/lua.test.ts`. Covers: realtime never pauses; turns pauses at once when idle; an active action, combat, a running queue (pending, current, or loop) unpause through `after_dispatch` and the tick handler pauses again when they end; `advance` runs exactly N ticks and then pauses, with `until_crafted` ending early when the hand queue empties; a busy character keeps time running past an advance; switching to realtime unpauses and forgets a pending advance; argument validation.

Verified: `lua tests/clock.lua` passes; `npm test` runs it.

## 1. `build` says why placement failed, and works while the clock is paused

Problem: Fable (baseline b): "`build` failures give no reason; `place_ghosts` does." Both turns1 players: "Direct build repeatedly said blocked but same ghost+construct succeeds" (a) and "`build` kept failing with 'placement blocked' even on clear ground; `place_ghosts` + `construct` works every time" (b).

Findings on the live world: (1) the reason was missing; (2) the "clear ground" failures are real and caused by turn mode: the engine refuses every `can_build_from_cursor` / `build_from_cursor` while `game.tick_paused` is set, which is the state between actions in turn mode. The same build at the same spot succeeds in realtime mode.

Change (`runtime.lua`):
- `placement_error` (shared by `build`, `build_direct` and `place_ghosts`) names what is in the footprint: entities/ghosts with positions, the character itself ("the character standing on the footprint (move off it first)"), water/space tiles (with a landfill hint), and a hint when trees/rocks/cliffs are there ("mine it, or place_ghosts (marks it) + construct (clears it)"). When nothing is found it says so and suggests checking the centre/direction.
- While `game.tick_paused` is true, `build` places directly through `surface.create_entity` (the path already used in map view and for underground belts) instead of cursor building. The cursor is never touched.

Verified live (turn mode, paused): build on own tile → "placement blocked by the character standing on the footprint (move off it first)"; on a tree → "placement blocked by tree-02 (-46.19,-39.5); mine it, or place_ghosts (marks it) + construct (clears it)"; on clear ground → before the fix "placement blocked (nothing found in the footprint ...)", after the fix a wooden chest was placed (unit 68). Unit tests: reasons for tree+character, water tiles, nothing found; paused build goes direct and never calls the cursor API.

Playbook: read the `build` error; it now names the blocker. If it names a tree or rock, use `place_ghosts` + `construct` (construct clears them) or `mine` it. If it names the character, step aside first. Direct `build` now works in turn mode.

## 2. `--wait` timeouts are unmistakable, follow the action's end tick, and `fh wait` exists

Problem: Astra: "`--wait --wait-timeout60000` may return a status snapshot while long construct is STILL active. The helper did not enforce completion and subsequent movement interrupted those builds twice." Also: "transfer --wait also returned immediately for awaiting_craft."

Change (`host/cli.ts`):
- The default wait now lasts until the action's own `until_tick` (ticks/60 s, +25% and 5 s margin; at least 30 s, at most 15 min). An explicit `--wait-timeout MS` still caps it.
- A timed-out wait returns `ok:false`, `error.code=wait_timeout` with the message "X is STILL RUNNING: the wait gave up after N s but the action has not finished (up to M s more, until tick T). A new character action would interrupt it. Keep waiting with 'fh wait', or check 'fh call status' (active) ...". The result carries `timed_out: true`, `still_running` (the active block) and `accepted`, and no `completion` any more, so a wrapper cannot mistake it for a finished action.
- New command `fh wait [--wait-timeout MS]`: blocks until the character has no active action and no combat, exits 0 with `idle:true` and `last` on a successful outcome, nonzero (`action_interrupted`) on a bad one, and the same `wait_timeout` shape if still running.
- `--wait` on `transfer`/`refuel`/`rearm` whose reply says `awaiting_craft` now waits for the pending feed to land.
- `wait_until` and `feed` (radius) are waitable.

Verified: CLI tests for the compact and JSON timeout shapes, `fh wait` success/failure/timeout, and the awaiting-craft transfer wait. Live: `fh call wait_until ... --wait` ran to its own timeout and exited nonzero with the last outcome.

Playbook: `--wait` now normally outlives the action, so a nonzero exit means the action failed or is still running; look at `error.code`. If it is `wait_timeout`, run `fh wait` (never a new move/mine/build) until it reports `idle`.

## 3. `collect` leaves feed chests alone

Problem: Astra: "Important: collect radius takes feed chests too! Collect plates with explicit furnace positions and transfer, not broad collect around science." and "Broad collect included science feed chests and accidentally removed their inputs."

Change (`runtime.lua`, `stock.lua`): both forms of `collect` default to machine outputs only (furnace, assembling-machine; the radius tour also cargo landing pads). Plain chests (`container`, `logistic-container`) are taken from only when their `positions` are given, when `types` lists them, or with the new flag `chests: true`. The in-reach form reports `chests_skipped` and a note; the radius form reports `left_in_chests`. The stock hint on `craft`/`construct` ("collect item=X radius=N chests=true gathers it") adds `chests=true` when the stock sits in chests.

Verified: unit tests (a stocked chest in reach is skipped by default, taken with `chests=true` or by position; the tour skips the chest and reports what it left); `tests/stock.lua` updated. Live: a radius collect reports `places: 0` with no chest involved.

Playbook: `collect` without positions never empties your chests now. To empty a chest, name its position or pass `chests: true`.

## 4. `feed` action

Problem: Fable: "A `feed` action: distribute items from inventory to all machines with a given recipe in reach (by recipe ingredients) ... Hand-feeding was ~60% of all calls." Astra: "relied too long on manual fuel and plate rounds."

Change (`runtime.lua`): `feed` gives each machine what it takes by hand: an assembler/furnace its recipe's item ingredients (an idle furnace its previous recipe's), a lab its science packs (`lab_inputs`), a burner (furnace, drill, boiler, burner inserter, burner generator) its fuel. Arguments: `count` (per ingredient/pack per machine, default 20), `fuel` (default coal, `false` to skip), `fuel_count` (default 10), `keep` (reserve kept in inventory), `items` (only these), `types`, `positions`, or `radius` + `ticks` for a walking tour (nearest-first through every machine that wants something you hold, ending early with `out_of_items` once nothing wanted is left; outcomes `topped_up | nothing_to_do | out_of_items | timed_out`; `last` reports `given`, `visited`, `items`). Nothing is taken out. Returns `transferred`, `items`, per-entity `gave`, `unchanged`, `held`.

Verified: unit tests for the in-reach feed (fuel/ore/science with reserve, filters, errors) and the radius tour. Live: `feed radius=30 --wait` walked to the furnace and gave it the 6 iron ore held (`given: 6, outcome: topped_up`; inspect showed 3 → 9 ore).

Playbook: after a supply run, stand near the line and call `feed` (or `feed radius=20` to walk the line) instead of one `transfer` per machine; set `keep` to hold back what you need for crafting.

## 5. `inspect` shows inserter tiles and fluid connection points

Problem: Fable: "`inspect` should show fluid connection tiles and inserter pickup/drop tiles for existing entities."

Change (`runtime.lua`): inserters already reported `pickup`/`drop` tiles; `inspect` now adds `io` ("pickup -> drop" with the entity found at each tile, as `scan fields=io`). Any entity with fluidboxes gets `fluid_connections` (per connection: `box`, `flow`, `at` tile, `joins` tile, `direction`, `fluid`, `connected_to` entity name, `underground_reach`) and `fluids_summary` (the `scan fields=fluids` string).

Verified: unit test with an inserter over a belt and an offshore pump joined to a pipe; live inspect of a furnace unchanged (no fluid fields, no error).

Playbook: before placing a pipe or pump next to a boiler/engine, `inspect` it and use `fluid_connections[].joins` as the pipe tile.

## 6. `wait_until` from the CLI

Problem: Fable: "`wait_until researched|item_count` usable from the CLI with --wait (not only inside a queue)."

Change (`runtime.lua`, `scheduler.lua` schema): `wait_until` is also a direct timed action (same conditions and `timeout`, checked every 10 ticks). Met already → returns `outcome: met` at once; otherwise an active `wait_until` action (status shows `condition` and `saw`) ending `met`, `timed_out` or `failed`. In turn mode the clock runs while it waits. `fh call wait_until --args '{"until":"researched","technology":"automation"}' --wait` works.

Verified: unit tests (met at once, met after ticks, timed out, validation); live wait on `item_count` ran its 300 ticks and reported `timed_out` with `saw: iron-plate 0`.

Playbook: use it to let a furnace/lab/research run without polling: `wait_until crafting_done`, `item_count`, `researched`.

## 7. `pole_route`: a pole line from A to B

Problem: Fable: "A one-call 'lay power poles from A to B' helper so the lab site could have been connected to the ore field." Astra: "Pole chain planned x=27.5 down to -49.5 step -7 ...". `build_path` is belts only.

Change (`runtime.lua`): `pole_route {from,to,waypoints?,item?,spacing?,dry_run?}` places pole ghosts along straight legs, spaced within the pole's wire reach (read from the prototype; default spacing leaves room for a 2-tile sideways shift: small 7, medium 8, big 29), shifting a blocked spot up to two tiles sideways, reusing own poles/ghosts already on the line, and reporting `poles`, `held`, `short` (craft that many), `failed` (with placement reasons), `bounds`. Trees under the ghosts are marked, so `construct` (default area = these bounds) clears them and builds the line; each built pole auto-wires to networks in reach (existing `build` behaviour).

Verified: unit test (even legs, reuse, sideways shift, held/short, errors); live dry run and real placement of 5 small-pole ghosts across 28 tiles of trees (1 obstacle marked), then removed.

Playbook: `pole_route from=<powered pole> to=<target>` then craft the `short` count and `construct --wait`.

## Also

- `research` with no arguments reports `current`, `progress`, `queue`, `pending` instead of "unknown technology" (Fable: "The in-game `research` call with {} errors"). Unit test; live check.
- A fuel transfer refused because the slot holds another fuel (Fable: "`transfer` of coal into a boiler holding wood is refused (entity_full blocked_item=coal)") now adds `entity_full.holding` and a note: "the fuel slot holds wood; one fuel type at a time: let it burn out or take it out first (transfer to_player item=wood)". Unit test.
- `mine` on something the engine will not hand-mine (turns1 a: "Stumps can block placement and mine reports inventory_full despite 72 free slots") now ends `not_minable` with `last.error` naming the entity, and keeps `inventory_full` for the no-room case. Unit tests for both.
- `fh queue submit --file` with a JSON object instead of an array (turns1 a: "Queue file is a bare array of steps (object silently submitted no steps)") is now rejected before contacting the game. CLI test. The related note "`fh queue submit` alone does not run time" (turns1 b) did not reproduce: a submitted plan unpauses the turn clock and `fh wait` saw it finish; the object-shaped plan is the likely cause.
- `docs/usage.md` updated for the wait semantics, `fh wait` and direct `wait_until`.

## Ready to merge / left over

Ready: everything above; all Lua and CLI tests pass (`npm test`: 57 pass, 4 bridge-socket tests blocked by the sandbox); the live world runs the final deployed runtime. Nothing is half-done.

Not addressed from the notes: `cancel_craft` of one recipe seeming to drop other queued crafts (not reproduced); a placement preview that checks pole coverage / inserter reach / belt gaps before construction (Astra's request 3; `scan fields=io|fluids` and the new `inspect` fields cover the inspection half); a screenshot that follows the controlled character (headless server; out of scope for the runtime).

Note for the merge: `runtime.lua` is close to Lua's 200-local limit in the bundled chunk (a deploy was rejected once during this work); new helpers were grouped into tables (`feeding`, `collect_types`) to stay under it. Future additions should do the same or move into sibling modules.
