-- The ores read (Opus, 00:20: "every ore patch on the charted map with amount
-- left, distance and nests within 50 tiles, so finding new iron is one call
-- instead of a script over map"): each resource patch on the charted chunks of
-- a surface with its centre, box, tiles, amount left (oil and the other
-- infinite resources: their yield), distance from the caller and from our
-- nearest building, the enemy spawners and worms within 50 tiles, and our
-- mining drills on it.
--
-- A patch: the tiles of one resource grouped in 4x4 cells (fluid wells in
-- 16x16 cells); cells that touch, across chunk borders too, are one patch, so
-- ore a few tiles apart joins (wells up to about 30 tiles apart). On world n's
-- tiles (shift09) this gives the patches the map shows: nauvis iron 1950, 201
-- and 176 tiles plus mined-out specks, its oil as two fields.
--
-- Cost: reading a whole planet at once took 75-115 ms on a private 2.0.77
-- server with world n's map (seeds and charted chunks: 8.7k and 12.4k
-- resource tiles, an 11k-entity base), so what each charted chunk holds (ore
-- cells, one of our buildings per 8x8 cell, our drills, enemy spawners and
-- worms) is kept per chunk in storage with the tick it was read. A pass walks
-- the charted chunks outward from the caller's chunk and reads them, the
-- first call within CALL_BUDGET, the harness tick the rest within TICK_BUDGET
-- a tick; a call REFRESH_TICKS after a pass began starts the next (newly
-- charted chunks join it); between passes a call only measures. Nothing runs
-- before the first call or after a pass ends. The budgets count engine calls
-- and entity reads, never time, so every peer does the same work.
return function(api)
  local M = {handlers={}, schema={}}
  local CELL, FLUID_CELL, BCELL, NEST_RANGE = 4, 16, 8, 50
  local REFRESH_TICKS = 18000
  M.CELL, M.FLUID_CELL, M.NEST_RANGE, M.REFRESH_TICKS = CELL, FLUID_CELL, NEST_RANGE, REFRESH_TICKS
  -- Work units: an engine call or an entity read is 1.
  M.CALL_BUDGET, M.TICK_BUDGET = 400, 400
  -- The rows read live (refresh below): the chunks under them read again within LIVE_BUDGET units a call, unless
  -- read in the last LIVE_FRESH ticks; at most MAX_UNDER drills with no_minable_resources checked for ore under them.
  M.LIVE_BUDGET, M.LIVE_FRESH, M.MAX_UNDER = 6000, 300, 64
  -- Not buildings: what "our nearest building" skips (threat.lua's list, and
  -- the transient entities a force's find returns).
  local NOT_BUILDING = {character=true, car=true, ['spider-vehicle']=true, locomotive=true, ['cargo-wagon']=true,
    ['fluid-wagon']=true, ['artillery-wagon']=true, ['entity-ghost']=true, ['tile-ghost']=true, ['construction-robot']=true,
    ['logistic-robot']=true, ['combat-robot']=true, ['capture-robot']=true, ['character-corpse']=true, ['item-request-proxy']=true,
    ['spider-leg']=true, ['spider-unit']=true, unit=true, projectile=true, ['artillery-projectile']=true, stream=true, fire=true,
    sticker=true, beam=true, ['smoke-with-trigger']=true, ['highlight-box']=true, ['speech-bubble']=true,
    ['entity-ghost-proxy']=true, ['cargo-pod']=true, ['rocket-silo-rocket']=true, ['rocket-silo-rocket-shadow']=true,
    explosion=true, corpse=true, ['rail-remnants']=true, ['particle-source']=true, ['deconstructible-tile-proxy']=true,
    ['item-entity']=true, asteroid=true, ['segmented-unit']=true, ['unit-spawner']=true, turret=true}
  M.NOT_BUILDING = NOT_BUILDING
  local names = {'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'}
  local function compass(from, to)
    local angle = (math.atan2 or math.atan)(to.x-from.x, -(to.y-from.y))
    return names[math.floor(angle/(math.pi/4)+0.5)%8+1]
  end
  local function round(v) return math.floor(v+0.5) end
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Integer keys for cells and chunks (no strings in the hot loops); a
  -- neighbour's key is the key plus one of NEAR.
  local function ckey(cx, cy) return (cx+524288)*1048576+(cy+524288) end
  local NEAR = {-1048577, -1048576, -1048575, -1, 1, 1048575, 1048576, 1048577}
  -- Distance from a point to a box {l, t, r, b} (tile edges): 0 inside.
  local function to_box(x, y, l, t, r, b)
    local dx = x < l and l-x or (x > r and x-r or 0)
    local dy = y < t and t-y or (y > b and y-b or 0)
    return (dx*dx+dy*dy)^0.5
  end
  -- Resource kinds: a fluid resource's wells, an infinite one's yield (oil,
  -- geysers, vents: amount over the prototype's normal amount, as the game
  -- shows it), else tiles and the amount left (lithium brine is a fluid that
  -- runs out).
  local kinds = {}
  local function kind_of(name)
    local k = kinds[name]
    if not k then
      local proto = prototypes.entity[name]
      local products = try(function() return proto.mineable_properties.products end) or {}
      local fluid = products[1] ~= nil and products[1].type == 'fluid'
      k = {fluid=fluid, infinite=try(function() return proto.infinite_resource end) == true,
        normal=try(function() return proto.normal_resource_amount end) or 0, cell=fluid and FLUID_CELL or CELL}
      kinds[name] = k
    end
    return k
  end
  local radius = {}

  -- The ore of a chunk's rows y0+from .. y0+to-1 into a record's cells (rec.by
  -- keeps them by name and key while the chunk is read): the work it took.
  -- Only ore whose tile lies in those rows of the chunk counts (a well over a
  -- border is read once).
  local function read_ore(surface, rec, x0, y0, from, to)
    local units = 1
    local by, cells = rec.by, rec.cells
    for _, e in pairs(surface.find_entities_filtered{area={{x0, y0+from}, {x0+32, y0+to}}, type='resource'}) do
      units = units+1
      local pos = e.position
      local x, y = math.floor(pos.x), math.floor(pos.y)
      if x >= x0 and x < x0+32 and y >= y0+from and y < y0+to then
        local name = e.name
        local of = by[name]
        if not of then of = {size=kind_of(name).cell}; by[name] = of end
        local c = of.size
        local ccx, ccy = math.floor(x/c), math.floor(y/c)
        local key = ckey(ccx, ccy)
        local cell = of[key]
        if not cell then
          cell = {name=name, cx=ccx, cy=ccy, n=0, amount=0, sx=0, sy=0, l=x, t=y, r=x+1, b=y+1}
          of[key] = cell; cells[#cells+1] = cell
        end
        cell.n = cell.n+1; cell.amount = cell.amount+e.amount; cell.sx = cell.sx+x+0.5; cell.sy = cell.sy+y+0.5
        if x < cell.l then cell.l = x elseif x+1 > cell.r then cell.r = x+1 end
        if y < cell.t then cell.t = y elseif y+1 > cell.b then cell.b = y+1 end
      end
    end
    return units
  end
  -- A record when its ore is all read.
  local function finish(rec)
    rec.by = nil
    if not rec.cells[1] then rec.cells = nil end
    return rec
  end
  -- What one chunk holds, as a record {t, cells, buildings, drills, enemies}
  -- and the work it took; with `rows`, only the buildings, drills, enemies
  -- and the ore of rows 0..rows-1 (the rest by read_band). Only entities
  -- whose centre lies in the chunk count (one over a border is read once, by
  -- its own chunk).
  function M.read_chunk(surface, force, cx, cy, rows)
    local x0, y0 = cx*32, cy*32
    local area = {{x0, y0}, {x0+32, y0+32}}
    local rec = {t=game.tick, by={}, cells={}}
    local units = read_ore(surface, rec, x0, y0, 0, rows or 32)
    if not rows then finish(rec) end
    -- Our buildings, one per 8x8 cell (enough for a distance), and our
    -- drills with what they mine. One find by force: a type list in the
    -- filter costs the engine more than reading the types here.
    units = units+1
    local bcells
    for _, e in pairs(surface.find_entities_filtered{area=area, force=force}) do
      units = units+1
      local t = e.type
      if not NOT_BUILDING[t] then
        local pos = e.position
        if pos.x >= x0 and pos.x < x0+32 and pos.y >= y0 and pos.y < y0+32 then
          local key = ckey(math.floor(pos.x/BCELL), math.floor(pos.y/BCELL))
          bcells = bcells or {}
          if not bcells[key] then
            bcells[key] = true
            rec.buildings = rec.buildings or {}
            rec.buildings[#rec.buildings+1] = {x=pos.x, y=pos.y, name=e.name}
          end
          if t == 'mining-drill' then
            local name = e.name
            local r = radius[name]
            if not r then r = try(function() return e.prototype.mining_drill_radius end) or 1; radius[name] = r end
            local target = try(function() return e.mining_target end)
            local tp = target and target.valid and target.position
            rec.drills = rec.drills or {}
            rec.drills[#rec.drills+1] = {x=pos.x, y=pos.y, r=r, target=tp and target.name or nil,
              tx=tp and math.floor(tp.x) or nil, ty=tp and math.floor(tp.y) or nil}
          end
        end
      end
    end
    -- Enemy spawners and worms: the structures the map keeps drawn.
    units = units+1
    for _, e in pairs(surface.find_entities_filtered{area=area, force='enemy', type={'unit-spawner', 'turret'}}) do
      units = units+1
      local pos = e.position
      if pos.x >= x0 and pos.x < x0+32 and pos.y >= y0 and pos.y < y0+32 then
        rec.enemies = rec.enemies or {}
        rec.enemies[#rec.enemies+1] = {x=pos.x, y=pos.y, name=e.name, spawner=e.type == 'unit-spawner' or nil}
      end
    end
    return rec, units
  end
  -- More rows of a dense chunk's ore (from..to-1); the record is done after the last.
  function M.read_band(surface, rec, cx, cy, from, to)
    local units = read_ore(surface, rec, cx*32, cy*32, from, to)
    if to >= 32 then finish(rec) end
    return units
  end
  M.DENSE, M.BAND = 256, 8

  -- Patches from the chunk records: cells that touch are one patch.
  -- charted(cx, cy) says whether a chunk is charted (for chart_edge).
  function M.build(chunks, charted)
    local by, order = {}, {}
    local drills, enemies, buildings = {}, {}, {}
    for _, rec in pairs(chunks) do
      local list = rec.cells
      if list then
        for _, cell in ipairs(list) do
          local cells = by[cell.name]
          if not cells then cells = {}; by[cell.name] = cells; order[#order+1] = cell.name end
          cells[(cell.cx+524288)*1048576+cell.cy+524288] = cell; cells[#cells+1] = cell
        end
      end
      list = rec.drills
      if list then for _, d in ipairs(list) do drills[#drills+1] = d end end
      list = rec.enemies
      if list then for _, e in ipairs(list) do enemies[#enemies+1] = e end end
      list = rec.buildings
      if list then for _, b in ipairs(list) do buildings[#buildings+1] = b end end
    end
    table.sort(order)
    local patches = {}
    for _, name in ipairs(order) do
      local cells, k = by[name], kind_of(name)
      local seen = {}
      for _, start in ipairs(cells) do
        local sk = (start.cx+524288)*1048576+start.cy+524288
        if not seen[sk] then
          seen[sk] = true
          local p = {name=name, fluid=k.fluid or nil, tiles=0, amount=0, sx=0, sy=0, l=start.l, t=start.t, r=start.r, b=start.b, cells={}, boxes={}}
          local stack, top = {start}, 1
          local pc, bx = p.cells, p.boxes
          while top > 0 do
            local q = stack[top]; stack[top] = nil; top = top-1
            p.tiles = p.tiles+q.n; p.amount = p.amount+q.amount; p.sx = p.sx+q.sx; p.sy = p.sy+q.sy
            if q.l < p.l then p.l = q.l end
            if q.t < p.t then p.t = q.t end
            if q.r > p.r then p.r = q.r end
            if q.b > p.b then p.b = q.b end
            local qk = (q.cx+524288)*1048576+q.cy+524288
            pc[#pc+1] = qk
            local nb = #bx
            bx[nb+1] = q.l; bx[nb+2] = q.t; bx[nb+3] = q.r; bx[nb+4] = q.b
            -- Ore on a chunk's edge with an uncharted chunk beyond: the patch
            -- may go on past the charted map.
            if charted and not p.chart_edge then
              local chx, chy = math.floor(q.l/32), math.floor(q.t/32)
              if (q.l == chx*32 and not charted(chx-1, chy)) or (q.r == chx*32+32 and not charted(chx+1, chy))
                or (q.t == chy*32 and not charted(chx, chy-1)) or (q.b == chy*32+32 and not charted(chx, chy+1)) then
                p.chart_edge = true
              end
            end
            for i = 1, 8 do
              local nk = qk+NEAR[i]
              local n = cells[nk]
              if n and not seen[nk] then seen[nk] = true; top = top+1; stack[top] = n end
            end
          end
          p.centre = {x=round(p.sx/p.tiles-0.5)+0.5, y=round(p.sy/p.tiles-0.5)+0.5}
          p.sx, p.sy = nil, nil
          if k.infinite and k.normal > 0 then p.yield = round(p.amount/k.normal*100) end
          patches[#patches+1] = p
        end
      end
    end
    M.attach(patches, enemies, buildings, drills)
    return patches
  end
  -- Distance from a point to the nearest tile of a patch (its cells' tile
  -- bounds), or `best` when the patch's box is no nearer than that.
  local function to_patch(p, x, y, best)
    if best and to_box(x, y, p.l, p.t, p.r, p.b) >= best then return best end
    local bx = p.boxes
    for i = 1, #bx, 4 do
      local d = to_box(x, y, bx[i], bx[i+1], bx[i+2], bx[i+3])
      if not best or d < best then best = d; if d == 0 then return 0 end end
    end
    return best
  end
  M.to_patch = to_patch
  -- Points by 64-tile bucket, each bucket with the box around its points.
  local function buckets(list)
    local by, all = {}, {}
    for _, b in ipairs(list) do
      local k = ckey(math.floor(b.x/64), math.floor(b.y/64))
      local bk = by[k]
      if not bk then bk = {l=b.x, t=b.y, r=b.x, b=b.y, list={}}; by[k] = bk; all[#all+1] = bk end
      bk.list[#bk.list+1] = b
      if b.x < bk.l then bk.l = b.x elseif b.x > bk.r then bk.r = b.x end
      if b.y < bk.t then bk.t = b.y elseif b.y > bk.b then bk.b = b.y end
    end
    return all
  end
  local function gap(bk, p)
    local dx = bk.r < p.l and p.l-bk.r or (bk.l > p.r and bk.l-p.r or 0)
    local dy = bk.b < p.t and p.t-bk.b or (bk.t > p.b and bk.t-p.b or 0)
    return (dx*dx+dy*dy)^0.5
  end

  -- Per patch: our drills on it, enemy spawners and worms within NEST_RANGE,
  -- our nearest building. enemies: {{x, y, name, spawner}}; buildings:
  -- {{x, y, name}}; drills: {{x, y, r, target, tx, ty}}.
  function M.attach(patches, enemies, buildings, drills)
    local at = {}
    for _, p in ipairs(patches) do
      at[p.name] = at[p.name] or {}
      for _, key in ipairs(p.cells) do at[p.name][key] = p end
      p.miners = 0
    end
    for _, d in ipairs(drills) do
      local hit
      if d.target and at[d.target] then
        local c = kind_of(d.target).cell
        hit = at[d.target][ckey(math.floor(d.tx/c), math.floor(d.ty/c))]
      end
      if not hit then
        -- No target (unpowered, depleted): a patch with a cell under its
        -- mining area.
        for name, cells in pairs(at) do
          local c = kind_of(name).cell
          for cx = math.floor((d.x-d.r)/c), math.floor((d.x+d.r)/c) do
            for cy = math.floor((d.y-d.r)/c), math.floor((d.y+d.r)/c) do
              hit = hit or cells[ckey(cx, cy)]
            end
          end
          if hit then break end
        end
      end
      if hit then hit.miners = hit.miners+1 end
    end
    local nests, homes = buckets(enemies), buckets(buildings)
    local bound = {}
    for _, p in ipairs(patches) do
      for _, bk in ipairs(nests) do
        if gap(bk, p) <= NEST_RANGE then
          for _, e in ipairs(bk.list) do
            local d = to_patch(p, e.x, e.y, NEST_RANGE+1e-9)
            if d <= NEST_RANGE then
              if e.spawner then p.spawners = (p.spawners or 0)+1 else p.worms = (p.worms or 0)+1 end
              if not p.nest_d or d < p.nest_d then p.nest_d, p.nest = d, e end
            end
          end
        end
      end
      -- Our nearest building: the bucket with the least bound first, then
      -- the next while its bound is under the best so far; each building is
      -- checked against the patch's box before its cells (squared distances,
      -- no calls: this runs for every patch on every rebuild).
      local pl, pt, pr, pb, bx = p.l, p.t, p.r, p.b, p.boxes
      for i = 1, #homes do
        local bk = homes[i]
        local dx = bk.r < pl and pl-bk.r or (bk.l > pr and bk.l-pr or 0)
        local dy = bk.b < pt and pt-bk.b or (bk.t > pb and bk.t-pb or 0)
        bound[i] = dx*dx+dy*dy
      end
      local best, near = math.huge, nil
      while best > 0 do
        local mi, mv = nil, best
        for i = 1, #homes do local v = bound[i]; if v < mv then mi, mv = i, v end end
        if not mi then break end
        bound[mi] = math.huge
        local list = homes[mi].list
        for j = 1, #list do
          local b = list[j]
          local x, y = b.x, b.y
          local dx = x < pl and pl-x or (x > pr and x-pr or 0)
          local dy = y < pt and pt-y or (y > pb and y-pb or 0)
          if dx*dx+dy*dy < best then
            for i = 1, #bx, 4 do
              local ex = x < bx[i] and bx[i]-x or (x > bx[i+2] and x-bx[i+2] or 0)
              local ey = y < bx[i+1] and bx[i+1]-y or (y > bx[i+3] and y-bx[i+3] or 0)
              local d2 = ex*ex+ey*ey
              if d2 < best then best, near = d2, b; if d2 == 0 then break end end
            end
            if best == 0 then break end
          end
        end
      end
      p.building_d, p.building = near and best^0.5 or nil, near
    end
    for _, p in ipairs(patches) do p.cells = nil end
  end

  -- The survey of one surface for one force, in storage: chunks (the tick
  -- each chunk was read), data (the records of the chunks that hold
  -- anything), count (chunks read), the walk of the current pass (coordinate
  -- pairs from head; walked: chunks already on it), refreshed (when the pass
  -- began), full (a pass has ended), changed and built (patches).
  local function surveys()
    local st = api.state()
    st.ores = st.ores or {}
    return st.ores
  end
  -- One position table for the engine's chart checks (it reads it at once).
  local spot = {x=0, y=0}
  local function charted(force, surface, cx, cy) spot.x, spot.y = cx, cy; return api.charted(force, surface, spot) == true end
  local function charted_fn(force, surface, entry)
    return function(cx, cy) return entry.chunks[ckey(cx, cy)] ~= nil or charted(force, surface, cx, cy) end
  end
  local function store(entry, k, rec)
    if not entry.chunks[k] then entry.count = entry.count+1 end
    entry.chunks[k] = rec.t
    entry.data[k] = (rec.cells or rec.buildings or rec.drills or rec.enemies) and rec or nil
    entry.changed = (entry.changed or 0)+1
  end
  -- One chunk read into the survey: the work it took. A chunk with more than
  -- DENSE ore tiles is read BAND rows at a time (entry.dense), the rest of it
  -- in the next slices, so no slice reads a thousand tiles at once.
  local function read(entry, surface, force, cx, cy)
    local x0, y0 = cx*32, cy*32
    local n = surface.count_entities_filtered{area={{x0, y0}, {x0+32, y0+32}}, type='resource'}
    if n <= M.DENSE then
      local rec, units = M.read_chunk(surface, force, cx, cy)
      store(entry, ckey(cx, cy), rec)
      return units+1
    end
    local rec, units = M.read_chunk(surface, force, cx, cy, M.BAND)
    entry.dense = {cx=cx, cy=cy, rec=rec, from=M.BAND}
    return units+1
  end
  -- The next band of a dense chunk: the work it took.
  local function band(entry, surface)
    local d = entry.dense
    local to = math.min(32, d.from+M.BAND)
    local units = M.read_band(surface, d.rec, d.cx, d.cy, d.from, to)
    d.from = to
    if to >= 32 then entry.dense = nil; store(entry, ckey(d.cx, d.cy), d.rec) end
    return units
  end
  -- A pass walks the charted chunks outward from the caller's chunk (eight
  -- neighbours; an uncharted chunk ends the walk there), and from the chunks
  -- read before and the force's spawn, and reads each chunk not read since
  -- the pass began: the nearest first, without listing the surface.
  local function start(entry, surface, force, ox, oy)
    entry.walk, entry.walked, entry.head, entry.refreshed = {}, {}, 1, game.tick
    local w = entry.walk
    local function seed(cx, cy)
      local k = ckey(cx, cy)
      if not entry.walked[k] then entry.walked[k] = true; w[#w+1] = cx; w[#w+1] = cy end
    end
    seed(ox, oy)
    local spawn = try(function() return force.get_spawn_position(surface) end)
    if spawn then seed(math.floor(spawn.x/32), math.floor(spawn.y/32)) end
    for k in pairs(entry.chunks) do
      local cx = math.floor(k/1048576)-524288
      seed(cx, k-(cx+524288)*1048576-524288)
    end
  end
  -- Walk and read until the budget is spent: whether the pass is over, and
  -- the budget left. A chunk checked is one unit, a chunk read its work.
  local function work(entry, budget)
    local surface, force = game.surfaces[entry.surface], game.forces[entry.force]
    if not (surface and force) then entry.walk, entry.walked, entry.dense = nil, nil, nil; return true, budget end
    local w, walked = entry.walk, entry.walked
    while budget > 0 and (entry.dense or entry.head < #w) do
      if entry.dense then
        budget = budget-band(entry, surface)
      else
        local cx, cy = w[entry.head], w[entry.head+1]
        entry.head = entry.head+2
        budget = budget-1
        local t = entry.chunks[ckey(cx, cy)]
        if t or charted(force, surface, cx, cy) then
          if not t or t < entry.refreshed then budget = budget-read(entry, surface, force, cx, cy) end
          for dx = -1, 1 do
            for dy = -1, 1 do
              local nk = ckey(cx+dx, cy+dy)
              if not walked[nk] then walked[nk] = true; w[#w+1] = cx+dx; w[#w+1] = cy+dy end
            end
          end
        end
      end
    end
    if entry.head >= #w and not entry.dense then entry.walk, entry.walked, entry.full = nil, nil, true; return true, budget end
    return false, budget
  end
  local function busy(entry) return entry.walk ~= nil end
  -- The harness tick: the passes under way, TICK_BUDGET a tick in all;
  -- nothing once they are over. It never raises (a fault would stop the
  -- harness tick): a failed read ends that pass and the next call says why.
  function M.tick()
    local st = api.state()
    if not st.ores_busy then return end
    local budget = M.TICK_BUDGET
    for _, entry in pairs(st.ores or {}) do
      if busy(entry) then
        local ok, done, left = pcall(work, entry, budget)
        if not ok then
          entry.error = tostring(done); entry.walk, entry.walked, entry.dense = nil, nil, nil
        else
          if not done then return end
          budget = left
          if budget <= 0 then return end
        end
      end
    end
    st.ores_busy = nil
  end

  local function short(n)
    if n >= 1e6 then return string.format('%.1fM', n/1e6) end
    if n >= 1e4 then return string.format('%dk', round(n/1e3)) end
    return tostring(round(n))
  end
  local function box_text(p) return string.format('(%d,%d)-(%d,%d)', p.l, p.t, p.r, p.b) end
  local function ago(ticks)
    local m = math.floor(ticks/3600)
    return m < 1 and math.floor(ticks/60)..' s ago' or m..' min ago'
  end

  -- The rows read live (Sonnet, shift11 16:16: 26 drills on Vulcanus coal said no_minable_resources and he took the
  -- patch for depleted while it held 659k coal around them; at 16:29 the read still showed 26 miners after he had
  -- removed them): the chunks under each row's patch, nearest row first, are read again now within LIVE_BUDGET units.
  -- Whether any chunk was read.
  local function refresh(entry, surface, force, rows, limit)
    local budget, any, seen = M.LIVE_BUDGET, false, {}
    for i = 1, math.min(limit, #rows) do
      local q = rows[i].q
      for cx = math.floor(q.l/32), math.floor((q.r-1)/32) do
        for cy = math.floor(q.t/32), math.floor((q.b-1)/32) do
          local k = ckey(cx, cy)
          local d = entry.dense
          if budget <= 0 then return any end
          if not seen[k] and not (d and d.cx == cx and d.cy == cy) then
            seen[k] = true
            local t = entry.chunks[k]
            if not t or game.tick-t > M.LIVE_FRESH then
              local n = surface.count_entities_filtered{area={{cx*32, cy*32}, {cx*32+32, cy*32+32}}, type='resource'}
              budget = budget-1
              if n < budget then
                -- The ore only: the chunk's buildings, drills and nests stay as the pass read them (the drills on
                -- each row are read live below).
                local old = entry.data[k] or {}
                local rec = {t=game.tick, by={}, cells={}, buildings=old.buildings, drills=old.drills, enemies=old.enemies}
                local units = read_ore(surface, rec, cx*32, cy*32, 0, 32)
                finish(rec)
                budget, any = budget-units, true
                -- Kept without a rebuild of the patches (a few milliseconds each, every call while drills mine): the
                -- rows count their own tiles and amount from it (recount); the next pass's rebuild takes it in.
                if not entry.chunks[k] then entry.count = entry.count+1 end
                entry.chunks[k] = rec.t
                entry.data[k] = (rec.cells or rec.buildings or rec.drills or rec.enemies) and rec or nil
              end
            end
          end
        end
      end
    end
    return any
  end
  -- A patch's tiles and amount from the chunks under it as last read: the cells of its resource inside its box.
  local function recount(entry, q)
    local tiles, amount = 0, 0
    for cx = math.floor(q.l/32), math.floor((q.r-1)/32) do
      for cy = math.floor(q.t/32), math.floor((q.b-1)/32) do
        local rec = entry.data[ckey(cx, cy)]
        for _, c in ipairs(rec and rec.cells or {}) do
          if c.name == q.name and c.l >= q.l and c.r <= q.r and c.t >= q.t and c.b <= q.b then
            tiles, amount = tiles+c.n, amount+c.amount
          end
        end
      end
    end
    return tiles, amount
  end
  -- When the chunks under a patch were read: the oldest of them, in ticks ago.
  local function age(entry, q)
    local oldest = 0
    for cx = math.floor(q.l/32), math.floor((q.r-1)/32) do
      for cy = math.floor(q.t/32), math.floor((q.b-1)/32) do
        local t = entry.chunks[ckey(cx, cy)]
        if t then oldest = math.max(oldest, game.tick-t) end
      end
    end
    return oldest
  end
  local status_names
  local function status_name(s)
    if not status_names then
      status_names = {}
      for k, v in pairs(try(function() return defines.entity_status end) or {}) do status_names[v] = k end
    end
    return s and status_names[s] or 'unknown'
  end
  -- Our mining drills on a patch now, by status, and for each one with no_minable_resources the patch's ore still
  -- under its mining area (none: mined out there). A drill counts when its mining area overlaps the patch's box and
  -- it mines this resource or nothing. Returns count, {status = n}, [{x, y, tiles, amount}].
  local function drills_on(surface, force, q, checks)
    local by, under, n = {}, {}, 0
    local found = surface.find_entities_filtered{area={{q.l-5, q.t-5}, {q.r+5, q.b+5}}, type='mining-drill', force=force}
    for _, d in pairs(found) do
      if d.valid then
        local r = radius[d.name]
        if not r then r = try(function() return d.prototype.mining_drill_radius end) or 1; radius[d.name] = r end
        local x, y = d.position.x, d.position.y
        if x+r > q.l and x-r < q.r and y+r > q.t and y-r < q.b then
          local target = try(function() return d.mining_target end)
          local mines = target and target.valid and target.name
          if not mines or mines == q.name then
            n = n+1
            local st = status_name(d.status)
            by[st] = (by[st] or 0)+1
            if st == 'no_minable_resources' and checks.left > 0 then
              checks.left = checks.left-1
              local tiles, amount = 0, 0
              for _, o in pairs(surface.find_entities_filtered{area={{x-r, y-r}, {x+r, y+r}}, type='resource', name=q.name}) do
                tiles, amount = tiles+1, amount+o.amount
              end
              under[#under+1] = {x=x, y=y, tiles=tiles, amount=amount}
            end
          end
        end
      end
    end
    return n, by, under
  end
  -- {status = n} as 'working 12, no_minable_resources 10', most first.
  local function by_text(by)
    local list = {}
    for k, v in pairs(by) do list[#list+1] = {k, v} end
    table.sort(list, function(x, y) return x[2] > y[2] or x[2] == y[2] and x[1] < y[1] end)
    for i, e in ipairs(list) do list[i] = e[2]..' '..e[1] end
    return table.concat(list, ', ')
  end
  local function fmt(n) return tostring(round(n)):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '') end
  -- Every drill of ours on the patch, one line each (d17 batch20 B2, Haiku: the 45 south copper drills, past the 64-tile
  -- scan radius): position, name, status, what it mines, the patch's ore under its mining area; the stopped ones first,
  -- then the least ore under them. At most MAX_LIST lines; the count of all.
  M.MAX_LIST = 200
  local function drill_list(surface, force, q)
    local rows = {}
    local found = surface.find_entities_filtered{area={{q.l-5, q.t-5}, {q.r+5, q.b+5}}, type='mining-drill', force=force}
    for _, d in pairs(found) do
      if d.valid then
        local r = radius[d.name]
        if not r then r = try(function() return d.prototype.mining_drill_radius end) or 1; radius[d.name] = r end
        local x, y = d.position.x, d.position.y
        local target = try(function() return d.mining_target end)
        local mines = target and target.valid and target.name
        if x+r > q.l and x-r < q.r and y+r > q.t and y-r < q.b and (not mines or mines == q.name) then
          local amount, tiles = 0, 0
          if #rows < M.MAX_LIST then
            for _, o in pairs(surface.find_entities_filtered{area={{x-r, y-r}, {x+r, y+r}}, type='resource', name=q.name}) do
              tiles, amount = tiles+1, amount+o.amount
            end
          end
          local st = status_name(d.status)
          rows[#rows+1] = {x=x, y=y, name=d.name, st=st, tiles=tiles, amount=amount}
        end
      end
    end
    table.sort(rows, function(u, v)
      local uw, vw = u.st == 'working' and 1 or 0, v.st == 'working' and 1 or 0
      if uw ~= vw then return uw < vw end
      if u.amount ~= v.amount then return u.amount < v.amount end
      if u.y ~= v.y then return u.y < v.y end
      return u.x < v.x
    end)
    local lines = {}
    for i = 1, math.min(#rows, M.MAX_LIST) do
      local u = rows[i]
      lines[i] = string.format('(%g,%g) %s %s: %s', u.x, u.y, u.name, u.st,
        u.tiles == 0 and 'no ' .. q.name .. ' under it' or string.format('%s %s under it (%d tiles)', fmt(u.amount), q.name, u.tiles))
    end
    return lines, #rows
  end

  -- forecast (batch27 B5, Sonnet: coal fell to 3 of 56 drills working with no warning): for a patch's drills of ours, the
  -- ore under each one's mining area, a tile under several shared evenly among them, against what it takes a minute
  -- working (its mining speed with its speed bonus, the resource's mining time, the drill's resource drain; productivity
  -- adds output, not drain): when each stops, so when half and all of them have, and what they take a minute now.
  -- Stopped drills count as stopped. An estimate at today's rates.
  local function mins_text(m)
    if not m then return 'never at this rate' end
    if m >= 600 then return string.format('%dh', math.floor(m / 60 + 0.5)) end
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), math.floor(m % 60)) end
    return string.format('%dm', math.floor(m + 0.5))
  end
  function M.forecast(surface, force, q)
    local drills = {}
    for _, d in pairs(surface.find_entities_filtered{area={{q.l-5, q.t-5}, {q.r+5, q.b+5}}, type='mining-drill', force=force}) do
      if d.valid then
        local r = radius[d.name]
        if not r then r = try(function() return d.prototype.mining_drill_radius end) or 1; radius[d.name] = r end
        local x, y = d.position.x, d.position.y
        local target = try(function() return d.mining_target end)
        local mines = target and target.valid and target.name
        if x+r > q.l and x-r < q.r and y+r > q.t and y-r < q.b and (not mines or mines == q.name) and #drills < M.MAX_LIST then
          drills[#drills+1] = {e=d, x=x, y=y, r=r, tiles={}}
        end
      end
    end
    local cover, amount = {}, {}
    for _, dr in ipairs(drills) do
      for _, o in pairs(surface.find_entities_filtered{area={{dr.x-dr.r, dr.y-dr.r}, {dr.x+dr.r, dr.y+dr.r}}, type='resource', name=q.name}) do
        local key = o.position.x .. ',' .. o.position.y
        cover[key] = (cover[key] or 0) + 1; amount[key] = o.amount
        dr.tiles[#dr.tiles+1] = key
      end
    end
    local mtime = try(function() return prototypes.entity[q.name].mineable_properties.mining_time end) or 1
    local times, take, working, under = {}, 0, 0, 0
    for key, n in pairs(amount) do under = under + n end
    for _, dr in ipairs(drills) do
      local share = 0
      for _, key in ipairs(dr.tiles) do share = share + amount[key] / cover[key] end
      local st = status_name(dr.e.status)
      local t = 0
      if st == 'working' and share > 0 then
        local speed = (try(function() return dr.e.prototype.mining_speed end) or 0.5) * (1 + (try(function() return dr.e.speed_bonus end) or 0))
        local drain = (try(function() return dr.e.prototype.resource_drain_rate_percent end) or 100) / 100
        local per_min = speed * 60 / mtime * drain
        take = take + per_min; working = working + 1
        t = per_min > 0 and share / per_min or nil
      end
      times[#times+1] = t or math.huge
    end
    table.sort(times)
    local n = #times
    local half = n > 0 and times[math.ceil(n / 2)] or nil
    local all = n > 0 and times[n] or nil
    if half == math.huge then half = nil end
    if all == math.huge then all = nil end
    local ents = {}
    for i, dr in ipairs(drills) do ents[i] = dr.e end
    return {entities=ents, drills=n, working=working, under=under, take_per_min=math.floor(take * 10 + 0.5) / 10,
      half_min=half and math.floor(half + 0.5), all_min=all and math.floor(all + 0.5),
      line=string.format('%d drill%s (%d working) on %s: %s under them, taken %s/min now; half of them stopped %s, all %s (each drill\'s share of the ore under it at its rate now; tiles under several shared)',
        n, n == 1 and '' or 's', working, q.name, fmt(under), fmt(take), half == 0 and 'now' or half and 'in about ' .. mins_text(half) or 'not at this rate',
        all == 0 and 'now' or all and 'in about ' .. mins_text(all) or 'not at this rate')}
  end
  M.mins_text = mins_text

  function M.handlers.ores(p, a)
    a = a or {}
    local want
    if a.resource ~= nil then
      local wanted = type(a.resource) == 'table' and a.resource or {a.resource}
      assert(#wanted >= 1 and #wanted <= 16, 'resource is a resource name or 1..16 of them')
      want = {}
      for _, name in ipairs(wanted) do
        local proto = type(name) == 'string' and prototypes.entity[name]
        if not (proto and proto.type == 'resource') then
          local all = {}
          for n, pr in pairs(prototypes.entity) do if pr.type == 'resource' then all[#all+1] = n end end
          table.sort(all)
          error(tostring(name)..' is not a resource; resources: '..table.concat(all, ', '), 0)
        end
        want[name] = true
      end
    end
    local min = a.min_amount
    assert(min == nil or (type(min) == 'number' and min >= 0), 'min_amount is a number: the least amount left (oil and other infinite resources: their yield %)')
    local limit = api.integer(a.limit, 20, 1, 100, 'limit')
    local surface, force = p.surface, p.force
    local remote = type(p) == 'table' and (rawget(p, '__remote') ~= nil or rawget(p, '__platform') ~= nil)
    local origin = a.position ~= nil and api.position(a.position) or (not remote and p.position) or nil
    if surface.platform then
      return {surface=surface.name, platform=surface.platform.name, patches={}, count=0,
        note='a space platform has no resource tiles; surface= names a planet'}
    end
    local all = surveys()
    local key = force.name..'@'..surface.index
    local entry = all[key]
    if not entry then
      entry = {surface=surface.index, force=force.name, chunks={}, data={}, count=0}
      all[key] = entry
    end
    local fault = entry.error
    entry.error = nil
    -- A pass: the first call reads around the caller within its own budget;
    -- the harness tick goes on. A call REFRESH_TICKS after a pass began (or
    -- after a failed one) starts the next.
    if not busy(entry) and (not entry.refreshed or fault or game.tick-entry.refreshed >= REFRESH_TICKS) then
      local o = origin or {x=0, y=0}
      start(entry, surface, force, math.floor(o.x/32), math.floor(o.y/32))
      if not entry.full then work(entry, M.CALL_BUDGET) end
    end
    if busy(entry) then api.state().ores_busy = true end
    -- Patches are built again when chunks were read since; while a pass is
    -- under way at most once a second (a rebuild is a few milliseconds).
    local function rebuild()
      entry.patches = M.build(entry.data, charted_fn(force, surface, entry))
      entry.built, entry.built_tick = entry.changed, game.tick
    end
    if not entry.patches or (entry.built ~= entry.changed and (not busy(entry) or game.tick-entry.built_tick >= 60)) then rebuild() end
    local function select()
      local rows, totals, torder = {}, {}, {}
      for _, q in ipairs(entry.patches) do
        local t = totals[q.name]
        if not t then t = {patches=0, amount=0, yield=q.yield ~= nil}; totals[q.name] = t; torder[#torder+1] = q.name end
        t.patches = t.patches+1; t.amount = t.amount+(q.yield or q.amount)
        if (not want or want[q.name]) and (not min or (q.yield or q.amount) >= min) then
          rows[#rows+1] = {q=q, d=origin and to_patch(q, origin.x, origin.y) or nil}
        end
      end
      table.sort(rows, function(x, y)
        local dx, dy = x.d or x.q.building_d or math.huge, y.d or y.q.building_d or math.huge
        if dx ~= dy then return dx < dy end
        if x.q.name ~= y.q.name then return x.q.name < y.q.name end
        return x.q.tiles > y.q.tiles
      end)
      return rows, totals, torder
    end
    -- The rows' chunks read again (each row counts its own tiles and amount from them below).
    local rows, totals, torder = select()
    -- patch: the one patch with ore at or within 8 tiles of that position, with every drill of ours on it (B2).
    local only
    assert(a.forecast == nil or (a.forecast == true and a.patch ~= nil), 'forecast is true, with patch (a spot on the patch)')
    if a.patch ~= nil then
      local pp = api.position(a.patch)
      local best, bd
      for _, r in ipairs(rows) do
        local d = to_patch(r.q, pp.x, pp.y, bd)
        if not bd or d < bd then best, bd = r, d end
      end
      if not best or bd > 8 then
        error(string.format('no %spatch with ore within 8 tiles of (%g,%g) in the %d charted chunks read so far%s', want and 'such ' or '', pp.x, pp.y, entry.count,
          best and string.format('; the nearest is %s %s, %d tiles off', best.q.name, box_text(best.q), round(bd)) or ''), 0)
      end
      rows, only = {best}, best
    end
    refresh(entry, surface, force, rows, limit)
    local out = {}
    local checks = {left=M.MAX_UNDER}
    for i = 1, math.min(limit, #rows) do
      local q, d = rows[i].q, rows[i].d
      local row = {resource=q.name, centre=q.centre, box=box_text(q), chart_edge=q.chart_edge or nil}
      local old = age(entry, q)
      row.read = old <= M.LIVE_FRESH and 'now' or ago(old)
      local tiles, amount = q.tiles, q.amount
      if not q.fluid and old <= M.LIVE_FRESH then tiles, amount = recount(entry, q) end
      if q.fluid then row.wells = q.tiles else row.tiles = tiles end
      if q.yield then row.yield = q.yield..'%' else row.amount = amount end
      -- Our drills on it now, by status; those with no_minable_resources checked for ore under them.
      local n, by, under = drills_on(surface, force, q, checks)
      row.miners = n
      if n > 0 then row.drills = by_text(by) end
      if #under > 0 then
        local bare, held = 0, {}
        for _, u in ipairs(under) do
          if u.tiles == 0 then bare = bare+1
          elseif #held < 6 then held[#held+1] = string.format('(%g,%g) %d tiles %s', u.x, u.y, u.tiles, fmt(u.amount)) end
        end
        local parts = {}
        if bare > 0 then
          parts[#parts+1] = string.format('no %s left under %d of the %d drills with no_minable_resources (mined out there)',
            q.name, bare, #under)
        end
        if #held > 0 then parts[#parts+1] = string.format('%s still under %s', q.name, table.concat(held, ', ')) end
        if not q.yield then
          parts[#parts+1] = string.format('the patch holds %s %s in %s tiles (read %s)', fmt(amount), q.name, fmt(tiles), row.read)
        end
        row.depleted_drills = table.concat(parts, '; ')
      end
      if only then
        local lines, n = drill_list(surface, force, q)
        row.drill_list = lines
        row.drill_list_note = n > #lines and string.format('%d drills; the first %d listed', n, #lines) or nil
        if a.forecast then
          row.forecast = M.forecast(surface, force, q)
          row.forecast.entities = nil
          -- the nearest other patches of the ore, their size, and a demolisher territory they lie in (demolishers.lua)
          local near = {}
          for _, other in ipairs(entry.patches or {}) do
            if other ~= q and other.name == q.name then
              near[#near+1] = {o=other, d=math.sqrt((other.centre.x - q.centre.x) ^ 2 + (other.centre.y - q.centre.y) ^ 2)}
            end
          end
          table.sort(near, function(u, v) return u.d < v.d end)
          local alts = {}
          for i = 1, math.min(3, #near) do
            local o = near[i].o
            local terr = api.territory and try(function() return api.territory(surface, force, o.centre) end)
            alts[i] = string.format('%s at (%d,%d), %d tiles away: %s in %s tiles%s', o.name, round(o.centre.x), round(o.centre.y), round(near[i].d),
              fmt(o.amount or 0), fmt(o.tiles or 0), terr and '; ' .. terr or '')
          end
          row.forecast.alternatives = #alts > 0 and alts or nil
        end
      end
      if d then row.distance = round(d); row.direction = d > 0 and compass(origin, q.centre) or nil end
      if q.building_d then
        row.from_building = round(q.building_d)
        row.building = string.format('%s %g,%g', q.building.name, q.building.x, q.building.y)
      end
      if q.nest then
        row.spawners, row.worms = q.spawners, q.worms
        row.nearest_nest = string.format('%s %d,%d %d tiles', q.nest.name, round(q.nest.x), round(q.nest.y), round(q.nest_d))
      end
      out[i] = row
    end
    table.sort(torder)
    local sums = {}
    for _, name in ipairs(torder) do
      local t = totals[name]
      sums[#sums+1] = string.format('%s %d (%s)', name, t.patches, t.yield and 'yield '..round(t.amount)..'%' or short(t.amount))
    end
    local survey
    if busy(entry) and not entry.full then
      survey = string.format('reading the charted map: %d chunk%s read so far, nearest first; the rest is read a few chunks a tick: later calls show every patch',
        entry.count, entry.count == 1 and '' or 's')
    elseif busy(entry) then
      survey = string.format('%d charted chunks read; being read again since %s (a few chunks a tick)', entry.count, ago(game.tick-entry.refreshed))
    else
      survey = string.format('%d charted chunks read; the last pass began %s', entry.count, ago(game.tick-entry.refreshed))
    end
    return {surface=surface.name, from=origin and {x=round(origin.x*10)/10, y=round(origin.y*10)/10} or nil, patches=out, count=#rows,
      more=#rows > limit and string.format('+%d more: limit raises the count', #rows-limit) or nil,
      resources=#sums > 0 and table.concat(sums, ', ') or 'no resource tiles on the charted chunks read', survey=survey,
      survey_error=fault and 'a background read failed and ended its pass (this call began another): '..fault or nil}
  end
  M.schema.ores = {resource='optional resource name or array (iron-ore, crude-oil, ...; default every resource)',
    forecast='optional true, with patch: the depletion forecast of our drills on it: each drill\'s share of the ore under its mining area (a tile under several shared) against what it takes a minute working (mining speed with its speed bonus, the resource\'s mining time, the drill\'s drain; productivity adds output, not drain): forecast {drills, working, under, take_per_min, half_min, all_min (minutes until half and all of them have stopped; stopped ones count), line, alternatives (the 3 nearest other patches of the ore: where, how far, how much, and a demolisher territory one lies in)}',
    patch='optional {x,y}: only the patch with ore at or within 8 tiles of it, with drill_list: every mining drill of ours on it, one line each (position, name, status, the patch\'s ore under its mining area), stopped ones first, then the least ore; at most '..M.MAX_LIST..' lines (drill_list_note gives the count past that)',
    surface='optional planet or surface name (default yours)', position='optional {x,y}: measure distance from here instead of the character',
    min_amount='optional: leave out patches with less left (oil and other infinite resources: their yield %)', limit='1..100 patches (default 20)',
    returns='read: patches [{resource, centre, box, tiles (fluids: wells), amount (left; oil and other infinite resources: yield, summed over the wells), distance and direction from you '
      ..'(or position; none on another surface), from_building (tiles from the patch to our nearest building) and building, spawners, worms '
      ..'and nearest_nest within '..NEST_RANGE..' tiles, miners (our mining drills on it now), drills (them by status: working, no_minable_resources ...), '
      ..'depleted_drills (the ones with no_minable_resources checked against the ore under their mining area: mined out there, or what is left '
      ..'under them, and what the patch still holds), read (now: the chunks under the row were read in this call, else how long ago; '
      ..'the rows nearest first are read again within a budget), chart_edge (ore reaches the edge of the charted map: '
      ..'it may go on past it)}] nearest first (on another surface: nearest our buildings first); count (patches that match), more, '
      ..'resources (patches and amount per resource), survey (chunks read: the first call on a surface reads the chunks around you '
      ..'and the rest is read a few chunks a tick, so later calls show every patch; a call 5 min after a pass began starts the next). '
      ..'A patch: tiles of one resource in touching 4x4 cells (fluid wells: 16x16) on charted chunks, across chunk borders'}
  return M
end
