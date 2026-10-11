# Usage

## Sessions

`fh start` runs a private server plus a graphical Factorio client that joins it. Both use their own config, mods and saves, so your normal Factorio setup is left alone.

```sh
fh start                          # session "default"
fh start --space-age --name exp   # another, independent world
fh start --save ~/saves/base.zip  # play a copy of an existing save
fh start --headless               # server only: no character, for deploys and diagnostics
fh doctor                         # can the character be controlled?
fh stop-session exp               # save, verify the ZIP, stop this session's processes
```

- Commands go to the `default` session unless you pass `--session NAME`.
- Sessions live in `.factorio-harness/sessions/` inside this repository. A name can be used once. To continue a world, start a new session with `--save` pointing at the save `stop-session` printed.
- Factorio is found in the usual Steam locations. Otherwise use `--factorio PATH` or `FACTORIO_BIN`.
- The client opens as a normal window. It stays usable for things without an action, such as respawning or complex GUIs.
- Known issue: outside Steam, the client joins with an empty player name. `--save` therefore rejects saves whose first player has a name.

### Niri isolation (optional)

On the [Niri](https://github.com/YaLTeR/niri) compositor, `--niri` (on `start` or `connect`) runs the client inside an unfocused nested Niri window instead, so launching never steals desktop focus. It needs `niri-harness` on your `PATH` and a window rule in your Niri config:

```kdl
window-rule {
    match app-id="niri" title="^niri$"
    open-focused false
}
```

`fh start` refuses to launch with `--niri` if the rule is missing. Set `FH_NIRI=1` to make `--niri` the default.

## Your own server

Use this when you host the game yourself:

```sh
fh install --mods ~/.factorio/mods   # then enable agent-harness and load the save once
export FACTORIO_RCON_PASSWORD=...     # or FACTORIO_RCON_PASSWORD_FILE
factorio --start-server save.zip --rcon-bind 127.0.0.1:27015 --rcon-password "$FACTORIO_RCON_PASSWORD"
```

- Join with a graphical client; the agent needs a living, connected character.
- Commands control player 1 unless you pass `--player N`.
- RCON has operator rights, so keep it on localhost.

## Running actions

```sh
fh call walk --args '{"direction":"east","ticks":60}' --wait
fh call status
```

- Arguments go in `--args JSON` or `--args-file F`. `fh describe` lists every action's arguments.
- Timed actions return as soon as the game accepts them. `--wait` blocks until the action finishes. It works with `walk`, `move_to`, `mine`, `build_path`, `construct`, `shoot`, `pickup`, `repair` and `wait_until`, and with `collect`, `rearm`, `refuel` or `feed` when a `radius` is given.
- With `--wait`, the command exits nonzero unless the action ended successfully (so `move_to` ending `arrived_near` counts as a failure), or when the wait times out. The wait lasts until the action's own end tick (at least 30 s, at most 15 min) unless `--wait-timeout MS` says otherwise.
- A timed-out wait is not a finished action. The reply has `error.code` `wait_timeout`, `timed_out: true` and `still_running` (the action's kind and end tick) and no `completion`. The action keeps running in game; a new character action would interrupt it. `fh wait` blocks until the character is idle again and reports the last outcome.
- Ctrl-C does not stop an action the game already accepted. `fh call stop` does.
- Output is compact tables meant for reading. Use `--format json` for programs.

## The in-game queue

A queue plan runs inside the game, with no CLI round trip between steps:

```json
[
  {"action":"shoot","args":{"auto":true,"radius":24,"ticks":300},"wait":false},
  {"action":"walk","args":{"direction":"west","ticks":90}},
  {"action":"wait_until","args":{"until":"no_enemies","radius":24}}
]
```

```sh
fh queue submit --file plan.json
fh queue status
fh queue edit --args '{"expected_revision":7,"index":1,"remove":1,"steps":[]}' # drop the next pending step
fh queue cancel          # add --args '{"clear":false}' to keep pending steps
fh queue resume
fh queue repeat --file plan.json
```

- `"wait":false` lets a step overlap the next one, for example shooting while walking.
- `wait_ticks` only works inside a queue. `wait_until` is also a direct timed action: `fh call wait_until --args '{"until":"researched","technology":"automation"}' --wait`.
- A failed step pauses the queue. Use `on_fail` (`abort`, `skip`, `goto:<label>`) and `guards` to handle failures instead.
- `queue edit` needs the current revision, so you can't accidentally edit a plan that has already moved on.
- A direct call that moves or acts as the character pauses the queue. Reads and actions like `craft` or `research` don't.

## Retries

- A dropped connection reports `outcome_unknown`. The CLI never replays the action automatically.
- Pass `--id ID` on a call to make retries safe. Repeating the same call with the same ID returns the cached result instead of running it again. The game keeps the last 256 results.
- Bridge sessions don't cache results, so a retry there runs the action again.
- Some actions, such as transfers, can partly succeed. Check the counts in the reply.
- `--journal FILE.jsonl` records every request and reply.

## Rules

Gameplay actions use the same mechanics as a human player: items come from the inventory, and reach and time apply. Nothing spawns items, teleports, or reveals the map.

Some actions work at a distance, the way a player can through remote view:

- `configure`, `requests` and `launch` in visible chunks
- ghosts and deconstruction marks in charted chunks

Not supported yet: vehicles, rails, circuit editing, and fluid transfers.

## Bots

A bot is a character the harness drives without a LuaPlayer or a client, so many agents can share one world. It plays by the same rules as a player's character (walking, mining and crafting time, reach, inventory, no free items).

```sh
# operator only (RCON), never through dispatch:
/silent-command rcon.print(remote.call("agent_harness","bot_create","astra"))   # {ok, bot={name,unit_number,position,index}}
/silent-command rcon.print(remote.call("agent_harness","bot_remove","astra"))   # the character dies; its corpse keeps the items
/silent-command rcon.print(remote.call("agent_harness","bots"))                 # name, index, alive, position, dead_until_tick

fh --bot astra call walk --args '{"direction":"east","ticks":60}' --wait        # or FH_BOT=astra; not with --player
fh --bot astra call status                                                      # bot=true, name, dead_until_tick, deaths
```

- Names match `[a-z][a-z0-9_-]{0,15}` and are unique (also against player names).
- A new bot gets the freeplay starting items and its own spot on rings around the spawn point, at least 2 tiles from every other bot.
- Every action works for bots. Building places directly (the item is consumed, reach is checked); tiles and blueprint pastes need no cursor (pastes cannot flip).
- A bot keeps the chunks within about 48 tiles of it charted and visible, as a player's character does (refreshed every second; charting takes up to ~40 ticks, so a bot that just arrived somewhere new may need a moment).
- Death ends the bot's action and queue step with outcome `died`. It respawns at its spawn spot after 600 ticks with the freeplay respawn items; `status` reports `dead_until_tick` meanwhile. Mining its corpse takes the items back.
- The server's `auto_pause` stops the game while no client is connected; keep a director client connected while bots play.
- Cost check (operator): `remote.call("agent_harness","profile_ticks",600)` times the harness tick for 600 ticks and writes the average to the server log (`agent-harness tick average ...`). Nine bots: about 0.05 ms per tick idle, 0.26 ms with all nine pathfinding at once.

## Profiles, speech bubbles, cameras

- `profile` sets your `display_name` (1..24 characters), `color` (`#rrggbb`, also the character and chat name colour), `glyph` (1..2 characters, an emoji or letters) and `motto` (0..80). With no arguments it reads the profile.
- `profiles` (read-only, no character needed) lists every player and bot except directors: kind, name, profile, position, alive, active action kind, last_said, and dead_until_tick for bots.
- `say` also draws the text over the speaker's character in its colour, wrapped at about 40 characters, for 8 s or until it speaks again. A person typing in the game chat gets a bubble too.
- Director cameras (operator only): `remote.call("agent_harness","camera", json)` with `{"player":1,"follow":"astra","zoom":0.8}` or `{"player":1,"position":{"x":0,"y":0},"smooth":false}`; `{"player":1,"release":true}` stops following. The player becomes a spectator once (its character is removed), and its view eases toward the target every tick, jumping when the target is over 200 tiles away. `remote.call("agent_harness","cameras")` and the read action `cameras` list them. An attached agent cannot be made a director.
- Directors: players that ever were cameras, spectators, and players named `pog-cam<N>` or `pog-director` (the camera clients, even before their first camera call). They never appear in `profiles`, and `say` lines are printed only to other players (camera views show the bubbles, not the chat console). A camera's view hides the GUI (minimap, research, side menu, quickbar, shortcut bar, crafting queue, alerts, tool bar, hotkey hints) but keeps entity info; if a camera player comes back with a character (a reconnect), it is made a spectator again within a tick, and its view settings are re-applied every 5 s.

## Live reload

```sh
fh deploy   # bundle runtime.lua and its sibling modules, validate, swap in
fh watch    # deploy on every change
```

- An invalid deploy is rejected, and the old code keeps running.
- The deployed code is stored in the save and takes priority over the mod's `runtime.lua`. For an existing save, edits only take effect after a deploy.
- A runtime error quarantines the runtime. Read-only calls still work until a fixed deploy succeeds.
- Module top-level code must not touch the game. Persistent state goes in `storage.agent_harness`.
- Changing prototypes or `control.lua` still needs a game reload.
