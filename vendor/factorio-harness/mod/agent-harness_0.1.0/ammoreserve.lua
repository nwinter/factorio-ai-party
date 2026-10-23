-- A platform's whole ammunition reserve, read in the background for wait_until/guard platform_ammo_below (d22 batch117
-- BZ1, Astra #1970: a full-edge abort must keep the return leg's ammunition; item_count with platform reads the hub
-- alone and ammo_below each turret alone). One pass reads every place aboard once, as the player could open each:
-- the hub's main inventory, each ammo turret's ammo slots, each belt's transport lines (an underground exit's buried
-- lines are its entrance's: once), each inserter's hand, each assembling machine's and furnace's output, each chest.
-- Each entity is read once a pass (walk.lua keeps an entity in the band its position falls in), so nothing is counted
-- twice within one reading; an item moved from one place to another while a pass runs (a pass on Asterion's 6743
-- belts takes about 1.5 s) can be counted in both or in neither.
-- A platform is read while a condition asked about it within KEEP ticks: a pass begins EVERY ticks after the last one
-- began, one pass at a time over all platforms; a step every STEP ticks reads at most BAND entities, after finding at
-- most BANDS bands (one chunk each) while those found are none. The hub is read on the pass's last step. A reading
-- keeps every ammo item by name and quality and place, its start and end ticks and the entities it read.
return function(api)
  local M = {}
  M.STEP, M.BAND, M.BANDS, M.EVERY, M.KEEP, M.PICK = 1, 100, 8, 1800, 36000, 60
  M.MAX_AGE, M.MAX_AGE_LOW, M.MAX_AGE_HIGH = 120, 30, 900  -- seconds: a reading older than this is stale
  M.PLACES = {'hub', 'turrets', 'belts', 'hands', 'machines', 'chests'}
  local BELTS = {['transport-belt']=true, ['underground-belt']=true, splitter=true, loader=true, ['loader-1x1']=true, ['lane-splitter']=true, ['linked-belt']=true}
  local TYPES = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'lane-splitter', 'linked-belt', 'inserter', 'ammo-turret',
    'assembling-machine', 'furnace', 'container'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function secs(t)
    local s = math.max(0, math.floor(t / 60 + 0.5))
    if s >= 3600 then return string.format('%dh%02dm%02ds', math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60) end
    if s >= 60 then return string.format('%dm%02ds', math.floor(s / 60), s % 60) end
    return s .. 's'
  end
  M.secs = secs
  local AMMO = {}  -- item name -> whether it is ammunition (prototype reads kept)
  local function is_ammo(name)
    local v = AMMO[name]
    if v == nil then
      local p = prototypes.item[name]
      v = p ~= nil and p.type == 'ammo'
      AMMO[name] = v
    end
    return v
  end
  local walker
  local function walk() walker = walker or api.walk or require('walk'){state=api.state}; return walker end
  local function store()
    local s = api.state()
    s.ammo_reserve = s.ammo_reserve or {plats={}}
    return s.ammo_reserve
  end
  local function platform(force, index)
    local f = game.forces[force]
    for _, pl in pairs(f and try(function() return f.platforms end) or {}) do if pl.index == index then return pl end end
  end
  local function put(job, place, name, quality, n)
    if not (n and n > 0 and is_ammo(name)) then return end
    if type(quality) ~= 'string' then quality = quality and quality.name or 'normal' end
    local byq = job.counts[name] or {}
    job.counts[name] = byq
    local row = byq[quality] or {}
    byq[quality] = row
    row[place] = (row[place] or 0) + n
  end
  local function contents(job, place, inv)
    for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do put(job, place, r.name, r.quality, r.count) end
  end
  local function read(job, e)
    local t = e.type
    if BELTS[t] then
      job.ents.belts = job.ents.belts + 1
      local lines = try(function() return e.get_max_transport_line_index() end) or 0
      local partner = t == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'output'
        and try(function() local n = e.neighbours; return n and n.valid and n or nil end)
      for i = 1, lines do
        local line = try(function() return e.get_transport_line(i) end)
        local same = partner and i > 2 and try(function() return line.line_equals(partner.get_transport_line(i)) end)
        if line and not same then contents(job, 'belts', line) end
      end
    elseif t == 'inserter' then
      job.ents.inserters = job.ents.inserters + 1
      local h = try(function() return e.held_stack end)
      if h and try(function() return h.valid_for_read end) then put(job, 'hands', h.name, h.quality, h.count) end
    elseif t == 'ammo-turret' then
      job.ents.turrets = job.ents.turrets + 1
      contents(job, 'turrets', try(function() return e.get_inventory(defines.inventory.turret_ammo) end))
    elseif t == 'container' then
      job.ents.chests = job.ents.chests + 1
      contents(job, 'chests', try(function() return e.get_inventory(defines.inventory.chest) end))
    else
      job.ents.machines = job.ents.machines + 1
      contents(job, 'machines', try(function() return e.get_output_inventory() end))
    end
  end
  -- The next platform to read: wanted within KEEP, its reading the oldest and begun EVERY ago or more; records not
  -- wanted within KEEP are dropped.
  local function pick(st, tick)
    local best, best_age
    for idx, rec in pairs(st.plats) do
      if tick - rec.wanted > M.KEEP then st.plats[idx] = nil
      else
        local age = rec.done and tick - rec.done.start or math.huge
        if age >= M.EVERY and (not best or age > best_age) then best, best_age = idx, age end
      end
    end
    if next(st.plats) == nil then api.state().ammo_reserve = nil; return end
    if not best then return end
    local rec = st.plats[best]
    local pl = platform(rec.force, best)
    local s = pl and pl.valid and pl.surface
    if not s then st.plats[best] = nil; return end
    local box
    for c in s.get_chunks() do
      if not box then box = {left=c.x, right=c.x, top=c.y, bottom=c.y}
      else box.left, box.right = math.min(box.left, c.x), math.max(box.right, c.x); box.top, box.bottom = math.min(box.top, c.y), math.max(box.bottom, c.y) end
    end
    rec.job = {start=tick, surface=s, hub=pl.hub, force=pl.force, counts={}, ents={belts=0, inserters=0, turrets=0, machines=0, chests=0},
      walk=box and {surface=s.index, box=box, x=box.left, y=box.top, rows=1, band_rows=1, cols=1, max=1} or nil, queue={}, qi=1}
    st.active = best
  end
  local function finish(rec, job, tick)
    local hub = job.hub
    if hub and hub.valid then contents(job, 'hub', try(function() return hub.get_inventory(defines.inventory.hub_main) end)) end
    rec.done = {start=job.start, finish=tick, counts=job.counts, ents=job.ents}
    rec.job = nil
  end
  function M.tick(tick)
    local st = api.state().ammo_reserve
    if not st then return end
    local rec = st.active and st.plats[st.active]
    local job = rec and rec.job
    if not job then
      st.active = nil
      if tick % M.PICK == 0 then pick(st, tick) end
      return
    end
    if tick % M.STEP ~= 0 then return end
    local s = job.surface
    if not (s and s.valid) then rec.job, st.active = nil, nil; return end
    if job.qi > #job.queue then
      job.queue, job.qi = {}, 1
      for _ = 1, M.BANDS do
        local band = job.walk and walk().band(job.walk, s, {force=job.force, type=TYPES})
        if not band then job.walked = true; break end
        for _, e in ipairs(band) do job.queue[#job.queue+1] = e end
        if #job.queue > 0 then break end
      end
      if job.walked and #job.queue == 0 then finish(rec, job, tick); st.active = nil; return end
    end
    local last = math.min(#job.queue, job.qi + M.BAND - 1)
    for i = job.qi, last do
      local e = job.queue[i]
      if e.valid then read(job, e) end
    end
    job.qi = last + 1
  end
  -- Asked about pl (a condition's check): the record, kept fresh.
  function M.want(pl, force)
    local st = store()
    local rec = st.plats[pl.index]
    if not rec then rec = {name=pl.name, force=force.name, first=game.tick}; st.plats[pl.index] = rec end
    rec.wanted, rec.name = game.tick, pl.name
    return rec
  end
  -- One item's count by place in a reading: quality nil (normal), a quality name, or "any" (every quality).
  function M.places(done, item, quality)
    local out, total = {}, 0
    for _, place in ipairs(M.PLACES) do out[place] = 0 end
    for q, row in pairs(done.counts[item] or {}) do
      if quality == 'any' or q == (quality or 'normal') then
        for place, n in pairs(row) do out[place] = out[place] + n; total = total + n end
      end
    end
    return out, total
  end
  local function places_text(out)
    local parts = {}
    for _, place in ipairs(M.PLACES) do if out[place] > 0 then parts[#parts+1] = place .. ' ' .. out[place] end end
    return #parts > 0 and table.concat(parts, ', ') or 'none aboard'
  end
  -- platform_ammo_below {platform, item, count, quality?, max_age?}: met when the newest reading holds fewer than count
  -- of the item (of that quality) aboard; also met (stale) when that reading began more than max_age seconds ago, or
  -- when there is none max_age seconds after the platform's first check; not met while the first pass runs within it.
  function M.check(pl, force, c)
    local rec = M.want(pl, force)
    local max_age = (c.max_age or M.MAX_AGE) * 60
    local q = c.quality == 'any' and ' (any quality)' or c.quality and c.quality ~= 'normal' and ' (' .. c.quality .. ')' or ''
    local d = rec.done
    if not d then
      local since = game.tick - rec.first
      local running = rec.job and string.format('a pass began %s ago', secs(game.tick - rec.job.start)) or 'its first pass waits for its turn'
      if since > max_age then
        return true, string.format('platform %s: no reading of its ammunition yet %s after its first check (%s), past max_age %s: met (no reading as fresh as max_age)',
          pl.name, secs(since), running, secs(max_age))
      end
      return false, string.format('platform %s: no reading of its ammunition yet (%s; %s since its first check; met if none by max_age %s)', pl.name, running, secs(since), secs(max_age))
    end
    local out, total = M.places(d, c.item, c.quality)
    local age = game.tick - d.start
    local e = d.ents
    local text = string.format('platform %s: %d %s%s aboard (%s) as read %s ago (ticks %d-%d: hub, %d ammo turrets, %d belts, %d inserters, %d machines, %d chests)',
      pl.name, total, c.item, q, places_text(out), secs(age), d.start, d.finish, e.turrets, e.belts, e.inserters, e.machines, e.chests)
    if age > max_age then return true, text .. string.format('; older than max_age %s: met (stale reading)', secs(max_age)) end
    return total < c.count, text .. string.format('; met below %d', c.count)
  end
  return M
end
