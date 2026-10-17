## Reference topics

Each topic, when to read it, and the commands it documents:

- `moving-items`, when you move items by hand or a move comes back `short` or out of reach: `transfer` (give, take,
  couriers), `collect` (machine outputs), `feed` (ingredients, packs, fuel), `refuel` (burners), `pickup` (belts,
  ground), `mine` (by hand), `rotate`, `repair`, `inventory`, `craft`, `cancel_craft`.
- `building`, when you place anything past a few hand builds: `build` (batches, settings, fast replace), `place_ghosts`,
  `construct` (ghosts by hand), `deconstruct`, `paste`, `placements` (where it fits), `nearest_water`, `conflicts`, `build_path`,
  `grid` (tiles), `pole_route`, `belt_route`, `rail_route`, `train_stop`, `train` (stops, schedules), `clear_cliffs`, `heat_budget`,
  `outpost` (one tour), `blueprint_save`, `blueprint_capture`, `blueprint_list`, `blueprint_place`, `blueprint_rename`,
  `blueprint_delete` (the team library); landfill, tiles, nuclear.
- `circuits-settings`, when you wire, set up logistics or configure a machine: `circuit_set` (conditions, combinators),
  `wire`, `configure` (recipe, modules, filters, priorities, quality), `requests` (logistic and personal).
- `movement-combat`, when a walk fails, enemies or turrets are involved, you drive or you died: `move_to` (reach, via,
  enemy margins, pockets), `retreat_guard`, `kite`, `recover` (your corpses), `turrets`, `rearm`, `artillery`,
  `shoot`, `use_item` (grenades, capsules), `equip` (gun and ammo slots), `vehicle` (enter, drive, remote),
  `equipment` (grids).
- `analysis`, when something is starved or slow or you need numbers to plan: `progress` (the run by shift), `research`
  and `research done`, `science` (packs), `supply` (one item), `bottleneck`, `trace`, `labs`, `inspect` (areas,
  remote view), `ports`, `power` (networks, fragile poles), `fuel_budget`, `game_alerts`, `belt_gaps`, `pipe_gaps`,
  `danger`, `drill_sites`, `ores`, `stock` (where an item is), `reservations` (a network's robot reservations), `construction_robots`, `shortages` (the factory's
  shortages in one read), `damage_log` (what hit our entities); the factory digest.
- `waits-queues`, for waits past the sleep and wait basics, or work that repeats: `wait_until` and `sleep --until` conditions,
  `wait_ticks`, `sleep_check`, `queue_submit` (modes), `queue_status`, `queue_edit`, `queue_cancel`, `queue_repeat`, `plan save`, `plan run`,
  `plan list`, `stop`, `order_set`, `orders`, `order_remove`, `orders_pause`, `orders_resume` (standing orders),
  `reminder_add`, `reminder_ack`, `reminders`; urgent wakes, slow game, harness updates.
- `team`, when you edit board items or read a `team:` or `team: shift` block or an `OPERATOR:` line: claims, `board projects`, `board_review`, `board_retire`, `lessons`, `lesson_add`, `lesson_edit`, `lesson_verify`, `review`,
  `lookahead`, `networks`, `boilers`, `tells`.
- `stream-people`, in your first minute (your stream profile) and when you talk to viewers or a human player joins:
  `profile`, `profiles`, `confess`, `chronicle`, `operator`, `poll` (the site's polls), `players`, `vote`, `votes`,
  `restore`.
- `space-age`, for rockets, platforms and other planets: `platforms` and `platform NAME`, `platform_create`,
  `platform_schedule`, `platform_endurance`, `platform_supply`, `platform_plan`, `launch`, `silo`, `cargo`, `load_silo`, `preflight`, `land`, `drop`,
  `freight_audit`, `where_is`, `agriculture`, the remote queue lane; spoilage, Gleba.
