# A sharper landscape stream: 1080p

For the operator, 2026-10-11 (branch eng/stream2; written during shake7, nothing on the box touched). Today the
landscape feed is the 1920x1080 canvas scaled to 1280x720 at 30 fps, Quick Sync H.264 at 6 Mbps; the vertical feed
is Aitum Vertical's 1080x1920 canvas, Quick Sync H.264 at 6 Mbps (`tools/vertical.py settings`).

## Recommendation

1. Output 1920x1080 at 30 fps (no scaling: the overlay page and `layout.json` are drawn at 1920x1080, so today
   every caption, card and the main camera are shrunk to two thirds and then compressed).
2. Landscape encoder NVENC H.264 on the RTX 2070 Super at 12 Mbps CBR, 2 s keyframes. Keep the vertical on Quick
   Sync at 6 Mbps, so the two feeds use different encoder chips. If NVENC is not wanted, Quick Sync H.264 at 12 Mbps
   does the same job (`--encoder qsv`).
3. Stay on H.264 and 30 fps for now: HEVC and 60 fps are not worth their risk and cost yet (below).
4. Needs about 28 Mbps of steady upload from the box (estimate below). Below that, 10 Mbps landscape.

First, keyframes. In shake7 YouTube Studio reported the horizontal feed's keyframe frequency as 7.9 s, an error (YouTube
wants 4 s or less); the vertical feed, at 2 s from `vertical.py settings`, was healthy. The pog profile is in Simple
output mode with Quick Sync and keyint 0 (auto), and Simple mode has no keyframe setting. The built-in YouTube service,
which would enforce 2 s, crashed OBS 32.2.2 (docs/SETUP.md). So the profile moves to Advanced output, where the stream
encoder's settings (`keyint_sec` among them) live in `streamEncoder.json`.

`obs_profile.py advanced` does that and carries over everything Simple mode did. It reads each value from the Simple
section and prints `CHECK:` for any that differs from what the operator described. The mapping follows OBS 32's
`frontend/utility/SimpleOutput.cpp` and `AdvancedOutput.cpp`:

| Simple mode | Advanced mode |
|---|---|
| `StreamEncoder=qsv`, `VBitrate`, CBR, `QSVPreset` | `AdvOut Encoder=obs_qsv11_v2`; `streamEncoder.json` `{rate_control: CBR, bitrate, keyint_sec: 2, preset}` |
| stream audio on mixer track 1 at `ABitrate` (160) | `TrackIndex=1`, `Track1Bitrate=160`, `AudioEncoder=ffmpeg_aac` |
| recording: `FilePath` (D:\pog\recordings), `RecFormat2` (mkv), quality "Stream" (shares the stream encoder) | `RecType=Standard`, `RecFilePath`, `RecFormat2`, `RecEncoder=none`, `RecAudioEncoder=none` (still one shared encode), `RecTracks=1` |
| (quality "Small"/"HQ" instead) | `RecEncoder` = its id, `recordEncoder.json` CQP at OBS's own CalcCRF(23 or 16) |
| replay buffer `RecRB`, `RecRBTime` (45), `RecRBSize` (512) | `AdvOut RecRB`, `RecRBTime`, `RecRBSize` |
| replay prefix `RecRBPrefix=Replay` (replays.py reads the saved path) | unchanged: Advanced mode reads `[SimpleOutput] RecRBPrefix/RecRBSuffix` too |
| `[Video] AutoRemux` (off), filename format, reconnect, delay, `service.json` (Custom RTMPS) | untouched |

Before writing, it keeps a dated copy of `basic.ini`, `streamEncoder.json` and `recordEncoder.json`
(`NAME.pog-YYYYMMDD-HHMMSS`; a file that did not exist gets a `.absent` marker). `rollback STAMP` restores all three
and deletes any of them the change created.

Shift change, OBS closed on the box (File > Exit), from the repo root on the Mac:

```sh
tools/.venv/bin/python tools/obs_profile.py show                       # read-only, works anytime
tools/.venv/bin/python tools/obs_profile.py advanced --dry-run         # every key before -> after, and CHECK lines
tools/.venv/bin/python tools/obs_profile.py advanced                   # prints the backup stamp and the undo command
# optional, the 1080p plan below (Advanced mode now; its own backups):
tools/.venv/bin/python tools/obs_profile.py 1080p --encoder nvenc --bitrate 12000 --dry-run
tools/.venv/bin/python tools/obs_profile.py 1080p --encoder nvenc --bitrate 12000
# start OBS. Undo everything (OBS closed): obs_profile.py rollback STAMP (the stamp `advanced` printed;
# `obs_profile.py backups` lists them)
```

After starting OBS: Settings > Output should show Output Mode "Advanced", the stream tab Quick Sync H.264 with
Keyframe Interval 2 s, the recording tab D:\pog\recordings, mkv, "(Use stream encoder)", and the replay buffer
45 s / 512 MB. In YouTube Studio's stream health, the horizontal feed's keyframe error should be gone within a minute
of going live. `tools/stream/replays.py` saving a clip ("[replays] saved ...Replay_...mkv") shows the buffer and its
prefix work.

The 1080p dry run prints every key before and after. Check that the current encoder value reads `qsv` (Simple output mode)
or `obs_qsv11_v2` (Advanced): that confirms the format the script writes (`nvenc` / `obs_nvenc_h264_tex`). The
script never touches `service.json`, so the stream stays on the Custom RTMPS service (docs/SETUP.md: OBS 32.2.2's
built-in YouTube service crashed OBS at stream start). The vertical needs no change for this plan.

## YouTube's numbers

YouTube Help, "Choose live encoder settings, bitrates, and resolutions" (support.google.com/youtube/answer/2853702),
minimum / recommended, Mbps:

| | H.264 | H.265 / AV1 |
|---|---|---|
| 720p30 | 3 / 8 | 2 / 6 |
| 1080p30 | 5 / 14 | 4 / 10 |
| 1080p60 | 6 / 17 | 4 / 12 |

Keyframes every 2 s (never over 4 s); audio 128 Kbps stereo. So today's 6 Mbps at 720p30 is below YouTube's
recommended 8, and 12 Mbps at 1080p30 sits between the 1080p30 minimum and recommendation. Factorio scenes are mostly
static with small moving detail (belts, inserters, biters), which compresses well; 12 is a reasonable start, 14 if
the upload allows. (That last point is my judgement, not measured.)

## Encoder

- Quick Sync H.264 (the box's Intel iGPU, today's encoder): carries the stream, the vertical, the recording (HEVC) and
  the replay buffer. One 30 s sample in shake3 with stream + recording + buffer: 0 frames skipped, CPU 10.7%, render
  0.78 ms (docs/STREAM-NOTES.md). Not measured since the vertical was added.
- NVENC (RTX 2070 Super, Turing): its H.264 encoder is a dedicated block on the GPU, separate from the 3D work of the
  game clients and OBS. If OBS renders on the 2070 (check OBS's log: "Loading up D3D11 on adapter"), NVENC encodes
  the frame where it is, whereas Quick Sync needs the frame copied from the NVIDIA GPU to the iGPU. That is the
  reason to move the larger landscape encode to NVENC. Session limit: NVIDIA's NVENC application note gives 8
  concurrent sessions per system on consumer GPUs with drivers 551.76 or newer (earlier drivers: 3 or 5); we would
  use one or two.
- HEVC: YouTube takes HEVC over Enhanced RTMP from OBS (since OBS 29.1, 2023) and recommends 10 instead of 14 Mbps at
  1080p30, so it would save upload. Not now: no source here confirms HEVC through our Custom RTMPS service plus
  YouTube's Dual stream, and a codec change is the riskier variable while the vertical is new. A later test.
- AV1: the 2070 Super has no AV1 encoder (Turing); not an option on this box.

## 60 fps

Doubles the frames for every client window, the overlay page, both canvases (the vertical canvas takes OBS's frame
rate) and both encodes; YouTube recommends 17 instead of 14 Mbps. The cameras pan slowly and the overlay is text, so
30 fps loses little. Revisit only if a camera follows fast vehicles. `obs_profile.py --fps 60` exists for a test.

## Director windows and zoom

- Holes in the 1920x1080 layout (`tools/stream/static/layout.json`): main 1208x680 at (24, 24), cam2 and cam3
  596x336. At a 1280x720 output the main camera reaches viewers as about 805x453 pixels; at 1080p as 1208x680.
- `start-client.ps1` sets no window size; the window is whatever Factorio last used. The director's pair framing
  assumes "~60 tiles across at zoom 1 on a 1080p client" (`tools/stream/director.py`), i.e. 1920 px / 32 px per
  tile. A capture at least 1208x680 (main) is not upscaled; 1920x1080 windows are downscaled to the hole, which is
  sharp. Check the capture sizes during a run (read-only):
  `tools/.venv/bin/python -c "import sys; sys.path.insert(0,'tools'); from obs import client; c=client(); [print(n, c.get_scene_item_transform('stream', c.get_scene_item_id('stream', n).scene_item_id).scene_item_transform['sourceWidth'], c.get_scene_item_transform('stream', c.get_scene_item_id('stream', n).scene_item_id).scene_item_transform['sourceHeight']) for n in ('stream cam1','stream cam2','stream cam3')]"`
- If a window size changes, the zoom must scale with it to frame the same area: Factorio shows
  window_height / (32 x zoom) tiles vertically, so going from a 720 to a 1080 px tall window at the same zoom shows
  1.5x more map. Then multiply `main_scale` (director.py, 1.5 today) by new_height / old_height, and the pair rule's
  60 tiles by the same ratio. With windows already 1920x1080 nothing changes.
- Sprite resolution: since round 8 the directors run `graphics-quality=medium` (normal-resolution sprites) to save
  memory. The main camera's zoom is 0.75 to 1.6 (base zooms x `main_scale`); above zoom 1 medium sprites are
  magnified and look soft, which a 1080p output will show more than 720p did. If memory allows, `-Human`-style high
  sprites for cam1 only would sharpen the main camera; that is a start-client.ps1 change for later.

## Box GPU and memory

- Commit charge is the limit that crashed shake5's cam3 (51.8 of 54.5 GB; each Space Age director ~5.2 GB private;
  docs/STREAM-NOTES.md "Director client memory"). Output resolution and encoder changes are inside OBS and cost
  little commit (an encoder's buffers are tens of MB, an estimate). Larger client windows cost mostly VRAM
  (render targets), not commit.
- VRAM: the 2070 Super has 8 GB for four Factorio clients, OBS's canvases and NVENC. Not measured; watch
  `render_ms` and skipped frames in `/replays.json` (OBS stats every 30 s) after the change.

## Upload

Estimate: landscape 12 + vertical 6 + 2 x 0.16 audio = about 18.3 Mbps of payload. RTMP bitrates are averages and
CBR still bursts; the usual advice is 1.5x headroom, so about 28 Mbps of steady upload (at 10 Mbps landscape: about
25). The box's upload has not been measured here: run a speed test on the box, and during the first shift watch
`tools/.venv/bin/python tools/obs.py stream-status` (skipped frames, congestion) and YouTube's stream health.

## How to check after the change

- `obs_profile.py show`: OutputCX/OutputCY 1920/1080, the encoder and bitrate.
- `obs.py stream-status`: skipped 0, congestion near 0 over the first 10 minutes.
- `/replays.json` stats: `render_ms`, `skipped_since_last` (render and output), CPU, against shake3's sample.
- YouTube's Live Control Room: "Excellent" stream health and 1080p in the quality menu; text on the cards readable on
  a phone in landscape.

## Sources

- YouTube Help, live encoder settings: https://support.google.com/youtube/answer/2853702
- NVIDIA NVENC application note (session limit): https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-application-note/index.html
- OBS and YouTube, HEVC/AV1 over Enhanced RTMP: https://obsproject.com/blog/youtube-renews-premier-sponsorship-of-the-obs-project
  and https://www.phoronix.com/news/OBS-Studio-AV1-HEVC-RTMP
- obs-qsv11 encoder ids and keys (OBS 32.0 source), Aitum Vertical 1.6.6 source: see docs/VERTICAL-PROPOSAL.md.
