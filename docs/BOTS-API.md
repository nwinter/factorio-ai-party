# Bots, profiles, bubbles and cameras: interface contract

Shared contract for the harness work (branch `eng/bots`) and the overlay/director work (branch `eng/overlay`).
Goal: 7+ AI agents in one world without one graphical client per agent; a watchable stream driven by 2-3
spectator "director" clients.

## Bots (script-driven characters)

- A bot is a `character` entity on force `player` created by the harness, not attached to any LuaPlayer.
  It follows exactly the same survival rules as a player character: real walking/mining/crafting time, reach,
  inventory, no free items. It starts with what a newly joined freeplay player gets
  (`remote.call("freeplay","get_created_items")` when that interface exists, else iron-plate 8, wood 1, pistol 1,
  firearm-magazine 10, burner-mining-drill 1, stone-furnace 1), next to the spawn point.
- Operator-only creation (not reachable through `dispatch`, so agents cannot spawn bots):
  `remote.call("agent_harness", "bot_create", name)` -> JSON `{ok, bot={name, unit_number, position}}`;
  `bot_remove(name)` drops it (character dies, corpse keeps items). Names: `[a-z][a-z0-9_-]{0,15}`, unique.
- Addressing: dispatch requests gain an optional `bot` string. `{bot="astra"}` targets that bot; `player`
  keeps working for real players. A request may carry one of them, not both. CLI: `fh --bot NAME ...`
  (and `FH_BOT` env var), mutually exclusive with `--player`.
- Every gameplay action that works for players works for bots (the runtime gets a body/proxy that exposes the
  LuaPlayer/LuaControl surface the handlers use, backed by the character; LuaPlayer-only calls such as cursor
  building go through the existing direct-placement path, which consumes the item and checks reach).
- Death: a bot whose character dies respawns at the spawn point after the normal respawn delay (600 ticks), with
  an empty inventory like a player; its corpse keeps the items. `status` reports `dead_until_tick` meanwhile.
- `status` for a bot includes `bot: true`, its name, position and the usual fields.
- The turn clock (clock.lua) treats active bot actions as work in progress like player actions.

## Profiles (agent-chosen identity)

- Action `profile` (any player or bot, about itself): optional `display_name` (1..24 chars),
  `color` ("#rrggbb"), `glyph` (1..2 characters: an emoji or letters, shown as the avatar), `motto` (0..80 chars).
  With no arguments it returns the current profile. Applies the color to the character (and chat name colour).
  Optional `avatar` (branch eng/art): `{base, helmet, visor, emblem, accessory, backdrop, accent}`, every field
  optional, values from fixed lists (see `docs/ART-NOTES.md`); `false` clears. `profiles` rows carry it as `avatar`
  (absent when unset); renderers draw a default from name and colour.
- Read action `profiles`: every player's and bot's profile plus `kind` ("bot"|"player"), `name`, `position`,
  `alive`, `active` (current action kind or false), and `last_said` {text, tick}. This is what the overlay polls.

## Speech bubbles

- `say` (existing) also draws the text above the speaker's character with `rendering.draw_text`
  (wrapped to ~40 chars per line, speaker colour, scaled for readability at normal zoom) for 8 s or until they
  speak again. Bots can `say`; their messages appear in the game chat as `name: text` like players'.

## Cameras (director clients)

- A director is a real connected player whose client exists only to be captured by OBS.
- Operator-only: `remote.call("agent_harness", "camera", json)` with `{player=index, follow=bot_or_player_name |
  position={x,y}, zoom=0.3..4, smooth=true}`. The harness switches that player to the spectator controller once and,
  every tick, eases its view toward the target (no teleport jumps unless the target is >200 tiles away).
  `{player=index, release=true}` stops following. Read: `cameras` -> current targets.
- Directors never count as agents: they have no character and are ignored by the turn clock and by `profiles`.

## Overlay / director service (Mac side)

- Polls `profiles`, `chat` (peek), operator score (tools/pog.py score) and per-bot `status` every 2-5 s.
- Chooses camera targets: main camera on the "most interesting" agent (recent build/mine/craft activity,
  combat, research completion credit, chat), minimum dwell ~20 s; secondary cameras on the next two.
  When two agents are within ~40 tiles, frame both (midpoint, zoomed out).
- Serves the overlay page (OBS browser source) and a JSON/SSE feed: agent cards (glyph avatar on colour,
  display name, model label, role, current action, alive/thinking/idle, location), chat feed with avatars and
  timestamps, research progress and recent milestones, production sparklines, alerts (attacks, low power, deaths).
  Model labels come from a run config file (name -> model, harness), not from agents.
