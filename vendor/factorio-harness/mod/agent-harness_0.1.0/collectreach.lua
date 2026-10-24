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
-- (d24 batch143 PO1, Sol #2133: Limestone's tally called 7 metallic "collected" while its collectors take only oxide and
-- carbonic, and its reprocessing crusher made 22 crafts) the production statistics count every chunk made on the
-- platform, the crushers' returns among them (reprocessing and advanced crushing return chunks): made, not what the
-- collectors caught. What they caught (caught): each collector's output count and its inserters' pickups (a hand empty
-- at one read and holding a chunk at the next, its pickup target the collector), read more often than an inserter's
-- half turn, so no pickup falls between reads (chunks stack to 1: a pickup is one chunk). 2.0.77 has no counter for it:
-- no collector or platform attribute, no event, and the arm inventory reads nil. On a copy of world n's 03:27 save,
-- Asterion (17 collectors, 14 crushers, fast inserters at 0.04 turns a tick): over 16,359 ticks the platform made 336
-- carbonic, 273 metallic and 707 oxide; its collectors' outputs received 229, 186 and 508, its crushers' outputs 106,
-- 88 and 197 (made equalled the two together within 9 a type at every read: the counts' timing), and a read every 6
-- ticks gave the same catch as one every tick.
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
  -- Each chunk type's count in the platform's production statistics (every chunk made on the platform, the crushers'
  -- returns among them): total, and over the last minute and ten.
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
  local function takes_of(f)
    if #f == 0 then return nil end
    local set = {}
    for _, n in ipairs(f) do set[n] = true end
    return set
  end
  local function accepts(c) return takes_of(filters(c)) end
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
    if #got_text > 0 then table.insert(lines, 2, 'made on ' .. pl.name .. ' (production statistics: every chunk made on the platform, the crushers\' returns among them; what its collectors caught: seconds starts a collector_tally watch): ' .. table.concat(got_text, '; ')) end
    return {view=view, chunks_in_view=#list, by_type=by_type, groups=groups, nearest=near, in_reach=in_reach, outside_reach=#list - in_reach,
      collectors=rows, made=got, lines=lines,
      note='reach: within collection_radius (7.5, the Space Age data) of the line from the collector\'s centre to the point collection_box_offset (5, its prototype) tiles in front, as chunks taken on a copy of this world fit; '
        .. 'a collector\'s arm load has no inventory to read; drift: tiles a second; made: the platform\'s production statistics for chunks, every chunk made on the platform: its collectors\' catch and the crushers\' returns (reprocessing and advanced crushing return chunks); a collector_tally watch (seconds) counts what the collectors caught'}
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
  -- (PO1) The catch: per collector, its output's count by chunk type and its inserters' hands at each read; a chunk
  -- arrived = the output's rise plus the chunks its inserters picked up since the last read. Read every CATCH ticks at
  -- most, and under half the shortest half turn of the inserters taking from the collectors.
  M.CATCH, M.FEEDERS_EVERY = 10, 600
  local function feeders(c, s, force)
    local p, out = c.position, {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=force, area={{p.x - 4, p.y - 4}, {p.x + 4, p.y + 4}}} end) or {}) do
      if try(function() return i.pickup_target end) == c then out[#out+1] = i end
    end
    return out
  end
  local function hand(i)
    local h = try(function() return i.held_stack end)
    if h and try(function() return h.valid_for_read end) then return h.name, h.count end
    return false
  end
  local function half_turn(i)
    local pr = i.prototype
    local v = try(function() return pr.get_inserter_rotation_speed(i.quality) end) or try(function() return pr.inserter_rotation_speed end)
    return v and v > 0 and 0.5 / v or nil
  end
  local function out_counts(c)
    local inv = output(c.e)
    local t = {}
    for _, n in ipairs(chunk_items()) do t[n] = inv and try(function() return inv.get_item_count(n) end) or 0 end
    return t, inv and try(function() return inv.get_item_count() end) or 0
  end
  local function catch_feeders(job, c)
    local s = job.pl.surface
    local was = {}
    for k, i in ipairs(c.feeders or {}) do if i.valid then was[i.unit_number] = c.hands[k] end end
    c.feeders, c.hands = feeders(c.e, s, job.pl.force), {}
    for k, i in ipairs(c.feeders) do
      local h = was[i.unit_number]
      if h == nil then h = hand(i) end  -- a new one: its hand now, not a pickup
      c.hands[k] = h
    end
  end
  local function catch_period(job)
    local short
    for _, c in ipairs(job.collectors) do
      for _, i in ipairs(c.feeders or {}) do
        local t = i.valid and half_turn(i)
        if t and (not short or t < short) then short = t end
      end
    end
    return math.max(1, math.min(M.CATCH, short and math.floor(short / 2) or M.CATCH))
  end
  function M.catch_start(job, tick)
    for _, c in ipairs(job.collectors) do
      if c.e and c.e.valid then
        catch_feeders(job, c)
        c.last, c.last_total = out_counts(c)
        c.caught, c.caught_by = 0, {}
      end
    end
    job.catch_every = catch_period(job)
    job.catch_next, job.feeders_next = tick + job.catch_every, tick + M.FEEDERS_EVERY
  end
  function M.catch_read(job, tick)
    local refresh = tick >= (job.feeders_next or 0)
    for _, c in ipairs(job.collectors) do
      if c.e and c.e.valid and c.last then
        local picks, any = {}, false
        for k, i in ipairs(c.feeders) do
          if i.valid then
            local n, k2 = hand(i)
            if n and not c.hands[k] then picks[n] = (picks[n] or 0) + k2; any = true end
            c.hands[k] = n
          end
        end
        local inv = output(c.e)
        local total = inv and try(function() return inv.get_item_count() end) or 0
        if any or total ~= c.last_total then
          local now = out_counts(c)
          for _, n in ipairs(chunk_items()) do
            local d = (now[n] or 0) - (c.last[n] or 0) + (picks[n] or 0)
            if d < 0 then c.taken_otherwise = (c.taken_otherwise or 0) - d
            elseif d > 0 then c.caught = c.caught + d; c.caught_by[n] = (c.caught_by[n] or 0) + d end
          end
          c.last, c.last_total = now, total
        end
        if refresh then catch_feeders(job, c) end
      end
    end
    if refresh then job.catch_every = catch_period(job); job.feeders_next = tick + M.FEEDERS_EVERY end
    job.catch_reads = (job.catch_reads or 0) + 1
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
    M.catch_start(job, game.tick)
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
    -- the filters at each read: they change while a watch runs (on the copy, a plan of the save changed the east
    -- collector's from metallic and oxide to carbonic and oxide during a 300 s watch)
    for _, c in ipairs(job.collectors) do
      if not c.gone then
        if c.e and c.e.valid then
          live = true
          local f = filters(c.e)
          if #f ~= #(c.filters or {}) or table.concat(f, ',') ~= table.concat(c.filters or {}, ',') then
            c.filters, c.takes = f, takes_of(f)
            c.changed = (c.changed or 0) + 1
          end
        else c.gone, c.e = tick, nil end
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
    local made = 0
    for n, v in pairs(prod) do
      local d = v - (job.prod0[n] or 0)
      if d ~= 0 then plat[#plat+1] = {name=n, count=d}; made = made + d end
    end
    table.sort(plat, function(a, b) return a.count > b.count end)
    local rows, seen, idle, sum_by, caught, caught_by, otherwise = {}, 0, 0, {}, 0, {}, 0
    local function text_of(t) local l = {}; for n, k in pairs(t) do l[#l+1] = k .. ' ' .. n end; table.sort(l); return #l > 0 and table.concat(l, ', ') or nil end
    for _, c in ipairs(job.collectors) do
      for n, k in pairs(c.by) do sum_by[n] = (sum_by[n] or 0) + k end
      for n, k in pairs(c.caught_by or {}) do caught_by[n] = (caught_by[n] or 0) + k end
      rows[#rows+1] = {position=c.position, filters=c.filters and #c.filters > 0 and c.filters or nil, filters_changed=c.changed,
        caught=c.caught or 0, caught_by_type=text_of(c.caught_by or {}), inserters=c.feeders and #c.feeders or nil, taken_otherwise=c.taken_otherwise,
        gone_in_reach=c.taken, gone_in_reach_by_type=text_of(c.by), gone_s=c.gone and math.floor((c.gone - job.start) / 60) or nil}
      seen = seen + c.taken
      caught = caught + (c.caught or 0)
      otherwise = otherwise + (c.taken_otherwise or 0)
      if (c.caught or 0) == 0 then idle = idle + 1 end
    end
    local secs = math.floor((now - job.start) / 6 + 0.5) / 10
    local made_parts, caught_parts, per_type, names = {}, {}, {}, {}
    local got = {}
    for _, x in ipairs(plat) do made_parts[#made_parts+1] = x.count .. ' ' .. x.name; names[x.name] = true; got[x.name] = x.count end
    for n in pairs(sum_by) do names[n] = true end
    for n in pairs(caught_by) do names[n] = true end
    local order = {}
    for n in pairs(names) do order[#order+1] = n end
    table.sort(order)
    local diff = {}
    for _, n in ipairs(order) do
      local inf, ca, ma = sum_by[n] or 0, caught_by[n] or 0, got[n] or 0
      if ca > 0 then caught_parts[#caught_parts+1] = ca .. ' ' .. n end
      per_type[#per_type+1] = {name=n, made=ma, caught=ca, made_minus_caught=ma - ca, inferred=inf, inferred_minus_caught=inf - ca}
      if inf ~= ca then diff[#diff+1] = string.format('%s %s%d', n, inf > ca and '+' or '', inf - ca) end
    end
    local off = seen - caught
    return {watching=not done or nil, done=done or nil, platform=job.platform, seconds=job.seconds, seconds_watched=secs, start_tick=job.start,
      end_tick=done and job.until_tick or nil, caught=caught, caught_by_type=text_of(caught_by), read_every=job.catch_every,
      made=made, made_by_type=plat, made_minus_caught=made - caught, taken_otherwise=otherwise > 0 and otherwise or nil,
      collectors=rows, gone_in_reach_total=seen, inferred_minus_caught=off, by_type=per_type, hit_hull=job.hit_hull or 0, gone_elsewhere=job.gone_elsewhere or 0,
      line=string.format('%s %s\'s %d collectors for %gs%s: caught %d (arrived in their outputs, read every %s ticks: %s), %d collector%s with none; made %d on the platform (production statistics, every chunk made there, the crushers\' returns among them: %s), %d more than caught; inferred: %d gone at a collector\'s reach whose filters take them (%s the caught count%s)',
        done and 'watched' or 'watching', job.platform, #rows, secs, done and '' or string.format(' of %ds', job.seconds), caught, tostring(job.catch_every or '?'),
        #caught_parts > 0 and table.concat(caught_parts, ', ') or 'none', idle, idle == 1 and '' or 's', made, #made_parts > 0 and table.concat(made_parts, ', ') or 'none', made - caught, seen,
        off == 0 and 'equal to' or string.format('%d %s than', math.abs(off), off > 0 and 'more' or 'fewer'), #diff > 0 and '; by type ' .. table.concat(diff, ', ') or '')
        .. string.format('; not counted: %d gone on a hull tile (struck the hull), %d gone away from every reach', job.hit_hull or 0, job.gone_elsewhere or 0)
        .. (otherwise > 0 and string.format('; %d taken from the outputs by other than their inserters (robots, a hand): not in caught', otherwise) or ''),
      note='caught: the chunks that arrived in the collectors\' outputs between the start and ' .. (done and 'the end' or 'now') .. ': each output\'s rise plus what the inserters taking from it picked up, read every read_every ticks, under half an inserter\'s half turn (chunks stack to 1: a pickup is one chunk); a chunk still in a collector\'s arm is not yet in it. '
        .. 'made: the platform\'s production statistics for chunks over the same span: every chunk made on the platform, the collectors\' catch and the crushers\' returns (reprocessing and advanced crushing return chunks); made_minus_caught: the crushers\' returns and the counts\' timing (on a copy of world n, made equalled the collectors\' and the crushers\' outputs together within 9 a type over 16,359 ticks). '
        .. 'gone_in_reach (inferred, not a catch count): a chunk seen within ' .. M.WATCH .. ' tiles (and its drift) of the reach of a collector whose filters take its type at one read (every ' .. M.SAMPLE
        .. ' ticks), gone from where its drift puts it at the next, its path since within ' .. M.SLACK .. ' tile of that reach (collectors take chunks as they cross into it), counted for the collector whose reach it came nearest; not counted: one found where its drift puts it, one gone where its drift puts it on a platform tile (hit_hull: it struck the hull), one whose path came near no such reach (gone_elsewhere); a chunk taken without being seen near a reach first is missed'}
  end
  function M.tick(tick)
    local all = api.state().collector_tally
    if not all then return end
    for _, job in pairs(all) do
      if not job.result and job.catch_next and tick >= job.catch_next and tick < job.until_tick then
        M.catch_read(job, tick)
        job.catch_next = tick + job.catch_every
      end
      if not job.result and tick >= job.next_tick then
        M.sample(job, tick)
        if tick >= job.until_tick then
          if job.catch_next then M.catch_read(job, tick) end
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
