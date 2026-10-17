-- linecut: a long belt or pipe line cut, as a team alert naming the cut tiles (d17 batch17 C1, Opus, every shift: a
-- 2-tile gap at (422.5,-249) idled 10 drills unnoticed; the belt-cut tells of batch13 went to the nearest agent, or to
-- nobody when the belt carried nothing as it died). What a player sees on the map: the line's tiles either side of the
-- gap and nothing between them.
-- On a belt's or pipe's death (runtime.lua on_entity_died, the entity still there): its line is followed through its
-- neighbours up to WALK tiles each way (belts: the belt neighbours, an underground to its pair; pipes: the fluid
-- neighbours); one that leaves LONG tiles or more of line is a cut. A death within MERGE tiles of a cut kept on the
-- same surface joins it (one raid, one gap), without a walk. alert_groups gives each cut as a group for the team's
-- alerts (pushalerts.lua, as beltgaps' cuts): its tiles, what destroyed them, how far the line runs either side, what
-- it carried; a cut whose tiles all stand again (any belt or pipe of ours on each) or older than KEEP is gone.
-- Cost: one walk of at most 2 x WALK neighbour reads per death not joining a cut; a look per cut tile when the alerts
-- are built (every few seconds).
return function(api)
  local M = {}
  local WALK, LONG, MERGE, KEEP, MAX = 24, 8, 3, 108000, 32
  local BELTS = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local PIPES = {pipe=true, ['pipe-to-ground']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store() local s = api.state(); s.linecut = s.linecut or {seq=0, cuts={}}; return s.linecut end
  local function key(e) return e.unit_number or (e.position.x .. ',' .. e.position.y) end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end

  -- The belts one way from e (way: 'inputs' or 'outputs'), up to WALK: {n, last, items}
  local function belt_walk(e, way)
    local seen, cur, n, last, items = {[key(e)]=true}, e, 0, nil, {}
    for _ = 1, WALK do
      local list = try(function() return cur.belt_neighbours[way] end) or {}
      local nxt = list[1]
      if not nxt and cur.type == 'underground-belt' then
        local pair = try(function() return cur.neighbours end)
        local t = try(function() return cur.belt_to_ground_type end)
        if pair and try(function() return pair.valid end) and ((way == 'inputs' and t == 'output') or (way == 'outputs' and t == 'input')) then nxt = pair end
      end
      if not (nxt and try(function() return nxt.valid end)) or seen[key(nxt)] then break end
      seen[key(nxt)] = true; n = n + 1; cur = nxt; last = nxt.position
      for i = 1, try(function() return nxt.get_max_transport_line_index() end) or 0 do
        for _, c in ipairs(try(function() return nxt.get_transport_line(i).get_contents() end) or {}) do items[c.name] = (items[c.name] or 0) + c.count end
      end
    end
    return {n=n, last=last, items=items}
  end
  -- The pipes on each side of p (its fluid neighbours as two starts), up to WALK each: {{n, last}, {n, last}}, fluid
  local function pipe_walk(p)
    local starts = {}
    for _, group in ipairs(try(function() return p.neighbours end) or {}) do
      for _, nb in ipairs(type(group) == 'table' and group or {}) do
        if try(function() return nb.valid end) and PIPES[nb.type] then starts[#starts+1] = nb end
      end
    end
    local out = {}
    for i = 1, math.min(2, #starts) do
      local seen, cur, n, last = {[key(p)]=true}, starts[i], 1, starts[i].position
      seen[key(cur)] = true
      for _ = 1, WALK - 1 do
        local nxt
        for _, group in ipairs(try(function() return cur.neighbours end) or {}) do
          for _, nb in ipairs(type(group) == 'table' and group or {}) do
            if not nxt and try(function() return nb.valid end) and PIPES[nb.type] and not seen[key(nb)] then nxt = nb end
          end
        end
        if not nxt then break end
        seen[key(nxt)] = true; n = n + 1; cur = nxt; last = nxt.position
      end
      out[i] = {n=n, last=last}
    end
    local fluid = try(function() local f = p.fluidbox[1]; return f and f.name end)
    return out, fluid
  end

  -- on_entity_died of one of ours (the entity still there).
  function M.note(event)
    local e = event.entity
    if not (e and e.valid) then return end
    local kind = BELTS[e.type] and 'belt' or PIPES[e.type] and 'pipe' or nil
    if not kind then return end
    local st = store()
    local s = e.surface.name
    local pos = {x=e.position.x, y=e.position.y}
    local cause = event.cause and try(function() return event.cause.valid and event.cause.name end)
    local placer = try(function() return e.last_user and e.last_user.name end)
    for _, c in ipairs(st.cuts) do
      if c.surface == s and c.kind == kind then
        for _, q in ipairs(c.tiles) do
          if math.abs(q.x - pos.x) <= MERGE and math.abs(q.y - pos.y) <= MERGE then
            c.tiles[#c.tiles+1] = {x=pos.x, y=pos.y, name=e.name}; c.tick = event.tick
            if cause then c.causes[cause] = (c.causes[cause] or 0) + 1 end
            if placer then c.placers[placer] = true end
            return
          end
        end
      end
    end
    local a, b, carried
    if kind == 'belt' then
      local up, down = belt_walk(e, 'inputs'), belt_walk(e, 'outputs')
      a, b = {n=up.n, last=up.last}, {n=down.n, last=down.last}
      carried = {}
      for name, n in pairs(up.items) do carried[#carried+1] = name end
      table.sort(carried)
    else
      local sides, fluid = pipe_walk(e)
      a, b = sides[1] or {n=0}, sides[2] or {n=0}
      carried = fluid and {fluid} or {}
    end
    if a.n + b.n < LONG or #st.cuts >= MAX then return end
    st.seq = st.seq + 1
    st.cuts[#st.cuts+1] = {id=st.seq, kind=kind, surface=s, force=e.force.name, tick=event.tick, first=event.tick,
      tiles={{x=pos.x, y=pos.y, name=e.name}}, causes=cause and {[cause]=1} or {}, placers=placer and {[placer]=true} or {},
      a=a, b=b, carried=carried}
  end

  -- The cuts as alert groups for force (pushalerts.lua); rebuilt or old ones dropped.
  function M.alert_groups(force)
    local st = store()
    local keep, out = {}, {}
    for _, c in ipairs(st.cuts) do
      local surface = game.get_surface(c.surface)
      local open = {}
      for _, q in ipairs(c.tiles) do
        local there = surface and try(function()
          return surface.find_entities_filtered{position={q.x, q.y}, type=c.kind == 'belt' and {'transport-belt', 'underground-belt', 'splitter'} or {'pipe', 'pipe-to-ground'}, force=c.force, limit=1}[1]
        end)
        if not there then open[#open+1] = q end
      end
      if #open > 0 and game.tick - c.tick <= KEEP then
        keep[#keep+1] = c
        if c.force == force.name then
          local names, by, causes = {}, {}, {}
          for _, q in ipairs(open) do names[q.name] = (names[q.name] or 0) + 1 end
          for name in pairs(c.placers) do by[name] = 1 end
          for name, n in pairs(c.causes) do causes[#causes+1] = n .. ' by ' .. name end
          table.sort(causes)
          local spots = {}
          for i, q in ipairs(open) do if i <= 4 then spots[i] = at(q) end end
          local sx, sy = 0, 0
          for _, q in ipairs(open) do sx, sy = sx + q.x, sy + q.y end
          local g = {key='line_cut|' .. c.id, kind='line_cut', surface=c.surface, n=#open, names=names, by=by, at={},
            center={x=math.floor(sx / #open + 0.5), y=math.floor(sy / #open + 0.5)}, rank=c.tick}
          for i, q in ipairs(open) do if i <= 4 then g.at[i] = {x=q.x, y=q.y} end end
          local side = function(s) return s.n > 0 and string.format('%d tile%s to %s', s.n, s.n == 1 and '' or 's', s.last and at(s.last) or '?') or 'nothing' end
          g.line = string.format('%s line cut at %s%s: %d tile%s gone%s, %ds ago, none rebuilt; the line runs %s on one side, %s on the other%s',
            c.kind, table.concat(spots, ', '), #open > 4 and string.format(' +%d more', #open - 4) or '', #open, #open == 1 and '' or 's',
            #causes > 0 and ' (' .. table.concat(causes, ', ') .. ')' or '', math.floor((game.tick - c.tick) / 60),
            side(c.a), side(c.b), #c.carried > 0 and '; it carried ' .. table.concat(c.carried, ', ', 1, math.min(4, #c.carried)) or '')
          out[#out+1] = g
        end
      end
    end
    st.cuts = keep
    return out
  end
  return M
end
