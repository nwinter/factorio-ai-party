# Shift-change recap

`serve.py` prepares a recap from the run's recorded files three hours after `stream.json`'s
`shift.start` (or two minutes before the deadline for a shorter shift). This is enabled for
real runs with shift metadata; `"shift_recap": false` in the run config disables it.
The worker receives copies of existing stream observations once a minute in
`runs/RUN/recap-record.jsonl`: the full board snapshot, plans, alerts, research, fleet and
analyst notes. It issues no harness, camera, OBS or feed requests.

`shift_recap.py` gathers the current shift's chronicle, first departures/arrivals supported
by its creation history, research, losses, score boundaries, plans, board reads in agent
journals, tells, chat, saved stills and analyst notes. It reads the entire predecessor chain
to deduplicate carried events and distinguish a first from a repeat. An unknown ship's
first sighting is not called its first flight. Chat, plans and assessments stay attributed;
missing evidence is listed in `manifest.json`'s coverage counts.

The normal preparation uses the existing hourly model route (OpenRouter, Opus by default;
`POG_RECAP_MODEL` overrides it) to write Rook/Vale exchanges and then review their entailment
against the records. Names, causes, attribution and final-state claims are reviewed; numbers
and clock strings also pass exact source checks in code. Digit and written-out numbers are
compared by exact value (including grouped digits and recorded shorthand such as `sixMIL`);
clock components never license unrelated quantities. Numbers elsewhere in the record do
not excuse a missing citation. The research selection samples the whole recorded interval.

Every raw draft is saved before checking in immutable `audit/draft-*.json` files, alongside
the full model input, exact rejected claim, line/title, offending number, cited rows, possible
uncited numerical matches, and the separate model review. `review.md` makes refusals readable.
The evidence reviewer returns a verdict for each indexed line. A refusal removes only that
line; valid narrative survives even if a second draft also has a bad claim. Extracts are used
only when there is no reviewed narrative (or no writer). They admit readable chat, chronicle,
firsts/losses and research; tells, board entries, plans and compressed text cannot be voiced
as extracts. Headlines are classified from their content: a rocket launch is a milestone. Record
text is data, never model instructions. No external research or additional game reads run.

Files live in `runs/RUN/shift-recap/`: `manifest.json`, content-addressed audio and recorded
stills under `assets/`, `script.md`, `cards.html`, and both `onair-*.html` rehearsal pages.
TTS uses the same Rook/Vale roles and backend routing as the casters (`POG_RECAP_TTS`, default
`auto`). The manifest is replaced atomically only after assets are written. A file lock
serializes competing preparations; a late early pass cannot overwrite a final one.

Prepared speech and transitions pass the spoken-content check described in `tour-FORMAT.md`: unprompted
Whisper transcription, normalized word error, extra leading/trailing speech and duration against characters.
`audio-checks.jsonl` records every attempt. One exact-script retry without direction is allowed; a second
failure removes that line from the prepared sequence. Cache receipts bind script and audio SHA-256 hashes.
Old manifests are checked/rebuilt during preparation, including a successor finishing the previous shift;
the player refuses unchecked or changed audio. This adds no transcription calls to live host lines.

At the deadline a bounded extract pass adds the closing developments without model latency.
The next service finishes that pass if the previous one was stopped during it. It also
includes the interval through `stopped.json.stop_utc` when the actual stop followed the
scheduled deadline. Refreshes replace the coda, retaining the original early script/audio.

The transition airs 35 seconds before the scheduled deadline. On the next run, playback
follows `resumed-from` and reads only the predecessor's prepared files. It works before a
game observation or caster process is available. It waits for the capture page, posts one
timed clip at a time, and keeps each card up until the clip's completion receipt. Skips,
errors and lost pages retry the unfinished line; successful lines survive restarts in
`shift-recap-recap-played.json` and tagged `audio-played.jsonl` receipts. Routine segments
and the live caster writer yield. The normal page audio queue holds routine speech.

`start.log`'s `started: N/M agents` ends playback, cancels any current clip, releases the
audio hold and removes the recap card. Partial and zero successful launches use the same
boundary. The marker is checked twice a second; a mid-shift service restart does not replay
the recap. If narration finishes first, the page restores the normal layout; the audio hold
remains without repeating the voices until the marker appears. Agent readiness is controlled by start-team, not by
the recap. A short startup can end a longer script before all lines air.

The recap and transition cover the entire broadcast canvas, including cameras and sidebar,
at 1920×1080 and 1080×1920. Each beat shows a short headline, speaker, record time and the
spoken caption. Imagery occupies a dedicated 1856×662 field (59.25% of 1920×1080) or
1032×1238 field (61.61% of 1080×1920), including its one-pixel border. Images fill that
field with a centered crop (`object-fit: cover`); the original uncropped files remain in
the audit assets. Captions sit below the image. Its capture time and Wube credit are separate
from the claim's record time. The page binds by ship/surface and nearest recorded time,
never by rotating an unrelated still. Ship names take precedence over their dock/route;
ambiguous subjects and missing or failed media get a neutral card. Source paths, row IDs,
binding reasons and the full timeline stay in the offline manifest/script/contact sheet.

Normal layout keeps receiving snapshots beneath the opaque recap layer. Completion,
interruption and an ended state after page reload restore it. A mid-recap reload renders the
current service beat; a recorded clip seeks to its elapsed time and stays muted beneath the
casters. The recap renderer runs before agent-dependent renderers, including when the service
has no agents snapshot yet. No OBS scene change is needed. The operator deploys/restarts the
service through the normal shift start.

`mapframes/*.json` supplies timestamped surface stills. An optional `runs/RUN/recap-media.json`
array can index other **already recorded** local images/clips, for example
`{"path":"archive/lark.webm","t":1793391508,"platform":"Lark","offset":0}` (or `surface`).
It must name an existing file inside that run, a capture time inside the recorded shift and
a subject. Accepted formats are WebP/PNG/JPEG/MP4/WebM. The prep reader makes no capture, remux, OBS request or
filename/mtime inference. Content-addressed copies and bindings survive service restarts.

Offline rehearsal (no service, game or OBS):

```sh
python3 tools/stream/shift_recap.py rehearse --run-dir runs/shift104 --out /tmp/recap104 --offline
```

Omit `--offline` to use the record-only narrative model and evidence review. `--tts none`
(the CLI default) renders script and cards only; `--tts say`/`tone` is local, and `auto`
uses the configured voice providers. `--logs tools/stream/logs` includes available legacy
analyst logs. `--until EPOCH` sets a reproducible record boundary. The rehearsal retains
`early-manifest.json`; arrow keys browse the two on-air HTML previews, or `?step=N` selects
a zero-based beat (transition followed by recap). Space or `?play=1` advances at prepared
line durations; Escape restores the normal layout. `?case=still`, `neutral`, `transition`,
`restore`, `early`, `interrupted` and `holding` select the corresponding checks. These are
the actual page markup, CSS and renderers with file-only state delivery and no audio. Early
startup supplies only `shift_recap`; restore uses an empty pre-observation Model, not a fake
world. The normal layout's remote font import is omitted so the rehearsal stays offline.

To rehearse a saved, reviewed manifest without rewriting its script:

```sh
python3 tools/stream/shift_recap_rehearsal.py --manifest OUT/manifest.json --out REPLAY
```

`python3 tools/stream/test_shift_recap.py` and `test_shift_recap_visuals.py` use stub records/audio
and never need the game, model credentials, the current clock or a live service.

## Automatic recorded imagery

`start-team.sh` starts `tools/stream/recap_capture.py RUN` beside the service when OBS is
allowed (`POG_OBS!=0`, `POG_RECAP_CAPTURE!=0`). It polls existing `state.json` every two
seconds. Only fresh service state with matching acknowledged/on-air director shots and
a connected compositor licenses a capture. The shot must have settled for three seconds;
a post-capture receipt must still identify the same camera, shot, surface and subject.
Host/show/replay/recap coverage, pending cameras and GUI panel slots are excluded. A named
ship wins over its dock; unnamed platform surfaces are not labelled as planets. No game
read or additional Factorio client is used.

The sole OBS request is read-only `GetSourceScreenshot` of `stream cam1/2/3`, never a scene:
1280px JPEG, quality 80. Maximum one attempt per 60 wall seconds across the shift and one
saved frame per subject per 300 seconds, including helper restarts. Automatic request
retry is disabled. A shift has a hard 128 MiB budget for `recap-frames/` plus its media
index (with room reserved for atomic index replacement); a response is capped at 2 MiB.
At the cap it stops requesting screenshots, preserving recorded evidence. The interval
and cap apply to this helper, independently of existing mapframes capture.

The helper stores capture start/end times, subject/type, surface/platform, camera source,
source dimensions, byte count, and the before/after receipts with tick and state time.
The atomic `recap-media.json` index is published after the JPEG. `recap-frames/status.json`
retains the last attempt, its elapsed milliseconds and any failure; `recap-capture.log`
records changes. The helper is included in start-team's normal PID/health lifecycle.

Preparation refreshes media independently of script/audio. A file-only worker checks once
per minute after preparation, and before a successor starts playback, including old final
manifests. Indexed-file and prepared-file arrival, replacement or deletion triggers new
bindings. Later captures in the same shift can illustrate an earlier beat; claim time
and capture time remain distinct. The nearest subject frame wins; an unnamed surface
beat may use the surface explicitly named by its cited record. No unrelated filler is used.

`manifest.json.media_review`, `review.md` and `prep.log` flag `NO BOUND MEDIA` and list each
missing/failed beat, its subject and asset diagnostics. Empty, missing, invalid-image and
changed prepared bytes are rejected. Browser decode failures fall back to neutral cards
and are exposed per beat in `PogShiftRecap.failures` for headless rehearsal checks.

To refresh a reviewed script with a recorded or mock-capture run, without model/TTS calls:

```sh
python3 tools/stream/shift_recap_rehearsal.py --manifest SAVED/manifest.json --run-dir RUN --out REPLAY
```

Capture bounds/receipts and media refresh diagnostics are exercised by
`python3 tools/stream/test_recap_capture.py`. Operator verification uses the actual exported
overlay and `tools/stream/overlay_shot.sh`, plus browser reload and restoration checks.
