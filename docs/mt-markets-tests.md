# Stage 1 adversarial coverage

Stage-2 coverage (`mod/tests/mt303_test.lua`, auto-discovered by the full harness): every buyer/seller/third-party/
no-force loss branch across death, final mining, deconstruction, entry and raised script removal; registered
object destruction and missing-entity fallback; buyer pre-removal denial; duplicate terminal receipts; partial
arrivals; fixed no-path fallback; dispatch and newly acquired allies sticky after ending, including non-cease-fire
pacts; shared partners; own-source protection; no route ETA; uncharted loss coordinates and unknown-killer identity
hidden; identical unknown/invented addresses; conserved coin including destruction; reload of live units and
terminal losses; same-surface offworld and platform Post selection; no cross-surface settlement; exact stock-stack
transfer with quality/ammo/tags into one raid wreck; destroyed stock conservation after reload; private metrics.
The CLI suite tests reference/action gating at Freight; the market display suite admits loss events and no-ETA
platform markers without admitting private measurements. Native results are recorded separately in report-mt303.md.

Spec/reviews: /Users/owner/code/pog-operator/markets/design-v3.md,
/Users/owner/code/pog-operator/markets/review-codex.md,
/Users/owner/code/pog-operator/markets/review-fable-v2.md.

`tests/mt296.lua` runs the actual market factory with deterministic inventories; `mt296dispatch.lua` runs the actual
runtime registration/projection/cache/passivity boundaries; `mt296data.lua` checks prototype isolation and defaults.
These are under vendor/factorio-harness. `tools/mt/market_engine.py` is the separate real-2.1.24 gate, split around a
server save/restart. Its existence is not evidence it has passed: recorded engine-begin/resume receipts establish that.

| Review finding | Regression/acceptance evidence |
| --- | --- |
| Codex 1, settlement and request replay | Two pairs share one buyer reservation and one seller stock; lifetime count includes transit; 30/200 partial arrival pays only 30; full receiver retries without repeated payment; durable same-id/payload replay; changed payload refuses; terminal quarantine. Engine probe evicts 300 cache entries, saves in transit, restarts, replays, and receives only 1/100 in the native chest. |
| Codex 2, secrecy | No status/actions/prototypes/near-action suggestions before contact; cached bundle changes at rung/contact; unknown vs invented address identical; hidden seller projection removes the whole row; pair-local fill/book ids; B-C fill does not change A's advertised B quantity or show C. Fault details stay operator-only. |
| Codex 3, productivity/commission money | No commission, NPC or pay handler; repeated tick/reload/second contact grants once; all audit totals equal fixed issuance. |
| Codex 4, killer-dependent refund | Stage 1 has no losable caravan or killer-based settlement; exact-arrival payment and source removal tests show seller remains unpaid while escrowed goods cannot be reclaimed. Stage 2 combat attribution is deliberately absent. |
| Codex 5, stack corruption | Explicit allowlist; rare stock untouched; quality arguments, magazines, science tools and a prototype with spoil ticks refuse. Native engine removes/inserts normal goods and checks exact quantities. |
| Codex 6, merchant immunity/contact | No merchant force is created; Post is its team's force; chart contact is the real engine event in both engine probe and fixture. No stage-1 freight entity can accidentally chart a base. |
| Codex 7, NPC/wire teleporter | No NPC/payout/wire handlers; same-surface matching check; no goods created at dispatch, exact removed/delivered conservation. |
| Codex 8, replenishing purse | One fixed grant per researched force; no quantity-based grant; raid/deposit preserve total issuance; 300-request replay cannot mint. |
| Codex 9, polling/reserves/teammate churn | Required keep/count; duplicate live order refuses with revision-aware cancel; reserves enforce affordability; public/private coexist; accepting buy is capped by own available wallet; zero funds supplies a working status call; actual runtime refuses passively. Human chat shares the same race and freeze checks. Agent trial measures polling/refusals and idle time. |
| Codex 10, allocation/fee churn | Best price before age, resting ask/bid, same-tick force-index tie, one pass over pairs, cap retained after cancel/relist, both swap legs charged, duplicate tick cannot rematch. No market fee. mt281 legacy migration preserves stock and terms; native market_migration.py retains 37 old plates and credits 10 new arrived plates without a cut. |
| Codex 11, freeze/coin custody | Freeze and embargo stop new matches but committed cargo arrives; no withdraw; 14,000 -> 10,500 -> 7,875 raid; duplicate death ignored; reserved buys cancel when needed; deposit exact physical coin; failed spill quarantines future deposits. Native engine uses actual human freeze and on_entity_died. |
| Codex 12, misleading success metrics | Prepared matched control, production targets/baseline, decision latency separate from ETA, diplomacy/fill, sampled agent idle share, post-arrival consumption and conservative imported-consumption lower bound. No wealth scoring or leaderboard. Timer transit makes no piracy/watchability claim. |
| Fable ladder | Swap exists before money; technology enabled per force at contact; Coinage grants once; to/from only at second contact; all actions passive. |
| Fable raid without hauling reserves | No withdraw; exact raid arithmetic/deposit/duplicate death and reserved-wallet tests above. |
| Fable belt-fed shop | Refill source between batches; keep remains; lifetime matched count stops further dispatch despite more stock. |
| Fable 1, nothing to sell | Prepared complementary 8-rich/4-poor cells, finite poor ore and identical-map control; actual throughput/agent selling require the engine/trial receipts. |
| Fable 2, seller-side piracy | Seller wallet unchanged until exact insertion; escrow inaccessible to source/team; fixed safe timer only. Freight safe-zone/combat tests belong to its later stage. |
| Fable 3, tick size | Ore reference 10; integer 5..30 range; grant 10,000. |
| Fable 4, disguised wire/gift | 900-per-ore and 1-per-plate refuse; rolling pair stack cap survives relisting; oversized swap lot refuses. |
| Fable 5, address/ETA leaks | Address fields absent until second contact; hidden/nonexistent identical; all routes ETA 5,400 ticks; no agent coordinates for peer or viewer marker. |
| Fable 6, goods removed from escrow | Source emptied after dispatch; delivery still exact; same goods cannot match another pair. |
| Fable 7, counterparty keys | Addressed and unaddressed orders coexist, with explicit cancellation per key. |
| Fable 8, stream | Operator markers interpolate; last price carries count/tick and one-print thin flag; completed shipments vanish. mt290 owns stream rendering and its tests. |

Full receivers retain owned cargo and unpaid escrow until space becomes available. This is an explicit persistent
waiting state, not a destroyed/refunded shipment. There is no automatic expiry or recovery command; a quarantined
transaction requires operator reconciliation. These limitations must remain visible in the report.

Commands (from harness directory): `npm test`, `lua tests/mt296.lua`, `lua tests/mt296dispatch.lua`,
`lua tests/mt296data.lua`. From repository: `agent-python tools/test_lua52_syntax.py`, `luac -p` on changed Lua,
`agent-python tools/mt/test_market_metrics.py`. Engine and trial commands require the server claim and mt290 release.

## Research income (mt299)

The full harness suite auto-discovers tests/mt299.lua. Its regressions cover progress and saved cancellation progress,
fast completions, infinite-level cost, pre-Coinage exclusion plus tier back-pay, script grants, conservation
(issuance = grants + research income), serialized state reload mid-window, flat-rate warmup/plateau, burst damping,
window expiry, fractional carry, hourly messages/replay, config validation/atomicity, disabled/legacy fixtures,
and a force lookup that throws on any rival read. mt296.lua retains grant/back-pay and physical custody checks
and verifies there are no scheduled payments after 200 idle game hours. Native-probe evidence is recorded separately
in the operator's report-mt299.md; deterministic fixtures do not establish an engine result.
