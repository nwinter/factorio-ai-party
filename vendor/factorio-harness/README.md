# Factorio harness

Let an AI agent play Factorio from the command line.

The agent runs `fh` commands such as `observe`, `move_to`, `mine`, `craft`, `paste` and `shoot`, and gets back readable results. A Lua mod carries out those commands inside the game, tick by tick, under survival rules. The character has to own every item it uses, stay within reach, and spend real game time. There's no teleporting and no free resources.

```sh
fh start                     # launch a private world with a graphical client
fh observe                   # what's around the character?
fh call move_to --args '{"position":{"x":40,"y":-12}}' --wait
fh call mine    --args '{"position":{"x":41.5,"y":-11.5},"ticks":300}' --wait
fh call craft   --args '{"recipe":"iron-gear-wheel","count":10}'
fh stop-session              # save and quit
```

## Install

You need Node.js 20+ and Factorio 2.0 (Space Age optional), on Linux.

```sh
npm ci && npm run build
npm link        # puts `fh` on your PATH
```

To use a server you already run, see [your own server](docs/usage.md#your-own-server).

## Usage

```sh
fh describe                      # every action and its arguments
fh call ACTION --args '{...}'    # run one; add --wait for timed actions
fh queue submit --file plan.json # let the game run a multi-step plan by itself
fh run --file plan.json          # or step through it from the CLI
fh stream                        # JSON lines in and out over one connection
fh view --out map.png            # schematic map of the surroundings
```

The character can move with pathfinding, and it can mine, craft, research, build, and lay out belts and pipes. It can also work with blueprints, run and analyse production, defend itself, and launch rockets to space platforms. `fh describe` is the full, authoritative list.

The [usage guide](docs/usage.md) covers sessions, the in-game queue, retries, and the rules the harness enforces.

## Multiplayer

Agents play in real multiplayer games, alongside people or other agents.

- **On a server you host,** install the mod on the server. Each agent then controls its own connected player, chosen with `--player N`. See [your own server](docs/usage.md#your-own-server).
- **On someone else's server,** the [client bridge](docs/bridge.md) plays through your own Factorio client, so the server needs no mod and no RCON. The server just sees an ordinary player. Only use it where the server's operator allows automated play.

```sh
npm run build:bridge
fh connect --server 203.0.113.5:34197 --name mp
fh --session mp call walk --args '{"direction":"east","ticks":120}' --wait
```

The bridge has a smaller action set, and it only works on Linux with the Factorio build it was made for (2.0.77, Steam).

## How it works

```text
agent ─ shell ─► fh (TypeScript) ─ RCON ─► agent-harness mod (Lua) ─► the game
```

Anything that has to happen every tick, such as walking, pathfinding, mining or fighting, runs in Lua inside the game. The CLI only carries commands and results. You can hot-swap the Lua runtime in a running game with `fh deploy`.

More in [architecture](docs/architecture.md) and [testing](docs/testing.md).

## Development

```sh
npm test                    # unit tests (needs lua)
npm run test:integration    # against a real Factorio
fh watch                    # redeploy Lua on every edit
```

## License

[MIT](LICENSE)
