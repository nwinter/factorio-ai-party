-- ghosts {position?, radius?, area?, surface?, name?, limit?, page?} (A10, Muse: 9 wall ghosts nearby were unfindable;
-- inspect counts ghosts by type and construction_robots groups them by 32-tile cell): each ghost of ours (entity and
-- tile) near a point or in an area, nearest first: its name, position, the item that places it (and how many you hold),
-- and whether robots can build it: the networks whose construction area covers it, their idle construction robots and
-- how many of the item they hold, else why not (no construction area covers it, no idle robot, none of the item).
-- A summary counts them by name and by that verdict. Read only; bounded: 4000 ghosts, radius 256.
return function(api)
  local M = {}
  local MAX, MAX_UNDER = 4000, 512
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function item_of(g)
    local proto = g.type == 'tile-ghost' and try(function() return prototypes.tile[g.ghost_name] end) or try(function() return g.ghost_prototype end)
    local it = proto and try(function() return proto.items_to_place_this[1] end)
    if not it then return nil, 0 end
    local name = type(it.name) == 'string' and it.name or try(function() return it.name.name end)
    return name, it.count or 1
  end
  -- (d18 batch40 A2, Astra: about 10 reads of Wayfarer's bow said "no roboport's construction area covers it") on a
  -- space platform the hub builds ghosts from its own inventory, with no roboport: what holds a ghost there. An entity
  -- ghost over empty space waits for the foundation under it (a foundation tile ghost there is built first; with none
  -- it is never built); then the hub holds the item or not, and whether its requests ask for it. 2.0.77 on world n:
  -- Wayfarer's hub has no logistic network and its surface none; past the hull the tile is empty-space.
  -- Returns the verdict and {hub_holds, hub_requests, no_foundation, foundation_ghosts}, or nil off a platform.
  -- (d20 batch60 V2, Sol #1499: two asteroid collector ghosts on IVc read "no foundation under 3 of its tiles" and were
  -- built by the hub with their front row over empty space) The floor an entity ghost needs, as the game checks it
  -- (2.0.77, read on the private copy): where its prototype has tile_buildability_rules, each rule's area (turned
  -- with the entity) needs tiles with one of its required layers and none of its colliding ones (asteroid-collector:
  -- foundation under its two rear rows, empty space under its front row and 3 rows past it; thruster: foundation under
  -- its body, empty space behind it); a tile of its box no rule covers needs a tile its collision mask does not meet
  -- (empty-space's layers include object and item: every building but rolling stock, robots and spidertrons). A
  -- foundation ghost on a tile counts as foundation to come. Returns {bare (need foundation, none and no ghost),
  -- ghosted (need foundation, a ghost there), not_empty (foundation, or a foundation ghost, where empty space is
  -- required), not_empty_ghosts, overhang (box tiles left over empty space by a rule), rules, placeable (the game's
  -- placement check for reviving it: can_place_entity, build_check_type ghost_revive, read only when a tile reads short;
  -- nil unread)}. On the private copy the check and a revive agreed in 8 of 8 cases (collectors north and east, their
  -- front over space or on foundation, a rear row over space; thrusters with space or foundation behind; belts).
  local function rot(x, y, dir) for _ = 1, math.floor(((dir or 0) % 16) / 4) do x, y = -y, x end return x, y end
  local function layers_of(m) return m and (m.layers or m) or nil end
  function M.floor(s, g)
    local out = {bare=0, ghosted=0, not_empty=0, not_empty_ghosts=0, overhang=0}
    local proto = try(function() return g.ghost_prototype end)
    local pos, dir = g.position, try(function() return g.direction end) or 0
    local rules = proto and try(function() return proto.tile_buildability_rules end) or {}
    local mask = proto and layers_of(try(function() return proto.collision_mask end))
    local areas = {}
    for _, r in ipairs(rules) do
      local a = r.area
      if a then
        local x1, y1 = rot(a.left_top.x, a.left_top.y, dir)
        local x2, y2 = rot(a.right_bottom.x, a.right_bottom.y, dir)
        local req, col = layers_of(r.required_tiles), layers_of(r.colliding_tiles)
        local area = {x1=pos.x + math.min(x1, x2), y1=pos.y + math.min(y1, y2), x2=pos.x + math.max(x1, x2), y2=pos.y + math.max(y1, y2),
          ground=(req and req.ground_tile) or (col and col.empty_space) or false, empty=(req and req.empty_space) or false}
        areas[#areas+1] = area
      end
    end
    out.rules = #areas > 0 or nil
    local function tile_ghost(x, y) return (try(function() return s.count_entities_filtered{area={{x, y}, {x + 1, y + 1}}, type='tile-ghost', force=g.force} end) or 0) > 0 end
    local function is_empty(t) return t and t.name == 'empty-space' end
    -- the box: a tile in a rule's area follows the rule; the rest, the mask against the tile (by name when unread)
    local b = try(function() return g.bounding_box end)
    local n = 0
    if b then
      for x = math.floor(b.left_top.x + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1 do
        for y = math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.y - 0.01) - 1 do
          n = n + 1
          local t = n <= 128 and try(function() return s.get_tile(x, y) end)
          local ground, ruled = false, false
          for _, a in ipairs(areas) do
            if x < a.x2 and x + 1 > a.x1 and y < a.y2 and y + 1 > a.y1 then
              ruled = true
              if a.ground then ground = true end
            end
          end
          if not ruled then
            local tl = t and layers_of(try(function() return t.prototype.collision_mask end))
            if tl and mask then for l in pairs(mask) do if tl[l] then ground = true end end
            else ground = is_empty(t) end
          end
          if is_empty(t) then
            if ground then if tile_ghost(x, y) then out.ghosted = out.ghosted + 1 else out.bare = out.bare + 1 end
            else out.overhang = out.overhang + 1 end
          end
        end
      end
    end
    -- rule areas needing empty space: foundation there, or a foundation ghost to come
    for _, a in ipairs(areas) do
      if a.empty then
        local box = {{math.floor(a.x1), math.floor(a.y1)}, {math.ceil(a.x2), math.ceil(a.y2)}}
        local solid = try(function() return s.count_tiles_filtered{area=box, name='empty-space', invert=true} end) or 0
        local ghosts = try(function() return s.count_entities_filtered{area=box, type='tile-ghost', force=g.force} end) or 0
        out.not_empty = out.not_empty + solid + ghosts
        out.not_empty_ghosts = out.not_empty_ghosts + ghosts
      end
    end
    local name = try(function() return g.ghost_name end)
    if (out.bare > 0 or out.not_empty > 0) and name and s.can_place_entity and defines.build_check_type and defines.build_check_type.ghost_revive then
      out.placeable = try(function() return s.can_place_entity{name=name, position=pos, direction=dir, force=g.force, build_check_type=defines.build_check_type.ghost_revive} end)
    end
    return out
  end
  function M.platform_blocker(s, g, item, count)
    local pl = try(function() return s.platform end)
    if not pl then return nil end
    local hub = try(function() return pl.hub end)
    if not (hub and hub.valid) then return 'the platform has no hub: nothing builds it', {} end
    local info, parts = {}, {}
    if g.type == 'entity-ghost' then
      local f = M.floor(s, g)
      local bare, ghosted = f.bare, f.ghosted
      -- (d20 batch60 V2) the game's own placement check has the last word: a ghost it would revive here is not held by
      -- its floor, whatever the count
      if (bare > 0 or f.not_empty > 0) and f.placeable then
        info.floor_ok = true
        parts[#parts+1] = 'its floor as the game checks it (the placement check for reviving this ghost) takes it'
      elseif bare > 0 then
        info.no_foundation = bare
        parts[#parts+1] = string.format('no foundation under %d of %s and no foundation ghost there: the hub does not build it until foundation is placed', bare, f.rules and 'the tiles its tile rules need foundation on' or 'its tiles')
      elseif f.not_empty > 0 then
        info.not_empty = f.not_empty
        parts[#parts+1] = string.format('foundation (%d tile%s) where its tile rules need empty space%s: the game does not place it there', f.not_empty, f.not_empty == 1 and '' or 's', f.not_empty_ghosts > 0 and string.format(' (%d of them foundation ghosts)', f.not_empty_ghosts) or '')
      elseif ghosted > 0 then
        info.foundation_ghosts = ghosted
        parts[#parts+1] = string.format('waits for foundation: %d space-platform-foundation ghost%s under it, built first', ghosted, ghosted == 1 and '' or 's')
      end
      if f.overhang > 0 then info.over_empty_space = f.overhang end
    end
    if not item then
      parts[#parts+1] = 'no item places it'
    else
      local holds = try(function() return hub.get_item_count(item) end) or 0
      info.hub_holds = holds
      if holds >= (count or 1) then
        parts[#parts+1] = string.format('the hub holds %d %s', holds, item)
      else
        local asks = 0
        local secs = try(function() return hub.get_logistic_sections() end)
        for i = 1, secs and secs.sections_count or 0 do
          local sec = try(function() return secs.get_section(i) end)
          if sec and sec.active ~= false then
            for _, fl in ipairs(sec.filters or {}) do
              local v = fl.value
              if (type(v) == 'table' and v.name or v) == item then asks = asks + (fl.min or 0) end
            end
          end
        end
        info.hub_requests = asks
        parts[#parts+1] = string.format('the hub holds %s; %s', holds > 0 and holds .. ' of the ' .. count .. ' ' .. item .. ' it needs' or 'no ' .. item,
          asks > 0 and string.format('its requests ask for %d (filled from a planet the platform stops at)', asks) or 'no request of the hub asks for it')
      end
    end
    return table.concat(parts, '; '), info
  end
  local function area_of(v)
    assert(type(v) == 'table', 'area is {left_top, right_bottom} or [[x1,y1],[x2,y2]]')
    local a = api.position(v.left_top or v[1])
    local b = api.position(v.right_bottom or v[2])
    local box = {{math.min(a.x, b.x), math.min(a.y, b.y)}, {math.max(a.x, b.x), math.max(a.y, b.y)}}
    assert(box[2][1] - box[1][1] <= 512 and box[2][2] - box[1][2] <= 512, 'area is at most 512 tiles a side')
    return box
  end
  function M.read(p, a)
    local s = p.surface
    if a.surface ~= nil then
      s = type(a.surface) == 'string' and game.get_surface(a.surface)
      assert(s, 'surface must be a planet or platform surface name')
    end
    local f = p.force
    local filter = {type={'entity-ghost', 'tile-ghost'}, force=f, limit=MAX}
    local centre, covered, where
    if a.area ~= nil then
      local box = area_of(a.area)
      filter.area = box
      centre = a.position and api.position(a.position) or {x=(box[1][1] + box[2][1]) / 2, y=(box[1][2] + box[2][2]) / 2}
      covered = string.format('in the area (%g,%g)-(%g,%g) on %s', box[1][1], box[1][2], box[2][1], box[2][2], s.name)
      where = string.format('area: [[%g,%g],[%g,%g]]', box[1][1], box[1][2], box[2][1], box[2][2])
    else
      assert(a.position ~= nil or s == p.surface, 'ghosts on another surface takes position or area there')
      centre = a.position and api.position(a.position) or p.position
      local radius = api.integer(a.radius, 32, 1, 256, 'radius')
      filter.position, filter.radius = centre, radius
      covered = string.format('within %d tiles of %s on %s', radius, at({x=math.floor(centre.x), y=math.floor(centre.y)}), s.name)
      where = string.format('position: [%g,%g], radius: %d', math.floor(centre.x * 10 + 0.5) / 10, math.floor(centre.y * 10 + 0.5) / 10, radius)
    end
    if a.name ~= nil then
      assert(type(a.name) == 'string', 'name is the ghost\'s entity or tile name')
      filter.ghost_name = a.name
    end
    local found = s.find_entities_filtered(filter)
    -- (d17 batch18 B3, Astra: three critical builds waited 10 min with 100+ idle robots; robots held spare poles with
    -- nowhere to put them) Each ghost's robot: the flying construction robot of its network with an order on it anywhere
    -- in its queue, read once a network (unit number -> robot and the order's place in its queue).
    local assigned, rcache, held_text, told, MAX_FLYING = {}, {}, {}, {}, 256
    local function robot_for(ln, g)
      local id = ln.network_id
      if not assigned[id] then
        -- and the network's robots in the air held up, by what holds them (counts left out: wood*4 and wood*3 as one)
        local map, held, n = {}, {}, 0
        for i, r in ipairs(try(function() return ln.construction_robots end) or {}) do
          for k, o in ipairs(r.valid and try(function() return r.robot_order_queue end) or {}) do
            local u = o.target and try(function() return o.target.valid and o.target.unit_number end)
            if u and not map[u] then map[u] = {r=r, k=k} end
          end
          if i <= MAX_FLYING and r.valid and api.robot_row then
            n = n + 1
            local _, stuck, why = api.robot_row(r, ln, rcache)
            if stuck and why then local key = why:gsub('%*%d+', ''); held[key] = (held[key] or 0) + 1 end
          end
        end
        local list, total = {}, 0
        for why, c in pairs(held) do list[#list+1] = {why=why, c=c}; total = total + c end
        table.sort(list, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.why < y.why end)
        local parts = {}
        for i = 1, math.min(2, #list) do parts[i] = list[i].c .. ' ' .. list[i].why end
        held_text[id] = total > 0 and string.format('%d of the %d construction robots of network %d in the air%s are held up: %s', total, n, id,
          n >= MAX_FLYING and ' read' or '', table.concat(parts, '; ')) or nil
        assigned[id] = map
      end
      local u = try(function() return g.unit_number end)
      return u and assigned[id][u]
    end
    local inv = s == p.surface and try(function() return p.get_main_inventory() end)
    local nets, held, contested, searches = {}, {}, {}, 0
    local rows, by_name, by_verdict, held_n, blocked, ghost_of = {}, {}, {}, 0, {}, {}
    for _, g in ipairs(found) do
      if g.valid then
        local item, count = item_of(g)
        local row = {name=g.ghost_name, tile=g.type == 'tile-ghost' or nil, position=g.position,
          distance=math.floor(api.distance(centre, g.position) + 0.5), item=item, count=item and count or nil}
        if item and inv then
          if held[item] == nil then held[item] = try(function() return inv.get_item_count(item) end) or 0 end
          row.you_hold = held[item]
        end
        -- the networks whose construction area covers it: their idle construction robots and the item they hold
        local covering = try(function() return s.find_logistic_networks_by_construction_area(g.position, f) end) or {}
        local best
        for _, ln in ipairs(covering) do
          local id = ln.network_id
          local n = nets[id]
          if not n then n = {idle=ln.available_construction_robots or 0, all=ln.all_construction_robots or 0, items={}}; nets[id] = n end
          if item and n.items[item] == nil then n.items[item] = try(function() return ln.get_item_count(item) end) or 0 end
          local has = item and n.items[item] or 0
          local score = (n.idle > 0 and 2 or 0) + (has > 0 and 1 or 0)
          if not best or score > best.score then best = {id=id, n=n, has=has, score=score} end
        end
        -- the flying robot with an order on it, first: (d18 batch38 A4, Astra: "its network holds no big-electric-pole"
        -- while a robot carried one to it, and restocking followed) a robot holding the item is it in transit
        local carrier
        for _, ln in ipairs(covering) do
          local hit = robot_for(ln, g)
          if hit and hit.r.valid then
            local line, stuck
            if api.robot_row then line, stuck = api.robot_row(hit.r, ln, rcache) end
            row.robot = line and string.format('%s (its order %d in the queue)', line, hit.k) or hit.r.name
            row.robot_held = stuck or nil
            local cargo = item and try(function() return hit.r.get_inventory(defines.inventory.robot_cargo).get_item_count(item) end) or 0
            if cargo > 0 then
              carrier = {position={x=hit.r.position.x, y=hit.r.position.y}, distance=math.floor(api.distance(hit.r.position, g.position) + 0.5), count=cargo, order=hit.k}
            end
            break
          end
        end
        local verdict
        local plat, pinfo
        if not best and not carrier then plat, pinfo = M.platform_blocker(s, g, item, count) end
        if plat then
          verdict = plat
          row.hub_holds, row.hub_requests, row.no_foundation, row.foundation_ghosts = pinfo.hub_holds, pinfo.hub_requests, pinfo.no_foundation, pinfo.foundation_ghosts
        elseif carrier then
          row.in_transit = carrier
          verdict = string.format('in transit: a construction robot carries %s to it (%d tiles away, its order %d)', item, carrier.distance, carrier.order)
        elseif not best then verdict = 'no roboport\'s construction area covers it'
        elseif best.n.idle > 0 and best.has > 0 then verdict = 'robots can build it'
        elseif best.has == 0 then verdict = 'its network holds no ' .. (item or 'item for it') .. ' and no robot carries one to it'
        else verdict = 'its network has no idle construction robot' end
        row.robots = verdict
        -- (B3) more ghosts of ours in its network want its item than the network holds: each, from where the item is
        if item and best and best.has > 0 and g.type == 'entity-ghost' then
          local key = best.id .. '|' .. item
          if contested[key] == nil and searches < 3 then
            searches = searches + 1
            local pk = try(function() return covering[1].select_pickup_point{name=item, position=g.position} end)
            local o = pk and try(function() return pk.owner end)
            contested[key] = M.contested(s, f, item, o and o.valid and o.position or g.position, best.has) or false
          end
          if contested[key] then row.contested = contested[key].line end
        end
        if g.type == 'entity-ghost' then ghost_of[row] = g end
        if best then row.network, row.idle_robots, row.network_holds = best.id, best.n.idle, best.has end
        if not row.robot and best then
          row.robot = 'no robot has an order on it'
          if held_text[best.id] and not told[best.id] then told[best.id] = true; told[#told+1] = held_text[best.id] end
        end
        rows[#rows+1] = row
        local key = row.name .. (row.tile and ' (tile)' or '')
        by_name[key] = (by_name[key] or 0) + 1
        by_verdict[verdict] = (by_verdict[verdict] or 0) + 1
        if row.robot_held then held_n = held_n + 1 end
      end
    end
    table.sort(rows, function(x, y) if x.distance ~= y.distance then return x.distance < y.distance end return x.name < y.name end)
    -- (d17 batch34 A1, Astra: ~65 medium-pole ghosts over live small poles read "robots can build it") the nearest 512
    -- entity ghosts (about 12 us each on world n): a live entity of ours on the spot, not marked, blocks it
    local checked = 0
    for _, r in ipairs(rows) do
      local g = ghost_of[r]
      if g and api.under then
        checked = checked + 1
        if checked > MAX_UNDER then break end
        local under, kind = api.under(g)
        if under then
          by_verdict[r.robots] = by_verdict[r.robots] - 1
          if by_verdict[r.robots] == 0 then by_verdict[r.robots] = nil end
          r.robots = string.format('blocked: our live %s %s stands on its spot, not marked for %s (robots do not build it until it is)', under.name, at(under.position),
            kind and 'upgrade' or 'deconstruction')
          local key = 'blocked: a live entity of ours on its spot, not marked for upgrade or deconstruction'
          by_verdict[key] = (by_verdict[key] or 0) + 1
          blocked[#blocked+1] = {ghost=g, under=under, kind=kind}
        end
      end
    end
    local limit = api.integer(a.limit, 24, 1, 64, 'limit')
    local pages = math.max(1, math.ceil(#rows / limit))
    local page = api.integer(a.page, 1, 1, pages, 'page')
    local list, lines = {}, {}
    for i = (page - 1) * limit + 1, math.min(#rows, page * limit) do
      local r = rows[i]
      list[#list+1] = r
      -- (d20 batch56 R7) who placed it, when, through which request (ghostlog.lua)
      if ghost_of[r] and api.placed_by then r.placed = try(function() return api.placed_by(ghost_of[r]) end) end
      lines[#lines+1] = string.format('%s%s ghost %s, %d tiles: needs %s%s; %s%s%s', r.name, r.tile and ' tile' or '', at(r.position), r.distance,
        r.item and (r.count .. ' ' .. r.item) or 'no item places it',
        r.you_hold and string.format(' (you hold %d)', r.you_hold) or '', r.robots,
        r.network and string.format(' (network %d: %d idle construction robots, holds %d)', r.network, r.idle_robots, r.network_holds) or '',
        r.robot and '; robot: ' .. r.robot or '') .. (r.placed and '; placed: ' .. r.placed or '')
    end
    local names, verdicts = {}, {}
    for k, n in pairs(by_name) do names[#names+1] = {k=k, n=n} end
    table.sort(names, function(x, y) if x.n ~= y.n then return x.n > y.n end return x.k < y.k end)
    local nt = {}
    for i, x in ipairs(names) do if i <= 8 then nt[i] = x.n .. ' ' .. x.k end end
    for k, n in pairs(by_verdict) do verdicts[#verdicts+1] = n .. ' ' .. k end
    table.sort(verdicts)
    local summary = #rows == 0 and ('no ghost of ours ' .. covered .. (a.name and ' named ' .. a.name or ''))
      or string.format('%d ghost%s %s%s: %s%s; %s', #rows, #rows == 1 and '' or 's', covered, #found >= MAX and ' (the first ' .. MAX .. ')' or '',
        table.concat(nt, ', '), #names > 8 and string.format(', +%d more names', #names - 8) or '', table.concat(verdicts, '; '))
        .. (held_n > 0 and string.format('; %d whose robot is held up', held_n) or '') .. (#told > 0 and '; ' .. table.concat(told, '; ') or '')
    local nextcmd
    if page < pages then
      nextcmd = string.format('ghosts {%s%s%s, limit: %d, page: %d}', where, a.surface and string.format(', surface: "%s"', s.name) or '',
        a.name and string.format(', name: "%s"', a.name) or '', limit, page + 1)
    end
    local where_s = ''
    if s ~= p.surface then where_s = s.platform and string.format(', platform: "%s"', s.platform.name) or string.format(', surface: "%s"', s.name) end
    return {summary=summary, ghosts=list, lines=lines, blocked=#blocked > 0 and api.under_lines(blocked, where_s) or nil,
      blocked_checked=checked > MAX_UNDER and string.format('the nearest %d entity ghosts checked for a live entity on their spot', MAX_UNDER) or nil, total=#rows, page=pages > 1 and page or nil, pages=pages > 1 and pages or nil,
      more=#rows > page * limit and #rows - page * limit or nil, next=nextcmd, covered=covered,
      note=try(function() return s.platform end) and 'on a space platform the hub builds ghosts from its own inventory (no roboport or construction robot): an entity ghost once the foundation under it is there and the hub holds its item'
        or 'construct {position, radius} builds ghosts by hand (it takes the items); robots build those in a construction area with idle robots and the item in the network'}
  end
  -- (d18 batch38 B3, Luna: the only roboport that landed was built at a duplicate ghost (67,44), not the claimed one at
  -- (204,69)) the game sets no build priority among ghosts. contested(surface, force, item, at): the entity ghosts of
  -- ours in the construction area of the network covering `at` that the item places, when there are more of them than
  -- the network holds: {wanted, holds, network, lines (each ghost: where, the claim holding it and its owner, the
  -- distance from at), line}; nil otherwise. Bounded: only when the network holds MAX_HOLDS or fewer; one ghost search
  -- (limit MAX_CONTESTED) of that network's box.
  local MAX_CONTESTED, MAX_HOLDS = 64, 16
  function M.contested(surface, force, item, from, holds)
    local ip = try(function() return prototypes.item[item] end)
    local place = ip and try(function() return ip.place_result and ip.place_result.name end)
    if not place then return nil end
    local net = (try(function() return surface.find_logistic_networks_by_construction_area(from, force) end) or {})[1]
    if not net then return nil end
    -- a few of it only (the search covers the network's box: 9 ms for Nauvis's on world n): MAX_HOLDS or fewer held
    holds = holds or try(function() return net.get_item_count(item) end) or 0
    if holds > MAX_HOLDS then return nil end
    local box
    for _, c in ipairs(try(function() return net.cells end) or {}) do
      local o = c.owner
      local r = try(function() return c.construction_radius end) or 0
      if o and o.valid and r > 0 and not try(function() return c.mobile end) then
        local x, y = o.position.x, o.position.y
        box = box and {math.min(box[1], x - r), math.min(box[2], y - r), math.max(box[3], x + r), math.max(box[4], y + r)} or {x - r, y - r, x + r, y + r}
      end
    end
    if not box then return nil end
    local ghosts = try(function() return surface.find_entities_filtered{area={{box[1], box[2]}, {box[3], box[4]}}, type='entity-ghost', ghost_name=place, force=force, limit=MAX_CONTESTED} end) or {}
    if #ghosts <= holds or #ghosts < 2 then return nil end
    table.sort(ghosts, function(x, y) return api.distance(x.position, from) < api.distance(y.position, from) end)
    local lines = {}
    for i, g in ipairs(ghosts) do
      if i > 8 then lines[#lines+1] = string.format('+%d more', #ghosts - 8); break end
      local c = api.claim_at and api.claim_at(surface, g.position)
      lines[#lines+1] = string.format('%s %s%s, %d tiles from %s', place, at(g.position),
        c and string.format(' (claim #%d %s, %s)', c.id, c.title or '', tostring(c.owner)) or ' (no claim)', math.floor(api.distance(g.position, from) + 0.5), at(from))
    end
    return {wanted=#ghosts, holds=holds, network=net.network_id, lines=lines,
      line=string.format('%d %s ghosts of ours in network %d want %s and it holds %d: %s; robots build whichever they take it to first (the game sets no order among ghosts; a ghost removed with deconstruct {area} is not built)',
        #ghosts, place, net.network_id, item, holds, table.concat(lines, '; '))}
  end
  M.schema = {ghosts = {position='optional centre (default you; another surface needs one)', radius='1..256 around it (default 32)',
    area='optional {left_top, right_bottom} or [[x1,y1],[x2,y2]] instead (at most 512 a side)', surface='optional planet or platform name', name='optional: only ghosts of this entity or tile',
    limit='1..64 ghosts a page (default 24)', page='1.. the next ghosts, nearest first',
    returns='summary (how many, by name, by robots verdict); blocked: the nearest 512 entity ghosts over a live entity of ours whose collision meets theirs and not marked for upgrade or deconstruction (robots do not build them until it is), per ghost and entity name: how many and the upgrade call that marks them (another name of the same fast-replace group and size), else the deconstruct call; ghosts [{name, tile, position, distance, item, count, you_hold, robots, network, idle_robots, network_holds, robot, robot_held, placed (who placed it, when, through which request, as inspect gives it)}] nearest first, with lines: each ghost, what places it, and whether robots can build it (in transit: a construction robot with an order on it carries its item, how far off; robots can build it; blocked: our live ENTITY stands on its spot, not marked for upgrade or deconstruction; no roboport\'s construction area covers it; its network holds no ITEM and no robot carries one to it; its network has no idle construction robot; on a space platform, where the hub builds: no foundation under it or a foundation ghost first, the hub holds ITEM or none and whether its requests ask for it: hub_holds, hub_requests, no_foundation, foundation_ghosts), in_transit {position, distance, count, order}, and robot: the flying construction robot with an order on it (anywhere in its queue: which place), its charge, what it holds, its orders and what holds it up (nowhere to put what it holds, waiting to charge or charging, its target outside the construction area), or no robot has an order on it; the summary counts those whose robot is held up, and for a network with such a ghost, how many of its construction robots in the air are held up and by what (the 2 most); page, pages, more, next. Read only'}}
  return M
end
