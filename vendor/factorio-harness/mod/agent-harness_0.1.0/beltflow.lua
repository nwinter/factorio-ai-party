-- Where a belt moves items (Grok, shift11: a belt facing south read as
-- feeding the tile at lower y; south is +y). line(e) for a transport belt,
-- underground belt or splitter, built or a ghost:
--   moves items south to (-22.5,-28.5); fed from (-22.5,-30.5)
-- A built one reads the engine's connections (belt_neighbours, an
-- underground's partner, the belt's shape; all set in the tick it is built,
-- checked on 2.0.77, where both underground ends face the way items go). A
-- ghost reads the belts and belt ghosts on the tiles around it: one behind
-- feeds it straight, else a lone one at a side makes a curve. Pure: the
-- factory takes the harness's try.
return function(api)
  local M = {}
  local try = api.try or function(fn) local ok, v = pcall(fn); if ok then return v end end
  local NAMES = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local VEC = {[0]={x=0, y=-1}, [4]={x=1, y=0}, [8]={x=0, y=1}, [12]={x=-1, y=0}}
  M.TYPES = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  local SEARCH = {'transport-belt', 'underground-belt', 'splitter', 'entity-ghost'}

  local function pt(p) return string.format('(%g,%g)', p.x, p.y) end
  local function add(p, v, k) k = k or 1; return {x=p.x+v.x*k, y=p.y+v.y*k} end
  local function same(a, b) return math.abs(a.x-b.x) < 0.01 and math.abs(a.y-b.y) < 0.01 end
  local function kind(e) return e.type == 'entity-ghost' and e.ghost_type or e.type end
  local function list(points)
    local out = {}
    for i, p in ipairs(points) do out[i] = pt(p) end
    return table.concat(out, ' and ')
  end

  -- The belt tiles of e facing d: a splitter's two lanes (west or north one first), else its own.
  local function tiles(e, d)
    if kind(e) ~= 'splitter' then return {e.position} end
    local s = VEC[(d+4) % 16]
    local a, b = add(e.position, s, -0.5), add(e.position, s, 0.5)
    if a.x > b.x or a.y > b.y then a, b = b, a end
    return {a, b}
  end

  local function covers(n, p)
    for _, t in ipairs(tiles(n, try(function() return n.direction end) or 0)) do if same(t, p) then return true end end
    return false
  end

  -- Where input n feeds ours: {from=its tile, into=ours} for each of its tiles one step on from which is ours (a
  -- splitter behind a splitter feeds both lanes), else its tile next to one of ours.
  local function feeds(n, ours)
    local nd = try(function() return n.direction end) or 0
    local out = {}
    for _, t in ipairs(tiles(n, nd)) do
      for _, o in ipairs(ours) do
        if VEC[nd] and same(add(t, VEC[nd]), o) then out[#out+1] = {from=t, into=o} end
      end
    end
    for _, t in ipairs(#out == 0 and tiles(n, nd) or {}) do
      for _, o in ipairs(ours) do
        if #out == 0 and math.abs(t.x-o.x) + math.abs(t.y-o.y) < 1.01 then out[1] = {from=t, into=o} end
      end
    end
    return out
  end

  -- "moves items D to ..." for a built belt: where its outputs go and whether a belt takes them there.
  local function moves(e, d, ours, under, outputs)
    local head = 'moves items ' .. NAMES[d]
    if under == 'input' then
      local partner = try(function() return e.neighbours end)
      if partner and partner.valid then return head .. ' underground to ' .. pt(partner.position) end
      return head .. ' underground (no exit end paired)'
    end
    local to, missing = {}, {}
    for i, o in ipairs(ours) do
      to[i] = add(o, VEC[d])
      local taken = false
      for _, n in ipairs(outputs) do if covers(n, to[i]) then taken = true end end
      if not taken then missing[#missing+1] = to[i] end
    end
    local text = head .. ' to ' .. list(to)
    if #missing == #to then return text .. ' (no belt takes them there: they stop at its end)' end
    if #missing > 0 then return text .. ' (no belt takes them at ' .. list(missing) .. ')' end
    local n = outputs[1]
    if #to == 1 and n and n.valid and n.direction ~= d then
      local k = kind(n)
      if k == 'underground-belt' or k == 'transport-belt' and try(function() return n.belt_shape end) == 'straight' then
        return text .. string.format(' (onto the side of %s facing %s)', n.name, NAMES[n.direction] or n.direction)
      end
    end
    return text
  end

  -- "fed from ..." parts: main is the input behind (or a curve's side), sides are side-loads.
  local function fed(main, sides, extra)
    local parts = {}
    if extra then parts[#parts+1] = extra end
    if #main > 0 then parts[#parts+1] = 'fed from ' .. list(main) end
    if #sides > 0 then parts[#parts+1] = 'side-loaded from ' .. list(sides) end
    if #parts == 0 then parts[1] = 'no belt feeds it' end
    return table.concat(parts, '; ')
  end

  -- Inputs {from, into} split behind or side; a curve (shape not straight, or a ghost belt with a lone side
  -- input and none behind) takes its side input as its main one.
  local function split(inputs, d, curve)
    local main, sides = {}, {}
    for _, i in ipairs(inputs) do
      if same(i.from, add(i.into, VEC[d], -1)) then main[#main+1] = i.from else sides[#sides+1] = i.from end
    end
    if curve and #main == 0 and #sides == 1 then main, sides = sides, {} end
    return main, sides
  end

  local function built(e, d, k, ours)
    local nb = try(function() return e.belt_neighbours end) or {}
    local under = k == 'underground-belt' and try(function() return e.belt_to_ground_type end) or nil
    local inputs = {}
    for _, n in pairs(nb.inputs or {}) do
      if n.valid then for _, i in ipairs(feeds(n, ours)) do inputs[#inputs+1] = i end end
    end
    local outputs = {}
    for _, n in pairs(nb.outputs or {}) do if n.valid then outputs[#outputs+1] = n end end
    local text = moves(e, d, ours, under, outputs)
    if under == 'output' then
      local partner = try(function() return e.neighbours end)
      local from = partner and partner.valid and 'fed underground from ' .. pt(partner.position) or 'no entrance end paired'
      local sides = {}
      for _, i in ipairs(inputs) do sides[#sides+1] = i.from end
      return text .. '; ' .. fed({}, sides, from)
    end
    local curve = k == 'transport-belt' and (try(function() return e.belt_shape end) or 'straight') ~= 'straight'
    return text .. '; ' .. fed(split(inputs, d, curve))
  end

  -- What a belt or belt ghost c outputs onto: its tiles one step on (an underground only from its exit).
  local function outputs_of(c)
    local cd = try(function() return c.direction end) or 0
    if not VEC[cd] then return {} end
    if kind(c) == 'underground-belt' and try(function() return c.belt_to_ground_type end) ~= 'output' then return {} end
    local out = {}
    for _, t in ipairs(tiles(c, cd)) do out[#out+1] = {from=t, to=add(t, VEC[cd])} end
    return out
  end

  local function ghost(e, d, k, ours)
    local under = k == 'underground-belt' and try(function() return e.belt_to_ground_type end) or nil
    local head = 'moves items ' .. NAMES[d]
    local text
    if under == 'input' then text = head .. ' underground'
    else
      local to = {}
      for i, o in ipairs(ours) do to[i] = add(o, VEC[d]) end
      text = head .. ' to ' .. list(to)
    end
    if under == 'output' then return text .. '; fed underground' end
    local lo, hi = ours[1], ours[#ours]
    local found = try(function()
      return e.surface.find_entities_filtered{area={{lo.x-1.5, lo.y-1.5}, {hi.x+1.5, hi.y+1.5}}, type=SEARCH, force=e.force}
    end) or {}
    local inputs = {}
    for _, c in ipairs(found) do
      if c.valid and c ~= e and M.TYPES[kind(c)] then
        for _, o in ipairs(outputs_of(c)) do
          for _, mine in ipairs(ours) do
            -- (one in front facing back meets it head-on: no input)
            if same(o.to, mine) and not same(o.from, add(mine, VEC[d])) then inputs[#inputs+1] = {from=o.from, into=mine} end
          end
        end
      end
    end
    return text .. '; ' .. fed(split(inputs, d, k == 'transport-belt'))
  end

  -- The line for e, or nil when it is no belt, underground or splitter (or faces a way belts do not).
  function M.line(e)
    if not (e and e.valid) then return nil end
    local k = kind(e)
    if not M.TYPES[k] then return nil end
    local d = try(function() return e.direction end)
    if not VEC[d] then return nil end
    local ours = tiles(e, d)
    if e.type == 'entity-ghost' then return ghost(e, d, k, ours) end
    return built(e, d, k, ours)
  end

  -- "NAME (x,y): line" for the last belt of a list of entities (a build batch, placed ghosts), or nil.
  function M.last(ents)
    for i = #ents, 1, -1 do
      local e = ents[i]
      local line = e and e.valid and M.line(e)
      if line then
        return string.format('%s (%g,%g): %s', e.type == 'entity-ghost' and e.ghost_name or e.name, e.position.x, e.position.y, line)
      end
    end
    return nil
  end
  return M
end
