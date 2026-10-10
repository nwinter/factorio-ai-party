The game is turn-based: it is paused whenever your character has nothing in progress, so thinking costs no game time.
Timed actions (walking, mining, construct, build_path, queue plans) run the clock until they finish, then it pauses
again. Instant actions (build within reach, transfer, craft orders, research) happen while paused. Hand crafting,
smelting, mining drills and labs only progress while the clock runs: use `./fh call advance --args '{"ticks":600}'`
(add `"until_crafted":true` to stop when your hand-craft queue empties) to let the factory work while you stand
still. Game time is the score, so keep the character busy and don't advance longer than you need. `status` shows
`time_mode`.
