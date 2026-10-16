-- The game's alerts and key warnings, pushed (viewer Enginerd, shift07 15:30:
-- "The agents would be a lot more efficient if they'd react to the alerts in
-- the UI, like reacting to unpowered buildings"). Full status listed power,
-- fuel and turret warnings only when an agent pulled it, and the game's alert
-- list (construction materials, robots, repair packs, storage, trains,
-- cargo, collectors) was never read. Here, what a player's alert panel and
-- entity status icons show:
-- - entity statuses: no power (and no pole reaching it), low power, no fuel,
--   gun turrets out of ammo (rebuilt ones still empty 60 s on: named apart),
--   flamethrower turrets dry;
-- - the game's alerts (LuaPlayer.get_alerts, read from an agent player whose
--   alerts are on; attacks, losses and empty turrets are told elsewhere);
-- - per network (networks.lua, task-selfview): draw at 85% of capacity or
--   more for 2 minutes, boilers under 20 minutes of fuel (again at 10 and 5), no idle logistic
--   robot for 10 minutes, accumulators empty within 10 minutes at their net flow.
-- Grouped by kind and 64-tile area on each surface; each group goes to the
-- agents whose board claim covers it, else who built it (last_user), else
-- the nearest agent on that surface. In the team block (team.alerts) at most
-- one digest per agent every 150 s, new or worsening groups only; the
-- game_alerts read lists them all. The scan is kept in storage for 30 s so
-- every peer computes the same lines.
local flameroil = require('flameroil')
return function(api)
  local M = {}
  local CELL, SCAN_TICKS, DIGEST_TICKS, MAX_LINES, MAX_SCAN = 64, 1800, 9000, 5, 20000
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local slots = require('slots')()
  local TYPES = {'assembling-machine', 'furnace', 'mining-drill', 'lab', 'inserter', 'beacon', 'radar', 'roboport',
    'pump', 'electric-turret', 'ammo-turret', 'fluid-turret', 'boiler', 'rocket-silo', 'agricultural-tower',
    'asteroid-collector', 'lamp', 'loader', 'loader-1x1', 'cargo-landing-pad', 'car', 'spider-vehicle', 'reactor'}
  -- Kinds and how a line says them; game alert types not listed read as their name.
  local LABEL = {no_power='no power', unconnected='not connected to power (no pole reaches them)', low_power='low power',
    no_fuel='out of fuel', no_ammo='out of ammo', flamer_dry='out of flamer oil', rebuilt_empty='rebuilt empty',
    burnt_full='stopped by a full burnt-result slot',
    no_material_for_construction='ghosts waiting for materials (no robot can bring them)',
    not_enough_construction_robots='not enough construction robots', not_enough_repair_packs='robots out of repair packs',
    no_storage='robots have no storage for what they carry', no_roboport_storage='no roboport storage',
    train_out_of_fuel='train out of fuel', train_no_path='train has no path', unclaimed_cargo='unclaimed cargo',
    collector_path_blocked='asteroid collector path blocked', pipeline_overextended='pipeline overextended (flow stops)',
    no_platform_storage='platform hub storage full', platform_tile_building_blocked='platform tile building blocked',
    input_spoilage='short of ingredients with spoilage in their input (their recipes do not take it)',
    output_chest_full='stopped: the chest their output goes into has no free slot',
    catalyst_gone='short of an ingredient their own recipe makes (none left in the input to start the next craft)',
    requester_full='requester chests with every slot taken while a request is short',
    heat_no_fuel='heating towers out of fuel and under 500 C (heat exchangers take 500 C and more)',
    outpost_ammo_low='turrets no construction robots reach, under 20% of their ammo slots',
    outpost_turret_lost='turrets no construction robots reached destroyed in the last 10 minutes'}
  local HINT = {no_power='fh call power', unconnected='fh call power', low_power='more power: fh call power', no_fuel='refuel', heat_no_fuel='refuel',
    no_ammo='rearm', flamer_dry='fh call flamers', no_material_for_construction='craft or bring the items for the ghosts',
    not_enough_construction_robots='more construction robots in the roboports', not_enough_repair_packs='repair packs into a roboport or storage chest',
    no_storage='a storage chest in the network', train_out_of_fuel='refuel the locomotive'}
  -- Told elsewhere (attacks, losses, the turret scan).
  local SKIP = {entity_destroyed=true, entity_under_attack=true, turret_fire=true, turret_out_of_ammo=true, custom=true}
  local STATUS
  local function statuses()
    if not STATUS then
      local s = defines.entity_status or {}
      STATUS = {[s.no_power or -1]='no_power', [s.low_power or -2]='low_power', [s.no_fuel or -3]='no_fuel',
        [s.no_minable_resources or -4]='out_of_ore'}
    end
    return STATUS
  end
  -- Drills out of ore (Nick 12:35): a drill whose patch under it is used up reads no_minable_resources and has no
  -- mining target left, so each read remembers the ore every drill mines (storage push_drills, per force, by unit
  -- number); one never seen mining takes the ore the drills still mining in its area mine. The groups are
  -- out_of_ore.<ore> (out_of_ore.unknown when neither says), with the drills still mining that ore in the area and the
  -- nearest patch of it none of our drills are on (the ores read's last survey of that surface; none: not said).
  local function drill_memory(force)
    local s = api.state()
    s.push_drills = s.push_drills or {}
    local mem = s.push_drills[force.name]
    if not mem then mem = {}; s.push_drills[force.name] = mem end
    return mem
  end
  -- A drill seen mining: its ore remembered, and counted in its cell (mining[surface|cx,cy][ore]).
  local function drill_mining(e, surface, mining, dmem)
    local t = try(function() return e.mining_target end)
    local name = t and try(function() return t.name end)
    if not name then return nil end
    local unit = try(function() return e.unit_number end)
    if unit and dmem then dmem[unit] = name end
    if mining then
      local key = surface .. '|' .. math.floor(e.position.x / CELL) .. ',' .. math.floor(e.position.y / CELL)
      mining[key] = mining[key] or {}
      mining[key][name] = (mining[key][name] or 0) + 1
    end
    return name
  end
  local function alert_names()
    local out = {}
    for name, id in pairs(defines.alert_type or {}) do out[id] = name end
    return out
  end

  -- detail: a line for this entity (lost sources: the inserter, what it read, what it puts into), up to MAX_DETAIL a group.
  local MAX_DETAIL = 4
  -- Turret kinds read again when shown (Haiku, shift12 15:20: two empty-ammo alerts sent it to guns already full).
  local RECHECK, MAX_UNITS = {no_ammo=true, rebuilt_empty=true, flamer_dry=true}, 512
  local function add(groups, kind, surface, e, pos, name, by, detail)
    local cx, cy = math.floor(pos.x / CELL), math.floor(pos.y / CELL)
    local key = kind .. '|' .. surface .. '|' .. cx .. ',' .. cy
    local g = groups[key]
    if not g then
      g = {key=key, kind=kind, surface=surface, n=0, names={}, sx=0, sy=0, at={}, by={}}
      groups[key] = g
    end
    g.observed_tick=game.tick
    if e and kind:match('^out_of_ore%.') and not g.drill then
      g.drill={position={x=pos.x,y=pos.y},name=name,unit_number=e.unit_number}
    end
    if e and (kind=='no_power' or kind=='unconnected' or kind=='low_power' or kind=='no_fuel') then
      g.status_entities=g.status_entities or {}
      if #g.status_entities<128 then g.status_entities[#g.status_entities+1]={entity=e,position={x=pos.x,y=pos.y},name=name}
      else g.status_capped=true end
    end
    g.n = g.n + 1
    g.sx, g.sy = g.sx + pos.x, g.sy + pos.y
    if name then g.names[name] = (g.names[name] or 0) + 1 end
    if by then g.by[by] = (g.by[by] or 0) + 1 end
    if #g.at < 4 then g.at[#g.at+1] = {x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10} end
    if detail then g.lost = g.lost or {}; if #g.lost < MAX_DETAIL then g.lost[#g.lost+1] = detail end end
    -- A turret group is read again before it is shown (M.recheck): its turrets by unit number, in its cells.
    if RECHECK[kind] and e then
      local unit = try(function() return e.unit_number end)
      if unit then
        g.units = g.units or {}
        g.nunits = (g.nunits or 0) + 1
        if g.nunits <= MAX_UNITS then g.units[unit] = true end
      end
    end
  end
  local function builder(e)
    return try(function() local u = e.last_user; return u and u.name end)
  end
  -- Lost sources (Haiku, 04:52: "a chest gone alert when a feed chest disappears, since an inserter with no source
  -- fails silently (once this hour, a boiler went no_fuel)"). Each read remembers every inserter's targets
  -- (targets.lua; storage push_inserters, per force, by unit number). An inserter that had a pickup target and now has
  -- none, or whose drop target is gone, is in a group of kind lost_source.<fed> or lost_target.<fed>, where fed is
  -- what it puts into (or put into, when that is gone): boiler, furnace, lab, assembler, else the entity type. It
  -- stays there, with what it read and fed then, until it has a target again or is gone.
  local FED = {boiler='boiler', furnace='furnace', lab='lab', ['assembling-machine']='assembler'}
  local function at_text(pos) return string.format('(%g,%g)', math.floor(pos.x * 10 + 0.5) / 10, math.floor(pos.y * 10 + 0.5) / 10) end
  -- A group's centre where its maker set none (shift23 16:20, Muse: game_alerts failed "attempt to index field 'center'"
  -- on an outpost_turret_lost group, a cell add() made that no merge had centred): the mean of its positions, else its
  -- first position.
  local function centred(g)
    if g.center then return g end
    if g.sx and g.sy and (g.n or 0) > 0 then g.center = {x=math.floor(g.sx / g.n + 0.5), y=math.floor(g.sy / g.n + 0.5)}
    elseif g.at and g.at[1] then g.center = {x=math.floor(g.at[1].x + 0.5), y=math.floor(g.at[1].y + 0.5)} end
    return g
  end
  M.centred = centred
  local function inserter_memory(force)
    local s = api.state()
    s.push_inserters = s.push_inserters or {}
    local mem = s.push_inserters[force.name]
    if not mem then mem = {gen=0, units={}}; s.push_inserters[force.name] = mem end
    return mem
  end
  local function watch_inserter(groups, s, e, mem)
    local unit = try(function() return e.unit_number end)
    local targets = api.targets
    if not (unit and targets) then return end
    local pick, drop = targets.read(e)
    -- The engine's target can stay empty a while after its chest is replaced (Astra, 07:26: a wooden chest upgraded to
    -- a requester; the inserter, holding cable, worked from it): what stands on the point counts as the target, and
    -- the remembered one is the current one, whichever entity that is now.
    if not pick then pick = targets.standing(s, try(function() return e.pickup_position end)) end
    if not drop then drop = targets.standing(s, try(function() return e.drop_position end)) end
    local old = mem.units[unit]
    local now = {g=mem.gen, p=pick and targets.name_at(pick) or nil, d=drop and targets.name_at(drop) or nil, dt=drop and drop.type or nil}
    if old then
      if not pick then now.lost_p = old.lost_p or old.p end
      if not drop then now.lost_d, now.ldt = old.lost_d or old.d, old.ldt or old.dt end
    end
    mem.units[unit] = now
    if not (now.lost_p or now.lost_d) then return end
    local fed = now.dt or now.ldt
    local word = FED[fed] or fed or 'nothing'
    local pos = at_text(e.position)
    local detail
    if now.lost_p then
      detail = string.format('%s %s read %s%s', e.name, pos, now.lost_p,
        now.d and ', puts into ' .. now.d or now.lost_d and ', put into ' .. now.lost_d .. ' (gone too)' or '')
    else
      detail = string.format('%s %s put into %s%s', e.name, pos, now.lost_d, now.p and ', reads ' .. now.p or '')
    end
    add(groups, (now.lost_p and 'lost_source.' or 'lost_target.') .. word, s.name, e, e.position, e.name, builder(e), detail)
  end
  -- After a whole read: forget inserters it did not see (gone, or past the read's budget).
  local function forget_unseen(mem)
    for unit, v in pairs(mem.units) do if v.g ~= mem.gen then mem.units[unit] = nil end end
  end
  -- Turrets rebuilt empty (Astra, shift10: 15+ gun turrets rebuilt by robots with no ammo and destroyed again;
  -- operator 06:20 item 10). Each read remembers every ammo turret (storage push_turrets, per force, by unit number).
  -- One first seen after a whole read was built since, and so is one that died (M.turret_died): rebuilt from its
  -- ghost it has its old unit number again (2.0). While it has had no ammo since it was first seen, for EMPTY_TICKS
  -- or more, it is in a rebuilt_empty group, named with its ammo request (instead of no_ammo). Once it holds ammo it
  -- is like any other turret.
  local EMPTY_TICKS = 3600
  local function turret_memory(force)
    local s = api.state()
    s.push_turrets = s.push_turrets or {}
    local mem = s.push_turrets[force.name]
    if not mem then mem = {gen=0, units={}}; s.push_turrets[force.name] = mem end
    return mem
  end
  -- After a whole read (complete: not cut by the read's budget, and started with this memory: a read under way at a
  -- deploy saw part of the map before it existed): forget turrets it did not see; from now on a turret not seen
  -- before was built since.
  local function turrets_read(mem, complete)
    if not complete then return end
    for unit, v in pairs(mem.units) do if v.g ~= mem.gen then mem.units[unit] = nil end end
    mem.ready = true
  end
  -- The kind for an ammo turret (empty: no ammo in it): rebuilt_empty with its detail, or no_ammo, or nil.
  local function turret_kind(e, empty, mem)
    local unit = mem and try(function() return e.unit_number end)
    local t = unit and mem.units[unit]
    if unit and not t then t = {new=mem.ready or nil}; mem.units[unit] = t end
    if t then
      t.g = mem.gen
      if not empty then t.new, t.empty = nil, nil
      elseif t.new then
        t.empty = t.empty or game.tick
        if game.tick - t.empty >= EMPTY_TICKS then
          local asks = try(function() local x = e.item_request_proxy; return x and x.item_requests end) or {}
          local parts = {}
          for _, r in ipairs(asks) do parts[#parts+1] = r.count .. ' ' .. r.name end
          return 'rebuilt_empty', string.format('%s %s %s', e.name, at_text(e.position),
            #parts > 0 and 'requests ' .. table.concat(parts, ', ') or 'no ammo request')
        end
      end
    end
    return empty and 'no_ammo' or nil
  end
  -- One read is these stages: the entities on each planet surface, the game's
  -- alert list, the network groups, then the merge. scan() runs them all at
  -- once; the background job (M.tick) walks each planet in bands (task-
  -- statuscost, 01:15 on world n: pushalerts.lines up to 150 ms when a reply
  -- ran the whole read; operator 04:00, see SLICE).
  local function entity_list(s, force, t, budget)
    return try(function() return s.find_entities_filtered{force=force, type=t, limit=budget} end) or {}
  end
  -- Entities from..to of a found list into the groups (mem: the inserter memory; tmem: the turret memory).
  -- Spoilable fuel in burners (Sol, shift13 16:50: biochambers starved with 20 nutrients loaded, the batch rotting
  -- within seconds): per cell and name, in mining['rot|surface|cx,cy'][name], how many burn it, how many of those
  -- spoil within ROT_SOON ticks, and the first to spoil (its stack's spoil_tick, item and position). An out-of-fuel
  -- group says it for its names (M.text, worked out when shown).
  local ROT_SOON, HEAT_WARN = 3600, 500
  local function spoiling(e, s, mining)
    if not (mining and api.first_spoil) then return end
    local burner = e.burner
    local inv = burner and burner.inventory
    if not inv then return end
    local tick, item = api.first_spoil(inv)
    if not tick then return end
    local rk = 'rot|' .. s.name .. '|' .. math.floor(e.position.x / CELL) .. ',' .. math.floor(e.position.y / CELL)
    local cell = mining[rk] or {}
    mining[rk] = cell
    local r = cell[e.name] or {n=0, soon=0}
    cell[e.name] = r
    r.n = r.n + 1
    if tick - game.tick < ROT_SOON then r.soon = r.soon + 1 end
    if not r.tick or tick < r.tick then r.tick, r.item, r.at = tick, item, {x=e.position.x, y=e.position.y} end
  end
  local STARVED = {}
  for _, k in ipairs({'item_ingredient_shortage', 'no_ingredients'}) do
    local v = defines.entity_status and defines.entity_status[k]
    if v then STARVED[v] = true end
  end
  -- A full_output maker whose output goes by inserter into a chest with no free slot (Grok, twice: the yumako mash and the
  -- nutrient and bioplastic chests full of spoilage): the chest, its slots and what fills them; and a starved machine
  -- whose recipe makes an ingredient it takes, with none of it in its input (Grok: the egg breeder's output inserter took
  -- its only pentapod egg): that item, what its output holds, and the hand size of the inserters taking from it.
  local FULL = {}
  for _, k in ipairs({'full_output'}) do local v = defines.entity_status and defines.entity_status[k]; if v then FULL[v] = true end end
  local function takers(e)
    local b = e.bounding_box
    local out = {}
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{type='inserter', area={left_top={x=b.left_top.x - 3, y=b.left_top.y - 3},
        right_bottom={x=b.right_bottom.x + 3, y=b.right_bottom.y + 3}}, force=e.force} end) or {}) do
      if try(function() return i.pickup_target end) == e then out[#out+1] = i end
    end
    return out
  end
  local function hand(i)
    local o = try(function() return i.inserter_stack_size_override end) or 0
    if o > 0 then return o end
    local bulk = try(function() return i.prototype.bulk end)
    local f = i.force
    return 1 + ((bulk and try(function() return f.bulk_inserter_capacity_bonus end) or try(function() return f.inserter_stack_size_bonus end)) or 0)
  end
  local function chest_full(e)
    for _, i in ipairs(takers(e)) do
      local d = try(function() return i.drop_target end)
      local inv = d and d.valid and (d.type == 'container' or d.type == 'logistic-container') and try(function() return d.get_inventory(defines.inventory.chest) end)
      if inv and try(function() return inv.count_empty_stacks() end) == 0 then
        local list = try(function() return inv.get_contents() end) or {}
        table.sort(list, function(a, b) return a.count > b.count end)
        local parts = {}
        for k2, st in ipairs(list) do if k2 > 3 then break end; parts[#parts+1] = st.name .. ' ' .. st.count end
        return string.format('%s %s full_output: %s %s puts its output into %s %s, all %d slots taken (%s)', e.name, at_text(e.position), i.name, at_text(i.position),
          d.name, at_text(d.position), #inv, table.concat(parts, ', '))
      end
    end
  end
  -- Recipes that take an item they also make, read once a recipe (most take none: the scan then stops here).
  local CATALYST = {}
  local function catalyst_gone(e)
    local r = try(function() return e.get_recipe() end)
    if not r then return nil end
    local c = CATALYST[r.name]
    if c == nil then
      c = false
      local makes = {}
      for _, pr in ipairs(r.products or {}) do if pr.type == 'item' then makes[pr.name] = true end end
      for _, ing in ipairs(r.ingredients or {}) do if ing.type == 'item' and makes[ing.name] then c = true end end
      CATALYST[r.name] = c
    end
    if not c then return nil end
    local made = {}
    for _, pr in ipairs(r.products or {}) do if pr.type == 'item' then made[pr.name] = true end end
    local input = try(function() return e.get_inventory(defines.inventory.crafter_input or defines.inventory.assembling_machine_input) end)
    local output = try(function() return e.get_output_inventory() end)
    for _, ing in ipairs(r.ingredients or {}) do
      if ing.type == 'item' and made[ing.name] and input and (try(function() return input.get_item_count(ing.name) end) or 0) == 0 then
        local hands = {}
        for _, i in ipairs(takers(e)) do hands[#hands+1] = string.format('%s %s hand %d', i.name, at_text(i.position), hand(i)) end
        return string.format('%s %s %s: its recipe takes %d %s and makes it, and none is in its input (its output holds %d); taken out by %s', e.name, at_text(e.position), r.name,
          ing.amount or 1, ing.name, output and (try(function() return output.get_item_count(ing.name) end) or 0) or 0, #hands > 0 and table.concat(hands, ', ') or 'no inserter')
      end
    end
  end
  local function read_list(groups, s, list, from, to, mem, tmem, mining, dmem)
    local st = statuses()
    for i = from or 1, to or #list do
      local e = list[i]
      if e.valid and mem and e.type == 'inserter' then watch_inserter(groups, s, e, mem) end
      if e.valid then pcall(spoiling, e, s, mining) end
      if e.valid then
        local kind = st[e.status]
        local detail
        if kind == 'no_power' then
          if not try(function() return e.electric_network_id end) then kind = 'unconnected'
          elseif api.network_cursor or api.network_groups then kind = nil end
        end
        -- A burner its full burnt-result slot stopped, whatever its status reads (burnt.lua; Sol, shift14).
        local stuck = api.burnt_stuck and try(function() return api.burnt_stuck(e) end)
        if stuck then
          kind = 'burnt_full'
          detail = string.format('%s %s: burnt-result slot %s; fuel slot %s%s', e.name, at_text(e.position), stuck.burnt,
            stuck.fuel ~= '' and stuck.fuel or 'empty', stuck.foreign and ' (not a fuel it burns: it burns ' .. stuck.burns .. ')' or '')
        end
        if e.type == 'mining-drill' then
          if kind == 'out_of_ore' then
            local unit = try(function() return e.unit_number end)
            kind = 'out_of_ore.' .. (unit and dmem and dmem[unit] or '?')
          else drill_mining(e, s.name, mining, dmem) end
        elseif kind == 'out_of_ore' then kind = nil end
        if e.type == 'ammo-turret' then
          local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
          local tk, td = turret_kind(e, inv and inv.get_item_count() == 0, tmem)
          if tk then kind, detail = tk, td
          else
            -- Under 20% of its ammo slots where no construction robot reaches (Opus, d15 15:20: the south copper
            -- outpost 550 tiles out, cut 5+ times a shift).
            local low = M.outpost_low(e, inv)
            if low then kind, detail = 'outpost_ammo_low', low end
          end
        elseif e.type == 'reactor' and e.burner then
          -- Heating towers (Gemini, d15 07:54: a dedicated warning when they run out of fuel): a burner reactor with an
          -- empty fuel slot and nothing burning, under HEAT_WARN C; one still hotter is not said (feeds gated by its
          -- temperature empty its slot by design).
          local inv = try(function() return e.burner.inventory end)
          local empty = inv and try(function() return inv.is_empty() end)
          local burning = try(function() return e.burner.currently_burning end)
          local left = try(function() return e.burner.remaining_burning_fuel end) or 0
          local temp = try(function() return e.temperature end)
          if empty and not burning and left <= 0 and temp and temp < HEAT_WARN then
            kind, detail = 'heat_no_fuel', string.format('%s %s: %d C, fuel slot empty', e.name, at_text(e.position), math.floor(temp))
          elseif kind == 'no_fuel' and temp and temp >= HEAT_WARN then kind = nil end
        elseif e.type == 'fluid-turret' then
          -- all it holds, its own buffer too (flameroil.lua; fluidbox[1] alone reads empty once the pipe drains)
          local amount = try(function() return (flameroil.read(e)) end)
          if amount and amount < 1 then kind = 'flamer_dry' end
        elseif not kind and (e.type == 'assembling-machine' or e.type == 'furnace') and STARVED[e.status] then
          -- Spoilage its recipe does not take, in the input of a machine short of ingredients (Sol, 22:08; Gleba).
          local sp = try(function() return slots.input_spoilage(e) end)
          if sp then kind, detail = 'input_spoilage', string.format('%s %s: %s', e.name, at_text(e.position), sp.text)
          else
            local cg = try(function() return api.timed and api.timed('pushalerts.catalyst_gone', catalyst_gone, e) or catalyst_gone(e) end)
            if cg then kind, detail = 'catalyst_gone', cg end
          end
        elseif not kind and (e.type == 'assembling-machine' or e.type == 'furnace') and FULL[e.status] then
          local cf = try(function() return api.timed and api.timed('pushalerts.output_chest_full', chest_full, e) or chest_full(e) end)
          if cf then kind, detail = 'output_chest_full', cf end
        end
        if kind then add(groups, kind, s.name, e, e.position, e.name, builder(e), detail) end
      end
    end
  end
  local function entities(groups, s, force, t, budget, mem, tmem, mining, dmem)
    local list = entity_list(s, force, t, budget)
    read_list(groups, s, list, nil, nil, mem, tmem, mining, dmem)
    return #list
  end
  -- The background job's step (operator 04:00: steps of a whole-surface find, then 1500 entities, burst to 138 ms in
  -- a game second): one band of a planet (walk.lua) or SLICE of the entities it found, one step every few ticks so
  -- a read spreads over its 30 s.
  local SLICE = 150
  local NET_SLICE = 2   -- networks whose alert groups one step of the background read makes
  local walk = api.walk or require('walk'){state=api.state}
  local function planets()
    local out = {}
    for _, s in pairs(game.surfaces) do
      if not try(function() return s.platform end) then out[#out+1] = s end  -- platforms: platalerts.lua
    end
    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
    return out
  end
  local function game_alerts(groups, force)
    -- The game's alert list, as an agent player's alert panel shows it.
    local reader = api.alert_reader and api.alert_reader(force)
    local raw = reader and try(function() return reader.get_alerts{} end)
    if raw then
      local names = alert_names()
      for surface_index, by_type in pairs(raw) do
        local s = game.surfaces[surface_index]
        for t, list in pairs(by_type) do
          local kind = names[t]
          if kind and not SKIP[kind] and s then
            for _, al in ipairs(list) do
              local e = al.target
              local ok = e and try(function() return e.valid end)
              local pos = ok and e.position or al.position
              if pos then
                add(groups, kind, s.name, ok and e or nil, pos, ok and e.name or (al.prototype and try(function() return al.prototype.name end)),
                  ok and builder(e) or nil)
              end
            end
          end
        end
      end
    end
  end
  -- Drills out of ore whose ore no read saw take the ore the drills still mining in their cell and the 8 around mine
  -- most; else out_of_ore.unknown.
  local function name_unknown_ore(groups, mining)
    local keys = {}
    for key, g in pairs(groups) do if g.kind == 'out_of_ore.?' then keys[#keys+1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local g = groups[key]
      local surface, cx, cy = key:match('|(.-)|(-?%d+),(-?%d+)$')
      cx, cy = tonumber(cx), tonumber(cy)
      local by = {}
      for dx = -1, 1 do for dy = -1, 1 do
        for ore, n in pairs((mining or {})[surface .. '|' .. (cx + dx) .. ',' .. (cy + dy)] or {}) do by[ore] = (by[ore] or 0) + n end
      end end
      local best, bn = nil, 0
      for ore, n in pairs(by) do if n > bn or (n == bn and best and ore < best) then best, bn = ore, n end end
      local kind = 'out_of_ore.' .. (best or 'unknown')
      local nk = kind .. '|' .. surface .. '|' .. cx .. ',' .. cy
      groups[key] = nil
      local h = groups[nk]
      if not h then g.kind, g.key = kind, nk; groups[nk] = g
      else
        h.drill=h.drill or g.drill
        h.n, h.sx, h.sy = h.n + g.n, h.sx + g.sx, h.sy + g.sy
        for n, v in pairs(g.names) do h.names[n] = (h.names[n] or 0) + v end
        for n, v in pairs(g.by) do h.by[n] = (h.by[n] or 0) + v end
        for _, pos in ipairs(g.at) do if #h.at < 4 then h.at[#h.at+1] = pos end end
      end
    end
  end
  -- The nearest patch of an ore that none of our drills are on, from the ores read's last survey of the surface.
  local function untapped(force, surface, ore, center)
    local s = game.surfaces[surface]
    local entry = s and ((api.state().ores or {})[force .. '@' .. s.index])
    local best, bd
    for _, q in ipairs(entry and entry.patches or {}) do
      if q.name == ore and (q.miners or 0) == 0 and q.centre then
        local d = ((q.centre.x - center.x) ^ 2 + (q.centre.y - center.y) ^ 2) ^ 0.5
        if not bd or d < bd then best, bd = q, d end
      end
    end
    if not best then return nil end
    return {x=math.floor(best.centre.x + 0.5), y=math.floor(best.centre.y + 0.5), d=math.floor(bd + 0.5), amount=best.yield or best.amount}
  end
  local function merge(groups, extra, mining, force)
    name_unknown_ore(groups, mining)
    -- Cells of one kind on one surface that touch (8 neighbours) are one area:
    -- a turret line across a cell edge is one group. Its key is its first cell.
    local out, done = {}, {}
    local cells = {}
    for key, g in pairs(groups) do cells[#cells+1] = key end
    table.sort(cells)
    for _, key in ipairs(cells) do
      if not done[key] then
        local g = groups[key]
        local kind, surface, cx, cy = key:match('^(.-)|(.-)|(-?%d+),(-?%d+)$')
        local area = {key=key, kind=g.kind, surface=g.surface, n=0, names={}, sx=0, sy=0, at={}, by={}}
        local queue = {{tonumber(cx), tonumber(cy)}}
        done[key] = true
        local ore = kind:match('^out_of_ore%.(.+)$')
        -- Drills still mining that ore in the area's cells and the cells around them.
        local near = ore and {}
        if ore then area.ore, area.still = ore, 0 end
        local fuel_cells = kind == 'no_fuel' and {} or nil
        while #queue > 0 do
          local c = table.remove(queue)
          if fuel_cells then fuel_cells[#fuel_cells+1] = c end
          local k = kind .. '|' .. surface .. '|' .. c[1] .. ',' .. c[2]
          local part = groups[k]
          if near then
            for dx = -1, 1 do for dy = -1, 1 do
              local mk = surface .. '|' .. (c[1] + dx) .. ',' .. (c[2] + dy)
              if not near[mk] then near[mk] = true; area.still = area.still + (((mining or {})[mk] or {})[ore] or 0) end
            end end
          end
          area.drill=area.drill or part.drill
          area.observed_tick=math.min(area.observed_tick or game.tick,part.observed_tick or game.tick)
          if part.status_entities then
            area.status_entities=area.status_entities or {}
            for _,r in ipairs(part.status_entities) do
              if #area.status_entities<128 then area.status_entities[#area.status_entities+1]=r else area.status_capped=true end
            end
            area.status_capped=area.status_capped or part.status_capped
          end
          area.n, area.sx, area.sy = area.n + part.n, area.sx + part.sx, area.sy + part.sy
          if part.units then
            area.units = area.units or {}
            for u in pairs(part.units) do area.units[u] = true end
            area.nunits = (area.nunits or 0) + (part.nunits or 0)
            area.cells = area.cells or {}
            area.cells[#area.cells+1] = {c[1], c[2]}
          end
          for n, v in pairs(part.names) do area.names[n] = (area.names[n] or 0) + v end
          for n, v in pairs(part.by) do area.by[n] = (area.by[n] or 0) + v end
          for _, pos in ipairs(part.at) do if #area.at < 4 then area.at[#area.at+1] = pos end end
          for _, d in ipairs(part.lost or {}) do area.lost = area.lost or {}; if #area.lost < MAX_DETAIL then area.lost[#area.lost+1] = d end end
          for dx = -1, 1 do for dy = -1, 1 do
            local nk = kind .. '|' .. surface .. '|' .. (c[1] + dx) .. ',' .. (c[2] + dy)
            if groups[nk] and not done[nk] then done[nk] = true; queue[#queue+1] = {c[1] + dx, c[2] + dy} end
          end end
        end
        area.center = {x=math.floor(area.sx / area.n + 0.5), y=math.floor(area.sy / area.n + 0.5)}
        area.sx, area.sy = nil, nil
        if ore and ore ~= 'unknown' and force then area.untapped = try(function() return untapped(force.name, surface, ore, area.center) end) end
        -- Out of fuel: the spoiling fuel of the same names in its cells and the cells around them (spoiling above).
        if fuel_cells and mining then
          local rot, seen = {}, {}
          for _, c in ipairs(fuel_cells) do
            for dx = -1, 1 do for dy = -1, 1 do
              local rk = 'rot|' .. surface .. '|' .. (c[1] + dx) .. ',' .. (c[2] + dy)
              if not seen[rk] then
                seen[rk] = true
                for name, r in pairs(mining[rk] or {}) do
                  if area.names[name] then
                    local a = rot[name] or {n=0, soon=0}
                    rot[name] = a
                    a.n, a.soon = a.n + r.n, a.soon + r.soon
                    if not a.tick or r.tick < a.tick then a.tick, a.item, a.at = r.tick, r.item, r.at end
                  end
                end
              end
            end end
          end
          if next(rot) then area.rot = rot end
        end
        out[#out+1] = area
      end
    end
    -- Network groups (networks.lua): power_high, boiler_fuel, robots_busy,
    -- one per network, with their own line and level (n).
    for _, g in ipairs(extra or {}) do out[#out+1] = centred(g) end
    table.sort(out, function(a, b) return a.n > b.n or (a.n == b.n and a.key < b.key) end)
    return out
  end
  local function network_groups(force)
    return api.network_groups and try(function() return api.network_groups(force) end) or {}
  end
  -- One read of everything at once: groups (array, worst first).
  local function scan(force)
    local groups, budget = {}, MAX_SCAN
    local mem, tmem = inserter_memory(force), turret_memory(force)
    local mining, dmem = {}, drill_memory(force)
    mem.gen, tmem.gen = mem.gen + 1, tmem.gen + 1
    for _, s in ipairs(planets()) do budget = budget - entities(groups, s, force, TYPES, budget, mem, tmem, mining, dmem) end
    forget_unseen(mem)
    turrets_read(tmem, budget > 0)
    game_alerts(groups, force)
    return merge(groups, network_groups(force), mining, force)
  end
  -- The background read, one stage per tick, its state in storage so every
  -- peer runs the same: started when the last read is SCAN_TICKS old.
  local function forces()
    local out = {}
    for _, f in pairs(game.forces or {}) do if f.players and #f.players > 0 then out[#out+1] = f end end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end
  -- A call timed as its own profile part while the operator profile runs (runtime M.timed); else just the call.
  local function timed(label, fn, ...)
    if api.timed then return api.timed(label, fn, ...) end
    return fn(...)
  end
  local step_do
  function M.tick(tick)
    local s = api.state()
    s.push_alerts = s.push_alerts or {}
    s.push_jobs = s.push_jobs or {}
    s.push_bg = true
    for _, force in ipairs(forces()) do
      -- A step that fails ends its job (noted in push_errors); the last read is kept another SCAN_TICKS.
      local ok, err = pcall(M.step, s, force, tick)
      if not ok then
        s.push_jobs[force.name] = nil
        s.push_errors = {count=((s.push_errors or {}).count or 0) + 1, last=tostring(err), tick=tick}
        if s.push_alerts[force.name] then s.push_alerts[force.name].tick = tick end
      end
    end
  end
  function M.step(s, force, tick)
    do
      local job = s.push_jobs[force.name]
      local c = s.push_alerts[force.name]
      if not job and (not c or tick - c.tick >= SCAN_TICKS) then
        local stages = {}
        for _, surface in ipairs(planets()) do stages[#stages+1] = {surface=surface.name} end
        stages[#stages+1] = {step='alerts'}
        stages[#stages+1] = {step='networks'}
        stages[#stages+1] = {step='merge'}
        stages[#stages+1] = {step='drill_sites'}
        s.push_steps = s.push_steps or {}
        job = {start=tick, stages=stages, i=1, groups={}, mining={}, budget=MAX_SCAN, steps=0,
          every=walk.every(s.push_steps[force.name], SCAN_TICKS)}
        s.push_jobs[force.name] = job
        local mem, tmem = inserter_memory(force), turret_memory(force)
        mem.gen, tmem.gen = mem.gen + 1, tmem.gen + 1
        job.tgen = tmem.gen
      elseif job and walk.due(job, tick, SCAN_TICKS) then
        job.steps = job.steps + 1
        local stage = job.stages[job.i]
        -- (each kind of step its own profile part, pushalerts.<kind>: operator 18:12, pushalerts.tick 487 ms in one
        -- game second at 17:53)
        local kind = stage.surface and (job.list and 'slice' or 'band') or stage.step
        timed('pushalerts.' .. kind, step_do, s, force, tick, job, stage)
      end
    end
  end
  step_do = function(s, force, tick, job, stage)
    if stage.surface then
      -- A planet: a band found in one step (walk.lua), then read SLICE a step.
      local surface
      for _, x in ipairs(planets()) do if x.name == stage.surface then surface = x end end
      if not surface or job.budget <= 0 then job.i = job.i + 1; job.walk, job.list = nil, nil
      elseif not job.list then
        job.walk = job.walk or walk.start(surface)
        local list = walk.band(job.walk, surface, {force=force, type=TYPES, limit=job.budget})
        if list then job.list, job.at = list, 1; job.budget = job.budget - #list
        else job.walk = nil; job.i = job.i + 1 end
      else
        local last = math.min(#job.list, job.at + SLICE - 1)
        read_list(job.groups, surface, job.list, job.at, last, inserter_memory(force), turret_memory(force), job.mining, drill_memory(force))
        job.at = last + 1
        if job.at > #job.list then job.list, job.at = nil, nil end
      end
    elseif stage.step == 'alerts' then
      job.i = job.i + 1; game_alerts(job.groups, force); forget_unseen(inserter_memory(force))
      local tmem = turret_memory(force)
      turrets_read(tmem, job.budget > 0 and job.tgen == tmem.gen)
    elseif stage.step == 'networks' then
      -- NET_SLICE networks a step, then the lightning and science groups each a step (operator 18:12: all of them in
      -- one tick took 58-60 ms on world n); without the stepped api, all at once as before.
      if api.network_cursor then
        job.net = job.net or api.network_cursor(force)
        local done, out = api.network_step(job.net, NET_SLICE)
        if done then job.extra, job.net = out, nil; job.i = job.i + 1 end
      else job.i = job.i + 1; job.extra = network_groups(force) end
    elseif stage.step=='merge' then
      job.result={tick=job.start,groups=merge(job.groups,job.extra,job.mining,force)}
      job.i=job.i+1;job.site_index=1
      job.stages[job.i]=job.stages[job.i] or {step='drill_sites'}
    else
      -- At most one depleted group lookup in a background step. Never in a
      -- reply; drill_sites caches both a free site and a bounded miss.
      local groups=job.result.groups
      while job.site_index<=#groups do
        local g=groups[job.site_index];job.site_index=job.site_index+1
        if api.drill_site and g.drill and g.ore~='unknown' then
          g.drill_site=try(function() return api.drill_site(force,g) end)
          return
        end
      end
      s.push_alerts[force.name]=job.result
      s.push_steps[force.name] = job.steps
      s.push_jobs[force.name] = nil
    end
  end
  -- Whether no construction robot reaches e (no logistic network's construction area covers it).
  function M.remote(e)
    local nets = try(function() return e.surface.find_logistic_networks_by_construction_area(e.position, e.force) end)
    return nets ~= nil and #nets == 0
  end
  -- An ammo turret with ammo under LOW_SHARE of what its slots hold, where no construction robot reaches: its line.
  local LOW_SHARE, LOST_KEEP = 0.2, 36000
  function M.outpost_low(e, inv)
    if not inv then return nil end
    local n = try(function() return inv.get_item_count() end) or 0
    if n <= 0 then return nil end
    local cap, name = 0, nil
    for i = 1, try(function() return #inv end) or 0 do
      local st = inv[i]
      if st.valid_for_read then name = name or st.name; cap = cap + (try(function() return prototypes.item[st.name].stack_size end) or 0)
      else cap = cap + (name and (try(function() return prototypes.item[name].stack_size end) or 0) or 0) end
    end
    if cap <= 0 or n >= LOW_SHARE * cap or not M.remote(e) then return nil end
    return string.format('%s %s: %d of %d %s (%d%%)', e.name, at_text(e.position), n, cap, name or 'ammo', math.floor(100 * n / cap))
  end
  -- One of our turrets died (the runtime's on_entity_died): marked built since, for when its ghost is built again; one
  -- no construction robot reached is kept LOST_KEEP ticks for the outpost_turret_lost group.
  function M.turret_died(e)
    local s = api.state()
    local mem = s.push_turrets and s.push_turrets[e.force.name]
    local unit = mem and e.unit_number
    if unit then mem.units[unit] = {new=true, g=mem.gen} end
    if M.remote(e) then
      s.push_lost = s.push_lost or {}
      table.insert(s.push_lost, {tick=game.tick, force=e.force.name, surface=e.surface.name, name=e.name, position={x=e.position.x, y=e.position.y}})
      while #s.push_lost > 64 do table.remove(s.push_lost, 1) end
    end
  end
  -- The last finished read; with the background job running it never reads
  -- in a reply, except a force's very first (and tests without the job).
  local function with_belts(c,force)
    local lost = {}
    for _, l in ipairs(api.state().push_lost or {}) do
      if l.force == force.name and game.tick - l.tick <= LOST_KEEP then
        add(lost, 'outpost_turret_lost', l.surface, nil, l.position, l.name, nil, string.format('%s %s destroyed %ds ago', l.name, at_text(l.position), math.floor((game.tick - l.tick) / 60)))
      end
    end
    if not api.belt_groups and not next(lost) then return c end
    local out={tick=c.tick,groups={}}
    for _,g in ipairs(c.groups) do out.groups[#out.groups+1]=g end
    for _,g in ipairs(api.belt_groups and api.belt_groups(force) or {}) do out.groups[#out.groups+1]=centred(g) end
    -- (cells as add() makes them: centred here, as merge centres the scan's)
    for _,g in pairs(lost) do g.observed_tick=game.tick; out.groups[#out.groups+1]=centred(g) end
    return out
  end
  local function current(force)
    local s = api.state()
    s.push_alerts = s.push_alerts or {}
    local c = s.push_alerts[force.name]
    if c and (s.push_bg or game.tick - c.tick < SCAN_TICKS) then return with_belts(c,force) end
    c = {tick=game.tick, groups=scan(force)}
    s.push_alerts[force.name] = c
    return with_belts(c,force)
  end

  -- The last groups as they are, never scanned here (open.lua reads them for a sleep's reply): {} before the first.
  function M.cached_groups(force)
    local c = (api.state().push_alerts or {})[force.name]
    return c and c.groups or {}
  end
  -- Who hears a group: the owners of active board claims over its centre (on its surface),
  -- else agents who built in it, else the nearest agent on its surface.
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  -- The claims over a point on the group's surface.
  local function claims_over(g, pos)
    local out, board = {}, api.state().board
    for _, i in pairs(board and board.items or {}) do
      local a = i.area
      if pos and i.kind == 'claim' and ACTIVE[i.status] and i.owner and a and pos.x >= a.left_top.x and pos.x <= a.right_bottom.x
        and pos.y >= a.left_top.y and pos.y <= a.right_bottom.y
        and (api.claim_surface and api.claim_surface(i) or i.surface or 'nauvis') == g.surface then out[#out+1] = i end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
  end
  M.claims_over = claims_over
  local function owners(g, roster)
    local out = {}
    for _, i in ipairs(claims_over(g, g.center)) do out[i.owner] = 'claim' end
    -- A boiler's feed chest in someone's claim (Haiku, shift17 10:50: "an alert that names the owner of a claimed boiler
    -- feed chest when it is empty, so the fuel owner is told directly"): that owner hears it too.
    for _, i in ipairs(claims_over(g, g.chest_at)) do out[i.owner] = out[i.owner] or 'claim' end
    if next(out) then return out end
    for name in pairs(g.by) do if roster[name] then out[name] = 'built' end end
    if next(out) then return out end
    local best, d2 = nil, math.huge
    for name, a in pairs(roster) do
      local pl = a.place
      if pl and pl.key == g.surface and pl.position and not pl.dead and g.center then
        local d = (pl.position.x - g.center.x) ^ 2 + (pl.position.y - g.center.y) ^ 2
        if d < d2 then best, d2 = name, d end
      end
    end
    if best then out[best] = 'nearest' end
    return out
  end
  local function roster()
    local out = {}
    for _, a in ipairs(try(api.agents) or {}) do out[a.name] = {index=a.index, place=api.place and try(function() return api.place(a.index) end)} end
    return out
  end
  local function what(g)
    local names = {}
    for name, n in pairs(g.names) do names[#names+1] = {name=name, n=n} end
    table.sort(names, function(a, b) return a.n > b.n or (a.n == b.n and a.name < b.name) end)
    if #names == 1 then return g.n .. ' ' .. names[1].name end
    if #names == 0 then return tostring(g.n) end
    local parts = {}
    for i = 1, math.min(3, #names) do parts[i] = names[i].n .. ' ' .. names[i].name end
    return string.format('%d (%s%s)', g.n, table.concat(parts, ', '), #names > 3 and ', ...' or '')
  end
  -- A turret group now (no_ammo, rebuilt_empty, flamer_dry): its turrets found again in its cells, only those still
  -- empty counted (a turret refilled since the read, by anyone, drops out; one gone too). nil when none is: the group is
  -- not shown, and its told count is cleared, so a turret that runs dry again is news. Other groups as they are.
  local TURRET_TYPE = {no_ammo='ammo-turret', rebuilt_empty='ammo-turret', flamer_dry='fluid-turret'}
  local function still_empty(e, kind)
    if kind == 'flamer_dry' then
      local amount = try(function() return (flameroil.read(e)) end)
      return amount ~= nil and amount < 1
    end
    local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
    return inv ~= nil and inv.get_item_count() == 0
  end
  function M.recheck(g, force)
    if g.status_entities then
      local keep,names,at,unknown={}, {}, {}, false
      local surface=game.surfaces[g.surface]
      if not surface then for _,v in pairs(game.surfaces) do if v.name==g.surface then surface=v;break end end end
      for _,r in ipairs(g.status_entities) do
        local visible=surface and (not force.is_chunk_visible or force.is_chunk_visible(surface,{x=math.floor(r.position.x/32),y=math.floor(r.position.y/32)}))
        local active=true
        if visible then
          local e=r.entity
          active=e.valid and ((g.kind=='unconnected' and not e.electric_network_id and
            (e.status==defines.entity_status.no_power or e.status==defines.entity_status.low_power)) or
            (g.kind~='unconnected' and statuses()[e.status]==g.kind))
        else unknown=true end
        if active then
          keep[#keep+1]=r;names[r.name]=(names[r.name] or 0)+1
          if #at<4 then at[#at+1]=r.position end
        end
      end
      if #keep==0 and not g.status_capped then return nil end
      local c={};for k,v in pairs(g) do c[k]=v end
      c.n=#keep+math.max(0,g.n-#g.status_entities);c.names=names;c.at=at
      c.stale=unknown or g.status_capped;c.checked_tick=game.tick
      return c
    end
    if not (RECHECK[g.kind] and g.units and g.cells) then return g end
    local surface
    for _, x in pairs(game.surfaces) do if x.name == g.surface then surface = x end end
    if not surface then return nil end
    local n, names, at, seen, keep, counted = 0, {}, {}, 0, {}, {}
    for _, c in ipairs(g.cells) do
      local box = {{c[1] * CELL, c[2] * CELL}, {(c[1] + 1) * CELL, (c[2] + 1) * CELL}}
      for _, e in ipairs(surface.find_entities_filtered{area=box, type=TURRET_TYPE[g.kind], force=force, limit=4096}) do
        local unit = e.valid and try(function() return e.unit_number end)
        -- On a cell edge a turret is in two cells' finds: counted once.
        if unit and g.units[unit] and not counted[unit] then
          counted[unit] = true
          seen = seen + 1
          if still_empty(e, g.kind) then
            n = n + 1
            names[e.name] = (names[e.name] or 0) + 1
            if #at < 4 then at[#at+1] = {x=math.floor(e.position.x * 10 + 0.5) / 10, y=math.floor(e.position.y * 10 + 0.5) / 10} end
            keep[at_text(e.position)] = true
          end
        end
      end
    end
    -- Past MAX_UNITS the rest were not remembered: taken as they were read.
    n = n + math.max(0, (g.nunits or 0) - MAX_UNITS)
    if n == 0 then return nil end
    if n == g.n then return g end
    local c = {}
    for k, v in pairs(g) do c[k] = v end
    c.n, c.names, c.at = n, names, at
    if g.lost then
      c.lost = {}
      for _, d in ipairs(g.lost) do
        local pos = d:match('(%(%-?[%d%.]+,%-?[%d%.]+%))')
        if not pos or keep[pos] then c.lost[#c.lost+1] = d end
      end
    end
    return c
  end
  -- plain: without the hint (the review block, selfview.lua).
  -- was: the count told before, or (a group with now_text) what its now_text said then.
  -- Where a group is: one entity at its own position as the game gives it (Muse 09:24: alert coordinates rounded to
  -- integers while chests sit at x.5, so a copied position missed the chest); more, the centre of the group.
  local function near_text(g)
    if g.n == 1 and g.at and g.at[1] then return at_text(g.at[1]) end
    return string.format('(%d,%d)', g.center.x, g.center.y)
  end
  function M.text(g, here, was, plain)
    centred(g)
    if not g.line and not g.center then
      return string.format('%d %s on %s (no position recorded)', g.n or 0, LABEL[g.kind] or tostring(g.kind):gsub('_', ' '), tostring(g.surface))
    end
    if g.line then
      local before = type(was) == 'string' and ' (was ' .. was .. ')' or was and string.format(' (was %d%s)', was, g.unit or '') or ''
      -- whose claim the boiler's feed chest is in (Haiku, shift17 10:50)
      local claim = ''
      if g.chest_at then
        local names = {}
        for _, i in ipairs(claims_over(g, g.chest_at)) do names[#names+1] = string.format("%s's claim #%d", i.owner, i.id) end
        if #names > 0 then claim = '; the chest is in ' .. table.concat(names, ', ') end
      end
      return g.line .. claim .. (g.surface ~= here and ' on ' .. g.surface or '') .. before
    end
    local lost, fed = g.kind:match('^lost_(%a+)%.(.+)$')
    if lost then
      -- '2 inserters feeding boiler lost their pickup target near (60,14): burner-inserter (60,14) read wooden-chest (41,13), puts into boiler (60,16); ...'
      local one = g.n == 1
      return string.format('%d inserter%s feeding %s lost %s %s target near %s%s%s: %s%s', g.n, one and '' or 's', fed,
        one and 'its' or 'their', lost == 'source' and 'pickup' or 'drop', near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
    end
    if g.ore then
      -- '6 electric-mining-drill out of ore near (40,-60): iron-ore; 4 still mining there; nearest untapped iron-ore (180,-20) 145 tiles, about 1.2M ore'
      local u = g.untapped
      local amount = u and u.amount and (u.amount >= 1e6 and string.format('%.1fM', u.amount / 1e6) or u.amount >= 1e4 and string.format('%dk', math.floor(u.amount / 1e3 + 0.5)) or tostring(math.floor(u.amount)))
      local site=g.drill_site
      local site_text=site and (site.site and string.format('; nearest checked %s site with room for %s (%g,%g), %.1f tiles from drill (%g,%g), %g ore; checked tick %d within %d tiles',
        g.ore,site.drill,site.site.position.x,site.site.position.y,site.site.distance,site.origin.x,site.origin.y,site.site.amount,site.tick,site.radius)
        or string.format('; no checked free %s site within %d tiles of drill (%g,%g); checked tick %d%s',g.ore,site.radius,site.origin.x,site.origin.y,site.tick,site.truncated and '; lookup capped' or '')) or ''
      return string.format('%s out of ore near %s%s%s: %s; %d still mining there%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        g.ore == 'unknown' and 'ore not seen' or g.ore, g.still or 0,
        (u and string.format('; nearest untapped %s (%d,%d) %d tiles, about %s ore', g.ore, u.x, u.y, u.d, amount) or '')..site_text)
    end
    if g.kind == 'input_spoilage' then
      -- '2 biochamber short of ingredients with spoilage in their input near (40,12): biochamber (40,12): input holds spoilage 50 in 1 of its 3 slots (...); ...'
      return string.format('%s short of ingredients with spoilage in their input near %s%s%s: %s%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
    end
    if g.kind == 'heat_no_fuel' then
      -- '2 heating-tower out of fuel and under 500 C near (40,12): heating-tower (40.5,12.5): 412 C, fuel slot empty; ...; refuel'
      return string.format('%s out of fuel and under 500 C near %s%s%s: %s%s%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '',
        not plain and '; refuel' or '')
    end
    if g.kind == 'burnt_full' then
      -- '2 biochamber stopped by a full burnt-result slot near (57,61): biochamber (45.5,72.5): burnt-result slot spoilage*200; fuel slot spoilage*3 (not a fuel it burns: it burns nutrients); ...'
      return string.format('%s stopped by a full burnt-result slot near %s%s%s: %s%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
    end
    if g.kind == 'rebuilt_empty' then
      -- '2 gun-turret rebuilt empty near (61,15): no ammo since built, 60+ s: gun-turret (60,14) requests 10 firearm-magazine; ...'
      return string.format('%s rebuilt empty near %s%s%s: no ammo since built, 60+ s: %s%s%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '',
        not plain and '; rearm' or '')
    end
    local hint = not plain and HINT[g.kind]
    -- Spoiling fuel of those burners around it (merge): how many still burn it, how many spoil within ROT_SOON, the first.
    local rot = {}
    local names = {}
    for name in pairs(g.rot or {}) do names[#names+1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local r = g.rot[name]
      local left = r.tick - game.tick
      rot[#rot+1] = string.format('%d %s around it burn spoiling fuel, %d of them within %ds; the first: %s %s at (%g,%g)', r.n, name, r.soon,
        ROT_SOON / 60, r.item, left > 0 and string.format('spoils in %ds', math.floor(left / 60 + 0.5)) or 'spoiled', r.at.x, r.at.y)
    end
    return string.format('%s %s near %s%s%s%s%s', what(g), LABEL[g.kind] or g.kind:gsub('_', ' '), near_text(g),
      g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '', hint and '; ' .. hint or '',
      (#rot > 0 and '; ' .. table.concat(rot, '; ') or '')..(g.stale and '; last observed tick '..(g.observed_tick or 0)..'; current state partly unknown' or ''))
  end

  -- Team block lines for p: at most one digest every DIGEST_TICKS, groups
  -- addressed to p that are new or grew since p was told. A group's rank,
  -- when it has one, is what grows (boiler_fuel: the step it reached, then
  -- how many boilers); its now_text is kept to say what it was.
  function M.lines(p, h)
    local mem = h.push or {told={}}
    if mem.tick and game.tick - mem.tick < DIGEST_TICKS then return {} end
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who = roster()
    local now, lines, more = {}, {}, 0
    for _, g0 in ipairs(c.groups) do
      -- One of yours, a turret group read again first: refilled since, it is not shown (nor counted as told).
      local g = owners(g0, who)[me] and M.recheck(g0, p.force) or nil
      if g then
        local level = g.rank or g.n
        now[g.key] = level
        local told = mem.told[g.key]
        if not told or level > told then
          if #lines < MAX_LINES then
            lines[#lines+1] = M.text(g, here, told and (mem.said and mem.said[g.key] or (not g.rank and told)) or nil)
            mem.told[g.key] = level
            if g.now_text then mem.said = mem.said or {}; mem.said[g.key] = g.now_text end
          else more = more + 1 end
        elseif level < told then  -- better: a rise from here is news again
          mem.told[g.key] = level
          if g.now_text then mem.said = mem.said or {}; mem.said[g.key] = g.now_text end
        end
      end
    end
    for key in pairs(mem.told) do if not now[key] then mem.told[key] = nil end end  -- gone: news again if it returns
    for key in pairs(mem.said or {}) do if not mem.told[key] then mem.said[key] = nil end end
    if more > 0 then lines[#lines+1] = string.format('+%d more alert groups: fh call game_alerts', more) end
    if #lines > 0 then mem.tick = game.tick end
    h.push = (next(mem.told) or mem.tick) and mem or nil
    return lines
  end

  -- Drills out of ore per surface (the shift start's networks block): 'drills out of ore: 14 (nauvis 12, vulcanus 2)';
  -- nil when none.
  function M.out_of_ore_line(force)
    local c = current(force)
    local by, total, order = {}, 0, {}
    for _, g in ipairs(c.groups) do
      if g.ore then
        if not by[g.surface] then by[g.surface] = 0; order[#order+1] = g.surface end
        by[g.surface] = by[g.surface] + g.n; total = total + g.n
      end
    end
    if total == 0 then return nil end
    table.sort(order, function(a, b) return by[a] > by[b] or (by[a] == by[b] and a < b) end)
    local parts = {}
    for _, s in ipairs(order) do parts[#parts+1] = s .. ' ' .. by[s] end
    return string.format('drills out of ore: %d (%s)', total, table.concat(parts, ', '))
  end
  -- For a sleep that wakes on chosen alert kinds (Luna, 19:50: low power, starvation in a claim): the groups of those
  -- kinds addressed to p now (a kind matches its own sub-kinds: lost_source matches lost_source.boiler), each
  -- {level, text}; a group new since the sleep began, or grown, wakes it (waits.lua).
  local function kind_matches(kind, kinds)
    for _, k in ipairs(kinds) do
      if kind == k or kind:sub(1, #k + 1) == k .. '.' then return true end
    end
    return false
  end
  function M.levels(p, kinds)
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who, out = roster(), {}
    for _, g in ipairs(c.groups) do
      if g.kind and kind_matches(g.kind, kinds) and owners(g, who)[me] then
        out[g.key] = {level=g.rank or g.n, text=M.text(g, here, nil, true)}
      end
    end
    return out
  end
  -- Machines in p's own active board claims that lack ingredients now (assemblers and furnaces, the game's status):
  -- {unit = line}; at most STARVED_FIND a claim.
  local STARVED_FIND = 500
  local STARVED = {item_ingredient_shortage=true, fluid_ingredient_shortage=true, no_ingredients=true}
  function M.starved(p)
    local me = api.who(p)
    local board = api.state().board
    local out = {}
    for _, i in pairs(board and board.items or {}) do
      local a = i.area
      if i.kind == 'claim' and ACTIVE[i.status] and i.owner == me and a then
        local name, surface = api.claim_surface and api.claim_surface(i) or i.surface or 'nauvis', nil
        for _, x in pairs(game.surfaces) do if x.name == name then surface = x end end
        for _, e in ipairs(surface and try(function()
          return surface.find_entities_filtered{area={{a.left_top.x, a.left_top.y}, {a.right_bottom.x, a.right_bottom.y}}, force=p.force, type={'assembling-machine', 'furnace'}, limit=STARVED_FIND}
        end) or {}) do
          local status = e.valid and api.status_name and api.status_name(e)
          if status and STARVED[status] and e.unit_number then
            out[e.unit_number] = string.format('%s %s in your claim "%s" %s', e.name, string.format('(%g,%g)', e.position.x, e.position.y),
              tostring(i.title or i.id), status:gsub('_', ' '))
          end
        end
      end
    end
    return out
  end
  -- Groups now in p's own board claims (selfview.lua review), worst first, without hints.
  function M.claim_lines(p)
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who, out = roster(), {}
    for _, g in ipairs(c.groups) do
      if owners(g, who)[me] == 'claim' then out[#out+1] = M.text(g, here, nil, true) end
    end
    return out
  end
  -- The game_alerts read: every group now, with who it goes to.
  function M.read(p, a)
    local c = current(p.force)
    local who = roster()
    local here = try(function() return p.surface.name end)
    local rows = {}
    for _, g0 in ipairs(c.groups) do
      local g = (a.surface == nil or g0.surface == a.surface) and (a.kind == nil or g0.kind == a.kind or g0.kind:sub(1, #a.kind + 1) == a.kind .. '.')
        and M.recheck(g0, p.force)
      if g then
        -- One group that fails to read is listed with why; the others still are.
        local ok, row = pcall(function()
          local to = {}
          for name, why in pairs(owners(g, who)) do to[#to+1] = name .. ' (' .. why .. ')' end
          table.sort(to)
          return {kind=g.kind, surface=g.surface, count=g.n, center=g.center, names=g.names, at=g.at, lost=g.lost,
            ore=g.ore, still_mining=g.still, untapped=g.untapped, drill_site=g.drill_site, observed_tick=g.observed_tick, checked_tick=g.checked_tick, stale=g.stale, line=M.text(g, here), to=#to > 0 and to or nil}
        end)
        rows[#rows+1] = ok and row or {kind=g.kind, surface=g.surface, count=g.n, line=string.format('%s on %s: this group could not be read (%s)', tostring(g.kind), tostring(g.surface), tostring(row))}
      end
    end
    return {groups=rows, scanned=string.format('%ds ago', math.floor((game.tick - c.tick) / 60)),
      note=#rows == 0 and 'no alerts or warnings' or nil}
  end
  M.schema = {
    game_alerts = {freshness='power/fuel entity groups recheck up to 128 recorded entities; hidden/capped observations are dated; belt_cut names missing formerly carrying tiles, cleared by observed replacements; out_of_ore includes drill_site, one representative drill placement cached 60 s and computed in background',surface='optional surface name', kind='optional kind (no_power, unconnected, low_power, no_fuel (its line adds the spoiling fuel of burners of those names around it: how many burn it, how many within 60 s, the first to spoil and when), burnt_full (burners stopped by a full burnt-result slot whatever their status reads, a biochamber whose spoiled nutrients fill it: each with what fills that slot and its fuel slot), no_ammo, flamer_dry; out_of_ore (mining drills whose patch under them is used up, by ore: out_of_ore.iron-ore, ...; each with ore, still_mining (our drills still mining that ore in the area) and untapped (the nearest patch of it no drill of ours is on, from the ores read\'s last survey: x, y, d tiles, amount));rebuilt_empty (turrets built with no ammo and still empty 60 s or more, each with its ammo request); lost_source and lost_target (inserters that had a pickup target and have none now, or whose drop target is gone; by what they feed: lost_source.boiler, .furnace, .lab, .assembler, else the entity type; each with lost: the inserter, what it read, what it puts into); per network: no_power.network (machines reporting no_power, grouped by electric network including small isolated networks, with its latest 5 s supply sample); power_high (draw at 85% of capacity or more for 2 min), boiler_fuel (boilers under 20 min of their own fuel at the draw with no fuel in their feeders\' hands or at their sources, again at 10 and 5; the fuel in chests and on belts within 64 tiles and what feeds them), feed_chest_low (a boiler\'s feed chest under 20 of its fuel with nothing put into it for 5 min: boiler, chest, count, feeder); robots_busy (no idle logistic robot for 10 min); accumulators_draining (a network\'s accumulators empty within 10 min at their net flow of the last 30 s, again under 5 and 2 min; kept 10 min after, so a Fulgora storm between lulls is not news; on Fulgora with the time to the next storm or to dawn); construction_wait (ghosts in a network\'s construction area waiting 5+ min since first seen while their items are in the network, with the construction robots and whether busy); deliveries_wait (requests unfilled 5+ min while providers or storage hold the item free, with what the logistic robots are doing); requester_full (requester chests with every slot taken while a request has been short 60+ s: per network, each chest, the item it asks and what fills its slots, spoilage counted); input_spoilage (assemblers and furnaces short of ingredients with spoilage their recipe does not take in their input: each machine, how much in how many slots); output_chest_full (a full_output maker whose output inserter puts into a chest with no free slot: the maker, the inserter, the chest and what fills its slots); catalyst_gone (a starved machine whose recipe takes an item it also makes, with none of it in its input: the item, what its output holds, and each inserter taking from it with its hand size);science_idle (a pack the research needs whose makers on the science surface all stood still at two science-line builds 5+ min apart, with their states and the chain\'s first short step); on Fulgora: lightning_unconnected (lightning attractors no pole reaches), lightning_unused (attractors in a network with no accumulator and nothing drawing power in the last minute), lightning_storage_full (a network with attractors whose accumulators are at 99% or more); or a game alert type such as no_material_for_construction, not_enough_construction_robots, not_enough_repair_packs, no_storage, train_out_of_fuel, unclaimed_cargo, collector_path_blocked)',
      returns='groups worst first: {kind, surface, count, center, names, at (up to 4 positions), line, to (who the team block tells: claim, built, nearest)}; scanned (the scan is at most 30 s old). What a player\'s alert panel and status icons show; new or worsening groups also come in team.alerts (one digest per 150 s). Read only'},
  }
  return M
end
