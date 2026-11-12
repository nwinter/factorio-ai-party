# Trading Post

- `offer {give:{item,count},get:{item,count}}` places a standing item swap. Put goods in your Trading Post using
  `transfer`. `status {}` shows stock, offers, exact accepting calls and inbound deliveries. Both sides post
  inverse offers; a match removes both lots into delivery escrow. Match and delivery need no conversation.
- `market {}` shows your wallet, reserved coin, reference prices, orders and offers. Research Coinage first.
  Coin never scores. Spend it to clear production bottlenecks, and sell surplus to fund further purchases.
- `sell {item,price,keep,count}` sells only stock above `keep`, up to a lifetime `count`. Both fields are required.
  `buy {item,price,count}` reserves `price*count`; its lifetime cap includes goods already in transit. Prices must
  be between half and three times the reference price. Iron ore is 10; iron and copper plates are 20.
- `cancel {item,side,revision?}` cancels only unmatched quantities. Read the shared order revision before cancelling
  a teammate's order. A live order cannot be overwritten. Matched goods and payment remain committed.
- `embargo {team}` stops new matches. Existing shipments still arrive. Frozen forces cannot make new commitments;
  existing deliveries still settle. Priced orders match every 10 seconds at the older order's price. Each pair has
  a rolling cap of ten stacks per minute. Delivery takes 90 seconds, independent of location. A full Post keeps
  undelivered cargo safe and unpaid until space is free. Collect items or connect output inserters to make room.
- `sell to`, `buy from`, `offer to` and `cancel team` appear when addressing is available. An addressed order and
  an unaddressed order can coexist. Read only the book your Post shows; its ids are local to that conversation.
- Your home Post holds your wallet. A raid spills one quarter as coin items, rounded down. Put recovered coin
  into a Post to credit its owner. There is no withdrawal. Unmatched bids may be cancelled to pay a raid;
  purchases already matched are committed escrow. Test Posts are indestructible until raids are enabled.
