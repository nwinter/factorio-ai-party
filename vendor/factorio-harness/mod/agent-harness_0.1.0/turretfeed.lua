-- turret_feeds {area | positions, ammo?, count?, chest?, inserter?, dry_run?} (batch24 C4, Opus ~8 times by script: the
-- script reported success when the chest did not fit). For each ammo turret of ours there that no inserter feeds (hand
-- fed): a free side where an inserter's drop lands in the turret and its pickup on a free tile, checked as a hand build
-- checks a spot (both tiles, and the spots planned for the turrets before it); a requester chest there asking for the
-- turret's ammunition and the inserter, built from your inventory by build (its walk into reach, its checks, entry
-- settings for the request). Each turret is planned (the chest and inserter spots), skipped (why) or short of items
-- (the chests and inserters you hold run out in turn).
return function(api)
  local M = {}
  local MAX = 32
  M.MAX = MAX  -- (d25 batch208 QU1) also a queue step's check (runtime.lua step_lengths)
  local DIRS = {0, 4, 8, 12}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function inside(b, q) return q.x > b.left_top.x and q.x < b.right_bottom.x and q.y > b.left_top.y and q.y < b.right_bottom.y end
  local function tile(q) return {x=math.floor(q.x) + 0.5, y=math.floor(q.y) + 0.5} end
  local function key(q) return math.floor(q.x) .. ',' .. math.floor(q.y) end
  -- An inserter of ours dropping into t (its drop target), or nil.
  local function fed_by(s, t)
    local b = t.bounding_box
    for _, i in ipairs(try(function() return s.find_entities_filtered{type='inserter', force=t.force,
        area={{b.left_top.x - 3, b.left_top.y - 3}, {b.right_bottom.x + 3, b.right_bottom.y + 3}}} end) or {}) do
      if try(function() return i.drop_target end) == t then return i end
    end
  end
  -- The ammunition for t: asked, else what it holds, else none.
  local function ammo_of(t, asked)
    if asked then return asked end
    local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
    for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do return c.name end
  end
  -- A side of t: an inserter tile next to its box and a direction whose drop lands in it and pickup on a free tile.
  local function side(s, force, t, ins, chest, taken)
    local b = t.bounding_box
    local x0, y0, x1, y1 = math.floor(b.left_top.x + 0.01), math.floor(b.left_top.y + 0.01), math.ceil(b.right_bottom.x - 0.01) - 1, math.ceil(b.right_bottom.y - 0.01) - 1
    local spots = {}
    for x = x0, x1 do spots[#spots+1] = {x=x + 0.5, y=y0 - 0.5}; spots[#spots+1] = {x=x + 0.5, y=y1 + 1.5} end
    for y = y0, y1 do spots[#spots+1] = {x=x0 - 0.5, y=y + 0.5}; spots[#spots+1] = {x=x1 + 1.5, y=y + 0.5} end
    local why
    for _, q in ipairs(spots) do
      for _, d in ipairs(DIRS) do
        local pick, drop = api.points(ins, q, d)
        if pick and drop and inside(b, drop) and not inside(b, pick) then
          local cq = tile(pick)
          if taken[key(q)] or taken[key(cq)] then why = why or 'the spots beside it are planned for another turret'
          elseif not s.can_place_entity{name=ins.name, position=q, direction=d, force=force, build_check_type=defines.build_check_type.manual} then
            why = why or 'no inserter fits on a side (each side tile is taken)'
          elseif not s.can_place_entity{name=chest.name, position=cq, force=force, build_check_type=defines.build_check_type.manual} then
            why = 'no chest fits behind an inserter spot (the tile behind each is taken)'
          else return {inserter=q, direction=d, chest=cq} end
        end
      end
    end
    return nil, why or 'no side where an inserter drops into it'
  end
  -- (batch26 B4, Opus: 20 old feed inserters stood unpowered unnoticed) a feed inserter with no power: why, or nil.
  function M.unpowered(i)
    if not (i and i.valid) then return nil end
    if try(function() return i.prototype.electric_energy_source_prototype end) == nil then return nil end
    if try(function() return i.electric_network_id end) == nil then return 'no pole reaches it' end
    if try(function() return i.status end) == (defines.entity_status or {}).no_power then return 'no power on its network' end
    return nil
  end
  -- A pole ghost that brings power to an inserter at q (batch26 B4): nil when a pole of ours already covers q; else a
  -- free tile within 2 of q inside the new pole's supply area and within its wire reach of our nearest pole.
  local function pole_link(s, force, q, pole, taken)
    local poles = try(function() return s.find_entities_filtered{type='electric-pole', force=force, position=q, radius=40, limit=64} end) or {}
    local near, nd
    for _, o in ipairs(poles) do
      local sad = try(function() return o.prototype.get_supply_area_distance() end) or 2.5
      if math.abs(o.position.x - q.x) <= sad + 0.4 and math.abs(o.position.y - q.y) <= sad + 0.4 then return nil end
      local d = math.sqrt((o.position.x - q.x) ^ 2 + (o.position.y - q.y) ^ 2)
      if not nd or d < nd then near, nd = o, d end
    end
    if not near then return nil, 'no pole of ours within 40 tiles' end
    local proto = prototypes.entity[pole]
    local sad = try(function() return proto.get_supply_area_distance() end) or 2.5
    local reach = try(function() return proto.get_max_wire_distance() end) or try(function() return proto.max_wire_distance end) or 7.5
    local near_reach = try(function() return near.prototype.get_max_wire_distance() end) or try(function() return near.prototype.max_wire_distance end) or reach
    local best, bd
    for dx = -2, 2 do
      for dy = -2, 2 do
        local c = {x=math.floor(q.x) + dx + 0.5, y=math.floor(q.y) + dy + 0.5}
        if not taken[key(c)] and math.abs(c.x - q.x) <= sad and math.abs(c.y - q.y) <= sad then
          local d = math.sqrt((c.x - near.position.x) ^ 2 + (c.y - near.position.y) ^ 2)
          if d <= math.min(reach, near_reach) and (not bd or d < bd)
            and try(function() return s.can_place_entity{name=pole, position=c, force=force, build_check_type=defines.build_check_type.manual_ghost} end) then best, bd = c, d end
        end
      end
    end
    if not best then
      return nil, string.format('no spot for a %s beside it within wire reach of %s %s (%d tiles away)', pole, near.name, at(near.position), math.floor(nd + 0.5))
    end
    return best
  end
  function M.handler(p, a)
    local s = p.surface
    local chest_name, ins_name = a.chest or 'requester-chest', a.inserter or 'inserter'
    local chest, ins = prototypes.entity[chest_name], prototypes.entity[ins_name]
    assert(chest and chest.type == 'logistic-container', 'chest: a logistic chest (default requester-chest)')
    assert(ins and ins.type == 'inserter', 'inserter: an inserter name (default inserter)')
    local count = a.count == nil and 50 or a.count
    assert(type(count) == 'number' and count >= 1 and count <= 1000 and count == math.floor(count), 'count: 1..1000 (the request, default 50)')
    if a.ammo ~= nil then assert(prototypes.item[a.ammo] and prototypes.item[a.ammo].type == 'ammo', 'ammo: an ammunition name') end
    local turrets = {}
    if a.positions ~= nil then
      assert(type(a.positions) == 'table' and #a.positions >= 1 and #a.positions <= MAX, 'positions: 1..32 turret positions')
      for _, pos in ipairs(a.positions) do
        local e = api.entity(p, {position=pos})
        assert(e.type == 'ammo-turret', e.name .. ' at ' .. at(e.position) .. ' is not an ammo turret')
        turrets[#turrets+1] = e
      end
    else
      assert(type(a.area) == 'table' and a.area.left_top and a.area.right_bottom, 'area {left_top, right_bottom} or positions')
      local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
      assert((rb.x - lt.x) <= 128 and (rb.y - lt.y) <= 128, 'area: at most 128x128')
      turrets = s.find_entities_filtered{type='ammo-turret', force=p.force, area={lt, rb}, limit=MAX + 1}
      assert(#turrets <= MAX, 'more than 32 ammo turrets in the area: a smaller area')
      table.sort(turrets, function(x, y) if x.position.y ~= y.position.y then return x.position.y < y.position.y end return x.position.x < y.position.x end)
    end
    if a.ghosts ~= nil then assert(type(a.ghosts) == 'boolean', 'ghosts must be true or false') end
    local pole = a.pole or 'small-electric-pole'
    if a.ghosts then assert(prototypes.entity[pole] and prototypes.entity[pole].type == 'electric-pole', 'pole: an electric pole name (default small-electric-pole)') end
    local inv = not a.ghosts and try(function() return p.get_main_inventory() end)
    local held_c, held_i = inv and inv.get_item_count(chest_name) or 0, inv and inv.get_item_count(ins_name) or 0
    if a.ghosts then held_c, held_i = math.huge, math.huge end
    local rows, builds, taken = {}, {}, {}
    local planned, skipped, short = 0, 0, 0
    for _, t in ipairs(turrets) do
      local row = {name=t.name, position=t.position}
      local feeder = fed_by(s, t)
      local ammo = ammo_of(t, a.ammo)
      if feeder then
        local off = M.unpowered(feeder)
        row.skipped = string.format('fed by %s %s already%s', feeder.name, at(feeder.position), off and '; inserter unpowered: ' .. off or '')
        row.unpowered = off and true or nil
        skipped = skipped + 1
      elseif not ammo then row.skipped = 'empty, and no ammo named: ammo names what the chest asks for'; skipped = skipped + 1
      else
        local spot, why = side(s, p.force, t, ins, chest, taken)
        if not spot then row.skipped = why; skipped = skipped + 1
        elseif planned >= held_c or planned >= held_i then
          row.short = string.format('you hold %d %s and %d %s: none left for it', held_c, chest_name, held_i, ins_name); short = short + 1
        else
          planned = planned + 1
          taken[key(spot.inserter)] = true; taken[key(spot.chest)] = true
          row.chest, row.inserter, row.direction, row.ammo = spot.chest, spot.inserter, api.compass(spot.direction), ammo
          row.entries = {#builds + 1, #builds + 2}
          builds[#builds+1] = {item=chest_name, position=spot.chest, requests={set={{item=ammo, min=count}}}}
          builds[#builds+1] = {item=ins_name, position=spot.inserter, direction=spot.direction}
          if a.ghosts then
            local pc, why = pole_link(s, p.force, spot.inserter, pole, taken)
            if pc then
              taken[key(pc)] = true; row.pole = pc; row.entries[3] = #builds + 1
              builds[#builds+1] = {item=pole, position=pc}
            elseif why then row.pole_note = why end
          end
        end
      end
      rows[#rows+1] = row
    end
    local lines, unpowered = {}, 0
    for _, r in ipairs(rows) do
      if r.unpowered then unpowered = unpowered + 1 end
      lines[#lines+1] = string.format('%s %s: %s', r.name, at(r.position), r.skipped and 'skipped: ' .. r.skipped or r.short and 'short: ' .. r.short
        or string.format('%s %s asking %d %s, %s %s facing %s%s%s', chest_name, at(r.chest), count, r.ammo, ins_name, at(r.inserter), r.direction,
          r.pole and string.format(', %s %s', pole, at(r.pole)) or '', r.pole_note and '; ' .. r.pole_note or ''))
    end
    local out = {turrets=#rows, planned=planned, skipped=skipped, short=short, unpowered=unpowered > 0 and unpowered or nil, rows=rows, lines=lines}
    if a.ghosts and not a.dry_run and #builds > 0 then
      local entities = {}
      for i, b in ipairs(builds) do entities[i] = {name=b.item, position=b.position, direction=b.direction, requests=b.requests} end
      local ok, placed = pcall(api.place_ghosts, p, {entities=entities})
      if not ok then out.error = tostring(placed):gsub('^[^:]*:%d+: ', ''); return out end
      out.ghosts = placed
      out.note = 'ghosts for construction robots (by remote view, as place_ghosts); the chest\'s request is set on its ghost'
      return out
    end
    if a.dry_run or #builds == 0 then
      out.dry_run = a.dry_run or nil
      out.note = #builds == 0 and 'nothing to build' or 'nothing built (dry_run)'
      return out
    end
    local ok, built = pcall(api.build, p, {builds=builds, all=true})
    if not ok then out.error = tostring(built):gsub('^[^:]*:%d+: ', ''); return out end
    -- Each turret's entries as build placed or refused them (build's failed rows by entry index).
    local failed = {}
    for _, f in ipairs(built.failed or {}) do failed[f.index] = f.error end
    for _, r in ipairs(rows) do
      if r.entries then
        local e1, e2 = failed[r.entries[1]], failed[r.entries[2]]
        r.not_built = (e1 or e2) and table.concat({e1 and 'chest: ' .. e1 or nil, e2 and 'inserter: ' .. e2 or nil}, '; ') or nil
      end
    end
    out.build = built
    out.note = built.walking and 'the build walks into reach first: each entry\'s outcome comes in last (status, --wait)'
      or 'rows not_built: an entry build refused; the rest stand with the chest\'s request set'
    return out
  end
  M.schema = {turret_feeds = {area='{left_top, right_bottom} up to 128x128: its ammo turrets of ours (at most 32)', positions='or 1..32 turret positions',
    ammo='optional ammunition name (default what each turret holds now)', count='optional 1..1000: the chest\'s request (default 50)',
    chest='optional logistic chest name (default requester-chest)', inserter='optional inserter name (default inserter)', dry_run='optional true: plan only',
    ghosts='optional true: place the chest, the inserter and, when no pole of ours covers the inserter, a pole as ghosts for construction robots (by remote view, as place_ghosts), nothing from your inventory',
    pole='optional pole name for ghosts (default small-electric-pole): beside the inserter, within wire reach of our nearest pole',
    returns='turrets, planned, skipped, short, unpowered (feeds already there whose inserter has no power: inserter unpowered in skipped), rows [{name, position, skipped (fed already, no free side, no ammo), pole, pole_note, short (the chests or inserters you hold ran out), chest, inserter, direction, ammo, not_built}], lines; build (the build reply: placed, failed, materials; it walks into reach as build does). From your inventory, as build places them; each spot checked as a hand build checks it'}}
  return M
end
