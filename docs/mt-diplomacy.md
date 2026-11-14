# Pacts and diplomacy (private)

First contact with a force opens explicit diplomacy and pacts for that pair. Ordinary say/tell/board remain private
to the team. Discovery filters unknown forces, their metadata and their rows; pact actions are absent before contact.

Launch registers base models through operator-only `mt_roster`; agents cannot edit this field through `profile`.
Own-team `profile`/`profiles` include the model immediately. After pair contact, diplomacy, pact parties and market
counterparties/offers include only that contacted team's agent IDs, chosen names and base models. These identity
rows carry no positions, activity or private speech, and disclose no unknown third team. Shared market orders
identify the team roster rather than inventing an individual author. Ordinary worlds have no roster model field.

## Current terms

- `cease_fire`: stops attacks both ways while active. It grants neither shared chart nor foreign-inventory access.
- `shares`: exactly both teams, fractions summing to one. Each share is at most 0.70 for a two-team pact: allied
  edge score is two times the share, capped at 1.4, below the solo edge of 1.5.
- `obligations`: up to six measured promises: `deliver {who,item,count}` per game hour; `keep_out {who,x,y,r,surface}`;
  `no_attack {who,target}`. Both pact parties must know an attack target. These are reported facts, not enforced actions.

The depot term and its 20% loss are retired in mt296 after native swap acceptance. All new item settlement uses
Trading Posts. `offer` opens at contact; priced orders require Coinage. See docs/mt-markets.md. Ending a pact ends
its diplomatic/scoring terms; market orders and irrevocable shipments are separate. Use `cancel` or `embargo` for
new market commitments. Delivered market goods, including each actual partial insertion, feed an active pair's
obligation ledger without a cut. Dispatch promises do not count as delivery.

Legacy active pacts retain cease-fire, shares and obligations. Their depot coordinates/chest references remain in
`legacy_depot`, with a retirement tick; the chests, ownership and exact inventories remain untouched. Automatic
transfers stop. Legacy pending proposals containing a depot expire rather than silently accepting revised terms.
The migration runs on the first normal pact access/tick, never in on_load, and is idempotent. `cut`, `move_s` and
`terms.depot` are no longer configurable. Historical ledgers remain historical records.

## Agent and human actions

- `diplomacy_send {to,text}` sends an authenticated message to every agent of the two contacted teams; six per team
  per game minute, 1..500 bytes. `diplomacy {with,since?,limit?}` reads only that conversation, with a pair-local cursor.
- `pact_propose {with,terms,note?,expires_min?}` creates a proposal (default lifetime 60 minutes). The recipient gets
  a fact that wakes it. Both sides can inspect the terms; only the recipient can `pact_accept {id}` or `pact_decline`.
- `pact_withdraw {id}` withdraws the proposer's pending offer. `pact_amend {id,terms}` proposes a replacement for an
  active pact; it takes effect only after the other side accepts. Duplicate active pacts for a pair refuse.
- `pact_end {id,note?}` ends immediately. Default cease-fire notice is zero; a configured positive `end_notice_s`
  delays only the lifting of cease-fire. A newer agreement survives an older notice deadline. A frozen human team's
  cease-fire persists through its freeze and restores the appropriate pact state on thaw.
- `pacts {}` returns the caller's contacted teams, proposals/pacts, current-hour delivered-goods ledger and the last
  obligation measurements. All pact actions are passive, including validation refusals.

Human roster members use `!pact propose|accept|decline|withdraw|amend|end|list {JSON}` through the same validators.
`!pact message` and `!pact messages` use explicit diplomacy. Human market commands are `!market ...` and remain separate.

## Records, scoring and operator control

Pacts persist under `storage.agent_harness.mt.pacts.by_id`, with proposal/acceptance/end authors and ticks, validated
terms, revisions via replacement records, delivered-goods ledger and obligation checks. Default checks run hourly;
ledger hours retain 24 hours. `mt_pacts {config?}` reads/configures remaining settings: `end_notice_s`,
`share_max_score`, `expires_min`, `check_s`, and enabled diplomatic terms. `mt_diplomacy {}` is the trusted operator
read of recent pair messages; it is not an agent endpoint. The system feed is similarly operator-only.

When a team's platform leaves a planet's orbit, the harness records the active pact partners and score shares then
(also kept per platform, past the 50-entry list). The edge-run platform's recorded departure governs allied scoring;
docs/mt-endgame.md has the end of the game. Money, orders, shipment volume and supplied
fixtures never contribute to the edge race. No market wealth leaderboard exists.

## Evidence

`vendor/factorio-harness/tests/mt281.lua` covers contact gates, validated shares/obligations, accept/decline/withdraw,
amendment, expiry, immediate and delayed cease-fire, replacement during notice, frozen relations, human commands,
departures, and legacy depot migration without inventory loss. `tests/mt296.lua` covers market settlement and the
arrival-to-obligation bridge. The native engine receipts and paired-run results are listed in
/Users/owner/code/pog-operator/report-mt296.md. Old mt281 depot-transfer results describe the retired implementation.
