# Space Age: feasibility and plan

Branch `research/spaceage`, 2026-10-10 night. Goal: run the long game on Factorio: Space Age with no end state:
reach the Shattered Planet, make promethium science, then keep raising science output through infinite research.

Summary:

- Access. The server already has what it needs. Each director client needs the expansion build of Factorio.
  Nick has now linked Steam on factorio.com and downloaded the installer. `tools/win/setup-expansion.ps1` makes a
  portable copy in `D:\pog`, from the download API zip or, as a fallback, from that installer (section 1). It is not
  run yet: this session cannot reach the box. After that the setup stays as it is: N standalone clients, no Steam,
  user verification off.
- Harness. Most of Space Age is already in the harness. It has platforms, hub requests, platform schedules, the silo
  launch, riding a rocket, landing, ghost construction on platforms, quality on build and transfer, and trigger
  technologies. The space parts have only run against fake-engine tests; the core (walking, mining, crafting, building,
  blueprints, combat) passed upstream's real-engine suite with Space Age enabled. The biggest gap was that bots
  (our multi-agent architecture) could not leave Nauvis. Round 4 (Oct 11) built bot travel: ride a rocket, act by
  remote view aboard, drop cargo and land in a cargo pod, respawn on the last planet; cameras and the overlay follow
  across surfaces (section 5). It ran live on `sa`: a bot rode up (35 s) and landed on Vulcanus (18 s), then
  unpacked dropped cargo, built and mined there. The live run found one bug, which is fixed. Earlier fixes on this
  branch: multi-surface score and sparklines, spoilage reads, Space Age recipe categories, Gleba plants, no
  hand-mining of hard-solid ore, the rocket-ride payload rule, and per-planet peaceful flags.
- Pace and cost. Reaching promethium science needs about 132k–152k science packs. Most of the work, though, is
  building on four more planets. Reference: a solo Astra reportedly finished all planets in about 44 game hours.
  Team estimate (option A, 2 to 4 agents): 60 game hours central (range 38–140), about 250 agent-hours, run as 4-hour
  shifts. The world is paused between shifts. A normal week is 9 shifts, about 30 game hours: 72 Astra hours
  across both Codex profiles (90% of each, resetting Saturdays) and 72 Claude hours. That is 2 weeks of play after
  stage 0 for the central case. Option B, a solo Astra like the reference, needs about 105–145 Codex agent-hours
  (about 1.5 weeks on both Codex profiles), and it isn't blocked on bot travel. After that, the unbounded phase is a
  fixed weekly budget (section 4).

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

Update (2026-10-10, 23:40): Nick logged in to factorio.com with Steam on the box. The site then offered Space Age,
and he downloaded the installer (`C:\Users\player\Downloads\Setup_FactorioSpaceAge_2.0.77.exe.zip`, 4.2 GB). So the
linking step is done. From this session I could not reach the box (SSH blocked) and found no factorio.com token on
the Mac, so I did not retry the download API, extract the installer or install anything. What I left instead is
`tools/win/setup-expansion.ps1`, written but not run (there is no PowerShell here to parse-check it). It always
installs to `D:\pog\factorio-2.0.77-expansion`:

1. Preferred: the portable zip from the download API
   (`get-download/2.0.77/expansion/win64-manual?username=...&token=...`). The token is on Nick's factorio.com
   profile page; save it on the box (for example `D:\pog\factorio-token.txt`), then run
   `tools/winps.sh tools/win/setup-expansion.ps1 -Username NAME -TokenFile D:\pog\factorio-token.txt`.
   A 403 now would mean the token belongs to a different account from the one Nick linked.
2. Fallback: `-Installer` unzips Nick's installer into `D:\pog\downloads`. It runs it only if it is an Inno Setup
   installer, with `/VERYSILENT /CURRENTUSER /NOICONS /TASKS="" /DIR=D:\pog\factorio-2.0.77-expansion`: no Program
   Files, no shortcuts. Inno still writes an uninstall entry in the registry. If the installer insists on admin
   rights, it may show a UAC prompt nobody can answer over SSH; the script gives up after an hour. Prefer option 1.

Either way the script writes a `config-path.cfg` that keeps write data next to the install, so `%APPDATA%\Factorio`
is never used, and checks for `data\space-age`. Clients then start with
`start-client.ps1 -Factorio D:\pog\factorio-2.0.77-expansion`, keeping their own config folders and names as now.
Nick's Steam install is not touched. Also check `D:\pog\factorio-2.0.77\data\space-age` (the server copy). If it is
missing, run the server from the expansion folder too (point `new-instance.ps1` and `start-server.ps1` at it). Server
and clients must both be 2.0.77.

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
| Space platforms: create, hub, construction | `force.create_space_platform{planet, starter_pack}` equals the "new platform" button; a silo then delivers the pack (`apply_starter_pack()` would skip that: a cheat). Hub: 59 slots, plus 20 per cargo bay. Ghosts are built from hub items. Foundation must be one connected area; thrusters on the south edge; no chests, burners, robots or rails. | `platform_create` (honest), `requests` on the hub with `import_from`, ghost tools with `platform=`, `grid`/`scan` with `platform=`, `platforms` (state, location, hub items, requests). | (Done in round 4: `drop`, hub items down in a `hub.create_cargo_pod()` pod; fake-engine tested.) Destroyed entities in `status` alerts. Why ghosts stay unbuilt (missing hub items). (Done tonight: `platforms platform=NAME` reports speed, damaged tiles and the unbuilt ghost count.) | Remote-view rights only (above). | 2 |
| Thrusters and routes | Thrusters burn `thruster-fuel` + `thruster-oxidizer` made on board from asteroid carbon, iron ore and ice. `PlatformSchedule` records have wait conditions (time, inactivity, item_count, all_requests_satisfied, any_request_not_satisfied, ...). Interrupts are set through `LuaSchedule` (`get_schedule()`). | `platform_schedule` (stops, waits, pause). | Interrupts. An ETA from `distance` and `speed`. (Done tonight: thruster count and lowest tank in `platforms`.) | Settings only. | 1 |
| Asteroid collection and crushing | Collectors (radius 7.5) pull chunks; chunks are not entities (`platform.find_asteroid_chunks_filtered`). Crushers are `assembling-machine`s (`metallic-asteroid-crushing` → iron ore, `carbonic` → carbon, `oxide` → ice). Asteroids (`asteroid` entities) damage platforms; turrets need ammo made on board. | `configure` sets recipes and filters remotely; `scan` sees asteroids as entities. | Collector filter settings in `configure`. (Done tonight: chunk counts by type in `platforms`.) An ammo and turret read per platform. | Settings only; ammo reaches turrets by inserters, never by hand. | 1 |
| Travel between planets (bodies) | Players: `launch_rocket(dest, character)`, then `LuaPlayer.land_on_planet()` from a platform stopped at a planet. The pod lands at a landing pad if there is one (unverified). | `launch ride=true`, `land` for players (untested). Bots: built in round 4 by the script-inventory plan (section 5), fake-engine tested. | A live run (`tools/sa_travel.py`), including the engine probe: does `launch_rocket(dest, character)` take a playerless character? If it does and lands it cleanly, the bot could ride in its own body. | Same as a player: real ascent, flight and descent time; only armor and weapons travel with the body; everything else ships as cargo. Re-creating a bot's body is the same act as creating the bot, which we already accept. | 2–3 |
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

### Reference: a solo Astra through all planets

Nick reports that a solo Astra finished all planets in about 44 game hours. The source is not in this repo.
`docs/PLAN.md` records Mira's run, a base-game win with enemies, also at about 44 game hours (4 d 11 h on the Codex
`/goal` clock, about $4,500 API-equivalent). Check that the two are different runs. If this one is a Space Age run, it
is the best anchor we have: one strong agent, writing its own tools on top of honest primitives, gets through every
planet in about 44 game hours, roughly a third of the brief's human estimate. If it ran at Mira's ratio (about 2.4
wall hours per game hour, since the agent's thinking time counts), it took about 105 wall hours. On one Codex
profile that is about 105 agent-hours, or 2.6 weekly allowances at our measured 2.5% per hour.

### Estimate to promethium science

Game hours per stage, with 2 agents on Nauvis rising to 4. Fulgora and Gleba run in parallel shifts, one agent each,
so their game hours overlap. The low end is the solo-Astra reference reached by a team. The central case adds our
harness gaps (bot travel, per-planet reads) and coordination cost. The high end assumes each new planet stalls the
team the way oil stalled single agents.

| Stage | Low | Central | High |
|---|---|---|---|
| Nauvis to a platform making space science, thrusters | 5 | 7 | 12 |
| Vulcanus base shipping metallurgic packs | 5 | 9 | 20 |
| Fulgora and Gleba in parallel (electromagnetic, agricultural) | 9 | 15 | 40 |
| Aquilo prerequisites and base (cryogenic) | 9 | 14 | 30 |
| Captivity, fusion, quantum processors, railgun platform, promethium run | 10 | 15 | 38 |
| Total game hours | 38 | 60 | 140 |
| Wall hours (×1.2 in real time) | 46 | 72 | 168 |
| Agent-hours (about 3.5 agents on average) | 160 | 250 | 590 |

Plus harness engineering (section 3): 15 to 20 sessions, 45 to 60 agent-hours, mostly before and during stage 1.

Option B, the cheap route: run a solo Astra as in the reference. It plays a real player through a client, so it is
not blocked on bot travel: `launch ride` and `land` already exist for players. About 44 to 60 game hours and 105 to
145 Codex agent-hours. That is 2.6 to 3.6 weekly allowances, or about 1.5 weeks on both Codex profiles. It is less to
watch and has no Claude in it. The team (option A) is the stream; option B is the fastest test that the harness
carries an agent to promethium. Both can share stage 0.

### Quota: weekly resets, shifts and pauses

Live quota (ai-usage cache, Sat Oct 10 23:39):

| Profile | Weekly used | Weekly reset | Budget per week at our burn rates |
|---|---|---|---|
| `codex` (personal) | 1% | Sat Oct 17, ~21:00 | ~40 Astra agent-hours |
| `codex-b` (account B) | 2% | Sat Oct 17, ~21:00 | ~40 Astra agent-hours |
| `claude` (personal) | 60% | Tue Oct 13, 10:00 | ~100 Claude agent-hours per full week |
| `claude-c` (account C) | 39% | Mon Oct 12, 13:00 | ~100 |
| `claude-b` (account B) | 38% | Fri Oct 16, 16:00 | ~100 |

The run uses five subscription accounts. The Claude ones have 5-hour session windows, so plan on about 100 Claude agent-hours a week spread across them. Rotate the
profile per shift rather than running one profile hot.

Run the game in shifts, never as one continuous burn:

- A shift is a 4-hour wall block with 2 to 4 agents. At the start the operator resumes the world
  (`tools/pog.py --world W resume`); at the end, agents write `notes.md` and the operator pauses and saves
  (`pause`, `save`). Between shifts the world stays paused, so game time moves only while agents play: the score
  stays comparable and nothing runs unattended.
- Bots live in the world across shifts. A shift's agent takes over a bot and continues from its `notes.md` and a
  fresh `status`. The next shift's agent may be a different model or profile.
- A normal week is 9 shifts (36 wall hours, about 30 game hours) with 2 Astra and 2 Claude agents: 72 Astra hours
  (90% of both Codex profiles) and 72 Claude hours.
- Codex resets Saturday around 21:00. Put Astra shifts early in the week and keep Friday and Saturday for
  Claude-only shifts and engineering, so an overrun never leaves a stage waiting for Codex.
- When a stage stalls on a missing harness read or action, pause the world (no agent-hours spent) and run engineer
  sessions on Claude until it is fixed. Don't let agents burn shifts working around it.

At about 30 game hours a week, the central case (60 game hours) takes 2 weeks of play, the low case 1.5 and the high
about 5, after stage 0.

After promethium the game has no end. Research-productivity levels 1–10 cost about 374k packs, which at 600
packs/min is about 10 game hours. The unbounded phase is a fixed weekly budget, not a finish line. For example, 4
shifts a week with 2 agents is 32 agent-hours: 16 Astra (40% of one Codex profile) and 16 Claude. Score it by packs
consumed per hour over all surfaces and the research-productivity level (both now in `tools/pog.py score`).

### Staged plan by week

Each stage has a gate; budgets are central estimates.

0. Week of Oct 10 (Codex fresh until Sat Oct 17): access and smoke test. One engineer session with box access:
   - install the expansion build (`tools/win/setup-expansion.ps1`, section 1);
   - run `tools/sa_smoke.py` on world `sa`, plus one base-game smoke test, since tonight's harness changes are only
     fake-tested;
   - join with a director client and a player client, and test `launch ride`, `land`, platform creation and hub
     construction for real;
   - test whether a playerless character can ride a rocket.

   Gate: smoke tests clean; a platform built from hub items; one ride up and down.
1. Same week: Nauvis to orbit.
   - Team and setup: 2 agents (Astra + Opus), real time, peaceful, Nauvis enemy bases on (promethium needs them
     later), 2 to 3 shifts.
   - Engineering in parallel: bot travel, platform reads, thrusters, asteroids (about 6 sessions, on Claude).
   - Gate: space science packs made on a platform and consumed in Nauvis labs; thrusters researched.
   - Budget: about 9 wall hours, 18 agent-hours. If stage 0 goes fast, start option B in the same week on the
     spare Codex quota.
2. Week of Oct 17: Vulcanus, then Fulgora and Gleba.
   - A third agent rides to Vulcanus. Then a fourth agent; spoilage feeding is done before Gleba.
   - Gate: metallurgic, electromagnetic and agricultural packs consumed on Nauvis.
   - About 30 wall hours, 105 agent-hours.
3. Week of Oct 24: Aquilo, captivity, fusion, railgun platform, promethium.
   - Gate: promethium packs consumed. The Shattered Planet trip itself is a turn-back route, as the game intends.
   - About 35 wall hours, 125 agent-hours. The high case spills into November.
4. Unbounded.
   - Fixed weekly budget in shifts; score is packs per hour and research-productivity level.
   - Stream it from here on.

Stop early and rethink if any stage runs past the high column. The usual cause will be a missing harness read or
action, which costs an engineer session, not agent-hours.

## 5. Bot travel (round 4, Oct 11)

Every agent is a bot, so bot travel was the blocker for the long run. It is built on this branch and passes
fake-engine tests, and it ran live on world `sa` on Oct 11 between 02:49 and 03:08. Nick deployed the runtime
(this session's permission mode refused `fh deploy`). A bot rode a rocket to a platform, was aboard with remote view
only, and the platform went to Vulcanus. There the bot dropped cargo, landed in a cargo pod, unpacked the cargo,
built and fuelled a furnace, walked about 90 tiles and mined coal. The live run found one bug, which stopped the
runtime; it is fixed in 0a9ddb0.

### Live bot-travel run on `sa` (Oct 11, `tools/sa_travel.py`, bot `traveler`)

Logs: `runs/sa-travel/run2.jsonl` and `run2.out` (ride up), `run3.out` and `smoke.jsonl` (resumed after the fix).
Run 1 (`run1-script-bug.jsonl`) failed on a script bug: it read `fh` replies at the top level, not `result`. So the
bot never emptied its inventory, and the harness rightly refused the ride ("only armor and guns travel with the
rider: put down everything in character_main first").

| Tick | Step | Result |
|---|---|---|
| 68112 → 68262 | Walk to the silo, put inventory and ammo in a chest (`transfer` × 4) | ok |
| 68271 | `launch ride=true platform=travel-test` | `launched`, rocket with no character; body removed, pistol kept |
| 68279 | `status` | `alive=false`, `control_error`: "riding a cargo pod (ascending ...)" |
| 70368 | `status` | `travel.state=aboard`. Ascent 2,097 ticks (35 s), the same as the engine's own rider (below) |
| 70375 | `platforms platform=travel-test` (aboard) | ok |
| 70381 | `move_to` (aboard) | refused: "aboard platform travel-test with no body (remote view only)" |
| 70389 | `platform_schedule` → Vulcanus (aboard) | ok, `waiting_for_departure`. Without thrusters it never left, so the operator set `space_location` (72213) |
| 72000 | Hourly survey sample | **Bug**: it sampled the bodiless bot and raised inside the tick, which quarantined the runtime. Fixed in 0a9ddb0 (sample bodies only; a survey error never raises in the tick); redeployed |
| 93360 | `drop` stone furnace ×1, coal ×10 (aboard) | `dropped`, pod to Vulcanus near (0, 0) |
| 93366 | `land` | pod at (0, 0); `riding a cargo pod (descending)` |
| 94462 | Body made on Vulcanus at (0, 0) | `landed.ticks=1096` (18 s). Inventory empty, pistol back |
| 94507 → 94708 | The drop's `cargo-pod-container` at (6.5, 8.5); walk there, `transfer` to the bot | 11 items (furnace, 10 coal) |
| 94749 | `build stone-furnace` at (8, 10) on Vulcanus | ok |
| 94761 | `refuel` | ok (coal into the furnace) |
| 95869 → 96764 | `move_to` coal at (-9.5, -90.5), 90 tiles from spawn | arrived |
| 96764 → 97064 | `mine` coal, 300 ticks | 2 coal in the inventory |
| 97099 | `score` | planets `nauvis`, `vulcanus`; platform `travel-test` at Vulcanus; 2 rockets |

What the run also showed:
- The nearest coal and calcite on Vulcanus are 90 tiles out, past `nearest`'s 64-tile limit. The script's own
  `nearest` found nothing, and the coal was found by operator read. Agents should use `map` there.
- While parked at Vulcanus, small metallic asteroids hit the undefended test platform (3 losses in `team.alerts`).
  The alert path works on platforms; real platforms need turrets.
- The drop container landed about 10 tiles from where the bot did, since the drop does not ask for the exact spot.
  That is close enough to walk.
- The stream side (cameras on another surface, overlay location) did not run: no director camera was pointed at the
  bot. It is still fake-tested only.

The live engine probe below ran before this, with operator Lua only. It decided the design question.

### Live engine probe on `sa` (Oct 11, 02:40 to 02:45, seed 20261010, Space Age 2.0.77)

Logged in `runs/sa-travel/engine-probe.jsonl`. Setup used operator Lua on `sa`: research marked done, a silo at
(12.5, 0.5) with an electric-energy interface and `rocket_parts` set, and platform `travel-test` from a starter pack
via `apply_starter_pack` (test setup).

| Tick | What happened |
|---|---|
| 3242 → 4154 | The silo builds the rocket from the parts (statuses 2, 3, 5, 7). Ready at 4154. |
| 4160 | `silo.launch_rocket({type=surface, surface=platform}, character)` with a character that has no player returns `true`. The engine takes a playerless rider. |
| 4465 → 5677 | The character rises with the rocket on Nauvis (y -4 → -146). |
| 5980 | The character is on `platform-1` (y -32, coming in). |
| 6283 onward | The character sits at the hub (0, 0), valid. `count_entities_filtered{name='character'}` on the platform returns 0, so it is held inside the hub, as a player's body is. Ascent: about 2,100 ticks (35 s). |
| 9823 | `hub.create_cargo_pod()` gives pod #84 (`awaiting_launch`). `pod.set_passenger(character)` raises no error, but `get_passenger()` then returns none. Setting `cargo_pod_destination` (Nauvis, (30, 30), exact) is accepted. |
| 10007 | Pod #84 is `ascending` on `platform-1`; it launched by itself once the destination was set. |
| 10375 | The same pod #84 is `descending` on Nauvis. A pod keeps its identity across the surface change. |
| 10927 | Pod #84 is at (30, 30), the exact position asked for. |
| 11111 | The pod is gone. It was empty and there is no landing pad, so it leaves nothing behind. Descent: about 1,200 ticks (20 s) from the destination being set. |
| 13504 | The character is still in the hub at (0, 0). Nothing brought it down; it was destroyed by hand afterwards. |

What this means:
- The engine takes a bot up in its own body, but has no way to bring it down. `land_on_planet` is LuaPlayer-only, and
  a hub-held character cannot be made a pod passenger. A bot that rode in its body would be stuck in the hub. The
  script plan (body removed at boarding, made again where the hub pod lands) is the right one, and is what the
  harness does.
- The ride times the harness relies on are confirmed: the rocket's pod reaches the hub in about 35 s. A hub pod
  launches on its own once its destination is set (the 5 s push is a fallback that should never fire), keeps its
  entity across surfaces, lands at the exact position asked for, and is gone about 20 s later. The minimum ride
  times (20 s up, 10 s down) sit below both.

The full run (`tools/sa_travel.py`) is in the table above.

### How it works

The engine's ride and landing are LuaPlayer moves, and a bot has no LuaPlayer. Whether `launch_rocket(dest,
character)` takes a playerless character is still untested. Even if it does, nothing could take such a body out of
the hub again (`land_on_planet` is a LuaPlayer method). So the harness uses the script-inventory plan from section 3,
which does not depend on that answer.

1. `launch ride=true platform=NAME` (`space.lua`, then `bots.board`). The checks are the same as for a player: reach
   to the silo, an empty rocket, and nothing carried but worn armor and guns. Bots also need an empty hand-craft
   queue and an empty hand, since both would be lost with the body. The rocket launches with no character
   (`silo.launch_rocket(dest)`). The armor and guns move into a script inventory (`game.create_inventory`, with
   `transfer_stack`, so equipment grids survive) and the body is removed. The bot then follows the rocket's own
   cargo pod (`silo.rocket.attached_cargo_pod`). Its `b.position` and `b.surface` track the pod, so cameras ride
   along. It arrives when the pod is delivered (gone) or parks on the platform; without a pod handle, after a fixed
   40 s. A ride lasts at least 20 s up and 10 s down, whatever the pod entity does (in case the engine replaces a
   pod when it changes surface). Rides follow the platform's index, so renaming a platform keeps its riders.
2. Aboard, the bot has no body. A whitelist (`bots.check_action`) lets through what a player in the hub can do by
   remote view:
   - `platforms`, `platform_schedule`, `platform_create`, `requests` with `platform=` or `position=`, and `drop`
   - ghost tools and `grid`/`scan` with `platform=`
   - `research`, `recipes`, `technologies`, chat, the board, `status`, `land`

   Everything else fails with "bot X is aboard platform P with no body (remote view only): ...". `status` reports
   `travel` {state, platform, from, to, since_tick}, `surface` and `planet`.
3. `drop` (new; the hub's drop slots) sends hub items in a cargo pod (`hub.create_cargo_pod()`, then
   `cargo_pod_destination`, which launches it) to the planet below a stopped platform. The hub's own stacks move into
   the pod's `cargo_unit`: whole stacks by `transfer_stack`, the rest of a stack as a copy with its spoil progress.
   So nothing is created or refreshed, and repeated entries in one call add up before the hub's count is checked.
   A refused destination puts the items back in the hub. It goes to
   our landing pad there if there is one, else near the bot's last spot on that planet, else spawn. Without a pad it
   lands as a `cargo-pod-container`, which `transfer` now opens as a chest. This is how a first landing gets
   anything besides armor and guns.
4. `land` (`bots.land`) sends a hub cargo pod with no cargo to the same place, the pad or the bot's spot. The bot
   follows it down, and the body is made where the pod comes down (`find_non_colliding_position`). It wears the same
   armor and guns and gets no starting items. If the pod still sits in the hatch after 5 s, it is pushed off once
   (`force_finish_ascending`); the descent is always the game's. `status.landed` gives the surface, tick, position
   and the ride's ticks. If no body can be made at the landing spot or by the spawn point, the ride ends as a
   death. It is never an error inside the game tick, which would stop the server.
5. Bots live on any surface. The bot record keeps `surface` (planet or platform) and `planet` (last planet stood on),
   plus the last spot per planet. Respawn uses the last planet, as for players. A platform destroyed while the bot
   is aboard is a death: the kit is lost, and the bot respawns on its last planet after the usual 10 s. Every read
   and action already goes through `p.surface` (checked: no other code assumes Nauvis), so it follows the bot.
6. Stream:
   - `profiles` reports `surface`, `where` (a planet, "platform NAME", or "cargo pod to X") and `travel`.
   - Cameras follow a bot across surfaces, take an optional `surface` for fixed views, and report it.
   - The director pairs agents only on the same surface, never while one rides a pod, and sends the surface with
     every fixed view (pair midpoints, deaths).
   - The overlay's location reads "platform alpha", "cargo pod to vulcanus" or "Vulcanus 40 m". A bodiless rider
     is not shown as dead, and no death alert fires at boarding. A `sleep` aboard does not wake as "died".

A separate review of the diff found five bugs before any live run, all fixed in 2786ba3. `drop` could duplicate
items through repeated entries and refreshed spoilage. A sleep aboard woke as "died". The overlay raised a death at
every boarding and kept a landed bot's ride state. A failed body spawn at landing would have errored in the tick.

Checked against the 2.0.77 API docs (all exist as used):
- `create_cargo_pod` ("setting cargo_pod_destination will cause it to launch")
- CargoDestination: a surface destination with no position goes to a station if one is available, else {0,0}
- `cargo_pod_state` (awaiting_launch, ascending, surface_transition, descending, parking), `force_finish_ascending`
- `rocket`, `attached_cargo_pod`, `launch_rocket(destination?, character?)`
- `LuaPlanet.create_surface`, `game.create_inventory`, `defines.inventory.cargo_unit` and `hub_main`
- `LuaSpacePlatform.space_location` (RW)

Checked on the live engine (`sa`, read-only probe and the engine probe above):
- `defines.inventory.cargo_unit`, `hub_main` and `chest` are all 1, and `defines.cargo_destination.surface` is 3.
- `cargo-pod-container` is a `temporary-container`, which `transfer` now opens as a chest.
- `prototypes.space_location.vulcanus.type` is `planet`; `game.planets.vulcanus.surface` is nil until it is created.
- A hub pod keeps its entity across surfaces, and an empty pod with no pad disappears after landing.

### Tests

- `tests/travel.lua` (new, in `npm test`), against a fake engine:
  - boarding refusals (crafting queue, held stack)
  - armor with its grid and a gun kept in the kit, the body removed, no death counted
  - the camera following the pod onto the platform surface
  - the aboard whitelist (8 allowed, 6 refused)
  - landing refused in transit
  - a landing on Vulcanus at spawn (surface created), the hatch push, the body at the pod's last position with
    armor and gun back
  - respawn on Vulcanus, the last spot remembered
  - a platform lost aboard (death, kit destroyed, respawn on Vulcanus)
  - a pad landing that ends on `parking`, no free hatch, removal in transit
  - minimum ride times when the pod vanishes early, a body that cannot be made (a death, not an error), a renamed
    platform
- `tests/space.lua`: a bot ride goes through the same payload rule, then launches without a character and boards
  the pod. `drop`: repeated entries summed against the hub, whole stacks moved with their freshness, part of a
  stack copied with its spoil progress, pad or position, a refused destination returning the items, platform in
  transit. `tests/waits.lua`: a sleeping rider is not dead.
- `tests/bots.lua`: `where` in `profiles`. `tools/stream/selftest.py`: different-surface pairing refused,
  same-surface pair with the surface sent, location text for planet, platform and pod.
- Results: `npm test` 96/100. The 4 failures are the bridge socket tests, which this sandbox refuses (`listen EPERM`
  on a Unix socket), as before. Every Lua suite passes (runtime 700 assertions, control 66). The stream selftests
  pass.

### The live run (next session with box access)

```
tools/winps.sh tools/win/start-server.ps1 -Name sa -Save sa1 -GamePort 34210 -RconPort 27030
tools/winps.sh tools/win/start-client.ps1 -Name sa -GamePort 34210 -PlayerName pog-sa -Slot -sa -Factorio D:\pog\factorio-2.0.77-expansion
POG_WORLD=sa bin/fh deploy        # control.lua unchanged: hot deploy is enough
tools/sa_travel.py                # logs to runs/sa-travel/smoke.jsonl, with ticks
```

What it does, all on `sa`:
1. Operator setup: research marked done, a silo with power from an electric-energy interface and a ready rocket
   (`rocket_parts` set), and platform `travel-test` from a starter pack (`apply_starter_pack`: test setup only).
2. The bot puts its inventory and ammo into a chest, rides up, reads `platforms` aboard and is refused `move_to`.
3. It schedules the platform to Vulcanus. If the platform does not arrive within `--fly-minutes` (it has no
   thrusters), the operator sets `space_location`.
4. The operator puts a furnace and coal in the hub; the bot `drop`s them and `land`s.
5. On Vulcanus it unpacks the container, mines coal and calcite, builds the furnace and refuels it.
6. Engine probe: a second rocket with a playerless character as rider, then where that character is every 5 s for
   a minute.

The ascent and descent ticks go into the log. The base-game smoke test should run once too (`tools/sa_smoke.py`
covers Space Age Nauvis).

### Left to do

- A real thruster flight. The test platform had none, so the operator moved it. A live run with a director camera
  pointed at the bot, to see cameras and the overlay on a platform and on Vulcanus.
- `nearest` reaches only 64 tiles. On Vulcanus the first resources were 90 tiles from spawn. Either widen it or tell
  agents to use `map` after landing.
- Riding up in the real body: possible (see the probe), but there is no way back down. Stay with the script plan.
- A real director client following a bot onto a platform: cameras teleport a spectator across surfaces, which the
  API allows. Whether the client renders a platform surface well enough for the stream is a question for the run.
- The pod's own descent on stream: cameras follow `b.position`, which tracks the pod on both surfaces.

- A player's Lua state in a hub (`character`, `controller_type`, `physical_surface`, `hub`). One line:
  `/c local p=game.player rcon.print(serpent.line{p.controller_type,p.physical_controller_type,p.character and {p.character.surface.name,p.character.position},p.hub and p.hub.surface.name,p.physical_surface.name})`
- Whether the game strips a rider's inventory, and whether a rider can use their inventory in the hub.
- Where `land_on_planet` puts the character (landing pad or spawn).
- Whether a playerless character can ride (`launch_rocket(dest, character)` for a bot). Bot travel no longer
  depends on it (section 5); `tools/sa_travel.py` ends with this probe.
- Space Age freeplay: crash site, starting items, `freeplay` remote interface, and whether the victory screen comes
  from `space-finish-script` (switch it off for an unbounded game).
- Whether `peaceful_mode` set on a new planet surface at creation calms demolishers and pentapods.
- Which hub inventory is "drop to planet". `drop` takes from `hub_main` into a pod's `cargo_unit` instead, which
  the API documents.
- Whether lightning hits characters on Fulgora.
