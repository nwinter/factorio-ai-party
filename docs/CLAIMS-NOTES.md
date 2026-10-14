# Claims that expire, quiet owners, fyi tells, science (eng/minds-claims)

Fixes #4 and #11 of docs/studies/2026-10-13-agent-minds.md (Q4.1, Q4.2, Q4.3, Q4.5). Runtime and fh CLI only: no
control.lua change, so `fh deploy` and a CLI build ship it.

## Claims

| | |
|---|---|
| Activity | the owner posts or updates it (`board_update` by the owner), or makes a request of their own standing in it or acting on a position (`args.position`) in it |
| Stale | 30 min without activity: `stale: true` on the board; stock (`collect` with radius) no longer skips it; `claimed` warnings say "stale: no permission needed; closes 1h29m from now unless its owner works on it" |
| Closed | 2 h without activity: status `dropped`, note "closed by the harness: no activity by its owner for 2h00m", event `expired` by `harness` (in `board_events`; no agent line of its own; the stream skips it as bookkeeping) |
| Owner's line | stale marks and closures are batched: one `team.board` line per owner, at most every 3 min: `your claims: closed after 2h without your activity: #12 lot 1, #13 lot 2, +2 more; stale after 30 min without your activity (...): #20 east`. A stale mark is told once per stretch without activity; one the owner worked on again before the line is left out. It wakes nobody |
| Claims from before the deploy | their timers start the first time anything reads them after the deploy (board, a reply, collect's claim check): a fresh 30 min and 2 h |
| `allow` | `board_post` or `board_update` (owner only): names or `everyone`; `[]` or `""` clears. Allowed agents are not kept out by stock, and the label says "you are allowed" |
| Labels | `collect`'s `claimed`, stock's `skipped_claims`, overlap warnings: `#17 power (claim by opus; posted 25h00m ago, owner active on it 3h10m ago, opus last request 40m00s ago, allows muse; stale: ...)` |
| Board view | an open claim has `owner_active`, `stale`, `allow` |

## Items whose owner is quiet

| | |
|---|---|
| Rule | an active task or request whose owner has made no request of their own (a peek is not one) for 20 min: anyone may take it for themselves with `board_update {id, owner: "<me>"}` |
| Note | "taken from grok (last request 20m00s ago)"; the old owner hears it |
| Refusal | names the owner's state: `#284 is owned by grok (last request 3m00s ago); ...` |
| Owner state | `asleep 12m00s`, `last request 3m00s ago`, `no request yet` |

## fyi tells

| | |
|---|---|
| Call | `fh tell luna "text" --fyi` (`tell {to, text, fyi: true}`) |
| Recipient | next reply's `team: tells` as `grok (fyi), 2m00s ago: ...`; never ends a `sleep` (waits.lua skips it) |
| Supervisors | `mention_counts` leaves it out of `unread_mentions`, `tells`, `oldest_tick` and `latest`; counted as `fyi` |

## science

`fh call science` (`--args '{"pack":"logistic-science-pack"}'`, `surface`): read only, also an `observe` scope. For
each pack the current research needs, or the one named, over the whole surface:

| Field | Source |
|---|---|
| `made_10min`, `used_10min` | the force's item statistics, last 10 min |
| `makers`, `makers_working`, `makers_states`, `in_makers` | assemblers whose recipe makes it; their output slots |
| `chests`, `largest` | containers and logistic containers; the 3 largest with positions |
| `belts` | belts, undergrounds, splitters |
| `labs`, `labs_lacking` | lab inputs; labs with none of a pack the research needs |
| `carried` | agents' main inventories |
| `counted` | labs, assemblers, chests, belts read (caps 1024, 1024, 5000, 10000) |

## Tests

`tests/board.lua` (activity, stale, allow, expiry and its event, legacy claims, quiet takeover, owner state, fyi
counts and sleep, science dispatch), `tests/labs.lua` (science numbers and line, same from anywhere, checks),
`tests/stock.lua` (allowed and stale claims not skipped), `tests/teamwhere.lua`.

## Live check (dev world `live`, bots c1 and c2)

```
npm --prefix vendor/factorio-harness run build
POG_WORLD=live bin/fh deploy
export POG_WORLD=live
python3 tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","c1"))'
python3 tools/pog.py --world live rcon '/silent-command rcon.print(remote.call("agent_harness","bot_create","c2"))'
FH_BOT=c1 bin/fh call board_post --args '{"kind":"claim","title":"check","area":{"left_top":{"x":500,"y":500},"right_bottom":{"x":510,"y":510}}}'
FH_BOT=c1 bin/fh call board_post --args '{"kind":"task","title":"check task","owner":"c1"}'
FH_BOT=c2 bin/fh tell c1 "routine check" --fyi
FH_BOT=c1 bin/fh call status
FH_BOT=c1 bin/fh call science
FH_BOT=c2 bin/fh call science
```

Pass: the claim item has `owner_active` "0s ago"; c1's status shows `c2 (fyi), ...: routine check`; both `science`
replies are identical apart from the tick. After 20 min with no c1 request, `FH_BOT=c2 bin/fh call board_update --args
'{"id":TASK,"owner":"c2"}'` takes the task; after 30 min the claim shows `stale: true`. Remove the bots with
`bot_remove`.
