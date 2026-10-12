# Stream audio: shoutcasters, voiced agent chat, game audio

Branch `eng/audio`. Two AI casters (Rook, play-by-play; Vale, colour) talk over the stream, agents' best chat lines
are spoken in per-agent voices, and the main director client's game sound sits underneath, ducked whenever anyone
talks. Everything is mixed by OBS through the overlay's browser source.

## Hosts by audience, and a public run as a first attempt (branch eng/audio2, 2026-10-12 morning)

**Model by audience.** The viewers bridge (`viewers.py`, inside serve.py) reads YouTube's "N watching now" for the
broadcast once a minute: `youtubei/v1/updated_metadata` with the video id (what the watch page polls for its
counter), or the watch page's ytInitialData once that fails. The snapshot has it as
`viewers_status.youtube.watching` (None when unknown) and `watching_t` (when it was read). caster.py's
`host_model` picks the main writer per line:

- `--model` (Opus) with 2+ watching, or with one viewer who arrived in the last 10 minutes (the count went from 0
  or unknown to 1);
- `--low-model` (start-team: `POG_CASTER_LOW_MODEL`, default `anthropic/claude-haiku-5.5`; empty: `--model` always)
  with 0 watching, or 1 for more than 10 minutes, or 1 after a 2;
- `--model` whenever the count is unknown or older than 3 minutes.

Urgent beats keep `--urgent-model`. Each switch is a caster.log line `[hosts] model or:... (watching N, read Ns
ago)` and a `host_model` row in the jsonl; every host line also names its model in the log. Check a broadcast by
hand: `python3 tools/stream/viewers.py --youtube VIDEO_ID --watching 3` (three readings a minute apart, both ways).
The parser's tests use `tools/stream/runs/yt-watching-sample.json`, written from the innertube reply shape, not
captured (youtube.com is closed to the engineer sandbox): replace it with a capture.

**A fresh run names no earlier run.** On a first shift the hosts, the analyst and the agents get nothing from the
team's earlier runs:

- caster.py: no pace baseline by default (`--baseline`/`--space-baseline` were shake1/shake4); the show notes and
  rules no longer mention earlier runs (the pace note comes with pace facts, only with a baseline). "Previously on"
  and the shift facts read only the run's own resumed-from chain.
- analyst.py: the earlier runs (digest section, `history_at/when/milestones/runs/study`, the past-run rules,
  `notes/past-runs.md`) only with `--past-runs` / `POG_ANALYST_PAST_RUNS=1`; the notes name no run.
- Agents: the PLAYBOOK's "Harness notes" and the Space Age flight note no longer mention earlier runs or a test
  world; Claude-style agents' settings deny other runs' folders.
- `tools/stream/test_fresh_run.py` sends every kind of beat and card of a fresh run through the writer and checks
  what the hosts, the analyst and its notes get for run ids from before it.

## Hosts, round 6 (HOSTS6.md, 2026-10-12 early)

Read from shake10 and shake11 (Opus main, Kimi urgent) before shake12 had data. The shake12 review (Sonnet urgent)
comes after 04:00.

- Shake11 to 00:41 (`copy_report --jsonl`):
  - 423 host lines: 6% templates, silence 62% of the time.
  - Opus writes in 6.6 s median (8.6 s p90), Kimi's urgent beats in 2.1 / 4.7 s. Two urgent Kimi timeouts.
  - $1.91 an hour: writer $1.52, TTS $0.38.
  - Cuts: "X, not Y" 11, a name not in the facts 8, a planet not reached 5 (wrongly, see below), metaphor 4.
  - Tells: no dash pivots, no "!" endings, 6.5% open on a number, 12.5 words a line.
- Repetition across a shift (item 2). "Here's the replay" opened 10 to 12 replays a shift, and "N labs are waiting on
  packs" came back 10 times in shake10. The repeat check only compared with the last few lines.
  - The caster now remembers each aired line's opening and its 3-4 word phrases for 30 minutes. Numbers and units
    are left out: "plates a minute" is a fact, not a framing.
  - Phrases aired twice reach the writer as `framings_used_lately`, with a rule to find a new way in.
  - A third line opening the same way within 20 minutes is cut ("style: opening used again this shift"). Replayed in
    order, that cut would take 3 of shake10's 727 lines and 14 of shake11's 392.
  - The phrase list does not count as facts for names.
- Research cards (item 3). Research beats work ("There it is. Electric accumulators, done. Defender's up next."), but
  shake11 ran 1 research card for 4 completions. The lull cards had used the caster's 3-minute request budget. A
  research completion now asks for its card past that budget; the director's own availability still applies.
- Other fixes (item 4).
  - Counts the hosts can stand on. Shake11 aired "That brings the shift total to one engineer lost" (00:38), then
    "That's two dead this shift" (00:40). Urgent beats and replays now carry `counts`: deaths and loss reports since
    the hosts came on, and attacks in the last 10 minutes.
  - Planets. A planet named in the beat's own facts (the research "Planet discovery Fulgora") or in a travel plan
    ("packing for Vulcanus") no longer counts as a claim to be there. Shake11 had cut 5 such lines.
  - Technology labels keep planet capitals ("Planet discovery Fulgora", not "fulgora").
### Shake12 review (02:58 to 04:05, Opus main, Sonnet urgent, rounds 4-6 live)

| | shake11 (to 00:41) | shake12 (to 04:05) |
|---|---|---|
| templates | 6% | 2% |
| silence | 62% | 54% |
| urgent writer: exchanges, latency median / p90 | Kimi: 78 in 110 min, 2.1 / 4.7 s | Sonnet: 83 in 69 min, 6.6 / 9.5 s |
| main writer latency | Opus 6.6 / 8.6 s | Opus 6.5 / 8.2 s |
| cost per hour, all (writer) | $1.91 ($1.52) | $2.78 ($2.29) |
| words a sentence; sentences of 3 words or fewer | 6.1; 21% | 7.4; 13% |

- "Previously on" works. Sonnet aired at 02:58:32:
  - Rook: "Welcome back. Last shift, the team finished seven techs and built more turrets and walls."
  - Vale: "Which they needed. Three engineers died, and small spitters wrecked a pile of belts and poles."
  - Rook: "Now Sol builds shared defense for the north oil corridor."

  "Built more turrets and walls" was not true. pog.py started counting turrets, walls and requester chests during
  shake11, so "135 more gun turret" was a first count. Growth now counts only buildings the first score counted, or
  pog.py's original list for older scores. Shake12's would read "12 more electric mining drills, 12 more assembling
  machine 2s, 10 more steam engines".
- Raids all hour.
  - An attack beat every 40 to 90 s, 69 of 83 urgent exchanges. Nearly each quoted the counts ("Seven attacks in ten
    minutes", "Eight...", "still zero deaths"), and "in ten minutes" was in 41 of 327 lines.
  - The counts' "since the hosts came on" aired as "since we came on air", cut 5 times for 'we'.
  - Fixes:
    - A plain attack within 2 minutes of the last attack, loss or death beat is dropped (`--attack-gap 120`);
      deaths and losses still speak.
    - Counts go only on death and loss beats, as `deaths_so_far`, `loss_reports_so_far` and `counted_since` (a
      clock time).
    - The framing memory reads numbers as N when they count events, so "attacks in N minutes" is a framing.
  - My estimate in the round-5 notes, about 27 urgent exchanges an hour, was too low for a raid-heavy shift:
    shake12 ran about 70. At that rate Sonnet costs about $0.58 an hour on urgent beats, about $0.16 on Kimi.
- Sonnet's urgent latency live (6.6 s median, 9.5 s p90) is three times the bench's (2.3 s), on the same prompt
  shape (facts median about 1,800 characters, no retries on urgent beats). The urgent writer now asks OpenRouter for
  the fastest provider (`provider: {sort: latency}`); this is untested live. If it stays slow, Kimi (2.1 / 4.7 s
  live) answers urgent beats faster.
- Repetition across the shift. Besides the counts, "turrets are doing their job" and "nobody has died" aired five
  times each, with the phrase list in the facts. A 4-word phrase aired three times in 30 minutes is now cut wherever
  it sits. Replayed in order, the opening and phrase cuts would take 26 of shake12's 329 lines (mostly the counts
  framing, which the source change removes), 45 of shake11's 983 and 3 of shake10's 727.
- Research cards. There were 2 research completions and no research card: the director was busy with replays. A
  research card it cannot take now is asked for again for 90 s, and the log says when it gives up.
- Replays come in bursts: three in 41 s at 04:04, often one pipe or one belt. The hosts now let a second replay
  within 60 s go by; the card still plays. Which losses get a replay is the director's call (`segments.py`).

## Hosts, round 5 (HOSTS5.md, 2026-10-11 night)

- "Previously on" (item 1).
  - `previous_shift()` reads the run that `resumed-from` names.
  - From its `scores.jsonl`, first row against last: the game minutes played, how many technologies were researched
    and the last four in the order they finished, the three buildings that grew most (belts and inserters left out),
    and the rockets launched.
  - From the caster jsonl logs its `caster.log` names: the deaths (distinct death beats), the loss reports, and the
    biggest loss, said as a person would.
  - The opener of a resumed shift carries it as `previously_on`, with a call to recap in the hosts' words, one thing a
    line, then the team's plan now. The opener gets three lines.
  - On shake11's real logs it reads: 239 game minutes, 10 technologies (last Flamethrower, Research speed 4,
    Military 3, Circuit network), 11 more steel furnaces, 7 more solar panels, 8 rockets, 6 deaths, 19 loss reports,
    the biggest "73 lost to medium biters".
- The team plan (item 2).
  - The snapshot's `board.plan` (goals and one line per agent, from `fh board plan`) reaches the hosts as
    `team_plan` on the opener, explain, pace and board beats.
  - A change to the plan (new goals, or an agent's line changing) is its own `plan` beat, priority 5, with what
    changed and a call to say what it means for the run.
  - An agent's plan line is its `working_on` when no board claim names a job, so "walking" reads "heading off for
    <plan line>".
  - Research news: research beats are priority 7 and never wait for quiet; research starts wait for 20 s of quiet.
- Fewer template fallbacks (item 3). In shake11 to 23:35, 15 of 181 host lines were templates. Two came after an
  urgent Kimi timeout (8 s); the rest came when every draft of a beat was cut. A non-urgent beat with nothing usable
  now stays quiet ("[writer] nothing usable for camera (...); staying quiet", counted as `skipped_quiet` in the
  `[cost]` stats). Urgent beats still get a template. Two of shake11's cuts were right time-left lines ("Shift ends
  in three and a half hours", "Still 199 minutes to handover"): "ends in N minutes" and "N minutes to handover" are
  now checked as time left, not cut as a shift end. Opus's own timeout is 36 s (3 x `--writer-timeout`), and it did
  not time out in shake11.
- Urgent model (item 4). Nick's bench on shake10's 20 urgent beats (`copy_bench --kinds attack,death,loss`):

  | writer | lines kept | latency median / p90 | words a line | opens on a number | per 1,000 exchanges |
  |---|---|---|---|---|---|
  | Kimi K2.6 | 36/44 | 3.1 / 5.9 s | 9.6 | 8/36 | $2.31 |
  | Haiku 5.5 | 36/44 (one beat wrote nothing) | 4.8 / 6.3 s | 13.2 | 3/36 | $0.72 |
  | Sonnet 5.5 | 40/44 | 2.3 / 6.6 s | 15.0 | 2/40 | $8.32 |

  The bench's "per stream hour" assumes 300 exchanges an hour. Urgent beats are far fewer: shake10 had 93 urgent
  exchanges in 203 minutes, about 27 an hour. At that rate urgent beats cost about $0.06 an hour on Kimi, $0.02 on
  Haiku and $0.23 on Sonnet, beside about $1.55 an hour for Opus on the other beats. The 11 cuts across the three
  writers were for 'we' (3), shift-end talk (2), absences (2), and one each for numbers, a metaphor, "X, not Y" and
  a number not in the facts. Urgent beats stay on Kimi tonight; Nick decides in the morning.
  `POG_CASTER_URGENT=or:anthropic/claude-sonnet-5.5` (or haiku) switches at a launch.

## Hosts, round 4 (HOSTS4.md, 2026-10-11 night)

### Opus 5.5 against Kimi (item 1)

`copy_report.py runs/<run>/caster.log --jsonl tools/stream/logs/caster-*.jsonl`. Shake10 ran Opus 5.5 on OpenRouter
from 18:47 to 22:09, with urgent beats on Kimi. Shake7 ran Kimi for everything, with the copy filters, from 13:00 to
17:00.

| | shake10 (Opus, urgent Kimi) | shake7 (Kimi) |
|---|---|---|
| host lines per hour | Opus 126, Kimi (urgent) 52, templates 13 | Kimi 476, templates 15 |
| template share | 7% | 3% |
| words a line | 12.2 (Opus 12.9) | 9.7 |
| words a sentence; sentences of 3 words or fewer | 6.2; 21% | 4.5; 35% |
| a voice on air / silence | 34% / 66% | 77% / 23% |
| write latency median / p90 | Opus 6.0 / 7.3 s; Kimi 2.0 / 4.3 s | 2.1 / 4.7 s |
| writer failures (timeouts) | 2 (2) | 7 (6) |
| cost per hour: writer, TTS, all | $1.55, $0.34, $1.89 | $0.53, $0.73, $1.26 |
| tells left | 0 dash pivots, 0 "!" endings, 1.7% three-part lists, 5.9% open on a number | 0, 0, about 4%, 14.8% |
| cuts | 48 (25 for style) | 255 (146 for style) |

Opus writes causes and plain talk ("Low power here means the boilers are short of fuel"), and the hosts are silent
two thirds of the time. LLM-isms left in its 453 lines:
- Cut off mid-word: 33 lines ("They scanned before leaving. Two ass"). The OpenRouter call allowed 400 tokens.
  - The budget is now `max(4 x, 1200)`.
  - When OpenRouter reports the length limit, the unfinished last line is dropped.
  - `check_line` cuts any line that does not end a sentence.
  - Replayed over shake10, that would have cut 32 lines.
- Verdict openers: 35 lines graded the last one ("Good call.", "Smart read.", "Good timing." 7 times). The notes now
  say to just say the next thing, and a second verdict opener within eight lines is cut.
- Lowercase names copied from the agents' tells ("Haiku just told astra"): 9 lines. Agents' names are capitalised
  before air; "haiku" after "as", "a" or "in" stays the poem.

### What the team has not built (item 2)

- The score (`tools/pog.py`) counts more buildings: roboports, requester and buffer chests, accumulators, gun, laser
  and flamethrower turrets, walls, beacons, pumpjacks, locomotives, nuclear reactors, centrifuges, fast and express
  belts. It also lists which buildings it counted (`entities_counted`), since zeros are left out of its counts.
- `live.py` passes the counts on.
- The model records when the stream saw each technology finish, and its snapshot carries `unused_unlocks`: up to four
  researched technologies with none of their building, oldest first. Each says when it was researched: "N minutes ago",
  or "before this stream" when it was done before the service started.
- Research beats and explain, production and pace beats give the hosts `not_built_yet`, with a note that it is
  commentary for viewers, at most once. Nothing goes to the agents.
- `check_line` lets "still no roboports" through only when `not_built_yet` backs it.
- A score without `entities_counted` (the old pog.py) gives no unused unlocks, so the hosts never call a building
  missing that was simply not counted.

### Agents answering viewers (item 3)

From shake11 the viewer relay reaches the agents. An agent's chat line that names a viewer who wrote in the last 10
minutes becomes a `viewer_reply` beat. It has priority 7, above a viewer question and below urgent beats, and plays
at the "viewer" rank. "@Name" counts always, and the bare name when it is longer than three letters. The facts carry
the viewer's question, the agent's answer and how to call it: Rook says who asked what, and Vale says what the agent
answered. Relayed "viewer NAME: ..." chat rows now give the viewer's name. Before this, only aloud chat reached the
hosts, so an answer said plainly would have been missed.

### Urgent beats on a fast Claude (item 4)

`--urgent-model or:<OpenRouter model>`, or `POG_CASTER_URGENT` in start-team, puts urgent beats on OpenRouter; the
default stays Kimi on Workers AI. `copy_bench --kinds attack,death,loss` replays only urgent beats (20 in shake10).
The bench, from a shell that may reach OpenRouter and Workers AI:

    L=~/code/player-of-games/tools/stream/logs
    python3 tools/stream/copy_bench.py $L/caster-20261011-184735.jsonl $L/caster-20261011-202016.jsonl \
        --kinds attack,death,loss --n 20 --timeout 8 \
        --writers cf=@cf/moonshotai/kimi-k2.6,or=anthropic/claude-haiku-5.5,or=anthropic/claude-sonnet-5.5 \
        --md /tmp/urgent-bench.md

Switch if Haiku or Sonnet keeps more lines than Kimi with a p90 under about 4 s (Kimi's is 4.3 s). It was not run
from this session.

## Hosts, round 3 (HOSTS3.md, 2026-10-11, for the 17:00 shift change)

The shake7 study (study/shake7, `docs/studies/shake7-early.md`) found the copy filter worked, but the plain style
turned into mockery of idle agents ("Classic Opus. Big chat energy."). About 108 of 803 lines said an agent was walking,
and 57 quoted a motto.

- The shift and planet fix (84b8749) and the numbers fix (7385467) are on eng/audio, which merges cleanly with main.
- Tone. The notes now say the agents are the stars and the hosts like them: curious about how they think, warm
  about what they try, a gentle tease at most. They also say what to talk about when nothing much is happening: the
  plan on the board, the factory, a number that changed, or a viewer's question. Never call a fact wrong.
- Facts.
  - An agent's `doing` is dropped when it is just travel ("walking", "moving").
  - Each agent now carries `working_on`, the job it holds on the board.
  - A lull's `busy_agents` lists only agents with a task or a job.
  - The planning status reads "working out the next step"; "between tasks" is gone.
  - Mottos appear only on the opener and the spotlight card.
- Cuts in `check_line`, all as style faults:
  - walking filler, when the facts don't mention walking;
  - mockery shapes: "classic Opus", "big chat energy", "still planning", "planning again", "Planning, they call it",
    "just waiting", "that motto aged fine";
  - motto filler, when the facts carry no motto;
  - calling a fact false ("that number is a lie").
- Quote marks come off a line only in pairs. Shake7 aired 13 lines with a lone quote mark.
- Cards. Each card on the overlay has a call (`CARD_CALLS`):
  - recap: tell the best story of the last few minutes;
  - production: what went up or down, and why it matters;
  - spotlight: introduce the agent as someone to root for;
  - research, overview and space have calls too.

  Any non-urgent beat that lands while a card is up carries the card (`on_screen_now`) and `card_on_screen`, which
  tells the hosts to talk about the card first.
- One voice at a time (item 5, Nick). `static/audio.js` now has one queue for hosts and agents.
  - A clip that matters more fades the current one out (`?fade=0.25` s) and plays next. Rank, high to low: urgent
    (attack, death, loss, space moment), an agent speaking aloud, an answer to a viewer, banter.
  - The rest of a Rook/Vale exchange goes before other clips of the same rank. An urgent line in between does not
    break the exchange.
  - A clip that expires while waiting is dropped, never played late.
  - caster.py sends `rank` and `exchange` with each host line, and serve.py takes a `cut` report.
  - `audio_selftest.mjs` overlaps five clips in a headless page and passes. It plays "A1 G U A2 B1": the agent fades
    A1 out, the urgent line fades G out, the exchange's second line comes before the other banter, and the expired
    clip never plays. Never two voices at once.
  - Until the caster restarts with this code, its lines carry no rank. The page then treats every host line as
    banter and every agent line as an agent, so urgent host lines don't interrupt yet.
- copy_bench puts logged facts in today's shape before writing: no walking, mottos only on the opener and spotlight,
  the shift by number, background numbers, card calls. `--match` picks the beats that went wrong.

- Item 6 (Nick: the hosts are "kinda dumb and still very LLM-y").
  - Speak less. Exchanges are 3 to 6 s apart (was 1 to 3). A camera cut, board note, harness note, research start or
    aloud chat line is said only after 20 s of quiet (`--quiet`). Filler comes only after 40 s of quiet (`--lull`,
    was 0), and only when something changed since the hosts last spoke or the analyst has a point. "Something
    changed" means technologies done, the research, the science rate in steps of 5, the stage, the board's claims or
    the alerts. Chat feeds the hosts only when an agent says it aloud (it was 25% of all chat). Urgent beats stay on
    Kimi (`--urgent-model` now defaults to it), whichever writer `--model` picks. `--gap 1 3 --lull 0 --quiet 0`
    brings back the continuous cast.
  - Richer facts.
    - Each agent carries `intent`: its newest say or tell, under 10 minutes old, cleaned for speech.
    - "walking" becomes "heading off for <board job>", or is dropped when there is no job.
    - Each agent carries `since_last_beat`: a new job, something new said, back from respawn, a new task, or
      "nothing new since the hosts last saw them".
    - The notes ask for a reason behind every line (news, a cause, a number that moved). An agent with nothing new
      is not worth a line, and there are no riffs on mottos or small notes.
  - Bigger writers. copy_bench and the caster take `or=<OpenRouter model>` (`--writer or`, OPENROUTER_API_KEY) beside
    `cf=` and `claude=`, and the bench reports cost per stream hour (`--per-hour`, default 300 exchanges). The
    comparison command is in `copy_bench.py`'s docstring and the final message of this round. It was not run from
    this session.
  - Limits. The bench feeds logged facts, which have no `intent` or `since_last_beat`, so it tests the prompt and
    the writer but not the new facts. The speak-less rules were tested with a stubbed writer, not on a live run.

Replayed over shake7's 1,200 aired writer lines, with facts in today's shape, today's checks would cut 288 (24%):
192 walking, 60 motto, 33 mockery. That assumes the writer keeps shake7's habits. Shake7's walking and motto lines came
from facts that no longer carry them, and the notes now ask for the opposite, so the live cut rate should be well
under that. The rewrite on a style fault catches most of the rest.

15 shake7 beats that went wrong, picked with `--match "walk|motto|still|again|classic|energy"`, with today's post-filter
on today's facts. The model's after lines for these beats could not be written from this session: the sandbox denies
api.cloudflare.com. They come from the command below.

| aired in shake7 | today |
|---|---|
| Rook: Grok's walking now. Engine or bust. | cut: walking filler |
| Rook: Opus is writing commands again. Planning, they call it. | cut: mocks an agent |
| Rook: Picking up turrets to walk west. Reuse, recycle, retrench. That's the motto almost. | cut: walking filler |
| Vale: Water main. That's pipes, pumps, lots of walking. | cut: walking filler |
| Rook: Their motto's "ore to orbit." Concrete fits. | cut: motto filler |
| Rook: Astra's new drills are in. They said they'd repay the favor. Still waiting. | cut: mocks an agent |
| Rook: Six and a half hours. First rocket's up, and Astra's still walking. | cut: walking filler |
| Rook: Grok's still walking. Hope that shore's close. | cut: walking filler |
| Rook: Opus is walking back to spawn again. | cut: walking filler |
| Rook: Their motto says steam first. They took it literal. | cut: motto filler |
| Vale: Sol's back from the dead and already writing orders. That's the motto talking. | cut: motto filler |
| Vale: They need hands more than plans. Opus is still walking. | cut: walking filler |
| Vale: Opus died, but the nest is gone. One for three spawners is a trade they take. | kept |
| Rook: Astra just claimed the concrete cell job. | kept |
| Vale: Twenty-eight. That's a whole suburb doing nothing. | kept |

To get the model's after lines and compare writers:

    L=~/code/player-of-games/tools/stream/logs
    python3 tools/stream/copy_bench.py $L/caster-20261011-130031.jsonl --n 15 \
        --match "walk|motto|still|again|classic|energy" \
        --writers cf=@cf/moonshotai/kimi-k2.6,cf=@cf/zai-org/glm-5.3-flash --md /tmp/copy-bench7.md

## Hosts, round 2 (HOSTS2.md, 2026-10-11 afternoon)

- Shift numbering (shake6 study P1 item 2). The `shift` fact is now `this_shift` ("shift 3"), `next_shift`
  ("shift 4"), `earlier_shifts`, `resumed_at_game_minute` and `at_the_deadline` ("the world is saved and shift 4
  continues it from there"), with no run names. It rides on every beat of a resumed run; the time left keeps its
  clock rule. `check_line` cuts a "shift N" that is neither this shift nor the next, and a run name ("Shake five",
  "shake5") that is not in the facts (pace facts still name their baseline). Shake6 aired "Shift five inherits smoke
  and debt" and "Shake five gets low density at ninety" in shift three.
- Planets (item 3). On Space Age runs the facts carry `planets_reached` (from the snapshot's `space.planets`, Nauvis
  at least) and `planets_not_reached_yet`. The show notes say only the planets reached have been visited, and
  `check_line` cuts a line that names an unreached planet unless it talks about the future ("next", "goal", "will",
  "on the way" and so on). Vale's "won't rebuild Vulcanus" is cut; "Vulcanus is the next big goal" passes.
- Base-game runs had the Space Age notes. model.py sends a `space` block on every run (`space_age` false in the base
  game), and `show_for` took any block as Space Age. `is_space_age` now reads the flag.
- From shake7's first minutes (it runs main from before these commits):
  - The numbers check counts per sentence. "Eleven gone now. Six pipes, two inserters." was cut and is now allowed.
  - The simile check cuts only drawn-out images, four words or more after "like a". "Talking like a shift supervisor" was cut and is now allowed.
  - Templates speak alerts as a person would: "11 lost to small biters. 6 pipes, 2 inserters.", "Biters at the steam engine.". Shake7 aired "Damage report: 11 lost: 6 pipe, 2 inserter (by small biters)." twice in a minute.
  - Event beats now carry the run's standing numbers under `background`, to mention only if they matter. These are the research percentage, the science rate, the stage and the technologies done. Shake7's hosts said "Rocket fuel at twenty two/twenty four/twenty six/twenty seven" in 6 of their first 30 lines. Story beats (open, research, lull, power) keep those numbers up front.
  - The style rewrite is logged ("[writer] rewrite after ..."), and copy_report counts it.
- `tools/stream/copy_report.py runs/<run>/caster.log [--last 30]` reads a running shift's caster log, read only: the
  template share and the `[cost]` fallbacks count, cuts by reason (style cuts by kind), and the tells left in writer
  lines next to the shake4-6 shares. On shake6 (before the copy changes) it gives 5% templates, 0 style cuts and
  62% dash pivots.

## Hosts that sound human (COPY.md, 2026-10-11)

Nick: the hosts' lines "seem super AI-format-ty". This section counts the tells, sums up how live casters talk,
and describes the writer changes. It ends with 30 lines on the same facts.

### The tells, counted

All 1,393 lines a writer model aired in shake4, shake5 and shake6 (`runs/shake{4,5,6}/caster.log`, Kimi K2.6;
template lines left out). One line can show several tells.

| tell | lines | share | example |
|---|---|---|---|
| dash pivot (an em dash mid-line) | 861 | 62% | "Sol's motto holds—furnaces warm, science moving—they're walking the walk right now!" |
| ends on "!" (623 have one anywhere) | 536 | 39% | "Logistics 2 surges to sixty-nine! Belt dreams live!" |
| body or drama metaphor on machines (starve, bleed, choke, feast, gasp, drown, scream, chew) | 356 | 26% | "twelve packs starve six labs while research dreams of green" |
| three-part list | 260 | 19% | "Muse malling belts and inserters, Astra fueling, Grok eyeing that lake—seven hands, one patchwork plan" |
| a host's name as address ("Rook,", "Vale!") | 248 | 18% | "Five fewer plates, Rook, and Grok's still sight-seeing" |
| semicolon | 200 | 14% | "They speak; they act. A rare moment of clarity in the rookery." |
| stock words (humming, cooking, deep, alive, symphony, chaos...) | 179 | 13% | "blue science humming", "three hours deep" |
| ends on a question | 139 | 10% | "Classic opening, but two claims on the board already—patient or slow?" |
| "X, not Y" / "not X, but Y" | 91 | 7% | "those furnaces want coal now, not philosophy!" |
| nature-documentary words | 70 | 5% | "Here we find Luna in deep thought ... a specimen of Codex, rare and luminous" |
| number with a metaphor in one clause | 49 | 4% | "Twenty-five of eighty-six machines gasping" |
| simile ("like a ...") | 39 | 3% | "like a heron staking its fishing ground" |

Sentence shapes repeat as well:
- **Openings:** 24% open on a number ("Thirty-three science, Rook..."), 23% on a name and a verb ("Opus walks..."), 10% on "Name's X".
- **Length:** lines average 14.9 words and 1.25 sentences, and 150 run to 20 words or more.
- **Frequent words:** "while" is the most frequent word of four letters or more, from the "A does X while B does Y" shape. "still" is fifth, and "dreams" also ranks high. Lines with the stock words "deep", "cooking" and "alive" are counted in the table.
- **Where the shapes come from:** the old prompt asked for them. Rook's persona said "vivid verbs, exclamations welcome", and the rules said "Be fun, like a great esports cast". The naturalist angle asked Vale for a hushed nature documentary.

### How live casters talk (research, with sources)

- **Short and reactive.** Real calls are fragments and reactions. Vin Scully's "High fly ball into right field, she is... gone!" was followed by more than a minute of silence ([1988 World Series](https://en.wikipedia.org/wiki/Kirk_Gibson%27s_1988_World_Series_home_run)). Al Michaels counted down "11 seconds, you've got 10 seconds", saying the number once and plainly ([Miracle on Ice](https://en.wikipedia.org/wiki/Miracle_on_Ice)).
- **Bursts and labels.** Studies of streamers find short "response cries" ("nice.", "oh shit.", "wait ...?") and short labels for a known kind of play ("What a disgusting roam") ([Recktenwald, PolyU thesis](https://theses.lib.polyu.edu.hk/bitstream/200/9795/1/991022179237803411.pdf)).
- **Sportscaster grammar.** Announcers drop the subject and the verb "is" ("Kestrel with the red circuits"), and use result phrases and stock routines ([Ferguson 1983, Language in Society](https://resolve.cambridge.org/core/journals/language-in-society/article/abs/sports-announcer-talk-syntactic-aspects-of-register-variation/6B134D8B6D90BD6B5B073B6C10A33FC0)).
- **Writing for the ear.** Talk to one person. One idea per sentence, short enough for a breath. Subject, then verb. Use contractions, strong verbs and rounded numbers said the way people say them. Read it aloud ([NPR](https://www.npr.org/2023/02/17/1156597697/how-to-write-script-speech-podcast-voice), [UBC](https://wiki.ubc.ca/Course:LFS400/Workshops/Writing_For_the_Ear), [journalism.university](https://journalism.university/audio-podcast/mastering-art-writing-audio-news)).
- **Play-by-play and colour.** Play-by-play says who and what. Colour says why, and does not repeat the play-by-play's facts. Colour gets out of the way on a big moment, and its longer thoughts go in the lulls and replays ([Say the Damn Score](https://www.saythedamnscore.com/sliding-analyst-chair/), [Wikipedia: colour commentator](https://en.wikipedia.org/wiki/Color_commentator)).
- **Hand-offs.** Casters pass by name, with a question the other answers ("Is this really happening, Bill?").
- **The AI tells.** Wikipedia's [Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing) lists "not X, but Y", the rule of three, puffed-up words and em dashes. These are the same tells counted above.
- **Prompting.** Anthropic's [prompting guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices) says examples are among the most reliable ways to steer tone. It recommends three to five varied ones, saying what to do with the reason given, and writing the prompt in the style wanted. Ban lists alone leak: one fix for dashes found models swapping in "--".

### What changed in the writer (`tools/stream/caster.py`)

- **Personas.** Rook speaks in "short plain words" and "reacts out loud". The old "vivid verbs, exclamations welcome" is gone. Vale answers Rook in plain talk.
- **`SPOKEN` style notes.**
  - The notes give the reason: every line is spoken by a voice engine on a live stream.
  - They are written in the style they ask for: short sentences, no dashes, no semicolons.
  - They ask for fragments, one idea per sentence, plain verbs, and who before what.
  - They ask for reactions ("Oh, there it is." "Wait, is that Grok?" "Huh."), answering the other host, and colour that doesn't repeat play-by-play.
  - Numbers: said once, at most one per line.
  - Endings: mostly full stops, and one exclamation an exchange at most.
  - Questions only when the other host answers. Calm moments are fine.
  - A short "never" list covers dashes, "X, not Y", lists of three, metaphors and similes, documentary narration, the stock words, and opening on a number.
  - Lines are at most 18 words (was 25).
- **`EXAMPLES`.** Twelve short exchanges in the hosts' voices, written for this, from made-up moments. Each call shows four at random, so no single shape hardens into a template. The fact check still applies to anything the writer copies from them.
- **Naturalist angle.** It keeps the close watching and drops the documentary narration.
- **Post-filter, part one: `restyle()`.** A dash pivot, a semicolon or an ellipsis becomes a full stop, which turns one line into two short sentences.
- **Post-filter, part two: `style_fault()` in `check_line`.** It rejects:
  - an "X, not Y" or "not X, but Y" contrast;
  - documentary words;
  - the stock words;
  - a body metaphor on machines, unless the facts use the word themselves ("84 of 234 machines starved" is the power alert's own wording);
  - a simile ("looks like a coal run" is fine).
- **Post-filter, part three: `tidy_exchange()`.** Exclamations after the first in an exchange become full stops, and a closing question nobody answers is dropped.
- **One rewrite.** When a style fault cuts an exchange before two lines, the writer is asked once more, with the reason and the line. Urgent beats are not retried. A second miss falls back to a template, as any failed draft does.
- **Cost and latency.** The notes and examples add about 445 tokens a call. That is about $0.0004 an exchange on Kimi K2.6, or roughly $0.08 an hour at shake5's pace. A rewrite costs one more call of about 2.7 s (Kimi's median in shake5). The next exchange is already prepared while the current one plays.
- **Voices.** The hosts stay on OpenAI voices (verse and ballad) unless `POG_TTS_PREFER=eleven`. With ElevenLabs working again, that is about 40,000 characters an hour, so it's Nick's cost decision.

### Replaying the post-filter over shake4-6

Over the 1,328 aired writer lines in the shake4-6 jsonl logs:
- `restyle` rewrites 76%, nearly all dash pivots.
- `style_fault` would cut 36%:

| reason | lines |
|---|---|
| "X, not Y" | 87 |
| documentary words | 54 |
| "dream(s)" | 65 |
| bleed and similar | 42 |
| starve and similar | 38 |
| "humming" or "hums" | 40 |
| simile | 27 |
| feast, gasp, choke, scream and other metaphors, stock words, the rest | the remaining 125 |

- `tidy_exchange` would turn 75 extra exclamations into full stops and drop 44 hanging closing questions, over 622 exchanges.

The 36% is the old prompt's output. The post-filter is a backstop, and the new notes and examples are meant to keep drafts from tripping it. If a live run shows many template lines (the `fallbacks` count in `caster.log`'s stats), loosen `BODY_WORDS` first.

### 30 lines on the same facts

Each item gives three lines:
- **aired:** what the old writer aired in shake4, shake5 or shake6.
- **post-filter:** what `restyle` and `style_fault` now do to that line, or "cut".
- **target:** a hand-written line on the same beat's facts, showing what the new notes aim for. Every target passes the new `check_line` against that beat's logged facts.

The targets are not model output. No writer model could be reached from this session:
- the wrangler OAuth token for Workers AI has expired;
- the sandbox denies registry.npmjs.org, so `npx wrangler` can't refresh it;
- api.cloudflare.com and api.anthropic.com are denied as well.

To get the model's own after lines on these 30 beats, refresh the login (`npx wrangler whoami`) and run `copy_bench.py` as shown below. It prints the same 30 beats, the same seed, with each writer's new exchange and the tell counts before and after.

Pairs 16, 26 and 29 show the limits of the filter. "a funeral pyre dressed as a boiler room" passes it, and so do "hit the ground running" and the misread "Seven hits" (seven buildings were lost). Those are for the prompt and the fact check to fix. Pair 21's "Grok's packer promise" is a fair callback: Grok had said "I will keep the packers fed" in a chat beat a minute earlier.

1. chat, game 2 hours 45 minutes
   - aired: Vale: Astra finally answers Luna's plea—guns first, copper second, acid third? That's three plans stacked on one stack inserter.
   - post-filter: Astra finally answers Luna's plea. Guns first, copper second, acid third? That's three plans stacked on one stack inserter.
   - target: Vale: Astra says they'll refill the west guns. Right after the copper build.
2. camera, game 3 hours 34 minutes
   - aired: Rook: Opus walks still! Steam first, they said—where is the steam, Vale?
   - post-filter: Opus walks still! Steam first, they said. Where is the steam, Vale?
   - target: Rook: Opus on the move, Astra planning. Both in shot.
3. attack, game 2 hours 8 minutes
   - aired: Rook: Boilers burning, assemblers cracking—biters taste steam and circuits both! This raid's a buffet.
   - post-filter: Boilers burning, assemblers cracking. Biters taste steam and circuits both! This raid's a buffet.
   - target: Rook: Biters on an assembler. Now a boiler too.
4. board, game 11 minutes
   - aired: Rook: Astra boards a coal run—five drills, public chest—fueling boilers while their motto hangs in the air!
   - post-filter: Astra boards a coal run. Five drills, public chest. Fueling boilers while their motto hangs in the air!
   - target: Rook: Astra's posted a coal job. Five drills into a public chest, for the boilers.
5. lull/analyst, game 2 hours 34 minutes
   - aired: Vale: Thirty-three science, Rook, and blue's finally even—though most of it is idle labs staring at empty belts.
   - post-filter: Thirty-three science, Rook, and blue's finally even. Though most of it is idle labs staring at empty belts.
   - target: Vale: Thirty-three science a minute. And blue has caught up with green.
6. segment, game 30 minutes
   - aired: Rook: Spotlight locks on Sonnet — five iron pairs, eight steel furnaces, hand-fed and hungry!
   - post-filter: Spotlight locks on Sonnet. Five iron pairs, eight steel furnaces, hand-fed and hungry!
   - target: Rook: Spotlight on Sonnet. They're the one making steel.
7. loss, game 2 hours 54 minutes
   - aired: Rook: Seventy-six gone, pipes bleeding dry—Astra walks while the south chokes!
   - post-filter: cut (style: metaphor 'bleeding')
   - target: Rook: Ouch. Seventy-six buildings lost in that one.
8. research, game 1 hour 30 minutes
   - aired: Vale: Six techs up on shake1, twelve thousand iron ahead—they'll out-science their way to orbit if biters let them.
   - post-filter: Six techs up on shake1, twelve thousand iron ahead. They'll out-science their way to orbit if biters let them.
   - target: Vale: Stone wall's done. They're six technologies ahead of shake1 now.
9. power, game 1 hour 47 minutes
   - aired: Rook: Plastic crawls at forty-six, advanced circuits barely four—engines dream in molasses, Vale!
   - post-filter: cut (style: metaphor 'dream')
   - target: Rook: Power's short. Seventy-six machines aren't getting enough.
10. death, game 34 minutes
   - aired: Rook: Muse goes quiet—too quiet! They planned the next step, now they're planning respawn.
   - post-filter: Muse goes quiet. Too quiet! They planned the next step, now they're planning respawn.
   - target: Rook: Oh, Muse is down. Small biters, right at spawn.
11. research_start, game 2 hours 25 minutes
   - aired: Rook: Logistics 2 surges to sixty-nine! Belt dreams live!
   - post-filter: cut (style: metaphor 'dreams')
   - target: Rook: Logistics 2 at sixty-nine percent. Faster belts soon.
12. harness, game 2 hours 59 minutes
   - aired: Rook: Six minutes! Opus walks, Processing choking at thirty-seven, and Astra's electric drill volunteers for burner hospice duty!
   - post-filter: cut (style: metaphor 'choking')
   - target: Rook: Opus has filed a bug. Building over a machine puts a second one on top.
13. open, game 3 hours 9 minutes
   - aired: Rook: We're live! Shift three picks up a world already three hours deep—blue science humming, processing units eighty-one percent done!
   - post-filter: cut (style: stock word 'humming')
   - target: Rook: Welcome back. Shift three, same world, right where they saved it.
14. chat, game 17 minutes
   - aired: Vale: Gemini borrows iron and circuits now, trading scraps to birth three inserters for their belt dream.
   - post-filter: cut (style: metaphor 'dream')
   - target: Vale: Gemini's borrowing from Sol. Three inserters for the belt mall.
15. camera, game 3 hours 4 minutes
   - aired: Rook: Muse Spark plots, Sol schemes, and the clock bleeds under sixty seconds!
   - post-filter: cut (style: metaphor 'bleeds')
   - target: Rook: Muse and Sol, both planning. Under a minute left.
16. attack, game 4 hours
   - aired: Vale: Walls hold today, but shift three handed shift four a funeral pyre dressed as a boiler room, Rook.
   - post-filter: unchanged
   - target: Vale: Biters on the stone wall. Well, that's what it's there for.
17. board/naturalist, game 3 hours 33 minutes
   - aired: Vale: Watch now as Luna, specimen planning, scratches commands toward orbit while coal politics rage westward.
   - post-filter: cut (style: nature-documentary narration)
   - target: Vale: Luna just okayed Astra's coal line inside their own claim. Very polite team.
18. lull/analyst, game 3 hours 45 minutes
   - aired: Rook: Sol, Luna, Opus—all walking! Three engineers strolling while iron bleeds a hundred plates a minute into starvation!
   - post-filter: cut (style: metaphor 'bleeds')
   - target: Rook: Three of them on foot right now. Opus is one.
19. segment, game 3 hours 17 minutes
   - aired: Rook: Replay rolls—biters chewing steam at forty-eight, sixteen, three seconds gone!
   - post-filter: Replay rolls. Biters chewing steam at forty-eight, sixteen, three seconds gone!
   - target: Rook: Here's the replay. Biters went for a steam engine.
20. loss, game 1 hour 35 minutes
   - aired: Rook: Eleven buildings gone and red science starved—biters feast while Sol's copper sits on the belt!
   - post-filter: cut (style: metaphor 'starved')
   - target: Rook: Eleven buildings lost. Four of them turrets.
21. research, game 1 hour 35 minutes
   - aired: Rook: Advanced Circuit lands—Sulfur Processing next, Grok's packer promise pays off!
   - post-filter: Advanced Circuit lands. Sulfur Processing next, Grok's packer promise pays off!
   - target: Rook: Advanced circuits are done. Sulfur processing is next.
22. power, game 1 hour 48 minutes
   - aired: Rook: Precious and stranded! No blue packs rolling, thirteen minutes, Vale—they're researching bricks while the factory gasps.
   - post-filter: cut (style: metaphor 'gasps')
   - target: Rook: Power's dipping again. Eighty-four machines short.
23. death, game 1 hour 44 minutes
   - aired: Vale: They'll keep that research, Rook; death costs nothing but time, and biters already took their thirty.
   - post-filter: They'll keep that research, Rook. Death costs nothing but time, and biters already took their thirty.
   - target: Vale: Haiku's down at spawn. They'll be back, and the research doesn't care.
24. research_start, game 1 hour 30 minutes
   - aired: Vale: Forty-seven on circuits, twenty techs deep, green lines humming—they out-research their repairs.
   - post-filter: cut (style: stock word 'humming')
   - target: Vale: Advanced circuits, almost halfway. Twenty technologies done.
25. harness, game 2 hours 6 minutes
   - aired: Rook: Astra's walking, not working—what's the call there?
   - post-filter: cut (style: 'X, not Y' contrast)
   - target: Rook: Astra wants a harness change. A safer way into a fight.
26. open, game 1 minute
   - aired: Rook: Nine engineers hit the ground running! Opus, Grok, Muse—everyone's still at spawn figuring out who grabs the first pick.
   - post-filter: Nine engineers hit the ground running! Opus, Grok, Muse. Everyone's still at spawn figuring out who grabs the first pick.
   - target: Rook: Welcome in. Nine AIs and one factory, and the game is a minute old.
27. chat/naturalist, game 1 hour 3 minutes
   - aired: Vale: Here we find Luna in deep thought, planning their next step—a specimen of Codex, rare and luminous, murmuring coal routes to Astra like a bird sharing a worm.
   - post-filter: cut (style: nature-documentary narration)
   - target: Vale: Luna watches everyone. Saw Astra take the forty iron and still asked for a coal route.
28. camera, game 3 hours 22 minutes
   - aired: Rook: Sonnet pauses between tasks—brain reloads while biters chew pipes north!
   - post-filter: Sonnet pauses between tasks. Brain reloads while biters chew pipes north!
   - target: Rook: Sonnet's between jobs. Sol walking past.
29. attack, game 1 hour 34 minutes
   - aired: Rook: Seven hits, two turrets down, one boiler—small biters just cost them steam!
   - post-filter: Seven hits, two turrets down, one boiler. Small biters just cost them steam!
   - target: Rook: Two turrets and a boiler gone.
30. board, game 3 hours 56 minutes
   - aired: Rook: Gemini plans, turrets bleed, two minutes left—who dies holding the blueprint?
   - post-filter: cut (style: metaphor 'bleed')
   - target: Rook: Gemini's starting on rocket fuel. Two minutes left in this shift.

### Running the writer comparison

It hasn't been run yet: no writer model could be reached from this session. To run it:

    npx wrangler whoami    # refresh the Workers AI login
    L=~/code/player-of-games/tools/stream/logs
    python3 tools/stream/copy_bench.py $L/caster-20261011-025203.jsonl $L/caster-20261011-052058.jsonl \
        $L/caster-20261011-072205.jsonl --n 30 \
        --writers cf=@cf/moonshotai/kimi-k2.6,cf=@cf/zai-org/glm-5.3-flash,cf=@cf/google/gemma-4-26b-a4b-it \
        --md /tmp/copy-bench.md

For each writer, the run reports:
- the tell counts before and after;
- lines kept by the fact and style checks;
- median and p90 latency;
- cost per 1,000 exchanges.

Workers AI prices per million tokens in/out (`TEXT_MODELS`): Kimi K2.6 $0.95/$4.00, GLM 5.3 Flash $0.15/$0.50, Gemma 4 26B $0.10/$0.30, DeepSeek V4 Flash $0.44/$1.32. With 30 exchanges per writer, the whole comparison costs well under $0.10.

Kimi stays the writer until a run like this shows another model writes plainer lines at a live-friendly latency (under about 5 s at p90). Earlier benches picked Kimi as the liveliest writer, and "lively" is part of what Nick heard as AI-ish.

## Round 6: shifts, the stage label, ElevenLabs off (shake5 P1 items 3, 4 and 5, 2026-10-11)

- Shifts (item 3). `caster.py --run-dir runs/RUN` (start-team.sh passes it) reads `resumed-from`, follows the chain
  of earlier shifts, and reads the resume tick from `start.log` ("resumed at tick N"). On a resumed run the hosts get
  `shift`: `number` (shake5 is 2), `continues` (shake4), `first_shift`, `resumed_at_game_minute` (124) and
  `at_the_deadline` ("the world is saved and the next shift continues it from there"). It rides with the clock: the
  opener, research, viewer, segment and pace/explain beats, and every beat in the last 15 minutes (every beat when no deadline is known). The opener's
  `how_to_call_it` asks the hosts to welcome viewers back to a later shift of the same world. The rule now says the
  agents play until the deadline and, when the facts carry a shift, that the deadline is a handover: the world is
  saved and research in progress and the base carry over. `check_line` rejects "ends the run" and "game over" lines
  on a shift at any time. A first shift (no `resumed-from`) gets no shift fact, since nothing says whether another
  shift will follow.
- Stage label (item 4). Stage 3 is "Oil & blue science" in `model.py` (was "Oil"); the overlay, the site and the
  segment facts show the same label. The hosts' facts also carry `science_packs_made` ("red (automation)", "green
  (logistic)", "blue (chemical)", ...), the packs made so far, so the stage reads as progress.
- ElevenLabs off (item 5, TTS part). Under `--tts auto`, providers named in `POG_TTS_OFF` are left out of the TTS
  object, so a voice picked before they were turned off (Opus's saved `el-george`) goes straight to its stand-in
  through `substitute()` with no ElevenLabs call and no 401. start-team.sh exports `POG_TTS_OFF` (empty since
  ElevenLabs works again; `eleven` while it has no credits). A forced
  `--tts eleven` still uses ElevenLabs. The `profiles.lua` part of item 5 (refuse a voice another agent holds) is not
  in this branch.

Not done here, from the same study: P2 item 12 (baseline past its end; research beats still carried
`shake1_finished_this_at` at minute 151), P2 item 13 (old deaths without a respawn fact, mottos read as plans) and
P3 item 18 ("still as a heron", "Luna they-them").

## Round 5: fixes from the shake4 study (2026-10-11)

What docs/studies/shake4.md P2 items 9 and 11 and section 6 asked of the casters, each covered by `caster_selftest.py`:

- Baseline wording (item 9). `baseline.py` now says what each stored run was (`RUNS`, or `--about` and
  `--space-age` when building one): shake1 is "the team's first nine-agent run, in the base game on the same seed",
  never "the previous run". When the current run plays Space Age and the baseline is a base-game run, `compared_with`
  adds "this run plays Space Age, so only the start compares", and research facts carry `<run>_was` with the same
  text. Space Age snapshots now compare with `baselines/shake4.json` (the first Space Age run on the seed;
  `--space-baseline`, '' for none); base-game ones keep shake1. A resumed shift past shake4's game 123 minutes gets
  no comparison, as before. The show notes say "an earlier run of the team's" and tell the hosts to name it as
  `compared_with` describes it.
- Names (item 11). A roster name in a line counts only when that agent is on camera or anywhere in this beat's own
  facts, or is the one who did an earlier beat (`earlier_on_air` entries "board at ...: Luna - ..."). A name only
  mentioned inside an earlier beat fails. Agents' voiced lines now join `earlier_on_air` ("aloud at ...: Grok - ..."),
  so the hosts may call back to them (shake4 rejected Grok twice right after Grok spoke aloud). "Two Sols", "both
  Sols" and the like are rejected. Replayed over shake4's 696 aired lines, 21 name lines and the "two Sols" line
  would now be cut; the old logs have no aloud beats, so the Grok case is not in that replay.
- Section 6 mistakes. Loss facts say "engineers killed (an engineer respawns); no building was lost" when only
  engineers died (mistake 7), and "buildings destroyed and engineers killed" for a mix. Pace facts call electronic
  circuits "green circuits" (mistake 3). The rules say researching a technology unlocks it and does not mean
  anything was built or made (mistake 6). The naturalist wording (mistake 9) was already fixed on main. Mistake 8,
  the analyst's "co-op", is eng/analyst's (item 10).

## Round 4: fixes from the shake3 study, the analyst's points, Space Age (2026-10-11)

What docs/studies/shake3.md P1 items 1, 2 (caster part) and 3 and P2 item 12 asked for, each covered by
`caster_selftest.py`:

- Attack and loss text. The runtime's `<entity> x<N>` is a hit count and "(by N small biter)" is a kill count.
  `live.py` (eng/stream2's version of the fix, adopted here so the branches merge) writes banners and replay titles
  without the counts: "Engineer under attack near (-48, 16)", "Base under attack near (64, 0): gun turret", and "21
  lost near (12, -40): 9 transport belt, 5 burner mining drill (by small biters)". For older text, `caster.py`'s
  `spoken()` turns "x9" into "hit 9 times" and "character" into "engineer". The "the biters are damaging:" prefix is
  gone. Loss facts, and attack facts that still carry a number, include `numbers_mean`. EXCHANGE_RULES states it as true statements: attack numbers count hits on the team's buildings or
  engineers, loss numbers count the team's buildings destroyed, and "character" and "engineer" mean one of the
  team's engineers.
- Time left. `--deadline` takes "YYYY-MM-DD HH:MM", "HH:MM", or a deadline.txt file or glob (the latest wins).
  start-team passes `"$rundir/*/deadline.txt"`. `minutes_to_deadline` goes on the opener, research, viewer and
  segment beats and the pace and explain fillers, and on every beat in the last 15 minutes. On every beat, the
  hosts said "forty-six minutes left" four exchanges running in a mock cast. `check_line` rejects "ends the run"
  before the last minute, and "N minutes left/to go/more minutes" lines that disagree with the fact or come without
  it. Research beats also get `compared_with_shake1` ("15 minutes later"), so the hosts need not do the arithmetic.
- Status "thinking (standing still)" is now "planning the next step" ("idle" is "between tasks"). The rules and the
  naturalist prompt describe planning kindly. Space Age pilot: most mockery lines were about standing still.
- Pronouns. `profile.pronouns` reaches the snapshot (`live.py`, `model.py`) and every agent fact (`pronouns`, else
  "they/them"). The rules say to use them. `check_line` rejects he/him/his or she/her when no agent in the facts
  chose them.
- `check_line` also catches "isn't there", "nowhere to be found" and "doesn't exist" absences, capitalised names
  outside the facts and roster, and lines in other scripts (Kimi aired Chinese characters once in the pilot).
  "Outside the roster" means a mid-sentence capitalised word in neither the facts nor the show notes, or any word
  listed with an agent's name ("Gear and Sol").
- Numbers written as words in the facts count as facts, so Sol's "eleven labs are working" lets the hosts say
  "Eleven labs" (P2 item 12). `game_minutes` covers "sixty-five minutes in".
- Rechecked over the aired lines: shake3, 12 of 425 lines would now be rejected (the study's "isn't there",
  "ends the run", "Gear and Sol", "she", "forty more minutes", and seven invented names). The Space Age pilot:
  3 of 187.
- Who spoke. Caster and agent records log `provider` and `voice` (the provider's voice id), plus `retried` when it
  applies, from `voices.TTS.last_here()`. That is a per-thread copy of `last`, because an exchange is synthesised
  in parallel. `caster_report.py` prints "spoken by". Mock run: `pbp: openai/verse`, `color: openai/ballad`.
- A Workers AI 8008 error ("AiError: Internal server error") retries once on another Aura-2 voice of the same
  gender (atlas to draco, thalia to theia). A second failure drops the line as before. eng/voices pointed out that
  the TTS failure counters (`down`, `fails`) are shared between the synthesis threads without a lock. Two threads
  failing at once can both count, so a provider may rest after 2 failures instead of 3.

The analyst (docs/ANALYST-NOTES.md, the split agreed there and in "Viewer questions answered by the analyst" below):

- Filler beats use the analyst's talking points. A fresh priority-3 point gets its own beat (angle `analyst`).
  Otherwise each angle takes the best unused point of a fitting kind: pace takes comparison or judgement; explain
  takes explainer, prediction or trivia; production takes stat; research takes prediction or stat; spotlight and
  board take storyline. The point goes in as `analyst_point` (the analyst's `point_facts`, which includes `pace`
  for run comparisons). Once the model writer has built lines on it, `POST /analyst/used` marks it, so it is never
  offered again.
- `corrections` (up to 6, verbatim) go into every beat's facts. The opener gets `analyst_headline` and
  `next_milestone`.
- Viewer questions are eng/analyst's code (the viewer branch of `facts_for`, the Differ's question loop, the viewer
  template). Two lines in `say_exchange` still call `self.ask_analyst(e)` when such a method exists. Nothing
  defines one, so they do nothing. They were to be removed as agreed, but a PreToolUse hook (Cygnal) blocked that
  edit, so they are left for a person to delete.
- Bench (`--bench`, Kimi, mock snapshot with one analyst cycle): 22/27 lines kept. The analyst case gave "seven labs
  are gasping, four more green assemblers needed", and the correction was used ("those are walls holding").

Space Age (eng/stream2 143eb0d, and the analyst's pilot suggestions):

- `space` alerts (first rocket, platform, orbit, landing) rank with research (priority 7). The hosts talk over
  `space` and `space_moment` segments; a moment is called "a milestone for the team". Platform `speed_kms` is
  dropped from the facts until it is checked against the game's km/s. Lulls may request a `space` segment when
  the director lists it as available.
- SHOW now covers the crash site (scenery from before the game; its fire is harmless) and the fact that research
  progress is always kept. On Space Age runs (the snapshot has `space`, the subtitle names Space Age, or
  `POG_SPACE_AGE=1`) it adds the expansion's goal and says a two-hour run is mostly the Nauvis start.
- Dry run against eng/stream2's `mock-sa3.json`: "Orbital One reaches Vulcanus! Forty-nine minutes, and space opens
  wide!", and a template line over the landing after a writer timeout.

Not done or not checked: the shake1 pace baseline still applies on Space Age runs, where the early game is similar
but later techs differ. The new rule wording has had one bench and two short mock runs, not a live world. Kimi
timed out at 12 s twice in the 100 s Space Age mock run (shake3 logged 9 timeouts in an hour). Spend this round:
about $0.08 of Workers AI and OpenAI TTS.

## Second pass: the hosts talk to each other, know the show, and never go quiet

Asked for on 2026-10-10 evening (the first two items of that request arrived cut off; this pass reads them as "the
hosts banter in multi-line exchanges" and "give them context so viewers understand and the hosts can judge how well
the bots play, e.g. against shake1"). What changed in `caster.py`:

- Exchanges. Each beat is a 2-3 line back-and-forth between Rook and Vale written in one call (`--lines 2 3`;
  urgent events get 2). Every line goes through the fact check; the exchange is kept up to its first bad line, and a
  template line stands in if nothing survives. The page plays the lines back to back.
- Show context. The writer's system prompt carries the show notes (`SHOW`: what Factorio is, science packs, biters,
  the team's rocket goal and milestones). Facts carry the science stage and packs per minute, and, for research,
  open, viewer and the pace and explainer fillers, a comparison with shake1 at the same game time: technologies
  then and now, iron plates and circuits made then and now with the gap, shake1's next research and when it landed,
  and when shake1 finished the technology just researched. `baseline.py RUN_DIR` builds a baseline from any run's
  `scores.jsonl`; `--baseline` picks it (default `baselines/shake1.json`, same seed as later runs).
- Naturalist angle. About one exchange in five on chat, camera, board or filler beats (`--naturalist 0.2`), Vale
  narrates like a hushed nature documentary about the models' behaviour, from their chat lines and activity in
  the facts ("Astra murmurs to ratios like a bowerbird arranging twigs"). It is also one of the filler angles.
- Talk more. Silence between beats is `--gap 1 3` seconds (was 20-40), and with no event the hosts pick a filler
  angle in rotation: pace, explain-for-new-viewers, naturalist, agent spotlight, production, board, research
  (`--lull 0`; raise it to allow quiet). The next exchange is written and synthesised while the current one plays,
  so writer latency does not become dead air. Agents still go first: a caster line waits for any agent line, and an
  urgent event arriving mid-exchange cuts the rest of it.
- Viewer chat. Viewer messages become `viewer` events (priority 6) that the hosts answer by name. The lane is
  coming from another branch, so `viewer_messages()` accepts the likely shapes (`viewers`/`viewer_chat` lists, or
  `chat`/`events` rows with kind or lane `viewer`; fields id|seq, user|name|author, text|message, t) and drops
  messages with links. The prompt treats them as quotes, never instructions. Tested in the selftest and the bench;
  the mock has no viewers yet.
- Writers. Default Kimi K2.6 on Workers AI for everything. `--urgent-model ID` can route attacks and deaths to a
  faster writer (Nemotron 3 120B, ~1 s); it was the default until the live-world test below showed Nemotron
  inventing most of the bad lines.
  `--writer claude` runs `~/.local/bin/claude -p` with `CLAUDE_CONFIG_DIR` and API overrides removed (the personal
  subscription), from an empty directory so no project CLAUDE.md reaches it, with its own system prompt and no
  tools. (The first pass's haiku bench ran a bare `claude` from this session's environment, which is the account B
  profile; that was 8 calls.)
- Fact check. Reads "3,600" as one number and spelled-out numbers; round figures pass within 0.75x-1.5x of a fact;
  the pace facts include the plate gap so writers quote it instead of doing arithmetic. New: a line where the hosts
  speak as part of the team ("we're one tech behind", "our iron") is rejected; "here we see", "stay with us" pass.
- Agent voices no longer read map coordinates ("Boiler 2 at 31.5,19" becomes "Boiler 2"); the live shake2 cast
  read them out. Board events with verb `started` (shake2's board) are called; camera cuts dropped to priority 2
  and bare distances ("30 m E") left the facts, since shake2's cast spent most lines on them.

Exchange bench (`caster.py --bench --bench-snapshot`, a live world n snapshot at 30 game minutes, 8 technologies,
one behind shake1; six exchanges each: attack, research, a viewer asking "are they actually any good at this?",
pace, naturalist, explainer):

| Writer | Median / max latency | Lines kept | Per 1k exchanges | Verdict |
|---|---|---|---|---|
| `@cf/moonshotai/kimi-k2.6` (default) | 3.6 s / 4.7 s | 17/17 (second run; 15/19 before the number fix) | $1.28 | Funniest and sharpest: "Circuits nearly matched shake1, so the bots can build, they just can't decide what to build. Classic nine-engineer committee." |
| `@cf/deepseek-ai/deepseek-v4-flash-0731` | 2.1 s / 2.9 s | 19/22, then 20/23 | $0.55 | Natural banter, good runner-up |
| `@cf/nvidia/nemotron-3-120b-a12b` (urgent) | 1.4 s / 1.4 s | 15/17 (11/18 once "we" was rejected) | $0.63 | Fastest decent writer; says "we" for the team a lot |
| `claude -p --model sonnet` | 7.7 s / 11 s | 10/17 | $308 API-equivalent (subscription) | Best analysis and explainer, but slow and quota-hungry |
| `claude -p --model haiku` | 6.1 s / 10.5 s | 12/17 | $18 API-equivalent (subscription) | Good, grounded; slow for a continuous cast |
| `@cf/google/gemma-4-26b-a4b-it` | 2.0 s / 4.8 s | 17/17 | $0.12 | Fine but generic and over-dramatic ("while the base burns") |
| `@cf/qwen/qwen3.8-27b` | 2.8 s / 12 s | 11/17 | $0.45 | Two timeouts |
| `@cf/zai-org/glm-4.7-flash` | 3.0 s / 3.7 s | 16/19 | $0.09 | Odd phrasing ("kilo-ton behind", "tamesters") |

Thinking models need thinking switched off or they return nothing (`MODEL_ARGS`): Kimi `chat_template_kwargs:
{thinking: false}`, GLM-5.3 `thinking: {type: disabled}`, the rest `enable_thinking: false`. gpt-oss-120b (7.9 s),
Llama 4 Scout and Mistral Small (quote marks and markdown in the lines) were dropped after a probe. A continuous
cast runs ~250 exchanges an hour: Kimi about $0.35/hour; Sonnet through `claude -p` would be ~$75/hour of
API-equivalent subscription quota, so it is not the default.

`--writer claude --model haiku` in the continuous loop (3 min dry run on the mock): 5.5 s per exchange, hidden by
writing during the previous exchange; Nemotron still took the urgent beats in about 1 s. Its rejects were all
callbacks to agents from earlier beats ("Sonnet's still nursing that smelter"), so each beat's facts now carry the
last four story beats (`earlier_on_air`).

Mock runs with the new pacing (4 min each, Node page listening, Aura-2): voices on air 78-81% of the time, median
silence 0.5-1.6 s, longest 5 s, no clip over another; 18-19 exchanges and 29 caster lines per 4 minutes; 4 of 18
exchanges naturalist. Cost rose with the airtime: **$1.6-1.7 per hour**, of which Aura-2 speech is $1.4. `--tts
aura1` halves the speech bill (shared voices for agents); `--gap 4 8` or `--lull 10` trades airtime for money.

Live world (world n just after shake2's 22:44 deadline, with the agents stopped and biters overrunning the base:
a read-only `serve.py --world n --no-camera` on port 8797 and a Node page; OBS was streaming shake2 and was not
touched). Two 5-minute casts:

1. Nemotron on every urgent beat (every beat was urgent): 41 lines, 10 templates. It invented things the fact
   check could not see: "last run they'd still be punching trees" about ten times on beats with no pace facts,
   "still no steam power", "zero belts laid". Each death got its own beat, so the cast looped. Alert text was read
   raw ("assembling machine-1 x129", "sonnet died").
2. After the fixes (urgent beats fold into one with `also_happening`; previous-run comparisons rejected without pace
   facts; "zero" checked; absences forbidden in the rules; display names and "(129 of them)" in alert text; Kimi on
   everything): 45 lines in 22 exchanges, 38 from the model and 3 templates, 5 rejected, voices on air 81%, silences
   1.2 s median and 5.1 s at most, no overlaps, $1.69/hour. Fillers covered pace, explainer, naturalist, spotlight
   and production between the attacks: "Here at the watering hole, two specimens rest—Luna smoothing feathers, Opus
   preening a finished nest", "One tech up on shake1, yet two hundred fewer plates—smart or slow?" ("Smart books,
   slow hands!"). One invented absence still got through ("Still no walls, still no turrets"), so the fact check now
   also rejects "still no X", "no X yet", "no X in sight" and "not a single". Rechecking every logged second-pass line
   (75 with facts): it would have rejected 7, all of them wrong ("still no steam power", "zero belts laid", "our iron's
   crawling"), and nothing that was right.

Merging with eng/voices: the only conflict is `tools/stream/voices.py`; take eng/voices' version whole (it carries
this branch's coordinate and "1,000" handling). `caster_selftest.py` passes against it with its `textprep.py`,
`lexicon.tsv` and `vocab.tsv`. caster.py passes caption text to `TTS.speak()`, which preps the audio text itself.

## Segments (with eng/stream2)

Agreed with eng/stream2 on 2026-10-10. eng/stream2 shows the segments and runs the director; the casters ask for
them and talk over them. Inert until serve.py serves `/segments`.

- `GET /segments` returns `{"types": [{type, title, params, seconds: [min, max], available, why}], "busy",
  "next_ok"}`. The types are production, research, spotlight `{"agent": name}`, overview (a zoomed-out map),
  recap (the last few minutes plus a summary card) and attack_replay. attack_replay stays unavailable until it
  gets the OBS replay buffer and scene switching during a live stream (eng/stream2 is waiting on Nick for both).
- `POST /segment {"type", "params", "seconds", "by": "caster", "reason"}` returns 200 `{"id", "state": "queued",
  "eta", "seconds", "title", "facts"}`, 409 `{"error": "busy" | "declined" | "unavailable", "retry_after"}` or
  400. `facts` holds every name and number on screen, fixed for the segment's life.
- The snapshot's `segment` is `{"id", "type", "state": "starting" | "live" | "ended", "started", "ends", "title",
  "facts", "by", "reason"}` or null. "starting" lasts about 2.5 s; an urgent event can end it early (`"cut":
  "attack"`).
- Caster side (`caster.py`): in lulls it asks for one of production, overview, recap or spotlight (a main-camera
  agent); after research it asks for research, and after an attack attack_replay. At most one request per
  `--segment-every` 180 s; the director also allows one per 3 minutes whoever asks, and fills lulls itself after
  about 6 quiet minutes. A segment that starts becomes a beat (priority 7) whose facts are `on_screen_now` (the
  segment's facts), so the fact check holds the hosts to what is on screen. While it is live with more than 6 s
  left, filler beats keep talking about it. While a segment is on screen its beat goes first (anything but a fresh
  priority-9 event), and a segment beat is dropped, even mid-exchange, once that segment has left the screen.

End to end against eng/stream2 (commit 4cef2b3, its mock with `"segments": {"spacing": 5}`, tone voices, a Node page):
the caster's own request after a research event was queued ("Research: Fluid handling 23%") and, later, declined
with 409 while an attack was on screen, as agreed. A production segment that stayed up 30 s got an exchange over it
5 s into its life: "Copper's surging fifty percent in ten minutes—somebody finally remembered the red desert!" /
"While advanced circuits bled out, down to ten." Three bugs found and fixed on the way:
the opener and an attack outranked the segment until an attack cut it; "fifty-one" for an on-screen 51.4 failed
the fact check (numbers within 1 of a fact now pass); and the hosts talked about a segment 25 s after an attack had
cut it. The mock raised an alert every few seconds, so most segments there were declined or cut within seconds.
eng/stream2 then changed the rule (4320f73, same API): a segment is cut, and requests are declined for 20 s, only
when the director actually cuts the main camera to a fight, death, base attack or loss; alerts it lets pass no
longer end or block segments. The caster needs no change for that.

Attack replays (eng/stream2 a3bc5dd, f9f88e2): the director queues each saved clip itself (about 17 s after it
cuts to a fight, 5 s after a death on the main camera), plays it in the OBS "replay" scene with the overlay page
riding along, and mutes the clip. The caster no longer asks for replays; it talks over them like any segment, with
the facts event, kind, agent, seconds and ago_s, plus a hint to call it as an instant replay in the past tense. The
first hint mentioned "muted" and the banner, and Kimi read those words on air ("Replay shows—muted, that REPLAY
banner"), so the hint now says only how to call it. On the bench: "Replay's up! Astra bites it twenty-one seconds
ago." Not run against a real replay (needs OBS on the box); the selftest and the bench cover the facts and the writing.

## Viewer questions answered by the analyst (eng/analyst, round 4)

The analyst (`tools/stream/analyst.py --viewer-questions`, on in start-team) picks the freshest viewer question
from the lane. It answers at most one every 150 s, takes nothing older than 60 s, and skips off-topic or unsafe
questions. It posts the restated question and a checked answer as `analyst.answers` in the snapshot. In
caster.py, eng/analyst owns only:
- the viewer and answer loops in `Differ.diff` (plain questions wait for the analyst while
  `questions_on(analyst)`; comments are unchanged);
- the viewer branch of `facts_for` (`analyst_answer`, `how_to_call_it`);
- a `viewer` template that fills only with an answer.
These are covered by caster_selftest.py "viewer questions". No `ask_analyst` hook is needed in `say_exchange`.
Details and the split with eng/audio's talking-points work are in docs/ANALYST-NOTES.md, "What the analyst
writes" and "Viewer questions on air".

Two suggestions for `SHOW`, from the Space Age pilot (your text, so not edited here):
- The crash site. At 01:39 the hosts called the replay of the burning wreck "pure biter buffet". Suggested
  sentence: "Every game starts beside the wreck of the engineers' crashed spaceship (the crash site): scenery
  from before the game, with a few starting items; its fire is harmless, and the engineers never crash."
- The goal. On Space Age runs (the stream's subtitle names Space Age, POG_SPACE_AGE=1), "The team's goal is a rocket
  launch" is wrong. Suggested: "In Space Age a rocket launch is a milestone: rockets carry a space platform starter
  pack to orbit, space science is made on the platform, and the expansion's goal is reaching the solar system
  edge. A 2 h run will mostly be the Nauvis start: oil, plastics and blue science are the big milestones."
- Write true statements in rules and facts ("research progress is always kept"), never negated mistakes. In
  the pilot, 31 of the analyst's 37 corrections were negated ("not because progress was lost"); the analyst's
  prompt now avoids them.

## Status

| Part | State (2026-10-10) |
|---|---|
| Second pass: exchanges, show context and shake1 pace, naturalist angle, continuous talk, viewer lane, new writers | Benched (8 writers), selftests, three mock casts; real-world test below |
| `caster.py` live: Gemma 4 writer, Aura-2 voices, Clef-flash classifier, mock feed, OBS page listening | Four live runs (3 to 5 min each), all lines from the model, none rejected; results below |
| All 41 Aura-2 voices, plus Aura-1 and MeloTTS | Rendered, loudness measured, transcribed back with Whisper (`voices.py --check`) |
| Writers: Gemma 4 26B, Llama 3.3 70B, Llama 3.1 8B, gpt-oss-20b, `claude -p --model haiku` | Benched (`caster.py --bench`) |
| OBS: cam1 process capture, limiter, sidechain ducking, music slot, overlay limiter (`obs.py stream-audio`) | Applied to scene `stream`; levels metered |
| Scratch scene `audio-test`, two one-minute recordings | Made: `D:/pog/recordings/2026-10-10_20-04-57.mkv` and `..._20-08-27.mkv` (box clock); program scene back on `stream` |
| cam1 with game sound, music off (`start-client.ps1 -Sound`) | cam1 in world n restarted with `-Sound`; `start-team.sh` now passes `-Sound` to cam1 |
| Overlay player, voice queue, selftests | `caster_selftest.py` all pass; `audio_selftest.mjs` 6/6 (earlier session) |
| macOS `say` voices | Not run (the sandbox blocks the speech service; works in a normal terminal) |

Development spend on Workers AI: about $0.33 by the scripts' own counters (voice survey with Whisper $0.16, benches
$0.01, four live runs $0.16).
Nothing was streamed and the `pog` profile's output settings were not touched.

## Run it

```sh
python3 tools/stream/serve.py --mock --port 8788                    # or --world live --run RUN.json (docs/STREAM-NOTES.md)
python3 tools/stream/caster.py --feed http://127.0.0.1:8788 --tts-fallback aura1   # Kimi K2.6 exchanges + Aura-2 + Clef
python3 tools/stream/caster.py --writer template --tts say --classifier heuristic   # free and offline (macOS)
python3 tools/stream/caster.py --writer claude --model sonnet        # `claude -p` (personal profile) writes the exchanges
python3 tools/stream/caster.py --gap 20 40 --lines 1 1 --lull 50     # roughly the first pass's sparse, single-line cast
python3 tools/stream/caster.py --dry-run --writer template           # print lines only, nothing synthesised or pushed
```

The overlay page plays whatever the caster pushes, so the OBS browser source needs no change beyond "Control audio
via OBS" (`reroute_audio`, already on in `tools/obs.py stream-scene`). By default the caster synthesises nothing
while no page is listening (`/audio/status` listeners = 0), so a forgotten caster costs nothing; `--always` overrides.

Credentials for the Cloudflare backends: `CLOUDFLARE_API_TOKEN` (+ `CLOUDFLARE_ACCOUNT_ID`), or else the wrangler
login. The wrangler OAuth token lasts an hour; `cfai.py` re-reads the file and, once the token has expired, runs
`npx wrangler whoami` to refresh it. The account picked is "the owner's Cloudflare account".

Checks (the voice survey is about $0.16, a bench under a cent):

```sh
python3 tools/stream/voices.py "Luna holds the west wall, what a defence!" --voice all --check --out /tmp/voices
python3 tools/stream/caster.py --bench --feed http://127.0.0.1:8788    # latency, rejects and cost per writer
python3 tools/stream/caster_report.py                                 # newest caster log: pacing, overlaps, cost
```

The wrangler token had expired when this session started; `npx wrangler whoami` refreshed it.

## How it works

```
serve.py (state, /events SSE) --> caster.py --(writer: Workers AI | claude | templates)--> line --> fact check
                                     |                                                             |
                                     +-- chat: aloud? else Clef/heuristic --> per-agent voice      v
                                                                                   TTS (Aura-2 | Aura-1 | MeloTTS | say | tone)
                                                                                                   |
overlay page (OBS browser source) <-- /audio-events <-- serve.py voice queue <-- POST /audio <------+
   audio.js: one voice at a time; a clip that matters more fades the current one out; captions
OBS: "stream game audio" (cam1 process capture, +4 dB, limiter) and "stream music bed" (-24 dB, disabled) each carry a
     compressor whose sidechain is "stream overlay", so game and music duck under every voice.
```

Events come from snapshot changes: alerts (attack, death, loss, power, research), board events (posted, taken,
done, blocked; harness requests), research switching, main-camera cuts, and chat. Priorities: attack/death 9, loss
8, research 7, power 6, harness 5, board and chat 4, camera 3, quiet-time "lull" 1. A burst of the same kind is one
story. Rook calls anything at research priority or above plus camera and board news; Vale answers big plays on the
next beat, picks up chat and fills lulls.

Pacing: one caster line, then a random 20-40 s gap (`--gap`), except urgent events (priority 8+) which wait only
`--urgent-gap` 8 s. Nobody starts while a clip is playing (the page reports start and end; the caster also tracks
clip lengths itself). Events older than 45 s are dropped. After 50 s of quiet Vale (or Rook) talks about the state.
Between synthesis and push each clip waits for the other channel (at most 10 s): a caster clip waits for any agent
clip, including one still in TTS; an agent clip waits only for a caster clip already playing, so agents keep
priority and the two cannot deadlock. This went in after the first live run showed two caster lines landing on top
of agent lines (each was written while the agent line was still being synthesised).

Never inventing facts: each line gets a facts object built only from the snapshot (event text with map coordinates
removed, the agent's display name, role, model, current action and place, research and its percent, technologies
done, a few production rates, board counts). The LLM sees only that plus the last six lines on air. Its output is
rejected (and a template line used instead) if it names an agent who is not in the facts, contains a number that is
not in the facts, runs over 34 words, or shares 60% of its words with a recent line. Template lines are filled from
the same facts and checked by `caster_selftest.py`.

Voiced chat: a message is voiced when the agent sent `say {text, aloud: true}` (eng/board stores it; the stream
service passes it through), or when the classifier calls it banter, strategy or emotion. Clef-flash classifies all
new messages of a poll in one call (one `choice` question per message: banter / strategy / emotion / logistics).
Without Cloudflare the local heuristic is used; on the mock's labelled lines it voices 14/18 banter lines and skips
32/36 logistics lines. Limits: one voiced line per agent per 60 s (`--agent-cooldown`), 15 s between voiced lines
(`--agent-gap`, `aloud` included), lines older than 20 s are dropped, text is cut at a sentence near 200 characters,
emoji, markdown, URLs and `@` signs are removed.

Clef live (three runs, 102 mock messages): 65 logistics, 9 strategy, 11 banter, none emotion, and 17 marked `aloud`
by the mock (not classified). Its calls were right on the lines checked by hand: "Labs are hungry and I'm the only one feeding them!"
banter, "Swapping to piercing ammo when we have steel to spare." strategy, "Blue science is starving for engines; Grok
can you bump the engine row?" logistics, "Inserted 200 blue packs." logistics. Cost: about $0.002 an hour.

## Voices

Voice ids are Deepgram Aura-2 speakers. Agents choose with `profile {voice: "orion"}` (see "Harness change" below).
Without a choice each agent gets a distinct voice picked by a hash of its name (stable for a given roster).

From Deepgram's Aura-2 catalogue (developers.deepgram.com/docs/tts-models, read 2026-10-10):

- Masculine: apollo, arcas, aries, draco (British), hermes, hyperion (Australian), jupiter, mars, neptune,
  odysseus, orion, orpheus, pluto, saturn, zeus
- Feminine: amalthea (Filipino), andromeda, asteria, athena, aurora, callista, cora, cordelia, delia, electra,
  harmonia, helena, hera, iris, janus (Southern), juno, luna, minerva, ophelia, pandora (British), phoebe, selene,
  theia (Australian), vesta
- Casters (reserved, never given to an agent): **atlas** for Rook (Deepgram: "enthusiastic, confident,
  approachable, friendly", mature) and **thalia** for Vale ("clear, confident, energetic, enthusiastic").
- Default picks for the nine-agent roster when nobody chooses: astra mars, gemini minerva, grok pandora, haiku
  neptune, luna odysseus, muse helena, opus electra, sol juno, sonnet jupiter. (The mock sets opus to orpheus and
  luna to theia through `profile.voice`.)

Survey (`voices.py --voice all --check`, one 125-character caster line, Aura-2): every voice was intelligible. Whisper
got every word from atlas, andromeda, apollo, aries, athena, helena, hera, hermes, juno, odysseus, orion and orpheus.
The common misses were the game word "biters" (heard as fighters, eiders or lighters by about a third of the voices)
and "Luna's" (Lunar, Luda, Linus). Raw loudness ranged from -18.8 LUFS (hera) to -29.7 LUFS (andromeda; harmonia,
minerva and zeus were also quiet), so `voices.py` now brings every cloud clip to -18 LUFS with a -1.5 dBTP limiter
(`TTS(target=...)`). Synthesis took 3.1-4.5 s for a 7-11 s clip (2.5 s median for the 5 s caster lines live).

Why atlas and thalia: atlas came back word-perfect, is one of the loudest raw voices, and Deepgram pitches it for
energetic advertising reads, which fits play-by-play better than draco (warm storytelling baritone, and Whisper
missed "biters"). Thalia is the most energetic of the clear feminine voices and contrasts with atlas, so viewers can
tell the two casters apart without captions. I chose from these measurements and Deepgram's descriptions; nobody has
listened to the voices yet, so a listen to `aura2-atlas.mp3` and `aura2-thalia.mp3` before going live is worth it.
Change them in `voices.CASTERS`.

Other backends, same line: Aura-1 (`--tts aura1`, 12 speakers, each id mapped to the nearest) took 1.2 s and is half
the price, but several agents share a voice; a good `--tts-fallback`. MeloTTS took 2.0 s, costs almost nothing and has
one voice, so it only suits a single caster. With `--tts say` each id maps to a macOS voice; robotic, but free.

## Costs per hour

Measured on the four live mock runs (16 minutes, the caster's own spend counter, Workers AI list prices from
developers.cloudflare.com/workers-ai/platform/pricing read 2026-10-10): **$0.53 to $0.63 per hour**, of which TTS was
over 90%. Caster voices alone are about $0.39 an hour; agent voices add the rest, and the mock (constant chat, many
lines marked `aloud`) is at the high end of that. Expect $0.50-0.60 an hour on a real team.

Writer bench (`caster.py --bench`, 8 lines each: pbp and colour on attack, research, camera, lull):

| Writer | Median latency | Rejected by the fact check | Cost per line | Notes |
|---|---|---|---|---|
| `@cf/google/gemma-4-26b-a4b-it` (default) | 0.8-1.2 s (0.75 s live) | 0/8, then 1/8 (a 30 s timeout, now capped at 12 s) | ~$0.00005 | Liveliest lines; needs `enable_thinking: false` or it returns nothing |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | 0.75-1.5 s (one 6.9 s) | 0/8 | ~$0.00014 | Accurate but flat ("Opus constructs offshore pump at power plant.") |
| `@cf/meta/llama-3.1-8b-instruct-fp8-fast` | 0.5 s | 1/8 (invented "46 percent") | ~$0.00003 | Wordy, garbles facts ("GPT-6 Luna's east wall") |
| `@cf/openai/gpt-oss-20b` | 3.4 s | 5/8 (empty or invented numbers) | ~$0.0002 | Reasoning eats the budget even at low effort |
| `claude -p --model haiku` | 7.5 s | 0/8 | $0 metered | Good, grounded lines; too slow to call plays as they happen |

Lines from the live runs, all Gemma: "Boom! Steel axe is officially online! They are charging toward oil gathering
with eighty-three percent completed!", "Watch out! Grok the Unyielding Builder is fighting off a biter fifty meters
southeast!", and Vale: "That little biter just punched a massive hole in their defenses. It is a setback while they are
eighty percent through sulfur processing". Gemma spells numbers out, which the digit-only fact check missed, so
`check_line` now also reads spelled numbers (eleven and up). A round figure passes when a fact is 0.75x to 1.5x of
it ("over a hundred machines" for 140 starved). All 24 live lines pass the stricter check.

| Piece | Model | Price | Per stream hour (live runs) |
|---|---|---|---|
| Caster lines | `@cf/google/gemma-4-26b-a4b-it` | $0.10 / $0.30 per M tokens in/out | ~130 lines: **~$0.01** |
| Caster voices | `@cf/deepgram/aura-2-en` | $0.030 per 1k chars | ~130 lines x ~100 chars: **~$0.39** |
| Agent voices | `@cf/deepgram/aura-2-en` | $0.030 per 1k chars | ~48 chars a line; 60-150 lines: **$0.09-0.22** |
| | `@cf/deepgram/aura-1` | $0.015 per 1k chars | half of the Aura-2 figures |
| | `@cf/myshell-ai/melotts` | $0.0002 per audio minute | ~$0.002 (one voice) |
| Chat classifier | `@cf/cloudflare/clef-flash` | $0.038 per M input tokens | ~400 messages: **~$0.002** |
| **Total** | Gemma 4 + Aura-2 + Clef-flash | | **~$0.50-0.60 per hour** (Aura-1 voices: about half) |

The account's free 10,000 neurons a day (about $0.11) covers roughly the first 12 minutes. `caster.py` keeps a
running estimate and logs it every 5 minutes and at exit (`[cost]` lines; `type: cost` rows in the log). The
biggest saving knob is caster pacing: `--gap 30 50` cuts the caster voice bill by about a quarter.

## OBS

```sh
PY=tools/.venv/bin/python
$PY tools/obs.py stream-audio            # adds "stream game audio" + ducking + the music slot to scene "stream"
tools/winps.sh tools/win/start-client.ps1 -Name n -GamePort 34205 -Slot -cam1 -PlayerName pog-cam1 -Sound  # stop cam1 first
$PY tools/obs.py meter --seconds 30 --inputs "stream overlay,stream game audio"   # check levels and ducking
```

Applied 2026-10-10 to scene `stream` (and `audio-test`). `start-team.sh` now starts cam1 with `-Sound`, so a new team
run has game sound without the manual restart. `start-client.ps1` does nothing while the client's task is still
running, so stop the old `factorio-cam1.exe` first (as `rejoin.sh` does).

- Game audio: an Application Audio Capture (`wasapi_process_output_capture`) of `factorio-cam1.exe` only, at
  +4 dB, with a limiter at -12 dB in front of the fader. Measured: cam1 spectating a base peaks around -28 dBFS raw,
  so the stream gets the factory at -23 to -26 dBFS peak between lines. The three video captures get
  `capture_audio: false`; cam2 and cam3 stay muted (no `-Sound`). The pog profile has no Desktop Audio or mic.
- Factorio music: `start-client.ps1` always writes `music-volume=0`; `-Sound` only unmutes the client.
- Voices: the page plays clips at -18 LUFS (normalised in `voices.py`); OBS meters them at -2 to -9 dBFS peak. A
  limiter at -1 dB on the overlay source catches the rare spike (one clip metered +5.5 dBFS right after a page reload).
- Ducking: compressor (ratio 2.5, threshold -40 dB, attack 15 ms, release 700 ms) with sidechain "stream overlay" on
  the game audio and the music bed. Measured 13-16 dB down while anyone speaks (game -25 to -38/-41 dBFS), back up
  within a second after. Ratio 6 measured about 22 dB, which took the factory out entirely. The page plays one voice
  at a time (HOSTS3 item 5): an agent line fades a host line out instead of playing over it.
- After restarting `serve.py`, reload the overlay sources (`obs.py reload-overlay`, or the source's Refresh button):
  a page loaded from an older service keeps its board running but never loads `audio.js`, so it plays nothing. The
  service's `/audio/status` `listeners` count shows how many pages are listening (2 with `audio-test` built).
- Music slot: "stream music bed" plays `D:\pog\music\bed.mp3` on loop at -24 dB, disabled in the scene until an
  original track is there; enable the scene item when it is.
- Test without touching the stream scene: `$PY tools/obs.py audio-test --url http://HOST:PORT/ [--game-url URL]`
  builds scene "audio-test" with its own overlay source and the same mix. The box reaches the Mac either through the
  reverse tunnel (`ssh -N -R 8787:127.0.0.1:PORT pogwin`) or on the LAN (`serve.py --host 0.0.0.0`; the Mac is
  <mac-ip>). Switch the program scene to it, record a minute with `obs.py start`/`stop`, switch back.
  Done twice on 2026-10-10 (reverse tunnel to `serve.py --mock --port 8788`, real cam1 audio, live casters). Meter
  readings in the recording: game -23 to -26 dBFS peak between lines and -40 to -49 dBFS under voices at the old
  ratio 6; voices -2 to -13 dBFS. Files: `D:/pog/recordings/2026-10-10_20-04-57.mkv`, `2026-10-10_20-08-27.mkv`.

## Knobs

`caster.py`: `--gap 20 40`, `--urgent-gap 8`, `--lull 50`, `--stale 45`, `--agent-gap 15`, `--agent-cooldown 60`,
`--chat-stale 20`, `--max-chars 200`, `--no-chat`, `--writer cf|claude|template`, `--model ID`,
`--tts aura2|aura1|melotts|say|tone`, `--tts-fallback BACKEND`, `--classifier clef|heuristic`, `--backoff 120`,
`--claude-bin PATH`, `--always`, `--dry-run`, `--duration S`. Model-specific request arguments (thinking off for
Gemma, low reasoning for gpt-oss) are in `MODEL_ARGS`. A backend that fails three times in a row is skipped
for `--backoff` seconds: the writer falls back to templates, the classifier to the heuristic, TTS to
`--tts-fallback` (or silence). Verified with Cloudflare unreachable: the cast carried on with templates and the
fallback voice.
Personas, priorities, rules and templates are at the top of `caster.py` (`CASTERS`, `PRIORITY`, `RULES`,
`TemplateWriter.T`). `--push FILE` sends one audio file as a clip (stings, tests).

Overlay URL: `?mute`, `?caster=0.9`, `?agent=1.0`, `?fade=0.25` (seconds to fade out an interrupted clip), `?captions=0`. Captions show who is speaking above
the bottom of the main camera (agents above casters). A desktop browser needs one click to start audio; OBS does not.

OBS levels: `GAME_DB`, `MUSIC_DB`, `DUCK` at the top of the audio section in `tools/obs.py`.

## Harness change (eng/board)

Not in main as of the 2026-10-10 merge; eng/board is adding it. The spec: `profile` should accept `voice` (one of the ids above, lower case) and return it in `profile` and `profiles`; the
stream service already passes `profiles[].voice` through to the caster. In `profiles.lua`:
`if a.voice ~= nil then pr.voice = text_arg(a.voice, 'voice', 1, 16):lower(); changed = true end`, add
`voice=pr.voice` to `public(pr)` and to the `profiles` rows, and list the ids in the schema text. Unknown ids are
harmless (the caster falls back to the default). Agents outside the run config get a default voice until `live.py`
also copies `voice` for them (left out to keep this branch merging cleanly with eng/stream2).

For agents (one line for `agent/team.md`): "`profile {voice: \"orion\"}` picks your stream voice; `say {text, aloud: true}`
speaks a line on stream; use it for jokes, plans and big moments, at most once a minute."

## Tests

```sh
python3 tools/stream/caster_selftest.py                              # fact check, classifier, voices, differ, templates
python3 tools/stream/serve.py --mock --port 8796 &
node --experimental-eventsource tools/stream/audio_selftest.mjs http://127.0.0.1:8796          # the page player
node --experimental-eventsource tools/stream/audio_selftest.mjs http://127.0.0.1:8796 --listen 200 &   # a page for:
python3 tools/stream/caster.py --feed http://127.0.0.1:8796 --writer template --classifier heuristic --tts tone --duration 190
```

End-to-end results (mock, 3.2 min each, tone voices, Node page as listener): first run 7 caster lines (one per
~27 s) and 10 agent lines, 17 clips played; that was too much agent talk, so the per-agent cooldown went in. Second
run with the current defaults: 6 caster lines (one per ~32 s) and 2 agent lines (both marked `aloud`), 8 clips
played. In both, no two clips played on one channel at once and no caster line started while an agent was speaking.
The mock's chat (~10 messages a minute, a sixth of them banter) is busier than a real team's, so on a real run
expect fewer agent lines; loosen `--agent-cooldown` if the agents feel too quiet. Against eng/stream2's mock (2.5 min, dry run, short gaps): the casters called board
posts, a harness request, base attacks, a death and low power.

Live runs, 2026-10-10 (Gemma 4 + Aura-2 + Clef, `serve.py --mock` on 8788, OBS pages listening through the reverse
tunnel; `caster_report.py` on each log):

| Run | Minutes | Caster lines (median gap) | Agent lines | Caster over agent / agent over caster | Writer rejects | $/hour |
|---|---|---|---|---|---|---|
| 1 | 3.3 | 7 (27 s) | 6 | 2 / 0 | 0 | 0.60 |
| 2 (pre-TTS busy flag) | 5.0 | 11 (29 s) | 7 | 1 / 2 | 0 | 0.53 |
| 3 (hold between TTS and push) | 4.9 | 11 (25 s) | 13 | 0 / 0 | 0 | 0.63 |
| 4 (`aloud` on the full gap) | 2.9 | 8 (25 s) | 5 | 0 / 0 | 0 | 0.63 |

Every caster line came from the model (no template fallbacks). Run 3's 13 agent lines included 9 that the mock
marked `aloud`, which then had half the gap; `aloud` now uses the full gap. Caster lines average about 100
characters (6 s) with Gemma against 47 for the templates, so caster TTS is most of the bill; lowering the "at most 25
words" in `RULES` is the lever if that matters.

## Next

1. Listen: `aura2-atlas.mp3` and `aura2-thalia.mp3` from the survey, and the two `audio-test` recordings on the box.
   Nobody has heard the voices or the mix yet; everything above is meters, Whisper and Deepgram's descriptions.
2. The harness `voice` field (above), then agents can pick voices; and the team brief line for `aloud`.
3. An original music bed at `D:\pog\music\bed.mp3`, then enable "stream music bed".
4. Optionally a `CLOUDFLARE_API_TOKEN` scoped to Workers AI. Without one, `cfai.py` runs `npx wrangler whoami` when
   the hourly wrangler token expires (the same refresh that worked by hand today; the automatic path has not yet
   been through an expiry).

## Voices round 2 (eng/voices, 2026-10-10)

Goal: livelier voices than Aura-2, agents choosing their own, names said right, within about $24 a day of TTS.

### Status

| Part | State |
|---|---|
| Adapters in `voices.py`: ElevenLabs v4 (`eleven`) and v4 Turbo / Flash v2.5 (`eleven-fast`), OpenAI gpt-4o-mini-tts (`openai`), Cartesia Sonic 3.6 (`cartesia`), Inworld TTS-2 (`inworld`), plus `auto` | Written; request shapes checked against each provider's docs (read 2026-10-10) and by `voices_selftest.py` with HTTP mocked. **No real request made to any of them** |
| Bench `voice_bench.py` (20 lines, every provider and voice, spend cap, listening page) | Run 1 (Nick's terminal, 2026-10-10 23:53, cut off at 15 minutes): 315 clips, all 13 OpenAI voices, 21 ElevenLabs clips before the account refused, 33 Aura-2. Resumable now (below) |
| Voice catalog for agents (70 voices, sound descriptions, ids of 16 characters or fewer) | `agent/voices.md`; `team.md` gets the list for the providers with keys at launch (`new-run.sh`) |
| `profile {"voice_description": ...}`: a designed voice per agent (ElevenLabs, else Inworld) | `voices.py` and the stream service (`model.py`, `live.py`) ready; needs the harness field (ask below) |
| Lexicon `tools/stream/lexicon.tsv`: roster, casters, model names, Factorio words | Done; inline IPA for providers that read it, respellings elsewhere |
| Loudness | Unchanged: every clip to -18 LUFS, -1.5 dBTP limiter, now including the premium providers |

| TTS text prep (`textprep.py`): spaces back in glued lines, spoken forms, optional spaces-only model pass | Done; `textprep_selftest.py` on real `runs/shake2` lines (below) |

This session's sandbox refuses `api.elevenlabs.io`, `api.openai.com` and `api.cloudflare.com`, so the bench runs from
Nick's terminal. **Test spend so far: $0.67** (bench run 1 by the scripts' counters: OpenAI $0.44, ElevenLabs $0.14,
Aura-2 $0.08, Whisper under $0.01; refused ElevenLabs requests are not billed).

### Bench run 1 (2026-10-10 23:53, `runs/voice-bench/20261010-2353/`)

`voice_bench.py --providers eleven,eleven-fast,openai,aura2 --check`, cut off by a 15-minute timeout in Aura-2
(`andromeda`, 13 of 20 lines). On disk: OpenAI 13 voices x 20 lines, ElevenLabs `el-alice` 19 (v4), `el-chris` 2
(v4), `el-eric` 1 (`eleven-fast`), Aura-2 `amalthea` 20 and `andromeda` 13. The run died before writing
`results.jsonl`, so the error texts went only to the terminal. `voice_bench.py --index` rebuilt `index.html` and
`summary.md` from the files.

Why ElevenLabs stopped, from the file times:

- `el-alice` lines 1-19 were written 2 s apart (23:53:15 to 23:53:54). Then 86 requests failed in 12 s (`el-alice`
  line 20, every line of `el-bill`, `el-brian`, `el-callum`, `el-charlie`, `el-chris` lines 1-5): about 0.14 s each,
  a refusal before any synthesis. `el-chris` lines 6 and 7 then succeeded (23:54:08, 23:54:10), and about 610 more
  requests failed in the same way until 23:55:45 (about 0.15 s each), with one exception: `eleven-fast` `el-eric` line 17 at 23:55:12,
  the shortest line (49 characters).
- Not the voice ids: `el-chris` and `el-eric` failed on some lines and succeeded on others with the same id and
  model. A wrong id fails every line. Not the model either: v4 served `el-alice` throughout.
- Most likely the account ran out of character credits after about 1,900 characters. ElevenLabs answers
  `401 quota_exceeded` when a request needs more credits than remain, so a short line can still fit while longer ones
  are refused, which matches the pattern. It does not fit perfectly (`el-chris` line 5 at 97 characters failed, then
  lines 6 and 7 at 96 and 98 went through), so a rate limit (429) is the other candidate. The resumed run settles it:
  it prints the account's plan and credits first, and the exact error when it drops a provider.

Fixed in the bench: results are appended clip by clip (a cut-off run keeps its record and errors), `--give-up 4`
drops a provider after four failures in a row and prints the error, `--resume DIR` renders only the clips a folder
lacks, `--redo` re-renders named lines, `--account` prints plan and credits, and `--index DIR` rebuilds the page.
Under `--tts auto` the stream now handles the same failure: an account out of credits (401/402, "quota") rests for 30
minutes after one refusal, a 429 for a minute, other errors after three in a row for two minutes. Meanwhile its voices
go to a steady stand-in (a caster's next voice, an agent's closest voice on another working provider, else Aura-2)
instead of flipping provider clip by clip as short lines still fit the last credits.

The bench also caught a text-prep bug: `textprep` split real words it did not know, so every provider read "lab
elling", "co lour", "a go" and "Vulcan us" (lines 8, 16, 19, 20). British spellings (colour, labelling, organise,
centre), words of three letters or fewer, and lexicon names are now left alone. A short capitalised token splits only
into team-vocabulary words ("Myred", "Oilgather"). The mood guess was also wrong on four lines: "never placing a
chest by hand again!" got `[sighs]`, and two deadpan lines came out neutral and frustrated. It now scores strong and
weak words, so "again" alone is weak, and short flat sentences read as deadpan. The completion command re-renders
those 8 lines.

Measured (`summary.md`; latency is an upper bound, the time between clips written, including normalisation):

| Provider | Clips | Per clip | Speech rate | $/stream hour at 45k chars | Pitch movement, caster lines |
|---|---|---|---|---|---|
| `eleven` (v4) | 21 | ≤2.0 s | 12.8 chars/s | $3.60 | `el-alice` 13.2, `el-chris` 17.4 semitones |
| `openai` | 260 | ≤1.8 s (p90 ≤3.0 s) | 12.5 chars/s | $0.90 | `oa-verse` 10.9, `oa-ballad` 10.2, `oa-echo` 10.2 ... `oa-shimmer` 6.8, `oa-onyx` 5.2 |
| `aura2` | 33 | ≤5.8 s (includes Whisper) | 12.5 chars/s | $1.35 | `amalthea` 4.7, `andromeda` 8.0 |

Pitch movement is the 10th-to-90th-percentile spread of a voice's pitch over a clip (`voice_bench.pitch_movement`),
a liveliness proxy: it puts numbers on "Aura-2 is flat" and Eleven v4 well above OpenAI, but it is no verdict on
quality. The page has the full table under "Voices by pitch movement". OpenAI's measured 12.5 chars/s (not the
assumed 15) puts it at $0.90 an hour.

Complete run 1 (only the missing clips, plus the 8 lines above; about $3.67, of which ElevenLabs about $3.45, which
needs about 45k credits if the account bills v4 at 1 credit and Turbo at 0.5 a character). A second cut-off resumes
with the same command:

```sh
python3 tools/stream/voice_bench.py --resume runs/voice-bench/20261010-2353 --providers openai,eleven,eleven-fast \
  --redo color-lull,agent-excited-2,agent-excited-3,agent-frustrated-3,agent-deadpan-1,agent-deadpan-2,agent-deadpan-3,agent-plan
```

The remaining 39 Aura-2 voices (787 clips, about $2, over an hour with `--check`) are left out: they are today's
voices and only the baseline. Add `aura2` to `--providers` for the full set.

### Run it once keys are in place

Keys are one file each in `~/.config/pog/`: `elevenlabs.key`, `openai.key`, `cartesia.key`, `inworld.key` (the Base64
credential exactly as the Inworld portal shows it). A provider without its file is skipped. Keys go only to their
own provider; nothing prints or logs them.

```sh
python3 tools/stream/voice_bench.py --dry-run          # what would render and the estimated cost
python3 tools/stream/voice_bench.py --check            # every provider with a key + Aura-2, Whisper accuracy
python3 tools/stream/voice_bench.py --design --providers eleven --lines pbp-open,color-banter   # designed casters
python3 tools/stream/voice_bench.py --list eleven      # voices this key can use (ElevenLabs ids change, see below)
open runs/voice-bench/<stamp>/index.html               # each line across every voice; summary.md has the numbers
python3 tools/stream/caster.py --tts auto --tts-fallback aura1   # live: each voice on its provider
```

The full bench (18 ElevenLabs voices on both models, 13 OpenAI, 5 Cartesia, 3 Inworld, 41 Aura-2; 20 lines,
1,684 characters) is estimated at **$6.61**. `--max-spend` (default $8) refuses a bigger plan and stops a run that
goes over. `--check` adds Whisper at about $0.0005 a minute.

### Providers, prices, cost per hour

Prices are list prices read 2026-10-10 (elevenlabs.io/pricing/api, developers.openai.com pricing, cartesia.ai/pricing,
inworld.ai/pricing). Cost per stream hour assumes **45,000 characters an hour**: eng/audio's two-host casters talk
about 80% of the time and put Aura-2 at about $1.4 an hour (about 47k characters), agents included
(`voice_bench.CHARS_PER_HOUR`).

| Backend | Model | Price | $/stream hour | Hours a day in $24 | Arena Elo* | Why |
|---|---|---|---|---|---|---|
| `eleven` | Eleven v4 | $0.08 / 1k chars | $3.60 | 6.7 | 1323 (#2) | Most expressive: audio tags `[excited]`, `[sighs]`; inline IPA |
| `eleven-fast` | Eleven v4 Turbo, else Flash v2.5 | $0.04 / 1k chars | $1.80 | 13 | 1327 (#1) | ~100 ms; Turbo on the HTTP endpoint is unconfirmed, so a refusal drops to Flash v2.5 |
| `cartesia` | Sonic 3.6 | ~$0.049 / 1k (1 credit a char) | $2.21 | 11 | 1284 (#4) | Emotion and speed per line; inline IPA |
| `inworld` | TTS-2 | $0.025 / 1k chars | $1.12 | 21 | 1257 (#7) | Delivery instruction in words, inline IPA, voice design; cheapest good one |
| `openai` | gpt-4o-mini-tts | ~$0.015 / min (launch estimate; $12/M audio tokens) | ~$0.75 | 32 | not in top 15 | Steerable with a free-text instruction; 13 voices |
| `aura2` | Deepgram Aura-2 | $0.030 / 1k chars | $1.35 | 18 | | Today's voices; the stand-in for every other voice |

\* artificialanalysis.ai TTS leaderboard as read 2026-10-10. Eleven v4's launch promo ($0.022/1k) ends Oct 12; the
table uses the regular rate.

Left out: Hume Octave (Hume is shutting down its TTS API on 2026-11-13), Google Gemini 3.8 Flash TTS (#5, $16.5/M;
a good next adapter if Inworld disappoints), Qwen-Audio TTS (#3, Alibaba Cloud account needed).

### Defaults for shake3 (2026-10-11; provisional, from bench run 1's measurements, not by ear)

Use `--tts auto` (with `--tts-fallback aura1`). With the keys on this machine (`elevenlabs.key`, `openai.key`):

- Casters on OpenAI: play-by-play (Rook) `oa-verse`, colour (Vale) `oa-ballad`. They move their pitch most of the 13
  OpenAI voices on the caster lines (10.9 and 10.2 semitones), and the colour voice is British-leaning like
  `ROLE_DESIGN["color"]`. If they sound too alike, `oa-coral` (brighter, about 5 semitones above `oa-verse`) is the
  colour alternative. Change it in `voices.ROLE_VOICES`.
- Agents: their own pick. Without one, each gets a distinct OpenAI voice by name hash. `oa-onyx` and `oa-shimmer`,
  the flattest, are left out of the defaults (`voices.DEFAULT_SKIP`), leaving exactly nine besides the casters'. With
  today's nine names: astra `oa-ash`, gemini `oa-coral`, grok `oa-marin`, haiku `oa-alloy`, luna `oa-cedar`, muse
  `oa-echo`, opus `oa-fable`, sol `oa-nova`, sonnet `oa-sage`. An agent who picks an ElevenLabs voice gets it while
  the account works, else a steady OpenAI stand-in.
- Why OpenAI first: it rendered all 260 clips, while the ElevenLabs account refused most requests (above). At the
  measured speech rate everything costs about $0.90 a stream hour, about 26 hours a day within $24.
  `voices.PREFER` sets the order; `POG_TTS_PREFER=eleven` puts ElevenLabs first (casters `el-liam` and `el-alice` on v4
  Turbo, $1.80 an hour, agents on v4). Switch once `voice_bench.py --account` shows credits, the completed bench has
  been heard, and `el-liam` (not yet rendered) sounds right. Eleven v4 moved its pitch most in run 1 (13 to 17
  semitones).

### Recommendation per role before the bench (kept for reference; superseded by the defaults above)

- Casters: ElevenLabs v4 Turbo (`--tts auto` with `elevenlabs.key` puts caster lines on v4 Turbo: first on the arena,
  $1.80 an hour, 13 hours a day within $24). Casters take the first available voice in `voices.ROLE_VOICES`: `el-liam`
  for Rook, `el-alice` for Vale, then the Cartesia, Inworld, OpenAI and Aura-2 picks. `POG_ELEVEN_CASTER=eleven` puts
  casters on v4 ($3.60 an hour, under 7 hours a day). After the bench, prefer the designed caster voices (`--design`,
  `voices.ROLE_DESIGN`) if they sound better: a designed voice belongs to the account and does not expire.
- Agents: their own pick on its own provider (`auto`), or a designed voice. An agent without either gets a distinct
  voice from the premium providers that have keys (by name hash; Aura-2 only once those run out), so defaults are no
  longer Aura-2 once a key exists. Agent lines stay on v4 (the most expressive model); agents speak far less than the
  casters (about 15% of the characters), so that adds about $0.50 an hour. Together: about $2.10 an hour, 11 hours a
  day within $24.
- Fallback: `--tts-fallback aura1` stays. Under `auto` a failing provider now rests and its voices go to a steady
  stand-in (bench run 1, above).

Listen before deciding: the voice descriptions for ElevenLabs and Cartesia come from provider listings, and nobody
has heard any of these voices yet.

### How `voices.py` works now

- `CATALOG`: `id -> (provider, provider voice, description, Aura-2 stand-in)`. The 41 Aura-2 ids are entries too, so
  existing picks (`orpheus`, `theia` in the mock) still work. Premium ids carry a prefix: `el-`, `oa-`, `ca-`, `in-`.
- `TTS("auto")` routes each voice to its provider. A provider without a key, or resting after failures, hands its
  voices to a stand-in: the caster's next voice in `ROLE_VOICES`, an agent's closest voice on the most preferred
  working provider (`PREFER`), else the Aura-2 `like`. A single failed request does the same for that clip. `TTS("eleven")` (or any one provider) speaks everything through that provider: its own voices
  as themselves, Aura-2 ids through a voice of that provider with the same stand-in.
- Delivery: `mood()` guesses excited, frustrated, deadpan or neutral from the words; casters add a role style
  (`ROLE_STYLE`). Eleven v4 gets a leading audio tag, OpenAI and Inworld a one-sentence instruction, Cartesia an
  emotion and speed.
- `TTS(cache=DIR)` or `POG_TTS_CACHE=DIR`: identical lines are served from disk (off by default; the bench uses
  none). `tts.last` tells which provider, voice and mood spoke the latest clip; `tts.spent` uses that provider's rate.
- ElevenLabs default voices: ElevenLabs retires them on 2026-12-31, and only accounts made before March 2026 have
  them. The catalog ids come from a third-party list that matches ElevenLabs' docs where they show ids; one v4 docs
  example labels a different id "George". Check with `voice_bench.py --list eleven` and replace any that 404.

### Agent voice choice and designed voices

`team.md` now carries a "Voice" item with the voice list, filled at launch by `new-run.sh` from
`voices.catalog_markdown()` for the providers whose keys exist on this machine, plus Aura-2. With no keys that is the
39 Aura-2 voices (caster voices are left out). `agent/voices.md` is the full list, generated with
`python3 tools/stream/voices.py catalog`. Descriptions say how a voice sounds (pitch, age, accent, energy) and
avoid gender labels.

`profile {"voice_description": "gravelly old prospector, slow drawl, amused"}`: the first time the caster sees it,
`assign_voices` designs a voice (ElevenLabs voice design with `eleven_ttv_v3`, keeping the first preview, else
Inworld voice design), saves it to the account, and remembers it in `~/.cache/pog/voices/designed.json` keyed by agent
and description, so it is made once. The voice's id is `my-<agent>`. An explicit `voice` wins over a description; a
failed design is remembered and not retried for the same description. ElevenLabs bills the preview text (about 170
characters, under $0.02) and the voice takes a slot on the plan.

### Pronunciation

`tools/stream/lexicon.tsv`: written form, respelling, IPA, note. It covers the nine agents, the model names (GPT-6.1
is "G P T six point one", Claude), the casters (Vale as "Vail"), and Factorio words (biters as "byters": a third of
Aura-2 voices were heard as "fighters"; Nauvis, Gleba, Aquilo, Kovarex, roboport, SPM, UPS, AM2, logi). Matching is
on whole words, case-insensitive, except all-capital entries (SPM) which match only capitals, so "power-ups" is left
alone. `speak()` applies it for the provider that speaks: inline `/IPA/` for Eleven v4 and Inworld, `<<s|oʊ|l>>` for
Cartesia, respellings for the rest. If a model reads the IPA aloud, `POG_TTS_IPA=0` forces respellings everywhere.
Captions keep the written text. Provider pronunciation dictionaries (ElevenLabs, Cartesia) would do the same as the
inline forms with server-side state to keep in sync, so they are not used.

### TTS text prep: glued lines (`textprep.py`)

Late in long sessions Sol stops writing spaces ("deadline17:59", "fixingall12", "Coalchestisfull",
"Delivered2assemblers5electricinserters3poles"); in `runs/shake2` 58 of Sol's 92 lines are glued. TTS read these as
one mangled word. `TTS.speak()` now sends `textprep` output to the provider; captions keep the agent's text.

1. Spoken forms: the game clock (`41m35` is "41 minutes 35", `57m00` "57 minutes"), units and rates (`540kW`,
   `1.56MW`, `189/min` "per minute"), `~90` "about 90", `+` "plus"/"and", `#13` "number 13", arrows "to", compass
   points (`NW` "north-west", `facesN` "faces north"), `AM`/`AMs`/`asm` "assembler(s)".
2. Boundaries: letter/digit (`100iron`), camelCase (`thanksGemini`, `AMworking`, `NWscout`, a plural acronym glued to
   the next word `AMsto8` "assemblers to 8"), punctuation followed by a letter.
3. Word segmentation of tokens that are not words: Viterbi over `vocab.tsv` (1,690 words counted from the team's own
   chat and notes, unglued lines only, so "inserter", "handoff", "courier" are cheap) with the system dictionary as
   a costly fallback, plurals and -ed/-ing forms included. 1-3 letter pieces come only from the team vocabulary or a
   short built-in list, which keeps out dictionary junk like "ama" and "ere". About 0.5 ms a line.
4. If a long token is still glued after that, `textprep.Respacer` asks a cheap model (OpenAI `gpt-4.1-nano`, else
   `gpt-5-nano`, when `openai.key` exists; else Workers AI Llama 3.1 8B) to insert spaces. Its answer is used only if
   it equals the input with whitespace removed, so it cannot change a word; anything else (or a timeout) keeps the
   heuristic text. Answers are cached per line. `POG_RESPACE=0` turns the model pass off. On shake2 the heuristics
   alone unglue all 58 lines, so the model should rarely be called; it has not been called for real yet.

Results on shake2 (`textprep_selftest.py`, which also reads `runs/shake2/chat.jsonl` from the main checkout when
present): seq 237 "Delivered2assemblers5electricinserters3poles sciencechest6.5,6.5." becomes "Delivered 2 assemblers 5
electric inserters 3 poles science chest."; seq 385 "all9labs greenempty50m07 despitefourgreenAMs" becomes "all 9
labs green empty 50 minutes 07 despite four green assemblers"; seq 394 "At9packs/min each they'lldraininsertersquickly"
becomes "At 9 packs per minute each they'll drain inserters quickly". On 619 unglued lines from shake1 and shake2 the
changes are spoken forms and words glued by the coordinate stripping (next paragraph); clean caster-style lines come
back unchanged.

`speakable()` had a bug that glued words for every agent: the coordinate patterns also ate the space after a
coordinate, so "in chest -58.5,-23.5 for mall" became "in chestfor mall" (16 "chestfor" in two runs). A removed
coordinate now leaves a space. eng/audio's `speakable()`/`has_coords()` (ranges, `along x-82.5`, "1,000" kept) are
ported into this branch, plus that fix, a strip for bare map ranges with a minus (`-68..-48`), and `~` kept before a
number (captions show "~90" as written; the TTS text says "about 90").

### For eng/audio (`caster.py`)

Status 2026-10-10 23:10: item 1 done on eng/audio ("Casters: pass caption text to TTS"). eng/audio checked the merge:
the two branches conflict only in `tools/stream/voices.py`; take eng/voices' file whole. eng/audio's
`caster_selftest.py` passes against it (including the coordinate and "1,000" cases).

1. Drop the `voices.pronounce(...)` around the text passed to `tts.speak(...)`: `speak()` applies the lexicon itself,
   per provider, and a line already respelled loses the IPA forms (it still works, just less precisely). Keep passing
   the caption text: `speak()` also restores spaces and spoken forms (`textprep`), for the audio only.
   `speakable()` now matches eng/audio's version plus the fixes above, so merging eng/voices after eng/audio should
   take this branch's `voices.py`.
2. `--tts auto` (with `--tts-fallback aura1`) is the setting once keys exist. Caster voices then come from
   `voices.ROLE_VOICES`; `voices.CASTERS` still names the Aura-2 and `say` voices.
3. Optional: log `tts.last` (provider, voice, mood, cached) with each clip.

### For eng/board (harness `profile`)

1. `voice_description`: `if a.voice_description ~= nil then pr.voice_description = text_arg(a.voice_description,
   'voice_description', 1, 300); changed = true end`, returned in `public(pr)` and in the `profiles` rows. The stream
   service passes it through already. Then add to `team.md`'s "Voice" item: `or describe the voice you want with
   "voice_description":"..." (up to 300 characters) and the stream designs one for you`.
2. The `voice` schema text in `profiles.lua` lists the Aura-2 names; change it to "a voice id from the list in your
   team brief (unknown or unset: a default from your name)" so agents see the premium voices. Ids stay within 16
   characters.

### Not verified (check on the first bench)

Verified by bench run 1: OpenAI requests for all 13 voices; ElevenLabs v4 requests with the `el-alice` and `el-chris`
ids, and `eleven-fast` with `el-eric`. Still open: the other 15 ElevenLabs ids; whether `eleven_v4_turbo` is served
on the HTTP endpoint (the bench's results now record the model each clip used); whether Eleven v4 and Inworld read
inline IPA right (listen to "Sol", "Gemini", "Nauvis" in lines 1, 3, 4); the Cartesia `Cartesia-Version:
2026-08-14` header; OpenAI's per-minute cost against the bill; time to first byte (the bench measures full
responses).
