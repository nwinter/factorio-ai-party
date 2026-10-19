-- hubfull: a hub too full for its payload (d18 batch37 B3, Grok: Spindle's hub filled with ore twice and the science
-- rocket could not board; seen only in the silo line's hub_full). Every CHECK ticks one platform waiting at a stop, in
-- turn: each silo of ours on that planet (the census list) whose request row for it reads hub_full (the payload a
-- rocket waits for takes more hub slots than are free) is told once per wait to those who hear about the platform
-- (platalerts.lua), as a line that wakes them, naming what fills the hub. Read only.
return function(api)
  local M = {}
  M.CHECK, M.TOP = 600, 4
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.hubfull = s.hubfull or {next=1, told={}}
    return s.hubfull
  end
  -- What fills the hub: items by slots, the most first.
  function M.fill_text(hub)
    local inv = try(function() return hub.get_inventory(defines.inventory.hub_main) end)
    if not inv then return '?' end
    local by, order = {}, {}
    for i = 1, #inv do
      local st = inv[i]
      if st.valid_for_read then
        if not by[st.name] then by[st.name] = {slots=0, n=0}; order[#order+1] = st.name end
        by[st.name].slots = by[st.name].slots + 1; by[st.name].n = by[st.name].n + st.count
      end
    end
    table.sort(order, function(x, y) return by[x].slots > by[y].slots end)
    local parts = {}
    for i, name in ipairs(order) do if i <= M.TOP then parts[i] = string.format('%s %d (%d slots)', name, by[name].n, by[name].slots) end end
    return table.concat(parts, ', ') .. (#order > M.TOP and ', ...' or '')
  end
  function M.check(pl)
    local st = store()
    local loc = try(function() return pl.space_location and pl.space_location.name end)
    local waiting = try(function() return pl.state end) == defines.space_platform_state.waiting_at_station
    if not (loc and waiting) then st.told[pl.index] = nil; return nil end
    if st.told[pl.index] == loc then return nil end
    local s = try(function() return game.planets[loc].surface end)
    if not s then return nil end
    for _, e in ipairs(api.silos and try(function() return api.silos(pl.force, s) end) or {}) do
      for _, r in ipairs(api.request_rows and try(function() return api.request_rows(e, pl.force, pl.name) end) or {}) do
        if r.flag == 'hub_full' then
          st.told[pl.index] = loc
          local line = string.format('hub full: %s waits at %s with %d free hub slots; the %s payload a rocket from rocket-silo (%g,%g) waits for takes %d; the hub holds %s',
            pl.name, loc, r.hub_free_slots or 0, r.item, e.position.x, e.position.y, r.slots_for_payload or 0, M.fill_text(pl.hub))
          for _, who in ipairs(api.listeners and try(function() return api.listeners(pl) end) or {}) do
            if api.deliver then pcall(api.deliver, who.index, {seq='hubfull', tick=game.tick, from='hub alert', text=line, wake=true}) end
          end
          return line
        end
      end
    end
    return nil
  end
  function M.tick(tick)
    if tick % M.CHECK ~= 29 then return end
    local st = store()
    local list = {}
    for _, f in pairs(game.forces) do
      for _, pl in pairs(try(function() return f.platforms end) or {}) do if pl.valid then list[#list+1] = pl end end
    end
    if #list == 0 then return end
    table.sort(list, function(x, y) return x.index < y.index end)
    if st.next > #list then st.next = 1 end
    local pl = list[st.next]
    st.next = st.next + 1
    M.check(pl)
  end
  return M
end
