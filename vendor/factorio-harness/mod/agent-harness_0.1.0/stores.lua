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
    local total = 0
    for _, n in pairs(totals) do total = total + n end
    local out = {item=item, surface=surface.name, total=total, by_kind=totals, places={}, more=0, in_flight=#flying > 0 and flying or nil}
    for i, e in ipairs(places) do
      if i <= limit then out.places[i] = e else out.more = out.more + 1 end
    end
    if out.more == 0 then out.more = nil end
    if total == 0 then out.note = 'none on this surface (surface=NAME looks on another planet or platform)' end
    return out
  end
  M.schema = {
    where_is = {item='item name', limit='1..50 places (default 15)', surface='optional surface name (default yours)',
      returns='total and by_kind (chest, lab, machine, vehicle, pad, hub, roboport, belts, inserter_hands, characters, in_flight); places: each chest, lab, machine, vehicle, pad, hub and teammate holding it {kind, entity or agent, position, count, distance}, nearest first (belts and inserter hands as totals only); more: places past the limit; in_flight: cargo pods from our platforms still in the air toward this surface {platform, state (awaiting_launch, ascending, descending, parking), count, lands}. Read only'},
  }
  return M
end
