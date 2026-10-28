-- shipment {platform | item} (d17 batch15 Group B, Sol request #614 and 08:04, Astra 07:58 and 08:05): one read across
-- the native systems a shipment goes through, as their GUIs show them; nothing here moves or decides anything.
-- Per stop of a platform's schedule (its station, waiting there or not, the departure conditions with what the hub holds):
-- - up: each hub request that imports from that planet, with its state: delivered (the hub holds the minimum), in flight
--   (a rocket's pod coming down onto the platform), launched (a rocket's pod still rising over the planet), loading (a
--   silo there fills a rocket for this platform with it, or logistic robots bring it to one), else waiting, with the
--   native gate that holds it now: the platform not stopped there, no silo with automatic requests, or the silo's
--   request flag (hub_full, below_min_payload, split_networks, matched, filling);
-- - down: what that planet's landing pads ask of the hub now (cargo the hub keeps for a later stop), and at the last
--   visit what pads received and what landed with no pad (spilled, where the container stands).
-- shipment {item}: the same rows for that item over every platform.
-- One fact line goes to the loader (who last launched to the platform) and those the platform's alerts go to when a
-- request is delivered, when cargo spills, and when a hub_full gate appears (M.tick, every 10 s).
-- Read only. Bounded: 16 platforms, 8 stops, 24 requests a stop shown.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- (d22 batch110 BT1) a property read or a method call under pcall with no closure made (shipment.tick read each
  -- platform's requests, silos and rockets through a new closure at every read)
  local function get(o, k) return o[k] end
  local function pget(o, k) if o == nil then return nil end local ok, v = pcall(get, o, k); if ok then return v end end
  local function pcall_method(o, k, ...)
    if o == nil then return false end
    local ok, f = pcall(get, o, k)
    if not (ok and f) then return false end
    return pcall(f, ...)
  end
  local function call(f, ...) local ok, v = pcall(f, ...); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local function ago(t) local s = math.floor(t / 60); return s < 120 and s .. 's' or string.format('%dm%02ds', math.floor(s / 60), s % 60) end
  local function items_text(t)
    local list = {}
    for n, c in pairs(t or {}) do if c > 0 then list[#list+1] = (n:gsub('@normal$', '')) .. '*' .. c end end
    table.sort(list)
    return #list > 0 and table.concat(list, ' ') or nil
  end
  -- (d22 batch91 BA1, Sol #1881: Meridian-V's thruster@legendary request read "normal thruster 0") a request's quality
  -- and comparator (its value {name, quality, comparator}; "=" when none), the qualities it takes, its label.
  local CMP = {['=']='=', ['>']='>', ['<']='<', ['>=']='>=', ['≥']='>=', ['<=']='<=', ['≤']='<=', ['!=']='!=', ['≠']='!='}
  local function qname(x) return type(x) == 'string' and x or type(x) == 'table' and x.name or 'normal' end
  -- (d25 batch198 QK1) a planet's landing pads' ask and hold by "name@quality" (freight.lua pads; a reader without
  -- qualities: normal), and such a table by name
  local function pads_q(planet, force)
    local a, h = api.pads(planet, force, true)
    local function norm(t) local out = {}; for k, v in pairs(t or {}) do out[k:find('@', 1, true) and k or k .. '@normal'] = v end; return out end
    return norm(a), norm(h)
  end
  local function by_name(t)
    local out = {}
    for k, v in pairs(t) do local n = k:match('^(.*)@[^@]*$') or k; out[n] = (out[n] or 0) + v end
    return out
  end
  local function takes(q, cmp)
    if cmp == '=' then return {q} end
    local qs = pget(prototypes, 'quality')
    local lv = pget(pget(qs, q), 'level')
    local out = {}
    for name, pq in pairs(qs or {}) do
      local l = pget(pq, 'level')
      if lv and l and name ~= 'quality-unknown' and ((cmp == '>' and l > lv) or (cmp == '<' and l < lv) or (cmp == '>=' and l >= lv)
          or (cmp == '<=' and l <= lv) or (cmp == '!=' and l ~= lv)) then out[#out+1] = name end
    end
    return out
  end
  local function label(name, q, cmp)
    if q == 'normal' and cmp == '=' then return name end
    return string.format('%s (%s%s)', name, cmp ~= '=' and cmp .. ' ' or '', q)
  end
  -- t by "name@quality": the sum over the qualities a request takes
  local function of(t, name, q, cmp)
    if cmp == '=' then return t[name .. '@' .. q] or 0 end  -- (BT1: takes' one-quality list, a table each call)
    local n = 0
    for _, qn in ipairs(takes(q, cmp)) do n = n + (t[name .. '@' .. qn] or 0) end
    return n
  end
  -- The hub's requests by the planet they import from: {planet = {key = {item, quality, comparator, min, custom_minimum}}}
  -- ('any' when none is set); key "name@quality" (a comparator other than "=" added).
  local function requests(pl)
    local out = {}
    local oks, secs = pcall_method(pget(pl, 'hub'), 'get_logistic_sections')
    if not oks then secs = nil end
    local get_section = secs and pget(secs, 'get_section')
    for i = 1, secs and secs.sections_count or 0 do
      local ok, sec = false, nil
      if get_section then ok, sec = pcall(get_section, i) end
      if not ok then sec = nil end
      if sec and sec.active ~= false then
        for _, f in ipairs(pget(sec, 'filters') or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or pget(f.import_from, 'name')) or 'any'
          if type(name) == 'string' and (f.min or 0) > 0 then
            local q = type(v) == 'table' and qname(v.quality) or 'normal'
            local cmp = CMP[type(v) == 'table' and type(v.comparator) == 'string' and v.comparator or '='] or '='
            local key = name .. '@' .. q .. (cmp ~= '=' and cmp or '')
            out[from] = out[from] or {}
            local r = out[from][key] or {item=name, quality=q, comparator=cmp, min=0, max=0, custom_minimum=f.minimum_delivery_count}
            r.min, r.max = r.min + f.min, r.max + (f.max or math.huge)
            out[from][key] = r
          end
        end
      end
    end
    return out
  end
  -- what a silo's rocket holds and what robots bring it, by "name@quality"
  local function rocket_cargo(e)
    local ok, inv = false, nil
    if defines.inventory.rocket_silo_rocket then ok, inv = pcall_method(e, 'get_inventory', defines.inventory.rocket_silo_rocket) end
    local okc, list = false, nil
    if ok and inv then okc, list = pcall_method(inv, 'get_contents') end
    local out = {}
    for _, r in ipairs(okc and list or {}) do local k = r.name .. '@' .. qname(r.quality); out[k] = (out[k] or 0) + r.count end
    return out
  end
  local function bringing(e)
    local out = {}
    local ok, pts = pcall_method(e, 'get_logistic_point')
    if not ok then pts = nil end
    if pts and pts.object_name then pts = {pts} end
    for _, pt in pairs(pts or {}) do
      for _, it in ipairs(pget(pt, 'targeted_items_deliver') or {}) do local k = it.name .. '@' .. qname(it.quality); out[k] = (out[k] or 0) + (it.count or 0) end
    end
    return out
  end
  -- A planet's silos for a platform, read once a call: {list = [{e, auto, target, cargo, coming, rows}], flags = {item =
  -- row}, pads}. (d22 batch110 BT1: shipment.tick read every silo of every planet in the platform's schedule, each
  -- auto silo's request_rows (every platform of the force, the networks' stock), 438 KB a call on a copy of world n)
  -- Each part is read when a row first needs it and kept for the call: the silos when a request from that planet is
  -- looked at, a silo's rocket cargo and robots' deliveries (cargo_of, coming_of) when a request is not delivered or in
  -- flight, the request flags (row_of: each auto silo's request_rows) when a request waits at the planet the platform
  -- is stopped at, the pads (pads_of) for the ready read. The same reads as before, of the same entities.
  local function silos_at(cache, force, planet, platform)
    local key = planet .. '|' .. platform
    if cache[key] then return cache[key] end
    local s = pget(pget(game.planets, planet), 'surface')
    local out = {list={}, force=force, platform=platform}
    -- the surface's silos, found once a minute (a whole-surface search: 5-8 ms on the copy of world n), kept in storage
    local sc = api.state(); sc.shipment_silos = sc.shipment_silos or {}
    local c = s and sc.shipment_silos[s.index]
    -- (batch31 B1) the landing pads too, in the same search
    if s and not (c and game.tick - c.tick < 3600 and c.pads) then
      c = {tick=game.tick, list={}, pads={}}
      -- (d19 batch44 A2) the census pass's silos and pads of ours when it has them (the find was 10.6 ms on the private
      -- copy's Nauvis)
      local known = api.census_typed and try(function() return api.census_typed(force, s, {'rocket-silo', 'cargo-landing-pad'}) end)
      for _, e in ipairs(known or try(function() return s.find_entities_filtered{type={'rocket-silo', 'cargo-landing-pad'}} end) or {}) do
        table.insert(e.type == 'rocket-silo' and c.list or c.pads, e)
      end
      sc.shipment_silos[s.index] = c
    end
    out.found = c
    for _, e in ipairs(c and c.list or {}) do
      if e.valid and e.force == force then
        local t = pget(e, 'transitional_request_target')
        out.list[#out.list+1] = {e=e, auto=pget(e, 'use_transitional_requests') == true, target=t and pget(t, 'valid') and pget(t, 'name') or nil}
      end
    end
    cache[key] = out
    return out
  end
  local function cargo_of(x)
    if not x.cargo then x.cargo = rocket_cargo(x.e) end
    return x.cargo
  end
  local function coming_of(x)
    if not x.coming then x.coming = bringing(x.e) end
    return x.coming
  end
  -- an auto silo's request_rows for the platform (nil for a silo without automatic requests)
  local function rows_of(sil, x)
    if x.rows == nil and x.auto and api.request_rows then
      x.rows = try(function() return api.request_rows(x.e, sil.force, sil.platform) end) or {}
    end
    return x.rows
  end
  local function pads_of(sil)
    if not sil.pads then
      sil.pads = {}
      for _, e in ipairs(sil.found and sil.found.pads or {}) do if e.valid and e.force == sil.force then sil.pads[#sil.pads+1] = e end end
    end
    return sil.pads
  end
  -- (d26 batch223 QAG1, Astra 02:09: Kestrel II's uranium-rounds-magazine read "split_networks ... the silo's network can
  -- give 0 ... other networks: network 96 holds 700" from Fulgora's first silo (network 840) while the other silo, in
  -- network 96, read matched) one request judged at each silo of ours on the planet: its own request row (an auto silo,
  -- the platform stopped there), else its network's stock against the payload a rocket waits for (the request's min
  -- payload, else a full rocket by weight). Read once a silo a call: its parts, its network, its rows by item.
  local function parts_of(x)
    if x.parts == nil then
      local n, req = pget(x.e, 'rocket_parts'), pget(pget(x.e, 'prototype'), 'rocket_parts_required')
      x.parts = n and req and (n .. '/' .. req) or false
    end
    return x.parts or nil
  end
  local function net_of(sil, x)
    if x.net == nil then
      local ok, ln = pcall_method(pget(x.e, 'surface'), 'find_logistic_network_by_position', pget(x.e, 'position'), sil.force)
      x.net = ok and ln or false
    end
    return x.net or nil
  end
  local function can_give(ln, item, qa, cmp)
    local n = 0
    for _, qn in ipairs(cmp == '=' and {qa} or takes(qa, cmp)) do
      local ok, c = pcall_method(ln, 'get_item_count', qn == 'normal' and item or {name=item, quality=qn})
      if ok and type(c) == 'number' then n = n + c end
    end
    return math.max(0, n)
  end
  local function payload_of(item, custom)
    if custom then return custom end
    local w = pget(pget(pget(prototypes, 'item'), item), 'weight')
    local lift = pget(pget(prototypes, 'utility_constants'), 'rocket_lift_weight')
    return w and lift and w > 0 and math.floor(lift / w) or nil
  end
  local function row_of(sil, x, key)
    if not x.by_key then
      x.by_key = {}
      for _, r in ipairs(rows_of(sil, x) or {}) do
        local k = r.item .. '@' .. (r.quality or 'normal') .. ((r.comparator or '=') ~= '=' and r.comparator or '')
        if r.platform == sil.platform and not x.by_key[k] then x.by_key[k] = r end
      end
    end
    return x.by_key[key]
  end
  local CAN = {matched=true, filling=true}
  -- [{name, position, auto, network, can_give, payload, parts, flag, can_fill, row}]: those that can fill it first, then by
  -- what their networks can give
  local function judge(sil, item, qa, cmp, custom, here)
    local key = item .. '@' .. qa .. (cmp ~= '=' and cmp or '')
    local list, payload = {}, nil
    for i, x in ipairs(sil.list) do
      local pos = pget(x.e, 'position') or {x=0, y=0}
      local s = {i=i, name=x.e.name, position={x=pos.x, y=pos.y}, auto=x.auto, parts=parts_of(x)}
      local r = here and x.auto and row_of(sil, x, key)
      if r then
        s.row, s.flag = r, r.flag or (r.line and r.line:match('^([%w_]+):'))
        s.network, s.can_give, s.payload = r.network, r.network_holds, r.payload
        s.can_fill = CAN[s.flag] or false
      else
        local ln = net_of(sil, x)
        s.network = ln and pget(ln, 'network_id') or nil
        s.can_give = ln and can_give(ln, item, qa, cmp) or 0
        if payload == nil then payload = payload_of(item, custom) or false end
        s.payload = payload or nil
        s.can_fill = x.auto and s.payload ~= nil and s.can_give >= s.payload or false
      end
      list[#list+1] = s
    end
    table.sort(list, function(a, b)
      if a.can_fill ~= b.can_fill then return a.can_fill end
      if (a.can_give or 0) ~= (b.can_give or 0) then return (a.can_give or 0) > (b.can_give or 0) end
      return a.i < b.i
    end)
    return list
  end
  -- silos sharing a network and a verdict said once: "<verdict> (network N can give C, <payload>): silo (x,y) parts p, ..."
  local function verdict(s, pl_name, here)
    if not s.auto then return 'automatic requests off (a load_silo or a launch by hand sends it)' end
    if s.can_fill then return (here or s.row) and 'can fill it' or 'can fill it once ' .. pl_name .. ' stops there' end
    if s.row then return 'cannot, ' .. tostring(s.flag) end
    return here and 'cannot (no request row of it read)' or 'cannot now'
  end
  local function silos_text(list, planet, pl_name, here)
    local groups, order = {}, {}
    for _, s in ipairs(list) do
      local v = verdict(s, pl_name, here)
      local net = s.network and string.format('network %d can give %d', s.network, s.can_give or 0) or 'in no logistic network'
      local pay = s.payload and ((s.can_give or 0) < s.payload and string.format(', under the %d a rocket waits for', s.payload)
        or string.format(', a rocket waits for %d', s.payload)) or ''
      local k = v .. ' (' .. net .. pay .. ')'
      if not groups[k] then groups[k] = {}; order[#order+1] = k end
      local g = groups[k]
      g[#g+1] = string.format('%s (%g,%g)%s', s.name, s.position.x, s.position.y, s.parts and ' parts ' .. s.parts or '')
    end
    local t = {}
    for _, k in ipairs(order) do t[#t+1] = k .. ': ' .. table.concat(groups[k], ', ') end
    return string.format('silos on %s for it%s: %s', planet, here and '' or ' (their networks\' stock now)', table.concat(t, '; '))
  end
  local function silos_rows(list)
    local out = {}
    for _, s in ipairs(list) do
      out[#out+1] = {name=s.name, position=s.position, auto=s.auto, network=s.network, can_give=s.can_give, payload=s.payload, parts=s.parts, flag=s.flag, can_fill=s.can_fill}
    end
    return out
  end
  -- the silo the game picked for the platform (false with none), and its position, read once a call
  local function picked_of(sil, name)
    if sil.picked == nil then
      sil.picked = false
      for _, x in ipairs(sil.list) do if x.auto and x.target == name then sil.picked = x; break end end
      if sil.picked then sil.picked_pos = sil.picked.e.position end
    end
    return sil.picked or nil, sil.picked_pos
  end
  -- One up request's state and line. q: the request {item, quality, comparator, custom_minimum}; counts: the hub's by
  -- "name@quality". (BA1) The silo the game picked: a silo there whose automatic requests fill a rocket for this
  -- platform now (its transitional_request_target), named in the row (picked_silo) and the waiting line.
  local function up_row(pl, planet, q, min, counts, here, sil, incoming, fast)
    local item, qa, cmp = q.item, q.quality or 'normal', q.comparator or '='
    local held = of(counts, item, qa, cmp)
    local name = label(item, qa, cmp)
    local row = {platform=pl.name, planet=planet, item=item, quality=qa, comparator=cmp, custom_minimum=q.custom_minimum, direction='up', min=min, hub=held}
    local picked, ppos = picked_of(sil, pl.name)
    if picked then row.picked_silo = {name=picked.e.name, position={x=ppos.x, y=ppos.y}} end
    if held >= min then
      row.state = 'delivered'
      row.line = string.format('%s %d from %s: delivered (the hub holds %d)', name, min, planet, held)
      return row
    end
    for _, r in ipairs(incoming or {}) do
      -- (a rocket's cargo is kept by name: its quality is not told apart)
      if (r.cargo[item] or 0) > 0 and (r.from == nil or r.from == planet or pget(pget(pget(game.planets, planet), 'surface'), 'name') == r.from) then
        row.state = r.down and 'in flight' or 'launched'
        row.line = string.format('%s %d from %s: %s (a rocket launched %s ago (%stick %d) carries %d%s; %s; the hub holds %d)', name, min, planet, row.state,
          ago(game.tick - r.tick), r.up and 'up #' .. r.up .. ', ' or '', r.tick, r.cargo[item], name ~= item and ' of any quality' or '',
          r.down and 'its pod comes down onto the platform' or 'its pod rises over ' .. planet, held)
        return row
      end
    end
    for _, x in ipairs(sil.list) do
      local inr, com = of(cargo_of(x), item, qa, cmp), of(coming_of(x), item, qa, cmp)
      if (inr > 0 or com > 0) and (x.target == pl.name or not x.auto) then
        row.state = 'loading'
        row.line = string.format('%s %d from %s: loading (%s at %s: %d in its rocket%s%s; the hub holds %d)', name, min, planet, x.e.name, at(x.e.position), inr,
          com > 0 and string.format(', logistic robots bring %d', com) or '', x.target == pl.name and ', automatic requests for this platform' or '', held)
        return row
      end
    end
    row.state = 'waiting'
    local gate
    if not here then
      gate = 'the platform is not stopped at ' .. planet
      -- (QAG1) the full read: each silo there by its network's stock (the tick reads none)
      if not fast then
        if #sil.list == 0 then gate = gate .. '; no rocket silo of ours on ' .. planet
        else
          local list = judge(sil, item, qa, cmp, q.custom_minimum, false)
          row.silos = silos_rows(list)
          gate = gate .. '; ' .. silos_text(list, planet, pl.name, false)
        end
      end
    else
      local auto = false
      for _, x in ipairs(sil.list) do if x.auto then auto = true end end
      if #sil.list == 0 then gate = 'no rocket silo of ours on ' .. planet
      else
        -- (BT1) the request rows read here alone: a request waiting at the planet the platform is stopped at, with auto
        -- silos. (QAG1) every silo's row, the gate led by one that can fill it
        local list = judge(sil, item, qa, cmp, q.custom_minimum, true)
        row.silos = silos_rows(list)
        local lead
        for _, s in ipairs(list) do if s.row then lead = s; break end end
        if not auto then gate = 'no silo on ' .. planet .. ' has automatic requests on (a load_silo or launch by hand sends it)'
        elseif lead then
          local line = lead.row.line or tostring(lead.flag)
          gate = string.format('%s at %s (%g,%g): %s', tostring(lead.flag), lead.name, lead.position.x, lead.position.y, (line:gsub('^[%w_]+: ', '', 1)))
        else gate = 'no silo reads a request of it' end
        gate = gate .. '; ' .. silos_text(list, planet, pl.name, true)
      end
      if auto then
        gate = gate .. (picked and string.format('; the game\'s pick: %s at %s is filling a rocket for %s now', picked.e.name, at(picked.e.position), pl.name)
          or string.format('; the game\'s pick: no silo on %s is filling a rocket for %s now', planet, pl.name))
      end
    end
    row.gate = gate
    row.line = string.format('%s %d from %s: waiting (the hub holds %d): %s', name, min, planet, held, gate)
    return row
  end
  -- Every row and line of one platform: {lines, rows}.
  -- fast (the tick): the states alone, no stop texts or pad asks. at: that planet's stop alone.
  -- (d22 batch110 BT1) fast makes no lines (its two callers, the tick and the ready read, take the rows alone): no
  -- planet's line, drops or receipt texts.
  local function key_order(a, b) return a < b end
  function M.platform(pl, cache, only, fast, at_planet)
    local lines, rows = {}, {}
    local sch = pget(pl, 'schedule')
    local records = sch and sch.records or {}
    local force = pl.force
    local stops = not fast and api.stops and call(api.stops, pl) or {}
    local reqs = requests(pl)
    local counts = api.hub_counts and call(api.hub_counts, pl) or {}
    local counts_q = api.hub_counts and call(api.hub_counts, pl, true) or {}
    -- (counts by name alone, from a reader without qualities: normal)
    if not next(counts_q) or not tostring(next(counts_q)):find('@', 1, true) then
      counts_q = {}
      for k, v in pairs(counts) do counts_q[k .. '@normal'] = v end
    end
    local inc = api.incoming and call(api.incoming, pl)
    local w = api.where and call(api.where, pl) or {}
    local segs = api.segments and call(api.segments, pl) or {}
    local planets, seen = {}, {}
    for i, r in ipairs(records) do if i <= 8 and r.station and not seen[r.station] then seen[r.station] = true; planets[#planets+1] = {i=i, name=r.station} end end
    for name in pairs(reqs) do if name ~= 'any' and not seen[name] then seen[name] = true; planets[#planets+1] = {name=name} end end
    for _, st in ipairs(planets) do
      local planet = st.name
      if at_planet and planet ~= at_planet then goto next_planet end
      local here = w.stopped and w.at == planet
      local parts = not fast and {} or nil
      -- (BT1) the planet's silos read when its first request is looked at (a stop no request imports from reads none)
      local sil
      local n = 0
      local keys = {}
      local mine = reqs[planet] or {}
      for key in pairs(mine) do keys[#keys+1] = key end
      table.sort(keys, key_order)
      for _, key in ipairs(keys) do
        local q = mine[key]
        if not only or q.item == only then
          n = n + 1
          sil = sil or silos_at(cache, force, planet, pl.name)
          local row = up_row(pl, planet, q, q.min, counts_q, here, sil, inc and inc.rows, fast)
          rows[#rows+1] = row
          if parts and n <= 24 then parts[#parts+1] = row.line end
        end
      end
      if parts and n > 24 then parts[#parts+1] = string.format('+%d more requests', n - 24) end
      -- down: what the planet's landing pads ask of the hub now, and the last visit's receipts and spills
      local ask, hold, ask_q, hold_q = {}, {}, {}, {}
      if api.pads and not fast then ask_q, hold_q = pads_q(planet, force); ask, hold = by_name(ask_q), by_name(hold_q) end
      -- (d24 batch142 PN1) its stop there with unloading off: the pads take nothing from the hub
      local F = api.freight and api.freight()
      local off, off_line
      if F and F.no_unload then off, off_line = F.no_unload(pl, planet) end
      if off then ask = {} end
      if parts and off_line then parts[#parts+1] = off_line end
      local down = {}
      -- (d25 batch198 QK1) what the hub gives up there to the pads asking by its sections for that planet
      -- (freight.lua hub_keeps_at, hub_gives; batch31 B6's sum of the mins went before PI1's maxes), each quality held
      -- against the rows and the pads' ask of that quality
      local asked = next(ask) ~= nil
      local keeps = F and F.hub_keeps_at and asked and F.hub_keeps_at(try(function() return pl.hub.get_logistic_sections() end), planet) or {}
      local byq = F and F.by_item and asked and F.by_item(counts_q) or {}
      local wants = F and F.wants and asked and F.wants(ask_q, hold_q) or {}
      for item, a in pairs(ask) do
        local want = a - (hold[item] or 0)
        local go
        if F and F.hub_gives then go = F.hub_gives(keeps, item, counts[item] or 0, wants[item] or want, false, byq[item]) else go = math.max(0, math.min(want, counts[item] or 0)) end
        if want > 0 and go > 0 and (not only or item == only) then
          down[#down+1] = string.format('%s %d (pads ask %d, hold %d)', item, go, a, hold[item] or 0)
          rows[#rows+1] = {platform=pl.name, planet=planet, item=item, direction='down', state=here and 'unloading' or 'aboard for ' .. planet, count=go}
        end
      end
      table.sort(down)
      if parts and #down > 0 then parts[#parts+1] = (here and 'the hub sends down to ' or 'aboard for the landing pads at ') .. planet .. ': ' .. table.concat(down, ', ') end
      for k = #segs, 1, -1 do
        local seg = segs[k]
        if seg.kind == 'stop' and seg.at == planet and seg.pods and not parts then
          -- (fast) the spills' rows alone
          local landed = seg.pods.landed
          if landed and not only then
            for name, c in pairs(landed.cargo or {}) do
              if c and c > 0 then rows[#rows+1] = {platform=pl.name, planet=planet, item=name, direction='down', state='spilled', count=c, at=landed.at} end
            end
          elseif landed then
            local c = landed.cargo and landed.cargo[only]
            if c and c > 0 then rows[#rows+1] = {platform=pl.name, planet=planet, item=only, direction='down', state='spilled', count=c, at=landed.at} end
          end
          break
        elseif seg.kind == 'stop' and seg.at == planet and seg.pods then
          local function pick(t) if not only then return t end; local o = {}; o[only] = t and t[only]; return o end
          local rc = seg.pods.received and items_text(pick(seg.pods.received.cargo))
          local sp = seg.pods.landed and items_text(pick(seg.pods.landed.cargo))
          local when = ago(game.tick - (seg.pods.last_tick or seg.start))
          if rc then parts[#parts+1] = string.format('landing pads received %s (the visit %s ago)', rc, when) end
          if sp then
            parts[#parts+1] = string.format('spilled: %s landed with no pad (%s), the visit %s ago', sp, table.concat(seg.pods.landed.at or {}, '; '), when)
            for name, c in pairs(pick(seg.pods.landed.cargo)) do
              if c and c > 0 then rows[#rows+1] = {platform=pl.name, planet=planet, item=name, direction='down', state='spilled', count=c, at=seg.pods.landed.at} end
            end
          end
          break
        end
      end
      -- (d17 batch34 A2, Astra, Luna) the platform's recent drops into a pad there, with what the pad showed after
      if parts then
        for _, d in ipairs(api.drops_taken and api.drops_taken({platform=pl.name, surface=planet, item=only, limit=2}) or {}) do
          parts[#parts+1] = d.verdict and d.verdict .. ': ' .. d.line or d.line
        end
        if #parts > 0 or not only then
          local head = st.i and (stops[st.i] or (st.i .. ' ' .. planet)) or (planet .. ' (not in the schedule)')
          lines[#lines+1] = string.format('%s: %s%s', pl.name, head, #parts > 0 and '; ' .. table.concat(parts, '; ') or '; no request imports from ' .. planet)
        end
      end
      ::next_planet::
    end
    return lines, rows
  end
  -- (Astra 09:20: Gleba's landing pads took all 500 processing units, 100 meant for Gleba and 400 for Aquilo) each item
  -- the hub holds that the landing pads of two or more coming stops ask for: what each stop's pads ask, in the order the
  -- schedule reaches them from where the platform is, and what the hub would have left after each at those asks.
  function M.conflicts(pl)
    local sch = try(function() return pl.schedule end)
    local records = sch and sch.records or {}
    if #records < 2 then return nil end
    local w = api.where and try(function() return api.where(pl) end) or {}
    local cur = sch.current or 1
    -- the stops in the order coming: waiting at the current stop, it first; else the one it flies to first
    local order, seen = {}, {}
    for k = 0, #records - 1 do
      local idx = (cur - 1 + k) % #records + 1
      local st = records[idx].station
      if st and not seen[st] then seen[st] = true; order[#order+1] = {i=idx, planet=st, here=w.stopped and w.at == st} end
    end
    local counts = api.hub_counts and try(function() return api.hub_counts(pl) end) or {}
    -- what the hub keeps at a stop: freight.lua hub_keeps_at (d24 batch137 PI1; batch31 B6's cases fit it: Swift at
    -- Nauvis kept its 501 magazines under 500..2000 from nauvis; Cinder at Nauvis sent all 85 foundation down under
    -- 50..inf from fulgora)
    local asks = {}
    local F0 = api.freight and api.freight()
    local byq = F0 and F0.by_item and F0.by_item(try(function() return api.hub_counts(pl, true) end)) or {}
    local held_of = {}
    for _, o in ipairs(order) do
      -- (d25 batch198 QK1) by item@quality: a pad's ask and a section's max are each for their own quality
      local ask, hold = {}, {}
      if api.pads then ask, hold = pads_q(o.planet, pl.force) end
      -- (d24 batch137 PI1) what the hub's sections for that planet keep (freight.lua hub_keeps_at): an infinite max
      -- keeps it all, a finite one sends down all above it
      local F = api.freight and api.freight()
      local keeps = F and F.hub_keeps_at(try(function() return pl.hub.get_logistic_sections() end), o.planet) or {}
      -- (d24 batch142 PN1) a stop with unloading off: its pads take nothing from the hub
      if F and F.no_unload and F.no_unload(pl, o.planet, o.i) then ask = {} end
      for key, a in pairs(ask) do
        local item, q = key:match('^(.*)@([^@]*)$')
        local want = a - (hold[key] or 0)
        -- (a reader without qualities: what it counts by name is normal)
        local held = byq[item] and byq[item][q] or not next(byq) and q == 'normal' and counts[item] or 0
        held_of[key] = held
        -- (d24 batch192 QAH1) a section's max is for its own quality: what the rows of that quality keep
        local k, keep = keeps[item], 0
        if F and F.hub_kept then keep, k = F.hub_kept(keeps, item, {[q]=held}) else keep = k and math.min(k.max, held) or 0 end
        if want > 0 and held - keep > 0 then
          asks[key] = asks[key] or {}
          table.insert(asks[key], {stop=o, want=want, ask=a, hold=hold[key] or 0, keep=keep, keep_text=F and F.keep_text(k)})
        end
      end
    end
    local lines = {}
    for key, list in pairs(asks) do
      if #list >= 2 then
        local left, parts = held_of[key], {}
        for _, x in ipairs(list) do
          local take = math.max(0, math.min(left - x.keep, x.want))
          left = left - take
          parts[#parts+1] = string.format('stop %d %s%s: its pads ask %d (hold %d)%s, %d go down there, %d left aboard',
            x.stop.i, x.stop.planet, x.stop.here and ' (here)' or '', x.ask, x.hold, x.keep > 0 and string.format(', its requests from %s keep %d (%s)', x.stop.planet, x.keep, tostring(x.keep_text)) or '', take, left)
        end
        lines[#lines+1] = string.format('cargo conflict on %s: the hub holds %d %s; %s', pl.name, held_of[key], (key:gsub('@normal$', '')), table.concat(parts, '; '))
      end
    end
    table.sort(lines)
    return #lines > 0 and lines or nil
  end
  -- shipment {platform, ready: true} (d17 batch31 B1, Luna 06:20: one compact platform/silo freight readiness read, with
  -- circuit-gate actuals, cargo pad free slots at descent and the silo's minimum-payload waiting reason): for the planet
  -- the platform stops at (else the stop it flies to, or planet): the platform's gate (platform_gate, a circuit wait with
  -- what the hub's wires read); each hub request from there not delivered with its state (the rows above); each silo of
  -- ours there (up to SILOS): its rocket, its automatic requests and why it waits (this platform's rows of silo's
  -- request_rows: the flag, the payload a rocket waits for, the network's stock, with what the rocket holds of it), and the circuit and logistic
  -- conditions of the inserters and loaders within FEED tiles (gates' rows, with what each reads now); the landing pads
  -- there (up to PADS): free slots each, and per item the hub would send down (the pads' asks less what they hold, beyond
  -- what the hub's requests from that planet keep) what the pads can take of it now and the slots it takes. Read only.
  local SILOS, PADS, FEED, GATED = 4, 8, 8, 16
  local FEED_TYPES = {'inserter', 'loader', 'loader-1x1'}
  function M.ready(p, pl)
    local lines, out = {}, {platform=pl.name}
    local g = api.gate and try(function() return api.gate(p, {platform=pl.name}) end)
    lines[#lines+1] = 'gate: ' .. (g and g.lines and g.lines[1] or '?')
    local w = api.where and try(function() return api.where(pl) end) or {}
    local sch = try(function() return pl.schedule end)
    local rec = sch and sch.records and sch.records[sch.current or 1]
    local planet = w.stopped and w.at or (rec and rec.station)
    if not (planet and game.planets[planet]) then
      lines[#lines+1] = 'no planet: the platform is not stopped at one and its schedule names none'
      return {lines=lines, platform=pl.name}
    end
    out.planet = planet
    local here = w.stopped and w.at == planet
    lines[#lines+1] = here and string.format('stopped at %s', planet) or string.format('not stopped at %s (%s): its silos load for it once it is, its pads take cargo then', planet, w.text or '?')
    -- (d18 batch37 B2) its item waits against each planet's stock and production rate
    for _, l in ipairs(api.wait_need and try(function() return api.wait_need(pl) end) or {}) do lines[#lines+1] = 'wait: ' .. l end
    -- up: the requests from there not delivered
    local cache = {}
    local _, rows = M.platform(pl, cache, nil, true, planet)
    local up, done = {}, 0
    for _, r in ipairs(rows) do
      if r.direction == 'up' and r.planet == planet then
        if r.state == 'delivered' then done = done + 1 elseif #up < 12 then up[#up+1] = r.line end
      end
    end
    lines[#lines+1] = string.format('up from %s: %s', planet, #up > 0 and table.concat(up, '; ') .. (done > 0 and string.format('; %d more delivered', done) or '')
      or (done > 0 and string.format('all %d requests delivered', done) or 'no hub request imports from ' .. planet))
    -- the silos there
    local sil = silos_at(cache, pl.force, planet, pl.name)
    out.silos = {}
    for i, x in ipairs(sil.list) do
      if i > SILOS then lines[#lines+1] = string.format('+%d more silos on %s', #sil.list - SILOS, planet); break end
      local e = x.e
      local parts = {}
      local rk = api.rocket and try(function() return api.rocket(e) end)
      parts[#parts+1] = rk and rk.rocket_now or '?'
      if x.auto then
        -- why it waits, this platform's requests alone: each with what the rocket holds of it
        local why = {}
        for _, r in ipairs(rows_of(sil, x) or {}) do
          if r.platform == pl.name and #why < 8 then why[#why+1] = string.format('%s; its rocket holds %d of it', r.line or r.item, of(cargo_of(x), r.item, r.quality or 'normal', r.comparator or '=')) end
        end
        local held = items_text(cargo_of(x))
        parts[#parts+1] = 'automatic requests on' .. (x.target and ', filling a rocket for ' .. x.target or ', no platform taken up now')
          .. (held and '; its rocket holds ' .. held or '')
          .. (#why > 0 and '; ' .. pl.name .. ' asks ' .. planet .. ' for what it lacks: ' .. table.concat(why, '; ')
            or (here and '; ' .. pl.name .. ' lacks nothing it asks ' .. planet .. ' for' or ''))
      else
        local held = items_text(cargo_of(x))
        parts[#parts+1] = 'automatic requests off (a load_silo or a launch by hand sends a rocket)' .. (held and '; its rocket holds ' .. held or '')
      end
      local gl, found = {}, {}
      local bb = e.bounding_box
      for _, f in ipairs(try(function() return e.surface.find_entities_filtered{area={{bb.left_top.x - FEED, bb.left_top.y - FEED}, {bb.right_bottom.x + FEED, bb.right_bottom.y + FEED}},
        type=FEED_TYPES, force=pl.force, limit=64} end) or {}) do
        if #found >= GATED then break end
        local gr = api.gate_row and try(function() return api.gate_row(f) end)
        if gr then found[#found+1] = gr; gl[#gl+1] = gr.line end
      end
      parts[#parts+1] = #gl > 0 and string.format('conditions within %d tiles: %s', FEED, table.concat(gl, '; ')) or string.format('no inserter or loader within %d tiles has a circuit or logistic condition', FEED)
      -- (d18 batch36 A2) what its rocket parts lack that this platform's hub holds
      local need = api.launch_need and try(function() return api.launch_need(pl, {e}) end)
      if need then parts[#parts+1] = table.concat(need, '; ') end
      lines[#lines+1] = string.format('silo %s %s: %s', e.name, at(e.position), table.concat(parts, '; '))
      out.silos[#out.silos+1] = {position={x=e.position.x, y=e.position.y}, auto=x.auto, rocket_ready=rk and rk.rocket_ready or nil, gates=#found > 0 and found or nil}
    end
    if #sil.list == 0 then lines[#lines+1] = 'no rocket silo of ours on ' .. planet end
    -- down: the landing pads there
    local pads = pads_of(sil)
    local counts = api.hub_counts and try(function() return api.hub_counts(pl) end) or {}
    -- (d24 batch137 PI1, Sol #2107: "would send 1776" calcite while calcite 200..inf from nauvis kept all 1980) what the
    -- hub gives up there by its sections for that planet (freight.lua hub_keeps_at, hub_gives)
    local F = api.freight and api.freight()
    local keeps = F and F.hub_keeps_at(try(function() return pl.hub.get_logistic_sections() end), planet) or {}
    -- (d24 batch142 PN1) its stop there with unloading off: the pads take nothing, a finite max still sends down
    local off, off_line
    if F and F.no_unload then off, off_line = F.no_unload(pl, planet) end
    out.no_unload = off_line
    -- what the pads ask (their active sections' minimums) and hold, as freight's pads reads them
    -- (d25 batch198 QK1) and by item@quality: a pad's ask is for its own quality
    local ask, hold, invs, ask_q, hold_q = {}, {}, {}, {}, {}
    for i, pad in ipairs(pads) do
      local ls = try(function() return pad.get_logistic_sections() end)
      for k = 1, ls and ls.sections_count or 0 do
        local sec = try(function() return ls.get_section(k) end)
        for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          if type(name) == 'string' and (f.min or 0) > 0 then
            ask[name] = (ask[name] or 0) + f.min
            local key = name .. '@' .. qname(type(v) == 'table' and v.quality)
            ask_q[key] = (ask_q[key] or 0) + f.min
          end
        end
      end
      local inv = defines.inventory.cargo_landing_pad_main and try(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
      for _, x in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
        hold[x.name] = (hold[x.name] or 0) + x.count
        local key = x.name .. '@' .. qname(x.quality)
        hold_q[key] = (hold_q[key] or 0) + x.count
      end
      invs[i] = inv or false
    end
    if #pads == 0 then lines[#lines+1] = 'no landing pad of ours on ' .. planet .. ': what the hub drops there lands with no pad'
    else
      local free, pl_parts = 0, {}
      for i, pad in ipairs(pads) do
        if i > PADS then break end
        local inv = invs[i]
        local f = inv and try(function() return inv.count_empty_stacks(true, false) end) or 0
        free = free + f
        local bar = inv and try(function() return inv.get_bar() end)
        pl_parts[#pl_parts+1] = string.format('%s %s %d free slots of %d%s', pad.name, at(pad.position), f, inv and #inv or 0,
          bar and inv and bar <= #inv and string.format(' (bar: %d usable)', bar - 1) or '')
      end
      local down, slots, kept = {}, 0, {}
      local names, named = {}, {}
      for item in pairs(ask) do names[#names+1] = item; named[item] = true end
      -- a finite max sends down what the hub holds above it, asked or not
      -- (QAH1) a section's max is for its own quality
      local byq = F and F.by_item and F.by_item(try(function() return api.hub_counts(pl, true) end)) or {}
      for item, k in pairs(keeps) do
        if not named[item] and (counts[item] or 0) > 0 and (byq[item] and F.hub_gives(keeps, item, counts[item], 0, false, byq[item]) > 0 or not byq[item] and k.max ~= math.huge and counts[item] > k.max) then names[#names+1] = item end
      end
      table.sort(names)
      out.down = {}
      local wants = F and F.wants and F.wants(ask_q, hold_q) or {}
      for _, item in ipairs(names) do
        local want = (ask[item] or 0) - (hold[item] or 0)
        local n, k = 0, nil
        if F then n, k = F.hub_gives(keeps, item, counts[item] or 0, wants[item] or want, off, byq[item]) else n = math.max(0, math.min(want, counts[item] or 0)) end
        if n == 0 and (k or off) and want > 0 and (counts[item] or 0) > 0 then
          kept[#kept+1] = string.format('%s: none of %d (%s; the pads ask %d, hold %d)', item, counts[item], k and F.keep_text(k) or 'unloading off', ask[item] or 0, hold[item] or 0)
        end
        if n > 0 then
          local stack = try(function() return prototypes.item[item].stack_size end) or 1
          local take = 0
          for _, inv in ipairs(invs) do if inv then take = take + (try(function() return inv.get_insertable_count(item) end) or 0) end end
          local need = math.ceil(n / stack)
          slots = slots + need
          down[#down+1] = string.format('%s %d (pads ask %d, hold %d%s; %d slots; the pads can take %d of it now%s)', item, n, ask[item] or 0, hold[item] or 0,
            k and string.format('; %s, and a finite max sends all above it down asked or not', F.keep_text(k)) or '', need, take,
            take < n and string.format(', %d short', n - take) or '')
          out.down[#out.down+1] = {item=item, count=n, slots=need, pads_take=take, keep=k and F.keep_text(k) or nil}
        end
      end
      lines[#lines+1] = string.format('landing pads on %s: %s%s; %s', planet, table.concat(pl_parts, ', '), #pads > PADS and ', ...' or '',
        #down > 0 and string.format('the hub would send down %s: %d slots in all, %d free%s', table.concat(down, ', '), slots, free, slots > free and ' (fewer)' or '')
        or off_line and 'the hub sends nothing down there' or 'the hub holds nothing the pads ask for beyond what its requests from ' .. planet .. ' keep')
        .. (#kept > 0 and '; kept aboard: ' .. table.concat(kept, '; ') or '') .. (off_line and '; ' .. off_line or '')
      out.pad_free_slots = free
    end
    out.lines = lines
    out.note = 'the platform\'s gate, the requests from that planet, its silos and landing pads as the game shows them now; a silo with automatic requests sends a rocket once it holds what the silo requests (on 2.0.77 a full rocket of the item, or the request\'s min payload); read only'
    return out
  end
  -- (d26 batch253 FP, #2365) freight: a set amount, full pickup or partial visits, against each pickup stop's waits
  -- and the hub's requests from there; read only
  function M.freight(p, a)
    local f = a.freight
    assert(type(f) == 'table' and type(f.item) == 'string' and (f.mode == 'full' or f.mode == 'partial') and type(a.platform) == 'string', 'freight is {item, amount, mode: full or partial, from?} with platform')
    local name, q = f.item:match('^([^@]+)@?(.*)$')
    q = q ~= '' and q or 'normal'
    assert(prototypes.item[name], 'freight.item is an item name')
    local n = api.integer(f.amount, nil, 1, 2^31, 'freight.amount')
    local pl
    for _, x in pairs(p.force.platforms) do if x.valid and x.name == a.platform then pl = x end end
    assert(pl, 'no platform of ours named ' .. a.platform)
    local reqs, warn, stops = requests(pl), {}, {}
    local function W(...) warn[#warn+1] = string.format(...) end
    for i, r in ipairs((pget(pl, 'schedule') or {}).records or {}) do
      local m = r.station and (reqs[r.station] or {})[name .. '@' .. q]
      if r.station and (f.from == r.station or not f.from and m) then
        local need, other, ors = nil, {}, false
        for k, w in ipairs(r.wait_conditions or {}) do
          ors = ors or k > 1 and w.compare_type == 'or'
          local c = type(w.condition) == 'table' and w.condition or {}
          local sig, cmp = c.first_signal or {}, CMP[c.comparator or '<']
          if w.type == 'item_count' and sig.name == name and qname(sig.quality) == q and c.constant and not c.second_signal and cmp:find('^[>=]') then
            need = math.max(need or 0, c.constant + (cmp == '>' and 1 or 0))
          else other[#other+1] = w.ticks and string.format('%s %g s', w.type, w.ticks / 60) or w.type end
        end
        local at, ow = 'stop ' .. i .. ' (' .. r.station .. ')', table.concat(other, ', ')
        stops[#stops+1] = {stop=i, planet=r.station, waits_for=need, other_waits=ow, joined_by_or=ors or nil, requests_min=m and m.min, requests_max=m and m.max < math.huge and m.max or nil}
        if f.mode == 'full' and not need then W('%s: no wait on %s (waits: %s): it leaves then, whatever is aboard', at, f.item, ow)
        elseif f.mode == 'full' and need < n then W('%s: waits for %d %s, under the %d declared', at, need, f.item, n)
        elseif f.mode == 'full' and ors then W('%s: its %s wait is joined by or (%s): that can send it on first', at, f.item, ow)
        elseif f.mode == 'partial' and need and not ors then W('%s: partial visits, but it waits for %d %s with no or: it stays until they are aboard', at, need, f.item) end
        if not m then W('%s: the hub requests no %s from there', at, f.item)
        elseif m.max < n then W('%s: its requests keep at most %d %s, under the %d declared', at, m.max, f.item, n)
        elseif f.mode == 'full' and m.min < n then W('%s: its requests ask %d %s, under the %d declared', at, m.min, f.item, n) end
        if m and need and m.max < need then W('%s: it waits for %d %s; its requests keep at most %d', at, need, f.item, m.max) end
      end
    end
    if #stops == 0 then W('no stop at %s, nor one its requests import %s from', tostring(f.from), f.item) end
    return {freight={item=f.item, amount=n, mode=f.mode, from=f.from}, stops=stops, warnings=warn[1] and warn or nil,
      line=string.format('%s %s %d %s: %d stops, %d mismatches', pl.name, f.mode, n, f.item, #stops, #warn)}
  end
  function M.read(p, a)
    if a.freight ~= nil then return M.freight(p, a) end
    -- (d20 batch62 X2, Sol #1529) surface is the ledger's: without ledger it is refused, never dropped
    assert(a.surface == nil or a.ledger ~= nil, 'surface goes with ledger: true (that surface\'s launches and drops)')
    -- (d18 batch36 D3) the surface's cargo ledger: launches up and drops down in time order (ledger.lua)
    if a.ledger ~= nil then
      assert(a.ledger == true, 'ledger is true')
      assert(a.ready == nil, 'ledger takes surface, direction, platform, item, silo, from_tick, to_tick and limit')
      -- (d25 batch203 QP1) silo: the rockets one silo launched (its unit number, as silo and the pod rows give it)
      local silo = a.silo ~= nil and (api.integer and api.integer(a.silo, nil, 1, 2^40, 'silo (a silo\'s unit number)') or a.silo) or nil
      -- (d24 batch179 QV1) the pod ledger (podlog.lua): every pod's journey, filtered
      assert(a.direction == nil or a.direction == 'up' or a.direction == 'down', 'direction is up or down')
      assert(a.platform == nil or type(a.platform) == 'string', 'platform is a platform name')
      assert(a.item == nil or (type(a.item) == 'string' and prototypes.item[a.item:match('^([^@]+)')]), 'item is an item name (name@quality for one quality)')
      local from = a.from_tick ~= nil and (api.integer and api.integer(a.from_tick, nil, 0, 2^40, 'from_tick') or a.from_tick) or nil
      local to = a.to_tick ~= nil and (api.integer and api.integer(a.to_tick, nil, 0, 2^40, 'to_tick') or a.to_tick) or nil
      local limit = a.limit ~= nil and (api.integer and api.integer(a.limit, nil, 1, 128, 'limit') or a.limit) or 32
      local surface = a.surface or (a.platform == nil and p.surface.name) or nil
      assert(surface == nil or (type(surface) == 'string' and game.surfaces[surface]), 'surface is a surface name')
      local filtered = a.direction ~= nil or a.platform ~= nil or a.item ~= nil or from ~= nil or to ~= nil or silo ~= nil
      local up
      if a.direction == 'up' then up = true elseif a.direction == 'down' then up = false end
      assert(not (silo and up == false), 'silo goes with rockets (direction up): pods sent down have no silo')
      if silo then up = true end
      local rows, total = {}, 0
      if api.podlog then rows, total = api.podlog({surfaces=surface and {[surface]=true} or nil, up=up, platform=a.platform, item=a.item, silo=silo, from=from, to=to, limit=limit}) end
      local out = {surface=surface, pods=#rows > 0 and rows or nil, pods_total=total,
        pods_line=string.format('%d pod journe%s%s recorded%s%s%s', total, total == 1 and 'y' or 'ys', surface and ' to and from ' .. surface or ' on every planet',
          a.platform and ' with ' .. a.platform or '', silo and ' launched by silo ' .. silo or '', total > #rows and string.format('; the newest %d here (limit)', #rows) or '')
          -- (d28 batch313 HB) the span of the rows shown and their order (Haiku summed pods of two visits 54 min apart)
          .. (#rows > 0 and string.format('; these sent from tick %d (%s ago) to tick %d (%s ago), oldest first', rows[1].sent_tick, ago(game.tick - rows[1].sent_tick),
            rows[#rows].sent_tick, ago(game.tick - rows[#rows].sent_tick)) or ''),
        note='the pod ledger: every cargo pod sent up (a rocket) or down (a hub\'s pod: landing pad requests, hub trash, drops) since this runtime recorded them, '
          .. 'the last 1000 on each planet, kept after the platform leaves; landing pad free slots are read as the pod lands and once it has delivered; '
          .. 'a rocket\'s silo is the one the game names (the launch event\'s rocket_silo, else the pod\'s origin): unknown for rockets sent before the ledger kept silos, never taken from nearby entities'}
      if not filtered and surface then
        local lines = api.ledger and api.ledger(surface) or {}
        out.lines = #lines > 0 and lines or {'no launch from ' .. surface .. ' and no drop to it recorded'}
        out.note = out.note .. '; lines: launches with what the platform asked (64 a surface) and the drops read\'s last 20 drops on every surface, with the pad\'s story'
      end
      return out
    end
    if a.ready ~= nil then
      assert(a.ready == true, 'ready is true')
      assert(type(a.platform) == 'string' and a.item == nil, 'ready takes platform (one platform name), not item')
      for _, pl in pairs(p.force.platforms) do if pl.valid and pl.hub and pl.hub.valid and pl.name == a.platform then return M.ready(p, pl) end end
      error('no platform of ours named ' .. a.platform, 0)
    end
    assert(a.platform == nil or type(a.platform) == 'string', 'platform is a platform name')
    assert(a.item == nil or (type(a.item) == 'string' and prototypes.item[a.item]), 'item is an item name')
    assert(a.platform ~= nil or a.item ~= nil, 'shipment takes platform or item')
    local cache, lines, rows, n = {}, {}, {}, 0
    for _, pl in pairs(p.force.platforms) do
      if pl.valid and pl.hub and pl.hub.valid and (a.platform == nil or pl.name == a.platform) then
        n = n + 1
        if n > 16 then break end
        local l, r = M.platform(pl, cache, a.item)
        for _, x in ipairs(l) do lines[#lines+1] = x end
        for _, x in ipairs(M.conflicts(pl) or {}) do
          if not a.item or x:find(' ' .. a.item .. ';', 1, true) then lines[#lines+1] = x end
        end
        for _, x in ipairs(r) do rows[#rows+1] = x end
      end
    end
    if a.platform and n == 0 then error('no platform of ours named ' .. a.platform, 0) end
    local states = {}
    for _, r in ipairs(rows) do states[r.state] = (states[r.state] or 0) + 1 end
    local st = {}
    for k, v in pairs(states) do st[#st+1] = k .. ' ' .. v end
    table.sort(st)
    return {lines=#lines > 0 and lines or {'no request or cargo of ' .. tostring(a.item or a.platform)}, rows=rows, states=#st > 0 and table.concat(st, ', ') or nil,
      note='what the hub requests, silos, rockets, landing pads and the schedule show now; read only'}
  end
  -- Fact lines on change: a request delivered, cargo spilled, a hub_full gate appearing; one platform a call (every
  -- 2 s), so each is read about every 10 s with five platforms (the whole read was 61-77 ms on the copy of world n).
  local function store()
    local s = api.state()
    s.shipment = s.shipment or {last={}, events={}, seq=0, spills={}}
    return s.shipment
  end
  local function push(st, pl, text)
    st.seq = st.seq + 1
    local by = api.last_to and try(function() return api.last_to(pl.name) end)
    st.events[#st.events+1] = {id=st.seq, tick=game.tick, platform=pl.name, text=text, loader=by and by.by or nil}
    while #st.events > 50 do table.remove(st.events, 1) end
  end
  function M.tick()
    local st = store()
    local all = {}
    for _, f in pairs(game.forces) do
      for _, pl in pairs(pget(f, 'platforms') or {}) do
        local hub = pl.valid and pl.hub
        if hub and hub.valid then all[#all+1] = pl end
      end
    end
    if #all == 0 then return end
    table.sort(all, function(x, y) return x.index < y.index end)
    st.rr = (st.rr or 0) % #all + 1
    local pl = all[st.rr]
    local mine = '^' .. pl.index .. '|'
    local now = {}
    local _, rows = M.platform(pl, {}, nil, true)
    for _, r in ipairs(rows) do
      if r.direction == 'up' then
        local key = pl.index .. '|' .. r.planet .. '|' .. r.item
        local was = st.last[key]
        local state = r.state .. (r.gate and r.gate:find('^hub_full') and ':hub_full' or '')
        now[key] = state
        if was and was ~= state then
          if r.state == 'delivered' then
            push(st, pl, string.format('shipment: %s from %s delivered to %s (the hub holds %d of %d asked)', r.item, r.planet, pl.name, r.hub, r.min))
          elseif state:find(':hub_full') and not was:find(':hub_full') then
            push(st, pl, string.format('shipment: %s from %s for %s waits: %s', r.item, r.planet, pl.name, r.gate))
          end
        end
      elseif r.state == 'spilled' then
        local key = pl.index .. '|' .. r.planet .. '|' .. r.item .. '|' .. r.count
        if not st.spills[key] then
          st.spills[key] = game.tick
          push(st, pl, string.format('shipment: %d %s from %s landed with no pad on %s (%s)', r.count, r.item, pl.name, r.planet, table.concat(r.at or {}, '; ')))
        end
      end
    end
    -- this platform's states replaced, the others kept
    for k in pairs(st.last) do if k:find(mine) then st.last[k] = nil end end
    for k, v in pairs(now) do st.last[k] = v end
    for k, t in pairs(st.spills) do if game.tick - t > 216000 then st.spills[k] = nil end end
  end
  -- The lines for agent p (h: its hint state): events of platforms it hears about, or it loaded for.
  function M.lines(p, h)
    local st = api.state().shipment
    if not st or #st.events == 0 then return nil end
    local last = h.shipment_seen or 0
    local me = api.who and api.who(p)
    local out = {}
    for _, e in ipairs(st.events) do
      if e.id > last and ((me and e.loader == me) or (api.hears and api.hears(p, e.platform))) then out[#out+1] = e.text end
    end
    h.shipment_seen = st.seq
    return #out > 0 and out or nil
  end
  M.schema = {shipment = {ledger='optional true, alone or with surface (default yours): the surface\'s cargo ledger in time order: each rocket launched up (up #id: the silo, the cargo, the platform and what its hub asked of the planet then, by automatic requests or by whom) and each drop down (drop #id: from which platform, the items, what the pad asked for them then, where the pod landed, what the pad held and what robots took from it in the 20 s after, the verdict); lines, note (what it cannot know). And pods (d24 batch179): the pod ledger, every cargo pod sent up (a rocket) or down (a hub\'s pod for landing pad requests or hub trash, and drops) on that planet, the last 1000 a planet, kept after the platform leaves, oldest first: [{id, pod (unit number), direction, silo (a rocket\'s: {unit_number, surface, position} as the game names it; unknown: sent before the ledger kept silos; not read), platform, stop, surface, sent_tick, landed_tick, destination (landing pad (x,y), hub, ground (x,y)), items (name@quality*count), by (a drop\'s sender), pad_free_before and pad_free_after (main and trash slots), ground (items the full pad did not take, on the ground beside it), line}], pods_total, pods_line; filters direction, platform, item, from_tick, to_tick, limit (lines only without them)', surface='with ledger: a surface name (default yours; with platform and no surface: every planet)',
    direction='with ledger: up or down', silo='with ledger: a silo\'s unit number: the rockets it launched (pods[].silo gives each rocket\'s silo {unit_number, surface, position}, or unknown for rockets sent before the ledger kept silos)', from_tick='with ledger: journeys sent at or after this tick', to_tick='with ledger: journeys sent at or before this tick', limit='with ledger: 1..128 (default 32): the newest that many journeys',
    platform='a platform name (with ledger: its journeys)', item='or an item name: that item on every platform (with ledger: journeys carrying it; name@quality for one quality)',
    freight='optional {item (name@quality), amount, mode: full (waits until amount is aboard) or partial (takes what is there, comes back), from (planet; default the stops it imports item from)}, with platform: {freight, stops [{stop, planet, waits_for, other_waits, joined_by_or, requests_min, requests_max}], warnings, line}; changes nothing',
    ready='optional true, with platform: the freight readiness read for the planet it stops at (else the stop it flies to): its gate (a circuit wait with what the hub\'s wires read), the requests from there not delivered, each silo there (its rocket, automatic requests and why it waits: what the rocket holds against the payload it waits for, the request flag; the circuit and logistic conditions of inserters and loaders within 8 tiles with what each reads now), the landing pads there (free slots each; per item the hub would send down: count, slots, what the pads can take of it now). Returns {lines, planet, silos, down, pad_free_slots}',
    returns='lines: per platform stop (the schedule\'s stop with its departure conditions and what the hub holds against them), each hub request importing from that planet with its state: delivered, in flight (a rocket\'s pod coming down onto the platform), launched (its pod still rising), loading (a silo there with it in its rocket or logistic robots bringing it), waiting with the native gate holding it (the platform not stopped there, no silo with automatic requests, the silo\'s request flag: hub_full, below_min_payload, split_networks, matched, filling), led by a silo that can fill it, then each silo of ours on that planet: can fill it or why not, its network, what that network can give, the payload a rocket waits for, its rocket parts (a stop not reached: by the networks\' stock now); what the planet\'s landing pads ask of the hub now; the last visit\'s pad receipts and spills (landed with no pad, where); the platform\'s last 2 drops into a pad there with what the pad showed after (landed, then taken by construction robots: how many, the first orders they flew to; as the drops read\'s pad line); cargo conflict lines: an item the hub holds that the landing pads of two or more coming stops ask, each stop in the order reached with what its pads ask and hold, what goes down there and what is left aboard after it. rows [{platform, planet, item, direction up|down, state, ...; up rows: quality, comparator, custom_minimum, hub (what the hub holds of the qualities the request takes), picked_silo {name, position} (a silo whose automatic requests fill a rocket for this platform now), silos [{name, position, auto, network, can_give, payload, parts, flag, can_fill}] (a waiting request)}], states (counts). A delivered request, a spill and a hub_full gate appearing come once in team.alerts to who last launched to the platform and those its alerts go to. Read only'}}
  return M
end
