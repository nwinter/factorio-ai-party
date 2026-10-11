# Stream audio: shoutcasters, voiced agent chat, game audio

Branch `eng/audio`. Two AI casters (Rook, play-by-play; Vale, colour) talk over the stream, agents' best chat lines
are spoken in per-agent voices, and the main director client's game sound sits underneath, ducked whenever anyone
talks. Everything is mixed by OBS through the overlay's browser source.

## Status

| Part | State (2026-10-10) |
|---|---|
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
python3 tools/stream/caster.py --feed http://127.0.0.1:8788 --tts-fallback aura1   # Gemma 4 writer + Aura-2 voices + Clef
python3 tools/stream/caster.py --writer template --tts say --classifier heuristic   # free and offline (macOS)
python3 tools/stream/caster.py --writer claude --tts aura2           # `claude -p --model haiku` writes, Aura-2 speaks
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
| Bench `voice_bench.py` (20 lines, every provider and voice, spend cap, listening page) | Runs end to end on the `tone` backend (60 clips, summary, `index.html`). Not run on a real voice |
| Voice catalog for agents (70 voices, sound descriptions, ids of 16 characters or fewer) | `agent/voices.md`; `team.md` gets the list for the providers with keys at launch (`new-run.sh`) |
| `profile {"voice_description": ...}`: a designed voice per agent (ElevenLabs, else Inworld) | `voices.py` and the stream service (`model.py`, `live.py`) ready; needs the harness field (ask below) |
| Lexicon `tools/stream/lexicon.tsv`: roster, casters, model names, Factorio words | Done; inline IPA for providers that read it, respellings elsewhere |
| Loudness | Unchanged: every clip to -18 LUFS, -1.5 dBTP limiter, now including the premium providers |

Why nothing was heard: no provider key is in `~/.config/pog/` yet (only OBS, RCON and YouTube files), and this
session's sandbox refused `api.cloudflare.com`, so even Aura-2 could not be called. **Test spend: $0.00.**

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
inworld.ai/pricing). Cost per stream hour assumes **25,000 characters an hour**: the measured 13k caster plus 3-7k
agent characters (above), with room for agents now speaking more through `say --aloud`.

| Backend | Model | Price | $/stream hour | Hours a day in $24 | Arena Elo* | Why |
|---|---|---|---|---|---|---|
| `eleven` | Eleven v4 | $0.08 / 1k chars | $2.00 | 12 | 1323 (#2) | Most expressive: audio tags `[excited]`, `[sighs]`; inline IPA |
| `eleven-fast` | Eleven v4 Turbo, else Flash v2.5 | $0.04 / 1k chars | $1.00 | 24 | 1327 (#1) | ~100 ms; Turbo on the HTTP endpoint is unconfirmed, so a refusal drops to Flash v2.5 |
| `cartesia` | Sonic 3.6 | ~$0.049 / 1k (1 credit a char) | $1.23 | 20 | 1284 (#4) | Emotion and speed per line; inline IPA |
| `inworld` | TTS-2 | $0.025 / 1k chars | $0.62 | 38 | 1257 (#7) | Delivery instruction in words, inline IPA, voice design; cheapest good one |
| `openai` | gpt-4o-mini-tts | ~$0.015 / min (launch estimate; $12/M audio tokens) | ~$0.42 | 57 | not in top 15 | Steerable with a free-text instruction; 13 voices |
| `aura2` | Deepgram Aura-2 | $0.030 / 1k chars | $0.75 | 32 | | Today's voices; the stand-in for every other voice |

\* artificialanalysis.ai TTS leaderboard as read 2026-10-10. Eleven v4's launch promo ($0.022/1k) ends Oct 12; the
table uses the regular rate.

Left out: Hume Octave (Hume is shutting down its TTS API on 2026-11-13), Google Gemini 3.8 Flash TTS (#5, $16.5/M;
a good next adapter if Inworld disappoints), Qwen-Audio TTS (#3, Alibaba Cloud account needed).

### Recommendation per role (provisional: from the leaderboard and features, not by ear)

- Casters: ElevenLabs v4 (`--tts auto` with `elevenlabs.key`; casters take the first available voice in
  `voices.ROLE_VOICES`: `el-liam` for Rook, `el-alice` for Vale, then the Cartesia, Inworld, OpenAI and Aura-2 picks).
  At $2 an hour this fits the budget for streams up to 12 hours a day; for longer days use `--tts eleven-fast`. After
  the bench, prefer the designed caster voices (`--design`, `voices.ROLE_DESIGN`) if they sound better: a designed
  voice belongs to the account and does not expire.
- Agents: their own pick on its own provider (`auto`), or a designed voice. Agents speak far less than casters
  (about a quarter of the characters), so even v4 adds only about $0.50 an hour.
- Fallback: `--tts-fallback aura1` stays; under `auto` a failing provider falls back per clip to the voice's own Aura-2
  stand-in (`like` in the catalog), so a voice keeps a similar sound.

Listen before deciding: the voice descriptions for ElevenLabs and Cartesia come from provider listings, and nobody
has heard any of these voices yet.

### How `voices.py` works now

- `CATALOG`: `id -> (provider, provider voice, description, Aura-2 stand-in)`. The 41 Aura-2 ids are entries too, so
  existing picks (`orpheus`, `theia` in the mock) still work. Premium ids carry a prefix: `el-`, `oa-`, `ca-`, `in-`.
- `TTS("auto")` routes each voice to its provider; a provider without a key, or a failed request, falls back to the
  stand-in on Aura-2. `TTS("eleven")` (or any one provider) speaks everything through that provider: its own voices
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

### For eng/audio (`caster.py`)

1. Drop the `voices.pronounce(...)` around the text passed to `tts.speak(...)`: `speak()` applies the lexicon itself,
   per provider, and a line already respelled loses the IPA forms (it still works, just less precisely).
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

ElevenLabs default-voice ids on Nick's account; whether `eleven_v4_turbo` is served on the HTTP endpoint; inline IPA
on Eleven v4 and Inworld; the Cartesia `Cartesia-Version: 2026-08-14` header; OpenAI's per-minute cost; latency of
any premium provider from this network (the bench measures full-response time, not time to first byte).
