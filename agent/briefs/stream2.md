# Engineer task: board and alerts on the stream overlay (branch eng/stream2)

Extend the stream overlay and director service in `tools/stream/` (read `docs/STREAM-NOTES.md`) per the "Overlay"
section of `docs/BOARD-API.md`: a board panel (recent board events with agent avatars: posted / taken / done /
blocked; open unowned request count; active claims), a harness changelog line when a `harness` item is done, and
alert banners for attacks/losses (also let the director cut to attacks). The harness side (`board_events`,
`board`, alerts) is being built on branch eng/board; develop against mock data matching the contract first, then
check the real shapes from that branch (`git show eng/board:...`) once it has them. Keep the page calm and readable at
stream resolution with 9 agents; fit the board panel into the existing right column (rebalance cards/production/chat
if needed). Also: show each agent's motto (from `profiles`) on its card, and show "profile not set" subtly.

Rules: read-only polling only (never gameplay actions); don't change the OBS `pog` profile output settings or start
recordings/streams; you may switch OBS scenes for screenshots and switch back (`tools/stream/obs_shot.py`). Never
touch worlds a, b, c, n except read-only polling of n (the finished shakedown world: real data with 9 bots). Commit to
eng/stream2 in small commits ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; don't push or
touch main. Update `docs/STREAM-NOTES.md` with a screenshot. Stop by the deadline in deadline.txt.
