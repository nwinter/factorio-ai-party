# Space Age overview (Factorio 2.0 expansion)

Space Age (released 21 Oct 2024) is a paid expansion made of four mods: Space Age, Quality, Elevated Rails and
Recycler (Quality is optional). Our base-game world (`live`, 2.0.77) has none of this; eng/spaceage is setting
up a Space Age world. Exact recipes and costs: use the Space Age prototype dump when it exists.

## What changes vs the base game

- The goal is no longer a rocket launch: you finish by flying a space platform to the **solar system edge**
  (first arrival shows the victory screen). Achievements: finish within 100 h ("Work around the clock") and
  within 40 h ("Express delivery"); disabled with peaceful/no enemies.
- The rocket silo comes much earlier: the tech needs 1,000 each of red, green and blue (no purple/yellow).
  A rocket needs 50 parts of 1 low density structure + 1 rocket fuel + 1 processing unit each (base: 100
  parts of 10 each). Rockets carry cargo to platforms, start new platforms, or carry the player.
- Space science is crafted on a space platform from asteroid materials (2 iron plates + 1 carbon + 1 ice ->
  5 packs, 15 s), not from satellites.
- New pack types: metallurgic (Vulcanus), electromagnetic (Fulgora), agricultural (Gleba), cryogenic
  (Aquilo), promethium (deep space). Each planet's pack can only be crafted on that planet.
- Many new trigger techs: Space platform (launch a starter pack), Space science pack (craft an asteroid
  collector), planet-specific triggers like mining a resource or crafting a first item there.
- Biolab (Nauvis-made lab, upgraded), per-recipe productivity research, new buildings (foundry,
  electromagnetic plant, biochamber, cryogenic plant, recycler), turbo belts, elevated rails.
- "Rush to space" achievement: research another planet's pack before production or utility science.

## Space platforms

- Created by launching a **space platform starter pack** in a rocket. Start as 10x10 foundation; built only
  from remote view by the platform itself (it builds ghosts as materials arrive). The **platform hub** is
  storage and control; if it dies the platform is lost.
- **Thrusters** (south edge only) burn thruster fuel + oxidizer, both made from crushed asteroids.
  More thrust = faster, but asteroids hit more often and faster.
- **Asteroid collectors** (edge only) grab chunks; **crushers** turn them into ore and materials:
  metallic (iron, copper), carbonic (carbon, sulfur, coal), oxide (ice/water, calcite), promethium (deep space only).
- Larger asteroids damage the platform; turrets break them into chunks. Gun turrets first, rocket turrets
  (Gleba) for bigger ones, railgun turrets (Aquilo) for huge asteroids near the edge.
- Platforms follow schedules like trains (planet stops, wait conditions); routes fill in intermediate stops.
- Distances: Nauvis to Vulcanus, Fulgora or Gleba 15,000 km each; Vulcanus-Gleba and Fulgora-Gleba 15,000 km;
  Gleba or Fulgora to Aquilo 30,000 km; Aquilo to solar system edge 100,000 km; edge to Shattered Planet
  4,000,000 km.

## The planets

| Planet | Solar | Resources | Pack and key unlocks | Hazards and enemies |
|---|---|---|---|---|
| Nauvis | 100% | iron, copper, coal, stone, oil, uranium | red to yellow, space | biters, pollution |
| Vulcanus | 400% | tungsten (big mining drill only), calcite, coal, lava, sulfuric acid | metallurgic; foundry, big mining drill, turbo belts | demolishers, lava; no water/oil |
| Fulgora | 20% | scrap (recycled into many items), heavy oil ocean | electromagnetic; recycler, EM plant, lightning collector, holmium | lightning storms; no enemies |
| Gleba | 50% | yumako, jellynut, stromatolites, water, stone | agricultural; biochamber, heating tower, spidertron, stack inserter | pentapods, spores, spoilage |
| Aquilo | 1% | ammoniacal solution, lithium brine, fluorine, crude oil (all pumped) | cryogenic; cryogenic plant, fusion, quantum processor, railgun | freezing; bots use 5x power |

- **Vulcanus**: molten world, no water or crude. Lava -> molten iron/copper in foundries; calcite helps.
  Tungsten carbide and tungsten plate lead to the big mining drill and foundry (both trigger techs).
  **Demolishers** (giant worms; small 30k HP, medium 100k, big 300k, huge regeneration) each own a territory
  and attack anything built in it; the start area is outside all territories; killing one frees its land
  for good. Unlocks artillery and speed module 3. Often visited first.
- **Fulgora**: lightning-struck desert islands with ruins. The only ore is scrap; **recyclers** turn it into
  gears, circuits, steel, batteries, holmium ore and more, and everything unwanted must be recycled away
  (balancing outputs is the puzzle). Lightning rods/collectors protect and harvest storms. Trains between
  islands. Unlocks mech armor, tesla turret, quality module 3.
- **Gleba**: swamp farming. Agricultural towers grow fruit; biochambers run on nutrients; iron/copper come
  from bacteria that turn into ore after 1 minute. Most products **spoil** (nutrients 5 min, agricultural
  science pack 1 h, bioflux 2 h). **Pentapods** (wrigglers, strafers, stompers; egg rafts on marsh) are
  attracted by spores, Gleba's pollutant; Gleba has its own evolution. Unlocks rocket turrets, spidertron.
- **Aquilo**: frozen ammonia ocean. Most buildings freeze unless heated (heat pipes from heating towers or
  reactors); build on ice platforms/concrete; iron, copper, coal and stone must be shipped in. Unlocks
  fusion power, quantum processors, railguns, foundation, captive biter spawner, promethium science.
  Travel needs techs from all three inner planets (rocket turrets and heating tower from Gleba, asteroid
  reprocessing from Vulcanus, electromagnetic science from Fulgora, plus advanced asteroid processing).

## Spoilage

- Spoilable items have freshness and turn into "spoilage" (or hatch) when it runs out: anywhere, including
  chests, machines and inserter hands. Stacks average freshness. Higher quality lasts longer.
- Agricultural science packs lose value: a 50% fresh pack gives half the science and is used twice as fast.
- Biter eggs (30 min) hatch into big biters; pentapod eggs (15 min) into wrigglers; a captive biter
  spawner's egg into a behemoth. Hatching inside your base is a real danger.
- Good play on Gleba: throughput over buffers, short lines, filtered inserters that clear spoilage.

## Quality

- Five tiers: normal, uncommon, rare, epic, legendary (legendary counts as tier 5). Higher quality gives
  e.g. +30% health or crafting speed per tier, bigger module effects, more storage.
- Quality modules add a chance to upgrade a crafted item one tier (then 10% chances for each further tier).
  Recyclers return 25% of ingredients, allowing "quality loops". Epic and legendary need Space Age techs.
- Quality is a late-game optimisation; early quality chasing is usually a distraction.

## Endgame: solar system edge, Shattered Planet, promethium

- The **solar system edge** is reached from Aquilo (100,000 km) after research (wiki names "Stellar discovery
  solar system edge"; this name may be 2.1-era, check the dump). Huge asteroids there need railguns.
  Reaching it is the Space Age victory.
- The **Shattered Planet** lies 4,000,000 km beyond; only promethium asteroids remain of it. Asteroid density
  keeps rising; the wiki says players are not expected to arrive. Distance achievements at 10k/30k/60k km.
- **Promethium science pack**: crafted only in space from 25 promethium asteroid chunks + 10 biter eggs +
  1 quantum processor -> 10 packs (5 s). Used for infinite Research productivity.

## Typical order and pacing

- Nauvis to blue science, rocket silo, first platform, space science (experienced: ~5 to 10 h).
- Inner planets in any order; Vulcanus or Fulgora first are common, Gleba often last of the three because of
  spoilage and pentapods. Each planet start is a new small base fed partly by rockets/platforms.
- Then Aquilo, then a well-armed platform to the edge. Experienced players: 40 to 100 h ("Express delivery"
  at 40 h is a challenge); first-timers often 100+ h. Default-settings speedruns are cited around 8 to 9 h
  (unverified).
- Good play: an automated Nauvis base that keeps sending rockets, a platform that travels without manual
  refuelling, each planet's pack shipped home to biolabs, defence on every surface (asteroids, demolisher
  borders, pentapod-facing walls, lightning rods), and using planet specialities (foundries, EM plants,
  big drills) back on Nauvis.

## Sources

- Factorio Wiki, "Space Age": https://wiki.factorio.com/Space_Age
- Factorio Wiki, "Planets": https://wiki.factorio.com/Planets (solar %, gravity, pressure)
- Factorio Wiki, "Vulcanus", "Fulgora", "Gleba", "Aquilo": https://wiki.factorio.com/Vulcanus,
  https://wiki.factorio.com/Fulgora, https://wiki.factorio.com/Gleba, https://wiki.factorio.com/Aquilo
- Factorio Wiki, "Space platform": https://wiki.factorio.com/Space_platform
- Factorio Wiki, "Rocket silo": https://wiki.factorio.com/Rocket_silo
- Factorio Wiki, "Space science pack": https://wiki.factorio.com/Space_science_pack
- Factorio Wiki, "Spoilage mechanics": https://wiki.factorio.com/Spoilage_mechanics
- Factorio Wiki, "Quality": https://wiki.factorio.com/Quality
- Factorio Wiki, "Demolisher": https://wiki.factorio.com/Demolisher; "Pentapods": https://wiki.factorio.com/Pentapods
- Factorio Wiki, "Shattered planet", "Solar system edge", "Promethium science pack":
  https://wiki.factorio.com/Shattered_planet, https://wiki.factorio.com/Solar_system_edge,
  https://wiki.factorio.com/Promethium_science_pack
- Factorio Wiki, "Technologies" (Space Age trigger techs): https://wiki.factorio.com/Technologies
- Factorio Wiki, "Achievements": https://wiki.factorio.com/Achievements
- docs/PLAN.md (Daniel Vestøl's Space Age harness: Astra reached a third planet)
