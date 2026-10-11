# Harness 2: honest waits, clearer game messages, a labs view

Branch `eng/harness2`. Implements P2 items 7, 8 and 10 (the labs part) of `docs/studies/shake1-transcripts.md`.
User-facing usage is in `vendor/factorio-harness/docs/usage.md` ("Running actions", "Waiting", "Messages and reads");
`agent/PLAYBOOK.md` gained two lines (sleep, labs, `--wait-timeout` on `wait_until`).

All gameplay changes are runtime-only (`control.lua` is unchanged), so a live world picks them up with `fh deploy`.
New Lua lives in sibling modules: `waits.lua`, `labs.lua`, `claims.lua`. `runtime.lua` gained no top-level locals
(new pieces hang off `M`: `M.waits`, `M.labs`, `M.claims`, `M.await_feed`, `M.character_owner`).

## What changed

### Waits (item 7)

- `wait_until --wait` takes its timeout from `--wait-timeout MS` (converted to ticks, capped at 54000 = 15 min) when
  `args.timeout` is not given; the runtime and queue steps accept `timeout` up to 54000 (was 36000). The CLI waits for
  the action's own end tick plus a margin in that case, so it never gives up just before the game does.
- Hitting an action's own limit is now `error.code: timed_out` with a message naming the condition and what it last
  saw (`wait_until timed_out: item_count not met (saw "iron-plate 8"); the timeout comes from --wait-timeout ...`).
  Before, it was `action_interrupted` / `Control ended: timed_out`. `fh wait` uses the same wording.
- `wait_ticks` is a direct timed action (1..54000 ticks, outcome `duration_elapsed`, waitable with `--wait`), and a
  queue step as before; `describe` says both.
- `fh sleep SECONDS` (1..900): the `sleep` action (passive: it never stops the current action or the queue) records
  the start tick and health; in `turns` clock mode it asks the clock to run (`advance`, at most 36000 ticks). The CLI
  polls `sleep_check {peek:true}` once a second and finishes with one plain `sleep_check`, so the final reply carries
  the `team` block. Wake reasons: `damaged` (health below the start, or an enemy hit on the character recorded by
  board.lua's alerts since the start; `health`, `lost`, `by`), `died` (exit 1), `mentioned`
  (a message filed in the board's per-agent mention inbox after the start, read there without delivering it; the
  `team.mentions` of the final reply delivers it as usual), `elapsed`. If the game advanced less than SECONDS within
  1.25 x SECONDS + 10 s of real time (paused server), it exits 1 with `timed_out`. Nothing runs per tick.

### Messages (item 8)

- Power: the status warning appears only when some electric machine is `low_power`, `no_power` or unconnected, as
  `power: 3 of 78 machines low_power; 1 unconnected (fh call power lists them)`. `no_power` with no electric network
  id counts as `unconnected` (Sol's "0/78 low_power, 1 no_power" was one unconnected machine).
- `move_to` ending `arrived_near` is a success for `--wait` (exit 0), in `fh wait` and in plans.
- `build` short of an item the hand-craft queue is making waits for it (the existing `awaiting_craft` feed action,
  reran when the craft lands; outcome `fed` or `failed`), single or batch; `--wait` follows it. Queue steps wait too
  (`build` is a timed kind only while it is awaiting a craft).
- Footprint refusals name another player's or bot's character: `placement blocked by h2-b's character standing at
  (6.8,1.8) (ask them to move, or build elsewhere)`. The own character keeps the old wording.
- `collect` with `radius` skips machines and chests inside another agent's active board claim and reports
  `skipped_claims` (`5 firearm-magazine in 1 places of #327 h2 test depot (claim by h2-b); ask the owner`).
  `collect` on named positions still takes from them (the agent chose them) and lists them in `claimed`.
- `inspect` is a read at sight range (32 tiles in a visible chunk, as `scan` and `nearest` use), with `in_reach`.
- `transfer` takes from character corpses (new inventory name `character_corpse`, first in the take order); an
  emptied corpse is destroyed, as when a player empties one. It never calls `mine_entity` (which segfaults the server
  for a bot).
- `docs/bridge.md`: the bridge examples (top-level `x`/`y`, correct for bridge sessions) now sit next to the harness
  form (`position:{x,y}`). `docs/usage.md`: the `arrived_near`, queue-only `wait_ticks` and corpse lines were stale
  and are replaced; new sections cover waiting, sleep and the changed messages.

### labs (item 10, labs part)

`fh call labs [--args '{"position":..,"radius":96}']`, a read sent as an observe scope (so an old bootstrap treats it
as read-only). Output:

```
research: "logistics 25% needs automation+logistic, eta 12m30s at 1 working labs"   (or "stalled: no lab is working", or "none: nothing queued ...")
labs: "4 in 2 groups"
groups: ["labs (0,0)-(6,0): 1/3 working, 2 missing_science_packs, lack logistic (2); feeders: 3 inserters (1 lab-to-lab); 1 idle: source transport-belt (0,-3) has nothing the lab needs; no logistic on their 1 belts/chests; sources hold automation 12", ...]
```

Groups are labs within 5.5 tiles of each other (chains), largest first; bounded to 256 labs, 8 group lines, 128
inserters per group and 16 sources per group. Feeders are inserters whose drop target is a lab of the group; idle
reasons come from the inserter status (`waiting_for_source_items` names the source, else the status, such as
`no_power`). ETA = remaining units x unit time / (lab researching speed x (1 + lab speed bonus)) / working labs; it
ignores lab modules and beacons.

## Verification

Fake-engine tests (all in `npm test`):

- `tests/waits.lua` (new): wait_ticks bounds and replacement, sleep wake reasons (elapsed, damaged with loss, a new
  mention but not an old one, death), the reason sticking for the final read, turns-mode advance.
- `tests/labs.lua` (new): grouping, ETA, missing packs, lab-to-lab inserters, idle source, packs absent from sources,
  no feeders and no power, no research, stalled.
- `mod/tests/runtime_test.lua`: footprint with another player's character, wait_until 54000 cap, direct wait_ticks,
  inspect out of reach (and rotate still refused), build awaiting a craft then rerunning, corpse transfer and removal.
- `tests/stock.lua`: radius collect skips a claim by someone else, keeps the agent's own claim.
- `tests/survey.lua`: the new power line.
- `tests/waits.test.ts` (new, CLI against a fake RCON server): arrived_near exits 0; wait_until timeout from
  `--wait-timeout` (36000 for 600000 ms, capped at 54000, explicit args win) and `timed_out` error; wait_ticks and an
  awaiting build are waited for; `fh sleep` polls with peek, reads once plainly, exits 1 on death, rejects 901.
- `npm test`: 71 pass, 4 fail; the 4 are the `bridge.test.ts` unix-socket tests, which fail in this sandbox with
  `listen EPERM` before any test code runs (same as before this branch).

Live, world `live` (bots `h2-a`, `h2-b`; runtime built from a scratch merge of eng/board 811968a and this branch,
deployed as sha a17260ef; later redeployed from eng/board 8421da7 + this branch 0c9b40a as sha 0f49e5fd, which is
what `live` runs now):

- `wait_ticks 120 --wait`: `duration_elapsed`. `wait_until item_count ... --wait --wait-timeout 4000`: the game got
  `until_tick` 240 ticks out and the CLI exited 1 with `timed_out` and `saw "iron-plate 8"`.
- `fh sleep 60`, then h2-b said `@h2-a ...`: woke after 4 s with `woke: mentioned`, the message, and `team.mentions`.
  `fh sleep 60` while the operator damaged the character by 30: `woke: damaged`, `health: 220`, `lost: 30`.
  `fh sleep 3`: `woke: elapsed`.
- `transfer` from a real character corpse as bot h2-a: 22 items, `corpse_removed`; the server stayed up.
- `build` stone-furnace on h2-b's spot: the refusal named `h2-b's character`.
- `inspect` of a furnace 14 tiles away: full reply, `in_reach` false.
- `craft iron-chest` then immediately `build iron-chest --wait`: `awaiting_craft`, then outcome `fed`, consumed 1.
- `move_to` into the chest: outcome `arrived_near`, exit 0.
- Temporary operator fixture (2 unpowered labs, a chest, an inserter; removed afterwards): `labs` reported
  `0/2 working, 2 no_power; feeders: 1 inserters; 1 idle: no_power`; status warned `power: 3 of 3 machines
  unconnected (fh call power lists them)`. Research did not start on this world (its queue reports full), so the
  ETA line is covered by the fake-engine test only.
- Claim by h2-b around a chest h2-a stocked: radius `collect` skipped it with `skipped_claims` naming #327 and h2-b;
  `collect` on the chest's position took the 5 and listed it under `claimed`. Chest mined and claim dropped after.
- Cost: `profile_ticks 600` with 11 bots idle: 0.048 ms per harness tick (eng/bots measured 0.046 ms with 9). Nothing
  new runs per tick; `wait_ticks` is an ordinary active action.
- After the redeploy, with the merged CLI: `fh sleep 60` while the operator applied 5 enemy damage woke after 8 s
  with `woke: damaged`, `lost: 5`, and the hit in `team.alerts`. `describe` on live lists `wait_ticks` (direct),
  `sleep`, `sleep_check`, `labs` and the new `inspect` note.
- The merged CLI (with eng/board's compact waits): `wait_until` ends with `error: timed_out: ...` as its last line;
  `fh sleep 2` printed `woke: elapsed`.

## Round 2: room for the runtime to grow (deploy size)

After main merged this branch, the runtime bundle was 507,910 bytes against a 524,288-byte cap that both
`host/bundle.ts` and `control.lua`'s `install` enforced. Two changes:

1. Compaction (host only, so every existing world benefits): `host/compact.ts` drops Lua comments, indentation,
   repeated spaces and trailing spaces outside strings, and keeps every line break, so runtime error line numbers
   (`agent-harness/runtime:NNNN`) still point at the same bundle lines. Short and long strings are copied byte for
   byte; a long comment inside a line becomes one space. The bundle went from 507,910 to 411,053 bytes (-19%), so a
   world with the old `control.lua` has about 113 KB of room again.
2. Chunked installs (`control.lua`, protocol 2): `install` now takes up to 8 MiB; `install_limits` reports
   `{max_bytes: 8388608, chunk_bytes: 262144, protocol: 2}`; `install_chunk(id, index, total, data)` collects chunks
   in order in `storage.agent_harness.pending_install` (chunk 1 starts over, so an abandoned upload is dropped);
   `install_commit(id, bytes)` checks the count and byte total, clears the upload, and installs through the same
   validate-then-swap path as `install`. `fh deploy` (`Harness.deploy`) sends one `install` up to 524,288 bytes,
   which every world accepts, so hot-deploy to existing worlds works as before. A larger bundle needs
   `install_limits`; an older world gets a clear error before anything is sent. Chunks are split on UTF-8 character
   boundaries.
3. Bug found on the way: `luaString` (the long-bracket quoting for RCON) produced `...]]]` for a value ending in
   `]`, which Lua closes one character early. Whole bundles never ended in `]`, but chunks can; it now raises the
   bracket level in that case.

Verification:

- `tests/compact.test.ts`: unit cases (comments inside strings, long strings and comments with levels, mid-line long
  comments, escapes, line counts); every Lua suite (`tests/*.lua`, `runtime_test`, `control_test`) run against
  compacted copies of all modules passes; the compacted bundle compiles.
- `tests/deploy.test.ts`: `luaString` round-trips values ending in brackets through real Lua; `utf8Chunks` keeps
  characters whole; small runtime = one `install`; 600 KB+ runtime = probe, 3 chunks within the cap and a commit with
  the right byte count; the commands `fh deploy` generates, run through the real `control.lua` under Lua, install an
  840 KB runtime byte for byte (4 chunks, protocol 2 reply); an old world (no `install_limits`) and an over-cap
  runtime are refused with clear messages.
- `mod/tests/control_test.lua`: limits, chunk order, starting over, incomplete commit (dropped, old runtime kept),
  byte mismatch, oversized chunk, an over-512-KiB single install.
- `npm test`: 89 pass, 4 fail (the same bridge `listen EPERM` sandbox failures).
- Live on `live` (old `control.lua`, started before this change): `fh deploy` of the compacted 411 KB bundle replied
  `protocol: 1` and the runtime works (`labs`, `sleep`); a padded 611,108-byte bundle was refused before sending
  with `this world's control.lua takes at most 524288 bytes and has no chunked install. Restart the world with the
  current agent-harness mod ...`, and the running runtime stayed in place.
- Not verified live: a chunked deploy into a world running the new `control.lua`. Creating a throwaway world
  (`tools/winps.sh tools/win/new-instance.ps1 -Name h2 ...`) was blocked in this session by the Cygnal guardrail
  (it reads the scripts' `-ExecutionPolicy Bypass` as disabling a safety gate). To check it: create or restart a
  world with the current mod (`new-instance.ps1` copies `D:\pog\mods`, so refresh that or the instance's `mods`
  folder first), then `fh deploy --file <a copy of the mod folder with a 200 KB padding module>/runtime.lua`; expect
  `protocol: 2` and `chunks: 3`, then `fh deploy` of the normal runtime.

Gaps: an existing world needs a server restart with the new mod (and refreshed client mod copies, else
`multiplayer.script-mismatch`) before it accepts more than 524,288 bytes; team runs create fresh worlds, so they get
it automatically once `D:\pog\mods` holds the current mod. A chunked upload is not atomic across RCON failures: a lost
chunk reply leaves the upload pending until the next `fh deploy`, which starts over at chunk 1. Save files carry the
stored runtime source (now compacted, so smaller than before).

## Merging with eng/board

Lua merges cleanly. `host/cli.ts` conflicts in 4 hunks; the resolution used for testing (merged tree: `npm test`
81 pass, the same 4 bridge EPERM failures):

1. `known` set: take eng/board's block and add `'sleep'` to the set.
2. `waitForAction`: take eng/board's split; in `waitForActionEnd` the deadline is
   `waitBudget(untilTick,nowTick,action === 'wait_until')`; in `waitForAction` also pass `timed_out` through to the
   brief: `(!done.ok && done.error?.code !== 'action_interrupted' && done.error?.code !== 'timed_out')`.
3. `waitForIdle` idle branch: eng/board's version with `error:endedError(last.kind ?? 'the action',last)`.
4. `execute` preamble: keep both, this branch's `wait_until` timeout block first, then eng/board's `before` read.

`tests/waits.test.ts` already allows eng/board's extra final status read.

## Gaps

- Bundle size: resolved in round 2 below (compaction plus chunked installs up to 8 MiB).
- `fh sleep` mention detection reads `storage.agent_harness.mentions` (board.lua's inbox) directly; if eng/board
  changes that layout, `waits.lua`'s `why()` must follow; the same holds for `char_hits` (enemy hits). Damage from
  non-enemy sources (fire, own turrets) is seen only as lower health at a check, once a second.
- A shell timeout shorter than the sleep or wait still cuts the agent off (Claude Code Bash timeout, Codex exec
  yield, Grok's auto-background): the brief's harness-side half only. Launch settings must allow it (P1 item 1).
- `labs`: the ETA ignores lab modules, beacons and lab-to-lab supply limits; belts are judged by their current
  contents, so a belt that is empty for a moment between items reads as "nothing"; inserters fed from a splitter or
  a ground item are reported by status only.
- `collect` with a radius skips claimed stock silently except for `skipped_claims`; an agent that owns nothing and
  needs the items must ask (intended). Claims with `status` `done` or `dropped` no longer protect anything.
- `build` waiting reports outcome `fed` (the shared feed action's name), not `built`; the built entity is in
  `last.result`.
- Not done from P2 item 10: push alerts for the claimed area, the one-line queue state and a working `./shot`.
- My reply to eng/board's coordination message was blocked by the session's outbound-message guardrail; I followed
  their proposal (deploy only merged bundles, h2- bots) without confirming it to them.
