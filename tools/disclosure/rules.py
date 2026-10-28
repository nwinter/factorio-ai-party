"""(d28 batch317 cp1) Progressive disclosure: when each unit of the agents' kit unlocks, per force (team).

A design inventory only: nothing here changes what agents see yet (docs/DISCLOSURE.md; tools/disclosure/build.py writes
manifest.json from these rules, describe.json and the agent docs).

A condition is a list of atoms. Its world atoms are a gate (all must hold); any one of its other atoms then unlocks
the unit; a unit with world atoms only is in or out from tick 0. An argument also needs its action, and a doc entry
its topic's world gate. An atom is one string:
  start                       in the kit at tick 0
  world:FLAG                  a setting of the world, fixed for the run (space_age, quality, enemies, team, stream,
                              humans): a unit whose only atoms are world atoms is in or out from tick 0
  research:TECH               the force has researched TECH (on_research_finished; at load: force.technologies)
  built:ENTITY[|ENTITY...]    the force has one of these entities (force.get_entity_count > 0, read in a slow sweep)
  arrived:PLANET              a character or platform of the force at PLANET (surface or space_location, slow sweep)
  event:KIND                  first seen by the force (EVENTS below: forwarded engine events or harness records)
  habit:KIND:N                the force's agents did KIND N times (HABITS below: counted in the harness's own handlers)
  scale:KIND:N                the force's size or age reached N (SCALES below: slow sweep)
  with:UNIT                   unlocked together with another unit (a doc entry with its actions, an argument with a
                              group); resolved by build.py, never stored
  self                        an alert's own trigger: off until it first fires; that firing carries the unlock line
  never                       not agent-facing (operator or test actions): never listed for agents
"""

WORLD = {
    "space_age": "the Space Age mod is on (POG_SPACE_AGE=1)",
    "quality": "the Quality mod is on (with Space Age)",
    "enemies": "enemies are on (POG_ENEMIES is not peaceful): biters attack",
    "team": "more than one agent plays in the force",
    "stream": "the run is streamed with viewers (profiles, polls, viewer chat)",
    "humans": "human players may join (co-op)",
}

# Each event: how it is detected and what it costs (docs/DISCLOSURE.md, "Triggers").
EVENTS = {
    "resource_depleted": "a resource entity of a patch mined out by the force's drill or hand (on_resource_depleted: "
                         "needs one more forwarded event in control.lua, a mod version change)",
    "enemy_seen": "an enemy unit, worm or nest charted or within 64 tiles of the force's entities (threat.lua's nest "
                  "news and attack groups per force)",
    "spitters": "a spitter or medium-or-larger biter seen (on_entity_damaged/on_entity_died causes, threat.lua)",
    "worms": "a worm turret seen or hitting the force",
    "attacked": "the force's buildings attacked the first time (threat.lua attacked areas, per force)",
    "loss": "the force's first loss incident (losses: buildings destroyed)",
    "pollution_attack": "an attack group formed from the force's pollution (on_unit_group_finished_gathering)",
    "died": "an agent of the force died",
    "demolishers": "a demolisher seen on Vulcanus",
    "pentapods": "a pentapod (wriggler, strafer, stomper) or egg raft seen on Gleba",
    "asteroids": "the force's platform hit by an asteroid (platform hits, status alerts)",
    "spoiled": "an item of the force spoiled the first time (spoilage made, item production statistics)",
    "low_power": "an electric network of the force on low or no power the first time (powercut.lua)",
    "starved": "a machine of the force stopped for an ingredient for 5 minutes",
    "second_surface": "the force has a platform, or a character on a second planet",
    "hub_full": "a platform hub of the force full",
    "freight": "the force's first cargo pod landed on a surface from a platform",
}

# Each habit: counted where the harness already handles the call (no tick cost), per force, bounded.
HABITS = {
    "hand_crafts": "hand crafts of one item (craft calls' counts summed per item)",
    "hand_belts": "belts placed one call at a time by hand (build with one belt entry)",
    "hand_poles": "electric poles placed by hand",
    "hand_feeds": "feed or transfer calls into machines of one kind",
    "chest_moves": "transfer calls between the same two containers",
    "walked": "tiles walked by the force's agents within one game hour",
    "refused": "refusals of the unit's own action (any reason): its dry_run, skip_failed and the like",
    "refused_builds": "build, place_ghosts or mine calls refused for the spot (blocked, out of reach, wrong tile)",
    "repeat_calls": "calls of one action with the same argument shape within 10 game minutes",
    "sleeps": "sleep or wait calls",
    "board_items": "board items posted by the force",
    "lookups": "help or describe lookups that found no topic",
}

SCALES = {
    "machines": "assemblers, furnaces and chemical plants the force has (get_entity_count by name)",
    "labs": "labs the force has",
    "drills": "mining drills the force has",
    "belts": "transport belts of every tier",
    "inserters": "inserters of every kind",
    "turrets": "turrets of every kind",
    "agents_on_surface": "agents of the force on one surface",
    "game_hours": "game hours since the force's first agent spawned",
    "shifts": "shifts the force has played (the run's shift counter)",
}

T0 = ["start"]
TEAM = ["world:team"]
STREAM = ["world:stream"]
NEVER = ["never"]
ENEMY = ["event:enemy_seen"]
SECOND = ["event:second_surface"]
ROBOTS = ["research:construction-robotics", "research:logistic-robotics", "built:roboport"]
LOGISTIC = ["research:logistic-system", "research:logistic-robotics"]
CIRCUIT = ["research:circuit-network"]
RAIL = ["research:railway", "built:locomotive|straight-rail"]
SILO = ["research:rocket-silo", "built:rocket-silo"]
PLATFORM = ["research:space-platform", "built:space-platform-hub"]
TURRET = ["research:gun-turret", "built:gun-turret|laser-turret|flamethrower-turret"]
VEHICLE = ["built:car|tank|spidertron|locomotive"]
OIL = ["research:oil-processing", "built:pumpjack"]
GLEBA = ["arrived:gleba", "research:agriculture"]
SPOIL = ["arrived:gleba", "research:agriculture", "research:captive-biter-spawner", "event:spoiled"]
QUALITY = ["research:quality-module"]
BIG_BASE = ["scale:machines:40"]

# The tick-0 core: what a team sees first (the early game: walk, mine, craft, place, look, research, talk).
ACTIONS = {
    # look
    "observe": T0, "status": T0, "clock": T0, "inspect": T0, "scan": T0, "nearest": T0, "map": T0, "ores": T0,
    "inventory": T0, "recipes": T0, "craftable": T0, "technologies": T0, "research_options": T0, "describe": T0,
    "grid": ["habit:refused_builds:3"],
    # move, mine, craft, place
    "walk": T0, "move_to": T0, "mine": T0, "craft": T0, "cancel_craft": T0, "build": T0, "rotate": T0,
    "pickup": T0, "collect": T0, "transfer": T0, "feed": T0, "refuel": T0, "deconstruct": T0,
    "nearest_water": T0,
    # research and pace
    "research": T0, "research_next": T0, "research_done": ["scale:game_hours:1", "habit:repeat_calls:5"],
    "sleep": T0, "wait_ticks": T0, "stop": T0,
    # talk
    "say": T0, "tell": TEAM, "tells": TEAM, "chat": T0, "chat_ack": T0, "operator": T0, "harness_request": T0,
    "board": TEAM, "board_plan": TEAM, "board_post": TEAM, "board_update": TEAM,
    # early tips: a tool that makes a repeated hand job cheaper
    "drill_sites": ["scale:drills:3", "habit:refused_builds:2"],
    "belt_route": ["habit:hand_belts:20", "scale:belts:40"],
    "pole_route": ["habit:hand_poles:8"],
    "pipe_route": ["research:oil-processing", "built:pipe-to-ground"],
    "build_path": ["habit:walked:2000", "habit:hand_belts:20"],
    "placements": ["habit:refused_builds:3", "scale:machines:10"],
    "conflicts": ["habit:refused_builds:3"],
    "deliver": ["habit:chest_moves:5"],
    "fuel_budget": ["habit:hand_feeds:20", "scale:machines:10"],
    "repair": ["event:attacked", "event:loss"],
    "wait_until": ["habit:sleeps:20", "scale:game_hours:1"],
    "sleep_check": ["habit:sleeps:20"],
    "queue_submit": ["habit:repeat_calls:5", "scale:game_hours:1"],
    "queue_status": ["with:queue_submit"], "queue_edit": ["with:queue_submit"], "queue_cancel": ["with:queue_submit"],
    "queue_pause": ["with:queue_submit"], "queue_resume": ["with:queue_submit"], "queue_repeat": ["with:queue_submit"],
    "plan_save": ["habit:repeat_calls:10"], "plan_run": ["with:plan_save"], "plans": ["with:plan_save"],
    "reminder_add": ["scale:game_hours:2"], "reminder_edit": ["with:reminder_add"], "reminder_ack": ["with:reminder_add"],
    "reminder_remove": ["with:reminder_add"], "reminder_snooze": ["with:reminder_add"], "reminders": ["with:reminder_add"],
    "order_set": ROBOTS + ["scale:machines:40"], "orders": ["with:order_set"], "order_remove": ["with:order_set"],
    "orders_pause": ["with:order_set"], "orders_resume": ["with:order_set"],
    # factory reads: grow with the factory
    "labs": ["built:lab"], "science": ["built:lab"],
    "power": ["built:steam-engine|solar-panel", "event:low_power"],
    "rates": ["scale:machines:10"], "supply": ["scale:machines:10", "event:starved"],
    "bottleneck": ["scale:machines:20", "event:starved"], "trace": ["scale:machines:20", "event:starved"],
    "shortages": ["scale:machines:20", "event:starved"], "ingredient_gap": ["event:starved", "scale:machines:20"],
    "dependency": ["scale:machines:20"], "stock": ["scale:machines:10", "habit:chest_moves:5"],
    "where_is": ["scale:machines:20"], "uptime": BIG_BASE, "ports": ["scale:inserters:20"],
    "belt_flow": ["scale:belts:100"], "belt_gaps": ["scale:belts:100"], "belt_upgrade": ["research:logistics-2"],
    "pipe_gaps": OIL, "flush": OIL, "heat_budget": ["research:nuclear-power", "research:heating-tower", "arrived:aquilo"],
    "game_alerts": ["scale:machines:20", "event:attacked"], "alerts_digest": ["scale:machines:40", "event:attacked"],
    "assembler_batch": ["scale:machines:10"], "configure": T0,
    # robots and logistics
    "networks": ROBOTS, "construction_robots": ROBOTS, "logistics_audit": ROBOTS, "reservations": ROBOTS,
    "robot_losses": ROBOTS, "requester_rate": LOGISTIC, "requests": LOGISTIC + ["research:space-platform"],
    "character_settings": ["research:logistic-robotics", "research:personal-roboport-equipment"],
    "place_ghosts": ROBOTS, "ghosts": ROBOTS, "remove_ghosts": ROBOTS, "construct": ROBOTS, "revive_ghost": ROBOTS,
    "cancel_deconstruction": ROBOTS, "upgrade": ROBOTS, "rebuild": ROBOTS + ["event:loss"], "outpost": ROBOTS,
    "restore": ["world:humans"],
    "copy": ROBOTS, "cut": ROBOTS, "paste": ROBOTS,
    "blueprint_save": ROBOTS, "blueprint_place": ["with:blueprint_save"], "blueprint_capture": ["with:blueprint_save"],
    "blueprint_list": ["with:blueprint_save"], "blueprint_status": ["with:blueprint_save"],
    "blueprint_rename": ["with:blueprint_save"], "blueprint_delete": ["with:blueprint_save"],
    "blueprint_retire": ["with:blueprint_save"], "blueprint_export": ["with:blueprint_save"],
    "blueprint_import": ["with:blueprint_save"],
    # circuits
    "circuit_set": CIRCUIT, "wire": CIRCUIT, "circuit_gate": CIRCUIT, "gates": CIRCUIT, "circuit_audit": CIRCUIT,
    "signal_watch": CIRCUIT,
    # rails
    "rail_route": RAIL, "train_stop": RAIL, "train": RAIL, "clear_cliffs": ["research:cliff-explosives"],
    # combat and vehicles
    "shoot": ["world:enemies"], "use_item": ["event:attacked", "event:died", "research:military-2"],
    "kite": ["event:attacked", "event:spitters"], "retreat_guard": ["event:attacked", "event:died"],
    "recover": ["event:died"], "danger": ENEMY, "damage_log": ["event:attacked", "event:loss"],
    "losses": ["event:loss"], "turrets": TURRET, "rearm": TURRET, "turret_feeds": ["scale:turrets:4"],
    "turret_tally": ["scale:turrets:4"], "defense": TURRET, "flamers": ["research:flamethrower"],
    "artillery": ["research:artillery"], "sight": ["research:radar", "built:radar"],
    "vehicle": VEHICLE + ["research:automobilism"], "spider_kite": ["research:spidertron"],
    "equip": ["research:modular-armor", "research:heavy-armor"], "equipment": ["research:modular-armor"],
    # team (a force with more than one agent): the basics at tick 0, the rest as the board grows
    "board_events": ["habit:board_items:20"], "board_review": ["habit:board_items:20"],
    "board_retire": ["habit:board_items:20"], "board_progress": ["habit:board_items:20"],
    "board_critical": ["habit:board_items:20"], "board_focus": ["habit:board_items:20"],
    "checks": ["scale:game_hours:2"], "lessons": ["scale:shifts:2", "event:died", "event:loss"],
    "lesson_add": ["with:lessons"], "lesson_edit": ["with:lessons"], "lesson_verify": ["with:lessons"],
    "lesson_review": ["with:lessons"], "ground_rules": ["scale:shifts:2"], "ground_rule_add": ["with:ground_rules"],
    "ground_rule_edit": ["with:ground_rules"], "ground_rule_retire": ["with:ground_rules"],
    "review": ["scale:game_hours:2"], "lookahead": ["scale:game_hours:2"], "boilers": ["built:boiler"],
    "mention_counts": TEAM,
    # stream and people
    "profile": STREAM, "profiles": STREAM, "confess": STREAM, "confessions": STREAM, "chronicle": STREAM,
    "vote": STREAM, "votes": STREAM, "players": ["world:humans"],
    # rockets, platforms, planets
    "silo": SILO, "launch": SILO, "launch_budget": SILO, "cargo": SILO, "load_silo": SILO, "silo_stage": SILO,
    "pods": SILO, "preflight": SILO, "min_payload": SILO,
    "platforms": PLATFORM, "platform": PLATFORM, "platform_create": PLATFORM, "platform_schedule": PLATFORM,
    "platform_rename": PLATFORM, "platform_delete": PLATFORM, "platform_endurance": PLATFORM,
    "platform_supply": PLATFORM, "platform_plan": PLATFORM, "platform_bom": PLATFORM,
    "platform_production": PLATFORM, "platform_digest": PLATFORM, "platform_tiles": PLATFORM,
    "platform_lanes": PLATFORM, "platform_gate": PLATFORM,
    "platform_defense": PLATFORM + ["event:asteroids"], "platform_rearm": ["event:asteroids", "scale:turrets:4"],
    "land": SECOND, "drop": SECOND, "drops": SECOND, "shipment": SECOND, "fleet": ["scale:platforms:2"],
    "freight_audit": ["event:freight"], "delivery_watch": ["event:freight"], "flight_watch": PLATFORM,
    "demolishers": ["arrived:vulcanus", "event:demolishers"],
    "agriculture": GLEBA, "eggs": ["arrived:gleba", "research:captive-biter-spawner", "event:pentapods"],
    # not agent-facing
    "attach": NEVER, "detach": NEVER, "advance": NEVER, "cameras": NEVER, "screenshot": NEVER, "dry_run": ["habit:refused:1"],
}
SCALES["platforms"] = "space platforms the force has"

# Arguments: by name across actions (an action's own entry in ARGS_OF wins). Arguments not named here unlock with
# their action ("with"). The describe meta-fields returns and examples are not arguments.
META_ARGS = {"returns", "examples"}
ARGS = {
    "quality": QUALITY, "quality_source": QUALITY,
    "surface": SECOND, "platform": SECOND,
    "avoid_enemies": ENEMY, "unsafe_goal": ENEMY, "avoid_nests": ENEMY, "stand_off": ENEMY,
    "stay_in_turret_coverage": TURRET, "max_uncovered": TURRET, "retreat": ["event:attacked", "event:died"],
    "combat": ENEMY,
    "spoiled_first": SPOIL, "min_spoil": SPOIL, "min_spoiled": SPOIL, "max_fresh": SPOIL, "fresh": SPOIL,
    "fresh_first": SPOIL, "min_fresh": SPOIL, "clear_spoilage": SPOIL, "spoil_priority": SPOIL,
    "dry_run": ["habit:refused:1"],
    "wake_on_messages": TEAM, "wake_on_board": TEAM, "wake_from": TEAM, "wake_local": TEAM,
    "wake_on_viewers": STREAM, "wake_on_orders": ["with:order_set"], "orders": ["with:order_set"],
    "circuit": CIRCUIT, "wires": CIRCUIT, "signals": CIRCUIT, "signal": CIRCUIT, "decider": CIRCUIT,
    "arithmetic": CIRCUIT, "selector": CIRCUIT, "speaker_alert": CIRCUIT,
    "network": ROBOTS, "personal_logistics": ["research:logistic-robotics"],
    "up_to_request": LOGISTIC, "auto_requests": PLATFORM, "item_requests": ROBOTS, "set_requests": LOGISTIC,
    "construction_requests": ROBOTS, "trash_unrequested": LOGISTIC, "from_buffers": LOGISTIC, "requests": LOGISTIC,
    "rail_layer": ["research:elevated-rail"], "elevated": ["research:elevated-rail"],
    "pods": SILO, "orbit": SILO, "send_to_orbit_automatically": SILO, "ride": PLATFORM,
    "mix_fluids": OIL, "cut_fluid": OIL, "fluids": OIL,
    "heating": ["research:heating-tower", "arrived:aquilo", "research:nuclear-power"],
    "modules": ["research:modules"], "check_inserters": ["scale:inserters:10", "habit:refused:1"],
    "vehicle": VEHICLE, "pair": ["research:spidertron"],
    "expected_revision": ["habit:board_items:20"], "supersedes": ["habit:board_items:20"],
    "blocked_by": ["habit:board_items:20"], "parent": ["habit:board_items:20"], "handoff": ["habit:board_items:20"],
    "lane": ["with:queue_submit"], "guards": ["with:queue_submit"], "pause_queue": ["with:queue_submit"],
    "resume_after_direct": ["with:queue_submit"],
    "filters": ["research:fast-inserter"], "filter_mode": ["research:fast-inserter"],
    "use_filters": ["research:fast-inserter"],
    "priority_targets": TURRET, "auto_targeting": TURRET, "ignore_unprioritised": TURRET,
}

# Argument groups of the largest actions: the simple form at the action's unlock, the rest later.
ARGS_OF = {
    "build": {"configure": ["scale:machines:10"], "requests": LOGISTIC, "circuit": CIRCUIT, "wires": CIRCUIT,
              "builds": ["habit:repeat_calls:5"], "skip_failed": ["habit:refused:1"], "clear_obstacles": T0,
              "materials": T0, "retry_when_clear": ROBOTS, "retry_ticks": ROBOTS, "retries": ROBOTS},
    "transfer": {"via": ["habit:chest_moves:5"], "steps": ["habit:chest_moves:5"], "keep": ["habit:chest_moves:5"],
                 "keep_max": ["habit:chest_moves:5"], "total": ["habit:chest_moves:5"],
                 "retry_when_clear": ROBOTS, "retry_ticks": ROBOTS, "retries": ROBOTS, "on_fail": ["habit:refused:1"],
                 "positions": ["habit:hand_feeds:10"], "area": ["habit:hand_feeds:10"], "types": ["habit:hand_feeds:10"]},
    "collect": {"follow": ["habit:repeat_calls:5"], "keep_taking": ["habit:repeat_calls:5"], "pods": SILO,
                "give": ["habit:chest_moves:5"], "take_back": ["habit:chest_moves:5"]},
    "move_to": {"mine_out": ["habit:refused:1"], "squeeze": ["habit:refused:1"], "unbox": ["habit:refused:1"],
                "via": ["habit:walked:2000"], "pathfind": ["habit:refused:1"]},
    "configure": {"recipe": T0, "position": T0, "positions": T0, "bar": ["habit:chest_moves:5"],
                  "storage_filter": ROBOTS, "input_priority": ["research:logistics"],
                  "output_priority": ["research:logistics"], "force": ["never"], "by": ["with:configure"]},
    "wait_until": {"tick": T0, "item": T0, "count": T0, "position": T0, "seconds": T0, "timeout": T0,
                   "conditions": ["habit:sleeps:40"], "loop": ["habit:sleeps:40"], "technology": T0,
                   "platform_built": PLATFORM, "platform_ready": PLATFORM, "location": PLATFORM,
                   "drop_id": SECOND, "last_drop": SECOND, "damage": ["event:attacked"]},
    "sleep": {"seconds": T0, "condition": T0, "reason": T0, "note": T0, "wake_on_urgent": ["event:attacked"],
              "peek": ["habit:sleeps:20"]},
    "inspect": {"memory": ["habit:repeat_calls:5"], "heating": ["research:heating-tower", "arrived:aquilo"]},
    "research": {"target_level": ["scale:game_hours:4"], "targets": ["scale:game_hours:4"]},
    "status": {"threats": ENEMY, "urgent_since": ["event:attacked"], "urgent_radius": ["event:attacked"]},
    "vehicle": {"remote": ["research:spidertron"], "pair": ["research:spidertron"], "route": ["research:spidertron"],
                "routes": ["research:spidertron"], "go_to": ["research:spidertron", "built:car|tank"]},
    "load_silo": {"launch_split": PLATFORM, "split_part": PLATFORM, "wait_platform": PLATFORM},
}

# Docs: whole topic files, and the brief's own sections.
TOPICS = {
    "moving-items": T0, "building": T0, "analysis": ["scale:machines:10"], "waits-queues": ["with:wait_until"],
    "circuits-settings": T0, "movement-combat": T0, "team": TEAM, "stream-people": STREAM,
    "space-age": SILO + PLATFORM,
}
# The brief's own files (the core every agent reads at the start of each context window, and the head of space-age),
# item by item: a top-level bullet or a paragraph; a file's default, then BRIEF_ITEMS by the item's text.
BRIEF = {
    "PLAYBOOK.md": T0, "team.md": TEAM, "coop.md": ["world:humans"], "compact.md": T0, "full-tools.md": T0,
    "harness-claude.md": T0, "spaceage.md": ["world:space_age"] + PLATFORM, "ref/index.md": T0,
}
BRIEF_ITEMS = [
    ("PLAYBOOK.md", r"leave a queue plan|queue plan check|pauses your running queue|queue submit --file", ["with:queue_submit"]),
    ("PLAYBOOK.md", r"urgent alert", ["event:enemy_seen", "event:low_power", "event:died", "event:second_surface"]),
    ("PLAYBOOK.md", r"^- More detail", ["never"]),
    ("team.md", r"Out of sight, reads add `fog`", ["event:loss", "research:radar"]),
    ("team.md", r"--aloud", ["world:stream"]),
    ("full-tools.md", r"Aethera and Peregrine", ["never"]),
]

# Doc entries by their lead (the text before the first ": " of a top-level item), first match wins, before the actions
# the entry names: an entry about a feature unlocks with the feature.
DOCS = [
    (r"^- Game rule, ghosts|^- Who placed it", ROBOTS),
    (r"^- Couriers", ["habit:chest_moves:5"]),
    (r"^- Rail and chain signals|^- Rolling stock", RAIL),
    (r"blueprint export", ["with:blueprint_save"]),
    (r"^- Dry runs", ["habit:refused:1"]),
    (r"^- Water and Gleba wetland", ["research:landfill", "arrived:gleba"]),
    (r"^- Nuclear", ["research:nuclear-power"]),
    (r"^- On Vulcanus|demolisher", ["arrived:vulcanus"]),
    (r"^- Logistics$", LOGISTIC),
    (r"^- Quality$", QUALITY),
    (r"^- Enemies", ["world:enemies"]),
    (r"`progress", ["scale:shifts:2"]),
    (r"What the production statistics count", ["scale:machines:10"]),
    (r"research_use", ["scale:shifts:2"]),
    (r"factory digest", ["scale:shifts:2"]),
    (r"seed loop|keeps a seed going|^- Gleba|^- Spoilage", GLEBA),
    (r"Frozen entities|heating tower", ["arrived:aquilo", "research:heating-tower"]),
    (r"belt carrying items destroyed|line cut|`line_cut`", ["event:attacked", "event:loss"]),
    (r"platform|Platform|Hub requests|hub's trash|Aboard", PLATFORM),
    (r"Supply left without a path", PLATFORM),
    (r"`fields|`scan \{|A scan lists", ["scale:machines:20"]),
    (r"plan list", ["with:plan_save"]),
    (r"queue_edit", ["with:queue_submit"]),
    (r"harness update keeps|dropped game connection", ["start"]),
]

# Alerts and tips (tools/disclosure/alerts.json, each kind with its source). "self": the alert stays off until its own
# trigger first fires, and that first firing carries the unlock line (Factorio's tips: an exhausted-patch alert appears
# with the first exhausted patch). An alert tied to a tool comes with the tool; machinery of every reply is start.
ALERTS = [
    (r"^(clock-|refusal-|reference-hint|flag-refusal|game-unreachable|outcome-unknown|wait-timeout|warning-line|"
     r"paged-more|corrected-|retried-note|outage-ended|rollback-redo|replaced-action|still-running|sleep-|wake-elapsed|"
     r"wake-condition|wake-line|require-met|harness-updated|hook-|supervise-|agy-loop|rest-ended|provider-stop-resume|"
     r"resume-shift|repeats-trim|operator-lines|tell-operator|idle-nudge|wake-respawned|wake-damaged|wake-died|"
     r"team-research-done|shift-block|wait-slow-game|team-reminder-operator-note)", ["start"]),
    (r"^(wake-queue|queue-|alert-queue-paused|moved-by)", ["with:queue_submit"]),
    (r"^lessons-matched", ["with:lessons"]), (r"^ground-rule", ["with:ground_rules"]),
    (r"^standing-orders-line", ["with:order_set"]), (r"^lookahead-block", ["with:lookahead"]),
    (r"^self-review-due", ["with:review"]), (r"^board-focus", ["with:board_focus"]),
    (r"^(tell-reminder|tell-owed-reminder)", ["with:reminder_add"]), (r"^alert-mixed-watch", ["with:signal_watch"]),
    (r"^(alert-delivery-watch|alert-shipment|tell-supply-left)", ["with:delivery_watch"]),
    (r"^alert-flight-watch", ["with:flight_watch"]), (r"^alert-drops", ["with:drop"]),
    (r"^(alert-spidertron|wake-spidertron|team-spidertron)", ["with:spider_kite"]),
    (r"^tell-artillery-flare", ["with:artillery"]), (r"^wake-starved", ["with:supply"]),
    (r"^(wake-alert-kinds|wake-watch-flags|wake-waited-now|wake-open-line)", ["with:wait_until"]),
    (r"^team-out-of-sight", ["research:radar", "built:radar"]),
    (r"^(team-reminder-profile|team-reminder-stream|poll-open|viewer-chat|operator-viewer|mention-viewer)",
     ["world:stream"]),
    (r"^run-target", ["start"]),
]
ALERT_GATES = {"biters": ["world:enemies"], "team": ["world:team"], "stream": ["world:stream"],
               "space": ["world:space_age"], "platforms": ["world:space_age"]}
