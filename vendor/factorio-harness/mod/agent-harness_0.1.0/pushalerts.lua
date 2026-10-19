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
    'asteroid-collector', 'lamp', 'loader', 'loader-1x1', 'cargo-landing-pad', 'car', 'spider-vehicle', 'reactor',
    'artillery-turret',
    -- (d17 territory part 4) read for coverage only: requester and buffer chests, ghosts
    'logistic-container', 'entity-ghost'}
  -- Kinds and how a line says them; game alert types not listed read as their name.
  local LABEL = {robots_lost='robots lost to enemies on their routes',line_cut='belt or pipe line cut',power_cut='machines cut off from power by a lost pole',no_power='no power', unconnected='not connected to power (no pole reaches them)', low_power='low power',
    no_fuel='out of fuel', no_ammo='out of ammo', flamer_dry='out of flamer oil', rebuilt_empty='rebuilt empty',
    burnt_full='stopped by a full burnt-result slot', output_full='drills stopped by a full chest they drop into', off_by_condition='stopped by their own circuit or logistic condition', captive_starving='captive spawners losing health', silo_spoils='staged cargo spoiling before its platform is back', captive_urgent='captive spawners dying within 2 min', captive_died='captive spawners died',
    no_material_for_construction='ghosts waiting for materials (no robot can bring them)',
    not_enough_construction_robots='not enough construction robots', not_enough_repair_packs='robots out of repair packs',
    no_storage='robots have no storage for what they carry', no_roboport_storage='no roboport storage',
    train_out_of_fuel='train out of fuel', train_no_path='train has no path', unclaimed_cargo='unclaimed cargo',
    collector_path_blocked='asteroid collector path blocked', pipeline_overextended='pipeline overextended (flow stops)',
    no_platform_storage='platform hub storage full', platform_tile_building_blocked='platform tile building blocked',
    input_spoilage='short of ingredients with spoilage in their input (their recipes do not take it)',
    seed_spoiling='not crafting while the seed in their input (pentapod eggs, bacteria) spoils within 3 min',
    output_chest_full='stopped: the chest their output goes into has no free slot',
    catalyst_gone='short of an ingredient their own recipe makes (none left in the input to start the next craft)',
    requester_full='requester chests with every slot taken while a request is short',
    mine_depleting='mines where half the drills stop within 30 min at the rate they take ore now',
    heat_no_fuel='heating towers out of fuel near their heat network\'s threshold (where it feeds heat exchangers, their working temperature from the prototype, 500 C; heating only, 30 C: under it a heater warms nothing)',
    outpost_ammo_low='turrets no construction robots reach, under 20% of their ammo slots',
    ammo_low='hand-fed turrets (no inserter drops into them) under 10 magazines',
    outpost_turret_lost='turrets no construction robots reached destroyed in the last 10 minutes',
    frozen='frozen (no heat reaches them)',
    artillery_empty='artillery turrets with no shell for 5 min or more'}
  local HINT = {no_power='fh call power', unconnected='fh call power', low_power='more power: fh call power', no_fuel='refuel', heat_no_fuel='refuel',
    no_ammo='rearm', ammo_low='rearm', flamer_dry='fh call flamers', no_material_for_construction='craft or bring the items for the ghosts',
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
  local RECHECK, MAX_UNITS = {no_ammo=true, rebuilt_empty=true, flamer_dry=true, ammo_low=true, artillery_empty=true}, 512
  -- (d17 batch22 C1, Haiku: hand-fed turrets found low only by polling, about every 20 minutes) a hand-fed ammo turret
  -- holding under AMMO_LOW magazines (rounds left in its stacks) is the kind ammo_low
  local AMMO_LOW = 10
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
    if #g.at < 8 then g.at[#g.at+1] = {x=math.floor(pos.x * 10 + 0.5) / 10, y=math.floor(pos.y * 10 + 0.5) / 10} end
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
    return g
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
  -- (d17 batch23 C1, Opus: artillery fed by an inserter from a requester chest asking shells, the chest empty for
  -- minutes, found only by looking) an artillery turret with no shell in it since ARTY_EMPTY ticks or more (the turret
  -- memory, by unit number): the piece, each inserter dropping into it with what it takes from (a requester or buffer
  -- chest: its shell request, what it holds, its network's shells and robots bringing), else hand-fed; an item request
  -- for shells on the piece.
  local ARTY_EMPTY, SHELL = 18000, 'artillery-shell'
  local function shell_feed(e)
    local parts = {}
    local p0 = e.position
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{area={{p0.x - 5, p0.y - 5}, {p0.x + 5, p0.y + 5}}, type='inserter', force=e.force, limit=32} end) or {}) do
      if i.valid and try(function() return i.drop_target end) == e and #parts < 3 then
        local src = try(function() return i.pickup_target end)
        local text = string.format('%s %s takes from %s', i.name, at_text(i.position), src and src.name .. ' ' .. at_text(src.position) or 'nothing')
        local pt = src and src.type == 'logistic-container' and try(function() return src.get_logistic_point(defines.logistic_member_index.logistic_container) end)
        if pt then
          local asks
          for _, f in ipairs(try(function() return pt.filters end) or {}) do
            local n = type(f.name) == 'string' and f.name or try(function() return f.name.name end)
            if n == SHELL then asks = (asks or 0) + (f.count or 0) end
          end
          local inv = try(function() return src.get_inventory(defines.inventory.chest) end)
          text = text .. string.format(' (%s, holds %d)', asks and 'asks ' .. asks .. ' ' .. SHELL or 'no request for ' .. SHELL,
            inv and try(function() return inv.get_item_count(SHELL) end) or 0)
          local ln = try(function() return pt.logistic_network end)
          local coming = 0
          for _, c in ipairs(try(function() return pt.targeted_items_deliver end) or {}) do
            local n = type(c.name) == 'string' and c.name or try(function() return c.name.name end)
            if n == SHELL then coming = coming + (c.count or 0) end
          end
          text = text .. (ln and string.format('; its logistic network holds %d %s (robots bringing %d)', try(function() return ln.get_item_count(SHELL) end) or 0, SHELL, coming)
            or '; in no logistic network')
        end
        parts[#parts+1] = text
      end
    end
    if #parts == 0 then parts[1] = 'no inserter drops into it' end
    local asks = try(function() local x = e.item_request_proxy; return x and x.item_requests end) or {}
    for _, r in ipairs(asks) do parts[#parts+1] = string.format('an item request for %d %s waits on it', r.count, r.name) end
    return table.concat(parts, '; ')
  end
  local function artillery_kind(e, mem)
    local inv = try(function() return e.get_inventory(defines.inventory.artillery_turret_ammo) end)
    local unit = inv and mem and try(function() return e.unit_number end)
    if not unit then return nil end
    local t = mem.units[unit]
    if not t then t = {}; mem.units[unit] = t end
    t.g = mem.gen
    if inv.get_item_count() > 0 then t.dry = nil; return nil end
    t.dry = t.dry or game.tick
    if game.tick - t.dry < ARTY_EMPTY then return nil end
    return 'artillery_empty', string.format('%s %s: empty for %d min; %s', e.name, at_text(e.position),
      math.floor((game.tick - t.dry) / 3600), shell_feed(e))
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
  -- A heating tower's heat network (batch27 A4, Astra board #975: an isolated Aquilo heating tower at 499 C, its network
  -- at 493 C and no heat exchanger on it, was told as out of fuel under 500 C): walked by heat connections (at most
  -- HEAT_PARTS), its coldest part and the heat exchangers on it. With exchangers the threshold is the highest working
  -- temperature of theirs (the prototype's min_working_temperature, 500 C); heating only, 30 C (heating.lua: a heater
  -- under 30 C warms nothing) with the cooling since the last read (push_heat, by unit number): told under 30 C or
  -- when that cooling reaches 30 C within HEAT_SOON minutes.
  local HEAT_PARTS, HEAT_FREEZE, HEAT_SOON = 512, 30, 10
  function M.heat_network(e)
    local seen, queue, head = {[e.unit_number or 0]=true}, {e}, 1
    local cold, exch, need = nil, 0, nil
    while head <= #queue and #queue <= HEAT_PARTS do
      local x = queue[head]; head = head + 1
      local t = try(function() return x.temperature end)
      local src = x.type == 'boiler' and try(function() return x.prototype.heat_energy_source_prototype end)
      if src then
        exch = exch + 1
        local w = try(function() return src.min_working_temperature end) or HEAT_WARN
        if not need or w > need then need = w end
      elseif t and (not cold or t < cold.t) then cold = {t=t, e=x} end
      for _, n in ipairs(try(function() return x.heat_neighbours end) or {}) do
        local u = n.unit_number or 0
        if n.valid and not seen[u] then seen[u] = true; queue[#queue+1] = n end
      end
    end
    return {parts=#queue, exchangers=exch, need=need, cold=cold}
  end
  local function heat_memory()
    local st = api.state()
    st.push_heat = st.push_heat or {}
    return st.push_heat
  end
  -- kind, detail (or nil) for a heating tower out of fuel at temp.
  function M.heat_alert(e, temp)
    local h = M.heat_network(e)
    local here = string.format('%s %s: %d C, fuel slot empty', e.name, at_text(e.position), math.floor(temp))
    if h.exchangers > 0 then
      if temp >= h.need then return nil end
      return 'heat_no_fuel', string.format('%s; its heat network feeds %d heat exchanger%s, which work at %d C and more', here, h.exchangers, h.exchangers == 1 and '' or 's', h.need)
    end
    local c = h.cold or {t=temp, e=e}
    local mem = heat_memory()
    local u = e.unit_number or 0
    local was = mem[u]
    mem[u] = {tick=game.tick, t=c.t}
    local rate = was and game.tick > was.tick and (was.t - c.t) * 3600 / (game.tick - was.tick) or nil
    local mins = rate and rate > 0 and (c.t - HEAT_FREEZE) / rate or nil
    if c.t >= HEAT_FREEZE and not (mins and mins <= HEAT_SOON) then return nil end
    return 'heat_no_fuel', string.format('%s; its heat network (%d part%s, no heat exchanger) coldest %d C at %s %s%s; under %d C a heater warms nothing',
      here, h.parts, h.parts == 1 and '' or 's', math.floor(c.t), c.e.name, at_text(c.e.position),
      c.t < HEAT_FREEZE and '' or string.format(', cooling %.1f C a minute: about %d min to %d C', rate, math.floor(mins + 0.5), HEAT_FREEZE), HEAT_FREEZE)
  end
  function M.heat_forget(e) local mem = api.state().push_heat; if mem then mem[e.unit_number or 0] = nil end end
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
  -- A rocket silo (A1, Sonnet 01:50: waits at the silo several times a shift): its rocket parts stalled for SILO_STALL
  -- ticks short of an ingredient (silo_short.<item>, with what the silo and its feeders hold; silo {position, why: true}
  -- follows the chain), or a built rocket not launched for SILO_IDLE ticks (silo_ready_idle, with its cargo and the
  -- platforms above). Per silo in storage (push_silos): when its part count last changed, when it became ready.
  local SILO_STALL, SILO_IDLE = 7200, 10800
  -- (d18 batch38 C4, Grok 18:20: about 200 agricultural packs were inside 5 minutes of spoiling after Petrel left) a
  -- spoilable item a platform's hub asks this planet for, staged in the silo's rocket or the chests of the silo's
  -- logistic network, that spoils before that platform's next arrival here (its schedule's ETA, api.platform_eta): how
  -- many, the first's time left, and where. Read at most every SPOIL_EVERY ticks a silo; bounded: 16 platforms, 32 chests
  -- an item, every slot of each.
  local SPOIL_EVERY, SPOIL_CHESTS = 1800, 32
  function M.silo_spoils(e, s, m)
    if not api.platform_eta then return nil end
    local planet = try(function() return s.planet and s.planet.name end) or s.name
    local wants = {}
    for i, pl in pairs(e.force.platforms) do
      if i > 16 then break end
      local here = try(function() return pl.space_location and pl.space_location.name end) == planet
      local secs = not here and pl.valid and pl.hub and try(function() return pl.hub.get_logistic_sections() end)
      for k = 1, secs and secs.sections_count or 0 do
        local sec = try(function() return secs.get_section(k) end)
        for _, f in ipairs(sec and sec.active ~= false and try(function() return sec.filters end) or {}) do
          local v = f.value
          local name = v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end))
          local from = f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end))
          if name and from == planet and (try(function() return prototypes.item[name].get_spoil_ticks() end) or 0) > 0 then
            wants[name] = wants[name] or {}
            table.insert(wants[name], pl)
          end
        end
      end
    end
    if not next(wants) then return nil end
    local ln = try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
    local lines = {}
    for name, pls in pairs(wants) do
      -- the soonest arrival of a platform that asks for it
      local eta, who
      for _, pl in ipairs(pls) do
        local t = try(function() return api.platform_eta(pl, planet) end)
        if t and (not eta or t < eta) then eta, who = t, pl.name end
      end
      if eta then
        local places = {}
        local invs = {}
        local rocket = try(function() return e.get_inventory(defines.inventory.rocket_silo_rocket) end)
        if rocket then invs[#invs+1] = {inv=rocket, where='the silo\'s rocket'} end
        local chests = 0
        for _, list in ipairs({ln and try(function() return ln.storages end) or {}, ln and try(function() return ln.providers end) or {}}) do
          for _, c in ipairs(list) do
            if chests >= SPOIL_CHESTS then break end
            if c.valid and c.type ~= 'roboport' and (try(function() return c.get_item_count(name) end) or 0) > 0 then
              chests = chests + 1
              local inv = try(function() return c.get_inventory(defines.inventory.chest) end) or try(function() return c.get_output_inventory() end)
              if inv then invs[#invs+1] = {inv=inv, where=string.format('%s %s', c.name, at_text(c.position))} end
            end
          end
        end
        local n, first, at_first = 0, nil, nil
        local soon = game.tick + eta * 60
        for _, x in ipairs(invs) do
          for i = 1, #x.inv do
            local st = x.inv[i]
            if st.valid_for_read and st.name == name then
              local t = try(function() return st.spoil_tick end)
              if t and t > 0 and t < soon then
                n = n + st.count
                places[x.where] = (places[x.where] or 0) + st.count
                if not first or t < first then first, at_first = t, x.where end
              end
            end
          end
        end
        if n > 0 then
          local where = {}
          for k, c in pairs(places) do where[#where+1] = k .. ' ' .. c end
          table.sort(where)
          lines[#lines+1] = string.format('%d %s staged for %s (its hub asks %s for it) spoil before its next arrival here in about %ds: the first in %ds (%s); in %s',
            n, name, who, planet, math.floor(eta + 0.5), math.floor((first - game.tick) / 60), at_first, table.concat(where, ', ', 1, math.min(4, #where)))
        end
      end
    end
    if #lines == 0 then return nil end
    table.sort(lines)
    return 'silo_spoils', string.format('%s %s: %s', e.name, at_text(e.position), table.concat(lines, '; '))
  end
  local function silo_state(e, s)
    local st = api.state()
    st.push_silos = st.push_silos or {}
    local unit = e.unit_number
    local m = st.push_silos[unit] or {}
    st.push_silos[unit] = m
    local ready = try(function() return e.rocket_silo_status == defines.rocket_silo_status.rocket_ready end)
    local parts = try(function() return e.rocket_parts end) or 0
    if m.parts ~= parts then m.parts, m.since = parts, game.tick end
    -- (d17 batch23 B3) rocket parts made, sampled for silo's rate
    if api.silo_sample then pcall(api.silo_sample, e) end
    if ready then m.ready = m.ready or game.tick else m.ready = nil end
    -- (C4) staged cargo spoiling before its platform is back comes first, read at most every SPOIL_EVERY ticks
    if not m.spoil_t or game.tick - m.spoil_t >= SPOIL_EVERY then
      m.spoil_t = game.tick
      local ok, k, d = pcall(M.silo_spoils, e, s, m)
      m.spoil = ok and k and {k, d} or nil
    end
    if m.spoil then return m.spoil[1], m.spoil[2] end
    if ready and game.tick - m.ready >= SILO_IDLE then
      local inv = try(function() return e.get_inventory(defines.inventory.rocket_silo_rocket) end)
      local held = {}
      for _, c in ipairs(inv and try(function() return inv.get_contents() end) or {}) do if #held < 4 then held[#held+1] = c.name .. '*' .. c.count end end
      local above = {}
      local planet = try(function() return s.planet and s.planet.name end) or s.name
      for _, pl in pairs(e.force.platforms) do
        if pl.valid and try(function() return pl.space_location and pl.space_location.name end) == planet then above[#above+1] = pl.name end
      end
      table.sort(above)
      return 'silo_ready_idle', string.format('%s %s: rocket ready %d min, not launched; cargo %s; platforms above: %s', e.name, at_text(e.position),
        math.floor((game.tick - m.ready) / 3600), #held > 0 and table.concat(held, ' ') or 'none', #above > 0 and table.concat(above, ', ') or 'none')
    end
    if not ready and e.status == defines.entity_status.item_ingredient_shortage and game.tick - (m.since or game.tick) >= SILO_STALL then
      local recipe = try(function() return e.get_recipe() end)
      local input = try(function() return e.get_inventory(defines.inventory.crafter_input or defines.inventory.assembling_machine_input) end)
      for _, ing in ipairs(recipe and recipe.ingredients or {}) do
        local have = input and try(function() return input.get_item_count(ing.name) end) or 0
        if ing.type == 'item' and have < (ing.amount or 1) then
          local required = try(function() return e.prototype.rocket_parts_required end) or 0
          return 'silo_short.' .. ing.name, string.format('%s %s: parts %d/%d, no new part for %d min; short of %s (%d in it); silo {position, why: true} follows it',
            e.name, at_text(e.position), parts, required, math.floor((game.tick - m.since) / 3600), ing.name, have)
        end
      end
    end
  end
  -- A starving captive spawner (d17 batch18 C6, viewer Foobator; game data, space-age entities.lua): a
  -- captive-biter-spawner has 350 health; production_health_effect not_producing -1/60 a tick (1 HP a second while it
  -- makes nothing: unfed or output blocked), producing +1/60; its dying_trigger_effect creates a hostile biter-spawner in
  -- its place (as_enemy, protected; read on the copy). Not producing: where, its health, minutes until it dies at that
  -- rate, and why (its fuel slot empty, with what it burns; output full; else its status); under CAPTIVE_URGENT seconds
  -- its own kind (captive_urgent), told at once. Its builder and the builders of the inserters feeding it hear it.
  local CAPTIVE, CAPTIVE_LOSS, CAPTIVE_URGENT = 'captive-biter-spawner', 1, 120
  local CAPTIVE_FUELS
  local function captive_fuels(e)
    if not CAPTIVE_FUELS then
      CAPTIVE_FUELS = {}
      local cats = try(function() return e.prototype.burner_prototype.fuel_categories end) or {}
      for name, it in pairs(prototypes.item) do
        local cat = try(function() return it.fuel_category end)
        if cat and cats[cat] then CAPTIVE_FUELS[#CAPTIVE_FUELS+1] = name end
      end
      table.sort(CAPTIVE_FUELS)
    end
    return CAPTIVE_FUELS
  end
  function M.captive(e)
    if not (e and e.valid and e.name == CAPTIVE) then return nil end
    local st = defines.entity_status or {}
    local status = try(function() return e.status end)
    if status == st.working then return nil end
    local hp, max = e.health or 0, try(function() return e.max_health end) or 350
    local secs = hp / CAPTIVE_LOSS
    local why
    local fuel = try(function() return e.get_fuel_inventory() end)
    local left = try(function() return e.burner.remaining_burning_fuel end) or 0
    if fuel and try(function() return fuel.is_empty() end) and left <= 0 then
      local f = captive_fuels(e)
      why = 'its fuel slot is empty' .. (#f > 0 and ' (it burns ' .. table.concat(f, ', ', 1, math.min(3, #f)) .. ')' or '')
    elseif FULL[status] then
      local parts = {}
      for _, x in ipairs(try(function() return e.get_output_inventory().get_contents() end) or {}) do parts[#parts+1] = x.count .. ' ' .. x.name end
      why = 'its output is full' .. (#parts > 0 and ' (' .. table.concat(parts, ', ') .. ')' or '')
    else
      for k, v in pairs(st) do if v == status then why = 'its status is ' .. k end end
    end
    local text = string.format('%s %s: health %d/%d, not producing (%s); it loses %d HP a second while it makes nothing, so it dies in about %.1f min, and a hostile biter-spawner takes its place',
      e.name, at_text(e.position), math.floor(hp), math.floor(max), why or 'not working', CAPTIVE_LOSS, secs / 60)
    return secs < CAPTIVE_URGENT and 'captive_urgent' or 'captive_starving', text
  end
  local function feeder_builders(e)
    local out = {}
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{position=e.position, radius=4, type='inserter', force=e.force, limit=32} end) or {}) do
      if try(function() return i.drop_target == e end) then local b = builder(i); if b then out[#out+1] = b end end
    end
    return out
  end
  -- A machine whose recipe keeps a seed going (batch26 B3, Grok: a biochamber holding eggs or copper bacteria that stops
  -- crafting loses the seed when it spoils or hatches): not working, with that seed in its input spoiling within
  -- SEED_SOON ticks: the first to spoil, when, and why it is not crafting (its status; a short ingredient named).
  local SEEDS, SEED_SOON = {['pentapod-egg']=true, ['copper-bacteria']=true, ['iron-bacteria']=true}, 10800
  local STATUS_NAMES
  local function status_of(e)
    if not STATUS_NAMES then
      STATUS_NAMES = {}
      for k, v in pairs(defines.entity_status or {}) do STATUS_NAMES[v] = k end
    end
    local st = try(function() return e.status end)
    return st, STATUS_NAMES[st] or tostring(st)
  end
  function M.seed_spoiling(e)
    local recipe = try(function() return e.get_recipe() end)
    if not recipe then return nil end
    local seed
    for _, ing in ipairs(recipe.ingredients or {}) do if SEEDS[ing.name] then seed = ing.name end end
    if not seed then return nil end
    local st, sname = status_of(e)
    if st == (defines.entity_status or {}).working then return nil end
    local inv = try(function() return e.get_inventory(defines.inventory.crafter_input or defines.inventory.assembling_machine_input) end)
    if not inv then return nil end
    local first, held = nil, 0
    for i = 1, #inv do
      local stck = inv[i]
      if stck.valid_for_read and stck.name == seed then
        held = held + stck.count
        local t = try(function() return stck.spoil_tick end)
        if t and t > 0 and (not first or t < first) then first = t end
      end
    end
    if not first or first - game.tick > SEED_SOON then return nil end
    local why = sname
    if sname == 'item_ingredient_shortage' or sname == 'no_ingredients' then
      for _, ing in ipairs(recipe.ingredients or {}) do
        if ing.type ~= 'fluid' and (try(function() return inv.get_item_count(ing.name) end) or 0) < (ing.amount or 1) then
          why = string.format('%s (%s %d of %d)', sname, ing.name, try(function() return inv.get_item_count(ing.name) end) or 0, ing.amount or 1); break
        end
      end
    end
    local left = math.max(0, math.floor((first - game.tick) / 60))
    return string.format('%s %s holds %s %d: the first %s in %dm%02ds; not crafting: %s', e.name, at_text(e.position), seed, held,
      seed == 'pentapod-egg' and 'hatches' or 'spoils', math.floor(left / 60), left % 60, why)
  end
  -- A captive spawner of ours that died (the runtime's on_entity_died): kept CAPTIVE_KEEP ticks, its group naming what
  -- stands in its place now.
  local CAPTIVE_KEEP = 36000
  function M.captive_died(e)
    if not (e and e.valid and e.name == CAPTIVE) then return end
    local s = api.state()
    s.push_captive = s.push_captive or {}
    local by = {}
    local b = builder(e); if b then by[#by+1] = b end
    for _, x in ipairs(feeder_builders(e)) do by[#by+1] = x end
    table.insert(s.push_captive, {tick=game.tick, force=e.force.name, surface=e.surface.name, position={x=e.position.x, y=e.position.y}, by=by})
    while #s.push_captive > 32 do table.remove(s.push_captive, 1) end
  end
  -- A machine its own circuit or logistic condition stops (d17 batch18 B2, Grok: the agricultural science biochamber
  -- stopped when the network's bioflux fell under 200): each unmet condition as its GUI shows it, with the value its
  -- first signal reads now (on its wires, or in the logistic network over it). A machine whose unmet conditions are all
  -- on what its recipe makes (a stock cap: the network holds enough of it) is not said.
  local OFF_TYPES = {['assembling-machine']=true, furnace=true, lab=true, ['mining-drill']=true, ['rocket-silo']=true}
  local function off_text(e)
    local cb = e.get_control_behavior()
    if not cb then return nil end
    local makes = {}
    local r = try(function() return e.get_recipe() end) or try(function() return e.previous_recipe end)
    local rname = r and (type(r.name) == 'string' and r.name or r.name and r.name.name)
    for _, pr in ipairs(rname and try(function() return prototypes.recipe[rname].products end) or {}) do makes[pr.name] = true end
    local parts, other = {}, false
    for _, k in ipairs({{'circuit_enable_disable', 'circuit_condition', 'circuit'}, {'connect_to_logistic_network', 'logistic_condition', 'logistic'}}) do
      local c = try(function() return cb[k[1]] end) and try(function() return cb[k[2]] end)
      if c and c.fulfilled == false then
        local first = c.first_signal
        if not (first and makes[first.name]) then other = true end
        -- the value its first signal reads now: on its red and green wires, or in the logistic network over it
        local v
        if first and first.name and k[3] == 'circuit' then
          for _, w in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
            local net = try(function() return e.get_circuit_network(w) end)
            if net then v = (v or 0) + (try(function() return net.get_signal(first) end) or 0) end
          end
        elseif first and first.name and (first.type == nil or first.type == 'item') then
          local ln = try(function() return e.surface.find_logistic_network_by_position(e.position, e.force) end)
          v = ln and (try(function() return ln.get_item_count(first.name) end) or 0)
        end
        local text = api.condition_text and try(function() return api.condition_text(c) end) or (first and first.name or 'blank')
        parts[#parts+1] = string.format('%s condition %s%s', k[3], text, v and (k[3] == 'logistic' and v < 0 and api.negative_note
          and (try(function() return api.negative_note(first.name, v) end) or '') or string.format(' (%s %d now)', first.name, v)) or '')
      end
    end
    if not other then return nil end
    return string.format('%s %s%s: off by its %s', e.name, at_text(e.position), rname and ' (' .. rname .. ')' or '', table.concat(parts, ' and '))
  end
  -- A drill stopped by a full chest it drops into (d17 territory addition, Nick 17:15: Vulcanus calcite drills stopped
  -- waiting for space in full iron chests; the game has no alert for it): status waiting_for_space_in_destination and
  -- its drop target a chest (a backed-up belt is often by design and not said). The drill, what it mines, the chest and
  -- its fill (slots used of all, the items in the most slots).
  local DROP_CHEST = {container=true, ['logistic-container']=true, ['linked-container']=true, ['infinity-container']=true}
  local function drill_full(e)
    local st = defines.entity_status or {}
    if not st.waiting_for_space_in_destination or e.status ~= st.waiting_for_space_in_destination then return nil end
    local c = e.drop_target
    if not (c and c.valid and DROP_CHEST[c.type]) then return nil end
    local inv = c.get_inventory(defines.inventory.chest)
    local used = inv and #inv - inv.count_empty_stacks() or 0
    local parts = {}
    local list = inv and inv.get_contents() or {}
    table.sort(list, function(a, b) return a.count > b.count end)
    for i = 1, math.min(2, #list) do parts[i] = list[i].name .. ' ' .. list[i].count end
    local ore = try(function() return e.mining_target and e.mining_target.name end)
    return string.format('%s %s%s into %s %s: %d/%d slots used%s', e.name, at_text(e.position), ore and ' mining ' .. ore or '', c.name, at_text(c.position),
      used, inv and #inv or 0, #parts > 0 and ' (' .. table.concat(parts, ', ') .. ')' or '')
  end
  M.drill_full = drill_full
  -- Out of radar sight (d17 territory addition, Nick 17:22: remote view, inspect, configure and scan by remote view need
  -- chunks our force sees now; on n 40 of Vulcanus' 98 drills stood in unseen chunks, two radars had no power, Aquilo
  -- has none): while the read walks our entities, per surface and 64-tile cell the drills, machines and turrets in a
  -- chunk no force of players sees now, and every radar with its status. Kept in the read's side table
  -- (mining.__sight), with the result.
  local SIGHT_KIND = {['mining-drill']='drills', ['assembling-machine']='machines', furnace='machines', lab='machines', ['rocket-silo']='machines',
    ['agricultural-tower']='machines', ['ammo-turret']='turrets', ['electric-turret']='turrets', ['fluid-turret']='turrets'}
  -- (is_chunk_visible took about 0.18 ms a chunk on the copy: at most VIS_STEP a slice of the read; past it, the previous
  -- read's answer for that chunk (storage push_vis), else the entity is counted unread)
  local VIS_STEP = 16
  -- Coverage (d17 territory part 4, Nick 17:33: nothing reported standing buildings outside coverage): what lies
  -- outside every roboport's construction area (robots neither build those ghosts nor repair or rebuild those
  -- buildings), per surface and 64-tile cell by name, ghosts apart; and requester and buffer chests outside every
  -- logistic area (their requests never fill). On the copy: 2 us an entity for the area query, 5 us a logistic chest.
  local COVER_ONLY, COVER_DONE, NOT_BUILDING = {['logistic-container']=true, ['entity-ghost']=true}, {valid=false}, {car=true, ['spider-vehicle']=true}
  local function cover_note(sight, s, e)
    if e.type == 'logistic-container' then
      local mode = try(function() return e.prototype.logistic_mode end)
      if (mode == 'requester' or mode == 'buffer') and not try(function() return e.logistic_network end) then
        local list = sight.chests[s.name] or {}; sight.chests[s.name] = list
        list.n = (list.n or 0) + 1
        if #list < 16 then list[#list+1] = {name=e.name, x=e.position.x, y=e.position.y} end
      end
      return
    end
    if NOT_BUILDING[e.type] then return end
    local nets = try(function() return s.find_logistic_networks_by_construction_area(e.position, e.force) end)
    if not nets or #nets > 0 then return end
    local key = s.name .. '|' .. math.floor(e.position.x / CELL) .. ',' .. math.floor(e.position.y / CELL)
    local c = sight.cover[key]
    if not c then c = {surface=s.name, n=0, ghosts=0, sx=0, sy=0, names={}}; sight.cover[key] = c end
    local ghost = e.type == 'entity-ghost'
    local name = ghost and e.ghost_name or e.name
    c.n = c.n + 1; c.sx = c.sx + e.position.x; c.sy = c.sy + e.position.y
    if ghost then c.ghosts = c.ghosts + 1; name = 'ghost of ' .. name end
    c.names[name] = (c.names[name] or 0) + 1
  end
  local function sight_note(mining, s, e)
    if not mining then return end
    local sight = mining.__sight
    if not sight then sight = {vis={}, cells={}, radars={}, unread=0, budget=VIS_STEP}; mining.__sight = sight end
    sight.cover = sight.cover or {}; sight.chests = sight.chests or {}
    pcall(cover_note, sight, s, e)
    if COVER_ONLY[e.type] then return end
    if e.type == 'radar' then
      local list = sight.radars[s.name] or {}
      sight.radars[s.name] = list
      if #list < 256 then list[#list+1] = {x=e.position.x, y=e.position.y, status=e.status} end
      return
    end
    local kind = SIGHT_KIND[e.type]
    if not kind then return end
    local cx, cy = math.floor(e.position.x / 32), math.floor(e.position.y / 32)
    local ck = s.name .. '|' .. cx .. ',' .. cy
    local seen = sight.vis[ck]
    if seen == nil then
      if (sight.budget or 0) > 0 then
        sight.budget = sight.budget - 1
        seen = try(function() return e.force.is_chunk_visible(s, {x=cx, y=cy}) end) or false; sight.vis[ck] = seen
      else
        local prev = (api.state().push_vis or {})[e.force.name]
        seen = prev and prev[ck]
        if seen == nil then sight.unread = (sight.unread or 0) + 1; return end
      end
    end
    if seen then return end
    local key = s.name .. '|' .. math.floor(e.position.x / CELL) .. ',' .. math.floor(e.position.y / CELL)
    local c = sight.cells[key]
    if not c then c = {surface=s.name, drills=0, machines=0, turrets=0, n=0, sx=0, sy=0}; sight.cells[key] = c end
    c[kind] = c[kind] + 1; c.n = c.n + 1; c.sx = c.sx + e.position.x; c.sy = c.sy + e.position.y
  end
  local function read_list(groups, s, list, from, to, mem, tmem, mining, dmem)
    if mining and mining.__sight then mining.__sight.budget = VIS_STEP end
    local st = statuses()
    for i = from or 1, to or #list do
      local e = list[i]
      if e.valid then pcall(sight_note, mining, s, e) end
      if e.valid and COVER_ONLY[e.type] then e = COVER_DONE end
      if e.valid and mem and e.type == 'inserter' then watch_inserter(groups, s, e, mem) end
      if e.valid then pcall(spoiling, e, s, mining) end
      if e.valid then
        local kind = st[e.status]
        local detail, feeders
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
          if not kind then
            local full = try(function() return drill_full(e) end)
            if full then kind, detail = 'output_full', full end
          end
        elseif kind == 'out_of_ore' then kind = nil end
        if e.type == 'ammo-turret' then
          local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
          local tk, td = turret_kind(e, inv and inv.get_item_count() == 0, tmem)
          if tk then kind, detail = tk, td
          else
            -- Under 20% of its ammo slots where no construction robot reaches (Opus, d15 15:20: the south copper
            -- outpost 550 tiles out, cut 5+ times a shift).
            local low = M.outpost_low(e, inv)
            if low then kind, detail = 'outpost_ammo_low', low
            else
              local n = inv and inv.get_item_count() or 0
              if n > 0 and n < AMMO_LOW and not M.inserter_fed(e) then
                local items = {}
                for _, c in ipairs(try(function() return inv.get_contents() end) or {}) do items[#items+1] = c.name .. ' ' .. c.count end
                kind, detail = 'ammo_low', string.format('%s %s: %s', e.name, at_text(e.position), table.concat(items, ', '))
              end
            end
          end
        elseif e.type == 'artillery-turret' then
          local ak, ad = artillery_kind(e, tmem)
          if ak then kind, detail, feeders = ak, ad, feeder_builders(e) end
        elseif e.type == 'reactor' and e.burner then
          -- Heating towers (Gemini, d15 07:54: a dedicated warning when they run out of fuel): a burner reactor with an
          -- empty fuel slot and nothing burning, under HEAT_WARN C; one still hotter is not said (feeds gated by its
          -- temperature empty its slot by design).
          local inv = try(function() return e.burner.inventory end)
          local empty = inv and try(function() return inv.is_empty() end)
          local burning = try(function() return e.burner.currently_burning end)
          local left = try(function() return e.burner.remaining_burning_fuel end) or 0
          local temp = try(function() return e.temperature end)
          if empty and not burning and left <= 0 and temp then
            local hk, hd = M.heat_alert(e, temp)
            if hk then kind, detail = hk, hd
            elseif kind == 'no_fuel' then kind = nil end
          else pcall(M.heat_forget, e) end
        elseif e.type == 'rocket-silo' then
          local sk, sd = silo_state(e, s)
          if sk then kind, detail = sk, sd end
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
        if e.name == CAPTIVE then
          local ck, cd = M.captive(e)
          if ck then kind, detail, feeders = ck, cd, feeder_builders(e) end
        end
        if not kind and OFF_TYPES[e.type] and try(function() return e.status end) == (defines.entity_status or {}).disabled_by_control_behavior then
          local off = try(function() return off_text(e) end)
          if off then kind, detail = 'off_by_condition', off end
        end
        -- (B3) a seed about to spoil in a machine not crafting comes before the other machine kinds
        if e.type == 'assembling-machine' and (kind == nil or kind == 'input_spoilage' or kind == 'catalyst_gone' or kind == 'off_by_condition' or kind == 'no_power' or kind == 'low_power') then
          local sd = try(function() return M.seed_spoiling(e) end)
          if sd then kind, detail, feeders = 'seed_spoiling', sd, feeder_builders(e) end
        end
        if kind then
          local g = add(groups, kind, s.name, e, e.position, e.name, builder(e), detail)
          for _, b in ipairs(feeders or {}) do g.by[b] = (g.by[b] or 0) + 1 end
        end
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
  -- Frozen entities (d17 frozen, Nick 17:18: "Do they easily see when buildings/transport belts are frozen? I see some
  -- frozen belts that have been frozen a long time on Aquilo"; on world n 70 belts and 8 pipes): on a planet whose
  -- entities require heating, a stage of the background read finds ours there once (Aquilo's 873: 1.2 ms on n) and
  -- reads FROZEN_SLICE a step for LuaEntity.frozen. Each frozen entity goes into its CELL group of kind frozen; when it
  -- was first seen frozen is kept (push_frozen, by unit number, dropped once it thaws or goes). The line: pipes and
  -- machines first, each with what it holds (the fluid or items it carried), then the belts as one run with what they
  -- carry, how long the oldest has been frozen, and the nearest heater (heat pipe, reactor, heating tower) within
  -- HEATER_R tiles with its temperature (30 C or more heats a neighbour: heating.lua).
  local FROZEN_SLICE, HEATER_R, FROZEN_SHOW = 400, 32, 4
  local STRIKE_SLICE = 400  -- buildings a step for lightning protection (on the copy about 5 us each)
  local function needs_heating(surface)
    return try(function() return surface.planet and surface.planet.prototype.entities_require_heating end) == true
  end
  local function frozen_memory(force)
    local st = api.state()
    st.push_frozen = st.push_frozen or {}
    st.push_frozen[force.name] = st.push_frozen[force.name] or {}
    return st.push_frozen[force.name]
  end
  local function ago_text(t)
    local m = math.floor(t / 3600)
    return m >= 60 and string.format('%dh%02dm', math.floor(m / 60), m % 60) or m .. 'm'
  end
  local function holds_of(e)
    if e.type == 'pipe' or e.type == 'pipe-to-ground' or e.type == 'storage-tank' or e.type == 'pump' then
      local f = try(function() return e.fluidbox[1] end)
      return f and string.format('%s %d', f.name, math.floor(f.amount + 0.5)) or 'empty'
    end
    local items = {}
    for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do
      for _, c in ipairs(try(function() return e.get_transport_line(i).get_contents() end) or {}) do items[c.name] = (items[c.name] or 0) + c.count end
    end
    local parts = {}
    for n, c in pairs(items) do parts[#parts+1] = n .. ' ' .. c end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ', ') or nil
  end
  local BELT_TYPES = {['transport-belt']=true, ['underground-belt']=true, splitter=true}
  -- What can freeze (the types a planet that requires heating stops: belts, pipes, machines, inserters, turrets, ...).
  local FREEZE_TYPES = {'transport-belt', 'underground-belt', 'splitter', 'loader', 'loader-1x1', 'pipe', 'pipe-to-ground', 'pump',
    'storage-tank', 'inserter', 'assembling-machine', 'furnace', 'mining-drill', 'lab', 'boiler', 'generator', 'offshore-pump',
    'ammo-turret', 'electric-turret', 'fluid-turret', 'radar', 'roboport', 'beacon', 'lamp', 'agricultural-tower', 'rocket-silo',
    'cargo-landing-pad', 'fusion-reactor', 'fusion-generator', 'train-stop', 'locomotive', 'cargo-wagon', 'fluid-wagon', 'arithmetic-combinator',
    'decider-combinator', 'constant-combinator', 'selector-combinator', 'power-switch', 'programmable-speaker'}
  local function freezable(s, force)
    return try(function() return s.find_entities_filtered{force=force, type=FREEZE_TYPES, limit=MAX_SCAN} end) or {}
  end
  -- A frozen entity read: into its cell's record (job.frozen[surface][cell]).
  local function frozen_read(job, s, e, mem, seen, tick)
    if not (e.valid and try(function() return e.frozen end)) then return end
    local unit = e.unit_number
    if unit then seen[unit] = true; mem[unit] = mem[unit] or tick end
    local cx, cy = math.floor(e.position.x / CELL), math.floor(e.position.y / CELL)
    local cells = job.frozen
    local c = cells[cx .. ',' .. cy]
    if not c then c = {others={}, belts={n=0, items={}}, first=tick}; cells[cx .. ',' .. cy] = c end
    c.first = math.min(c.first, unit and mem[unit] or tick)
    c.ents = (c.ents or 0) + 1
    if BELT_TYPES[e.type] then
      local b = c.belts
      b.n = b.n + 1
      b.x0, b.y0 = math.min(b.x0 or e.position.x, e.position.x), math.min(b.y0 or e.position.y, e.position.y)
      b.x1, b.y1 = math.max(b.x1 or e.position.x, e.position.x), math.max(b.y1 or e.position.y, e.position.y)
      b.name = b.name or e.name
      local h = holds_of(e)
      if h then b.items[#b.items+1] = h end
    else
      c.others[#c.others+1] = {name=e.name, position={x=e.position.x, y=e.position.y}, holds=holds_of(e)}
    end
    c.list = c.list or {}
    if #c.list < 256 then c.list[#c.list+1] = e end
  end
  -- The cells read: groups with their lines.
  local function frozen_groups(job, s, force, tick)
    for _, c in pairs(job.frozen) do
      local first
      for _, e in ipairs(c.list or {}) do
        if e.valid then
          add(job.groups, 'frozen', s.name, e, e.position, e.name, builder(e), nil)
          first = first or e
        end
      end
      local g = first and job.groups['frozen|' .. s.name .. '|' .. math.floor(first.position.x / CELL) .. ',' .. math.floor(first.position.y / CELL)]
      if g then
        centred(g)
        local parts = {}
        table.sort(c.others, function(a, b) return a.name < b.name end)
        for i, o in ipairs(c.others) do
          if i <= FROZEN_SHOW then parts[#parts+1] = string.format('%s %s%s', o.name, at_text(o.position), o.holds and ' holding ' .. o.holds or '') end
        end
        if #c.others > FROZEN_SHOW then parts[#parts+1] = string.format('+%d more', #c.others - FROZEN_SHOW) end
        local b = c.belts
        if b.n > 0 then
          parts[#parts+1] = string.format('%d %s from %s to %s, %s', b.n, b.name, at_text({x=b.x0, y=b.y0}), at_text({x=b.x1, y=b.y1}),
            #b.items > 0 and 'carrying ' .. table.concat(b.items, ', ', 1, math.min(3, #b.items)) or 'empty')
        end
        -- (the nearest to any of the frozen ones: on world n hot heat pipes stood 2 tiles from frozen belts they did not
        -- touch, and a heater warms only what touches it)
        local heater, hd, by
        for _, h in ipairs(try(function() return s.find_entities_filtered{position=g.center, radius=HEATER_R, type={'heat-pipe', 'reactor'}, force=force, limit=64} end) or {}) do
          for _, e in ipairs(c.list or {}) do
            if e.valid then
              local d = (h.position.x - e.position.x) ^ 2 + (h.position.y - e.position.y) ^ 2
              if not hd or d < hd then heater, hd, by = h, d, e end
            end
          end
        end
        local htext
        if heater then
          local temp = try(function() return heater.temperature end) or 0
          htext = string.format('nearest heater %s %s %d C, %d tiles from %s %s%s; a heater warms only what touches it (a side or a corner)', heater.name,
            at_text(heater.position), math.floor(temp), math.floor(math.sqrt(hd) + 0.5), by.name, at_text(by.position), temp < 30 and ' (under 30 C: it heats nothing)' or '')
        else htext = string.format('no heater (heat pipe, reactor, heating tower) of ours within %d tiles', HEATER_R) end
        g.line = string.format('%d frozen near %s: %s; frozen at least %s; %s', g.n, string.format('(%d,%d)', g.center.x, g.center.y),
          table.concat(parts, '; '), ago_text(tick - c.first), htext)
      end
    end
  end
  -- Thawed ones forgotten (those of list not frozen now); a memory past 8192 drops what this read did not see.
  local function frozen_forget(mem, list, seen)
    for _, e in ipairs(list) do if e.valid and e.unit_number and not seen[e.unit_number] then mem[e.unit_number] = nil end end
    local n = 0
    for _ in pairs(mem) do n = n + 1 end
    if n > 8192 then for unit in pairs(mem) do if not seen[unit] then mem[unit] = nil end end end
  end
  -- One planet at once (the synchronous scan).
  local function frozen_all(groups, s, force, tick)
    local job, mem = {groups=groups, frozen={}}, frozen_memory(force)
    local seen, list = {}, freezable(s, force)
    for _, e in ipairs(list) do pcall(frozen_read, job, s, e, mem, seen, tick) end
    pcall(frozen_groups, job, s, force, tick)
    frozen_forget(mem, list, seen)
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
        for _, pos in ipairs(g.at) do if #h.at < 8 then h.at[#h.at+1] = pos end end
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
  -- Mines running out (batch27 B5, Sonnet: coal fell to 3 of 56 drills working with no warning): the patches the ores
  -- read's last survey has our drills on (a copy each, for the job), one forecast a background step (ores.forecast);
  -- half the drills stopping within MINE_HORIZON minutes is a mine_depleting group to their builders.
  local MINE_HORIZON, MINE_MAX, MINE_DRILLS = 30, 64, 32
  local function mine_patches(force)
    local out = {}
    for _, entry in pairs(api.state().ores or {}) do
      local s = entry.force == force.name and game.surfaces[entry.surface]
      for _, q in ipairs(s and entry.patches or {}) do
        if (q.miners or 0) > 0 and not q.yield and not q.fluid and q.l and #out < MINE_MAX then
          out[#out+1] = {surface=s.name, name=q.name, l=q.l, t=q.t, r=q.r, b=q.b, centre=q.centre}
        end
      end
    end
    return out
  end
  local function mine_group(force, m)
    local s = game.surfaces[m.surface]
    local f = s and api.mine_forecast and api.mine_forecast(s, force, m, MINE_DRILLS)
    if not (f and f.half_min and f.half_min <= MINE_HORIZON) then return nil end
    local by, names = {}, {}
    for _, e in ipairs(f.entities or {}) do
      local b = builder(e)
      if b then by[b] = (by[b] or 0) + 1 end
      names[e.name] = (names[e.name] or 0) + 1
    end
    local u = try(function() return untapped(force.name, m.surface, m.name, m.centre) end)
    local terr = u and api.territory and try(function() return api.territory(s, force, {x=u.x, y=u.y}) end)
    local cx, cy = math.floor(m.centre.x / CELL), math.floor(m.centre.y / CELL)
    return {key='mine_depleting|' .. m.surface .. '|' .. cx .. ',' .. cy, kind='mine_depleting', surface=m.surface, n=f.drills, names=names, by=by, at={},
      center={x=math.floor(m.centre.x + 0.5), y=math.floor(m.centre.y + 0.5)}, observed_tick=game.tick,
      line=string.format('mine running out near (%d,%d): %s%s', math.floor(m.centre.x + 0.5), math.floor(m.centre.y + 0.5), f.line,
        u and string.format('; nearest untapped %s (%d,%d) %d tiles, about %d%s', m.name, u.x, u.y, u.d, math.floor(u.amount or 0), terr and ', ' .. terr or '') or '; no untapped patch of it in the survey')}
  end
  M.mine_patches, M.mine_group = mine_patches, mine_group
  local function merge(groups, extra, mining, force)
    name_unknown_ore(groups, mining)
    -- Cells of one kind on one surface that touch (8 neighbours) are one area:
    -- a turret line across a cell edge is one group. Its key is its first cell.
    local out, done = {}, {}
    local cells = {}
    for key, g in pairs(groups) do cells[#cells+1] = key end
    table.sort(cells)
    for _, key in ipairs(cells) do
      -- (frozen: a cell each, its own line)
      if not done[key] and groups[key].kind == 'frozen' then done[key] = true; out[#out+1] = centred(groups[key]) end
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
          for _, pos in ipairs(part.at) do if #area.at < 8 then area.at[#area.at+1] = pos end end
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
    for _, s in ipairs(planets()) do if needs_heating(s) then frozen_all(groups, s, force, game.tick) end end
    forget_unseen(mem)
    turrets_read(tmem, budget > 0)
    game_alerts(groups, force)
    local sight = mining.__sight
    if sight then local st = api.state(); st.push_vis = st.push_vis or {}; st.push_vis[force.name] = sight.vis end
    return merge(groups, network_groups(force), mining, force), sight and {cells=sight.cells, radars=sight.radars, unread=sight.unread, cover=sight.cover, chests=sight.chests} or {cells={}, radars={}}
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
        for _, surface in ipairs(planets()) do if needs_heating(surface) then stages[#stages+1] = {frozen=surface.name} end end
        for _, surface in ipairs(planets()) do if api.strike_cursor then stages[#stages+1] = {strike=surface.name} end end
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
        local kind = stage.surface and (job.list and 'slice' or 'band') or stage.frozen and 'frozen' or stage.strike and 'strike' or stage.step
        timed('pushalerts.' .. kind, step_do, s, force, tick, job, stage)
      end
    end
  end
  step_do = function(s, force, tick, job, stage)
    if stage.strike then
      -- A lightning planet: our buildings outside every lightning attractor's protection, STRIKE_SLICE a step
      -- (lightning.lua; the attractors' index and the find each a step); other planets pass at once.
      local surface = game.get_surface(stage.strike)
      job.strike = job.strike or {}
      local cur = job.strike_cur or (surface and api.strike_cursor(surface, force))
      if cur and not api.strike_step(cur, STRIKE_SLICE) then job.strike_cur = cur; return end
      if cur then job.strike[stage.strike] = cur.result end
      job.strike_cur = nil
      job.i = job.i + 1
      return
    end
    if stage.frozen then
      -- A planet that freezes: its entities found once, then FROZEN_SLICE a step; the cells' groups when done.
      local surface = game.get_surface(stage.frozen)
      if not surface then job.i = job.i + 1; return end
      if not job.flist then
        job.flist = freezable(surface, force)
        job.fat, job.frozen, job.fseen = 1, {}, {}
        return
      end
      local mem = frozen_memory(force)
      local last = math.min(#job.flist, job.fat + FROZEN_SLICE - 1)
      for i = job.fat, last do pcall(frozen_read, job, surface, job.flist[i], mem, job.fseen, tick) end
      job.fat = last + 1
      if job.fat > #job.flist then
        pcall(frozen_groups, job, surface, force, tick)
        frozen_forget(mem, job.flist, job.fseen)  -- (another planet's are kept by their own stage)
        job.flist, job.frozen, job.fseen = nil, nil, nil
        job.i = job.i + 1
      end
      return
    end
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
      local sight=job.mining.__sight
      if sight then s.push_vis=s.push_vis or {}; s.push_vis[force.name]=sight.vis end
      job.result={tick=job.start,groups=merge(job.groups,job.extra,job.mining,force),sight=sight and {cells=sight.cells,radars=sight.radars,unread=sight.unread,cover=sight.cover,chests=sight.chests,strike=job.strike} or {cells={},radars={},strike=job.strike}}
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
      -- (batch27 B5) one mine's forecast a step
      if api.mine_forecast and not job.mines then job.mines=try(function() return mine_patches(force) end) or {}; job.mine_i=1 end
      if job.mines and job.mine_i<=#job.mines then
        local m=job.mines[job.mine_i]; job.mine_i=job.mine_i+1
        local g=try(function() return mine_group(force,m) end)
        if g then groups[#groups+1]=g end
        return
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
    for _, d in ipairs(api.state().push_captive or {}) do
      if d.force == force.name and game.tick - d.tick <= CAPTIVE_KEEP then
        local sf = game.get_surface(d.surface)
        local spawner = sf and try(function() return sf.find_entities_filtered{position=d.position, radius=4, type='unit-spawner', limit=1}[1] end)
        local g = add(lost, 'captive_died', d.surface, nil, d.position, CAPTIVE, d.by[1], string.format('%s %s died %s ago; %s', CAPTIVE, at_text(d.position),
          (function() local m = math.floor((game.tick - d.tick) / 3600); return m > 0 and m .. 'm' or math.floor((game.tick - d.tick) / 60) .. 's' end)(),
          spawner and string.format('a hostile %s (force %s) stands in its place at %s', spawner.name, spawner.force.name, at_text(spawner.position)) or 'nothing stands in its place now'))
        for k = 2, #d.by do g.by[d.by[k]] = (g.by[d.by[k]] or 0) + 1 end
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
    local groups, sight = scan(force)
    c = {tick=game.tick, groups=groups, sight=sight}
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
    -- ammo_low (C1): who built them, and every agent within 64 tiles of the group
    if g.kind == 'ammo_low' then
      for name in pairs(g.by or {}) do if roster[name] then out[name] = 'built' end end
      for name, a in pairs(roster) do
        local pl = a.place
        if pl and pl.key == g.surface and pl.position and not pl.dead and g.center
          and (pl.position.x - g.center.x) ^ 2 + (pl.position.y - g.center.y) ^ 2 <= 64 * 64 then out[name] = out[name] or 'near' end
      end
      return out
    end
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
  local TURRET_TYPE = {no_ammo='ammo-turret', rebuilt_empty='ammo-turret', flamer_dry='fluid-turret', ammo_low='ammo-turret',
    artillery_empty='artillery-turret'}
  -- Whether an inserter of ours drops into e (one find round it: a long arm reaches 2 tiles past a 2x2 turret).
  function M.inserter_fed(e)
    local p0 = e.position
    for _, i in ipairs(try(function() return e.surface.find_entities_filtered{area={{p0.x - 4, p0.y - 4}, {p0.x + 4, p0.y + 4}}, type='inserter', force=e.force, limit=32} end) or {}) do
      if i.valid and try(function() return i.drop_target end) == e then return true end
    end
    return false
  end
  local function still_empty(e, kind)
    if kind == 'ammo_low' then
      local inv = try(function() return e.get_inventory(defines.inventory.turret_ammo) end)
      return inv ~= nil and inv.get_item_count() < AMMO_LOW
    end
    if kind == 'flamer_dry' then
      local amount = try(function() return (flameroil.read(e)) end)
      return amount ~= nil and amount < 1
    end
    local inv = try(function() return e.get_inventory(kind == 'artillery_empty' and defines.inventory.artillery_turret_ammo or defines.inventory.turret_ammo) end)
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
          if #at<8 then at[#at+1]=r.position end
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
            if #at < 8 then at[#at+1] = {x=math.floor(e.position.x * 10 + 0.5) / 10, y=math.floor(e.position.y * 10 + 0.5) / 10} end
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
  -- An alert's entities now, by its key (d17 batch12 C1, Haiku ~6 times: a refuel round an alert's centre found none of
  -- the 15 furnaces it named: a group is every touching 32-tile cell, and its centre the average): the burners or
  -- turrets still in that state (status groups: as recorded, still valid; turret groups: still empty). nil when no
  -- alert of ours has that key now.
  function M.alert_entities(force, key)
    local g
    for _, x in ipairs(current(force).groups or {}) do if x.key == key then g = x end end
    if not g then return nil end
    local list = {}
    if g.status_entities then
      for _, r in ipairs(g.status_entities) do
        local e = r.entity
        if e and e.valid and (g.kind == 'unconnected' or statuses()[e.status] == g.kind or g.kind == 'heat_no_fuel') then list[#list+1] = e end
      end
    elseif TURRET_TYPE[g.kind] and g.units and g.cells then
      local surface
      for _, x in pairs(game.surfaces) do if x.name == g.surface then surface = x end end
      local seen = {}
      for _, c in ipairs(surface and g.cells or {}) do
        local box = {{c[1] * CELL, c[2] * CELL}, {(c[1] + 1) * CELL, (c[2] + 1) * CELL}}
        for _, e in ipairs(surface.find_entities_filtered{area=box, type=TURRET_TYPE[g.kind], force=force, limit=4096}) do
          local unit = e.valid and try(function() return e.unit_number end)
          if unit and g.units[unit] and not seen[unit] and still_empty(e, g.kind) then seen[unit] = true; list[#list+1] = e end
        end
      end
    end
    return list, g
  end
  -- The exact positions of a group's entities (C1): 'stone-furnace (24.5,-60.5), ...' (at most 8), and its key.
  local ALERT_TAKES = {no_fuel='refuel', heat_no_fuel='refuel', no_ammo='rearm', rebuilt_empty='rearm', ammo_low='rearm'}
  local function where_text(g)
    local parts = {}
    if g.status_entities then
      for _, r in ipairs(g.status_entities) do
        if #parts >= 8 then break end
        if r.entity and try(function() return r.entity.valid end) then parts[#parts+1] = r.name .. ' ' .. at_text(r.position) end
      end
    else
      for _, q in ipairs(g.at or {}) do parts[#parts+1] = at_text(q) end
    end
    if #parts == 0 then return '' end
    return ': ' .. table.concat(parts, ', ') .. (g.n > #parts and string.format(', +%d more', g.n - #parts) or '')
  end
  -- plain: without the hint (the review block, selfview.lua).
  -- was: the count told before, or (a group with now_text) what its now_text said then.
  -- Where a group is: one entity at its own position as the game gives it (Muse 09:24: alert coordinates rounded to
  -- integers while chests sit at x.5, so a copied position missed the chest); more, the centre of the group.
  local function near_text(g)
    if g.n == 1 and g.at and g.at[1] then return at_text(g.at[1]) end
    return string.format('(%d,%d)', g.center.x, g.center.y)
  end
  -- The nearest fuel to an out-of-fuel group (d17 batch18 B4, Haiku: furnaces at (96,-14..-38), (56,-33), (95,-171) ran
  -- dry all shift and Haiku held no coal): our chests within FUEL_R tiles of the group's centre, else our belts within
  -- FUEL_BELT_R, holding a fuel its most common burner takes; the nearest, with item, count and distance; and the area round the
  -- burners for refuel {area, from: "nearest"} (at most 256 a side). Read when shown, kept FUEL_KEEP ticks a group.
  local FUEL_R, FUEL_BELT_R, FUEL_KEEP, FUEL_FIND = 64, 32, 600, 1024
  local fuel_seen, FUEL_BY = {}, nil
  local function fuels_for(names)
    if not FUEL_BY then
      FUEL_BY = {}
      for name, it in pairs(prototypes.item) do
        local cat = try(function() return it.fuel_category end)
        if cat and (try(function() return it.fuel_value end) or 0) > 0 then FUEL_BY[cat] = FUEL_BY[cat] or {}; FUEL_BY[cat][#FUEL_BY[cat]+1] = name end
      end
    end
    local out, seen = {}, {}
    for name in pairs(names or {}) do
      local cats = try(function() return prototypes.entity[name].burner_prototype.fuel_categories end) or {}
      for cat in pairs(cats) do for _, item in ipairs(FUEL_BY[cat] or {}) do if not seen[item] then seen[item] = true; out[#out+1] = item end end end
    end
    table.sort(out)
    return out
  end
  local function fuel_near(g)
    local f = fuel_seen[g.key or '']
    if f and game.tick - f.tick < FUEL_KEEP then return f end
    f = {tick=game.tick}
    if g.key then fuel_seen[g.key] = f end
    local surface = game.get_surface(g.surface)
    -- the fuels the group's most common burner takes (biochambers with a steel furnace: nutrients)
    local top, tn
    for name, n in pairs(g.names or {}) do if not tn or n > tn or (n == tn and name < top) then top, tn = name, n end end
    local items = fuels_for(top and {[top]=true} or {})
    if not surface or #items == 0 then return f end
    local c = g.n == 1 and g.at and g.at[1] or g.center
    local force
    for _, r in ipairs(g.status_entities or {}) do force = force or try(function() return r.entity.valid and r.entity.force end) end
    force = force or 'player'
    local best
    local function consider(e, item, n)
      local d = ((e.position.x - c.x) ^ 2 + (e.position.y - c.y) ^ 2) ^ 0.5
      if n > 0 and (not best or d < best.d) then best = {e=e, item=item, n=n, d=d} end
    end
    -- (one contents read an inventory or belt line: a count call a fuel item was 3-4 times the cost on the copy)
    local set = {}
    for _, item in ipairs(items) do set[item] = true end
    local function add(counts, list)
      for _, st in ipairs(list or {}) do if set[st.name] then counts[st.name] = (counts[st.name] or 0) + st.count end end
    end
    for _, e in ipairs(surface.find_entities_filtered{position=c, radius=FUEL_R, force=force, type={'container', 'logistic-container'}, limit=FUEL_FIND}) do
      local counts = {}
      add(counts, try(function() return e.get_inventory(defines.inventory.chest).get_contents() end))
      for item, n in pairs(counts) do consider(e, item, n) end
    end
    if not best then
      for _, e in ipairs(surface.find_entities_filtered{position=c, radius=FUEL_BELT_R, force=force, type={'transport-belt', 'underground-belt', 'splitter'}, limit=FUEL_FIND}) do
        local counts = {}
        for i = 1, try(function() return e.get_max_transport_line_index() end) or 0 do add(counts, try(function() return e.get_transport_line(i).get_contents() end)) end
        for item, n in pairs(counts) do consider(e, item, n) end
      end
    end
    if best then
      f.text = string.format('nearest fuel: %s %d in %s %s, %d tiles from %s', best.item, best.n, best.e.name, at_text(best.e.position), math.floor(best.d + 0.5), near_text(g))
      f.item = best.item
    else
      f.text = string.format('no chest within %d tiles or belt within %d tiles of %s holds %s', FUEL_R, FUEL_BELT_R, near_text(g), table.concat(items, ', ', 1, math.min(4, #items)))
    end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local pts = {}
    if g.status_entities and not g.status_capped then for _, r in ipairs(g.status_entities) do pts[#pts+1] = r.position end
    elseif (g.n or 0) <= #(g.at or {}) then pts = g.at end
    for _, q in ipairs(pts) do x0, y0, x1, y1 = math.min(x0, q.x), math.min(y0, q.y), math.max(x1, q.x), math.max(y1, q.y) end
    if #pts > 0 and x1 - x0 <= 252 and y1 - y0 <= 252 then
      f.area = string.format('[[%d,%d],[%d,%d]]', math.floor(x0) - 2, math.floor(y0) - 2, math.ceil(x1) + 2, math.ceil(y1) + 2)
    end
    return f
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
    -- silo kinds (A1): each silo's line
    if g.kind == 'silo_spoils' then
      return string.format('staged cargo spoils before its platform is back %s%s: %s', g.surface ~= here and 'on ' .. g.surface or 'here',
        was and string.format(' (was %d)', was) or '', table.concat(g.lost or {}, '; '))
    end
    local short_item = g.kind:match('^silo_short%.(.+)$')
    if short_item or g.kind == 'silo_ready_idle' then
      return string.format('%s %s%s: %s', short_item and ('rocket silo short of ' .. short_item) or 'rocket ready and not launched',
        g.surface ~= here and 'on ' .. g.surface or 'here', was and string.format(' (was %d)', was) or '', table.concat(g.lost or {}, '; '))
    end
    if g.kind == 'heat_no_fuel' then
      -- '1 heating-tower out of fuel near (40,12): heating-tower (40.5,12.5): 412 C, fuel slot empty; its heat network feeds 2 heat exchangers, which work at 500 C and more; refuel'
      return string.format('%s out of fuel near %s%s%s: %s%s%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '',
        not plain and (g.key and string.format('; refuel {alert: "%s"}', g.key) or '; refuel') or '')
        .. (not plain and (function()
          local f = try(function() return fuel_near(g) end)
          return f and f.text and '; ' .. f.text .. (f.item and f.area and string.format('; refuel {area: %s, from: "nearest", fuel: "%s"}', f.area, f.item) or '') or ''
        end)() or '')
    end
    if g.kind == 'captive_starving' or g.kind == 'captive_urgent' or g.kind == 'captive_died' then
      local head = g.kind == 'captive_died' and 'captive spawner died' or g.kind == 'captive_urgent' and 'captive spawner dies within 2 min' or 'captive spawner losing health'
      return string.format('%s%s%s: %s%s', head, g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
    end
    if g.kind == 'ammo_low' then
      -- '2 gun-turret hand-fed under 10 magazines near (-180,73): gun-turret (-186,72): firearm-magazine 4; ...; rearm {alert: "..."}'
      return string.format('%s hand-fed (no inserter drops into %s) under 10 magazines near %s%s%s: %s%s%s', what(g), g.n == 1 and 'it' or 'them', near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '',
        not plain and g.key and string.format('; rearm {alert: "%s"} tours exactly these', g.key) or '')
    end
    if g.kind == 'off_by_condition' then
      -- '1 biochamber stopped by its own circuit or logistic condition near (57,61): biochamber (45.5,72.5) (agricultural-science-pack): off by its logistic condition bioflux > 200 (...)'
      return string.format('%s stopped by %s own circuit or logistic condition near %s%s%s: %s%s', what(g), g.n == 1 and 'its' or 'their', near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
    end
    if g.kind == 'output_full' then
      -- '2 big-mining-drill stopped by a full chest near (130,120): big-mining-drill (128,118) mining calcite into iron-chest (128,120.5): 32/32 slots used (calcite 1600); ...'
      return string.format('%s stopped by a full chest near %s%s%s: %s%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
    end
    if g.kind == 'artillery_empty' then
      -- '1 artillery-turret with no shell for 5+ min near (150.5,-134.5): artillery-turret (150.5,-134.5): empty for 7 min; inserter (148.5,-134.5) takes from requester-chest (147.5,-134.5) (asks 10 artillery-shell, holds 0); ...'
      return string.format('%s with no shell for 5+ min near %s%s%s: %s%s', what(g), near_text(g),
        g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
        table.concat(g.lost or {}, '; '), g.n > #(g.lost or {}) and string.format('; +%d more', g.n - #(g.lost or {})) or '')
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
        not plain and (g.key and string.format('; rearm {alert: "%s"}', g.key) or '; rearm') or '')
    end
    local hint = not plain and HINT[g.kind]
    -- (C1) a refuel or rearm takes this alert by its key
    if hint and ALERT_TAKES[g.kind] and g.key and (g.n > 1 or g.kind == 'ammo_low') then hint = string.format('%s {alert: "%s"}', ALERT_TAKES[g.kind], g.key) end
    -- (B4) out of fuel: the nearest fuel, and refuel over the burners' area taking it from the nearest chest or belt
    if hint and g.kind == 'no_fuel' then
      local f = try(function() return fuel_near(g) end)
      if f and f.text then hint = f.text .. (f.item and f.area and string.format('; refuel {area: %s, from: "nearest", fuel: "%s"}', f.area, f.item) or '; ' .. hint) end
    end
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
    return string.format('%s %s near %s%s%s%s%s%s', what(g), LABEL[g.kind] or g.kind:gsub('_', ' '), near_text(g),
      g.surface ~= here and ' on ' .. g.surface or '', was and string.format(' (was %d)', was) or '',
      ALERT_TAKES[g.kind] and g.n > 1 and where_text(g) or '', hint and '; ' .. hint or '',
      (#rot > 0 and '; ' .. table.concat(rot, '; ') or '')..(g.stale and '; last observed tick '..(g.observed_tick or 0)..'; current state partly unknown' or ''))
  end

  -- Team block lines for p: at most one digest every DIGEST_TICKS, groups
  -- addressed to p that are new or grew since p was told. A group's rank,
  -- when it has one, is what grows (boiler_fuel: the step it reached, then
  -- how many boilers); its now_text is kept to say what it was.
  -- (C6) a captive spawner dying within 2 minutes, or dead, is told in the team block's urgent part and wakes a sleep
  -- (M.urgent_captive), not here.
  local URGENT_KINDS = {captive_urgent=true, captive_died=true}
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
      local g = not URGENT_KINDS[g0.kind] and owners(g0, who)[me] and M.recheck(g0, p.force) or nil
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

  -- Out of radar sight, per planet (status alerts.out_of_sight; an hourly team line): our drills, machines and turrets
  -- in chunks no force of players sees now, by 64-tile area (the most first, up to SIGHT_AREAS), each with the nearest
  -- radar of ours on that planet and its state; and the radars not working. From the last background read.
  local SIGHT_AREAS, SIGHT_TEAM = 5, 216000
  local RADAR_WORDS = {no_power='no power', low_power='low power', disabled_by_control_behavior='off by its circuit condition', no_minable_resources=nil}
  local function radar_state(status)
    for k, v in pairs(defines.entity_status or {}) do if v == status then return RADAR_WORDS[k] or k:gsub('_', ' ') end end
    return 'unknown'
  end
  function M.sight_lines(force)
    local c = (api.state().push_alerts or {})[force.name]
    local sight = c and c.sight
    if not sight then return nil end
    local by = {}
    for _, cell in pairs(sight.cells or {}) do
      local list = by[cell.surface] or {}; by[cell.surface] = list; list[#list+1] = cell
    end
    local surfaces = {}
    for name in pairs(by) do surfaces[#surfaces+1] = name end
    for name in pairs(sight.radars or {}) do if not by[name] then surfaces[#surfaces+1] = name end end
    table.sort(surfaces)
    local working = (defines.entity_status or {}).working
    local lines = {}
    for _, name in ipairs(surfaces) do
      local cells, radars = by[name] or {}, (sight.radars or {})[name] or {}
      local parts, off = {}, {}
      local total = {drills=0, machines=0, turrets=0}
      table.sort(cells, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.sx < b.sx end)
      for i, cell in ipairs(cells) do
        for k in pairs(total) do total[k] = total[k] + cell[k] end
        if i <= SIGHT_AREAS then
          local mx, my = cell.sx / cell.n, cell.sy / cell.n
          local what = {}
          for _, k in ipairs({'drills', 'machines', 'turrets'}) do if cell[k] > 0 then what[#what+1] = cell[k] .. ' ' .. (cell[k] == 1 and k:sub(1, -2) or k) end end
          local best, bd
          for _, r in ipairs(radars) do
            local d = math.sqrt((r.x - mx) ^ 2 + (r.y - my) ^ 2)
            if not bd or d < bd then best, bd = r, d end
          end
          parts[#parts+1] = string.format('%s near (%d,%d), nearest radar %s', table.concat(what, ', '), math.floor(mx), math.floor(my),
            best and string.format('(%g,%g) %d tiles, %s', best.x, best.y, math.floor(bd + 0.5), best.status == working and 'working' or radar_state(best.status)) or 'none on ' .. name)
        end
      end
      for _, r in ipairs(radars) do if r.status ~= working then off[#off+1] = string.format('radar (%g,%g) %s', r.x, r.y, radar_state(r.status)) end end
      if #cells > 0 or #off > 0 then
        local head = #cells > 0 and string.format('out of radar sight on %s: %d drills, %d machines, %d turrets in %d area%s (64 tiles): %s%s', name, total.drills, total.machines, total.turrets,
          #cells, #cells == 1 and '' or 's', table.concat(parts, '; '), #cells > SIGHT_AREAS and string.format('; +%d more areas', #cells - SIGHT_AREAS) or '') or string.format('on %s every drill, machine and turret of ours is in sight', name)
        lines[#lines+1] = head .. (#off > 0 and '; radars not working: ' .. table.concat(off, ', ', 1, math.min(6, #off)) .. (#off > 6 and string.format(', +%d more', #off - 6) or '') or '')
      end
    end
    if #lines > 0 and (sight.unread or 0) > 0 then
      lines[#lines+1] = string.format('(%d buildings in chunks not yet read for sight; the next reads take them)', sight.unread)
    end
    return #lines > 0 and lines or nil, c.tick
  end
  -- Outside coverage, per planet (status alerts.outside_coverage; the hourly team line): what lies outside every
  -- roboport's construction area by 64-tile area (the most first, up to SIGHT_AREAS: count, ghosts, the 3 names most
  -- there), and the requester and buffer chests outside every logistic area. From the last background read.
  function M.coverage_lines(force)
    local c = (api.state().push_alerts or {})[force.name]
    local sight = c and c.sight or {}
    local by = {}
    for _, cell in pairs(sight.cover or {}) do local list = by[cell.surface] or {}; by[cell.surface] = list; list[#list+1] = cell end
    local surfaces = {}
    for name in pairs(by) do surfaces[#surfaces+1] = name end
    for name in pairs(sight.chests or {}) do if not by[name] then surfaces[#surfaces+1] = name end end
    table.sort(surfaces)
    local lines = {}
    for _, name in ipairs(surfaces) do
      local cells, chests = by[name] or {}, (sight.chests or {})[name]
      local parts, total, ghosts = {}, 0, 0
      table.sort(cells, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.sx < b.sx end)
      for i, cell in ipairs(cells) do
        total, ghosts = total + cell.n, ghosts + cell.ghosts
        if i <= SIGHT_AREAS then
          local names = {}
          for k, n in pairs(cell.names) do names[#names+1] = {k=k, n=n} end
          table.sort(names, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
          local what = {}
          for j = 1, math.min(3, #names) do what[j] = names[j].n .. ' ' .. names[j].k end
          parts[#parts+1] = string.format('%s%s near (%d,%d)', table.concat(what, ', '), #names > 3 and ', ...' or '', math.floor(cell.sx / cell.n), math.floor(cell.sy / cell.n))
        end
      end
      local text = {}
      if #cells > 0 then
        text[#text+1] = string.format('outside every roboport\'s construction area on %s (robots do not build, repair or rebuild there): %d (%d of them ghosts) in %d area%s (64 tiles): %s%s',
          name, total, ghosts, #cells, #cells == 1 and '' or 's', table.concat(parts, '; '), #cells > SIGHT_AREAS and string.format('; +%d more areas', #cells - SIGHT_AREAS) or '')
      end
      if chests and (chests.n or 0) > 0 then
        local at = {}
        for i, x in ipairs(chests) do if i <= 6 then at[i] = string.format('%s (%g,%g)', x.name, x.x, x.y) end end
        text[#text+1] = string.format('%s%d requester or buffer chest%s outside every logistic area on %s (their requests never fill): %s%s', #text > 0 and '' or '',
          chests.n, chests.n == 1 and '' or 's', name, table.concat(at, ', '), chests.n > #at and string.format(', +%d more', chests.n - #at) or '')
      end
      for _, t in ipairs(text) do lines[#lines+1] = t end
    end
    -- Lightning (lightning.lua): our buildings outside every attractor's protection, and those lightning killed.
    local ok, more = pcall(function() return api.strike_lines and api.strike_lines(sight.strike, force, SIGHT_AREAS) end)
    for _, l in ipairs(ok and more or {}) do lines[#lines+1] = l end
    return #lines > 0 and lines or nil
  end
  -- The team line: at most once an hour (h.sight_tick), the same lines (sight, then coverage).
  function M.sight_team(p, h)
    if h.sight_tick and game.tick - h.sight_tick < SIGHT_TEAM then return {} end
    local lines = M.sight_lines(p.force) or {}
    for _, l in ipairs(M.coverage_lines(p.force) or {}) do lines[#lines+1] = l end
    if #lines == 0 then return {} end
    h.sight_tick = game.tick
    return lines
  end
  -- The urgent captive groups addressed to p now: {key, level, line}.
  function M.urgent_captive(p)
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who, out = roster(), {}
    for _, g in ipairs(c.groups) do
      if URGENT_KINDS[g.kind] and owners(g, who)[me] then out[#out+1] = {key=g.key, level=g.n, line=M.text(g, here)} end
    end
    return out
  end
  -- (d17 batch30 A2, Sol and viewer Foobator 05:47: a speaker set to alert went unseen; the game's custom alerts were
  -- skipped) programmable speaker alerts: the game's custom alerts whose target is a programmable speaker, read from
  -- the alert list (the alert reader's, as game_alerts) at most once a SPEAKER_TICKS, kept in storage. A row a speaker:
  -- key, surface, position, message and icon (its alert settings), since (the alert's tick), by (who built it). Each
  -- goes to who built it and every agent on its surface; the team block tells one once while it stays up, and again
  -- when it comes back; a wait on alert kinds speaker ends on a new one; game_alerts lists them as kind speaker.
  M.SPEAKER_TICKS, M.SPEAKER_MAX = 60, 64
  function M.speakers(force)
    local st = api.state()
    st.push_speakers = st.push_speakers or {}
    local c = st.push_speakers[force.name]
    if c and game.tick - c.tick < M.SPEAKER_TICKS then return c.rows end
    local rows = {}
    local reader = api.alert_reader and api.alert_reader(force)
    local custom = defines.alert_type and defines.alert_type.custom
    local raw = reader and custom and try(function() return reader.get_alerts{type=custom} end)
    for si, by_type in pairs(raw or {}) do
      local sf = game.surfaces[si]
      for _, list in pairs(by_type) do
        for _, al in ipairs(list) do
          local e = al.target
          if sf and #rows < M.SPEAKER_MAX and e and try(function() return e.valid and e.type == 'programmable-speaker' end) then
            local ap = try(function() return e.alert_parameters end) or {}
            local msg = type(ap.alert_message) == 'string' and ap.alert_message or (type(al.message) == 'string' and al.message) or ''
            local icon = ap.icon_signal_id or al.icon
            rows[#rows+1] = {key='speaker|' .. sf.name .. '|' .. tostring(e.unit_number), surface=sf.name,
              position={x=e.position.x, y=e.position.y}, message=msg, since=al.tick or game.tick, by=builder(e),
              icon=type(icon) == 'table' and icon.name and ((icon.type or 'item') .. ':' .. icon.name) or nil}
          end
        end
      end
    end
    table.sort(rows, function(a, b) return a.key < b.key end)
    st.push_speakers[force.name] = {tick=game.tick, rows=rows}
    return rows
  end
  function M.speaker_text(r, here)
    return string.format('speaker alert%s at (%g,%g)%s: %s%s, %s ago', r.surface ~= here and ' on ' .. r.surface or '', r.position.x, r.position.y,
      r.by and ' (built by ' .. r.by .. ')' or '', r.message ~= '' and '"' .. r.message .. '"' or 'no message', r.icon and ' [' .. r.icon .. ']' or '',
      (function() local sec = math.floor(math.max(0, game.tick - r.since) / 60); return sec < 60 and sec .. 's' or string.format('%dm%02ds', math.floor(sec / 60), sec % 60) end)())
  end
  -- The speaker rows p hears: its own speakers and those on the surface it is on.
  function M.my_speakers(p)
    local me, here = api.who(p), try(function() return p.surface.name end)
    local out = {}
    for _, r in ipairs(M.speakers(p.force)) do
      if r.by == me or r.surface == here then out[#out+1] = r end
    end
    return out, here
  end
  -- The team block's lines: each speaker alert once while it stays up (h.speakers: key -> since told).
  function M.speaker_lines(p, h)
    local told, now, lines = h.speakers or {}, {}, {}
    local rows, here = M.my_speakers(p)
    for _, r in ipairs(rows) do
      if told[r.key] ~= r.since then lines[#lines+1] = M.speaker_text(r, here) end
      now[r.key] = r.since
    end
    h.speakers = next(now) and now or nil
    return lines
  end
  -- The team block's urgent part: each such group once (again when it grows), h.captive: key -> level told.
  function M.captive_lines(p, h)
    local told, now, lines = h.captive or {}, {}, {}
    for _, r in ipairs(M.urgent_captive(p)) do
      now[r.key] = told[r.key]
      if not told[r.key] or r.level > told[r.key] then lines[#lines+1] = r.line; now[r.key] = r.level end
    end
    h.captive = next(now) and now or nil
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
    local out = {}
    if kind_matches('speaker', kinds) then
      local rows, here0 = M.my_speakers(p)
      for _, r in ipairs(rows) do out[r.key] = {level=r.since, text=M.speaker_text(r, here0)} end
      local only = true
      for _, k in ipairs(kinds) do if k ~= 'speaker' then only = false end end
      if only then return out end
    end
    local c = current(p.force)
    local me = api.who(p)
    local here = try(function() return p.surface.name end)
    local who = roster()
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
    -- (d17 batch32 B2, Sol: 148 groups in 82 KB hid no_storage) kind: one kind, several (an array or "a,b"), each with
    -- its sub-kinds; compact: true: counts per kind first, then one line a group
    assert(a.compact == nil or type(a.compact) == 'boolean', 'compact must be true or false')
    assert(a.surface == nil or type(a.surface) == 'string', 'surface is a surface name')
    local kinds
    if a.kind ~= nil then
      kinds = {}
      if type(a.kind) == 'string' then for w in a.kind:gmatch('[^,%s]+') do kinds[#kinds+1] = w end
      else
        assert(type(a.kind) == 'table', 'kind is an alert kind, several in an array, or "a,b"')
        for _, w in ipairs(a.kind) do assert(type(w) == 'string', 'kind names are strings'); kinds[#kinds+1] = w end
      end
      assert(#kinds >= 1 and #kinds <= 16, 'kind: 1..16 alert kinds')
    end
    local function wanted(kind)
      if not kinds then return true end
      for _, k in ipairs(kinds) do if kind == k or kind:sub(1, #k + 1) == k .. '.' then return true end end
      return false
    end
    -- (d17 batch35 B4, Luna: game_alerts ran 1,300+ lines, 82 KB, over all surfaces each review) claim: a board claim's
    -- id, or mine: true for the caller's own claims: only groups whose centre (or feed chest) lies in it; since: the
    -- cursor the last reply gave: only groups not shown then (by kind, surface and 32-tile cell), and how many of those
    -- shown then are gone. Either gives the compact form.
    assert(a.mine == nil or type(a.mine) == 'boolean', 'mine must be true or false')
    assert(a.claim == nil or type(a.claim) == 'number', 'claim is a board claim id (board lists them)')
    assert(a.since == nil or type(a.since) == 'number', 'since is the cursor the last game_alerts reply gave')
    local me = api.who and api.who(p)
    local claim_filter
    if a.claim ~= nil or a.mine then
      local board = api.state().board
      local want = {}
      for _, i in pairs(board and board.items or {}) do
        if i.kind == 'claim' and ACTIVE[i.status] and ((a.claim ~= nil and i.id == a.claim) or (a.mine and a.claim == nil and i.owner == me)) then want[i.id] = true end
      end
      assert(next(want) or a.mine, string.format('no open claim #%s on the board', tostring(a.claim)))
      claim_filter = function(g)
        for _, i in ipairs(claims_over(g, g.center)) do if want[i.id] then return true end end
        for _, i in ipairs(claims_over(g, g.chest_at)) do if want[i.id] then return true end end
        return false
      end
    end
    if a.since ~= nil or claim_filter then a = setmetatable({compact=true}, {__index=a}) end
    local function gkey(g)
      local cx = g.center and math.floor(g.center.x / 32) or '?'
      local cy = g.center and math.floor(g.center.y / 32) or '?'
      return tostring(g.kind) .. '|' .. tostring(g.surface) .. '|' .. cx .. ',' .. cy
    end
    local st = api.state()
    st.alerts_seen = st.alerts_seen or {}
    local before = me and st.alerts_seen[me]
    local since_note
    if a.since ~= nil and not (before and before.cursor == a.since) then
      since_note = 'since: not the cursor of your last game_alerts reply' .. (before and string.format(' (that was %d)', before.cursor) or '') .. ': every group listed'
    end
    local c = current(p.force)
    local who = roster()
    local here = try(function() return p.surface.name end)
    local rows = {}
    local shown_keys, new_n = {}, 0
    for _, g0 in ipairs(c.groups) do
      local g = (a.surface == nil or g0.surface == a.surface) and wanted(g0.kind) and (not claim_filter or claim_filter(g0))
        and M.recheck(g0, p.force)
      if g then
        local k = gkey(g)
        shown_keys[k] = true
        if a.since ~= nil and not since_note and before.keys[k] then g = nil else new_n = new_n + 1 end
      end
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
    -- speaker alerts (A2), read live
    if wanted('speaker') then
      for _, r in ipairs(M.speakers(p.force)) do
        if a.surface == nil or r.surface == a.surface then
          local to = {}
          if r.by and who[r.by] then to[#to+1] = r.by .. ' (built)' end
          for name, ag in pairs(who) do if name ~= r.by and ag.place and ag.place.key == r.surface then to[#to+1] = name .. ' (on ' .. r.surface .. ')' end end
          table.sort(to)
          rows[#rows+1] = {kind='speaker', surface=r.surface, count=1, center=r.position, message=r.message, icon=r.icon, since_tick=r.since,
            line=M.speaker_text(r, here), to=#to > 0 and to or nil}
        end
      end
    end
    -- counts per kind (the most groups first) and per surface
    local by, order = {}, {}
    for _, r in ipairs(rows) do
      if not by[r.kind] then by[r.kind] = 0; order[#order+1] = r.kind end
      by[r.kind] = by[r.kind] + 1
    end
    table.sort(order, function(x, y) return by[x] > by[y] or (by[x] == by[y] and x < y) end)
    local parts = {}
    for _, k in ipairs(order) do parts[#parts+1] = k .. ' ' .. by[k] end
    local counts = #rows > 0 and string.format('%d group%s: %s', #rows, #rows == 1 and '' or 's', table.concat(parts, ', ')) or nil
    local scanned = string.format('%ds ago', math.floor((game.tick - c.tick) / 60))
    -- the cursor: the groups this reply covered, kept per agent (the last one only)
    local cursor, gone
    if me and (a.since ~= nil or a.mine or a.claim ~= nil or a.cursor) then
      if a.since ~= nil and not since_note then
        gone = 0
        for k in pairs(before.keys) do if not shown_keys[k] then gone = gone + 1 end end
      end
      cursor = (before and before.cursor or 0) + 1
      st.alerts_seen[me] = {cursor=cursor, keys=shown_keys, tick=game.tick}
    end
    if a.compact then
      local lines = {}
      for _, r in ipairs(rows) do
        local l = string.format('%s %s: %s', r.kind, r.surface or '?', tostring(r.line or ''):gsub('[%c]+', ' '))
        lines[#lines+1] = #l > 300 and l:sub(1, 297) .. '...' or l
      end
      return {counts=counts, lines=#lines > 0 and lines or nil, scanned=scanned, cursor=cursor, since_note=since_note,
        new=a.since ~= nil and not since_note and new_n or nil, gone_since=gone,
        note=#rows == 0 and (a.since ~= nil and not since_note and 'no new alert or warning since the cursor' or 'no alerts or warnings') .. (kinds and ' of ' .. table.concat(kinds, ', ') or '') .. (a.surface and ' on ' .. a.surface or '') .. (claim_filter and ' in the claim' .. (a.mine and 's named' or '') or '') or nil}
    end
    return {counts=counts, groups=rows, scanned=scanned,
      note=#rows == 0 and 'no alerts or warnings' or nil}
  end
  M.schema = {
    game_alerts = {freshness='power/fuel entity groups recheck up to 128 recorded entities; hidden/capped observations are dated; belt_cut names missing formerly carrying tiles, cleared by observed replacements; frozen: on a planet whose entities need heating, our frozen entities per 64-tile area (pipes and machines with what they hold, belts as one run, how long frozen since first seen, the nearest heater with its temperature and distance from the nearest frozen one); line_cut: a long belt or pipe line (8+ tiles) cut where ours died, naming the cut tiles (and what else stands on one), how far the line runs either side and what it carried, what the belt past the cut feeds (the machines inserters take into from it, with their state) and how to rebuild each tile (a ghost there, or what to place facing which way), until a belt or pipe stands there again (at most 6 h); power_cut: a pole loss not joined again (power cut #N: the split, the machines no other pole reaches, the missing link and a ghost there or not, and each machine left alone as it stands now: a pump with its fluid), while it lasts; also a belt line blocked: a build that leaves a belt facing into a tile with no belt but another entity (not an inserter) and a belt within 2 tiles past it facing the same way, naming that entity, after 30 s, until it or either belt is gone or a belt stands there; belt_cut names what stands on a missing tile in sight; out_of_ore includes drill_site, one representative drill placement cached 60 s and computed in background',surface='optional surface name', kind='optional kind (no_power, unconnected, low_power, no_fuel (its line adds the spoiling fuel of burners of those names around it: how many burn it, how many within 60 s, the first to spoil and when), burnt_full (burners stopped by a full burnt-result slot whatever their status reads, a biochamber whose spoiled nutrients fill it: each with what fills that slot and its fuel slot), output_full (mining drills waiting for space in a chest they drop into, per 64-tile area: each drill, what it mines, the chest and its slots used, what fills it; a backed-up belt is not said), off_by_condition (assemblers, furnaces, labs, drills and silos off by their own circuit or logistic condition, each with the condition and the value it reads; a condition on what its recipe makes, a stock cap, is not said), no_ammo, flamer_dry, speaker (programmable speakers alerting now, read live: message, icon, since_tick, to: who built it and agents on its surface), artillery_empty (artillery turrets with no shell for 5+ min: each with the inserters feeding it, their requester chest\'s shell request and holdings, its network\'s shells); out_of_ore (mining drills whose patch under them is used up, by ore: out_of_ore.iron-ore, ...; each with ore, still_mining (our drills still mining that ore in the area) and untapped (the nearest patch of it no drill of ours is on, from the ores read\'s last survey: x, y, d tiles, amount));rebuilt_empty (turrets built with no ammo and still empty 60 s or more, each with its ammo request); lost_source and lost_target (inserters that had a pickup target and have none now, or whose drop target is gone; by what they feed: lost_source.boiler, .furnace, .lab, .assembler, else the entity type; each with lost: the inserter, what it read, what it puts into); per network: no_power.network (machines reporting no_power, grouped by electric network including small isolated networks, with its latest 5 s supply sample); power_high (draw at 85% of capacity or more for 2 min), boiler_fuel (boilers under 20 min of their own fuel at the draw with no fuel in their feeders\' hands or at their sources, again at 10 and 5; the fuel in chests and on belts within 64 tiles and what feeds them), feed_chest_low (a boiler\'s feed chest under 20 of its fuel with nothing put into it for 5 min: boiler, chest, count, feeder); robots_busy (no idle logistic robot for 10 min); accumulators_draining (a network\'s accumulators empty within 10 min at their net flow of the last 30 s, again under 5 and 2 min; kept 10 min after, so a Fulgora storm between lulls is not news; on Fulgora with the time to the next storm or to dawn); construction_wait (ghosts in a network\'s construction area waiting 5+ min since first seen while their items are in the network, with the construction robots and whether busy); deliveries_wait (requests unfilled 5+ min while providers or storage hold the item free, with what the logistic robots are doing); requester_full (requester chests with every slot taken while a request has been short 60+ s: per network, each chest, the item it asks and what fills its slots, spoilage counted); input_spoilage (assemblers and furnaces short of ingredients with spoilage their recipe does not take in their input: each machine, how much in how many slots); seed_spoiling (a machine whose recipe takes pentapod eggs or bacteria, not crafting while that seed in its input hatches or spoils within 3 min: the seed, when, and why it is not crafting); output_chest_full (a full_output maker whose output inserter puts into a chest with no free slot: the maker, the inserter, the chest and what fills its slots); catalyst_gone (a starved machine whose recipe takes an item it also makes, with none of it in its input: the item, what its output holds, and each inserter taking from it with its hand size);science_idle (a pack the research needs whose makers on the science surface all stood still at two science-line builds 5+ min apart, with their states and the chain\'s first short step); on Fulgora: lightning_unconnected (lightning attractors no pole reaches), lightning_unused (attractors in a network with no accumulator and nothing drawing power in the last minute), lightning_storage_full (a network with attractors whose accumulators are at 99% or more); or a game alert type such as no_material_for_construction, not_enough_construction_robots, not_enough_repair_packs, no_storage, train_out_of_fuel, unclaimed_cargo, collector_path_blocked)',
      compact='optional true: counts (groups per kind, the most first), then lines: one line a group, "KIND SURFACE: its line" (cut at 300 characters), in place of groups',
      claim='optional board claim id: only the groups whose centre (or feed chest) lies in that open claim\'s area on its surface (compact)', mine='optional true: the same over your own open claims',
      since='optional: the cursor your last game_alerts reply gave (with claim, mine or cursor: true): only the groups not in that reply (by kind, surface and 32-tile cell), new (how many), gone_since (how many of that reply\'s are gone), compact; every reply with claim, mine, since or cursor gives a new cursor (kept per agent, the last one)',
      cursor='optional true: give a cursor without filtering',
      returns='counts (N groups: kind n, ... the most first); groups worst first: {kind, surface, count, center, names, at (up to 4 positions), line, to (who the team block tells: claim, built, nearest)}; scanned (the scan is at most 30 s old). kind takes one kind, several in an array or "no_storage,no_power", each with its sub-kinds. What a player\'s alert panel and status icons show; new or worsening groups also come in team.alerts (one digest per 150 s). Read only'},
  }
  return M
end
