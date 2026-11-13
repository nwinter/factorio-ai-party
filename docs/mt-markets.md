# Stage 1 markets (private mt296)

Spec: /Users/owner/code/pog-operator/markets/design-v3.md. The implementation is the market factory in pacts.lua,
instantiated through its existing require. No new requires or persistent on_load mutations. World n is untouched.

First contact opens the Post, `offer` and swap cancellation. Coinage costs 50 automation packs at 15 seconds each,
is disabled/invisible until contact, and pays its 10,000 base grant plus earned research-tier back-pay once. It opens `market`, `buy`, `sell`, `embargo`.
`to`/`from`/cancel-team appear only after a second contact. All actions, including refusals, are passive. Status
carries the current block. Schemas and reference entries are gated; bundle identity changes with contact/rung.

The finite allowlist contains ore, coal, stone, plates, gears, cable, circuits, plastic, sulfur and batteries.
Science packs are excluded because partial pack durability is stack state. All cargo is normal quality. No NPC,
commissions, withdrawal, wire, merchant force, fee, productivity issuance or economic victory exists.

Orders are shared by force and keyed by side/item/counterparty. A second live order refuses with an executable
cancel call; optional revision prevents cancelling a changed order. Buy reserves count*limit price. Sell requires
keep and lifetime count. Cancel cannot recall matches. Prices are integer 0.5..3 times reference (ore 10, plates 20).
Matching occurs in one deterministic pass every 600 ticks, by pair order from mt.order and item name. Best ask/bid,
age, then engine force index determine priority; the resting order sets price. Every pair shares a rolling ten-stack
cap across items and directions; swaps charge both legs. Wildcard stock/budget is consumed once across all pairs.
A peer sees only its pair's fill ids and pair-specific advertised remainder, never competing-pair depletion or reasons.

Matched goods move out of the Post into persistent stateless escrow. Each leg records removed and delivered counts;
buyer coin leaves wallet into transaction escrow. Arrival after 5,400 ticks pays only the exact inserted quantity.
A full receiver remains waiting, with cargo and unpaid escrow intact until space is made. Cancellation, embargo and
freeze stop new commitments/matches; existing deliveries continue. There is no distance-dependent ETA or early payment.
Completed/quarantined transactions and request receipts persist indefinitely. Only pending transactions are ticked.
Errors mark both the transaction and market quarantined, then propagate to control.lua's existing runtime quarantine.
A deployment cannot silently resume an uncertain transaction; operator reconciliation is required.

Wallet means available plus unmatched buy reserves. Matched payments are irrevocable escrow outside that wallet.
Destroying the home Post spills floor(wallet/4), including unmatched reserves; bids are cancelled if necessary to
free that amount. The death unit number is a persistent receipt. Coin deposits credit actual removed items only.
Destroyed Posts are recreated near their original home on the next pass. Stage-1 Posts default indestructible.

`mt_market {}` is operator-only: audit, full pair transactions, viewer markers and last prices with a thin flag.
Markers interpolate between Posts only in that trusted operator response. `mt_market {config}` sets the experiment
switch, timings/cap and destructibility. Disabling refuses unsettled cargo and cancels unmatched orders. Coin audit:
wallets + payment escrow + circulating physical coin = cumulative research/stipend issuance; reserved is a subset of wallets.

Human commands use `!market offer|market|sell|buy|cancel|embargo {JSON}`, or `!market` / `!market list`.
They invoke the same validators and use saved human request sequence numbers.

Prepared fixture: tools/mt/market_fixture.py prepare / activate / brief. Use one paused saved map for both arms.
Green has eight rich iron cells and four small copper cells; Yellow mirrors them. Each has twelve drills/furnaces,
seven production cells, labs and a labelled power fixture. Poor ore totals 1,200 and should deplete near ten minutes
at four drills' nominal 120/minute. Objective: 1,800 circuits, 1,500 gears and 600 red packs produced after activation.
The gears consumed by red science count within the 1,500, not as extra iron demand. Supplied gears are not newly
produced gears. Expected missing plates are 1,390/1,700; a 10,000 grant buys 500 plates (36%/29%). These are fixture design
estimates until engine throughput is measured. The same stock position and items are preserved in the control.

The pact depot and its cut are retired after real-engine swap acceptance. Legacy chests retain their contents;
active cease-fire, shares and obligations remain. Pending depot proposals expire. Only actual market arrivals count
toward active-pact delivery obligations. No competing automatic depot pipe remains.

The canonical fixture holds production machines/inserters inactive until activation. Startup may tick to deploy the
runtime, but cannot consume supplied inputs. POG_MT_PAUSED_START keeps models from starting before the operator
signal; the opening instruction permits profile/identity only. Activation asserts unchanged production/consumption
counts and stock before forcing contact. Enemy cease-fire is symmetric in both arms to isolate the production
mechanism; this trial does not test enemy pressure or combat. The independent QA run releases the held machines
for ten accelerated simulation minutes, verifies every line produces and the small patch depletes, then discards
that loaded state. Both trials restore the exact canonical paused save, at normal game speed.

## Full-game money supply (d42e)

The approved table is in pacts.lua's market CFG.grants, configurable through the operator's mt_market endpoint.
Coinage pays 10,000; logistic/chemical/production/utility science pay 5,000 each; space science pays 10,000;
metallurgic/electromagnetic/agricultural/cryogenic science pay 5,000 each (60,000 research total). No military,
promethium, mint, loan, catch-up bonus or freight loss implementation. Payments use only the team's own research.

Coinage combines all already-researched unpaid tiers into one `research:mt-coinage` payment. Every tier points to
its saved payment receipt. Subsequent research pays only unpaid tiers, once; legacy `granted=true` maps Coinage to
a legacy receipt without minting it again. Stored amounts never change when config changes. Grant sizes are integer
0..1,000,000; unknown tiers refuse before settings mutate. Payment facts name amount/cause and say "this does not
depend on when you research it"; neither facts nor public events reveal any other team's tier count or existence.

Default full-game growth settings: growth_enabled=true, growth_start_hours=60, growth_every_hours=20,
growth_amount=20000. Game hour uses game.tick/216000, not wall time or agent sessions. Each team's durable period
cursor/payment IDs make duplicate ticks/reloads harmless; missed notifications after Coinage are caught up.
Research back-pay is distinct from stipends: Coinage acquired between boundaries waits for the next boundary.
A disabled stipend advances its cursor without paying, so re-enabling does not pay disabled periods. Existing
pre-feature saves start their stipend schedule at the next boundary. Market fixture prepare/activate and the
supplied cargo/circuit fixture explicitly disable growth; the canonical saved fixture is unchanged on disk.

Reference items now require the caller's own tier. Base items include ore, fuel coal, stone, plates, gear, cable,
electronic circuit, pipe20, iron stick10 and stone brick20. Logistic adds steel100. Chemical adds the pre-existing
plastic30/sulfur30/battery80/advanced-circuit260/processing-unit1400 cards and engine180, explosives20,
solid-fuel20, electric-engine350, flying-robot-frame820, low-density-structure750, rocket-fuel220. No planetary
items or science tools are admitted. Stock, offers, accepting calls and order validation share the gate; a locked
item cannot be acquired through a swap's other leg. Existing prices are retained, not silently repriced.

New card derivations use the ordinary 2.1 recipes and existing material cards, with water free and an explicit
2 coin/unit reference for liquid oil products (not separately traded). This is a nominal recipe-cost estimate,
not a runtime production-cost measurement, and includes no productivity/quality advantage:
- engine = steel100 + gear40 + 2 pipe20 = 180;
- explosives = (coal10 + sulfur30)/2 = 20;
- solid fuel = 10 light oil * 2 = 20;
- electric engine = engine180 + 2 circuits70 + 15 lubricant*2 = 350;
- robot frame = electric engine350 + 2 batteries80 + steel100 + 3 circuits70 = 820;
- low density = 20 copper plates20 + 5 plastic30 + 2 steel100 = 750;
- rocket fuel = 10 solid fuel20 + 10 light oil*2 = 220.
Sources: tools/analyst/kb/space-age-2.1.24/recipes.json and the installed 2.1.24 recycler/recycling.lua. The existing
ore10/plate20 reference convention is retained. Price bands and pair capacity are unchanged.

Physical coin in inventories, inserter hands, belt lines or ground entities spills on death with quality preserved.
An unfinished coin-recycling craft also returns its consumed coin. Remove custody before spilling to avoid duplicate
corpse inventories; a durable death receipt prevents retry, and incomplete mutations quarantine the market. Such
spills change neither physical circulation nor issuance. The home-Post wallet spill stays unchanged. Recycler data
provides exactly 1 coin -> 1 coin, with automatic recycling, productivity and quality upgrades disabled; it is not a
mint recipe. Audit now reads wallets + payment escrow + circulating physical coin = cumulative issuance (research
and stipends); reservations remain part of wallets. Native and unit evidence is in report-mt295.md.
