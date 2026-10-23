#!/usr/bin/env python3
"""Dump Factorio prototypes over RCON into the analyst's knowledge base (read-only Lua, nothing in the game changes).
Space Age: asteroids.json lists each route's and each orbit's asteroid_spawn_definitions as the game gives them
(asteroid, type, quality, probability, speed, spawn_points) and the asteroid entities (max_health, resistances).
Fluid energy (Sol, d15 19:05): fluid-burning and fluid-making entities (fusion reactor and generator, generators such as
steam engines and turbines, boilers and heat exchangers, reactors) get a "fluid" object in entities.json: fluid usage a
second, fluid boxes (production type, filter, temperatures, volume, connections), neighbour bonus, effectivity,
maximum and target temperature (`--only fluid_energy` merges it into an existing entities.json).
Quality and modules (d22 batch102 BL1, Sol #1919: "Local quality calculator cannot use export alone"): a recipe's products
carry extra_count_fraction (the EM plant recycler's 37 + 0.5 holmium) and ignored_by_productivity, and the recipe
effects_not_allowed (and maximum_productivity when it is not 3); a module item carries module_effects, module_category,
tier and effects_by_quality (each visible quality: a bonus times its default_multiplier, cut to 0.01, a penalty
unchanged; checked on a copy against entity.effects, 60 of 60; a machine's totals stop at consumption -0.8 and quality
0); qualities.json each quality's level, next, next_probability, default_multiplier and the beacon power, drill drain
and science drain multipliers; the `effects` page merges into entities.json each machine's base_effect (the EM plant's
productivity 0.5), what it uses, allowed effects and module categories, crafting or researching speed by quality, and a
beacon's distribution effectivity, its bonus a quality level and profile. `--password-file` reads a private copy's
password.

  python3 tools/analyst/dump_prototypes.py                      # world live -> tools/analyst/kb/base-2.0.77/
  python3 tools/analyst/dump_prototypes.py --world sa --port 27031 --out tools/analyst/kb/space-age-2.0.77
  python3 tools/analyst/dump_prototypes.py --world n --only asteroids --out tools/analyst/kb/space-age-2.0.77

Each category is read in pages of names (sorted, so pages are stable) to keep RCON replies small. Every property read
is wrapped in pcall, so a field missing in this game version is left out instead of failing the dump. Each page goes
as one line: the Lua holds no "--" comments (one commented out the rest of the entities page, 15:25), and no command is
longer than the longest that ran live (MAX_COMMAND; tools/analyst/test_dump_prototypes.py checks both).
"""
import argparse, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.dont_write_bytecode = True
from pog import Rcon, PORTS  # noqa: E402

COMMON = r"""
local function g(f) local ok, v = pcall(f) if ok then return v end end
local function names(t) local r = {} for k in pairs(t) do r[#r+1] = k end table.sort(r) return r end
local function products(list)
  local r = {}
  for _, p in ipairs(list or {}) do
    r[#r+1] = {type=p.type, name=p.name, amount=p.amount, amount_min=p.amount_min, amount_max=p.amount_max,
      probability=(p.probability ~= 1) and p.probability or nil, temperature=p.temperature}
  end
  return r
end
local function emissions(es, e)
  if not es then return nil end
  local per_j = g(function() return es.emissions_per_joule end)
  local w = g(function() return e.get_max_energy_usage() * 60 end) or g(function() return e.energy_usage * 60 end)
  if not per_j or not w then return nil end
  local r = {}
  for k, v in pairs(per_j) do if v ~= 0 then r[k] = v * w * 60 end end
  return next(r) and r or nil
end
"""

LUA = {
    "recipes": r"""
local src = prototypes.recipe
local out = {}
local list = names(src)
local function made(list)
  local r = products(list)
  for i, p in ipairs(list or {}) do
    r[i].extra_count_fraction = p.extra_count_fraction
    r[i].ignored_by_productivity = (p.ignored_by_productivity or 0) > 0 and p.ignored_by_productivity or nil
  end
  return r
end
for i = START, math.min(#list, START + COUNT - 1) do
  local r = src[list[i]]
  out[#out+1] = {name=r.name, category=r.category, energy=r.energy, enabled=r.enabled, hidden=r.hidden,
    ingredients=products(r.ingredients), products=made(r.products), subgroup=g(function() return r.subgroup.name end),
    maximum_productivity=g(function() return r.maximum_productivity ~= 3 and r.maximum_productivity or nil end),
    effects_not_allowed=g(function() local no = {} for k, v in pairs(r.allowed_effects or {}) do if not v then no[#no+1] = k end end table.sort(no) return #no > 0 and no or nil end),
    main_product=g(function() return r.main_product and r.main_product.name end),
    allow_productivity=g(function() return r.allowed_effects and r.allowed_effects.productivity end),
    surface_conditions=g(function() return r.surface_conditions end)}
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
    "technologies": r"""
local src = prototypes.technology
local out = {}
local list = names(src)
for i = START, math.min(#list, START + COUNT - 1) do
  local t = src[list[i]]
  local pre, eff, ing = {}, {}, {}
  for n in pairs(t.prerequisites or {}) do pre[#pre+1] = n end
  table.sort(pre)
  for _, e in ipairs(t.effects or {}) do
    eff[#eff+1] = {type=e.type, recipe=e.recipe, modifier=e.modifier, ammo_category=e.ammo_category,
      turret_id=e.turret_id, item=e.item, quality=e.quality, space_location=e.space_location}
  end
  for _, x in ipairs(t.research_unit_ingredients or {}) do ing[#ing+1] = {name=x.name, amount=x.amount} end
  out[#out+1] = {name=t.name, prerequisites=pre, effects=eff, unit_ingredients=ing,
    unit_count=g(function() return t.research_unit_count end),
    unit_count_formula=g(function() return t.research_unit_count_formula end),
    unit_time=g(function() return t.research_unit_energy / 60 end),
    trigger=g(function() return t.research_trigger end), max_level=g(function() return t.max_level end),
    level=g(function() return t.level end), upgrade=g(function() return t.upgrade end), hidden=t.hidden,
    essential=g(function() return t.essential end), enabled=t.enabled, order=t.order}
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
    "items": r"""
local src = prototypes.item
local out = {}
local list = names(src)
for i = START, math.min(#list, START + COUNT - 1) do
  local it = src[list[i]]
  out[#out+1] = {name=it.name, type=it.type, stack_size=it.stack_size, subgroup=g(function() return it.subgroup.name end),
    fuel_value=(it.fuel_value or 0) > 0 and it.fuel_value or nil, fuel_category=g(function() return it.fuel_category end),
    place_result=g(function() return it.place_result and it.place_result.name end),
    rocket_launch_products=g(function() return products(it.rocket_launch_products) end),
    spoil_ticks=g(function() return (it.get_spoil_ticks and it.get_spoil_ticks()) or nil end),
    spoil_result=g(function() return it.spoil_result and it.spoil_result.name end),
    weight=g(function() return it.weight end), hidden=it.hidden, order=it.order,
    module_effects=it.type == "module" and g(function() return it.module_effects end) or nil,
    module_category=it.type == "module" and g(function() return it.category end) or nil, tier=it.type == "module" and g(function() return it.tier end) or nil}
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
    "fluids": r"""
local src = prototypes.fluid
local out = {}
local list = names(src)
for i = START, math.min(#list, START + COUNT - 1) do
  local f = src[list[i]]
  out[#out+1] = {name=f.name, default_temperature=f.default_temperature, max_temperature=f.max_temperature,
    heat_capacity=f.heat_capacity, fuel_value=(f.fuel_value or 0) > 0 and f.fuel_value or nil, hidden=f.hidden}
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
    "entities": r"""
local types = {"assembling-machine","furnace","mining-drill","lab","boiler","generator","solar-panel","accumulator",
  "reactor","heat-exchanger","burner-generator","inserter","transport-belt","underground-belt","splitter",
  "offshore-pump","pump","rocket-silo","electric-pole","roboport","construction-robot","logistic-robot",
  "ammo-turret","electric-turret","fluid-turret","artillery-turret","wall","gate","radar","beacon","unit",
  "unit-spawner","turret","resource","car","spider-vehicle","locomotive","cargo-wagon","fluid-wagon",
  "storage-tank","agricultural-tower","fusion-reactor","fusion-generator","asteroid-collector","thruster",
  "space-platform-hub","cargo-landing-pad","lightning-attractor","segmented-unit","spider-unit","capture-robot",
  "tree","simple-entity","container","logistic-container","pipe","pipe-to-ground"}
local all = prototypes.get_entity_filtered({{filter="type", type=types}})
local out = {}
local list = names(all)
for i = START, math.min(#list, START + COUNT - 1) do
  local e = all[list[i]]
  local t = e.type
  local r = {name=e.name, type=t, max_health=g(function() return e.get_max_health() end) or g(function() return e.max_health end),
    hidden=g(function() return e.hidden end)}
  if t ~= "tree" and t ~= "simple-entity" and t ~= "resource" then
    r.crafting_speed = g(function() return e.get_crafting_speed() end) or g(function() return e.crafting_speed end)
    r.crafting_categories = g(function() return e.crafting_categories end)
    r.mining_speed = g(function() return e.mining_speed end)
    r.resource_categories = g(function() return e.resource_categories end)
    r.mining_area = g(function() return e.mining_drill_radius and e.mining_drill_radius * 2 end)
    r.researching_speed = g(function() return e.get_researching_speed and e.get_researching_speed() or e.researching_speed end)
    r.energy_usage_kw = g(function() return e.energy_usage and e.energy_usage * 60 / 1000 end)
    r.max_energy_usage_kw = g(function() return e.get_max_energy_usage() * 60 / 1000 end)
    r.max_energy_production_kw = g(function() return e.get_max_energy_production() * 60 / 1000 end)
    r.module_slots = g(function() return e.module_inventory_size end)
    r.belt_speed_items_per_s = g(function() return e.belt_speed and e.belt_speed * 60 * 8 end)
    r.inserter_rotation_speed = g(function() return e.get_inserter_rotation_speed and e.get_inserter_rotation_speed() or e.inserter_rotation_speed end)
    r.pumping_speed_per_s = g(function() return e.get_pumping_speed and e.get_pumping_speed() * 60 or (e.pumping_speed and e.pumping_speed * 60) end)
    r.burner = g(function() return e.burner_prototype and {effectivity=e.burner_prototype.effectivity, categories=e.burner_prototype.fuel_categories} end)
    r.electric = g(function() return e.electric_energy_source_prototype ~= nil end)
    r.emissions_per_minute = emissions(e.electric_energy_source_prototype, e) or emissions(e.burner_prototype, e)
    r.supply_area = g(function() return e.get_supply_area_distance() end)
    r.max_wire_distance = (t == "electric-pole") and g(function() return e.get_max_wire_distance() end) or nil
    r.target_temperature = g(function() return e.target_temperature end)
    r.max_fluid_usage = g(function() return e.fluid_usage_per_tick and e.fluid_usage_per_tick * 60 end)
    r.attack_range = g(function() return e.attack_parameters and e.attack_parameters.range end)
    r.attack_cooldown = g(function() return e.attack_parameters and e.attack_parameters.cooldown end)
    r.movement_speed = (t == "unit" or t == "car" or t == "locomotive") and g(function() return e.speed end) or nil
    r.absorptions_to_join_attack = g(function() return next(e.absorptions_to_join_attack) and e.absorptions_to_join_attack or nil end)
    r.attack_damage = g(function()
      local d = e.attack_parameters.ammo_type.action[1].action_delivery[1].target_effects
      for _, x in ipairs(d) do if x.type == "damage" then return x.damage end end end)
    r.max_pursue_distance = g(function() return e.max_pursue_distance end)
    r.spawner_units = g(function()
      if not e.result_units then return nil end
      local u = {}
      for _, x in ipairs(e.result_units) do
        local pts = {}
        for _, sp in ipairs(x.spawn_points or {}) do pts[#pts+1] = {evolution=sp.evolution_factor, weight=sp.weight or sp.spawn_weight} end
        u[#u+1] = {unit=x.unit, points=pts}
      end
      return u end)
    r.max_count_of_owned_units = g(function() return e.max_count_of_owned_units end)
    r.max_polluted = g(function() return e.max_pollution_to_join_attack end)
    r.robot_speed = (t == "construction-robot" or t == "logistic-robot") and g(function() return e.speed end) or nil
    r.logistic_radius = g(function() return e.logistic_radius end)
    r.construction_radius = g(function() return e.construction_radius end)
    r.rocket_parts_required = g(function() return e.rocket_parts_required end)
    r.radar_range_chunks = g(function() return e.max_distance_of_nearby_sector_revealed end)
    r.radar_scan_chunks = g(function() return e.max_distance_of_sector_revealed end)
    r.inventory_size = g(function() return e.get_inventory_size(1) end)
  end
  if t == "resource" then
    r.mining_time = g(function() return e.mineable_properties.mining_time end)
    r.products = g(function() return products(e.mineable_properties.products) end)
    r.required_fluid = g(function() return e.mineable_properties.required_fluid end)
    r.fluid_amount = g(function() return e.mineable_properties.fluid_amount end)
    r.infinite = g(function() return e.infinite_resource end)
    r.category = g(function() return e.resource_category end)
  end
  if t == "tree" or t == "simple-entity" then
    r.mining_time = g(function() return e.mineable_properties.mining_time end)
    r.products = g(function() return products(e.mineable_properties.products) end)
    r.emissions_per_second = g(function() return e.emissions_per_second end)
  end
  local clean = {}
  for k, v in pairs(r) do if v ~= nil and v ~= false and v ~= 0 then clean[k] = v end end
  clean.name, clean.type = e.name, t
  out[#out+1] = clean
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
    "locations": r"""
local locs, conns = {}, {}
local ok_l, L = pcall(function() return prototypes.space_location end)
if ok_l and L then
  for name, l in pairs(L) do
    locs[#locs+1] = {name=name, type=g(function() return l.type end), distance=g(function() return l.distance end),
      orientation=g(function() return l.orientation end), gravity_pull=g(function() return l.gravity_pull end),
      solar_power_in_space=g(function() return l.solar_power_in_space end), magnitude=g(function() return l.magnitude end),
      surface_properties=g(function() return l.surface_properties end), order=g(function() return l.order end)}
  end
end
local ok_c, C = pcall(function() return prototypes.space_connection end)
if ok_c and C then
  for name, c in pairs(C) do
    conns[#conns+1] = {name=name, from=g(function() return c.from.name end), to=g(function() return c.to.name end),
      length=g(function() return c.length end)}
  end
end
local props = {}
local ok_p, SP = pcall(function() return prototypes.surface_property end)
if ok_p and SP then for name, p in pairs(SP) do props[#props+1] = {name=name, default=g(function() return p.default_value end)} end end
local quals = {}
local ok_q, Q = pcall(function() return prototypes.quality end)
if ok_q and Q then for name, q in pairs(Q) do quals[#quals+1] = {name=name, level=q.level, hidden=q.hidden} end end
rcon.print(helpers.table_to_json({total=1, items={{locations=locs, connections=conns, surface_properties=props, qualities=quals}}}))
""",
    "asteroids": r"""
local rows = {}
local ok_c, C = pcall(function() return prototypes.space_connection end)
if ok_c and C then for _, n in ipairs(names(C)) do rows[#rows+1] = {"route", n} end end
local ok_l, L = pcall(function() return prototypes.space_location end)
if ok_l and L then for _, n in ipairs(names(L)) do rows[#rows+1] = {"orbit", n} end end
local A = g(function() return prototypes.get_entity_filtered({{filter="type", type="asteroid"}}) end) or {}
for _, n in ipairs(names(A)) do rows[#rows+1] = {"asteroid", n} end
local function nm(v) if type(v) == "string" then return v end return g(function() return v.name end) end
local function defs(list)
  local out = {}
  for _, d in ipairs(list or {}) do
    local pts = {}
    for _, s in ipairs(g(function() return d.spawn_points end) or {}) do
      pts[#pts+1] = {distance=g(function() return s.distance end), probability=g(function() return s.probability end),
        speed=g(function() return s.speed end)}
    end
    out[#out+1] = {asteroid=nm(g(function() return d.asteroid end)), type=g(function() return d.type end),
      quality=nm(g(function() return d.quality end)), probability=g(function() return d.probability end),
      speed=g(function() return d.speed end), spawn_points=#pts > 0 and pts or nil}
  end
  return out
end
local out = {}
for i = START, math.min(#rows, START + COUNT - 1) do
  local kind, n = rows[i][1], rows[i][2]
  if kind == "route" then
    local c = C[n]
    out[#out+1] = {kind=kind, name=n, from=g(function() return c.from.name end), to=g(function() return c.to.name end),
      length=g(function() return c.length end), asteroids=defs(g(function() return c.asteroid_spawn_definitions end))}
  elseif kind == "orbit" then
    local l = L[n]
    out[#out+1] = {kind=kind, name=n, asteroids=defs(g(function() return l.asteroid_spawn_definitions end))}
  else
    local e = A[n]
    local res = {}
    for t, r in pairs(g(function() return e.resistances end) or {}) do res[#res+1] = {type=t, decrease=r.decrease, percent=r.percent} end
    out[#out+1] = {kind=kind, name=n, max_health=g(function() return e.get_max_health() end) or g(function() return e.max_health end),
      resistances=res}
  end
end
rcon.print(helpers.table_to_json({total=#rows, items=out}))
""",
    "settings": r"""
local ms = game.map_settings
local function copy(t, keys) local r = {} for _, k in ipairs(keys) do r[k] = g(function() return t[k] end) end return r end
local P = {"enabled","diffusion_ratio","min_to_diffuse","ageing","expected_max_per_chunk","min_to_show_per_chunk","min_pollution_to_damage_trees","pollution_with_max_forest_damage","pollution_per_tree_damage","pollution_restored_per_tree_damage","max_pollution_to_restore_trees","enemy_attack_pollution_consumption_modifier"}
local EV = {"enabled","time_factor","destroy_factor","pollution_factor"}
local EX = {"enabled","max_expansion_distance","settler_group_min_size","settler_group_max_size","min_expansion_cooldown","max_expansion_cooldown"}
local UG = {"min_group_gathering_time","max_group_gathering_time","max_wait_time_for_late_members","min_group_radius","max_group_radius"}
local surfaces = {}
for _, s in pairs(game.surfaces) do surfaces[#surfaces+1] = s.name end
local diff = g(function() return {technology_price_multiplier=game.difficulty_settings.technology_price_multiplier,
  spoil_time_modifier=game.difficulty_settings.spoil_time_modifier} end)
local mods = {}
for n, v in pairs(script.active_mods) do mods[n] = v end
rcon.print(helpers.table_to_json({items={{
  mods=mods, pollution=copy(ms.pollution, P), enemy_evolution=copy(ms.enemy_evolution, EV),
  enemy_expansion=copy(ms.enemy_expansion, EX), unit_group=copy(ms.unit_group, UG), difficulty=diff, surfaces=surfaces,
  peaceful=g(function() return game.surfaces.nauvis.peaceful_mode end),
  autoplace=g(function() return game.surfaces.nauvis.map_gen_settings.autoplace_controls end),
  starting_area=g(function() return game.surfaces.nauvis.map_gen_settings.starting_area end)}}, total=1}))
""",
    # Fluid rates of fluid-burning and fluid-making entities (Sol, d15 19:05: fusion planning read 10 MW and 50 MW and
    # no fluid rate): each one's fluid usage a second, its fluid boxes (production type, filter, temperatures, volume),
    # the reactor's neighbour bonus, the generator's effectivity and maximum temperature, a fluid energy source (2.0.77:
    # the fusion pair's rate is LuaEntityPrototype.get_fluid_usage_per_tick(), 4/s and 2/s; max_fluid_usage is not read). Merged
    # into entities.json by name (the entities page is near MAX_COMMAND); fields the game lacks are left out.
    "qualities": r"""
local src = prototypes.quality
local out = {}
local list = names(src)
for i = START, math.min(#list, START + COUNT - 1) do
  local q = src[list[i]]
  out[#out+1] = {name=q.name, level=q.level, hidden=q.hidden, default_multiplier=g(function() return q.default_multiplier end),
    next=g(function() return q.next and q.next.name end), next_probability=g(function() return q.next_probability end),
    beacon_power_usage_multiplier=g(function() return q.beacon_power_usage_multiplier end),
    mining_drill_resource_drain_multiplier=g(function() return q.mining_drill_resource_drain_multiplier end),
    science_pack_drain_multiplier=g(function() return q.science_pack_drain_multiplier end)}
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
    "effects": r"""
local all = prototypes.get_entity_filtered({{filter="type", type={"assembling-machine","furnace","rocket-silo","mining-drill","lab","beacon"}}})
local qs = {}
for n, q in pairs(prototypes.quality) do if not q.hidden then qs[#qs+1] = n end end
table.sort(qs)
local out = {}
local list = names(all)
for i = START, math.min(#list, START + COUNT - 1) do
  local e = all[list[i]]
  local r = {name=e.name, type=e.type}
  local er = g(function() return e.effect_receiver end)
  if er then
    r.base_effect = next(er.base_effect or {}) and er.base_effect or nil
    r.uses_module_effects, r.uses_beacon_effects, r.uses_surface_effects = er.uses_module_effects, er.uses_beacon_effects, er.uses_surface_effects
  end
  r.allowed_effects = g(function() return e.allowed_effects end)
  r.allowed_module_categories = g(function() return e.allowed_module_categories end)
  local cs, rs = {}, {}
  for _, q in ipairs(qs) do
    cs[q] = g(function() return e.get_crafting_speed(q) end)
    rs[q] = g(function() return e.get_researching_speed(q) end)
  end
  r.crafting_speed_by_quality = next(cs) and cs or nil
  r.researching_speed_by_quality = next(rs) and rs or nil
  if e.type == "beacon" then
    r.distribution_effectivity = g(function() return e.distribution_effectivity end)
    r.distribution_effectivity_bonus_per_quality_level = g(function() return e.distribution_effectivity_bonus_per_quality_level end)
    r.profile = g(function() local p = {} for k = 1, math.min(#e.profile, 16) do p[k] = e.profile[k] end return p end)
  end
  out[#out+1] = r
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
    "fluid_energy": r"""
local want = {["fusion-reactor"]=true, ["fusion-generator"]=true, generator=true, boiler=true, reactor=true, ["burner-generator"]=true}
local all, list = prototypes.entity, {}
for name, e in pairs(all) do if want[e.type] or g(function() return e.fluid_energy_source_prototype ~= nil end) then list[#list+1] = name end end
table.sort(list)
local out = {}
for i = START, math.min(#list, START + COUNT - 1) do
  local e = all[list[i]]
  local r = {name=e.name, type=e.type}
  r.max_fluid_usage_per_s = g(function() return e.get_fluid_usage_per_tick() * 60 end) or g(function() return e.fluid_usage_per_tick * 60 end)
  r.two_direction_only = g(function() return e.two_direction_only end)
  r.effectivity = g(function() return e.effectivity end)
  r.neighbour_bonus = g(function() return e.neighbour_bonus end)
  r.maximum_temperature = g(function() return e.maximum_temperature end)
  r.target_temperature = g(function() return e.target_temperature end)
  r.burns_fluid = g(function() return e.burns_fluid end)
  r.scale_fluid_usage = g(function() return e.scale_fluid_usage end)
  r.perceived_performance = g(function() return e.perceived_performance end)
  r.max_power_output_kw = g(function() return e.max_power_output * 60 / 1000 end)
  r.fluid_energy_source = g(function()
    local f = e.fluid_energy_source_prototype
    if not f then return nil end
    return {effectivity=g(function() return f.effectivity end), burns_fluid=g(function() return f.burns_fluid end),
      scale_fluid_usage=g(function() return f.scale_fluid_usage end), fluid_usage_per_s=g(function() return f.fluid_usage_per_tick * 60 end),
      maximum_temperature=g(function() return f.maximum_temperature end)} end)
  local boxes = {}
  for _, b in ipairs(g(function() return e.fluidbox_prototypes end) or {}) do
    boxes[#boxes+1] = {production_type=g(function() return b.production_type end), filter=g(function() return b.filter.name end),
      minimum_temperature=g(function() return b.minimum_temperature end), maximum_temperature=g(function() return b.maximum_temperature end),
      volume=g(function() return b.volume end), connections=g(function() return #b.pipe_connections end)}
  end
  if #boxes > 0 then r.fluid_boxes = boxes end
  out[#out+1] = r
end
rcon.print(helpers.table_to_json({total=#list, items=out}))
""",
}

PAGE = {"recipes": 60, "technologies": 40, "items": 80, "fluids": 80, "entities": 40, "locations": 1, "settings": 1,
        "asteroids": 3, "fluid_energy": 10, "qualities": 20, "effects": 20}
SINGLE = ("settings", "locations")
# The longest command that ran live (the entities page, 2026-10-13): nothing longer is sent.
MAX_COMMAND = 6800


def command(cat, start):
    """One page's RCON command: the Lua on one line (so it may hold no "--" comment)."""
    body = COMMON + LUA[cat].replace("START", str(start)).replace("COUNT", str(PAGE[cat]))
    cmd = "/silent-command " + " ".join(line.strip() for line in body.splitlines() if line.strip())
    if "--" in cmd:
        raise SystemExit(f"{cat}: the Lua holds '--', which would comment out the rest of the one-line command")
    if len(cmd.encode()) > MAX_COMMAND:
        raise SystemExit(f"{cat}: command is {len(cmd.encode())} bytes, over the {MAX_COMMAND} that ran live")
    return cmd


def dump(rc, cat):
    out, start, total = [], 1, None
    while total is None or start <= total:
        text = rc.command(command(cat, start))
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            raise SystemExit(f"{cat} page {start}: not JSON: {text[:400]}")
        total = data["total"]
        out += data["items"]
        start += PAGE[cat]
    return out


def tidy(v):
    """Floats to 4 decimals (2.0.77 gives a module's 0.8 as 0.80000001192092896); tables as they are."""
    if isinstance(v, float) and abs(v) < 1e12:
        return round(v, 4)
    if isinstance(v, dict):
        return {k: tidy(x) for k, x in v.items()}
    if isinstance(v, list):
        return [tidy(x) for x in v]
    return v


def merge_effects(out_dir, rows):
    """(d22 batch102 BL1, Sol #1919: "module item records omit effects and machine built-in productivity") effects rows
    go into entities.json by name, as each machine's "effects" object: base_effect (the machine's own, the EM plant's
    productivity 0.5), what it uses (modules, beacons, the surface), allowed_effects, allowed_module_categories, its
    crafting or researching speed by quality, and a beacon's distribution effectivity, its bonus a quality level and its
    profile. Returns the line printed."""
    path = os.path.join(out_dir, "entities.json")
    with open(path) as f:
        entities = json.load(f)
    by = {r["name"]: {k: tidy(v) for k, v in r.items() if k not in ("name", "type") and v not in (None, [], {})} for r in rows}
    merged = 0
    for e in entities:
        fx = by.get(e["name"])
        if fx:
            e["effects"] = fx
            merged += 1
        else:
            e.pop("effects", None)
    with open(path, "w") as f:
        json.dump(entities, f, indent=0, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    return f"effects: {len(rows)} read, {merged} merged into {os.path.relpath(path)}"


# A module's effect at a quality, as the game applies it (checked on a copy of world n's save, d22 15:08, with
# entity.effects of an assembling-machine-3 holding one module): a bonus (speed, productivity or quality above 0,
# consumption or pollution below 0) times the quality's default_multiplier, cut to 0.01 (a legendary quality module 3:
# 0.25 x 2.5 = 0.625, read 0.62); a penalty unchanged.
BONUS = {"speed": 1, "productivity": 1, "quality": 1, "consumption": -1, "pollution": -1}


def module_effect(key, value, multiplier):
    if BONUS.get(key, 0) * value <= 0:
        return round(value, 4)
    v = value * multiplier
    cut = math.floor(abs(v) * 100 + 1e-6) / 100
    return round(cut if v > 0 else -cut, 4)


def add_module_qualities(out_dir):
    """Each module in items.json gets effects_by_quality {quality: {effect: value}} from its module_effects and
    qualities.json's default_multiplier (the visible qualities). Returns the line printed, or None without both files."""
    ip, qp = os.path.join(out_dir, "items.json"), os.path.join(out_dir, "qualities.json")
    if not (os.path.exists(ip) and os.path.exists(qp)):
        return None
    with open(ip) as f:
        items = json.load(f)
    with open(qp) as f:
        quals = [q for q in json.load(f) if not q.get("hidden") and isinstance(q.get("default_multiplier"), (int, float))]
    quals.sort(key=lambda q: q.get("level") or 0)
    n = 0
    for it in items:
        fx = it.get("module_effects")
        if not isinstance(fx, dict) or not fx:
            it.pop("effects_by_quality", None)
            continue
        it["module_effects"] = tidy(fx)
        it["effects_by_quality"] = {q["name"]: {k: module_effect(k, v, q["default_multiplier"]) for k, v in fx.items()} for q in quals}
        n += 1
    with open(ip, "w") as f:
        json.dump(items, f, indent=0, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    return f"modules: {n} with effects_by_quality ({', '.join(q['name'] for q in quals)}) in {os.path.relpath(ip)}"


def merge_fluid_energy(out_dir, rows):
    """fluid_energy rows go into entities.json by name, as each entity's "fluid" object (the entities page is near
    MAX_COMMAND, so they are read apart). Returns the line printed."""
    path = os.path.join(out_dir, "entities.json")
    with open(path) as f:
        entities = json.load(f)
    def tidy(v):
        # (2.0.77 gives the fusion rates as 3.9999997 and 1.999998 a second: 4 decimals)
        if isinstance(v, float) and abs(v) < 1e12:
            return round(v, 4)
        if isinstance(v, dict):
            return {k: tidy(x) for k, x in v.items()}
        if isinstance(v, list):
            return [tidy(x) for x in v]
        return v
    by = {r["name"]: {k: tidy(v) for k, v in r.items() if k not in ("name", "type") and v not in (None, False, [], {})} for r in rows}
    merged = 0
    for e in entities:
        fluid = by.get(e["name"])
        if fluid:
            e["fluid"] = fluid
            merged += 1
        else:
            e.pop("fluid", None)
    with open(path, "w") as f:
        json.dump(entities, f, indent=0, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    return f"fluid_energy: {len(rows)} read, {merged} merged into {os.path.relpath(path)}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default="live")
    ap.add_argument("--port", type=int)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--out", default=os.path.join(HERE, "kb", "base-2.0.77"))
    ap.add_argument("--only", help="comma-separated categories")
    ap.add_argument("--password-file", help="the RCON password file (default ~/.config/pog/rcon-WORLD.pw): a private copy's")
    a = ap.parse_args()
    pw = open(a.password_file or os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    rc = Rcon(a.host, a.port or PORTS[a.world], pw)
    os.makedirs(a.out, exist_ok=True)
    for cat in (a.only.split(",") if a.only else LUA):
        rows = dump(rc, cat)
        if cat == "fluid_energy":
            print(merge_fluid_energy(a.out, rows))
            continue
        if cat == "effects":
            print(merge_effects(a.out, rows))
            continue
        if cat == "qualities":
            rows = tidy(rows)
        if cat in SINGLE:
            rows = rows[0]
        path = os.path.join(a.out, f"{cat}.json")
        with open(path, "w") as f:
            json.dump(rows, f, indent=0, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        # A single record (locations, settings): its lists' sizes, not "1"
        size = len(rows) if isinstance(rows, list) else ", ".join(f"{k} {len(v)}" for k, v in sorted(rows.items())
                                                                   if isinstance(v, list)) or "1 record"
        print(f"{cat}: {size} -> {os.path.relpath(path)}")
    line = add_module_qualities(a.out)
    if line:
        print(line)


if __name__ == "__main__":
    main()
