#!/usr/bin/env python3
"""Dump Factorio prototypes over RCON into the analyst's knowledge base (read-only Lua, nothing in the game changes).

  python3 tools/analyst/dump_prototypes.py                      # world live -> tools/analyst/kb/base-2.0.77/
  python3 tools/analyst/dump_prototypes.py --world sa --port 27031 --out tools/analyst/kb/space-age-2.0.77

Each category is read in pages of names (sorted, so pages are stable) to keep RCON replies small. Every property read
is wrapped in pcall, so a field missing in this game version is left out instead of failing the dump.
"""
import argparse, json, os, sys

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
for i = START, math.min(#list, START + COUNT - 1) do
  local r = src[list[i]]
  out[#out+1] = {name=r.name, category=r.category, energy=r.energy, enabled=r.enabled, hidden=r.hidden,
    ingredients=products(r.ingredients), products=products(r.products), subgroup=g(function() return r.subgroup.name end),
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
    weight=g(function() return it.weight end), hidden=it.hidden, order=it.order}
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
}

PAGE = {"recipes": 60, "technologies": 40, "items": 80, "fluids": 80, "entities": 40, "locations": 1, "settings": 1}
SINGLE = ("settings", "locations")


def dump(rc, cat):
    out, start, total = [], 1, None
    while total is None or start <= total:
        body = COMMON + LUA[cat].replace("START", str(start)).replace("COUNT", str(PAGE[cat]))
        text = rc.command("/silent-command " + " ".join(line.strip() for line in body.splitlines() if line.strip()))
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            raise SystemExit(f"{cat} page {start}: not JSON: {text[:400]}")
        total = data["total"]
        out += data["items"]
        start += PAGE[cat]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default="live")
    ap.add_argument("--port", type=int)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--out", default=os.path.join(HERE, "kb", "base-2.0.77"))
    ap.add_argument("--only", help="comma-separated categories")
    a = ap.parse_args()
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    rc = Rcon(a.host, a.port or PORTS[a.world], pw)
    os.makedirs(a.out, exist_ok=True)
    for cat in (a.only.split(",") if a.only else LUA):
        rows = dump(rc, cat)
        if cat in SINGLE:
            rows = rows[0]
        path = os.path.join(a.out, f"{cat}.json")
        with open(path, "w") as f:
            json.dump(rows, f, indent=0, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"{cat}: {len(rows) if isinstance(rows, list) else 1} -> {os.path.relpath(path)}")


if __name__ == "__main__":
    main()
