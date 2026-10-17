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
  local function at(q) return string.format('(%g,%g)', math.floor(q.x + 0.5), math.floor(q.y + 0.5)) end
  local function ago(t) local s = math.floor(t / 60); return s < 120 and s .. 's' or string.format('%dm%02ds', math.floor(s / 60), s % 60) end
  local function items_text(t)
    local list = {}
    for n, c in pairs(t or {}) do if c > 0 then list[#list+1] = n .. '*' .. c end end
    table.sort(list)
    return #list > 0 and table.concat(list, ' ') or nil
  end
  -- The hub's requests by the planet they import from: {planet = {item = min}} ('any' when none is set).
  local function requests(pl)
    local out = {}
    local secs = try(function() return pl.hub.get_logistic_sections() end)
    for i = 1, secs and secs.sections_count or 0 do
      local sec = try(function() return secs.get_section(i) end)
      if sec and sec.active ~= false then
        for _, f in ipairs(try(function() return sec.filters end) or {}) do
          local v = f.value
          local name = type(v) == 'table' and v.name or v
          local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end)) or 'any'
          if type(name) == 'string' and (f.min or 0) > 0 then
            out[from] = out[from] or {}
            out[from][name] = (out[from][name] or 0) + f.min
          end
        end
      end
    end
    return out
  end
  local function rocket_cargo(e)
    local inv = defines.inventory.rocket_silo_rocket and try(function() return e.get_inventory(defines.inventory.rocket_silo_rocket) end)
    local out = {}
    for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do out[r.name] = (out[r.name] or 0) + r.count end
    return out
  end
  local function bringing(e)
    local out = {}
    local pts = try(function() return e.get_logistic_point() end)
    if pts and pts.object_name then pts = {pts} end
    for _, pt in pairs(pts or {}) do
      for _, it in ipairs(try(function() return pt.targeted_items_deliver end) or {}) do out[it.name] = (out[it.name] or 0) + (it.count or 0) end
    end
    return out
  end
  -- A planet's silos for a platform, read once a call: {list = [{e, auto, target, cargo, coming}], flags = {item = row}}.
  local function silos_at(cache, force, planet, platform)
    local key = planet .. '|' .. platform
    if cache[key] then return cache[key] end
    local s = try(function() return game.planets[planet].surface end)
    local out = {list={}, flags={}}
    -- the surface's silos, found once a minute (a whole-surface search: 5-8 ms on the copy of world n), kept in storage
    local sc = api.state(); sc.shipment_silos = sc.shipment_silos or {}
    local c = s and sc.shipment_silos[s.index]
    if s and not (c and game.tick - c.tick < 3600) then
      c = {tick=game.tick, list=try(function() return s.find_entities_filtered{type='rocket-silo'} end) or {}}
      sc.shipment_silos[s.index] = c
    end
    for _, e in ipairs(c and c.list or {}) do
      if e.valid and e.force == force then
      local x = {e=e, auto=try(function() return e.use_transitional_requests end) == true,
        target=try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end), cargo=rocket_cargo(e), coming=bringing(e)}
      out.list[#out.list+1] = x
      if x.auto and api.request_rows then
        for _, r in ipairs(try(function() return api.request_rows(e, force) end) or {}) do
          if r.platform == platform and not out.flags[r.item] then out.flags[r.item] = r end
        end
      end
      end
    end
    cache[key] = out
    return out
  end
  -- One up request's state and line.
  local function up_row(pl, planet, item, min, held, here, sil, incoming)
    local row = {platform=pl.name, planet=planet, item=item, direction='up', min=min, hub=held}
    if held >= min then
      row.state = 'delivered'
      row.line = string.format('%s %d from %s: delivered (the hub holds %d)', item, min, planet, held)
      return row
    end
    for _, r in ipairs(incoming or {}) do
      if (r.cargo[item] or 0) > 0 and (r.from == nil or r.from == planet or try(function() return game.planets[planet].surface.name end) == r.from) then
        row.state = r.down and 'in flight' or 'launched'
        row.line = string.format('%s %d from %s: %s (a rocket launched %s ago carries %d; %s; the hub holds %d)', item, min, planet, row.state,
          ago(game.tick - r.tick), r.cargo[item], r.down and 'its pod comes down onto the platform' or 'its pod rises over ' .. planet, held)
        return row
      end
    end
    for _, x in ipairs(sil.list) do
      local inr, com = x.cargo[item] or 0, x.coming[item] or 0
      if (inr > 0 or com > 0) and (x.target == pl.name or not x.auto) then
        row.state = 'loading'
        row.line = string.format('%s %d from %s: loading (%s at %s: %d in its rocket%s%s; the hub holds %d)', item, min, planet, x.e.name, at(x.e.position), inr,
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
      local f = sil.flags[item]
      if #sil.list == 0 then gate = 'no rocket silo of ours on ' .. planet
      elseif not auto then gate = 'no silo on ' .. planet .. ' has automatic requests on (a load_silo or launch by hand sends it)'
      elseif f then gate = f.line
      else gate = 'no silo reads a request of it' end
    end
    row.gate = gate
    row.line = string.format('%s %d from %s: waiting (the hub holds %d): %s', item, min, planet, held, gate)
    return row
  end
  -- Every row and line of one platform: {lines, rows}.
  -- fast (the tick): the states alone, no stop texts or pad asks.
  function M.platform(pl, cache, only, fast)
    local lines, rows = {}, {}
    local sch = try(function() return pl.schedule end)
    local records = sch and sch.records or {}
    local stops = not fast and api.stops and try(function() return api.stops(pl) end) or {}
    local reqs = requests(pl)
    local counts = api.hub_counts and try(function() return api.hub_counts(pl) end) or {}
    local inc = api.incoming and try(function() return api.incoming(pl) end)
    local w = api.where and try(function() return api.where(pl) end) or {}
    local segs = api.segments and try(function() return api.segments(pl) end) or {}
    local planets, seen = {}, {}
    for i, r in ipairs(records) do if i <= 8 and r.station and not seen[r.station] then seen[r.station] = true; planets[#planets+1] = {i=i, name=r.station} end end
    for name in pairs(reqs) do if name ~= 'any' and not seen[name] then seen[name] = true; planets[#planets+1] = {name=name} end end
    for _, st in ipairs(planets) do
      local planet = st.name
      local here = w.stopped and w.at == planet
      local head = st.i and (stops[st.i] or (st.i .. ' ' .. planet)) or (planet .. ' (not in the schedule)')
      local parts = {}
      local sil = silos_at(cache, pl.force, planet, pl.name)
      local n = 0
      local list = {}
      for item, min in pairs(reqs[planet] or {}) do list[#list+1] = {item=item, min=min} end
      table.sort(list, function(a, b) return a.item < b.item end)
      for _, q in ipairs(list) do
        if not only or q.item == only then
          n = n + 1
          local row = up_row(pl, planet, q.item, q.min, counts[q.item] or 0, here, sil, inc and inc.rows)
          rows[#rows+1] = row
          if n <= 24 then parts[#parts+1] = row.line end
        end
      end
      if n > 24 then parts[#parts+1] = string.format('+%d more requests', n - 24) end
      -- down: what the planet's landing pads ask of the hub now, and the last visit's receipts and spills
      local ask, hold = {}, {}
      if api.pads and not fast then local a1, h1 = api.pads(planet, pl.force); ask, hold = a1 or {}, h1 or {} end
      local down = {}
      for item, a in pairs(ask) do
        local want = a - (hold[item] or 0)
        local carry = counts[item] or 0
        if want > 0 and carry > 0 and (not only or item == only) then
          down[#down+1] = string.format('%s %d (pads ask %d, hold %d)', item, math.min(want, carry), a, hold[item] or 0)
          rows[#rows+1] = {platform=pl.name, planet=planet, item=item, direction='down', state=here and 'unloading' or 'aboard for ' .. planet, count=math.min(want, carry)}
        end
      end
      table.sort(down)
      if #down > 0 then parts[#parts+1] = (here and 'the hub sends down to ' or 'aboard for the landing pads at ') .. planet .. ': ' .. table.concat(down, ', ') end
      for k = #segs, 1, -1 do
        local seg = segs[k]
        if seg.kind == 'stop' and seg.at == planet and seg.pods then
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
      if #parts > 0 or not only then
        lines[#lines+1] = string.format('%s: %s%s', pl.name, head, #parts > 0 and '; ' .. table.concat(parts, '; ') or '; no request imports from ' .. planet)
      end
    end
    return lines, rows
  end
  function M.read(p, a)
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
      for _, pl in pairs(try(function() return f.platforms end) or {}) do
        if pl.valid and pl.hub and pl.hub.valid then all[#all+1] = pl end
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
  M.schema = {shipment = {platform='a platform name', item='or an item name: that item on every platform',
    returns='lines: per platform stop (the schedule\'s stop with its departure conditions and what the hub holds against them), each hub request importing from that planet with its state: delivered, in flight (a rocket\'s pod coming down onto the platform), launched (its pod still rising), loading (a silo there with it in its rocket or logistic robots bringing it), waiting with the native gate holding it (the platform not stopped there, no silo with automatic requests, the silo\'s request flag: hub_full, below_min_payload, split_networks, matched, filling); what the planet\'s landing pads ask of the hub now; the last visit\'s pad receipts and spills (landed with no pad, where). rows [{platform, planet, item, direction up|down, state, ...}], states (counts). A delivered request, a spill and a hub_full gate appearing come once in team.alerts to who last launched to the platform and those its alerts go to. Read only'}}
  return M
end
