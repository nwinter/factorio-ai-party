# Fresh game exercise

`POG_MT_FRESH=1` now enables `POG_GAME_TEST=1` unless explicitly disabled. Use
`tools/mt/launch.py` for the pinned 2.1 baseline. Do not resume a plaza save or
invoke contact/quality fixtures for this exercise.

After the roster's bots exist and before models start, `game_test.py` verifies
there are no existing contact records. It sends each active pair a private
opening: split factory and scouting work, build drills/furnaces/power/research,
gather the supplies, and explore toward the central resources. Instructions
arrive through the existing operator inbox on the agents' next harness reply.
There are no free items, technology unlocks, teleports or fabricated contacts.

The helper polls actual `mt_contacts`. A first chart or shot contact sends only
the two involved teams instructions for explicit diplomacy, an agreement and a
brief skirmish using their own gear. Existing cease-fires and notice periods
still apply. A positive-damage `shot` record triggers verification and further
production objectives. No kill scoring or game rules change. Models decide
their actions; objectives are not a claim that they completed them.

`runs/RUN/op/game-scenario.json` records delivery keys, observed contacts,
deadline and completion/failure. An existing receipt cannot be reset. The
helper is registered in `helpers.pid` and stops with the bounded session.
`POG_MT_TEAMS` restricts both opening and contact instructions. The broadcast
guardian checks exact agent IDs from the selected stream roster, including
reduced rosters, rather than assuming three teams.

Before going live: verify all models have chosen distinct identities, the
scenario is running, no agent is missing, and OBS displays the merged UI.
During the run, verify visible building, movement, teammate messages, real
contact, explicit diplomacy, and (if chosen under the rules) actual damage.
Preserve per-agent action counts and the final save. Report missing milestones
honestly; do not turn a stalled run into a manufactured success.

Scoped Muse launches use native `muse exec`, which supports excluding foreign
personal context, inside the same outer process scope as the other clients.
The deadline-controlled wrapper stops on a native error (including provider
limits); it never retries one in a loop. Native context and compaction last for
each turn. If Muse finishes before the game deadline, a fresh conversation
recovers from its own notes and keeps its chosen identity. No shared session
index is read. Main-run interactive Muse launches are unchanged.
