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
| Spoilage | Nothing reads `spoil_percent` or spoil ticks. Inventories show counts only, and `feed`/`collect` ignore freshness. Nothing spoils on Nauvis until biter eggs (captured spawners) or Gleba fruit arrive. | Missing; needed before Gleba. |
| Crash site | Space Age freeplay keeps the Nauvis crash site. The harness already ignores its zero-damage fire in the combat detector, and bot spawn rings route around the wreck. | No change. |
| Surfaces in reads | Observation reads use the actor's own surface, so they follow a player to another planet. `nearest`/`scan`/`map` stay limited to charted chunks of that surface. | Present. |
| Cameras | Directors follow a bot or player across surfaces (`p.teleport(target, surface)` on a surface change). A player sitting in a platform hub has no character, so the camera uses the player's position. | Present. |
