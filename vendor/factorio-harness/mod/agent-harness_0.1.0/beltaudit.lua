-- trace {position, forward, audit} (C3, Opus 18:20: 3 of 4 trunks ran at half capacity): along the belts the walk
-- followed, where lanes lose capacity, from what the tiles show:
--   a side-load whose belt carries both lanes: both go onto the one lane of the belt it joins (at most half gets on);
--   a curve made a side-load: an empty stub behind the turn tile keeps it straight, so the belt coming in from the
--   side loads both its lanes onto one lane where a curve would have kept them;
--   a route that ends at missing tiles: within 4 tiles ahead the run goes on (a belt, an underground, a splitter or a
--   ghost of one), with what that run carries now; or it ends against a belt facing another way.
return function(h)
  local M = {}
  local try, place, at, side = h.try, h.place, h.at, h.side
  local STEP = {[0]={0,-1}, [4]={1,0}, [8]={0,1}, [12]={-1,0}}
  local DIR = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local GAP, STUB = 4, 3
  local TYPES = {'transport-belt', 'underground-belt', 'splitter'}
  local function empty(l) return next(l.left) == nil and next(l.right) == nil end
  -- An empty straight input with at most STUB tiles (all empty) in its run: a stray tile, not a trunk.
  local function stub(s)
    local e, n = s, 0
    while e and e.valid do
      if not empty(h.lanes_of(e)) then return false end
      n = n + 1
      if n > STUB then return false end
      local bn = try(function() return e.belt_neighbours end)
      local ins = bn and bn.inputs or {}
      if #ins == 0 then return true end
      if #ins > 1 then return false end
      e = ins[1]
    end
    return true
  end
  -- Side-loads onto straight belt e (each input belt once: done).
  function M.sideloads(e, out, done)
    if e.type ~= 'transport-belt' or try(function() return e.belt_shape end) ~= 'straight' then return end
    local bn = try(function() return e.belt_neighbours end)
    local ins = bn and bn.inputs or {}
    local straight
    for _, b in ipairs(ins) do if b.direction == e.direction then straight = b end end
    for _, b in ipairs(ins) do
      if b.valid and b.direction ~= e.direction and not done[b.unit_number] then
        done[b.unit_number] = true
        local k = h.lane_near(e, b.position) or 1
        local l = h.lanes_of(b)
        local full = h.lane_full(e, k) and ' (that lane is full: ' .. h.lane_text(h.lanes_of(e)[k == 1 and 'left' or 'right'] or {}) .. ')' or ''
        if straight and stub(straight) then
          out[#out+1] = string.format('a curve made a side-load at %s: %s turns into it, but the empty %s behind it keeps it straight, so both lanes of %s (left %s, right %s) go onto its %s lane only%s',
            place(e), place(b), place(straight), place(b), h.lane_text(l.left), h.lane_text(l.right), side(k), full)
        elseif next(l.left) and next(l.right) then
          out[#out+1] = string.format('%s side-loads both its lanes (left %s, right %s) onto %s %s lane only: at most half of what it carries gets on%s',
            place(b), h.lane_text(l.left), h.lane_text(l.right), place(e), side(k), full)
        end
      end
    end
  end
  local function find(surface, force, pos)
    local area = {{pos.x - 0.3, pos.y - 0.3}, {pos.x + 0.3, pos.y + 0.3}}
    local e = try(function() return surface.find_entities_filtered{area=area, type=TYPES, force=force, limit=1}[1] end)
    if e then return e end
    local g = try(function() return surface.find_entities_filtered{area=area, ghost_type=TYPES, force=force, limit=1}[1] end)
    return g, g ~= nil
  end
  -- A route ending at belt e: the run going on within GAP tiles ahead (missing tiles), or a belt against it facing away.
  function M.gap(e, seen, out)
    if e.type == 'splitter' or e.type == 'underground-belt' and try(function() return e.belt_to_ground_type end) == 'input' then return end
    local d = try(function() return e.direction end) or 0
    local st = STEP[d]
    if not st then return end
    for n = 1, GAP do
      local pos = {x=e.position.x + st[1] * n, y=e.position.y + st[2] * n}
      if seen and not seen(pos) then return end
      local f, ghost = find(e.surface, e.force, pos)
      if f then
        if ghost then
          local gpos = f.position
          out[#out+1] = n == 1 and string.format('%s ends at a %s ghost %s: nothing passes until it is built', place(e), f.ghost_name, at(gpos))
            or string.format('%s ends %d tile%s short: %s ghost %s waits ahead, %s missing', place(e), n - 1, n == 2 and '' or 's', f.ghost_name, at(gpos),
              n == 2 and 'one tile' or (n - 1) .. ' tiles')
        elseif n == 1 then
          if f.direction ~= d then
            out[#out+1] = string.format('%s ends against %s, which faces %s: nothing passes', place(e), place(f), DIR[f.direction] or tostring(f.direction))
          end
        else
          local l = h.lanes_of(f)
          local holes = {}
          for j = 1, n - 1 do holes[j] = at({x=e.position.x + st[1] * j, y=e.position.y + st[2] * j}) end
          out[#out+1] = string.format('missing tile%s at %s: %s ends there and %s goes on after it carrying left %s, right %s%s', n == 2 and '' or 's',
            table.concat(holes, ', '), place(e), place(f), h.lane_text(l.left), h.lane_text(l.right), empty(l) and ' (nothing reaches it from here)' or '')
        end
        return
      end
    end
  end
  -- The audit of a trace's walked routes: {tiles, end_at, stop, dark}.
  function M.audit(routes, seen, cap)
    local out, done, tiles = {}, {}, {}
    for _, r in ipairs(routes) do
      for _, e in ipairs(r.tiles or {}) do
        if #out >= cap then break end
        if e.valid and not tiles[e.unit_number] then tiles[e.unit_number] = true; M.sideloads(e, out, done) end
      end
      local e = r.end_at
      if #out < cap and not r.dark and e and e.valid and type(r.stop) == 'string' and r.stop:find('^belt ends at') then M.gap(e, seen, out) end
    end
    local n = 0
    for _ in pairs(tiles) do n = n + 1 end
    if #out == 0 then
      out[1] = string.format('%d belt tile%s walked: no side-load of two carried lanes onto one, no curve made a side-load, no route ending %d tiles or less short of a belt ahead', n, n == 1 and '' or 's', GAP)
    end
    return out
  end
  return M
end
