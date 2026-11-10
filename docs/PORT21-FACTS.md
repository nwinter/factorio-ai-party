# Engine facts used by the 2.1.24 harness

Native macOS 2.1.24 + Space Age + recycler + this harness, on an isolated migrated copy. Evidence is under
`/Users/owner/code/personal/player-of-games/artifacts/port21-p3`. Measurements describe these fixtures, not every
mod or quality. The preserved 2.0.77 baseline and old measurements remain separate.

| Dependency | 2.1.24 evidence | Harness consequence |
|---|---|---|
| Recipe means, science and quality | Uranium .007/.993; scrap gear .2; recycling iron .5; egg productivity exemptions; labs retain fractional capacity separately from inventory | Native means and science capacity, rather than item durability; quality module effects already use probability scale |
| Fluid stock/topology | Own pipe capacity100, joined segment200; private and shared stores distinct; boiler6water/s→60steam/s; conservation checked | Indexed stores; count each segment once and private stores separately |
| Rocket inventory | Empty0 slots grows to26 distinct items, 1000kg lift | Weight bound, no20-slot bound; preserve stack metadata on partial transfers |
| Automatic rockets | One pod delivered iron10+copper10; next compiled request iron180+copper180 | Read engine-selected mixed batch; no per-item full-rocket readiness claim |
| Platform requests | Native provider100→90, recipient0→10; planet retention vs platforms-only, import anywhere | Preserve request_from and location; report platform deliveries |
| Departure/inactivity | Trash1000→0 one tick before departure; incoming platform pod resets inactivity (31 samples, age1tick) | Native and harness waits agree |
| Cargo pod capacity | 10 fixed slots; iron insertion caps at1000, length stays10 | Existing drop splitter remains10 slots |
| Thruster burn | Normal/rare/legendary2/3.2/5 of both fluids per tick above80%; stepped linear curve below80% matches within .000006 units in sampled intervals; tanks1000 | Quality burn model retained; no reuse of2.0 acceleration fixture |
| Foundation counting | One medium metallic asteroid destroyed2 tiles and itself;2 ghosts; after supply, hub rebuilt2 using2 items, production consumption0 | Count tile ghosts/build events, not production stats; no foundation collision-damage forecast |
| Character mine_tile | Character with no player mined stone-path→grass and received1 stone brick | Native bug fixed; existing guarded timed mining implementation remains compatible |
| Asteroid geometry | 3000ticks, Nauvis–Vulcanus10–50%, reset2km/tick, height16; widths21/101/301:39/79/160. Scheduled width101:93 | Provisional native fit and explicit scope in replies; old calibration/history archived |

The first thruster fixture had no schedule and consumed no fuel; the scheduled retry is the burn evidence. The
first timing callback passed a platform where launch_rocket requires its hub; it stopped the private scenario.
It was corrected and retried from the immutable prior checkpoint. Neither was a harness runtime failure.

Unmeasured: other routes/hull heights/speeds for the asteroid fit; statistical confidence for all scheduled hulls;
collision damage distributions; all silo qualities; artillery/find/rehash timing; splitter half-swings; cargo-bay
unloading-distance changes; vehicle braking; lightning; railgun buffer; cross-architecture performance ratios.
Native insertion/quality transfers, undergrounds, fluids, and science have earlier order evidence; they are not
repeated here. Joined-client chunk activation and screenshot ownership are checked with the mt smoke in order10.
The normal silo/hub timing fixture is recorded below when complete; queue completion always polls native state.

Normal ready silo: launch accepted at tick130127492, hub item arrived2100ticks later (**35s**). Hub hatches:
three pods immediately, fourth unavailable, first hatch free after**120ticks**. Ground pods crossed to the planet
surface around501–512ticks; that is not landing. The native finished-descending and delivered-cargo events on a
second three-pod fixture occurred at**1099/1101/1102ticks** (18.32–18.37s), spawning cargo-pod containers. Existing
~40s up/~20s down messages are approximate observations; actual completion is native state/event driven.
Evidence: `order8-timing21.json`, `order8-pod-events21.json`; first failed timing callback retained separately.
