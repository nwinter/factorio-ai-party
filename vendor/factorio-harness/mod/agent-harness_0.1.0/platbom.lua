-- platform_bom {platform, pack?} (B3, Sol 22:50: "I manually reconciled this every five minutes and found 13 mixed
-- rockets replace 31 single-item launches"): a platform's remaining bill of materials in one read. Per item: what its
-- ghosts still need (entity ghosts by the item that places them, tile ghosts by the tile's item), what is built of it
-- there, what the hub holds, what is in flight to it (cargo pods headed for this platform, from any planet), what the
-- hub's requests ask, and the rest still to send. pack: true splits the rest into rockets within a rocket's lift and
-- cargo slots, heaviest items first (cargo.lua weigh: each item into the first rocket with room for some of it).
-- Item requests (modules and the like) count too: on entity ghosts and on item-request proxies of built machines (d17
-- batch19 A3, Astra: Swiftlet's 34 efficiency and 2 speed modules were in no BOM line). Items construction robots
-- there carry (taken from the hub for a ghost not built yet) are said, and taken off what is still to send. Read only.
-- Every count is by item and quality (d21 batch66 AB1): a ghost is built only from items of its own quality.
local qflow = require('qflow')   -- (d24 batch152 PX1) statistics read at every quality
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function item_of(proto)
    local list = proto and try(function() return proto.items_to_place_this end)
    local first = list and list[1]
    if not first then return nil end
    local name = type(first.name) == 'string' and first.name or try(function() return first.name.name end)
    return name, first.count or 1
  end
  -- (d21 batch66 AB1, Sol #1591: Solstice's ghosts needed asteroid-collector@uncommon 1, solar-panel@epic 1 and @rare 2;
  -- the BOM counted collector 1 and solar 3 at normal, took 6 normal panels in the hub as covering them, and its
  -- requests never asked the qualities) every count is by item and quality, as construction_blocked and the game's
  -- ghost item requests are: the hub builds a ghost only from items of its quality, so no other quality covers it.
  local function qname(q)
    if type(q) == 'string' then return q end
    return q and try(function() return q.name end) or 'normal'
  end
  local function key(name, q) return name .. '@' .. (q or 'normal') end
  local function split(k) local name, q = k:match('^(.*)@([^@]*)$'); return name or k, q or 'normal' end
  local function label(k) local name, q = split(k); return q == 'normal' and name or k end
  local function count_of(inv, k)
    if not inv then return 0 end
    local name, q = split(k)
    return try(function() return inv.get_item_count{name=name, quality=q} end) or 0
  end
  -- What a ghost or an item-request proxy asks to have put in it (modules and the like), added into `into` by item.
  local function requests_of(e, into)
    local list = try(function() return e.item_requests end)
    if type(list) == 'table' and #list > 0 then
      for _, q in ipairs(list) do
        local n = type(q.name) == 'table' and q.name.name or q.name
        if n and (q.count or 0) > 0 then local k = key(n, qname(q.quality)); into[k] = (into[k] or 0) + q.count end
      end
      return
    end
    for _, plan in ipairs(try(function() return e.insert_plan end) or {}) do
      local n = plan.id and (type(plan.id.name) == 'table' and plan.id.name.name or plan.id.name)
      local c = plan.items and plan.items.grid_count or 0
      for _, r in ipairs(plan.items and plan.items.in_inventory or {}) do c = c + (r.count or 1) end
      if n and c > 0 then local k = key(n, qname(plan.id.quality)); into[k] = (into[k] or 0) + c end
    end
  end
  -- The items the platform's construction robots carry now, by item and quality.
  local function in_robots(pl, force)
    local by = {}
    for _, r in ipairs(try(function() return pl.surface.find_entities_filtered{type='construction-robot', force=force} end) or {}) do
      local inv = try(function() return r.get_inventory(defines.inventory.robot_cargo) end)
      for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do local k = key(c.name, qname(c.quality)); by[k] = (by[k] or 0) + c.count end
    end
    return by
  end
  -- Cargo pods headed for the platform, from any surface: their cargo by item and quality, and how many pods.
  local function in_flight(pl)
    local hub = pl.hub
    local by, pods = {}, 0
    local station, platform_kind = defines.cargo_destination and defines.cargo_destination.station, defines.cargo_destination and defines.cargo_destination.space_platform
    for _, s in pairs(game.surfaces) do
      for _, pod in ipairs(try(function() return s.find_entities_filtered{type='cargo-pod'} end) or {}) do
        local d = pod.valid and try(function() return pod.cargo_pod_destination end)
        local ours = d and ((d.type == station and d.station == hub) or (d.type == platform_kind and d.space_platform == pl))
        -- (a pod leaving the platform for a planet has the planet as its destination)
        if ours then
          pods = pods + 1
          local inv = try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
          for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do local k = key(c.name, qname(c.quality)); by[k] = (by[k] or 0) + c.count end
        end
      end
    end
    return by, pods
  end
  -- What the hub's active request sections ask of each item and quality (their min summed).
  local function asks(hub)
    local out = {}
    local secs = try(function() return hub.get_logistic_sections() end)
    for i = 1, secs and secs.sections_count or 0 do
      local sec = secs.get_section(i)
      if sec and sec.active ~= false then
        for _, f in pairs(try(function() return sec.filters end) or {}) do
          local v = f.value
          local name = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
          if name and (f.min or 0) > 0 then local k = key(name, qname(v.quality)); out[k] = (out[k] or 0) + f.min end
        end
      end
    end
    return out
  end
  -- request (A6, Sol 01:50: a fixed request kept refilling the hub after the build, about 40 foundation rockets it did
  -- not need): a hub section of its own (logistic group "platform_bom: NAME") asking, for each item, what the
  -- platform's ghosts (those in area, when given) still need, imported from import_from; kept so every 10 s (M.tick):
  -- lowered as the ghosts are built, removed with the last of them. request: false removes it.
  -- A full rocket of an item by weight (the default minimum payload of a hub request), nil when not known.
  local function full_rocket(item)
    local w = try(function() return prototypes.item[item].weight end)
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end) or 1000000
    if not (w and w > 0) then return nil end
    return math.max(1, math.floor(lift / w))
  end
  local function ghost_need(pl, force, areas)
    local s = pl.surface
    local need, known = {}, {}
    local lists = {}
    local kinds = {'entity-ghost', 'tile-ghost', 'item-request-proxy'}
    if areas then for _, ar in ipairs(areas) do lists[#lists+1] = s.find_entities_filtered{area=ar, type=kinds, force=force} end
    else lists[1] = s.find_entities_filtered{type=kinds, force=force} end
    for _, list in ipairs(lists) do
      for _, g in ipairs(list) do
        if g.type == 'item-request-proxy' then requests_of(g, need)
        else
          local gk = g.type .. ':' .. g.ghost_name
          local k = known[gk]
          if not k then local item, n = item_of(try(function() return g.ghost_prototype end)); k = {item=item, n=n}; known[gk] = k end
          if k.item then local q = key(k.item, qname(try(function() return g.quality end))); need[q] = (need[q] or 0) + k.n end
          if g.type == 'entity-ghost' then requests_of(g, need) end
        end
      end
    end
    return need
  end
  local function store() local st = api.state and api.state() or {}; st.bom_requests = st.bom_requests or {}; return st.bom_requests end
  local function section_of(hub, group, create)
    local secs = try(function() return hub.get_logistic_sections() end)
    if not secs then return nil end
    for i = 1, secs.sections_count do
      local sec = secs.get_section(i)
      if sec and try(function() return sec.group end) == group then return sec, secs, i end
    end
    if create then return secs.add_section(group), secs end
  end
  -- Sets the section to need less what the platform's construction robots carry (taken from the hub for ghosts not built
  -- yet: counted as the hub's, so the hub's dip while they fly sends no rocket; Astra, Swiftlet: duplicate hardware);
  -- returns lines (item, the request now, what the ghosts need, the robots carry, the hub holds).
  local function apply(pl, rec, need)
    local hub = pl.hub
    local items = {}
    local carry = next(need) and in_robots(pl, pl.force) or {}
    for k, n in pairs(need) do local name, q = split(k); items[#items+1] = {item=k, name=name, quality=q, n=math.max(0, n - (carry[k] or 0)), need=n, carry=carry[k]} end
    table.sort(items, function(x, y) return x.item < y.item end)
    if #items == 0 then
      local _, secs, i = section_of(hub, rec.group, false)
      if secs and i then secs.remove_section(i) end
      return {}, true
    end
    local sec = section_of(hub, rec.group, true)
    local n = try(function() return sec.filters_count end) or 0
    -- Each item's slot options as they stand (d17 batch12 A0, Sol: the rewrite every 10 s erased the custom minimum
    -- payload min_payload had set, so small hardware waited for a full rocket): its min_payload and max are kept, the
    -- request's own min_payload map wins, and a slot already as wanted is not written again.
    -- (d17 batch34 A3, Muse: Wayfarer's floor request read absent with 72 ghosts open, between two rewrites that each
    -- read it as 72; both times items sorted before it had just dropped out) each item keeps the slot it has: an item no
    -- longer needed is cleared where it stands and a new one takes a free slot, so no rewrite writes one item into
    -- another's slot. (d21 batch66 AB1) A slot is an item at a quality (comparator =): one slot each.
    local was, free, wanted = {}, {}, {}
    for _, it in ipairs(items) do wanted[it.item] = true end
    for i = 1, n do
      local f = try(function() return sec.get_slot(i) end)
      local v = f and f.value
      local name = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
      if name then name = key(name, qname(v.quality)) end
      if name and wanted[name] and not was[name] then
        was[name] = {slot=i, min=f.min, max=f.max, mp=f.minimum_delivery_count, from=f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))}
      else
        if name then pcall(sec.clear_slot, i) end
        free[#free+1] = i
      end
    end
    -- A slot's minimum payload changed since the keeper last wrote it (d17 batch21 A2, Astra: crusher 10 -> 9 by
    -- min_payload, put back every 10 s) was changed by requests or min_payload: the keeper adopts it.
    rec.written = rec.written or {}
    local inv0 = rec.tail and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    for i, it in ipairs(items) do
      local w = was[it.item]
      if w and rec.written[it.item] ~= nil and (w.mp or false) ~= rec.written[it.item] then
        rec.min_payload = rec.min_payload or {}
        rec.min_payload[it.item] = w.mp or false
        rec.adopted = rec.adopted or {}
        rec.adopted[it.item] = {mp=w.mp, tick=game.tick}
      end
      local mp = rec.min_payload and rec.min_payload[it.item]
      if mp == nil and rec.min_payload then mp = rec.min_payload[it.name] end
      if mp == nil and w then mp = w.mp end
      if mp == false or mp == 0 then mp = nil end
      -- tail (d17 batch21 A2): the payload no more than what is still to come (the request less what the hub holds),
      -- so the last few do not wait for a full batch
      -- (d17 batch33 A3, Sol: Wayfarer's arithmetic combinator asked 2 against the default, a full rocket of 50, and
      -- waited) a slot with no custom minimum payload has the game's default, a full rocket by weight: tail lowers that
      -- too
      local full = full_rocket(it.name)
      if rec.tail then
        local left = it.n - count_of(inv0, it.item)
        local base = mp or full
        if base and left > 0 and left < base then it.tail_of = base; it.tail_default = not mp or nil; mp = left end
      end
      it.full = full
      it.mp = mp
      rec.written[it.item] = mp or false
      local slot = w and w.slot or table.remove(free, 1)
      if not slot then n = n + 1; slot = n end
      it.slot = slot
      if not (w and w.min == it.n and w.mp == mp and w.from == rec.import_from) then
        sec.set_slot(slot, {value={type='item', name=it.name, quality=it.quality, comparator='='}, min=it.n, max=w and w.max or nil,
          import_from=rec.import_from, minimum_delivery_count=mp})
      end
    end
    local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local lines = {}
    -- what was written and what the hub holds now, for the watch (A3)
    local spent = rec.spent
    rec.min, rec.held, rec.slot, rec.spent = {}, {}, {}, nil
    for _, it in ipairs(items) do
      rec.min[it.item] = it.n; rec.slot[it.item] = it.slot
      rec.held[it.item] = count_of(inv, it.item)
    end
    for _, it in ipairs(items) do
      local held = rec.held[it.item]
      lines[#lines+1] = string.format('%s: request %d from %s (the ghosts need %d%s; the hub holds %d)%s', label(it.item), it.n, rec.import_from, it.need,
        it.carry and string.format(', construction robots carry %d', it.carry) or '', held,
        it.mp and string.format('; custom minimum payload %d', it.mp) or (it.full and string.format('; minimum payload: a full rocket, %d by weight (the game\'s default)', it.full) or '; minimum payload: the game\'s default'))
        .. (it.tail_of and string.format(' (tail: %d of the %d %s, what is still to come)', it.mp, it.tail_of, it.tail_default and 'a full rocket takes' or 'set') or '')
        .. (rec.adopted and rec.adopted[it.item] and string.format(' (adopted from the slot, changed by requests or min_payload: %s)', rec.adopted[it.item].mp and tostring(rec.adopted[it.item].mp) or 'none') or '')
        .. (spent and spent[it.item] and string.format(' (lowered at once by %d since the last rewrite as the hub spent it)', spent[it.item]) or '')
    end
    return lines, false
  end
  -- The watch (batch27 A3, Sol: the 10 s rewrite launched a full stack after ghosts used hub stock: 200 pipes, extra
  -- modules): the hub spends its stock on ghosts at once, and what the ghosts need falls only as they are built and the
  -- section is rewritten, so in between the hub holds less than the request asks and the planet sends again. Each tick
  -- a drop in what the hub holds of an item the section asks for lowers that request by as much at once; the rewrite
  -- every 10 s (M.tick) then counts the ghosts, the robots' cargo and the hub again in full.
  local platforms = {}
  local function platform_of(index)
    local pl = platforms[index]
    if pl and pl.valid then return pl end
    for _, f in pairs(game.forces) do
      for _, x in pairs(f.platforms) do if x.valid and x.index == index then platforms[index] = x; return x end end
    end
  end
  function M.watch()
    for index, rec in pairs(store()) do
      local pl = rec.held and platform_of(index)
      local hub = pl and pl.hub
      local inv = hub and hub.valid and try(function() return hub.get_inventory(defines.inventory.hub_main) end)
      if inv then
        local sec
        for item, was in pairs(rec.held) do
          local now = count_of(inv, item)
          if now < was and (rec.min[item] or 0) > 0 then
            sec = sec or section_of(hub, rec.group, false)
            local i = rec.slot[item]
            local f = sec and i and try(function() return sec.get_slot(i) end)
            local v = f and f.value
            local name = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
            if name and key(name, qname(v.quality)) == item then
              local min = math.max(0, rec.min[item] - (was - now))
              if pcall(sec.set_slot, i, {value=v, min=min, max=f.max, import_from=f.import_from, minimum_delivery_count=f.minimum_delivery_count}) then
                rec.spent = rec.spent or {}
                rec.spent[item] = (rec.spent[item] or 0) + rec.min[item] - min
                rec.min[item] = min
              end
            end
          end
          rec.held[item] = now
        end
      end
    end
  end
  -- (batch28 A3, Sol: a railgun turret min 4 silently stopped construction) a minimum payload heavier than a rocket lifts
  -- (rocket_lift_weight, 1000 kg) is refused, naming the most that fits.
  local function payload_fits(item, n, what)
    if type(n) ~= 'number' or n <= 0 then return end
    local w = try(function() return prototypes.item[item].weight end)
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end) or 1000000
    if w and w > 0 and n * w > lift then
      error(string.format('%s %s %d: %d weigh %g kg, a rocket lifts %g kg: at most %d fit%s (%s %d)', what, item, n, n, n * w / 1000, lift / 1000,
        math.floor(lift / w), math.floor(lift / w) == 1 and 's' or '', what, math.floor(lift / w)), 0)
    end
  end
  function M.request(p, a, pl)
    assert(pl.hub and pl.hub.valid, 'platform ' .. pl.name .. ' has no hub yet')
    local recs = store()
    local group = 'platform_bom: ' .. pl.name
    if a.request == false then
      local _, secs, i = section_of(pl.hub, group, false)
      if secs and i then secs.remove_section(i) end
      recs[pl.index] = nil
      return {platform=pl.name, request='removed', lines={'the platform_bom request section on ' .. pl.name .. '\'s hub is removed; its other requests are as they were'}}
    end
    local from = a.import_from or try(function() return pl.space_location.name end)
    assert(type(from) == 'string' and prototypes.space_location[from], 'import_from: the planet the items come from (default the one the platform is at)')
    local areas
    if a.area ~= nil then
      local list = (a.area.left_top or (a.area[1] and a.area[1].x)) and {a.area} or a.area
      areas = {}
      for _, ar in ipairs(list) do
        local lt, rb = ar.left_top or ar[1], ar.right_bottom or ar[2]
        assert(lt and rb and lt.x < rb.x and lt.y < rb.y, 'area: {left_top, right_bottom} or a list of them')
        areas[#areas+1] = {{lt.x, lt.y}, {rb.x, rb.y}}
      end
    end
    -- min_payload {item: N} (A0): the custom minimum payload of those items' requests (0 or false clears it)
    local mpmap
    if a.min_payload ~= nil then
      assert(type(a.min_payload) == 'table' and a.min_payload[1] == nil, 'min_payload is {item: N, ...} (0 or false clears it)')
      mpmap = {}
      for item, n in pairs(a.min_payload) do
        local name, q = split(tostring(item))
        assert(prototypes.item[name], 'min_payload: unknown item ' .. tostring(item))
        assert(not item:find('@', 1, true) or prototypes.quality[q], 'min_payload: unknown quality ' .. q .. ' (item or item@quality)')
        assert(n == false or (type(n) == 'number' and n == math.floor(n) and n >= 0 and n <= 1000000), 'min_payload ' .. item .. ': 1..1000000, or 0 or false to clear')
        payload_fits(name, n, 'min_payload')
        mpmap[item] = n
      end
    end
    local old = recs[pl.index]
    if not mpmap and old and old.min_payload then mpmap = old.min_payload end
    assert(a.tail == nil or type(a.tail) == 'boolean', 'tail must be true or false')
    local tail = a.tail
    if tail == nil and old then tail = old.tail end
    local rec = {group=group, import_from=from, areas=areas, force=p.force.name, by=api.who and api.who(p) or nil, tick=game.tick, min_payload=mpmap, tail=tail or nil,
      written=old and old.written or nil, adopted=not a.min_payload and old and old.adopted or nil, spent=old and old.spent or nil}
    recs[pl.index] = rec
    local lines, gone = apply(pl, rec, ghost_need(pl, p.force, areas))
    if gone then recs[pl.index] = nil end
    return {platform=pl.name, request=gone and 'nothing to request: no ghost' .. (areas and ' in the area' or '') or 'set',
      group=group, lines=#lines > 0 and lines or {'no ghost' .. (areas and ' in the area' or '') .. ' on ' .. pl.name .. ': no request kept'},
      note='a hub section of its own (logistic group "' .. group .. '"), set to what the ghosts' .. (areas and ' in the area' or '') .. ' still need; read again every 10 s: lowered as they are built, removed with the last; each tick a drop in what the hub holds of an item it asks lowers that request by as much at once; your other hub requests stay as they are'}
  end
  function M.tick(tick)
    local recs = store()
    for index, rec in pairs(recs) do
      local pl
      for _, f in pairs(game.forces) do
        for _, x in pairs(f.platforms) do if x.valid and x.index == index then pl = x end end
      end
      if not (pl and pl.hub and pl.hub.valid) then recs[index] = nil
      else
        local ok, _, gone = pcall(apply, pl, rec, ghost_need(pl, pl.force, rec.areas))
        if ok and gone then recs[index] = nil end
      end
    end
  end
  -- surface (d17 batch17 A6, Gemini: the outstanding platform requests from the planet she is on): every platform's
  -- active hub requests that import from that planet, with what its hub holds and how many it still lacks, and where
  -- the platform is. Read only.
  function M.from_surface(p, planet)
    assert(type(planet) == 'string' and prototypes.space_location[planet], 'surface: a planet the platforms import from (nauvis, gleba, ...)')
    local lines, rows = {}, {}
    for _, pl in pairs(p.force.platforms) do
      local hub = try(function() return pl.hub end)
      if pl.valid and hub and hub.valid then
        local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
        local where = try(function() return pl.space_location and 'at ' .. pl.space_location.name end)
          or try(function() local c = pl.space_connection; return c and 'flying ' .. c.from.name .. '<->' .. c.to.name end) or 'in space'
        local secs = try(function() return hub.get_logistic_sections() end)
        local asks = {}
        for i = 1, secs and secs.sections_count or 0 do
          local sec = secs.get_section(i)
          if sec and sec.active ~= false then
            for _, f in ipairs(sec.filters or {}) do
              local v = f.value
              local name = type(v) == 'table' and v.name or v
              local q = type(v) == 'table' and qname(v.quality) or 'normal'
              local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
              if name and from == planet and (f.min or 0) > 0 then
                local held = count_of(inv, key(name, q))
                local short = math.max(0, f.min - held)
                rows[#rows+1] = {platform=pl.name, item=name, quality=q, asks=f.min, holds=held, short=short, where=where}
                if short > 0 then asks[#asks+1] = string.format('%s %d (asks %d, holds %d)', label(key(name, q)), short, f.min, held) end
              end
            end
          end
        end
        if #asks > 0 then lines[#lines+1] = string.format('%s (%s) lacks from %s: %s', pl.name, where, planet, table.concat(asks, ', ')) end
      end
    end
    if #lines == 0 then lines[1] = 'no platform of ours lacks anything it asks from ' .. planet end
    return {surface=planet, requests=rows, lines=lines}
  end
  function M.read(p, a)
    if a.surface ~= nil and a.platform == nil then return M.from_surface(p, a.surface) end
    assert(a.pack == nil or type(a.pack) == 'boolean', 'pack must be true or false')
    if a.request ~= nil then
      assert(type(a.request) == 'boolean', 'request is true or false')
      return M.request(p, a, api.platform(p, a.platform))
    end
    local pl = api.platform(p, a.platform)
    local s, hub = pl.surface, pl.hub
    assert(s and hub and hub.valid, 'platform ' .. pl.name .. ' has no hub yet (waiting for its starter pack)')
    local need, ghost_names, tile_names = {}, {}, {}
    local entity_ghosts, tile_ghosts = 0, 0
    -- (the item per ghost name, read once: 4094 ghosts on Meridian)
    local known = {}
    local asked = {}
    for _, g in ipairs(s.find_entities_filtered{type='item-request-proxy', force=p.force}) do requests_of(g, asked) end
    for _, g in ipairs(s.find_entities_filtered{type={'entity-ghost', 'tile-ghost'}, force=p.force}) do
      if g.type == 'entity-ghost' then requests_of(g, asked) end
      local gk = g.type .. ':' .. g.ghost_name
      local k = known[gk]
      if not k then
        local proto = try(function() return g.ghost_prototype end)
        local item, n = item_of(proto)
        k = {item=item, n=n, proto=proto}; known[gk] = k
      end
      local item, n, proto = k.item, k.n, k.proto
      if item then
        item = key(item, qname(try(function() return g.quality end)))
        need[item] = (need[item] or 0) + n
        if g.type == 'tile-ghost' then tile_ghosts = tile_ghosts + 1; tile_names[item] = proto.name
        else entity_ghosts = entity_ghosts + 1; ghost_names[item] = proto.name end
      end
    end
    local requests = {}
    for item, n in pairs(asked) do need[item] = (need[item] or 0) + n; requests[item] = n end
    local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    local flight, pods = in_flight(pl)
    local carry = in_robots(pl, p.force)
    local ask = asks(hub)
    local rows, rest, lines = {}, {}, {}
    -- a row an item at a quality: built, held, in flight and carried at that quality only; the hub's stock of the item at
    -- other qualities is said beside it (it builds none of these ghosts)
    for item, n in pairs(need) do
      local name, q = split(item)
      local built
      if ghost_names[item] then built = try(function() return s.count_entities_filtered{name=ghost_names[item], force=p.force, quality=q} end) end
      if tile_names[item] then built = try(function() return s.count_tiles_filtered{name=tile_names[item]} end) end
      local held = count_of(inv, item)
      local all = inv and try(function() return inv.get_item_count(name) end) or held
      local coming = flight[item] or 0
      local robots = carry[item] or 0
      local left = math.max(0, n - held - coming - robots)
      rows[#rows+1] = {item=name, quality=q, key=label(item), ghosts_need=n, requests=requests[item], built=built, hub=held,
        hub_other_quality=all > held and all - held or nil, in_flight=coming > 0 and coming or nil,
        in_robots=robots > 0 and robots or nil, remaining=left, asks=ask[item]}
      if left > 0 then rest[#rest+1] = {name=name, quality=q, count=left} end
    end
    table.sort(rows, function(x, y) if x.remaining ~= y.remaining then return x.remaining > y.remaining end return x.key < y.key end)
    for _, r in ipairs(rows) do
      lines[#lines+1] = string.format('%s: ghosts need %d%s%s; hub holds %d%s%s%s; %s%s', r.key, r.ghosts_need,
        r.requests and string.format(' (%d of them asked into ghosts and machines)', r.requests) or '', r.built and string.format(' (%d built)', r.built) or '',
        r.hub, r.hub_other_quality and string.format(' (and %d at other qualities, which do not build these)', r.hub_other_quality) or '',
        r.in_robots and string.format(', construction robots carry %d', r.in_robots) or '', r.in_flight and string.format(', %d in flight', r.in_flight) or '',
        r.remaining > 0 and string.format('%d to send', r.remaining) or 'covered',
        r.asks and string.format(' (the hub asks %d)', r.asks) or ' (the hub asks none)')
    end
    -- (d17 batch34 A3, Muse nearly called Wayfarer's hull closed on a request line that had dropped) ghosts open whose
    -- item no active hub request asks for, while the hub, cargo pods on their way and its robots hold less than they need
    local unasked = {}
    for _, r in ipairs(rows) do
      if r.remaining > 0 and (r.asks or 0) == 0 then
        unasked[#unasked+1] = string.format('%s: ghosts need %d, %d not in the hub, in flight or in robots; no active hub request asks for it', r.key, r.ghosts_need, r.remaining)
      end
    end
    local out = {platform=pl.name, entity_ghosts=entity_ghosts, tile_ghosts=tile_ghosts, pods_in_flight=pods, items=rows,
      lines=#lines > 0 and lines or {'no ghost on ' .. pl.name .. ': nothing to build'}, unrequested=#unasked > 0 and unasked or nil,
      requests_check=(entity_ghosts + tile_ghosts > 0) and (#unasked > 0 and string.format('%d item%s the ghosts still need %s no active hub request (unrequested)', #unasked, #unasked == 1 and '' or 's', #unasked == 1 and 'has' or 'have')
        or 'every item the ghosts still need has an active hub request') or nil}
    if #rest > 0 then
      local lift, slots = api.cargo.limits(nil)
      local w = api.cargo.weigh(rest, lift, slots)
      out.remaining_kg, out.fewest_rockets = w.total_kg, w.fewest
      if a.pack then
        out.pack = {rockets=w.rockets, fewest=w.fewest, split=w.split, too_heavy=w.too_heavy, lift=w.lift, note=w.note}
      end
      lines[#lines+1] = string.format('to send: %g kg, at least %d rocket%s by weight and slots%s', w.total_kg, w.fewest, w.fewest == 1 and '' or 's',
        a.pack and w.rockets and string.format('; pack: %d rockets, each within %s', w.rockets, w.lift) or ' (pack: true splits it into rockets)')
    end
    return out
  end
  -- platform_production {platform, item?} (D4, Astra ~10 times: ammo_rates covers only the last flight, and nothing read
  -- what a platform makes in orbit): the platform's own production statistics (its surface's, as the production GUI
  -- shows them), per item and fluid made or used: totals since it was built and the rate a minute over the last 1, 10
  -- and 60 minutes, made against used; the most made first.
  local WINDOWS = {{'one_minute', 1, '1m'}, {'ten_minutes', 10, '10m'}, {'one_hour', 60, '1h'}}
  -- (d24 batch171 QN1, Sol 15:09: Asterion's three explosives chemical plants read 39/min each in inspect, 117 in all,
  -- against 290 made a minute in the statistics; a cryogenic plant with 8 productivity module 3s, beside two beacons of
  -- speed module 3s, made explosives too, 207/min at full speed) with item: the crafting machines on the platform whose
  -- recipe makes it, each at full speed as inspect gives it (craftrate.lua), and their sum. MAKERS_SHOWN listed.
  local MAKERS_SHOWN = 12
  local function makers(pl, item)
    local rows, sum = {}, 0
    local found = try(function() return pl.surface.find_entities_filtered{type={'assembling-machine', 'furnace'}} end) or {}
    for _, e in ipairs(found) do
      -- the recipe's products first (an idle furnace: its last recipe); the rate only for a machine that makes it
      local recipe = try(function() return e.get_recipe() end)
      if not recipe then
        local prev = try(function() return e.previous_recipe end)
        recipe = prev and prev.name and try(function() return e.force.recipes[type(prev.name) == 'table' and prev.name.name or prev.name] end)
      end
      local makes = false
      for _, pr in ipairs(recipe and try(function() return recipe.products end) or {}) do makes = makes or pr.name == item end
      local rate = makes and api.craftrate and try(function() return api.craftrate(e) end)
      for _, pr in ipairs(rate and rate.products or {}) do
        if pr.name == item then
          sum = sum + pr.per_min
          rows[#rows+1] = {entity=e.name, quality=try(function() return e.quality.name end), position={x=e.position.x, y=e.position.y},
            recipe=rate.recipe, speed=rate.speed, productivity=rate.productivity, per_min=pr.per_min,
            status=api.status_name and try(function() return api.status_name(e) end) or nil,
            crafts=try(function() return e.products_finished end)}
        end
      end
    end
    table.sort(rows, function(x, y) if x.per_min ~= y.per_min then return x.per_min > y.per_min end
      if x.position.x ~= y.position.x then return x.position.x < y.position.x end return x.position.y < y.position.y end)
    local words = {}
    for i, r in ipairs(rows) do
      if i > MAKERS_SHOWN then words[#words+1] = string.format('+%d more', #rows - MAKERS_SHOWN); break end
      words[#words+1] = string.format('%s%s (%g,%g) %s %g/min (speed %g, productivity +%d%%%s)', r.entity,
        r.quality and r.quality ~= 'normal' and '@' .. r.quality or '', r.position.x, r.position.y, r.recipe, r.per_min,
        r.speed, math.floor(r.productivity * 100 + 0.5), r.status and ', ' .. r.status or '')
    end
    return rows, math.floor(sum * 10 + 0.5) / 10, words
  end
  function M.production(p, a)
    local pl = api.platform(p, a.platform)
    assert(pl.surface, 'platform ' .. pl.name .. ' has no surface yet')
    assert(a.item == nil or type(a.item) == 'string', 'item is an item or fluid name')
    -- (d18 batch39 C2) leg: the whole leg's delta from freight's samples (freight.lua leg_delta)
    if a.leg ~= nil then
      assert(a.leg == true, 'leg is true')
      local d = api.leg and api.leg(pl) or {lines={'no leg samples'}}
      d.platform = pl.name
      d.note = 'from the totals kept at each segment\'s start and end (thruster fuel and oxidizer: fluid statistics; ammunition: item statistics), cargo from the rockets launched to it and its cargo pods; read only'
      return d
    end
    local rows, lines = {}, {}
    for _, kind in ipairs({'item', 'fluid'}) do
      local stats = try(function() return kind == 'item' and p.force.get_item_production_statistics(pl.surface) or p.force.get_fluid_production_statistics(pl.surface) end)
      local names = {}
      for name in pairs(stats and stats.input_counts or {}) do names[name] = true end
      for name in pairs(stats and stats.output_counts or {}) do names[name] = true end
      for name in pairs(names) do
        if a.item == nil or a.item == name then
          -- (PX1) an item over every quality, the qualities named (made_by_quality, used_by_quality); a fluid by name
          local item = kind == 'item'
          local r
          if item then
            local m, mb = qflow.count_by(stats, name, 'input')
            local u, ub = qflow.count_by(stats, name, 'output')
            r = {name=name, kind=kind, made=math.floor(m + 0.5), used=math.floor(u + 0.5), made_by_quality=qflow.label(mb), used_by_quality=qflow.label(ub)}
          else r = {name=name, kind=kind, made=math.floor(stats.get_input_count(name) + 0.5), used=math.floor(stats.get_output_count(name) + 0.5)} end
          local function flow(cat, pi)
            if item then return qflow.flow(stats, name, cat, pi, true) end
            return stats.get_flow_count{name=name, category=cat, precision_index=pi, count=true}
          end
          for _, w in ipairs(WINDOWS) do
            local made = try(function() return flow('input', defines.flow_precision_index[w[1]]) end) or 0
            local used = try(function() return flow('output', defines.flow_precision_index[w[1]]) end) or 0
            r['made_per_min_' .. w[3]] = math.floor(made / w[2] * 10 + 0.5) / 10
            r['used_per_min_' .. w[3]] = math.floor(used / w[2] * 10 + 0.5) / 10
          end
          rows[#rows+1] = r
        end
      end
    end
    table.sort(rows, function(x, y) if x.made ~= y.made then return x.made > y.made end return x.name < y.name end)
    for i, r in ipairs(rows) do
      if i > 24 then lines[#lines+1] = string.format('+%d more (item: NAME reads one)', #rows - 24); break end
      lines[#lines+1] = string.format('%s: made %g/min, used %g/min (last 10 min); last 1 min %g/%g, last hour %g/%g; in all made %d, used %d',
        r.name, r.made_per_min_10m, r.used_per_min_10m, r.made_per_min_1m, r.used_per_min_1m, r.made_per_min_1h, r.used_per_min_1h, r.made, r.used)
    end
    local out_makers, full
    if a.item then
      local words
      out_makers, full, words = makers(pl, a.item)
      local made = rows[1] and rows[1].made_per_min_1m
      lines[#lines+1] = #out_makers == 0 and string.format('makers: no crafting machine on %s has a recipe that makes %s', pl.name, a.item)
        or string.format('makers: %d crafting machine%s on %s with a recipe that makes %s, %g/min together at full speed%s: %s', #out_makers,
          #out_makers == 1 and '' or 's', pl.name, a.item, full, made and string.format(' (made %g in the last minute)', made) or '', table.concat(words, '; '))
    end
    local where = api.where and try(function() return api.where(pl) end)
    return {platform=pl.name, where=where and where.text or nil, items=rows, makers=out_makers, makers_full_per_min=full,
      lines=#lines > 0 and lines or {'nothing made or used on ' .. pl.name .. (a.item and ' of ' .. a.item or '') .. ' in its statistics'},
      note='the platform\'s own production statistics (its surface), as the production GUI shows them: made counts what every machine on it made, productivity included; with item, makers lists the crafting machines whose recipe makes it, each at full speed as inspect gives it (inspect\'s rate is one machine alone); wait_until {until: produced, platform, item, at_least} waits for what it makes from now'}
  end
  M.schema = {platform_production = {platform='platform name', item='optional item or fluid name: that one only',leg='optional true: the whole leg instead: since the platform left its last stop to now (the leg and the stop after it so far), and while it is stopped the last full leg alone: thruster fuel and oxidizer and each ammunition made and used, cargo loaded (rockets launched to it) and dropped (its cargo pods), totals and a minute: lines, since_departure and last_leg {from, to, minutes, fuel, ammo, loaded, dropped}',
    returns='lines (the most made first), items [{name, kind, made, used (totals; an item\'s over every quality, made_by_quality and used_by_quality when not all normal), made_per_min_1m|10m|1h, used_per_min_1m|10m|1h}], where; with item, makers [{entity, quality, position, recipe, speed, productivity, per_min (at full speed, as inspect), status, crafts (products_finished)}] and makers_full_per_min, and a makers line; read only'},
    platform_bom = {platform='platform name (or surface)',surface='optional planet, without platform: every platform\'s active hub requests that import from it: requests [{platform, item, quality, asks, holds (at that quality), short, where}], lines (a line a platform with what it lacks)',
    request='optional true (A6): keep a hub section of its own (logistic group "platform_bom: NAME") asking for what the platform\'s ghosts still need, their module and other item requests and built machines\' too, less what its construction robots carry, one slot an item at a quality (as the ghosts need it; a normal item never covers a ghost of another quality) (import_from, default the planet it is at; area: only the ghosts there), read again every 10 s: lowered as they are built, removed with the last of them (each item keeps its slot from one rewrite to the next: one no longer needed is cleared where it stands, a new one takes a free slot); false removes it. Your other requests stay as they are. Returns lines (item, or item@quality past normal: request N from P (the ghosts need N; the hub holds H at that quality)), request, group, note',
    import_from='with request: the planet the items come from (default the one the platform is at)',
    tail='with request: optional true: an item\'s minimum payload is no more than what is still to come (its request less what the hub holds), so the last few go without a full batch; a slot with no custom minimum payload (the game\'s default, a full rocket by weight) is lowered the same way; kept until false. Each line says the minimum payload the slot has now',
    min_payload='with request: {item: N} (every quality of it) or {"item@quality": N}: the custom minimum payload of those items\' requests in the section (0 or false clears it); one set by min_payload on the section is kept through the rewrites too', area='with request: {left_top, right_bottom} or a list: only the ghosts there count',
    pack='optional true: the rest still to send split into rockets within a rocket\'s lift and cargo slots, heaviest items first, each into the first rocket with room (pack {rockets, fewest, split [{rocket, kg, slots, items}]}); load_silo {items, launch, platform} takes each rocket\'s list',
    returns='lines (one per item and quality, item@quality past normal, most still to send first, then the total), items [{item, quality, key (item, or item@quality past normal), ghosts_need (what the entity and tile ghosts there need of it at that quality), built (entities of it at that quality, or tiles, already built there), hub (held at that quality), hub_other_quality (the hub\'s stock of the item at other qualities: it builds none of these ghosts), in_flight (in cargo pods headed for this platform), requests (of ghosts_need: item requests, modules and the like, on entity ghosts and on item-request proxies of built machines), in_robots (carried by the platform\'s construction robots now), remaining (need less hub, in flight and in robots), asks (the hub\'s active requests)}], requests_check (with ghosts open: whether every item they still need has an active hub request) and unrequested (each item the ghosts still need, beyond the hub, in flight and in robots, that no active hub request asks for), entity_ghosts, tile_ghosts, pods_in_flight, remaining_kg, fewest_rockets. Read only'}}
  return M
end
