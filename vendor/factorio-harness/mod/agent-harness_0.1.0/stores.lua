-- where_is: where an item is stored on a surface, nearest first, as a player
-- could find by looking (the science study, shift 5: 18 labs lacked red packs
-- for three hours while Gemini moved 1,118 of them out of one chest; `labs`
-- showed stock only at each lab's feeders). Read only. Chests, labs, machines,
-- vehicles, landing pads and platform hubs by entity; belts and inserter hands
-- as totals; the team's characters by name.
return function(api)
  local M = {}
  local MAX_LIMIT = 50
  -- Entity types that hold items, and how where_is calls them.
  local KIND = {container='chest', ['logistic-container']='chest', ['linked-container']='chest',
    ['infinity-container']='chest', ['temporary-container']='pod', lab='lab', ['assembling-machine']='machine', furnace='machine',
    ['rocket-silo']='machine', car='vehicle', ['cargo-wagon']='vehicle', ['spider-vehicle']='vehicle',
    ['cargo-landing-pad']='pad', ['space-platform-hub']='hub', roboport='roboport'}
  local BELTS = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'linked-belt'}
  local TYPES = {}
  for t in pairs(KIND) do TYPES[#TYPES+1] = t end
  table.sort(TYPES)
  local function count_in(e, item)
    local ok, n = pcall(function() return e.get_item_count(item) end)
    return ok and type(n) == 'number' and n or 0
  end
  -- How many of a spoilable item in an entity's inventories spoil within `ticks` (d17 batch12 C7, Grok: yumako mash read
  -- 559, then 167 minutes later; a total read as a reserve): each stack's own spoil tick.
  M.SOON_TICKS, M.SOON_PLACES = 7200, 400
  function M.spoils_soon(e, item, ticks)
    local n = 0
    local max = (pcall(function() return e.get_max_inventory_index() end)) and e.get_max_inventory_index() or 0
    for i = 1, max do
      local inv = (pcall(function() return e.get_inventory(i) end)) and e.get_inventory(i) or nil
      if inv then
        for k = 1, #inv do
          local st = inv[k]
          if st.valid_for_read and st.name == item then
            local ok, t = pcall(function() return st.spoil_tick end)
            if ok and type(t) == 'number' and t > 0 and t - game.tick <= ticks then n = n + st.count end
          end
        end
      end
    end
    return n
  end
  -- (d17 batch14 B2, Sol: a cargo pad's overflow spilled landed hardware and where_is and stock read 0) an item's stacks
  -- lying on the ground, as a player sees them: in chunks our force sees now. {count, stacks, cells [{position (the
  -- cell's first stack), count, stacks}] by 32-tile cell, most first}; MAX_GROUND stacks read.
  M.MAX_GROUND = 20000
  function M.on_ground(force, surface, item)
    local list = surface.find_entities_filtered{type='item-entity', limit=M.MAX_GROUND}
    local seen, cells, order, count, stacks = {}, {}, {}, 0, 0
    for _, e in ipairs(list) do
      local ok, st = pcall(function() return e.stack end)
      if ok and st and st.valid_for_read and st.name == item then
        local q = e.position
        local cx, cy = math.floor(q.x / 32), math.floor(q.y / 32)
        local k = cx .. ',' .. cy
        if seen[k] == nil then
          local okv, v = pcall(function() return force.is_chunk_visible(surface, {x=cx, y=cy}) end)
          seen[k] = okv and v == true
        end
        if seen[k] then
          count, stacks = count + st.count, stacks + 1
          local c = cells[k]
          if not c then c = {position={x=q.x, y=q.y}, count=0, stacks=0}; cells[k] = c; order[#order+1] = c end
          c.count, c.stacks = c.count + st.count, c.stacks + 1
        end
      end
    end
    table.sort(order, function(x, y) return x.count > y.count end)
    return {count=count, stacks=stacks, cells=order, capped=#list >= M.MAX_GROUND or nil}
  end
  -- (d17 batch33 B1, Grok 09:22: the last pentapod eggs were in an inserter's hand, then a robot's cargo, while where_is
  -- read 0) what our logistic and construction robots on a surface carry of an item: each logistic network's robots'
  -- cargo, at most MAX_ROBOTS robots read a call. Returns count, robots carrying it, robots read, capped.
  -- (world n, 11:15: about 1 us a robot after the ~3 ms list build: 2048 read 4.7 ms)
  M.MAX_ROBOTS = 4096
  function M.robot_cargo(force, surface, item)
    local n, carrying, read, capped = 0, 0, 0, false
    local cargo = defines.inventory.robot_cargo
    for _, ln in ipairs((force.logistic_networks or {})[surface.name] or {}) do
      for _, list in ipairs({'logistic_robots', 'construction_robots'}) do
        local ok, robots = pcall(function() return ln[list] end)
        for _, r in ipairs(ok and robots or {}) do
          if read >= M.MAX_ROBOTS then capped = true; break end
          read = read + 1
          local okc, k = pcall(function() return r.get_inventory(cargo).get_item_count(item) end)
          if okc and type(k) == 'number' and k > 0 then n = n + k; carrying = carrying + 1 end
        end
      end
    end
    return n, carrying, read, capped
  end
  function M.where_is(p, a)
    local item = a.item
    assert(type(item) == 'string' and item ~= '', 'item is required (an item name, e.g. automation-science-pack)')
    local ok_proto, known = pcall(function() return prototypes.item[item] ~= nil end)
    assert(not ok_proto or known, 'unknown item ' .. item)
    local limit = a.limit or 15
    assert(type(limit) == 'number' and limit >= 1 and limit <= MAX_LIMIT, 'limit must be 1..' .. MAX_LIMIT)
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface or platform surface name')
      surface = game.get_surface and game.get_surface(a.surface) or nil
      assert(surface, 'unknown surface ' .. a.surface)
    end
    local here = (surface == p.surface) and p.position or nil
    local function dist(pos)
      if not (here and pos) then return nil end
      return math.floor(math.sqrt((pos.x - here.x) ^ 2 + (pos.y - here.y) ^ 2) + 0.5)
    end
    local places, totals = {}, {}
    local function add(kind, n)
      totals[kind] = (totals[kind] or 0) + n
    end
    for _, e in ipairs(surface.find_entities_filtered{force=p.force, type=TYPES}) do
      local n = count_in(e, item)
      if n > 0 then
        local kind = KIND[e.type] or 'other'
        add(kind, n)
        places[#places+1] = {kind=kind, entity=e.name, position={x=e.position.x, y=e.position.y}, count=n,
          distance=dist(e.position)}
      end
    end
    -- Landed cargo pods of any force (batch28 B3, Muse: unclaimed cargo with no positions), each once.
    local seen_pod = {}
    for _, pl in ipairs(places) do seen_pod[pl.entity .. '@' .. pl.position.x .. ',' .. pl.position.y] = true end
    for _, e in ipairs(surface.find_entities_filtered{name='cargo-pod-container'}) do
      local n = count_in(e, item)
      if n > 0 and not seen_pod[e.name .. '@' .. e.position.x .. ',' .. e.position.y] then
        add('pod', n)
        places[#places+1] = {kind='pod', entity=e.name, position={x=e.position.x, y=e.position.y}, count=n, distance=dist(e.position)}
      end
    end
    -- Belts and inserter hands: totals only (thousands of segments).
    local on_belts = 0
    for _, e in ipairs(surface.find_entities_filtered{force=p.force, type=BELTS}) do
      local ok, lines = pcall(function() return e.get_max_transport_line_index() end)
      for i = 1, ok and lines or 0 do
        local ok2, n = pcall(function() return e.get_transport_line(i).get_item_count(item) end)
        if ok2 and type(n) == 'number' then on_belts = on_belts + n end
      end
    end
    if on_belts > 0 then add('belts', on_belts) end
    local held = 0
    for _, e in ipairs(surface.find_entities_filtered{force=p.force, type='inserter'}) do
      local ok, n = pcall(function()
        local s = e.held_stack
        return s and s.valid_for_read and s.name == item and s.count or 0
      end)
      if ok and type(n) == 'number' then held = held + n end
    end
    if held > 0 then add('inserter_hands', held) end
    local okr, robot_n, carriers, robots_read, capped = pcall(M.robot_cargo, p.force, surface, item)
    if okr and robot_n > 0 then add('robot_cargo', robot_n) end
    local robot_note = okr and capped and string.format('robot cargo: the first %d robots read', robots_read) or nil
    -- The team's characters on this surface, by agent name.
    for _, ag in ipairs(api.agents()) do
      local c = api.character(ag.index)
      if c and c.valid and c.surface == surface then
        local n = count_in(c, item)
        if n > 0 then
          add('characters', n)
          places[#places+1] = {kind='character', agent=ag.name, position={x=c.position.x, y=c.position.y}, count=n,
            distance=dist(c.position)}
        end
      end
    end
    table.sort(places, function(x, y)
      if x.distance and y.distance and x.distance ~= y.distance then return x.distance < y.distance end
      if x.count ~= y.count then return x.count > y.count end
      return x.position.x < y.position.x
    end)
    -- Cargo pods from our platforms still in the air toward this surface (pods.lua; Grok, shift13: 519 packs were in
    -- the air while where_is and the pad showed none): each with its platform, state, count and where it lands.
    local flying = {}
    for _, r in ipairs(api.pods and api.pods.in_flight(p.force.name, surface.name) or {}) do
      local n = 0
      for k, v in pairs(r.items) do if k == item or k:match('^([^@]+)') == item then n = n + v end end
      if n > 0 then
        add('in_flight', n)
        flying[#flying+1] = {platform=r.platform, state=r.state, count=n,
          lands=r.pad and string.format('landing pad (%g,%g)', r.pad.x, r.pad.y) or 'the ground (no pad takes it)'}
      end
    end
    -- on the ground (B2): a place per 32-tile cell
    local okg, g = pcall(M.on_ground, p.force, surface, item)
    if okg and g.count > 0 then
      add('on_ground', g.count)
      for _, c in ipairs(g.cells) do
        places[#places+1] = {kind='ground', entity=string.format('%d stack%s on the ground', c.stacks, c.stacks == 1 and '' or 's'), position=c.position, count=c.count,
          distance=dist(c.position)}
      end
      table.sort(places, function(x, y)
        if x.distance and y.distance and x.distance ~= y.distance then return x.distance < y.distance end
        if x.count ~= y.count then return x.count > y.count end
        return x.position.x < y.position.x
      end)
    end
    local total = 0
    for _, n in pairs(totals) do total = total + n end
    -- A spoilable item: what of it spoils within 2 minutes in the places read (the first SOON_PLACES, the most held first).
    local soon
    local spoils = pcall(function() return prototypes.item[item].get_spoil_ticks() end) and prototypes.item[item].get_spoil_ticks() > 0
    if spoils then
      local order = {}
      for _, e in ipairs(places) do order[#order+1] = e end
      table.sort(order, function(x, y) return x.count > y.count end)
      soon = 0
      local ents = {}
      for _, e in ipairs(surface.find_entities_filtered{force=p.force, type=TYPES}) do ents[e.position.x .. ',' .. e.position.y .. e.name] = e end
      for i, pl in ipairs(order) do
        if i > M.SOON_PLACES then break end
        local e = pl.entity and ents[pl.position.x .. ',' .. pl.position.y .. pl.entity]
        if e then local n = M.spoils_soon(e, item, M.SOON_TICKS); soon = soon + n; if n > 0 then pl.spoils_within_2_min = n end end
      end
    end
    local out = {item=item, surface=surface.name, total=total, by_kind=totals, places={}, more=0, in_flight=#flying > 0 and flying or nil,
      spoils_within_2_min=soon, spoil_note=soon and string.format('%d of the %d spoil within 2 minutes (chests, machines and the like; belts, hands and robot cargo not read)', soon, total) or nil,
      robot_cargo=okr and robot_n > 0 and string.format('%d carried by %d robot%s now', robot_n, carriers, carriers == 1 and '' or 's') or nil, robot_note=robot_note}
    for i, e in ipairs(places) do
      if i <= limit then out.places[i] = e else out.more = out.more + 1 end
    end
    if out.more == 0 then out.more = nil end
    if total == 0 then out.note = 'none on this surface (surface=NAME looks on another planet or platform)' end
    return out
  end
  M.schema = {
    where_is = {item='item name', limit='1..50 places (default 15)', surface='optional surface name (default yours)',
      returns='total and by_kind (a spoilable item: spoils_within_2_min and spoil_note, each place its own spoils_within_2_min; chest, lab, machine, vehicle, pad, hub, roboport, pod (a landed cargo pod\'s container, of any force), belts, inserter_hands, robot_cargo (what our logistic and construction robots carry now, up to 4096 robots read: robot_note when capped), characters, in_flight, on_ground: stacks lying on the ground in chunks our force sees now); places: each chest, lab, machine, vehicle, pad, hub and teammate holding it {kind, entity or agent, position, count, distance} (kind ground: the stacks on the ground in one 32-tile cell, entity says how many), nearest first (belts and inserter hands as totals only); more: places past the limit; in_flight: cargo pods from our platforms still in the air toward this surface {platform, state (awaiting_launch, ascending, descending, parking), count, lands}. Read only'},
  }
  return M
end
