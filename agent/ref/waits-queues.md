- `wait_until {until, ..., timeout?}`: waits inside the game until a condition holds, with no call per check: a direct
  timed action (`--wait`), a queue step, a queue guard's `when` or a standing order's `when`. Conditions: `researched`
  (`technology`; without it the research running now; a technology with levels, an infinite one too, is met once the
  level it was on when the wait began is done, or `level: N` is); `crafting_done`; `item_count` (`item`, `at_least` or `below`;
  `quality`: that quality only, `"any"` every quality summed, none the name alone, which counts normal quality only;
  no other condition takes `quality`; `positions`: chests or machines of ours, summed, a silo's rocket cargo too (the item `rocket` is ammunition);
  default your inventory; `"surface":"nauvis"`: with positions, those chests there, alone, our logistic networks
  there (all of them summed), in the remote lane too; `network: {x,y}`: the one logistic network covering that spot;
  `platform`: the landed items in that hub, not incoming cargo or hub trash); `spoil_within` (`position`: an assembler,
  furnace or biochamber; `seconds` 1..3600; `item` optional: met when its input's first stack, of item or any,
  spoils or hatches within seconds; saw names it and the seconds left); `pod_landed` (`platform`, `item`?,
  `at_least`?: pods sent down from it that landed since the wait began, by freight's receipts: received by a pad or
  landed as a container; with `item`, how many of it; default 1; `drop_id: N` or `last_drop: true` (its latest drop
  when the wait begins): that one drop, met once it has landed; in the remote and platform lanes too). A rocket's cargo loaded to N is `item_count` with
  the silo's position; what a hub or a landing pad holds is `item_count` with `platform` or the pad's position;
  `rocket_ready` (`position`: the silo); `rocket_parts` (`position`, `at_least`; without it every part; `silo_parts`
  is the same name); `produced` (`positions`, `item`, `at_least`: made since the wait began, by the machines'
  products-finished counter; `{platform, item, at_least}` on a platform); `platform_built` (`platform`: no foundation
  ghost left) and `platform_ready` (`platform` with `positions`, `area` or `tiles`: that part's ghosts only;
  `platform_built` takes the same subset); `fluid_count` (`platform`, `fluid`, `at_least` or `below`: every tank,
  pipe, thruster and machine of ours there holding it, saw saying how much in each kind) and `circuit_signal` (`platform`, `signal`, `at_least` or `below`: the hub's red and green wires), queue
  steps and the remote lane too, e.g. `{"until":"fluid_count","platform":"Swift","fluid":"thruster-fuel","at_least":12000}`;
  `platform_arrived`, `platform_left` (`./fh help space-age`); `all` (`conditions`: 1..8 plain conditions, met when
  every one holds; in the remote lane when each is one the lane takes), e.g. `{"until":"all","conditions":[{"until":
  "fluid_count","platform":"Swift","fluid":"thruster-fuel","at_least":12000},{"until":"fluid_count","platform":"Swift",
  "fluid":"thruster-oxidizer","at_least":12000}]}`; also `no_enemy_structures`, `no_enemies`, `units_clear`, `turrets_idle`, `ammo_below`,
  `fuel_below`, `health_below`, `health_above`, `damaged`, `ghosts_waiting` (`./fh help wait_until`). `until` also
  takes the `--until` words (`"item_count yumako>=40"`), and `ticks` or `timeout_ticks` for `timeout` (1..54000 ticks,
  default 3600; with `--wait` it comes from `--wait-timeout`: `600000` is 10 minutes, 15 at most); hitting it fails
  with `timed_out`; a queue step with `on_timeout: "hold"` stays first in pending instead and the queue pauses with
  it (`paused_why` names the condition still unmet and what it saw; `queue_resume` waits for it again with a fresh
  timeout). Status and `last` show `saw`, `wait_estimates` (each condition's ETA with its rate basis, or no
  estimate) and `idle_s` (idle seconds in this wait). A direct call takes the wake options below and `pause_queue` (as
  `wait_ticks`). Example: `./fh call wait_until --args '{"until":"researched","technology":"automation"}' --wait`
- `./fh sleep SECONDS --until COND` and `./fh wait --until COND`: COND in words, several joined by `|` (or a JSON
  list) waking on whichever holds first and naming it: `item_count iron-plate>=200 at -18.5,-34.5 -16.5,-34.5` (those
  chests, summed; also `<`, `below`, `above`), `rocket_ready 65.5,14.5`, `rocket_parts>=40 at 65.5,14.5` (no count:
  every part), `produced iron-gear-wheel>=50 at 10.5,20.5`, `queue_done` (your queue finishing or stalling, a standing
  order's round too; at once when none runs), `alert` (a new attack, enemy group or nest alert; an attack known when the wait began wakes it only
  with new attackers or a loss near it, and the wake says the repeats it held: `alert_held`),
  `alert low_power starved` (a new or grown alert group of those kinds addressed to you, as `game_alerts` names them;
  `starved`: an assembler or furnace in your own claims that lacks ingredients and did not when the wait began;
  `speaker`: a programmable speaker of yours or on your surface starting an alert),
  `alert near=X,Y radius=R min_size=N` (or `area=X1,Y1,X2,Y2`: only an attack, group or nest there and that big;
  `woke: alert` names it), `tell` (wait only), `platform_arrived Sunward gleba`, or a wait_until condition as JSON. A
  sleep's reply says first whether your queue keeps running, your action keeps going until a tick, or your character
  stands idle; its first and last replies (and the operator's idle nudge) carry `open for you: ...`: your board items,
  alert groups and idle or starved machines in your fresh claims, and requests and tells to you unanswered.
  `--then ACTION [JSON]` runs one read action when the sleep ends and returns it with the wake; a sleep a newer one
  replaced runs none, and its `note` names the newer sleep. `sleep {orders: false}` starts no standing order during
  the sleep. A tell or board line shown in a sleep reply that your next sleep followed within 5 s comes again in
  `team.missed_while_asleep`. Egg news ends a sleep that takes no messages only for eggs you carry. Example:
  `./fh sleep 120 --until "item_count nutrients<50 at 4.5,15.5" --then inspect '{"position":{"x":4.5,"y":15.5}}'`
  `--require-met`: the wake's first line is `condition met after N s` or `condition not met: woke told after N s`
  (a tell, an urgent alert, the time up), and the exit status 0 when the condition held, 3 when not, 1 when the wait
  failed; a tell or urgent news still ends the wait at once. Without it the exit status is 0 whatever woke it.
  Example: `./fh sleep 300 --until "item_count power-armor-mk2>=1" --require-met && ./fh call equipment ...`
- `wait_ticks {ticks, pause_queue?}`: your character stands idle `ticks` (1..54000): a direct timed action (outcome
  `duration_elapsed`, or `told` or `mentioned` when a tell or mention ends it early) or a queue step. A direct
  `wait_ticks` or `wait_until` while your queue runs runs as a sleep (`as_sleep`) and the queue keeps going;
  `pause_queue: true` pauses the queue for the wait instead.
- `sleep_check`: the running sleep's state (`woke`, `slept_s`, `saw`) with `wait_estimates` and `idle_s` refreshed;
  wake replies refresh them too, and `fh wait --until` puts them on its line. A sleep that ends before its time, and
  a direct `wait_ticks` or `wait_until` ended by a message, an urgent alert or damage (`last`), give
  `personal_requests`: your personal requests still unfilled, each `item: hold N of M (K on the way); why`.
- `queue_submit {steps, mode?, guards?, lane?, dry_run?}` (`./fh queue submit --file plan.json`): runs steps
  `{action, args, wait?, label?, on_fail?, min_moved?, on_short?}` inside the game; an error names the step's path.
  At submit a step naming a platform that is not ours is refused (unless an earlier step creates it), and a requests
  `section` past the hub's count (unless an earlier requests step works on that hub); positions are not checked. A
  plan that pauses on a step failing in its first 10 s is a line in your team block at once.
  Into a repeating plan `mode` is required (the refusal names the job): `replace` stops it, `ahead` interrupts and
  restarts an absolute-goal step, `append` waits behind this round, `next` runs the new steps once right after the
  active step (which goes on) and keeps the loop. `mode: "replace"` stops the active step of any plan (a running
  `load_silo` too); `mode: "pending"` replaces only the pending steps. `on_fail`: `abort` pauses, `skip` goes on (it
  acquires nothing), `goto:<label>` jumps to that pending label. A `place_ghosts` or `build` step with failed entries
  fails (`reason: place_ghosts: 3 entries failed (37 placed); first: ...`) and its `on_fail` applies. A transfer step
  that moves fewer than asked (a full target) succeeds short; `min_moved: N` fails it below N moved. A transfer,
  collect, feed, rearm or refuel step with a position and no `walk` runs with `walk: true`: it walks into reach from
  any distance, with move_to's enemy checks (`walk: false` keeps it from walking; standing orders keep `max_walk`). `guards` (up to 8
  `{when, goto | steps}`) are checked while the plan runs. `dry_run: true` checks the plan and queues nothing.
  `lane: "remote"`: the remote lane (`./fh help space-age`); `lane: "platform:NAME"`: a remote lane of its own for that
  platform (the same steps), apart from the remote lane and the other platforms' lanes; each queue call takes the same
  `lane`, and `queue_status`'s `lanes.platforms` lists them. A queue step or standing order step that ends with you 8
  or more tiles from where it began is named in your next reply: `moved_by`
  (`standing order rearm-se (rearm, done) moved you from (10,4) to (53,112) (112 tiles)`). Example:
  `./fh call queue_submit --args '{"mode":"append","steps":[{"action":"move_to","args":{"position":{"x":12,"y":-40}}},{"action":"rearm","args":{"radius":20},"on_fail":"skip"}]}'`
- `queue_status {history?, pending?, args?, orders?, lane?}` (`./fh queue status`): the active step (`running_s`;
  `active.progress`: a tour's or courier's leg, distance left and moved so far; `waiting_at_machine`: a collect
  standing at a machine that crafts, which is no stall), the next one, and the plan you last submitted (`plan`: steps
  done, ok, failed; `history`: its own results); `paused_why` says what paused the queue. `args: true`: history with
  each step's arguments (and a finished loop's steps); `./fh queue status orders` lists the standing orders' steps
  too. An interrupted queued transfer tour resumes from the stops left. Example:
  `./fh call queue_status --args '{"history":"all","pending":10}'`
- `queue_edit {id, steps?, to?}`: `id: "job-12"` deletes a pending step (`steps`: replace it, `to: N`: move it); the
  active step is untouched. Example: `./fh call queue_edit --args '{"id":"job-12","to":1}'`
- `queue_cancel {lane?, clear?}`: cancels a queue (`lane: "remote"` for the remote lane); `clear: false` keeps the
  pending steps.
- `queue_pause {lane?}` (`./fh queue pause`): pauses a queue and holds it: the running step goes back to the head of
  pending, and nothing resumes it until `./fh queue resume` (or a submit or repeat that starts it). Without it, a
  direct call that interrupts a queued `load_silo` lets the queue go on when that call ends. Replies with a paused
  queue say what paused it (`paused_by`; `queue_held` on a direct call while you hold it). A failed direct call that
  paused it says so first in its error, and `team.queue_paused` stays on every reply until `queue_resume`.
  `queue_resume_after: true` on the direct call (or queue_submit's `resume_after_direct: true`) runs it again when the call
  ends.
- `queue_repeat {steps, interval_ticks?, times?, for_ticks?, condition?, orders?, name?}`: replaces the queue with a
  repeating plan. `times` (rounds) and `for_ticks` (no round starts after that) end the loop with one `queue:` line
  (`done after N rounds: ...`) and `loop_done` in `queue_status`; `condition: {until: ...}` ends it at a round
  boundary when met (before round one too). A round whose short steps differ from the round before puts a `queue:`
  line in the team block; steps with `up_to: true` or `"on_short": "skip"` are left out of it. `orders` says which
  standing orders may run between its rounds (triggered ones by default, `"all"` the default routine too, `"none"`
  none). Example:
  `./fh call queue_repeat --args '{"name":"rearm-loop","times":20,"interval_ticks":3600,"steps":[{"action":"rearm","args":{"radius":30}}]}'`
- `./fh plan save NAME --file plan.json` (`plan_save`): stores a queue plan (a JSON array of steps). Example:
  `./fh plan save refuel-round --file plan.json`
- `./fh plan run NAME` (`plan_run`): runs a saved plan again. Example: `./fh plan run refuel-round`
- `./fh plan list`: your saved plans (`fh call plans` is the same read).
- `stop`: ends your running body action (a walk, tour, `load_silo` or gather) and starts nothing. A call that ends a
  running action says in `replaced` what that action had done and where its walk stopped.
- `order_set {name, steps, when?, priority?, interval_ticks?, max_walk?}`: a standing order: runs its queue steps
  whenever its `when` holds (any `wait_until` condition; radius up to 256, `ammo_below`/`fuel_below` areas up to
  256x256). One order without `when` is your default routine, run every `interval_ticks` (up to 216000, an hour) while
  no trigger holds. Up to 6 orders of 32 steps; 3 failed runs in a row switch one off. They run only while your
  character is free (no action, your queue empty, or a repeating queue between its rounds: triggered orders by
  default, `queue_repeat {"orders":"all"}` the default routine too, `"none"` none), 20 s after your own last action;
  your own action or queue call stops a running order at once and it resumes after. `max_walk: N`: the order waits
  (its state says where and how far) while its place is over N tiles from you. An order refused for enemies that come
  and go (an area under attack, units or a group seen now) waits for the place to clear and runs again; it is not a
  failure (orders line: `waits for enemies near (x,y) to clear`). A reply's `orders:` line says which runs and why; it
  is shown when it changed and at least every 10 minutes (`--format json` always has it). A fuel round that takes from
  a named chest and feeds several furnace areas on `fuel_below` is in usage.md (`keep-furnaces-fueled`). Example:
  `./fh call order_set --args '{"name":"rearm","priority":7,"when":{"until":"ammo_below","count":20,"position":{"x":12,"y":-40},"radius":20},"steps":[{"action":"rearm","args":{"radius":20}}]}'`
- `orders`: lists your standing orders with their state, runs, failures and last run.
- `order_remove {name}`: deletes one.
- `orders_pause {seconds?}`: holds them (default until `orders_resume`); a running order stops and resumes after.
- `orders_resume`: lets them run again.
- `reminder_add {message, every_ticks | due_in_ticks, recipients?, wake?, steps?}`: sends you (or teammates) a private line
  when due, as a tell; `wake: false`: the line comes with the next reply and wakes no wait. Reminders never act in the
  game. `steps` makes a checklist: up to 12 names, or `{name, every_ticks}` for a step whose line comes again that
  often while it is your next one; each run goes out with your next unfinished step, and progress is per recipient.
  A run not acknowledged folds into the next; at 2 runs missed the owner gets one line naming who, the last result and
  the reminder_edit call that changes the recipients (again only after that recipient acknowledges or the recipients
  change).
  Example: `./fh call reminder_add --args '{"message":"check the boiler feed chests","every_ticks":54000}'`
- `reminder_ack {id, result, next_in_ticks?, every_ticks?, step?, leave?, resume?}`: records what the review found;
  `next_in_ticks` puts the next run off; its owner's `every_ticks` there sets a new cadence. On a checklist it records
  one step (your next unfinished one, or `step: N`) and names the next; the run is done for you once every step is
  recorded (a one-time checklist is done when everyone's is). `leave: true` sets it aside in an emergency (no step
  lines); `resume: true` or any step's ack picks it up at the next unfinished step. Example:
  `./fh call reminder_ack --args '{"id":3,"result":"all boilers fed","next_in_ticks":36000}'`
- `reminders {pending?}`: lists them, with each recipient's runs missed (`missed`); `pending: true` lists only what
  waits for you, each at its next step.
- What ends a wait (`./fh sleep`, `./fh wait`, `--wait`, direct `wait_ticks`/`wait_until`), besides the core's list:
  `--wait-through-tells` (`wake_on_messages: false`): no tell or mention ends it (`told_during_wait` lists them; on
  `--wait` and `./fh wait` on an action too; on an action alone it waits as `--wait` does), a tell sent with `--wake`
  still does; `--wake-from sol,astra`
  (`wake_from`): only a tell or mention from those (or `operator`); `--no-operator-wake` (`wake_on_operator: false`):
  operator tells and reminder jobs do not; `--wake-local` (`wake_local: true`): only tells and mentions to you (a tell
  to the whole team waits for your next reply), urgent news on your surface or in your claims (another platform's
  losses wait), and `--until alert` on your surface; `--wake-on-orders`: a standing order's rounds end a sleep too (by
  default only the plan you submitted, finishing or stalling: `queue_done`, `queue_stalled`); `--urgent-radius N`
  (1..200): attacks, groups, losses and deaths count only within N tiles of you; `--wake-near N` (`wake: {near: N}` on
  sleep, wait_ticks, wait_until): only an attack on ours or a loss within N tiles wakes it, the other urgent alerts
  come with the reply as `held_alerts`: an attack group on Nauvis, or a loss in a claim of yours there, wakes nothing
  while you wait on Gleba with it. `--no-board-wake` (`wake_on_board: false` on sleep, which `./fh sleep` and `./fh
  wait --until` use): a board item of yours assigned or changed by someone else does not end it (`board_held` lists
  them; an @-mention of you in it is a mention and still does); direct `wait_ticks`/`wait_until` never wake on board
  news, only on tells and mentions. A wait ended by anything but its condition says the condition now (`waited_now`:
  met or not, its value; for a platform, where it is and its latest launch up with its age). Urgent alerts and the
  action ending still end every wait. Each attack, group, loss or death wakes you once, however its counts grow (an attack after a
  minute's quiet is a new one); a power collapse or captive spawner again only when it comes back after 2 minutes gone
  (`alerts_digest` keeps the counts). A platform's alert lines (turrets empty, slow, fuel short, no repair packs) are
  told once while they last, again when their state changes or after 2 minutes clear. A sleep on a platform's arrival or departure
  (`fh sleep 900 --until 'platform Wren at vulcanus'`, or `left gleba`) goes on through tells; `--wake-on-tells` keeps
  them waking it.
- A tell or mention ends `--wait` or `./fh wait` on an action with `told`, `still_running` (the action keeps going),
  except on collect, feed, transfer, load_silo, rearm, refuel, recover and pickup: those go on through plain tells
  (listed in `told_during_wait`) and end on an urgent alert or a tell sent with `--wake`.
- `./fh wait --max 150` (or `--until idle`) waits for your running action (and combat) to end, at most 150 s, and
  returns at once when nothing runs (`outcome: idle`, exit 0, naming the last action and how long ago it ended when
  that was before your previous call); after the action already ended it gives its result. `--wait` replies are brief
  (outcome, position, inventory change; `--full` for the whole status).
- The clock line counts a wait or sleep as idle: `game 98h40m; +5m00s, idle 5m00s (100%, 4m30s in wait_ticks)`, and so
  do your stream card and the operator's idle nudge. With a standing order on (not paused, none running) it is still
  idle, and the clock and sleep lines add `on watch: NAMES` (the orders that act when a trigger holds). Queues,
  standing orders and `queue_repeat` keep your character working through a sleep.
- A harness update keeps waits, timed collects, tours, mining, building, repairs, queues and orders running with their
  end tick and progress (`team: harness_updated`: `... (your collect carried over)`), the remote lane's waits too; a
  move_to or drive restarts (`resumed`).
- A dropped game connection is ridden out: fh sends the call again with the same ID for up to 90 s (`retried`); the
  game answers an ID it already ran from its record. `game_unreachable` means nothing was sent. When the game runs
  slow, sleeps and `--wait` keep waiting while it advances (`slow_game: 18 ticks/s, 30% of normal`, also on the clock
  line) and end `paused` when it stops. After a server restart from a save, one reply says `rolled_back` and lists in
  `redo` what you changed since, which is gone.
