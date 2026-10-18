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
    local nets, held = {}, {}
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
        local verdict
        if not best then verdict = 'no roboport\'s construction area covers it'
        elseif best.n.idle > 0 and best.has > 0 then verdict = 'robots can build it'
        elseif best.has == 0 then verdict = 'its network holds no ' .. (item or 'item for it')
        else verdict = 'its network has no idle construction robot' end
        row.robots = verdict
        if g.type == 'entity-ghost' then ghost_of[row] = g end
        if best then row.network, row.idle_robots, row.network_holds = best.id, best.n.idle, best.has end
        for _, ln in ipairs(covering) do
          local hit = robot_for(ln, g)
          if hit and hit.r.valid then
            local line, stuck
            if api.robot_row then line, stuck = api.robot_row(hit.r, ln, rcache) end
            row.robot = line and string.format('%s (its order %d in the queue)', line, hit.k) or hit.r.name
            row.robot_held = stuck or nil
            break
          end
        end
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
      lines[#lines+1] = string.format('%s%s ghost %s, %d tiles: needs %s%s; %s%s%s', r.name, r.tile and ' tile' or '', at(r.position), r.distance,
        r.item and (r.count .. ' ' .. r.item) or 'no item places it',
        r.you_hold and string.format(' (you hold %d)', r.you_hold) or '', r.robots,
        r.network and string.format(' (network %d: %d idle construction robots, holds %d)', r.network, r.idle_robots, r.network_holds) or '',
        r.robot and '; robot: ' .. r.robot or '')
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
      note='construct {position, radius} builds ghosts by hand (it takes the items); robots build those in a construction area with idle robots and the item in the network'}
  end
  M.schema = {ghosts = {position='optional centre (default you; another surface needs one)', radius='1..256 around it (default 32)',
    area='optional {left_top, right_bottom} or [[x1,y1],[x2,y2]] instead (at most 512 a side)', surface='optional planet or platform name', name='optional: only ghosts of this entity or tile',
    limit='1..64 ghosts a page (default 24)', page='1.. the next ghosts, nearest first',
    returns='summary (how many, by name, by robots verdict); blocked: the nearest 512 entity ghosts over a live entity of ours whose collision meets theirs and not marked for upgrade or deconstruction (robots do not build them until it is), per ghost and entity name: how many and the upgrade call that marks them (another name of the same fast-replace group and size), else the deconstruct call; ghosts [{name, tile, position, distance, item, count, you_hold, robots, network, idle_robots, network_holds, robot, robot_held}] nearest first, with lines: each ghost, what places it, and whether robots can build it (robots can build it; blocked: our live ENTITY stands on its spot, not marked for upgrade or deconstruction; no roboport\'s construction area covers it; its network holds no ITEM; its network has no idle construction robot), and robot: the flying construction robot with an order on it (anywhere in its queue: which place), its charge, what it holds, its orders and what holds it up (nowhere to put what it holds, waiting to charge or charging, its target outside the construction area), or no robot has an order on it; the summary counts those whose robot is held up, and for a network with such a ghost, how many of its construction robots in the air are held up and by what (the 2 most); page, pages, more, next. Read only'}}
  return M
end
