-- sight {surface?, position?, radius?, area?}: which chunks our force sees now, which it has only charted, and which
-- it has not charted, and what gives the sight (d24 batch174 QQ1, Luna #2242: danger counted the unseen chunks and
-- map and scan listed charted entities, so a remote read could not say which chunk edges of a defended wall were out
-- of sight, nor where a radar would cover them). As a player's map shows it:
--   visible: force.is_chunk_visible (radar continuous scan, a character's or vehicle's sight, now);
--   charted: force.is_chunk_charted and not visible (drawn under fog of war);
--   uncharted: neither.
-- What gives our force sight, measured on a copy of world n (docs/usage.md d24 batch174): a radar with power, the
-- square of chunks within get_max_distance_of_nearby_sector_revealed (its quality's; 3 for radar: 7x7) of its own
-- chunk on either axis, none without power; a roboport (powered or not) 2 chunks (5x5), a cargo landing pad 4 (9x9), a
-- spidertron 2 (5x5; its chunk_exploration_radius reads 3). None from a character without a player (the bots), nor
-- a car or tank (a car with a driver too), nor any turret, machine, pole, wall, chest, belt or lamp tried. A chunk stays visible
-- about 560-600 ticks after its source stops or goes. For each visible chunk the source: the nearest working radar
-- whose scan covers it, else the nearest roboport, pad or spidertron covering it, else a radar not working (lit from
-- before it stopped); for each chunk not visible, the nearest radar of ours and how many chunks outside its continuous
-- scan it is (0: inside, with that radar not working). Remote: by surface, no character move. Bounded: at most MAX
-- chunks a call.
return function(api)
  local M = {}
  -- (cap) world n, Nauvis's base, 256 chunks: read 3.96 ms, its reply encoded 1.58 ms; 1024 chunks on the copy read 9-20
  -- ms and encoded 14-23 ms (the copy runs these 3-11x slower): 256 a call. A radius of 240 touches at most 16x16.
  local MAX, DEF_R, MAX_R, LINES = 256, 128, 240, 12
  -- the chunks round one our force sees, either axis, by type (no prototype field gives these)
  local SIGHT = {roboport=2, ['cargo-landing-pad']=4, ['spider-vehicle']=2}
  local KIND = {roboport='roboport', ['cargo-landing-pad']='cargo-landing-pad', ['spider-vehicle']='spidertron'}
  local function try(f) local ok, v = pcall(f); if ok then return v end end
  local function round(v) return math.floor(v + 0.5) end
  local RANGE = {}
  -- a radar's continuous scan, in chunks, for its name and quality (prototype reads cost 40-200 us: kept)
  local function range_of(e)
    local q = try(function() return e.quality.name end) or 'normal'
    local k = e.name .. '@' .. q
    local r = RANGE[k]
    if r == nil then
      r = try(function() return e.prototype.get_max_distance_of_nearby_sector_revealed(q) end)
        or try(function() return e.prototype.get_max_distance_of_nearby_sector_revealed() end) or 0
      RANGE[k] = r
    end
    return r
  end
  local STATUS
  local function status_name(e)
    if not STATUS then
      STATUS = {}
      for k, v in pairs(try(function() return defines.entity_status end) or {}) do STATUS[v] = k end
    end
    local s = try(function() return e.status end)
    return s and STATUS[s] or 'unknown'
  end
  local function working(e) return try(function() return e.status == defines.entity_status.working end) == true end
  local function area_of(a)
    local v = a.area
    local lt = v.left_top or v[1]
    local rb = v.right_bottom or v[2]
    assert(type(lt) == 'table' and type(rb) == 'table', 'area is {left_top={x,y}, right_bottom={x,y}} or [[x0,y0],[x1,y1]]')
    local p1, p2 = api.position(lt), api.position(rb)
    return math.min(p1.x, p2.x), math.min(p1.y, p2.y), math.max(p1.x, p2.x), math.max(p1.y, p2.y)
  end
  -- number text by string.format: tostring and .. on a number cost about 8 us each (numtext.lua)
  local function run_text(x0, x1) return x0 == x1 and string.format('%d', x0) or string.format('%d..%d', x0, x1) end
  function M.read(p, a)
    local c = p.character
    local s = a.surface ~= nil and api.surface(p, a.surface) or p.surface
    local f = p.force
    local x0, y0, x1, y1, pos, r
    if a.area ~= nil then
      assert(a.position == nil and a.radius == nil, 'sight takes area, or position with radius: not both')
      x0, y0, x1, y1 = area_of(a)
    else
      assert(a.position ~= nil or not (c and c.valid) or c.surface == s, 'sight with surface needs position or area there (your character stands on another surface)')
      pos = a.position ~= nil and api.position(a.position) or (c and c.valid and {x=c.position.x, y=c.position.y})
      assert(pos, 'sight takes position {x,y} (default where your character stands) or area')
      r = a.radius == nil and DEF_R or a.radius
      assert(type(r) == 'number' and r >= 16 and r <= MAX_R, 'radius is 16..' .. MAX_R .. ' tiles (default ' .. DEF_R .. ')')
      x0, y0, x1, y1 = pos.x - r, pos.y - r, pos.x + r, pos.y + r
    end
    -- the chunks the area touches
    local cx0, cy0, cx1, cy1 = math.floor(x0 / 32), math.floor(y0 / 32), math.floor(x1 / 32), math.floor(y1 / 32)
    if x1 > x0 and x1 % 32 == 0 then cx1 = cx1 - 1 end
    if y1 > y0 and y1 % 32 == 0 then cy1 = cy1 - 1 end
    local w, h = cx1 - cx0 + 1, cy1 - cy0 + 1
    local n = w * h
    assert(n <= MAX, string.format('that area touches %d chunks (%dx%d), over the cap of %d a call: a smaller radius or area', n, w, h, MAX))
    -- each chunk: charted, visible (index i = (cy - cy0) * w + (cx - cx0) + 1)
    local vis, cha = {}, {}
    local pt = {x=0, y=0}
    for cy = cy0, cy1 do
      for cx = cx0, cx1 do
        local i = (cy - cy0) * w + (cx - cx0) + 1
        pt.x, pt.y = cx, cy
        vis[i] = f.is_chunk_visible(s, pt)
        cha[i] = vis[i] or f.is_chunk_charted(s, pt)
      end
    end
    -- our radars, roboports, pads and spidertrons on the surface (the census pass's lists, else one find)
    local function ours(t) return api.census_typed and try(function() return api.census_typed(f, s, t) end) or try(function() return s.find_entities_filtered{type=t, force=f} end) or {} end
    local radars = ours('radar')
    local sources, src_of = {}, {}
    local function source(e, kind, range)
      local k = e.unit_number or e
      if src_of[k] then return src_of[k] end
      local q = e.position
      -- position and chunk as "x,y" text: a reply's numbers are its encoding's cost (sources run to a hundred)
      local px, py, qx, qy = round(q.x), round(q.y), math.floor(q.x / 32), math.floor(q.y / 32)
      local row = {kind=kind, unit_number=e.unit_number, position=string.format('%d,%d', px, py), chunk=string.format('%d,%d', qx, qy), range=range,
        px=px, py=py, qx=qx, qy=qy}
      if kind == 'radar' then row.name = e.name; row.status = status_name(e) end
      sources[#sources+1] = row
      src_of[k] = #sources
      return #sources
    end
    local R = {}
    for _, e in ipairs(radars) do
      if e.valid then
        local q = e.position
        R[#R+1] = {e=e, cx=math.floor(q.x / 32), cy=math.floor(q.y / 32), r=range_of(e), ok=working(e)}
      end
    end
    -- the covering radar of each chunk: working first, then the nearest (on either axis, then by distance)
    local best, bestd = {}, {}
    for _, rd in ipairs(R) do
      for cy = math.max(cy0, rd.cy - rd.r), math.min(cy1, rd.cy + rd.r) do
        for cx = math.max(cx0, rd.cx - rd.r), math.min(cx1, rd.cx + rd.r) do
          local i = (cy - cy0) * w + (cx - cx0) + 1
          local d = (rd.ok and 0 or 1e6) + (cx - rd.cx) * (cx - rd.cx) + (cy - rd.cy) * (cy - rd.cy)
          if not best[i] or d < bestd[i] then best[i], bestd[i] = rd, d end
        end
      end
    end
    -- roboports, pads and spidertrons covering the area: the nearest each chunk
    local eye, eyed = {}, {}
    for t, rr in pairs(SIGHT) do
      for _, e in ipairs(ours(t)) do
        if e.valid then
          local q = e.position
          local ex, ey = math.floor(q.x / 32), math.floor(q.y / 32)
          local me = {e=e, kind=KIND[t], r=rr}
          for cy = math.max(cy0, ey - rr), math.min(cy1, ey + rr) do
            for cx = math.max(cx0, ex - rr), math.min(cx1, ex + rr) do
              local i = (cy - cy0) * w + (cx - cx0) + 1
              local d = (cx - ex) * (cx - ex) + (cy - ey) * (cy - ey)
              if not eye[i] or d < eyed[i] then eye[i], eyed[i] = me, d end
            end
          end
        end
      end
    end
    -- the nearest radar to a chunk not in sight, and how far outside its continuous scan
    local function nearest(cx, cy)
      local b, bo, bd
      for _, rd in ipairs(R) do
        local dx, dy = math.abs(cx - rd.cx), math.abs(cy - rd.cy)
        local o = math.max(dx, dy) - rd.r
        if o < 0 then o = 0 end
        local d = dx * dx + dy * dy
        if not b or o < bo or (o == bo and d < bd) then b, bo, bd = rd, o, d end
      end
      return b, bo
    end
    local out = {surface=s.name, chunk_area={left=cx0, top=cy0, right=cx1, bottom=cy1}, chunks=n, cap=MAX,
      tiles={left=cx0 * 32, top=cy0 * 32, right=(cx1 + 1) * 32, bottom=(cy1 + 1) * 32},
      visible={}, charted={}, uncharted={}, sources=sources, rows={}, lines={}}
    if pos then out.position = {x=round(pos.x), y=round(pos.y)}; out.radius = r end
    -- the chunk lists, a group per source (visible) or per nearest radar and distance outside its scan (the others):
    -- {by or radar, outside, n, chunks "x,y x,y ..."}
    local groups = {{}, {}, {}}
    local function put(list, set, key, cx, cy, by, outside)
      local g = groups[set][key]
      if not g then
        g = set == 1 and {by=by} or {radar=by, outside=outside}
        g.n = 0; g.at = {}; groups[set][key] = g; list[#list+1] = g
      end
      g.n = g.n + 1
      g.at[g.n] = string.format('%d,%d', cx, cy)
    end
    local kinds = {visible=0, charted=0, uncharted=0}
    local unknown = 0
    for cy = cy0, cy1 do
      local runs, run = {}, nil
      for cx = cx0, cx1 do
        local i = (cy - cy0) * w + (cx - cx0) + 1
        local state, by, outside
        if vis[i] then
          state = 'visible'
          local rd = best[i]
          local y = eye[i]
          if rd and rd.ok then by = source(rd.e, 'radar', rd.r)
          elseif y then by = source(y.e, y.kind, y.r)
          elseif rd then by = source(rd.e, 'radar', rd.r)
          else unknown = unknown + 1 end
          if by then sources[by].gives = (sources[by].gives or 0) + 1 end
          put(out.visible, 1, by or 0, cx, cy, by)
        else
          state = cha[i] and 'charted' or 'uncharted'
          local rd, o = nearest(cx, cy)
          if rd then by, outside = source(rd.e, 'radar', rd.r), o end
          put(cha[i] and out.charted or out.uncharted, cha[i] and 2 or 3, by and by * 4096 + outside or -1, cx, cy, by, outside)
        end
        kinds[state] = kinds[state] + 1
        if run and run.state == state and run.by == by then
          run.x1 = cx
          if outside then run.o0, run.o1 = math.min(run.o0, outside), math.max(run.o1, outside) end
        else
          run = {state=state, by=by, x0=cx, x1=cx, o0=outside, o1=outside}
          runs[#runs+1] = run
        end
      end
      local parts = {}
      for _, u in ipairs(runs) do
        local src = u.by and sources[u.by]
        local tail
        if u.state == 'visible' then
          tail = src and string.format(' (%s #%d)', src.kind, src.unit_number or 0) or ' (no source of ours covers it now)'
        elseif src then
          tail = string.format(' (radar #%d, %s outside its scan)', src.unit_number or 0, u.o0 == u.o1 and string.format('%d', u.o0) or string.format('%d-%d', u.o0, u.o1))
        else tail = ' (no radar of ours on this surface)' end
        parts[#parts+1] = u.state .. ' ' .. run_text(u.x0, u.x1) .. tail
      end
      out.rows[#out.rows+1] = string.format('row y=%d: %s', cy, table.concat(parts, '; '))
    end
    for _, list in ipairs({out.visible, out.charted, out.uncharted}) do
      for _, g in ipairs(list) do g.chunks = table.concat(g.at, ' '); g.at = nil end
    end
    out.counts = kinds
    local lines = out.lines
    lines[#lines+1] = string.format('%s: chunks x %d..%d, y %d..%d (tiles %d,%d to %d,%d), %d chunks (cap %d): %d visible now, %d charted (not visible), %d uncharted',
      s.name, cx0, cx1, cy0, cy1, cx0 * 32, cy0 * 32, (cx1 + 1) * 32, (cy1 + 1) * 32, n, MAX, kinds.visible, kinds.charted, kinds.uncharted)
    -- the sources that give the most sight here first, at most LINES of them
    local order = {}
    for i = 1, #sources do order[i] = i end
    table.sort(order, function(x, y) return (sources[x].gives or 0) > (sources[y].gives or 0) or ((sources[x].gives or 0) == (sources[y].gives or 0) and x < y) end)
    for k, i in ipairs(order) do
      if k > LINES then lines[#lines+1] = string.format('%d more sources (sources)', #order - LINES); break end
      local src = sources[i]
      local gives = src.gives or 0
      if src.kind == 'radar' then
        lines[#lines+1] = string.format('radar #%d %s at (%d,%d), chunk (%d,%d), %s: continuous scan %d chunks either axis; gives sight to %d chunks here%s',
          src.unit_number or 0, src.name, src.px, src.py, src.qx, src.qy, src.status, src.range, gives, gives == 0 and ' (the nearest radar to chunks not visible)' or '')
      else
        lines[#lines+1] = string.format('%s #%d at (%d,%d), chunk (%d,%d): sight %d chunks either axis; gives sight to %d chunks here',
          src.kind, src.unit_number or 0, src.px, src.py, src.qx, src.qy, src.range, gives)
      end
    end
    if unknown > 0 then lines[#lines+1] = string.format('%d visible chunks no source of ours covers now: a chunk stays visible about 10 s (560-600 ticks) after its source stops or goes, and a radar\'s long-range scan lights one chunk at a time', unknown) end
    if #R == 0 then lines[#lines+1] = 'no radar of ours on ' .. s.name end
    for _, src in ipairs(sources) do src.px, src.py, src.qx, src.qy = nil, nil, nil, nil end
    return out
  end
  M.schema = {sight = {surface='optional planet or surface name (remote: no character move)',
    position='{x,y}: the centre (default where your character stands)', radius='16..' .. MAX_R .. ' tiles round position (default ' .. DEF_R .. '): the chunks that square touches',
    area='or {left_top={x,y}, right_bottom={x,y}} (or [[x0,y0],[x1,y1]]): the chunks it touches',
    returns='at most ' .. MAX .. ' chunks a call (more is refused, naming the count). As a player\'s map shows it, in chunk coordinates (chunk x covers tiles x*32..x*32+31): '
      .. 'visible [{by, n, chunks}] (chunks our force sees now, a group per source; by: the index in sources; chunks "x,y x,y ..."), '
      .. 'charted [{radar, outside, n, chunks}] (charted, not visible) and uncharted [{radar, outside, n, chunks}] (a group per nearest radar of ours and outside: chunks outside its continuous scan, 0 inside it while it is not working); '
      .. 'sources [{kind (radar, roboport, cargo-landing-pad, spidertron), unit_number, position "x,y", chunk "x,y", range (chunks either axis), gives (visible chunks here it is the source of), and a radar\'s name and status (working, no_power, ...)}] '
      .. '(a visible chunk\'s source: the nearest working radar whose continuous scan covers it, else the nearest roboport (2 chunks), cargo landing pad (4) or spidertron (2) covering it, else a radar not working; '
      .. 'characters, cars and tanks give no sight; a chunk stays visible about 10 s after its source stops or goes); '
      .. 'rows (one line a chunk row: runs of visible, charted and uncharted with their source), counts, chunk_area, tiles, lines (the first ' .. LINES .. ' sources by chunks they give). Read only'}}
  return M
end
