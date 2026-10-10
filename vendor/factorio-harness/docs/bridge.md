# Client bridge

The client bridge lets an agent play on a multiplayer server that does not run the `agent-harness` mod and does not expose RCON, such as a friend's or a community server. It is loaded into **your own Factorio client**. The agent's commands become the same input actions that the client's GUI sends, so the server sees a normal player. Nothing is installed or changed on the server.

Only use it where automated play is allowed. Many servers forbid bots. Ask the operator first.

## How it works

```text
fh (host)  ──JSON lines over a private Unix socket──►  libfh-bridge.so inside your Factorio client
                                                         ├─ reads game state between ticks
                                                         └─ stages normal InputActions
                                                                   │ the client's own multiplayer connection
                                                                   ▼
                                                             unchanged server
```

Factorio runs the same deterministic simulation on every peer and synchronizes only player input. Client-only code that changes game state therefore desyncs. The bridge never writes game state. It only:

1. **Stages input actions** through `PlayerInputSource::process`, the virtual function the GUI uses. The client's permission checks, latency handling, and network path all still apply.
2. **Reads state** on the game-update thread, inside the input flush between ticks. Reads use the engine's own accessors where possible, for example controller and entity virtual functions. It never calls a function that creates or mutates game objects. For example, it walks the chunk table itself instead of calling `Surface::getChunk`, which would create missing chunks.

It is an `LD_PRELOAD` library with no dependencies. At load time it checks the executable's GNU build ID against the builds it was derived from. It then resolves local symbols from the executable's `.symtab` and replaces two slots of `PlayerInputSource`'s vtable:

- `flushActions(bool, MapTick)`: once the connection is confirmed as multiplayer (a `NetworkInputListener` is attached), it runs queued commands and timed controls, then calls the original.
- `process(InputAction&&)`: arbitrates between you and the agent. While the agent walks, the GUI's periodic "no key pressed: stop walking" is suppressed, and pressing a movement key hands control back to you. While the agent mines, mouse-hover selection and mine-button release are suppressed. Clicking to mine yourself takes over.

Payloads that are not plain data, such as `Build` and `CursorTransfer`, are constructed by the engine's own network loader, `InputAction::loadConstructActionData`. The bridge supplies a byte stream that pads short reads instead of throwing, then rejects a payload that was short or has leftover bytes. No C++ exception is thrown across bridge frames. Prototype names are resolved from the engine's `PrototypeList<T>::indexToPrototype` tables.

## Using it

```sh
npm ci && npm run build && npm run build:bridge

# Try it on a private vanilla server (no harness mod), with RCON for inspection:
fh start --bridge --name trial

# Or join someone else's server:
fh connect --server 203.0.113.5:34197 --name mp \
  [--password-file server-password.txt] \
  [--player-data ~/.factorio/player-data.json] \
  [--mods /path/to/matching/mods] [--space-age]

fh --session mp doctor
fh --session mp observe --args '{"radius":16}'
fh --session mp call scan --args '{"radius":64,"types":"resource","limit":20}'
fh --session mp call walk --args '{"direction":"east","ticks":120}' --wait
fh --session mp call mine --args '{"x":70.5,"y":1.5,"ticks":600}' --wait
fh --session mp call craft --args '{"recipe":"iron-gear-wheel","count":4}'
fh --session mp call build --args '{"item":"burner-mining-drill","x":-68,"y":-53,"direction":"east"}' --wait
fh stop-session mp
```

`connect` launches a graphical client the same way `start` does (including `--niri`). It waits until the bridge reports a multiplayer game with a player. Use `--player-data` for servers that verify accounts: the file carries your Factorio username and token. It is copied privately (0600) into the session directory. The server password goes on Factorio's command line, which Factorio requires; other local users can see it in the process list. `stream`, `run`, `describe`, `doctor`, `observe` and `call` work with bridge sessions. `deploy`, `watch` and `view` need the harness mod and are rejected. A bridge can also be addressed directly with `--bridge-socket PATH`.

## Commands and outcomes

`fh --session NAME describe` lists the running bridge's interface.

| Action | Effect | Completion (`last.<kind>.outcome`) |
|---|---|---|
| `observe` | Tick, player, controller, position, main inventory, cursor, crafting queue, selection, active controls, and nearby entities | none |
| `scan` | Entities near the player or a point, nearest first, with resource amounts | none |
| `walk` | Hold a direction for `ticks` | `duration_elapsed` once the simulation shows the character standing; `human_input`, `stopped`, `not_started`, or `stop_unconfirmed` |
| `mine` | Select the entity at a position and hold the mine button | `target_mined` when the entity is gone; `miner_stopped` if it still exists (out of reach, inventory full); `duration_elapsed`; `not_started` |
| `build` | Pick up a main-inventory stack, click the world, clear the cursor | `built` when the stack count drops; otherwise `not_built` |
| `craft` | Queue hand-crafting | Check `crafting_queue` and the inventory: the engine silently skips unaffordable crafts |
| `stop` | Release movement and mining | immediate |

A reply confirms that the action was **submitted**. Effects apply after the multiplayer input latency, and the server may still reject them. That's why timed controls finish only when the client's own simulation shows the result, and `--wait` reports that observed outcome. If the connection drops mid-request, the CLI reports `outcome_unknown` and never replays the action.

Behaviour to know about:

- The character walks in 8 directions. Arbitrary vectors are accepted, and the engine snaps them to the nearest direction. Walking speed is about 0.15 tiles per tick.
- Mining reach is about 2.7 tiles for resources and larger for other entities. Out of reach, the outcome is `miner_stopped`.
- Entity positions are centres; `scan` reports them directly. `build` positions follow the engine's placement rules. For example, a 2×2 drill is centred on a tile corner, and drills only fit over resources.
- If the client crashes mid-walk, the server keeps applying the last input until it drops the peer, about 10 seconds. The same holds for any crashed client.

## What was verified

All verification used Factorio 2.0.77 (Linux, Steam build `3d00bbaf…`) against private vanilla servers started for the test, with RCON available as an independent authoritative view:

- Walking, crafting, mining rocks, trees and ore, and building a burner drill on coal, all confirmed on the server's own state. Client-observed position and inventory matched the server exactly.
- 120 randomized walk, craft, stop and mine commands in two minutes: no errors and no desync. Across all sessions, neither server nor client logs contain a desync.
- Rejoin after killing the client with SIGKILL mid-walk: the new session gets fresh control state and stays in sync.
- A second, unmodified client could not join at the same time. This Steam build connects with an empty username unless it has a service token, and the server refuses duplicate names. Other peers' view is therefore evidenced by the server's authoritative state and by Factorio's own CRC desync detection, not by a second screen.

## Limits and future work

- **Pinned build.** Any other executable keeps the bridge inert (`bridge_status.inactive_reason`). Factorio's own types are not in the shipped debug info, so every structure offset (the `layout` namespace in `bridge/src/game.hpp`) was derived from the disassembly of the named engine function that uses it. `game.hpp` lists the source of each constant. To port to a new build, re-derive those constants from the same functions, then add the build ID.
- **Player inventory only.** Inserting into or taking from entities (fuel, furnace output) is not implemented. The GUI's Ctrl-click path depends on the hovered selection. The GUI re-selects whatever the idle mouse covers, and it sends that update outside `process`, so the bridge cannot yet arbitrate it.
- Only the main inventory is read. Armor, guns and ammo slots, entity inventories, research, and tiles are not observed yet.
- One agent per client. When a human uses the same client, their movement and mining input take precedence, and a build clears their cursor.
- Linux x86-64 only. The bridge uses `LD_PRELOAD`, ELF symbol tables, and the Itanium C++ ABI.

## Developer mode

`FH_BRIDGE_DEVELOPER=1` adds `raw` (submit any action from its hex network payload through the engine loader), `peek`, and `pointers`. `FH_BRIDGE_CAPTURE=file.jsonl` logs every action that passes through `process`. Use them only on your own test sessions.
