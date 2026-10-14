-- A flamethrower turret's oil (Astra, shift11 16:36: status and the flamers
-- read said all 12 flamers were dry while inspect showed crude-oil 87.2, and
-- that flamer burnt a reactor; Haiku nearly walked past it). A 2.0 fluid
-- turret fires from a buffer of its own (the prototype's fluid_buffer_size,
-- 100 for the flamethrower turret), filled from its fluidbox, which is part of
-- the pipe line and reads empty once the line has drained: on world n four
-- flamers each read fluidbox[1] nil and get_fluid_contents crude-oil 86 to
-- 100 (2026-10-14). So the oil is the whole entity's fluid, as inspect reads
-- it (get_fluid_contents), of the fluids the turret fires (its
-- attack_parameters.fluids: crude oil, heavy oil, light oil), and the
-- capacity its fluidboxes' volumes plus that buffer. Pure, so a hot reload
-- can bundle it.
local M = {}
local function try(fn) local ok, v = pcall(fn); if ok then return v end end
local fired, sizes = {}, {}

-- {fluid name = true} the prototype fires, or nil when it names none (any fluid counts).
local function fluids_of(proto)
  local name = proto.name or proto
  if fired[name] == nil then
    local set = false
    local list = try(function() return proto.attack_parameters.fluids end)
    for _, f in pairs(list or {}) do
      local n = type(f) == 'table' and (f.type or f.name) or f
      if type(n) == 'string' then set = set or {}; set[n] = true end
    end
    fired[name] = set
  end
  return fired[name] or nil
end

local function capacity_of(proto)
  local name = proto.name or proto
  if sizes[name] == nil then
    local total = 0
    for _, fp in pairs(try(function() return proto.fluidbox_prototypes end) or {}) do
      total = total + (try(function() return fp.volume end) or 0)
    end
    total = total + (try(function() return proto.fluid_buffer_size end) or 0)
    sizes[name] = total
  end
  return sizes[name] > 0 and sizes[name] or nil
end

-- amount, capacity (nil if unknown), the fluid it holds most of (nil when
-- empty), {fluid = amount} of the fluids it fires.
function M.read(e)
  local proto = try(function() return e.prototype end)
  local want = proto and fluids_of(proto)
  -- Per fluid, the larger of the entity's contents and its fluidboxes' (a box with oil never reads dry, whichever
  -- of the two the contents count).
  local held = {}
  for name, v in pairs(try(function() return e.get_fluid_contents() end) or {}) do
    if type(v) == 'number' then held[name] = v end
  end
  local boxes = {}
  local fb = try(function() return e.fluidbox end)
  for i = 1, (fb and #fb or 0) do
    local f = try(function() return fb[i] end)
    if f then local n = f.name or '?'; boxes[n] = (boxes[n] or 0) + (f.amount or 0) end
  end
  for name, v in pairs(boxes) do held[name] = math.max(held[name] or 0, v) end
  local amount, top, most, fluids = 0, nil, 0, {}
  for name, v in pairs(held) do
    if type(v) == 'number' and v > 0 and (not want or want[name]) then
      fluids[name] = v
      amount = amount + v
      if v > most then top, most = name, v end
    end
  end
  return amount, proto and capacity_of(proto), top, fluids
end

local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end

-- 'N of M with oil (crude-oil 87 at (64.5,-121), ...)': rows {amount, fluid,
-- position}, up to `show` named (those with the least oil first, as they go
-- dry first), or 'none of M with oil'.
function M.summary(rows, show)
  local with = {}
  for _, r in ipairs(rows) do if (r.amount or 0) >= 1 then with[#with + 1] = r end end
  if #with == 0 then return string.format('none of %d with oil', #rows) end
  table.sort(with, function(a, b) return a.amount < b.amount end)
  local named = {}
  for i = 1, math.min(show or 3, #with) do
    local r = with[i]
    named[i] = string.format('%s %d at %s', r.fluid or 'oil', math.floor(r.amount + 0.5), at(r.position))
  end
  return string.format('%d of %d with oil (%s%s)', #with, #rows, table.concat(named, ', '), #with > #named and ', ...' or '')
end

return M
