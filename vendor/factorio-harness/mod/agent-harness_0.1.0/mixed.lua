-- (d23 batch123 CF2, viewer Aurora 09:45: "Could measurement watches flag module or feed edits during a test and mark
-- the sample as mixed? Preserve the before/after data and notify its owner to start a clean window.") An edit inside
-- what a running bounded watch measures splits its window at the edit:
-- - what counts: an entity it measures (uptime's machines, turret_tally's turrets, belt_flow's sampled belts) built,
--   mined, destroyed, configured (recipe, modules, filters, ...), rotated, wired, or given or relieved of items by a
--   call (transfer, feed, refuel, rearm) or a ctrl-click; a feeder of one built, mined, destroyed or configured (an
--   inserter or mining drill dropping into it or taking from it, a loader touching it, a beacon whose supply area reaches
--   it; for belt_flow a belt, splitter, loader or inserter within a tile of the line's box); on a platform
--   (collector_tally, asteroid_watch, flight_watch while it watches) any turret, collector, thruster, beacon or feed
--   (inserter, loader, belt) there;
-- - where it is seen: the harness's own builds, mines and the calls above (any agent's), and the events control.lua
--   forwards (on_built_entity, on_player_mined_entity, on_robot_mined_entity, on_entity_died, on_player_fast_transferred,
--   on_gui_opened/on_gui_closed with a recipe or module change between them). Not seen: a construction robot's build or a
--   platform's own build (control.lua forwards no event of them), a circuit's own changes;
-- - what happens: the watch's read up to the edit is kept (mixed.parts: from, to, its line and lines; an asteroid_watch
--   and an uptime watch keep the whole closed watch as a segment, read by segment_start; a window begun on the edit's
--   own tick keeps no part), and the watch
--   starts again from the edit tick with the same arguments to its end tick (flight_watch: its counts begun again, to
--   its arrival or limit); when that start is refused (too few seconds left, the call refused), or an entity it
--   measures was mined or destroyed, the watch ends at the edit and its final is that part. mixed.edits names each
--   edit (tick, what, by, the entity, how it touches the watch); the watch's owner hears each split once.
-- No tick work: the events and calls only, and a call or event does nothing while no watch runs (a signature of the
-- running watches is compared; the index of what they measure is made again when it changes).
return function(api)
  local M = {}
  M.KINDS = {'uptime', 'turret_tally', 'belt_flow', 'collector_tally', 'asteroid_watch'}
  M.EDITS, M.PARTS, M.LINES, M.PART_LINES = 6, 3, 3, 64
  -- the fewest seconds a kind's start takes (its handler's own lower bound)
  M.MIN = {uptime=10, turret_tally=5, belt_flow=2, collector_tally=10, asteroid_watch=10}
  local FEED = {inserter=true, loader=true, ['loader-1x1']=true, beacon=true, ['mining-drill']=true}
  local BELT = {['transport-belt']=true, ['underground-belt']=true, splitter=true, loader=true, ['loader-1x1']=true, ['linked-belt']=true, inserter=true}
  local PLATFORM = {['ammo-turret']=true, ['electric-turret']=true, ['fluid-turret']=true, ['artillery-turret']=true, ['asteroid-collector']=true,
    inserter=true, loader=true, ['loader-1x1']=true, ['transport-belt']=true, ['underground-belt']=true, splitter=true, thruster=true, beacon=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function at(q) return q and string.format('(%g,%g)', r1(q.x), r1(q.y)) or '?' end
  local function store()
    local s = api.state()
    s.mixed = s.mixed or {lines={}}
    return s.mixed
  end
  -- An entity as the index reads it; e may already be one (a mine's, taken before it went).
  function M.describe(e)
    if type(e) == 'table' and e.described then return e end
    if not (e and e.valid) then return nil end
    local bb = e.bounding_box
    local d = {described=true, surface=e.surface.index, name=e.name, type=e.type, unit_number=e.unit_number, position={x=e.position.x, y=e.position.y},
      box={bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y}, force=e.force and e.force.name}
    if e.type == 'inserter' or e.type == 'mining-drill' then
      d.drop = try(function() local q = e.drop_position; return {x=q.x, y=q.y} end)
      if e.type == 'inserter' then d.pickup = try(function() local q = e.pickup_position; return {x=q.x, y=q.y} end) end
    elseif e.type == 'beacon' then
      d.supply = try(function() return e.prototype.get_supply_area_distance(e.quality) end) or try(function() return e.prototype.get_supply_area_distance() end) or 3
    end
    return d
  end
  local function inside(q, b) return q and q.x >= b[1] and q.x <= b[3] and q.y >= b[2] and q.y <= b[4] end
  local function overlap(a, b, m) return a[1] - m <= b[3] and a[3] + m >= b[1] and a[2] - m <= b[4] and a[4] + m >= b[2] end
  -- The running watches: a signature, and the index of what each measures (kept in storage, so every peer reads the same).
  local function signature()
    local s, parts = api.state(), {}
    for _, k in ipairs(M.KINDS) do
      for idx, job in pairs(s[k] or {}) do
        if type(job) == 'table' and not job.result and job.until_tick and game.tick <= job.until_tick then parts[#parts+1] = k .. idx .. ':' .. job.start end
      end
    end
    for _, w in ipairs(s.flightwatch and s.flightwatch.list or {}) do
      if w.state == 'watching' then parts[#parts+1] = 'f' .. w.id .. ':' .. tostring(w.start) end
    end
    return table.concat(parts, ',')
  end
  local function units_of(entry, ents)
    entry.units, entry.boxes = {}, {}
    for _, e in ipairs(ents) do
      if e and e.valid then
        entry.surface = entry.surface or e.surface.index
        local bb = e.bounding_box
        local b = {bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y}
        if e.unit_number then entry.units[e.unit_number] = true end
        entry.boxes[#entry.boxes+1] = b
        local u = entry.box
        entry.box = u and {math.min(u[1], b[1]), math.min(u[2], b[2]), math.max(u[3], b[3]), math.max(u[4], b[4])} or {b[1], b[2], b[3], b[4]}
      end
    end
  end
  local function build()
    local s, list = api.state(), {}
    for _, k in ipairs(M.KINDS) do
      for idx, job in pairs(s[k] or {}) do
        if type(job) == 'table' and not job.result and job.until_tick and game.tick <= job.until_tick then
          local entry = {kind=k, index=idx, job=job}
          if k == 'uptime' then
            local ents = {}
            for _, m in ipairs(job.machines or {}) do ents[#ents+1] = m.e end
            units_of(entry, ents); entry.types = FEED
          elseif k == 'turret_tally' then
            local ents = {}
            for _, t in ipairs(job.turrets or {}) do ents[#ents+1] = t.e end
            units_of(entry, ents); entry.types = FEED
          elseif k == 'belt_flow' then
            local ents = {}
            for _, pt in ipairs(job.points or {}) do ents[#ents+1] = pt.entity end
            units_of(entry, ents); entry.types, entry.line = BELT, true
            local f, t = job.path_from, job.path_to
            if f and t and entry.box then
              local b = entry.box
              entry.box = {math.min(b[1], f.x, t.x) - 1, math.min(b[2], f.y, t.y) - 1, math.max(b[3], f.x, t.x) + 1, math.max(b[4], f.y, t.y) + 1}
            end
          else
            entry.surface, entry.whole, entry.types = job.surface, true, PLATFORM
          end
          if entry.surface then list[#list+1] = entry end
        end
      end
    end
    for _, w in ipairs(s.flightwatch and s.flightwatch.list or {}) do
      if w.state == 'watching' then
        local sf = try(function() return w.pl.surface.index end) or try(function() return game.forces[w.force].platforms[w.index].surface.index end)
        if sf then list[#list+1] = {w=w, kind='flight_watch', surface=sf, whole=true, types=PLATFORM} end
      end
    end
    return list
  end
  local function watches()
    local sig = signature()
    if sig == '' then return nil end
    local st = store()
    if st.sig ~= sig then st.sig, st.index = sig, build() end
    return st.index
  end
  M.watches = watches
  -- How edit d touches entry: 'measured', 'feeds it' or 'on the platform', or nil.
  local function touches(entry, d)
    if d.surface ~= entry.surface then return nil end
    if d.unit_number and entry.units and entry.units[d.unit_number] then return entry.line and 'a belt it samples' or 'what it measures' end
    if not entry.types[d.type] then return nil end
    if entry.whole then return 'on the platform it watches' end
    if entry.line then return overlap(d.box, entry.box, 0) and 'on the belt line it samples' or nil end
    for _, b in ipairs(entry.boxes) do
      if (d.drop and inside(d.drop, b)) or (d.pickup and inside(d.pickup, b)) then return 'feeds what it measures' end
      if d.supply and overlap(d.box, b, d.supply) then return 'a beacon reaching what it measures' end
      if (d.type == 'loader' or d.type == 'loader-1x1') and overlap(d.box, b, 0.5) then return 'feeds what it measures' end
    end
  end
  local function tell(name, text)
    local st = store()
    st.lines[name] = st.lines[name] or {}
    local l = st.lines[name]
    l[#l+1] = text
    while #l > M.LINES do table.remove(l, 1) end
  end
  local function copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end
  -- The kept part: its line and lines, from a read of the watch as it stood at the edit.
  local function part(read, from, to)
    local lines = {}
    for k, l in ipairs(type(read) == 'table' and type(read.lines) == 'table' and read.lines or {}) do
      if k > M.PART_LINES then lines[#lines+1] = string.format('+%d more', #read.lines - M.PART_LINES); break end
      lines[k] = l
    end
    -- (d25 batch212 QX1) a flight watch's part keeps its ammunition and repair packs used, read at from and to
    local fw = type(read) == 'table' and read or {}
    return {from_tick=from, to_tick=to, line=type(read) == 'table' and (read.line or read.note) or nil, lines=#lines > 0 and lines or nil,
      ammunition=fw.ammunition, repair_packs_used=fw.repair_packs_used, foundation=fw.foundation}  -- (d25 batch216 QAA1) its foundation too
  end
  local function summary(mx)
    local e = mx.edits[1]
    return string.format('mixed: %d edit%s during the window, the first at tick %d (%s, %s); %s', #mx.edits, #mx.edits == 1 and '' or 's',
      e.tick, e.text, e.how, mx.ended and 'the watch ended at the edit (' .. mx.ended .. '): its final is the part before it'
        or #mx.parts == 0 and string.format('this window runs from tick %d', mx.from_tick)
        or string.format('the read up to tick %d is kept apart (mixed.parts); this window runs from tick %d', mx.parts[#mx.parts].to_tick, mx.from_tick))
  end
  local function merged(old, rec)
    local mx = old and old.mixed and {edits=copy(old.mixed.edits), parts=copy(old.mixed.parts)} or {edits={}, parts={}}
    mx.edits[#mx.edits+1] = rec
    while #mx.edits > M.EDITS do table.remove(mx.edits, 1) end
    return mx
  end
  local function split(entry, rec)
    local tick = game.tick
    if entry.kind == 'flight_watch' then
      local w = entry.w
      local mx = merged(w, rec)
      local ok, before = pcall(api.flight_rebase, w, tick)
      if ok and before then
        mx.parts[#mx.parts+1] = part(before, before.start_tick or w.start, tick)
        while #mx.parts > M.PARTS do table.remove(mx.parts, 1) end
        mx.from_tick = tick
      else mx.ended = 'its counts could not begin again: ' .. tostring(before) end
      mx.line = summary(mx)
      w.mixed = mx
      tell(w.setter, string.format('your flight watch #%d on %s: %s', w.id, w.platform, mx.line))
      return
    end
    local job, kind = entry.job, entry.kind
    local p = api.player(entry.index)
    local mx = merged(job, rec)
    local left = math.floor((job.until_tick - tick) / 60)
    local why
    if rec.gone then why = rec.gone
    elseif not job.call then why = 'it was started before this change'
    elseif left < M.MIN[kind] then why = string.format('%d s left, fewer than the %d a new %s takes', left, M.MIN[kind], kind)
    elseif not (p and p.valid) then why = 'its agent is not here' end
    local new
    if not why then
      local args = copy(job.call.args)
      args.seconds, args.reason = left, job.reason
      local ok, err = pcall(api.call, p, job.call.action, args)
      new = api.state()[kind][entry.index]
      if not ok or new == job then why, new = 'the new start was refused: ' .. tostring(err), nil end
    end
    if new and job.start == tick then
      -- (d25 batch219 QAD1: two configure steps of one queue on one tick split Sol's uptime watch twice, and the second
      -- kept a part of no ticks, one of the 3 kept) a window begun on this tick holds nothing: begun again, no part
      new.segments, new.segments_dropped = job.segments, job.segments_dropped
      mx.from_tick, new.call, new.mixed = tick, job.call, mx
    elseif new then
      -- (d25 batch200 QM1) a kind that keeps the whole closed watch (api.close: asteroid_watch's and uptime's segments) reads it so
      local close = api.close and api.close[kind]
      local okr, before = false, nil
      if close then okr, before = pcall(close, job, new, tick, rec.text) end
      if not okr then okr, before = pcall(api.read[kind], job) end
      mx.parts[#mx.parts+1] = part(okr and before or nil, job.start, tick)
      if close and okr and type(before) == 'table' and before.segment_start then mx.parts[#mx.parts].segment_start = before.segment_start end
      while #mx.parts > M.PARTS do table.remove(mx.parts, 1) end
      mx.from_tick, new.call, new.mixed = tick, job.call, mx
    else
      mx.ended = why
      job.until_tick, job.next_tick = tick, math.min(job.next_tick or tick, tick)
      job.mixed = mx
    end
    mx.line = summary(mx)
    local who = api.who_index and api.who_index(entry.index)
    if who then tell(who, string.format('your %s watch (started tick %d): %s', kind, job.start, mx.line)) end
  end
  -- An edit: d an entity (or its description), what was done and by whom ('configure modules by sonnet'); removed: it
  -- is going (mined, destroyed), so a watch measuring it ends at the edit rather than start again with it.
  function M.edit(e, what, removed)
    local list = watches()
    if not list then return 0 end
    if type(e) == 'userdata' and not (e.valid and e.force.name == 'player') then return 0 end
    local d = M.describe(e)
    if not d or (d.force and d.force ~= 'player') then return 0 end
    local n = 0
    for _, entry in ipairs(list) do
      local how = touches(entry, d)
      if how then
        local holder = entry.w or entry.job
        local last = holder.mixed and holder.mixed.edits[#holder.mixed.edits]
        -- one change seen twice (a call and its event) splits once
        if not (last and last.tick == game.tick and last.unit_number == d.unit_number) then
          local gone = removed and entry.units and entry.units[d.unit_number] and string.format('%s %s it measured is gone', d.name, at(d.position)) or nil
          split(entry, {tick=game.tick, text=what .. ' on ' .. d.name .. ' ' .. at(d.position), how=how, unit_number=d.unit_number, gone=gone})
          n = n + 1
          store().sig = nil
        end
      end
    end
    return n
  end
  -- A call's targets: the entities at its position(s) on its surface.
  function M.at(surface, positions, what)
    if not watches() or not surface then return 0 end
    local n = 0
    for k, q in ipairs(positions) do
      if k > 64 then break end
      local x, y = q.x or q[1], q.y or q[2]
      if type(x) == 'number' and type(y) == 'number' then
        for _, e in ipairs(surface.find_entities_filtered{position={x, y}, force='player'}) do n = n + M.edit(e, what) end
      end
    end
    return n
  end
  -- (on_gui_opened/closed) a measured machine's recipe and modules as the GUI was opened, compared at close.
  local function print_of(e)
    local r = try(function() local x, q = e.get_recipe(); return x and (x.name .. '@' .. tostring(q and q.name or q)) end) or ''
    local inv = try(function() return e.get_module_inventory() end)
    local m = {}
    for _, it in ipairs(inv and try(function() return inv.get_contents() end) or {}) do m[#m+1] = it.name .. '@' .. tostring(it.quality) .. '*' .. it.count end
    table.sort(m)
    return r .. '|' .. table.concat(m, ',')
  end
  function M.gui(event, opened)
    local e = event.entity
    if not (e and e.valid and watches()) then return end
    local st = store()
    st.gui = st.gui or {}
    if opened then st.gui[event.player_index] = {unit=e.unit_number, print=print_of(e)}; return end
    local g = st.gui[event.player_index]
    st.gui[event.player_index] = nil
    if g and g.unit == e.unit_number and g.print ~= print_of(e) then
      local p = game.get_player(event.player_index)
      M.edit(e, 'recipe or modules changed in its window by ' .. (p and p.name or 'a player'))
    end
  end
  -- The forwarded events (control.lua) this reads.
  M.events = {}
  for _, n in ipairs{'on_built_entity', 'on_player_mined_entity', 'on_robot_mined_entity', 'on_entity_died', 'on_player_fast_transferred', 'on_gui_opened', 'on_gui_closed'} do
    if defines and defines.events and defines.events[n] then M.events[defines.events[n]] = n end
  end
  local function name_of(index) local p = index and game.get_player(index); return p and p.name or 'a player' end
  function M.on_event(event)
    local n, e = M.events[event.name], event.entity
    if not (n and e and e.valid) then return end
    if n == 'on_gui_opened' or n == 'on_gui_closed' then return M.gui(event, n == 'on_gui_opened') end
    -- most deaths are not ours (asteroids, biters): the force first
    if e.force.name ~= 'player' or not watches() then return end
    local what
    if n == 'on_built_entity' then what = 'built by ' .. name_of(event.player_index)
    elseif n == 'on_player_mined_entity' then what = 'mined by ' .. name_of(event.player_index)
    elseif n == 'on_robot_mined_entity' then what = 'mined by a construction robot'
    elseif n == 'on_entity_died' then what = 'destroyed' .. (event.cause and event.cause.valid and ' by ' .. event.cause.name or '')
    else what = (event.from_player and 'items put in' or 'items taken out') .. ' by ' .. name_of(event.player_index) .. ' (ctrl-click)' end
    M.edit(e, what, n ~= 'on_built_entity' and n ~= 'on_player_fast_transferred')
  end
  -- The watch's mixed record for a read, or nil.
  function M.view(holder)
    local mx = holder and holder.mixed
    if not mx then return nil end
    local edits = {}
    for k, e in ipairs(mx.edits) do edits[k] = string.format('tick %d: %s (%s)', e.tick, e.text, e.how) end
    return {line=mx.line, edits=edits, parts=mx.parts, from_tick=mx.from_tick, ended=mx.ended}
  end
  -- The owner's lines (team.alerts), once.
  function M.lines(p, h)
    local who = api.who and api.who(p)
    local st = api.state().mixed
    local l = who and st and st.lines[who]
    if not l or #l == 0 then return nil end
    st.lines[who] = nil
    return l
  end
  return M
end
