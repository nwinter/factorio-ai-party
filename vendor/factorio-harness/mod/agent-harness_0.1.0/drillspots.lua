-- placements {name: a mining drill or pumpjack, resource, near?, radius?, limit?} (d17 batch21 B2, Sonnet: free wells
-- and drill spots tried one placement at a time): the spots on a resource round a position, in a chunk our force sees
-- now, with what blocks each one (the build refusal's own text: an entity of ours or another, a tile and the foundation
-- or landfill it needs, a cliff, ...). A pumpjack (a drill over a fluid resource): every well, the directions it fits.
-- A solid-ore drill: every tile centre (corner for an even footprint) whose mining area holds the resource, the most
-- ore under it first, the free ones taken so none overlaps another. Read only; bounded: radius 1..32, one find of the
-- resource and one placement check a spot (and direction), the refusal text for at most MAX_WHY spots.
return function(api)
  local M = {}
  local MAX_WHY = 24
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local function fits(p, proto, q, d)
    return p.surface.can_place_entity{name=proto.name, position=q, direction=d, force=p.force, build_check_type=defines.build_check_type.manual}
  end
  -- 'the fewest words' for the group count: what the refusal names first (after "placement blocked by").
  local function kind_of(why)
    local w = why:match('^placement blocked by tiles: ([%w%-]+)') and 'tiles: ' .. why:match('^placement blocked by tiles: ([%w%-]+)')
      or why:match('^placement blocked by ([%w%-]+)') or why:match('^placement blocked: ([^;(]+)') or 'blocked'
    return w
  end
  function M.read(p, a, proto)
    local res = a.resource
    local pos = a.near ~= nil and api.position(a.near) or a.position ~= nil and api.position(a.position) or p.position
    api.read_sight(p, pos, 'near')
    local radius = api.integer(a.radius, 16, 1, 32, 'radius (with resource)')
    local limit = api.integer(a.limit, 20, 1, 100, 'limit')
    local area = {{pos.x - radius, pos.y - radius}, {pos.x + radius, pos.y + radius}}
    local filter = {area=area, type='resource'}
    if type(res) == 'string' then
      assert(prototypes.entity[res] and prototypes.entity[res].type == 'resource', tostring(res) .. ' is not a resource')
      filter.name = res
    end
    local list = p.surface.find_entities_filtered(filter)
    local cats = try(function() return proto.resource_categories end) or {}
    local ores, fluid, name = {}, false, nil
    for _, r in ipairs(list) do
      local cat = try(function() return r.prototype.resource_category end)
      if r.valid and (not next(cats) or cats[cat]) and api.seen(p, r.position) then
        ores[#ores+1] = r
        name = name or r.name
        if try(function() return r.prototype.infinite_resource end) or try(function() return r.prototype.mineable_properties.products[1].type end) == 'fluid' then fluid = true end
      end
    end
    assert(#ores > 0, string.format('no %s within %d tiles of %s that a %s mines, in a chunk our force sees now', type(res) == 'string' and res or 'resource', radius, at(pos), proto.name))
    local free, blocked, groups, gorder, nwhy = {}, {}, {}, {}, 0
    local function block(q, d)
      local why = 'placement blocked'
      if nwhy < MAX_WHY then nwhy = nwhy + 1; why = try(function() return api.why(p, proto, q, d) end) or why end
      local k = kind_of(why)
      if not groups[k] then groups[k] = {n=0, first=at(q)}; gorder[#gorder+1] = k end
      groups[k].n = groups[k].n + 1
      blocked[#blocked+1] = {position=q, why=why}
    end
    if fluid or proto.name == 'pumpjack' then
      -- every well: taken by a drill of ours, or the directions a pumpjack fits
      for _, r in ipairs(ores) do
        local q = {x=r.position.x, y=r.position.y}
        local taken = p.surface.find_entities_filtered{position=q, radius=0.5, type='mining-drill', force=p.force, limit=1}[1]
        if taken then
          blocked[#blocked+1] = {position=q, why=string.format('taken by our %s %s', taken.name, at(taken.position))}
          local k = 'ours already'
          if not groups[k] then groups[k] = {n=0, first=at(q)}; gorder[#gorder+1] = k end
          groups[k].n = groups[k].n + 1
        else
          local dirs = {}
          for _, d in ipairs({0, 4, 8, 12}) do if fits(p, proto, q, d) then dirs[#dirs+1] = NAMES[d] end end
          if #dirs > 0 then free[#free+1] = {position=q, directions=dirs, amount=r.amount, line=string.format('%s %s %s: fits facing %s', r.name, at(q), r.amount and ('yield ' .. r.amount) or '', table.concat(dirs, ', '))}
          else block(q, 0) end
        end
      end
      table.sort(free, function(x, y) return (x.amount or 0) > (y.amount or 0) end)
    else
      -- tile centres whose mining area holds the ore, the most ore first; the free ones kept apart
      local tiles = {}
      -- (number keys: a string key costs about 16 us in the game's Lua)
      for _, r in ipairs(ores) do tiles[(math.floor(r.position.x) + 2097152) * 4194304 + math.floor(r.position.y) + 2097152] = r.amount or 1 end
      local mr = try(function() return proto.mining_drill_radius end) or 1
      local w, h = proto.tile_width or 2, proto.tile_height or 2
      local ox, oy = w % 2 == 1 and 0.5 or 0, h % 2 == 1 and 0.5 or 0
      local cands = {}
      for x = math.floor(pos.x - radius), math.floor(pos.x + radius) do
        for y = math.floor(pos.y - radius), math.floor(pos.y + radius) do
          local q = {x=x + ox, y=y + oy}
          local amount, n = 0, 0
          for tx = math.floor(q.x - mr + 0.01), math.ceil(q.x + mr - 0.01) - 1 do
            for ty = math.floor(q.y - mr + 0.01), math.ceil(q.y + mr - 0.01) - 1 do
              local v = tiles[(tx + 2097152) * 4194304 + ty + 2097152]
              if v then amount, n = amount + v, n + 1 end
            end
          end
          if n > 0 then cands[#cands+1] = {position=q, amount=amount, tiles=n} end
        end
      end
      table.sort(cands, function(x, y) return x.amount > y.amount end)
      local taken = {}
      local function overlaps(q)
        for _, t in ipairs(taken) do if math.abs(t.x - q.x) < w and math.abs(t.y - q.y) < h then return true end end
        return false
      end
      for _, c in ipairs(cands) do
        if not overlaps(c.position) then
          if #free < limit and fits(p, proto, c.position, 0) then
            free[#free+1] = {position=c.position, amount=c.amount, tiles=c.tiles, line=string.format('%s: %d %s tiles, %d under its mining area', at(c.position), c.tiles, name, c.amount)}
            taken[#taken+1] = c.position
          elseif #blocked < 200 and not fits(p, proto, c.position, 0) then block(c.position, 0) end
        end
      end
    end
    local shown = {}
    for i = 1, math.min(limit, #free) do shown[i] = free[i] end
    local parts = {}
    for _, k in ipairs(gorder) do parts[#parts+1] = string.format('%s %d (one at %s)', k, groups[k].n, groups[k].first) end
    local why_rows = {}
    for i = 1, math.min(#blocked, MAX_WHY) do why_rows[i] = string.format('%s: %s', at(blocked[i].position), blocked[i].why) end
    return {name=proto.name, resource=name, near=pos, radius=radius, free=shown, free_count=#free, blocked=why_rows, blocked_count=#blocked,
      blocked_by=#parts > 0 and table.concat(parts, ', ') or nil,
      line=string.format('%s on %s within %d tiles of %s: %d free%s, %d blocked%s', proto.name, name, radius, at(pos), #free,
        fluid and ' wells' or ' spots (none overlapping)', #blocked, #parts > 0 and ' (' .. table.concat(parts, ', ') .. ')' or '')}
  end
  return M
end
