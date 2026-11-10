# Public test stream (mt289 race view)

Cp4 fits two agents per team, scoped internal conversations, and a fixed viewer
chat footer. Missing activity falls back to the roster's model label. Missing maps,
metrics and empty chat/news are hidden; the viewer footer appears when messages arrive.
The live relay/site integration belongs to mt290; its merge contract is
in `docs/mt-public-chat-contract.md`. The standalone commands below retain the old
read-only YouTube reader until that integration is merged.

This lives on the `mt/` line only. Public test broadcasts are authorized; the
mode's implementation still stays off `main`. Nothing here starts streaming or
transitions a YouTube broadcast to live.

## Start and stop

Use the checked-out `mt/batch289` (or the operator's merged mt checkpoint). The
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
forward); `POG_MT_PUBLIC_DWELL` defaults to a 30-second ordinary dwell (10–300 allowed). Fresh milestones can
cut earlier, after a 15-second minimum at the default; see the director below.
`POG_MT_YOUTUBE` is optional and must be the intended broadcast ID, never an old
channel stream chosen by accident. `POG_MT_STREAM=1` alone keeps its existing
private/local behavior. No site push, caster, viewer relay, or highlight runs.

The public page is http://127.0.0.1:8790/ on this Mac and pogwin; `/state.json`
is its public projection. The only other routes are `/health`, the fixed `/mapview.js` renderer, and
manifest-listed `/static/game/{item,tech,place}/*.webp` icons. No files
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
It uses the installed **Space Age** build at `D:/pog/factorio-2.0.77-expansion`;
the base-only alpha build cannot join this world. The server's on-disk mods are
copied into the dedicated client directory before joining.
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

The director considers the existing team feeds every five seconds. A successful cut
holds for `max(10, min(20, dwell/2))` seconds (15 at the default). Fresh rockets,
losses, contact, research and builds attract a cut after that minimum; otherwise
acting agents get preference at the ordinary dwell. At `dwell × max(2, team_count)`
seconds since a team's last appearance, oldest-first fairness overrides interest.
This is a target subject to minimum dwell, poll timing, feed freshness and camera
success. Failed cuts cool down for 30 seconds and never change the on-camera label.
Stale or paused teams are ineligible. No team is starved by another team's repeated
news while its feed and chart checks remain healthy.

The camera frames the first acting agent with a position, then the basemap core,
then a located agent. Existing `lookcam` chart checks run through
`Harness('imac2', team)` before each cut, tightening zoom if necessary. No chart
mutation, full chart read, new Lua, or tick callback was added. It still uses one
pogwin camera. The iMac screenshot client has no additional work.

Human-password/whitelist servers need `pog-director2` admitted and a compatible
client password before use. The default AI test server requires neither. Camera
startup times out instead of weakening server authentication.

## OBS

The `mt-stream` scene contains only `mt background`, `mt camera`, `mt overlay`.
The main camera occupies 1280×720 at (24,248). A ranked race strip runs across
the top; each right-hand team panel contains its activities, map and last two conversation
messages. A viewer-chat panel occupies the wide footer when messages are present, and the right
footer shows two recent race events. Mt290 owns relaying viewer messages to agents;
team conversations are never copied to that relay. The canvas is 1920×1080. The camera is silent in this
checkpoint; music and caster pipelines are not started.
All graphics/text are canvas-rendered, retaining mt288's workaround for disappearing
OBS HTML text. The browser remains transparent over the camera rectangle. Mt289
was checked offline at 1920×1080, including four teams/twelve agents and a 75-second
moving replay; its changed rectangle still needs the next operator OBS preview.

Setup refuses if OBS is streaming, saves the prior program scene, selects
`mt-stream`, starts recording if needed, and waits for recording to become active.
Stop restores the prior scene if `mt-stream` is still selected and stops recording
only if this supervisor started it. It leaves the scene available for later runs.
Both recording start and stop wait for OBS's asynchronous state change.
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
with the same arguments without inserting a second broadcast. Privacy defaults to unlisted (`--privacy` overrides it);
`enableAutoStart=false`, `enableAutoStop=false`, DVR and recording from start are
enabled. Creating/binding does not send video. OBS's start-stream and YouTube's
go-live controls remain explicit operator actions after checking the preview.

API references checked for this implementation:
https://developers.google.com/youtube/data/live/reference/rest/v3/liveBroadcasts/insert
https://developers.google.com/youtube/data/live/reference/rest/v3/liveBroadcasts/bind

## Race facts and offline preview

`public_race.project()` is imported as `public_overlay.project()`, retaining the
single explicit public boundary. The page cannot read raw team state or operator
files. Numeric fields are finite and bounded, grids contain only map categories,
technologies/items come from the existing Wube icon manifest, and identities come
from the launch roster. Actions are built from recognized verbs/item names, never
arbitrary jobs, notes, errors or action payloads. Roster team-speech and tells with exclusively same-team recipients are kept,
explicitly tagged and nested under their team. Confession/operator/notice lanes,
cross-team tells and sensitive-looking speech are excluded. Viewer author identities are not published. Free-form speech filtering
is conservative; it is not a general-purpose classifier of every possible secret.

The standings rank rockets, then completed technologies; ties remain ties. This
is a visible comparison metric, not a weighted research-cost score or an estimate
of percent to victory. When all fresh scores are zero, startup steps compare the
presence of a burner miner, stone furnace, steam engine, lab and assembler.
A feed with unknown scores is unranked. Current research has its own percentage.
SPM and its up-to-30-point history reuse the stream's labs-consumption metric.

The existing `op/views.json` supplies building counts and a newer research count
when applicable. It is read locally every five seconds and ignored after 150s;
its existing upstream 60s schedule is unchanged. No additional game data calls
are introduced. Milestones use safe chronicle/research fields or score changes;
`~` means the time of observation, not an exact event timestamp. Building counts
only establish that a building exists, never that power is flowing or that a
count decrease was destruction. The event ring retains 80 events in memory,
exposes the latest 12 and shows two; restarting reseeds only available recent
source events. The minimaps reuse the existing basemap core and the main map's
category colours/run grouping; missing maps are hidden, with the roster/activity text reclaiming their width. They are factory
grids, not new cameras. The icon credit is always on screen.

Offline (no game, clients, OBS, broadcast, or operator gate):

```sh
python3 tools/mt/public_replay.py --write /absolute/artifacts/synthetic.json
python3 tools/mt/public_replay.py --write /absolute/artifacts/mtt1-replay.json --mtt1 /absolute/mtt1/op
python3 tools/mt/public_replay.py --serve /absolute/artifacts/synthetic.json --port 8796
# Keep the supplied before-mtt1-16m.png in that artifact directory for the composite.
PLAYWRIGHT=/absolute/node_modules/playwright MT_SOAK=1 node tools/mt/public_replay_check.cjs /absolute/artifacts
python3 tools/test_mt_race.py
python3 tools/test_mt_public.py
python3 tools/mt/public_bench.py
```

The preview is http://127.0.0.1:8796/. Its fixtures explicitly identify synthetic
or recorded replay, with a still camera frame. The recorded fixture never invents
SPM, maps or agent activity missing from the logs. Preview tooling is separate
from the production HTTP server and is not staged by `public_stream.py`.
