# Stream audio: shoutcasters, voiced agent chat, game audio

Branch `eng/audio`. Two AI casters (Rook, play-by-play; Vale, colour) talk over the stream, agents' best chat lines
are spoken in per-agent voices, and the main director client's game sound sits underneath, ducked whenever anyone
talks. Everything is mixed by OBS through the overlay's browser source.

## Status

| Part | State |
|---|---|
| `caster.py` event feed, pacing, fact check, template writer, chat voicing, heuristic classifier | Built and run end to end against the mock (this branch and merged with eng/stream2) |
| Overlay voice player (`static/audio.js`): queue per channel, caster ducking, captions, playback reports | Built; `audio_selftest.mjs` runs the real file in Node against the real service, 6/6 checks pass |
| `serve.py` voice queue (`POST /audio`, `/audio-events`, `/audio/clip/ID`, `/audio/status`) | Built and exercised by both tests |
| Workers AI writer, Aura-2 / Aura-1 / MeloTTS voices, Clef-flash classifier (`cfai.py`, `voices.py`) | Written from the current Cloudflare docs, **never called**: this session's sandbox refused `api.cloudflare.com` |
| `claude -p --model haiku` writer | Written, **never run**: the session's permission mode refused running `claude` |
| macOS `say` voices | Written, **produced no audio here**: the sandbox blocks the speech service (works in a normal terminal) |
| OBS: game-audio capture, sidechain ducking, music slot, scratch scene, meter (`tools/obs.py`) | Written, **not applied**: the session could read OBS but its permission mode refused changing it, so no test recording was made |
| Client music off (`start-client.ps1 -Sound`) | Written, not run (no SSH to the box from this session) |

So no real voice has been heard yet. The `tone` TTS backend (ffmpeg babble timed like speech) stood in for a voice in
every test. Development spend: $0.00.

## Run it

```sh
python3 tools/stream/serve.py --mock --port 8788                    # or --world live --run RUN.json (docs/STREAM-NOTES.md)
python3 tools/stream/caster.py --feed http://127.0.0.1:8788          # Workers AI writer (llama-3.3-70b fast) + Aura-2 voices + Clef
python3 tools/stream/caster.py --writer template --tts say --classifier heuristic   # free and offline (macOS)
python3 tools/stream/caster.py --writer claude --tts aura2           # `claude -p --model haiku` writes, Aura-2 speaks
python3 tools/stream/caster.py --dry-run --writer template           # print lines only, nothing synthesised or pushed
```

The overlay page plays whatever the caster pushes, so the OBS browser source needs no change beyond "Control audio
via OBS" (`reroute_audio`, already on in `tools/obs.py stream-scene`). By default the caster synthesises nothing
while no page is listening (`/audio/status` listeners = 0), so a forgotten caster costs nothing; `--always` overrides.

Credentials for the Cloudflare backends: `CLOUDFLARE_API_TOKEN` (+ `CLOUDFLARE_ACCOUNT_ID`), or else the wrangler
login. The wrangler OAuth token lasts an hour; `npx wrangler whoami` refreshes it, and `cfai.py` re-reads the file. A
stream longer than an hour should use a token scoped to Workers AI. The account picked is "the owner's Cloudflare account".

First checks once the network allows Cloudflare (each costs well under a cent):

```sh
python3 tools/stream/voices.py "Luna holds the west wall, what a defence!" --tts aura2 --voice all --out /tmp/voices
python3 tools/stream/caster.py --bench --feed http://127.0.0.1:8788    # latency, rejects and cost per writer
```

## How it works

```
serve.py (state, /events SSE) --> caster.py --(writer: Workers AI | claude | templates)--> line --> fact check
                                     |                                                             |
                                     +-- chat: aloud? else Clef/heuristic --> per-agent voice      v
                                                                                   TTS (Aura-2 | Aura-1 | MeloTTS | say | tone)
                                                                                                   |
overlay page (OBS browser source) <-- /audio-events <-- serve.py voice queue <-- POST /audio <------+
   audio.js: caster channel + agent channel; casters duck to 30% while an agent speaks; captions
OBS: "stream game audio" (cam1 process capture, -14 dB) and "stream music bed" (-24 dB, disabled) each carry a
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
(7.5 s for `aloud`), lines older than 20 s are dropped, text is cut at a sentence near 200 characters, emoji,
markdown, URLs and `@` signs are removed.

## Voices

Voice ids are Deepgram Aura-2 speakers. Agents choose with `profile {voice: "orion"}` (see "Harness change" below).
Without a choice each agent gets a distinct voice picked by a hash of its name (stable for a given roster).

- Masculine: apollo, arcas, aries, atlas, hermes, hyperion (Australian), janus, jupiter, mars, neptune, odysseus,
  orion, orpheus, pluto, saturn, zeus
- Feminine: amalthea, andromeda, asteria, athena, aurora, callista, cora, cordelia, delia, electra, harmonia,
  helena, hera, iris, juno, luna, minerva, ophelia, pandora (British), phoebe, theia (Australian), vesta
- Reserved for the casters: draco (Rook, British) and thalia (Vale).
- Default picks for the nine-agent mock roster: astra iris, gemini arcas, grok harmonia, haiku aurora, luna orion,
  muse orpheus, opus amalthea, sol juno, sonnet theia.

The genders and accents above are my reading of Deepgram's catalogue; listen to `voices.py --voice all` before
announcing them to agents. Aura-1 has 12 speakers, so each id maps to its nearest one (several agents may share a
voice). MeloTTS has one voice: only usable for the casters. With `--tts say` each id maps to a macOS voice (Daniel,
Karen, Moira, Tessa, Rishi, the Eddy/Flo/Reed/Rocko/Sandy/Shelley families); robotic, but free and distinct.

## Costs per hour

Volumes measured from the 3.2-minute end-to-end mock run: a caster line averages 47 characters and 3.2 s; voiced
agent lines average 48 characters. At the default pacing that is about 120 caster lines an hour (one per ~30 s); agent
lines are capped near 60 an hour by the per-agent cooldown and gaps (the second mock run gave about 40). Prices are the Workers AI list prices
(developers.cloudflare.com/workers-ai/platform/pricing, read 2026-10-10). Latency has not been measured.

| Piece | Model | Price | Per stream hour |
|---|---|---|---|
| Caster lines | `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | $0.293 / $2.253 per M tokens in/out | ~120 calls x ~550 in, ~40 out: **~$0.03** |
| | `@cf/meta/llama-3.1-8b-instruct-fp8-fast` | $0.045 / $0.384 | ~$0.005 (weaker writing, more template fallbacks expected) |
| | `claude -p --model haiku` | personal subscription | $0 metered; each call starts a CLI process (seconds). `--claude-bin PATH` picks the binary: from Python, `claude` resolves to the first one on PATH, not the shell's profile function |
| Caster voices | `@cf/deepgram/aura-2-en` | $0.030 per 1k chars | ~5.6k chars: **~$0.17** |
| Agent voices | `@cf/deepgram/aura-2-en` | $0.030 per 1k chars | ~2.9k chars: **~$0.09** |
| | `@cf/deepgram/aura-1` | $0.015 per 1k chars | half of the Aura-2 figures |
| | `@cf/myshell-ai/melotts` | $0.0002 per audio minute | ~$0.002 (one voice) |
| Chat classifier | `@cf/cloudflare/clef-flash` | $0.038 per M input tokens | ~300 messages x ~150 tokens: **<$0.01** |
| **Total** | Llama 3.3 70B + Aura-2 + Clef-flash | | **~$0.30 per hour** |

The account's free 10,000 neurons a day (about $0.11) covers roughly the first 20 minutes. `caster.py` keeps a
running estimate and logs it every 5 minutes (`[cost]` lines; `type: cost` rows in the log).

## OBS

```sh
PY=tools/.venv/bin/python
$PY tools/obs.py stream-audio            # adds "stream game audio" + ducking + the music slot to scene "stream"
tools/winps.sh tools/win/start-client.ps1 -Name live -Slot -cam1 -PlayerName pog-cam1 -Sound   # cam1 unmuted, music 0
$PY tools/obs.py meter --seconds 30 --inputs "stream overlay,stream game audio"   # check levels and ducking
```

- Game audio: an Application Audio Capture (`wasapi_process_output_capture`) of `factorio-cam1.exe` only, at
  -14 dB. The three video captures get `capture_audio: false`, so nothing else can leak game sound. cam2 and cam3
  stay muted (no `-Sound`). The pog profile has no Desktop Audio or mic devices, so nothing is doubled.
- Factorio music: `start-client.ps1` now always writes `music-volume=0`; `-Sound` only unmutes the client. A running
  client keeps its old config until it is restarted (`Stop-ScheduledTask`/`Start-ScheduledTask pog-<world>-client-cam1`).
- Ducking: compressor (ratio 6, threshold -42 dB, attack 15 ms, release 700 ms) with sidechain "stream overlay" on
  both the game audio and the music bed: roughly 10-12 dB down while anyone speaks. Agents over casters is done in
  the page (casters to 30%, `?duck=` to change).
- Music slot: "stream music bed" plays `D:\pog\music\bed.mp3` on loop at -24 dB, disabled in the scene until an
  original track is there; enable the scene item when it is.
- Test without touching the stream scene: `$PY tools/obs.py audio-test --url http://HOST:PORT/ [--game-url URL]`
  builds scene "audio-test" with its own overlay source and the same mix. The box reaches the Mac either through the
  reverse tunnel (`ssh -N -R 8787:127.0.0.1:PORT pogwin`) or on the LAN (`serve.py --host 0.0.0.0`; the Mac is
  <mac-ip>). Switch the program scene to it, record a minute with `obs.py start`/`stop`, switch back.

## Knobs

`caster.py`: `--gap 20 40`, `--urgent-gap 8`, `--lull 50`, `--stale 45`, `--agent-gap 15`, `--agent-cooldown 60`,
`--chat-stale 20`, `--max-chars 200`, `--no-chat`, `--writer cf|claude|template`, `--model ID`,
`--tts aura2|aura1|melotts|say|tone`, `--tts-fallback BACKEND`, `--classifier clef|heuristic`, `--backoff 120`,
`--claude-bin PATH`, `--always`, `--dry-run`, `--duration S`. A backend that fails three times in a row is skipped
for `--backoff` seconds: the writer falls back to templates, the classifier to the heuristic, TTS to
`--tts-fallback` (or silence). Verified with Cloudflare unreachable: the cast carried on with templates and the
fallback voice.
Personas, priorities, rules and templates are at the top of `caster.py` (`CASTERS`, `PRIORITY`, `RULES`,
`TemplateWriter.T`). `--push FILE` sends one audio file as a clip (stings, tests).

Overlay URL: `?mute`, `?duck=0.3`, `?caster=0.9`, `?agent=1.0`, `?captions=0`. Captions show who is speaking above
the bottom of the main camera (agents above casters). A desktop browser needs one click to start audio; OBS does not.

OBS levels: `GAME_DB`, `MUSIC_DB`, `DUCK` at the top of the audio section in `tools/obs.py`.

## Harness change needed (eng/board)

`profile` should accept `voice` (one of the ids above, lower case) and return it in `profile` and `profiles`; the
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

## Next

1. Allow `api.cloudflare.com` for the caster and run the two "first checks" above; pick Aura-2 vs Aura-1 by ear,
   confirm each voice's gender/accent, and confirm the Clef `choice` answer shape (`pick_choice` accepts a few).
2. Run `--bench` for writer latency; if Llama 3.3 70B is slower than ~2 s, try `gemma-4-26b-a4b-it` or the 8B model.
3. `obs.py stream-audio`, restart cam1 with `-Sound`, then a one-minute recording in `audio-test` and a listen.
4. The harness `voice` field (above), and an original music bed.
