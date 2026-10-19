-- deconwent: where a deconstructed item went (d18 batch37 D3, Astra: recovered artillery silently built an older ghost
-- elsewhere). On a robot's mining (on_robot_mined_entity, our force) the harness follows that robot every EVERY ticks
-- while it holds the items: the order it flies (a ghost to build, as robot_order_queue gives it), then where its cargo
-- went: the ghost it built (an entity of the ghost's name now stands there, with who placed the ghost), a storage chest
-- within 3 tiles of where it was last seen (then that chest is watched, and the next construction robot within 8 tiles
-- taking the item from it is followed the same way), or neither seen. At most WATCH followed at once, HOPS robots a
-- record, FOLLOW ticks a robot, STORED ticks a chest; KEEP records kept. where_is {item} reads them (deconstructed).
-- What it cannot know: a robot's cargo can leave by a way not seen (a chest out of 3 tiles, a robot destroyed: said),
-- and the item taken from storage may be another of the same name in that chest.
return function(api)
  local M = {}
  M.WATCH, M.KEEP, M.HOPS, M.EVERY, M.FOLLOW, M.STORED = 16, 32, 3, 60, 7200, 18000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function store()
    local s = api.state()
    s.decon_went = s.decon_went or {seq=0, list={}}
    return s.decon_went
  end
  local function ago(t)
    local sec = math.floor(t / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  local function name_of(v) if type(v) == 'table' or type(v) == 'userdata' then return v.name end return v end
  local function cargo(r, item)
    local inv = try(function() return r.get_inventory(defines.inventory.robot_cargo) end)
    return inv and (try(function() return inv.get_item_count(item) end) or 0) or 0
  end
  local function watching(st)
    local n = 0
    for _, r in ipairs(st.list) do if r.state == 'carried' or r.state == 'stored' then n = n + 1 end end
    return n
  end
  function M.on_mined(event)
    local e, robot, buffer = event.entity, event.robot, event.buffer
    if not (e and robot and robot.valid and buffer) then return end
    -- our buildings and items on the ground (a pickup); trees, rocks and other neutral clearing are not followed
    if e.type ~= 'item-entity' and try(function() return e.force.name end) ~= robot.force.name then return end
    local items, first = {}, nil
    for _, c in ipairs(try(function() return buffer.get_contents() end) or {}) do
      local n = name_of(c.name)
      if n and (c.count or 0) > 0 then items[#items+1] = n .. '*' .. c.count; first = first or n end
    end
    if not first then return end
    local st = store()
    st.seq = st.seq + 1
    local rec = {id=st.seq, tick=game.tick, name=e.name, position={x=e.position.x, y=e.position.y}, surface=e.surface.name, force=robot.force.name,
      items=table.concat(items, ', '), item=first, robot=robot, robot_no=robot.unit_number, first_robot=robot.unit_number, hops={}, state='carried', since=game.tick,
      last_pos={x=robot.position.x, y=robot.position.y}}
    if watching(st) >= M.WATCH then rec.state = 'done'; rec.robot = nil; rec.hops[1] = string.format('not followed (%d followed at once)', M.WATCH) end
    st.list[#st.list+1] = rec
    while #st.list > M.KEEP do table.remove(st.list, 1) end
  end
  local function hop(rec, text) rec.hops[#rec.hops+1] = string.format('%s %s after', text, ago(game.tick - rec.tick)) end
  local function done(rec, text) if text then hop(rec, text) end; rec.state = 'done'; rec.robot = nil; rec.chest = nil end
  local function follow(rec)
    local r = rec.robot
    if not (r and r.valid) then return done(rec, string.format('robot #%s gone (destroyed or out of reach of the read) last seen at %s', tostring(rec.robot_no), at(rec.last_pos))) end
    local n = cargo(r, rec.item)
    if n > 0 then
      rec.last_pos = {x=r.position.x, y=r.position.y}
      local o = (try(function() return r.robot_order_queue end) or {})[1]
      local t = o and o.target
      if t and t.valid and t.type == 'entity-ghost' then
        local by = try(function() return t.last_user and t.last_user.name end)
        rec.ghost = {name=t.ghost_name, position={x=t.position.x, y=t.position.y}, by=by}
      end
      if game.tick - rec.since > M.FOLLOW then done(rec, string.format('robot #%s still carrying it at %s (no longer followed)', tostring(rec.robot_no), at(rec.last_pos))) end
      return
    end
    local s = game.get_surface(rec.surface)
    local g = rec.ghost
    if g and s then
      local built = try(function() return s.find_entities_filtered{position=g.position, name=g.name, limit=1} end) or {}
      if #built > 0 then
        return done(rec, string.format('robot #%s built the %s ghost at %s%s', tostring(rec.robot_no), g.name, at(g.position), g.by and ' (placed by ' .. g.by .. ')' or ''))
      end
    end
    local chests = s and try(function() return s.find_entities_filtered{type='logistic-container', position=rec.last_pos, radius=3, force=rec.force} end) or {}
    for _, c in ipairs(chests) do
      local mode = try(function() return c.prototype.logistic_mode end)
      local held = try(function() return c.get_item_count(rec.item) end) or 0
      if mode == 'storage' and held > 0 then
        hop(rec, string.format('robot #%s put it into %s %s', tostring(rec.robot_no), c.name, at(c.position)))
        rec.state, rec.robot, rec.chest, rec.chest_count, rec.since = 'stored', nil, c, held, game.tick
        return
      end
    end
    done(rec, string.format('robot #%s no longer holds it at %s: no ghost of it built there and no storage chest within 3 tiles holding it', tostring(rec.robot_no), at(rec.last_pos)))
  end
  local function stored(rec)
    local c = rec.chest
    if not (c and c.valid) then return done(rec, 'the storage chest is gone') end
    local n = try(function() return c.get_item_count(rec.item) end) or 0
    if n < rec.chest_count then
      local taker
      for _, b in ipairs(try(function() return c.surface.find_entities_filtered{type='construction-robot', position=c.position, radius=8, force=rec.force} end) or {}) do
        if cargo(b, rec.item) > 0 then taker = b; break end
      end
      if taker and #rec.hops < M.HOPS + 1 then
        hop(rec, string.format('construction robot #%s took %s from %s %s', tostring(taker.unit_number), rec.item, c.name, at(c.position)))
        rec.state, rec.robot, rec.robot_no, rec.chest, rec.ghost, rec.since = 'carried', taker, taker.unit_number, nil, nil, game.tick
        rec.last_pos = {x=taker.position.x, y=taker.position.y}
        return
      end
      if n == 0 then return done(rec, string.format('it left %s %s with no construction robot of ours seen holding it within 8 tiles (a logistic robot, an inserter or a player)', c.name, at(c.position))) end
    end
    rec.chest_count = n
    if game.tick - rec.since > M.STORED then done(rec, string.format('still in %s %s (no longer watched)', c.name, at(c.position))) end
  end
  function M.tick()
    for _, rec in ipairs(store().list) do
      if rec.state == 'carried' then pcall(follow, rec)
      elseif rec.state == 'stored' then pcall(stored, rec) end
    end
  end
  -- Lines for an item (or an entity of that name), newest first.
  function M.lines(item, surface)
    local out = {}
    local list = store().list
    for i = #list, 1, -1 do
      local r = list[i]
      if (r.item == item or r.name == item or (r.items or ''):find(item .. '*', 1, true)) and (not surface or r.surface == surface) then
        out[#out+1] = string.format('#%d %s at %s on %s, deconstructed %s ago: robot #%s took %s; %s%s', r.id, r.name, at(r.position), r.surface,
          ago(game.tick - r.tick), tostring(r.first_robot), r.items, #r.hops > 0 and table.concat(r.hops, '; ') or 'carried, followed now',
          (r.state == 'carried' or r.state == 'stored') and ' (still followed)' or '')
        if #out >= 6 then break end
      end
    end
    return out
  end
  return M
end
