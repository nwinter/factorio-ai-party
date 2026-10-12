# Space Age: the Nauvis start and the first platform (Factorio 2.0.77)

Space Age (released 21 Oct 2024) is the paid expansion: mods space-age, quality and elevated-rails on top of
base. Our dump world `sa` runs base, elevated-rails, quality and space-age 2.0.77 plus agent-harness (dump:
settings.json). Numbers marked "dump" come from `kb/space-age-2.0.77/`; check anything else with `kb.py`.
A 2 h run will mostly be the Nauvis start; read the first three sections first.

## 1. The Nauvis start: what is the same, what differs

Same as base 2.0:
- Same planet, ores (iron, copper, coal, stone, crude oil, uranium), biters, pollution and evolution. Dump
  world `sa`: evolution time 4e-6, pollution 9e-7, kills 0.002 (base defaults), expansion on, tech price x1,
  and **peaceful mode on**. Check the run's own settings before talking about attacks.
- Nauvis day-night cycle 25,200 ticks = 7 min (dump: locations.json).
- Same science packs and recipes (dump, identical in both dumps): red 1 copper plate + 1 gear, 5 s; green 1
  belt + 1 inserter, 6 s; grey 1 piercing magazine + 1 grenade + 2 walls -> 2, 10 s; blue 1 sulfur + 3
  advanced circuits + 2 engines -> 2, 24 s.
- Same lab (60 kW, speed 1, 2 module slots; dump). Many circuit and belt recipes moved to new categories
  ("electronics", "pressing") so planet machines can make them; assemblers still make them (dump).
- The crash site, below. Both dumps contain the same crash-site entities.

The crash site (scenery, not an event):
- Every freeplay game starts beside the wreck of the player's crashed ship (intro backstory). Entities
  (dump, both versions): `crash-site-spaceship` (600 HP, 5 slots), `crash-site-spaceship-wreck-big-1/2`
  (150 HP, 2 slots), `...-wreck-medium-1/2/3` (100 HP, 1 slot), `crash-site-chest-1/2` (350 HP, 48 slots).
  Small wrecks `crash-site-spaceship-wreck-small-1..6` exist too (seen in build errors; not in the
  dump because their type is not dumped).
- The pieces hold a few starter items (agents report "wreck loot" plates). They have no
  mining products of their own: mining one gives whatever is inside and removes it (factorio-data).
  Agents mine wrecks to clear building space; deconstruction marking does not work on them (agents' notes).
- The wreck burns: `crash-site-fire-flame` and smoke entities (factorio-data). Our harness logs the flames
  as zero-damage "hits" on `crash-site-spaceship` (hundreds of them) and now ignores them: **not an
  attack, nothing crashed during the run, nothing hit the base.**
- Exact starting items in Space Age freeplay are unverified (docs/SPACEAGE.md; `tools/sa_smoke.py` probes).

Trigger technologies (done by an action, no packs; dump: technologies.json):
- Steam power: craft 50 iron plates. Electronics: craft 10 copper plates. Both have no prerequisites.
- Automation science pack: craft 1 lab (needs Electronics + Steam power). Red research starts after this.
- Oil processing: mine crude oil (needs Oil gathering, a pack tech). No crude found = no refinery, plastics or blue.
- Steel axe: craft 50 steel plates. Uranium processing: mine uranium ore.
- Space Age only, later: Space platform (create a platform), Space science pack (build an asteroid
  collector), and planet triggers (mine calcite, a big volcanic rock, a Fulgoran ruin vault, stromatolites...).
- Research progress is kept when labs switch techs; nothing is ever lost (kb note, wiki Research).

Nauvis tree to blue (dump, `kb.py path chemical-science-pack`):
- 15 techs from a new game: electronics > steam-power > automation-science-pack > automation >
  logistic-science-pack > steel-processing > automation-2 > engine > fluid-handling > oil-gathering >
  oil-processing > plastics > advanced-circuit > sulfur-processing > chemical-science-pack.
- 1,050 red + 915 green; 347 lab-minutes (35 min with 10 labs, 17 with 20). Same as base.

What Space Age changes before space (dump, base vs Space Age):
- Rocket silo tech is much cheaper and earlier: 1,000 x (red, green, blue), 60 s each; no purple/yellow.
  Base: 1,000 x (red, green, blue, purple, yellow) behind productivity/speed module 3 and utility science.
- Path to the silo: 29 techs, 4,225 red, 4,090 green, 2,650 blue, 2,585 lab-minutes (Space Age) vs 44 techs,
  5,960/5,785/3,350/1,600 purple/1,000 yellow, 3,740 lab-minutes (base) (`kb.py path rocket-silo`).
- Some Nauvis techs now need space science: module 2s (200 units), logistic system (requester chests),
  Kovarex. Automation 3 costs 500 (base 150). Cliff explosives and coal liquefaction need Vulcanus packs.
- **Quality** starts early: Quality module tech is 500 x (red, green) after Modules and unlocks uncommon
  and rare. Epic needs Gleba science, legendary all planets. Only mention it if the game shows quality.
- No satellite (recipe absent; base satellite gave 1,000 space science). Space science comes from a platform.
- No recycling on Nauvis early: the recycler recipe needs magnetic field 99 (Fulgora only) and the Recycling
  tech triggers by mining a Fulgoran ruin vault (dump).
- Biolab (speed 2, 4 module slots, 300 kW) is very late: tech 1,000 x 8 pack types; recipe needs biter
  eggs, U-235, refined concrete, a lab and capture-robot rockets (dump).
- Total techs: 275 (Space Age) vs 196 (base) (dump).

## 2. The rocket

- Silo tech prerequisites (dump): advanced-material-processing-2, concrete, logistic-robotics,
  low-density-structure, processing-unit, rocket-fuel. Unlocks: rocket silo, rocket part, cargo landing
  pad, space platform starter pack, space platform foundation, and turns on space platforms.
- Silo recipe: 1,000 steel, 200 processing units, 200 electric engines, 100 pipes, 1,000 concrete, 30 s.
  Silo: 5,000 HP, 4 module slots (dump).
- Rocket part: 1 processing unit + 1 low density structure + 1 rocket fuel, 3 s (dump). **50 parts per
  rocket** (dump `rocket_parts_required`; base 100 parts of 10 each). One rocket = 50 of each ingredient
  (base 1,000 of each).
- Cargo landing pad: 25 steel, 10 processing units, 200 concrete; 80 slots (dump). Platforms drop cargo to it.
- A rocket lifts 1 t (docs/SPACEAGE.md, `rocket_lift_weight`). Item weights (dump): starter pack 1 t (a
  whole rocket), iron plate 1 kg (1,000 per rocket), gun turret 20 kg (50), asteroid collector 100 kg (10).
- What the first rocket is for: launching the space platform starter pack to create the first platform.
  Later rockets carry cargo up to platforms or carry the player (wiki Rocket silo).
- **A launch does not end the game in Space Age.** The goal is a platform reaching the solar system edge
  (wiki Space Age). In base 2.0 the first launch shows the victory screen.
- Wiki: a Space Age silo with a buffered rocket launches about every 27 s.

## 3. The first space platform

- Space platform starter pack: 20 steel + 20 processing units + 60 space platform foundation, 60 s (dump).
  Foundation: 20 steel + 20 copper cable, 10 s (dump).
- Space platform tech: trigger "create a space platform" (launch the starter pack); unlocks asteroid
  collector, crusher, basic metallic/carbonic/oxide crushing and cargo bay (dump).
- The new platform is a 10x10 foundation with the hub in the middle (wiki). Hub: 1,000 HP, 59 slots (dump).
  Lose the hub and the whole platform and its contents are lost (wiki).
- The platform builds itself: ghosts placed in remote view are built from hub stock as materials arrive; no
  robots, no character on board needed (wiki).
- Asteroid collector (5 processing units, 8 electric engines, 20 LDS; 300 HP, 72 kW): building one fires
  the Space science pack trigger (dump). Collectors grab small chunks floating past.
- Crusher (540 kW, speed 1; dump), 2 s per chunk, 20% chance to return the chunk: metallic -> 20 iron ore;
  carbonic -> 10 carbon; oxide -> 5 ice (dump). Copper ore, sulfur and calcite need Advanced asteroid
  processing (Gleba-era tech, 2,000 x 7 packs).
- Space science: 2 iron plates + 1 carbon + 1 ice -> 5 packs, 15 s, in assemblers, only where gravity is 0,
  i.e. on a platform (dump surface condition). Iron plates come from smelting crushed ore on board. Packs
  then drop to Nauvis for the labs. Stack size 200 (base 2,000) (dump).
- Space science unlocks 14 techs, including Space platform thruster: 500 x (red, green, blue, space);
  unlocks thruster, thruster fuel, oxidizer and ice melting (dump).
- Thruster: 10 steel, 10 processing units, 5 electric engines; 300 HP (dump); south edge only (wiki). It
  burns two fluids made on board in chemical plants, space only (dump): thruster fuel 2 carbon + 10 water ->
  75, 2 s; oxidizer 2 iron ore + 10 water -> 75, 2 s; water from ice melting, 1 ice -> 20 water, 1 s.
- More thrusters = faster, but asteroids come more often and hit harder (wiki).
- To travel: at least one thruster and fuel, plus the destination researched. Planet discovery Vulcanus,
  Fulgora, Gleba: 1,000 x (red, green, blue, space) each, after the thruster tech; Fulgora also needs
  accumulators, Gleba landfill (dump). Path to Vulcanus discovery: 33 techs, 1,500 space packs (kb path).
- Distances (dump): Nauvis to Vulcanus, Fulgora, Gleba 15,000 km each; Vulcanus-Gleba and Gleba-Fulgora
  15,000; Gleba or Fulgora to Aquilo 30,000; Aquilo to solar system edge 100,000; edge to Shattered Planet
  4,000,000. No direct Vulcanus-Fulgora route. Schedules work like train schedules (wiki).
- What can go wrong, in host words:
  - Parked over Nauvis it is safe: only harmless chunks there (wiki Asteroid).
  - Between planets medium asteroids appear; with no turrets on the front (north) edge they smash foundation
    and machines; if the hub dies the platform is gone. Gun turrets need ammo shipped up.
  - Out of fuel or oxidizer: thrusters stop and the platform drifts, waiting to be refuelled.
  - Bigger asteroids beyond Fulgora/Gleba (gun turrets poor; rocket turrets from Gleba), huge beyond
    Aquilo (railguns) (wiki Asteroid).

## 4. What hosts get wrong

Hand the hosts the true statement ("the wreck is scenery from before the game", "research progress is always
kept"), never the mistake with a "not": their fast writer tends to drop the "not".

- The wreck at spawn is scenery from tick 0: not enemies, not an attack, not a crash during the run. Its
  fire is harmless flicker. Agents' characters never "crash"; an agent that is quiet is thinking or waiting.
- Damaged buildings are ours (red health bars), not enemy counts. "Lost" lists are our buildings.
- Research progress is never lost, not when labs switch, not when labs are destroyed.
- A rocket launch is a milestone, not victory. Victory is a platform at the solar system edge.
- The Shattered Planet is 4,000,000 km past the edge; nobody is expected to arrive (wiki).
- Quality, spoilage and other planets don't matter in the first two hours unless the game shows them.
- Space science is made on a platform, not in Nauvis assemblers, and not from satellites.
- Basic asteroid crushing gives iron ore, carbon and ice only; no copper.
- Peaceful mode (if on) means biters only fight back when attacked; check before calling an attack.

## 5. Pacing

- The silo path is 2,585 lab-minutes, over 2 h of lab time even with 20 labs fully fed. **In a 2 h run,
  oil, plastics and blue science are the realistic headline milestones.**
- Community (forums, experienced players on a 40 h run): silo researched by about 5 h ("5 to 10 hours"),
  first platform making space science 1 to 2 h later, first mobile platform about 12 h. Nauvis is often the
  slowest planet. Treat as fast-player numbers.
- Typical full game: 40 to 100 h for experienced players ("Express delivery" achievement under 40 h);
  first-timers often 100 h or more (wiki Achievements; community, unverified).

## 6. The planets (short)

| Planet | Solar (dump) | Resources | Pack and key unlocks | Hazards |
|---|---|---|---|---|
| Nauvis | 100% | iron, copper, coal, stone, oil, uranium | red to yellow; rocket | biters, pollution |
| Vulcanus | 400% | tungsten, calcite, coal, lava, sulfuric acid | metallurgic; foundry, big drill, turbo belts | demolishers |
| Fulgora | 20% | scrap (recycled), heavy oil | electromagnetic; recycler, EM plant | lightning |
| Gleba | 50% | yumako, jellynut, stromatolites | agricultural; biochamber, rocket turret | pentapods, spoilage |
| Aquilo | 1% | ammonia, lithium brine, fluorine, oil | cryogenic; fusion, quantum processor, railgun | freezing |

- Vulcanus: no water; molten iron/copper from lava in foundries. Demolishers (giant worms) own
  territories; the landing area is outside them. Often visited first.
- Fulgora: the only ore is scrap; recyclers turn it into gears, circuits, holmium and more; lightning rods.
- Gleba: farming; most products spoil (agricultural science loses value as it ages); pentapods follow spores.
- Aquilo: everything freezes without heat. Discovery: 3,000 x 9 packs, needing techs from all three inner
  planets (dump).
- Edge and Shattered Planet: the Promethium science pack tech (2,000 x 10 packs, after biter egg handling
  and fusion) unlocks both locations (dump). Promethium pack: 25 promethium chunks + 1 quantum processor +
  10 biter eggs -> 10, 5 s, cryogenic plant, in space (dump).

## Sources

- Dump: tools/analyst/kb/space-age-2.0.77/ and base-2.0.77/ (recipes, technologies, items, entities,
  locations, settings); `tools/analyst/kb.py` tech, recipe, path, planets, search.
- factorio-data (Wube's public prototypes): core/lualib/crash-site.lua and base/prototypes/entity/crash-site.lua,
  https://github.com/wube/factorio-data
- Factorio Wiki: Space Age https://wiki.factorio.com/Space_Age; Rocket silo https://wiki.factorio.com/Rocket_silo;
  Space platform https://wiki.factorio.com/Space_platform; Asteroid https://wiki.factorio.com/Asteroid;
  Research https://wiki.factorio.com/Research; Achievements https://wiki.factorio.com/Achievements;
  Planets https://wiki.factorio.com/Planets; Shattered planet https://wiki.factorio.com/Shattered_planet
- Factorio forums, "Advice For 40 Hour Space Age Run": https://forums.factorio.com/viewtopic.php?p=680279
- docs/SPACEAGE.md (rocket lift 1 t, crash-site status), milestones.md,
  agents' notes (wreck mining, "wreck loot"), tools/stream/live.py (zero-damage hits ignored)
