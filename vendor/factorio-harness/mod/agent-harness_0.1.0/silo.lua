-- A rocket silo as its GUI and the entities around it show it (Gemini, shift09
-- 00:20: "A dedicated silo status command (parts X/50, loaded cargo weight,
-- missing ingredients)"). One read for the nearest silo or every silo on a
-- surface: rocket parts against the 2.0 rocket_parts_required, the silo's state
-- and crafting status, each rocket part ingredient with what the silo holds and
-- what its feeding inserters hold and take from, whether the rocket is ready,
-- the cargo against a rocket's lift and slots (cargo.lua), the automatic
-- requests checkbox, our platforms in orbit above, and the last launch.
-- Launches are recorded when the game orders one (on_rocket_launch_ordered,
-- forwarded by control.lua) and when an agent's launch call goes through.
-- Bounded: 16 silos, the inserters within 8 tiles of each. Read only.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local M = {}
  local MAX_SILOS, FEED_REACH, MAX_FEEDERS, MAX_RECORDS = 16, 8, 64, 32
  -- request rows: shown in a silo's row, read by default, read with requests: true, a page of those
  local REQ_SHOWN, REQ_READ, REQ_ALL, REQ_PAGE = 8, 48, 192, 48
  local FLAG_ORDER = {'filling', 'matched', 'split_networks', 'hub_full', 'below_min_payload', 'on_the_way'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  -- (d20 batch55 P6, Grok #1413: a hub read "holds 0 lacks 500" while a science rocket flew to it) what rockets launched
  -- to a hub carry to it now: its requester point's deliveries on the way, the hub GUI's in-transit count (2.0.77: a
  -- launch of 100 iron plates read 100 from the launch until the pod landed, then 0). By name and quality.
  function M.on_the_way(hub)
    local out = {}
    local pt = defines.logistic_member_index and defines.logistic_member_index.space_platform_hub_requester
      and try(function() return hub.get_logistic_point(defines.logistic_member_index.space_platform_hub_requester) end)
    for _, it in ipairs(pt and try(function() return pt.targeted_items_deliver end) or {}) do
      local q = type(it.quality) == 'string' and it.quality or try(function() return it.quality.name end) or 'normal'
      local k = it.name .. '@' .. q
      out[k] = (out[k] or 0) + (it.count or 0)
    end
    return out
  end
  local function invert(t) local out = {} for k, v in pairs(t or {}) do out[v] = k end return out end
  -- (d22 batch91 BA1, Sol #1881: Meridian-V asked thruster@legendary 4 from Vulcanus; 4 legendary sat in storage and the
  -- silo read "holds 0" and the network "0") 2.0.77's get_item_count(name) counts normal quality alone (read on a copy
  -- of world n: Meridian-V's hub 2 solar-panel by name, 4 epic; network 22 0 accumulator by name, 12 epic). A request
  -- counts what its quality and comparator take (the request's value: {name, quality, comparator}; "=" when none).
  local CMP = {['=']='=', ['>']='>', ['<']='<', ['>=']='>=', ['≥']='>=', ['<=']='<=', ['≤']='<=', ['!=']='!=', ['≠']='!='}
  function M.want(v)
    local q = v and (type(v.quality) == 'string' and v.quality or try(function() return v.quality.name end)) or 'normal'
    local c = v and v.comparator
    c = CMP[type(c) == 'string' and c or '='] or '='
    return q, c
  end
  -- The qualities a request takes: its own with "=", else every quality whose level passes the comparator.
  function M.qualities(q, cmp)
    if cmp == '=' then return {q} end
    local lv = try(function() return prototypes.quality[q].level end)
    local out = {}
    for name, pq in pairs(try(function() return prototypes.quality end) or {}) do
      local l = try(function() return pq.level end)
      if lv and l and name ~= 'quality-unknown' and ((cmp == '>' and l > lv) or (cmp == '<' and l < lv) or (cmp == '>=' and l >= lv)
          or (cmp == '<=' and l <= lv) or (cmp == '!=' and l ~= lv)) then out[#out+1] = name end
    end
    table.sort(out)
    return out
  end
  -- fn(id) counted over the qualities a request takes (a plain name for normal: the call it always was)
  function M.count_q(fn, name, q, cmp)
    local n = 0
    for _, qn in ipairs(M.qualities(q, cmp)) do n = n + (try(function() return fn(qn == 'normal' and name or {name=name, quality=qn}) end) or 0) end
    return n
  end
  -- "accumulator (epic)", "thruster (>= rare)"; the name alone for a normal "=" request.
  function M.label(name, q, cmp)
    if q == 'normal' and cmp == '=' then return name end
    return string.format('%s (%s%s)', name, cmp ~= '=' and cmp .. ' ' or '', q)
  end
  local function at(pos) return string.format('(%g,%g)', pos.x, pos.y) end
  local function ago(ticks)
    local s = math.floor(ticks / 60)
    if s >= 3600 then return string.format('%dh%02dm', math.floor(s / 3600), math.floor(s / 60) % 60) end
    return s >= 60 and string.format('%dm%02ds', math.floor(s / 60), s % 60) or s .. 's'
  end
  local function input_inventory(e)
    local i = defines.inventory.crafter_input or defines.inventory.assembling_machine_input
    return i and try(function() return e.get_inventory(i) end)
  end
  local function items_text(list, limit)
    if not list or #list == 0 then return nil end
    table.sort(list, function(x, y) if x.count ~= y.count then return x.count > y.count end return x.name < y.name end)
    local out = {}
    for i = 1, math.min(#list, limit) do
      local s = list[i]
      out[i] = s.name .. (s.quality and s.quality ~= 'normal' and '@' .. s.quality or '') .. '*' .. s.count
    end
    return table.concat(out, ' ') .. (#list > limit and string.format(' +%d more', #list - limit) or '')
  end
  local function contents(inv) return inv and try(function() return inv.get_contents() end) or {} end
  -- What a feeder's source holds of the named items: a belt's lines, else its output inventory.
  local function holds(e, names)
    local out = {}
    if e.type == 'transport-belt' or e.type == 'underground-belt' or e.type == 'splitter' then
      for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
        for k, v in pairs(try(function() return e.get_transport_line(i).get_contents() end) or {}) do
          local name, n = type(v) == 'table' and v.name or k, type(v) == 'table' and v.count or v
          if names[name] then out[name] = (out[name] or 0) + n end
        end
      end
    else
      local inv = try(function() return e.get_output_inventory() end)
      for _, s in ipairs(contents(inv)) do if names[s.name] then out[s.name] = (out[s.name] or 0) + s.count end end
    end
    return out
  end

  -- Launch records --------------------------------------------------------------
  -- (d17 batch23 B3, Gemini and Sonnet) rocket parts made per silo: its products_finished sampled (a read, and the
  -- alert scan) at most once every 10 s, the last 64 samples; the rate over the last 10 minutes of them.
  function M.sample_made(e)
    local st = api.state and api.state()
    if not st then return nil end
    st.silo_made = st.silo_made or {}
    local unit = e.unit_number or -1
    local list = st.silo_made[unit] or {}
    st.silo_made[unit] = list
    -- (d20 batch52 K8, Astra #1277: 0.3 parts a minute while a part came every 5 s) a silo's products_finished counts
    -- rockets, not parts (2.0.77 on the private copy: 331 -> 332 as a rocket launched while rocket_parts went 0 -> 13
    -- over 50 s): parts made are finished rockets times the parts a rocket takes, plus the parts of the one building
    local fin = try(function() return e.products_finished end)
    if not fin then return nil end
    local req = try(function() return e.prototype.rocket_parts_required end) or 1
    local n = fin * req + (try(function() return e.rocket_parts end) or 0)
    local last = list[#list]
    -- (d18 batch38 C3, Sonnet: 0.3 a minute idle against 55 while a load waits read as a contradiction) each sample with
    -- what the silo was doing: building parts, short of an ingredient, or holding a built rocket (parts are made only
    -- while it builds)
    local now_state = M.made_state(e)
    -- (K8) samples kept before parts were counted held rockets: dropped
    if last and not last.parts then for i = #list, 1, -1 do list[i] = nil end; last = nil end
    if not last or game.tick - last.tick >= 600 or n < last.n then
      if last and n < last.n then for i = #list, 1, -1 do list[i] = nil end end
      list[#list+1] = {tick=game.tick, n=n, s=now_state, parts=true}
      while #list > 64 do table.remove(list, 1) end
    end
    local from, fi
    for i, x in ipairs(list) do if game.tick - x.tick <= 36000 and x.tick < game.tick then from, fi = x, i; break end end
    local rate = from and (n - from.n) / ((game.tick - from.tick) / 3600) or nil
    -- the window's time by state (each interval counted at its start's state) and the rate while building
    local spent, built_parts = {}, 0
    if from then
      for i = fi, #list do
        local x, y = list[i], list[i + 1]
        local t1, n1 = y and y.tick or game.tick, y and y.n or n
        local k = x.s or 'unknown'
        spent[k] = (spent[k] or 0) + (t1 - x.tick)
        if k == 'building' then built_parts = built_parts + (n1 - x.n) end
      end
    end
    local b = spent.building or 0
    return {made=n, per_min=rate and math.floor(rate * 10 + 0.5) / 10 or nil, over_s=from and math.floor((game.tick - from.tick) / 60) or nil,
      spent=from and spent or nil, while_building=b >= 600 and math.floor(built_parts / (b / 3600) * 10 + 0.5) / 10 or nil, state=now_state}
  end
  -- What a silo is doing for the rate's window: building (parts in progress), short (building, an ingredient short),
  -- ready (a built rocket stands: no parts until it launches), other.
  function M.made_state(e)
    local rs = try(function() return e.rocket_silo_status end)
    local building = defines.rocket_silo_status and rs == defines.rocket_silo_status.building_rocket
    if not building then return rs ~= nil and 'ready' or 'other' end
    local st = api.status_name and try(function() return api.status_name(e) end)
    if st == 'item_ingredient_shortage' or st == 'no_ingredients' or st == 'fluid_ingredient_shortage' then return 'short' end
    return 'building'
  end
  local STATE_WORDS = {building='building parts', short='short of an ingredient', ready='holding a built rocket (no parts until it launches)', other='neither', unknown='unknown'}
  -- "0.3 a minute over the last 10m00s: building parts 1m00s (about 3 a minute then), holding a built rocket 9m00s"
  function M.rate_text(made)
    if not (made and made.per_min) then return nil end
    local parts = {}
    for _, k in ipairs({'building', 'short', 'ready', 'other', 'unknown'}) do
      local t = made.spent and made.spent[k]
      if t and t > 0 then
        parts[#parts+1] = STATE_WORDS[k] .. ' ' .. ago(t) .. (k == 'building' and made.while_building and string.format(' (%g a minute then)', made.while_building) or '')
      end
    end
    return string.format('%g a minute over the last %s (samples at most every 10 s)%s', made.per_min, ago(made.over_s * 60),
      #parts > 0 and ': ' .. table.concat(parts, ', ') or '')
  end
  local function records()
    local s = api.state()
    s.silo_launches = s.silo_launches or {}
    return s.silo_launches
  end
  M.SAME_LAUNCH = 600
  -- One record per silo (the latest), at most MAX_RECORDS silos kept.
  function M.record(silo, fields)
    local unit = try(function() return silo.unit_number end)
    if not unit then return end
    local list = records()
    local r = list[unit]
    -- The game's launch-ordered event a few ticks after our launch call is the same launch, not another (d17 batch12
    -- C6, Sol: a second load_silo step read it as a launch made under it and ended rocket_launched with 0 loaded).
    if fields.ordered and r and r.called and not r.ordered and game.tick - r.tick <= M.SAME_LAUNCH then
      for k, v in pairs(fields) do if v ~= nil and k ~= 'by' then r[k] = v end end
      return
    end
    if not (r and r.tick == game.tick) then
      r = {tick=game.tick, surface=try(function() return silo.surface.name end), position=try(function() return silo.position end)}
      list[unit] = r
    end
    for k, v in pairs(fields) do if v ~= nil then r[k] = v end end
    local n, oldest, at_tick = 0, nil, math.huge
    for u, x in pairs(list) do n = n + 1; if x.tick < at_tick then oldest, at_tick = u, x.tick end end
    if n > MAX_RECORDS and oldest then list[oldest] = nil end
  end
  -- The newest launch recorded to a platform with who made it ({tick, cargo, to, by, surface}), or nil (shipment.lua).
  function M.last_to(platform)
    local best
    for _, r in pairs(records()) do
      if r.to == 'platform ' .. platform and (not best or r.tick > best.tick) then best = r end
    end
    return best
  end
  -- The silo's last launch as recorded ({tick, cargo, to, by}), or nil.
  function M.last_launch(silo)
    local unit = try(function() return silo.unit_number end)
    return unit and records()[unit] or nil
  end
  local destinations
  local function destination_text(d)
    if not d then return nil end
    destinations = destinations or invert(defines.cargo_destination)
    local kind = destinations[d.type] or tostring(d.type)
    local pl = (d.station and try(function() return d.station.surface.platform end)) or d.space_platform
    if pl and try(function() return pl.valid end) then
      return 'platform ' .. pl.name .. (kind == 'space_platform' and ' (its starter pack)' or '')
    end
    if kind == 'surface' and d.surface then return 'surface ' .. tostring(try(function() return d.surface.name end)) end
    return kind
  end
  -- (d19 batch45, batch40 B2, Grok: a stale provider pile looked like the load that launched) each spoilable item in an
  -- inventory with its spread (spoil.lua spread_text: spoiled share by count, range, quarters, how many spoil within
  -- 10, 30 and 60 min); nil when none spoils
  function M.spoil_lines(inv)
    local sp = api.spoil and api.spoil()
    if not (sp and inv) then return nil end
    local acc = try(function() return sp.inventory(inv, {}) end) or {}
    local out = {}
    for _, r in ipairs(acc) do out[#out+1] = try(function() return sp.spread_text(r) end) end
    table.sort(out)
    return #out > 0 and out or nil
  end
  -- on_rocket_launch_ordered: the rocket's cargo pod holds the cargo and knows where it goes.
  function M.on_launch_ordered(event)
    local silo = event.rocket_silo
    if not (silo and silo.valid) then return end
    local pod = try(function() return event.rocket.attached_cargo_pod end)
    local inv = pod and defines.inventory.cargo_unit and try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    local cargo = items_text(contents(inv), 8)
    local by = event.player_index and try(function() return game.get_player(event.player_index).name end)
    M.record(silo, {cargo=cargo or 'empty', to=destination_text(pod and try(function() return pod.cargo_pod_destination end)), by=by, ordered=true, up=event.harness_up,
      spoil=M.spoil_lines(inv)})
  end

  -- The rocket in words (Astra 10:50: teammates read a ready rocket's 0/50 parts, and a rising one, as launched or as
  -- a missing kit three times): ready to launch, or rising into place, not launched; launching; or building, parts
  -- X/Y. Then the last launch. A built rocket's parts are used, and the silo goes on making the next one's: those are
  -- next_parts, said as the next rocket's (round1650d: Grok read "rocket built and ready: parts consumed (13/50)" as a
  -- rocket still being built and held Sunward's cargo rockets 5 min). {rocket_ready, parts (while building),
  -- next_parts (once built), rocket (all of it), rocket_now, last (the last-launch part)}.
  local silo_states
  local RISING = {create_rocket=true, lights_blinking_open=true, doors_opening=true, doors_opened=true, rocket_rising=true,
    arms_advance=true}
  local LAUNCHING = {launch_starting=true, launch_started=true, engine_starting=true, arms_retract=true, rocket_flying=true,
    lights_blinking_close=true, doors_closing=true}
  function M.rocket(e)
    silo_states = silo_states or invert(defines.rocket_silo_status)
    local st = try(function() return e.rocket_silo_status end)
    local state = silo_states[st] or tostring(st)
    local ready = st ~= nil and st == defines.rocket_silo_status.rocket_ready
    local parts = try(function() return e.rocket_parts end) or 0
    local required = try(function() return e.prototype.rocket_parts_required end) or 0
    -- A built rocket's own parts are said with it (shift14 21:20: Grok read rocket_ready beside next_parts 6/50, 27 s
    -- after a launch, as a rocket with 6 of its parts; it was the rocket whose 50 parts the silo had made while the one
    -- before waited, and it launched): built_parts, and the count after it as the rocket after it's.
    local now, next_parts, built
    if ready or RISING[state] then built = required .. '/' .. required end
    if ready then
      now = string.format('rocket built (%s parts) and ready to launch, not launched', built)
    elseif RISING[state] then
      now = string.format('rocket built (%s parts), rising into place (%s), not launched', built, (state:gsub('_', ' ')))
    elseif LAUNCHING[state] then
      now = string.format('rocket launching (%s)', (state:gsub('_', ' ')))
    else
      now = string.format('building the rocket: parts %d/%d', parts, required)
    end
    if ready or RISING[state] or LAUNCHING[state] then
      next_parts = parts .. '/' .. required
      now = now .. '; parts for the rocket after it ' .. next_parts
    end
    local last = records()[try(function() return e.unit_number end) or -1]
    -- (d18 batch39 B1) the launch's tick and ledger id, and the tick this was read: shipment names the same launch so
    local last_text = (last and string.format('last launch %s ago (%stick %d)%s', ago(game.tick - last.tick), last.up and 'up #' .. last.up .. ', ' or '', last.tick, last.to and ' to ' .. last.to or '')
      or 'no launch seen')
    return {rocket_ready=ready, parts=not next_parts and parts .. '/' .. required or nil, next_parts=next_parts, built_parts=built,
      rocket=now .. '; ' .. last_text, rocket_now=now, last=last_text,
      last_launch=last and {ago=ago(game.tick - last.tick), tick=last.tick, up=last.up, to=last.to, cargo=last.cargo, by=last.by} or nil, read_tick=game.tick}
  end

  -- The silo's inventories by their transfer names (Luna 12:20: a 50/50/50 kit went into the rocket cargo instead of
  -- the recipe input): what each holds, what it is for, and one transfer call for it. parts and cargo are aliases
  -- transfer takes for a silo (runtime.lua M.INVENTORY_ALIASES).
  M.ALIASES = {parts='assembling_machine_input', cargo='rocket_silo_rocket'}
  function M.ingredients(e)
    local recipe = try(function() return e.get_recipe() end)
    local names = {}
    for _, ing in ipairs(recipe and recipe.ingredients or {}) do if ing.type == 'item' then names[#names+1] = ing.name end end
    return names, recipe and recipe.name or 'rocket-part'
  end
  function M.inventories(e, encode)
    local pos = {x=e.position.x, y=e.position.y}
    local names, recipe = M.ingredients(e)
    local function call(args) return "fh call transfer --args '" .. encode(args) .. "'" end
    local function held(inv) return items_text(contents(inv), 8) or 'empty' end
    local rows = {}
    rows[1] = {inventory='assembling_machine_input', alias='parts', holds=held(input_inventory(e)),
      what=string.format("the %s recipe's ingredients (%s): the silo crafts rocket parts from them", recipe,
        #names > 0 and table.concat(names, ', ') or 'none'),
      example=call{position=pos, direction='to_entity', item=names[1] or 'low-density-structure', count=50, inventory='assembling_machine_input'}}
    local rocket_inv = defines.inventory.rocket_silo_rocket and try(function() return e.get_inventory(defines.inventory.rocket_silo_rocket) end)
    local lift = api.cargo.limits(e)
    local loaded = contents(rocket_inv)
    rows[2] = {inventory='rocket_silo_rocket', alias='cargo', holds=rocket_inv and held(rocket_inv) or 'no rocket to load yet',
      what=string.format("the rocket's cargo: it goes up with the rocket at launch (lift %g kg); not used for parts", api.cargo.kg(lift)),
      example=call{position=pos, direction='to_entity', item=loaded[1] and loaded[1].name or 'space-platform-foundation', count=10, inventory='rocket_silo_rocket'}}
    -- Cargo comes out again by hand, as the silo's GUI allows, without a launch (Luna, shift17 10:50: 447 spoilage in
    -- Gleba's rocket "and no way to clear it"; her transfer to_player from it at 11:46 moved 648 iron plates out).
    local spoiled = 0
    for _, s in ipairs(loaded) do if s.name == 'spoilage' then spoiled = spoiled + s.count end end
    if rocket_inv and #loaded > 0 then
      rows[2].take_example = call{position=pos, direction='to_player', item=spoiled > 0 and 'spoilage' or loaded[1].name, inventory='rocket_silo_rocket'}
      rows[2].what = rows[2].what .. '; it comes out by hand without a launch (take_example)'
    end
    if spoiled > 0 then rows[2].spoilage = spoiled end
    local trash = defines.inventory.rocket_silo_trash and try(function() return e.get_inventory(defines.inventory.rocket_silo_trash) end)
    if trash then
      rows[3] = {inventory='rocket_silo_trash', holds=held(trash),
        what='trash slots: items the game moved out of the rocket (cargo loaded by hand while automatic requests are on); take-only',
        example=call{position=pos, direction='to_player', inventory='rocket_silo_trash'}}
    end
    return rows
  end

  -- The read --------------------------------------------------------------------
  local function feeders(e, recipe_items)
    local box = {left_top={x=e.position.x - FEED_REACH, y=e.position.y - FEED_REACH}, right_bottom={x=e.position.x + FEED_REACH, y=e.position.y + FEED_REACH}}
    local list = try(function() return e.surface.find_entities_filtered{area=box, type='inserter', force=e.force, limit=MAX_FEEDERS} end) or {}
    local out = {n=0, idle={}, hands={}, sources={}, at={}}
    local seen = {}
    for _, ins in ipairs(list) do
      if ins.valid and try(function() return ins.drop_target end) == e then
        out.n = out.n + 1
        local held = try(function() local h = ins.held_stack; return h.valid_for_read and {name=h.name, count=h.count} end)
        if held and recipe_items[held.name] then out.hands[held.name] = (out.hands[held.name] or 0) + held.count end
        local src = try(function() return ins.pickup_target end)
        local status = api.status_name(ins) or 'unknown'
        if status ~= 'working' and not held then
          local why = status
          if status == 'waiting_for_source_items' then why = src and 'source ' .. src.name .. ' ' .. at(src.position) .. ' holds no ingredient it takes' or 'nothing to pick up from' end
          out.idle[why] = (out.idle[why] or 0) + 1
        end
        if src and src.valid then
          local key = src.unit_number or at(src.position)
          if not seen[key] then
            seen[key] = true
            local h = holds(src, recipe_items)
            for name, n in pairs(h) do out.at[name] = (out.at[name] or 0) + n end
            out.sources[#out.sources+1] = src.name .. ' ' .. at(src.position)
          end
        end
      end
    end
    return out
  end
  local function platforms_above(force, planet)
    if not planet then return nil end
    local out = {}
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      if pl.valid and try(function() return pl.space_location and pl.space_location.name end) == planet then
        local waiting = pl.state == (defines.space_platform_state or {}).waiting_for_starter_pack
        out[#out+1] = pl.name .. (waiting and ' (waiting for its starter pack)' or '')
      end
    end
    table.sort(out)
    return #out > 0 and out or nil
  end
  -- Ours flying toward this planet now (the leg's end headed for, freight.lua's rule), with where from and how far flown.
  local function platforms_coming(force, planet)
    if not planet or not api.leg then return nil end
    local out = {}
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      local leg = pl.valid and try(function() return api.leg(pl) end)
      if leg and leg.to == planet then out[#out+1] = string.format('%s (from %s, %d%% flown)', pl.name, leg.from, math.floor((leg.flown or 0) * 100 + 0.5)) end
    end
    table.sort(out)
    return #out > 0 and out or nil
  end
  function M.view(e, force, opts)
    opts = opts or {}
    silo_states = silo_states or invert(defines.rocket_silo_status)
    -- (the per-part crafting below counts parts left only while the rocket is still being built)
    local proto = e.prototype
    local required = try(function() return proto.rocket_parts_required end) or 0
    local parts = try(function() return e.rocket_parts end) or 0
    local state = silo_states[e.rocket_silo_status] or tostring(e.rocket_silo_status)
    local ready = e.rocket_silo_status == defines.rocket_silo_status.rocket_ready
    local status = api.status_name(e) or 'unknown'
    local rk = M.rocket(e)
    local row = {name=e.name, position=e.position, surface=e.surface.name, parts=rk.parts, built_parts=rk.built_parts, next_parts=rk.next_parts, rocket_ready=ready,
      rocket=rk.rocket, state=state, status=status}
    local made = M.sample_made(e)
    -- A built rocket's parts are consumed: none are left to make for it.
    local left = (ready or RISING[state]) and 0 or math.max(0, required - parts)
    local words = {}
    words[#words+1] = string.format('%s %s on %s: %s', e.name, at(e.position), e.surface.name, rk.rocket_now)
    if made then
      row.parts_made, row.parts_per_min = made.made, made.per_min
      row.parts_rate = M.rate_text(made)
      row.parts_per_min_building = made.while_building
      words[#words+1] = string.format('rocket parts made %d%s', made.made, row.parts_rate and ', ' .. row.parts_rate
        or ' (the rate needs a second sample, 10 s or more later)')
    end
    -- Crafting: the part in progress, and the rest of the rocket at this speed.
    local recipe = try(function() return e.get_recipe() end)
    -- (d20 batch55 P7) the machine's productivity with the recipe's research (rocket part productivity), capped
    local prod = 1 + math.min((try(function() return e.productivity_bonus end) or 0) + (recipe and try(function() return e.force.recipes[recipe.name].productivity_bonus end) or 0),
      recipe and try(function() return recipe.prototype.maximum_productivity end) or 3)
    local crafts_left = math.ceil(left / prod - 1e-9)
    local crafting = try(function() return e.is_crafting() end) and true or false
    local progress = try(function() return e.crafting_progress end) or 0
    if recipe and left > 0 then
      local speed = try(function() return e.crafting_speed end) or 0
      local each = speed > 0 and (try(function() return recipe.energy end) or 0) / speed or nil
      row.crafting = {part_progress=crafting and string.format('%d%%', math.floor(progress * 100)) or nil, parts_left=left,
        part_s=each and math.floor(each * 100 + 0.5) / 100 or nil, productivity=prod > 1 and string.format('+%d%%', math.floor((prod - 1) * 100 + 0.5)) or nil}
      if status == 'working' and each then
        row.crafting.rocket_eta_s = math.ceil((crafts_left - (crafting and progress or 0)) * each)
        words[#words+1] = string.format('%s (part %d%%), %d parts left, the rocket in %s at this speed', status, math.floor(progress * 100), left, ago(row.crafting.rocket_eta_s * 60))
      else
        words[#words+1] = string.format('%s, %d parts left', status:gsub('_', ' '), left)
      end
    elseif not ready and not RISING[state] then
      words[#words+1] = (status:gsub('_', ' '))
    end
    -- Ingredients for the parts left: in the silo, in feeders' hands, at their sources.
    if recipe then
      local names = {}
      for _, ing in ipairs(recipe.ingredients or {}) do if ing.type == 'item' then names[ing.name] = true end end
      local feed = feeders(e, names)
      local inv = input_inventory(e)
      local list, lacks, short = {}, {}, {}
      local to_start = math.max(0, crafts_left - (crafting and 1 or 0))
      for _, ing in ipairs(recipe.ingredients or {}) do
        local have = inv and try(function() return inv.get_item_count(ing.name) end) or 0
        local r = {name=ing.name, per_part=ing.amount, in_silo=have, in_hands=feed.hands[ing.name] or 0, at_sources=feed.at[ing.name] or 0,
          needed=ing.amount * to_start}
        r.short = math.max(0, r.needed - r.in_silo - r.in_hands - r.at_sources)
        if r.short == 0 then r.short = nil end
        list[#list+1] = r
        if have < ing.amount and to_start > 0 then lacks[#lacks+1] = ing.name end
        if r.short then short[#short+1] = string.format('%s %d', ing.name, r.short) end
      end
      row.ingredients = list
      row.lacks = #lacks > 0 and lacks or nil
      local idle = {}
      for why, n in pairs(feed.idle) do idle[#idle+1] = n .. ' idle: ' .. why end
      table.sort(idle)
      row.feeders = {inserters=feed.n, idle=#idle > 0 and idle or nil, sources=#feed.sources > 0 and feed.sources or nil}
      if left > 0 then
        local parts_text = {}
        for _, r in ipairs(list) do
          parts_text[#parts_text+1] = string.format('%s %d in the silo, %d at feeders (%d needed)', r.name, r.in_silo, r.in_hands + r.at_sources, r.needed)
        end
        words[#words+1] = 'for the parts left: ' .. table.concat(parts_text, ', ')
        if #lacks > 0 then words[#words+1] = 'lacks ' .. table.concat(lacks, ', ') .. ' in the silo' end
        if #short > 0 then words[#words+1] = 'short for this rocket: ' .. table.concat(short, ', ') end
        words[#words+1] = feed.n == 0 and 'no inserter feeds it'
          or string.format('%d feeding inserters%s', feed.n, #idle > 0 and ' (' .. table.concat(idle, '; ') .. ')' or '')
      end
    end
    -- Cargo against a rocket's lift and slots.
    local rocket_inv = defines.inventory.rocket_silo_rocket and try(function() return e.get_inventory(defines.inventory.rocket_silo_rocket) end)
    -- (B2) a spoilable item in the silo's input (the parts' ingredients) with its spread
    row.input_spoil = M.spoil_lines(try(function() return e.get_inventory(defines.inventory.assembling_machine_input) end))
    local loaded = {}
    for _, s in ipairs(contents(rocket_inv)) do loaded[#loaded+1] = {name=s.name, count=s.count, quality=s.quality ~= 'normal' and s.quality or nil} end
    local lift, slots = api.cargo.limits(e)
    if #loaded > 0 then
      local w = api.cargo.weigh(loaded, lift, slots)
      -- room_kg (batch24 A4, Gemini: what is aboard and the room left without a full inspect)
      local room = math.max(0, math.floor((api.cargo.kg(lift) - w.total_kg) * 10 + 0.5) / 10)
      row.cargo = {kg=w.total_kg, lift_kg=api.cargo.kg(lift), room_kg=room, stacks=w.stacks, slots=slots, items=items_text(loaded, 8),
        over_kg=w.total_kg > api.cargo.kg(lift) and math.floor((w.total_kg - api.cargo.kg(lift)) * 10 + 0.5) / 10 or nil}
      words[#words+1] = string.format('cargo %g/%g kg (%g kg free), %d/%d slots: %s', w.total_kg, api.cargo.kg(lift), room, w.stacks, slots, row.cargo.items)
      -- (B2) what of it spoils, and how far it has spoiled
      row.cargo.spoil = M.spoil_lines(rocket_inv)
      if row.cargo.spoil then words[#words+1] = 'aboard: ' .. table.concat(row.cargo.spoil, '; ') end
    else
      row.cargo = {kg=0, lift_kg=api.cargo.kg(lift), room_kg=api.cargo.kg(lift), stacks=0, slots=slots}
      words[#words+1] = rocket_inv and 'no cargo loaded' or 'no rocket to load yet'
    end
    local trash = defines.inventory.rocket_silo_trash and try(function() return e.get_inventory(defines.inventory.rocket_silo_trash) end)
    row.trash = items_text(contents(trash), 8)
    if row.trash then words[#words+1] = 'trash slots: ' .. row.trash .. ' (never launched; transfer {position, direction: to_player, inventory: rocket_silo_trash} takes it back)' end
    row.auto_requests = try(function() return e.use_transitional_requests end) and true or false
    -- each request a platform above makes of this planet, flagged (A8)
    -- (d17 batch35 B5, Gemini 14:16: 8 platforms and 2 silos, the rows past 8 dropped with no word) ordered by flag, the
    -- first 8 with the count of the rest and of each flag; requests: true gives every row, REQ_PAGE a page
    local okr, reqs, unread = pcall(M.request_rows, e, force, nil, nil, opts.requests and REQ_ALL or nil)
    if okr and reqs and #reqs > 0 then
      row.platform_requests = {}
      local first, last = 1, math.min(#reqs, REQ_SHOWN)
      if opts.requests then first = (opts.page - 1) * REQ_PAGE + 1; last = math.min(#reqs, first + REQ_PAGE - 1) end
      for i = first, last do
        local r = reqs[i]
        row.platform_requests[#row.platform_requests+1] = {platform=r.platform, item=r.item, flag=r.flag, network_can_give=r.network_holds,
          providers=r.providers, storage=r.storage, next_launch=r.next_launch, line=r.line}
      end
      local n, by = {}, {}
      for _, r in ipairs(reqs) do by[r.flag] = (by[r.flag] or 0) + 1 end
      for _, f in ipairs(FLAG_ORDER) do if by[f] then n[#n+1] = f .. ' ' .. by[f] end end
      local total = #reqs + (unread or 0)
      row.platform_requests_count = total
      row.platform_requests_flags = table.concat(n, ', ')
      local shown = #row.platform_requests
      local rest = total - shown
      if opts.requests then
        row.platform_requests_page = opts.page
        row.platform_requests_pages = math.max(1, math.ceil(#reqs / REQ_PAGE))
        words[#words+1] = string.format('platform requests %d (%s): rows %d-%d listed, page %d of %d%s', total, row.platform_requests_flags,
          first, first + shown - 1, opts.page, row.platform_requests_pages,
          (unread or 0) > 0 and string.format('; %d more not read (the first %d are)', unread, REQ_ALL) or '')
        if shown == 0 then words[#words] = string.format('platform requests %d (%s): no rows on page %d of %d', total, row.platform_requests_flags, opts.page, row.platform_requests_pages) end
      else
        row.platform_requests_more = rest > 0 and rest or nil
        words[#words+1] = string.format('platform requests %d (%s)%s', total, row.platform_requests_flags,
          rest > 0 and string.format(': the first %d listed, %d more (silo {position, requests: true} lists every one)', shown, rest) or '')
      end
    end
    -- (B3) the next automatic launch: the request filled now, else the first a rocket's payload is there for
    -- (d20 batch52 K8, Astra #1277: "rocket 25 filling" while the rocket held 56 magazines of the 100 the silo asked) of
    -- the target's rows, the item the silo's own request asks or its rocket holds
    local nxt
    local asked = {}
    local pt = defines.logistic_member_index and defines.logistic_member_index.rocket_silo_requester
      and try(function() return e.get_logistic_point(defines.logistic_member_index.rocket_silo_requester) end)
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      local name = type(f.name) == 'string' and f.name or try(function() return f.name.name end)
      if name and (f.count or 0) > 0 then asked[name] = f.count end
    end
    for _, s in ipairs(contents(rocket_inv)) do asked[s.name] = asked[s.name] or true end
    for _, r in ipairs(okr and reqs or {}) do if r.filling and asked[r.item] then nxt = r; break end end
    if not nxt then for _, r in ipairs(okr and reqs or {}) do if r.filling then nxt = r; break end end end
    if not nxt then for _, r in ipairs(okr and reqs or {}) do if r.flag == 'matched' then nxt = r; break end end end
    if nxt and nxt.next_launch then
      row.next_auto_launch = string.format('%s %s: %s%s', nxt.platform, nxt.item, nxt.min_payload and 'under min_payload, ' .. nxt.min_payload or 'full, ' .. tostring(nxt.full_rocket),
        nxt.filling and ' (filling now: the game\'s target for the silo\'s requests)' or ' (the network can give it now)')
    end
    -- (d20 batch55 P6) what the game decides, said as facts: it gives the platform the silo fills for and no reason;
    -- 2.0.77 has no priority among platform requests; a request rockets on the way cover is not filled again until they land
    if row.next_auto_launch or (okr and reqs and #reqs > 0) then
      local covered = {}
      for _, r in ipairs(okr and reqs or {}) do if r.flag == 'on_the_way' then covered[#covered+1] = string.format('%s %s %d', r.platform, r.item, r.on_the_way) end end
      row.auto_launch_rule = 'the game picks which platform request a rocket fills (the silo\'s target, no reason given); 2.0.77 has no priority among platform requests; a request counts what rockets launched to the hub carry on the way, so none is filled again until they land'
        .. (#covered > 0 and '; covered on the way now: ' .. table.concat(covered, ', ', 1, math.min(4, #covered)) or '')
    end
    words[#words+1] = 'automatic requests ' .. (row.auto_requests and 'on (the silo launches for platforms\' requests itself)' or 'off')
    -- a load_silo auto_requests pause (B5): by whom, for how many more rockets
    local paused = api.pause_line and try(function() return api.pause_line(e) end)
    if paused then row.auto_requests_paused = paused; words[#words+1] = paused end
    if row.auto_requests then
      local ok, w = pcall(M.auto_wait, e, force, loaded)
      if ok and w then row.auto_waits = w; words[#words+1] = 'automatic launch: ' .. w end
      if row.next_auto_launch then words[#words+1] = 'the next automatic launch: ' .. row.next_auto_launch end
      if row.auto_launch_rule then words[#words+1] = row.auto_launch_rule end
    end
    -- (d17 batch15 A4, Gemini) what logistic robots carry or have reserved toward the silo now (its logistic points'
    -- deliveries on the way), and the platform its automatic requests fill for
    local coming = {}
    local pts = try(function() return e.get_logistic_point() end)
    if pts and pts.object_name then pts = {pts} end
    for _, pt in pairs(pts or {}) do
      for _, it in ipairs(try(function() return pt.targeted_items_deliver end) or {}) do
        local k = it.name .. (it.quality and it.quality ~= 'normal' and '@' .. it.quality or '')
        coming[k] = (coming[k] or 0) + (it.count or 0)
      end
    end
    local cl = {}
    for k, n in pairs(coming) do if n > 0 then cl[#cl+1] = k .. ' ' .. n end end
    table.sort(cl)
    local target = try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end)
    if #cl > 0 then
      row.robots_bringing = table.concat(cl, ', ')
      words[#words+1] = 'logistic robots bringing (carrying or reserved): ' .. row.robots_bringing .. (target and ' (automatic requests for platform ' .. target .. ')' or '')
    end
    row.requesting_for = target
    -- (d17 batch32 B6, Gemini: multi-rocket manifests read in several calls) loading, in one line near the head: for
    -- whom (the platform its automatic requests fill for, else the platform a hand load was for, by whom), the requests
    -- it fills now, what is aboard, what robots bring, and a paused manifest's rockets left
    do
      local hand = not target and api.load_record and try(function() return api.load_record(e) end)
      local filling = {}
      for _, r in ipairs(okr and reqs or {}) do
        if r.filling then filling[#filling+1] = string.format('%s %d asked (holds %d)', r.item, r.asks or 0, r.holds or 0) end
      end
      row.loading = string.format('for %s%s; aboard %s; robots bringing %s%s',
        target and ('platform ' .. target .. ' (its automatic requests)') or (hand and string.format('%s (loaded by hand by %s, %s ago)', tostring(hand.platform), tostring(hand.by), ago(game.tick - (hand.tick or game.tick)))) or 'no platform',
        #filling > 0 and ', filling ' .. table.concat(filling, ', ') or '',
        row.cargo and row.cargo.items or 'nothing', row.robots_bringing or 'nothing', paused and '; ' .. paused or '')
      if target or hand or #filling > 0 or row.robots_bringing or (row.cargo and row.cargo.items) then table.insert(words, 2, 'loading ' .. row.loading)
      else row.loading = nil end
    end
    row.send_to_orbit_automatically = try(function() return e.send_to_orbit_automatically end) and true or false
    if row.send_to_orbit_automatically then words[#words+1] = 'send to orbit automatically on' end
    -- (d19 batch46 3, viewer Aurora) who last changed each switch, when, before and after (editlog.lua)
    row.setting_edits = M.setting_edits(e)
    if row.setting_edits then words[#words+1] = 'changed: ' .. table.concat(row.setting_edits, '; ') end
    local planet_name = try(function() return e.surface.planet and e.surface.planet.name end)
    row.platforms_above = platforms_above(force, planet_name)
    if row.platforms_above then words[#words+1] = 'our platforms above: ' .. table.concat(row.platforms_above, ', ') end
    -- (B5) a platform flying here: named, its requests not in platform_requests until it stops in orbit
    row.platforms_coming = platforms_coming(force, planet_name)
    if row.platforms_coming then words[#words+1] = 'our platforms on their way here (their requests count once in orbit): ' .. table.concat(row.platforms_coming, ', ') end
    local last = records()[e.unit_number or -1]
    if last then
      row.last_launch = {ago=ago(game.tick - last.tick), tick=last.tick, up=last.up, to=last.to, cargo=last.cargo, by=last.by, spoil=last.spoil}
      words[#words+1] = string.format('last launch %s ago (%stick %d)%s%s%s', ago(game.tick - last.tick), last.up and 'up #' .. last.up .. ', ' or '', last.tick, last.to and ' to ' .. last.to or '',
        last.by and ' by ' .. last.by or '', last.cargo and ', cargo ' .. last.cargo or '')
    else
      words[#words+1] = 'no launch seen'
    end
    row.read_tick = game.tick
    words[#words+1] = string.format('read at tick %d', game.tick)
    row.line = table.concat(words, '; ')
    return row
  end
  -- What automatic launch waits for (Muse, d15 shifts 19-20, twice: Starling asked 50 low-density-structure and no
  -- rocket went up). Seen on a 2.0.77 copy of world n: with automatic requests on, the silo's own logistic request
  -- (its rocket_silo_requester point) asked its network for 200 low-density-structure, a full rocket by weight at 5 kg
  -- each, both for a platform asking 50 with no max and for one asking 400..400 holding 350, and the rocket went up once
  -- it held about 200. So the line gives the platform it fills a rocket for, the silo's request against what the rocket
  -- holds and what its network holds; with no platform taken up, the platforms stopped above that ask this planet for
  -- items they lack, with what the network holds of each and a full rocket of it (on the copy: with 16-30
  -- low-density-structure in its network the silo took up no platform asking for it; with 320 it filled 200 and launched).
  -- The harness does not change the rule.
  function M.auto_wait(e, force, loaded)
    local target = try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end)
    local pt = defines.logistic_member_index.rocket_silo_requester and try(function() return e.get_logistic_point(defines.logistic_member_index.rocket_silo_requester) end)
    local ln = try(function() return e.surface.find_logistic_network_by_position(e.position, force) end)
    local have = {}
    for _, s in ipairs(loaded or {}) do local k = s.name .. '@' .. (s.quality or 'normal'); have[k] = (have[k] or 0) + s.count end
    local parts = {}
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      local name = type(f.name) == 'string' and f.name or try(function() return f.name.name end)
      if name and (f.count or 0) > 0 then
        -- (BA1) the silo's request by its quality
        local q, cmp = M.want(f)
        local free = ln and M.count_q(function(id) return ln.get_item_count(id) end, name, q, cmp) or 0
        local held = 0
        for _, qn in ipairs(M.qualities(q, cmp)) do held = held + (have[name .. '@' .. qn] or 0) end
        local label = M.label(name, q, cmp)
        local w = try(function() return prototypes.item[name].weight end)
        local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end)
        local full = w and lift and w > 0 and math.floor(lift / w) or nil
        local short = f.count - held
        parts[#parts+1] = string.format('%s %d of %d aboard%s; its network holds %d more%s', label, held, f.count,
          full and f.count == full and string.format(' (a full rocket by weight, %g kg each)', w / 1000) or '', math.max(0, free),
          short > 0 and free < short and string.format(', under the %d it still waits for', short) or '')
      end
    end
    if target then
      local others = {}
      local n = 0
      for _, r in ipairs(M.request_rows(e, force, ln)) do if r.platform ~= target then n = n + 1; if #others < 4 then others[#others+1] = r.line end end end
      return string.format('filling a rocket for %s: %s; it goes up once the rocket holds what the silo requests (on 2.0.77 a full rocket of the item, or the request\'s min payload)%s%s',
        target, #parts > 0 and table.concat(parts, '; ') or 'the silo requests nothing from its network now',
        #others > 0 and '; waiting meanwhile: ' .. table.concat(others, '; ') or '',
        n > #others and string.format(' (and %d more: silo {requests: true})', n - #others) or '')
    end
    -- No platform taken up: the platforms above asking this planet for items they lack, each with why no rocket goes.
    local rows, unread = M.request_rows(e, force, ln)
    local planet = try(function() return e.surface.planet.name end)
    if #rows > 0 then
      local lines = {}
      for i, r in ipairs(rows) do if i <= 6 then lines[#lines+1] = r.line end end
      local more = #rows + (unread or 0) - #lines
      return 'no platform taken up now; above ' .. tostring(planet) .. ': ' .. table.concat(lines, '; ')
        .. (more > 0 and string.format(' (and %d more: silo {requests: true})', more) or '')
    end
    return 'no platform stopped above ' .. tostring(planet) .. ' asks it for items it lacks'
  end
  -- Per request a platform stopped above makes of this planet (Sol 04:50: Petrel stalled ~15 min with a ready silo, 9
  -- free hub slots and 4,500 foundation in providers): how much it asks and holds, the payload a rocket waits for (the
  -- request's min payload, else a full rocket by weight, as seen on 2.0.77), what the silo's network holds of it, the hub
  -- slots that payload takes and the hub's free slots, and whether the silo is filling a rocket for it or another
  -- platform now. Facts only; the game's choice among eligible requests is not read.
  -- only: one platform's name, the others skipped (shipment's readiness read). cap: the rows read (default REQ_READ);
  -- past it a request is counted, not read. The rows come in FLAG_ORDER (filling first), in hub order within a flag;
  -- the second value is the count of requests past the cap.
  function M.request_rows(e, force, ln, only, cap)
    cap = cap or REQ_READ
    local unread = 0
    ln = ln or try(function() return e.surface.find_logistic_network_by_position(e.position, force) end)
    local planet = try(function() return e.surface.planet.name end)
    local target = try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end)
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end)
    local rows = {}
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      local loc = pl.valid and try(function() return pl.space_location.name end)
      if loc == planet and pl.hub and pl.hub.valid and (only == nil or pl.name == only) then
        local main = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
        local free_slots = main and try(function() return main.count_empty_stacks(true, false) end)
        local secs = try(function() return pl.hub.get_logistic_sections() end)
        local coming = M.on_the_way(pl.hub)
        for i = 1, secs and secs.sections_count or 0 do
          local sec = try(function() return secs.get_section(i) end)
          for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
            local v = f.value
            local name = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
            local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
            -- (BA1) the hub's holding, the networks' stock and what is on the way by the request's quality and comparator
            local q, cmp = M.want(v)
            local held = name and M.count_q(function(id) return pl.hub.get_item_count(id) end, name, q, cmp) or 0
            if name and from == planet and (f.min or 0) > held and #rows >= cap then unread = unread + 1
            elseif name and from == planet and (f.min or 0) > held then
              local w = try(function() return prototypes.item[name].weight end)
              local full = w and lift and w > 0 and math.floor(lift / w) or nil
              local way = 0
              for _, qn in ipairs(M.qualities(q, cmp)) do way = way + (coming[name .. '@' .. qn] or 0) end
              local label = M.label(name, q, cmp)
              local lacks = math.max(0, f.min - held - way)
              local mp = f.minimum_delivery_count
              local payload = mp or full
              local stack = try(function() return prototypes.item[name].stack_size end) or 1
              -- (B3) what the network can give now: its provider and storage chests (requester and buffer chests' requests
              -- are theirs), less what robots have reserved (the game's count)
              local net = ln and math.max(0, M.count_q(function(id) return ln.get_item_count(id) end, name, q, cmp)) or 0
              local from_prov = ln and math.max(0, M.count_q(function(id) return ln.get_item_count(id, 'providers') end, name, q, cmp)) or 0
              local from_store = ln and math.max(0, M.count_q(function(id) return ln.get_item_count(id, 'storage') end, name, q, cmp)) or 0
              local need_slots = payload and math.ceil(math.min(payload, full or payload) / stack) or nil
              local r = {platform=pl.name, item=name, quality=q, comparator=cmp, custom_minimum=mp, asks=f.min, holds=held, on_the_way=way, lacks=lacks, min_payload=mp, full_rocket=full,
                payload=payload, network_holds=net, providers=from_prov, storage=from_store, slots_for_payload=need_slots, hub_free_slots=free_slots,
                next_launch=mp and string.format('min_payload %d', mp) or (full and string.format('full %d', full) or nil),
                filling=target == pl.name or nil, other_filling=target and target ~= pl.name and target or nil}
              local words = {string.format('%s asks %s %d (holds %d, %slacks %d)', pl.name, label, f.min, held, way > 0 and way .. ' on the way in rockets launched to it, ' or '', lacks)}
              if lacks == 0 then words[#words+1] = 'what is on the way covers it: the game launches for it again once those land' end
              words[#words+1] = mp and string.format('min payload %d (its custom minimum)', mp)
                or (full and string.format('no min payload: a rocket waits for a full one, %d by weight', full) or 'no min payload')
              words[#words+1] = string.format('the silo\'s network can give %d now (provider chests %d, storage chests %d, less what robots have reserved)%s', net, from_prov, from_store,
                payload and net < payload and string.format(', under the %d a rocket waits for', payload) or '')
              if need_slots and free_slots then
                words[#words+1] = string.format('that payload takes %d hub slot%s, the hub has %d free%s', need_slots, need_slots == 1 and '' or 's', free_slots,
                  free_slots < need_slots and ' (fewer)' or '')
              end
              if r.filling then words[#words+1] = 'the silo fills a rocket for ' .. pl.name .. ' now'
              elseif r.other_filling then words[#words+1] = 'the silo fills a rocket for ' .. target .. ' now' end
              -- the flag (A8, Gemini 01:50: silos idle with rockets ready, the stock just under min_payload or split
              -- across networks): matched, below_min_payload, split_networks (the planet's other networks hold the
              -- rest: each named), hub_full, filling
              -- (d17 batch29 C3, Gemini: a silo waited for an item only another network held) each other network's chest
              -- robots would take it from (select_pickup_point near the silo), for load_silo's from
              local others, other_n, chests = {}, 0, {}
              local function pick(o, n)
                local id = (q == 'normal' or cmp ~= '=') and name or {name=name, quality=q}
                local pt = n > 0 and #chests < 4 and try(function() return o.select_pickup_point{name=id, position=e.position} end)
                local c = pt and try(function() return pt.owner end)
                if not (c and c.valid) then return '' end
                local has = M.count_q(function(i) return c.get_item_count(i) end, name, q, cmp)
                chests[#chests+1] = {x=c.position.x, y=c.position.y}
                return string.format(', most at hand in %s (%g,%g) holding %d', c.name, c.position.x, c.position.y, has)
              end
              if ln and net > 0 then pick(ln, net) end
              for _, o in pairs(try(function() return force.logistic_networks[e.surface.name] end) or {}) do
                if not (ln and o.network_id == ln.network_id) then
                  local n = math.max(0, M.count_q(function(id) return o.get_item_count(id) end, name, q, cmp))
                  if n > 0 then
                    other_n = other_n + n
                    local cell = try(function() return o.cells[1].owner end)
                    others[#others+1] = string.format('network %d%s holds %d%s', o.network_id, cell and cell.valid and string.format(' (near %d,%d)', cell.position.x, cell.position.y) or '', n, pick(o, n))
                  end
                end
              end
              if r.filling then r.flag = 'filling'
              elseif lacks == 0 then r.flag = 'on_the_way'
              elseif need_slots and free_slots and free_slots < need_slots then r.flag = 'hub_full'
              elseif payload and net >= payload then r.flag = 'matched'
              elseif payload and net + other_n >= payload then r.flag = 'split_networks'
              else r.flag = 'below_min_payload' end
              if #others > 0 and r.flag ~= 'matched' then words[#words+1] = 'other networks on ' .. e.surface.name .. ': ' .. table.concat(others, '; ', 1, math.min(3, #others)) end
              -- (d18 batch37 B1, Sonnet: calcite stalled Wayfarer twice) short of the payload: where else the planet holds it
              if r.flag ~= 'matched' and r.flag ~= 'filling' and r.flag ~= 'on_the_way' and api.elsewhere then
                -- (BA1) by the request's quality when it takes one (with another comparator: not read)
                local eline = cmp == '=' and try(function() return (api.elsewhere(force, e.surface, name, ln, e.position, true, q)) end)
                if eline then r.elsewhere = eline; words[#words+1] = eline end
              end
              -- split_networks: carried over by hand, a walking load_silo from those chests that launches for the platform
              if r.flag == 'split_networks' and #chests > 0 and q == 'normal' and cmp == '=' then
                local auto = try(function() return e.use_transitional_requests end)
                local n = math.min(lacks, full or lacks, net + other_n)
                r.load_silo = {position={x=e.position.x, y=e.position.y}, items={[name]=n}, from=chests, walk=true, launch=true, platform=pl.name, auto_requests=auto and 'pause' or nil}
                words[#words+1] = string.format('by hand: load_silo {items {%s: %d}, from those chests, walk, launch, platform %s%s} (the row\'s load_silo is its args)',
                  name, n, pl.name, auto and ', auto_requests "pause"' or '')
              end
              r.line = r.flag .. ': ' .. table.concat(words, ', ')
              rows[#rows+1] = r
              r.at = #rows
            end
          end
        end
      end
    end
    local rank = {}
    for i, f in ipairs(FLAG_ORDER) do rank[f] = i end
    table.sort(rows, function(x, y)
      local a, b = rank[x.flag] or 99, rank[y.flag] or 99
      if a ~= b then return a < b end
      return x.at < y.at
    end)
    for _, r in ipairs(rows) do r.at = nil end
    return rows, unread
  end
  -- (d17 batch32 A1, Grok: 241 agricultural science packs went to rocket_silo_trash and never launched) switching a
  -- silo's automatic requests on with cargo loaded by hand: the game moves cargo out of the rocket into the silo's trash
  -- slots. What is aboard now, split into what a platform stopped above asks this planet for (request_rows: a request
  -- its hub lacks) and the rest, which no request asks for and goes to the trash; nil when nothing is aboard.
  function M.trash_risk(e, force)
    local inv = defines.inventory.rocket_silo_rocket and try(function() return e.get_inventory(defines.inventory.rocket_silo_rocket) end)
    local aboard = contents(inv)
    if #aboard == 0 then return nil end
    local asked = {}
    for _, r in ipairs(try(function() return M.request_rows(e, force) end) or {}) do asked[r.item] = r.platform end
    local lost, kept, lost_n = {}, {}, 0
    for _, st in ipairs(aboard) do
      if asked[st.name] then kept[#kept+1] = {name=st.name, count=st.count, quality=st.quality}
      else lost[#lost+1] = {name=st.name, count=st.count, quality=st.quality}; lost_n = lost_n + st.count end
    end
    local lost_text, kept_text = items_text(lost, 8), items_text(kept, 8)
    return {lost=lost_text, lost_count=lost_n, asked=kept_text,
      line=string.format('the rocket holds %s', table.concat((function()
        local t = {}
        if lost_text then t[#t+1] = lost_text .. ' that no platform stopped above asks this planet for: with automatic requests on the game moves it into the silo\'s trash slots, which never launch' end
        if kept_text then t[#t+1] = kept_text .. ' that a platform above asks for' end
        return t end)(), '; and '))}
  end
  -- The silo GUI's switches as they stand, with where the silo is (configure and launch read them back after a change).
  function M.setting_edits(e)
    local log = api.editlog and api.editlog()
    return log and e.unit_number and try(function() return log.lines('silo:' .. e.unit_number) end) or nil
  end
  function M.settings(e)
    local target = try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end)
    local rk = M.rocket(e)
    return {silo = string.format('%s at (%g,%g) on %s', e.name, e.position.x, e.position.y, e.surface.name),
      auto_requests = try(function() return e.use_transitional_requests end) and true or false,
      send_to_orbit_automatically = try(function() return e.send_to_orbit_automatically end) and true or false,
      setting_edits = M.setting_edits(e),
      requesting_for = target, parts = rk.parts, built_parts = rk.built_parts, next_parts = rk.next_parts, rocket_ready = rk.rocket_ready, rocket = rk.rocket,
      state = try(function() return silo_states[e.rocket_silo_status] end)}
  end
  -- silo {position, why: true} (A2, Sonnet 22:50: "a one-call 'why is this silo part short' chain trace down to the raw
  -- input"; he found low-density-structure, then plastic, then no coal on Vulcanus by hand): the rocket-part
  -- ingredient the silo is shortest of (one it lacks for the next part first, else the most short for the parts left,
  -- else the least on hand against what the parts left need), the places its feeding inserters take from (what each
  -- holds of it; a requester or buffer chest: its request and what its logistic network holds and has on the way), and
  -- that item's chain on the silo's planet as bottleneck {item} reads it (makers by state and what most of them lack,
  -- down to the first step whose makers mostly do not lack an ingredient: the root), with up to 3 makers not working.
  local function source_entities(e)
    local box = {left_top={x=e.position.x - FEED_REACH, y=e.position.y - FEED_REACH}, right_bottom={x=e.position.x + FEED_REACH, y=e.position.y + FEED_REACH}}
    local out, seen = {}, {}
    for _, ins in ipairs(try(function() return e.surface.find_entities_filtered{area=box, type='inserter', force=e.force, limit=MAX_FEEDERS} end) or {}) do
      if ins.valid and try(function() return ins.drop_target end) == e then
        local src = try(function() return ins.pickup_target end)
        local key = src and src.valid and (src.unit_number or at(src.position))
        if key and not seen[key] then seen[key] = true; out[#out+1] = src end
      end
    end
    return out
  end
  local function source_line(src, item)
    local held = holds(src, {[item]=true})[item] or 0
    if src.type == 'logistic-container' then
      local inv = try(function() return src.get_inventory(defines.inventory.chest) end)
      held = inv and try(function() return inv.get_item_count(item) end) or held
    end
    local text = string.format('%s %s holds %d', src.name, at(src.position), held)
    local pt = try(function() return src.get_logistic_point(defines.logistic_member_index.logistic_container) end)
    if pt then
      local asks
      for _, f in ipairs(try(function() return pt.filters end) or {}) do
        local n = type(f.name) == 'string' and f.name or try(function() return f.name.name end)
        if n == item then asks = (asks or 0) + (f.count or 0) end
      end
      if try(function() return pt.mode end) == defines.logistic_mode.requester or try(function() return pt.mode end) == defines.logistic_mode.buffer then
        text = text .. (asks and string.format(', asks %d', asks) or ', no request for it')
      end
      local coming = 0
      for _, c in ipairs(try(function() return pt.targeted_items_deliver end) or {}) do
        local n = type(c.name) == 'string' and c.name or try(function() return c.name.name end)
        if n == item then coming = coming + (c.count or 0) end
      end
      local ln = try(function() return pt.logistic_network end)
      if ln then
        text = text .. string.format('; its logistic network holds %d (robots bringing %d)', try(function() return ln.get_item_count(item) end) or 0, coming)
      else
        text = text .. '; in no logistic network'
      end
    end
    return text
  end
  function M.why(p, e, row)
    local list = row.ingredients or {}
    local pick, why_pick
    for _, l in ipairs(row.lacks or {}) do
      for _, r in ipairs(list) do if r.name == l and not pick then pick, why_pick = r, 'it lacks one for the next part' end end
    end
    if not pick then
      for _, r in ipairs(list) do if r.short and (not pick or r.short > (pick.short or 0)) then pick, why_pick = r, 'the most short for the parts left' end end
    end
    if not pick then
      local best
      for _, r in ipairs(list) do
        local share = (r.in_silo + r.in_hands + r.at_sources) / math.max(1, r.needed)
        if r.needed > 0 and (not best or share < best) then pick, best, why_pick = r, share, 'the least on hand for the parts left' end
      end
    end
    if not pick then
      return {line=string.format('%s %s: no rocket part to make now (%s); nothing is short', e.name, at(e.position), row.rocket or row.state)}
    end
    local item = pick.name
    local out = {item=item, picked=why_pick}
    local srcs = {}
    for i, src in ipairs(source_entities(e)) do if i <= 4 then srcs[#srcs+1] = source_line(src, item) end end
    out.feeders = #srcs > 0 and srcs or nil
    local words = {string.format('%s: the silo holds %d (%d a part, %d for the parts left; %s), %d in feeding inserters\' hands',
      item, pick.in_silo, pick.per_part, pick.needed, why_pick, pick.in_hands)}
    words[#words+1] = #srcs > 0 and table.concat(srcs, '; ') or 'no inserter feeds the silo'
    local ok, chain = pcall(api.bottleneck, p, {item=item, surface=e.surface.name})
    if ok and type(chain) == 'table' then
      out.chain, out.root, out.path = chain.line, chain.root, chain.path
      local nw = {}
      for i, w in ipairs(chain.not_working or {}) do if i <= 3 then nw[i] = w end end
      out.not_working = #nw > 0 and nw or nil
      local fx = {}
      for i, f in ipairs(chain.fixes or {}) do if i <= 3 then fx[i] = f end end
      out.fixes = #fx > 0 and fx or nil
      words[#words+1] = chain.line or ''
      if chain.root then words[#words+1] = 'root: ' .. chain.root end
    elseif not ok then
      out.chain_error = tostring(chain)
    end
    out.line = table.concat(words, '; ')
    return out
  end
  -- (d18 batch36 D1, Gemini) every surface in one call: silo {surface: "all"} or {all: true}: a line a silo (the planets'
  -- silos from the census pass, else one search a planet): its rocket parts and their rate, the payload aboard against
  -- the request it fills (the platform its automatic requests take up), and next_auto_launch. ALL_SILOS at most.
  M.ALL_SILOS = 16
  function M.read_all(p)
    local rows, lines = {}, {}
    local surfaces = {}
    for _, s in pairs(game.surfaces) do if try(function() return s.planet end) then surfaces[#surfaces+1] = s end end
    table.sort(surfaces, function(x, y) return x.index < y.index end)
    for _, s in ipairs(surfaces) do
      local list = api.census_silos and try(function() return api.census_silos(p.force, s) end)
      local silos = {}
      if list then silos = list
      else
        silos = try(function() return s.find_entities_filtered{type='rocket-silo', force=p.force, limit=MAX_SILOS} end) or {}
      end
      for _, e in ipairs(silos) do
        if #rows >= M.ALL_SILOS then break end
        local row = M.view(e, p.force)
        rows[#rows+1] = row
        local rk = M.rocket(e)
        local parts = rk.rocket_now
        local rate = row.parts_per_min and string.format(', %s parts/min%s', tostring(row.parts_per_min),
          row.parts_per_min_building and string.format(' (%g while building)', row.parts_per_min_building) or '') or ''
        local aboard = row.cargo and row.cargo.items or 'nothing'
        local filling = {}
        for _, r in ipairs(row.platform_requests or {}) do
          if r.filling then filling[#filling+1] = string.format('%s %d asked (holds %d)', r.item, r.asks or 0, r.holds or 0) end
        end
        lines[#lines+1] = string.format('%s %s on %s: %s%s; aboard %s%s%s', e.name, at(e.position), s.name, parts, rate, aboard,
          row.requesting_for and string.format('; filling for %s%s', row.requesting_for, #filling > 0 and ': ' .. table.concat(filling, ', ') or '') or '',
          row.next_auto_launch and '; next automatic launch: ' .. row.next_auto_launch or '')
      end
    end
    assert(#rows > 0, 'no rocket silo of ours on any planet')
    return {all=true, silos=rows, lines=lines, rockets_launched=try(function() return p.force.rockets_launched end),
      note=#rows >= M.ALL_SILOS and 'the first ' .. M.ALL_SILOS .. ' silos' or nil}
  end
  function M.read(p, a)
    assert(a.why == nil or type(a.why) == 'boolean', 'why must be true or false')
    assert(a.requests == nil or type(a.requests) == 'boolean', 'requests must be true or false')
    assert(a.page == nil or (type(a.page) == 'number' and a.page >= 1 and a.page == math.floor(a.page)), 'page must be a whole number from 1')
    assert(a.page == nil or a.requests, 'page goes with requests: true')
    assert(a.all == nil or a.all == true, 'all is true: every silo of ours on every planet')
    if a.all or a.surface == 'all' then
      assert(a.position == nil and a.why == nil, 'all (surface "all") reads every silo; position and why read one')
      return M.read_all(p)
    end
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    -- (d19 batch44 A2: this find was 11.5 ms on the private copy's Nauvis, 54 silo calls an hour in shifts 39-41) the
    -- silos the census pass found (every 30 s); with position, the 10 tiles round it read live too (a silo built since);
    -- none known: the whole surface as before
    local silos = api.census_typed and try(function() return api.census_typed(p.force, surface, 'rocket-silo') end)
    if silos and a.position ~= nil then
      local q = api.position(a.position)
      local near = false
      for _, e in ipairs(silos) do if (e.position.x - q.x) ^ 2 + (e.position.y - q.y) ^ 2 <= 100 then near = true end end
      if not near then
        for _, e in ipairs(try(function() return surface.find_entities_filtered{type='rocket-silo', force=p.force, position=q, radius=10} end) or {}) do silos[#silos+1] = e end
      end
    end
    local from_census = silos and #silos > 0
    if not silos or #silos == 0 then silos = surface.find_entities_filtered{type='rocket-silo', force=p.force, limit=MAX_SILOS} end
    assert(#silos > 0, 'no rocket silo of ours on ' .. surface.name)
    if a.position ~= nil then
      local pos = api.position(a.position)
      local best, d2 = nil, math.huge
      for _, e in ipairs(silos) do
        local d = (e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2
        if d < d2 then best, d2 = e, d end
      end
      silos = {best}
    end
    table.sort(silos, function(x, y) if x.position.x ~= y.position.x then return x.position.x < y.position.x end return x.position.y < y.position.y end)
    local rows = {}
    for _, e in ipairs(silos) do rows[#rows+1] = M.view(e, p.force, {requests=a.requests, page=a.page or 1}) end
    if a.why then
      assert(#silos == 1, 'why reads one silo: give position (the silo nearest it)')
      rows[1].why = M.why(p, silos[1], rows[1])
    end
    return {surface=surface.name, silos=rows, rockets_launched=try(function() return p.force.rockets_launched end),
      note=#silos >= MAX_SILOS and 'the first ' .. MAX_SILOS .. ' silos' or nil,
      read_from=from_census and a.position == nil and 'the silos the background census found (every 30 s); one built since: silo {position} reads it' or nil}
  end
  M.schema = {silo = {position='optional {x,y}: the silo nearest it (default every silo on the surface)', surface='optional surface name (default yours), or "all": every silo of ours on every planet, a line each (as all: true)',
    all='optional true: every silo of ours on every planet (16 at most): lines, a line a silo: its rocket parts and their rate, what is aboard, the platform its automatic requests fill for and what of that request it holds, next_auto_launch; silos (each silo\'s full read)',
    requests='optional true: platform_requests lists every row (up to ' .. REQ_ALL .. ', ' .. REQ_PAGE .. ' a page) instead of the first ' .. REQ_SHOWN .. '; platform_requests_page and platform_requests_pages',
    page='optional page of platform_requests with requests: true (default 1)',
    why='optional true, with position (or one silo there): why its rocket parts are short, as one read: the ingredient it is shortest of (one it lacks for the next part first), the places its feeding inserters take from (what each holds of it; a requester or buffer chest: its request, and what its logistic network holds and robots bring), and that item\'s chain on the silo\'s planet as bottleneck {item} reads it (each step\'s makers by state and what most of them lack, down to the root), with up to 3 makers not working and fixes: why {item, picked, feeders, chain, root, path, not_working, fixes, line}',
    returns='silos [{name, position, surface, parts (X/required, the 2.0 rocket_parts_required, while the rocket is being built), built_parts (ready or rising: the built rocket\'s, 50/50), next_parts (once it is built: ready, rising or launching; the parts the silo makes for the rocket after it: a ready rocket with next_parts 6/50 is built and launches), rocket_ready (true only for a built rocket), rocket ("rocket built (50/50 parts) and ready to launch, not launched; parts for the rocket after it 13/50; last launch 4m10s ago to platform X"; rising into place; launching; or building, parts X/Y), state (the silo\'s rocket state), status, '
      .. 'crafting {part_progress, parts_left, part_s, productivity, rocket_eta_s (at this speed, while working)}, ingredients [{name, per_part, in_silo, in_hands '
      .. '(feeding inserters\' hands), at_sources (what their belts and chests hold), needed (for the parts left), short}], lacks (ingredients the silo holds too few '
      .. 'of for the next part), feeders {inserters, idle, sources}, cargo {kg, lift_kg, room_kg (lift left), stacks, slots, items, over_kg}, trash, robots_bringing (what logistic robots carry or have reserved toward the silo now) and requesting_for (the platform its automatic requests fill for), auto_requests and send_to_orbit_automatically (the GUI checkboxes; configure sets them), '
      .. 'platforms_above (ours in orbit of this planet), parts_made and parts_per_min (rocket parts made, products_finished; the rate over the last 10 min of samples taken at most every 10 s by reads and the alert scan), parts_rate (the rate, its window, and the time in it spent building parts, short of an ingredient or holding a built rocket: parts are made only while it builds), parts_per_min_building, next_auto_launch (with automatic requests on: the request filled now, else the first the network can give a rocket\'s payload for: platform, item, under min_payload N or full N by weight), auto_launch_rule (what the game decides: the platform the silo fills for is the game\'s, with no reason given; 2.0.77 has no priority among platform requests; a request counts what rockets launched to the hub carry, so none is filled again until they land; the requests covered on the way now), platform_requests [{platform, item, quality, comparator (= > < >= <= !=; holds, on_the_way and the networks count the qualities it takes), custom_minimum, asks, holds, on_the_way (in rockets launched to the hub, the hub GUI\'s in-transit count), lacks (asks less holds less on_the_way), network_can_give (provider and storage chests less robots\' reservations), providers, storage, next_launch (min_payload N | full N), flag (matched: the silo\'s network holds the payload a rocket waits for; below_min_payload; split_networks: other networks on the planet hold the rest, named, each with the chest robots would take it from; hub_full: the payload takes more hub slots than are free; filling: the silo fills a rocket for it now; on_the_way: rockets on the way cover it), load_silo (split_networks: the args that carry it over by hand: a walking load from those chests that launches for the platform), line}] (each request a platform in orbit of this planet makes of it that its hub lacks, in flag order: filling, matched, split_networks, hub_full, below_min_payload; the first 8, or every one with requests: true), platform_requests_count, platform_requests_flags (the count of each flag), platform_requests_more (the rows past the first 8), platforms_coming (ours flying here now: from where, share flown; a platform\'s requests count once it is in orbit), last_launch {ago, tick, up (the cargo ledger\'s launch id: shipment and the platforms\' incoming lines name the same launch by it), to, cargo, by, spoil (each spoilable item it carried with its spread)}, cargo.spoil and input_spoil (each spoilable item in the rocket and in the silo\'s input: spoiled share by count, range, quarters, how many spoil within 10, 30 and 60 min), read_tick (the tick this was read: the line ends read at tick T), line}]; rockets_launched (the force\'s count). '
      .. 'Feeders: inserters within 8 tiles dropping into the silo. Launches are seen from when the harness was deployed. Read only'}}
  return M
end
