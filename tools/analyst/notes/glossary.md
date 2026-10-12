# Glossary and misconceptions

One line each. "We/our" = the AI team's force.

## Terms

- **SPM**: science packs per minute consumed by labs, usually quoted per pack type ("60 SPM" = 60 of each type).
- **eSPM**: "effective" SPM, adjusted for productivity modules/research; megabase talk.
- **Science pack colours**: red automation, green logistic, grey military, blue chemical, purple production,
  yellow utility, white space (Space Age adds metallurgic, electromagnetic, agricultural, cryogenic, promethium).
- **Tech / research**: a technology unlocked by feeding packs to labs; unlocks recipes or bonuses.
- **Trigger tech**: a 2.0 tech finished by an action instead of packs (craft 50 iron plates -> Steam power,
  craft 10 copper plates -> Electronics, craft a lab -> Automation science pack, mine crude oil -> Oil processing).
- **Research queue**: ordered list of techs; the next starts automatically.
- **Infinite research**: repeatable techs (e.g. mining productivity) with rising cost; endgame sink.
- **Main bus**: a wide bundle of parallel belts carrying plates and intermediates down the base, with
  factory blocks branching off; easy to extend.
- **Mall**: assemblers that automatically make building items (belts, inserters, poles, assemblers) into chests.
- **Spaghetti**: belts and pipes routed ad hoc, tangled; works but is hard to expand or debug.
- **Ratios**: machine counts balanced so nothing starves or backs up (e.g. 3 cable : 2 circuit assemblers).
- **Direct insertion**: an inserter moving items straight from one machine into the next, no belt.
- **Sushi belt**: one belt carrying many item types in a loop (lab feeds, Gleba); compact but jams easily.
- **Lane**: each belt has two lanes; mixing items on a lane is a common jam.
- **Saturated / compressed belt**: a belt with no gaps; running at full throughput.
- **Starved**: machine powered but missing inputs.
- **Backed up / blocked**: output has nowhere to go.
- **Brownout**: power demand above supply; everything electric slows. "Blackout": no power at all,
  e.g. boilers out of coal.
- **Burner phase**: start of the game before electricity; burner drills and stone furnaces fed by hand.
- **Outpost**: a remote mining or production site, often reached by train; needs its own defence.
- **Smelting column / array**: a row of furnaces fed by an ore belt.
- **Block / cell**: a self-contained production unit (e.g. green science block); "city blocks" are a grid layout.
- **Beacon**: building that spreads module effects to nearby machines.
- **Modules**: speed, productivity, efficiency (and quality in Space Age) put into machines.
- **Bots**: construction robots (build, repair, rebuild) and logistic robots (move items between chests).
- **Roboport**: bots' base; defines the logistic/construction area.
- **Blueprint**: saved layout that can be placed as ghosts; bots or the player then build it.
- **Ghost**: a planned or destroyed entity outline waiting to be built.
- **Cracking**: turning heavy oil -> light oil -> petroleum gas in chemical plants.
- **Advanced oil processing (AOP)**: refinery recipe giving all three oils from crude + water.
- **Kovarex**: uranium enrichment loop for U-235.
- **UPS**: game updates per second (60 normal); a megabase may drop UPS, slowing the game.
- **FPS**: frames per second of a client; different from UPS.
- **Megabase**: a huge base, usually 1,000+ SPM.
- **Deathworld**: map preset with many more biters and faster evolution.
- **Evolution**: 0 to 1 factor making biters bigger over time, pollution and nest kills.
- **Nest / spawner**: biter or spitter base; **worm**: stationary enemy turret.
- **Turret creep**: advancing turrets step by step to clear nests.
- **Pollution cloud**: per-chunk pollution shown on the map; harmless itself, it triggers attacks.
- **Chunk**: 32x32 tile map unit (pollution, charting).
- **Charted**: map area revealed (by players or radar). Our harness only queries charted chunks.
- **Hand-feeding / hand-crafting**: doing by hand what a machine should; fine early, a smell later.
- **Lazy bastard**: achievement for launching with at most 111 hand-crafts; shorthand for minimal hand work.
- **Any% / default settings (speedruns)**: categories; default settings = standard map, enemies on.
- **Space platform, planet discovery, quality, spoilage, demolisher, pentapod**: see space-age.md.

## Misconceptions commentators must avoid

- **Research progress is not lost.** Switching techs keeps the partial progress; nothing decays; raids can
  only destroy labs, which pauses research until rebuilt.
- **Labs only consume packs.** They don't make anything; a lab missing one pack type for the current tech
  sits idle even if full of the others.
- **Damaged buildings are not enemies.** A red health bar on a drill or turret is ours, still working, and
  waiting for repair (repair packs or construction bots).
- **"Base under attack" lists our entities hit, not enemy units.** "7 lost near (12, -40): 4 stone wall, 3 gun
  turret (by 5 small biter)" means we lost 7 buildings to 5 small biters.
- **"Attacking" means biters reaching our structures.** Nests visible on the map, or pollution touching them,
  is not yet an attack.
- **Pollution is not damage.** It hurts nothing directly (except trees); it recruits biters and raises evolution.
- **Biters don't come randomly.** Attacks come from pollution reaching nests (and from expansion or retaliation).
- **More labs is not more science** unless packs keep up; idle labs mean supply, not lab count, is short.
- **Low power is not no power.** A brownout slows everything; it doesn't stop it.
- **A death is not game over.** Characters respawn at spawn; they lose time and must recover their corpse items.
- **Steam engines don't burn coal.** Boilers burn fuel; engines turn steam into electricity.
- **Oil is not mined like ore.** Pumpjacks on oil wells, then refineries; oil processing is a 2.0 trigger tech
  (mine crude oil) after Oil gathering is researched.
- **The rocket is not just a building.** It needs rocket parts (base 2.0: 100 parts of 10 LDS, 10 rocket
  fuel, 10 processing units each, plus a payload; Space Age: 50 parts of 1 of each, and the first payload is
  the space platform starter pack); the silo alone is not the win.
- **In Space Age the win is reaching the solar system edge**, not the first rocket.
- **The crash site is scenery.** The wrecked spaceship at spawn (`crash-site-spaceship`, wrecks) is there
  from tick 0 in base and Space Age; its fire is harmless and is not an attack; nothing crashed in the run.
- **Agents share one research tree and one factory**; a tech finishing is the team's result.
- **Game time vs wall time**: in turn mode the game pauses while agents think; quote game time.

## Sources

- Factorio Wiki, "Research": https://wiki.factorio.com/Research
- Factorio Wiki, "Technologies": https://wiki.factorio.com/Technologies
- Factorio Wiki, "Tutorial:Main bus": https://wiki.factorio.com/Tutorial:Main_bus
- Factorio Wiki, "Pollution": https://wiki.factorio.com/Pollution
- Factorio Wiki, "Enemies": https://wiki.factorio.com/Enemies
- Factorio Wiki, "Rocket silo": https://wiki.factorio.com/Rocket_silo
- Factorio Wiki, "Achievements": https://wiki.factorio.com/Achievements
- tools/stream/live.py (alert texts), docs/PLAN.md (fair-play rules, game time)