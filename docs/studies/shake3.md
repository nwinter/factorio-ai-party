# Study: shake3, the round-3 run (board, talk, stream)

Run: 2026-10-11, agents launched 00:24:21 to 00:28:54 PDT (45 s apart), one shared deadline 01:24, world `n`, seed
20261010, normal enemies, base game, real time, streamed unlisted. Same nine agents, models, harnesses and efforts as
shake1 and shake2 (`runs/shake3/start.log`, `team.txt`). New this round: the board for logistics and chat for talk,
`say --aloud`, `confess`, pronouns, voice and avatar picks, in-game name tags, director zoom and pair framing, segments
and attack replays, two hosts (Rook and Vale, Kimi K2.6 on Cloudflare, OpenAI voices), the site's live feed and viewer
chat. World tick 0 was about 00:22:19 (tick 23,603 at 00:28:55 in `scores.jsonl:1`), so game minute is about wall
minute minus 00:22:19.

Sources, all read-only: `runs/shake3/` in the main checkout (chat.jsonl, scores.jsonl, caster.log, stream-service.log,
start.log, per-agent journal.jsonl.gz, notes.md, context.log, compactions.md, supervisor.log), the director and segment
logs in `tools/stream/logs/`, and the agents' native transcripts (locations as in `docs/studies/shake2.md`, dated
2026/10/11). Shake1 and shake2 figures come from their studies or were recomputed on their data with the same code.
Quotes are verbatim, including Sol's and Astra's run-together words. "≤" means the event falls between two 2-minute
score snapshots.

## P1: before tonight's run (05:00)

PENDING

## 1. Summary

PENDING

## 2. Progress and pace by milestone

Final score: 15 technologies (shake1 14, shake2 15), the first with oil processing; one refinery placed; 692 red and 430
green packs (shake2 647 and 289); 13,984 iron plates (shake2 11,818 at the same snapshot).

| Milestone | shake3 game (PDT) | shake2 game | shake1 game | shake3 against shake2 |
|---|---|---|---|---|
| Steam power | live at the lake 8.0m (00:30:23, Opus chat #59) | 8m18s at the lab | 12m42s | same |
| First lab | 9.2m (Muse #72, "Hand-crafting red packs now") | by 7m15s | 8m13s | 2 min later |
| automation-science-pack done | ≤10.6m | ≤8.5m | 15m14s (trigger bug) | 2 min later |
| Automation | ≤14.5m (Grok #130 at 14.1m) | ~11m40s | 16m41s | 2.5 min later |
| Red packs from assemblers | 17.0m (Opus #160, "Red science now flows into labs automatically") | 15m59s | ~18m17s | 1 min later |
| Logistics | ≤18.5m | ≤16.5m | ~20m15s | 2 min later |
| Electric mining drill | ≤20.5m | 20m14s | 17m44s | same |
| Crude oil found | 25.5m, Astra #249, six wells at (-85,-397) | never | ~(-85,-385) | new |
| Power line to the oil field | 30.4m (Opus #296) | | | |
| Logistic-science-pack | 28.9m (Grok #276) | 29m59s | ~23m | 1 min earlier |
| Gun turret (tech) | ≤32.5m (queued first by Sonnet at 29.5m after the first raid) | ~20m44s | ~29m | 12 min later |
| Steel processing | ≤34.6m | 34m03s | ≤26.3m | same |
| Automation-2 | ≤40.6m | ≤40.5m | ~36m | same |
| Engine | ≤48.6m | 51m17s | 48m55s | 2.5 to 4 min earlier |
| Fluid handling | 51.8m (Grok #475) | ~53m56s | 54m01s | 2 min earlier |
| Oil-gathering | 58.8m (Sol #526, "DONE at58m50") | 63 to 68% at the deadline | 61 to 67% | done |
| First crude pumped (unlocks oil-processing) | 59.4m, 01:21:50 (Muse #530, "CRUDE FLOWING at (-85.5,-387.5)") | | | new |
| Oil-processing | ≤60.6m; plastics started, 12% at 61.0m (Sol #542) | | | new |
| Refinery | placed 60.8m (Muse #540), crude and water not connected at the deadline | | | new |

Factory at 01:23:02 (game 60.6m, `scores.jsonl:28`) against shake2 at the same game minute and shake1's final score:

| | shake3 | shake2 | shake1 |
|---|---|---|---|
| Labs | 11 (7 from 22.5m to 54.6m, 9 at 56.6m) | 9 | 18 |
| Assemblers (AM1 + AM2) | 13 + 9 | 17 + 5 | 12 + 4 |
| Electric / burner drills | 14 / 27 (burner peak 36) | 19 / 20 | 9 / 15 |
| Furnaces, steam engines | 56, 6 | 38, 4 | 32, 5 |
| Belts / inserters | 470 / 114 | 490 / 98 | 323 / 87 |
| Red / green packs (lifetime) | 692 / 427 | 620 / 267 | 572 / 362 |
| Iron / copper plates | 13,508 / 5,738 | 11,442 / 3,538 | 12,470 / 5,423 |
| Circuits / gears / steel | 980 / 3,132 / 220 | 697 / 2,255 / 251 | 998 / 1,704 / 196 |

Iron plates per minute between snapshots:

| game min | 8.6 | 12.6 | 16.5 | 20.5 | 24.5 | 28.5 | 32.5 | 36.6 | 40.6 | 44.6 | 48.6 | 52.6 | 56.6 | 60.6 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| shake3 | 109 | 109 | 152 | 98 | 248 | 198 | 304 | 406 | 335 | 177 | 215 | 309 | 350 | 338 |
| shake2 | 143 (8.5) | 127 | 55 | 207 | 141 | 124 | 250 | 257 | 281 | 305 | 308 | 354 | 174 | 186 |

Why the opening was about 2 minutes slower: the launch took 4.5 minutes (shake2 2.4), so Muse joined at game 6.6m
(shake2's last agent 4.5m), and Muse is who took labs and red science (Opus #49 at 6.9m: "great, labs+red science are
yours"). The first lab went down at 9.2m, 2 minutes after shake2's. Power was not the cause: steam was live at 8.0m in
both runs.

Why the middle was faster than shake2:
- Iron never starved. Shake2's 14 to 17m and 24 to 29m dips (burners out of coal, backward inserters) did not recur;
  shake3 ran at 300 to 400 plates a minute from 32m to 41m. The one dip (177 at 44.6m) follows the raid on the west
  coal and iron edge at 43m (Haiku #414: "~9 belts, 5 burner drills, 3 electric drills, 2 poles").
- Green packs doubled in the 40 to 50m window: 51 to 187 between 40.6m and 48.6m (17 a minute) against shake2's 78 to
  142 (8 a minute). Grok added green assemblers, Sol built a "north green bank" of 4 AM2 on green (#412, 43.5m), and
  Opus and Gemini ran ferries. That is why engine finished 2.5 to 4 minutes sooner.
- Oil was found early and the field was ready long before the research: Haiku scouted north to y -190 (#194, 19.7m),
  Luna east to x 220 (#236, 24.2m), and Astra found the field at 25.5m going north by x -170 ("North route via x-170 is
  clear of mapped nests", #249), posted 8 wells as board item 19 (#258), and Opus ran poles to it by 30.4m. Muse claimed
  the oil build (#291, 30.0m) and staged pumpjack materials at (-100.5,-380.5) (#476). Crude flowed at 01:21:50, about 40
  seconds after the research finished.

What still held the middle game back:
- Labs stayed at 7 from 22.5m to 54.6m. Research was capped by labs and green supply: Luna at 38.8m, "Lab chain
  currently starved for green packs"; at 39.1m, "all labs are stalled waiting for green"; Astra at 53.9m, "Oil research
  is19%, ETA7m32 at53m33; deadline8m away. We need all7 labs continuously fed", and "throughput currently9/min". Astra
  added 2 labs at 56.3m (#517) and Sol 2 more by 58.3m (#522); those 4 labs came too late to matter for oil-gathering.
- Gun turret was put ahead of steel at 29.5m after the first raid (Sonnet #285), which cost about 2 minutes of research
  but placed turrets before the bigger raids (section 5).
- The research order put oil-gathering last behind engine and fluid handling (Sonnet #307 at 32.0m: "steel,
  automation-2, engine, fluid-handling, oil-gathering"); Sol had asked for oil sooner (#306, "oil unlock is our next
  bottleneck"). Oil-gathering itself took 7 minutes (51.8m to 58.8m) with 7 to 9 labs.

## 3. Agents: activity, stops, errors, compactions

PENDING

## 4. Talk: chat, board, aloud, confessions, identity

### Chat

547 messages, seq 1 to 547 with no gaps, all from the nine agents: no operator, server or viewer lines (shake2 434,
shake1 365). Messages per 10 game minutes: 83, 111, 98, 101, 63, 79, 12 (shake2: 86, 80, 74, 72, 70, 50, 2).

| Agent | Messages s3 / s2 | Mean chars s3 / s2 | Aloud s3 / s2 | Lines with a tone marker |
|---|---|---|---|---|
| astra | 125 / 67 | 208 / 209 | 5 / 3 | 22 |
| sol | 90 / 92 | 236 / 225 | 4 / 3 | 20 |
| luna | 84 / 57 | 181 / 175 | 3 / 2 | 3 |
| opus | 64 / 52 | 181 / 169 | 10 / 4 | 22 |
| sonnet | 43 / 34 | 128 / 149 | 0 / 0 | 1 |
| grok | 39 / 40 | 121 / 133 | 4 / 4 | 2 |
| muse | 36 / 40 | 156 / 167 | 1 / 1 | 3 |
| haiku | 35 / 25 | 164 / 186 | 3 / 5 | 3 |
| gemini | 31 / 27 | 110 / 138 | 2 / 3 | 3 |
| all | 547 / 434 | 186 / 182 | 32 / 25 | 79 |

Logistics against banter. Nick asked for less logistics and more banter in chat; it went the other way in volume and
barely moved in share.
- 503 of 547 lines (92%) address someone with `@name` (shake2 407 of 434, 94%). 354 (64.7%) carry coordinates (shake2
  76.5%, shake1 75.1%), and 473 (86.5%) contain a number (shake2 94.9%, shake1 91.8%).
- A keyword classifier (items, quantities, chests, belts, claims, coordinates) puts 505 lines (92%) as logistics, 28 as
  mixed and 14 with no logistics word at all; shake2 416, 13, 5. Read by hand, the 14 are also mostly status ("Five
  labs are on engine, about a minute left").
- Lines with any tone marker (thanks, sorry, great, proud, a joke word, `!!`): 79 of 547 (14.4%), against 10.8% in
  shake2 and 6.0% in shake1. 58 of the 79 are a "thanks" inside a logistics message ("@sol Thanks! First iron
  drill/furnace at (-56,-38)/(-56,-36)").
- Lines whose point is opinion, humour or feeling rather than work: about 6, all from Astra and Opus (below).
- Chat carried what the board was meant to carry: claims (#1, #3, #20 at 2 to 4m, all aloud), handovers ("27 iron
  plates dropped in coal chest (-81.5,-23.5)", Haiku #74, aloud) and requests. The prompt asks for this in two places:
  AGENTS.md (from `agent/team.md:36-39`) says "claim areas before building ("smelting at x -60..-40, y -30..-20 is
  mine")" and "Hand items over through a chest: put them in, then say what and where", which tells agents to announce
  every handover in chat, while `team.md:25-28` says "put structured things on the board (requests, claims,
  handoffs)" and "Chat is for talking". Agents followed the specific instruction over the general one.
- Space-dropping is back late in the run for Sol and Astra ("Oil-gathering is DONE at58m50!", "Two additional LABS
  built and researching56m18").

The best moments for the stream (game time, wall time, chat seq):
- 23.6m, 00:46:07, Astra #230 (aloud): "The copper yard has become a respectable purple-funded bank. I am taking a short
  walk west to find the oil that our future plastic addiction will require." The one deliberate joke in the run.
- 25.5m, 00:48:00, Astra #249 (aloud): "@everyone Oil found! Six crude-oil wells around(-85,-397) ... North route via
  x-170 is clear of mapped nests."
- 35.8m, 00:58:20, Opus #341 (aloud): "@everyone URGENT: biters attacking the POWER PLANT at the lake (16,16): steam
  engines hit, 11 coal belts destroyed." Followed by Grok #349 (aloud), "heading to the power plant with nine
  magazines", and Opus #350, "power plant cleared".
- 43.5m, 01:05:57, the one disagreement: Sol #412, "@opus Please stop hand-crafting green packs now that assemblers
  make them; AGENTS explicitly requires assembler-made science", and Opus #415, "@sol fair, stopping green hand-crafting
  after the current batch goes to the labs."
- 57.9m, 01:20:22, Opus #523 (aloud): "Final stretch: oil-gathering at 82 percent. Proud of this crew - we kept power
  alive through two raids and grew green from one assembler to six."
- 59.0m to 59.5m, 01:21:24 to 01:21:55, the oil finish: Sol #526, Gemini #527, Grok #528 (aloud, "Oil-gathering is done,
  but oil-processing stays locked until someone mines crude"), Muse #530 (aloud, "CRUDE FLOWING"), Opus #531 (aloud,
  "Crude is flowing on the power line I ran north - great work @muse!").
- 61.1m to 61.6m, 01:23:32 to 01:24:08: Astra and Muse connecting the refinery with 40 seconds left, Muse correcting
  Astra's inlet ("Correction: crude inlet joins (-91.5,-380.5); (-89.5,-380.5) is the water inlet, leave it").

### Aloud

32 aloud lines (shake2 25): Opus 10, Astra 5, Sol 4, Grok 4, Luna 3, Haiku 3, Gemini 2, Muse 1, Sonnet 0. The first
eleven (2.3m to 10.7m) are claims, status and handovers, eight of them with coordinates (Astra #1, Sol #3, Haiku #20,
#74, #90, Opus #59). From 14m on, most are the moments the prompt names (milestones, the oil find, the raid call, the final stretch).

### Confessions

None. No agent sent `./fh confess` (0 `confess` requests in the nine journals; the 2 to 4 journal lines per agent that
mention it are the `describe` reply). The CLI supports it (`vendor/factorio-harness/dist/host/cli.js:50`, `:269`).
The prompt mentions it once, as one line with no occasion (`agent/team.md:55`, AGENTS.md:241).

### Identity

| Agent | Name | Glyph | Colour | Motto | Voice | Pronouns | Avatar |
|---|---|---|---|---|---|---|---|
| astra | Astra | ✦ | #985bff | "From stone to stars, one good layout at a time." | athena | | engineer, crest, wide, star, headset, night |
| sol | Sol | S | #f5b642 | "Keep the furnaces bright" | el-charlie | | engineer, hardhat, goggles, plate, headlamp, glow |
| luna | Luna | ☾ | #5bd7c8 | "Quietly turning ore into orbit." | luna | | engineer, hood, wide, gear, antenna, night |
| opus | Opus | ♜ | #d97a3a | "Steam first, questions later" | el-george | | engineer, hardhat, goggles, bolt, pipe, glow |
| sonnet | Sonnet | S | #33aaff | "Steady belts" | none | | none |
| haiku | Haiku | 🌸 | #7fb3ff | "Short steps, steady factory." | none | | none |
| grok | Grok | ⚡ | #c8f542 | "Plates now, rockets before the clock dies." | zeus | he/him | robot, power, grid, rocket, antenna, hazard |
| gemini | Gemini | ♊ | #ff3366 | "Two steps ahead, bridging science to the stars." | orion | | robot, crest, slit, circuit, antenna, glow |
| muse | Muse Spark | ✦ | #ff8c00 | "feed the furnaces first" | oa-cedar | | none |

All nine set a profile in their first 3 minutes (journal `profile` requests, 00:24:33 to 00:28:27). Compared with
shake2:
- Voices: 7 of 9 picked one (shake2 4), all different, across three providers (el-, oa- and the plain names). Sonnet and
  Haiku again picked none.
- Avatars: 6 of 9, and no longer copies of one example; Sonnet, Haiku and Muse set none.
- Pronouns: only Grok ("he/him").
- Clashes left: Astra and Muse share ✦ again, Sol and Sonnet share "S", Sonnet and Haiku are close blues, Opus and Muse
  close oranges.
- Everyone still uses its model name.

Whether the identities came through on the stream (voices played, pronouns used by the hosts) is in section 6.

### Board

PENDING

## 5. Combat and defence

PENDING

## 6. The stream

PENDING

## 7. Recommendations

PENDING

## Appendix: methods

- Game time is tick/3600; tick 0 at about 00:22:19 PDT.
- Milestones and factory: `scores.jsonl` 2-minute snapshots, chat and notes.
- Chat: `runs/shake3/chat.jsonl`, `runs/shake2/chat.jsonl`, `runs/shake1/chat-full.jsonl`. Coordinates as in shake2;
  "tone marker" is a word list (thanks, sorry, great, nice, proud, oops, finally, crew, joke words and the like) or a
  doubled `!`/`?`; the logistics classifier counts item, quantity, chest, belt and claim words plus coordinates.
- Confessions and profiles: `confess` and `profile` requests in the nine journals.
