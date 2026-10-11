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
  technologies. All of it has only been run against fake-engine tests. The two big gaps: bots (our multi-agent
  architecture) cannot leave Nauvis, and nothing reads spoilage. I could not run the Space Age world on the box from
  this session (section 2). The fixes from tonight and a one-command smoke test are on this branch.
- Pace and cost. See section 4.

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
- All 19 Lua fake-engine suites pass (`lua tests/*.lua`, `mod/tests/*.lua`; runtime 681 assertions, control 66,
  scheduler 56). That includes `tests/space.lua`, which covers platforms, requests, schedules, launches and landing.
- New fake-engine checks for the score and stream Lua (multi-surface sums, infinite levels).

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
| Stream sparklines (`tools/stream/harness.py` FLOW_LUA) | Nauvis only. | Fixed: summed over surfaces. `STREAM_LUA` (power-starved machine count) is still Nauvis only. |
| `bin/fh`, `tools/pog.py` | No world `sa`. | Added (RCON 27030). |
| Bots (`bots.lua`) | Every bot lives on `nauvis`: created there, respawns there, and the record's surface is fixed. `launch ride=true` and `land` call `LuaPlayer` methods, and a bot has no player, so they would have failed with a nil index. | Guarded: both now refuse bots with a clear error. Bot travel is the largest gap (section 3). |
| Platforms, requests, launch, land (`space.lua`) | Present (from upstream), but only fake-engine tested. They assume a real player: `land` uses `LuaPlayer.land_on_planet`, and `ride` uses the player's character. | Needs a real run. |
| Ghost building on platforms | `place_ghosts`, `paste`, `blueprint_place`, `deconstruct`, `grid` and `scan` take `platform=NAME` (hub at 0,0) and work from remote view. `place_ghosts` handles `space-platform-foundation` tiles. | Present. |
| Trigger technologies | `technologies` and `research` describe Space Age triggers (craft, mine, build, `send-item-to-orbit`, `capture-spawner`, create a platform) and never try to research them in labs. | Present. |
| Quality | `build`, `transfer`, `stock`, construction and `rates` take or report quality (default `normal`). Counts are exact per quality: an uncommon gear does not satisfy a `normal` request. | Present; agents need to be told this in the playbook. |
| Spoilage | Nothing read `spoil_percent`. Inventories show counts only (`get_contents()` has no freshness), and `feed`/`collect` ignore freshness. Nothing spoils on Nauvis until biter eggs (captive spawners) or Gleba fruit arrive. | Partly fixed: `status` has `spoiling` ("yumako*15 50%", stalest first) and `scan` has a `spoil` field. Freshness-aware feeding is still missing (section 3). |
| Hand-craft categories | In Space Age the character crafts `crafting, electronics, pressing, recycling-or-hand-crafting, organic-or-hand-crafting, organic-or-assembling`: belts are `pressing`; circuits, cables and poles are `electronics`. The harness reads the character's own `crafting_categories`, so this works, but two places ignored a recipe's `additional_categories`. | Fixed: one shared check for `craft`, the shortfall explanation, the assembler suggestion and `craftable`. |
| Gleba plants | Yumako and jellystem are type `plant`, so `type='tree'` filters miss them. | Fixed: obstacle marking under ghosts, the "clearable" build hint and the chart's tree summary include `plant`. |
| Quality counts | A bare item name in `get_item_count` counts normal quality only ([ItemWithQualityID](https://lua-api.factorio.com/2.0.77/concepts/ItemWithQualityID.html)). The harness uses bare names in 7 places (`wait_until item_count`, lab and recipe ingredient counts). | Correct for recipes, which need exact quality. `wait_until` undercounts once quality items exist; fix when quality starts. |
| Hard-solid ores | `tungsten-ore` (Vulcanus) is `hard-solid`; only the big mining drill mines it, never a character. | `mine` fails with the game's refusal; worth a clearer message before Vulcanus. |
| Nauvis recipe and tech changes | `rocket-part` is 1 processing unit + 1 low-density structure + 1 rocket fuel, 50 per rocket; no satellite; the rocket silo needs only red, green and blue packs; `space-science-pack` is a trigger tech (build an asteroid collector); assembling machine 3 needs speed modules. | No harness code names these. `agent/PLAYBOOK.md` needs a Space Age section. |
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

So the honest equivalent of "no character on a platform" is the remote controller's rights. Any agent, wherever its
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
modules, and any weapons", and no ammo. The harness should enforce that: refuse to ride with anything else in the
main inventory, as the silo's "Travel to platform" button does.

### Per item

| Item | Game mechanics (2.0.77) | Harness today | Needed actions and reads | Fair-play mapping | Effort |
|---|---|---|---|---|---|
| Rockets and cargo pods | 50 rocket parts per rocket; payload limited by weight (1 t, `rocket_lift_weight`), 20 slots. Silo GUI: deliver cargo to a platform in orbit, launch a starter pack, or ride alone. `use_transitional_requests` auto-fills and launches for platform requests. Pods land on the planet's `cargo-landing-pad`, else near spawn as a `cargo-pod-container` (temporary container). | `launch` (cargo to a platform, to orbit, `ride`), silo `auto_requests`, `transfer` into `rocket_silo_rocket` and `cargo_landing_pad_main`, `platforms` lists silos. Fake-engine tested only. | Real-engine test. `ride` should use `{type=station, station=hub}` and require an empty payload plus the armor/weapons rule. Transfer from a `cargo-pod-container`. A launch report that follows the pod's state (`cargo_pod_state`, `on_cargo_pod_finished_*`). | Loading the silo needs reach (as now); launching from the silo GUI needs reach or remote view (GUI action); pad requests are settings. | 1–2 |
| Space platforms: create, hub, construction | `force.create_space_platform{planet, starter_pack}` equals the "new platform" button; a silo then delivers the pack (`apply_starter_pack()` would skip that: a cheat). Hub: 59 slots, plus 20 per cargo bay. Ghosts are built from hub items. Foundation must be one connected area; thrusters on the south edge; no chests, burners, robots or rails. | `platform_create` (honest), `requests` on the hub with `import_from`, ghost tools with `platform=`, `grid`/`scan` with `platform=`, `platforms` (state, location, hub items, requests). | Hub drop to planet (`hub.create_cargo_pod()` with items taken from the hub inventory, or the hub's drop slots: which inventory is unverified). Platform health: `damaged_tiles`, destroyed entities in `status` alerts. Weight, `speed`. A `platform` view of what is unbuilt and why (ghosts waiting for items). | Remote-view rights only (above). | 2 |
| Thrusters and routes | Thrusters burn `thruster-fuel` + `thruster-oxidizer` made on board from asteroid carbon, iron ore and ice. `PlatformSchedule` records have wait conditions (time, inactivity, item_count, all_requests_satisfied, any_request_not_satisfied, ...). Interrupts are set through `LuaSchedule` (`get_schedule()`). | `platform_schedule` (stops, waits, pause). | Interrupts. A per-platform `fuel` read (thruster fluid levels, speed). An ETA from `distance` and `speed`. | Settings only. | 1 |
| Asteroid collection and crushing | Collectors (radius 7.5) pull chunks; chunks are not entities (`platform.find_asteroid_chunks_filtered`). Crushers are `assembling-machine`s (`metallic-asteroid-crushing` → iron ore, `carbonic` → carbon, `oxide` → ice). Asteroids (`asteroid` entities) damage platforms; turrets need ammo made on board. | `configure` sets recipes and filters remotely; `scan` sees asteroids as entities. | A chunk read (counts near the platform by type). Collector filter settings in `configure`. An ammo and turret read per platform. | Settings only; ammo reaches turrets by inserters, never by hand. | 1 |
| Travel between planets (bodies) | Players: `launch_rocket(dest, character)`, then `LuaPlayer.land_on_planet()` from a platform stopped at a planet. The pod lands at a landing pad if there is one (unverified). | `launch ride=true`, `land` for players (untested). Bots: refused (tonight). All bots live on Nauvis. | Bot travel. First test whether `launch_rocket(dest, character)` accepts a playerless character and what the hub does with it. If not: on launch, keep the bot's armor and weapons in a script inventory and remove the body; the bot then acts with remote-view rights while "aboard". On drop, send a real cargo pod down (`hub.create_cargo_pod()`, destination the planet) and create the body where the pod lands, with those items back. Track `b.surface`; respawn on the last planet (as for players). | Same as a player: real ascent, flight and descent time; only armor and weapons travel with the body; everything else ships as cargo. Re-creating a bot's body is the same act as creating the bot, which we already accept. | 2–3 |
| Other surfaces | Vulcanus: calcite, tungsten (hard-solid), lava, demolishers (`segmented-unit`) in territories; peaceful stops them seeking buildings, but they still roam. Fulgora: scrap and the recycler; night lightning damages metal buildings; oil-ocean islands. Gleba: `plant`s, agricultural towers, pentapods (`spider-unit`, `unit`), spores. Aquilo: freezing (`entity.frozen`), heating towers, ammoniacal ocean. Many planet techs are triggers (mine calcite, craft tungsten plate, ...), which the harness already describes. | Reads follow the actor's surface. Threat reports know biters and spawners. | Per planet in `status` warnings and `threats`: demolisher territories (`surface.get_territories()`), the lightning season and unprotected buildings, frozen machines, pentapod nests. A clearer `mine` refusal for hard-solid ores. Chart summaries that name the new rocks (`big-volcanic-rock`, stromatolites, icebergs, ruins) instead of matching "rock". | Peaceful per planet: `peaceful_mode` is per surface. An `on_surface_created` world setting copies Nauvis's to each new planet, documented as a world setting like the map seed. Keep enemy bases on Nauvis: the promethium path needs a living spawner to capture (`biter-egg-handling` trigger) and biter eggs. | 1 per planet (4) |
| Quality | Five levels; quality modules from early on; the recycler loops quality. Recipes need ingredients of exactly one quality; `begin_crafting` has no quality parameter. | Quality on build, transfer, stock, construction, rates, requests; exact counts. | `wait_until` and lab counts across qualities; quality in inventory summaries and `stock` totals; `configure` recipe quality (`set_recipe(recipe, quality)`). | No change: quality comes from modules and the recycler. | 1 |
| Spoilage | Gleba fruit 1 h, mash 3 min, jelly 4 min, nutrients 5 min, bioflux 2 h, agricultural pack 1 h, bacteria 1 min; spoiled `pentapod-egg` and `biter-egg` hatch enemies anywhere, inventories and platforms included. | `status.spoiling`, `scan fields=spoil` (tonight). | `feed`/`collect` freshest-first; inserter spoil priority in `configure` (`inserter_spoil_priority`); a warning when the actor carries eggs; lab inputs' freshness in `labs`. | No change. | 1 |
| Elevated rails and trains | Rails, ramps and supports need gravity, so none work on platforms. They matter on Fulgora, where islands are joined over oil ocean, and for big Nauvis bases. | The harness has no train actions at all (base game included). | Trains: place rails (blueprints already work), stops, schedules, a `train` read. Optional: Fulgora can start with platform drops and `foundation` later. | No change. | 2–3 (optional) |
| Shattered Planet and promethium | `promethium-science-pack` (tech, 2000 × 10 packs) unlocks `solar-system-edge` and `shattered-planet`. Promethium chunks come only on that route; huge asteroids need railguns. The pack is made on a platform from 25 chunks, 1 quantum processor and 10 biter eggs (eggs from captive spawners on Nauvis, spoiling in 30 min). The wiki says nobody is expected to reach the planet; platforms turn back on a fly condition. Vanilla victory is reaching `solar-system-edge`. | Schedules, requests, ghosts. | Fly-condition waits and interrupts; a platform damage and ammo read; egg logistics (rush eggs into orbit). Turn off the victory screen for an unbounded game (`space_finish_script` `set_no_victory`). | Settings only. | 1–2 |
| Infinite research (the unbounded score) | `research-productivity` costs 1.2^L × 1000 units of all 12 packs; levels 1–5 cost about 107k packs, 1–10 about 374k. Other infinite techs cost 1.5^L or 2^L. | Score now reports levels past the first of each infinite tech, and packs consumed over all surfaces. | A leaderboard line in the overlay: science packs consumed per hour (all surfaces) and research-productivity level. | — | 0.5 |

Total: about 15–20 sessions (45–60 engineer agent-hours), of which about 8 come before the first planet: rockets,
platforms, thrusters, collection and bot travel.
