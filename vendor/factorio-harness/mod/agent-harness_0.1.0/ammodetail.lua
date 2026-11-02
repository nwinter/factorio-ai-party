-- Read-only 2.0.77 trigger facts. Cache immutable prototypes, never force bonuses.
-- A graph, not a blast simulation: repeat counts, falloff and overlapping areas are not summed.
local M = {}
M.LIMITATION = 'area/splash and multi-target effects not modelled; each ammunition estimated independently'
local AMMO, ENTITY, QUALITY = {}, {}, {}
local function try(fn) local ok, v = pcall(fn); if ok then return v end end
local fields = {'type', 'radius', 'force', 'target_entities', 'target_enemies', 'trigger_from_target',
  'repeat_count', 'repeat_count_deviation', 'probability', 'projectile', 'beam', 'stream', 'entity_name',
  'lower_distance_threshold', 'upper_distance_threshold', 'lower_damage_modifier', 'upper_damage_modifier',
  'collision_mode', 'starting_speed', 'starting_speed_deviation', 'max_range', 'min_range'}
local branches = {'action', 'action_delivery', 'source_effects', 'target_effects'}
local function friendly(t)
  if t.target_enemies == true or t.force == 'enemy' then return 'no' end
  if t.force == 'all' or t.force == 'same' or t.force == 'friend' then return 'yes' end
  return 'unknown'
end
local function facts(ammo)
  if AMMO[ammo] then return AMMO[ammo] end
  local ip = prototypes.item[ammo]
  local at = ip and (try(function() return ip.get_ammo_type('turret') end) or try(function() return ip.get_ammo_type() end))
  local out = {direct_damage={}, area_damage={}, actions={}, projectiles={},
    units='base prototype damage per effect; radius in tiles; repeats, probability, falloff and overlap not summed',
    scope='ammo actions and referenced projectile attack/final actions; created entities, beams and streams named only'}
  local nodes, entities, seen = 0, 0, {}
  local walk, entity
  local function capped() out.truncated = true; return {unread='detail bound reached'} end
  function entity(name, area)
    if seen[name] then return end
    if entities >= 16 then out.truncated = true; return end
    seen[name], entities = true, entities + 1
    local raw = ENTITY[name]
    if not raw then
      local p = prototypes.entity[name]
      raw = {attack=p and try(function() return p.attack_result end), final=p and try(function() return p.final_attack_result end)}
      ENTITY[name] = raw
    end
    out.projectiles[name] = {attack=walk(raw.attack, name .. '.attack', area, 0),
      final=walk(raw.final, name .. '.final', area, 0)}
  end
  function walk(t, path, area, depth)
    if type(t) ~= 'table' then return nil end
    if depth > 24 or nodes >= 512 then return capped() end
    nodes = nodes + 1
    local r = {}
    if t[1] then
      for i, v in ipairs(t) do
        if nodes >= 512 then r[#r+1] = capped(); break end
        r[#r+1] = walk(v, path .. '[' .. i .. ']', area, depth + 1)
      end
      return r
    end
    for _, k in ipairs(fields) do if t[k] ~= nil then r[k] = t[k] end end
    if t.type == 'area' then
      area = {radius=t.radius, force=t.force, friendly_fire=friendly(t), path=path,
        target_entities=t.target_entities, repeat_count=t.repeat_count, probability=t.probability}
      r.friendly_fire = area.friendly_fire
    end
    if t.damage then
      r.damage = {type=t.damage.type, amount=t.damage.amount}
      if area then
        out.area_damage[#out.area_damage+1] = {damage={[t.damage.type]=t.damage.amount}, radius=area.radius,
          force=area.force, friendly_fire=area.friendly_fire, action_path=area.path, effect_path=path}
      else
        local k = t.damage.type
        out.direct_damage[k] = (out.direct_damage[k] or 0) + t.damage.amount
      end
    end
    for _, k in ipairs(branches) do if t[k] then r[k] = walk(t[k], path .. '.' .. k, area, depth + 1) end end
    -- 2.0.77 nested-result nodes have action but no type; retain that structure explicitly.
    if t.action and not t.type then r.type = 'nested-action' end
    if t.projectile then entity(t.projectile, area) end
    return r
  end
  out.actions = walk(at and at.action, 'ammo.action', nil, 0) or {}
  if not at then out.unavailable = 'ammo prototype action unavailable' end
  AMMO[ammo] = out
  return out
end
function M.read(ammo, quality)
  quality = quality or 'normal'
  local qm = QUALITY[quality]
  if not qm then qm = try(function() return prototypes.quality[quality].default_multiplier end) or 1; QUALITY[quality] = qm end
  return {prototype=facts(ammo), quality=quality, quality_multiplier=qm,
    quality_scaling='damage uses ammunition quality multiplier; listed prototype damage and radii are unscaled; force/turret bonuses excluded',
    forecast_damage_scope='legacy flattened damage entries applied to one target; nested secondary projectiles excluded',
    damage_model=M.LIMITATION}
end
return M
