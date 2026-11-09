# Public test stream (mt288)

This lives on the `mt/` line only. Public test broadcasts are authorized; the
mode's implementation still stays off `main`. Nothing here starts streaming or
transitions a YouTube broadcast to live.

## Start and stop

Use the checked-out `mt/batch288` (or the operator's merged mt checkpoint). The
normal launch tree remains the agents' tree; public operator files stay outside
it. Use the project's Python environment, or the existing Homebrew Python used
by the launch scripts (`PATH=/opt/homebrew/bin:$PATH`).

```sh
# Normal new test; public staging implies POG_MT_STREAM=1.
POG_MT_PUBLIC=1 POG_MT_FRESH=1 tools/mt/start-mt.sh RUN 25

# With viewer chat from the operator-created broadcast (display only).
POG_MT_PUBLIC=1 POG_MT_YOUTUBE=VIDEO_ID POG_MT_FRESH=1 tools/mt/start-mt.sh RUN 25

# Add public staging to an already-running test whose team services are up.
python3 tools/mt/public_stream.py start RUN
python3 tools/mt/public_stream.py status RUN

# Remove just the public camera/overlay/recording; leave agents and feeds running.
python3 tools/mt/public_stream.py stop RUN

# Stop the run, including its public supervisor, before stopping team services.
tools/mt/stop-mt.sh RUN
```

`POG_MT_PUBLIC_PORT` defaults to 8790 (both this Mac's local HTTP and pogwin's reverse
forward); `POG_MT_PUBLIC_DWELL` defaults to 30 seconds per team (10–300 allowed).
`POG_MT_YOUTUBE` is optional and must be the intended broadcast ID, never an old
channel stream chosen by accident. `POG_MT_STREAM=1` alone keeps its existing
private/local behavior. No site push, caster, viewer relay, or highlight runs.

The public page is http://127.0.0.1:8790/ on this Mac and pogwin; `/state.json`
is its public projection. Only these routes and `/health` are served. No files
from a run tree, paths, quota/account data, or operator request fields are served.
OBS shows the HTTP page to viewers; no public HTTP server is needed.

`runs/RUN/op/public-stream.json` records readiness, PID, prior scene, and the
recording path after stop. `public-stream.log` contains errors and camera cuts.
Startup fails visibly if the tunnel, join, team framing, or recording fails.
The agents and per-team services remain running if public staging fails; fix it
and use `public_stream.py start RUN`. A dropped SSH connection cleans up the
public components and requires a stop/start. No automatic go-live exists.

If an operator later starts streaming, stop OBS streaming before stopping this
run. Stop refuses while OBS is live, so it cannot blank a broadcast unexpectedly.
The YouTube broadcast remains open (`enableAutoStop=false`) until the operator
ends it. If cleanup records an error, inspect OBS and the specific owned camera
PID before retrying; never kill a process by pattern.

## Camera and network

One pogwin client: `pog-director2`, executable `factorio-mtcam.exe`, task
`pog-mt-stream-camera`, write data `D:/pog/mt-stream/client`. It uses medium
sprites, low video memory, no audio. It refuses to start while another Factorio
process is running on pogwin. World n's `n-client-cam1` and settings are untouched.
The iMac's `pog-cam1` remains the agents' screenshot renderer; public staging does
not replace the `POG_MT_CAM` shot sync.

Factorio's game port is UDP; SSH port forwarding alone is TCP. The owned bridge is:

```text
pogwin spectator -> 127.0.0.1:34478 UDP -> bridge.ps1
  -> 127.0.0.1:34478 TCP -> reverse SSH from this Mac
  -> udp_bridge.py -> imac.local:34475 UDP
```

The same SSH connection reverse-forwards the overlay and locally forwards
4458 to pogwin's OBS WebSocket 4455. All new listeners bind loopback. This Mac
initiates SSH to pogwin, so no route from 192.168.0.x to 192.168.4.x is needed.

The director cycles in `op/streams.txt` order (`TEAM URL`). It uses each team's
existing basemap core, or the first located agent while the base is empty. The
existing `lookcam` chart check runs through `Harness('imac2', team)` before each
cut, tightening zoom if the frame crosses uncharted chunks. It reads no full
`chart.lua` endpoint and adds no game-tick work. The on-camera label changes only
after a successful camera command. Missing/stale feeds are marked and skipped.
Later bases can outgrow a fixed frame; this first release shows their center.

Human-password/whitelist servers need `pog-director2` admitted and a compatible
client password before use. The default AI test server requires neither. Camera
startup times out instead of weakening server authentication.

## OBS

The `mt-stream` scene contains only `mt background`, `mt camera`, `mt overlay`.
The main camera occupies 1440×810 at (0,72), with team cards on the right and
team/viewer chat below. The canvas is 1920×1080. The camera is silent in this
checkpoint; music and caster pipelines are not started.

Setup refuses if OBS is streaming, saves the prior program scene, selects
`mt-stream`, starts recording if needed, and waits for recording to become active.
Stop restores the prior scene if `mt-stream` is still selected and stops recording
only if this supervisor started it. It leaves the scene available for later runs.
World n's sources, scenes, streaming credentials, profiles and collections are
not edited.

## YouTube: operator creates the broadcast

`public_broadcast.py` reuses `tools/yt_upload.py` and its existing `youtube` OAuth
scope. It never prints ingest keys and never calls `liveBroadcasts.transition`.
Use the existing stream ID matching OBS's configured ingest key:

```sh
python3 tools/mt/public_broadcast.py streams

# Review the exact public broadcast insert and bind; no network or auth in dry-run.
python3 tools/mt/public_broadcast.py create \
  --title 'Factorio: Space Age — AI team tests' \
  --start 2026-11-09T05:00:00Z --stream-id STREAM_ID \
  --receipt runs/RUN/op/broadcast.json

# Operator executes the reviewed request (choose the actual future start time).
python3 tools/mt/public_broadcast.py create \
  --title 'Factorio: Space Age — AI team tests' \
  --start 2026-11-09T05:00:00Z --stream-id STREAM_ID \
  --receipt runs/RUN/op/broadcast.json --execute
```

The receipt saves the inserted ID before binding, so a failed bind can be retried
with the same arguments without inserting a second broadcast. Privacy is public;
`enableAutoStart=false`, `enableAutoStop=false`, DVR and recording from start are
enabled. Creating/binding does not send video. OBS's start-stream and YouTube's
go-live controls remain explicit operator actions after checking the preview.

API references checked for this implementation:
https://developers.google.com/youtube/data/live/reference/rest/v3/liveBroadcasts/insert
https://developers.google.com/youtube/data/live/reference/rest/v3/liveBroadcasts/bind
