-- Facts beside a reminder's gear gap (d22 batch94 BD1, viewer Aurora site:4268 on #114: "require live research and
-- stock checks before claiming gear is unavailable"). For an item a recipient names in reminder_ack gap_items, read
-- when the reminder is read, as a player sees them: the recipes that make it (hidden ones, recycling, left out) and
-- whether each is enabled (the crafting menu), the technologies that unlock them and whether each is researched (the research screen), how many are in the
-- logistic networks of the recipient's surface by quality (a network's GUI), on a platform in its hub, and in the
-- recipient's own inventory. Facts only: an agent's claim is never refused.
-- Also: which equipment and armor items a technology unlocks (reminders' on.research "equipment") and whether an item
-- is gear (on.delivered "equipment"), and the recipient's own armor read for reminder_ack gear.
return function(api)
  local M = {}
  local MAX_ITEMS = 8
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- Equipment (it goes in a grid) or armor (it has a grid or goes in the armor slot).
  local gear_cache = {}
  function M.is_gear(name)
    if gear_cache[name] ~= nil then return gear_cache[name] end
    local it = try(function() return prototypes.item[name] end)
    local yes = it ~= nil and (try(function() return it.place_as_equipment_result end) ~= nil or try(function() return it.type end) == 'armor')
    gear_cache[name] = yes
    return yes
  end
  function M.check_items(list)
    if type(list) == 'string' then list = {list} end
    assert(type(list) == 'table' and #list >= 1 and #list <= MAX_ITEMS, 'gap_items: 1..' .. MAX_ITEMS .. ' item names')
    local out, seen = {}, {}
    for _, n in ipairs(list) do
      assert(type(n) == 'string', 'gap_items are item names')
      assert(try(function() return prototypes.item[n] end), 'gap_items: no item ' .. n)
      if not seen[n] then seen[n] = true; out[#out+1] = n end
    end
    return out
  end
  function M.item_known(n) return type(n) == 'string' and try(function() return prototypes.item[n] end) ~= nil end
  function M.technology_known(n) return type(n) == 'string' and try(function() return prototypes.technology[n] end) ~= nil end
  -- recipe name -> technologies whose effects unlock it (built once a load: every technology's effects)
  local unlockers
  local function by_recipe()
    if unlockers then return unlockers end
    unlockers = {}
    for tname, t in pairs(prototypes.technology) do
      for _, e in ipairs(try(function() return t.effects end) or {}) do
        if e.type == 'unlock-recipe' and e.recipe then
          unlockers[e.recipe] = unlockers[e.recipe] or {}
          table.insert(unlockers[e.recipe], tname)
        end
      end
    end
    for _, list in pairs(unlockers) do table.sort(list) end
    return unlockers
  end
  -- (d26 batch249 R11) the technologies that unlock a recipe (nil: none)
  function M.unlocked_by(recipe) return by_recipe()[recipe] end
  -- The gear items a technology's recipes make, as text (nil: none).
  function M.unlocks_gear(tech)
    local made, seen = {}, {}
    for _, e in ipairs(try(function() return tech.prototype.effects end) or try(function() return tech.effects end) or {}) do
      if e.type == 'unlock-recipe' and e.recipe then
        for _, pr in ipairs(try(function() return prototypes.recipe[e.recipe].products end) or {}) do
          if pr.type == 'item' and pr.name and not seen[pr.name] and M.is_gear(pr.name) then seen[pr.name] = true; made[#made+1] = pr.name end
        end
      end
    end
    table.sort(made)
    return #made > 0 and table.concat(made, ', ') or nil
  end
  local function qualities()
    local out = {}
    for name in pairs(try(function() return prototypes.quality end) or {}) do
      if name ~= 'quality-unknown' then out[#out+1] = name end
    end
    table.sort(out)
    return #out > 0 and out or {'normal'}
  end
  local function count_in(get, item, qs, into)
    local total = 0
    for _, q in ipairs(qs) do
      local n = try(function() return get({name=item, quality=q}) end) or 0
      if n > 0 then into[q] = (into[q] or 0) + n; total = total + n end
    end
    return total
  end
  local function by_quality_text(t)
    local parts = {}
    for q, n in pairs(t) do parts[#parts+1] = {q=q, n=n} end
    table.sort(parts, function(a, b) return a.q == 'normal' or (b.q ~= 'normal' and a.q < b.q) end)
    local out = {}
    for i, x in ipairs(parts) do out[i] = x.q == 'normal' and tostring(x.n) or x.n .. ' ' .. x.q end
    return table.concat(out, ', ')
  end
  -- facts(p, items): rows {item, recipes [{name, enabled}], technologies [{name, researched}], surface, networks,
  -- in_networks {quality: count}, in_hub, held, line}
  function M.facts(p, items)
    local rows = {}
    local c = try(function() return p.character end)
    local force = try(function() return p.force end)
    local surface = c and try(function() return c.surface end) or try(function() return p.surface end)
    local sname = surface and try(function() return surface.name end)
    local nets = force and sname and try(function() return force.logistic_networks[sname] end) or {}
    local hub = surface and try(function() return surface.platform and surface.platform.hub end)
    local main = try(function() return p.get_main_inventory() end)
    local qs = qualities()
    local map = by_recipe()
    for _, item in ipairs(items) do
      local r = {item=item, surface=sname, networks=#nets, recipes={}, technologies={}, in_networks={}}
      local recs = try(function() return prototypes.get_recipe_filtered{{filter='has-product-item', elem_filters={{filter='name', name=item}}}} end) or {}
      local seen_t = {}
      for rname, rp in pairs(recs) do
        -- hidden recipes (recycling) are not in the crafting menu
        if not try(function() return rp.hidden end) then
        local fr = force and try(function() return force.recipes[rname] end)
        r.recipes[#r.recipes+1] = {name=rname, enabled=fr and try(function() return fr.enabled end) or false}
        for _, t in ipairs(map[rname] or {}) do
          if not seen_t[t] then
            seen_t[t] = true
            local ft = force and try(function() return force.technologies[t] end)
            r.technologies[#r.technologies+1] = {name=t, researched=ft and try(function() return ft.researched end) or false}
          end
        end
        end
      end
      table.sort(r.recipes, function(a, b) return a.name < b.name end)
      table.sort(r.technologies, function(a, b) return a.name < b.name end)
      local n_net = 0
      for _, net in ipairs(nets) do n_net = n_net + count_in(function(x) return net.get_item_count(x) end, item, qs, r.in_networks) end
      if hub then
        local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
        local t = {}
        if inv and count_in(function(x) return inv.get_item_count(x) end, item, qs, t) > 0 then r.in_hub = t end
      end
      local held = {}
      if main and count_in(function(x) return main.get_item_count(x) end, item, qs, held) > 0 then r.held = held end
      local parts = {}
      if #r.recipes == 0 then parts[#parts+1] = 'no recipe makes it'
      else
        local rp = {}
        for i, x in ipairs(r.recipes) do rp[i] = x.name .. (x.enabled and ' enabled' or ' not enabled') end
        parts[#parts+1] = 'recipe ' .. table.concat(rp, ', ')
      end
      if #r.technologies > 0 then
        local tp = {}
        for i, x in ipairs(r.technologies) do tp[i] = x.name .. (x.researched and ' researched' or ' not researched') end
        parts[#parts+1] = 'technology ' .. table.concat(tp, ', ')
      end
      parts[#parts+1] = string.format('in %s\'s logistic networks: %s (%d network%s)', tostring(sname), n_net > 0 and by_quality_text(r.in_networks) or '0',
        #nets, #nets == 1 and '' or 's')
      if hub then parts[#parts+1] = 'in its hub: ' .. (r.in_hub and by_quality_text(r.in_hub) or '0') end
      parts[#parts+1] = 'held: ' .. (r.held and by_quality_text(r.held) or '0')
      r.line = item .. ': ' .. table.concat(parts, '; ')
      rows[#rows+1] = r
    end
    return rows
  end
  -- The recipient's own armor, as its armor GUI shows it: one line (reminder_ack gear).
  function M.gear_line(p, grids)
    local c = try(function() return p.character end)
    if not (c and try(function() return c.valid end)) then return 'no character (dead or not spawned)' end
    local armor = grids.armor(c)
    if not armor then return 'no armor worn' end
    local grid = try(function() return c.grid end)
    if not grid then return armor .. ': no equipment grid' end
    local v = grids.view(grid)
    return string.format('%s %s: %s; %d free cells%s%s', armor, v.grid, v.equipment, v.free_cells, v.shield and '; shield ' .. v.shield or '',
      v.battery_mj and '; battery ' .. v.battery_mj .. ' MJ' or '')
  end
  return M
end
