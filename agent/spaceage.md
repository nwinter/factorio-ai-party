
## Space Age

This world runs Space Age with Quality and Elevated Rails. The long-term goal replaces the rocket: send science up
the Space Age tree (planets, then promethium science, then infinite research). This changes the milestones after
blue science:

6. Rocket silo (Space Age version: red, green and blue packs only), a cargo landing pad, and a first space platform.
   Create it with `platform_create`, then put the `space-platform-starter-pack` into a ready rocket's cargo; the silo
   launches it.
7. Space science made on a platform (asteroid collectors, crushers, an assembler for `space-science-pack`), shipped
   down and consumed in Nauvis labs; thrusters.
8. Planets: Vulcanus (metallurgic), Fulgora (electromagnetic), Gleba (agricultural), then Aquilo (cryogenic).

What differs from the base game:

- Many technologies are triggers, not lab research: mine calcite, craft a tungsten plate, build an asteroid
  collector, create a platform. `technologies` names the trigger; `research` never queues them in labs.
- Rocket parts are 1 processing unit + 1 low-density structure + 1 rocket fuel; 50 per rocket. There is no satellite.
- The character hand-crafts more categories (belts are `pressing`, circuits and poles `electronics`); `craftable`
  and `craft` know this.
- Platforms are worked from remote view, wherever your character is. Use `platform=NAME` on `place_ghosts`,
  `paste`, `blueprint_place`, `deconstruct`, `grid` and `scan` (hub at 0,0). Change settings with `configure`,
  `platform_schedule` and `requests`, and read them with `platforms`. The hub builds ghosts from its own inventory
  (no robots), so items must reach the hub. Rockets launch on their own for the hub's requests when the silo has
  `auto_requests` on (`launch`). You cannot move items by hand on a platform.
- Riding a rocket (`launch ride=true platform=NAME`, standing at the silo) takes only your worn armor and guns. Ship
  everything else as cargo first; the harness refuses otherwise. Finish or cancel hand crafting and empty your hand
  too. The ride takes about 40 s; `status` shows `travel` (ascending, aboard, descending) and where you are.
- Aboard a platform you have no body. You act by remote view only: `platforms`, `platform_schedule`, `requests`,
  ghost tools with `platform=`, `research`, chat and the board. `land` drops you in a cargo pod to the planet below
  a stopped platform. You land on its landing pad if there is one, else where you last stood on that planet, else
  near its spawn, in about 20 s. You land with only your armor and guns, so send what you need down first: `drop`
  (the hub's drop slots) sends hub items to the planet below in a cargo pod. It goes to the landing pad if there
  is one, else it lands as a container near where you will land. Take the items out with `transfer`.
- On a new planet only about 48 tiles around you are charted, so `nearest` and `map` see little at first. Walk out to
  explore, or build a radar. On Vulcanus the first coal can be 90 tiles from the landing spot.
- If you die on another planet, you respawn on the planet where you last stood. If your platform is destroyed
  while you are aboard, you die.
- Asteroids hit platforms in flight and can destroy them. On a test world, a platform with four gun turrets and
  piercing rounds was destroyed halfway to Vulcanus, about a minute after it left orbit. A platform with twelve
  such turrets was destroyed at 80% of the way. One with 21 turrets and physical projectile damage and weapon shooting
  speed researched to level 6 arrived undamaged. The trip took about 6,800 ticks. `platforms` shows hub health.
- Quality: items and machines have a quality (`normal`, `uncommon`, `rare`, `epic`, `legendary`). Counts are per
  quality: a rare gear is not a normal gear. Actions default to `normal`; pass `quality` to move or build others.
- Spoilage: Gleba fruit, nutrients, bioflux, agricultural packs and eggs spoil. `status` shows `spoiling` (stalest
  first) and `scan` takes the field `spoil`. Spoiled pentapod and biter eggs hatch enemies wherever they are,
  your inventory and platforms included.
- Production is counted per planet and platform; the operator score sums them all.
