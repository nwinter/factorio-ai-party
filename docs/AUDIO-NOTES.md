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
