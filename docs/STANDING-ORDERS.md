# Standing orders (design, eng/standing)

Goal: an agent sets up routine play once (restock, refuel, rearm, courier, feed labs, repair, build ghosts) and its
character keeps doing it whenever it has nothing else to do. The agent's own requests always come first.

## Measured: shifts 04 to 06 (`tools/idle_report.py`, from the agents' journals)

Idle: the character had no action running. Measured from every reply's clock line ("character idle Ns"), as merged
intervals. Agents that queue their work are rarely idle; agents that act one request at a time are idle most of
the shift.

| Agent | Character idle (04 / 05 / 06) | queue_submit | queue_repeat | guards | plan_run |
|---|---|---|---|---|---|
| Astra | 6% / 6% / 2% | 73 | 25 | 0 | 1 |
| Opus | 6% / 6% / 0% | 14 | 35 | 0 | 0 |
| Sol | 14% / 17% / 33% | 124 | 0 | 0 | 0 |
| Grok | 17% / 22% / 60% | 14 | 51 | 0 | 0 |
| Luna | 43% / 58% / 69% | 9 | 29 | 0 | 7 |
| Gemini | 35% / 47% / 72% | 0 | 5 | 0 | 1 |
| Haiku | 75% / 12% / 34% | 0 | 0 | 0 | 0 |
| Muse | 78% / 76% / 85% | 4 | 0 | 0 | 0 |
| Sonnet | 0% / 10% / 12% (few requests: 161 / 3,955 / 1,804) | 1 | 0 | 0 | 28 |

- Guards were never used. Waits: 66 wait_until in three shifts. Long idle stretches (2 min or more): Muse 115 min in
  shift05 (up to 13 min at a time), Haiku 107 min in shift04, Sonnet 24 min in shift05.
- The repeated hand work is moving items, mostly by single requests:
  - courier transfers: Gemini about 2,300 direct transfers (plates, intermediates), Muse about 2,500;
  - feeding labs by hand: Muse 639 of those were science packs, one request each;
  - refuel and feed: Opus about 1,200 feed steps, all inside repeating plans (the one agent that automated it);
  - rearm: Astra 400 ammo transfers in queued plans, Grok 93 by hand;
  - repair: 1,429 repair steps in queued plans.
- Repeating plans that worked were short loops (feed a row of machines, refill turrets). The failure mode is the
  one the operator saw: a loop that finishes, then nothing until the agent's next turn (Sonnet: a short plan, then 25 min).

## Design

**Orders.** Each agent has up to 6 standing orders, kept in the save (they survive shift changes):

```
order_set {name, steps, when?, priority 1-9 (with when), cooldown_ticks? (with when), interval_ticks? (default), max_ticks?}
order_remove {name}     orders_pause {seconds?}     orders_resume {hold_s?}     orders  (list with state)
```

- `steps`: the same steps as `queue_submit` (any player action, labels, on_fail), at most 32.
- With `when`: a triggered order. `when` takes the existing predicates (`ammo_below`, `item_count` on chests,
  `health_below`, `no_enemies`, `researched`...) plus three new ones: `ghosts_waiting {position, radius, at_least}`,
  `damaged {position, radius, fraction}` (our buildings under a health fraction, default any damage),
  `fuel_below {position, radius, count}` (burner machines: furnaces, drills, boilers, burner inserters). All read only
  what the player could see, like the existing ones.
- Without `when`: the default routine, run whenever no trigger holds (at most one default per agent), with
  `interval_ticks` (default 1800) between runs.

**When they run.** Only when the character is free: no direct action running, the queue empty and not looping, a
body on the map (not dead, riding or aboard), the agent in the game (a request of its own or an fh sleep poll in the
last 30 min, so a world left running between shifts does not play on for absent agents), and 20 s after the agent's own last character request or queue call
(`orders_resume {hold_s}` sets 0..600), so an agent acting step by step keeps its character between requests. Then
the highest-priority trigger that holds and is off cooldown runs, else the default. Between the rounds of a repeating
plan (Opus, shift13), triggered orders run too, and the default routine with `queue_repeat {orders: "all"}`
(`"none"` keeps every order out); the hold then counts from the agent's own last request, and the next round waits
for the order's run to end. An order runs as a plan in the
agent's own queue, marked with its name (`queue_status` shows `order`).

**Preemption.** Any request that drives the character (a direct action, `queue_submit`, `queue_repeat`, `plan_run`,
`queue_cancel`) stops a running order at once; `queue_edit` is refused while one runs. The order keeps its remaining
steps (an interrupted relative step such as `wait_ticks` is not repeated, as in a paused plan) and resumes when the
character is free again, if its trigger still holds. A holding trigger of higher priority also stops a running order
(the default counts 0), which resumes after. Reads, chat, crafting and board posts do not preempt.

**Status.** Every reply carries one `orders` line while orders exist (right after the clock line in compact output):
`orders: restock-ammo running (3 turrets below 20), step 2/5`,
`orders: waiting (1 trigger not holding; patrol next in 40 s)`, `orders: patrol waits for your move_to, resumes after`,
`orders: patrol resumes in 12 s (after your last action)`, `orders: paused (orders_resume)`, and for a failing order
`lab-feed failed 1/3: transfer: ...` or `lab-feed off after 3 failures: ... (order_set it again)`. Status (brief and
full) has `order {name, reason, step, steps}`; the stream overlay shows "auto: restock ammo" on the agent's card. The
operator's `idle_report` has `orders {set, running, reason, paused}`; `tools/idle_nudge.py` never nudges an agent
whose order is running, and its tell says how many orders are set.

**Limits.**
- Per tick: each agent's triggers are checked once a second, staggered by player index, one predicate per agent per
  check, radius at most 64, at most 16 chest positions. While the agent's own work keeps the character busy no
  predicate runs; while an order runs, only triggers of higher priority are checked.
- Hold: an order starts only after the character has been free for 20 s since the agent's own last character request
  or queue call (`orders_resume {hold_s}`: 0..600). An agent acting one request at a time keeps its character between
  requests.
- Agent plays: an order starts only if the agent made a request of its own (or an fh sleep poll) in the last 30 min.
  A world left running between shifts does not play on for absent agents; the agent's next request brings its orders
  back. A run already going finishes.
- Per agent: 6 orders, 32 steps each, one order running at a time. A run stops after `max_ticks` (default 3600, up
  to 18000). A trigger waits `cooldown_ticks` (default 600, at least 300) before it can fire again.
- Failures: a failed step (or a run over `max_ticks`) fails the run; an order that fails 3 runs in a row is switched
  off, with the reason in the status line on every reply; `order_set` with the same name switches it back on.
- A fault in the orders code stays in the agent's orders line; it never stops the runtime.
- Survival-fair: steps are the agent's own actions through the same handlers (walking, reach, inventory, crafting
  time). Nothing acts at a distance; nothing the agent couldn't do itself.

**Prompt (one paragraph in team.md).** Set standing orders for your routine jobs (turret ammo, lab packs, fuel,
courier runs, repairs, ghosts), so your character keeps working while you think; your own requests always come
first.

## v1 (eng/standing)

| Part | Where |
|---|---|
| Orders: state, calls, the once-a-second look, the line | `mod/agent-harness_0.1.0/orders.lua` |
| Runs in the agent's queue, preemption, run results | `scheduler.lua` (`run_order`, `order`, `cancel_order`, `order_result`) |
| `ghosts_waiting`, `damaged`, `fuel_below` | `conditions.lua` |
| Request path, `orders` line, status `order`, tick | `runtime.lua` |
| `idle_report` `orders` | `idle.lua`, `tools/idle_nudge.py` |
| Operator kill switch `orders_kill` | `orders.lua` (`M.operator`), `runtime.lua` (operator dispatch), `tools/orders_kill.py` |
| Compact output: the line after the clock | `host/format.ts`, `host/cli.ts` |
| Overlay "auto: name" | `tools/stream/live.py`, `tools/stream/model.py` |
| Prompt | `agent/team.md` |

Tests: `tests/orders.lua` (default and hold, preemption and resume, reads not preempting, triggers and cooldown,
priority takeover, queue calls, pause and resume, `max_ticks`, 3-failure switch-off, limits and argument checks,
per-agent, idle clock, the operator kill switch, describe), `tests/conditions.lua` (the new predicates),
`tests/format.test.ts`, `tools/stream/selftest.py`, `tools/test_idle_nudge.py`, and `npm test`. Next: measure again
with `tools/idle_report.py` after a shift with orders.

## Operator kill switch

```
python3 tools/orders_kill.py --world live on       # stop every running order; start none
python3 tools/orders_kill.py --world live status
python3 tools/orders_kill.py --world live off      # orders start again after each agent's hold
```

| | |
|---|---|
| Call | dispatch `{"operator": true, "action": "orders_kill", "args": {"on": true\|false}}`; no `on`: state only |
| Who | operator only (RCON); from an agent it fails as `unsupported action` |
| `on: true` | every agent's running order stops at once; no resume, no failure counted; nothing starts, triggers included |
| While on | every agent's `orders:` line is `orders: paused by the operator`; `orders` has `paused_by_operator: true` and each order's state `paused by the operator`; `idle_report` `orders.operator_paused`; `order_set`, `order_remove`, `orders_pause` work; an agent's `orders_resume` does not lift it |
| `on: false` | orders start again `hold` (20 s default) after the switch; a stopped order starts afresh |
| Reply | `on`, `since_tick`, `stopped` (agents whose order stopped), `agents_with_orders` |
| Persistence | world state: survives a runtime deploy and a save and restart |
| Ships with | a runtime deploy (`fh deploy`); no `control.lua` change, no client refresh |

## Live check (dev world `live`)

A test bot `so1`: a default routine (patrol), a trigger (a ghost waiting) that takes over, then a `move_to`
interrupt and the resume. A client must be connected so the game runs. About 5 minutes. From the repo root on a
checkout of `eng/standing`:

```
# 0. Build the CLI and deploy this runtime; the bot and the world
npm --prefix vendor/factorio-harness run build
POG_WORLD=live bin/fh deploy
export POG_WORLD=live FH_BOT=so1
python3 tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","so1"))'
POS=$(bin/fh call status --format json | python3 -c 'import json,sys; r=json.load(sys.stdin); p=r.get("result",r)["position"]; print(int(p["x"]), int(p["y"]))')
read X Y <<< "$POS"; echo "so1 at $X,$Y"
```

```
# 1. Default routine: walks east, waits, walks back
bin/fh call order_set --args '{"name":"patrol","interval_ticks":600,"steps":[{"action":"walk","args":{"direction":"east","ticks":120}},{"action":"wait_ticks","args":{"ticks":60}},{"action":"walk","args":{"direction":"west","ticks":120}},{"action":"wait_ticks","args":{"ticks":60}}]}'
sleep 3
bin/fh call queue_status
bin/fh call status --args '{"brief":true}'
```

Pass: the new bot has made no character request yet, so there is no hold and patrol starts within a second or two:
`queue_status` has `order: patrol` with reason `default routine`, its `orders:` line says
`patrol running (default routine), step k/4`, and brief status has `order` with name `patrol`. If the stream service
watches `live`, the overlay card for so1 shows `auto: patrol`. The 20 s hold is checked in step 3.

```
# 2. Trigger: a ghost 6 tiles east of the start; the order walks next to it, waits 30 s, steps one tile
bin/fh call place_ghosts --args "{\"entities\":[{\"name\":\"wooden-chest\",\"position\":{\"x\":$((X+6)),\"y\":$Y}}]}"
bin/fh call order_set --args "{\"name\":\"ghost\",\"priority\":6,\"cooldown_ticks\":600,\"when\":{\"until\":\"ghosts_waiting\",\"position\":{\"x\":$((X+6)),\"y\":$Y},\"radius\":4},\"steps\":[{\"action\":\"move_to\",\"args\":{\"position\":{\"x\":$((X+6)),\"y\":$((Y+2))}}},{\"action\":\"wait_ticks\",\"args\":{\"ticks\":1800}},{\"action\":\"move_to\",\"args\":{\"position\":{\"x\":$((X+6)),\"y\":$((Y+3))}}}]}"
sleep 8
bin/fh call orders
```

Pass: within a few seconds `ghost running (1 ghosts), step 1/3` (or `2/3`), and in `orders` patrol's state is
`resumes when free` (a holding trigger of higher priority took over the running default). If patrol was between runs,
ghost simply starts; that also passes. If `place_ghosts` refuses the spot (a tree, water), use `$((X+8))` in both
commands. Go on to step 3 within 30 s, while ghost waits.

```
# 3. Interrupt: the bot's own move_to stops the order at once; it resumes 20 s after the move ends (the hold)
bin/fh call move_to --args "{\"position\":{\"x\":$((X-5)),\"y\":$Y}}"
bin/fh call queue_status
bin/fh wait
bin/fh call orders
sleep 25
bin/fh call queue_status
```

Pass: the `move_to` reply's `orders:` line says `ghost waits for your move_to, resumes after`. The `queue_status`
right after it shows no `order` and no pending steps. After `fh wait`, the line says `ghost resumes in N s (after
your last action)`, N up to 20. After the sleep, `queue_status` has `order: ghost` with reason `resumed` and
`steps: 1` (the interrupted 30 s wait is not repeated, as in a paused plan; the last move_to is left; `steps: 3` if
the interrupt came before the bot reached the ghost), and the bot walks back next to the ghost.

```
# 4. Operator view, kill switch, pause, and cleanup
python3 tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","dispatch","{\"id\":\"so-check-1\",\"operator\":true,\"action\":\"idle_report\",\"args\":{}}"))'
python3 tools/orders_kill.py --world live on
bin/fh call queue_status
sleep 30
bin/fh call orders
python3 tools/orders_kill.py --world live off
sleep 25
bin/fh call queue_status
bin/fh call orders_pause
bin/fh call queue_status
bin/fh call orders_resume
bin/fh call order_remove --args '{"name":"ghost"}'
bin/fh call order_remove --args '{"name":"patrol"}'
python3 tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_remove","so1"))'
```

Pass: the so1 row of `idle_report` has `orders` with `set: 2`, and while an order runs, `running` names it and
`standing_s` is 0. `orders_kill.py on` prints `stopped: so1` if an order was running (the ghost trigger still
holds); the `queue_status` after it has no `order`, its line is `orders: paused by the operator`, and after the 30 s
`orders` still shows nothing running, each order's state `paused by the operator`. After `off` and 25 s,
`queue_status` has `order: ghost` (reason `1 ghosts`, the run starts afresh) or patrol. After `orders_pause` the line is `orders: paused (orders_resume)` and `queue_status` has no
`order`. After both `order_remove` calls the reply has no `orders:` line. The ghost stays on the map (a wooden chest
ghost); remove it in the game if wanted.
