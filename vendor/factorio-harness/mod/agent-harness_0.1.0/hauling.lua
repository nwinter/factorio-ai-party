-- Hand hauling (operator 05:00, viewer Joonazan: "a counter for how much
-- manual hauling each bot has done"): per agent since the save began, the
-- items moved by hand and the calls that moved them, split by who started the
-- call (a direct request, a queue step, a standing order's step), the carry
-- distance, and the hauls repeated most. The stream reads it as `operator`
-- (hauling) every few minutes and keeps the rows in the run folder; the site
-- and the stream card take a shift's numbers as the difference.
-- Counted: every hand transfer that moved items (transfer either way, collect,
-- feed, refuel, rearm: runtime.lua transfer_one) and every pickup from the
-- ground (runtime.lua finish). A call counts once, on its first move.
-- Carry distance: per item, the straight line from the spot it was last taken
-- or put to the spot it is put now (a chain of puts adds each leg; one put of
-- several items adds its longest leg), legs on one surface up to LEG_MAX tiles.
-- Repeated hauls: puts grouped by item, the CELL-tile cells of the spot it was
-- last taken from (none when it was not taken from an entity or the ground)
-- and of the spot it went to; at most KEEP per agent, the fewest dropped.
return function(api)
  local M = {}
  local LEG_MAX, CELL, KEEP, TOP = 400, 10, 100, 10
  local running = {}   -- index -> the call running now {src=...}: set and cleared within one request or step
  local function rec(index)
    local s = api.state()
    s.hauling = s.hauling or {}
    local a = s.hauling[index]
    if not a then
      a = {items=0, calls=0, direct={items=0, calls=0}, queue={items=0, calls=0}, order={items=0, calls=0},
        carry=0, take={}, at={}, hauls={}, since=game.tick}
      s.hauling[index] = a
    end
    return a
  end
  -- A direct request (runtime.lua dispatch) or a queue step (scheduler.lua) runs from begin to done. A timed
  -- action it started (a walking collect, a feed waiting for a craft, a pickup) moves items later, on ticks: it
  -- carries the call's source and whether the call was counted.
  function M.begin(index, src) running[index] = {src=src} end
  function M.done(index)
    local r = running[index]
    running[index] = nil
    local act = r and api.active and api.active(index)
    if act and act.hauling_src == nil then act.hauling_src, act.hauling_counted = r.src, r.hauling_counted end
  end
  local function action_src(index, act)
    if act.hauling_src == nil then
      act.hauling_src = act.queued and (api.order_step and api.order_step(index) and 'order' or 'queue') or 'direct'
    end
    return act.hauling_src
  end
  -- Who started what moves items now: the action given (a pickup's end), the call running, else the running timed
  -- action.
  local function context(index, given)
    if given then return given, action_src(index, given) end
    local r = running[index]
    if r then return r, r.src end
    local act = api.active and api.active(index)
    if act then return act, action_src(index, act) end
    return nil, 'direct'
  end
  local function cell(pos) return math.floor(pos.x / CELL) .. ',' .. math.floor(pos.y / CELL) end
  local function dist(u, v) return math.sqrt((u.x - v.x) ^ 2 + (u.y - v.y) ^ 2) end
  -- Items moved at pos (an entity's position, or the character's for a pickup) on surface: to_player takes, else puts.
  function M.moved(index, direction, pos, surface, stacks, entity_name, given)
    if type(stacks) ~= 'table' or #stacks == 0 or not pos then return end
    local a = rec(index)
    local ctx, src = context(index, given)
    local n = 0
    for _, st in ipairs(stacks) do n = n + (st.count or 0) end
    if n <= 0 then return end
    a.items = a.items + n
    -- shells into an artillery piece: who loaded it (artycam.lua)
    if direction ~= 'to_player' and api.put and entity_name then pcall(api.put, api.name and api.name(index) or tostring(index), pos, surface, stacks, entity_name) end
    a[src].items = a[src].items + n
    if ctx and not ctx.hauling_counted then
      ctx.hauling_counted = true
      a.calls = a.calls + 1
      a[src].calls = a[src].calls + 1
    end
    local here = {x=math.floor(pos.x + 0.5), y=math.floor(pos.y + 0.5), s=surface}
    local leg = 0
    for _, st in ipairs(stacks) do
      local name = st.name
      local prev = a.at[name]
      if direction ~= 'to_player' and prev and prev.s == surface then
        local d = dist(prev, here)
        if d <= LEG_MAX and d > leg then leg = d end
      end
      a.at[name] = here
      if direction == 'to_player' then
        a.take[name] = here
      else
        local from = a.take[name]
        if from and from.s ~= surface then from = nil end
        local key = name .. '|' .. tostring(surface) .. '|' .. (from and cell(from) or '-') .. '>' .. cell(here)
        local h = a.hauls[key]
        if not h then
          h = {item=name, s=surface, from=from and {x=from.x, y=from.y} or nil, to={x=here.x, y=here.y}, to_name=entity_name, n=0, items=0}
          a.hauls[key] = h
          a.haul_count = (a.haul_count or 0) + 1
          if a.haul_count > KEEP then
            local low, low_key
            for k, v in pairs(a.hauls) do
              if k ~= key and (not low or v.n < low.n) then low, low_key = v, k end
            end
            if low_key then a.hauls[low_key] = nil; a.haul_count = a.haul_count - 1 end
          end
        end
        h.n = h.n + 1
        h.items = h.items + (st.count or 0)
        h.last = game.tick
      end
    end
    a.carry = a.carry + leg
  end
  -- Operator read: every agent's totals and its most repeated hauls.
  local function read(a)
    a = a or {}
    local top = a.top or TOP
    assert(type(top) == 'number' and top >= 0 and top <= 50, 'top must be 0..50')
    local out = {}
    for index, r in pairs(api.state().hauling or {}) do
      local rows = {}
      for key, h in pairs(r.hauls) do rows[#rows+1] = {key=key, h=h} end
      table.sort(rows, function(x, y) return x.h.n > y.h.n or (x.h.n == y.h.n and x.key < y.key) end)
      local hauls = {}
      for i = 1, math.min(top, #rows) do
        local h = rows[i].h
        hauls[i] = {item=h.item, surface=h.s, from=h.from, to=h.to, to_name=h.to_name, times=h.n, items=h.items}
      end
      out[#out+1] = {name=api.name(index), items=r.items, calls=r.calls,
        direct_items=r.direct.items, direct_calls=r.direct.calls, queue_items=r.queue.items, queue_calls=r.queue.calls,
        order_items=r.order.items, order_calls=r.order.calls, carry_tiles=math.floor(r.carry + 0.5), since_tick=r.since,
        hauls=#hauls > 0 and hauls or nil}
    end
    table.sort(out, function(x, y) return tostring(x.name) < tostring(y.name) end)
    return {agents=out, tick=game.tick}
  end
  -- (d17 batch35 D5, viewer Aurora 14:47) what feeds a haul's destination the item without hands now: inserters dropping
  -- into it (from a belt, chest or machine, and whether that source holds the item now), its requester or buffer
  -- request for the item, a silo's automatic requests, robots bringing it. rows: [{agent, item, surface, to={x,y},
  -- to_name}], at most 16; one entity lookup and one inserter search of its box widened by 3 tiles each. Read only.
  local function name_of(v) return type(v) == 'table' and v.name or v end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function feed_one(r)
    local s = r.surface and game.get_surface(r.surface)
    if not s or type(r.to) ~= 'table' then return {agent=r.agent, item=r.item, line='no surface ' .. tostring(r.surface)} end
    local pos = {x=(r.to.x or 0), y=(r.to.y or 0)}
    local found = s.find_entities_filtered{area={{pos.x - 1, pos.y - 1}, {pos.x + 1, pos.y + 1}}, name=r.to_name, limit=4}
    local e = found[1]
    if not (e and e.valid) then
      return {agent=r.agent, item=r.item, line=string.format('no %s at (%g,%g) now', tostring(r.to_name or 'entity'), pos.x, pos.y)}
    end
    local feeds = {}
    local box = e.bounding_box
    for _, ins in ipairs(s.find_entities_filtered{type='inserter', area={{box.left_top.x - 3, box.left_top.y - 3}, {box.right_bottom.x + 3, box.right_bottom.y + 3}}, limit=48}) do
      if ins.drop_target == e then
        local src = ins.pickup_target
        -- an inserter using filters that leave the item out does not feed it
        local filt
        if try(function() return ins.use_filters end) then
          filt = try(function()
            for i = 1, ins.filter_slot_count do local f = ins.get_filter(i); if f and name_of(f.name) == r.item then return true end end
            return false end)
        end
        if filt ~= false then
          local holds
          if src and src.valid then
            if src.type == 'transport-belt' or src.type == 'underground-belt' or src.type == 'splitter' then
              holds = 0
              for i = 1, try(function() return src.get_max_transport_line_index() end) or 0 do
                holds = holds + (try(function() return src.get_transport_line(i).get_item_count(r.item) end) or 0)
              end
            else
              holds = try(function() return src.get_item_count(r.item) end)
            end
          end
          feeds[#feeds+1] = string.format('%s from %s%s', ins.name, src and src.valid and string.format('%s (%g,%g)', src.name, src.position.x, src.position.y) or 'the ground',
            holds and string.format(' holding %d now', holds) or '')
        end
      end
    end
    local pt = try(function() return e.get_logistic_point(defines.logistic_member_index.logistic_container) end)
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      if name_of(f.name) == r.item and (f.count or 0) > 0 then feeds[#feeds+1] = string.format('its %s request for %d', try(function() return e.prototype.logistic_mode end) or 'logistic', f.count) end
    end
    if e.type == 'rocket-silo' and try(function() return e.use_transitional_requests end) then feeds[#feeds+1] = 'the silo\'s automatic requests (on)' end
    local coming = 0
    for _, p in pairs(try(function() local x = e.get_logistic_point(); if x and x.object_name then return {x} end; return x end) or {}) do
      for _, it in ipairs(try(function() return p.targeted_items_deliver end) or {}) do
        if name_of(it.name) == r.item then coming = coming + (it.count or 0) end
      end
    end
    if coming > 0 then feeds[#feeds+1] = string.format('robots bringing %d now', coming) end
    return {agent=r.agent, item=r.item, entity=e.name, position={x=e.position.x, y=e.position.y}, feeds=feeds,
      line=string.format('%s (%g,%g) on %s, fed %s without hands now: %s', e.name, e.position.x, e.position.y, s.name, r.item,
        #feeds > 0 and table.concat(feeds, '; ') or 'none')}
  end
  local function feed_read(a)
    a = a or {}
    assert(type(a.rows) == 'table' and #a.rows <= 16, 'rows: 1..16 {agent, item, surface, to, to_name}')
    local out = {}
    for i, r in ipairs(a.rows) do
      local ok, row = pcall(feed_one, r)
      out[i] = ok and row or {agent=r.agent, item=r.item, line='not read: ' .. tostring(row)}
    end
    return {rows=out, tick=game.tick}
  end
  M.operator = {hauling=read, haul_feed=feed_read}
  return M
end
