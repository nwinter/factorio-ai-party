# Past runs (only with analyst.py --past-runs)

The team's earlier runs on this seed, for pace comparisons when the stream wants them. Off by default: the public
run is presented as a first attempt, and the notes tool does not serve this file then.

## AI runs (seed 20261010, base 2.0.77)

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
  west coal field (~50-53m) cut iron from ~400/min to ~0. Final: 18 labs, "2/18 labs working". About 10
  deaths, mostly agents walking into biter groups; 8 of 12 furnaces idle when an ore belt broke; four
  separate green lines, one fully automated. Pollution reached nests at ~16 min, the first raid hit spawn
  at ~28 min. A harness bug stopped the lab-craft trigger firing; the operator unlocked it at 15m14s.
- Mira's run (GPT-6 Astra alone, standard game with enemies): rocket at ~44 h game time
  (4 d 11 h wall clock). A first-time-human-like result; slow by experienced standards.
- Lesson so far: more agents did not mean faster tech. Nine agents were slower than two (14 techs/h vs
  25 in 2 h) because of duplicated work, hand logistics and raids; the two had a peaceful map, so say so when
  using this (the solo and co-op tests are not pace benchmarks for the team runs).

## For scale

shake1 green peaked at 31/min (52-54 min) then collapsed; the two-agent co-op test (peaceful map; on air never
"coop1") averaged about 15 red and 14 green per minute over 2 h (1,867 and 1,731 packs) and reached blue by 1h34.

## Space Age pacing

shake1 and shake2 (nine agents, ~1 h): about 14 techs, no oil processing; round three (turn mode) reached blue
science at 1h20. A rocket in a 2 h run would be far beyond any run so far.

## Sources

docs/PLAN.md (milestone table, round three, co-op 1, Mira's run), docs/studies/shake1.md and shake2.md.
