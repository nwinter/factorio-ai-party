-- railsignal: rail and chain signals on a rail layer, ground or elevated (d20 batch71 AG1, Sol #1686: Fulgora's
-- elevated junction near (-63,140); place_ghosts refused rail_layer and placements searched the ground only).
-- Read on 2.0.77 (private copy, an elevated straight line over ground with no ground rail):
--   * a rail end (LuaRailEnd) gives in_signal_location and out_signal_location (and alternative_* where a curve
--     needs them): {position, direction, rail_layer}; an elevated rail's say rail_layer 1 (defines.rail_layer.elevated);
--   * can_place_entity and create_entity take rail_layer for a signal, and so does an entity-ghost (revived, the signal
--     reads rail_layer 1); LuaEntity.rail_layer reads a built signal's layer;
--   * the game's manual check (build_check_type manual, and manual_ghost for a ghost) takes a signal beside the
--     elevated line at rail_layer elevated only, and only facing the way that spot faces (west there: every other
--     direction refused); with rail_layer ground it refuses it there; the script check takes either layer anywhere;
--   * a signal created 0.2 tiles off the spot stood on the spot (-148.5,2.5); get_connected_rails gives the rail it
--     guards; signal_state (open 0, closed 1, reserved 2, reserved_by_circuit_network 3), chain_signal_state (none 0,
--     all_open 1, partially_open 2, none_open 3).
return function(api)
  local M = {}
  M.TYPES = {['rail-signal']=true, ['rail-chain-signal']=true}
  local LAYER = {ground=0, elevated=1}
  local LAYER_NAME = {[0]='ground', [1]='elevated'}
  M.LAYER_NAME = LAYER_NAME
  local RAILS = {'straight-rail', 'half-diagonal-rail', 'curved-rail-a', 'curved-rail-b', 'elevated-straight-rail', 'elevated-half-diagonal-rail',
    'elevated-curved-rail-a', 'elevated-curved-rail-b', 'legacy-straight-rail', 'legacy-curved-rail'}
  local LOCS = {'in_signal_location', 'out_signal_location', 'alternative_in_signal_location', 'alternative_out_signal_location'}
  local DIR_NAME = {[0]='north', 'northnortheast', 'northeast', 'eastnortheast', 'east', 'eastsoutheast', 'southeast', 'southsoutheast',
    'south', 'southsouthwest', 'southwest', 'westsouthwest', 'west', 'westnorthwest', 'northwest', 'northnorthwest'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(p) return string.format('(%g,%g)', p.x, p.y) end
  local function dir_name(d) return DIR_NAME[d] or tostring(d) end
  function M.is_signal(name)
    local proto = name and prototypes.entity[name]
    return proto and M.TYPES[proto.type] or false
  end
  -- rail_layer as given: nil, 'ground' or 'elevated' (a number 0 or 1 too).
  function M.layer_arg(v)
    if v == nil then return nil end
    if v == 0 or v == 1 then return v end
    local l = LAYER[v]
    assert(l, 'rail_layer is ground or elevated')
    return l
  end
  -- The signal spots of the rails within radius of centre: {position, direction, rail_layer, rail, kind}, each once,
  -- nearest first; layer filters.
  function M.spots(surface, force, center, radius, layer)
    local seen, out = {}, {}
    local rails = try(function() return surface.find_entities_filtered{position=center, radius=radius + 3, type=RAILS, limit=512} end) or {}
    for _, r in ipairs(rails) do
      for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do
        local re = try(function() return r.get_rail_end(rd) end)
        for _, k in ipairs(re and LOCS or {}) do
          local loc = try(function() return re[k] end)
          local pos = loc and loc.position
          if pos and (layer == nil or loc.rail_layer == layer) then
            local d2 = (pos.x - center.x) ^ 2 + (pos.y - center.y) ^ 2
            local key = pos.x .. ',' .. pos.y .. ',' .. loc.direction .. ',' .. (loc.rail_layer or 0)
            if d2 <= radius * radius and not seen[key] then
              seen[key] = true
              out[#out+1] = {position={x=pos.x, y=pos.y}, direction=loc.direction, rail_layer=loc.rail_layer or 0, rail=r, d2=d2}
            end
          end
        end
      end
    end
    table.sort(out, function(a, b) return a.d2 < b.d2 or (a.d2 == b.d2 and (a.position.x < b.position.x or (a.position.x == b.position.x and a.position.y < b.position.y))) end)
    return out
  end
  local function spot_text(s)
    return string.format('%s facing %s (%s, beside %s %s)', at(s.position), dir_name(s.direction), LAYER_NAME[s.rail_layer] or '?', s.rail.name, at(s.rail.position))
  end
  -- The direction of the signal spot at pos (on layer if given) when one is there; nil else.
  function M.direction_at(surface, force, pos, layer)
    for _, s in ipairs(M.spots(surface, force, pos, 1, layer)) do
      if math.abs(s.position.x - pos.x) < 0.3 and math.abs(s.position.y - pos.y) < 0.3 then return s.direction, s.rail_layer end
    end
  end
  -- The game's own check for a signal (manual, or manual_ghost for a ghost) on the layer asked, or with none asked the
  -- ground layer and then the elevated: {ok, layer, why}.
  function M.check(surface, force, name, pos, dir, layer, ghost)
    local ct = ghost and defines.build_check_type.manual_ghost or defines.build_check_type.manual
    local tried = layer and {layer} or {0, 1}
    for _, l in ipairs(tried) do
      if try(function() return surface.can_place_entity{name=name, position=pos, direction=dir, force=force, rail_layer=l, build_check_type=ct} end) then
        return {ok=true, layer=l}
      end
    end
    local near = M.spots(surface, force, pos, 6, layer)
    local list = {}
    for _, sp in ipairs(near) do
      if #list >= 4 then break end
      if try(function() return surface.can_place_entity{name=name, position=sp.position, direction=sp.direction, force=force, rail_layer=sp.rail_layer, build_check_type=ct} end) then
        list[#list+1] = spot_text(sp)
      end
    end
    return {ok=false, why=string.format('the game refuses %s at %s facing %s on the %s rail layer%s; %s', name, at(pos), dir_name(dir or 0),
      layer and LAYER_NAME[layer] or 'ground or elevated', ghost and ' (its ghost check)' or '',
      #list > 0 and 'spots within 6 tiles the game takes it on now: ' .. table.concat(list, '; ')
        or string.format('of %d signal spot%s within 6 tiles%s, the game takes it on none now', #near, #near == 1 and '' or 's', layer and ' on that layer' or ''))}
  end
  -- A spec's signal placement made ready: its direction (the spot's there when none is given) and layer, checked.
  -- {direction, layer, line} or an error with the game's refusal.
  function M.resolve(surface, force, name, pos, dir, layer, ghost)
    local snapped
    if dir == nil then
      local d, l = M.direction_at(surface, force, pos, layer)
      if d then dir = d; snapped = string.format('direction %s: the signal spot there faces so', dir_name(d)) end
      layer = layer or l
    end
    local c = M.check(surface, force, name, pos, dir or 0, layer, ghost)
    if not c.ok then error(c.why, 0) end
    return {direction=dir or 0, layer=c.layer, line=string.format('%s at %s facing %s on the %s rail layer%s', name, at(pos), dir_name(dir or 0), LAYER_NAME[c.layer], snapped and ' (' .. snapped .. ')' or '')}
  end
  -- placements for a signal: the spots of the rails near (rail_layer filters), each with the game's check.
  function M.placements(p, a, proto)
    local center = a.near ~= nil and api.position(a.near) or a.position ~= nil and api.position(a.position) or p.position
    local radius = api.integer(a.radius, 10, 1, 24, 'radius')
    local limit = api.integer(a.limit, 10, 1, 50, 'limit')
    local layer = M.layer_arg(a.rail_layer)
    local out, refused = {}, 0
    local spots = M.spots(p.surface, p.force, center, radius, layer)
    for _, s in ipairs(spots) do
      if #out >= limit then break end
      local ok = try(function() return p.surface.can_place_entity{name=proto.name, position=s.position, direction=s.direction, force=p.force, rail_layer=s.rail_layer,
        build_check_type=defines.build_check_type.manual_ghost} end)
      if ok then
        out[#out+1] = {position=s.position, direction=dir_name(s.direction), rail_layer=LAYER_NAME[s.rail_layer], rail={name=s.rail.name, position=s.rail.position}}
      else refused = refused + 1 end
    end
    return {name=proto.name, near=center, radius=radius, rail_layer=layer and LAYER_NAME[layer] or 'ground and elevated', placements=out, count=#out, checked=#spots,
      refused=refused > 0 and refused or nil,
      note='the signal spots of the rails within the radius (each rail end\'s in and out signal locations, as the game snaps a signal), each checked with the game\'s ghost check on its rail layer; '
        .. 'a spot already holding a signal or blocked is counted in refused'}
  end
  -- inspect of a signal (or its ghost): its rail layer, the rails it is attached to, its block state.
  function M.read(e)
    if not (e and e.valid) then return nil end
    local ghost = e.type == 'entity-ghost'
    local t = ghost and e.ghost_type or e.type
    if not M.TYPES[t] then return nil end
    local out = {}
    if ghost then
      out.note = 'a ghost: its rail layer and rails are read once built'
      return out
    end
    local l = try(function() return e.rail_layer end)
    out.rail_layer = LAYER_NAME[l]
    local rails = {}
    for _, r in ipairs(try(function() return e.get_connected_rails() end) or {}) do rails[#rails+1] = {name=r.name, position=r.position} end
    out.rails = rails
    if t == 'rail-chain-signal' then
      local s = try(function() return e.chain_signal_state end)
      for k, v in pairs(defines.chain_signal_state or {}) do if v == s then out.state = k end end
    end
    local s = try(function() return e.signal_state end)
    for k, v in pairs(defines.signal_state or {}) do if v == s then out.signal_state = k end end
    local parts = {}
    for _, r in ipairs(rails) do parts[#parts+1] = r.name .. ' ' .. at(r.position) end
    out.line = string.format('%s %s on the %s rail layer, attached to %s; block %s%s', e.name, at(e.position), out.rail_layer or '?',
      #parts > 0 and table.concat(parts, ', ') or 'no rail', out.signal_state or '?', out.state and ', chain ' .. out.state or '')
    return out
  end
  return M
end
