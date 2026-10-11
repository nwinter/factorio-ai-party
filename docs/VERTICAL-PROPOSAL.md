# Vertical (9:16) stream for YouTube mobile: proposal

For the operator. Branch eng/stream2, 2026-10-11.

## Problem

On phones held upright, YouTube's vertical surfaces crop a 16:9 stream to its middle third (x 656..1264 of 1920). On
our layout that keeps the right half of the main camera and none of the panels: no names, no chat, no science.

## What is already built (eng/stream2)

- `http://HOST:PORT/portrait`: a 1080x1920 overlay page fed by the same service and code as the landscape page.
  Top to bottom:
  - title and clock;
  - the main camera, full width and 16:9 (the feed scaled, not cropped);
  - cam2 and cam3 side by side;
  - a 3x3 agent grid;
  - science per minute;
  - chat, with conversation lane, viewers lane and logistics ticker.

  Text is about 1.6x the landscape size. Segments, alerts, replays' "coming up" card and voice captions (with host
  portraits) all work on it. Camera holes are in `tools/stream/static/layout-portrait.json`:

  | camera | x, y | size |
  |---|---|---|
  | main | 24, 112 | 1032x581 |
  | cam2 | 24, 709 | 508x286 |
  | cam3 | 548, 709 | 508x286 |

- Checked: in jsdom against shake2's live state and the mock. Not yet looked at in OBS.

## What the box can do (checked 2026-10-11 over obs-websocket, read-only)

- OBS 32.2.2, obs-websocket 5.7.4, one canvas "Main" (1920x1080, 60 fps).
- `GetCanvasList` exists, so this OBS has the multi-canvas machinery that vertical plugins build on.
- The websocket cannot create a canvas, so a 9:16 canvas comes from a plugin or OBS's own UI.
- One Quick Sync encoder already carries the recording, the stream and the 45 s replay buffer.
- With only the buffer running, no output frames were skipped.

## What YouTube offers (not verified: this session had no web access)

- From what was known before October 2026: a 9:16 live stream plays full screen on phones and can surface in the
  Shorts feed.
- A channel can run more than one live stream at a time, each on its own stream key.
- YouTube may by now also accept a horizontal and a vertical rendition of one stream ("dual format"). **Check this
  first:** if it exists, it is the simplest route, and the OBS setup below changes to whatever it asks for.

## Recommendation (cheapest good option)

A second live stream in 9:16 from a second canvas in the same OBS:

1. On YouTube Studio, check for dual-format live. If it is offered, follow its OBS setup, using the scene from
   step 3. If not, create a second live event (vertical) with its own stream key.
2. In OBS, add a 9:16 canvas (1080x1920, 30 or 60 fps): the free Aitum Vertical plugin, or OBS 32's own canvas
   settings if this build exposes them.
3. In that canvas, one scene "stream vertical":
   - the three director window captures (the same `game_capture` sources as the "stream" scene) placed in the holes
     above;
   - one browser source on `http://127.0.0.1:8787/portrait` at 1080x1920 on top (audio: off, since the landscape
     overlay already carries the voices; or on, if the vertical output has its own audio mix).
4. Point the vertical output at the second key, on the same Quick Sync encoder:
   - 1080x1920 at 6-8 Mbps (or 720x1280 at 4 Mbps if the encoder is tight);
   - watch `outputSkippedFrames` in `/replays.json` (stats every 30 s) during the first run.
5. Replays and segments need no change: segments draw on both pages, and replays switch only the landscape program
   scene. (The vertical canvas keeps showing the live cameras during a replay, which is acceptable for a first
   version.)

Cost:
- a second encode on Quick Sync (the main unknown, since the stream, recording and buffer have never been measured
  together);
- a second live event to start and stop;
- about 20 minutes of OBS setup.

No change to the `pog` profile's existing outputs.

## Alternatives considered

- **Crop-safe landscape layout** (move names and chat into the middle third): no second encode, but the middle
  third is 608 px wide, too narrow for the panels and it would cramp the landscape stream.
- **Second OBS instance** with its own profile: works without plugins but doubles capture and render load and means
  two configs to keep in sync. A fallback if the canvas route fails.
- **Vertical only:** loses desktop and TV viewers, who still get the cropped feed.

## Open questions for the operator

- Does YouTube Studio offer dual-format live on this channel?
- Is the Aitum Vertical plugin (or OBS's canvas UI) acceptable on the box?
- Encoder headroom: run one 10-minute test with stream + recording + replay buffer + vertical output and read
  `/replays.json` before a real run.
