-- (mt274, private: multi-team phase 1) Map and forces setup for a run of several teams, and first contact.
-- Operator actions only (RCON dispatch with operator: true); nothing here is an agent's action or read, and no agent
-- reply carries what it records.
--   mt_setup     one force per team (made if missing): every team at war with every other and with the enemy (no
--                cease-fire, no friendship), chart not shared; each team's spawn on every planet surface (surfaces
--                made for planets that have none yet, with every team's spawn as a starting point before their
--                first chunks are made). Records the teams: contact detection runs from then on.
--   mt_generate  makes the chunks of an area now (resources and nests are placed when a chunk is made).
--   mt_resources clears resources in circles and places patches (ores by tile, oil by well) to exact totals.
--   mt_assign    moves a LuaPlayer into a team's force (a force charts nothing without one, batch266) and, while it
--                is connected, makes it a spectator with no character left behind.
--   mt_check     each team: force, players, spawns, relations, chart share and charted chunks round its spawn.
--   mt_survey    each start and each placed site: resources, water and nests round it.
--   mt_corridor  whether a path between two starts avoids every nest by a margin (a grid walk over the area).
--   mt_contacts  first contacts: the first time a team's chart shows another team's entity (on_chunk_charted), and
--                the first hit between two teams (on_entity_damaged), per ordered pair, with tick, place and what.
return function(api)
  local M = {operator={}}
  local MAX_TEAMS, MAX_PATCHES, MAX_CONTACTS = 8, 200, 200
  local function st()
    local s = api.state()
    s.mt = s.mt or {}
    return s.mt
  end
  local function pos_of(v, what)
    if type(v) == 'table' and v.x == nil and type(v[1]) == 'number' then v = {x=v[1], y=v[2]} end
    assert(type(v) == 'table' and type(v.x) == 'number' and type(v.y) == 'number', what .. ' needs x and y')
    return {x=v.x, y=v.y}
  end
  local function surface_of(name)
    local s = game.get_surface(name or 'nauvis')
    assert(s, 'no surface ' .. tostring(name))
    return s
  end
  local function team_names()
    local out = {}
    for _, t in ipairs(st().order or {}) do out[#out+1] = t end
    return out
  end

  function M.operator.mt_setup(a)
    assert(type(a.teams) == 'table' and #a.teams >= 2 and #a.teams <= MAX_TEAMS, 'teams: 2..' .. MAX_TEAMS .. ' {name, spawns}')
    local s, made, order = st(), {}, {}
    local planets = {}
    for name in pairs(game.planets) do planets[#planets+1] = name end
    table.sort(planets)
    -- the forces
    for _, t in ipairs(a.teams) do
      assert(type(t.name) == 'string' and t.name:match('^[%w_-]+$') and t.name ~= 'player' and t.name ~= 'enemy' and t.name ~= 'neutral',
        'team name: letters, digits, _ or -, not player, enemy or neutral')
      assert(type(t.spawns) == 'table' and t.spawns.nauvis, 'team ' .. t.name .. ': spawns {nauvis = {x, y}, ...}')
      if not game.forces[t.name] then game.create_force(t.name); made[#made+1] = t.name end
      order[#order+1] = t.name
    end
    -- surfaces for planets that have none: every team's spawn there a starting point, set before any chunk is made
    local surfaces = {}
    for _, planet in ipairs(planets) do
      local pl = game.planets[planet]
      local surface = pl.surface
      local points = {}
      for _, t in ipairs(a.teams) do if t.spawns[planet] then points[#points+1] = pos_of(t.spawns[planet], t.name .. ' spawn on ' .. planet) end end
      if not surface and #points > 0 and a.create_surfaces ~= false then
        surface = pl.create_surface()
        local mgs = surface.map_gen_settings
        mgs.starting_points = points
        surface.map_gen_settings = mgs
        surfaces[#surfaces+1] = planet .. ' (made, ' .. #points .. ' starting points)'
      elseif surface then
        surfaces[#surfaces+1] = planet .. ' (there)'
      end
    end
    -- relations, chart share and spawns
    for _, t in ipairs(a.teams) do
      local f = game.forces[t.name]
      for _, u in ipairs(a.teams) do
        if u.name ~= t.name then f.set_cease_fire(u.name, false); f.set_friend(u.name, false) end
      end
      f.set_cease_fire('enemy', false); f.set_friend('enemy', false)
      f.set_cease_fire('player', false); f.set_friend('player', false)
      f.share_chart = false
      for planet, p in pairs(t.spawns) do
        local surface = game.planets[planet] and game.planets[planet].surface or game.get_surface(planet)
        if surface then f.set_spawn_position(pos_of(p, t.name .. ' spawn on ' .. planet), surface) end
      end
    end
    s.order = order
    s.teams = {}
    for _, n in ipairs(order) do s.teams[n] = true end
    s.spawns = {}
    for _, t in ipairs(a.teams) do s.spawns[t.name] = t.spawns end
    s.contacts = s.contacts or {}
    s.first = s.first or {}
    s.set_tick = game.tick
    return {teams=order, made=made, surfaces=surfaces}
  end

  -- Chunks of an area made now (blocks the tick until they are).
  function M.operator.mt_generate(a)
    local surface = surface_of(a.surface)
    local c = pos_of(a.position, 'position')
    local r = a.radius
    assert(type(r) == 'number' and r >= 1 and r <= 64, 'radius: 1..64 chunks round position')
    surface.request_to_generate_chunks(c, r)
    surface.force_generate_chunk_requests()
    return {surface=surface.name, chunks=(2 * r + 1) ^ 2}
  end

  -- Clears resources in circles, then places patches. A patch's amount is its total: ore tiles share it, richer at
  -- the centre (1 at the middle, 0.4 at the rim); water or other blocked tiles are left out and the rest share it.
  -- Oil: wells in rings of 7 tiles, each well the total / count.
  function M.operator.mt_resources(a)
    local surface = surface_of(a.surface)
    local cleared, placed = 0, {}
    for _, c in ipairs(a.clear or {}) do
      local p = pos_of(c, 'clear')
      for _, e in ipairs(surface.find_entities_filtered{position=p, radius=c.r, type='resource', name=c.names}) do e.destroy(); cleared = cleared + 1 end
    end
    assert(#(a.patches or {}) <= MAX_PATCHES, 'patches: at most ' .. MAX_PATCHES)
    local s = st()
    s.patches = s.patches or {}
    -- A patch's centre moves (rings of 8 tiles, up to max_shift) to the nearest spot where its disc is dry land with no
    -- resource yet: 25 points across the disc (oil: its wells' ring) must take the resource.
    local function fits(name, c, r)
      for i = -2, 2 do
        for j = -2, 2 do
          local q = {x=c.x + i * r / 2.5, y=c.y + j * r / 2.5}
          if (q.x - c.x) ^ 2 + (q.y - c.y) ^ 2 <= r * r and not surface.can_place_entity{name=name, position=q} then return false end
        end
      end
      return true
    end
    local function spot(name, c, r, max)
      if fits(name, c, r) then return c, 0 end
      for d = 8, max, 8 do
        local n = math.max(8, math.floor(2 * math.pi * d / 8))
        for k = 0, n - 1 do
          local q = {x=math.floor(c.x + d * math.cos(2 * math.pi * k / n)) + 0.5, y=math.floor(c.y + d * math.sin(2 * math.pi * k / n)) + 0.5}
          if fits(name, q, r) then return q, d end
        end
      end
      return c, nil
    end
    local function place(patch)
      local p = pos_of(patch, 'patch')
      assert(prototypes.entity[patch.name] and prototypes.entity[patch.name].type == 'resource', 'not a resource: ' .. tostring(patch.name))
      local shift
      p, shift = spot(patch.name, p, patch.wells and 10 or patch.r, patch.max_shift or 0)
      local row = {name=patch.name, site=patch.site, x=p.x, y=p.y, amount=0, tiles=0, shifted=shift, no_dry_spot=shift == nil or nil,
        slid=patch.slid}
      if patch.wells then
        local n, ring, k = patch.wells, 0, 0
        local spots = {}
        local tries = 0
        while #spots < n and tries < 200 do
          tries = tries + 1
          local ang = k * 2 * math.pi / math.max(1, ring * 6)
          local q = {x=math.floor(p.x + ring * 7 * math.cos(ang)) + 0.5, y=math.floor(p.y + ring * 7 * math.sin(ang)) + 0.5}
          if surface.can_place_entity{name=patch.name, position=q} then spots[#spots+1] = q end
          k = k + 1
          if ring == 0 or k >= ring * 6 then ring, k = ring + 1, 0 end
        end
        local each = math.floor(patch.amount / math.max(1, #spots))
        for _, q in ipairs(spots) do
          surface.create_entity{name=patch.name, position=q, amount=each}
          row.amount, row.tiles = row.amount + each, row.tiles + 1
        end
      else
        local r = patch.r
        local cells, weight = {}, 0
        for x = math.floor(p.x - r), math.ceil(p.x + r) do
          for y = math.floor(p.y - r), math.ceil(p.y + r) do
            local q = {x=x + 0.5, y=y + 0.5}
            local d = math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
            if d <= r and surface.can_place_entity{name=patch.name, position=q} then
              local w = 1 - 0.6 * d / r
              cells[#cells+1] = {q, w}; weight = weight + w
            end
          end
        end
        -- each tile its share rounded down; the rest to the richest tile, so the total is the patch's amount
        local counts, sum, top = {}, 0, 1
        for i, c in ipairs(cells) do
          counts[i] = math.max(1, math.floor(patch.amount * c[2] / weight))
          sum = sum + counts[i]
          if c[2] > cells[top][2] then top = i end
        end
        if #cells > 0 and sum < patch.amount then counts[top] = counts[top] + patch.amount - sum end
        for i, c in ipairs(cells) do
          surface.create_entity{name=patch.name, position=c[1], amount=counts[i]}
          row.amount, row.tiles = row.amount + counts[i], row.tiles + 1
        end
      end
      placed[#placed+1] = row
      if #s.patches < MAX_PATCHES then s.patches[#s.patches+1] = row end
    end
    for _, patch in ipairs(a.patches or {}) do place(patch) end
    -- (mt275) a shared site between two starts slides as a whole along its axis (the line as far from both starts:
    -- 16-tile steps either way, up to slide) to the first centre where every patch fits at its offset; then each patch
    -- moves at most max_shift (48) from there. With no such centre in reach, the patches move one by one as above.
    for _, site in ipairs(a.sites or {}) do
      local c, ax = pos_of(site, 'site'), pos_of(site.axis, 'axis')
      local found
      for k = 0, math.floor((site.slide or 0) / 16) * 2 do
        local d = (k % 2 == 1 and 1 or -1) * math.ceil(k / 2) * 16
        local q = {x=c.x + d * ax.x, y=c.y + d * ax.y}
        local all = true
        for _, sp in ipairs(site.patches) do
          if not fits(sp.name, {x=q.x + sp.dx, y=q.y + sp.dy}, sp.wells and 10 or sp.r) then all = false; break end
        end
        if all then found = {q, d}; break end
      end
      for _, sp in ipairs(site.patches) do
        local patch = {}
        for k2, v in pairs(sp) do patch[k2] = v end
        patch.site = site.name
        if found then
          patch.x, patch.y = math.floor(found[1].x + sp.dx) + 0.5, math.floor(found[1].y + sp.dy) + 0.5
          patch.max_shift, patch.slid = sp.near_shift or 48, found[2]
        else
          patch.x, patch.y = math.floor(c.x + sp.dx) + 0.5, math.floor(c.y + sp.dy) + 0.5
          patch.max_shift = sp.max_shift or 288
        end
        place(patch)
      end
    end
    return {surface=surface.name, cleared=cleared, placed=placed}
  end

  function M.operator.mt_assign(a)
    local s = st()
    assert(s.teams and s.teams[a.team], 'not a team: ' .. tostring(a.team))
    local p = game.get_player(a.player)
    assert(p, 'no player ' .. tostring(a.player) .. ' (a client joins once with that name)')
    local was = p.force.name
    local spectator = false
    -- the spectator switch first: on the iMac test (mt275) a connected player's force set before it read player after
    if p.connected then
      local c = p.character
      p.set_controller{type=defines.controllers.spectator}
      if c and c.valid then c.destroy() end
      spectator = true
    end
    p.force = a.team
    s.players = s.players or {}
    s.players[p.name] = a.team
    return {player=p.name, force=p.force.name, was=was, connected=p.connected, spectator=spectator}
  end

  local function charted_round(f, surface, c, r)
    local n, of = 0, 0
    local cx, cy = math.floor(c.x / 32), math.floor(c.y / 32)
    for x = cx - r, cx + r do
      for y = cy - r, cy + r do
        of = of + 1
        if f.is_chunk_charted(surface, {x=x, y=y}) then n = n + 1 end
      end
    end
    return n, of
  end
  function M.operator.mt_check(a)
    local s = st()
    local out = {}
    for _, name in ipairs(team_names()) do
      local f = game.forces[name]
      local row = {team=name, exists=f ~= nil}
      if f then
        local players = {}
        for _, p in pairs(f.players) do players[#players+1] = p.name .. (p.connected and ' (connected)' or '') end
        row.players = players
        row.share_chart = f.share_chart
        local rel = {}
        for _, other in ipairs(team_names()) do
          if other ~= name then rel[#rel+1] = string.format('%s cease_fire=%s friend=%s', other, tostring(f.get_cease_fire(other)), tostring(f.get_friend(other))) end
        end
        rel[#rel+1] = string.format('enemy cease_fire=%s', tostring(f.get_cease_fire('enemy')))
        row.relations = rel
        local spawns = {}
        for _, surface in pairs(game.surfaces) do
          if not surface.platform then
            local p = f.get_spawn_position(surface)
            spawns[#spawns+1] = string.format('%s (%g,%g)', surface.name, p.x, p.y)
          end
        end
        table.sort(spawns)
        row.spawns = spawns
        local home = s.spawns and s.spawns[name] and s.spawns[name].nauvis
        if home then
          local n, of = charted_round(f, game.surfaces.nauvis, pos_of(home, 'spawn'), a.chunks or 5)
          row.charted_round_spawn = n .. ' of ' .. of
        end
        local researched = 0
        for _, t in pairs(f.technologies) do if t.researched then researched = researched + 1 end end
        row.researched = researched
      end
      out[#out+1] = row
    end
    return {teams=out, contacts=#(s.contacts or {})}
  end

  -- What lies round a point: resources by name (tiles or wells, amount), water tiles, nests.
  local function round(surface, c, r, nest_r)
    local res = {}
    for _, e in ipairs(surface.find_entities_filtered{position=c, radius=r, type='resource'}) do
      local x = res[e.name] or {n=0, amount=0}
      x.n = x.n + 1; x.amount = x.amount + e.amount
      res[e.name] = x
    end
    local rows = {}
    for n, x in pairs(res) do rows[#rows+1] = string.format('%s %d (%d)', n, x.amount, x.n) end
    table.sort(rows)
    local water = surface.count_tiles_filtered{position=c, radius=r, collision_mask='water_tile'}
    local nests = surface.find_entities_filtered{position=c, radius=nest_r, type='unit-spawner'}
    local near
    for _, e in ipairs(nests) do
      local d = math.sqrt((e.position.x - c.x) ^ 2 + (e.position.y - c.y) ^ 2)
      if not near or d < near then near = d end
    end
    local worms = surface.count_entities_filtered{position=c, radius=nest_r, type='turret', force='enemy'}
    return {resources=rows, water_tiles=water, nests=#nests, worms=worms, nearest_nest=near and math.floor(near + 0.5) or nil}
  end
  function M.operator.mt_survey(a)
    local s = st()
    local surface = surface_of(a.surface)
    local r, nest_r = a.radius or 200, a.nest_radius or 600
    local out = {}
    for _, name in ipairs(team_names()) do
      local sp = s.spawns[name][surface.name]
      if sp then
        local c = pos_of(sp, 'spawn')
        local row = round(surface, c, r, nest_r)
        row.team, row.at = name, string.format('(%g,%g)', c.x, c.y)
        out[#out+1] = row
      end
    end
    local sites = {}
    for _, site in ipairs(a.sites or {}) do
      local c = pos_of(site, 'site')
      local row = round(surface, c, site.r or 80, site.nest_r or 120)
      row.site, row.at = site.name, string.format('(%g,%g)', c.x, c.y)
      sites[#sites+1] = row
    end
    return {surface=surface.name, radius=r, nest_radius=nest_r, starts=out, sites=sites}
  end

  -- A walk over a grid of cells (cell tiles a side) in the box round the starts plus margin: a cell is blocked when a
  -- nest lies within margin_nest tiles of its centre. Per pair of starts: whether an open path joins them, and the
  -- open cells' count. Cells of chunks not made yet count as open (the reply says how many chunks were not made).
  function M.operator.mt_corridor(a)
    local s = st()
    local surface = surface_of(a.surface)
    local cell, near, margin = a.cell or 32, a.nest_margin or 96, a.margin or 400
    local starts = {}
    for _, name in ipairs(team_names()) do starts[#starts+1] = {name=name, p=pos_of(s.spawns[name][surface.name], 'spawn')} end
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, t in ipairs(starts) do x1, y1, x2, y2 = math.min(x1, t.p.x), math.min(y1, t.p.y), math.max(x2, t.p.x), math.max(y2, t.p.y) end
    x1, y1, x2, y2 = x1 - margin, y1 - margin, x2 + margin, y2 + margin
    local w, h = math.ceil((x2 - x1) / cell), math.ceil((y2 - y1) / cell)
    local blocked = {}
    local nests = surface.find_entities_filtered{area={{x1 - near, y1 - near}, {x2 + near, y2 + near}}, type='unit-spawner'}
    local k = math.ceil(near / cell)
    local function block(px, py)
      local cx, cy = math.floor((px - x1) / cell), math.floor((py - y1) / cell)
      for dx = -k, k do
        for dy = -k, k do
          local gx, gy = cx + dx, cy + dy
          if gx >= 0 and gy >= 0 and gx < w and gy < h then
            local mx, my = x1 + (gx + 0.5) * cell, y1 + (gy + 0.5) * cell
            if (mx - px) ^ 2 + (my - py) ^ 2 <= near * near then blocked[gy * w + gx] = true end
          end
        end
      end
    end
    for _, e in ipairs(nests) do block(e.position.x, e.position.y) end
    -- (water: true) a cell mostly water is blocked too: no one walks across it
    local wet = 0
    if a.water then
      for gx = 0, w - 1 do
        for gy = 0, h - 1 do
          local i = gy * w + gx
          if not blocked[i] then
            local lx, ly = x1 + gx * cell, y1 + gy * cell
            if surface.count_tiles_filtered{area={{lx, ly}, {lx + cell, ly + cell}}, collision_mask='water_tile'} * 2 > cell * cell then blocked[i] = true; wet = wet + 1 end
          end
        end
      end
    end
    local missing = 0
    for gx = 0, w - 1, math.max(1, math.floor(32 / cell)) do
      for gy = 0, h - 1, math.max(1, math.floor(32 / cell)) do
        if not surface.is_chunk_generated{x=math.floor((x1 + gx * cell) / 32), y=math.floor((y1 + gy * cell) / 32)} then missing = missing + 1 end
      end
    end
    local function walk(from)
      local seen, queue, head = {}, {}, 1
      local sx, sy = math.floor((from.x - x1) / cell), math.floor((from.y - y1) / cell)
      local start = sy * w + sx
      seen[start] = -1; queue[1] = start
      while head <= #queue do
        local i = queue[head]; head = head + 1
        local gx, gy = i % w, math.floor(i / w)
        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
          local nx, ny = gx + d[1], gy + d[2]
          if nx >= 0 and ny >= 0 and nx < w and ny < h then
            local j = ny * w + nx
            if not seen[j] and not blocked[j] then seen[j] = i; queue[#queue+1] = j end
          end
        end
      end
      return seen, #queue
    end
    local pairs_out = {}
    for i, t in ipairs(starts) do
      local seen, n = walk(t.p)
      for j = i + 1, #starts do
        local u = starts[j]
        local key = math.floor((u.p.y - y1) / cell) * w + math.floor((u.p.x - x1) / cell)
        pairs_out[#pairs_out+1] = string.format('%s-%s: %s (%d open cells reached from %s)', t.name, u.name, seen[key] and 'open path' or 'no open path', n, t.name)
      end
    end
    -- (mt275) close: true picks nests to place (biter spawners of the enemy force) until no pair keeps an open path:
    -- each time on the middle cell of a shortest open path (the cell as far from both its ends' starts as the path
    -- allows), off its starts' biter-free area (keep tiles from every start); place: true places them (a spawner and
    -- a medium worm each). Returns the nests picked.
    local picked = {}
    if a.close then
      local keep = a.keep or 300
      for _ = 1, a.max_nests or 60 do
        local cut
        for i, t in ipairs(starts) do
          local seen = walk(t.p)
          for j = i + 1, #starts do
            local u = starts[j]
            local key = math.floor((u.p.y - y1) / cell) * w + math.floor((u.p.x - x1) / cell)
            if seen[key] and not cut then
              local path, c = {}, key
              while c and c ~= -1 do path[#path+1] = c; c = seen[c] end
              local best, bd
              for _, cc in ipairs(path) do
                local mx, my = x1 + (cc % w + 0.5) * cell, y1 + (math.floor(cc / w) + 0.5) * cell
                local d = math.huge
                for _, st0 in ipairs(starts) do d = math.min(d, math.sqrt((mx - st0.p.x) ^ 2 + (my - st0.p.y) ^ 2)) end
                if d >= keep and (not bd or d > bd) and surface.count_tiles_filtered{position={mx, my}, radius=6, collision_mask='water_tile'} == 0 then best, bd = {mx, my}, d end
              end
              cut = best or false
              if not best then pairs_out[#pairs_out+1] = string.format('%s-%s: no dry cell %d tiles from every start on its open path', t.name, u.name, keep) end
            end
          end
        end
        if not cut then break end
        picked[#picked+1] = cut
        block(cut[1], cut[2])
      end
      if a.place then
        for i, q in ipairs(picked) do
          local at = surface.find_non_colliding_position('biter-spawner', q, 24, 1)
          if at then
            surface.create_entity{name=i % 2 == 0 and 'spitter-spawner' or 'biter-spawner', position=at, force='enemy'}
            local wpos = surface.find_non_colliding_position('medium-worm-turret', {at.x + 6, at.y}, 16, 1)
            if wpos then surface.create_entity{name='medium-worm-turret', position=wpos, force='enemy'} end
            q[3] = true
          end
        end
      end
    end
    local nb = 0
    for _ in pairs(blocked) do nb = nb + 1 end
    local rows = {}
    for _, q in ipairs(picked) do rows[#rows+1] = string.format('(%d,%d)%s', q[1], q[2], q[3] and ' placed' or '') end
    if a.close then
      local after = {}
      for i, t in ipairs(starts) do
        local seen = walk(t.p)
        for j = i + 1, #starts do
          local u = starts[j]
          local key = math.floor((u.p.y - y1) / cell) * w + math.floor((u.p.x - x1) / cell)
          after[#after+1] = string.format('%s-%s: %s', t.name, u.name, seen[key] and 'open path' or 'no open path')
        end
      end
      rows[#rows+1] = 'after: ' .. table.concat(after, '; ')
    end
    return {surface=surface.name, box=string.format('(%d,%d)-(%d,%d)', x1, y1, x2, y2), cell=cell, nest_margin=near, nests=#nests, picked=#picked > 0 and rows or nil,
      cells=w * h, blocked=nb, water_cells=wet, chunks_not_made=missing, pairs=pairs_out}
  end

  -- First contact. A record: tick, kind (chart or shot), the two teams, surface, position and what.
  local function record(rec)
    local s = st()
    s.contacts = s.contacts or {}
    if #s.contacts >= MAX_CONTACTS then return end
    rec.tick = game.tick
    s.contacts[#s.contacts+1] = rec
    log('mt contact: ' .. helpers.table_to_json(rec))
    pcall(helpers.write_file, 'pog/mt-contacts.jsonl', helpers.table_to_json(rec) .. '\n', true, 0)
  end
  -- (mt275) the chart hook's cost: mt_cost {reset?} writes the events counted and their total time to the server log
  -- (a LuaProfiler prints only there or by rcon.print), then starts again with reset
  local cost = {n=0, searched=0}
  local function charted(event)
    local s = st()
    local teams = s.teams
    if not teams then return end
    local f = event.force
    if not (f and teams[f.name]) then return end
    local first = s.first
    local others = {}
    for _, n in ipairs(s.order) do
      if n ~= f.name and not first['chart ' .. f.name .. '>' .. n] then others[#others+1] = n end
    end
    if #others == 0 then return end
    local surface = game.get_surface(event.surface_index)
    if not surface then return end
    cost.searched = cost.searched + 1
    for _, e in ipairs(surface.find_entities_filtered{area=event.area, force=others, limit=16}) do
      local o = e.force.name
      local key = 'chart ' .. f.name .. '>' .. o
      if not first[key] then
        first[key] = game.tick
        record({kind='chart', team=f.name, other=o, surface=surface.name, x=e.position.x, y=e.position.y, entity=e.name})
      end
    end
  end
  function M.on_charted(event)
    if not cost.acc then return charted(event) end
    local p = helpers.create_profiler()
    charted(event)
    p.stop()
    cost.acc.add(p)
    cost.n = cost.n + 1
  end
  function M.operator.mt_cost(a)
    local n, searched = cost.n, cost.searched
    if cost.acc then log({'', 'mt chart cost: ', n, ' events, ', searched, ' searched, total ', cost.acc}) end
    if a.reset ~= false then cost = {n=0, searched=0, acc=helpers.create_profiler(true)} end
    return {events=n, searched=searched, logged=n > 0, timing=cost.acc ~= nil}
  end
  function M.on_damaged(event)
    local s = st()
    local teams = s.teams
    if not teams then return end
    local by, e = event.force, event.entity
    if not (by and teams[by.name] and e and e.valid) then return end
    local victim = e.force.name
    if victim == by.name or not teams[victim] then return end
    local key = 'shot ' .. by.name .. '>' .. victim
    if s.first[key] then return end
    s.first[key] = game.tick
    local cause = event.cause
    record({kind='shot', team=by.name, other=victim, surface=e.surface.name, x=e.position.x, y=e.position.y, entity=e.name,
      cause=cause and cause.valid and cause.name or nil, damage=event.final_damage_amount})
  end
  function M.operator.mt_contacts(a)
    local s = st()
    local out = {}
    for _, c in ipairs(s.contacts or {}) do
      if not a.since or c.tick > a.since then out[#out+1] = c end
    end
    return {teams=team_names(), contacts=out, since_setup_tick=s.set_tick}
  end
  return M
end
