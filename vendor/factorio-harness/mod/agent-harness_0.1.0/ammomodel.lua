-- One ammunition model for a trip (d20 batch51 H1, viewer Aurora 09:36: "Could departure and route forecasts use the same
-- ingredient limits as endurance, including shared stock? Otherwise their spare-ammo estimates can contradict a
-- resource shortage."). Before this, platform_endurance's resource rows capped what is made by the ingredients aboard,
-- while its own departure and flight lines, its route forecast and the ammo_rates of preflight and the platforms read
-- multiplied the make rate by the time, uncapped, and counted stranded ammunition (or not) each its own way. Each now asks
-- this model, so the same ship and trip read the same:
-- - stock: every place aboard (freight.lua stock_places), less what can reach no turret (ammofeed.lua: on belts no
--   turret's way reaches, or in a hub no inserter takes from toward a turret);
-- - received: on rockets launched to the platform and not arrived (freight.lua incoming), counted once: it has left the
--   planet's stock, and no other platform's read holds it;
-- - made: the rate measured, at most what the machines aboard can make from the ingredients aboard (two levels down;
--   fluids in tanks and in the makers' fluid boxes) and what reaches them at the rates the ingredients are made aboard.
--   An ingredient two products draw on (iron plates for magazines and rockets) is split between them by the rates they
--   are made at now, so its stock is counted once; what other machines aboard use of it at the rates now (its measured
--   use less the products') is taken off first.
-- binds: which limit sets what is made over a time: the stock (none made aboard), the make rate, or an ingredient.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function round(x, d) local m = 10 ^ (d or 0); return math.floor(x * m + 0.5) / m end
  local function mins(m)
    if not m then return '?' end
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), math.floor(m % 60)) end
    return string.format('%dm%02ds', math.floor(m), math.floor((m % 1) * 60))
  end
  M.mins = mins
  local ALL = setmetatable({}, {__index=function() return true end})
  -- What the model covers: ammunition and repair packs.
  function M.kind(name)
    local t = try(function() return prototypes.item[name].type end)
    return t == 'ammo' or t == 'repair-tool'
  end
  -- o (all optional): places (a stock_places read already made), feed (an ammofeed trace already read; false: none),
  -- feed_why (why there is none), rate(name, category, fluid) (per minute over the caller's window; default the last 10
  -- minutes of the platform's production statistics), fluid_stock(names) (fluids in thrusters and tanks), background
  -- (true: the ammunition trace's last background read, never one in this call: a trace of a few hundred belts took 33 ms
  -- on the private copy, d19 batch45).
  function M.new(pl, o)
    o = o or {}
    local m = {pl=pl}
    local places = o.places
    if places == nil then places = api.stock_places and try(function() return api.stock_places(pl, ALL) end) or false end
    local held = {}
    if places then for k, v in pairs(places.total or {}) do held[k] = v end
    else
      local hub = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
      for _, r in ipairs(hub and try(function() return hub.get_contents() end) or {}) do held[r.name] = (held[r.name] or 0) + r.count end
      for _, t in ipairs(try(function() return pl.surface.find_entities_filtered{type='ammo-turret', force=pl.force} end) or {}) do
        local inv = try(function() return t.get_inventory(defines.inventory.turret_ammo) end)
        for _, r in ipairs(inv and try(function() return inv.get_contents() end) or {}) do held[r.name] = (held[r.name] or 0) + r.count end
      end
    end
    m.places = places or nil
    m.aboard = {}
    for k, v in pairs(held) do m.aboard[k] = v end
    -- What can reach no turret (d17 batch13 B1): left out of the stock projected, and said.
    local tr, why = o.feed, o.feed_why
    if tr == nil then
      tr = api.ammofeed and pl.surface and try(function()
        local t, w
        if o.background and api.ammofeed.get then t, w = api.ammofeed.get(pl, nil, true) else t, w = (api.ammofeed.get or api.ammofeed.trace)(pl) end
        why = w; return t end)
    end
    m.feed, m.feed_why = tr or nil, why
    m.stranded = {}
    if tr then
      for name, n in pairs(tr.stranded_by or {}) do m.stranded[name] = (m.stranded[name] or 0) + n end
      for name, n in pairs(tr.hub_stranded or {}) do m.stranded[name] = (m.stranded[name] or 0) + n end
    end
    for name, n in pairs(m.stranded) do held[name] = math.max(0, (held[name] or 0) - n) end
    m.held = held
    m.received = {}
    local inc = api.incoming and try(function() return api.incoming(pl) end)
    for _, r in ipairs(inc and inc.rows or {}) do
      for name, n in pairs(r.cargo or {}) do if M.kind(name) then m.received[name] = (m.received[name] or 0) + n end end
    end
    local P = defines.flow_precision_index or {}
    local istats, fstats
    local rate = o.rate or function(name, cat, fluid)
      if fluid then fstats = fstats or try(function() return pl.force.get_fluid_production_statistics(pl.surface) end) or false
      else istats = istats or try(function() return pl.force.get_item_production_statistics(pl.surface) end) or false end
      local st = fluid and fstats or istats
      return st and P.ten_minutes and (try(function() return st.get_flow_count{name=name, category=cat, precision_index=P.ten_minutes, count=true} end) or 0) / 10 or 0
    end
    local fluid_stock = o.fluid_stock or function(names)
      local out = {}
      for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{type={'thruster', 'storage-tank'}, force=pl.force} end) or {}) do
        for i = 1, try(function() return #e.fluidbox end) or 0 do
          local f = try(function() return e.fluidbox[i] end)
          if f and names[f.name] then out[f.name] = (out[f.name] or 0) + f.amount end
        end
      end
      return out
    end
    -- The machines aboard that make an item: their recipe, products a craft, and the ingredients in their inputs.
    -- (each machine's recipe and its products read once a call: {e, recipe, made = {product: amount a craft}})
    local makers
    local function maker(name)
      if not makers then
        makers = {}
        for _, e in ipairs(try(function() return pl.surface.find_entities_filtered{type='assembling-machine', force=pl.force} end) or {}) do
          local r = try(function() return e.get_recipe() end)
          if r then
            local made = {}
            for _, pr in ipairs(try(function() return r.products end) or {}) do
              made[pr.name] = (pr.amount or ((pr.amount_min or 0) + (pr.amount_max or 0)) / 2) * (pr.probability or 1)
            end
            makers[#makers+1] = {e=e, r=r, made=made}
          end
        end
      end
      local rec, per, inputs, fluids_in = nil, 0, {}, {}
      for _, mk in ipairs(makers) do
        local e, r, made_here = mk.e, mk.r, mk.made[name] or 0
        if made_here > 0 then
          rec, per = r, made_here
          local inv = try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end)
          for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do inputs[c.name] = (inputs[c.name] or 0) + c.count end
          for i = 1, try(function() return #e.fluidbox end) or 0 do
            local f = try(function() return e.fluidbox[i] end)
            if f and f.name then fluids_in[f.name] = (fluids_in[f.name] or 0) + (f.amount or 0) end
          end
        end
      end
      return rec, per, inputs, fluids_in
    end
    -- An ingredient's pool over t minutes: what is aboard, plus what its own makers can still make (below) or else its
    -- measured make rate, less what machines other than the ones counted use of it (own: their use a minute).
    local function pool(g, t, own)
      local other = math.max(0, g.used - (own or 0))
      return math.max(0, g.have + (g.below and g.below.at(t) or g.made * t) - other * t)
    end
    -- An item's recipe aboard with its ingredients, two levels down; nil when no machine aboard makes it.
    local nodes = {}
    local function node(name, depth)
      depth = depth or 1
      local key = name .. '#' .. depth
      if nodes[key] ~= nil then return nodes[key] or nil end
      local rec, per, inputs, fluids_in = maker(name)
      if not rec then nodes[key] = false; return nil end
      local ings = {}
      for _, ing in ipairs(try(function() return rec.ingredients end) or {}) do
        if (ing.amount or 0) > 0 then
          local fluid = ing.type == 'fluid'
          local have
          if fluid then have = (fluid_stock({[ing.name]=true})[ing.name] or 0) + (fluids_in[ing.name] or 0)
          else have = (held[ing.name] or 0) + (inputs[ing.name] or 0) end
          ings[#ings+1] = {item=ing.name, have=have, amount=ing.amount, fluid=fluid or nil,
            below=not fluid and depth < 2 and node(ing.name, depth + 1) or nil,
            made=rate(ing.name, 'input', fluid), used=rate(ing.name, 'output', fluid)}
        end
      end
      if #ings == 0 then nodes[key] = false; return nil end
      local n = {per=per, ings=ings}
      if depth > 1 then
        -- below: its own measured make rate is what its makers use of each ingredient
        local own = rate(name, 'input', false) / per
        function n.at(t)
          local best, which
          for _, g in ipairs(ings) do
            local more = math.floor(pool(g, t, own * g.amount) / g.amount) * per
            if not best or more < best then best, which = more, g end
          end
          return best, which
        end
        local more, g = n.at(0)
        n.more, n.item, n.have = more, g.item, round(g.have)
      end
      nodes[key] = n
      return n
    end
    -- The products made aboard and their rates (register every one before reading a cap: the split needs them all).
    local rates, caps = {}, {}
    function m.make(name, made)
      if (made or 0) > 0 then rates[name] = made else rates[name] = nil end
      caps = {}
    end
    -- What the products use of each ingredient a minute at their rates: {item: {total, by = {product: use}}}.
    local function uses()
      local u = {}
      for p, r in pairs(rates) do
        local n = node(p)
        for _, g in ipairs(n and n.ings or {}) do
          u[g.item] = u[g.item] or {total=0, by={}}
          local x = r / n.per * g.amount
          u[g.item].total = u[g.item].total + x
          u[g.item].by[p] = x
        end
      end
      return u
    end
    -- The cap on what is made of a product (registered with m.make): {at(t) (at most this many made within t minutes),
    -- more (now), item, have, per_craft, fluid, below {more, item, have}, shared {product: share}, share (this one's),
    -- ingredient_made_per_min, more_per_min}; nil when nothing aboard makes it.
    function m.cap(name)
      if caps[name] ~= nil then return caps[name] or nil end
      local n = rates[name] and node(name)
      if not n then caps[name] = false; return nil end
      local u = uses()
      local cap = {per_craft=nil}
      local function share(g)
        local x = u[g.item]
        return x and x.total > 0 and (x.by[name] or 0) / x.total or 1
      end
      function cap.at(t)
        local best, which
        for _, g in ipairs(n.ings) do
          local more = math.floor(pool(g, t, u[g.item] and u[g.item].total) * share(g) / g.amount) * n.per
          if not best or more < best then best, which = more, g end
        end
        return math.floor(best), which
      end
      local more, g = cap.at(0)
      cap.more, cap.item, cap.have, cap.per_craft, cap.fluid = more, g.item, round(g.have), g.amount, g.fluid
      cap.below = g.below and {more=g.below.more, item=g.below.item, have=g.below.have} or nil
      cap.ingredient_made_per_min = round(g.made, 1)
      cap.more_per_min = round((cap.at(60) - more) / 60, 1)
      local s = share(g)
      if s < 0.999 then
        cap.share = round(s, 2)
        cap.shared = {}
        for p, x in pairs(u[g.item].by) do if p ~= name then cap.shared[p] = round(x / u[g.item].total, 2) end end
      end
      local other = math.max(0, g.used - (u[g.item] and u[g.item].total or 0))
      if other > 0 then cap.other_use_per_min = round(other, 1) end
      caps[name] = cap
      return cap
    end
    -- What is made of a product within t minutes at `made` a minute, with the cap: amount, and the cap when it binds.
    function m.made(name, made, t)
      if not (t and t > 0 and (made or 0) > 0) then return 0 end
      local cap = m.cap(name)
      local c = cap and cap.at(t)
      if c and c < made * t then return c, cap end
      return made * t
    end
    -- The shared ingredient as words: ' shared with rocket (40%)'.
    local function shared_text(cap)
      if not cap.shared then return '' end
      local t = {}
      for p, s in pairs(cap.shared) do t[#t+1] = string.format('%s %d%%', p, math.floor(s * 100 + 0.5)) end
      table.sort(t)
      return string.format(', shared with %s by make rate: this one %d%%', table.concat(t, ', '), math.floor(cap.share * 100 + 0.5))
    end
    -- Which limit sets what is made of a product over t minutes at `made` a minute: {kind (stock | rate | ingredients),
    -- line}. t nil: the limit now (no time to count over).
    function m.binds(name, made, t)
      if (made or 0) <= 0 then return {kind='stock', line='binds: the stock (none made aboard)'} end
      local cap = m.cap(name)
      if not cap then return {kind='rate', line=string.format('binds: the make rate (%g/min; no machine aboard with its recipe read)', round(made, 1))} end
      local c = t and t > 0 and cap.at(t)
      local over = c and string.format(' over %s', mins(t)) or ''
      if (c and c < made * t) or (not t and cap.more == 0) then
        return {kind='ingredients', item=cap.item, line=string.format('binds: the ingredients: %s (%d%s aboard%s%s): at most %d more%s, against %d at %g/min',
          cap.item, cap.have, cap.fluid and ' units' or '', shared_text(cap), cap.other_use_per_min and string.format('; other machines use %g/min of it', cap.other_use_per_min) or '',
          c or cap.more, over, math.floor(made * (t or 0) + 0.5), round(made, 1))}
      end
      return {kind='rate', line=string.format('binds: the make rate (%g/min; the ingredients aboard cover %s%s)', round(made, 1),
        t and mins(t) or 'it now', cap.item and string.format(', %s the closest at %d more%s', cap.item, c or cap.more, shared_text(cap)) or '')}
    end
    -- At t minutes at made and used a minute: what is left (stock + received + made - used; may be negative).
    function m.left(name, made, used, t, stock)
      return (stock or m.held[name] or 0) + (m.received[name] or 0) + m.made(name, made, t) - (used or 0) * t
    end
    -- When what is left reaches 0 at made and used a minute (minutes, at most a day ahead), or nil: with a cap, the first
    -- quarter minute it is gone, then halved to a second.
    function m.lasts(name, made, used, stock)
      if (used or 0) <= 0 then return nil end
      local cap = (made or 0) > 0 and m.cap(name)
      if not cap then
        local net = (made or 0) - used
        return net < 0 and ((stock or m.held[name] or 0) + (m.received[name] or 0)) / -net or nil
      end
      local function at(t) return m.left(name, made, used, t, stock) end
      if at(1440) > 0 then return nil end
      local lo, hi = 0, 0.25
      while at(hi) > 0 do lo, hi = hi, hi + 0.25 end
      for _ = 1, 8 do local mid = (lo + hi) / 2; if at(mid) > 0 then lo = mid else hi = mid end end
      return hi
    end
    return m
  end
  return M
end
