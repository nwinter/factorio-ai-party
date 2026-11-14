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
--                the first hit between two teams (on_entity_damaged), per ordered pair, with tick, place and what; the
--                rules sent (mt_rules) per team.
--   mt_rules     (mt276 G) the rules of contact, sent when the operator chooses (Nick d27 10:45: first let the teams
--                work out from the harness's own facts that others exist): one operator tell to every agent of each
--                team named, the tick kept per team.
--   mt_chat_scrub (mt277) drops the game's join and leave lines (players notices) from the harness chat: the setup's
--                team accounts (mt-red, ...) joined once each, and every agent's chat would show them. players.lua
--                writes none on a map with teams set up (tools/mt/start-mt.sh runs this before agents launch).
--   mt_force_move (mt302) moves a force's entities on a surface to another force, never a cargo pod (a 2.1.24 crash).
-- (mt276 G) Each first contact also reaches the agents it concerns as a fact line (api.on_contact; runtime.lua): the
-- team whose chart showed the other's entity; for a hit, the team hit (waking) and the team whose entity hit.
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
    if api.on_contact then pcall(api.on_contact, rec) end
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
  -- A shipment entering an already-visible chunk is contact too. It charts nothing itself.
  function M.shipment_seen(e)
    local s=st();if game.tick%60~=0 then return end
    for _,t in ipairs(s.order or {}) do
      local f=game.forces[t];local key='chart '..t..'>'..e.force.name
      if t~=e.force.name and not s.first[key] and f.is_chunk_visible(e.surface,{x=math.floor(e.position.x/32),y=math.floor(e.position.y/32)}) then
        s.first[key]=game.tick
        record{kind='chart',team=t,other=e.force.name,surface=e.surface.name,x=e.position.x,y=e.position.y,entity=e.name}
      end
    end
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
    return {teams=team_names(), contacts=out, since_setup_tick=s.set_tick, rules=s.rules}
  end
  function M.operator.mt_rules(a)
    local s = st()
    local list = type(a.teams) == 'table' and a.teams or {a.team}
    assert(#list >= 1, 'teams: the teams to send the rules to (or team)')
    for _, t in ipairs(list) do assert(s.teams and s.teams[t], 'not a team: ' .. tostring(t)) end
    assert(api.tell_team, 'no tell in this runtime')
    s.rules = s.rules or {}
    local out = {}
    for _, t in ipairs(list) do
      local r = api.tell_team(t, a.text, a.summary)
      s.rules[t] = {tick=game.tick, seq=r and r.seq, bytes=#tostring(a.text)}
      out[#out+1] = {team=t, seq=r and r.seq, to=r and r.to}
    end
    return {sent=out, tick=game.tick}
  end
  function M.operator.mt_chat_scrub(a)
    local c = api.state().chat
    local kept, dropped = {}, 0
    for _, m in ipairs(c and c.messages or {}) do
      if m.notice and m.from == 'players' then dropped = dropped + 1 else kept[#kept+1] = m end
    end
    if c then c.messages = kept end
    return {dropped=dropped, kept=#kept}
  end
  -- (mt302) mt_force_move {from=, to=, surface=, area=, keep_pads=}: moves one force's entities on a surface (an area of
  -- it, or all) to another force, the way a bench split or a hand-over does, and never a cargo pod. On 2.1.24 writing a
  -- cargo pod's force while it is bound for the ground (it has no pad, or its pad went) leaves the pod in the surface's
  -- incoming list after it lands: the next pod that lands on the ground there, any force's, crashes the server
  -- (SIGSEGV in CargoUnit::getGroundPosition), and a save made in between carries the fault. Pods keep their force and
  -- land as they would; a pad that moves sends its inbound pods to the ground, which is safe. Characters stay too
  -- (players move by mt_assign), and so do platform hubs (a platform belongs to its force). game.merge_forces was
  -- measured safe. Only the operator's split or hand-over moves
  -- entities between forces; no agent action does.
  function M.operator.mt_force_move(a)
    local from, to = game.forces[a.from or ''], game.forces[a.to or '']
    assert(from, 'from: a force name')
    assert(to, 'to: a force name')
    assert(from ~= to, 'from and to are the same force')
    local surface = surface_of(a.surface)
    local filter = {force=from}
    if a.area ~= nil then
      assert(type(a.area) == 'table', 'area: {{x,y},{x,y}}')
      local p1, p2 = pos_of(a.area[1], 'area[1]'), pos_of(a.area[2], 'area[2]')
      filter.area = {{math.min(p1.x, p2.x), math.min(p1.y, p2.y)}, {math.max(p1.x, p2.x), math.max(p1.y, p2.y)}}
    end
    local out = {moved=0, failed=0, pods_kept=0, characters_kept=0, hubs_kept=0, pads_kept=0, tick=game.tick}
    for _, e in ipairs(surface.find_entities_filtered(filter)) do
      if e.valid then
        local t = e.type
        if t == 'cargo-pod' then out.pods_kept = out.pods_kept + 1
        elseif t == 'character' then out.characters_kept = out.characters_kept + 1
        elseif t == 'space-platform-hub' then out.hubs_kept = out.hubs_kept + 1
        elseif t == 'cargo-landing-pad' and a.keep_pads then out.pads_kept = out.pads_kept + 1
        elseif pcall(function() e.force = to end) then out.moved = out.moved + 1
        else out.failed = out.failed + 1 end
      end
    end
    return out
  end
  -- (mt301, private) The end of the game (the private design doc, Nick d27-d28). Solo edge 1.5; allied edge 1.0 each
  -- member, split by the pact's shares (2 x share, capped by pacts' share_max_score 1.4). The alliance that counts is
  -- the one pacts.lua recorded when the edge-run platform left its last planet. The team's Nauvis home (its cargo
  -- landing pad, with power round it) must stand when the platform arrives, or the arrival does not count. A team
  -- that wipes every other team wins: a wipe is no powered production building for wipe_down_s AND every agent of the
  -- team killed on respawn by another team. It is detected and alerted, never restored; the win waits for the
  -- operator unless wipe_win is 'auto'. An optional deadline ends the run by milestone ranking. The result is frozen
  -- in storage (mt.game.result), written to script-output pog/mt-game-result.json, pog/mt-game.jsonl and the log, and
  -- told to the agents (each team's line names only teams it has had contact with), the feed (a system line) and the
  -- operator (alerts in mt_game; team_views.py shows them).
  --   operator: mt_game {config?, end_by_wipe?, wipe_clear?, end_now?, clear_result?, alerts_since?}, mt_game_tick
  M.game = (function()
    local G = {operator={}}
    local DEFAULTS = {target='solar-system-edge', solo=1.5, home_surface='nauvis', home_radius=64, home_power=true,
      wipe_down_s=600, respawn_window_s=120, wipe_win='confirm', deadline_tick=false, check_s=60}
    local PRODUCTION = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'rocket-silo', 'agricultural-tower'}
    local INNER = {vulcanus=true, fulgora=true, gleba=true}
    local MAX_ARRIVALS, MAX_ALERTS = 50, 200
    -- The race to the edge (proposal, report-mt301.md): each milestone once, at the tick the harness first saw it. A
    -- technology milestone counts only where the game has that technology.
    local MILESTONES = {
      {'automation-science-pack', 'tech'}, {'logistic-science-pack', 'tech'}, {'military-science-pack', 'tech'},
      {'chemical-science-pack', 'tech'}, {'production-science-pack', 'tech'}, {'utility-science-pack', 'tech'},
      {'rocket-silo', 'tech'}, {'first-rocket'}, {'first-platform'}, {'space-science-pack', 'tech'},
      {'first-planet'}, {'second-planet'}, {'third-planet'},
      {'metallurgic-science-pack', 'tech'}, {'electromagnetic-science-pack', 'tech'}, {'agricultural-science-pack', 'tech'},
      {'aquilo'}, {'cryogenic-science-pack', 'tech'}, {'stellar-discovery-solar-system-edge', 'tech'},
      {'edge-run'}, {'edge'}}
    G.MILESTONES = MILESTONES
    local function on() local m = api.state().mt; return m and m.teams and m.order and m or nil end
    local function gs()
      local m = st()
      m.game = m.game or {config={}, teams={}, arrivals={}, alerts={}, at_target={}, alert_seq=0}
      return m.game
    end
    local function cfg(k)
      local v = gs().config[k]
      if v ~= nil then return v end
      return DEFAULTS[k]
    end
    local function rec_of(t)
      local g = gs()
      g.teams[t] = g.teams[t] or {milestones={}, planets={}, kills={}}
      return g.teams[t]
    end
    local function pacts() return api.pacts and api.pacts() or nil end
    local function contacted(a, b) local p = pacts(); return a == b or (p ~= nil and p.contacted(a, b)) end
    local function words(name) return (tostring(name):gsub('-', ' ')) end
    local function emit(rec, file)
      pcall(log, 'mt game: ' .. helpers.table_to_json(rec))
      pcall(helpers.write_file, 'pog/mt-game.jsonl', helpers.table_to_json(rec) .. '\n', true, 0)
      if file then pcall(helpers.write_file, 'pog/' .. file, helpers.table_to_json(rec), false, 0) end
    end
    local function alert(kind, team, text, extra)
      local g = gs()
      g.alert_seq = g.alert_seq + 1
      local a = {seq=g.alert_seq, tick=game.tick, kind=kind, team=team, text=text}
      for k, v in pairs(extra or {}) do a[k] = v end
      g.alerts[#g.alerts+1] = a
      while #g.alerts > MAX_ALERTS do table.remove(g.alerts, 1) end
      emit({alert=a})
      return a
    end
    local function fact(t, text) if api.fact then pcall(api.fact, t, text, true) end end
    local function platforms(f)
      local list = {}
      for _, pl in pairs(f and f.platforms or {}) do if pl.valid then list[#list+1] = pl end end
      return list
    end

    -- Milestones: a few reads per team (technologies by name, rockets, its platforms).
    function G.observe(t, tick)
      local f = game.forces[t]
      if not f then return end
      local r = rec_of(t)
      local function reach(name) if not r.milestones[name] then r.milestones[name] = tick end end
      for _, m in ipairs(MILESTONES) do
        if m[2] == 'tech' and not r.milestones[m[1]] then
          local tech = f.technologies[m[1]]
          if tech and tech.researched then reach(m[1]) end
        end
      end
      if (f.rockets_launched or 0) > 0 then reach('first-rocket') end
      local target = cfg('target')
      for _, pl in ipairs(platforms(f)) do
        if pl.hub and pl.hub.valid then reach('first-platform') end
        local at = pl.space_location and pl.space_location.name
        if at and (INNER[at] or at == 'aquilo') and not r.planets[at] then r.planets[at] = tick end
        if at == 'aquilo' then reach('aquilo') end
        local c = not at and pl.space_connection
        if c and ((c.to and c.to.name == target) or (c.from and c.from.name == target)) then reach('edge-run') end
      end
      local n = 0
      for p in pairs(r.planets) do if INNER[p] then n = n + 1 end end
      if n >= 1 then reach('first-planet') end
      if n >= 2 then reach('second-planet') end
      if n >= 3 then reach('third-planet') end
    end
    -- Ranked by milestones reached, then by the tick of the latest one (sooner first); equal both share a place.
    function G.standings()
      local rows = {}
      for _, t in ipairs(team_names()) do
        local r = rec_of(t)
        local n, last, latest, names = 0, nil, nil, {}
        for _, m in ipairs(MILESTONES) do
          local tick = r.milestones[m[1]]
          if tick then
            n = n + 1; names[#names+1] = m[1]
            if not last or tick >= last then last, latest = tick, m[1] end   -- equal ticks: the later in the race
          end
        end
        rows[#rows+1] = {team=t, milestones=n, of=#MILESTONES, reached=names, latest=latest, tick=last, wiped=r.wiped and true or nil}
      end
      table.sort(rows, function(a, b)
        if a.milestones ~= b.milestones then return a.milestones > b.milestones end
        if (a.tick or 0) ~= (b.tick or 0) then return (a.tick or 0) < (b.tick or 0) end
        return a.team < b.team
      end)
      for i, row in ipairs(rows) do
        local prev = rows[i - 1]
        row.rank = (prev and prev.milestones == row.milestones and prev.tick == row.tick) and prev.rank or i
      end
      return rows
    end

    -- An entity's power: production buildings by status (no power, no fuel), the home's by its electric buffer.
    local function up(e)
      if not (e and e.valid) then return false end
      local ok, s = pcall(function() return e.status end)
      if not ok or s == nil then return true end
      local d = defines.entity_status
      return s ~= d.no_power and s ~= d.no_fuel
    end
    local function electric(e)
      local ok, v = pcall(function()
        local b = e.electric_buffer_size
        if not b or b <= 0 then return nil end
        local s = e.status
        if s ~= nil and s == defines.entity_status.no_power then return false end
        return e.energy > 0
      end)
      if ok then return v end
      return nil
    end
    function G.home(t)
      local surface = game.get_surface(cfg('home_surface'))
      if not surface then return {ok=false, why='no ' .. tostring(cfg('home_surface')) .. ' surface'} end
      local pad = surface.find_entities_filtered{type='cargo-landing-pad', force=t, limit=1}[1]
      if not pad then return {ok=false, why='no cargo landing pad of ours on ' .. surface.name} end
      local h = {ok=true, surface=surface.name, pad={x=pad.position.x, y=pad.position.y}}
      if cfg('home_power') then
        local seen = 0
        for _, e in ipairs(surface.find_entities_filtered{position=pad.position, radius=cfg('home_radius'), force=t}) do
          local p = electric(e)
          if p ~= nil then seen = seen + 1 end
          if p then h.powered_by = e.name; return h end
        end
        h.ok = false
        h.why = seen == 0 and ('no electric building of ours within ' .. cfg('home_radius') .. ' tiles of the landing pad')
          or 'no power at the landing pad (' .. seen .. ' electric buildings round it, none powered)'
      end
      return h
    end
    -- A powered production building anywhere: the last one found first (one read), else the first 200 of each
    -- surface, else every one.
    local function production_up(t)
      local r = rec_of(t)
      if r.witness and up(r.witness) then return true end
      r.witness = nil
      local partial = {}
      for pass = 1, 2 do
        for _, surface in pairs(game.surfaces) do
          if pass == 1 or partial[surface.name] then
            local found = surface.find_entities_filtered{type=PRODUCTION, force=t, limit=pass == 1 and 200 or nil}
            for _, e in ipairs(found) do if up(e) then r.witness = e; return true end end
            if pass == 1 and #found >= 200 then partial[surface.name] = true end
          end
        end
      end
      return false
    end
    -- A character of a team's agent killed by another team within respawn_window_s of its (re)spawn.
    function G.on_died(event)
      local m = on()
      local e = event.entity
      if not (m and e and e.valid and e.type == 'character') then return end
      local victim, by = e.force.name, event.force and event.force.name
      if not (m.teams[victim] and by and m.teams[by] and by ~= victim) then return end
      local unit = e.unit_number
      for _, b in pairs((api.state().bots or {}).by_index or {}) do
        local c = b.character
        if c and (c == e or (c.valid and c.unit_number == unit)) then
          if game.tick - (b.spawn_tick or b.created_tick or 0) <= cfg('respawn_window_s') * 60 then
            local cause = event.cause
            rec_of(victim).kills[b.name] = {tick=game.tick, by=by, cause=cause and cause.valid and cause.name or nil}
          end
          return
        end
      end
    end
    local function team_bots(t)
      local list = {}
      for _, b in pairs((api.state().bots or {}).by_index or {}) do if (b.force or 'player') == t then list[#list+1] = b end end
      table.sort(list, function(x, y) return x.name < y.name end)
      return list
    end
    function G.check_wipe(t, tick)
      local r = rec_of(t)
      if production_up(t) then
        r.down_since = nil
        if r.wiped then
          alert('recovered', t, t .. ': a production building has power again; its wipe flag is cleared (nothing was restored)', {wiped_tick=r.wiped.tick})
          r.wiped = nil
        end
        return
      end
      r.down_since = r.down_since or tick
      if r.wiped or tick - r.down_since < cfg('wipe_down_s') * 60 then return end
      local bots, killed = team_bots(t), {}
      if #bots == 0 then return end   -- a team without agents (humans only) is never flagged
      for _, b in ipairs(bots) do
        local k = r.kills[b.name]
        if not (k and k.tick >= r.down_since) then return end
        killed[#killed+1] = b.name .. ' by ' .. k.by .. (k.cause and (' (' .. k.cause .. ')') or '')
      end
      r.wiped = {tick=tick, down_since=r.down_since, killed=killed}
      alert('wipe', t, string.format('%s is wiped: no powered production building since tick %d (%d s), and every agent killed on respawn by another team: %s. Restore is the operator\'s call; nothing was restored.',
        t, r.down_since, math.floor((tick - r.down_since) / 60), table.concat(killed, ', ')), {down_since=r.down_since})
    end

    -- The lines to agents: each names only the teams the reader's team has had contact with.
    function G.fact_text(res, t)
      local mine = res.scores and res.scores[t]
      local score = mine and string.format(' Our score: %g.', mine) or ''
      local w = res.winner
      if res.reason == 'edge' then
        local where, a = words(res.arrival.at), res.arrival
        if w == t then
          if res.kind == 'solo' then
            return string.format('The run is over: our platform %s reached the %s with our Nauvis home standing. We win alone.%s', a.platform, where, score)
          end
          local names = {}
          for u, v in pairs(res.scores) do if u ~= t and v > 0 and contacted(t, u) then names[#names+1] = string.format('%s %g', u, v) end end
          table.sort(names)
          return string.format('The run is over: our platform %s reached the %s with our Nauvis home standing, allied when it left its last planet with %s.%s',
            a.platform, where, table.concat(names, ', '), score)
        elseif (mine or 0) > 0 and contacted(t, w) then
          return string.format('The run is over: %s\'s platform reached the %s; our team was allied with %s when it left its last planet.%s', w, where, w, score)
        elseif contacted(t, w) then
          return string.format('The run is over: %s\'s platform reached the %s.%s', w, where, score)
        end
        return 'The run is over.' .. score
      elseif res.reason == 'wipe' then
        if w == t then return 'The run is over: every other team is wiped. We win.' .. score end
        if contacted(t, w) then return string.format('The run is over: %s wiped every other team.%s', w, score) end
        return 'The run is over.' .. score
      end
      local parts, own = {}, nil
      for _, row in ipairs(res.standings or {}) do
        if row.team == t then own = row end
        if contacted(t, row.team) then parts[#parts+1] = (row.team == t and 'our team' or row.team) .. ' ' .. row.milestones end
      end
      if #parts > 1 then
        return 'The run is over at its time limit, ranked by milestones toward the edge: ' .. table.concat(parts, ', ') .. '.'
      end
      return string.format('The run is over at its time limit; our team reached %d milestones toward the edge.', own and own.milestones or 0)
    end
    local function public_text(res)
      if res.reason == 'edge' then
        if res.kind == 'solo' then return string.format('%s reached the %s alone and wins (score %g)', res.winner, words(res.arrival.at), res.scores[res.winner]) end
        local names = {}
        for u, v in pairs(res.scores) do if v > 0 then names[#names+1] = string.format('%s %g', u, v) end end
        table.sort(names)
        return string.format('%s reached the %s with its allies: %s', res.winner, words(res.arrival.at), table.concat(names, ', '))
      elseif res.reason == 'wipe' then return res.winner .. ' wiped every other team and wins' end
      local top = {}
      for _, row in ipairs(res.standings) do if row.rank == 1 then top[#top+1] = row.team end end
      return 'Time is up; ranked by milestones toward the edge: ' .. table.concat(top, ' and ') .. (#top > 1 and ' share the lead' or ' leads')
    end
    function G.finish(reason, r)
      local g = gs()
      if g.result then return g.result end
      local res = {reason=reason, tick=game.tick, winner=r.winner, kind=r.kind, scores=r.scores, arrival=r.arrival, by=r.by,
        standings=G.standings(), deadline_tick=cfg('deadline_tick') or nil}
      if reason == 'milestones' then
        res.winners = {}
        for _, row in ipairs(res.standings) do if row.rank == 1 then res.winners[#res.winners+1] = row.team end end
        if #res.winners == 1 then res.winner = res.winners[1] end
      end
      res.text = public_text(res)
      g.result = res
      emit({result=res}, 'mt-game-result.json')
      alert('game_over', res.winner, 'Game over (' .. reason .. '): ' .. res.text .. '. The result is frozen in mt_game.')
      for _, t in ipairs(team_names()) do fact(t, G.fact_text(res, t)) end
      if api.feed then pcall(api.feed, {event='game_over', team=res.winner, text='Game over: ' .. res.text}) end
      return res
    end

    -- Edge arrivals: once per platform per stay at the target.
    local function scores_for(t, allies)
      local scores = {}
      for _, u in ipairs(team_names()) do scores[u] = 0 end
      if #allies == 0 then scores[t] = cfg('solo'); return scores, 'solo' end
      local P = pacts()
      local cap = P and P.share_max and P.share_max(2) * 2 or 1.4
      local own = 0
      for _, p in ipairs(allies) do
        local mine, theirs = 1, 1
        if p.shares then mine, theirs = 2 * (p.shares[t] or 0.5), 2 * (p.shares[p.with] or 0.5) end
        scores[p.with] = math.min(cap, math.max(scores[p.with] or 0, theirs))
        own = own + mine
      end
      scores[t] = math.min(cap, own / #allies)
      for u, v in pairs(scores) do scores[u] = math.floor(v * 1000 + 0.5) / 1000 end   -- 1.2, not 1.19999...
      return scores, 'allied'
    end
    function G.arrival(t, pl, tick)
      local g, P = gs(), pacts()
      local dep = P and P.last_departure and P.last_departure(t, pl.index)
      local rec = {tick=tick, team=t, platform=pl.name, at=cfg('target')}
      if dep then rec.departure = {from=dep.from, tick=dep.tick, pacts=dep.pacts} else rec.departure_unrecorded = true end
      g.arrivals[#g.arrivals+1] = rec
      while #g.arrivals > MAX_ARRIVALS do table.remove(g.arrivals, 1) end
      if g.result then rec.after_end = true; emit({arrival=rec}); return rec end
      rec.home = G.home(t)
      if not rec.home.ok then
        rec.counted, rec.why = false, 'home did not hold: ' .. rec.home.why
        emit({arrival=rec})
        alert('arrival_refused', t, string.format('%s\'s platform %s reached the %s, but its Nauvis home did not hold (%s): not counted.', t, pl.name, words(rec.at), rec.home.why))
        fact(t, string.format('Our platform %s reached the %s, but our Nauvis home did not hold (%s): the arrival does not count. With the landing pad standing and powered, arrive again.',
          pl.name, words(rec.at), rec.home.why))
        return rec
      end
      local allies = {}
      if dep then
        for _, p in ipairs(dep.pacts or {}) do if p.cease_fire then allies[#allies+1] = p end end
      else
        -- No departure on record (it left while the harness did not run): the pacts holding now, and the operator told.
        for _, p in ipairs(P and P.active_with and P.active_with(t) or {}) do if p.cease_fire then allies[#allies+1] = p end end
        alert('departure_unrecorded', t, string.format('%s\'s platform %s arrived with no departure on record: scored by the pacts holding at arrival.', t, pl.name))
      end
      local scores, kind = scores_for(t, allies)
      rec.counted, rec.kind = true, kind
      rec.home = {ok=true, pad=rec.home.pad, powered_by=rec.home.powered_by}
      emit({arrival=rec})
      rec_of(t).milestones.edge = rec_of(t).milestones.edge or tick
      return G.finish('edge', {winner=t, kind=kind, scores=scores, arrival=rec})
    end
    function G.check_arrivals(tick)
      local g, target = gs(), cfg('target')
      for _, t in ipairs(team_names()) do
        for _, pl in ipairs(platforms(game.forces[t])) do
          local key = t .. '/' .. tostring(pl.index)
          if pl.space_location and pl.space_location.name == target then
            if not g.at_target[key] then
              g.at_target[key] = tick
              G.arrival(t, pl, tick)
              if g.result then return end
            end
          elseif g.at_target[key] then g.at_target[key] = nil end
        end
      end
    end
    -- An event of a team's platform (on_space_platform_changed_state): the departure and arrival on the tick.
    function G.on_platform(event)
      if not on() or gs().result then return end
      local P = pacts()
      if P and P.departures_now then pcall(P.departures_now) end
      G.check_arrivals(event.tick or game.tick)
    end

    local function wipe_win(tick)
      local names, alive = team_names(), {}
      for _, t in ipairs(names) do if not rec_of(t).wiped then alive[#alive+1] = t end end
      local g = gs()
      if #names < 2 or #alive ~= 1 then g.wipe_win_alerted = nil; return end
      local w = alive[1]
      if cfg('wipe_win') == 'auto' then return G.finish('wipe', {winner=w, kind='wipe', scores={[w]=cfg('solo')}}) end
      if g.wipe_win_alerted ~= w then
        g.wipe_win_alerted = w
        alert('wipe_win_pending', w, w .. ' has wiped every other team. The run ends when the operator confirms: mt_game {end_by_wipe="' .. w .. '"}; or restore a team.')
      end
    end
    -- Every 60 ticks (runtime.lua): arrivals; every check_s the milestones, wipes and the deadline.
    function G.tick(tick)
      local m = on()
      if not m then return end
      local g = gs()
      if g.result then return end
      if not m.pacts and api.pacts and tick % 600 < 60 then
        local P = pacts()
        if P and P.departures_now then pcall(P.departures_now) end
      end
      G.check_arrivals(tick)
      if g.result then return end
      if g.last_check and tick - g.last_check < cfg('check_s') * 60 then return end
      g.last_check = tick
      for _, t in ipairs(team_names()) do
        G.observe(t, tick)
        G.check_wipe(t, tick)
      end
      wipe_win(tick)
      local dl = cfg('deadline_tick')
      if not g.result and dl and tick >= dl then G.finish('milestones', {kind='deadline', by='deadline'}) end
    end

    local CHECK = {
      target=function(v) return type(v) == 'string' and prototypes.space_location[v] ~= nil, 'a space location' end,
      solo=function(v) return type(v) == 'number' and v >= 1 and v <= 10, '1..10' end,
      home_surface=function(v) return type(v) == 'string' and #v > 0, 'a surface name' end,
      home_radius=function(v) return type(v) == 'number' and v >= 1 and v <= 500, '1..500 tiles' end,
      home_power=function(v) return type(v) == 'boolean', 'true or false' end,
      wipe_down_s=function(v) return type(v) == 'number' and v >= 1 and v <= 86400, '1..86400 s' end,
      respawn_window_s=function(v) return type(v) == 'number' and v >= 1 and v <= 3600, '1..3600 s' end,
      wipe_win=function(v) return v == 'confirm' or v == 'auto', 'confirm or auto' end,
      deadline_tick=function(v) return v == false or (type(v) == 'number' and v == math.floor(v) and v >= game.tick), 'false or a tick from now on' end,
      check_s=function(v) return type(v) == 'number' and v >= 1 and v <= 3600, '1..3600 s' end}
    function G.operator.mt_game(a)
      assert(on(), 'no teams set up (mt_setup)')
      local g = gs()
      if a.config ~= nil then
        assert(type(a.config) == 'table', 'config: {setting = value}')
        local set = {}
        for key, value in pairs(a.config) do
          local k, v = key, value
          if k == 'deadline_h' then
            assert(type(v) == 'number' and v > 0 and v <= 10000, 'deadline_h: hours from now, 0..10000')
            k, v = 'deadline_tick', game.tick + math.floor(v * 216000)
          end
          assert(CHECK[k], 'config: ' .. tostring(k) .. ' is no setting')
          local ok, want = CHECK[k](v)
          assert(ok, 'config ' .. k .. ': ' .. want)
          set[k] = v
        end
        assert(not g.result or next(set) == nil, 'the result is frozen; settings no longer change it')
        for k, v in pairs(set) do g.config[k] = v end
      end
      if a.wipe_clear ~= nil then
        assert(on().teams[a.wipe_clear], 'not a team: ' .. tostring(a.wipe_clear))
        local r = rec_of(a.wipe_clear)
        r.wiped, r.down_since, r.kills, r.witness = nil, nil, {}, nil
        alert('wipe_cleared', a.wipe_clear, a.wipe_clear .. ': wipe record cleared by the operator')
      end
      if a.end_by_wipe ~= nil then
        local w = a.end_by_wipe
        assert(on().teams[w], 'not a team: ' .. tostring(w))
        assert(not g.result, 'the result is already frozen')
        for _, t in ipairs(team_names()) do
          assert(t == w or rec_of(t).wiped, t .. ' is not wiped: no wipe win for ' .. w)
        end
        assert(not rec_of(w).wiped, w .. ' is wiped itself')
        G.finish('wipe', {winner=w, kind='wipe', scores={[w]=cfg('solo')}, by='operator'})
      end
      if a.end_now ~= nil then
        assert(a.end_now == true, 'end_now: true (ends the run now by milestone ranking)')
        assert(not g.result, 'the result is already frozen')
        G.finish('milestones', {kind='operator', by='operator'})
      end
      if a.clear_result ~= nil then
        assert(g.result and a.clear_result == g.result.tick, 'clear_result: the frozen result\'s tick (a deliberate operator undo)')
        alert('result_cleared', g.result.winner, 'the frozen result of tick ' .. g.result.tick .. ' was cleared by the operator')
        g.result, g.at_target = nil, {}
      end
      local c, teams = {}, {}
      for k in pairs(DEFAULTS) do c[k] = cfg(k) end
      for _, t in ipairs(team_names()) do
        local r = rec_of(t)
        local kills = {}
        for name, k in pairs(r.kills) do kills[name] = {tick=k.tick, by=k.by, cause=k.cause} end
        teams[t] = {down_since=r.down_since, wiped=r.wiped, respawn_kills=kills, milestones=r.milestones}
      end
      local alerts = {}
      for _, x in ipairs(g.alerts) do if not a.alerts_since or x.seq > a.alerts_since then alerts[#alerts+1] = x end end
      return {config=c, result=g.result, standings=G.standings(), teams=teams, arrivals=g.arrivals, alerts=alerts,
        alert_seq=g.alert_seq, milestones=#MILESTONES, tick=game.tick}
    end
    function G.operator.mt_game_tick(a)
      local g = gs()
      g.last_check = nil
      G.tick(a.tick or game.tick)
      return {tick=game.tick, result=g.result}
    end
    return G
  end)()
  for k, fn in pairs(M.game.operator) do M.operator[k] = fn end
  return M
end
