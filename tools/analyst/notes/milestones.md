# Milestones, pacing and "what comes next" (Factorio 2.0 base game)

Exact recipes, tech costs and prerequisites come from the prototype dump (`kb/`); this file covers order,
pacing and judgement. Game time = in-game time (ticks / 3600 minutes). Our harness pauses the game while
agents think in turn mode, so compare game time, not wall time.

## The standard progression

1. **Burner phase (0 to ~10 min).** Hand-mine stone and wood, craft stone furnaces and burner mining drills,
   put burner drills on iron, copper, coal and stone, smelt in stone furnaces. Everything is fuelled by hand.
   - 2.0: the first techs are *trigger technologies*, finished by doing something, not by science packs:
     Steam power = craft 50 iron plates; Electronics = craft 10 copper plates; Automation science pack =
     craft a lab. Nothing can be researched with packs until a lab has been crafted.
     (If no research starts long after a lab is crafted, the trigger may not have fired: say what is seen.)
2. **Steam power (~5 to 15 min).** Offshore pump -> boiler -> steam engines, small electric poles. Boilers
   burn coal (or wood). From here power is the backbone: electric drills, assemblers, labs, inserters.
3. **Red science automated (~10 to 20 min).** Labs fed with automation science packs (copper plate + gear)
   from assemblers. First pack techs (2.0 names): Automation (assembler 1), Electric
   mining drill, Logistics (splitters, undergrounds), Logistic science pack, Gun turret, Military.
4. **Green science (~20 to 40 min).** Unlocked by the Logistic science pack tech (red packs).
   Logistic science pack = inserter + transport belt. Needs a gear, circuit
   and iron supply line; the first real "factory block". Unlocks most mid-game techs.
5. **Steel (~20 to 40 min).** Steel processing (red science). Steel furnaces, medium poles, needed for oil
   and for the rocket. Steel axe is a 2.0 trigger tech (craft 50 steel plates).
6. **Oil (~45 min to 2 h).** Oil gathering (pumpjack, packs) -> Oil processing (2.0 trigger: mine crude oil)
   -> refinery + chemical plant -> petroleum gas -> plastic and sulfur. Requires finding an oil field
   (scouting; often far away, long pipes or later trains). Fluid handling (pumps, tanks, barrels) first.
7. **Blue science (~1 to 2.5 h).** Chemical science pack = engine units + advanced circuits (plastic) +
   sulfur. Biggest jump in complexity: four parallel chains (steel/engines, plastic, red circuits, sulfur).
8. **Robots (~1.5 to 3 h).** Robotics -> Construction robotics (roboports, construction bots: build
   blueprints, repair damage, rebuild destroyed entities) -> Logistic robotics. Experienced players rush
   construction bots: they turn blueprints into instant builds. GPT-6 Astra did this in its 44 h win.
9. **Purple and yellow (~3 to 6 h).** Production science (electric furnace, productivity module, rails) and
   utility science (processing units, flying robot frames, low density structures). Usually also a rail
   network and new ore outposts, since starting patches run low.
10. **Rocket silo (~5 to 15 h).** Rocket silo tech needs all of red/green/blue/purple/yellow. Silo recipe
    (wiki): 1,000 concrete, 200 electric engine units, 100 pipes, 200 processing units, 1,000 steel plates.
    Base 2.0 rocket: 100 rocket parts, each 10 low density structures + 10 rocket fuel + 10 processing
    units (so 1,000 of each per rocket). A cargo landing pad must exist before launch.
11. **Rocket launch / space science.** Base 2.0: first launch shows the victory screen; since 2.0.7 the
    rocket needs a payload to win. A satellite returns 1,000 space science packs (white) to the landing pad.
    Space science feeds infinite research. (Space Age changes all of this; see space-age.md.)

## Typical pacing for comparison

- **Speedrunners (any% / default settings).** Unverified in 2.0: community posts cite default-settings
  rocket runs of roughly 2 h 20 to 3 h (1.1 era: "under 3 hours" for the best), any% (seeded, custom map
  allowed) roughly 1 h 20 to 1 h 30, and community comments that 2.0 runs are about an hour longer than
  1.1. Space Age default-settings record cited around 8 h 15 to 8 h 50. Treat these as order of magnitude.
- **Experienced players, normal play.** The "There is no spoon" achievement (launch a rocket within 8 h)
  is a recognised challenge for experienced players; "No time for chitchat" is 15 h. Both are disabled
  with peaceful/no enemies. A relaxed experienced run reaches the rocket in roughly 10 to 30 h.
- **First-time players.** Commonly 30 to 100+ hours to the first rocket (no single authoritative source;
  say "often dozens of hours").
- Rough human checkpoints (competent, not speedrunning; our estimate, not a cited record):
  steam ~10 min, red automated ~15 min, green automated ~30 min, oil/plastic ~1 to 1.5 h,
  blue science ~1.5 to 2.5 h, construction bots ~2 to 3 h, purple/yellow ~4 to 6 h, rocket 8 to 15 h.

## Judging this team's pace

Compare the team with the human checkpoints above and with its own earlier minutes (the digest, game_snapshot,
and history_world for a later shift of the same world). A team of AI agents sharing one world duplicates work and
carries items by hand more than one experienced player would, and raids cost it time; say what the numbers show.

## What comes next (after X, usually Y, because Z)

- After **burner mining** -> steam power: everything after needs electricity; hand-fuelling does not scale.
- After **steam power** -> craft a lab (2.0 trigger) and automate red science: research is the clock.
- After **red automated** -> Automation, Logistics, Gun turret, then green science; green unlocks most techs.
  With biters on, gun turrets come before pollution reaches nests (on this seed, about 15 to 20 min in).
- After **green automated** -> scale red+green to a target (e.g. 30-60 SPM) and get steel; then Oil
  gathering + Fluid handling, and scout for oil, because blue science needs plastic and sulfur.
- After **oil processing** -> plastic + sulfur + advanced circuits -> blue science. Advanced oil
  processing and cracking follow once petroleum is the bottleneck.
- After **blue science** -> construction robots (the biggest quality-of-life jump), Advanced material
  processing (steel furnaces), Automation 2, Electric energy distribution, then solar/accumulators or
  more boilers, and better defence (stone walls, laser turrets) as evolution rises.
- After **robots** -> purple and yellow science, trains to new ore fields, modules.
- After **purple + yellow** -> rocket silo, rocket parts (LDS, rocket fuel, processing units).
- After **rocket launch** -> base game: space science and infinite research (victory already shown).
  Space Age: platforms and the first planet (space-age.md).
- Typical stall points to call out: no oil found (scouting), power brownout when labs and assemblers
  grow faster than boilers, iron starvation (the most common), and raids on undefended outposts.

## Sources

- docs/PLAN.md (human pacing)
- Factorio Wiki, "Technologies": https://wiki.factorio.com/Technologies (2.0 trigger technologies)
- Factorio Wiki, "Research": https://wiki.factorio.com/Research
- Factorio Wiki, "Rocket silo": https://wiki.factorio.com/Rocket_silo (parts, silo recipe, 2.0.7 payload rule)
- Factorio Wiki, "Achievements": https://wiki.factorio.com/Achievements (There is no spoon, No time for chitchat)
- Steam discussion on speedrun times: https://steamcommunity.com/app/427520/discussions/0/591757421998769170
- Factorio Forums, "Version 2.0.45" thread (DS record mentions): https://forums.factorio.com/viewtopic.php?t=128162&start=40
- speedrun.com Factorio guides (categories): https://www.speedrun.com/factorio/guides
