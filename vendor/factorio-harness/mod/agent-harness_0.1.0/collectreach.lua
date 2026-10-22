-- platform_supply {platform, collection: true}: the asteroid chunks floating around a platform and its collectors'
-- reach, as a player on the platform sees them (d22 batch78 AN2, Astra #1774: Asterion showed about 90 chunks while
-- its collectors had collected nothing for 10 minutes, and nothing told spawn geometry from arm reach).
-- - the view: the chunks of the platform's surface holding its foundation, MARGIN tiles out on every side;
-- - chunks in it (LuaSpacePlatform.find_asteroid_chunks_filtered: name, position, movement), grouped by type in
--   GROUP-tile cells (count, box, drift in tiles a second), and the NEAREST nearest a collector's reach;
-- - each collector: its reach (within collection_radius of the line from its centre to the point
--   collection_box_offset tiles in front of it; the offset from the prototype, the radius from the Space Age data:
--   2.0.77's LuaEntityPrototype has no collection_radius), status, filters, what its output holds (its arm's load has no inventory to read), the chunks
--   in its reach now by type, and the nearest chunk outside it;
-- - collected: the platform's production statistics (the production GUI) for each chunk type over the last minute
--   and ten minutes;
-- - with seconds: a bounded watch (collector_tally, one an agent) reading the chunks in the collectors' reach every
--   SAMPLE ticks: one in a reach at a read and gone from where its drift puts it at the next was taken by that
--   collector (the output's count misses them: the inserters empty it within those ticks); and the platform's own
--   count from the production statistics between the start and now. Read only.
-- (d22 batch81 AQ1, Sol #1852: Spindle's oxide-only collector was credited 92 metallic, 54 carbonic and 33 oxide, 242
-- in all, while the platform collected 132) the per-collector count is inferred and named so (gone_in_reach): a chunk
-- counts only for a collector whose filters take it, and only when its drift's path came to that reach (one that
-- drifts away is not counted); beside it the platform's exact count from the production statistics and how far the
-- inferred sum is from it. A chunk gone where its drift puts it on a platform tile struck the hull and is
-- not counted either (hit_hull): on a copy of world n's 08:40 save, 70 of the 103 chunks that vanished round Spindle
-- in 14,034 ticks vanished so, 13 as the platform's count rose and 20 left the 128-tile view; the oxide collector at
-- (5.5,-22.5) stands on the hull's north edge, and its reach covers the hull behind it. 2.0.77 has no per-collector catch count: no event for a collected chunk (the
-- only *chunk* events are map chunks), the collector's arm inventory (defines.inventory.asteroid_collector_arm) reads
-- nil, and the production statistics are the platform's.
-- Read on a private copy of world n's shift57 save (05:16 PDT, Asterion over Nauvis: 89 chunks, 12 collectors on two
-- sides facing out): one collector facing east took chunks placed at rest 12 and 12.4 tiles in front of it and not
-- 12.7; with the others switched off, 2 tiles in front and not 1.2 (docs/usage.md has the rest).
return function(api)
  local M = {}
  M.MARGIN, M.GROUP, M.NEAREST, M.SAMPLE = 32, 16, 12, 10
  M.RADIUS = {['asteroid-collector']=7.5}  -- collection_radius in space-age/prototypes/entity/entities.lua
  M.DEFAULT_RADIUS = 7.5
  local FOUNDATION = 'space-platform-foundation'
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function at(p) return string.format('(%g,%g)', r1(p.x), r1(p.y)) end
  local DIR = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local function chunk_name(c) return type(c.name) == 'string' and c.name or try(function() return c.name.name end) or '?' end
  local function xy(v)
    if type(v) ~= 'table' then return {x=0, y=0} end
    return {x=v.x or v[1] or 0, y=v.y or v[2] or 0}
  end
  -- A collector's reach: every point within radius of the line from its centre to the point offset tiles in front
  -- (from, to, radius). On the copy, chunks vanished in empty space 7.3-7.6 tiles beside a collector's centre (0.3-1.3
  -- in front), outside a circle around the front point alone; the line's ends fit what was taken 12 and 12.4 tiles in
  -- front and left at 12.7.
  function M.reach(c)
    local pos, d = c.position, try(function() return c.direction end) or 0
    local angle = d / 16 * 2 * math.pi
    local off = try(function() return c.prototype.collection_box_offset end) or 0
    return {from={x=pos.x, y=pos.y}, to={x=pos.x + off * math.sin(angle), y=pos.y - off * math.cos(angle)}, radius=M.RADIUS[c.name] or M.DEFAULT_RADIUS}
  end
  -- distance from (x,y) to the reach's line, less its radius: <= 0 inside
  local function out_xy(reach, x, y)
    local ax, ay, bx, by = reach.from.x, reach.from.y, reach.to.x, reach.to.y
    local vx, vy = bx - ax, by - ay
    local len2 = vx * vx + vy * vy
    local t = len2 > 0 and math.max(0, math.min(1, ((x - ax) * vx + (y - ay) * vy) / len2)) or 0
    local dx, dy = x - (ax + t * vx), y - (ay + t * vy)
    return math.sqrt(dx * dx + dy * dy) - reach.radius
  end
  function M.outside(reach, p) return out_xy(reach, p.x, p.y) end
  local outside = M.outside
  -- The view: the box of the surface's chunks holding foundation, MARGIN tiles out.
  function M.view(s)
    local x0, y0, x1, y1
    for ch in s.get_chunks() do
      local a = ch.area
      if s.count_tiles_filtered{area=a, name=FOUNDATION, limit=1} > 0 then
        x0, y0 = math.min(x0 or a.left_top.x, a.left_top.x), math.min(y0 or a.left_top.y, a.left_top.y)
        x1, y1 = math.max(x1 or a.right_bottom.x, a.right_bottom.x), math.max(y1 or a.right_bottom.y, a.right_bottom.y)
      end
    end
    if not x0 then return nil end
    return {left_top={x=x0 - M.MARGIN, y=y0 - M.MARGIN}, right_bottom={x=x1 + M.MARGIN, y=y1 + M.MARGIN}}
  end
  local function collectors(s, force)
    return try(function() return s.find_entities_filtered{type='asteroid-collector', force=force} end) or {}
  end
  local function output(c) return try(function() return c.get_inventory(defines.inventory.asteroid_collector_output) end) end
  local CHUNKS
  local function chunk_items()
    if not CHUNKS then
      CHUNKS = {}
      for name, pr in pairs(prototypes.asteroid_chunk or {}) do
        if not name:find('^parameter%-') and not try(function() return pr.hidden end) then CHUNKS[#CHUNKS+1] = name end
      end
      table.sort(CHUNKS)
    end
    return CHUNKS
  end
  -- Each chunk type's count in the platform's production statistics: total, and over the last minute and ten.
  local function collected(force, s)
    local st = try(function() return force.get_item_production_statistics(s) end)
    if not st then return nil end
    local out = {}
    for _, n in ipairs(chunk_items()) do
      if prototypes.item[n] then
        local function flow(i) return try(function() return st.get_flow_count{name=n, category='input', precision_index=i, count=true} end) or 0 end
        out[#out+1] = {name=n, total=try(function() return st.get_input_count(n) end) or 0,
          last_1m=math.floor(flow(defines.flow_precision_index.one_minute) + 0.5), last_10m=math.floor(flow(defines.flow_precision_index.ten_minutes) + 0.5)}
      end
    end
    return out
  end
  local function status_name(c)
    local s = try(function() return c.status end)
    for k, v in pairs(defines.entity_status or {}) do if v == s then return k end end
    return 'unknown'
  end
  local function contents(c)
    local inv = output(c)
    local list = inv and try(function() return inv.get_contents() end) or {}
    local parts = {}
    for _, x in ipairs(list) do parts[#parts+1] = x.name .. (x.quality and x.quality ~= 'normal' and '@' .. x.quality or '') .. '*' .. x.count end
    return #parts > 0 and table.concat(parts, ' ') or 'nothing'
  end
  local function filters(c)
    local out = {}
    for i = 1, try(function() return c.filter_slot_count end) or 0 do
      local f = try(function() return c.get_filter(i) end)
      local n = f and (type(f) == 'string' and f or f.name)
      if n then out[#out+1] = n end
    end
    return out
  end
  -- The chunk types a collector takes: its filters, or every type with none set (nil).
  local function accepts(c)
    local f = filters(c)
    if #f == 0 then return nil end
    local set = {}
    for _, n in ipairs(f) do set[n] = true end
    return set
  end
  M.accepts = accepts
  -- The read: {view, chunks_in_view, by_type, groups, nearest, in_reach, collectors, collected, lines}
  function M.read(pl)
    local s, force = pl.surface, pl.force
    local view = M.view(s)
    assert(view, pl.name .. ' has no foundation tiles')
    local list = try(function() return pl.find_asteroid_chunks_filtered{area=view} end) or {}
    local cols = collectors(s, force)
    local reaches = {}
    for i, c in ipairs(cols) do reaches[i] = M.reach(c) end
    local by, order, cells, cell_order, near, in_reach = {}, {}, {}, {}, {}, 0
    local per = {}  -- collector index -> {by type in reach, nearest outside}
    local takes = {}
    for i, c in ipairs(cols) do per[i] = {in_reach={}, n=0, takes=0}; takes[i] = accepts(c) end
    for _, ch in ipairs(list) do
      local name, pos, mv = chunk_name(ch), xy(ch.position), xy(ch.movement)
      if not by[name] then by[name] = 0; order[#order+1] = name end
      by[name] = by[name] + 1
      local k = name .. '|' .. math.floor(pos.x / M.GROUP) .. ',' .. math.floor(pos.y / M.GROUP)
      local g = cells[k]
      if not g then
        g = {name=name, count=0, x0=pos.x, y0=pos.y, x1=pos.x, y1=pos.y, mx=0, my=0}
        cells[k] = g; cell_order[#cell_order+1] = g
      end
      g.count = g.count + 1
      g.x0, g.y0, g.x1, g.y1 = math.min(g.x0, pos.x), math.min(g.y0, pos.y), math.max(g.x1, pos.x), math.max(g.y1, pos.y)
      g.mx, g.my = g.mx + mv.x, g.my + mv.y
      local best, bi = nil, nil
      local inside = false
      for i, r in ipairs(reaches) do
        local d = outside(r, pos)
        if d <= 0 then
          inside = true
          local t = per[i].in_reach
          t[name] = (t[name] or 0) + 1
          per[i].n = per[i].n + 1
          if not takes[i] or takes[i][name] then per[i].takes = per[i].takes + 1 end
        else
          local o = per[i].nearest
          if not o or d < o.outside then per[i].nearest = {name=name, position={x=r1(pos.x), y=r1(pos.y)}, outside=r1(d)} end
        end
        if not best or d < best then best, bi = d, i end
      end
      if inside then in_reach = in_reach + 1 end
      if bi then
        near[#near+1] = {name=name, position={x=r1(pos.x), y=r1(pos.y)}, drift={x=r1(mv.x * 60), y=r1(mv.y * 60)},
          collector=at(cols[bi].position), outside=best > 0 and r1(best) or 0}
      end
    end
    table.sort(near, function(a, b) return a.outside < b.outside end)
    for i = #near, M.NEAREST + 1, -1 do near[i] = nil end
    table.sort(cell_order, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.name < b.name end)
    local groups = {}
    for i, g in ipairs(cell_order) do
      if i > 24 then break end
      groups[i] = {name=g.name, count=g.count, box={left_top={x=r1(g.x0), y=r1(g.y0)}, right_bottom={x=r1(g.x1), y=r1(g.y1)}},
        drift={x=r1(g.mx / g.count * 60), y=r1(g.my / g.count * 60)}}
    end
    local by_type, type_text = {}, {}
    table.sort(order, function(a, b) return by[a] > by[b] or (by[a] == by[b] and a < b) end)
    for _, n in ipairs(order) do by_type[#by_type+1] = {name=n, count=by[n]}; type_text[#type_text+1] = by[n] .. ' ' .. n end
    local rows, lines = {}, {}
    for i, c in ipairs(cols) do
      local r, p = reaches[i], per[i]
      local d = try(function() return c.direction end) or 0
      local inr = {}
      for n, k in pairs(p.in_reach) do inr[#inr+1] = k .. ' ' .. n end
      table.sort(inr)
      local f = filters(c)
      local row = {position={x=c.position.x, y=c.position.y}, direction=DIR[d] or d, quality=try(function() return c.quality.name end) or 'normal',
        reach={from={x=r1(r.from.x), y=r1(r.from.y)}, to={x=r1(r.to.x), y=r1(r.to.y)}, radius=r.radius}, status=status_name(c), holds=contents(c), filters=#f > 0 and f or nil,
        in_reach=p.n, in_reach_by_type=#inr > 0 and table.concat(inr, ', ') or nil, in_reach_it_takes=p.n > 0 and p.takes or nil, nearest_outside=p.nearest}
      row.line = string.format('collector %s facing %s: %s; reach %g around the line to %s; holds %s; %s%s', at(c.position), tostring(row.direction), row.status,
        r.radius, at(r.to), row.holds, p.n > 0 and string.format('%d chunk%s in reach now (%s)%s', p.n, p.n == 1 and '' or 's', row.in_reach_by_type,
          #f > 0 and string.format(', %d of them of a type its filters take (%s)', p.takes, table.concat(f, ', ')) or '') or 'no chunk in reach now',
        p.nearest and string.format('; nearest outside: %s %s, %g tiles beyond its reach', p.nearest.name, at(p.nearest.position), p.nearest.outside) or '')
      rows[i] = row
      lines[#lines+1] = row.line
    end
    local got = collected(force, s)
    local got_text = {}
    local kept = {}
    for _, g in ipairs(got or {}) do
      if g.total > 0 or by[g.name] then
        kept[#kept+1] = g
        got_text[#got_text+1] = string.format('%s %d in the last minute, %d in 10 minutes', g.name, g.last_1m, g.last_10m)
      end
    end
    got = got and kept
    table.insert(lines, 1, string.format('%d chunk%s in view %s-%s%s; %d in a collector\'s reach now, %d outside every reach; %d collector%s',
      #list, #list == 1 and '' or 's', at(view.left_top), at(view.right_bottom), #type_text > 0 and ' (' .. table.concat(type_text, ', ') .. ')' or '',
      in_reach, #list - in_reach, #cols, #cols == 1 and '' or 's'))
    if #got_text > 0 then table.insert(lines, 2, 'collected on ' .. pl.name .. ' (production statistics): ' .. table.concat(got_text, '; ')) end
    return {view=view, chunks_in_view=#list, by_type=by_type, groups=groups, nearest=near, in_reach=in_reach, outside_reach=#list - in_reach,
      collectors=rows, collected=got, lines=lines,
      note='reach: within collection_radius (7.5, the Space Age data) of the line from the collector\'s centre to the point collection_box_offset (5, its prototype) tiles in front, as chunks taken on a copy of this world fit; '
        .. 'a collector\'s arm load has no inventory to read; drift: tiles a second; collected: the platform\'s production statistics, all its collectors together'}
  end

  -- The tally watch (measures.lua kind collector_tally).
  local function store() local st = api.state(); st.collector_tally = st.collector_tally or {}; return st.collector_tally end
  local function prod_counts(force, s)
    local out = {}
    for _, g in ipairs(collected(force, s) or {}) do out[g.name] = g.total end
    return out
  end
  -- WATCH: a chunk is watched within this many tiles of the reach of a collector whose filters take it, plus what it
  -- drifts in a sample; SLACK: a chunk gone with its drift's path from the last read this near such a reach is
  -- credited to it. On the copy (Spindle, 16 chunks collected in 14,034 ticks read every tick) each vanished 1-4 ticks
  -- before the platform's count rose, at 0.18 inside to 0.92 outside the fitted reach (one 2.77): collectors take a chunk
  -- as it crosses into reach, so one read inside a reach at a sample is rarely there.
  M.WATCH, M.SLACK = 2, 1
  -- The collector of those whose filters take the type nearest the path from (x,y) over dt ticks at (mx,my) a tick,
  -- and how far outside its reach: (index, distance), or nil when no such collector stands.
  local function path_reach(job, name, x, y, mx, my, dt)
    local best, bi
    for i, c in ipairs(job.collectors) do
      if not c.gone and (not c.takes or c.takes[name]) then
        for k = 0, dt, 2 do
          local d = out_xy(c.reach, x + mx * k, y + my * k)
          if not best or d < best then best, bi = d, i end
        end
      end
    end
    return bi, best
  end
  function M.start(p, pl, seconds, reason)
    assert(type(seconds) == 'number' and seconds >= 10 and seconds <= 3600 and seconds == math.floor(seconds), 'seconds: 10..3600')
    local s = pl.surface
    local cols = {}
    local x0, y0, x1, y1
    for _, c in ipairs(collectors(s, pl.force)) do
      local r = M.reach(c)
      cols[#cols+1] = {e=c, position={x=c.position.x, y=c.position.y}, reach=r, takes=accepts(c), filters=filters(c), taken=0, by={}}
      for _, q in ipairs({r.from, r.to}) do
        x0, y0 = math.min(x0 or math.huge, q.x - r.radius), math.min(y0 or math.huge, q.y - r.radius)
        x1, y1 = math.max(x1 or -math.huge, q.x + r.radius), math.max(y1 or -math.huge, q.y + r.radius)
      end
    end
    assert(#cols > 0, pl.name .. ' has no asteroid collector')
    local replaced = store()[p.index] and not store()[p.index].result
    local job = {platform=pl.name, pl=pl, surface=s.index, force=pl.force.name, start=game.tick, until_tick=game.tick + seconds * 60,
      next_tick=game.tick + M.SAMPLE, seconds=seconds, samples=0, collectors=cols, prod0=prod_counts(pl.force, s), reason=reason,
      box={left_top={x=x0 - M.WATCH - 6, y=y0 - M.WATCH - 6}, right_bottom={x=x1 + M.WATCH + 6, y=y1 + M.WATCH + 6}}}
    M.sample(job, game.tick)
    store()[p.index] = job
    return replaced
  end
  -- Each sample: a chunk watched at the last one that is gone from where its drift puts it now counts as gone at the
  -- reach its drift's path came within SLACK of (of a collector whose filters take its type), unless that spot is on a
  -- platform tile (it struck the hull); one whose path came near no such reach is not counted (it drifted out, or went
  -- elsewhere); then the chunks to watch now.
  M.TOLERANCE = 0.5
  -- A platform tile at x, y: the hull (a chunk that reaches it is gone, not collected).
  local function on_hull(s, x, y)
    local t = s and try(function() return s.get_tile(math.floor(x), math.floor(y)) end)
    return t ~= nil and t.valid ~= false and t.name ~= 'empty-space'
  end
  M.on_hull = on_hull
  function M.sample(job, tick)
    local live = false
    for _, c in ipairs(job.collectors) do
      if not c.gone then
        if c.e and c.e.valid then live = true else c.gone, c.e = tick, nil end
      end
    end
    local now = job.pl and job.pl.valid and try(function() return job.pl.find_asteroid_chunks_filtered{area=job.box} end)
    local surface = now and job.pl.surface
    if not now then live = false; now = {} end
    -- the chunks near a reach of a collector that takes them: matched against the watched ones, and watched next
    local cur, prev = {}, {}
    for _, ch in ipairs(now) do
      local pos, mv = ch.position, ch.movement
      local x, y = pos.x or pos[1] or 0, pos.y or pos[2] or 0
      local mx, my = mv and (mv.x or mv[1]) or 0, mv and (mv.y or mv[2]) or 0
      local name = chunk_name(ch)
      local step = math.sqrt(mx * mx + my * my) * M.SAMPLE
      local _, d = path_reach(job, name, x, y, 0, 0, 0)
      if d and d <= M.WATCH + 2 * step + 1 then
        local c = {name=name, x=x, y=y, mx=mx, my=my, tick=tick}
        cur[#cur+1] = c
        if d <= M.WATCH + step then prev[#prev+1] = c end
      end
    end
    for _, q in ipairs(job.prev or {}) do
      local dt = tick - q.tick
      local px, py = q.x + q.mx * dt, q.y + q.my * dt
      local found = false
      for _, c in ipairs(cur) do
        if c.name == q.name and math.abs(c.x - px) <= M.TOLERANCE and math.abs(c.y - py) <= M.TOLERANCE then found = true; break end
      end
      if not found then
        -- the drift a few ticks on too: a chunk last seen just short of the hull's edge
        if on_hull(surface, px, py) or on_hull(surface, px + q.mx * 3, py + q.my * 3) then
          job.hit_hull = (job.hit_hull or 0) + 1
        else
          local i, d = path_reach(job, q.name, q.x, q.y, q.mx, q.my, dt)
          local col = i and d <= M.SLACK and job.collectors[i]
          if col then
            col.taken = col.taken + 1
            col.by[q.name] = (col.by[q.name] or 0) + 1
          else
            job.gone_elsewhere = (job.gone_elsewhere or 0) + 1
          end
        end
      end
    end
    job.prev = prev
    job.samples = job.samples + 1
    job.sampled, job.all_gone = tick, not live or nil
  end
  function M.result(job, done)
    local now = done and job.until_tick or game.tick
    local s = game.surfaces[job.surface]
    local prod = s and prod_counts(game.forces[job.force], s) or {}
    local plat = {}
    local total = 0
    for n, v in pairs(prod) do
      local d = v - (job.prod0[n] or 0)
      if d ~= 0 then plat[#plat+1] = {name=n, count=d}; total = total + d end
    end
    table.sort(plat, function(a, b) return a.count > b.count end)
    local rows, seen, idle, sum_by = {}, 0, 0, {}
    for _, c in ipairs(job.collectors) do
      local by = {}
      for n, k in pairs(c.by) do by[#by+1] = k .. ' ' .. n; sum_by[n] = (sum_by[n] or 0) + k end
      table.sort(by)
      rows[#rows+1] = {position=c.position, filters=c.filters and #c.filters > 0 and c.filters or nil, gone_in_reach=c.taken,
        gone_in_reach_by_type=#by > 0 and table.concat(by, ', ') or nil, gone_s=c.gone and math.floor((c.gone - job.start) / 60) or nil}
      seen = seen + c.taken
      if c.taken == 0 then idle = idle + 1 end
    end
    local secs = math.floor((now - job.start) / 6 + 0.5) / 10
    local parts, per_type, names = {}, {}, {}
    for _, x in ipairs(plat) do parts[#parts+1] = x.count .. ' ' .. x.name; names[x.name] = true end
    for n in pairs(sum_by) do names[n] = true end
    local order = {}
    for n in pairs(names) do order[#order+1] = n end
    table.sort(order)
    local got = {}
    for _, x in ipairs(plat) do got[x.name] = x.count end
    local diff = {}
    for _, n in ipairs(order) do
      local a, b = sum_by[n] or 0, got[n] or 0
      per_type[#per_type+1] = {name=n, inferred=a, collected=b, difference=a - b}
      if a ~= b then diff[#diff+1] = string.format('%s %s%d', n, a > b and '+' or '', a - b) end
    end
    local off = seen - total
    return {watching=not done or nil, done=done or nil, platform=job.platform, seconds=job.seconds, seconds_watched=secs, start_tick=job.start,
      end_tick=done and job.until_tick or nil, collected=total, collected_by_type=plat, collectors=rows, gone_in_reach_total=seen,
      inferred_minus_collected=off, by_type=per_type, hit_hull=job.hit_hull or 0, gone_elsewhere=job.gone_elsewhere or 0,
      line=string.format('%s %s\'s %d collectors for %gs%s: %d chunks collected (production statistics, exact, the platform\'s: %s); inferred: %d gone at a collector\'s reach whose filters take them (%s the collected count%s), %d collector%s with none',
        done and 'watched' or 'watching', job.platform, #rows, secs, done and '' or string.format(' of %ds', job.seconds), total,
        #parts > 0 and table.concat(parts, ', ') or 'none', seen,
        off == 0 and 'equal to' or string.format('%d %s than', math.abs(off), off > 0 and 'more' or 'fewer'),
        #diff > 0 and '; by type ' .. table.concat(diff, ', ') or '', idle, idle == 1 and '' or 's')
        .. string.format('; not counted: %d gone on a hull tile (struck the hull), %d gone away from every reach', job.hit_hull or 0, job.gone_elsewhere or 0),
      note='collected: the platform\'s production statistics between the start and ' .. (done and 'the end' or 'now') .. ', exact, all its collectors together; gone_in_reach (inferred, not a catch count: 2.0.77 gives none per collector): a chunk seen within ' .. M.WATCH .. ' tiles (and its drift) of the reach of a collector whose filters take its type at one read (every ' .. M.SAMPLE
        .. ' ticks), gone from where its drift puts it at the next, its path since within ' .. M.SLACK .. ' tile of that reach (collectors take chunks as they cross into it), counted for the collector whose reach it came nearest; not counted: one found where its drift puts it, one gone where its drift puts it on a platform tile (hit_hull: it struck the hull), one whose path came near no such reach (gone_elsewhere); a chunk taken without being seen near a reach first is missed, so the inferred sum can fall short of collected'}
  end
  function M.tick(tick)
    local all = api.state().collector_tally
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and tick >= job.next_tick then
        M.sample(job, tick)
        if tick >= job.until_tick then
          job.result = M.result(job, true)
          job.collectors, job.prev, job.pl = nil, nil, nil
        else
          job.next_tick = math.min(tick + M.SAMPLE, job.until_tick)
        end
      end
    end
  end
  -- The agent's watch of that platform: its result so far or done (a done one marked read), or nil.
  function M.tally(p, pl)
    local job = store()[p.index]
    if not job or job.platform ~= pl.name then return nil end
    if job.result then job.read_tick = game.tick; return job.result end
    return M.result(job, false)
  end
  return M
end
