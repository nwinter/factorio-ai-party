# Human players in the agents' world (branch `eng/players`)

The server stays closed to outside players (Nick's choice). Everything here is built and tested offline (mocked Lua,
fake RCON) and checked live with Nick's own client ("nick" on world n) as the stand-in. Nothing on this branch has
run in a real game yet; "How to check it live" below is the first run.

## What changed

| Piece | Where | What it does |
|---|---|---|
| Player log | `mod/.../players.lua` | Per human: builds (ghosts too), removals (`mined` by hand, by `robot` on their deconstruction order, `destroyed` by their character or a vehicle they drive), pending deconstruction and upgrade orders, big inventory moves (50+ items) with chests and vehicles. Trees, rocks, ore, corpses and ghosts are not "work" and are not logged as removals. |
| Humans | `runtime.lua` | A human is a LuaPlayer that is not a camera client (`pog-cam*`, `pog-director*`, spectators) and not an attached agent. Bots have no LuaPlayer, so their events never carry a player and are never logged. |
| Agent tools | `fh players [NAME]`, `fh vote`, `fh votes`, `fh restore NAME` | Also `fh call players|vote|restore` with the same words. Described in `agent/team.md` ("Human players"), tools only. |
| Guest group | `control.lua` | A player's first join (`on_player_created`) puts them in `pog-guest`. Fixed in control.lua, so a quarantined runtime cannot let a newcomer in with full permissions. Camera clients and names the operator trusted are exempt. |
| Votes | `votes.lua` (every kind: mute, unmute, kick, ban, trust), `tools/players.py` (the operator) | One vote module and one `fh vote` for eng/viewers2's mute vote and these. The harness decides each ballot when it is cast. Mute and unmute act at once; a carried kick, ban or trust waits for `players.py`, which runs `/kick` or `/ban` or the group change and closes the vote. |
| Stream | `chat.notice`, `tools/stream/model.py` | Every ballot, result and restore is a chat line from `vote` (the overlay's big chat lane; agents read it as chat). Joins and leaves are lines from `players` (the ticker), and so is a burst: 20 removals, or 20 deconstruction or upgrade orders, by one human within 5 minutes. The line gives the count, the time taken and the last position, at most one per player and kind every 2 minutes. Agents get it as unread chat, so they need not poll `fh players`. |
| Launch | `tools/start-team.sh` | `POG_PLAYERS=1` starts `tools/players.py watch` (log `runs/RUN/players.log`, results `runs/RUN/votes.jsonl`). `POG_PLAYERS_PROTECT=nick` keeps names from being kicked or banned. |
| Trusted names | `tools/start-team.sh`, operator `trust_names` | Every fresh run is a new save, so Nick's first join would land in the guest group. Right after the deploy, start-team.sh sets `POG_TRUSTED_PLAYERS` (default `nick`; empty for none) as names that join in the normal group. |

### Inventory moves

- Factorio has no event that says "player X took 200 plates from chest Y".
- A chest or vehicle opened by hand is snapshotted on `on_gui_opened` and compared on `on_gui_closed`. The chest's loss is the player's `took`, and its gain is the player's `put`.
- Ctrl-click transfers (`on_player_fast_transferred`) carry no counts. They are paired with the change of the player's main inventory in the same tick, whichever event comes first.
- Moves under 50 items are not kept.
- Not covered:
  - furnace and assembler outputs taken by hand;
  - items dropped on belts or the ground (`on_player_dropped_item`);
  - inserter, filter and recipe changes;
  - rotations.

  The guest group blocks the settings paste that would change recipes wholesale.

### Guest group: what a newcomer cannot do

I checked these against the 2.0 `defines.input_action` list. A name missing in a given version is skipped.

- **Planners:**
  - `deconstruct`, `upgrade`, `cancel_deconstruct`, `cancel_upgrade`.
- **Blueprints:**
  - import: `import_blueprint`, `import_blueprint_string`, `import_blueprints_filtered`, `import_permissions_string`;
  - library: `open_blueprint_library_gui`, `grab_blueprint_record`, `delete_blueprint_library`, `delete_blueprint_record`;
  - making one in game: `copy`, `alternative_copy`, `select_blueprint_entities`, `alt_select_blueprint_entities`, `setup_blueprint`, `setup_single_blueprint_record`, `reassign_blueprint`;
  - pasting: `activate_paste`.

  A blueprint built with shift (super-forced) marks whatever is in the way for deconstruction, so blueprints are out altogether.
- **Sabotage without a planner:**
  - `paste_entity_settings` (recipes across a row of assemblers);
  - `remove_cables`;
  - `flush_opened_entity_fluid`, `flush_opened_entity_specific_fluid`;
  - `use_item`: grenades, poison, cliff explosives. Raw fish is a capsule too, so guests cannot eat fish.
  - `toggle_driving` (ramming with cars and trains);
  - `destroy_item`, `destroy_opened_item`.
- **Team-wide state:**
  - research: `start_research`, `cancel_research`, `move_research`, `change_research_condition`, `set_research_finished_stops_game`;
  - trains: stops, schedules, interrupts, limits, coupling;
  - launches: `launch_rocket`, `set_rocket_silo_send_to_orbit_automated_mode`;
  - platforms: create, delete, rename;
  - `send_spidertron`, `toggle_artillery_auto_targeting`;
  - logistic groups and network names;
  - map tags.
- **Admin:**
  - `add/delete/edit_permission_group`, `admin_action`, `change_multiplayer_config`, `map_editor_action`, `toggle_map_editor`, `cheat`, `spawn_item`.

A guest can still do the following:

- **Mine by hand.** Factorio cannot allow mining ore and trees but not buildings. Hand-mined buildings are logged, and `restore` puts their ghosts back.
- **Shoot.** Area damage can hit the team's buildings, which are logged as `destroyed`.
- **Take items from chests.** These are logged as moves.
- **Rotate, set filters, and build.** Builds are logged. A guest's ghosts are harmless, since without planners they cannot mark anything for removal.

### Votes (one module, merged with eng/viewers2)

eng/viewers2 built `fh vote mute|unmute|list` in audience.lua, deciding in the game. This branch had `fh vote kick|ban|trust`, with ballots in the game and the tally in `tools/votes.py`. Both registered a `vote` action, so one would have replaced the other.

They are now one module, `votes.lua`, and one command:

- `fh vote [yes|no] mute|unmute|kick|ban|trust NAME "reason"` opens a vote or adds a ballot. `fh vote list` (or `fh votes`) shows open and recent votes and muted viewers.
- Mute and unmute name a viewer; kick, ban and trust name a human player.
- A reason is required to open a vote, or for a yes from the CLI. `-` reads it from stdin.
- **Decided when cast (as on eng/viewers2):**
  - yes from more than half the active agents carries it;
  - no from more than half fails it;
  - ballots of agents who went quiet stop counting.
- **Who is active:** a bot or attached agent whose own last request, or `fh sleep` poll (`sleep_check`), is within 10 minutes. The voter always counts.
  - Other peeks do not count. The overlay peeks at every bot's status every few seconds, which on eng/viewers2 made every bot look active forever.
  - Players who are not agents (Nick) never count; eng/viewers2 counted every non-director player.
- **From this branch:**
  - one open vote per kind and name;
  - 10 minutes open, then `expired` (it may open again at once);
  - after a vote is decided, the same kind on the same name waits 5 minutes;
  - `fh vote no` votes against.
- **Results:**
  - Carried mute or unmute acts at once: the muted list stays in audience.lua, where `viewer_say` refuses those viewers, and `viewers.py` reads it from operator `votes`.
  - A carried kick, ban or trust waits as `carried`. `tools/players.py` reads `votes_pending`, runs it, and closes it with `vote_close` as `done`, or `cancelled` for a protected name.
- **Lines:** every ballot and result is a notice from `vote` (eng/viewers2's wording) on the stream's ticker. Player joins, leaves, bursts and restores are notices from `players`.
- **`tools/votes.py` is gone:** nothing in Python tallies votes any more. The decision lives in one place, in the game.

### Restore

`fh restore NAME [--args '{"minutes":30}']` (any agent, no vote):

1. Cancels every pending deconstruction and upgrade order the player placed.
2. For each removal in the window that is not yet restored:
   - if the same entity or its ghost stands there: `already`;
   - if a manual ghost can be placed there (`can_place_entity` with `build_check_type = manual_ghost`): it places an `entity-ghost` with the same name, direction and quality, and `expires = false`. It keeps the assembler recipe and the underground belt input/output;
   - otherwise (something else stands there now): `blocked`.
3. Ghosts are build orders and nothing is created from nothing. Construction robots fill them from logistic storage, and agents can fill them with `revive_ghost` or `construct`.

Each removal is restored once, so a second restore places nothing new.

Two things I could not verify without a live game:

- whether `create_entity{name='entity-ghost', type='output'}` sets an underground belt ghost's direction;
- whether `set_recipe` works on an assembler ghost.

Both are wrapped so a failure only loses the setting. Check them in the live test below.

## How to check it live

This needs a deploy first: the new control.lua and the runtime (see "What I need" in the final message).

1. **Demote yourself.** Nick is an existing or trusted player on world n (`POG_TRUSTED_PLAYERS`), so his group does not change by itself. Run `python3 tools/players.py --world n guest nick`, then try a deconstruction planner in the client. It should be refused. Run `python3 tools/players.py --world n trust nick` to undo it.
2. **Watch the log.** In the client, place 5 belts, mine 2 by hand, mark one machine with the planner (while trusted), and take 100 plates out of a chest. Then run `bin/fh players` as any agent, or `python3 tools/players.py --world n show`. It should list nick with `built count=5`, `removed how mined=2`, `pending_orders deconstruct 1`, and a move with `took iron-plate=100`.
3. **Restore.** Run `POG_WORLD=n bin/fh --bot <bot> restore nick`. The marked machine should no longer be marked, and ghosts should appear where the 2 belts were.
4. **Vote.** With three bots active, two run `fh vote kick nick "test"`. The second ballot prints a `#N kick nick carried` notice. Then `python3 tools/players.py --world n once --dry-run` should print "would be carried out". Run it without `--dry-run` to be kicked for real. To check the lines without the kick, set `POG_PLAYERS_PROTECT=nick`: the vote closes as cancelled.
5. **Mute.** Two bots run `fh vote mute testviewer "test"`. Then `python3 tools/audience.py --world n viewer testviewer hi` should come back `dropped: muted`.
6. **Guest on first join.** On a fresh smoke world (not a, b, c, n), a client joining as a new name should be in `pog-guest` (`fh players` shows `group guest`).

## Console audit (eng/broker, merged here)

This branch merges eng/broker, which goes into main at the 17:00 shift change.

- `tools/players.py`'s operator dispatches use the stream service's request form, so the audit counts them as harness requests and does not log them.
- `/kick`, `/ban` and the other moderation commands (`/unban`, `/mute`, `/whitelist`, `/promote`, ...) are labelled `moderation` and listed one by one in the stop-team audit. Each one there should match a carried vote in `runs/RUN/votes.jsonl`.
- With the broker on, agents can only send harness requests for their own bot, so a moderation command can only come from the operator.

## Opening the server later (not done)

### Now

- `start-server.ps1` binds the game to `127.0.0.1:<port>` and RCON to `127.0.0.1`. Only clients on the box (the camera clients, Nick's desktop shortcut) can join.
- `server-settings.json`, from `new-instance.ps1`, has:
  - `visibility` public false, lan false;
  - `game_password` empty;
  - `require_user_verification` false;
  - `max_players` 0 (no limit);
  - `afk_autokick_interval` 0;
  - `allow_commands` admins-only;
  - `only_admins_can_pause_the_game` true.

### Network

Factorio is UDP only, on port 34197 by default (wiki "Multiplayer"). The box sits behind the home router (<windows-box-ip>).

1. **VPS UDP relay (recommended).** It keeps the home IP private.
   - A small VPS with a public IP runs WireGuard to the box. It forwards UDP 34197 into the tunnel to the box (iptables DNAT plus MASQUERADE, or nginx `stream { server { listen 34197 udp; proxy_pass <box wg ip>:<port>; } }`).
   - The server's `--bind` changes from `127.0.0.1` to the box's WireGuard address. RCON stays on `127.0.0.1` always.
   - Costs:
     - one more hop of latency;
     - the server sees every player arrive from the VPS address. Factorio's bans and whitelist are by name, so that is fine; per-IP limits are not.
2. **Router port forward.** UDP 34197 to the box. It is the simplest option, but it exposes the home IP and needs the router not to randomize source ports.
3. **Invite-only virtual LAN.** Tailscale or similar, with only invited players on it. It is the closest to today's closed server and needs no public port. Each player installs the client.

### Server settings

| Setting | Value | Why |
|---|---|---|
| `game_password` | set; give it to invited players | the first gate |
| `require_user_verification` | `true` | names are factorio.com accounts, so kicks, bans and the whitelist stick to a person. The camera clients then need real accounts or tokens, or the whitelist has to admit them some other way. Test this before relying on it. |
| `--use-server-whitelist true --server-whitelist FILE` | camera clients, nick, invited names | `/whitelist add NAME` at runtime; an empty whitelist admits anyone (wiki "Console") |
| `--server-banlist FILE` | a file kept with the instance | bans survive restarts; `--use-authserver-bans` also reports them to factorio.com |
| `max_players` | camera clients (3) plus the human slots | the camera clients count as players |
| `ignore_player_limit_for_returning_players` | `false` | a full server stays full |
| `afk_autokick_interval` | minutes, e.g. 15, once camera clients are known to be exempt | the camera clients are idle by design; test first, or keep 0 and rely on kick votes |
| `visibility.public` | `false` while invite-only | public listing needs `username` plus `token` |
| `allow_commands`, `only_admins_can_pause_the_game`, `server-adminlist.json` | `admins-only`, `true`, Nick only | never a guest |

Other things to settle before opening:

- **Mod download.** Every client needs `agent-harness_0.1.0` exactly. It is not on the mod portal, so guests cannot download it in the game's join dialog. Publish it (private or unlisted), or hand out the zip.
- **Camera names.** The guest exemption and the player list match camera clients by name pattern (`pog-cam<digits>`, `pog-director<digits>`). With a public server, someone could join as `pog-cam9` and be treated as a camera: not a guest and not in `fh players`. The whitelist closes that; an exact name list in `control.lua` and `cameras.lua` would too.
- **Chat.** Human chat reaches every agent as chat (`nick: ...`). It needs the same filtering the viewer relay has: rate limits, length caps, and the injection check from eng/viewers.
- **Bandwidth.** The home uplink carries the stream already; set `max_upload_in_kilobytes_per_second` if guests make the stream stutter.

## Tests

- **`lua tests/players.lua` (harness):**
  - the log: builds, each kind of removal, orders, moves (chest GUI and both orders of ctrl-click);
  - the read's window and errors;
  - votes.lua on players: errors, open, against, a repeated ballot, failed by a majority against, cooldown, trust carried, `votes_pending`, `vote_close`, expiry and reopening;
  - restore: cancelled, ghosts with settings, already, blocked, nothing twice;
  - the operator group change;
  - join and leave lines.
- **`lua mod/tests/control_test.lua`:**
  - the guest group is created with the planners and import denied;
  - a newcomer joins it; camera and trusted names do not;
  - the new events are forwarded.
- **`lua mod/tests/runtime_test.lua`:**
  - the four actions are described, and vote takes all five kinds;
  - `players` answers without a character;
  - a failed vote stops nothing.
- **`lua tests/viewers.lua` (from eng/viewers2):** the mute vote through the runtime, unchanged except that `ban` is now a kind (the bad kind is `poke`) and a director's refusal reads `directors do not vote`.
- **`lua tests/bots.lua`:** the electorate: own requests and `fh sleep` polls count, overlay peeks do not.
- **`npm test`:** both branches' `fh vote` tests (mute, unmute and list; kick, no, trust, votes, players, restore), with words and through `fh call`.
- **`python3 tools/test_players.py`:**
  - the operator pass on a fake world: kick, ban, trust, protected, bad name, failed command, dry run;
  - the request form and the direct commands, the overlay lane, and the agent docs (tools only).
- **`python3 tools/test_resume.py`:** the start-team dry run lists player votes only with `POG_PLAYERS=1`.
