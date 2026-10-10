# Upstream

Vendored from https://github.com/CarsonBurke/factorio-harness (MIT, see LICENSE) at commit `bcc2e9d`
("docs: explain multiplayer setup options"). Local changes for player-of-games:

- `mod/agent-harness_0.1.0/clock.lua`: turn mode (game paused whenever no character work is in progress;
  `clock`, `advance` actions).
- Ore hand-mining through `mine_entity` at hand speed (setting `mining_state` did not survive a connected client).
- Engineer-agent changes from 2026-10-10 runs: build failure reasons and paused-clock building, `--wait` semantics
  and `fh wait`, `collect` leaves chests alone, `feed`, `inspect` IO/fluid connections, direct `wait_until`,
  `pole_route`, and smaller fixes. Details and evidence: `../../docs/HARNESS-CHANGES.md`.
