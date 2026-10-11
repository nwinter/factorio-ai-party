# Harness3 notes: the shake2 harness bugs (branch eng/harness3)

Scope: the six bugs in `docs/studies/shake2.md` section 13, P2 item 10, with the evidence from section 7. All six are
fixed and covered by fake-engine tests. None is verified on world `live`: this session's permission mode denied every
`bin/fh` command (`bin/fh call status`, `bin/fh doctor`), so I could not deploy or create `h3-*` bots. The commands to
run are in "Live verification" below. `tools/pog.py --world live score` did work (tick 1132557, running).

## The bugs

| Bug | shake2 evidence (journals in `runs/shake2/*/journal.jsonl.gz`) | Cause | Fix | Test |
|---|---|---|---|---|
| `call inventory` unsupported | 17 calls failed with "unsupported action; call describe": Luna 5, Haiku 5, Sonnet 4, Grok 1, Gemini 1, Opus 1 | no such action | new read-only action `inventory`: `inventory` (main), `guns`, `ammo`, `armor`, `free` (status's `free=N/M` line), `crafting`, `warnings`; listed in describe | `mod/tests/runtime_test.lua`: contents, free line, clock line, a running walk keeps going, unknown arguments rejected |
| `describe.json` not greppable by `"name": "craft"` | Grok found nothing, decided the file was missing, tried to regenerate it | lines were `"craft": {...}` | `tools/describe-lines.py` writes `"craft": {"name": "craft", "args": {...}}`; both `grep '"craft"'` and `grep '"name": "craft"'` hit that one line; arguments sit under `args` because `scan` and others take an argument called `name` | `tools/test_describe_lines.py` (fake describe reply); also checked on shake2's real describe |
| `construct`: "Invalid PlayerIdentification" | Sol 04:53:22, `construct {"ticks":3600}` | `construction.lua` marked trees under ghosts with `order_deconstruction(force, p)`, where `p` is the bot (or map-view) proxy table | passes `real(p)`: the LuaPlayer, or nil for a bot | `tests/construction.lua`: the fake `order_deconstruction` rejects anything but a LuaPlayer or nil, as the engine does; the old line fails it |
| `shoot` "did not spend ammo" | Grok's own observes show it did: ammo slots 10 -> 8 after a 400-tick shoot, 12 -> 11 after 500 ticks | the compact `--wait` reply printed `last` (the previous move_to) instead of `last_combat`, and diffed only the main inventory while magazines sit in the ammo slots | CLI: a shoot wait prints `outcome` from `last_combat`, `action: shoot`, `ammo_used`; every wait's `inventory:` diff now covers main inventory plus ammo slots. Runtime: shoot records the ammo at the start, `last_combat.ammo_used` (whole magazines), ends with `out_of_ammo` when the slots empty, and refuses to start with no ammo | `tests/cli.test.ts` (compact shoot wait); `mod/tests/runtime_test.lua` (no ammo fails, ammo_used, out_of_ammo) |
| `observe scope=stock` without an item | Luna once, Muse twice: "item must be a known item name" | `stock.view` required `item` | without `item` it returns `items`: one line per item held in machine outputs and chests within `radius` (default 128), largest first, e.g. `copper-plate 200 in 1 entity (1 chest)`; `limit` 1..64 (default 16), `more`, and a note pointing at `item=NAME` | `tests/stock.lua` |
| `./shot` never delivers | "not delivered within 20 s" in shake1 and shake2 | (1) `start-team.sh` never started `tools/shot-sync.sh`; (2) a bot has no client, so `take_screenshot` got `by_player=nil` and every connected director rendered it into its own folder; (3) shot-sync watched `<ws>-client` folders, which team runs do not have | runtime: a bot's screenshot is rendered by the first connected director (else the first connected player), the reply names it (`client:`), no client is an error. `./shot` asks for `script-output/pog/<ws>/<name>.png`, makes the name path-safe, prints fh's error when the request fails, waits 30 s and names the client on a timeout. `shot-sync.sh RUN_DIR CLIENT_DIR...` routes `pog\<ws>\*.png` to `RUN_DIR/<ws>/shots/`, copying a file only once it was listed on an earlier pass. `start-team.sh` starts it for `<world>-client-cam1..3` (its pid goes in `stream-service.pid`, so `stop-team.sh` stops it) | `tests/bots.lua` (director chosen, player keeps own client, none connected fails); `tools/test_shot_sync.py` (fake ssh/scp box; the generated `./shot` wrapper with a fake `bin/fh`) |

Survival rules are unchanged. Shooting used real ammo before and after; the change only reports it, and a shoot with
empty ammo slots now fails instead of standing there. Screenshots render the bot's own position, which the bot keeps
charted.

## What players should do differently

- `./fh call inventory` works; it is a read and does not interrupt a running action.
- `./fh observe --args '{"scope":"stock"}'` lists what the factory holds; add `"item"` for places and a collect line.
- After `shoot --wait`, read `ammo_used` and the `inventory:` line (it includes the ammo slots now). `out_of_ammo` ends
  shooting early and exits nonzero.
- `grep '"name": "build"' describe.json` and `grep '"build"' describe.json` both return the action's line.
- `./shot NAME` is worth trying again in team runs once shot-sync runs; its failure message now names the client.

`agent/PLAYBOOK.md` is unchanged (eng/board edits the docs side); its "Look:" line could list `./fh call inventory`.

## Files touched

Harness (`vendor/factorio-harness`):
- `host/cli.ts`: `carried()` helper; `brief()` takes the action and reads `last_combat` for shoot; `ammo_used`; the
  `before` read uses `carried()`. Small hunks around `inventoryChange`, `brief` and `execute`.
- `mod/agent-harness_0.1.0/runtime.lua`: `stop_combat`, describe entries (shoot, inventory, stock), `handlers.inventory`
  (after `handlers.status`), `screenshot_client` + `handlers.screenshot`, `handlers.shoot`, the `reads` set,
  `construction_module{... real=real ...}`, one line in the combat loop of `M.tick_body`.
- `mod/agent-harness_0.1.0/construction.lua`: one line in `mark_obstacles`.
- `mod/agent-harness_0.1.0/kite.lua`: exports `ammo_count`.
- `mod/agent-harness_0.1.0/stock.lua`: `M.summary`, start of `M.view`.
- Tests: `tests/cli.test.ts`, `tests/construction.lua`, `tests/stock.lua`, `tests/bots.lua`, `mod/tests/runtime_test.lua`.

Outside the harness (the describe.json and ./shot bugs live there):
- `tools/describe-lines.py`, `tools/test_describe_lines.py` (new)
- `tools/shot-sync.sh` (new interface: `RUN_DIR CLIENT_DIR...`; the old `WS[=CLIENT_DIR]` form is gone, nothing called it)
- `tools/new-run.sh` (the `./shot` wrapper only), `tools/start-team.sh` (starts shot-sync), `tools/test_shot_sync.py` (new)
- `docs/SETUP.md` (the screenshot gotcha line)

Merge notes: eng/board (error lines) may also touch `host/cli.ts`; my hunks there are confined to `brief()` and the
inventory diff. eng/harness2 (cameras, name tags) works in `cameras.lua`/`profiles.lua`; I did not touch them and only
call `M.is_director`. I did not append to `docs/HARNESS-CHANGES.md` to keep merges small; this file is the record.

## Tests

- `npm test`: 90 pass, 4 fail. The 4 are `tests/bridge.test.ts` tests that open a Unix socket under `.cache/`; this
  session's sandbox refuses it (`listen EPERM`). They failed the same way before my first change (89 pass, 4 fail at
  780345f) and do not touch my code.
- Every `tests/*.lua` and `mod/tests/*.lua`: pass.
- `python3 tools/test_describe_lines.py`, `python3 tools/test_shot_sync.py`: pass.

## Live verification (to run; this session could not)

Run from the repo root on eng/harness3. Deploying replaces the runtime the other engineers loaded on `live`; their next
deploy replaces it again.

```sh
cd vendor/factorio-harness && npm run build && cd ../..
POG_WORLD=live bin/fh deploy
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","h3-a"))'

# inventory: main/guns/ammo/armor, free=N/M
POG_WORLD=live bin/fh --bot h3-a call inventory
# stock without an item: items list (empty note on a bare world)
POG_WORLD=live bin/fh --bot h3-a observe --args '{"scope":"stock"}'
# shoot: the bot starts with a pistol and 10 magazines; expect "action: shoot", ammo_used, and an inventory line with
# firearm-magazine-N when there was something to hit (0 used with no target in range)
POG_WORLD=live bin/fh --bot h3-a call shoot --args '{"auto":true,"ticks":120}' --wait
# construct over a tree: find one, place a ghost on it, construct; expect no PlayerIdentification error, mined>=1
POG_WORLD=live bin/fh --bot h3-a call nearest --args '{"type":"tree","limit":1}'
# TX,TY: the tree's position rounded to whole numbers (a stone furnace is 2x2; the bot starts with one)
POG_WORLD=live bin/fh --bot h3-a call place_ghosts --args '{"entities":[{"name":"stone-furnace","position":{"x":TX,"y":TY}}]}'
POG_WORLD=live bin/fh --bot h3-a call construct --args '{"area":{"left_top":{"x":TX-2,"y":TY-2},"right_bottom":{"x":TX+2,"y":TY+2}}}' --wait
# screenshot: needs the live director client connected (D:\pog\inst\live-client-director); expect "client: pog-director"
POG_WORLD=live bin/fh --bot h3-a call screenshot --args '{"path":"pog/h3-a/t1.png"}'
mkdir -p runs/h3test/h3-a/shots && tools/shot-sync.sh runs/h3test live-client-director   # Ctrl-C after t1.png arrives
ls runs/h3test/h3-a/shots/
tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_remove","h3-a"))'
```
