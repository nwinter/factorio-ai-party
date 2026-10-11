# Analyst: game knowledge and talking points for the hosts (eng/analyst)

The hosts write each line with a fast small model (Gemma 4 26B, about 1 s) from a small facts snapshot, so they know
little Factorio. The analyst is the slow expert behind them: every 60-120 s a strong model with read-only tools
studies the game and writes talking points, storylines, a judgement, what comes next, segment suggestions and
corrections, each with the facts behind its names and numbers. It also answers viewer questions on demand.

```
 game world (RCON, read-only)      run history          knowledge base (base 2.0.77 dump + notes)
        │ tools/analyst/game.py       history.py              kb.py, notes/*.md
        └──────────────┬──────────────────┴─────────────────────────┘
                 digest (2 s) + MCP tools (tools/analyst/mcp_server.py, read-only by construction)
                       │
          claude -p --model sonnet (subscription route), every 90 s ──► POST /analyst ─► serve.py snapshot "analyst"
          POST :8789/ask {question} (about 6 s) ◄── casters' viewer beats                    │
                                                                       caster.py (eng/audio) picks points
                                                                       director (eng/stream2) gets segment requests
```

## Run it

```sh
python3 tools/stream/analyst.py --world n --bot astra --feed http://127.0.0.1:8788 --run-dir runs/RUN --ask-port 8789
python3 tools/stream/analyst.py --replay runs/shake2 --at 45 --once --dry-run       # offline, past run at minute 45
python3 tools/stream/analyst.py --replay runs/shake1 --at 40 --at-step 6 --cycles 3   # walk a past run
python3 tools/stream/analyst.py --world n --digest-only                               # what the model is given
python3 tools/stream/analyst.py --model opus --every 120 ...                          # slower, catches more
python3 tools/analyst/test_analyst.py                                                 # offline tests
```

`tools/start-team.sh` starts it with the casters (`POG_ANALYST=0` skips it, `POG_ANALYST_MODEL=opus` switches model),
reading as the first bot with peek, posting to the service on 8788 and answering questions on 8789.

Run `tools/stream/analyst.py` as a bare command (no `cd ... &&`, no pipe): `.claude/settings.local.json` exempts
exactly `python3 tools/stream/analyst.py *` from the sandbox, which `claude -p` needs to reach its login and
api.anthropic.com. Inside the sandbox every model call fails with `network-outbound api.anthropic.com denied`.

## Files

| file | what |
|---|---|
| `tools/analyst/dump_prototypes.py` | dumps recipes, technologies, items, fluids, entities, planets/routes/qualities and map settings over RCON with read-only Lua (paged, every field in pcall) |
| `tools/analyst/kb/base-2.0.77/*.json` | the dump from world `live` (217 recipes, 196 technologies, 251 items, 139 entities, 19 fluids), 2026-10-11 |
| `tools/analyst/kb.py` | lookups: search (with names like "green science"), recipe, tech (cost, trigger, prerequisites, unlocks, leads to), path to a goal (minus what is researched), ratio (machines and drills for N/min), output (what N machines make), research time with N labs, compare production with a target, entity stats, planets |
| `tools/analyst/notes/*.md` | curated notes with sources: milestones and pacing, good vs poor play, biters and pollution, Space Age, glossary and misconceptions |
| `tools/analyst/game.py` | read-only game reads (below) and a replay source from a run's `scores.jsonl` |
| `tools/analyst/history.py` | past runs as benchmarks: every run at minute M, when each run finished a technology, milestones, study documents (also from other branches) |
| `tools/analyst/mcp_server.py` | stdio MCP server exposing all of the above as 24 read-only tools |
| `tools/stream/analyst.py` | the loop: digest, `claude -p`, fact check, POST, segment requests, `/ask` server, `--eval` |
| `tools/stream/analyst_board.py` | the store inside serve.py, plus `pick_point` / `point_facts` for the casters |
| `tools/analyst/evaluate.py`, `eval/questions.json`, `eval/results-*.json` | the 30-question check |

## Read-only, by construction

- The model runs as `claude -p --tools Read,Grep,Glob --strict-mcp-config --mcp-config <analyst server>
  --permission-mode dontAsk`: no Bash, no Edit/Write, no other MCP servers. Its only game access is the MCP server.
- Game reads in `game.py`: harness `dispatch` limited to read actions (`status`, `chat`, `power`, `describe`,
  `board`, `board_events`, `profiles`, `labs`), always with `"peek": true` so the reading identity's chat, board and
  team hints stay unread for the agent; and plain Lua that only reads statistics (production and kill statistics over
  1 min / 10 min / 1 h, entity counts, machine status by recipe, research and saved progress, evolution, pollution),
  the same privilege as `tools/pog.py score` and the stream service. Nothing calls a gameplay action, writes `storage`
  or changes a setting.
- During development only world `live` was read (it is an empty director world tonight); a, b, c and n were not
  touched. The 2.0.77 dump came from `live`.

## What the analyst writes (for eng/audio)

`POST /analyst` stores a cycle; every snapshot then carries `analyst` (null until the first cycle):

```json
{"headline": "At 54 minutes the team makes 33.8 science packs a minute ...",
 "judgement": {"pace": "on pace", "text": "...", "facts": {...}},
 "talking_points": [{"id": "tp12", "kind": "comparison", "topic": "spm-vs-shake2", "priority": 3,
     "text": "The nine-agent shake2 team had 21.8 packs a minute at this point. The best solo run had 41.3.",
     "facts": {"shake2_spm": 21.8, "best_solo_spm": 41.3, "minute": 54}, "agents": [], "game_minute": 54, "expires": 1760169000}],
 "storylines": [{"id": "west-under-attack", "title": "...", "status": "developing", "text": "...", "facts": {}}],
 "next": {"milestone": "oil processing", "text": "...", "facts": {...}},
 "segments": [{"type": "research", "params": {}, "reason": "...", "urgency": 2}],
 "corrections": ["The belts, furnaces and poles listed as lost in the west are ours, destroyed by biters."],
 "game_minute": 54, "age_s": 12, "meta": {"seconds": 14.3, "turns": 1, "cost_usd": 0.05, "model": "sonnet"}}
```

- `kind` is one of stat, comparison, explainer, prediction, judgement, storyline, trivia, correction. Up to 10 fresh
  unused points, best first (priority, then newest). A new point with the same `topic` replaces the old one; points
  expire after `ttl_s` (120-900 s).
- Every number and agent name in a point's `text` is in its `facts` (the analyst drops points that fail, with the
  same tolerance as the caster's check), so a host line built from `{"point": text, **facts}` passes
  `check_line`. In the check below the hosts' writer, given the analyst's answer as a fact under the caster's own
  RULES, was right 26/30 (vs 9/30 alone).
- Checked against eng/audio's `check_line` (eng/audio 22f76ae): 28 of the 30 relay lines pass with facts
  `{viewer_question, analyst_answer, game_time, team_size}`. The two rejections are right: one line invented
  "ninety minutes", one spoke as "we". Your rule that past-run comparisons need a `"pace"` fact is met by
  `point_facts` (adds `pace` for comparisons or any text naming a run) and by `/ask` replies.
- `POST /analyst/used {"id": "tp12"}` marks a point said; it is not offered again. `GET /analyst.json` has everything.

Suggested caster changes (your file, so not done here; `tools/stream/analyst_board.py` has the helpers):

1. Filler beats: in `facts_for` for `lull`, attach the best point for the angle and say it in the host's own words:
   `pace` <- comparison/judgement, `explain` <- explainer/prediction, `production` <- stat, `research` <- prediction.
   `p = pick_point(s.get("analyst"), self.used_points, kinds=...)`, `f["analyst"] = point_facts(p)`, angle text
   "the analyst's point; say it in your own words, keep its numbers". After the line, POST `/analyst/used`.
   A fresh priority-3 point could also become its own beat (priority 2-3), so the best insight airs within a minute.
2. Corrections: add `analyst.corrections` (at most 6 short rules) to the writer's system prompt for the next lines.
   They target what is on screen now ("the red alerts are our walls being hit").
3. Viewer questions: done on eng/analyst in round 4, without a caster-side `/ask` call; see "Viewer questions on
   air" below. (`/ask` on :8789 stays for manual use.)
4. `judgement` and `next` are good material for `open`/recap beats; `headline` for the first line after a cut.

Round 4 split with eng/audio (pog-audio-13 proposed it: it takes items 1, 2 and 4, touching `facts_for`'s lull
branch, `LLMWriter.exchange`, `Caster.filler` and `speak_lines`). Item 3 is done the other way round from that
proposal: no `Caster.ask_analyst` hook is needed, so please leave it out. A synchronous `/ask` takes 3 to 5 s inside
an exchange and has no rate limit. eng/analyst's caster.py lines are listed in the next section. For your new
`check_line` name rule: answers carry proper nouns (Nauvis, Vulcanus, Space Age, Factorio, agent and run names).
They are always in `facts.analyst_answer` / `facts.viewer_question`, and the viewer's name is in
`facts.viewer_message.from`, so "capitalised words that appear in the facts are fine" covers them. Corrections and
points are now written as true statements ("research progress is always kept"), never as a negated mistake. Please
pass them on verbatim.

## Viewer questions on air (round 4)

```
site / YouTube chat -> viewers.py lane (snapshot `viewers`) -> analyst.py viewer_loop (every 3 s)
  -> picks the freshest question -> claude -p with the read-only tools (3-5 s)
  -> POST /analyst/answer -> snapshot `analyst.answers[]` -> caster.py viewer beat (Rook: name + question, Vale: answer)
```

- On with `--viewer-questions` (start-team passes it; `POG_VIEWER_QUESTIONS=0` turns it off). Relay into the
  game is untouched (still off).
- Choice (`analyst_board.QuestionPicker`): a question is a lane message with a `?` or a leading question word and at
  least three words. Orders to the agents (`order`) are never taken. The newest question wins, it must be at most
  60 s old when picked (`--ask-max-age`), and at most one answer goes out per 150 s (`--ask-every`). A skipped
  question (off-topic, unsafe, no answer, error) holds the next pick only 20 s. Unanswered questions just age out.
- Safety: the lane has already passed viewers.py (links, spam, injection patterns, rate limits; Clef when
  configured). Claude then answers only fair questions about Factorio, the run, the agents and models, AI on the
  stream or the stream itself. Anything rude, sexual, hateful, violent, political or medical gets `{"skip": ...}`,
  as do questions about real people, requests for secrets or prompts, and orders or "read this out". The question
  is quoted as data. The hosts get a neutral restatement of the question (at most 12 words), never the raw chat
  text. Answers over 50 words, with coordinates, or more than 105 s after the question was asked are dropped
  (`answer_problem`).
- The answer prompt is the 30/30 viewer-question prompt (evaluate.ANSWER_SYSTEM) cut to two sentences. It names
  Space Age on Space Age runs, adds the facts hosts get wrong, and asks for true statements rather than negated
  mistakes.
- Snapshot: `analyst.answers` = `[{id, msg_id, viewer, question, answer, facts: {viewer_question, analyst_answer,
  pace?}, seconds, asked_t, t}]`, kept 120 s. `analyst.viewer_questions = {"on": true, "every_s": 150}` comes from
  each cycle.
- caster.py (eng/analyst's only lines there, covered by caster_selftest.py "viewer questions"):
  1. `Differ.diff`: while `questions_on(analyst)` is true (the latest cycle says on, age under 400 s), plain viewer
     questions are not turned into beats. The writer alone answered 9/30 viewer questions right. Comments still
     are. Each new `analyst.answers` entry becomes `{"kind": "viewer", viewer, text: question, answer,
     answer_facts, prio: 7}`.
  2. `facts_for`, viewer branch: `analyst_answer`, the answer facts, and `how_to_call_it` = "Rook says the
     viewer's name and question; Vale answers it from analyst_answer".
  3. `TemplateWriter`: a `viewer` template that fills only when there is an `analyst_answer`, so a writer outage
     still airs the answer.
  4. The one generic change: `e["prio"] = e.get("prio") or PRIORITY...` at the end of `diff`.
- Test (mock service on :8798, replayed chat, analyst on the shake2 replay, caster on templates because the
  sandbox cannot reach Workers AI):
  - The science-per-minute question was answered in 4.8 s and voiced 5 s later as "rustyminer asks: How many
    science packs per minute is the team making right now? About 24.5 science packs a minute ...".
  - The research question was answered in 3.7 s: "No, progress is kept. ...".
  - The crash-site question was answered in 3.6 s: the wreck dates from before the game.
  - "who should I vote for in the election?" was skipped in 2.8 s ("political question").
  - A Space Age question asked on a base-game run got base figures (100 parts). The base prompt now sends Space Age
    questions to the Space Age notes. On Space Age runs the knowledge base itself is Space Age (50 parts).

## Segments (for eng/stream2)

With `--segments` (off by default; on in no script yet) the analyst requests the highest-urgency suggestion of
urgency 2 or more, by `"by": "analyst"`, falling through types the service lists as unavailable, at most one per
cycle; the director's spacing and attack rules still decide. Spotlight takes the agent's display name and is mapped
to the id from `/state.json`. Checked against eng/stream2's mock (commit 4320f73): spotlight on Astra went live
(`by: analyst`), a second request got `busy`, production/research came back `unavailable` (the mock has no production).
Ideas for you: an "analyst says" lower third from `analyst.headline` or a priority-3 point (text and numbers come with
facts); a production segment variant that shows `kb_compare` output (what is short for a target rate).

Merge note: `tools/stream/serve.py` conflicts with eng/stream2 on two lines, both branches adding a parameter to
`make_handler` and to its call. Resolution: `def make_handler(hub, decisions, audio=None, segments=None,
replays=None, analyst=None)` with both bodies' defaults, and `make_handler(hub, decisions, segments=segments,
replays=replays, analyst=analyst)`. eng/audio merges cleanly.

## The check: 30 viewer questions (2026-10-11)

`python3 tools/stream/analyst.py --eval`, results in `tools/analyst/eval/results-20261011-000817.json` (answers, gold,
regex grade and my grade). 25 knowledge questions (recipes, ratios, technologies and trigger techs, machine stats,
biters, Space Age, misconceptions, alert reading) with gold from the dump and notes, and 5 about the current game,
played from the shake2 score log at minute 50 (snapshot 0h48m, shake2 itself left out of the history).

| | correct (regex) | correct (my reading) | median latency | max |
|---|---|---|---|---|
| Analyst: Sonnet via `claude -p`, tools | 30/30 | 30/30 | 5.6 s | 8.4 s |
| Hosts' writer alone: Gemma 4 26B, colour persona, hosts' facts | 9/30 | 9/30 | 1.4 s | 7.1 s |
| Relay: Gemma given the analyst's answer, caster RULES | 22/30 | 26/30 | 1.0 s | 1.7 s |

- The writer alone invented numbers on almost every exact question: 42 assemblers for 60 green per minute (8),
  gun turret range 35 tiles (18), 32 s per iron plate (3.2), 15 furnaces for 120 plates (7), 12 assemblers for 60 red
  (10), "it depends" on steam engine power, and called the Shattered Planet "a modded setting". It got progress
  being kept, two engines per boiler, belt speed, the four planets, copper as the bottleneck and the current research.
- Analyst slips: Q2 says "about 4 more" feeder machines while listing 5 (the main figure, 8, is right). Cost
  $0.60 API-equivalent for the 30 (subscription route, so quota rather than money).
- Second analyst pass (`results-20261011-002414.json`): 30/30 by regex, 29/30 by my reading, median 6.4 s, max 8.9 s.
  Q26 stated a false figure in passing ("red and green both run at 24 a minute"; 24.5 is the total), on a question it
  otherwise answered right. Minor slips: Q2 has one assembler "shared" by two recipes, Q16 says boiler pollution does
  not depend on fuel. The errors were side remarks beyond the question, so the answer prompt now asks for the answer
  plus at most one supporting figure read from a tool this turn. Third pass with that prompt
  (`results-20261011-002528.json`): 30/30 by regex and by my reading, median 6.1 s, max 9.2 s, shorter answers.
  Over the three passes: 89/90 by my reading.
- Relay misses: dropped the key fact (Q2 said 13 machines in all, Q17 dropped the 50-pack cost, Q22 dropped
  promethium) or rounded it (Q18, 3.2 s to "about three"). A caster that keeps the analyst's numbers verbatim would
  close most of that.
- Regex grades miss spelled-out numbers ("nine hundred kilowatts"); my reading is in `human_correct` in the file.

## Cycles, latency, model choice

- Cycle: digest about 2 s (one RCON round trip per read), then `claude -p`. Sonnet: 14-18 s, 1-2 turns, $0.05-0.13
  API-equivalent per cycle (about $3/hour at 90 s). Opus: 62 s, 7 turns, $0.36 per cycle; it read deeper, for example
  it caught that Astra's chat claim of 36 green packs a minute from 4 assembler 2s was wrong (30) and turned it into
  a correction. Default Sonnet at 90 s; Opus fits a 120 s cadence when quota allows.
- Why `claude -p` on the subscription: strongest models available on a flat route, MCP support for a read-only tool
  boundary, and `--output-format json` gives cost and turns per cycle. Workers AI models were the alternative
  (cheaper, faster) but the hosts' own model scored 9/30 without tools.
- Arithmetic: the first cycles had the model compute "4 green assemblers make 36 a minute" in its head. Now the
  digest carries exact per-machine rates for the science packs and key intermediates (and, on live worlds, each
  machine group's full-time capacity next to its actual output), and the prompt says to use `kb_output`,
  `kb_ratio`, `kb_research_time` and `kb_path` for any computed figure. The fact check only proves numbers are in the
  point's facts, not that the facts are right.

## Space Age

- research/spaceage plans world `sa` (game 34210, RCON 27030); it does not exist yet (no `~/.config/pog/rcon-sa.pw`).
  When it runs: `python3 tools/analyst/dump_prototypes.py --world sa --port 27030 --out tools/analyst/kb/space-age-2.0.77`,
  then `POG_KB=space-age-2.0.77` for the analyst. The dumper already reads planets, space connections, surface
  properties and qualities, trigger types beyond the base ones, and Space Age entity types; base worlds dump cleanly.
- `notes/space-age.md` covers planets, platforms, spoilage, quality, the edge and the Shattered Planet from the wiki;
  marked uncertain: the edge technology's name and default-settings speedrun times.
- `game.py` sums production, kills, losses, buildings and machine status over every surface by default
  (`--surface all`; planets and platforms) and lists the surfaces with our buildings; `--surface nauvis` reads one.
  Evolution and pollution are Nauvis's. Platform details (speed, location, hub stock) are not read yet; research/spaceage
  added a harness `platforms` read that could join `READ_ACTIONS` once it is in the runtime.

## What's left

- Production rates use `get_flow_count{count=true}` without a sample index, which the 2.0 API documents as the
  whole 1-minute / 10-minute / 1-hour window. Only checked on an empty world; compare one cycle's SPM with the overlay
  headline on the first live run.
- Not yet run during a live team run: the live reads were exercised on world `live` (empty) and the cycles on the
  shake1/shake2 score logs, which have production and research but no machine status, power or alerts.
- The caster does not consume the points yet (eng/audio; suggested changes above). The overlay shows nothing of the
  analyst (eng/stream2's call).
- Replay sources come from 2-minute score snapshots, so their "last 10 minutes" rates are interpolated and their
  science is "produced", not consumed.
- `history.py` labels the solo runs from PLAN.md's tables (world a = GPT-6 Astra, b = Fable 5.1); check if that
  mapping is wrong for any run.
- The notes' human pacing figures (SPM by hour, speedrun times) are estimates the notes mark as unverified.
