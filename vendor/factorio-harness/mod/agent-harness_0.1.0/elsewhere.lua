-- elsewhere: where a surface holds an item that no logistic network gives (d18 batch37 B1, Sonnet: calcite stalled
-- Wayfarer twice while it sat in chests the silo's network could not give; Grok 16:57: Gleba held about 16,000 copper ore
-- in plain chests while furnaces and LDS assemblers were empty). Chests of ours on the surface and our crafters'
-- outputs, both from the census pass's lists (no search: a whole-surface find of chests took 14-16 ms on Nauvis), by kind: plain chests (in no network: none gives them), requester and
-- buffer chests (theirs), provider and storage chests outside the given network (another network's), machine outputs.
-- Counts, how many places, and the nearest NEAR positions to a point. Kept FRESH ticks a surface and item.
return function(api)
  local M = {}
  M.FRESH, M.NEAR = 3600, 3
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local cache = {}
  local function mode_of(e)
    if e.type ~= 'logistic-container' then return 'plain' end
    local m = try(function() return e.prototype.logistic_mode end)
    if m == 'requester' or m == 'buffer' then return 'requesters' end
    return 'network'
  end
  -- {plain, requesters, network (per network id), outputs}: each {count, places, list {pos, count}}.
  -- quality (d22 batch91 BA1): that quality alone (get_item_count(name) counts normal alone on 2.0.77)
  function M.read(force, surface, item, quality)
    local key = surface.index .. '|' .. force.name .. '|' .. item .. '|' .. (quality or 'normal')
    local name = item
    if quality and quality ~= 'normal' then item = {name=name, quality=quality} end
    local c = cache[key]
    if c and game.tick - c.tick < M.FRESH then return c.out end
    local out = {plain={count=0, places=0, list={}}, requesters={count=0, places=0, list={}}, outputs={count=0, places=0, list={}}, networks={}}
    local chests = api.chests and try(function() return api.chests(force, surface) end)
    out.listed = chests ~= nil
    for _, e in ipairs(chests or {}) do
      local n = e.valid and (try(function() return e.get_item_count(item) end) or 0) or 0
      if n > 0 then
        local k = mode_of(e)
        if k == 'network' then
          local ln = try(function() return e.logistic_network end)
          local id = ln and ln.network_id or 0
          local g = out.networks[id] or {count=0, places=0, list={}}
          out.networks[id] = g
          g.count = g.count + n; g.places = g.places + 1; g.list[#g.list+1] = {pos=e.position, count=n, name=e.name}
          if not ln then out.plain.count = out.plain.count + n; out.plain.places = out.plain.places + 1; out.plain.list[#out.plain.list+1] = {pos=e.position, count=n, name=e.name} end
        else
          local g = out[k]
          g.count = g.count + n; g.places = g.places + 1; g.list[#g.list+1] = {pos=e.position, count=n, name=e.name}
        end
      end
    end
    for _, e in ipairs(api.crafters and try(function() return api.crafters(force, surface) end) or {}) do
      local inv = e.valid and try(function() return e.get_output_inventory() end)
      local n = inv and (try(function() return inv.get_item_count(item) end) or 0) or 0
      if n > 0 then
        local g = out.outputs
        g.count = g.count + n; g.places = g.places + 1; g.list[#g.list+1] = {pos=e.position, count=n, name=e.name}
      end
    end
    cache[key] = {tick=game.tick, out=out}
    return out
  end
  local function nearest(list, to)
    table.sort(list, function(x, y)
      local dx = to and ((x.pos.x - to.x) ^ 2 + (x.pos.y - to.y) ^ 2) or -x.count
      local dy = to and ((y.pos.x - to.x) ^ 2 + (y.pos.y - to.y) ^ 2) or -y.count
      return dx < dy
    end)
    local parts = {}
    for i = 1, math.min(M.NEAR, #list) do parts[i] = string.format('%s %s %d', list[i].name, at(list[i].pos), list[i].count) end
    return table.concat(parts, ', ')
  end
  -- One line: what the surface holds of item that the network `ln` (nil: none) cannot give, nearest `to` first; nil when
  -- it holds none outside it.
  -- no_networks: leave other networks out (the silo's request rows name them already).
  function M.line(force, surface, item, ln, to, no_networks, quality)
    local r = M.read(force, surface, item, quality)
    local parts, total = {}, 0
    if r.plain.count > 0 then
      total = total + r.plain.count
      parts[#parts+1] = string.format('plain chests %d in %d (no network gives them; nearest %s)', r.plain.count, r.plain.places, nearest(r.plain.list, to))
    end
    if r.requesters.count > 0 then
      total = total + r.requesters.count
      parts[#parts+1] = string.format('requester and buffer chests %d in %d (theirs; nearest %s)', r.requesters.count, r.requesters.places, nearest(r.requesters.list, to))
    end
    local mine = ln and ln.network_id
    for id, g in pairs(r.networks) do
      -- (with no network named, every network's providers and storage give it: not counted)
      if id ~= 0 and mine and id ~= mine and not no_networks then
        total = total + g.count
        parts[#parts+1] = string.format('network %d\'s provider and storage chests %d in %d (nearest %s)', id, g.count, g.places, nearest(g.list, to))
      end
    end
    if r.outputs.count > 0 then
      total = total + r.outputs.count
      parts[#parts+1] = string.format('machine outputs %d in %d (nearest %s)', r.outputs.count, r.outputs.places, nearest(r.outputs.list, to))
    end
    if total == 0 then return nil, 0 end
    if not r.listed then parts[#parts+1] = 'chests not read: the census pass has not listed them yet' end
    return string.format('%s holds %d %s%s %s: %s', surface.name, total, item, quality and quality ~= 'normal' and ' (' .. quality .. ')' or '', mine and ('that network ' .. mine .. ' cannot give') or 'outside the logistic networks\' providers and storage', table.concat(parts, '; ')), total
  end
  return M
end
