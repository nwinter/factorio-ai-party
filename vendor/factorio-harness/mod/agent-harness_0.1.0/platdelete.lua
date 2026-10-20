-- platform_delete {platform, dry_run?, confirm?, cancel?} (d20 batch54 N7, Astra #1405: Bastion was being stripped for
-- retirement; the platform GUI deletes a platform and fh had no action). What the game does, read on the private copy
-- (2.0.77): LuaSpacePlatform.destroy() schedules the deletion 18000 ticks (5 min) ahead and counts down
-- (scheduled_for_deletion); cancel_deletion() sets it back to 0; when it runs out the platform's surface goes with
-- everything on it: the hub and its cargo, the entities and the foundation; a character standing aboard was destroyed
-- with it. What becomes of cargo pods on their way to it was not checked. The dry run lists what would go; a platform
-- that is not empty (hub cargo, entities besides the hub, pods on their way) or is occupied (a character aboard) is
-- refused unless confirm is its name. Nothing is deleted on its own.
return function(api)
  local M = {}
  local LIST = 200   -- entities listed by name up to this many; past it, counted
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function contents_text(inv)
    local parts, n = {}, 0
    for _, s in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local q = s.quality and (type(s.quality) == 'table' and s.quality.name or s.quality) or 'normal'
      parts[#parts+1] = s.name .. (q ~= 'normal' and '@' .. q or '') .. '*' .. s.count
      n = n + s.count
    end
    table.sort(parts)
    return n, parts
  end
  -- What would go with the platform: {hub_cargo, entities, ghosts, foundation_tiles, characters, pods, scheduled, empty, occupied, lines}.
  function M.read(pl)
    local s, hub = pl.surface, pl.hub
    local out = {lines={}}
    local cargo_n, cargo = 0, {}
    if hub and hub.valid then
      for _, id in ipairs({'hub_main', 'hub_trash'}) do
        local inv = defines.inventory[id] and try(function() return hub.get_inventory(defines.inventory[id]) end)
        local n, parts = contents_text(inv)
        cargo_n = cargo_n + n
        for _, x in ipairs(parts) do cargo[#cargo+1] = (id == 'hub_trash' and 'trash ' or '') .. x end
      end
    end
    out.hub_cargo = cargo_n > 0 and table.concat(cargo, ' ') or 'empty'
    -- the entities besides the hub (any force), ghosts apart; by name when there are few
    local total = s and try(function() return s.count_entities_filtered{} end) or 0
    local ghosts = s and try(function() return s.count_entities_filtered{type={'entity-ghost', 'tile-ghost'}} end) or 0
    local chars = s and try(function() return s.find_entities_filtered{type='character'} end) or {}
    local pods_here = s and try(function() return s.count_entities_filtered{type='cargo-pod'} end) or 0
    local built = math.max(0, total - ghosts - #chars - pods_here - ((hub and hub.valid) and 1 or 0))
    local names
    if built > 0 and built <= LIST then
      local by = {}
      -- (the private copy: Swift's 253 such of 480, with the counts and the foundation, read in 2.4 ms)
      for _, e in ipairs(try(function() return s.find_entities_filtered{type={'entity-ghost', 'tile-ghost', 'character', 'cargo-pod'}, invert=true} end) or {}) do
        if e.valid and e ~= hub then
          by[e.name] = (by[e.name] or 0) + 1
        end
      end
      names = {}
      for n, c in pairs(by) do names[#names+1] = n .. '*' .. c end
      table.sort(names)
    end
    out.entities = built
    out.entity_names = names and table.concat(names, ' ') or nil
    out.ghosts = ghosts
    out.foundation_tiles = s and try(function() return s.count_tiles_filtered{name='space-platform-foundation'} end) or 0
    local who = {}
    for _, c in ipairs(chars) do
      local name = api.character_owner and try(function() return api.character_owner(c) end) or nil
      who[#who+1] = string.format('%s at %s', name or ('character ' .. tostring(c.unit_number)), at(c.position))
    end
    out.characters = #who > 0 and who or nil
    local inc = api.incoming and try(function() return api.incoming(pl) end)
    out.pods = inc and inc.rockets > 0 and inc.lines or nil
    out.pods_on_platform = pods_here > 0 and pods_here or nil
    out.scheduled = (try(function() return pl.scheduled_for_deletion end) or 0) > 0 and pl.scheduled_for_deletion or nil
    out.empty = cargo_n == 0 and built == 0 and not out.pods and pods_here == 0
    out.occupied = #who > 0
    local L = out.lines
    L[#L+1] = 'hub cargo: ' .. out.hub_cargo
    L[#L+1] = string.format('entities besides the hub: %d%s; ghosts %d; foundation tiles %d', built,
      out.entity_names and ' (' .. out.entity_names .. ')' or '', ghosts, out.foundation_tiles)
    L[#L+1] = 'characters aboard: ' .. (#who > 0 and table.concat(who, '; ') or 'none')
    L[#L+1] = 'cargo pods on their way: ' .. (out.pods and table.concat(out.pods, '; ') or 'none') .. (pods_here > 0 and string.format('; %d on the platform now', pods_here) or '')
    if out.scheduled then L[#L+1] = string.format('scheduled for deletion: in %ds (tick %d)', math.floor(out.scheduled / 60), game.tick + out.scheduled) end
    return out
  end
  local WHAT = 'when the deletion runs the platform\'s surface goes with everything on it (the hub and its cargo, the entities, the foundation); a character standing aboard goes with it'
  function M.handler(p, a)
    assert(type(a.platform) == 'string', 'platform is the platform\'s name')
    for _, k in ipairs({'dry_run', 'cancel'}) do assert(a[k] == nil or type(a[k]) == 'boolean', k .. ' is true or false') end
    assert(a.confirm == nil or type(a.confirm) == 'string', 'confirm is the platform\'s name')
    local pl = api.platform(p, a.platform)
    local r = M.read(pl)
    local out = {platform=pl.name, hub_cargo=r.hub_cargo, entities=r.entities, entity_names=r.entity_names, ghosts=r.ghosts,
      foundation_tiles=r.foundation_tiles, characters=r.characters, pods=r.pods, pods_on_platform=r.pods_on_platform,
      empty=r.empty, occupied=r.occupied, lines=r.lines}
    if a.cancel then
      assert(r.scheduled, pl.name .. ' is not scheduled for deletion')
      pl.cancel_deletion()
      out.cancelled = true
      out.line = string.format('%s: its deletion (due in %ds) cancelled', pl.name, math.floor(r.scheduled / 60))
      return out
    end
    local why = {}
    if not r.empty then
      local w = {}
      if r.hub_cargo ~= 'empty' then w[#w+1] = 'hub cargo' end
      if r.entities > 0 then w[#w+1] = r.entities .. ' entities besides the hub' end
      if r.pods or r.pods_on_platform then w[#w+1] = 'cargo pods on their way or on it' end
      why[#why+1] = 'not empty (' .. table.concat(w, ', ') .. ')'
    end
    if r.occupied then why[#why+1] = 'occupied (' .. table.concat(r.characters, '; ') .. ')' end
    if a.dry_run then
      out.dry_run = true
      out.line = string.format('%s: %s; %s', pl.name, #why > 0 and ('would be refused without confirm: ' .. table.concat(why, '; '))
        or 'empty and unoccupied: platform_delete deletes it', WHAT)
      if r.scheduled then out.line = out.line .. string.format('; already scheduled for deletion in %ds', math.floor(r.scheduled / 60)) end
      return out
    end
    if r.scheduled then
      error(string.format('%s is scheduled for deletion already, in %ds (tick %d); cancel: true cancels it', pl.name, math.floor(r.scheduled / 60), game.tick + r.scheduled), 0)
    end
    if #why > 0 and a.confirm ~= pl.name then
      error(string.format('%s is %s; nothing deleted; confirm: "%s" deletes it with them (%s)', pl.name, table.concat(why, '; '), pl.name, WHAT), 0)
    end
    pl.destroy()
    local left = try(function() return pl.scheduled_for_deletion end) or 0
    out.scheduled_ticks = left
    out.due_tick = game.tick + left
    out.line = string.format('%s: scheduled for deletion in %ds (tick %d), the game\'s own delay; cancel: true cancels it before then; %s',
      pl.name, math.floor(left / 60), game.tick + left, WHAT)
    if api.event then pcall(api.event, 'platform_delete', {platform=pl.name, by=api.who and api.who(p) or nil, due_tick=game.tick + left}) end
    return out
  end
  M.schema = {platform_delete = {platform='the platform\'s name', dry_run='optional true: a read: what would go (hub cargo, entities besides the hub, ghosts, foundation tiles, characters aboard, cargo pods on their way) and whether the call would be refused',
    confirm='the platform\'s name: deletes one that is not empty (hub cargo, entities besides the hub, cargo pods on their way) or occupied (a character aboard); without it such a platform is refused',
    cancel='optional true: cancels a scheduled deletion',
    returns='hub_cargo, entities, entity_names (up to 200), ghosts, foundation_tiles, characters, pods, empty, occupied, lines, line; deleting: scheduled_ticks and due_tick (the game schedules a deletion 5 min ahead; when it runs the platform\'s surface goes with everything on it, a character aboard included); cancelled'}}
  return M
end
