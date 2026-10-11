# Biters, pollution, evolution and defence (Nauvis, Factorio 2.0)

Our worlds run normal biters unless a run says peaceful. Values are wiki defaults for 2.0; map settings of a
given world may differ (read them from the world if it matters).

## Pollution: where it comes from

- Machines emit pollution while working (per minute at full power, wiki): boiler 30, burner mining drill 12,
  electric mining drill 10, steel furnace 4, stone furnace 2, electric furnace 1, assembler 1: 4,
  assembler 2: 3, assembler 3: 2. Boilers and drills dominate early; the mining and power areas are the
  biggest sources. Modules change it (speed/productivity raise it, efficiency lowers it).
- Pollution is a number per chunk (32x32 tiles), shown as the red cloud on the map. It does **no damage** to
  buildings or players. It only matters because it reaches enemy spawners and drives evolution.

## Spread and absorption

- A chunk above 15 pollution spreads 2% per 64 ticks to its four neighbours (neighbours send some back).
- Every tile absorbs a little per second; per chunk per minute (wiki, 2.0): water ~1.54, grass and dirt
  ~1.11, sand and red desert ~0.92, nuclear ground ~0.77; concrete, paths and landfill 0. 2.0.7 greatly
  raised tile absorption (water x5, other tiles ~x2.5), so 2.0 clouds are smaller than 1.1 players expect.
- Trees absorb (up to 0.001 per tree per second at full leaves) and get damaged above 60 pollution per chunk
  (they lose leaves and turn grey). Deserts and cleared forests let the cloud travel further.
- The cloud grows until total absorption matches emission. Spawners also remove the pollution they absorb.

## What triggers attacks

- Biters do not hunt the factory on their own. When the cloud reaches a chunk with spawners, each spawner
  absorbs pollution (above 20 in the chunk: 20 + 1% of chunk pollution every 64 ticks) and spends it to
  recruit units into an attack group. Pollution cost per unit: small biter 4, medium biter 20, big biter
  80, behemoth 400; small spitter 4, medium 12, big 30, behemoth 200.
- Attack groups launch every 1 to 10 minutes (random), wait up to 2 extra minutes for stragglers, then walk
  toward the pollution sources, typically the drills, boilers and furnaces that made it.
- On the way they attack what blocks the path, and switch to any military target nearby: turrets, the
  characters (agents), vehicles. Agents who walk into a group get killed (about 10 deaths in shake1).
- Attacking a nest makes nearby units defend it. Expansion parties (below) also destroy what is in the way.
- In shake1 pollution reached nests around 16 min; the first raid hit spawn at ~28 min.

## Evolution factor (0 to 1, default 2.0 factors)

- Raises with time (+0.000004 per second), with pollution produced anywhere (+0.0000009 per unit) and with
  each spawner destroyed (+0.002; worms don't count). Each gain is scaled down by (1 - evolution)^2, so it
  slows near the top and never reaches 1.
- Pollution produced counts, not pollution that reaches nests: absorbing the cloud reduces attacks but not
  evolution. Time alone adds about 1.4% per game hour early on.
- Approximate pollution needed (time ignored): 10% at ~123k, 20% at ~278k, 50% at ~1.1M, 90% at ~10M.
- Higher evolution means bigger units in attack groups, tougher nests (350 HP at 0 up to 3,500 at max) and
  faster spawning (spawner cooldown 6 s at 0 to 2.5 s at 1).

## Unit tiers (Nauvis)

| Tier | Biter HP | Spitter HP | Worm HP | Appears around evolution |
|---|---|---|---|---|
| Small | 15 | 10 | 200 | from start |
| Medium | 75 | 50 | 500 | biter ~20%, spitter ~40%, worm 30% |
| Big | 375 | 200 | 1,500 | ~50% |
| Behemoth | 3,000 | 1,500 | 3,000 | ~90% |

- Spitters have range 13 to 16 (gun turrets reach 18); worms are stationary turrets (range 25 to 48)
  placed at map generation (higher tiers further from spawn) and by expansion once evolution allows.
- Wiki tier thresholds are approximate (the table there is partly garbled); quote "around".

## Expansion

- Biters build new bases: every 4 to 60 minutes (default; the wiki text reverses the range) a group of
  5 to 20 units walks to a chunk within 7 chunks of existing spawners, preferring chunks with no player
  structures within 3 chunks, and turns into new spawners/worms. Over hours nests creep closer.

## Defence

- Gun turret (2.0 tech "Gun turret", red packs; shake1 had it at ~29 min): range 18, needs magazines
  (firearm, then piercing, later uranium). Cheap and the standard early answer. Empty turrets do nothing:
  re-arming is a job.
- Stone walls slow biters so turrets get more shots; gates let trains and players through.
- Laser turrets (blue-science era) use electricity, no ammo, range 24; heavy draw during big attacks.
  Flamethrower turrets (oil-fed, range 30) are strong vs groups. Military research raises damage.
- Good doctrine: turrets at every outpost (mining, power) and along the side facing nests before the cloud
  reaches them; clear nearby nests early while evolution is low (each nest killed adds a little evolution).
- Signs defence works: alerts show turrets being hit but few or no losses; the same area attacked repeatedly
  with only walls lost; dead biters, not dead drills. Signs it fails: losses of drills, belts, furnaces,
  boilers; turrets out of ammo; production dropping in the attacked area.

## Damaged vs destroyed vs enemies (common commentator error)

- Our harness/overlay alerts describe **our** buildings, not enemies:
  - "Base under attack near (x, y): gun-turret x2" = biters are hitting **our** entities in that area
    (the list names our buildings that took damage).
  - "7 lost near (12, -40): 4 stone wall, 3 gun turret (by 5 small biter)" = 7 of **our** entities were
    destroyed there; the last part names the attackers (killed by small biters).
  - "Luna is under attack" = the agent's character is in combat.
  - Agent board lines look like `attack near (16,16) by small-biter: character xN, wooden-chest x15 hit` and
    `losses in (3,2)-(20,20) 2 destroyed: 1 character, 1 wooden-chest by 2 small-biter`.
- A damaged building (health bar below full) is ours and still works; it is not an enemy and not "infected".
  It stays damaged until repaired: by hand with repair packs (2.0: Repair pack is a research; each pack
  restores 600 HP) or automatically by construction robots in roboport range.
- A destroyed building leaves a ghost that construction robots can rebuild (whether ghosts appear without
  research in 2.0 is not confirmed here; check before saying it).
- "Attacking" means biters reaching our structures. Seeing nests on the map is not an attack.

## Peaceful mode and settings

- Peaceful mode: biters exist but only fight back when attacked; pollution does not trigger attack groups.
  Our early benchmarks and co-op 1 were peaceful; shake1 used normal enemies. Rocket time achievements
  are disabled with peaceful or no enemies. Deathworld presets raise nest density and evolution factors.
- Enemy settings: no enemies, peaceful, normal (default); map settings also set evolution and expansion.

## Sources

- Factorio Wiki, "Pollution": https://wiki.factorio.com/Pollution (spread, tile absorption, 2.0.7 change,
  machine values, spawner absorption, unit costs)
- Factorio Wiki, "Enemies": https://wiki.factorio.com/Enemies (evolution factors, tiers, HP, expansion)
- Factorio Wiki, "Repair pack": https://wiki.factorio.com/Repair_pack
- Factorio Wiki, "Gun turret": https://wiki.factorio.com/Gun_turret
- Factorio Wiki, "Achievements": https://wiki.factorio.com/Achievements
- tools/stream/live.py (loss_events, attack_events text), docs/STREAM-NOTES.md (alerts),
  docs/BOARD-API.md and docs/BOARD-NOTES.md (agent alert lines), docs/studies/shake1.md (raids)
