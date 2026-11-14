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
Request receipts persist indefinitely: a used id never runs twice. Only pending transactions are ticked. (mt301) Over
a long game the records compact once a game minute: a team's receipts older than its newest 256 drop their copied
result, and committed ones older than its newest 4,096 keep only their tick (a replay answers `committed`,
`compacted`, whatever its arguments); delivered transactions with no escrow older than a pair's newest 200 fold into
per-item print counts (last price, count, tick), which `mt_market` last prices include; credited deposits older than
the newest 100 fold into a count and coin total; fill counters and book ids of orders no longer held are dropped.
Quarantined, waiting and in-transit transactions never fold. `mt_market {compact=true}` compacts now; its `records`
field reports the sizes. The audit totals are unchanged by compaction.
Errors mark both the transaction and market quarantined, then propagate to control.lua's existing runtime quarantine.
A deployment cannot silently resume an uncertain transaction; operator reconciliation is required.

Wallet means available plus unmatched buy reserves. Matched payments are irrevocable escrow outside that wallet.
Destroying the home Post spills floor(wallet/4), including unmatched reserves; bids are cancelled if necessary to
free that amount. The death unit number is a persistent receipt. Coin deposits credit actual removed items only.
Destroyed Posts are recreated near their original home on the next pass. Stage-1 Posts default indestructible.

`mt_market {}` is operator-only: audit, full pair transactions, viewer markers and last prices with a thin flag.
Markers interpolate between Posts only in that trusted operator response. `mt_market {config}` sets the experiment
switch, timings/cap and destructibility. Disabling refuses unsettled cargo and cancels unmatched orders. Coin audit:
wallets + payment escrow + circulating physical coin = cumulative grants plus research-income issuance; reserved is a subset of wallets.

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
metallurgic/electromagnetic/agricultural/cryogenic science pay 5,000 each (60,000 research total). No military or
promethium grants, mint, loan, catch-up bonus or freight loss implementation. Payments use only the team's own research.

Coinage combines all already-researched unpaid tiers into one `research:mt-coinage` payment. Every tier points to
its saved payment receipt. Subsequent research pays only unpaid tiers, once; legacy `granted=true` maps Coinage to
a legacy receipt without minting it again. Stored amounts never change when config changes. Grant sizes are integer
0..1,000,000; unknown tiers refuse before settings mutate. Payment facts name amount/cause and say "this does not
depend on when you research it"; neither facts nor public events reveal any other team's tier count or existence.

Research income replaces the scheduled stipend (mt299). Defaults: research_enabled=true,
growth_coin_per_rate=5, level_rate=0.001. The two rates accept finite numbers in 0..1,000,000, including zero
and fractions; research_enabled is boolean. The old growth_amount/start/every/enabled settings are no longer
accepted. A saved growth_enabled=false still disables research income unless research_enabled is explicitly set,
so old prepared-base saves retain their opt-out. Both fixture preparation/activation scripts set research_enabled=false.

Each team samples only its own technology progress once per game second and on research completion. Research value
is completed units times the sum of ingredient amounts times science reference prices, including fractional units
of the current technology and saved progress of cancelled research. Lab consumption, spoilage, productivity and
quality are never separate inputs: only research actually earned counts. A technology/level progress watermark
prevents cancellation, resumption, reversal, duplicate callbacks or reload from paying twice. Infinite levels use
the existing researchcost helper for the completed level's unit count. Script-researched completions update the
baseline but pay no income. Tier grants and Coinage tier back-pay retain their existing behavior.

At Coinage, upgrade of an existing save, and re-enabling income, existing current/saved/completed research is a
baseline, never research-income back-pay. Research while income is disabled does not enter the income window.
The rolling sum retains timestamped value increments for the last 432,000 ticks (two game hours); rate is always
sum/120 coin-value per minute, even in the first two hours. Growth pays only increases above the saved lifetime
high. Level income pays level_rate times each new value increment. A flat rate after the two-hour warmup receives
no further growth income; a 120,000-value burst sets only a 1,000/min high and pays 5,000 growth coin.

Both components accumulate into integer wallet coin with a persistent fractional remainder. Income updates total
issuance in the same operation. The saved ledger contains value, rate, high_rate, growth/level entitlements, paid,
remainder, rolling samples and the current hour's integer total. Hour boundaries emit one own-team fact and one
operator event, "Wallet +N coin: research income this hour", with no per-sample messages. Game hour is game.tick/216000;
ordinary one-second callbacks close each hour, while skipped callbacks coalesce the outstanding report once.

Science reference prices are valuation-only entries in K.PRICES; they do not admit tools or spoilable packs to
orders/cargo. The operator mt_market response exposes research_reference_prices. Nominal base-recipe costs use the
existing material cards (preserved, not repriced), no productivity/quality bonuses, free water, 10 per new raw item
(ores, carbon, ice, fruit, biter eggs, promethium chunks), and 2 per raw fluid/oil product. Molten metal is 2 per unit
(the casting equivalent of the existing 20/plate). This is a reference convention, not a scarcity/transport price.
Refunded catalysts/coolant are netted out; energy, machines, fuel and shipment costs are excluded.

| Pack | Reference coin per research unit's single pack | Recipe derivation |
| --- | ---: | --- |
| Automation | 60 | copper20 + gear40 |
| Logistic | 160 | inserter130 + belt30 |
| Military | 275 | (piercing magazine150 + grenade200 + 2 walls100)/2; 2.1 magazine batch yields two |
| Chemical | 585 | (2 engines180 + 3 advanced circuits260 + sulfur30)/2 |
| Production | 5950/3 | (furnace2500 + productivity module1650 + 30 rails60)/3 |
| Utility | 5870/3 | (3 low density750 + 2 processing units1400 + robot frame820)/3 |
| Space | 12 | (2 plates20 + carbon10 + ice10)/5 |
| Metallurgic | 712 | 3 carbide64 + 2 tungsten plates60 + 200 molten copper2 |
| Electromagnetic | 1001 | supercapacitor471 + accumulator440 + 25 electrolyte3.3 + 25 holmium solution0.3 |
| Agricultural | 124.6875 | bioflux26.25 + net cultivated egg98.4375 |
| Cryogenic | 86.872 | 3 ice10 + lithium41.2 + 3 net coolant5.224 |
| Promethium | 201.552 | (25 chunks10 + quantum processor1665.52 + 10 biter eggs10)/10 |

Intermediate derivations: acid=(5 sulfur30+plate20)/50=3.4; carbide=2 ore10+10 acid3.4+carbon10=64;
tungsten plate=4 ore10+10 molten iron2=60; holmium solution=(2 ore10+stone10)/100=0.3;
holmium plate=20 solution0.3=6; electrolyte=(stone10+10 heavy oil2+10 solution0.3)/10=3.3;
superconductor=(holmium6+copper20+plastic30+5 light oil2)/2=33;
supercapacitor=2 holmium6+2 superconductor33+4 circuit70+battery80+10 electrolyte3.3=471.
Fruit processing yields mash5 and jelly2.5; bioflux=(15 mash5+12 jelly2.5)/4=26.25;
nutrients=5 bioflux26.25/40=3.28125; cultivation yields one net egg per 30 nutrients=98.4375.
Lithium=(holmium6+50 brine2+50 ammonia2)/5=41.2; coolant=(50 fluorine2+50 ammonia2+fuel20+lithium41.2)/50=5.224;
carbon fiber=10 mash5+carbon10=60; quantum=carbide64+processing1400+superconductor33+fiber60+2 lithium41.2+5 net coolant5.224=1665.52.
Sources: https://github.com/wube/factorio-data/blob/master/base/prototypes/recipe.lua and
https://github.com/wube/factorio-data/blob/master/space-age/prototypes/recipe.lua (2.1 recipe definitions, checked d43).

Reference items now require the caller's own tier. Base items include ore, fuel coal, stone, plates, gear, cable,
electronic circuit, pipe20, iron stick10 and stone brick20. Logistic adds steel100. Chemical adds the pre-existing
plastic30/sulfur30/battery80/advanced-circuit260/processing-unit1400 cards and engine180, explosives20,
solid-fuel20, electric-engine350, flying-robot-frame820, low-density-structure750, rocket-fuel220. No planetary
cargo or science tools are admitted. Stock, offers, accepting calls and order validation share the gate; a locked
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
mint recipe. Audit now reads wallets + payment escrow + circulating physical coin = cumulative issuance (grants
and research income); reservations remain part of wallets. Native and unit evidence is in report-mt295.md.

## Full-game profile (mt302)
`mt_market {profile="full"}` sets a full game's market in one call. `tools/mt/start-mt.sh` sends it in
`POG_RUN_MODE=full` (`launch.py --run-mode full`) and refuses to start if it is refused. Test runs and prepared-base
fixtures keep the settings their save holds (Posts indestructible, ground spills, research income as the fixture set).
- `destructible=true`: home Posts can be destroyed. A destroyed Post is rebuilt empty at the team's home on the next
  market pass (each second). Goods inside it go with it; only its coin is accounted.
- `raid_share=0.25`: the destroyed home Post debits 25% of the wallet. Unmatched buy orders are cancelled first if
  the reserve would block the debit; matched coin is already in escrow and untouched.
- `wreck=true`: that coin lands in a coin wreck, a character corpse at the Post's spot. Inserters and robots cannot
  take from it, and `order_deconstruction` refuses it. Any team's character loots it with `mine {position, name:
  "character-corpse"}` (in reach, on a charted chunk). Coin put into any team's Post credits that team within a
  second. If no wreck can be made, the coin goes on the ground as before.
- Any other entity holding coin that dies (chest, belt, inserter hand, recycler, vehicle) spills its coin into a wreck
  the same way. A character keeps its coin: the game leaves it in its corpse, for any team to loot.
- Coin in a recycler comes back as coin (`mt-coin-recycling`, one for one). With nothing in front, the recycler drops
  its first result on the ground ahead of it, the rest into its output.
- Tier grants at their defaults, research income on (`research_enabled`, `growth_coin_per_rate`, `level_rate`).
- Pacts keep pacts.lua's DEFAULTS (`end_notice_s` 0, `share_max_score` 1.4, `expires_min` 60, all terms on). The
  `mt_market` reply shows `settings` and `pact_settings`.

The raided team's agents get one waking line ("Home Trading Post destroyed: N coin spilled in the wreck."); no other
team gets it. Native proof on 2.1.24: report-mt302.md, artifacts/mt302/mnative-*.json.
