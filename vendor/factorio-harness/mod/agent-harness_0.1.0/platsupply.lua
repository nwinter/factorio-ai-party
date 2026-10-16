-- platform_supply {platform}: one read of a platform's supply chain (Sol, Astra 03:21-03:23: Petrel's first flight
-- starved of fuel after an exporter was repurposed and an underground side-load blocked a lane; about 20 reads by
-- hand). In the chain's order, each with what the GUI shows of it:
-- - asteroid collectors: chunks held, filters, status, the inserters taking from them and where they put the chunks,
--   and foundation ghosts in the open space in front (once built they break its tile rules);
-- - crushers: recipe, status, input and output held;
-- - fuel and oxidizer makers (thruster-fuel and thruster-oxidizer recipes): status and what they hold;
-- - thrusters: fuel and oxidizer in their tanks;
-- - each gun: rounds, and an empty one's feed (platalerts.lua turret_feed);
-- ghosts apart (by name), and the first stop in that order: a collector, crusher or maker not working, a thruster
-- short, or an empty gun. Read only.
return function(api)
  local M = {}
  local LIST = 12
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local statuses
  local function status(e)
    statuses = statuses or (function() local t = {} for k, v in pairs(defines.entity_status or {}) do t[v] = k end return t end)()
    local s = try(function() return e.status end)
    return s and statuses[s] or 'unknown'
  end
  local WORKING = {working=true, normal=true}
  local function contents_text(inv, limit)
    local list = inv and try(function() return inv.get_contents() end) or {}
    table.sort(list, function(a, b) return a.count > b.count end)
    local out = {}
    for i, s in ipairs(list) do if i > (limit or 4) then out[#out+1] = '+' .. (#list - i + 1) .. ' more'; break end; out[#out+1] = s.name .. '*' .. s.count end
    return #out > 0 and table.concat(out, ' ') or 'empty'
  end
  local function takers(s, e, force)
    local p0, b = e.position, e.bounding_box
    local area = {left_top={x=b.left_top.x - 3, y=b.left_top.y - 3}, right_bottom={x=b.right_bottom.x + 3, y=b.right_bottom.y + 3}}
    local out = {}
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', area=area, force=force} end) or {}) do
      if try(function() return i.pickup_target end) == e then
        local d = try(function() return i.drop_target end)
        out[#out+1] = string.format('%s %s into %s', i.name, at(i.position), d and d.valid and (d.name .. ' ' .. at(d.position)) or 'nothing (no drop target)')
      end
    end
    return out
  end
  local function recipe_of(e) return try(function() local r = e.get_recipe(); return r and r.name end) end
  function M.read(p, a)
    assert(type(a.platform) == 'string', 'platform is required (a platform name)')
    local pl = api.platform(p, a.platform)
    local s, force = pl.surface, pl.force
    local lines, first = {}, nil
    local function stop(text) first = first or text end
    -- Tile ghosts on the platform, for the collectors' open space.
    local tile_ghosts = {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='tile-ghost', limit=8192} end) or {}) do
      local tp = g.valid and prototypes.tile[g.ghost_name]
      if tp then tile_ghosts[math.floor(g.position.x) * 65536 + math.floor(g.position.y)] = {name=g.ghost_name, prototype=tp} end
    end
    local function find(t) return try(function() return s.find_entities_filtered{type=t, force=force} end) or {} end
    -- Collectors.
    local collectors = {}
    for _, c in ipairs(find('asteroid-collector')) do
      local inv = try(function() return c.get_inventory(defines.inventory.asteroid_collector_output) end)
      local filters = {}
      for i = 1, try(function() return c.filter_slot_count end) or 0 do
        local f = try(function() return c.get_filter(i) end)
        local n = f and (type(f) == 'string' and f or f.name)
        if n then filters[#filters+1] = n end
      end
      local st = status(c)
      local out = takers(s, c, force)
      local front = api.placewhy and try(function()
        return api.placewhy.tile_rules(s, c.prototype, c.position, c.direction, function(x, y) return tile_ghosts[x * 65536 + y] or s.get_tile(x, y) end)
      end)
      local row = string.format('collector %s: %s; holds %s; filters %s; %s', at(c.position), st, contents_text(inv), #filters > 0 and table.concat(filters, ', ') or 'none (takes every chunk)',
        #out > 0 and 'taken by ' .. table.concat(out, ', ') or 'no inserter takes from it')
      if front then row = row .. '; foundation ghosts in its open space: ' .. front end
      collectors[#collectors+1] = row
      if not WORKING[st] then stop(row) elseif #out == 0 then stop(row) elseif front then stop(row) end
    end
    lines[#lines+1] = #collectors > 0 and string.format('%d collector%s', #collectors, #collectors == 1 and '' or 's') or 'no asteroid collectors'
    for i, r in ipairs(collectors) do if i <= LIST then lines[#lines+1] = r end end
    -- Crushers and the fuel and oxidizer makers.
    local crushers, makers = {}, {}
    for _, e in ipairs(find('assembling-machine')) do
      local r = recipe_of(e)
      local cat = try(function() return e.prototype.crafting_categories end) or {}
      local st = status(e)
      local held = string.format('in %s, out %s', contents_text(try(function() return e.get_inventory(defines.inventory.crafter_input or defines.inventory.assembling_machine_input) end), 3),
        contents_text(try(function() return e.get_inventory(defines.inventory.crafter_output or defines.inventory.assembling_machine_output) end), 3))
      if cat.crushing then
        local row = string.format('crusher %s %s: %s; %s', at(e.position), r or 'no recipe', st, held)
        crushers[#crushers+1] = row
        if not WORKING[st] then stop(row) end
      elseif r and (r:find('thruster%-fuel') or r:find('thruster%-oxidizer')) then
        local fl = {}
        for i = 1, try(function() return #e.fluidbox end) or 0 do
          local f = try(function() return e.fluidbox[i] end)
          if f then fl[#fl+1] = string.format('%s %d', f.name, math.floor(f.amount)) end
        end
        local row = string.format('%s %s %s: %s; %s%s', e.name, at(e.position), r, st, held, #fl > 0 and '; fluids ' .. table.concat(fl, ', ') or '')
        makers[#makers+1] = row
        if not WORKING[st] then stop(row) end
      end
    end
    lines[#lines+1] = string.format('%d crusher%s', #crushers, #crushers == 1 and '' or 's')
    for i, r in ipairs(crushers) do if i <= LIST then lines[#lines+1] = r end end
    lines[#lines+1] = string.format('%d fuel and oxidizer maker%s', #makers, #makers == 1 and '' or 's')
    for i, r in ipairs(makers) do if i <= LIST then lines[#lines+1] = r end end
    -- Thrusters.
    local thr = api.thrust and try(function() return api.thrust(pl) end)
    if thr then
      lines[#lines+1] = string.format('%d thruster%s%s', thr.count or 0, (thr.count or 0) == 1 and '' or 's', #(thr.lines or {}) > 0 and ': ' .. table.concat(thr.lines, ' | ') or ': no thruster tank under half')
      if #(thr.lines or {}) > 0 then stop('thrusters: ' .. thr.lines[1]) end
    end
    -- Guns.
    local guns, empty = 0, 0
    local hub_ammo = {}
    for _, st in ipairs(pl.hub and pl.hub.valid and try(function() return pl.hub.get_inventory(defines.inventory.hub_main).get_contents() end) or {}) do
      if try(function() return prototypes.item[st.name].type end) == 'ammo' then hub_ammo[st.name] = (hub_ammo[st.name] or 0) + st.count end
    end
    local gun_rows = {}
    for _, t in ipairs(find('ammo-turret')) do
      guns = guns + 1
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      local n = inv and try(function() return inv.get_item_count() end) or 0
      if n == 0 then
        empty = empty + 1
        local row = string.format('%s %s empty: %s', t.name, at(t.position), api.turret_feed and try(function() return api.turret_feed(t) end) or '?')
        gun_rows[#gun_rows+1] = row
        stop(row)
      end
    end
    local hub_text = {}
    for n2, c2 in pairs(hub_ammo) do hub_text[#hub_text+1] = n2 .. '*' .. c2 end
    table.sort(hub_text)
    lines[#lines+1] = string.format('%d gun%s, %d empty; the hub holds %s', guns, guns == 1 and '' or 's', empty, #hub_text > 0 and table.concat(hub_text, ' ') or 'no ammo')
    for i, r in ipairs(gun_rows) do if i <= LIST then lines[#lines+1] = r end end
    -- Ghosts apart.
    local by = {}
    for _, g in ipairs(try(function() return s.find_entities_filtered{type='entity-ghost', limit=4096} end) or {}) do
      local n2 = try(function() return g.ghost_name end) or '?'
      by[n2] = (by[n2] or 0) + 1
    end
    local gl = {}
    for n2, c2 in pairs(by) do gl[#gl+1] = {n2, c2} end
    table.sort(gl, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
    for i, v in ipairs(gl) do gl[i] = v[2] .. ' ' .. v[1] end
    local nt = 0
    for _ in pairs(tile_ghosts) do nt = nt + 1 end
    lines[#lines+1] = 'ghosts: ' .. (#gl > 0 and table.concat(gl, ', ', 1, math.min(8, #gl)) or 'no entity ghosts') .. (nt > 0 and string.format('; %d tile ghosts', nt) or '')
    table.insert(lines, 1, 'first stop: ' .. (first or 'none: every collector, crusher and maker works, no thruster is short, no gun is empty'))
    return {platform=pl.name, first_stop=first, lines=lines}
  end
  M.schema = {platform_supply = {platform='platform name',
    returns='lines, in the chain\'s order: first stop (the first of these not working: a collector (not working, no inserter takes from it, or foundation ghosts in its open space), a crusher, a fuel or oxidizer maker, a thruster under half, an empty gun); collectors (status, chunks held, filters, the inserters taking from them and where they put the chunks); crushers (recipe, status, input and output); thruster-fuel and thruster-oxidizer makers (status, what they hold, fluids); thrusters; guns (an empty one with what feeds it); ghosts by name, apart. first_stop. Read only'}}
  return M
end
