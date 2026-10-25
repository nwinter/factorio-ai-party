-- platform_rearm {platform, positions?, item?, ammo_below, target_count} (batch24 A3, Sol request940: a helper refilled
-- two wing guns and two rocket turrets every 30 s for two hours; 100 magazines can go in under 80 s): each named turret
-- (or every ammo turret aboard) holding under ammo_below of its ammunition, counting what is on the way to it already
-- (its item request), gets an item request for the rest up to target_count, filled from the hub as deliver's are. A
-- queue step in the platform's lane (lane platform:NAME, or remote); queue_repeat with interval_ticks runs it as a
-- standing top-up. Requests made are counted per platform (refills since).
return function(api)
  local M = {}
  -- (d25 batch208 QU1) the most a call takes, also a queue step's check (runtime.lua step_lengths)
  M.POSITIONS = 32
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function store(name)
    local s = api.state()
    s.platform_rearm = s.platform_rearm or {}
    s.platform_rearm[name] = s.platform_rearm[name] or {since=game.tick, requests=0, items=0}
    return s.platform_rearm[name]
  end
  -- What an item request on e already brings of item into its ammo slots.
  local function on_the_way(e, item)
    local proxy = try(function() return e.item_request_proxy end)
    if not (proxy and proxy.valid) then return 0 end
    local n = 0
    for _, plan in ipairs(try(function() return proxy.insert_plan end) or {}) do
      local id = plan.id or {}
      local name = type(id.name) == 'string' and id.name or (id.name and id.name.name)
      if name == item then
        for _, row in ipairs(plan.items and plan.items.in_inventory or {}) do
          if row.inventory == defines.inventory.turret_ammo then n = n + (row.count or 1) end
        end
      end
    end
    return n
  end
  -- The ammunition a turret holds now (the most of one name), else nil.
  local function held_ammo(inv)
    local best, bn
    for _, c in ipairs(try(function() return inv.get_contents() end) or {}) do
      if not bn or c.count > bn then best, bn = c.name, c.count end
    end
    return best
  end
  function M.handler(p, a)
    assert(type(a.platform) == 'string' and a.platform ~= '', 'platform: the platform\'s name')
    local below, target = a.ammo_below, a.target_count
    assert(type(below) == 'number' and below >= 1 and below <= 10000 and below == math.floor(below), 'ammo_below: 1..10000 (a turret holding fewer is topped up)')
    assert(type(target) == 'number' and target >= below and target <= 10000 and target == math.floor(target), 'target_count: ammo_below..10000 (what each turret is topped up to)')
    if a.item ~= nil then
      assert(type(a.item) == 'string' and prototypes.item[a.item] and prototypes.item[a.item].type == 'ammo', 'item: an ammunition name')
    end
    local q = api.on_platform(p, a.platform)
    local surface = q.surface
    local pl = surface.platform
    local hub = pl and pl.hub
    local hub_inv = hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local turrets = {}
    if a.positions ~= nil then
      assert(type(a.positions) == 'table' and #a.positions >= 1 and #a.positions <= M.POSITIONS, 'positions: 1..' .. M.POSITIONS .. ' turret positions {x,y}')
      for _, pos in ipairs(a.positions) do
        local ok, e = pcall(api.remote_entity, q, {position=pos})
        if not ok then turrets[#turrets+1] = {position=pos, error=tostring(e):gsub('^[^:]*:%d+: ', '')}
        elseif e.type ~= 'ammo-turret' then turrets[#turrets+1] = {position=pos, error=e.name .. ' at ' .. at(e.position) .. ' is not an ammo turret'}
        else turrets[#turrets+1] = {entity=e} end
      end
    else
      for _, e in ipairs(surface.find_entities_filtered{type='ammo-turret', force=p.force, limit=256}) do turrets[#turrets+1] = {entity=e} end
      table.sort(turrets, function(x, y) local u, v = x.entity.position, y.entity.position; if u.y ~= v.y then return u.y < v.y end return u.x < v.x end)
    end
    -- (d19 batch41 A2, Sol seq 868: firearm-magazine requested of 5 railgun and 6 rocket turrets on Bastion) the ammunition
    -- each turret kind takes: an item no named turret takes is refused with each kind and its items; with no positions,
    -- the turrets aboard that do not take it are left out and named.
    local kinds, order = {}, {}
    for _, t in ipairs(turrets) do
      local e = t.entity
      if e and not kinds[e.name] then
        local tk = api.takes and try(function() return api.takes(e.prototype) end)
        -- a kind whose ammunition is unknown (no prototype read) takes any
        local fits = tk and {} or setmetatable({}, {__index=function() return true end})
        for _, n in ipairs(tk and tk.items or {}) do fits[n] = true end
        kinds[e.name] = {n=0, items=tk and tk.items or {}, fits=fits}; order[#order+1] = e.name
      end
      if e then kinds[e.name].n = kinds[e.name].n + 1 end
    end
    local left_out
    if a.item ~= nil then
      local bad = {}
      for _, name in ipairs(order) do
        local k = kinds[name]
        if not k.fits[a.item] then bad[#bad+1] = string.format('%s (%d) takes %s', name, k.n, #k.items > 0 and table.concat(k.items, ', ') or 'no ammunition item') end
      end
      local any = false
      for _, name in ipairs(order) do if kinds[name].fits[a.item] then any = true end end
      if #bad > 0 and (a.positions ~= nil or not any) then
        error(string.format('item %s: not taken by %s', a.item, table.concat(bad, '; ')), 0)
      end
      if #bad > 0 then left_out = string.format('left out, not taking %s: %s', a.item, table.concat(bad, '; ')) end
    end
    local st = store(pl and pl.name or a.platform)
    local rows, asked, items, wanted = {}, 0, 0, {}
    for _, t in ipairs(turrets) do
      local e = t.entity
      if e and a.item ~= nil and not kinds[e.name].fits[a.item] then e = nil end
      if not e then if t.error then rows[#rows+1] = {position=t.position, error=t.error} end
      else
        local inv = e.get_inventory(defines.inventory.turret_ammo)
        local item = a.item or held_ammo(inv)
        local row = {name=e.name, position=e.position}
        -- a request already on it for ammunition it does not take (configure {position, item_requests: false} removes it)
        row.unusable_request = api.unusable and try(function() return api.unusable(e) end) or nil
        if not item then
          row.note = 'empty, and no item named: item names the ammunition'
        else
          local have = inv.get_item_count(item)
          local coming = on_the_way(e, item)
          row.item, row.held, row.on_the_way = item, have, coming > 0 and coming or nil
          if have + coming < below then
            local want = target - have - coming
            local ok, r = pcall(api.deliver_one, p, e, {[item]=want})
            if ok and r.requested then
              row.requested = want
              asked = asked + 1; items = items + want
              wanted[item] = (wanted[item] or 0) + want
            else row.refused = ok and table.concat(r.refused or {}, '; ') or tostring(r):gsub('^[^:]*:%d+: ', '') end
          end
        end
        rows[#rows+1] = row
      end
    end
    st.requests = st.requests + asked; st.items = st.items + items
    local hub_lines = {}
    for item, n in pairs(wanted) do
      local h = hub_inv and hub_inv.get_item_count(item) or 0
      hub_lines[#hub_lines+1] = string.format('the hub holds %d %s%s', h, item, h < n and string.format(' (fewer than the %d asked: the rest waits for more in the hub)', n) or '')
    end
    table.sort(hub_lines)
    return {platform=pl and pl.name or a.platform, turrets=#rows, requested=asked, rows=rows, hub=#hub_lines > 0 and hub_lines or nil, left_out=left_out,
      refills=string.format('%d item requests (%d rounds) since tick %d', st.requests, st.items, st.since),
      line=string.format('%d of %d turrets under %d: topped up to %d (%d rounds asked from the hub)', asked, #rows, below, target, items)}
  end
  M.schema = {platform_rearm = {platform='platform name', positions='optional 1..32 turret positions (platform coordinates); default every ammo turret aboard',
    item='optional ammunition name (default: what each turret holds now); refused when a named turret does not take it; with no positions the turrets aboard that do not take it are left out (left_out names them)', ammo_below='1..10000: a turret holding fewer of it, counting what is on the way, is topped up',
    target_count='ammo_below..10000: what it is topped up to',
    returns='turrets, requested (how many got an item request), rows [{name, position, item, held, on_the_way (an item request not yet filled), requested, refused, unusable_request (a request on it for ammunition it does not take; configure item_requests: false removes it), note, error}], left_out, hub (what the hub holds of each item asked), refills (requests and rounds asked on this platform since), line. Item requests the hub fills, as deliver\'s; no body. A platform lane step (lane platform:NAME or remote); queue_repeat with interval_ticks keeps topping up'}}
  return M
end
