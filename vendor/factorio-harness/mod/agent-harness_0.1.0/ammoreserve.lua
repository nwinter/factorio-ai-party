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
-- (d24 batch173 QP1, Astra #2241: Asterion's left and right rocket loops are not connected, and a full left loop hid
-- the right one running low) A condition can scope the count: area (an area aboard: what each place in it holds, the
-- hub too when it stands in it) or loop (from one belt's position: the belts joined to it end to end, through
-- splitters, undergrounds and linked belts, and through inserters that move items from one belt to another, either
-- way along them; the inserters taking from those belts, their hands, and the ammo turrets those inserters fill:
-- Asterion's turrets are fed by short belts that inserters fill from a main loop). The same pass counts each scope beside the whole platform. A loop's belts
-- are found before the pass that first needs them: the belt-to-belt inserters a band at a time (as the pass walks), then
-- LOOP_STEP belts a step, at most LOOP_MAX; again when that find is LOOP_EVERY ticks old at a pass's start. A reading keeps the one before it, so a check gives the change between them.
return function(api)
  local M = {}
  M.STEP, M.BAND, M.BANDS, M.EVERY, M.KEEP, M.PICK = 1, 100, 8, 1800, 36000, 60
  M.MAX_AGE, M.MAX_AGE_LOW, M.MAX_AGE_HIGH = 120, 30, 900  -- seconds: a reading older than this is stale
  M.PLACES = {'hub', 'turrets', 'belts', 'hands', 'machines', 'chests'}
  M.LOOP_STEP, M.LOOP_MAX, M.LOOP_EVERY = 200, 20000, 18000
  local BELTS = {['transport-belt']=true, ['underground-belt']=true, splitter=true, loader=true, ['loader-1x1']=true, ['lane-splitter']=true, ['linked-belt']=true}
  local TYPES_BELT = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'lane-splitter', 'linked-belt'}
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
  -- One count into each of the sinks (the whole platform's reading and the scopes holding the place: {counts, ents}).
  local function put(sinks, place, name, quality, n)
    if not (n and n > 0 and is_ammo(name)) then return end
    if type(quality) ~= 'string' then quality = quality and quality.name or 'normal' end
    for _, sink in ipairs(sinks) do
      local byq = sink.counts[name] or {}
      sink.counts[name] = byq
      local row = byq[quality] or {}
      byq[quality] = row
      row[place] = (row[place] or 0) + n
    end
  end
  local function contents(sinks, place, inv)
    for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do put(sinks, place, r.name, r.quality, r.count) end
  end
  local function inside(box, pos) return pos.x >= box[1] and pos.x <= box[3] and pos.y >= box[2] and pos.y <= box[4] end
  local function unit(e) return e.unit_number end  -- a valid entity's (2.0: every one of these types has one)
  -- The sinks for an entity: the whole reading, each area holding its position, and for a belt each loop it is in.
  local BUF = {}  -- one list for every entity read (used before the next read)
  local function sinks_of(job, e, t)
    local sinks = job.sinks1
    if not job.scopes then return sinks end
    sinks = BUF
    for i = #sinks, 2, -1 do sinks[i] = nil end
    sinks[1] = job
    local pos, u
    for _, sc in ipairs(job.scopes) do
      if sc.box then
        pos = pos or e.position
        if inside(sc.box, pos) then sinks[#sinks+1] = sc end
      elseif sc.members and BELTS[t] then
        u = u or unit(e)
        if u and sc.members[u] then sinks[#sinks+1] = sc end
      end
    end
    return sinks
  end
  local function tally(sinks, kind)
    for _, sink in ipairs(sinks) do sink.ents[kind] = sink.ents[kind] + 1 end
  end
  local function read(job, e)
    local t = e.type
    local sinks = sinks_of(job, e, t)
    if BELTS[t] then
      tally(sinks, 'belts')
      local lines = try(function() return e.get_max_transport_line_index() end) or 0
      local partner = t == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'output'
        and try(function() local n = e.neighbours; return n and n.valid and n or nil end)
      for i = 1, lines do
        local line = try(function() return e.get_transport_line(i) end)
        local same = partner and i > 2 and try(function() return line.line_equals(partner.get_transport_line(i)) end)
        if line and not same then contents(sinks, 'belts', line) end
      end
    elseif t == 'inserter' then
      if job.loops then  -- an inserter taking from a loop's belt is the loop's, and so is the turret it fills
        local from = e.pickup_target
        local fu = from and unit(from)
        if fu then
          for _, sc in ipairs(job.loops) do
            if sc.members[fu] then
              sinks[#sinks+1] = sc
              local to = e.drop_target
              local tu = to and to.type == 'ammo-turret' and unit(to)
              if tu then sc.fed[tu] = true end
            end
          end
        end
      end
      tally(sinks, 'inserters')
      local h = try(function() return e.held_stack end)
      if h and try(function() return h.valid_for_read end) then put(sinks, 'hands', h.name, h.quality, h.count) end
    elseif t == 'ammo-turret' then
      tally(sinks, 'turrets')
      local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
      contents(sinks, 'turrets', inv)
      if job.loops then  -- kept for the loops: which turret is a loop's is known once the pass has read the inserters
        local u = unit(e)
        if u then job.turret_rows[u] = inv and try(function() return inv.get_contents() end) or {} end
      end
    elseif t == 'container' then
      tally(sinks, 'chests')
      contents(sinks, 'chests', try(function() return e.get_inventory(defines.inventory.chest) end))
    else
      tally(sinks, 'machines')
      contents(sinks, 'machines', try(function() return e.get_output_inventory() end))
    end
  end
  -- A scope's key and its parts from a condition: area {left_top, right_bottom} (or [[x,y],[x,y]]) or loop {x,y}.
  local function xy(v) return {x=tonumber(v.x or v[1]), y=tonumber(v.y or v[2])} end
  local function num(v) return string.format('%g', v) end
  function M.scope(c)
    if c.area then
      local lt, rb = xy(c.area.left_top or c.area[1]), xy(c.area.right_bottom or c.area[2])
      return string.format('area (%s,%s)-(%s,%s)', num(lt.x), num(lt.y), num(rb.x), num(rb.y)), {box={lt.x, lt.y, rb.x, rb.y}}
    elseif c.loop then
      local at = xy(c.loop)
      return string.format('loop from (%s,%s)', num(at.x), num(at.y)), {at=at}
    end
  end
  local function fresh_ents() return {belts=0, inserters=0, turrets=0, machines=0, chests=0} end
  -- A loop's belts: from the belt at its position, every belt joined to one found, either way (belt_neighbours,
  -- an underground's partner, a linked belt's), by unit number; LOOP_STEP belts a step.
  local function loop_begin(s, force, key, at)
    local first = try(function() return s.find_entities_filtered{position=at, type=TYPES_BELT, force=force, limit=1}[1] end)
    local f = {key=key, members={}, n=0, queue={}, qi=1, tail=0}
    if first then
      f.first = {name=first.name, x=first.position.x, y=first.position.y}
      local u = unit(first)
      if u then f.members[u] = true; f.n = 1; f.queue[1] = first; f.tail = 1 end
    end
    return f
  end
  -- (QP1) an inserter that moves items from one belt to another joins the two belts, either way (links: unit -> {entity})
  local function link(links, e)
    local from, to = e.pickup_target, e.drop_target
    local fu, tu = from and BELTS[from.type] and unit(from), to and BELTS[to.type] and unit(to)
    if not (fu and tu) then return end
    links[fu] = links[fu] or {}; links[fu][#links[fu]+1] = to
    links[tu] = links[tu] or {}; links[tu][#links[tu]+1] = from
  end
  local function loop_step(f, links)
    -- the queue's end is kept apart: its read slots are cleared, so # would not find it
    local last = math.min(f.tail, f.qi + M.LOOP_STEP - 1)
    for i = f.qi, last do
      local e = f.queue[i]
      f.queue[i] = nil
      if e.valid then
        local next_ = {}
        local nb = try(function() return e.belt_neighbours end)
        for _, side in ipairs({'inputs', 'outputs'}) do for _, n in ipairs(nb and nb[side] or {}) do next_[#next_+1] = n end end
        local partner = e.type == 'underground-belt' and try(function() return e.neighbours end)
        if partner then next_[#next_+1] = partner end
        local linked = e.type == 'linked-belt' and try(function() return e.linked_belt_neighbour end)
        if linked then next_[#next_+1] = linked end
        local eu = links and unit(e)
        for _, n in ipairs(eu and links[eu] or {}) do next_[#next_+1] = n end
        for _, n in ipairs(next_) do
          local u = n.valid and BELTS[n.type] and unit(n)
          if u and not f.members[u] and f.n < M.LOOP_MAX then
            f.members[u] = true; f.n = f.n + 1; f.tail = f.tail + 1; f.queue[f.tail] = n
          elseif u and not f.members[u] then f.capped = true end
        end
      end
    end
    f.qi = last + 1
    return f.qi > f.tail
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
    local job = {start=tick, surface=s, hub=pl.hub, force=pl.force, counts={}, ents=fresh_ents(),
      walk=box and {surface=s.index, box=box, x=box.left, y=box.top, rows=1, band_rows=1, cols=1, max=1} or nil, queue={}, qi=1}
    job.sinks1 = {job}
    -- (QP1) the scopes asked within KEEP; a loop's belts found first when it has none or they are LOOP_EVERY old
    for key, sc in pairs(rec.scopes or {}) do
      if tick - sc.wanted > M.KEEP then rec.scopes[key] = nil
      else
        job.scopes = job.scopes or {}
        local row = {key=key, box=sc.box, counts={}, ents=fresh_ents()}
        if sc.at then
          rec.loops = rec.loops or {}
          local lp = rec.loops[key]
          if not lp or tick - lp.built > M.LOOP_EVERY then
            job.finding = job.finding or {}
            job.finding[#job.finding+1] = loop_begin(s, pl.force, key, sc.at)
          end
          row.fed = {}
          job.loops = job.loops or {}
          job.loops[#job.loops+1] = row
        end
        job.scopes[#job.scopes+1] = row
      end
    end
    if job.loops then job.turret_rows = {} end
    rec.job = job
    st.active = best
  end
  local function finish(rec, job, tick)
    local hub = job.hub
    if hub and hub.valid then
      local sinks = {job}
      for _, sc in ipairs(job.scopes or {}) do
        if sc.box and inside(sc.box, hub.position) then sinks[#sinks+1] = sc end
      end
      contents(sinks, 'hub', try(function() return hub.get_inventory(defines.inventory.hub_main) end))
    end
    local scopes
    for _, sc in ipairs(job.scopes or {}) do
      if sc.fed then  -- the turrets the loop's inserters fill
        for u in pairs(sc.fed) do
          local rows = job.turret_rows[u]
          if rows then
            sc.ents.turrets = sc.ents.turrets + 1
            for _, r in ipairs(rows) do put({sc}, 'turrets', r.name, r.quality, r.count) end
          end
        end
        local lp = rec.loops and rec.loops[sc.key]
        sc.loop = lp and {belts=lp.n, first=lp.first, capped=lp.capped, built=lp.built} or nil
      end
      scopes = scopes or {}
      scopes[sc.key] = {counts=sc.counts, ents=sc.ents, loop=sc.loop}
    end
    rec.prev = rec.done
    rec.done = {start=job.start, finish=tick, counts=job.counts, ents=job.ents, scopes=scopes}
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
    local f = job.finding and job.finding[1]
    if f and not job.linked then  -- (QP1) the belt-to-belt inserters first, bands as the pass walks them
      job.links = job.links or {}
      job.iwalk = job.iwalk or (job.walk and {surface=job.walk.surface, box=job.walk.box, x=job.walk.box.left, y=job.walk.box.top, rows=1, band_rows=1, cols=1, max=1})
      for _ = 1, M.BANDS do
        local band = job.iwalk and walk().band(job.iwalk, s, {force=job.force, type={'inserter'}})
        if not band then job.linked = true; job.iwalk = nil; break end
        for _, e in ipairs(band) do if e.valid then link(job.links, e) end end
        if #band > 0 then break end
      end
      return
    end
    if f then  -- (QP1) a loop's belts, before the pass reads anything
      if loop_step(f, job.links) then
        table.remove(job.finding, 1)
        rec.loops[f.key] = {members=f.members, n=f.n, first=f.first, capped=f.capped, built=tick}
        if #job.finding == 0 then
          job.finding, job.links = nil, nil
          for _, sc in ipairs(job.loops or {}) do sc.members = rec.loops[sc.key] and rec.loops[sc.key].members or {} end
        end
      end
      return
    end
    if job.loops and not job.loops[1].members then
      for _, sc in ipairs(job.loops) do sc.members = rec.loops[sc.key] and rec.loops[sc.key].members or {} end
    end
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
  -- Asked about pl (a condition's check): the record, kept fresh; with a scope (key, parts), that scope too.
  function M.want(pl, force, key, parts)
    local st = store()
    local rec = st.plats[pl.index]
    if not rec then rec = {name=pl.name, force=force.name, first=game.tick}; st.plats[pl.index] = rec end
    rec.wanted, rec.name = game.tick, pl.name
    if key then
      rec.scopes = rec.scopes or {}
      local sc = rec.scopes[key]
      if not sc then sc = {box=parts.box, at=parts.at, first=game.tick}; rec.scopes[key] = sc end
      sc.wanted = game.tick
      return rec, sc
    end
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
  -- (QP1) the item's total in the reading before the newest, for the same scope: the change between the two a minute
  local function change(rec, d, key, c, total)
    local p = rec.prev
    local pc = p and (key and p.scopes and p.scopes[key] or not key and p)
    if not pc or d.start <= p.start then return '' end
    local _, before = M.places(pc, c.item, c.quality)
    local mins = (d.start - p.start) / 3600
    local per = (total - before) / mins
    return string.format('; %+d since the reading before (%s earlier): %+.1f/min net (made or brought in less what left)',
      total - before, secs(d.start - p.start), per)
  end
  function M.check(pl, force, c)
    local key, parts = M.scope(c)
    local rec, sc = M.want(pl, force, key, parts)
    local max_age = (c.max_age or M.MAX_AGE) * 60
    local q = c.quality == 'any' and ' (any quality)' or c.quality and c.quality ~= 'normal' and ' (' .. c.quality .. ')' or ''
    local d = rec.done
    local sd = d and key and d.scopes and d.scopes[key]
    if not d or key and not sd then
      local first = sc and sc.first or rec.first
      local since = game.tick - first
      local what = key and 'its ' .. key or 'its ammunition'
      local running = rec.job and string.format('a pass began %s ago', secs(game.tick - rec.job.start)) or 'its first pass waits for its turn'
      if key and rec.job and rec.job.finding then running = running .. ', finding the loop\'s belts' end
      if since > max_age then
        return true, string.format('platform %s: no reading of %s yet %s after its first check (%s), past max_age %s: met (no reading as fresh as max_age)',
          pl.name, what, secs(since), running, secs(max_age))
      end
      return false, string.format('platform %s: no reading of %s yet (%s; %s since its first check; met if none by max_age %s)', pl.name, what, running, secs(since), secs(max_age))
    end
    local src = sd or d
    local out, total = M.places(src, c.item, c.quality)
    local age = game.tick - d.start
    local e = src.ents
    local text
    if key then
      local lp = sd.loop
      local found = lp and (lp.first and string.format('%d belts joined to %s (%g,%g)%s, found %s ago', lp.belts, lp.first.name, lp.first.x, lp.first.y,
        lp.capped and string.format(' (stopped at %d)', M.LOOP_MAX) or '', secs(game.tick - lp.built)) or 'no belt of ours at that position') .. '; ' or ''
      text = string.format('platform %s, %s: %d %s%s (%s) as read %s ago (ticks %d-%d: %s%d ammo turrets, %d belts, %d inserters, %d machines, %d chests in it)',
        pl.name, key, total, c.item, q, places_text(out), secs(age), d.start, d.finish, found, e.turrets, e.belts, e.inserters, e.machines, e.chests)
    else
      text = string.format('platform %s: %d %s%s aboard (%s) as read %s ago (ticks %d-%d: hub, %d ammo turrets, %d belts, %d inserters, %d machines, %d chests)',
        pl.name, total, c.item, q, places_text(out), secs(age), d.start, d.finish, e.turrets, e.belts, e.inserters, e.machines, e.chests)
    end
    text = text .. change(rec, d, key, c, total)
    if age > max_age then return true, text .. string.format('; older than max_age %s: met (stale reading)', secs(max_age)) end
    return total < c.count, text .. string.format('; met below %d', c.count)
  end
  return M
end
