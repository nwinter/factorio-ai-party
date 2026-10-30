# Ship framing (batch387)

Overview bounds come from built `space-platform-foundation` tile edges, including the exclusive right and bottom
edges. The former first-4000-entity-centres scan was not a hull: on the d30 copy Asterion had 8,975 entities, its
sample ended at x=6, and its foundation extended to x=51. Its sampled centre was x=-21.25; the hull centre was x=0.
The old scan also missed the stern (255.5 versus foundation edge 384). It has been removed from `PLATFORM_LUA`.

`Harness.platform_hulls` uses the existing foundation/chunk read for every ship, including docked refits, one ship
per observation poll. Unread ships go first, then the oldest read; the minimum reread age is 30 seconds. With 21
ships and the default three-second poll, a full sweep takes about 63 seconds, plus polling delays. Metadata still
refreshes every 15 seconds. A cold ship has no public camera view until its first hull read; a measured empty
foundation falls back to the hub. Cached geometry is replaced on the next successful survey, including shrinkage.
An error retains the last published geometry. No game-tick sampler, runtime action, or whitelist entry was added.
The existing direct read was exercised through the real Harness client on the private iMac copy.

The fit uses 60 by 33.75 tiles at zoom 1 and the narrower of the landscape and portrait native centre crops.
At the measured 2880x1620 capture, the 1208x1032 landscape hole removes 492 px per side; the 1032x883 portrait hole
removes 493. `serve.py` derives `platform_frac` from those layouts and `cams.CLIENT`, independently of other
shots' `view_frac`. Remote platform attention, work overview entries, platform holds/visits, featured context and
space segments receive that fraction. Explicit featured context omits the flight detail framing and turret reach.
Visit and work openings, operator holds and aboard follows also explicitly select hull overview framing.
Space segments retain a tall hull's pan rather than discarding it. Whole-ship zoom is rounded down to hundredths, preserving the default five-tile margin on each side.

The batch376 main zoom floor remains 0.3, and the panel floor remains 0.06. A main frame at 0.3 spans 112.5 tiles
vertically: neither the brief's 160-tile refit nor the copied 442-tile Asterion hull can fit in one still. Oversized
ships retain their sweep, with endpoints derived from the actual hull; a ship wider than the minimum-zoom pane
remains limited as before. `platform_frame.limited` in director logs makes that limit explicit. Intentional
flight detail, bow/machinery framing, work close-ups and the batch383 remote pan identity/speed rules remain.
Pan endpoint geometry uses the exact 33.75-tile height; timing, easing, destination identity and speed cap do not
change. GUI panel fits still meet their independent final floor and may therefore show only part of a large ship.

`platform_frame` in each ship command log records source bounds, hull centre, pane fraction, unconstrained fit
and whether the floor prevented the full fit. The existing command and camera acknowledgement record the sent
and acknowledged position/zoom. A smooth acknowledgement is a target receipt, not proof of the client's current
interpolated position. Private checks use cuts and additionally read the actual spectator position while paused.

Reproduce the geometric checks with `python3 tools/stream/test_platform_fit.py`. The checked-in fixture holds
three private-copy foundation silhouettes, the former sampled bounds and historical acknowledged camera commands.
`python3 tools/stream/render_platform_fit.py --output /absolute/artifact/directory` produces native-crop before/after
reconstructions. They depict the measured tiles and framing, not captured Factorio sprites or live post-deploy output.
The full d30 measurements, private command acknowledgements, renderings and gate results accompany the operator report.
