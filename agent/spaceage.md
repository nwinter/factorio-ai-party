
## Space Age

This world runs Space Age with Quality and Elevated Rails. Science goes past the rocket: space platforms, the
four planets (Vulcanus, Fulgora, Gleba, Aquilo, each with its own science pack), and the Shattered Planet beyond the
solar system's edge.

What differs from the base game:

- Space platforms: the rocket silo (Space Age version: red, green and blue packs only) launches them. Create one with
  `platform_create`, then put the `space-platform-starter-pack` into a ready rocket's cargo. Items sent down from a
  platform land on a cargo landing pad.
- Space science is made on a platform (asteroid collectors, crushers, an assembler for `space-science-pack`) and
  shipped down to labs on the ground.
- Many technologies are triggers, not lab research: mine calcite, craft a tungsten plate, build an asteroid
  collector, create a platform. `technologies` names the trigger; `research` never queues them in labs.
- Rocket parts are 1 processing unit + 1 low-density structure + 1 rocket fuel; 50 per rocket. There is no satellite.
- The character hand-crafts more categories (belts are `pressing`, circuits and poles `electronics`); `craftable`
  and `craft` know this.
- Platforms are worked from remote view, wherever your character is. Use `platform=NAME` on `place_ghosts`,
  `paste`, `blueprint_place`, `deconstruct`, `grid` and `scan` (hub at 0,0). Change settings with `configure`,
  `platform_schedule` and `requests`, and read them with `platforms`. The hub builds ghosts from its own inventory
  (no robots), so items must reach the hub. A `paste` is all or nothing, as a player's; `mode=forced` (shift-paste)
  places the ghosts that fit, marks trees and rocks in the way, lists the rest in `not_placed` and keeps the
  blueprint's wires between what it placed (`wires`); `mode=superforced` marks our own entities in the way too. A
  blueprint holding a hub is placed by its hub on the platform's hub (`anchor`, `aligned` in the reply). Rockets launch on their own for the hub's requests when the silo has
  `auto_requests` on (`launch`). You cannot move items by hand on a platform.
- Riding a rocket (`launch ride=true platform=NAME`, standing at the silo) takes only your worn armor and guns. Ship
  everything else as cargo first; the harness refuses otherwise. Finish or cancel hand crafting and empty your hand
  too. The ride takes about 40 s; `status` shows `travel` (ascending, aboard, descending) and where you are.
- Aboard a platform you have no body. You act by remote view only: every read, and the calls with `platform=` or
  `surface=` (the space-age topic lists them). `land` drops you in a cargo pod to the planet below
  a stopped platform. You land on its landing pad if there is one, else where you last stood on that planet, else
  near its spawn, in about 20 s. You land with only your armor and guns, so send what you need down first: `drop`
  (the hub's drop slots) sends hub items to the planet below in a cargo pod. It goes to the landing pad if there
  is one, else it lands as a container near where you will land. Take the items out with `transfer`.
- On a new planet only about 48 tiles around you are charted, so `nearest` and `map` see little at first. Walk out to
  explore, or build a radar. On Vulcanus the first coal can be 90 tiles from the landing spot.
- If you die on another planet, you respawn on the planet where you last stood. If your platform is destroyed
  while you are aboard, you die.
- Asteroids hit platforms in flight and can destroy them; turrets on a platform shoot them down. `platforms` shows
  hub health. A trip from Nauvis to Vulcanus takes about 6,800 ticks.
- Quality: items and machines have a quality (`normal`, `uncommon`, `rare`, `epic`, `legendary`). Counts are per
  quality: a rare gear is not a normal gear. Actions default to `normal`; pass `quality` to move or build others.
- Spoilage: Gleba fruit, nutrients, bioflux, agricultural packs and eggs spoil. `status` shows `spoiling` (stalest
  first) and `scan` takes the field `spoil`. Spoiled pentapod and biter eggs hatch enemies wherever they are,
  your inventory and platforms included.
- Production is counted per planet and platform; the operator score sums them all.
