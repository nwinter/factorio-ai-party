# Testing

`npm test` builds the TypeScript CLI and runs transport, protocol, bundling, and host tests. The Lua policy tests exercise bounded actions and validation against a small fake engine. Real-engine tests supplement those checks.

## Real Factorio smoke test

```sh
npm run test:integration
# Or use an existing installation:
FACTORIO_BIN=/absolute/path/factorio/bin/x64/factorio npm run test:integration
```

The default executable is `.cache/factorio/bin/x64/factorio`. The smoke test was run successfully with official Linux headless **2.0.72**. To download that exact build:

```sh
mkdir -p .cache/downloads
curl --fail --location https://factorio.com/get-download/2.0.72/headless/linux64 \
  --output .cache/downloads/factorio_headless.tar.xz
tar -xJf .cache/downloads/factorio_headless.tar.xz -C .cache
```

The test copies the mod into a fresh `.cache/integration/run-*` directory, creates its own map, binds game and RCON sockets to localhost, disables public/LAN listing, and uses a random RCON password. It stops its processes and retains the disposable save and engine log for diagnosis. It does not open or modify an existing game save or the user's Factorio configuration.

Smoke checks:

- Mod initialization on a new map and TCP RCON authentication/commands.
- Protocol discovery and safe rejection when no connected player exists.
- Repeated request IDs returning cached mutation results, and rejection of conflicting ID reuse.
- Deployment of the bundled Lua runtime, including blueprint and scheduler modules.
- Rejection of invalid Lua while keeping the previous runtime operational.
- Saving and reloading the map with the installed runtime and deduplication cache intact.

## Connected-client gameplay checks

```sh
FACTORIO_BIN=/path/to/factorio/bin/x64/factorio \
FACTORIO_CLIENT_BIN=/path/to/factorio/bin/x64/factorio \
npm run test:integration
```

The full game executable can serve both roles; `--start-server` runs it headlessly. Both executables must have matching versions. This mode launches a second client using its own configuration and connects it to the isolated test server, waiting up to 60 seconds for it to join.

The connected-client suite passed on **Factorio 2.0.77 with Space Age** using a separate Xvfb display. The existing desktop game stayed running throughout.

On Linux, isolate its display with Xvfb so an existing game stays undisturbed. Steam builds launched outside Steam may need their application ID set:

```sh
SteamAppId=427520 SteamGameId=427520 SDL_VIDEODRIVER=x11 \
FACTORIO_BIN=/path/to/factorio/bin/x64/factorio \
FACTORIO_CLIENT_BIN=/path/to/factorio/bin/x64/factorio \
FACTORIO_TEST_SPACE_AGE=1 \
xvfb-run -a npm run test:integration
```

`FACTORIO_TEST_SPACE_AGE=1` enables the installed Space Age, Quality, and Elevated Rails mods and adds mech armor/equipment checks. Omit it for base-game tests.

The gameplay fixture uses console commands to create an empty test area and give a known inventory. These fixture mutations exist only in the integration script. Harness actions run with `cheat_mode=false`, except for an explicit test of the opt-in cheat-mode boundary. Checks cover:

- Observation and normal crafting/building ingredient costs, including the last item in a stack.
- Partial inventory transfers and blocked-build item preservation.
- Normal mining, repair with cursor restoration, and walking.
- Blueprint capture/export/import, ghosts, physical ghost construction costs, cut/cancel, and nested book selection.
- Concurrent queued combat and walking, normal enemy damage, and queue revision conflicts.
- Native screenshot creation, a PNG schematic from observations, and live deployment stopping movement.
- Optional mech armor equip and equipment insertion/removal returning owned items.
- Character death during queued movement/combat stops controls and pauses pending work while status remains readable.

Evidence files are `factorio.log`, `observation.json`, `observation.png` (schematic), and `screenshot.png` (native rendering) under the printed run directory.

Without `FACTORIO_CLIENT_BIN`, gameplay checks are explicitly skipped. Headless Factorio cannot create a `LuaPlayer` through Lua, and `LuaPlayer.character` is `nil` when disconnected. A saved player alone does not substitute for a connected client; see the [Factorio 2.0.72 LuaPlayer API](https://lua-api.factorio.com/2.0.72/classes/LuaPlayer.html). A passing smoke test by itself does not establish gameplay correctness.

## Graphical session launcher

The launcher's `--niri` mode was separately exercised with Factorio 2.0.77 under an
isolated nested Niri compositor. The existing desktop Factorio window's focused
window ID and focus timestamp were identical before launch, after graphical
readiness, and after shutdown. No host focus restoration or input commands were
used. `niri-harness --no-window-wait` deliberately avoids its focus-restoration
path; the launcher checks the host's unfocused nested-window rule first.

The nested client uses its own Xwayland display with Factorio's
`[graphics] v-sync=false`. Native Wayland sprite loading stalled while the outer
window was offscreen; X11 with vsync still enabled loaded but failed multiplayer
catch-up. The final configuration entered the game in about eight seconds while
the original desktop game kept focus.

Verified through the CLI: named-session `doctor`, observation PNG `view`, a
640×480 native screenshot from the graphical client, save-before-stop with a
complete ZIP archive, and starting a copied save in another isolated session.
The credential file has mode 0600, sessions have private directories, and all
launcher verification processes were stopped. Current session data is stored
under `.factorio-harness/sessions/`, separate from disposable integration caches.
Initial launcher evidence remains in
`.cache/sessions/launcher-vsync-mui1n9aa/`; durable-path verification is in
`.factorio-harness/sessions/launcher-final-check/`.

Player identity is verified against a copied save before reporting readiness.
This installed Steam build, when launched outside Steam, ignored both minimal
and engine-generated isolated `player-data.json` username settings and connected
with an empty name. New-world launch and resuming that empty-name player's save
were verified. Resuming an arbitrary named Steam player's character is **not
verified**: the launcher rejects an identity mismatch and cleans up rather than
silently selecting another character. It reports the actual connected player
index so subsequent CLI calls do not assume player 1.
