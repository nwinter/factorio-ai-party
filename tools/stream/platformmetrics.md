# Platform metrics

The main overlay shows a compact card for the main-camera platform, or the active featured platform while the
director shows something else. The main camera takes precedence if it shows a different ship. Host view hides
the card. Selection uses `onair.platform.name`, `cameras.main.ship.name`, then active `featured_platform.name`,
joined to `space.platforms`. The older small ship label yields to this card on the main view.

The service calls the operator read `platform_metrics` at most once per 20 wall seconds across all selections.
The runtime must advertise it in `describe.operator_reads`; earlier runtimes show no card. It starts no watch,
does no background work, and does not call endurance, hull coverage, ammunition-feed tracing or ingredient
planning. A failed read hides the card; successful readings expire after 45 seconds. Unknown fields are omitted.

The card reports:

- Directed leg, distance flown/left, progress and current speed in km per game second. ETA is approximate wall
  time at current ship speed and observed game ticks per wall second, including reduced UPS. It needs two samples
  of the same leg and is absent when paused, stationary or without advancing ticks.
- Asteroids by size in the acknowledged main camera's rectangle at the last sample. It uses the director's
  frame zoom, position and on-air crop. This field is absent when the selected ship has no main-camera frame.
- Kills and damage dealt per wall minute from matching turret tooltip counters, and hits taken per wall minute
  plus damage taken during the displayed sampling window from the existing platform hit totals. A changed turret
  roster or reset counter suppresses the affected rates. Damage taken is not an unrepaired-health deficit.
- Turrets by type: total, engaged (a shooting target at the instant sampled), and empty ammunition inventories.
  Engaged is not a count of projectiles fired in the interval; electric/fluid turrets have no empty-ammo value.
- Ammunition by type, all qualities: stock in hub and loaded turrets; surface production and consumption per wall
  minute; net change. Consumption includes crafting. Buffer minutes divide that stock by positive net consumption;
  belts, machines, incoming rockets, ingredient limits and feed access are excluded. This is not an endurance
  prediction. No depletion time is shown for a zero or positive net rate.
- Repair packs in the hub; fuel and oxidizer in thruster/storage tanks (pipes and machines excluded).
- Destroyed entities recorded this leg, excluding foundation tiles, only when the existing leg and loss-log
  coverage are complete. No estimated zero is supplied for an unobserved or truncated leg.

The native read caps turret enumeration at 257 (over 256 hides its aggregates), tanks at 129 (over 128 hides fuel),
camera rectangles at 512 tiles per side, and each size count at 4097 (over 4096 hides that count). Loss history is
the existing bounded 6000-row ring. It performs no asteroid entity traversal. No runtime events were added.

Rows retain their DOM nodes while values change. The card is part of the normal main overlay; it requires the
updated runtime and stream process at the operator's deployment. It makes no OBS calls.

Offline checks: `python3 tools/stream/test_platformmetrics.py`, the harness `platformmetrics_test.lua`, and the
ordinary npm/Python gates. The report records private dense-leg profiling and the private-run screenshot.
