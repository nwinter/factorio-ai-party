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
            local r = out[from][key] or {item=name, quality=q, comparator=cmp, min=0, custom_minimum=f.minimum_delivery_count}
            r.min = r.min + f.min
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
  -- flight, the request flags (flags_of: each auto silo's request_rows) when a request waits at the planet the platform
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
  local function flags_of(sil)
    if not sil.flags then
      sil.flags = {}
      for _, x in ipairs(sil.list) do
        for _, r in ipairs(rows_of(sil, x) or {}) do
          local k = r.item .. '@' .. (r.quality or 'normal') .. ((r.comparator or '=') ~= '=' and r.comparator or '')
          if r.platform == sil.platform and not sil.flags[k] then sil.flags[k] = r end
        end
      end
    end
    return sil.flags
  end
  local function pads_of(sil)
    if not sil.pads then
      sil.pads = {}
      for _, e in ipairs(sil.found and sil.found.pads or {}) do if e.valid and e.force == sil.force then sil.pads[#sil.pads+1] = e end end
    end
    return sil.pads
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
  local function up_row(pl, planet, q, min, counts, here, sil, incoming)
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
    if not here then gate = 'the platform is not stopped at ' .. planet
    else
      local auto = false
      for _, x in ipairs(sil.list) do if x.auto then auto = true end end
      -- (BT1) the flags read here alone: a request waiting at the planet the platform is stopped at, with auto silos
      local f = #sil.list > 0 and auto and flags_of(sil)[item .. '@' .. qa .. (cmp ~= '=' and cmp or '')]
      if #sil.list == 0 then gate = 'no rocket silo of ours on ' .. planet
      elseif not auto then gate = 'no silo on ' .. planet .. ' has automatic requests on (a load_silo or launch by hand sends it)'
      elseif f then gate = f.line
      else gate = 'no silo reads a request of it' end
      if auto then
        gate = gate .. (picked and string.format('; the game\'s pick: %s at %s fills a rocket for %s now', picked.e.name, at(picked.e.position), pl.name)
          or string.format('; the game\'s pick: no silo on %s fills a rocket for %s now', planet, pl.name))
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
          local row = up_row(pl, planet, q, q.min, counts_q, here, sil, inc and inc.rows)
          rows[#rows+1] = row
          if parts and n <= 24 then parts[#parts+1] = row.line end
        end
      end
      if parts and n > 24 then parts[#parts+1] = string.format('+%d more requests', n - 24) end
      -- down: what the planet's landing pads ask of the hub now, and the last visit's receipts and spills
      local ask, hold = {}, {}
      if api.pads and not fast then local a1, h1 = api.pads(planet, force); ask, hold = a1 or {}, h1 or {} end
      local down = {}
      -- (batch31 B6) the hub keeps at a stop what its requests from that planet ask, and no more (by item: BA1's keys
      -- summed over qualities)
      local keep_here = {}
      if next(ask) then for _, r in pairs(mine) do keep_here[r.item] = (keep_here[r.item] or 0) + r.min end end
      for item, a in pairs(ask) do
        local want = a - (hold[item] or 0)
        local carry = (counts[item] or 0) - (keep_here[item] or 0)
        if want > 0 and carry > 0 and (not only or item == only) then
          down[#down+1] = string.format('%s %d (pads ask %d, hold %d)', item, math.min(want, carry), a, hold[item] or 0)
          rows[#rows+1] = {platform=pl.name, planet=planet, item=item, direction='down', state=here and 'unloading' or 'aboard for ' .. planet, count=math.min(want, carry)}
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
    -- what the hub keeps at a stop (space.lua KEEP_RULE, batch31 B6): what its requests importing from that planet ask
    -- (on the copy of world n Swift at Nauvis kept its 501 magazines under 500..2000 from nauvis; Cinder at Nauvis sent all
    -- 85 foundation down under 50..inf from fulgora); a request from another planet keeps nothing there
    local reqs = requests(pl)
    local asks = {}
    for _, o in ipairs(order) do
      local ask, hold = {}, {}
      if api.pads then local a1, h1 = api.pads(o.planet, pl.force); ask, hold = a1 or {}, h1 or {} end
      local keep = {}
      for _, r in pairs(reqs[o.planet] or {}) do keep[r.item] = (keep[r.item] or 0) + r.min end
      for item, a in pairs(ask) do
        local want = a - (hold[item] or 0)
        if want > 0 and (counts[item] or 0) - (keep[item] or 0) > 0 then
          asks[item] = asks[item] or {}
          table.insert(asks[item], {stop=o, want=want, ask=a, hold=hold[item] or 0, keep=keep[item] or 0})
        end
      end
    end
    local lines = {}
    for item, list in pairs(asks) do
      if #list >= 2 then
        local left, parts = counts[item], {}
        for _, x in ipairs(list) do
          local take = math.max(0, math.min(left - x.keep, x.want))
          left = left - take
          parts[#parts+1] = string.format('stop %d %s%s: its pads ask %d (hold %d)%s, %d go down there, %d left aboard',
            x.stop.i, x.stop.planet, x.stop.here and ' (here)' or '', x.ask, x.hold, x.keep > 0 and string.format(', its requests from %s keep %d', x.stop.planet, x.keep) or '', take, left)
        end
        lines[#lines+1] = string.format('cargo conflict on %s: the hub holds %d %s; %s', pl.name, counts[item], item, table.concat(parts, '; '))
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
    -- the hub keeps there what its requests from that planet ask (space.lua KEEP_RULE), by item
    local keep = {}
    for _, r in pairs(requests(pl)[planet] or {}) do keep[r.item] = (keep[r.item] or 0) + r.min end
    -- what the pads ask (their active sections' minimums) and hold, as freight's pads reads them
    local ask, hold, invs = {}, {}, {}
    for i, pad in ipairs(pads) do
      local ls = try(function() return pad.get_logistic_sections() end)
      for k = 1, ls and ls.sections_count or 0 do
        local sec = try(function() return ls.get_section(k) end)
        for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          if type(name) == 'string' and (f.min or 0) > 0 then ask[name] = (ask[name] or 0) + f.min end
        end
      end
      local inv = defines.inventory.cargo_landing_pad_main and try(function() return pad.get_inventory(defines.inventory.cargo_landing_pad_main) end)
      for _, x in ipairs(inv and try(function() return inv.get_contents() end) or {}) do hold[x.name] = (hold[x.name] or 0) + x.count end
      invs[i] = inv or false
    end
    if #pads == 0 then lines[#lines+1] = 'no landing pad of ours on ' .. planet .. ': what the hub drops there lands with no pad'
    else
      local free, pl_parts = 0, {}
      for i, pad in ipairs(pads) do
        if i > PADS then break end
        local inv = invs[i]
        local f = inv and try(function() return inv.count_empty_stacks() end) or 0
        free = free + f
        pl_parts[#pl_parts+1] = string.format('%s %s %d free slots of %d', pad.name, at(pad.position), f, inv and #inv or 0)
      end
      local down, slots = {}, 0
      local names = {}
      for item in pairs(ask) do names[#names+1] = item end
      table.sort(names)
      out.down = {}
      for _, item in ipairs(names) do
        local want = ask[item] - (hold[item] or 0)
        local spare = (counts[item] or 0) - (keep[item] or 0)
        local n = math.min(want, spare)
        if n > 0 then
          local stack = try(function() return prototypes.item[item].stack_size end) or 1
          local take = 0
          for _, inv in ipairs(invs) do if inv then take = take + (try(function() return inv.get_insertable_count(item) end) or 0) end end
          local need = math.ceil(n / stack)
          slots = slots + need
          down[#down+1] = string.format('%s %d (pads ask %d, hold %d; %d slots; the pads can take %d of it now%s)', item, n, ask[item], hold[item] or 0, need, take,
            take < n and string.format(', %d short', n - take) or '')
          out.down[#out.down+1] = {item=item, count=n, slots=need, pads_take=take}
        end
      end
      lines[#lines+1] = string.format('landing pads on %s: %s%s; %s', planet, table.concat(pl_parts, ', '), #pads > PADS and ', ...' or '',
        #down > 0 and string.format('the hub would send down %s: %d slots in all, %d free%s', table.concat(down, ', '), slots, free, slots > free and ' (fewer)' or '')
        or 'the hub holds nothing the pads ask for beyond what its requests from ' .. planet .. ' keep')
      out.pad_free_slots = free
    end
    out.lines = lines
    out.note = 'the platform\'s gate, the requests from that planet, its silos and landing pads as the game shows them now; a silo with automatic requests sends a rocket once it holds what the silo requests (on 2.0.77 a full rocket of the item, or the request\'s min payload); read only'
    return out
  end
  function M.read(p, a)
    -- (d20 batch62 X2, Sol #1529) surface is the ledger's: without ledger it is refused, never dropped
    assert(a.surface == nil or a.ledger ~= nil, 'surface goes with ledger: true (that surface\'s launches and drops)')
    -- (d18 batch36 D3) the surface's cargo ledger: launches up and drops down in time order (ledger.lua)
    if a.ledger ~= nil then
      assert(a.ledger == true, 'ledger is true')
      assert(a.platform == nil and a.item == nil and a.ready == nil, 'ledger takes surface only')
      local surface = a.surface or p.surface.name
      assert(type(surface) == 'string' and game.surfaces[surface], 'surface is a surface name')
      local lines = api.ledger and api.ledger(surface) or {}
      return {surface=surface, lines=#lines > 0 and lines or {'no launch from ' .. surface .. ' and no drop to it recorded'},
        note='launches are recorded from when this runtime ran (64 a surface); drops as the drops read keeps them (the last 20 on every surface)'}
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
  M.schema = {shipment = {ledger='optional true, alone or with surface (default yours): the surface\'s cargo ledger in time order: each rocket launched up (up #id: the silo, the cargo, the platform and what its hub asked of the planet then, by automatic requests or by whom) and each drop down (drop #id: from which platform, the items, what the pad asked for them then, where the pod landed, what the pad held and what robots took from it in the 20 s after, the verdict); lines, note (what it cannot know)', surface='with ledger: a surface name',
    platform='a platform name', item='or an item name: that item on every platform',
    ready='optional true, with platform: the freight readiness read for the planet it stops at (else the stop it flies to): its gate (a circuit wait with what the hub\'s wires read), the requests from there not delivered, each silo there (its rocket, automatic requests and why it waits: what the rocket holds against the payload it waits for, the request flag; the circuit and logistic conditions of inserters and loaders within 8 tiles with what each reads now), the landing pads there (free slots each; per item the hub would send down: count, slots, what the pads can take of it now). Returns {lines, planet, silos, down, pad_free_slots}',
    returns='lines: per platform stop (the schedule\'s stop with its departure conditions and what the hub holds against them), each hub request importing from that planet with its state: delivered, in flight (a rocket\'s pod coming down onto the platform), launched (its pod still rising), loading (a silo there with it in its rocket or logistic robots bringing it), waiting with the native gate holding it (the platform not stopped there, no silo with automatic requests, the silo\'s request flag: hub_full, below_min_payload, split_networks, matched, filling); what the planet\'s landing pads ask of the hub now; the last visit\'s pad receipts and spills (landed with no pad, where); the platform\'s last 2 drops into a pad there with what the pad showed after (landed, then taken by construction robots: how many, the first orders they flew to; as the drops read\'s pad line); cargo conflict lines: an item the hub holds that the landing pads of two or more coming stops ask, each stop in the order reached with what its pads ask and hold, what goes down there and what is left aboard after it. rows [{platform, planet, item, direction up|down, state, ...; up rows: quality, comparator, custom_minimum, hub (what the hub holds of the qualities the request takes), picked_silo {name, position} (a silo whose automatic requests fill a rocket for this platform now)}], states (counts). A delivered request, a spill and a hub_full gate appearing come once in team.alerts to who last launched to the platform and those its alerts go to. Read only'}}
  return M
end
