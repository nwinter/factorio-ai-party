# Stage 1 markets (private mt296)

Spec: /Users/owner/code/pog-operator/markets/design-v3.md. The implementation is the market factory in pacts.lua,
instantiated through its existing require. No new requires or persistent on_load mutations. World n is untouched.

First contact opens the Post, `offer` and swap cancellation. Coinage costs 50 automation packs at 15 seconds each,
is disabled/invisible until contact, and grants 10,000 once per force. It opens `market`, `buy`, `sell`, `embargo`.
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
wallets + payment escrow + circulating physical coin = fixed grants; reserved is a subset of wallets.

Human commands use `!market offer|market|sell|buy|cancel|embargo {JSON}`, or `!market` / `!market list`.
They invoke the same validators and use saved human request sequence numbers.

Prepared fixture: tools/mt/market_fixture.py prepare / activate / brief. Use one paused saved map for both arms.
Green has eight rich iron cells and four small copper cells; Yellow mirrors them. Each has twelve drills/furnaces,
seven production cells, labs and a labelled power fixture. Poor ore totals 1,200 and should deplete near ten minutes
at four drills' nominal 120/minute. Objective: 1,800 circuits, 1,500 gears and 600 red packs produced after activation.
The gears consumed by red science count within the 1,500, not as extra iron demand. Supplied gears are not newly
produced gears. Expected missing plates are 1,390/1,700; a 10,000 grant buys 500 plates (36%/29%). These are fixture design
estimates until engine throughput is measured. The same stock position and items are preserved in the control.

The original pact depot remains pending real-engine swap acceptance. Retire it and its cut only after that gate;
cease-fire, shares and obligations remain, with delivered market goods counted toward delivery obligations.

The canonical fixture holds production machines/inserters inactive until activation. Startup may tick to deploy the
runtime, but cannot consume supplied inputs. POG_MT_PAUSED_START keeps models from starting before the operator
signal; the opening instruction permits profile/identity only. Activation asserts unchanged production/consumption
counts and stock before forcing contact. Enemy cease-fire is symmetric in both arms to isolate the production
mechanism; this trial does not test enemy pressure or combat. The independent QA run releases the held machines
for ten accelerated simulation minutes, verifies every line produces and the small patch depletes, then discards
that loaded state. Both trials restore the exact canonical paused save, at normal game speed.
