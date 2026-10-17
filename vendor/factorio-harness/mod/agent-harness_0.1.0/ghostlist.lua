-- ghosts {position?, radius?, area?, surface?, name?, limit?, page?} (A10, Muse: 9 wall ghosts nearby were unfindable;
-- inspect counts ghosts by type and construction_robots groups them by 32-tile cell): each ghost of ours (entity and
-- tile) near a point or in an area, nearest first: its name, position, the item that places it (and how many you hold),
-- and whether robots can build it: the networks whose construction area covers it, their idle construction robots and
-- how many of the item they hold, else why not (no construction area covers it, no idle robot, none of the item).
-- A summary counts them by name and by that verdict. Read only; bounded: 4000 ghosts, radius 256.
return function(api)
  local M = {}
  local MAX = 4000
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
    local inv = s == p.surface and try(function() return p.get_main_inventory() end)
    local nets, held = {}, {}
    local rows, by_name, by_verdict = {}, {}, {}
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
        if best then row.network, row.idle_robots, row.network_holds = best.id, best.n.idle, best.has end
        rows[#rows+1] = row
        local key = row.name .. (row.tile and ' (tile)' or '')
        by_name[key] = (by_name[key] or 0) + 1
        by_verdict[verdict] = (by_verdict[verdict] or 0) + 1
      end
    end
    table.sort(rows, function(x, y) if x.distance ~= y.distance then return x.distance < y.distance end return x.name < y.name end)
    local limit = api.integer(a.limit, 24, 1, 64, 'limit')
    local pages = math.max(1, math.ceil(#rows / limit))
    local page = api.integer(a.page, 1, 1, pages, 'page')
    local list, lines = {}, {}
    for i = (page - 1) * limit + 1, math.min(#rows, page * limit) do
      local r = rows[i]
      list[#list+1] = r
      lines[#lines+1] = string.format('%s%s ghost %s, %d tiles: needs %s%s; %s%s', r.name, r.tile and ' tile' or '', at(r.position), r.distance,
        r.item and (r.count .. ' ' .. r.item) or 'no item places it',
        r.you_hold and string.format(' (you hold %d)', r.you_hold) or '', r.robots,
        r.network and string.format(' (network %d: %d idle construction robots, holds %d)', r.network, r.idle_robots, r.network_holds) or '')
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
    local nextcmd
    if page < pages then
      nextcmd = string.format('ghosts {%s%s%s, limit: %d, page: %d}', where, a.surface and string.format(', surface: "%s"', s.name) or '',
        a.name and string.format(', name: "%s"', a.name) or '', limit, page + 1)
    end
    return {summary=summary, ghosts=list, lines=lines, total=#rows, page=pages > 1 and page or nil, pages=pages > 1 and pages or nil,
      more=#rows > page * limit and #rows - page * limit or nil, next=nextcmd, covered=covered,
      note='construct {position, radius} builds ghosts by hand (it takes the items); robots build those in a construction area with idle robots and the item in the network'}
  end
  M.schema = {ghosts = {position='optional centre (default you; another surface needs one)', radius='1..256 around it (default 32)',
    area='optional {left_top, right_bottom} or [[x1,y1],[x2,y2]] instead (at most 512 a side)', surface='optional planet or platform name', name='optional: only ghosts of this entity or tile',
    limit='1..64 ghosts a page (default 24)', page='1.. the next ghosts, nearest first',
    returns='summary (how many, by name, by robots verdict); ghosts [{name, tile, position, distance, item, count, you_hold, robots, network, idle_robots, network_holds}] nearest first, with lines: each ghost, what places it, and whether robots can build it (robots can build it; no roboport\'s construction area covers it; its network holds no ITEM; its network has no idle construction robot); page, pages, more, next. Read only'}}
  return M
end
