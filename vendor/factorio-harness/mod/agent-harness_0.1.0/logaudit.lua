-- logistics_audit {network | position} (d17 batch17 C2, Luna, shift29: paged 109 requester chests on Gleba to find 5
-- whose slots spoilage filled): every requester of one logistic network, ranked by what keeps its requests short, as
-- each chest's GUI and the network's show it now:
--   full     every slot taken, so a short item has no room: by items it does not request (spoilage named), or its own;
--   spoiled  spoilage it does not request holds slots, NEAR_FULL or fewer left (with more room, the summary names it);
--   waiting  a delivery on the way for WAIT ticks or more while it is still under its count (the networks watch);
--   not_sent short with the item free in providers or storage and nothing on the way;
--   shortage short and none of it free in the network.
-- The rest under their count have deliveries on the way under WAIT ticks (counted, not listed).
-- Each short or waiting item with the network's free count and the provider robots would take it from (the game's
-- pick: select_pickup_point), its position and distance. Characters' personal requests are left out.
-- Read only; bounded: LOOK requesters a call (from: the next ones), rows up to MAX_ROWS.
return function(api)
  local M = {}
  local LOOK, ROWS, MAX_ROWS, WAIT, NEAR_FULL, FAR_LOOK = 256, 12, 48, 18000, 4, 128
  local RANK = {full_unrequested=1, full=2, spoiled=3, waiting=4, not_sent=5, shortage=6}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local function dist(a, b) return math.floor(math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) + 0.5) end
  -- a filter's name and quality read as prototypes (userdata) on the live game, as tables in tests (Gemini 15:35: storage on
  -- network 410 failed concatenating a LuaItemPrototype)
  local function name_of(v) if type(v) == 'table' or type(v) == 'userdata' then return v.name end return v end
  local function span(t)
    local s = math.floor(t / 60)
    return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's'
  end
  local function key_of(name, quality) return quality ~= 'normal' and name .. '@' .. quality or name end

  -- The network: by id on the surface, else the one covering position (default: where you stand).
  local function network(p, a, surface)
    if a.network ~= nil then
      local want = tonumber(a.network)
      local ids = {}
      for _, ln in ipairs(try(function() return p.force.logistic_networks[surface.name] end) or {}) do
        if ln.network_id == want then return ln end
        ids[#ids+1] = '#' .. ln.network_id
      end
      error(string.format('no logistic network #%s of ours on %s (there: %s)', tostring(a.network), surface.name, #ids > 0 and table.concat(ids, ', ') or 'none'))
    end
    local pos = a.position or p.position
    pos = {x=tonumber(pos.x or pos[1]), y=tonumber(pos.y or pos[2])}
    assert(pos.x and pos.y, 'position must be {x, y}')
    local ln = try(function() return surface.find_logistic_network_by_position(pos, p.force) end)
    if not ln then error(string.format('no logistic network of ours covers %s on %s; give network (an id from networks)', at(pos), surface.name)) end
    return ln
  end

  -- What one requester point asks and holds: {e, asks [{item, quality, want, have, on_way, short}], holds, kind, ...}
  local function look(ln, pt, n, free, now)
    local e = try(function() return pt.owner end)
    if not (e and e.valid) or e.type == 'character' then return nil end
    local unit = e.unit_number
    local asks, named = {}, {}
    for _, f in ipairs(try(function() return pt.filters end) or {}) do
      local name, quality = name_of(f.name), name_of(f.quality) or 'normal'
      if name and (f.count or 0) > 0 then
        local k = key_of(name, quality)
        named[name] = true
        if asks[k] then asks[k].want = asks[k].want + f.count
        else asks[k] = {item=name, quality=quality ~= 'normal' and quality or nil, q=quality, want=f.count} end
      end
    end
    local coming = try(function() return pt.targeted_items_deliver end) or {}
    local inv = try(function() return e.get_inventory(defines.inventory.chest) end)
    local list = {}
    for k, x in pairs(asks) do
      x.have = try(function() return e.get_item_count{name=x.item, quality=x.q} end) or 0
      local on_way = 0
      if type(coming[x.item]) == 'number' then on_way = coming[x.item]
      else
        for _, c in pairs(coming) do
          if type(c) == 'table' and name_of(c.name) == x.item and (name_of(c.quality) or 'normal') == x.q then on_way = on_way + (c.count or 0) end
        end
      end
      x.on_way = on_way
      x.short = math.max(0, x.want - x.have - on_way)
      if x.have < x.want then
        local since = unit and n.waiting and n.waiting[unit .. '|' .. x.item .. '|' .. x.q]
        if on_way > 0 and since then x.waited = now - since end
        if x.short > 0 then
          local since2 = unit and n.unfilled and n.unfilled[unit .. '|' .. x.item .. '|' .. x.q]
          if since2 then x.unfilled = now - since2 end
        end
        if free[k] == nil then
          local s = try(function() return ln.get_supply_counts({name=x.item, quality=x.q}) end)
            or try(function() return ln.get_supply_counts(x.item) end) or {}
          free[k] = math.max(0, (s['active-provider'] or 0) + (s['passive-provider'] or 0)) + math.max(0, s.storage or 0)
        end
        x.free = free[k]
        list[#list+1] = x
      end
    end
    table.sort(list, function(a, b) if a.short ~= b.short then return a.short > b.short end return a.item < b.item end)
    local r = {e=e, asks=list}
    if #list == 0 then return r end
    -- What fills it: requested or not, spoilage among them.
    local holds, other, spoil, slots, empty = {}, 0, 0, nil, nil
    if inv then
      slots = #inv
      empty = try(function() return inv.count_empty_stacks() end)
      for _, c in ipairs(try(function() return inv.get_contents() end) or {}) do
        local nm, q = name_of(c.name), name_of(c.quality) or 'normal'
        holds[#holds+1] = {item=nm, quality=q ~= 'normal' and q or nil, count=c.count, requested=named[nm] or nil}
        if not named[nm] then other = other + c.count; if nm == 'spoilage' then spoil = spoil + c.count end end
      end
      table.sort(holds, function(a, b) return a.count > b.count end)
    end
    r.holds, r.slots, r.empty, r.spoilage, r.unrequested = holds, slots, empty, spoil, other
    -- Its block: the first that holds, in RANK order.
    local blocked = false
    if inv and empty == 0 then
      for _, x in ipairs(list) do
        if not try(function() return inv.can_insert{name=x.item, quality=x.q, count=1} end) then blocked = true; x.no_room = true end
      end
    end
    if blocked then r.kind = other > 0 and 'full_unrequested' or 'full'
    elseif spoil > 0 and (empty or 0) <= NEAR_FULL then r.kind = 'spoiled'
    else
      if spoil > 0 then r.spoil_room = true end
      for _, x in ipairs(list) do
        if x.waited and x.waited >= WAIT then r.kind = r.kind or 'waiting' end
      end
      if not r.kind then
        for _, x in ipairs(list) do
          if x.short > 0 and x.on_way == 0 and x.free > 0 then r.kind = 'not_sent'; break end
        end
      end
      if not r.kind then
        for _, x in ipairs(list) do if x.short > 0 and x.free == 0 then r.kind = 'shortage'; break end end
      end
    end
    return r
  end

  local function holds_text(r)
    local parts = {}
    for i, h in ipairs(r.holds or {}) do
      if i > 4 then parts[#parts+1] = string.format('+%d more', #r.holds - 4); break end
      parts[#parts+1] = string.format('%s %d%s', key_of(h.item, h.quality or 'normal'), h.count, h.requested and '' or h.item == 'spoilage' and ' (spoiled, not requested)' or ' (not requested)')
    end
    return #parts > 0 and table.concat(parts, ', ') or 'nothing'
  end
  local function ask_text(x)
    local parts = {string.format('has %d', x.have)}
    if x.on_way > 0 then parts[#parts+1] = string.format('%d on the way%s', x.on_way, x.waited and x.waited >= 3600 and ' for ' .. span(x.waited) or '') end
    if x.short > 0 and x.unfilled and x.unfilled >= 3600 then parts[#parts+1] = 'short ' .. span(x.unfilled) end
    if x.no_room then parts[#parts+1] = 'no room' end
    parts[#parts+1] = x.free > 0 and string.format('%d free in the network', x.free) or 'none free in the network'
    if x.from then parts[#parts+1] = string.format('robots take it from %s %s, %d tiles (holds %d)', x.from.name, at(x.from.position), x.from.distance, x.from.count) end
    return string.format('%s %d (%s)', key_of(x.item, x.q), x.want, table.concat(parts, ', '))
  end
  local HEAD = {full_unrequested='every slot taken, by items it does not request', full='every slot taken, by what it requests',
    spoiled='spoilage it does not request takes slots, 4 or fewer free', waiting='deliveries on the way 5+ min', not_sent='free in the network, nothing on the way',
    shortage='short in the network'}

  -- storage (d17 batch32 B7, Gemini: robots with no storage, the game's no_storage alert): the network's storage chests
  -- (free slots, filters), its robots holding cargo with no order to put it anywhere (what the alert names), the items
  -- they hold, and for each whether a storage chest of the network can take it now (a free slot, and no filter or a
  -- filter of that item). Read only; at most ROBOTS robots read.
  -- (world n, 11:15: building a network's robot list costs about 3 ms, then about 3 us a robot here: 2048 read 8.9 ms)
  local ROBOTS = 2048
  function M.storage(p, a, surface, ln)
    local chests, free, filtered, full = 0, 0, {}, 0
    local takers = {any=0, by={}}
    for _, c in ipairs(try(function() return ln.storages end) or {}) do
      if c.valid and c.type == 'logistic-container' then
        chests = chests + 1
        local inv = try(function() return c.get_inventory(defines.inventory.chest) end)
        local empty = inv and (try(function() return inv.count_empty_stacks() end) or 0) or 0
        free = free + empty
        if empty == 0 then full = full + 1 end
        local f = try(function() return c.storage_filter end)
        local fname = f and name_of(f.name or f)
        if fname then
          filtered[fname] = (filtered[fname] or 0) + 1
          if empty > 0 then takers.by[fname] = (takers.by[fname] or 0) + 1 end
        elseif empty > 0 then takers.any = takers.any + 1 end
      end
    end
    local stuck, items, read = 0, {}, 0
    for _, list in ipairs({'logistic_robots', 'construction_robots'}) do
      for _, r in ipairs(try(function() return ln[list] end) or {}) do
        if read >= ROBOTS then break end
        read = read + 1
        local inv = try(function() return r.get_inventory(defines.inventory.robot_cargo) end)
        if inv and not try(function() return inv.is_empty() end) and #(try(function() return r.robot_order_queue end) or {}) == 0 then
          stuck = stuck + 1
          for _, st in ipairs(try(function() return inv.get_contents() end) or {}) do items[st.name] = (items[st.name] or 0) + st.count end
        end
      end
    end
    local item_lines = {}
    for name, n in pairs(items) do
      local can = takers.any + (takers.by[name] or 0)
      item_lines[#item_lines+1] = string.format('%s %d: %s', name, n, can > 0 and string.format('%d storage chest%s can take it', can, can == 1 and '' or 's')
        or (filtered[name] and 'its filtered storage chests are full and no unfiltered one has room' or 'no storage chest has room for it (a free slot, unfiltered or filtered to it)'))
    end
    table.sort(item_lines)
    local fl = {}
    for name, n in pairs(filtered) do fl[#fl+1] = name .. ' ' .. n end
    table.sort(fl)
    local line = string.format('logistic network #%d on %s: %d storage chest%s, %d free slots%s%s; %d robot%s hold cargo with nowhere to put it%s',
      ln.network_id, surface.name, chests, chests == 1 and '' or 's', free, full > 0 and string.format(' (%d full)', full) or '',
      #fl > 0 and ', filtered: ' .. table.concat(fl, ', ') or '', stuck, stuck == 1 and '' or 's',
      #item_lines > 0 and ': ' .. table.concat(item_lines, '; ') or '')
    return {network=ln.network_id, surface=surface.name, storage_chests=chests, free_slots=free, full_chests=full, filtered=#fl > 0 and fl or nil,
      robots_stuck=stuck, stuck_items=#item_lines > 0 and item_lines or nil, robots_read=read, line=line}
  end
  function M.read(p, a)
    a = a or {}
    local surface = (a.surface or a.platform) and api.surface_named and api.surface_named(p.force, a) or p.surface
    local ln = network(p, a, surface)
    if a.storage ~= nil then
      assert(a.storage == true, 'storage is true')
      return M.storage(p, a, surface, ln)
    end
    local n = (api.state() or {}).networks or {}
    local now = game.tick
    local points = try(function() return ln.requester_points end) or {}
    local from = math.max(1, math.floor(tonumber(a.from) or 1))
    local last = math.min(#points, from + LOOK - 1)
    local free, rows, counts, ok, looked, coming, rotten, all = {}, {}, {}, 0, 0, 0, {}, {}
    for i = from, last do
      local r = look(ln, points[i], n, free, now)
      if r then
        looked = looked + 1
        all[#all+1] = r
        if r.kind then counts[r.kind] = (counts[r.kind] or 0) + 1; rows[#rows+1] = r
        elseif #r.asks > 0 then coming = coming + 1
        else ok = ok + 1 end
        if r.spoil_room then rotten[#rotten+1] = string.format('%s spoilage %d', at(r.e.position), r.spoilage) end
      end
    end
    local function age(r) local m = 0; for _, x in ipairs(r.asks) do m = math.max(m, x.waited or 0, x.unfilled or 0) end; return m end
    table.sort(rows, function(x, y)
      if RANK[x.kind] ~= RANK[y.kind] then return RANK[x.kind] < RANK[y.kind] end
      local ax, ay = age(x), age(y)
      if ax ~= ay then return ax > ay end
      return x.e.unit_number < y.e.unit_number
    end)
    local limit = math.min(MAX_ROWS, math.max(1, math.floor(tonumber(a.limit) or ROWS)))
    local here = p.surface == surface and p.position
    local out, lines = {}, {}
    for i = 1, math.min(limit, #rows) do
      local r = rows[i]
      local pos = r.e.position
      for _, x in ipairs(r.asks) do
        if x.short > 0 or x.waited then
          local pick = x.free > 0 and try(function() return ln.select_pickup_point{name={name=x.item, quality=x.q}, position=pos} end)
          local o = pick and try(function() return pick.owner end)
          if o and o.valid then x.from = {name=o.name, position=o.position, distance=dist(o.position, pos), count=o.get_item_count{name=x.item, quality=x.q}} end
        end
      end
      local asks = {}
      for _, x in ipairs(r.asks) do
        asks[#asks+1] = {item=x.item, quality=x.quality, want=x.want, have=x.have, on_way=x.on_way, short=x.short, free=x.free,
          waited_s=x.waited and math.floor(x.waited / 60) or nil, short_s=x.unfilled and math.floor(x.unfilled / 60) or nil,
          no_room=x.no_room, from=x.from}
      end
      local texts = {}
      for j, x in ipairs(r.asks) do if j <= 4 then texts[j] = ask_text(x) end end
      local d = here and dist(here, pos)
      out[#out+1] = {name=r.e.name, position=pos, distance=d, block=r.kind, asks=asks, slots=r.slots, empty_slots=r.empty,
        spoilage=r.spoilage > 0 and r.spoilage or nil, unrequested=r.unrequested > 0 and r.unrequested or nil, holds=r.holds}
      local fill = ''
      if r.kind == 'full_unrequested' or r.kind == 'full' or r.kind == 'spoiled' then
        fill = string.format(' (%d of %d slots: %s)', (r.slots or 0) - (r.empty or 0), r.slots or 0, holds_text(r))
      end
      lines[#lines+1] = string.format('%s %s%s: %s%s; asks %s%s', r.e.name, at(pos), d and string.format(', %d tiles', d) or '', HEAD[r.kind], fill,
        table.concat(texts, '; '), #r.asks > 4 and string.format('; +%d more', #r.asks - 4) or '')
    end
    local tally = {}
    for _, k in ipairs({'full_unrequested', 'full', 'spoiled', 'waiting', 'not_sent', 'shortage'}) do
      if counts[k] then tally[#tally+1] = string.format('%d %s', counts[k], k) end
    end
    local more = last < #points and last + 1 or nil
    local summary = string.format('logistic network #%d on %s: %d requesters looked at%s; %d blocked: %s; %d under their count with deliveries on the way under 5 min; %d filled%s',
      ln.network_id, surface.name, looked, from > 1 and string.format(' (from %d)', from) or '', #rows, #tally > 0 and table.concat(tally, ', ') or 'none', coming, ok,
      more and string.format('; %d more requesters: from %d', #points - last, more) or '')
    if #rotten > 0 then
      summary = summary .. string.format('; %d more hold spoilage they do not request, with room left: %s%s', #rotten,
        table.concat(rotten, ', ', 1, math.min(6, #rotten)), #rotten > 6 and ', ...' or '')
    end
    -- (d17 batch34 B3, Opus: 20 old requesters had pulled ore 500 tiles for 20 hours) requesters served from far: each
    -- ask short or with a delivery on the way, whose pickup the network would pick now (select_pickup_point) lies more
    -- than `far` tiles off (default 200); the first FAR_LOOK asks read
    local far_tiles = math.max(1, math.floor(tonumber(a.far) or 200))
    local far, asked = {}, 0
    for _, r in ipairs(all) do
      for _, x in ipairs(r.asks or {}) do
        if ((x.short or 0) > 0 or (x.on_way or 0) > 0) and (x.free or 0) > 0 and asked < FAR_LOOK then
          asked = asked + 1
          local pos = r.e.position
          local pick = try(function() return ln.select_pickup_point{name={name=x.item, quality=x.q}, position=pos} end)
          local o = pick and try(function() return pick.owner end)
          local d = o and o.valid and dist(o.position, pos)
          if d and d > far_tiles and #far < 16 then
            far[#far+1] = string.format('%s %s asks %s (%d on the way, %d short): robots would take it from %s %s, %d tiles away', r.e.name, at(pos), x.item,
              x.on_way or 0, x.short or 0, o.name, at(o.position), d)
          end
        end
      end
    end
    if #far > 0 then summary = summary .. string.format('; %d ask%s served from over %d tiles away (far)', #far, #far == 1 and '' or 's', far_tiles) end
    return {far=#far > 0 and far or nil, network=ln.network_id, surface=surface.name, looked=looked, blocked=#rows, coming=coming, filled=ok, counts=counts, requesters=out,
      shown=#out, lines=lines, summary=summary, next_from=more}
  end
  M.schema = {logistics_audit = {storage='optional true: the network\'s storage room instead (the no_storage alert): storage chests, free slots, full ones, filters; robots holding cargo with no order to put it anywhere (logistic and construction, 2048 read) and their items, each with whether a storage chest can take it now: network, storage_chests, free_slots, full_chests, filtered, robots_stuck, stuck_items, line',network='optional logistic network id (networks lists them)', position='optional {x, y}: the network covering it (default: where you stand)',
    surface='optional surface name (default yours)', limit='optional rows, default 12, up to 48', from='optional: start at this requester (next_from of the last call)',far='optional tiles (default 200): far lists each ask short or with a delivery on the way whose pickup the network would pick now lies farther off (the first 128 asks read, 16 lines)',
    returns='every requester of the network (256 a call; next_from for more) by what keeps it short, worst first: full_unrequested (every slot taken while a short item has no room, by items it does not request; spoilage named), full (the same, by its own items), spoiled (spoilage it does not request takes slots, 4 or fewer free; with more room the summary names them), waiting (a delivery on the way 5+ min while under its count), not_sent (short, the item free in providers or storage, nothing on the way), shortage (short, none free in the network); the rest under their count have deliveries on the way under 5 min (coming). requesters [{name, position, distance, block, asks [{item, want, have, on_way, short, free, waited_s, short_s, no_room, from {name, position, distance, count}: the provider robots would take it from}], slots, empty_slots, spoilage, unrequested, holds}], counts, blocked, coming, filled, lines, summary, far (requesters served from over far tiles away: the ask, on the way, short, the chest robots would take it from and how far). Characters left out. Read only'}}
  return M
end
