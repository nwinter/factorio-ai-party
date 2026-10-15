-- Cargo pods on their way down from our platforms (Grok, shift13: the second Sunward stopped at Nauvis, Grok found
-- its 519 production packs neither on the landing pad nor in where_is and told Astra they had not landed; the pods
-- came down a few seconds later). On a copy of world n (2.0.77) a pod from a hub reads awaiting_launch, then
-- ascending on the platform's surface (about 50 tiles from the hub), then descending on the planet's surface (from
-- about 260 tiles off toward the pad), parking at the pad, and is gone once its cargo is delivered: about 20 s in
-- all. It is the same entity on both surfaces, so a pod seen while it rises is followed down by reference. Once a
-- second the surfaces of the platforms stopped at a space location are read for pods (0.12 ms for world n's two
-- platforms on the copy, against 7.6 ms for one search of all Nauvis); a pod is forgotten when it is gone or after
-- two minutes. Read only: what a player sees of pods in the sky.
return function(api)
  local M = {}
  local SAMPLE, KEEP, MAX = 60, 7200, 256
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.pods = s.pods or {}
    return s.pods
  end
  local function contents(pod)
    local inv = try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    local out = {}
    for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      local q = type(st.quality) == 'table' and st.quality.name or st.quality
      local key = st.name .. (q and q ~= 'normal' and '@' .. q or '')
      out[key] = (out[key] or 0) + st.count
    end
    return next(out) and out or nil
  end
  -- Where a pod goes: the surface's name and the landing pad's position, if a pad takes it.
  local function destination(pod)
    local d = try(function() return pod.cargo_pod_destination end)
    if not d then return nil end
    local station = d.station and try(function() return d.station.valid and d.station end)
    local surface = station and try(function() return station.surface.name end)
      or try(function() return type(d.surface) == 'string' and d.surface or d.surface.name end)
    return surface, station and {x=station.position.x, y=station.position.y} or nil
  end
  function M.tick(tick)
    if tick % SAMPLE ~= 0 then return end
    local list = store()
    local n = 0
    for unit, r in pairs(list) do
      if not (r.pod and r.pod.valid) or tick - r.start > KEEP then list[unit] = nil else n = n + 1 end
    end
    for _, f in pairs(game.forces) do
      for _, pl in pairs(try(function() return f.platforms end) or {}) do
        local s = pl.valid and try(function() return pl.space_location and pl.surface end)
        if s and s.valid then
          for _, pod in pairs(s.find_entities_filtered{type='cargo-pod'}) do
            local unit = pod.valid and pod.unit_number
            local r = unit and list[unit]
            if unit and not r and n < MAX then
              local to, pad = destination(pod)
              -- Going down: to another surface than the platform's own.
              if to and to ~= s.name then
                list[unit] = {pod=pod, platform=pl.name, force=f.name, to=to, pad=pad, items=contents(pod), start=tick}
                n = n + 1
              end
            elseif r and not r.items then r.items = contents(pod) end
          end
        end
      end
    end
  end
  -- The pods of force `force` still in the air toward surface `to` (from `platform` only, when given):
  -- {platform, state, pad, items={key=count}}, oldest first.
  function M.in_flight(force, to, platform)
    local out = {}
    for _, r in pairs(store()) do
      if r.pod and r.pod.valid and r.force == force and r.to == to and (not platform or r.platform == platform) then
        local items = contents(r.pod) or r.items
        out[#out+1] = {platform=r.platform, state=try(function() return r.pod.cargo_pod_state end) or '?', pad=r.pad, items=items or {}, start=r.start}
      end
    end
    table.sort(out, function(x, y) return x.start < y.start end)
    return out
  end
  local function items_text(t, limit)
    local list = {}
    for k, v in pairs(t) do list[#list+1] = {k=k, v=v} end
    table.sort(list, function(x, y) return x.v > y.v or (x.v == y.v and x.k < y.k) end)
    local parts = {}
    for i = 1, math.min(limit or 6, #list) do parts[i] = list[i].k .. '*' .. list[i].v end
    if #list > (limit or 6) then parts[#parts+1] = '+' .. (#list - (limit or 6)) .. ' more' end
    return table.concat(parts, ' ')
  end
  -- The pods followed now that left platform `platform` of force `force` (freight.lua counts each on the platform's
  -- stop, through to where it went).
  function M.from(force, platform)
    local out = {}
    for _, r in pairs(store()) do
      if r.force == force and r.platform == platform and r.pod and r.pod.valid then out[#out+1] = r.pod end
    end
    return out
  end
  -- "3 cargo pods from Sunward still in the air: processing-unit*300 (to the landing pad at (52,54); 2 descending,
  -- 1 ascending)", or nil when none.
  function M.line(force, to, platform)
    local list = M.in_flight(force, to, platform)
    if #list == 0 then return nil end
    local items, states, pads, from = {}, {}, {}, {}
    for _, r in ipairs(list) do
      for k, v in pairs(r.items) do items[k] = (items[k] or 0) + v end
      states[r.state] = (states[r.state] or 0) + 1
      pads[r.pad and string.format('the landing pad at (%g,%g)', r.pad.x, r.pad.y) or 'the ground (no pad takes them)'] = true
      from[r.platform] = true
    end
    local function keys(t) local out = {} for k in pairs(t) do out[#out+1] = k end table.sort(out) return out end
    local parts = {}
    for _, s in ipairs(keys(states)) do parts[#parts+1] = states[s] .. ' ' .. s end
    return string.format('%d cargo pod%s from %s still in the air: %s (to %s; %s)', #list, #list == 1 and '' or 's',
      table.concat(keys(from), ', '), next(items) and items_text(items) or 'contents not read yet', table.concat(keys(pads), ', '),
      table.concat(parts, ', '))
  end
  return M
end
