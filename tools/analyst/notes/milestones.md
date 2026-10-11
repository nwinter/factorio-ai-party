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
     (In shake1 a harness bug stopped the lab-craft trigger firing; the operator unlocked it at 15m14s.)
2. **Steam power (~5 to 15 min).** Offshore pump -> boiler -> steam engines, small electric poles. Boilers
   burn coal (or wood). From here power is the backbone: electric drills, assemblers, labs, inserters.
3. **Red science automated (~10 to 20 min).** Labs fed with automation science packs (copper plate + gear)
   from assemblers. First pack techs (2.0 names, as seen in shake1): Automation (assembler 1), Electric
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

## Our AI runs (seed 20261010, base 2.0.77)

Single agents, peaceful (docs/PLAN.md, agent-logged game times):

| Milestone | Astra realtime | Astra turns | Fable 5.1 realtime | Fable 5.1 turns |
|---|---|---|---|---|
| Burner mining + smelting | 7:49 | 3:52 | 8:25 | 5:50 |
| Steam power | 10:56 | 6:37 | 17:15 | 7:00 |
| Assembler red science into labs | 17:02 | 10:48 | 20:08 | ~13:00 |
| Automation/logistics + electric mining | 23:23 | 16:16 | partial | 17:40 |
| Green science automated | 30:12 | 20:29 | hand-fed | ~28:30 |
| Oil | none found | petroleum 55:45 | none | none |

- Round three (turn mode, 3 h): Astra reached blue science (14 packs) at game 1h20 despite a 16-minute
  harness crash; Fable reached 12 techs, building toward oil.
- The two-agent co-op test (coop1; on air say "the two-agent co-op test", never "coop1" or "the co-op": GPT-6
  Astra and Claude Opus 5.5 together, base game, real time, peaceful, so no biters, 2 h): 25 techs including robotics; blue science consumed
  by 1h34; 364 blue, 1,731 green, 1,867 red packs; 32k iron plates. Roughly competent-human pace.
- shake1 (nine agents, normal biters, real time, ~59 min; docs/studies/shake1.md): 14 techs; burner
  mining ~4m25; steam 12m42; red from assemblers ~18m17; green packs from assemblers 23m47; fully automated
  green chain only at 51m52; steel by ~26m; gun turret ~29m (after the first raid); oil gathering 61-67%
  at the deadline, so no crude, plastics or blue. Green peaked at 31/min, then a raid on the undefended
  west coal field (~50-53m) cut iron from ~400/min to ~0. Final: 18 labs, "2/18 labs working".
- Mira's run (GPT-6 Astra alone, standard game with enemies): rocket at ~44 h game time
  (4 d 11 h wall clock). A first-time-human-like result; slow by experienced standards.
- Lesson so far: more agents did not mean faster tech. Nine agents were slower than two (14 techs/h vs
  25 in 2 h) because of duplicated work, hand logistics and raids; the two had a peaceful map, so say so when
  using this (the solo and co-op tests are not pace benchmarks for the team runs).

## What comes next (after X, usually Y, because Z)

- After **burner mining** -> steam power: everything after needs electricity; hand-fuelling does not scale.
- After **steam power** -> craft a lab (2.0 trigger) and automate red science: research is the clock.
- After **red automated** -> Automation, Logistics, Gun turret, then green science; green unlocks most techs.
  With biters on, gun turrets come before pollution reaches nests (in shake1 nests were reached at ~16 min).
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

- docs/PLAN.md (milestone table, round three, co-op 1, Mira's run)
- docs/studies/shake1.md (nine-agent run)
- Factorio Wiki, "Technologies": https://wiki.factorio.com/Technologies (2.0 trigger technologies)
- Factorio Wiki, "Research": https://wiki.factorio.com/Research
- Factorio Wiki, "Rocket silo": https://wiki.factorio.com/Rocket_silo (parts, silo recipe, 2.0.7 payload rule)
- Factorio Wiki, "Achievements": https://wiki.factorio.com/Achievements (There is no spoon, No time for chitchat)
- Steam discussion on speedrun times: https://steamcommunity.com/app/427520/discussions/0/591757421998769170
- Factorio Forums, "Version 2.0.45" thread (DS record mentions): https://forums.factorio.com/viewtopic.php?t=128162&start=40
- speedrun.com Factorio guides (categories): https://www.speedrun.com/factorio/guides
