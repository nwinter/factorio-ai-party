-- trace {position, upstream: true}: from a target back along what feeds it, to the first place an ingredient stops
-- or goes elsewhere (Sol, Luna, Astra, Grok; d15 shifts 19-20: Starling drifted backwards ~8 min while an arm at
-- (9.5,2.5) sent all its ore onto a furnace belt; Swift's ammo starved behind a jammed mixed return; Grok walked a coal
-- tour while coal sat on the copper ore lane). Per ingredient the target lacks (all: every one; item: that one):
-- - the inserters feeding it: a filter that does not let it through, an inserter off by its circuit condition (the
--   condition and the signal on its wires), what each holds;
-- - a chest or machine an inserter reads: what it holds, and what fills it;
-- - a belt an inserter reads: each lane it picks, walked upstream (undergrounds, splitters, side-loads) tile by tile:
--   the lane at the inserter (full, front item: a jammed mixed lane), the first tile back where the ingredient is on
--   it, inserters taking it off the lane on the way (elsewhere: onto another belt, into a chest, into a machine with
--   another recipe; with status, filter and what each holds; ones feeding machines like the target are counted), a
--   splitter filter that sends it to the other side, where it comes onto the lane (an inserter, a drill, a side-load,
--   with what that reads), and the first tile where another item joins the lane and from what;
-- - a machine making it (at a lane's start, or read straight by an inserter): its state, and (one level down) why it
--   stops, traced the same way.
-- A thruster: each fluid input through pipes and pumps (thrust.lua) to the machines making it, each traced as above
-- (thruster fuel and oxidizer back through crushers to the collectors). A hub, chest or belt tile: what is put into it
-- (item: that item), each source traced the same way. Bounded: 800 belt tiles (500 a lane), 16 lane walks, depth 2.
return function(api, H)
  local M = {}
  local try, at, place, side, status = H.try, H.at, H.place, H.side, H.status
  local BELT, CRAFTER, CONTAINER = H.BELT, H.CRAFTER, H.CONTAINER
  -- On a copy of world n a walk cost about 0.08 ms a belt tile in the container (about 0.02 ms on n): 800 tiles stay
  -- under the 20 ms rule.
  local MAX_TILES, MAX_WALKS, MAX_DEPTH, MAX_LIST, MAX_LANE = 800, 16, 2, 4, 500

  -- An item or filter name, userdata-safe (2.0 gives prototypes for some filters and qualities).
  local function name_of(v)
    if type(v) == 'string' then return v end
    local n = v ~= nil and try(function() return v.name end)
    if type(n) == 'string' then return n end
    n = n ~= nil and try(function() return n.name end)
    return type(n) == 'string' and n or nil
  end
  local function fuel(item) return (try(function() return prototypes.item[item].fuel_value end) or 0) > 0 end
  -- What the target does with an item, said on a join: 'which it uses', 'which it burns as fuel', else nil.
  local function use_of(target, item, uses)
    if uses[item] then return 'which it uses' end
    if try(function() return target.burner end) and fuel(item) then return 'which it burns as fuel' end
  end
  local function machine_state(e)
    local st = status(e)
    if st == 'disabled_by_control_behavior' and api.state_text then return try(function() return api.state_text(e) end) or st end
    return st
  end
  local function recipe_name(e)
    local r = H.recipe_of(e)
    return r and r.name
  end
  local function output_inv(e)
    if CRAFTER[e.type] then return H.output_of(e) end
    if e.type == 'asteroid-collector' then return H.inventory(e, 'asteroid_collector_output') end
    if e.type == 'space-platform-hub' then return try(function() return e.get_inventory(defines.inventory.hub_main) end) end
    if e.type == 'lab' then return nil end
    return H.main(e)
  end
  local function contents(inv)
    local m = {}
    for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local n = name_of(c.name)
      if n then m[n] = (m[n] or 0) + c.count end
    end
    return m
  end
  -- Items on line k of a belt (any index: a splitter has 8, an underground 4).
  local function lane_items(e, k)
    local m = {}
    for _, c in ipairs(try(function() return e.get_transport_line(k).get_contents() end) or {}) do
      local n = name_of(c.name)
      if n then m[n] = (m[n] or 0) + c.count end
    end
    return m
  end
  -- Whether a source an inserter reads can give item: it holds some, or a machine there makes it.
  local function gives(src, item, m)
    if not item or m[item] then return true end
    if not (src and src.valid) then return false end
    if CRAFTER[src.type] then
      local r = H.recipe_of(src)
      for _, pr in ipairs(r and try(function() return r.products end) or {}) do if pr.name == item then return true end end
    end
    if src.type == 'mining-drill' then return drill_items(src)[item] ~= nil end
    return false
  end
  -- What a drill drops: its resource's products.
  local function drill_items(d)
    local m = {}
    local res = try(function() return d.mining_target end)
    local mp = res and try(function() return res.prototype.mineable_properties end)
    for _, pr in ipairs(mp and mp.products or {}) do if pr.name then m[pr.name] = 1 end end
    return m
  end

  -- Per 32-tile cell: inserters (trace.lua's index) and mining drills by what they drop onto.
  local function drills_of(surface, force)
    local cache = {}
    return function(e)
      local cx, cy = math.floor(e.position.x / 32), math.floor(e.position.y / 32)
      local key = cx .. ',' .. cy
      local c = cache[key]
      if not c then
        c = {}
        for _, d in ipairs(try(function() return surface.find_entities_filtered{type='mining-drill', force=force,
          position={x=cx * 32 + 16, y=cy * 32 + 16}, radius=28, limit=2048} end) or {}) do
          local t = try(function() return d.drop_target end)
          local k = t and t.unit_number
          if k then c[k] = c[k] or {}; table.insert(c[k], d) end
        end
        cache[key] = c
      end
      return c[e.unit_number] or {}
    end
  end

  -- The lanes feeding lane k of belt e, upstream: the same internal line on an input belt (or the input underground
  -- of an output one), else the lines that feed it here (a splitter's inputs, a belt that ends onto it).
  local function prev_lanes(e, k, bn)
    local line = try(function() return e.get_transport_line(k) end)
    if not line then return {} end
    local cands = {}
    bn = bn or try(function() return e.belt_neighbours end)
    for _, n in ipairs(bn and bn.inputs or {}) do cands[#cands+1] = n end
    if e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'output' then
      local nb = try(function() return e.neighbours end)
      if nb and nb.valid then cands[#cands+1] = nb end
    end
    for _, n in ipairs(cands) do
      for j = 1, try(function() return n.get_max_transport_line_index() end) or 0 do
        if try(function() return n.get_transport_line(j).line_equals(line) end) then return {{e=n, k=j}} end
      end
    end
    local near = {[e.unit_number or 0] = true}
    for _, n in ipairs(cands) do near[n.unit_number or 0] = true end
    local out = {}
    for _, o in ipairs(try(function() return line.input_lines end) or {}) do
      local owner = try(function() return o.owner end)
      if owner and owner.valid and near[owner.unit_number or 0] and BELT[owner.type] then
        for j = 1, try(function() return owner.get_max_transport_line_index() end) or 0 do
          local l = try(function() return owner.get_transport_line(j) end)
          if l and (l == o or try(function() return l.line_equals(o) end)) then out[#out+1] = {e=owner, k=j}; break end
        end
      end
    end
    return out
  end
  -- Belts side-loading onto lane k of e (perpendicular inputs on a straight belt or an underground, onto the lane
  -- nearest them).
  local function side_loaders(e, k, bn)
    local out = {}
    if not (bn and bn.inputs and #bn.inputs > 1 or e.type == 'underground-belt' and bn and bn.inputs and #bn.inputs > 0) then return out end
    if not (e.type == 'underground-belt' or (e.type == 'transport-belt' and try(function() return e.belt_shape end) == 'straight')) then return out end
    for _, b in ipairs(bn.inputs) do
      if b.valid and b.direction ~= e.direction and H.lane_near(e, b.position) == k then out[#out+1] = b end
    end
    return out
  end
  -- Whether lane k of splitter sp passes item toward the side `toward` (the output the walk came back from):
  -- the filtered item goes to the priority side, everything else to the other.
  local function splitter_blocks(sp, item, toward)
    local f = H.splitter_filter(sp)
    local prio = try(function() return sp.splitter_output_priority end)
    if not (f and item and (prio == 'left' or prio == 'right') and toward) then return nil end
    if (f == item) ~= (toward == prio) then
      return string.format('%s %s filter %s to the %s: %s goes to the %s output, and this lane comes from the %s', sp.name, at(sp.position), f, prio,
        item, f == item and prio or (prio == 'left' and 'right' or 'left'), toward)
    end
  end
  local function list_text(m, limit)
    local list = {}
    for n, c in pairs(m) do list[#list+1] = {n=n, c=c} end
    table.sort(list, function(x, y) if x.c ~= y.c then return x.c > y.c end return x.n < y.n end)
    local parts = {}
    for i = 1, math.min(limit or 3, #list) do parts[i] = list[i].c .. ' ' .. list[i].n end
    return #parts > 0 and table.concat(parts, ', ') .. (#list > (limit or 3) and ', ...' or '') or 'nothing'
  end
  local function inserter_text(i)
    local name, n = H.hand(i)
    local fl = H.filters_of(i)
    return string.format('%s %s %s%s%s', i.name, at(i.position), machine_state(i), fl and ' filter ' .. H.filter_text(fl) or '',
      name and string.format(', holding %d %s', n, name) or '')
  end
  -- Where an inserter puts what it takes, said as a place.
  local function into_text(t)
    if not (t and t.valid) then return 'onto the ground' end
    if BELT[t.type] then return 'onto ' .. place(t) end
    local r = CRAFTER[t.type] and recipe_name(t)
    return 'into ' .. place(t) .. (r and ' (recipe ' .. r .. ')' or '')
  end

  -- One lane walked upstream from (e, k). ctx: {target, item, uses, idx_of, drills_at, seen, budget, mine (feeders)}.
  -- Returns {tiles, first_at, takers, shares, sources, joins, stop, blocked, at_start}.
  local function walk_lane(ctx, e, k, toward0)
    local item = ctx.item
    local w = {tiles=0, takers={}, shares=0, share_names={}, sources={}, joins={}, path={}}
    local visited = {}
    local last, toward = nil, toward0
    local run, run_from, run_side, run_name
    local function close(pos)
      if run then
        w.path[#w.path+1] = run == 1 and string.format('%s %s %s lane', run_name, at(run_from), run_side)
          or string.format('%s %s to %s %s lane (%d tiles)', run_name, at(run_from), at(pos), run_side, run)
        run = nil
      end
    end
    local joined = {}
    local function foreign(m, where, what)
      for n in pairs(m) do
        if n ~= item and not joined[n] then
          joined[n] = true
          w.joins[#w.joins+1] = {tile=w.tiles, item=n, text=string.format('%s joins the %s lane at %s from %s%s', n, side(k), place(where), what,
            use_of(ctx.target, n, ctx.uses) and ' (' .. use_of(ctx.target, n, ctx.uses) .. ')' or '')}
        end
      end
    end
    while true do
      if ctx.budget.tiles >= MAX_TILES then close(last and last.position or e.position); w.stop = 'walk capped at ' .. MAX_TILES .. ' belt tiles'; break end
      if w.tiles >= MAX_LANE then close(last and last.position or e.position); w.stop = 'lane walk capped at ' .. MAX_LANE .. ' tiles back'; break end
      if ctx.seen and not ctx.seen(e.position) then
        close(last and last.position or e.position)
        w.stop = 'out of sight at ' .. at(e.position) .. ' (what is on it there is unknown)'
        break
      end
      local key = tostring(e.unit_number) .. ':' .. k
      if visited[key] or ctx.walked[key] then close(last and last.position or e.position); w.stop = 'meets a lane already walked at ' .. place(e) .. ' ' .. side(k) .. ' lane'; break end
      visited[key] = true; ctx.walked[key] = true
      ctx.budget.tiles = ctx.budget.tiles + 1
      w.tiles = w.tiles + 1
      local here = lane_items(e, k)
      -- The lane itself: the first tile back where the item is on it; another item on it here.
      if item and (here[item] or 0) > 0 and not w.first_at then w.first_at = {tile=w.tiles, e=e} end
      if run and run_name == e.name and run_side == side(k) and e.type == 'transport-belt' then run = run + 1
      else
        close(last and last.position or e.position)
        if e.type == 'transport-belt' then run, run_from, run_side, run_name = 1, e.position, side(k), e.name
        else
          local f = e.type == 'splitter' and H.splitter_filter(e)
          w.path[#w.path+1] = string.format('%s %s %s lane%s', e.name, at(e.position), side(k),
            f and string.format(' (filter %s to the %s)', f, try(function() return e.splitter_output_priority end) or '?') or '')
        end
      end
      -- A splitter whose filter sends the item to the other output.
      if e.type == 'splitter' and toward then
        local b = splitter_blocks(e, item, toward)
        if b then w.blocked = {tile=w.tiles, text=b}; close(e.position); w.stop = b; break end
      end
      -- Inserters taking from this tile (not the target's own feeders): elsewhere, or into machines like the target.
      for _, row in ipairs(ctx.idx_of(e).by_pick[e.unit_number] or {}) do
        local i, t = row.e, row.drop
        if i.valid and not ctx.mine[i.unit_number] and not ctx.counted[i.unit_number] and H.picks_lane(i, k) then
          ctx.counted[i.unit_number] = true
          local fl = H.filters_of(i)
          if (not item or H.allows(fl, item)) and (not item or H.accepts(t, item, ctx.pk)) then
            local like = t and t.valid and t ~= ctx.target and t.name == ctx.target.name and recipe_name(t) == recipe_name(ctx.target)
            if t == ctx.target or like then
              w.shares = w.shares + 1
              if like and #w.share_names < 2 then w.share_names[#w.share_names+1] = place(t) end
            elseif #w.takers < 8 then
              local name = H.hand(i)
              w.takers[#w.takers+1] = {tile=w.tiles, holding=item and name == item, off=status(i) == 'disabled_by_control_behavior', text=inserter_text(i) .. ' takes it ' .. into_text(t)
                .. string.format(' (%d tiles back)', w.tiles - 1)}
            end
          end
        end
      end
      -- What comes onto the lane here: inserters and drills dropping onto it, belts side-loading onto it.
      local function arrive(m, where, what, src, named)
        if item and (named or gives(src, item, m)) then
          w.sources[#w.sources+1] = {tile=w.tiles, text=what, src=src}
          local rest = {}
          for n, c in pairs(m) do if n ~= item then rest[n] = c end end
          foreign(rest, where, what)
        else foreign(m, where, what) end
      end
      for _, row in ipairs(ctx.idx_of(e).by_drop[e.unit_number] or {}) do
        local i = row.e
        if i.valid and H.drop_lane(e, i) == k then
          local m, src = {}, row.pick
          local name, n = H.hand(i)
          if name then m[name] = n end
          if src and src.valid and not BELT[src.type] then for nm, c in pairs(contents(output_inv(src))) do m[nm] = (m[nm] or 0) + c end
          elseif src and src.valid then for nm, c in pairs(H.items_on(src)) do m[nm] = (m[nm] or 0) + c end end
          -- Only what its filter lets through (an inserter from the hub filtered to iron-ore puts nothing else here).
          local fl = H.filters_of(i)
          if fl then for nm in pairs(m) do if not H.allows(fl, nm) then m[nm] = nil end end end
          arrive(m, e, inserter_text(i) .. (src and src.valid and ' from ' .. place(src) or ''), src,
            item and fl and fl.mode ~= 'blacklist' and H.allows(fl, item))
        end
      end
      for _, d in ipairs(ctx.drills_at(e)) do
        if d.valid and H.drop_lane(e, d) == k then arrive(drill_items(d), e, string.format('%s %s %s', d.name, at(d.position), machine_state(d)), d) end
      end
      local bn = try(function() return e.belt_neighbours end)
      for _, b in ipairs(side_loaders(e, k, bn)) do
        local m = H.upstream_items(b)
        arrive(m, e, string.format('%s side-loading (carrying %s)', place(b), list_text(m)), nil)
        if item and m[item] and #ctx.queue < MAX_WALKS then
          for j = 1, 2 do ctx.queue[#ctx.queue+1] = {e=b, k=j, from=place(b) .. ' ' .. side(j) .. ' lane, side-loading onto ' .. place(e)} end
        end
      end
      local prev = prev_lanes(e, k, bn)
      if #prev == 0 then
        close(e.position)
        w.stop = string.format('the lane starts at %s (%s lane %s)', place(e), side(k), list_text(here))
        w.start = e
        break
      end
      -- Several lanes feed it (a splitter's two inputs): the first walked on, the others queued.
      for x = 2, #prev do
        if #ctx.queue < MAX_WALKS then ctx.queue[#ctx.queue+1] = {e=prev[x].e, k=prev[x].k, from='the other input of ' .. place(e) .. ' ' .. side(k) .. ' lane'} end
      end
      local nxt = prev[1].e
      -- Coming back into a splitter: the side of it this lane leaves by.
      if nxt.type == 'splitter' and nxt ~= e then toward = H.splitter_side(nxt, e) elseif nxt ~= e then toward = nil end
      last = e
      e, k = nxt, prev[1].k
    end
    return w
  end

  -- The headline for one lane: the first place (in the direction items move) where the item stops or goes elsewhere.
  local function lane_line(ctx, w, start_text)
    local item = ctx.item
    local parts = {}
    local reach = 0
    for _, s in ipairs(w.sources) do reach = math.max(reach, s.tile) end
    if w.first_at then reach = math.max(reach, w.first_at.tile) end
    local takers, off = {}, {}
    for _, t in ipairs(w.takers) do
      if not item or reach == 0 or t.tile <= reach then
        if t.off then off[#off+1] = t else takers[#takers+1] = t end
      end
    end
    table.sort(takers, function(x, y) return x.tile > y.tile end)
    table.sort(off, function(x, y) return x.tile > y.tile end)
    local head
    if w.blocked then parts[#parts+1] = 'stops at ' .. w.blocked.text; head = parts[#parts] end
    if item then
      if #takers > 0 and reach > 0 then
        parts[#parts+1] = 'goes elsewhere first at ' .. takers[1].text .. (#takers > 1 and string.format(' (+%d more taking it off this lane)', #takers - 1) or '')
        head = head or parts[#parts]
      elseif #takers > 0 then
        parts[#parts+1] = string.format('%d inserter%s on the way would take it elsewhere, the first %s', #takers, #takers == 1 and '' or 's', takers[1].text)
      end
      if #off > 0 then
        parts[#parts+1] = string.format('%d inserter%s that would take it elsewhere %s off by its condition now: %s', #off, #off == 1 and '' or 's', #off == 1 and 'is' or 'are', off[1].text)
      end
      if w.first_at and w.first_at.tile == 1 then
        parts[#parts+1] = string.format('%s is on this lane at %s', item, place(w.first_at.e))
      elseif w.first_at then
        parts[#parts+1] = string.format('%s first on this lane %d tiles back, at %s', item, w.first_at.tile - 1, place(w.first_at.e))
      elseif not w.blocked then
        parts[#parts+1] = string.format('no %s on this lane for %d tiles back', item, w.tiles)
      end
      local none = not w.first_at and not w.blocked and parts[#parts]
      if #w.sources > 0 then
        table.sort(w.sources, function(x, y) return x.tile > y.tile end)
        parts[#parts+1] = 'comes onto it from ' .. w.sources[1].text .. string.format(' (%d tiles back)', w.sources[1].tile - 1)
        if none then head = head or none .. '; ' .. parts[#parts] end
      elseif not w.blocked then
        parts[#parts+1] = 'nothing found putting ' .. item .. ' onto it'
        if none then head = head or none .. ', and nothing found putting it onto it (' .. tostring(w.stop) .. ')' end
      end
    end
    if #w.joins > 0 then
      table.sort(w.joins, function(x, y) return x.tile > y.tile end)
      if item then parts[#parts+1] = 'first other item: ' .. w.joins[1].text
      else
        local list = {}
        for i = 1, math.min(MAX_LIST, #w.joins) do list[i] = w.joins[i].text end
        parts[#parts+1] = 'items come onto it (first first): ' .. table.concat(list, '; ') .. (#w.joins > MAX_LIST and '; ...' or '')
      end
    end
    if w.shares > 0 then parts[#parts+1] = string.format('%d inserter%s on the way feed%s machines like this one%s', w.shares, w.shares == 1 and '' or 's',
      w.shares == 1 and 's' or '', #w.share_names > 0 and ' (' .. table.concat(w.share_names, ', ') .. ')' or '') end
    if not w.blocked and w.stop then parts[#parts+1] = w.stop end
    return start_text .. ': ' .. table.concat(parts, '; '), head and start_text .. ': ' .. head
  end

  -- The fluid box index of fluid in machine e (its contents, else an input box filtered to it).
  local function fluid_index(e, fluid)
    local fb = try(function() return e.fluidbox end)
    for i = 1, (fb and try(function() return #fb end) or 0) do
      local f = try(function() return fb[i] end)
      if (f and f.name == fluid) or name_of(try(function() return fb.get_filter(i) end)) == fluid then return i end
    end
  end
  -- A jammed lane's cause downstream (Astra, d15: a thruster fuel path whose ore stood behind ice the ice plant, full of
  -- water, no longer took): the inserters on this lane, at the feeder's tile and up to DOWN tiles on, that take the front
  -- item, and where they put it; one into a machine with full output is the deadlock.
  local DOWN = 16
  local function front_takers(ctx, b, k, front)
    local line = try(function() return b.get_transport_line(k) end)
    local tiles, e = {b}, b
    for _ = 1, DOWN do
      local bn = try(function() return e.belt_neighbours end)
      local nxt
      for _, o in ipairs(bn and bn.outputs or {}) do
        for j = 1, try(function() return o.get_max_transport_line_index() end) or 0 do
          if line and try(function() return o.get_transport_line(j).line_equals(line) end) then nxt = o end
        end
      end
      if not nxt then break end
      tiles[#tiles+1] = nxt; e = nxt
    end
    local out, stuck = {}, false
    for _, t in ipairs(tiles) do
      for _, row in ipairs(ctx.idx_of(t).by_pick[t.unit_number] or {}) do
        local i, d = row.e, row.drop
        if i.valid and H.picks_lane(i, k) and H.allows(H.filters_of(i), front) and H.accepts(d, front, ctx.pk) and #out < 3 then
          local st = d and d.valid and status(d)
          local full = st == 'full_output' or st == 'waiting_for_space_in_destination'
          if full then stuck = true end
          out[#out+1] = string.format('%s %s %s takes %s %s%s', i.name, at(i.position), status(i), front, into_text(d), st and ' (' .. st .. ')' or '')
        end
      end
    end
    if #out == 0 then return string.format('no inserter on this lane within %d tiles takes %s', DOWN, front) end
    return (stuck and 'deadlock: ' or '') .. table.concat(out, '; ')
  end
  local trace_target
  -- A belt lane walk from a feeder, with its own findings: the lane at the feeder, then the walk.
  local function trace_lane(ctx, b, k, from_text, depth, out)
    local l = H.lanes_of(b)
    local full = H.lane_full(b, k)
    local here = l[side(k)]
    local lane = {from=from_text, at_feeder=string.format('%s lane %s%s', side(k), H.lane_text(here), full and ' (full)' or '')}
    if full and ctx.item and not here[ctx.item] then
      local front = H.front_item(b, k)
      lane.jammed = string.format('the %s lane at %s is full and holds no %s (left lane %s, right lane %s)%s', side(k), place(b), ctx.item,
        H.lane_text(l.left), H.lane_text(l.right), front and ', front item ' .. front or '')
      if front then lane.jammed = lane.jammed .. '; ' .. front_takers(ctx, b, k, front) end
    end
    local w = walk_lane(ctx, b, k, nil)
    lane.path_back = table.concat(w.path, ' <- ')
    local line, head = lane_line(ctx, w, from_text)
    lane.line = (lane.jammed and lane.jammed .. '; ' or '') .. line
    lane.head = lane.jammed or head
    out.lanes[#out.lanes+1] = lane
    -- A machine at the source that is not working: one level down.
    for _, s in ipairs(w.sources) do
      local m = s.src
      if m and m.valid and (CRAFTER[m.type] or m.type == 'mining-drill') and depth < MAX_DEPTH and not ctx.explained[m.unit_number] then
        ctx.explained[m.unit_number] = true
        local st = status(m)
        if st ~= 'working' and CRAFTER[m.type] then
          local sub = trace_target(ctx.p, m, {all=ctx.all}, depth + 1, ctx)
          if sub then out.makers[#out.makers+1] = sub end
        elseif st ~= 'working' then out.makers[#out.makers+1] = {entity=m.name, position=m.position, line=place(m) .. ' ' .. machine_state(m)} end
      end
    end
  end
  -- One ingredient into the target: each feeder, its filter and state, what it reads, upstream.
  local function trace_item(ctx, tgt, w, depth, feeders)
    local item = w.item
    local row = {item=item, has=w.has, needs=w.amount, feeders={}, lanes={}, makers={}}
    local lines = {}
    local let = {}
    for _, f in ipairs(feeders) do
      local fl = H.filters_of(f.e)
      local text = inserter_text(f.e)
      if item and not H.allows(fl, item) then
        lines[#lines+1] = string.format('%s does not let %s through its filter', text, item)
      else
        let[#let+1] = f
        local st = status(f.e)
        if st == 'disabled_by_control_behavior' then lines[#lines+1] = 'stops at ' .. text end
        row.feeders[#row.feeders+1] = text .. ' takes from ' .. (f.pick and f.pick.valid and place(f.pick) or 'nothing at its pickup')
      end
    end
    if #feeders == 0 then lines[#lines+1] = 'no inserter feeds it'
    elseif #let == 0 then lines[#lines+1] = 'no inserter feeding it lets ' .. item .. ' through its filter' end
    local sub = {p=ctx.p, target=tgt.target, item=item, uses=tgt.uses, idx_of=ctx.idx_of, drills_at=ctx.drills_at, seen=ctx.seen, budget=ctx.budget,
      mine=tgt.mine, counted={}, walked={}, queue={}, pk=ctx.pk, explained=ctx.explained, all=ctx.all}
    for _, f in ipairs(let) do
      local src = f.pick
      if not (src and src.valid) then
        lines[#lines+1] = place(f.e) .. ': nothing at its pickup'
      elseif BELT[src.type] then
        for k = 1, 2 do
          if H.picks_lane(f.e, k) and ctx.budget.walks < MAX_WALKS then
            ctx.budget.walks = ctx.budget.walks + 1
            trace_lane(sub, src, k, string.format('%s picks %s %s lane', place(f.e), place(src), side(k)), depth, row)
          end
        end
      else
        local n = item and H.count(output_inv(src), item) or 0
        local text = string.format('%s reads %s, holding %s', place(f.e), place(src), item and (n .. ' ' .. item) or list_text(contents(output_inv(src))))
        if item and n == 0 then
          if CRAFTER[src.type] or src.type == 'mining-drill' or src.type == 'asteroid-collector' then
            text = text .. ' (' .. machine_state(src) .. ')'
            if CRAFTER[src.type] and depth < MAX_DEPTH and not ctx.explained[src.unit_number] then
              ctx.explained[src.unit_number] = true
              local m = trace_target(ctx.p, src, {all=ctx.all}, depth + 1, ctx)
              if m then row.makers[#row.makers+1] = m end
            end
          else
            -- A chest: what fills it (a requester or buffer chest: its request, which robots fill).
            local mode = src.type == 'logistic-container' and try(function() return src.prototype.logistic_mode end)
            if mode == 'requester' or mode == 'buffer' then
              local want = 0
              local secs = try(function() return src.get_logistic_sections() end)
              for k = 1, secs and secs.sections_count or 0 do
                local sec = try(function() return secs.get_section(k) end)
                for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
                  if name_of(f.value) == item then want = want + (f.min or 0) end
                end
              end
              text = text .. (want > 0 and string.format('; a %s chest requesting %d (robots fill it)', mode, want) or string.format('; a %s chest with no request for it', mode))
            end
            local fill = {}
            for _, r in ipairs(ctx.idx_of(src).by_drop[src.unit_number] or {}) do
              if #fill < MAX_LIST then fill[#fill+1] = inserter_text(r.e) .. (r.pick and r.pick.valid and ' from ' .. place(r.pick) or '') end
            end
            text = text .. (#fill > 0 and '; filled by ' .. table.concat(fill, '; ') or '; no inserter fills it')
          end
        end
        lines[#lines+1] = text
      end
    end
    -- Lanes queued on the way (a side-load or a splitter's other input that brings it): walked as their own lanes.
    while #sub.queue > 0 and ctx.budget.walks < MAX_WALKS do
      local q = table.remove(sub.queue, 1)
      ctx.budget.walks = ctx.budget.walks + 1
      trace_lane(sub, q.e, q.k, q.from, depth, row)
    end
    -- The summary: the feeders' and chests' lines, each lane's first problem (lanes has every lane in full), the makers.
    local fine = 0
    for _, l in ipairs(row.lanes) do
      if l.head then lines[#lines+1] = l.head else fine = fine + 1 end
      l.head = nil
    end
    if fine > 0 then lines[#lines+1] = string.format('%d lane%s with no stop found (lanes)', fine, fine == 1 and '' or 's') end
    for _, m in ipairs(row.makers) do lines[#lines+1] = 'its maker ' .. (m.line or place(m)) end
    row.line = string.format('%s%s: ', item or 'what it takes', item and string.format(' (has %s of %s)', tostring(w.has), tostring(w.amount)) or '') .. table.concat(lines, '; ')
    if #row.feeders == 0 then row.feeders = nil end
    if #row.makers == 0 then row.makers = nil end
    return row
  end

  -- What a target takes: a crafter's or lab's ingredients (H.wants), a thruster's fluids, else the item given.
  local budget_of = setmetatable({}, {__mode='k'})
  trace_target = function(p, e, a, depth, parent)
    a = a or {}
    local ctx
    if parent then
      ctx = {p=parent.p, idx_of=parent.idx_of, drills_at=parent.drills_at, seen=parent.seen, budget=parent.budget, walked=parent.walked,
        explained=parent.explained, pk=parent.pk}
    else
      ctx = {p=p, idx_of=H.cells(e.surface, e.force), drills_at=drills_of(e.surface, e.force), seen=H.sight(p, e.surface),
        budget={tiles=0, walks=0}, walked={}, explained={[e.unit_number or 0]=true}, pk=H.packs(p)}
    end
    ctx.all = a.all
    local out = {entity=e.name, position=e.position, status=machine_state(e)}
    budget_of[out] = ctx.budget
    local list, what = H.wants(e, p)
    if e.type == 'thruster' then
      out.ingredients = {}
      local parts = {}
      for i = 1, (try(function() return #e.fluidbox end) or 0) do
        local f = try(function() return e.fluidbox[i] end)
        local name = f and f.name or name_of(try(function() return e.fluidbox.get_filter(i) end)) or ('input ' .. i)
        local up = api.fluid_upstream and api.fluid_upstream(e.fluidbox, i) or {pumps={}, makers={}, tanks={}}
        local row = {fluid=name, amount=f and math.floor(f.amount) or 0, makers={}}
        local bits = {string.format('%s %d', name, row.amount)}
        for _, pmp in ipairs(up.pumps) do if status(pmp) ~= 'working' then bits[#bits+1] = 'pump ' .. at(pmp.position) .. ' ' .. machine_state(pmp) end end
        if #up.makers == 0 then bits[#bits+1] = 'no machine making ' .. name .. ' is connected to it' end
        for _, m in ipairs(up.makers) do
          if depth < MAX_DEPTH + 1 and not ctx.explained[m.entity.unit_number] then
            ctx.explained[m.entity.unit_number] = true
            local sub = trace_target(p, m.entity, {all=ctx.all}, depth + 1, ctx)
            row.makers[#row.makers+1] = sub
            bits[#bits+1] = 'made by ' .. sub.line
          end
        end
        row.line = table.concat(bits, '; ')
        out.ingredients[#out.ingredients+1] = row
        parts[#parts+1] = row.line
      end
      out.line = place(e) .. ': ' .. table.concat(parts, ' | ')
      return out
    end
    local uses = {}
    for _, w in ipairs(list or {}) do uses[w.item] = true end
    local idx = ctx.idx_of(e)
    local feeders = {}
    for _, row in ipairs(idx.by_drop[e.unit_number] or {}) do if row.e.valid then feeders[#feeders+1] = row end end
    -- The target's own feeders, near it (a big machine's may lie in the next cell).
    local more = H.index(e.surface, e.force, {position=e.position, radius=H.radius_of(e) + 3})
    for _, row in ipairs(more.by_drop[e.unit_number] or {}) do
      local dup = false
      for _, f in ipairs(feeders) do if f.e == row.e then dup = true end end
      if not dup then feeders[#feeders+1] = row end
    end
    local tgt = {target=e, uses=uses, mine={}}
    for _, f in ipairs(feeders) do tgt.mine[f.e.unit_number] = true end
    local todo = {}
    if a.item ~= nil then
      local have = 0
      for _, w in ipairs(list or {}) do if w.item == a.item then have = w.has; todo[1] = w end end
      if not todo[1] then todo[1] = {item=a.item, amount='?', has=H.count(H.main(e) or (CRAFTER[e.type] and H.input_of(e)), a.item)} end
    elseif list then
      for _, w in ipairs(list) do
        if not w.fluid and (a.all or w.has < w.amount) then todo[#todo+1] = w end
      end
    end
    out.crafting = what
    out.ingredients = {}
    local lines = {}
    if not list and a.item == nil then
      -- A hub, chest or belt: what each feeder carries, each lane walked with no one item.
      out.ingredients[1] = trace_item(ctx, tgt, {item=nil, has='?', amount='?'}, depth, feeders)
      lines[1] = out.ingredients[1].line
    end
    for _, w in ipairs(todo) do
      local row = trace_item(ctx, tgt, w, depth, feeders)
      out.ingredients[#out.ingredients+1] = row
      lines[#lines+1] = row.line
    end
    -- A fluid ingredient it lacks (all: every one): by pipe to the machines making it.
    for _, w in ipairs(list or {}) do
      if w.fluid and (a.all or w.has < w.amount) and (a.item == nil) then
        local bits = {string.format('%s (a fluid, has %s of %s)', w.item, tostring(w.has), tostring(w.amount))}
        local index = fluid_index(e, w.item)
        local up = index and api.fluid_upstream and api.fluid_upstream(e.fluidbox, index) or {pumps={}, makers={}, tanks={}}
        for _, pmp in ipairs(up.pumps) do if status(pmp) ~= 'working' then bits[#bits+1] = 'pump ' .. at(pmp.position) .. ' ' .. machine_state(pmp) end end
        if #up.makers == 0 then bits[#bits+1] = 'no machine making ' .. w.item .. ' is connected to it' end
        local row = {item=w.item, has=w.has, needs=w.amount, fluid=true, makers={}}
        for _, m in ipairs(up.makers) do
          if depth < MAX_DEPTH and not ctx.explained[m.entity.unit_number] then
            ctx.explained[m.entity.unit_number] = true
            local sub = trace_target(p, m.entity, {all=ctx.all}, depth + 1, ctx)
            row.makers[#row.makers+1] = sub
            bits[#bits+1] = 'made by ' .. sub.line
          elseif #bits < 6 then bits[#bits+1] = 'made by ' .. place(m.entity) .. ' ' .. machine_state(m.entity) end
        end
        row.line = table.concat(bits, '; ')
        if #row.makers == 0 then row.makers = nil end
        out.ingredients[#out.ingredients+1] = row
        lines[#lines+1] = row.line
      end
    end
    if #lines == 0 then lines[1] = 'holds every ingredient for its next craft (all=true traces them all)' end
    out.line = string.format('%s %s%s: %s', place(e), machine_state(e), what and ' (' .. what .. ')' or '', table.concat(lines, ' | '))
    return out
  end

  -- trace {position, upstream: true} on a belt tile: both lanes (or those carrying something) walked back.
  local function from_belt(p, e, a)
    local ctx = {p=p, target=e, item=a.item, uses={}, idx_of=H.cells(e.surface, e.force), drills_at=drills_of(e.surface, e.force),
      seen=H.sight(p, e.surface), budget={tiles=0, walks=0}, mine={}, counted={}, walked={}, queue={}, pk=H.packs(p), explained={}}
    local row = {lanes={}, makers={}}
    for k = 1, 2 do
      ctx.budget.walks = ctx.budget.walks + 1
      trace_lane(ctx, e, k, place(e) .. ' ' .. side(k) .. ' lane', 0, row)
    end
    while #ctx.queue > 0 and ctx.budget.walks < MAX_WALKS do
      local q = table.remove(ctx.queue, 1)
      ctx.budget.walks = ctx.budget.walks + 1
      trace_lane(ctx, q.e, q.k, q.from, 0, row)
    end
    return {belt=e.name, position=e.position, item=a.item, lanes=row.lanes, makers=#row.makers > 0 and row.makers or nil,
      cost=string.format('%d belt tiles, %d lane walks', ctx.budget.tiles, ctx.budget.walks)}
  end

  function M.trace(p, a)
    local e = H.target(p, a)
    if a.item ~= nil then assert(type(a.item) == 'string' and prototypes.item[a.item], 'item must be an item name: ' .. tostring(a.item)) end
    if BELT[e.type] then return from_belt(p, e, a) end
    local out = trace_target(p, e, a, 0, nil)
    out.cost = string.format('%d belt tiles, %d lane walks', budget_of[out] and budget_of[out].tiles or 0, budget_of[out] and budget_of[out].walks or 0)
    budget_of[out] = nil
    return out
  end
  M.trace_target = trace_target
  M.prev_lanes, M.splitter_blocks, M.walk_lane = prev_lanes, splitter_blocks, walk_lane
  return M
end
