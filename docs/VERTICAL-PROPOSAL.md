# Vertical (9:16) stream for YouTube: install and setup

For the operator. Branch eng/stream2, 2026-10-11 (researched on the web 08:40-09:10 PDT; nothing on the box was
touched). Nick approved installing Aitum Vertical and wants a designed portrait stream: our `/portrait` page over the
three director cameras, not YouTube's centre crop.

## The plan in one paragraph

YouTube now takes a horizontal and a vertical feed from an encoder as **one broadcast** ("Dual stream"): one watch
page, one chat, one notification; phones in the Shorts feed get the vertical feed, everyone else the horizontal one.
The vertical feed goes to a **second stream key** chosen in the Live Control Room. On the box, Aitum Vertical 1.6.6
adds a 1080x1920 canvas with its own scenes and its own RTMP output. `tools/vertical.py` builds the scene in that
canvas (the three existing director captures plus `/portrait` on top) and sets the output's key; the plugin's
"start and stop with main" option makes `tools/obs.py stream-start` (and `start-team.sh --stream`) start both feeds.

## YouTube: what it needs (YouTube Help, "Get started with live streaming", desktop)

- Dual stream is on by default for streams started from the Live Control Room; by default the vertical feed is
  YouTube's centre crop of the horizontal one (its other auto layouts: "Fit to phone width", "Stacked").
- To send our own vertical feed: Live Control Room, **Stream** tab, in the vertical preview change **Auto** to
  **Encoder**, use the **RTMP(S)** protocol, and pick a **second stream key** in the **Stream key** dropdown for the
  vertical feed. Then go live.
- It is one broadcast with two formats: one URL, one chat, combined metrics in the Live Control Room; vertical-only
  metrics appear 24 hours after the stream.
- The vertical format **cannot be added after the stream has started**: set it up before going live.
- Eligibility: a verified channel, no live streaming restrictions in the last 90 days, owner at least 16.
- Turning it off: Stream tab, **Stream settings**, **Dual stream** off.
- YouTube's help page gives no resolution or bitrate for the vertical feed. Third-party guides suggest treating it
  as another 1080p feed: H.264, CBR, 2 s keyframes, 1080x1920. Our landscape feed is Quick Sync H.264 at 6 Mbps
  over `rtmps://a.rtmps.youtube.com:443/live2` (docs/SETUP.md); the vertical one uses the same.
- Not needed: OBS's "Multitrack video" (Enhanced Broadcasting). Aitum Vertical can be its extra canvas, but that is
  Twitch's dual format; YouTube's takes a second RTMP(S) feed.

## Aitum Vertical: the release and what it installs

| | |
|---|---|
| Version | 1.6.6, released 2026-10-06 ("Fix update download url"; 1.6.5 on 2026-10-05 fixed a shutdown crash and scene-order loading). Previous: 1.6.4, 2026-05-21. |
| OBS | 1.6.0+ needs OBS 31.1 or newer; its installer refuses an OBS major below 31. 1.6.3 fixed edit-transform for OBS 32.1. The box has OBS 32.2.2, obs-websocket 5.7.4. |
| Download | `https://github.com/Aitum/obs-vertical-canvas/releases/download/1.6.6/vertical-canvas-windows-installer.exe` (3,910,392 bytes, SHA-256 `01a81d1ea7489062ba51cc92a980b6870498a213fdd872d59a697a8136ce1fd8` per GitHub's API). Also on the release: `vertical-canvas-windows.zip` (files for the OBS folder) and `vertical-canvas-windows-programdata.zip` (for `C:\ProgramData\obs-studio\plugins`). |
| Installer | Inno Setup (`cmake/windows/resources/installer-Windows.iss.in`): finds OBS from the registry, else `C:\Program Files\obs-studio`, checks `bin\64bit\obs64.exe` is version 31+. Silent: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="file"`. |
| Config | The plugin's settings (canvas size, outputs with server and key, bitrate, encoder, audio track, "match main") are in `%APPDATA%\obs-studio\plugin_config\vertical-canvas\config.json` (`obs_module_config_path("config.json")`, module `vertical-canvas`). Its scenes are OBS canvas scenes in the scene collection (`pog`), with the plugin's order in each scene's settings. The stream key sits in that config.json in plain text, as OBS's own key does in the profile. |
| Canvas | Named "Aitum Vertical", default 1080x1920, created through OBS's canvas API, so `GetCanvasList` lists it. Frame rate is OBS's: on the box 30 fps (the main canvas outputs 1280x720 at 30 fps). |
| Websocket | Vendor `aitum-vertical-canvas`. Requests: `version`, `get_scenes`, `current_scene`, `switch_scene` {scene}, `status`, `start_streaming`, `stop_streaming`, `toggle_streaming`, `update_stream_server` {stream_server, index}, `update_stream_key` {stream_key, index}, recording/backtrack/virtual-camera start/stop, `add_chapter`, `pause_recording`. Most take `width`/`height` to pick the canvas. Events: `streaming_starting`, `streaming_started`, `streaming_stopping`, `streaming_stopped` (with `code`, `last_error`). obs-websocket 5.7.4 takes `canvasUuid` on `CreateScene`, `CreateSceneItem`, `GetSceneItemList`, `SetSceneItemTransform`, `SetSceneItemIndex` and `GetSourceScreenshot`, so a scene in the plugin's canvas can be built by script. There is no request for the plugin's bitrate or encoder: those are set once in its settings dialog. |
| Settings dialog | Vertical dock, gear: **General** (Resolution), **Streaming** (Enabled / Name / Server / Key per output; Video Bitrate, default 6000 Kbps; "Start and stop streaming when main OBS starts and stops streaming"; "Use main OBS settings", which when off shows Audio Track and Video Encoder), Recording, Backtrack. |
| Risks | 1.6.6 is five days old (it changes only the update URL over 1.6.5, itself six days old). Forum users reported after OBS 32.0 that websocket control of vertical scenes broke and that long streams through the plugin's outputs dropped; both are anecdotes from before 1.6.3-1.6.5, not reproduced. The 10-minute test below is the check. Fallback: 1.6.4 (same URLs with `1.6.4`, five months old). |

## Steps for the operator

Nothing here changes the `pog` profile's own outputs or the "stream" scene.

Done 2026-10-11 (operator): steps 1 to 3 and 5. Aitum Vertical 1.6.6 installed (exit 0), OBS restarted,
`vertical.py check` shows the "Aitum Vertical" canvas (1080x1920, 30 fps), plugin 1.6.6 and its default "Vertical
Scene"; `vertical.py scene` built "stream vertical". Until step 4 runs the plugin has no output and "start and stop
with main" is off (the plugin's defaults with no config file), so a streamed run is unchanged except for rendering
the vertical canvas.

1. **Close OBS** on the box desktop (File > Exit, so it shuts down cleanly and does not offer safe mode next
   start). Nothing should be live.
2. **Install** (from the repo root on the Mac, ~1 min): `tools/winps.sh tools/win/install-aitum-vertical.ps1`.
   It downloads to `D:\pog\installers`, refuses a wrong SHA-256 or a running OBS, installs silently and prints the
   installer's exit code and the files it wrote.
3. **Start OBS** on the box desktop as usual (profile and scene collection `pog`).
4. **Plugin output settings, without the GUI** (Mac, OBS closed on the box, between shifts, ~10 s):
   ```sh
   printf '%s\n' 'THE-VERTICAL-KEY' > ~/.config/pog/youtube-vertical.key; chmod 600 ~/.config/pog/youtube-vertical.key
   tools/.venv/bin/python tools/vertical.py settings --dry-run   # what it would set; reads the box's config only
   tools/.venv/bin/python tools/vertical.py settings             # writes it (a dated copy of the old one stays)
   ```
   `settings` refuses while `obs64.exe` runs (the plugin rewrites its `config.json` when OBS exits, so an edit made
   while OBS runs is lost). It copies `%APPDATA%\obs-studio\plugin_config\vertical-canvas\config.json` from the box,
   sets the 1080x1920 canvas's entry, keeps a copy there as `config.json.pog-YYYYMMDD-HHMMSS` and copies it back:

   | key in the canvas entry | value | meaning (vertical-canvas.cpp 1.6.6) |
   |---|---|---|
   | `stream_advanced_settings` | `true` | "Use main OBS settings" unticked: the encoder below is used as set |
   | `stream_encoder` | `obs_qsv11_v2` | Quick Sync H.264, the landscape stream's encoder |
   | `stream_encoder_settings` | `{"rate_control": "CBR", "bitrate": 6000, "max_bitrate": 6000, "keyint_sec": 2}` | passed to the encoder as they are (obs-qsv11's keys; `keyint_sec` 0 would be the encoder's own default) |
   | `streaming_video_bitrate` | `6000` | what the dialog shows (used by the plugin only with main settings) |
   | `stream_audio_track` | `1` | mixer track 1, the landscape stream's |
   | `stream_outputs[0]` | `{"name": "YouTube vertical", "stream_server": "rtmps://a.rtmps.youtube.com:443/live2", "stream_key": KEY, "enabled": true}` | the RTMP(S) output; enabled only with a server and a key |
   | `streaming_match_main` | `true` only if that output is enabled | starts and stops the vertical feed with the main stream |

   Everything else in the file (scenes order, transitions, hotkeys, recording) is kept. Options: `--bitrate`,
   `--keyint`, `--track`, `--encoder`, `--server`, `--key-file`, `--no-match-main`. Without a key file it sets the
   encoder and leaves the output disabled and "match main" off: with "match main" on and no enabled output, 1.6.6
   opens a modal "No output server" dialog on the box every time the main stream starts.
   The file exists only after OBS has exited once since the install (`settings` says so if it is missing).
   Rotating the key later: the same command with the new key file, OBS closed. (`vertical.py key` changes the
   key of an existing output live, but cannot create or enable one: on a fresh install it does nothing and the
   plugin still answers success.)
5. **Scene** (Mac, tunnel up as for `tools/obs.py`): `vertical.py check`, `vertical.py scene`, `vertical.py shot
   vertical.png`. The `/portrait` browser source is muted on purpose: the landscape overlay carries the voices, and
   OBS's mix feeds both outputs.
6. **Test, unlisted, 10 minutes** (with a world and the stream service running, e.g. world live; after Nick's YouTube
   Studio answers below):
   - YouTube Studio: set up dual stream for the test broadcast (below), visibility unlisted;
   - `tools/.venv/bin/python tools/obs.py stream-start` (starts both through "match main");
     `tools/.venv/bin/python tools/vertical.py status` should show `"streaming": true`;
   - in the Live Control Room both previews should be live; on a phone, the vertical one;
   - every 30 s `/replays.json` has OBS's stats: `skipped_since_last` (render and output frames), CPU and render ms;
     `tools/.venv/bin/python tools/obs.py stream-status` gives the landscape output's skipped frames;
   - `tools/.venv/bin/python tools/obs.py stream-stop`, then `vertical.py status` shows `"streaming": false`.
   If frames are skipped, lower the vertical bitrate (`settings --bitrate 4500`, OBS closed) first; the canvas stays
   1080x1920 because the page and its camera holes are laid out for it.
7. From then on a team run with `--stream` streams both; nothing in `start-team.sh` changes. Undo:
   `vertical.py settings --no-match-main` (OBS closed), or uninstall "Aitum Vertical" with OBS closed.

## Questions for Nick in YouTube Studio

1. **Is Dual stream offered on the channel?** Live Control Room, Stream tab: is there a vertical preview with an
   **Auto / Encoder** choice, and under Stream settings a **Dual stream** toggle? (It needs a verified channel and no
   live restrictions in 90 days.)
2. **Which broadcast do the runs use?** The default "Stream now" stream key, or scheduled events? Dual stream is
   set per stream in the Stream tab and cannot be added once live, so it has to be set before each run's
   `stream-start`, or on the reusable default stream if YouTube keeps it there.
3. **Create the second stream key** in that dropdown ("Create new stream key"): protocol **RTMP(S)**, a name like
   "pog vertical", and send it to the operator for `~/.config/pog/youtube-vertical.key` (never in a commit or chat).
   Keep the landscape key as the horizontal one.
4. **Encoder for vertical:** choose **Encoder** (our designed feed) rather than Auto (centre crop). Leave the auto
   layout options unused.
5. **Visibility and Shorts:** the same as the horizontal (unlisted for tests). Is the live allowed to surface in the
   Shorts feed (that is where the vertical feed is seen)?
6. **Upload:** is about 12.5 Mbps up from the box fine for both feeds (6 + 6 Mbps video + audio)? Otherwise the
   vertical drops to 4.5 Mbps.

## Not covered yet

- The vertical scene has been built on the box but not looked at: one `vertical.py shot` during a run is the next
  check (the director captures and `/portrait` only render with the clients and the stream service up).
- `vertical.py settings` is tested against stand-in ssh/scp and a config shaped like the plugin's `SaveSettings`
  output, not the box's real file; the `--dry-run` against the box is the first contact.
- During a landscape replay the vertical feed keeps the live cameras (replays switch only the main program).
- Encoder headroom for a second encode (1080x1920 at 30 fps, 6 Mbps) next to stream, recording and replay buffer: one
  sample so far, without it.

## Sources

- YouTube Help, "Get started with live streaming" (desktop): https://support.google.com/youtube/answer/2474026
- Aitum Vertical releases and assets (GitHub API): https://github.com/Aitum/obs-vertical-canvas/releases/tag/1.6.6
- Plugin source at 1.6.6: `vertical-canvas.cpp` (vendor requests, config keys), `config-dialog.cpp`,
  `data/locale/en-US.ini`, `cmake/windows/resources/installer-Windows.iss.in`, `buildspec.json`.
- OBS forum resource page and thread (version history, OBS 32 reports):
  https://obsproject.com/forum/resources/aitum-vertical.1715/
- obs-websocket 5.7.4 protocol (canvasUuid fields):
  https://github.com/obsproject/obs-websocket/blob/5.7.4/docs/generated/protocol.md
- Third-party dual-stream guides (bitrate suggestions only): https://streamups.com/blog/how-to-dual-stream-youtube-desktop-mobile
