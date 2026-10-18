-- Fluid ports of an entity that is not built yet (Gemini: an electromagnetic
-- plant's recipe moves which fluid each port carries): where each fluid
-- connection is, the tile outside it a pipe must take, the way it faces, its
-- flow, and the fluid the recipe puts there. `ports` takes a name, position,
-- direction and recipe; `inspect` of a ghost shows the same for its recipe.
-- 2.0 joins a crafting machine's fluid boxes by recipe (read on the shift
-- world, 2026-10-13, from 30 machines' engine connections): a chemical plant
-- on lubricant takes heavy oil at both input ports, on sulfur water and
-- petroleum gas at one each and no output; an oil refinery on simple coal
-- liquefaction puts heavy oil out of all three outputs; an electromagnetic
-- plant on supercapacitor takes electrolyte at both inputs. So: a recipe fluid
-- with a fluidbox_index takes that box of its side only; the others take the
-- side's free boxes in order; when a side has one fluid without an index, its
-- leftover boxes join that fluid; a side with no fluid has no connections.
-- More boxes than fluids without an index: the first fluid takes the extra
-- boxes, in order, then one box each (d17 batch30 A1, read on world n: the
-- cryogenic plant at (-85.5,-19.5) on Aquilo, north, on lithium, joins its left
-- and middle input boxes as one fluidbox of lithium-brine and gives the right one
-- to ammonia; its outputs, with no fluid product, are not there). Joined boxes are
-- one engine fluidbox: `box` numbers them as the built machine's inspect does.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local NAME = {[0]='north', [4]='east', [8]='south', [12]='west'}
  local function fluids_of(list)
    local out = {}
    for _, f in ipairs(list or {}) do
      if f.type == 'fluid' then out[#out+1] = f end
    end
    return out
  end
  -- Per prototype fluid box index: {fluid, joined?, box} or {off}, box the
  -- engine's fluidbox number ({box} alone for a box that is not a crafting
  -- machine's input or output); nil without a recipe.
  function M.assign(proto, recipe)
    if not recipe then return nil end
    local sides = {input={}, output={}}
    for i, b in ipairs(api.boxes(proto)) do
      local t = b.production_type
      if sides[t] then table.insert(sides[t], i) end
    end
    local out = {}
    local function side(kind, fluids)
      local slots, free, loose = sides[kind], {}, {}
      for k in ipairs(slots) do free[k] = true end
      for _, f in ipairs(fluids) do
        local k = f.fluidbox_index
        if type(k) == 'number' and k > 0 and slots[k] and free[k] then
          out[slots[k]] = {fluid=f.name}; free[k] = nil
        else loose[#loose+1] = f end
      end
      local open = {}
      for k in ipairs(slots) do if free[k] then open[#open+1] = k end end
      if #loose == 0 then
        for _, k in ipairs(open) do out[slots[k]] = {off=true} end
      else
        -- the first loose fluid takes the boxes left over, then one each
        local extra, j = math.max(0, #open - #loose), 1
        for n, f in ipairs(loose) do
          for m = 1, n == 1 and extra + 1 or 1 do
            local k = open[j]
            if k then out[slots[k]] = {fluid=f.name, joined=m > 1 or nil}; j = j + 1 end
          end
        end
      end
    end
    side('input', fluids_of(recipe.ingredients))
    side('output', fluids_of(recipe.products))
    -- the engine's fluidbox numbers: prototype order, a closed box left out, a side's boxes of one fluid as one
    local key_of, n = {}, 0
    for i, b in ipairs(api.boxes(proto)) do
      local a = out[i]
      if not (a and a.off) then
        local key = a and a.fluid and (b.production_type .. '|' .. a.fluid) or ('#' .. i)
        if not key_of[key] then n = n + 1; key_of[key] = n end
        out[i] = out[i] or {}
        out[i].box = key_of[key]
      end
    end
    return out
  end
  -- The recipe as the machine takes it: a name (or prototype) it can make.
  function M.recipe(proto, name)
    if name == nil or name == false then return nil end
    local r = type(name) == 'string' and prototypes.recipe[name] or name
    assert(type(r) ~= 'string' and r ~= nil, 'unknown recipe '..tostring(name))
    local cats = proto.crafting_categories
    assert(cats, proto.name..' takes no recipe')
    if not cats[r.category] then
      local list = {}
      for c in pairs(cats) do list[#list+1] = c end
      table.sort(list)
      error(string.format('%s cannot make %s (category %s; it makes %s)', proto.name, r.name, r.category, table.concat(list, ', ')), 0)
    end
    return r
  end
  local function centre(x, y) return {x=x+0.5, y=y+0.5} end
  -- One row per connection, in inspect's fluid_connections form: at (the
  -- entity's tile with the port), joins (the tile outside it, where a pipe or
  -- another port joins), direction, flow, fluid, box. A port the recipe
  -- closes is left out and listed in closed.
  -- e: {prototype, position, direction, mirroring} (a ghost or a plan).
  function M.rows(e, recipe)
    local proto = e.prototype
    local given = api.boxes(proto)
    local assigned = M.assign(proto, recipe)
    local rows, closed = {}, {}
    for _, c in ipairs(api.defined(e)) do
      local b = given[c.box] or {}
      local a = assigned and assigned[c.box]
      local flow = b.production_type == 'input' and 'input' or b.production_type == 'output' and 'output'
        or (c.flow == 'input-output' and 'input-output' or c.flow)
      if a and a.off then
        closed[#closed+1] = string.format('%s %g,%g', flow or '?', c.tx+0.5, c.ty+0.5)
      else
        local fluid = c.fluid
        if a and a.fluid then fluid = a.fluid end
        rows[#rows+1] = {at=centre(c.x, c.y), joins=centre(c.tx, c.ty), direction=NAME[c.dir], flow=flow,
          fluid=fluid or (assigned and 'none' or nil), box=a and a.box or c.box, kind=c.kind ~= 'normal' and c.kind or nil,
          underground_reach=c.kind == 'underground' and c.reach or nil}
      end
    end
    return rows, closed
  end
  return M
end
