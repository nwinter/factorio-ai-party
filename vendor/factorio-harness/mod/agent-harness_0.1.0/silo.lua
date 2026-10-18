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
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function invert(t) local out = {} for k, v in pairs(t or {}) do out[v] = k end return out end
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
  -- on_rocket_launch_ordered: the rocket's cargo pod holds the cargo and knows where it goes.
  function M.on_launch_ordered(event)
    local silo = event.rocket_silo
    if not (silo and silo.valid) then return end
    local pod = try(function() return event.rocket.attached_cargo_pod end)
    local inv = pod and defines.inventory.cargo_unit and try(function() return pod.get_inventory(defines.inventory.cargo_unit) end)
    local cargo = items_text(contents(inv), 8)
    local by = event.player_index and try(function() return game.get_player(event.player_index).name end)
    M.record(silo, {cargo=cargo or 'empty', to=destination_text(pod and try(function() return pod.cargo_pod_destination end)), by=by, ordered=true})
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
    local last_text = last and string.format('last launch %s ago%s', ago(game.tick - last.tick), last.to and ' to ' .. last.to or '')
      or 'no launch seen'
    return {rocket_ready=ready, parts=not next_parts and parts .. '/' .. required or nil, next_parts=next_parts, built_parts=built,
      rocket=now .. '; ' .. last_text, rocket_now=now, last=last_text,
      last_launch=last and {ago=ago(game.tick - last.tick), tick=last.tick, to=last.to, cargo=last.cargo, by=last.by} or nil}
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
  function M.view(e, force)
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
    -- A built rocket's parts are consumed: none are left to make for it.
    local left = (ready or RISING[state]) and 0 or math.max(0, required - parts)
    local words = {}
    words[#words+1] = string.format('%s %s on %s: %s', e.name, at(e.position), e.surface.name, rk.rocket_now)
    -- Crafting: the part in progress, and the rest of the rocket at this speed.
    local recipe = try(function() return e.get_recipe() end)
    local prod = 1 + (try(function() return e.productivity_bonus end) or 0)
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
    else
      row.cargo = {kg=0, lift_kg=api.cargo.kg(lift), room_kg=api.cargo.kg(lift), stacks=0, slots=slots}
      words[#words+1] = rocket_inv and 'no cargo loaded' or 'no rocket to load yet'
    end
    local trash = defines.inventory.rocket_silo_trash and try(function() return e.get_inventory(defines.inventory.rocket_silo_trash) end)
    row.trash = items_text(contents(trash), 8)
    if row.trash then words[#words+1] = 'trash slots: ' .. row.trash end
    row.auto_requests = try(function() return e.use_transitional_requests end) and true or false
    -- each request a platform above makes of this planet, flagged (A8)
    local okr, reqs = pcall(M.request_rows, e, force)
    if okr and reqs and #reqs > 0 then
      row.platform_requests = {}
      for i, r in ipairs(reqs) do if i <= 8 then row.platform_requests[i] = {platform=r.platform, item=r.item, flag=r.flag, line=r.line} end end
    end
    words[#words+1] = 'automatic requests ' .. (row.auto_requests and 'on (the silo launches for platforms\' requests itself)' or 'off')
    -- a load_silo auto_requests pause (B5): by whom, for how many more rockets
    local paused = api.pause_line and try(function() return api.pause_line(e) end)
    if paused then row.auto_requests_paused = paused; words[#words+1] = paused end
    if row.auto_requests then
      local ok, w = pcall(M.auto_wait, e, force, loaded)
      if ok and w then row.auto_waits = w; words[#words+1] = 'automatic launch: ' .. w end
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
    row.send_to_orbit_automatically = try(function() return e.send_to_orbit_automatically end) and true or false
    if row.send_to_orbit_automatically then words[#words+1] = 'send to orbit automatically on' end
    row.platforms_above = platforms_above(force, try(function() return e.surface.planet and e.surface.planet.name end))
    if row.platforms_above then words[#words+1] = 'our platforms above: ' .. table.concat(row.platforms_above, ', ') end
    local last = records()[e.unit_number or -1]
    if last then
      row.last_launch = {ago=ago(game.tick - last.tick), tick=last.tick, to=last.to, cargo=last.cargo, by=last.by}
      words[#words+1] = string.format('last launch %s ago%s%s%s', ago(game.tick - last.tick), last.to and ' to ' .. last.to or '',
        last.by and ' by ' .. last.by or '', last.cargo and ', cargo ' .. last.cargo or '')
    else
      words[#words+1] = 'no launch seen'
    end
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
    for _, s in ipairs(loaded or {}) do have[s.name] = (have[s.name] or 0) + s.count end
    local parts = {}
    for _, f in ipairs(pt and try(function() return pt.filters end) or {}) do
      local name = type(f.name) == 'string' and f.name or try(function() return f.name.name end)
      if name and (f.count or 0) > 0 then
        local free = ln and (try(function() return ln.get_item_count(name) end) or 0) or 0
        local w = try(function() return prototypes.item[name].weight end)
        local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end)
        local full = w and lift and w > 0 and math.floor(lift / w) or nil
        local short = f.count - (have[name] or 0)
        parts[#parts+1] = string.format('%s %d of %d aboard%s; its network holds %d more%s', name, have[name] or 0, f.count,
          full and f.count == full and string.format(' (a full rocket by weight, %g kg each)', w / 1000) or '', math.max(0, free),
          short > 0 and free < short and string.format(', under the %d it still waits for', short) or '')
      end
    end
    if target then
      local others = {}
      for _, r in ipairs(M.request_rows(e, force, ln)) do if r.platform ~= target and #others < 4 then others[#others+1] = r.line end end
      return string.format('filling a rocket for %s: %s; it goes up once the rocket holds what the silo requests (on 2.0.77 a full rocket of the item, or the request\'s min payload)%s',
        target, #parts > 0 and table.concat(parts, '; ') or 'the silo requests nothing from its network now',
        #others > 0 and '; waiting meanwhile: ' .. table.concat(others, '; ') or '')
    end
    -- No platform taken up: the platforms above asking this planet for items they lack, each with why no rocket goes.
    local rows = M.request_rows(e, force, ln)
    local planet = try(function() return e.surface.planet.name end)
    if #rows > 0 then
      local lines = {}
      for i, r in ipairs(rows) do if i <= 6 then lines[#lines+1] = r.line end end
      return 'no platform taken up now; above ' .. tostring(planet) .. ': ' .. table.concat(lines, '; ')
    end
    return 'no platform stopped above ' .. tostring(planet) .. ' asks it for items it lacks'
  end
  -- Per request a platform stopped above makes of this planet (Sol 04:50: Petrel stalled ~15 min with a ready silo, 9
  -- free hub slots and 4,500 foundation in providers): how much it asks and holds, the payload a rocket waits for (the
  -- request's min payload, else a full rocket by weight, as seen on 2.0.77), what the silo's network holds of it, the hub
  -- slots that payload takes and the hub's free slots, and whether the silo is filling a rocket for it or another
  -- platform now. Facts only; the game's choice among eligible requests is not read.
  function M.request_rows(e, force, ln)
    ln = ln or try(function() return e.surface.find_logistic_network_by_position(e.position, force) end)
    local planet = try(function() return e.surface.planet.name end)
    local target = try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end)
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end)
    local rows = {}
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      local loc = pl.valid and try(function() return pl.space_location.name end)
      if loc == planet and pl.hub and pl.hub.valid then
        local main = try(function() return pl.hub.get_inventory(defines.inventory.hub_main) end)
        local free_slots = main and try(function() return main.count_empty_stacks() end)
        local secs = try(function() return pl.hub.get_logistic_sections() end)
        for i = 1, secs and secs.sections_count or 0 do
          local sec = try(function() return secs.get_section(i) end)
          for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
            local v = f.value
            local name = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
            local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
            local held = name and (try(function() return pl.hub.get_item_count(name) end) or 0) or 0
            if name and from == planet and (f.min or 0) > held and #rows < 16 then
              local w = try(function() return prototypes.item[name].weight end)
              local full = w and lift and w > 0 and math.floor(lift / w) or nil
              local lacks = f.min - held
              local mp = f.minimum_delivery_count
              local payload = mp or full
              local stack = try(function() return prototypes.item[name].stack_size end) or 1
              local net = ln and math.max(0, try(function() return ln.get_item_count(name) end) or 0) or 0
              local need_slots = payload and math.ceil(math.min(payload, full or payload) / stack) or nil
              local r = {platform=pl.name, item=name, asks=f.min, holds=held, lacks=lacks, min_payload=mp, full_rocket=full,
                payload=payload, network_holds=net, slots_for_payload=need_slots, hub_free_slots=free_slots,
                filling=target == pl.name or nil, other_filling=target and target ~= pl.name and target or nil}
              local words = {string.format('%s asks %s %d (holds %d, lacks %d)', pl.name, name, f.min, held, lacks)}
              words[#words+1] = mp and string.format('min payload %d', mp)
                or (full and string.format('no min payload: a rocket waits for a full one, %d by weight', full) or 'no min payload')
              words[#words+1] = string.format('the silo\'s network holds %d%s', net,
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
              local others, other_n = {}, 0
              for _, o in pairs(try(function() return force.logistic_networks[e.surface.name] end) or {}) do
                if not (ln and o.network_id == ln.network_id) then
                  local n = math.max(0, try(function() return o.get_item_count(name) end) or 0)
                  if n > 0 then
                    other_n = other_n + n
                    local cell = try(function() return o.cells[1].owner end)
                    others[#others+1] = string.format('network %d%s holds %d', o.network_id, cell and cell.valid and string.format(' (near %d,%d)', cell.position.x, cell.position.y) or '', n)
                  end
                end
              end
              if r.filling then r.flag = 'filling'
              elseif need_slots and free_slots and free_slots < need_slots then r.flag = 'hub_full'
              elseif payload and net >= payload then r.flag = 'matched'
              elseif payload and net + other_n >= payload then r.flag = 'split_networks'
              else r.flag = 'below_min_payload' end
              if #others > 0 and r.flag ~= 'matched' then words[#words+1] = 'other networks on ' .. e.surface.name .. ': ' .. table.concat(others, '; ', 1, math.min(3, #others)) end
              r.line = r.flag .. ': ' .. table.concat(words, ', ')
              rows[#rows+1] = r
            end
          end
        end
      end
    end
    return rows
  end
  -- The silo GUI's switches as they stand, with where the silo is (configure and launch read them back after a change).
  function M.settings(e)
    local target = try(function() local t = e.transitional_request_target; return t and t.valid and t.name or nil end)
    local rk = M.rocket(e)
    return {silo = string.format('%s at (%g,%g) on %s', e.name, e.position.x, e.position.y, e.surface.name),
      auto_requests = try(function() return e.use_transitional_requests end) and true or false,
      send_to_orbit_automatically = try(function() return e.send_to_orbit_automatically end) and true or false,
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
  function M.read(p, a)
    assert(a.why == nil or type(a.why) == 'boolean', 'why must be true or false')
    local surface = p.surface
    if a.surface ~= nil then
      assert(type(a.surface) == 'string', 'surface must be a surface name')
      surface = game.get_surface(a.surface)
      assert(surface, 'no surface ' .. a.surface)
    end
    local silos = surface.find_entities_filtered{type='rocket-silo', force=p.force, limit=MAX_SILOS}
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
    for _, e in ipairs(silos) do rows[#rows+1] = M.view(e, p.force) end
    if a.why then
      assert(#silos == 1, 'why reads one silo: give position (the silo nearest it)')
      rows[1].why = M.why(p, silos[1], rows[1])
    end
    return {surface=surface.name, silos=rows, rockets_launched=try(function() return p.force.rockets_launched end),
      note=#silos >= MAX_SILOS and 'the first ' .. MAX_SILOS .. ' silos' or nil}
  end
  M.schema = {silo = {position='optional {x,y}: the silo nearest it (default every silo on the surface)', surface='optional surface name (default yours)',
    why='optional true, with position (or one silo there): why its rocket parts are short, as one read: the ingredient it is shortest of (one it lacks for the next part first), the places its feeding inserters take from (what each holds of it; a requester or buffer chest: its request, and what its logistic network holds and robots bring), and that item\'s chain on the silo\'s planet as bottleneck {item} reads it (each step\'s makers by state and what most of them lack, down to the root), with up to 3 makers not working and fixes: why {item, picked, feeders, chain, root, path, not_working, fixes, line}',
    returns='silos [{name, position, surface, parts (X/required, the 2.0 rocket_parts_required, while the rocket is being built), built_parts (ready or rising: the built rocket\'s, 50/50), next_parts (once it is built: ready, rising or launching; the parts the silo makes for the rocket after it: a ready rocket with next_parts 6/50 is built and launches), rocket_ready (true only for a built rocket), rocket ("rocket built (50/50 parts) and ready to launch, not launched; parts for the rocket after it 13/50; last launch 4m10s ago to platform X"; rising into place; launching; or building, parts X/Y), state (the silo\'s rocket state), status, '
      .. 'crafting {part_progress, parts_left, part_s, productivity, rocket_eta_s (at this speed, while working)}, ingredients [{name, per_part, in_silo, in_hands '
      .. '(feeding inserters\' hands), at_sources (what their belts and chests hold), needed (for the parts left), short}], lacks (ingredients the silo holds too few '
      .. 'of for the next part), feeders {inserters, idle, sources}, cargo {kg, lift_kg, room_kg (lift left), stacks, slots, items, over_kg}, trash, robots_bringing (what logistic robots carry or have reserved toward the silo now) and requesting_for (the platform its automatic requests fill for), auto_requests and send_to_orbit_automatically (the GUI checkboxes; configure sets them), '
      .. 'platforms_above (ours in orbit of this planet), platform_requests [{platform, item, flag (matched: the silo\'s network holds the payload a rocket waits for; below_min_payload; split_networks: other networks on the planet hold the rest, named; hub_full: the payload takes more hub slots than are free; filling: the silo fills a rocket for it now), line}] (each request a platform above makes of this planet that its hub lacks), last_launch {ago, tick, to, cargo, by}, line}]; rockets_launched (the force\'s count). '
      .. 'Feeders: inserters within 8 tiles dropping into the silo. Launches are seen from when the harness was deployed. Read only'}}
  return M
end
