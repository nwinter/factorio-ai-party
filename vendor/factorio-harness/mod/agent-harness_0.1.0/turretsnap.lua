-- turretsnap (d29 batch344 GS, Sol #2750: "Trial31 guard477 fired 81734480 railgun (19.5,-75.5) at 4 ammo; by next
-- readonly inspect gun recovered 10, so cannot distinguish sparse belt, pickup batch latency, control or power"): when
-- an ammo_below guard on a platform fires, the lowest turret and what feeds it, read on that same tick (the condition's
-- check, conditions.lua), kept here and named in the guard's evidence; queue_status {snapshots} lists them a page at a
-- time and {snapshot: id} reads one in full. Read only.
-- - the turret: unit number, name, position, its ammo stacks (item, quality, count) and rounds (a magazine's: the
--   first stack's ammo left plus a full magazine for each other item);
-- - each inserter whose drop target is the turret (at most FEEDERS, found within REACH tiles of its box): unit
--   number, name, position, status, the held stack, its hand settings (stack size override, filters and their mode),
--   pickup and drop targets (name, type, position), its energy and whether its electric network reaches it, its
--   circuit control (disabled by it or not, the condition), and on a belt it picks from each transport line's count of
--   the turret's ammo (and of all items);
-- - the platform: where it is or the leg it flies (from, to, km flown and left) and its speed.
-- A snapshot reads the turret, at most FEEDERS inserters and their pickups: a few hundred API reads at most (measured
-- on a copy: batch344 report). The newest KEEP are kept a force.
return function(api)
  local M = {}
  M.FEEDERS, M.REACH, M.KEEP, M.PAGE = 8, 3, 32, 8
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.guard_snapshots = s.guard_snapshots or {seq=0, list={}}
    return s.guard_snapshots
  end
  local function at(q) return q and {x=q.x, y=q.y} or nil end
  local status_names
  local function status_name(v)
    if v == nil then return nil end
    if not status_names then status_names = {}; for k, x in pairs(defines.entity_status or {}) do status_names[x] = k end end
    return status_names[v] or tostring(v)
  end
  local function target(e)
    if not (e and e.valid) then return nil end
    return {name=e.name, type=e.type, unit_number=e.unit_number, position=at(e.position)}
  end
  -- The turret's ammo: its stacks and rounds.
  local function ammo(t)
    local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
    local stacks, rounds, items = {}, 0, 0
    for i = 1, inv and #inv or 0 do
      local st = inv[i]
      if st.valid_for_read then
        local per = try(function() return prototypes.item[st.name].magazine_size end) or 1
        local left = try(function() return st.ammo end) or per
        stacks[#stacks+1] = {name=st.name, quality=try(function() return st.quality.name end), count=st.count, ammo_in_first=left}
        rounds = rounds + left + (st.count - 1) * per
        items = items + st.count
      end
    end
    return stacks, items, rounds
  end
  local function lanes(b, item)
    local n = try(function() return b.get_max_transport_line_index() end) or 0
    local out = {}
    for i = 1, math.min(n, 4) do
      local line = try(function() return b.get_transport_line(i) end)
      if line then
        out[#out+1] = {line=i, item=item and (try(function() return line.get_item_count(item) end) or 0) or nil,
          all=try(function() return #line end) or nil}
      end
    end
    return out
  end
  local function feeder(i, item)
    local h = try(function() return i.held_stack end)
    local held = h and h.valid_for_read and {name=h.name, count=h.count} or nil
    local filters = {}
    for k = 1, try(function() return i.filter_slot_count end) or 0 do
      local f = try(function() return i.get_filter(k) end)
      if f then filters[#filters+1] = type(f) == 'table' and (f.name or f) or f end
    end
    local cb = try(function() return i.get_control_behavior() end)
    local circuit
    if cb then
      circuit = {disabled=try(function() return cb.disabled end), enable_disable=try(function() return cb.circuit_enable_disable end),
        condition=try(function() local c = cb.circuit_condition; return c and {first=c.first_signal and c.first_signal.name, comparator=c.comparator, constant=c.constant,
          second=c.second_signal and c.second_signal.name} end)}
    end
    local pick = try(function() return i.pickup_target end)
    local row = {unit_number=i.unit_number, name=i.name, position=at(i.position), status=status_name(try(function() return i.status end)), held=held,
      stack_size_override=try(function() local v = i.inserter_stack_size_override; return v and v > 0 and v or nil end),
      filter_mode=try(function() return i.inserter_filter_mode end), filters=#filters > 0 and filters or nil,
      pickup=target(pick), drop=target(try(function() return i.drop_target end)),
      energy=try(function() return math.floor(i.energy + 0.5) end), powered=try(function() return i.is_connected_to_electric_network() end),
      circuit=circuit}
    if pick and pick.valid and (pick.type == 'transport-belt' or pick.type == 'underground-belt' or pick.type == 'splitter') then
      row.pickup_lanes = lanes(pick, item)
    end
    return row
  end
  -- The snapshot of turret t on platform pl now (why: the guard's text). Kept; returns {id, line} for the evidence.
  function M.take(pl, t, why, guard)
    local st = store()
    local stacks, items, rounds = ammo(t)
    local item = stacks[1] and stacks[1].name or nil
    local s = t.surface
    local box = try(function() return t.prototype.collision_box end) or {left_top={x=-1, y=-1}, right_bottom={x=1, y=1}}
    local p = t.position
    local found = try(function() return s.find_entities_filtered{type='inserter', area={{p.x + box.left_top.x - M.REACH, p.y + box.left_top.y - M.REACH},
      {p.x + box.right_bottom.x + M.REACH, p.y + box.right_bottom.y + M.REACH}}} end) or {}
    local feeders, more = {}, 0
    for _, i in ipairs(found) do
      if try(function() return i.drop_target end) == t then
        if #feeders < M.FEEDERS then feeders[#feeders+1] = feeder(i, item) else more = more + 1 end
      end
    end
    local where
    local leg = api.leg and try(function() return api.leg(pl) end)
    if leg then where = {from=leg.from, to=leg.to, flown_km=math.floor((leg.length or 0) - (leg.left_km or 0) + 0.5), left_km=math.floor((leg.left_km or 0) + 0.5)}
    else where = {at=try(function() return pl.space_location.name end)} end
    st.seq = st.seq + 1
    local snap = {id=st.seq, tick=game.tick, force=t.force.name, platform=pl.name, why=why, guard=guard,
      turret={unit_number=t.unit_number, name=t.name, position=at(p), ammo=stacks, items=items, rounds=rounds},
      feeders=feeders, feeders_more=more > 0 and more or nil, leg=where,
      speed_km_s=try(function() return math.floor(pl.speed * 60 * 10 + 0.5) / 10 end)}
    local fl = {}
    for _, f in ipairs(feeders) do
      local ln = {}
      for _, l in ipairs(f.pickup_lanes or {}) do ln[#ln+1] = string.format('line %d: %s', l.line, tostring(l.item)) end
      fl[#fl+1] = string.format('%s (%g,%g) %s, holds %s%s%s', f.name, f.position.x, f.position.y, tostring(f.status), f.held and (f.held.count .. ' ' .. f.held.name) or 'nothing',
        f.pickup and (' from ' .. f.pickup.name .. (#ln > 0 and ' [' .. table.concat(ln, ', ') .. ']' or '')) or ' from nothing',
        f.circuit and f.circuit.disabled and ', disabled by its circuit' or '')
    end
    snap.line = string.format('snapshot #%d at tick %d: %s (%g,%g) on %s holds %d ammo items (%d rounds)%s; %d feeding inserter%s%s%s; %s, %s',
      snap.id, snap.tick, t.name, p.x, p.y, pl.name, items, rounds, item and ' of ' .. item or '', #feeders, #feeders == 1 and '' or 's',
      #fl > 0 and ': ' .. table.concat(fl, '; ') or '', more > 0 and string.format(' (%d more not read)', more) or '',
      where.at and ('at ' .. where.at) or where.from and string.format('flying %s->%s, %d km flown, %d left', where.from, where.to, where.flown_km, where.left_km)
        or 'where unknown (no leg read)',
      snap.speed_km_s and string.format('%g km/s', snap.speed_km_s) or 'speed unknown')
    st.list[#st.list+1] = snap
    local mine, first = 0, nil
    for k, x in ipairs(st.list) do if x.force == snap.force then mine = mine + 1; first = first or k end end
    if mine > M.KEEP and first then table.remove(st.list, first) end
    return {snapshot=snap.id, line=snap.line}
  end
  -- queue_status {snapshots: true, from?} (the force's newest first, PAGE a page: id, tick, platform, turret, line) or
  -- {snapshot: id} (one in full).
  function M.read(p, a)
    local st = store()
    if a.snapshot ~= nil then
      assert(type(a.snapshot) == 'number', 'snapshot: a snapshot\'s id (queue_status {snapshots: true} lists them)')
      for _, x in ipairs(st.list) do if x.id == a.snapshot and x.force == p.force.name then return x end end
      error(string.format('no snapshot #%s kept (the newest %d a force are kept)', tostring(a.snapshot), M.KEEP), 0)
    end
    local mine = {}
    for k = #st.list, 1, -1 do local x = st.list[k]; if x.force == p.force.name then mine[#mine+1] = x end end
    local from = a.from or 1
    assert(type(from) == 'number' and from >= 1 and from == math.floor(from), 'from: the first row, 1 or more (next_from of the page before)')
    local rows = {}
    for k = from, math.min(#mine, from + M.PAGE - 1) do
      local x = mine[k]
      rows[#rows+1] = {id=x.id, tick=x.tick, platform=x.platform, guard=x.guard, turret=x.turret.name .. string.format(' (%g,%g)', x.turret.position.x, x.turret.position.y), line=x.line}
    end
    return {snapshots=rows, total=#mine, next_from=from + M.PAGE <= #mine and from + M.PAGE or nil, keep=M.KEEP,
      note='taken when an ammo_below guard on a platform fired, on that tick; queue_status {snapshot: id} reads one in full'}
  end
  return M
end
