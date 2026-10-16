-- platform_plan {platform}: a platform as planned, built and ghosts together (Sol 01:52: a 270-tile solar island no
-- foundation joined, and two belt crossings in the ammo loops, found by his own graph audit of exported blueprints).
-- Facts read from the surface: foundation tiles built and planned (tile ghosts) in 4-joined groups, the one with the hub
-- first, every other group an island with its size, a tile of it, how many of its tiles are ghosts and how many entity
-- ghosts stand on it; belts (transport belts, undergrounds, splitters, built and ghost) as a graph of the tile each one
-- moves its items to: closed loops (a cycle no belt leaves), belts that run head on into another (items stop), and
-- belts that feed another's side (side-loads), each with whether a ghost is in it. Read only.
return function(api)
  local M = {}
  local MAX_TILES, MAX_BELTS, LIST = 40000, 8000, 8
  local VEC = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Numeric tile keys (a string key a tile cost 43 ms for 2345 tiles in the container, a number 5 ms).
  local function k(x, y) return (x + 32768) * 65536 + (y + 32768) end
  local function at(x, y) return string.format('(%g,%g)', x, y) end

  local function foundation(s, hub)
    local built = try(function() return s.find_tiles_filtered{name='space-platform-foundation', limit=MAX_TILES} end) or {}
    local ghosts = try(function() return s.find_entities_filtered{type='tile-ghost', ghost_name='space-platform-foundation', limit=MAX_TILES} end) or {}
    local tiles, n = {}, 0
    for _, t in ipairs(built) do local p = t.position; tiles[k(p.x, p.y)] = {x=p.x, y=p.y}; n = n + 1 end
    for _, g in ipairs(ghosts) do
      local x, y = math.floor(g.position.x), math.floor(g.position.y)
      if not tiles[k(x, y)] then tiles[k(x, y)] = {x=x, y=y, ghost=true}; n = n + 1 end
    end
    local hx, hy = hub and math.floor(hub.position.x) or 0, hub and math.floor(hub.position.y) or 0
    local seen, groups = {}, {}
    for key, t in pairs(tiles) do
      if not seen[key] then
        local g = {size=0, ghosts=0, first=t, hub=false}
        local stack = {t}
        seen[key] = true
        while #stack > 0 do
          local c = table.remove(stack)
          g.size = g.size + 1
          if c.ghost then g.ghosts = g.ghosts + 1 end
          if c.x == hx and c.y == hy then g.hub = true end
          if c.x < g.first.x or (c.x == g.first.x and c.y < g.first.y) then g.first = c end
          for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
            local nk = k(c.x + d[1], c.y + d[2])
            local nt = tiles[nk]
            if nt and not seen[nk] then seen[nk] = true; stack[#stack+1] = nt end
          end
        end
        groups[#groups+1] = g
      end
    end
    table.sort(groups, function(a, b) if a.hub ~= b.hub then return a.hub end return a.size > b.size end)
    return groups, n, #built >= MAX_TILES or #ghosts >= MAX_TILES
  end

  local function belts(s, force)
    local list = try(function() return s.find_entities_filtered{type={'transport-belt', 'underground-belt', 'splitter'}, force=force, limit=MAX_BELTS} end) or {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='entity-ghost', ghost_type={'transport-belt', 'underground-belt', 'splitter'}, force=force, limit=MAX_BELTS} end) or {}) do
      list[#list+1] = g
    end
    local node = {}  -- tile -> {e, name, ghost, dir, x, y, out = {tiles}, under}
    for _, e in ipairs(list) do
      local ghost = e.type == 'entity-ghost'
      local t = ghost and e.ghost_type or e.type
      local name = ghost and e.ghost_name or e.name
      local dir = e.direction or 0
      local v = VEC[dir]
      if v and BELT[t] then
        local cx, cy = e.position.x, e.position.y
        local cells = {}
        if t == 'splitter' then
          -- two tiles side by side across its direction
          local px, py = -v[2] * 0.5, v[1] * 0.5
          cells = {{cx + px, cy + py}, {cx - px, cy - py}}
        else cells = {{cx, cy}} end
        local under = t == 'underground-belt' and (try(function() return e.belt_to_ground_type end) or (ghost and try(function() return e.ghost_prototype and nil end)))
        local partner = t == 'underground-belt' and not ghost and try(function() local n = e.neighbours; return n and n.valid and n or nil end)
        for _, c in ipairs(cells) do
          local x, y = math.floor(c[1]), math.floor(c[2])
          local n = {name=name, ghost=ghost, dir=dir, x=x, y=y, type=t, under=under}
          if t == 'underground-belt' and under == 'input' then
            n.out = partner and {k(math.floor(partner.position.x), math.floor(partner.position.y))} or {}
            n.open = not partner
          else
            n.out = {k(x + v[1], y + v[2])}
          end
          node[k(x, y)] = n
        end
      end
    end
    return node, #list
  end

  local function label(n) return (n.ghost and 'ghost of ' or '') .. n.name .. ' ' .. at(n.x + 0.5, n.y + 0.5) end

  local function audit_belts(node)
    local head, side, loops = {}, {}, {}
    local pairs_head = {}
    -- What feeds each belt: from behind (straight on), or from a side.
    local behind, sides = {}, {}
    for key, n in pairs(node) do
      for _, o in ipairs(n.out) do
        local m = node[o]
        if m and m ~= n and not (n.type == 'underground-belt' and n.under == 'input') then
          if m.dir == n.dir then behind[o] = true
          elseif (m.dir - n.dir) % 8 == 4 then sides[o] = (sides[o] or 0) + 1 end
        end
      end
    end
    for key, n in pairs(node) do
      for _, o in ipairs(n.out) do
        local m = node[o]
        if m and m ~= n and not (n.type == 'underground-belt' and n.under == 'input') then
          -- An underground output takes items from the tile behind it only; an input's mouth faces the way it flows.
          local opposite = (m.dir - n.dir) % 16 == 8
          local across = (m.dir - n.dir) % 8 == 4
          if opposite and m.type ~= 'underground-belt' then
            local a, b = key, o
            if a > b then a, b = b, a end
            if not pairs_head[a .. ':' .. b] then
              pairs_head[a .. ':' .. b] = true
              head[#head+1] = label(n) .. ' and ' .. label(m) .. ' run head on into each other'
            end
          elseif across and m.type == 'transport-belt' and (behind[o] or (sides[o] or 0) > 1) then
            -- One belt coming in from a side alone makes a curve; with a belt behind it (or both sides) it is a side-load.
            side[#side+1] = label(n) .. ' feeds the side of ' .. label(m)
          end
        end
      end
    end
    -- Closed loops: strongly connected groups of 2+ belts that no belt leaves.
    local index, low, onstack, st, count = {}, {}, {}, {}, 0
    local comps = {}
    local function strong(v)
      count = count + 1; index[v] = count; low[v] = count; st[#st+1] = v; onstack[v] = true
      for _, w in ipairs(node[v].out) do
        if node[w] then
          if not index[w] then strong(w); low[v] = math.min(low[v], low[w])
          elseif onstack[w] then low[v] = math.min(low[v], index[w]) end
        end
      end
      if low[v] == index[v] then
        local comp = {}
        repeat local w = table.remove(st); onstack[w] = nil; comp[#comp+1] = w until w == v
        if #comp > 1 then comps[#comps+1] = comp end
      end
    end
    local keys = {}
    for key in pairs(node) do keys[#keys+1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do if not index[key] and count < 20000 then pcall(strong, key) end end
    for _, comp in ipairs(comps) do
      -- Two belts facing each other are named head on, not a loop.
      local pair2 = #comp == 2 and (node[comp[1]].dir - node[comp[2]].dir) % 16 == 8
      if pair2 then goto continue end
      local set, exits, ghosts = {}, 0, 0
      for _, key in ipairs(comp) do set[key] = true end
      for _, key in ipairs(comp) do
        local n = node[key]
        if n.ghost then ghosts = ghosts + 1 end
        for _, o in ipairs(n.out) do if not set[o] then exits = exits + 1 end end
      end
      local first = node[comp[1]]
      for _, key in ipairs(comp) do local n = node[key]; if n.x < first.x or (n.x == first.x and n.y < first.y) then first = n end end
      loops[#loops+1] = {belts=#comp, ghosts=ghosts, exits=exits, first=label(first),
        line=string.format('%d belts in a loop from %s%s, %s', #comp, label(first), ghosts > 0 and string.format(' (%d of them ghosts)', ghosts) or '',
          exits == 0 and 'no belt leaves it' or string.format('%d way%s out', exits, exits == 1 and '' or 's'))}
      ::continue::
    end
    table.sort(loops, function(a, b) return a.belts > b.belts end)
    table.sort(head); table.sort(side)
    return head, side, loops
  end

  function M.read(p, a)
    assert(type(a.platform) == 'string', 'platform is required (a platform name)')
    local pl = api.platform(p, a.platform)
    local s, hub = pl.surface, pl.hub
    local groups, ntiles, capped = foundation(s, hub and hub.valid and hub or nil)
    local islands = {}
    for i, g in ipairs(groups) do
      if not g.hub then
        local on = try(function() return s.count_entities_filtered{type='entity-ghost', area={left_top={x=g.first.x - 64, y=g.first.y - 64}, right_bottom={x=g.first.x + 64, y=g.first.y + 64}}} end)
        islands[#islands+1] = {size=g.size, ghost_tiles=g.ghosts, tile=at(g.first.x, g.first.y),
          line=string.format('%d tiles from %s (%d of them ghosts) join no foundation with the hub', g.size, at(g.first.x, g.first.y), g.ghosts)}
      end
    end
    local node, nbelts = belts(s, pl.force)
    local head, side, loops = audit_belts(node)
    local main = groups[1] and groups[1].hub and groups[1] or nil
    local lines = {string.format('foundation: %d tiles%s; the hub\'s group %d tiles (%d ghosts); %d island%s', ntiles, capped and ' (the first ' .. MAX_TILES .. ' read)' or '',
      main and main.size or 0, main and main.ghosts or 0, #islands, #islands == 1 and '' or 's')}
    for i, x in ipairs(islands) do if i <= LIST then lines[#lines+1] = 'island: ' .. x.line end end
    lines[#lines+1] = string.format('belts: %d (built and ghosts); %d loop%s, %d head on, %d side-load%s', nbelts, #loops, #loops == 1 and '' or 's', #head, #side, #side == 1 and '' or 's')
    for i, l in ipairs(loops) do if i <= LIST then lines[#lines+1] = 'loop: ' .. l.line end end
    for i, h in ipairs(head) do if i <= LIST then lines[#lines+1] = 'head on: ' .. h end end
    for i, x in ipairs(side) do if i <= LIST then lines[#lines+1] = 'side-load: ' .. x end end
    return {platform=pl.name, foundation_tiles=ntiles, hub_group=main and main.size or nil, islands=islands, belts=nbelts, loops=loops,
      head_on=#head > 0 and head or nil, side_loads=#side > 0 and side or nil, lines=lines}
  end
  M.schema = {platform_plan = {platform='platform name',
    returns='a platform as planned, built and ghosts together (read only): foundation_tiles (built and tile ghosts), hub_group (the 4-joined tiles with the hub), islands [{size, ghost_tiles, tile, line}] (groups no foundation joins with the hub), belts (transport belts, undergrounds and splitters, built and ghosts), loops [{belts, ghosts, exits, first, line}] (belts whose items come round again; exits 0: no belt leaves it), head_on (a belt moving its items into one facing it), side_loads (a belt feeding the side of another), lines'}}
  return M
end
