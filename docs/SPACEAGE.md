# Space Age: feasibility and plan

Branch `research/spaceage`, 2026-10-10 night. Goal: run the long game on Factorio: Space Age with no end state:
reach the Shattered Planet, make promethium science, then keep raising science output through infinite research.

Summary:

- Access. The server already has what it needs. Only the director clients are blocked: each one must run the
  expansion build of Factorio, and our factorio.com account can't download that build until Nick links the Steam
  account that owns Space Age (steps in section 1). After that the setup stays as it is: N standalone clients, no
  Steam, user verification off.
- Harness. Most of Space Age is already in the harness. It has platforms, hub requests, platform schedules, the silo
  launch, riding a rocket, landing, ghost construction on platforms, quality on build and transfer, and trigger
  technologies. The space parts have only run against fake-engine tests; the core (walking, mining, crafting, building,
  blueprints, combat) passed upstream's real-engine suite with Space Age enabled. The biggest gap: bots (our
  multi-agent architecture) cannot leave Nauvis. I could not run the Space Age world on the box from this session
  (section 2). Tonight's fixes are on this branch: multi-surface score and sparklines, spoilage reads, Space Age
  recipe categories, Gleba plants, no hand-mining of hard-solid ore, the rocket-ride payload rule, bot travel
  refusal, and per-planet peaceful flags. A one-command smoke test is there too.
- Pace and cost. Reaching promethium science needs about 132k–152k science packs. Most of the work, though, is
  building on four more planets. Central estimate: about 90 game hours, 105 wall hours and 370 agent-hours (range
  230–800). With one Astra and the rest Claude agents, that is about 2.8 Codex and 2.6 Claude weekly allowances,
  plus 45–60 engineer agent-hours. That means about three weeks with one allowance of each per week. After that, the
  unbounded phase is a fixed weekly budget (section 4).

## 1. Access

Findings (web research; sources inline; nothing logged in or downloaded):

| Question | Answer | Confidence |
|---|---|---|
| Does the server need anything? | No. The Linux headless build "comes with Space Age content and it is free to download" ([archive 2.0.77](https://factorio.com/download/archive/2.0.77)). On Windows the normal game package is the server ([FAQ](https://factorio.com/faq)). Our server runs `D:\pog\factorio-2.0.77`, a copy of Nick's Steam install. Steam installs the expansion build only when the DLC box is ticked in the game's Steam properties ([forum](https://forums.factorio.com/viewtopic.php?p=657083)); Nick owns it, so the copy should have `data\space-age`. `new-instance.ps1 -SpaceAge` already enables `space-age`, `quality` and `elevated-rails`. | high; check that the folder exists |
| What does a client need? | The expansion build. Wube's download API names the builds `alpha` ("without the space age expansion") and `expansion` ([Download API](https://wiki.factorio.com/Download_API)). A base build refuses the DLC mods ("Mod elevated-rails requires Space Age expansion", [forum](https://forums.factorio.com/viewtopic.php?p=659962)), and a base client joining a Space Age server fails with mismatched mods ([forum](https://forums.factorio.com/viewtopic.php?p=623897)). The check is in the client executable, at mod load. | high |
| Why the 403? | Not documented. Most likely the account behind our token does not own the expansion on factorio.com yet: Steam purchases appear there only after linking. | medium |
| How does a Steam purchase reach factorio.com? | "If you purchased on Steam you will need to link your accounts at the profile page" ([support](https://factorio.com/support/help)). Users report that the expansion download appeared after linking ([forum](https://forums.factorio.com/viewtopic.php?p=646556), [Steam](https://steamcommunity.com/app/427520/discussions/0/4631482745020754557/)). If it doesn't: log out and in, or email support@factorio.com with the username and Steam ID64 ([forum](https://forums.factorio.com/viewtopic.php?p=621001)). | high |
| Three or more clients without Steam? | Yes, as now. The factorio.com build does not use Steam. Our servers run with `require_user_verification = false`, so each client joins under its own `player-data.json` name. Two clients with the same name would kick each other ([wiki](https://wiki.factorio.com/Multiplayer)), which `start-client.ps1` already avoids. I found no per-account limit on concurrent clients. The [terms](https://factorio.com/terms-of-service) license "personal, non-commercial use" and say nothing about running several clients or bots at once; that judgement is Nick's. | medium |
| Can the Steam copy run clients instead? | It restarts itself through Steam. A `steam_appid.txt` next to the exe used to stop that (a Wube developer in 2019, same thread). It is unsupported and untested on 2.0, so don't use it. | low |
| 2.0.77 or 2.1? | Stay on 2.0.77. 2.1 is experimental (2.1.21). It breaks Lua APIs we use (`LuaEntity.fluidbox` removed, `fuel_category` → `fuel_categories`) and changes platforms: drag depends on weight, and characters can't travel to platforms until the first planet research ([2.1.0 notes](https://wiki.factorio.com/Version_history/2.1.0)). | medium-high |

What Nick must do (about 10 minutes; nothing on the box changes until step 4):

1. Log in at factorio.com with the account whose token we use, open the profile page, and link the Steam account that
   owns Space Age ("Link Steam account", or log in once with "Log in with Steam").
2. Check that the download page now offers Space Age, not "Buy". If it doesn't, log out and back in, or relink. If it
   still doesn't, email support@factorio.com with the factorio.com username and the Steam ID64.
3. If the token was regenerated, put the new one where the earlier download used it.
4. Then an engineer downloads `https://www.factorio.com/get-download/2.0.77/expansion/win64-manual` with that
   username and token and unzips it to `D:\pog\factorio-2.0.77-expansion`. Clients start with
   `start-client.ps1 -Factorio D:\pog\factorio-2.0.77-expansion` and keep their own config folders and names as now.
   Nick's Steam install and `%APPDATA%\Factorio` are not touched.
5. Check `D:\pog\factorio-2.0.77\data\space-age` exists (the server copy). If not, run the server from the expansion
   zip as well (point `new-instance.ps1` and `start-server.ps1` at it).

Clients are now needed only for watching: agents play as bots, and only the one to three director clients and any
human player need the expansion build.

## 2. Harness on Space Age Nauvis

### What ran and what didn't

From this session I could not run the world on the box. The sandbox here refuses connections to
<windows-box-ip>:22 ("Operation not permitted"; SSH, `scp` and the RCON tunnel all depend on it), and GitHub downloads
were denied as well. The steps below are scripted so the next session on the Mac with box access runs them in one
pass. No world was created and nothing on the box changed.

What did run, on the Mac:

- `npm test` (TypeScript host): 89 of 93 pass. The 4 failures are the bridge tests, which need a Unix socket that
  this sandbox refuses (`listen EPERM`), not a code fault.
- All 19 Lua fake-engine suites pass (`lua tests/*.lua`, `mod/tests/*.lua`; runtime 684 assertions with tonight's,
  control 66, scheduler 56). That includes `tests/space.lua`, which covers platforms, requests, schedules, launches and landing.
- New fake-engine checks for the score and stream Lua (multi-surface sums, infinite levels).
- A review of every API member in tonight's diff against the 2.0.77 docs. It found one critical bug: `mine`
  read `mining_categories`, which doesn't exist; the field is `resource_categories`. In a real game every ore `mine`
  would have failed, base game included, and the fakes accepted the wrong name. Fixed, along with four minor
  findings. Fakes can't catch this kind of mistake, so run `tools/sa_smoke.py` (and one base-game smoke) before these
  harness changes reach worlds a, b, c, n or live.

Evidence that the harness core works on Space Age: upstream's connected-client integration suite "passed on
**Factorio 2.0.77 with Space Age**" (`vendor/factorio-harness/docs/testing.md`; `FACTORIO_TEST_SPACE_AGE=1`). It
covers observe, crafting, building, mining, walking, blueprints, combat and mech armor with Space Age, Quality and
Elevated Rails enabled. It does not exercise platforms, launches or travel.

### To run on the box (world `sa`, ports 34210/27030)

```sh
tools/winps.sh tools/win/new-instance.ps1 -Name sa -Save sa1 -SpaceAge -Peaceful
openssl rand -hex 16 > ~/.config/pog/rcon-sa.pw && scp ~/.config/pog/rcon-sa.pw pogwin:D:/pog/inst/sa/rcon.pw
tools/winps.sh tools/win/start-server.ps1 -Name sa -Save sa1 -GamePort 34210 -RconPort 27030
ssh -N -L 27030:127.0.0.1:27030 pogwin &
POG_WORLD=sa bin/fh doctor; POG_WORLD=sa bin/fh doctor; POG_WORLD=sa bin/fh deploy
tools/sa_smoke.py                       # log: runs/sa-smoke/smoke.jsonl; exit 1 lists failed steps
tools/pog.py --world sa save && tools/winps.sh tools/win/stop-world.ps1 -Name sa
```

`tools/sa_smoke.py` refuses worlds a, b, c, n and live. It first probes the world with operator Lua: active mods,
space locations, quality levels, crash-site entities near spawn, the freeplay starting items, the state and trigger
type of key technologies (automation-science-pack through promethium-science-pack and research-productivity), key
recipes, which items spoil, and peaceful mode. Then a bot plays a scripted early game: mine stone and coal, craft
furnaces, build a burner drill and furnace on iron, refuel, wait for plates, collect, craft gears, and set and queue
research. Every step is logged as ok or FAIL and the script goes on, so one pass lists everything that breaks. No
director client is needed, because bots play without one. A client only matters for watching, and that waits on
section 1.

### What breaks or is missing (from reading the code against Space Age)

| Area | Finding | Status |
|---|---|---|
| Score (`tools/pog.py score`) | Read only `game.surfaces.nauvis` and base-game packs, so production on other planets and platforms was invisible. | Fixed: sums over all surfaces; adds the six Space Age packs, packs consumed, levels of each infinite technology, planets with our entities, and platforms. Unknown names are skipped, so base-game worlds give the same output as before. |
| Stream sparklines (`tools/stream/harness.py` FLOW_LUA) | Nauvis only. | Fixed: sparklines and the power-starved machine count cover every surface. |
| `bin/fh`, `tools/pog.py` | No world `sa`. | Added (RCON 27030). |
| Bots (`bots.lua`) | Every bot lives on `nauvis`: created there, respawns there, and the record's surface is fixed. `launch ride=true` and `land` call `LuaPlayer` methods, and a bot has no player, so they would have failed with a nil index. | Guarded: both now refuse bots with a clear error. Bot travel is the largest gap (section 3). |
| Platforms, requests, launch, land (`space.lua`) | Present (from upstream), but only fake-engine tested. They assume a real player: `land` uses `LuaPlayer.land_on_planet`, and `ride` uses the player's character. | Needs a real run. |
| Ghost building on platforms | `place_ghosts`, `paste`, `blueprint_place`, `deconstruct`, `grid` and `scan` take `platform=NAME` (hub at 0,0) and work from remote view. `place_ghosts` handles `space-platform-foundation` tiles. | Present. |
| Trigger technologies | `technologies` and `research` describe Space Age triggers (craft, mine, build, `send-item-to-orbit`, `capture-spawner`, create a platform) and never try to research them in labs. | Present. |
| Quality | `build`, `transfer`, `stock`, construction and `rates` take or report quality (default `normal`). Counts are exact per quality: an uncommon gear does not satisfy a `normal` request. | Present; agents need to be told this in the playbook. |
| Spoilage | Nothing read `spoil_percent`. Inventories show counts only (`get_contents()` has no freshness), and `feed`/`collect` ignore freshness. Nothing spoils on Nauvis until biter eggs (captive spawners) or Gleba fruit arrive. | Partly fixed: `status` has `spoiling` ("yumako*15 50%", stalest first) and `scan` has a `spoil` field. Freshness-aware feeding is still missing (section 3). |
| Hand-craft categories | In Space Age the character crafts `crafting, electronics, pressing, recycling-or-hand-crafting, organic-or-hand-crafting, organic-or-assembling`: belts are `pressing`; circuits, cables and poles are `electronics`. The harness reads the character's own `crafting_categories`, so this works, but two places ignored a recipe's `additional_categories`. | Fixed: one shared check for `craft`, the shortfall explanation, the assembler suggestion and `craftable`. |
| Gleba plants | Yumako and jellystem are type `plant`, so `type='tree'` filters miss them. | Fixed: obstacle marking under ghosts, the "clearable" build hint and the chart's tree summary include `plant` when the space-age mod is active. |
| Quality counts | A bare item name in `get_item_count` counts normal quality only ([ItemWithQualityID](https://lua-api.factorio.com/2.0.77/concepts/ItemWithQualityID.html)). The harness uses bare names in 7 places (`wait_until item_count`, lab and recipe ingredient counts). | Correct for recipes, which need exact quality. `wait_until` undercounts once quality items exist; fix when quality starts. |
| Hard-solid ores | `tungsten-ore` (Vulcanus) is `hard-solid`; only the big mining drill mines it, never a character. The harness hand-mines ore through `mine_entity`, which does not check mining categories, so a character could have mined tungsten: a fairness hole. | Fixed: `mine` refuses ores outside the character's `resource_categories` with a clear message. |
| Nauvis recipe and tech changes | `rocket-part` is 1 processing unit + 1 low-density structure + 1 rocket fuel, 50 per rocket; no satellite; the rocket silo needs only red, green and blue packs; `space-science-pack` is a trigger tech (build an asteroid collector); assembling machine 3 needs speed modules. | No harness code names these. Added `agent/spaceage.md`, appended to `AGENTS.md` by `tools/new-run.sh` when `POG_SPACE_AGE=1`: milestones, triggers, platforms by remote view, riding, quality, spoilage. |
| Crash site | The crash-site code in `core/lualib` is unchanged, but whether Space Age freeplay still spawns it and gives the same starting items is unverified (the scenario file is not in the public data). The harness already ignores the wreck's zero-damage fire in the combat detector, and bot spawn rings route around the wreck. | `sa_smoke.py` probes it. |
| Surfaces in reads | Observation reads use the actor's own surface, so they follow a player to another planet. `nearest`/`scan`/`map` stay limited to charted chunks of that surface. | Present. |
| Cameras | Directors follow a bot or player across surfaces (`p.teleport(target, surface)` on a surface change), falling back to the player's position when there is no character. | Present. |

## 3. What Space Age needs beyond Nauvis

API facts below are from the 2.0.77 Lua API docs and the `2.0.77` tag of wube/factorio-data. The "latest" docs and
`master` are now 2.1, which differs. Effort is in engineer sessions of about three hours, like tonight's.

### The fair-play rule for space

A human in Space Age reaches a platform in two ways. Remote view (open from anywhere) lets them place and cancel
ghosts, mark deconstruction, change entity settings, schedules and logistic requests, and read everything. Riding a
rocket puts them in the platform hub. There they are "locked inside the hub and stuck in remote view until they drop to
a planet" ([wiki](https://wiki.factorio.com/Space_platform)). The platform builds its ghosts itself from the hub
inventory, with no robots.

So the fair equivalent of "no character on a platform" is the remote controller's rights. Any agent, wherever its
body stands, may:

- edit a platform with ghosts, blueprints and deconstruction (`platform=NAME` on `place_ghosts`, `paste`,
  `blueprint_place`, `deconstruct`);
- change settings: recipes, filters, schedules and requests (`configure` already falls back to remote entities;
  `platform_schedule`, `requests`);
- read anything on it (`platforms`, `grid`, `scan`).

It may never move items by hand on a platform. Items reach a platform only by rocket, and leave only by cargo pod
drops, or by the game's own construction and deconstruction from the hub. The harness already works this way: "Platforms
are always shown in remote view, so none of this needs the character there" (`space.lua`). Riding a rocket matters only
for moving a body to another planet.

Two wiki pages conflict on whether a rider can open their own inventory in the hub. Until the box shows which is
right, the harness should not allow it. The wiki says a rider takes only "any equipped armor, their installed
modules, and any weapons", and no ammo. The harness now enforces that, together with the silo's "Travel to
platform" rule that the rider is the only payload. `launch ride=true` refuses while the rocket holds cargo or the
character's main, ammo or trash inventory holds anything. This may be stricter than the game; loosen it if the box shows the game keeps the
items safely.

### Per item

| Item | Game mechanics (2.0.77) | Harness today | Needed actions and reads | Fair-play mapping | Effort |
|---|---|---|---|---|---|
| Rockets and cargo pods | 50 rocket parts per rocket; payload limited by weight (1 t, `rocket_lift_weight`), 20 slots. Silo GUI: deliver cargo to a platform in orbit, launch a starter pack, or ride alone. `use_transitional_requests` auto-fills and launches for platform requests. Pods land on the planet's `cargo-landing-pad`, else near spawn as a `cargo-pod-container` (temporary container). | `launch` (cargo to a platform, to orbit, `ride`), silo `auto_requests`, `transfer` into `rocket_silo_rocket` and `cargo_landing_pad_main`, `platforms` lists silos. Fake-engine tested only. | Real-engine test. `ride` sends to `{type=surface, surface=platform}`, which the API says switches to the hub station; `{type=station, station=hub}` is the documented alternative if it misbehaves. (Done tonight: the empty-payload and armor/guns rule.) Transfer from a `cargo-pod-container`. A launch report that follows the pod's state (`cargo_pod_state`, `on_cargo_pod_finished_*`). | Loading the silo needs reach (as now); launching from the silo GUI needs reach or remote view (GUI action); pad requests are settings. | 1–2 |
| Space platforms: create, hub, construction | `force.create_space_platform{planet, starter_pack}` equals the "new platform" button; a silo then delivers the pack (`apply_starter_pack()` would skip that: a cheat). Hub: 59 slots, plus 20 per cargo bay. Ghosts are built from hub items. Foundation must be one connected area; thrusters on the south edge; no chests, burners, robots or rails. | `platform_create` (honest), `requests` on the hub with `import_from`, ghost tools with `platform=`, `grid`/`scan` with `platform=`, `platforms` (state, location, hub items, requests). | Hub drop to planet (`hub.create_cargo_pod()` with items taken from the hub inventory, or the hub's drop slots: which inventory is unverified). Destroyed entities in `status` alerts. Why ghosts stay unbuilt (missing hub items). (Done tonight: `platforms platform=NAME` reports speed, damaged tiles and the unbuilt ghost count.) | Remote-view rights only (above). | 2 |
| Thrusters and routes | Thrusters burn `thruster-fuel` + `thruster-oxidizer` made on board from asteroid carbon, iron ore and ice. `PlatformSchedule` records have wait conditions (time, inactivity, item_count, all_requests_satisfied, any_request_not_satisfied, ...). Interrupts are set through `LuaSchedule` (`get_schedule()`). | `platform_schedule` (stops, waits, pause). | Interrupts. An ETA from `distance` and `speed`. (Done tonight: thruster count and lowest tank in `platforms`.) | Settings only. | 1 |
| Asteroid collection and crushing | Collectors (radius 7.5) pull chunks; chunks are not entities (`platform.find_asteroid_chunks_filtered`). Crushers are `assembling-machine`s (`metallic-asteroid-crushing` → iron ore, `carbonic` → carbon, `oxide` → ice). Asteroids (`asteroid` entities) damage platforms; turrets need ammo made on board. | `configure` sets recipes and filters remotely; `scan` sees asteroids as entities. | Collector filter settings in `configure`. (Done tonight: chunk counts by type in `platforms`.) An ammo and turret read per platform. | Settings only; ammo reaches turrets by inserters, never by hand. | 1 |
| Travel between planets (bodies) | Players: `launch_rocket(dest, character)`, then `LuaPlayer.land_on_planet()` from a platform stopped at a planet. The pod lands at a landing pad if there is one (unverified). | `launch ride=true`, `land` for players (untested). Bots: refused (tonight). All bots live on Nauvis. | Bot travel. First test whether `launch_rocket(dest, character)` accepts a playerless character and what the hub does with it. If not: on launch, keep the bot's armor and weapons in a script inventory and remove the body; the bot then acts with remote-view rights while "aboard". On drop, send a real cargo pod down (`hub.create_cargo_pod()`, destination the planet) and create the body where the pod lands, with those items back. Track `b.surface`; respawn on the last planet (as for players). | Same as a player: real ascent, flight and descent time; only armor and weapons travel with the body; everything else ships as cargo. Re-creating a bot's body is the same act as creating the bot, which we already accept. | 2–3 |
| Other surfaces | Vulcanus: calcite, tungsten (hard-solid), lava, demolishers (`segmented-unit`) in territories; peaceful stops them seeking buildings, but they still roam. Fulgora: scrap and the recycler; night lightning damages metal buildings; oil-ocean islands. Gleba: `plant`s, agricultural towers, pentapods (`spider-unit`, `unit`), spores. Aquilo: freezing (`entity.frozen`), heating towers, ammoniacal ocean. Many planet techs are triggers (mine calcite, craft tungsten plate, ...), which the harness already describes. | Reads follow the actor's surface. Threat reports know biters and spawners. | Per planet in `status` warnings and `threats`: demolisher territories (`surface.get_territories()`), the lightning season and unprotected buildings, frozen machines, pentapod nests. (Done tonight: `mine` refuses hard-solid ores.) Chart summaries that name the new rocks (`big-volcanic-rock`, stromatolites, icebergs, ruins) instead of matching "rock". | Peaceful per planet: `peaceful_mode` is per surface, and a planet's surface is created on first arrival. `tools/pog.py --world W peaceful` (added tonight) copies Nauvis's peaceful and no-enemies flags to every planet surface, a world setting like the map seed. Run it when `score` lists a new planet, or move it into `control.lua` as an `on_surface_created` handler, which needs a mod update on server and clients. Keep enemy bases on Nauvis: the promethium path needs a living spawner to capture (`biter-egg-handling` trigger) and biter eggs. | 1 per planet (4) |
| Quality | Five levels; quality modules from early on; the recycler loops quality. Recipes need ingredients of one quality; `begin_crafting` has no quality parameter. | Quality on build, transfer, stock, construction, rates, requests; exact counts. | `wait_until` and lab counts across qualities; quality in inventory summaries and `stock` totals; `configure` recipe quality (`set_recipe(recipe, quality)`). | No change: quality comes from modules and the recycler. | 1 |
| Spoilage | Gleba fruit 1 h, mash 3 min, jelly 4 min, nutrients 5 min, bioflux 2 h, agricultural pack 1 h, bacteria 1 min; spoiled `pentapod-egg` and `biter-egg` hatch enemies anywhere, inventories and platforms included. | `status.spoiling`, `scan fields=spoil` (tonight). | `feed`/`collect` freshest-first; inserter spoil priority in `configure` (`inserter_spoil_priority`); a warning when the actor carries eggs; lab inputs' freshness in `labs`. | No change. | 1 |
| Elevated rails and trains | Rails, ramps and supports need gravity, so none work on platforms. They matter on Fulgora, where islands are joined over oil ocean, and for big Nauvis bases. | The harness has no train actions at all (base game included). | Trains: place rails (blueprints already work), stops, schedules, a `train` read. Optional: Fulgora can start with platform drops and `foundation` later. | No change. | 2–3 (optional) |
| Shattered Planet and promethium | `promethium-science-pack` (tech, 2000 × 10 packs) unlocks `solar-system-edge` and `shattered-planet`. Promethium chunks come only on that route; huge asteroids need railguns. The pack is made on a platform from 25 chunks, 1 quantum processor and 10 biter eggs (eggs from captive spawners on Nauvis, spoiling in 30 min). The wiki says nobody is expected to reach the planet; platforms turn back on a fly condition. Vanilla victory is reaching `solar-system-edge`. | Schedules, requests, ghosts. | Fly-condition waits and interrupts; a platform damage and ammo read; egg logistics (rush eggs into orbit). Turn off the victory screen for an unbounded game (`space_finish_script` `set_no_victory`). | Settings only. | 1–2 |
| Infinite research (the unbounded score) | `research-productivity` costs 1.2^L × 1000 units of all 12 packs; levels 1–5 cost about 107k packs, 1–10 about 374k. Other infinite techs cost 1.5^L or 2^L. | Score now reports infinite levels completed per technology, and packs consumed over all surfaces. | A leaderboard line in the overlay: science packs consumed per hour (all surfaces) and research-productivity level. | n/a | 0.5 |

Total: about 15–20 sessions (45–60 engineer agent-hours), of which about 8 come before the first planet: rockets,
platforms, thrusters, collection and bot travel.

## 4. Pace and cost

### Our pace so far (base game, seed 20261010)

From `runs/*/scores.jsonl` (operator score snapshots; packs are produced red, green and blue packs):

| Run | Agents | Mode | Wall h | Game h | Techs | Packs | Packs per agent-hour | Packs/min at the end |
|---|---|---|---|---|---|---|---|---|
| baseline1 world a | 1 | real time | 0.8 | 0.84 | 13 | 898 | ~1,100 | n/a |
| turns3h world a (Astra) | 1 | turns | 3.0 | 1.35 | 19 | 2,286 | ~760 | ~52 |
| coop1 (Astra + Opus) | 2 | real time | 2.4 | 2.00 | 25 | 3,971 | ~830 | ~57 |
| shake1 (9 agents, enemies on) | 9 | real time | 1.0 | ~1.0 | 14 | 934 | ~100 | n/a |

Small teams in real time get the most science per agent-hour; nine agents in one world got an eighth of that
(`docs/studies/shake1.md` explains why: coordination and hand logistics). In real time, game time runs at about 0.8 to
1.0 hours per wall hour once pauses are counted.

### What Space Age asks for

Totals from the 2.0.77 technology data, summing each milestone's prerequisites (count × packs). Lab-hours assume one
speed-1 lab with no bonuses:

| Milestone | Packs | Lab-hours |
|---|---|---|
| rocket-silo (Space Age: 1000 × red, green, blue) | 10,965 | 43 |
| space-platform-thruster | 12,965 | 51 |
| Vulcanus, Gleba or Fulgora discovery | ~17,000 each | ~70 |
| all three inner planets discovered | 25,605 | 104 |
| Aquilo discovery | 80,580 | 221 |
| promethium-science-pack (unlocks the solar system edge and the Shattered Planet) | 131,980 | 314 |
| the same plus railgun (needed in practice) | 151,980 | 347 |
| every finite technology (about 250) | 682,255 | 1,569 |
| base game rocket-silo, for comparison | 17,695 | 62 |

The pack counts alone are within reach. coop1 had made 36% of the Space Age silo's packs by game hour 2 and was
running at 57 packs/min. At that rate the rest takes about 2 more game hours. 152k packs at 57/min would take 44 game
hours, so the factory has to grow several-fold, but that is the normal shape of a run. The packs are not the hard part.
The hard part is that from Vulcanus on, every new pack needs a working base on another planet, built with that
planet's rules, and new mechanics are where our agents slow down. Oil is the precedent: only one single agent reached
petroleum (at game 0:56, in turn mode), the 43-minute real-time runs found none, and shake1's nine agents ended with
oil-gathering at 61 to 67%.

Human references: a first base-game rocket averages about 42 hours on HowLongToBeat (quoted in a
[2018 forum thread](https://forums.factorio.com/viewtopic.php?p=380886)). The Space Age multiplayer any% record is
6 h 51 min according to a speedrun.com profile page; I could not open the full
[leaderboard](https://www.speedrun.com/factorio). I found no reliable figure for a first Space Age playthrough, so
the brief's "a hundred hours or more" stands.

### Estimate to promethium science

Game hours per stage, with 2 agents on Nauvis rising to 4 (one per planet or platform). The low end assumes the early
game pace holds; the high end assumes each new planet stalls the team the way oil stalled single agents:

| Stage | Low | Central | High |
|---|---|---|---|
| Nauvis to a platform making space science, thrusters | 5 | 8 | 15 |
| Vulcanus base shipping metallurgic packs | 8 | 12 | 25 |
| Fulgora (electromagnetic) | 8 | 12 | 25 |
| Gleba (agricultural; spoilage, pentapods) | 10 | 15 | 35 |
| Aquilo prerequisites and base (cryogenic) | 12 | 20 | 40 |
| Captivity, fusion, quantum processors, railgun platform, promethium run | 12 | 20 | 50 |
| Total game hours | 55 | 87 | 190 |
| Wall hours (×1.2 in real time) | 66 | 105 | 230 |
| Agent-hours (about 3.5 agents on average) | 230 | 370 | 800 |

Plus harness engineering (section 3): 15 to 20 sessions, 45 to 60 agent-hours.

### Subscription quota

Measured: Codex (Astra) about 2.5% of a weekly allowance per agent-hour, so one weekly allowance buys about 40
agent-hours. Claude agents use about 1%, so about 100 agent-hours.

| Team mix (central 370 agent-hours) | Codex weekly allowances | Claude weekly allowances |
|---|---|---|
| Half Astra, half Claude | 4.6 | 1.9 |
| One Astra, the rest Claude (about 30% Astra) | 2.8 | 2.6 |
| All Claude | 0 | 3.7 |

With one Codex and one Claude allowance per week, the one-Astra mix takes about 3 weeks of play for the central case,
2 for the low and 6 to 7 for the high, plus the engineering sessions. Each extra profile shortens that in proportion.
Codex is the constraint in every mix with more than one Astra, so Astra should hold the role where it has done best
(science and the main Nauvis factory) and Claude agents take the other planets.

After promethium the game has no end. Research-productivity levels 1–10 cost about 374k packs, which at 600
packs/min is about 10 game hours. The unbounded phase is a budget choice, not a finish line. For example, 2 agents
for 20 wall hours a week costs about 50% of a Codex allowance plus 20% of a Claude allowance a week. Score it by
packs consumed per hour over all surfaces and the research-productivity level (both now in `tools/pog.py score`).

### Staged plan

Each stage has a gate; budgets are central estimates.

0. Access and smoke test (this week). Nick links Steam on factorio.com (section 1, 10 minutes). One engineer
   session:
   - download the expansion build;
   - run `tools/sa_smoke.py` on world `sa`;
   - join with a director client and a human or player client, and test `launch ride`, `land`, platform creation
     and hub construction for real;
   - test whether a playerless character can ride a rocket.

   Gate: smoke test clean; a platform built from hub items; one ride up and down.
1. Nauvis to orbit.
   - Team and setup: 2 agents (Astra + Opus), real time, peaceful, Nauvis enemy bases on (promethium needs them
     later), sessions of about 3 hours.
   - Engineering in parallel: bot travel, platform reads, thrusters, asteroids (about 6 sessions).
   - Gate: space science packs made on a platform and consumed in Nauvis labs; thrusters researched.
   - Budget: about 10 wall hours, 20 agent-hours (Codex 25%, Claude 10%).
   - This stage is also the Space Age version of the base-game rocket goal in `docs/PLAN.md`.
2. Vulcanus.
   - A third agent rides to Vulcanus.
   - Gate: metallurgic packs consumed on Nauvis.
   - About 15 wall hours, 45 agent-hours.
3. Fulgora and Gleba.
   - A fourth agent; spoilage feeding done before Gleba.
   - Gate: electromagnetic and agricultural packs consumed.
   - About 30 wall hours, 120 agent-hours.
4. Aquilo, captivity, fusion, railgun platform, promethium.
   - Gate: promethium packs consumed. The Shattered Planet trip itself is a turn-back route, as the game intends.
   - About 50 wall hours, 200 agent-hours.
5. Unbounded.
   - Fixed weekly budget; score is packs per hour and research-productivity level.
   - Stream it from here on.

Stop early and rethink if any planet stage runs past the high column. The usual cause will be a missing harness read
or action, which costs an engineer session, not agent-hours.

## Open questions to settle on the box

- A player's Lua state in a hub (`character`, `controller_type`, `physical_surface`, `hub`). One line:
  `/c local p=game.player rcon.print(serpent.line{p.controller_type,p.physical_controller_type,p.character and {p.character.surface.name,p.character.position},p.hub and p.hub.surface.name,p.physical_surface.name})`
- Whether the game strips a rider's inventory, and whether a rider can use their inventory in the hub.
- Where `land_on_planet` puts the character (landing pad or spawn).
- Whether a playerless character can ride (`launch_rocket(dest, character)` for a bot).
- Space Age freeplay: crash site, starting items, `freeplay` remote interface, and whether the victory screen comes
  from `space-finish-script` (switch it off for an unbounded game).
- Whether `peaceful_mode` set on a new planet surface at creation calms demolishers and pentapods.
- Which hub inventory is "drop to planet".
- Whether lightning hits characters on Fulgora.
