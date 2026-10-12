# Good vs poor play, rules of thumb, how to judge a team

Machine speeds, power draws, pollution, belt speeds, the steam ratio inputs and the blue science recipe below were
checked against the base 2.0.77 prototype dump on 2026-10-11 (`kb.py entity|recipe`). Other figures: confirm with
the `kb` lookups before quoting them on air.

## How research actually works (say this right)

- Research progress is **never lost**. Switching to another tech saves the progress of the old one; several
  techs can be partly researched at once. Nothing decays, no tech can be "unresearched", and raids cannot
  take research away (they can only destroy labs, which pauses research).
- Research is per force. All our agents share one force, so one research queue and one tech tree.
- A tech costs N *units*; each unit needs one of each listed pack and T seconds of lab time.
  Time = unit time x units / (labs x lab speed). Labs **consume** packs; they produce nothing else.
- A lab works only if it holds every pack type the current unit needs. A red+green tech stalls in a lab
  that has only red. Labs can pass packs to neighbouring labs through inserters.
- 2.0 trigger techs are done by actions: Steam power (craft 50 iron plates), Electronics (craft 10 copper
  plates), Automation science pack (craft a lab), Steel axe (craft 50 steel plates), Oil processing (mine
  crude oil), Uranium processing (mine uranium ore).
- The research queue (on by default) moves to the next tech automatically when one finishes.

## Words for machine states

- **Starved**: a machine has power but is missing input (labs without packs, furnaces without ore,
  assemblers without gears). Usually means an upstream line is too small or broken.
- **Output full / blocked**: the machine's output has nowhere to go (belt backed up, chest full).
  A backed-up belt in front of labs is fine; a backed-up belt of intermediates may mean a downstream gap.
- **Low power / brownout**: demand exceeds supply; everything electric slows down proportionally
  (inserters, assemblers, labs, drills). Not the same as "no power" (disconnected).
- **Idle labs**: labs not consuming packs; either starved, missing one pack type, or no research queued.

## Signs of good play

- SPM grows steadily; labs are almost always working (no idle labs, all needed pack types present).
- Packs and plates move by **belts** (or bots), not by hand; boilers and burners fed by belt.
- **Power headroom**: production above peak demand with spare boilers/engines; coal belted to boilers.
- Ratios planned: e.g. enough gear and circuit assemblers that science assemblers never wait.
- A **main bus** or another layout with room to grow; a **mall** that builds belts, inserters, assemblers,
  poles, furnaces automatically so building never waits on hand-crafting.
- Iron capacity built ahead of need (iron is the usual limit early); copper matched to circuit demand.
- **Defence before pollution reaches nests**: gun turrets with ammo at outposts and the pollution edge,
  later walls and turret lines; someone watches attack alerts and re-arms turrets.
- Oil scouted early and fluid handling researched before the oil push.
- **Rushing construction robots** after blue science; blueprints for repeated blocks.
- In a team: one owner per job, one coordinator for the research queue, clear handoff points.

## Signs of poor play

- **Hand-feeding**: carrying plates to assemblers or packs to labs; fuelling dozens of burner drills by hand.
- **Starved labs** while lots of labs exist (labs built faster than packs).
- **Brownouts** from too few boilers/engines, or **boilers out of coal** (whole factory stops).
- **Burner drills** kept long after electric mining; they need fuel, pollute more (12/min vs 10/min each,
  wiki), and mine at half the rate of electric drills.
- **Spaghetti that blocks expansion**: belts crossing everything, no room to add machines.
- **Red science overbuilt without green**: red-only techs run out fast; mid-game needs red+green together.
- **Ignoring defence** until the first raid; undefended outposts (a raid can take a whole coal field).
- Mixed belt lanes (two items on one lane jam), inserters placed backwards, chests filled with the wrong item.
- Building oil before research can use it, or blue science parts with no plastic supply.
- Duplicated work: several separate half-lines instead of one finished one (four green lines,
  one fully automated, is a typical sight).

## Standard ratios and rates (rules of thumb; confirm with the dump)

- Steam: 1 offshore pump : 20 boilers : 40 steam engines (pump 1,200 water/s; boiler 1.8 MW, 60 steam/s;
  engine 900 kW, 30 steam/s). 1 boiler feeds 2 engines = 1.8 MW. A boiler burns ~0.45 coal/s (4 MJ coal).
- Belts: yellow 15 items/s, red 30/s, blue 45/s (both lanes together).
- Mining: electric drill 0.5 ore/s (90 kW); burner drill 0.25 ore/s. About 30 electric drills fill a
  yellow belt.
- Smelting: iron/copper plate 3.2 s. Stone furnace (speed 1) ~0.31 plates/s, steel furnace (speed 2)
  ~0.63/s. 48 stone or 24 steel furnaces fill a yellow belt. ~1 electric drill per 1.6 stone furnaces.
- Assembler crafting speed: AM1 0.5, AM2 0.75, AM3 1.25.
- Red pack 5 s, green pack 6 s: build red:green assemblers 5:6. For 1 pack/s (60 SPM) of each: 10 red +
  12 green with AM1, or ~7 red + 8 green with AM2.
- Gear 0.5 s; copper cable 0.5 s for 2; green circuit 0.5 s (1 iron + 3 cable): 3 cable : 2 circuit
  assemblers.
- Blue pack: 2 engine units + 3 advanced circuits + 1 sulfur -> 2 packs, 24 s (check dump).
- Labs needed: labs = units per second x unit time (a unit takes one pack of each type; lab speed 1,
  no modules). E.g. 1 pack/s on a 30 s-per-unit tech needs 30 labs; on a 5 s tech, 5 labs.
- Power draws to sanity-check headroom: assembler 1 ~75 kW, assembler 2 ~150 kW, lab ~60 kW,
  electric drill 90 kW, electric furnace 180 kW (check dump).

## Rough SPM benchmarks by game time (our judgement, not a record)

SPM in the community = science packs consumed per minute **of each type** being researched ("a 60 SPM base" makes
60 red, 60 green, ... per minute). **On our stream the overlay headline and the analyst's "SPM" are all pack colours
summed**, so 15 red + 12 green shows as 27 SPM. Say which one when quoting; the table below is per type.

| Game time | Weak | Competent human | Strong / speedrun-like |
|---|---|---|---|
| 30 min | red hand-fed | red ~10, green starting | red+green ~20-30 |
| 1 h | red ~10, green <10 | red+green 20-45 | red+green 45-60, oil started |
| 2 h | no blue | blue started, red+green 30-60 | blue 30+, robots |
| 4 h | blue trickle | red/green/blue 45-90 | purple/yellow running |
| 8 h | | rocket parts begun | rocket launched |

For scale: a raid on an undefended outpost can take green from 30 a minute to nothing; a well-run two-player
peaceful game makes about 15 red and 14 green a minute over 2 h and reaches blue by about 1h30.

## How to judge a team at a given moment

1. Research: what is being researched, how far, and is it the right next step (milestones.md)?
2. Labs: how many, how many working, which pack is missing.
3. Science supply: pack production per minute vs lab demand; which intermediate is short
   (gears, circuits, inserters, belts; for blue: plastic, sulfur, engines, advanced circuits).
4. Plates: iron and copper per minute and the trend; which ore patch feeds it; drills burner or electric.
5. Power: production vs demand, satisfaction %, coal stock at boilers; is a brownout coming?
6. Defence: turrets at outposts and near pollution sources, ammo, recent losses; evolution factor.
7. Logistics: belts vs hand carrying; any blocked lines (mixed lanes, full chests).
8. Team: who owns what, duplicated or unowned work, idle agents.
- A good one-line judgement names a number, a comparison and a cause, e.g. "15 SPM green at 40 min,
  up from 9 ten minutes ago; green is starved by copper; next is oil, usually around 1 to 2 h."

## Common mistakes to watch for (and name kindly)

- Placing inserters the wrong way; feeding fuel and ore on one belt lane; long-handed vs normal inserter.
- Power poles not connecting two networks; steam engines placed but not piped.
- Furnace columns starved because the ore belt broke (8 of 12 furnaces idle is a typical sight).
- Running pipes too far without pumps (2.0 fluids: long segments lose throughput; check before saying it).
- Walking characters into biter groups (the usual cause of deaths). Respawn is free but loses time.

## Sources

- Factorio Wiki, "Research": https://wiki.factorio.com/Research (progress saved when switching, formula)
- Factorio Wiki, "Technologies": https://wiki.factorio.com/Technologies (trigger techs)
- Factorio Wiki, "Pollution": https://wiki.factorio.com/Pollution (machine pollution values)
- Factorio Wiki, "Power production": https://wiki.factorio.com/Power_production
- Factorio Wiki, "Tutorial:Main bus": https://wiki.factorio.com/Tutorial:Main_bus
- docs/PLAN.md (two-player totals)
