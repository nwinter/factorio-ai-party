-- net_map (operator read for the live map; d21 batch68 AD3, viewer Aurora 13:03 PDT: "Could maps show logistic/power
-- network IDs and coverage, plus a selected item's source-to-consumer blockers? K2 carbide and the lab spoilage provider
-- exposed reachability gaps."). Per planet, from the census pass's entity lists (census.lua poles and typed: no find of
-- its own), made in steps in the background, one planet at a time, each made again PERIOD after its last:
-- - electric: each network of our poles (electric_network_id) with its pole count ("id,letter,poles;..."), and a grid
--   of where they supply: a
--   cell carries the network whose poles' supply area covers any of it (the one with the most poles where two do), one
--   letter a network (the #LETTERS biggest; '*' the others). The cell: the smallest power of 2 tiles that puts the
--   middle 90% of the poles within EMAX cells a side; the grid spans every pole, at most MAX_CELLS cells a side round
--   the poles' median (poles beyond: `outside`); rows run-length packed as push_live packs them ("12A", rle 1);
-- - logistic: each logistic network of our roboports (network_id), its roboports' positions with their logistic and
--   construction radius (the game's areas are squares that far from the roboport) and its robots, all and idle:
--   {id, lr, cr, n, ports "x,y;...", odd "x,y,lr,cr;..." (a radius other than the network's first), robots "logistic,
--   idle, construction, idle"};
-- - items: per item, its sources and consumers on the planet by kind and by the logistic network at their spot (0: no
--   roboport's logistic area covers it). Sources: crafters making it (their recipe, a furnace's last one), drills mining
--   it, provider, storage and buffer chests and cargo landing pads holding it (amount: the count; a pad's network: the
--   one at its spot, the pad's own logistic_network reads nil on 2.0.77), and machines' and labs' trash slots holding
--   it (spoilage). Consumers: crafters whose recipe takes it, labs (the packs the force's research takes now) and
--   requester and buffer chests asking for it (amount: the count asked). A group: kind, network, count, amount, members
--   with an electric energy source and no electric network, the box round all and the first MAX_POS positions, as one
--   string "kind,network,count,amount,unpowered,x0,y0,x1,y1[,x,y]..." (a group of one: "...,x,y", its spot), groups
--   joined by ';'. Kinds: A crafter, M drill, R lab, P provider chest, S storage, B buffer, Q requester, L landing
--   pad, T trash slots.
-- Strings rather than tables of numbers: table_to_json takes about 28 us a number on the x86 private copy.
-- Read only; nothing in the game changes.
return function(api)
  local M = {operator={}}
  M.PERIOD, M.EVERY, M.POLE_SLICE, M.SLICE, M.ROWS, M.EMAX, M.MAX_CELLS = 3600, 3, 200, 100, 100, 160, 1024
  M.MAX_POS, M.MAX_ITEMS, M.MAX_PORTS = 4, 400, 2000
  local LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
  local ITEM_TYPES = {'assembling-machine', 'furnace', 'rocket-silo', 'lab', 'mining-drill', 'logistic-container', 'cargo-landing-pad'}
  local CHEST_KIND = {['active-provider']='P', ['passive-provider']='P', storage='S', buffer='B', requester='Q'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.netmap = s.netmap or {done={}, tried={}}
    return s.netmap
  end
  local function planets()
    local out = {}
    for _, s in pairs(game.surfaces) do if try(function() return s.planet ~= nil end) then out[#out+1] = s end end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
  end
  -- prototype facts, cached by name (and quality)
  local SAD, MODE, ELEC, MINED, LAB_IN = {}, {}, {}, {}, {}
  local function supply(e)
    local q = try(function() return e.quality.name end) or 'normal'
    local k = e.name .. '|' .. q
    local d = SAD[k]
    if d == nil then d = try(function() return e.prototype.get_supply_area_distance(e.quality) end) or 0; SAD[k] = d end
    return d
  end
  local function mode(name)
    local m = MODE[name]
    if m == nil then m = try(function() return prototypes.entity[name].logistic_mode end) or false; MODE[name] = m end
    return m
  end
  local function electric(name)
    local v = ELEC[name]
    if v == nil then v = try(function() return prototypes.entity[name].electric_energy_source_prototype ~= nil end) == true; ELEC[name] = v end
    return v
  end
  local function mined(resource)
    local v = MINED[resource]
    if v == nil then
      v = {}
      for _, p in ipairs(try(function() return prototypes.entity[resource].mineable_properties.products end) or {}) do
        if p.type == nil or p.type == 'item' then v[#v+1] = p.name end
      end
      MINED[resource] = v
    end
    return v
  end
  local function lab_inputs(name)
    local v = LAB_IN[name]
    if v == nil then
      v = {}
      for _, n in ipairs(try(function() return prototypes.entity[name].lab_inputs end) or {}) do v[n] = true end
      LAB_IN[name] = v
    end
    return v
  end

  local function letter(r) return r <= #LETTERS and LETTERS:sub(r, r) or '*' end
  -- A sparse grid row {cx = rank} from cx0, run-length packed: three or more of a letter as the count and the letter
  -- ("....AAAA" -> "4.4A"), the row's trailing empty cells left out.
  local function rle_row(row, cx0)
    if not row then return '' end
    local keys = {}
    for cx in pairs(row) do keys[#keys+1] = cx end
    table.sort(keys)
    local out, ch, n, at = {}, nil, 0, cx0
    local function emit(c, k) if c and k > 0 then out[#out+1] = k >= 3 and (k .. c) or string.rep(c, k) end end
    for _, cx in ipairs(keys) do
      local c = letter(row[cx])
      if cx > at then emit(ch, n); ch, n = nil, 0; emit('.', cx - at) end
      if c == ch then n = n + 1 else emit(ch, n); ch, n = c, 1 end
      at = cx + 1
    end
    emit(ch, n)
    return table.concat(out)
  end
  local function new_job(s, tick)
    return {surface=s.index, name=s.name, start=tick, stage='poles', i=1,
      px={}, py={}, pd={}, pid={}, nets={}, minx=math.huge, miny=math.huge, maxx=-math.huge, maxy=-math.huge,
      ports={}, nports=0, items={}, n_items=0}
  end
  -- A source or consumer into its group (kind and logistic network).
  local function add(job, item, role, kind, lnet, amount, e, unpowered)
    local it = job.items[item]
    if not it then
      if job.n_items >= M.MAX_ITEMS then job.items_capped = true; return end
      it = {s={}, c={}}; job.items[item] = it; job.n_items = job.n_items + 1
    end
    local k = kind .. lnet
    local g = it[role][k]
    local x, y = math.floor(e.position.x), math.floor(e.position.y)
    if not g then g = {kind, lnet, 0, 0, 0, {}, {x, y, x, y}}; it[role][k] = g end
    g[3] = g[3] + 1
    g[4] = g[4] + (amount or 0)
    if unpowered then g[5] = g[5] + 1 end
    if #g[6] < M.MAX_POS then g[6][#g[6]+1] = {x, y} end
    local b = g[7]
    if x < b[1] then b[1] = x end
    if y < b[2] then b[2] = y end
    if x > b[3] then b[3] = x end
    if y > b[4] then b[4] = y end
  end
  local function recipe_of(e)
    local r = try(function() return e.get_recipe() end)
    if r then return try(function() return r.products end), try(function() return r.ingredients end) end
    if e.type == 'furnace' then
      local pr = try(function() return e.previous_recipe end)
      local name = pr and (type(pr.name) == 'string' and pr.name or try(function() return pr.name.name end))
      local p = name and prototypes.recipe[name]
      if p then return p.products, p.ingredients end
    end
  end
  local function trash(job, e, kind, lnet, unpowered)
    local inv = try(function() return e.get_inventory(e.type == 'lab' and defines.inventory.lab_trash or defines.inventory.crafter_trash) end)
    for _, it in ipairs(inv and try(function() return inv.get_contents() end) or {}) do add(job, it.name, 's', 'T', lnet, it.count, e, unpowered) end
  end
  local function read_item_entity(job, surface, force, e)
    if not e.valid then return end
    local t = e.type
    if t == 'logistic-container' then
      local kind = CHEST_KIND[mode(e.name) or '']
      if not kind then return end
      local ln = try(function() return e.logistic_network end)
      local lnet = ln and try(function() return ln.network_id end) or 0
      if kind ~= 'Q' then
        local inv = try(function() return e.get_inventory(defines.inventory.chest) end)
        local held = {}
        for _, it in ipairs(inv and try(function() return inv.get_contents() end) or {}) do held[it.name] = (held[it.name] or 0) + it.count end
        for name, n in pairs(held) do add(job, name, 's', kind, lnet, n, e) end
      end
      if kind == 'Q' or kind == 'B' then
        local rp = try(function() return e.get_requester_point() end)
        local asked = {}
        for _, f in ipairs(rp and try(function() return rp.filters end) or {}) do
          if f.name and (f.count or 0) > 0 then asked[f.name] = (asked[f.name] or 0) + f.count end
        end
        for name, n in pairs(asked) do add(job, name, 'c', kind, lnet, n, e) end
      end
      return
    end
    local ln = try(function() return surface.find_logistic_network_by_position(e.position, force) end)
    local lnet = ln and try(function() return ln.network_id end) or 0
    if t == 'cargo-landing-pad' then
      local inv = try(function() return e.get_inventory(defines.inventory.cargo_landing_pad_main) end)
      local held = {}
      for _, it in ipairs(inv and try(function() return inv.get_contents() end) or {}) do held[it.name] = (held[it.name] or 0) + it.count end
      for name, n in pairs(held) do add(job, name, 's', 'L', lnet, n, e) end
      return
    end
    local unpowered = electric(e.name) and try(function() return e.electric_network_id end) == nil
    if t == 'mining-drill' then
      local target = try(function() return e.mining_target end)
      for _, name in ipairs(target and mined(target.name) or {}) do add(job, name, 's', 'M', lnet, 0, e, unpowered) end
    elseif t == 'lab' then
      local ins = lab_inputs(e.name)
      for _, name in ipairs(job.research or {}) do if ins[name] then add(job, name, 'c', 'R', lnet, 0, e, unpowered) end end
      trash(job, e, 'R', lnet, unpowered)
    else
      local products, ingredients = recipe_of(e)
      for _, p in ipairs(products or {}) do if p.type == nil or p.type == 'item' then add(job, p.name, 's', 'A', lnet, 0, e, unpowered) end end
      for _, p in ipairs(ingredients or {}) do if p.type == nil or p.type == 'item' then add(job, p.name, 'c', 'A', lnet, 0, e, unpowered) end end
      trash(job, e, 'A', lnet, unpowered)
    end
  end

  -- The job's finished map.
  local function finish(job)
    local nets = {}
    for _, n in ipairs(job.order or {}) do
      if n.rank <= #LETTERS then nets[#nets+1] = n.id .. ',' .. LETTERS:sub(n.rank, n.rank) .. ',' .. n.poles end
    end
    local more, more_poles = 0, 0
    for _, n in ipairs(job.order or {}) do if n.rank > #LETTERS then more, more_poles = more + 1, more_poles + n.poles end end
    local electric = {poles=#job.px, nets=table.concat(nets, ';'), more=more > 0 and more or nil, more_poles=more > 0 and more_poles or nil, capped=job.poles_capped or nil}
    if job.cell then
      electric.cell, electric.x0, electric.y0 = job.cell, job.cx0 * job.cell, job.cy0 * job.cell
      electric.w, electric.h, electric.rows, electric.rle = job.cx1 - job.cx0 + 1, job.cy1 - job.cy0 + 1, job.rows, 1
      electric.outside = job.outside > 0 and job.outside or nil
    end
    local logistic = {}
    for _, id in ipairs(job.port_ids or {}) do logistic[#logistic+1] = job.ports[id] end
    table.sort(logistic, function(a, b) return #a.ports > #b.ports or (#a.ports == #b.ports and a.id < b.id) end)
    for i, n in ipairs(logistic) do
      local ports, odd = {}, {}
      for _, p in ipairs(n.ports) do ports[#ports+1] = string.format('%g,%g', p[1], p[2]) end
      for _, p in ipairs(n.odd) do odd[#odd+1] = string.format('%g,%g,%g,%g', p[1], p[2], p[3], p[4]) end
      logistic[i] = {id=n.id, lr=n.lr, cr=n.cr, n=#n.ports + #n.odd, ports=table.concat(ports, ';'), odd=#odd > 0 and table.concat(odd, ';') or nil,
        robots=n.robots and table.concat(n.robots, ',') or nil}
    end
    local items, names = {}, {}
    for name in pairs(job.items) do names[#names+1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local it, row = job.items[name], {name, '', ''}
      for r, role in ipairs({'s', 'c'}) do
        local keys = {}
        for k in pairs(it[role]) do keys[#keys+1] = k end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do
          local g = it[role][k]
          local parts = {g[1], g[2], g[3], g[4], g[5], g[7][1], g[7][2], g[7][3], g[7][4]}
          -- (one spot: its position is the box)
          if g[3] == 1 then parts[8], parts[9] = nil, nil
          else for _, p in ipairs(g[6]) do parts[#parts+1] = p[1]; parts[#parts+1] = p[2] end end
          out[#out+1] = table.concat(parts, ',')
        end
        row[r+1] = table.concat(out, ';')
      end
      items[#items+1] = row
    end
    return {surface=job.name, tick=job.start, done_tick=game.tick, census=job.census, electric=electric, logistic=logistic,
      ports_capped=job.ports_capped or nil, items=items, items_capped=job.items_capped or nil, research=job.research_name}
  end

  function M.step(st, tick)
    local job = st.job
    local force = game.forces.player
    if not job then
      local best, bage
      for _, s in ipairs(planets()) do
        local d = st.done[s.name]
        local last = math.max(d and d.tick or -math.huge, st.tried[s.name] or -math.huge)
        local age = tick - last
        if age >= M.PERIOD and (not best or age > bage) then best, bage = s, age end
      end
      for name in pairs(st.done) do if not game.get_surface(name) then st.done[name] = nil end end
      if best then st.job = new_job(best, tick) end
      return
    end
    local surface = game.get_surface(job.surface)
    if not (surface and force) then st.job = nil; return end
    if job.stage == 'poles' then
      if not job.list then
        local list, as_of, capped = api.poles(force, surface)
        -- (no census pass over this surface yet: tried again PERIOD on)
        if not list then st.tried[job.name] = tick; st.job = nil; return end
        job.list, job.census, job.poles_capped = list, as_of, capped or nil
      end
      local last = math.min(#job.list, job.i + M.POLE_SLICE - 1)
      for k = job.i, last do
        local e = job.list[k]
        local id = e.valid and try(function() return e.electric_network_id end)
        if id then
          local x, y, d = e.position.x, e.position.y, supply(e)
          local n = #job.px + 1
          job.px[n], job.py[n], job.pd[n], job.pid[n] = x, y, d, id
          job.nets[id] = (job.nets[id] or 0) + 1
          if d > 0 then
            if x - d < job.minx then job.minx = x - d end
            if x + d > job.maxx then job.maxx = x + d end
            if y - d < job.miny then job.miny = y - d end
            if y + d > job.maxy then job.maxy = y + d end
          end
        end
      end
      job.i = last + 1
      if job.i > #job.list then
        -- each network's letter by its poles (most first), and the grid's cell: up to EMAX cells a side
        local order = {}
        for id, n in pairs(job.nets) do order[#order+1] = {id=id, poles=n} end
        table.sort(order, function(a, b) return a.poles > b.poles or (a.poles == b.poles and a.id < b.id) end)
        job.rank = {}
        for r, n in ipairs(order) do n.rank = r; job.rank[n.id] = r end
        job.order = order
        if job.maxx > job.minx then
          -- the middle 90% of the poles (a sample of at most 2000) sets the cell; the frame spans all, at most MAX_CELLS
          local xs, ys, every = {}, {}, math.max(1, math.floor(#job.px / 2000))
          for k = 1, #job.px, every do xs[#xs+1] = job.px[k]; ys[#ys+1] = job.py[k] end
          table.sort(xs); table.sort(ys)
          local lo, hi = math.max(1, math.floor(#xs * 0.05)), math.max(1, math.ceil(#xs * 0.95))
          local C = 1
          while (xs[hi] - xs[lo] + 8) / C > M.EMAX or (ys[hi] - ys[lo] + 8) / C > M.EMAX do C = C * 2 end
          job.cell = C
          local mx, my, half = math.floor(xs[math.ceil(#xs / 2)] / C), math.floor(ys[math.ceil(#ys / 2)] / C), M.MAX_CELLS / 2
          job.cx0, job.cy0 = math.max(math.floor(job.minx / C), mx - half), math.max(math.floor(job.miny / C), my - half)
          job.cx1, job.cy1 = math.min(math.ceil(job.maxx / C) - 1, mx + half - 1), math.min(math.ceil(job.maxy / C) - 1, my + half - 1)
          job.grid, job.stage, job.outside = {}, 'grid', 0
        else job.stage = 'ports' end
        job.list, job.i = nil, 1
      end
    elseif job.stage == 'grid' then
      local C, last = job.cell, math.min(#job.px, job.i + M.POLE_SLICE - 1)
      for k = job.i, last do
        local x, y, d, r = job.px[k], job.py[k], job.pd[k], job.rank[job.pid[k]]
        local ax, ay, bx, by = math.floor((x - d) / C), math.floor((y - d) / C), math.ceil((x + d) / C) - 1, math.ceil((y + d) / C) - 1
        if d <= 0 then
        elseif bx < job.cx0 or ax > job.cx1 or by < job.cy0 or ay > job.cy1 then job.outside = job.outside + 1
        else
          for cy = math.max(ay, job.cy0), math.min(by, job.cy1) do
            local row = job.grid[cy]
            if not row then row = {}; job.grid[cy] = row end
            for cx = math.max(ax, job.cx0), math.min(bx, job.cx1) do
              local old = row[cx]
              if not old or r < old then row[cx] = r end
            end
          end
        end
      end
      job.i = last + 1
      if job.i > #job.px then job.stage, job.rows, job.cy = 'rows', {}, job.cy0 end
    elseif job.stage == 'rows' then
      for cy = job.cy, math.min(job.cy1, job.cy + M.ROWS - 1) do
        job.rows[#job.rows+1] = rle_row(job.grid[cy], job.cx0)
        job.cy = cy + 1
      end
      if job.cy > job.cy1 then job.grid, job.stage = nil, 'ports' end
    elseif job.stage == 'ports' then
      if not job.list then job.list, job.i, job.port_ids = api.typed(force, surface, 'roboport') or {}, 1, {} end
      local last = math.min(#job.list, job.i + M.SLICE - 1)
      for k = job.i, last do
        local e = job.list[k]
        local cell = e.valid and try(function() return e.logistic_cell end)
        if cell then
          if job.nports >= M.MAX_PORTS then job.ports_capped = true; break end
          local ln = try(function() return cell.logistic_network end)
          local id = ln and try(function() return ln.network_id end) or 0
          local lr, cr = try(function() return cell.logistic_radius end) or 0, try(function() return cell.construction_radius end) or 0
          local n = job.ports[id]
          if not n then
            n = {id=id, lr=lr, cr=cr, ports={}, odd={}}
            if ln then
              n.robots = {try(function() return ln.all_logistic_robots end) or 0, try(function() return ln.available_logistic_robots end) or 0,
                try(function() return ln.all_construction_robots end) or 0, try(function() return ln.available_construction_robots end) or 0}
            end
            job.ports[id] = n; job.port_ids[#job.port_ids+1] = id
          end
          local x, y = math.floor(e.position.x * 2 + 0.5) / 2, math.floor(e.position.y * 2 + 0.5) / 2
          if lr == n.lr and cr == n.cr then n.ports[#n.ports+1] = {x, y} else n.odd[#n.odd+1] = {x, y, lr, cr} end
          job.nports = job.nports + 1
        end
      end
      job.i = last + 1
      if job.i > #job.list then
        job.list, job.i, job.stage = nil, 1, 'items'
        local r = force.current_research
        job.research, job.research_name = {}, r and r.name or nil
        for _, ing in ipairs(r and try(function() return r.research_unit_ingredients end) or {}) do
          if ing.type == nil or ing.type == 'item' then job.research[#job.research+1] = ing.name end
        end
      end
    elseif job.stage == 'items' then
      if not job.list then job.list = api.typed(force, surface, ITEM_TYPES) or {} end
      local last = math.min(#job.list, job.i + M.SLICE - 1)
      for k = job.i, last do read_item_entity(job, surface, force, job.list[k]) end
      job.i = last + 1
      if job.i > #job.list then
        st.done[job.name] = finish(job)
        st.tried[job.name] = nil
        st.job = nil
      end
    end
  end
  function M.tick(tick)
    if tick % M.EVERY ~= 0 then return end
    local st = store()
    local ok, err = pcall(M.step, st, tick)
    if not ok then
      if st.job then st.tried[st.job.name] = tick end
      st.job = nil
      st.errors = {count=((st.errors or {}).count or 0) + 1, last=tostring(err):sub(1, 200), tick=tick}
    end
  end
  -- {tick, surfaces [{surface, tick}] (the maps made), map (args.surface's, or none), job {surface, stage}, errors}
  function M.read(args)
    args = type(args) == 'table' and args or {}
    local st = store()
    local list = {}
    for name, m in pairs(st.done) do list[#list+1] = {surface=name, tick=m.tick} end
    table.sort(list, function(a, b) return a.surface < b.surface end)
    return {tick=game.tick, surfaces=list, map=type(args.surface) == 'string' and st.done[args.surface] or nil,
      job=st.job and {surface=st.job.name, stage=st.job.stage, start=st.job.start} or nil, errors=st.errors}
  end
  M.operator.net_map = M.read
  return M
end
