# A human team (mt278 part H): what is built, how to turn it on, what a human client gets

Private, mt branches only (left out of the agents' launch tree). Off by default: `POG_MT_HUMANS=0`.

## Turning it on
1. The map: a human team (force `white`) beside the AI teams.
   - A new map: `tools/mt/mt_map.py create --humans [--human-factor 1.75] ...`: its start is a starting point of the
     map (a biter-free start area from tick 0), with the same primary patches as an AI team's.
   - A map made without it (mt275-final): `tools/mt/mt_map.py add-humans --host imac.local --port 27475 --password-file
     ~/.config/pog/rcon-imac-mt.pw`. It runs mt_setup again with every team (the AI teams' forces, spawns and contacts
     as they are), looks for dry land from the target outward (no nearer an AI start), makes the chunks, removes the
     nests within 400 tiles, clears the natural resources and places the team's patches, on Nauvis and its planet
     spawns. On mt275-final the target (0,2830) was a lake (54% water); it took (-414,2951): 2313 tiles from the
     nearest AI start (1.78x the AI spacing of 1300), 1331 enemies removed, all five patches placed.
2. The roster: `agent/mt/humans.tsv`, one player name a line.
3. A run: `POG_MT_HUMANS=1 tools/mt/start-mt.sh RUN MINUTES` (and `POG_MT_HUMANS=1` for imac_mt.sh when it starts the
   server). POG_MT_HUMANS_ARGS adds mt_humans fields (`'"budget_h":10,"block_h":1'`).

## The join flow
- The server: a game password (`~/.config/pog/mt-humans.pw`, made once, given to the humans) and the server whitelist
  (`--use-server-whitelist`): the roster, the camera client pog-cam1 and the setup accounts mt-red ... mt-white. A
  name not on it is refused ("UserNotWhitelisted", tested). No admin list: the console is RCON's alone
  (`allow_commands: admins-only`).
- `require_user_verification` stays off: our iMac clients (camera, setup joins) have no factorio.com token. So the
  game password is what keeps someone else from joining under a roster name. With humans from outside, a token for
  our clients (Nick's factorio.com account) would let verification go on.
- The harness (humans.lua `place`): a roster player who joins goes into the team's force, a character at the team's
  spawn, in the permission group `pog-humans` (no blueprint import or blueprint library; Nick's d29 rule). Anyone
  else is left in the player force (no team sees it). Tested on the iMac: human1 joined in 46 s (game password given by
  the client), force white, at (-415,2951), group pog-humans.
- Mods: the server's exact mod set (research-mods.md's proposal when Nick picks it); a client with others is refused
  by the game itself.
- No harness tools for humans: they play the GUI. The harness sees them: the census and contact detection run per
  team force (the human force is one), the team page lists the freeze state.

## The freeze
Settings (mt_humans): budget_h 10 (a day's budget), block_h 1 (the shortest block), offline_min 30, warm_min 10,
quiet_min 10, day_h 24 (game time: the harness has no wall clock; a paused world spends none).
- Asked by a roster player's chat line `!freeze [HOURS]` (the team's own chat), by the operator (mt_freeze
  {start=true, hours}), or by itself once no roster player has been online for offline_min. Refused when less than a
  block is left today.
- Never within quiet_min of a hit between the team and another team (biters do not count): it waits, then warms up.
  The warm-up (warm_min) is announced to the team in its chat; a hit during it sends it back to waiting.
- While frozen:
  - a cease-fire both ways with every other team (the earlier settings kept and put back);
  - the team's players in the group `pog-frozen`: no action but chat and looking (so a frozen team cannot build or
    attack either);
  - its core entities indestructible: assembling machines (with chemical plants, refineries, foundries, EM plants,
    biochambers, cryogenic plants), furnaces, mining drills, labs, rocket silos, agricultural towers, boilers, steam
    engines and turbines (generator), burner generators, reactors, heat pipes, fusion reactors and generators, solar
    panels, accumulators, electric poles, lightning attractors, offshore pumps, cargo landing pads and cargo bays.
    Belts, inserters, chests, walls and turrets are not: a freeze keeps a team alive, it is no defence.
  - core entities built while frozen (robots) are made indestructible as they appear.
- It ends: an asked block when its hours are up; an automatic one when a roster player is back and its first block_h
  has passed; on `!unfreeze` after block_h; by the operator; or when the day's budget runs out. The core entities go
  back to destructible, except those that were already indestructible before the freeze.
- The AI teams learn it as a fact in the rules-of-contact message (mt_rules' text is the operator's; a sentence for it:
  "One team's players are humans, who sleep: their team may freeze for up to 10 hours a day, in blocks of an hour or
  more, never within 10 minutes of a fight. While frozen, its production, power and landing pad cannot be destroyed,
  and a cease-fire holds both ways.").

### Cost (measured on the iMac copy, 2.0.77 native; a base of 30,100 core entities: small poles)
- `destructible` itself: 0.2 us an entity (30,000 in 6.8 ms).
- Finding them is the cost: one find over every surface 77 ms; a find over the base's own area 15 ms; the chunk list of
  Nauvis (10,651 chunks) alone 18.8 ms. A find costs about 7.5 us a chunk and 0.5 us an entity found.
- So the freeze walks each surface's chunks in rings round the team's spawn, its place kept in storage, spending at
  most STEP_UNITS a tick (a chunk's find 10, an entity 1, a chunk only checked 1). At 6000 units: 37 steps for the
  30,100, median 5.5 ms, max 9.6 ms in the first round; in a second round two steps of 40 and 22 ms, the size of the
  harness heap's collection cycle (memory: GC atomic plus last step 41-58 ms once a cycle), which falls in whatever
  runs. STEP_UNITS is 4000 (about 3.7 ms a step at that median). Live: 30,100 set in 57 ticks, and back in 56.
- An earlier version kept a set of every entity it froze: its hash table's growth made one step 25 ms. It keeps only
  the core entities already indestructible before the freeze (a few) instead.
- The freeze's checks (once a second) read the connected players and a few numbers: no game reads.

## Knowledge
- The human team knows the setup (the AI teams, the rules, the freeze); what Nick tells them.
- Nothing changes for the AI teams: their briefs say nothing of humans; they learn of them by contact, as of any team,
  and of the freeze by the rules-of-contact message.
- Two things a human could learn that the AI teams cannot, and that rules have to cover (lockstep makes them
  unavoidable): see below.

## What a human client gets (H4)
- The harness mod folder (`agent-harness_0.1.0`, 290 files, 9.2 MB on mt/batch278) is every harness module's source:
  control.lua `require`s runtime.lua as its fallback runtime, and runtime.lua `require`s 261 modules, multiteam.lua
  and humans.lua among them, with comments that name the design (10+ files mention mt274-mt278).
- The save a client downloads to join holds `storage.agent_harness`: the deployed runtime's source (the bundle is sent
  without comments, but its names stay: mt_setup, mt_rules, humans, freeze) and every team's harness state (each team's
  board, plans, tells, chat, operator lines in team_stores, the contacts, the bots). Factorio is lockstep: every
  client holds the whole game state in memory, and the downloaded map stays in the client's write-data until the next
  join. Strings in it are readable with ordinary tools.
- Proposal:
  1. A client build of the mod: control.lua, data.lua, the avatar sprites, info.json, and a stub runtime.lua (the
     contract only: dispatch refuses, tick and stop_all do nothing). The real runtime is always deployed into the
     save before a human joins (start-mt.sh deploys first), so the fallback never runs. The server must run the same
     build (a joining client's mods must match the server's), so the mt server's mods folder would hold the client
     build and every deploy goes through RCON as now. No private code ships in the mod.
  2. The save cannot be hidden: the rule for the human team (no reading the game's files or memory; no other
     tools on the game) and trust, as with any streamer team. Tells and boards could be kept out of the save only by
     keeping them off the server, a different harness.
  3. Optional: keep the human team's names out of the AI teams' harness state anyway (they are, by B), and the AI
     teams' names out of what humans see in game (force names are visible to everyone in the force list; neutral
     force names would need line 1's force-name change).
