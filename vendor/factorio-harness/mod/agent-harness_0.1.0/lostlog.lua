-- Lost buildings (Nick d17 17:28: "Do they see destroyed building ghosts and have an easy way of reconstructing
-- them?"). Each building of ours that dies is kept here, one row each (the losses incidents in runtime.lua count them
-- by area): surface, name, position, direction, quality, tick, cause. The game names each one in its destroyed alerts
-- wherever it was, so the rows are fair to read in fog.
-- losses {surface?, area? | position+radius?, since?, name?, limit?, page?}: what of ours died where, whether a ghost
-- stands for it now (the game leaves one when it can; the map shows our ghosts in fog), whether in sight it stands
-- rebuilt, whether a roboport's construction area covers its ghost and what that network holds, and the items a rebuild
-- needs, carried or not.
-- rebuild {area | position+radius, all?, from?, avoid_enemies?, unsafe_goal?, dry_run?}: one queued plan for the ghosts
-- robots will not build (no construction area covers them, or its network has no idle robot or none of the item; all:
-- every ghost): take the items you do not carry from chests (from, else chests of ours near you, nearest first), craft
-- by hand what none holds (silo_stage's gathering, stage.lua), then construct over those ghosts in boxes of up to
-- 256x256, its walks with avoid_enemies as construct's.
return function(api)
  local M = {}
  local MAX = 6000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function store()
    local s = api.state()
    s.lost_log = s.lost_log or {rows={}, next=1}
    return s.lost_log
  end
  -- A building of ours died (runtime.lua's on_entity_died, after its not-lost types).
  function M.died(e, cause)
    local m = store()
    local q = try(function() return e.quality and e.quality.name end)
    m.rows[m.next] = {f=e.force.name, s=e.surface.name, n=e.name, x=e.position.x, y=e.position.y,
      d=try(function() return e.supports_direction and e.direction or nil end), q=q ~= 'normal' and q or nil, t=game.tick, c=cause}
    m.next = m.next % MAX + 1
  end
  -- Rows of force/surface in box ({{x1,y1},{x2,y2}}), newest first; the newest row a position wins.
  function M.rows_in(force, surface, box, since)
    local out, seen = {}, {}
    local m = store()
    for i = 0, MAX - 1 do
      local r = m.rows[((m.next - 2 - i) % MAX) + 1]
      if r and r.f == force and r.s == surface and (not since or r.t >= since) and
        (not box or (r.x >= box[1][1] and r.x <= box[2][1] and r.y >= box[1][2] and r.y <= box[2][2])) then
        local k = r.n .. '@' .. r.x .. ',' .. r.y
        if not seen[k] then seen[k] = true; out[#out+1] = r end
      end
    end
    return out
  end
  local function area_of(a, p)
    if a.area ~= nil then
      local v = a.area
      assert(type(v) == 'table', 'area is {left_top, right_bottom} or [[x1,y1],[x2,y2]]')
      local x = api.position(v.left_top or v[1]); local y = api.position(v.right_bottom or v[2])
      local box = {{math.min(x.x, y.x), math.min(x.y, y.y)}, {math.max(x.x, y.x), math.max(x.y, y.y)}}
      assert(box[2][1] - box[1][1] <= 512 and box[2][2] - box[1][2] <= 512, 'area is at most 512 tiles a side')
      return box
    end
    if a.position ~= nil then
      local c = api.position(a.position)
      local r = api.integer(a.radius, 64, 1, 256, 'radius')
      return {{c.x - r, c.y - r}, {c.x + r, c.y + r}}
    end
    return nil
  end
  local function surface_of(p, a)
    if a.surface == nil then return p.surface end
    assert(type(a.surface) == 'string', 'surface must be a surface name')
    local s = game.get_surface(a.surface)
    assert(s, 'unknown surface ' .. a.surface)
    return s
  end
  local function item_of(name)
    local it = try(function() return prototypes.entity[name].items_to_place_this[1] end)
    if not it then return nil, 0 end
    return type(it.name) == 'string' and it.name or try(function() return it.name.name end), it.count or 1
  end
  -- What robots make of a ghost at pos: the best covering network (idle robots, the item), or nil.
  function M.robots(s, f, pos, item, nets)
    local best
    for _, ln in ipairs(try(function() return s.find_logistic_networks_by_construction_area(pos, f) end) or {}) do
      local id = ln.network_id
      local n = nets[id]
      if not n then n = {ln=ln, idle=ln.available_construction_robots or 0, items={}}; nets[id] = n end
      if item and n.items[item] == nil then n.items[item] = try(function() return ln.get_item_count(item) end) or 0 end
      local has = item and n.items[item] or 0
      local score = (n.idle > 0 and 2 or 0) + (has > 0 and 1 or 0)
      if not best or score > best.score then best = {id=id, idle=n.idle, has=has, score=score} end
    end
    return best
  end
  local function verdict(best, item)
    if not best then return 'no roboport\'s construction area covers it' end
    if best.idle > 0 and best.has > 0 then return string.format('robots can build it (network %d: %d idle, %d %s)', best.id, best.idle, best.has, item) end
    if best.has == 0 then return string.format('network %d covers it and holds no %s', best.id, item or 'item for it') end
    return string.format('network %d covers it and has no idle construction robot', best.id)
  end
  -- Ghosts of ours by name@x,y in the 64-tile cells the rows fall in (one find a cell).
  local function ghosts_for(s, f, rows)
    local cells, out = {}, {}
    for _, r in ipairs(rows) do cells[math.floor(r.x / 64) .. ',' .. math.floor(r.y / 64)] = true end
    for k in pairs(cells) do
      local cx, cy = k:match('^(.-),(.*)$'); cx, cy = tonumber(cx) * 64, tonumber(cy) * 64
      for _, g in ipairs(s.find_entities_filtered{area={left_top={x=cx, y=cy}, right_bottom={x=cx + 64, y=cy + 64}}, force=f, type='entity-ghost'}) do
        if g.valid then out[g.ghost_name .. '@' .. g.position.x .. ',' .. g.position.y] = g end
      end
    end
    return out
  end

  function M.read(p, a)
    local s, f = surface_of(p, a), p.force
    local box = area_of(a, p)
    local since
    if a.since ~= nil then since = game.tick - api.integer(a.since, 60, 1, 100800, 'since') * 3600 end
    assert(a.name == nil or type(a.name) == 'string', 'name is an entity name')
    local rows = M.rows_in(f.name, s.name, box, since)
    if a.name then
      local kept = {}
      for _, r in ipairs(rows) do if r.n == a.name then kept[#kept+1] = r end end
      rows = kept
    end
    local where = (box and string.format(' in (%g,%g)-(%g,%g)', box[1][1], box[1][2], box[2][1], box[2][2]) or '') .. ' on ' .. s.name
    if #rows == 0 then
      return {count=0, line='no building of ours lost' .. where .. (since and ' in that time' or ' that the log holds (it began d17; the newest ' .. MAX .. ')')}
    end
    local ghosts = ghosts_for(s, f, rows)
    local inv = s == p.surface and try(function() return p.get_main_inventory() end)
    local nets, by_name, order, items, counts = {}, {}, {}, {}, {ghost=0, covered=0, robots=0, outside=0, rebuilt=0, gone=0, unknown=0}
    local out_rows = {}
    for _, r in ipairs(rows) do
      local q = {x=r.x, y=r.y}
      local item, n = item_of(r.n)
      local row = {name=r.n, position=q, quality=r.q, lost_s_ago=math.floor((game.tick - r.t) / 60), cause=r.c}
      local g = ghosts[r.n .. '@' .. r.x .. ',' .. r.y]
      local b = by_name[r.n]
      if not b then b = {name=r.n, lost=0, ghosts=0, robots=0, outside=0}; by_name[r.n] = b; order[#order+1] = b end
      b.lost = b.lost + 1
      if g then
        counts.ghost = counts.ghost + 1; b.ghosts = b.ghosts + 1
        row.ghost = true
        local best = M.robots(s, f, q, item, nets)
        row.robots = verdict(best, item)
        -- (d18 batch40 A2) on a space platform the hub builds it: what holds it there (ghostlist.lua)
        if not best and api.platform_blocker then row.robots = api.platform_blocker(s, g, item, 1) or row.robots end
        local robots_build = best and best.idle > 0 and best.has > 0
        if best then counts.covered = counts.covered + 1 end
        if robots_build then counts.robots = counts.robots + 1; b.robots = b.robots + 1 else counts.outside = counts.outside + 1; b.outside = b.outside + 1 end
        if item then
          local it = items[item] or {item=item, need=0, robots=0, by_hand=0, networks={}}
          items[item] = it
          it.need = it.need + n
          if robots_build then it.robots = it.robots + n else it.by_hand = it.by_hand + n end
          if best then it.networks[best.id] = best.has end
        end
      else
        row.ghost = false
        if f.is_chunk_visible(s, {x=math.floor(r.x / 32), y=math.floor(r.y / 32)}) then
          local e = try(function() return s.find_entity(r.n, q) end)
          if e then row.now = 'rebuilt: one stands there now'; counts.rebuilt = counts.rebuilt + 1
          else row.now = 'gone: nothing of it there now, and no ghost'; counts.gone = counts.gone + 1 end
        else
          row.now = 'no ghost there now (out of sight: whether it was rebuilt is unknown)'; counts.unknown = counts.unknown + 1
        end
      end
      out_rows[#out_rows+1] = row
    end
    local item_rows = {}
    for _, it in pairs(items) do
      local held = inv and (try(function() return inv.get_item_count(it.item) end) or 0) or nil
      local in_nets = 0
      for _, has in pairs(it.networks) do in_nets = in_nets + has end
      item_rows[#item_rows+1] = {item=it.item, need=it.need, robots_build=it.robots > 0 and it.robots or nil,
        to_carry=it.by_hand > 0 and it.by_hand or nil, you_hold=held, in_covering_networks=next(it.networks) and in_nets or nil}
    end
    table.sort(item_rows, function(x, y) if x.need ~= y.need then return x.need > y.need end return x.item < y.item end)
    table.sort(order, function(x, y) if x.lost ~= y.lost then return x.lost > y.lost end return x.name < y.name end)
    local limit = api.integer(a.limit, 32, 1, 64, 'limit')
    local pages = math.max(1, math.ceil(#out_rows / limit))
    local page = api.integer(a.page, 1, 1, pages, 'page')
    local shown = {}
    for i = (page - 1) * limit + 1, math.min(#out_rows, page * limit) do shown[#shown+1] = out_rows[i] end
    local line = string.format('%d buildings of ours lost%s%s: %d with a ghost now (%d robots can build: idle robots and the item in a network '
      .. 'whose construction area covers it; %d not: %d of those in a construction area without robots or the item, %d outside every one)',
      #rows, where, since and string.format(' in the last %d min', a.since) or '', counts.ghost, counts.robots, counts.outside,
      counts.covered - counts.robots, counts.outside - (counts.covered - counts.robots))
    if counts.rebuilt + counts.gone + counts.unknown > 0 then
      line = line .. string.format('; %d without a ghost (%d rebuilt in sight, %d gone in sight, %d out of sight)', counts.rebuilt + counts.gone + counts.unknown,
        counts.rebuilt, counts.gone, counts.unknown)
    end
    return {count=#rows, line=line, by_name=order, items=#item_rows > 0 and item_rows or nil, losses=shown, page=page, pages=pages,
      next=page < pages and page + 1 or nil,
      rebuild=counts.outside > 0 and string.format('rebuild {area} plans the %d ghosts robots will not build: takes the items you do not carry, crafts '
        .. 'what no chest holds, walks there and builds them', counts.outside) or nil}
  end

  -- The rebuild plan.
  local NEAR = 96
  function M.rebuild(p, a)
    assert(a.dry_run == nil or type(a.dry_run) == 'boolean', 'dry_run must be true or false')
    assert(a.all == nil or type(a.all) == 'boolean', 'all must be true or false')
    assert(a.surface == nil or (game.get_surface(a.surface) == p.surface), 'rebuild walks: the area must be on your surface')
    local box = area_of(a, p)
    assert(box, 'area {left_top, right_bottom} or position and radius is required')
    local s, f = p.surface, p.force
    local found = s.find_entities_filtered{area={left_top={x=box[1][1], y=box[1][2]}, right_bottom={x=box[2][1], y=box[2][2]}}, force=f,
      type={'entity-ghost', 'tile-ghost'}, limit=4001}
    assert(#found <= 4000, 'more than 4000 ghosts there; rebuild a smaller area')
    local nets, list, skipped = {}, {}, 0
    local want, need_n = {}, 0
    for _, g in ipairs(found) do
      if g.valid then
        local item, n
        if g.type == 'tile-ghost' then
          local it = try(function() return prototypes.tile[g.ghost_name].items_to_place_this[1] end)
          item, n = it and (type(it.name) == 'string' and it.name or try(function() return it.name.name end)), it and it.count or 1
        else item, n = item_of(g.ghost_name) end
        local best = not a.all and M.robots(s, f, g.position, item, nets)
        if best and best.idle > 0 and best.has > 0 then skipped = skipped + 1
        else
          list[#list+1] = g
          if item then want[item] = (want[item] or 0) + n; need_n = need_n + 1 end
        end
      end
    end
    if #list == 0 then
      return {ghosts=#found, line=#found == 0 and string.format('no ghost of ours in (%g,%g)-(%g,%g)', box[1][1], box[1][2], box[2][1], box[2][2])
        or string.format('all %d ghosts there are for robots (idle robots and the item in a network whose construction area covers them); all: true builds them too', skipped)}
    end
    -- Sources: the chests given, else chests of ours within NEAR tiles of you that hold any of it, nearest first.
    local chests = {}
    if a.from ~= nil then
      local froms = a.from
      assert(type(froms) == 'table' and (froms.x or froms[1]), 'from: a chest {x,y} or 1..16 of them')
      if froms.x then froms = {froms} end
      assert(#froms >= 1 and #froms <= 16, 'from: 1..16 chests')
      for i, q in ipairs(froms) do
        local pos = api.position(q)
        local e = api.entity(p, pos)
        assert(e, string.format('from[%d] %s: no chest of ours in sight or on the map there', i, at(pos)))
        chests[#chests+1] = e
      end
    else
      local near = s.find_entities_filtered{position=p.position, radius=NEAR, force=f, type={'container', 'logistic-container'}}
      table.sort(near, function(x, y) return api.distance(p.position, x.position) < api.distance(p.position, y.position) end)
      for _, e in ipairs(near) do
        if #chests >= 16 then break end
        if api.visible(p, e.position) then
          for item in pairs(want) do
            if (try(function() return e.get_item_count(item) end) or 0) > 0 then chests[#chests+1] = e; break end
          end
        end
      end
    end
    local g = api.gather(p, want, chests)
    -- construct over the ghosts' boxes, 256 tiles a side at most, the nearest box first
    -- (construct takes at most 1024 ghosts a box: a 256 box with more is split into 64 boxes)
    local function group(ghosts, size)
      local cells, order = {}, {}
      for _, e in ipairs(ghosts) do
        local k = math.floor(e.position.x / size) .. ',' .. math.floor(e.position.y / size)
        local c = cells[k]
        if not c then c = {x0=e.position.x, y0=e.position.y, x1=e.position.x, y1=e.position.y, n=0, list={}}; cells[k] = c; order[#order+1] = c end
        c.x0, c.y0 = math.min(c.x0, e.position.x), math.min(c.y0, e.position.y)
        c.x1, c.y1 = math.max(c.x1, e.position.x), math.max(c.y1, e.position.y)
        c.n = c.n + 1; c.list[#c.list+1] = e
      end
      return order
    end
    local boxes = {}
    for _, c in ipairs(group(list, 256)) do
      if c.n > 1000 then for _, d in ipairs(group(c.list, 64)) do boxes[#boxes+1] = d end else boxes[#boxes+1] = c end
    end
    table.sort(boxes, function(x, y)
      return api.distance(p.position, {x=(x.x0 + x.x1) / 2, y=(x.y0 + x.y1) / 2}) < api.distance(p.position, {x=(y.x0 + y.x1) / 2, y=(y.y0 + y.y1) / 2})
    end)
    local steps, plan = g.steps, g.plan
    for _, c in ipairs(boxes) do
      local area = {left_top={x=math.floor(c.x0) - 1, y=math.floor(c.y0) - 1}, right_bottom={x=math.ceil(c.x1) + 1, y=math.ceil(c.y1) + 1}}
      steps[#steps+1] = {action='construct', args={area=area, outside_robots=not a.all or nil, avoid_enemies=a.avoid_enemies, unsafe_goal=a.unsafe_goal},
        label='construct ' .. c.n .. ' ghosts'}
      plan[#plan+1] = string.format('construct %d ghost%s in (%g,%g)-(%g,%g)', c.n, c.n == 1 and '' or 's', area.left_top.x, area.left_top.y,
        area.right_bottom.x, area.right_bottom.y)
    end
    local out = {ghosts=#list, left_for_robots=skipped > 0 and skipped or nil, items=want, plan=plan, crafts=g.crafts,
      missing=g.missing, raw_short=g.raw_short, short=g.short}
    if a.dry_run then out.line = 'dry run: nothing queued'; out.steps = steps; return out end
    out.queue = api.submit(p, {steps=steps})
    out.queued = #steps
    out.line = string.format('queued %d step%s for %d ghost%s: %s%s', #steps, #steps == 1 and '' or 's', #list, #list == 1 and '' or 's',
      table.concat(plan, '; '), g.short and '; ' .. g.short or '')
    return out
  end

  M.schema = {
    losses = {surface='optional surface name (default yours)', area='optional {left_top, right_bottom} or [[x1,y1],[x2,y2]], up to 512 a side',
      position='optional centre with radius (1..256, default 64), instead of area', since='optional minutes back (1..100800)',
      name='optional entity name', limit='1..64 rows a page (default 32)', page='1..',
      returns='count, line, by_name [{name, lost, ghosts, robots (ghosts robots can build), outside}], items [{item, need, robots_build, to_carry, '
        .. 'you_hold, in_covering_networks}], losses [{name, position, quality, lost_s_ago, cause, ghost, robots (a ghost: the covering network, '
        .. 'its idle robots and the item, or that no construction area covers it), now (no ghost: rebuilt or gone in sight; out of sight unknown)}], '
        .. 'page, pages, next, rebuild; each building of ours that died is kept (since d17, the newest 6000); the game\'s destroyed alerts name '
        .. 'each one wherever it was, and its map shows our ghosts in fog'},
    rebuild = {area='{left_top, right_bottom} or [[x1,y1],[x2,y2]] on your surface, up to 512 a side', position='or a centre with radius (1..256)',
      all='true: every ghost there, also those robots can build (default: only the ones robots will not: no construction area covers them, or '
        .. 'its network has no idle robot or none of the item)',
      from='optional chest {x,y} or 1..16 of them to take from, in order (default: chests of ours within 96 tiles of you, in sight, '
        .. 'holding any of it, nearest first)',
      avoid_enemies='as construct\'s', unsafe_goal='as construct\'s', dry_run='true: the plan (steps), nothing queued',
      returns='ghosts, left_for_robots, items {item: count}, plan (the takes, the crafts, a construct a box), crafts, missing, raw_short, short, '
        .. 'queued, queue, line; the plan runs in your queue: transfer walks per chest (on_short skip), craft and wait_until crafting_done, '
        .. 'construct {area, outside_robots} per box of up to 256x256, nearest first'}}
  return M
end
