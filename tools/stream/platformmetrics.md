# Platform metrics

The main overlay shows a compact card for the main-camera platform, or the active featured platform while the
director shows something else. The main camera takes precedence if it shows a different ship. Host view hides
the card. Selection uses `onair.platform.name`, `cameras.main.ship.name`, then active `featured_platform.name`,
joined to `space.platforms`. The older small ship label yields to this card on the main view.

The service calls the operator read `platform_metrics` at most once per 20 wall seconds across all selections.
The runtime must advertise it in `describe.operator_reads`; earlier runtimes show no card. It starts no watch,
does no background work, and does not call endurance, hull coverage, ammunition-feed tracing or ingredient
planning. A failed read hides the card; successful readings expire after 45 seconds. Unknown fields are omitted.
While the simulation is paused, the collector sends no metric reads, hides rates/ETA, and lets cached facts expire.
Resume begins with a new baseline, so paused time does not dilute the rates.

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

## Card balance (batch391)

Landscape and portrait use one 360px card, 14px from the game pane's left/top edges. A visible top caption raises
it only to that caption's bottom plus 8px. Ship name and directed route/dock share the first line in every mode.
The first line fits its text without truncation; padding, width and anchor do not depend on the mode.
Panes shorter than 800px tighten detail-row whitespace and leading, retaining the same type sizes and width.

Flight defaults to compact navigation. A newly observed departure, changed leg/reversal or arrival, a positive
hit/damage window, or an increase in big/huge asteroids can start an **8 wall-second** detail beat. There must be
**30 wall-seconds after the preceding beat ends** before another can start, across ship/leg changes. Events during
that gap are not queued. Repainting a sample cannot restart a beat; a timer collapses it even between 20-second
reads. Sample age is subtracted from the beat. Cold pages/ship selections establish a baseline rather than
inventing a departure; reload shows current warnings and resumes full featured-flight telemetry immediately.
Outer-system routes alone do not expand. An active featured attempt stays full throughout its flight.

Warnings remain visible when details collapse: positive hits, damage and leg losses,
empty guns, measured ammo buffers below two minutes, and fuel/oxidizer tanks at zero. There is no invented fuel
percentage/low threshold. Each warning needs two known clean telemetry samples and at least 20 wall-seconds
since its last positive reading to clear; unknowns are not an all-clear. Ammo stock with a measured nonnegative
net rate also clears its buffer warning. Ship/leg changes discard unrelated warning history.
Full telemetry highlights current warnings in their own rows; held historical warnings remain above it.
Compact mode puts all held warnings directly below navigation, avoiding duplicate rows in the full card.

Docked details stack vertically. The candidate's actual DOM rectangle must fit above the bottom 58px caption
reserve, clear visible captions by 8px, and clear the complete surveyed foundation rectangle by 12px. Projection
uses the existing snapshot's main-camera position, zoom and cropped-width fraction (60 x 33.75 tiles at zoom 1),
at the measured pane size. Work, attention, close-up, map/follow scenes or absent geometry are conservatively
compact: their worksite is not bounded reliably. No camera framing or game read changes. Two distinct clear
telemetry samples expand; a new obstruction collapses immediately. Arrival may get a short beat only when clear.

Offline DOM tests cover scene switches, reload, ship/leg changes, actual pane dimensions, caption clearance,
hysteresis, held warnings, expired/cached samples, beat spacing and continuous featured attempts.
