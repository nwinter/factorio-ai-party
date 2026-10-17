-- platform_defense {platform} (A4, Astra 01:50: four collectors lost last shift): a platform's turret cover.
-- - each asteroid collector's front (the middle of its collection area, its tile rule that keeps empty space): the
--   turrets whose range reaches it, each with its ammo and what feeds it (an inserter and what it takes from, robots
--   bringing ammo, or nothing: by hand); uncovered, the nearest turret and how far past its range;
-- - each side of the hull (foundation tiles with empty space beside them, by the side the space is on): how many edge
--   tiles no turret reaches, as runs (gaps), the longest first;
-- - the turrets: ammo, feed, and those empty.
-- A turret's reach is its prototype's attack range from its centre. Read only; bounded: 40000 foundation tiles,
-- 256 turrets.
return function(api)
  local M = {}
  local MAX_TILES, MAX_TURRETS, GAPS = 40000, 256, 8
  local TURRETS = {'ammo-turret', 'electric-turret', 'fluid-turret'}
  local SIDES = {{0, -1, 'north'}, {1, 0, 'east'}, {0, 1, 'south'}, {-1, 0, 'west'}}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function key(x, y) return (x + 32768) * 65536 + (y + 32768) end
  local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
  local function rotate(x, y, dir) for _ = 1, math.floor(((dir or 0) % 16) / 4) do x, y = -y, x end return x, y end
  -- what a turret holds and what feeds it
  local function turret_info(s, force, t)
    local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
    local held, rounds = {}, 0
    for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do held[#held+1] = c.name .. '*' .. c.count; rounds = rounds + c.count end
    local ammo = t.type == 'ammo-turret' and (#held > 0 and table.concat(held, ' ') or 'no ammo')
      or t.type == 'electric-turret' and 'electric' or 'fluid'
    local feed
    if t.type == 'ammo-turret' then
      local b = t.bounding_box
      for _, ins in ipairs(try(function() return s.find_entities_filtered{area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}, type='inserter', force=force} end) or {}) do
        if not feed and try(function() return ins.drop_target end) == t then
          local src = try(function() return ins.pickup_target end)
          feed = string.format('%s %s from %s', ins.name, at(ins.position), src and src.valid and (src.name .. ' ' .. at(src.position)) or 'nothing')
        end
      end
      if not feed then
        local proxy = try(function() local x = t.item_request_proxy; return x and x.valid and x end)
        if proxy then feed = 'robots bringing ammo' end
      end
    end
    return {entity=t, name=t.name, position=t.position, range=try(function() return t.prototype.attack_parameters.range end) or 0,
      ammo=ammo, empty=t.type == 'ammo-turret' and rounds == 0, feed=feed or (t.type == 'ammo-turret' and 'nothing (by hand)' or t.type == 'electric-turret' and 'power' or 'pipe')}
  end
  local function covering(turrets, q)
    local list, nearest, nd = {}, nil, nil
    for _, t in ipairs(turrets) do
      local d = dist(t.position, q)
      if d <= t.range then list[#list+1] = t end
      local over = d - t.range
      if not nd or over < nd then nearest, nd = t, over end
    end
    return list, nearest, nd
  end
  function M.read(p, a)
    local pl = api.platform(p, a.platform)
    local s = pl.surface
    assert(s, 'platform ' .. pl.name .. ' has no surface yet')
    local force = pl.force
    local turrets = {}
    for _, t in ipairs(s.find_entities_filtered{type=TURRETS, force=force, limit=MAX_TURRETS}) do
      if t.valid then turrets[#turrets+1] = turret_info(s, force, t) end
    end
    local lines = {}
    -- collectors' fronts
    local collectors = {}
    for _, c in ipairs(s.find_entities_filtered{type='asteroid-collector', force=force}) do
      local front
      for _, rule in ipairs(try(function() return c.prototype.tile_buildability_rules end) or {}) do
        local empty = false
        for l in pairs(rule.required_tiles and rule.required_tiles.layers or {}) do if l == 'empty_space' then empty = true end end
        if empty then
          local cx, cy = (rule.area.left_top.x + rule.area.right_bottom.x) / 2, (rule.area.left_top.y + rule.area.right_bottom.y) / 2
          local rx, ry = rotate(cx, cy, c.direction)
          front = {x=c.position.x + rx, y=c.position.y + ry}
        end
      end
      front = front or c.position
      local list, nearest, nd = covering(turrets, front)
      local words = {}
      for i, t in ipairs(list) do if i <= 4 then words[i] = string.format('%s %s %s, fed by %s', t.name, at(t.position), t.ammo, t.feed) end end
      local row = {position=c.position, front=front, covered_by=#list}
      collectors[#collectors+1] = row
      if #list > 0 then
        lines[#lines+1] = string.format('asteroid-collector %s, front %s: %d turret%s reach it: %s%s', at(c.position), at(front), #list, #list == 1 and '' or 's',
          table.concat(words, '; '), #list > 4 and string.format('; +%d more', #list - 4) or '')
      else
        lines[#lines+1] = string.format('asteroid-collector %s, front %s: NO turret reaches it%s', at(c.position), at(front),
          nearest and string.format(' (nearest %s %s, %.0f tiles past its range %g)', nearest.name, at(nearest.position), nd, nearest.range) or ' (no turret on the platform)')
      end
    end
    -- hull edges by side
    local tiles = s.find_tiles_filtered{name='space-platform-foundation', limit=MAX_TILES}
    local set = {}
    for _, t in ipairs(tiles) do set[key(t.position.x, t.position.y)] = true end
    local sides = {}
    for _, t in ipairs(tiles) do
      local x, y = t.position.x, t.position.y
      for _, d in ipairs(SIDES) do
        if not set[key(x + d[1], y + d[2])] then
          local q = {x=x + 0.5, y=y + 0.5}
          local list = covering(turrets, q)
          local sd = sides[d[3]] or {edge=0, open={}}
          sides[d[3]] = sd
          sd.edge = sd.edge + 1
          if #list == 0 then sd.open[#sd.open+1] = {x=x, y=y} end
        end
      end
    end
    local side_rows = {}
    for _, d in ipairs(SIDES) do
      local sd = sides[d[3]]
      if sd then
        -- runs of uncovered edge tiles: along x for north/south, along y for east/west
        local along = (d[3] == 'north' or d[3] == 'south')
        table.sort(sd.open, function(u, v)
          if along then if u.y ~= v.y then return u.y < v.y end return u.x < v.x end
          if u.x ~= v.x then return u.x < v.x end return u.y < v.y end)
        local runs = {}
        for _, t in ipairs(sd.open) do
          local r = runs[#runs]
          if r and math.abs((along and t.x or t.y) - (along and r.x1 or r.y1)) <= 2 and math.abs((along and t.y or t.x) - (along and r.y1 or r.x1)) <= 2 then
            r.x1, r.y1, r.n = t.x, t.y, r.n + 1
          else runs[#runs+1] = {x0=t.x, y0=t.y, x1=t.x, y1=t.y, n=1} end
        end
        table.sort(runs, function(u, v) return u.n > v.n end)
        local gaps = {}
        for i, r in ipairs(runs) do if i <= GAPS then gaps[i] = string.format('(%d,%d)-(%d,%d) %d tile%s', r.x0, r.y0, r.x1, r.y1, r.n, r.n == 1 and '' or 's') end end
        side_rows[#side_rows+1] = {side=d[3], edge_tiles=sd.edge, uncovered=#sd.open, gaps=gaps}
        lines[#lines+1] = string.format('%s side: %d edge tiles, %d no turret reaches%s', d[3], sd.edge, #sd.open,
          #gaps > 0 and ': ' .. table.concat(gaps, '; ') .. (#runs > GAPS and string.format('; +%d more runs', #runs - GAPS) or '') or '')
      end
    end
    local empty, hand = {}, 0
    for _, t in ipairs(turrets) do
      if t.empty then empty[#empty+1] = t.name .. ' ' .. at(t.position) end
      if t.feed == 'nothing (by hand)' then hand = hand + 1 end
    end
    lines[#lines+1] = string.format('%d turrets: %d empty%s, %d fed by nothing (by hand)', #turrets, #empty, #empty > 0 and ' (' .. table.concat(empty, ', ', 1, math.min(6, #empty)) .. ')' or '', hand)
    local trows = {}
    for i, t in ipairs(turrets) do if i <= 64 then trows[i] = {name=t.name, position=t.position, range=t.range, ammo=t.ammo, feed=t.feed} end end
    -- (d17 batch13 B1) each turret's way back to its ammunition: what can reach it and what is stranded
    local feed
    if api.ammofeed then
      local ok, tr = pcall(api.ammofeed.trace, pl)
      if ok then
        local aboard = try(function() return p.character and p.character.valid and p.character.surface == s end) == true
        local per = {}
        for i, row in ipairs(tr.rows) do if i <= 64 then per[i] = {position=row.position, holds=row.own, reaches=row.reaches, stopped=#row.stops > 0 or nil} end end
        feed = {reaches=tr.reaches, stranded=tr.stranded, stranded_groups=tr.stranded_groups, stranded_recover=tr.stranded_recover, hub_reaches=tr.hub_reaches,
          turrets=per, lines=api.ammofeed.lines(tr, a.feed == true, pl.name, aboard)}
        for _, l in ipairs(feed.lines) do lines[#lines+1] = l end
      else feed = {error=tostring(tr)} end
    end
    return {platform=pl.name, lines=lines, collectors=collectors, sides=side_rows, turrets=trows, feed=feed,
      note='a turret reaches what lies within its attack range of its centre; a collector\'s front is the middle of its collection area; the hull\'s edge tiles are foundation tiles with empty space beside them'}
  end
  M.schema = {platform_defense = {platform='platform name', feed='optional true: every turret\'s way to its ammunition (default: those low, under 10 that can reach them, or stopped)',
    returns='lines: each asteroid collector\'s front (the middle of its collection area) with the turrets whose range reaches it (ammo, fed by: an inserter and its source, robots, or nothing: by hand), or NO turret with the nearest and how far past its range; each hull side (north, east, south, west: foundation tiles with empty space on that side) with the edge tiles no turret reaches as runs, the longest first; the turrets (empty, fed by hand); then the ammunition: what can reach a turret (turrets, the belts on their ways, sources, the hub when an inserter takes from it toward one) against what is stranded (on belts no turret\'s way reaches, by group with their area), and each turret low or stopped: what it holds, what can reach it (each inserter and its way: the hub, a chest or machine, or a belt with the ammo on the belts upstream and who puts items on them) and what stops it (no feeder, an inserter or belt switched off by its circuit, a filter leaving its ammo out, belts nothing feeds: dry after what is on them). Every turret\'s reach in one line (ammunition that can reach each turret), and per stranded group the belts holding it (most first) and the call that would recover it: pickup {belt, area} when your character stands on that surface, else deconstruct {platform, area, entity_types: the belts} (the hub takes the belts and the items on them; the other belts of ours in that area named), and whether the hub\'s ammunition reaches a turret. feed {reaches, stranded, stranded_groups, stranded_recover [{count, belts, area, other_belts_in_area}], hub_reaches, turrets [{position, holds, reaches, stopped}], lines}. collectors [{position, front, covered_by}], sides [{side, edge_tiles, uncovered, gaps}], turrets [{name, position, range, ammo, feed}]. Read only'}}
  return M
end
