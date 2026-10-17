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
-- A line blocked by an entity on its tile (Sonnet, d17 12:20: a medium-electric-pole at (353.5,95.5), built before the
-- belt row, took one tile of it; the build said "placement blocked by" among 21 entries, the belt "they stop at its
-- end", and 6 drills stood waiting_for_space for an hour): on a build of ours (on_built_entity: the harness's builds
-- and a player's; robots' builds raise another event the mod does not forward), a belt facing into a tile that holds
-- no belt but another entity, with a belt beyond it within SPAN tiles facing the same way, is kept; after AGE ticks
-- it is a team alert of the same kind as a cut naming that entity, until the entity or either belt is gone or a belt
-- stands there. A cut tile something else now stands on names it too (M.blocker).
return function(api)
  local M = {}
  local WALK, LONG, MERGE, KEEP, MAX = 24, 8, 3, 108000, 32
  local SPAN, AGE, MAX_BLOCKED = 2, 1800, 32
  local VEC = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  -- What never takes a tile from a belt (the rest that stands there does).
  local PASS = {resource=true, character=true, ['character-corpse']=true, corpse=true, ['item-entity']=true, ['entity-ghost']=true,
    ['tile-ghost']=true, ['item-request-proxy']=true, ['highlight-box']=true, ['smoke-with-trigger']=true, ['particle-source']=true,
    projectile=true, ['artillery-projectile']=true, beam=true, stream=true, sticker=true, fire=true, explosion=true, unit=true,
    ['combat-robot']=true, ['construction-robot']=true, ['logistic-robot']=true, car=true, ['spider-vehicle']=true,
    ['deconstructible-tile-proxy']=true, ['transport-belt']=true, ['underground-belt']=true, splitter=true, ['linked-belt']=true,
    ['loader']=true, ['loader-1x1']=true, ['lane-splitter']=true}
  local BELTS = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local PIPES = {pipe=true, ['pipe-to-ground']=true}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store() local s = api.state(); s.linecut = s.linecut or {seq=0, cuts={}}; s.linecut.blocked = s.linecut.blocked or {}; return s.linecut end
  local function key(e) return e.unit_number or (e.position.x .. ',' .. e.position.y) end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  -- The entity on the tile holding q that a belt there would have to go round (ours first), or nil.
  function M.blocker(surface, q)
    local x, y = math.floor(q.x), math.floor(q.y)
    local found, best = try(function() return surface.find_entities_filtered{area={{x + 0.05, y + 0.05}, {x + 0.95, y + 0.95}}, limit=8} end) or {}, nil
    for _, e in ipairs(found) do
      if e.valid and not PASS[e.type] then
        local mine = e.force and e.force.name ~= 'neutral' and e.force.name ~= 'enemy'
        if not best or mine and not best.mine then best = {e=e, mine=mine} end
      end
    end
    return best and best.e
  end
  -- 'medium-electric-pole (353.5,95.5) stands there (placed by sonnet)'
  function M.blocker_text(e, where)
    local by = try(function() return e.last_user and e.last_user.name end)
    return string.format('%s %s stands %s%s', e.name, at(e.position), where or 'there', by and ' (placed by ' .. by .. ')' or '')
  end

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

  local BELT_TYPES = {'transport-belt', 'underground-belt', 'splitter', 'linked-belt', 'loader', 'loader-1x1', 'lane-splitter'}
  local function tkey(x, y) return x .. ',' .. y end
  -- Our belts by tile within r of q: {['x,y']=belt}, and the list.
  local function belts_near(surface, force, q, r)
    local map, list = {}, try(function() return surface.find_entities_filtered{area={{q.x - r, q.y - r}, {q.x + r, q.y + r}}, type=BELT_TYPES, force=force} end) or {}
    for _, b in ipairs(list) do
      local bb = b.bounding_box
      for x = math.floor(bb.left_top.x + 0.05), math.ceil(bb.right_bottom.x - 0.05) - 1 do
        for y = math.floor(bb.left_top.y + 0.05), math.ceil(bb.right_bottom.y - 0.05) - 1 do map[tkey(x, y)] = b end
      end
    end
    return map, list
  end
  local function belt_at(surface, force, q)
    local list = try(function() return surface.find_entities_filtered{area={{math.floor(q.x) + 0.05, math.floor(q.y) + 0.05}, {math.floor(q.x) + 0.95, math.floor(q.y) + 0.95}}, type=BELT_TYPES, force=force, limit=1} end)
    return list and list[1]
  end
  -- b faces a tile with no belt but an entity, and a belt within SPAN tiles past it faces the same way: kept.
  local function check(surface, force, b, map, st)
    if not (b.valid and (b.type == 'transport-belt' or b.type == 'underground-belt' and b.belt_to_ground_type == 'output')) then return end
    local d = VEC[b.direction]
    if not d then return end
    local x, y = math.floor(b.position.x), math.floor(b.position.y)
    local t1 = {x=x + d[1], y=y + d[2]}
    if map[tkey(t1.x, t1.y)] then return end
    for k = 2, SPAN + 1 do
      local nb = map[tkey(x + d[1] * k, y + d[2] * k)]
      if nb then
        if nb.direction ~= b.direction then return end
        local blk = M.blocker(surface, {x=t1.x + 0.5, y=t1.y + 0.5})
        -- (an inserter there moves the items on: not a block)
        if not blk or blk.type == 'inserter' then return end
        local here = {x=t1.x + 0.5, y=t1.y + 0.5}
        for _, r in ipairs(st.blocked) do if r.surface == surface.name and r.at.x == here.x and r.at.y == here.y then return end end
        if #st.blocked >= MAX_BLOCKED then return end
        st.seq = st.seq + 1
        st.blocked[#st.blocked+1] = {id=st.seq, surface=surface.name, force=force.name, dir=b.direction, at=here,
          up={x=b.position.x, y=b.position.y}, down={x=nb.position.x, y=nb.position.y}, first=game.tick}
        return
      end
    end
  end
  -- on_built_entity of ours: the belts round what was built, each checked (one find for them, one per belt facing a
  -- tile with no belt and a belt past it).
  function M.built(event)
    local e = event.entity or event.created_entity
    if not (e and e.valid) or e.type == 'entity-ghost' or e.type == 'tile-ghost' then return end
    local f = e.force
    if not f or f.name == 'neutral' or f.name == 'enemy' then return end
    local bb = e.bounding_box
    -- (a belt that faces it from the side, or one SPAN + 1 tiles back that its gap reaches)
    local r = SPAN + 1 + math.max(bb.right_bottom.x - bb.left_top.x, bb.right_bottom.y - bb.left_top.y) / 2
    if r > 6 then return end
    local st = store()
    st.blocked = st.blocked or {}
    local map, list = belts_near(e.surface, f, e.position, r)
    for i, b in ipairs(list) do if i <= 64 then check(e.surface, f, b, map, st) end end
  end
  local function belt_items(e, items)
    for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
      for _, c in ipairs(try(function() return e.get_transport_line(i).get_contents() end) or {}) do items[c.name] = (items[c.name] or 0) + c.count end
    end
    return items
  end
  local function items_text(items)
    local parts = {}
    for name, n in pairs(items) do parts[#parts+1] = {name, n} end
    table.sort(parts, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i, x in ipairs(parts) do if i <= 4 then out[i] = x[1] .. ' ' .. x[2] end end
    return #out > 0 and table.concat(out, ', ') or nil
  end
  local function ago(t) local m = math.floor(t / 3600); return m >= 1 and m .. 'm' or math.floor(t / 60) .. 's' end
  -- The blocked lines as alert groups for force: one gone (the entity, either belt) or bridged is dropped.
  local function blocked_groups(force, st, out)
    local keep = {}
    for _, b in ipairs(st.blocked or {}) do
      local surface = game.get_surface(b.surface)
      local f = game.forces[b.force]
      local up = surface and f and belt_at(surface, f, b.up)
      local down = up and belt_at(surface, f, b.down)
      local blk = down and not belt_at(surface, f, b.at) and up.direction == b.dir and down.direction == b.dir and M.blocker(surface, b.at)
      if blk then
        keep[#keep+1] = b
        if b.force == force.name and game.tick - b.first >= AGE then
          local back, on = belt_walk(up, 'inputs'), belt_walk(down, 'outputs')
          local held = items_text(belt_items(up, back.items))
          local by = try(function() return blk.last_user and blk.last_user.name end)
          out[#out+1] = {key='line_cut|b' .. b.id, kind='line_cut', surface=b.surface, n=1, names={[blk.name]=1}, by=by and {[by]=1} or {},
            at={{x=b.at.x, y=b.at.y}}, center={x=math.floor(b.at.x), y=math.floor(b.at.y)}, rank=b.first,
            line=string.format('belt line blocked at %s: %s; the belt runs %d tile%s from %s to %s and stops there%s; the line goes on from %s%s; seen %s ago',
              at(b.at), M.blocker_text(blk, "where the belt's next tile should be"), back.n + 1, back.n == 0 and '' or 's', at(back.last or b.up), at(b.up),
              held and ', holding ' .. held or ', empty', at(b.down), on.n > 0 and string.format(', %d tile%s to %s', on.n + 1, on.n == 0 and '' or 's', at(on.last)) or '',
              ago(game.tick - b.first))}
        end
      end
    end
    st.blocked = keep
  end

  -- The cuts as alert groups for force (pushalerts.lua); rebuilt or old ones dropped.
  function M.alert_groups(force)
    local st = store()
    local keep, out = {}, {}
    pcall(blocked_groups, force, st, out)
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
          local standing = {}
          for i, q in ipairs(open) do
            local blk = i <= 4 and surface and M.blocker(surface, q)
            if blk then standing[#standing+1] = M.blocker_text(blk, 'on ' .. at(q)) end
          end
          g.line = string.format('%s line cut at %s%s: %d tile%s gone%s, %ds ago, none rebuilt%s; the line runs %s on one side, %s on the other%s',
            c.kind, table.concat(spots, ', '), #open > 4 and string.format(' +%d more', #open - 4) or '', #open, #open == 1 and '' or 's',
            #causes > 0 and ' (' .. table.concat(causes, ', ') .. ')' or '', math.floor((game.tick - c.tick) / 60),
            #standing > 0 and ' (' .. table.concat(standing, '; ') .. ')' or '',
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
