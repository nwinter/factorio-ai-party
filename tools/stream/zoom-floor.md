# Rendered camera zoom floor

Ordinary director shots have a final game-zoom floor of **0.3 for a full client** and **0.06 for a GUI inset**.
`Director.apply` enforces it after exact framing, main/side scaling and panel scaling. It also floors every native
pan point; logarithmic zoom interpolation stays between those values. The acknowledged `game_zoom` and native
path describe what was sent. An oversized ship retains its existing pan or gets a partial frame at the floor.
Only a target explicitly marked `map: true` is exempt. A GUI panel still follows the existing API's 0.05 minimum
and cannot use the main client's remote-controller chart mode.

## Private-client measurement (batch376, 2026-10-30)

Factorio **2.0.77**, private native iMac server and separate private GUI client; Resolute, surface `platform-22`,
paused save `batch374-single.zip` at tick 85502405. Client display resolution **2880×1620** (1440×810 Retina window),
GUI panels **492×277**, matching the stream camera/inset dimensions. Custom UI scale 1; the coarse sweep was also
checked at scale 1.5. No live stream camera, OBS setting or service was changed.

The GUI-camera transition is bracketed by **0.0384 (colored map blocks)** and **0.0385 (building sprites)**.
Coarse checks: 0.01, 0.025, 0.03 and 0.035 were blocks; 0.04, 0.05, 0.06, 0.07, 0.1, 0.15 and 0.2 were rendered.
The final four-panel capture shows 0.038, 0.0384, 0.0385 and 0.039 left to right. The chosen 0.06 floor leaves
margin above the measured transition. The old 0.05 panel minimum already rendered in this test; this measurement
does not establish that every historical live blob frame came from that minimum.

Full-client spectator rendering is a different path: main screenshots at 0.035 and 0.04 still show sprites;
there is no observed main transition at the inset boundary. The ordinary full-client camera API already rejects
zoom below 0.3. The final capture confirms rendered main at 0.3 plus all panels at 0.06. Explicit main map shots
use the remote controller's chart mode instead (API range 0.01–1, chart cutoff 2).

Captures use the connected client's `game.take_screenshot` with `show_gui=true`, `resolution={2880,1620}` and an
explicit main `zoom`. The GUI cameras in those images use their own zooms. For the below-API boundary sweep only,
the private paused player's `gui.screen["pog_panel_N"].zoom` was set directly; this changed no runtime source.
The dedicated client and server were both stopped after measurement; the copy slot was released to batch377.

Evidence directory: `/Users/owner/code/personal/player-of-games/artifacts/batch376/`

- `boundary-final.png`: four-panel transition bracket (0.038, 0.0384, 0.0385, 0.039).
- `capped.png`: main 0.3 and panels 0.06, all rendered.
- `panels-scale1.png`: panels 0.04, 0.05, 0.06, 0.07.
- `boundary-main035.png`, `main040.png`: distinct full-client rendering below the GUI threshold.
- `zoom-scale1.txt`, `zoom-boundary.txt`, `private-client.log`: dimensions, scale, tick, version and probe values.
- `private-stop.log`: private server shutdown; dedicated client PID 87186 was stopped separately.

Offline regression: `python3 tools/stream/test_zoom_floor.py` exercises real director sends, low exact/ordinary
zooms, panel scaling, oversized featured-platform main/inset shots, all native pan points and their interpolated
zooms, failed-send retries and explicitly marked maps. It requires no game or OBS access.
