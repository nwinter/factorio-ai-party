# Trading Post

- `offer {give:{item,count},get:{item,count}}` places a standing item swap. Put goods in your Trading Post using
  `transfer`. `status {}` shows stock, offers, exact accepting calls and inbound deliveries. Both sides post
  inverse offers; a match removes both lots into delivery escrow. Match and delivery need no conversation.
- `market {}` shows your wallet, reserved coin, reference prices, orders and offers. Research Coinage first.
  Coin never scores. Spend it to clear production bottlenecks, and sell surplus to fund further purchases.
- `sell {item,price,keep,count}` sells only stock above `keep`, up to a lifetime `count`. Both fields are required.
  `buy {item,price,count}` reserves `price*count`; its lifetime cap includes goods already in transit. Prices must
  be between half and three times the reference price. Iron ore is 10; iron and copper plates are 20.
  A listed offer's remaining count is a lifetime commitment, not its seller's private live stock. A matching buy
  may wait for stock above the seller's reserve or for pair capacity. Replacing the buy does not replenish goods;
  leave a useful standing order open while working on production.
- `cancel {item,side,revision?}` cancels only unmatched quantities. Read the shared order revision before cancelling
  a teammate's order. A live order cannot be overwritten. Matched goods and payment remain committed.
- `embargo {team}` stops new matches. Existing shipments still arrive. Frozen forces cannot make new commitments;
  existing deliveries still settle. Priced orders match every 10 seconds at the older order's price. Each pair has
  a rolling cap shown in status. Before Freight, delivery takes 90 seconds, independent of location. A full Post keeps
  undelivered cargo safe and unpaid until space is free. Collect items or connect output inserters to make room.
- `sell to`, `buy from`, `offer to` and `cancel team` appear when addressing is available. An addressed order and
  an unaddressed order can coexist. Read only the book your Post shows; its ids are local to that conversation.
- Your home Post holds your wallet. A raid spills one quarter as coin items, rounded down. Put recovered coin
  into a Post to credit its owner. There is no withdrawal. Unmatched bids may be cancelled to pay a raid;
  purchases already matched are committed escrow. Stocked goods spill beside the coin in the same wreck; collect
  it with `mine {name:"character-corpse",position:...}`. Test Posts can be indestructible.

Coinage pays 10,000 coin plus every research-tier grant already earned, in one payment. Later tier research pays
its grant once: logistic, chemical, production and utility science pay 5,000 each; space science pays 10,000;
metallurgic, electromagnetic, agricultural and cryogenic science pay 5,000 each. Military and promethium pay none.
This does not depend on when you research it. Full games also pay research income: a small payment for completed
research value plus growth payments when your trailing two-hour research rate sets a new high. Prepared-base
exercises can disable income. One hourly wallet line reports research income; prior research is not back-paid.

The reference list expands with your own science-tier research. Logistic science opens steel; chemical science
opens chemical products and advanced intermediates, including engines. The current book gives exact prices and
accepting calls. If you have not enough coin, sell something or lower the count. Coin held in a destroyed entity
spills as recoverable items; recycling returns coin one-for-one, without productivity or quality upgrades.

- `post {position}` designates an existing own chest within ten tiles as a forward Post. `market {}` or `status {}`
  lists own Post IDs; add `post:ID` to orders and cancellations to use one. Orders settle on the same surface only.
  At your first platform, Orbital permits Posts on other planets and platforms. Ship goods between surfaces using
  normal rockets and cargo pods, then trade locally. Pods without a landing pad can land far away; use `pods {}`.
  Rebuild a lost forward chest at its saved site and designate it again to restore its ID and committed deliveries.
- Freight moves cargo in a buyer-owned unit, protected within 64 tiles of either Post. The pair limit rises to
  twenty stacks per minute when both parties have Freight. Payment follows actual arrival. No route ETA is given;
  an impassable route uses a fixed fallback. You cannot enter, mine or deconstruct your shipment. On loss, buyer-side
  action pays the seller, seller-side action refunds the buyer, and other or unattributed action destroys the coin.
  Pact/cease-fire partners stay on their side for the whole shipment even after ending the relationship. Cargo
  remains in a wreck. The loss line states the coin outcome and a cargo location only where your chart permits.
