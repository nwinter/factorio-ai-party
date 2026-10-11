# Stream audio: shoutcasters, voiced agent chat, game audio

Branch `eng/audio`. Two AI casters (Rook, play-by-play; Vale, colour) talk over the stream, agents' best chat lines
are spoken in per-agent voices, and the main director client's game sound sits underneath, ducked whenever anyone
talks. Everything is mixed by OBS through the overlay's browser source.

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
   audio.js: caster channel + agent channel; casters duck to 30% while an agent speaks; captions
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
  within a second after. Ratio 6 measured about 22 dB, which took the factory out entirely. Agents over casters is
  done in the page (casters to 30%, `?duck=` to change).
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

Overlay URL: `?mute`, `?duck=0.3`, `?caster=0.9`, `?agent=1.0`, `?captions=0`. Captions show who is speaking above
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
