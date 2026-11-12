# Public test stream (mt294 broadcast view)

One 1920×1080 overlay over one game camera: a standings strip that holds every team's roster,
the camera with the agent on air named in a lower third, a speech feed for all teams
("team radio": team talk, private tells, team-board notes, diplomacy, viewer chat), a news belt
and the game clock. Agents appear with the name, persona, colour, glyph and portrait they chose.
The state the page reads is described in `docs/mt-public-chat-contract.md`; where the identities
and the ordered speech feed come from is in `docs/mt-identities-feed.md`.

This lives on the `mt/` line only. Public test broadcasts are authorized; the
mode's implementation still stays off `main`. Nothing here starts streaming or
transitions a YouTube broadcast to live.

## Start and stop

Use the checked-out `mt/batch290` (or the operator's merged mt checkpoint).
All new tests use 2.1.24. Before the general-launcher commands below, export the
2.1 server/app/mod-list/KB/launch-tree pins from docs/PORT21.md; do not use the
general launcher's 2.0 defaults. The closed `port21.sh` wrapper still refuses
public staging; it now permits local team stream services and viewer fixtures. The
normal launch tree remains the agents' tree; public operator files stay outside
it. Use the project's Python environment, or the existing Homebrew Python used
by the launch scripts (`PATH=/opt/homebrew/bin:$PATH`).

```sh
# Normal new test; public staging implies POG_MT_STREAM=1.
POG_MT_PUBLIC=1 POG_MT_FRESH=1 tools/mt/start-mt.sh RUN 25

# With moderated viewer chat from the site and operator-created broadcast.
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
private/local behavior unless POG_MT_VIEWERS=1 is supplied. Public staging defaults
POG_MT_VIEWERS=1: each team's serve.py reads site/YouTube chat through the existing
Filter, Clef and Relay. Every accepted line reaches both agents in every team;
a viewer may name a team as a conversational cue. Operator-only and viewers-only
channels retain their existing rules. No automatic site push, caster or highlight runs.
The overlay reads these filtered lanes; it never starts another reader or relay.
Manual hidden-viewers rules and deletions apply before display and delivery.
Removing TREE/runs/RUN/TEAM/viewer-relay pauses that team's relay.

The public page is http://127.0.0.1:8790/ on this Mac and pogwin; `/state.json`
is its public projection. The only other routes are `/health`, the page's own files (`/overlay.js`,
`/avatar.js` from the main stream, `/mapview.js`, five font files under `/fonts/`), and
manifest-listed `/static/game/{item,tech,place}/*.webp` icons, all from one fixed table
(`public_overlay.asset`). The fonts are vendored in `tools/mt/fonts` (Titillium Web and Big Shoulders
Display, SIL OFL, licences beside them), so the page loads nothing from the internet. No files
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
holds for `max(10, min(20, dwell/2))` seconds (15 at the default). After that, in order:

1. Fairness. A team unseen for `dwell × max(2, team_count)` seconds (90 s for three teams) gets the
   camera, oldest first. A team where nobody has moved for a while waits twice that while another
   team is working, and its visit is a glance: it ends at the minimum dwell.
2. Fresh news elsewhere (rocket, loss, contact, pact, research, build), as before.
3. Action. If nobody on the team on air is acting and someone on another team is, cut there.
4. At the ordinary dwell: move to another team that is acting; stay with the only team that is;
   rotate, longest unseen first, when nobody is.
5. Within the team on air, turn to the teammate who is acting once the agent on air has stopped.

"Acting" comes from `public_race.subjects()`, the director's private reading of each team's feed:
an action running now counts most (the stream director's fight, build, work and walk classes), a
request that just changed the map (`did`) and the stream's decaying `interest` keep a builder in
view between calls, and an agent whose character has stood idle (`idle_s`), rests or is offline
counts for almost nothing. Nothing from `subjects()` is published except the chosen agent's name.

The shot (`public_overlay.shots`): follow the agent who is doing something, close for fights and
building, wide for walks (the game eases the view after a walking agent); else the base while its
labs are running; else the agent who moved most recently, so a character is on screen; else the
base. The existing `lookcam` chart checks run through `Harness('imac2', team)` before each cut and
tighten the zoom, and a follow shot that is not charted falls back to the base. No chart mutation,
full chart read, new Lua, or tick callback. Failed cuts cool down for 30 seconds and never change
the on-camera label. Stale or paused teams are ineligible. It still uses one pogwin camera.

`tools/mt/camera_eval.py RUN/op` replays a finished run from its own logs and reports, for the
earlier rule and this one, how much of the time an acting agent was in frame. On t291 and t292 the
earlier rule showed action 22% and 15% of the time (and an empty frame 38% of t291); this rule
46% and 33% with no empty frames, at the same cut rate. Someone was acting 51% and 38% of the time.

Human-password/whitelist servers need `pog-director2` admitted and a compatible
client password before use. The default AI test server requires neither. Camera
startup times out instead of weakening server authentication.

## OBS

The `mt-stream` scene contains only `mt background`, `mt camera`, `mt overlay`.
The camera occupies **1408×792 at (16,188)**. That rectangle is `public_overlay.CAMERA_RECT`:
`setup_obs` gives it to the `mt camera` scene item and the page reads it from `state.layout`, so
the video and its frame cannot drift apart; change it in that one place. The standings strip runs
across the top (150 px + margins), the speech feed fills the 464 px to the right of the camera,
and the show bug, news belt and game clock sit below. The camera is silent; music and caster
pipelines are not started. All graphics and text are canvas-rendered (mt288: DOM text vanished in
OBS after about a minute). The page animates at the source's frame rate (30 fps in OBS); one full
draw is about 0.5 ms of script in Chromium. `?ambient=0` stops the idle motion (belts, lamps) and
draws only on changes. The page stays transparent over the camera rectangle. Checked offline at
1920×1080 for 2 to 6 teams and 2 or 3 agents a team; the new rectangle and the fonts still need
the next operator OBS preview.

The Wube graphics credit appears inside the camera frame for 14 seconds when the page loads (OBS
reloads the source when the scene becomes active, so at the start of a broadcast) and for 14 seconds
each hour after that.

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

# Review the exact unlisted broadcast insert and bind; no network or auth in dry-run.
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
with the same arguments without inserting a second broadcast. Privacy defaults to
unlisted; `--privacy unlisted|public|private` overrides it.
`enableAutoStart=false`, `enableAutoStop=false`, DVR and recording from start are
enabled. Creating/binding does not send video. OBS's start-stream and YouTube's
go-live controls remain explicit operator actions after checking the preview.

API references checked for this implementation:
https://developers.google.com/youtube/data/live/reference/rest/v3/liveBroadcasts/insert
https://developers.google.com/youtube/data/live/reference/rest/v3/liveBroadcasts/bind

## Race facts and offline preview

`public_race.project()` is imported as `public_overlay.project()`, retaining the single explicit
public boundary. The page cannot read raw team state or operator files. Numeric fields are finite
and bounded, grids contain only map categories, technologies/items come from the existing Wube
icon manifest. The roster decides who is on a team; the name, persona, colour, glyph, pronouns and
avatar parts an agent chose (the harness `profile` action) are rebuilt by `public_race.identity()`:
letters, digits and light punctuation for a name, no staff or source words, `#rrggbb` colours, the
avatar generator's own part names. Actions are built from recognized verbs and item names, never
arbitrary jobs, notes, errors or action payloads. Speech is each team's own talk, tells to
teammates, team-board notes, explicit diplomacy and identity announcements; confession, operator
and notice lanes, cross-team tells and sensitive-looking speech are excluded. Viewer author
identities are not published. Free-form speech filtering is conservative; it is not a
general-purpose classifier of every possible secret.

The standings rank rockets, then completed technologies; ties remain ties. This
is a visible comparison metric, not a weighted research-cost score or an estimate
of percent to victory. When all fresh scores are zero, startup steps compare the
presence of a burner miner, stone furnace, steam engine, lab and assembler.
A feed with unknown scores is unranked. Current research has its own percentage.
SPM and its up-to-30-point history reuse the stream's labs-consumption metric.

The existing `op/views.json` supplies building counts, a newer research count when applicable,
contacts, pacts and the ordered speech feed (`feed`, mt290 cp5: written every five seconds). It is
read locally every five seconds and ignored after 150 s. No additional game data calls
are introduced. Milestones use safe chronicle/research fields or score changes;
`~` means the time of observation, not an exact event timestamp. Building counts
only establish that a building exists, never that power is flowing or that a
count decrease was destruction. The event ring retains 80 events in memory and exposes the
latest 12; the speech ring retains 240 lines and exposes the latest 40; restarting reseeds only
what the sources still hold. Missing data is not drawn: no placeholders, and an agent with no
activity read shows its roster model label.

Offline (no game, clients, OBS, broadcast, or operator gate):

```sh
A=/absolute/artifacts
python3 tools/mt/public_replay.py --write $A/fixtures/synthetic-3x2.json
python3 tools/mt/public_replay.py --write $A/fixtures/synthetic-4x3.json --teams 4 --agents 3
python3 tools/mt/public_replay.py --write $A/fixtures/synthetic-3x2-opening.json --fresh
# A finished run, rebuilt from its own logs (journals in the launch tree op/launch-tree names):
python3 tools/mt/public_replay.py --write $A/fixtures/t292-replay.json --run /absolute/runs/t292/op
python3 tools/mt/public_replay.py --serve $A/fixtures/synthetic-3x2.json --port 8796
PLAYWRIGHT=/absolute/node_modules/playwright node tools/mt/public_replay_check.cjs $A 8796
python3 tools/mt/camera_eval.py /absolute/runs/t291/op /absolute/runs/t292/op
python3 tools/test_mt_race.py
python3 tools/test_mt_public.py
python3 tools/mt/public_bench.py
```

The preview is http://127.0.0.1:8796/ (`?frame=N` on `/state.json` picks a frame). Fixtures say on
screen what they are. Every frame goes through the production path (project, Race.update,
audience, Director with subjects). The synthetic cast and lines are invented; a recorded replay
holds only what the run's logs hold, so SPM, research progress and base maps stay absent there.
`public_replay_check.cjs` writes `$A/after/*.png` (camera stills from `$A/stills/*.png` when
present) and `$A/browser-check.json`: no page errors, a transparent camera window, each line drawn
only under its own team, a removed viewer line gone from the page, the Wube credit at the start and
hourly, twelve names in a 4×3 strip, and the script time of a draw.
