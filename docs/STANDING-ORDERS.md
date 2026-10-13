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
  one Nick saw: a loop that finishes, then nothing until the agent's next turn (Sonnet: a short plan, then 25 min).

## Design

**Orders.** Each agent has up to 6 standing orders, kept in the save (they survive shift changes):

```
order_set {name, steps, when?, priority 1-9, cooldown_ticks?, interval_ticks?, max_ticks?}
order_remove {name}     orders_pause / orders_resume     orders  (list with state)
```

- `steps`: the same steps as `queue_submit` (any player action, labels, on_fail), at most 32.
- With `when`: a triggered order. `when` takes the existing predicates (`ammo_below`, `item_count` on chests,
  `health_below`, `no_enemies`, `researched`...) plus three new ones: `ghosts_waiting {position, radius, at_least}`,
  `damaged {position, radius, below}` (our buildings under a health fraction), `fuel_below {position, radius, count}`
  (burner machines and boilers). All read only what the player could see, like the existing ones.
- Without `when`: the default routine, run whenever no trigger holds (at most one default per agent), with
  `interval_ticks` (default 1800) between runs.

**When they run.** Only when the character is free: no direct action running, the queue empty and not looping, not
riding a rocket or aboard a platform. Then the highest-priority trigger that holds and is off cooldown runs, else the
default. An order runs as a plan in the agent's own queue, marked with its name.

**Preemption.** Any request that drives the character (a direct action, `queue_submit`, `queue_repeat`, `plan_run`)
stops a running order at once. The order keeps its remaining steps and resumes when the character is free again, if
its trigger still holds (a default resumes; a trigger that no longer holds is dropped until it fires again). Reads,
chat and board posts do not preempt.

**Status.** Every reply carries one line while orders exist:
`orders: restock-ammo running (3 turrets below 20 near (12,-40)), step 2/5` or
`orders: waiting (patrol next in 40 s)` or `orders: paused by your move_to, restock-ammo resumes after` or
`orders: lab-feed off after 3 failures: <reason>`. The stream state gets the running order's name and reason, so the
overlay and site can show "auto: restock ammo" next to the agent.

**Limits.**
- Per tick: each agent's triggers are checked once a second, staggered by player index, one predicate per agent per
  check, radius at most 64, at most 16 chest positions. No predicate runs while the character is busy.
- Per agent: 6 orders, 32 steps each, one order running at a time. A run stops after `max_ticks` (default 3600, up
  to 18000). A trigger waits `cooldown_ticks` (default 600, at least 300) before it can fire again.
- Failures: an order that fails 3 runs in a row is switched off, with the reason in the status line and a `team:`
  note; `order_set` with the same name switches it back on.
- Survival-fair: steps are the agent's own actions through the same handlers (walking, reach, inventory, crafting
  time). Nothing acts at a distance; nothing the agent couldn't do itself.

**Prompt (one paragraph in team.md).** Set standing orders for your routine jobs (turret ammo, lab packs, fuel,
courier runs, repairs, ghosts), so your character keeps working while you think; your own requests always come
first.

## v1 scope (eng/standing)

`orders.lua` beside `scheduler.lua` (state, `order_set`/`order_remove`/`orders`/pause and resume, the free-character
check, trigger evaluation with the limits above, preemption hooks in the request path, the status line), the three
new predicates in `conditions.lua`, the `team.md` paragraph, and the stream state field. Tests: Lua tests in
`vendor/factorio-harness/tests` (free check, priority and default, cooldown, preemption and resume, failure switch-off,
limits, the new predicates) and `npm test`. Measure again with `tools/idle_report.py` after a shift with orders.
