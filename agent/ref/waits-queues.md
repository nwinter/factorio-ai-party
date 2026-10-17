- `./fh call wait_until --args '{"until":"researched","technology":"automation"}' --wait` (also `item_count`,
  `crafting_done`) lets the factory run until a condition holds, without polling. `item_count` takes `"surface":"nauvis"`
  (with positions, those chests there; alone, our logistic networks there), in the remote lane too. A sleep that takes
  no messages (a ship wait) is not ended by egg news unless you carry the eggs. `fh wait` after the action already
  ended gives its result (`note` says it ended before your previous call). Add `--wait-timeout 600000` to
  wait up to 10 minutes (15 at most); hitting the limit fails with `timed_out`.
  A `platform_arrived` or `platform_left` wait with no `timeout` (queued or direct) goes on past its default 60 s while
  its ETA is known: to the ETA plus a quarter and 10 s, at most 54000 ticks (`extended` says so).
- A sleep's reply's first line says whether your queue keeps running, your action keeps going until a tick, or your
  character stands idle.
- `--until "item_count iron-plate>=200 at -18.5,-34.5 -16.5,-34.5"` counts those chests.
- `--wait` replies are brief (outcome, position, inventory change; add `--full` for the whole status).
- `./fh wait --max 150` (or `--until idle`) waits for your running action (and combat) to end, at most 150 s, and
  returns at once when nothing runs (`outcome: idle`, exit 0, naming the last action and how long ago it ended when
  that was before your previous call).
- `./fh sleep 600 --until "rocket_ready 65.5,14.5"` (or `wait_until {"until":"rocket_ready","position":...}`) waits for
  that silo's rocket to be ready; the item `rocket` is ammunition, and `item_count` at a silo counts its rocket cargo.
  `--until "rocket_parts>=40 at 65.5,14.5"` (or `{"until":"rocket_parts","at_least":40,"position":...}`, also a queue
  guard's `when`) waits for the rocket being built to have 40 parts (`silo_parts` is the same name; with no count, every
  part: `--until "rocket_parts at 65.5,14.5"`). `--until queue_done` (a sleep's only) wakes when your queue finishes or
  stalls, a standing order's round too, and at once when none runs. `{"until":"all","conditions":[...]}` holds when
  every one does.
- `--then ACTION [JSON]` on `fh sleep` and `fh wait --until` runs one read when the sleep ends and returns it with the
  wake: `./fh sleep 120 --until "item_count nutrients<50 at 4.5,15.5" --then inspect '{"position":{"x":4.5,"y":15.5}}'`
  (read actions only). A sleep a newer one replaced runs none, and its `note` names the newer sleep.
  `--until "produced iron-gear-wheel>=50 at 10.5,20.5"` (or `{"until":"produced","item":...,"at_least":50,"positions":[...]}`, a wait or queue step) waits until those machines made 50 since the wait began (their products-finished counter).
  `./fh wait --until "item_count coal below 20 at 10,39"` wakes when that chest's coal falls under 20 (also `>=`, `<`,
  `above`; several `X,Y` are summed). `./fh wait --until "alert low_power starved"` wakes on a new or grown alert
  group of those kinds addressed to you (`low_power`, `no_power`, `no_fuel`, ... as `game_alerts` names them), or
  `starved`: an assembler or furnace in your own claims that lacks ingredients and did not when the wait began.
  Several joined by `|` wake on whichever holds first: `./fh wait --until "alert|platform_arrived Sunward gleba"`,
  `"item_count coal>=50 at 10,39 | item_count iron-plate>=100 at 12,39"` (the wake names the one that held).
- `sleep --until "tell|alert"` and `wait --until` accept the same joined events; `wait_until {until:"item_count", platform, item, at_least}` waits for landed hub stock in sleep, queue steps and guards (incoming cargo and hub trash excluded).
  `feed {area, walk:true}` already tours successive groups; `out_of_reach` is the initial count, `last.visited` the stops reached; exhausted carried items and fuel slots holding another fuel limit delivery.
- Direct `wait_until` and `wait_ticks` accept `wake_on_messages:false`: tells and mentions remain for the next reply while the wait continues; default true wakes on messages.
  `fh sleep` and `fh wait --until` take it too (`--wait-through-tells`); while your queue runs, a direct wait runs as such a sleep (`as_sleep`) and the queue keeps going. A tell with `--wake` still ends it.
- A tell or mention ends a wait early: a direct `wait_ticks`/`wait_until` (outcome `told` or `mentioned`), and
  `--wait` or `./fh wait` on an action (outcome `told`, `still_running`: the action keeps going), except the tours
  listed below (collect, feed, transfer, load_silo, rearm, refuel, recover, pickup).
  `--wait-through-tells` keeps `--wait` and `./fh wait` on an action waiting too (`told_during_wait` lists them).
  `--wake-from sol,astra` (`wake_from`): only a tell or mention from those (or `operator`) ends a sleep or wait;
  `--no-operator-wake` (`wake_on_operator: false`): operator tells and reminder jobs do not end it. Urgent alerts and
  the action ending still end them.
- A sleep ends when the plan you submitted to your queue finishes or stalls (`queue_done`, `queue_stalled`); a
  standing order's rounds do not end it (`--wake-on-orders` makes them).
- A collect standing at a machine that crafts is no stall (queue_status `waiting_at_machine` says which); a call that
  ends a running action says in `replaced` what that action had done and where its walk stopped.
- A dropped game connection is ridden out: fh sends the call again with the same ID for up to 90 s (`retried`); the game
  answers an ID it already ran from its record. `--wait` on collect, feed, transfer, load_silo, rearm, refuel, recover or
  pickup goes on through tells (listed in `told_during_wait`) and ends on an urgent alert or a tell sent with --wake.
- `fh sleep 900 --until 'platform Wren at vulcanus'` (or `left gleba`) goes on through tells (`--wake-on-tells` keeps
  them waking it). `tell --wake` wakes a teammate every time; `ignoring` names a wait your tell does not end.
  `queue_status` `paused_why` says what paused the queue. A queue step or standing order step that ends with you 8 or
  more tiles from where it began is named in your next reply (not a poll): `moved_by` (`standing order rearm-se (rearm,
  done) moved you from (10,4) to (53,112) (112 tiles)`). A queued `launch {wait_ready}` whose rocket goes records `launched`.
- Urgent wakes: `--urgent-radius N` (1..200) counts attacks, groups, losses and deaths only within N tiles of you. `--until "alert near=X,Y radius=R min_size=N"` (or `area=X1,Y1,X2,Y2`)
  wakes only on an attack, group or nest there and that big; `woke: alert` names the alert.
- Conditional `sleep`, `wait_until`, and queue waits report `wait_estimates` (ETA and rate basis, or no estimate) and
  `idle_s` in this wait; `sleep_check` and wake replies refresh them, and `fh wait --until` includes them on its line.
- An idle sleep makes nothing: your character stands still, and the clock line and your stream card count it as idle.
  Queues, standing orders and `queue_repeat` keep your character working through a sleep.
  A sleep's first and last replies (and the operator's idle nudge) carry `open for you: ...`: your board items, alert
  groups and idle or starved machines in your fresh claims, and requests and tells to you unanswered.
- A queue plan's rounds (refuel, rearm) keep going while you think; `wait_until` waits for one condition up to its
  timeout; `./fh sleep` and `./fh wait --until` leave the queue running.
- The clock line counts a wait or sleep as idle: `game 98h40m; +5m00s, idle 5m00s (100%, 4m30s in wait_ticks)`.
  The operator's idle nudge uses the same count.
- Raw `fh call wait_until` accepts word-form `until` and `ticks`/`timeout_ticks` aliases; queue errors name the step path. Aboard, queues accept allowed remote steps, `configure {platform}` works, and `observe` reports surroundings with `player.body:"none"`.
- `./fh plan save NAME --file plan.json` stores a queue plan; `./fh plan run NAME` runs it again; `./fh plan list`.
  `./fh queue status` shows the active step (`running_s`), the next one, and the plan you last submitted (`plan`: steps
  done, ok, failed; `history`: its own results); `./fh queue status orders` lists the standing orders' steps too;
  `--args '{"history":"all","pending":10}'` shows more.
  `queue_submit` into a repeat requires explicit `mode`: `replace` stops it, `ahead` interrupts/restarts an absolute-goal step, `append` waits behind this round, `next` runs the new steps once right after the active step (which goes on) and keeps the loop; refusal names the job.
  `mode: "replace"` stops the active step of any plan (a running `load_silo` too). `mode: "pending"` replaces only the pending steps; `queue_edit {id: "job-12"}` deletes a pending step (`steps`: replace it, `to: N`: move it), the active step untouched. A `place_ghosts` or `build` step with failed entries fails (`reason: place_ghosts: 3 entries failed (37 placed); first: ...`) and its `on_fail` applies.
  `queue_repeat {condition: {until: ...}}` ends at a round boundary when met (before round one too); `feed up_to:true` ending `out_of_items` exits 0 from `--wait`/`fh wait`, with moved and stops left.
- `queue_status {args: true}`: history with each step's arguments (and a finished loop's steps); status `active.progress` gives a tour's or courier's leg, distance left and moved so far; an interrupted queued transfer tour resumes from the stops left.
- `./fh call stop` ends your running body action (a walk, tour, `load_silo` or gather) and starts nothing; `queue_cancel` (with `lane: "remote"` for the remote lane) cancels a queue.
- A `craft` stock refusal names stocking chests and queue-step `on_fail`: `abort` pauses, `skip` continues,
  `goto:<label>` jumps to that pending label. Skipping acquires nothing; `transfer`/`collect` take stock explicitly.
- Standing orders keep your character on routine jobs while you think: turret ammo, lab packs, fuel, repairs,
  ghosts. `./fh call order_set --args '{"name":"rearm","priority":7,"when":{"until":
  "ammo_below","count":20,"position":{"x":12,"y":-40},"radius":20},"steps":[{"action":"rearm","args":{"radius":20}}]}'`
  runs its queue steps whenever
  its `when` holds (any `wait_until` condition, plus `ghosts_waiting`, `damaged`, `fuel_below` and `platform_arrived`); one order without
  `when` is your default routine, run every `interval_ticks` while no trigger holds. Up to 6 orders of 32 steps. They
  run only while your character is free (no action, your queue empty, or a repeating queue between its rounds:
  triggered orders by default, `queue_repeat {"orders":"all"}` the default routine too, `"none"` none), 20 s after your own last action; your own
  action or queue call stops a running order at once and it resumes after. A reply's `orders:` line says which
  runs and why; it is shown when it changed and at least every 10 minutes (`--format json` always has it). `./fh call orders` lists them; `order_remove`, `orders_pause`, `orders_resume`.
- `order_set` can take fuel from a named chest then `feed {area, walk:true}` over several furnace areas on `fuel_below`; the complete `keep-furnaces-fueled` call is in usage.md.
- `reminder_add {message, every_ticks or due_in_ticks, recipients?}` sends you (or teammates) a private line when due, as a tell; `reminder_ack {id, result}` records what the review found; `reminders` lists them. They never act in the game.
- A harness update keeps waits, timed collects, tours, mining, building, repairs, queues and orders running with their end
  tick and progress (`team: harness_updated`: `... (your collect carried over)`), the remote lane's waits too; a move_to or drive restarts (`resumed`).
- When the game runs slow, sleeps and `--wait` keep waiting while it advances (`slow_game: 18 ticks/s, 30% of normal`,
  also on the clock line) and end `paused` when it stops. `game_unreachable` means nothing was sent; after a server
  restart from a save, one reply says `rolled_back` and lists in `redo` what you changed since, which is gone.
- `fh wait` over a walking or loading tour goes on through plain tells (an urgent alert or a `--wake` tell ends it).
  The default routine's `interval_ticks` runs up to 216000 (an hour).
- A standing order refused for enemies that come and go (an area under attack, units or a group seen now) waits for
  the place to clear and runs again; it is not a failure (orders line: `waits for enemies near (x,y) to clear`).
- `wait_until {until: "platform_ready", platform, positions?, area?, tiles?}` waits for that part's ghosts only
  (`platform_built` takes the same subset).
- `reminder_add {..., wake: false}`: its line comes with your next reply and wakes no wait. `reminder_ack {id, result,
  next_in_ticks}` puts the next run off; its owner's `every_ticks` there sets a new cadence.
- `order_set {..., max_walk: N}`: the order waits (state says where and how far) while its place is over N tiles from
  you. `sleep {orders: false}` starts no standing order during the sleep.
