# The end of the game (private, mt301)

Rules (Nick d27-d28, the private design doc): the first team whose platform reaches the solar-system edge wins.
Alone it scores 1.5. Allied, every member scores 1.0, split by the pact's shares (2 x share, at most 1.4). The
alliance that counts is the one recorded when the edge-run platform left its last planet. The team's Nauvis home must
still stand when the platform arrives. A team that wipes every other team also wins. A deadline, if the operator sets
one, ends the run by milestone ranking.

Code: `M.game` in `vendor/factorio-harness/mod/agent-harness_0.1.0/multiteam.lua` (no new module). Departures are
`pacts.lua`'s; `bots.lua` stamps each (re)spawn tick; `teamfeed.lua` carries the game-over system line.

## Edge arrival

- Each game second, and on every `on_space_platform_changed_state`, each team's platforms are read. A platform whose
  `space_location` is the target (`solar-system-edge`; setting `target`, e.g. `shattered-planet`) arrives once per
  stay there.
- Home: the team's `cargo-landing-pad` on `home_surface` (nauvis), and, with `home_power` (default on), an electric
  building of the team within `home_radius` (64) tiles of the pad with energy and not "no power". The pad itself has
  no energy source in 2.1, so "powered" is read from the base round it. Without a home the arrival is recorded,
  `arrival_refused` is alerted, the team's agents are told it does not count, and the game goes on; the platform
  counts if it leaves and arrives again with the home standing.
- Alliance: the pacts with a cease-fire in the platform's last departure from a planet. A pact ended after that
  departure still counts; one made after it does not; a pact without a cease-fire is no alliance. Shares come from
  that pact. With several allies, each ally scores 2 x its share of its own pact, the arriving team the mean of its
  shares x 2. With no departure on record (the harness was off when it left), the pacts holding at arrival count and
  `departure_unrecorded` is alerted.

## Wipe (detected, alerted, never restored)

- Down: no production building of the team (assembling machines, furnaces, drills, labs, silos, agricultural towers,
  every surface) that is not "no power" / "no fuel". The last one found is read first; else the first 200 of each
  surface; else all.
- Killed on respawn: a character of a team's agent killed by another team's force (any cause of that force) within
  `respawn_window_s` (120) of its spawn. Biters do not count.
- Wiped: down for `wipe_down_s` (600) AND every agent of the team killed on respawn since it went down. A team with no
  agents is never flagged. The `wipe` alert names each kill. If production comes back, `recovered` is alerted and the
  flag clears. Nothing restores a base or a character: restore is Nick's call, from a checkpoint.
- Wipe win: when every other team is wiped, `wipe_win_pending` is alerted and the run ends on
  `mt_game {end_by_wipe="TEAM"}` (refused unless every other team is flagged). `wipe_win='auto'` ends it at once.
- Agents are not told of a wipe.

## Milestones and the deadline

21 milestones, each once, at the tick the harness first saw it (each `check_s`, 60 s): automation, logistic,
military, chemical, production and utility science (technologies), rocket silo, first rocket, first platform (a hub),
space science, first, second and third inner planet reached (a platform stopped at Vulcanus, Fulgora or Gleba),
metallurgic, electromagnetic and agricultural science, Aquilo reached, cryogenic science, the edge discovered
(`stellar-discovery-solar-system-edge`), bound for the edge (a platform on a connection to the target), the edge.
Ranked by count, then by the tick of the latest (sooner first); equal both share a place. The public ranking
(`public_race.rank`) uses the same standings; money never ranks.

`mt_game {config={deadline_h=H}}` or `{deadline_tick=T}` sets a deadline; at it the run ends by milestones.
`mt_game {end_now=true}` ends it now.

## The result

Frozen at `storage.agent_harness.mt.game.result`: reason (`edge`, `wipe`, `milestones`), tick, winner (and winners
for a tie), kind, scores, the arrival (platform, departure with its pacts, home), the standings. Written to the
server's script-output `pog/mt-game-result.json` and `pog/mt-game.jsonl` (every alert and arrival) and the log. Told
to each team's agents as a waking line naming only teams it has had contact with (a team with no contact reads "The
run is over." and its score); to the feed as one system line (kind `game`); to the operator as the `game_over` alert.
Settings no longer change once frozen. `mt_game {clear_result=TICK}` (the result's tick) is the deliberate undo.

## Operator

- `mt_game {config?, end_by_wipe?, wipe_clear?, end_now?, clear_result?, alerts_since?}`: settings (`target`, `solo`,
  `home_surface`, `home_radius`, `home_power`, `wipe_down_s`, `respawn_window_s`, `wipe_win`, `deadline_tick` or
  `deadline_h`, `check_s`; refused whole), the result, standings, per-team down/wipe/kills/milestones, arrivals,
  alerts. `mt_game_tick` runs a step now (tests).
- `tools/mt/team_views.py` reads it each minute into views.json (`game`), shows the result and the loud alerts at
  the top of views.html, appends each new alert once to `runs/RUN/op/game-alerts.jsonl` and prints it.
- The public overlay ranks by the standings and shows the result as rebuilt text (`public_race.project_result`).

Tests: `vendor/factorio-harness/mod/tests/mt301_test.lua`, `mod/tests/mt301market_test.lua` (outside the agents' launch tree), `tools/test_mt301.py`,
`tools/test_mt_race.py`. Native evidence: /Users/owner/code/pog-operator/report-mt301.md.
