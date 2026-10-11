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
| Canvas | Named "Aitum Vertical", default 1080x1920, created through OBS's canvas API, so `GetCanvasList` lists it. Frame rate is OBS's (60). |
| Websocket | Vendor `aitum-vertical-canvas`. Requests: `version`, `get_scenes`, `current_scene`, `switch_scene` {scene}, `status`, `start_streaming`, `stop_streaming`, `toggle_streaming`, `update_stream_server` {stream_server, index}, `update_stream_key` {stream_key, index}, recording/backtrack/virtual-camera start/stop, `add_chapter`, `pause_recording`. Most take `width`/`height` to pick the canvas. Events: `streaming_starting`, `streaming_started`, `streaming_stopping`, `streaming_stopped` (with `code`, `last_error`). obs-websocket 5.7.4 takes `canvasUuid` on `CreateScene`, `CreateSceneItem`, `GetSceneItemList`, `SetSceneItemTransform`, `SetSceneItemIndex` and `GetSourceScreenshot`, so a scene in the plugin's canvas can be built by script. There is no request for the plugin's bitrate or encoder: those are set once in its settings dialog. |
| Settings dialog | Vertical dock, gear: **General** (Resolution), **Streaming** (Enabled / Name / Server / Key per output; Video Bitrate, default 6000 Kbps; "Start and stop streaming when main OBS starts and stops streaming"; "Use main OBS settings", which when off shows Audio Track and Video Encoder), Recording, Backtrack. |
| Risks | 1.6.6 is five days old (it changes only the update URL over 1.6.5, itself six days old). Forum users reported after OBS 32.0 that websocket control of vertical scenes broke and that long streams through the plugin's outputs dropped; both are anecdotes from before 1.6.3-1.6.5, not reproduced. The 10-minute test below is the check. Fallback: 1.6.4 (same URLs with `1.6.4`, five months old). |

## Steps for the operator (after Nick's game; the box free)

Times are rough. Nothing here changes the `pog` profile's own outputs or the "stream" scene.

1. **Close OBS** on the box desktop (File > Exit, so it shuts down cleanly and does not offer safe mode next
   start). Stop the replay buffer first if a run is not on: nothing should be live.
2. **Install** (from the repo root on the Mac, ~1 min):
   ```sh
   git pull   # this branch, eng/stream2 (or main once merged)
   tools/winps.sh tools/win/install-aitum-vertical.ps1
   ```
   It downloads to `D:\pog\installers`, refuses a wrong SHA-256 or a running OBS, installs silently and prints the
   installer's exit code and the files it wrote. Exit code 0 and lines under `obs-plugins\64bit\vertical-canvas.dll`
   mean done. (By hand instead: download the URL above, check `Get-FileHash`, run it with the flags above.)
3. **Start OBS** on the box desktop as usual (profile and scene collection `pog`). A "Vertical" dock appears; if
   the plugin asks about updates, answer no. Open the dock's gear once: General, Resolution `1080x1920`.
4. **Plugin output settings** (gear, Streaming), once:
   - untick "Use main OBS settings"; Video Encoder: **QuickSync H.264** (the landscape stream's encoder), rate
     control **CBR**, keyframe interval **2 s**, Audio Track **1** (the landscape stream's track);
   - Video Bitrate **6000** Kbps (as landscape; upload total about 12.5 Mbps with audio);
   - tick "Start and stop streaming when main OBS starts and stops streaming";
   - leave Server and Key for step 6.
5. **Scene** (Mac, tunnel up as for `tools/obs.py`, ~10 s):
   ```sh
   tools/tunnel.sh 4455      # if not already up
   tools/.venv/bin/python tools/vertical.py check     # versions, the "Aitum Vertical" canvas, plugin scenes
   tools/.venv/bin/python tools/vertical.py scene     # builds "stream vertical", switches the plugin to it
   tools/.venv/bin/python tools/vertical.py shot vertical.png   # look at it
   ```
   The reverse tunnel for the overlay (8787 on the box) must be up, as for the landscape overlay. The scene's
   `/portrait` browser source is muted on purpose: the landscape overlay carries the voices, and OBS's mix feeds
   both outputs. If `scene` stops with "no canvas named 'Aitum Vertical'", open the Vertical dock once and rerun.
6. **Key** (after Nick's YouTube Studio steps below give a second key):
   ```sh
   printf '%s\n' 'THE-VERTICAL-KEY' > ~/.config/pog/youtube-vertical.key; chmod 600 ~/.config/pog/youtube-vertical.key
   tools/.venv/bin/python tools/vertical.py key       # sets output 1's server (RTMPS) and key through the plugin
   ```
   If the plugin answers that output 0 does not exist, type the server `rtmps://a.rtmps.youtube.com:443/live2` and
   the key into the dock's Streaming settings instead.
7. **Test, unlisted, 10 minutes** (with a world and the stream service running, e.g. world live):
   - YouTube Studio: set up dual stream for the test broadcast (below), visibility unlisted;
   - `tools/.venv/bin/python tools/obs.py stream-start` (starts both through "match main");
     `tools/.venv/bin/python tools/vertical.py status` should show `"streaming": true`;
   - in the Live Control Room both previews should be live; on a phone, the vertical one;
   - every 30 s `/replays.json` has OBS's stats: `skipped_since_last` (render and output frames) and CPU, as for
     shake3's sample (0 skipped, 10.7% CPU with stream + recording + buffer);
     `tools/.venv/bin/python tools/obs.py stream-status` gives the landscape output's skipped frames;
   - `tools/.venv/bin/python tools/obs.py stream-stop`, then `vertical.py status` shows `"streaming": false`.
   If frames are skipped, lower the vertical bitrate to 4500 first; the canvas stays 1080x1920 because the page and
   its camera holes are laid out for it.
8. From then on a team run with `--stream` streams both; nothing in `start-team.sh` changes. Undo: untick "match
   main", or uninstall "Aitum Vertical" from Windows' installed apps with OBS closed.

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

- The vertical scene has not been seen in OBS: `/portrait` was checked in jsdom only, and the plugin's canvas has not
  existed yet. `vertical.py` is tested against a fake websocket (`tools/test_vertical.py`); `vertical.py check` is
  the first real contact.
- During a landscape replay the vertical feed keeps the live cameras (replays switch only the main program).
- Whether inputs from the main canvas can be added to a scene of the plugin's canvas by `CreateSceneItem`: the
  plugin's own Sources dock does this, and OBS's inputs are global, so it should; if not, `vertical.py scene` stops
  at the first camera and the three captures are added by hand from the Vertical dock (Add > Existing).
- Encoder headroom for a second 1080p60 encode next to stream, recording and replay buffer: one sample so far.

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
