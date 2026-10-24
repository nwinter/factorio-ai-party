-- outpost {area | position, radius}: one tour that puts a remote outpost back together (Opus, d15 15:20: the south copper
-- outpost 550 tiles out was cut by biters 5+ times a shift, and each fix took several calls and long walks). It reads the
-- area now and submits one plan to the queue, each step as the agent would call it:
-- - construct {area}: every ghost there built from what the character holds (poles, belts, turrets), walking to them;
-- - rearm {area, item, below}: every ammo turret there under `below` rounds topped up, a walking tour;
-- - wire {from, to} (copper): each pole there with no wire path to the rest of its old network, joined to the nearest
--   pole of the network that has power, when a copper wire reaches (after the construct step: a rebuilt pole may join
--   on its own, and the wire step then says already).
-- dry_run: the read and the plan, nothing queued. A step that fails is skipped (on_fail skip), so the rest still runs.
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  local MAX_WIRES, MAX_POLES = 8, 400
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x * 10 + 0.5) / 10, math.floor(q.y * 10 + 0.5) / 10) end
  local function area_of(a)
    if a.area ~= nil then
      local b = a.area
      local lt, rb = b.left_top or b[1], b.right_bottom or b[2]
      assert(type(lt) == 'table' and type(rb) == 'table', 'area is {left_top, right_bottom}')
      lt, rb = api.position(lt), api.position(rb)
      assert(rb.x - lt.x <= 256 and rb.y - lt.y <= 256 and rb.x > lt.x and rb.y > lt.y, 'area up to 256x256')
      return {left_top=lt, right_bottom=rb}, {x=(lt.x + rb.x) / 2, y=(lt.y + rb.y) / 2}
    end
    assert(a.position ~= nil, 'outpost takes area {left_top, right_bottom} or position (with radius, default 32)')
    local c = api.position(a.position)
    local r = api.integer(a.radius, 32, 4, 128, 'radius')
    return {left_top={x=c.x - r, y=c.y - r}, right_bottom={x=c.x + r, y=c.y + r}}, c
  end
  -- The ammo item for the rearm: the one named, else what the turrets there hold most of, else firearm-magazine.
  local function ammo_of(turrets, a)
    if a.ammo ~= nil then
      assert(type(a.ammo) == 'string' and prototypes.item[a.ammo] and prototypes.item[a.ammo].type == 'ammo', 'ammo is an ammo item name')
      return a.ammo
    end
    local by = {}
    for _, t in ipairs(turrets) do
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
        local n = type(c.name) == 'string' and c.name or try(function() return c.name.name end)
        if n then by[n] = (by[n] or 0) + c.count end
      end
    end
    local best, bn
    for n, c in pairs(by) do if not bn or c > bn then best, bn = n, c end end
    return best or 'firearm-magazine'
  end
  function M.read(p, a)
    assert(a.dry_run == nil or type(a.dry_run) == 'boolean', 'dry_run must be true or false')
    local box, centre = area_of(a)
    local below = api.integer(a.below, 20, 1, 1000, 'below')
    local s, f = p.surface, p.force
    local area = {box.left_top, box.right_bottom}
    -- Ghosts there, by name.
    local ghosts, gn, need = {}, 0, {}
    for _, g in ipairs(s.find_entities_filtered{type='entity-ghost', force=f, area=area, limit=2000}) do
      gn = gn + 1
      local n = try(function() return g.ghost_name end) or '?'
      ghosts[n] = (ghosts[n] or 0) + 1
      local it = try(function() return g.ghost_prototype.items_to_place_this[1] end)
      local iname = it and (type(it.name) == 'string' and it.name or try(function() return it.name.name end))
      if iname then need[iname] = (need[iname] or 0) + (it.count or 1) end
    end
    -- What the character lacks of the ghosts' items (construct builds from what it holds).
    local short = {}
    for iname, n in pairs(need) do
      local held = try(function() return p.get_item_count(iname) end) or 0
      if held < n then short[#short+1] = string.format('%s %d (you hold %d)', iname, n, held) end
    end
    table.sort(short)
    -- Ammo turrets under `below` rounds.
    local turrets = s.find_entities_filtered{type='ammo-turret', force=f, area=area, limit=500}
    local low = 0
    for _, t in ipairs(turrets) do
      local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
      if (inv and try(function() return inv.get_item_count() end) or 0) < below then low = low + 1 end
    end
    -- Poles there in networks with no power now, each with the nearest pole of a network with power that a copper wire
    -- reaches (in the area and a wire's reach around it).
    local poles = s.find_entities_filtered{type='electric-pole', force=f, area={{box.left_top.x - 32, box.left_top.y - 32}, {box.right_bottom.x + 32, box.right_bottom.y + 32}}, limit=MAX_POLES}
    local powered = {}
    local function has_power(e)
      local id = e.electric_network_id
      if powered[id] == nil then
        local stats = try(function() return e.electric_network_statistics end)
        local made = 0
        for name, all in pairs(stats and try(function() return stats.output_counts end) or {}) do
          made = made + (try(function() return qflow.flow(stats, name, 'output', defines.flow_precision_index.five_seconds, nil, all) end) or 0)
        end
        powered[id] = made > 0
      end
      return powered[id]
    end
    local wires, dark = {}, 0
    local seen_net = {}
    for _, e in ipairs(poles) do
      local inside = e.position.x >= box.left_top.x and e.position.x <= box.right_bottom.x and e.position.y >= box.left_top.y and e.position.y <= box.right_bottom.y
      if inside and e.valid and not has_power(e) and not seen_net[e.electric_network_id] then
        seen_net[e.electric_network_id] = true
        dark = dark + 1
        local best, bd
        local from = try(function() return e.get_wire_connector(defines.wire_connector_id.pole_copper, false) end)
        for _, o in ipairs(poles) do
          if o ~= e and o.valid and o.electric_network_id ~= e.electric_network_id and has_power(o) then
            local d = (o.position.x - e.position.x) ^ 2 + (o.position.y - e.position.y) ^ 2
            local to = try(function() return o.get_wire_connector(defines.wire_connector_id.pole_copper, false) end)
            if (not bd or d < bd) and from and to and try(function() return from.can_wire_reach(to) end) then best, bd = o, d end
          end
        end
        if best and #wires < MAX_WIRES then wires[#wires+1] = {from={x=e.position.x, y=e.position.y}, to={x=best.position.x, y=best.position.y},
          text=string.format('%s %s (network %d, no power) to %s %s (network %d)', e.name, at(e.position), e.electric_network_id, best.name, at(best.position), best.electric_network_id)} end
      end
    end
    local ammo = ammo_of(turrets, a)
    local steps, plan = {}, {}
    if gn > 0 then
      steps[#steps+1] = {action='construct', args={area=box}, on_fail='skip'}
      local names = {}
      for n, c in pairs(ghosts) do names[#names+1] = c .. ' ' .. n end
      table.sort(names)
      plan[#plan+1] = string.format('construct: %d ghosts (%s)%s', gn, table.concat(names, ', ', 1, math.min(6, #names)) .. (#names > 6 and ', ...' or ''),
        #short > 0 and '; short of ' .. table.concat(short, ', ', 1, math.min(6, #short)) .. (#short > 6 and ', ...' or '') or '')
    end
    if low > 0 then
      steps[#steps+1] = {action='rearm', args={area=box, ammo=ammo, below=below}, on_fail='skip'}
      plan[#plan+1] = string.format('rearm: %d of %d ammo turrets under %d rounds, with %s (you hold %d)', low, #turrets, below, ammo, try(function() return p.get_item_count(ammo) end) or 0)
    end
    for _, w in ipairs(wires) do
      steps[#steps+1] = {action='wire', args={from=w.from, to=w.to}, on_fail='skip'}
      plan[#plan+1] = 'wire: ' .. w.text
    end
    local out = {area=string.format('%s to %s', at(box.left_top), at(box.right_bottom)), ghosts=gn, turrets=#turrets, turrets_low=low,
      unpowered_networks=dark, plan=#plan > 0 and plan or nil}
    if dark > #wires then out.not_reached = string.format('%d network%s with no power and no pole of a powered network a copper wire reaches', dark - #wires, dark - #wires == 1 and '' or 's') end
    if #steps == 0 then out.line = 'nothing to do in the area: no ghosts, no ammo turret under ' .. below .. ' rounds, no pole cut off from power'; return out end
    if a.dry_run then out.line = 'dry run: nothing queued'; out.steps = steps; return out end
    local q = api.submit(p, {steps=steps})
    out.queued = #steps
    out.queue = q and q.plan and {id=q.plan.id, steps=q.plan.steps} or nil
    out.line = string.format('queued %d step%s: %s', #steps, #steps == 1 and '' or 's', table.concat(plan, '; '))
    return out
  end
  M.schema = {outpost={area='{left_top, right_bottom} up to 256x256 (or position and radius)', position='{x,y}: the outpost centre', radius='4..128 (default 32)',
    ammo='optional ammo item for the rearm (default: what the turrets there hold most of, else firearm-magazine)', below='rearm turrets under this many rounds (default 20)',
    dry_run='true: the read and the plan (steps), nothing queued',
    returns='ghosts, turrets, turrets_low, unpowered_networks, plan (one line per step: construct, rearm, wire), not_reached, queued, queue, line; the plan runs in your queue (queue_status), each step skipped on failure'}}
  return M
end
