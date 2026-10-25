-- ledger: one cargo ledger per surface (d18 batch36 D3, Luna 15:48: the silo chain inferred across cargo, shipment and
-- inspect; an LDS delivery that looked done did not reach the feeders). Each rocket launched is recorded as it goes (the
-- game's launch-ordered event): its id, the silo, the platform it goes to and what that platform's hub asked of this
-- planet then for the cargo's items, and the cargo. shipment {ledger: true, surface?} reads, in time order, those
-- launches up from the surface and the drops down to it (drops.lua's records: the platform, what the pad asked for the
-- items then, where the pod landed, what the pad held and what robots took from it in the 20 s after, the verdict).
-- What it cannot know: launches before this runtime ran (none recorded), more than KEEP launches a surface, more than
-- drops.lua keeps (its last 20 on every surface), and a drop's pad asks before the pad watch began (batch34).
return function(api)
  local M = {}
  M.KEEP = 64
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.ledger = s.ledger or {seq=0, by={}}
    return s.ledger
  end
  local function name_of(v) if type(v) == 'table' or type(v) == 'userdata' then return v.name end return v end
  local function ago(t)
    local sec = math.floor(t / 60)
    if sec >= 3600 then return string.format('%dh%02dm', math.floor(sec / 3600), math.floor(sec / 60) % 60) end
    if sec >= 60 then return string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end
    return sec .. 's'
  end
  -- What a platform's hub asks of planet for these items: "low-density-structure 100 (holds 20)"; (d25 batch198 QK1)
  -- a quality other than normal named, and held of that quality: "asteroid-collector@legendary 3 (holds 0)".
  local function hub_asks(pl, planet, names)
    local out = {}
    local secs = try(function() return pl.hub.get_logistic_sections() end)
    for i = 1, secs and secs.sections_count or 0 do
      local sec = try(function() return secs.get_section(i) end)
      for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
        local v = f.value
        local n = v and name_of(v.name)
        local from = f.import_from and name_of(f.import_from)
        if n and names[n] and (from == nil or from == planet) then
          local q = v.quality and name_of(v.quality) or 'normal'
          out[#out+1] = string.format('%s %d (holds %d)', q == 'normal' and n or n .. '@' .. q, f.min or 0, try(function() return pl.hub.get_item_count(q == 'normal' and n or {name=n, quality=q}) end) or 0)
        end
      end
    end
    return out
  end
  function M.on_launch(event)
    local silo = event.rocket_silo
    if not (silo and silo.valid) then return end
    local pod = try(function() return event.rocket.attached_cargo_pod end)
    local inv = pod and defines.inventory.cargo_unit and try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    local cargo, names = {}, {}
    for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local n = name_of(c.name)
      cargo[#cargo+1] = n .. '*' .. c.count; names[n] = true
    end
    local d = pod and try(function() return pod.cargo_pod_destination end)
    local pl = d and ((d.station and try(function() return d.station.surface.platform end)) or d.space_platform)
    local surface = silo.surface.name
    local st = store()
    st.seq = st.seq + 1
    local rec = {id=st.seq, tick=game.tick, silo={x=silo.position.x, y=silo.position.y}, cargo=#cargo > 0 and table.concat(cargo, ', ') or 'empty',
      to=pl and try(function() return pl.valid and pl.name end) or nil,
      by=event.player_index and try(function() return game.get_player(event.player_index).name end) or nil}
    if pl and rec.to then
      local asks = hub_asks(pl, surface, names)
      rec.asks = #asks > 0 and table.concat(asks, ', ') or 'no request of its hub names this cargo from ' .. surface
      rec.auto = try(function() return silo.transitional_request_target == pl end) or nil
    end
    local list = st.by[surface] or {}
    st.by[surface] = list
    list[#list+1] = rec
    while #list > M.KEEP do table.remove(list, 1) end
    return rec.id
  end
  -- (d18 batch39 A2) the latest launch recorded to a platform, from any surface: the record and its surface, or nil
  function M.latest_to(name)
    local best, where
    for surface, list in pairs(store().by) do
      for i = #list, 1, -1 do
        local r = list[i]
        if r.to == name then
          if not best or r.tick > best.tick then best, where = r, surface end
          break
        end
      end
    end
    return best, where
  end
  -- The surface's launches and drops, oldest first.
  function M.read(surface_name, drops)
    local entries = {}
    for _, r in ipairs((store().by[surface_name]) or {}) do
      entries[#entries+1] = {tick=r.tick, line=string.format('up #%d, %s ago: rocket-silo (%g,%g) launched %s%s%s%s', r.id, ago(game.tick - r.tick), r.silo.x, r.silo.y,
        r.cargo, r.to and ' to ' .. r.to or ' (no platform: its pod goes to the surface)', r.asks and '; ' .. r.to .. ' asked ' .. r.asks or '',
        r.auto and ' (its automatic requests)' or (r.by and ' (launched by ' .. r.by .. ')' or ''))}
    end
    for _, r in ipairs(drops or {}) do
      if r.surface == surface_name then
        local items = table.concat(r.sent or {}, ' ')
        local where = r.landed_in and ('; landed in ' .. r.landed_in) or (r.at and string.format('; landed at (%g,%g)', r.at.x, r.at.y)) or (r.state == 'descending' and '; still descending' or '')
        entries[#entries+1] = {tick=r.tick, line=string.format('down drop #%d, %s ago: from %s, %s%s%s%s%s', r.id, ago(game.tick - r.tick), tostring(r.platform), items,
          r.pad_asks and '; the pad asked ' .. r.pad_asks or '', where, r.pad_text and '; ' .. r.pad_text or '', r.verdict and ' (' .. r.verdict .. ')' or '')}
      end
    end
    table.sort(entries, function(x, y) return x.tick < y.tick end)
    local lines = {}
    for i, e in ipairs(entries) do lines[i] = e.line end
    return lines
  end
  return M
end
