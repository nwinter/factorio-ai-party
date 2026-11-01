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

`start.log`'s `started: N/M agents` stops after the current line's audible end receipt,
then releases speech, image, captions and camera together. Partial and zero successful
launches use the same boundary. The marker is checked twice a second; a mid-shift service
restart does not replay the recap. If narration finishes first, the page restores the normal
layout and releases speech without repeating the voices. Agent readiness remains controlled
by start-team. A short startup can leave later, unstarted lines unaired.

The capture page that starts an attempt owns its completion, including when reconnecting
to a restarted service without another page-load report. Wrong-session, short, muted and
cancelled ends cannot complete a beat. A playing recap has no wall-duration deadline:
delayed output and delayed end receipts retain its immutable script/media binding and camera.
WebAudio's output latency drains before the end (or cut) receipt. Reload and reconnect retry
the same unfinished beat. Explicit interruption cancels speech but retains the scene and
ownership until the page acknowledges the stop. Phase/deadline changes drain the current line.
Start/end logs contain the line, clip and capture session; public recap state includes `clip`,
and director move logs include the segment's source/phase/beat ID in `target.seg`.

The recommended layout puts the recap over the existing OBS game-camera rectangle,
1208×1032 in landscape and 1032×883 in portrait. The sidebar dims while narration runs;
camera labels and ordinary overlay captions yield. The title has a dark gradient. Captions
use `rgba(9,21,28,.88)` behind warm-white text, with a shadow and gold speaker/accent. Even
against white footage the caption text has approximately 12:1 contrast. Text shrinks to fit
longer record extracts. The rest of the footage stays unobscured.

Each beat prefers a recorded **video** of its named ship/surface whose capture interval
contains the cited record time. A nearer still cannot displace such a clip. Stills stay in
the audit/contact sheet; they never cover gameplay on air. Without a clip, the browser is
transparent over the existing live camera. A subject cue goes through the normal director's
segment-camera path using only existing platform views or agent positions. Operator holds
and urgent shots keep priority; unknown/ambiguous subjects hold the current game camera
through the receipt, suppressing quiet tours and ordinary directing. Resolved recap shots
also retain their framing through delayed/retried narration, without routine pans or an
independent camera hold timeout. The normal `#voice` layer is hidden throughout narration,
including retries and interruption/output drain.
The live label names a subject only from acknowledged compositor state. Capture time and
claim time remain distinct, and live footage explicitly says “earlier shift narrated”.

The browser's muted, looping video element supplies prepared footage; no OBS media source,
scene switch, camera transform or browser-source setup is required. Clips contain no audio.
While loading, on decoder error, or after a 2.5-second stall, the live game remains/reappears
under the captions. A mid-recap reload seeks to `(elapsed + offset) % duration`, keeping
motion through long lines. End, interruption and a completed narration's holding state
release the decoder and restore normal opacity/labels. State continues updating throughout.

`?recap_layout=cinema` enables the full-canvas comparison when a clip is actually playing.
It uses a center crop and loses substantially more of the scene in portrait. Loading or
failed clips return to the existing camera rectangle, since the live OBS camera is not
full canvas. The default translucent layout preserves more gameplay and needs no scene
operations. Changing the comparison switch on a live OBS browser source is an operator
choice at normal deployment, never part of preparation.

`mapframes/*.json` supplies timestamped surface stills. An optional `runs/RUN/recap-media.json`
array can index other **already recorded** local images/clips, for example
`{"path":"archive/lark.webm","t":1793391508,"platform":"Lark","duration":12,"offset":0}` (or `surface`).
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
line durations; Escape restores the normal layout. `?case=clip`, `live`, `transition`,
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
and cap apply to this helper, independently of existing mapframes capture. Prepared
content-addressed copies can add at most another 128 MiB: at most 256 MiB added capture
and prepared-image storage per shift, excluding pre-existing mapframes/audio/archive clips.

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
changed prepared bytes are rejected. Browser decode failures reveal live gameplay
and are exposed per beat in `PogShiftRecap.failures` for headless rehearsal checks.
The offline rehearsal CLI also fully decodes images with Pillow and the first frame of
indexed video with ffmpeg; decode failures are included in both the review and prep log.

To refresh a reviewed script with a recorded or mock-capture run, without model/TTS calls:

```sh
python3 tools/stream/shift_recap_rehearsal.py --manifest SAVED/manifest.json --run-dir RUN --out REPLAY
```

Capture bounds/receipts and media refresh diagnostics are exercised by
`python3 tools/stream/test_recap_capture.py`. Operator verification uses the actual exported
overlay and `tools/stream/overlay_shot.sh`, plus browser reload and restoration checks.

## Preparing gameplay cuts

`replays.py` is the existing on-air precedent: it plays a muted program recording through
an OBS media source in a separate replay scene, carrying the live overlay off canvas for
voices. Its `-game.mkv` companion copies the **same composed video** with audio stream 2;
“game” describes the audio, not clean video. The full shift MKVs and Replay MKVs contain
program overlays. For recaps, crop a reviewed camera rectangle at preparation time to
avoid old sidebar/chat/subtitles; never replay the complete program inside the overlay.
Check the entire cut for scene changes, inset overlays and source labels. A replay's event
label does not establish which camera its whole buffer actually shows.

`recap_footage.py --recipe RECIPE.json --run-dir RUN` is a dry run. Add `--apply` to cut on
the Mac from a local completed recording or saved replay. It never calls OBS, the game or
a remote host, and never starts/restarts a service. Each recipe entry supplies:

```json
{"clips":[{"source":"/absolute/path/to/finished.mkv","offset":30,"duration":12,
 "t":1793544519.5,"subject":"Asterion","subject_type":"platform",
 "crop":[24,144,1208,864],
 "coverage":{"reviewed":true,"start":1793544519,"end":1793544534,
 "evidence":"reference to verified subject coverage throughout this interval",
 "clock_anchor":"verified recording/record epoch alignment; include uncertainty"}}]}
```

The numbers are a schema example, not a recipe to apply to another file. Do not derive UTC
from the Windows filename or mtime: the batch404 sample had a one-hour clock discrepancy.
Use explicit recording-start receipts or visually aligned events plus director receipts,
and disclose uncertainty. A subject-camera request alone is not proof of recorded pixels.

The cut is 1024px wide, 24 fps VP9 WebM (`yuv420p`), with `-an -sn -dn`, two encoder threads,
real-time preset and CRF 34. This decodes in OBS's browser and headless Chromium. A 12-second
1920×1080 HEVC replay sample took 3.43 seconds on the Mac including validation and made a
4,000,149-byte clip. This is one measurement, not a worst-case guarantee. Bounds: 16 cuts
per invocation, 20 seconds/16 MiB per clip, 256 MiB in `recap-clips/` per shift, 120-second
encoder timeout. Prepared content-addressed copies add at most another 256 MiB for those
clips. Existing still-capture budgets remain separate. Source size/mtime enter the cache
key, changed sources are rejected, complete silent output is probed and decoded, and the
index is atomically merged under the capture helper's lock. Failed prep leaves the prior
index intact. Missing or failed media always takes the live route.

Copy a saved replay to the Mac with `scp`, then run the recipe; only a few dozen MB need
cross the network. Whole four-hour recordings in the inspected listing were 21.2–23.3 GB.
For those, ffmpeg/ffprobe are also installed on pogwin via WinGet. The operator can run the
same emitted ffmpeg argument list there against `D:/pog/recordings/...`, substituting a
new scratch output path, then copy the small silent WebM back. The Mac helper's emitted
command uses an explicit seek before the input and a bounded duration; it does not decode
four hours. Windows cutting/CPU time was not measured on the streaming machine. Never
overwrite a recording or run an encoder from the live ticker. The Mac route avoids adding
encoding contention to OBS; a whole-recording copy trades local/network disk cost for that
isolation. Imported cuts must still carry reviewed capture-time and subject metadata in
`recap-media.json`, including `duration`, and pass rehearsal decoding.

After cutting, `shift_recap_rehearsal.py --manifest SAVED/manifest.json --run-dir RUN --out
REPLAY` rebinds the saved script without model or voice generation. Normal service media
refresh ingests the index at preparation/startup. `media_review` reports separate clip and
live-fallback counts. `--backdrop SILENT.webm --snapshot SAVED_STATE.json` supplies an
explicit, watermarked offline stand-in for OBS underneath the real exported pages; it is
never added to production markup. Use `recap_footage_browser.mjs` for decode advancement,
muting, failure fallback, elapsed-time reload, every caption's fit, completion and restore.

## Operator-only voice isolation

Batch403 owns all browser speech during a recap. For literal voice-only program audio,
`recap_audio_guard.py` is a separate operator-run script: by default it only prints a dry
run of active, unmuted track-1 inputs other than `stream overlay`. `--apply` watches the
existing state endpoint; it writes the original mute states to `--receipt` **before**
muting anything. Narration completion, interruption, Ctrl-C or a service-read failure
restores those exact states. `--undo --receipt FILE` recovers after a crash; a pending
receipt refuses a second watcher. Track-2-only clean recording audio is excluded. There
are no scene/source creation, recording or stream-control calls. Only the operator starts
this guard; it is not started by the service or by preparation. Do not run two guards.

```sh
python3 tools/stream/recap_audio_guard.py --receipt /absolute/operator/recap-audio-undo.json
python3 tools/stream/recap_audio_guard.py --receipt /absolute/operator/recap-audio-undo.json --apply
python3 tools/stream/recap_audio_guard.py --receipt /absolute/operator/recap-audio-undo.json --undo
```

The batch404 read-only dry run selected `stream cam1` and `stream game audio`. The apply,
partial-failure receipt and undo paths are tested exclusively against an OBS stub. Without
the guard, prepared clips are still silent and other speech is held, but ordinary live
game ambience remains in the program mix.
