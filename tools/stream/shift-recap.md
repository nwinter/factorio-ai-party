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
and clock strings also pass exact source checks in code. A failed draft gets one retry;
missing credentials or a failed review falls back to attributed record extracts. Record
text is data, never model instructions. No external research or additional game reads run.

Files live in `runs/RUN/shift-recap/`: `manifest.json`, content-addressed audio and recorded
stills under `assets/`, `script.md`, `cards.html`, and both `onair-*.html` rehearsal pages.
TTS uses the same Rook/Vale roles and backend routing as the casters (`POG_RECAP_TTS`, default
`auto`). The manifest is replaced atomically only after assets are written. A file lock
serializes competing preparations; a late early pass cannot overwrite a final one.

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
the recap. If narration finishes first, its final card/timeline stays up without repeating
the voices until the marker appears. Agent readiness is controlled by start-team, not by
the recap. A short startup can end a longer script before all lines air.

The on-air cards use the same recorded script, source clocks and still captions as the
offline export. Stills remain explicitly labelled archival images; game graphics carry
Wube's credit. The timeline comes from recorded milestones, losses and research. No OBS
scene change is needed. These changes take effect only when the operator deploys/restarts
the service through the normal shift start.

Offline rehearsal (no service, game or OBS):

```sh
python3 tools/stream/shift_recap.py rehearse --run-dir runs/shift104 --out /tmp/recap104 --offline
```

Omit `--offline` to use the record-only narrative model and evidence review. `--tts none`
(the CLI default) renders script and cards only; `--tts say`/`tone` is local, and `auto`
uses the configured voice providers. `--logs tools/stream/logs` includes available legacy
analyst logs. `--until EPOCH` sets a reproducible record boundary. The rehearsal retains
`early-manifest.json`; arrow keys browse the two on-air HTML previews, or `?card=N` selects
a zero-based card. `python3 tools/stream/test_shift_recap.py` uses stub records/audio and
never needs the game, model credentials, the current clock or a live service.
